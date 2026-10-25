package kafkax

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
	grpccodes "google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

func dlqCount(t *testing.T, reader *sdkmetric.ManualReader, topic, group string) int64 {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.kafka.dlq.records" {
				continue
			}
			for _, p := range m.Data.(metricdata.Sum[int64]).DataPoints {
				tp, _ := p.Attributes.Value(attribute.Key("topic"))
				gp, _ := p.Attributes.Value(attribute.Key("group"))
				if tp.AsString() == topic && gp.AsString() == group {
					if p.Attributes.Len() != 2 {
						t.Errorf("unexpected DLQ labels: %v", p.Attributes)
					}
					return p.Value
				}
			}
		}
	}
	t.Fatalf("missing DLQ series for %s/%s", topic, group)
	return -1
}

func TestProduceConsumeSpanParent(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	brokers := cluster(t, 1, "in")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in"})
	done := make(chan struct{})
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			if !trace.SpanContextFromContext(ctx).IsValid() {
				t.Error("handler has no span")
			}
			close(done)
			return nil
		}})
	waitFor(t, done, "consumer span")
	if err := r.stop(t); err != nil {
		t.Fatal(err)
	}
	spans := recorder.Ended()
	if len(spans) != 2 {
		t.Fatalf("spans = %d, want 2", len(spans))
	}
	send, process := spans[0], spans[1]
	if send.Name() != "send in" || process.Name() != "process in" || process.SpanKind() != trace.SpanKindConsumer ||
		process.Parent().SpanID() != send.SpanContext().SpanID() || process.SpanContext().TraceID() != send.SpanContext().TraceID() {
		t.Fatalf("incorrect producer/consumer relationship: %v / %v", send, process)
	}
	attrs := attribute.NewSet(send.Attributes()...)
	for key, want := range map[string]string{"messaging.system": "kafka", "messaging.destination.name": "in", "messaging.operation.name": "send", "messaging.operation.type": "send"} {
		got, _ := attrs.Value(attribute.Key(key))
		if got.AsString() != want {
			t.Errorf("%s = %v, want %s", key, got, want)
		}
	}
	if len(send.Attributes()) != 4 {
		t.Errorf("unexpected producer attributes: %v", send.Attributes())
	}
}

func TestHandlerTimeoutRetriesAndCountsDLQ(t *testing.T) {
	recorder, reader := traceTelemetry(t)
	brokers := cluster(t, 1, "in", "in.dlq")
	var attempts []context.Context
	r := start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxAttempts: 2, HandlerTimeout: 20 * time.Millisecond,
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			attempts = append(attempts, ctx)
			<-ctx.Done()
			return ctx.Err()
		}})
	if got := dlqCount(t, reader, "in", "g"); got != 0 {
		t.Fatalf("initial DLQ = %d", got)
	}
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in"})
	dlq := readTopic(t, brokers, "in.dlq", 1, 15*time.Second)
	if len(dlq) != 1 {
		t.Fatalf("DLQ records = %d", len(dlq))
	}
	if err := r.stop(t); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 2 || attempts[0] == attempts[1] {
		t.Fatalf("attempts = %v", attempts)
	}
	for _, ctx := range attempts {
		if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
			t.Errorf("attempt error = %v", ctx.Err())
		}
	}
	if got := dlqCount(t, reader, "in", "g"); got != 1 {
		t.Errorf("DLQ = %d, want 1", got)
	}
	if h := headerMap(dlq[0]); h[HeaderDLQReason] != ReasonRetriesExhausted {
		t.Errorf("DLQ headers = %v", h)
	}
	count := 0
	for _, span := range recorder.Ended() {
		if span.SpanKind() == trace.SpanKindConsumer {
			count++
			if span.Status().Code != codes.Error || len(span.Events()) == 0 {
				t.Errorf("timeout span did not record error: %v", span)
			}
		}
	}
	if count != 2 {
		t.Errorf("consumer spans = %d, want 2", count)
	}
}

// A Permanent error returned after the attempt's deadline still sends the record to the
// dead-letter topic at once, with reason permanent: the deadline does not turn it into a
// transient error that is retried.
func TestPermanentAfterDeadlineGoesToDLQAtOnce(t *testing.T) {
	brokers := cluster(t, 1, "in", "in.dlq")
	produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("bad")})
	var calls atomic.Int32
	start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxAttempts: 3, HandlerTimeout: 20 * time.Millisecond,
		Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error {
			calls.Add(1)
			<-ctx.Done()
			return Permanent(errors.New("missing video_id"))
		}})
	dlq := readTopic(t, brokers, "in.dlq", 1, 15*time.Second)
	if len(dlq) != 1 {
		t.Fatalf("dead-letter topic has %d records, want 1", len(dlq))
	}
	if h := headerMap(dlq[0]); h[HeaderDLQReason] != ReasonPermanent {
		t.Errorf("dead-letter headers = %v, want reason %s", h, ReasonPermanent)
	}
	if n := calls.Load(); n != 1 {
		t.Errorf("handler calls = %d, want 1", n)
	}
}

