-- name: CreateVideo :exec
INSERT INTO videos (id, author_id, title, status, size_bytes, content_type)
VALUES ($1, $2, $3, 'UPLOADING', $4, $5);

-- name: GetVideo :one
SELECT * FROM videos
WHERE id = $1;

-- name: MarkVideoProcessing :one
-- Locks the row; only an UPLOADING video moves, so a concurrent call updates nothing.
UPDATE videos SET status = 'PROCESSING'
WHERE id = $1 AND status = 'UPLOADING'
RETURNING *;

-- name: MarkVideoReady :one
-- Locks the row; only a PROCESSING video moves, so a redelivered transcode.completed, or one for
-- a video that has failed meanwhile, updates nothing.
UPDATE videos
SET status = 'READY', duration_ms = $2, playlist_key = $3, thumbnail_key = $4, published_at = now()
WHERE id = $1 AND status = 'PROCESSING'
RETURNING *;

-- name: MarkVideoFailed :execrows
-- Only a PROCESSING video moves: READY stays READY, and a redelivery finds FAILED already.
UPDATE videos SET status = 'FAILED'
WHERE id = $1 AND status = 'PROCESSING';
