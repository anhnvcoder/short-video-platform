package server

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/outbox"
)

func completeUpload(ctx context.Context, t *testing.T, s *Server, caller, videoID string) (*videov1.CompleteUploadResponse, error) {
	t.Helper()
	return call(ctx, caller, methodCompleteUpload, &videov1.CompleteUploadRequest{VideoId: videoID}, s.CompleteUpload)
}

// uploaded creates a video of caller through InitUpload and stores the matching object.
func uploaded(t *testing.T, s *Server, storage *fakeStorage, caller string) string {
	t.Helper()
	req := validRequest()
	resp, err := initUpload(t, s, caller, req)
	if err != nil {
		t.Fatal(err)
	}
	storage.put(resp.GetVideoId(), req.GetSizeBytes(), "video/mp4")
	return resp.GetVideoId()
}

type outboxRow struct {
	topic   string
	payload []byte
	headers map[string]string
}

// outboxRows returns the outbox rows keyed by videoID, oldest first.
func outboxRows(t *testing.T, videoID string) []outboxRow {
	t.Helper()
	rows, err := testPool.Query(t.Context(),
		"SELECT topic, payload, headers FROM outbox WHERE record_key = $1 ORDER BY id", videoID)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (outboxRow, error) {
		var x outboxRow
		err := r.Scan(&x.topic, &x.payload, &x.headers)
		return x, err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// wantUnchanged fails unless the video is still in st and has no outbox row.
func wantUnchanged(t *testing.T, videoID, st string) {
	t.Helper()
	if got := readStored(t, videoID).status; got != st {
		t.Errorf("status = %s, want %s", got, st)
	}
	if rows := outboxRows(t, videoID); len(rows) != 0 {
		t.Errorf("got %d outbox rows, want none", len(rows))
	}
}

// wantVideoUploaded fails unless payload is a video.uploaded event for the video.
func wantVideoUploaded(t *testing.T, payload []byte, videoID, author string) {
	t.Helper()
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(payload, &ev); err != nil {
		t.Fatalf("payload is not a VideoEvent: %v", err)
	}
	if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil || ev.GetMeta().GetOccurredAt() == nil {
		t.Errorf("event meta = %v, want an event_id and occurred_at", ev.GetMeta())
	}
	want := &videov1.VideoUploaded{
		VideoId:     videoID,
		AuthorId:    author,
		SourceKey:   "uploads/" + videoID,
		ContentType: "video/mp4",
		SizeBytes:   validRequest().GetSizeBytes(),
	}
	if !proto.Equal(ev.GetVideoUploaded(), want) {
		t.Errorf("video_uploaded = %v, want %v", ev.GetVideoUploaded(), want)
	}
}

func TestCompleteUploadMovesToProcessingAndEmitsVideoUploaded(t *testing.T) {
	needDB(t)
	testTelemetry(t)
	s, storage, logs := newServerWithStorage()
	author := ids.New()
	id := uploaded(t, s, storage, author)
	// As the otelgrpc stats handler of grpcserver leaves the context: the RPC's server span.
	ctx, span := otel.Tracer("test").Start(t.Context(), "CompleteUpload")
	defer span.End()

	resp, err := completeUpload(ctx, t, s, author, id)
	if err != nil {
		t.Fatal(err)
	}
	if v := resp.GetVideo(); v.GetVideoId() != id || v.GetAuthorId() != author ||
		v.GetStatus() != videov1.VideoStatus_VIDEO_STATUS_PROCESSING {
		t.Errorf("CompleteUpload = %v, want the video in PROCESSING", v)
	}
	if got := readStored(t, id).status; got != "PROCESSING" {
		t.Errorf("stored status = %s, want PROCESSING", got)
	}
	rows := outboxRows(t, id)
	if len(rows) != 1 {
		t.Fatalf("got %d outbox rows, want 1", len(rows))
	}
	if rows[0].topic != "video.lifecycle.v1" {
		t.Errorf("topic = %q, want video.lifecycle.v1", rows[0].topic)
	}
	if want := traceparentOf(span); len(rows[0].headers) != 1 || rows[0].headers["traceparent"] != want {
		t.Errorf("headers = %v, want the request span's traceparent %s", rows[0].headers, want)
	}
	wantVideoUploaded(t, rows[0].payload, id, author)

	recs := logs.records(t, "upload completed")
	if len(recs) != 1 {
		t.Fatalf("got %d \"upload completed\" log lines, want 1", len(recs))
	}
	for key, val := range map[string]string{"user_id": author, "video_id": id, "trace_id": span.SpanContext().TraceID().String()} {
		if recs[0][key] != val {
			t.Errorf("log %s = %v, want %q", key, recs[0][key], val)
		}
	}

	// A retry returns the video as it is and emits nothing more.
	again, err := completeUpload(ctx, t, s, author, id)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.GetVideo().GetStatus(); got != videov1.VideoStatus_VIDEO_STATUS_PROCESSING {
		t.Errorf("second CompleteUpload status = %s, want PROCESSING", got)
	}
	if rows := outboxRows(t, id); len(rows) != 1 {
		t.Errorf("got %d outbox rows after a second call, want 1", len(rows))
	}
	if n := len(logs.records(t, "upload completed")); n != 1 {
		t.Errorf("got %d \"upload completed\" log lines after a second call, want 1", n)
	}
}

func TestCompleteUploadInvalidID(t *testing.T) {
	s, _ := newServer()
	for _, id := range []string{"", "not-a-uuid", strings.ToUpper(ids.New()), "{" + ids.New() + "}"} {
		_, err := completeUpload(t.Context(), t, s, ids.New(), id)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
	}
}

// Another user's video, in any status, gets exactly the error of a missing one (UP-3), and
// nothing about it changes.
func TestCompleteUploadOfAnotherUserLooksLikeMissing(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	author, other := ids.New(), ids.New()

	_, missingErr := completeUpload(t.Context(), t, s, other, ids.New())
	wantError(t, missingErr, codes.NotFound, ReasonVideoNotFound)
	if msg := status.Convert(missingErr).Message(); msg != "video not found" {
		t.Fatalf("message = %q, want %q", msg, "video not found")
	}

	videos := map[string]string{"UPLOADING": uploaded(t, s, storage, author)}
	for _, st := range []string{"PROCESSING", "READY", "FAILED"} {
		videos[st] = ids.New()
		insertVideo(t, videos[st], author, st, st == "READY", time.Now(), time.Now())
	}
	heads := storage.headCalls()
	for st, id := range videos {
		_, err := completeUpload(t.Context(), t, s, other, id)
		if status.Code(err) != status.Code(missingErr) || grpcerr.Reason(err) != grpcerr.Reason(missingErr) ||
			status.Convert(err).Message() != status.Convert(missingErr).Message() {
			t.Errorf("CompleteUpload(%s video of another user) = %v, want the same error as a missing video: %v", st, err, missingErr)
		}
		wantUnchanged(t, id, st)
	}
	if got := storage.headCalls(); got != heads {
		t.Errorf("storage was asked %d times about other users' videos", got-heads)
	}
}

func TestCompleteUploadReturnsLaterStatusAsIs(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	author := ids.New()
	for st, want := range map[string]videov1.VideoStatus{
		"PROCESSING": videov1.VideoStatus_VIDEO_STATUS_PROCESSING,
		"READY":      videov1.VideoStatus_VIDEO_STATUS_READY,
	} {
		id := ids.New()
		insertVideo(t, id, author, st, st == "READY", time.Now(), time.Now())
		resp, err := completeUpload(t.Context(), t, s, author, id)
		if err != nil {
			t.Fatalf("CompleteUpload(%s video): %v", st, err)
		}
		if got := resp.GetVideo().GetStatus(); got != want {
			t.Errorf("status = %s, want %s", got, want)
		}
		wantUnchanged(t, id, st)
	}
	if n := storage.headCalls(); n != 0 {
		t.Errorf("storage was asked %d times, want none", n)
	}
}

func TestCompleteUploadOfFailedVideo(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, id := ids.New(), ids.New()
	insertVideo(t, id, author, "FAILED", false, time.Time{}, time.Now())
	_, err := completeUpload(t.Context(), t, s, author, id)
	wantError(t, err, codes.FailedPrecondition, ReasonVideoFailed)
	wantUnchanged(t, id, "FAILED")
}

// A missing or wrong object leaves the video UPLOADING, so the client can upload again with the
// same form and then complete.
func TestCompleteUploadRejectsMissingOrMismatchedObject(t *testing.T) {
	needDB(t)
	size := validRequest().GetSizeBytes()
	for _, tc := range []struct {
		name        string
		put         bool
		size        int64
		contentType string
		reason      string
	}{
		{name: "missing", reason: ReasonUploadNotFound},
		{name: "smaller", put: true, size: size - 1, contentType: "video/mp4", reason: ReasonUploadMismatch},
		{name: "larger", put: true, size: size + 1, contentType: "video/mp4", reason: ReasonUploadMismatch},
		{name: "other content type", put: true, size: size, contentType: "video/webm", reason: ReasonUploadMismatch},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, storage, _ := newServerWithStorage()
			author := ids.New()
			resp, err := initUpload(t, s, author, validRequest())
			if err != nil {
				t.Fatal(err)
			}
			id := resp.GetVideoId()
			if tc.put {
				storage.put(id, tc.size, tc.contentType)
			}
			_, err = completeUpload(t.Context(), t, s, author, id)
			wantError(t, err, codes.FailedPrecondition, tc.reason)
			wantUnchanged(t, id, "UPLOADING")

			storage.put(id, size, "video/mp4")
			if _, err := completeUpload(t.Context(), t, s, author, id); err != nil {
				t.Fatalf("CompleteUpload after a correct upload: %v", err)
			}
			if rows := outboxRows(t, id); len(rows) != 1 {
				t.Errorf("got %d outbox rows, want 1", len(rows))
			}
		})
	}
}

