-- name: InsertConsumerOffset :exec
-- Creates the offset row of a partition the first time it is seen; an existing row is kept.
INSERT INTO consumer_offsets (consumer_group, topic, partition, next_offset)
VALUES (@consumer_group, @topic, @partition, 0)
ON CONFLICT (consumer_group, topic, partition) DO NOTHING;

-- name: LockConsumerOffset :one
-- Holds the offset row until the transaction ends, so a second consumer of the same partition
-- waits, then reads the offset this one committed.
SELECT next_offset
FROM consumer_offsets
WHERE consumer_group = @consumer_group AND topic = @topic AND partition = @partition
FOR UPDATE;

-- name: SetConsumerOffset :exec
UPDATE consumer_offsets
SET next_offset = @next_offset, updated_at = now()
WHERE consumer_group = @consumer_group AND topic = @topic AND partition = @partition;

-- name: AddViewCounts :exec
-- Adds counts[i] to the counter of video_ids[i]. Callers pass each id once, in ascending order,
-- so concurrent batches lock the rows in the same order. Two unnest calls in the select list zip
-- arrays of equal length (sqlc does not parse the two-argument unnest in FROM).
INSERT INTO view_counts (video_id, view_count)
SELECT unnest(@video_ids::uuid[]), unnest(@counts::bigint[])
ON CONFLICT (video_id) DO UPDATE
SET view_count = view_counts.view_count + EXCLUDED.view_count, updated_at = now();
