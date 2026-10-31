package server

import (
	"context"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"uuid"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/outbox"
	"github.com/anhnvcoder/svp-backend/services/video-service/internal/store"
)

const testDurationMs = 83_250

// newVideo inserts a video in status and returns its id; a READY video gets its media fields.
func newVideo(t *testing.T, status string) string {
	t.Helper()
	id := ids.New()
	published := time.Date(2026, 10, 1, 8, 30, 0, 0, time.UTC)
	insertVideo(t, id, ids.New(), status, status == "READY", published, time.Now())
	return id
}

func loadVideo(t *testing.T, id string) store.Video {
	t.Helper()
	v, err := store.New(testPool).GetVideo(t.Context(), uuid.MustParse(id))
	if err != nil {
		t.Fatalf("read video %s: %v", id, err)
	}
	return v
}

// The keys media-worker publishes: the master at the root of a version, the thumbnail in the
// directory of the try that created it.
const (
	testVersion = "0190a6e4-7b2c-7d3e-9f40-0000000000a1"
	testAttempt = "0190a6e4-7b2c-7d3e-9f40-0000000000b2"
)

func playlistKeyOf(id string) string { return "media/" + id + "/" + testVersion + "/master.m3u8" }

func thumbnailKeyOf(id string) string {
	return "media/" + id + "/" + testVersion + "/" + testAttempt + "/thumbnail.jpg"
}

func completedEvent(id string) *mediav1.TranscodeEvent {
	return &mediav1.TranscodeEvent{
		Meta: outbox.NewMeta(),
		Event: &mediav1.TranscodeEvent_TranscodeCompleted{TranscodeCompleted: &mediav1.TranscodeCompleted{
			VideoId:      id,
			PlaylistKey:  playlistKeyOf(id),
			ThumbnailKey: thumbnailKeyOf(id),
			Duration:     durationpb.New(testDurationMs * time.Millisecond),
			Renditions:   []*mediav1.Rendition{{Name: "360p", Width: 640, Height: 360, BitrateBps: 800_000}},
		}},
	}
}

func failedEvent(id string) *mediav1.TranscodeEvent {
	return &mediav1.TranscodeEvent{
		Meta: outbox.NewMeta(),
		Event: &mediav1.TranscodeEvent_TranscodeFailed{TranscodeFailed: &mediav1.TranscodeFailed{
			VideoId: id,
			Reason:  mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT,
			Detail:  "moov atom not found",
		}},
	}
}

// completedWith returns transcode.completed for id after change.
func completedWith(id string, change func(*mediav1.TranscodeCompleted)) *mediav1.TranscodeEvent {
	ev := completedEvent(id)
	change(ev.GetTranscodeCompleted())
	return ev
}

func transcodeRecord(key string, ev *mediav1.TranscodeEvent) *kgo.Record {
	value, err := proto.Marshal(ev)
	if err != nil {
		panic(err)
	}
	return &kgo.Record{Topic: TopicMediaTranscodes, Key: []byte(key), Value: value}
}

func handleTranscode(ctx context.Context, s *Server, r *kgo.Record) error {
	return s.HandleTranscode(ctx, r, kafkax.Attempt{Number: 1})
}

// wantVideoReady fails unless payload is a video.ready event matching the stored video v.
func wantVideoReady(t *testing.T, payload []byte, v store.Video) {
	t.Helper()
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(payload, &ev); err != nil {
		t.Fatalf("payload is not a VideoEvent: %v", err)
	}
	if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil || ev.GetMeta().GetOccurredAt() == nil {
		t.Errorf("event meta = %v, want an event_id and occurred_at", ev.GetMeta())
	}
	id := v.ID.String()
	want := &videov1.VideoReady{
		VideoId:      id,
		AuthorId:     v.AuthorID.String(),
		Title:        v.Title,
		Duration:     durationpb.New(testDurationMs * time.Millisecond),
		PlaylistKey:  playlistKeyOf(id),
		ThumbnailKey: thumbnailKeyOf(id),
		PublishedAt:  timestamppb.New(*v.PublishedAt),
	}
	if !proto.Equal(ev.GetVideoReady(), want) {
		t.Errorf("video_ready = %v, want %v", ev.GetVideoReady(), want)
	}
}

