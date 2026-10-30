#!/usr/bin/env bash
# Velero restore drill of one namespace on the cloud cluster of stage 7.
# The learner runs it, with the cloud cluster's kubectl context; never on the laptop's k3d (refused before any kubectl
# call) and never from make. It needs kubectl, jq and curl on the machine, Velero installed and configured as the top of
# deploy/k8s/cloud/values/velero.yaml says, and no velero CLI: backups and restores are created as objects from the
# templates in deploy/k8s/cloud/velero/drill/.
#
# Runner mode: context k3d-svp is taken only on a runner the CI platform made for this one job, running Linux
# (ci_hosted_runner of deploy/ci/platform.sh, checked with uname before any kubectl call; a guard against accidents on
# the 16 GB laptop, not a security boundary), where scenario velero of deploy/ci/verify-run.sh has installed Velero
# with deploy/k8s/cloud/runner/velero/values.yaml and Redpanda on the CSI hostpath driver. Every other k3d-* context,
# and an empty one, is refused. There namespace svp-data also holds the object store the backups go to, Postgres and
# Valkey, so the drill keeps to Redpanda and its fixture; what changes from the steps below:
#   - check: the VolumeSnapshotClass is the hostpath driver's, Redpanda's PVCs are on a StorageClass of that driver,
#     and the Secrets are not checked (the drill deletes none);
#   - step 1: at least one consumer group has a committed offset above 0 (a seed ran before: comparing offsets of 0
#     proves nothing), and at least one fixture ConfigMap (label svp-drill=velero-fixture, random bytes the scenario
#     wrote so that the backup's tarball is over 5 MiB) is there; the SHA-256 of each is recorded;
#   - step 2: the backup takes Redpanda's objects (labels app.kubernetes.io/instance=redpanda and
#     app.kubernetes.io/name=redpanda, drill/backup-runner.yaml) and the fixtures, without Secrets; every fixture must
#     be in the resource list, or the drill stops before deleting anything. Then the backup's tarball in bucket velero
#     (HEAD as user svp-velero through Envoy, https://s3.svp.localhost:8443): over 5 MiB, multipart (ETag "<md5>-<parts>"),
#     and its CRC32 read back with x-amz-checksum-mode: ENABLED, or what the store answers instead written down;
#   - steps 3 and 4: no Argo CD on the dev path, so no auto-sync to turn off; T0 deletes Redpanda's StatefulSet, its
#     PVCs and the fixtures (never the namespace), and waits for the PVCs and their PersistentVolumes to be gone before
#     the Restore, which would otherwise skip a PVC still there;
#   - step 5: Redpanda's pods Ready instead of every pod of the namespace, and each fixture back with its SHA-256;
#   - step 6: T1 is the end of `make k8s-smoke` passing, run by the drill itself;
#   - sweep: what Velero is not there to delete is skipped, the fixtures are deleted by label, then every object left
#     in bucket velero (as svp-velero, who reaches no other bucket) until it is empty; no AWS command.
#
# Usage: deploy/k8s/cloud/velero/drill-restore.sh --context <ctx> [--namespace <ns>] [--confirm-delete <ns>] check|run|sweep
#   --context         the cloud cluster's context; k3d-svp only in runner mode (above)
#   --namespace       the namespace to back up, delete and restore (default svp-data, where Redpanda keeps its volumes;
#                     svp-data only in runner mode)
#   --confirm-delete  `run` deletes the namespace: it runs only when this repeats the namespace's name
#   check  read only: Velero ready, BackupStorageLocation default Available, a VolumeSnapshotClass for EBS with Velero's
#          label, the snapshot CRDs, the namespace and its Redpanda pod, and every Secret of the namespace made again
#          after a restore by External Secrets, cert-manager or Argo CD
#   run    the drill below
#   sweep  the end of the session, before helm uninstall: deletes the Schedule svp-daily, then every backup it made and
#          every drill backup with their EBS snapshots and bucket files (DeleteBackupRequest), the drill restores, and
#          prints the AWS command that lists EBS snapshots left from CSI, for the learner to run with their profile
#
# Steady-state hypothesis: a namespace deleted as a whole comes back from the last backup with its volumes; every consumer
# group's committed offsets are those of the backup (none lost, none moved back), lag returns to 0, the DLQ does not
# grow, Argo CD only creates again the Secrets its charts render (nothing else differs from git), and the system
# serves again.
#
# The drill (run):
#   1. The checks of `check` first. Uploads and load must already be stopped (k6 ended, no client). Waits for every
#      consumer group's lag to reach 0, then records each group's committed offset per partition and every topic's
#      high watermark, twice 60 s apart: they must not move (nothing is still writing).
#   2. Creates a Backup of the namespace without Secrets and waits for Completed. Every volume must have its CSI
#      snapshot and the resource list read from the bucket no Secret (threat model BAK-2); otherwise the drill stops
#      here, before anything is deleted.
#   3. Turns off Argo CD's auto-sync of svp-root and of every Application deploying into the namespace: self-heal would
#      rebuild the StatefulSet with empty volumes before Velero restores, and a restore skips what already exists.
#   4. T0: deletes the namespace, creates a Restore from the backup, waits for Completed, then turns auto-sync back on:
#      the PVCs (from their snapshots) and the StatefulSet exist now, so self-heal makes no empty volume, and the
#      Secrets a chart renders (Redpanda's lifecycle scripts and configurator) come back only through Argo CD, as
#      External Secrets and cert-manager make theirs again. Waits for every Application Synced.
#   5. Waits for every pod of the namespace Ready, the Redpanda cluster healthy and every group that had members at
#      step 1 with members again (the services reconnected; ready_seconds). Then, before anything new is written,
#      checks: committed offsets equal to step 1, lag 0, DLQ topics' high watermarks unchanged.
#   6. T1: the learner runs the smoke flow through the cloud API from their own terminal (deploy/compose/smoke.sh's
#      steps, one new upload READY exactly once) and types passed or failed: T1 is a "passed", RTO = T1 - T0 (the
#      checks of step 5, a few rpk calls, are inside it). Then prints the checks left to the learner (counters and feed
#      rows unchanged, the restored svp pods admitted by Kyverno).
#
# Watch: kubectl --context <ctx> -n velero get backups.velero.io,restores.velero.io -w; kubectl --context <ctx> -n <ns> get pods -w; the
# alerts KafkaConsumerLagHigh and KafkaDLQRecords.
# Pass: every check of step 5 PASS, the smoke passed at T1 and the learner's checks hold; rto_seconds is the RTO the
# drill measured (none when the smoke failed).
# Stop early: Ctrl-C. Before T0 auto-sync is turned back on by the script; between T0 and the Restore's Completed it is
# left off on purpose (an Application syncing into the half-restored namespace would make empty volumes) and the
# commands to turn it back on are printed; from the Restore on it is on again. A backup or restore stuck in progress:
# kubectl --context <ctx> -n velero delete backups.velero.io|restores.velero.io <name>.
#
# Results: a summary on stdout and JSON in .k8s/drills/velero-restore-<time>.json. Written for bash 3.2 (macOS).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)

