package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/internal/redistest"
	"github.com/anhnvcoder/short-video-platform/internal/redisx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/httpx"
	"github.com/anhnvcoder/short-video-platform/services/gateway/internal/ratelimit"
)

// redisEnv is an env whose rate limits run on the test Redis, under keys the test deletes itself.
type redisEnv struct {
	*env
	client *redis.Client
	prefix string
}

// newRedisEnv bounds each Redis call by 2 s instead of the gateway's 50 ms: the tests count
// requests exactly, and under the whole -race suite a slower call would take the fallback.
func newRedisEnv(t *testing.T) *redisEnv {
	t.Helper()
	client, prefix := redistest.New(t)
	t.Cleanup(func() { deleteKeys(t, client, prefix) })
	limits := ratelimit.New(client, prefix, ratelimit.WithStoreTimeout(2*time.Second))
	return &redisEnv{env: newEnvWithLimits(t, limits), client: client, prefix: prefix}
}

// deleteKeys deletes the keys under prefix, then fails the test if any is still there.
func deleteKeys(t *testing.T, client *redis.Client, prefix string) {
	t.Helper()
	if keys := scanKeys(t, client, prefix); len(keys) > 0 {
		if err := client.Del(context.Background(), keys...).Err(); err != nil {
			t.Errorf("delete keys: %v", err)
		}
	}
	if left := scanKeys(t, client, prefix); len(left) != 0 {
		t.Errorf("keys left under %s: %v", prefix, left)
	}
}

func scanKeys(t *testing.T, client *redis.Client, prefix string) []string {
	t.Helper()
	var keys []string
	iter := client.Scan(context.Background(), 0, prefix+"*", 100).Iterator()
	for iter.Next(context.Background()) {
		keys = append(keys, iter.Val())
	}
	if err := iter.Err(); err != nil {
		t.Fatalf("scan %s*: %v", prefix, err)
	}
	return keys
}

// wantTTLs fails the test unless every key under prefix expires. Only PTTL -1 (no expiry) fails:
// a key may expire between SCAN and PTTL (PTTL -2), as a read or write bucket does within
// 100 ms or 500 ms when the -race suite runs slowly, and that is the expiry being checked.
func (e *redisEnv) wantTTLs(t *testing.T) {
	t.Helper()
	for _, key := range scanKeys(t, e.client, e.prefix) {
		ttl, err := e.client.PTTL(t.Context(), key).Result()
		if err != nil {
			t.Errorf("PTTL %s: %v", key, err)
		} else if ttl == -1 {
			t.Errorf("PTTL %s = %v, want the key to expire", key, ttl)
		}
	}
}

// send serves a request from remoteAddr with body (none when empty), a Bearer token when set,
// and headers.
func (e *env) send(t *testing.T, remoteAddr, method, path, body, token string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequestWithContext(t.Context(), method, path, strings.NewReader(body))
	r.RemoteAddr = remoteAddr
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, r)
	return rec
}

// wantRateLimited checks rec is the 429 of a rate limit, with Retry-After of retryAfter seconds.
func wantRateLimited(t *testing.T, rec *httptest.ResponseRecorder, retryAfter string) {
	t.Helper()
	if got := rateLimitedRetryAfter(t, rec); got != retryAfter {
		t.Errorf("Retry-After = %q, want %q", got, retryAfter)
	}
}

// wantRateLimitedSince checks rec is the 429 of a rate limit with interval T whose first
// request came after start. Redis returns T less the time since that request, so Retry-After
// lies from T less the time since start, rounded down, to T, in whole seconds and at least 1.
func wantRateLimitedSince(t *testing.T, rec *httptest.ResponseRecorder, interval time.Duration, start time.Time) {
	t.Helper()
	got := rateLimitedRetryAfter(t, rec)
	most := max(int((interval+time.Second-1)/time.Second), 1)
	least := max(int((interval-time.Since(start))/time.Second), 1)
	if n, err := strconv.Atoi(got); err != nil || n < least || n > most {
		t.Errorf("Retry-After = %q, want from %d to %d", got, least, most)
	}
}

