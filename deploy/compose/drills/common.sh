# shellcheck shell=bash
# Helpers shared by the failure drills (kill-worker.sh, duplicate-events.sh, measure-ready.sh,
# duplicate-feed-events.sh, engagement-down.sh, measure-freshness.sh, rate-limit.sh,
# measure-explore-cache.sh, upload-cleanup.sh, alert-to-sentry.sh, obs-threats.sh): docker compose
# through the command `make` passes in $COMPOSE, recreating a service with drill-only settings, rpk
# inside the Redpanda container, record lookups by key, consumer group lag and seeks, read-only
# outbox queries on svp_video, HLS downloads, timed requests, read-only queries to the
# observability stack of `make up OBS=lgtm` (Prometheus, Tempo and Loki through Grafana,
# Alertmanager, the GlitchTip API), and putting the stack back on exit.
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
# The background request load of a drill (alert-to-sentry.sh), stopped on exit.
load_pid=

compose() { "${compose_cmd[@]}" "$@"; }
rpk() { compose exec -T redpanda rpk "$@"; }

# restore_stack: starts every stack service that is not running and recreates every one whose
# settings differ from compose.yaml (a service a drill recreated with drill-only settings goes
# back to the defaults, since those variables are never exported); prints ok, or FAIL and
# returns 1.
restore_stack() {
  if compose up -d --no-deps --wait "${stack_services[@]}" >"$work/restore.log" 2>&1; then
    echo "ok    stack running again (${stack_services[*]})"
  else
    echo "FAIL  restore the stack: compose up --wait failed (see make ps / make logs)" >&2
    return 1
  fi
}

# drill_exit: the EXIT trap. Stops the stats sampler and the request load, restores the stack,
# removes $work, and keeps the script's exit status (1 when the stack cannot be restored).
drill_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n $sampler_pid ]]; then kill "$sampler_pid" 2>/dev/null || true; fi
  if [[ -n $load_pid ]]; then kill "$load_pid" 2>/dev/null || true; fi
  restore_stack || rc=1
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

# Observability drills (alert-to-sentry.sh, obs-threats.sh): read-only access to the stack of
# `make up OBS=lgtm` (docs/adr/0011-observability-stage3.md, sections 7 to 9). Prometheus, Tempo and
# Loki are reached through Grafana's datasource proxy, since their own ports are not published;
# Alertmanager and GlitchTip through their loopback ports. The GlitchTip API token (read-only:
# event:read, project:read) is read from .env into a shell variable that is never exported,
# printed, written to a file or put on a command line: the printf builtin writes the header to
# curl's stdin.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
env_file=$repo_root/.env
grafana_url=http://127.0.0.1:3000
proxy_url=$grafana_url/api/datasources/proxy/uid
alertmanager_url=http://127.0.0.1:9093
# Lines a Loki query may return; a query that reaches it fails, since lines would be missing.
loki_limit=5000
sentry_api_url=
sentry_org=
sentry_project=
sentry_token=
sentry_status=
# jq function: an RFC 3339 UTC time ("2026-10-17T05:00:05.200Z", fraction optional) in seconds
# since the epoch, with the fraction.
jq_epoch='def epoch: capture("^(?<s>[^.Z]+)(?<f>[.][0-9]+)?Z$") | ((.s + "Z") | fromdateiso8601) + (("0" + (.f // "")) | tonumber);'

# obs_get URL OUT [CURL_ARGS...]: GET URL into OUT; CURL_ARGS such as --data-urlencode NAME=VALUE
# become the query string. Prints the HTTP status (000 when nothing answered).
obs_get() {
  local url=$1 out=$2
  shift 2
  : >"$out"
  curl -sS -G --max-time "$max_time" -o "$out" -w '%{http_code}' "$@" "$url" || true
}

# prom_query EXPR: an instant PromQL query; the response stays in $work/prom.json and prom_value
# is set to the value of its first sample ("" when the result is empty). Sets a variable instead
# of printing, like key_records, so that a failure ends the script.
prom_query() {
  local status
  status=$(obs_get "$proxy_url/prometheus/api/v1/query" "$work/prom.json" --data-urlencode "query=$1")
  [[ $status == 200 && $(jq -r '.status' "$work/prom.json" 2>/dev/null) == success ]] ||
    fail "Prometheus query through Grafana is 200 (status $status): $1"
  prom_value=$(jq -r '.data.result[0].value[1] // ""' "$work/prom.json")
}

