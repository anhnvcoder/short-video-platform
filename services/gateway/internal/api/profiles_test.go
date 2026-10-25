package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
)

func TestRegisterWithHandle(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodPost, "/auth/register", `{"email":"a@example.com","password":"correct horse","handle":"Alice","display_name":"Alice A"}`, "")
	wantStatus(t, rec, http.StatusCreated)
	req := e.users.only(t).req.(*userv1.RegisterRequest)
	// The handle goes on as typed: user-service normalizes it.
	if req.GetHandle() != "Alice" || req.GetDisplayName() != "Alice A" || req.GetEmail() != "a@example.com" {
		t.Errorf("request = %v", req)
	}
}

func TestRegisterProfileErrors(t *testing.T) {
	for _, tc := range []struct {
		err        error
		wantStatus int
	}{
		{grpcerr.New(codes.AlreadyExists, "HANDLE_ALREADY_TAKEN", "handle is already taken"), http.StatusConflict},
		{grpcerr.New(codes.InvalidArgument, "INVALID_HANDLE", "handle must match ^[a-z][a-z0-9_]{2,29}$"), http.StatusBadRequest},
		{grpcerr.New(codes.InvalidArgument, "INVALID_DISPLAY_NAME", "display_name must be 1 to 50 characters"), http.StatusBadRequest},
	} {
		code := grpcerr.Reason(tc.err)
		t.Run(code, func(t *testing.T) {
			e := newEnv(t)
			e.users.fail(tc.err)
			rec := e.do(t, http.MethodPost, "/auth/register", `{"email":"a@example.com","password":"correct horse","handle":"bob"}`, "")
			wantStatus(t, rec, tc.wantStatus)
			if p := decodeProblem(t, rec); p.Code != code || p.Detail != status.Convert(tc.err).Message() {
				t.Errorf("problem = %+v, want code %s", p, code)
			}
		})
	}
}

