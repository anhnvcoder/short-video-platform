-- +goose Up
-- The feed read model, built from user.follows.v1 and video.lifecycle.v1. No foreign keys: users
-- and videos live in other services' databases, and the events of the two topics come in any order.

-- Keyed by followee, the reverse of user-service's follows: fan-out looks up an author's followers.
CREATE TABLE follows (
    followee_id uuid        NOT NULL,
    follower_id uuid        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (followee_id, follower_id)
);

-- READY videos. The first video.ready wins (ON CONFLICT DO NOTHING), so a video's published_at never
-- changes here, and the timeline's primary key keeps one row per user and video.
CREATE TABLE videos (
    video_id      uuid        PRIMARY KEY,
    author_id     uuid        NOT NULL,
    title         text        NOT NULL,
    duration_ms   bigint      NOT NULL,
    playlist_key  text        NOT NULL,
    thumbnail_key text        NOT NULL,
    published_at  timestamptz NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);
-- Backfill on follow.
CREATE INDEX videos_author_published_idx ON videos (author_id, published_at DESC, video_id DESC);
-- Explore feed.
CREATE INDEX videos_published_idx ON videos (published_at DESC, video_id DESC);

-- One row per follower and video of the last 30 days. The primary key both rejects duplicates and
-- serves the keyset read; there is no other index, so fan-out updates one. created_at is the time
-- each row was inserted, to see how long a fan-out took.
CREATE TABLE timeline (
    user_id      uuid        NOT NULL,
    published_at timestamptz NOT NULL,
    video_id     uuid        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, published_at, video_id)
);

-- +goose Down
DROP TABLE timeline;
DROP TABLE videos;
DROP TABLE follows;
