#!/usr/bin/env bash
# Test data for the web client's end-to-end tests (web/e2e/*.e2e.ts), run once per `playwright test` by
# e2e/global-setup.ts against the compose stack of `make up`, through the gateway at 127.0.0.1:8080.
#
# - Explore must hold at least 21 READY videos, so the feed has a third page and 20 moves from video to video each
#   reach a video not played yet in the run. Videos of earlier runs count; only the missing ones are uploaded, by
#   fresh authors, at most per_author each: the gateway's upload class allows a burst of 10 per user and at most 3
#   open uploads, so each upload waits for READY before the next one starts, and a 429 waits for its Retry-After.
# - Every run uploads one more video by a fresh author with an HTML title (threat model WEB-1). It is the newest READY
#   video, so the first of explore, and its author has no other video: following them fills the Following feed with
#   exactly that one.
#
# Writes {"xss": {"video_id", "author_id", "title"}, "explore_ready": N} to the file named by the first argument.
#
# LOCAL LAB ONLY: sourcing lib.sh deletes the gateway's register rate limit keys (svp:gw:rl:register:*) in Redis db 10
# on 127.0.0.1:6379 with SCAN + DEL, as `make smoke` does. The web's BFF reaches the gateway from one container
# address, so every browser of every run shares one register bucket (burst 20 per hour). Never point it at a shared
# stack.
set -euo pipefail

out=${1:?usage: seed.sh OUTPUT_FILE}
base=${SVP_E2E_GATEWAY_URL:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/../../deploy/compose/lib.sh"

xss_title='<img src=x onerror=window.__xss=1>'
min_ready=21
per_author=8
ready_timeout=180

wait_gateway_ready 60

# count_explore AUTH_FILE: prints how many READY videos explore holds, reading pages of 50 until the last one or
# min_ready.
count_explore() {
  local cursor="" n=0 status
  while :; do
    status=$(request GET "/feed/explore?page_size=50${cursor:+&cursor=$cursor}" "$1")
    [[ $status == 200 ]] || fail "count explore (status $status, $(problem_summary))"
    n=$((n + $(jq '.items | length' "$work/body")))
    cursor=$(jq -r '.next_cursor | @uri' "$work/body")
    [[ -n $cursor && $n -lt $min_ready ]] || break
  done
  printf '%s' "$n"
}

# post_video NAME AUTH_FILE TITLE: POST /videos for the test clip like create_video of lib.sh, waiting out a 429
# (Retry-After) at most 3 times.
post_video() {
  local name=$1 status wait try
  jq -n --arg t "$3" --argjson s "$clip_size" '{title: $t, size_bytes: $s, content_type: "video/mp4"}' >"$work/$name.json"
  for try in 1 2 3 4; do
    : >"$work/body"
    status=$(curl -sS --max-time "$max_time" -o "$work/body" -D "$work/headers" -w '%{http_code}' -X POST \
      -H "@$2" -H 'Content-Type: application/json' --data-binary "@$work/$name.json" "$base/videos" || true)
    [[ $status == 429 && $try -lt 4 ]] || break
    wait=$(tr -d '\r' <"$work/headers" | awk -F': ' 'tolower($1) == "retry-after" { print $2 }')
    echo "wait  upload rate limited, retry in ${wait:-1} s"
    sleep "${wait:-1}"
  done
  [[ $status == 201 && -n $(field video_id) ]] || fail "create video $name (status $status, $(problem_summary))"
  printf -v "${name}_id" '%s' "$(field video_id)"
  mv "$work/body" "$work/$name.upload"
}

# upload_ready NAME AUTH_FILE TITLE: creates, uploads and completes one test clip, then waits for READY.
upload_ready() {
  local status
  post_video "$1" "$2" "$3"
  status=$(upload_file "$1" "$work/clip.mp4")
  [[ $status == 2?? ]] || fail "upload $1 to the presigned form (status $status, code $(storage_error_code))"
  status=$(complete_upload "$1" "$2")
  [[ $status == 202 ]] || fail "complete upload of $1 (status $status, $(problem_summary))"
  wait_ready "$1" "$2" "$ready_timeout"
}

# A short vertical clip: a few small renditions transcode in seconds.
make_video "$work/clip.mp4" 4 360x640
clip_size=$(file_size "$work/clip.mp4")

new_user reader
ready=$(count_explore "$work/reader.auth")
# The WEB-1 video below is one of the min_ready.
missing=$((min_ready - 1 - ready))
if ((missing > 0)); then
  for ((i = 0; i < missing; i++)); do
    if ((i % per_author == 0)); then
      new_user "filler$((i / per_author))"
    fi
    upload_ready "fill$i" "$work/filler$((i / per_author)).auth" "e2e clip $(openssl rand -hex 4)"
  done
  ok "uploaded $missing videos for explore (had $ready READY)"
else
  ok "explore holds at least $min_ready READY videos"
fi

new_user xss_author
upload_ready xss "$work/xss_author.auth" "$xss_title"
ok "WEB-1 video READY after ${xss_wait} s"

# Explore's first page is cached for a few seconds (feed-service): wait until the new video leads it, as the web's
# first page (default page size) shows it.
deadline=$((SECONDS + 30))
while :; do
  status=$(request GET /feed/explore "$work/reader.auth")
  [[ $status == 200 ]] || fail "read explore (status $status, $(problem_summary))"
  [[ $(jq -r '.items[0].video_id // ""' "$work/body") == "$xss_id" ]] && break
  ((SECONDS < deadline)) || fail "WEB-1 video first in explore within 30 s"
  sleep 1
done
ok "WEB-1 video first in explore"

ready=$(count_explore "$work/reader.auth")
((ready >= min_ready)) || fail "explore holds at least $min_ready READY videos (got $ready)"
jq -n --arg v "$xss_id" --arg a "$xss_author_id" --arg t "$xss_title" --argjson n "$ready" \
  '{xss: {video_id: $v, author_id: $a, title: $t}, explore_ready: $n}' >"$out"
ok "seed written (explore holds at least $ready READY videos)"
