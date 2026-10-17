-- +goose Up
-- Events waiting for the relay, written in the transaction that changes the follow edge, so an
-- event exists exactly when its change commits (docs/adr/0009-engagement-feed-stage2b.md, section 1;
-- internal/outbox).
CREATE TABLE outbox (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     uuid        NOT NULL UNIQUE,
    topic        text        NOT NULL,
    record_key   text        NOT NULL,
    payload      bytea       NOT NULL,
    headers      jsonb       NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);
CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;

-- +goose Down
DROP TABLE outbox;