func TestCompleteUploadStorageErrorIsUnavailable(t *testing.T) {
	needDB(t)
	for name, headErr := range map[string]error{
		"server error":  errors.New("objstore: head uploads/x: 503 SlowDown at 10.0.0.7"),
		"access denied": objstore.ErrAccessDenied,
	} {
		t.Run(name, func(t *testing.T) {
			s, storage, logs := newServerWithStorage()
			author := ids.New()
			id := uploaded(t, s, storage, author)
			storage.headErr = headErr

			_, err := completeUpload(t.Context(), t, s, author, id)
			if status.Code(err) != codes.Unavailable || status.Convert(err).Message() != "storage unavailable" ||
				grpcerr.Reason(err) != ReasonDependencyUnavailable {
				t.Errorf("error = %v, want UNAVAILABLE %s with message %q", err, ReasonDependencyUnavailable, "storage unavailable")
			}
			wantUnchanged(t, id, "UPLOADING")
			if recs := logs.records(t, "head uploaded file"); len(recs) != 1 || recs[0]["error"] == nil || recs[0]["video_id"] != id {
				t.Errorf("storage failure log = %v, want one line with error and video_id", recs)
			}
		})
	}
}

// A failed outbox insert rolls the status change back.
func TestCompleteUploadOutboxFailureRollsBack(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	author := ids.New()
	id := uploaded(t, s, storage, author)

	// Refuse outbox rows of this video only; id is a server-generated UUID.
	ctx := t.Context()
	_, err := testPool.Exec(ctx, `
		CREATE FUNCTION refuse_test_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			IF NEW.record_key = '`+id+`' THEN
				RAISE EXCEPTION 'outbox insert refused by test';
			END IF;
			RETURN NEW;
		END $$;
		CREATE TRIGGER refuse_test_outbox BEFORE INSERT ON outbox
			FOR EACH ROW EXECUTE FUNCTION refuse_test_outbox();`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, err := testPool.Exec(context.Background(),
			"DROP TRIGGER refuse_test_outbox ON outbox; DROP FUNCTION refuse_test_outbox()")
		if err != nil {
			t.Error(err)
		}
	})

	_, err = completeUpload(ctx, t, s, author, id)
	if status.Code(err) != codes.Internal || status.Convert(err).Message() != "internal error" {
		t.Errorf("error = %v, want INTERNAL with message %q", err, "internal error")
	}
	wantUnchanged(t, id, "UPLOADING")
}

