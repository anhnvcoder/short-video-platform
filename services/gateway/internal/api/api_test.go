package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/ratelimit"
)

const (
	testKID = "k1"
	userA   = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	userB   = "01928c6e-7b3a-7cde-8f01-000000000000"
	// userC has no profile: fakeUsers' GetProfiles leaves it out, as user-service leaves out an
	// id without a user.
	userC   = "01928c6e-7b3a-7cde-8f01-444444444444"
	videoID = "01928c6e-7b3a-7cde-8f01-111111111111"
	// videoID2 is the second item of every feed page fakeFeed answers.
	videoID2 = "01928c6e-7b3a-7cde-8f01-333333333333"
	// clientTraceparent is a valid traceparent a client might send; it must never be used.
	clientTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	clientTraceID     = "4bf92f3577b34da6a3ce929d0e0e4736"
	fakeAccessToken   = "fake.access.token"
	mediaBase         = "http://127.0.0.1:9000/media"
	// fakeRefreshToken is the refresh token fakeUsers' Login answers.
	fakeRefreshToken = "fake-refresh-token-of-login"
	// rotatedAccessToken and rotatedRefreshToken are what fakeUsers' Refresh answers.
	rotatedAccessToken  = "fake.rotated.access.token" //nolint:gosec // a fake token of the tests
	rotatedRefreshToken = "fake-refresh-token-rotated"
	// uploadSecret stands for a presigned POST credential: it must reach the client, not the log.
	uploadSecret = "presigned-signature-secret"
	// noFormFields is a title fakeVideos answers with a nil form_fields map.
	noFormFields = "no form fields"
	// nextCursor is the next_page_token of every non-empty following page fakeFeed answers.
	nextCursor = "next-page-token"
	// emptyCursor is a page_token fakeFeed answers with an empty last page.
	emptyCursor = "empty"
	// traceparentKey is the metadata key of the W3C trace context the services receive.
	traceparentKey = "traceparent"
)

var (
	createdAt   = time.Date(2026, 10, 11, 1, 2, 3, 456000000, time.UTC)
	publishedAt = time.Date(2026, 10, 11, 1, 5, 0, 0, time.UTC)
	uploadUntil = time.Date(2026, 10, 11, 1, 17, 3, 0, time.UTC)
	tokenExpiry = time.Date(2026, 10, 11, 2, 0, 0, 0, time.UTC)
	// refreshExpiry is when the refresh tokens fakeUsers answers expire.
	refreshExpiry = time.Date(2026, 10, 25, 1, 0, 0, 0, time.UTC)
)

// call is one RPC a fake backend received.
type call struct {
	method string
	md     metadata.MD
	req    any
}

// backend is a fake gRPC server on a bufconn listener: it records every RPC with its incoming
// metadata, then runs hook (when set) before the fake service; a non-nil error from hook is
// the RPC's answer. It also serves the standard health service.
type backend struct {
	health *health.Server
	stop   func()

	mu    sync.Mutex
	calls []call
	hook  func(ctx context.Context, method string) error
}

func (b *backend) intercept(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	if info.FullMethod == healthpb.Health_Check_FullMethodName {
		return handler(ctx, req)
	}
	md, _ := metadata.FromIncomingContext(ctx)
	b.mu.Lock()
	b.calls = append(b.calls, call{method: info.FullMethod, md: md, req: req})
	hook := b.hook
	b.mu.Unlock()
	if hook != nil {
		if err := hook(ctx, info.FullMethod); err != nil {
			return nil, err
		}
	}
	return handler(ctx, req)
}

func (b *backend) setHook(hook func(ctx context.Context, method string) error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.hook = hook
}

// fail makes every RPC return err.
func (b *backend) fail(err error) {
	b.setHook(func(context.Context, string) error { return err })
}

func (b *backend) recorded() []call {
	b.mu.Lock()
	defer b.mu.Unlock()
	return slices.Clone(b.calls)
}

// only returns the single recorded call and fails the test if there is not exactly one.
func (b *backend) only(t *testing.T) call {
	t.Helper()
	calls := b.recorded()
	if len(calls) != 1 {
		t.Fatalf("backend got %d calls, want 1: %+v", len(calls), calls)
	}
	return calls[0]
}

// startBackend serves register on a new bufconn listener and returns the fake and a client
// connection to it, dialed like the gateway's (with httpx.ClientTelemetry) and with opts added.
// The fake continues the trace it receives, as a service's grpcserver does.
func startBackend(t *testing.T, register func(*grpc.Server), opts ...grpc.DialOption) (*backend, *grpc.ClientConn) {
	t.Helper()
	b := &backend{health: health.NewServer()}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.StatsHandler(otelgrpc.NewServerHandler()), grpc.UnaryInterceptor(b.intercept))
	healthpb.RegisterHealthServer(srv, b.health)
	register(srv)
	go func() { _ = srv.Serve(lis) }()
	b.stop = srv.Stop
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet", append([]grpc.DialOption{
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		httpx.ClientTelemetry(),
	}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	// grpc.NewClient connects lazily, on the first RPC, which then pays for the bufconn dial and
	// the HTTP/2 handshake inside its own deadline. Under a loaded -race run of the whole repo
	// that can exceed statsTimeout (100 ms), so GetStats would fail before reaching the fake.
	// Connecting here keeps setup out of every call's deadline; tests that stop a backend still
	// see it unreachable, as the connection to it breaks.
	conn.Connect()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	for state := conn.GetState(); state != connectivity.Ready; state = conn.GetState() {
		if !conn.WaitForStateChange(ctx, state) {
			t.Fatalf("connection to the fake backend not ready: %v", state)
		}
	}
	return b, conn
}

type fakeUsers struct {
	userv1.UnimplementedUserServiceServer
}

func (fakeUsers) Register(context.Context, *userv1.RegisterRequest) (*userv1.RegisterResponse, error) {
	return &userv1.RegisterResponse{UserId: userA}, nil
}

func (fakeUsers) Login(context.Context, *userv1.LoginRequest) (*userv1.LoginResponse, error) {
	return &userv1.LoginResponse{
		AccessToken:      fakeAccessToken,
		ExpiresAt:        timestamppb.New(tokenExpiry),
		RefreshToken:     fakeRefreshToken,
		RefreshExpiresAt: timestamppb.New(refreshExpiry),
	}, nil
}

func (fakeUsers) Refresh(context.Context, *userv1.RefreshRequest) (*userv1.RefreshResponse, error) {
	return &userv1.RefreshResponse{
		AccessToken:      rotatedAccessToken,
		ExpiresAt:        timestamppb.New(tokenExpiry),
		RefreshToken:     rotatedRefreshToken,
		RefreshExpiresAt: timestamppb.New(refreshExpiry),
	}, nil
}

func (fakeUsers) Logout(context.Context, *userv1.LogoutRequest) (*userv1.LogoutResponse, error) {
	return &userv1.LogoutResponse{}, nil
}

func (fakeUsers) Follow(context.Context, *userv1.FollowRequest) (*userv1.FollowResponse, error) {
	return &userv1.FollowResponse{}, nil
}

func (fakeUsers) Unfollow(context.Context, *userv1.UnfollowRequest) (*userv1.UnfollowResponse, error) {
	return &userv1.UnfollowResponse{}, nil
}

// profiles are the users fakeUsers knows, by user id.
var profiles = map[string]*userv1.Profile{
	userA: {UserId: userA, Handle: "alice", DisplayName: "Alice"},
	userB: {UserId: userB, Handle: "bob", DisplayName: "Bob B"},
}

// GetProfiles answers the known profiles among user_ids, in reverse order, so the gateway must
// match them by user_id.
func (fakeUsers) GetProfiles(_ context.Context, req *userv1.GetProfilesRequest) (*userv1.GetProfilesResponse, error) {
	var out []*userv1.Profile
	for _, id := range slices.Backward(req.GetUserIds()) {
		if p, ok := profiles[id]; ok {
			out = append(out, p)
		}
	}
	return &userv1.GetProfilesResponse{Profiles: out}, nil
}

// GetProfileByHandle knows only "bob", whom the caller follows.
func (fakeUsers) GetProfileByHandle(_ context.Context, req *userv1.GetProfileByHandleRequest) (*userv1.GetProfileByHandleResponse, error) {
	if req.GetHandle() != "bob" {
		return nil, grpcerr.New(codes.NotFound, "USER_NOT_FOUND", "user not found")
	}
	return &userv1.GetProfileByHandleResponse{Profile: profiles[userB], FollowedByMe: true}, nil
}

