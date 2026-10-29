package projector

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/kmsg"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/outbox"
	"github.com/anhnvcoder/short-video-platform/internal/pgtest"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/migrations"
)

// testPool is the migrated database shared by the package's tests; nil when SVP_TEST_POSTGRES_URL
// is unset, and then tests that need it skip. Every test uses fresh ids, so tests only see their
// own rows, except PruneTimeline, which deletes every expired row.
var (
	testPool  *pgxpool.Pool
	skipNoURL string
)

func TestMain(m *testing.M) {
	pool, cleanup, err := pgtest.Create(context.Background(), "svp_feed_projector_test", migrations.FS)
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

func newProjector() *Projector {
	return New(testPool, slog.New(slog.DiscardHandler))
}

func mustMarshal(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func followRecord(t *testing.T, follower, followee string) *kgo.Record {
	t.Helper()
	return &kgo.Record{Topic: TopicUserFollows, Key: []byte(follower), Value: mustMarshal(t, &userv1.FollowEvent{
		Meta:  outbox.NewMeta(),
		Event: &userv1.FollowEvent_UserFollowed{UserFollowed: &userv1.UserFollowed{FollowerId: follower, FolloweeId: followee}},
	})}
}

func unfollowRecord(t *testing.T, follower, followee string) *kgo.Record {
	t.Helper()
	return &kgo.Record{Topic: TopicUserFollows, Key: []byte(follower), Value: mustMarshal(t, &userv1.FollowEvent{
		Meta:  outbox.NewMeta(),
		Event: &userv1.FollowEvent_UserUnfollowed{UserUnfollowed: &userv1.UserUnfollowed{FollowerId: follower, FolloweeId: followee}},
	})}
}

// readyEvent returns a valid video.ready of video by author, published at published.
func readyEvent(video, author string, published time.Time) *videov1.VideoReady {
	return &videov1.VideoReady{
		VideoId:  video,
		AuthorId: author,
		Title:    "a video",
		Duration: durationpb.New(83250 * time.Millisecond),
		// The layout media-worker writes: media/<video>/<version>/master.m3u8 and the thumbnail
		// in the directory of the try that created the master.
		PlaylistKey:  "media/" + video + "/0190a6e4-7b2c-7d3e-9f40-0000000000a1/master.m3u8",
		ThumbnailKey: "media/" + video + "/0190a6e4-7b2c-7d3e-9f40-0000000000a1/0190a6e4-7b2c-7d3e-9f40-0000000000b2/thumbnail.jpg",
		PublishedAt:  timestamppb.New(published),
	}
}

func videoRecord(t *testing.T, e *videov1.VideoReady) *kgo.Record {
	t.Helper()
	return &kgo.Record{Topic: TopicVideoLifecycle, Key: []byte(e.GetVideoId()), Value: mustMarshal(t, &videov1.VideoEvent{
		Meta:  outbox.NewMeta(),
		Event: &videov1.VideoEvent_VideoReady{VideoReady: e},
	})}
}

func readyRecord(t *testing.T, video, author string, published time.Time) *kgo.Record {
	t.Helper()
	return videoRecord(t, readyEvent(video, author, published))
}

func handle(t *testing.T, p *Projector, rs ...*kgo.Record) {
	t.Helper()
	for _, r := range rs {
		if err := p.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err != nil {
			t.Fatalf("Handle(%s) = %v", r.Topic, err)
		}
	}
}

// now is the current time at the precision of timestamptz.
func now() time.Time {
	return time.Now().Truncate(time.Microsecond)
}

// timeline returns the video ids in user's timeline, newest first.
func timeline(t *testing.T, user string) []string {
	t.Helper()
	rows, err := testPool.Query(t.Context(),
		"SELECT video_id::text FROM timeline WHERE user_id = $1 ORDER BY published_at DESC, video_id DESC", user)
	if err != nil {
		t.Fatal(err)
	}
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func count(t *testing.T, query string, args ...any) int {
	t.Helper()
	var n int
	if err := testPool.QueryRow(t.Context(), query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func hasRow(t *testing.T, user, video string) bool {
	t.Helper()
	return count(t, "SELECT count(*) FROM timeline WHERE user_id = $1 AND video_id = $2", user, video) == 1
}

func following(t *testing.T, follower, followee string) bool {
	t.Helper()
	return count(t, "SELECT count(*) FROM follows WHERE follower_id = $1 AND followee_id = $2", follower, followee) == 1
}

// addFollowers gives author n new followers with random ids.
func addFollowers(t *testing.T, author string, n int) {
	t.Helper()
	_, err := testPool.Exec(t.Context(),
		"INSERT INTO follows (followee_id, follower_id) SELECT $1, gen_random_uuid() FROM generate_series(1, $2)", author, n)
	if err != nil {
		t.Fatal(err)
	}
}

func TestConsumerConfigRetriesWithoutLimit(t *testing.T) {
	cfg := New(nil, slog.New(slog.DiscardHandler)).ConsumerConfig("127.0.0.1:19092")
	if cfg.Group != "feed-service" || !slices.Equal(cfg.Topics, []string{"user.follows.v1", "video.lifecycle.v1"}) {
		t.Errorf("group %q topics %q, want feed-service on user.follows.v1 and video.lifecycle.v1", cfg.Group, cfg.Topics)
	}
	if cfg.MaxAttempts != math.MaxInt {
		t.Errorf("MaxAttempts = %d, want unlimited (math.MaxInt)", cfg.MaxAttempts)
	}
}

// Each attempt has a deadline of its own: long enough for a fan-out to
// 200k followers, about a second, and short enough that a stuck lock does not hold the consumer.
func TestConsumerConfigBoundsEachAttempt(t *testing.T) {
	cfg := New(nil, slog.New(slog.DiscardHandler)).ConsumerConfig("127.0.0.1:19092")
	if cfg.HandlerTimeout != 30*time.Second {
		t.Errorf("HandlerTimeout = %s, want 30s", cfg.HandlerTimeout)
	}
}

// An attempt waiting on the author lock that another transaction holds ends at the attempt's
// deadline, its transaction rolled back: nothing is written, and the event applies once the lock
// is free.
func TestAttemptWaitingOnAuthorLockEndsAtDeadline(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b, video := ids.New(), ids.New(), ids.New()
	handle(t, p, followRecord(t, b, author))

	holder, err := testPool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = holder.Rollback(context.Background()) }()
	if _, err := holder.Exec(t.Context(),
		"SELECT pg_advisory_xact_lock(hashtextextended('feed-author:' || $1::uuid::text, 0))", author); err != nil {
		t.Fatal(err)
	}

	const deadline = 200 * time.Millisecond
	ctx, cancel := context.WithTimeout(t.Context(), deadline)
	defer cancel()
	start := time.Now()
	err = p.Handle(ctx, readyRecord(t, video, author, now()), kafkax.Attempt{Number: 1})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("Handle returned nil while the author lock was held")
	}
	if elapsed > deadline+rollbackTimeout {
		t.Errorf("Handle returned after %s, want within the deadline %s and the rollback bound %s", elapsed, deadline, rollbackTimeout)
	}
	t.Logf("attempt on a held author lock returned after %s: %v", elapsed, err)
	if n := count(t, "SELECT count(*) FROM videos WHERE video_id = $1", video); n != 0 {
		t.Errorf("timed-out attempt stored the video")
	}

	if err := holder.Rollback(t.Context()); err != nil {
		t.Fatal(err)
	}
	handle(t, p, readyRecord(t, video, author, now()))
	if got := timeline(t, b); !slices.Equal(got, []string{video}) {
		t.Errorf("timeline after the lock was freed = %v, want [%s]", got, video)
	}
}

// A rebalance waits for the records in hand, for longer than a short Postgres outage, so a
// partition does not move while an old event is still being retried.
func TestConsumerConfigBlocksRebalance(t *testing.T) {
	cfg := New(nil, slog.New(slog.DiscardHandler)).ConsumerConfig("127.0.0.1:19092")
	if !cfg.BlockRebalance || cfg.RebalanceTimeout < time.Minute || cfg.MaxPollRecords <= 0 {
		t.Errorf("BlockRebalance %v, RebalanceTimeout %s, MaxPollRecords %d; want blocking, at least a minute, a bounded poll",
			cfg.BlockRebalance, cfg.RebalanceTimeout, cfg.MaxPollRecords)
	}
}

// A second video.ready of a stored video naming another author (forged, threat model IN-4) fans
// out to nobody: followers are chosen by the stored author, so unfollowing that author later
// still removes everything it delivered.
func TestVideoReadyWithAnotherAuthorFansOutToNobody(t *testing.T) {
	needDB(t)
	p := newProjector()
	x, y, b, c, video := ids.New(), ids.New(), ids.New(), ids.New(), ids.New()
	published := now().Add(-time.Hour)
	handle(t, p, followRecord(t, b, x), followRecord(t, c, y), readyRecord(t, video, x, published))

	handle(t, p, readyRecord(t, video, y, published))
	if got := timeline(t, c); len(got) != 0 {
		t.Errorf("follower of the forged author got %v, want nothing", got)
	}
	if !hasRow(t, b, video) {
		t.Error("follower of the stored author lost the video")
	}
	var author string
	if err := testPool.QueryRow(t.Context(), "SELECT author_id::text FROM videos WHERE video_id = $1", video).Scan(&author); err != nil {
		t.Fatal(err)
	}
	if author != x {
		t.Errorf("stored author = %s, want the first %s", author, x)
	}
}

// A follower present before video.ready gets the video, with the stored published_at; the author
// does not.
func TestFollowThenVideoReadyFansOut(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b, c, video := ids.New(), ids.New(), ids.New(), ids.New()
	published := now().Add(-time.Hour)

	handle(t, p, followRecord(t, b, author), followRecord(t, c, author), readyRecord(t, video, author, published))

	for _, user := range []string{b, c} {
		if got := timeline(t, user); !slices.Equal(got, []string{video}) {
			t.Errorf("timeline of %s = %v, want [%s]", user, got, video)
		}
	}
	if got := timeline(t, author); len(got) != 0 {
		t.Errorf("author's timeline = %v, want empty", got)
	}
	var at time.Time
	if err := testPool.QueryRow(t.Context(), "SELECT published_at FROM timeline WHERE user_id = $1", b).Scan(&at); err != nil {
		t.Fatal(err)
	}
	if !at.Equal(published) {
		t.Errorf("timeline published_at = %v, want %v", at, published)
	}
}

// video.ready may come before the user.followed it should be part of: the follow backfills it.
func TestVideoReadyThenFollowBackfills(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b, video := ids.New(), ids.New(), ids.New()

	handle(t, p, readyRecord(t, video, author, now().Add(-time.Hour)))
	if got := timeline(t, b); len(got) != 0 {
		t.Fatalf("timeline before follow = %v, want empty", got)
	}
	handle(t, p, followRecord(t, b, author))
	if got := timeline(t, b); !slices.Equal(got, []string{video}) {
		t.Errorf("timeline = %v, want [%s]", got, video)
	}
}

// A redelivery and a forged second video.ready with another published_at change nothing: the
// first one wins, and no row is duplicated.
func TestVideoReadyTwiceKeepsFirst(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b, video := ids.New(), ids.New(), ids.New()
	first := now().Add(-2 * time.Hour)
	handle(t, p, followRecord(t, b, author))

	r := readyRecord(t, video, author, first)
	handle(t, p, r, r, readyRecord(t, video, author, first.Add(time.Hour)))

	if n := count(t, "SELECT count(*) FROM videos WHERE video_id = $1", video); n != 1 {
		t.Errorf("got %d videos rows, want 1", n)
	}
	var stored time.Time
	if err := testPool.QueryRow(t.Context(), "SELECT published_at FROM videos WHERE video_id = $1", video).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !stored.Equal(first) {
		t.Errorf("videos published_at = %v, want the first %v", stored, first)
	}
	if n := count(t, "SELECT count(*) FROM timeline WHERE user_id = $1 AND video_id = $2 AND published_at = $3", b, video, first); n != 1 ||
		len(timeline(t, b)) != 1 {
		t.Errorf("timeline = %v, want one row at the first published_at", timeline(t, b))
	}
}

func TestUnfollowThenVideoReadyNotDelivered(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b, video := ids.New(), ids.New(), ids.New()

	handle(t, p, followRecord(t, b, author), unfollowRecord(t, b, author), readyRecord(t, video, author, now()))
	if got := timeline(t, b); len(got) != 0 {
		t.Errorf("timeline = %v, want empty", got)
	}
	if following(t, b, author) {
		t.Error("edge still there after unfollow")
	}
}

// Unfollow removes only the followee's videos, and only from the follower's timeline.
func TestVideoReadyThenUnfollowRemovesRows(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, other, b, c := ids.New(), ids.New(), ids.New(), ids.New()
	video, otherVideo := ids.New(), ids.New()
	handle(t, p, followRecord(t, b, author), followRecord(t, c, author), followRecord(t, b, other),
		readyRecord(t, video, author, now().Add(-time.Hour)), readyRecord(t, otherVideo, other, now().Add(-2*time.Hour)))

	handle(t, p, unfollowRecord(t, b, author))
	if got := timeline(t, b); !slices.Equal(got, []string{otherVideo}) {
		t.Errorf("timeline of b = %v, want only the other author's [%s]", got, otherVideo)
	}
	if !hasRow(t, c, video) {
		t.Error("another follower lost the video")
	}
}

// Replaying a pair's whole history (as `rpk group seek` does) ends where the first pass ended.
func TestReplayFollowUnfollowFollow(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b := ids.New(), ids.New()
	videos := []string{ids.New(), ids.New(), ids.New()}
	history := []*kgo.Record{followRecord(t, b, author)}
	for i, v := range videos {
		history = append(history, readyRecord(t, v, author, now().Add(-time.Duration(i+1)*time.Hour)))
	}
	history = append(history, unfollowRecord(t, b, author), followRecord(t, b, author))

	handle(t, p, history...)
	first := timeline(t, b)
	if !slices.Equal(first, videos) || !following(t, b, author) {
		t.Fatalf("after the first pass: timeline %v following %v, want %v and true", first, following(t, b, author), videos)
	}
	handle(t, p, history...)
	if got := timeline(t, b); !slices.Equal(got, first) || !following(t, b, author) {
		t.Errorf("after replay: timeline %v following %v, want %v and true", got, following(t, b, author), first)
	}
}

func TestBackfillTakesNewestTwentyWithinThirtyDays(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, b := ids.New(), ids.New()
	var newest []string
	for i := range 25 {
		v := ids.New()
		handle(t, p, readyRecord(t, v, author, now().Add(-time.Duration(i+1)*time.Hour)))
		if i < 20 {
			newest = append(newest, v)
		}
	}
	handle(t, p, readyRecord(t, ids.New(), author, now().Add(-31*24*time.Hour)))

	handle(t, p, followRecord(t, b, author))
	if got := timeline(t, b); !slices.Equal(got, newest) {
		t.Errorf("timeline = %v (%d videos), want the 20 newest %v", got, len(got), newest)
	}
}

func TestFanOutTenThousandFollowers(t *testing.T) {
	needDB(t)
	p := newProjector()
	author, video := ids.New(), ids.New()
	addFollowers(t, author, 10000)

	start := time.Now()
	handle(t, p, readyRecord(t, video, author, now()))
	elapsed := time.Since(start)
	t.Logf("fan-out to 10000 followers took %v", elapsed)

	if n := count(t, "SELECT count(*) FROM timeline WHERE video_id = $1", video); n != 10000 {
		t.Errorf("got %d timeline rows, want 10000", n)
	}
	if elapsed > 5*time.Second {
		t.Errorf("fan-out took %v, want under 5s", elapsed)
	}
}

// Fan-out racing a follow or unfollow of the same author ends with the timeline matching the
// final follow state. Without the author lock, a change committed while the fan-out's INSERT ...
// SELECT runs is missed: an unfollowed user keeps the video, or a new follower misses it.
func TestConcurrentFanOutAndFollowChanges(t *testing.T) {
	needDB(t)
	p := newProjector()
	const rounds = 40
	for i := range rounds {
		author, b, video := ids.New(), ids.New(), ids.New()
		// Enough followers that the fan-out statement runs for a while.
		addFollowers(t, author, 2000)
		unfollow := i%2 == 0
		change := followRecord(t, b, author)
		if unfollow {
			handle(t, p, followRecord(t, b, author))
			change = unfollowRecord(t, b, author)
		}
		ready := readyRecord(t, video, author, now())

		var (
			wg   sync.WaitGroup
			errs [2]error
		)
		start := make(chan struct{})
		wg.Go(func() {
			<-start
			errs[0] = p.Handle(t.Context(), ready, kafkax.Attempt{Number: 1})
		})
		wg.Go(func() {
			<-start
			// Spread the change over the fan-out's run.
			time.Sleep(time.Duration(i/2%8) * 2 * time.Millisecond)
			errs[1] = p.Handle(t.Context(), change, kafkax.Attempt{Number: 1})
		})
		close(start)
		wg.Wait()
		if err := errors.Join(errs[:]...); err != nil {
			t.Fatal(err)
		}

		if got, want := hasRow(t, b, video), !unfollow; got != want {
			t.Errorf("round %d (unfollow %v): b has the video = %v, want %v", i, unfollow, got, want)
		}
		if n := count(t, "SELECT count(*) FROM timeline WHERE video_id = $1", video); n != 2000+boolInt(!unfollow) {
			t.Errorf("round %d: got %d timeline rows, want %d", i, n, 2000+boolInt(!unfollow))
		}
	}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// Events of no interest to the feed are committed without a change.
func TestUninterestingEventsAreSkipped(t *testing.T) {
	needDB(t)
	p := newProjector()
	video := ids.New()
	// An unknown oneof field: number 15 as a length-delimited field, which neither event has.
	unknownBranch := append(mustMarshal(t, &videov1.VideoEvent{Meta: outbox.NewMeta()}), 15<<3|2, 2, 'h', 'i')
	records := map[string]*kgo.Record{
		"video.uploaded": {Topic: TopicVideoLifecycle, Key: []byte(video), Value: mustMarshal(t, &videov1.VideoEvent{
			Meta:  outbox.NewMeta(),
			Event: &videov1.VideoEvent_VideoUploaded{VideoUploaded: &videov1.VideoUploaded{VideoId: video, AuthorId: ids.New()}},
		})},
		"empty video event":    {Topic: TopicVideoLifecycle, Key: []byte(video), Value: mustMarshal(t, &videov1.VideoEvent{Meta: outbox.NewMeta()})},
		"unknown video branch": {Topic: TopicVideoLifecycle, Key: []byte(video), Value: unknownBranch},
		"empty follow event":   {Topic: TopicUserFollows, Key: []byte(video), Value: mustMarshal(t, &userv1.FollowEvent{Meta: outbox.NewMeta()})},
		"unknown follow branch": {Topic: TopicUserFollows, Key: []byte(video),
			Value: append(mustMarshal(t, &userv1.FollowEvent{Meta: outbox.NewMeta()}), 15<<3|2, 2, 'h', 'i')},
	}
	for name, r := range records {
		if err := p.Handle(t.Context(), r, kafkax.Attempt{Number: 1}); err != nil {
			t.Errorf("%s: Handle = %v, want nil", name, err)
		}
	}
	if n := count(t, "SELECT count(*) FROM videos WHERE video_id = $1", video); n != 0 {
		t.Errorf("video.uploaded stored a video")
	}
}

// Every malformed or forged event goes to its dead-letter topic at once and writes nothing
// (IN-5, FF-6).
func TestInvalidEventsGoToDeadLetter(t *testing.T) {
	needDB(t)
	cluster, err := kfake.NewCluster(kfake.NumBrokers(1),
		kfake.SeedTopics(1, TopicUserFollows, TopicVideoLifecycle),
		kfake.SeedTopics(1, TopicUserFollows+kafkax.DLQSuffix, TopicVideoLifecycle+kafkax.DLQSuffix))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cluster.Close)
	brokers := strings.Join(cluster.ListenAddrs(), ",")

	author := ids.New()
	ready := func(change func(id string, e *videov1.VideoReady)) func(t *testing.T, id string) *kgo.Record {
		return func(t *testing.T, id string) *kgo.Record {
			e := readyEvent(id, author, now())
			change(id, e)
			return videoRecord(t, e)
		}
	}
	cases := []struct {
		name   string
		record func(t *testing.T, id string) *kgo.Record
	}{
		{"undecodable video event", func(_ *testing.T, id string) *kgo.Record {
			return &kgo.Record{Topic: TopicVideoLifecycle, Key: []byte(id), Value: []byte{0xff}}
		}},
		{"video_id not a UUID", ready(func(_ string, e *videov1.VideoReady) { e.VideoId = "not-a-uuid" })},
		{"video_id upper case", ready(func(id string, e *videov1.VideoReady) { e.VideoId = strings.ToUpper(id) })},
		{"author_id not a UUID", ready(func(_ string, e *videov1.VideoReady) { e.AuthorId = "" })},
		{"playlist under another video", ready(func(_ string, e *videov1.VideoReady) { e.PlaylistKey = "media/" + ids.New() + "/master.m3u8" })},
		{"thumbnail under another video", ready(func(_ string, e *videov1.VideoReady) { e.ThumbnailKey = "media/" + ids.New() + "/thumbnail.jpg" })},
		{"playlist with ..", ready(func(id string, e *videov1.VideoReady) { e.PlaylistKey = "media/" + id + "/../x/master.m3u8" })},
		{"playlist with %2e%2e", ready(func(id string, e *videov1.VideoReady) { e.PlaylistKey = "media/" + id + "/%2e%2e/master.m3u8" })},
		{"thumbnail with backslash", ready(func(id string, e *videov1.VideoReady) { e.ThumbnailKey = "media/" + id + "/..\\x.jpg" })},
		{"playlist is the prefix", ready(func(id string, e *videov1.VideoReady) { e.PlaylistKey = "media/" + id + "/" })},
		{"no published_at", ready(func(_ string, e *videov1.VideoReady) { e.PublishedAt = nil })},
		{"no duration", ready(func(_ string, e *videov1.VideoReady) { e.Duration = nil })},
		{"zero duration", ready(func(_ string, e *videov1.VideoReady) { e.Duration = durationpb.New(0) })},
		{"title with NUL", ready(func(_ string, e *videov1.VideoReady) { e.Title = "a\x00b" })},
		{"empty title", ready(func(_ string, e *videov1.VideoReady) { e.Title = "" })},
		{"blank title", ready(func(_ string, e *videov1.VideoReady) { e.Title = " \t\n " })},
		{"title of 201 characters", ready(func(_ string, e *videov1.VideoReady) { e.Title = strings.Repeat("é", 201) })},
		{"title not UTF-8", func(t *testing.T, id string) *kgo.Record {
			// proto.Marshal refuses invalid UTF-8, so swap one byte of an encoded title.
			e := readyEvent(id, author, now())
			e.Title = "title-placeholder"
			r := videoRecord(t, e)
			r.Value = bytes.Replace(r.Value, []byte("title-placeholder"), []byte("\xffitle-placeholder"), 1)
			return r
		}},
		{"undecodable follow event", func(_ *testing.T, id string) *kgo.Record {
			return &kgo.Record{Topic: TopicUserFollows, Key: []byte(id), Value: []byte{0xff}}
		}},
		{"follower_id not a UUID", func(t *testing.T, id string) *kgo.Record { return followRecord(t, "x", id) }},
		{"followee_id not a UUID", func(t *testing.T, id string) *kgo.Record { return followRecord(t, id, "x") }},
		{"unfollow followee_id not a UUID", func(t *testing.T, id string) *kgo.Record { return unfollowRecord(t, id, "") }},
	}

	p := newProjector()
	var (
		mu      sync.Mutex
		results = map[string][]error{}
	)
	cfg := p.ConsumerConfig(brokers)
	cfg.BackoffBase, cfg.BackoffMax = time.Millisecond, time.Millisecond
	cfg.Handler = func(ctx context.Context, r *kgo.Record, a kafkax.Attempt) error {
		err := p.Handle(ctx, r, a)
		mu.Lock()
		defer mu.Unlock()
		results[string(r.Key)] = append(results[string(r.Key)], err)
		return err
	}
	c, err := kafkax.NewConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("consumer Run = %v", err)
		}
	})

	var records []*kgo.Record
	wantDead := map[string]int{}
	for _, tc := range cases {
		r := tc.record(t, ids.New())
		r.Headers = []kgo.RecordHeader{{Key: "test-case", Value: []byte(tc.name)}}
		records = append(records, r)
		wantDead[r.Topic+kafkax.DLQSuffix]++
	}
	// One partition per topic: once a topic's last record is handled, every earlier one is settled.
	lastVideo, lastFollower := ids.New(), ids.New()
	records = append(records, readyRecord(t, lastVideo, author, now()), followRecord(t, lastFollower, author))
	produce(t, brokers, records...)
	eventually(t, "the last records to be handled", func() bool {
		mu.Lock()
		defer mu.Unlock()
		for _, key := range []string{lastVideo, lastFollower} {
			errs := results[key]
			if len(errs) == 0 || errs[len(errs)-1] != nil {
				return false
			}
		}
		return true
	})

	byCase := map[string]*kgo.Record{}
	for topic, n := range wantDead {
		for _, r := range readTopic(t, brokers, topic, n) {
			byCase[headerValue(r, "test-case")] = r
		}
	}
	for i, tc := range cases {
		r, ok := byCase[tc.name]
		switch {
		case !ok:
			t.Errorf("%s: not in the dead-letter topic", tc.name)
		case headerValue(r, kafkax.HeaderDLQReason) != kafkax.ReasonPermanent:
			t.Errorf("%s: dlq-reason = %q (error %q), want permanent", tc.name,
				headerValue(r, kafkax.HeaderDLQReason), headerValue(r, kafkax.HeaderDLQError))
		}
		mu.Lock()
		tries := len(results[string(records[i].Key)])
		mu.Unlock()
		if tries != 1 {
			t.Errorf("%s: handled %d times, want once", tc.name, tries)
		}
	}
	// Only the two valid records wrote anything.
	if n := count(t, "SELECT count(*) FROM videos WHERE author_id = $1", author); n != 1 {
		t.Errorf("got %d videos of the author, want only the valid one", n)
	}
	if n := count(t, "SELECT count(*) FROM follows WHERE followee_id = $1", author); n != 1 {
		t.Errorf("got %d follows of the author, want only the valid one", n)
	}
}

