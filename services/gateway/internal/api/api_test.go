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

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

const (
	testKID = "k1"
	userA   = "01928c6e-7b3a-7cde-8f01-23456789abcd"
	userB   = "01928c6e-7b3a-7cde-8f01-000000000000"
	videoID = "01928c6e-7b3a-7cde-8f01-111111111111"
	// clientTraceparent is a valid traceparent a client might send; it must never be used.
	clientTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	fakeAccessToken   = "fake.access.token"
)

var (
	createdAt   = time.Date(2026, 10, 11, 1, 2, 3, 456000000, time.UTC)
	publishedAt = time.Date(2026, 10, 11, 1, 5, 0, 0, time.UTC)
	tokenExpiry = time.Date(2026, 10, 11, 2, 0, 0, 0, time.UTC)
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
// connection to it.
func startBackend(t *testing.T, register func(*grpc.Server)) (*backend, *grpc.ClientConn) {
	t.Helper()
	b := &backend{health: health.NewServer()}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.UnaryInterceptor(b.intercept))
	healthpb.RegisterHealthServer(srv, b.health)
	register(srv)
	go func() { _ = srv.Serve(lis) }()
	b.stop = srv.Stop
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return b, conn
}

type fakeUsers struct {
	userv1.UnimplementedUserServiceServer
}

func (fakeUsers) Register(context.Context, *userv1.RegisterRequest) (*userv1.RegisterResponse, error) {
	return &userv1.RegisterResponse{UserId: userA}, nil
}

func (fakeUsers) Login(context.Context, *userv1.LoginRequest) (*userv1.LoginResponse, error) {
	return &userv1.LoginResponse{AccessToken: fakeAccessToken, ExpiresAt: timestamppb.New(tokenExpiry)}, nil
}

func (fakeUsers) Follow(context.Context, *userv1.FollowRequest) (*userv1.FollowResponse, error) {
	return &userv1.FollowResponse{}, nil
}

func (fakeUsers) Unfollow(context.Context, *userv1.UnfollowRequest) (*userv1.UnfollowResponse, error) {
	return &userv1.UnfollowResponse{}, nil
}

// fakeVideos answers GetVideo with a READY video for videoID and an UPLOADING one otherwise.
type fakeVideos struct {
	videov1.UnimplementedVideoServiceServer
}

func (fakeVideos) InitUpload(context.Context, *videov1.InitUploadRequest) (*videov1.InitUploadResponse, error) {
	return &videov1.InitUploadResponse{VideoId: videoID}, nil
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
		v.PublishedAt = timestamppb.New(publishedAt)
	}
	return &videov1.GetVideoResponse{Video: v}, nil
}

// env is the gateway handler in front of fake user and video services.
type env struct {
	handler http.Handler
	users   *backend
	videos  *backend
	key     ed25519.PrivateKey
}

func newEnv(t *testing.T) *env {
	t.Helper()
	key, err := authtoken.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	users, userConn := startBackend(t, func(s *grpc.Server) { userv1.RegisterUserServiceServer(s, fakeUsers{}) })
	videos, videoConn := startBackend(t, func(s *grpc.Server) { videov1.RegisterVideoServiceServer(s, fakeVideos{}) })
	verifier := authtoken.NewVerifier(map[string]ed25519.PublicKey{testKID: key.Public().(ed25519.PublicKey)})
	return &env{handler: New(userConn, videoConn, verifier), users: users, videos: videos, key: key}
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

func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) problem {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("Content-Type = %q, want application/problem+json (body %q)", ct, rec.Body.String())
	}
	p := decode[problem](t, rec)
	if p.Status != rec.Code {
		t.Errorf("status field = %d, response status = %d", p.Status, rec.Code)
	}
	if p.TraceID == "" {
		t.Error("trace_id is empty")
	}
	return p
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
	want := map[string]string{
		"access_token": fakeAccessToken,
		"token_type":   "Bearer",
		"expires_at":   "2026-10-11T02:00:00Z",
	}
	if len(got) != len(want) {
		t.Errorf("body = %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	if req := e.users.only(t).req.(*userv1.LoginRequest); req.GetEmail() != "a@example.com" || req.GetPassword() != "correct horse" {
		t.Errorf("request = %v", req)
	}
	// The response carries a token and the request a password and an email; none reaches the log.
	for _, s := range []string{fakeAccessToken, "correct horse", "a@example.com"} {
		if strings.Contains(logs.String(), s) {
			t.Errorf("log contains %q:\n%s", s, logs.String())
		}
	}
	if !strings.Contains(logs.String(), `"route":"POST /auth/login"`) {
		t.Errorf("no access log line for the login:\n%s", logs.String())
	}
}

func TestPublicRoutesSendNoUserID(t *testing.T) {
	e := newEnv(t)
	body := `{"email":"a@example.com","password":"correct horse"}`
	for _, path := range []string{"/auth/register", "/auth/login"} {
		// A token on a public route is ignored too.
		rec := e.do(t, http.MethodPost, path, body, e.token(t, userA))
		if rec.Code >= 300 {
			t.Fatalf("%s: status = %d", path, rec.Code)
		}
	}
	for _, c := range e.users.recorded() {
		if v := c.md.Get(callerid.MetadataKey); len(v) != 0 {
			t.Errorf("%s got x-user-id %v", c.method, v)
		}
		if v := c.md.Get(traceparent.MetadataKey); len(v) != 1 {
			t.Errorf("%s got traceparent %v, want one value", c.method, v)
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
	if got := decode[map[string]string](t, rec); got["video_id"] != videoID || len(got) != 1 {
		t.Errorf("body = %v, want {video_id: %s}", got, videoID)
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
			"video_id":     videoID,
			"author_id":    userA,
			"title":        "first clip",
			"status":       "READY",
			"created_at":   "2026-10-11T01:02:03.456Z",
			"duration_ms":  float64(12345),
			"published_at": "2026-10-11T01:05:00Z",
		}
		if len(got) != len(want) {
			t.Errorf("body = %v, want %v", got, want)
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("%s = %v, want %v", k, got[k], v)
			}
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
	})

	calls := e.videos.recorded()
	if len(calls) != 2 || calls[0].req.(*videov1.GetVideoRequest).GetVideoId() != videoID {
		t.Errorf("calls = %+v", calls)
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
			p := decodeProblem(t, rec)
			if p.Code != "NOT_READY" || p.Detail != "" {
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
		{http.MethodGet, "/videos/" + videoID, ""},
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
				if n := len(e.users.recorded()) + len(e.videos.recorded()); n != 0 {
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
	tp := md.Get(traceparent.MetadataKey)
	if len(tp) != 1 || tp[0] == clientTraceparent {
		t.Errorf("traceparent = %v, want one value made by the gateway", tp)
	} else if _, ok := traceparent.TraceID(tp[0]); !ok {
		t.Errorf("traceparent %q is not valid", tp[0])
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
