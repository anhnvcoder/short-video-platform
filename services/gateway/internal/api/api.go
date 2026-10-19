// Package api is the gateway's REST API (services/gateway/openapi.yaml): it turns JSON
// requests into gRPC calls to user-service, video-service, feed-service and engagement-service
// and their answers back into JSON (snake_case fields, RFC 3339 UTC times).
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/ratelimit"
)

const (
	// callTimeout is the deadline of every gRPC call a request makes, so no request waits on a
	// service for longer; the services pass it on and never set a longer one (ADR-0002).
	callTimeout = 3 * time.Second
	// readyTimeout bounds the health checks of /readyz.
	readyTimeout = 1 * time.Second
	// statsTimeout bounds the one GetStats call a feed page makes (ADR-0009 section 9): the feed
	// answers within its 150 ms p99 budget even when engagement-service is slow.
	statsTimeout = 100 * time.Millisecond
)

type server struct {
	users      userv1.UserServiceClient
	videos     videov1.VideoServiceClient
	feeds      feedv1.FeedServiceClient
	engagement engagementv1.EngagementServiceClient
	limits     *ratelimit.Limiter
	// clientAddr finds the client's address for the rate limits by IP.
	clientAddr httpx.ClientAddr
	deps       []dependency
	// mediaBaseURL is the public base of media object keys, without a trailing slash.
	mediaBaseURL string
}

// dependency is a service /readyz checks.
type dependency struct {
	name   string
	health healthpb.HealthClient
}

// New returns the gateway's HTTP handler: every route on its own mux, behind Trace, Recover,
// AccessLog and ValidUTF8, with RequireAuth in front of the routes that need a caller. Every
// route but healthz and readyz is rate limited by limits (ADR-0010 section 2): register and
// login by client IP, the others by the authenticated user, after RequireAuth. A request
// that matches no route gets a problem response too. userConn, videoConn, feedConn and engagementConn reach
// user-service, video-service, feed-service and engagement-service. mediaBaseURL is the public
// base that media object keys are appended to, without a trailing slash. clientAddr finds the
// client's address, for the rate limits by IP and the client.address of spans alike. serverName
// is the gateway's host:port, with a numeric port, named in its HTTP spans and metrics (see
// httpx.Trace).
func New(userConn, videoConn, feedConn, engagementConn grpc.ClientConnInterface, verifier *authtoken.Verifier, mediaBaseURL string, limits *ratelimit.Limiter, clientAddr httpx.ClientAddr, serverName string) http.Handler {
	s := &server{
		mediaBaseURL: mediaBaseURL,
		limits:       limits,
		clientAddr:   clientAddr,
		users:        userv1.NewUserServiceClient(userConn),
		videos:       videov1.NewVideoServiceClient(videoConn),
		feeds:        feedv1.NewFeedServiceClient(feedConn),
		engagement:   engagementv1.NewEngagementServiceClient(engagementConn),
		// engagement-service is left out on purpose: the feed degrades to items without stats
		// when it is down (architecture §7.2), so the gateway stays ready and keeps serving.
		deps: []dependency{
			{name: "user-service", health: healthpb.NewHealthClient(userConn)},
			{name: "video-service", health: healthpb.NewHealthClient(videoConn)},
			{name: "feed-service", health: healthpb.NewHealthClient(feedConn)},
		},
	}
	auth := httpx.RequireAuth(verifier)
	// authed puts RequireAuth, then the rate limit of class c on the caller's user id, in front of h.
	authed := func(c ratelimit.Class, h http.HandlerFunc) http.Handler {
		return auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if s.allow(w, r, c, httpx.UserID(r.Context())) {
				h(w, r)
			}
		}))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /auth/register", s.register)
	mux.HandleFunc("POST /auth/login", s.login)
	mux.Handle("PUT /me/following/{user_id}", authed(ratelimit.Write, s.follow))
	mux.Handle("DELETE /me/following/{user_id}", authed(ratelimit.Write, s.unfollow))
	mux.Handle("POST /videos", authed(ratelimit.Upload, s.initUpload))
	mux.Handle("POST /videos/{video_id}/complete", authed(ratelimit.Write, s.completeUpload))
	mux.Handle("GET /videos/{video_id}", authed(ratelimit.Read, s.getVideo))
	mux.Handle("PUT /videos/{video_id}/like", authed(ratelimit.Write, s.like))
	mux.Handle("DELETE /videos/{video_id}/like", authed(ratelimit.Write, s.unlike))
	mux.Handle("POST /videos/{video_id}/views", authed(ratelimit.Write, s.recordView))
	mux.Handle("GET /feed/following", authed(ratelimit.Read, s.followingFeed))
	mux.Handle("GET /feed/explore", authed(ratelimit.Read, s.exploreFeed))
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	return httpx.Trace(serverName, clientAddr)(httpx.Recover(httpx.AccessLog(httpx.ValidUTF8(httpx.Routes(mux)))))
}

