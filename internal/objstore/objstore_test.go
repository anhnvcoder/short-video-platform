package objstore

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testConfig(endpoint string) Config {
	return Config{ //nolint:gosec // a dummy credential, never sent anywhere real
		Endpoint:        endpoint,
		Region:          "us-east-1",
		AccessKeyID:     "svp-test",
		SecretAccessKey: "not-a-real-secret",
		UploadsBucket:   "uploads",
		MediaBucket:     "media",
	}
}

func newTestStore(t *testing.T, cfg Config) *Store {
	t.Helper()
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestNewRejectsMissingConfig(t *testing.T) {
	for _, field := range []string{"Endpoint", "Region", "AccessKeyID", "SecretAccessKey", "UploadsBucket", "MediaBucket"} {
		cfg := testConfig("http://minio:9000")
		switch field {
		case "Endpoint":
			cfg.Endpoint = ""
		case "Region":
			cfg.Region = ""
		case "AccessKeyID":
			cfg.AccessKeyID = ""
		case "SecretAccessKey":
			cfg.SecretAccessKey = ""
		case "UploadsBucket":
			cfg.UploadsBucket = ""
		case "MediaBucket":
			cfg.MediaBucket = ""
		}
		_, err := New(cfg)
		if err == nil || !strings.Contains(err.Error(), field) {
			t.Errorf("New() without %s: error = %v, want one naming the field", field, err)
		}
	}
}

func TestBucketByPrefix(t *testing.T) {
	cfg := testConfig("http://minio:9000")
	cfg.UploadsBucket, cfg.MediaBucket = "up-bucket", "media-bucket"
	s := newTestStore(t, cfg)
	tests := []struct {
		key, want string
	}{
		{"uploads/0192", "up-bucket"},
		{"media/0192/master.m3u8", "media-bucket"},
		{"media/0192/", "media-bucket"},
		{"uploads/", ""},
		{"media/", ""},
		{"", ""},
		{"other/0192", ""},
		{"Uploads/0192", ""},
		{"/uploads/0192", ""},
		{"uploads0192", ""},
	}
	for _, tt := range tests {
		got, err := s.bucket(tt.key)
		if tt.want == "" {
			if !errors.Is(err, ErrInvalidKey) {
				t.Errorf("bucket(%q) = %q, %v; want ErrInvalidKey", tt.key, got, err)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("bucket(%q) = %q, %v; want %q", tt.key, got, err, tt.want)
		}
	}
}

// decodePolicy returns the expiration and conditions of a base64 POST policy.
func decodePolicy(t *testing.T, policy string) (string, []any) {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(policy)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Expiration string `json:"expiration"`
		Conditions []any  `json:"conditions"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Expiration, doc.Conditions
}

func TestPresignPostPolicy(t *testing.T) {
	cfg := testConfig("http://minio:9000")
	cfg.PublicEndpoint = "http://127.0.0.1:9000"
	s := newTestStore(t, cfg)
	const key = "uploads/0192a7b4-5c3e-7d2f-8a1b-3c4d5e6f7a8b"

	before := time.Now()
	post, err := s.PresignPost(t.Context(), key, 1234, "video/mp4", 15*time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	if post.URL != "http://127.0.0.1:9000/uploads" {
		t.Errorf("URL = %q, want the public endpoint plus the bucket", post.URL)
	}
	for _, f := range []string{"key", "policy", "Content-Type", "X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Signature"} {
		if post.Fields[f] == "" {
			t.Errorf("field %s missing", f)
		}
	}
	if post.Fields["key"] != key || post.Fields["Content-Type"] != "video/mp4" {
		t.Errorf("key, Content-Type fields = %q, %q", post.Fields["key"], post.Fields["Content-Type"])
	}
	if !strings.HasPrefix(post.Fields["X-Amz-Credential"], "svp-test/") {
		t.Errorf("X-Amz-Credential = %q, want the access key of the store", post.Fields["X-Amz-Credential"])
	}

	exp, conds := decodePolicy(t, post.Fields["policy"])
	if got := post.ExpiresAt.UTC().Format(time.RFC3339); got != exp {
		t.Errorf("ExpiresAt = %s, policy expiration = %s", got, exp)
	}
	if d := post.ExpiresAt.Sub(before); d < 15*time.Minute-time.Second || d > 15*time.Minute+2*time.Second {
		t.Errorf("ExpiresAt is %v after signing, want 15m", d)
	}

	want := map[string]bool{
		`{"bucket":"uploads"}`:                   false,
		`{"key":"` + key + `"}`:                  false,
		`{"Content-Type":"video/mp4"}`:           false,
		`["content-length-range",1,1234]`:        false,
		`{"X-Amz-Algorithm":"AWS4-HMAC-SHA256"}`: false,
	}
	keyConds := 0
	for _, c := range conds {
		b, err := json.Marshal(c)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := want[string(b)]; ok {
			want[string(b)] = true
		}
		if strings.Contains(string(b), "starts-with") {
			t.Errorf("policy has a prefix condition %s; key, bucket and type must match exactly", b)
		}
		if strings.Contains(string(b), `"key"`) || strings.Contains(string(b), `$key`) {
			keyConds++
		}
	}
	for c, found := range want {
		if !found {
			t.Errorf("policy lacks condition %s; conditions: %v", c, conds)
		}
	}
	if keyConds != 1 {
		t.Errorf("policy has %d key conditions, want exactly one", keyConds)
	}
}

func TestPresignPostRejects(t *testing.T) {
	s := newTestStore(t, testConfig("http://minio:9000"))
	tests := []struct {
		name, key, contentType string
		size                   int64
		ttl                    time.Duration
	}{
		{"media key", "media/0192/master.m3u8", "video/mp4", 10, time.Minute},
		{"other prefix", "other/0192", "video/mp4", 10, time.Minute},
		{"bare prefix", "uploads/", "video/mp4", 10, time.Minute},
		{"zero size", "uploads/0192", "video/mp4", 0, time.Minute},
		{"no content type", "uploads/0192", "", 10, time.Minute},
		{"no ttl", "uploads/0192", "video/mp4", 10, 0},
	}
	for _, tt := range tests {
		post, err := s.PresignPost(t.Context(), tt.key, tt.size, tt.contentType, tt.ttl)
		if err == nil || post != nil {
			t.Errorf("%s: PresignPost() = %v, %v; want an error", tt.name, post, err)
		}
	}
}

func TestHeadClassifiesErrors(t *testing.T) {
	tests := []struct {
		status    int
		want      error
		permanent bool
	}{
		{http.StatusNotFound, ErrNotFound, true},
		{http.StatusForbidden, ErrAccessDenied, true},
		{http.StatusServiceUnavailable, nil, false},
	}
	for _, tt := range tests {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(tt.status)
		}))
		s := newTestStore(t, testConfig(srv.URL))
		_, err := s.Head(t.Context(), "uploads/v1")
		srv.Close()
		if err == nil {
			t.Fatalf("HTTP %d: Head() succeeded", tt.status)
		}
		if tt.want != nil && !errors.Is(err, tt.want) {
			t.Errorf("HTTP %d: error = %v, want %v", tt.status, err, tt.want)
		}
		if !tt.permanent && (errors.Is(err, ErrNotFound) || errors.Is(err, ErrAccessDenied)) {
			t.Errorf("HTTP %d: error = %v classified as permanent, want temporary", tt.status, err)
		}
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "42")
		w.Header().Set("Content-Type", "video/mp4")
	}))
	defer srv.Close()
	info, err := newTestStore(t, testConfig(srv.URL)).Head(t.Context(), "uploads/v1")
	if err != nil || info != (ObjectInfo{Size: 42, ContentType: "video/mp4"}) {
		t.Errorf("Head() = %+v, %v; want size 42, video/mp4", info, err)
	}
}

// fakeGet serves GET /uploads/uploads/<id> with body, chunked when chunked is true (no
// Content-Length), and 404 for any other path.
func fakeGet(t *testing.T, body string, chunked bool) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/uploads/uploads/v1" {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`<Error><Code>NoSuchKey</Code></Error>`))
			return
		}
		if chunked {
			_, _ = w.Write([]byte(body[:1]))
			w.(http.Flusher).Flush()
			_, _ = w.Write([]byte(body[1:]))
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// staleFile writes a file where Download will write, as an earlier attempt would leave it.
func staleFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "src")
	if err := os.WriteFile(path, []byte("stale content from an earlier attempt"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDownload(t *testing.T) {
	tests := []struct {
		name    string
		chunked bool
		max     int64
		wantErr error
	}{
		{"within limit", false, 10, nil},
		{"exactly the limit, chunked", true, 10, nil},
		{"over the limit by length", false, 9, ErrTooLarge},
		{"over the limit while streaming", true, 9, ErrTooLarge},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := fakeGet(t, "0123456789", tt.chunked)
			s := newTestStore(t, testConfig(srv.URL))
			path := staleFile(t)
			err := s.Download(t.Context(), "uploads/v1", path, tt.max)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("Download() error = %v, want %v", err, tt.wantErr)
			}
			got, rerr := os.ReadFile(path) //nolint:gosec // a file this test downloaded
			if tt.wantErr != nil {
				if !errors.Is(rerr, os.ErrNotExist) {
					t.Errorf("file left behind after %v (read error %v)", err, rerr)
				}
				return
			}
			if string(got) != "0123456789" {
				t.Errorf("file = %q", got)
			}
		})
	}

	t.Run("not found", func(t *testing.T) {
		srv := fakeGet(t, "0123456789", false)
		s := newTestStore(t, testConfig(srv.URL))
		path := staleFile(t)
		if err := s.Download(t.Context(), "uploads/v2", path, 10); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Download() error = %v, want ErrNotFound", err)
		}
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("file exists after a failed download: %v", err)
		}
	})
}

func TestDeletePrefixRejects(t *testing.T) {
	s := newTestStore(t, testConfig("http://svp-unreachable.invalid:9000"))
	for _, p := range []string{"media/", "media/0192", "other/0192/", ""} {
		if err := s.DeletePrefix(t.Context(), p); !errors.Is(err, ErrInvalidKey) {
			t.Errorf("DeletePrefix(%q) error = %v, want ErrInvalidKey", p, err)
		}
	}
}
