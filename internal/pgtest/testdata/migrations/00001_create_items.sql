-- +goose Up
CREATE TABLE items (
    id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL
);

-- +goose Down
DROP TABLE items;
