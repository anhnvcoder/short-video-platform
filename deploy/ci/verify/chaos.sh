# shellcheck shell=bash
# Scenario chaos of deploy/ci/verify-run.sh, which sources this file: the Chaos Mesh experiments of
# deploy/k8s/cloud/chaos/ on the k3d cluster of the dev path (job k3d of .github/workflows/verify.yml), each under a
# k6 Job of profile cloud (deploy/k6/cloud/run.sh) of its own holding its load. The steps, in order:
#
#   k8s-up                make k8s-up
#   seed-videos           the READY videos the load reads, as scenario k6-cloud-mini seeds them (k6mini_seed)
#   chaos-mesh-install    the install commands of a cloud session, with the runner's overlay: namespace chaos-mesh
#                         labelled Pod Security privileged, helm upgrade --install of the chart of
#                         deploy/k8s/cloud/charts.json with deploy/k8s/cloud/values/chaos-mesh.yaml then
#                         deploy/k8s/cloud/runner/chaos-mesh/values.yaml (the socket of k3s's containerd, the
#                         controller's list of controllers); then the controller and a chaos-daemon on every node
#                         ready, the CRDs there, the controller namespaced on svp alone without a multi-cluster
#                         controller; then the controller still running 150 s on (see The controller's webhook below)
#   chaos-b-trial         the kernel module sch_netem loaded on the runner (see Kernel module below); a test pod
#                         chaos-probe in svp (the media-worker image: a shell and nc); under the step's k6 run, 20 TCP
#                         connections in a row to the cluster DNS Service before (its baseline), during and after
#                         deploy/k8s/cloud/chaos/b-trial-network-delay-probe.yaml; passes when each connection took at
#                         least 150 ms more during and at most 50 ms more after
#   chaos-a               under the step's k6 run: 5 min steady state; a gateway pod killed (a-pod-kill-gateway.yaml)
#                         and 5 min after the kill; a feed-service pod killed (a-pod-kill-feed-service.yaml) and 5 min
#                         after; the window after the gateway kill, from 30 s on, is the steady state the second kill
#                         needs
#   chaos-b               under the step's k6 run: 5 min steady state (with stats in GET /feed/explore);
#                         engagement-service delayed 200 ms for 5 min (b-network-delay-engagement.yaml), the feed read
#                         once during; the delay deleted, the feed's stats back
#   chaos-c               helm upgrade of the release to target svp-data (the cloud session's command); under the
#                         step's k6 run: 5 min steady state; Redpanda down for 5 min (c-redpanda-failure.yaml) while 3
#                         videos are uploaded through the API; its return (the broker Ready again); the 3 videos READY
#                         within 15 min, each transcoded and announced once; the lag of every consumer group back (see
#                         Lag below) and the dead-letter topics unchanged 10 min after the return
#   chaos-mesh-uninstall  its diagnostics (see Diagnostics below); every experiment deleted and gone first; then the
#                         commands of the end of a cloud session: helm uninstall, namespace chaos-mesh deleted, the
#                         CRDs *.chaos-mesh.org deleted; then nothing of Chaos Mesh left: no experiment, CRD, webhook
#                         configuration, ClusterRole, ClusterRoleBinding, Role or RoleBinding of the release, no
#                         namespace; a k6 Job a step cut short left behind is deleted too
#
# Kernel module: the network delay of chaos-b-trial and chaos-b is a netem qdisc that chaos-daemon adds in the target
# pod's network namespace, so the kernel module sch_netem must be there (the k3d nodes share the runner's kernel). The
# trial checks it first (chaos_netem): loaded or built in, else loaded with modprobe; when the modules of the running
# kernel do not have it, linux-modules-extra-<kernel> (where Ubuntu's cloud kernels keep it) is installed first, on a
# runner's VM that serves this one job. The delay shapes only the egress of the target pods (direction to, no target),
# so ifb, which shaping of ingress would need, is not. sch_netem not loaded at the end fails the trial with that reason
# (trial.kernel in the results); chaos-b is skipped whenever the trial did not pass, with the trial's reason. When
# seed-videos or chaos-mesh-install did not pass, the experiments are skipped. An experiment that cannot start, or a
# step whose stop leaves the cluster unsteady, writes a stop mark ($SVP_VERIFY_OUT/chaos-state/stop): the later
# experiments are skipped with its reason. chaos-mesh-uninstall always runs.
#
# The controller's webhook: every experiment is admitted through the webhooks of Chaos Mesh's controller, which the
# API server calls at Service chaos-mesh-controller-manager, and the controller has no readiness probe: its endpoint is
# Ready while its container runs, missing while it crashes or restarts (a helm upgrade that changes its target
# namespace restarts it). Before each apply, and after the helm upgrade of chaos-c, the step waits at most 120 s for a
# Ready endpoint of that Service (chaos_controller_ready; the wait counts in the hold as part controller), and fails
# with that reason when none comes. Each wait, with the controller's pod and restarts, is in <experiment>.controller.
# A controller the API server refuses a list exits once the 2 min it waits for its caches to sync are over, and starts
# again, so chaos-mesh-install watches it for 150 s after its rollout (chaos_controller_stable): the same pod, no
# restart, and no "is forbidden" in its log but for its own Events (each right refused listed in install.controller_stable), or the step fails,
# with its diagnostics, and the experiments are skipped.
#
# Diagnostics: a step whose experiment failed (from its exit, before its k6 run's end is awaited), and the uninstall
# whatever its result, write .k8s/drills/chaos-<time>-diagnostics-<step>.json beside the results (chaos_diag): Chaos
# Mesh's pods (node, IP, each container's state, restarts and how its last run ended), the Ready endpoints of the
# webhook, the leader lease, the events of namespace chaos-mesh, the status of each experiment of the step (conditions,
# the record of each target container with its events) as read just before it was deleted, and the last 200 lines of
# the log (and of the run before, after a restart) of the controller and of chaos-daemon on the node of the step's
# target. deploy/ci/verify-collect.sh keeps .k8s/drills/*.json, scanned for every secret value; these come apart from
# the results so that a scan that drops one leaves the results in the artifact. Chaos Mesh is a third-party component
# outside namespace svp, and no Secret is read.
#
# The load: each experiment runs under a k6 run of its own, started at the beginning of its step (chaos_k6_begin:
# setup(), the ramp, then the experiment's own steady state) and ended at its end, however the experiment ended
# (chaos_k6_finish: the Job's end awaited, each pod's summary read with run.sh logs, the Job deleted, the runner's
# checks over its hold window). The pool's access tokens are issued in setup() and live an hour, with no refresh: each
# run must end within 55 min of its Job's start, setup() included, which one run under every experiment could not. So
# each experiment has its own steady-state hypothesis, checked under the very load its fault then meets. Every run has
# the same level and ramp, and holds for its experiment's parts at their longest plus a margin (chaos_config lists
# them); the hold is fixed when the Job starts. An experiment never extends its run, nor moves to another one midway.
# Hold level: half the highest level k6-cloud-mini passed on this runner, rounded down, at least 1 pod; each pod keeps
# the load of one pod of the 20-pod design.
#
# Holding the load: before each window of an experiment (steady state, the experiment, its recovery) opens, the k6 Job
# must hold its load for the window's whole planned length, and again when it closes: the Job has not ended, each of
# its pods is Running, the window lies within the hold window ([the last pod's end of setup() + the ramp, the first
# pod's end of setup() + the ramp + the hold], 10 s in from each end) and ends within 55 min of the Job's start. When
# it does not, the experiment fails "k6 not holding its load" without a verdict on its hypothesis; the JSON says how
# long the hold would have had to be. A run whose planned end (setup(), the ramp, the hold, the ramp down) falls past
# those 55 min is deleted before its experiment starts. A step passes when its experiment did not fail, its run's
# summary was read and the runner was enough over its hold window (k6's thresholds are data here: the experiment ran
# in this load).
#
# Each experiment's hypothesis and early stop are those of its manifest. The numbers come from the cluster's Prometheus
# (a port-forward on 127.0.0.1:19090, as the drills open it), each over its window, read 30 s after it closed:
# the gateway's feed 5xx ratio and p99, its 5xx on like, view and upload init, the breaker, the alerts; from the API
# (through Envoy) and from rpk in the broker pod. An experiment ends:
#   pass     every line of its hypothesis held
#   finding  it ran under load with every number measured, and a line did not hold (or, with one feed-service replica
#            at the kill, the time the feed went without it): data, recorded, not a failure of the step
#   fail     not measured: k6 not holding its load, no steady state before it, a number Prometheus or rpk did not
#            give, a check of the early stop unread, the script stopped; the step fails
# Early stop, checked every 15 s from the moment an experiment is applied to the end of its recovery, in every wait
# (its injection, the uploads, a killed pod's replacement, its deletion, the broker's return, the videos): a node
# NotReady, or the feed's 5xx above 5% over a minute for more than a minute. A check whose nodes or 5xx ratio did not
# come (the API or Prometheus did not answer, no feed request in the minute) logs a line and counts in the
# experiment's early_stop_checks_unread, which makes it unmeasured; a 5xx streak goes on across it. The experiment is
# deleted at once; when the cluster is not back to steady state (the pods of the target Ready again, the feed's 5xx
# under 0.1% over a minute) within 3 min, the stop mark is written. The trial delays its own test pod only, and has no
# early stop.
#
# Lag (experiment c): the TOTAL-LAG of each consumer group (rpk group describe), each group on its own, never summed.
# Every group must be back to 0 within 10 min of Redpanda's return, except the groups of chaos_lag_batch_groups:
# engagement-service counts views in batches (up to 5 000 records or 1 s a batch), so under the load's views its lag
# read at any moment is the batch in flight; it must be back to the highest lag it had in the steady state. The steady
# state needs every other group at 0. rpk not answering is unread, never 0.
#
# Results: .k8s/drills/chaos-<time>.json (each step merges its part as it goes, so a run cut short keeps what came
# before): the k3s version (Chaos Mesh 2.8.5 is tested by its CI up to Kubernetes 1.35), every window with the k6
# checks at its ends, each experiment's numbers, findings and result, its baseline (the part of its own results its
# hypothesis is held against: <experiment>.k6.baseline), its k6 run (<experiment>.k6: level, the hold's arithmetic,
# the hold window; <experiment>.k6_end: the summaries, the runner's checks over the hold window), what the uninstall
# left, and the name of each diagnostics file (<step>.diagnostics). Each run's hold window also goes to
# $SVP_VERIFY_OUT/k6-windows.tsv (label chaos-<experiment>), for the throttle criterion of deploy/ci/verify-sample.sh.
#
# Stopped by a signal (the run cancelled, or a step's limit reached, which verify-run.sh turns into TERM with 120 s
# before KILL): the step deletes the experiments and waits up to 40 s for them to be gone. Chaos Mesh's finalizer lets
# an experiment go only once its fault is taken back from every target, so only then does the step remove Chaos Mesh
# as the end of a session does; with an experiment still there, Chaos Mesh stays, for its controller to take the fault
# back (chaos-mesh-uninstall, which always runs, waits longer). Then it deletes the k6 Job (run.sh delete), its
# summaries unread: the later experiments are skipped. The stop mark is written first; each request is bounded (5 s,
# helm uninstall 20 s, run.sh delete 25 s), which fits those 120 s while the API answers, and a KILL that comes first
# still leaves the mark and chaos-mesh-uninstall to follow. It writes no diagnostics: chaos-mesh-uninstall does.
#
# A step that ends otherwise before its k6 run's end (an early stop, k6 not holding its load, no steady state, a
# failed request) still ends that run on its exit as the step's end does (chaos_k6_finish), once the run has reached
# its hold: the rest of its hold and its ramp down, which end within the 55 min, then its summaries, its k6_end and its
# line in k6-windows.tsv; the step's own result stays. A run that never reached its hold (setup() not ended within
# 15 min, the Job ended in setup(), a planned end past the 55 min) is deleted at once.
#
# LOCAL LAB ONLY, as every k3d drill: the register rate limit keys svp:gw:rl:register:* in the cluster's Valkey db 10
# are deleted before each k6 run starts and when a step registers a user (deploy/compose/lib.sh).
#
# Linux only (GNU date), as verify-run.sh. Run as a script, bash deploy/ci/verify/chaos.sh test, it runs its self-test
# (no cluster: fake kubectl, helm and run.sh), also on macOS.

# The seed of READY videos, the end of setup() in the k6 pods, the state of the Job, the OOM kills and the runner's
# checks over a window are those of scenario k6-cloud-mini: its file is sourced for its functions (k6mini_*), and this
# file sets build, job_minutes_default, k3d and scenario_targets after it.
# shellcheck source=deploy/ci/verify/k6-cloud-mini.sh
. "$(dirname "${BASH_SOURCE[0]}")/k6-cloud-mini.sh"

build=k8s-up
job_minutes_default=330
k3d=1

# chaos_config: the constants every step reads (each step runs in a bash of its own).
chaos_config() {
  # Hold level: k6-cloud-mini passed 1 and 2 pods on the runner and failed at 4 (run 40620333867), so half of 2.
  chaos_k6_pods=1
  chaos_ramp_m=2
  # Profile cloud ramps down over 1 min after its hold (deploy/k6/lib/config.js).
  chaos_ramp_down_s=60
  # The hold of each experiment's k6 run, its parts in seconds, each at its longest; run.sh --hold is their sum
  # rounded up to whole minutes, the Job's deadline 2 + hold + 1 + 15 min (render.sh). controller is the wait for the
  # webhook's endpoint before an apply (chaos_controller_ready, 120 s at most):
  #   trial  controller 120, window 240 (20 connections before, the delay injected (60), 20 during, the experiment
  #          deleted (60), up to three runs after over 30 s), margin 120: 480 s, --hold 8m
  #   a      steady 300, settle 30 (Prometheus has a window's last samples 30 s after it closed), controller 120,
  #          gateway 360 (the kill seen (60) and the 300 s after it), settle 30, controller 120, feed-service 360,
  #          settle 30, margin 120: 1470 s, 25m
  #   b      steady 300, settle 30, controller 120, delay 420 (injected (60), 300 delayed, deleted (60)), recovery
  #          120, settle 30, margin 120: 1140 s, 19m
  #   c      steady 300, settle 30, controller 120, outage 480 (injected (60), 300 down, deleted (120)), broker 120
  #          (Ready again), videos 900 (READY; the lag and the dead-letter topics within it), topics 60, settle 30,
  #          margin 120: 2160 s, 36m
  # The longest, c, with setup() at its limit (15 min, the image pull included), the ramp and the ramp down: 15 + 2 +
  # 36 + 1 = 54 min, within chaos_access_s.
  chaos_hold_trial='controller:120 window:240 margin:120'
  chaos_hold_a='steady:300 settle:30 controller:120 gateway:360 settle:30 controller:120 feed-service:360 settle:30 margin:120'
  chaos_hold_b='steady:300 settle:30 controller:120 delay:420 recovery:120 settle:30 margin:120'
  chaos_hold_c='steady:300 settle:30 controller:120 outage:480 broker:120 videos:900 topics:60 settle:30 margin:120'
  # How long after its Job's start a k6 run may last: the pool's access tokens are issued in setup(), after that
  # start, and live an hour; the 5 min left are a margin.
  chaos_access_s=3300
  # The consumer groups whose lag goes back to their own steady-state level rather than 0 (see Lag in the header).
  chaos_lag_batch_groups=engagement-service
  # Seconds between two checks of the early stop (chaos_watch_due).
  chaos_watch_every=15
  # How long the trap waits for the experiments to be gone before it removes Chaos Mesh.
  chaos_trap_wait_s=40
  chaos_state=$SVP_VERIFY_OUT/chaos-state
  chaos_files=$repo/deploy/k8s/cloud/chaos
  chaos_k6_run=("$repo/deploy/k6/cloud/run.sh" --context k3d-svp --domain svp.localhost)
  # The experiments by namespace, kind and name, deleted first whenever a step stops.
  chaos_experiments='svp:networkchaos:network-delay-trial svp:podchaos:pod-kill-gateway svp:podchaos:pod-kill-feed-service
    svp:networkchaos:network-delay-engagement svp-data:podchaos:redpanda-failure'
  chaos_feed_sel='service_name="gateway",http_request_method="GET",http_route=~"/feed/following|/feed/explore"'
  chaos_written= chaos_key= chaos_step= chaos_why= chaos_high_since= chaos_watched_at= chaos_watch_unread=0 prom_pid=
  # The pods the step's experiment targets, "NAMESPACE APP" (label app.kubernetes.io/name), whose nodes' chaos-daemon
  # logs go into the step's diagnostics (chaos_diag); and whether the step wrote them.
  chaos_target= chaos_diag_done=
  # What the step's exit does with a k6 run it started and has not finished (chaos_on_exit): delete, or finish once
  # the run has reached its hold within the pool's access (chaos_k6_begin).
  chaos_k6_live=
}

# chaos_helm ARGS...: helm on the cluster, its homes under .k8s/helm as the repository's scripts keep them.
chaos_helm() {
  HELM_CACHE_HOME=$repo/.k8s/helm/cache HELM_CONFIG_HOME=$repo/.k8s/helm/config HELM_DATA_HOME=$repo/.k8s/helm/data \
    helm --kube-context k3d-svp "$@"
}

# chaos_upgrade [ARGS...]: helm upgrade --install of the chart of deploy/k8s/cloud/charts.json with its values and the
# runner's overlay after them, waiting for the release; ARGS are added (the --set of experiment c).
chaos_upgrade() {
  local chart_repo version values runner
  read -r chart_repo version values runner < <(jq -r '.charts[] | select(.name == "chaos-mesh")
    | "\(.repo) \(.version) \(.values) \(.runnerValues)"' "$repo/deploy/k8s/cloud/charts.json") || return 1
  chaos_helm upgrade --install chaos-mesh chaos-mesh --repo "$chart_repo" --version "$version" -n chaos-mesh \
    -f "$repo/$values" -f "$repo/$runner" --wait --timeout 10m "$@"
}

# chaos_put KEY JSON: merges JSON (an object) into KEY of the scenario's results file, nested objects included (made
# at the first call, its path kept in the state directory), with every window recorded so far.
chaos_put() {
  local f tmp
  mkdir -p "$chaos_state"
  touch "$chaos_state/windows.jsonl"
  f=$(cat "$chaos_state/json-path" 2>/dev/null)
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    f=$repo/.k8s/drills/chaos-$(date -u +%Y%m%dT%H%M%SZ).json
    mkdir -p "$(dirname "$f")"
    jq -n '{scenario: "chaos"}' >"$f" || return 1
    printf '%s\n' "$f" >"$chaos_state/json-path"
  fi
  tmp=$f.tmp
  jq --arg k "$1" --argjson v "$2" --slurpfile w "$chaos_state/windows.jsonl" \
    '.[$k] = ((.[$k] // {}) * $v) | .windows = $w' "$f" >"$tmp" && mv "$tmp" "$f"
  # A part without a result is a step's progress; the step has written its result only with one.
  [ "$1" != "$chaos_key" ] || ! jq -e 'has("result")' <<<"$2" >/dev/null || chaos_written=1
}

# chaos_fail KEY REASON: a fail result for KEY; prints FAIL with REASON.
chaos_fail() {
  echo "FAIL  $1: $2"
  chaos_put "$1" "$(jq -nc --arg r "$2" '{result: "fail", reason: $r}')"
}

# chaos_mark_stop REASON: the stop mark (see the header). One line, no tab: verify-run.sh puts it in results.tsv.
chaos_mark_stop() {
  mkdir -p "$chaos_state"
  printf '%s\n' "$1" | tr '\t\n' '  ' >"$chaos_state/stop"
  echo "chaos: the later experiments are skipped: $1"
}

# chaos_delete_experiments: asks for the deletion of each experiment of chaos_experiments that exists, without waiting
# for it to go (chaos_experiments_gone does); each request bounded, for the trap.
chaos_delete_experiments() {
  local e ns kind name
  for e in $chaos_experiments; do
    IFS=: read -r ns kind name <<<"$e"
    kc --request-timeout=5s -n "$ns" delete "$kind" "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || :
  done
}

# chaos_experiments_left: the experiments of chaos_experiments that still exist, one namespace/kind/name per line (none
# of a kind whose CRD is not there); false when the API did not answer.
chaos_experiments_left() {
  local e ns kind name crds out
  crds=$(kc --request-timeout=5s get crd -o name 2>/dev/null) || return 1
  for e in $chaos_experiments; do
    IFS=: read -r ns kind name <<<"$e"
    grep -qxF "customresourcedefinition.apiextensions.k8s.io/$kind.chaos-mesh.org" <<<"$crds" || continue
    out=$(kc --request-timeout=5s -n "$ns" get "$kind" "$name" --ignore-not-found -o name 2>/dev/null) || return 1
    [ -z "$out" ] || echo "$ns/$kind/$name"
  done
}

# chaos_experiments_gone SECONDS: waits at most SECONDS for every experiment to be gone. Chaos Mesh's finalizer lets an
# experiment go only once its fault is taken back from every target, so gone means restored; removing the controller
# or the CRDs before would leave the fault injected and the CRD stuck terminating. Prints what is left when not.
chaos_experiments_gone() {
  local deadline=$(($(date +%s) + $1)) left
  while :; do
    if left=$(chaos_experiments_left); then
      [ -n "$left" ] || return 0
    else
      left="unread (the API did not answer)"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 2
  done
  echo "chaos: experiments not gone within $1 s: $(printf '%s' "$left" | tr '\n' ' ')"
  return 1
}

# chaos_teardown [WAIT]: the end of a cloud session, in its order: helm uninstall, the namespace, the CRDs. Only once
# every experiment is gone (chaos_experiments_gone). WAIT false (the trap) does not wait for the namespace and the CRDs
# to go, and bounds each request instead.
chaos_teardown() {
  local wait=${1:-true} crds rt=() ht=60s
  [ "$wait" = true ] || { rt=(--request-timeout=5s) ht=20s; }
  if chaos_helm status chaos-mesh -n chaos-mesh >/dev/null 2>&1; then
    chaos_helm uninstall chaos-mesh -n chaos-mesh --timeout "$ht" || echo "chaos: helm uninstall chaos-mesh failed"
  fi
  kc ${rt[@]+"${rt[@]}"} delete namespace chaos-mesh --ignore-not-found --wait="$wait" --timeout=180s ||
    echo "chaos: delete namespace chaos-mesh failed"
  crds=$(kc --request-timeout=5s get crd -o name 2>/dev/null | grep '\.chaos-mesh\.org$')
  if [ -n "$crds" ]; then
    # shellcheck disable=SC2086 # one CRD name per word
    kc ${rt[@]+"${rt[@]}"} delete $crds --wait="$wait" --timeout=180s || echo "chaos: delete the CRDs *.chaos-mesh.org failed"
  fi
}

# chaos_guard STEP KEY: the step's traps; KEY is its part of the results file. On exit: the port-forward stopped, the
# work directory of the API helpers removed, a fail result when the step wrote none, the diagnostics of a failed step
# (chaos_diag_failed), then a k6 run the step started and did not finish: finished as the step's end would have
# (chaos_k6_finish) once it reached its hold, deleted otherwise. On INT or TERM: see the header.
chaos_guard() {
  chaos_step=$1 chaos_key=$2
  trap 'chaos_on_exit' EXIT
  trap 'chaos_on_signal' INT TERM
}
chaos_on_exit() {
  [ -z "$prom_pid" ] || { kill "$prom_pid" 2>/dev/null; wait "$prom_pid" 2>/dev/null; }
  [ -z "${work:-}" ] || rm -rf "$work"
  if [ -z "$chaos_written" ] && [ -n "$chaos_key" ]; then
    chaos_fail "$chaos_key" "the step $chaos_step stopped before its result (see its log)"
  fi
  chaos_diag_failed
  case $chaos_k6_live in
    finish)
      echo "chaos: $chaos_step ended before its k6 run: its Job's end awaited and its summaries read before it is deleted"
      chaos_k6_finish "$chaos_key" || :
      ;;
    delete) timeout 60 "${chaos_k6_run[@]}" delete || echo "chaos: run.sh delete failed" ;;
  esac
}
chaos_on_signal() {
  trap - INT TERM
  echo "chaos: $chaos_step stopped by a signal: deleting the experiments, then Chaos Mesh once they are gone, then the k6 Job"
  local stopped="$chaos_step was stopped (run cancelled or step limit)"
  chaos_mark_stop "$stopped"
  chaos_delete_experiments
  if chaos_experiments_gone "$chaos_trap_wait_s"; then
    chaos_teardown false
    chaos_mark_stop "$stopped; experiments, Chaos Mesh and the k6 Job deleted"
  else
    chaos_mark_stop "$stopped; an experiment was not gone within $chaos_trap_wait_s s, so Chaos Mesh was left for its controller to take the fault back; the k6 Job deleted"
  fi
  timeout 25 "${chaos_k6_run[@]}" delete || echo "chaos: run.sh delete failed"
  # No diagnostics on the way out: their requests would not fit the time left before KILL, and chaos-mesh-uninstall
  # writes them.
  chaos_k6_live= chaos_diag_done=1
  exit 143
}

