#!/usr/bin/env bash
# Drill: the gateway's rate limits on the running stack (ADR-0010, sections 2, 5 and 7). With a
# fresh user A:
#   1. A's login left its login-email bucket in Redis db 10 (svp:gw:rl:login-email:<ip>:<hash>):
#      the limits run on the real Redis;
#   2. logins with a new, never registered email and a wrong password: 5 are 401, the 6th is 429
#      RATE_LIMITED with a Retry-After header (login-email, burst 5);
#   3. A calls POST /videos 4 times without uploading: 3 are 201, the 4th is 429
#      TOO_MANY_UPLOADS (UP-7, at most 3 open upload forms per user);
#   4. Redis unreachable: the gateway is recreated with REDIS_URL on an unresolvable .invalid host
#      (the native Redis is shared with another project and is never stopped): the feed is 200, a
#      like and an unlike 204 and a view 202 (those classes fail open), logins with another new
#      email are 429 after 3 x 401 (the in-memory fallback, half the limits), and the gateway logs
#      "rate limit store unavailable, using fallback";
#   5. the gateway is recreated with its default settings and writes to Redis again: one wrong
#      login with another new email leaves that email's login-email bucket (it lives 6 min, so the
#      check cannot miss it).
# Like, unlike and view go to the first video of explore (any READY video; run make smoke first on
# an empty stack). The drill registers one user, so it never uses up the per-IP register bucket.
# Prints one ok/FAIL line per check and exits non-zero on the first failure; on exit (passed or
# not) every stack service runs again with its default settings. Reads Redis db 10 only, with SCAN.
#
# Usage (from the repo root, stack up): make drill-rate-limit
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# The Redis-down setting: .invalid never resolves (RFC 2606).
redis_down_url=redis://redis-down.invalid:6379/10

# gateway_keys PATTERN: how many keys of the gateway's Redis db 10 match PATTERN.
gateway_keys() {
  local keys
  keys=$(redis-cli -h 127.0.0.1 -p 6379 -n 10 --scan --pattern "$1") || fail "scan Redis db 10 for $1"
  count_lines "$keys"
}

# login_attempt CRED_FILE: POST /auth/login with the credentials in CRED_FILE; prints the status,
# leaves the body in $work/body and the response headers in $work/headers. Only used with wrong
# passwords, so no response holds a token.
login_attempt() {
  : >"$work/body"
  : >"$work/headers"
  curl -sS --max-time "$max_time" -o "$work/body" -D "$work/headers" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary "@$1" "$base/auth/login" || true
}

# retry_after: the Retry-After header of the last login_attempt ("" when absent).
retry_after() { tr -d '\r' <"$work/headers" | awk -F': *' 'tolower($1) == "retry-after" { print $2; exit }'; }

# email_buckets CRED_FILE: how many login-email buckets of the email in CRED_FILE Redis db 10
# holds; the key holds the SHA-256 of the email (no raw email in Redis).
email_buckets() {
  local hash
  hash=$(jq -r '.email | ascii_downcase' "$1" | tr -d '\n' | shasum -a 256 | cut -c 1-32)
  gateway_keys "svp:gw:rl:login-email:*:$hash"
}

# wrong_cred: writes a new, never registered email and a random password to $work/wrong.cred.
wrong_cred() {
  local email
  email="drill-rl-$(date +%s)-$(openssl rand -hex 4)@example.test"
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" '{email: $e, password: env.DRILL_PASSWORD}' >"$work/wrong.cred"
}

# wrong_logins ALLOWED STEP: with a new, never registered email and a random password, ALLOWED
# logins are 401 and the next one is 429 RATE_LIMITED with a Retry-After of at least 1 s.
wrong_logins() {
  local allowed=$1 i status after
  wrong_cred
  for ((i = 1; i <= allowed; i++)); do
    status=$(login_attempt "$work/wrong.cred")
    [[ $status == 401 ]] || fail "$2: wrong login $i of $allowed is 401 (status $status, $(problem_summary))"
  done
  status=$(login_attempt "$work/wrong.cred")
  after=$(retry_after)
  [[ $status == 429 && $(field code) == RATE_LIMITED && $after =~ ^[1-9][0-9]*$ ]] ||
    fail "$2: wrong login $((allowed + 1)) is 429 RATE_LIMITED with Retry-After (status $status, $(problem_summary), Retry-After '$after')"
  ok "$2: $allowed wrong logins 401, then 429 RATE_LIMITED with Retry-After $after s"
}

