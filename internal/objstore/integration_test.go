package objstore

import (
	"bytes"
	"context"
	"errors"
	"io"
	"maps"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

// The integration tests run against the MinIO of `make up`, through `make test-stack`, as the
// two service users created by minio-init, so they run under the same per-service policies as the
// services. A test skips when the variable it needs is unset, which keeps `make check` working
// without the stack (ADR-0008 sections 6 and 11).
const (
	envS3Endpoint     = "SVP_TEST_S3_ENDPOINT"
	envVideoAccessKey = "SVP_TEST_S3_VIDEO_ACCESS_KEY"
	envVideoSecretKey = "SVP_TEST_S3_VIDEO_SECRET_KEY" //nolint:gosec // a variable name, not a secret
	envWorkerAccess   = "SVP_TEST_S3_WORKER_ACCESS_KEY"
	envWorkerSecret   = "SVP_TEST_S3_WORKER_SECRET_KEY" //nolint:gosec // a variable name, not a secret
)

// requireEnv skips the test unless every variable in names is set, and returns their values.
func requireEnv(t *testing.T, names ...string) []string {
	t.Helper()
	values := make([]string, len(names))
	for i, n := range names {
		if values[i] = os.Getenv(n); values[i] == "" {
			t.Skipf("%s is not set; run make up, then make test-stack", n)
		}
	}
	return values
}

func stackConfig(endpoint, accessKey, secretKey string) Config {
	return Config{
		Endpoint:        endpoint,
		Region:          "us-east-1",
		AccessKeyID:     accessKey,
		SecretAccessKey: secretKey,
		UploadsBucket:   "uploads",
		MediaBucket:     "media",
	}
}

// videoStore returns the store of video-service; it also cleans up after the tests.
func videoStore(t *testing.T) (*Store, string) {
	t.Helper()
	v := requireEnv(t, envS3Endpoint, envVideoAccessKey, envVideoSecretKey)
	return newTestStore(t, stackConfig(v[0], v[1], v[2])), v[0]
}

func workerStore(t *testing.T) *Store {
	t.Helper()
	v := requireEnv(t, envS3Endpoint, envWorkerAccess, envWorkerSecret)
	return newTestStore(t, stackConfig(v[0], v[1], v[2]))
}

// cleanup removes the test objects under uploads/<id> and media/<id>/ with video-service,
// which may delete under both prefixes.
func cleanup(t *testing.T, video *Store, id string) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		if err := video.Delete(ctx, UploadsPrefix+id); err != nil {
			t.Errorf("cleanup: %v", err)
		}
		if err := video.DeletePrefix(ctx, MediaPrefix+id+"/"); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
}