# loki_query LOGQL START END: the log lines of LOGQL between START and END (seconds since the
# epoch), oldest first, into $work/loki.json as an array of objects: the stream's labels and
# structured metadata (service_name, trace_id, user_id, status, ...) plus `line`, the log message.
loki_query() {
  local status n
  status=$(obs_get "$proxy_url/loki/loki/api/v1/query_range" "$work/loki-raw.json" --data-urlencode "query=$1" \
    --data-urlencode "start=${2%.*}000000000" --data-urlencode "end=$((${3%.*} + 1))000000000" \
    --data-urlencode "limit=$loki_limit" --data-urlencode direction=forward)
  [[ $status == 200 && $(jq -r '.status' "$work/loki-raw.json" 2>/dev/null) == success ]] ||
    fail "Loki query through Grafana is 200 (status $status): $1"
  jq '[.data.result[] | .stream as $s | .values[] | $s + {line: .[1], ts: .[0]}] | sort_by(.ts)' \
    "$work/loki-raw.json" >"$work/loki.json"
  n=$(jq length "$work/loki.json")
  ((n < loki_limit)) || fail "Loki query returned $n lines, its limit; lines would be missing: $1"
}

# tempo_search TRACEQL START END: the traces matching TRACEQL between START and END (seconds since
# the epoch) into $work/tempo-traces, one "START_SECONDS TRACE_ID" line each, oldest first. Trace
# ids are padded to 32 hex digits: Tempo drops leading zeros, logs and GlitchTip keep them.
# Tempo answers 400 "start must be before end" when START is exactly 30 s before its now, to the
# second (it splits the range there and one part is empty); a second later the search works, so
# that answer is asked again.
tempo_search() {
  local status try
  for try in 1 2 3; do
    status=$(obs_get "$proxy_url/tempo/api/search" "$work/tempo-search.json" --data-urlencode "q=$1" \
      --data-urlencode "start=${2%.*}" --data-urlencode "end=$((${3%.*} + 1))" --data-urlencode limit=1000)
    [[ $status == 400 ]] && grep -q 'start must be before end' "$work/tempo-search.json" || break
    sleep 1
  done
  [[ $status == 200 ]] ||
    fail "Tempo search through Grafana is 200 (status $status: $(head -c 200 "$work/tempo-search.json" | tr '\n' ' ')): $1"
  jq -r '.traces[]? | "\(.startTimeUnixNano) \(.traceID)"' "$work/tempo-search.json" |
    awk '$2 ~ /^[0-9a-f]+$/ { id = $2; while (length(id) < 32) id = "0" id; printf "%.6f %s\n", $1 / 1e9, id }' |
    sort -n >"$work/tempo-traces"
}

# tempo_trace TRACE_ID OUT: the whole trace from Tempo into OUT; prints the HTTP status (404 while
# Tempo has not ingested it yet).
tempo_trace() { obs_get "$proxy_url/tempo/api/traces/$1" "$2"; }

# am_alerts ALERTNAME SEVERITY: the alerts with that name and severity that Alertmanager holds (in
# any state; resolved ones are gone) into $work/alerts.json, each with `starts`, its startsAt in
# seconds since the epoch.
am_alerts() {
  local status
  status=$(obs_get "$alertmanager_url/api/v2/alerts" "$work/alerts-raw.json" \
    --data-urlencode "filter=alertname=\"$1\"" --data-urlencode "filter=severity=\"$2\"")
  [[ $status == 200 ]] || fail "Alertmanager GET /api/v2/alerts is 200 (status $status)"
  jq "$jq_epoch"' [.[] | . + {starts: (.startsAt | epoch)}]' "$work/alerts-raw.json" >"$work/alerts.json"
}

