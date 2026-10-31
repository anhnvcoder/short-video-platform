package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	engagementv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/engagement/v1"
	"github.com/anhnvcoder/svp-backend/internal/callerid"
	"github.com/anhnvcoder/svp-backend/internal/grpcerr"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/logx"
	"github.com/anhnvcoder/svp-backend/internal/pgtest"
	"github.com/anhnvcoder/svp-backend/services/engagement-service/migrations"
)

const (
	methodLike       = "/svp.engagement.v1.EngagementService/Like"
	methodUnlike     = "/svp.engagement.v1.EngagementService/Unlike"
	methodRecordView = "/svp.engagement.v1.EngagementService/RecordView"
	methodGetStats   = "/svp.engagement.v1.EngagementService/GetStats"
)

// testPool is the migrated database shared by the package's tests; nil when SVP_TEST_POSTGRES_URL
// is unset, and then tests that need it skip.
var (
	testPool  *pgxpool.Pool
	skipNoURL string
)

func TestMain(m *testing.M) {
	pool, cleanup, err := pgtest.Create(context.Background(), "svp_engagement_server_test", migrations.FS)
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

// newServer returns a Server on the test database (nil without one: only validation paths and
// RecordView work) producing with producer, and the buffer its logs go to.
func newServer(producer *kgo.Client) (*Server, *logBuffer) {
	logs := &logBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	return New(testPool, testPool, producer, logger), logs
}

// newServerWithoutDB is newServer with no database at all, for tests whose code path must not
// reach it: a call that does panics on the nil pool instead of passing quietly.
func newServerWithoutDB(producer *kgo.Client) (*Server, *logBuffer) {
	logs := &logBuffer{}
	logger := slog.New(logx.NewHandler(slog.NewJSONHandler(logs, nil)))
	return New(nil, nil, producer, logger), logs
}

// call runs handler the way the gRPC server does: through the callerid interceptor, with caller
// as x-user-id metadata (none when caller is "").
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

func like(t *testing.T, s *Server, caller, videoID string) error {
	t.Helper()
	_, err := call(t.Context(), caller, methodLike, &engagementv1.LikeRequest{VideoId: videoID}, s.Like)
	return err
}

func unlike(t *testing.T, s *Server, caller, videoID string) error {
	t.Helper()
	_, err := call(t.Context(), caller, methodUnlike, &engagementv1.UnlikeRequest{VideoId: videoID}, s.Unlike)
	return err
}

func getStats(t *testing.T, s *Server, caller string, videoIDs ...string) (*engagementv1.GetStatsResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodGetStats, &engagementv1.GetStatsRequest{VideoIds: videoIDs}, s.GetStats)
}

// statsOf returns the one VideoStats of videoID as caller sees it.
func statsOf(t *testing.T, s *Server, caller, videoID string) *engagementv1.VideoStats {
	t.Helper()
	resp, err := getStats(t, s, caller, videoID)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetStats()) != 1 {
		t.Fatalf("got %d stats, want 1", len(resp.GetStats()))
	}
	return resp.GetStats()[0]
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

// likeRows returns count(*) of likes and the stored like_count (-1 without a like_counts row)
// for videoID.
func likeRows(t *testing.T, videoID string) (likes, likeCount int64) {
	t.Helper()
	err := testPool.QueryRow(t.Context(), `
		SELECT (SELECT count(*) FROM likes WHERE video_id = $1),
		       COALESCE((SELECT like_count FROM like_counts WHERE video_id = $1), -1)`, videoID,
	).Scan(&likes, &likeCount)
	if err != nil {
		t.Fatal(err)
	}
	return likes, likeCount
}

// Every RPC but GetStats requires a caller; GetStats rejects a present but invalid one.
func TestEveryRPCRequiresCaller(t *testing.T) {
	s, _ := newServer(nil)
	videoID := ids.New()
	for _, caller := range []string{"", "not-a-uuid", strings.ToUpper(ids.New())} {
		_, err := call(t.Context(), caller, methodLike, &engagementv1.LikeRequest{VideoId: videoID}, s.Like)
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
		_, err = call(t.Context(), caller, methodUnlike, &engagementv1.UnlikeRequest{VideoId: videoID}, s.Unlike)
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
		_, err = call(t.Context(), caller, methodRecordView, &engagementv1.RecordViewRequest{VideoId: videoID}, s.RecordView)
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
		if caller == "" {
			continue
		}
		_, err = call(t.Context(), caller, methodGetStats, &engagementv1.GetStatsRequest{VideoIds: []string{videoID}}, s.GetStats)
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
	}
}

