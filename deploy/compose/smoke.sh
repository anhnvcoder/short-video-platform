#!/usr/bin/env bash
# End-to-end smoke test of the core stack through the gateway: register and log in user A,
# create and read a video, check the visibility rule against user B (threat model UP-3), B
# follows A; then upload a real video through its presigned form, complete it, wait for the
# asynchronous transcode to make it READY, play its HLS anonymously, and check that the storage
# refuses a file larger than declared (UP-1); then find the video in B's following feed and in
# explore, like and unlike it, count views (a repeated view within 60 s is accepted but not
# counted, RL-3), and check that unfollowing removes it from B's following feed (ADR-0009,
# ADR-0010). Prints one ok/FAIL line per step and exits non-zero on the first
# failure. Needs curl, jq, openssl, ffmpeg and redis-cli on the host, and the native Redis on
# 127.0.0.1:6379 (lib.sh resets the register rate limit there).
#
# Usage: deploy/compose/smoke.sh [base-url]   (default http://127.0.0.1:8080)
#
# The same steps run against the local k3d cluster svp with `make k8s-smoke`: base
# https://api.svp.localhost:8443, CURL_CA_BUNDLE=.k8s/ca.crt so curl trusts the cluster's CA for
# the API and the storage alike, and SVP_STACK=k3d so lib.sh resets the limit in the cluster's
# Valkey (kubectl, context k3d-svp) instead of the host's Redis.
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/lib.sh"

# 1. Wait for the gateway and the three services behind /readyz (user, video, feed) to be ready.
wait_gateway_ready 60

# 2. User A creates a video and reads it back.
new_user a
title="smoke video $(openssl rand -hex 4)"
jq -n --arg t "$title" '{title: $t, size_bytes: 1048576, content_type: "video/mp4"}' >"$work/video.json"
status=$(request POST /videos "$work/a.auth" "$work/video.json")
video_id=$(field video_id)
[[ $status == 201 && -n $video_id ]] || fail "create video (status $status, $(problem_summary))"
ok "create video"

status=$(request GET "/videos/$video_id" "$work/a.auth")
[[ $status == 200 ]] || fail "author reads video (status $status, $(problem_summary))"
[[ $(field status) == UPLOADING ]] || fail "video status is UPLOADING (got $(field status))"
[[ $(field title) == "$title" ]] || fail "video title round-trips"
[[ $(field author_id) == "$a_id" ]] || fail "video author_id is user A"
ok "author reads video: UPLOADING, title, author_id"

# 3. No token: 401 problem+json.
status=$(request GET "/videos/$video_id")
[[ $status == 401 && $(<"$work/type") == application/problem+json* ]] ||
  fail "read video without token is 401 problem+json (status $status, type $(<"$work/type"))"
ok "read video without token: 401 problem+json"

# 4. User B cannot see A's video while it is not READY (UP-3).
new_user b
status=$(request GET "/videos/$video_id" "$work/b.auth")
[[ $status == 404 && $(field code) == VIDEO_NOT_FOUND ]] ||
  fail "other user reads unpublished video is 404 VIDEO_NOT_FOUND (status $status, $(problem_summary))"
ok "other user reads unpublished video: 404 VIDEO_NOT_FOUND"

# 5. B follows A twice (idempotent) before A uploads, so A's upload reaches B's following feed by
# fan-out. B unfollows in step 15.
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow (status $status, $(problem_summary))"
ok "follow"
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow again (status $status, $(problem_summary))"
ok "follow again"

# 6. User A uploads a real 10 s 720p video through the presigned form and completes it.
make_video "$work/clip.mp4" 10 1280x720
clip_size=$(file_size "$work/clip.mp4")
create_video clip "$work/a.auth" "smoke upload $(openssl rand -hex 4)" "$clip_size" video/mp4
ok "create video for upload ($clip_size bytes)"

