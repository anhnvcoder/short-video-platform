package projector

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/event/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
)

// meteredProjector returns a Projector on the test database whose metrics go to a meter provider
// of the test's own, and that provider's reader.
func meteredProjector(t *testing.T) (*Projector, *sdkmetric.ManualReader) {
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
	return newProjector(), reader
}

// freshness returns the single svp.feed.freshness point read from reader, cumulative since the
// projector was made; a zero point when none was recorded.
func freshness(t *testing.T, reader *sdkmetric.ManualReader) metricdata.HistogramDataPoint[float64] {
	t.Helper()
	var data metricdata.ResourceMetrics
	if err := reader.Collect(t.Context(), &data); err != nil {
		t.Fatal(err)
	}
	for _, scope := range data.ScopeMetrics {
		for _, m := range scope.Metrics {
			if m.Name != "svp.feed.freshness" {
				continue
			}
			if m.Unit != "s" {
				t.Errorf("svp.feed.freshness unit = %q, want s", m.Unit)
			}
			points := m.Data.(metricdata.Histogram[float64]).DataPoints
			if len(points) != 1 || points[0].Attributes.Len() != 0 {
				t.Fatalf("svp.feed.freshness points = %+v, want one without attributes", points)
			}
			return points[0]
		}
	}
	return metricdata.HistogramDataPoint[float64]{}
}

// readyRecordWithMeta is readyRecord carrying meta, whose occurred_at the test chooses.
func readyRecordWithMeta(t *testing.T, video, author string, meta *eventv1.EventMeta) *kgo.Record {
	t.Helper()
	return &kgo.Record{Topic: TopicVideoLifecycle, Key: []byte(video), Value: mustMarshal(t, &videov1.VideoEvent{
		Meta:  meta,
		Event: &videov1.VideoEvent_VideoReady{VideoReady: readyEvent(video, author, now())},
	})}
}

// A fan-out records one sample, the time from occurred_at to its commit, in the freshness buckets
// (0.1 s to 60 s, with a bound at 10 s so the p95 freshness target is readable); a redelivery and
// a forged second video.ready of the same video record none.
func TestFreshnessRecordsFirstFanOutOnly(t *testing.T) {
	needDB(t)
	p, reader := meteredProjector(t)
	author, b, video := ids.New(), ids.New(), ids.New()
	handle(t, p, followRecord(t, b, author))

	const age = 2 * time.Second
	before := time.Now()
	r := readyRecordWithMeta(t, video, author, &eventv1.EventMeta{EventId: ids.New(), OccurredAt: timestamppb.New(before.Add(-age))})
	handle(t, p, r)
	took := time.Since(before)
	got := freshness(t, reader)
	if got.Count != 1 {
		t.Fatalf("samples after one fan-out = %d, want 1", got.Count)
	}
	if got.Sum < age.Seconds() || got.Sum > (age+took).Seconds() {
		t.Errorf("freshness = %.3f s, want between %.3f and %.3f", got.Sum, age.Seconds(), (age + took).Seconds())
	}
	if !slices.Equal(got.Bounds, []float64{0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60}) {
		t.Errorf("bucket bounds = %v, want the freshness buckets 0.1 s to 60 s", got.Bounds)
	}

	// The replay of drill-duplicates-feed, then a forged video.ready of the stored video.
	handle(t, p, r, readyRecord(t, video, ids.New(), now()))
	if got := freshness(t, reader); got.Count != 1 {
		t.Errorf("samples after a redelivery and a forged second video.ready = %d, want 1", got.Count)
	}
}

// A video.ready without a valid occurred_at is published without a sample and without an error;
// an author without followers still gets one.
func TestFreshnessWithoutOccurredAtOrFollowers(t *testing.T) {
	needDB(t)
	p, reader := meteredProjector(t)
	author, b := ids.New(), ids.New()
	handle(t, p, followRecord(t, b, author))

	noTime, badTime := ids.New(), ids.New()
	handle(t, p,
		readyRecordWithMeta(t, noTime, author, &eventv1.EventMeta{EventId: ids.New()}),
		readyRecordWithMeta(t, badTime, author, &eventv1.EventMeta{EventId: ids.New(), OccurredAt: &timestamppb.Timestamp{Nanos: -1}}),
	)
	if got := timeline(t, b); len(got) != 2 {
		t.Errorf("timeline = %v, want both videos", got)
	}
	if got := freshness(t, reader); got.Count != 0 {
		t.Errorf("samples without occurred_at = %d, want 0", got.Count)
	}

	handle(t, p, readyRecord(t, ids.New(), ids.New(), now()))
	if got := freshness(t, reader); got.Count != 1 {
		t.Errorf("samples after a video of an author without followers = %d, want 1", got.Count)
	}
}
