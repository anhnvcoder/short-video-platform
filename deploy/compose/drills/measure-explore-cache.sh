#!/usr/bin/env bash
# Measures the explore feed cache of feed-service (ADR-0010, sections 3 and 7): the first explore
# page is cached in Redis db 14 for 5 s and concurrent misses share one Postgres read
# (singleflight). The drill deletes the cached first pages (svp:feed:explore:*), then:
#   1. wave 1: N concurrent GET /feed/explore (one curl process, a connection each) on the empty
#      cache: feed-service logs "explore page loaded from database" exactly once;
#   2. wave 2: N more concurrent requests, started as soon as wave 1's first response arrives, so
#      inside the 5 s TTL: no Postgres read at all.
# Each wave runs as its own fresh user, since the read limit is a burst of 200 per user; every
# request must be 200. Prints p50, p95 and max response time of each wave, and a warning (not a
# failure) when wave 1 takes over 4 s, since wave 2 may then outlive the TTL. The Postgres reads are
# the log lines feed-service writes during both waves: two counts of the line with the same
# --since, right before wave 1 and after wave 2, so earlier runs never count and the Docker VM's
# clock need not match the host's. The waves overlap, so they are not counted apart: wave 1 starts
# on the emptied cache and reads at least once, so 1 read in all is 1 in wave 1 and 0 in wave 2.
# Deletes only the explore keys in Redis db 14; reads no database.
#
# Usage (from the repo root, stack up): make measure-explore-cache N=100
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

runs=${N:-100}
[[ $runs =~ ^[1-9][0-9]*$ ]] && ((runs <= 150)) ||
  fail "N is between 1 and 150 (got '$runs'): the read limit allows a burst of 200 per user"
load_msg="explore page loaded from database"

# start_wave NAME AUTH_FILE: starts N concurrent GET /feed/explore as NAME in one background curl
# process; every request appends "STATUS SECONDS" to $work/NAME as soon as it ends (curl's -w
# output goes to stderr, which is unbuffered). Sets wave_pid.
start_wave() {
  local i
  for ((i = 0; i < runs; i++)); do
    printf 'url = "%s/feed/explore"\noutput = "/dev/null"\n' "$base"
  done >"$work/$1.curl"
  : >"$work/$1"
  curl -s --parallel --parallel-immediate --parallel-max "$runs" --max-time "$max_time" -H "@$2" \
    -w '%{stderr}%{http_code} %{time_total}\n' -K "$work/$1.curl" 2>>"$work/$1" &
  wave_pid=$!
}

# wave_report NAME: fails unless every request of wave NAME was 200; prints "p50 P  p95 P  max M"
# (nearest rank, seconds).
wave_report() {
  local got bad
  got=$(count_lines "$(<"$work/$1")")
  bad=$(awk '$1 != 200 { n++ } END { print n + 0 }' "$work/$1")
  [[ $got == "$runs" && $bad == 0 ]] || fail "$1: $runs requests all 200 (got $got answers, $bad not 200)"
  awk '{ print $2 }' "$work/$1" | sort -n >"$work/$1.sorted"
  awk -v n="$runs" '
    { t[NR] = $1 }
    function pct(p,  r) { r = int(p * n / 100); if (r < p * n / 100) r++; if (r < 1) r = 1; return t[r] * 1000 }
    END { printf "p50 %.1f ms  p95 %.1f ms  max %.1f ms", pct(50), pct(95), t[n] * 1000 }' "$work/$1.sorted"
}

# loads: how many "explore page loaded from database" lines feed-service logged since $since.
loads() {
  compose logs --no-log-prefix --since "$since" feed-service 2>/dev/null | grep -cF "\"msg\":\"$load_msg\"" || true
}

wait_gateway_ready 60
new_user w1
new_user w2

# Empty the cache: only the explore first pages of feed-service, found by SCAN.
keys=$(redis-cli -h 127.0.0.1 -p 6379 -n 14 --scan --pattern 'svp:feed:explore:*') ||
  fail "scan Redis db 14 for svp:feed:explore:*"
for key in $keys; do
  redis-cli -h 127.0.0.1 -p 6379 -n 14 DEL "$key" >/dev/null || fail "delete $key in Redis db 14"
done
ok "explore cache emptied ($(count_lines "$keys") keys deleted in Redis db 14)"

# Wave 1 on the empty cache; wave 2 as soon as wave 1's first answer is in. Both counts look back
# a minute, far more than the host and the Docker VM clocks drift apart.
since=$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 60))')
before=$(loads)
start1=$(now)
start_wave wave1 "$work/w1.auth"
pid1=$wave_pid
until [[ -s $work/wave1 ]]; do
  kill -0 "$pid1" 2>/dev/null || [[ -s $work/wave1 ]] || fail "wave 1 ended without an answer"
  sleep 0.01
done
start2=$(now)
start_wave wave2 "$work/w2.auth"
pid2=$wave_pid
wait "$pid1" || true
end1=$(now)
wait "$pid2" || true
end2=$(now)
took1=$(awk -v a="$start1" -v b="$end1" 'BEGIN { printf "%.2f", b - a }')
took2=$(awk -v a="$start2" -v b="$end2" 'BEGIN { printf "%.2f", b - a }')
gap=$(awk -v a="$start1" -v b="$start2" 'BEGIN { printf "%.2f", b - a }')

report1=$(wave_report wave1)
report2=$(wave_report wave2)
if awk -v t="$took1" 'BEGIN { exit !(t > 4) }'; then
  echo "WARN  wave 1 took $took1 s: wave 2 may have outlived the 5 s cache TTL"
fi

# The log lines reach docker logs a moment after they are written.
sleep 2
total=$(($(loads) - before))
echo "      wave 1: N=$runs on an empty cache in $took1 s; $report1"
echo "      wave 2: N=$runs started $gap s after wave 1, in $took2 s; $report2"
echo "      Postgres reads during both waves: $total"
[[ $total == 1 ]] ||
  fail "both waves: $runs concurrent requests on an empty cache, then $runs within the TTL, read Postgres once in all (got $total)"
ok "wave 1: $runs concurrent requests on an empty cache, 1 Postgres read"
ok "wave 2: $runs requests within the 5 s TTL, 0 Postgres reads"

echo "measure-explore-cache: all checks passed"
