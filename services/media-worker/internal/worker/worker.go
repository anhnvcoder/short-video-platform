// Package worker consumes video.uploaded from video.lifecycle.v1, transcodes the source to HLS
// and publishes transcode.completed or transcode.failed to media.transcodes.v1 (architecture
// §7.1).
//
// Output is immutable: a version is the event_id of the video.uploaded, and its objects live under
// media/<video_id>/<version>/. Each try uploads into a directory of its own, <version>/<attempt>/,
// and then creates <version>/master.m3u8 only if no try created it before, so no object a player
// may already hold is ever written again and every object can be cached for a year. A try that
// finds the master already there transcodes nothing and publishes the stored result again.
//
// Error classes (A-1-review, M-1-review): a bad event goes to the dead-letter topic; a file that
// is not a usable video (whitelist refusal, corrupt data, limits, ffprobe or ffmpeg failing,
// killed by a signal or timed out) is answered with transcode.failed at once, so a crafted file
// runs only once and never blocks its partition through retries; only storage, Kafka and
// environment errors are retried, and the last try turns them into RETRIES_EXHAUSTED.
package worker

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/metric/noop"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/event/v1"
	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

// Topics and consumer group. The topics must be ones redpanda-init creates, since the broker does
// not create topics on first use.
const (
	InputTopic  = "video.lifecycle.v1"
	OutputTopic = "media.transcodes.v1"
	Group       = "media-worker"
)

// Retry budget: about two to four minutes of backoff, so storage or broker trouble lasting a
// minute or two does not turn into RETRIES_EXHAUSTED, which makes video-service delete the
// user's upload.
const (
	maxAttempts = 10
	backoffBase = time.Second
	backoffMax  = time.Minute
	// tryTimeout bounds one try: the download, ffprobe and ffmpeg (cut at 30 s and 10 minutes by
	// transcode) and the uploads. Past it the try fails as temporary, not blamed on the file.
	tryTimeout = 15 * time.Minute
	// rebalanceTimeout covers the whole retry budget of a record: every try with its publish,
	// plus every backoff (at most backoffMax each). A rebalance waits for the record in hand,
	// since a commit on a revoked partition would be lost, and a member that does not rejoin
	// in time is dropped from the group.
	rebalanceTimeout = maxAttempts*(tryTimeout+produceTimeout) + (maxAttempts-1)*backoffMax
)

const (
	// maxSourceBytes caps a download whatever the event says, at the 500 MiB upload limit.
	maxSourceBytes = 500 << 20
	// produceTimeout bounds publishing the result; past it the try fails and is retried.
	produceTimeout = 30 * time.Second
	// maxDetail caps the diagnostic carried by transcode.failed.
	maxDetail = 512

	sourceName = "source"
	outName    = "out"

	// cacheControl goes on every object of a version: its keys never get other bytes.
	cacheControl = "max-age=31536000, immutable"
	// maxPlaylistBytes caps a stored playlist read back: a 3-minute video at 4 s segments has a
	// few KB.
	maxPlaylistBytes = 1 << 20
)

// instrumentationName names the tracer and meter of the worker.
const instrumentationName = "github.com/anhnvcoder/svp-backend/services/media-worker/internal/worker"

// transcodeBuckets are the bucket bounds in seconds, the same as svp.video.ready.duration of
// video-service; this histogram feeds dashboards only, no SLO.
var transcodeBuckets = []float64{10, 20, 30, 45, 60, 90, 120, 180, 300, 600}

// Storage is the part of objstore.Store the worker uses. Errors follow objstore: ErrNotFound,
// ErrTooLarge, ErrAccessDenied and ErrExists wrapped; anything else is temporary.
type Storage interface {
	Download(ctx context.Context, key, path string, maxBytes int64) error
	Upload(ctx context.Context, key, path, contentType, cacheControl string) error
	// Create is Upload only when key holds no object yet, ErrExists otherwise.
	Create(ctx context.Context, key, path, contentType, cacheControl string) error
	// Exists lists key: false only when storage answered that it holds no such object.
	Exists(ctx context.Context, key string) (bool, error)
}

