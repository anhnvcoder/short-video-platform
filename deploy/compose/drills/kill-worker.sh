#!/usr/bin/env bash
# Drill: kill media-worker in the middle of a transcode and check the video is not lost
# (ADR-0008 section 8: manual commit after the handler, so the uncommitted video.uploaded is
# delivered again). Uploads a 60 s 1080p video, completes it, waits until ffmpeg runs for it in
# the worker, SIGKILLs the container, starts it again and waits for READY. Checks: the video is
# READY and every playlist and segment downloads; the outbox of svp_video holds exactly two rows
# for it (video.uploaded, video.ready); one transcode.completed was published; status and
# published_at do not change after one more cycle. Prints one ok/FAIL line per check and exits
# non-zero on the first failure; on exit every stack service runs again.
#
# Usage (from the repo root, stack up): make drill-kill-worker
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# Seconds ffmpeg runs before the kill, so the job has partial output in /work.
kill_after=${kill_after:-3}

wait_gateway_ready 60
new_user a
make_video "$work/clip.mp4" 60 1920x1080
ok "generated a 60 s 1080p test video ($(file_size "$work/clip.mp4") bytes)"

upload_video clip "$work/a.auth" "$work/clip.mp4"
ok "uploaded and completed video $clip_id: 202 PROCESSING"

# Wait for the worker's ffmpeg on this video (ffprobe runs first and does not count). Finishing
# first means the drill killed nothing: that is a failure, not a pass.
ffmpeg_running() { compose top media-worker 2>/dev/null | grep -F "/work/$clip_id/" | grep -Eq '(^|[ /])ffmpeg( |$)'; }
deadline=$((SECONDS + 120))
while ! ffmpeg_running; do
  video_status clip "$work/a.auth"
  [[ $clip_status == PROCESSING ]] ||
    fail "worker finished the transcode (status $clip_status) before the drill saw ffmpeg; nothing was killed"
  ((SECONDS < deadline)) || fail "ffmpeg for video $clip_id running in media-worker within 120 s"
  sleep 0.2
done
ok "media-worker is running ffmpeg for the video"

sleep "$kill_after"
ffmpeg_running ||
  fail "ffmpeg still running ${kill_after} s later (the transcode ended before the kill)"
compose kill media-worker >/dev/null 2>&1 || fail "kill media-worker"
killed_at=$(utc_now)
ok "killed media-worker (SIGKILL) after ffmpeg ran ${kill_after} s"

key_records media.transcodes.v1 "$clip_id" 12
[[ -z $records ]] ||
  fail "no transcode.completed published before the kill (the job had already finished)"
video_status clip "$work/a.auth"
[[ $clip_status == PROCESSING ]] || fail "video still PROCESSING after the kill (got $clip_status)"
ok "nothing published before the kill; video still PROCESSING"

start_service media-worker
ok "media-worker started again"

# A killed member never leaves its group: the redelivery waits for its session to expire.
wait_ready clip "$work/a.auth" 600
playlist_url=$(field playlist_url)
[[ -n $playlist_url ]] || fail "READY video has a playlist_url"
ok "video READY ${clip_wait} s after the restart"

hls=$(fetch_hls "$playlist_url" "$work/hls")
ok "every playlist and segment downloads ($hls)"

[[ $(log_count media-worker "$killed_at" "transcode job finished" "$clip_id") == 1 ]] ||
  fail "the restarted media-worker logged one finished job for the video"
key_records media.transcodes.v1 "$clip_id" 12
completed=$(count_lines "$records")
[[ $completed == 1 ]] || fail "one transcode.completed for the video (got $completed)"
ok "the restarted worker redid the job: one transcode.completed"

read -r total uploaded ready <<<"$(outbox_counts "$clip_id")"
[[ $total == 2 && $uploaded == 1 && $ready == 1 ]] ||
  fail "outbox holds 2 rows for the video, one video.uploaded and one video.ready (got total=$total uploaded=$uploaded ready=$ready)"
ok "outbox: 2 rows (video.uploaded, video.ready)"

video_status clip "$work/a.auth"
published=$clip_published
[[ -n $published ]] || fail "READY video has published_at"
wait_caught_up 120 media-worker video-service
sleep "$settle_seconds"
video_status clip "$work/a.auth"
read -r total2 uploaded2 ready2 <<<"$(outbox_counts "$clip_id")"
[[ $clip_status == READY && $clip_published == "$published" ]] ||
  fail "status and published_at unchanged one cycle later (got $clip_status, $clip_published; was $published)"
[[ "$total2 $uploaded2 $ready2" == "$total $uploaded $ready" ]] ||
  fail "outbox unchanged one cycle later (got $total2 $uploaded2 $ready2)"
ok "one cycle later (groups caught up + ${settle_seconds} s): READY, published_at $published, outbox unchanged"

echo "drill-kill-worker: all checks passed"
