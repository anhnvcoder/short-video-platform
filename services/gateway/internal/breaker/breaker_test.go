package breaker

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
)

const (
	testMethod  = "/svp.test.v1.TestService/Do"
	statsMethod = "/svp.test.v1.TestService/Stats"
	// rejectWithin is how fast a call the breaker refuses must fail.
	rejectWithin = 10 * time.Millisecond
)

// fast are the production thresholds (breaker.go) with a short open period, so tests reach half-open quickly.
var fast = func() thresholds {
	th := production
	th.openFor = 50 * time.Millisecond
	return th
}()

// fake is a gRPC server on a bufconn listener: every method but the standard health service
// gets the error answer returns (nil: an empty message), and is counted.
type fake struct {
	mu     sync.Mutex
	calls  int
	answer func(ctx context.Context) error
}

func (f *fake) handle(_ any, stream grpc.ServerStream) error {
	if err := stream.RecvMsg(&emptypb.Empty{}); err != nil {
		return err
	}
	f.mu.Lock()
	f.calls++
	answer := f.answer
	f.mu.Unlock()
	if answer != nil {
		if err := answer(stream.Context()); err != nil {
			return err
		}
	}
	return stream.SendMsg(&emptypb.Empty{})
}

func (f *fake) setAnswer(answer func(ctx context.Context) error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.answer = answer
}

// fail makes every call answer code.
func (f *fake) fail(code codes.Code) {
	f.setAnswer(func(context.Context) error { return status.Error(code, "fake "+code.String()) })
}

func (f *fake) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// start serves a fake on bufconn and returns it with a client connection that goes through
// the interceptor.
func start(t *testing.T, interceptor grpc.UnaryClientInterceptor) (*fake, *grpc.ClientConn) {
	t.Helper()
	f := &fake{}
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.UnknownServiceHandler(f.handle))
	healthpb.RegisterHealthServer(srv, health.NewServer())
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(interceptor),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return f, conn
}

func invoke(ctx context.Context, conn *grpc.ClientConn, method string) error {
	return conn.Invoke(ctx, method, &emptypb.Empty{}, &emptypb.Empty{})
}

// callN makes n calls to method and fails the test unless each returns want.
func callN(t *testing.T, conn *grpc.ClientConn, method string, n int, want codes.Code) {
	t.Helper()
	for i := range n {
		if got := status.Code(invoke(t.Context(), conn, method)); got != want {
			t.Fatalf("call %d: code %v, want %v", i+1, got, want)
		}
	}
}

// wantRejected checks that a call fails at once with UNAVAILABLE without reaching f.
func wantRejected(t *testing.T, f *fake, conn *grpc.ClientConn, method string) {
	t.Helper()
	before := f.count()
	start := time.Now()
	err := invoke(t.Context(), conn, method)
	elapsed := time.Since(start)
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("error = %v, want UNAVAILABLE", err)
	}
	if elapsed > rejectWithin {
		t.Errorf("rejected call took %v, want under %v", elapsed, rejectWithin)
	}
	if got := f.count(); got != before {
		t.Errorf("server got %d calls while the breaker was open", got-before)
	}
}

// wantReaches checks that a call reaches f.
func wantReaches(t *testing.T, f *fake, conn *grpc.ClientConn, method string) {
	t.Helper()
	before := f.count()
	_ = invoke(t.Context(), conn, method)
	if f.count() != before+1 {
		t.Fatal("call did not reach the server")
	}
}

func TestOpensAfterConsecutiveFailures(t *testing.T) {
	for _, code := range []codes.Code{codes.Unavailable, codes.DeadlineExceeded} {
		t.Run(code.String(), func(t *testing.T) {
			f, conn := start(t, New("test-service"))
			f.fail(code)
			callN(t, conn, testMethod, 4, code)
			wantReaches(t, f, conn, testMethod)
			wantRejected(t, f, conn, testMethod)
			wantRejected(t, f, conn, testMethod)
		})
	}
}

func TestServiceAnswersDoNotOpen(t *testing.T) {
	for _, code := range []codes.Code{codes.NotFound, codes.InvalidArgument, codes.ResourceExhausted, codes.FailedPrecondition, codes.Internal} {
		t.Run(code.String(), func(t *testing.T) {
			f, conn := start(t, New("test-service"))
			f.fail(code)
			callN(t, conn, testMethod, 30, code)
			if got := f.count(); got != 30 {
				t.Errorf("server got %d calls, want 30", got)
			}
		})
	}
}