// mediaKeys lists the keys under prefix in the media bucket, as video-service (the only user
// allowed to list it, under media/).
func mediaKeys(t *testing.T, video *Store, prefix string) []string {
	t.Helper()
	var keys []string
	pages := s3.NewListObjectsV2Paginator(video.client, &s3.ListObjectsV2Input{
		Bucket: aws.String(video.mediaBucket), Prefix: aws.String(prefix),
	})
	for pages.HasMorePages() {
		page, err := pages.NextPage(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		for _, o := range page.Contents {
			keys = append(keys, aws.ToString(o.Key))
		}
	}
	slices.Sort(keys)
	return keys
}

func writeFile(t *testing.T, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// postForm sends fields and then file as a multipart form to url, the way a browser submits
// the presigned form, and returns the status code and response body.
func postForm(t *testing.T, url string, fields map[string]string, file []byte) (int, string) {
	t.Helper()
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	names := make([]string, 0, len(fields))
	for k := range fields {
		names = append(names, k)
	}
	slices.Sort(names)
	for _, k := range names {
		if err := w.WriteField(k, fields[k]); err != nil {
			t.Fatal(err)
		}
	}
	// S3 ignores every field after the file, so it comes last.
	fw, err := w.CreateFormFile("file", "clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(file); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPost, url, &body)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestIntegrationPresignedPost(t *testing.T) {
	video, endpoint := videoStore(t)
	const size = 64
	file := bytes.Repeat([]byte("v"), size)

	// presign returns a fresh key under uploads/ and its form, cleaned up after the test.
	presign := func(t *testing.T, s *Store, ttl time.Duration) (string, string, *PresignedPost) {
		t.Helper()
		id := ids.New()
		cleanup(t, video, id)
		key := UploadsPrefix + id
		post, err := s.PresignPost(t.Context(), key, size, "video/mp4", ttl)
		if err != nil {
			t.Fatal(err)
		}
		return id, key, post
	}
	assertAbsent := func(t *testing.T, key string) {
		t.Helper()
		if _, err := video.Head(t.Context(), key); !errors.Is(err, ErrNotFound) {
			t.Errorf("Head(%s) error = %v, want ErrNotFound", key, err)
		}
	}
	assertRejected := func(t *testing.T, status int, body string) {
		t.Helper()
		if status < 400 {
			t.Errorf("status %d, want a rejection; body %s", status, body)
		}
	}

	t.Run("valid form", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		status, body := postForm(t, post.URL, post.Fields, file)
		if status != http.StatusNoContent && status != http.StatusCreated {
			t.Fatalf("status %d, want 204 or 201; body %s", status, body)
		}
		info, err := video.Head(t.Context(), key)
		if err != nil {
			t.Fatal(err)
		}
		if info != (ObjectInfo{Size: size, ContentType: "video/mp4"}) {
			t.Errorf("Head() = %+v, want size %d, video/mp4", info, size)
		}
	})

	t.Run("key changed to another upload", func(t *testing.T) {
		otherID := ids.New()
		cleanup(t, video, otherID)
		_, key, post := presign(t, video, time.Minute)
		fields := withField(post.Fields, "key", UploadsPrefix+otherID)
		status, body := postForm(t, post.URL, fields, file)
		if status != http.StatusForbidden {
			t.Errorf("status %d, want 403; body %s", status, body)
		}
		assertAbsent(t, key)
		assertAbsent(t, UploadsPrefix+otherID)
	})

	t.Run("key changed to media", func(t *testing.T) {
		id, _, post := presign(t, video, time.Minute)
		target := MediaPrefix + id + "/master.m3u8"
		// Same bucket name in the URL, and the media bucket too: both must refuse.
		for _, url := range []string{post.URL, strings.TrimSuffix(post.URL, "/uploads") + "/media"} {
			status, body := postForm(t, url, withField(post.Fields, "key", target), file)
			if status != http.StatusForbidden {
				t.Errorf("POST %s: status %d, want 403; body %s", url, status, body)
			}
		}
		if keys := mediaKeys(t, video, MediaPrefix+id+"/"); len(keys) != 0 {
			t.Errorf("media objects written: %v", keys)
		}
	})

	t.Run("file one byte too large", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		status, body := postForm(t, post.URL, post.Fields, append(bytes.Clone(file), 'x'))
		assertRejected(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("empty file", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		status, body := postForm(t, post.URL, post.Fields, nil)
		assertRejected(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("other content type", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		status, body := postForm(t, post.URL, withField(post.Fields, "Content-Type", "video/webm"), file)
		assertRejected(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("content type field missing", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		fields := maps.Clone(post.Fields)
		delete(fields, "Content-Type")
		status, body := postForm(t, post.URL, fields, file)
		assertRejected(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("expired form", func(t *testing.T) {
		_, key, post := presign(t, video, time.Second)
		// The policy expiration has whole seconds; wait until it is clearly past.
		time.Sleep(time.Until(post.ExpiresAt) + 1500*time.Millisecond)
		status, body := postForm(t, post.URL, post.Fields, file)
		assertRejected(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("URL from the public endpoint", func(t *testing.T) {
		// Signing never calls the internal endpoint, so an unreachable one still gives a form
		// that works against the public endpoint.
		cfg := stackConfig("http://svp-unreachable.invalid:9000", os.Getenv(envVideoAccessKey), os.Getenv(envVideoSecretKey))
		cfg.PublicEndpoint = endpoint
		signer := newTestStore(t, cfg)
		_, key, post := presign(t, signer, time.Minute)
		if post.URL != endpoint+"/uploads" {
			t.Errorf("URL = %q, want %q", post.URL, endpoint+"/uploads")
		}
		status, body := postForm(t, post.URL, post.Fields, file)
		if status != http.StatusNoContent && status != http.StatusCreated {
			t.Fatalf("status %d, want 204 or 201; body %s", status, body)
		}
		if _, err := video.Head(t.Context(), key); err != nil {
			t.Errorf("Head() error = %v", err)
		}
	})
}

// withField returns a copy of fields with k set to v.
func withField(fields map[string]string, k, v string) map[string]string {
	out := maps.Clone(fields)
	out[k] = v
	return out
}

func TestIntegrationWorkerPermissions(t *testing.T) {
	video, _ := videoStore(t)
	worker := workerStore(t)
	id := ids.New()
	cleanup(t, video, id)
	content := []byte("source video bytes")
	if err := video.Upload(t.Context(), UploadsPrefix+id, writeFile(t, content), "video/mp4"); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(t.TempDir(), "source")
	if err := worker.Download(t.Context(), UploadsPrefix+id, dst, int64(len(content))); err != nil {
		t.Fatalf("worker Download() error = %v", err)
	}
	got, err := os.ReadFile(dst) //nolint:gosec // a file this test downloaded
	if err != nil || !bytes.Equal(got, content) {
		t.Errorf("downloaded %q, %v; want %q", got, err, content)
	}

	tooSmall := filepath.Join(t.TempDir(), "source")
	if err := worker.Download(t.Context(), UploadsPrefix+id, tooSmall, int64(len(content))-1); !errors.Is(err, ErrTooLarge) {
		t.Errorf("Download() over the limit: error = %v, want ErrTooLarge", err)
	}
	if _, err := os.Stat(tooSmall); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("file left after a download over the limit: %v", err)
	}

	segment := MediaPrefix + id + "/720p/seg_000.ts"
	if err := worker.Upload(t.Context(), segment, writeFile(t, []byte("ts")), "video/mp2t"); err != nil {
		t.Errorf("worker Upload(media) error = %v", err)
	}
	if keys := mediaKeys(t, video, MediaPrefix+id+"/"); !slices.Equal(keys, []string{segment}) {
		t.Errorf("media keys = %v, want [%s]", keys, segment)
	}

	otherID := ids.New()
	cleanup(t, video, otherID)
	if err := worker.Upload(t.Context(), UploadsPrefix+otherID, writeFile(t, []byte("x")), "video/mp4"); !errors.Is(err, ErrAccessDenied) {
		t.Errorf("worker Upload(uploads) error = %v, want ErrAccessDenied", err)
	}
	if _, err := video.Head(t.Context(), UploadsPrefix+otherID); !errors.Is(err, ErrNotFound) {
		t.Errorf("Head() after a denied upload: %v, want ErrNotFound", err)
	}
}

func TestIntegrationVideoServicePermissions(t *testing.T) {
	video, _ := videoStore(t)
	worker := workerStore(t)
	id := ids.New()
	cleanup(t, video, id)

	if err := video.Upload(t.Context(), MediaPrefix+id+"/master.m3u8", writeFile(t, []byte("#EXTM3U")), "application/vnd.apple.mpegurl"); !errors.Is(err, ErrAccessDenied) {
		t.Errorf("video-service Upload(media) error = %v, want ErrAccessDenied", err)
	}

	upload := UploadsPrefix + id
	if err := video.Upload(t.Context(), upload, writeFile(t, []byte("x")), "video/mp4"); err != nil {
		t.Fatal(err)
	}
	if err := video.Delete(t.Context(), upload); err != nil {
		t.Errorf("Delete(uploads) error = %v", err)
	}
	if _, err := video.Head(t.Context(), upload); !errors.Is(err, ErrNotFound) {
		t.Errorf("Head() after Delete: %v, want ErrNotFound", err)
	}

	playlist := MediaPrefix + id + "/master.m3u8"
	if err := worker.Upload(t.Context(), playlist, writeFile(t, []byte("#EXTM3U")), "application/vnd.apple.mpegurl"); err != nil {
		t.Fatal(err)
	}
	if err := video.Delete(t.Context(), playlist); err != nil {
		t.Errorf("Delete(media) error = %v", err)
	}
	if keys := mediaKeys(t, video, MediaPrefix+id+"/"); len(keys) != 0 {
		t.Errorf("media keys after Delete = %v", keys)
	}

	// Deleting what does not exist is not an error, under either prefix.
	for _, key := range []string{upload, playlist} {
		if err := video.Delete(t.Context(), key); err != nil {
			t.Errorf("Delete(%s) of a missing object: %v", key, err)
		}
	}
	if err := video.DeletePrefix(t.Context(), MediaPrefix+id+"/"); err != nil {
		t.Errorf("DeletePrefix() with nothing under it: %v", err)
	}
}

func TestIntegrationDeletePrefix(t *testing.T) {
	video, _ := videoStore(t)
	worker := workerStore(t)
	id, otherID := ids.New(), ids.New()
	cleanup(t, video, id)
	cleanup(t, video, otherID)

	keys := []string{
		MediaPrefix + id + "/master.m3u8",
		MediaPrefix + id + "/360p/index.m3u8",
		MediaPrefix + id + "/360p/seg_000.ts",
		MediaPrefix + id + "/720p/index.m3u8",
		MediaPrefix + id + "/720p/seg_000.ts",
	}
	kept := MediaPrefix + otherID + "/master.m3u8"
	f := writeFile(t, []byte("data"))
	for _, k := range append(slices.Clone(keys), kept) {
		if err := worker.Upload(t.Context(), k, f, "application/octet-stream"); err != nil {
			t.Fatal(err)
		}
	}

	// Two keys per list page: five objects take three pages.
	video.listPageSize = 2
	if err := video.DeletePrefix(t.Context(), MediaPrefix+id+"/"); err != nil {
		t.Fatalf("DeletePrefix() error = %v", err)
	}
	if left := mediaKeys(t, video, MediaPrefix+id+"/"); len(left) != 0 {
		t.Errorf("left under the prefix: %v", left)
	}
	if other := mediaKeys(t, video, MediaPrefix+otherID+"/"); !slices.Equal(other, []string{kept}) {
		t.Errorf("other video keys = %v, want [%s]", other, kept)
	}
}
