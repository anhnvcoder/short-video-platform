package ratelimit

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/anhnvcoder/svp-backend/internal/redistest"
)

// testLimit has a 200 ms interval, so the Redis cases wait at most that long for a refill.
var testLimit = Limit{Rate: 5, Period: time.Second, Burst: 3}

// testStoreTimeout bounds the Redis calls of the tests that need Redis to answer: under the
// whole -race suite a call can take longer than defaultStoreTimeout and take the fallback.
const testStoreTimeout = 2 * time.Second

// fakeClock is a clock tests move by hand.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// gcra is one implementation of the GCRA step under test: allow checks key, and wait lets d pass.
type gcra struct {
	allow func(t *testing.T, key string, lim Limit) (bool, time.Duration)
	wait  func(d time.Duration)
}

// testRedis returns a client to the test database and a key prefix whose keys the test deletes
// itself, failing when any is left over.
func testRedis(t *testing.T) (*redis.Client, string) {
	t.Helper()
	client, prefix := redistest.New(t)
	t.Cleanup(func() { deleteKeys(t, client, prefix) })
	return client, prefix
}

// deleteKeys deletes the keys under prefix, then fails the test if any is still there.
func deleteKeys(t *testing.T, client *redis.Client, prefix string) {
	t.Helper()
	ctx := context.Background()
	keys := scanKeys(t, client, prefix)
	if len(keys) > 0 {
		if err := client.Del(ctx, keys...).Err(); err != nil {
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

// downClient returns a closed client: every command fails at once, as when Redis is down.
func downClient(t *testing.T) *redis.Client {
	t.Helper()
	client := redis.NewClient(&redis.Options{Addr: "127.0.0.1:6379"})
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	return client
}

// captureLog points slog.Default at a JSON handler writing to the returned buffer until the
// test ends. Tests using it must not run in parallel.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return &buf
}

func TestGCRABurstAndRefill(t *testing.T) {
	impls := map[string]func(t *testing.T) gcra{
		"redis": func(t *testing.T) gcra {
			client, prefix := testRedis(t)
			l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
			return gcra{
				allow: func(t *testing.T, key string, lim Limit) (bool, time.Duration) {
					t.Helper()
					ok, retry, err := l.allowRedis(t.Context(), lim, prefix+key)
					if err != nil {
						t.Fatalf("allowRedis: %v", err)
					}
					return ok, retry
				},
				wait: time.Sleep,
			}
		},
		"memory": func(*testing.T) gcra {
			clock := newFakeClock()
			m := newMemory(clock.Now)
			return gcra{
				allow: func(_ *testing.T, key string, lim Limit) (bool, time.Duration) { return m.allow(key, lim) },
				wait:  clock.Advance,
			}
		},
	}
	for name, newImpl := range impls {
		t.Run(name, func(t *testing.T) {
			g := newImpl(t)
			for i := range testLimit.Burst {
				if ok, _ := g.allow(t, "a", testLimit); !ok {
					t.Fatalf("request %d of the burst refused", i+1)
				}
			}
			ok, retry := g.allow(t, "a", testLimit)
			if ok {
				t.Fatal("request burst+1 allowed")
			}
			if interval := testLimit.interval(); retry <= 0 || retry > interval {
				t.Fatalf("retry after %v, want within (0, %v]", retry, interval)
			}
			if ok, _ := g.allow(t, "b", testLimit); !ok {
				t.Error("another key shares the bucket")
			}
			g.wait(retry)
			if ok, _ := g.allow(t, "a", testLimit); !ok {
				t.Fatalf("refused after waiting %v", retry)
			}
			if ok, _ := g.allow(t, "a", testLimit); ok {
				t.Error("allowed again right after the refill of one request")
			}
		})
	}
}

func TestRedisKeysExpire(t *testing.T) {
	client, prefix := testRedis(t)
	l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	ctx := t.Context()
	if ok, _ := l.Allow(ctx, Class{Name: "test", Limit: testLimit}, "id"); !ok {
		t.Fatal("first request refused")
	}
	if got := l.ClaimView(ctx, "user", "video"); got != ViewClaimed {
		t.Fatalf("ClaimView = %v, want ViewClaimed", got)
	}
	full := testLimit.interval() * time.Duration(testLimit.Burst)
	for key, maxTTL := range map[string]time.Duration{
		prefix + "rl:test:id":              full,
		prefix + "rl:view-once:user:video": viewWindow,
	} {
		ttl, err := client.PTTL(ctx, key).Result()
		if err != nil {
			t.Fatal(err)
		}
		if ttl <= 0 || ttl > maxTTL {
			t.Errorf("PTTL %s = %v, want within (0, %v]", key, ttl, maxTTL)
		}
	}
	if keys := scanKeys(t, client, prefix); len(keys) != 2 {
		t.Errorf("keys = %v, want the two above", keys)
	}
}

func TestClaimAndReleaseView(t *testing.T) {
	client, prefix := testRedis(t)
	l := New(client, prefix, WithStoreTimeout(testStoreTimeout))
	ctx := t.Context()
	steps := []struct {
		user, video string
		want        ViewClaim
	}{
		{"u1", "v1", ViewClaimed},
		{"u1", "v1", ViewRepeated},
		{"u2", "v1", ViewClaimed},
		{"u1", "v2", ViewClaimed},
	}
	for _, s := range steps {
		if got := l.ClaimView(ctx, s.user, s.video); got != s.want {
			t.Errorf("ClaimView(%s, %s) = %v, want %v", s.user, s.video, got, s.want)
		}
	}
	l.ReleaseView(ctx, "u1", "v1")
	if got := l.ClaimView(ctx, "u1", "v1"); got != ViewClaimed {
		t.Errorf("ClaimView after ReleaseView = %v, want ViewClaimed", got)
	}
}

func TestRedisDown(t *testing.T) {
	logs := captureLog(t)
	l := New(downClient(t), "svp:test:down:")
	ctx := t.Context()

	soft := Class{Name: "soft", Limit: Limit{100, time.Second, 100}, Fallback: testLimit}
	for i := range testLimit.Burst {
		if ok, _ := l.Allow(ctx, soft, "id"); !ok {
			t.Fatalf("fallback refused request %d of its burst", i+1)
		}
	}
	if ok, retry := l.Allow(ctx, soft, "id"); ok || retry <= 0 {
		t.Errorf("fallback allowed burst+1 (retry %v); a soft-closed class must stay limited", retry)
	}

	open := Class{Name: "open", Limit: testLimit}
	for i := range 2 * testLimit.Burst {
		if ok, _ := l.Allow(ctx, open, "id"); !ok {
			t.Fatalf("open class refused request %d", i+1)
		}
	}
	if got := l.ClaimView(ctx, "u", "v"); got != ViewUnchecked {
		t.Errorf("ClaimView = %v, want ViewUnchecked", got)
	}
	l.ReleaseView(ctx, "u", "v")

	if n := strings.Count(logs.String(), "rate limit store unavailable, using fallback"); n != 1 {
		t.Errorf("WARN logged %d times, want once per %v:\n%s", n, warnEvery, logs)
	}
}

// A request that is already cancelled or past its deadline makes the Redis call fail while Redis
// is healthy: the fallback still applies, but no WARN says Redis is unavailable.
func TestGoneRequestDoesNotWarn(t *testing.T) {
	client, prefix := testRedis(t)
	expired, cancelExpired := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
	defer cancelExpired()
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	for name, ctx := range map[string]context.Context{"cancelled": cancelled, "deadline exceeded": expired} {
		t.Run(name, func(t *testing.T) {
			logs := captureLog(t)
			l := New(client, prefix)
			soft := Class{Name: "soft", Limit: Limit{100, time.Second, 100}, Fallback: testLimit}
			for i := range testLimit.Burst {
				if ok, _ := l.Allow(ctx, soft, "id"); !ok {
					t.Fatalf("fallback refused request %d of its burst", i+1)
				}
			}
			if ok, _ := l.Allow(ctx, soft, "id"); ok {
				t.Error("fallback allowed burst+1; a soft-closed class must stay limited")
			}
			if ok, _ := l.Allow(ctx, Class{Name: "open", Limit: testLimit}, "id"); !ok {
				t.Error("open class refused a request")
			}
			if got := l.ClaimView(ctx, "u", "v"); got != ViewUnchecked {
				t.Errorf("ClaimView = %v, want ViewUnchecked", got)
			}
			if logs.Len() != 0 {
				t.Errorf("logged for a request that was gone:\n%s", logs)
			}
		})
	}
}

func TestRedisUnreachable(t *testing.T) {
	captureLog(t)
	// .invalid never resolves (RFC 6761), so the dial fails.
	client := redis.NewClient(&redis.Options{Addr: "redis.invalid:6379", DialTimeout: 100 * time.Millisecond, MaxRetries: -1})
	t.Cleanup(func() { _ = client.Close() })
	l := New(client, "svp:test:down:")
	start := time.Now()
	if ok, _ := l.Allow(t.Context(), LoginIP, "192.0.2.1"); !ok {
		t.Error("first login refused")
	}
	if ok, _ := l.Allow(t.Context(), Read, "user"); !ok {
		t.Error("read refused")
	}
	if l.mem.size() != 1 {
		t.Errorf("memory holds %d keys, want only the login one", l.mem.size())
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("two calls took %v; each must give up within %v", d, defaultStoreTimeout)
	}
}

func TestStoreTimeout(t *testing.T) {
	if got := New(nil, "svp:test:").storeTimeout; got != 50*time.Millisecond {
		t.Errorf("default store timeout = %v, want 50ms", got)
	}
	// A Redis call that cannot finish within the bound counts as Redis failing, even when Redis
	// is healthy: a soft-closed class takes its fallback.
	captureLog(t)
	client, prefix := testRedis(t)
	l := New(client, prefix, WithStoreTimeout(time.Nanosecond))
	if l.storeTimeout != time.Nanosecond {
		t.Fatalf("store timeout = %v, want 1ns", l.storeTimeout)
	}
	soft := Class{Name: "soft", Limit: Limit{100, time.Second, 100}, Fallback: testLimit}
	for i := range testLimit.Burst {
		if ok, _ := l.Allow(t.Context(), soft, "id"); !ok {
			t.Fatalf("fallback refused request %d of its burst", i+1)
		}
	}
	if ok, _ := l.Allow(t.Context(), soft, "id"); ok {
		t.Error("allowed burst+1: the calls did not time out into the fallback")
	}
	if l.mem.size() != 1 {
		t.Errorf("memory holds %d keys, want the soft one", l.mem.size())
	}
}

func TestMemoryConcurrent(t *testing.T) {
	clock := newFakeClock()
	m := newMemory(clock.Now)
	lim := Limit{Rate: 1, Period: time.Hour, Burst: 50}
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		allowed int
	)
	for range 200 {
		wg.Go(func() {
			if ok, _ := m.allow("same", lim); ok {
				mu.Lock()
				allowed++
				mu.Unlock()
			}
		})
	}
	wg.Wait()
	if allowed != lim.Burst {
		t.Errorf("allowed %d of 200 concurrent requests, want the burst %d", allowed, lim.Burst)
	}
}

func TestMemorySweepsExpiredKeys(t *testing.T) {
	clock := newFakeClock()
	m := newMemory(clock.Now)
	lim := Limit{Rate: 60, Period: time.Minute, Burst: 2} // full again 2 s after the last request
	for _, key := range []string{"a", "b", "c"} {
		m.allow(key, lim)
	}
	if n := m.size(); n != 3 {
		t.Fatalf("size = %d, want 3", n)
	}
	clock.Advance(sweepInterval)
	m.allow("d", lim)
	if n := m.size(); n != 1 {
		t.Errorf("size after the sweep = %d, want 1 (only d)", n)
	}
}

// size is the number of keys m holds.
func (m *memory) size() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.tats)
}
