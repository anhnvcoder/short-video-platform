#!/usr/bin/env bash
# DAST of the gateway against its OpenAPI contract (services/gateway/openapi.yaml) with Schemathesis, on the running
# compose stack (`make up`), run by `make dast` and by the CI job `stack`.
#
#   1. Refuses unless the gateway container of compose project svp runs, network svp_web exists, and no node or
#      registry of the k3d cluster svp runs; it never starts anything.
#   2. LOCAL LAB ONLY: deletes the gateway's per-IP register rate limit keys (svp:gw:rl:register:*) in Redis db 10 on
#      127.0.0.1:6379 before and after the run (reset_register_limit of deploy/compose/lib.sh, as make smoke does), and
#      waits for /readyz, so that a stack still starting is not reported as an API failure. Never point this script at
#      a shared stack.
#   3. Registers and logs in a test user through http://127.0.0.1:8080. Its access token stays in this script's
#      environment: never printed, never on a command line.
#   4. Runs SCHEMATHESIS_IMAGE on svp_web against http://gateway:8080, the token passed as `-e SVP_DAST_TOKEN` with no
#      value (docker reads it from the environment). The container has an address of its own, so its per-IP rate limit
#      buckets are apart from the registration above and from every other step. SVP_DAST_TIMEOUT seconds (600) bound
#      the pull of a missing image and the run together: past them the script stops the container and kills the
#      docker client; macOS has no timeout(1).
#   5. Everything Schemathesis prints goes to .dast/<time>/schemathesis.log, never to the terminal: a failed check
#      prints the response body and a curl command to reproduce it, and the responses of /auth/* and POST /videos hold
#      tokens and presigned forms. junit.xml and requests.har hold the same bodies. The folder is private (mode 700)
#      and those three files never leave the machine or runner.
#   6. Builds summary.json (counts and labels only) from the HAR, then scans the two files meant to be published,
#      report.json and summary.json, for secrets, the test user's token included. Only once both are clean does it
#      print a summary from them.
#
# Usage: SCHEMATHESIS_IMAGE=<image> deploy/dast/run.sh
#   SVP_DAST_SEED=<n> repeats a run with the seed of its report.json (the stack's data differs, so the requests may too).
# Exit status: Schemathesis's own: 0 when every check passed, 1 when a check failed, 2 when it could not run (config,
# schema, internal error, nothing tested). A run over its time limit or with a secret in a published file is 1.
set -euo pipefail

: "${SCHEMATHESIS_IMAGE:?set SCHEMATHESIS_IMAGE (run make dast)}"
timeout=${SVP_DAST_TIMEOUT:-600}
repo=$(cd "$(dirname "$0")/../.." && pwd)
spec=$repo/services/gateway/openapi.yaml
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

# 1. The compose stack only, already running.
[[ -z $(docker_ ps -q --filter label=k3d.cluster=svp; docker_ ps -q --filter 'name=^k3d-svp-registry$') ]] || {
  echo "FAIL  the k3d cluster svp or its registry is running; this DAST runs on the compose stack only (make k8s-down, then make up)" >&2
  exit 2
}
[[ -n $(docker_ ps -q --filter label=com.docker.compose.project=svp --filter label=com.docker.compose.service=gateway \
  --filter status=running) ]] || {
  echo "FAIL  container gateway of the compose stack is not running; start the stack first (make up)" >&2
  exit 2
}
docker_ network inspect svp_web >/dev/null 2>&1 || {
  echo "FAIL  compose network svp_web not found; start the stack first (make up)" >&2
  exit 2
}

# 2. LOCAL LAB ONLY: sourcing lib.sh resets the register rate limit; the EXIT trap below resets it again after the run.
base=http://127.0.0.1:8080
# shellcheck source=deploy/compose/lib.sh
source "$repo/deploy/compose/lib.sh"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
container=svp-dast-$stamp
client=
cleanup() {
  # A docker client still running (the script was interrupted) dies before the container is removed: one still
  # pulling the image would otherwise start the scan once this script is gone.
  if [[ -n $client ]]; then kill -KILL "$client" 2>/dev/null || true; fi
  docker_ rm -f "$container" >/dev/null 2>&1 || true
  # In a subshell: a failed reset prints its FAIL line without cutting the rest of the cleanup short.
  (reset_register_limit) || true
  rm -rf "$work"
}
trap cleanup EXIT

wait_gateway_ready 60

# 3. The test user. Its body holds the token: emptied as soon as the token is read.
DAST_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "dast-$stamp-$(openssl rand -hex 4)@example.test" \
  --arg h "dast_$(openssl rand -hex 6)" '{email: $e, password: env.DAST_PASSWORD, handle: $h}' >"$work/user.reg"
jq '{email, password}' "$work/user.reg" >"$work/user.cred"
status=$(request POST /auth/register "" "$work/user.reg")
[[ $status == 201 ]] || fail "register the test user (status $status, $(problem_summary))"
status=$(request POST /auth/login "" "$work/user.cred")
SVP_DAST_TOKEN=$(field access_token)
: >"$work/body"
[[ $status == 200 && -n $SVP_DAST_TOKEN ]] || fail "log in the test user (status $status)"
export SVP_DAST_TOKEN
ok "test user registered and logged in"

