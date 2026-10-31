package server

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	feedv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/feed/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/pagetoken"
	"github.com/anhnvcoder/svp-backend/internal/redistest"
	"github.com/anhnvcoder/svp-backend/internal/redisx"
	"github.com/anhnvcoder/svp-backend/services/feed-service/internal/store"
)

// loadMessage is the log line the drills count, one per Postgres read of a first explore page.
const loadMessage = "explore page loaded from database"

// testCacheTimeout bounds the Redis commands of cachedServer: a test run under -race with every
// package at once can take longer than the 50 ms of production for a local Redis call, and the
// tests count Postgres reads, which a timed-out cache read adds.
const testCacheTimeout = 5 * time.Second

// loadLog is a slog.Handler keeping the page_size, the cache result and the cache write result of
// every loadMessage record.
type loadLog struct {
	mu     sync.Mutex
	sizes  []int64
	caches []string
	writes []string
}

func (h *loadLog) Enabled(context.Context, slog.Level) bool { return true }

func (h *loadLog) Handle(_ context.Context, r slog.Record) error {
	if r.Message != loadMessage {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	r.Attrs(func(a slog.Attr) bool {
		switch a.Key {
		case "page_size":
			h.sizes = append(h.sizes, a.Value.Int64())
		case "cache":
			h.caches = append(h.caches, a.Value.String())
		case "cache_write":
			h.writes = append(h.writes, a.Value.String())
		}
		return true
	})
	return nil
}

func (h *loadLog) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *loadLog) WithGroup(string) slog.Handler      { return h }

func (h *loadLog) logged() []int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.sizes)
}

// cacheResults returns the cache attribute of every loadMessage record.
func (h *loadLog) cacheResults() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.caches)
}

// cacheWrites returns the cache_write attribute of every loadMessage record.
func (h *loadLog) cacheWrites() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.Clone(h.writes)
}

// newCache returns a client to the test Redis and a key prefix of the test's own. After
// redistest has deleted the test's keys, it checks none is left.
func newCache(t *testing.T) (*redis.Client, string) {
	t.Helper()
	var prefix string
	// Registered before redistest.New's cleanup, so it runs after it.
	t.Cleanup(func() {
		if prefix == "" {
			return // skipped or failed before a prefix was made
		}
		// The production timeouts of redisx are too short for a loaded test run.
		o, err := redisx.Options(os.Getenv(redistest.EnvURL))
		if err != nil {
			t.Fatal(err)
		}
		o.DialTimeout, o.ReadTimeout, o.WriteTimeout, o.PoolTimeout = testCacheTimeout, testCacheTimeout, testCacheTimeout, testCacheTimeout
		c := redis.NewClient(o)
		defer func() { _ = c.Close() }()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		keys, err := keysUnder(ctx, c, prefix)
		if err != nil {
			t.Fatal(err)
		}
		if len(keys) != 0 {
			t.Errorf("keys %v left under %s after cleanup", keys, prefix)
		}
	})
	client, p := redistest.New(t)
	prefix = p
	return client, prefix
}

// keysUnder returns every key under prefix, sorted, following SCAN's cursor until it ends.
func keysUnder(ctx context.Context, c *redis.Client, prefix string) ([]string, error) {
	var keys []string
	iter := c.Scan(ctx, 0, prefix+"*", 1000).Iterator()
	for iter.Next(ctx) {
		keys = append(keys, iter.Val())
	}
	// SCAN may return a key twice.
	slices.Sort(keys)
	return slices.Compact(keys), iter.Err()
}

// cachedServer returns a Server on the test database and a test Redis prefix of its own, with its
// log of Postgres reads of a first page. Its cache commands get testCacheTimeout, and a cached
// page stays a minute: the tests count reads, which an expiry during a slow run would add.
func cachedServer(t *testing.T) (*Server, *redis.Client, string, *loadLog) {
	t.Helper()
	needDB(t)
	client, prefix := newCache(t)
	log := &loadLog{}
	s := New(testPool, client, prefix, slog.New(log), WithCacheTimeout(testCacheTimeout))
	s.exploreCacheTTL = time.Minute
	return s, client, prefix, log
}

