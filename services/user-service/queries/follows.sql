-- name: CreateFollow :exec
INSERT INTO follows (follower_id, followee_id)
VALUES ($1, $2)
ON CONFLICT (follower_id, followee_id) DO NOTHING;

-- name: DeleteFollow :exec
DELETE FROM follows
WHERE follower_id = $1 AND followee_id = $2;