func TestGetMe(t *testing.T) {
	e := newEnv(t)
	seen := make(chan time.Duration, 1)
	e.users.setHook(func(ctx context.Context, _ string) error {
		d, _ := ctx.Deadline()
		seen <- time.Until(d)
		return nil
	})
	rec := e.do(t, http.MethodGet, "/me", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
	// The profile, and nothing else: no email, no followed_by_me.
	wantAuthor(t, decode[map[string]any](t, rec), userA, "alice", "Alice")
	c := e.users.only(t)
	if c.method != userv1.UserService_GetProfiles_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if ids := c.req.(*userv1.GetProfilesRequest).GetUserIds(); !slices.Equal(ids, []string{userA}) {
		t.Errorf("user_ids = %v, want [%s]", ids, userA)
	}
	if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
	// The profile is the answer itself, so it has the whole call deadline, not the authors' 100 ms.
	if d := <-seen; d <= callTimeout-time.Second || d > callTimeout {
		t.Errorf("user-service saw a deadline %v away, want about %v", d, callTimeout)
	}
	if n := len(e.videos.recorded()) + len(e.engagement.recorded()); n != 0 {
		t.Errorf("other services got %d calls, want 0", n)
	}
}

func TestGetMeErrors(t *testing.T) {
	t.Run("no profile", func(t *testing.T) {
		e := newEnv(t)
		rec := e.do(t, http.MethodGet, "/me", "", e.token(t, userC))
		wantStatus(t, rec, http.StatusNotFound)
		if p := decodeProblem(t, rec); p.Code != "USER_NOT_FOUND" || p.Detail != "user not found" {
			t.Errorf("problem = %+v", p)
		}
	})
	// Unlike the authors of a page, a failing GetProfiles fails GET /me through the §8.4 table.
	t.Run("user-service unavailable", func(t *testing.T) {
		e := newEnv(t)
		e.users.fail(status.Error(codes.Unavailable, "user-service is down"))
		rec := e.do(t, http.MethodGet, "/me", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusServiceUnavailable)
		if p := decodeProblem(t, rec); p.Code != "UNAVAILABLE" || p.Detail != "" {
			t.Errorf("problem = %+v", p)
		}
	})
}

func TestUpdateMe(t *testing.T) {
	const name = "Nguyễn Real Name"
	logs := captureLog(t)
	e := newEnv(t)
	rec := e.do(t, http.MethodPatch, "/me", `{"display_name":"`+name+`"}`, e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
	wantAuthor(t, decode[map[string]any](t, rec), userA, "alice", name)
	c := e.users.only(t)
	if c.method != userv1.UserService_UpdateDisplayName_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if got := c.req.(*userv1.UpdateDisplayNameRequest).GetDisplayName(); got != name {
		t.Errorf("display_name = %q, want %q", got, name)
	}
	if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
	// A display name may be a real name: it stays out of the log (threat model WEB-18).
	if strings.Contains(logs.String(), "Real Name") {
		t.Errorf("log contains the display name:\n%s", logs)
	}
}

func TestUpdateMeBodies(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		code       string
	}{
		{"empty", "", http.StatusBadRequest, "INVALID_JSON"},
		{"not JSON", "display_name=x", http.StatusBadRequest, "INVALID_JSON"},
		{"unknown field", `{"display_name":"x","handle":"other"}`, http.StatusBadRequest, "INVALID_JSON"},
		{"not a string", `{"display_name":42}`, http.StatusBadRequest, "INVALID_JSON"},
		{"too large", `{"display_name":"` + strings.Repeat("a", 64<<10) + `"}`, http.StatusRequestEntityTooLarge, "BODY_TOO_LARGE"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			rec := e.send(t, "192.0.2.1:5000", http.MethodPatch, "/me", tc.body, e.token(t, userA), map[string]string{"Content-Type": "application/json"})
			wantStatus(t, rec, tc.status)
			if p := decodeProblem(t, rec); p.Code != tc.code {
				t.Errorf("code = %q, want %q", p.Code, tc.code)
			}
			if n := e.callCount(); n != 0 {
				t.Errorf("services got %d calls, want 0", n)
			}
		})
	}
	// A missing or empty display_name is user-service's to refuse, like any other invalid name.
	for _, body := range []string{`{}`, `{"display_name":""}`} {
		t.Run(body, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodPatch, "/me", body, e.token(t, userA))
			wantStatus(t, rec, http.StatusBadRequest)
			if p := decodeProblem(t, rec); p.Code != "INVALID_DISPLAY_NAME" {
				t.Errorf("code = %q, want INVALID_DISPLAY_NAME", p.Code)
			}
			if got := e.users.only(t).req.(*userv1.UpdateDisplayNameRequest).GetDisplayName(); got != "" {
				t.Errorf("display_name = %q, want empty", got)
			}
		})
	}
	t.Run("account gone", func(t *testing.T) {
		e := newEnv(t)
		rec := e.do(t, http.MethodPatch, "/me", `{"display_name":"x"}`, e.token(t, userC))
		wantStatus(t, rec, http.StatusNotFound)
		if p := decodeProblem(t, rec); p.Code != "USER_NOT_FOUND" {
			t.Errorf("code = %q, want USER_NOT_FOUND", p.Code)
		}
	})
}

func TestGetProfile(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/profiles/bob", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	wantJSON(t, rec)
	got := decode[map[string]any](t, rec)
	if len(got) != 4 || got["user_id"] != userB || got["handle"] != "bob" || got["display_name"] != "Bob B" || got["followed_by_me"] != true {
		t.Errorf("body = %v", got)
	}
	c := e.users.only(t)
	if c.method != userv1.UserService_GetProfileByHandle_FullMethodName {
		t.Errorf("method = %s", c.method)
	}
	if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
		t.Errorf("x-user-id = %v, want [%s]", v, userA)
	}
}