// allow counts the request in class c under id and, when the class refuses it, writes the 429
// and returns false; the handler then returns.
func (s *server) allow(w http.ResponseWriter, r *http.Request, c ratelimit.Class, id string) bool {
	ok, retryAfter := s.limits.Allow(r.Context(), c, id)
	if !ok {
		httpx.WriteRateLimited(w, r, c.Name, retryAfter)
	}
	return ok
}

// callContext returns the context of a gRPC call made for r: metadata built from scratch by
// OutgoingContext (threat model IN-1) and the call deadline.
func callContext(r *http.Request) (context.Context, context.CancelFunc) {
	return context.WithTimeout(httpx.OutgoingContext(r.Context()), callTimeout)
}

// writeJSON writes v as an application/json response with status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		// Every response type is a struct of strings, numbers and times, which always marshals.
		panic(err)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type registerResponse struct {
	UserID string `json:"user_id"`
}

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, ratelimit.Register, ratelimit.ClientIP(r, s.clientAddr)) {
		return
	}
	var req credentials
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.Register(ctx, &userv1.RegisterRequest{Email: req.Email, Password: req.Password})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, registerResponse{UserID: resp.GetUserId()})
}

type loginResponse struct {
	AccessToken string    `json:"access_token"`
	TokenType   string    `json:"token_type"`
	ExpiresAt   time.Time `json:"expires_at"`
}

// login checks the client IP before reading the body, and the (IP, email) pair once the body
// decodes (threat model JWT-4).
func (s *server) login(w http.ResponseWriter, r *http.Request) {
	ip := ratelimit.ClientIP(r, s.clientAddr)
	if !s.allow(w, r, ratelimit.LoginIP, ip) {
		return
	}
	var req credentials
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if !s.allow(w, r, ratelimit.LoginEmail, ratelimit.LoginEmailID(ip, req.Email)) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.Login(ctx, &userv1.LoginRequest{Email: req.Email, Password: req.Password})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, loginResponse{
		AccessToken: resp.GetAccessToken(),
		TokenType:   "Bearer",
		ExpiresAt:   resp.GetExpiresAt().AsTime(),
	})
}

// follow and unfollow pass user_id on as it is: user-service validates it.
func (s *server) follow(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.users.Follow(ctx, &userv1.FollowRequest{FolloweeId: r.PathValue("user_id")}); err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) unfollow(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.users.Unfollow(ctx, &userv1.UnfollowRequest{FolloweeId: r.PathValue("user_id")}); err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type initUploadRequest struct {
	Title       string `json:"title"`
	SizeBytes   int64  `json:"size_bytes"`
	ContentType string `json:"content_type"`
}

type initUploadResponse struct {
	VideoID    string            `json:"video_id"`
	UploadURL  string            `json:"upload_url"`
	FormFields map[string]string `json:"form_fields"`
	ExpiresAt  time.Time         `json:"expires_at"`
}

// initUpload creates the video and returns the presigned POST. upload_url and form_fields are a
// short-lived credential: they go to the client only and never to the log (threat model UP-2).
func (s *server) initUpload(w http.ResponseWriter, r *http.Request) {
	var req initUploadRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.InitUpload(ctx, &videov1.InitUploadRequest{
		Title:       req.Title,
		SizeBytes:   req.SizeBytes,
		ContentType: req.ContentType,
	})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	fields := resp.GetFormFields()
	if fields == nil {
		fields = map[string]string{} // openapi: form_fields is a required object, never null
	}
	w.Header().Set("Location", "/videos/"+resp.GetVideoId())
	writeJSON(w, http.StatusCreated, initUploadResponse{
		VideoID:    resp.GetVideoId(),
		UploadURL:  resp.GetUploadUrl(),
		FormFields: fields,
		ExpiresAt:  resp.GetExpiresAt().AsTime(),
	})
}

type videoResponse struct {
	VideoID     string     `json:"video_id"`
	AuthorID    string     `json:"author_id"`
	Title       string     `json:"title"`
	Status      string     `json:"status"`
	CreatedAt   time.Time  `json:"created_at"`
	DurationMs  *int64     `json:"duration_ms,omitempty"`
	PublishedAt *time.Time `json:"published_at,omitempty"`
	// PlaylistURL and ThumbnailURL are set once the video has the keys, which is when it is READY.
	PlaylistURL  string `json:"playlist_url,omitempty"`
	ThumbnailURL string `json:"thumbnail_url,omitempty"`
}

func (s *server) getVideo(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: r.PathValue("video_id")})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, s.toVideoResponse(resp.GetVideo()))
}