// rateLimitedRetryAfter checks rec is the 429 of a rate limit and returns its Retry-After.
func rateLimitedRetryAfter(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	wantStatus(t, rec, http.StatusTooManyRequests)
	if p := decodeProblem(t, rec); p.Code != "RATE_LIMITED" || p.Detail != "too many requests" {
		t.Errorf("problem = %+v, want code RATE_LIMITED, detail \"too many requests\"", p)
	}
	return rec.Header().Get("Retry-After")
}

// untilLimited sends requests with send until one is refused and returns that response. It
// fails the test unless at least burst passed, and no more than GCRA refills while the requests
// run: one every interval.
func untilLimited(t *testing.T, burst int, interval time.Duration, send func(i int) *httptest.ResponseRecorder) *httptest.ResponseRecorder {
	t.Helper()
	start := time.Now()
	for i := range 2*burst + 10 {
		rec := send(i)
		if rec.Code == http.StatusTooManyRequests {
			if most := burst + int(time.Since(start)/interval) + 1; i < burst || i > most {
				t.Errorf("%d requests passed, want from %d to %d", i, burst, most)
			}
			return rec
		}
		if rec.Code >= 300 {
			t.Fatalf("request %d: status %d (body %q)", i+1, rec.Code, rec.Body.String())
		}
	}
	t.Fatalf("no request refused after %d", 2*burst+10)
	return nil
}

// methodCalls counts the calls of method a backend received.
func methodCalls(b *backend, method string) int {
	n := 0
	for _, c := range b.recorded() {
		if c.method == method {
			n++
		}
	}
	return n
}

const credentialsBody = `{"email":"a@example.com","password":"correct horse"}` //nolint:gosec // fake credentials of the tests

func TestRegisterRateLimitedByIP(t *testing.T) {
	logs := captureLog(t)
	e := newRedisEnv(t)
	const ip = "192.0.2.1:5000"
	start := time.Now()
	for i := range 20 {
		if rec := e.send(t, ip, http.MethodPost, "/auth/register", credentialsBody, "", nil); rec.Code != http.StatusCreated {
			t.Fatalf("register %d: status %d", i+1, rec.Code)
		}
	}
	// One account a minute once the burst of 20 is spent.
	wantRateLimitedSince(t, e.send(t, ip, http.MethodPost, "/auth/register", credentialsBody, "", nil), time.Minute, start)
	if n := len(e.users.recorded()); n != 20 {
		t.Errorf("user-service got %d calls, want 20", n)
	}
	if rec := e.send(t, "192.0.2.2:5000", http.MethodPost, "/auth/register", credentialsBody, "", nil); rec.Code != http.StatusCreated {
		t.Errorf("another IP: status %d, want 201", rec.Code)
	}
	if !strings.Contains(logs.String(), `"rate_limit":"register"`) {
		t.Errorf("access log does not name the rate limit:\n%s", logs)
	}
	e.wantTTLs(t)
}

func TestLoginRateLimitedByIPAndEmail(t *testing.T) {
	logs := captureLog(t)
	e := newRedisEnv(t)
	const ip = "192.0.2.1:5000"
	login := func(email string) *httptest.ResponseRecorder {
		return e.send(t, ip, http.MethodPost, "/auth/login", fmt.Sprintf(`{"email":%q,"password":"wrong password"}`, email), "", nil)
	}
	start := time.Now()
	for i := range 5 {
		if rec := login("a@example.com"); rec.Code != http.StatusOK {
			t.Fatalf("login %d: status %d", i+1, rec.Code)
		}
	}
	// The same email, written another way, is the same (IP, email) bucket: 10 an hour.
	wantRateLimitedSince(t, login("  A@Example.com"), 6*time.Minute, start)
	// Another email from the same IP is not held back by it.
	if rec := login("b@example.com"); rec.Code != http.StatusOK {
		t.Errorf("another email: status %d, want 200", rec.Code)
	}
	if n := len(e.users.recorded()); n != 6 {
		t.Errorf("user-service got %d calls, want 6", n)
	}
	// No raw email reaches Redis or the log.
	for _, key := range scanKeys(t, e.client, e.prefix) {
		if strings.Contains(strings.ToLower(key), "example") {
			t.Errorf("key %s holds the email", key)
		}
	}
	if strings.Contains(strings.ToLower(logs.String()), "example.com") {
		t.Errorf("log holds the email:\n%s", logs)
	}
	e.wantTTLs(t)
}

