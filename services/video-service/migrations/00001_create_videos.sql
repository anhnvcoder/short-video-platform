-- +goose Up
-- author_id has no foreign key: users live in user-service's database.
-- duration_ms, playlist_key, thumbnail_key and published_at stay NULL until the video is READY.
CREATE TABLE videos (
    id            uuid        PRIMARY KEY,
    author_id     uuid        NOT NULL,
    title         text        NOT NULL,
    status        text        NOT NULL CHECK (status IN ('UPLOADING', 'PROCESSING', 'READY', 'FAILED')),
    size_bytes    bigint      NOT NULL,
    content_type  text        NOT NULL,
    duration_ms   bigint,
    playlist_key  text,
    thumbnail_key text,
    published_at  timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE videos;
