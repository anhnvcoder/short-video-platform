#!/usr/bin/env bash
# Drill traffic for the canaries on cluster svp, from this machine through Envoy:
# - the gateway's: about 10 requests/s (https://api.svp.localhost:8443) to GET /feed/explore and GET /feed/following,
#   the routes whose 5xx and latency AnalysisTemplate gateway-canary judges;
# - the web client's: about 4 requests/s (https://svp.localhost:8443), GET /login three times a second (a page that
#   needs no session and calls no gateway) and once a second one static asset (/_next/static/...) named in the HTML of
#   the latest /login, which AnalysisTemplate web-canary judges. An asset only the other build has answers 404 while a
#   canary runs: the 404s of route web-asset in the log count the asset requests that crossed builds.
# A canary needs at least 30 responses that are not 4xx a minute to be judged at all; at 25% this traffic brings the
# gateway's about 150 and the web client's about 45.
#
#   traffic.sh start    starts the traffic in the background (nohup), records its pid and log in .k8s/drills/traffic.pid
#                       and returns once every user is logged in and requests flow; refuses to start a second one
#   traffic.sh stop     stops the process of that pid (and only it: the command line must be this script's run mode),
#                       which stops its user loops, then prints the requests of its log by status
#   traffic.sh status   exit 0 and "PID LOG" while it runs, exit 1 otherwise
#   traffic.sh run LOG  the traffic itself, in the foreground (what start runs)
#
# Both feeds need a token and count in rate limit class read, 600 a minute with a burst of 200 per user
# (services/gateway/internal/ratelimit/ratelimit.go): four drill users take 2.5 requests/s each, alternating the two
# routes, so no user comes near its limit. Each user logs in again 5 minutes before its token expires (expires_at of
# the login; tokens last an hour, threat model JWT-3) and as soon as a request gets 401, at most once a minute (login is
# limited per email, 5 at once then 10 an hour), so the traffic runs for hours, through the push of a release.
#
# Every request is one line of the log .k8s/drills/traffic-<UTC start>.log:
#   <unix time of the request's start, ms> <user u1..u4, web for the web client's> <route explore|following|login, or
#   web-login|web-asset> <HTTP status, 000 when none> <time to the response, ms>
# and lines starting with # mark the start and stop. drill-k8s-canary and measure-canary read it; a window where more
# than 1% of the feed requests got 401 or 429 makes them report "inconclusive".
#
# Run through make (k8s-traffic-start, k8s-traffic-stop): SVP_STACK=k3d and CURL_CA_BUNDLE (the cluster's CA) come from
# there. Users are registered fresh at each start. LOCAL LAB ONLY: starting deletes the register rate limit keys in the
# cluster's Valkey db 10 (deploy/compose/lib.sh).
set -euo pipefail

cmd=${1:-}
base=${SVP_TRAFFIC_BASE:-https://api.svp.localhost:8443}
web_base=${SVP_TRAFFIC_WEB_BASE:-https://svp.localhost:8443}

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/../lib.sh"
drills="$repo_root/.k8s/drills"
pidfile="$drills/traffic.pid"

# Four users at one request every 400 ms each; the web client's loop one request every 250 ms.
users=4
interval_ms=400
web_interval_ms=250

# running: true when the process recorded in $pidfile runs this script's run mode; sets traffic_pid, traffic_log.
running() {
  traffic_pid= traffic_log=
  [ -s "$pidfile" ] || return 1
  read -r traffic_pid traffic_log <"$pidfile" || return 1
  [[ $traffic_pid =~ ^[0-9]+$ ]] || return 1
  case $(ps -p "$traffic_pid" -o command= 2>/dev/null) in
    *traffic.sh\ run\ *) return 0 ;;
    *) return 1 ;;
  esac
}

# summary LOG: the feed requests of LOG by status, the logins, and the web client's requests by route and status.
summary() {
  awk '!/^#/ && NF == 5 {
      if ($3 == "login") l[$4]++
      else if ($3 == "web-login") wl[$4]++
      else if ($3 == "web-asset") wa[$4]++
      else { n++; c[$4]++ }
    }
    END {
      printf "feed requests %d:", n; for (k in c) printf " %s=%d", k, c[k]; printf "\n"
      printf "logins:"; for (k in l) printf " %s=%d", k, l[k]; printf "\n"
      printf "web /login:"; for (k in wl) printf " %s=%d", k, wl[k]; printf "\n"
      printf "web assets:"; for (k in wa) printf " %s=%d", k, wa[k]; printf "\n"
    }' "$1"
}

