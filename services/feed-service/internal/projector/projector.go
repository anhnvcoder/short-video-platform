// Package projector builds feed-service's read model (follows, videos, timeline) from the events
// of user.follows.v1 and video.lifecycle.v1, and prunes timeline rows past 30 days
// (docs/adr/0009-engagement-feed-stage2b.md, sections 6 and 7).
package projector

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"time"
	"unicode/utf8"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	videov1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/video/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
	"github.com/anhnvcoder/short-video-platform/internal/kafkax"
	"github.com/anhnvcoder/short-video-platform/internal/logx"
	"github.com/anhnvcoder/short-video-platform/internal/objstore"
	"github.com/anhnvcoder/short-video-platform/services/feed-service/internal/store"
)

// Topics and consumer group of the feed read model (ADR-0009 section 11).
const (
	TopicUserFollows    = "user.follows.v1"
	TopicVideoLifecycle = "video.lifecycle.v1"
	Group               = "feed-service"
)

// pruneBatch bounds the rows one DELETE of PruneTimeline removes.
const pruneBatch = 5000

// maxTitleRunes is video-service's limit on a title (MaxTitleRunes in its server package).
const maxTitleRunes = 200

const (
	// maxPollRecords bounds the records one poll hands to the handler, so a rebalance held by
	// BlockRebalance waits for at most this many records.
	maxPollRecords = 100
	// rebalanceTimeout is how long the group waits for this member to settle its poll and rejoin.
	// A poll of maxPollRecords takes well under a second, a fan-out to 200k followers a few; the
	// rest covers a short Postgres outage (a restart, a failover) during which the handler keeps
	// retrying. An outage longer than this gets the member dropped from the group, and its
	// partitions move to another member while it still retries.
	rebalanceTimeout = 5 * time.Minute
)

// Projector applies events to the read model.
type Projector struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	logger  *slog.Logger
}

// New returns a Projector writing to pool.
func New(pool *pgxpool.Pool, logger *slog.Logger) *Projector {
	return &Projector{pool: pool, queries: store.New(pool), logger: logger}
}

// ConsumerConfig returns the consumer of both topics in Group. Transient errors are retried
// without limit (the backoff is capped): a valid user.followed or video.ready sent to the
// dead-letter topic because Postgres was down would leave the read model wrong with nobody
// knowing, and replaying it later could bring back an edge unfollowed since. Only malformed
// events, marked kafkax.Permanent, go to the dead-letter topics.
func (p *Projector) ConsumerConfig(brokers string) kafkax.ConsumerConfig {
	return kafkax.ConsumerConfig{
		Brokers:     brokers,
		ClientID:    Group,
		Group:       Group,
		Topics:      []string{TopicUserFollows, TopicVideoLifecycle},
		Handler:     p.Handle,
		Logger:      p.logger,
		MaxAttempts: math.MaxInt,
		// A rebalance waits for the records in hand. Without this, a partition could move to
		// another member while this one retries an old user.followed through a Postgres outage,
		// and that retry could land after the new owner applied a later user.unfollowed.
		MaxPollRecords:   maxPollRecords,
		BlockRebalance:   true,
		RebalanceTimeout: rebalanceTimeout,
	}
}

// Handle is the kafkax.Handler of both topics. Every handler is idempotent (ON CONFLICT DO
// NOTHING, deletes), so a redelivered event changes nothing and needs no processed_events
// table.
func (p *Projector) Handle(ctx context.Context, r *kgo.Record, _ kafkax.Attempt) error {
	switch r.Topic {
	case TopicUserFollows:
		return p.handleFollow(ctx, r)
	case TopicVideoLifecycle:
		return p.handleVideo(ctx, r)
	}
	return kafkax.Permanent(fmt.Errorf("record from unexpected topic %q", r.Topic))
}

func (p *Projector) handleFollow(ctx context.Context, r *kgo.Record) error {
	var ev userv1.FollowEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		return kafkax.Permanent(fmt.Errorf("decode FollowEvent: %w", err))
	}
	switch e := ev.GetEvent().(type) {
	case *userv1.FollowEvent_UserFollowed:
		follower, followee, err := parseEdge(e.UserFollowed.GetFollowerId(), e.UserFollowed.GetFolloweeId())
		if err != nil {
			return err
		}
		return p.follow(edgeContext(ctx, &ev, follower, followee), follower, followee)
	case *userv1.FollowEvent_UserUnfollowed:
		follower, followee, err := parseEdge(e.UserUnfollowed.GetFollowerId(), e.UserUnfollowed.GetFolloweeId())
		if err != nil {
			return err
		}
		return p.unfollow(edgeContext(ctx, &ev, follower, followee), follower, followee)
	}
	// An unknown or empty branch decodes as nil: skip it (ADR-0006).
	return nil
}