# chaos_api: the API, rpk and Prometheus helpers of the drills (deploy/k8s/drills/lib.sh), through Envoy with the
# cluster's CA; its work directory goes with chaos_on_exit.
chaos_api() {
  export SVP_STACK=k3d CURL_CA_BUNDLE=$repo/.k8s/ca.crt
  base=https://api.svp.localhost:8443
  # shellcheck source=deploy/k8s/drills/lib.sh
  . "$repo/deploy/k8s/drills/lib.sh"
  # lib.sh sets its own EXIT trap; chaos_on_exit removes $work as well.
  trap 'chaos_on_exit' EXIT
}

# chaos_k6_holding SECONDS: whether the k6 Job holds its load now and for SECONDS more (see the header); sets chaos_why
# when not.
chaos_k6_holding() {
  local need=$1 t from to access job state
  t=$(date +%s)
  read -r from to access < <(jq -r '"\(.hold_from) \(.hold_to) \(.access_to)"' "$chaos_state/k6.json" 2>/dev/null)
  if ! [[ ${from:-} =~ ^[0-9]+$ && ${to:-} =~ ^[0-9]+$ && ${access:-} =~ ^[0-9]+$ ]]; then
    chaos_why="no hold window (the step's k6 run did not start its hold)"
    return 1
  fi
  if ! job=$(kc -n svp-load get job svp-k6 -o json 2>/dev/null); then
    chaos_why="no Job svp-load/svp-k6"
    return 1
  fi
  state=$(jq -r '[.status.conditions[]? | select(.status == "True" and (.type == "Complete" or .type == "Failed")) | .type]
    | first // "running"' <<<"$job")
  if [ "$state" != running ]; then
    chaos_why="Job svp-load/svp-k6 ended ($state)"
    return 1
  fi
  local pods want
  want=$(jq -r '.spec.parallelism' <<<"$job")
  pods=$(kc -n svp-load get pods -l batch.kubernetes.io/job-name=svp-k6 -o json 2>/dev/null |
    jq '[.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null)] | length')
  if [ "${pods:-0}" != "$want" ]; then
    chaos_why="${pods:-no} pod(s) of the Job Running, $want expected"
    return 1
  fi
  if [ "$t" -lt "$from" ]; then
    chaos_why="the hold starts in $((from - t)) s"
    return 1
  fi
  if [ $((t + need)) -gt "$to" ]; then
    chaos_why="the hold ends in $((to - t)) s, the window needs $need s; a hold $((t + need - to)) s longer would do"
    return 1
  fi
  if [ $((t + need)) -gt "$access" ]; then
    chaos_why="the run's $((chaos_access_s / 60)) min end in $((access - t)) s (the pool's access tokens), the window needs $need s"
    return 1
  fi
}

# chaos_k6_begin KEY PARTS BASELINE: the k6 run of experiment KEY (see The load in the header): run.sh start at the
# hold level, held for the sum of PARTS ("name:seconds ...") rounded up to whole minutes; once setup() has ended in
# every pod, the hold window into $chaos_state/k6.json and KEY's k6 part of the results file, with BASELINE (the part
# of KEY's results its hypothesis is held against). A run whose setup() did not end, or whose planned end falls past
# chaos_access_s from its start, is left for the step's exit to delete; past that check, the step's exit finishes it
# (chaos_k6_live). Returns when the hold window opens, true when k6 holds its load then; sets chaos_why when not.
chaos_k6_begin() {
  local key=$1 parts=$2 baseline=$3 p need=0 hold_m started deadline ends setup_done=0 ended first last from to end
  local access job_deadline
  for p in $parts; do need=$((need + ${p#*:})); done
  hold_m=$(((need + 59) / 60))
  rm -f "$chaos_state/k6.json"
  "${chaos_k6_run[@]}" delete || { chaos_why="run.sh delete of a Job left behind failed"; return 1; }
  # LOCAL LAB ONLY: deploy/compose/lib.sh deletes the register rate limit keys as it is sourced.
  SVP_STACK=k3d bash -c '. "$1/deploy/compose/lib.sh"' _ "$repo" || { chaos_why="the reset of the register keys failed"; return 1; }
  started=$(date +%s)
  chaos_k6_live=delete
  "${chaos_k6_run[@]}" --pods "$chaos_k6_pods" --ramp "${chaos_ramp_m}m" --hold "${hold_m}m" start ||
    { chaos_why="run.sh start failed"; return 1; }
  # setup() takes 3 min at most; the pods may wait for their image first.
  deadline=$((started + 900))
  while :; do
    ends=$(k6mini_setup_ends)
    setup_done=$(grep -c . <<<"$ends")
    ended=$(k6mini_job_ended)
    [ "$setup_done" -ge "$chaos_k6_pods" ] || [ -n "$ended" ] || [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 10
  done
  if [ "$setup_done" -lt "$chaos_k6_pods" ] || [ -n "$ended" ]; then
    chaos_why="setup() ended in $setup_done of $chaos_k6_pods pod(s) within 15 min${ended:+; the Job ended ($ended)}"
    return 1
  fi
  first=$(awk '{ print $1 }' <<<"$ends" | sort -n | head -n 1)
  last=$(awk '{ print $1 }' <<<"$ends" | sort -n | tail -n 1)
  from=$((last + chaos_ramp_m * 60 + 10))
  to=$((first + chaos_ramp_m * 60 + hold_m * 60 - 10))
  end=$((last + chaos_ramp_m * 60 + hold_m * 60 + chaos_ramp_down_s))
  access=$((started + chaos_access_s))
  jq -nc --argjson s "$started" --argjson f "$from" --argjson t "$to" --argjson a "$access" \
    '{started: $s, hold_from: $f, hold_to: $t, access_to: $a}' >"$chaos_state/k6.json"
  job_deadline=$(kc -n svp-load get job svp-k6 -o jsonpath='{.spec.activeDeadlineSeconds}')
  chaos_put "$key" "$(jq -nc --argjson pods "$chaos_k6_pods" --arg parts "$parts" --argjson need "$need" \
    --argjson m "$hold_m" --argjson ramp "$chaos_ramp_m" --argjson s "$started" --argjson f "$from" --argjson t "$to" \
    --argjson e "$end" --argjson a "$access" --argjson deadline "${job_deadline:-null}" --arg key "$key" \
    --arg baseline "$baseline" '
    {k6: {run: "chaos-\($key), its own: started in this step, ended (k6_end) before the next experiment",
     baseline: $baseline,
     pods: $pods,
     pods_why: "half the highest level k6-cloud-mini passed on the runner (2 pods, run 40620333867)",
     ramp_m: $ramp, hold_m: $m,
     hold_parts_s: ($parts | split(" ") | map(split(":") | {part: .[0], s: (.[1] | tonumber)})),
     hold_needed_s: $need, job_deadline_s: $deadline, started: ($s | todate),
     hold_window: {from: ($f | todate), to: ($t | todate)},
     load_ends_s_after_start: ($e - $s), access_until: ($a | todate)}}')"
  echo "k6: $chaos_k6_pods pod(s), ramp ${chaos_ramp_m} min, hold ${hold_m} min ($parts, sum $need s); hold window" \
    "$(date -u -d "@$from" +%H:%M:%SZ) to $(date -u -d "@$to" +%H:%M:%SZ); the load ends $((end - started)) s after the Job's start"
  if [ "$end" -gt "$access" ]; then
    chaos_why="the run would end $((end - started)) s after its Job's start, past the $chaos_access_s s the pool's access allows"
    return 1
  fi
  # The run ends within the pool's access: from here a step that stops before its end still reads its summaries.
  chaos_k6_live=finish
  chaos_wait_until "$from"
  chaos_k6_holding 0 || { chaos_why="not at the start of its hold: $chaos_why"; return 1; }
  echo "ok    k6 holds its load"
}

# chaos_k6_finish KEY: the end of experiment KEY's k6 run, at the end of its step or, when the step stopped before
# (an early stop, k6 not holding its load, no steady state), from its exit: waits for the Job to end (the rest of its
# hold and its ramp down; 5 min past the hold window at most), reads each pod's summary (run.sh logs), deletes the
# Job; the hold window into $SVP_VERIFY_OUT/k6-windows.tsv and the runner's checks over it (k6mini_runner). KEY's
# k6_end part of the results file; true when the summary was read and the runner was enough. A failed experiment's
# diagnostics come first (chaos_diag_failed): the logs they keep are those of the failure, not of the minutes after.
chaos_k6_finish() {
  local key=$1 from to deadline ended oom out dir runner end rc=0
  chaos_diag_failed
  read -r from to < <(jq -r '"\(.hold_from) \(.hold_to)"' "$chaos_state/k6.json")
  deadline=$((to + 300))
  ended=$(k6mini_job_ended)
  while [ -z "$ended" ] && kc -n svp-load get job svp-k6 >/dev/null 2>&1 && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 15
    ended=$(k6mini_job_ended)
  done
  echo "Job svp-k6: ${ended:-not ended}"
  [ "$(date +%s)" -ge "$to" ] || to=$(date +%s)
  oom=$(k6mini_oom)
  out=$("${chaos_k6_run[@]}" logs) || rc=1
  printf '%s\n' "$out"
  dir=$(sed -n 's/^summaries in //p' <<<"$out")
  "${chaos_k6_run[@]}" delete || rc=1
  chaos_k6_live=
  printf 'chaos-%s\t%s\t%s\t%s\n' "$key" "$from" "$to" "$chaos_k6_pods" >>"$SVP_VERIFY_OUT/k6-windows.tsv"
  runner=$(k6mini_runner "$from" "$to" "$chaos_k6_pods" "$oom")
  # rate_limited: every 429 of the run, setup() included, as the threshold svp_rate_limited counts them; the routes'
  # own counts cover only the load's routes.
  end=$(cat "$repo/${dir:-none}"/pod-*.json 2>/dev/null | jq -sc --arg job "${ended:-not ended}" --arg dir "${dir:-}" \
    --argjson pods "$chaos_k6_pods" --argjson runner "$runner" --argjson rc "$rc" '
    . as $s | {job: $job, summaries: $dir, pods_with_summary: ($s | length),
      thresholds_ok: (($s | length) == $pods and all($s[]; .thresholds_ok)),
      thresholds_failed: ($s | map(.thresholds[] | select(.ok | not) | "\(.metric): \(.expression)") | unique),
      dropped_iterations: ($s | map(.dropped_iterations) | add // 0),
      rate_limited: ($s | map(.metrics.svp_rate_limited.values.count // 0) | add // 0),
      routes: ($s | map(.routes[]) | group_by(.route) | map({route: .[0].route, requests: (map(.requests) | add),
        failed_rate_max: (map(.failed_rate) | max), p99_ms_max: (map(.p99_ms) | max)})),
      note: "k6 thresholds over the whole run, the experiment included: data, not the step result",
      runner: $runner}
    | .result = (if $rc == 0 and .pods_with_summary >= $pods and .runner.enough == true then "pass" else "fail" end)') ||
    end='{"result": "fail", "note": "the summaries were not read"}'
  chaos_put "$key" "$(jq -nc --argjson e "$end" '{k6_end: $e}')"
  jq -r '"k6: Job \(.job); \(.pods_with_summary) summary(ies), thresholds \(if .thresholds_ok then "ok" else "FAILED (data: the experiment ran in this load)" end), dropped_iterations \(.dropped_iterations), 429 \(.rate_limited)",
    (.thresholds_failed[]? | "  threshold failed: \(.)"),
    "runner enough: \(.runner.enough); " + ((.runner.checks // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")),
    "k6 run: \(.result)"' <<<"$end"
  [ "$(jq -r .result <<<"$end")" = pass ]
}

# chaos_open NAME SECONDS / chaos_close: a window of the current step (see Holding the load in the header): open checks
# that k6 holds for SECONDS, close checks again; each records the window, true when k6 held at both ends.
chaos_open() {
  chaos_win=$1 chaos_win_from=$(date +%s)
  if chaos_k6_holding "$2"; then
    echo "window $1 opens: k6 holds its load for its $2 s"
    return 0
  fi
  chaos_record_window false null
  echo "window $1 not opened: k6 not holding its load: $chaos_why"
  return 1
}
chaos_close() {
  if chaos_k6_holding 0; then
    chaos_record_window true true
    echo "window $chaos_win closes: k6 held its load"
    return 0
  fi
  chaos_record_window true false
  echo "window $chaos_win: k6 no longer holding its load at its end: $chaos_why"
  return 1
}

chaos_record_window() {
  jq -nc --arg s "$chaos_step" --arg n "$chaos_win" --argjson f "$chaos_win_from" --argjson t "$(date +%s)" \
    --argjson o "$1" --argjson c "$2" --arg why "$chaos_why" '
    {step: $s, window: $n, from: ($f | todate), to: ($t | todate), seconds: ($t - $f), k6_holding_at_open: $o,
     k6_holding_at_close: $c} + (if $o and $c then {} else {why: $why} end)' >>"$chaos_state/windows.jsonl"
}

# chaos_wait_until T [COMMAND...]: sleeps until T (seconds since the epoch), running COMMAND every 15 s; returns 1 as
# soon as COMMAND does.
chaos_wait_until() {
  local t=$1 left
  shift
  while left=$((t - $(date +%s))) && [ "$left" -gt 0 ]; do
    sleep $((left < 15 ? left : 15))
    if [ $# -gt 0 ]; then "$@" || return 1; fi
  done
}

# --- Prometheus (prometheus_forward and promql of deploy/k8s/drills/lib.sh).

# chaos_q QUERY TIME: the first value of QUERY at TIME as a number, null when it has none (no series, NaN, no answer).
chaos_q() {
  local r
  r=$(promql "$1" "$2" 2>/dev/null)
  jq -r '.[0].value[1] // null | if . == null or . == "NaN" or . == "+Inf" or . == "-Inf" then null else tonumber end' \
    <<<"${r:-[]}" 2>/dev/null || echo null
}

# The gateway's request counts: http_server_request_duration_seconds_count with FILTER (labels) over W.
chaos_n() { echo "sum(increase(http_server_request_duration_seconds_count{$1}[$2]))"; }

# 5xx of FILTER over W, 0 when the routes answered without one.
chaos_n5() { echo "(sum(increase(http_server_request_duration_seconds_count{$1,http_response_status_code=~\"5..\"}[$2])) or vector(0))"; }

chaos_ratio_query() { echo "$(chaos_n5 "$chaos_feed_sel" "$1") / $(chaos_n "$chaos_feed_sel" "$1")"; }
chaos_p99_query() {
  echo "histogram_quantile(0.99, sum by (le) (increase(http_server_request_duration_seconds_bucket{$chaos_feed_sel}[$1]))) * 1000"
}

# Envoy's 5xx ratio on the backends of HTTPRoute api (the gateway): requests that died with a killed pod, which the
# gateway's own metrics cannot count. Recorded, not part of a hypothesis.
chaos_envoy_query() {
  local s='envoy_cluster_name=~"httproute/svp/api/.+"'
  echo "(sum(increase(envoy_cluster_upstream_rq_xx{$s,envoy_response_code_class=\"5\"}[$1])) or vector(0)) / sum(increase(envoy_cluster_upstream_rq_xx{$s}[$1]))"
}

# Page alerts firing at any time in W.
chaos_pages_query() { echo "count(max_over_time(ALERTS{alertstate=\"firing\",severity=\"page\"}[$1])) or vector(0)"; }

# chaos_steady FROM TO: prints the steady state of the window as JSON (the feed's 5xx ratio under 0.1%, its p99 at most
# 150 ms, no page alert firing in it); false when one does not hold or is unmeasured.
chaos_steady() {
  local w=$(($2 - $1))s ratio p99 pages j
  ratio=$(chaos_q "$(chaos_ratio_query "$w")" "$2")
  p99=$(chaos_q "$(chaos_p99_query "$w")" "$2")
  pages=$(chaos_q "$(chaos_pages_query "$w")" "$2")
  j=$(jq -nc --argjson r "$ratio" --argjson p "$p99" --argjson a "$pages" --argjson f "$1" --argjson t "$2" '
    {from: ($f | todate), to: ($t | todate), feed_5xx_ratio: $r, feed_p99_ms: $p, page_alerts_fired: $a}
    | .holds = ($r != null and $p != null and $a != null and $r < 0.001 and $p <= 150 and $a == 0)')
  echo "steady state: $j" >&2
  printf '%s\n' "$j"
  jq -e '.holds' <<<"$j" >/dev/null
}

# chaos_watch: one check of the early stop (see the header), run every 15 s by chaos_wait_until; sets chaos_why and
# returns 1 when the experiment must stop. A check whose nodes or 5xx ratio did not come logs a line and counts in
# chaos_watch_unread; the 5xx streak (chaos_high_since) goes on across it, ended only by a ratio read under 5%.
chaos_watch() {
  local t notready r unread=
  t=$(date +%s)
  notready=$(kc get nodes -o json 2>/dev/null |
    jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True"))] | length' 2>/dev/null)
  if [[ ${notready:-} =~ ^[1-9] ]]; then
    chaos_why="$notready node(s) NotReady"
    return 1
  fi
  [[ ${notready:-} =~ ^[0-9]+$ ]] || unread="the nodes (the API did not answer)"
  r=$(chaos_q "$(chaos_ratio_query 1m)" "$t")
  if [ "$r" = null ]; then
    unread="${unread:+$unread, }the feed's 5xx over the last minute (Prometheus did not answer, or no feed request)"
  elif awk -v r="$r" 'BEGIN { exit !(r > 0.05) }'; then
    chaos_high_since=${chaos_high_since:-$t}
    echo "feed 5xx over the last minute: $r (above 5% since $((t - chaos_high_since)) s)"
    if [ $((t - chaos_high_since)) -gt 60 ]; then
      chaos_why="the feed's 5xx above 5% for more than a minute ($r)"
      return 1
    fi
  else
    chaos_high_since=
  fi
  if [ -n "$unread" ]; then
    chaos_watch_unread=$((chaos_watch_unread + 1))
    echo "early stop check unread: $unread; $chaos_watch_unread unread in this experiment${chaos_high_since:+, the 5xx streak since $((t - chaos_high_since)) s goes on}"
  fi
}
# chaos_watch_due: chaos_watch once chaos_watch_every seconds have passed since it last ran (chaos_watched_at), for
# the loops that poll more often than that; true otherwise.
chaos_watch_due() {
  local t
  t=$(date +%s)
  [ $((t - ${chaos_watched_at:-0})) -ge "$chaos_watch_every" ] || return 0
  chaos_watched_at=$t
  chaos_watch
}

# chaos_ready NAMESPACE APP: the Ready pods of APP (label app.kubernetes.io/name) that are not being deleted, one name
# per line. chaos_alive: those not being deleted, Ready or not. Both false when the API did not answer, so that an
# unanswered list never reads as no pod.
chaos_ready() {
  local j
  j=$(kc -n "$1" get pods -l "app.kubernetes.io/name=$2" -o json) || return 1
  jq -r '.items[]
    | select(.metadata.deletionTimestamp == null and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name' <<<"$j"
}

chaos_alive() {
  local j
  j=$(kc -n "$1" get pods -l "app.kubernetes.io/name=$2" -o json) || return 1
  jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name' <<<"$j"
}

# chaos_recovered NAMESPACE APP COUNT: waits at most 3 min for COUNT Ready pods of APP and the feed's 5xx under 0.1%
# over the last minute; false when the cluster did not get back to that.
chaos_recovered() {
  local deadline=$(($(date +%s) + 180)) r
  while [ "$(date +%s)" -lt "$deadline" ]; do
    r=$(chaos_q "$(chaos_ratio_query 1m)" "$(date +%s)")
    if [ "$(chaos_ready "$1" "$2" | grep -c .)" -ge "$3" ] && [ "$r" != null ] &&
      awk -v r="$r" 'BEGIN { exit !(r < 0.001) }'; then
      return 0
    fi
    sleep 10
  done
  return 1
}

# chaos_stopped_early KEY WHEN NAMESPACE APP COUNT: experiment KEY stopped early WHEN (chaos_why says why; its
# experiment already deleted): the open window and the reason recorded, then the wait for steady state (COUNT Ready
# pods of APP, chaos_recovered); a fail result, with the stop mark when the cluster did not get back to it. Returns 1.
chaos_stopped_early() {
  local why=$chaos_why
  echo "early stop $2: $why"
  chaos_record_window true null
  chaos_put "$1" "$(jq -nc --arg why "$2: $why" '{early_stop: $why}')"
  if ! chaos_recovered "$3" "$4" "$5"; then
    chaos_fail "$1" "stopped early $2 ($why), not back to steady state within 3 min"
    chaos_mark_stop "experiment ($1) stopped early and the cluster did not get back to steady state"
    return 1
  fi
  chaos_fail "$1" "stopped early $2 ($why); back to steady state"
  return 1
}

# chaos_injected NAMESPACE KIND NAME [watch]: waits at most 60 s for the experiment's AllInjected condition; with
# watch, the early stop is checked meanwhile (chaos_watch_due). Returns 1 when it was not injected in time, 2 on an
# early stop.
chaos_injected() {
  local i
  for i in $(seq 1 30); do
    if [ "${4:-}" = watch ]; then chaos_watch_due || return 2; fi
    [ "$(kc -n "$1" get "$2" "$3" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null)" = True ] &&
      return 0
    sleep 2
  done
  return 1
}

# chaos_delete_watched NAMESPACE KIND NAME SECONDS: deletes the experiment and waits at most SECONDS for it to be gone
# (Chaos Mesh's finalizer lets it go once its fault is taken back), the early stop checked meanwhile: a stop it calls
# for is logged, the experiment being on its way out already, and the recovery's checks that follow see it again while
# it lasts. Its status is read first, for the step's diagnostics (chaos_diag_object). False when the experiment is not
# gone in time.
chaos_delete_watched() {
  local deadline out
  # The two reads of the diagnostics take up to 5 s each: with the watch due every 15 s and checked again right after
  # them, no more than 25 s pass between two checks of the early stop.
  chaos_watch_due || echo "early stop called for before $2 $3 is deleted: $chaos_why"
  chaos_diag_object "$1" "$2" "$3"
  chaos_watch_due || echo "early stop called for before $2 $3 is deleted: $chaos_why"
  deadline=$(($(date +%s) + $4))
  kc -n "$1" delete "$2" "$3" --ignore-not-found --wait=false >/dev/null || echo "delete $2 $3 failed"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    chaos_watch_due || echo "early stop called for while $2 $3 is being deleted: $chaos_why"
    if out=$(kc -n "$1" get "$2" "$3" --ignore-not-found -o name 2>/dev/null) && [ -z "$out" ]; then
      return 0
    fi
    sleep 2
  done
  echo "$2 $3 not gone within $4 s of its deletion"
  return 1
}

# --- Chaos Mesh itself: its webhook before an apply, the diagnostics, the kernel module of the delay.

# chaos_controller_ready WHEN: waits at most 120 s for a Ready endpoint of Service chaos-mesh-controller-manager (see
# The controller's webhook in the header), polling its EndpointSlices every 5 s; WHEN names the moment. Prints one line
# and records the wait, the endpoints and the controller's pods (node, restarts) as controller.WHEN of the step's part
# of the results file; false, with chaos_why, when no endpoint was Ready in time. No fault is applied while it waits.
chaos_controller_ready() {
  local start t n pods
  start=$(date +%s)
  while :; do
    n=$(kc --request-timeout=10s -n chaos-mesh get endpointslices -l kubernetes.io/service-name=chaos-mesh-controller-manager \
      -o json 2>/dev/null | jq '[.items[].endpoints[]?
        | select(.conditions.ready != false and .conditions.terminating != true) | .addresses[]] | length' 2>/dev/null)
    t=$(date +%s)
    [[ ${n:-} =~ ^[1-9] ]] && break
    [ $((t - start)) -lt 120 ] || break
    sleep 5
  done
  [[ ${n:-} =~ ^[0-9]+$ ]] || n=null
  pods=$(chaos_controller_pods)
  [ -n "$pods" ] || pods=null
  chaos_put "$chaos_key" "$(jq -nc --arg w "$1" --argjson n "$n" --argjson s $((t - start)) --argjson p "$pods" '
    {controller: {($w): {ready_endpoints: $n, waited_s: $s, ready: ($n != null and $n > 0), pods: $p}}}')"
  if [[ $n =~ ^[1-9] ]]; then
    echo "controller: the webhook's endpoint Ready after $((t - start)) s ($1; pods: $(jq -r 'if . == null then "unread"
      elif length == 0 then "none" else map("\(.pod) on \(.node), \(.restarts) restart(s)") | join("; ") end' <<<"$pods"))"
    return 0
  fi
  chaos_why="the controller's webhook (Service chaos-mesh-controller-manager) had no Ready endpoint within 120 s"
  chaos_why+=" ($1; pods: $(jq -r 'if . == null then "unread" elif length == 0 then "none"
    else map("\(.pod), \(.restarts) restart(s)") | join("; ") end' <<<"$pods"))"
  echo "FAIL  $chaos_why"
  return 1
}

# chaos_controller_pods: the controller's pods as [{pod, node, restarts}] on one line, nothing when the API did not
# answer.
chaos_controller_pods() {
  kc --request-timeout=10s -n chaos-mesh get pods -l app.kubernetes.io/component=controller-manager -o json 2>/dev/null |
    jq -c '[.items[] | {pod: .metadata.name, node: .spec.nodeName,
      restarts: ([.status.containerStatuses[]?.restartCount] | add // 0)}]' 2>/dev/null
}

# chaos_controller_stable SECONDS: the controller still runs SECONDS after its rollout (see The controller's webhook in
# the header): its pods and their restarts, read every 10 s, the same as at the start, then the log of each of those
# pods read for a refusal of the API server ("is forbidden"; each right refused as "cannot VERB resource R in API group
# G ..."). Prints one line and records controller_stable in the step's part of the results; false, with chaos_why, on
# no pod, a restart or another pod, a list or log the API did not give, or a refusal. Each request bounded (10 s).
chaos_controller_stable() {
  local start t first now pod log logs= unread= lines refused events
  start=$(date +%s)
  first=$(chaos_controller_pods)
  now=$first
  while [ "$(jq 'length' <<<"${first:-[]}")" -gt 0 ] && [ "$now" = "$first" ]; do
    [ $(($(date +%s) - start)) -lt "$1" ] || break
    sleep 10
    now=$(chaos_controller_pods)
  done
  t=$(date +%s)
  for pod in $(jq -r '.[]?.pod' <<<"${first:-[]}"); do
    if log=$(kc --request-timeout=10s -n chaos-mesh logs "$pod" 2>/dev/null); then
      logs+=$log$'\n'
    else
      unread+=" $pod"
    fi
  done
  # A refused Event is not counted: the chart grants the namespaced controller no right in its own namespace, so its
  # Events there (leader election) are rejected, and client-go drops an Event it cannot write without retrying; the
  # controller's work does not depend on them. They are recorded apart (events_refused).
  events=$(grep 'is forbidden' <<<"$logs" | grep -cE 'cannot create resource \\?"?events\\?"? ')
  lines=$(($(grep -c 'is forbidden' <<<"$logs") - events))
  refused=$(grep 'is forbidden' <<<"$logs" | grep -vE 'cannot create resource \\?"?events\\?"? ' | grep -oE 'cannot [a-z]+ resource \\?"?[a-z0-9.-]+\\?"? in API group \\?"?[a-z0-9.-]*\\?"?( at the cluster scope| in the namespace \\?"?[a-z0-9-]+\\?"?)?' |
    tr -d '\\"' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))')
  chaos_put "$chaos_key" "$(jq -nc --arg first "$first" --arg now "$now" --argjson s $((t - start)) --arg unread "$unread" \
    --argjson lines "$lines" --argjson refused "$refused" --argjson events "$events" '
    {controller_stable: {watched_s: $s, pods_at_start: ($first | fromjson? // null), pods_at_end: ($now | fromjson? // null),
      logs_unread: ($unread | split(" ") | map(select(length > 0))), forbidden_lines: $lines, refused: $refused,
      events_refused: $events}}')"
  if [ "$(jq 'length' <<<"${first:-[]}")" -eq 0 ]; then
    chaos_why="the controller's pods $([ -n "$first" ] && echo "not there" || echo "unread (the API did not answer)") after its rollout"
  elif [ -z "$now" ]; then
    chaos_why="the controller's pods unread (the API did not answer) $((t - start)) s after its rollout"
  elif [ "$now" != "$first" ]; then
    chaos_why="the controller restarted, or its pod changed, within $((t - start)) s of its rollout"
    chaos_why+=" (pods: $(jq -r 'map("\(.pod), \(.restarts) restart(s)") | join("; ")' <<<"$first") at the start;"
    chaos_why+=" $(jq -r 'map("\(.pod), \(.restarts) restart(s)") | join("; ")' <<<"$now") then)"
  elif [ -n "$unread" ]; then
    chaos_why="the controller's log unread (the API did not answer) for:$unread"
  elif [ "$lines" -gt 0 ]; then
    chaos_why="the API server refused the controller $lines time(s) in $((t - start)) s: $(jq -r 'if length == 0 then
      "rights not named in the log" else join("; ") end' <<<"$refused")"
  else
    echo "controller: running $((t - start)) s after its rollout, no restart, no refusal in its log ($(jq -r \
      'map("\(.pod) on \(.node)") | join("; ")' <<<"$first"))"
    return 0
  fi
  echo "FAIL  $chaos_why"
  return 1
}

# chaos_diag_object NAMESPACE KIND NAME: the experiment's status (its conditions; the record of each target container,
# with its events) and the Kubernetes events about it, read just before it is deleted, into the state directory for the
# step's diagnostics (chaos_diag); an experiment the API did not answer for is recorded as unread.
chaos_diag_object() {
  local obj ev
  mkdir -p "$chaos_state"
  obj=$(kc --request-timeout=5s -n "$1" get "$2" "$3" --ignore-not-found -o json 2>/dev/null) || obj=unread
  ev=$(kc --request-timeout=5s -n "$1" get events --field-selector "involvedObject.name=$3" -o json 2>/dev/null |
    jq -c '[.items[] | {type, reason, message, count, last: (.lastTimestamp // .eventTime)}]' 2>/dev/null)
  [ -n "$ev" ] || ev=null
  jq -nc --arg ns "$1" --arg kind "$2" --arg name "$3" --arg obj "$obj" --argjson ev "$ev" --argjson t "$(date +%s)" '
    {namespace: $ns, kind: $kind, name: $name, read_at: ($t | todate),
     status: (if $obj == "unread" then "unread (the API did not answer)" elif $obj == "" then "not there"
       else ($obj | fromjson? | .status) // "unread (not JSON)" end),
     events: $ev}' >"$chaos_state/object-$chaos_key-$3.json"
}

# chaos_diag KEY WHY: the diagnostics of KEY (see Diagnostics in the header) into chaos-<time>-diagnostics-<KEY>.json
# beside the results file, and its name into KEY's part of the results (diagnostics). The chaos-daemon logs are those
# of the nodes of chaos_target's pods, of every chaos-daemon when it has none (no target, or its pods gone). Each
# request bounded (10 s); a list the API did not answer is null.
chaos_diag() {
  local key=$1 why=$2 results file tmp pods nodes= tns tapp e ns kind name pod container node restarts run f prev
  results=$(cat "$chaos_state/json-path" 2>/dev/null)
  if [ -z "$results" ] || [ ! -f "$results" ]; then
    chaos_put "$key" '{}'
    results=$(cat "$chaos_state/json-path")
  fi
  file=${results%.json}-diagnostics-$key.json
  tmp=$(mktemp -d)
  # Experiments still there: their status now.
  for e in $(chaos_experiments_left 2>/dev/null); do
    IFS=/ read -r ns kind name <<<"$e"
    chaos_diag_object "$ns" "$kind" "$name"
  done
  pods=$(kc --request-timeout=10s -n chaos-mesh get pods -o json 2>/dev/null)
  jq -e '.items' >/dev/null 2>&1 <<<"$pods" || pods='{"items": null}'
  if [ -n "$chaos_target" ]; then
    read -r tns tapp <<<"$chaos_target"
    nodes=$(kc --request-timeout=10s -n "$tns" get pods -l "app.kubernetes.io/name=$tapp" -o json 2>/dev/null |
      jq -r '.items[].spec.nodeName // empty' 2>/dev/null | sort -u)
  fi
  : >"$tmp/logs.jsonl"
  # The controller's pods, and chaos-daemon's on the target's nodes (all of them without one): name, container, node,
  # restarts; the log of the run before only after a restart.
  jq -r --arg nodes "$nodes" '($nodes | split("\n") | map(select(length > 0))) as $n
    | .items[]? | (.metadata.labels["app.kubernetes.io/component"] // "") as $c | (.spec.nodeName // "-") as $node
    | select($c == "controller-manager" or ($c == "chaos-daemon" and (($n | length) == 0 or ($n | index([$node])) != null)))
    | [.metadata.name, .spec.containers[0].name, $node, ([.status.containerStatuses[]?.restartCount] | add // 0)]
    | @tsv' <<<"$pods" |
    while IFS=$'\t' read -r pod container node restarts; do
      for run in current previous; do
        prev=()
        if [ "$run" = previous ]; then
          [ "$restarts" != 0 ] || continue
          prev=(--previous)
        fi
        kc --request-timeout=10s -n chaos-mesh logs "$pod" -c "$container" --tail=200 ${prev[@]+"${prev[@]}"} </dev/null 2>&1 |
          jq -R . | jq -sc --arg pod "$pod" --arg c "$container" --arg node "$node" --arg run "$run" \
            '{pod: $pod, container: $c, node: $node, run: $run, lines: .}' >>"$tmp/logs.jsonl"
      done
    done
  kc --request-timeout=10s -n chaos-mesh get endpointslices -l kubernetes.io/service-name=chaos-mesh-controller-manager \
    -o json 2>/dev/null | jq -c '[.items[].endpoints[]? | {addresses, ready: .conditions.ready,
      terminating: .conditions.terminating, pod: .targetRef.name}]' >"$tmp/endpoints" 2>/dev/null
  kc --request-timeout=10s -n chaos-mesh get leases -o json 2>/dev/null | jq -c '[.items[] | {name: .metadata.name,
    holder: .spec.holderIdentity, renewed: .spec.renewTime, lease_s: .spec.leaseDurationSeconds,
    transitions: .spec.leaseTransitions}]' >"$tmp/leases" 2>/dev/null
  kc --request-timeout=10s -n chaos-mesh get events -o json 2>/dev/null | jq -c '[.items
    | sort_by(.lastTimestamp // .eventTime // "") | .[-50:][] | {type, reason, object: "\(.involvedObject.kind)/\(.involvedObject.name)",
      message, count, last: (.lastTimestamp // .eventTime)}]' >"$tmp/events" 2>/dev/null
  for f in endpoints leases events; do [ -s "$tmp/$f" ] || echo null >"$tmp/$f"; done
  cat "$chaos_state"/object-"$key"-*.json >"$tmp/objects.jsonl" 2>/dev/null || :
  jq -n --arg key "$key" --arg step "$chaos_step" --arg why "$why" --arg target "$chaos_target" --arg nodes "$nodes" \
    --argjson t "$(date +%s)" --argjson pods "$pods" --slurpfile logs "$tmp/logs.jsonl" \
    --slurpfile objects "$tmp/objects.jsonl" --slurpfile endpoints "$tmp/endpoints" --slurpfile leases "$tmp/leases" \
    --slurpfile events "$tmp/events" '
    {step: $step, key: $key, why: $why, at: ($t | todate),
     target: (if $target == "" then null else $target end),
     target_nodes: ($nodes | split("\n") | map(select(length > 0))),
     chaos_mesh_pods: ($pods.items | if . == null then null else map({name: .metadata.name,
       component: .metadata.labels["app.kubernetes.io/component"], node: .spec.nodeName, ip: .status.podIP,
       phase: .status.phase, deleting: (.metadata.deletionTimestamp != null),
       containers: [.status.containerStatuses[]? | {name, ready, restarts: .restartCount,
         state: (.state // {} | to_entries[0] // {key: "unknown", value: {}}
           | "\(.key)\(if .value.reason then " " + .value.reason else "" end)"),
         last_terminated: (.lastState.terminated | if . then {reason, exitCode, signal, startedAt, finishedAt} else null end)}]})
       end),
     webhook_endpoints: $endpoints[0], leases: $leases[0], events: $events[0],
     experiments: $objects, logs: $logs}' >"$tmp/diag.json" && mv "$tmp/diag.json" "$file"
  rm -rf "$tmp"
  if [ -f "$file" ]; then
    chaos_put "$key" "$(jq -nc --arg f "$(basename "$file")" '{diagnostics: $f}')"
    echo "diagnostics: $(basename "$file") ($(jq -r '"\(.chaos_mesh_pods // [] | length) pod(s) of Chaos Mesh," +
      " \(.logs | length) log tail(s), \(.experiments | length) experiment(s)"' "$file"))"
  else
    echo "diagnostics: $(basename "$file") not written"
  fi
}

# chaos_diag_failed: chaos_diag of the current step, once, when its result is fail.
chaos_diag_failed() {
  local results
  [ -z "$chaos_diag_done" ] && [ -n "$chaos_key" ] || return 0
  results=$(cat "$chaos_state/json-path" 2>/dev/null)
  [ "$(jq -r --arg k "$chaos_key" '.[$k].result // empty' "$results" 2>/dev/null)" = fail ] || return 0
  chaos_diag_done=1
  chaos_diag "$chaos_key" "$(jq -r --arg k "$chaos_key" '.[$k].reason // "fail"' "$results")"
}

# chaos_module NAME: the kernel module NAME of the running kernel: loaded (lsmod lists it), builtin (the kernel's
# modules.builtin lists it), available (modprobe -n finds it) or absent.
chaos_module() {
  if lsmod 2>/dev/null | awk -v m="$1" '$1 == m { f = 1 } END { exit !f }'; then
    echo loaded
  elif grep -qE "/$1\.ko(\.[a-z]+)?$" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null; then
    echo builtin
  elif modprobe -n -q "$1" 2>/dev/null; then
    echo available
  else
    echo absent
  fi
}

# chaos_netem: sch_netem on the runner (see Kernel module in the header): loaded with modprobe unless loaded or built
# in already, after installing linux-modules-extra-<kernel> when the kernel's modules lack it. Prints one line and
# records what it found and did as kernel of the trial's results; false, with chaos_why, when sch_netem is not loaded
# at the end.
chaos_netem() {
  local kernel pkg before after install= done
  kernel=$(uname -r)
  pkg=linux-modules-extra-$kernel
  before=$(chaos_module sch_netem)
  if [ "$before" = absent ]; then
    # DPkg::Lock::Timeout: the runner's own apt jobs may hold the lock for a while; the package lists are fetched only
    # when the install cannot find the package without them.
    if sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -q "$pkg" >/dev/null 2>&1 ||
      { sudo apt-get -o DPkg::Lock::Timeout=120 update -q >/dev/null 2>&1 &&
        sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -q "$pkg" >/dev/null 2>&1; }; then
      install=installed
    else
      install=failed
    fi
  fi
  case $before in loaded | builtin) ;; *) sudo modprobe sch_netem >/dev/null 2>&1 || : ;; esac
  after=$(chaos_module sch_netem)
  chaos_put trial "$(jq -nc --arg k "$kernel" --arg pkg "$pkg" --arg b "$before" --arg i "$install" --arg a "$after" \
    --arg dir "$([ -d "/lib/modules/$kernel" ] && echo true || echo false)" \
    --arg host "$(cat "$SVP_VERIFY_OUT/sch-netem" 2>/dev/null)" '
    {kernel: {release: $k, modules_dir: ($dir == "true"), host_check: (if $host == "" then null else $host end),
      sch_netem: {before: $b, package: (if $i == "" then null else {name: $pkg, result: $i} end), after: $a},
      ifb: "not used: the delay shapes the egress of the target pods only (direction to, no target)"}}')"
  done=${install:+, $pkg $install}
  case $after in
    loaded | builtin)
      echo "netem: sch_netem $after on kernel $kernel (before: $before$done)"
      return 0
      ;;
  esac
  chaos_why="sch_netem $after on kernel $kernel (before: $before$done): no network delay possible"
  echo "FAIL  netem: $chaos_why"
  return 1
}

# --- The steps.

# chaos_install: step chaos-mesh-install (see the header).
chaos_install() {
  chaos_config
  rm -rf "$chaos_state"
  mkdir -p "$chaos_state"
  : >"$chaos_state/windows.jsonl"
  chaos_guard chaos-mesh-install install
  local started k8s nodes daemons crds env scope multi
  started=$(date +%s)
  k8s=$(kc version -o json | jq -r '.serverVersion.gitVersion')
  # The commands of a cloud session (deploy/k8s/cloud/values/chaos-mesh.yaml), with the runner's overlay.
  kc create namespace chaos-mesh || { chaos_fail install "create namespace chaos-mesh"; return 1; }
  kc label namespace chaos-mesh pod-security.kubernetes.io/enforce=privileged ||
    { chaos_fail install "label namespace chaos-mesh privileged"; return 1; }
  chaos_upgrade || { chaos_fail install "helm upgrade --install chaos-mesh (Kubernetes $k8s)"; return 1; }
  kc -n chaos-mesh rollout status deployment/chaos-controller-manager --timeout=300s &&
    kc -n chaos-mesh rollout status daemonset/chaos-daemon --timeout=300s ||
    { chaos_fail install "controller or chaos-daemon not ready within 300 s (Kubernetes $k8s)"; return 1; }
  nodes=$(kc get nodes -o name | grep -c .)
  daemons=$(kc -n chaos-mesh get daemonset chaos-daemon -o jsonpath='{.status.numberReady}')
  crds=$(kc get crd -o name | grep -c '\.chaos-mesh\.org$')
  env=$(kc -n chaos-mesh get deployment chaos-controller-manager -o json |
    jq -c '.spec.template.spec.containers[0].env | map({(.name): .value}) | add')
  scope=$(jq -r '"\(.CLUSTER_SCOPED) \(.TARGET_NAMESPACE)"' <<<"$env")
  # The multi-cluster controllers, which the runner's overlay leaves out of the controller's list (its comment says
  # why): one of them on, or all of them ("*", the controller's default), and the controller exits 2 min after each
  # start.
  multi=$(jq -c '(.ENABLED_CONTROLLERS // "*") | split(",")
    | map(select(. == "*" or . == "remotecluster" or endswith("-remote-apply")))' <<<"$env")
  chaos_put install "$(jq -nc --arg k8s "$k8s" --argjson nodes "$nodes" --argjson daemons "${daemons:-0}" \
    --argjson crds "$crds" --arg scope "$scope" --argjson multi "${multi:-null}" --argjson s $(($(date +%s) - started)) '
    {kubernetes: $k8s, chart: "chaos-mesh 2.8.5", chart_tested_up_to: "Kubernetes 1.35 (its CI)",
     kyverno: "Audit on the dev path: a pod-failure in svp would not be refused; (c) stays in svp-data as designed",
     nodes: $nodes, chaos_daemons_ready: $daemons, crds: $crds,
     cluster_scoped: ($scope | split(" ")[0]), target_namespace: ($scope | split(" ")[1]),
     multicluster_controllers_on: $multi, seconds: $s}')"
  echo "Chaos Mesh 2.8.5 on Kubernetes $k8s: chaos-daemon ready on $daemons of $nodes node(s), $crds CRDs, controller" \
    "CLUSTER_SCOPED/TARGET_NAMESPACE $scope, multi-cluster controllers on: ${multi:-unread}"
  if ! { [ "$daemons" = "$nodes" ] && [ "$crds" -gt 0 ] && [ "$scope" = "false svp" ] && [ "$multi" = "[]" ]; }; then
    chaos_fail install "not as installed by design: chaos-daemon ready on ${daemons:-0} of $nodes node(s), $crds CRDs, controller CLUSTER_SCOPED/TARGET_NAMESPACE '$scope' (false svp expected), multi-cluster controllers on: ${multi:-unread} (none expected)"
    return 1
  fi
  # Past the 2 min the controller waits for its caches to sync, after which a controller refused a list exits: the
  # trial comes only after.
  chaos_controller_stable 150 || { chaos_fail install "$chaos_why"; return 1; }
  chaos_put install '{"result": "pass"}'
}

# chaos_rtt: milliseconds that 20 TCP connections in a row from the test pod to the cluster DNS (port 53) take, as the
# runner times the kubectl exec that runs them (its own overhead is the same before, during and after); empty when a
# connection failed.
chaos_rtt() {
  local a b
  a=$(date +%s%3N)
  # shellcheck disable=SC2016 # expanded by the pod's sh
  kc -n svp exec chaos-probe -- sh -c 'i=0; while [ $i -lt 20 ]; do nc -z -w 3 "$1" 53 || exit 1; i=$((i + 1)); done' \
    _ "$1" >/dev/null 2>&1 || return 0
  b=$(date +%s%3N)
  echo $((b - a))
}

# chaos_trial: step chaos-b-trial (see the header).
chaos_trial() {
  chaos_config
  chaos_guard chaos-b-trial trial
  chaos_target='svp chaos-probe'
  local image dns before during after injected i held=true r
  chaos_netem || { chaos_fail trial "$chaos_why"; return 1; }
  image=$(kc -n svp get deployment media-worker -o jsonpath='{.spec.template.spec.containers[0].image}')
  dns=$(kc -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')
  [ -n "$image" ] && [ -n "$dns" ] || { chaos_fail trial "read the media-worker image and the DNS Service's address"; return 1; }
  # Pod Security restricted, no token, the image's own shell and nc; made before the k6 run, so that its hold does not
  # wait for it, and alive for the run's setup and ramp as well. Written as JSON: a here-document would not survive the
  # export of this function to the step's bash.
  jq -n --arg image "$image" '{apiVersion: "v1", kind: "Pod",
    metadata: {name: "chaos-probe", namespace: "svp", labels: {"app.kubernetes.io/name": "chaos-probe"}},
    spec: {automountServiceAccountToken: false, restartPolicy: "Never", terminationGracePeriodSeconds: 1,
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "probe", image: $image, command: ["sleep", "3600"],
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {cpu: "200m", memory: "64Mi"}}}]}}' |
    kc apply -f - || { chaos_fail trial "create pod svp/chaos-probe"; return 1; }
  kc -n svp wait --for=condition=Ready pod/chaos-probe --timeout=120s ||
    { chaos_fail trial "pod svp/chaos-probe Ready within 120 s"; return 1; }
  chaos_k6_begin trial "$chaos_hold_trial" "trial.ms_for_20_before: the 20 connections before the delay, in this window" ||
    { chaos_fail trial "k6 not holding its load: $chaos_why"; return 1; }
  chaos_controller_ready trial || { chaos_fail trial "$chaos_why"; return 1; }
  chaos_open trial 240 || { chaos_fail trial "k6 not holding its load: $chaos_why"; return 1; }
  before=$(chaos_rtt "$dns")
  kc apply -f "$chaos_files/b-trial-network-delay-probe.yaml" || { chaos_fail trial "apply the trial"; return 1; }
  injected=false
  chaos_injected svp networkchaos network-delay-trial && injected=true
  during=$(chaos_rtt "$dns")
  chaos_diag_object svp networkchaos network-delay-trial
  kc -n svp delete networkchaos network-delay-trial --timeout=60s || echo "delete networkchaos network-delay-trial failed"
  # The delay goes with the object; three tries over 30 s for the last packets held back.
  for i in 1 2 3; do
    after=$(chaos_rtt "$dns")
    [ -n "$after" ] && [ -n "$before" ] && [ $((after - before)) -le 1000 ] && break
    [ "$i" = 3 ] || sleep 10
  done
  chaos_close || held=false
  kc -n svp delete pod chaos-probe --wait=false
  chaos_put trial "$(jq -nc --argjson inj "$injected" --arg b "$before" --arg d "$during" --arg a "$after" \
    --argjson held "$held" --arg why "$chaos_why" '
    def n: if . == "" then null else tonumber end;
    ($b | n) as $b | ($d | n) as $d | ($a | n) as $a |
    {injected: $inj, connections: 20, target: "the cluster DNS Service, TCP 53",
     ms_for_20_before: $b, ms_for_20_during: $d, ms_for_20_after: $a,
     extra_ms_per_connection_during: (if $b and $d then ($d - $b) / 20 | round else null end),
     extra_ms_per_connection_after: (if $b and $a then ($a - $b) / 20 | round else null end)}
    | .result = (if ($held | not) or .extra_ms_per_connection_during == null or .extra_ms_per_connection_after == null
        then "fail"
        elif .injected and .extra_ms_per_connection_during >= 150 and .extra_ms_per_connection_after <= 50 then "pass"
        else "fail" end)
    | if ($held | not) then .reason = "k6 not holding its load at the end of the trial: \($why)"
      elif .result == "pass" then .
      elif .extra_ms_per_connection_during == null or .extra_ms_per_connection_after == null then
        .reason = "a run of 20 connections failed"
      elif (.injected | not) then .reason = "the delay was not injected within 60 s"
      else .reason = "per connection +\(.extra_ms_per_connection_during) ms during (at least 150), +\(.extra_ms_per_connection_after) ms after (at most 50)"
      end')"
  jq -r '.trial | "trial: \(.result)\(if .reason then " (\(.reason))" else "" end); 20 connections \(.ms_for_20_before) ms before, \(.ms_for_20_during) ms during, \(.ms_for_20_after) ms after (per connection +\(.extra_ms_per_connection_during) / +\(.extra_ms_per_connection_after) ms)"' \
    "$(cat "$chaos_state/json-path")"
  chaos_k6_finish trial
  r=$?
  [ "$(jq -r .trial.result "$(cat "$chaos_state/json-path")")" = pass ] && [ "$r" = 0 ]
}

# chaos_kill FILE APP: applies the PodChaos of FILE (one pod of APP in svp killed), then sets chaos_killed_at (when a
# pod that was Ready went), chaos_replicas (the Ready pods before) and chaos_ready_s (the kill to as many Ready pods
# again, one of them new; empty when not within 180 s); deletes the experiment, its status read first for the step's
# diagnostics (chaos_diag_object). The early stop is checked every 15 s all along (chaos_watch_due). Returns 1 when no
# pod went within 60 s (chaos_why says why), 2 on an early stop.
chaos_kill() {
  local before t deadline now rc=0
  chaos_killed_at= chaos_ready_s= chaos_watched_at=
  before=$(chaos_ready svp "$2") || { chaos_why="the API did not list the Ready pods of $2"; return 1; }
  chaos_replicas=$(grep -c . <<<"$before")
  kc apply -f "$1" || { chaos_why="apply $(basename "$1") failed"; return 1; }
  deadline=$(($(date +%s) + 60))
  while [ -z "$chaos_killed_at" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    chaos_watch_due || { rc=2; break; }
    # A list the API did not answer says nothing of the pods: read again.
    if now=$(chaos_alive svp "$2"); then
      for t in $before; do grep -qxF "$t" <<<"$now" || chaos_killed_at=$(date +%s); done
    fi
    [ -n "$chaos_killed_at" ] || sleep 1
  done
  if [ "$rc" = 0 ] && [ -z "$chaos_killed_at" ]; then
    chaos_diag_object svp podchaos "pod-kill-$2"
    kc delete -f "$1" --ignore-not-found
    chaos_why="no pod of $2 killed within 60 s of applying $(basename "$1")"
    return 1
  fi
  if [ "$rc" = 0 ]; then
    echo "a pod of $2 killed at $(date -u -d "@$chaos_killed_at" +%H:%M:%SZ), $chaos_replicas Ready before"
    deadline=$((chaos_killed_at + 180))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      chaos_watch_due || { rc=2; break; }
      if now=$(chaos_ready svp "$2") && [ "$(grep -c . <<<"$now")" -ge "$chaos_replicas" ] &&
        [ -n "$(comm -13 <(sort <<<"$before") <(sort <<<"$now"))" ]; then
        chaos_ready_s=$(($(date +%s) - chaos_killed_at))
        break
      fi
      sleep 1
    done
    if [ -n "$chaos_ready_s" ]; then
      echo "$2: as many pods Ready again, one of them new, $chaos_ready_s s after the kill"
    elif [ "$rc" = 0 ]; then
      echo "$2: not as many pods Ready again within 180 s of the kill"
    fi
  fi
  # As in chaos_delete_watched: the early stop is checked around the two bounded reads of the diagnostics, so that no
  # more than 25 s pass between two checks while the pods come back.
  if [ "$rc" = 0 ] && ! chaos_watch_due; then rc=2; fi
  chaos_diag_object svp podchaos "pod-kill-$2"
  if [ "$rc" = 0 ] && ! chaos_watch_due; then rc=2; fi
  kc delete -f "$1" --ignore-not-found
  return "$rc"
}

# chaos_kill_numbers APP: the numbers and verdict of the kill chaos_kill just made (see a-pod-kill-*.yaml), as JSON,
# with the checks of the early stop left unread since the kill (chaos_watch_unread).
chaos_kill_numbers() {
  local k=$chaos_killed_at ratio p99b p99a envoy pages
  ratio=$(chaos_q "$(chaos_ratio_query 600s)" $((k + 300)))
  p99b=$(chaos_q "$(chaos_p99_query 300s)" "$k")
  p99a=$(chaos_q "$(chaos_p99_query 270s)" $((k + 300)))
  envoy=$(chaos_q "$(chaos_envoy_query 300s)" $((k + 300)))
  pages=$(chaos_q "$(chaos_pages_query 600s)" $((k + 300)))
  jq -nc --arg app "$1" --argjson k "$k" --argjson rep "$chaos_replicas" --argjson ready "${chaos_ready_s:-null}" \
    --argjson ratio "$ratio" --argjson p99b "$p99b" --argjson p99a "$p99a" --argjson envoy "$envoy" --argjson pages "$pages" \
    --argjson unread "$chaos_watch_unread" '
    {app: $app, killed_at: ($k | todate), replicas_ready_at_kill: $rep, replacement_ready_s: $ready,
     feed_5xx_ratio_10m: $ratio, feed_p99_ms_5m_before: $p99b, feed_p99_ms_after_first_30s: $p99a,
     envoy_api_5xx_ratio_5m_after: $envoy, page_alerts_fired_10m: $pages, early_stop_checks_unread: $unread}
    | .unmeasured = ([{feed_5xx_ratio_10m: $ratio, feed_p99_ms_5m_before: $p99b, feed_p99_ms_after_first_30s: $p99a,
        page_alerts_fired_10m: $pages} | to_entries[] | select(.value == null) | .key]
        + (if $unread > 0 then ["early_stop (\($unread) check(s) unread)"] else [] end))
    | .findings = (
        (if $ready == null then ["the new pod of \($app) was not Ready within 180 s of the kill"] else [] end) +
        (if $rep < 2 then ["only \($rep) replica of \($app) Ready at the kill: the feed went without it until the new pod was Ready (\($ready // "not within 180") s); a finding about its minimum replica count, not a failed hypothesis"]
         else
           (if $ratio != null and $ratio >= 0.001 then ["feed 5xx \($ratio * 10000 | round / 100)% over the 10 min around the kill (hypothesis < 0.1%)"] else [] end) +
           (if $p99b != null and $p99b > 150 then ["feed p99 \($p99b | round) ms in the 5 min before the kill (hypothesis <= 150)"] else [] end) +
           (if $p99a != null and $p99a > 150 then ["feed p99 \($p99a | round) ms after the first 30 s (hypothesis <= 150)"] else [] end) +
           (if $ready != null and $ready > 60 then ["new pod Ready \($ready) s after the kill (hypothesis < 60 s)"] else [] end) +
           (if $pages != null and $pages > 0 then ["\($pages) page alert(s) fired in the 10 min around the kill"] else [] end)
         end))
    | .result = (if (.unmeasured | length) > 0 then "fail" elif (.findings | length) > 0 then "finding" else "pass" end)'
}

# chaos_report KEY: the result of KEY with its findings, from the results file; true unless it is fail.
chaos_report() {
  jq -r --arg k "$1" '.[$k] | "\($k): \(.result)\(if .reason then " (\(.reason))" else "" end)",
    (.. | objects | (.findings // [])[] | "  FINDING  \(.)"),
    (.. | objects | select((.unmeasured // []) | length > 0) | "  unmeasured: \(.unmeasured | join(", "))")' \
    "$(cat "$chaos_state/json-path")"
  [ "$(jq -r --arg k "$1" '.[$k].result' "$(cat "$chaos_state/json-path")")" != fail ]
}

# chaos_a: step chaos-a (see the header).
chaos_a() {
  chaos_config
  chaos_guard chaos-a a
  chaos_api
  prometheus_forward
  local t0 steady gw fs app file r
  chaos_k6_begin a "$chaos_hold_a" "a.steady: the 5 min before the gateway kill; a.steady_before_feed_service for the second kill" ||
    { chaos_fail a "k6 not holding its load: $chaos_why"; return 1; }
  chaos_open steady 300 || { chaos_fail a "k6 not holding its load: $chaos_why"; return 1; }
  t0=$chaos_win_from
  chaos_wait_until $((t0 + 300))
  chaos_close || { chaos_fail a "k6 not holding its load at the end of the steady state: $chaos_why"; return 1; }
  sleep 30
  if ! steady=$(chaos_steady "$t0" $((t0 + 300))); then
    chaos_put a "$(jq -nc --argjson s "${steady:-null}" '{steady: $s}')"
    chaos_fail a "no steady state before the gateway kill"
    chaos_mark_stop "no steady state before experiment (a)"
    return 1
  fi
  chaos_put a "$(jq -nc --argjson s "$steady" '{steady: $s}')"
  for app in gateway feed-service; do
    file=$chaos_files/a-pod-kill-$app.yaml
    chaos_target="svp $app"
    chaos_controller_ready "kill-$app" || { chaos_fail a "$chaos_why"; return 1; }
    chaos_open "kill-$app" 400 || { chaos_fail a "k6 not holding its load before the $app kill: $chaos_why"; return 1; }
    chaos_watch_unread=0
    chaos_kill "$file" "$app"
    case $? in
      1)
        chaos_fail a "$chaos_why"
        return 1
        ;;
      2)
        chaos_stopped_early a "after the $app kill" svp "$app" "$chaos_replicas"
        return 1
        ;;
    esac
    chaos_close || { chaos_fail a "k6 not holding its load during the $app kill: $chaos_why"; return 1; }
    chaos_open "recovery-$app" $((chaos_killed_at + 300 - $(date +%s))) ||
      { chaos_fail a "k6 not holding its load after the $app kill: $chaos_why"; return 1; }
    if ! chaos_wait_until $((chaos_killed_at + 300)) chaos_watch; then
      chaos_stopped_early a "after the $app kill" svp "$app" "$chaos_replicas"
      return 1
    fi
    chaos_close || { chaos_fail a "k6 not holding its load at the end of the $app recovery: $chaos_why"; return 1; }
    # Prometheus has the window's last samples 30 s after it closed.
    sleep 30
    if [ "$app" = feed-service ]; then
      fs=$(chaos_kill_numbers feed-service)
      continue
    fi
    gw=$(chaos_kill_numbers gateway)
    chaos_put a "$(jq -nc --argjson g "$gw" '{gateway: $g}')"
    # The steady state of the second kill: the window after the first, from 30 s on, and the gateway's pods back.
    steady=$(chaos_steady $((chaos_killed_at + 30)) $((chaos_killed_at + 300)))
    r=$?
    chaos_put a "$(jq -nc --argjson s "${steady:-null}" '{steady_before_feed_service: $s}')"
    if [ "$r" != 0 ] || [ "$(chaos_ready svp gateway | grep -c .)" -lt "$chaos_replicas" ]; then
      chaos_fail a "not back to steady state after the gateway kill"
      chaos_mark_stop "the cluster was not back to steady state after the gateway kill"
      return 1
    fi
  done
  chaos_put a "$(jq -nc --argjson g "$gw" --argjson f "$fs" '{gateway: $g, feed_service: $f,
    result: ([$g.result, $f.result] | if any(. == "fail") then "fail" elif any(. == "finding") then "finding" else "pass" end)}')"
  chaos_k6_finish a
  r=$?
  chaos_report a && [ "$r" = 0 ]
}

# chaos_explore_stats: GET /feed/explore as the step's user; prints "STATUS ITEMS WITH_STATS".
chaos_explore_stats() {
  local status
  status=$(request GET "/feed/explore?page_size=20" "$work/chaos.auth")
  echo "$status $(jq '.items | length' "$work/body" 2>/dev/null || echo 0) $(jq '[.items[] | select(.stats != null)] | length' "$work/body" 2>/dev/null || echo 0)"
}

# chaos_b: step chaos-b (see the header).
chaos_b() {
  chaos_config
  chaos_guard chaos-b b
  chaos_target='svp engagement-service'
  chaos_api
  prometheus_forward
  local t0 t1 t_end steady base_feed during_feed back_s r ratio p99 lv5 lv breaker cbo
  new_user chaos
  chaos_k6_begin b "$chaos_hold_b" "b.steady: the 5 min before the delay, with the feed's stats read then" ||
    { chaos_fail b "k6 not holding its load: $chaos_why"; return 1; }
  base_feed=$(chaos_explore_stats)
  chaos_open steady 300 || { chaos_fail b "k6 not holding its load: $chaos_why"; return 1; }
  t0=$chaos_win_from
  chaos_wait_until $((t0 + 300))
  chaos_close || { chaos_fail b "k6 not holding its load at the end of the steady state: $chaos_why"; return 1; }
  sleep 30
  breaker=$(chaos_q 'max(max_over_time(svp_breaker_state{service_name="gateway"}[300s]))' $((t0 + 300)))
  if ! steady=$(chaos_steady "$t0" $((t0 + 300))) || [ "$breaker" != 0 ] || [ "$(cut -d ' ' -f 3 <<<"$base_feed")" = 0 ]; then
    chaos_put b "$(jq -nc --argjson s "${steady:-null}" --argjson br "$breaker" --arg f "$base_feed" \
      '{steady: ($s + {breaker_max: $br, explore_status_items_with_stats: $f})}')"
    chaos_fail b "no steady state before the delay (breaker $breaker, explore $base_feed)"
    chaos_mark_stop "no steady state before experiment (b)"
    return 1
  fi
  chaos_put b "$(jq -nc --argjson s "$steady" --argjson br "$breaker" --arg f "$base_feed" \
    '{steady: ($s + {breaker_max: $br, explore_status_items_with_stats: $f})}')"
  chaos_controller_ready delay || { chaos_fail b "$chaos_why"; return 1; }
  chaos_open delay 480 || { chaos_fail b "k6 not holding its load for the delay: $chaos_why"; return 1; }
  chaos_watch_unread=0 chaos_watched_at=
  kc apply -f "$chaos_files/b-network-delay-engagement.yaml" || { chaos_fail b "apply the delay"; return 1; }
  chaos_injected svp networkchaos network-delay-engagement watch
  case $? in
    1)
      chaos_delete_watched svp networkchaos network-delay-engagement 60
      chaos_fail b "the delay was not injected within 60 s"
      return 1
      ;;
    2)
      chaos_delete_watched svp networkchaos network-delay-engagement 60
      chaos_stopped_early b "while the delay was injected" svp engagement-service 1
      return 1
      ;;
  esac
  t1=$(date +%s)
  r=0
  chaos_wait_until $((t1 + 60)) chaos_watch && during_feed=$(chaos_explore_stats) &&
    chaos_wait_until $((t1 + 300)) chaos_watch || r=1
  chaos_delete_watched svp networkchaos network-delay-engagement 60
  t_end=$(date +%s)
  if [ "$r" = 1 ]; then
    chaos_stopped_early b "during the delay" svp engagement-service 1
    return 1
  fi
  chaos_close || { chaos_fail b "k6 not holding its load at the end of the delay: $chaos_why"; return 1; }
  chaos_open recovery 120 || { chaos_fail b "k6 not holding its load after the delay: $chaos_why"; return 1; }
  back_s=
  while [ $(($(date +%s) - t_end)) -lt 120 ]; do
    chaos_watch_due || { chaos_stopped_early b "after the delay" svp engagement-service 1; return 1; }
    if [ "$(cut -d ' ' -f 3 <<<"$(chaos_explore_stats)")" -gt 0 ]; then
      back_s=$(($(date +%s) - t_end))
      break
    fi
    sleep 5
  done
  chaos_close || { chaos_fail b "k6 not holding its load at the end of the recovery: $chaos_why"; return 1; }
  sleep 30
  ratio=$(chaos_q "$(chaos_ratio_query 300s)" $((t1 + 300)))
  p99=$(chaos_q "$(chaos_p99_query 300s)" $((t1 + 300)))
  local lvsel='service_name="gateway",http_route=~"/videos/[{]video_id[}]/(like|views)"'
  lv5=$(chaos_q "$(chaos_n5 "$lvsel" 300s)" $((t1 + 300)))
  lv=$(chaos_q "$(chaos_n "$lvsel" 300s)" $((t1 + 300)))
  breaker=$(chaos_q 'max(max_over_time(svp_breaker_state{service_name="gateway"}[300s]))' $((t1 + 300)))
  cbo=$(chaos_q 'max(max_over_time(ALERTS{alertname="CircuitBreakerOpen",alertstate="firing"}[300s])) or vector(0)' $((t1 + 300)))
  chaos_put b "$(jq -nc --argjson t1 "$t1" --arg during "${during_feed:-}" --argjson back "${back_s:-null}" \
    --argjson ratio "$ratio" --argjson p99 "$p99" --argjson lv5 "$lv5" --argjson lv "$lv" --argjson br "$breaker" \
    --argjson cbo "$cbo" --argjson unread "$chaos_watch_unread" '
    ($during | split(" ") | map(tonumber? // null)) as $d |
    {injected_at: ($t1 | todate), latency_ms: 200, jitter_ms: 20, seconds: 300,
     feed_5xx_ratio: $ratio, feed_p99_ms: $p99, like_view_requests: $lv, like_view_5xx: $lv5,
     breaker_max: $br, circuit_breaker_open_fired: $cbo,
     explore_during: {status: $d[0], items: $d[1], items_with_stats: $d[2]}, stats_back_s_after_end: $back,
     early_stop_checks_unread: $unread}
    | .unmeasured = ([{feed_5xx_ratio: $ratio, feed_p99_ms: $p99, like_view_requests: $lv, breaker_max: $br,
        explore_during: $d[0]} | to_entries[] | select(.value == null) | .key]
        + (if $lv == 0 then ["like_view_requests (none in the window)"] else [] end)
        + (if $unread > 0 then ["early_stop (\($unread) check(s) unread)"] else [] end))
    | .findings = (
        (if $ratio != null and $ratio >= 0.001 then ["feed 5xx \($ratio * 10000 | round / 100)% while delayed (hypothesis < 0.1%)"] else [] end) +
        (if $p99 != null and $p99 > 150 then ["feed p99 \($p99 | round) ms while delayed (hypothesis <= 150): a finding about the gateway'"'"'s call deadlines"] else [] end) +
        (if $lv5 != null and $lv5 > 0 then ["\($lv5 | round) like or view request(s) answered 5xx while delayed (hypothesis: none)"] else [] end) +
        (if ($br // 0) > 0 or ($cbo // 0) > 0 then ["the breaker opened (state max \($br), CircuitBreakerOpen fired \($cbo)) while engagement-service was slow, not down"] else [] end) +
        (if $d[0] != null and $d[0] != 200 then ["GET /feed/explore answered \($d[0]) while delayed (hypothesis 200)"] else [] end) +
        (if $d[2] != null and $d[2] > 0 then ["\($d[2]) feed item(s) still had stats while delayed: the 100 ms deadline did not cut the call"] else [] end) +
        (if $back == null then ["stats not back within 120 s of the end"] elif $back > 60 then ["stats back \($back) s after the end (hypothesis: within a minute)"] else [] end))
    | .result = (if (.unmeasured | length) > 0 then "fail" elif (.findings | length) > 0 then "finding" else "pass" end)')"
  chaos_k6_finish b
  r=$?
  chaos_report b && [ "$r" = 0 ]
}

# chaos_rpk ARGS...: rpk in the broker pod, as the drills' rpk, cut off after 10 s: a broker that does not answer must
# not hold up the checks of the early stop between two reads.
chaos_rpk() { timeout 10 kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk "$@"; }

# chaos_lag: "GROUP LAG" of every consumer group (the TOTAL-LAG of rpk group describe), one group per line; false with
# nothing printed when rpk did not answer for the list or the description, listed no group (a broker back from its
# outage that has not loaded them yet: the services always have some), or described a listed group without its lag.
# Each rpk call is checked on its own: in a pipe its failure would be awk's empty output, read as no lag.
chaos_lag() {
  local out groups lags
  out=$(chaos_rpk group list) || return 1
  groups=$(awk 'NR > 1 { print $2 }' <<<"$out")
  [ -n "$groups" ] || return 1
  # shellcheck disable=SC2086 # one group per word
  out=$(chaos_rpk group describe $groups) || return 1
  lags=$(awk '$1 == "GROUP" { g = $2 } $1 == "TOTAL-LAG" && g != "" && $2 ~ /^[0-9]+$/ { print g, $2; g = "" }' <<<"$out")
  [ "$(cut -d ' ' -f 1 <<<"$lags" | sort -u)" = "$(sort -u <<<"$groups")" ] || return 1
  printf '%s\n' "$lags"
}
# chaos_sample_lag: appends a read of every group's lag to $work/lag.steady (chaos_wait_until runs it during the steady
# state); an unread one adds nothing.
chaos_sample_lag() { chaos_lag >>"$work/lag.steady" || :; }

# chaos_lag_targets FILE: the lag of experiment c (see Lag in the header) from the steady state's reads in FILE ("GROUP
# LAG" lines), as JSON: each group with its highest lag then (steady_max) and the lag it must be back to (target: 0,
# its steady_max for a group of chaos_lag_batch_groups), and the reads after the return so far.
chaos_lag_targets() {
  awk '$2 ~ /^[0-9]+$/ { if (!($1 in m) || $2 + 0 > m[$1]) m[$1] = $2 + 0 } END { for (g in m) print g, m[g] }' "$1" |
    jq -Rn --arg batch "$chaos_lag_batch_groups" '
      ($batch | split(" ") | map(select(length > 0))) as $b
      | {groups: ([inputs | select(length > 0) | split(" ") | .[0] as $g | (.[1] | tonumber) as $m
          | {key: $g, value: {steady_max: $m, target: (if ($b | index([$g])) != null then $m else 0 end),
              back_s_after_return: null, last: null}}] | from_entries),
         batch_groups: $b, reads_after_return: 0, unread_after_return: 0}'
}
# chaos_lag_steady_holds STATE: whether the steady state read every group at least once with each at most its target
# (every group outside chaos_lag_batch_groups at 0).
chaos_lag_steady_holds() { jq -e '(.groups | length) > 0 and ([.groups[]] | all(.steady_max <= .target))' <<<"$1" >/dev/null; }
# chaos_lag_read STATE LAGS SECONDS: STATE with one read after the return: LAGS (chaos_lag, or empty when unread)
# SECONDS after it. Each group of the steady state takes its lag as last; the first read at or under its target sets
# its back_s_after_return. A group the read lacks keeps what it had.
chaos_lag_read() {
  if [ -z "$2" ]; then
    jq -c '.unread_after_return += 1' <<<"$1"
    return
  fi
  jq -c --arg lags "$2" --argjson s "$3" '
    ($lags | split("\n") | map(select(length > 0) | split(" ") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $l
    | .reads_after_return += 1
    | .groups |= with_entries(.key as $g
        | if $l[$g] == null then .
          else .value.last = $l[$g]
            | if .value.back_s_after_return == null and $l[$g] <= .value.target then .value.back_s_after_return = $s
              else . end
          end)' <<<"$1"
}
# chaos_lag_back STATE: whether every group of the steady state has been back at or under its target.
chaos_lag_back() { jq -e '[.groups[]] | all(.back_s_after_return != null)' <<<"$1" >/dev/null; }

# chaos_dlq FILE: "TOPIC PARTITION HIGH-WATERMARK" of every dead-letter topic (<topic>.dlq; none until a first record
# goes to one) into FILE; false when rpk did not answer.
chaos_dlq() {
  local t topics
  : >"$1"
  topics=$(chaos_rpk topic list 2>/dev/null) || return 1
  for t in $(awk 'NR > 1 && $1 ~ /\.dlq$/ { print $1 }' <<<"$topics"); do
    chaos_rpk topic describe -p "$t" >"$1.t" 2>/dev/null || return 1
    awk -v t="$t" '$1 == "PARTITION" { table = 1; next } table && NF >= 3 { print t, $1, $NF }' "$1.t" >>"$1"
  done
  rm -f "$1.t"
}

# chaos_uploads_start: the three uploads of experiment c while the broker is down (create, the object store, complete;
# up to 70 s each), in the background so that the early stop is checked while they run (chaos_uploads_watch); its pid
# in chaos_up_pid. Each upload in a subshell of its own, so that a refused create or complete (which the helpers fail
# on) is a result and not the end of the others; its exit status into $work/c<i>.rc, its video id into $work/c<i>.id.
chaos_uploads_start() {
  (
    for i in 1 2 3; do
      (
        create "c$i" "$work/chaos.auth" "$work/clip.mp4"
        upload "c$i" "$work/clip.mp4"
        complete "c$i" "$work/chaos.auth"
        id_var=c${i}_id
        printf '%s\n' "${!id_var}" >"$work/c$i.id"
      )
      echo $? >"$work/c$i.rc"
    done
  ) &
  chaos_up_pid=$!
}
# chaos_uploads_watch: the early stop checked while the uploads run; returns 1 on an early stop, the uploads still
# running (they end on their own: the caller deletes the experiment first, then waits for them).
chaos_uploads_watch() {
  while kill -0 "$chaos_up_pid" 2>/dev/null; do
    chaos_watch_due || return 1
    sleep 1
  done
}
# chaos_uploads_result: once the uploads have ended, their results as a JSON list in chaos_up_json, their video ids in
# chaos_up_ids.
chaos_uploads_result() {
  local i id rc
  chaos_up_json='[]' chaos_up_ids=
  for i in 1 2 3; do
    id=$(cat "$work/c$i.id" 2>/dev/null)
    rc=$(cat "$work/c$i.rc" 2>/dev/null)
    chaos_up_json=$(jq -c --arg i "$i" --arg id "$id" --argjson ok "$([ "$rc" = 0 ] && echo true || echo false)" \
      '. + [{upload: ($i | tonumber), video_id: (if $id == "" then null else $id end), created_and_completed: $ok}]' \
      <<<"$chaos_up_json")
    [ -z "$id" ] || chaos_up_ids="$chaos_up_ids $id"
  done
}

# chaos_c: step chaos-c (see the header).
chaos_c() {
  chaos_config
  chaos_guard chaos-c c
  chaos_target='svp-data redpanda'
  chaos_api
  local t0 t1 t_end t_back steady target id st uploads lag lags deadline ready_at transcoded announced once='[]'
  local dlq_same ratio p99 post5 views5 r
  # The cloud session's command for experiment (c), with the runner's overlay.
  chaos_upgrade --set controllerManager.targetNamespace=svp-data || { chaos_fail c "helm upgrade to svp-data"; return 1; }
  target=$(kc -n chaos-mesh get deployment chaos-controller-manager -o json |
    jq -r '.spec.template.spec.containers[0].env | map({(.name): .value}) | add | .TARGET_NAMESPACE')
  [ "$target" = svp-data ] || { chaos_fail c "the controller targets '$target' after the upgrade, not svp-data"; return 1; }
  kc -n chaos-mesh rollout status deployment/chaos-controller-manager --timeout=180s ||
    { chaos_fail c "the controller not ready after the upgrade"; return 1; }
  # The new target restarted the controller: its webhook is back before anything else.
  chaos_controller_ready upgrade || { chaos_fail c "$chaos_why"; return 1; }
  prometheus_forward
  make_video "$work/clip.mp4" 2 320x240
  new_user chaos
  : >"$work/lag.steady"
  chaos_k6_begin c "$chaos_hold_c" "c.steady: the 5 min before the outage, with every consumer group's lag and the dead-letter topics read then" ||
    { chaos_fail c "k6 not holding its load: $chaos_why"; return 1; }
  chaos_open steady 300 || { chaos_fail c "k6 not holding its load: $chaos_why"; return 1; }
  t0=$chaos_win_from
  chaos_wait_until $((t0 + 300)) chaos_sample_lag
  chaos_close || { chaos_fail c "k6 not holding its load at the end of the steady state: $chaos_why"; return 1; }
  sleep 30
  lag=$(chaos_lag_targets "$work/lag.steady")
  if ! steady=$(chaos_steady "$t0" $((t0 + 300))) || ! chaos_lag_steady_holds "$lag" || ! chaos_dlq "$work/dlq.before"; then
    chaos_put c "$(jq -nc --argjson s "${steady:-null}" --argjson l "$lag" '{steady: ($s + {lag: $l})}')"
    chaos_fail c "no steady state before Redpanda's failure (the feed; the lag of every consumer group read, each outside $chaos_lag_batch_groups at 0; or the dead-letter topics unread)"
    chaos_mark_stop "no steady state before experiment (c)"
    return 1
  fi
  chaos_put c "$(jq -nc --argjson s "$steady" --argjson l "$lag" '{steady: ($s + {lag: $l})}')"
  chaos_controller_ready outage || { chaos_fail c "$chaos_why"; return 1; }
  # The outage does not start unless k6 holds its load for its recovery as well: injected (60), 300 down, deleted
  # (120), 120 for the broker, 900 for the videos, 60 to read the topics.
  chaos_open outage 1560 || { chaos_fail c "k6 not holding its load for the outage and its recovery: $chaos_why"; return 1; }
  chaos_watch_unread=0 chaos_watched_at=
  kc apply -f "$chaos_files/c-redpanda-failure.yaml" || { chaos_fail c "apply the Redpanda failure"; return 1; }
  t1=$(date +%s)
  chaos_injected svp-data podchaos redpanda-failure watch
  case $? in
    1)
      chaos_delete_watched svp-data podchaos redpanda-failure 120
      chaos_fail c "the Redpanda failure was not injected within 60 s"
      return 1
      ;;
    2)
      chaos_delete_watched svp-data podchaos redpanda-failure 120
      chaos_stopped_early c "while Redpanda's failure was injected" svp-data redpanda 1
      return 1
      ;;
  esac
  r=0
  chaos_uploads_start
  chaos_uploads_watch || r=1
  [ "$r" = 1 ] || chaos_wait_until $((t1 + 300)) chaos_watch || r=1
  chaos_delete_watched svp-data podchaos redpanda-failure 120
  t_end=$(date +%s)
  # The uploads end on their own (each request has its time limit); on an early stop they may still run here.
  wait "$chaos_up_pid"
  chaos_uploads_result
  uploads=$chaos_up_json
  chaos_put c "$(jq -nc --argjson u "$uploads" '{uploads: $u}')"
  if [ "$r" = 1 ]; then
    chaos_stopped_early c "during the outage" svp-data redpanda 1
    return 1
  fi
  chaos_close || { chaos_fail c "k6 not holding its load at the end of the outage: $chaos_why"; return 1; }
  chaos_open recovery 1020 || { chaos_fail c "k6 not holding its load after the outage: $chaos_why"; return 1; }
  t_back=
  while [ $(($(date +%s) - t_end)) -lt 120 ]; do
    chaos_watch_due || { chaos_stopped_early c "while Redpanda came back" svp-data redpanda 1; return 1; }
    if [ "$(chaos_ready svp-data redpanda | grep -c .)" -ge 1 ]; then
      t_back=$(date +%s)
      break
    fi
    sleep 2
  done
  if [ -z "$t_back" ]; then
    chaos_record_window true null
    chaos_fail c "Redpanda not Ready within 120 s of the end of the failure"
    chaos_mark_stop "Redpanda did not come back after experiment (c)"
    return 1
  fi
  echo "Redpanda back $((t_back - t_end)) s after the end of the failure"
  # The videos READY within 15 min of the return, every group's lag back to its target within 10 min. The early stop is
  # checked between any two requests: a lag read takes 20 s at most (chaos_rpk), a video's state 5 s.
  deadline=$((t_back + 900))
  ready_at='{}'
  while [ "$(date +%s)" -lt "$deadline" ]; do
    chaos_watch_due || { chaos_stopped_early c "after Redpanda's return" svp-data redpanda 1; return 1; }
    for id in $chaos_up_ids; do
      [ "$(jq -r --arg id "$id" '.[$id] // empty' <<<"$ready_at")" = "" ] || continue
      st=$(request GET "/videos/$id" "$work/chaos.auth")
      [ "$st" = 200 ] && [ "$(field status)" = READY ] &&
        ready_at=$(jq -c --arg id "$id" --argjson s $(($(date +%s) - t_back)) '.[$id] = $s' <<<"$ready_at")
      chaos_watch_due || { chaos_stopped_early c "after Redpanda's return" svp-data redpanda 1; return 1; }
    done
    if ! chaos_lag_back "$lag" && [ $(($(date +%s) - t_back)) -le 600 ]; then
      lags=$(chaos_lag) || lags=
      lag=$(chaos_lag_read "$lag" "$lags" $(($(date +%s) - t_back)))
    fi
    # Every video READY, and every group's lag back or its 10 min over.
    if [ "$(jq length <<<"$ready_at")" -ge "$(wc -w <<<"$chaos_up_ids")" ] &&
      { chaos_lag_back "$lag" || [ $(($(date +%s) - t_back)) -gt 600 ]; }; then
      break
    fi
    sleep 5
  done
  echo "lag after the return: $(jq -c '.groups | map_values({target, back_s_after_return, last})' <<<"$lag")"
  # The dead-letter topics 10 min after the return.
  chaos_wait_until $((t_back + 600)) chaos_watch ||
    { chaos_stopped_early c "after Redpanda's return" svp-data redpanda 1; return 1; }
  dlq_same=null
  chaos_dlq "$work/dlq.after" && { cmp -s "$work/dlq.before" "$work/dlq.after" && dlq_same=true || dlq_same=false; }
  chaos_watch_due || { chaos_stopped_early c "after Redpanda's return" svp-data redpanda 1; return 1; }
  read_topic media.transcodes.v1 "$work/transcodes"
  chaos_watch_due || { chaos_stopped_early c "after Redpanda's return" svp-data redpanda 1; return 1; }
  read_topic video.lifecycle.v1 "$work/lifecycle"
  for id in $chaos_up_ids; do
    transcoded=$(count_key "$work/transcodes" "$id" 12)
    announced=$(count_key "$work/lifecycle" "$id" 1a)
    once=$(jq -c --arg id "$id" --argjson t "$transcoded" --argjson a "$announced" \
      '. + [{video_id: $id, transcode_completed: $t, video_ready: $a}]' <<<"$once")
  done
  chaos_close || { chaos_fail c "k6 not holding its load at the end of the recovery: $chaos_why"; return 1; }
  sleep 30
  ratio=$(chaos_q "$(chaos_ratio_query 300s)" $((t1 + 300)))
  p99=$(chaos_q "$(chaos_p99_query 300s)" $((t1 + 300)))
  post5=$(chaos_q "$(chaos_n5 'service_name="gateway",http_request_method="POST",http_route="/videos"' 300s)" $((t1 + 300)))
  views5=$(chaos_q "$(chaos_n5 'service_name="gateway",http_route=~"/videos/[{]video_id[}]/views"' 300s)" $((t1 + 300)))
  chaos_put c "$(jq -nc --argjson t1 "$t1" --argjson te "$t_end" --argjson tb "$t_back" --argjson u "$uploads" \
    --argjson ready "$ready_at" --argjson once "$once" --argjson lag "$lag" --argjson dlq "$dlq_same" \
    --argjson ratio "$ratio" --argjson p99 "$p99" --argjson post5 "$post5" --argjson views5 "$views5" \
    --argjson unread "$chaos_watch_unread" '
    ($lag.groups | to_entries) as $g |
    {failed_at: ($t1 | todate), ended_at: ($te | todate), back_s_after_end: ($tb - $te), uploads: $u,
     ready_s_after_return: $ready, exactly_once: $once, lag: $lag, dlq_unchanged_10m_after: $dlq,
     feed_5xx_ratio: $ratio, feed_p99_ms: $p99, upload_init_5xx: $post5, view_5xx_counted_apart: $views5,
     early_stop_checks_unread: $unread}
    | .unmeasured = ([{feed_5xx_ratio: $ratio, feed_p99_ms: $p99, dlq_unchanged_10m_after: $dlq}
        | to_entries[] | select(.value == null) | .key]
        + ($g | map(select(.value.last == null) | "lag of group \(.key) (rpk never answered for it after the return)"))
        + (if $unread > 0 then ["early_stop (\($unread) check(s) unread)"] else [] end))
    | .findings = (
        ($u | map(select(.created_and_completed | not) | "upload \(.upload): create, upload or complete not answered as while Redpanda runs (hypothesis: the outbox keeps the events)")) +
        (if $post5 != null and $post5 > 0 then ["POST /videos answered 5xx \($post5 | round) time(s) during the outage"] else [] end) +
        (if $ratio != null and $ratio >= 0.001 then ["feed 5xx \($ratio * 10000 | round / 100)% during the outage (hypothesis < 0.1%)"] else [] end) +
        (if $p99 != null and $p99 > 150 then ["feed p99 \($p99 | round) ms during the outage (hypothesis <= 150)"] else [] end) +
        ($u | map(select(.video_id != null and ($ready[.video_id] == null)) | "video \(.video_id) not READY within 15 min of the return")) +
        ($once | map(select(.transcode_completed != 1 or .video_ready != 1) | "video \(.video_id): \(.transcode_completed) transcode.completed, \(.video_ready) video.ready (hypothesis: exactly once)")) +
        ($g | map(select(.value.last != null and .value.back_s_after_return == null)
          | "the lag of group \(.key) not back to \(.value.target) within 10 min of the return (last read \(.value.last))")) +
        (if $dlq == false then ["a dead-letter topic grew"] else [] end))
    | .result = (if (.unmeasured | length) > 0 then "fail" elif (.findings | length) > 0 then "finding" else "pass" end)')"
  chaos_k6_finish c
  r=$?
  chaos_report c && [ "$r" = 0 ]
}

# chaos_left: what of Chaos Mesh (and the trial's pod) is left, one per line; "unread: WHAT" for a list the API did not
# answer, so that an unanswered list never reads as nothing left.
chaos_left() {
  local out
  if out=$(chaos_experiments_left); then grep . <<<"$out"; else echo "unread: experiments"; fi
  if out=$(kc get crd -o name); then grep '\.chaos-mesh\.org$' <<<"$out"; else echo "unread: CRDs"; fi
  if out=$(kc get namespace chaos-mesh --ignore-not-found -o name); then grep . <<<"$out"; else echo "unread: namespace chaos-mesh"; fi
  if out=$(kc get mutatingwebhookconfigurations,validatingwebhookconfigurations,clusterroles,clusterrolebindings -o name); then
    grep -E '/chaos-mesh' <<<"$out"
  else
    echo "unread: webhook configurations, ClusterRoles, ClusterRoleBindings"
  fi
  if out=$(kc get roles,rolebindings -A -l app.kubernetes.io/instance=chaos-mesh -o name); then grep . <<<"$out"; else echo "unread: Roles, RoleBindings"; fi
  if out=$(chaos_helm list -A -q); then grep -x chaos-mesh <<<"$out"; else echo "unread: helm releases"; fi
  if out=$(kc -n svp get pod chaos-probe --ignore-not-found -o name); then grep . <<<"$out"; else echo "unread: pod svp/chaos-probe"; fi
}

# chaos_uninstall: step chaos-mesh-uninstall (see the header).
chaos_uninstall() {
  chaos_config
  chaos_guard chaos-mesh-uninstall uninstall
  local left gone=true
  # Whatever the experiments gave: the controller's restarts and logs of the whole scenario, before they go.
  chaos_diag_done=1
  chaos_diag uninstall "the state of Chaos Mesh at the end of the scenario, before its uninstall"
  chaos_delete_experiments
  kc -n svp delete pod chaos-probe --ignore-not-found --wait=false
  if chaos_experiments_gone 180; then
    chaos_teardown true
  else
    # Removing Chaos Mesh now would leave the fault injected: it stays, and the step fails with what is left.
    gone=false
  fi
  # A k6 Job a step cut short left behind (each step deletes its own).
  "${chaos_k6_run[@]}" delete || echo "chaos: run.sh delete failed"
  left=$(chaos_left)
  chaos_put uninstall "$(jq -nc --arg l "$left" --argjson gone "$gone" '{experiments_gone_first: $gone,
    left: ($l | split("\n") | map(select(length > 0)))}
    | .result = (if $gone and (.left | length) == 0 then "pass" else "fail" end)')"
  if [ -n "$left" ]; then
    printf 'FAIL  left after the uninstall:\n%s\n' "$left"
    return 1
  fi
  echo "ok    nothing of Chaos Mesh left: no experiment, CRD, webhook configuration, ClusterRole, ClusterRoleBinding, Role, RoleBinding, namespace or release"
}

export -f chaos_config chaos_helm chaos_upgrade chaos_put chaos_fail chaos_mark_stop chaos_delete_experiments \
  chaos_experiments_left chaos_experiments_gone chaos_teardown chaos_guard chaos_on_exit chaos_on_signal chaos_api \
  chaos_k6_holding chaos_k6_begin chaos_k6_finish chaos_open chaos_close chaos_record_window \
  chaos_wait_until chaos_q chaos_n chaos_n5 chaos_ratio_query chaos_p99_query chaos_envoy_query \
  chaos_pages_query chaos_steady chaos_watch chaos_watch_due chaos_ready chaos_alive chaos_recovered \
  chaos_stopped_early chaos_injected chaos_delete_watched chaos_controller_ready chaos_controller_pods \
  chaos_controller_stable chaos_diag_object chaos_diag \
  chaos_diag_failed chaos_module chaos_netem chaos_install chaos_rtt chaos_trial chaos_kill \
  chaos_kill_numbers chaos_report chaos_a chaos_explore_stats chaos_b chaos_rpk chaos_lag chaos_sample_lag \
  chaos_lag_targets chaos_lag_steady_holds chaos_lag_read chaos_lag_back chaos_dlq chaos_uploads_start \
  chaos_uploads_watch chaos_uploads_result chaos_c chaos_left chaos_uninstall

scenario_targets() {
  local chaos_off= chaos_stop_file=$SVP_VERIFY_OUT/chaos-state/stop chaos_trial_why
  step k8s-up 60 make k8s-up
  step seed-videos 40 bash -c 'k6mini_seed'
  case $last_status in fail | timeout) chaos_off="seed-videos did not pass" ;; esac
  step chaos-mesh-install 20 bash -c 'chaos_install'
  case $last_status in fail | timeout) chaos_off=${chaos_off:-"Chaos Mesh not installed"} ;; esac
  # Each experiment's limit: its k6 run's setup (15 min at most) and ramp (2), its hold (chaos_config), the Job's end
  # and its summary (5), what comes before the run (the kernel module and the probe pod of the trial, the helm upgrade
  # of c), and a margin.
  if [ -n "$chaos_off" ]; then
    skip chaos-b-trial "$chaos_off"
  else
    step chaos-b-trial 35 bash -c 'chaos_trial'
  fi
  local chaos_trial_status=$last_status
  # The trial's reason (sch_netem not loaded, the delay not injected, ...) on one line, for chaos-b's note.
  chaos_trial_why=$(jq -j '.trial.reason // empty' "$(cat "$SVP_VERIFY_OUT/chaos-state/json-path" 2>/dev/null)" 2>/dev/null |
    tr '\t\n' '  ')
  if [ -n "$chaos_off" ] || [ -s "$chaos_stop_file" ]; then
    skip chaos-a "${chaos_off:-$(cat "$chaos_stop_file")}"
  else
    step chaos-a 50 bash -c 'chaos_a'
  fi
  if [ -n "$chaos_off" ] || [ -s "$chaos_stop_file" ]; then
    skip chaos-b "${chaos_off:-$(cat "$chaos_stop_file")}"
  elif [ "$chaos_trial_status" != ok ]; then
    skip chaos-b "the trial of the network delay did not pass${chaos_trial_why:+: $chaos_trial_why}"
  else
    step chaos-b 40 bash -c 'chaos_b'
  fi
  if [ -n "$chaos_off" ] || [ -s "$chaos_stop_file" ]; then
    skip chaos-c "${chaos_off:-$(cat "$chaos_stop_file")}"
  else
    step chaos-c 75 bash -c 'chaos_c'
  fi
  step chaos-mesh-uninstall 15 bash -c 'chaos_uninstall'
}

# chaos_test: the self-test (see the header): the k6 holding check, a k6 run whose setup() does not end or whose end
# would fall past the pool's access, each experiment's own k6 run with its steady state (the trial's baseline) before
# its fault, its run ended and read when its step fails or stops early, the trap of a stopped step, the early stop
# while a killed pod's replacement is awaited and when a check is unread, the lag of each group (rpk failing, the
# targets, the return), the uploads under the early stop, the trial's k6 checks and the uninstall's unread lists, over
# fake kubectl, helm and run.sh first on PATH (and a fake clock for the waits). No cluster, no network. Exits 1 when a
# case fails.
chaos_test() {
  local work failures=0 now
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/repo/deploy/k6/cloud" "$work/repo/deploy/compose" "$work/out"
  # deploy/compose/lib.sh, which chaos_k6_begin sources to reset the register keys: nothing to reset here.
  : >"$work/repo/deploy/compose/lib.sh"
  export SVP_VERIFY_OUT=$work/out repo=$work/repo FAKE_LOG=$work/calls FAKE_DIR=$work
  ok() { echo "ok    $1"; }
  fail() {
    echo "FAIL  $1" >&2
    failures=$((failures + 1))
  }
  same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
  # kubectl: logs each call; fails every call while $FAKE_DIR/api-down exists; get job prints $FAKE_DIR/job.json (exit
  # 1 when absent); get endpointslices adds "<clock> endpoints" to $FAKE_DIR/events and prints endpoints.json, one
  # Ready endpoint without it, an endpoint not Ready while $FAKE_DIR/endpoints-wait counts down (one per call); logs in chaos-mesh prints one line naming its arguments; get pods prints cm-pods.json in
  # chaos-mesh (no pod without it), pods.json elsewhere; get nodes one Ready node; get crd lists the CRDs of the two
  # kinds of experiment; get of an experiment -o json prints object.json, -o name prints it while $FAKE_DIR/linger
  # counts down (one per call); get secrets prints secrets.json (none without it); get deployment and get service print
  # an image and an address; apply of a file adds "<clock> apply <file>" to events; anything else succeeds silently.
  # run.sh logs each call, and adds "<clock> k6-<command>" to events; its logs writes $FAKE_DIR/summary.json as the
  # one pod's summary.
  cat >"$work/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
[ ! -f "$FAKE_DIR/api-down" ] || exit 1
case " $* " in
  *" get job "*) [ -f "$FAKE_DIR/job.json" ] && cat "$FAKE_DIR/job.json" || exit 1 ;;
  *" get endpointslices "*)
    echo "$(cat "$FAKE_DIR/clock" 2>/dev/null || echo 0) endpoints" >>"$FAKE_DIR/events"
    n=$(cat "$FAKE_DIR/endpoints-wait" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then
      echo "$((n - 1))" >"$FAKE_DIR/endpoints-wait"
      echo '{"items": [{"endpoints": [{"addresses": ["10.42.0.9"], "conditions": {"ready": false}}]}]}'
    elif [ -f "$FAKE_DIR/endpoints.json" ]; then
      cat "$FAKE_DIR/endpoints.json"
    else
      echo '{"items": [{"endpoints": [{"addresses": ["10.42.0.9"], "conditions": {"ready": true}}]}]}'
    fi
    ;;
  *" -n chaos-mesh logs "*) echo "log of $*" ;;
  *" -n chaos-mesh get pods "*) cat "$FAKE_DIR/cm-pods.json" 2>/dev/null || echo '{"items": []}' ;;
  *" get pods "*) cat "$FAKE_DIR/pods.json" ;;
  *" get podchaos "*" -o json "* | *" get networkchaos "*" -o json "*) cat "$FAKE_DIR/object.json" 2>/dev/null ;;
  *" get secrets "*) cat "$FAKE_DIR/secrets.json" 2>/dev/null || echo '{"items": []}' ;;
  *" get nodes "*) echo '{"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}]}' ;;
  *" get crd "*)
    echo customresourcedefinition.apiextensions.k8s.io/networkchaos.chaos-mesh.org
    echo customresourcedefinition.apiextensions.k8s.io/podchaos.chaos-mesh.org
    ;;
  *" get podchaos "* | *" get networkchaos "*)
    n=$(cat "$FAKE_DIR/linger" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then
      echo "$((n - 1))" >"$FAKE_DIR/linger"
      echo "chaos.chaos-mesh.org/lingering"
    fi
    ;;
  *" get deployment "*) echo registry.example/media-worker@sha256:0 ;;
  *" get service "*) echo 10.43.0.10 ;;
  *" apply -f - "*) ;;
  *" apply -f "*) echo "$(cat "$FAKE_DIR/clock" 2>/dev/null || echo 0) apply $(basename "${!#}")" >>"$FAKE_DIR/events" ;;
esac
EOS
  printf '#!/usr/bin/env bash\necho "helm $*" >>"$FAKE_LOG"\n' >"$work/bin/helm"
  # The kernel module of the delay (chaos_netem), never the machine's own sudo, apt-get or modprobe: lsmod lists
  # sch_netem while $FAKE_DIR/netem-loaded exists; modprobe -n finds it while netem-available or netem-loaded exists,
  # and modprobe loads it then; apt-get logs its call and, unless $FAKE_DIR/apt-fails exists, makes it available
  # (install), or does nothing (update); sudo runs its command (env takes the VAR=value before it).
  cat >"$work/bin/lsmod" <<'EOS'
#!/usr/bin/env bash
echo "Module                  Size  Used by"
[ ! -f "$FAKE_DIR/netem-loaded" ] || echo "sch_netem              24576  0"
EOS
  cat >"$work/bin/modprobe" <<'EOS'
#!/usr/bin/env bash
echo "modprobe $*" >>"$FAKE_LOG"
[ -f "$FAKE_DIR/netem-available" ] || [ -f "$FAKE_DIR/netem-loaded" ] || exit 1
[ "$1" = -n ] || touch "$FAKE_DIR/netem-loaded"
EOS
  cat >"$work/bin/apt-get" <<'EOS'
#!/usr/bin/env bash
echo "apt-get $*" >>"$FAKE_LOG"
[ ! -f "$FAKE_DIR/apt-fails" ] || exit 100
case " $* " in *" install "*) touch "$FAKE_DIR/netem-available" ;; esac
EOS
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"$FAKE_LOG"\nexec env "$@"\n' >"$work/bin/sudo"
  chmod +x "$work/bin/lsmod" "$work/bin/modprobe" "$work/bin/apt-get" "$work/bin/sudo"
  touch "$work/netem-loaded"
  cat >"$work/repo/deploy/k6/cloud/run.sh" <<'EOS'
#!/usr/bin/env bash
echo "run.sh $*" >>"$FAKE_LOG"
echo "$(cat "$FAKE_DIR/clock" 2>/dev/null || echo 0) k6-${!#}" >>"$FAKE_DIR/events"
if [ "${!#}" = logs ]; then
  mkdir -p "$repo/.k6/cloud-test"
  cp "$FAKE_DIR/summary.json" "$repo/.k6/cloud-test/pod-0.json"
  echo "summaries in .k6/cloud-test"
fi
EOS
  chmod +x "$work/bin/kubectl" "$work/bin/helm" "$work/repo/deploy/k6/cloud/run.sh"
  # A pod's summary as deploy/k6/lib/summary.js prints it, the fields chaos_k6_finish reads.
  echo '{"thresholds_ok": true, "thresholds": [{"metric": "svp_rate_limited", "expression": "count==0", "ok": true}],
    "dropped_iterations": 0, "metrics": {"svp_rate_limited": {"values": {"count": 0}}},
    "routes": [{"route": "/feed/explore", "requests": 900, "failed_rate": 0, "p99_ms": 40}]}' >"$work/summary.json"
  PATH=$work/bin:$PATH
  kc() { kubectl --context k3d-svp "$@"; }
  export -f kc
  chaos_config

  # The k6 holding check: a Job of 1 pod running, its pod Running, the hold window from 100 s ago to 1000 s ahead.
  now=$(date +%s)
  mkdir -p "$chaos_state"
  # hold FROM TO [ACCESS]: the hold window and the end of the pool's access, in seconds from now.
  hold() { jq -nc --argjson f $((now + $1)) --argjson t $((now + $2)) --argjson a $((now + ${3:-5000})) \
    '{started: 0, hold_from: $f, hold_to: $t, access_to: $a}' >"$chaos_state/k6.json"; }
  hold -100 1000
  running_job='{"spec": {"parallelism": 1}, "status": {"conditions": []}}'
  printf '%s' "$running_job" >"$work/job.json"
  printf '{"items": [{"metadata": {}, "status": {"phase": "Running"}}]}' >"$work/pods.json"
  holds() { if chaos_k6_holding "$1"; then echo yes; else echo "no: $chaos_why"; fi; }
  same "holding: Job running, its pod Running, the window inside the hold" yes "$(holds 600)"
  case $(holds 1100) in "no: the hold ends in"*) ok "holding: a window that would end past the hold" ;;
    *) fail "holding: a window past the hold end: got '$(holds 1100)'" ;; esac
  printf '{"spec": {"parallelism": 1}, "status": {"conditions": [{"type": "Complete", "status": "True"}]}}' >"$work/job.json"
  same "holding: the Job ended" "no: Job svp-load/svp-k6 ended (Complete)" "$(holds 0)"
  rm "$work/job.json"
  same "holding: no Job" "no: no Job svp-load/svp-k6" "$(holds 0)"
  printf '%s' "$running_job" >"$work/job.json"
  printf '{"items": [{"metadata": {}, "status": {"phase": "Pending"}}]}' >"$work/pods.json"
  same "holding: the pod not Running" "no: 0 pod(s) of the Job Running, 1 expected" "$(holds 0)"
  printf '{"items": [{"metadata": {"deletionTimestamp": "x"}, "status": {"phase": "Running"}}]}' >"$work/pods.json"
  same "holding: the pod being deleted" "no: 0 pod(s) of the Job Running, 1 expected" "$(holds 0)"
  printf '{"items": [{"metadata": {}, "status": {"phase": "Running"}}]}' >"$work/pods.json"
  hold 50 1000
  case $(holds 0) in "no: the hold starts in"*) ok "holding: before the hold starts" ;;
    *) fail "holding: before the hold: got '$(holds 0)'" ;; esac
  hold -100 1000 500
  same "holding: a window inside the pool's access" yes "$(holds 400)"
  case $(holds 600) in "no: the run's 55 min end in"*) ok "holding: a window that would end past the pool's access" ;;
    *) fail "holding: a window past the access: got '$(holds 600)'" ;; esac
  rm "$chaos_state/k6.json"
  same "holding: no hold window" "no: no hold window (the step's k6 run did not start its hold)" "$(holds 0)"

  # fake_clock: date +%s and sleep on $FAKE_DIR/clock, for the cases' subshells; date -u -d @T prints T.
  fake_clock() {
    date() { case $1 in +%s) cat "$FAKE_DIR/clock" ;; -u) echo "${3#@}" ;; *) command date "$@" ;; esac; }
    sleep() { echo $(($(cat "$FAKE_DIR/clock") + ${1%.*})) >"$FAKE_DIR/clock"; }
    echo 1000000 >"$FAKE_DIR/clock"
  }

  # A k6 run on the fake clock that does not reach its hold: setup() still running after 15 min, the Job ended in
  # setup(), or a planned end past the pool's access. Each fails before the hold window, and the step's exit deletes
  # the run at once, its summaries unread: one delete for a Job left behind, one on exit. A run that reached its hold
  # is finished by the exit instead: its summaries read (logs), then deleted.
  local begin_out
  begin_case() {
    (
      # Only the case's line on stdout (fd 3): the step's own output and its exit's go nowhere.
      exec 3>&1 >/dev/null 2>&1
      # The step's EXIT trap removes $work, which here would be the test's own folder.
      work=
      fake_clock
      k6mini_setup_ends() { [ -z "${begin_setup:-}" ] || echo "$(cat "$FAKE_DIR/clock") 32"; }
      k6mini_job_ended() { echo "${begin_ended:-}"; }
      k6mini_oom() { echo null; }
      k6mini_runner() { echo '{"enough": true}'; }
      rm -rf "$chaos_state"
      mkdir -p "$chaos_state"
      : >"$FAKE_LOG"
      chaos_access_s=${begin_access:-$chaos_access_s}
      chaos_guard chaos-c c
      chaos_k6_begin c "$chaos_hold_c" "c.steady"
      echo "rc=$? elapsed=$(($(cat "$FAKE_DIR/clock") - 1000000)) $chaos_why" >&3
    )
    echo "deletes=$(grep -cE '^run\.sh .* delete$' "$FAKE_LOG") logs=$(grep -cE '^run\.sh .* logs$' "$FAKE_LOG")"
  }
  begin_out=$(begin_case | tr '\n' ' ')
  same "begin: setup() still running after 15 min: fail, the run deleted on exit" \
    "rc=1 elapsed=900 setup() ended in 0 of 1 pod(s) within 15 min deletes=2 logs=0 " "$begin_out"
  begin_out=$(begin_ended=Failed begin_case | tr '\n' ' ')
  same "begin: the Job ended in setup(): fail, the run deleted on exit" \
    "rc=1 elapsed=0 setup() ended in 0 of 1 pod(s) within 15 min; the Job ended (Failed) deletes=2 logs=0 " "$begin_out"
  begin_out=$(begin_setup=1 begin_access=2000 begin_case | tr '\n' ' ')
  same "begin: a run that would end past the pool's access: fail before its hold, the run deleted on exit" \
    "rc=1 elapsed=0 the run would end 2340 s after its Job's start, past the 2000 s the pool's access allows deletes=2 logs=0 " \
    "$begin_out"
  begin_out=$(begin_setup=1 begin_case | tr '\n' ' ')
  same "begin: c's run (36 min hold) within the pool's access: holds at the start of its hold; finished on exit" \
    "rc=0 elapsed=130  deletes=2 logs=1 " "$begin_out"

  # Each experiment on the fake clock, its k6 run real (chaos_k6_begin, chaos_k6_finish over the fake run.sh) and the
  # cluster's answers stubbed: one k6 run of its own started in its step and ended by its end (run.sh delete of a Job
  # left behind, start, logs, delete), its summary read into its k6_end and its hold window into k6-windows.tsv, its
  # steady state (the trial: its window, where its baseline is read) opened after that run's start, closed with k6
  # holding and before the first fault is applied, and its baseline named in its results. c stops at its injection
  # (the rest of it needs the API and rpk): its run is then ended by the step's exit, its summary read all the same.
  # With exp_stop, a, b and c stop early at their first fault (a: the gateway kill; b, c: while it is injected) and the
  # cluster is back to steady state: each step fails with that reason, and its exit still ends its run the same way.
  experiment_case() {
    (
      # The step's output and its exit's go nowhere: only the case's line below on stdout.
      exec >/dev/null
      work=$FAKE_DIR/step-work
      mkdir -p "$work"
      fake_clock
      rm -rf "$chaos_state"
      mkdir -p "$chaos_state"
      : >"$FAKE_LOG"
      : >"$FAKE_DIR/events"
      rm -f "$SVP_VERIFY_OUT/k6-windows.tsv"
      printf '%s' "$running_job" >"$FAKE_DIR/job.json"
      printf '{"items": [{"metadata": {}, "status": {"phase": "Running"}}]}' >"$FAKE_DIR/pods.json"
      k6mini_setup_ends() { echo "$(cat "$FAKE_DIR/clock") 32"; }
      k6mini_job_ended() { :; }
      k6mini_oom() { echo null; }
      k6mini_runner() { echo '{"enough": true}'; }
      chaos_api() { :; }
      prometheus_forward() { :; }
      chaos_q() { echo 0; }
      chaos_watch() { :; }
      chaos_ready() { printf 'pod-a\npod-b\n'; }
      new_user() { :; }
      make_video() { :; }
      chaos_upgrade() { :; }
      chaos_rtt() {
        if grep -q 'apply -f .*b-trial' "$FAKE_LOG" && ! grep -q 'delete networkchaos network-delay-trial' "$FAKE_LOG"; then
          echo 4500
        else
          echo 100
        fi
      }
      chaos_kill() {
        kc apply -f "$1" >/dev/null
        chaos_killed_at=$(date +%s) chaos_replicas=2 chaos_ready_s=10
        kc delete -f "$1" --ignore-not-found
        [ -z "${exp_stop:-}" ] || { chaos_why="the feed's 5xx above 5% for more than a minute (0.2)"; return 2; }
      }
      chaos_explore_stats() { echo "200 20 20"; }
      chaos_injected() {
        if [ -n "${exp_stop:-}" ] && [ "${4:-}" = watch ]; then
          chaos_why="1 node(s) NotReady"
          return 2
        fi
        [ "$2" != podchaos ]
      }
      chaos_delete_watched() { kc -n "$1" delete "$2" "$3" --ignore-not-found --wait=false; }
      chaos_sample_lag() { printf 'feed-service 0\nengagement-service 3\n' >>"$work/lag.steady"; }
      chaos_dlq() { : >"$1"; }
      kc() {
        case "$*" in
          *"get deployment chaos-controller-manager"*)
            echo '{"spec": {"template": {"spec": {"containers": [{"env": [{"name": "TARGET_NAMESPACE", "value": "svp-data"}]}]}}}}'
            ;;
          *) kubectl --context k3d-svp "$@" ;;
        esac
      }
      "$2"
      echo "$?" >"$FAKE_DIR/rc"
    )
    jq -r --arg key "$1" --arg steady "$3" --rawfile ev "$FAKE_DIR/events" \
      --rawfile tsv <(cat "$SVP_VERIFY_OUT/k6-windows.tsv" 2>/dev/null) '
      ($ev | split("\n") | map(select(length > 0) | split(" "))) as $e
      | ([$e[] | select(.[1] == "k6-start") | .[0] | tonumber]) as $starts
      | ([$e[] | select(.[1] == "apply") | .[0] | tonumber] | first) as $apply
      | ([$e[] | select(.[1] == "k6-delete") | .[0] | tonumber] | last) as $deleted
      | ([$e | to_entries[] | select(.value[1] == "apply") | .key]) as $applies
      | ([$e | to_entries[] | select(.value[1] == "endpoints") | .key]) as $checks
      | ([.windows[] | select(.step == "chaos-\(if $key == "trial" then "b-trial" else $key end)" and .window == $steady)]
         | first) as $w
      | "runs=\($starts | length)",
        "steady=\(if $w == null then "none"
          elif ($w.from | fromdate) >= $starts[0] and ($w.to | fromdate) <= $apply and $w.k6_holding_at_open
            and $w.k6_holding_at_close then "after-its-run-start-before-apply" else "wrong \($w)" end)",
        "deleted=\(if $deleted != null and $apply != null and $deleted >= $apply then "after-apply" else "no" end)",
        "webhook=\(if ($applies | length) > 0 and ([range(0; $applies | length) as $i
            | ($applies[$i]) as $a | (if $i == 0 then -1 else $applies[$i - 1] end) as $p
            | any($checks[]; . > $p and . < $a)] | all) then "checked-before-each-apply" else "unchecked" end)",
        "baseline=\(if (.[$key].k6.baseline // "") != "" and (.[$key].k6.run // "") == "chaos-\($key), its own: started in this step, ended (k6_end) before the next experiment" then "recorded" else "missing" end)",
        "hold=\(.[$key].k6.hold_m)m",
        "k6=\([$e[] | select(.[1] | startswith("k6-")) | .[1][3:]] | join(","))",
        "k6_end=\(.[$key].k6_end | if . == null then "none" else "\(.result),\(.pods_with_summary)-summary" end)",
        "tsv=\($tsv | split("\n") | map(select(length > 0) | split("\t")[0]) | join(","))"' \
      "$(cat "$chaos_state/json-path")" | tr '\n' ' ' | sed 's/ $//'
  }
  # early_out KEY: the exit status and the result of the step experiment_case just ran, and its diagnostics: written
  # (the file beside the results, named in them, its reason the step's) or none.
  early_out() {
    local res d diag
    res=$(cat "$chaos_state/json-path")
    d=$(jq -r --arg key "$1" '.[$key].diagnostics // empty' "$res")
    diag=${d:-none}
    [ -n "$d" ] && [ -f "$(dirname "$res")/$d" ] &&
      [ "$(jq -r .why "$(dirname "$res")/$d")" = "$(jq -r --arg key "$1" '.[$key].reason' "$res")" ] && diag=written
    jq -r --arg key "$1" --arg rc "$(cat "$work/rc")" --arg d "$diag" \
      '"rc=\($rc) \(.[$key].result): \(.[$key].reason) diagnostics=\($d)"' "$res"
  }
  local run_ok='runs=1 steady=after-its-run-start-before-apply deleted=after-apply webhook=checked-before-each-apply baseline=recorded'
  local run_end='k6=delete,start,logs,delete k6_end=pass,1-summary'
  same "trial: its own k6 run, its window (the baseline before the delay) before the delay" \
    "$run_ok hold=8m $run_end tsv=chaos-trial" "$(experiment_case trial chaos_trial trial)"
  same "trial: passed, so no diagnostics" "pass none" \
    "$(jq -r '"\(.trial.result) \(.trial.diagnostics // "none")"' "$(cat "$chaos_state/json-path")")"
  same "a: its own k6 run, its 5 min steady state before the gateway kill" \
    "$run_ok hold=25m $run_end tsv=chaos-a" "$(experiment_case a chaos_a steady)"
  same "b: its own k6 run, its 5 min steady state before the delay" \
    "$run_ok hold=19m $run_end tsv=chaos-b" "$(experiment_case b chaos_b steady)"
  same "c: its own k6 run, its 5 min steady state before Redpanda's failure; ended by the step's exit" \
    "$run_ok hold=36m $run_end tsv=chaos-c" "$(experiment_case c chaos_c steady)"
  same "a, stopped early at the gateway kill: its run still ended, its summary read, its window recorded" \
    "$run_ok hold=25m $run_end tsv=chaos-a" "$(exp_stop=1 experiment_case a chaos_a steady)"
  same "a, stopped early: the step fails with the early stop" \
    "rc=1 fail: stopped early after the gateway kill (the feed's 5xx above 5% for more than a minute (0.2)); back to steady state diagnostics=written" \
    "$(early_out a)"
  same "a, stopped early: its diagnostics written before its k6 run's end is awaited" diagnostics-first \
    "$(awk '/ -n chaos-mesh get pods -o json/ && !d { d = NR } /^run\.sh .* logs$/ && !l { l = NR }
      END { print (d && l && d < l) ? "diagnostics-first" : "d=" d " l=" l }' "$work/calls")"
  same "b, stopped early while the delay is injected: its run still ended, its summary read, its window recorded" \
    "$run_ok hold=19m $run_end tsv=chaos-b" "$(exp_stop=1 experiment_case b chaos_b steady)"
  same "b, stopped early: the step fails with the early stop" \
    "rc=1 fail: stopped early while the delay was injected (1 node(s) NotReady); back to steady state diagnostics=written" \
    "$(early_out b)"
  same "c, stopped early while Redpanda's failure is injected: its run still ended, its summary read, its window recorded" \
    "$run_ok hold=36m $run_end tsv=chaos-c" "$(exp_stop=1 experiment_case c chaos_c steady)"
  same "c, stopped early: the step fails with the early stop" \
    "rc=1 fail: stopped early while Redpanda's failure was injected (1 node(s) NotReady); back to steady state diagnostics=written" \
    "$(early_out c)"

  # The controller's webhook without a Ready endpoint: a checks it every 5 s for 120 s, then fails with that reason
  # before any apply; its run still ended and read, its diagnostics written. Back after 3 checks: a waits 15 s for it,
  # then applies. c checks it after its helm upgrade, before its k6 run.
  echo '{"items": [{"endpoints": [{"addresses": ["10.42.0.9"], "conditions": {"ready": false}}]}]}' >"$work/endpoints.json"
  local wh_out
  wh_out=$(experiment_case a chaos_a steady)
  case $wh_out in *" webhook=unchecked "*" $run_end "*) ok "webhook: no Ready endpoint: no apply; the run still ended and read" ;;
    *) fail "webhook: no Ready endpoint: got '$wh_out'" ;; esac
  # 25 checks in the wait (0, 5, ..., 120 s), the 26th the diagnostics' own read of the endpoints.
  same "webhook: no Ready endpoint: 25 checks over 120 s, no apply" "checks=26 applies=0" \
    "checks=$(grep -c ' endpoints$' "$work/events") applies=$(grep -c ' apply ' "$work/events")"
  same "webhook: no Ready endpoint: the step fails with that reason" \
    "rc=1 fail: the controller's webhook (Service chaos-mesh-controller-manager) had no Ready endpoint within 120 s (kill-gateway; pods: none) diagnostics=written" \
    "$(early_out a)"
  rm -f "$work/endpoints.json"
  echo 3 >"$work/endpoints-wait"
  same "webhook: back after 3 checks: a waits for it, then applies" "$run_ok hold=25m $run_end tsv=chaos-a" \
    "$(experiment_case a chaos_a steady)"
  same "webhook: the wait recorded" '{"ready_endpoints":1,"waited_s":15,"ready":true}' \
    "$(jq -c '.a.controller["kill-gateway"] | {ready_endpoints, waited_s, ready}' "$(cat "$chaos_state/json-path")")"
  rm -f "$work/endpoints-wait"
  experiment_case c chaos_c steady >/dev/null
  same "webhook: c checks it after its helm upgrade, before its k6 run" "upgrade-before-k6 true" \
    "$(awk '$2 == "endpoints" && !e { e = NR } $2 == "k6-start" && !k { k = NR }
      END { print (e && k && e < k) ? "upgrade-before-k6" : "e=" e " k=" k }' "$work/events") $(jq -r '.c.controller.upgrade.ready' "$(cat "$chaos_state/json-path")")"
  rm -rf "$work/step-work"
  printf '%s' "$running_job" >"$work/job.json"
  printf '{"items": [{"metadata": {}, "status": {"phase": "Running"}}]}' >"$work/pods.json"
  now=$(date +%s)
  hold -100 1000

  # A step stopped by TERM while a window runs, its experiments gone after two reads: experiments deleted, read until
  # gone, then Chaos Mesh, then the k6 Job, at once: its run past its start of hold is deleted, not awaited and read.
  local pid rc order
  : >"$FAKE_LOG"
  echo 2 >"$work/linger"
  bash -c 'chaos_config; chaos_guard chaos-a a; chaos_k6_live=finish; echo started >"$FAKE_DIR/started"; while :; do sleep 1; done' &
  pid=$!
  for _ in $(seq 1 50); do [ -f "$work/started" ] && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid"
  rc=$?
  same "stopped: the step exits 143" 143 "$rc"
  order=$(awk '
    / delete podchaos pod-kill-gateway / && !e { e = NR }
    / get (podchaos|networkchaos) / { g = NR }
    /^helm .* uninstall chaos-mesh / && !h { h = NR }
    / delete namespace chaos-mesh / && !n { n = NR }
    / delete customresourcedefinition/ && !c { c = NR }
    /^run\.sh .* delete$/ && !k { k = NR }
    END { print (e && g && h && n && c && k && e < g && g < h && h < n && n < c && c < k) ? "in order" : "e=" e " g=" g " h=" h " n=" n " c=" c " k=" k }' "$FAKE_LOG")
  same "stopped: experiments deleted, read until gone, helm uninstall, namespace, CRDs, then run.sh delete" "in order" "$order"
  same "stopped: every experiment deleted" 5 "$(grep -cE ' delete (podchaos|networkchaos) ' "$FAKE_LOG")"
  same "stopped: the k6 run deleted once, its summaries not awaited" "delete=1 logs=0" \
    "delete=$(grep -cE '^run\.sh .* delete$' "$FAKE_LOG") logs=$(grep -cE '^run\.sh .* logs$' "$FAKE_LOG")"
  case $(cat "$chaos_state/stop" 2>/dev/null) in "chaos-a was stopped"*"Chaos Mesh and the k6 Job deleted"*) ok "stopped: the stop mark written" ;;
    *) fail "stopped: the stop mark: got '$(cat "$chaos_state/stop" 2>/dev/null)'" ;; esac
  same "stopped: the step's result is fail" fail "$(jq -r .a.result "$(cat "$chaos_state/json-path")")"

  # The same with an experiment that does not go (its fault not taken back): Chaos Mesh stays, the k6 Job goes.
  : >"$FAKE_LOG"
  rm -f "$work/started"
  echo 1000 >"$work/linger"
  bash -c 'chaos_config; chaos_trap_wait_s=2; chaos_guard chaos-c c; echo started >"$FAKE_DIR/started"; while :; do sleep 1; done' &
  pid=$!
  for _ in $(seq 1 50); do [ -f "$work/started" ] && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid"
  rc=$?
  same "stopped, an experiment left: the step exits 143" 143 "$rc"
  same "stopped, an experiment left: no helm uninstall, namespace or CRD deleted" 0 \
    "$(grep -cE '^helm .* uninstall |delete namespace chaos-mesh|delete customresourcedefinition' "$FAKE_LOG")"
  same "stopped, an experiment left: the k6 Job deleted" 1 "$(grep -cE '^run\.sh .* delete$' "$FAKE_LOG")"
  case $(cat "$chaos_state/stop" 2>/dev/null) in *"not gone within 2 s, so Chaos Mesh was left"*) ok "stopped, an experiment left: the stop mark says so" ;;
    *) fail "stopped, an experiment left: the stop mark: got '$(cat "$chaos_state/stop" 2>/dev/null)'" ;; esac
  rm -f "$work/linger"

  # The kill of a pod whose replacement never comes, on a fake clock (date +%s and sleep): the early stop is checked
  # every 15 s while the replacement is awaited, and stops it.
  local kill_out
  : >"$FAKE_LOG"
  : >"$work/watch"
  echo 1000000 >"$work/clock"
  kill_case() {
    (
      work=
      date() { case $1 in +%s) cat "$FAKE_DIR/clock" ;; -u) echo "${3#@}" ;; *) command date "$@" ;; esac; }
      sleep() { echo $(($(cat "$FAKE_DIR/clock") + ${1%.*})) >"$FAKE_DIR/clock"; }
      chaos_ready() { grep -q ' apply ' "$FAKE_LOG" || echo pod-a; }
      chaos_alive() { chaos_ready "$@"; }
      # Stops on its check number chaos_watch_stop_at (0: never).
      chaos_watch() {
        echo watch >>"$FAKE_DIR/watch"
        [ "$chaos_watch_stop_at" -gt 0 ] && [ "$(grep -c . "$FAKE_DIR/watch")" -ge "$chaos_watch_stop_at" ] || return 0
        chaos_why="1 node(s) NotReady"
        return 1
      }
      chaos_kill "$chaos_files/a-pod-kill-gateway.yaml" gateway >/dev/null
      echo "rc=$? ready=${chaos_ready_s:-none} elapsed=$(($(cat "$FAKE_DIR/clock") - 1000000))"
    )
  }
  # The watch stops on its second check, 15 s after the kill.
  local chaos_watch_stop_at=2
  kill_out=$(kill_case)
  case $kill_out in "rc=2 ready=none elapsed="*) ok "kill: an early stop while the replacement is awaited returns 2" ;;
    *) fail "kill: early stop while awaiting the replacement: got '$kill_out'" ;; esac
  [ "${kill_out##*elapsed=}" -le 20 ] && ok "kill: the stop came within 15 s of the kill, not after 180 s" ||
    fail "kill: the stop came after ${kill_out##*elapsed=} s"
  same "kill: the experiment deleted after the early stop" 1 "$(grep -c ' delete -f .*a-pod-kill-gateway.yaml' "$FAKE_LOG")"
  same "kill: its status read for the diagnostics before its deletion" read-before-delete \
    "$(awk '/ get podchaos pod-kill-gateway .*-o json/ && !g { g = NR } / delete -f .*a-pod-kill-gateway.yaml/ && !d { d = NR }
      END { print (g && d && g < d) ? "read-before-delete" : "g=" g " d=" d }' "$FAKE_LOG")"
  # The watch never stops: 180 s awaited, checked every 15 s.
  : >"$FAKE_LOG"
  : >"$work/watch"
  echo 1000000 >"$work/clock"
  chaos_watch_stop_at=0
  kill_out=$(kill_case)
  case $kill_out in "rc=0 ready=none elapsed="*) ok "kill: no replacement within 180 s returns 0 with no ready time" ;;
    *) fail "kill: no replacement: got '$kill_out'" ;; esac
  [ "$(grep -c . "$work/watch")" -ge 12 ] && ok "kill: the early stop checked every 15 s while the replacement is awaited" ||
    fail "kill: the early stop checked $(grep -c . "$work/watch") time(s) in 180 s"

  # The lag: each group on its own; rpk failing, listing no group or describing a group without its lag is unread
  # (false, nothing printed), never 0.
  lag() { (
    chaos_rpk() {
      case "$1 $2" in
        "group list") [ "$lag_list" = fail ] && return 1; printf 'BROKER  GROUP  STATE\n'
          [ "$lag_list" = empty ] || printf '0  feed-service  Stable\n0  engagement-service  Stable\n' ;;
        "group describe")
          [ "$lag_describe" = fail ] && return 1
          printf 'GROUP        feed-service\nSTATE        Stable\nTOTAL-LAG    6\n\nTOPIC  PARTITION  LAG\nvideo.lifecycle.v1  0  6\n\n'
          [ "$lag_describe" = short ] || printf 'GROUP        engagement-service\nTOTAL-LAG    0\n' ;;
      esac
    }
    if chaos_lag; then echo read; else echo unread; fi
  ); }
  same "lag: rpk group list fails" unread "$(lag_list=fail lag)"
  same "lag: rpk lists no group" unread "$(lag_list=empty lag)"
  same "lag: rpk describe fails" unread "$(lag_list=ok lag_describe=fail lag)"
  same "lag: a listed group described without its lag" unread "$(lag_list=ok lag_describe=short lag)"
  same "lag: each group apart" "feed-service 6 engagement-service 0 read" "$(lag_list=ok lag_describe=ok lag | tr '\n' ' ' | sed 's/ $//')"

  # The lag's targets and its return, never summed: engagement-service (a batch group) at 6 at most in the steady state
  # keeps 6 as its target; feed-service must reach 0, so feed-service at 6 beside engagement-service at 0 is not back.
  local lag_st
  printf 'feed-service 0\nengagement-service 6\nfeed-service 0\nengagement-service 2\n' >"$work/lag.steady"
  lag_st=$(chaos_lag_targets "$work/lag.steady")
  same "lag: targets 0, and the steady highest for the batch group" '{"engagement-service":6,"feed-service":0}' \
    "$(jq -c '.groups | map_values(.target)' <<<"$lag_st")"
  chaos_lag_steady_holds "$lag_st" && ok "lag: the steady state holds with feed-service at 0" ||
    fail "lag: the steady state with feed-service at 0"
  lag_st=$(chaos_lag_read "$lag_st" "" 10)
  lag_st=$(chaos_lag_read "$lag_st" $'feed-service 6\nengagement-service 0' 30)
  chaos_lag_back "$lag_st" && fail "lag: feed-service at 6 read as back (a sum would be 6 <= 6)" ||
    ok "lag: feed-service at 6 beside engagement-service at 0 is not back"
  lag_st=$(chaos_lag_read "$lag_st" $'feed-service 0\nengagement-service 5' 60)
  chaos_lag_back "$lag_st" && ok "lag: back once feed-service reads 0, engagement-service within its 6" ||
    fail "lag: back once feed-service reads 0"
  same "lag: each group's time back, the reads and the unread one" \
    '{"back":{"engagement-service":30,"feed-service":60},"reads":2,"unread":1}' \
    "$(jq -c '{back: (.groups | map_values(.back_s_after_return)), reads: .reads_after_return, unread: .unread_after_return}' <<<"$lag_st")"
  printf 'feed-service 2\nengagement-service 6\n' >"$work/lag.steady"
  chaos_lag_steady_holds "$(chaos_lag_targets "$work/lag.steady")" &&
    fail "lag: feed-service at 2 in the steady state read as steady" || ok "lag: no steady state with feed-service at 2"
  : >"$work/lag.steady"
  chaos_lag_steady_holds "$(chaos_lag_targets "$work/lag.steady")" &&
    fail "lag: no read in the steady state read as steady" || ok "lag: no steady state without a read"

  # The early stop: a check Prometheus does not answer logs a line and counts, and the 5xx streak goes on; a ratio under
  # 5% ends it; above 5% for more than a minute stops.
  watch_case() { (
    chaos_q() { echo "$watch_r"; }
    chaos_high_since=$(($(date +%s) - ${watch_since:-0})) chaos_watch_unread=0
    out=$(chaos_watch)
    rc=$?
    chaos_watch >/dev/null
    echo "rc=$rc streak=$([ -n "$chaos_high_since" ] && echo on || echo off) unread=$chaos_watch_unread logged=$(grep -c 'early stop check unread' <<<"$out")"
  ); }
  same "watch: Prometheus unread: logged, counted, the streak goes on" "rc=0 streak=on unread=1 logged=1" \
    "$(watch_r=null watch_since=30 watch_case)"
  same "watch: under 5% ends the streak" "rc=0 streak=off unread=0 logged=0" "$(watch_r=0.01 watch_since=30 watch_case)"
  same "watch: above 5% for more than a minute stops" "rc=1 streak=on unread=0 logged=0" \
    "$(watch_r=0.2 watch_since=61 watch_case)"

  # The uploads while Redpanda is down run in the background with the early stop checked meanwhile; one that stops
  # returns at once, the uploads go on to their end and their results are read.
  uploads_case() { (
    work=$FAKE_DIR/up
    rm -rf "$work"
    mkdir -p "$work"
    chaos_watch_every=1 chaos_watched_at=
    : >"$FAKE_DIR/watch"
    create() { command sleep 0.5; printf -v "${1}_id" '%s' "id-$1"; }
    upload() { command sleep 0.5; }
    # The helpers fail (exit) on a refused request, as complete does here for c2.
    complete() { [ "$1" != c2 ] || exit 1; }
    chaos_watch() {
      echo watch >>"$FAKE_DIR/watch"
      [ "${uploads_stop_at:-0}" -gt 0 ] && [ "$(grep -c . "$FAKE_DIR/watch")" -ge "$uploads_stop_at" ] || return 0
      chaos_why="1 node(s) NotReady"
      return 1
    }
    chaos_uploads_start
    chaos_uploads_watch
    rc=$?
    kill -0 "$chaos_up_pid" 2>/dev/null && running=yes || running=no
    wait "$chaos_up_pid"
    chaos_uploads_result
    echo "rc=$rc running_at_return=$running watches=$(grep -c . "$FAKE_DIR/watch") ids=$(echo $chaos_up_ids) $(jq -c 'map(.created_and_completed)' <<<"$chaos_up_json")"
  ); }
  local up_out
  up_out=$(uploads_stop_at=0 uploads_case)
  case $up_out in "rc=0 running_at_return=no watches="*" ids=id-c1 id-c3 [true,false,true]") ok "uploads: run to their end, results read" ;;
    *) fail "uploads: got '$up_out'" ;; esac
  [ "$(sed 's/.*watches=\([0-9]*\).*/\1/' <<<"$up_out")" -ge 2 ] && ok "uploads: the early stop checked while they run" ||
    fail "uploads: the early stop not checked while they run: '$up_out'"
  up_out=$(uploads_stop_at=1 uploads_case)
  case $up_out in "rc=1 running_at_return=yes watches="*" ids=id-c1 id-c3 [true,false,true]") ok "uploads: an early stop returns at once, the uploads end and are read" ;;
    *) fail "uploads: early stop: got '$up_out'" ;; esac

  # The trial: its window opens and closes with the k6 checks; k6 not holding at either end fails it. Its k6 run's start
  # and end are stubbed: the hold window is set here.
  trial_case() {
    (
      # Only the case's line on stdout (fd 3): the step's own output and its exit's go nowhere.
      exec 3>&1 >/dev/null 2>&1
      work=
      rm -rf "$chaos_state"
      mkdir -p "$chaos_state"
      : >"$FAKE_LOG"
      hold -100 1000
      chaos_k6_begin() { :; }
      chaos_k6_finish() { :; }
      chaos_injected() { :; }
      # 20 connections: 100 ms before and after, 4 500 ms during the delay; the Job ends while "during" runs when
      # trial_job_ends says so.
      chaos_rtt() {
        if grep -q 'apply -f .*b-trial' "$FAKE_LOG" && ! grep -q 'delete networkchaos network-delay-trial' "$FAKE_LOG"; then
          [ -z "$trial_job_ends" ] ||
            printf '{"spec": {"parallelism": 1}, "status": {"conditions": [{"type": "Failed", "status": "True"}]}}' >"$FAKE_DIR/job.json"
          echo 4500
        else
          echo 100
        fi
      }
      chaos_trial
      echo "rc=$? $(jq -c '{result: .trial.result, reason: .trial.reason, windows: [.windows[] | [.window, .k6_holding_at_open, .k6_holding_at_close]]}' "$(cat "$chaos_state/json-path")")" >&3
    )
  }
  local trial_out
  printf '%s' "$running_job" >"$work/job.json"
  trial_out=$(trial_job_ends= trial_case)
  same "trial: k6 holds at both ends" 'rc=0 {"result":"pass","reason":null,"windows":[["trial",true,true]]}' "$trial_out"
  printf '{"spec": {"parallelism": 1}, "status": {"conditions": [{"type": "Failed", "status": "True"}]}}' >"$work/job.json"
  trial_out=$(trial_job_ends= trial_case)
  same "trial: the Job ended before the window: fail, the delay never applied" \
    'rc=1 {"result":"fail","reason":"k6 not holding its load: Job svp-load/svp-k6 ended (Failed)","windows":[["trial",false,null]]}' \
    "$trial_out"
  grep -q 'apply -f .*b-trial' "$FAKE_LOG" && fail "trial: the delay applied without k6 holding" ||
    ok "trial: no delay applied without k6 holding"
  printf '%s' "$running_job" >"$work/job.json"
  trial_out=$(trial_job_ends=1 trial_case)
  same "trial: the Job ended during the window: fail" \
    'rc=1 {"result":"fail","reason":"k6 not holding its load at the end of the trial: Job svp-load/svp-k6 ended (Failed)","windows":[["trial",true,false]]}' \
    "$trial_out"
  printf '%s' "$running_job" >"$work/job.json"

  # The diagnostics: Chaos Mesh's pods with how their last run ended, the experiment's status as read before its
  # deletion, the logs of the controller and of chaos-daemon on the target's node only, each with the run before after a
  # restart; every chaos-daemon's when the target has no pod.
  cat >"$work/cm-pods.json" <<'EOJ'
{"items": [
  {"metadata": {"name": "chaos-controller-manager-1", "labels": {"app.kubernetes.io/component": "controller-manager"}},
   "spec": {"nodeName": "node-1", "containers": [{"name": "chaos-mesh"}]},
   "status": {"phase": "Running", "podIP": "10.42.0.9", "containerStatuses": [{"name": "chaos-mesh", "ready": true,
     "restartCount": 2, "state": {"running": {}}, "lastState": {"terminated": {"reason": "Error", "exitCode": 1}}}]}},
  {"metadata": {"name": "chaos-daemon-a", "labels": {"app.kubernetes.io/component": "chaos-daemon"}},
   "spec": {"nodeName": "node-1", "containers": [{"name": "chaos-daemon"}]},
   "status": {"phase": "Running", "containerStatuses": [{"name": "chaos-daemon", "ready": true, "restartCount": 0,
     "state": {"running": {}}, "lastState": {}}]}},
  {"metadata": {"name": "chaos-daemon-b", "labels": {"app.kubernetes.io/component": "chaos-daemon"}},
   "spec": {"nodeName": "node-2", "containers": [{"name": "chaos-daemon"}]},
   "status": {"phase": "Running", "containerStatuses": [{"name": "chaos-daemon", "ready": true, "restartCount": 1,
     "state": {"running": {}}, "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}}}]}}]}
EOJ
  echo '{"status": {"conditions": [{"type": "AllInjected", "status": "False"}], "experiment": {"desiredPhase": "Run",
    "containerRecords": [{"id": "svp/engagement-service-1", "phase": "Not Injected",
      "events": [{"type": "Failed", "operation": "Apply", "message": "rpc error: tc failed"}]}]}}}' >"$work/object.json"
  printf '{"items": [{"metadata": {}, "spec": {"nodeName": "node-2"}, "status": {"phase": "Running"}}]}' >"$work/pods.json"
  diag_case() { (
    exec 3>&1 >/dev/null 2>&1
    work=
    rm -rf "$chaos_state"
    mkdir -p "$chaos_state"
    : >"$FAKE_LOG"
    chaos_step=chaos-b chaos_key=b chaos_target=$1 chaos_diag_done=
    chaos_diag_object svp networkchaos network-delay-engagement
    chaos_diag b "the delay was not injected within 60 s"
    res=$(cat "$chaos_state/json-path")
    d=$(dirname "$res")/$(jq -r .b.diagnostics "$res")
    {
      echo "file=$(basename "$d" | sed 's/^chaos-[0-9TZ]*-//')"
      jq -r '"why=\(.why)", "nodes=\(.target_nodes | join(","))",
        "last=\([.chaos_mesh_pods[] | .containers[0] | "\(.restarts):\(.last_terminated.reason // "-")"] | join(","))",
        "status=\(.experiments[0].status.experiment.containerRecords[0].events[0].message)",
        "logs=\(.logs | map("\(.pod)/\(.run)") | join(","))"' "$d"
      echo "requested=$(grep -c ' -n chaos-mesh logs ' "$FAKE_LOG") previous=$(grep -c ' -n chaos-mesh logs .* --previous' "$FAKE_LOG")"
    } | tr '\n' ' ' | sed 's/ $//' >&3
  ); }
  local cm='chaos-controller-manager-1/current,chaos-controller-manager-1/previous'
  same "diagnostics: the controller's and the target node's chaos-daemon, each run before after a restart" \
    "file=diagnostics-b.json why=the delay was not injected within 60 s nodes=node-2 last=2:Error,0:-,1:OOMKilled status=rpc error: tc failed logs=$cm,chaos-daemon-b/current,chaos-daemon-b/previous requested=4 previous=2" \
    "$(diag_case 'svp engagement-service')"
  same "diagnostics: no target, every chaos-daemon" \
    "file=diagnostics-b.json why=the delay was not injected within 60 s nodes= last=2:Error,0:-,1:OOMKilled status=rpc error: tc failed logs=$cm,chaos-daemon-a/current,chaos-daemon-b/current,chaos-daemon-b/previous requested=5 previous=2" \
    "$(diag_case '')"

  # The artifact keeps the diagnostics beside the results (.k8s/drills/*.json of deploy/ci/verify-collect.sh), and
  # drops that file alone when it holds a secret value: the filter of this checkout over a tree of its own
  # (SVP_VERIFY_REPO), with a fake .env and a fake Secret of chaos-mesh, both made here.
  local real crepo res diagf csecret
  real=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
  res=$(cat "$chaos_state/json-path")
  diagf=$(dirname "$res")/$(jq -r .b.diagnostics "$res")
  crepo=$work/collect
  mkdir -p "$crepo/.k8s/drills" "$work/collect-out"
  echo chaos >"$work/collect-out/scenario"
  csecret=$(openssl rand -hex 12)
  printf 'SVP_FAKE_PASSWORD=%s\n' "$(openssl rand -hex 12)" >"$crepo/.env"
  jq -n --arg v "$(printf '%s' "$csecret" | base64)" '{items: [{type: "Opaque", data: {"tls.key": $v}}]}' >"$work/secrets.json"
  cp "$res" "$diagf" "$crepo/.k8s/drills/"
  # collect: the verdict of files.txt on each file of .k8s/drills, its time stamp left out.
  collect() {
    rm -rf "$work/art"
    SVP_VERIFY_REPO=$crepo SVP_VERIFY_OUT=$work/collect-out SVP_VERIFY_ARTIFACT=$work/art SVP_VERIFY_SECRETS=$work/sec \
      "$real/deploy/ci/verify-collect.sh" >/dev/null 2>&1
    awk -F '\t' '$2 ~ /^\.k8s\/drills\// { f = $2; sub(/.*\//, "", f); sub(/^chaos-[0-9TZ]*/, "chaos", f)
      print $1, f ($1 == "dropped" ? " " $3 : "") }' "$work/art/files.txt" 2>/dev/null | sort | tr '\n' ';'
  }
  same "artifact: the diagnostics kept beside the results" "kept chaos-diagnostics-b.json;kept chaos.json;" "$(collect)"
  jq --arg s "$csecret" '.logs[0].lines += ["a line that quotes \($s)"]' "$diagf" >"$crepo/.k8s/drills/$(basename "$diagf")"
  same "artifact: diagnostics that hold a secret value dropped, the results kept" \
    "dropped chaos-diagnostics-b.json secret-value;kept chaos.json;" "$(collect)"
  rm -f "$work/secrets.json" "$work/object.json" "$work/cm-pods.json"
  printf '{"items": [{"metadata": {}, "status": {"phase": "Running"}}]}' >"$work/pods.json"

  # An experiment deleted with the early stop watched (b, c) has its status read first, for the step's diagnostics.
  local dw_out
  dw_out=$( (
    exec 3>&1 >/dev/null 2>&1
    work=
    rm -rf "$chaos_state"
    mkdir -p "$chaos_state"
    : >"$FAKE_LOG"
    echo '{"status": {"conditions": [{"type": "AllInjected", "status": "False"}]}}' >"$FAKE_DIR/object.json"
    chaos_key=c
    chaos_watch_due() { :; }
    chaos_delete_watched svp-data podchaos redpanda-failure 10
    echo "rc=$? $(jq -c '.status.conditions[0].status' "$chaos_state/object-c-redpanda-failure.json") $(awk '
      / get podchaos redpanda-failure .*-o json/ && !g { g = NR } / delete podchaos redpanda-failure / && !d { d = NR }
      END { print (g && d && g < d) ? "read-before-delete" : "g=" g " d=" d }' "$FAKE_LOG")" >&3
  ) )
  rm -f "$work/object.json"
  same "delete: the experiment's status read before its deletion" 'rc=0 "False" read-before-delete' "$dw_out"

  # The uninstall writes its diagnostics whatever comes after, before any experiment is deleted.
  local un_out
  un_out=$( (
    exec 3>&1 >/dev/null 2>&1
    work=
    rm -rf "$chaos_state"
    mkdir -p "$chaos_state"
    : >"$FAKE_LOG"
    chaos_uninstall
    res=$(cat "$chaos_state/json-path")
    echo "$(jq -r '.uninstall.diagnostics // "none"' "$res" | sed 's/^chaos-[0-9TZ]*-//') $(awk '
      / -n chaos-mesh get pods -o json/ && !d { d = NR } / delete (podchaos|networkchaos) / && !e { e = NR }
      END { print (d && e && d < e) ? "before-the-deletions" : "d=" d " e=" e }' "$FAKE_LOG")" >&3
  ) )
  same "uninstall: its diagnostics first" "diagnostics-uninstall.json before-the-deletions" "$un_out"

  # The kernel module of the delay: loaded already, loaded with modprobe, linux-modules-extra installed first, or not to
  # be had (the install fails): then the trial fails with that reason before its probe pod and k6 run.
  local kernel
  kernel=$(uname -r)
  netem_case() { (
    exec 3>&1 >/dev/null 2>&1
    work=
    rm -rf "$chaos_state"
    mkdir -p "$chaos_state"
    : >"$FAKE_LOG"
    chaos_key=trial
    chaos_netem
    echo "rc=$? $(jq -c '.trial.kernel.sch_netem' "$(cat "$chaos_state/json-path")") apt=$(grep -c '^apt-get ' "$FAKE_LOG") load=$(grep -c '^modprobe sch_netem' "$FAKE_LOG")" >&3
  ); }
  same "netem: loaded already" 'rc=0 {"before":"loaded","package":null,"after":"loaded"} apt=0 load=0' "$(netem_case)"
  rm -f "$work/netem-loaded"
  touch "$work/netem-available"
  same "netem: loaded with modprobe" 'rc=0 {"before":"available","package":null,"after":"loaded"} apt=0 load=1' "$(netem_case)"
  rm -f "$work/netem-loaded" "$work/netem-available"
  same "netem: absent, linux-modules-extra installed, then loaded" \
    "rc=0 {\"before\":\"absent\",\"package\":{\"name\":\"linux-modules-extra-$kernel\",\"result\":\"installed\"},\"after\":\"loaded\"} apt=1 load=1" \
    "$(netem_case)"
  rm -f "$work/netem-loaded" "$work/netem-available"
  touch "$work/apt-fails"
  same "netem: absent and its package not installed (install, update)" \
    "rc=1 {\"before\":\"absent\",\"package\":{\"name\":\"linux-modules-extra-$kernel\",\"result\":\"failed\"},\"after\":\"absent\"} apt=2 load=1" \
    "$(netem_case)"
  local tn_out
  tn_out=$( (
    exec 3>&1 >/dev/null 2>&1
    work=
    rm -rf "$chaos_state"
    mkdir -p "$chaos_state"
    : >"$FAKE_LOG"
    chaos_trial
    echo "rc=$? $(jq -r '"\(.trial.result): \(.trial.reason)"' "$(cat "$chaos_state/json-path")") probe=$(grep -c ' apply -f - ' "$FAKE_LOG") k6=$(grep -c '^run\.sh ' "$FAKE_LOG")" >&3
  ) )
  same "netem: not to be had: the trial fails with it, no probe pod, no k6 run" \
    "rc=1 fail: sch_netem absent on kernel $kernel (before: absent, linux-modules-extra-$kernel failed): no network delay possible probe=0 k6=0" \
    "$tn_out"
  # The scenario: the trial runs whatever verify-host.sh found (it loads the module itself); chaos-b is skipped with the
  # trial's own reason when the trial did not pass.
  local st_out
  st_out=$( (
    exec 3>&1 >/dev/null 2>&1
    echo absent >"$SVP_VERIFY_OUT/sch-netem"
    rm -f "$chaos_state/stop"
    step() {
      echo "step $1" >&3
      last_status=ok
      [ "$1" = chaos-b-trial ] || return 0
      last_status=fail
      chaos_put trial '{"result": "fail", "reason": "sch_netem absent on kernel k: no network delay possible"}'
    }
    skip() {
      echo "skip $1: $2" >&3
      last_status=skipped
    }
    scenario_targets
  ) | tr '\n' ';')
  same "scenario: the trial runs with sch_netem absent on the host; chaos-b skipped with the trial's reason" \
    "step k8s-up;step seed-videos;step chaos-mesh-install;step chaos-b-trial;step chaos-a;skip chaos-b: the trial of the network delay did not pass: sch_netem absent on kernel k: no network delay possible;step chaos-c;step chaos-mesh-uninstall;" \
    "$st_out"
  rm -f "$work/apt-fails" "$SVP_VERIFY_OUT/sch-netem"
  touch "$work/netem-loaded"

  # The install on the fake clock: the step passes only once the controller has run 150 s after its rollout (past its
  # caches' 2 min) with the same pod, no restart and no refusal in its log. A restart within them (inst_restart_at, in
  # seconds after the rollout), a refusal (inst_log, a line as the controller of 2.8.5 logs it), or a multi-cluster
  # controller on (inst_on, its ENABLED_CONTROLLERS) fails the step with its reason and its diagnostics.
  install_case() { (
    exec 3>&1 >/dev/null 2>&1
    work=
    fake_clock
    : >"$FAKE_LOG"
    chaos_upgrade() { echo "helm upgrade" >>"$FAKE_LOG"; }
    kc() {
      local r=0
      case "$*" in
        *"version -o json"*) echo '{"serverVersion": {"gitVersion": "v1.35.1+k3s1"}}' ;;
        *"get nodes -o name"*) echo node/k3d-svp-server-0 ;;
        *"get daemonset chaos-daemon"*) echo 1 ;;
        *"get deployment chaos-controller-manager"*)
          jq -nc --arg on "${inst_on:-podchaos-records,networkchaos-records,podnetworkchaos}" '{spec: {template: {spec:
            {containers: [{env: [{name: "CLUSTER_SCOPED", value: "false"}, {name: "TARGET_NAMESPACE", value: "svp"},
              {name: "ENABLED_CONTROLLERS", value: $on}]}]}}}}'
          ;;
        *"-n chaos-mesh get pods"*)
          [ -z "${inst_restart_at:-}" ] || [ "$(cat "$FAKE_DIR/clock")" -lt $((1000000 + inst_restart_at)) ] || r=1
          jq -nc --argjson r "$r" '{items: [{metadata: {name: "chaos-controller-manager-0",
            labels: {"app.kubernetes.io/component": "controller-manager"}}, spec: {nodeName: "k3d-svp-server-0",
            containers: [{name: "chaos-mesh"}]}, status: {containerStatuses: [{restartCount: $r}]}}]}'
          ;;
        *"-n chaos-mesh logs "*)
          echo "$(cat "$FAKE_DIR/clock") logs" >>"$FAKE_LOG"
          printf '%s\n' "INFO setup starting manager" ${inst_log:+"$inst_log"}
          ;;
        *) kubectl --context k3d-svp "$@" ;;
      esac
    }
    # In a bash of its own as verify-run.sh runs a step, so that its exit (the diagnostics) comes before the line.
    (chaos_install)
    echo "rc=$? elapsed=$(($(cat "$FAKE_DIR/clock") - 1000000)) $(jq -c '.install | {result, watched:
      .controller_stable.watched_s, refused: .controller_stable.refused, multi: .multicluster_controllers_on,
      diagnostics: (.diagnostics != null)}' "$(cat "$chaos_state/json-path")") $(jq -r '.install.reason // ""' \
      "$(cat "$chaos_state/json-path")") first-log-at=$(awk '/ logs$/ { print $1 - 1000000; exit }' "$FAKE_LOG")" >&3
  ); }
  same "install: passes once the controller ran 150 s after its rollout, its log read then" \
    'rc=0 elapsed=150 {"result":"pass","watched":150,"refused":[],"multi":[],"diagnostics":false}  first-log-at=150' \
    "$(install_case)"
  same "install: a restart 130 s after the rollout fails the step, with its diagnostics" \
    'rc=1 elapsed=130 {"result":"fail","watched":130,"refused":[],"multi":[],"diagnostics":true} the controller restarted, or its pod changed, within 130 s of its rollout (pods: chaos-controller-manager-0, 0 restart(s) at the start; chaos-controller-manager-0, 1 restart(s) then) first-log-at=130' \
    "$(inst_restart_at=130 install_case)"
  # shellcheck disable=SC2016 # the controller's log line, its quotes escaped as it writes them
  same "install: a refusal of the API server in the controller's log fails the step, each right refused named" \
    'rc=1 elapsed=150 {"result":"fail","watched":150,"refused":["cannot list resource remoteclusters in API group chaos-mesh.org at the cluster scope"],"multi":[],"diagnostics":true} the API server refused the controller 1 time(s) in 150 s: cannot list resource remoteclusters in API group chaos-mesh.org at the cluster scope first-log-at=150' \
    "$(inst_log='2026-10-28T10:42:24.9Z	ERROR	controller-runtime.cache.UnhandledError	runtime/runtime.go:221	Failed to watch	{"type": "*v1alpha1.RemoteCluster", "error": "failed to list *v1alpha1.RemoteCluster: remoteclusters.chaos-mesh.org is forbidden: User \"system:serviceaccount:chaos-mesh:chaos-controller-manager\" cannot list resource \"remoteclusters\" in API group \"chaos-mesh.org\" at the cluster scope"}' install_case)"
  # shellcheck disable=SC2016 # the client-go line of a rejected Event, its quotes escaped as it writes them
  same "install: a refused Event of the controller in its own namespace does not fail the step" \
    'rc=0 elapsed=150 {"result":"pass","watched":150,"refused":[],"multi":[],"diagnostics":false}  first-log-at=150' \
    "$(inst_log='E1028 12:38:45.022295       1 event.go:359] "Server rejected event (will not retry!)" err="events is forbidden: User \"system:serviceaccount:chaos-mesh:chaos-controller-manager\" cannot create resource \"events\" in API group \"\" in the namespace \"chaos-mesh\""' install_case)"
  same "install: a multi-cluster controller on fails the step before the watch" \
    'rc=1 elapsed=0 {"result":"fail","watched":null,"refused":null,"multi":["remotecluster","podchaos-remote-apply"],"diagnostics":true} not as installed by design: chaos-daemon ready on 1 of 1 node(s), 2 CRDs, controller CLUSTER_SCOPED/TARGET_NAMESPACE '"'false svp'"' (false svp expected), multi-cluster controllers on: ["remotecluster","podchaos-remote-apply"] (none expected) first-log-at=0' \
    "$(inst_on=podchaos-records,remotecluster,podchaos-remote-apply install_case)"
  same "install: all controllers on (\"*\") fails the step the same way" \
    'rc=1 ["*"]' "$(inst_on='*' install_case | sed -E 's/^(rc=[0-9]).*"multi":(\[[^]]*\]).*/\1 \2/')"
  # The scenario: no experiment when the install did not pass; the uninstall still runs.
  local si_out
  si_out=$( (
    exec 3>&1 >/dev/null 2>&1
    step() {
      echo "step $1" >&3
      last_status=ok
      [ "$1" != chaos-mesh-install ] || last_status=fail
    }
    skip() {
      echo "skip $1: $2" >&3
      last_status=skipped
    }
    scenario_targets
  ) | tr '\n' ';')
  same "scenario: the install failed: every experiment skipped, the uninstall run" \
    "step k8s-up;step seed-videos;step chaos-mesh-install;skip chaos-b-trial: Chaos Mesh not installed;skip chaos-a: Chaos Mesh not installed;skip chaos-b: Chaos Mesh not installed;skip chaos-c: Chaos Mesh not installed;step chaos-mesh-uninstall;" \
    "$si_out"

  # The uninstall's lists: one the API did not answer is listed as unread, never as nothing left.
  touch "$work/api-down"
  case $(chaos_left) in *"unread: experiments"*"unread: CRDs"*"unread: namespace chaos-mesh"*) ok "left: unanswered lists read as unread" ;;
    *) fail "left: unanswered lists: got '$(chaos_left | tr '\n' ' ')'" ;; esac
  rm -f "$work/api-down"

  local f
  for f in chaos_install chaos_trial chaos_a chaos_b chaos_c chaos_uninstall; do
    declare -f "$f" | grep -q 'chaos_guard ' || fail "$f does not install the traps (chaos_guard)"
  done
  ok "every step installs the traps"
  # Each experiment under a k6 run of its own, started and ended in its step.
  for f in chaos_trial chaos_a chaos_b chaos_c; do
    declare -f "$f" | grep -q 'chaos_k6_begin ' && declare -f "$f" | grep -q 'chaos_k6_finish ' ||
      fail "$f does not run its experiment under a k6 run of its own (chaos_k6_begin, chaos_k6_finish)"
  done
  ok "each experiment starts and ends a k6 run of its own"

  echo "chaos_test: $failures failure(s)"
  [ "$failures" = 0 ]
}

# Run as a script (not sourced by verify-run.sh): the self-test.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    test) chaos_test ;;
    *)
      echo "usage: bash deploy/ci/verify/chaos.sh test (the self-test; verify-run.sh sources this file)" >&2
      exit 2
      ;;
  esac
fi
