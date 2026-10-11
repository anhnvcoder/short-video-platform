-- +goose Up
-- email is stored trimmed and lower-cased by the service, so the unique constraint makes the
-- comparison case-insensitive. The constraint is named because the service maps its violation
-- to ALREADY_EXISTS.
CREATE TABLE users (
    id            uuid        PRIMARY KEY,
    email         text        NOT NULL,
    password_hash text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_email_key UNIQUE (email)
);

-- +goose Down
DROP TABLE users;
