package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	videov1 "github.com/anhnvcoder/svp-backend/gen/go/svp/video/v1"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/objstore"
	"github.com/anhnvcoder/svp-backend/internal/pgpool"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/video-service/migrations"
)

const (
	methodInitUpload     = "/svp.video.v1.VideoService/InitUpload"
	methodGetVideo       = "/svp.video.v1.VideoService/GetVideo"
	methodCompleteUpload = "/svp.video.v1.VideoService/CompleteUpload"
)

// testPool is the migrated database shared by the package's tests; nil when SVP_TEST_POSTGRES_URL
// is unset, and then tests that need it skip.
var (
	testPool  *pgxpool.Pool
	skipNoURL string
)

func TestMain(m *testing.M) {
	pool, cleanup, err := pgtest.Create(context.Background(), "svp_video_server_test", migrations.FS)
	switch {
	case errors.Is(err, pgtest.ErrNoURL):
		skipNoURL = err.Error()
	case err != nil:
		fmt.Fprintln(os.Stderr, "pgtest:", err)
		os.Exit(1)
	default:
		testPool = pool
	}
	code := m.Run()
	if cleanup != nil {
		if err := cleanup(); err != nil {
			fmt.Fprintln(os.Stderr, "pgtest:", err)
			code = 1
		}
	}
	os.Exit(code)
}

func needDB(t *testing.T) {
	t.Helper()
	if testPool == nil {
		t.Skip(skipNoURL)
	}
}

// logBuffer collects JSON log lines.
type logBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *logBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// String returns every log line written so far.
func (b *logBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// records returns the decoded log lines whose msg is msg.
func (b *logBuffer) records(t *testing.T, msg string) []map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for line := range strings.SplitSeq(strings.TrimSpace(b.buf.String()), "\n") {
		if line == "" {
			continue
		}
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line %q is not JSON: %v", line, err)
		}
		if rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

// fakeStorage signs forms for real (signing is local, nothing is sent), answers Head from
// objects and records deletes instead of calling a storage server.
type fakeStorage struct {
	*objstore.Store

	mu      sync.Mutex
	objects map[string]objstore.ObjectInfo
	headErr error
	heads   int
	// deleted lists the keys and prefixes of the deletes that succeeded, in order.
	deleted []string
	// failDeletes is the number of coming Delete or DeletePrefix calls that fail.
	failDeletes int
}

// Signing credentials of the fake; the endpoint is never called.
const (
	fakeAccessKey      = "test-access-key"
	fakePublicEndpoint = "http://127.0.0.1:9000"
)

func newFakeStorage() *fakeStorage {
	st, err := objstore.New(objstore.Config{
		Endpoint:        "http://storage.invalid:9000",
		PublicEndpoint:  fakePublicEndpoint,
		Region:          "us-east-1",
		AccessKeyID:     fakeAccessKey,
		SecretAccessKey: "test-secret-key",
		UploadsBucket:   "uploads",
		MediaBucket:     "media",
	})
	if err != nil {
		panic(err)
	}
	return &fakeStorage{Store: st, objects: map[string]objstore.ObjectInfo{}}
}

func (f *fakeStorage) Head(_ context.Context, key string) (objstore.ObjectInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.heads++
	if f.headErr != nil {
		return objstore.ObjectInfo{}, f.headErr
	}
	obj, ok := f.objects[key]
	if !ok {
		return objstore.ObjectInfo{}, fmt.Errorf("head %s: %w", key, objstore.ErrNotFound)
	}
	return obj, nil
}

func (f *fakeStorage) Delete(_ context.Context, key string) error {
	return f.delete(key)
}

func (f *fakeStorage) DeletePrefix(_ context.Context, prefix string) error {
	return f.delete(prefix)
}

func (f *fakeStorage) delete(key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failDeletes > 0 {
		f.failDeletes--
		return fmt.Errorf("objstore: delete %s: storage unavailable", key)
	}
	f.deleted = append(f.deleted, key)
	return nil
}

// setFailDeletes makes the next n deletes fail.
func (f *fakeStorage) setFailDeletes(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failDeletes = n
}

// deletes returns the keys and prefixes deleted so far.
func (f *fakeStorage) deletes() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.deleted)
}

// put stores what Head reports for uploads/<videoID>.
func (f *fakeStorage) put(videoID string, size int64, contentType string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.objects[objstore.UploadsPrefix+videoID] = objstore.ObjectInfo{Size: size, ContentType: contentType}
}

func (f *fakeStorage) headCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.heads
}

