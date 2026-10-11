-- +goose Up
-- A stand-in entity table for the tests that lock a row before writing its event.
CREATE TABLE videos (
    id     uuid PRIMARY KEY,
    status text NOT NULL
);

-- +goose Down
DROP TABLE videos;
