#!/usr/bin/env bash
# `make drill-k8s-web-obs`: what the web client leaves in the observability stack of cluster svp after
# `make k8s-web-e2e` (docs/adr/0019-web-k3d-supply-chain-observability.md, sections 7, 8, 10 and 11). Read only.
#   1. trace   Tempo holds a trace of the last hour with spans of service.name=web and of service.name=gateway: the
#              web's call to the gateway carried its trace context, and the gateway (TRUST_TRACE_CONTEXT=true) went
#              on in the same trace. The newest such trace is printed with its span count per service.
#   2. rum     Prometheus holds the web-vitals histograms of service_name="web": LCP and CLS must have samples, INP
#              only when the run had an interaction (a page that saw none sends no INP), so INP without samples is
#              SKIP while a failed query is FAIL. Every series' route label is one of the closed set of
#              server/telemetry/vitals.ts. p75 of each metric is printed, over all routes and per route, from the
#              cumulative buckets (a series the e2e run made may hold a single sample, which increase() cannot read).
#   3. errors  the GlitchTip event that web/e2e/glitchtip.e2e.ts found (web/test-results/glitchtip-<project>.json of
#              `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` on k3d) is there, tagged service=web and runtime=browser, with
#              frames mapped to the web's source (turbopack:///[project]/...), read again through the API.
# Each check prints PASS, FAIL (or SKIP for INP) and the table at the end; a FAIL does not stop the next check. Exit 1
# when any check failed.
#
# Tempo, Prometheus and GlitchTip have no address on the host: each is reached through a port-forward of its own on
# 127.0.0.1 (13200, 19090, 8000), opened before the checks and stopped by its pid when the script ends; a port that
# is taken stops the script, naming it. GlitchTip's read-only API token (event:read, project:read) is read from Secret
# svp-obs/glitchtip-api into a shell variable and goes to curl on stdin only, never printed or on a command line.
# Nothing is written to the cluster and no rate limit key is touched.
set -euo pipefail

# Read only: deploy/k8s/drills/lib.sh then leaves out deploy/compose/lib.sh, which deletes rate limit keys.
drill_read_only=1
# shellcheck source=deploy/k8s/drills/lib.sh
. "$(dirname "$0")/lib.sh"

tempo_port=13200
glitchtip_port=8000
tempo_url=http://127.0.0.1:$tempo_port
glitchtip_url=http://127.0.0.1:$glitchtip_port
results_dir=$repo_root/web/test-results
# Seconds back from now that Tempo is searched.
trace_window=3600
# The route label values of server/telemetry/vitals.ts.
routes='/ /following /login /register /me /upload /u/[handle] /v/[id]'

tempo_pid=
glitchtip_pid=
stop_forwards() {
  prometheus_stop
  local pid
  for pid in "$tempo_pid" "$glitchtip_pid"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  tempo_pid=
  glitchtip_pid=
}
trap 'stop_forwards; rm -rf "$work"' EXIT

# forward SERVICE LOCAL:REMOTE: a port-forward to service SERVICE of svp-obs on 127.0.0.1:LOCAL in the background;
# sets forward_pid. kubectl itself, not the kc function: $! of a function in the background would be a subshell's pid.
forward() {
  port_free "${2%%:*}" || fail "127.0.0.1:${2%%:*} is in use (another port-forward?); free it and run again"
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 "service/$1" "$2" >"$work/forward-$1.log" 2>&1 &
  forward_pid=$!
}

prometheus_forward
forward tempo "$tempo_port:3200"
tempo_pid=$forward_pid
wait_until 30 "port-forward to Tempo on 127.0.0.1:$tempo_port" curl -sf --max-time 2 "$tempo_url/ready"
forward glitchtip "$glitchtip_port:8000"
glitchtip_pid=$forward_pid
wait_until 30 "port-forward to GlitchTip on 127.0.0.1:$glitchtip_port" curl -sf --max-time 2 "$glitchtip_url/_health/"

