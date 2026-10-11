# shellcheck shell=bash
# Helpers shared by the failure drills (kill-worker.sh, duplicate-events.sh, measure-ready.sh,
# duplicate-feed-events.sh, engagement-down.sh, measure-freshness.sh, rate-limit.sh,
# measure-explore-cache.sh, upload-cleanup.sh): docker compose through the command `make` passes in
# $COMPOSE, recreating a service with drill-only settings, rpk inside the Redpanda container, record
# lookups by key, consumer group lag and seeks, read-only outbox queries on svp_video, HLS
# downloads, timed requests, and putting the stack back on exit.
# Written for bash 3.2 (the macOS /bin/bash).
#
# Source it after setting `base` (the gateway URL); it sources ../lib.sh, whose rules it keeps.
# The database is read with SELECT only, as the local superuser on 127.0.0.1:5432.

# shellcheck source=deploy/compose/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[[ -n ${COMPOSE:-} ]] || fail "COMPOSE is not set; run the drills through make"
read -r -a compose_cmd <<<"$COMPOSE"

# Every service a drill may stop or kill; on exit they are all started again.
stack_services=(redpanda minio user-service video-service engagement-service feed-service gateway media-worker)
# Seconds to wait after the consumer groups caught up, so the relay (200 ms poll) and a late
# redelivery would have shown up.
settle_seconds=${settle_seconds:-5}
sampler_pid=

compose() { "${compose_cmd[@]}" "$@"; }
rpk() { compose exec -T redpanda rpk "$@"; }