// wantDeletes fails unless the storage deleted exactly want, in order.
func wantDeletes(t *testing.T, storage *fakeStorage, want ...string) {
	t.Helper()
	if got := storage.deletes(); !slices.Equal(got, want) {
		t.Errorf("deletes = %q, want %q", got, want)
	}
}

func filesOf(id string) []string {
	return []string{"uploads/" + id, "media/" + id + "/"}
}

func TestTranscodeCompletedMarksReadyAndEmitsVideoReady(t *testing.T) {
	needDB(t)
	testTelemetry(t)
	s, storage, logs := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	// As kafkax leaves the context of a record: its consumer span.
	ctx, span := otel.Tracer("test").Start(t.Context(), "process "+TopicMediaTranscodes)
	defer span.End()

	before := time.Now()
	if err := handleTranscode(ctx, s, transcodeRecord(id, completedEvent(id))); err != nil {
		t.Fatal(err)
	}
	v := loadVideo(t, id)
	if v.Status != "READY" || v.DurationMs == nil || *v.DurationMs != testDurationMs ||
		v.PlaylistKey == nil || *v.PlaylistKey != playlistKeyOf(id) ||
		v.ThumbnailKey == nil || *v.ThumbnailKey != thumbnailKeyOf(id) {
		t.Errorf("stored video = %+v, want READY with the event's duration and keys", v)
	}
	if v.PublishedAt == nil || v.PublishedAt.Before(before.Add(-time.Second)) {
		t.Errorf("published_at = %v, want about now", v.PublishedAt)
	}
	rows := outboxRows(t, id)
	if len(rows) != 1 {
		t.Fatalf("got %d outbox rows, want 1", len(rows))
	}
	if rows[0].topic != TopicVideoLifecycle {
		t.Errorf("topic = %q, want %s", rows[0].topic, TopicVideoLifecycle)
	}
	if want := traceparentOf(span); len(rows[0].headers) != 1 || rows[0].headers["traceparent"] != want {
		t.Errorf("headers = %v, want the consumer span's traceparent %s", rows[0].headers, want)
	}
	wantVideoReady(t, rows[0].payload, v)
	wantDeletes(t, storage)
	if n := len(logs.records(t, "video ready")); n != 1 {
		t.Errorf("got %d \"video ready\" log lines, want 1", n)
	}
}

// A redelivery (same event_id) and a second completion (new event_id) move nothing: still one
// video.ready, and the publication time stays.
func TestTranscodeCompletedTwiceEmitsOnce(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	r := transcodeRecord(id, completedEvent(id))
	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	first := loadVideo(t, id)

	for _, again := range []*kgo.Record{r, transcodeRecord(id, completedEvent(id))} {
		if err := handleTranscode(t.Context(), s, again); err != nil {
			t.Fatal(err)
		}
	}
	v := loadVideo(t, id)
	if v.Status != "READY" || !v.PublishedAt.Equal(*first.PublishedAt) {
		t.Errorf("video = %s published %v, want READY published %v", v.Status, v.PublishedAt, first.PublishedAt)
	}
	if rows := outboxRows(t, id); len(rows) != 1 {
		t.Errorf("got %d outbox rows, want 1", len(rows))
	}
	wantDeletes(t, storage)
}

func TestTranscodeFailedMarksFailedAndDeletesFiles(t *testing.T) {
	needDB(t)
	s, storage, logs := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	r := transcodeRecord(id, failedEvent(id))

	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage, filesOf(id)...)
	recs := logs.records(t, "video failed")
	if len(recs) != 1 || recs[0]["reason"] != "TRANSCODE_FAILURE_REASON_INVALID_INPUT" ||
		recs[0]["detail"] != "moov atom not found" || recs[0]["video_id"] != id {
		t.Errorf("\"video failed\" log lines = %v, want one with reason, detail and video_id", recs)
	}

	// Redelivered: still FAILED, and the files are deleted again.
	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage, append(filesOf(id), filesOf(id)...)...)
}

