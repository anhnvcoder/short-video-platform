#!/usr/bin/env bash
# Drill: deliver the stage 2B events twice and check the counters and the feed read model do not
# change. With fresh users A and B, B following A and A's video READY
# in B's feed, liked by B and viewed 5 times by B (counted once: the gateway forwards one view per
# user and video every 60 s, RL-3):
#   1. stop engagement-service, move group engagement-service on engagement.views.v1 back to the
#      run's view.recorded, start it, wait for lag 0: view_count is still 1 and the like count is
#      unchanged (offsets kept in svp_engagement filter the replay);
#   2. stop feed-service, move group feed-service on user.follows.v1 back to B's user.followed
#      and on video.lifecycle.v1 back to the video's video.ready, start it, wait for lag 0: B's
#      follows, B's timeline and the video's row in svp_feed are the same, row for row;
#   3. B unfollows A, the video leaves B's following feed; replay as in 2: the partition delivers
#      user.followed then user.unfollowed again, so B's timeline ends without A's video.
# Records are found by key and event branch, never by "end of topic", so the drill runs again on
# topics full of earlier runs. Prints one ok/FAIL line per check and exits non-zero on the first
# failure; on exit every stack service runs again. Reads svp_engagement and svp_feed with SELECT
# only.
#
# Usage (from the repo root, stack up): make drill-duplicates-feed
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# Views B records, and how many of them are counted: the gateway forwards only the first within
# 60 s (RL-3). The drill waits until the counter shows them before the replay.
views=5
counted=1

# select_rows DB: runs the SELECT on stdin against DB with the psql variables a, b and v (user A,
# user B, the video); prints one space-separated line per row.
select_rows() {
  psql -h 127.0.0.1 -p 5432 -U postgres -d "$1" -w -X -q -At -F ' ' -v ON_ERROR_STOP=1 \
    -v a="$a_id" -v b="$b_id" -v v="$clip_id"
}

# engagement_state FILE: the video's view and like counters and likes rows in svp_engagement.
engagement_state() {
  select_rows svp_engagement >"$1" <<'SQL' || fail "read the counters of video $clip_id from svp_engagement"
SELECT 'view_counts', video_id, view_count, updated_at FROM view_counts WHERE video_id = :'v';
SELECT 'like_counts', video_id, like_count FROM like_counts WHERE video_id = :'v';
SELECT 'likes', video_id, user_id, created_at FROM likes WHERE video_id = :'v' ORDER BY user_id;
SQL
}

# feed_state FILE: B's follows and timeline rows and the video's row in svp_feed.
feed_state() {
  select_rows svp_feed >"$1" <<'SQL' || fail "read the read model of B and video $clip_id from svp_feed"
SELECT 'follows', followee_id, follower_id, created_at FROM follows WHERE follower_id = :'b'
ORDER BY followee_id;
SELECT 'timeline', user_id, published_at, video_id, created_at FROM timeline WHERE user_id = :'b'
ORDER BY published_at, video_id;
SELECT 'videos', video_id, author_id, title, duration_ms, playlist_key, thumbnail_key, published_at, created_at
FROM videos WHERE video_id = :'v';
SQL
}

# same_state STEP BEFORE AFTER WHAT: fails with a diff unless the two snapshots are identical.
same_state() {
  if ! diff "$2" "$3" >&2; then
    fail "$1: $4 identical before and after the replay (diff above)"
  fi
  ok "$1: $4 identical ($(count_lines "$(<"$3")") rows)"
}

# rows FILE TABLE: how many rows of TABLE a snapshot holds.
rows() { grep -c "^$2 " "$1" || true; }

# first_record TOPIC KEY TAG WHAT: sets part and offset to the first record of key_records.
first_record() {
  key_records "$1" "$2" "$3"
  part= offset=
  read -r part offset <<<"$records" || true
  [[ -n $offset ]] || fail "find $4 on $1"
}

# replay_feed STEP: stops feed-service, seeks group feed-service on user.follows.v1 back to B's
# user.followed and on video.lifecycle.v1 back to the video's video.ready, starts it and waits
# until it consumed everything again.
replay_feed() {
  local follow_part follow_offset
  first_record user.follows.v1 "$b_id" 12 "B's user.followed"
  follow_part=$part follow_offset=$offset
  first_record video.lifecycle.v1 "$clip_id" 1a "the video's video.ready"
  ok "$1: user.followed of B is user.follows.v1 $follow_part@$follow_offset, video.ready is video.lifecycle.v1 $part@$offset"
  stop_consumer feed-service feed-service
  seek_group feed-service user.follows.v1 "$follow_part" "$follow_offset"
  seek_group feed-service video.lifecycle.v1 "$part" "$offset"
  # One group, two topics, one seek each: the second seek must keep the first one.
  [[ $(group_offset feed-service user.follows.v1 "$follow_part") == "$follow_offset" ]] ||
    fail "$1: group feed-service keeps user.follows.v1 $follow_part@$follow_offset after the second seek"
  ok "$1: group feed-service set back on both topics (lag to replay: $(group_field feed-service TOTAL-LAG))"
  start_service feed-service
  wait_gateway_ready 60
  wait_caught_up 120 feed-service
  sleep "$settle_seconds"
  ok "$1: feed-service consumed the replay (lag 0)"
}

