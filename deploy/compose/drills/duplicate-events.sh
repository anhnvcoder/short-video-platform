#!/usr/bin/env bash
# Drill: deliver events twice and check the consumers are idempotent: delivery is at least once, so a replay is
# normal (ADR-0003 rule 1, ADR-0008 section 8). With a fresh READY video:
#   1. stop video-service, move group video-service on media.transcodes.v1 back to the video's
#      transcode.completed (rpk group seek), start it, wait for lag 0: status, published_at and the
#      outbox rows of the video do not change;
#   2. stop media-worker, move group media-worker on video.lifecycle.v1 back to the video's
#      video.uploaded, start it, wait for the new transcode.completed and lag 0: video-service
#      ignores it as in 1, and master.m3u8 and every variant playlist are byte for byte the same.
# Records are found by key and event branch, never by "end of topic", so the drill runs again on
# a topic full of earlier runs. Prints one ok/FAIL line per check and exits non-zero on the first
# failure; on exit every stack service runs again.
#
# Usage (from the repo root, stack up): make drill-duplicates
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# check_unchanged STEP: status, published_at and outbox rows of the video are what they were
# before the replays.
check_unchanged() {
  video_status clip "$work/a.auth"
  [[ $clip_status == READY && $clip_published == "$published" ]] ||
    fail "$1: status and published_at unchanged (got $clip_status, $clip_published; was READY, $published)"
  [[ $(outbox_counts "$clip_id") == "$outbox" ]] ||
    fail "$1: outbox rows of the video unchanged (got $(outbox_counts "$clip_id"); was $outbox)"
  ok "$1: still READY, published_at $published, outbox $outbox (total uploaded ready)"
}

wait_gateway_ready 60
new_user a
make_video "$work/clip.mp4" 10 1280x720
upload_video clip "$work/a.auth" "$work/clip.mp4"
wait_ready clip "$work/a.auth" 300
playlist_url=$(field playlist_url)
video_status clip "$work/a.auth"
published=$clip_published
outbox=$(outbox_counts "$clip_id")
[[ $outbox == "2 1 1" ]] || fail "outbox holds video.uploaded and video.ready for the new video (got $outbox)"
hls=$(fetch_hls "$playlist_url" "$work/before")
ok "video $clip_id READY, published_at $published, outbox 2 rows, HLS $hls"
wait_caught_up 60 media-worker video-service

# 1. Replay transcode.completed to video-service.
key_records media.transcodes.v1 "$clip_id" 12
read -r part offset <<<"$records"
[[ -n ${offset:-} ]] || fail "find the video's transcode.completed on media.transcodes.v1"
ok "transcode.completed of the video is media.transcodes.v1 partition $part offset $offset"
stop_consumer video-service video-service
seek_group video-service media.transcodes.v1 "$part" "$offset"
since=$(utc_now)
start_service video-service
wait_gateway_ready 60
wait_caught_up 120 video-service
sleep "$settle_seconds"
ignored=$(log_count video-service "$since" "transcode event ignored" "$clip_id")
[[ $ignored -ge 1 ]] || fail "video-service logged the replayed transcode.completed as ignored"
ok "video-service consumed the replay (lag 0) and ignored it"
check_unchanged "replayed transcode.completed"

# 2. Replay video.uploaded to media-worker, which transcodes again and publishes a second
# transcode.completed.
key_records video.lifecycle.v1 "$clip_id" 12
read -r part offset <<<"$records"
[[ -n ${offset:-} ]] || fail "find the video's video.uploaded on video.lifecycle.v1"
ok "video.uploaded of the video is video.lifecycle.v1 partition $part offset $offset"
key_records media.transcodes.v1 "$clip_id" 12
completed=$(count_lines "$records")
stop_consumer media-worker media-worker
seek_group media-worker video.lifecycle.v1 "$part" "$offset"
since=$(utc_now)
start_service media-worker
deadline=$((SECONDS + 300))
until key_records media.transcodes.v1 "$clip_id" 12 && [[ $(count_lines "$records") -gt $completed ]]; do
  ((SECONDS < deadline)) || fail "media-worker publishes a new transcode.completed for the video within 300 s"
  sleep 2
done
ok "media-worker transcoded the replayed video.uploaded again: transcode.completed $completed -> $((completed + 1))"
wait_caught_up 120 media-worker video-service
sleep "$settle_seconds"
ignored=$(log_count video-service "$since" "transcode event ignored" "$clip_id")
[[ $ignored -ge 1 ]] || fail "video-service logged the second transcode.completed as ignored"
ok "video-service consumed the second transcode.completed (lag 0) and ignored it"
check_unchanged "replayed video.uploaded"

# Variant playlists (segment names and durations) must be byte for byte the same. The master
# playlist too, except BANDWIDTH and AVERAGE-BANDWIDTH: ffmpeg measures them from the segments it
# wrote, and a multi-threaded libx264 re-encode is not bit-exact, so they drift slightly; they
# must stay within max_bandwidth_drift percent.
max_bandwidth_drift=${max_bandwidth_drift:-5}
hls=$(fetch_hls "$playlist_url" "$work/after")
for f in "$work"/before/*.m3u8; do
  [[ ${f##*/} == master.m3u8 ]] && continue
  if ! cmp -s "$f" "$work/after/${f##*/}"; then
    diff "$f" "$work/after/${f##*/}" | head -n 20 >&2 || true
    fail "variant playlist ${f##*/} identical before and after the second transcode (diff above)"
  fi
done
ok "every variant playlist identical before and after ($hls)"

bandwidths() { grep -o 'BANDWIDTH=[0-9]*' "$1" | cut -d= -f2; }
masked() { sed -E 's/BANDWIDTH=[0-9]+/BANDWIDTH=*/g' "$1"; }
if ! diff <(masked "$work/before/master.m3u8") <(masked "$work/after/master.m3u8") >&2; then
  fail "master.m3u8 identical before and after apart from the measured bandwidths (diff above)"
fi
drift=$(paste <(bandwidths "$work/before/master.m3u8") <(bandwidths "$work/after/master.m3u8") |
  awk '{ d = ($2 - $1) / $1 * 100; if (d < 0) d = -d; if (d > m) m = d } END { printf "%.2f", m }')
awk -v d="$drift" -v m="$max_bandwidth_drift" 'BEGIN { exit !(d <= m) }' ||
  fail "master.m3u8 measured bandwidths within ${max_bandwidth_drift}% before and after (drift ${drift}%)"
if cmp -s "$work/before/master.m3u8" "$work/after/master.m3u8"; then
  ok "master.m3u8 identical before and after"
else
  ok "master.m3u8 identical before and after apart from measured bandwidths (largest drift ${drift}%)"
fi

echo "drill-duplicates: all checks passed"