// A handler that finishes its work and returns nil just as the consumer stops gets its record or
// batch committed, as Handler and BatchHandler say: only an error leaves it uncommitted.
func TestNilReturnedAtStopCommits(t *testing.T) {
	for _, batch := range []bool{false, true} {
		t.Run(map[bool]string{false: "record", true: "batch"}[batch], func(t *testing.T) {
			brokers := cluster(t, 1, "in")
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in", Value: []byte("job")})
			started := make(chan struct{})
			handler := func(ctx context.Context) error { close(started); <-ctx.Done(); return nil }
			var r *running
			if batch {
				r = startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					MaxBatchRecords: 1, Handler: func(ctx context.Context, _ *Batch) ([]Rejected, error) { return nil, handler(ctx) }})
			} else {
				r = start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error { return handler(ctx) }})
			}
			waitFor(t, started, "handler")
			if err := r.stop(t); err != nil {
				t.Fatalf("Run() = %v, want nil on stop", err)
			}
			if c := committed(t, brokers, "g"); c[TopicPartition{Topic: "in"}] != 1 {
				t.Errorf("committed offsets = %v, want in/0 at 1", c)
			}
		})
	}
}

// The consumer span of a failed attempt holds the error's type and safe code, never its text,
// which can wrap a Postgres message quoting a parameter.
func TestConsumerSpanOmitsErrorText(t *testing.T) {
	const secret = "alice@example.com"
	tests := []struct {
		name       string
		err        error
		kind, code string
	}{
		{"postgres", fmt.Errorf("insert follow %s: %w", secret, &pgconn.PgError{Code: "23505", Message: "Key (email)=(" + secret + ") exists"}),
			"*pgconn.PgError", "23505"},
		{"grpc", fmt.Errorf("get video: %w", status.Error(grpccodes.Internal, secret)), "*status.Error", "Internal"},
		{"permanent", Permanent(fmt.Errorf("decode %s: %w", secret, errors.New("bad"))), "*errors.errorString", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			recorder, _ := traceTelemetry(t)
			c := &Consumer{cfg: ConsumerConfig{Group: "g", Handler: func(context.Context, *kgo.Record, Attempt) error { return tt.err }}}
			if _, err := c.handle(t.Context(), &kgo.Record{Topic: "in"}, Attempt{Number: 1}); !errors.Is(err, tt.err) {
				t.Fatalf("handle() = %v, want the handler's error", err)
			}
			span := recorder.Ended()[0]
			dump := fmt.Sprintf("%v %v", span.Status(), span.Events())
			if strings.Contains(dump, secret) {
				t.Errorf("consumer span holds the error text: %s", dump)
			}
			if span.Status().Code != codes.Error || span.Status().Description != tt.kind || len(span.Events()) != 1 {
				t.Fatalf("consumer span status %v, events %v; want an error of %s and one exception event", span.Status(), span.Events(), tt.kind)
			}
			attrs := attribute.NewSet(span.Events()[0].Attributes...)
			kind, _ := attrs.Value(semconv.ExceptionTypeKey)
			code, hasCode := attrs.Value(semconv.ExceptionMessageKey)
			if kind.AsString() != tt.kind || code.AsString() != tt.code || hasCode != (tt.code != "") {
				t.Errorf("exception event = %v, want type %s and code %q", span.Events()[0].Attributes, tt.kind, tt.code)
			}
		})
	}
}

func TestStopEndsConsumerSpan(t *testing.T) {
	for _, batch := range []bool{false, true} {
		t.Run(map[bool]string{false: "record", true: "batch"}[batch], func(t *testing.T) {
			recorder, reader := traceTelemetry(t)
			brokers := cluster(t, 1, "in", "in.dlq")
			started := make(chan struct{})
			handler := func(ctx context.Context) error { close(started); <-ctx.Done(); return ctx.Err() }
			var r *running
			if batch {
				r = startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					MaxBatchRecords: 1, Handler: func(ctx context.Context, _ *Batch) ([]Rejected, error) { return nil, handler(ctx) }})
			} else {
				r = start(t, ConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
					Handler: func(ctx context.Context, _ *kgo.Record, _ Attempt) error { return handler(ctx) }})
			}
			produce(t, producer(t, brokers), &kgo.Record{Topic: "in"})
			waitFor(t, started, "handler")
			if err := r.stop(t); err != nil {
				t.Fatal(err)
			}
			if len(recorder.Started()) != len(recorder.Ended()) {
				t.Error("consumer span leaked on shutdown")
			}
			if got := dlqCount(t, reader, "in", "g"); got != 0 {
				t.Errorf("shutdown counted DLQ: %d", got)
			}
			if len(committed(t, brokers, "g")) != 0 {
				t.Error("shutdown committed in-flight record")
			}
		})
	}
}