// Worker handles one video.uploaded at a time in its own directory under WorkDir.
type Worker struct {
	store    Storage
	producer *kgo.Client
	workDir  string
	logger   *slog.Logger
	// tryTimeout is the constant of the same name; tests shorten it.
	tryTimeout time.Duration
	// transcodeDuration is svp.transcode.duration: the transcode step of a try that ended with a
	// result.
	transcodeDuration metric.Float64Histogram
}

// New returns a Worker that reads and writes objects through store, publishes with producer and
// keeps job files under workDir. Its spans and metrics go to the global providers.
func New(store Storage, producer *kgo.Client, workDir string, logger *slog.Logger) *Worker {
	transcodeDuration, err := otel.Meter(instrumentationName).Float64Histogram("svp.transcode.duration",
		metric.WithUnit("s"), metric.WithDescription("Time ffprobe and ffmpeg took on a try that ended with a result"),
		metric.WithExplicitBucketBoundaries(transcodeBuckets...))
	if err != nil {
		// A metric never stops the worker: report the error and record nothing.
		otel.Handle(err)
		transcodeDuration = noop.Float64Histogram{}
	}
	return &Worker{
		store: store, producer: producer, workDir: workDir, logger: logger, tryTimeout: tryTimeout,
		transcodeDuration: transcodeDuration,
	}
}

// ConsumerConfig returns the consumer of InputTopic in Group with the worker's retry budget:
// one record per poll, and rebalances wait for the record in hand. HandlerTimeout stays unset:
// Handle bounds each try with tryTimeout and the publish of its result with produceTimeout,
// instead of the 10 s or 30 s of the other consumers, which would cut short a transcode that
// ffmpeg may run for up to 10 minutes.
func (w *Worker) ConsumerConfig(brokers string) kafkax.ConsumerConfig {
	return kafkax.ConsumerConfig{
		Brokers:          brokers,
		ClientID:         Group,
		Group:            Group,
		Topics:           []string{InputTopic},
		Handler:          w.Handle,
		Logger:           w.logger,
		MaxAttempts:      maxAttempts,
		BackoffBase:      backoffBase,
		BackoffMax:       backoffMax,
		MaxPollRecords:   1,
		BlockRebalance:   true,
		RebalanceTimeout: rebalanceTimeout,
	}
}

// CleanWorkDir removes the job directories a previous run left in the work directory (a job
// cut short by a crash), creating the directory if needed. Only directories named by a video id
// go: other entries stay, so a WORK_DIR shared with other files (such as /tmp) loses nothing
// else. The directory itself stays too: it is a mount point.
func (w *Worker) CleanWorkDir() error {
	if err := os.MkdirAll(w.workDir, 0o750); err != nil {
		return fmt.Errorf("create work directory: %w", err)
	}
	entries, err := os.ReadDir(w.workDir)
	if err != nil {
		return fmt.Errorf("read work directory: %w", err)
	}
	for _, e := range entries {
		if !e.IsDir() || !isID(e.Name()) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(w.workDir, e.Name())); err != nil {
			return fmt.Errorf("clean work directory: %w", err)
		}
	}
	return nil
}

// Handle is the kafkax.Handler of InputTopic.
func (w *Worker) Handle(ctx context.Context, r *kgo.Record, a kafkax.Attempt) error {
	up, version, err := decode(r)
	if err != nil || up == nil {
		return err
	}
	ctx = logx.With(ctx, slog.String("video_id", up.GetVideoId()), slog.String("version", version))

	j := &job{w: w, up: up, version: version}
	tryCtx, cancel := context.WithTimeout(ctx, w.tryTimeout)
	ev, err := j.run(tryCtx)
	cancel()
	if err != nil {
		if ctx.Err() != nil || !a.Last {
			// Stopping (the record stays uncommitted) or a temporary error kafkax retries.
			j.log(ctx, slog.LevelWarn, "transcode job interrupted", a, slog.String("error", w.scrub(err.Error())))
			return err
		}
		ev = w.failed(up, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED, err)
	}
	if err := w.publish(ctx, up.GetVideoId(), ev); err != nil {
		j.log(ctx, slog.LevelWarn, "publish transcode result failed", a, slog.String("error", err.Error()))
		return err
	}
	j.log(ctx, slog.LevelInfo, "transcode job finished", a, outcomeAttrs(ev)...)
	// Only once the result is out, so a try retried after a failed publish counts once; a try
	// that ended before transcoding (source missing) has no transcode step to count.
	if j.transcode > 0 {
		outcome := "ready"
		if ev.GetTranscodeFailed() != nil {
			outcome = "failed"
		}
		w.transcodeDuration.Record(ctx, j.transcode.Seconds(), metric.WithAttributes(attribute.String("outcome", outcome)))
	}
	return nil
}

