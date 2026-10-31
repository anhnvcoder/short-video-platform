package worker

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.opentelemetry.io/otel"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/event/v1"
	mediav1 "github.com/anhnvcoder/svp-backend/gen/go/svp/media/v1"
	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/services/media-worker/internal/transcode"
)

// fakeStore keeps objects in memory and follows objstore's error contract, Create's
// If-None-Match: * included.
type fakeStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	types   map[string]string
	caches  map[string]string
	// uploads lists every key written, by Upload or a successful Create, in call order.
	uploads []string
	// existsErr, when set, is what Exists returns.
	existsErr error
	// beforeUpload, when set, runs before each Upload and Create; an error it returns fails the
	// call without writing.
	beforeUpload func(key string) error
	// afterCreate, when set, runs after a successful Create.
	afterCreate func()
	// downloads counts Download calls; maxBytes is the limit of the last one.
	downloads int
	maxBytes  int64
	// failDownloads makes the next n downloads fail with a temporary error; -1 fails them all.
	failDownloads int
	// blockDownloads makes downloads wait until their context ends.
	blockDownloads bool
	// afterDownload, when set, runs after a successful download.
	afterDownload func()
}

func newFakeStore() *fakeStore {
	return &fakeStore{objects: map[string][]byte{}, types: map[string]string{}, caches: map[string]string{}}
}

func (s *fakeStore) put(key string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.objects[key] = data
}

func (s *fakeStore) Download(ctx context.Context, key, path string, maxBytes int64) error {
	s.mu.Lock()
	s.downloads++
	s.maxBytes = maxBytes
	if s.blockDownloads {
		s.mu.Unlock()
		<-ctx.Done()
		return fmt.Errorf("download %s: %w", key, ctx.Err())
	}
	if s.failDownloads != 0 {
		if s.failDownloads > 0 {
			s.failDownloads--
		}
		s.mu.Unlock()
		return errors.New("objstore: download " + key + ": 503 Service Unavailable")
	}
	data, ok := s.objects[key]
	hook := s.afterDownload
	s.mu.Unlock()
	if !ok {
		return fmt.Errorf("download %s: %w", key, objstore.ErrNotFound)
	}
	if int64(len(data)) > maxBytes {
		return fmt.Errorf("download %s: %w", key, objstore.ErrTooLarge)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	if hook != nil {
		hook()
	}
	return nil
}

func (s *fakeStore) Upload(_ context.Context, key, path, contentType, cacheControl string) error {
	return s.write(key, path, contentType, cacheControl, false)
}

func (s *fakeStore) Create(_ context.Context, key, path, contentType, cacheControl string) error {
	if err := s.write(key, path, contentType, cacheControl, true); err != nil {
		return err
	}
	if s.afterCreate != nil {
		s.afterCreate()
	}
	return nil
}

func (s *fakeStore) write(key, path, contentType, cacheControl string, create bool) error {
	if s.beforeUpload != nil {
		if err := s.beforeUpload(key); err != nil {
			return err
		}
	}
	data, err := os.ReadFile(path) //nolint:gosec // a file of the job under test
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, taken := s.objects[key]; create && taken {
		return fmt.Errorf("upload %s: %w", key, objstore.ErrExists)
	}
	s.objects[key] = data
	s.types[key] = contentType
	s.caches[key] = cacheControl
	s.uploads = append(s.uploads, key)
	return nil
}

func (s *fakeStore) Exists(_ context.Context, key string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.existsErr != nil {
		return false, s.existsErr
	}
	_, ok := s.objects[key]
	return ok, nil
}

// get returns the object at key, nil when there is none.
func (s *fakeStore) get(key string) []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.objects[key]
}

func (s *fakeStore) snapshot() (uploads []string, downloads int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.uploads), s.downloads
}

// env is a worker wired to an in-memory Kafka and a fake store.
type env struct {
	brokers string
	client  *kgo.Client // producer for the worker and the tests
	store   *fakeStore
	workDir string
	w       *Worker
}

func newEnv(t *testing.T) *env {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1),
		kfake.SeedTopics(1, InputTopic, InputTopic+kafkax.DLQSuffix, OutputTopic))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	brokers := strings.Join(c.ListenAddrs(), ",")
	cl, err := kafkax.NewClient(brokers, "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cl.Close)
	e := &env{brokers: brokers, client: cl, store: newFakeStore(), workDir: t.TempDir()}
	e.w = New(e.store, cl, e.workDir, slog.New(slog.DiscardHandler))
	return e
}

func requireFFmpeg(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not in PATH (install ffmpeg to run this test): %v", tool, err)
		}
	}
}

