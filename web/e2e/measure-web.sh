#!/usr/bin/env bash
# `make measure-web`, run from web/ on the compose stack of `make up`: the memory of the `web` container at rest, the
# whole e2e run (which includes the first-frame test, e2e/first-frame.e2e.ts), the memory right after, then one summary:
# time to first frame p50/p95 per browser and the two memory readings, printed and written to
# test-results/measure-web-<UTC time>.json (gitignored). Memory is MemUsage of `docker stats --no-stream`, the
# container's cgroup memory less its inactive file cache; "at rest" is when this script starts, so run it right after
# `make up` for the reading the Definition of Done asks for. Exits with the e2e run's status.
#
# LOCAL LAB ONLY, like the e2e run itself (e2e/seed.sh resets the gateway's register rate limit in Redis db 10).
set -euo pipefail

docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

container=$(docker_ ps -q --filter label=com.docker.compose.project=svp --filter label=com.docker.compose.service=web)
[[ -n $container ]] || {
  echo "measure-web: container web of the compose stack is not running; run 'make up' first" >&2
  exit 1
}

# memory_mib: MemUsage of the container in MiB (docker prints e.g. 112.5MiB / 256MiB).
memory_mib() {
  docker_ stats --no-stream --format '{{.MemUsage}}' "$container" | awk '{
    v = $1; n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
    if (u == "KiB") n /= 1024; else if (u == "GiB") n *= 1024; else if (u == "B") n /= 1048576
    printf "%.1f", n
  }'
}

rest=$(memory_mib)
echo "web memory at rest: $rest MiB"

rm -f test-results/first-frame-*.json
status=0
pnpm e2e || status=$?

after=$(memory_mib)
echo "web memory after e2e: $after MiB"

out="test-results/measure-web-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p test-results
shopt -s nullglob
frames=(test-results/first-frame-*.json)
jq -n --argjson rest "$rest" --argjson after "$after" --argjson e2e_status "$status" \
  --slurpfile frames <(cat /dev/null ${frames[@]+"${frames[@]}"}) \
  '{measured_at: (now | todate), e2e_status: $e2e_status,
    web_memory_mib: {at_rest: $rest, after_e2e: $after},
    first_frame: ($frames | map({key: .project, value: {moves, p50_ms, p95_ms, max_ms}}) | from_entries)}' >"$out"

echo "measure-web:"
jq -r '.first_frame | to_entries[] | "  first frame \(.key): p50 \(.value.p50_ms) ms, p95 \(.value.p95_ms) ms (\(.value.moves) moves)"' "$out"
((${#frames[@]} == 2)) || echo "  first frame: measured in ${#frames[@]} of 2 browsers (see the e2e output above)"
jq -r '.web_memory_mib | "  web memory: \(.at_rest) MiB at rest, \(.after_e2e) MiB after e2e"' "$out"
echo "  written to web/$out"
exit "$status"
