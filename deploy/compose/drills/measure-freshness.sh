#!/usr/bin/env bash
# Measures feed freshness (architecture §2: p95 under 10 s from video.ready to the last timeline
# row) the way ADR-0009 section 10 decides:
#   1. registers a new author (no older videos, so the fake follows backfill nothing) and has
#      tools/fakefollows produce FOLLOWERS user.followed events for it, impersonating user-service;
#      waits until svp_feed holds all FOLLOWERS follows of the author (load time and follows/s);
#   2. N times, one after the other: uploads the same short clip and polls svp_feed every 100 ms
#      until the video has FOLLOWERS timeline rows; freshness = the created_at of the last of those
#      rows (clock_timestamp() as it was inserted) - the video's published_at in svp_video, so the
#      time a poll takes to scan the table is not part of it. Both come from the Postgres clock,
#      and the subtraction is done in SQL. Each run also splits the time into the outbox relay
#      (published_at -> relay picks the video.ready row up), delivery (-> feed-service inserts the
#      first timeline row) and fan-out (first -> last row inserted);
#   3. prints every run, p50, p95 (nearest rank: the max for N < 20) and max against 10 s, and the
#      peak CPU and RAM of feed-service (docker compose stats) during the load and during the runs;
#   4. always, also on failure or Ctrl-C: produces user.unfollowed for the same ids, waits until
#      the feed-service group has no lag (every follow and unfollow produced so far is applied),
#      then checks that the author has no follow and its videos no timeline row in svp_feed. When
#      that cleanup fails, the ids file is kept and the command to finish it is printed.
# A p95 over 10 s is reported, not failed: at 200,000 followers it is a data point (ADR-0009
# section 7, "Xem lại khi"). The script fails when a measurement cannot be taken. N is at most 10:
# every video has the one followed author, whose upload limit is a burst of 10 POST /videos
# (ADR-0010, section 2).
#
# Reads svp_feed and svp_video with SELECT only; produces only to the stack's Redpanda.
#
# Usage (from the repo root, stack up): make measure-freshness FOLLOWERS=10000 N=10
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

followers=${FOLLOWERS:-10000}
runs=${N:-10}
[[ $followers =~ ^[1-9][0-9]*$ ]] || fail "FOLLOWERS is a positive integer (got '$followers')"
[[ $runs =~ ^[1-9][0-9]*$ ]] && ((runs <= 10)) ||
  fail "N is between 1 and 10 (got '$runs'): the upload limit allows the one author a burst of 10 videos"
brokers=127.0.0.1:19092
nfr_seconds=10
# Seconds to wait for svp_feed to take in (or drop) all follows: generous at 100 follows/s.
follows_timeout=$((120 + followers / 100))
# Seconds from CompleteUpload until every timeline row of a video is there.
run_timeout=300
repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
ids_file=$work/followers
author_id=

# query DB [psql args...]: runs the SQL on stdin against DB as the local superuser; prints the
# rows unaligned, columns separated by "|" (timestamps hold a space).
query() {
  local db=$1
  shift
  psql -h 127.0.0.1 -p 5432 -U postgres -d "$db" -w -X -q -At -F '|' -v ON_ERROR_STOP=1 "$@"
}

follows_count() {
  query svp_feed -v a="$author_id" <<'SQL'
SELECT count(*) FROM follows WHERE followee_id = :'a';
SQL
}

# wait_follows TARGET TIMEOUT: polls the author's follow count in svp_feed until it is TARGET,
# printing progress every 10 s; sets `waited` to the seconds taken (milliseconds). Returns 1 on a
# query error or timeout, after printing why.
wait_follows() {
  local start deadline=$((SECONDS + $2)) next=$((SECONDS + 10)) got
  start=$(now)
  while :; do
    got=$(follows_count) || {
      echo "FAIL  read the follows of author $author_id from svp_feed" >&2
      return 1
    }
    [[ $got == "$1" ]] && break
    if ((SECONDS >= deadline)); then
      echo "FAIL  author $author_id has $1 follows in svp_feed within $2 s (still $got)" >&2
      return 1
    fi
    if ((SECONDS >= next)); then
      echo "      ... $got follows of the author in svp_feed, waiting for $1"
      next=$((SECONDS + 10))
    fi
    sleep 0.5
  done
  waited=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
}

# wait_feed_caught_up TIMEOUT: polls until the feed-service group has no lag on its topics,
# printing progress every 10 s; sets `waited` like wait_follows. Returns 1 on timeout instead of
# failing, so the exit trap can use it.
wait_feed_caught_up() {
  local start deadline=$((SECONDS + $1)) next=$((SECONDS + 10)) lag
  start=$(now)
  while :; do
    lag=$(group_field feed-service TOTAL-LAG)
    [[ $lag == 0 ]] && break
    if ((SECONDS >= deadline)); then
      echo "FAIL  group feed-service has no lag within $1 s (still '$lag')" >&2
      return 1
    fi
    if ((SECONDS >= next)); then
      echo "      ... group feed-service lag '$lag', waiting for 0"
      next=$((SECONDS + 10))
    fi
    sleep 0.5
  done
  waited=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
}

