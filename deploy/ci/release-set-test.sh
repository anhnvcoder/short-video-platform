#!/usr/bin/env bash
# Tests for deploy/ci/release-set.sh snapshot and verify: the set of releases staging ran during the checks of a run
# of scenario gitops. A fake kubectl first on PATH answers from the files of a made-up cluster (Applications, the
# workloads and pods of namespace svp), and a throwaway repository stands for the clone of svp-gitops: commit R1 names
# release A of every service, R2 release B of the gateway. Checked:
#   - nothing moves between the two snapshots: release-set.json holds the seven releases of R1 with their tags, R1,
#     the charts of envs/stg/charts.yaml at R1 (a commit of the code repository other than R1, as it always is), the
#     latest deployedAt of R1, the run and the steps that ran in between (a skipped one left out);
#   - none written, exit not 0, with the reason: a rollout of the gateway from A to B (svp-gitops R1 → R2); a sync to
#     B and back to A (R1 at both ends, a new history entry); two digests on the gateway's pods, and a pod not Ready
#     running B beside a Ready one running A; a digest the configuration at R does not name; two Applications of the
#     charts at two revisions; charts at a revision envs/stg/charts.yaml at R does not name; a sync running; a
#     Deployment not Healthy; k8s-smoke not passed in the window;
#   - the pod of a drill's Deployment (other labels) is not a pod of a service;
#   - lists as large as a real cluster's (the Applications over 1 MiB with their resources and sync results, the pods
#     over 128 KiB, the most Linux takes in one argument): recorded all the same;
#   - snapshot writes its file and exits 1 when the cluster could not be recorded now;
#   - check takes the release-set.json written and refuses one whose release of web has a tag that is no commit;
#   - record-stg.sh on a machine prints the deployment of R in stg it would make, and refuses the file of another run.
# Runs on macOS and Linux: no network, no cluster.
#
# Usage, from anywhere: deploy/ci/release-set-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }

services=(gateway user-service video-service engagement-service feed-service media-worker web)
prefix=ghcr.io/anhnvcoder/short-video-platform
gitops_url=https://github.com/anhnvcoder/svp-gitops.git
code_url=https://github.com/anhnvcoder/short-video-platform.git
hex() { printf '%s' "$1" | shasum -a 256 | cut -c1-"$2"; }
digest() { echo "sha256:$(hex "$1" 64)"; }
tag=6ca2d8a795dd
charts=$(hex charts 40)

# --- Fake kubectl: -n NAMESPACE get RESOURCE -o json, answered from $FAKE_K8S/<resource>.json.
mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ] && [ "$1" != get ]; do shift; done
case $2 in
applications.argoproj.io)
  # FAKE_SEQ: a file with one cluster folder per line, read n lines in on the n-th call (the last line from then on).
  if [ -n "${FAKE_SEQ:-}" ]; then
    n=$(( $(cat "$FAKE_SEQ.n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$FAKE_SEQ.n"
    d=$(sed -n "${n}p" "$FAKE_SEQ")
    [ -n "$d" ] || d=$(tail -n 1 "$FAKE_SEQ")
    cat "$d/apps.json"
  else
    cat "$FAKE_K8S/apps.json"
  fi ;;
deployments.apps) cat "$FAKE_K8S/deployments.json" ;;
rollouts.argoproj.io) cat "$FAKE_K8S/rollouts.json" ;;
pods) cat "$FAKE_K8S/pods.json" ;;
*) echo "fake kubectl: no $2" >&2; exit 1 ;;
esac
EOF
chmod 755 "$work/bin/kubectl"

