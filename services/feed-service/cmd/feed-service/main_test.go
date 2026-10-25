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
	"sync/atomic"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"

	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/sentryx"
	"github.com/anhnvcoder/short-video-platform/internal/telemetry"
)

func TestServeRequiresItsVariables(t *testing.T) {
	for _, tc := range []struct{ databaseURL, brokers, redisURL, want string }{
		{"", "redpanda:9092", "", "DATABASE_URL"},
		{"postgres://unused@127.0.0.1:1/unused", "", "", "KAFKA_BROKERS"},
		// The broker list and the Redis URL are checked before the database is opened, so this
		// URL is never dialled.
		{"postgres://unused@127.0.0.1:1/unused", " , ", "", "KAFKA_BROKERS"},
		{"postgres://unused@127.0.0.1:1/unused", "redpanda:notaport", "", "KAFKA_BROKERS"},
		{"postgres://unused@127.0.0.1:1/unused", "redpanda:9092", "not a url", "REDIS_URL"},
	} {
		t.Setenv("DATABASE_URL", tc.databaseURL)
		t.Setenv("KAFKA_BROKERS", tc.brokers)
		t.Setenv("REDIS_URL", tc.redisURL)
		err := serve(t.Context(), slog.New(slog.DiscardHandler))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("DATABASE_URL=%q KAFKA_BROKERS=%q REDIS_URL=%q: serve() = %v, want an error naming %s",
				tc.databaseURL, tc.brokers, tc.redisURL, err, tc.want)
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
	t.Setenv("REDIS_URL", "")
	// pgpool rejects this URL once the tracker has started. Every later failure, a malformed
	// LISTEN_ADDR included, returns through the same deferred call.
	t.Setenv("DATABASE_URL", "postgres://%zz")
	var logs bytes.Buffer
	logger := slog.New(slog.NewMultiHandler(slog.NewJSONHandler(&logs, nil), &sentryx.Handler{}))

	err := run(t.Context(), logger, []string{"serve"})
	if _, logged := errors.AsType[loggedError](err); !logged || !errors.Is(err, pgpool.ErrInvalidURL) {
		t.Fatalf("run(serve) = %v, want a loggedError wrapping pgpool.ErrInvalidURL", err)
	}
	if n := strings.Count(logs.String(), `"msg":"feed-service failed"`); n != 1 {
		t.Errorf("logged the failure %d times, want 1; log:\n%s", n, logs.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if !slices.ContainsFunc(envelopes, func(e string) bool { return strings.Contains(e, `"message":"feed-service failed"`) }) {
		t.Errorf("tracker received %q, want an event for the failure", envelopes)
	}
}

func TestMigrateRequiresDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "")
	if err := migrate(t.Context()); err == nil || !strings.Contains(err.Error(), "DATABASE_URL") {
		t.Errorf("migrate() = %v, want an error naming DATABASE_URL", err)
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

// Prune runs at start and on every tick; a failed run does not stop the next one, and the loop
// returns once ctx is canceled.
func TestRunPruneRepeatsUntilCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int32
	prune := func(context.Context, func()) (int64, error) {
		switch calls.Add(1) {
		case 1:
			return 0, errors.New("database down")
		case 3:
			cancel()
		}
		return 1, nil
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		runPrune(ctx, slog.New(slog.DiscardHandler), time.Millisecond, time.Minute, telemetry.NewLoop("timeline-prune"), prune)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("runPrune did not return after cancel")
	}
	if n := calls.Load(); n != 3 {
		t.Errorf("prune ran %d times, want 3", n)
	}
}

// The first run happens right away, not after the first interval.
func TestRunPruneRunsAtStart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ran := make(chan struct{}, 1)
	prune := func(context.Context, func()) (int64, error) {
		ran <- struct{}{}
		cancel()
		return 0, nil
	}
	go runPrune(ctx, slog.New(slog.DiscardHandler), time.Hour, time.Minute, telemetry.NewLoop("timeline-prune"), prune)
	select {
	case <-ran:
	case <-time.After(10 * time.Second):
		t.Fatal("prune did not run at start")
	}
}

// pruneLoop returns the timeline-prune loop on a meter provider of the test's own, and a function
// reading the loop's last-success value as the next export would.
func pruneLoop(t *testing.T) (*telemetry.Loop, func() int64) {
	t.Helper()
	previous := otel.GetMeterProvider()
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	otel.SetMeterProvider(mp)
	t.Cleanup(func() {
		otel.SetMeterProvider(previous)
		if err := mp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	loop := telemetry.NewLoop("timeline-prune")
	return loop, func() int64 {
		var data metricdata.ResourceMetrics
		if err := reader.Collect(context.Background(), &data); err != nil {
			t.Fatal(err)
		}
		for _, scope := range data.ScopeMetrics {
			for _, m := range scope.Metrics {
				if m.Name != "svp.loop.last_success" {
					continue
				}
				for _, p := range m.Data.(metricdata.Gauge[int64]).DataPoints {
					if v, _ := p.Attributes.Value(attribute.Key("loop")); v.AsString() == "timeline-prune" {
						return p.Value
					}
				}
			}
		}
		t.Fatal("no svp.loop.last_success point for timeline-prune")
		return 0
	}
}

// A run past its timeout is cut short and logged at WARN, a run that fails otherwise is logged at
// ERROR, and neither is reported as a success; the run after them goes on as usual and is.
func TestRunPruneBoundsEachRun(t *testing.T) {
	loop, lastSuccess := pruneLoop(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	const timeout = 50 * time.Millisecond
	var calls atomic.Int32
	var afterFailures, afterSuccess int64
	prune := func(ctx context.Context, onBatch func()) (int64, error) {
		switch calls.Add(1) {
		case 1:
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > timeout {
				t.Errorf("prune run has deadline %v (set %v), want within %v", deadline, ok, timeout)
			}
			<-ctx.Done() // Postgres holding a lock
			return 3, ctx.Err()
		case 2:
			return 0, errors.New("database down")
		case 3:
			afterFailures = lastSuccess()
			onBatch() // the run's one batch, which found nothing to delete
			return 0, nil
		}
		afterSuccess = lastSuccess()
		cancel()
		return 0, nil
	}
	var logs bytes.Buffer
	done := make(chan struct{})
	start := time.Now()
	go func() {
		defer close(done)
		runPrune(ctx, slog.New(slog.NewJSONHandler(&logs, nil)), time.Millisecond, timeout, loop, prune)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("runPrune did not return")
	}
	if n := calls.Load(); n != 4 {
		t.Fatalf("prune ran %d times, want 4", n)
	}
	if afterFailures != 0 {
		t.Errorf("last success after two failed runs = %d, want 0 (never succeeded)", afterFailures)
	}
	if afterSuccess < start.Unix() {
		t.Errorf("last success after a successful run = %d, want at least %d", afterSuccess, start.Unix())
	}
	out := logs.String()
	for _, want := range []string{`"level":"WARN","msg":"prune timeline timed out"`, `"level":"ERROR","msg":"prune timeline"`} {
		if strings.Count(out, want) != 1 {
			t.Errorf("want one %s; log:\n%s", want, out)
		}
	}
}

// A run that works through a backlog past its timeout is still cut short and logged at WARN, and
// each batch it finished before that refreshes the loop's last success, so the loop does not look
// stalled while it keeps deleting.
func TestRunPruneReportsBatchesOfATimedOutRun(t *testing.T) {
	loop, lastSuccess := pruneLoop(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	start := time.Now()
	var calls atomic.Int32
	prune := func(ctx context.Context, onBatch func()) (int64, error) {
		if calls.Add(1) == 2 {
			cancel()
			return 0, nil
		}
		onBatch()    // a first batch of 5000 rows deleted
		<-ctx.Done() // the second one still running at the deadline
		return 5000, ctx.Err()
	}
	var logs bytes.Buffer
	done := make(chan struct{})
	go func() {
		defer close(done)
		runPrune(ctx, slog.New(slog.NewJSONHandler(&logs, nil)), time.Millisecond, 50*time.Millisecond, loop, prune)
	}()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("runPrune did not return")
	}
	if got := lastSuccess(); got < start.Unix() {
		t.Errorf("last success after a timed-out run with one batch done = %d, want at least %d", got, start.Unix())
	}
	if want := `"level":"WARN","msg":"prune timeline timed out"`; !strings.Contains(logs.String(), want) {
		t.Errorf("want %s; log:\n%s", want, logs.String())
	}
}