// Production keeps the cache budget: 50 ms per Redis command, so a slow Redis costs
// little before the Postgres read, and pages cached 5 s, the most a new video waits to reach the
// explore feed.
func TestCacheDefaults(t *testing.T) {
	s := New(nil, nil, "svp:feed:", slog.New(slog.DiscardHandler))
	if s.cacheTimeout != 50*time.Millisecond || s.exploreCacheTTL != 5*time.Second {
		t.Errorf("cache timeout %s, TTL %s; want 50ms and 5s", s.cacheTimeout, s.exploreCacheTTL)
	}
	if s := New(nil, nil, "svp:feed:", slog.New(slog.DiscardHandler), WithCacheTimeout(time.Second)); s.cacheTimeout != time.Second {
		t.Errorf("WithCacheTimeout(1s) set %s", s.cacheTimeout)
	}
}

// countReads makes every explore read of s wait delay before it reads Postgres, and returns the
// number of reads so far. A delay lets concurrent requests meet in one read.
func countReads(s *Server, delay time.Duration) func() int64 {
	var n atomic.Int64
	read := s.exploreRows
	s.exploreRows = func(ctx context.Context, p store.GetExploreFeedParams) ([]store.GetExploreFeedRow, error) {
		n.Add(1)
		time.Sleep(delay)
		return read(ctx, p)
	}
	return n.Load
}

type exploreResult struct {
	ids []string
	err error
}

// exploreAtOnce sends n first-page requests of size from n goroutines released together and
// returns what each got.
func exploreAtOnce(t *testing.T, s *Server, n int, size int32) []exploreResult {
	t.Helper()
	start := make(chan struct{})
	results := make([]exploreResult, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			<-start
			resp, err := explore(t, s, ids.New(), size, "")
			results[i] = exploreResult{ids: videoIDs(resp.GetItems()), err: err}
		})
	}
	close(start)
	wg.Wait()
	return results
}

// threeVideos empties videos and stores three, returning their ids newest first.
func threeVideos(t *testing.T) []string {
	t.Helper()
	emptyVideos(t)
	var vs []video
	for i := range 3 {
		vs = append(vs, insertVideo(t, ids.New(), now().Add(-time.Duration(i)*time.Minute)))
	}
	return newestFirst(vs)
}

func firstPageKey(prefix, size string) string {
	return prefix + "explore:v1:first:" + size
}

// N concurrent requests on an empty cache read Postgres once; a request within the TTL reads it
// no more.
func TestExploreFirstPageConcurrentMissReadsPostgresOnce(t *testing.T) {
	for _, tt := range []struct {
		name  string
		delay time.Duration
	}{
		// Every request misses the cache while the read is still going, so all of them join it.
		{name: "slow read", delay: 200 * time.Millisecond},
		// Some requests miss the cache just before the read fills it but ask for the page only
		// after the read has ended.
		{name: "fast read", delay: 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			s, client, prefix, log := cachedServer(t)
			want := threeVideos(t)
			reads := countReads(s, tt.delay)

			const n = 100
			for i, r := range exploreAtOnce(t, s, n, 0) {
				if r.err != nil || !slices.Equal(r.ids, want) {
					t.Errorf("request %d: %v, %v; want %v", i, r.ids, r.err, want)
				}
			}
			if got := reads(); got != 1 {
				t.Errorf("%d concurrent requests read Postgres %d times, want 1", n, got)
			}
			if got := log.logged(); !slices.Equal(got, []int64{DefaultPageSize}) {
				t.Errorf("%q logged with page_size %v, want once with %d", loadMessage, got, DefaultPageSize)
			}
			t.Logf("%d concurrent requests on an empty cache: %d Postgres read(s)", n, reads())

			ttl, err := client.PTTL(t.Context(), firstPageKey(prefix, "10")).Result()
			if err != nil || ttl <= 0 || ttl > s.exploreCacheTTL {
				t.Errorf("cached page TTL = %s, %v; want within (0, %s]", ttl, err, s.exploreCacheTTL)
			}
			resp, err := explore(t, s, ids.New(), 0, "")
			if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) {
				t.Errorf("cached page = %v, %v; want %v", videoIDs(resp.GetItems()), err, want)
			}
			if got := reads(); got != 1 {
				t.Errorf("a request within the TTL read Postgres again: %d reads, want 1", got)
			}
		})
	}
}