// decode returns the video.uploaded carried by r with the version of its output (its event_id),
// nil for any other event (the topic carries the whole video lifecycle; skipped and committed),
// or a permanent error for a record that breaks the contract.
func decode(r *kgo.Record) (*videov1.VideoUploaded, string, error) {
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		return nil, "", kafkax.Permanent(fmt.Errorf("decode VideoEvent: %w", err))
	}
	var up *videov1.VideoUploaded
	switch e := ev.GetEvent().(type) {
	case *videov1.VideoEvent_VideoUploaded:
		up = e.VideoUploaded
	default:
		// video_ready is for feed-service; an unknown branch decodes as nil.
		return nil, "", nil
	}
	if err := checkUploaded(r, &ev, up); err != nil {
		return nil, "", kafkax.Permanent(err)
	}
	return up, ev.GetMeta().GetEventId(), nil
}

// checkUploaded checks the fields of a video.uploaded the worker relies on. The event_id becomes
// a path segment of public keys: a canonical UUID only, like the video_id.
func checkUploaded(r *kgo.Record, ev *videov1.VideoEvent, up *videov1.VideoUploaded) error {
	switch {
	case ev.GetMeta() == nil:
		return errors.New("video.uploaded has no meta")
	case !isID(ev.GetMeta().GetEventId()):
		return errors.New("video.uploaded meta.event_id is not a canonical UUID")
	case !isID(up.GetVideoId()):
		return errors.New("video.uploaded video_id is not a canonical UUID")
	case string(r.Key) != up.GetVideoId():
		return errors.New("video.uploaded record key differs from video_id")
	case up.GetSourceKey() != objstore.UploadsPrefix+up.GetVideoId():
		return errors.New("video.uploaded source_key is not uploads/<video_id>")
	case up.GetSizeBytes() < 1:
		return errors.New("video.uploaded size_bytes is not positive")
	}
	return nil
}

func isID(s string) bool {
	_, err := ids.Parse(s)
	return err == nil
}

// job is one try at one video.
type job struct {
	w       *Worker
	up      *videov1.VideoUploaded
	version string

	download, transcode, upload time.Duration
}