# --- The clone of svp-gitops: R1 with release A of every service, R2 with release B of the gateway.
config=$work/svp-gitops
mkdir -p "$config/envs/stg/images"
gw() { git -C "$config" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q "$config"
git -C "$config" remote add origin "$gitops_url"
image_file() {
  printf '# The release of %s.\nimage:\n  repository: %s/%s\n  tag: "%s"\n  digest: "%s"\n' "$1" "$prefix" "$1" "$tag" "$2"
}
for svc in "${services[@]}"; do image_file "$svc" "$(digest "A-$svc")" >"$config/envs/stg/images/$svc.yaml"; done
printf '# Charts.\nrevision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$charts" "$(hex collector 64)" \
  >"$config/envs/stg/charts.yaml"
gw add -A && gw commit -q -m R1
r1=$(git -C "$config" rev-parse HEAD)
image_file gateway "$(digest B-gateway)" >"$config/envs/stg/images/gateway.yaml"
gw commit -q -am R2
r2=$(git -C "$config" rev-parse HEAD)

# cluster DIR [VAR=VALUE...]: writes a made-up cluster into DIR. Every service runs release A on two Ready pods, its
# Application synced svp-gitops at R (default R1) and the charts at C (charts), history entry 1 of R. Settings, each
# VAR=VALUE: R, C (the charts of every Application), C_GATEWAY (those of the gateway's Application), HIST_GATEWAY
# (the id of its last history entry), OP_GATEWAY (the phase of its last sync), HEALTH_GATEWAY (its health), PODS_GATEWAY (the gateway's pods,
# "<release>:<ready>" separated by spaces, release A or B or another name), EXTRA_POD (a pod of a drill's
# Deployment), DEPLOY_UNHEALTHY (a service whose Deployment is not done), BIG (every Application lists 600 resources
# in its status and its last sync's result, every pod carries an annotation of 10 000 bytes).
cluster() {
  local dir=$1 R=$r1 C=$charts C_GATEWAY= HIST_GATEWAY=1 OP_GATEWAY=Succeeded HEALTH_GATEWAY=Healthy PODS_GATEWAY="A:true A:true" EXTRA_POD= \
    DEPLOY_UNHEALTHY= BIG= kv svc pods='[]' p rel ready apps='[]' c
  shift
  for kv in "$@"; do local "$kv"; done
  mkdir -p "$dir"
  apps=$(jq -n --arg r "$R" --arg url "$gitops_url" --arg code "$code_url" '[{metadata: {name: "svp-root"},
    spec: {source: {repoURL: $url, targetRevision: "refs/heads/main", path: "argocd/apps",
      helm: {valuesObject: {chartRepoURL: $code}}}},
    status: {sync: {status: "Synced", revision: $r}, health: {status: "Healthy"}, operationState: {phase: "Succeeded"},
      history: [{id: 1, revision: $r, deployedAt: "2026-10-30T01:00:00Z"}]}},
    {metadata: {name: "cert-manager"},
    spec: {source: {repoURL: "quay.io/jetstack/charts", chart: "cert-manager", targetRevision: "v1.19.1"}},
    status: {sync: {status: "Synced", revision: "v1.19.1"}, health: {status: "Healthy"},
      operationState: {phase: "Succeeded"}, history: [{id: 1, revision: "v1.19.1", deployedAt: "2026-10-30T00:50:00Z"}]}}]')
  for svc in "${services[@]}"; do
    c=$C
    [ "$svc" != gateway ] || c=${C_GATEWAY:-$C}
    apps=$(jq --arg s "$svc" --arg r "$R" --arg c "$c" --arg url "$gitops_url" --arg code "$code_url" \
      --argjson hist "$([ "$svc" = gateway ] && echo "$HIST_GATEWAY" || echo 1)" \
      --arg op "$([ "$svc" = gateway ] && echo "$OP_GATEWAY" || echo Succeeded)" \
      --arg health "$([ "$svc" = gateway ] && echo "$HEALTH_GATEWAY" || echo Healthy)" '. + [{metadata: {name: $s},
      spec: {sources: [{repoURL: $code, targetRevision: $c, path: "deploy/helm/svp-service"},
        {repoURL: $url, targetRevision: "refs/heads/main", ref: "values"}]},
      status: {sync: {status: "Synced", revisions: [$c, $r]}, health: {status: $health},
        operationState: {phase: $op},
        history: [range(1; $hist + 1) | {id: ., revisions: [$c, $r], deployedAt: "2026-10-30T01:0\(.):00Z"}]}}]' \
      <<<"$apps")
    for p in $([ "$svc" = gateway ] && echo "$PODS_GATEWAY" || echo "A:true A:true"); do
      rel=${p%%:*} ready=${p#*:}
      pods=$(jq --arg s "$svc" --arg img "$prefix/$svc:$tag@$(digest "$rel-$svc")" --argjson ready "$ready" \
        '. + [{metadata: {name: "\($s)-\(length)", labels: {"app.kubernetes.io/name": $s,
          "app.kubernetes.io/component": "server"}}, spec: {containers: [{name: $s, image: $img}]},
          status: {conditions: [{type: "Ready", status: (if $ready then "True" else "False" end)}]}}]' <<<"$pods")
    done
  done
  if [ -n "$EXTRA_POD" ]; then
    pods=$(jq --arg img "$prefix/web@$(digest drill)" '. + [{metadata: {name: "drill-supplychain-unsigned-0",
      labels: {"app.kubernetes.io/name": "drill-supplychain-unsigned"}}, spec: {containers: [{name: "app", image: $img}]},
      status: {conditions: [{type: "Ready", status: "True"}]}}]' <<<"$pods")
  fi
  if [ -n "$BIG" ]; then
    apps=$(jq '[range(0; 600) | {group: "apps", version: "v1", kind: "Deployment", namespace: "svp",
      name: "resource-\(.)", status: "Synced", health: {status: "Healthy"}}] as $res
      | map(.status.resources = $res | .status.operationState.syncResult.resources = $res)' <<<"$apps")
    pods=$(jq 'map(.metadata.annotations = {"kubectl.kubernetes.io/last-applied-configuration": ("x" * 10000)})' <<<"$pods")
  fi
  echo "{\"items\": $apps}" >"$dir/apps.json"
  echo "{\"items\": $pods}" >"$dir/pods.json"
  jq -n '{items: [{metadata: {name: "gateway"}, status: {phase: "Healthy"}}, {metadata: {name: "web"}, status: {phase: "Healthy"}}]}' \
    >"$dir/rollouts.json"
  printf '%s\n' "${services[@]}" | grep -v -e '^gateway$' -e '^web$' | jq -R . | jq -s --arg bad "$DEPLOY_UNHEALTHY" \
    '{items: map({metadata: {name: ., generation: 2}, spec: {replicas: 2}, status: ({observedGeneration: 2, replicas: 2,
      updatedReplicas: 2, availableReplicas: 2} + (if . == $bad then {updatedReplicas: 1, unavailableReplicas: 1} else {} end))})}' \
    >"$dir/deployments.json"
}