// With Redis down, the first page still comes from Postgres, still one read for concurrent
// requests, and no client sees an error.
func TestExploreFirstPageWithRedisDown(t *testing.T) {
	needDB(t)
	want := threeVideos(t)
	log := &loadLog{}
	s := New(testPool, closedRedis(), "svp:test:closed:", slog.New(log))
	reads := countReads(s, 200*time.Millisecond)

	for i, r := range exploreAtOnce(t, s, 20, 0) {
		if r.err != nil || !slices.Equal(r.ids, want) {
			t.Errorf("request %d: %v, %v; want %v", i, r.ids, r.err, want)
		}
	}
	if got := reads(); got != 1 {
		t.Errorf("20 concurrent requests read Postgres %d times, want 1", got)
	}
	// Nothing was cached, so the next request reads again.
	if _, err := explore(t, s, ids.New(), 0, ""); err != nil {
		t.Fatal(err)
	}
	if got := reads(); got != 2 {
		t.Errorf("reads = %d after a later request, want 2", got)
	}
	if got := len(log.logged()); got != 2 {
		t.Errorf("%q logged %d times, want 2", loadMessage, got)
	}
}

// The first request of a shared read giving up fails only that request: the read goes on and the
// requests waiting on it get the page.
func TestExploreFirstPageSurvivesFirstCallerCancel(t *testing.T) {
	s, _, _, _ := cachedServer(t)
	want := threeVideos(t)
	started, release := make(chan struct{}), make(chan struct{})
	var reads atomic.Int64
	var readCtxErr error
	read := s.exploreRows
	s.exploreRows = func(ctx context.Context, p store.GetExploreFeedParams) ([]store.GetExploreFeedRow, error) {
		if reads.Add(1) == 1 {
			close(started)
		}
		<-release
		readCtxErr = ctx.Err()
		return read(ctx, p)
	}

	firstCtx, cancel := context.WithCancel(t.Context())
	defer cancel()
	firstErr := make(chan error, 1)
	go func() {
		_, err := call(firstCtx, ids.New(), methodExplore, &feedv1.GetExploreFeedRequest{}, s.GetExploreFeed)
		firstErr <- err
	}()
	<-started
	const n = 10
	results := make(chan exploreResult, n)
	for range n {
		go func() {
			resp, err := explore(t, s, ids.New(), 0, "")
			results <- exploreResult{ids: videoIDs(resp.GetItems()), err: err}
		}()
	}
	time.Sleep(100 * time.Millisecond) // let them join the read
	cancel()
	if err := <-firstErr; status.Code(err) != codes.Canceled {
		t.Errorf("canceled first request = %v, want Canceled", err)
	}
	close(release)
	for range n {
		if r := <-results; r.err != nil || !slices.Equal(r.ids, want) {
			t.Errorf("waiting request: %v, %v; want %v", r.ids, r.err, want)
		}
	}
	if readCtxErr != nil {
		t.Errorf("shared read's context = %v after the first request was canceled, want live", readCtxErr)
	}
	if got := reads.Load(); got != 1 {
		t.Errorf("reads = %d, want 1", got)
	}
}

// A failed shared read fails every request waiting on it with INTERNAL, and caches nothing.
func TestExploreFirstPagePostgresErrorIsNotCached(t *testing.T) {
	s, client, prefix, _ := cachedServer(t)
	threeVideos(t)
	var reads atomic.Int64
	s.exploreRows = func(context.Context, store.GetExploreFeedParams) ([]store.GetExploreFeedRow, error) {
		reads.Add(1)
		time.Sleep(200 * time.Millisecond)
		return nil, errors.New("database is down")
	}
	for i, r := range exploreAtOnce(t, s, 10, 0) {
		if status.Code(r.err) != codes.Internal {
			t.Errorf("request %d: %v, want Internal", i, r.err)
		}
	}
	if got := reads.Load(); got != 1 {
		t.Errorf("reads = %d, want 1", got)
	}
	if n, err := client.Exists(t.Context(), firstPageKey(prefix, "10")).Result(); err != nil || n != 0 {
		t.Errorf("cache holds the page after a failed read (%d, %v), want nothing", n, err)
	}
}