results=$repo/.dast/$stamp
mkdir -p "$repo/.dast"
mkdir -m 700 "$results"
seed=${SVP_DAST_SEED:-$((RANDOM * 32768 + RANDOM))}

# 4. The run. Checks: no 5xx; status, content type, headers and body as the spec declares; 401 or 403 without a token
# or with a wrong one (ignored_auth); invalid input refused with a 4xx (negative_data_rejection). Left out:
# positive_data_acceptance (opaque cursors and server-side rules such as the upload limits reject input valid by the
# schema), use_after_free and ensure_resource_availability (need the stateful phase and links the spec does not have),
# object_level_authorization (needs two identities), missing_required_header (no required header besides the token,
# which ignored_auth covers), unsupported_method and allow_header_conformance (Go's ServeMux answers HEAD on every GET
# route, which the spec does not list). The probes are left out: they take no input, and /readyz is a 503 whenever a
# dependency flaps.
# Budget: 5 requests a second with one worker, 25 fuzzed cases per operation, which the gateway's rate limits (2 writes
# a second per user, burst 60) turn partly into 429s: declared in the spec, so they fail no check and only cost
# coverage, which summary.json measures. --rate-limit auto would wait out each Retry-After, minutes for register.
# SCHEMATHESIS_COVERAGE=false: the image's coverage plugin writes reports this run does not use. -w /tmp: anything else
# written to the working directory stays in the container.
echo "Schemathesis on the compose gateway (seed $seed); results in ${results#"$repo"/}"
started=$SECONDS
# The client runs in the background so that the time limit also covers the pull of a missing image, which docker run
# does before it creates the container. Not through docker_: env execs docker, so $! is the client's own pid, where a
# function would put a subshell in between.
env -u DOCKER_DEFAULT_PLATFORM docker run --rm --name "$container" --network svp_web --user "$(id -u):$(id -g)" -w /tmp \
  -e SVP_DAST_TOKEN -e SCHEMATHESIS_COVERAGE=false \
  -v "$spec:/schema/openapi.yaml:ro" -v "$repo/deploy/dast/schemathesis.toml:/config/schemathesis.toml:ro" \
  -v "$results:/reports" \
  "$SCHEMATHESIS_IMAGE" --no-color --config-file /config/schemathesis.toml \
  run /schema/openapi.yaml --url http://gateway:8080 \
  --phases examples,coverage,fuzzing --mode all \
  --checks not_a_server_error,status_code_conformance,content_type_conformance,response_schema_conformance,response_headers_conformance,ignored_auth,negative_data_rejection \
  --exclude-path /healthz --exclude-path /readyz \
  --rate-limit 5/s --max-examples 25 --workers 1 --request-timeout 10 --seed "$seed" --generation-database none \
  --output-sanitize true \
  --report json,junit,har --report-dir /reports --report-json-path /reports/report.json \
  --report-junit-path /reports/junit.xml --report-har-path /reports/requests.har \
  >"$results/schemathesis.log" 2>&1 &
client=$!
# Past the limit: stop the container if the client got as far as starting it, kill the client (still pulling, it then
# never creates the container), and remove a container the client started between the two. Stopping the container
# alone would leave a client that is still pulling free to start the scan late.
timed_out=false
while kill -0 "$client" 2>/dev/null; do
  if ((SECONDS - started >= timeout)); then
    timed_out=true
    docker_ stop -t 5 "$container" >/dev/null 2>&1 || true
    kill -KILL "$client" 2>/dev/null || true
    docker_ rm -f "$container" >/dev/null 2>&1 || true
    break
  fi
  sleep 1
done
rc=0
# The braces keep bash's notice of a killed client ("Killed: 9") off the terminal.
{ wait "$client" || rc=$?; } 2>/dev/null
client=
elapsed=$((SECONDS - started))

if [[ ! -s $results/report.json ]]; then
  if $timed_out; then
    fail "Schemathesis did not end within ${timeout} s (image pull included) and was stopped; lower --max-examples rather than the limit"
  fi
  fail "Schemathesis wrote no report.json (exit status $rc); read ${results#"$repo"/}/schemathesis.log on this machine"
fi

