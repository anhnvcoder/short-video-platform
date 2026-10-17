package main

import (
	"context"
	"encoding/json"
	"net"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
)

func TestParseMediaBaseURL(t *testing.T) {
	for _, tc := range []struct {
		name, in, want string
		wantErr        bool
	}{
		{name: "http", in: "http://127.0.0.1:9000/media", want: "http://127.0.0.1:9000/media"},
		{name: "https cdn", in: "https://cdn.example.com", want: "https://cdn.example.com"},
		{name: "trailing slash is dropped", in: "http://127.0.0.1:9000/media/", want: "http://127.0.0.1:9000/media"},
		{name: "empty", in: "", wantErr: true},
		{name: "relative path", in: "/media", wantErr: true},
		{name: "no scheme", in: "127.0.0.1:9000/media", wantErr: true},
		{name: "unknown scheme", in: "ftp://example.com/media", wantErr: true},
		{name: "no host", in: "http:///media", wantErr: true},
		{name: "not a url", in: "http://[::1", wantErr: true},
		{name: "query", in: "http://127.0.0.1:9000/media?x=1", wantErr: true},
		{name: "empty query", in: "http://127.0.0.1:9000/media?", wantErr: true},
		{name: "fragment", in: "http://127.0.0.1:9000/media#x", wantErr: true},
		{name: "empty fragment", in: "http://127.0.0.1:9000/media#", wantErr: true},
		{name: "userinfo", in: "http://user:secret@127.0.0.1:9000/media", wantErr: true}, //nolint:gosec // fake userinfo is the case under test
		{name: "user only", in: "http://user@127.0.0.1:9000/media", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseMediaBaseURL(tc.in)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// fakeServer answers every method with answer(method, n), n counting that method's calls from 1
// (nil: an empty message), and records the calls.
type fakeServer struct {
	mu     sync.Mutex
	calls  map[string]int
	answer func(ctx context.Context, method string, n int) error
}

func (f *fakeServer) handle(_ any, stream grpc.ServerStream) error {
	if err := stream.RecvMsg(&emptypb.Empty{}); err != nil {
		return err
	}
	method, _ := grpc.MethodFromServerStream(stream)
	f.mu.Lock()
	f.calls[method]++
	n := f.calls[method]
	f.mu.Unlock()
	if err := f.answer(stream.Context(), method, n); err != nil {
		return err
	}
	return stream.SendMsg(&emptypb.Empty{})
}

func (f *fakeServer) count(method string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[method]
}

// connect serves a fakeServer with answer on bufconn and returns it with a connection dialed
// with b's options, as serve dials b.
func connect(t *testing.T, b backend, answer func(ctx context.Context, method string, n int) error) (*fakeServer, *grpc.ClientConn) {
	t.Helper()
	f := &fakeServer{calls: map[string]int{}, answer: answer}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.UnknownServiceHandler(f.handle))
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	opts := append(b.dialOptions(), grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
		return lis.DialContext(ctx)
	}))
	conn, err := grpc.NewClient("passthrough:///bufnet", opts...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return f, conn
}

func invoke(ctx context.Context, conn *grpc.ClientConn, method string) error {
	return conn.Invoke(ctx, method, &emptypb.Empty{}, &emptypb.Empty{})
}

var backends = []backend{userBackend, videoBackend, feedBackend, engagementBackend}

func TestServiceConfig(t *testing.T) {
	type name struct{ Service, Method string }
	// The idempotent methods of ADR-0010 section 4: only these are retried, as a second try of
	// any other would repeat its effect.
	want := map[string][]name{
		"user-service": {
			{"svp.user.v1.UserService", "Follow"},
			{"svp.user.v1.UserService", "Unfollow"},
		},
		"video-service": {
			{"svp.video.v1.VideoService", "GetVideo"},
			{"svp.video.v1.VideoService", "CompleteUpload"},
		},
		"feed-service": {
			{"svp.feed.v1.FeedService", "GetFollowingFeed"},
			{"svp.feed.v1.FeedService", "GetExploreFeed"},
		},
		"engagement-service": {
			{"svp.engagement.v1.EngagementService", "Like"},
			{"svp.engagement.v1.EngagementService", "Unlike"},
		},
	}
	fullName := regexp.MustCompile(`^/svp\.[a-z]+\.v1\.[A-Za-z]+Service/[A-Za-z]+$`)
	for _, b := range backends {
		t.Run(b.name, func(t *testing.T) {
			for _, m := range b.retry {
				if !fullName.MatchString(m) {
					t.Errorf("retry method %q is not a full method name", m)
				}
			}
			var cfg struct {
				MethodConfig []struct {
					Name        []name
					RetryPolicy struct {
						MaxAttempts          int
						InitialBackoff       string
						MaxBackoff           string
						BackoffMultiplier    float64
						RetryableStatusCodes []string
					}
				}
				RetryThrottling struct {
					MaxTokens  float64
					TokenRatio float64
				}
			}
			dec := json.NewDecoder(strings.NewReader(b.serviceConfig()))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&cfg); err != nil {
				t.Fatalf("service config: %v\n%s", err, b.serviceConfig())
			}
			if len(cfg.MethodConfig) != 1 {
				t.Fatalf("methodConfig has %d entries, want 1", len(cfg.MethodConfig))
			}
			mc := cfg.MethodConfig[0]
			if !slices.Equal(mc.Name, want[b.name]) {
				t.Errorf("names = %v, want %v", mc.Name, want[b.name])
			}
			rp := mc.RetryPolicy
			if rp.MaxAttempts != 3 || rp.InitialBackoff != "0.05s" || rp.MaxBackoff != "0.2s" || rp.BackoffMultiplier != 2 ||
				!slices.Equal(rp.RetryableStatusCodes, []string{"UNAVAILABLE"}) {
				t.Errorf("retryPolicy = %+v", rp)
			}
			if cfg.RetryThrottling.MaxTokens != 10 || cfg.RetryThrottling.TokenRatio != 0.1 {
				t.Errorf("retryThrottling = %+v", cfg.RetryThrottling)
			}
			conn, err := grpc.NewClient("passthrough:///unused", b.dialOptions()...)
			if err != nil {
				t.Fatalf("grpc.NewClient refused the dial options: %v", err)
			}
			_ = conn.Close()
		})
	}
	// grpc.NewClient does check the service config, so the check above means something.
	if _, err := grpc.NewClient("passthrough:///unused",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultServiceConfig(`{"methodConfig": [{"retryPolicy": {"maxAttempts": "x"}}]}`),
	); err == nil {
		t.Error("grpc.NewClient accepted an invalid service config")
	}
}