// TestGetProfileHandlePassedThrough: the gateway does not judge a handle; upper case, other
// letters and junk go to user-service as they are, and its 404 comes back.
func TestGetProfileHandlePassedThrough(t *testing.T) {
	for _, tc := range []struct{ path, handle string }{
		{"/profiles/Bob", "Bob"},
		{"/profiles/b%C3%B3b", "bób"},
		{"/profiles/a%20b", "a b"},
		{"/profiles/nobody", "nobody"},
	} {
		t.Run(tc.handle, func(t *testing.T) {
			e := newEnv(t)
			rec := e.do(t, http.MethodGet, tc.path, "", e.token(t, userA))
			wantStatus(t, rec, http.StatusNotFound)
			if p := decodeProblem(t, rec); p.Code != "USER_NOT_FOUND" || p.Detail != "user not found" {
				t.Errorf("problem = %+v", p)
			}
			if got := e.users.only(t).req.(*userv1.GetProfileByHandleRequest).GetHandle(); got != tc.handle {
				t.Errorf("handle = %q, want %q", got, tc.handle)
			}
		})
	}
}

func TestAuthorVideos(t *testing.T) {
	for _, tc := range []struct {
		name, path, author string
	}{
		{"mine", "/me/videos", userA},
		{"someone else's", "/users/" + userB + "/videos", userB},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnvPatient(t)
			rec := e.do(t, http.MethodGet, tc.path+"?page_size=18&cursor=abc", "", e.token(t, userA))
			wantStatus(t, rec, http.StatusOK)
			wantJSON(t, rec)
			got := decode[struct {
				Items      []map[string]any `json:"items"`
				NextCursor *string          `json:"next_cursor"`
			}](t, rec)
			if got.NextCursor == nil || *got.NextCursor != nextCursor || len(got.Items) != 2 {
				t.Fatalf("body = %s", rec.Body.String())
			}
			ready, uploading := got.Items[0], got.Items[1]
			wantFeedItem(t, ready, map[string]any{
				"video_id":     videoID,
				"author_id":    tc.author,
				"status":       "READY",
				"playlist_url": mediaBase + "/media/" + videoID + "/master.m3u8",
			})
			wantFeedItem(t, uploading, map[string]any{"video_id": videoID2, "status": "UPLOADING"})
			if _, ok := uploading["playlist_url"]; ok {
				t.Errorf("UPLOADING item has a playlist_url: %v", uploading)
			}
			p := profiles[tc.author]
			for _, item := range got.Items {
				wantAuthor(t, item["author"], tc.author, p.GetHandle(), p.GetDisplayName())
			}
			if st, _ := ready["stats"].(map[string]any); st["view_count"] != float64(100) || st["liked_by_me"] != true {
				t.Errorf("stats = %v", ready["stats"])
			}
			if _, ok := uploading["stats"]; !ok {
				t.Errorf("UPLOADING item has no stats: %v", uploading)
			}

			c := e.videos.only(t)
			req := c.req.(*videov1.ListAuthorVideosRequest)
			if c.method != videov1.VideoService_ListAuthorVideos_FullMethodName || req.GetAuthorId() != tc.author ||
				req.GetPageSize() != 18 || req.GetPageToken() != "abc" {
				t.Errorf("%s request = %v", c.method, req)
			}
			if v := c.md.Get(callerid.MetadataKey); !slices.Equal(v, []string{userA}) {
				t.Errorf("x-user-id = %v, want [%s]", v, userA)
			}
			if ids := e.engagement.only(t).req.(*engagementv1.GetStatsRequest).GetVideoIds(); !slices.Equal(ids, []string{videoID, videoID2}) {
				t.Errorf("GetStats video_ids = %v", ids)
			}
			if ids := e.users.only(t).req.(*userv1.GetProfilesRequest).GetUserIds(); !slices.Equal(ids, []string{tc.author}) {
				t.Errorf("GetProfiles user_ids = %v, want [%s]", ids, tc.author)
			}
		})
	}
}

func TestAuthorVideosEmptyPage(t *testing.T) {
	e := newEnv(t)
	rec := e.do(t, http.MethodGet, "/me/videos?cursor="+emptyCursor, "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	if got := rec.Body.String(); got != `{"items":[],"next_cursor":""}` {
		t.Errorf("body = %s", got)
	}
	if n := len(e.users.recorded()) + len(e.engagement.recorded()); n != 0 {
		t.Errorf("user-service and engagement-service got %d calls for an empty page, want 0", n)
	}
}