// UpdateDisplayName answers the caller's profile with the new name, and refuses an empty one.
func (fakeUsers) UpdateDisplayName(ctx context.Context, req *userv1.UpdateDisplayNameRequest) (*userv1.UpdateDisplayNameResponse, error) {
	if req.GetDisplayName() == "" {
		return nil, grpcerr.New(codes.InvalidArgument, "INVALID_DISPLAY_NAME", "display_name must be 1 to 50 characters")
	}
	md, _ := metadata.FromIncomingContext(ctx)
	ids := md.Get(callerid.MetadataKey)
	if len(ids) != 1 || profiles[ids[0]] == nil {
		return nil, grpcerr.New(codes.NotFound, "USER_NOT_FOUND", "user not found")
	}
	p := profiles[ids[0]]
	return &userv1.UpdateDisplayNameResponse{Profile: &userv1.Profile{UserId: p.GetUserId(), Handle: p.GetHandle(), DisplayName: req.GetDisplayName()}}, nil
}

// fakeVideos answers GetVideo with a READY video for videoID and an UPLOADING one otherwise.
type fakeVideos struct {
	videov1.UnimplementedVideoServiceServer
}

// InitUpload answers without form fields when the title is noFormFields.
func (fakeVideos) InitUpload(_ context.Context, req *videov1.InitUploadRequest) (*videov1.InitUploadResponse, error) {
	if req.GetTitle() == noFormFields {
		return &videov1.InitUploadResponse{VideoId: videoID, UploadUrl: "http://127.0.0.1:9000/svp-uploads", ExpiresAt: timestamppb.New(uploadUntil)}, nil
	}
	return &videov1.InitUploadResponse{
		VideoId:    videoID,
		UploadUrl:  "http://127.0.0.1:9000/svp-uploads",
		FormFields: map[string]string{"key": "uploads/" + videoID, "x-amz-signature": uploadSecret},
		ExpiresAt:  timestamppb.New(uploadUntil),
	}, nil
}

// CompleteUpload answers PROCESSING for videoID and READY (idempotent repeat) for any other id.
func (f fakeVideos) CompleteUpload(ctx context.Context, req *videov1.CompleteUploadRequest) (*videov1.CompleteUploadResponse, error) {
	resp, err := f.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: req.GetVideoId()})
	if err != nil {
		return nil, err
	}
	v := resp.GetVideo()
	if req.GetVideoId() == videoID {
		v.Status = videov1.VideoStatus_VIDEO_STATUS_PROCESSING
		v.Duration, v.PlaylistKey, v.ThumbnailKey, v.PublishedAt = nil, "", "", nil
	} else {
		v.Status = videov1.VideoStatus_VIDEO_STATUS_READY
		v.PlaylistKey = "media/" + req.GetVideoId() + "/master.m3u8"
		v.ThumbnailKey = "media/" + req.GetVideoId() + "/thumb.jpg"
	}
	return &videov1.CompleteUploadResponse{Video: v}, nil
}

func (fakeVideos) GetVideo(_ context.Context, req *videov1.GetVideoRequest) (*videov1.GetVideoResponse, error) {
	v := &videov1.Video{
		VideoId:   req.GetVideoId(),
		AuthorId:  userA,
		Title:     "first clip",
		Status:    videov1.VideoStatus_VIDEO_STATUS_UPLOADING,
		CreatedAt: timestamppb.New(createdAt),
	}
	if req.GetVideoId() == videoID {
		v.Status = videov1.VideoStatus_VIDEO_STATUS_READY
		v.Duration = durationpb.New(12345 * time.Millisecond)
		v.PlaylistKey = "media/" + videoID + "/master.m3u8"
		v.ThumbnailKey = "media/" + videoID + "/thumb.jpg"
		v.PublishedAt = timestamppb.New(publishedAt)
	}
	return &videov1.GetVideoResponse{Video: v}, nil
}

// GetPublicVideo answers the READY video videoID and VIDEO_NOT_FOUND for any other id, like
// video-service for a video that is not READY.
func (f fakeVideos) GetPublicVideo(ctx context.Context, req *videov1.GetPublicVideoRequest) (*videov1.GetPublicVideoResponse, error) {
	if req.GetVideoId() != videoID {
		return nil, grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found")
	}
	resp, _ := f.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: videoID})
	return &videov1.GetPublicVideoResponse{Video: resp.GetVideo()}, nil
}

// ListAuthorVideos answers two videos of author_id, the READY videoID and the UPLOADING
// videoID2, and nextCursor; or an empty last page for emptyCursor. Like video-service, it
// rejects a negative page_size.
func (f fakeVideos) ListAuthorVideos(ctx context.Context, req *videov1.ListAuthorVideosRequest) (*videov1.ListAuthorVideosResponse, error) {
	switch {
	case req.GetPageSize() < 0:
		return nil, grpcerr.New(codes.InvalidArgument, "INVALID_PAGE_SIZE", "page_size must not be negative")
	case req.GetPageToken() == emptyCursor:
		return &videov1.ListAuthorVideosResponse{}, nil
	}
	var videos []*videov1.Video
	for _, id := range []string{videoID, videoID2} {
		resp, _ := f.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: id})
		v := resp.GetVideo()
		v.AuthorId = req.GetAuthorId()
		videos = append(videos, v)
	}
	return &videov1.ListAuthorVideosResponse{Videos: videos, NextPageToken: nextCursor}, nil
}

// fakeFeed answers both feeds with the page of fakeFeedPage.
type fakeFeed struct {
	feedv1.UnimplementedFeedServiceServer
}

// fakeFeedPage returns two items and nextCursor, or an empty page for emptyCursor. Like
// feed-service, it rejects a negative page_size and a page_token longer than 64 characters.
func fakeFeedPage(size int32, token string) ([]*feedv1.FeedItem, string, error) {
	switch {
	case size < 0:
		return nil, "", grpcerr.New(codes.InvalidArgument, "INVALID_PAGE_SIZE", "page_size must not be negative")
	case len(token) > 64:
		return nil, "", grpcerr.New(codes.InvalidArgument, "INVALID_PAGE_TOKEN", "page_token is invalid")
	case token == emptyCursor:
		return nil, "", nil
	}
	items := []*feedv1.FeedItem{
		{
			VideoId:      videoID,
			AuthorId:     userB,
			Title:        "first clip",
			Duration:     durationpb.New(12345 * time.Millisecond),
			PlaylistKey:  "media/" + videoID + "/master.m3u8",
			ThumbnailKey: "media/" + videoID + "/thumb.jpg",
			PublishedAt:  timestamppb.New(publishedAt),
		},
		{
			VideoId:      videoID2,
			AuthorId:     userB,
			Title:        "second clip",
			Duration:     durationpb.New(2 * time.Second),
			PlaylistKey:  "media/" + videoID2 + "/master.m3u8",
			ThumbnailKey: "media/" + videoID2 + "/thumb.jpg",
			PublishedAt:  timestamppb.New(createdAt),
		},
	}
	return items, nextCursor, nil
}

func (fakeFeed) GetFollowingFeed(_ context.Context, req *feedv1.GetFollowingFeedRequest) (*feedv1.GetFollowingFeedResponse, error) {
	items, next, err := fakeFeedPage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	return &feedv1.GetFollowingFeedResponse{Items: items, NextPageToken: next}, nil
}

