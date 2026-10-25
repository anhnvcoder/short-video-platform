-- +goose Up
-- When the video last moved from UPLOADING to PROCESSING, the start of svp.video.ready.duration.
-- Videos that left UPLOADING before this migration keep NULL and record no sample.
ALTER TABLE videos ADD COLUMN processing_at timestamptz;

-- +goose Down
ALTER TABLE videos DROP COLUMN processing_at;
