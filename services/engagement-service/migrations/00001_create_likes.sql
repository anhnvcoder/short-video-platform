-- +goose Up
-- Likes and their counter, changed in one transaction: like_count moves only when a likes row
-- is really inserted or deleted. A transaction locks the likes row first and the like_counts row
-- second, so concurrent likes on one video never deadlock. The CHECK catches a code bug; the
-- count never goes negative.
CREATE TABLE likes (
    video_id   uuid        NOT NULL,
    user_id    uuid        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, user_id)
);

CREATE TABLE like_counts (
    video_id   uuid   PRIMARY KEY,
    like_count bigint NOT NULL CHECK (like_count >= 0)
);

-- +goose Down
DROP TABLE like_counts;
DROP TABLE likes;