func (fakeFeed) GetExploreFeed(_ context.Context, req *feedv1.GetExploreFeedRequest) (*feedv1.GetExploreFeedResponse, error) {
	items, _, err := fakeFeedPage(req.GetPageSize(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	return &feedv1.GetExploreFeedResponse{Items: items}, nil
}

// fakeEngagement answers GetStats with one stats per id in request order: view_count 100*(i+1),
// like_count i+1 and liked_by_me for the first. setStats replaces that answer.
type fakeEngagement struct {
	engagementv1.UnimplementedEngagementServiceServer

	mu    sync.Mutex
	stats []*engagementv1.VideoStats
}

func (f *fakeEngagement) setStats(stats []*engagementv1.VideoStats) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stats = stats
}

func (*fakeEngagement) Like(context.Context, *engagementv1.LikeRequest) (*engagementv1.LikeResponse, error) {
	return &engagementv1.LikeResponse{}, nil
}

func (*fakeEngagement) Unlike(context.Context, *engagementv1.UnlikeRequest) (*engagementv1.UnlikeResponse, error) {
	return &engagementv1.UnlikeResponse{}, nil
}

func (*fakeEngagement) RecordView(context.Context, *engagementv1.RecordViewRequest) (*engagementv1.RecordViewResponse, error) {
	return &engagementv1.RecordViewResponse{}, nil
}

func (f *fakeEngagement) GetStats(_ context.Context, req *engagementv1.GetStatsRequest) (*engagementv1.GetStatsResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.stats != nil {
		return &engagementv1.GetStatsResponse{Stats: f.stats}, nil
	}
	var stats []*engagementv1.VideoStats
	for i, id := range req.GetVideoIds() {
		stats = append(stats, &engagementv1.VideoStats{
			VideoId:   id,
			ViewCount: int64(100 * (i + 1)),
			LikeCount: int64(i + 1),
			LikedByMe: i == 0,
		})
	}
	return &engagementv1.GetStatsResponse{Stats: stats}, nil
}

// env is the gateway handler in front of fake user, video, feed and engagement services.
type env struct {
	handler    http.Handler
	users      *backend
	videos     *backend
	feeds      *backend
	engagement *backend
	stats      *fakeEngagement
	key        ed25519.PrivateKey
}

// newEnv returns an env whose rate limits run as when Redis is down (see downLimits).
func newEnv(t *testing.T) *env {
	t.Helper()
	return newEnvWithLimits(t, downLimits(t))
}

// downLimits returns a Limiter whose Redis client is closed, so every call fails at once:
// soft-closed classes use their in-memory fallback and open classes let everything through.
func downLimits(t *testing.T) *ratelimit.Limiter {
	t.Helper()
	client := redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379"})
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	return ratelimit.New(client, "svp:test:down:")
}

// newEnvWithLimits returns an env with limits, whose connection to engagement-service is
// dialed with engagementOpts added. It trusts no proxy: the client is the connection.
func newEnvWithLimits(t *testing.T, limits *ratelimit.Limiter, engagementOpts ...grpc.DialOption) *env {
	t.Helper()
	return newEnvBehind(t, httpx.ClientAddr{}, limits, engagementOpts...)
}

// newEnvBehind is newEnvWithLimits finding the client's address with clientAddr.
func newEnvBehind(t *testing.T, clientAddr httpx.ClientAddr, limits *ratelimit.Limiter, engagementOpts ...grpc.DialOption) *env {
	t.Helper()
	return newEnvDialed(t, clientAddr, limits, nil, engagementOpts)
}

// newEnvDialed is newEnvBehind with userOpts added to the dial options of user-service too.
func newEnvDialed(t *testing.T, clientAddr httpx.ClientAddr, limits *ratelimit.Limiter, userOpts, engagementOpts []grpc.DialOption) *env {
	t.Helper()
	key, err := authtoken.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	users, userConn := startBackend(t, func(s *grpc.Server) { userv1.RegisterUserServiceServer(s, fakeUsers{}) }, userOpts...)
	videos, videoConn := startBackend(t, func(s *grpc.Server) { videov1.RegisterVideoServiceServer(s, fakeVideos{}) })
	feeds, feedConn := startBackend(t, func(s *grpc.Server) { feedv1.RegisterFeedServiceServer(s, fakeFeed{}) })
	stats := &fakeEngagement{}
	engagement, engagementConn := startBackend(t, func(s *grpc.Server) { engagementv1.RegisterEngagementServiceServer(s, stats) }, engagementOpts...)
	verifier := authtoken.NewVerifier(map[string]ed25519.PublicKey{testKID: key.Public().(ed25519.PublicKey)})
	return &env{
		handler:    New(userConn, videoConn, feedConn, engagementConn, verifier, mediaBase, limits, clientAddr, "gateway:8080"),
		users:      users,
		videos:     videos,
		feeds:      feeds,
		engagement: engagement,
		stats:      stats,
		key:        key,
	}
}

// callCount is the number of RPCs every fake service received.
func (e *env) callCount() int {
	return len(e.users.recorded()) + len(e.videos.recorded()) + len(e.feeds.recorded()) + len(e.engagement.recorded())
}

// token returns a valid access token for userID.
func (e *env) token(t *testing.T, userID string) string {
	t.Helper()
	tok, _, err := authtoken.NewIssuer(testKID, e.key).Issue(userID)
	if err != nil {
		t.Fatal(err)
	}
	return tok.Reveal()
}

// do sends a request with body (none when empty) and, when token is set, a Bearer token.
func (e *env) do(t *testing.T, method, path, body, token string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequestWithContext(t.Context(), method, path, nil)
	} else {
		r = httptest.NewRequestWithContext(t.Context(), method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	return rec
}

func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("body %q: %v", rec.Body.String(), err)
	}
	return v
}

type problem struct {
	Type    string `json:"type"`
	Title   string `json:"title"`
	Status  int    `json:"status"`
	Detail  string `json:"detail"`
	Code    string `json:"code"`
	TraceID string `json:"trace_id"`
}

// decodeProblem checks the problem+json content type and returns the body, which must carry a
// trace_id.
func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) problem {
	t.Helper()
	p := decodeUntracedProblem(t, rec)
	if p.TraceID == "" {
		t.Error("trace_id is empty")
	}
	return p
}

// decodeUntracedProblem is decodeProblem for the probes, which have no trace.
func decodeUntracedProblem(t *testing.T, rec *httptest.ResponseRecorder) problem {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("Content-Type = %q, want application/problem+json (body %q)", ct, rec.Body.String())
	}
	p := decode[problem](t, rec)
	if p.Status != rec.Code {
		t.Errorf("status field = %d, response status = %d", p.Status, rec.Code)
	}
	return p
}

// traceOf returns the trace a call's metadata carries; it is invalid when there is none.
func traceOf(md metadata.MD) trace.SpanContext {
	carrier := propagation.MapCarrier{}
	for _, v := range md.Get(traceparentKey) {
		carrier[traceparentKey] = v
	}
	return trace.SpanContextFromContext(propagation.TraceContext{}.Extract(context.Background(), carrier))
}

func wantStatus(t *testing.T, rec *httptest.ResponseRecorder, want int) {
	t.Helper()
	if rec.Code != want {
		t.Fatalf("status = %d, want %d (body %q)", rec.Code, want, rec.Body.String())
	}
}

func wantJSON(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
}

// captureLog points slog.Default at a logx JSON handler writing to the returned buffer until
// the test ends. Tests using it must not run in parallel.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(logx.NewHandler(slog.NewJSONHandler(&buf, nil))))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

func TestRegister(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/auth/register", `{"email":"a@example.com","password":"correct horse"}`, "")
	wantStatus(t, rec, http.StatusCreated)
	wantJSON(t, rec)
	if got := decode[map[string]string](t, rec); got["user_id"] != userA || len(got) != 1 {
		t.Errorf("body = %v, want {user_id: %s}", got, userA)
	}
	c := e.users.only(t)
	if c.method != userv1.UserService_Register_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if req := c.req.(*userv1.RegisterRequest); req.GetEmail() != "a@example.com" || req.GetPassword() != "correct horse" {
		t.Errorf("request = %v", req)
	}
}

func TestLogin(t *testing.T) {
	logs := captureLog(t)
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/auth/login", `{"email":"a@example.com","password":"correct horse"}`, "")
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
	got := decode[map[string]string](t, rec)
	wantTokenBody(t, got, fakeAccessToken, fakeRefreshToken)
	if req := e.users.only(t).req.(*userv1.LoginRequest); req.GetEmail() != "a@example.com" || req.GetPassword() != "correct horse" {
		t.Errorf("request = %v", req)
	}
	// The response carries tokens and the request a password and an email; none reaches the log.
	for _, s := range []string{fakeAccessToken, fakeRefreshToken, "correct horse", "a@example.com"} {
		if strings.Contains(logs.String(), s) {
			t.Errorf("log contains %q:\n%s", s, logs.String())
		}
	}
	if !strings.Contains(logs.String(), `"route":"POST /auth/login"`) {
		t.Errorf("no access log line for the login:\n%s", logs.String())
	}
}