func TestBatchTimeoutLinksAndDLQ(t *testing.T) {
	recorder, reader := traceTelemetry(t)
	brokers := cluster(t, 1, "in", "in.dlq")
	rs := []*kgo.Record{{Topic: "in"}, {Topic: "in"}}
	produce(t, producer(t, brokers), rs...)
	var attempts []context.Context
	done := make(chan struct{})
	r := startBatch(t, BatchConsumerConfig{Brokers: brokers, Group: "g", Topics: []string{"in"},
		MaxBatchRecords: 2, HandlerTimeout: 20 * time.Millisecond,
		Handler: func(ctx context.Context, b *Batch) ([]Rejected, error) {
			attempts = append(attempts, ctx)
			if len(attempts) < 3 {
				<-ctx.Done()
				return nil, ctx.Err()
			}
			// The handler's result stands even when the 20 ms are up by the time it returns, so
			// this attempt succeeds however late the scheduler runs it.
			close(done)
			return []Rejected{{Record: b.Records[0], Err: errors.New("bad event")}}, nil
		}})
	waitFor(t, done, "batch retry success")
	if got := readTopic(t, brokers, "in.dlq", 1, 15*time.Second); len(got) != 1 {
		t.Fatalf("DLQ records = %d", len(got))
	}
	if err := r.stop(t); err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 3 || attempts[0] == attempts[1] || attempts[1] == attempts[2] {
		t.Fatalf("attempts = %v", attempts)
	}
	if got := dlqCount(t, reader, "in", "g"); got != 1 {
		t.Errorf("DLQ = %d", got)
	}
	count := 0
	for _, span := range recorder.Ended() {
		if span.SpanKind() != trace.SpanKindConsumer {
			continue
		}
		count++
		if span.Parent().IsValid() || len(span.Links()) != 2 {
			t.Fatalf("unexpected batch parent/links: %v", span)
		}
		for i, link := range span.Links() {
			if link.SpanContext.SpanID() != trace.SpanContextFromContext(rs[i].Context).SpanID() {
				t.Errorf("link %d = %v", i, link)
			}
		}
		if (count < 3) != (span.Status().Code == codes.Error) {
			t.Errorf("attempt %d status = %v", count, span.Status())
		}
	}
	if count != 3 {
		t.Errorf("batch spans = %d", count)
	}
}

func TestBatchLinksLimitedTo128ValidContexts(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	batch := &Batch{Records: []*kgo.Record{{Topic: "in", Headers: []kgo.RecordHeader{{Key: "traceparent", Value: []byte("bad")}}}, {Topic: "in"}}}
	for range 130 {
		batch.Records = append(batch.Records, &kgo.Record{Topic: "in", Headers: []kgo.RecordHeader{{Key: "traceparent", Value: []byte(validTP)}}})
	}
	b := &BatchConsumer{cfg: BatchConsumerConfig{Group: "g", Logger: slog.New(slog.DiscardHandler), Handler: func(context.Context, *Batch) ([]Rejected, error) { return nil, nil }}}
	if _, _, err := b.handle(t.Context(), batch); err != nil {
		t.Fatal(err)
	}
	span := recorder.Ended()[0]
	if span.Parent().IsValid() || len(span.Links()) != 128 {
		t.Errorf("unexpected batch links: %v", span)
	}
}

func TestProduceRecordParentKeepsCallDeadline(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	brokers := cluster(t, 1, "out")
	cl := producer(t, brokers)
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	rec := &kgo.Record{Topic: "missing", Context: propagation.TraceContext{}.Extract(context.Background(), propagation.MapCarrier{"traceparent": validTP})}
	started := time.Now()
	if err := Produce(ctx, cl, rec); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("produce error = %v", err)
	}
	if time.Since(started) > time.Second {
		t.Fatal("record parent lost call deadline")
	}
	deadline, ok := rec.Context.Deadline()
	want, _ := ctx.Deadline()
	if !ok || !deadline.Equal(want) {
		t.Errorf("record deadline = %v, want %v", deadline, want)
	}
	span := recorder.Ended()[0]
	if span.Status().Code != codes.Error || span.Parent().TraceID().String() != validTraceID {
		t.Errorf("failed producer = %v", span)
	}
}

func TestProduceCancellationAfterRequestWasSent(t *testing.T) {
	recorder, _ := traceTelemetry(t)
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(1, "out"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	sent := make(chan struct{})
	var once sync.Once
	c.ControlKey(0, func(kmsg.Request) (kmsg.Response, error, bool) {
		c.KeepControl()
		once.Do(func() { close(sent) })
		return nil, nil, true // Accept the request without sending an acknowledgement.
	})
	cl := producer(t, strings.Join(c.ListenAddrs(), ","))
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- Produce(ctx, cl, &kgo.Record{Topic: "out", Context: context.Background()}) }()
	waitFor(t, sent, "produce request to reach broker")
	started := time.Now()
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("produce error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("in-flight idempotent produce ignored cancellation")
	}
	if time.Since(started) > time.Second {
		t.Error("produce did not return promptly")
	}
	spans := recorder.Ended()
	if len(spans) != 1 || spans[0].Status().Code != codes.Error {
		t.Errorf("cancelled producer spans = %v", spans)
	}
}
