#!/usr/bin/env bash
# Runs one verification scenario: its make targets in order, each under a time limit of its own, with its whole output
# in a file (docs/adr/0021-deferred-verification-stage6b.md, sections 2, 3 and 5). Same on the GitHub runner
# (.github/workflows/verify.yml) and on the rented Linux VM that stands in for it.
#
#   verify-run.sh compose-obs|dev-k3d
#
# The job's log is public, so a target's output never goes there: each writes to $SVP_VERIFY_OUT/logs/<NN>-<name>.log,
# and the log gets fixed lines only (target, limit, result, seconds). deploy/ci/verify-collect.sh later copies what
# passes its scan into the artifact and prints the end of each failed target's output from that copy. A target that
# exits non-zero is a result, not the end of the scenario (load-local over its latency threshold, web-lighthouse over
# its LCP budget): the next target still runs, and $SVP_VERIFY_OUT/results.tsv gets one line per target (id, name,
# ok|fail|timeout|skipped|cancelled, exit status, start and end in seconds since the epoch, seconds, note). Exits 1
# when any target was not ok.
#
# The first target builds what the others use (up for compose-obs, k8s-up for dev-k3d). When it is not ok, every
# later target is skipped at once with the note "infrastructure step failed": none of them can pass, and waiting for
# each to fail (the RAM steps wait 15 min for pods that never get Ready) only spends the job's time. The collect and
# upload steps of the job still run.
#
# SVP_VERIFY_TARGETS (the dispatch's input targets; empty: every target) names the targets to run, separated by
# spaces, each a name of the scenario's list (results.tsv shows them); the build target always runs. The others are
# skipped with the note "not in targets", which does not make the run fail, and keep their id, so a log is named the
# same in every run. A name that is not one of the scenario's, or a character other than a-z, 0-9, - and space, stops
# the script before any target starts (exit 2). A target that reads another's result still needs it: ram-peak
# without drill-k8s-keda is skipped, and fails the run; the others fail on their own, so name what they read with them:
# the READY video of smoke (k8s-smoke) for load-local and drill-k8s-threats, the reports of web-lighthouse-<n> for
# lcp, the run of k8s-web-e2e for drill-k8s-web-obs.
#
# Deadline: no target starts, and none runs, past the earlier of
#   - the job's start ($SVP_VERIFY_OUT/job-start, written by the job's first step) + SVP_VERIFY_JOB_MINUTES - 25 min,
#     the time the collect and upload steps keep;
#   - this script's start + SVP_VERIFY_STEP_MINUTES (the step's timeout-minutes) - 5 min, so it ends before GitHub
#     stops the step, with time to name the target that ran out and do what follows each target (below).
# Without those variables (the VM) the job's limit is 120 min for compose-obs and 330 for dev-k3d, counted from now. A
# target gets the smaller of its own limit and what is left; GNU timeout stops its whole process group, with 120 s
# more for the drills' traps to put the stack back, then kills it. While a disk-low mark of deploy/ci/verify-sample.sh
# exists, no target starts ("disk").
#
# After each target, once its result is in results.tsv: deploy/ci/verify-mask.sh env (make up OBS=lgtm and the k3d
# install add tokens to .env), and on k3d verify-mask.sh cluster while the cluster answers, and make k8s-traffic-stop
# when drill traffic still runs (a canary drill cut short leaves it running). Each under a time limit of its own (at
# most about 3 min together), so a cluster that no longer answers cannot hold the script past its deadline.
#
# Steps that are not a make target of their own, all reading what the targets left:
#   load-local (compose-obs)   waits until Alertmanager has no RateLimitFallbackActive alert (drill-obs-threats makes
#                              it fire on purpose), polls Alertmanager every 10 s through make load-local and 150 s
#                              after it (the rule's 2 m window and a margin), counting the polls it answered and those
#                              it did not, then reads from Prometheus (Grafana's datasource proxy) the gateway's p99
#                              Redis command time, its Redis commands that timed out, and its rate limit decisions, all
#                              and on the fallback counter, over the load, counting the queries it did not answer;
#                              rate-limit-load.json. Its exit status is that of make load-local
#   fallback-alert-under-load  fails when an alert RateLimitFallbackActive started during that window, and also when
#                              the evidence is missing: a poll of Alertmanager or a query of Prometheus that got no
#                              answer (Alertmanager lists an alert only while it fires, so a gap could hide one), or no
#                              rate limit decision of the gateway over the load. On the runner Redis is reached over
#                              Linux's bridge, not Docker Desktop's host.docker.internal, so a clean result is weak
#                              evidence; the promtool tests of the rule are the main check
#   web-lighthouse-<n>         make web-lighthouse, its manifest.json kept as manifest-<n>.json
#   lcp                        median LCP of / and /v/{id} over the three runs, with Lighthouse's benchmarkIndex;
#                              lcp.json; fails when a median is over 2500 ms
#   ram-rest-<label> (k3d)     the cluster at rest as ADR-0014 section 2 measures it: every pod Ready (or ended:
#                              Succeeded, Failed), 60 s, then the median of the next 6 samples of verify-sample.sh
#                              (10 s apart) of docker stats MEM USAGE of the k3d containers; anon, active_file and
#                              kernel of memory.stat of each node; kubectl top pods --containers, each container and
#                              summed by namespace, and kubectl top node; the window of those samples, to read
#                              samples/pods.tsv at rest by; ram-rest-<label>.json and .txt, the .txt with free -m of
#                              the runner at that point
#   ram-peak (k3d)             over the samples taken while drill-k8s-keda ran: the highest median of 6 samples in a row
#                              that each saw 2 Running media-worker pods, and the highest sample; ram-peak.json, .txt.
#                              Skipped when drill-k8s-keda did not run
#
# Linux only: GNU timeout and date -d.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$repo" || exit 1
# ci_temp_dir and the other ci_* functions: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
export SVP_VERIFY_OUT=$out repo here

