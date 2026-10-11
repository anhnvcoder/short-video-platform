-- name: GetStats :many
-- One row per element of video_ids, in the same order and repeated when an id repeats; unknown
-- ids get zeros. Every join is a primary key lookup, so no table is scanned.
SELECT
    COALESCE(v.view_count, 0)::bigint AS view_count,
    COALESCE(l.like_count, 0)::bigint AS like_count,
    (m.user_id IS NOT NULL)::boolean AS liked_by_me
FROM unnest(@video_ids::uuid[]) WITH ORDINALITY AS r(video_id, ord)
LEFT JOIN view_counts v ON v.video_id = r.video_id
LEFT JOIN like_counts l ON l.video_id = r.video_id
LEFT JOIN likes m ON m.video_id = r.video_id AND m.user_id = @caller_id::uuid
ORDER BY r.ord;