die() {
  echo "FAIL  $1" >&2
  exit 1
}
usage() {
  sed -n 's/^# Usage: //p' "$0" >&2
  exit 2
}

ctx= ns=svp-data confirm= cmd=
while [ $# -gt 0 ]; do
  case $1 in
    --context) [ $# -ge 2 ] || usage; ctx=$2; shift 2 ;;
    --namespace) [ $# -ge 2 ] || usage; ns=$2; shift 2 ;;
    --confirm-delete) [ $# -ge 2 ] || usage; confirm=$2; shift 2 ;;
    check | run | sweep) cmd=$1; shift ;;
    *) usage ;;
  esac
done

# ci_hosted_runner: whether this is a runner the CI platform made for this one job (runner mode above).
# shellcheck source=deploy/ci/platform.sh
. "$repo/deploy/ci/platform.sh"

# The guard comes before any kubectl call, even a local one: an empty context would be kubectl's current one, and k3d's
# cluster is the local lab, which this drill never touches outside a CI runner's job.
[ -n "$ctx" ] || die "no --context: name the cloud cluster's kubectl context"
runner=
case $ctx in
  k3d-svp)
    [ "$(uname -s)" = Linux ] && ci_hosted_runner 2>/dev/null ||
      die "context k3d-svp only on a Linux runner the CI platform made for this job (scenario velero of verify.yml); this drill runs on the cloud cluster otherwise"
    runner=1
    ;;
  k3d-*) die "context $ctx is a local k3d cluster; this drill runs on the cloud cluster only" ;;
