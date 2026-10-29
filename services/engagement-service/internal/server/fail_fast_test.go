package server

import (
	"bytes"
	"context"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"

	engagementv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/pgpool"
	"github.com/anhnvcoder/short-video-platform/internal/pgretry/pgretrytest"
)

// failMargin is how much later than writeTimeout a write may fail: the race detector and a busy
// machine slow everything down, and the bound only has to stay well under the gateway's 3 s.
const failMargin = 500 * time.Millisecond

// countingTracer counts the statements a pool sends (Exec, Query, QueryRow; BEGIN and COMMIT
// are statements too).
type countingTracer struct{ n atomic.Int64 }

func (c *countingTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	c.n.Add(1)
	return ctx
}

func (c *countingTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// testDBHost returns host:port of the package's test database.
func testDBHost() string {
	cc := testPool.Config().ConnConfig
	return net.JoinHostPort(cc.Host, strconv.Itoa(int(cc.Port)))
}

// newTestPool returns a pool of at most maxConns connections to the package's test database
// through host, as pgpool sizes and bounds it, that has not connected yet. tracer may be nil.
func newTestPool(t *testing.T, host string, maxConns int32, tracer pgx.QueryTracer) *pgxpool.Pool {
	t.Helper()
	u, err := url.Parse(testPool.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	u.Host = host
	cfg, err := pgxpool.ParseConfig(u.String())
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = maxConns
	cfg.ConnConfig.ConnectTimeout = pgpool.ConnectTimeout
	cfg.ConnConfig.Tracer = tracer
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// serveGRPC serves s over bufconn behind the caller interceptor, as the service does, and returns
// a client to it.
func serveGRPC(t *testing.T, s *Server) engagementv1.EngagementServiceClient {
	t.Helper()
	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer(grpc.UnaryInterceptor(CallerInterceptor()))
	engagementv1.RegisterEngagementServiceServer(srv, s)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return engagementv1.NewEngagementServiceClient(conn)
}

// rpc is Like or Unlike over gRPC.
type rpc func(t *testing.T, c engagementv1.EngagementServiceClient, caller, videoID string) (metadata.MD, error)

func likeRPC(t *testing.T, c engagementv1.EngagementServiceClient, caller, videoID string) (metadata.MD, error) {
	t.Helper()
	var trailer metadata.MD
	ctx := metadata.AppendToOutgoingContext(t.Context(), callerid.MetadataKey, caller)
	_, err := c.Like(ctx, &engagementv1.LikeRequest{VideoId: videoID}, grpc.Trailer(&trailer))
	return trailer, err
}

func unlikeRPC(t *testing.T, c engagementv1.EngagementServiceClient, caller, videoID string) (metadata.MD, error) {
	t.Helper()
	var trailer metadata.MD
	ctx := metadata.AppendToOutgoingContext(t.Context(), callerid.MetadataKey, caller)
	_, err := c.Unlike(ctx, &engagementv1.UnlikeRequest{VideoId: videoID}, grpc.Trailer(&trailer))
	return trailer, err
}

// wantDependencyUnavailable fails unless err is UNAVAILABLE with ErrorInfo
// DEPENDENCY_UNAVAILABLE and trailer tells the client's retry policy not to retry.
func wantDependencyUnavailable(t *testing.T, err error, trailer metadata.MD) {
	t.Helper()
	wantError(t, err, codes.Unavailable, ReasonDependencyUnavailable)
	if got := trailer.Get(retryPushbackKey); len(got) != 1 || got[0] != "-1" {
		t.Errorf("trailer %s = %q, want [\"-1\"]", retryPushbackKey, got)
	}
	if msg := status.Convert(err).Message(); strings.Contains(msg, "postgres") || strings.Contains(msg, testDBHost()) {
		t.Errorf("message %q carries database details", msg)
	}
}

// Like and Unlike each send one statement, whether they change a row or not: no BEGIN, no second
// statement, no COMMIT.
func TestLikeAndUnlikeSendOneStatement(t *testing.T) {
	needDB(t)
	tracer := &countingTracer{}
	pool := newTestPool(t, testDBHost(), 2, tracer)
	s, _ := newServer(nil)
	s = New(pool, pool, nil, s.logger)
	caller, videoID := ids.New(), ids.New()
	for _, step := range []struct {
		name string
		run  func() error
	}{
		{"like", func() error { return like(t, s, caller, videoID) }},
		{"like again", func() error { return like(t, s, caller, videoID) }},
		{"unlike", func() error { return unlike(t, s, caller, videoID) }},
		{"unlike again", func() error { return unlike(t, s, caller, videoID) }},
	} {
		tracer.n.Store(0)
		if err := step.run(); err != nil {
			t.Fatalf("%s: %v", step.name, err)
		}
		if got := tracer.n.Load(); got != 1 {
			t.Errorf("%s sent %d statements, want 1", step.name, got)
		}
	}
	if likes, count := likeRows(t, videoID); likes != 0 || count != 0 {
		t.Errorf("likes rows = %d, like_count = %d, want 0 and 0", likes, count)
	}
}

// Many likes of one user on one video at once count once, and as many unlikes at once take it
// back once.
func TestConcurrentLikesOfOneUserCountOnce(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	caller, videoID := ids.New(), ids.New()
	for _, step := range []struct {
		name               string
		run                func() error
		wantLikes, wantCnt int64
	}{
		{"like", func() error { return like(t, s, caller, videoID) }, 1, 1},
		{"unlike", func() error { return unlike(t, s, caller, videoID) }, 0, 0},
	} {
		var wg sync.WaitGroup
		errs := make(chan error, 16)
		for range 16 {
			wg.Go(func() {
				if err := step.run(); err != nil {
					errs <- err
				}
			})
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Fatalf("%s: %v", step.name, err)
		}
		if likes, count := likeRows(t, videoID); likes != step.wantLikes || count != step.wantCnt {
			t.Errorf("after concurrent %s: likes rows = %d, like_count = %d, want %d and %d",
				step.name, likes, count, step.wantLikes, step.wantCnt)
		}
	}
}

// Through a database 40 ms a round trip away, a like succeeds on a pool that has no connection
// yet, on the connection it then keeps, and on the new connection that replaces one cut.
func TestLikeThroughSmallLatency(t *testing.T) {
	needDB(t)
	proxy := pgretrytest.LatencyProxy(t, testDBHost(), 20*time.Millisecond)
	pool := newTestPool(t, proxy.Addr(), 2, nil)
	s, _ := newServer(nil)
	c := serveGRPC(t, New(pool, pool, nil, s.logger))
	caller := ids.New()

	if _, err := likeRPC(t, c, caller, ids.New()); err != nil {
		t.Fatalf("like on a pool without connections: %v", err)
	}
	if _, err := likeRPC(t, c, caller, ids.New()); err != nil {
		t.Fatalf("like on the pooled connection: %v", err)
	}

	accepted := proxy.Accepted()
	proxy.CutAll()
	// The pooled connection is dead and pgx learns it on its first use: that like may fail,
	// as unavailable, and the next one runs on a new connection with no prepared statement.
	videoID := ids.New()
	trailer, err := likeRPC(t, c, caller, videoID)
	if err != nil {
		wantDependencyUnavailable(t, err, trailer)
		if _, err := likeRPC(t, c, caller, videoID); err != nil {
			t.Fatalf("like on a new connection after the cut: %v", err)
		}
	}
	if proxy.Accepted() == accepted {
		t.Error("no new connection after the cut")
	}
	if likes, count := likeRows(t, videoID); likes != 1 || count != 1 {
		t.Errorf("likes rows = %d, like_count = %d, want 1 and 1", likes, count)
	}
}

// Through a database 400 ms a round trip away, a like on a pooled connection that has run the
// statement before takes one round trip and succeeds; a like that needs a new connection (connect,
// startup, prepare, execute: 1.2 s at least) is UNAVAILABLE once writeTimeout runs out, and the
// pooled connection still serves the next like.
func TestLikeThroughLargeLatency(t *testing.T) {
	needDB(t)
	proxy := pgretrytest.LatencyProxy(t, testDBHost(), 0)
	pool := newTestPool(t, proxy.Addr(), 4, nil)
	s, _ := newServer(nil)
	c := serveGRPC(t, New(pool, pool, nil, s.logger))
	if _, err := likeRPC(t, c, ids.New(), ids.New()); err != nil {
		t.Fatalf("warm-up like: %v", err)
	}
	proxy.SetDelay(200 * time.Millisecond)

	start := time.Now()
	if _, err := likeRPC(t, c, ids.New(), ids.New()); err != nil {
		t.Fatalf("like on the pooled connection: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 400*time.Millisecond {
		t.Fatalf("like took %v, under one round trip through the proxy: the delay does not apply", elapsed)
	}

	// Two likes at once: one gets the pooled connection, the other dials a new one.
	type result struct {
		err     error
		trailer metadata.MD
		elapsed time.Duration
	}
	results := make(chan result, 2)
	for range 2 {
		go func() {
			start := time.Now()
			trailer, err := likeRPC(t, c, ids.New(), ids.New())
			results <- result{err, trailer, time.Since(start)}
		}()
	}
	var failed int
	for range 2 {
		r := <-results
		if r.err == nil {
			continue
		}
		failed++
		wantDependencyUnavailable(t, r.err, r.trailer)
		if r.elapsed < writeTimeout || r.elapsed > writeTimeout+failMargin {
			t.Errorf("failed like took %v, want %v (+%v at most)", r.elapsed, writeTimeout, failMargin)
		}
	}
	if failed != 1 {
		t.Errorf("%d of two likes failed, want the one on a new connection", failed)
	}

	if _, err := likeRPC(t, c, ids.New(), ids.New()); err != nil {
		t.Fatalf("like on the pooled connection after a failed one: %v", err)
	}
}

// A connection cut after Postgres got the statement but before the answer came back is
// UNAVAILABLE, not INTERNAL, and the server does not send the statement again; the client's next
// call leaves the count right whether the cut statement ran or not.
func TestCutDuringWriteIsUnavailable(t *testing.T) {
	needDB(t)
	for _, tt := range []struct {
		name     string
		before   rpc
		write    rpc
		wantRows int64
	}{
		{name: "like", write: likeRPC, wantRows: 1},
		{name: "unlike", before: likeRPC, write: unlikeRPC, wantRows: 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			// The answer takes 50 ms to come back, so the cut always comes first.
			proxy := pgretrytest.LatencyProxy(t, testDBHost(), 50*time.Millisecond)
			tracer := &countingTracer{}
			pool := newTestPool(t, proxy.Addr(), 2, tracer)
			s, _ := newServer(nil)
			c := serveGRPC(t, New(pool, pool, nil, s.logger))
			caller, videoID := ids.New(), ids.New()
			if tt.before != nil {
				if _, err := tt.before(t, c, caller, videoID); err != nil {
					t.Fatal(err)
				}
			}

			// The statement's parameters go out in binary: the video id's 16 bytes mark its chunk.
			id := uuid.MustParse(videoID)
			proxy.CutAfter(func(chunk []byte) bool { return bytes.Contains(chunk, id[:]) })
			tracer.n.Store(0)
			trailer, err := tt.write(t, c, caller, videoID)
			wantDependencyUnavailable(t, err, trailer)
			if got := tracer.n.Load(); got != 1 {
				t.Errorf("server sent %d statements, want 1: no retry of its own", got)
			}

			if _, err := tt.write(t, c, caller, videoID); err != nil {
				t.Fatalf("second %s: %v", tt.name, err)
			}
			if likes, count := likeRows(t, videoID); likes != tt.wantRows || count != tt.wantRows {
				t.Errorf("likes rows = %d, like_count = %d, want %d and %d", likes, count, tt.wantRows, tt.wantRows)
			}
		})
	}
}

// A caller whose own deadline runs out, or who cancels, before writeTimeout gets
// DEADLINE_EXCEEDED or CANCELLED as before, not DEPENDENCY_UNAVAILABLE.
func TestCallerDeadlineBeforeWriteTimeout(t *testing.T) {
	needDB(t)
	proxy := pgretrytest.LatencyProxy(t, testDBHost(), 0)
	pool := newTestPool(t, proxy.Addr(), 2, nil)
	s, _ := newServer(nil)
	s = New(pool, pool, nil, s.logger)
	if err := like(t, s, ids.New(), ids.New()); err != nil {
		t.Fatalf("warm-up like: %v", err)
	}
	proxy.SetDelay(200 * time.Millisecond)

	ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
	defer cancel()
	_, err := call(ctx, ids.New(), methodLike, &engagementv1.LikeRequest{VideoId: ids.New()}, s.Like)
	if status.Code(err) != codes.DeadlineExceeded || grpcerr.Reason(err) != "" {
		t.Errorf("like past the caller's deadline = %v, want DEADLINE_EXCEEDED without a reason", err)
	}

	ctx, cancel = context.WithCancel(t.Context())
	time.AfterFunc(150*time.Millisecond, cancel)
	_, err = call(ctx, ids.New(), methodUnlike, &engagementv1.UnlikeRequest{VideoId: ids.New()}, s.Unlike)
	if status.Code(err) != codes.Canceled || grpcerr.Reason(err) != "" {
		t.Errorf("unlike canceled by the caller = %v, want CANCELLED without a reason", err)
	}
}

// A refused connection is UNAVAILABLE at once, without waiting for writeTimeout.
func TestRefusedDatabaseFailsFast(t *testing.T) {
	needDB(t)
	pool := newTestPool(t, pgretrytest.ClosedPort(t), 2, nil)
	s, _ := newServer(nil)
	c := serveGRPC(t, New(pool, pool, nil, s.logger))
	for _, write := range []rpc{likeRPC, unlikeRPC} {
		start := time.Now()
		trailer, err := write(t, c, ids.New(), ids.New())
		wantDependencyUnavailable(t, err, trailer)
		if elapsed := time.Since(start); elapsed > writeTimeout/2 {
			t.Errorf("refused write took %v, want well under %v", elapsed, writeTimeout)
		}
	}
}

// statsChurn runs waves of GetStats through readProxy, each call canceled at 100 ms as the
// gateway does, while likes run one after the other on a direct write pool. With warmReads the
// read pool starts with a connection, else with none. It checks that the read pool never holds
// more than its size, connections being dialed or cleaned up after a cancel included, that the
// write pool opens no connection, and that every like succeeds within writeTimeout. It returns
// the read pool and the most connections it had being dialed at once.
func statsChurn(t *testing.T, readProxy *pgretrytest.Proxy, delay, waveGap time.Duration, waves int, warmReads bool) (*pgxpool.Pool, int32) {
	t.Helper()
	const readConns, writeConns = 5, 5 // DATABASE_MAX_CONNS=10
	readPool := newTestPool(t, readProxy.Addr(), readConns, nil)
	writePool := newTestPool(t, testDBHost(), writeConns, nil)
	s, _ := newServer(nil)
	s = New(readPool, writePool, nil, s.logger)
	if err := like(t, s, ids.New(), ids.New()); err != nil {
		t.Fatalf("warm-up like: %v", err)
	}
	if warmReads {
		if _, err := getStats(t, s, ids.New(), ids.New()); err != nil {
			t.Fatalf("warm-up GetStats: %v", err)
		}
	}
	readProxy.SetDelay(delay)
	writeNew := writePool.Stat().NewConnsCount()

	stop := make(chan struct{})
	var bg sync.WaitGroup
	var maxInUse, maxTotal, maxDialing atomic.Int32
	bg.Go(func() {
		for {
			st := readPool.Stat()
			setMax(&maxInUse, st.ConstructingConns()+st.AcquiredConns())
			setMax(&maxTotal, st.TotalConns())
			setMax(&maxDialing, st.ConstructingConns())
			select {
			case <-stop:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	})
	likeErrs := make(chan error, 1000)
	bg.Go(func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			start := time.Now()
			err := like(t, s, ids.New(), ids.New())
			if err == nil && time.Since(start) > writeTimeout {
				t.Errorf("like took %v during the GetStats churn", time.Since(start))
			}
			if err != nil {
				likeErrs <- err
			}
		}
	})

	start := time.Now()
	for w := range waves {
		if wait := time.Until(start.Add(time.Duration(w) * waveGap)); wait > 0 {
			time.Sleep(wait)
		}
		var wg sync.WaitGroup
		for range 2 * readConns {
			wg.Go(func() {
				ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
				defer cancel()
				_, _ = call(ctx, ids.New(), methodGetStats, &engagementv1.GetStatsRequest{VideoIds: []string{ids.New()}}, s.GetStats)
			})
		}
		wg.Wait()
	}
	close(stop)
	bg.Wait()
	close(likeErrs)
	for err := range likeErrs {
		t.Errorf("like during the GetStats churn: %v", err)
	}

	if got := maxInUse.Load(); got > readConns {
		t.Errorf("read pool had %d connections dialing or in use at once, want at most %d", got, readConns)
	}
	if got := maxTotal.Load(); got > readConns {
		t.Errorf("read pool had %d connections at once, want at most %d", got, readConns)
	}
	if got := writePool.Stat().NewConnsCount(); got != writeNew {
		t.Errorf("write pool opened %d connections during the GetStats churn, want 0", got-writeNew)
	}
	return readPool, maxDialing.Load()
}

func setMax(m *atomic.Int32, v int32) {
	for {
		old := m.Load()
		if v <= old || m.CompareAndSwap(old, v) {
			return
		}
	}
}

// GetStats canceled at 100 ms again and again by a database 400 ms a round trip away makes the
// read pool close and dial connections, and only the read pool: likes go on.
func TestCanceledStatsChurnOnlyTheReadPool(t *testing.T) {
	needDB(t)
	proxy := pgretrytest.LatencyProxy(t, testDBHost(), 0)
	accepted := proxy.Accepted()
	statsChurn(t, proxy, 200*time.Millisecond, 300*time.Millisecond, 4, true)
	if proxy.Accepted() == accepted {
		t.Error("the read pool opened no connection: the GetStats calls did not churn it")
	}
}

// Handshakes that take more than a second, over two waves of GetStats a second apart, each with
// more calls than the read pool has connections: the dials go on after the calls are canceled,
// yet the read pool never holds more than its size, likes go on, and closing the pool does not
// wait for the dials. The read pool starts empty, so every slot it fills is a dial. (A connection
// whose query was canceled is another matter: pgx cleans it up in the background, a cancel request
// and a drain bounded by 15 s, and the pool keeps its slot, and Close waits, until that ends.)
func TestHungHandshakesStayInTheReadPool(t *testing.T) {
	needDB(t)
	proxy := pgretrytest.LatencyProxy(t, testDBHost(), 0)
	// 1 s each way: the startup message alone waits 2 s for its answer.
	readPool, dialing := statsChurn(t, proxy, time.Second, 1100*time.Millisecond, 2, false)
	if dialing != 5 {
		t.Errorf("read pool had at most %d connections dialing at once, want all 5: the dials should outlive the canceled calls", dialing)
	}
	if got := readPool.Stat().ConstructingConns(); got == 0 {
		t.Fatal("no dial under way when the pool closes")
	}
	start := time.Now()
	readPool.Close()
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("Close took %v with dials under way, want under 1s (connect timeout %v)", elapsed, pgpool.ConnectTimeout)
	}
}