// TestSuccessResetsConsecutiveFailures: four failures, a success, four failures never make five
// in a row, and stay under the 20-call minimum of the ratio rule.
func TestSuccessResetsConsecutiveFailures(t *testing.T) {
	f, conn := start(t, New("test-service"))
	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 4, codes.Unavailable)
	f.setAnswer(nil)
	callN(t, conn, testMethod, 1, codes.OK)
	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 4, codes.Unavailable)
	wantReaches(t, f, conn, testMethod)
}

// TestCancelledCountsNeitherWay: cancelled calls between failures neither reset the run of
// failures (a success would) nor add to it.
func TestCancelledCountsNeitherWay(t *testing.T) {
	f, conn := start(t, New("test-service"))
	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 4, codes.Unavailable)

	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	for range 10 {
		if err := invoke(cancelled, conn, testMethod); status.Code(err) != codes.Canceled {
			t.Fatalf("error = %v, want CANCELLED", err)
		}
	}
	// A call cancelled while the server works on it.
	f.setAnswer(func(ctx context.Context) error {
		<-ctx.Done()
		return ctx.Err()
	})
	inFlight, cancelInFlight := context.WithCancel(t.Context())
	time.AfterFunc(20*time.Millisecond, cancelInFlight)
	if err := invoke(inFlight, conn, testMethod); status.Code(err) != codes.Canceled {
		t.Fatalf("error = %v, want CANCELLED", err)
	}

	f.fail(codes.Unavailable)
	wantReaches(t, f, conn, testMethod) // the fifth failure in a row
	wantRejected(t, f, conn, testMethod)
}

// TestDependencyUnavailableDoesNotOpen: a service answering UNAVAILABLE with the platform's
// ErrorInfo (one of its dependencies is down) neither opens the breaker nor breaks a run of
// UNAVAILABLE without one (the service itself unreachable), which still opens it.
func TestDependencyUnavailableDoesNotOpen(t *testing.T) {
	f, conn := start(t, New("test-service"))
	dependencyDown := func(context.Context) error {
		return grpcerr.New(codes.Unavailable, "DEPENDENCY_UNAVAILABLE", "storage unavailable")
	}
	f.setAnswer(dependencyDown)
	callN(t, conn, testMethod, 30, codes.Unavailable)
	if got := f.count(); got != 30 {
		t.Fatalf("server got %d calls, want 30", got)
	}

	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 4, codes.Unavailable)
	f.setAnswer(dependencyDown)
	callN(t, conn, testMethod, 3, codes.Unavailable)
	f.fail(codes.Unavailable)
	wantReaches(t, f, conn, testMethod) // the fifth UNAVAILABLE without ErrorInfo in a row
	wantRejected(t, f, conn, testMethod)
}

func TestIgnoreDeadline(t *testing.T) {
	f, conn := start(t, New("test-service", statsMethod))
	f.fail(codes.DeadlineExceeded)
	callN(t, conn, statsMethod, 30, codes.DeadlineExceeded)
	// Other methods still count DEADLINE_EXCEEDED.
	callN(t, conn, testMethod, 5, codes.DeadlineExceeded)
	wantRejected(t, f, conn, testMethod)
	wantRejected(t, f, conn, statsMethod)
}

func TestIgnoreDeadlineStillCountsUnavailable(t *testing.T) {
	f, conn := start(t, New("test-service", statsMethod))
	f.fail(codes.Unavailable)
	callN(t, conn, statsMethod, 5, codes.Unavailable)
	wantRejected(t, f, conn, testMethod)
}

func TestOpensOnFailureRatio(t *testing.T) {
	f, conn := start(t, New("test-service"))
	// Failure, success, failure, ... : never two failures in a row.
	for i := range 21 {
		if i%2 == 0 {
			f.fail(codes.Unavailable)
		} else {
			f.setAnswer(nil)
		}
		wantReaches(t, f, conn, testMethod)
	}
	// The 21st call was the 11th failure out of 21: at least 20 calls, at least half failed.
	wantRejected(t, f, conn, testMethod)
}

func TestStaysClosedUnderFailureRatio(t *testing.T) {
	f, conn := start(t, New("test-service"))
	// One failure in three.
	for i := range 60 {
		if i%3 == 0 {
			f.fail(codes.Unavailable)
		} else {
			f.setAnswer(nil)
		}
		wantReaches(t, f, conn, testMethod)
	}
}

