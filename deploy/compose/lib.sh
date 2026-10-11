# shellcheck shell=bash
# Helpers shared by the scripts that drive the core stack through the gateway (smoke.sh, later
# drills): API requests, test users, generated test videos, the presigned upload, completion,
# waiting for READY, anonymous HLS downloads and looking a video up in a feed. Written for bash 3.2
# (the macOS /bin/bash).
#
# Source it after setting `base` (the gateway URL). It creates the private work directory $work,
# removed on exit. Rules every helper keeps: passwords, tokens and presigned form fields are never
# printed and never on a command line (jq and curl read them from the environment or from files
# in $work); every work file is private (umask 077); every request has a --max-time.
#
# LOCAL LAB ONLY: sourcing it deletes the gateway's per-IP register rate limit keys in Redis
# (reset_register_limit below), so that smoke and drill runs within one hour do not use up the
# register burst. Never point these scripts at a shared or production stack.

# Seconds an API request may take: a server that accepts the connection and never answers must
# not hang the script.
max_time=${max_time:-5}
# Seconds an upload to or a download from the object storage may take.
transfer_max_time=${transfer_max_time:-60}

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}

# reset_register_limit: LOCAL LAB ONLY. Every request of these scripts reaches the gateway from the
# one Docker bridge address, and every script registers fresh users, so runs within an hour would
# use up the per-IP register burst of 20 (ADR-0010, sections 2 and 7). Deletes the register
# buckets (svp:gw:rl:register:*) in the gateway's Redis db 10 on 127.0.0.1:6379 with SCAN + DEL,
# and no other key; the limit itself is not raised.
reset_register_limit() {
  local key n=0
  command -v redis-cli >/dev/null || fail "redis-cli not found (brew install redis)"
  redis-cli -h 127.0.0.1 -p 6379 -n 10 --scan --pattern 'svp:gw:rl:register:*' >"$work/register-keys" ||
    fail "scan the register rate limit keys in Redis db 10"
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    redis-cli -h 127.0.0.1 -p 6379 -n 10 DEL "$key" >/dev/null || fail "delete a register rate limit key in Redis db 10"
    n=$((n + 1))
  done <"$work/register-keys"
  ok "register rate limit reset for this lab run ($n keys deleted in Redis db 10)"
}
reset_register_limit

# request METHOD PATH [AUTH_FILE] [BODY_FILE]: sends the request to the gateway, leaves the body
# in $work/body and the content type in $work/type, and prints the HTTP status.
request() {
  local args=(-sS --max-time "$max_time" -o "$work/body" -w '%{http_code} %{content_type}' -X "$1" "$base$2")
  if [[ -n ${3:-} ]]; then args+=(-H "@$3"); fi
  if [[ -n ${4:-} ]]; then args+=(-H 'Content-Type: application/json' --data-binary "@$4"); fi
  local out
  : >"$work/body"
  # On a connection error curl still prints status 000; report that instead of exiting here.
  out=$(curl "${args[@]}" || true)
  printf '%s' "${out#* }" >"$work/type"
  printf '%s' "${out%% *}"
}

# field NAME: prints a top-level string field of the last response body ("" when absent).
field() { jq -r --arg k "$1" '.[$k] // "" | tostring' "$work/body" 2>/dev/null || true; }

# problem_summary: the code of the last problem response, never the raw body.
problem_summary() { echo "code=$(field code)"; }

# wait_gateway_ready SECONDS: waits until the gateway and the services behind it are ready, plus
# at most one request's max_time when the deadline passes during a request.
wait_gateway_ready() {
  local deadline=$((SECONDS + $1))
  until [[ $(curl -s --max-time "$max_time" -o /dev/null -w '%{http_code}' "$base/readyz" || true) == 200 ]]; do
    ((SECONDS < deadline)) || fail "readyz within $1s"
    sleep 1
  done
  ok "readyz"
}

