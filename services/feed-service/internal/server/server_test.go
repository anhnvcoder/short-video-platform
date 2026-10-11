package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	feedv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/feed/v1"
	"github.com/anhnvcoder/short-video-platform/internal/callerid"
	"github.com/anhnvcoder/short-video-platform/internal/grpcerr"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/pagetoken"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/migrations"
)

const (
	methodFollowing = "/svp.feed.v1.FeedService/GetFollowingFeed"
	methodExplore   = "/svp.feed.v1.FeedService/GetExploreFeed"
)

// testPool is the migrated database shared by the package's tests; nil when SVP_TEST_POSTGRES_URL
// is unset, and then tests that need it skip. Following-feed tests use fresh users, so they only
// see their own rows; explore tests empty videos first, since the explore feed is everyone's.
var (
	testPool  *pgxpool.Pool
	skipNoURL string
)

func TestMain(m *testing.M) {
	pool, cleanup, err := pgtest.Create(context.Background(), "svp_feed_server_test", migrations.FS)
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

// newServer returns a Server on the test database (nil without one: only validation paths work).
func newServer() *Server {
	return New(testPool, slog.New(slog.DiscardHandler))
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

func following(t *testing.T, s *Server, caller string, size int32, token string) (*feedv1.GetFollowingFeedResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodFollowing,
		&feedv1.GetFollowingFeedRequest{PageSize: size, PageToken: token}, s.GetFollowingFeed)
}

func explore(t *testing.T, s *Server, caller string, size int32, token string) (*feedv1.GetExploreFeedResponse, error) {
	t.Helper()
	return call(t.Context(), caller, methodExplore,
		&feedv1.GetExploreFeedRequest{PageSize: size, PageToken: token}, s.GetExploreFeed)
}

// feedPage is what both RPCs return.
type feedPage interface {
	GetItems() []*feedv1.FeedItem
	GetNextPageToken() string
}

// readAll follows next_page_token from the first page to the last and returns the video ids of
// every page.
func readAll(t *testing.T, size int32, read func(token string) (feedPage, error)) [][]string {
	t.Helper()
	var pages [][]string
	token := ""
	for range 100 {
		resp, err := read(token)
		if err != nil {
			t.Fatal(err)
		}
		pages = append(pages, videoIDs(resp.GetItems()))
		if token = resp.GetNextPageToken(); token == "" {
			return pages
		}
		if len(resp.GetItems()) != int(size) {
			t.Fatalf("page %d has %d items and a next page, want %d", len(pages), len(resp.GetItems()), size)
		}
	}
	t.Fatal("no last page after 100 pages")
	return nil
}

func followingPages(t *testing.T, s *Server, caller string, size int32) [][]string {
	t.Helper()
	return readAll(t, size, func(token string) (feedPage, error) { return following(t, s, caller, size, token) })
}

func videoIDs(items []*feedv1.FeedItem) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.GetVideoId()
	}
	return out
}

func wantError(t *testing.T, err error, code codes.Code, reason string) {
	t.Helper()
	if got := status.Code(err); got != code {
		t.Fatalf("code = %s (err %v), want %s", got, err, code)
	}
	if got := grpcerr.Reason(err); got != reason {
		t.Fatalf("reason = %q, want %q", got, reason)
	}
}

// now is the current time at the precision of timestamptz.
func now() time.Time {
	return time.Now().Truncate(time.Microsecond)
}

// video is a row of videos.
type video struct {
	id, author string
	published  time.Time
}

// insertVideo stores a READY video of author published at published and returns it.
func insertVideo(t *testing.T, author string, published time.Time) video {
	t.Helper()
	id := ids.New()
	_, err := testPool.Exec(t.Context(), `
		INSERT INTO videos (video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at)
		VALUES ($1, $2, $3, 83250, $4, $5, $6)`,
		id, author, "title of "+id, "media/"+id+"/master.m3u8", "media/"+id+"/thumbnail.jpg", published)
	if err != nil {
		t.Fatal(err)
	}
	return video{id: id, author: author, published: published}
}