# machine SCRIPT ARGS...: SCRIPT of deploy/ci/ as a machine runs it (env -i: no variable of a CI job running this
# test), the fake kubectl first on PATH, the clone above. rs: release-set.sh.
machine() {
  local script=$1
  shift
  env -i PATH="$work/bin:$PATH" HOME="$work" TMPDIR="${TMPDIR:-/tmp}" FAKE_K8S="${FAKE_K8S:-}" FAKE_SEQ="${FAKE_SEQ:-}" \
    SVP_RELEASE_SET_SETTLE_SECONDS="${SVP_RELEASE_SET_SETTLE_SECONDS:-}" \
    SVP_RELEASE_SET_SETTLE_INTERVAL="${SVP_RELEASE_SET_SETTLE_INTERVAL:-}" SVP_GITOPS_DIR="$config" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$here/$script" "$@"
}
rs() { machine release-set.sh "$@"; }
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n01\tk8s-gitops-up\tok\t0\t1\t2\t1\t\n02\trelease-set-before\tok\t0\t2\t3\t1\t\n03\tk8s-smoke\tok\t0\t3\t4\t1\t\n04\tdrill-k8s-threats\tskipped\t\t4\t4\t0\tnot in targets\n05\tram-rest-end\tok\t0\t4\t5\t1\t\n' \
  >"$work/results.tsv"