// page_size is normalized before it names the key; a negative one and the caller check fail
// before the cache, and later pages bypass it.
func TestExploreCacheKeys(t *testing.T) {
	s, client, prefix, log := cachedServer(t)
	threeVideos(t)
	reads := countReads(s, 0)

	for _, size := range []int32{0, 10, 60} {
		if _, err := explore(t, s, ids.New(), size, ""); err != nil {
			t.Fatal(err)
		}
	}
	if got := log.logged(); !slices.Equal(got, []int64{10, 50}) {
		t.Errorf("page sizes read from Postgres = %v, want [10 50] (0 and 10 share a key)", got)
	}
	keys, err := keysUnder(t.Context(), client, prefix)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{firstPageKey(prefix, "10"), firstPageKey(prefix, "50")}; !slices.Equal(keys, want) {
		t.Errorf("keys = %v, want %v", keys, want)
	}

	_, err = explore(t, s, ids.New(), -1, "")
	wantError(t, err, codes.InvalidArgument, ReasonInvalidPageSize)
	_, err = explore(t, s, "", 0, "")
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("cached page without a caller = %v, want Unauthenticated", err)
	}
	if got := reads(); got != 2 {
		t.Errorf("reads = %d, want 2", got)
	}

	// A later page reads Postgres every time and writes no key.
	token := pagetoken.Encode(pagetoken.Cursor{Time: now()})
	for range 2 {
		if _, err := explore(t, s, ids.New(), 0, token); err != nil {
			t.Fatal(err)
		}
	}
	if got := reads(); got != 4 {
		t.Errorf("reads = %d after two later pages, want 4", got)
	}
	if keys, err := keysUnder(t.Context(), client, prefix); err != nil || len(keys) != 2 {
		t.Errorf("keys after later pages = %v, %v; want the same two", keys, err)
	}
}

// Cached bytes that do not decode are a miss: the page is read from Postgres and cached again.
func TestExploreCorruptCacheIsAMiss(t *testing.T) {
	s, client, prefix, _ := cachedServer(t)
	want := threeVideos(t)
	reads := countReads(s, 0)
	key := firstPageKey(prefix, "10")
	// Field 1, length 5, but one byte follows.
	if err := client.Set(t.Context(), key, []byte{0x0a, 0x05, 0x01}, ExploreCacheTTL).Err(); err != nil {
		t.Fatal(err)
	}
	resp, err := explore(t, s, ids.New(), 0, "")
	if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) {
		t.Fatalf("page = %v, %v; want %v", videoIDs(resp.GetItems()), err, want)
	}
	if got := reads(); got != 1 {
		t.Errorf("reads = %d, want 1", got)
	}
	resp, err = explore(t, s, ids.New(), 0, "")
	if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) || reads() != 1 {
		t.Errorf("page after refill = %v, %v with %d reads; want %v from the cache", videoIDs(resp.GetItems()), err, reads(), want)
	}
}

// A cache read that fails because the request is gone (cancelled, or past its deadline) is a
// miss without a WARN: Redis is healthy. A live request on a Redis that is down still warns.
func TestExploreCacheReadOfGoneRequestDoesNotWarn(t *testing.T) {
	client, prefix := newCache(t)
	expired, cancelExpired := context.WithDeadline(t.Context(), time.Now().Add(-time.Second))
	defer cancelExpired()
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	for name, ctx := range map[string]context.Context{"cancelled": cancelled, "deadline exceeded": expired} {
		t.Run(name, func(t *testing.T) {
			var logs bytes.Buffer
			s := New(nil, client, prefix, slog.New(slog.NewJSONHandler(&logs, nil)))
			if _, _, got := s.cachedExplorePage(ctx, firstPageKey(prefix, "10")); got == cacheHit {
				t.Error("cachedExplorePage reported a hit")
			}
			if logs.Len() != 0 {
				t.Errorf("logged for a request that was gone:\n%s", &logs)
			}
		})
	}

	var logs bytes.Buffer
	s := New(nil, closedRedis(), "svp:test:closed:", slog.New(slog.NewJSONHandler(&logs, nil)))
	if _, _, got := s.cachedExplorePage(t.Context(), firstPageKey("svp:test:closed:", "10")); got == cacheHit {
		t.Error("cachedExplorePage reported a hit with Redis down")
	}
	if !strings.Contains(logs.String(), `"msg":"read explore cache"`) {
		t.Errorf("no WARN for Redis down; log:\n%s", &logs)
	}
}

// The Postgres read of N concurrent requests on an empty cache is logged once, as a cache miss
// whose page was then cached.
func TestExploreLoadLogsCacheMiss(t *testing.T) {
	s, _, _, log := cachedServer(t)
	want := threeVideos(t)
	countReads(s, 200*time.Millisecond)

	for i, r := range exploreAtOnce(t, s, 50, 0) {
		if r.err != nil || !slices.Equal(r.ids, want) {
			t.Errorf("request %d: %v, %v; want %v", i, r.ids, r.err, want)
		}
	}
	if got := log.cacheResults(); !slices.Equal(got, []string{"miss"}) {
		t.Errorf("%q logged with cache %v, want once with miss", loadMessage, got)
	}
	if got := log.cacheWrites(); !slices.Equal(got, []string{"ok"}) {
		t.Errorf("%q logged with cache_write %v, want once with ok", loadMessage, got)
	}
}