// newServer returns a Server on the test database (nil without one: only validation paths work)
// and the buffer its logs go to.
func newServer() (*Server, *logBuffer) {
	s, _, logs := newServerWithStorage()
	return s, logs
}

// newServerWithStorage is newServer that also returns the server's fake storage.
func newServerWithStorage() (*Server, *fakeStorage, *logBuffer) {
	logs := &logBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	storage := newFakeStorage()
	return New(testPool, storage, logger), storage, logs
}

// call runs handler the way the gRPC server does: through CallerInterceptor, with caller as
// x-user-id metadata (none when caller is "").
func call[Req, Resp any](ctx context.Context, caller, method string, req Req, handler func(context.Context, Req) (Resp, error)) (Resp, error) {
	if caller != "" {
		ctx = metadata.NewIncomingContext(ctx, metadata.Pairs(callerid.MetadataKey, caller))
	}
	resp, err := CallerInterceptor()(ctx, req, &grpc.UnaryServerInfo{FullMethod: method},
		func(ctx context.Context, req any) (any, error) { return handler(ctx, req.(Req)) })
	if err != nil {
		var zero Resp
		return zero, err
	}
	return resp.(Resp), nil
}

func initUpload(t *testing.T, s *Server, caller string, req *videov1.InitUploadRequest) (*videov1.InitUploadResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodInitUpload, req, s.InitUpload)
}

func getVideo(t *testing.T, s *Server, caller, videoID string) (*videov1.GetVideoResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodGetVideo, &videov1.GetVideoRequest{VideoId: videoID}, s.GetVideo)
}

func validRequest() *videov1.InitUploadRequest {
	return &videov1.InitUploadRequest{Title: "My first video", SizeBytes: 1 << 20, ContentType: "video/mp4"}
}

// wantError fails unless err has code and ErrorInfo reason.
func wantError(t *testing.T, err error, code codes.Code, reason string) {
	t.Helper()
	if got := status.Code(err); got != code {
		t.Fatalf("code = %s (err %v), want %s", got, err, code)
	}
	if got := grpcerr.Reason(err); got != reason {
		t.Fatalf("reason = %q, want %q", got, reason)
	}
}

// storedVideo reads back the columns InitUpload writes.
type storedVideo struct {
	authorID, title, status, contentType string
	sizeBytes                            int64
}

func readStored(t *testing.T, videoID string) storedVideo {
	t.Helper()
	var v storedVideo
	err := testPool.QueryRow(t.Context(),
		"SELECT author_id::text, title, status, content_type, size_bytes FROM videos WHERE id = $1", videoID,
	).Scan(&v.authorID, &v.title, &v.status, &v.contentType, &v.sizeBytes)
	if err != nil {
		t.Fatalf("read video %s: %v", videoID, err)
	}
	return v
}

func TestInitUploadCreatesUploadingVideo(t *testing.T) {
	needDB(t)
	testTelemetry(t)
	s, logs := newServer()
	caller := ids.New()
	// As the otelgrpc stats handler of grpcserver leaves the context: the RPC's server span.
	ctx, span := otel.Tracer("test").Start(t.Context(), "InitUpload")
	defer span.End()

	req := &videov1.InitUploadRequest{Title: "  Chuyến đi Đà Lạt  ", SizeBytes: 12345, ContentType: "Video/MP4; codecs=avc1"}
	resp, err := call(ctx, caller, methodInitUpload, req, s.InitUpload)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ids.Parse(resp.GetVideoId()); err != nil {
		t.Fatalf("video_id %q is not a canonical UUID", resp.GetVideoId())
	}

	want := storedVideo{authorID: caller, title: "Chuyến đi Đà Lạt", status: "UPLOADING", contentType: "video/mp4", sizeBytes: 12345}
	if got := readStored(t, resp.GetVideoId()); got != want {
		t.Errorf("stored video = %+v, want %+v", got, want)
	}

	recs := logs.records(t, "video created")
	if len(recs) != 1 {
		t.Fatalf("got %d \"video created\" log lines, want 1", len(recs))
	}
	for key, val := range map[string]string{"user_id": caller, "video_id": resp.GetVideoId(), "trace_id": span.SpanContext().TraceID().String()} {
		if recs[0][key] != val {
			t.Errorf("log %s = %v, want %q", key, recs[0][key], val)
		}
	}
}

// postPolicy is the decoded "policy" form field of a presigned POST.
type postPolicy struct {
	Expiration time.Time `json:"expiration"`
	Conditions []any     `json:"conditions"`
}

