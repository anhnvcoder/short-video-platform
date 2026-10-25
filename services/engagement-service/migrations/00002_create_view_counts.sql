-- +goose Up
-- View counters, added in batches by the view.recorded consumer. consumer_offsets holds, per
-- partition, the next offset not yet counted; it changes in the same transaction as
-- view_counts, so a redelivered record is counted once.
CREATE TABLE view_counts (
    video_id   uuid        PRIMARY KEY,
    view_count bigint      NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE consumer_offsets (
    consumer_group text        NOT NULL,
    topic          text        NOT NULL,
    partition      int         NOT NULL,
    next_offset    bigint      NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_group, topic, partition)
);

-- +goose Down
DROP TABLE consumer_offsets;
DROP TABLE view_counts;