# cleanup_fakes: unfollows every id of the ids file, waits until feed-service has applied every
# event produced so far, then checks that the author has no follow and its videos no timeline row
# in svp_feed; removes the ids file when done. Counting only after the lag is 0 makes the check a
# proof: before that, a count of 0 can just mean feed-service has not applied the follows yet.
# Returns 1 when any step fails (never exits: it runs in the exit trap too).
cleanup_fakes() {
  local left
  [[ -s $ids_file ]] || return 0
  if ! "$work/fakefollows" unfollow -brokers "$brokers" -followee "$author_id" -in "$ids_file" >"$work/unfollow.log" 2>&1; then
    echo "FAIL  fakefollows unfollow: $(tail -n 1 "$work/unfollow.log")" >&2
    return 1
  fi
  wait_feed_caught_up "$follows_timeout" || return 1
  left=$(follows_count) || {
    echo "FAIL  read the follows of author $author_id from svp_feed" >&2
    return 1
  }
  if [[ $left != 0 ]]; then
    echo "FAIL  author $author_id has no follow left in svp_feed once feed-service caught up (still $left)" >&2
    return 1
  fi
  left=$(query svp_feed -v a="$author_id" <<'SQL'
SELECT count(*) FROM timeline t JOIN videos v USING (video_id) WHERE v.author_id = :'a';
SQL
  ) || {
    echo "FAIL  read the timeline rows of author $author_id's videos from svp_feed" >&2
    return 1
  }
  if [[ $left != 0 ]]; then
    echo "FAIL  no timeline row of author $author_id's videos left in svp_feed (still $left)" >&2
    return 1
  fi
  rm -f "$ids_file"
  ok "unfollowed $followers fake followers in $waited s; svp_feed: 0 follows of the author, 0 timeline rows of its videos"
}

# measure_exit: the EXIT trap. Cleans the fake follows up, keeps the ids file outside $work when
# that fails, then hands the exit status to drill_exit (common.sh), which reads it from $?.
measure_exit() {
  local rc=$? kept
  set +e
  trap - INT TERM
  if ! cleanup_fakes; then
    rc=1
    kept=$(mktemp "${TMPDIR:-/tmp}/fakefollows-ids.XXXXXX") && cp "$ids_file" "$kept" &&
      echo "FAIL  fake follows of author $author_id are not cleaned up; ids kept in $kept, finish with:" >&2 &&
      echo "      go run ./tools/fakefollows unfollow -followee $author_id -in $kept" >&2
  fi
  (exit "$rc")
  drill_exit
}
trap measure_exit EXIT
# A signal ends the script through exit, so the EXIT trap cleans up.
trap 'exit 130' INT TERM

# start_sampler FILE: samples feed-service with docker compose stats (about two seconds per call)
# into FILE until stop_sampler.
start_sampler() {
  : >"$1"
  (
    while :; do
      compose stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' feed-service >>"$1" 2>/dev/null || true
    done
  ) &
  sampler_pid=$!
}
stop_sampler() {
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sampler_pid=
}

# peak_usage FILE LABEL: prints the peak CPU and RAM of the samples in FILE. CPUPerc is like
# "53.21%" (100% per core); MemUsage like "81.5MiB / 256MiB".
peak_usage() {
  local samples cpu mem
  read -r samples cpu mem <<<"$(awk '
    function mib(v,   n) {
      n = v + 0
      if (v ~ /GiB$/) return n * 1024
      if (v ~ /MiB$/) return n
      if (v ~ /KiB$/) return n / 1024
      return n / 1048576
    }
    { c = $1 + 0; m = mib($2); s++; if (c > cm) cm = c; if (m > mm) mm = m }
    END { printf "%d %.1f %.0f", s, cm, mm }' "$1")"
  ((samples > 0)) || fail "docker compose stats sampled feed-service $2"
  echo "      feed-service $2 ($samples samples): peak CPU ${cpu}%, peak RAM ${mem} MiB (limit 256 MiB)"
}

go build -C "$repo_root" -o "$work/fakefollows" ./tools/fakefollows || fail "build tools/fakefollows"
wait_gateway_ready 60
new_user author
check_uuid "$author_id"
make_video "$work/clip.mp4" 5 1280x720
ok "generated a 5 s 720p test video ($(file_size "$work/clip.mp4") bytes), used for every run"

# 1. Load the fake follows; the load time runs from the start of the produce.
start_sampler "$work/stats-load"
load_start=$(now)
"$work/fakefollows" follow -brokers "$brokers" -followee "$author_id" -n "$followers" -out "$ids_file" >"$work/follow.log" 2>&1 ||
  fail "fakefollows follow: $(tail -n 1 "$work/follow.log")"