// silentRedis returns a client to a TCP listener of the test's own that accepts connections and
// never answers, so every command runs out of time: a Redis too slow for the cache budget.
func silentRedis(t *testing.T) *redis.Client {
	t.Helper()
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var conns []net.Conn
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
		}
	}()
	// The production client: redisx's 50 ms timeouts, deadlines from the context, no retry.
	client, err := redisx.New("redis://" + ln.Addr().String() + "/15")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = client.Close()
		_ = ln.Close()
		<-done
		mu.Lock()
		defer mu.Unlock()
		for _, c := range conns {
			_ = c.Close()
		}
	})
	return client
}

// With Redis too slow to answer, every request still gets the page from Postgres, and every
// Postgres read is logged as caused by a cache timeout: one line per shared read that ran.
func TestExploreLoadLogsCacheTimeout(t *testing.T) {
	needDB(t)
	want := threeVideos(t)
	log := &loadLog{}
	s := New(testPool, silentRedis(t), "svp:test:silent:", slog.New(log), WithCacheTimeout(20*time.Millisecond))
	reads := countReads(s, 50*time.Millisecond)

	const n = 50
	for i, r := range exploreAtOnce(t, s, n, 0) {
		if r.err != nil || !slices.Equal(r.ids, want) {
			t.Errorf("request %d: %v, %v; want %v", i, r.ids, r.err, want)
		}
	}
	got := log.cacheResults()
	if len(got) == 0 || int64(len(got)) != reads() {
		t.Errorf("%q logged %d times for %d Postgres reads, want one line per read and at least one", loadMessage, len(got), reads())
	}
	for i, c := range got {
		if c != "timeout" {
			t.Errorf("load %d logged with cache %q, want timeout", i, c)
		}
	}
	t.Logf("%d concurrent requests on a silent Redis: %d shared Postgres read(s), each logged cache=timeout", n, reads())
}

// Caching the page read from Postgres on a Redis too slow to answer is logged as a write timeout
// on the load line: the page may not be stored, so the next shared read finds none because Redis
// was slow.
func TestExploreLoadLogsCacheWriteTimeout(t *testing.T) {
	needDB(t)
	want := threeVideos(t)
	log := &loadLog{}
	s := New(testPool, silentRedis(t), "svp:test:silent:", slog.New(log), WithCacheTimeout(20*time.Millisecond))

	resp, err := explore(t, s, ids.New(), 0, "")
	if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) {
		t.Fatalf("page = %v, %v; want %v", videoIDs(resp.GetItems()), err, want)
	}
	if got := log.cacheWrites(); !slices.Equal(got, []string{"timeout"}) {
		t.Errorf("%q logged with cache_write %v, want once with timeout", loadMessage, got)
	}
}

// A Redis failure other than a timeout, and cached bytes that do not decode, are logged as a
// cache error on the Postgres read; with Redis down, caching the page fails the same way.
func TestExploreLoadLogsCacheError(t *testing.T) {
	t.Run("redis down", func(t *testing.T) {
		needDB(t)
		want := threeVideos(t)
		log := &loadLog{}
		s := New(testPool, closedRedis(), "svp:test:closed:", slog.New(log))
		resp, err := explore(t, s, ids.New(), 0, "")
		if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) {
			t.Fatalf("page = %v, %v; want %v", videoIDs(resp.GetItems()), err, want)
		}
		if got := log.cacheResults(); !slices.Equal(got, []string{"error"}) {
			t.Errorf("%q logged with cache %v, want once with error", loadMessage, got)
		}
		if got := log.cacheWrites(); !slices.Equal(got, []string{"error"}) {
			t.Errorf("%q logged with cache_write %v, want once with error", loadMessage, got)
		}
	})
	t.Run("corrupt page", func(t *testing.T) {
		s, client, prefix, log := cachedServer(t)
		want := threeVideos(t)
		// Field 1, length 5, but one byte follows.
		if err := client.Set(t.Context(), firstPageKey(prefix, "10"), []byte{0x0a, 0x05, 0x01}, ExploreCacheTTL).Err(); err != nil {
			t.Fatal(err)
		}
		resp, err := explore(t, s, ids.New(), 0, "")
		if err != nil || !slices.Equal(videoIDs(resp.GetItems()), want) {
			t.Fatalf("page = %v, %v; want %v", videoIDs(resp.GetItems()), err, want)
		}
		if got := log.cacheResults(); !slices.Equal(got, []string{"error"}) {
			t.Errorf("%q logged with cache %v, want once with error", loadMessage, got)
		}
	})
}
