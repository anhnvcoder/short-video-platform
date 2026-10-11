-- +goose Up
-- One row per edge, follower -> followee. The primary key serves lookups by follower; no other
-- index until a query needs one. The foreign keys are named because the service maps their
-- violations: an unknown followee is NOT_FOUND, an unknown follower is UNAUTHENTICATED. Postgres
-- checks them in the order declared, so a missing follower is reported first.
CREATE TABLE follows (
    follower_id uuid        NOT NULL,
    followee_id uuid        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT follows_pkey PRIMARY KEY (follower_id, followee_id),
    CONSTRAINT follows_follower_id_fkey FOREIGN KEY (follower_id) REFERENCES users (id),
    CONSTRAINT follows_followee_id_fkey FOREIGN KEY (followee_id) REFERENCES users (id),
    CONSTRAINT follows_no_self_follow CHECK (follower_id <> followee_id)
);

-- +goose Down
DROP TABLE follows;