esac
[ -n "$cmd" ] || usage
[[ $ns =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "namespace '$ns' is not a valid name"
case $ns in
  kube-* | velero | argocd | default) die "namespace $ns is not one to drill on" ;;
esac
[ -z "$runner" ] || [ "$ns" = svp-data ] || die "runner mode drills on namespace svp-data only (got $ns)"
command -v jq >/dev/null || die "jq is not installed"
command -v curl >/dev/null || die "curl is not installed"
# Read whole before grep: grep -q stops at the first match, and kubectl still writing would die of SIGPIPE (pipefail).
contexts=$(kubectl config get-contexts -o name) || die "kubectl config get-contexts"
grep -qxF -- "$ctx" <<<"$contexts" || die "no context $ctx in the kubeconfig"

kc() { kubectl --context "$ctx" "$@"; }
now() { date -u +%s; }
stamp=$(date -u +%y%m%d%H%M%S)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
drill=$here/drill
rp_pod=redpanda-0
# The CSI driver whose VolumeSnapshotClass Velero must find, and the backup template.
driver=ebs.csi.aws.com backup_template=backup.yaml
if [ -n "$runner" ]; then
  driver=hostpath.csi.k8s.io backup_template=backup-runner.yaml
  # Redpanda's objects (its chart's labels) and the fixture ConfigMaps, the only things the runner drill deletes.
  rp_sel=app.kubernetes.io/instance=redpanda,app.kubernetes.io/name=redpanda
  fixture_sel=svp-drill=velero-fixture
  # The object store through Envoy, with the CA make k8s-up exported (curl reads CURL_CA_BUNDLE, the signed URL of
  # no_secret_in included).
  s3_origin=https://s3.svp.localhost:8443
  export CURL_CA_BUNDLE=$repo/.k8s/ca.crt
  [ -f "$CURL_CA_BUNDLE" ] || die "$CURL_CA_BUNDLE is missing (make k8s-ca)"
  command -v sha256sum >/dev/null || die "sha256sum is not installed"
  # The files under $work hold the login of svp-velero (curl configs).
  umask 077
fi

ok() { echo "ok    $1"; }
pass() {
  echo "PASS  $1"
  results+=("{\"check\":$(jq -Rn --arg s "$1" '$s'),\"ok\":true}")
}
failc() {
  echo "FAIL  $1" >&2
  results+=("{\"check\":$(jq -Rn --arg s "$1" '$s'),\"ok\":false}")
  failed=1
}
results=()
failed=0

# wait_for DESCRIPTION TIMEOUT_S COMMAND...: runs COMMAND every 5 s until it succeeds; dies after TIMEOUT_S.
wait_for() {
  local desc=$1 timeout=$2 start
  shift 2
  start=$(now)
  until "$@"; do
    [ $(($(now) - start)) -lt "$timeout" ] || die "timed out after ${timeout}s waiting for $desc"
    sleep 5
  done
}

# rpk ARGS...: rpk inside the broker container, with the login its environment already holds.
rpk() { kc -n "$ns" exec "$rp_pod" -c redpanda -- rpk "$@"; }

# snapshot FILE: "G group topic partition committed" per group partition and "T topic partition high-watermark" per
# topic partition; FILE.active lists the groups with a member right now.
snapshot() {
  local out=$1 g t members
  : >"$out"
  : >"$out.active"
  rpk group list >"$work/groups" || die "rpk group list"
  for g in $(awk 'NR > 1 { print $2 }' "$work/groups" | sort); do
    rpk group describe "$g" >"$work/describe" || die "rpk group describe $g"
    awk -v g="$g" '
      $1 == "TOPIC" { for (i = 1; i <= NF; i++) col[$i] = i; table = 1; next }
      table && NF >= 3 { print "G", g, $col["TOPIC"], $col["PARTITION"], $col["CURRENT-OFFSET"] }
    ' "$work/describe" >>"$out"
    # Only a group with a member is waited for after the restore: one already Empty (a past rpk consume, a service
    # scaled to 0) keeps its committed offsets but never gets members back.
    members=$(awk '$1 == "MEMBERS" { print $2 }' "$work/describe")
    if [ "${members:-0}" -gt 0 ]; then echo "$g" >>"$out.active"; fi
  done
  rpk topic list >"$work/topics" || die "rpk topic list"
  for t in $(awk 'NR > 1 { print $1 }' "$work/topics" | sort); do
    rpk topic describe -p "$t" >"$work/partitions" || die "rpk topic describe $t"
    # Not by header column: REPLICAS prints as "[0 1 2]", several fields once a topic has more than one replica. rpk
    # puts PARTITION first and HIGH-WATERMARK last whichever optional columns it adds.
    awk -v t="$t" '
      $1 == "PARTITION" { table = 1; next }
      table && NF >= 3 { print "T", t, $1, $NF }
    ' "$work/partitions" >>"$out"
  done
  sort -o "$out" "$out"
}

groups_of() { awk '$1 == "G" { print $2 }' "$1" | sort -u; }

all_lag_zero() {
  local g lag
  for g in $(awk 'NR > 1 { print $2 }' <(rpk group list 2>/dev/null)); do
    lag=$(rpk group describe "$g" 2>/dev/null | awk '$1 == "TOTAL-LAG" { print $2 }')
    [ "$lag" = 0 ] || return 1
  done
}

# from_template FILE NAME [BACKUP]: the template with its name, its backup's name (backupName, or target.name of a
# DownloadRequest) and the namespace replaced.
from_template() {
  sed -e "s/^  name: drill-svp-data$/  name: $2/" -e "s/^  backupName: drill-svp-data$/  backupName: ${3:-}/" \
    -e "s/^    name: drill-svp-data$/    name: ${3:-}/" -e "s/^    - svp-data$/    - $ns/" "$drill/$1"
}

# no_secret_in BACKUP: reads the backup's resource list from the bucket through a DownloadRequest and its signed URL;
# true when no Secret is in it.
no_secret_in() {
  local req=$1-list url
  from_template download-request.yaml "$req" "$1" | kc apply -f - >/dev/null || die "create DownloadRequest $req"
  has_url() { [ -n "$(kc -n velero get downloadrequests.velero.io "$req" -o jsonpath='{.status.downloadURL}' 2>/dev/null)" ]; }
  wait_for "the signed URL of DownloadRequest $req" 120 has_url
  url=$(kc -n velero get downloadrequests.velero.io "$req" -o jsonpath='{.status.downloadURL}')
  kc -n velero delete downloadrequests.velero.io "$req" --ignore-not-found >/dev/null
  curl -fsS "$url" | gunzip >"$work/resources.json" || die "download the resource list of backup $1"
  jq -r 'keys[]' "$work/resources.json" >"$work/resource-kinds"
  ! grep -Eq '(^|/)Secret$' "$work/resource-kinds"
}

# phase KIND NAME: status.phase of a Velero object ("" before the server sets it). KIND is always the full resource
# name (backups.velero.io): CloudNativePG also defines a Backup kind, and a bare "backup" resolves to its group.
phase() { kc -n velero get "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null || true; }

# wait_phase KIND NAME TIMEOUT_S: waits for Completed; dies on any final phase that is not.
wait_phase() {
  local start p
  start=$(now)
  while :; do
    p=$(phase "$1" "$2")
    case $p in
      Completed) return 0 ;;
      Failed | PartiallyFailed | FailedValidation)
        kc -n velero get "$1" "$2" -o jsonpath='{.status}' >&2 || true
        echo >&2
        die "$1 $2 ended $p"
        ;;
    esac
    [ $(($(now) - start)) -lt "$3" ] || die "timed out after ${3}s waiting for $1 $2 (phase '$p')"
    sleep 5
  done
}