// addToTimeline puts videos into user's timeline, as fan-out does.
func addToTimeline(t *testing.T, user string, vs ...video) {
	t.Helper()
	for _, v := range vs {
		_, err := testPool.Exec(t.Context(),
			"INSERT INTO timeline (user_id, published_at, video_id) VALUES ($1, $2, $3)", user, v.published, v.id)
		if err != nil {
			t.Fatal(err)
		}
	}
}

// newestFirst returns the ids of vs in feed order: published_at DESC, video_id DESC.
func newestFirst(vs []video) []string {
	sorted := slices.Clone(vs)
	slices.SortFunc(sorted, func(a, b video) int {
		if c := b.published.Compare(a.published); c != 0 {
			return c
		}
		return strings.Compare(b.id, a.id)
	})
	out := make([]string, len(sorted))
	for i, v := range sorted {
		out[i] = v.id
	}
	return out
}

// timelineOf gives a new user n videos of a new author, published a minute apart, newest an hour
// ago, and returns the user and the videos.
func timelineOf(t *testing.T, n int) (string, []video) {
	t.Helper()
	user, author := ids.New(), ids.New()
	vs := make([]video, n)
	for i := range vs {
		vs[i] = insertVideo(t, author, now().Add(-time.Hour-time.Duration(i)*time.Minute))
	}
	addToTimeline(t, user, vs...)
	return user, vs
}

// emptyVideos removes every video, so an explore test sees only its own.
func emptyVideos(t *testing.T) {
	t.Helper()
	if _, err := testPool.Exec(t.Context(), "DELETE FROM videos"); err != nil {
		t.Fatal(err)
	}
}

func TestEveryRPCRequiresCaller(t *testing.T) {
	s := newServer()
	for _, caller := range []string{"", "not-a-uuid", strings.ToUpper(ids.New())} {
		_, err := following(t, s, caller, 0, "")
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
		_, err = explore(t, s, caller, 0, "")
		wantError(t, err, codes.Unauthenticated, callerid.ReasonUnauthenticatedCaller)
	}
}

// A server wired without the interceptor must not serve an anonymous caller.
func TestHandlersFailClosedWithoutInterceptor(t *testing.T) {
	s := newServer()
	if _, err := s.GetFollowingFeed(t.Context(), &feedv1.GetFollowingFeedRequest{}); status.Code(err) != codes.Unauthenticated {
		t.Errorf("GetFollowingFeed code = %s, want Unauthenticated", status.Code(err))
	}
	if _, err := s.GetExploreFeed(t.Context(), &feedv1.GetExploreFeedRequest{}); status.Code(err) != codes.Unauthenticated {
		t.Errorf("GetExploreFeed code = %s, want Unauthenticated", status.Code(err))
	}
}

func TestNegativePageSizeIsRejected(t *testing.T) {
	// No database: validation runs before it is used.
	s := newServer()
	caller := ids.New()
	_, err := following(t, s, caller, -1, "")
	wantError(t, err, codes.InvalidArgument, ReasonInvalidPageSize)
	_, err = explore(t, s, caller, -1, "")
	wantError(t, err, codes.InvalidArgument, ReasonInvalidPageSize)
}

func TestInvalidPageTokenIsRejected(t *testing.T) {
	// No database: validation runs before it is used.
	s := newServer()
	caller := ids.New()
	valid := pagetoken.Encode(pagetoken.Cursor{PublishedAt: now(), VideoID: uuid.MustParse(ids.New())})
	for _, tc := range []struct{ name, token string }{
		{"65 characters", valid + strings.Repeat("A", pagetoken.MaxLen+1-len(valid))},
		{"broken base64", "not base64!"},
		{"broken protobuf", valid[:len(valid)-4]},
		{"no video_id", "CAE"}, // field 1 = 1, nothing else
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := following(t, s, caller, 0, tc.token)
			wantError(t, err, codes.InvalidArgument, ReasonInvalidPageToken)
			_, err = explore(t, s, caller, 0, tc.token)
			wantError(t, err, codes.InvalidArgument, ReasonInvalidPageToken)
		})
	}
}