// The title rule matches video-service's checkTitle: NUL, invalid UTF-8, blank and over 200
// characters are rejected; surrounding spaces do not count.
func TestValidTitle(t *testing.T) {
	cases := map[string]bool{
		"a video":                              true,
		strings.Repeat("é", 200):               true,
		"  " + strings.Repeat("x", 200) + "\t": true,
		"":                                     false,
		" \t\n ":                               false,
		strings.Repeat("é", 201):               false,
		"a\x00b":                               false,
		"\x00":                                 false,
		"bad \xff byte":                        false,
	}
	for title, want := range cases {
		if got := validTitle(title); got != want {
			t.Errorf("validTitle(%q) = %v, want %v", title, got, want)
		}
	}
}

// The stored title is the trimmed one validTitle checked, so the feed keeps the 200-character
// limit whatever surrounds the title in the event.
func TestVideoReadyStoresTrimmedTitle(t *testing.T) {
	needDB(t)
	p := newProjector()
	for _, tc := range []struct{ name, title, want string }{
		{"900000 spaces", strings.Repeat(" ", 900_000) + "a", "a"},
		{"200 characters inside spaces", "  " + strings.Repeat("x", 200) + "\t", strings.Repeat("x", 200)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			video := ids.New()
			e := readyEvent(video, ids.New(), now())
			e.Title = tc.title
			handle(t, p, videoRecord(t, e))
			var stored string
			if err := testPool.QueryRow(t.Context(), "SELECT title FROM videos WHERE video_id = $1", video).Scan(&stored); err != nil {
				t.Fatal(err)
			}
			if stored != tc.want {
				t.Errorf("stored title has %d characters, want %q", utf8.RuneCountInString(stored), tc.want)
			}
		})
	}
}

