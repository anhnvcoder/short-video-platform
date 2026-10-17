#!/usr/bin/env bash
# Drill: the stage 3 rows of the threat model (docs/threat-model.md, section 5) on the stack of
# `make up OBS=lgtm` (docs/adr/0011-observability-stage3.md, sections 1 and 4 to 9). Each item prints
# ok or FAIL lines; an item that fails does not stop the next ones (the stack is restored first),
# and the script exits non-zero when any failed:
#   JWT-8  a fresh user with a random email and password registers, logs in (access token), reads
#          GET /feed/explore with the token (200) and logs in with another random password (401);
#          with user-service stopped it logs in again and, with the token, follows a random user
#          id: each 503, or 504 when the gateway's connection still waits on the stopped
#          container's address, with a trace_id in the problem body; user-service starts again.
#          The traces of these requests (Tempo), every log line of every service meanwhile (Loki)
#          and the GlitchTip events of both 5xx hold neither the email, either password nor the
#          access token, nor an Authorization header or a Bearer value (plain string search in the
#          downloaded JSON);
#   UP-8   POST /videos, upload and complete: video-service logs "video created" and "upload
#          completed" with user_id, video_id and trace_id (Loki), and the gateway's access log line
#          of each trace_id has the same user_id (the gateway logs no video_id: trace_id joins them);
#   OPS-1  GET /debug/pprof/, /debug/pprof/heap and /metrics through the gateway are 404; the
#          project publishes exactly 127.0.0.1 ports 8080 (gateway), 9000 and 9001 (minio), 19092
#          (redpanda), 3000 (lgtm: Grafana), 8000 (glitchtip) and 9093 (alertmanager), each to the
#          same container port (every binding on the loopback), so the Collector, Prometheus,
#          Tempo, Loki and Pyroscope publish nothing;
#   RL-2   the gateway recreated with REDIS_URL on an unresolvable .invalid host (as in
#          drill-rate-limit; the native Redis is never stopped): after three logins Prometheus has
#          svp_ratelimit_decisions_total{store="fallback"} > 0 for the new gateway instance, and
#          Alertmanager a new RateLimitFallbackActive alert within 4 minutes of the first login;
#          the gateway is recreated with its default settings.
# On exit (passed or not) every stack service runs again with its default settings. Reads no
# database; reads from .env only the GlitchTip variables, never printing a value. Registers two
# users.
#
# Usage (from the repo root, stack up with OBS=lgtm): make drill-obs-threats
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# The Redis-down setting of drill-rate-limit: .invalid never resolves (RFC 2606).
redis_down_url=redis://redis-down.invalid:6379/10
fallback_alert_timeout=240
jwt8_5xx='http_server_request_duration_seconds_count{service_name="gateway",http_route=~"/auth/login|/me/following/.+",http_response_status_code=~"5.."}'
jwt8_traces='{ resource.service.name = "gateway" && span:kind = server && (span.http.route = "/auth/register" || span.http.route = "/auth/login" || span.http.route = "/feed/explore" || span.http.route = "/me/following/{user_id}") }'
# Every port the project publishes with OBS=lgtm, as "SERVICE HOST_IP:PORT->CONTAINER_PORT", sorted.
expected_publishers="alertmanager 127.0.0.1:9093->9093
gateway 127.0.0.1:8080->8080
glitchtip 127.0.0.1:8000->8000
lgtm 127.0.0.1:3000->3000
minio 127.0.0.1:9000->9000
minio 127.0.0.1:9001->9001
redpanda 127.0.0.1:19092->19092"

# wrong_cred FILE: writes a new, never registered email and a random password to FILE.
wrong_cred() {
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "drill-obs-$(date +%s)-$(openssl rand -hex 4)@example.test" \
    '{email: $e, password: env.DRILL_PASSWORD}' >"$1"
}

