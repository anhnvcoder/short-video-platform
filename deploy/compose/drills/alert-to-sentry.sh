#!/usr/bin/env bash
# Drill: from a page alert to the error in under five minutes (the "done when" of stage 3). On the
# stack of `make up OBS=lgtm`:
#   1. the observability stack answers (Grafana, Prometheus, Tempo, Loki, Alertmanager, the
#      GlitchTip API with the drill token from .env); a fresh user reads GET /feed/following and
#      GET /feed/explore in turn every load_interval seconds in the background until the drill
#      ends (2 requests/s, far under the read limit of 600/min, burst 200);
#   2. before T0: the page alert of feed-availability (FeedAvailabilityBudgetBurn, severity=page)
#      is not in Alertmanager (after an earlier run its 30m/6h window keeps it firing for about 30
#      minutes: the drill waits for it to resolve, at most resolve_timeout seconds, printing its
#      progress), and for 31 s in a row Prometheus showed no new feed 5xx, nor did the load: the
#      error tracker sends one event per fingerprint per 30 s, and an error just before T0 would
#      hold back the event of the first error after it;
#   3. T0: stop feed-service, a real outage: the feed answers 5xx;
#   4. T1: startsAt of the new page alert (startsAt after T0) in Alertmanager, within
#      alert_timeout seconds (on timeout: the rule's state and the current error ratios); then
#      feed-service starts again;
#   5. T2: in Tempo, the earliest gateway trace after T0 on a feed route with a 5xx; it holds a
#      gRPC client span to feed-service in error status;
#   6. T3: in Loki, the gateway's access log line of that trace_id, with a 5xx status;
#   7. T4: in GlitchTip, the event tagged with that trace_id, or, when the tracker's limit held it
#      back, the one of the next error trace in order, whose client span and log line are then
#      checked the same way, so that trace, log line and event share one trace_id; within
#      sentry_timeout seconds;
#   8. prints T1 - T0 and T4 - T1 (under 5 minutes: the stage's target), links to Grafana Explore,
#      Alertmanager and GlitchTip to go over the steps by hand, and how many GlitchTip events the
#      run produced;
#   9. when the config Alertmanager runs has a Telegram receiver (GET /api/v2/status; its
#      entrypoint writes one from SVP_ALERT_TELEGRAM_BOT_TOKEN and SVP_ALERT_TELEGRAM_CHAT_ID when
#      the container starts), its count of Telegram notifications went up after T1 and its failure
#      count did not; else SKIP. Both variables set in .env with no such receiver loaded fails
#      before T0.
# Prints one ok/FAIL line per check and exits non-zero on the first failure; on exit (passed or
# not) the load stops and every stack service runs again. Reads no database; reads from .env only
# the GlitchTip and Telegram variables, never printing a value.
#
# Usage (from the repo root, stack up with OBS=lgtm): make drill-alert-to-sentry
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

load_interval=${load_interval:-0.5}
# An earlier run's page alert resolves about 30 minutes after its errors (the 30m window).
resolve_timeout=${resolve_timeout:-2400}
alert_timeout=600
sentry_timeout=120
# The stage's target for T4 - T1.
target_seconds=300
quiet_seconds=31

alert=FeedAvailabilityBudgetBurn
feed_selector='http_server_request_duration_seconds_count{service_name="gateway",http_request_method="GET",http_route=~"/feed/following|/feed/explore"'
feed_5xx="$feed_selector,http_response_status_code=~\"5..\"}"
error_traces='{ resource.service.name = "gateway" && span:kind = server && span.http.route =~ "/feed/following|/feed/explore" && span.http.response.status_code >= 500 }'

# start_load: as user "load", GET /feed/following and /feed/explore in turn every load_interval
# seconds, in the background; one "EPOCH FEED STATUS" line per request in $work/load.log.
start_load() {
  (
    while :; do
      for feed in following explore; do
        s=$(curl -s -o /dev/null --max-time "$max_time" -w '%{http_code}' -H "@$work/load.auth" \
          "$base/feed/$feed?page_size=1" || true)
        printf '%s %s %s\n' "$(date +%s)" "$feed" "$s" >>"$work/load.log"
        sleep "$load_interval"
      done
    done
  ) &
  load_pid=$!
}