// generate writes a synthetic clip from ffmpeg's lavfi sources and returns its bytes.
func generate(t *testing.T, name string, args ...string) []byte {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	full := append([]string{"-hide_banner", "-nostdin", "-loglevel", "error", "-y"}, args...)
	full = append(full, path)
	if out, err := exec.CommandContext(t.Context(), "ffmpeg", full...).CombinedOutput(); err != nil { //nolint:gosec // test fixture command
		t.Fatalf("generate %s: %v\n%s", name, err, out)
	}
	data, err := os.ReadFile(path) //nolint:gosec // the fixture just written
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func clip(t *testing.T, size string, seconds int) []byte {
	t.Helper()
	return generate(t, "in.mp4",
		"-f", "lavfi", "-i", fmt.Sprintf("testsrc2=size=%s:rate=30:duration=%d", size, seconds),
		"-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=440:duration=%d", seconds),
		"-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest")
}

// uploaded returns a valid video.uploaded record for id announcing size bytes; edit changes the
// event before it is encoded.
func uploaded(t *testing.T, id string, size int, edit func(*videov1.VideoEvent, *videov1.VideoUploaded)) *kgo.Record {
	t.Helper()
	up := &videov1.VideoUploaded{
		VideoId:     id,
		AuthorId:    ids.New(),
		SourceKey:   objstore.UploadsPrefix + id,
		ContentType: "video/mp4",
		SizeBytes:   int64(size),
	}
	ev := &videov1.VideoEvent{
		Meta:  &eventv1.EventMeta{EventId: ids.New(), OccurredAt: timestamppb.Now()},
		Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: up},
	}
	if edit != nil {
		edit(ev, up)
	}
	return record(t, id, ev)
}

func record(t *testing.T, key string, ev proto.Message) *kgo.Record {
	t.Helper()
	value, err := proto.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	return &kgo.Record{Topic: InputTopic, Key: []byte(key), Value: value}
}

// withSource stores data as the source of a new video and returns its record.
func (e *env) withSource(t *testing.T, data []byte) (string, *kgo.Record) {
	t.Helper()
	id := ids.New()
	e.store.put(objstore.UploadsPrefix+id, data)
	return id, uploaded(t, id, len(data), nil)
}

func (e *env) handle(t *testing.T, r *kgo.Record) {
	t.Helper()
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err != nil {
		t.Fatalf("Handle: %v", err)
	}
}

// read returns the first n records of topic, failing when fewer arrive within 15 s.
func (e *env) read(t *testing.T, topic string, n int) []*kgo.Record {
	t.Helper()
	cl, err := kafkax.NewClient(e.brokers, "test-reader", kgo.ConsumeTopics(topic), kgo.FetchMaxWait(100*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(out) < n && ctx.Err() == nil {
		out = append(out, cl.PollFetches(ctx).Records()...)
	}
	if len(out) < n {
		t.Fatalf("%s: got %d records, want %d", topic, len(out), n)
	}
	return out[:n]
}

// count returns how many records topic holds: it appends a marker and reads up to it.
func (e *env) count(t *testing.T, topic string) int {
	t.Helper()
	marker := &kgo.Record{Topic: topic, Key: []byte("marker")}
	if err := kafkax.Produce(t.Context(), e.client, marker); err != nil {
		t.Fatal(err)
	}
	n := int(marker.Offset)
	e.read(t, topic, n+1)
	return n
}

func decodeOut(t *testing.T, r *kgo.Record) *mediav1.TranscodeEvent {
	t.Helper()
	var ev mediav1.TranscodeEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		t.Fatal(err)
	}
	if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil {
		t.Errorf("meta.event_id %q: %v", ev.GetMeta().GetEventId(), err)
	}
	if at := ev.GetMeta().GetOccurredAt().AsTime(); time.Since(at) > time.Minute || time.Until(at) > time.Second {
		t.Errorf("meta.occurred_at = %v, want now", at)
	}
	return &ev
}

// failure handles r and returns the transcode.failed it publishes.
func (e *env) failure(t *testing.T, r *kgo.Record) *mediav1.TranscodeFailed {
	t.Helper()
	e.handle(t, r)
	out := e.read(t, OutputTopic, 1)[0]
	f := decodeOut(t, out).GetTranscodeFailed()
	if f == nil {
		t.Fatal("published event is not transcode.failed")
	}
	if string(out.Key) != f.GetVideoId() {
		t.Errorf("record key %q, video_id %q", out.Key, f.GetVideoId())
	}
	return f
}

func (e *env) requireCleanWorkDir(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(e.workDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("work directory not cleaned: %v", entries)
	}
}

// versionOf returns the version a record's output goes under: its event_id.
func versionOf(t *testing.T, r *kgo.Record) string {
	t.Helper()
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		t.Fatal(err)
	}
	return ev.GetMeta().GetEventId()
}