# leaks FILE: names what FILE holds of the JWT-8 user's email (any case), password, the wrong
# password, access token or its signature, an Authorization header name or a Bearer value; ""
# when none. awk reads the values from its environment, never from its command line.
leaks() {
  JWT8_EMAIL=$email JWT8_PASSWORD=$password JWT8_WRONG_PASSWORD=$wrong_password JWT8_TOKEN=$token \
    JWT8_SIGNATURE=${token##*.} awk '
    { s = s $0 "\n" }
    END {
      l = tolower(s)
      if (index(l, tolower(ENVIRON["JWT8_EMAIL"]))) out = out " email"
      if (index(s, ENVIRON["JWT8_PASSWORD"])) out = out " password"
      if (index(s, ENVIRON["JWT8_WRONG_PASSWORD"])) out = out " wrong-password"
      if (index(s, ENVIRON["JWT8_TOKEN"])) out = out " access-token"
      if (index(s, ENVIRON["JWT8_SIGNATURE"])) out = out " token-signature"
      if (index(l, "authorization")) out = out " authorization"
      if (index(l, "bearer ")) out = out " bearer"
      print substr(out, 2)
    }' "$1"
}

jwt8() {
  local start end status login_status follow_status t_login t_follow t n i id deadline found what events=
  # The events of the two 5xx must not be held back by the tracker's limit of one event per
  # fingerprint (here: gateway, "grpc call failed" and the login or follow route) per 30 s.
  wait_quiet_5xx "$jwt8_5xx" 31 180
  start=$(now)
  new_user j
  email=$(jq -r '.email' "$work/j.cred")
  password=$(jq -r '.password' "$work/j.cred")
  token=$(sed -n 's/^Authorization: Bearer //p' "$work/j.auth")
  [[ -n $email && -n $password && $token == *.*.* ]] || fail "JWT-8: the user's email, password and access token are known"

  status=$(request GET "/feed/explore?page_size=1" "$work/j.auth")
  [[ $status == 200 ]] || fail "JWT-8: GET /feed/explore with the access token is 200 (status $status, $(problem_summary))"
  WRONG_PASSWORD=$(openssl rand -hex 16) jq '.password = env.WRONG_PASSWORD' "$work/j.cred" >"$work/j-wrong.cred"
  wrong_password=$(jq -r '.password' "$work/j-wrong.cred")
  [[ -n $wrong_password && $wrong_password != "$password" ]] || fail "JWT-8: the wrong password is known and not the user's"
  status=$(request POST /auth/login "" "$work/j-wrong.cred")
  [[ $status == 401 ]] || fail "JWT-8: login with a wrong password is 401 (status $status, $(problem_summary))"
  ok "JWT-8: registered, logged in (access token), GET /feed/explore with the token (200), login with a wrong password (401)"

  compose stop user-service >/dev/null 2>&1 || fail "stop user-service"
  login_status=$(request POST /auth/login "" "$work/j.cred")
  t_login=$(field trace_id)
  follow_status=$(request PUT "/me/following/$(openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})/\1-\2-\3-\4-/')" "$work/j.auth")
  t_follow=$(field trace_id)
  : >"$work/body"
  start_service user-service
  wait_gateway_ready 60
  [[ ($login_status == 503 || $login_status == 504) && $t_login =~ ^[0-9a-f]{32}$ ]] ||
    fail "JWT-8: login with user-service stopped is 503 or 504 with a trace_id (status $login_status, trace_id '$t_login')"
  [[ ($follow_status == 503 || $follow_status == 504) && $t_follow =~ ^[0-9a-f]{32}$ ]] ||
    fail "JWT-8: follow with the access token and user-service stopped is 503 or 504 with a trace_id (status $follow_status, trace_id '$t_follow')"
  end=$(now)
  ok "JWT-8: with user-service stopped, login $login_status (trace_id $t_login) and follow with the access token $follow_status (trace_id $t_follow); user-service running again"

  # Tempo: the register, the three logins, the feed read and the follow, both 5xx among them.
  deadline=$((SECONDS + 90))
  while :; do
    tempo_search "$jwt8_traces" "$start" "$end"
    n=$(wc -l <"$work/tempo-traces" | tr -d ' ')
    ((n >= 6)) && grep -q " $t_login\$" "$work/tempo-traces" && grep -q " $t_follow\$" "$work/tempo-traces" && break
    ((SECONDS < deadline)) ||
      fail "JWT-8: Tempo has the 6 traces of the register, logins, feed read and follow, both 5xx among them, within 90 s (found $n)"
    sleep 3
  done
  : >"$work/jwt8-traces.json"
  i=0
  while read -r _ id; do
    i=$((i + 1))
    deadline=$((SECONDS + 30))
    until [[ $(tempo_trace "$id" "$work/trace.json") == 200 ]]; do
      ((SECONDS < deadline)) || fail "JWT-8: Tempo GET trace $id is 200 within 30 s"
      sleep 2
    done
    cat "$work/trace.json" >>"$work/jwt8-traces.json"
  done <"$work/tempo-traces"

  # Loki: every line of every service from the register to now, once the gateway's lines of both
  # 5xx are in.
  deadline=$((SECONDS + 60))
  while :; do
    loki_query '{service_name=~".+"}' "$((${start%.*} - 1))" "$(now)"
    found=$(jq --arg a "$t_login" --arg b "$t_follow" \
      'any(.[]; .service_name == "gateway" and .trace_id == $a) and any(.[]; .service_name == "gateway" and .trace_id == $b)' \
      "$work/loki.json")
    [[ $found == true ]] && break
    ((SECONDS < deadline)) || fail "JWT-8: Loki has the gateway's log lines of traces $t_login and $t_follow within 60 s"
    sleep 3
  done
  cp "$work/loki.json" "$work/jwt8-logs.json"

  # GlitchTip: the events of both 5xx, one per fingerprint.
  : >"$work/jwt8-events.json"
  for t in "$t_login" "$t_follow"; do
    deadline=$((SECONDS + 120))
    while :; do
      sentry_find_event "$t"
      [[ -n $sentry_event ]] && break
      ((SECONDS < deadline)) || fail "JWT-8: GlitchTip has the event of the 5xx with trace_id $t within 120 s"
      sleep 5
    done
    sentry_event_json "$sentry_event" "$work/event.json"
    cat "$work/event.json" >>"$work/jwt8-events.json"
    events+=" $sentry_event (issue $sentry_issue)"
  done

  what=$(leaks "$work/jwt8-traces.json")
  [[ -z $what ]] || fail "JWT-8: the traces of the register, logins, feed read and follow hold no secret (found: $what)"
  ok "JWT-8: $i traces ($(jq -s '[.[] | (.batches // .resourceSpans)[] | (.scopeSpans // .instrumentationLibrarySpans)[]?.spans[]?] | length' "$work/jwt8-traces.json") spans): no email, password, access token, Authorization or Bearer"
  what=$(leaks "$work/jwt8-logs.json")
  [[ -z $what ]] || fail "JWT-8: the log lines of every service meanwhile hold no secret (found: $what)"
  ok "JWT-8: $(jq length "$work/jwt8-logs.json") log lines of $(jq -r '[.[].service_name] | unique | join(", ")' "$work/jwt8-logs.json"): no email, password, access token, Authorization or Bearer"
  what=$(leaks "$work/jwt8-events.json")
  [[ -z $what ]] || fail "JWT-8: the GlitchTip events of the login and follow 5xx hold no secret (found: $what)"
  ok "JWT-8: GlitchTip events of the login $login_status and the follow $follow_status:$events: no email, password, access token, Authorization or Bearer"
}

# up8_gateway_line TRACE_ID ROUTE: the gateway's access log line of TRACE_ID is for ROUTE and has
# the user's user_id.
up8_gateway_line() {
  local deadline=$((SECONDS + 60)) got
  while :; do
    loki_query "{service_name=\"gateway\"} | trace_id=\"$1\"" "$((${start%.*} - 1))" "$(now)"
    got=$(jq -c 'first(.[] | select(.line == "http request")) | {route, status, user_id}' "$work/loki.json")
    [[ -n $got ]] && break
    ((SECONDS < deadline)) || fail "UP-8: Loki has the gateway's access log line of trace $1 within 60 s"
    sleep 3
  done
  [[ $(jq -r --arg r "$2" --arg u "$u_id" '.route == $r and .user_id == $u' <<<"$got") == true ]] ||
    fail "UP-8: the gateway's access log line of trace $1 is $2 with user_id $u_id (got $got)"
}

up8() {
  local deadline created completed
  start=$(now)
  new_user u
  make_video "$work/up8.mp4" 2 320x240
  upload_video up8 "$work/u.auth" "$work/up8.mp4"
  ok "UP-8: user $u_id created, uploaded and completed video $up8_id"

  deadline=$((SECONDS + 60))
  while :; do
    loki_query "{service_name=\"video-service\"} | video_id=\"$up8_id\"" "$((${start%.*} - 1))" "$(now)"
    created=$(jq -c 'first(.[] | select(.line == "video created")) | {user_id, video_id, trace_id}' "$work/loki.json")
    completed=$(jq -c 'first(.[] | select(.line == "upload completed")) | {user_id, video_id, trace_id}' "$work/loki.json")
    [[ -n $created && -n $completed ]] && break
    ((SECONDS < deadline)) ||
      fail "UP-8: Loki has video-service's \"video created\" and \"upload completed\" lines of video $up8_id within 60 s"
    sleep 3
  done
  for line in "$created" "$completed"; do
    [[ $(jq -r --arg u "$u_id" --arg v "$up8_id" '.user_id == $u and .video_id == $v and (.trace_id // "" | test("^[0-9a-f]{32}$"))' <<<"$line") == true ]] ||
      fail "UP-8: video-service's log line carries user_id $u_id, video_id $up8_id and a trace_id (got $line)"
  done
  ok "UP-8: video-service logged \"video created\" (trace $(jq -r .trace_id <<<"$created")) and \"upload completed\" (trace $(jq -r .trace_id <<<"$completed")) with user_id, video_id, trace_id"

  up8_gateway_line "$(jq -r .trace_id <<<"$created")" "POST /videos"
  up8_gateway_line "$(jq -r .trace_id <<<"$completed")" "POST /videos/{video_id}/complete"
  ok "UP-8: the gateway's access log lines of both traces (POST /videos, POST /videos/{video_id}/complete) have user_id $u_id"
}

ops1() {
  local p status bad
  for p in /debug/pprof/ /debug/pprof/heap /metrics; do
    status=$(request GET "$p")
    [[ $status == 404 ]] || fail "OPS-1: GET $p through the gateway is 404 (status $status)"
  done
  ok "OPS-1: GET /debug/pprof/, /debug/pprof/heap and /metrics through the gateway: 404"

  compose ps --format json >"$work/ps.json" || fail "OPS-1: compose ps"
  jq -rn '[inputs | if type == "array" then .[] else . end] | .[] | .Service as $s
    | .Publishers[]? | select(.PublishedPort != 0) | "\($s) \(.URL):\(.PublishedPort)->\(.TargetPort)"' "$work/ps.json" |
    LC_ALL=C sort -u >"$work/published"
  bad=$(awk '$2 !~ /^127\.0\.0\.1:/' "$work/published" | tr '\n' ' ')
  [[ -z $bad ]] || fail "OPS-1: every published port binds 127.0.0.1 (not: $bad)"
  [[ $(<"$work/published") == "$expected_publishers" ]] ||
    fail "OPS-1: the project publishes exactly $(tr '\n' ' ' <<<"$expected_publishers")(got: $(tr '\n' ' ' <"$work/published"))"
  ok "OPS-1: published ports, all on 127.0.0.1, each to the same port of its service: $(tr '\n' ' ' <"$work/published")"
  ok "OPS-1: otelcol (4317), and in lgtm Prometheus (9090), Tempo (3200), Loki (3100) and Pyroscope (4040), publish nothing"
}

# gateway_instances: the service_instance_id of every gateway Prometheus holds a recent sample of,
# sorted, one per line.
gateway_instances() {
  prom_query 'group by (service_instance_id) (go_goroutine_count{service_name="gateway"})'
  jq -r '.data.result[].metric.service_instance_id' "$work/prom.json" | sort
}

rl2() {
  local before instance first first_s deadline status i alert_seen
  # A fallback alert from an earlier run must be gone, so the one checked below is this run's.
  wait_alert_gone RateLimitFallbackActive page 300
  gateway_instances >"$work/instances-before"
  recreate_service gateway SVP_GATEWAY_REDIS_URL="$redis_down_url"
  wait_gateway_ready 60
  ok "RL-2: gateway recreated with REDIS_URL=$redis_down_url"

  first=$(now)
  first_s=$SECONDS
  wrong_cred "$work/rl2.cred"
  for i in 1 2 3; do
    status=$(request POST /auth/login "" "$work/rl2.cred")
    [[ $status == 401 ]] || fail "RL-2: wrong login $i with Redis down is 401 (status $status, $(problem_summary))"
  done
  ok "RL-2: 3 wrong logins with Redis down: 401 each"

  deadline=$((SECONDS + 90))
  while :; do
    instance=$(gateway_instances | comm -13 "$work/instances-before" - | head -n 1)
    if [[ -n $instance ]]; then
      prom_query "sum(svp_ratelimit_decisions_total{service_name=\"gateway\",store=\"fallback\",service_instance_id=\"$instance\"})"
      awk -v v="$prom_value" 'BEGIN { exit !(v + 0 > 0) }' && break
    fi
    ((SECONDS < deadline)) ||
      fail "RL-2: Prometheus has svp_ratelimit_decisions_total{store=\"fallback\"} > 0 for the new gateway within 90 s (instance '${instance}', value '${prom_value:-}')"
    sleep 5
  done
  ok "RL-2: svp_ratelimit_decisions_total{store=\"fallback\"} = $prom_value for the new gateway instance $instance ($(awk -v a="$first" -v b="$(now)" 'BEGIN { printf "%.0f", b - a }') s after the first login)"

  # The limit counts from the first login, the wait for the counter above included.
  wait_alert_new RateLimitFallbackActive page "$first" "$((fallback_alert_timeout - (SECONDS - first_s)))" ||
    fail "RL-2: a new RateLimitFallbackActive (page) alert in Alertmanager within $fallback_alert_timeout s of the first login"
  alert_seen=$(now)
  awk -v a="$first" -v s="$alert_starts" -v b="$alert_seen" -v m="$fallback_alert_timeout" 'BEGIN { exit !(s - a <= m && b - a <= m) }' ||
    fail "RL-2: RateLimitFallbackActive (page) starts and is seen in Alertmanager within $fallback_alert_timeout s of the first login (startsAt $(awk -v a="$first" -v b="$alert_starts" 'BEGIN { printf "%.0f", b - a }') s, seen $(awk -v a="$first" -v b="$alert_seen" 'BEGIN { printf "%.0f", b - a }') s after it)"
  ok "RL-2: RateLimitFallbackActive active in Alertmanager: startsAt $(awk -v a="$first" -v b="$alert_starts" 'BEGIN { printf "%.0f", b - a }') s, seen $(awk -v a="$first" -v b="$alert_seen" 'BEGIN { printf "%.0f", b - a }') s after the first login (limit $fallback_alert_timeout s)"

  recreate_service gateway
  wait_gateway_ready 60
  wrong_cred "$work/rl2.cred"
  status=$(request POST /auth/login "" "$work/rl2.cred")
  [[ $status == 401 ]] || fail "RL-2: with the default settings a wrong login is 401 (status $status, $(problem_summary))"
  ok "RL-2: gateway recreated with its default REDIS_URL; a wrong login is 401"
}

obs_preflight
wait_gateway_ready 60

failed=
# run_item NAME FUNCTION: runs FUNCTION in a subshell, where a fail ends the item only; after a
# failure the stack is restored (the item may have stopped or recreated a service) before the
# next item.
run_item() {
  local rc
  set +e
  (
    set -e
    "$2"
  )
  rc=$?
  set -e
  if ((rc != 0)); then
    failed+=" $1"
    restore_stack || true
  fi
}

run_item JWT-8 jwt8
run_item UP-8 up8
run_item OPS-1 ops1
run_item RL-2 rl2

if [[ -n $failed ]]; then
  echo "FAIL  drill-obs-threats:$failed" >&2
  exit 1
fi
echo "drill-obs-threats: all checks passed"
