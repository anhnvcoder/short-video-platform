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
	// service for longer; the services pass it on and never set a longer one.
	callTimeout = 3 * time.Second
	// readyTimeout bounds the health checks of /readyz.
	readyTimeout = 1 * time.Second
	// statsTimeout bounds each of the two calls that add stats and authors to the videos of an
	// answer, one GetStats and one GetProfiles side by side: the feed answers within its 150 ms p99
	// budget even when engagement-service or user-service is slow.
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
// route but healthz and readyz is rate limited by limits: register, login,
// refresh, logout and the public video by client IP, the others by the authenticated user,
// after RequireAuth. A
// request that matches no route gets a problem response too. userConn, videoConn, feedConn and engagementConn reach
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
	mux.HandleFunc("POST /auth/refresh", s.refresh)
	mux.HandleFunc("POST /auth/logout", s.logout)
	// The one route outside /auth without RequireAuth: the public share page reads it without
	// logging in.
	mux.HandleFunc("GET /public/videos/{video_id}", s.getPublicVideo)
	mux.Handle("GET /me", authed(ratelimit.Read, s.getMe))
	mux.Handle("PATCH /me", authed(ratelimit.Write, s.updateMe))
	mux.Handle("GET /me/videos", authed(ratelimit.Read, s.myVideos))
	mux.Handle("GET /profiles/{handle}", authed(ratelimit.Read, s.getProfile))
	mux.Handle("GET /users/{user_id}/videos", authed(ratelimit.Read, s.userVideos))
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

// registerRequest is credentials plus the optional handle and display name; user-service
// generates a handle when it is empty and defaults the display name to the handle.
type registerRequest struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	Handle      string `json:"handle"`
	DisplayName string `json:"display_name"`
}

type registerResponse struct {
	UserID string `json:"user_id"`
}

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	if !s.allow(w, r, ratelimit.Register, ratelimit.ClientIP(r, s.clientAddr)) {
		return
	}
	var req registerRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.Register(ctx, &userv1.RegisterRequest{
		Email:       req.Email,
		Password:    req.Password,
		Handle:      req.Handle,
		DisplayName: req.DisplayName,
	})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, registerResponse{UserID: resp.GetUserId()})
}

// tokenResponse is the answer of login and refresh alike (schema AccessToken).
type tokenResponse struct {
	AccessToken      string    `json:"access_token"`
	TokenType        string    `json:"token_type"`
	ExpiresAt        time.Time `json:"expires_at"`
	RefreshToken     string    `json:"refresh_token"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
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
	writeJSON(w, http.StatusOK, tokenResponse{
		AccessToken:      resp.GetAccessToken(),
		TokenType:        "Bearer",
		ExpiresAt:        resp.GetExpiresAt().AsTime(),
		RefreshToken:     resp.GetRefreshToken(),
		RefreshExpiresAt: resp.GetRefreshExpiresAt().AsTime(),
	})
}

type refreshTokenRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// refresh and logout need no Bearer: the access token may have just expired, and the refresh
// token is the credential. Both check the client IP before reading the body (class refresh). A
// missing or empty refresh_token goes on to user-service, which answers it like any other token
// it cannot use. The refresh token is a credential: it never goes into a log line, a span or a
// problem (threat model JWT-8).
//
// The Refresh call is never retried, not even on UNAVAILABLE: the presented token is used up, so
// a second attempt would be a reuse and revoke the whole family.
func (s *server) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshTokenRequest
	if !s.readRefreshToken(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.Refresh(ctx, &userv1.RefreshRequest{RefreshToken: req.RefreshToken})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse{
		AccessToken:      resp.GetAccessToken(),
		TokenType:        "Bearer",
		ExpiresAt:        resp.GetExpiresAt().AsTime(),
		RefreshToken:     resp.GetRefreshToken(),
		RefreshExpiresAt: resp.GetRefreshExpiresAt().AsTime(),
	})
}

// logout answers 204 for any token user-service accepts, an unknown one included, so the answer
// does not tell which tokens exist.
func (s *server) logout(w http.ResponseWriter, r *http.Request) {
	var req refreshTokenRequest
	if !s.readRefreshToken(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	if _, err := s.users.Logout(ctx, &userv1.LogoutRequest{RefreshToken: req.RefreshToken}); err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// readRefreshToken counts the request in class refresh by client IP, then decodes the body into
// req. On failure it has written the response and returns false.
func (s *server) readRefreshToken(w http.ResponseWriter, r *http.Request, req *refreshTokenRequest) bool {
	return s.allow(w, r, ratelimit.Refresh, ratelimit.ClientIP(r, s.clientAddr)) && httpx.DecodeJSON(w, r, req)
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

// profile is what anyone may see of a user (schema Profile); it never holds the email.
type profile struct {
	UserID      string `json:"user_id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"display_name"`
}

