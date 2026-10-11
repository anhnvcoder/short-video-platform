// Package breaker puts a circuit breaker in front of the gRPC calls to one service, so the
// gateway fails at once while that service is down instead of waiting out every call's deadline
// (ADR-0010 section 4).
package breaker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/sony/gobreaker/v2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
)

// thresholds says when a breaker opens and for how long.
type thresholds struct {
	// consecutive failures open the breaker.
	consecutive uint32
	// minCalls calls with a failure ratio of at least ratio within window also open it.
	minCalls uint32
	ratio    float64
	// window is the sliding window of the counts, made of buckets of bucket each.
	window, bucket time.Duration
	// openFor is how long the breaker stays open before it lets one trial call through.
	openFor time.Duration
}

// adr are the thresholds of ADR-0010 section 4.
var adr = thresholds{
	consecutive: 5,
	minCalls:    20,
	ratio:       0.5,
	window:      10 * time.Second,
	bucket:      1 * time.Second,
	openFor:     5 * time.Second,
}

var (
	// errFailure and errExcluded are what the breaker sees of a call's result: a failure, or a
	// result that counts neither way. Anything else the call returns counts as a success.
	errFailure  = errors.New("failure")
	errExcluded = errors.New("excluded")
)

// New returns a unary client interceptor that runs every call to service through one circuit
// breaker. UNAVAILABLE and DEADLINE_EXCEEDED count as failures; CANCELLED (the client went away)
// counts neither way; any other code means the service answered and counts as a success. An
// UNAVAILABLE carrying an ErrorInfo of the platform's domain is the service answering that one of
// its own dependencies is down, so it counts neither way either: it must not cut off the methods
// that do not need that dependency. For
// the methods in ignoreDeadline (full names, "/pkg.Service/Method"), DEADLINE_EXCEEDED counts
// neither way either: their own short deadline running out says nothing about the service.
// While the breaker is open, or half-open with its one trial call under way, a call fails at
// once with UNAVAILABLE and nothing goes on the wire. grpc.health.v1.Health/Check bypasses the
// breaker, so readiness sees the service as it is. Every state change is logged as a warning.
func New(service string, ignoreDeadline ...string) grpc.UnaryClientInterceptor {
	return newInterceptor(adr, service, ignoreDeadline)
}

func newInterceptor(th thresholds, service string, ignoreDeadline []string) grpc.UnaryClientInterceptor {
	cb := gobreaker.NewCircuitBreaker[struct{}](gobreaker.Settings{
		Name:         service,
		MaxRequests:  1,
		Interval:     th.window,
		BucketPeriod: th.bucket,
		Timeout:      th.openFor,
		ReadyToTrip: func(c gobreaker.Counts) bool {
			// Requests also counts excluded calls and calls still under way, so the ratio is
			// taken over the calls that counted.
			calls := c.TotalSuccesses + c.TotalFailures
			return c.ConsecutiveFailures >= th.consecutive ||
				(calls >= th.minCalls && float64(c.TotalFailures) >= th.ratio*float64(calls))
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			slog.Warn("circuit breaker state changed",
				slog.String("target", name),
				slog.String("from", from.String()),
				slog.String("to", to.String()),
			)
		},
		IsExcluded: func(err error) bool { return errors.Is(err, errExcluded) },
	})

	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		if method == healthpb.Health_Check_FullMethodName {
			return invoker(ctx, method, req, reply, cc, opts...)
		}
		var callErr error
		_, err := cb.Execute(func() (struct{}, error) {
			callErr = invoker(ctx, method, req, reply, cc, opts...)
			return struct{}{}, classify(callErr, slices.Contains(ignoreDeadline, method))
		})
		if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
			return status.Error(codes.Unavailable, fmt.Sprintf("%s: %v", service, err))
		}
		return callErr
	}
}

// classify turns a call's error into what the breaker counts.
func classify(err error, ignoreDeadline bool) error {
	switch status.Code(err) {
	case codes.Unavailable:
		if grpcerr.Reason(err) != "" {
			return errExcluded
		}
		return errFailure
	case codes.DeadlineExceeded:
		if ignoreDeadline {
			return errExcluded
		}
		return errFailure
	case codes.Canceled:
		return errExcluded
	default:
		return nil
	}
}