wait_gateway_ready 60
new_user a

# 1. The limits run on Redis: A's login left its login-email bucket.
n=$(email_buckets "$work/a.cred")
[[ $n == 1 ]] || fail "Redis db 10 holds A's login-email bucket (found $n keys)"
ok "Redis db 10 holds A's login-email bucket ($(gateway_keys 'svp:gw:rl:*') svp:gw:rl:* keys in all)"

# 2. login-email with Redis: burst 5.
wrong_logins 5 "Redis up"

# 3. UP-7: at most 3 videos UPLOADING per user within the 15 minutes of an upload form.
for i in 1 2 3 4; do
  jq -n --arg t "drill rate limit $i $(openssl rand -hex 4)" '{title: $t, size_bytes: 1048576, content_type: "video/mp4"}' >"$work/video.json"
  status=$(request POST /videos "$work/a.auth" "$work/video.json")
  if ((i <= 3)); then
    [[ $status == 201 ]] || fail "POST /videos $i of 3 is 201 (status $status, $(problem_summary))"
  else
    [[ $status == 429 && $(field code) == TOO_MANY_UPLOADS ]] ||
      fail "POST /videos 4 with 3 uploads open is 429 TOO_MANY_UPLOADS (status $status, $(problem_summary))"
  fi
done
ok "POST /videos without uploading: 3 x 201, then 429 TOO_MANY_UPLOADS"

status=$(request GET "/feed/explore?page_size=1" "$work/a.auth")
video_id=$(jq -r '.items[0].video_id // ""' "$work/body")
[[ $status == 200 && -n $video_id ]] || fail "explore has a video to like and view (status $status; run make smoke first)"
check_uuid "$video_id"

# 4. Redis unreachable: recreate the gateway alone with REDIS_URL on a host that never resolves.
since=$(utc_now)
recreate_service gateway SVP_GATEWAY_REDIS_URL="$redis_down_url"
wait_gateway_ready 60
ok "gateway recreated with REDIS_URL=$redis_down_url"

status=$(request GET /feed/explore "$work/a.auth")
[[ $status == 200 ]] || fail "Redis down: GET /feed/explore is 200 (status $status, $(problem_summary))"
status=$(request PUT "/videos/$video_id/like" "$work/a.auth")
[[ $status == 204 ]] || fail "Redis down: PUT like is 204 (status $status, $(problem_summary))"
status=$(request DELETE "/videos/$video_id/like" "$work/a.auth")
[[ $status == 204 ]] || fail "Redis down: DELETE like is 204 (status $status, $(problem_summary))"
status=$(request POST "/videos/$video_id/views" "$work/a.auth")
[[ $status == 202 ]] || fail "Redis down: POST view is 202 (status $status, $(problem_summary))"
ok "Redis down: feed 200, like and unlike 204, view 202 (fail open)"

# login-email falls back to the in-memory bucket of this gateway: burst 3.
wrong_logins 3 "Redis down"
n=$(compose logs --no-log-prefix --since "$since" gateway 2>/dev/null |
  grep -cF '"msg":"rate limit store unavailable, using fallback"' || true)
[[ $n -gt 0 ]] || fail "Redis down: the gateway logs 'rate limit store unavailable, using fallback'"
ok "Redis down: gateway logged 'rate limit store unavailable, using fallback' ($n lines, at most one per 10 s)"

# 5. Back to the default settings: the gateway writes to Redis again. A new email's login-email
# bucket lives 6 min after one login, where A's read bucket would live 100 ms.
recreate_service gateway
wait_gateway_ready 60
status=$(request GET /feed/explore "$work/a.auth")
[[ $status == 200 ]] || fail "default settings: GET /feed/explore is 200 (status $status, $(problem_summary))"
wrong_cred
status=$(login_attempt "$work/wrong.cred")
[[ $status == 401 ]] || fail "default settings: a wrong login with a new email is 401 (status $status, $(problem_summary))"
n=$(email_buckets "$work/wrong.cred")
[[ $n == 1 ]] || fail "default settings: Redis db 10 holds the new email's login-email bucket (found $n keys)"
ok "gateway recreated with its default REDIS_URL: a wrong login's login-email bucket is in Redis db 10 again"

echo "drill-rate-limit: all checks passed"
