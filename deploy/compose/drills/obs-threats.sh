#!/usr/bin/env bash
# Drill: the stage 3 rows of the threat model (docs/threat-model.md, section 5) on the stack of
# `make up OBS=lgtm`. Each item prints
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
#          project publishes exactly 127.0.0.1 ports 8080 (gateway), 3001 (web), 9000 (s3, the
#          object store's S3 API), 19092 (redpanda), 3000 (lgtm: Grafana), 8000 (glitchtip) and 9093
#          (alertmanager), each to the same container port (every binding on the loopback), so the
#          Collector, Prometheus, Tempo, Loki and Pyroscope publish nothing;
#   RL-2   the gateway recreated with REDIS_URL on an unresolvable .invalid host (as in
#          drill-rate-limit; the native Redis is never stopped): after three logins Prometheus has
#          svp_ratelimit_decisions_total{store="fallback"} > 0 for the new gateway instance, and
#          Alertmanager a new RateLimitFallbackActive alert within 4 minutes of the first login;
#          the gateway is recreated with its default settings;
#   WEB-9  through the web client at http://localhost:3001 (threat model 4.9), as a browser
#          without JavaScript would: GET /login?next=<a random marker in the query>, register and
#          log in through the /register and /login forms (their Server Actions; the session
#          cookie svp_sid stays in a private cookie jar), log out and in again, the feed (/ and
#          /api/feed/explore), an upload (POST /api/videos, the presigned form, POST
#          /api/videos/{id}/complete), web-vitals beacons to /rum (one valid, two whose path
#          holds the email or the ?next= query: dropped), and one error report to /monitoring
#          whose message and stack carry the email, the session's access and refresh tokens,
#          the sid, the ?next= URL and the presigned form's signature and policy in a URL query
#          (the redaction rules must take them out). Then no GlitchTip event of tag service=web
#          received since, no trace of service.name=web (Tempo), no log line of any service
#          meanwhile (Loki; the web client logs to stdout only) and no Prometheus series of
#          service_name=web or of svp_web_vital_* holds the email (any case), the password,
#          the access or refresh token (read from the session in Redis db 9, never printed),
#          the sid, the ?next= marker, the form's policy or signature, the names upload_url,
#          form_fields or X-Amz-Signature, or a string shaped like a JWT. Controls: the error
#          report's event is in GlitchTip, Tempo has a trace of service web, Prometheus a
#          series svp_web_vital_lcp_seconds_count{route="/"}, Loki the "upload completed" line
#          of the video (so "not found" is not "no data"). The session is logged out at the end.
# On exit (passed or not) every stack service runs again with its default settings. Reads no
# database but the web client's session store in Redis db 9 (GET of the drill user's own
# session); reads from .env only the GlitchTip variables, never printing a value. Registers three
# users (two at the gateway, one through the web client). LOCAL LAB ONLY: sourcing
# deploy/compose/lib.sh deletes the gateway's register rate limit keys in Redis db 10.
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
redpanda 127.0.0.1:19092->19092
s3 127.0.0.1:9000->9000
web 127.0.0.1:3001->3001"

# control MESSAGE: an ok line for a control check (the data the search runs on is there, so finding none of the
# values is not finding no data).
control() { ok "control: $1"; }

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

# The web client of compose, as the browser opens it (localhost: its APP_ORIGIN, which the CSRF check and Next's own
# Server Action check compare with).
web_base=http://localhost:3001
web_cookie=svp_sid
web_same_origin=(-H "Sec-Fetch-Site: same-origin" -H "Origin: $web_base")
web9_traces='{ resource.service.name = "web" }'