// A server wired without the interceptor must not serve an anonymous caller where one is required.
// GetStats then answers as for a call without caller, which only reads public counters.
func TestHandlersFailClosedWithoutInterceptor(t *testing.T) {
	s, _ := newServer(nil)
	videoID := ids.New()
	_, err := s.Like(t.Context(), &engagementv1.LikeRequest{VideoId: videoID})
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("Like code = %s, want Unauthenticated", status.Code(err))
	}
	_, err = s.RecordView(t.Context(), &engagementv1.RecordViewRequest{VideoId: videoID})
	if status.Code(err) != codes.Unauthenticated {
		t.Errorf("RecordView code = %s, want Unauthenticated", status.Code(err))
	}
	if _, err = s.GetStats(t.Context(), &engagementv1.GetStatsRequest{}); err != nil {
		t.Errorf("GetStats without caller = %v, want no error", err)
	}
}

func TestInvalidVideoIDIsRejected(t *testing.T) {
	// No database and no producer: validation runs before either is used.
	s, _ := newServerWithoutDB(nil)
	caller := ids.New()
	for _, id := range []string{"", "not-a-uuid", strings.ToUpper(ids.New()), "{" + ids.New() + "}"} {
		_, err := call(t.Context(), caller, methodLike, &engagementv1.LikeRequest{VideoId: id}, s.Like)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
		_, err = call(t.Context(), caller, methodUnlike, &engagementv1.UnlikeRequest{VideoId: id}, s.Unlike)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
		_, err = call(t.Context(), caller, methodRecordView, &engagementv1.RecordViewRequest{VideoId: id}, s.RecordView)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
		_, err = getStats(t, s, caller, ids.New(), id)
		wantError(t, err, codes.InvalidArgument, ReasonInvalidVideoID)
	}
}

func TestLikeTwiceCountsOnce(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	caller, videoID := ids.New(), ids.New()
	for range 2 {
		if err := like(t, s, caller, videoID); err != nil {
			t.Fatal(err)
		}
	}
	got := statsOf(t, s, caller, videoID)
	if got.GetLikeCount() != 1 || !got.GetLikedByMe() {
		t.Errorf("stats = %v, want like_count 1, liked_by_me true", got)
	}
	if likes, count := likeRows(t, videoID); likes != 1 || count != 1 {
		t.Errorf("likes rows = %d, like_count = %d, want 1 and 1", likes, count)
	}
}

func TestUnlikeNeverGoesNegative(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	caller, other, videoID := ids.New(), ids.New(), ids.New()

	// Unliking a video nobody liked creates no counter.
	if err := unlike(t, s, caller, videoID); err != nil {
		t.Fatal(err)
	}
	if likes, count := likeRows(t, videoID); likes != 0 || count != -1 {
		t.Errorf("after unlike without like: likes rows = %d, like_count = %d, want 0 and no row", likes, count)
	}

	// Another user's like is not removed by the caller's unlike, and unliking twice takes one.
	for _, step := range []func() error{
		func() error { return like(t, s, other, videoID) },
		func() error { return like(t, s, caller, videoID) },
		func() error { return unlike(t, s, caller, videoID) },
		func() error { return unlike(t, s, caller, videoID) },
	} {
		if err := step(); err != nil {
			t.Fatal(err)
		}
	}
	if got := statsOf(t, s, caller, videoID); got.GetLikeCount() != 1 || got.GetLikedByMe() {
		t.Errorf("caller's stats = %v, want like_count 1, liked_by_me false", got)
	}
	if got := statsOf(t, s, other, videoID); got.GetLikeCount() != 1 || !got.GetLikedByMe() {
		t.Errorf("other's stats = %v, want like_count 1, liked_by_me true", got)
	}

	if err := unlike(t, s, other, videoID); err != nil {
		t.Fatal(err)
	}
	if err := unlike(t, s, other, videoID); err != nil {
		t.Fatal(err)
	}
	if likes, count := likeRows(t, videoID); likes != 0 || count != 0 {
		t.Errorf("likes rows = %d, like_count = %d, want 0 and 0", likes, count)
	}
}