func decodePolicy(t *testing.T, field string) postPolicy {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(field)
	if err != nil {
		t.Fatalf("policy is not base64: %v", err)
	}
	var p postPolicy
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatalf("policy is not JSON: %v", err)
	}
	return p
}

// hasCondition reports whether the policy holds want, compared as JSON.
func (p postPolicy) hasCondition(t *testing.T, want any) bool {
	t.Helper()
	w, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range p.Conditions {
		if got, _ := json.Marshal(c); string(got) == string(w) {
			return true
		}
	}
	return false
}

// The form lets the client write exactly uploads/<video_id>, of 1 to size_bytes bytes with the
// normalized content type, for 15 minutes (UP-1); it never reaches the logs (UP-2).
func TestInitUploadReturnsPresignedForm(t *testing.T) {
	needDB(t)
	s, logs := newServer()
	before := time.Now()
	req := &videov1.InitUploadRequest{Title: "Form", SizeBytes: 12345, ContentType: "Video/MP4; codecs=avc1"}
	resp, err := initUpload(t, s, ids.New(), req)
	if err != nil {
		t.Fatal(err)
	}
	after := time.Now()
	key := "uploads/" + resp.GetVideoId()

	if want := fakePublicEndpoint + "/uploads"; resp.GetUploadUrl() != want {
		t.Errorf("upload_url = %q, want %q", resp.GetUploadUrl(), want)
	}
	fields := resp.GetFormFields()
	if fields["key"] != key || fields["Content-Type"] != "video/mp4" {
		t.Errorf("form key = %q, Content-Type = %q, want %q and video/mp4", fields["key"], fields["Content-Type"], key)
	}
	if !strings.Contains(fields["X-Amz-Credential"], fakeAccessKey+"/") || fields["X-Amz-Signature"] == "" {
		t.Errorf("form fields %v lack the signing fields", fields)
	}

	expires := resp.GetExpiresAt().AsTime()
	if expires.Before(before.Add(uploadFormTTL-time.Second)) || expires.After(after.Add(uploadFormTTL+time.Second)) {
		t.Errorf("expires_at = %s, want about %s", expires, before.Add(uploadFormTTL))
	}
	policy := decodePolicy(t, fields["policy"])
	if !policy.Expiration.Equal(expires) {
		t.Errorf("policy expiration %s != expires_at %s", policy.Expiration, expires)
	}
	for _, want := range []any{
		map[string]string{"bucket": "uploads"},
		map[string]string{"key": key},
		map[string]string{"Content-Type": "video/mp4"},
		[]any{"content-length-range", 1, 12345},
	} {
		if !policy.hasCondition(t, want) {
			t.Errorf("policy conditions %v lack %v", policy.Conditions, want)
		}
	}
	for _, c := range policy.Conditions {
		if arr, ok := c.([]any); ok && len(arr) > 0 && arr[0] == "starts-with" {
			t.Errorf("policy has a prefix condition %v; the key must match exactly", c)
		}
	}

	all := logs.String()
	for _, secret := range []string{fields["policy"], fields["X-Amz-Signature"], resp.GetUploadUrl()} {
		if strings.Contains(all, secret) {
			t.Errorf("logs contain the form (%.20q...)", secret)
		}
	}
}

func TestInitUploadIsNotIdempotent(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	caller := ids.New()
	first, err := initUpload(t, s, caller, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	second, err := initUpload(t, s, caller, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	if first.GetVideoId() == second.GetVideoId() {
		t.Errorf("two calls returned the same video_id %s", first.GetVideoId())
	}
}

func TestInitUploadTitle(t *testing.T) {
	accepted := []struct{ name, title, stored string }{
		{"200 multi-byte runes", strings.Repeat("ệ", 200), strings.Repeat("ệ", 200)},
		{"one rune", "a", "a"},
		{"markup kept verbatim", "  <script>alert(1)</script> & \"x\"  ", "<script>alert(1)</script> & \"x\""},
	}
	for _, tc := range accepted {
		t.Run(tc.name, func(t *testing.T) {
			needDB(t)
			s, _ := newServer()
			req := validRequest()
			req.Title = tc.title
			resp, err := initUpload(t, s, ids.New(), req)
			if err != nil {
				t.Fatal(err)
			}
			if got := readStored(t, resp.GetVideoId()).title; got != tc.stored {
				t.Errorf("stored title = %q, want %q", got, tc.stored)
			}
		})
	}

	rejected := []struct{ name, title string }{
		{"empty", ""},
		{"whitespace only", " \t\n  "},
		{"201 multi-byte runes", strings.Repeat("ệ", 201)},
		{"201 runes after trimming", "  " + strings.Repeat("a", 201) + "  "},
		{"broken UTF-8", "abc\xff\xfe"},
		{"truncated multi-byte rune", "Đà Lạt\xe1\xbb"},
		{"NUL byte", "a\x00b"},
	}
	for _, tc := range rejected {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := newServer()
			req := validRequest()
			req.Title = tc.title
			_, err := initUpload(t, s, ids.New(), req)
			wantError(t, err, codes.InvalidArgument, ReasonInvalidTitle)
		})
	}
}

