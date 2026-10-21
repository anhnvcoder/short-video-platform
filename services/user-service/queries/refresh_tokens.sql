-- name: CreateRefreshToken :exec
INSERT INTO refresh_tokens (id, family_id, user_id, token_hash, created_at, expires_at, family_expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7);

-- name: GetRefreshTokenOwner :one
-- The family and user of a token, read before the family lock is taken; neither ever changes.
SELECT family_id, user_id FROM refresh_tokens
WHERE token_hash = $1;

-- name: LockRefreshFamily :exec
-- Serializes every rotation, reuse check and logout of one family until the transaction ends, so
-- a rotation running beside a logout, or beside the reuse of an ancestor token, cannot add a live
-- token to a family that has just been revoked (docs/adr/0016-web-client.md, section 2). Under
-- READ COMMITTED each statement after it sees all that the previous holder committed, so the
-- token must be read again once the lock is held.
SELECT pg_advisory_xact_lock(hashtextextended('refresh-family:' || sqlc.arg(family_id)::uuid::text, 0));

-- name: GetRefreshToken :one
SELECT id, family_id, user_id, expires_at, family_expires_at,
       (used_at IS NOT NULL)::boolean AS used, (revoked_at IS NOT NULL)::boolean AS revoked
FROM refresh_tokens
WHERE token_hash = $1;

-- name: MarkRefreshTokenUsed :execrows
-- The family lock already rules out a second rotation of the same token; the conditions are a
-- second layer, and the caller requires exactly one changed row.
UPDATE refresh_tokens SET used_at = @now::timestamptz
WHERE id = @id AND used_at IS NULL AND revoked_at IS NULL AND expires_at > @now::timestamptz;

-- name: RevokeRefreshFamily :execrows
UPDATE refresh_tokens SET revoked_at = @now::timestamptz
WHERE family_id = @family_id AND revoked_at IS NULL;
