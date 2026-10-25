#!/usr/bin/env bash
# Game day on the compose stack: a real outage under the background
# load of k6, handled by the on-call with the runbook of the page alert alone, timed for the postmortem. The outage is
# engagement-service stopped, which opens the gateway's circuit breaker to it and fires CircuitBreakerOpen (page).
#
#   gameday.sh start [BASE]   (make gameday; runs the whole session in one terminal)
#     1. checks the stack of `make up OBS=lgtm` answers (obs_preflight of common.sh), engagement-service runs, and no
#        page alert is active in Alertmanager: an earlier run's alert must resolve first (waits at most
#        resolve_timeout seconds, printing its progress), since a page already firing would hide the new one; the
#        session (its folder, mark and end) starts before that wait;
#     2. starts k6 profile local (deploy/k6/main.js in K6_IMAGE, as deploy/k6/load.sh runs it) held for SVP_K6_HOLD
#        (default 60m: the session ends it sooner), waits for the ramp and steady_seconds of steady state, and fails
#        unless the load got no 5xx or connection error by then;
#     3. T0: stops engagement-service (compose stop, the container of this project only);
#     4. T1: startsAt of the new CircuitBreakerOpen (page) in Alertmanager, within alert_timeout seconds; when it does
#        not come, the miss is written to the timeline (a detection failure is a result too) and the session goes on;
#     5. waits for the on-call, writing to the timeline what it sees by itself (engagement-service running again, the
#        breaker closed in Prometheus, the alert resolved) until `end`;
#     on exit (end, Ctrl-C or a failure): the load stops (the k6 container, svp-gameday-k6, is stopped and removed, or
#     removed before it starts when it was created but not started yet, so no load starts after the session); once T0
#     was reached, engagement-service and every other stack service run again, while a session that stops before T0
#     (the k3d cluster running, a failed check, an early end) starts no container, since it changed none;
#     .k6/gameday-<time>/ holds timeline.tsv (with the reason of a failure), report.txt (timeline, durations, the
#     load's requests and errors by route between T0 and the `recovered` mark, the gateway's from Prometheus), k6.log
#     and k6's summary.json.
#   gameday.sh mark diagnosed|mitigated|recovered   (make gameday-mark M=...; from another terminal)
#     writes the on-call's mark to the running session's timeline, with a snapshot of k6's counters at that moment.
#   gameday.sh end   (make gameday-end)
#     asks the running session to end at whatever step it is (before T0 it ends without the outage), waits until it
#     has put the stack back, then prints its report.
# mark and end exit non-zero when no session runs.
#
# k6 serves its REST API on 127.0.0.1:6565 for the session (the counters by route behind the windowed numbers). That
# API also serves setup data, the pool users' tokens, so it is bound to loopback only and nothing but /v1/metrics is
# read. Reads no database. LOCAL LAB ONLY: like every drill it deletes the gateway's register rate limit keys in Redis
# db 10 first (deploy/compose/lib.sh), since the k6 pool registers from one address.
#
# Usage (from the repo root, stack up with OBS=lgtm and a READY video, e.g. after make smoke):
#   make gameday; make gameday-mark M=diagnosed; make gameday-end
set -euo pipefail

cmd=${1:-}
repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
results_root=$repo_root/.k6
# Holds the folder of the running session; its pid file says whether that session still runs.
pointer=$results_root/gameday.current
k6_port=6565
k6_url=http://127.0.0.1:$k6_port
# The k6 container's name: created and started apart, it is stopped and removed by name, so it needs no container id.
k6_name=svp-gameday-k6
marks="diagnosed mitigated recovered"
# The k6 routes of deploy/k6/lib/config.js, in its order.
k6_routes=("/feed/explore" "/feed/following" "/videos/{video_id}/like" "/videos/{video_id}/views" "/videos" "/" "/v/[id]" "/login")

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
clock() { date -u -r "${1%.*}" +%H:%M:%SZ; }

# record DIR EPOCH EVENT SOURCE: one "EPOCH UTC EVENT SOURCE" line, tab-separated, in DIR/timeline.tsv.
record() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$(date -u -r "${2%.*}" +%Y-%m-%dT%H:%M:%SZ)" "$3" "$4" >>"$1/timeline.tsv"
}

