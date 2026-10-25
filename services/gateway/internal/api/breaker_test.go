package api

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/breaker"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
)

// TestEngagementBreakerOpen: once engagement-service's breaker opens, likes fail at once with
// 503 and the feed answers at once without stats, neither reaching engagement-service. It
// checks no wall-clock bound tighter than a call's own deadline: a loaded -race run can spend
// more than half of statsTimeout on a feed request alone.
func TestEngagementBreakerOpen(t *testing.T) {
	logs := captureLog(t)
	e := newEnvWithLimits(t, downLimits(t),
		grpc.WithUnaryInterceptor(breaker.New("engagement-service", engagementv1.EngagementService_GetStats_FullMethodName)))
	e.engagement.fail(status.Error(codes.Unavailable, "engagement-service is down"))
	token := e.token(t, userA)

	for range 5 {
		wantStatus(t, e.do(t, http.MethodPut, "/videos/"+videoID+"/like", "", token), http.StatusServiceUnavailable)
	}
	if got := len(e.engagement.recorded()); got != 5 {
		t.Fatalf("engagement-service got %d calls, want 5", got)
	}

	// From now on a call that got past the breaker would hang until its deadline and fail with
	// DEADLINE_EXCEEDED, so a leak shows as a recorded call, a wait of a whole timeout and the
	// wrong error, not as a few milliseconds that a busy machine can spend anyway.
	e.engagement.setHook(func(ctx context.Context, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	})

	start := time.Now()
	rec := e.do(t, http.MethodPut, "/videos/"+videoID+"/like", "", token)
	if elapsed := time.Since(start); elapsed >= callTimeout {
		t.Errorf("like with the breaker open took %v, want under %v", elapsed, callTimeout)
	}
	wantStatus(t, rec, http.StatusServiceUnavailable)
	if p := decodeProblem(t, rec); p.Code != "UNAVAILABLE" || p.Detail != "" {
		t.Errorf("problem = %+v, want code UNAVAILABLE and no detail", p)
	}

	feedLogsFrom := logs.Len()
	rec = e.do(t, http.MethodGet, "/feed/following", "", token)
	wantStatus(t, rec, http.StatusOK)
	got := decode[struct {
		Items []map[string]any `json:"items"`
	}](t, rec)
	if len(got.Items) != 2 {
		t.Fatalf("body = %s", rec.Body.String())
	}
	for _, item := range got.Items {
		if st, ok := item["stats"]; ok {
			t.Errorf("item %v has stats %v, want none", item["video_id"], st)
		}
	}
	if got := len(e.engagement.recorded()); got != 5 {
		t.Errorf("engagement-service got %d calls, want still 5", got)
	}
	// The feed went without stats because the breaker refused GetStats, not because statsTimeout
	// ran out: a call that waited would log DeadlineExceeded instead.
	if feedLogs := logs.String()[feedLogsFrom:]; !strings.Contains(feedLogs, `"msg":"served without stats"`) ||
		!strings.Contains(feedLogs, `"error":"rpc error: code = Unavailable desc = engagement-service: circuit breaker is open"`) {
		t.Errorf("feed log lacks the breaker's refusal of GetStats:\n%s", feedLogs)
	}
	if !strings.Contains(logs.String(), `"msg":"circuit breaker state changed"`) ||
		!strings.Contains(logs.String(), `"grpc_code":"Unavailable"`) {
		t.Errorf("log lacks the state change or the stats warning:\n%s", logs.String())
	}
}

// TestUserBreakerOpen: once user-service's breaker opens, follows fail at once with 503 and the
// feed answers without authors, keeping its stats, without GetProfiles reaching user-service.
func TestUserBreakerOpen(t *testing.T) {
	logs := captureLog(t)
	e := newEnvDialed(t, httpx.ClientAddr{}, downLimits(t),
		[]grpc.DialOption{grpc.WithUnaryInterceptor(breaker.New("user-service", userv1.UserService_GetProfiles_FullMethodName))},
		[]grpc.DialOption{patientExtras()})
	e.users.fail(status.Error(codes.Unavailable, "user-service is down"))
	token := e.token(t, userA)

	for range 5 {
		wantStatus(t, e.do(t, http.MethodPut, "/me/following/"+userB, "", token), http.StatusServiceUnavailable)
	}
	if got := len(e.users.recorded()); got != 5 {
		t.Fatalf("user-service got %d calls, want 5", got)
	}
	// As in TestEngagementBreakerOpen, a call that got past the breaker would now hang until its
	// deadline and log DeadlineExceeded.
	e.users.setHook(func(ctx context.Context, _ string) error {
		<-ctx.Done()
		return ctx.Err()
	})

	feedLogsFrom := logs.Len()
	rec := e.do(t, http.MethodGet, "/feed/following", "", token)
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
	if got := len(e.users.recorded()); got != 5 {
		t.Errorf("user-service got %d calls, want still 5", got)
	}
	if feedLogs := logs.String()[feedLogsFrom:]; !strings.Contains(feedLogs, `"msg":"served without authors"`) ||
		!strings.Contains(feedLogs, `"error":"rpc error: code = Unavailable desc = user-service: circuit breaker is open"`) {
		t.Errorf("feed log lacks the breaker's refusal of GetProfiles:\n%s", feedLogs)
	}
}