scenario=${1:-}
case $scenario in
  compose-obs) job_minutes_default=120 build=up ;;
  dev-k3d) job_minutes_default=330 build=k8s-up ;;
  *)
    echo "FAIL  verify-run: unknown scenario '$scenario' (compose-obs, dev-k3d); nothing started" >&2
    exit 2
    ;;
esac
targets=${SVP_VERIFY_TARGETS:-}
case $targets in
  *[!a-z0-9\ -]*)
    # Not printed back: the job's log reads a line that starts with :: as a command.
    echo "FAIL  verify-run: SVP_VERIFY_TARGETS holds a character other than a-z, 0-9, - and space; nothing started" >&2
    exit 2
    ;;
esac
results=$out/results.tsv

now() { date +%s; }
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
digits() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

step_start=$(now)
job_start=$(cat "$out/job-start" 2>/dev/null) && digits "$job_start" || job_start=$step_start
job_minutes=${SVP_VERIFY_JOB_MINUTES:-$job_minutes_default}
digits "$job_minutes" || job_minutes=$job_minutes_default
deadline=$((job_start + job_minutes * 60 - 25 * 60))
if digits "${SVP_VERIFY_STEP_MINUTES:-}"; then
  step_deadline=$((step_start + SVP_VERIFY_STEP_MINUTES * 60 - 300))
  [ "$step_deadline" -lt "$deadline" ] && deadline=$step_deadline
fi
echo "verify-run $scenario: started $(utc "$step_start"); no target runs past $(utc "$deadline")"

n=0
not_ok=0
current=
timeout_pid=
last_log=
last_status=
last_start=0
last_end=0
# listing: set while the scenario's targets are only listed into names, before any runs (see the scenarios below).
listing=
names=
infra_failed=
unchosen_note="not in targets"

# chosen NAME: whether NAME runs in this run (see SVP_VERIFY_TARGETS in the header).
chosen() {
  [ -z "$targets" ] || [ "$1" = "$build" ] && return 0
  case " $targets " in *" $1 "*) return 0 ;; esac
  return 1
}

# record ID NAME STATUS EXIT START END NOTE
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(($6 - $5))" "$7" >>"$results"
  [ "$3" = ok ] || [ "$7" = "$unchosen_note" ] || not_ok=$((not_ok + 1))
  echo "[$1] $2: $3${4:+ (exit $4)}, $(($6 - $5)) s${7:+; $7}"
}

traffic_running() { [ "$scenario" = dev-k3d ] && timeout 10 deploy/k8s/drills/traffic.sh status >/dev/null 2>&1; }
cluster_answers() { timeout 15 kubectl --context k3d-svp --request-timeout=10s get --raw /readyz >/dev/null 2>&1; }
# traffic_stop LOG: stops the drill traffic (traffic.sh waits 20 s at most for it), its output appended to LOG.
traffic_stop() { timeout 60 make -s k8s-traffic-stop >>"${1:-/dev/null}" 2>&1; }