# new_user NAME: registers and logs in a fresh random user; sets <NAME>_id and writes the
# Authorization header to $work/<NAME>.auth.
new_user() {
  local name=$1 email status token
  email="smoke-$(date +%s)-$(openssl rand -hex 4)@example.test"
  SMOKE_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" '{email: $e, password: env.SMOKE_PASSWORD}' >"$work/$name.cred"

  status=$(request POST /auth/register "" "$work/$name.cred")
  [[ $status == 201 && -n $(field user_id) ]] || fail "register user $name (status $status, $(problem_summary))"
  printf -v "${name}_id" '%s' "$(field user_id)"
  ok "register user $name"

  status=$(request POST /auth/login "" "$work/$name.cred")
  token=$(field access_token)
  : >"$work/body" # the body holds the token: drop it now
  [[ $status == 200 && -n $token ]] || fail "login user $name (status $status)"
  printf 'Authorization: Bearer %s\n' "$token" >"$work/$name.auth"
  ok "login user $name"
}

# make_video FILE SECONDS WIDTHxHEIGHT: writes an H.264/AAC MP4 test video (moving test pattern
# and a sine tone) of that length and size.
make_video() {
  command -v ffmpeg >/dev/null || fail "ffmpeg not found (brew install ffmpeg)"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=$3:rate=30:duration=$2" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$2" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 96k \
    -shortest -movflags +faststart "$1" || fail "generate a $2 s $3 test video"
}

# file_size FILE: prints the size of FILE in bytes.
file_size() { wc -c <"$1" | tr -d ' '; }

# create_video NAME AUTH_FILE TITLE SIZE_BYTES CONTENT_TYPE: POST /videos; sets <NAME>_id and keeps
# the response, which holds the presigned form, in $work/<NAME>.upload for upload_file.
create_video() {
  local name=$1 status
  jq -n --arg t "$3" --argjson s "$4" --arg c "$5" '{title: $t, size_bytes: $s, content_type: $c}' >"$work/$name.json"
  status=$(request POST /videos "$2" "$work/$name.json")
  [[ $status == 201 && -n $(field video_id) && -n $(field upload_url) ]] ||
    fail "create video $name (status $status, $(problem_summary))"
  printf -v "${name}_id" '%s' "$(field video_id)"
  mv "$work/body" "$work/$name.upload"
}

# upload_url NAME / upload_key NAME: the storage URL and object key of video NAME's presigned
# form. Neither is a credential; the policy and signature fields are.
upload_url() { jq -r '.upload_url' "$work/$1.upload"; }
upload_key() { jq -r '.form_fields.key' "$work/$1.upload"; }

