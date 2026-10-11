// Package api is the gateway's REST API (services/gateway/openapi.yaml): it turns JSON
// requests into gRPC calls to user-service and video-service and their answers back into JSON
// (snake_case fields, RFC 3339 UTC times).
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/authtoken"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
)

const (
	// callTimeout is the deadline of every gRPC call a request makes (ADR-0002).
	callTimeout = 3 * time.Second
	// readyTimeout bounds the health checks of /readyz.
	readyTimeout = 1 * time.Second
)

type server struct {
	users  userv1.UserServiceClient
	videos videov1.VideoServiceClient
	deps   []dependency
	// mediaBaseURL is the public base of media object keys, without a trailing slash.
	mediaBaseURL string
}

// dependency is a service /readyz checks.
type dependency struct {
	name   string
	health healthpb.HealthClient
}

// New returns the gateway's HTTP handler: every route on its own mux, behind Trace, Recover and
// AccessLog, with RequireAuth in front of the routes that need a caller. A request that matches
// no route gets a problem response too. userConn and videoConn
// reach user-service and video-service. mediaBaseURL is the public base that media object keys
// are appended to, without a trailing slash.
func New(userConn, videoConn grpc.ClientConnInterface, verifier *authtoken.Verifier, mediaBaseURL string) http.Handler {
	s := &server{
		mediaBaseURL: mediaBaseURL,
		users:        userv1.NewUserServiceClient(userConn),
		videos:       videov1.NewVideoServiceClient(videoConn),
		deps: []dependency{
			{name: "user-service", health: healthpb.NewHealthClient(userConn)},
			{name: "video-service", health: healthpb.NewHealthClient(videoConn)},
		},
	}
	auth := httpx.RequireAuth(verifier)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /auth/register", s.register)
	mux.HandleFunc("POST /auth/login", s.login)
	mux.Handle("PUT /me/following/{user_id}", auth(http.HandlerFunc(s.follow)))
	mux.Handle("DELETE /me/following/{user_id}", auth(http.HandlerFunc(s.unfollow)))
	mux.Handle("POST /videos", auth(http.HandlerFunc(s.initUpload)))
	mux.Handle("POST /videos/{video_id}/complete", auth(http.HandlerFunc(s.completeUpload)))
	mux.Handle("GET /videos/{video_id}", auth(http.HandlerFunc(s.getVideo)))
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	return httpx.Trace(httpx.Recover(httpx.AccessLog(httpx.Routes(mux))))
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

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	var req credentials
	if !httpx.DecodeJSON(w, r, &req) {
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