// run looks for the version's master; when it is there it reads the stored result back,
// otherwise it downloads, transcodes, uploads into a directory of this try and creates the
// master. It returns the event to publish, transcode.failed for a permanent failure included, or
// a temporary error. The job directory is removed on return.
func (j *job) run(ctx context.Context) (*mediav1.TranscodeEvent, error) {
	id := j.up.GetVideoId()
	prefix := objstore.MediaPrefix + id + "/" + j.version + "/"
	dir := filepath.Join(j.w.workDir, id)
	// A redelivery after a crash finds the previous try's files: start clean.
	if err := os.RemoveAll(dir); err != nil {
		return nil, fmt.Errorf("clean job directory: %w", err)
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("create job directory: %w", err)
	}
	defer func() { _ = os.RemoveAll(dir) }()

	// Only saves a transcode: an answer gone stale is caught when the master is created.
	var exists bool
	err := j.step(ctx, "check output", func(ctx context.Context) error {
		var err error
		exists, err = j.w.store.Exists(ctx, prefix+transcode.MasterPlaylist)
		return err
	})
	if err != nil {
		return nil, err
	}
	if exists {
		return j.stored(ctx, dir, prefix)
	}

	src := filepath.Join(dir, sourceName)
	start := time.Now()
	err = j.step(ctx, "download source", func(ctx context.Context) error {
		return j.w.store.Download(ctx, j.up.GetSourceKey(), src, min(j.up.GetSizeBytes(), maxSourceBytes))
	})
	j.download = time.Since(start)
	switch {
	case errors.Is(err, objstore.ErrNotFound):
		return j.w.failed(j.up, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_SOURCE_MISSING, err), nil
	case errors.Is(err, objstore.ErrTooLarge):
		// The object grew after CompleteUpload checked it (UP-2): not the file that was accepted.
		return j.w.failed(j.up, mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, err), nil
	case err != nil:
		return nil, err
	}

	// A new directory for every try, never used again: a try still running elsewhere (a member
	// that lost its session keeps its handler going) writes only into its own.
	attempt := ids.New()
	out := filepath.Join(dir, outName)
	start = time.Now()
	var res transcode.Result
	// transcode.Run adds a span for each ffprobe and ffmpeg run under this one.
	err = j.step(ctx, "transcode", func(ctx context.Context) error {
		var err error
		res, err = transcode.Run(ctx, src, out, attempt)
		return err
	})
	j.transcode = time.Since(start)
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		if reason, ok := permanentReason(err); ok {
			return j.w.failed(j.up, reason, err), nil
		}
		return nil, err
	}

	start = time.Now()
	err = j.step(ctx, "upload output", func(ctx context.Context) error {
		// Files come segments first and master.m3u8 last: no playlist is visible before its parts,
		// and the master, the only object of the version outside the attempt directory, is
		// created only once everything it names is stored.
		for _, f := range res.Files {
			path := filepath.Join(out, filepath.FromSlash(f.Path))
			if f.Path == transcode.MasterPlaylist {
				return j.w.store.Create(ctx, prefix+f.Path, path, f.ContentType, cacheControl)
			}
			if err := j.w.store.Upload(ctx, prefix+attempt+"/"+f.Path, path, f.ContentType, cacheControl); err != nil {
				return err
			}
		}
		return errors.New("transcode output has no master playlist")
	})
	j.upload = time.Since(start)
	switch {
	case errors.Is(err, objstore.ErrExists):
		// Another try created the master first; this try's directory stays unreferenced.
		return j.stored(ctx, dir, prefix)
	case err != nil:
		return nil, err
	}
	return completed(j.up, prefix, attempt, res.Duration, res.Renditions), nil
}

// stored reads back the master of the version under prefix and the playlist of its lowest
// rendition, and returns the transcode.completed they describe, as the try that created the
// master published it. It writes nothing; every error is temporary, as the result is there.
func (j *job) stored(ctx context.Context, dir, prefix string) (*mediav1.TranscodeEvent, error) {
	var ev *mediav1.TranscodeEvent
	err := j.step(ctx, "read output", func(ctx context.Context) error {
		path := filepath.Join(dir, transcode.MasterPlaylist)
		if err := j.w.store.Download(ctx, prefix+transcode.MasterPlaylist, path, maxPlaylistBytes); err != nil {
			return err
		}
		data, err := os.ReadFile(path) //nolint:gosec // the file just downloaded into the job directory
		if err != nil {
			return err
		}
		m, err := transcode.ParseMaster(data)
		if err != nil {
			return err
		}
		path = filepath.Join(dir, "lowest.m3u8")
		if err := j.w.store.Download(ctx, prefix+m.LowestPlaylist(), path, maxPlaylistBytes); err != nil {
			return err
		}
		if data, err = os.ReadFile(path); err != nil { //nolint:gosec // the file just downloaded into the job directory
			return err
		}
		duration, err := transcode.PlaylistDuration(data)
		if err != nil {
			return err
		}
		if duration <= 0 {
			return errors.New("stored rendition playlist has no duration")
		}
		ev = completed(j.up, prefix, m.Attempt, duration, m.Renditions)
		return nil
	})
	if err != nil {
		return nil, err
	}
	j.w.logger.LogAttrs(ctx, slog.LevelInfo, "transcode output exists")
	return ev, nil
}

// step runs fn in a child span of ctx named name. The span carries the video id and nothing
// taken from the file or its paths: a failure gets a fixed description, its error stays in the
// log.
func (j *job) step(ctx context.Context, name string, fn func(context.Context) error) error {
	ctx, span := otel.Tracer(instrumentationName).Start(ctx, name,
		trace.WithAttributes(attribute.String("video_id", j.up.GetVideoId())))
	defer span.End()
	err := fn(ctx)
	if err != nil {
		span.SetStatus(codes.Error, name+" failed")
	}
	return err
}