func toProfile(p *userv1.Profile) *profile {
	return &profile{UserID: p.GetUserId(), Handle: p.GetHandle(), DisplayName: p.GetDisplayName()}
}

// userProfile is a profile as the caller sees it (schema UserProfile).
type userProfile struct {
	profile
	FollowedByMe bool `json:"followed_by_me"`
}

// getMe reads the caller's profile with GetProfiles. Unlike the authors added to videos, the
// profile is the answer itself, so the call has the whole call deadline and its errors go
// through the §8.4 table. GetProfiles leaves out an id without a user, which here means the
// token outlived its account (a database reset): 404 USER_NOT_FOUND, the reason user-service
// gives on the other routes of the caller's own profile.
func (s *server) getMe(w http.ResponseWriter, r *http.Request) {
	caller := httpx.UserID(r.Context())
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.GetProfiles(ctx, &userv1.GetProfilesRequest{UserIds: []string{caller}})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	for _, p := range resp.GetProfiles() {
		if p.GetUserId() == caller {
			writeJSON(w, http.StatusOK, toProfile(p))
			return
		}
	}
	httpx.WriteProblem(w, r, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
}

type profileUpdate struct {
	DisplayName string `json:"display_name"`
}

// updateMe changes the caller's display name. A missing or empty display_name goes on to
// user-service, which refuses it like any other invalid name (INVALID_DISPLAY_NAME). The name
// is never logged: users may put their real name in it (threat model WEB-18).
func (s *server) updateMe(w http.ResponseWriter, r *http.Request) {
	var req profileUpdate
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.UpdateDisplayName(ctx, &userv1.UpdateDisplayNameRequest{DisplayName: req.DisplayName})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toProfile(resp.GetProfile()))
}

// getProfile passes handle on as it is: user-service normalizes it and answers a value that
// cannot be a handle with the same 404 as an unknown one.
func (s *server) getProfile(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.users.GetProfileByHandle(ctx, &userv1.GetProfileByHandleRequest{Handle: r.PathValue("handle")})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, userProfile{profile: *toProfile(resp.GetProfile()), FollowedByMe: resp.GetFollowedByMe()})
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
	// Author and Stats are added by GET /videos/{video_id} and the video lists (see addExtras);
	// nil, and the field absent, in POST /videos/{video_id}/complete and when their service did
	// not answer in time.
	Author *profile    `json:"author,omitempty"`
	Stats  *videoStats `json:"stats,omitempty"`
}

// getVideo reads the video first, then adds its author and stats: the video decides whether
// there is anything to show, and only its own errors fail the request.
func (s *server) getVideo(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: r.PathValue("video_id")})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	v := s.toVideoResponse(resp.GetVideo())
	stats, authors := s.addExtras(r, []string{v.VideoID}, []string{v.AuthorID})
	v.Stats, v.Author = stats[v.VideoID], authors[v.AuthorID]
	writeJSON(w, http.StatusOK, v)
}

// publicVideo is a READY video for anyone (schema PublicVideo): the fields of a feed item, and
// counters without liked_by_me, since there is no caller.
type publicVideo struct {
	VideoID      string            `json:"video_id"`
	AuthorID     string            `json:"author_id"`
	Title        string            `json:"title"`
	DurationMs   int64             `json:"duration_ms"`
	PlaylistURL  string            `json:"playlist_url"`
	ThumbnailURL string            `json:"thumbnail_url"`
	PublishedAt  time.Time         `json:"published_at"`
	Author       *profile          `json:"author,omitempty"`
	Stats        *publicVideoStats `json:"stats,omitempty"`
}

type publicVideoStats struct {
	ViewCount int64 `json:"view_count"`
	LikeCount int64 `json:"like_count"`
}

