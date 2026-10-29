#!/usr/bin/env bash
# Drill: deliver events twice and check the consumers are idempotent: delivery is at least once, so a replay is
# normal. With a fresh READY video:
#   1. stop video-service, move group video-service on media.transcodes.v1 back to the video's
#      transcode.completed (rpk group seek), start it, wait for lag 0: status, published_at and the
#      outbox rows of the video do not change;
#   2. stop media-worker, move group media-worker on video.lifecycle.v1 back to the video's
#      video.uploaded, start it, wait for the new transcode.completed and lag 0: media-worker found
#      the version's master and transcoded nothing ("transcode output exists"), the new
#      transcode.completed carries the same keys, duration and renditions byte for byte, no object
#      under media/<video_id>/ was added or written again (keys and ETags), every playlist is byte
#      for byte the same, and video-service ignores it as in 1.
# Records are found by key and event branch, never by "end of topic", so the drill runs again on
# a topic full of earlier runs. The objects are listed with a signed request by curl inside the
# object store's container, the root credential coming from that container's environment, never
# printed and never on a command line. Prints one ok/FAIL line per check and exits non-zero on the first
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

# media_objects VIDEO_ID FILE: writes "<key> <etag>" of every object under media/<VIDEO_ID>/ to
# FILE, sorted; fails on any answer of the store but a complete listing. curl reads the root
# credential as a config line on its standard input.
media_objects() {
  local out
  out=$(compose exec -T s3 sh -c \
    'printf "user = \"svp-admin:%s\"\n" "$RUSTFS_SECRET_KEY" |
      exec curl -sS --fail -K - --aws-sigv4 aws:amz:us-east-1:s3 "http://127.0.0.1:9000/media?list-type=2&prefix=media/$1/"' \
    sh "$1" 2>&1) || fail "list media/$1/ with a signed request in the s3 container: $(printf '%s' "$out" | tail -n 1)"
  [[ $out == *"<IsTruncated>false</IsTruncated>"* ]] || fail "listing of media/$1/ is complete in one page"
  printf '%s' "$out" | listing_pairs | LC_ALL=C sort >"$2" ||
    fail "read the keys and ETags of media/$1/ from the listing; response starts: $(printf '%s' "$out" | head -c 300 | tr '\n' ' ')"
  [[ -s $2 ]] || fail "media/$1/ holds objects"
}

# listing_pairs: reads a ListObjectsV2 response on stdin, prints "<key> <etag>" for every <Contents>
# block. The order of the elements inside a block differs between stores (RustFS writes the ETag
# before the Key), so each block is read on its own: it must hold exactly one non-empty Key and
# one ETag, whatever their order and whatever else it holds. The ETag keeps its escaped quotes.
listing_pairs() {
  { grep -oE '</?Contents>|<(Key|ETag)>[^<]*</(Key|ETag)>' || true; } |
    awk '
      /^<Contents>$/   { if (open) bad = 1; open = 1; key = etag = ""; keys = etags = 0; next }
      /^<\/Contents>$/ { if (!open || keys != 1 || etags != 1 || key == "" || etag == "") bad = 1; else print key " " etag; open = 0; next }
      /^<Key>/         { if (!open) bad = 1; keys++; key = $0; gsub(/<[^>]*>/, "", key); next }
      /^<ETag>/        { if (!open) bad = 1; etags++; etag = $0; gsub(/<[^>]*>/, "", etag); next }
      END              { if (bad || open) exit 1 }'
}

# completed_body PARTITION OFFSET: the hex of the transcode.completed at that place of the last
# key_records read, without the envelope (field 1): two results are the same when these are.
completed_body() {
  local hex n
  hex=$(awk -v p="$1" -v o="$2" '$1 == p && $2 == o { print $4; exit }' "$work/consume")
  [[ ${hex:0:2} == 0a ]] || fail "record $1/$2 of media.transcodes.v1 starts with its envelope"
  n=$((16#${hex:2:2}))
  printf '%s' "${hex:$(((2 + n) * 2))}"
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

# 2. Replay video.uploaded to media-worker, which finds the master of the version, transcodes
# nothing and publishes a second transcode.completed from the stored playlists.
media_objects "$clip_id" "$work/objects-before"
ok "media/$clip_id/ holds $(count_lines "$(<"$work/objects-before")") objects before the replay"
key_records video.lifecycle.v1 "$clip_id" 12
read -r part offset <<<"$records"
[[ -n ${offset:-} ]] || fail "find the video's video.uploaded on video.lifecycle.v1"
ok "video.uploaded of the video is video.lifecycle.v1 partition $part offset $offset"
key_records media.transcodes.v1 "$clip_id" 12
completed=$(count_lines "$records")
read -r first_part first_offset <<<"$records"
first_body=$(completed_body "$first_part" "$first_offset")
stop_consumer media-worker media-worker
seek_group media-worker video.lifecycle.v1 "$part" "$offset"
since=$(utc_now)
start_service media-worker
deadline=$((SECONDS + 300))
until key_records media.transcodes.v1 "$clip_id" 12 && [[ $(count_lines "$records") -gt $completed ]]; do
  ((SECONDS < deadline)) || fail "media-worker publishes a new transcode.completed for the video within 300 s"
  sleep 2
done
ok "media-worker answered the replayed video.uploaded: transcode.completed $completed -> $((completed + 1))"
read -r last_part last_offset <<<"$(printf '%s' "$records" | tail -n 1)"
[[ $(completed_body "$last_part" "$last_offset") == "$first_body" ]] ||
  fail "the second transcode.completed has the keys, duration and renditions of the first, byte for byte"
ok "the second transcode.completed carries the first one's keys, duration and renditions"
[[ $(log_count media-worker "$since" "transcode output exists" "$clip_id") -ge 1 ]] ||
  fail "media-worker logged \"transcode output exists\" for the video (it transcoded again)"
ok "media-worker found the version's master and transcoded nothing"
wait_caught_up 120 media-worker video-service
sleep "$settle_seconds"
ignored=$(log_count video-service "$since" "transcode event ignored" "$clip_id")
[[ $ignored -ge 1 ]] || fail "video-service logged the second transcode.completed as ignored"
ok "video-service consumed the second transcode.completed (lag 0) and ignored it"
check_unchanged "replayed video.uploaded"

# Nothing was written: the same objects with the same ETags, and every playlist byte for byte
# the same.
media_objects "$clip_id" "$work/objects-after"
if ! diff "$work/objects-before" "$work/objects-after" >&2; then
  fail "keys and ETags under media/$clip_id/ the same before and after the replay (diff above)"
fi
ok "no object under media/$clip_id/ added or written again ($(count_lines "$(<"$work/objects-after")") objects, same ETags)"
hls=$(fetch_hls "$playlist_url" "$work/after")
for f in "$work"/before/*.m3u8; do
  if ! cmp -s "$f" "$work/after/${f##*/}"; then
    diff "$f" "$work/after/${f##*/}" | head -n 20 >&2 || true
    fail "playlist ${f##*/} identical before and after the replay (diff above)"
  fi
done
ok "master.m3u8 and every variant playlist identical before and after ($hls)"

echo "drill-duplicates: all checks passed"
