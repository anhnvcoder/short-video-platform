-- +goose Up
-- The keyset read of ListAuthorVideos (docs/adr/0018-web-profiles-public-video-upload.md, section
-- 4): one author's videos newest first by (created_at, id). The row comparison of the cursor is an
-- index condition here, so a page costs the same however deep it is. Every status is indexed: the
-- author's own list holds UPLOADING, PROCESSING and FAILED videos too.
CREATE INDEX videos_author_created_idx ON videos (author_id, created_at DESC, id DESC);

-- +goose Down
DROP INDEX videos_author_created_idx;
