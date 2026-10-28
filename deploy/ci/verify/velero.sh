# shellcheck shell=bash
# Scenario velero of deploy/ci/verify-run.sh, which sources this file: Velero backing up and restoring Redpanda's
# volume through CSI snapshots, to the object store of the k3d cluster of the dev path (job k3d of
# .github/workflows/verify.yml). Each step runs only when the ones before it passed; one that does not pass before the
# drill sends the scenario straight to the sweep and the uninstall, so the drill never runs on a half-made install:
#
#   k8s-up               make k8s-up with SVP_K8S_RUNNER_CSI=1: deploy/k8s/install.sh installs the CSI hostpath driver
#                        (deploy/k8s/cloud/runner/csi/) right before Redpanda and puts Redpanda's volume on its
#                        StorageClass
#   velero-prepare       namespace velero (Pod Security restricted); in the object store, bucket velero (no bucket
#                        policy, no CORS) and user svp-velero with a policy that reaches that bucket only
#                        (deploy/k8s/cloud/runner/velero/svp-velero-policy.json), its key random, made here and kept
#                        only in Secret velero/velero-s3 (never in .env, never printed; added to the secret list of
#                        deploy/ci/verify-mask.sh before anything uses it, so the job's log masks it as soon as this
#                        step ends and the artifact scan looks for it: see velero_keep_secret);
#                        NetworkPolicy svp-data/velero-s3 (deploy/k8s/cloud/runner/velero/networkpolicy.yaml); then,
#                        through Envoy as BAK-1 does, svp-velero lists, reads, writes and deletes in velero and reaches
#                        no other bucket, and no service's user nor svp-pg-backup reaches velero
#   velero-install       the chart of deploy/k8s/cloud/charts.json with deploy/k8s/cloud/values/velero.yaml, then
#                        deploy/k8s/cloud/runner/velero/values.yaml (BackupStorageLocation to s3.svp-data:9000)
#   velero-ready         Deployment velero Available, its pod Ready, BackupStorageLocation default Available, each
#                        within a limit; else kubectl describe of the location (no Secret in it)
#   velero-reach         the NetworkPolicy, now that Velero's pod is there: a probe pod in velero with the two labels
#                        the policy selects reaches s3.svp-data:9000, one without them does not, while its own DNS
#                        lookup of the name and a TCP connection to the cluster's DNS work (so the refusal is the
#                        policy's, not a missing name or a pod that is not running); the location Available is
#                        Velero's own server reaching it
#   velero-seed          make k8s-smoke (one upload to READY: the consumer groups commit), at least one group partition
#                        with a committed offset above 0, then 12 fixture ConfigMaps in svp-data (label
#                        svp-drill=velero-fixture, 600 KiB of random bytes each, so the backup's tarball cannot compress
#                        under 5 MiB and the AWS plugin's uploader has to go multipart; nothing secret)
#   drill-restore-check  deploy/k8s/cloud/velero/drill-restore.sh check, runner mode (see that script)
#   drill-restore        drill-restore.sh run: backup, delete Redpanda's StatefulSet, PVCs and fixtures, restore,
#                        offsets, lag, DLQ, fixtures' SHA-256, the tarball in the bucket, make k8s-smoke, RTO
#   drill-restore-sweep  drill-restore.sh sweep: the drill's backups through Velero, the fixtures, then bucket velero
#                        emptied (always runs, as the next one)
#   velero-uninstall     what the end of a cloud session runs: helm uninstall, namespace velero deleted, the CRDs
#                        *.velero.io deleted; NetworkPolicy svp-data/velero-s3 deleted; then nothing of Velero is
#                        left: no CRD, webhook, ClusterRole or ClusterRoleBinding named velero, namespace or policy
#
# The CSI driver stays: Redpanda's volume is on it, and the cluster goes with the job. Linux only, as verify-run.sh.

build=k8s-up
job_minutes_default=330
k3d=1

# velero_s3_origin: the object store through Envoy, as from a browser (the HTTPRoute s3 of chart svp-data).
velero_s3_origin=https://s3.svp.localhost:8443