func TestLoginIPLimitIgnoresForwardedHeaders(t *testing.T) {
	e := newRedisEnv(t)
	const ip = "192.0.2.1:5000"
	// Each request claims another client address and another email; all of them are one IP,
	// limited to a burst of 30 and one a second.
	rec := untilLimited(t, 30, time.Second, func(i int) *httptest.ResponseRecorder {
		headers := map[string]string{
			"X-Forwarded-For": fmt.Sprintf("203.0.113.%d", i),
			"X-Real-IP":       fmt.Sprintf("198.51.100.%d", i),
			"Forwarded":       fmt.Sprintf("for=203.0.113.%d", i),
		}
		body := fmt.Sprintf(`{"email":"user%d@example.com","password":"correct horse"}`, i)
		return e.send(t, ip, http.MethodPost, "/auth/login", body, "", headers)
	})
	wantRateLimited(t, rec, "1")
	// The IP limit is checked before the body is read.
	wantRateLimited(t, e.send(t, ip, http.MethodPost, "/auth/login", "{", "", nil), "1")
}

// TestLoginIPLimitBehindProxy: behind one trusted proxy the IP limit counts the address the
// proxy appended to X-Forwarded-For. A client that writes another element before it on every
// request stays in one bucket, which leaves another client behind the same proxy unlimited; a
// client reaching the gateway directly is counted by its connection, whatever element it writes
// last (threat model RL-1).
func TestLoginIPLimitBehindProxy(t *testing.T) {
	// Fallback limits: login-ip burst 15, one every 2 s.
	e := newEnvBehind(t, httpx.NewClientAddr(1, []netip.Prefix{netip.MustParsePrefix("10.42.0.0/16")}), downLimits(t))
	const envoy, direct = "10.42.0.7:5000", "192.0.2.1:5000"
	login := func(remote, xff string, i int) *httptest.ResponseRecorder {
		body := fmt.Sprintf(`{"email":"user%d@example.com","password":"correct horse"}`, i)
		return e.send(t, remote, http.MethodPost, "/auth/login", body, "", map[string]string{"X-Forwarded-For": xff})
	}

	// The in-memory limiter answers T less the time since the first request, rounded up, so a slow
	// burst can lower Retry-After from 2 to 1; wantRateLimitedSince accepts that range.
	start := time.Now()
	wantRateLimitedSince(t, untilLimited(t, 15, 2*time.Second, func(i int) *httptest.ResponseRecorder {
		return login(envoy, fmt.Sprintf("203.0.113.%d, 198.51.100.9", i), i)
	}), 2*time.Second, start)
	wantStatus(t, login(envoy, "203.0.113.1, 198.51.100.10", 100), http.StatusOK)

	start = time.Now()
	wantRateLimitedSince(t, untilLimited(t, 15, 2*time.Second, func(i int) *httptest.ResponseRecorder {
		return login(direct, fmt.Sprintf("198.51.100.%d", 20+i), i)
	}), 2*time.Second, start)
}

// refreshOrLogout sends the i-th request of a run that alternates /auth/refresh and
// /auth/logout from remoteAddr, which share class refresh.
func refreshOrLogout(t *testing.T, e *env, remoteAddr string, i int) *httptest.ResponseRecorder {
	t.Helper()
	path := "/auth/refresh"
	if i%2 == 1 {
		path = "/auth/logout"
	}
	return e.send(t, remoteAddr, http.MethodPost, path, refreshBody, "", nil)
}

