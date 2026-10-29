-- name: Like :exec
-- Inserts the caller's like and, only when the row is new, adds one to like_count, in one
-- statement and so one implicit transaction: liking twice counts once. A concurrent insert of
-- the same row waits for the other transaction and then inserts nothing. The counter upsert reads
-- the rows the insert returns, so the likes row is locked before the like_counts row.
WITH inserted AS (
    INSERT INTO likes (video_id, user_id)
    VALUES (@video_id, @user_id)
    ON CONFLICT (video_id, user_id) DO NOTHING
    RETURNING video_id
)
INSERT INTO like_counts (video_id, like_count)
SELECT video_id, 1 FROM inserted
ON CONFLICT (video_id) DO UPDATE SET like_count = like_counts.like_count + 1;

-- name: Unlike :exec
-- Deletes the caller's like and, only when a row was deleted, takes one from like_count, in one
-- statement: unliking a video not liked changes nothing, and like_count never goes below the
-- number of likes rows. The counter update joins the rows the delete returns, so the likes row is
-- locked before the like_counts row.
WITH deleted AS (
    DELETE FROM likes
    WHERE likes.video_id = @video_id AND likes.user_id = @user_id
    RETURNING likes.video_id
)
UPDATE like_counts SET like_count = like_counts.like_count - 1
FROM deleted
WHERE like_counts.video_id = deleted.video_id;