// completeUpload answers 202 with the video in whatever state CompleteUpload returns: the RPC is
// idempotent and the state is in the body. The service validates video_id.
func (s *server) completeUpload(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.CompleteUpload(ctx, &videov1.CompleteUploadRequest{VideoId: r.PathValue("video_id")})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusAccepted, s.toVideoResponse(resp.GetVideo()))
}

// mediaURL returns the public URL of an object key, or "" for an empty key.
func (s *server) mediaURL(key string) string {
	if key == "" {
		return ""
	}
	return s.mediaBaseURL + "/" + key
}

func (s *server) toVideoResponse(v *videov1.Video) videoResponse {
	out := videoResponse{
		VideoID:  v.GetVideoId(),
		AuthorID: v.GetAuthorId(),
		Title:    v.GetTitle(),
		// VIDEO_STATUS_READY → READY.
		Status:       strings.TrimPrefix(v.GetStatus().String(), "VIDEO_STATUS_"),
		CreatedAt:    v.GetCreatedAt().AsTime(),
		PlaylistURL:  s.mediaURL(v.GetPlaylistKey()),
		ThumbnailURL: s.mediaURL(v.GetThumbnailKey()),
	}
	if d := v.GetDuration(); d != nil {
		ms := d.AsDuration().Milliseconds()
		out.DurationMs = &ms
	}
	if p := v.GetPublishedAt(); p != nil {
		t := p.AsTime()
		out.PublishedAt = &t
	}
	return out
}

