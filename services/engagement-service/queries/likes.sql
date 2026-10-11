-- name: InsertLike :execrows
-- Returns 0 when the caller already likes the video; a concurrent insert of the same row waits
-- for the other transaction and then inserts nothing.
INSERT INTO likes (video_id, user_id)
VALUES ($1, $2)
ON CONFLICT (video_id, user_id) DO NOTHING;

-- name: IncrementLikeCount :exec
INSERT INTO like_counts (video_id, like_count)
VALUES ($1, 1)
ON CONFLICT (video_id) DO UPDATE SET like_count = like_counts.like_count + 1;

-- name: DeleteLike :execrows
-- Returns 0 when the caller does not like the video.
DELETE FROM likes
WHERE video_id = $1 AND user_id = $2;

-- name: DecrementLikeCount :exec
UPDATE like_counts SET like_count = like_count - 1
WHERE video_id = $1;