// trip opens the breaker in front of f with five UNAVAILABLE calls.
func trip(t *testing.T, f *fake, conn *grpc.ClientConn) {
	t.Helper()
	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 5, codes.Unavailable)
	wantRejected(t, f, conn, testMethod)
}

func TestHalfOpenTrialSucceeds(t *testing.T) {
	f, conn := start(t, newInterceptor(fast, "test-service", nil))
	trip(t, f, conn)
	time.Sleep(fast.openFor + 20*time.Millisecond)
	f.setAnswer(nil)
	callN(t, conn, testMethod, 1, codes.OK)
	// Closed again: a fresh run of four failures does not open it.
	f.fail(codes.Unavailable)
	callN(t, conn, testMethod, 4, codes.Unavailable)
	wantReaches(t, f, conn, testMethod)
}

func TestHalfOpenTrialFails(t *testing.T) {
	f, conn := start(t, newInterceptor(fast, "test-service", nil))
	trip(t, f, conn)
	time.Sleep(fast.openFor + 20*time.Millisecond)
	wantReaches(t, f, conn, testMethod)
	wantRejected(t, f, conn, testMethod)
	// Open for another full period, then a trial again.
	time.Sleep(fast.openFor + 20*time.Millisecond)
	f.setAnswer(nil)
	callN(t, conn, testMethod, 1, codes.OK)
}

func TestHalfOpenLetsOneTrialThrough(t *testing.T) {
	f, conn := start(t, newInterceptor(fast, "test-service", nil))
	trip(t, f, conn)
	time.Sleep(fast.openFor + 20*time.Millisecond)

	arrived := make(chan struct{})
	release := make(chan struct{})
	f.setAnswer(func(context.Context) error {
		close(arrived)
		<-release
		return nil
	})
	trial := make(chan error, 1)
	go func() { trial <- invoke(t.Context(), conn, testMethod) }()
	<-arrived
	wantRejected(t, f, conn, testMethod)
	close(release)
	if err := <-trial; err != nil {
		t.Fatalf("trial call: %v", err)
	}
	f.setAnswer(nil)
	wantReaches(t, f, conn, testMethod)
}

func TestHealthCheckBypassesBreaker(t *testing.T) {
	f, conn := start(t, New("test-service"))
	trip(t, f, conn)
	resp, err := healthpb.NewHealthClient(conn).Check(t.Context(), &healthpb.HealthCheckRequest{})
	if err != nil {
		t.Fatalf("health check with the breaker open: %v", err)
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("status = %v, want SERVING", resp.GetStatus())
	}
}

func TestStateChangesLogged(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	f, conn := start(t, newInterceptor(fast, "video-service", nil))
	trip(t, f, conn)
	time.Sleep(fast.openFor + 20*time.Millisecond)
	f.setAnswer(nil)
	callN(t, conn, testMethod, 1, codes.OK)

	type entry struct {
		Level, Msg, Target, From, To string
	}
	var got []entry
	dec := json.NewDecoder(&buf)
	for dec.More() {
		var e entry
		if err := dec.Decode(&e); err != nil {
			t.Fatal(err)
		}
		got = append(got, e)
	}
	want := []entry{
		{"WARN", "circuit breaker state changed", "video-service", "closed", "open"},
		{"WARN", "circuit breaker state changed", "video-service", "open", "half-open"},
		{"WARN", "circuit breaker state changed", "video-service", "half-open", "closed"},
	}
	if len(got) != len(want) {
		t.Fatalf("log entries = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("entry %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestConcurrentCalls(t *testing.T) {
	f, conn := start(t, newInterceptor(fast, "test-service", nil))
	var n sync.Mutex
	i := 0
	f.setAnswer(func(context.Context) error {
		n.Lock()
		defer n.Unlock()
		i++
		if i%2 == 0 {
			return status.Error(codes.Unavailable, "down")
		}
		return nil
	})
	var wg sync.WaitGroup
	for range 32 {
		wg.Go(func() {
			for range 50 {
				if err := invoke(t.Context(), conn, testMethod); err != nil && status.Code(err) != codes.Unavailable {
					t.Errorf("error = %v, want nil or UNAVAILABLE", err)
				}
			}
		})
	}
	wg.Wait()
}