// getPublicVideo serves the public share page. It never reads the
// Authorization header, a wrong token included, so nothing here has a caller: GetPublicVideo
// and GetStats go out without x-user-id, and the answer is the same for everyone. The rate
// limit by client IP comes before any call, so a caller over it costs no service anything
// (threat model WEB-15).
//
// Only a 200 may be kept by a shared cache, for 30 seconds: counters lag by about a minute
// anyway. Everything else is no-store: a 404 is heuristically cacheable (RFC 9110 section
// 15.1), and a video still PROCESSING must not stay a cached 404 once READY; a 429 belongs to
// one client. video-service answers every video it will not show (no such video, not READY, an
// id that is not a UUID) with the same NOT_FOUND, which goes out unchanged.
func (s *server) getPublicVideo(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.allow(w, r, ratelimit.Public, ratelimit.ClientIP(r, s.clientAddr)) {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.GetPublicVideo(ctx, &videov1.GetPublicVideoRequest{VideoId: r.PathValue("video_id")})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	pv := resp.GetVideo()
	out := publicVideo{
		VideoID:      pv.GetVideoId(),
		AuthorID:     pv.GetAuthorId(),
		Title:        pv.GetTitle(),
		DurationMs:   pv.GetDuration().AsDuration().Milliseconds(),
		PlaylistURL:  s.mediaURL(pv.GetPlaylistKey()),
		ThumbnailURL: s.mediaURL(pv.GetThumbnailKey()),
		PublishedAt:  pv.GetPublishedAt().AsTime(),
	}
	stats, authors := s.addExtras(r, []string{out.VideoID}, []string{out.AuthorID})
	if st := stats[out.VideoID]; st != nil {
		out.Stats = &publicVideoStats{ViewCount: st.ViewCount, LikeCount: st.LikeCount}
	}
	out.Author = authors[out.AuthorID]
	w.Header().Set("Cache-Control", "public, max-age=30")
	writeJSON(w, http.StatusOK, out)
}

type videoPage struct {
	Items      []videoResponse `json:"items"`
	NextCursor string          `json:"next_cursor"`
}

// myVideos lists the caller's own videos, in every status.
func (s *server) myVideos(w http.ResponseWriter, r *http.Request) {
	s.serveAuthorVideos(w, r, httpx.UserID(r.Context()))
}

// userVideos passes user_id on as it is: video-service validates it, and shows videos that are
// not READY only when it is the caller's own id.
func (s *server) userVideos(w http.ResponseWriter, r *http.Request) {
	s.serveAuthorVideos(w, r, r.PathValue("user_id"))
}

// serveAuthorVideos reads one page of authorID's videos and adds their authors and stats. The
// query works as on the feeds (see pageQuery).
func (s *server) serveAuthorVideos(w http.ResponseWriter, r *http.Request, authorID string) {
	size, token, ok := pageQuery(w, r)
	if !ok {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	resp, err := s.videos.ListAuthorVideos(ctx, &videov1.ListAuthorVideosRequest{AuthorId: authorID, PageSize: size, PageToken: token})
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}
	items := make([]videoResponse, 0, len(resp.GetVideos())) // an empty page is [], never null
	videoIDs := make([]string, 0, len(resp.GetVideos()))
	authorIDs := make([]string, 0, len(resp.GetVideos()))
	for _, v := range resp.GetVideos() {
		item := s.toVideoResponse(v)
		items = append(items, item)
		videoIDs = append(videoIDs, item.VideoID)
		authorIDs = append(authorIDs, item.AuthorID)
	}
	stats, authors := s.addExtras(r, videoIDs, authorIDs)
	for i := range items {
		items[i].Stats, items[i].Author = stats[items[i].VideoID], authors[items[i].AuthorID]
	}
	writeJSON(w, http.StatusOK, videoPage{Items: items, NextCursor: resp.GetNextPageToken()})
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
	// Author is nil, and the field absent, when user-service did not answer in time or has no
	// profile for author_id.
	Author *profile `json:"author,omitempty"`
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

// pageQuery reads the paging query of a feed or a video list: the cursor goes on unread as
// page_token (architecture §8.3) and page_size must be an integer; their values are the
// service's to check. On a page_size that is not an integer it writes the 400 and returns false.
func pageQuery(w http.ResponseWriter, r *http.Request) (size int32, token string, ok bool) {
	q := r.URL.Query()
	if v := q.Get("page_size"); v != "" {
		n, err := strconv.ParseInt(v, 10, 32)
		if err != nil {
			httpx.WriteProblem(w, r, http.StatusBadRequest, "INVALID_PAGE_SIZE", "page_size must be an integer")
			return 0, "", false
		}
		size = int32(n)
	}
	return size, q.Get("cursor"), true
}

// serveFeed reads one feed page with fetch and adds the authors and stats of its videos. A
// feed-service error is mapped like any other; a failure to add authors or stats is not (see
// addExtras).
func (s *server) serveFeed(w http.ResponseWriter, r *http.Request, fetch func(ctx context.Context, size int32, token string) (feedPage, error)) {
	size, token, ok := pageQuery(w, r)
	if !ok {
		return
	}
	ctx, cancel := callContext(r)
	defer cancel()
	page, err := fetch(ctx, size, token)
	if err != nil {
		httpx.WriteGRPCError(w, r, err)
		return
	}

	items := make([]feedItem, 0, len(page.GetItems())) // an empty page is [], never null
	videoIDs := make([]string, 0, len(page.GetItems()))
	authorIDs := make([]string, 0, len(page.GetItems()))
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
		videoIDs = append(videoIDs, it.GetVideoId())
		authorIDs = append(authorIDs, it.GetAuthorId())
	}
	stats, authors := s.addExtras(r, videoIDs, authorIDs)
	for i := range items {
		items[i].Stats, items[i].Author = stats[items[i].VideoID], authors[items[i].AuthorID]
	}
	writeJSON(w, http.StatusOK, feedResponse{Items: items, NextCursor: page.GetNextPageToken()})
}

// addExtras reads what the gateway adds to the videos of one answer: the stats of videoIDs with
// one GetStats call and the profiles of the authors with one GetProfiles call, side by side, so
// a page waits for the slower of the two rather than their sum. Each call has its own
// statsTimeout and no retry: 100 ms holds no second try. The answers come back by video id and
// by user id, so their order and count do not matter; a video or author without a match gets
// nothing, and a nil map answers nil for every key. A call that fails only leaves its part out
// (see getStats, getAuthors). An empty page makes no call.
//
// GetStats goes out with the caller's x-user-id when the request has one, for liked_by_me; on
// the public route there is none, and engagement-service then reads no like.
func (s *server) addExtras(r *http.Request, videoIDs, authorIDs []string) (map[string]*videoStats, map[string]*profile) {
	if len(videoIDs) == 0 {
		return nil, nil
	}
	var stats map[string]*videoStats
	var authors map[string]*profile
	var wg sync.WaitGroup
	wg.Go(func() { stats = s.getStats(r, videoIDs) })
	wg.Go(func() { authors = s.getAuthors(r, authorIDs) })
	wg.Wait()
	return stats, authors
}

// getStats returns the stats of ids by video id, or nil when GetStats fails. The error is only
// logged: a slow or failing engagement-service must not fail the answer (architecture §7.2),
// so it does not go through the §8.4 table. While engagement-service's circuit breaker is open
// the call fails at once, without waiting for statsTimeout.
func (s *server) getStats(r *http.Request, ids []string) map[string]*videoStats {
	ctx, cancel := context.WithTimeout(httpx.OutgoingContext(r.Context()), statsTimeout)
	defer cancel()
	resp, err := s.engagement.GetStats(ctx, &engagementv1.GetStatsRequest{VideoIds: ids})
	if err != nil {
		slog.WarnContext(r.Context(), "served without stats",
			slog.String("grpc_code", status.Code(err).String()),
			slog.String("error", err.Error()),
		)
		return nil
	}
	byID := make(map[string]*videoStats, len(resp.GetStats()))
	for _, st := range resp.GetStats() {
		byID[st.GetVideoId()] = &videoStats{
			ViewCount: st.GetViewCount(),
			LikeCount: st.GetLikeCount(),
			LikedByMe: st.GetLikedByMe(),
		}
	}
	return byID
}

// getAuthors returns the profiles of ids, each asked once, by user id, or nil when GetProfiles
// fails. As in getStats the error is only logged, and while user-service's circuit breaker is
// open the call fails at once. The log line holds no profile: display names may be real names
// (threat model WEB-18).
func (s *server) getAuthors(r *http.Request, ids []string) map[string]*profile {
	seen := make(map[string]bool, len(ids))
	unique := make([]string, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			unique = append(unique, id)
		}
	}
	ctx, cancel := context.WithTimeout(httpx.OutgoingContext(r.Context()), statsTimeout)
	defer cancel()
	resp, err := s.users.GetProfiles(ctx, &userv1.GetProfilesRequest{UserIds: unique})
	if err != nil {
		slog.WarnContext(r.Context(), "served without authors",
			slog.String("grpc_code", status.Code(err).String()),
			slog.String("error", err.Error()),
		)
		return nil
	}
	byID := make(map[string]*profile, len(resp.GetProfiles()))
	for _, p := range resp.GetProfiles() {
		byID[p.GetUserId()] = toProfile(p)
	}
	return byID
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
