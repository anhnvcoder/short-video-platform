#!/usr/bin/env bash
# The load test of deploy/k6/main.js against the running compose stack (`make up`), run by `make load-local` (profile
# local) and `make load-ci` (profile ci, the CI job `stack`); docs/adr/0020-reliability-stage6.md, section 2.
#
#   1. Refuses unless the gateway and web containers of compose project svp run and no node or registry of the k3d
#      cluster svp does; it never starts anything.
#   2. LOCAL LAB ONLY: deletes the gateway's per-IP register rate limit keys (svp:gw:rl:register:*) in Redis db 10 on
#      127.0.0.1:6379 with SCAN + DEL (reset_register_limit of deploy/compose/lib.sh, as make smoke does), since the
#      pool registers from the one address of the k6 container. Never point this script at a shared stack.
#   3. Runs K6_IMAGE in a container on the compose network svp_web, where the gateway and the web client are: the
#      gateway at http://gateway:8080, and the web at http://web:3001 with Host and Origin of http://localhost:3001,
#      the APP_ORIGIN Next's Server Action check and the web's CSRF check compare against. The gateway sees the k6
#      container's own address, apart from the web container's, so the two never share a per-IP rate limit bucket.
#      K6_NO_USAGE_REPORT: k6 would otherwise report each run to Grafana's usage server.
#   4. Writes .k6/<profile>-<yyyymmddThhmmssZ>/summary.json (from handleSummary, no setup data) and machine.json (the
#      Docker VM's CPUs and memory, power source), then greps the folder: a token, cookie or password in it fails the
#      run.
#
# Usage: K6_IMAGE=<image> deploy/k6/load.sh local|ci  (SVP_K6_HOLD=<n>s|m overrides how long the full rate holds)
# Exit status: 0 when every threshold passed, 1 otherwise (k6's own status is printed).
set -euo pipefail

profile=${1:-}
case $profile in
  local | ci) ;;
  *)
    echo "usage: deploy/k6/load.sh local|ci" >&2
    exit 2
    ;;
esac
: "${K6_IMAGE:?set K6_IMAGE (run make load-$profile)}"
repo=$(cd "$(dirname "$0")/../.." && pwd)
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

running() {
  docker_ ps -q --filter label=com.docker.compose.project=svp --filter "label=com.docker.compose.service=$1" \
    --filter status=running
}
[[ -z $(docker_ ps -q --filter label=k3d.cluster=svp; docker_ ps -q --filter 'name=^k3d-svp-registry$') ]] || {
  echo "FAIL  the k3d cluster svp or its registry is running; this load test runs on the compose stack only (make k8s-down, then make up)" >&2
  exit 1
}
for svc in gateway web; do
  [[ -n $(running "$svc") ]] || {
    echo "FAIL  container $svc of the compose stack is not running; start the stack first (make up OBS=lgtm)" >&2
    exit 1
  }
done
docker_ network inspect svp_web >/dev/null 2>&1 || {
  echo "FAIL  compose network svp_web not found; start the stack first (make up OBS=lgtm)" >&2
  exit 1
}

base=http://127.0.0.1:8080
# shellcheck source=deploy/compose/lib.sh
source "$repo/deploy/compose/lib.sh" # LOCAL LAB ONLY: resets the register rate limit (step 2)
wait_gateway_ready 30

results=$repo/.k6/$profile-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$results"
power=
if command -v pmset >/dev/null; then
  power=$(pmset -g batt | sed -n "s/.*drawing from '\([^']*\)'.*/\1/p")
  if pmset -g | grep -Eq '^ *lowpowermode +1'; then power="$power, Low Power Mode"; fi
fi
docker_ info --format '{{json .}}' | jq --arg host "$(uname -sm)" --arg power "$power" \
  '{host: $host, power: (if $power == "" then null else $power end), docker_cpus: .NCPU, docker_memory_bytes: .MemTotal,
    docker_os: .OperatingSystem, docker_architecture: .Architecture}' >"$results/machine.json"

hold_env=()
if [[ -n ${SVP_K6_HOLD:-} ]]; then hold_env=(-e "SVP_K6_HOLD=$SVP_K6_HOLD"); fi
echo "k6 profile $profile on the compose stack; results in ${results#"$repo"/}"
rc=0
docker_ run --rm --network svp_web --user "$(id -u):$(id -g)" \
  -e K6_NO_USAGE_REPORT=true -e K6_AUTO_EXTENSION_RESOLUTION=false \
  -v "$repo/deploy/k6:/scripts:ro" -v "$results:/results" \
  "$K6_IMAGE" run --quiet \
  -e "SVP_K6_PROFILE=$profile" -e SVP_API_URL=http://gateway:8080 -e SVP_WEB_URL=http://web:3001 \
  -e SVP_WEB_ORIGIN=http://localhost:3001 -e SVP_K6_RESULTS=/results ${hold_env[@]+"${hold_env[@]}"} \
  /scripts/main.js || rc=$?

[[ -s $results/summary.json ]] || fail "k6 wrote no summary.json (k6 exit status $rc)"
# Names and shapes of what must never be in the results: a JWT, the session cookie, the words a header or field of
# a secret carries.
if leaks=$(grep -rIlE -i 'eyJ[A-Za-z0-9_-]{8,}|svp_sid|bearer|password|cookie|token|set-cookie' "$results"); then
  fail "the results hold a token, cookie or password: ${leaks//$repo\//}"
fi
ok "no token, cookie or password in ${results#"$repo"/}"
case $rc in
  0) ok "k6 profile $profile: every threshold passed" ;;
  99) fail "k6 profile $profile: thresholds failed (see the FAIL lines above and ${results#"$repo"/}/summary.json)" ;;
  *) fail "k6 profile $profile ended with status $rc" ;;
esac
