package objstore

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// fakeAgent is a credential endpoint like the EKS Pod Identity agent, opened by the test on
// loopback. Each fetch hands out a new credential (key ASIA<n>, session token session-<n>) valid
// for lifetime, and records the Authorization header it got.
type fakeAgent struct {
	srv      *httptest.Server
	lifetime time.Duration

	mu     sync.Mutex
	tokens []string
}

func newFakeAgent(t *testing.T, lifetime time.Duration) *fakeAgent {
	t.Helper()
	a := &fakeAgent{lifetime: lifetime}
	a.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/credentials" {
			http.NotFound(w, r)
			return
		}
		a.mu.Lock()
		a.tokens = append(a.tokens, r.Header.Get("Authorization"))
		n := len(a.tokens)
		a.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{ //nolint:gosec // a dummy credential of a fake agent
			"AccessKeyId":     fmt.Sprintf("ASIA%d", n),
			"SecretAccessKey": "not-a-real-secret",
			"Token":           fmt.Sprintf("session-%d", n),
			"Expiration":      time.Now().Add(a.lifetime).UTC().Format(time.RFC3339),
		})
	}))
	t.Cleanup(a.srv.Close)
	return a
}

// fetches returns the Authorization header of every fetch so far.
func (a *fakeAgent) fetches() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string(nil), a.tokens...)
}

// writeToken puts token into the token file at path, as the kubelet does when it rotates it.
func writeToken(t *testing.T, path, token string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		t.Fatal(err)
	}
}

// containerConfig is testConfig with the credential of agent instead of a static key.
func containerConfig(t *testing.T, endpoint string, agent *fakeAgent) (Config, string) {
	t.Helper()
	tokenFile := filepath.Join(t.TempDir(), "eks-pod-identity-token")
	writeToken(t, tokenFile, "pod-token-1")
	cfg := testConfig(endpoint)
	cfg.AccessKeyID, cfg.SecretAccessKey = "", ""
	cfg.Credentials = CredentialsContainer
	cfg.ContainerCredentialsURI = agent.srv.URL + "/v1/credentials"
	cfg.ContainerTokenFile = tokenFile
	return cfg, tokenFile
}

// A form signed with a short-lived credential carries its session token as a field and in the
// signed policy, since storage checks the token against the policy; a static key has no token.
func TestPresignPostSessionToken(t *testing.T) {
	agent := newFakeAgent(t, time.Hour)
	cfg, _ := containerConfig(t, "http://s3:9000", agent)
	post, err := newTestStore(t, cfg).PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", 15*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if got := post.Fields["X-Amz-Security-Token"]; got != "session-1" {
		t.Errorf("X-Amz-Security-Token = %q, want the session token of the fetched credential", got)
	}
	if !strings.HasPrefix(post.Fields["X-Amz-Credential"], "ASIA1/") {
		t.Errorf("X-Amz-Credential = %q, want the fetched access key", post.Fields["X-Amz-Credential"])
	}
	_, conds := decodePolicy(t, post.Fields["policy"])
	if !strings.Contains(fmt.Sprint(conds), "X-Amz-Security-Token:session-1") {
		t.Errorf("policy conditions %v lack the session token", conds)
	}
	if got := agent.fetches(); len(got) != 1 || got[0] != "pod-token-1" {
		t.Errorf("agent got Authorization %q, want one fetch with the token of the file", got)
	}

	static, err := newTestStore(t, testConfig("http://s3:9000")).PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := static.Fields["X-Amz-Security-Token"]; ok {
		t.Error("a form signed with a static key has an X-Amz-Security-Token field")
	}
}