# after LOG: what follows every target (see the header). Mask lines go to this script's stdout, the job's log.
after() {
  timeout 30 "$here/verify-mask.sh" env || echo "verify-run: verify-mask.sh env failed"
  if [ "$scenario" = dev-k3d ] && cluster_answers; then
    # Five namespaces, each read within 10 s.
    timeout 60 "$here/verify-mask.sh" cluster || echo "verify-run: verify-mask.sh cluster failed"
  fi
  if traffic_running; then
    echo "verify-run: drill traffic still running; make k8s-traffic-stop"
    traffic_stop "$1" || echo "verify-run: make k8s-traffic-stop failed"
  fi
}

# On a cancelled run or when GitHub stops the step: stop the target, name it, stop the drill traffic.
on_signal() {
  trap - INT TERM
  if [ -n "$timeout_pid" ]; then
    kill -TERM "$timeout_pid" 2>/dev/null
    wait "$timeout_pid" 2>/dev/null
  fi
  if [ -n "$current" ]; then
    # shellcheck disable=SC2086 # current holds "ID NAME START"
    set -- $current
    record "$1" "$2" cancelled "" "$3" "$(now)" "the run was cancelled or the step timed out"
  fi
  traffic_running && traffic_stop "$last_log"
  exit 130
}
trap on_signal INT TERM

# skip NAME NOTE: records NAME as the next target, skipped for NOTE; for "not in targets" instead when NAME is not
# chosen, and for "infrastructure step failed" once the build target was not ok (see the header).
skip() {
  local t note=$2
  if [ -n "$listing" ]; then
    names="$names $1"
    return
  fi
  t=$(now)
  n=$((n + 1))
  last_status=skipped
  if ! chosen "$1"; then
    note=$unchosen_note
  elif [ -n "$infra_failed" ]; then
    note="infrastructure step failed"
  fi
  record "$(printf '%02d' "$n")" "$1" skipped "" "$t" "$t" "$note"
}

# step NAME LIMIT_MINUTES COMMAND...: runs COMMAND as the next target (see the header).
step() {
  local name=$1 limit=$(($2 * 60)) id start end rc status note= log left
  shift 2
  if [ -n "$listing" ] || ! chosen "$name" || [ -n "$infra_failed" ]; then
    skip "$name" ""
    return
  fi
  if [ -e "$out/disk-low" ]; then
    skip "$name" "disk: free space under 15% + 1 GiB"
    return
  fi
  start=$(now)
  left=$((deadline - start))
  if [ "$left" -lt 60 ]; then
    skip "$name" deadline
    return
  fi
  n=$((n + 1))
  id=$(printf '%02d' "$n")
  log=$out/logs/$id-$name.log
  if [ "$limit" -gt "$left" ]; then
    limit=$left
    note="limit cut to ${left} s by the deadline"
  fi
  echo "[$id] $name: started $(utc "$start"), limit $limit s"
  current="$id $name $start"
  last_log=$log
  timeout --kill-after=120 "$limit" "$@" >"$log" 2>&1 </dev/null &
  timeout_pid=$!
  wait "$timeout_pid"
  rc=$?
  timeout_pid=
  end=$(now)
  case $rc in
    0) status=ok ;;
    124 | 137) status=timeout note="${note:+$note; }stopped after $limit s" ;;
    *) status=fail ;;
  esac
  current=
  last_start=$start last_end=$end last_status=$status
  record "$id" "$name" "$status" "$rc" "$start" "$end" "$note"
  [ "$name" = "$build" ] && [ "$status" != ok ] && infra_failed=1
  after "$log"
}

# --- Steps of their own; exported, since timeout runs them in a new bash.