// 25 videos in pages of 10 come back as 10, 10, 5, newest first, each once, and the last
// next_page_token is empty. A video published between two reads does not shift later pages.
func TestFollowingFeedPagesWithoutGapsOrDuplicates(t *testing.T) {
	needDB(t)
	s := newServer()
	user, vs := timelineOf(t, 25)
	want := newestFirst(vs)

	first, err := following(t, s, user, 10, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := videoIDs(first.GetItems()); !slices.Equal(got, want[:10]) {
		t.Fatalf("page 1 = %v, want %v", got, want[:10])
	}
	// Newer than every video of the timeline: keyset paging must not move to show it.
	addToTimeline(t, user, insertVideo(t, ids.New(), now()))

	second, err := following(t, s, user, 10, first.GetNextPageToken())
	if err != nil {
		t.Fatal(err)
	}
	if got := videoIDs(second.GetItems()); !slices.Equal(got, want[10:20]) {
		t.Errorf("page 2 = %v, want %v", got, want[10:20])
	}
	third, err := following(t, s, user, 10, second.GetNextPageToken())
	if err != nil {
		t.Fatal(err)
	}
	if got := videoIDs(third.GetItems()); !slices.Equal(got, want[20:]) {
		t.Errorf("page 3 = %v, want %v", got, want[20:])
	}
	if third.GetNextPageToken() != "" {
		t.Errorf("last page next_page_token = %q, want empty", third.GetNextPageToken())
	}
}

// Exactly a full last page: the extra row read tells there is no next page.
func TestFollowingFeedFullLastPageHasNoNextToken(t *testing.T) {
	needDB(t)
	s := newServer()
	user, vs := timelineOf(t, 20)
	pages := followingPages(t, s, user, 10)
	if len(pages) != 2 || !slices.Equal(slices.Concat(pages...), newestFirst(vs)) {
		t.Errorf("pages = %v, want two pages of %v", pages, newestFirst(vs))
	}
}

// Videos sharing a published_at are ordered by video_id, and a page boundary inside such a run
// loses nothing.
func TestSamePublishedAtIsOrderedByVideoID(t *testing.T) {
	needDB(t)
	s := newServer()
	user, author := ids.New(), ids.New()
	same := now().Add(-time.Hour)
	var vs []video
	for range 7 {
		vs = append(vs, insertVideo(t, author, same))
	}
	vs = append(vs, insertVideo(t, author, same.Add(time.Minute)), insertVideo(t, author, same.Add(-time.Minute)))
	addToTimeline(t, user, vs...)

	pages := followingPages(t, s, user, 3)
	if len(pages) != 3 {
		t.Errorf("got %d pages, want 3", len(pages))
	}
	if got, want := slices.Concat(pages...), newestFirst(vs); !slices.Equal(got, want) {
		t.Errorf("feed = %v, want %v", got, want)
	}
}

func TestPageSizeDefaultAndMaximum(t *testing.T) {
	needDB(t)
	s := newServer()
	user, _ := timelineOf(t, 60)
	for _, tc := range []struct{ size, want int32 }{{0, DefaultPageSize}, {1, 1}, {50, 50}, {51, MaxPageSize}, {1 << 30, MaxPageSize}} {
		resp, err := following(t, s, user, tc.size, "")
		if err != nil {
			t.Fatal(err)
		}
		if got := len(resp.GetItems()); got != int(tc.want) || resp.GetNextPageToken() == "" {
			t.Errorf("page_size %d: %d items, next %q; want %d items and a next page", tc.size, got, resp.GetNextPageToken(), tc.want)
		}
	}
}

// A token edited to point anywhere, even at another user's rows, only moves where the caller
// reads in their own timeline (threat model PG-1).
func TestEditedTokenStaysInCallersTimeline(t *testing.T) {
	needDB(t)
	s := newServer()
	user, vs := timelineOf(t, 5)
	want := newestFirst(vs)
	other, otherVideos := timelineOf(t, 3)

	at := func(v video) string {
		return pagetoken.Encode(pagetoken.Cursor{PublishedAt: v.published, VideoID: uuid.MustParse(v.id)})
	}
	for _, tc := range []struct {
		name, token string
		want        []string
	}{
		// The other user's rows are a little newer than user's: reading starts at user's newest.
		{"another user's row", at(otherVideos[0]), want},
		{"own row", at(vs[1]), want[2:]},
		{"far future", pagetoken.Encode(pagetoken.Cursor{PublishedAt: now().AddDate(100, 0, 0)}), want},
		{"before everything", pagetoken.Encode(pagetoken.Cursor{PublishedAt: now().AddDate(-100, 0, 0)}), nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := following(t, s, user, 10, tc.token)
			if err != nil {
				t.Fatal(err)
			}
			if got := videoIDs(resp.GetItems()); !slices.Equal(got, tc.want) {
				t.Errorf("feed = %v, want %v", got, tc.want)
			}
		})
	}
	// And the other user's videos never show up in user's feed.
	for _, id := range slices.Concat(followingPages(t, s, user, 2)...) {
		if slices.ContainsFunc(otherVideos, func(v video) bool { return v.id == id }) {
			t.Errorf("user's feed has %s of user %s", id, other)
		}
	}
}