// TestAuthorVideosWithoutProfile: user-service has no profile for the author, so the items go
// without author and keep their stats.
func TestAuthorVideosWithoutProfile(t *testing.T) {
	e := newEnvPatient(t)
	rec := e.do(t, http.MethodGet, "/users/"+userC+"/videos", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Items []map[string]any `json:"items"`
	}](t, rec)
	for _, item := range got.Items {
		if a, ok := item["author"]; ok {
			t.Errorf("item %v has author %v, want none", item["video_id"], a)
		}
		if _, ok := item["stats"]; !ok {
			t.Errorf("item %v has no stats", item["video_id"])
		}
	}
}

func TestAuthorVideosErrors(t *testing.T) {
	t.Run("page_size not an integer", func(t *testing.T) {
		e := newEnv(t)
		rec := e.do(t, http.MethodGet, "/users/"+userB+"/videos?page_size=abc", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusBadRequest)
		if p := decodeProblem(t, rec); p.Code != "INVALID_PAGE_SIZE" {
			t.Errorf("code = %q, want INVALID_PAGE_SIZE", p.Code)
		}
		if n := e.callCount(); n != 0 {
			t.Errorf("services got %d calls, want 0", n)
		}
	})
	t.Run("negative page_size goes to video-service", func(t *testing.T) {
		e := newEnv(t)
		rec := e.do(t, http.MethodGet, "/me/videos?page_size=-1", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusBadRequest)
		if p := decodeProblem(t, rec); p.Code != "INVALID_PAGE_SIZE" {
			t.Errorf("code = %q, want INVALID_PAGE_SIZE", p.Code)
		}
		if n := len(e.users.recorded()) + len(e.engagement.recorded()); n != 0 {
			t.Errorf("user-service and engagement-service got %d calls, want 0", n)
		}
	})
	t.Run("malformed user_id goes to video-service", func(t *testing.T) {
		e := newEnv(t)
		e.videos.fail(grpcerr.New(codes.InvalidArgument, "INVALID_AUTHOR_ID", "author_id must be a canonical lowercase UUID"))
		rec := e.do(t, http.MethodGet, "/users/NOT-a-uuid/videos", "", e.token(t, userA))
		wantStatus(t, rec, http.StatusBadRequest)
		if p := decodeProblem(t, rec); p.Code != "INVALID_AUTHOR_ID" {
			t.Errorf("code = %q, want INVALID_AUTHOR_ID", p.Code)
		}
		if got := e.videos.only(t).req.(*videov1.ListAuthorVideosRequest).GetAuthorId(); got != "NOT-a-uuid" {
			t.Errorf("author_id = %q, want NOT-a-uuid", got)
		}
	})
}