status=$(upload_file clip "$work/clip.mp4")
[[ $status == 2?? ]] || fail "upload to the presigned form (status $status, code $(storage_error_code))"
ok "upload to the presigned form"

status=$(complete_upload clip "$work/a.auth")
[[ $status == 202 && $(field status) == PROCESSING ]] ||
  fail "complete upload is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
ok "complete upload: 202 PROCESSING"

# 7. The transcode runs asynchronously (outbox, Redpanda, media-worker, Redpanda, video-service).
wait_ready clip "$work/a.auth" 180
playlist_url=$(field playlist_url)
thumbnail_url=$(field thumbnail_url)
[[ -n $playlist_url && -n $thumbnail_url ]] || fail "READY video has playlist_url and thumbnail_url"
ok "video READY after ${clip_wait} s, playlist_url and thumbnail_url set"

# 8. Anyone can play it: master playlist, one variant playlist, one segment, the thumbnail.
status=$(fetch "$playlist_url" "$work/master.m3u8")
[[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$work/master.m3u8" ||
  fail "anonymous GET master.m3u8 is 200 with #EXT-X-STREAM-INF (status $status)"
ok "anonymous GET master.m3u8"

variant_url=$(resolve "$playlist_url" "$(first_uri "$work/master.m3u8")")
status=$(fetch "$variant_url" "$work/variant.m3u8")
segment_ref=$(first_uri "$work/variant.m3u8")
[[ $status == 200 && -n $segment_ref ]] || fail "anonymous GET variant playlist is 200 with a segment (status $status)"
ok "anonymous GET variant playlist"

status=$(fetch "$(resolve "$variant_url" "$segment_ref")" "$work/segment")
[[ $status == 200 && -s $work/segment ]] || fail "anonymous GET segment is 200 and not empty (status $status)"
ok "anonymous GET segment ($(file_size "$work/segment") bytes)"

status=$(fetch "$thumbnail_url" "$work/thumbnail")
[[ $status == 200 && -s $work/thumbnail ]] || fail "anonymous GET thumbnail is 200 and not empty (status $status)"
ok "anonymous GET thumbnail"

# The uploaded original stays private (UP-5).
status=$(fetch "$(upload_url clip)/$(upload_key clip)" "$work/original")
[[ $status == 403 ]] || fail "anonymous GET of the uploaded original is 403 (status $status)"
ok "anonymous GET of the uploaded original: 403"

# The media bucket can be read object by object but not listed, so video ids are not enumerable
# (UP-6). playlist_url is <storage>/media/<key>, so the bucket URL is the part before the key.
media_bucket_url="${playlist_url%%/media/*}/media"
for query in "list-type=2" "list-type=2&prefix=media/"; do
  status=$(fetch "$media_bucket_url?$query" "$work/listing")
  [[ $status == 403 ]] || fail "anonymous listing of the media bucket ($query) is 403 (status $status)"
done
ok "anonymous listing of the media bucket: 403"

# 9. User B now sees A's READY video.
status=$(request GET "/videos/$clip_id" "$work/b.auth")
[[ $status == 200 && $(field status) == READY ]] ||
  fail "other user reads READY video (status $status, $(problem_summary))"
ok "other user reads READY video"

# 10. The storage enforces the declared size: one byte more than declared is refused (UP-1). Any
# other refusal (an expired policy, a bad signature) would not show that, so the code is pinned.
create_video big "$work/a.auth" "smoke oversize $(openssl rand -hex 4)" 1024 video/mp4
head -c 1025 /dev/urandom >"$work/big.bin"
status=$(upload_file big "$work/big.bin")
code=$(storage_error_code)
[[ $status == 400 && $code == EntityTooLarge ]] ||
  fail "upload larger than size_bytes is refused with 400 EntityTooLarge (status $status, code $code)"
ok "upload larger than size_bytes refused by the storage: $status $code"

# 11. The READY video reaches B's following feed (video.ready, feed-service fan-out) and explore,
# and the playlist_url of the feed item plays.
wait_feed_item following "$work/b.auth" "$clip_id" 15 '. != null' "video in B's following feed"
feed_playlist_url=$(jq -r '.playlist_url' "$work/item")
ok "video in B's following feed"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '. != null' "video in explore"
ok "video in explore"
status=$(fetch "$feed_playlist_url" "$work/feed-master.m3u8")
[[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$work/feed-master.m3u8" ||
  fail "anonymous GET of the feed item's playlist_url is 200 with #EXT-X-STREAM-INF (status $status)"
ok "anonymous GET of the feed item's playlist_url"

# 12. Likes: B likes twice (idempotent), counted once and seen as B's own like, not A's; then B
# unlikes. The feed carries stats only when engagement-service answers in time, so every stats
# check polls.
for i in 1 2; do
  status=$(request PUT "/videos/$clip_id/like" "$work/b.auth")
  [[ $status == 204 ]] || fail "B likes the video, call $i (status $status, $(problem_summary))"
done
ok "B likes the video twice: 204"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '.stats.like_count == 1 and .stats.liked_by_me == true' \
  "like_count 1, liked_by_me true for B"
ok "like_count 1, liked_by_me true for B"
wait_feed_item explore "$work/a.auth" "$clip_id" 15 '.stats.like_count == 1 and .stats.liked_by_me == false' \
  "like_count 1, liked_by_me false for A"
ok "like_count 1, liked_by_me false for A"
status=$(request DELETE "/videos/$clip_id/like" "$work/b.auth")
[[ $status == 204 ]] || fail "B unlikes the video (status $status, $(problem_summary))"
wait_feed_item explore "$work/b.auth" "$clip_id" 15 '.stats.like_count == 0 and .stats.liked_by_me == false' \
  "like_count 0 after unlike"
ok "B unlikes the video: like_count 0"

# 13. Views are counted asynchronously (engagement.views.v1, batched by engagement-service). The
# gateway counts one view per user and video every 60 s (RL-3): B's repeated views are still
# accepted with 202, but only the first is counted; A's view is counted too.
for i in 1 2 3; do
  status=$(request POST "/videos/$clip_id/views" "$work/b.auth")
  [[ $status == 202 ]] || fail "B records view $i (status $status, $(problem_summary))"
done
ok "B records 3 views: 202"
wait_feed_item explore "$work/b.auth" "$clip_id" 30 '.stats.view_count == 1' "view_count 1 after B's 3 views (RL-3)"
ok "view_count 1 after B's 3 views (RL-3)"
status=$(request POST "/videos/$clip_id/views" "$work/a.auth")
[[ $status == 202 ]] || fail "A records a view (status $status, $(problem_summary))"
wait_feed_item explore "$work/b.auth" "$clip_id" 30 '.stats.view_count == 2' "view_count 2 after A's view"
ok "A records a view: 202, view_count 2"

# 14. A cursor that cannot be decoded is refused.
status=$(request GET "/feed/following?cursor=abc" "$work/b.auth")
[[ $status == 400 && $(field code) == INVALID_PAGE_TOKEN ]] ||
  fail "following feed with cursor=abc is 400 INVALID_PAGE_TOKEN (status $status, $(problem_summary))"
ok "following feed with cursor=abc: 400 INVALID_PAGE_TOKEN"

# 15. B unfollows A (user.unfollowed): the video leaves B's following feed but stays in explore.
status=$(request DELETE "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "unfollow (status $status, $(problem_summary))"
ok "unfollow"
wait_feed_item following "$work/b.auth" "$clip_id" 15 '. == null' "video gone from B's following feed after unfollow"
ok "video gone from B's following feed after unfollow"
status=$(feed_item explore "$work/b.auth" "$clip_id")
[[ $status == 200 && $(<"$work/item") != null ]] ||
  fail "video still in explore after unfollow (status $status, $(item_summary))"
ok "video still in explore after unfollow"

echo "smoke: all steps passed"
