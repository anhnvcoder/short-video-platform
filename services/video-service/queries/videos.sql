-- name: CreateVideo :exec
INSERT INTO videos (id, author_id, title, status, size_bytes, content_type)
VALUES ($1, $2, $3, 'UPLOADING', $4, $5);

-- name: GetVideo :one
SELECT * FROM videos
WHERE id = $1;