# web_get PATH OUT [CURL_ARGS...] / web_post PATH OUT [CURL_ARGS...]: a request to the web client with the drill user's
# session (the private cookie jar $work/web.jar, kept up to date); the body goes to OUT and the HTTP status is printed
# (000 when nothing answered). Accept-Language en: the form errors the drill reads are the English copy. Redirects are
# not followed.
web_get() { web_curl GET "$@"; }
web_post() { web_curl POST "$@"; }
web_curl() {
  local method=$1 path=$2 out=$3
  shift 3
  : >"$out"
  touch "$work/web.jar"
  curl -sS --max-time 15 -X "$method" -o "$out" -w '%{http_code}' -b "$work/web.jar" -c "$work/web.jar" \
    -H 'Accept-Language: en' "$@" "$web_base$path" || true
}

# web_sid: the session id in the cookie jar, "" when there is none. Never printed.
web_sid() {
  [[ -f $work/web.jar ]] || return 0
  awk -F '\t' -v n="$web_cookie" '$6 == n { v = $7 } END { print v }' "$work/web.jar"
}

# form_fields HTML_FILE: the hidden inputs of the form that has a password field in HTML_FILE, as curl config lines
# (form-string = "NAME=VALUE", HTML entities decoded); fails when there is none. A form whose action is a Server Action
# carries the action's id and bound state in such inputs ($ACTION_...), which is how a browser without JavaScript posts
# it: a multipart POST of those fields and the user's, to the page's own URL.
form_fields() {
  perl -0777 -ne '
    my $form;
    while (/(<form\b.*?<\/form>)/sg) { my $f = $1; if ($f =~ /name="password"/) { $form = $f; last } }
    defined $form or exit 1;
    my $n = 0;
    while ($form =~ /<input\b([^>]*)>/sg) {
      my $a = $1;
      next unless $a =~ /\btype="hidden"/;
      my ($name) = $a =~ /\bname="([^"]*)"/ or next;
      my ($value) = $a =~ /\bvalue="([^"]*)"/;
      $value = "" unless defined $value;
      for ($name, $value) {
        s/&quot;/"/g; s/&#x27;|&#39;/\x27/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/&/g;
        s/\\/\\\\/g; s/"/\\"/g;
      }
      print "form-string = \"$name=$value\"\n";
      $n++;
    }
    exit($n ? 0 : 1);
  ' "$1"
}

# web_form PAGE FIELDS_FILE: reads PAGE with the session of the cookie jar and posts its form as a browser without
# JavaScript does, with the fields of FIELDS_FILE (a JSON object; the values reach curl in a private config file, never
# on a command line) and the app's own origin; the answer goes to $work/form.out and form_status is set to the HTTP
# status: 303 when the action redirects (signed in), 200 when the form comes back with an error. Sets a variable
# instead of printing, like key_records: a fail inside $(...) would only end the subshell.
web_form() {
  local status
  status=$(web_get "$1" "$work/form.html")
  [[ $status == 200 ]] || fail "GET $1 of the web client is 200 (status $status)"
  {
    echo "url = \"$web_base$1\""
    echo 'header = "Accept-Language: en"'
    form_fields "$work/form.html" || fail "the form of $1 has hidden Server Action fields"
    jq -r 'to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"' "$2"
  } >"$work/form.curl"
  : >"$work/form.out"
  form_status=$(curl -sS --max-time 15 -o "$work/form.out" -w '%{http_code}' -b "$work/web.jar" -c "$work/web.jar" \
    -K "$work/form.curl" "${web_same_origin[@]}" || true)
}

# holds VALUES_FILE FILE: the names of the values of VALUES_FILE ("NAME<TAB>VALUE[<TAB>i]" lines; i: any case) that
# FILE holds, space-separated, and "jwt" when FILE holds a string shaped like a JWT (eyJ and three dot-separated
# base64url parts); "" when none. awk reads the values from the file, never from its command line.
holds() {
  awk -F '\t' 'NR == FNR { n++; name[n] = $1; val[n] = $2; ci[n] = ($3 == "i"); next }
    { s = s $0 "\n" }
    END {
      l = tolower(s)
      for (i = 1; i <= n; i++) {
        if (val[i] == "") continue
        if (ci[i] ? index(l, tolower(val[i])) : index(s, val[i])) out = out " " name[i]
      }
      if (match(s, /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/)) out = out " jwt"
      print substr(out, 2)
    }' "$1" "$2"
}

