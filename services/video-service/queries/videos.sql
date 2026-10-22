-- name: CreateVideo :exec
INSERT INTO videos (id, author_id, title, status, size_bytes, content_type)
VALUES ($1, $2, $3, 'UPLOADING', $4, $5);

-- name: GetVideo :one
SELECT * FROM videos
WHERE id = $1;

-- name: MarkVideoProcessing :one
-- Locks the row; only an UPLOADING video moves, so a concurrent call updates nothing.
UPDATE videos SET status = 'PROCESSING', processing_at = now()
WHERE id = $1 AND status = 'UPLOADING'
RETURNING *;

-- name: MarkVideoReady :one
-- Locks the row; only a PROCESSING video moves, so a redelivered transcode.completed, or one for
-- a video that has failed meanwhile, updates nothing.
UPDATE videos
SET status = 'READY', duration_ms = $2, playlist_key = $3, thumbnail_key = $4, published_at = now()
WHERE id = $1 AND status = 'PROCESSING'
RETURNING *;

-- name: MarkVideoFailed :one
-- Only a PROCESSING video moves: READY stays READY, and a redelivery finds FAILED already.
UPDATE videos SET status = 'FAILED'
WHERE id = $1 AND status = 'PROCESSING'
RETURNING processing_at;

-- name: ClockTimestamp :one
-- The current time on Postgres's clock, the one that set processing_at. Read outside a
-- transaction after a commit, it marks when the committed status became visible; now() would
-- give the start of the transaction, before any lock wait.
SELECT clock_timestamp()::timestamptz AS now;

-- name: LockAuthorUploads :exec
-- Serializes the InitUpload calls of one author until the transaction ends, so two concurrent
-- calls cannot both pass the open upload count (UP-7). Other authors do not wait.
SELECT pg_advisory_xact_lock(hashtextextended('video-upload-author:' || sqlc.arg(author_id)::uuid::text, 0));

-- name: CountOpenUploads :one
-- Videos of the author still UPLOADING whose upload form may still be valid.
SELECT count(*) FROM videos
WHERE author_id = sqlc.arg(author_id) AND status = 'UPLOADING' AND created_at > sqlc.arg(created_after);

-- name: TryLockUploadSweep :one
-- Taken by the abandoned upload sweep for the rest of the transaction; false when another
-- instance holds it.
SELECT pg_try_advisory_xact_lock(sqlc.arg(lock_id)::bigint)::boolean AS locked;

-- name: ListAbandonedUploads :many
-- Locks the oldest videos still UPLOADING created before created_before. A row that a concurrent
-- CompleteUpload moves first is re-checked after its lock is released, and skipped.
SELECT id, author_id FROM videos
WHERE status = 'UPLOADING' AND created_at < sqlc.arg(created_before)
ORDER BY created_at
LIMIT sqlc.arg(max_videos)
FOR UPDATE;

-- name: MarkUploadsFailed :many
UPDATE videos SET status = 'FAILED'
WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND status = 'UPLOADING'
RETURNING id, author_id;

-- name: ListAuthorVideos :many
-- Reads a page of the videos of author_id, newest first, strictly after the cursor
-- (before_created_at, before_id); a NULL before_created_at starts at the newest video. Every status
-- when all_statuses (the caller is the author), otherwise only READY ones (UP-3). Runs on
-- videos_author_created_idx.
SELECT * FROM videos
WHERE author_id = @author_id
  AND (@all_statuses::boolean OR status = 'READY')
  AND (created_at, id) < (COALESCE(sqlc.narg(before_created_at)::timestamptz, 'infinity'), @before_id::uuid)
ORDER BY created_at DESC, id DESC
LIMIT @row_limit;