// TestRefreshAndLogoutRateLimitedByIP: refresh and logout share one bucket per client IP, a burst
// of 30 and one a second, checked before the body is read.
func TestRefreshAndLogoutRateLimitedByIP(t *testing.T) {
	logs := captureLog(t)
	e := newRedisEnv(t)
	const ip = "192.0.2.1:5000"
	rec := untilLimited(t, 30, time.Second, func(i int) *httptest.ResponseRecorder {
		return refreshOrLogout(t, e.env, ip, i)
	})
	wantRateLimited(t, rec, "1")
	calls := len(e.users.recorded())
	// Redis refills the bucket by its own clock, one a second, so a slow run could see the next
	// request let through. Moving the bucket's TAT (Unix ms, as the GCRA script stores it) an hour
	// past Redis's now keeps it full whatever the pace: the malformed body below must then be
	// refused before it is read, with a Retry-After of about an hour, never parsed into a 400.
	key := e.prefix + "rl:" + ratelimit.Refresh.Name + ":192.0.2.1"
	if n, err := e.client.Exists(t.Context(), key).Result(); err != nil || n != 1 {
		t.Fatalf("bucket %s: exists %d, err %v; want the key the limit just used", key, n, err)
	}
	now, err := e.client.Time(t.Context()).Result()
	if err != nil {
		t.Fatalf("redis TIME: %v", err)
	}
	if err := e.client.Set(t.Context(), key, now.Add(time.Hour).UnixMilli(), 2*time.Hour).Err(); err != nil {
		t.Fatalf("set bucket %s: %v", key, err)
	}
	late := e.send(t, ip, http.MethodPost, "/auth/logout", "{", "", nil)
	// TAT + T - now - T*burst = 3600 + 1 - 30 s, rounded up, less the time the request took.
	got := rateLimitedRetryAfter(t, late)
	if n, err := strconv.Atoi(got); err != nil || n < 3500 || n > 3571 {
		t.Errorf("Retry-After = %q, want from 3500 to 3571", got)
	}
	if n := len(e.users.recorded()); n != calls {
		t.Errorf("user-service got %d calls after the limit, want 0", n-calls)
	}
	if rec := refreshOrLogout(t, e.env, "192.0.2.2:5000", 0); rec.Code != http.StatusOK {
		t.Errorf("another IP: status %d, want 200", rec.Code)
	}
	if !strings.Contains(logs.String(), `"rate_limit":"refresh"`) {
		t.Errorf("access log does not name the rate limit:\n%s", logs)
	}
	e.wantTTLs(t)
}

// TestRefreshLimitedWhileRedisDown: class refresh is soft-closed, so while Redis fails the
// in-memory fallback still limits it, to a burst of 15 and one every 2 s.
func TestRefreshLimitedWhileRedisDown(t *testing.T) {
	e := newEnv(t)
	const ip = "192.0.2.1:5000"
	start := time.Now()
	wantRateLimitedSince(t, untilLimited(t, 15, 2*time.Second, func(i int) *httptest.ResponseRecorder {
		return refreshOrLogout(t, e, ip, i)
	}), 2*time.Second, start)
}

func TestLoginBadJSONCountsOnlyIP(t *testing.T) {
	e := newEnv(t) // fallback limits: login-ip burst 15, login-email burst 3
	const ip = "192.0.2.1:5000"
	// The in-memory limiter answers T less the time since the first request that counted, so each
	// refusal below is checked against a range that follows the clock, not a fixed value.
	ipStart := time.Now()
	for range 3 {
		wantStatus(t, e.send(t, ip, http.MethodPost, "/auth/login", `{"email":`, "", nil), http.StatusBadRequest)
	}
	emailStart := time.Now()
	for i := range 3 {
		if rec := e.send(t, ip, http.MethodPost, "/auth/login", credentialsBody, "", nil); rec.Code != http.StatusOK {
			t.Fatalf("login %d after bad JSON: status %d; bad JSON must not count against the email", i+1, rec.Code)
		}
	}
	// login-email fallback: 5 an hour, one every 12 minutes.
	wantRateLimitedSince(t, e.send(t, ip, http.MethodPost, "/auth/login", credentialsBody, "", nil), 12*time.Minute, emailStart)
	// 7 of the IP's 15 are spent; 8 more logins with other emails pass, the next one does not.
	for i := range 8 {
		body := fmt.Sprintf(`{"email":"user%d@example.com","password":"correct horse"}`, i)
		if rec := e.send(t, ip, http.MethodPost, "/auth/login", body, "", nil); rec.Code != http.StatusOK {
			t.Fatalf("login %d with another email: status %d", i+1, rec.Code)
		}
	}
	wantRateLimitedSince(t, e.send(t, ip, http.MethodPost, "/auth/login", `{"email":"z@example.com","password":"x"}`, "", nil), 2*time.Second, ipStart)
}