cmd_check() {
  kc -n velero rollout status deployment/velero --timeout=60s >/dev/null || die "deployment velero/velero is not ready"
  ok "Velero server ready"
  local hint="bucket, region and KMS key filled in, Pod Identity?"
  [ -z "$runner" ] || hint="bucket velero, user svp-velero, Secret velero/velero-s3, NetworkPolicy svp-data/velero-s3?"
  [ "$(phase backupstoragelocations.velero.io default)" = Available ] ||
    die "BackupStorageLocation velero/default is not Available ($hint)"
  ok "BackupStorageLocation default Available"
  kc get crd volumesnapshots.snapshot.storage.k8s.io volumesnapshotcontents.snapshot.storage.k8s.io >/dev/null ||
    die "the snapshot CRDs are missing (EKS snapshot controller add-on; on a runner deploy/k8s/cloud/runner/csi/install.sh)"
  [ -n "$(kc get volumesnapshotclass -l velero.io/csi-volumesnapshot-class=true \
    -o jsonpath="{.items[?(@.driver==\"$driver\")].metadata.name}")" ] ||
    die "no VolumeSnapshotClass for $driver with label velero.io/csi-volumesnapshot-class=true"
  ok "VolumeSnapshotClass for $driver"
  kc get namespace "$ns" >/dev/null || die "namespace $ns not found"
  kc -n "$ns" get pod "$rp_pod" >/dev/null || die "pod $ns/$rp_pod not found"
  ok "namespace $ns with pod $rp_pod"
  if [ -n "$runner" ]; then
    # A volume on another class (local-path, k3s's default) has no snapshot: the backup would hold Redpanda's objects
    # and no data, and the restore would bring back an empty broker.
    local pvc class provisioner n=0
    while read -r pvc class; do
      [ -n "$pvc" ] || continue
      provisioner=$(kc get storageclass "$class" -o jsonpath='{.provisioner}') || die "read StorageClass $class"
      [ "$provisioner" = "$driver" ] ||
        die "PVC $ns/$pvc is on StorageClass $class ($provisioner), not one of $driver: make k8s-up with SVP_K8S_RUNNER_CSI=1 on a new cluster"
      n=$((n + 1))
    done < <(kc -n "$ns" get pvc -l "$rp_sel" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.storageClassName}{"\n"}{end}')
    [ "$n" -gt 0 ] || die "no PVC of Redpanda in $ns (labels $rp_sel)"
    ok "$n PVC(s) of Redpanda on a StorageClass of $driver"
    echo "skip  Secrets of $ns: the runner drill deletes none (only Redpanda's StatefulSet and PVCs and the fixtures)"
    return 0
  fi
  # The backup leaves Secrets out (BAK-2), so after the restore each must be made again from its source: the
  # ExternalSecret owning it or the cert-manager Certificate named on it, both restored with the namespace, or the
  # chart that renders it (Redpanda's redpanda-sts-lifecycle and redpanda-configurator), applied again by Argo CD once
  # auto-sync is back on. Argo CD v3 marks what it applies with the annotation argocd.argoproj.io/tracking-id (the
  # default tracking method, base/argo-cd.yaml of svp-gitops does not change it). Any other Secret (one written from
  # .env by a script) would be gone for good, and the pods reading it would never start.
  local orphans
  orphans=$(kc -n "$ns" get secrets -o json | jq -r '.items[]
    | select(any(.metadata.ownerReferences[]?; .kind == "ExternalSecret"
        and (.apiVersion | startswith("external-secrets.io/"))) | not)
    | select(.metadata.annotations["cert-manager.io/certificate-name"] == null)
    | select(.metadata.annotations["argocd.argoproj.io/tracking-id"] == null)
    | .metadata.name') || die "list the Secrets of $ns"
  [ -z "$orphans" ] || die "Secrets of $ns that none of External Secrets, cert-manager or Argo CD makes again after a \
restore: $(echo "$orphans" | tr '\n' ' ')(make them from Secrets Manager through External Secrets)"
  ok "every Secret of $ns made again by External Secrets, cert-manager or Argo CD"
}

# Argo CD: the Applications whose auto-sync is turned off for the drill, root first, with their automated policy.
argocd_present() { kc get crd applications.argoproj.io >/dev/null 2>&1; }
sync_off() {
  argocd_present || { echo "skip  Argo CD not installed: no auto-sync to turn off"; return 0; }
  kc -n argocd get applications -o json | jq -r --arg ns "$ns" '
    [.items[] | select(.spec.syncPolicy.automated != null)
      | select(.metadata.name == "svp-root" or .spec.destination.namespace == $ns)]
    | sort_by(if .metadata.name == "svp-root" then 0 else 1 end)[]
    | [.metadata.name, (.spec.syncPolicy.automated | tojson)] | @tsv' >"$work/apps"
  local app policy
  while IFS=$'\t' read -r app policy; do
    kc -n argocd patch application "$app" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null ||
      die "turn off auto-sync of Application $app"
    echo "ok    auto-sync off: Application $app"
  done <"$work/apps"
}
sync_on_commands() {
  local app policy
  while IFS=$'\t' read -r app policy; do
    printf "kubectl --context %s -n argocd patch application %s --type merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":%s}}}'\n" \
      "$ctx" "$app" "$policy"
  done <"$work/apps"
}
sync_on() {
  [ -s "$work/apps" ] || return 0
  local app policy
  # Children first, root last: the root rewrites the children's specs from git as soon as it syncs.
  while IFS=$'\t' read -r app policy; do
    kc -n argocd patch application "$app" --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":$policy}}}" \
      >/dev/null || { echo "FAIL  turn auto-sync of $app back on; run:" >&2; sync_on_commands >&2; return 1; }
    echo "ok    auto-sync on: Application $app"
  done < <(sed -n '1!G;h;$p' "$work/apps")
}
apps_synced() {
  [ -s "$work/apps" ] || return 0
  local app
  for app in $(cut -f1 "$work/apps"); do
    [ "$(kc -n argocd get application "$app" -o jsonpath='{.status.sync.status}')" = Synced ] || return 1
  done
}

ns_ready() {
  kc -n "$ns" get pods -o json 2>/dev/null | jq -e '
    [.items[] | select(.status.phase != "Succeeded")] as $p
    | ($p | length) > 0
      and all($p[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
}
# Outputs are read whole (no grep -q, no awk exit) so that kubectl never dies of SIGPIPE half way.
redpanda_healthy() {
  local health
  health=$(rpk cluster health 2>/dev/null) || return 1
  grep -Eq '^Healthy:[[:space:]]+true' <<<"$health"
}
groups_back() {
  local g members
  for g in $(sort -u "$work/before.active"); do
    members=$(rpk group describe "$g" 2>/dev/null | awk '$1 == "MEMBERS" { print $2 }')
    [ -n "$members" ] && [ "$members" -gt 0 ] || return 1
  done
}

# --- Runner mode only (see the top).

# rp_ready: Redpanda's pods are there and every one is Ready.
rp_ready() {
  kc -n "$ns" get pods -l "$rp_sel" -o json 2>/dev/null | jq -e '
    (.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
}
# rp_gone: no pod or PVC of Redpanda left (an error reading them is not gone).
rp_gone() {
  local left
  left=$(kc -n "$ns" get pods,pvc -l "$rp_sel" -o name) || return 1
  [ -z "$left" ]
}
# pvs_gone: none of the PersistentVolumes listed in $work/pvs is left.
pvs_gone() {
  local pv left
  for pv in $(cat "$work/pvs"); do
    left=$(kc get pv "$pv" --ignore-not-found -o name) || return 1
    [ -z "$left" ] || return 1
  done
}

# fixture_sums FILE: "name sha256" of every fixture ConfigMap of $ns, sorted; the digest is of its data and binaryData.
fixture_sums() {
  local f sum
  : >"$1"
  for f in $(kc -n "$ns" get configmaps -l "$fixture_sel" -o jsonpath='{.items[*].metadata.name}'); do
    sum=$(kc -n "$ns" get configmap "$f" -o json | jq -cS '{data, binaryData}' | sha256sum) || return 1
    echo "$f ${sum%% *}" >>"$1"
  done
  LC_ALL=C sort -o "$1" "$1"
}

# velero_login: the login of svp-velero, from the AWS credentials file in Secret velero/velero-s3, as a curl config in
# $work (mode 600, never on a command line).
velero_login() {
  kc -n velero get secret velero-s3 -o json | jq -r '
    .data.cloud | @base64d | split("\n") | map(capture("^(?<k>aws_access_key_id|aws_secret_access_key)=(?<v>.+)$")?
      | {(.k): .v}) | add // {}
    | if (.aws_access_key_id // "") == "" or (.aws_secret_access_key // "") == "" then error("no key in profile default")
      else "user = \((.aws_access_key_id + ":" + .aws_secret_access_key) | @json)" end' >"$work/velero.curl"
}

# s3 METHOD PATH OUT: a request to the object store through Envoy, signed (AWS Signature V4) as svp-velero; prints the
# status, the body in OUT.
s3() {
  curl -s --max-time 30 -o "$3" -w '%{http_code}' -K "$work/velero.curl" --aws-sigv4 aws:amz:us-east-1:s3 -X "$1" \
    "$s3_origin$2" || true
}

# bucket_object BACKUP: the backup's tarball in bucket velero, written by the AWS plugin's uploader: over 5 MiB, so
# uploaded in parts (5 MiB each), and the CRC32 the plugin sends with every multipart upload. Its JSON in
# $work/bucket.json.
bucket_object() {
  local key=backups/$1/$1.tar.gz status bytes etag parts crc ctype
  velero_login || die "read the login of svp-velero from Secret velero/velero-s3"
  # HEAD (-I), with the checksum mode that makes S3 return the object's checksum.
  status=$(curl -s --max-time 30 -I -o "$work/head" -w '%{http_code}' -K "$work/velero.curl" \
    --aws-sigv4 aws:amz:us-east-1:s3 -H 'x-amz-checksum-mode: ENABLED' "$s3_origin/velero/$key" || true)
  tr -d '\r' <"$work/head" >"$work/head.txt"
  hdr() {
    awk -v h="$1" '{ i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == h) { v = substr($0, i + 1);
      sub(/^[ \t]+/, "", v); print v } }' "$work/head.txt" | tail -n 1
  }
  bytes=$(hdr content-length) etag=$(hdr etag | tr -d '"') crc=$(hdr x-amz-checksum-crc32) ctype=$(hdr x-amz-checksum-type)
  parts=$(sed -n 's/^[0-9a-fA-F]*-\([0-9][0-9]*\)$/\1/p' <<<"$etag")
  jq -n --arg key "velero/$key" --arg status "$status" --arg bytes "$bytes" --arg etag "$etag" --arg parts "$parts" \
    --arg crc "$crc" --arg ctype "$ctype" \
    --arg headers "$(grep -i '^x-amz-checksum' "$work/head.txt" | cut -d: -f1 | tr '\n' ' ')" '
    def n: if . == "" then null else tonumber end;
    {key: $key, head_status: ($status | n), bytes: ($bytes | n), etag: $etag, parts: ($parts | n),
     checksum_crc32: (if $crc == "" then null else $crc end), checksum_type: (if $ctype == "" then null else $ctype end),
     checksum_headers: ($headers | split(" ") | map(select(. != "")))}' >"$work/bucket.json"
  if [ "$status" != 200 ]; then
    failc "HEAD of the tarball velero/$key as svp-velero: status $status"
    return 0
  fi
  if [ "${bytes:-0}" -gt 5242880 ]; then
    pass "tarball velero/$key is $bytes bytes, over 5 MiB"
  else
    failc "tarball velero/$key is ${bytes:-?} bytes, not over 5 MiB: the uploader did not have to go multipart (more fixture bytes)"
  fi
  if [ "${parts:-0}" -ge 2 ]; then
    pass "tarball uploaded in $parts parts (ETag $etag)"
  else
    failc "tarball not a multipart upload (ETag $etag)"
  fi
  if [ -n "$crc" ]; then
    pass "CRC32 of the tarball read back: $crc${ctype:+ ($ctype)}"
  else
    echo "note  HEAD with x-amz-checksum-mode: ENABLED returned no x-amz-checksum-crc32 (checksum headers: $(jq -r '.checksum_headers | join(", ") | if . == "" then "none" else . end' "$work/bucket.json")): what the store keeps of the plugin's CRC32"
  fi
}

# bucket_keys: every key of bucket velero, one a line (the first 1000: the caller lists again until it is empty).
bucket_keys() {
  local status
  status=$(s3 GET "/velero?list-type=2&max-keys=1000" "$work/list.xml")
  case $status in
    200) ;;
    # No bucket (a run stopped before the scenario made it): nothing in it.
    404) return 0 ;;
    *) echo "FAIL  list bucket velero as svp-velero: status $status" >&2; return 1 ;;
  esac
  grep -o '<Key>[^<]*</Key>' "$work/list.xml" | sed -e 's/^<Key>//' -e 's/<\/Key>$//' || true
}