// A video.ready whose title Postgres cannot store (NUL) goes to the dead-letter topic, and the
// records behind it are still applied: the consumer does not retry it forever (IN-5).
func TestPoisonTitleDoesNotStallConsumer(t *testing.T) {
	needDB(t)
	cluster, err := kfake.NewCluster(kfake.NumBrokers(1),
		kfake.SeedTopics(1, TopicUserFollows, TopicVideoLifecycle),
		kfake.SeedTopics(1, TopicUserFollows+kafkax.DLQSuffix, TopicVideoLifecycle+kafkax.DLQSuffix))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cluster.Close)
	brokers := strings.Join(cluster.ListenAddrs(), ",")

	p := newProjector()
	cfg := p.ConsumerConfig(brokers)
	cfg.BackoffBase, cfg.BackoffMax = time.Millisecond, time.Millisecond
	c, err := kafkax.NewConsumer(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("consumer Run = %v", err)
		}
	})

	author, follower, poison, video := ids.New(), ids.New(), ids.New(), ids.New()
	bad := readyEvent(poison, author, now())
	bad.Title = "a\x00b"
	// One partition per topic: the poison record comes first on video.lifecycle.v1, the valid
	// video.ready right behind it.
	produce(t, brokers, videoRecord(t, bad), followRecord(t, follower, author), readyRecord(t, video, author, now()))

	eventually(t, "the follow and the valid video to be applied", func() bool {
		return hasRow(t, follower, video)
	})
	dead := readTopic(t, brokers, TopicVideoLifecycle+kafkax.DLQSuffix, 1)[0]
	if string(dead.Key) != poison || headerValue(dead, kafkax.HeaderDLQReason) != kafkax.ReasonPermanent {
		t.Errorf("dead letter key %s reason %q, want %s permanent", dead.Key, headerValue(dead, kafkax.HeaderDLQReason), poison)
	}
	if n := count(t, "SELECT count(*) FROM videos WHERE video_id = $1", poison); n != 0 {
		t.Errorf("poison video stored %d times, want never", n)
	}
	want := map[string]int64{TopicVideoLifecycle: 2, TopicUserFollows: 1}
	eventually(t, "offsets committed past every record", func() bool {
		got := committedOffsets(t, brokers, Group)
		return got[TopicVideoLifecycle] == want[TopicVideoLifecycle] && got[TopicUserFollows] == want[TopicUserFollows]
	})
}

