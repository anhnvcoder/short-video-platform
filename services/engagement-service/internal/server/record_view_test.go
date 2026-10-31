package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	engagementv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
)

// recordSpans makes the global tracer provider record every span, with W3C TraceContext
// propagation as telemetry.Setup installs it, until the test ends.
func recordSpans(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	previousTP, previousProp := otel.GetTracerProvider(), otel.GetTextMapPropagator()
	recorder := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder), sdktrace.WithSampler(sdktrace.AlwaysSample()))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	t.Cleanup(func() {
		otel.SetTracerProvider(previousTP)
		otel.SetTextMapPropagator(previousProp)
		if err := tp.Shutdown(context.Background()); err != nil {
			t.Error(err)
		}
	})
	return recorder
}

// newCluster starts an in-memory Kafka cluster holding TopicViews with 3 partitions and its
// dead-letter topic with 1, as deploy/redpanda/create-topics.sh creates them, and returns it with
// its broker list.
func newCluster(t *testing.T) (*kfake.Cluster, string) {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(3, TopicViews),
		kfake.SeedTopics(1, TopicViews+kafkax.DLQSuffix))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return c, strings.Join(c.ListenAddrs(), ",")
}

func newProducer(t *testing.T, brokers string) *kgo.Client {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "engagement-service-test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	return cl
}

func TestRecordViewProducesViewRecorded(t *testing.T) {
	_, brokers := newCluster(t)
	// No database: RecordView must not touch it.
	s, _ := newServerWithoutDB(newProducer(t, brokers))
	caller, videoID := ids.New(), ids.New()
	recorder := recordSpans(t)
	// The span the gRPC server instrumentation opens for the call.
	ctx, span := otel.Tracer("test").Start(t.Context(), "svp.engagement.v1.EngagementService/RecordView",
		trace.WithSpanKind(trace.SpanKindServer))

	before := time.Now()
	_, err := call(ctx, caller, methodRecordView, &engagementv1.RecordViewRequest{VideoId: videoID}, s.RecordView)
	span.End()
	if err != nil {
		t.Fatal(err)
	}

	r := readTopic(t, brokers, TopicViews, 1)[0]
	if string(r.Key) != videoID {
		t.Errorf("key = %q, want video_id %q", r.Key, videoID)
	}
	// The header names the producer span, a child of the request's span in the same trace.
	header := headerValue(r, "traceparent")
	parts := strings.Split(header, "-")
	if len(parts) != 4 || parts[1] != span.SpanContext().TraceID().String() {
		t.Errorf("traceparent header = %q, want trace id %s", header, span.SpanContext().TraceID())
	}
	var producer sdktrace.ReadOnlySpan
	for _, sp := range recorder.Ended() {
		if sp.SpanKind() == trace.SpanKindProducer {
			producer = sp
		}
	}
	if producer == nil || producer.Parent().SpanID() != span.SpanContext().SpanID() ||
		len(parts) != 4 || parts[2] != producer.SpanContext().SpanID().String() {
		t.Errorf("traceparent header = %q, want the producer span %v under the request span %s",
			header, producer, span.SpanContext().SpanID())
	}
	var ev engagementv1.ViewEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		t.Fatalf("decode ViewEvent: %v", err)
	}
	if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil {
		t.Errorf("event_id %q is not a canonical UUID", ev.GetMeta().GetEventId())
	}
	if at := ev.GetMeta().GetOccurredAt().AsTime(); at.Before(before.Truncate(time.Second)) || at.After(time.Now()) {
		t.Errorf("occurred_at = %v, want the time of the request", at)
	}
	v := ev.GetViewRecorded()
	if v.GetVideoId() != videoID || v.GetViewerId() != caller {
		t.Errorf("view_recorded = %v, want video_id %s, viewer_id %s (the caller)", v, videoID, caller)
	}
}

// Each call is one view: two calls by the same caller produce two events with distinct ids.
func TestRecordViewIsOneEventPerCall(t *testing.T) {
	_, brokers := newCluster(t)
	s, _ := newServerWithoutDB(newProducer(t, brokers))
	caller, videoID := ids.New(), ids.New()
	for range 2 {
		if _, err := call(t.Context(), caller, methodRecordView, &engagementv1.RecordViewRequest{VideoId: videoID}, s.RecordView); err != nil {
			t.Fatal(err)
		}
	}
	rs := readTopic(t, brokers, TopicViews, 2)
	var first, second engagementv1.ViewEvent
	if err := proto.Unmarshal(rs[0].Value, &first); err != nil {
		t.Fatal(err)
	}
	if err := proto.Unmarshal(rs[1].Value, &second); err != nil {
		t.Fatal(err)
	}
	if first.GetMeta().GetEventId() == second.GetMeta().GetEventId() {
		t.Error("two views share one event_id")
	}
	if rs[0].Partition != rs[1].Partition {
		t.Errorf("views of one video went to partitions %d and %d, want one partition", rs[0].Partition, rs[1].Partition)
	}
}

func TestRecordViewWithoutBrokerIsUnavailable(t *testing.T) {
	c, brokers := newCluster(t)
	c.Close()
	s, logs := newServerWithoutDB(newProducer(t, brokers))
	videoID := ids.New()

	start := time.Now()
	_, err := call(t.Context(), ids.New(), methodRecordView, &engagementv1.RecordViewRequest{VideoId: videoID}, s.RecordView)
	elapsed := time.Since(start)

	if status.Code(err) != codes.Unavailable {
		t.Fatalf("code = %s (err %v), want Unavailable", status.Code(err), err)
	}
	// The reason tells the gateway's breaker the service itself is up.
	if got := grpcerr.Reason(err); got != ReasonDependencyUnavailable {
		t.Errorf("reason = %q, want %q", got, ReasonDependencyUnavailable)
	}
	if elapsed < produceTimeout-100*time.Millisecond || elapsed > produceTimeout+time.Second {
		t.Errorf("RecordView returned after %v, want about %v", elapsed, produceTimeout)
	}
	// The broker's address and error stay in the log, out of the response.
	msg := status.Convert(err).Message()
	if msg != "view could not be recorded, retry later" {
		t.Errorf("message = %q, want the generic one", msg)
	}
	recs := logs.records(t, "produce view.recorded")
	if len(recs) != 1 {
		t.Fatalf("got %d \"produce view.recorded\" log lines, want 1", len(recs))
	}
	if recs[0]["video_id"] != videoID || recs[0]["error"] == "" {
		t.Errorf("log = %v, want video_id %s and the error", recs[0], videoID)
	}
}

func headerValue(r *kgo.Record, key string) string {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}