cmd_run() {
  if [ -n "$runner" ]; then
    [ "$confirm" = "$ns" ] || die "run deletes Redpanda's StatefulSet and PVCs in $ns: add --confirm-delete $ns"
  else
    [ "$confirm" = "$ns" ] || die "run deletes namespace $ns: add --confirm-delete $ns"
  fi
  cmd_check
  local backup=drill-$ns-$stamp restore t0 t1= rto= ready
  restore=$backup-restore
  echo '{}' >"$work/bucket.json"
  : >"$work/fixtures.before"
  : >"$work/fixtures.after"

  echo "== 1. quiet Redpanda, offsets recorded"
  wait_for "every consumer group's lag to reach 0 (are uploads and load stopped?)" 600 all_lag_zero
  snapshot "$work/before"
  sleep 60
  snapshot "$work/again"
  cmp -s "$work/before" "$work/again" || {
    diff "$work/before" "$work/again" >&2 || true
    die "offsets or high watermarks moved within 60 s: something still writes; stop it and run again"
  }
  ok "$(groups_of "$work/before" | wc -l | tr -d ' ') groups ($(wc -l <"$work/before.active" | tr -d ' ') with members), \
$(awk '$1 == "T"' "$work/before" | wc -l | tr -d ' ') topic partitions recorded, nothing moving"
  if [ -n "$runner" ]; then
    local committed
    committed=$(awk '$1 == "G" && $5 ~ /^[0-9]+$/ && $5 > 0' "$work/before" | wc -l | tr -d ' ')
    [ "$committed" -gt 0 ] ||
      die "no consumer group has a committed offset above 0: offsets of 0 equal after the restore prove nothing (seed with make k8s-smoke first)"
    ok "$committed group partition(s) with a committed offset above 0"
    fixture_sums "$work/fixtures.before" || die "read the fixture ConfigMaps of $ns"
    [ -s "$work/fixtures.before" ] || die "no fixture ConfigMap in $ns (label $fixture_sel): the scenario writes them before the drill"
    ok "$(wc -l <"$work/fixtures.before" | tr -d ' ') fixture ConfigMap(s), SHA-256 of each recorded"
  fi

  echo "== 2. backup $backup"
  from_template "$backup_template" "$backup" | kc create -f - >/dev/null || die "create Backup $backup"
  wait_phase backups.velero.io "$backup" 1800
  local attempted completed
  attempted=$(kc -n velero get backups.velero.io "$backup" -o jsonpath='{.status.csiVolumeSnapshotsAttempted}')
  completed=$(kc -n velero get backups.velero.io "$backup" -o jsonpath='{.status.csiVolumeSnapshotsCompleted}')
  # Nothing is deleted yet: a backup without every volume's snapshot, or with a Secret, stops the drill here.
  [ "${attempted:-0}" -gt 0 ] && [ "${completed:-0}" = "$attempted" ] ||
    die "backup $backup has ${completed:-0} of ${attempted:-0} CSI snapshots completed: the volumes of $ns would be lost"
  ok "backup $backup Completed, $completed CSI snapshots"
  no_secret_in "$backup" || die "backup $backup holds Secrets (threat model BAK-2): $(grep -E '(^|/)Secret$' "$work/resource-kinds" | tr '\n' ' ')"
  pass "backup $backup holds no Secret ($(wc -l <"$work/resource-kinds" | tr -d ' ') kinds), $completed CSI snapshots"
  if [ -n "$runner" ]; then
    echo "kinds in the backup: $(tr '\n' ' ' <"$work/resource-kinds")"
    local missing
    # The resource list names each item namespace/name under its group/version/Kind.
    missing=$(jq -r '.["v1/ConfigMap"] // [] | map(split("/") | last) | .[]' "$work/resources.json" |
      LC_ALL=C sort | LC_ALL=C comm -23 <(cut -d' ' -f1 "$work/fixtures.before") -)
    [ -z "$missing" ] || die "fixture ConfigMaps missing from backup $backup: $(echo "$missing" | tr '\n' ' ')(Velero left them out)"
    pass "every fixture ConfigMap is in backup $backup"
    bucket_object "$backup"
  fi

  if [ -n "$runner" ] && ! argocd_present; then
    echo "== 3. skip  Argo CD not installed (dev path): no auto-sync to turn off"
    : >"$work/apps"
  else
    echo "== 3. Argo CD auto-sync off"
    : >"$work/apps"
    trap 'echo "stopped before T0: turning auto-sync back on" >&2; sync_on || true; rm -rf "$work"' EXIT
    sync_off
  fi

  if [ -n "$runner" ]; then
    echo "== 4. T0: delete Redpanda's StatefulSet and PVCs and the fixtures in $ns, restore"
    t0=$(now)
    kc -n "$ns" get pvc -l "$rp_sel" -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' >"$work/pvs" ||
      die "list the PersistentVolumes of Redpanda's PVCs"
    kc -n "$ns" delete statefulset -l "$rp_sel" --wait=true --timeout=5m >/dev/null || die "delete Redpanda's StatefulSet"
    kc -n "$ns" delete pvc -l "$rp_sel" --wait=false >/dev/null || die "delete Redpanda's PVCs"
    kc -n "$ns" delete configmap -l "$fixture_sel" --wait=true --timeout=2m >/dev/null || die "delete the fixture ConfigMaps"
    # A PVC still there when the Restore runs is skipped by it (it exists), and its old data would pass for restored.
    wait_for "Redpanda's pods and PVCs gone" 600 rp_gone
    wait_for "the PersistentVolumes of Redpanda's PVCs ($(tr '\n' ' ' <"$work/pvs"))gone (StorageClass reclaim Delete)" 300 pvs_gone
    ok "StatefulSet, $(grep -c . "$work/pvs") PVC(s) with their volumes and the fixtures deleted after $(($(now) - t0)) s"
    from_template restore.yaml "$restore" "$backup" | kc create -f - >/dev/null || die "create Restore $restore"
    wait_phase restores.velero.io "$restore" 1800
    ok "restore $restore Completed after $(($(now) - t0)) s"
  else
    echo "== 4. T0: delete namespace $ns, restore, auto-sync back on"
    t0=$(now)
    # Until the Restore is Completed an Application syncing into the namespace would make empty volumes: auto-sync stays
    # off on failure.
    trap 'echo "stopped after T0: auto-sync left off; once the namespace is restored, run:" >&2; sync_on_commands >&2; rm -rf "$work"' EXIT
    kc delete namespace "$ns" --wait=true --timeout=15m >/dev/null || die "delete namespace $ns"
    ok "namespace $ns deleted after $(($(now) - t0)) s"
    from_template restore.yaml "$restore" "$backup" | kc create -f - >/dev/null || die "create Restore $restore"
    wait_phase restores.velero.io "$restore" 1800
    ok "restore $restore Completed after $(($(now) - t0)) s"
    # The PVCs (from their snapshots) and the StatefulSet are back, so self-heal can make no empty volume now; and the
    # Secrets the charts render, left out of the backup, come back only when Argo CD applies them again (Redpanda's
    # redpanda-sts-lifecycle and redpanda-configurator, mounted by its StatefulSet: no broker pod gets Ready before).
    trap 'rm -rf "$work"' EXIT
    sync_on || die "auto-sync is still off: run the commands above, then watch namespace $ns by hand"
    local start
    start=$(now)
    until apps_synced; do
      [ $(($(now) - start)) -lt 600 ] || break
      sleep 5
    done
    if apps_synced; then
      pass "Argo CD: every Application Synced after the restore"
    else
      failc "Argo CD: an Application is not Synced 10 minutes after auto-sync was turned back on"
    fi
  fi

  echo "== 5. pods Ready, Redpanda healthy, consumers back; offsets checked before anything new is written"
  if [ -n "$runner" ]; then
    wait_for "Redpanda's pods in $ns Ready" 1800 rp_ready
  else
    wait_for "every pod of $ns Ready" 1800 ns_ready
  fi
  wait_for "the Redpanda cluster healthy" 600 redpanda_healthy
  wait_for "every consumer group that had members at step 1 with members again" 900 groups_back
  ready=$(($(now) - t0))
  ok "pods Ready, Redpanda healthy, consumers back after $ready s"
  # Before the smoke: its upload makes the consumers commit, so the offsets are compared with the backup's now.
  wait_for "every consumer group's lag back to 0" 900 all_lag_zero
  pass "every consumer group's lag back to 0"
  snapshot "$work/after"
  if diff <(awk '$1 == "G"' "$work/before") <(awk '$1 == "G"' "$work/after") >"$work/groups.diff"; then
    pass "committed offsets of every group equal to the backup's (none lost, none moved back)"
  else
    cat "$work/groups.diff" >&2
    failc "committed offsets differ from the backup's"
  fi
  if diff <(awk '$1 == "T" && $2 ~ /\.dlq$/' "$work/before") <(awk '$1 == "T" && $2 ~ /\.dlq$/' "$work/after") \
    >"$work/dlq.diff"; then
    pass "dead-letter topics (<topic>.dlq) unchanged"
  else
    cat "$work/dlq.diff" >&2
    failc "a DLQ topic grew"
  fi
  if ! diff <(awk '$1 == "T"' "$work/before") <(awk '$1 == "T"' "$work/after") >"$work/topics.diff"; then
    echo "note  high watermarks that moved since step 1 (events written after the backup are lost; relays may write):"
    cat "$work/topics.diff"
  fi
  if [ -n "$runner" ]; then
    fixture_sums "$work/fixtures.after" || die "read the restored fixture ConfigMaps of $ns"
    if cmp -s "$work/fixtures.before" "$work/fixtures.after"; then
      pass "every fixture ConfigMap restored with the same SHA-256 ($(wc -l <"$work/fixtures.after" | tr -d ' '))"
    else
      diff "$work/fixtures.before" "$work/fixtures.after" >&2 || true
      failc "fixture ConfigMaps after the restore differ from the backup's (missing or other content)"
    fi
  fi

  echo "== 6. T1: smoke passed"
  local smoke=
  if [ -n "$runner" ]; then
    # On the runner the smoke flow is the lab's own, through Envoy: make k8s-smoke, whose end passing is T1.
    if make -C "$repo" -s k8s-smoke </dev/null; then smoke=passed; else smoke=failed; fi
  else
    # The service is back only once the smoke flow passes, so T1 waits for it. It runs from the learner's terminal: it
    # needs the cloud API's address and a reset of the register rate limit there, neither of which this script knows.
    echo "Run the smoke flow through the cloud API now (deploy/compose/smoke.sh's steps, one new upload READY exactly once)."
    until [ "$smoke" = passed ] || [ "$smoke" = failed ]; do
      printf 'Type passed or failed when it ends: '
      read -r smoke || die "no answer about the smoke flow on stdin"
    done
  fi
  if [ "$smoke" = passed ]; then
    t1=$(now)
    rto=$((t1 - t0))
    pass "smoke flow through the API after the restore"
    ok "RTO = T1 - T0 = $rto s"
  else
    failc "smoke flow through the API after the restore: no RTO"
  fi

  mkdir -p "$repo/.k8s/drills"
  local json=$repo/.k8s/drills/velero-restore-$stamp.json
  printf '%s\n' ${results[@]+"${results[@]}"} | jq -s --arg ctx "$ctx" --arg ns "$ns" --arg backup "$backup" --arg restore "$restore" \
    --argjson t0 "$t0" --argjson t1 "${t1:-null}" --argjson ready "$ready" --argjson rto "${rto:-null}" \
    --arg mode "${runner:+runner}" --slurpfile bucket "$work/bucket.json" \
    --rawfile before "$work/fixtures.before" --rawfile after "$work/fixtures.after" \
    '{context: $ctx, namespace: $ns, backup: $backup, restore: $restore, t0: ($t0 | todate),
      t1: (if $t1 == null then null else ($t1 | todate) end), ready_seconds: $ready, rto_seconds: $rto, checks: .}
     + (if $mode == "runner" then {mode: "runner", bucket_object: $bucket[0],
          fixtures: {before: ($before | split("\n") | map(select(. != "") | split(" ") | {name: .[0], sha256: .[1]})),
                     after: ($after | split("\n") | map(select(. != "") | split(" ") | {name: .[0], sha256: .[1]}))}}
        else {} end)' >"$json"
  echo "results: $json"
  if [ -z "$runner" ]; then
    cat <<EOF