// TestExtrasSideBySide: GetProfiles and GetStats run at the same time. Each fake waits, within
// its own deadline, for the other call to arrive: called one after the other, the first would
// time out and its part of the answer would be missing.
func TestExtrasSideBySide(t *testing.T) {
	e := newEnvPatient(t)
	statsIn, authorsIn := make(chan struct{}), make(chan struct{})
	meet := func(mine, other chan struct{}) func(ctx context.Context, _ string) error {
		return func(ctx context.Context, _ string) error {
			close(mine)
			select {
			case <-other:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	e.engagement.setHook(meet(statsIn, authorsIn))
	e.users.setHook(meet(authorsIn, statsIn))
	rec := e.do(t, http.MethodGet, "/feed/explore", "", e.token(t, userA))
	wantStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Items []map[string]any `json:"items"`
	}](t, rec)
	for _, item := range got.Items {
		if _, ok := item["stats"]; !ok {
			t.Errorf("item %v has no stats", item["video_id"])
		}
		if _, ok := item["author"]; !ok {
			t.Errorf("item %v has no author", item["video_id"])
		}
	}
}

// TestFeedWithoutAuthorsWhenUserServiceSlow: GetProfiles past its 100 ms leaves every item
// without author, keeps the stats, and is only logged. The deadline and the number of calls are
// read where the gateway makes the call: under a loaded -race run the call may not even reach the
// fake user-service within 100 ms. GetStats outlives statsTimeout (patientExtras), so the stats
// do not race it either.
func TestFeedWithoutAuthorsWhenUserServiceSlow(t *testing.T) {
	logs := captureLog(t)
	// getProfiles is a GetProfiles call as the gateway made it: when, and with which deadline (the
	// zero time when it had none).
	type getProfiles struct{ at, deadline time.Time }
	var (
		mu    sync.Mutex
		calls []getProfiles
	)
	watch := grpc.WithChainUnaryInterceptor(func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		if method == userv1.UserService_GetProfiles_FullMethodName {
			d, _ := ctx.Deadline()
			mu.Lock()
			calls = append(calls, getProfiles{at: time.Now(), deadline: d})
			mu.Unlock()
		}
		return invoker(ctx, method, req, reply, cc, opts...)
	})
	e := newEnvDialed(t, httpx.ClientAddr{}, downLimits(t), []grpc.DialOption{watch}, []grpc.DialOption{patientExtras()})
	e.users.setHook(func(ctx context.Context, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	})
	start := time.Now()
	rec := e.do(t, http.MethodGet, "/feed/following", "", e.token(t, userA))
	end := time.Now()
	wantStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Items []map[string]any `json:"items"`
	}](t, rec)
	if len(got.Items) != 2 {
		t.Fatalf("body = %s", rec.Body.String())
	}
	for _, item := range got.Items {
		if a, ok := item["author"]; ok {
			t.Errorf("item %v has author %v, want none", item["video_id"], a)
		}
		if _, ok := item["stats"]; !ok {
			t.Errorf("item %v has no stats", item["video_id"])
		}
	}
	mu.Lock()
	seen := slices.Clone(calls)
	mu.Unlock()
	if len(seen) != 1 {
		t.Fatalf("gateway made %d GetProfiles calls, want 1: no retry", len(seen))
	}
	// The gateway set the deadline after start and before the call went out, so a deadline of
	// statsTimeout is at least statsTimeout after start and at most statsTimeout after the call,
	// whatever the machine's load.
	if c := seen[0]; c.deadline.Before(start.Add(statsTimeout)) || c.deadline.Sub(c.at) > statsTimeout {
		t.Errorf("GetProfiles deadline %v after the request started and %v after the call, want statsTimeout (%v)",
			c.deadline.Sub(start), c.deadline.Sub(c.at), statsTimeout)
	}
	// The deadline above bounds the wait; this only catches a request left to the 3 s call
	// deadline, as a busy machine can spend more than statsTimeout on the request alone.
	if elapsed := end.Sub(start); elapsed >= callTimeout {
		t.Errorf("request took %v, want under %v", elapsed, callTimeout)
	}
	if w := logLines(t, logs, "served without authors"); len(w) != 1 || w[0]["level"] != "WARN" || w[0]["grpc_code"] != "DeadlineExceeded" {
		t.Errorf("want one WARN about the authors missing after the deadline:\n%s", logs)
	}
}

// wantNoCaller fails the test if any call b received carries x-user-id.
func wantNoCaller(t *testing.T, b *backend) {
	t.Helper()
	for _, c := range b.recorded() {
		if v := c.md.Get(callerid.MetadataKey); len(v) != 0 {
			t.Errorf("%s got x-user-id %v, want none", c.method, v)
		}
	}
}