produce_seconds=$(awk -v a="$load_start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
ok "produced $followers user.followed for author $author_id in ${produce_seconds} s"
wait_follows "$followers" "$follows_timeout" || exit 1
stop_sampler
load_seconds=$(awk -v a="$load_start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
rate=$(awk -v n="$followers" -v s="$load_seconds" 'BEGIN { printf "%.0f", n / s }')
ok "svp_feed holds all $followers follows of the author ${load_seconds} s after the produce started (${rate} follows/s)"
peak_usage "$work/stats-load" "during the follow load"

# 2. Measure N videos.
start_sampler "$work/stats-runs"
: >"$work/times"
echo "      run  freshness  relay  delivery  fan-out  (seconds)"
for i in $(seq 1 "$runs"); do
  upload_video "run$i" "$work/author.auth" "$work/clip.mp4"
  id_var="run${i}_id"
  video_id=${!id_var}
  deadline=$((SECONDS + run_timeout))
  polls=0
  while :; do
    # A failed query must fail here: `read <<<"$(query)" || fail` would not, since read succeeds
    # on the empty string.
    count=$(query svp_feed -v v="$video_id" <<'SQL'
SELECT count(*) FROM timeline WHERE video_id = :'v';
SQL
    ) || fail "count the timeline rows of video $video_id in svp_feed"
    [[ $count == "$followers" ]] && break
    ((count < followers)) || fail "video $video_id has at most $followers timeline rows (got $count)"
    ((SECONDS < deadline)) || fail "run $i: video $video_id has $followers timeline rows within $run_timeout s (still $count)"
    polls=$((polls + 1))
    if ((polls % 20 == 0)); then
      state=$(query svp_video -v v="$video_id" <<'SQL'
SELECT status FROM videos WHERE id = :'v';
SQL
      ) || fail "read the status of video $video_id from svp_video"
      [[ $state != FAILED ]] || fail "run $i: video $video_id went FAILED instead of READY"
    fi
    sleep 0.1
  done
  rows=$(query svp_feed -v v="$video_id" <<'SQL'
SELECT min(created_at), max(created_at) FROM timeline WHERE video_id = :'v';
SQL
  ) || fail "read the insert times of video $video_id's timeline rows from svp_feed"
  IFS='|' read -r first last <<<"$rows"
  # The outbox row carrying video.ready: oneof field 3 (tag byte 26) after the EventMeta.
  rows=$(query svp_video -v v="$video_id" -v first="$first" -v last="$last" <<'SQL'
SELECT round(EXTRACT(EPOCH FROM (:'last'::timestamptz - v.published_at))::numeric, 3),
       round(EXTRACT(EPOCH FROM (o.published_at - v.published_at))::numeric, 3),
       round(EXTRACT(EPOCH FROM (:'first'::timestamptz - o.published_at))::numeric, 3),
       round(EXTRACT(EPOCH FROM (:'last'::timestamptz - :'first'::timestamptz))::numeric, 3)
FROM videos v
JOIN outbox o ON o.record_key = v.id::text
 AND get_byte(o.payload, 0) = 10 AND get_byte(o.payload, 1) < 128
 AND get_byte(o.payload, 2 + get_byte(o.payload, 1)) = 26
WHERE v.id = :'v';
SQL
  ) || fail "compute the freshness of video $video_id from svp_video"
  IFS='|' read -r fresh relay delivery fanout <<<"$rows"
  [[ -n $fresh ]] || fail "svp_video has video $video_id with published_at and its video.ready outbox row"
  echo "$fresh" >>"$work/times"
  printf '      %3d  %9s  %5s  %8s  %7s  (video %s)\n' "$i" "$fresh" "$relay" "$delivery" "$fanout" "$video_id"
done
stop_sampler
ok "$runs videos reached all $followers timelines"

# 3. Summary.
sort -n "$work/times" >"$work/sorted"
pct() { awk -v p="$1" -v n="$runs" 'BEGIN { r = int(p * n / 100); if (r < p * n / 100) r++; if (r < 1) r = 1 } NR == r' "$work/sorted"; }
p50=$(pct 50)
p95=$(pct 95)
max=$(tail -n 1 "$work/sorted")
echo "      FOLLOWERS=$followers N=$runs  p50 ${p50} s  p95 ${p95} s  max ${max} s"
if awk -v p="$p95" -v s="$nfr_seconds" 'BEGIN { exit !(p < s) }'; then
  ok "p95 ${p95} s under the freshness NFR of ${nfr_seconds} s"
else
  echo "NOTE  p95 ${p95} s over the freshness NFR of ${nfr_seconds} s (ADR-0009 section 7: revisit when this holds at 200,000)"
fi
peak_usage "$work/stats-runs" "during the runs"

# 4. Clean up now, so a failure shows as one; the exit trap would retry it.
cleanup_fakes || fail "clean up the fake follows of author $author_id"

echo "measure-freshness: done"