func TestInitUploadSize(t *testing.T) {
	t.Run("exactly 500 MiB", func(t *testing.T) {
		needDB(t)
		s, _ := newServer()
		req := validRequest()
		req.SizeBytes = 524288000
		resp, err := initUpload(t, s, ids.New(), req)
		if err != nil {
			t.Fatal(err)
		}
		if got := readStored(t, resp.GetVideoId()).sizeBytes; got != 524288000 {
			t.Errorf("stored size_bytes = %d, want 524288000", got)
		}
	})

	for _, size := range []int64{0, -1, -524288000, 524288001, 1 << 40} {
		t.Run(fmt.Sprint(size), func(t *testing.T) {
			s, _ := newServer()
			req := validRequest()
			req.SizeBytes = size
			_, err := initUpload(t, s, ids.New(), req)
			wantError(t, err, codes.InvalidArgument, ReasonInvalidSize)
		})
	}
}

func TestInitUploadContentType(t *testing.T) {
	accepted := []struct{ in, stored string }{
		{"video/mp4", "video/mp4"},
		{"video/mp4; codecs=avc1", "video/mp4"},
		{"VIDEO/MP4", "video/mp4"},
		{"video/quicktime", "video/quicktime"},
		{"video/" + strings.Repeat("x", 127), "video/" + strings.Repeat("x", 127)},
	}
	for _, tc := range accepted {
		t.Run(fmt.Sprintf("%.20q", tc.in), func(t *testing.T) {
			needDB(t)
			s, _ := newServer()
			req := validRequest()
			req.ContentType = tc.in
			resp, err := initUpload(t, s, ids.New(), req)
			if err != nil {
				t.Fatal(err)
			}
			if got := readStored(t, resp.GetVideoId()).contentType; got != tc.stored {
				t.Errorf("stored content_type = %q, want %q", got, tc.stored)
			}
		})
	}

	for _, in := range []string{"", "video", "video/", "/mp4", "image/png", "application/octet-stream", "video/mp4; =", "video/mp4;;", "videos/mp4", "video/" + strings.Repeat("x", 128), "video/*", "*/*", "*/mp4", "video/mp*"} {
		t.Run(fmt.Sprintf("%.20q", in), func(t *testing.T) {
			s, _ := newServer()
			req := validRequest()
			req.ContentType = in
			_, err := initUpload(t, s, ids.New(), req)
			wantError(t, err, codes.InvalidArgument, ReasonInvalidContentType)
		})
	}
}

// insertVideo stores a video directly, in a status or with timestamps a test cannot reach quickly
// through the RPCs (READY and FAILED come from transcode events).
func insertVideo(t *testing.T, id, author, videoStatus string, ready bool, publishedAt, createdAt time.Time) {
	t.Helper()
	var durationMs *int64
	var playlist, thumbnail *string
	var published *time.Time
	if ready {
		d, p, th := int64(83_250), "media/"+id+"/master.m3u8", "media/"+id+"/thumb.jpg"
		durationMs, playlist, thumbnail, published = &d, &p, &th, &publishedAt
	}
	_, err := testPool.Exec(t.Context(), `
		INSERT INTO videos (id, author_id, title, status, size_bytes, content_type,
		                    duration_ms, playlist_key, thumbnail_key, published_at, created_at)
		VALUES ($1, $2, 'Inserted', $3, 1000, 'video/mp4', $4, $5, $6, $7, $8)`,
		id, author, videoStatus, durationMs, playlist, thumbnail, published, createdAt)
	if err != nil {
		t.Fatalf("insert video: %v", err)
	}
}