// like, unlike and recordView pass video_id on as it is: engagement-service validates it.
func (s *server) like(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.engagement.Like(ctx, &engagementv1.LikeRequest{VideoId: r.PathValue("video_id")}); err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) unlike(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.engagement.Unlike(ctx, &engagementv1.UnlikeRequest{VideoId: r.PathValue("video_id")}); err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// recordView answers 202 without a body: the view is queued, and view_count catches up later.
// A user's view of a video counts once a minute (threat model RL-3): a repeat gets the same 202
// without reaching engagement-service, so the client learns nothing and has nothing to retry.
// Only a canonical video id gets a key; any other goes on as before and engagement-service
// rejects it. When the call fails the key is dropped in the background, without holding the
// answer, so the client's retry is counted.
func (s *server) recordView(w http.ResponseWriter, r *http.Request) {
	videoID := r.PathValue("video_id")
	userID := httpx.UserID(r.Context())
	claim := ratelimit.ViewUnchecked
	if _, err := ids.Parse(videoID); err == nil {
		claim = s.limits.ClaimView(r.Context(), userID, videoID)
	}
	if claim == ratelimit.ViewRepeated {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.engagement.RecordView(ctx, &engagementv1.RecordViewRequest{VideoId: videoID}); err != nil {
		if claim == ratelimit.ViewClaimed {
			go s.limits.ReleaseView(context.WithoutCancel(r.Context()), userID, videoID)
		}
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

type feedResponse struct {
	Items      []feedItem `json:"items"`
	NextCursor string     `json:"next_cursor"`
}

type feedItem struct {
	VideoID      string    `json:"video_id"`
	AuthorID     string    `json:"author_id"`
	Title        string    `json:"title"`
	DurationMs   int64     `json:"duration_ms"`
	PlaylistURL  string    `json:"playlist_url"`
	ThumbnailURL string    `json:"thumbnail_url"`
	PublishedAt  time.Time `json:"published_at"`
	// Stats is nil, and the field absent, when engagement-service did not answer in time.
	Stats *videoStats `json:"stats,omitempty"`
}

type videoStats struct {
	ViewCount int64 `json:"view_count"`
	LikeCount int64 `json:"like_count"`
	LikedByMe bool  `json:"liked_by_me"`
}

// feedPage is what both feed RPCs answer.
type feedPage interface {
	GetItems() []*feedv1.FeedItem
	GetNextPageToken() string
}

func (s *server) followingFeed(w http.ResponseWriter, r *http.Request) {
	s.serveFeed(w, r, func(ctx context.Context, size int32, token string) (feedPage, error) {
		return s.feeds.GetFollowingFeed(ctx, &feedv1.GetFollowingFeedRequest{PageSize: size, PageToken: token})
	})
}

func (s *server) exploreFeed(w http.ResponseWriter, r *http.Request) {
	s.serveFeed(w, r, func(ctx context.Context, size int32, token string) (feedPage, error) {
		return s.feeds.GetExploreFeed(ctx, &feedv1.GetExploreFeedRequest{PageSize: size, PageToken: token})
	})
}

// serveFeed reads one feed page with fetch and adds the stats of its videos. The query's cursor
// goes on unread as page_token (architecture §8.3) and page_size must be an integer; their
// values are feed-service's to check. A feed-service error is mapped like any other; a stats
// failure is not (see addStats).
func (s *server) serveFeed(w http.ResponseWriter, r *http.Request, fetch func(ctx context.Context, size int32, token string) (feedPage, error)) {
	q := r.URL.Query()
	var size int32
	if v := q.Get("page_size"); v != "" {
		n, err := strconv.ParseInt(v, 10, 32)
		if err != nil {
			httpx.WriteProblem(w, r, http.StatusBadRequest, "INVALID_PAGE_SIZE", "page_size must be an integer")
			return
		}
		size = int32(n)
	}
	ctx, cancel := callContext(r)
	defer cancel()
	page, err := fetch(ctx, size, q.Get("cursor"))
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}

	items := make([]feedItem, 0, len(page.GetItems())) // an empty page is [], never null
	for _, it := range page.GetItems() {
		items = append(items, feedItem{
			VideoID:      it.GetVideoId(),
			AuthorID:     it.GetAuthorId(),
			Title:        it.GetTitle(),
			DurationMs:   it.GetDuration().AsDuration().Milliseconds(),
			PlaylistURL:  s.mediaURL(it.GetPlaylistKey()),
			ThumbnailURL: s.mediaURL(it.GetThumbnailKey()),
			PublishedAt:  it.GetPublishedAt().AsTime(),
		})
	}
	s.addStats(r, items)
	writeJSON(w, http.StatusOK, feedResponse{Items: items, NextCursor: page.GetNextPageToken()})
}

// addStats sets the stats of items from one GetStats call, within statsTimeout and without
// retry (ADR-0009 section 9). Stats are matched by video_id, so their order and count do not
// matter; an item without a match keeps no stats. Any error leaves every item without stats and
// is only logged: a slow or failing engagement-service must not fail the feed (architecture
// §7.2), so the error does not go through the §8.4 table. While engagement-service's circuit
// breaker is open the call fails at once, without waiting for statsTimeout (ADR-0010 section 4).
func (s *server) addStats(r *http.Request, items []feedItem) {
	if len(items) == 0 {
		return
	}
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.VideoID
	}
	ctx, cancel := context.WithTimeout(httpx.OutgoingContext(r.Context()), statsTimeout)
	defer cancel()
	resp, err := s.engagement.GetStats(ctx, &engagementv1.GetStatsRequest{VideoIds: ids})
	if err != nil {
		slog.WarnContext(r.Context(), "feed served without stats",
			slog.String("grpc_code", status.Code(err).String()),
			slog.String("error", err.Error()),
		)
		return
	}
	byID := make(map[string]*videoStats, len(resp.GetStats()))
	for _, st := range resp.GetStats() {
		byID[st.GetVideoId()] = &videoStats{
			ViewCount: st.GetViewCount(),
			LikeCount: st.GetLikeCount(),
			LikedByMe: st.GetLikedByMe(),
		}
	}
	for i := range items {
		items[i].Stats = byID[items[i].VideoID]
	}
}

type statusResponse struct {
	Status string `json:"status"`
}

// healthz answers while the process can serve HTTP; it checks nothing else.
func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

// readyz checks the health of every dependency at once, within readyTimeout. Any dependency not
// SERVING makes it a 503 problem; which one and why goes to the log only.
func (s *server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(httpx.OutgoingContext(r.Context()), readyTimeout)
	defer cancel()
	errs := make([]error, len(s.deps))
	var wg sync.WaitGroup
	for i, d := range s.deps {
		wg.Go(func() { errs[i] = checkServing(ctx, d.health) })
	}
	wg.Wait()

	ready := true
	for i, err := range errs {
		if err != nil {
			ready = false
			slog.WarnContext(r.Context(), "dependency not ready",
				slog.String("dependency", s.deps[i].name),
				slog.String("error", err.Error()),
			)
		}
	}
	if !ready {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, "NOT_READY", "")
		return
	}
	writeJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

func checkServing(ctx context.Context, health healthpb.HealthClient) error {
	resp, err := health.Check(ctx, &healthpb.HealthCheckRequest{})
	if err != nil {
		return err
	}
	if st := resp.GetStatus(); st != healthpb.HealthCheckResponse_SERVING {
		return fmt.Errorf("status %s", st)
	}
	return nil
}