# --- 1. A trace through the web and the gateway.
check_trace() {
  local end start id services
  end=$(date +%s)
  start=$((end - trace_window))
  curl -sf --max-time 20 -G "$tempo_url/api/search" --data-urlencode \
    'q={ resource.service.name = "web" } && { resource.service.name = "gateway" }' \
    --data-urlencode "start=$start" --data-urlencode "end=$end" --data-urlencode limit=20 >"$work/tempo-search.json" ||
    fail "Tempo search answers"
  id=$(jq -r '[.traces[]? | select(.traceID | test("^[0-9a-f]+$"))] | max_by(.startTimeUnixNano | tonumber) | .traceID // ""' \
    "$work/tempo-search.json")
  [ -n "$id" ] ||
    fail "Tempo has no trace of the last $trace_window s with spans of both web and gateway (run make k8s-web-e2e first)"
  curl -sf --max-time 20 "$tempo_url/api/traces/$id" >"$work/trace.json" || fail "Tempo returns trace $id"
  # Tempo's JSON is OTLP: resource spans under batches (v1 API) or trace.resourceSpans; spans under scopeSpans (or
  # the older instrumentationLibrarySpans).
  services=$(jq -r '
    [(.batches // .trace.resourceSpans // .resourceSpans // [])[]
     | {service: ([.resource.attributes[]? | select(.key == "service.name") | .value.stringValue][0] // "?"),
        spans: ([(.scopeSpans // .instrumentationLibrarySpans // [])[] | .spans[]?] | length)}]
    | group_by(.service) | map("\(.[0].service)=\(map(.spans) | add)") | join(" ")' "$work/trace.json")
  [[ " $services " == *" web="* && " $services " == *" gateway="* ]] ||
    fail "trace $id holds spans of web and gateway (spans per service: ${services:-none})"
  ok "trace $id: spans per service $services"
}

# --- 2. The web-vitals histograms.
# rum_metric NAME REQUIRED: NAME is the Prometheus name without _bucket/_count (svp_web_vital_lcp_seconds); REQUIRED 1
# fails without samples, 0 prints SKIP: no samples is not an error then, a query that fails still is.
rum_metric() {
  local name=$1 sel="{service_name=\"web\"}" count bad p75 per_route
  count=$(promql "sum(${name}_count$sel)") || fail "Prometheus query of ${name}_count answers"
  count=$(jq -r '.[0].value[1] // "0"' <<<"$count")
  if awk -v v="$count" 'BEGIN { exit !(v + 0 == 0) }'; then
    if [ "$2" = 1 ]; then
      fail "$name has no samples of service web (run make k8s-web-e2e first)"
    fi
    echo "SKIP  $name has no samples: the run recorded no interaction"
    return 0
  fi
  promql "count by (route) (${name}_count$sel)" >"$work/routes.json" || fail "Prometheus query of ${name} routes answers"
  bad=$(jq -r --arg ok "$routes" '($ok | split(" ")) as $set | [.[] | .metric.route // "<none>" | select(. as $r | $set | index($r) | not)] | unique | join(", ")' \
    "$work/routes.json")
  [ -z "$bad" ] || fail "$name has route labels outside the closed set: $bad"
  p75=$(promql "histogram_quantile(0.75, sum by (le) (${name}_bucket$sel))") || fail "Prometheus p75 of $name answers"
  p75=$(jq -r '.[0].value[1] // "?"' <<<"$p75")
  per_route=$(promql "histogram_quantile(0.75, sum by (le, route) (${name}_bucket$sel))") ||
    fail "Prometheus p75 of $name by route answers"
  per_route=$(jq -r 'sort_by(.metric.route) | map("\(.metric.route) \(.value[1])") | join(", ")' <<<"$per_route")
  ok "$name: $count samples, p75 $p75 (by route: $per_route)"
}
check_rum() {
  rum_metric svp_web_vital_lcp_seconds 1
  rum_metric svp_web_vital_cls 1
  rum_metric svp_web_vital_inp_seconds 0
}

# --- 3. The browser error in GlitchTip.
# glitchtip_get PATH OUT: GET PATH of the GlitchTip API with the read-only token into OUT; prints the HTTP status.
glitchtip_get() {
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -sS --max-time 10 -H @- -o "$2" -w '%{http_code}' "$glitchtip_url$1" || true
}
check_errors() {
  local file project stack id status sources n=0
  token=$(kc -n svp-obs get secret glitchtip-api --ignore-not-found -o jsonpath='{.data.SENTRY_AUTH_TOKEN}' |
    base64 -d) || fail "read Secret svp-obs/glitchtip-api"
  [ -n "$token" ] || fail "Secret svp-obs/glitchtip-api has no SENTRY_AUTH_TOKEN; run make k8s-glitchtip-init first"
  for project in chromium webkit; do
    file=$results_dir/glitchtip-$project.json
    [ -f "$file" ] || continue
    stack=$(jq -r '.stack // ""' "$file")
    [ "$stack" = k3d ] ||
      fail "web/test-results/glitchtip-$project.json is from the $stack stack; run SVP_E2E_GLITCHTIP=1 make k8s-web-e2e"
    id=$(jq -r '.event_id // ""' "$file")
    [[ $id =~ ^[0-9a-f]{32}$ ]] || fail "web/test-results/glitchtip-$project.json holds an event id (got '$id')"
    status=$(glitchtip_get "/api/0/projects/svp/svp/events/$id/" "$work/event.json")
    [ "$status" = 200 ] || fail "GlitchTip GET event $id ($project) is 200 (status $status)"
    jq -e '([.tags[]? | select(.key == "service") | .value] == ["web"]) and
      ([.tags[]? | select(.key == "runtime") | .value] == ["browser"])' "$work/event.json" >/dev/null ||
      fail "GlitchTip event $id ($project) has tags service=web and runtime=browser"
    sources=$(jq -r '
      [((.entries // [])[] | select(.type == "exception") | .data.values[]?), (.exception.values[]?)]
      | .[0].stacktrace.frames // [] | map(.filename // .absPath // .abs_path // "")
      | "\(map(select(test("(^|/)\\[project\\]/|^web/"))) | length) of \(length)"' "$work/event.json")
    [[ $sources != 0\ of* ]] || fail "GlitchTip event $id ($project) has frames mapped to the web's source ($sources)"
    ok "GlitchTip event $id ($project): $sources frames mapped to the web's source"
    n=$((n + 1))
  done
  token=
  [ "$n" -gt 0 ] || fail "no web/test-results/glitchtip-<project>.json: run SVP_E2E_GLITCHTIP=1 make k8s-web-e2e first"
}

# run_check NAME FUNCTION: runs FUNCTION in a subshell, so that its fail ends only that check, and records the result.
results=()
run_check() {
  local rc
  echo "--- $1"
  set +e
  (
    set -e
    "$2"
  )
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    echo "PASS  $1"
    results+=("PASS  $1")
  else
    echo "FAIL  $1"
    results+=("FAIL  $1")
  fi
}

run_check trace check_trace
run_check rum check_rum
run_check errors check_errors

echo "drill-k8s-web-obs:"
failed=0
for line in "${results[@]}"; do
  echo "  $line"
  [[ $line != FAIL* ]] || failed=1
done
exit "$failed"