func TestNoTimelineIsEmpty(t *testing.T) {
	needDB(t)
	s := newServer()
	resp, err := following(t, s, ids.New(), 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetItems()) != 0 || resp.GetNextPageToken() != "" {
		t.Errorf("got %d items, next %q; want none", len(resp.GetItems()), resp.GetNextPageToken())
	}
}

// Rows past 30 days are not served, even before the hourly prune deletes them.
func TestFollowingFeedHidesRowsOlderThanThirtyDays(t *testing.T) {
	needDB(t)
	s := newServer()
	user, author := ids.New(), ids.New()
	recent := insertVideo(t, author, now().AddDate(0, 0, -29))
	old := insertVideo(t, author, now().AddDate(0, 0, -31))
	addToTimeline(t, user, recent, old)

	resp, err := following(t, s, user, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := videoIDs(resp.GetItems()); !slices.Equal(got, []string{recent.id}) || resp.GetNextPageToken() != "" {
		t.Errorf("feed = %v (next %q), want only [%s]", got, resp.GetNextPageToken(), recent.id)
	}
}

// A feed item carries the stored copy of the video, duration from duration_ms.
func TestFeedItemFields(t *testing.T) {
	needDB(t)
	s := newServer()
	user, vs := timelineOf(t, 1)
	v := vs[0]
	resp, err := following(t, s, user, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetItems()) != 1 {
		t.Fatalf("got %d items, want 1", len(resp.GetItems()))
	}
	it := resp.GetItems()[0]
	if it.GetVideoId() != v.id || it.GetAuthorId() != v.author || it.GetTitle() != "title of "+v.id ||
		it.GetDuration().AsDuration() != 83250*time.Millisecond ||
		it.GetPlaylistKey() != "media/"+v.id+"/master.m3u8" || it.GetThumbnailKey() != "media/"+v.id+"/thumbnail.jpg" ||
		!it.GetPublishedAt().AsTime().Equal(v.published) {
		t.Errorf("item = %v, want the stored %+v", it, v)
	}
}

// The explore feed lists every READY video, newest first and older than 30 days too, the same for
// every caller, with the same keyset paging.
func TestExploreFeedListsEveryVideo(t *testing.T) {
	needDB(t)
	emptyVideos(t)
	s := newServer()
	var vs []video
	same := now().Add(-time.Hour)
	for i := range 6 {
		vs = append(vs, insertVideo(t, ids.New(), now().Add(-time.Duration(i)*time.Minute)), insertVideo(t, ids.New(), same))
	}
	vs = append(vs, insertVideo(t, ids.New(), now().AddDate(0, 0, -90)))
	want := newestFirst(vs)

	for _, caller := range []string{ids.New(), ids.New()} {
		pages := readAll(t, 5, func(token string) (feedPage, error) { return explore(t, s, caller, 5, token) })
		if len(pages) != 3 || !slices.Equal(slices.Concat(pages...), want) {
			t.Errorf("caller %s: pages = %v, want 5, 5, 3 of %v", caller, pages, want)
		}
	}
}

func TestExploreFeedEmpty(t *testing.T) {
	needDB(t)
	emptyVideos(t)
	resp, err := explore(t, newServer(), ids.New(), 0, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetItems()) != 0 || resp.GetNextPageToken() != "" {
		t.Errorf("got %d items, next %q; want none", len(resp.GetItems()), resp.GetNextPageToken())
	}
}
