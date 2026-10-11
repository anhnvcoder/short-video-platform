-- name: CreateUser :exec
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3);

-- name: GetUserByEmail :one
SELECT id, password_hash FROM users
WHERE email = $1;

-- name: UpdatePasswordHash :exec
UPDATE users SET password_hash = $2
WHERE id = $1;