# case NAME WANT_EXIT BEFORE_SETTINGS -- AFTER_SETTINGS: snapshots of two made-up clusters, then verify; WANT_EXIT 0
# wants release-set.json, any other no file.
case_() {
  local name=$1 want=$2 rc=0 b=() a=() side=b
  shift 2
  for kv in "$@"; do
    if [ "$kv" = -- ]; then side=a; elif [ "$side" = b ]; then b+=("$kv"); else a+=("$kv"); fi
  done
  rm -rf "$work/k8s" "$work/out" && mkdir -p "$work/out"
  cluster "$work/k8s/before" ${b[@]+"${b[@]}"}
  cluster "$work/k8s/after" ${a[@]+"${a[@]}"}
  FAKE_K8S=$work/k8s/before rs snapshot "$work/out/before.json" >/dev/null 2>&1 || :
  FAKE_K8S=$work/k8s/after rs snapshot "$work/out/after.json" >/dev/null 2>&1 || :
  rs verify "$work/out/before.json" "$work/out/after.json" "$work/out/release-set.json" "$work/results.tsv" \
    >"$work/out/verify.out" 2>"$work/out/verify.err" || rc=$?
  if [ "$want" = 0 ]; then
    same "$name: exit 0" 0 "$rc"
    [ -f "$work/out/release-set.json" ] && ok "$name: release-set.json written" || fail "$name: release-set.json written"
  else
    [ "$rc" != 0 ] && ok "$name: exit not 0" || fail "$name: exit not 0"
    [ ! -e "$work/out/release-set.json" ] && [ ! -e "$work/out/release-set.json.tmp" ] && ok "$name: nothing written" ||
      fail "$name: nothing written"
  fi
}

# --- Nothing moves.
case_ "nothing moves" 0 --
out=$work/out/release-set.json
same "nothing moves: ref R1" "$r1" "$(jq -r .ref "$out")"
same "nothing moves: environment" stg "$(jq -r .environment "$out")"
same "nothing moves: the seven services" "$(printf '%s\n' "${services[@]}" | sort | paste -sd ' ' -)" \
  "$(jq -r '.images | keys | join(" ")' "$out")"
same "nothing moves: the gateway's release A with its tag" "$prefix/gateway $tag $(digest A-gateway)" \
  "$(jq -r '.images.gateway | "\(.repository) \(.tag) \(.digest)"' "$out")"
same "nothing moves: the charts of envs/stg/charts.yaml at R1" "$charts v1.36 $(hex collector 64)" \
  "$(jq -r '.charts | "\(.revision) \(.podSecurityVersion) \(.collectorConfigSha256)"' "$out")"
same "nothing moves: deployed_at, the latest sync of R1" 2026-10-30T01:01:00Z "$(jq -r .deployed_at "$out")"
same "nothing moves: run_url" local "$(jq -r .run_url "$out")"
same "nothing moves: the steps that ran in the window" "k8s-smoke:ok ram-rest-end:ok" \
  "$(jq -r '[.steps[] | "\(.name):\(.status)"] | join(" ")' "$out")"
rs check "$out" >/dev/null 2>&1 && ok "check: release-set.json is a payload of a record" ||
  fail "check: release-set.json is a payload of a record"
jq '.images.web.tag = "main"' "$out" >"$work/bad.json"
if rs check "$work/bad.json" >/dev/null 2>"$work/bad.err"; then fail "check: a tag that is no commit is refused"; else
  has "$work/bad.err" "does not name one release on GHCR" && ok "check: a tag that is no commit is refused" ||
    fail "check: a tag that is no commit is refused, saying why"
fi

# record-stg.sh on a machine: the requests it would send, nothing sent; a file of another run refused.
machine record-stg.sh "$out" >"$work/record.out" 2>&1 && ok "record-stg.sh: a machine prints the record" ||
  fail "record-stg.sh: a machine prints the record"
has "$work/record.out" "-X POST repos/anhnvcoder/svp-gitops/deployments --input -" &&
  has "$work/record.out" "\"ref\":\"$r1\",\"environment\":\"stg\"" && ok "record-stg.sh: the deployment of R1 in stg" ||
  fail "record-stg.sh: the deployment of R1 in stg"
