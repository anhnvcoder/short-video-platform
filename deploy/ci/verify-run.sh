#!/usr/bin/env bash
# Runs one verification scenario: its make targets in order, each under a time limit of its own, with its whole output
# in a file. Same on the GitHub runner
# (.github/workflows/verify.yml) and on the rented Linux VM that stands in for it.
#
#   verify-run.sh compose-obs|dev-k3d|gitops|web-canary|k6-cloud-mini|chaos|velero
#
# The targets of each scenario, in order, are in a file of their own, deploy/ci/verify/<scenario>.sh, which this script
# sources (each has its own owner, and seven in one file would be too long to review). A scenario file sets build (the
# name of its first target, which builds what the others use), job_minutes_default (the job's limit when
# SVP_VERIFY_JOB_MINUTES is not set) and k3d (1 when its targets run on cluster k3d-svp, 0 otherwise), may define
# helpers of its own (exported when a step runs them through bash -c), and defines scenario_targets, its targets in
# order through step and skip below. It may read names (every target of its list, once listed) and call chosen (below)
# while its targets run. It sets no other variable of this script, and its own are local to its functions
# with names apart from this script's: step and skip see a caller's locals (bash scopes dynamically), so a local n in
# scenario_targets would take the place of the target count. A name not in the list of this script, a missing file, a
# file that does not declare those, or one whose first target is not its build target stops the script before
# anything starts (exit 2).
#
# The job's log is public, so a target's output never goes there: each writes to $SVP_VERIFY_OUT/logs/<NN>-<name>.log,
# and the log gets fixed lines only (target, limit, result, seconds). deploy/ci/verify-collect.sh later copies what
# passes its scan into the artifact and prints the end of each failed target's output from that copy. A target that
# exits non-zero is a result, not the end of the scenario (load-local over its latency threshold, web-lighthouse over
# its LCP budget): the next target still runs, and $SVP_VERIFY_OUT/results.tsv gets one line per target (id, name,
# ok|fail|timeout|skipped|cancelled, exit status, start and end in seconds since the epoch, seconds, note). Exits 1
# when any target was not ok. Once the last target has its line, $SVP_VERIFY_OUT/run-end gets the time: without it the
# run was cut short (cancelled, or the step stopped by its timeout-minutes) and results.tsv may lack the target that
# was running and every later one, so deploy/ci/verify-sample.sh does not count the run as ended in time.
#
# Before the first target of a k3d scenario: make gitops-clone, main of the deployment configuration svp-gitops cloned
# anonymously into .gitops/svp-gitops of the checkout (base/ and components.json for make k8s-up, all of it for make
# k8s-gitops-up), and SVP_GITOPS_DIR exported to it for every target (deploy/k8s/lib.sh, gitops_dir). No target can
# pass without it: when the clone fails nothing starts (exit 1).
#
# The first target builds what the others use (the scenario file's build: up for compose-obs, k8s-gitops-up for gitops,
# k8s-up for the other k3d scenarios). When it is not ok, every later target is skipped at once with the note
# "infrastructure step failed": none of them can pass, and waiting for each to fail (the RAM steps wait 15 min for pods
# that never get Ready) only spends the job's time. The collect and upload steps of the job still run.
#
# SVP_VERIFY_TARGETS (the dispatch's input targets; empty: every target) names the targets to run, separated by
# spaces, each a name of the scenario's list (results.tsv shows them); the build target always runs. The others are
# skipped with the note "not in targets", which does not make the run fail, and keep their id, so a log is named the
# same in every run. A name that is not one of the scenario's, or a character other than a-z, 0-9, - and space, stops
# the script before any target starts (exit 2). A target that reads another's result still needs it: ram-peak
# without the drill-k8s-keda right before it and ram-s3-upload without measure-upload are skipped, and fail the run;
# the others fail on their own, so name what they read with them: the READY video of smoke (k8s-smoke) for load-local,
# drill-k8s-threats and object-store-roundtrip, the reports of web-lighthouse-<n> for lcp, the run of k8s-web-e2e for
# drill-k8s-web-obs.
#
# Deadline: no target starts, and none runs, past the earlier of
#   - the job's start ($SVP_VERIFY_OUT/job-start, written by the job's first step) + SVP_VERIFY_JOB_MINUTES - 25 min,
#     the time the collect and upload steps keep;
#   - this script's start + SVP_VERIFY_STEP_MINUTES (the step's timeout-minutes) - 5 min, so it ends before GitHub
#     stops the step, with time to name the target that ran out and do what follows each target (below).
# Without those variables (the VM) the job's limit is the scenario file's (120 min for compose-obs, 330 for the k3d
# scenarios), counted from now. A target gets the smaller of its own limit and what is left; GNU timeout stops its
# whole process group, with 120 s more for the drills' traps to put the stack back, then kills it. While a disk-low
# mark of deploy/ci/verify-sample.sh exists, no target starts ("disk").
#
# After each target, once its result is in results.tsv: deploy/ci/verify-mask.sh env (make up OBS=lgtm and the k3d
# install add tokens to .env), and on k3d verify-mask.sh cluster while the cluster answers, and make k8s-traffic-stop
# when drill traffic still runs (a canary drill cut short leaves it running). Each under a time limit of its own (at
# most about 3 min together), so a cluster that no longer answers cannot hold the script past its deadline.
#
# Steps that are not a make target of their own, defined here for every scenario file to use (the ram-* ones on k3d):
#   ram-rest-<label> (k3d)     the cluster at rest: every pod Ready (or ended:
#                              Succeeded, Failed), 60 s, then the median of the next 6 samples of verify-sample.sh
#                              (10 s apart) of docker stats MEM USAGE of the k3d containers; anon, active_file and
#                              kernel of memory.stat of each node; kubectl top pods --containers, each container and
#                              summed by namespace, and kubectl top node; the window of those samples, to read
#                              samples/pods.tsv at rest by; ram-rest-<label>.json and .txt, the .txt with free -m of
#                              the runner at that point
#   ram-peak[-<n>] (k3d)       deploy/ci/verify-sample.sh peak over the samples taken while the drill-k8s-keda right
#                              before it ran: the highest median of 6 samples in a row that each saw 2 media-worker pods
#                              transcoding (an ffmpeg process in the pod), with MEM USAGE minus active_file over the
#                              same samples, and the highest sample; ram-peak[-<n>].json, .txt (a scenario that runs the
#                              drill twice names the pairs drill-k8s-keda-<n>, ram-peak-<n>). Skipped when that drill
#                              did not run
#   unwritten                  a step of the scenario whose script is not written yet: fails with a line naming it, so
#                              the run shows the gap instead of a result
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
# The secret lists of deploy/ci/verify-mask.sh, which object-store-roundtrip searches the s3-init logs with.
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
export SVP_VERIFY_OUT=$out SVP_VERIFY_SECRETS=$secrets repo here

