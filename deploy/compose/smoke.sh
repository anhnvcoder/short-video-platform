#!/usr/bin/env bash
# End-to-end smoke test of the core stack through the gateway: register and log in user A,
# create and read a video, check the visibility rule against user B (threat model UP-3), then
# follow and unfollow. Prints one ok/FAIL line per step and exits non-zero on the first failure.
# Passwords and tokens are never printed and never passed on a command line: jq gets the
# password from its environment, curl reads bodies and headers from private files.
#
# Usage: deploy/compose/smoke.sh [base-url]   (default http://127.0.0.1:8080)
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# Seconds a single request may take: a server that accepts the connection and never answers
# must not hang the script.
max_time=5
# Request bodies and the Authorization headers hold secrets: keep every work file private.
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}

# request METHOD PATH [AUTH_FILE] [BODY_FILE]: sends the request, leaves the body in
# $work/body and the content type in $work/type, and prints the HTTP status.
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

# 1. Wait for the gateway and both services to be ready: 60 s, plus at most one request's
# max_time when the deadline passes during a request.
deadline=$((SECONDS + 60))
until [[ $(curl -s --max-time "$max_time" -o /dev/null -w '%{http_code}' "$base/readyz" || true) == 200 ]]; do
  ((SECONDS < deadline)) || fail "readyz within 60s"
  sleep 1
done
ok "readyz"

# 2. User A creates a video and reads it back.
new_user a
title="smoke video $(openssl rand -hex 4)"
jq -n --arg t "$title" '{title: $t, size_bytes: 1048576, content_type: "video/mp4"}' >"$work/video.json"
status=$(request POST /videos "$work/a.auth" "$work/video.json")
video_id=$(field video_id)
[[ $status == 201 && -n $video_id ]] || fail "create video (status $status, $(problem_summary))"
ok "create video"

status=$(request GET "/videos/$video_id" "$work/a.auth")
[[ $status == 200 ]] || fail "author reads video (status $status, $(problem_summary))"
[[ $(field status) == UPLOADING ]] || fail "video status is UPLOADING (got $(field status))"
[[ $(field title) == "$title" ]] || fail "video title round-trips"
[[ $(field author_id) == "$a_id" ]] || fail "video author_id is user A"
ok "author reads video: UPLOADING, title, author_id"

# 3. No token: 401 problem+json.
status=$(request GET "/videos/$video_id")
[[ $status == 401 && $(<"$work/type") == application/problem+json* ]] ||
  fail "read video without token is 401 problem+json (status $status, type $(<"$work/type"))"
ok "read video without token: 401 problem+json"

# 4. User B cannot see A's video while it is not READY (UP-3).
new_user b
status=$(request GET "/videos/$video_id" "$work/b.auth")
[[ $status == 404 && $(field code) == VIDEO_NOT_FOUND ]] ||
  fail "other user reads unpublished video is 404 VIDEO_NOT_FOUND (status $status, $(problem_summary))"
ok "other user reads unpublished video: 404 VIDEO_NOT_FOUND"

# 5. B follows A twice (idempotent) and unfollows.
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow (status $status, $(problem_summary))"
ok "follow"
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "follow again (status $status, $(problem_summary))"
ok "follow again"
status=$(request DELETE "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "unfollow (status $status, $(problem_summary))"
ok "unfollow"

echo "smoke: all steps passed"