case $cmd in
  status)
    if running; then
      echo "$traffic_pid $traffic_log"
      exit 0
    fi
    exit 1
    ;;

  stop)
    if ! running; then
      rm -f "$pidfile"
      ok "no drill traffic running"
      exit 0
    fi
    kill -TERM "$traffic_pid" || fail "stop drill traffic (pid $traffic_pid)"
    deadline=$((SECONDS + 20))
    while kill -0 "$traffic_pid" 2>/dev/null; do
      ((SECONDS < deadline)) || fail "drill traffic (pid $traffic_pid) still running 20s after SIGTERM"
      sleep 1
    done
    rm -f "$pidfile"
    ok "drill traffic stopped (pid $traffic_pid), log $traffic_log"
    summary "$traffic_log"
    exit 0
    ;;

  start)
    [[ ${SVP_STACK:-} == k3d ]] || fail "SVP_STACK=k3d is not set; start the traffic through make k8s-traffic-start"
    if running; then fail "drill traffic already running (pid $traffic_pid, log $traffic_log); make k8s-traffic-stop first"; fi
    mkdir -p "$drills"
    log="$drills/traffic-$(date -u +%Y%m%dT%H%M%SZ).log"
    : >"$log"
    # The worker's own messages (registration, a failure) go beside the log; it outlives this shell (nohup, no
    # terminal), so make's or install.sh's exit does not stop it.
    nohup "$0" run "$log" >"$log.out" 2>&1 </dev/null &
    pid=$!
    echo "$pid $log" >"$pidfile"
    deadline=$((SECONDS + 90))
    until grep -q '^# ready' "$log"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pidfile"
        cat "$log.out" >&2
        fail "drill traffic exited while starting (output above)"
      fi
      if ((SECONDS >= deadline)); then
        kill -TERM "$pid" 2>/dev/null || true
        rm -f "$pidfile"
        fail "drill traffic not flowing within 90s (see $log.out)"
      fi
      sleep 1
    done
    ok "drill traffic started (pid $pid): $users users, ~$((users * 1000 / interval_ms)) API requests/s, ~$((1000 / web_interval_ms)) web requests/s, log $log"
    exit 0
    ;;

  run) ;;

  *)
    echo "usage: traffic.sh start|stop|status|run LOG" >&2
    exit 2
    ;;
esac

# ---- run LOG: the traffic itself.
log=${2:?usage: traffic.sh run LOG}
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

# register_user N: a fresh drill user uN; its email and password stay in $work/uN.cred (mode 600, removed on exit).
register_user() {
  local u=$1 status
  TRAFFIC_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "traffic-$(date +%s)-$(openssl rand -hex 4)@example.test" \
    '{email: $e, password: env.TRAFFIC_PASSWORD}' >"$work/u$u.cred"
  status=$(curl -sS --max-time 10 -o "$work/u$u.body" -w '%{http_code}' -X POST "$base/auth/register" \
    -H 'Content-Type: application/json' --data-binary "@$work/u$u.cred" || true)
  [[ $status == 201 ]] || fail "register drill user u$u (status $status)"
}

# login N: logs uN in; writes its Authorization header to $work/uN.auth and sets exp_N to the token's expiry (unix
# seconds). Returns 1 when the login failed. The token goes from the body to the header file through jq only; the
# body is emptied at once.
login() {
  local u=$1 t0 out
  t0=$(now)
  out=$(curl -sS --max-time 10 -o "$work/u$u.body" -w '%{http_code} %{time_total}' -X POST "$base/auth/login" \
    -H 'Content-Type: application/json' --data-binary "@$work/u$u.cred" 2>/dev/null || true)
  record "$t0" "u$u" login "${out:-000 0}"
  if [[ ${out%% *} != 200 ]]; then
    : >"$work/u$u.body"
    return 1
  fi
  jq -r '"Authorization: Bearer " + .access_token' "$work/u$u.body" >"$work/u$u.auth"
  printf -v "exp_$u" '%s' "$(jq -r '.expires_at | sub("\\.[0-9]+"; "") | fromdateiso8601' "$work/u$u.body")"
  : >"$work/u$u.body"
}