func TestIPv6ClientsShareTheir64(t *testing.T) {
	e := newEnv(t) // fallback register: burst 10, one every 2 minutes
	start := time.Now()
	for i := range 10 {
		addr := fmt.Sprintf("[2001:db8::%x]:5000", i+1)
		if rec := e.send(t, addr, http.MethodPost, "/auth/register", credentialsBody, "", nil); rec.Code != http.StatusCreated {
			t.Fatalf("register %d: status %d", i+1, rec.Code)
		}
	}
	wantRateLimitedSince(t, e.send(t, "[2001:db8::ffff]:6000", http.MethodPost, "/auth/register", credentialsBody, "", nil), 2*time.Minute, start)
	if rec := e.send(t, "[2001:db8:0:1::1]:5000", http.MethodPost, "/auth/register", credentialsBody, "", nil); rec.Code != http.StatusCreated {
		t.Errorf("another /64: status %d, want 201", rec.Code)
	}
}

func TestUserRoutesRateLimitedByUser(t *testing.T) {
	const ip = "192.0.2.1:5000"
	initBody := `{"title":"clip","size_bytes":10,"content_type":"video/mp4"}`
	for _, tt := range []struct {
		name, method, path, body string
		burst                    int
		interval                 time.Duration
	}{
		{"upload", http.MethodPost, "/videos", initBody, 10, 2 * time.Minute},
		{"write", http.MethodPut, "/videos/" + videoID + "/like", "", 60, time.Second / 2},
		{"read", http.MethodGet, "/feed/explore", "", 200, time.Second / 10},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newRedisEnv(t)
			tokenA, tokenB := e.token(t, userA), e.token(t, userB)
			var calls int
			start := time.Now()
			rec := untilLimited(t, tt.burst, tt.interval, func(int) *httptest.ResponseRecorder {
				calls = e.callCount()
				return e.send(t, ip, tt.method, tt.path, tt.body, tokenA, nil)
			})
			wantRateLimitedSince(t, rec, tt.interval, start)
			if n := e.callCount(); n != calls {
				t.Errorf("the refused request reached a service (%d calls, want %d)", n, calls)
			}
			// Another user from the same IP has their own bucket.
			if rec := e.send(t, ip, tt.method, tt.path, tt.body, tokenB, nil); rec.Code >= 300 {
				t.Errorf("another user: status %d", rec.Code)
			}
			e.wantTTLs(t)
		})
	}
}

func TestUnauthenticatedRequestIsNotCounted(t *testing.T) {
	e := newRedisEnv(t)
	wantStatus(t, e.do(t, http.MethodGet, "/feed/explore", "", ""), http.StatusUnauthorized)
	for _, path := range []string{"/healthz", "/readyz"} {
		for range 3 {
			wantStatus(t, e.do(t, http.MethodGet, path, "", ""), http.StatusOK)
		}
	}
	if keys := scanKeys(t, e.client, e.prefix); len(keys) != 0 {
		t.Errorf("keys = %v, want none", keys)
	}
}

func TestViewCountedOncePerMinute(t *testing.T) {
	e := newRedisEnv(t)
	tokenA, tokenB := e.token(t, userA), e.token(t, userB)
	views := func() int { return methodCalls(e.engagement, engagementv1.EngagementService_RecordView_FullMethodName) }
	view := func(token, id string) {
		t.Helper()
		wantStatus(t, e.do(t, http.MethodPost, "/videos/"+id+"/views", "", token), http.StatusAccepted)
	}

	view(tokenA, videoID)
	view(tokenA, videoID) // the repeat: the same 202, not forwarded
	if n := views(); n != 1 {
		t.Fatalf("RecordView calls = %d, want 1", n)
	}
	view(tokenB, videoID)
	view(tokenA, videoID2)
	if n := views(); n != 3 {
		t.Errorf("RecordView calls = %d, want 3: another user or video counts", n)
	}
	key := e.prefix + "rl:view-once:" + userA + ":" + videoID
	if ttl := e.client.PTTL(t.Context(), key).Val(); ttl <= 0 || ttl > time.Minute {
		t.Errorf("PTTL %s = %v, want within (0, 60s]", key, ttl)
	}

	// A non-canonical id gets no key and is forwarded every time; engagement-service rejects it.
	upper := strings.ToUpper(videoID)
	before := len(scanKeys(t, e.client, e.prefix))
	view(tokenA, upper)
	view(tokenA, upper)
	if n := views(); n != 5 {
		t.Errorf("RecordView calls = %d, want 5: a non-canonical id is forwarded", n)
	}
	if n := len(scanKeys(t, e.client, e.prefix)); n != before {
		t.Errorf("keys %d, want %d: a non-canonical id must write nothing", n, before)
	}
	e.wantTTLs(t)
}

