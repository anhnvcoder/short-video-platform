-- +goose Up
-- Partial indexes over the videos still UPLOADING: the per-author count of open uploads in
-- InitUpload (UP-7) and the sweep of abandoned uploads. They hold only the few videos being
-- uploaded, not every published one.
CREATE INDEX videos_uploading_author_idx ON videos (author_id, created_at) WHERE status = 'UPLOADING';
CREATE INDEX videos_uploading_created_idx ON videos (created_at) WHERE status = 'UPLOADING';

-- +goose Down
DROP INDEX videos_uploading_created_idx;
DROP INDEX videos_uploading_author_idx;