# event_time DIR EVENT: the epoch of the first EVENT line of DIR/timeline.tsv, or "".
event_time() { awk -F '\t' -v e="$2" '$3 == e { print $1; exit }' "$1/timeline.tsv"; }

# session_alive DIR: whether the `start` process of DIR still runs (its pid, running this script).
session_alive() {
  local pid
  pid=$(cat "$1/pid" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | grep -q 'gameday\.sh'
}

# active_session: prints the folder of the running session; otherwise says why and returns 1. A stale pointer (its
# process gone without cleaning up, e.g. killed with SIGKILL) is removed.
active_session() {
  local dir
  if [[ ! -f $pointer ]]; then
    echo "no game day is running (make gameday starts one)" >&2
    return 1
  fi
  dir=$(cat "$pointer")
  if ! session_alive "$dir"; then
    rm -f "$pointer"
    echo "no game day is running: the session in ${dir#"$repo_root"/} ended without cleaning up (its process is gone);" \
      "engagement-service or the k6 container $k6_name may still be as it left them: run make up OBS=lgtm, make ps," \
      "and env -u DOCKER_DEFAULT_PLATFORM docker rm -f $k6_name" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

# k6_snapshot DIR NAME: k6's current metrics (cumulative since its start) into DIR/k6-NAME.json.
k6_snapshot() {
  curl -sS --max-time 5 -o "$1/k6-$2.json" "$k6_url/v1/metrics" 2>/dev/null &&
    jq -e '.data | length > 0' "$1/k6-$2.json" >/dev/null 2>&1
}

# k6_window DIR A B: per route, the load's requests, failed requests (http_req_failed: 5xx and connection errors) and
# 429s between snapshots A and B, as tab-separated lines. k6 reports a rate for http_req_failed, so its count is
# rate x the route's request count, at each end.
k6_window() {
  local routes
  routes=$(printf '%s\n' "${k6_routes[@]}" | jq -R . | jq -sc .)
  jq -r --slurpfile b "$1/k6-$3.json" --argjson routes "$routes" '
    def m(d): [d.data[] | {key: .id, value: .attributes.sample}] | from_entries;
    def failed(x; r): ((x["http_req_failed{route:" + r + ",phase:load}"].rate // 0)
      * (x["http_reqs{route:" + r + ",phase:load}"].count // 0));
    m(.) as $a | m($b[0]) as $z | $routes[] as $r
    | [$r,
       (($z["http_reqs{route:" + $r + ",phase:load}"].count // 0) - ($a["http_reqs{route:" + $r + ",phase:load}"].count // 0)),
       ((failed($z; $r) - failed($a; $r)) | round),
       (($z["svp_rate_limited{route:" + $r + "}"].count // 0) - ($a["svp_rate_limited{route:" + $r + "}"].count // 0))]
    | @tsv' "$1/k6-$2.json"
}

case $cmd in
  mark)
    m=${2:-}
    case " $marks " in
      *" $m "*) ;;
      *)
        echo "usage: gameday.sh mark diagnosed|mitigated|recovered (make gameday-mark M=...)" >&2
        exit 2
        ;;
    esac
    dir=$(active_session) || exit 1
    t0=$(event_time "$dir" T0)
    [[ -n $t0 ]] || {
      echo "the outage is not injected yet (no T0 in ${dir#"$repo_root"/}/timeline.tsv); mark after T0" >&2
      exit 1
    }
    [[ -z $(event_time "$dir" "$m") ]] || {
      echo "$m is already marked at $(clock "$(event_time "$dir" "$m")"); the first mark stands" >&2
      exit 1
    }
    t=$(now)
    k6_snapshot "$dir" "$m" || echo "note  k6 metrics not available at this mark; its window falls back to the end" >&2
    record "$dir" "$t" "$m" "make gameday-mark M=$m"
    echo "ok    marked $m at $(clock "$t"), T0 + $(awk -v a="$t0" -v b="$t" 'BEGIN { printf "%.0f", b - a }') s"
    exit 0
    ;;
  end)
    dir=$(active_session) || exit 1
    pid=$(cat "$dir/pid")
    : >"$dir/end.request"
    echo "asked the game day in ${dir#"$repo_root"/} to end; waiting until it has put the stack back"
    deadline=$((SECONDS + 300))
    while kill -0 "$pid" 2>/dev/null; do
      ((SECONDS < deadline)) || {
        echo "FAIL  the session (pid $pid) did not end within 300 s; see its terminal" >&2
        exit 1
      }
      sleep 1
    done
    [[ -s $dir/report.txt ]] || {
      echo "FAIL  the session ended without writing ${dir#"$repo_root"/}/report.txt; see its terminal" >&2
      exit 1
    }
    cat "$dir/report.txt"
    exit 0
    ;;
  start) ;;
  *)
    echo "usage: gameday.sh start [BASE] | mark diagnosed|mitigated|recovered | end" >&2
    exit 2
    ;;
esac

: "${K6_IMAGE:?set K6_IMAGE (run make gameday)}"
if [[ -f $pointer ]] && session_alive "$(cat "$pointer")"; then
  echo "FAIL  a game day is already running in $(cat "$pointer"); make gameday-end ends it" >&2
  exit 1
fi
rm -f "$pointer"

base=${2:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

target=engagement-service
alert=CircuitBreakerOpen
runbook=docs/runbooks/circuit-breaker-open.md
hold=${SVP_K6_HOLD:-60m}
# k6 profile local ramps up for 30 s (deploy/k6/lib/config.js).
ramp_seconds=30
steady_seconds=120
alert_timeout=600
resolve_timeout=2400
k6_created=
k6_pid=
dir=
t0=
t1=
telegram=off
tg_sent0=0
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

# fail: lib.sh's, and once the session has its folder the reason also goes to the timeline, so that the report of a
# session that stopped says why.
fail() {
  if [[ -n $dir ]]; then record "$dir" "$(now)" fail "$1"; fi
  echo "FAIL  $1" >&2
  exit 1
}

# end_if_requested STEP: ends the session (status 0, the EXIT trap cleans up) when `end` asked for it; every wait of
# the session calls it, so that an end before T1 is honoured too.
end_if_requested() {
  [[ -e $dir/end.request ]] || return 0
  record "$dir" "$(now)" end-requested "make gameday-end $1"
  echo "ok    end requested $1"
  exit 0
}

# active_pages: the names of the page alerts active in Alertmanager (not silenced or inhibited), one per line; returns
# 1 when Alertmanager does not answer.
active_pages() {
  local status
  status=$(obs_get "$alertmanager_url/api/v2/alerts" "$work/pages.json" --data-urlencode 'filter=severity="page"' \
    --data-urlencode active=true --data-urlencode silenced=false --data-urlencode inhibited=false)
  [[ $status == 200 ]] || return 1
  jq -r '.[].labels.alertname' "$work/pages.json" | sort -u
}

# wait_no_page TIMEOUT: waits until no page alert is active, printing which ones still are every minute.
wait_no_page() {
  local start=$SECONDS next=0 names
  while :; do
    end_if_requested "before T0 (waiting for the earlier page alerts to resolve)"
    names=$(active_pages) || fail "Alertmanager GET /api/v2/alerts answers"
    [[ -z $names ]] && return 0
    ((SECONDS - start < $1)) ||
      fail "no page alert active within $1 s (still active: $(tr '\n' ' ' <<<"$names")); run make gameday again later"
    if ((SECONDS - start >= next)); then
      echo "wait  page alert(s) still active after $((SECONDS - start)) s: $(tr '\n' ' ' <<<"$names")(at most $1 s)"
      next=$((next + 60))
    fi
    sleep 15
  done
}

# prom_scalar EXPR: the value of EXPR's first sample, or "" when Prometheus does not answer or has none; unlike
# prom_query it never ends the script, so that a slow scrape does not end the session.
prom_scalar() {
  local status
  status=$(obs_get "$proxy_url/prometheus/api/v1/query" "$work/scalar.json" --data-urlencode "query=$1")
  [[ $status == 200 ]] || return 0
  jq -r '.data.result[0].value[1] // ""' "$work/scalar.json" 2>/dev/null || true
}

# telegram_loaded, telegram_sent: whether the config Alertmanager runs has a Telegram receiver, and how many Telegram
# notifications it has sent (the same reads as alert-to-sentry.sh).
telegram_loaded() {
  [[ $(obs_get "$alertmanager_url/api/v2/status" "$work/am-status.json") == 200 ]] || return 1
  jq -r '.config.original // ""' "$work/am-status.json" |
    awk '/^receivers:/ { r = 1; next } /^[^ -]/ { r = 0 } r && /^ +telegram_configs:/ { found = 1 } END { exit !found }'
}
telegram_sent() {
  obs_get "$alertmanager_url/metrics" "$work/am-metrics" >/dev/null
  awk '/^alertmanager_notifications_total\{.*integration="telegram"/ { n += $NF } END { print n + 0 }' "$work/am-metrics"
}

k6_running() { [[ -n $k6_pid ]] && kill -0 "$k6_pid" 2>/dev/null; }
k6_container_running() { [[ -n $(docker_ ps -q --filter "name=^$k6_name\$" --filter status=running) ]]; }

# stop_k6: ends the load whatever state its container is in. The container is created in the foreground, then
# started by a client in the background, rather than by one `docker run`: a `docker run` client that gets TERM between
# its create and its start forwards the signal to a container that does not run yet, which ignores it, then starts it,
# and the load would begin after the session ended. Split, only that start client ever starts the container. So a
# running container is stopped (k6 writes summary.json on SIGTERM; the client returns as it exits); one created and
# not started is removed, so the client's start fails at once with no such container, or, when its start already
# reached the daemon, the container it started is killed with the removal. Then the client is waited for (KILL after
# 60 s) and the name removed in any state. A Ctrl-C during the create itself (pulling the image, then creating) ends
# before the container exists or leaves it created, which nothing starts and the removal takes; one the daemon would
# finish creating after that is caught by the next session's precondition.
stop_k6() {
  local i
  [[ -n $k6_created ]] || return 0
  if k6_container_running; then
    docker_ stop -t 30 "$k6_name" >/dev/null 2>&1
  else
    docker_ rm -f "$k6_name" >/dev/null 2>&1
  fi
  if [[ -n $k6_pid ]]; then
    for ((i = 0; i < 60; i++)); do
      kill -0 "$k6_pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$k6_pid" 2>/dev/null
    wait "$k6_pid" 2>/dev/null
  fi
  docker_ rm -f "$k6_name" >/dev/null 2>&1
  echo "ok    k6 stopped"
}

# k6_failed_total FILE: the load's failed requests over every route in one snapshot.
k6_failed_total() {
  jq '[.data[] | {key: .id, value: .attributes.sample}] | from_entries as $m
    | [$m | keys[] | select(startswith("http_req_failed{route:") and endswith(",phase:load}"))
       | ($m[.].rate // 0) * ($m["http_reqs" + ltrimstr("http_req_failed")].count // 0)] | add // 0 | round' "$1"
}

since_t0() {
  local t
  t=$(event_time "$dir" "$1")
  if [[ -n $t && -n $t0 ]]; then awk -v a="$t0" -v b="$t" 'BEGIN { printf "%.0f s", b - a }'; else echo "not reached"; fi
}

write_report() {
  local w_end w_name w_secs
  if [[ -n ${t0:-} ]]; then
    echo "Game day ${dir##*/}: $target stopped under k6 profile local (hold $hold); runbook $runbook"
  else
    echo "Game day ${dir##*/}: ended before T0, $target was not stopped (the timeline says why)"
  fi
  echo
  echo "Timeline (UTC):"
  awk -F '\t' -v t0="${t0:-}" '{
    off = (t0 == "") ? "" : sprintf("T%+.0f s", $1 - t0)
    printf "  %s  %-9s  %-34s %s\n", substr($2, 12), off, $3, $4 }' "$dir/timeline.tsv"
  [[ -n ${t0:-} ]] || return 0
  echo
  echo "Durations from T0:"
  echo "  TTD (T1 - T0)                      $(since_t0 T1)"
  echo "  diagnosed (on-call mark)           $(since_t0 diagnosed)"
  echo "  mitigated (on-call mark)           $(since_t0 mitigated)"
  echo "  recovered (on-call mark)           $(since_t0 recovered)"
  echo "  $target running (seen)    $(since_t0 auto:service-running)"
  echo "  breaker closed (Prometheus)        $(since_t0 auto:breaker-closed)"
  echo "  $alert resolved (seen)  $(since_t0 auto:alert-resolved)"
  if [[ -f $dir/k6-recovered.json ]]; then w_name=recovered; else w_name=end; fi
  w_end=$(event_time "$dir" "$w_name")
  echo
  if [[ -f $dir/k6-T0.json && -f $dir/k6-$w_name.json ]]; then
    echo "k6 load between T0 and $w_name ($(awk -v a="$t0" -v b="$w_end" 'BEGIN { printf "%.0f", b - a }') s); failed = 5xx or connection error:"
    printf '  %-26s %9s %8s %6s\n' route requests failed 429
    k6_window "$dir" T0 "$w_name" | awk -F '\t' '{ printf "  %-26s %9s %8s %6s\n", $1, $2, $3, $4 }'
  else
    echo "k6 load between T0 and $w_name: no snapshot (k6 was not running at one end)"
  fi
  w_secs=$(awk -v a="$t0" -v b="$w_end" 'BEGIN { printf "%.0f", b - a }')
  if ((w_secs > 0)) && [[ $(obs_get "$proxy_url/prometheus/api/v1/query" "$work/window.json" --data-urlencode "time=${w_end%.*}" \
    --data-urlencode "query=sum by (http_route, http_response_status_code) (increase(http_server_request_duration_seconds_count{service_name=\"gateway\"}[${w_secs}s]))") == 200 ]]; then
    echo
    echo "Gateway requests between T0 and $w_name (Prometheus increase over ${w_secs}s, extrapolated):"
    printf '  %-26s %9s %8s\n' http_route total 5xx
    jq -r '[.data.result[] | {r: .metric.http_route, s: .metric.http_response_status_code, v: (.value[1] | tonumber)}]
      | group_by(.r)[] | [.[0].r, (map(.v) | add | round), (map(select(.s | startswith("5")) | .v) | add // 0 | round)] | @tsv' \
      "$work/window.json" | awk -F '\t' '{ printf "  %-26s %9s %8s\n", $1, $2, $3 }'
  fi
  echo
  if [[ $telegram == on ]]; then
    echo "Telegram: Alertmanager sent $(($(telegram_sent) - tg_sent0)) notification(s) since T0"
  else
    echo "Telegram: not configured (no receiver in Alertmanager); the page was only in $alertmanager_url"
  fi
  echo "k6 over the whole run (thresholds fail by design during the outage): ${dir#"$repo_root"/}/k6.log, summary.json"
}

# gameday_exit: the EXIT trap, in place of common.sh's drill_exit. Takes k6's last snapshot, puts every stack service
# back, stops k6 (stop_k6: its summary.json is written on the way out), writes the report, and keeps the exit status
# (1 when the stack cannot be restored). Ignores INT and TERM while it runs. The stack is put back only once the session
# changed it (t0 is set right before the stop): an earlier exit, such as the k3d guard's, must not start the compose
# stack beside a cluster, and has nothing to undo.
gameday_exit() {
  local rc=$? leaks
  # A second Ctrl-C must not cut the cleanup short: the stack would stay half down and the k6 container running.
  trap - EXIT
  trap '' INT TERM
  set +e
  if [[ -n $dir ]]; then
    record "$dir" "$(now)" end "gameday.sh exit (status $rc)"
    k6_running && k6_snapshot "$dir" end
  fi
  if [[ -n $t0 ]]; then
    restore_stack || rc=1
  elif [[ -n $dir ]]; then
    echo "ok    stack left as it was: the session ended before T0, $target was not stopped"
  fi
  stop_k6
  if [[ -n $dir ]]; then
    write_report >"$dir/report.txt" 2>&1
    if leaks=$(grep -rIlE -i 'eyJ[A-Za-z0-9_-]{8,}|svp_sid|bearer|password|cookie|token|set-cookie' "$dir"); then
      echo "FAIL  the results hold a token, cookie or password: ${leaks//$repo_root\//}" >&2
      rc=1
    fi
    echo
    cat "$dir/report.txt"
    [[ $(cat "$pointer" 2>/dev/null) == "$dir" ]] && rm -f "$pointer"
  fi
  rm -rf "$work"
  exit "$rc"
}
trap gameday_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 1. Preconditions.
[[ -z $(docker_ ps -q --filter label=k3d.cluster=svp; docker_ ps -q --filter 'name=^k3d-svp-registry$') ]] ||
  fail "the k3d cluster svp or its registry is running; the game day runs on the compose stack only"
obs_preflight
[[ -n $(compose ps --status running -q "$target") ]] || fail "$target is running before the game day (make up OBS=lgtm)"
docker_ network inspect svp_web >/dev/null 2>&1 || fail "compose network svp_web exists (make up OBS=lgtm)"
[[ -z $(docker_ ps -aq --filter "name=^$k6_name\$") ]] ||
  fail "no container $k6_name is left from an earlier session (env -u DOCKER_DEFAULT_PLATFORM docker rm -f $k6_name removes it)"
curl -s -o /dev/null --max-time 2 "$k6_url/" && fail "127.0.0.1:$k6_port is free for k6's REST API (something answers there)"
wait_gateway_ready 60
if telegram_loaded; then telegram=on; else telegram=off; fi

mkdir -p "$results_root"
dir=$results_root/gameday-$(date -u +%Y%m%dT%H%M%SZ)
mkdir "$dir"
echo "$$" >"$dir/pid"
echo "$dir" >"$pointer"
record "$dir" "$(now)" start "make gameday (telegram $telegram)"
wait_no_page "$resolve_timeout"
ok "no page alert active in Alertmanager"

# 2. Background load and steady state. The container is created here and started apart (stop_k6 says why);
# k6_created is set first, since a Ctrl-C during the create may leave the container created. The start does not go
# through docker_: a function in the background runs in a subshell, whose pid k6_pid would then be, and a signal to it
# would orphan the client; env execs docker, so $! is the client's pid.
k6_created=1
docker_ create --rm --name "$k6_name" --network svp_web --user "$(id -u):$(id -g)" -p "127.0.0.1:$k6_port:6565" \
  -e K6_NO_USAGE_REPORT=true -e K6_AUTO_EXTENSION_RESOLUTION=false \
  -v "$repo_root/deploy/k6:/scripts:ro" -v "$dir:/results" \
  "$K6_IMAGE" run --quiet --address 0.0.0.0:6565 \
  -e SVP_K6_PROFILE=local -e SVP_API_URL=http://gateway:8080 -e SVP_WEB_URL=http://web:3001 \
  -e SVP_WEB_ORIGIN=http://localhost:3001 -e SVP_K6_RESULTS=/results -e "SVP_K6_HOLD=$hold" \
  /scripts/main.js >/dev/null 2>"$dir/k6.log" ||
  fail "container $k6_name created (docker create: $(tail -n 3 "$dir/k6.log" | tr '\n' ' '))"
env -u DOCKER_DEFAULT_PLATFORM docker start -a "$k6_name" >>"$dir/k6.log" 2>&1 &
k6_pid=$!
deadline=$((SECONDS + 240))
until k6_snapshot "$dir" start && [[ $(jq '[.data[] | select(.id == "iterations") | .attributes.sample.count] | add // 0' "$dir/k6-start.json") -gt 0 ]]; do
  end_if_requested "before T0 (k6 setup)"
  k6_running || fail "k6 is running (it stopped: $(tail -n 3 "$dir/k6.log" | tr '\n' ' '))"
  ((SECONDS < deadline)) || fail "k6 finished setup and started the load within 240 s"
  sleep 3
done
record "$dir" "$(now)" load-started "k6 REST API: first iterations"
ok "k6 profile local running (hold $hold); waiting $ramp_seconds s ramp + $steady_seconds s steady state"
deadline=$((SECONDS + ramp_seconds + steady_seconds))
while ((SECONDS < deadline)); do
  end_if_requested "before T0 (steady state)"
  k6_running || fail "k6 kept running through the steady state ($(tail -n 3 "$dir/k6.log" | tr '\n' ' '))"
  sleep 5
done
k6_snapshot "$dir" baseline || fail "k6's REST API answers"
failed=$(k6_failed_total "$dir/k6-baseline.json")
[[ $failed == 0 ]] || fail "steady state before the outage: the load got no 5xx or connection error (got $failed)"
names=$(active_pages) || fail "Alertmanager GET /api/v2/alerts answers"
[[ -z $names ]] || fail "no page alert active before T0 (active: $(tr '\n' ' ' <<<"$names"))"
record "$dir" "$(now)" steady "k6: 0 failed requests; Alertmanager: no page"
ok "steady state: the load got no failed request, no page alert active"
if [[ $telegram == on ]]; then tg_sent0=$(telegram_sent); fi
end_if_requested "before T0"

# 3. T0: the outage.
k6_snapshot "$dir" T0 || fail "k6's REST API answers at T0"
t0=$(now)
compose stop "$target" >/dev/null 2>&1 || fail "stop $target"
record "$dir" "$t0" T0 "compose stop $target"
ok "T0 $(clock "$t0"): $target stopped"

# 4. T1: the page. wait_alert_new asks Alertmanager once per poll here (no timeout of its own), so that an end
# requested while the page has not come, a detection failure included, is honoured within seconds.
alert_deadline=$((SECONDS + alert_timeout))
until wait_alert_new "$alert" page "$t0" 0; do
  end_if_requested "after T0, before T1"
  ((SECONDS < alert_deadline)) || break
  sleep 5
done
if [[ -n $alert_starts ]]; then
  t1=$alert_starts
  record "$dir" "$t1" T1 "Alertmanager startsAt of $alert (page) $(jq -c --argjson t "$t1" '[.[] | select(.starts == $t) | .labels.target] | first' "$work/alerts.json")"
  ok "T1 $(clock "$t1"): $alert (page) startsAt, T1 - T0 = $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.0f", b - a }') s"
else
  t1=
  record "$dir" "$(now)" T1-missed "no new $alert (page) in Alertmanager within $alert_timeout s of T0"
  echo "FAIL  no new $alert (page) in Alertmanager within $alert_timeout s of T0: a detection failure, kept in the timeline; the session goes on" >&2
fi

cat <<EOF

On-call: handle it with $runbook and the dashboards it names; nothing else.
  alert      $alertmanager_url/#/alerts?filter=%7Balertname%3D%22$alert%22%7D
  marks      make gameday-mark M=diagnosed | M=mitigated | M=recovered   (another terminal)
  end        make gameday-end, or Ctrl-C here: the stack is put back either way

EOF

# 5. Wait for the on-call, noting what can be seen without them.
shown=$(wc -l <"$dir/timeline.tsv")
seen_open=
while :; do
  end_if_requested "while waiting for the on-call"
  if [[ -z $(event_time "$dir" auto:service-running) && -n $(compose ps --status running -q "$target" 2>/dev/null) ]]; then
    record "$dir" "$(now)" auto:service-running "compose ps: $target running"
  fi
  v=$(prom_scalar "max(svp_breaker_state{service_name=\"gateway\",target=\"$target\"})")
  if [[ -n $v ]] && awk -v v="$v" 'BEGIN { exit !(v > 0) }'; then seen_open=1; fi
  if [[ -n $seen_open && $v == 0 && -z $(event_time "$dir" auto:breaker-closed) ]]; then
    record "$dir" "$(now)" auto:breaker-closed "Prometheus: max svp_breaker_state{target=\"$target\"} = 0"
  fi
  if [[ -n $t1 && -z $(event_time "$dir" auto:alert-resolved) ]] && names=$(active_pages) && ! grep -qx "$alert" <<<"$names"; then
    record "$dir" "$(now)" auto:alert-resolved "Alertmanager: no active $alert"
  fi
  if [[ -z $(event_time "$dir" k6-ended) ]] && ! k6_running; then
    record "$dir" "$(now)" k6-ended "k6 finished its hold of $hold (or stopped)"
  fi
  if (($(wc -l <"$dir/timeline.tsv") > shown)); then
    tail -n +$((shown + 1)) "$dir/timeline.tsv" | awk -F '\t' '{ printf "note  %s %s (%s)\n", substr($2, 12), $3, $4 }'
    shown=$(wc -l <"$dir/timeline.tsv")
  fi
  sleep 5
done
