package objstore

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"hash/crc32"
	"io"
	"maps"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

// The integration tests run against the local object store of `make up`, through
// `make test-stack`, as the two service users created by the store's init job, so they run under
// the same per-service policies as the services. A test skips when the variable it needs is
// unset, which keeps `make check` working without the stack.
const (
	envS3Endpoint     = "SVP_TEST_S3_ENDPOINT"
	envVideoAccessKey = "SVP_TEST_S3_VIDEO_ACCESS_KEY"
	envVideoSecretKey = "SVP_TEST_S3_VIDEO_SECRET_KEY" //nolint:gosec // a variable name, not a secret
	envWorkerAccess   = "SVP_TEST_S3_WORKER_ACCESS_KEY"
	envWorkerSecret   = "SVP_TEST_S3_WORKER_SECRET_KEY" //nolint:gosec // a variable name, not a secret
	envProbeAccess    = "SVP_TEST_S3_PROBE_ACCESS_KEY"
	envProbeSecret    = "SVP_TEST_S3_PROBE_SECRET_KEY" //nolint:gosec // a variable name, not a secret

	// probeBucket belongs to a probe user that only tests use. A multipart test needs
	// AbortMultipartUpload to clean up, which the service users do not have and must not get.
	probeBucket = "objstore-probe"
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
	// A form the store refuses for what the client sent gets a 4xx; a 5xx would say nothing
	// about whether the store checked it.
	assertClientError := func(t *testing.T, status int, body string) {
		t.Helper()
		if status < 400 || status > 499 {
			t.Errorf("status %d, want 4xx; body %s", status, body)
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
		// Stores differ on the code (403 on S3 and MinIO, 400 on RustFS); what matters is that
		// the form is refused and nothing is written.
		t.Logf("status %d", status)
		assertClientError(t, status, body)
		assertAbsent(t, key)
		assertAbsent(t, UploadsPrefix+otherID)
	})

	t.Run("key changed to media", func(t *testing.T) {
		id, _, post := presign(t, video, time.Minute)
		target := MediaPrefix + id + "/master.m3u8"
		// Same bucket name in the URL, and the media bucket too: both must refuse.
		for _, url := range []string{post.URL, strings.TrimSuffix(post.URL, "/uploads") + "/media"} {
			status, body := postForm(t, url, withField(post.Fields, "key", target), file)
			// Refused with a 4xx whatever code the store picks; the check below proves nothing was written.
			t.Logf("POST %s: status %d", url, status)
			assertClientError(t, status, body)
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

	t.Run("policy size limit raised after signing", func(t *testing.T) {
		_, key, post := presign(t, video, time.Minute)
		policy := editPolicy(t, post.Fields["policy"], func(conds []any) {
			for i, c := range conds {
				if r, ok := c.([]any); ok && len(r) == 3 && r[0] == "content-length-range" {
					conds[i] = []any{"content-length-range", 1, 2 * size}
				}
			}
		})
		// The edited policy would admit one byte more, but the signature covers the original.
		status, body := postForm(t, post.URL, withField(post.Fields, "policy", policy), append(bytes.Clone(file), 'x'))
		assertClientError(t, status, body)
		assertAbsent(t, key)
	})

	t.Run("policy key changed after signing", func(t *testing.T) {
		otherID := ids.New()
		cleanup(t, video, otherID)
		_, key, post := presign(t, video, time.Minute)
		other := UploadsPrefix + otherID
		policy := editPolicy(t, post.Fields["policy"], func(conds []any) {
			for i, c := range conds {
				if m, ok := c.(map[string]any); ok && m["key"] != nil {
					conds[i] = map[string]any{"key": other}
				}
			}
		})
		fields := withField(withField(post.Fields, "policy", policy), "key", other)
		status, body := postForm(t, post.URL, fields, file)
		assertClientError(t, status, body)
		assertAbsent(t, key)
		assertAbsent(t, other)
	})

	for _, tc := range []struct {
		name string
		drop []string
	}{
		{"form without signature", []string{"X-Amz-Signature", "X-Amz-Credential"}},
		// Only the key and the file, as an anonymous client would send: uploads allows nothing
		// anonymous.
		{"anonymous form", []string{"policy", "X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Signature"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, key, post := presign(t, video, time.Minute)
			fields := maps.Clone(post.Fields)
			for _, f := range tc.drop {
				if _, ok := fields[f]; !ok {
					t.Fatalf("form has no %s field; fields %v", f, slices.Sorted(maps.Keys(fields)))
				}
				delete(fields, f)
			}
			status, body := postForm(t, post.URL, fields, file)
			assertClientError(t, status, body)
			assertAbsent(t, key)
		})
	}

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

// editPolicy decodes a base64 POST policy, lets edit change its conditions in place and returns
// it encoded again, without touching the signature. It fails the test when edit changed nothing,
// so a case cannot pass by sending the policy as signed.
func editPolicy(t *testing.T, policy string, edit func(conds []any)) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(policy)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	conds, ok := doc["conditions"].([]any)
	if !ok {
		t.Fatalf("policy has no conditions: %s", raw)
	}
	before, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	edit(conds)
	after, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(before, after) {
		t.Fatalf("edit left the policy unchanged: %s", raw)
	}
	return base64.StdEncoding.EncodeToString(after)
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

// TestIntegrationMultipartChecksum uploads an object of more than 5 MiB in two parts, each with
// a CRC32 checksum, the way the Velero AWS plugin uploads large files with aws-sdk-go-v2. The SDK
// sends that checksum in one of two forms, and the store must take both: in an
// x-amz-checksum-crc32 header over HTTP, as backup tools send it to an in-cluster http://
// endpoint, and in an aws-chunked trailer, which the SDK picks only when the request URL is
// https. The trailer pass therefore goes through a TLS proxy of the test's own in front of the
// HTTP endpoint, as a TLS gateway fronts the store in the cluster. Each pass checks on the
// client's transport that every part was sent in its form, so it cannot pass on the other one.
// It runs as the probe user, on the probe bucket only.
func TestIntegrationMultipartChecksum(t *testing.T) {
	v := requireEnv(t, envS3Endpoint, envProbeAccess, envProbeSecret)
	endpoint, accessKey, secretKey := v[0], v[1], v[2]
	video, _ := videoStore(t)

	t.Run("probe user cannot write the service buckets", func(t *testing.T) {
		probe := newTestStore(t, stackConfig(endpoint, accessKey, secretKey))
		id := ids.New()
		cleanup(t, video, id)
		f := writeFile(t, []byte("x"))
		upload, playlist := UploadsPrefix+id, MediaPrefix+id+"/master.m3u8"
		for _, key := range []string{upload, playlist} {
			if err := probe.Upload(t.Context(), key, f, "video/mp4"); !errors.Is(err, ErrAccessDenied) {
				t.Errorf("probe Upload(%s) error = %v, want ErrAccessDenied", key, err)
			}
		}
		if _, err := video.Head(t.Context(), upload); !errors.Is(err, ErrNotFound) {
			t.Errorf("Head() after a denied upload: %v, want ErrNotFound", err)
		}
		if keys := mediaKeys(t, video, MediaPrefix+id+"/"); len(keys) != 0 {
			t.Errorf("media objects written: %v", keys)
		}
	})

	t.Run("upload with CRC32 header over HTTP", func(t *testing.T) {
		rec := newRecordingTransport(http.DefaultTransport)
		client := probeClient(endpoint, accessKey, secretKey, rec)
		uploadMultipartCRC32(t, client, rec, func(t *testing.T, sent sentPart, part []byte) {
			t.Helper()
			if got, want := sent.header.Get("X-Amz-Checksum-Crc32"), crc32Base64(part); got != want {
				t.Errorf("X-Amz-Checksum-Crc32 = %q, want %q", got, want)
			}
			if got := sent.header.Get("Content-Encoding"); strings.Contains(got, "aws-chunked") {
				t.Errorf("Content-Encoding = %q, want no aws-chunked", got)
			}
			if got := sent.header.Get("X-Amz-Trailer"); got != "" {
				t.Errorf("X-Amz-Trailer = %q, want none", got)
			}
			// The body is the part itself, with no chunk framing around it.
			if !bytes.HasSuffix(part, sent.tail) || len(sent.tail) != tailSize {
				t.Errorf("body does not end with the part; last bytes %q", sent.tail)
			}
		})
	})

	t.Run("upload with trailing CRC32 over HTTPS", func(t *testing.T) {
		proxy := newTLSProxy(t, endpoint)
		rec := newRecordingTransport(proxy.Client().Transport)
		client := probeClient(proxy.URL, accessKey, secretKey, rec)
		uploadMultipartCRC32(t, client, rec, func(t *testing.T, sent sentPart, part []byte) {
			t.Helper()
			for header, want := range map[string]string{
				"X-Amz-Trailer":                "x-amz-checksum-crc32",
				"X-Amz-Content-Sha256":         "STREAMING-UNSIGNED-PAYLOAD-TRAILER",
				"X-Amz-Decoded-Content-Length": strconv.Itoa(len(part)),
				"X-Amz-Checksum-Crc32":         "",
			} {
				if got := sent.header.Get(header); got != want {
					t.Errorf("%s = %q, want %q", header, got, want)
				}
			}
			if got := sent.header.Get("Content-Encoding"); !strings.Contains(got, "aws-chunked") {
				t.Errorf("Content-Encoding = %q, want aws-chunked", got)
			}
			if trailer := "x-amz-checksum-crc32:" + crc32Base64(part); !bytes.Contains(sent.tail, []byte(trailer)) {
				t.Errorf("body does not end with the trailer %q; last bytes %q", trailer, sent.tail)
			}
		})
	})
}

// probeClient is an S3 client of the probe user that sends through rt. It is a client of its
// own: Store sends a checksum only when an operation requires one, and its configuration stays
// as the services run it.
func probeClient(endpoint, accessKey, secretKey string, rt http.RoundTripper) *s3.Client {
	return s3.New(s3.Options{
		Region:                     "us-east-1",
		BaseEndpoint:               aws.String(endpoint),
		UsePathStyle:               true,
		Credentials:                credentials.NewStaticCredentialsProvider(accessKey, secretKey, ""),
		HTTPClient:                 &http.Client{Transport: rt},
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenSupported,
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	})
}

// uploadMultipartCRC32 uploads two parts with a CRC32 checksum to a fresh key of the probe
// bucket, lets check judge what rec saw sent for each part, completes the upload and reads the
// object back. It aborts the upload if it does not complete and deletes the object afterwards.
func uploadMultipartCRC32(t *testing.T, client *s3.Client, rec *recordingTransport, check func(t *testing.T, sent sentPart, part []byte)) {
	t.Helper()
	// 5 MiB is the smallest part S3 accepts but the last; the second part makes the object
	// larger than that.
	parts := [][]byte{randomBytes(t, 5<<20), randomBytes(t, 1<<20+1)}
	bucket, key := aws.String(probeBucket), aws.String("probe/"+ids.New())

	created, err := client.CreateMultipartUpload(t.Context(), &s3.CreateMultipartUploadInput{
		Bucket: bucket, Key: key, ChecksumAlgorithm: types.ChecksumAlgorithmCrc32,
	})
	if err != nil {
		t.Fatalf("CreateMultipartUpload() error = %v", err)
	}
	completed := false
	t.Cleanup(func() {
		// t.Context is done once cleanup runs.
		ctx := context.Background()
		if !completed {
			if _, err := client.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{
				Bucket: bucket, Key: key, UploadId: created.UploadId,
			}); err != nil {
				t.Errorf("cleanup: abort upload: %v", err)
			}
		}
		if _, err := client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: bucket, Key: key}); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})

	var done []types.CompletedPart
	for i, p := range parts {
		n := int32(i + 1) //nolint:gosec // two parts
		out, err := client.UploadPart(t.Context(), &s3.UploadPartInput{
			Bucket: bucket, Key: key, UploadId: created.UploadId, PartNumber: aws.Int32(n),
			Body: bytes.NewReader(p), ChecksumAlgorithm: types.ChecksumAlgorithmCrc32,
		})
		if err != nil {
			t.Fatalf("UploadPart(%d) error = %v", n, err)
		}
		if got, want := aws.ToString(out.ChecksumCRC32), crc32Base64(p); got != want {
			t.Errorf("UploadPart(%d) checksum = %q, want %q", n, got, want)
		}
		done = append(done, types.CompletedPart{PartNumber: aws.Int32(n), ETag: out.ETag, ChecksumCRC32: out.ChecksumCRC32})
	}

	for i, p := range parts {
		n := strconv.Itoa(i + 1)
		sent, ok := rec.part(n)
		if !ok {
			t.Fatalf("part %s was never sent", n)
		}
		t.Run("part "+n, func(t *testing.T) { check(t, sent, p) })
	}

	if _, err := client.CompleteMultipartUpload(t.Context(), &s3.CompleteMultipartUploadInput{
		Bucket: bucket, Key: key, UploadId: created.UploadId,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: done},
	}); err != nil {
		t.Fatalf("CompleteMultipartUpload() error = %v", err)
	}
	completed = true

	obj, err := client.GetObject(t.Context(), &s3.GetObjectInput{Bucket: bucket, Key: key})
	if err != nil {
		t.Fatalf("GetObject() error = %v", err)
	}
	defer func() { _ = obj.Body.Close() }()
	got, err := io.ReadAll(obj.Body)
	if err != nil {
		t.Fatal(err)
	}
	// A store that does not decode aws-chunked keeps the chunk framing in the object.
	if want := bytes.Join(parts, nil); !bytes.Equal(got, want) {
		t.Errorf("read back %d bytes that differ from the %d uploaded", len(got), len(want))
	}
}

