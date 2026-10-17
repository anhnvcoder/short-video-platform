package outbox

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kmsg"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

// The broker takes the produce request of a batch from three traces and holds its ack past the
// relay's produce deadline (docs/adr/0011-observability-stage3.md, section 11): the batch fails,
// the transaction rolls back and frees the relay lock at once, no row is marked sent, and every
// producer span ends with the error in its row's trace. Once the broker answers, the late ack
// included, the relay sends the rows again under the same event IDs; the broker may then hold a
// copy of each from the late write, which consumers absorb.
func TestRelayBrokerHoldingAckReleasesLockAndLeavesRowsUnsent(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	pool := newDB(t, "held_ack")
	var want []string
	traces := map[trace.TraceID]bool{}
	for range 3 {
		ctx, span := otel.Tracer("test").Start(t.Context(), "request")
		want = append(want, write(ctx, t, pool, ids.New()))
		traces[span.SpanContext().TraceID()] = true
		span.End()
	}

	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, topic))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	brokers := strings.Join(c.ListenAddrs(), ",")
	received, release := make(chan struct{}), make(chan struct{})
	var receivedOnce, releaseOnce sync.Once
	c.ControlKey(int16(kmsg.Produce), func(kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		receivedOnce.Do(func() { close(received) })
		c.SleepControl(func() { <-release })
		return nil, nil, false // then handled as usual: written and acknowledged
	})
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })

	r, _ := newRelay(pool, newClient(t, brokers))
	r.produceTimeout = time.Second
	recorder.Reset()
	type result struct {
		n   int
		err error
	}
	done := make(chan result, 1)
	started := time.Now()
	go func() {
		n, err := r.sendBatch(t.Context())
		done <- result{n, err}
	}()
	var n int
	select {
	case res := <-done:
		n, err = res.n, res.err
	case <-time.After(10 * time.Second):
		t.Fatal("sendBatch did not return at its produce deadline while the broker held the ack")
	}
	elapsed := time.Since(started)
	if n != 0 || !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "send outbox rows") {
		t.Fatalf("sendBatch() = %d, %v; want 0 and the produce deadline", n, err)
	}
	select {
	case <-received:
	default:
		t.Fatal("the produce request never reached the broker")
	}
	if limit := r.produceTimeout + 2*time.Second; elapsed > limit {
		t.Errorf("sendBatch() took %v, want at most %v", elapsed, limit)
	}
	if got := countUnsent(t, pool); got != 3 {
		t.Errorf("%d rows unsent after the failed batch, want 3", got)
	}
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	var locked bool
	if err := tx.QueryRow(t.Context(), "SELECT pg_try_advisory_xact_lock($1)", lockID).Scan(&locked); err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback(t.Context())
	if !locked {
		t.Error("the relay lock is still held after the failed batch")
	}
	spans := recorder.Ended()
	if len(spans) != 3 {
		t.Fatalf("%d producer spans ended, want 3", len(spans))
	}
	for _, s := range spans {
		if s.Status().Code != codes.Error || !traces[s.SpanContext().TraceID()] {
			t.Errorf("producer span %s in trace %s, status %v; want an error in a row's trace", s.Name(), s.SpanContext().TraceID(), s.Status())
		}
		delete(traces, s.SpanContext().TraceID())
	}

	releaseOnce.Do(func() { close(release) })
	eventually(t, "the rows to be sent once the broker answers", func() bool {
		n, err := r.sendBatch(t.Context())
		return err == nil && n == 3
	})
	if got := countUnsent(t, pool); got != 0 {
		t.Errorf("%d rows unsent after the retry, want 0", got)
	}
	got := eventIDs(t, consume(t, brokers, 3, 300*time.Millisecond))
	for _, id := range want {
		if !slices.Contains(got, id) {
			t.Errorf("event %s missing from %v", id, got)
		}
	}
	for _, id := range got {
		if !slices.Contains(want, id) {
			t.Errorf("unexpected event %s, want only %v", id, want)
		}
	}
}
