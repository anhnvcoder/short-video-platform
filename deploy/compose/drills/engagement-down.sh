#!/usr/bin/env bash
# Drill: engagement-service is down, the gateway's circuit breaker opens, and the feed still serves
# (architecture section 7.2). With fresh users A and
# B, B following A and A's video READY in B's feed with stats:
#   1. stop engagement-service;
#   2. send likes in parallel until the gateway logs the engagement-service breaker as open (one
#      at a time each would wait out the 3 s call timeout); then 10 PUT /videos/{id}/like in a row
#      are each 503 in under max_open_seconds, without reaching the network (prints the slowest);
#   3. GET /feed/following and /feed/explore are 200 within max_feed_seconds, with items and no
#      `stats` on any item; /readyz is 200;
#   4. start engagement-service: the breaker closes by itself (half-open after 5 s, one trial call),
#      PUT like is 204 again within close_timeout seconds (prints how long it took), and the feed
#      items carry `stats` again.
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
# With the breaker open a like must be refused within this many seconds: it fails fast from the breaker instead of
# waiting out the 3 s call timeout.
max_open_seconds=0.1
# Seconds after engagement-service is healthy again within which a like must succeed.
close_timeout=30

# breaker_changes SINCE TO: how many times the gateway logged the engagement-service breaker
# changing to state TO (open, half-open, closed) since SINCE (RFC 3339).
breaker_changes() {
  compose logs --no-log-prefix --since "$1" gateway 2>/dev/null | grep -F '"msg":"circuit breaker state changed"' |
    grep -F '"target":"engagement-service"' | grep -cF "\"to\":\"$2\"" || true
}

# check_feed_without_stats FEED: GET /feed/FEED is 200 within max_feed_seconds, has items, and no
# item has stats.
check_feed_without_stats() {
  local status seconds
  read -r status seconds <<<"$(timed_request GET "/feed/$1" "$work/b.auth")"
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
since=$(utc_now)
stop_consumer engagement-service engagement-service

# 2. Open the breaker: 5 failed calls in a row. Each call to the stopped service may wait out the
# 3 s call timeout, so the likes go out in parallel rounds until the gateway logs the change.
start=$(now)
for round in 1 2 3 4 5; do
  for i in 1 2 3 4 5 6; do
    curl -s --max-time "$max_time" -o /dev/null -X PUT -H "@$work/b.auth" "$base/videos/$clip_id/like" &
  done
  wait
  [[ $(breaker_changes "$since" open) -gt 0 ]] && break
  ((round < 5)) || fail "gateway logs the engagement-service breaker as open after $((round * 6)) likes"
done
opened=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
ok "engagement-service breaker open after $((round * 6)) likes in parallel rounds (${opened} s)"

# The breaker stays open 5 s: the 10 likes below take well under that.
: >"$work/open-times"
for i in 1 2 3 4 5 6 7 8 9 10; do
  read -r status seconds <<<"$(timed_request PUT "/videos/$clip_id/like" "$work/b.auth")"
  [[ $status == 503 ]] || fail "PUT like $i with the breaker open is 503 (status $status after $seconds s, $(problem_summary))"
  echo "$seconds" >>"$work/open-times"
done
slowest=$(sort -n "$work/open-times" | tail -n 1)
awk -v s="$slowest" -v m="$max_open_seconds" 'BEGIN { exit !(s < m) }' ||
  fail "every PUT like with the breaker open answers in under $max_open_seconds s (slowest $slowest s)"
ok "10 PUT like with the breaker open: 503 each, slowest $slowest s (< $max_open_seconds s)"

# 3. The feed serves without stats and the gateway stays ready.
check_feed_without_stats following
check_feed_without_stats explore
status=$(curl -s --max-time "$max_time" -o /dev/null -w '%{http_code}' "$base/readyz" || true)
[[ $status == 200 ]] || fail "/readyz with engagement-service down is 200 (status $status)"
ok "/readyz with engagement-service down: 200"

# 4. Start engagement-service again: the next trial call after the open period closes the breaker.
start_service engagement-service
start=$(now)
deadline=$((SECONDS + close_timeout))
while :; do
  status=$(request PUT "/videos/$clip_id/like" "$work/b.auth")
  [[ $status == 204 ]] && break
  ((SECONDS < deadline)) ||
    fail "PUT like is 204 within $close_timeout s of engagement-service running again (last status $status, $(problem_summary))"
  sleep 0.5
done
closed=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
[[ $(breaker_changes "$since" closed) -gt 0 ]] || fail "gateway logs the engagement-service breaker as closed again"
ok "engagement-service running again: PUT like 204 after ${closed} s, breaker closed by itself"
wait_feed_item following "$work/b.auth" "$clip_id" 60 '. != null and .stats != null' \
  "stats back in B's following feed after engagement-service restarts"
ok "stats back in B's following feed ($(jq -c '.stats' "$work/item"))"

echo "drill-engagement-down: all checks passed"
