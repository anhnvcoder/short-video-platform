-- name: LockAuthor :exec
-- Serializes every change to the follow edges and fan-out of one author until the transaction
-- ends, so a follower added during a fan-out still gets the new video and one removed does not
-- keep it (docs/adr/0009-engagement-feed-stage2b.md, section 7). It must be the transaction's first
-- statement: under READ COMMITTED each later statement then sees all that the previous holder
-- committed.
SELECT pg_advisory_xact_lock(hashtextextended('feed-author:' || sqlc.arg(author_id)::uuid::text, 0));

-- name: InsertFollow :exec
INSERT INTO follows (followee_id, follower_id)
VALUES (@followee_id, @follower_id)
ON CONFLICT DO NOTHING;

-- name: BackfillTimeline :execrows
-- Puts the followee's 20 newest videos of the last 30 days into the follower's timeline.
INSERT INTO timeline (user_id, published_at, video_id)
SELECT @follower_id::uuid, published_at, video_id FROM videos
WHERE author_id = @followee_id AND published_at > now() - interval '30 days'
ORDER BY published_at DESC, video_id DESC
LIMIT 20
ON CONFLICT DO NOTHING;

-- name: DeleteFollow :exec
DELETE FROM follows
WHERE followee_id = @followee_id AND follower_id = @follower_id;

-- name: DeleteAuthorFromTimeline :execrows
-- Removes every video of the followee from the follower's timeline.
DELETE FROM timeline t
USING videos v
WHERE t.user_id = @follower_id AND t.video_id = v.video_id AND v.author_id = @followee_id;

-- name: InsertVideo :execrows
-- The first video.ready wins: published_at of a stored video never changes. Returns 0 for a video
-- already stored.
INSERT INTO videos (video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (video_id) DO NOTHING;

-- name: FanOutVideo :execrows
-- Puts the video into the timeline of every follower of its author, with the published_at and
-- author stored in videos rather than the event's: a second video.ready naming another author
-- (forged, threat model IN-4) fans out to nobody.
INSERT INTO timeline (user_id, published_at, video_id)
SELECT f.follower_id, v.published_at, v.video_id
FROM follows f JOIN videos v ON v.video_id = @video_id AND v.author_id = @author_id
WHERE f.followee_id = @author_id
ON CONFLICT DO NOTHING;

-- name: DeleteExpiredTimeline :execrows
-- Deletes up to row_limit timeline rows older than 30 days.
DELETE FROM timeline
WHERE (user_id, published_at, video_id) IN (
    SELECT user_id, published_at, video_id FROM timeline
    WHERE published_at < now() - interval '30 days'
    LIMIT @row_limit
);

-- name: GetFollowingFeed :many
-- Reads a page of user's timeline of the last 30 days, newest first, strictly after the cursor
-- (before_published_at, before_video_id); a NULL before_published_at starts at the newest row.
-- The row comparison is an index condition on the timeline primary key, so a page costs the same
-- however deep it is.
SELECT v.video_id, v.author_id, v.title, v.duration_ms, v.playlist_key, v.thumbnail_key, v.published_at
FROM timeline t
JOIN videos v ON v.video_id = t.video_id
WHERE t.user_id = @user_id
  AND t.published_at > now() - interval '30 days'
  AND (t.published_at, t.video_id) < (COALESCE(sqlc.narg(before_published_at)::timestamptz, 'infinity'), @before_video_id::uuid)
ORDER BY t.published_at DESC, t.video_id DESC
LIMIT @row_limit;

-- name: GetExploreFeed :many
-- Reads a page of every READY video, newest first, strictly after the cursor, on
-- videos_published_idx; a NULL before_published_at starts at the newest video.
SELECT video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at
FROM videos
WHERE (published_at, video_id) < (COALESCE(sqlc.narg(before_published_at)::timestamptz, 'infinity'), @before_video_id::uuid)
ORDER BY published_at DESC, video_id DESC
LIMIT @row_limit;