// newTLSProxy starts a TLS server that forwards every request to the store's HTTP endpoint. Its
// Client trusts its certificate.
func newTLSProxy(t *testing.T, endpoint string) *httptest.Server {
	t.Helper()
	target, err := url.Parse(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	s := httptest.NewTLSServer(&httputil.ReverseProxy{Rewrite: func(r *httputil.ProxyRequest) {
		r.SetURL(target)
		// The client signed the Host it called, and the store checks the signature against
		// the Host it receives.
		r.Out.Host = r.In.Host
	}})
	t.Cleanup(s.Close)
	return s
}

// recordingTransport passes every request on to next and keeps, for each UploadPart, the
// headers and the last bytes of the body as the client sent them.
type recordingTransport struct {
	next  http.RoundTripper
	mu    sync.Mutex
	parts map[string]*sentPart
}

type sentPart struct {
	header http.Header
	tail   []byte
}

// tailSize holds the last chunk of an aws-chunked body: the final empty chunk and the trailer.
const tailSize = 256

func newRecordingTransport(next http.RoundTripper) *recordingTransport {
	return &recordingTransport{next: next, parts: map[string]*sentPart{}}
}

func (rt *recordingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	n := req.URL.Query().Get("partNumber")
	if req.Method != http.MethodPut || n == "" || req.Body == nil {
		return rt.next.RoundTrip(req)
	}
	sent := &sentPart{header: req.Header.Clone()}
	rt.mu.Lock()
	rt.parts[n] = sent
	rt.mu.Unlock()
	// A RoundTripper must not change the request it was given.
	out := req.Clone(req.Context())
	out.Body = &tailReader{ReadCloser: req.Body, mu: &rt.mu, part: sent}
	return rt.next.RoundTrip(out)
}

// part returns what was sent for part number n. The store answers only after reading the whole
// body, so once UploadPart returns the tail is complete.
func (rt *recordingTransport) part(n string) (sentPart, bool) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	s, ok := rt.parts[n]
	if !ok {
		return sentPart{}, false
	}
	return sentPart{header: s.header, tail: bytes.Clone(s.tail)}, true
}

// tailReader passes the body through and keeps its last tailSize bytes in part.
type tailReader struct {
	io.ReadCloser
	mu   *sync.Mutex
	part *sentPart
}

func (r *tailReader) Read(b []byte) (int, error) {
	n, err := r.ReadCloser.Read(b)
	r.mu.Lock()
	tail := append(r.part.tail, b[:n]...)
	r.part.tail = bytes.Clone(tail[max(0, len(tail)-tailSize):])
	r.mu.Unlock()
	return n, err
}

func randomBytes(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

// crc32Base64 is the CRC32 (IEEE) of b in the form of the x-amz-checksum-crc32 header.
func crc32Base64(b []byte) string {
	return base64.StdEncoding.EncodeToString(binary.BigEndian.AppendUint32(nil, crc32.ChecksumIEEE(b)))
}