func TestFailedViewReleasesItsKey(t *testing.T) {
	e := newRedisEnv(t)
	token := e.token(t, userA)
	key := e.prefix + "rl:view-once:" + userA + ":" + videoID

	e.engagement.fail(status.Error(codes.Unavailable, "engagement down"))
	wantStatus(t, e.do(t, http.MethodPost, "/videos/"+videoID+"/views", "", token), http.StatusServiceUnavailable)
	deadline := time.Now().Add(2 * time.Second)
	for e.client.Exists(t.Context(), key).Val() != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("key %s still there after the call failed", key)
		}
		time.Sleep(10 * time.Millisecond)
	}

	e.engagement.setHook(nil)
	wantStatus(t, e.do(t, http.MethodPost, "/videos/"+videoID+"/views", "", token), http.StatusAccepted)
	if n := methodCalls(e.engagement, engagementv1.EngagementService_RecordView_FullMethodName); n != 2 {
		t.Errorf("RecordView calls = %d, want 2: the retry is forwarded", n)
	}
}

func TestRedisDownPerClass(t *testing.T) {
	for _, tt := range []struct {
		name   string
		limits func(t *testing.T) *ratelimit.Limiter
	}{
		{"closed client", downLimits},
		{"unreachable host", func(t *testing.T) *ratelimit.Limiter {
			client, err := redisx.New("redis://redis.invalid:6379/15") // .invalid never resolves (RFC 6761)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = client.Close() })
			return ratelimit.New(client, "svp:test:down:")
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			logs := captureLog(t)
			e := newEnvWithLimits(t, tt.limits(t))
			const ip = "192.0.2.1:5000"
			token := e.token(t, userA)

			// Soft-closed: login stays limited, by the fallback's burst of 15 per IP.
			start := time.Now()
			for i := range 15 {
				body := fmt.Sprintf(`{"email":"user%d@example.com","password":"correct horse"}`, i)
				if rec := e.send(t, ip, http.MethodPost, "/auth/login", body, "", nil); rec.Code != http.StatusOK {
					t.Fatalf("login %d: status %d", i+1, rec.Code)
				}
			}
			wantRateLimitedSince(t, e.send(t, ip, http.MethodPost, "/auth/login", credentialsBody, "", nil), 2*time.Second, start)

			// Open: past every Redis burst, feed, like and view still go through, and every
			// view is forwarded.
			for i := range 61 {
				if rec := e.send(t, ip, http.MethodPut, "/videos/"+videoID+"/like", "", token, nil); rec.Code != http.StatusNoContent {
					t.Fatalf("like %d: status %d", i+1, rec.Code)
				}
			}
			for i := range 3 {
				if rec := e.send(t, ip, http.MethodPost, "/videos/"+videoID+"/views", "", token, nil); rec.Code != http.StatusAccepted {
					t.Fatalf("view %d: status %d", i+1, rec.Code)
				}
				if rec := e.send(t, ip, http.MethodGet, "/feed/following", "", token, nil); rec.Code != http.StatusOK {
					t.Fatalf("feed %d: status %d", i+1, rec.Code)
				}
			}
			if n := methodCalls(e.engagement, engagementv1.EngagementService_RecordView_FullMethodName); n != 3 {
				t.Errorf("RecordView calls = %d, want 3", n)
			}
			if n := strings.Count(logs.String(), "rate limit store unavailable, using fallback"); n != 1 {
				t.Errorf("WARN logged %d times, want 1", n)
			}
		})
	}
}