func TestRetry(t *testing.T) {
	type tc struct {
		b      backend
		method string
	}
	var idempotent []tc
	for _, b := range backends {
		for _, m := range b.retry {
			idempotent = append(idempotent, tc{b, m})
		}
	}
	notIdempotent := []tc{
		{userBackend, userv1.UserService_Register_FullMethodName},
		{userBackend, userv1.UserService_Login_FullMethodName},
		{videoBackend, videov1.VideoService_InitUpload_FullMethodName},
		{engagementBackend, engagementv1.EngagementService_RecordView_FullMethodName},
		{engagementBackend, engagementv1.EngagementService_GetStats_FullMethodName},
	}
	unavailableOnce := func(_ context.Context, _ string, n int) error {
		if n == 1 {
			return status.Error(codes.Unavailable, "restarting")
		}
		return nil
	}

	for _, c := range idempotent {
		t.Run("unavailable then ok "+c.method, func(t *testing.T) {
			f, conn := connect(t, c.b, unavailableOnce)
			if err := invoke(t.Context(), conn, c.method); err != nil {
				t.Fatalf("error = %v, want success after a retry", err)
			}
			if got := f.count(c.method); got != 2 {
				t.Errorf("server got %d attempts, want 2", got)
			}
		})
		t.Run("deadline exceeded "+c.method, func(t *testing.T) {
			f, conn := connect(t, c.b, func(context.Context, string, int) error {
				return status.Error(codes.DeadlineExceeded, "too slow")
			})
			if err := invoke(t.Context(), conn, c.method); status.Code(err) != codes.DeadlineExceeded {
				t.Fatalf("error = %v, want DEADLINE_EXCEEDED", err)
			}
			if got := f.count(c.method); got != 1 {
				t.Errorf("server got %d attempts, want 1", got)
			}
		})
	}
	for _, c := range notIdempotent {
		t.Run("not retried "+c.method, func(t *testing.T) {
			f, conn := connect(t, c.b, unavailableOnce)
			if err := invoke(t.Context(), conn, c.method); status.Code(err) != codes.Unavailable {
				t.Fatalf("error = %v, want UNAVAILABLE", err)
			}
			if got := f.count(c.method); got != 1 {
				t.Errorf("server got %d attempts, want 1", got)
			}
		})
	}
	t.Run("at most three attempts", func(t *testing.T) {
		method := userv1.UserService_Follow_FullMethodName
		f, conn := connect(t, userBackend, func(context.Context, string, int) error {
			return status.Error(codes.Unavailable, "down")
		})
		if err := invoke(t.Context(), conn, method); status.Code(err) != codes.Unavailable {
			t.Fatalf("error = %v, want UNAVAILABLE", err)
		}
		if got := f.count(method); got != 3 {
			t.Errorf("server got %d attempts, want 3", got)
		}
	})
}