// attemptOf returns the attempt directory the stored master of prefix names.
func (e *env) attemptOf(t *testing.T, prefix string) string {
	t.Helper()
	m, err := transcode.ParseMaster(e.store.get(prefix + transcode.MasterPlaylist))
	if err != nil {
		t.Fatalf("stored master: %v", err)
	}
	return m.Attempt
}

// completedOf decodes a transcode.completed for id, without its envelope.
func completedOf(t *testing.T, r *kgo.Record, id string) *mediav1.TranscodeCompleted {
	t.Helper()
	if string(r.Key) != id {
		t.Errorf("record key %q, want %s", r.Key, id)
	}
	c := decodeOut(t, r).GetTranscodeCompleted()
	if c == nil {
		t.Fatal("event is not transcode.completed")
	}
	return c
}

func renditionsOf(c *mediav1.TranscodeCompleted) []string {
	var names []string
	for _, rd := range c.GetRenditions() {
		names = append(names, fmt.Sprintf("%s %dx%d %d", rd.GetName(), rd.GetWidth(), rd.GetHeight(), rd.GetBitrateBps()))
	}
	return names
}

// checkCompleted checks c is the result of the 2 s 1280x720 clip under prefix, its master naming
// attempt.
func checkCompleted(t *testing.T, c *mediav1.TranscodeCompleted, id, prefix, attempt string) {
	t.Helper()
	if c.GetVideoId() != id || c.GetPlaylistKey() != prefix+"master.m3u8" || c.GetThumbnailKey() != prefix+attempt+"/thumbnail.jpg" {
		t.Errorf("completed = %v, want keys %smaster.m3u8 and %s%s/thumbnail.jpg", c, prefix, prefix, attempt)
	}
	for _, key := range []string{c.GetPlaylistKey(), c.GetThumbnailKey()} {
		if !objstore.IsMediaKey(key, id) {
			t.Errorf("%s is not a media key of %s", key, id)
		}
	}
	if d := c.GetDuration().AsDuration(); d < 1900*time.Millisecond || d > 2100*time.Millisecond {
		t.Errorf("duration = %v, want about 2 s", d)
	}
	if got, want := renditionsOf(c), []string{"360p 640x360 800000", "720p 1280x720 2500000"}; !slices.Equal(got, want) {
		t.Errorf("renditions = %v, want %v", got, want)
	}
}

// The first delivery writes the version: every object of the try under its attempt directory,
// segments first, the master last at the version's root, all of them immutable. A redelivery
// finds the master, downloads no source and writes nothing, and publishes the same result read
// back from the stored playlists.
func TestHandleValidUploadTwiceGivesSameResult(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "1280x720", 2))
	prefix := "media/" + id + "/" + versionOf(t, r) + "/"

	e.handle(t, r)
	first, downloads := e.store.snapshot()
	if downloads != 1 {
		t.Errorf("downloads = %d, want the source only", downloads)
	}
	if len(first) == 0 || first[len(first)-1] != prefix+transcode.MasterPlaylist {
		t.Fatalf("uploads %v: want %smaster.m3u8 last", first, prefix)
	}
	attempt := e.attemptOf(t, prefix)
	lastSegment, firstPlaylist := -1, len(first)
	for i, k := range first[:len(first)-1] {
		if !strings.HasPrefix(k, prefix+attempt+"/") {
			t.Errorf("upload key %s outside %s%s/", k, prefix, attempt)
		}
		if strings.HasSuffix(k, ".ts") {
			lastSegment = i
		}
		if strings.HasSuffix(k, "/index.m3u8") {
			firstPlaylist = min(firstPlaylist, i)
		}
	}
	if lastSegment < 0 || lastSegment > firstPlaylist {
		t.Errorf("uploads %v: want every segment before the rendition playlists", first)
	}
	if !slices.Contains(first, prefix+attempt+"/"+transcode.Thumbnail) {
		t.Errorf("uploads %v: no thumbnail", first)
	}
	for _, k := range first {
		if c := e.store.caches[k]; c != "max-age=31536000, immutable" {
			t.Errorf("%s Cache-Control %q", k, c)
		}
	}
	if typ := e.store.types[prefix+transcode.MasterPlaylist]; typ != "application/vnd.apple.mpegurl" {
		t.Errorf("master content type %q", typ)
	}
	if !strings.Contains(string(e.store.get(prefix+transcode.MasterPlaylist)), "\n"+attempt+"/360p/index.m3u8") {
		t.Errorf("master does not name %s/360p/index.m3u8:\n%s", attempt, e.store.get(prefix+transcode.MasterPlaylist))
	}

	e.handle(t, r)
	all, downloads := e.store.snapshot()
	if len(all) != len(first) {
		t.Errorf("redelivery wrote %v", all[len(first):])
	}
	// The master and the lowest rendition's playlist, no source.
	if downloads != 3 {
		t.Errorf("downloads = %d, want 3", downloads)
	}

	outs := e.read(t, OutputTopic, 2)
	c1, c2 := completedOf(t, outs[0], id), completedOf(t, outs[1], id)
	checkCompleted(t, c1, id, prefix, attempt)
	if !proto.Equal(c1, c2) {
		t.Errorf("redelivery gave another result:\n%v\n%v", c1, c2)
	}
	e.requireCleanWorkDir(t)
}