# load_local_watch: see load-local in the header. Runs in a bash of its own (timeout), without this script's options.
load_local_watch() {
  local am=http://127.0.0.1:9093/api/v2/alerts prom=http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus
  local filter='alertname="RateLimitFallbackActive"' tmp start end rc poller deadline cleared=false w m redis
  local q_p99 q_timeouts q_fallback q_decisions p99 timeouts fallback decisions prom_failed=0
  tmp=$(mktemp -d)
  # am_alerts FILE [CURL ARGS...]: the alerts of RateLimitFallbackActive into FILE as one JSON list; fails when
  # Alertmanager does not answer with one.
  am_alerts() {
    local file=$1
    shift
    curl -sS -G --fail --max-time 10 "$am" --data-urlencode "filter=$filter" "$@" -o "$file.raw" &&
      jq -c 'if type == "array" then . else error("not a list of alerts") end' "$file.raw" >"$file"
  }
  # am_poll: one poll of the watch: its alerts appended to alerts.jsonl, "<time> ok" or "<time> failed" to polls.
  am_poll() {
    if am_alerts "$tmp/poll"; then
      jq -c '.[]' "$tmp/poll" >>"$tmp/alerts.jsonl"
      echo "$(date +%s) ok" >>"$tmp/polls"
    else
      echo "$(date +%s) failed" >>"$tmp/polls"
    fi
  }
  deadline=$(($(date +%s) + 300))
  while :; do
    if am_alerts "$tmp/now" --data-urlencode active=true --data-urlencode silenced=false \
      --data-urlencode inhibited=false && [ "$(jq length "$tmp/now")" = 0 ]; then
      cleared=true
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "RateLimitFallbackActive still active (or Alertmanager not answering) after 300 s; load starts anyway"
      break
    fi
    sleep 10
  done
  : >"$tmp/polls"
  start=$(date +%s)
  (while :; do
    am_poll
    sleep 10
  done) &
  poller=$!
  make load-local
  rc=$?
  end=$(date +%s)
  echo "make load-local: exit $rc; watching Alertmanager 150 s more"
  sleep 150
  kill "$poller" 2>/dev/null
  wait "$poller" 2>/dev/null
  am_poll
  # promql EXPR: the value of the first sample at the end of the load, "none" when the query has no sample; fails when
  # Prometheus does not answer it.
  promql() {
    curl -sS -G --fail --max-time 20 "$prom/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$end" \
      -o "$tmp/prom.json" &&
      jq -r 'if .status == "success" then (.data.result[0].value[1] // "none") else error("query failed") end' \
        "$tmp/prom.json"
  }
  # Each query built first: a selector such as {a="x",b="y"} inside a nested "$(... "...")" is brace-expanded by bash.
  w=$((end - start))
  m=db_client_connections_use_time_milliseconds
  redis='service_name="gateway",db_system="redis"'
  printf -v q_p99 'histogram_quantile(0.99, sum by (le) (increase(%s_bucket{%s,type="command"}[%ss])))' "$m" "$redis" "$w"
  printf -v q_timeouts 'sum(increase(%s_count{%s,error_type="context_timeout"}[%ss]))' "$m" "$redis" "$w"
  printf -v q_fallback 'sum(increase(svp_ratelimit_decisions_total{service_name="gateway",store="fallback"}[%ss]))' "$w"
  printf -v q_decisions 'sum(increase(svp_ratelimit_decisions_total{service_name="gateway"}[%ss]))' "$w"
  p99=$(promql "$q_p99") || { p99=null prom_failed=$((prom_failed + 1)); }
  timeouts=$(promql "$q_timeouts") || { timeouts=null prom_failed=$((prom_failed + 1)); }
  fallback=$(promql "$q_fallback") || { fallback=null prom_failed=$((prom_failed + 1)); }
  decisions=$(promql "$q_decisions") || { decisions=null prom_failed=$((prom_failed + 1)); }
  jq -n --argjson start "$start" --argjson end "$end" --argjson rc "$rc" --argjson cleared "$cleared" \
    --slurpfile alerts <(cat "$tmp/alerts.jsonl" 2>/dev/null) --rawfile polls "$tmp/polls" \
    --arg p99 "$p99" --arg timeouts "$timeouts" --arg fallback "$fallback" --arg decisions "$decisions" \
    --argjson prom_failed "$prom_failed" --argjson watched "$(($(date +%s) - start))" '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    # A value of Prometheus: a number, "none" (the query had no sample) or null (Prometheus did not answer).
    def value: if . == "null" then null else (tonumber? // .) end;
    ($alerts | map(select((.startsAt | epoch) >= $start)) | unique_by(.fingerprint)) as $new |
    ($polls | split("\n") | map(select(length > 0) | split(" ")[1])) as $p |
    {
      load_start: ($start | todate), load_end: ($end | todate), watched_seconds: $watched, load_local_exit: $rc,
      alertmanager: {cleared_before_load: $cleared, polls_ok: ($p | map(select(. == "ok")) | length),
        polls_failed: ($p | map(select(. == "failed")) | length)},
      prometheus_queries_failed: $prom_failed,
      fallback_alerts: ($new | length),
      fallback_alerts_started: ($new | map(.startsAt)),
      gateway_redis_command_p99_ms: ($p99 | value), gateway_redis_context_timeouts: ($timeouts | value),
      gateway_fallback_decisions: ($fallback | value), gateway_rate_limit_decisions: ($decisions | value),
      note: "Redis is reached over the Linux bridge on the runner, not host.docker.internal of Docker Desktop: no false page here is weak evidence; the promtool tests of the rule are the main check"
    }' >"$SVP_VERIFY_OUT/rate-limit-load.json"
  rm -rf "$tmp"
  cat "$SVP_VERIFY_OUT/rate-limit-load.json"
  return "$rc"
}

# fallback_alert_check: see fallback-alert-under-load in the header; one line per reason it fails.
fallback_alert_check() {
  local problems
  problems=$(jq -r '
    (if .alertmanager.polls_ok == 0 then "Alertmanager answered no poll during the load" else empty end),
    (if .alertmanager.polls_failed > 0
      then "Alertmanager did not answer \(.alertmanager.polls_failed) poll(s): an alert could have fired unseen"
      else empty end),
    (if .prometheus_queries_failed > 0 then "Prometheus did not answer \(.prometheus_queries_failed) query(ies)"
      else empty end),
    (if (.gateway_rate_limit_decisions | type) != "number" or .gateway_rate_limit_decisions <= 0
      then "Prometheus shows no rate limit decision of the gateway over the load" else empty end),
    (if .fallback_alerts > 0 then "RateLimitFallbackActive started \(.fallback_alerts) time(s) during the load"
      else empty end)' "$SVP_VERIFY_OUT/rate-limit-load.json") || {
    echo "FAIL  no rate-limit-load.json to read (load-local did not finish)"
    return 1
  }
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/FAIL  /'
    return 1
  fi
  echo "ok    no RateLimitFallbackActive started during the load; Alertmanager answered every poll"
}

# lighthouse_run N: make web-lighthouse, its manifest kept as manifest-N.json (each run writes manifest.json anew).
lighthouse_run() {
  local rc dir=web/test-results/lighthouse
  make web-lighthouse
  rc=$?
  [ -f "$dir/manifest.json" ] && mv "$dir/manifest.json" "$dir/manifest-$1.json"
  return "$rc"
}

# lcp_median: see lcp in the header.
lcp_median() {
  local dir=web/test-results/lighthouse reports
  reports=$(jq -r '.[].jsonPath' "$dir"/manifest-*.json) || return 1
  [ -n "$reports" ] || { echo "no Lighthouse report"; return 1; }
  # shellcheck disable=SC2086 # one path per line, none with a blank (lhci names them)
  jq -s '
    def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
      else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    map({page: (.requestedUrl | sub("^https?://[^/]+"; "") | if startswith("/v/") then "/v/{id}" else . end),
      lcp: .audits["largest-contentful-paint"].numericValue, benchmark: .environment.benchmarkIndex})
    | group_by(.page) | map({page: .[0].page, runs: length, lcp_median_ms: (map(.lcp) | median | round),
      lcp_ms: map(.lcp | round), benchmark_index: map(.benchmark), within_2500_ms: ((map(.lcp) | median) <= 2500)})' \
    $reports >"$SVP_VERIFY_OUT/lcp.json" || return 1
  cat "$SVP_VERIFY_OUT/lcp.json"
  jq -e 'length > 0 and all(.within_2500_ms)' "$SVP_VERIFY_OUT/lcp.json" >/dev/null
}

kc() { kubectl --context k3d-svp "$@"; }

# not_ready: the pods that have not ended (Succeeded or Failed) and are not Running with every container ready. A
# Failed pod never becomes Ready (an evicted pod, the pod of a hook Job with backoffLimit 0), so waiting for it would
# only spend the step's limit; an eviction shows in samples/events.tsv.
not_ready() {
  kc get pods -A -o json | jq '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.status.phase != "Running" or any(.status.containerStatuses[]?; .ready | not))] | length'
}

# ram_rest LABEL: see ram-rest in the header.
ram_rest() {
  local label=$1 left ready_at samples node free_m file=$SVP_VERIFY_OUT/ram-rest-$1
  until left=$(not_ready) && [ "$left" = 0 ]; do
    echo "pods not ready: ${left:-unknown}"
    sleep 10
  done
  ready_at=$(date +%s)
  echo "every pod Ready or ended at $(date -u -d "@$ready_at" +%H:%M:%SZ); resting 60 s"
  sleep 60
  # Each sample "<time> <MiB>".
  until samples=$(awk -F '\t' -v t=$((ready_at + 60)) '$1 >= t && $2 != "" { print $1, $2 }' \
    "$SVP_VERIFY_OUT/samples/docker.tsv" | head -n 6) && [ "$(printf '%s\n' "$samples" | grep -c .)" = 6 ]; do
    sleep 10
  done
  free_m=$(free -m) || return 1
  for node in k3d-svp-server-0 k3d-svp-agent-0; do
    env -u DOCKER_DEFAULT_PLATFORM docker exec "$node" cat /sys/fs/cgroup/memory.stat |
      awk -v n="$node" '$1 == "anon" || $1 == "active_file" || $1 == "kernel" { printf "%s\t%s\t%s\n", n, $1, $2 }'
  done >"$file.stat" || return 1
  kc top pods -A --containers --no-headers >"$file.pods" || return 1
  kc top node --no-headers >"$file.nodes" || return 1
  jq -n --arg label "$label" --argjson ready "$ready_at" --arg samples "$samples" \
    --rawfile stat "$file.stat" --rawfile pods "$file.pods" --rawfile nodes "$file.nodes" '
    def mib: capture("^(?<n>[0-9.]+)(?<u>[KMG]i)?$") | (.n | tonumber) * ({"Ki": (1 / 1024), "Mi": 1, "Gi": 1024}[.u // "Mi"]);
    def median: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    def rows($s): $s | split("\n") | map(select(length > 0) | [splits("[ \t]+")]);
    (rows($samples) | map(map(tonumber))) as $t |
    ($t | map(.[1])) as $s |
    (rows($stat) | map({node: .[0], key: .[1], mib: ((.[2] | tonumber) / 1048576)})) as $mem |
    ($mem | map(select(.key == "active_file") | .mib) | add) as $active |
    (rows($pods) | map({namespace: .[0], pod: .[1], container: .[2], cpu_m: (.[3] | sub("m$"; "") | tonumber),
      memory_mib: (.[4] | mib | round)})) as $containers |
    ($containers | group_by(.namespace) | map({key: .[0].namespace, value: (map(.memory_mib) | add)}) | from_entries) as $ns |
    ($s | median) as $usage |
    {
      label: $label, ready_at: ($ready | todate), rest_seconds: 60,
      window: {from: ($t[0][0] | todate), to: ($t[-1][0] | todate)},
      mem_usage_samples_mib: $s, mem_usage_median_mib: $usage,
      nodes_memory_stat_mib: ($mem | map({(.node + " " + .key): (.mib | round)}) | add),
      mem_usage_minus_active_file_mib: ($usage - $active | round),
      pods_mib_by_namespace: $ns, pods_total_mib: ($ns | [.[]] | add), containers: $containers,
      top_node: (rows($nodes) | map({node: .[0], cpu: .[1], memory: .[3]})),
      budget: {rest_gib: 6.5, peak_gib: 8.7, pods_gib: 4.7},
      rest_b_reached: (($usage - $active) < 6.5 * 1024 and ($ns | [.[]] | add) <= 4.7 * 1024)
    }' >"$file.json" || return 1
  rm -f "$file.stat" "$file.pods" "$file.nodes"
  {
    jq -r '"RAM at rest (\(.label)): MEM USAGE median \(.mem_usage_median_mib) MiB, minus active_file \(.mem_usage_minus_active_file_mib) MiB, pods \(.pods_total_mib) MiB; (b) reached: \(.rest_b_reached)",
      (.pods_mib_by_namespace | to_entries[] | "  \(.key): \(.value) MiB")' "$file.json"
    printf 'free -m of the runner at rest:\n%s\n' "$free_m"
  } | tee "$file.txt"
}

# ram_peak START END: see ram-peak in the header.
ram_peak() {
  local file=$SVP_VERIFY_OUT/ram-peak
  awk -F '\t' -v a="$1" -v b="$2" '$1 >= a && $1 <= b' "$SVP_VERIFY_OUT/samples/docker.tsv" |
    jq -R -s --argjson start "$1" --argjson end "$2" '
    def median: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    split("\n") | map(select(length > 0) | split("\t") | {t: (.[0] | tonumber), mib: (.[1] | tonumber), workers: .[5]}) as $r |
    [range(0; ($r | length) - 5) | $r[.:. + 6] | select(all(.workers == "2")) | {from: (.[0].t | todate), median: (map(.mib) | median)}] as $w |
    {
      window: {start: ($start | todate), end: ($end | todate)}, samples: ($r | length),
      samples_with_2_workers: ($r | map(select(.workers == "2")) | length),
      windows_of_6_with_2_workers: ($w | length),
      peak_median_of_6_mib: ($w | map(.median) | max), peak_window_from: ($w | max_by(.median) | .from),
      highest_sample_mib: ($r | map(.mib) | max),
      peak_within_8_7_gib: ($w | map(.median) | max | if . == null then null else . < 8.7 * 1024 end),
      note: "workers counts the Running media-worker pods of each sample, taken as both transcoding while drill-k8s-keda runs"
    }' >"$file.json" || return 1
  jq -r '"RAM peak during drill-k8s-keda: median of 6 with 2 workers \(.peak_median_of_6_mib) MiB (\(.windows_of_6_with_2_workers) window(s)), highest sample \(.highest_sample_mib) MiB, within 8.7 GiB: \(.peak_within_8_7_gib)"' \
    "$file.json" | tee "$file.txt"
}
export -f load_local_watch fallback_alert_check lighthouse_run lcp_median kc not_ready ram_rest ram_peak

# --- The scenarios (docs/adr/0021-deferred-verification-stage6b.md, section 5). Called twice: with listing set, step
# and skip only add each name to names, which SVP_VERIFY_TARGETS is checked against; then for the run.
scenario_targets() {
  case $scenario in
    compose-obs)
      step up 40 make up OBS=lgtm
      step smoke 15 make smoke
      step drill-obs-threats 30 make drill-obs-threats
      step load-local 25 bash -c load_local_watch
      step fallback-alert-under-load 1 bash -c fallback_alert_check
      for i in 1 2 3; do step "web-lighthouse-$i" 10 bash -c 'lighthouse_run "$1"' _ "$i"; done
      step lcp 1 bash -c lcp_median
      # Last: not in the ADR's list for this scenario, and the longest wait (an alert of an earlier run must resolve
      # first), so the deadline cuts it before anything else.
      step drill-alert-to-sentry 40 make drill-alert-to-sentry
      ;;
    dev-k3d)
      step k8s-up 60 make k8s-up
      step k8s-smoke 15 make k8s-smoke
      step ram-rest-start 15 bash -c 'ram_rest start'
      step drill-k8s-threats 30 make drill-k8s-threats
      step drill-k8s-pdb 20 make drill-k8s-pdb
      step drill-k8s-canary 30 make drill-k8s-canary
      step k8s-web-sourcemaps 20 make k8s-web-sourcemaps
      step k8s-web-e2e 40 env SVP_E2E_GLITCHTIP=1 make k8s-web-e2e
      step drill-k8s-web-obs 15 make drill-k8s-web-obs
      step drill-k8s-keda 40 make drill-k8s-keda N=9
      if [ "$last_status" = skipped ]; then
        skip ram-peak "drill-k8s-keda did not run"
      else
        step ram-peak 2 bash -c 'ram_peak "$1" "$2"' _ "$last_start" "$last_end"
      fi
      step drill-k8s-backup 40 make drill-k8s-backup MODE=latest
      step drill-k8s-backup-pitr 40 make drill-k8s-backup MODE=pitr
      step ram-rest-end 15 bash -c 'ram_rest end'
      ;;
  esac
}

listing=1
scenario_targets
listing=
unknown=
# shellcheck disable=SC2086 # targets holds only a-z, 0-9, - and spaces (checked above): split on spaces, no glob
for t in $targets; do
  case "$names " in *" $t "*) ;; *) unknown="$unknown $t" ;; esac
done
if [ -n "$unknown" ]; then
  echo "FAIL  verify-run: not a target of $scenario:$unknown (its targets:$names); nothing started" >&2
  exit 2
fi
mkdir -p "$out/logs" || exit 1
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$results"
[ -n "$targets" ] && echo "verify-run $scenario: targets $build $targets; the others are skipped"
scenario_targets

echo "verify-run $scenario: $n target(s), $not_ok not ok (results.tsv; the outputs reach the artifact after verify-collect.sh)"
[ "$not_ok" = 0 ]