func TestGetVideoReadyIsVisibleToEveryone(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	id, author := ids.New(), ids.New()
	created := time.Date(2026, 10, 11, 8, 0, 0, 123456000, time.UTC)
	published := created.Add(90 * time.Second)
	insertVideo(t, id, author, "READY", true, published, created)

	for _, caller := range []string{ids.New(), author} {
		resp, err := getVideo(t, s, caller, id)
		if err != nil {
			t.Fatalf("GetVideo by %s: %v", caller, err)
		}
		v := resp.GetVideo()
		if v.GetVideoId() != id || v.GetAuthorId() != author || v.GetTitle() != "Inserted" ||
			v.GetStatus() != videov1.VideoStatus_VIDEO_STATUS_READY ||
			v.GetDuration().AsDuration() != 83250*time.Millisecond ||
			v.GetPlaylistKey() != "media/"+id+"/master.m3u8" || v.GetThumbnailKey() != "media/"+id+"/thumb.jpg" ||
			!v.GetCreatedAt().AsTime().Equal(created) || !v.GetPublishedAt().AsTime().Equal(published) {
			t.Errorf("GetVideo by %s = %v", caller, v)
		}
	}
}

func TestGetVideoHiddenLooksLikeMissing(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author, other := ids.New(), ids.New()

	_, missingErr := getVideo(t, s, other, ids.New())
	wantError(t, missingErr, codes.NotFound, ReasonVideoNotFound)
	if msg := status.Convert(missingErr).Message(); msg != "video not found" {
		t.Fatalf("message = %q, want %q", msg, "video not found")
	}

	uploaded, err := initUpload(t, s, author, validRequest())
	if err != nil {
		t.Fatal(err)
	}
	hidden := map[string]string{"UPLOADING": uploaded.GetVideoId()}
	for _, st := range []string{"PROCESSING", "FAILED"} {
		hidden[st] = ids.New()
		insertVideo(t, hidden[st], author, st, false, time.Time{}, time.Now())
	}

	for st, id := range hidden {
		_, err := getVideo(t, s, other, id)
		if status.Code(err) != status.Code(missingErr) || grpcerr.Reason(err) != grpcerr.Reason(missingErr) ||
			status.Convert(err).Message() != status.Convert(missingErr).Message() {
			t.Errorf("GetVideo(%s video of another user) = %v, want the same error as a missing video: %v", st, err, missingErr)
		}
	}
}

func TestGetVideoAuthorSeesEveryStatus(t *testing.T) {
	needDB(t)
	s, _ := newServer()
	author := ids.New()

	uploaded, err := initUpload(t, s, author, &videov1.InitUploadRequest{Title: "Draft", SizeBytes: 42, ContentType: "video/webm"})
	if err != nil {
		t.Fatal(err)
	}
	resp, err := getVideo(t, s, author, uploaded.GetVideoId())
	if err != nil {
		t.Fatal(err)
	}
	v := resp.GetVideo()
	if v.GetStatus() != videov1.VideoStatus_VIDEO_STATUS_UPLOADING || v.GetTitle() != "Draft" || v.GetAuthorId() != author ||
		v.GetCreatedAt() == nil || v.GetDuration() != nil || v.GetPublishedAt() != nil || v.GetPlaylistKey() != "" || v.GetThumbnailKey() != "" {
		t.Errorf("GetVideo(own UPLOADING video) = %v", v)
	}

	for st, want := range map[string]videov1.VideoStatus{
		"PROCESSING": videov1.VideoStatus_VIDEO_STATUS_PROCESSING,
		"FAILED":     videov1.VideoStatus_VIDEO_STATUS_FAILED,
	} {
		id := ids.New()
		insertVideo(t, id, author, st, false, time.Time{}, time.Now())
		resp, err := getVideo(t, s, author, id)
		if err != nil {
			t.Fatalf("GetVideo(own %s video): %v", st, err)
		}
		if got := resp.GetVideo().GetStatus(); got != want {
			t.Errorf("status = %s, want %s", got, want)
		}
	}
}

func TestGetVideoInvalidID(t *testing.T) {
	s, _ := newServer()
	upper := strings.ToUpper(ids.New())
	for _, id := range []string{"", "not-a-uuid", upper, "{" + ids.New() + "}", "urn:uuid:" + ids.New()} {
		_, err := getVideo(t, s, ids.New(), id)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
	}
}