// A try that dies before the master leaves objects no playlist names; the next try transcodes
// again into a directory of its own and the master names that one.
func TestHandleRetryBeforeMasterUsesNewDirectory(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "1280x720", 2))
	prefix := "media/" + id + "/" + versionOf(t, r) + "/"
	var calls int
	e.store.beforeUpload = func(string) error {
		if calls++; calls == 3 {
			return errors.New("objstore: upload: 503 Service Unavailable")
		}
		return nil
	}
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err == nil {
		t.Fatal("Handle succeeded with a failed upload")
	}
	partial, _ := e.store.snapshot()
	if len(partial) != 2 || e.store.get(prefix+transcode.MasterPlaylist) != nil {
		t.Fatalf("after the failed try: uploads %v, want 2 and no master", partial)
	}

	e.handle(t, r)
	all, downloads := e.store.snapshot()
	if downloads != 2 {
		t.Errorf("downloads = %d, want the source twice", downloads)
	}
	attempt := e.attemptOf(t, prefix)
	for _, k := range partial {
		if strings.HasPrefix(k, prefix+attempt+"/") {
			t.Errorf("the master names %s, the directory of the failed try (%s)", attempt, k)
		}
	}
	for _, k := range all[len(partial):] {
		if k != prefix+transcode.MasterPlaylist && !strings.HasPrefix(k, prefix+attempt+"/") {
			t.Errorf("second try wrote %s outside its directory %s", k, attempt)
		}
	}
	checkCompleted(t, completedOf(t, e.read(t, OutputTopic, 1)[0], id), id, prefix, attempt)
	if n := e.count(t, OutputTopic); n != 1 {
		t.Errorf("%d events published, want 1", n)
	}
}

// A try that dies after creating the master but before publishing: the redelivery publishes
// the result from the stored playlists, writing and transcoding nothing.
func TestHandleRedeliveryAfterMasterPublishesStoredResult(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "1280x720", 2))
	prefix := "media/" + id + "/" + versionOf(t, r) + "/"
	ctx, cancel := context.WithCancel(t.Context())
	e.store.afterCreate = cancel
	if err := e.w.Handle(ctx, r, kafkax.Attempt{Number: 1}); err == nil {
		t.Fatal("Handle succeeded although it stopped before publishing")
	}
	if n := e.count(t, OutputTopic); n != 0 {
		t.Fatalf("%d events published before the redelivery", n)
	}
	stored, downloads := e.store.snapshot()
	attempt := e.attemptOf(t, prefix)

	e.handle(t, r)
	all, after := e.store.snapshot()
	if len(all) != len(stored) {
		t.Errorf("redelivery wrote %v", all[len(stored):])
	}
	if after-downloads != 2 {
		t.Errorf("redelivery downloaded %d objects, want the master and one playlist", after-downloads)
	}
	// The marker of the count above, then the only result.
	outs := e.read(t, OutputTopic, 2)
	if string(outs[0].Key) != "marker" {
		t.Fatalf("first record has key %q, want the marker", outs[0].Key)
	}
	checkCompleted(t, completedOf(t, outs[1], id), id, prefix, attempt)
	e.requireCleanWorkDir(t)
}