// TestBreakerPerBackend: user-service failing opens its own breaker only.
func TestBreakerPerBackend(t *testing.T) {
	down := func(context.Context, string, int) error { return status.Error(codes.Unavailable, "down") }
	users, userConn := connect(t, userBackend, down)
	videos, videoConn := connect(t, videoBackend, func(context.Context, string, int) error { return nil })

	register := userv1.UserService_Register_FullMethodName
	for range 5 {
		if err := invoke(t.Context(), userConn, register); status.Code(err) != codes.Unavailable {
			t.Fatalf("error = %v, want UNAVAILABLE", err)
		}
	}
	start := time.Now()
	if err := invoke(t.Context(), userConn, register); status.Code(err) != codes.Unavailable {
		t.Fatalf("error = %v, want UNAVAILABLE from the open breaker", err)
	}
	if elapsed := time.Since(start); elapsed > 10*time.Millisecond {
		t.Errorf("rejected call took %v", elapsed)
	}
	if got := users.count(register); got != 5 {
		t.Errorf("user-service got %d calls, want 5", got)
	}

	getVideo := videov1.VideoService_GetVideo_FullMethodName
	if err := invoke(t.Context(), videoConn, getVideo); err != nil {
		t.Fatalf("video-service call: %v", err)
	}
	if got := videos.count(getVideo); got != 1 {
		t.Errorf("video-service got %d calls, want 1", got)
	}
}

// TestSlowStatsDoNotOpenBreaker: GetStats running past its 100 ms budget again and again leaves
// engagement-service's breaker closed, so likes and views still reach it (ADR-0010 section 4).
func TestSlowStatsDoNotOpenBreaker(t *testing.T) {
	getStats := engagementv1.EngagementService_GetStats_FullMethodName
	f, conn := connect(t, engagementBackend, func(ctx context.Context, method string, _ int) error {
		if method != getStats {
			return nil
		}
		select {
		case <-time.After(200 * time.Millisecond):
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	for range 8 {
		ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
		err := invoke(ctx, conn, getStats)
		cancel()
		if status.Code(err) != codes.DeadlineExceeded {
			t.Fatalf("GetStats error = %v, want DEADLINE_EXCEEDED", err)
		}
	}
	for _, m := range []string{
		engagementv1.EngagementService_Like_FullMethodName,
		engagementv1.EngagementService_RecordView_FullMethodName,
	} {
		if err := invoke(t.Context(), conn, m); err != nil {
			t.Fatalf("%s: %v", m, err)
		}
		if got := f.count(m); got != 1 {
			t.Errorf("%s reached engagement-service %d times, want 1", m, got)
		}
	}
}