# web9_logout: the EXIT trap of the WEB-9 item (run_item runs it in a subshell): logs the web session out, so it does
# not stay in Redis db 9 for its 30 days.
web9_logout() {
  [[ -n $(web_sid) ]] || return 0
  [[ $(web_post /logout "$work/web9-logout" "${web_same_origin[@]}") == 303 ]] &&
    ok "WEB-9: the web session logged out" || echo "info  WEB-9: the logout did not answer 303: the session ends with its TTL"
}

# web9_events SINCE: every GlitchTip event tagged service=web received at or after SINCE (seconds since the epoch), each
# whole, into $work/web9-events.json; sets web9_event_count.
web9_events() {
  local issue url page id
  : >"$work/web9-events.json"
  web9_event_count=0
  sentry_get "/api/0/projects/$sentry_org/$sentry_project/issues/?query=service%3Aweb" "$work/sentry-issues.json"
  [[ $sentry_status == 200 ]] || fail "WEB-9: GlitchTip issue search by tag service:web is 200 (status $sentry_status)"
  for issue in $(jq -r --argjson t "$1" "$jq_epoch"' .[] | select((.lastSeen | epoch) >= $t) | .id | select(test("^[0-9]+$"))' \
    "$work/sentry-issues.json"); do
    url="/api/0/issues/$issue/events/"
    for ((page = 0; page < 20; page++)); do
      sentry_get "$url" "$work/sentry-events.json"
      [[ $sentry_status == 200 ]] || fail "WEB-9: GlitchTip events of issue $issue is 200 (status $sentry_status)"
      for id in $(jq -r --argjson t "$1" "$jq_epoch"' .[] | select((.date_received | epoch) >= $t) | .event_id' \
        "$work/sentry-events.json"); do
        sentry_event_json "$id" "$work/event.json"
        cat "$work/event.json" >>"$work/web9-events.json"
        echo >>"$work/web9-events.json"
        web9_event_count=$((web9_event_count + 1))
      done
      url=$(sentry_next_page)
      [[ -n $url ]] || break
    done
  done
}

