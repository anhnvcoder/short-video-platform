package outbox

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

func traceTelemetry(t *testing.T) (*tracetest.SpanRecorder, *sdkmetric.ManualReader) {
	t.Helper()
	previousTrace, previousMeter, previousProp := otel.GetTracerProvider(), otel.GetMeterProvider(), otel.GetTextMapPropagator()
	recorder := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder), sdktrace.WithSampler(sdktrace.AlwaysSample()))
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	otel.SetTracerProvider(tp)
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		otel.SetTracerProvider(previousTrace)
		otel.SetMeterProvider(previousMeter)
		otel.SetTextMapPropagator(previousProp)
		if err := tp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
		if err := mp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	return recorder, reader
}

func loopValues(t *testing.T, reader *sdkmetric.ManualReader) map[string]int64 {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	values := map[string]int64{}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.loop.last_success" {
				continue
			}
			if m.Unit != "s" {
				t.Errorf("loop unit = %q", m.Unit)
			}
			for _, p := range m.Data.(metricdata.Gauge[int64]).DataPoints {
				label, _ := p.Attributes.Value(attribute.Key("loop"))
				if p.Attributes.Len() != 1 {
					t.Errorf("unexpected loop labels: %v", p.Attributes)
				}
				values[label.AsString()] = p.Value
			}
		}
	}
	return values
}

func TestRelayLoopReportsIdleSuccessAndCleanup(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "loop")
	r, _ := newRelay(pool, newClient(t, cluster(t, 1)))
	initial := loopValues(t, reader)
	if len(initial) != 2 || initial["outbox-relay"] != 0 || initial["outbox-cleanup"] != 0 {
		t.Fatalf("initial loop values = %v", initial)
	}
	before := time.Now().Unix()
	stop := start(t, r)
	eventually(t, "successful idle relay and cleanup", func() bool {
		values := loopValues(t, reader)
		return values["outbox-relay"] >= before && values["outbox-cleanup"] >= before
	})
	stop()
	// A failed iteration must not refresh an existing success timestamp.
	previous := loopValues(t, reader)["outbox-relay"]
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	r.Run(ctx)
	if got := loopValues(t, reader)["outbox-relay"]; got != previous {
		t.Errorf("failed loop changed success from %d to %d", previous, got)
	}
}

func TestRelayPostgresStepsHaveBoundedDeadlines(t *testing.T) {
	for _, step := range []string{"read", "mark", "commit"} {
		t.Run(step, func(t *testing.T) {
			_, reader := traceTelemetry(t)
			pool := newDB(t, "timeout_"+step)
			write(t.Context(), t, pool, ids.New())
			holder, err := pool.Begin(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = holder.Rollback(context.Background()) }()
			switch step {
			case "read":
				if _, err := holder.Exec(t.Context(), "LOCK TABLE outbox IN ACCESS EXCLUSIVE MODE"); err != nil {
					t.Fatal(err)
				}
			case "mark":
				if _, err := holder.Exec(t.Context(), "SELECT id FROM outbox FOR UPDATE"); err != nil {
					t.Fatal(err)
				}
			case "commit":
				if err := holder.Rollback(t.Context()); err != nil {
					t.Fatal(err)
				}
				// A deferred trigger runs during COMMIT, after the marking UPDATE has returned.
				if _, err := pool.Exec(t.Context(), `CREATE FUNCTION delay_commit() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN PERFORM pg_sleep(30); RETURN NEW; END $$;
 CREATE CONSTRAINT TRIGGER delay_commit AFTER UPDATE ON outbox DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION delay_commit()`); err != nil {
					t.Fatal(err)
				}
			}
			r, _ := newRelay(pool, newClient(t, cluster(t, 1)))
			r.postgresTimeout = 500 * time.Millisecond
			started := time.Now()
			_, err = r.sendBatch(t.Context())
			elapsed := time.Since(started)
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("sendBatch error = %v", err)
			}
			want := map[string]string{"read": "read outbox", "mark": "mark outbox rows sent", "commit": "commit outbox rows sent"}[step]
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error = %v, want %s", err, want)
			}
			if elapsed < r.postgresTimeout-100*time.Millisecond || elapsed > 2*r.postgresTimeout+time.Second {
				t.Errorf("sendBatch took %v", elapsed)
			}
			if got := loopValues(t, reader)["outbox-relay"]; got != 0 {
				t.Errorf("failed step recorded success: %d", got)
			}
			if err := holder.Rollback(t.Context()); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
				t.Fatal(err)
			}
			if n := countUnsent(t, pool); n != 1 {
				t.Errorf("unsent rows = %d, want 1", n)
			}
			// The same relay can retry once the obstruction is gone, with the default deadline so a
			// loaded test run does not miss it.
			r.postgresTimeout = postgresTimeout
			if step == "commit" {
				if _, err := pool.Exec(t.Context(), "DROP TRIGGER delay_commit ON outbox"); err != nil {
					t.Fatal(err)
				}
			}
			// pgx closes a timed-out connection asynchronously; the old transaction may
			// briefly retain its advisory lock until the server observes that close.
			eventually(t, "retry after the failed transaction releases its lock", func() bool {
				n, err := r.sendBatch(t.Context())
				if err != nil {
					t.Fatalf("retry = %d, %v", n, err)
				}
				return n == 1
			})
		})
	}
}

