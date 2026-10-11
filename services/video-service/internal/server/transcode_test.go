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
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	mediav1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/internal/traceparent"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/store"
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

func completedEvent(id string) *mediav1.TranscodeEvent {
	return &mediav1.TranscodeEvent{
		Meta: outbox.NewMeta(),
		Event: &mediav1.TranscodeEvent_TranscodeCompleted{TranscodeCompleted: &mediav1.TranscodeCompleted{
			VideoId:      id,
			PlaylistKey:  "media/" + id + "/master.m3u8",
			ThumbnailKey: "media/" + id + "/thumbnail.jpg",
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
		PlaylistKey:  "media/" + id + "/master.m3u8",
		ThumbnailKey: "media/" + id + "/thumbnail.jpg",
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
	s, storage, logs := newServerWithStorage()
	id := newVideo(t, "PROCESSING")
	// As kafkax leaves the context of a record with a traceparent header.
	ctx := traceparent.NewContext(t.Context(), testTraceparent)

	before := time.Now()
	if err := handleTranscode(ctx, s, transcodeRecord(id, completedEvent(id))); err != nil {
		t.Fatal(err)
	}
	v := loadVideo(t, id)
	if v.Status != "READY" || v.DurationMs == nil || *v.DurationMs != testDurationMs ||
		v.PlaylistKey == nil || *v.PlaylistKey != "media/"+id+"/master.m3u8" ||
		v.ThumbnailKey == nil || *v.ThumbnailKey != "media/"+id+"/thumbnail.jpg" {
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
	if len(rows[0].headers) != 1 || rows[0].headers["traceparent"] != testTraceparent {
		t.Errorf("headers = %v, want the record's traceparent", rows[0].headers)
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

// A newer media-worker may send an event type this service does not know: skip it (ADR-0006).
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
// publishes video.ready, carrying the request's traceparent all the way.
func TestUploadToReadyThroughKafka(t *testing.T) {
	needDB(t)
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
	if _, err := completeUpload(traceparent.NewContext(t.Context(), testTraceparent), t, s, author, id); err != nil {
		t.Fatal(err)
	}

	uploadedRec := readTopic(t, brokers, TopicVideoLifecycle, id, 1)[0]
	wantVideoUploaded(t, uploadedRec.Value, id, author)
	// Like media-worker, answer with the traceparent of the record being handled.
	r := transcodeRecord(id, completedEvent(id))
	r.Headers = []kgo.RecordHeader{{Key: "traceparent", Value: []byte(headerValue(uploadedRec, "traceparent"))}}
	produce(t, brokers, r)

	recs := readTopic(t, brokers, TopicVideoLifecycle, id, 2)
	v := loadVideo(t, id)
	if v.Status != "READY" {
		t.Fatalf("status = %s, want READY", v.Status)
	}
	wantVideoReady(t, recs[1].Value, v)
	if got := headerValue(recs[1], "traceparent"); got != testTraceparent {
		t.Errorf("video.ready traceparent = %q, want %q", got, testTraceparent)
	}
	resp, err := getVideo(t, s, ids.New(), id)
	if err != nil || resp.GetVideo().GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY {
		t.Errorf("GetVideo by another user = %v, %v; want the READY video", resp, err)
	}
}
