package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	mediav1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/objstore"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/services/video-service/internal/store"
)

// Topic and consumer group of the transcode results. The topic must be one redpanda-init creates,
// since the broker does not create topics on first use.
const (
	TopicMediaTranscodes = "media.transcodes.v1"
	TranscodeGroup       = "video-service"
	// transcodeHandlerTimeout bounds one attempt at a transcode event, its Postgres work and S3
	// deletes included. An attempt past it is a temporary error that kafkax retries, so a held row
	// lock or a hung S3 call cannot stall the partition.
	transcodeHandlerTimeout = 10 * time.Second
)

// TranscodeConsumerConfig returns the consumer of TopicMediaTranscodes in TranscodeGroup, with
// the default retry budget of kafkax.
func (s *Server) TranscodeConsumerConfig(brokers string) kafkax.ConsumerConfig {
	return kafkax.ConsumerConfig{
		Brokers:        brokers,
		ClientID:       TranscodeGroup,
		Group:          TranscodeGroup,
		Topics:         []string{TopicMediaTranscodes},
		Handler:        s.HandleTranscode,
		Logger:         s.logger,
		HandlerTimeout: transcodeHandlerTimeout,
	}
}

// HandleTranscode is the kafkax.Handler of TopicMediaTranscodes (architecture §7.1).
// transcode.completed moves a PROCESSING video to READY and writes video.ready to the outbox in
// one transaction; transcode.failed moves it to FAILED, then deletes its files, the saga's
// compensation step. Both moves are one-way, so a redelivered event moves nothing and needs no
// processed_events table: READY ignores it, FAILED deletes the files again.
//
// The event comes from media-worker, which handles untrusted files: it is only acted on for a
// PROCESSING video and with keys under media/<video_id>/ (FF-6). Anything else goes to the
// dead-letter topic (IN-5).
func (s *Server) HandleTranscode(ctx context.Context, r *kgo.Record, _ kafkax.Attempt) error {
	var ev mediav1.TranscodeEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		return kafkax.Permanent(fmt.Errorf("decode TranscodeEvent: %w", err))
	}
	switch e := ev.GetEvent().(type) {
	case *mediav1.TranscodeEvent_TranscodeCompleted:
		id, err := checkTranscodeEvent(r, &ev, e.TranscodeCompleted.GetVideoId())
		if err != nil {
			return err
		}
		return s.transcodeCompleted(transcodeContext(ctx, &ev, id), id, e.TranscodeCompleted)
	case *mediav1.TranscodeEvent_TranscodeFailed:
		id, err := checkTranscodeEvent(r, &ev, e.TranscodeFailed.GetVideoId())
		if err != nil {
			return err
		}
		return s.transcodeFailed(transcodeContext(ctx, &ev, id), id, e.TranscodeFailed)
	}
	// An unknown branch decodes as nil: skip it. Adding a branch is a compatible change within v1,
	// so a newer media-worker may send one this service does not know yet.
	return nil
}

// checkTranscodeEvent checks the envelope and returns the parsed video_id.
func checkTranscodeEvent(r *kgo.Record, ev *mediav1.TranscodeEvent, videoID string) (uuid.UUID, error) {
	if ev.GetMeta() == nil {
		return uuid.UUID{}, kafkax.Permanent(errors.New("transcode event has no meta"))
	}
	id, err := ids.Parse(videoID)
	if err != nil {
		return uuid.UUID{}, kafkax.Permanent(errors.New("transcode event video_id is not a canonical UUID"))
	}
	if string(r.Key) != videoID {
		return uuid.UUID{}, kafkax.Permanent(errors.New("transcode event record key differs from video_id"))
	}
	return id, nil
}

func transcodeContext(ctx context.Context, ev *mediav1.TranscodeEvent, id uuid.UUID) context.Context {
	return logx.With(ctx, slog.String("video_id", id.String()), slog.String("event_id", ev.GetMeta().GetEventId()))
}

func (s *Server) transcodeCompleted(ctx context.Context, id uuid.UUID, c *mediav1.TranscodeCompleted) error {
	prefix := mediaPrefix(id)
	for _, key := range []string{c.GetPlaylistKey(), c.GetThumbnailKey()} {
		if !objstore.IsMediaKey(key, id.String()) {
			return kafkax.Permanent(fmt.Errorf("transcode.completed key %q is not under %s", key, prefix))
		}
	}
	d := c.GetDuration()
	if d.CheckValid() != nil || d.AsDuration().Milliseconds() < 1 {
		return kafkax.Permanent(errors.New("transcode.completed duration is not positive"))
	}

	v, moved, err := s.markReady(ctx, id, c, d.AsDuration().Milliseconds())
	if err != nil {
		return err
	}
	if !moved {
		return s.notProcessing(ctx, id, "transcode.completed")
	}
	s.recordReadyDuration(ctx, v.ProcessingAt, "ready")
	s.logger.InfoContext(ctx, "video ready")
	return nil
}