// Likes and unlikes racing from many goroutines, the same user's on the same video included,
// leave like_count equal to the number of likes rows.
func TestConcurrentLikesKeepCountExact(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	videoID := ids.New()
	users := []string{ids.New(), ids.New(), ids.New()}

	const perUser = 4
	const rounds = 15
	var wg sync.WaitGroup
	errs := make(chan error, len(users)*perUser*rounds)
	for _, user := range users {
		for g := range perUser {
			wg.Go(func() {
				for i := range rounds {
					var err error
					if (g+i)%2 == 0 {
						err = like(t, s, user, videoID)
					} else {
						err = unlike(t, s, user, videoID)
					}
					if err != nil {
						errs <- err
					}
				}
			})
		}
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}

	likes, count := likeRows(t, videoID)
	if count == -1 {
		count = 0
	}
	if likes != count {
		t.Errorf("like_count = %d, count(*) of likes = %d", count, likes)
	}
	if got := statsOf(t, s, users[0], videoID); got.GetLikeCount() != likes {
		t.Errorf("GetStats like_count = %d, want %d", got.GetLikeCount(), likes)
	}
}

func TestGetStatsWithNoIDs(t *testing.T) {
	// No database: zero ids never reach it.
	s, _ := newServerWithoutDB(nil)
	resp, err := getStats(t, s, ids.New())
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetStats()) != 0 {
		t.Errorf("got %d stats, want none", len(resp.GetStats()))
	}
}

func TestGetStatsLimitsIDs(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	caller := ids.New()
	videoIDs := make([]string, MaxStatsVideoIDs+1)
	for i := range videoIDs {
		videoIDs[i] = ids.New()
	}

	_, err := getStats(t, s, caller, videoIDs...)
	wantError(t, err, codes.InvalidArgument, ReasonTooManyVideoIDs)

	resp, err := getStats(t, s, caller, videoIDs[:MaxStatsVideoIDs]...)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetStats()) != MaxStatsVideoIDs {
		t.Errorf("got %d stats, want %d", len(resp.GetStats()), MaxStatsVideoIDs)
	}
}

func TestGetStatsKeepsRequestOrder(t *testing.T) {
	needDB(t)
	s, _ := newServer(nil)
	caller, other := ids.New(), ids.New()
	a, b, unknown := ids.New(), ids.New(), ids.New()

	for _, l := range []struct{ user, video string }{{caller, a}, {other, a}, {other, b}} {
		if err := like(t, s, l.user, l.video); err != nil {
			t.Fatal(err)
		}
	}
	// view_counts is written by the view consumer; set it directly here.
	if _, err := testPool.Exec(t.Context(),
		"INSERT INTO view_counts (video_id, view_count) VALUES ($1, 7), ($2, 3)", a, b); err != nil {
		t.Fatal(err)
	}

	request := []string{b, a, unknown, a}
	resp, err := getStats(t, s, caller, request...)
	if err != nil {
		t.Fatal(err)
	}
	want := []*engagementv1.VideoStats{
		{VideoId: b, ViewCount: 3, LikeCount: 1, LikedByMe: false},
		{VideoId: a, ViewCount: 7, LikeCount: 2, LikedByMe: true},
		{VideoId: unknown},
		{VideoId: a, ViewCount: 7, LikeCount: 2, LikedByMe: true},
	}
	wantStats(t, resp.GetStats(), want)

	// Another caller sees the same counters but none of the caller's likes.
	resp, err = getStats(t, s, ids.New(), request...)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range want {
		w.LikedByMe = false
	}
	wantStats(t, resp.GetStats(), want)
}

func wantStats(t *testing.T, got, want []*engagementv1.VideoStats) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %d stats, want %d", len(got), len(want))
	}
	for i := range want {
		g, w := got[i], want[i]
		if g.GetVideoId() != w.GetVideoId() || g.GetViewCount() != w.GetViewCount() ||
			g.GetLikeCount() != w.GetLikeCount() || g.GetLikedByMe() != w.GetLikedByMe() {
			t.Errorf("stats[%d] = %v, want %v", i, g, w)
		}
	}
}
