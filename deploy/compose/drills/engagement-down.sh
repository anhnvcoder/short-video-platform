#!/usr/bin/env bash
# Drill: engagement-service is down and the feed still serves (ADR-0009 section 9, architecture
# section 7.2). With fresh users A and B, B following A and A's video READY in B's feed with stats:
#   1. stop engagement-service;
#   2. GET /feed/following and /feed/explore are 200 within max_feed_seconds, with items and no
#      `stats` on any item; PUT /videos/{id}/like is 503 or 504, not a hang; /readyz is 200;
#   3. start engagement-service: the feed items carry `stats` again.
# Prints one ok/FAIL line per check and exits non-zero on the first failure; on exit every stack
# service runs again. No database is read.
#
# Usage (from the repo root, stack up): make drill-engagement-down
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

# A feed page without stats must still answer within this many seconds (the gateway gives
# GetStats 100 ms).
max_feed_seconds=${max_feed_seconds:-1}

# timed_get PATH AUTH_FILE: GET through the gateway like `request`; leaves the body in $work/body
# and prints "STATUS SECONDS" (curl's %{time_total}).
timed_get() {
  : >"$work/body"
  curl -sS --max-time "$max_time" -o "$work/body" -w '%{http_code} %{time_total}' -H "@$2" "$base$1" || true
}

# check_feed_without_stats FEED: GET /feed/FEED is 200 within max_feed_seconds, has items, and no
# item has stats.
check_feed_without_stats() {
  local status seconds
  read -r status seconds <<<"$(timed_get "/feed/$1" "$work/b.auth")"
  [[ $status == 200 ]] || fail "GET /feed/$1 with engagement-service down is 200 (status $status, $(problem_summary))"
  awk -v s="$seconds" -v m="$max_feed_seconds" 'BEGIN { exit !(s < m) }' ||
    fail "GET /feed/$1 with engagement-service down answers within $max_feed_seconds s (took $seconds s)"
  [[ $(jq '.items | length' "$work/body") -gt 0 ]] || fail "GET /feed/$1 with engagement-service down has items"
  [[ $(jq '[.items[] | has("stats")] | any' "$work/body") == false ]] ||
    fail "GET /feed/$1 with engagement-service down has no stats on any item"
  ok "GET /feed/$1 with engagement-service down: 200 in $seconds s, $(jq '.items | length' "$work/body") items, none with stats"
}

wait_gateway_ready 60
new_user a
new_user b
status=$(request PUT "/me/following/$a_id" "$work/b.auth")
[[ $status == 204 ]] || fail "B follows A (status $status, $(problem_summary))"
ok "B follows A"
make_video "$work/clip.mp4" 5 1280x720
upload_video clip "$work/a.auth" "$work/clip.mp4"
wait_ready clip "$work/a.auth" 300
ok "video $clip_id READY after ${clip_wait} s"
wait_feed_item following "$work/b.auth" "$clip_id" 30 '. != null and .stats != null' "video in B's following feed with stats"
ok "video in B's following feed with stats"

# 1. Stop engagement-service.
stop_consumer engagement-service engagement-service

# 2. The feed serves without stats, likes fail fast, the gateway stays ready.
check_feed_without_stats following
check_feed_without_stats explore
start=$(now)
status=$(request PUT "/videos/$clip_id/like" "$work/b.auth")
took=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.3f", b - a }')
[[ $status == 503 || $status == 504 ]] ||
  fail "PUT like with engagement-service down is 503 or 504 (status $status after $took s, $(problem_summary))"
ok "PUT like with engagement-service down: $status in $took s"
status=$(curl -s --max-time "$max_time" -o /dev/null -w '%{http_code}' "$base/readyz" || true)
[[ $status == 200 ]] || fail "/readyz with engagement-service down is 200 (status $status)"
ok "/readyz with engagement-service down: 200"

# 3. Start engagement-service again: stats come back once the gateway reconnects.
start_service engagement-service
wait_feed_item following "$work/b.auth" "$clip_id" 60 '. != null and .stats != null' \
  "stats back in B's following feed after engagement-service restarts"
ok "engagement-service running again: stats back in B's following feed ($(jq -c '.stats' "$work/item"))"

echo "drill-engagement-down: all checks passed"