# load_statuses SECONDS: the statuses the load got in the last SECONDS, as "COUNT STATUS" lines.
load_statuses() {
  awk -v t="$(($(date +%s) - $1))" '$1 >= t { print $3 }' "$work/load.log" | sort | uniq -c | awk '{ print $1 " " $2 }'
}

# telegram_counts: sets tg_sent and tg_failed to Alertmanager's counts of Telegram notifications
# sent and failed, from its own /metrics.
telegram_counts() {
  local status
  status=$(obs_get "$alertmanager_url/metrics" "$work/am-metrics")
  [[ $status == 200 ]] || fail "Alertmanager GET /metrics is 200 (status $status)"
  tg_sent=$(awk '/^alertmanager_notifications_total\{.*integration="telegram"/ { n += $NF } END { print n + 0 }' "$work/am-metrics")
  tg_failed=$(awk '/^alertmanager_notifications_failed_total\{.*integration="telegram"/ { n += $NF } END { print n + 0 }' "$work/am-metrics")
}

# telegram_loaded: whether the config Alertmanager runs (GET /api/v2/status) has a receiver with
# telegram_configs.
telegram_loaded() {
  local status
  status=$(obs_get "$alertmanager_url/api/v2/status" "$work/am-status.json")
  [[ $status == 200 ]] || fail "Alertmanager GET /api/v2/status is 200 (status $status)"
  jq -r '.config.original // ""' "$work/am-status.json" |
    awk '/^receivers:/ { r = 1; next } /^[^ -]/ { r = 0 } r && /^ +telegram_configs:/ { found = 1 } END { exit !found }'
}