web9() {
  local start end status handle email next_marker report_marker id n i deadline what policy signature
  trap web9_logout EXIT
  start=$(now)
  next_marker=$(openssl rand -hex 8)
  report_marker=DrillWeb9$(openssl rand -hex 4)
  : >"$work/web.jar"

  # A page whose URL has a query: ?next= names where to go after login.
  status=$(web_get "/login?next=%2Fme%3Fd%3D$next_marker" "$work/web9.html")
  [[ $status == 200 ]] || fail "WEB-9: GET /login?next=... of the web client is 200 (status $status)"
  handle=drill_$(openssl rand -hex 6)
  email="drill-web9-$(date +%s)-$(openssl rand -hex 4)@example.test"
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" --arg h "$handle" \
    '{email: $e, password: env.DRILL_PASSWORD, handle: $h}' >"$work/web9.cred"
  web_form /register "$work/web9.cred"
  [[ $form_status == 303 && -n $(web_sid) ]] ||
    fail "WEB-9: register through the web client's /register form: 303 with cookie $web_cookie (status $form_status)"
  status=$(web_post /logout "$work/web9.html" "${web_same_origin[@]}")
  [[ $status == 303 && -z $(web_sid) ]] || fail "WEB-9: log out through the web client: 303 and the cookie cleared (status $status)"
  jq '{email, password}' "$work/web9.cred" >"$work/web9-login.cred"
  web_form /login "$work/web9-login.cred"
  [[ $form_status == 303 && -n $(web_sid) ]] ||
    fail "WEB-9: log in through the web client's /login form: 303 with cookie $web_cookie (status $form_status)"
  ok "WEB-9: user @$handle registered, logged out and logged in through the web client's forms (no JavaScript, Server Actions)"

  status=$(web_get / "$work/web9.html")
  [[ $status == 200 ]] || fail "WEB-9: GET / (the feed) through the web client with the session is 200 (status $status)"
  status=$(web_get "/api/feed/explore?page_size=5" "$work/web9.html")
  [[ $status == 200 ]] || fail "WEB-9: GET /api/feed/explore through the web client is 200 (status $status)"
  make_video "$work/web9.mp4" 2 320x240
  jq -n --arg t "drill web9 $(openssl rand -hex 4)" --argjson s "$(file_size "$work/web9.mp4")" \
    '{title: $t, size_bytes: $s, content_type: "video/mp4"}' >"$work/web9-video.json"
  # The answer holds the presigned form: it stays in $work/web9.upload for upload_file of deploy/compose/lib.sh.
  status=$(web_post /api/videos "$work/web9.upload" "${web_same_origin[@]}" -H 'Content-Type: application/json' \
    --data-binary "@$work/web9-video.json")
  id=$(jq -r '.video_id // ""' "$work/web9.upload" 2>/dev/null || true)
  [[ $status == 201 && -n $id ]] || fail "WEB-9: POST /api/videos through the web client is 201 with a video_id (status $status)"
  check_uuid "$id"
  status=$(upload_file web9 "$work/web9.mp4")
  [[ $status == 2?? ]] || fail "WEB-9: upload to the presigned form (status $status, code $(storage_error_code))"
  status=$(web_post "/api/videos/$id/complete" "$work/web9.html" "${web_same_origin[@]}")
  [[ $status == 202 ]] || fail "WEB-9: POST /api/videos/{id}/complete through the web client is 202 (status $status)"
  ok "WEB-9: through the web client: feed (/ and /api/feed/explore 200), video $id created, uploaded and completed"

  # The values no telemetry may hold; the tokens come from the session itself (Redis db 9, key svp:web:sess:<SHA-256
  # of the sid>), read into this private file only.
  redis-cli -h 127.0.0.1 -p 6379 -n 9 GET "svp:web:sess:$(web_sid | tr -d '\n' | shasum -a 256 | cut -c1-64)" \
    >"$work/web9.session" ||
    fail "WEB-9: read the drill user's web session in Redis db 9"
  policy=$(jq -r '[.form_fields | to_entries[] | select(.key | ascii_downcase == "policy") | .value][0] // ""' "$work/web9.upload")
  signature=$(jq -r '[.form_fields | to_entries[] | select(.key | ascii_downcase == "x-amz-signature") | .value][0] // ""' \
    "$work/web9.upload")
  {
    jq -r '"email\t\(.email)\ti", "password\t\(.password)"' "$work/web9.cred"
    WEB_SID=$(web_sid) jq -r '"access-token\t\(.access_token // "")", "refresh-token\t\(.refresh_token // "")", "sid\t\(env.WEB_SID)"' \
      "$work/web9.session" 2>/dev/null || true
    printf 'next-query\t%s\nupload-policy\t%s\nupload-signature\t%s\n' "$next_marker" "$policy" "$signature"
    printf 'upload_url\tupload_url\ti\nform_fields\tform_fields\ti\nX-Amz-Signature\tx-amz-signature\ti\n'
  } >"$work/web9.values"
  rm -f "$work/web9.session"
  n=$(awk -F '\t' '$2 != ""' "$work/web9.values" | wc -l | tr -d ' ')
  ((n == 11)) || fail "WEB-9: the 11 values to search for are known (email, password, access and refresh token, sid, ?next= marker, form policy and signature, 3 names; got $n)"

  # RUM: one valid beacon, and two whose path is no page of the app (dropped whole, no series).
  for i in '"/"' "\"/u/$email\"" "\"/login?next=%2Fme%3Fd%3D$next_marker\""; do
    status=$(web_post /rum "$work/web9.html" "${web_same_origin[@]}" -H 'Content-Type: text/plain;charset=UTF-8' \
      --data-binary "{\"path\":$i,\"metrics\":[{\"name\":\"LCP\",\"value\":1234.5},{\"name\":\"CLS\",\"value\":0.02}]}")
    [[ $status == 204 ]] || fail "WEB-9: POST /rum with a beacon is 204 (status $status)"
  done
  # An error report carrying what the redaction rules must take out: the email, the tokens and the
  # sid in the message, the ?next= URL and the presigned form's signature and policy in a frame's URL query.
  awk -F '\t' 'BEGIN { split("access-token refresh-token sid upload-policy upload-signature email", k, " ") }
    { v[$1] = $2 } END { for (i = 1; i <= 6; i++) print v[k[i]] }' "$work/web9.values" | {
    read -r W9_ACCESS
    read -r W9_REFRESH
    read -r W9_SID
    read -r W9_POLICY
    read -r W9_SIGNATURE
    read -r W9_EMAIL
    W9_ACCESS=$W9_ACCESS W9_REFRESH=$W9_REFRESH W9_SID=$W9_SID W9_POLICY=$W9_POLICY W9_SIGNATURE=$W9_SIGNATURE \
      W9_EMAIL=$W9_EMAIL jq -n --arg name "$report_marker" --arg web "$web_base" --arg next "$next_marker" '{
        name: $name,
        message: "drill report for \(env.W9_EMAIL) token \(env.W9_ACCESS) refresh \(env.W9_REFRESH) sid \(env.W9_SID) from \($web)/login?next=%2Fme%3Fd%3D\($next)",
        stack: "\($name): drill report\n    at report (\($web)/_next/static/chunks/drill.js?X-Amz-Signature=\(env.W9_SIGNATURE)&policy=\(env.W9_POLICY):1:1)",
        path: "/",
        debug_ids: {}
      }'
  } >"$work/web9-report.json"
  status=$(web_post /monitoring "$work/web9.html" "${web_same_origin[@]}" -H 'Content-Type: text/plain;charset=UTF-8' \
    --data-binary "@$work/web9-report.json")
  rm -f "$work/web9-report.json"
  [[ $status == 202 ]] || fail "WEB-9: POST /monitoring with an error report is 202 (status $status)"
  ok "WEB-9: 3 beacons to /rum (204 each) and an error report $report_marker to /monitoring (202)"

  # Controls: the web client's data is there, so finding none of the values is not finding no data.
  deadline=$((SECONDS + 120))
  while :; do
    web9_events "${start%.*}"
    grep -qF "$report_marker" "$work/web9-events.json" && break
    ((SECONDS < deadline)) || fail "WEB-9: GlitchTip has the event of error report $report_marker (tag service=web) within 120 s"
    sleep 5
  done
  control "GlitchTip has the event of error report $report_marker ($web9_event_count event(s) of service web since the drill's start)"
  end=$(now)
  deadline=$((SECONDS + 90))
  while :; do
    tempo_search "$web9_traces" "$start" "$end"
    n=$(wc -l <"$work/tempo-traces" | tr -d ' ')
    ((n >= 1)) && break
    ((SECONDS < deadline)) || fail "WEB-9: Tempo has a trace of service web within 90 s"
    sleep 3
  done
  : >"$work/web9-traces.json"
  while read -r _ i; do
    deadline=$((SECONDS + 30))
    until [[ $(tempo_trace "$i" "$work/trace.json") == 200 ]]; do
      ((SECONDS < deadline)) || fail "WEB-9: Tempo GET trace $i is 200 within 30 s"
      sleep 2
    done
    cat "$work/trace.json" >>"$work/web9-traces.json"
  done <"$work/tempo-traces"
  control "Tempo has $n trace(s) of service web since the drill's start ($(jq -s '[.[] | (.batches // .resourceSpans)[] | (.scopeSpans // .instrumentationLibrarySpans)[]?.spans[]?] | length' "$work/web9-traces.json") spans)"
  deadline=$((SECONDS + 90))
  while :; do
    prom_query 'count(svp_web_vital_lcp_seconds_count{route="/"})'
    awk -v v="$prom_value" 'BEGIN { exit !(v + 0 > 0) }' && break
    ((SECONDS < deadline)) || fail "WEB-9: Prometheus has a series svp_web_vital_lcp_seconds_count{route=\"/\"} within 90 s"
    sleep 5
  done
  status=$(obs_get "$proxy_url/prometheus/api/v1/series" "$work/web9-series.json" \
    --data-urlencode 'match[]={service_name="web"}' --data-urlencode 'match[]={__name__=~"svp_web_vital_.+"}' \
    --data-urlencode "start=${start%.*}" --data-urlencode "end=$(($(now | cut -d. -f1) + 1))")
  [[ $status == 200 && $(jq -r '.status' "$work/web9-series.json" 2>/dev/null) == success ]] ||
    fail "WEB-9: Prometheus series of service web through Grafana is 200 (status $status)"
  control "Prometheus has svp_web_vital_lcp_seconds_count{route=\"/\"}; $(jq '.data | length' "$work/web9-series.json") series of service_name=web or svp_web_vital_* since the drill's start"
  deadline=$((SECONDS + 60))
  while :; do
    loki_query '{service_name=~".+"}' "$((${start%.*} - 1))" "$(now)"
    [[ $(jq --arg v "$id" 'any(.[]; .service_name == "video-service" and .video_id == $v and .line == "upload completed")' \
      "$work/loki.json") == true ]] && break
    ((SECONDS < deadline)) || fail "WEB-9: Loki has video-service's \"upload completed\" line of video $id within 60 s"
    sleep 3
  done
  cp "$work/loki.json" "$work/web9-logs.json"
  control "Loki has video-service's \"upload completed\" line of the video uploaded through the web client; $(jq length "$work/web9-logs.json") lines of $(jq -r '[.[].service_name] | unique | join(", ")' "$work/web9-logs.json"), $(jq '[.[] | select(.service_name == "web")] | length' "$work/web9-logs.json") of web (it logs to stdout only)"

  what=$(holds "$work/web9.values" "$work/web9-events.json")
  [[ -z $what ]] || fail "WEB-9: the GlitchTip events of service web hold none of the values (found: $what)"
  ok "WEB-9: $web9_event_count GlitchTip event(s) of service web, the error report's included: no email, password, access or refresh token, sid, ?next= query, form policy or signature, upload_url, form_fields, X-Amz-Signature or JWT"
  what=$(holds "$work/web9.values" "$work/web9-traces.json")
  [[ -z $what ]] || fail "WEB-9: the traces of service web hold none of the values (found: $what)"
  ok "WEB-9: $n trace(s) of service web: none of the values"
  what=$(holds "$work/web9.values" "$work/web9-logs.json")
  [[ -z $what ]] || fail "WEB-9: the log lines of every service meanwhile hold none of the values (found: $what)"
  ok "WEB-9: $(jq length "$work/web9-logs.json") log lines of every service meanwhile: none of the values"
  what=$(holds "$work/web9.values" "$work/web9-series.json")
  [[ -z $what ]] || fail "WEB-9: the Prometheus series of service web and of the web vitals hold none of the values (found: $what)"
  ok "WEB-9: $(jq '.data | length' "$work/web9-series.json") Prometheus series of service web and of the web vitals: none of the values in any label"
  rm -f "$work/web9.values"
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
    # Said even after the item's own FAIL line: a command that stops the item under set -e (one not found, exit 127)
    # prints none, and where only the verdict lines of this output are kept (the CI runner's artifact), this line is
    # all that tells how the item ended.
    echo "FAIL  $1: the item ended with exit status $rc" >&2
    failed+=" $1"
    restore_stack || true
  fi
}

run_item JWT-8 jwt8
run_item UP-8 up8
run_item OPS-1 ops1
run_item RL-2 rl2
run_item WEB-9 web9

if [[ -n $failed ]]; then
  echo "FAIL  drill-obs-threats:$failed" >&2
  exit 1
fi
echo "drill-obs-threats: all checks passed"