// Two tries of one event at once, as when a member that lost its session keeps its handler
// going: A stops before its first upload, B runs to the end, then A goes on. B's master is the
// only one, nothing under B's directory is written after it, and A publishes B's result.
func TestHandleConcurrentTriesPublishOneVersion(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "1280x720", 2))
	prefix := "media/" + id + "/" + versionOf(t, r) + "/"
	blocked, release := make(chan struct{}), make(chan struct{})
	// Only the first upload, A's, waits; B's go through while A waits.
	var first atomic.Bool
	e.store.beforeUpload = func(string) error {
		if first.CompareAndSwap(false, true) {
			close(blocked)
			<-release
		}
		return nil
	}
	other := New(e.store, e.client, t.TempDir(), slog.New(slog.DiscardHandler))
	errA := make(chan error, 1)
	go func() { errA <- e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}) }()
	<-blocked
	if err := other.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err != nil {
		t.Fatalf("try B: %v", err)
	}
	afterB, _ := e.store.snapshot()
	attemptB := e.attemptOf(t, prefix)
	master := e.store.get(prefix + transcode.MasterPlaylist)
	close(release)
	if err := <-errA; err != nil {
		t.Fatalf("try A: %v", err)
	}

	all, _ := e.store.snapshot()
	var attemptA string
	for _, k := range all[len(afterB):] {
		rest, ok := strings.CutPrefix(k, prefix)
		dir, _, _ := strings.Cut(rest, "/")
		switch {
		case !ok || dir == attemptB || rest == transcode.MasterPlaylist:
			t.Errorf("try A wrote %s after B's master", k)
		case attemptA == "":
			attemptA = dir
		case dir != attemptA:
			t.Errorf("try A wrote under two directories: %s, %s", attemptA, dir)
		}
	}
	if attemptA == "" {
		t.Error("try A uploaded nothing")
	}
	if got := e.store.get(prefix + transcode.MasterPlaylist); !slices.Equal(got, master) {
		t.Errorf("master changed after B created it")
	}
	outs := e.read(t, OutputTopic, 2)
	cB, cA := completedOf(t, outs[0], id), completedOf(t, outs[1], id)
	checkCompleted(t, cB, id, prefix, attemptB)
	if !proto.Equal(cA, cB) {
		t.Errorf("try A published another result:\n%v\n%v", cA, cB)
	}
}

// A master the worker cannot read back is never replaced: the try fails as temporary and
// writes nothing.
func TestHandleUnreadableStoredMasterIsTemporary(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	id := ids.New()
	version := ids.New()
	e.store.put(objstore.UploadsPrefix+id, []byte("never read"))
	e.store.put("media/"+id+"/"+version+"/master.m3u8", []byte("#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=640x360\n360p/index.m3u8\n"))
	r := uploaded(t, id, 10, func(ev *videov1.VideoEvent, _ *videov1.VideoUploaded) { ev.Meta.EventId = version })
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err == nil {
		t.Fatal("Handle succeeded with a master it cannot parse")
	}
	uploads, downloads := e.store.snapshot()
	if len(uploads) != 0 || downloads != 1 {
		t.Errorf("uploads %v, downloads %d; want none and the master only", uploads, downloads)
	}
	if n := e.count(t, OutputTopic); n != 0 {
		t.Errorf("%d events published", n)
	}
}

// A refused check of the master is an error, never "not there": nothing is downloaded or
// written.
func TestHandleExistsErrorIsTemporary(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.store.existsErr = fmt.Errorf("list: %w", objstore.ErrAccessDenied)
	_, r := e.withSource(t, []byte("never read"))
	if err := e.w.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); !errors.Is(err, objstore.ErrAccessDenied) {
		t.Fatalf("Handle = %v, want the temporary ErrAccessDenied", err)
	}
	if uploads, downloads := e.store.snapshot(); len(uploads) != 0 || downloads != 0 {
		t.Errorf("uploads %v, downloads %d; want none", uploads, downloads)
	}
}

func TestHandleSourceMissing(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	id := ids.New()
	f := e.failure(t, uploaded(t, id, 1000, nil))
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_SOURCE_MISSING || f.GetVideoId() != id {
		t.Errorf("failed = %v, want SOURCE_MISSING for %s", f, id)
	}
	e.requireCleanWorkDir(t)
}

func TestHandleNotAVideo(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	_, r := e.withSource(t, []byte("hello, this is not a video\n"))
	f := e.failure(t, r)
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT {
		t.Errorf("reason = %v, want INVALID_INPUT", f.GetReason())
	}
	if strings.Contains(f.GetDetail(), e.workDir) {
		t.Errorf("detail %q carries the work directory", f.GetDetail())
	}
	if uploads, _ := e.store.snapshot(); len(uploads) != 0 {
		t.Errorf("uploads = %v, want none", uploads)
	}
	e.requireCleanWorkDir(t)
}

func TestHandleDurationExceeded(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	_, r := e.withSource(t, generate(t, "long.mp4",
		"-f", "lavfi", "-i", "color=c=black:size=64x64:rate=1:duration=182", "-c:v", "libx264", "-preset", "ultrafast"))
	if f := e.failure(t, r); f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED {
		t.Errorf("failed = %v, want DURATION_EXCEEDED", f)
	}
	e.requireCleanWorkDir(t)
}

func TestHandleObjectLargerThanAnnounced(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	id := ids.New()
	// The object was replaced after CompleteUpload checked a 10-byte file (UP-2).
	e.store.put(objstore.UploadsPrefix+id, make([]byte, 11))
	f := e.failure(t, uploaded(t, id, 10, nil))
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT {
		t.Errorf("failed = %v, want INVALID_INPUT", f)
	}
	if e.store.maxBytes != 10 {
		t.Errorf("download limit = %d, want the announced 10", e.store.maxBytes)
	}
	e.requireCleanWorkDir(t)
}