# wait_alert_gone ALERTNAME SEVERITY TIMEOUT: waits until Alertmanager holds no such alert, printing
# its progress every minute, so that the alert a drill then checks is a new one; fails after
# TIMEOUT seconds.
wait_alert_gone() {
  local start=$SECONDS next=0
  while :; do
    am_alerts "$1" "$2"
    [[ $(jq length "$work/alerts.json") == 0 ]] && return 0
    ((SECONDS - start < $3)) ||
      fail "$1 ($2) from an earlier run resolved in Alertmanager within $3 s (still active; run the drill again later)"
    if ((SECONDS - start >= next)); then
      echo "wait  $1 ($2) from an earlier run still active after $((SECONDS - start)) s; waiting for it to resolve (at most $3 s)"
      next=$((next + 60))
    fi
    sleep 15
  done
}

# wait_alert_new ALERTNAME SEVERITY SINCE TIMEOUT: polls Alertmanager every 5 s until it holds such
# an alert with startsAt after SINCE (seconds since the epoch) and sets alert_starts to that
# startsAt; returns 1 after TIMEOUT seconds, so the caller can say why before failing.
wait_alert_new() {
  local deadline=$((SECONDS + $4))
  while :; do
    am_alerts "$1" "$2"
    alert_starts=$(jq -r --argjson t "$3" '[.[] | select(.starts > $t) | .starts] | min // ""' "$work/alerts.json")
    [[ -n $alert_starts ]] && return 0
    ((SECONDS < deadline)) || return 1
    sleep 5
  done
}

# recent_5xx_expr SELECTOR: PromQL for the 5xx that the gateway HTTP count series of SELECTOR (with
# a 5xx status matcher) shows in the last 60 s: the increase of every series, plus every series
# that appeared meanwhile, since the first sample of a new series already holds errors that
# increase() does not count.
recent_5xx_expr() {
  printf '(sum(increase(%s[60s])) or vector(0)) + (sum(%s unless %s offset 60s) or vector(0))' "$1" "$1" "$1"
}

# wait_quiet_5xx SELECTOR SECONDS TIMEOUT: waits until Prometheus has shown no new 5xx in SELECTOR
# for SECONDS in a row (polling every 5 s), so that the error tracker's limit of one event per
# fingerprint per 30 s (ADR-0011, section 7) cannot hold back the event of the next error; fails
# after TIMEOUT seconds. A 5xx not yet exported (at most 15 s old) cannot be seen this way.
wait_quiet_5xx() {
  local start=$SECONDS quiet_since=
  while :; do
    prom_query "$(recent_5xx_expr "$1")"
    if awk -v v="$prom_value" 'BEGIN { exit !(v + 0 == 0) }'; then
      quiet_since=${quiet_since:-$SECONDS}
      ((SECONDS - quiet_since >= $2)) && return 0
    else
      quiet_since=
    fi
    ((SECONDS - start < $3)) || fail "no new 5xx in Prometheus for $2 s in a row within $3 s ($1)"
    sleep 5
  done
}