func TestDatabaseErrorIsGenericInternal(t *testing.T) {
	needDB(t)
	// Opened as main opens its pool.
	closed, err := pgpool.New(t.Context(), testPool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	logs := &logBuffer{}
	s := New(closed, newFakeStorage(), slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil))))

	_, initErr := initUpload(t, s, ids.New(), validRequest())
	_, getErr := getVideo(t, s, ids.New(), ids.New())
	_, completeErr := completeUpload(t.Context(), t, s, ids.New(), ids.New())
	_, publicErr := getPublicVideo(t, s, "", ids.New())
	_, listErr := listAuthorVideos(t, s, ids.New(), &videov1.ListAuthorVideosRequest{AuthorId: ids.New()})
	for _, err := range []error{initErr, getErr, completeErr, publicErr, listErr} {
		if status.Code(err) != codes.Internal || status.Convert(err).Message() != "internal error" {
			t.Errorf("error = %v, want INTERNAL with message %q", err, "internal error")
		}
	}
	// The video was never stored, so the log names no video_id an operator would look up in vain.
	if recs := logs.records(t, "insert video"); len(recs) != 1 || recs[0]["error"] == nil || recs[0]["video_id"] != nil {
		t.Errorf("insert failure log = %v, want one line with error and without video_id", recs)
	}
}

// TestOverGRPC runs the service behind a real gRPC server, wired as main wires it.
func TestOverGRPC(t *testing.T) {
	s, _ := newServer()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.ChainUnaryInterceptor(CallerInterceptor()))
	healthpb.RegisterHealthServer(srv, health.NewServer())
	videov1.RegisterVideoServiceServer(srv, s)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	client := videov1.NewVideoServiceClient(conn)

	t.Run("missing caller", func(t *testing.T) {
		ctx := t.Context()
		_, initErr := client.InitUpload(ctx, validRequest())
		_, getErr := client.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: ids.New()})
		_, completeErr := client.CompleteUpload(ctx, &videov1.CompleteUploadRequest{VideoId: ids.New()})
		_, listErr := client.ListAuthorVideos(ctx, &videov1.ListAuthorVideosRequest{AuthorId: ids.New()})
		for name, err := range map[string]error{
			"InitUpload": initErr, "GetVideo": getErr, "CompleteUpload": completeErr, "ListAuthorVideos": listErr,
		} {
			if status.Code(err) != codes.Unauthenticated || grpcerr.Reason(err) != callerid.ReasonUnauthenticatedCaller {
				t.Errorf("%s without x-user-id = %v, want UNAUTHENTICATED", name, err)
			}
		}
	})

	t.Run("health check needs no caller", func(t *testing.T) {
		resp, err := healthpb.NewHealthClient(conn).Check(t.Context(), &healthpb.HealthCheckRequest{})
		if err != nil || resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
			t.Errorf("Health/Check without x-user-id = (%v, %v), want SERVING", resp, err)
		}
	})

	// GetPublicVideo is public: without x-user-id, and with a malformed one, it reaches the handler,
	// which answers NOT_FOUND for a missing video instead of UNAUTHENTICATED.
	t.Run("GetPublicVideo needs no caller", func(t *testing.T) {
		needDB(t)
		_, err := client.GetPublicVideo(t.Context(), &videov1.GetPublicVideoRequest{VideoId: ids.New()})
		wantError(t, err, codes.NotFound, ReasonVideoNotFound)
		ctx := metadata.AppendToOutgoingContext(t.Context(), callerid.MetadataKey, "not-a-uuid")
		_, err = client.GetPublicVideo(ctx, &videov1.GetPublicVideoRequest{VideoId: ids.New()})
		wantError(t, err, codes.NotFound, ReasonVideoNotFound)
	})

	t.Run("CompleteUpload of a missing video", func(t *testing.T) {
		needDB(t)
		ctx := metadata.AppendToOutgoingContext(t.Context(), callerid.MetadataKey, ids.New())
		_, err := client.CompleteUpload(ctx, &videov1.CompleteUploadRequest{VideoId: ids.New()})
		wantError(t, err, codes.NotFound, ReasonVideoNotFound)
	})

	t.Run("InitUpload then GetVideo", func(t *testing.T) {
		needDB(t)
		author := ids.New()
		ctx := metadata.AppendToOutgoingContext(t.Context(), callerid.MetadataKey, author)
		created, err := client.InitUpload(ctx, validRequest())
		if err != nil {
			t.Fatal(err)
		}
		got, err := client.GetVideo(ctx, &videov1.GetVideoRequest{VideoId: created.GetVideoId()})
		if err != nil {
			t.Fatal(err)
		}
		if got.GetVideo().GetVideoId() != created.GetVideoId() || got.GetVideo().GetAuthorId() != author {
			t.Errorf("GetVideo = %v", got.GetVideo())
		}
	})
}
