package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/breaker"
)

// TestEngagementBreakerOpen: once engagement-service's breaker opens, likes fail at once with
// 503 and the feed answers at once without stats, neither reaching engagement-service
// (ADR-0010 section 4).
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

	start := time.Now()
	rec := e.do(t, http.MethodPut, "/videos/"+videoID+"/like", "", token)
	// Far under callTimeout (3 s), with room for a slow -race run: the like does not wait for a
	// call the breaker refuses. That no call reaches engagement-service is checked below.
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Errorf("like with the breaker open took %v, want well under %v", elapsed, callTimeout)
	}
	wantStatus(t, rec, http.StatusServiceUnavailable)
	if p := decodeProblem(t, rec); p.Code != "UNAVAILABLE" || p.Detail != "" {
		t.Errorf("problem = %+v, want code UNAVAILABLE and no detail", p)
	}

	start = time.Now()
	rec = e.do(t, http.MethodGet, "/feed/following", "", token)
	// Well under statsTimeout: the feed does not wait for a call the breaker refuses.
	if elapsed := time.Since(start); elapsed > statsTimeout/2 {
		t.Errorf("feed with the breaker open took %v, want well under %v", elapsed, statsTimeout)
	}
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
	if !strings.Contains(logs.String(), `"msg":"circuit breaker state changed"`) ||
		!strings.Contains(logs.String(), `"grpc_code":"Unavailable"`) {
		t.Errorf("log lacks the state change or the stats warning:\n%s", logs.String())
	}
}