// wantTokenBody checks got is the AccessToken schema with access and refresh, and nothing else.
func wantTokenBody(t *testing.T, got map[string]string, access, refresh string) {
	t.Helper()
	want := map[string]string{
		"access_token":       access,
		"token_type":         "Bearer",
		"expires_at":         "2026-10-11T02:00:00Z",
		"refresh_token":      refresh,
		"refresh_expires_at": "2026-10-25T01:00:00Z",
	}
	if len(got) != len(want) {
		t.Errorf("body = %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

// refreshBody is the body of /auth/refresh and /auth/logout with fakeRefreshToken.
const refreshBody = `{"refresh_token":"` + fakeRefreshToken + `"}`

func TestRefresh(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/auth/refresh", refreshBody, "")
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
	wantTokenBody(t, decode[map[string]string](t, rec), rotatedAccessToken, rotatedRefreshToken)
	c := e.users.only(t)
	if c.method != userv1.UserService_Refresh_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if got := c.req.(*userv1.RefreshRequest).GetRefreshToken(); got != fakeRefreshToken {
		t.Errorf("refresh_token = %q, want %q", got, fakeRefreshToken)
	}
}

func TestLogout(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/auth/logout", refreshBody, "")
	wantStatus(t, rec, http.StatusNoContent)
	if rec.Body.Len() != 0 {
		t.Errorf("body = %q, want empty", rec.Body.String())
	}
	c := e.users.only(t)
	if c.method != userv1.UserService_Logout_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if got := c.req.(*userv1.LogoutRequest).GetRefreshToken(); got != fakeRefreshToken {
		t.Errorf("refresh_token = %q, want %q", got, fakeRefreshToken)
	}
}

// TestRefreshAndLogoutBodies: a body that is not one JSON object of known fields is refused
// before any call, as on login; a missing or empty refresh_token goes on to user-service, which
// judges it like any other token.
func TestRefreshAndLogoutBodies(t *testing.T) {
	for _, path := range []string{"/auth/refresh", "/auth/logout"} {
		for _, tc := range []struct {
			name, body string
			status     int
			code       string
		}{
			{"empty", "", http.StatusBadRequest, "INVALID_JSON"},
			{"not JSON", "refresh_token=" + fakeRefreshToken, http.StatusBadRequest, "INVALID_JSON"},
			{"unknown field", `{"refresh_token":"x","user_id":"` + userA + `"}`, http.StatusBadRequest, "INVALID_JSON"},
			{"not a string", `{"refresh_token":42}`, http.StatusBadRequest, "INVALID_JSON"},
			{"too large", `{"refresh_token":"` + strings.Repeat("a", 64<<10) + `"}`, http.StatusRequestEntityTooLarge, "BODY_TOO_LARGE"},
		} {
			t.Run(path+" "+tc.name, func(t *testing.T) {
				e := newEnv(t)
				rec := e.send(t, "192.0.2.1:5000", http.MethodPost, path, tc.body, "", map[string]string{"Content-Type": "application/json"})
				wantStatus(t, rec, tc.status)
				p := decodeProblem(t, rec)
				if p.Code != tc.code {
					t.Errorf("code = %q, want %q", p.Code, tc.code)
				}
				if strings.Contains(rec.Body.String(), fakeRefreshToken) {
					t.Errorf("problem echoes the token: %s", rec.Body.String())
				}
				if n := e.callCount(); n != 0 {
					t.Errorf("services got %d calls, want 0", n)
				}
			})
		}
		for _, body := range []string{`{}`, `{"refresh_token":""}`} {
			t.Run(path+" "+body, func(t *testing.T) {
				e := newEnv(t)
				e.do(t, http.MethodPost, path, body, "")
				var got string
				switch req := e.users.only(t).req.(type) {
				case *userv1.RefreshRequest:
					got = req.GetRefreshToken()
				case *userv1.LogoutRequest:
					got = req.GetRefreshToken()
				}
				if got != "" {
					t.Errorf("refresh_token = %q, want empty", got)
				}
			})
		}
	}
}

func TestPublicRoutesSendNoUserID(t *testing.T) {
	e := newEnv(t)
	for _, rt := range []struct{ path, body string }{
		{"/auth/register", credentialsBody},
		{"/auth/login", credentialsBody},
		{"/auth/refresh", refreshBody},
		{"/auth/logout", refreshBody},
	} {
		// A token on a public route is ignored too.
		rec := e.do(t, http.MethodPost, rt.path, rt.body, e.token(t, userA))
		if rec.Code >= 300 {
			t.Fatalf("%s: status = %d", rt.path, rec.Code)
		}
	}
	for _, c := range e.users.recorded() {
		if v := c.md.Get(callerid.MetadataKey); len(v) != 0 {
			t.Errorf("%s got x-user-id %v", c.method, v)
		}
		if v := c.md.Get(traceparentKey); len(v) != 1 || !traceOf(c.md).IsValid() {
			t.Errorf("%s got traceparent %v, want one valid value", c.method, v)
		}
	}
}

func TestFollowAndUnfollow(t *testing.T) {
	for _, tc := range []struct {
		method, rpc string
	}{
		{http.MethodPut, userv1.UserService_Follow_FullMethodName},
		{http.MethodDelete, userv1.UserService_Unfollow_FullMethodName},
	} {
		t.Run(tc.method, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, tc.method, "/me/following/"+userB, "", e.token(t, userA))
			wantStatus(t, rec, http.StatusNoContent)
			if rec.Body.Len() != 0 {
				t.Errorf("body = %q, want empty", rec.Body.String())
			}
			c := e.users.only(t)
			if c.method != tc.rpc {
				t.Errorf("method = %s, want %s", c.method, tc.rpc)
			}
			followee := ""
			switch req := c.req.(type) {
			case *userv1.FollowRequest:
				followee = req.GetFolloweeId()
			case *userv1.UnfollowRequest:
				followee = req.GetFolloweeId()
			}
			if followee != userB {
				t.Errorf("followee_id = %q, want %q", followee, userB)
			}
			if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("x-user-id = %v, want [%s]", v, userA)
			}
		})
	}
}

func TestInitUpload(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/videos", `{"title":"first clip","size_bytes":1048576,"content_type":"video/mp4"}`, e.token(t, userA))
	wantStatus(t, rec, http.StatusCreated)
	wantJSON(t, rec)
	if loc := rec.Header().Get("Location"); loc != "/videos/"+videoID {
		t.Errorf("Location = %q", loc)
	}
	got := decode[struct {
		VideoID    string            `json:"video_id"`
		UploadURL  string            `json:"upload_url"`
		FormFields map[string]string `json:"form_fields"`
		ExpiresAt  string            `json:"expires_at"`
	}](t, rec)
	if got.VideoID != videoID || got.UploadURL != "http://127.0.0.1:9000/svp-uploads" || got.ExpiresAt != "2026-10-11T01:17:03Z" {
		t.Errorf("body = %+v", got)
	}
	if got.FormFields["key"] != "uploads/"+videoID || got.FormFields["x-amz-signature"] != uploadSecret || len(got.FormFields) != 2 {
		t.Errorf("form_fields = %v", got.FormFields)
	}
	c := e.videos.only(t)
	req := c.req.(*videov1.InitUploadRequest)
	if req.GetTitle() != "first clip" || req.GetSizeBytes() != 1048576 || req.GetContentType() != "video/mp4" {
		t.Errorf("request = %v", req)
	}
	if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
}

func TestInitUploadNilFormFieldsIsEmptyObject(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/videos", `{"title":"`+noFormFields+`","size_bytes":1048576,"content_type":"video/mp4"}`, e.token(t, userA))
	wantStatus(t, rec, http.StatusCreated)
	got := decode[map[string]json.RawMessage](t, rec)
	if string(got["form_fields"]) != "{}" {
		t.Errorf("form_fields = %s, want {}", got["form_fields"])
	}
}

// TestInitUploadKeepsCredentialOutOfLog is threat model UP-2: the presigned POST goes to the
// client only.
func TestInitUploadKeepsCredentialOutOfLog(t *testing.T) {
	logs := captureLog(t)
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/videos", `{"title":"first clip","size_bytes":1048576,"content_type":"video/mp4"}`, e.token(t, userA))
	wantStatus(t, rec, http.StatusCreated)
	if !strings.Contains(logs.String(), `"route":"POST /videos"`) {
		t.Errorf("no access log line for the request:\n%s", logs.String())
	}
	for _, s := range []string{uploadSecret, "svp-uploads", "x-amz-signature"} {
		if strings.Contains(logs.String(), s) {
			t.Errorf("log contains %q:\n%s", s, logs.String())
		}
	}
}

func TestInitUploadRejectsBadJSON(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/videos", `{"title":"x","owner":"someone"}`, e.token(t, userA))
	wantStatus(t, rec, http.StatusBadRequest)
	if p := decodeProblem(t, rec); p.Code != "INVALID_JSON" {
		t.Errorf("code = %q, want INVALID_JSON", p.Code)
	}
	if n := len(e.videos.recorded()); n != 0 {
		t.Errorf("video-service got %d calls, want 0", n)
	}
}

func TestGetVideo(t *testing.T) {
	e := newEnv(t)

	t.Run("ready", func(t *testing.T) {
		rec := e.do(t, http.MethodGet, "/videos/"+videoID, "", e.token(t, userA))
		wantStatus(t, rec, http.StatusOK)
		wantJSON(t, rec)
		got := decode[map[string]any](t, rec)
		want := map[string]any{
			"video_id":      videoID,
			"author_id":     userA,
			"title":         "first clip",
			"status":        "READY",
			"created_at":    "2026-10-11T01:02:03.456Z",
			"duration_ms":   float64(12345),
			"published_at":  "2026-10-11T01:05:00Z",
			"playlist_url":  mediaBase + "/media/" + videoID + "/master.m3u8",
			"thumbnail_url": mediaBase + "/media/" + videoID + "/thumb.jpg",
		}
		// The author and the stats, with liked_by_me, come from one call each.
		if len(got) != len(want)+2 {
			t.Errorf("body = %v, want %v with author and stats", got, want)
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("%s = %v, want %v", k, got[k], v)
			}
		}
		wantAuthor(t, got["author"], userA, "alice", "Alice")
		if st, _ := got["stats"].(map[string]any); len(st) != 3 || st["view_count"] != float64(100) || st["like_count"] != float64(1) || st["liked_by_me"] != true {
			t.Errorf("stats = %v", got["stats"])
		}
	})

	t.Run("uploading", func(t *testing.T) {
		const other = "01928c6e-7b3a-7cde-8f01-222222222222"
		rec := e.do(t, http.MethodGet, "/videos/"+other, "", e.token(t, userA))
		wantStatus(t, rec, http.StatusOK)
		got := decode[map[string]any](t, rec)
		if got["status"] != "UPLOADING" || got["video_id"] != other {
			t.Errorf("body = %v", got)
		}
		for _, k := range []string{"duration_ms", "published_at", "playlist_url", "thumbnail_url"} {
			if _, ok := got[k]; ok {
				t.Errorf("body has %s: %v", k, got)
			}
		}
		if _, ok := got["stats"]; !ok {
			t.Errorf("body has no stats: %v", got)
		}
	})

	calls := e.videos.recorded()
	if len(calls) != 2 || calls[0].req.(*videov1.GetVideoRequest).GetVideoId() != videoID {
		t.Errorf("calls = %+v", calls)
	}
	for _, b := range []struct {
		backend *backend
		method  string
	}{
		{e.users, userv1.UserService_GetProfiles_FullMethodName},
		{e.engagement, engagementv1.EngagementService_GetStats_FullMethodName},
	} {
		for _, c := range b.backend.recorded() {
			if c.method != b.method {
				t.Errorf("method = %s, want %s", c.method, b.method)
			}
			if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("%s x-user-id = %v, want [%s]", c.method, v, userA)
			}
		}
		if n := len(b.backend.recorded()); n != 2 {
			t.Errorf("%s calls = %d, want one per request", b.method, n)
		}
	}
}