type stepDeadline struct {
	sql       string
	remaining time.Duration
	err       error
}

type deadlineTracer struct {
	mu            sync.Mutex
	steps         []stepDeadline
	stallRollback bool
}

func (d *deadlineTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	deadline, _ := ctx.Deadline()
	d.mu.Lock()
	d.steps = append(d.steps, stepDeadline{sql: data.SQL, remaining: time.Until(deadline), err: ctx.Err()})
	d.mu.Unlock()
	if data.SQL == "rollback" && d.stallRollback {
		// Simulate an unresponsive rollback while still exercising pgx's transaction lifecycle.
		select {
		case <-ctx.Done():
		case <-time.After(6 * time.Second):
		}
	}
	return ctx
}
func (*deadlineTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func observedPool(t *testing.T, pool *pgxpool.Pool, tracer *deadlineTracer) *pgxpool.Pool {
	t.Helper()
	cfg := pool.Config()
	cfg.ConnConfig.Tracer = tracer
	observed, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(observed.Close)
	return observed
}

func TestRelayRollbackHasIndependentBoundedContext(t *testing.T) {
	pool := newDB(t, "rollback_deadline")
	write(t.Context(), t, pool, ids.New())
	tracer := &deadlineTracer{stallRollback: true}
	observed := observedPool(t, pool, tracer)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	r, _ := newRelay(observed, newClient(t, cluster(t, 1), kgo.WithHooks(cancelOnAck{cancel})))
	r.postgresTimeout = time.Second
	// Cancellation after produce must not cancel the independent rollback budget.
	started := time.Now()
	if n, err := r.sendBatch(ctx); !errors.Is(err, context.Canceled) || n != 0 {
		t.Fatalf("sendBatch = %d, %v", n, err)
	}
	if elapsed := time.Since(started); elapsed < r.postgresTimeout-100*time.Millisecond || elapsed > r.postgresTimeout+time.Second {
		t.Errorf("rollback took %v, want its independent %v budget", elapsed, r.postgresTimeout)
	}
	tracer.mu.Lock()
	defer tracer.mu.Unlock()
	found := false
	for _, step := range tracer.steps {
		if step.sql == "rollback" {
			found = true
			if step.err != nil || step.remaining < r.postgresTimeout*4/5 || step.remaining > r.postgresTimeout {
				t.Errorf("rollback context = %+v", step)
			}
		}
	}
	if !found {
		t.Fatal("rollback was not observed")
	}
}

func TestRelayCleanupUsesOneDeadline(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "cleanup_deadline")
	tracer := &deadlineTracer{}
	observed := observedPool(t, pool, tracer)
	if _, err := pool.Exec(t.Context(), `INSERT INTO outbox (event_id,topic,record_key,payload,published_at)
 SELECT gen_random_uuid(),'t','k','\x00',now()-interval '25 hours' FROM generate_series(1,1001)`); err != nil {
		t.Fatal(err)
	}
	r, _ := newRelay(observed, nil)
	r.cleanupTimeout = 10 * time.Second
	r.cleanup(t.Context())
	tracer.mu.Lock()
	defer tracer.mu.Unlock()
	var first time.Duration
	count := 0
	for _, step := range tracer.steps {
		if strings.HasPrefix(step.sql, "DELETE FROM outbox") {
			count++
			if step.remaining <= 0 || step.remaining > r.cleanupTimeout {
				t.Errorf("cleanup deadline = %v", step.remaining)
			}
			if first == 0 {
				first = step.remaining
			} else if step.remaining >= first {
				t.Error("cleanup renewed its deadline for next batch")
			}
		}
	}
	if count != 2 {
		t.Errorf("cleanup statements = %d, want 2", count)
	}
	if got := loopValues(t, reader)["outbox-cleanup"]; got == 0 {
		t.Error("successful cleanup missing heartbeat")
	}
}

func TestToRecordExtractsWithoutInjectingTraceHeaders(t *testing.T) {
	traceTelemetry(t)
	rec := toRecord(t.Context(), row{topic: topic, headers: map[string]string{"traceparent": validTP, "tracestate": "vendor=value", "custom": "kept"}})
	sc := trace.SpanContextFromContext(rec.Context)
	if !sc.IsRemote() || sc.TraceID().String() != "4bf92f3577b34da6a3ce929d0e0e4736" || sc.TraceState().String() != "vendor=value" {
		t.Errorf("record parent = %v", sc)
	}
	if len(rec.Headers) != 1 || rec.Headers[0].Key != "custom" {
		t.Errorf("relay injected trace headers: %v", rec.Headers)
	}
}

func TestRelayRollbackFailureDoesNotReportSuccess(t *testing.T) {
	_, reader := traceTelemetry(t)
	pool := newDB(t, "rollback_failure")
	observed := observedPool(t, pool, &deadlineTracer{stallRollback: true})
	r, logs := newRelay(observed, nil)
	r.postgresTimeout = time.Second
	r.retryBase, r.retryMax = time.Hour, time.Hour
	stop := start(t, r)
	eventually(t, "rollback failure to enter relay backoff", func() bool {
		return len(logs.records(t, "outbox relay failed, retrying")) == 1
	})
	stop()
	if got := loopValues(t, reader)["outbox-relay"]; got != 0 {
		t.Errorf("rollback failure reported success: %d", got)
	}
}
