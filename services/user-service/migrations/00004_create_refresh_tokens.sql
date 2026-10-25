-- +goose Up
-- One row per refresh token. Only the SHA-256 of the
-- token is stored, so a leaked table yields no usable token. A login starts a family (family_id is
-- the id of its first token); every rotation adds a row to the same family and marks the old one
-- used, and a used token presented again, or a logout, revokes the whole family. Used rows stay
-- until the family expires so that reuse can still be detected. The service passes every time in
-- from its own clock instead of using now(), so tests can move past an expiry without waiting.
-- family_expires_at, the 30-day ceiling of the login, is copied to every row because a rotated
-- token needs it and the family's first row may be gone by then. Deleting a user deletes its
-- tokens. The constraints are named because the service matches the foreign key's violation.
CREATE TABLE refresh_tokens (
    id                uuid        NOT NULL,
    family_id         uuid        NOT NULL,
    user_id           uuid        NOT NULL,
    token_hash        bytea       NOT NULL,
    created_at        timestamptz NOT NULL,
    expires_at        timestamptz NOT NULL,
    family_expires_at timestamptz NOT NULL,
    used_at           timestamptz,
    revoked_at        timestamptz,
    CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT refresh_tokens_token_hash_key UNIQUE (token_hash),
    CONSTRAINT refresh_tokens_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT refresh_tokens_expires_within_family CHECK (expires_at <= family_expires_at),
    CONSTRAINT refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);
-- Serves the statement that revokes every token of a family.
CREATE INDEX refresh_tokens_family_id_idx ON refresh_tokens (family_id);

-- +goose Down
DROP TABLE refresh_tokens;