func TestPublicVideo(t *testing.T) {
	e := newEnvPatient(t)
	// No Authorization, a token that is not a JWT, and a valid token: the same answer, and no
	// call carries a caller.
	for _, auth := range []string{"", "not-a-jwt", e.token(t, userB)} {
		rec := e.do(t, http.MethodGet, "/public/videos/"+videoID, "", auth)
		wantStatus(t, rec, http.StatusOK)
		wantJSON(t, rec)
		if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=30" {
			t.Errorf("Cache-Control = %q, want public, max-age=30", cc)
		}
		got := decode[map[string]any](t, rec)
		want := map[string]any{
			"video_id":      videoID,
			"author_id":     userA,
			"title":         "first clip",
			"duration_ms":   float64(12345),
			"published_at":  "2026-10-11T01:05:00Z",
			"playlist_url":  mediaBase + "/media/" + videoID + "/master.m3u8",
			"thumbnail_url": mediaBase + "/media/" + videoID + "/thumb.jpg",
		}
		if len(got) != len(want)+2 {
			t.Errorf("body = %v, want %v with author and stats", got, want)
		}
		wantFeedItem(t, got, want)
		wantAuthor(t, got["author"], userA, "alice", "Alice")
		// The fake answers liked_by_me true for the first id; the route never passes it on.
		if st, _ := got["stats"].(map[string]any); len(st) != 2 || st["view_count"] != float64(100) || st["like_count"] != float64(1) {
			t.Errorf("stats = %v, want view_count and like_count only", got["stats"])
		}
	}
	for _, c := range e.videos.recorded() {
		if c.method != videov1.VideoService_GetPublicVideo_FullMethodName || c.req.(*videov1.GetPublicVideoRequest).GetVideoId() != videoID {
			t.Errorf("video call = %s %v", c.method, c.req)
		}
	}
	if n := len(e.videos.recorded()); n != 3 {
		t.Errorf("video-service got %d calls, want 3", n)
	}
	wantNoCaller(t, e.videos)
	wantNoCaller(t, e.users)
	wantNoCaller(t, e.engagement)
}

func TestPublicVideoErrors(t *testing.T) {
	for _, tc := range []struct {
		name, id   string
		err        error
		wantStatus int
		wantCode   string
	}{
		// video-service answers a video that is not READY and a malformed id the same way.
		{"not ready", "01928c6e-7b3a-7cde-8f01-222222222222", nil, http.StatusNotFound, "VIDEO_NOT_FOUND"},
		{"malformed id", "NOT-a-uuid", nil, http.StatusNotFound, "VIDEO_NOT_FOUND"},
		{"video-service unavailable", videoID, status.Error(codes.Unavailable, "video-service is down"), http.StatusServiceUnavailable, "UNAVAILABLE"},
		{"video-service failing", videoID, status.Error(codes.Internal, "db down"), http.StatusInternalServerError, "INTERNAL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newEnv(t)
			if tc.err != nil {
				e.videos.fail(tc.err)
			}
			rec := e.do(t, http.MethodGet, "/public/videos/"+tc.id, "", "")
			wantStatus(t, rec, tc.wantStatus)
			if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
				t.Errorf("Cache-Control = %q, want no-store", cc)
			}
			p := decodeProblem(t, rec)
			if p.Code != tc.wantCode {
				t.Errorf("code = %q, want %q", p.Code, tc.wantCode)
			}
			if tc.wantStatus == http.StatusNotFound && p.Detail != "video not found" {
				t.Errorf("detail = %q, want the one detail of every unviewable video", p.Detail)
			}
			if got := e.videos.only(t).req.(*videov1.GetPublicVideoRequest).GetVideoId(); got != tc.id {
				t.Errorf("video_id = %q, want %q", got, tc.id)
			}
			if n := len(e.users.recorded()) + len(e.engagement.recorded()); n != 0 {
				t.Errorf("user-service and engagement-service got %d calls, want 0", n)
			}
		})
	}
}

