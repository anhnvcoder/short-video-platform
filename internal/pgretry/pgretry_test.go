package pgretry_test

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/anhnvcoder/short-video-platform/internal/pgretry"
	"github.com/anhnvcoder/short-video-platform/internal/pgretry/pgretrytest"
)

// connectErr returns the error pgconn gives for a connection attempt to addr.
func connectErr(t *testing.T, addr, query string) error {
	t.Helper()
	conn, err := pgconn.Connect(t.Context(), "postgres://svp:pw@"+addr+"/svp_user?sslmode=disable"+query)
	if err == nil {
		_ = conn.Close(context.Background())
		t.Fatalf("connect to %s succeeded, want an error", addr)
	}
	return err
}

func TestRetryable(t *testing.T) {
	tests := []struct {
		name string
		err  func(t *testing.T) error
		want bool
	}{
		{name: "refused", err: func(t *testing.T) error { return connectErr(t, pgretrytest.ClosedPort(t), "") }, want: true},
		{name: "never answers", err: func(t *testing.T) error {
			return connectErr(t, pgretrytest.Blackhole(t), "&connect_timeout=1")
		}, want: true},
		// The proxy of the retry tests must make the first attempt fail with a retryable error.
		{name: "closed before the proxy is ready", err: func(t *testing.T) error {
			return connectErr(t, pgretrytest.DelayedProxy(t, pgretrytest.ClosedPort(t), time.Minute), "")
		}, want: true},
		{name: "not a connection error", err: func(*testing.T) error { return errors.New("boom") }, want: false},
		{name: "context canceled", err: func(*testing.T) error { return context.Canceled }, want: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.err(t)
			if got := pgretry.Retryable(err); got != tt.want {
				t.Errorf("Retryable(%v) = %v, want %v", err, got, tt.want)
			}
		})
	}
}

func TestConnectReturnsOtherErrorsAtOnce(t *testing.T) {
	logs := pgretrytest.CaptureDefaultLog(t)
	boom := errors.New("boom")
	calls := 0
	err := pgretry.Connect(t.Context(), func(context.Context) error { calls++; return boom })
	if !errors.Is(err, boom) || calls != 1 {
		t.Errorf("Connect() = %v after %d calls, want boom after 1", err, calls)
	}
	if strings.Contains(logs.String(), "retrying") {
		t.Errorf("a non-network error was retried:\n%s", logs)
	}
}

// expiringCtx is a context whose deadline passes when the test calls expire, not on a clock: from
// then on Done is closed and Err returns context.DeadlineExceeded, as for a real deadline. The
// test then decides where in Connect the deadline falls, whatever the load of the machine.
type expiringCtx struct {
	context.Context
	done    chan struct{}
	expired atomic.Bool
}

func newExpiringCtx(parent context.Context) *expiringCtx {
	return &expiringCtx{Context: parent, done: make(chan struct{})}
}

func (c *expiringCtx) Done() <-chan struct{} { return c.done }

func (c *expiringCtx) Err() error {
	if c.expired.Load() {
		return context.DeadlineExceeded
	}
	return nil
}

func (c *expiringCtx) expire() {
	if c.expired.CompareAndSwap(false, true) {
		close(c.done)
	}
}

// onWarn is a slog handler that calls f for each WARN record. Connect logs a failed attempt at
// WARN right before it waits for the next one, so f runs at the start of that wait.
type onWarn struct{ f func() }

func (h onWarn) Enabled(context.Context, slog.Level) bool { return true }

func (h onWarn) Handle(_ context.Context, r slog.Record) error {
	if r.Level == slog.LevelWarn {
		h.f()
	}
	return nil
}

func (h onWarn) WithAttrs([]slog.Attr) slog.Handler { return h }

func (h onWarn) WithGroup(string) slog.Handler { return h }

// The caller's deadline wins over the retry window: when it passes during the wait between two
// attempts, Connect returns at once instead of making the next attempt.
func TestConnectStopsWhenDeadlinePassesDuringWait(t *testing.T) {
	refused := connectErr(t, pgretrytest.ClosedPort(t), "")
	ctx := newExpiringCtx(t.Context())
	prev := slog.Default()
	slog.SetDefault(slog.New(onWarn{f: ctx.expire}))
	t.Cleanup(func() { slog.SetDefault(prev) })
	calls := 0
	err := pgretry.Connect(ctx, func(context.Context) error { calls++; return refused })
	if !errors.Is(err, context.DeadlineExceeded) || !errors.Is(err, refused) || calls != 1 {
		t.Errorf("Connect() = %v after %d calls, want context.DeadlineExceeded with the refused attempt after 1",
			err, calls)
	}
}

// A deadline that passed during an attempt stops the retries before any wait.
func TestConnectStopsWhenDeadlinePassedDuringAttempt(t *testing.T) {
	ctx, cancel := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
	defer cancel()
	addr := pgretrytest.ClosedPort(t)
	calls := 0
	err := pgretry.Connect(ctx, func(ctx context.Context) error {
		calls++
		conn, err := pgconn.Connect(ctx, "postgres://svp:pw@"+addr+"/svp_user?sslmode=disable")
		if err == nil {
			_ = conn.Close(context.Background())
		}
		return err
	})
	if !errors.Is(err, context.DeadlineExceeded) || calls != 1 {
		t.Errorf("Connect() = %v after %d calls, want context.DeadlineExceeded after 1", err, calls)
	}
}