wait_gateway_ready 60
new_user a
new_user b
check_uuid "$a_id"
check_uuid "$b_id"

# Setup: B follows A, A's video goes READY and reaches B's following feed, B likes it and views
# it $views times.
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "B follows A (status $status, $(problem_summary))"
ok "B follows A"
make_video "$work/clip.mp4" 5 1280x720
upload_video clip "$work/a.auth" "$work/clip.mp4"
wait_ready clip "$work/a.auth" 300
ok "video $clip_id READY after ${clip_wait} s"
wait_feed_item following "$work/b.auth" "$clip_id" 30 '. != null' "video in B's following feed"
ok "video in B's following feed"
status=$(request PUT "/videos/$clip_id/like" "$work/b.auth")
[[ $status == 204 ]] || fail "B likes the video (status $status, $(problem_summary))"
for ((i = 1; i <= views; i++)); do
  status=$(request POST "/videos/$clip_id/views" "$work/b.auth")
  [[ $status == 202 ]] || fail "B records view $i (status $status, $(problem_summary))"
done
ok "B likes the video and records $views views"

# Views are counted in batches of up to 1 s: wait for all of them before taking the snapshot.
deadline=$((SECONDS + 60))
while :; do
  # A failed query must fail here, not count as "not yet": `until [[ $(select_rows) == 5 ]]`
  # would wait out the deadline and then blame the counter.
  count=$(select_rows svp_engagement <<<"SELECT view_count FROM view_counts WHERE video_id = :'v';") ||
    fail "read view_count of video $clip_id from svp_engagement"
  [[ $count != "$counted" ]] || break
  ((SECONDS < deadline)) || fail "view_count of the video reaches $counted within 60 s (still '$count')"
  sleep 1
done
wait_caught_up 60 engagement-service feed-service
engagement_state "$work/engagement.before"
feed_state "$work/feed.before"
[[ $(rows "$work/engagement.before" like_counts) == 1 && $(rows "$work/feed.before" follows) == 1 &&
  $(rows "$work/feed.before" timeline) == 1 && $(rows "$work/feed.before" videos) == 1 ]] ||
  fail "snapshot holds the counters, B's follow, B's timeline row and the video"
ok "view_count $counted after $views views (RL-3), like_count 1; svp_feed: 1 follow, 1 timeline row, 1 video for this run"

# 1. Replay view.recorded to engagement-service.
first_record engagement.views.v1 "$clip_id" 12 "the video's first view.recorded"
replayed=$(count_lines "$records")
[[ $replayed == "$counted" ]] || fail "engagement.views.v1 holds $counted view.recorded of the video (got $replayed)"
ok "first view.recorded of the video is engagement.views.v1 partition $part offset $offset ($replayed of the video)"
stop_consumer engagement-service engagement-service
seek_group engagement-service engagement.views.v1 "$part" "$offset"
start_service engagement-service
wait_caught_up 120 engagement-service
sleep "$settle_seconds"
ok "engagement-service consumed the replay (lag 0)"
engagement_state "$work/engagement.after"
same_state "replayed view.recorded" "$work/engagement.before" "$work/engagement.after" \
  "view_count $counted, like_count and likes of the video"

# 2. Replay user.followed and video.ready to feed-service.
replay_feed "replayed follow"
feed_state "$work/feed.after"
same_state "replayed follow" "$work/feed.before" "$work/feed.after" "B's follows, B's timeline and the video row"

# 3. B unfollows A, then the same replay: followed and unfollowed come back in partition order.
status=$(request DELETE "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "B unfollows A (status $status, $(problem_summary))"
wait_feed_item following "$work/b.auth" "$clip_id" 30 '. == null' "video gone from B's following feed after unfollow"
wait_caught_up 60 feed-service
feed_state "$work/feed.unfollowed"
[[ $(rows "$work/feed.unfollowed" follows) == 0 && $(rows "$work/feed.unfollowed" timeline) == 0 ]] ||
  fail "after unfollow svp_feed holds no follow and no timeline row for B"
ok "B unfollowed A: video gone from B's following feed, no follow or timeline row for B"
replay_feed "replayed follow and unfollow"
feed_state "$work/feed.replayed"
same_state "replayed follow and unfollow" "$work/feed.unfollowed" "$work/feed.replayed" \
  "B's follows, B's timeline (no video of A) and the video row"
status=$(feed_item following "$work/b.auth" "$clip_id")
[[ $status == 200 && $(<"$work/item") == null ]] ||
  fail "video still absent from B's following feed after the replay (status $status, $(item_summary))"
ok "video still absent from B's following feed after the replay"

echo "drill-duplicates-feed: all checks passed"