// committedOffsets returns the offsets group committed on partition 0 of each topic.
func committedOffsets(t *testing.T, brokers, group string) map[string]int64 {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "feed-service-test-offsets")
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	req := kmsg.NewPtrOffsetFetchRequest()
	req.Group = group
	resp, err := req.RequestWith(t.Context(), cl)
	if err != nil {
		t.Fatal(err)
	}
	if err := kerr.ErrorForCode(resp.ErrorCode); err != nil {
		t.Fatal(err)
	}
	out := map[string]int64{}
	for _, tp := range resp.Topics {
		for _, part := range tp.Partitions {
			if part.Partition == 0 {
				out[tp.Topic] = part.Offset
			}
		}
	}
	return out
}

func produce(t *testing.T, brokers string, rs ...*kgo.Record) {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "feed-service-test-producer")
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	if err := kafkax.Produce(t.Context(), cl, rs...); err != nil {
		t.Fatal(err)
	}
}

// readTopic reads topic from the start until n records have come, and returns them.
func readTopic(t *testing.T, brokers, topic string, n int) []*kgo.Record {
	t.Helper()
	cl, err := kafkax.NewClient(brokers, "feed-service-test-reader",
		kgo.ConsumeTopics(topic), kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(out) < n && ctx.Err() == nil {
		cl.PollFetches(ctx).EachRecord(func(r *kgo.Record) { out = append(out, r) })
	}
	if len(out) < n {
		t.Fatalf("got %d records on %s, want %d", len(out), topic, n)
	}
	return out
}

func headerValue(r *kgo.Record, key string) string {
	for _, h := range r.Headers {
		if h.Key == key {
			return string(h.Value)
		}
	}
	return ""
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// PruneTimeline deletes, batch after batch, only rows past 30 days.
func TestPruneTimelineDeletesOnlyExpired(t *testing.T) {
	needDB(t)
	p := newProjector()
	user := ids.New()
	insert := func(age time.Duration, n int) {
		_, err := testPool.Exec(t.Context(),
			"INSERT INTO timeline (user_id, published_at, video_id) SELECT $1, $2, gen_random_uuid() FROM generate_series(1, $3)",
			user, now().Add(-age), n)
		if err != nil {
			t.Fatal(err)
		}
	}
	insert(31*24*time.Hour, 5)
	insert(30*24*time.Hour+time.Minute, 2)
	insert(29*24*time.Hour, 3)
	insert(time.Hour, 1)

	// A batch of 2 needs four DELETEs for 7 rows, the last one partial.
	batches := 0
	n, err := p.pruneTimeline(t.Context(), 2, func() { batches++ })
	if err != nil {
		t.Fatal(err)
	}
	if n < 7 {
		t.Errorf("pruned %d rows, want at least the 7 expired", n)
	}
	// Every full batch is followed by another DELETE, and the last one, partial or empty, counts too.
	if want := int(n/2) + 1; batches != want {
		t.Errorf("onBatch called %d times for %d rows in batches of 2, want %d", batches, n, want)
	}
	if got := count(t, "SELECT count(*) FROM timeline WHERE user_id = $1", user); got != 4 {
		t.Errorf("%d rows left, want the 4 within 30 days", got)
	}
	if got := count(t, "SELECT count(*) FROM timeline WHERE published_at < now() - interval '30 days'"); got != 0 {
		t.Errorf("%d expired rows left, want 0", got)
	}

	// Nothing left to do, which is still a batch done.
	batches = 0
	if n, err := p.PruneTimeline(t.Context(), func() { batches++ }); err != nil || n != 0 || batches != 1 {
		t.Errorf("PruneTimeline again = %d, %v with %d batches, want 0, nil with 1", n, err, batches)
	}
}

// A run whose deadline passes between two batches fails, and the batch it finished before that
// was reported, so a run working through a backlog does not look stalled.
func TestPruneTimelineReportsBatchesOfARunCutShort(t *testing.T) {
	needDB(t)
	p := newProjector()
	if _, err := testPool.Exec(t.Context(),
		"INSERT INTO timeline (user_id, published_at, video_id) SELECT $1, $2, gen_random_uuid() FROM generate_series(1, 5)",
		ids.New(), now().Add(-31*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	batches := 0
	// The deadline comes once the first batch is done, so the second DELETE never runs.
	n, err := p.pruneTimeline(ctx, 2, func() {
		batches++
		cancel()
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("pruneTimeline() error = %v, want the run's context error", err)
	}
	if n != 2 || batches != 1 {
		t.Errorf("pruneTimeline() deleted %d rows in %d reported batches, want 2 in 1", n, batches)
	}
}