// media-worker may write media/<id>/ again after the video failed (a retried job finishing
// late): the completion deletes those files and publishes nothing.
func TestTranscodeCompletedAfterFailedDeletesFilesAgain(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "FAILED")

	if err := handleTranscode(t.Context(), s, transcodeRecord(id, completedEvent(id))); err != nil {
		t.Fatal(err)
	}
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage, filesOf(id)...)
}

func TestTranscodeFailedAfterReadyIsIgnored(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "READY")
	before := loadVideo(t, id)

	if err := handleTranscode(t.Context(), s, transcodeRecord(id, failedEvent(id))); err != nil {
		t.Fatal(err)
	}
	wantUnchanged(t, id, "READY")
	if after := loadVideo(t, id); !after.PublishedAt.Equal(*before.PublishedAt) || *after.PlaylistKey != *before.PlaylistKey {
		t.Errorf("video = %+v, want its media fields unchanged", after)
	}
	wantDeletes(t, storage)
}

// A newer media-worker may send an event type this service does not know: skip it, since adding
// a oneof branch is a compatible change within v1.
func TestTranscodeUnknownEventIsSkipped(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	// An unknown oneof field: number 15 as a length-delimited field, which TranscodeEvent lacks.
	value, err := proto.Marshal(&mediav1.TranscodeEvent{Meta: outbox.NewMeta()})
	if err != nil {
		t.Fatal(err)
	}
	value = append(value, 15<<3|2, 2, 'h', 'i')

	if err := handleTranscode(t.Context(), s, &kgo.Record{Key: []byte(id), Value: value}); err != nil {
		t.Fatalf("HandleTranscode = %v, want nil", err)
	}
	wantUnchanged(t, id, "PROCESSING")
	wantDeletes(t, storage)
}

// transcodeCluster starts an in-memory Kafka with the service's topics, media.transcodes.v1
// having partitions partitions, and returns its broker list.
func transcodeCluster(t *testing.T, partitions int32) string {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(partitions, TopicMediaTranscodes),
		kfake.SeedTopics(1, TopicMediaTranscodes+kafkax.DLQSuffix), kfake.SeedTopics(3, TopicVideoLifecycle))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return strings.Join(c.ListenAddrs(), ",")
}

// handled records what the handler returned for each record key.
type handled struct {
	mu    sync.Mutex
	byKey map[string][]error
}

func (h *handled) add(key string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.byKey == nil {
		h.byKey = map[string][]error{}
	}
	h.byKey[key] = append(h.byKey[key], err)
}

func (h *handled) results(key string) []error {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.byKey[key])
}

// done reports whether the handler has returned nil for key.
func (h *handled) done(key string) bool {
	errs := h.results(key)
	return len(errs) > 0 && errs[len(errs)-1] == nil
}

// startTranscodeConsumer runs the service's transcode consumer with the given backoff, recording
// every handler result in h. stop cancels it and waits; it also runs when the test ends.
func startTranscodeConsumer(t *testing.T, s *Server, brokers string, backoff time.Duration, h *handled) (stop func()) {
	t.Helper()
	cfg := s.TranscodeConsumerConfig(brokers)
	cfg.BackoffBase, cfg.BackoffMax = backoff, backoff
	cfg.Handler = func(ctx context.Context, r *kgo.Record, a kafkax.Attempt) error {
		err := s.HandleTranscode(ctx, r, a)
		h.add(string(r.Key), err)
		return err
	}
	c, err := kafkax.NewConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	var once sync.Once
	stop = func() {
		once.Do(func() {
			cancel()
			select {
			case err := <-done:
				if err != nil {
					t.Errorf("consumer: %v", err)
				}
			case <-time.After(30 * time.Second):
				t.Error("consumer did not stop")
			}
		})
	}
	t.Cleanup(stop)
	return stop
}

func produce(t *testing.T, brokers string, rs ...*kgo.Record) {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "video-service-test-producer")
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	if err := kafkax.Produce(t.Context(), cl, rs...); err != nil {
		t.Fatal(err)
	}
}