// wantAuthor checks got is the author profile {user_id, handle, display_name}.
func wantAuthor(t *testing.T, got any, userID, handle, displayName string) {
	t.Helper()
	a, _ := got.(map[string]any)
	if len(a) != 3 || a["user_id"] != userID || a["handle"] != handle || a["display_name"] != displayName {
		t.Errorf("author = %v, want {%s %s %s}", got, userID, handle, displayName)
	}
}

func TestCompleteUpload(t *testing.T) {
	e := newEnv(t)

	t.Run("processing", func(t *testing.T) {
		rec := e.do(t, http.MethodPost, "/videos/"+videoID+"/complete", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusAccepted)
		wantJSON(t, rec)
		got := decode[map[string]any](t, rec)
		if got["status"] != "PROCESSING" || got["video_id"] != videoID {
			t.Errorf("body = %v", got)
		}
		for _, k := range []string{"duration_ms", "published_at", "playlist_url", "thumbnail_url"} {
			if _, ok := got[k]; ok {
				t.Errorf("body has %s: %v", k, got)
			}
		}
	})

	t.Run("repeat on a ready video", func(t *testing.T) {
		const other = "01928c6e-7b3a-7cde-8f01-222222222222"
		rec := e.do(t, http.MethodPost, "/videos/"+other+"/complete", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusAccepted)
		got := decode[map[string]any](t, rec)
		if got["status"] != "READY" || got["playlist_url"] != mediaBase+"/media/"+other+"/master.m3u8" {
			t.Errorf("body = %v", got)
		}
	})

	calls := e.videos.recorded()
	if len(calls) != 2 || calls[0].method != videov1.VideoService_CompleteUpload_FullMethodName {
		t.Fatalf("calls = %+v", calls)
	}
	if got := calls[0].req.(*videov1.CompleteUploadRequest).GetVideoId(); got != videoID {
		t.Errorf("video_id = %q, want %q", got, videoID)
	}
	if v := calls[0].md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
}

func TestCompleteUploadErrors(t *testing.T) {
	for _, tc := range []struct {
		name       string
		path       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"not found", "/videos/" + videoID + "/complete", grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found"), http.StatusNotFound, "VIDEO_NOT_FOUND"},
		{"malformed id", "/videos/NOT-a-uuid/complete", grpcerr.New(codes.InvalidArgument, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID"), http.StatusBadRequest, "INVALID_VIDEO_ID"},
		{"object missing", "/videos/" + videoID + "/complete", grpcerr.New(codes.FailedPrecondition, "UPLOAD_NOT_FOUND", "uploaded object not found"), http.StatusBadRequest, "UPLOAD_NOT_FOUND"},
		{"object mismatch", "/videos/" + videoID + "/complete", grpcerr.New(codes.FailedPrecondition, "UPLOAD_MISMATCH", "uploaded object does not match"), http.StatusBadRequest, "UPLOAD_MISMATCH"},
		{"video failed", "/videos/" + videoID + "/complete", grpcerr.New(codes.FailedPrecondition, "VIDEO_FAILED", "video failed"), http.StatusBadRequest, "VIDEO_FAILED"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			e.videos.fail(tc.err)
			rec := e.do(t, http.MethodPost, tc.path, "", e.token(t, userA))
			wantStatus(t, rec, tc.wantStatus)
			if p := decodeProblem(t, rec); p.Code != tc.wantCode {
				t.Errorf("code = %q, want %q", p.Code, tc.wantCode)
			}
			e.videos.only(t)
		})
	}
}

func TestHealthz(t *testing.T) {
	e := newEnv(t)
	// Liveness does not depend on the services.
	e.users.stop()
	e.videos.stop()
	rec := e.do(t, http.MethodGet, "/healthz", "", "")
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
}

func TestReadyz(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/readyz", "", "")
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
}

func TestReadyzNotReady(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(e *env)
	}{
		{"user-service not serving", func(e *env) {
			e.users.health.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)
		}},
		{"video-service not serving", func(e *env) {
			e.videos.health.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)
		}},
		{"video-service unreachable", func(e *env) { e.videos.stop() }},
		{"feed-service not serving", func(e *env) {
			e.feeds.health.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)
		}},
		{"feed-service unreachable", func(e *env) { e.feeds.stop() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logs := captureLog(t)
			e := newEnv(t)
			tc.setup(e)
			start := time.Now()
			rec := e.do(t, http.MethodGet, "/readyz", "", "")
			wantStatus(t, rec, http.StatusServiceUnavailable)
			if elapsed := time.Since(start); elapsed > readyTimeout+500*time.Millisecond {
				t.Errorf("readyz took %v", elapsed)
			}
			// /readyz is left out of tracing: its problem has an empty trace_id.
			p := decodeUntracedProblem(t, rec)
			if p.Code != "NOT_READY" || p.Detail != "" || p.TraceID != "" {
				t.Errorf("problem = %+v", p)
			}
			if !strings.Contains(logs.String(), "dependency not ready") {
				t.Errorf("log does not name the failing dependency:\n%s", logs.String())
			}
		})
	}
}

func TestAuthenticatedRoutesNeedToken(t *testing.T) {
	routes := []struct{ method, path, body string }{
		{http.MethodPut, "/me/following/" + userB, ""},
		{http.MethodDelete, "/me/following/" + userB, ""},
		{http.MethodPost, "/videos", `{"title":"x","size_bytes":1,"content_type":"video/mp4"}`},
		{http.MethodPost, "/videos/" + videoID + "/complete", ""},
		{http.MethodGet, "/videos/" + videoID, ""},
		{http.MethodPut, "/videos/" + videoID + "/like", ""},
		{http.MethodDelete, "/videos/" + videoID + "/like", ""},
		{http.MethodPost, "/videos/" + videoID + "/views", ""},
		{http.MethodGet, "/feed/following", ""},
		{http.MethodGet, "/feed/explore", ""},
		{http.MethodGet, "/me", ""},
		{http.MethodPatch, "/me", `{"display_name":"x"}`},
		{http.MethodGet, "/me/videos", ""},
		{http.MethodGet, "/profiles/bob", ""},
		{http.MethodGet, "/users/" + userB + "/videos", ""},
	}
	for _, rt := range routes {
		for _, token := range []string{"", "not-a-jwt"} {
			t.Run(rt.method+" "+rt.path+" token="+token, func(t *testing.T) {
				e := newEnv(t)
				rec := e.do(t, rt.method, rt.path, rt.body, token)
				wantStatus(t, rec, http.StatusUnauthorized)
				if p := decodeProblem(t, rec); p.Code != "INVALID_TOKEN" {
					t.Errorf("code = %q, want INVALID_TOKEN", p.Code)
				}
				if n := e.callCount(); n != 0 {
					t.Errorf("services got %d calls, want 0", n)
				}
			})
		}
	}
}

// TestOutgoingMetadataFromTokenOnly is threat model IN-1: the services receive the user id of
// the token and a traceparent the gateway made, never a client header.
func TestOutgoingMetadataFromTokenOnly(t *testing.T) {
	e := newEnv(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/videos/"+videoID, nil)
	r.Header.Set("Authorization", "Bearer "+e.token(t, userA))
	r.Header.Set("X-User-Id", userB)
	r.Header.Set("Traceparent", clientTraceparent)
	r.Header.Set("X-Foo", "bar")
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusOK)

	md := e.videos.only(t).md
	if v := md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
	tp := md.Get(traceparentKey)
	if len(tp) != 1 || tp[0] == clientTraceparent {
		t.Errorf("traceparent = %v, want one value made by the gateway", tp)
	} else if sc := traceOf(md); !sc.IsValid() || sc.TraceID().String() == clientTraceID {
		t.Errorf("traceparent %q is not valid or continues the client's trace", tp[0])
	}
	if v := md.Get("x-foo"); len(v) != 0 {
		t.Errorf("x-foo = %v, want none", v)
	}
	for k, vals := range md {
		for _, v := range vals {
			if v == userB || v == clientTraceparent || v == "bar" {
				t.Errorf("metadata %s carries client value %q", k, v)
			}
		}
	}
}

