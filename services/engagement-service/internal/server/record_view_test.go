package server

import (
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
)

const testTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

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
	ctx := traceparent.NewContext(t.Context(), testTraceparent)

	before := time.Now()
	if _, err := call(ctx, caller, methodRecordView, &engagementv1.RecordViewRequest{VideoId: videoID}, s.RecordView); err != nil {
		t.Fatal(err)
	}

	r := readTopic(t, brokers, TopicViews, 1)[0]
	if string(r.Key) != videoID {
		t.Errorf("key = %q, want video_id %q", r.Key, videoID)
	}
	if got := headerValue(r, traceparent.MetadataKey); got != testTraceparent {
		t.Errorf("traceparent header = %q, want %q", got, testTraceparent)
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
