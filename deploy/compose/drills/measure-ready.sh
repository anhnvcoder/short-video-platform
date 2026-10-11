#!/usr/bin/env bash
# Measures how long a video takes from CompleteUpload to READY (architecture §2, video processing
# SLO: p95 under 2 minutes for a 60 s video). Runs N uploads one after the other, each with the
# same generated 60 s 1080p video; times from the moment POST /videos/{id}/complete returns until
# GET /videos/{id} shows READY, polling every 0.5 s. Prints every run, p50, p95 (nearest rank: the
# max for N < 20) and max against the SLO, and the peak CPU and RAM of media-worker sampled with
# docker compose stats during the runs against its limits (2 CPUs, 2 GiB). Prints one ok/FAIL line
# per check and exits non-zero when one fails.
#
# Usage (from the repo root, stack up): make measure-ready N=5
set -euo pipefail

base=${1:-http://127.0.0.1:8080}
# shellcheck source=deploy/compose/drills/common.sh
source "$(dirname "$0")/common.sh"

runs=${N:-5}
[[ $runs =~ ^[1-9][0-9]*$ ]] || fail "N is a positive integer (got '$runs')"
slo_seconds=120
mem_limit_mib=2048
ready_timeout=600

wait_gateway_ready 60
new_user a
make_video "$work/clip.mp4" 60 1920x1080
ok "generated a 60 s 1080p test video ($(file_size "$work/clip.mp4") bytes), used for every run"

# Sample media-worker once per stats call (each takes about two seconds) until the script ends.
(
  while :; do
    compose stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' media-worker >>"$work/stats" 2>/dev/null || true
  done
) &
sampler_pid=$!

: >"$work/times"
for i in $(seq 1 "$runs"); do
  upload_video "run$i" "$work/a.auth" "$work/clip.mp4"
  start=$(now)
  id_var="run${i}_id"
  deadline=$((SECONDS + ready_timeout))
  while :; do
    video_status "run$i" "$work/a.auth"
    state_var="run${i}_status"
    [[ ${!state_var} == READY ]] && break
    [[ ${!state_var} == FAILED ]] && fail "run $i: video ${!id_var} went FAILED instead of READY"
    ((SECONDS < deadline)) || fail "run $i: video ${!id_var} READY within $ready_timeout s (still ${!state_var})"
    sleep 0.5
  done
  took=$(awk -v a="$start" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }')
  echo "$took" >>"$work/times"
  ok "run $i/$runs: complete -> READY in ${took} s (video ${!id_var})"
done

kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=

# Nearest-rank percentiles over the sorted times.
sort -n "$work/times" >"$work/sorted"
pct() { awk -v p="$1" -v n="$runs" 'BEGIN { r = int(p * n / 100); if (r < p * n / 100) r++; if (r < 1) r = 1 } NR == r' "$work/sorted"; }
p50=$(pct 50)
p95=$(pct 95)
max=$(tail -n 1 "$work/sorted")
echo "      N=$runs  p50 ${p50} s  p95 ${p95} s  max ${max} s"
awk -v p="$p95" -v s="$slo_seconds" 'BEGIN { exit !(p < s) }' ||
  fail "p95 ${p95} s under the SLO of ${slo_seconds} s"
ok "p95 ${p95} s under the SLO of ${slo_seconds} s"

# CPUPerc is like "153.21%" (100% per core); MemUsage like "812.5MiB / 2GiB".
read -r samples cpu mem <<<"$(awk '
  function mib(v,   n) {
    n = v + 0
    if (v ~ /GiB$/) return n * 1024
    if (v ~ /MiB$/) return n
    if (v ~ /KiB$/) return n / 1024
    return n / 1048576
  }
  { c = $1 + 0; m = mib($2); s++; if (c > cm) cm = c; if (m > mm) mm = m }
  END { printf "%d %.1f %.0f", s, cm, mm }' "$work/stats")"
((samples > 0)) || fail "docker compose stats sampled media-worker during the runs"
echo "      media-worker over $samples samples: peak CPU ${cpu}% (limit 200%), peak RAM ${mem} MiB (limit ${mem_limit_mib} MiB)"
((mem < mem_limit_mib)) || fail "media-worker peak RAM ${mem} MiB under its ${mem_limit_mib} MiB limit"
ok "media-worker peak RAM ${mem} MiB under its ${mem_limit_mib} MiB limit"

echo "measure-ready: all checks passed"