# upload_file NAME FILE: POSTs FILE to video NAME's presigned form as multipart/form-data, every
# form field first and the file last, as the storage requires. The URL and fields go to curl in a
# config file, not on its command line. Leaves the storage's answer in $work/body and prints the
# HTTP status.
upload_file() {
  local cfg="$work/$1.curl"
  # --form-string sends a value as is; --form would read a value starting with @ or < as a file.
  # @json quoting is valid curl config quoting for these values (no control characters).
  jq -r --arg f "$2" '
    "url = \(.upload_url | @json)",
    (.form_fields | to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"),
    "form = \("file=@\($f)" | @json)"
  ' "$work/$1.upload" >"$cfg"
  : >"$work/body"
  curl -sS --max-time "$transfer_max_time" -o "$work/body" -w '%{http_code}' -K "$cfg" || true
}

# storage_error_code: the <Code> of the last S3 error response (XML), never the whole body.
storage_error_code() { sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p' "$work/body" | head -n 1; }

# complete_upload NAME AUTH_FILE: POST /videos/{id}/complete for video NAME; prints the HTTP status
# and leaves the video in $work/body.
complete_upload() {
  local id_var="${1}_id"
  request POST "/videos/${!id_var}/complete" "$2"
}

# wait_ready NAME AUTH_FILE TIMEOUT: polls GET /videos/{id} once a second until video NAME is
# READY, failing on FAILED or after TIMEOUT seconds; sets <NAME>_wait to the seconds waited and
# leaves the READY video in $work/body.
wait_ready() {
  local id_var="${1}_id" start=$SECONDS status state
  while :; do
    status=$(request GET "/videos/${!id_var}" "$2")
    [[ $status == 200 ]] || fail "read video $1 while waiting for READY (status $status, $(problem_summary))"
    state=$(field status)
    [[ $state == READY ]] && break
    [[ $state == FAILED ]] && fail "video $1 went FAILED instead of READY"
    ((SECONDS - start < $3)) || fail "video $1 READY within $3 s (still $state)"
    sleep 1
  done
  printf -v "${1}_wait" '%s' $((SECONDS - start))
}

# fetch URL FILE: anonymous GET of URL into FILE; prints the HTTP status.
fetch() {
  : >"$2"
  curl -sS --max-time "$transfer_max_time" -o "$2" -w '%{http_code}' "$1" || true
}

# first_uri PLAYLIST_FILE: the first URI line of an HLS playlist (a variant playlist in a master
# playlist, a segment in a variant playlist); "" with status 0 when there is none, so under
# `set -o pipefail` the caller's check reports the empty playlist instead of the script exiting
# silently on grep's status.
first_uri() { { grep -v -e '^#' -e '^[[:space:]]*$' "$1" || true; } | head -n 1 | tr -d '\r'; }

# resolve BASE_URL REF: REF resolved against the playlist at BASE_URL (absolute REF kept as is).
resolve() {
  case $2 in
    http://* | https://*) printf '%s' "$2" ;;
    *) printf '%s/%s' "${1%/*}" "$2" ;;
  esac
}

# Pages of feed_page_size items a feed lookup reads before it calls a video absent: explore holds
# every READY video, older smoke runs included, so the video looked for may not be on the first page.
feed_pages=${feed_pages:-5}
feed_page_size=${feed_page_size:-50}

# feed_item FEED AUTH_FILE VIDEO_ID: looks for VIDEO_ID in GET /feed/FEED (following or explore),
# following next_cursor for at most feed_pages pages; writes the item, or null when it is not
# there, to $work/item and prints the HTTP status of the last page read.
feed_item() {
  local cursor="" page status
  echo null >"$work/item"
  for ((page = 0; page < feed_pages; page++)); do
    status=$(request GET "/feed/$1?page_size=$feed_page_size${cursor:+&cursor=$cursor}" "$2")
    if [[ $status != 200 ]]; then
      printf '%s' "$status"
      return
    fi
    jq --arg id "$3" 'first(.items[] | select(.video_id == $id)) // null' "$work/body" >"$work/item"
    cursor=$(jq -r '.next_cursor | @uri' "$work/body")
    [[ $(<"$work/item") == null && -n $cursor ]] || break
  done
  printf '%s' "$status"
}

# item_summary: whether the last feed item was found and its stats, for a FAIL line.
item_summary() { jq -c 'if . == null then "video absent" else {stats} end' "$work/item"; }

# wait_feed_item FEED AUTH_FILE VIDEO_ID TIMEOUT FILTER STEP: polls feed_item once a second until
# the jq FILTER, run on the item (null when the video is absent), is true; fails naming STEP on a
# non-200 page or after TIMEOUT seconds, with the last state of the item. Leaves the item in
# $work/item.
wait_feed_item() {
  local start=$SECONDS status
  while :; do
    status=$(feed_item "$1" "$2" "$3")
    [[ $status == 200 ]] || fail "$6: GET /feed/$1 (status $status, $(problem_summary))"
    [[ $(jq -r "$5" "$work/item") == true ]] && return
    ((SECONDS - start < $4)) || fail "$6 within $4 s (last: $(item_summary))"
    sleep 1
  done
}