func parseEdge(followerID, followeeID string) (follower, followee uuid.UUID, err error) {
	if follower, err = ids.Parse(followerID); err != nil {
		return follower, followee, kafkax.Permanent(errors.New("follow event follower_id is not a canonical UUID"))
	}
	if followee, err = ids.Parse(followeeID); err != nil {
		return follower, followee, kafkax.Permanent(errors.New("follow event followee_id is not a canonical UUID"))
	}
	return follower, followee, nil
}

func edgeContext(ctx context.Context, ev *userv1.FollowEvent, follower, followee uuid.UUID) context.Context {
	return logx.With(ctx, slog.String("follower_id", follower.String()), slog.String("followee_id", followee.String()),
		slog.String("event_id", ev.GetMeta().GetEventId()))
}

// follow adds the edge and backfills the followee's recent videos. The backfill runs even when
// the edge was there already, so a redelivery after a crash between the two still completes it.
func (p *Projector) follow(ctx context.Context, follower, followee uuid.UUID) error {
	var backfilled int64
	err := p.inAuthorTx(ctx, followee, func(q *store.Queries) error {
		if err := q.InsertFollow(ctx, store.InsertFollowParams{FolloweeID: followee, FollowerID: follower}); err != nil {
			return fmt.Errorf("insert follow: %w", err)
		}
		n, err := q.BackfillTimeline(ctx, store.BackfillTimelineParams{FollowerID: follower, FolloweeID: followee})
		if err != nil {
			return fmt.Errorf("backfill timeline: %w", err)
		}
		backfilled = n
		return nil
	})
	if err != nil {
		return err
	}
	p.logger.InfoContext(ctx, "follow applied", slog.Int64("backfilled", backfilled))
	return nil
}

// unfollow removes the edge and every video of the followee from the follower's timeline.
func (p *Projector) unfollow(ctx context.Context, follower, followee uuid.UUID) error {
	var removed int64
	err := p.inAuthorTx(ctx, followee, func(q *store.Queries) error {
		if err := q.DeleteFollow(ctx, store.DeleteFollowParams{FolloweeID: followee, FollowerID: follower}); err != nil {
			return fmt.Errorf("delete follow: %w", err)
		}
		n, err := q.DeleteAuthorFromTimeline(ctx, store.DeleteAuthorFromTimelineParams{FollowerID: follower, FolloweeID: followee})
		if err != nil {
			return fmt.Errorf("delete timeline rows: %w", err)
		}
		removed = n
		return nil
	})
	if err != nil {
		return err
	}
	p.logger.InfoContext(ctx, "unfollow applied", slog.Int64("removed", removed))
	return nil
}

func (p *Projector) handleVideo(ctx context.Context, r *kgo.Record) error {
	var ev videov1.VideoEvent
	if err := proto.Unmarshal(r.Value, &ev); err != nil {
		return kafkax.Permanent(fmt.Errorf("decode VideoEvent: %w", err))
	}
	ready := ev.GetVideoReady()
	if ready == nil {
		// video.uploaded is media-worker's; an unknown or empty branch is skipped (ADR-0006).
		return nil
	}
	v, err := checkVideoReady(ready)
	if err != nil {
		return err
	}
	ctx = logx.With(ctx, slog.String("video_id", v.VideoID.String()), slog.String("author_id", v.AuthorID.String()),
		slog.String("event_id", ev.GetMeta().GetEventId()))
	return p.publish(ctx, v)
}