// A credential is reused only while it outlives the longest form by the refresh window: one that
// expires sooner is fetched again before the next form, with the token the file holds by then.
func TestContainerCredentialsRefreshBeforeFormsOutliveThem(t *testing.T) {
	if credentialRefreshWindow <= maxPresignTTL {
		t.Fatalf("refresh window %s is not longer than the longest form %s", credentialRefreshWindow, maxPresignTTL)
	}
	tests := []struct {
		name     string
		lifetime time.Duration
		refetch  bool
	}{
		{"outlives the window", credentialRefreshWindow + 10*time.Minute, false},
		// Still longer than a form, but inside the window: replaced before it is used again.
		{"inside the window", credentialRefreshWindow - time.Minute, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			agent := newFakeAgent(t, tt.lifetime)
			cfg, tokenFile := containerConfig(t, "http://s3:9000", agent)
			s := newTestStore(t, cfg)
			var keys []string
			for i := range 2 {
				if i == 1 {
					writeToken(t, tokenFile, "pod-token-2")
				}
				post, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", maxPresignTTL)
				if err != nil {
					t.Fatal(err)
				}
				keys = append(keys, strings.SplitN(post.Fields["X-Amz-Credential"], "/", 2)[0])
			}
			fetches := agent.fetches()
			if !tt.refetch {
				if fmt.Sprint(fetches) != "[pod-token-1]" || keys[0] != keys[1] {
					t.Errorf("fetches %q, forms signed with %v; want one fetch and the cached credential twice", fetches, keys)
				}
				return
			}
			// The SDK may ask the cache more than once per form; every ask of an expiring
			// credential fetches, so count only that the second form got a fresh one.
			if fetches[len(fetches)-1] != "pod-token-2" || keys[0] == keys[1] {
				t.Errorf("fetches %q, forms signed with %v; want the second form signed with a credential fetched after it", fetches, keys)
			}
		})
	}
}

func TestPresignPostRejectsFormsLongerThanTheLimit(t *testing.T) {
	s := newTestStore(t, testConfig("http://s3:9000"))
	if _, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", maxPresignTTL+time.Second); err == nil {
		t.Errorf("PresignPost() with a ttl over %s succeeded", maxPresignTTL)
	}
}

// Calls to storage are signed with the fetched credential and carry its session token, and each
// cached credential is fetched once: once for calls, once for forms.
func TestContainerCredentialsSignRequests(t *testing.T) {
	agent := newFakeAgent(t, time.Hour)
	var auth, token string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, token = r.Header.Get("Authorization"), r.Header.Get("X-Amz-Security-Token")
		w.Header().Set("Content-Length", "1")
	}))
	defer srv.Close()
	cfg, _ := containerConfig(t, srv.URL, agent)
	s := newTestStore(t, cfg)
	for range 2 {
		if _, err := s.Head(t.Context(), "uploads/v1"); err != nil {
			t.Fatal(err)
		}
	}
	if !strings.Contains(auth, "Credential=ASIA1/") || token != "session-1" {
		t.Errorf("Authorization %q, X-Amz-Security-Token %q; want the fetched credential", auth, token)
	}
	for range 2 {
		if _, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", time.Minute); err != nil {
			t.Fatal(err)
		}
	}
	if got := len(agent.fetches()); got != 2 {
		t.Errorf("agent fetched %d times, want once for calls and once for forms", got)
	}
}

// A credential too close to its expiry to sign a form still signs calls: only forms need one that
// outlives them, so calls neither fetch again nor fail while the agent is down.
func TestContainerCredentialsCallsKeepACredentialFormsReplace(t *testing.T) {
	if callCredentialWindow >= credentialRefreshWindow {
		t.Fatalf("call window %s is not shorter than the form window %s", callCredentialWindow, credentialRefreshWindow)
	}
	// Inside the window of forms, well outside the window of calls.
	agent := newFakeAgent(t, credentialRefreshWindow-time.Minute)
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		w.Header().Set("Content-Length", "1")
	}))
	defer srv.Close()
	cfg, _ := containerConfig(t, srv.URL, agent)
	s := newTestStore(t, cfg)
	if _, err := s.Head(t.Context(), "uploads/v1"); err != nil {
		t.Fatal(err)
	}
	// The credential still outlives this form, so the form is signed.
	if _, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", maxPresignTTL); err != nil {
		t.Fatal(err)
	}
	first := len(agent.fetches())

	// The agent goes away: calls go on with the cached credential.
	agent.srv.Close()
	for range 3 {
		if _, err := s.Head(t.Context(), "uploads/v1"); err != nil {
			t.Fatalf("Head() with a cached credential and the agent down: %v", err)
		}
	}
	if got := len(agent.fetches()); got != first {
		t.Errorf("agent fetched %d times for calls, want %d: calls keep the credential", got, first)
	}
	if !strings.Contains(auth, "Credential=ASIA1/") {
		t.Errorf("Authorization %q, want the credential fetched first", auth)
	}
	// Forms do not reuse a credential inside their window, and none can be fetched now.
	if _, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", maxPresignTTL); err == nil {
		t.Error("PresignPost() reused a credential that expires within the form window")
	}
}