func TestHandleCapsDownloadAt500MiB(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.failure(t, uploaded(t, ids.New(), 2<<30, nil))
	if e.store.maxBytes != 500<<20 {
		t.Errorf("download limit = %d, want %d", e.store.maxBytes, 500<<20)
	}
}

// A crafted file that crashes ffprobe must not be retried: each retry would run it again.
func TestHandleProbeKilledBySignalIsPermanent(t *testing.T) {
	requireFFmpeg(t)
	e := newEnv(t)
	_, r := e.withSource(t, []byte("crafted"))
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "ffprobe"), []byte("#!/bin/sh\nkill -SEGV $$\n"), 0o700); err != nil { //nolint:gosec // test stand-in for ffprobe
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)

	f := e.failure(t, r) // attempt 1 of many: a temporary error would come back as an error
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT {
		t.Errorf("failed = %v, want INVALID_INPUT", f)
	}
	if !strings.Contains(f.GetDetail(), "signal") {
		t.Errorf("detail %q does not name the signal", f.GetDetail())
	}
}

func TestPermanentReason(t *testing.T) {
	t.Parallel()
	signaled := exec.CommandContext(t.Context(), "sh", "-c", "kill -SEGV $$").Run()
	exited := exec.CommandContext(t.Context(), "sh", "-c", "exit 1").Run()
	_, notFound := exec.LookPath("no-such-tool-svp")
	invalid := mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_INVALID_INPUT
	for _, tc := range []struct {
		name      string
		err       error
		want      mediav1.TranscodeFailureReason
		permanent bool
	}{
		{"invalid input", fmt.Errorf("%w: not on whitelist", transcode.ErrInvalidInput), invalid, true},
		{"duration", fmt.Errorf("%w: 182 s", transcode.ErrDurationExceeded),
			mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_DURATION_EXCEEDED, true},
		{"timeout", fmt.Errorf("transcode: ffmpeg: %w", context.DeadlineExceeded), invalid, true},
		{"killed by signal", fmt.Errorf("transcode: ffmpeg: %w", signaled), invalid, true},
		{"exit status", fmt.Errorf("transcode: ffmpeg: %w", exited), invalid, true},
		{"tool missing", fmt.Errorf("transcode: ffmpeg: %w", notFound), 0, false},
		{"disk", fmt.Errorf("transcode: %w", io.ErrShortWrite), 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := permanentReason(tc.err)
			if ok != tc.permanent || (ok && got != tc.want) {
				t.Errorf("permanentReason(%v) = %v, %v; want %v, %v", tc.err, got, ok, tc.want, tc.permanent)
			}
		})
	}
}