// permanentReason classifies a transcode error: true when retrying cannot help.
func permanentReason(err error) (mediav1.TranscodeFailureReason, bool) {
	var exitErr *exec.ExitError
	switch {
	case errors.Is(err, transcode.ErrDurationExceeded):
		return mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED, true
	case errors.Is(err, transcode.ErrInvalidInput),
		// ffprobe or ffmpeg ran out of time on this file.
		errors.Is(err, context.DeadlineExceeded),
		// Exited with a status after the probe passed (corrupt data further in), or killed by
		// a signal (a crash on a crafted file, or the memory limit).
		errors.As(err, &exitErr):
		return mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT, true
	}
	// The tool could not start, or the output directory could not be written or read.
	return mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_UNSPECIFIED, false
}

// completed is the transcode.completed of the version under prefix whose master names attempt.
func completed(up *videov1.VideoUploaded, prefix, attempt string, duration time.Duration, rs []transcode.Rendition) *mediav1.TranscodeEvent {
	renditions := make([]*mediav1.Rendition, 0, len(rs))
	for _, r := range rs {
		renditions = append(renditions, &mediav1.Rendition{
			Name:       r.Name,
			Width:      int32(r.Width),   //nolint:gosec // at most 4096, checked by the probe
			Height:     int32(r.Height),  //nolint:gosec // at most 4096, checked by the probe
			BitrateBps: int32(r.Bitrate), //nolint:gosec // ladder constants
		})
	}
	return &mediav1.TranscodeEvent{Event: &mediav1.TranscodeEvent_TranscodeCompleted{
		TranscodeCompleted: &mediav1.TranscodeCompleted{
			VideoId:      up.GetVideoId(),
			PlaylistKey:  prefix + transcode.MasterPlaylist,
			ThumbnailKey: prefix + attempt + "/" + transcode.Thumbnail,
			Duration:     durationpb.New(duration),
			Renditions:   renditions,
		},
	}}
}

func (w *Worker) failed(up *videov1.VideoUploaded, reason mediav1.TranscodeFailureReason, cause error) *mediav1.TranscodeEvent {
	return &mediav1.TranscodeEvent{Event: &mediav1.TranscodeEvent_TranscodeFailed{
		TranscodeFailed: &mediav1.TranscodeFailed{VideoId: up.GetVideoId(), Reason: reason, Detail: w.scrub(cause.Error())},
	}}
}

// scrub turns an error into an operator diagnostic: job paths cut out, bounded, valid UTF-8.
// Errors carry no credential: objstore and the SDK never put one in a message.
func (w *Worker) scrub(s string) string {
	s = strings.ReplaceAll(s, w.workDir+string(filepath.Separator), "")
	if len(s) > maxDetail {
		s = s[:maxDetail]
	}
	return strings.ToValidUTF8(s, "")
}

// publish stamps ev with a new envelope and produces it keyed by videoID. The traceparent of
// the incoming record travels in ctx.
func (w *Worker) publish(ctx context.Context, videoID string, ev *mediav1.TranscodeEvent) error {
	ev.Meta = &eventv1.EventMeta{EventId: ids.New(), OccurredAt: timestamppb.Now()}
	value, err := proto.Marshal(ev)
	if err != nil {
		return fmt.Errorf("marshal TranscodeEvent: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, produceTimeout)
	defer cancel()
	return kafkax.Produce(ctx, w.producer, &kgo.Record{Topic: OutputTopic, Key: []byte(videoID), Value: value})
}

func (j *job) log(ctx context.Context, level slog.Level, msg string, a kafkax.Attempt, extra ...slog.Attr) {
	attrs := append([]slog.Attr{
		slog.Int("attempt", a.Number),
		slog.Duration("download", j.download),
		slog.Duration("transcode", j.transcode),
		slog.Duration("upload", j.upload),
	}, extra...)
	j.w.logger.LogAttrs(ctx, level, msg, attrs...)
}

func outcomeAttrs(ev *mediav1.TranscodeEvent) []slog.Attr {
	if f := ev.GetTranscodeFailed(); f != nil {
		return []slog.Attr{
			slog.String("outcome", "failed"),
			slog.String("reason", f.GetReason().String()),
			slog.String("detail", f.GetDetail()),
		}
	}
	c := ev.GetTranscodeCompleted()
	return []slog.Attr{
		slog.String("outcome", "completed"),
		slog.Duration("duration", c.GetDuration().AsDuration()),
		slog.Int("renditions", len(c.GetRenditions())),
	}
}