Left to the learner, then written down with the RTO:
  - like counts, view counts and feed rows unchanged (the SELECTs of deploy/compose/drills/duplicate-feed-events.sh)
  - the restored svp pods admitted by Kyverno: kubectl --context $ctx get policyreports -A, no new Fail
EOF
  fi
  [ "$failed" -eq 0 ] || exit 1
}

# ours: "name phase" of every backup the drill or the Schedule svp-daily made (Velero labels a Schedule's backups with
# velero.io/schedule-name); backups of anything else are left alone.
ours() {
  kc -n velero get backups.velero.io -o json | jq -r '.items[]
    | select(.metadata.labels["svp-drill"] == "velero-restore" or .metadata.labels["velero.io/schedule-name"] == "svp-daily")
    | "\(.metadata.name) \(.status.phase // "New")"'
}
# Velero refuses to delete a backup still running (New, Queued, InProgress, Finalizing...).
none_running() {
  local list
  list=$(ours) || return 1
  [ -z "$list" ] || ! grep -Eqv ' (Completed|PartiallyFailed|Failed|FailedValidation|Deleting)$' <<<"$list"
}

cmd_sweep() {
  # Once Velero is uninstalled nothing deletes the EBS snapshots (Retain) and bucket files of its backups, not even at
  # their ttl: the Schedule goes first so that no new backup starts, then every backup of the session goes through Velero.
  # In runner mode the sweep also runs after a step before the drill failed, Velero perhaps never installed: what needs
  # Velero is skipped then, and the fixtures and bucket velero are emptied all the same.
  local n=0
  if [ -n "$runner" ] && ! kc get crd backups.velero.io >/dev/null 2>&1; then
    echo "skip  Velero not installed: no Schedule, backup or restore to delete"
  else
    kc -n velero delete schedules.velero.io svp-daily --ignore-not-found >/dev/null || die "delete Schedule velero/svp-daily"
    ok "Schedule svp-daily deleted: no new backup"
    wait_for "the backups in progress to end" 1800 none_running
    local b
    ours >"$work/backups" || die "list the backups in velero"
    for b in $(cut -d' ' -f1 "$work/backups"); do
      from_template delete-backup.yaml "$b-delete" "$b" | kc apply -f - >/dev/null || die "request deletion of backup $b"
      echo "ok    deletion requested: backup $b"
      n=$((n + 1))
    done
    gone() {
      local list
      list=$(ours) || return 1
      [ -z "$list" ]
    }
    [ "$n" -eq 0 ] || wait_for "Velero to delete the backups and their snapshots (errors: kubectl --context $ctx -n velero \
get deletebackuprequests.velero.io -o jsonpath='{..status.errors}')" 900 gone
    kc -n velero delete restores.velero.io -l svp-drill=velero-restore --ignore-not-found >/dev/null
    kc -n velero delete deletebackuprequests.velero.io -l svp-drill=velero-restore --ignore-not-found >/dev/null
    ok "$n backups deleted (drill and svp-daily); drill restores removed"
  fi
  local left
  left=$(kc get volumesnapshotcontents -o json | jq -r '.items[] | select(.metadata.labels["velero.io/backup-name"] != null)
    | "\(.metadata.name) backup=\(.metadata.labels["velero.io/backup-name"]) snapshot=\(.status.snapshotHandle // "?")"')
  if [ -n "$left" ]; then
    if [ -n "$runner" ]; then
      echo "note  VolumeSnapshotContents of Velero backups still in the cluster (Retain; they go with the job's cluster):"
    else
      echo "note  VolumeSnapshotContents of Velero backups still in the cluster; their EBS snapshots outlive Velero (Retain):"
    fi
    echo "$left"
  fi
  if [ -n "$runner" ]; then
    kc -n "$ns" delete configmap -l "$fixture_sel" --ignore-not-found >/dev/null || die "delete the fixture ConfigMaps of $ns"
    ok "fixture ConfigMaps of $ns deleted (label $fixture_sel)"
    # What Velero did not delete (a restore's logs and results, a backup it never knew of) goes object by object, as
    # svp-velero: a user whose policy reaches bucket velero alone cannot touch pg-backups, uploads or media.
    if ! kc -n velero get secret velero-s3 >/dev/null 2>&1; then
      echo "skip  no Secret velero/velero-s3: Velero never had a login, so nothing of it is in bucket velero"
      return 0
    fi
    velero_login || die "read the login of svp-velero from Secret velero/velero-s3 (needed to empty bucket velero)"
    local round key keys status deleted=0
    for round in 1 2 3 4 5 6 7 8 9 10; do
      keys=$(bucket_keys) || die "list bucket velero"
      [ -n "$keys" ] || break
      while IFS= read -r key; do
        [[ $key =~ ^[A-Za-z0-9._/-]+$ ]] || die "bucket velero holds a key with characters this sweep does not send: delete it by hand"
        status=$(s3 DELETE "/velero/$key" "$work/delete.out")
        [ "$status" = 204 ] || [ "$status" = 200 ] || die "delete velero/$key as svp-velero: status $status"
        deleted=$((deleted + 1))
      done <<<"$keys"
    done
    keys=$(bucket_keys) || die "list bucket velero"
    [ -z "$keys" ] || die "bucket velero still holds objects after $round rounds of deletes"
    ok "bucket velero empty ($deleted object(s) Velero left there deleted)"
    return 0
  fi
  cat <<EOF
Left for the learner (AWS, with the profile and region of the cloud session): EBS snapshots made through CSI that are
still there. After the sweep none from this session should be left: delete each one started during the session with the
second command.
  AWS_PROFILE=<profile> aws ec2 describe-snapshots --region <region> --owner-ids self \\
    --filters Name=tag-key,Values=CSIVolumeSnapshotName \\
    --query 'Snapshots[].{id:SnapshotId,name:Tags[?Key==\`CSIVolumeSnapshotName\`]|[0].Value,started:StartTime}' --output table
  AWS_PROFILE=<profile> aws ec2 delete-snapshot --region <region> --snapshot-id <id>
EOF
}

case $cmd in
  check) cmd_check ;;
  run) cmd_run ;;
  sweep) cmd_sweep ;;
esac