// A video that fails while CompleteUpload waits for its row lock: the UPDATE then matches no row,
// and the call answers VIDEO_FAILED as for a video that had failed before, writing no event.
func TestCompleteUploadOfVideoFailedMeanwhile(t *testing.T) {
	needDB(t)
	s, storage, _ := newServerWithStorage()
	author := ids.New()
	id := uploaded(t, s, storage, author)
	ctx := t.Context()

	holder, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(ctx, "SELECT 1 FROM videos WHERE id = $1 FOR UPDATE", id); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := completeUpload(ctx, t, s, author, id)
		result <- err
	}()
	eventually(t, "the call to wait for the row lock", func() bool {
		var waiting int
		err := testPool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == 1
	})
	if _, err := holder.Exec(ctx, "UPDATE videos SET status = 'FAILED' WHERE id = $1", id); err != nil {
		t.Fatal(err)
	}
	if err := holder.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	wantError(t, <-result, codes.FailedPrecondition, ReasonVideoFailed)
	wantUnchanged(t, id, "FAILED")
	if rows := outboxRows(t, id); len(rows) != 0 {
		t.Errorf("got %d outbox rows, want 0", len(rows))
	}
}

// Two calls racing on one video: the second UPDATE waits for the first transaction, then matches
// no row, so exactly one event is written and both calls answer PROCESSING.
func TestConcurrentCompleteUploadEmitsOnce(t *testing.T) {
	needDB(t)
	s, storage, logs := newServerWithStorage()
	author := ids.New()
	id := uploaded(t, s, storage, author)
	ctx := t.Context()

	// Hold the row so both calls reach their UPDATE before either can go on.
	holder, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(ctx, "SELECT 1 FROM videos WHERE id = $1 FOR UPDATE", id); err != nil {
		t.Fatal(err)
	}

	type result struct {
		resp *videov1.CompleteUploadResponse
		err  error
	}
	results := make(chan result, 2)
	for range 2 {
		go func() {
			resp, err := completeUpload(ctx, t, s, author, id)
			results <- result{resp, err}
		}()
	}
	eventually(t, "both calls to wait for the row lock", func() bool {
		var waiting int
		err := testPool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		return waiting == 2
	})
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	for range 2 {
		r := <-results
		if r.err != nil {
			t.Fatalf("CompleteUpload: %v", r.err)
		}
		if got := r.resp.GetVideo().GetStatus(); got != videov1.VideoStatus_VIDEO_STATUS_PROCESSING {
			t.Errorf("status = %s, want PROCESSING", got)
		}
	}
	if rows := outboxRows(t, id); len(rows) != 1 {
		t.Errorf("got %d outbox rows, want 1", len(rows))
	}
	if n := len(logs.records(t, "upload completed")); n != 1 {
		t.Errorf("got %d \"upload completed\" log lines, want 1", n)
	}
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The relay, wired as main wires it, puts the event on video.lifecycle.v1 keyed by video_id with
// a traceparent header in the request's trace: that of the producer span, a child of the
// request's span.
func TestRelaySendsVideoUploadedWithTraceparent(t *testing.T) {
	needDB(t)
	recorder, _ := testTelemetry(t)
	cluster, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(3, TopicVideoLifecycle))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cluster.Close)
	brokers := strings.Join(cluster.ListenAddrs(), ",")

	s, storage, logs := newServerWithStorage()
	author := ids.New()
	id := uploaded(t, s, storage, author)
	ctx, span := otel.Tracer("test").Start(t.Context(), "CompleteUpload")
	_, err = completeUpload(ctx, t, s, author, id)
	span.End()
	if err != nil {
		t.Fatal(err)
	}

	producer, err := kafkax.NewClient(brokers, "video-service-test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(producer.Close)
	relayCtx, stopRelay := context.WithCancel(t.Context())
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		outbox.NewRelay(testPool, producer, slog.New(slog.NewJSONHandler(logs, nil))).Run(relayCtx)
	}()
	t.Cleanup(func() {
		stopRelay()
		<-relayDone
	})

	consumer, err := kafkax.NewClient(brokers, "video-service-test-consumer",
		kgo.ConsumeTopics(TopicVideoLifecycle), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(consumer.Close)
	var rec *kgo.Record
	pollCtx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	for rec == nil && pollCtx.Err() == nil {
		consumer.PollFetches(pollCtx).EachRecord(func(r *kgo.Record) {
			if string(r.Key) == id {
				rec = r
			}
		})
	}
	if rec == nil {
		t.Fatalf("no record keyed %s on %s", id, TopicVideoLifecycle)
	}
	var tps []string
	for _, h := range rec.Headers {
		if h.Key == "traceparent" {
			tps = append(tps, string(h.Value))
		}
	}
	if len(tps) != 1 {
		t.Fatalf("traceparent headers = %q, want one", tps)
	}
	if got := traceIDOf(t, tps[0]); got != span.SpanContext().TraceID() {
		t.Errorf("traceparent %s is in trace %s, want the request's trace %s", tps[0], got, span.SpanContext().TraceID())
	}
	// The relay ends the producer span after the broker acknowledged the record.
	var send sdktrace.ReadOnlySpan
	eventually(t, "the producer span to end", func() bool {
		for _, ended := range recorder.Ended() {
			if traceparentOfContext(ended.SpanContext()) == tps[0] {
				send = ended
			}
		}
		return send != nil
	})
	if send.Name() != "send "+TopicVideoLifecycle || send.Parent().SpanID() != span.SpanContext().SpanID() {
		t.Errorf("record traceparent %s is not a producer span child of the request span", tps[0])
	}
	wantVideoUploaded(t, rec.Value, id, author)
}