// checkVideoReady checks every field the feed stores or serves, so a forged or broken event goes
// to the dead-letter topic instead of failing every retry and stalling both topics (IN-5). The
// keys end up in URLs the gateway builds, so they get the same check as video-service gives
// media-worker's (FF-6); the title gets video-service's own title rule.
func checkVideoReady(e *videov1.VideoReady) (store.InsertVideoParams, error) {
	videoID, err := ids.Parse(e.GetVideoId())
	if err != nil {
		return store.InsertVideoParams{}, kafkax.Permanent(errors.New("video.ready video_id is not a canonical UUID"))
	}
	authorID, err := ids.Parse(e.GetAuthorId())
	if err != nil {
		return store.InsertVideoParams{}, kafkax.Permanent(errors.New("video.ready author_id is not a canonical UUID"))
	}
	if !validTitle(e.GetTitle()) {
		return store.InsertVideoParams{}, kafkax.Permanent(errors.New("video.ready title is not 1 to 200 characters of valid UTF-8 text"))
	}
	prefix := objstore.MediaPrefix + videoID.String() + "/"
	for _, key := range []string{e.GetPlaylistKey(), e.GetThumbnailKey()} {
		if !objstore.IsMediaKey(key, videoID.String()) {
			return store.InsertVideoParams{}, kafkax.Permanent(fmt.Errorf("video.ready key %q is not under %s", key, prefix))
		}
	}
	d := e.GetDuration()
	if d.CheckValid() != nil || d.AsDuration().Milliseconds() < 1 {
		return store.InsertVideoParams{}, kafkax.Permanent(errors.New("video.ready duration is not positive"))
	}
	if err := e.GetPublishedAt().CheckValid(); err != nil {
		return store.InsertVideoParams{}, kafkax.Permanent(fmt.Errorf("video.ready published_at: %w", err))
	}
	return store.InsertVideoParams{
		VideoID:      videoID,
		AuthorID:     authorID,
		Title:        e.GetTitle(),
		DurationMs:   d.AsDuration().Milliseconds(),
		PlaylistKey:  e.GetPlaylistKey(),
		ThumbnailKey: e.GetThumbnailKey(),
		PublishedAt:  e.GetPublishedAt().AsTime(),
	}, nil
}

// validTitle applies video-service's checkTitle rule: after trimming, 1 to maxTitleRunes
// characters of valid UTF-8 without NUL (Postgres text cannot hold NUL). The title is stored as
// given; video-service has already trimmed it.
func validTitle(title string) bool {
	title = strings.TrimSpace(title)
	if !utf8.ValidString(title) || strings.ContainsRune(title, 0) {
		return false
	}
	n := utf8.RuneCountInString(title)
	return n > 0 && n <= maxTitleRunes
}

// publish stores the video and fans it out to its author's followers in one transaction.
func (p *Projector) publish(ctx context.Context, v store.InsertVideoParams) error {
	var fanned int64
	err := p.inAuthorTx(ctx, v.AuthorID, func(q *store.Queries) error {
		if err := q.InsertVideo(ctx, v); err != nil {
			return fmt.Errorf("insert video: %w", err)
		}
		n, err := q.FanOutVideo(ctx, store.FanOutVideoParams{VideoID: v.VideoID, AuthorID: v.AuthorID})
		if err != nil {
			return fmt.Errorf("fan out video: %w", err)
		}
		fanned = n
		return nil
	})
	if err != nil {
		return err
	}
	p.logger.InfoContext(ctx, "video fanned out", slog.Int64("timeline_rows", fanned))
	return nil
}

// inAuthorTx runs fn in a transaction whose first statement takes the advisory lock of author,
// so follow, unfollow and fan-out of one author never interleave, across topics and replicas.
func (p *Projector) inAuthorTx(ctx context.Context, author uuid.UUID, fn func(q *store.Queries) error) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	// After Commit this is a no-op; on ctx cancellation it still reaches the server.
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	q := p.queries.WithTx(tx)
	if err := q.LockAuthor(ctx, author); err != nil {
		return fmt.Errorf("lock author: %w", err)
	}
	if err := fn(q); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}
	return nil
}

// PruneTimeline deletes timeline rows older than 30 days, a batch at a time until none is left,
// and returns how many it deleted. Reads filter those rows out anyway, so running late, twice or
// on several replicas at once is harmless.
func (p *Projector) PruneTimeline(ctx context.Context) (int64, error) {
	return p.pruneTimeline(ctx, pruneBatch)
}

func (p *Projector) pruneTimeline(ctx context.Context, batch int32) (int64, error) {
	var total int64
	for {
		n, err := p.queries.DeleteExpiredTimeline(ctx, batch)
		total += n
		if err != nil {
			return total, fmt.Errorf("delete expired timeline rows: %w", err)
		}
		if n < int64(batch) {
			return total, nil
		}
	}
}