// TestCompleteUploadIgnoresClientUserID is threat model IN-1 on the complete route.
func TestCompleteUploadIgnoresClientUserID(t *testing.T) {
	e := newEnv(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/videos/"+videoID+"/complete", nil)
	r.Header.Set("Authorization", "Bearer "+e.token(t, userA))
	r.Header.Set("X-User-Id", userB)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusAccepted)
	if v := e.videos.only(t).md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
}

func TestServiceErrors(t *testing.T) {
	for _, tc := range []struct {
		name               string
		method, path, body string
		authed             bool
		videoBackend       bool
		err                error
		wantStatus         int
		wantCode           string
		wantDetail         string
	}{
		{
			name:   "email already registered",
			method: http.MethodPost, path: "/auth/register", body: `{"email":"a@example.com","password":"correct horse"}`,
			err:        grpcerr.New(codes.AlreadyExists, "EMAIL_ALREADY_REGISTERED", "email is already registered"),
			wantStatus: http.StatusConflict, wantCode: "EMAIL_ALREADY_REGISTERED", wantDetail: "email is already registered",
		},
		{
			name:   "invalid credentials",
			method: http.MethodPost, path: "/auth/login", body: `{"email":"a@example.com","password":"wrong password"}`,
			err:        grpcerr.New(codes.Unauthenticated, "INVALID_CREDENTIALS", "invalid email or password"),
			wantStatus: http.StatusUnauthorized, wantCode: "INVALID_CREDENTIALS", wantDetail: "invalid email or password",
		},
		{
			name:   "invalid refresh token",
			method: http.MethodPost, path: "/auth/refresh", body: refreshBody,
			err:        grpcerr.New(codes.Unauthenticated, "INVALID_REFRESH_TOKEN", "invalid refresh token"),
			wantStatus: http.StatusUnauthorized, wantCode: "INVALID_REFRESH_TOKEN", wantDetail: "invalid refresh token",
		},
		{
			name:   "refresh with user-service unavailable",
			method: http.MethodPost, path: "/auth/refresh", body: refreshBody,
			err:        status.Error(codes.Unavailable, "user-service is down"),
			wantStatus: http.StatusServiceUnavailable, wantCode: "UNAVAILABLE", wantDetail: "",
		},
		{
			name:   "logout with user-service unavailable",
			method: http.MethodPost, path: "/auth/logout", body: refreshBody,
			err:        status.Error(codes.Unavailable, "user-service is down"),
			wantStatus: http.StatusServiceUnavailable, wantCode: "UNAVAILABLE", wantDetail: "",
		},
		{
			name:   "video not found",
			method: http.MethodGet, path: "/videos/" + videoID, authed: true, videoBackend: true,
			err:        grpcerr.New(codes.NotFound, "VIDEO_NOT_FOUND", "video not found"),
			wantStatus: http.StatusNotFound, wantCode: "VIDEO_NOT_FOUND", wantDetail: "video not found",
		},
		{
			name:   "invalid video argument",
			method: http.MethodPost, path: "/videos", body: `{"title":"","size_bytes":0,"content_type":"text/plain"}`, authed: true, videoBackend: true,
			err:        grpcerr.New(codes.InvalidArgument, "INVALID_TITLE", "title must be 1 to 200 characters"),
			wantStatus: http.StatusBadRequest, wantCode: "INVALID_TITLE", wantDetail: "title must be 1 to 200 characters",
		},
		{
			name:   "status without reason",
			method: http.MethodDelete, path: "/me/following/" + userB, authed: true,
			err:        status.Error(codes.PermissionDenied, "not allowed"),
			wantStatus: http.StatusForbidden, wantCode: "PERMISSION_DENIED", wantDetail: "not allowed",
		},
		{
			name:   "internal error hides the message",
			method: http.MethodPut, path: "/me/following/" + userB, authed: true,
			err:        grpcerr.New(codes.Internal, "DB_DOWN", "dial tcp 10.0.0.5:5432: connection refused"),
			wantStatus: http.StatusInternalServerError, wantCode: "INTERNAL", wantDetail: "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			b := e.users
			if tc.videoBackend {
				b = e.videos
			}
			b.fail(tc.err)
			token := ""
			if tc.authed {
				token = e.token(t, userA)
			}
			rec := e.do(t, tc.method, tc.path, tc.body, token)
			wantStatus(t, rec, tc.wantStatus)
			p := decodeProblem(t, rec)
			if p.Code != tc.wantCode || p.Detail != tc.wantDetail {
				t.Errorf("code, detail = %q, %q; want %q, %q", p.Code, p.Detail, tc.wantCode, tc.wantDetail)
			}
			if strings.Contains(rec.Body.String(), "10.0.0.5") || strings.Contains(rec.Body.String(), "DB_DOWN") {
				t.Errorf("body leaks the internal error: %s", rec.Body.String())
			}
			b.only(t)
		})
	}
}

// TestMalformedFolloweePassedThrough checks the gateway leaves validation to the service: a
// malformed user_id reaches user-service unchanged and its INVALID_ARGUMENT becomes a 400.
func TestMalformedFolloweePassedThrough(t *testing.T) {
	e := newEnv(t)
	e.users.setHook(func(context.Context, string) error {
		return grpcerr.New(codes.InvalidArgument, "INVALID_FOLLOWEE_ID", "followee_id must be a canonical lowercase UUID")
	})
	rec := e.do(t, http.MethodPut, "/me/following/NOT-a-uuid", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusBadRequest)
	if p := decodeProblem(t, rec); p.Code != "INVALID_FOLLOWEE_ID" {
		t.Errorf("code = %q", p.Code)
	}
	if got := e.users.only(t).req.(*userv1.FollowRequest).GetFolloweeId(); got != "NOT-a-uuid" {
		t.Errorf("followee_id = %q, want NOT-a-uuid", got)
	}
}

// TestSlowServiceTimesOut waits out the real 3 s call deadline.
func TestSlowServiceTimesOut(t *testing.T) {
	e := newEnv(t)
	// The hook runs on a server goroutine; a channel hands the deadline it saw to the test.
	seen := make(chan time.Duration, 1)
	e.videos.setHook(func(ctx context.Context, _ string) error {
		d, _ := ctx.Deadline()
		seen <- time.Until(d)
		<-ctx.Done()
		return status.FromContextError(ctx.Err()).Err()
	})
	start := time.Now()
	rec := e.do(t, http.MethodGet, "/videos/"+videoID, "", e.token(t, userA))
	elapsed := time.Since(start)
	wantStatus(t, rec, http.StatusGatewayTimeout)
	if p := decodeProblem(t, rec); p.Code != "DEADLINE_EXCEEDED" || p.Detail != "" {
		t.Errorf("problem = %+v", p)
	}
	if deadline := <-seen; deadline <= callTimeout-time.Second || deadline > callTimeout {
		t.Errorf("service saw a deadline %v away, want about %v", deadline, callTimeout)
	}
	if elapsed < callTimeout || elapsed > callTimeout+time.Second {
		t.Errorf("request took %v, want about %v", elapsed, callTimeout)
	}
}