// markReady moves the video from PROCESSING to READY and writes its video.ready event in one
// transaction; the UPDATE locks the row before the outbox insert, as internal/outbox requires.
// It returns the video as the UPDATE left it and true once committed, or false, writing
// nothing, when the video is not PROCESSING.
func (s *Server) markReady(ctx context.Context, id uuid.UUID, c *mediav1.TranscodeCompleted, durationMs int64) (store.Video, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return store.Video{}, false, fmt.Errorf("begin transaction: %w", err)
	}
	defer rollback(ctx, tx, s.rollbackTimeout)

	playlist, thumbnail := c.GetPlaylistKey(), c.GetThumbnailKey()
	v, err := s.queries.WithTx(tx).MarkVideoReady(ctx, store.MarkVideoReadyParams{
		ID:           id,
		DurationMs:   &durationMs,
		PlaylistKey:  &playlist,
		ThumbnailKey: &thumbnail,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.Video{}, false, nil
	}
	if err != nil {
		return store.Video{}, false, fmt.Errorf("mark video ready: %w", err)
	}
	ev := &videov1.VideoEvent{
		Meta: outbox.NewMeta(),
		Event: &videov1.VideoEvent_VideoReady{VideoReady: &videov1.VideoReady{
			VideoId:      id.String(),
			AuthorId:     v.AuthorID.String(),
			Title:        v.Title,
			Duration:     durationpb.New(time.Duration(durationMs) * time.Millisecond),
			PlaylistKey:  playlist,
			ThumbnailKey: thumbnail,
			// Set by the UPDATE, so the event carries exactly what GetVideo returns.
			PublishedAt: timestamppb.New(*v.PublishedAt),
		}},
	}
	if err := outbox.Write(ctx, tx, TopicVideoLifecycle, id.String(), ev); err != nil {
		return store.Video{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return store.Video{}, false, fmt.Errorf("commit transaction: %w", err)
	}
	return v, true, nil
}

// rollback rolls tx back within timeout, even when ctx has already ended; after Commit it does
// nothing. A Postgres that does not answer cannot hold the caller longer than timeout.
func rollback(ctx context.Context, tx pgx.Tx, timeout time.Duration) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), timeout)
	defer cancel()
	_ = tx.Rollback(ctx)
}

// recordReadyDuration records the time from when the video became PROCESSING until now as
// svp.video.ready.duration with outcome. It runs once the new status is committed, and reads the
// end from Postgres's clock, the one that set processing_at, so a lock wait or a slow commit is
// counted and the service's own clock never is. A video that became PROCESSING before
// processing_at existed has none, and records nothing; so does a video whose clock read fails,
// as its status is already committed and the handler must not run again for a sample.
func (s *Server) recordReadyDuration(ctx context.Context, processingAt *time.Time, outcome string) {
	if processingAt == nil {
		return
	}
	end, err := s.queries.ClockTimestamp(ctx)
	if err != nil {
		s.logger.WarnContext(ctx, "ready duration not recorded", slog.String("outcome", outcome), slog.Any("error", err))
		return
	}
	s.readyDuration.Record(ctx, end.Sub(*processingAt).Seconds(),
		metric.WithAttributes(attribute.String("outcome", outcome)))
}

func (s *Server) transcodeFailed(ctx context.Context, id uuid.UUID, f *mediav1.TranscodeFailed) error {
	processingAt, err := s.queries.MarkVideoFailed(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return s.notProcessing(ctx, id, "transcode.failed")
	}
	if err != nil {
		return fmt.Errorf("mark video failed: %w", err)
	}
	// The UPDATE ran on its own and is committed.
	s.recordReadyDuration(ctx, processingAt, "failed")
	// The record was handled, but the trace ends in a failed video. The reason is an enum name;
	// the free-text detail stays in the log.
	trace.SpanFromContext(ctx).SetStatus(codes.Error, "transcode failed: "+f.GetReason().String())
	s.logger.WarnContext(ctx, "video failed",
		slog.String("reason", f.GetReason().String()), slog.String("detail", f.GetDetail()))
	return s.deleteFiles(ctx, id)
}

// notProcessing settles a transcode event that moved nothing because the video is not
// PROCESSING.
func (s *Server) notProcessing(ctx context.Context, id uuid.UUID, event string) error {
	v, err := s.queries.GetVideo(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return kafkax.Permanent(fmt.Errorf("%s for a video that does not exist", event))
	}
	if err != nil {
		return fmt.Errorf("select video: %w", err)
	}
	switch v.Status {
	case statusReady:
		// A redelivery, or a late failure of a video already published: READY is final.
		s.logger.InfoContext(ctx, "transcode event ignored", slog.String("event", event), slog.String("status", v.Status))
		return nil
	case statusFailed:
		// A redelivery whose deletes may not have finished, or a worker that wrote
		// media/<video_id>/ again after the video failed: delete again.
		s.logger.InfoContext(ctx, "transcode event for a failed video", slog.String("event", event))
		return s.deleteFiles(ctx, id)
	case statusUploading:
		// media-worker only hears of a video once it is PROCESSING: the event is forged or
		// misrouted, and must not kill an upload in progress (FF-6).
		return kafkax.Permanent(fmt.Errorf("%s for a video still UPLOADING", event))
	}
	// PROCESSING now but not at the UPDATE: CompleteUpload committed in between, so the event
	// came before video.uploaded. Retrying sees the video as it settles.
	return fmt.Errorf("%s: video became %s meanwhile", event, v.Status)
}

// deleteFiles removes the source upload and whatever HLS output exists for the video. Both
// deletes succeed when there is nothing to delete, so running them again is safe; an error is
// returned for kafkax to retry, and the record is committed only once both are done.
func (s *Server) deleteFiles(ctx context.Context, id uuid.UUID) error {
	if err := s.storage.Delete(ctx, objstore.UploadsPrefix+id.String()); err != nil {
		return fmt.Errorf("delete source upload: %w", err)
	}
	if err := s.storage.DeletePrefix(ctx, mediaPrefix(id)); err != nil {
		return fmt.Errorf("delete media files: %w", err)
	}
	s.logger.InfoContext(ctx, "video files deleted")
	return nil
}

// mediaPrefix returns media/<video_id>/, under which every object of the video's HLS output
// lives.
func mediaPrefix(id uuid.UUID) string {
	return objstore.MediaPrefix + id.String() + "/"
}