# trace_client_span TRACE: polls Tempo (at most 60 s) until TRACE holds the gateway's gRPC client
# span to feed-service in error status; sets client to its name and gRPC code.
trace_client_span() {
  local deadline=$((SECONDS + 60)) status
  while :; do
    status=$(tempo_trace "$1" "$work/trace.json")
    if [[ $status == 200 ]]; then
      client=$(jq -r '[(.batches // .resourceSpans)[]
        | select(any(.resource.attributes[]?; .key == "service.name" and .value.stringValue == "gateway"))
        | (.scopeSpans // .instrumentationLibrarySpans)[]?.spans[]?
        | select((.kind == "SPAN_KIND_CLIENT" or .kind == 3) and (.name | startswith("svp.feed.v1.FeedService/"))
                 and (.status.code == "STATUS_CODE_ERROR" or .status.code == 2))
        | .name + " (" + ([.attributes[]? | select(.key == "rpc.response.status_code") | .value.stringValue // (.value.intValue | tostring)] | first // "no code") + ")"]
        | first // ""' "$work/trace.json")
      [[ -n $client ]] && return 0
    fi
    ((SECONDS < deadline)) ||
      fail "trace $1 holds a gateway gRPC client span to feed-service in error status (status $status)"
    sleep 3
  done
}

# trace_log_line TRACE: polls Loki (at most 60 s) until it has the gateway's access log line of
# TRACE with a 5xx status; sets line to its route, status and user_id.
trace_log_line() {
  local deadline=$((SECONDS + 60))
  while :; do
    loki_query "{service_name=\"gateway\"} | trace_id=\"$1\"" "$((${t0%.*} - 5))" "$(now)"
    line=$(jq -c 'first(.[] | select(.line == "http request" and (.status // "" | test("^5")))) | {route, status, user_id}' "$work/loki.json")
    [[ -n $line ]] && return 0
    ((SECONDS < deadline)) || fail "Loki has the gateway's access log line of trace $1 with a 5xx status within 60 s"
    sleep 3
  done
}

# since SECONDS_A SECONDS_B: B - A with one decimal.
since() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# clock SECONDS: the UTC time of day of SECONDS since the epoch. GNU date (Linux, the CI runner) reads an epoch with
# -d @SECONDS; BSD date (macOS) has no -d for it and needs -r instead.
if date -u -d @0 +%s >/dev/null 2>&1; then
  clock() { date -u -d "@${1%.*}" +%H:%M:%SZ; }
else
  clock() { date -u -r "${1%.*}" +%H:%M:%SZ; }
fi

obs_preflight
if telegram_loaded; then
  telegram=on
elif [[ -n $(dotenv_value "$env_file" SVP_ALERT_TELEGRAM_BOT_TOKEN) && -n $(dotenv_value "$env_file" SVP_ALERT_TELEGRAM_CHAT_ID) ]]; then
  fail "Telegram: SVP_ALERT_TELEGRAM_BOT_TOKEN and SVP_ALERT_TELEGRAM_CHAT_ID are set in .env, but Alertmanager runs no Telegram receiver: the chat id is not an integer, or the values came after the container started (run make up OBS=lgtm again; see make logs SVC=alertmanager)"
else
  telegram=off
fi
wait_gateway_ready 60
new_user load
: >"$work/load.log"
start_load
ok "background load: GET /feed/following and /feed/explore in turn every $load_interval s"

# 2. Preconditions before T0.
wait_alert_gone "$alert" page "$resolve_timeout"
ok "$alert (page) not active in Alertmanager"
wait_quiet_5xx "$feed_5xx" "$quiet_seconds" 300
statuses=$(load_statuses "$quiet_seconds")
[[ -n $statuses && $(awk '$2 != 200' <<<"$statuses") == "" ]] ||
  fail "the load got only 200 in the last $quiet_seconds s (got: $(tr '\n' ' ' <<<"$statuses"))"
ok "no feed 5xx for $quiet_seconds s in a row: Prometheus shows none, the load got only 200 ($(awk '{ n += $1 } END { print n }' <<<"$statuses") requests)"
if [[ $telegram == on ]]; then telegram_counts; tg_sent0=$tg_sent tg_failed0=$tg_failed; fi

# 3. T0: the outage.
t0=$(now)
compose stop feed-service >/dev/null 2>&1 || fail "stop feed-service"
ok "T0 $(clock "$t0"): feed-service stopped"

# 4. T1: the new page alert.
if ! wait_alert_new "$alert" page "$t0" "$alert_timeout"; then
  obs_get "$proxy_url/prometheus/api/v1/rules" "$work/rules.json" --data-urlencode "rule_name[]=$alert" >/dev/null
  echo "      rule $alert: $(jq -c '[.data.groups[]?.rules[]? | {severity: .labels.severity, state, health, lastError}]' "$work/rules.json" 2>/dev/null)" >&2
  for w in 5m 1h 30m 6h; do
    prom_query "slo:sli_error:ratio_rate$w{sloth_slo=\"feed-availability\"}"
    echo "      feed-availability error ratio over $w: ${prom_value:-no data}" >&2
  done
  fail "a new $alert (page) alert in Alertmanager within $alert_timeout s of T0"
fi
t1=$alert_starts
ok "T1 $(clock "$t1"): $alert (page) startsAt, T1 - T0 = $(since "$t0" "$t1") s"
start_service feed-service
ok "feed-service running again"

# 5. T2: the earliest error trace after T0, from Tempo.
deadline=$((SECONDS + 120))
while :; do
  tempo_search "$error_traces" "$t0" "$t1"
  awk -v t="$t0" '$1 > t { print $2 }' "$work/tempo-traces" >"$work/error-traces"
  [[ -s $work/error-traces ]] && break
  ((SECONDS < deadline)) || fail "Tempo has a gateway feed trace with a 5xx between T0 and T1 within 120 s"
  sleep 3
done
trace=$(head -n 1 "$work/error-traces")
trace_client_span "$trace"
t2=$(now)
ok "T2 $(clock "$t2"): earliest error trace after T0 $trace ($(wc -l <"$work/error-traces" | tr -d ' ') error traces between T0 and T1), client span $client"

# 6. T3: the gateway's access log line of that trace, from Loki.
trace_log_line "$trace"
t3=$(now)
ok "T3 $(clock "$t3"): gateway access log of trace $trace: $line"

# 7. T4: the GlitchTip event, for the earliest error trace that has one. The time limit holds after
# every lookup, not only once all the traces were looked up: one pass over many traces without an
# event can take longer than the limit, and an event found after it is late.
deadline=$((SECONDS + sentry_timeout))
sentry_late="GlitchTip has an event tagged with the trace_id of one of the $(wc -l <"$work/error-traces" | tr -d ' ') error traces after T0 within $sentry_timeout s (the first one's event may have been held back by the tracker's 1 event/30 s limit and every later one too)"
sentry_trace=
while [[ -z $sentry_trace ]]; do
  while read -r t; do
    sentry_find_event "$t"
    ((SECONDS < deadline)) || fail "$sentry_late"
    if [[ -n $sentry_event ]]; then
      sentry_trace=$t
      break
    fi
  done <"$work/error-traces"
  [[ -n $sentry_trace ]] && break
  sleep 5
done
position=$(grep -n -x "$sentry_trace" "$work/error-traces" | cut -d: -f1)
if [[ $sentry_trace != "$trace" ]]; then
  # The chain goes on with the trace that has an event: its span and log line too.
  echo "note  error trace 1 ($trace) has no event (held back by the tracker's limit); error trace $position does: $sentry_trace"
  trace=$sentry_trace
  trace_client_span "$trace"
  ok "error trace $position $trace: client span $client"
  trace_log_line "$trace"
  ok "error trace $position $trace: gateway access log $line"
fi
t4=$(now)
sentry_event_json "$sentry_event" "$work/event.json"
[[ $(jq -r --arg t "$sentry_trace" '(.contexts.trace.trace_id == $t) and any(.tags[]; .key == "trace_id" and .value == $t)
  and any(.tags[]; .key == "service" and .value == "gateway")' "$work/event.json") == true ]] ||
  fail "GlitchTip event $sentry_event has trace_id $sentry_trace in its tags and trace context, and tag service=gateway"
ok "T4 $(clock "$t4"): GlitchTip event $sentry_event (issue $sentry_issue, tags $(jq -c '[.tags[] | select(.key == "route" or .key == "code") | "\(.key)=\(.value)"]' "$work/event.json")) of error trace $position after T0; trace, log line and event share trace_id $trace"

total=$(since "$t1" "$t4")
echo
echo "Alert to error, T0 = $(clock "$t0") feed-service stopped:"
echo "  T1 - T0  $(since "$t0" "$t1") s  alert startsAt"
echo "  T2 - T1  $(since "$t1" "$t2") s  trace found in Tempo"
echo "  T3 - T1  $(since "$t1" "$t3") s  log line found in Loki"
echo "  T4 - T1  $total s  GlitchTip event found, trace, log line and event of one trace_id (target < $target_seconds s)"
echo "Go over it by hand:"
echo "  alert   $alertmanager_url/#/alerts?filter=%7Balertname%3D%22$alert%22%7D"
echo "  trace   $(explore_link tempo "$trace" "$((${t0%.*} - 60))" "$(now)")"
echo "  logs    $(explore_link loki "{service_name=\"gateway\"} | trace_id=\"$trace\"" "$((${t0%.*} - 60))" "$(now)")"
echo "  error   ${sentry_link:-$sentry_api_url} (event $sentry_event)"
echo
awk -v s="$total" -v m="$target_seconds" 'BEGIN { exit !(s < m) }' || fail "T4 - T1 = $total s is under $target_seconds s"
ok "T4 - T1 = $total s, under $target_seconds s"

sentry_events_since "$t0"
ok "GlitchTip events received since T0: $sentry_count (the tracker sends at most one per fingerprint per 30 s)"

# 9. Telegram.
if [[ $telegram == on ]]; then
  deadline=$((SECONDS + 120))
  while :; do
    telegram_counts
    ((tg_sent > tg_sent0)) && break
    ((SECONDS < deadline)) || fail "Alertmanager sent a Telegram notification within 120 s of T1 (sent $tg_sent0 -> $tg_sent)"
    sleep 5
  done
  ((tg_failed == tg_failed0)) || fail "Alertmanager's Telegram notifications did not fail (failed $tg_failed0 -> $tg_failed)"
  ok "Telegram: Alertmanager sent $((tg_sent - tg_sent0)) notification(s) since T0, none failed"
else
  echo "SKIP  Telegram: Alertmanager runs no Telegram receiver (SVP_ALERT_TELEGRAM_BOT_TOKEN or SVP_ALERT_TELEGRAM_CHAT_ID empty in .env); the alert is only in $alertmanager_url"
fi

echo "drill-alert-to-sentry: all checks passed"