func TestUnmatchedRouteIsProblem(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/me/following", "", "")
	wantStatus(t, rec, http.StatusNotFound)
	if p := decodeProblem(t, rec); p.Code != "NOT_FOUND" {
		t.Errorf("404 code = %q, want NOT_FOUND", p.Code)
	}

	rec = e.do(t, http.MethodPatch, "/videos/"+videoID, "", "")
	wantStatus(t, rec, http.StatusMethodNotAllowed)
	if p := decodeProblem(t, rec); p.Code != "METHOD_NOT_ALLOWED" {
		t.Errorf("405 code = %q, want METHOD_NOT_ALLOWED", p.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("Allow = %q, want %q", allow, "GET, HEAD")
	}
}

// wantFeedItem checks the fields of item shared by every fakeFeed page; stats are checked apart.
func wantFeedItem(t *testing.T, item map[string]any, want map[string]any) {
	t.Helper()
	for k, v := range want {
		if item[k] != v {
			t.Errorf("%s = %v, want %v", k, item[k], v)
		}
	}
}

func TestFeed(t *testing.T) {
	for _, tc := range []struct {
		path, rpc, wantNext string
	}{
		{"/feed/following", feedv1.FeedService_GetFollowingFeed_FullMethodName, nextCursor},
		{"/feed/explore", feedv1.FeedService_GetExploreFeed_FullMethodName, ""},
	} {
		t.Run(tc.path, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, tc.path+"?page_size=5&cursor=abc", "", e.token(t, userA))
			wantStatus(t, rec, http.StatusOK)
			wantJSON(t, rec)
			got := decode[struct {
				Items      []map[string]any `json:"items"`
				NextCursor *string          `json:"next_cursor"`
			}](t, rec)
			if got.NextCursor == nil || *got.NextCursor != tc.wantNext {
				t.Errorf("next_cursor = %v, want %q", got.NextCursor, tc.wantNext)
			}
			if len(got.Items) != 2 {
				t.Fatalf("items = %v, want 2", got.Items)
			}
			first := got.Items[0]
			if len(first) != 9 {
				t.Errorf("item has %d fields, want 9: %v", len(first), first)
			}
			wantAuthor(t, first["author"], userB, "bob", "Bob B")
			wantAuthor(t, got.Items[1]["author"], userB, "bob", "Bob B")
			wantFeedItem(t, first, map[string]any{
				"video_id":      videoID,
				"author_id":     userB,
				"title":         "first clip",
				"duration_ms":   float64(12345),
				"published_at":  "2026-10-11T01:05:00Z",
				"playlist_url":  mediaBase + "/media/" + videoID + "/master.m3u8",
				"thumbnail_url": mediaBase + "/media/" + videoID + "/thumb.jpg",
			})
			wantStats := map[string]any{"view_count": float64(100), "like_count": float64(1), "liked_by_me": true}
			if st, _ := first["stats"].(map[string]any); len(st) != len(wantStats) {
				t.Errorf("stats = %v, want %v", first["stats"], wantStats)
			} else {
				wantFeedItem(t, st, wantStats)
			}
			second := got.Items[1]
			wantFeedItem(t, second, map[string]any{"video_id": videoID2, "duration_ms": float64(2000), "published_at": "2026-10-11T01:02:03.456Z"})
			if st, _ := second["stats"].(map[string]any); st["view_count"] != float64(200) || st["liked_by_me"] != false {
				t.Errorf("second stats = %v", second["stats"])
			}

			c := e.feeds.only(t)
			if c.method != tc.rpc {
				t.Errorf("method = %s, want %s", c.method, tc.rpc)
			}
			req := c.req.(interface {
				GetPageSize() int32
				GetPageToken() string
			})
			if req.GetPageSize() != 5 || req.GetPageToken() != "abc" {
				t.Errorf("page_size, page_token = %d, %q; want 5, abc", req.GetPageSize(), req.GetPageToken())
			}
			if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("feed x-user-id = %v, want [%s]", v, userA)
			}
			s := e.engagement.only(t)
			if s.method != engagementv1.EngagementService_GetStats_FullMethodName {
				t.Errorf("engagement method = %s", s.method)
			}
			if ids := s.req.(*engagementv1.GetStatsRequest).GetVideoIds(); !slices.Equal(ids, []string{videoID, videoID2}) {
				t.Errorf("GetStats video_ids = %v", ids)
			}
			if v := s.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("engagement x-user-id = %v, want [%s]", v, userA)
			}
			// Both items have one author: GetProfiles is asked for it once.
			p := e.users.only(t)
			if p.method != userv1.UserService_GetProfiles_FullMethodName {
				t.Errorf("user method = %s", p.method)
			}
			if ids := p.req.(*userv1.GetProfilesRequest).GetUserIds(); !slices.Equal(ids, []string{userB}) {
				t.Errorf("GetProfiles user_ids = %v, want [%s]", ids, userB)
			}
		})
	}
}

func TestFeedWithoutQuery(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/feed/following", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	req := e.feeds.only(t).req.(*feedv1.GetFollowingFeedRequest)
	if req.GetPageSize() != 0 || req.GetPageToken() != "" {
		t.Errorf("request = %v, want page_size 0 and no page_token", req)
	}
}

func TestFeedEmptyPage(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/feed/following?cursor="+emptyCursor, "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	got := decode[map[string]json.RawMessage](t, rec)
	if string(got["items"]) != "[]" || string(got["next_cursor"]) != `""` {
		t.Errorf("body = %s, want items [] and next_cursor \"\"", rec.Body.String())
	}
	if n := len(e.engagement.recorded()) + len(e.users.recorded()); n != 0 {
		t.Errorf("engagement-service and user-service got %d calls for an empty page, want 0", n)
	}
}

// TestFeedStatsMatchedByVideoID gives GetStats an answer in another order, missing one item and
// with an id not on the page.
func TestFeedStatsMatchedByVideoID(t *testing.T) {
	e := newEnv(t)
	e.stats.setStats([]*engagementv1.VideoStats{
		{VideoId: "01928c6e-7b3a-7cde-8f01-999999999999", ViewCount: 9},
		{VideoId: videoID2, ViewCount: 42, LikeCount: 3, LikedByMe: true},
	})
	rec := e.do(t, http.MethodGet, "/feed/explore", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Items []map[string]any `json:"items"`
	}](t, rec)
	if len(got.Items) != 2 {
		t.Fatalf("items = %v", got.Items)
	}
	if st, ok := got.Items[0]["stats"]; ok {
		t.Errorf("item %s has stats %v, want none", videoID, st)
	}
	st, _ := got.Items[1]["stats"].(map[string]any)
	if st["view_count"] != float64(42) || st["like_count"] != float64(3) || st["liked_by_me"] != true {
		t.Errorf("item %s stats = %v", videoID2, got.Items[1]["stats"])
	}
}

// TestFeedWithoutStatsWhenEngagementFails is graceful degradation (architecture §7.2): the feed
// answers 200 without stats, about statsTimeout at most, and the error is only logged.
func TestFeedWithoutStatsWhenEngagementFails(t *testing.T) {
	const internalMessage = "dial tcp 10.0.0.9:5432: connection refused"
	for _, tc := range []struct {
		name  string
		setup func(e *env, seen chan<- time.Duration)
	}{
		{"error", func(e *env, _ chan<- time.Duration) {
			e.engagement.fail(status.Error(codes.Internal, internalMessage))
		}},
		{"slower than the timeout", func(e *env, seen chan<- time.Duration) {
			e.engagement.setHook(func(ctx context.Context, _ string) error {
				d, _ := ctx.Deadline()
				seen <- time.Until(d)
				// The server-side deadline can fire just before the gateway's own timer. Answering
				// with success then lets stats reach the gateway in time on a busy machine, so the
				// fake fails like a real handler cut off by its deadline.
				select {
				case <-time.After(300 * time.Millisecond):
				case <-ctx.Done():
				}
				return ctx.Err()
			})
		}},
		{"unreachable", func(e *env, _ chan<- time.Duration) { e.engagement.stop() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logs := captureLog(t)
			e := newEnv(t)
			seen := make(chan time.Duration, 1)
			tc.setup(e, seen)
			token := e.token(t, userA)
			start := time.Now()
			rec := e.do(t, http.MethodGet, "/feed/following", "", token)
			elapsed := time.Since(start)
			wantStatus(t, rec, http.StatusOK)
			got := decode[struct {
				Items      []map[string]any `json:"items"`
				NextCursor string           `json:"next_cursor"`
			}](t, rec)
			if len(got.Items) != 2 || got.NextCursor != nextCursor {
				t.Fatalf("body = %s", rec.Body.String())
			}
			for _, item := range got.Items {
				if st, ok := item["stats"]; ok {
					t.Errorf("item %v has stats %v, want none", item["video_id"], st)
				}
			}
			// The feed fake answers at once, so the request costs about the stats timeout at most.
			if elapsed > statsTimeout+150*time.Millisecond {
				t.Errorf("request took %v, want about %v at most", elapsed, statsTimeout)
			}
			select {
			case d := <-seen:
				if d > statsTimeout || d <= 0 {
					t.Errorf("engagement-service saw a deadline %v away, want at most %v", d, statsTimeout)
				}
			default:
			}
			if strings.Contains(rec.Body.String(), "10.0.0.9") {
				t.Errorf("body leaks the internal error: %s", rec.Body.String())
			}
			if !strings.Contains(logs.String(), `"level":"WARN","msg":"served without stats"`) {
				t.Errorf("no WARN about the missing stats:\n%s", logs.String())
			}
			if strings.Contains(logs.String(), token) {
				t.Errorf("log contains the access token:\n%s", logs.String())
			}
		})
	}
}

func TestFeedInvalidPageSize(t *testing.T) {
	for _, size := range []string{"abc", "1.5", "99999999999"} {
		t.Run(size, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, "/feed/following?page_size="+size, "", e.token(t, userA))
			wantStatus(t, rec, http.StatusBadRequest)
			if p := decodeProblem(t, rec); p.Code != "INVALID_PAGE_SIZE" {
				t.Errorf("code = %q, want INVALID_PAGE_SIZE", p.Code)
			}
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}

	t.Run("negative goes to feed-service", func(t *testing.T) {
		e := newEnv(t)
		rec := e.do(t, http.MethodGet, "/feed/explore?page_size=-1", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusBadRequest)
		if p := decodeProblem(t, rec); p.Code != "INVALID_PAGE_SIZE" {
			t.Errorf("code = %q, want INVALID_PAGE_SIZE", p.Code)
		}
		if got := e.feeds.only(t).req.(*feedv1.GetExploreFeedRequest).GetPageSize(); got != -1 {
			t.Errorf("page_size = %d, want -1", got)
		}
		if n := len(e.engagement.recorded()); n != 0 {
			t.Errorf("engagement-service got %d calls, want 0", n)
		}
	})
}