// A credential that cannot be fetched fails the call, and the error carries no token.
func TestContainerCredentialsFetchFailure(t *testing.T) {
	agent := newFakeAgent(t, time.Hour)
	cfg, tokenFile := containerConfig(t, "http://s3:9000", agent)
	if err := os.Remove(tokenFile); err != nil {
		t.Fatal(err)
	}
	_, err := newTestStore(t, cfg).PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", time.Minute)
	if err == nil {
		t.Fatal("PresignPost() without a token file succeeded")
	}
	if len(agent.fetches()) != 0 {
		t.Error("agent was called without a token")
	}

	failing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"code":"InvalidToken","message":"token rejected"}`))
	}))
	defer failing.Close()
	cfg, _ = containerConfig(t, "http://s3:9000", agent)
	cfg.ContainerCredentialsURI = failing.URL + "/v1/credentials"
	_, err = newTestStore(t, cfg).PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", time.Minute)
	if err == nil {
		t.Fatal("PresignPost() with a refusing agent succeeded")
	}
	if strings.Contains(err.Error(), "pod-token-1") {
		t.Errorf("error leaks the token: %v", err)
	}
}

func TestNewRejectsMixedCredentials(t *testing.T) {
	agent := newFakeAgent(t, time.Hour)
	tests := []struct {
		name   string
		change func(*Config)
		want   string
	}{
		{"unknown mode", func(c *Config) { c.Credentials = "env" }, "Credentials"},
		{"container with an access key", func(c *Config) { c.AccessKeyID = "svp-test" }, "AccessKeyID"},
		{"container with a secret key", func(c *Config) { c.SecretAccessKey = "not-a-real-secret" }, "SecretAccessKey"},
		{"container without a token file", func(c *Config) { c.ContainerTokenFile = "" }, "ContainerTokenFile"},
		{"container without a URI", func(c *Config) { c.ContainerCredentialsURI = "" }, "ContainerCredentialsURI"},
		{"container URI of another host", func(c *Config) { c.ContainerCredentialsURI = "http://10.0.0.1/v1/credentials" }, "ContainerCredentialsURI"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, _ := containerConfig(t, "http://s3:9000", agent)
			tt.change(&cfg)
			_, err := New(cfg)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("New() error = %v, want one naming %s", err, tt.want)
			}
		})
	}
}

func TestCheckContainerURI(t *testing.T) {
	for _, tt := range []struct {
		uri string
		ok  bool
	}{
		{"http://169.254.170.23/v1/credentials", true},
		{"http://[fd00:ec2::23]/v1/credentials", true},
		{"http://127.0.0.1:41234/v1/credentials", true},
		{"http://[::1]:41234/v1/credentials", true},
		{"https://169.254.170.23/v1/credentials", false},
		{"http://169.254.169.254/latest/meta-data/", false},
		{"http://169.254.170.2/v2/credentials", false},
		{"http://localhost/v1/credentials", false},
		{"http://agent.example/v1/credentials", false},
		{"http://user:pass@169.254.170.23/v1/credentials", false},
		{"http://[::ffff:127.0.0.1]/v1/credentials", true},
		{"169.254.170.23/v1/credentials", false},
		{"", false},
	} {
		err := checkContainerURI(tt.uri)
		if (err == nil) != tt.ok {
			t.Errorf("checkContainerURI(%q) = %v, want ok=%v", tt.uri, err, tt.ok)
		}
		if err != nil && tt.uri != "" && strings.Contains(err.Error(), tt.uri) {
			t.Errorf("checkContainerURI(%q) error prints the URI: %v", tt.uri, err)
		}
	}
}

// accessEnv lists every variable ReadAccessEnv reads.
var accessEnv = []string{"S3_CREDENTIALS", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "AWS_CONTAINER_CREDENTIALS_FULL_URI",
	"AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "S3_PATH_STYLE"}

func setAccessEnv(t *testing.T, env map[string]string) {
	t.Helper()
	for _, name := range accessEnv {
		t.Setenv(name, env[name])
	}
}

func TestReadAccessEnv(t *testing.T) {
	const agentURI = "http://169.254.170.23/v1/credentials"
	const tokenFile = "/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token" //nolint:gosec // a path, not a secret
	tests := []struct {
		name string
		env  map[string]string
		want Config
	}{
		{"defaults", map[string]string{"S3_ACCESS_KEY_ID": "key", "S3_SECRET_ACCESS_KEY": "secret-value"},
			Config{Credentials: CredentialsStatic, AccessKeyID: "key", SecretAccessKey: "secret-value"}},
		{"static, path-style", map[string]string{"S3_CREDENTIALS": "static", "S3_ACCESS_KEY_ID": "key",
			"S3_SECRET_ACCESS_KEY": "secret-value", "S3_PATH_STYLE": "true"},
			Config{Credentials: CredentialsStatic, AccessKeyID: "key", SecretAccessKey: "secret-value"}},
		{"container, virtual-hosted", map[string]string{"S3_CREDENTIALS": "container", "S3_PATH_STYLE": "false",
			"AWS_CONTAINER_CREDENTIALS_FULL_URI": agentURI, "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE": tokenFile},
			Config{Credentials: CredentialsContainer, ContainerCredentialsURI: agentURI, ContainerTokenFile: tokenFile, VirtualHosted: true}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setAccessEnv(t, tt.env)
			var got Config
			if err := got.ReadAccessEnv(); err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("ReadAccessEnv() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestReadAccessEnvErrorsNameTheVariable(t *testing.T) {
	container := map[string]string{ //nolint:gosec // variable names and a path, not a secret
		"S3_CREDENTIALS":                         "container",
		"AWS_CONTAINER_CREDENTIALS_FULL_URI":     "http://169.254.170.23/v1/credentials",
		"AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE": "/var/run/token",
	}
	static := map[string]string{"S3_ACCESS_KEY_ID": "key", "S3_SECRET_ACCESS_KEY": "secret-value"}
	tests := []struct {
		name, variable, value string
		base                  map[string]string
	}{
		{"unknown mode", "S3_CREDENTIALS", "env", static},
		{"mode in capitals", "S3_CREDENTIALS", "Container", container},
		{"static without access key", "S3_ACCESS_KEY_ID", "", static},
		{"static without secret key", "S3_SECRET_ACCESS_KEY", "", static},
		{"container with access key", "S3_ACCESS_KEY_ID", "leftover-key", container},
		{"container with secret key", "S3_SECRET_ACCESS_KEY", "secret-value", container},
		{"container without URI", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "", container},
		{"container URI of another host", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://10.1.2.3:8080/creds", container},
		{"container without token file", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE", "", container},
		{"path style 1", "S3_PATH_STYLE", "1", static},
		{"path style TRUE", "S3_PATH_STYLE", "TRUE", static},
		{"path style yes", "S3_PATH_STYLE", "yes", container},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			env := map[string]string{}
			for k, v := range tt.base {
				env[k] = v
			}
			env[tt.variable] = tt.value
			setAccessEnv(t, env)
			var cfg Config
			err := cfg.ReadAccessEnv()
			if err == nil || !strings.Contains(err.Error(), tt.variable) {
				t.Fatalf("ReadAccessEnv() error = %v, want one naming %s", err, tt.variable)
			}
			for _, v := range []string{tt.value, "secret-value", "/var/run/token"} {
				if len(v) > 3 && strings.Contains(err.Error(), v) {
					t.Errorf("error prints the value %q: %v", v, err)
				}
			}
		})
	}
}

// hostRecorder answers every request with an empty 200 and records its host and path.
type hostRecorder struct{ host, path string }

func (rt *hostRecorder) RoundTrip(r *http.Request) (*http.Response, error) {
	rt.host, rt.path = r.URL.Host, r.URL.Path
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Length": {"0"}},
		Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
}

// Virtual-hosted puts the bucket into the host of both the requests and the form URL, so the
// form posts to the bucket's own origin; path-style keeps it in the path (the other tests).
func TestVirtualHosted(t *testing.T) {
	cfg := testConfig("https://s3.ap-southeast-1.amazonaws.com")
	cfg.Region = "ap-southeast-1"
	cfg.VirtualHosted = true
	cfg.UploadsBucket = "svp-stg-uploads-a1b2"
	s := newTestStore(t, cfg)

	post, err := s.PresignPost(t.Context(), "uploads/v1", 10, "video/mp4", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if post.URL != "https://svp-stg-uploads-a1b2.s3.ap-southeast-1.amazonaws.com" {
		t.Errorf("form URL = %q, want the bucket's own origin", post.URL)
	}

	// The transport answers in place of S3: nothing leaves the machine.
	rt := &hostRecorder{}
	s.client = s3.New(s.client.Options(), func(o *s3.Options) { o.HTTPClient = &http.Client{Transport: rt} })
	if _, err := s.Head(t.Context(), "uploads/v1"); err != nil {
		t.Fatal(err)
	}
	if rt.host != "svp-stg-uploads-a1b2.s3.ap-southeast-1.amazonaws.com" || rt.path != "/uploads/v1" {
		t.Errorf("HEAD went to host %q path %q, want the bucket in the host", rt.host, rt.path)
	}
}