func TestHandleCancelDuringFFmpeg(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	id, r := e.withSource(t, clip(t, "1920x1080", 10))
	jobDir := filepath.Join(e.workDir, id)
	ffmpegRuns := "^ffmpeg .*" + regexp.QuoteMeta(jobDir)

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	seen := make(chan struct{})
	e.store.afterDownload = func() {
		go func() {
			defer cancel()
			for range 500 {
				if exec.CommandContext(t.Context(), "pgrep", "-f", ffmpegRuns).Run() == nil { //nolint:gosec // a temporary directory path
					close(seen)
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
		}()
	}

	err := e.w.Handle(ctx, r, kafkax.Attempt{Number: 1, Last: true})
	if err == nil {
		t.Fatal("Handle returned nil after cancel")
	}
	select {
	case <-seen:
	default:
		t.Fatal("ffmpeg was never seen running")
	}
	if n := e.count(t, OutputTopic); n != 0 {
		t.Errorf("%d events published after cancel", n)
	}
	if _, err := os.Stat(jobDir); !os.IsNotExist(err) {
		t.Errorf("job directory still there: %v", err)
	}
	if ps, err := exec.CommandContext(t.Context(), "pgrep", "-fl", ffmpegRuns).Output(); err == nil { //nolint:gosec // a temporary directory path
		t.Errorf("ffmpeg still running:\n%s", ps)
	}
}

func TestHandleTryTimeoutIsTemporary(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.w.tryTimeout = 50 * time.Millisecond
	e.store.blockDownloads = true
	id, r := e.withSource(t, []byte("never read"))
	// Without the try timeout, a blocked download would end only here, canceled.
	ctx, cancel := context.WithCancel(t.Context())
	defer time.AfterFunc(10*time.Second, cancel).Stop()

	err := e.w.Handle(ctx, r, kafkax.Attempt{Number: 1})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Handle = %v, want a temporary deadline error", err)
	}

	if err := e.w.Handle(ctx, r, kafkax.Attempt{Number: maxAttempts, Last: true}); err != nil {
		t.Fatalf("last try: %v", err)
	}
	f := decodeOut(t, e.read(t, OutputTopic, 1)[0]).GetTranscodeFailed()
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED || f.GetVideoId() != id {
		t.Errorf("event = %v, want RETRIES_EXHAUSTED for %s", f, id)
	}
	if n := e.count(t, OutputTopic); n != 1 {
		t.Errorf("%d events published, want only the last try's", n)
	}
	e.requireCleanWorkDir(t)
}

func TestRebalanceTimeoutCoversRetryBudget(t *testing.T) {
	t.Parallel()
	var backoffs time.Duration
	for n := 1; n < maxAttempts; n++ {
		backoffs += min(backoffBase<<(n-1), backoffMax)
	}
	if budget := maxAttempts*(tryTimeout+produceTimeout) + backoffs; rebalanceTimeout < budget {
		t.Errorf("rebalanceTimeout = %v, retry budget = %v", rebalanceTimeout, budget)
	}
	if cfg := New(nil, nil, "", nil).ConsumerConfig(""); cfg.RebalanceTimeout != rebalanceTimeout || !cfg.BlockRebalance {
		t.Errorf("consumer config = %+v", cfg)
	}
}

func TestCleanWorkDirRemovesOnlyJobDirectories(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	job := filepath.Join(e.workDir, ids.New())
	if err := os.MkdirAll(filepath.Join(job, "out"), 0o750); err != nil {
		t.Fatal(err)
	}
	// Not job directories: a directory with another name, a file, a file named like a job.
	idFile := ids.New()
	if err := os.Mkdir(filepath.Join(e.workDir, "notes"), 0o750); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"stray", idFile} {
		if err := os.WriteFile(filepath.Join(e.workDir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.w.CleanWorkDir(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(job); !os.IsNotExist(err) {
		t.Errorf("job directory still there: %v", err)
	}
	entries, err := os.ReadDir(e.workDir)
	if err != nil {
		t.Fatal(err)
	}
	var left []string
	for _, en := range entries {
		left = append(left, en.Name())
	}
	want := []string{"notes", "stray", idFile}
	slices.Sort(want)
	if !slices.Equal(left, want) {
		t.Errorf("left %v, want %v", left, want)
	}
}

// startConsumer runs the worker's consumer with millisecond backoff until the test ends.
func (e *env) startConsumer(t *testing.T) {
	t.Helper()
	cfg := e.w.ConsumerConfig(e.brokers)
	cfg.BackoffBase, cfg.BackoffMax = time.Millisecond, 5*time.Millisecond
	c, err := kafkax.NewConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	t.Cleanup(func() {
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

func (e *env) produce(t *testing.T, rs ...*kgo.Record) {
	t.Helper()
	if err := kafkax.Produce(t.Context(), e.client, rs...); err != nil {
		t.Fatal(err)
	}
}

func TestConsumerRetriesStorageThenCompletes(t *testing.T) {
	t.Parallel()
	requireFFmpeg(t)
	e := newEnv(t)
	e.store.failDownloads = 2
	id, r := e.withSource(t, clip(t, "640x360", 2))
	// Produced in a trace, as the relay of video-service sends it. Each run starts a trace of its
	// own, so a run with -count=N does not count the spans of an earlier one.
	ctx, parent := otel.Tracer("test").Start(t.Context(), "send "+InputTopic)
	parent.End()
	r.Context = ctx
	e.startConsumer(t)
	e.produce(t, r)

	out := e.read(t, OutputTopic, 1)[0]
	if c := decodeOut(t, out).GetTranscodeCompleted(); c.GetVideoId() != id {
		t.Errorf("event = %v, want transcode.completed for %s", c, id)
	}
	want := parent.SpanContext().TraceID()
	if got := traceIDOf(t, headerValue(out, "traceparent")); got != want {
		t.Errorf("result is in trace %s, want the record's trace %s", got, want)
	}
	// Every try, the two failed downloads included, traced its steps in the record's trace.
	var downloads int
	for _, s := range spansOf(want) {
		if s.Name() == "download source" {
			downloads++
		}
	}
	if downloads != 3 {
		t.Errorf("%d download spans in the record's trace, want 3", downloads)
	}
	if _, downloads := e.store.snapshot(); downloads != 3 {
		t.Errorf("downloads = %d, want 3", downloads)
	}
	if n := e.count(t, InputTopic+kafkax.DLQSuffix); n != 0 {
		t.Errorf("%d records in the dead-letter topic", n)
	}
}

func TestConsumerRetriesExhaustedPublishesOneFailure(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.store.failDownloads = -1
	id, r := e.withSource(t, []byte("never read"))
	e.startConsumer(t)
	e.produce(t, r)

	f := decodeOut(t, e.read(t, OutputTopic, 1)[0]).GetTranscodeFailed()
	if f.GetReason() != mediav1.TranscodeFailureReason_TRANSCODE_FAILURE_REASON_RETRIES_EXHAUSTED || f.GetVideoId() != id {
		t.Errorf("event = %v, want RETRIES_EXHAUSTED for %s", f, id)
	}
	if !strings.Contains(f.GetDetail(), "503") {
		t.Errorf("detail %q does not carry the last error", f.GetDetail())
	}
	if _, downloads := e.store.snapshot(); downloads != maxAttempts {
		t.Errorf("downloads = %d, want %d", downloads, maxAttempts)
	}
	if n := e.count(t, OutputTopic); n != 1 {
		t.Errorf("%d events published, want 1", n)
	}
	if n := e.count(t, InputTopic+kafkax.DLQSuffix); n != 0 {
		t.Errorf("%d records in the dead-letter topic", n)
	}
	e.requireCleanWorkDir(t)
}

func TestConsumerSendsBadEventsToDLQAndSkipsOthers(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	id := ids.New()
	bad := map[string]*kgo.Record{
		"garbage value": {Topic: InputTopic, Key: []byte(id), Value: []byte{0xff, 0xff, 0xff}},
		"no meta":       uploaded(t, id, 10, func(ev *videov1.VideoEvent, _ *videov1.VideoUploaded) { ev.Meta = nil }),
		"key differs": func() *kgo.Record {
			r := uploaded(t, id, 10, nil)
			r.Key = []byte(ids.New())
			return r
		}(),
		"uppercase id": record(t, strings.ToUpper(id), func() *videov1.VideoEvent {
			up := &videov1.VideoUploaded{VideoId: strings.ToUpper(id), SourceKey: "uploads/" + strings.ToUpper(id), SizeBytes: 10}
			return &videov1.VideoEvent{Meta: &eventv1.EventMeta{EventId: ids.New()}, Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: up}}
		}()),
		"traversal source": uploaded(t, id, 10, func(_ *videov1.VideoEvent, up *videov1.VideoUploaded) {
			up.SourceKey = "uploads/../x"
		}),
		"media source": uploaded(t, id, 10, func(_ *videov1.VideoEvent, up *videov1.VideoUploaded) {
			up.SourceKey = "media/" + id
		}),
		"zero size": uploaded(t, id, 0, nil),
		"no event_id": uploaded(t, id, 10, func(ev *videov1.VideoEvent, _ *videov1.VideoUploaded) {
			ev.Meta.EventId = ""
		}),
		"event_id not canonical": uploaded(t, id, 10, func(ev *videov1.VideoEvent, _ *videov1.VideoUploaded) {
			ev.Meta.EventId = strings.ToUpper(ids.New())
		}),
		"event_id a path": uploaded(t, id, 10, func(ev *videov1.VideoEvent, _ *videov1.VideoUploaded) {
			ev.Meta.EventId = "../" + id
		}),
	}
	for name, r := range bad {
		r.Headers = append(r.Headers, kgo.RecordHeader{Key: "case", Value: []byte(name)})
		e.produce(t, r)
	}
	ready := record(t, id, &videov1.VideoEvent{
		Meta:  &eventv1.EventMeta{EventId: ids.New()},
		Event: &videov1.VideoEvent_VideoReady{VideoReady: &videov1.VideoReady{VideoId: id}},
	})
	// Last, a valid event with no source: its transcode.failed shows everything before it is settled.
	last := ids.New()
	e.produce(t, ready, uploaded(t, last, 10, nil))
	e.startConsumer(t)

	if f := decodeOut(t, e.read(t, OutputTopic, 1)[0]).GetTranscodeFailed(); f.GetVideoId() != last {
		t.Fatalf("first event = %v, want the failure of %s", f, last)
	}
	dlq := e.read(t, InputTopic+kafkax.DLQSuffix, len(bad))
	var cases []string
	for _, r := range dlq {
		if got := headerValue(r, kafkax.HeaderDLQReason); got != kafkax.ReasonPermanent {
			t.Errorf("%s: dlq-reason = %q", headerValue(r, "case"), got)
		}
		cases = append(cases, headerValue(r, "case"))
	}
	if n := e.count(t, InputTopic+kafkax.DLQSuffix); n != len(bad) {
		t.Errorf("dead-letter topic holds %d records, want %d: %v", n, len(bad), cases)
	}
	if _, downloads := e.store.snapshot(); downloads != 1 {
		t.Errorf("downloads = %d, want 1 (the last event only)", downloads)
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