# drill_exit: the EXIT trap. Stops the stats sampler, starts every stack service that is not
# running and recreates every one whose settings differ from compose.yaml (a service a drill
# recreated with drill-only settings goes back to the defaults, since those variables are never
# exported), removes $work, and keeps the script's exit status (1 when the stack cannot be
# restored).
drill_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n $sampler_pid ]]; then kill "$sampler_pid" 2>/dev/null || true; fi
  if compose up -d --no-deps --wait "${stack_services[@]}" >"$work/restore.log" 2>&1; then
    echo "ok    stack running again (${stack_services[*]})"
  else
    echo "FAIL  restore the stack: compose up --wait failed (see make ps / make logs)" >&2
    rc=1
  fi
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# check_uuid VALUE: fails unless VALUE is a UUID (it goes into SQL and grep patterns).
check_uuid() {
  [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "video id is a UUID (got '$1')"
}

# upload_video NAME AUTH_FILE FILE: creates video NAME for FILE, uploads it through the presigned
# form and completes it (202 PROCESSING); sets <NAME>_id like create_video.
upload_video() {
  local name=$1 size status id_var="${1}_id"
  size=$(file_size "$3")
  create_video "$name" "$2" "drill $name $(openssl rand -hex 4)" "$size" video/mp4
  check_uuid "${!id_var}"
  status=$(upload_file "$name" "$3")
  [[ $status == 2?? ]] || fail "upload video $name to the presigned form (status $status, code $(storage_error_code))"
  status=$(complete_upload "$name" "$2")
  [[ $status == 202 && $(field status) == PROCESSING ]] ||
    fail "complete video $name is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
}

# video_status NAME AUTH_FILE: GET /videos/{id}; sets <NAME>_status and <NAME>_published.
video_status() {
  local id_var="${1}_id" status
  status=$(request GET "/videos/${!id_var}" "$2")
  [[ $status == 200 ]] || fail "read video $1 (status $status, $(problem_summary))"
  printf -v "${1}_status" '%s' "$(field status)"
  printf -v "${1}_published" '%s' "$(field published_at)"
}

# event_tag HEX: the protobuf tag byte (hex) of the oneof branch of an event envelope whose field
# 1 is the EventMeta: "12" for field 2 (video_uploaded, transcode_completed), "1a" for field 3
# (video_ready, transcode_failed); "" when the value does not start that way.
event_tag() {
  local hex=$1 n
  [[ ${hex:0:2} == 0a ]] || return 0
  n=$((16#${hex:2:2}))
  ((n < 128)) || return 0 # a two-byte length never happens for EventMeta; refuse to guess
  printf '%s' "${hex:$(((2 + n) * 2)):2}"
}

# key_records TOPIC KEY TAG: sets `records` to the "PARTITION OFFSET" lines of every record in
# TOPIC with KEY whose event branch is TAG, oldest first per partition ("" when none). Reads the
# whole topic, so it finds a record by its key wherever earlier runs left others. It sets a
# variable instead of printing because `fail` inside $(...) would only end the subshell: an rpk
# error would read as "no records". Call it as a plain command, never in $(...).
key_records() {
  local p o k v
  records=
  rpk topic consume "$1" -o :end -f '%p %o %k %v{hex}\n' >"$work/consume" ||
    fail "read topic $1 with rpk topic consume"
  while read -r p o k v; do
    if [[ $k == "$2" && $(event_tag "$v") == "$3" ]]; then records+="$p $o"$'\n'; fi
  done <"$work/consume"
  return 0
}

# count_lines TEXT: the number of non-empty lines of TEXT.
count_lines() { printf '%s' "$1" | grep -c . || true; }

# group_field GROUP NAME: a summary field of rpk group describe (STATE, TOTAL-LAG, MEMBERS); ""
# when describe fails, which happens for a moment while the group rebalances, so callers poll.
group_field() { rpk group describe "$1" 2>/dev/null | awk -v f="$2" '$1 == f { print $2; exit }' || true; }

# group_offset GROUP TOPIC PARTITION: the group's committed offset on that partition.
group_offset() {
  rpk group describe "$1" 2>/dev/null | awk -v t="$2" -v p="$3" '$1 == t && $2 == p { print $3; exit }' || true
}

# wait_group GROUP FIELD VALUE TIMEOUT: polls until FIELD of GROUP is VALUE.
wait_group() {
  local deadline=$((SECONDS + $4)) got
  while :; do
    got=$(group_field "$1" "$2")
    [[ $got == "$3" ]] && return 0
    ((SECONDS < deadline)) || fail "group $1 $2 is $3 within $4 s (still '$got')"
    sleep 1
  done
}

# wait_caught_up TIMEOUT GROUP...: waits until every GROUP has a member and no lag.
wait_caught_up() {
  local t=$1 g
  shift
  for g in "$@"; do
    wait_group "$g" STATE Stable "$t"
    wait_group "$g" TOTAL-LAG 0 "$t"
  done
}

# stop_consumer SERVICE GROUP: stops SERVICE and waits until its group has no member, since a
# group with an active member refuses an offset change.
stop_consumer() {
  compose stop "$1" >/dev/null 2>&1 || fail "stop $1"
  wait_group "$2" STATE Empty 90
  ok "stopped $1; group $2 is Empty"
}

# start_service SERVICE: starts SERVICE again and waits until it is running (healthy when it has
# a healthcheck).
start_service() {
  compose up -d --no-deps --wait "$1" >/dev/null 2>&1 || fail "start $1 again"
}

# seek_group GROUP TOPIC PARTITION OFFSET: moves GROUP's committed offset on that one partition to
# OFFSET (the other partitions keep theirs) and checks it took.
seek_group() {
  printf '%s %s %s\n' "$2" "$3" "$4" | rpk group seek "$1" --to-file /dev/stdin --topics "$2" >"$work/seek" 2>&1 ||
    fail "rpk group seek $1 $2/$3 to $4: $(tail -n 1 "$work/seek")"
  [[ $(group_offset "$1" "$2" "$3") == "$4" ]] || fail "group $1 committed offset on $2/$3 is $4 after the seek"
  ok "seeked group $1 on $2 partition $3 back to offset $4"
}

# outbox_counts VIDEO_ID: prints "TOTAL UPLOADED READY", the outbox rows of the video in svp_video
# and how many carry video.uploaded (oneof field 2) and video.ready (field 3). SELECT only.
outbox_counts() {
  psql -h 127.0.0.1 -p 5432 -U postgres -d svp_video -w -X -q -At -F ' ' -v ON_ERROR_STOP=1 -v id="$1" <<'SQL' ||
SELECT count(*),
       count(*) FILTER (WHERE tag = 18),
       count(*) FILTER (WHERE tag = 26)
FROM (SELECT CASE WHEN get_byte(payload, 0) = 10 AND get_byte(payload, 1) < 128
                  THEN get_byte(payload, 2 + get_byte(payload, 1)) END AS tag
      FROM outbox
      WHERE record_key = :'id') AS rows;
SQL
    fail "read the outbox of video $1 from svp_video"
}

# fetch_hls PLAYLIST_URL DIR: downloads the master playlist, every variant playlist and every
# segment they list into DIR (master.m3u8, <n>.m3u8); fails on any non-200 or empty segment.
# Prints "<variants> variants, <segments> segments".
fetch_hls() {
  local master=$1 dir=$2 variant_url seg status vi=0 segs=0
  mkdir -p "$dir"
  status=$(fetch "$master" "$dir/master.m3u8")
  [[ $status == 200 ]] && grep -q '^#EXT-X-STREAM-INF' "$dir/master.m3u8" ||
    fail "GET master.m3u8 is 200 with #EXT-X-STREAM-INF (status $status)"
  while read -r variant; do
    vi=$((vi + 1))
    variant_url=$(resolve "$master" "$variant")
    status=$(fetch "$variant_url" "$dir/$vi.m3u8")
    [[ $status == 200 ]] && grep -q '^#EXT-X-ENDLIST' "$dir/$vi.m3u8" ||
      fail "GET variant playlist $variant is 200 and complete (status $status)"
    while read -r seg; do
      status=$(fetch "$(resolve "$variant_url" "$seg")" "$work/segment")
      [[ $status == 200 && -s $work/segment ]] || fail "GET segment $variant -> $seg is 200 and not empty (status $status)"
      segs=$((segs + 1))
    done < <(grep -v -e '^#' -e '^[[:space:]]*$' "$dir/$vi.m3u8" | tr -d '\r')
  done < <(grep -v -e '^#' -e '^[[:space:]]*$' "$dir/master.m3u8" | tr -d '\r')
  ((vi > 0 && segs > 0)) || fail "master playlist lists variants with segments"
  echo "$vi variants, $segs segments"
}

# log_count SERVICE SINCE MSG VIDEO_ID: how many JSON log lines of SERVICE since SINCE (RFC 3339)
# have message MSG for VIDEO_ID.
log_count() {
  compose logs --no-log-prefix --since "$2" "$1" 2>/dev/null |
    grep -F "\"msg\":\"$3\"" | grep -cF "\"video_id\":\"$4\"" || true
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# recreate_service SERVICE [VAR=VALUE...]: recreates SERVICE alone with the compose variables given
# (none: the defaults of compose.yaml) and waits until it is healthy. The variables reach this one
# compose call only.
recreate_service() {
  local service=$1
  shift
  env "$@" "${compose_cmd[@]}" up -d --no-deps --wait "$service" >"$work/recreate.log" 2>&1 ||
    fail "recreate $service${1:+ with $*}: $(tail -n 1 "$work/recreate.log") (see make logs SVC=$service)"
}

# timed_request METHOD PATH AUTH_FILE: like `request`, but prints "STATUS SECONDS" (curl's
# %{time_total}); leaves the body in $work/body.
timed_request() {
  : >"$work/body"
  curl -sS --max-time "$max_time" -o "$work/body" -w '%{http_code} %{time_total}' -X "$1" -H "@$3" "$base$2" || true
}