scenarios="compose-obs dev-k3d gitops web-canary k6-cloud-mini chaos velero"
scenario=${1:-}
case $scenario in
  compose-obs | dev-k3d | gitops | web-canary | k6-cloud-mini | chaos | velero) ;;
  *)
    echo "FAIL  verify-run: unknown scenario '$scenario' ($scenarios); nothing started" >&2
    exit 2
    ;;
esac
scenario_file=$here/verify/$scenario.sh
build= job_minutes_default= k3d=
unset -f scenario_targets
if [ ! -f "$scenario_file" ]; then
  echo "FAIL  verify-run: no file deploy/ci/verify/$scenario.sh for scenario $scenario; nothing started" >&2
  exit 2
fi
# shellcheck source=/dev/null # one of deploy/ci/verify/*.sh, chosen by the case above
. "$scenario_file"
bad=
case $job_minutes_default in '' | *[!0-9]*) bad=1 ;; esac
case $k3d in 0 | 1) ;; *) bad=1 ;; esac
if [ -n "$bad" ] || [ -z "$build" ] || ! declare -F scenario_targets >/dev/null; then
  echo "FAIL  verify-run: deploy/ci/verify/$scenario.sh does not set build, job_minutes_default (minutes) and" \
    "k3d (0 or 1), or does not define scenario_targets; nothing started" >&2
  exit 2
fi
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

traffic_running() { [ "$k3d" = 1 ] && timeout 10 deploy/k8s/drills/traffic.sh status >/dev/null 2>&1; }
cluster_answers() { timeout 15 kubectl --context k3d-svp --request-timeout=10s get --raw /readyz >/dev/null 2>&1; }
# traffic_stop LOG: stops the drill traffic (traffic.sh waits 20 s at most for it), its output appended to LOG.
traffic_stop() { timeout 60 make -s k8s-traffic-stop >>"${1:-/dev/null}" 2>&1; }

# after LOG: what follows every target (see the header). Mask lines go to this script's stdout, the job's log.
after() {
  timeout 30 "$here/verify-mask.sh" env || echo "verify-run: verify-mask.sh env failed"
  if [ "$k3d" = 1 ] && cluster_answers; then
    # Seven namespaces, each read within 10 s.
    timeout 90 "$here/verify-mask.sh" cluster || echo "verify-run: verify-mask.sh cluster failed"
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

# --- Steps of their own for every scenario file; exported, since timeout runs them in a new bash.

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

# unwritten NAME: see unwritten in the header.
unwritten() {
  echo "FAIL  $1: no script runs this step yet"
  return 1
}

export -f kc not_ready ram_rest unwritten

# --- The scenario's targets: scenario_targets of the scenario file, called twice. With listing set, step and skip only
# add each name to names, which SVP_VERIFY_TARGETS is checked against; then for the run.
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
case "$names " in
  " $build "*) ;;
  *)
    echo "FAIL  verify-run: the first target of deploy/ci/verify/$scenario.sh is not its build target $build; nothing" \
      "started" >&2
    exit 2
    ;;
esac
if [ "$k3d" = 1 ]; then
  # Fetches main again, not the commit the job's source-map step cloned. Accepted risk: a web release merged between
  # the two steps makes those maps another release's, and target gitops-sourcemaps then fails, as it uploads nothing
  # unless every chunk the web serves has its debug ID in the maps; so no wrong map is ever uploaded. Pinning that
  # commit here would leave the clone off main, which the release wait after the scenario follows.
  make -s gitops-clone || {
    echo "FAIL  verify-run: make gitops-clone (the deployment configuration svp-gitops); nothing started" >&2
    exit 1
  }
  SVP_GITOPS_DIR=$(. "$repo/deploy/k8s/lib.sh" && echo "$gitops_ci_clone") || exit 1
  export SVP_GITOPS_DIR
fi
mkdir -p "$out/logs" || exit 1
rm -f "$out/run-end"
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$results"
[ -n "$targets" ] && echo "verify-run $scenario: targets $build $targets; the others are skipped"
scenario_targets
now >"$out/run-end"

echo "verify-run $scenario: $n target(s), $not_ok not ok (results.tsv; the outputs reach the artifact after verify-collect.sh)"
[ "$not_ok" = 0 ]