# sentry_init: reads SENTRY_API_URL, SENTRY_ORG, SENTRY_PROJECT and SENTRY_AUTH_TOKEN from .env
# with the strict rule of deploy/observability/glitchtip/dotenv.sh; fails naming the first one
# missing or empty, never printing a value.
sentry_init() {
  local v
  # shellcheck source=deploy/observability/glitchtip/dotenv.sh
  . "$repo_root/deploy/observability/glitchtip/dotenv.sh"
  for v in SENTRY_API_URL SENTRY_ORG SENTRY_PROJECT SENTRY_AUTH_TOKEN; do
    [[ -n $(dotenv_value "$env_file" "$v") ]] ||
      fail "$v is missing or empty in .env; run make up OBS=lgtm (or make glitchtip-init) first"
  done
  sentry_api_url=$(dotenv_value "$env_file" SENTRY_API_URL)
  sentry_org=$(dotenv_value "$env_file" SENTRY_ORG)
  sentry_project=$(dotenv_value "$env_file" SENTRY_PROJECT)
  sentry_token=$(dotenv_value "$env_file" SENTRY_AUTH_TOKEN)
  # Another port on the loopback can be an SSH tunnel to another machine: only GlitchTip's own.
  [[ $sentry_api_url == http://127.0.0.1:8000 ]] ||
    fail "SENTRY_API_URL in .env is the local GlitchTip (http://127.0.0.1:8000); the drills send its token nowhere else"
  [[ $sentry_org =~ ^[a-z0-9-]+$ && $sentry_project =~ ^[a-z0-9-]+$ ]] ||
    fail "SENTRY_ORG and SENTRY_PROJECT in .env are slugs"
}

# sentry_get PATH OUT: GET PATH (under SENTRY_API_URL, or a full URL there such as a next page)
# with the drill token into OUT, the response headers into $work/sentry.headers; sets
# sentry_status. A 401 or 403 fails: the token is wrong or lacks its scopes.
sentry_get() {
  local url=$1
  [[ $url == http* ]] || url=$sentry_api_url$url
  [[ $url == "$sentry_api_url"/* ]] || fail "GlitchTip API URL stays under SENTRY_API_URL (got another host)"
  : >"$2"
  sentry_status=$(printf 'Authorization: Bearer %s\n' "$sentry_token" |
    curl -sS --max-time "$max_time" -H @- -o "$2" -D "$work/sentry.headers" -w '%{http_code}' "$url" || true)
  case $sentry_status in
    401 | 403)
      fail "GlitchTip API answered $sentry_status: SENTRY_AUTH_TOKEN in .env is wrong or lacks the event:read and project:read scopes"
      ;;
  esac
}

# sentry_next_page: the next page's URL from the Link header of the last sentry_get, "" on the last
# page.
sentry_next_page() {
  { tr -d '\r' <"$work/sentry.headers" | grep -i '^link:' | grep -o '<[^>]*>; rel="next"; results="true"' || true; } |
    sed 's/^<\([^>]*\)>.*/\1/' | head -n 1
}

# sentry_find_event TRACE_ID: looks for the GlitchTip event tagged with TRACE_ID: the issues whose
# tags hold it, then their events, page by page, for the one with that trace_id tag (an issue's
# newest event need not be it). Sets sentry_event (its event id), sentry_issue and sentry_link
# (the issue's page), all "" when there is none yet.
sentry_find_event() {
  local issue url page
  sentry_event=
  sentry_issue=
  sentry_link=
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/issues/?query=trace_id%3A$1" "$work/sentry-issues.json"
  [[ $sentry_status == 200 ]] || fail "GlitchTip issue search by trace_id is 200 (status $sentry_status)"
  for issue in $(jq -r '.[].id | select(test("^[0-9]+$"))' "$work/sentry-issues.json"); do
    url="/api/0/issues/$issue/events/"
    for ((page = 0; page < 20; page++)); do
      sentry_get "$url" "$work/sentry-events.json"
      [[ $sentry_status == 200 ]] || fail "GlitchTip events of issue $issue is 200 (status $sentry_status)"
      sentry_event=$(jq -r --arg t "$1" \
        'first(.[] | select(any(.tags[]?; .key == "trace_id" and .value == $t)) | .event_id) // ""' "$work/sentry-events.json")
      if [[ -n $sentry_event ]]; then
        sentry_issue=$issue
        sentry_link=$(jq -r --arg i "$issue" 'first(.[] | select(.id == $i) | .permalink) // ""' "$work/sentry-issues.json")
        return 0
      fi
      url=$(sentry_next_page)
      [[ -n $url ]] || break
    done
  done
}

# sentry_event_json EVENT_ID OUT: the whole event into OUT; fails unless it is there.
sentry_event_json() {
  [[ $1 =~ ^[0-9a-f]{32}$ ]] || fail "GlitchTip event id is 32 hex digits (got '$1')"
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/events/$1/" "$2"
  [[ $sentry_status == 200 ]] || fail "GlitchTip GET event $1 is 200 (status $sentry_status)"
}

# sentry_events_since EPOCH: sets sentry_count to how many events GlitchTip received at or after
# EPOCH (seconds since the epoch), over every issue of the project seen since then.
sentry_events_since() {
  local url next page issue epage eurl
  sentry_count=0
  url="/api/0/projects/$sentry_org/$sentry_project/issues/"
  for ((page = 0; page < 20; page++)); do
    sentry_get "$url" "$work/sentry-issues.json"
    [[ $sentry_status == 200 ]] || fail "GlitchTip issue list is 200 (status $sentry_status)"
    next=$(sentry_next_page)
    for issue in $(jq -r --argjson t "$1" "$jq_epoch"' .[] | select((.lastSeen | epoch) >= $t) | .id | select(test("^[0-9]+$"))' \
      "$work/sentry-issues.json"); do
      eurl="/api/0/issues/$issue/events/"
      for ((epage = 0; epage < 20; epage++)); do
        sentry_get "$eurl" "$work/sentry-events.json"
        [[ $sentry_status == 200 ]] || fail "GlitchTip events of issue $issue is 200 (status $sentry_status)"
        sentry_count=$((sentry_count + $(jq --argjson t "$1" "$jq_epoch"' [.[] | select((.date_received | epoch) >= $t)] | length' \
          "$work/sentry-events.json")))
        eurl=$(sentry_next_page)
        [[ -n $eurl ]] || break
      done
    done
    url=$next
    [[ -n $url ]] || break
  done
}

# explore_link DATASOURCE_UID QUERY FROM TO: a Grafana Explore URL running QUERY on that datasource
# between FROM and TO (seconds since the epoch), to go over a drill's step by hand.
explore_link() {
  jq -rn --arg g "$grafana_url" --arg ds "$1" --arg q "$2" --arg from "${3%.*}000" --arg to "$((${4%.*} + 1))000" '
    {a: {datasource: $ds,
         queries: [{refId: "A", datasource: {uid: $ds}, query: $q} + (if $ds == "tempo" then {queryType: "traceql"} else {} end)],
         range: {from: $from, to: $to}}}
    | tojson | @uri | "\($g)/explore?schemaVersion=1&orgId=1&panes=\(.)"'
}

# obs_preflight: the stack of `make up OBS=lgtm` answers: Grafana, and Prometheus, Tempo and Loki
# through it, Alertmanager, the GlitchTip API with the drill token; the gateway's metrics reached
# Prometheus (through the Collector) within the last 45 s; and .env holds SENTRY_DSN, without which
# the services report no error, so a drill would wait for an event that cannot come.
obs_preflight() {
  local status age
  status=$(obs_get "$grafana_url/api/health" "$work/obs.json")
  [[ $status == 200 ]] || fail "Grafana at $grafana_url answers (status $status); run make up OBS=lgtm"
  status=$(obs_get "$alertmanager_url/-/ready" "$work/obs.json")
  [[ $status == 200 ]] || fail "Alertmanager at $alertmanager_url is ready (status $status); run make up OBS=lgtm"
  status=$(obs_get "$proxy_url/tempo/api/echo" "$work/obs.json")
  [[ $status == 200 ]] || fail "Tempo answers through Grafana (status $status)"
  status=$(obs_get "$proxy_url/loki/loki/api/v1/labels" "$work/obs.json")
  [[ $status == 200 ]] || fail "Loki answers through Grafana (status $status)"
  prom_query 'time() - max(timestamp(go_goroutine_count{service_name="gateway"}))'
  age=${prom_value:-never}
  awk -v a="$age" 'BEGIN { exit !(a != "never" && a + 0 < 45) }' ||
    fail "the gateway's metrics reach Prometheus (last sample $age s ago; is otelcol running?)"
  sentry_init
  [[ -n $(dotenv_value "$env_file" SENTRY_DSN) ]] ||
    fail "SENTRY_DSN is missing or empty in .env, so the services report no error; run make glitchtip-init, then make up OBS=lgtm"
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/" "$work/obs.json"
  [[ $sentry_status == 200 ]] ||
    fail "GlitchTip API at $sentry_api_url answers for project $sentry_org/$sentry_project (status $sentry_status)"
  ok "observability stack up: Grafana, Prometheus, Tempo, Loki, Alertmanager, GlitchTip API (gateway metrics ${age%.*} s old)"
}
