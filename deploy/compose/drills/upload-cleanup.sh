#!/usr/bin/env bash
# Drill: the job that cleans up abandoned uploads in video-service.
# video-service is recreated alone with drill-only settings, an upload abandoned after
# abandon_after and a sweep every sweep_interval (defaults 1h and 5m), then with a fresh user A:
#   1. A creates video "abandoned" and uploads its file but never completes it; the object is in
#      the uploads bucket;
#   2. A creates, uploads and completes video "done" at the same time (PROCESSING);
#   3. within failed_timeout seconds of its creation, GET /videos/{id} shows "abandoned" FAILED,
#      its object is gone from the uploads bucket and video-service logged "upload abandoned" for
#      it; "done" is not touched and goes READY;
#   4. video-service is recreated with its default settings.
# The object is looked up with a signed HEAD request by curl inside the object store's container,
# the root credential coming from that container's environment, never printed and never on a
# command line. Every other video left
# UPLOADING for longer than abandon_after (earlier smoke and drill runs) is cleaned up too. Prints
# one ok/FAIL line per check and exits non-zero on the first failure; on exit (passed or not)
# every stack service runs again with its default settings. Reads no database.
#
# Usage (from the repo root, stack up): make drill-upload-cleanup
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# Drill-only settings: below the 15 minutes of an upload form, so never outside a drill (a form
# still valid could write the object again after the cleanup).
abandon_after=20s
sweep_interval=5s
failed_timeout=60

# upload_object NAME: prints "exists" or "missing" for the object of video NAME's upload form in
# the uploads bucket; fails on any other answer of the store. curl reads the root credential as a
# config line on its standard input.
upload_object() {
  local path out
  path="$(basename "$(upload_url "$1")")/$(upload_key "$1")"
  out=$(compose exec -T s3 sh -c \
    'printf "user = \"svp-admin:%s\"\n" "$RUSTFS_SECRET_KEY" |
      exec curl -sS -K - --aws-sigv4 aws:amz:us-east-1:s3 --head -o /dev/null -w "%{http_code}" "http://127.0.0.1:9000/$1"' \
    sh "$path" 2>&1) || true
  case $out in
    200) echo exists ;;
    404) echo missing ;;
    *) fail "look up $path with a HEAD request in the s3 container: $(printf '%s' "$out" | tail -n 1)" ;;
  esac
}

# 0. video-service with the short settings.
recreate_service video-service SVP_UPLOAD_ABANDON_AFTER="$abandon_after" SVP_UPLOAD_SWEEP_INTERVAL="$sweep_interval"
since=$(utc_now)
wait_gateway_ready 60
ok "video-service recreated with UPLOAD_ABANDON_AFTER=$abandon_after UPLOAD_SWEEP_INTERVAL=$sweep_interval"

new_user a
make_video "$work/clip.mp4" 5 1280x720

# 1. An upload that is never completed.
create_video abandoned "$work/a.auth" "drill abandoned $(openssl rand -hex 4)" "$(file_size "$work/clip.mp4")" video/mp4
created=$SECONDS
check_uuid "$abandoned_id"
status=$(upload_file abandoned "$work/clip.mp4")
[[ $status == 2?? ]] || fail "upload video abandoned to the presigned form (status $status, code $(storage_error_code))"
state=$(upload_object abandoned)
[[ $state == exists ]] || fail "the uploaded object of video abandoned is in the uploads bucket (got $state)"
ok "video $abandoned_id uploaded, not completed; its object is in the uploads bucket"

# 2. An upload completed at the same time.
upload_video done "$work/a.auth" "$work/clip.mp4"
ok "video $done_id uploaded and completed: PROCESSING"

# 3. The sweep marks the abandoned upload FAILED and deletes its object.
while :; do
  video_status abandoned "$work/a.auth"
  [[ $abandoned_status == FAILED ]] && break
  [[ $abandoned_status == UPLOADING ]] || fail "video abandoned stays UPLOADING until it goes FAILED (got $abandoned_status)"
  ((SECONDS - created < failed_timeout)) || fail "video abandoned FAILED within $failed_timeout s of its creation"
  sleep 1
done
ok "video abandoned FAILED $((SECONDS - created)) s after its creation (abandoned after $abandon_after, sweep every $sweep_interval)"
state=$(upload_object abandoned)
[[ $state == missing ]] || fail "the object of video abandoned is gone from the uploads bucket (got $state)"
ok "the object of video abandoned is gone from the uploads bucket"
n=$(log_count video-service "$since" "upload abandoned" "$abandoned_id")
[[ $n == 1 ]] || fail "video-service logged 'upload abandoned' once for video abandoned (got $n)"
ok "video-service logged 'upload abandoned' for video abandoned"

video_status done "$work/a.auth"
[[ $done_status == PROCESSING || $done_status == READY ]] ||
  fail "video done is untouched by the sweep: PROCESSING or READY (got $done_status)"
wait_ready done "$work/a.auth" 300
ok "video done untouched by the sweep: READY after ${done_wait} s"

# 4. Back to the default settings.
recreate_service video-service
wait_gateway_ready 60
ok "video-service recreated with its default settings"

echo "drill-upload-cleanup: all checks passed"