# The calls velero-prepare makes inside the object store's pod, as its root user: the root login never leaves the pod
# (curl reads it from the container's own environment, as a config on its stdin), and svp-velero's key arrives on
# stdin, first line, followed by the policy. The pod's root filesystem is read-only, so the temporary files go to
# /dev/shm, the pod's own memory.
# shellcheck disable=SC2016 # expanded by the pod's sh, not here
velero_store_script='set -eu
IFS= read -r key
case $key in "" | *[!0-9A-Za-z]*) echo "the key of svp-velero must be letters and digits" >&2; exit 1 ;; esac
tmp=$(mktemp -d -p /dev/shm)
trap "rm -rf $tmp" EXIT
cat >"$tmp/policy.json"
call() {
  m=$1 p=$2
  shift 2
  printf "user = \"%s:%s\"\n" "$RUSTFS_ACCESS_KEY" "$RUSTFS_SECRET_KEY" |
    curl -sS -K - --aws-sigv4 aws:amz:us-east-1:s3 -X "$m" -o "$tmp/resp" -w "%{http_code}" "$@" "http://127.0.0.1:9000$p"
}
code() { sed -n -e "s:.*<Code>\([A-Za-z]*\)</Code>.*:\1:p" -e "s:.*\"Code\" *\: *\"\([A-Za-z]*\)\".*:\1:p" "$tmp/resp" | head -n 1; }
must() {
  what=$1 statuses=$2
  shift 2
  st=$(call "$@") || { echo "$what: no answer from the store" >&2; exit 1; }
  case " $statuses " in *" $st "*) return 0 ;; esac
  echo "$what: status $st $(code)" >&2
  exit 1
}
st=$(call PUT /velero) || { echo "bucket velero: no answer from the store" >&2; exit 1; }
case $st in
  200) ;;
  409) [ "$(code)" = BucketAlreadyOwnedByYou ] || { echo "bucket velero: status 409 $(code)" >&2; exit 1; } ;;
  *) echo "bucket velero: status $st $(code)" >&2; exit 1 ;;
esac
must "bucket policy of velero" "200 204" DELETE "/velero?policy"
must "CORS of velero" "200 204" DELETE "/velero?cors"
must "policy svp-velero" "200 204" PUT "/rustfs/admin/v3/add-canned-policy?name=svp-velero" --data-binary "@$tmp/policy.json"
printf "{\"secretKey\":\"%s\",\"status\":\"enabled\"}" "$key" >"$tmp/user.json"
must "user svp-velero" "200 204" PUT "/rustfs/admin/v3/add-user?accessKey=svp-velero" --data-binary "@$tmp/user.json"
must "policy of user svp-velero" "200 204" PUT "/rustfs/admin/v3/set-user-or-group-policy?policyName=svp-velero&userOrGroup=svp-velero&isGroup=false"
echo "ok    bucket velero (no bucket policy, no CORS), user svp-velero with policy svp-velero only"'

# velero_req CONFIG METHOD PATH: one request to the object store through Envoy, signed (AWS Signature V4) with the
# login of the private curl config CONFIG; prints "STATUS CODE", CODE the S3 error code of the answer ("-" when none).
velero_req() {
  local out status code
  out=$(mktemp)
  status=$(curl -s --max-time 15 --cacert "$repo/.k8s/ca.crt" -o "$out" -w '%{http_code}' -K "$1" \
    --aws-sigv4 aws:amz:us-east-1:s3 -X "$2" ${4:+--data-binary "$4"} "$velero_s3_origin$3" || true)
  code=$(sed -n 's:.*<Code>\([A-Za-z]*\)</Code>.*:\1:p' "$out" | sed -n 1p)
  rm -f "$out"
  echo "$status ${code:--}"
}

# velero_expect CONFIG USER METHOD PATH WANT [BODY]: velero_req must answer WANT; prints a PASS or FAIL line, and
# counts a FAIL in velero_failed.
velero_expect() {
  local got
  got=$(velero_req "$1" "$3" "$4" "${6:-}")
  if [ "$got" = "$5" ]; then
    echo "PASS  $2 $3 $4: $got"
  else
    echo "FAIL  $2 $3 $4: want $5, got $got"
    velero_failed=$((velero_failed + 1))
  fi
}