// TestFeedLongCursorPassedThrough checks the gateway never reads the cursor: feed-service gets
// it unchanged and rejects it.
func TestFeedLongCursorPassedThrough(t *testing.T) {
	e := newEnv(t)
	cursor := strings.Repeat("A", 500)
	rec := e.do(t, http.MethodGet, "/feed/following?cursor="+cursor, "", e.token(t, userA))
	wantStatus(t, rec, http.StatusBadRequest)
	if p := decodeProblem(t, rec); p.Code != "INVALID_PAGE_TOKEN" {
		t.Errorf("code = %q, want INVALID_PAGE_TOKEN", p.Code)
	}
	if got := e.feeds.only(t).req.(*feedv1.GetFollowingFeedRequest).GetPageToken(); got != cursor {
		t.Errorf("page_token has %d characters, want the %d of the cursor", len(got), len(cursor))
	}
}

// TestFeedServiceErrorIsMapped: unlike engagement-service, a feed-service error fails the request
// through the §8.4 table.
func TestFeedServiceErrorIsMapped(t *testing.T) {
	e := newEnv(t)
	e.feeds.fail(grpcerr.New(codes.Unavailable, "DB_DOWN", "dial tcp 10.0.0.5:5432: connection refused"))
	rec := e.do(t, http.MethodGet, "/feed/following", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusServiceUnavailable)
	if p := decodeProblem(t, rec); p.Code != "UNAVAILABLE" || p.Detail != "" {
		t.Errorf("problem = %+v", p)
	}
	if strings.Contains(rec.Body.String(), "10.0.0.5") || strings.Contains(rec.Body.String(), "DB_DOWN") {
		t.Errorf("body leaks the internal error: %s", rec.Body.String())
	}
	if n := len(e.engagement.recorded()); n != 0 {
		t.Errorf("engagement-service got %d calls, want 0", n)
	}
}

// TestLikeUnlikeAndView also checks threat model IN-1 on these routes: a client X-User-Id header
// never reaches engagement-service.
func TestLikeUnlikeAndView(t *testing.T) {
	for _, tc := range []struct {
		method, path, rpc string
		wantStatus        int
	}{
		{http.MethodPut, "/videos/" + videoID + "/like", engagementv1.EngagementService_Like_FullMethodName, http.StatusNoContent},
		{http.MethodDelete, "/videos/" + videoID + "/like", engagementv1.EngagementService_Unlike_FullMethodName, http.StatusNoContent},
		{http.MethodPost, "/videos/" + videoID + "/views", engagementv1.EngagementService_RecordView_FullMethodName, http.StatusAccepted},
	} {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			e := newEnv(t)
			r := httptest.NewRequestWithContext(t.Context(), tc.method, tc.path, nil)
			r.Header.Set("Authorization", "Bearer "+e.token(t, userA))
			r.Header.Set("X-User-Id", userB)
			rec := httptest.NewRecorder()
			e.handler.ServeHTTP(rec, r)
			wantStatus(t, rec, tc.wantStatus)
			if rec.Body.Len() != 0 {
				t.Errorf("body = %q, want empty", rec.Body.String())
			}
			c := e.engagement.only(t)
			if c.method != tc.rpc {
				t.Errorf("method = %s, want %s", c.method, tc.rpc)
			}
			if got := c.req.(interface{ GetVideoId() string }).GetVideoId(); got != videoID {
				t.Errorf("video_id = %q, want %q", got, videoID)
			}
			if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("x-user-id = %v, want [%s]", v, userA)
			}
		})
	}
}

func TestEngagementErrors(t *testing.T) {
	invalidID := grpcerr.New(codes.InvalidArgument, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID")
	for _, tc := range []struct {
		name         string
		method, path string
		err          error
		wantStatus   int
		wantCode     string
		wantDetail   string
	}{
		{"like malformed id", http.MethodPut, "/videos/NOT-a-uuid/like", invalidID, http.StatusBadRequest, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID"},
		{"unlike malformed id", http.MethodDelete, "/videos/NOT-a-uuid/like", invalidID, http.StatusBadRequest, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID"},
		{"view malformed id", http.MethodPost, "/videos/NOT-a-uuid/views", invalidID, http.StatusBadRequest, "INVALID_VIDEO_ID", "video_id must be a canonical lowercase UUID"},
		{
			"view broker down", http.MethodPost, "/videos/" + videoID + "/views",
			grpcerr.New(codes.Unavailable, "BROKER_DOWN", "produce to redpanda:9092 failed"),
			http.StatusServiceUnavailable, "UNAVAILABLE", "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			e.engagement.fail(tc.err)
			rec := e.do(t, tc.method, tc.path, "", e.token(t, userA))
			wantStatus(t, rec, tc.wantStatus)
			p := decodeProblem(t, rec)
			if p.Code != tc.wantCode || p.Detail != tc.wantDetail {
				t.Errorf("code, detail = %q, %q; want %q, %q", p.Code, p.Detail, tc.wantCode, tc.wantDetail)
			}
			if strings.Contains(rec.Body.String(), "redpanda") || strings.Contains(rec.Body.String(), "BROKER_DOWN") {
				t.Errorf("body leaks the internal error: %s", rec.Body.String())
			}
			want := videoID
			if strings.Contains(tc.path, "NOT-a-uuid") {
				want = "NOT-a-uuid"
			}
			if got := e.engagement.only(t).req.(interface{ GetVideoId() string }).GetVideoId(); got != want {
				t.Errorf("video_id = %q, want %q", got, want)
			}
		})
	}
}

// TestFeedIgnoresClientUserID is threat model IN-1 on the feed: both services get the user id
// of the token and no client header.
func TestFeedIgnoresClientUserID(t *testing.T) {
	e := newEnv(t)
	r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/feed/following", nil)
	r.Header.Set("Authorization", "Bearer "+e.token(t, userA))
	r.Header.Set("X-User-Id", userB)
	r.Header.Set("Traceparent", clientTraceparent)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	wantStatus(t, rec, http.StatusOK)
	for _, c := range []call{e.feeds.only(t), e.engagement.only(t)} {
		if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
			t.Errorf("%s x-user-id = %v, want [%s]", c.method, v, userA)
		}
		if tp := c.md.Get(traceparentKey); len(tp) != 1 || tp[0] == clientTraceparent || traceOf(c.md).TraceID().String() == clientTraceID {
			t.Errorf("%s traceparent = %v, want one value made by the gateway", c.method, tp)
		}
	}
}

// TestReadyzIgnoresEngagement: engagement-service down only takes the stats off the feed, so the
// gateway stays ready.
func TestReadyzIgnoresEngagement(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(e *env)
	}{
		{"not serving", func(e *env) {
			e.engagement.health.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)
		}},
		{"unreachable", func(e *env) { e.engagement.stop() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			tc.setup(e)
			rec := e.do(t, http.MethodGet, "/readyz", "", "")
			wantStatus(t, rec, http.StatusOK)
		})
	}
}

// TestInvalidUTF8IsBadRequest: a path or query that is not valid UTF-8 cannot go into a proto3
// string field (grpc-go refuses to marshal it and the call fails as INTERNAL), so the gateway
// answers 400 itself and calls no service.
func TestInvalidUTF8IsBadRequest(t *testing.T) {
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/feed/following?cursor=%FF"},
		{http.MethodGet, "/feed/explore?cursor=%C3%28"},
		{http.MethodGet, "/feed/following?%FF=1"},
		{http.MethodPut, "/videos/%FF/like"},
		{http.MethodDelete, "/videos/%FF/like"},
		{http.MethodPost, "/videos/%FF/views"},
		{http.MethodGet, "/videos/%FF"},
		{http.MethodPost, "/videos/%FF/complete"},
		{http.MethodPut, "/me/following/%FF"},
		{http.MethodDelete, "/me/following/%FF"},
		{http.MethodGet, "/profiles/%FF"},
		{http.MethodGet, "/users/%FF/videos"},
		{http.MethodGet, "/me/videos?cursor=%FF"},
		{http.MethodGet, "/public/videos/%FF"},
	} {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, tc.method, tc.path, "", e.token(t, userA))
			wantStatus(t, rec, http.StatusBadRequest)
			if p := decodeProblem(t, rec); p.Code != "INVALID_UTF8" {
				t.Errorf("code = %q, want INVALID_UTF8", p.Code)
			}
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}
}