// TestPublicVideoWithSlowExtras: user-service and engagement-service past their 100 ms leave
// the video without author and stats, still a cacheable 200.
func TestPublicVideoWithSlowExtras(t *testing.T) {
	e := newEnv(t)
	hang := func(ctx context.Context, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	}
	e.users.setHook(hang)
	e.engagement.setHook(hang)
	rec := e.do(t, http.MethodGet, "/public/videos/"+videoID, "", "")
	wantStatus(t, rec, http.StatusOK)
	got := decode[map[string]any](t, rec)
	for _, k := range []string{"author", "stats"} {
		if v, ok := got[k]; ok {
			t.Errorf("body has %s %v, want none", k, v)
		}
	}
	if got["video_id"] != videoID {
		t.Errorf("body = %v", got)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "public, max-age=30" {
		t.Errorf("Cache-Control = %q", cc)
	}
}

// readDecisions makes a meter provider with a manual reader global until the test ends and
// returns a function that reads svp.ratelimit.decisions as "class result store" → value.
// Limiters built after it record there.
func readDecisions(t *testing.T) func() map[string]int64 {
	t.Helper()
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	prev := otel.GetMeterProvider()
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(prev)
		_ = mp.Shutdown(context.Background())
	})
	return func() map[string]int64 {
		t.Helper()
		var data metricdata.ResourceMetrics
		if err := reader.Collect(t.Context(), &data); err != nil {
			t.Fatal(err)
		}
		out := map[string]int64{}
		for _, scope := range data.ScopeMetrics {
			for _, m := range scope.Metrics {
				sum, ok := m.Data.(metricdata.Sum[int64])
				if m.Name != "svp.ratelimit.decisions" || !ok {
					continue
				}
				for _, p := range sum.DataPoints {
					class, _ := p.Attributes.Value("class")
					result, _ := p.Attributes.Value("result")
					store, _ := p.Attributes.Value("store")
					out[fmt.Sprintf("%s %s %s", class.AsString(), result.AsString(), store.AsString())] = p.Value
				}
			}
		}
		return out
	}
}

// TestPublicVideoRateLimitedByIP: class public counts each client IP before any service is
// called, a burst of 60 and one every 500 ms, and its 429 is never cached.
func TestPublicVideoRateLimitedByIP(t *testing.T) {
	logs := captureLog(t)
	collect := readDecisions(t)
	e := newRedisEnv(t)
	const ip = "192.0.2.1:5000"
	var calls int
	start := time.Now()
	rec := untilLimited(t, 60, time.Second/2, func(int) *httptest.ResponseRecorder {
		calls = e.callCount()
		// A token changes nothing: the route counts by IP.
		return e.send(t, ip, http.MethodGet, "/public/videos/"+videoID, "", e.token(t, userA), nil)
	})
	wantRateLimitedSince(t, rec, time.Second/2, start)
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("429 Cache-Control = %q, want no-store", cc)
	}
	if n := e.callCount(); n != calls {
		t.Errorf("the refused request reached a service (%d calls, want %d)", n, calls)
	}
	if rec := e.send(t, "192.0.2.2:5000", http.MethodGet, "/public/videos/"+videoID, "", "", nil); rec.Code != http.StatusOK {
		t.Errorf("another IP: status %d, want 200", rec.Code)
	}
	if !strings.Contains(logs.String(), `"rate_limit":"public"`) {
		t.Errorf("access log does not name the rate limit:\n%s", logs)
	}
	got := collect()
	if got["public limited redis"] < 1 || got["public allowed redis"] < 61 || got["public allowed fallback"] != 0 {
		t.Errorf("decisions = %v, want class public on redis", got)
	}
	e.wantTTLs(t)
}

// TestPublicVideoLimitedWhileRedisDown: class public is soft-closed, so while Redis fails the
// in-memory fallback still limits it, to a burst of 30 and one every 2 s, counted under
// store="fallback" (threat model RL-2).
func TestPublicVideoLimitedWhileRedisDown(t *testing.T) {
	collect := readDecisions(t)
	e := newEnv(t)
	const ip = "192.0.2.1:5000"
	start := time.Now()
	rec := untilLimited(t, 30, 2*time.Second, func(int) *httptest.ResponseRecorder {
		return e.send(t, ip, http.MethodGet, "/public/videos/"+videoID, "", "", nil)
	})
	wantRateLimitedSince(t, rec, 2*time.Second, start)
	got := collect()
	if got["public limited fallback"] != 1 || got["public allowed fallback"] < 30 {
		t.Errorf("decisions = %v, want class public on the fallback", got)
	}
}