# velero_access KEY DIR: the access checks of velero-prepare, curl configs in DIR (mode 700).
velero_access() {
  local key=$1 dir=$2 obj u
  obj=velero-access-$(date +%s)
  velero_failed=0
  printf 'user = "svp-velero:%s"\n' "$key" >"$dir/svp-velero.curl"
  kc -n svp-data get secret s3-users -o json | jq -r '
    "user = \(("svp-video-service:" + (.data.SVP_VIDEO_S3_SECRET_KEY | @base64d)) | @json)"' >"$dir/svp-video-service.curl" ||
    fail "read the login of svp-video-service from Secret svp-data/s3-users"
  kc -n svp-data get secret s3-users -o json | jq -r '
    "user = \(("svp-media-worker:" + (.data.SVP_MEDIA_WORKER_S3_SECRET_KEY | @base64d)) | @json)"' >"$dir/svp-media-worker.curl" ||
    fail "read the login of svp-media-worker from Secret svp-data/s3-users"
  kc -n svp-data get secret pg-backup-s3 -o json |
    jq -r '"user = \(((.data.ACCESS_KEY_ID | @base64d) + ":" + (.data.ACCESS_SECRET_KEY | @base64d)) | @json)"' \
      >"$dir/svp-pg-backup.curl" || fail "read the login of svp-pg-backup from Secret svp-data/pg-backup-s3"
  printf 'velero access probe\n' >"$dir/body"

  # svp-velero: everything a backup needs in its bucket, nothing anywhere else.
  u="$dir/svp-velero.curl"
  velero_expect "$u" svp-velero GET "/velero?list-type=2&max-keys=1" "200 -"
  velero_expect "$u" svp-velero GET "/velero/$obj" "404 NoSuchKey"
  velero_expect "$u" svp-velero PUT "/velero/$obj" "200 -" "@$dir/body"
  velero_expect "$u" svp-velero GET "/velero/$obj" "200 -"
  velero_expect "$u" svp-velero DELETE "/velero/$obj" "204 -"
  velero_expect "$u" svp-velero GET "/uploads?list-type=2&max-keys=1" "403 AccessDenied"
  velero_expect "$u" svp-velero GET "/uploads/uploads/$obj" "403 AccessDenied"
  velero_expect "$u" svp-velero PUT "/uploads/uploads/$obj" "403 AccessDenied" "@$dir/body"
  velero_expect "$u" svp-velero GET "/media?list-type=2&max-keys=1" "403 AccessDenied"
  # Not under media/: what is there any request may read (UP-6), signed or not.
  velero_expect "$u" svp-velero GET "/media/$obj" "403 AccessDenied"
  velero_expect "$u" svp-velero GET "/pg-backups?list-type=2&max-keys=1" "403 AccessDenied"
  velero_expect "$u" svp-velero GET "/pg-backups/$obj" "403 AccessDenied"
  velero_expect "$u" svp-velero PUT "/pg-backups/$obj" "403 AccessDenied" "@$dir/body"

  # Every other user of the store: refused at velero; the control shows its login itself works.
  local who
  for who in svp-video-service svp-media-worker svp-pg-backup; do
    u="$dir/$who.curl"
    velero_expect "$u" "$who" GET "/velero?list-type=2&max-keys=1" "403 AccessDenied"
    velero_expect "$u" "$who" GET "/velero/$obj" "403 AccessDenied"
    velero_expect "$u" "$who" PUT "/velero/$obj" "403 AccessDenied" "@$dir/body"
    if [ "$who" = svp-pg-backup ]; then
      velero_expect "$u" "$who" GET "/pg-backups?list-type=2&max-keys=1" "200 -"
    else
      velero_expect "$u" "$who" GET "/uploads/uploads/$obj" "404 NoSuchKey"
    fi
  done
  rm -f "$dir"/*.curl
  [ "$velero_failed" = 0 ] || fail "$velero_failed access check(s) of bucket velero did not answer as they must"
  ok "svp-velero reaches bucket velero only; svp-video-service, svp-media-worker and svp-pg-backup are refused there"
}

# velero_keep_secret VALUE: adds VALUE and its base64 to cluster.values, the list of the cluster's secret values that
# deploy/ci/verify-mask.sh keeps in $SVP_VERIFY_SECRETS (one value per line; the list only grows). The verify-mask.sh
# cluster that verify-run.sh runs as this step ends masks what is new in that list in the job's log, and
# deploy/ci/verify-collect.sh searches the artifact for every value of it. A value made in a step has to go this way:
# ci_mask here would write its ::add-mask:: line, value and all, into the step's own log file, which is not the job's
# log; and Secret velero/velero-s3 holds the key only inside its credentials file, whose line
# aws_secret_access_key=<key> verify-mask.sh masks whole, never the bare key.
velero_keep_secret() (
  umask 077
  mkdir -p "$SVP_VERIFY_SECRETS" &&
    { printf '%s\n' "$1" && printf '%s' "$1" | base64 | tr -d '\n' && printf '\n'; } \
      >>"$SVP_VERIFY_SECRETS/cluster.values"
)

# velero_prepare: step velero-prepare (see the top).
velero_prepare() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  local key dir
  umask 077
  dir=$(mktemp -d)
  # shellcheck disable=SC2064 # dir is fixed now
  trap "rm -rf '$dir'" EXIT
  kc create namespace velero --dry-run=client -o yaml | kc apply --server-side --field-manager=svp-verify -f - >/dev/null ||
    fail "create namespace velero"
  kc label namespace velero --overwrite pod-security.kubernetes.io/enforce=restricted >/dev/null ||
    fail "label namespace velero with Pod Security restricted"
  ok "namespace velero (Pod Security restricted)"
  # 20 random bytes in hex: 40 letters and digits, the form of the other secret keys of the store.
  key=$(openssl rand -hex 20) || fail "make the key of svp-velero"
  velero_keep_secret "$key" || fail "add the key of svp-velero to the secret list of deploy/ci/verify-mask.sh"
  { printf '%s\n' "$key"; cat "$repo/deploy/k8s/cloud/runner/velero/svp-velero-policy.json"; } |
    kc -n svp-data exec -i s3-0 -c s3 -- sh -c "$velero_store_script" || fail "make bucket velero and user svp-velero"
  # Server-side apply: a client-side one would copy the data into the last-applied-configuration annotation.
  printf '%s' "$key" | jq -Rs '{apiVersion: "v1", kind: "Secret", type: "Opaque",
      metadata: {name: "velero-s3", namespace: "velero"},
      data: {cloud: ("[default]\naws_access_key_id=svp-velero\naws_secret_access_key=" + . + "\n" | @base64)}}' |
    kc apply --server-side --field-manager=svp-verify --force-conflicts -f - >/dev/null || fail "apply Secret velero/velero-s3"
  ok "Secret velero/velero-s3 (key cloud: profile default of svp-velero)"
  kc apply --server-side --field-manager=svp-verify -f "$repo/deploy/k8s/cloud/runner/velero/networkpolicy.yaml" \
    >/dev/null || fail "apply NetworkPolicy svp-data/velero-s3"
  ok "NetworkPolicy svp-data/velero-s3: pod s3 TCP 9000 from Velero's server pod in velero"
  velero_access "$key" "$dir"
}

# velero_install: step velero-install. Helm runs the chart's CRD Job and applies the release; velero-ready waits.
velero_install() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  local chart_repo chart version
  read -r chart_repo chart version < <(jq -r '.charts[] | select(.name == "velero") | "\(.repo) \(.chart) \(.version)"' \
    "$repo/deploy/k8s/cloud/charts.json") || fail "read chart velero of deploy/k8s/cloud/charts.json"
  echo "helm upgrade --install velero $chart --repo $chart_repo --version $version (namespace velero)"
  hc upgrade --install velero "$chart" --repo "$chart_repo" --version "$version" --namespace velero \
    --values "$repo/deploy/k8s/cloud/values/velero.yaml" --values "$repo/deploy/k8s/cloud/runner/velero/values.yaml" \
    --wait=hookOnly --timeout 10m >/dev/null || fail "install chart velero"
  ok "release velero installed (CRDs of the image's version, BackupStorageLocation default to s3.svp-data:9000)"
}

# velero_bsl_available: true once BackupStorageLocation velero/default is Available.
velero_bsl_available() {
  [ "$(kc -n velero get backupstoragelocations.velero.io default -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ]
}

# velero_ready: step velero-ready.
velero_ready() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  if ! kc -n velero wait --for=condition=Available deployment/velero --timeout=300s >/dev/null ||
    ! kc -n velero wait --for=condition=Ready pod -l name=velero,app.kubernetes.io/name=velero --timeout=120s >/dev/null; then
    unready_report velero || true
    fail "Deployment velero/velero Available and its pod Ready within 300 s and 120 s"
  fi
  ok "Deployment velero Available, its pod Ready"
  local deadline=$((SECONDS + 300))
  until velero_bsl_available; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kc -n velero describe backupstoragelocation default || true
      fail "BackupStorageLocation velero/default Available within 300 s (status above: the login of Secret velero/velero-s3, bucket velero, NetworkPolicy svp-data/velero-s3)"
    fi
    sleep 5
  done
  ok "BackupStorageLocation default Available: Velero's server reaches bucket velero as svp-velero"
}

# velero_probe_pod NAME LABELS IMAGE: a pod in velero that only sleeps, for the connection probes of velero-reach;
# LABELS a JSON object. Pod Security restricted, as the namespace enforces.
velero_probe_pod() {
  jq -n --arg name "$1" --argjson labels "$2" --arg image "$3" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: $name, namespace: "velero", labels: $labels},
    spec: {automountServiceAccountToken: false, restartPolicy: "Never", terminationGracePeriodSeconds: 1,
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "probe", image: $image, command: ["sleep", "900"],
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {cpu: "200m", memory: "64Mi"}}}]}}' |
    kc create -f - >/dev/null
}

# The probes inside a probe pod (its image's busybox): "dns" or "nodns" for the name of the object store, then the state
# of a TCP connection to it and to the cluster's DNS: open, timeout (no answer in 5 s: dropped) or refused (an answer
# at once: rejected, the policy's other way of saying no, or nothing listening).
# shellcheck disable=SC2016 # expanded by the pod's sh, not here
velero_probe_script='probe() {
  s=$(date +%s)
  if timeout 8 nc -z -w 5 "$1" "$2" >/dev/null 2>&1; then echo open; return; fi
  if [ $(($(date +%s) - s)) -ge 4 ]; then echo timeout; else echo refused; fi
}
if nslookup s3.svp-data.svc.cluster.local >/dev/null 2>&1; then echo dns; else echo nodns; fi
probe s3.svp-data.svc.cluster.local 9000
probe kube-dns.kube-system.svc.cluster.local 53'

# velero_reach: step velero-reach (see the top).
velero_reach() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  local image allowed denied failed=0
  velero_bsl_available || fail "BackupStorageLocation velero/default is not Available: velero-ready did not pass"
  # The image threats.sh probes with: the cluster already has it, and its busybox has nc, nslookup and timeout.
  image=$(kc -n svp get deployment media-worker -o jsonpath='{.spec.template.spec.containers[0].image}') ||
    fail "read the image of deployment svp/media-worker"
  trap 'kc -n velero delete pod velero-probe-allowed velero-probe-denied --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
  # The two labels policy velero-s3 selects, without app.kubernetes.io/instance: Velero's Deployment does not adopt it.
  velero_probe_pod velero-probe-allowed '{"name": "velero", "app.kubernetes.io/name": "velero"}' "$image" ||
    fail "create pod velero/velero-probe-allowed"
  velero_probe_pod velero-probe-denied '{"app.kubernetes.io/name": "velero-probe"}' "$image" ||
    fail "create pod velero/velero-probe-denied"
  kc -n velero wait --for=condition=Ready pod/velero-probe-allowed pod/velero-probe-denied --timeout=120s >/dev/null ||
    fail "probe pods Ready in velero within 120 s"
  allowed=$(kc -n velero exec velero-probe-allowed -- sh -c "$velero_probe_script" | tr '\n' ' ') ||
    fail "run the probes in velero/velero-probe-allowed"
  denied=$(kc -n velero exec velero-probe-denied -- sh -c "$velero_probe_script" | tr '\n' ' ') ||
    fail "run the probes in velero/velero-probe-denied"
  echo "probe with the labels of Velero's server pod: $allowed(name of s3, s3:9000, kube-dns:53)"
  echo "probe without them:                        $denied(name of s3, s3:9000, kube-dns:53)"
  ok "positive: BackupStorageLocation Available (Velero's own server pod reaches s3:9000)"
  if [ "$allowed" = "dns open open " ]; then
    echo "PASS  a pod with the labels policy velero-s3 selects reaches s3.svp-data:9000"
  else
    echo "FAIL  a pod with the labels policy velero-s3 selects reaches s3.svp-data:9000 (got: $allowed)"
    failed=1
  fi
  case $denied in
    "dns timeout open " | "dns refused open ")
      echo "PASS  a pod of velero without those labels is refused at s3.svp-data:9000 ($(echo "$denied" | cut -d' ' -f2)), while its DNS lookup and a TCP connection to kube-dns work"
      ;;
    "nodns "*) echo "FAIL  the name of s3 does not resolve in the probe pod: a refusal there would prove nothing"; failed=1 ;;
    *) echo "FAIL  a pod of velero without the labels of Velero's server pod is refused at s3:9000 and reaches kube-dns:53 (got: $denied)"; failed=1 ;;
  esac
  [ "$failed" = 0 ] || fail "NetworkPolicy svp-data/velero-s3 does not do what it must"
}

# velero_seed: step velero-seed (see the top).
velero_seed() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  local g committed=0 i tmp
  make -C "$repo" -s k8s-smoke || fail "make k8s-smoke (the seed of the drill)"
  rpk_() { kc -n svp-data exec redpanda-0 -c redpanda -- rpk "$@"; }
  for g in $(rpk_ group list | awk 'NR > 1 { print $2 }'); do
    committed=$((committed + $(rpk_ group describe "$g" | awk '
      $1 == "TOPIC" { for (i = 1; i <= NF; i++) col[$i] = i; table = 1; next }
      table && NF >= 3 && $col["CURRENT-OFFSET"] ~ /^[0-9]+$/ && $col["CURRENT-OFFSET"] > 0 { n++ }
      END { print n + 0 }')))
  done
  [ "$committed" -gt 0 ] || fail "no consumer group has a committed offset above 0 after make k8s-smoke"
  ok "$committed group partition(s) with a committed offset above 0"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # tmp is fixed now
  trap "rm -rf '$tmp'" EXIT
  kc -n svp-data delete configmap -l svp-drill=velero-fixture --ignore-not-found >/dev/null ||
    fail "delete the fixtures of an earlier run"
  # Random bytes: kubectl stores them under binaryData (not UTF-8), as base64 in the backup's JSON, which gzip brings
  # back to about their own size. 12 x 600 KiB is over 7 MiB, under the 1 MiB limit of a ConfigMap each.
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    head -c 614400 /dev/urandom >"$tmp/random.bin"
    kc -n svp-data create configmap "svp-velero-fixture-$i" --from-file=random.bin="$tmp/random.bin" --dry-run=client \
      -o json | jq '.metadata.labels = {"svp-drill": "velero-fixture"}' | kc create -f - >/dev/null ||
      fail "create ConfigMap svp-data/svp-velero-fixture-$i"
  done
  ok "12 fixture ConfigMaps in svp-data (label svp-drill=velero-fixture, 600 KiB of random bytes each)"
}

# velero_names REGEX GET_ARGS...: the names (kind/name) that kubectl get GET_ARGS -o name lists and that match REGEX
# (awk, on the name in lower case); returns 1, printing nothing, when the list cannot be read, so an API that does not
# answer is never taken for "none".
velero_names() {
  local re=$1 all
  shift
  all=$(kc get "$@" -o name) || return 1
  printf '%s\n' "$all" | awk -v re="$re" 'tolower($0) ~ re'
}

# velero_left WHAT REGEX GET_ARGS...: true when velero_names REGEX GET_ARGS... finds nothing; otherwise a FAIL line,
# naming what is left or saying the list could not be read.
velero_left() {
  local what=$1 found
  shift
  if ! found=$(velero_names "$@"); then
    echo "FAIL  $what: the list could not be read, so what is left is unknown"
    return 1
  fi
  [ -z "$found" ] && return 0
  echo "FAIL  $what left: $(printf '%s\n' "$found" | tr '\n' ' ')"
  return 1
}

# velero_uninstall: step velero-uninstall (see the top).
velero_uninstall() {
  set -euo pipefail
  # shellcheck source=deploy/k8s/lib.sh
  . "$repo/deploy/k8s/lib.sh"
  local crd crds left=0
  if hc status velero --namespace velero >/dev/null 2>&1; then
    hc uninstall velero --namespace velero --wait --timeout 5m >/dev/null || fail "helm uninstall velero"
    ok "release velero uninstalled"
  else
    echo "skip  no release velero to uninstall"
  fi
  kc delete namespace velero --ignore-not-found --wait=true --timeout=5m >/dev/null || fail "delete namespace velero"
  crds=$(velero_names '[.]velero[.]io$' crd) || fail "list the CRDs of the cluster, to delete those of Velero"
  for crd in $crds; do
    kc delete "$crd" --wait=true --timeout=2m >/dev/null || fail "delete $crd"
  done
  kc -n svp-data delete networkpolicy velero-s3 --ignore-not-found >/dev/null || fail "delete NetworkPolicy svp-data/velero-s3"
  ok "namespace velero, the CRDs *.velero.io and NetworkPolicy svp-data/velero-s3 deleted"
  # What is left, each kind on its own line; an error reading one is not "nothing left".
  velero_left "CRDs *.velero.io" '[.]velero[.]io$' crd || left=1
  velero_left "webhook configurations named velero" velero \
    validatingwebhookconfigurations,mutatingwebhookconfigurations || left=1
  velero_left "cluster RBAC named velero (the server's binding is cluster-admin)" velero \
    clusterroles,clusterrolebindings || left=1
  velero_left "namespace velero" '^namespace/velero$' namespaces || left=1
  velero_left "NetworkPolicy svp-data/velero-s3" '/velero-s3$' -n svp-data networkpolicies || left=1
  [ "$left" = 0 ] || fail "Velero is not gone"
  ok "nothing of Velero left: no CRD, webhook, cluster RBAC, namespace velero or NetworkPolicy svp-data/velero-s3"
}

export velero_s3_origin velero_store_script velero_probe_script
export -f velero_req velero_expect velero_access velero_keep_secret velero_prepare velero_install velero_bsl_available \
  velero_ready velero_probe_pod velero_reach velero_seed velero_names velero_left velero_uninstall

# velero_gate NAME LIMIT COMMAND...: step, unless a step before it did not pass (velero_stop of scenario_targets).
velero_gate() {
  if [ -n "$velero_stop" ]; then
    skip "$1" "$velero_stop"
    return
  fi
  step "$@"
  case $last_status in fail | timeout) velero_stop="$1 did not pass: no drill on a half-made install" ;; esac
}

scenario_targets() {
  local velero_stop= velero_drill=deploy/k8s/cloud/velero/drill-restore.sh
  step k8s-up 60 env SVP_K8S_RUNNER_CSI=1 make k8s-up
  velero_gate velero-prepare 10 bash -c 'velero_prepare'
  velero_gate velero-install 15 bash -c 'velero_install'
  velero_gate velero-ready 10 bash -c 'velero_ready'
  velero_gate velero-reach 10 bash -c 'velero_reach'
  velero_gate velero-seed 20 bash -c 'velero_seed'
  velero_gate drill-restore-check 5 "$velero_drill" --context k3d-svp check
  velero_gate drill-restore 75 "$velero_drill" --context k3d-svp --confirm-delete svp-data run
  # Whatever happened above: the drill's backups and objects go, then Velero, as at the end of a cloud session.
  step drill-restore-sweep 20 "$velero_drill" --context k3d-svp sweep
  step velero-uninstall 15 bash -c 'velero_uninstall'
}