// readTopic reads topic from the start until n records keyed key (any key when key is "") have
// come, and returns them.
func readTopic(t *testing.T, brokers, topic, key string, n int) []*kgo.Record {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "video-service-test-reader",
		kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(out) < n && ctx.Err() == nil {
		cl.PollFetches(ctx).EachRecord(func(r *kgo.Record) {
			if key == "" || string(r.Key) == key {
				out = append(out, r)
			}
		})
	}
	if len(out) < n {
		t.Fatalf("got %d records on %s, want %d", len(out), topic, n)
	}
	return out
}

func headerValue(r *kgo.Record, key string) string {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

// Every malformed, forged or out-of-order event goes to the dead-letter topic at once and
// changes nothing (IN-5, FF-6); an unknown event type is skipped and committed.
func TestTranscodeInvalidEventsGoToDeadLetter(t *testing.T) {
	needDB(t)
	brokers := transcodeCluster(t, 1)
	s, storage, _ := newServerWithStorage()

	cases := []struct {
		name string
		// status is the status of the video the event names; "" means no video.
		status string
		record func(id string) *kgo.Record
	}{
		{"undecodable value", "PROCESSING", func(id string) *kgo.Record {
			return &kgo.Record{Key: []byte(id), Value: []byte{0xff}}
		}},
		{"no meta", "PROCESSING", func(id string) *kgo.Record {
			ev := completedEvent(id)
			ev.Meta = nil
			return transcodeRecord(id, ev)
		}},
		{"video_id not canonical", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(strings.ToUpper(id), completedEvent(strings.ToUpper(id)))
		}},
		{"record key differs from video_id", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(ids.New(), failedEvent(id))
		}},
		{"video does not exist", "", func(id string) *kgo.Record {
			return transcodeRecord(id, completedEvent(id))
		}},
		{"failed for an UPLOADING video", "UPLOADING", func(id string) *kgo.Record {
			return transcodeRecord(id, failedEvent(id))
		}},
		{"completed for an UPLOADING video", "UPLOADING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedEvent(id))
		}},
		{"playlist of another video", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = "media/" + ids.New() + "/master.m3u8"
			}))
		}},
		{"playlist climbing out with ..", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = "media/" + id + "/../x"
			}))
		}},
		{"playlist climbing out with %2e%2e", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = "media/" + id + "/%2e%2e/" + ids.New() + "/master.m3u8"
			}))
		}},
		{"playlist climbing out with backslashes", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = "media/" + id + `/..\` + ids.New() + `\master.m3u8`
			}))
		}},
		{"thumbnail climbing to the uploads bucket with %2e%2e", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.ThumbnailKey = "media/" + id + "/%2e%2e/%2e%2e/%2e%2e/uploads/" + ids.New()
			}))
		}},
		{"playlist is the prefix itself", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.PlaylistKey = "media/" + id + "/"
			}))
		}},
		{"thumbnail in the uploads bucket", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.ThumbnailKey = "uploads/" + id
			}))
		}},
		{"zero duration", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.Duration = durationpb.New(0)
			}))
		}},
		{"no duration", "PROCESSING", func(id string) *kgo.Record {
			return transcodeRecord(id, completedWith(id, func(c *mediav1.TranscodeCompleted) {
				c.Duration = nil
			}))
		}},
	}
	h := &handled{}
	startTranscodeConsumer(t, s, brokers, time.Millisecond, h)

	videoIDs := make([]string, len(cases))
	var rs []*kgo.Record
	for i, c := range cases {
		videoIDs[i] = ids.New()
		if c.status != "" {
			videoIDs[i] = newVideo(t, c.status)
		}
		r := c.record(videoIDs[i])
		r.Topic = TopicMediaTranscodes
		r.Headers = []kgo.RecordHeader{{Key: "test-case", Value: []byte(c.name)}}
		rs = append(rs, r)
	}
	// One partition: once the last record is handled, every earlier one is settled.
	unknown := ids.New()
	rs = append(rs, &kgo.Record{Topic: TopicMediaTranscodes, Key: []byte(unknown), Value: mustMarshal(t, &mediav1.TranscodeEvent{Meta: outbox.NewMeta()})})
	last := newVideo(t, "PROCESSING")
	rs = append(rs, transcodeRecord(last, failedEvent(last)))
	produce(t, brokers, rs...)
	eventually(t, "the last record to be handled", func() bool { return h.done(last) })

	if !h.done(unknown) {
		t.Errorf("unknown event type: handler returned %v, want nil", h.results(unknown))
	}
	dead := readTopic(t, brokers, TopicMediaTranscodes+kafkax.DLQSuffix, "", len(cases))
	byCase := map[string]*kgo.Record{}
	for _, r := range dead {
		byCase[headerValue(r, "test-case")] = r
	}
	for i, c := range cases {
		r, ok := byCase[c.name]
		switch {
		case !ok:
			t.Errorf("%s: not in the dead-letter topic", c.name)
		case headerValue(r, kafkax.HeaderDLQReason) != kafkax.ReasonPermanent:
			t.Errorf("%s: dlq-reason = %q (error %q), want permanent", c.name,
				headerValue(r, kafkax.HeaderDLQReason), headerValue(r, kafkax.HeaderDLQError))
		}
		if c.status != "" {
			wantUnchanged(t, videoIDs[i], c.status)
		}
		for _, d := range storage.deletes() {
			if strings.Contains(d, videoIDs[i]) {
				t.Errorf("%s: deleted %s", c.name, d)
			}
		}
	}
	if len(dead) != len(cases) {
		t.Errorf("got %d dead letters, want %d", len(dead), len(cases))
	}
}

func mustMarshal(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Deleting fails twice: kafkax retries the record, the third try deletes everything, and only
// then is the offset committed, so a new member of the group does not see the record again.
func TestTranscodeFailedRetriesDeletesUntilDone(t *testing.T) {
	needDB(t)
	brokers := transcodeCluster(t, 1)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	storage.setFailDeletes(2)

	h := &handled{}
	stop := startTranscodeConsumer(t, s, brokers, time.Millisecond, h)
	produce(t, brokers, transcodeRecord(id, failedEvent(id)))
	eventually(t, "the record to be handled", func() bool { return h.done(id) })
	stop()
	if errs := h.results(id); len(errs) != 3 || errs[0] == nil || errs[1] == nil {
		t.Errorf("handler results = %v, want two errors then nil", errs)
	}
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage, filesOf(id)...)

	h2 := &handled{}
	startTranscodeConsumer(t, s, brokers, time.Millisecond, h2)
	next := newVideo(t, "PROCESSING")
	produce(t, brokers, transcodeRecord(next, failedEvent(next)))
	eventually(t, "the next record to be handled", func() bool { return h2.done(next) })
	if errs := h2.results(id); len(errs) != 0 {
		t.Errorf("committed record handled again: %v", errs)
	}
}

// The consumer stops while deleting keeps failing: the record stays uncommitted, and the next
// member of the group handles it again and deletes the files of the already FAILED video.
func TestTranscodeFailedUncommittedUntilDeleted(t *testing.T) {
	needDB(t)
	brokers := transcodeCluster(t, 1)
	s, storage, _ := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	storage.setFailDeletes(1000)

	h := &handled{}
	stop := startTranscodeConsumer(t, s, brokers, time.Hour, h)
	produce(t, brokers, transcodeRecord(id, failedEvent(id)))
	eventually(t, "a first failed try", func() bool { return len(h.results(id)) == 1 })
	stop()
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage)

	storage.setFailDeletes(0)
	h2 := &handled{}
	startTranscodeConsumer(t, s, brokers, time.Millisecond, h2)
	eventually(t, "the record to be handled again", func() bool { return h2.done(id) })
	wantUnchanged(t, id, "FAILED")
	wantDeletes(t, storage, filesOf(id)...)
}

// The whole saga in-process: CompleteUpload, the relay publishes video.uploaded, the test plays
// media-worker and answers transcode.completed, the consumer marks the video READY and the relay
// publishes video.ready, all in the request's trace.
func TestUploadToReadyThroughKafka(t *testing.T) {
	needDB(t)
	testTelemetry(t)
	brokers := transcodeCluster(t, 3)
	s, storage, logs := newServerWithStorage()

	relayClient, err := kafkax.NewClient(brokers, "video-service-test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(relayClient.Close)
	relayCtx, stopRelay := context.WithCancel(context.Background())
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		outbox.NewRelay(testPool, relayClient, slog.New(slog.NewJSONHandler(logs, nil))).Run(relayCtx)
	}()
	t.Cleanup(func() {
		stopRelay()
		<-relayDone
	})
	startTranscodeConsumer(t, s, brokers, time.Millisecond, &handled{})

	author := ids.New()
	id := uploaded(t, s, storage, author)
	ctx, span := otel.Tracer("test").Start(t.Context(), "CompleteUpload")
	_, err = completeUpload(ctx, t, s, author, id)
	span.End()
	if err != nil {
		t.Fatal(err)
	}
	traceID := span.SpanContext().TraceID()

	uploadedRec := readTopic(t, brokers, TopicVideoLifecycle, id, 1)[0]
	wantVideoUploaded(t, uploadedRec.Value, id, author)
	// Like media-worker, answer in the trace of the record being handled.
	r := transcodeRecord(id, completedEvent(id))
	r.Context = otel.GetTextMapPropagator().Extract(t.Context(),
		propagation.MapCarrier{"traceparent": headerValue(uploadedRec, "traceparent")})
	produce(t, brokers, r)

	recs := readTopic(t, brokers, TopicVideoLifecycle, id, 2)
	v := loadVideo(t, id)
	if v.Status != "READY" {
		t.Fatalf("status = %s, want READY", v.Status)
	}
	wantVideoReady(t, recs[1].Value, v)
	if got := traceIDOf(t, headerValue(recs[1], "traceparent")); got != traceID {
		t.Errorf("video.ready is in trace %s, want the request's trace %s", got, traceID)
	}
	resp, err := getVideo(t, s, ids.New(), id)
	if err != nil || resp.GetVideo().GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY {
		t.Errorf("GetVideo by another user = %v, %v; want the READY video", resp, err)
	}
}

// completedUpload creates a video through InitUpload and CompleteUpload, so it is PROCESSING
// with processing_at set, and returns its id.
func completedUpload(t *testing.T, s *Server, storage *fakeStorage) string {
	t.Helper()
	author := ids.New()
	id := uploaded(t, s, storage, author)
	if _, err := completeUpload(t.Context(), t, s, author, id); err != nil {
		t.Fatal(err)
	}
	return id
}

// transcode.completed records one svp.video.ready.duration sample, outcome ready, of about the
// time since CompleteUpload; a redelivery records nothing more.
func TestReadyDurationFromCompleteUploadToReady(t *testing.T) {
	needDB(t)
	_, reader := testTelemetry(t)
	s, storage, _ := newServerWithStorage()
	start := time.Now()
	id := completedUpload(t, s, storage)
	const wait = 300 * time.Millisecond
	time.Sleep(wait)

	r := transcodeRecord(id, completedEvent(id))
	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start).Seconds()
	points := readySamples(t, reader)
	ready, ok := points["ready"]
	if !ok || len(points) != 1 || ready.Count != 1 {
		t.Fatalf("samples = %v, want one with outcome ready", points)
	}
	// Postgres and the test share this machine's clock.
	if ready.Sum < wait.Seconds() || ready.Sum > elapsed {
		t.Errorf("sample = %.3fs, want between %.3fs and %.3fs", ready.Sum, wait.Seconds(), elapsed)
	}
	// The sample is read from Postgres's clock alone: it ends after the moving transaction
	// committed, so no earlier than published_at, its now(), and no later than a clock read after
	// the handler returned.
	after := postgresNow(t)
	v := loadVideo(t, id)
	if low, high := v.PublishedAt.Sub(*v.ProcessingAt).Seconds(), after.Sub(*v.ProcessingAt).Seconds(); ready.Sum < low || ready.Sum > high {
		t.Errorf("sample = %.6fs, want between published_at - processing_at = %.6fs and %.6fs on Postgres's clock", ready.Sum, low, high)
	}
	if want := readyBuckets; !slices.Equal(ready.Bounds, want) {
		t.Errorf("bounds = %v, want %v", ready.Bounds, want)
	}

	for _, again := range []*kgo.Record{r, transcodeRecord(id, completedEvent(id))} {
		if err := handleTranscode(t.Context(), s, again); err != nil {
			t.Fatal(err)
		}
	}
	if got := readySamples(t, reader)["ready"].Count; got != 1 {
		t.Errorf("after redeliveries: %d samples, want 1", got)
	}
}

// The sample ends when the video is READY for everyone, after the commit: a transcode.completed
// whose UPDATE waits for a lock on the row counts the wait, which the transaction's now() in
// published_at leaves out.
func TestReadyDurationIncludesLockWait(t *testing.T) {
	needDB(t)
	_, reader := testTelemetry(t)
	s, storage, _ := newServerWithStorage()
	id := completedUpload(t, s, storage)

	lock, err := testPool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lock.Rollback(context.Background()) }()
	var lockPID int
	if err := lock.QueryRow(t.Context(), "SELECT pg_backend_pid()").Scan(&lockPID); err != nil {
		t.Fatal(err)
	}
	if _, err := lock.Exec(t.Context(), "SELECT 1 FROM videos WHERE id = $1 FOR UPDATE", id); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- handleTranscode(t.Context(), s, transcodeRecord(id, completedEvent(id))) }()
	waitBlockedBy(t, lockPID)
	const hold = 300 * time.Millisecond
	time.Sleep(hold)
	if err := lock.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	after := postgresNow(t)

	points := readySamples(t, reader)
	ready, ok := points["ready"]
	if !ok || len(points) != 1 || ready.Count != 1 {
		t.Fatalf("samples = %v, want one with outcome ready", points)
	}
	v := loadVideo(t, id)
	if v.Status != "READY" {
		t.Fatalf("status = %s, want READY", v.Status)
	}
	// The transaction began, at published_at, before its UPDATE blocked, and the lock was held
	// for hold after that: the sample must cover both.
	txStart := v.PublishedAt.Sub(*v.ProcessingAt).Seconds()
	if low, high := txStart+hold.Seconds(), after.Sub(*v.ProcessingAt).Seconds(); ready.Sum < low || ready.Sum > high {
		t.Errorf("sample = %.3fs, want between %.3fs (published_at - processing_at = %.3fs, plus the %s lock wait) and %.3fs",
			ready.Sum, low, txStart, hold, high)
	}
}

// waitBlockedBy returns once some backend waits for a lock held by the backend pid, or fails
// after a while.
func waitBlockedBy(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var blocked int
		err := testPool.QueryRow(t.Context(),
			"SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))", pid).Scan(&blocked)
		if err != nil {
			t.Fatalf("read pg_stat_activity: %v", err)
		}
		if blocked > 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("no backend blocked by pid %d after 5s", pid)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// postgresNow returns the time on Postgres's clock.
func postgresNow(t *testing.T) time.Time {
	t.Helper()
	var now time.Time
	if err := testPool.QueryRow(t.Context(), "SELECT clock_timestamp()").Scan(&now); err != nil {
		t.Fatalf("read Postgres clock: %v", err)
	}
	return now
}

// transcode.failed records one sample, outcome failed, and leaves the consumer span in error; a
// redelivery records nothing more.
func TestReadyDurationOfFailedVideo(t *testing.T) {
	needDB(t)
	recorder, reader := testTelemetry(t)
	s, storage, _ := newServerWithStorage()
	id := completedUpload(t, s, storage)

	ctx, span := otel.Tracer("test").Start(t.Context(), "process "+TopicMediaTranscodes)
	r := transcodeRecord(id, failedEvent(id))
	before := postgresNow(t)
	err := handleTranscode(ctx, s, r)
	after := postgresNow(t)
	span.End()
	if err != nil {
		t.Fatal(err)
	}
	points := readySamples(t, reader)
	p, ok := points["failed"]
	if !ok || len(points) != 1 || p.Count != 1 || p.Sum <= 0 {
		t.Fatalf("samples = %v, want one positive with outcome failed", points)
	}
	// Measured on Postgres's clock, from processing_at to after the failing UPDATE committed.
	start := *loadVideo(t, id).ProcessingAt
	if low, high := before.Sub(start).Seconds(), after.Sub(start).Seconds(); p.Sum < low || p.Sum > high {
		t.Errorf("sample = %.6fs, want between %.6fs and %.6fs on Postgres's clock", p.Sum, low, high)
	}
	ended := recorder.Ended()
	if len(ended) == 0 || ended[len(ended)-1].Status().Code != codes.Error ||
		ended[len(ended)-1].Status().Description != "transcode failed: TRANSCODE_FAILURE_REASON_INVALID_INPUT" {
		t.Errorf("consumer span status = %v, want Error with the reason", ended[len(ended)-1].Status())
	}

	if err := handleTranscode(t.Context(), s, r); err != nil {
		t.Fatal(err)
	}
	if got := readySamples(t, reader)["failed"].Count; got != 1 {
		t.Errorf("after a redelivery: %d samples, want 1", got)
	}
}

// A video that became PROCESSING before processing_at existed moves as before and records no
// sample.
func TestReadyDurationSkipsVideoWithoutProcessingAt(t *testing.T) {
	needDB(t)
	_, reader := testTelemetry(t)
	s, _, _ := newServerWithStorage()
	ready, failed := newVideo(t, "PROCESSING"), newVideo(t, "PROCESSING")

	if err := handleTranscode(t.Context(), s, transcodeRecord(ready, completedEvent(ready))); err != nil {
		t.Fatal(err)
	}
	if err := handleTranscode(t.Context(), s, transcodeRecord(failed, failedEvent(failed))); err != nil {
		t.Fatal(err)
	}
	if v := loadVideo(t, ready); v.Status != "READY" || v.ProcessingAt != nil {
		t.Errorf("video = %s, processing_at %v; want READY without processing_at", v.Status, v.ProcessingAt)
	}
	wantUnchanged(t, failed, "FAILED")
	if points := readySamples(t, reader); len(points) != 0 {
		t.Errorf("samples = %v, want none", points)
	}
}

func TestTranscodeConsumerBoundsEachAttempt(t *testing.T) {
	s, _ := newServer()
	if got := s.TranscodeConsumerConfig("127.0.0.1:1").HandlerTimeout; got != 10*time.Second {
		t.Errorf("HandlerTimeout = %s, want 10s", got)
	}
}

// A transcode.completed whose row is locked past the attempt's deadline returns an error, and its
// rollback, against a Postgres that does not answer, ends within rollbackTimeout.
func TestTranscodeRollbackIsBounded(t *testing.T) {
	needDB(t)
	pool, hang := withHangingRollback(t, testPool)
	s := New(pool, newFakeStorage(), slog.New(slog.DiscardHandler))
	s.rollbackTimeout = 200 * time.Millisecond
	id := newVideo(t, "PROCESSING")

	lock, err := testPool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lock.Rollback(context.Background()) }()
	if _, err := lock.Exec(t.Context(), "SELECT 1 FROM videos WHERE id = $1 FOR UPDATE", id); err != nil {
		t.Fatal(err)
	}

	const attempt = 300 * time.Millisecond
	ctx, cancel := context.WithTimeout(t.Context(), attempt)
	defer cancel()
	start := time.Now()
	err = handleTranscode(ctx, s, transcodeRecord(id, completedEvent(id)))
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("HandleTranscode = nil, want an error")
	}
	if hang.rollbacks.Load() == 0 || hang.unbounded.Load() != 0 {
		t.Errorf("rollbacks = %d, without deadline %d; want some, all with a deadline", hang.rollbacks.Load(), hang.unbounded.Load())
	}
	if limit := attempt + s.rollbackTimeout + time.Second; elapsed > limit {
		t.Errorf("HandleTranscode took %s, want at most %s", elapsed, limit)
	}
	if err := lock.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	wantUnchanged(t, id, "PROCESSING")
}
