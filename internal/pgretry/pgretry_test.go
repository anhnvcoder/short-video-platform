package pgretry_test

import (
	"context"
	"errors"
	"strings"
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

func TestConnectStopsWhenContextEnds(t *testing.T) {
	addr := pgretrytest.ClosedPort(t)
	ctx, cancel := context.WithTimeout(t.Context(), 600*time.Millisecond)
	defer cancel()
	calls := 0
	start := time.Now()
	err := pgretry.Connect(ctx, func(ctx context.Context) error {
		calls++
		conn, err := pgconn.Connect(ctx, "postgres://svp:pw@"+addr+"/svp_user?sslmode=disable")
		if err == nil {
			_ = conn.Close(context.Background())
		}
		return err
	})
	elapsed := time.Since(start)
	// Attempts at 0, 250 ms and 750 ms: the deadline falls during the second wait.
	if !errors.Is(err, context.DeadlineExceeded) || calls != 2 {
		t.Errorf("Connect() = %v after %d calls, want context.DeadlineExceeded after 2", err, calls)
	}
	if elapsed > time.Second {
		t.Errorf("Connect() took %v with a 600ms deadline, want under 1s", elapsed)
	}
}
