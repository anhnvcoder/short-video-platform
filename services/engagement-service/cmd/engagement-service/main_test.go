package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
)

func TestServeRequiresItsVariables(t *testing.T) {
	for _, tc := range []struct{ databaseURL, brokers, want string }{
		{"", "redpanda:9092", "DATABASE_URL"},
		{"postgres://unused@127.0.0.1:1/unused", "", "KAFKA_BROKERS"},
		// The broker list is checked before the database is opened, so this URL is never dialled.
		{"postgres://unused@127.0.0.1:1/unused", " , ", "KAFKA_BROKERS"},
		{"postgres://unused@127.0.0.1:1/unused", "redpanda:notaport", "KAFKA_BROKERS"},
	} {
		t.Setenv("DATABASE_URL", tc.databaseURL)
		t.Setenv("KAFKA_BROKERS", tc.brokers)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("DATABASE_URL=%q KAFKA_BROKERS=%q: serve() = %v, want an error naming %s",
				tc.databaseURL, tc.brokers, err, tc.want)
		}
	}
}

// A failure after the error tracker has started is logged while the tracker still runs, so that
// it reaches the tracker, and only once: main does not log it again.
func TestServeReportsAFailureBeforeTheErrorTrackerStops(t *testing.T) {
	var mu sync.Mutex
	var envelopes []string
	tracker := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		envelopes = append(envelopes, string(body))
		mu.Unlock()
	}))
	defer tracker.Close()
	t.Setenv("SENTRY_DSN", "http://public@"+tracker.Listener.Addr().String()+"/1")
	t.Setenv("OTEL_SDK_DISABLED", "true")
	t.Setenv("KAFKA_BROKERS", "redpanda:9092")
	// pgpool rejects this URL once the tracker has started. Every later failure, a malformed
	// LISTEN_ADDR included, returns through the same deferred call.
	t.Setenv("DATABASE_URL", "postgres://%zz")
	var logs bytes.Buffer
	logger := slog.New(slog.NewMultiHandler(slog.NewJSONHandler(&logs, nil), &sentryx.Handler{}))

	err := run(t.Context(), logger, []string{"serve"})
	if _, logged := errors.AsType[loggedError](err); !logged || !errors.Is(err, pgpool.ErrInvalidURL) {
		t.Fatalf("run(serve) = %v, want a loggedError wrapping pgpool.ErrInvalidURL", err)
	}
	if n := strings.Count(logs.String(), `"msg":"engagement-service failed"`); n != 1 {
		t.Errorf("logged the failure %d times, want 1; log:\n%s", n, logs.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.ContainsFunc(envelopes, func(e string) bool {
		return strings.Contains(e, `"message":"engagement-service failed"`)
	}) {
		t.Errorf("tracker received %q, want an event for the failure", envelopes)
	}
}

func TestPoolSizes(t *testing.T) {
	for _, tc := range []struct {
		value       string
		read, write int32
		wantErr     bool
	}{
		{value: "", read: 5, write: 5},
		{value: "10", read: 5, write: 5},
		{value: "2", read: 1, write: 1},
		{value: "3", read: 1, write: 2},
		{value: "0", wantErr: true},
		{value: "1", wantErr: true},
		{value: "-4", wantErr: true},
		{value: "ten", wantErr: true},
		{value: "4.5", wantErr: true},
		{value: " 10", wantErr: true},
		{value: "99999999999", wantErr: true},
	} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("DATABASE_MAX_CONNS", tc.value)
			read, write, err := poolSizes()
			if tc.wantErr {
				if err == nil || !strings.Contains(err.Error(), "DATABASE_MAX_CONNS") {
					t.Fatalf("poolSizes() error = %v, want one naming DATABASE_MAX_CONNS", err)
				}
				if len(tc.value) > 1 && strings.Contains(err.Error(), tc.value) {
					t.Errorf("error %q carries the value", err)
				}
				return
			}
			if err != nil || read != tc.read || write != tc.write {
				t.Errorf("poolSizes() = %d, %d, %v; want %d, %d, nil", read, write, err, tc.read, tc.write)
			}
		})
	}
}

// An invalid DATABASE_MAX_CONNS stops serve before anything starts, with an error that names the
// variable and not the database URL.
func TestServeRejectsInvalidMaxConns(t *testing.T) {
	const secret = "s3cret-pw"
	t.Setenv("DATABASE_URL", "postgres://svp:"+secret+"@127.0.0.1:1/svp_engagement")
	t.Setenv("KAFKA_BROKERS", "redpanda:9092")
	t.Setenv("DATABASE_MAX_CONNS", "1")
	err := serve(t.Context(), slog.New(slog.DiscardHandler))
	if err == nil || !strings.Contains(err.Error(), "DATABASE_MAX_CONNS") {
		t.Fatalf("serve() = %v, want an error naming DATABASE_MAX_CONNS", err)
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "127.0.0.1") {
		t.Errorf("error %q leaks the database URL", err)
	}
}

func TestRunRejectsUnknownCommand(t *testing.T) {
	if err := run(t.Context(), slog.New(slog.DiscardHandler), []string{"serv"}); err == nil {
		t.Error("run(serv) = nil, want an error")
	}
}

type fakeConsumer func(ctx context.Context) error

func (f fakeConsumer) Run(ctx context.Context) error { return f(ctx) }

// A consumer that stops on an error is replaced, and the loop ends without error once ctx is
// canceled.
func TestRunConsumerReplacesAFailedConsumer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	made := 0
	newConsumer := func() (runner, error) {
		made++
		if made == 1 {
			return fakeConsumer(func(context.Context) error { return errors.New("commit failed") }), nil
		}
		return fakeConsumer(func(ctx context.Context) error {
			cancel()
			<-ctx.Done()
			return nil
		}), nil
	}
	if err := runConsumer(ctx, slog.New(slog.DiscardHandler), time.Millisecond, newConsumer); err != nil {
		t.Fatalf("runConsumer() = %v, want nil", err)
	}
	if made != 2 {
		t.Errorf("made %d consumers, want 2", made)
	}
}

func TestRunConsumerStopsWhileWaitingToRestart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	made := 0
	newConsumer := func() (runner, error) {
		made++
		return fakeConsumer(func(context.Context) error {
			time.AfterFunc(10*time.Millisecond, cancel)
			return errors.New("commit failed")
		}), nil
	}
	if err := runConsumer(ctx, slog.New(slog.DiscardHandler), time.Hour, newConsumer); err != nil {
		t.Fatalf("runConsumer() = %v, want nil", err)
	}
	if made != 1 {
		t.Errorf("made %d consumers, want 1", made)
	}
}

func TestRunConsumerReturnsCreateError(t *testing.T) {
	want := errors.New("bad config")
	newConsumer := func() (runner, error) { return nil, want }
	err := runConsumer(context.Background(), slog.New(slog.DiscardHandler), time.Millisecond, newConsumer)
	if !errors.Is(err, want) {
		t.Fatalf("runConsumer() = %v, want %v", err, want)
	}
}