jq '.run_url = "https://github.com/anhnvcoder/short-video-platform/actions/runs/1"' "$out" >"$work/other-run.json"
if machine record-stg.sh "$work/other-run.json" >/dev/null 2>"$work/record.err"; then
  fail "record-stg.sh: the payload of another run is refused"
else
  has "$work/record.err" "not of this run local" && ok "record-stg.sh: the payload of another run is refused" ||
    fail "record-stg.sh: the payload of another run is refused, saying why"
fi

# --- Something moves, or does not match.
case_ "rollout of the gateway A to B" 1 -- R="$r2" HIST_GATEWAY=2 PODS_GATEWAY="B:true B:true"
check_err() { has "$work/out/verify.err" "$2" && ok "$1" || fail "$1: no '$2' in:"$'\n'"$(sed 's/^/      /' "$work/out/verify.err")"; }
check_err "rollout: names the gateway, both images and revisions" \
  "gateway: its image changed during the checks: $prefix/gateway@$(digest A-gateway) before smoke, $prefix/gateway@$(digest B-gateway) after (svp-gitops ${r1:0:12} before, ${r2:0:12} after)"
check_err "rollout: svp-gitops moved" "svp-gitops moved during the checks: revision $r1 before smoke, $r2 after"
case_ "A to B and back to A" 1 -- HIST_GATEWAY=3
check_err "A to B to A: the new history entries" \
  "Application gateway synced during the checks: last history entry 1 before smoke, 3 after"
case_ "two digests on the gateway's pods" 1 -- PODS_GATEWAY="A:true B:true"
check_err "two digests: names them" "after the checks: gateway: its pods run 2 images"
case_ "a pod not Ready runs B beside a Ready one on A" 1 PODS_GATEWAY="A:true B:false" -- PODS_GATEWAY="A:true B:false"
check_err "a pod not Ready: still two images" "before smoke: gateway: its pods run 2 images"
case_ "a digest the configuration at R does not name" 1 PODS_GATEWAY="X:true" -- PODS_GATEWAY="X:true"
check_err "digest not in the configuration: names both" \
  "gateway: its pods run $prefix/gateway@$(digest X-gateway), but envs/stg/images/gateway.yaml at ${r1:0:12} of svp-gitops names $prefix/gateway@$(digest A-gateway)"
other=$(hex other 40)
case_ "two Applications of the charts at two revisions" 1 C_GATEWAY="$other" -- C_GATEWAY="$other"
check_err "two chart revisions: says so" "name 2 revisions"
case_ "charts at a revision charts.yaml at R does not name" 1 C="$other" -- C="$other"
check_err "charts not of charts.yaml: names both" \
  "the charts run at ${other:0:12}, but envs/stg/charts.yaml at ${r1:0:12} of svp-gitops names revision $charts"
case_ "a sync running" 1 -- OP_GATEWAY=Running
check_err "a sync running: says so" "after the checks: Application gateway: a sync is running"
case_ "a Deployment not Healthy" 1 DEPLOY_UNHEALTHY=feed-service --
check_err "a Deployment not Healthy: names it" "before smoke: feed-service: Deployment replicas 2/2, updated 1, available 2, not Healthy"
case_ "the pod of a drill's Deployment" 0 EXTRA_POD=1 -- EXTRA_POD=1
same "the pod of a drill: not a release of web" "$prefix/web@$(digest A-web)" \
  "$(jq -r '.images.web | "\(.repository)@\(.digest)"' "$work/out/release-set.json")"

case_ "lists over the limit of one argument" 0 BIG=1 -- BIG=1
[ "$(wc -c <"$work/k8s/after/apps.json")" -gt 1048576 ] && [ "$(wc -c <"$work/k8s/after/pods.json")" -gt 131072 ] &&
  ok "large lists: the Applications over 1 MiB, the pods over 128 KiB" ||
  fail "large lists: the Applications over 1 MiB, the pods over 128 KiB"
same "large lists: the gateway's release A" "$prefix/gateway@$(digest A-gateway)" \
  "$(jq -r '.images.gateway | "\(.repository)@\(.digest)"' "$work/out/release-set.json" 2>/dev/null)"