# record START USER ROUTE "STATUS TIME_TOTAL": appends one line to the log and sets latency_ms. START comes from now
# (seconds with 3 decimals), curl's time_total is in seconds. One short write in append mode, so the lines of the four
# loops never interleave.
record() {
  local code=${4%% *} t=${4#* } frac
  frac="${t#*.}000"
  latency_ms=$((10#${t%%.*} * 1000 + 10#${frac:0:3}))
  printf '%s %s %s %s %d\n' "${1%.*}${1#*.}" "$2" "$3" "$code" "$latency_ms" >>"$log"
}

# user_loop N: requests of uN until stopped; a SIGTERM ends the loop and the request in flight with it. A login that
# fails (the gateway restarting, a rate limit) is tried again 15 s later, while the old token is used meanwhile.
user_loop() {
  local u=$1 i=0 t0 now_s out path exp_var="exp_$u" last_login got_401=0 next_try=0 pause_ms cpid=
  trap '[ -n "$cpid" ] && kill "$cpid" 2>/dev/null; exit 0' TERM
  last_login=$(date +%s)
  while :; do
    t0=$(now)
    now_s=${t0%.*}
    if ((now_s >= next_try)) && { ((now_s >= ${!exp_var} - 300)) || ((got_401 && now_s - last_login >= 60)); }; then
      if login "$u"; then
        last_login=$now_s got_401=0
      else
        next_try=$((now_s + 15))
      fi
      t0=$(now)
    fi
    if ((i % 2 == 0)); then path=explore; else path=following; fi
    i=$((i + 1))
    curl -sS --max-time 5 -o /dev/null -w '%{http_code} %{time_total}' -H "@$work/u$u.auth" \
      "$base/feed/$path" >"$work/u$u.out" 2>/dev/null &
    cpid=$!
    wait "$cpid" || true
    cpid=
    out=$(cat "$work/u$u.out")
    record "$t0" "u$u" "$path" "${out:-000 0}"
    if [[ ${out%% *} == 401 ]]; then got_401=1; fi
    # The next request starts about interval_ms after this one did (the loop's own work takes ~20 ms).
    pause_ms=$((interval_ms - latency_ms - 20))
    if ((pause_ms > 0)); then sleep "0.$(printf '%03d' "$pause_ms")"; fi
  done
}

# web_loop: the web client's requests until stopped, without a session: three GET /login, then one GET of the asset
# the latest /login named (a /login again while none is known), every web_interval_ms. The asset's query (?dpl=<build>)
# is left out: Next serves the file by its path alone.
web_loop() {
  local i=0 t0 out route url asset= pause_ms cpid=
  trap '[ -n "$cpid" ] && kill "$cpid" 2>/dev/null; exit 0' TERM
  while :; do
    t0=$(now)
    if ((i % 4 == 3)) && [ -n "$asset" ]; then
      route=web-asset url=$web_base$asset
    else
      route=web-login url=$web_base/login
    fi
    i=$((i + 1))
    curl -sS --max-time 5 -o "$work/web.body" -w '%{http_code} %{time_total}' "$url" >"$work/web.out" 2>/dev/null &
    cpid=$!
    wait "$cpid" || true
    cpid=
    out=$(cat "$work/web.out")
    record "$t0" web "$route" "${out:-000 0}"
    if [[ $route == web-login && ${out%% *} == 200 ]]; then
      asset=$(grep -oE '/_next/static/[A-Za-z0-9_./-]+\.js' "$work/web.body" | head -n 1 || true)
    fi
    pause_ms=$((web_interval_ms - latency_ms - 20))
    if ((pause_ms > 0)); then sleep "0.$(printf '%03d' "$pause_ms")"; fi
  done
}

loops=
stop_traffic() {
  trap - TERM INT
  # shellcheck disable=SC2086
  if [ -n "$loops" ]; then kill $loops 2>/dev/null || true; wait $loops 2>/dev/null || true; fi
  echo "# stop $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
  exit 0
}
trap stop_traffic TERM INT

echo "# start $(date -u +%Y-%m-%dT%H:%M:%SZ) base=$base users=$users interval_ms=$interval_ms web_base=$web_base web_interval_ms=$web_interval_ms" >>"$log"
for u in $(seq 1 "$users"); do register_user "$u"; done
for u in $(seq 1 "$users"); do
  login "$u" || fail "first login of drill user u$u"
done
# The loops start interval_ms/users apart, so the users' requests are spread over each interval rather than sent four
# at a time: in lockstep, one slow call behind the gateway (a cache miss of the explore page, a slow stats query)
# would make four responses slow at once and count four times in a canary's p99.
for u in $(seq 1 "$users"); do
  user_loop "$u" &
  loops="$loops $!"
  sleep "0.$(printf '%03d' $((interval_ms / users)))"
done
web_loop &
loops="$loops $!"
echo "# ready $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
wait
