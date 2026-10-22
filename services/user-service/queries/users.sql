-- name: CreateUser :exec
INSERT INTO users (id, email, password_hash, handle, display_name)
VALUES ($1, $2, $3, $4, $5);

-- name: GetUserByEmail :one
SELECT id, password_hash FROM users
WHERE email = $1;

-- name: UpdatePasswordHash :exec
UPDATE users SET password_hash = $2
WHERE id = $1;

-- name: GetProfiles :many
-- ANY answers a repeated id once and skips ids without a user.
SELECT id, handle, display_name FROM users
WHERE id = ANY(@ids::uuid[]);

-- name: GetProfileByHandle :one
-- follows has no self edge (follows_no_self_follow), so a caller reading their own profile gets false.
SELECT u.id, u.handle, u.display_name,
       EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = @caller_id AND f.followee_id = u.id) AS followed_by_me
FROM users u
WHERE u.handle = @handle;

-- name: UpdateDisplayName :one
UPDATE users SET display_name = @display_name
WHERE id = @id
RETURNING id, handle, display_name;