sed -i.bak 's/\tk8s-smoke\tok\t0/\tk8s-smoke\tfail\t1/' "$work/results.tsv" && rm "$work/results.tsv.bak"
case_ "k8s-smoke did not pass" 1 --
check_err "k8s-smoke did not pass: says so" "k8s-smoke did not pass after release-set-before"

# --- snapshot alone.
rm -rf "$work/k8s" && cluster "$work/k8s/now" OP_GATEWAY=Running
rc=0
FAKE_K8S=$work/k8s/now rs snapshot "$work/now.json" >/dev/null 2>"$work/now.err" || rc=$?
same "snapshot of a cluster that cannot be recorded: exit 1" 1 "$rc"
[ -s "$work/now.json" ] && ok "snapshot: the file is written all the same" || fail "snapshot: the file is written all the same"
has "$work/now.err" "Application gateway: a sync is running" && ok "snapshot: says why" || fail "snapshot: says why"

# --- snapshot --settle: waits for every Application to be Synced and Healthy on two reads in a row. The fake kubectl
# answers the n-th read of the Applications from the n-th folder of FAKE_SEQ (the last one from then on).
# settle_case NAME WANT_EXIT SECONDS FOLDER...: one snapshot --settle over the sequence; leaves the reads it took in
# $settle_reads and its output in $work/settle.out, $work/settle.err.
settle_case() {
  local name=$1 want=$2 seconds=$3 rc=0
  shift 3
  rm -f "$work/seq" "$work/seq.n"
  printf '%s\n' "$@" >"$work/seq"
  FAKE_K8S=$work/k8s/healthy FAKE_SEQ=$work/seq SVP_RELEASE_SET_SETTLE_SECONDS=$seconds SVP_RELEASE_SET_SETTLE_INTERVAL=1 \
    rs snapshot --settle "$work/settle.json" >"$work/settle.out" 2>"$work/settle.err" || rc=$?
  settle_reads=$(cat "$work/seq.n")
  same "$name: exit $want" "$want" "$rc"
}
rm -rf "$work/k8s" && cluster "$work/k8s/healthy" && cluster "$work/k8s/degraded" HEALTH_GATEWAY=Degraded
h=$work/k8s/healthy
d=$work/k8s/degraded

settle_case "settle: Degraded, then Healthy before the deadline" 0 10 "$d" "$d" "$h" "$h"
has "$work/settle.out" "after waiting " && ok "settle: says how long it waited" ||
  fail "settle: says how long it waited: $(cat "$work/settle.out")"
# 4 reads to settle (D, D, H, H) and one more for the snapshot itself.
same "settle: two Healthy reads in a row, then the snapshot" 5 "$settle_reads"
[ -s "$work/settle.json" ] && ok "settle: the snapshot is written" || fail "settle: the snapshot is written"

settle_case "settle: Healthy, Degraded, Healthy does not settle on the first Healthy" 0 10 "$h" "$d" "$h" "$h"
same "settle: flip: four reads to settle and one for the snapshot, not the first Healthy" 5 "$settle_reads"

settle_case "settle: Degraded all along" 1 3 "$d"
has "$work/settle.err" "not every Application settled within 3 s" && has "$work/settle.err" "gateway: Synced, Degraded" &&
  ok "settle: runs out saying which Application and its state" || fail "settle: runs out saying which Application and its state"
[ -s "$work/settle.json" ] && ok "settle: the snapshot is written all the same" || fail "settle: the snapshot is written all the same"
has "$work/settle.err" "Application gateway: Synced, Degraded; Synced and Healthy wanted" &&
  ok "settle: the snapshot says why too" || fail "settle: the snapshot says why too"

# Without --settle nothing waits: one read of the Applications for the snapshot.
rm -f "$work/seq" "$work/seq.n" && printf '%s\n' "$d" >"$work/seq"
FAKE_K8S=$h FAKE_SEQ=$work/seq rs snapshot "$work/nowait.json" >/dev/null 2>&1 || :
same "snapshot without --settle: one read, no wait" 1 "$(cat "$work/seq.n")"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