# 6. summary.json: requests by status, overall and by operation. Each request is matched to the operation of the spec
# whose path template has its length and its static segments; the operations are read from the spec's paths, written
# by hand at a fixed indentation. A method the spec does not declare on a path (the coverage phase sends some, expecting
# 405) counts as OTHER on that path.
operations=$(awk '
  /^paths:/ { in_paths = 1; next }
  in_paths && /^[^ #]/ { in_paths = 0 }
  in_paths && /^  \/[^ ]*:$/ { path = $1; sub(/:$/, "", path) }
  in_paths && /^    (get|put|post|patch|delete):$/ { m = $1; sub(/:$/, "", m); print toupper(m) " " path }
' "$spec" | jq -R -s 'split("\n") | map(select(. != "") | split(" ") | {method: .[0], path: .[1]})')
if [[ -s $results/requests.har ]]; then
  jq --argjson ops "$operations" --arg stamp "$stamp" --argjson seconds "$elapsed" --argjson rc "$rc" '
    def segments: ltrimstr("/") | split("/");
    def matches($template; $path):
      ($template | segments) as $t | ($path | segments) as $p
      | ($t | length) == ($p | length)
        and all(range(0; $t | length); ($t[.] | test("^[{].*[}]$")) or $t[.] == $p[.]);
    def by_status: group_by(.status) | map({key: (.[0].status | tostring), value: length}) | from_entries;
    def ratio_429: if length == 0 then 0 else (map(select(.status == 429)) | length) / length * 1000 | round / 1000 end;
    [.log.entries[]
      | (.request.url | sub("^[a-z]+://[^/]*"; "") | sub("[?#].*$"; "")) as $path
      | .request.method as $method
      | {status: .response.status,
         operation: (first($ops[] | select(.method == $method and matches(.path; $path)) | "\(.method) \(.path)")
                     // first($ops[] | select(matches(.path; $path)) | "OTHER \(.path)")
                     // "unmatched")}] as $requests
    | {run: $stamp, duration_seconds: $seconds, schemathesis_exit_status: $rc,
       requests: ($requests | length), status: ($requests | by_status), rate_limited_ratio: ($requests | ratio_429),
       operations: ($requests | group_by(.operation)
         | map({key: .[0].operation,
                value: {requests: length, status: by_status, rate_limited_ratio: ratio_429}}) | from_entries)}
  ' "$results/requests.har" >"$results/summary.json"
else
  jq -n --arg stamp "$stamp" --argjson seconds "$elapsed" --argjson rc "$rc" \
    '{run: $stamp, duration_seconds: $seconds, schemathesis_exit_status: $rc, requests: 0}' >"$results/summary.json"
fi

# The published files must hold no secret: a JWT (the presigned policy is base64 JSON too), the token fields, a
# presigned signature or credential, the web's session cookie, a Bearer header, or the test user's own token, which
# grep reads from a file descriptor instead of its command line. On a match the run fails naming the file and the
# pattern only, and prints nothing from the files.
leak=
for f in report.json summary.json; do
  for pattern in 'eyJ[A-Za-z0-9_-]{8,}' '"access_token"' '"refresh_token"' 'svp_sid' 'Bearer [A-Za-z0-9]'; do
    if grep -qE -- "$pattern" "$results/$f"; then
      echo "FAIL  ${results#"$repo"/}/$f matches $pattern" >&2
      leak=1
    fi
  done
  for pattern in 'X-Amz-Signature' 'X-Amz-Credential'; do
    if grep -qi -- "$pattern" "$results/$f"; then
      echo "FAIL  ${results#"$repo"/}/$f matches $pattern" >&2
      leak=1
    fi
  done
  if grep -qF -f <(printf '%s\n' "$SVP_DAST_TOKEN") "$results/$f"; then
    echo "FAIL  ${results#"$repo"/}/$f holds the test user's access token" >&2
    leak=1
  fi
done
[[ -z $leak ]] || fail "a published file holds a secret; nothing printed from it"
ok "no token, cookie or presigned form in report.json and summary.json"

# The summary, from the two clean files only.
jq -r '
  "version      \(.schemathesis_version)",
  "seed         \(.seed)",
  "exit status  \(.exit_code), stop reason \(.stop_reason)",
  "operations   \(.operations.tested // 0) tested of \(.operations.selected // 0) selected (\(.operations.total // 0) in the spec)",
  "test cases   \(.test_cases.generated) generated, \(.test_cases.with_failures) with failures, \(.test_cases.unique_failures) unique failures",
  (.failures[] | "failure      \(.code) \(.title): \(.count) (\(.operations | join(", ")))"),
  (.errors[] | "error        \(.title): \(.count)")
' "$results/report.json"
jq -r '
  "requests     \(.requests) in \(.duration_seconds) s",
  "status       \(.status // {} | to_entries | map("\(.key)=\(.value)") | join(" "))",
  "429 ratio    \(.rate_limited_ratio // 0)",
  (.operations // {} | to_entries[] | "  \(.key): \(.value.status | to_entries | map("\(.key)=\(.value)") | join(" "))")
' "$results/summary.json"

if $timed_out; then
  fail "Schemathesis ran over ${timeout} s (image pull included) and was stopped; lower --max-examples rather than the limit"
fi
case $rc in
  0) ok "Schemathesis: every check passed" ;;
  1)
    echo "FAIL  Schemathesis: a check failed (read ${results#"$repo"/}/schemathesis.log on this machine; seed $seed)" >&2
    exit 1
    ;;
  2)
    echo "FAIL  Schemathesis could not run (read ${results#"$repo"/}/schemathesis.log on this machine)" >&2
    exit 2
    ;;
  *)
    echo "FAIL  Schemathesis ended with status $rc (read ${results#"$repo"/}/schemathesis.log on this machine)" >&2
    exit 2
    ;;
esac
