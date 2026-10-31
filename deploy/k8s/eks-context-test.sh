#!/usr/bin/env bash
# Tests for the scripts that reach an EKS cluster of the project (the eks-* targets of deploy/k8s/k8s.mk), without a
# cluster, a network or AWS: fake kubectl, k3d, docker, curl, ffmpeg and sleep first on PATH, each recording its
# arguments, and a fake helm that runs the real one for `helm template` (nothing reaches a cluster) and records every
# other call. Everything is a fixture in a temporary directory: a copy of this checkout's deploy/ committed into a
# throwaway git repository (so gitops.sh can read the charts at a commit), with a fake .env and a stub of
# deploy/ci/values-check.sh (the signatures are its own test's), and a throwaway svp-gitops whose root chart has the
# shape of the platform layer: Application svp-cluster with values files and a valuesObject. The fake secrets are made
# at run time, so no file of the repository holds one. Cases:
#   - deploy/k8s/lib.sh: the context of kc and hc (k3d-svp unless SVP_KUBE_CONTEXT is svp-stg or svp-prd), every other
#     name refused as the file is sourced, a cloud context refused by a script not written for it, and the helpers of
#     the local cluster alone refusing svp-stg before docker or k3d run;
#   - deploy/k8s/gitops.sh on svp-stg: CLUSTER_VALUES checked before any kubectl (a key missing, of the wrong kind, of
#     another cluster, the file missing), SVP_RDS_MASTER_PASSWORD required; a run that passes calls kubectl and helm on
#     svp-stg only, never k3d or docker, makes the namespaces of svp-cluster's values in the root's render (no
#     cnpg-system), applies a root with platform eks and cluster from the file, writes pg-superuser from
#     SVP_RDS_MASTER_PASSWORD and no source of the in-cluster object store, runs glitchtip-init.sh;
#   - deploy/k8s/secrets.sh on svp-stg without SVP_RDS_MASTER_PASSWORD or without svp-secrets, with it and the store
#     in the cluster; on k3d-svp as before (pg-superuser from .env, the store's sources, the same line);
#   - reset_register_limit of deploy/compose/lib.sh with SVP_STACK=eks: the context passed, every other one refused;
#   - deploy/k8s/eks-seed.sh with a fake API behind curl: every request to https://api.<domain> or the form's URL, and
#     a stop when explore holds fewer than 30 videos.
# No output of a script may hold a secret value or its base64.
#
# Usage, from anywhere: deploy/k8s/eks-context-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
for tool in helm jq git openssl perl; do
  command -v "$tool" >/dev/null || {
    echo "FAIL  $tool is not installed" >&2
    exit 1
  }
done
real_helm=$(command -v helm)

# --- the fake tools. FAKE_STATE is the folder of their logs and answers.
bin=$work/bin
mkdir -p "$bin"
cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
s=$FAKE_STATE
# One line per call: an argument of several lines (the code of a python shell) on one.
printf '%s' "$*" | tr '\n' ' ' >>"$s/kubectl.log"
echo >>"$s/kubectl.log"
[ "${1:-}" = --context ] || { echo "fake kubectl: --context is not the first argument" >&2; exit 2; }
shift 2
[ "${1:-}" != -n ] || shift 2
args="$*"
case $args in
  "get --raw /readyz" | "rollout status deployment/glitchtip --timeout=300s") ;;
  "get nodes -o jsonpath="*) printf 'arm64\narm64\n' ;;
  "get namespace "*) grep -qx "${args#get namespace }" "$s/namespaces" ;;
  "apply "* | "create -f -") { echo "---"; cat; echo; } >>"$s/applied.yaml" ;;
  "get pvc "* | "get secret glitchtip-runtime" | "get crd "* | "get rollouts.argoproj.io "*) exit 1 ;;
  "get pod "* | "get deployment "*) ;;
  "get applications.argoproj.io -o json") cat "$s/apps.json" ;;
  "exec deployment/glitchtip "*) printf 'svp-dsn=%s\nsvp-token=%s\nsvp-sourcemaps-token=%s\n' "$FAKE_DSN" "$FAKE_TOKEN" "$FAKE_SOURCEMAPS_TOKEN" ;;
  "get externalsecrets.external-secrets.io -A -o json")
    n=$(cat "$s/annotations" 2>/dev/null || echo 0)
    jq -n --arg rv "1-$n" '{items: [["svp", "sentry"], ["svp-obs", "glitchtip-api"], ["svp-obs", "glitchtip-sourcemaps"]]
      | map({metadata: {namespace: .[0], name: .[1], generation: 1},
             status: {syncedResourceVersion: $rv, conditions: [{type: "Ready", status: "True"}]}})}' ;;
  "annotate externalsecrets.external-secrets.io "*) echo $(($(cat "$s/annotations" 2>/dev/null || echo 0) + 1)) >"$s/annotations" ;;
  "exec deploy/valkey -c valkey -- valkey-cli -n 10 --scan --pattern svp:gw:rl:register:*") printf 'svp:gw:rl:register:a\nsvp:gw:rl:register:b\n' ;;
  "exec deploy/valkey -c valkey -- valkey-cli -n 10 DEL "*) echo 1 ;;
  *) echo "fake kubectl: unexpected call: $args" >&2; exit 3 ;;
esac
EOF
cat >"$bin/helm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$FAKE_STATE/helm.log"
for a; do [ "\$a" != template ] || exec "$real_helm" "\$@"; done
EOF
for tool in k3d docker; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$FAKE_STATE/%s.log"\nexit 1\n' "$tool" >"$bin/$tool"
done
# sleep returns at once: the waits of the scripts poll fakes that answer the same every time.
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
# ffmpeg: the last argument is the output file.
printf '#!/usr/bin/env bash\nfor a; do :; done\nprintf fake-video >"$a"\n' >"$bin/ffmpeg"
chmod 755 "$bin"/*

# The fake curl of the release check: GHCR's token endpoint and an anonymous HEAD of a manifest, both 200.
ghcr_bin=$work/ghcr-bin
mkdir -p "$ghcr_bin"
cat >"$ghcr_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/curl.log"
case "$*" in
  *ghcr.io/token*) printf '{"token":"anonymous"}\n200' ;;
  *ghcr.io/v2/*) printf 200 ;;
  *) exit 7 ;;
esac
EOF
chmod 755 "$ghcr_bin/curl"

# new_state [NAMESPACE...]: an empty folder of logs; the namespaces that exist in the fake cluster.
new_state() {
  FAKE_STATE=$(mktemp -d "$work/state.XXXXXX")
  export FAKE_STATE
  : >"$FAKE_STATE/kubectl.log"
  : >"$FAKE_STATE/helm.log"
  : >"$FAKE_STATE/applied.yaml"
  printf '%s\n' "$@" >"$FAKE_STATE/namespaces"
}

# --- the fake secrets.
names=(SVP_PG_SUPERUSER_PASSWORD
  SVP_USER_MIGRATOR_DB_PASSWORD SVP_USER_APP_DB_PASSWORD SVP_VIDEO_MIGRATOR_DB_PASSWORD SVP_VIDEO_APP_DB_PASSWORD
  SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD SVP_ENGAGEMENT_APP_DB_PASSWORD SVP_FEED_MIGRATOR_DB_PASSWORD
  SVP_FEED_APP_DB_PASSWORD SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD
  SVP_S3_ROOT_PASSWORD SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY SVP_PG_BACKUP_S3_SECRET_KEY
  SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD
  SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD
  JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS SVP_GRAFANA_ADMIN_PASSWORD GLITCHTIP_SECRET_KEY
  GLITCHTIP_ADMIN_PASSWORD)
: >"$work/secrets"
fake=$work/code
mkdir -p "$fake"
{
  for n in "${names[@]}"; do
    v="fake-$(openssl rand -hex 12)"
    echo "$v" >>"$work/secrets"
    echo "$n=$v"
  done
  echo "GLITCHTIP_ADMIN_EMAIL=admin@svp.local"
  v=$(openssl rand -base64 32)
  echo "$v" >>"$work/secrets"
  echo "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=$v"
} >"$fake/.env"
env_pg_password=$(sed -n 's/^SVP_PG_SUPERUSER_PASSWORD=//p' "$fake/.env")
rds_password="rds-$(openssl rand -hex 12)"
FAKE_DSN="http://$(openssl rand -hex 16)@127.0.0.1:8000/1"
FAKE_TOKEN="token-$(openssl rand -hex 16)"
FAKE_SOURCEMAPS_TOKEN="maps-$(openssl rand -hex 16)"
export FAKE_DSN FAKE_TOKEN FAKE_SOURCEMAPS_TOKEN
printf '%s\n' "$rds_password" "${FAKE_DSN%@*}" "$FAKE_TOKEN" "$FAKE_SOURCEMAPS_TOKEN" >>"$work/secrets"

# leaks FILE: the secrets (or their base64) FILE holds, one line each; nothing when none.
leaks() {
  local v
  while IFS= read -r v; do
    if grep -qF -- "$v" "$1" || grep -qF -- "$(b64 "$v")" "$1"; then echo "${v:0:8}..."; fi
  done <"$work/secrets"
}
# no_leak NAME FILE: a case of its own, that the output FILE of NAME holds no secret.
no_leak() {
  local found
  found=$(leaks "$2")
  if [ -z "$found" ]; then ok "$1: no secret value in the output"; else fail "$1: the output holds secrets: $found"; fi
}
# source_value NAME KEY: the decoded value of KEY of the Secret NAME applied last in $FAKE_STATE/applied.yaml.
source_value() {
  awk -v name="$1" -v key="$2" '/^---/ { n = "" } $1 == "name:" { n = $2 }
    n == name && $1 == key ":" { gsub(/"/, "", $2); print $2 }' "$FAKE_STATE/applied.yaml" | tail -n 1 | base64 -d
}

# --- the throwaway checkout: deploy/ of this one, a stub of values-check.sh, committed.
cp -R "$repo/deploy" "$fake/deploy"
cat >"$fake/deploy/ci/values-check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/values-check.log"
EOF
chmod 755 "$fake/deploy/ci/values-check.sh"
g() { git -c user.name=test -c user.email=test@example.test -c commit.gpgsign=false "$@"; }
g -C "$fake" init -q && g -C "$fake" add -A deploy && g -C "$fake" commit -q -m fixture ||
  {
    echo "FAIL  commit the throwaway checkout" >&2
    exit 1
  }
chart_rev=$(git -C "$fake" rev-parse HEAD)

# --- the throwaway svp-gitops.
gitops=$work/gitops
mkdir -p "$gitops/argocd/apps/templates" "$gitops/base" "$gitops/envs/stg/images" "$gitops/platforms/eks" \
  "$gitops/platforms/k3d"
printf 'apiVersion: v2\nname: apps\nversion: 0.1.0\n' >"$gitops/argocd/apps/Chart.yaml"
echo 'env: ""' >"$gitops/argocd/apps/values.yaml"
jq -n '{components: [
  {name: "svp-cluster", namespace: "cert-manager", wave: 1, path: "deploy/helm/svp-cluster"},
  {name: "cloudnative-pg", namespace: "cnpg-system", wave: 2, repo: "https://cloudnative-pg.github.io/charts",
   chart: "cloudnative-pg", version: "0.0.1", platforms: ["k3d"]},
  {name: "svp-data", namespace: "svp-data", wave: 3, path: "deploy/helm/svp-data"},
  {name: "svp-observability", namespace: "svp-obs", wave: 5, path: "deploy/helm/svp-observability"}]}' \
  >"$gitops/argocd/apps/components.json"
# The root of the platform layer, reduced to what gitops.sh reads: Application svp-cluster with its values files and a
# valuesObject rendered on cluster, which replaces the platform file's namespaces (no cnpg-system, external-dns); an
# Application before it with other values, so the one named svp-cluster must be picked.
cat >"$gitops/argocd/apps/templates/applications.yaml" <<'EOF'
{{- if ne .Values.platform "eks" }}{{ fail "platform is not eks" }}{{ end }}
{{- $rds := required "cluster.rdsAddress is not set" .Values.cluster.rdsAddress }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svp-data
  namespace: argocd
spec:
  sources:
    - repoURL: {{ .Values.chartRepoURL }}
      path: deploy/helm/svp-data
      helm:
        valuesObject:
          platformNamespaces: [{name: wrong-application}]
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: svp-cluster
  namespace: argocd
spec:
  sources:
    - repoURL: {{ .Values.chartRepoURL }}
      path: deploy/helm/svp-cluster
      helm:
        releaseName: svp-cluster
        valueFiles:
          - $values/platforms/{{ .Values.platform }}/svp-cluster.yaml
          - $values/envs/{{ .Values.env }}/svp-cluster.yaml
        valuesObject:
          platformNamespaces:
            - name: argo-rollouts
            - name: keda
            - name: kyverno
            - name: {{ printf "external-dns-%s" (.Values.cluster.name | trimPrefix "svp-") | quote }}
    - repoURL: {{ .Values.repoURL | default "https://github.com/anhnvcoder/svp-gitops.git" }}
      targetRevision: {{ .Values.targetRevision | quote }}
      ref: values
EOF
printf 'platformNamespaces:\n  - name: cnpg-system\n  - name: keda\ns3:\n  mode: external\nstorageClass:\n  enabled: true\n' \
  >"$gitops/platforms/eks/svp-cluster.yaml"
echo '# Values of the platform k3d: none.' >"$gitops/platforms/k3d/README.md"
printf 'externalSecrets:\n  enabled: true\n  store: kubernetes\n  prefix: ""\n' >"$gitops/envs/stg/svp-cluster.yaml"
printf 'revision: %s\npodSecurityVersion: v1.35\ncollectorConfigSha256: %s\n' "$chart_rev" "$(printf '0%.0s' {1..64})" \
  >"$gitops/envs/stg/charts.yaml"
echo '{"name": "argocd", "namespace": "argocd", "repo": "https://argoproj.github.io/argo-helm", "chart": "argo-cd", "version": "0.0.1", "values": "base/argo-cd.yaml"}' \
  >"$gitops/argocd/bootstrap.json"
echo '{}' >"$gitops/base/argo-cd.yaml"
printf 'apiVersion: argoproj.io/v1alpha1\nkind: AppProject\nmetadata:\n  name: svp\n  namespace: argocd\n' \
  >"$gitops/argocd/project.yaml"
# shellcheck disable=SC2016 # read from lib.sh by bash, not expanded here
services=$(bash -c '. "$1/deploy/k8s/lib.sh" && echo "${svp_services[*]}"' _ "$fake")
for svc in $services; do
  prefix=ghcr.io/anhnvcoder/svp-backend/
  [ "$svc" != web ] || prefix=ghcr.io/anhnvcoder/svp-frontend/
  printf 'image:\n  repository: %s%s\n  tag: "%s"\n  digest: "sha256:%s"\n' "$prefix" "$svc" "$(openssl rand -hex 6)" \
    "$(openssl rand -hex 32)" >"$gitops/envs/stg/images/$svc.yaml"
done
g -C "$gitops" init -q && g -C "$gitops" add -A . && g -C "$gitops" commit -q -m fixture &&
  git -C "$gitops" remote add origin https://github.com/anhnvcoder/svp-gitops.git || {
  echo "FAIL  commit the throwaway svp-gitops" >&2
  exit 1
}
gitops_sha=$(git -C "$gitops" rev-parse HEAD)
export SVP_GITOPS_DIR=$gitops

# The cluster values: the example of the contract as JSON, as terraform output -json writes it.
yaml_values_json() {
  mkdir -p "$work/vj/templates"
  printf 'apiVersion: v2\nname: vj\nversion: 0.1.0\n' >"$work/vj/Chart.yaml"
  echo '# json {{ toJson .Values }}' >"$work/vj/templates/v.yaml"
  "$real_helm" template vj "$work/vj" --values "$1" | sed -n 's/^# json //p'
}
example=$repo/deploy/ci/cluster-values.example.yaml
yaml_values_json "$example" >"$work/cluster.json"
[ "$(jq -r .name "$work/cluster.json")" = svp-stg ] || {
  echo "FAIL  read $example" >&2
  exit 1
}

# The Applications the fake Argo CD reports: every one gitops.sh waits for on eks, ready.
apps_json() {
  jq -n '{items: ["svp-root", "svp-cluster", "svp-data", "svp-observability"] | map({metadata: {name: .},
    status: {sync: {status: "Synced"}, health: {status: "Healthy"}, operationState: {phase: "Succeeded"}}})}'
}

# gitops_run OUT [VAR=VALUE...]: deploy/k8s/gitops.sh of the throwaway checkout on context svp-stg, with the fake tools
# and the environment given, at most 120 s; output in OUT, exit status in $rc.
gitops_run() {
  local out=$1
  shift
  rc=0
  env PATH="$bin:$ghcr_bin:$PATH" SVP_KUBE_CONTEXT=svp-stg GITOPS_REV="$gitops_sha" "$@" \
    perl -e 'alarm 120; exec @ARGV' "$fake/deploy/k8s/gitops.sh" >"$out" 2>&1 || rc=$?
}
# no_cluster_call NAME: kubectl was not run, nor helm but for templates, nor k3d or docker.
no_cluster_call() {
  if [ -s "$FAKE_STATE/kubectl.log" ] || grep -vq '^template ' "$FAKE_STATE/helm.log" ||
    [ -s "$FAKE_STATE/k3d.log" ] || [ -s "$FAKE_STATE/docker.log" ]; then
    fail "$1: a cluster was called: $(cat "$FAKE_STATE/kubectl.log" "$FAKE_STATE/helm.log" | head -n 3 | paste -sd ';' -)"
  else
    ok "$1: no kubectl, helm (but templates), k3d or docker call"
  fi
}
# refused NAME OUT MESSAGE: the run failed with MESSAGE in its output.
refused() {
  if [ "$rc" != 0 ] && grep -qF -- "$3" "$2"; then
    ok "$1: refused ($3)"
  else
    fail "$1: exit $rc, want a failure with '$3':"$'\n'"$(sed 's/^/      /' "$2")"
  fi
}

# --- 1. deploy/k8s/lib.sh: the context.
# lib_run OUT CODE: CODE after sourcing lib.sh of the throwaway checkout, with the fake tools; status in $rc.
lib_run() {
  local out=$1
  shift
  rc=0
  # shellcheck disable=SC2016 # expanded by the inner bash
  env PATH="$bin:$PATH" bash -c '. "$0/deploy/k8s/lib.sh" && eval "$1"' "$fake" "$1" >"$out" 2>&1 || rc=$?
}
for bad in arn:aws:eks:ap-southeast-1:000000000000:cluster/svp-stg k3d-other '' ' svp-stg ' svp-dev; do
  new_state
  SVP_KUBE_CONTEXT=$bad lib_run "$work/out" 'kc get nodes'
  if [ "$rc" != 0 ] && grep -qF "SVP_KUBE_CONTEXT is $(printf '%q' "$bad")" "$work/out" && [ ! -s "$FAKE_STATE/kubectl.log" ]; then
    ok "lib.sh: SVP_KUBE_CONTEXT=$(printf '%q' "$bad") refused as it is sourced, naming it, before kubectl"
  else
    fail "lib.sh: SVP_KUBE_CONTEXT=$(printf '%q' "$bad"): exit $rc, kubectl '$(cat "$FAKE_STATE/kubectl.log")': $(cat "$work/out")"
  fi
done
new_state
(
  unset SVP_KUBE_CONTEXT
  lib_run "$work/out" 'kc get --raw /readyz && hc template x /nonexistent >/dev/null 2>&1; true'
)
if grep -qx -- '--context k3d-svp get --raw /readyz' "$FAKE_STATE/kubectl.log" &&
  grep -q -- '--kube-context k3d-svp' "$FAKE_STATE/helm.log"; then
  ok "lib.sh: SVP_KUBE_CONTEXT unset, kc and hc name k3d-svp"
else
  fail "lib.sh: SVP_KUBE_CONTEXT unset: kubectl '$(cat "$FAKE_STATE/kubectl.log")', helm '$(cat "$FAKE_STATE/helm.log")'"
fi
new_state
SVP_KUBE_CONTEXT=svp-stg lib_run "$work/out" 'kube_cloud_ok=1; kc get --raw /readyz && hc template x /nonexistent >/dev/null 2>&1; true'
if grep -qx -- '--context svp-stg get --raw /readyz' "$FAKE_STATE/kubectl.log" &&
  grep -q -- '--kube-context svp-stg' "$FAKE_STATE/helm.log"; then
  ok "lib.sh: SVP_KUBE_CONTEXT=svp-stg in a script written for it, kc and hc name svp-stg"
else
  fail "lib.sh: SVP_KUBE_CONTEXT=svp-stg: kubectl '$(cat "$FAKE_STATE/kubectl.log")', helm '$(cat "$FAKE_STATE/helm.log")'"
fi
new_state
SVP_KUBE_CONTEXT=svp-prd lib_run "$work/out" 'kc get --raw /readyz'
refused "lib.sh: kc on svp-prd in a script not written for a cloud cluster (the dev path, a drill)" "$work/out" \
  "context svp-prd is an EKS cluster, which this script does not run against"
no_cluster_call "lib.sh: kc on svp-prd in a script not written for it"
for fn in ensure_registry ensure_cluster export_ca 'k3d_ cluster list'; do
  new_state
  SVP_KUBE_CONTEXT=svp-stg lib_run "$work/out" "kube_cloud_ok=1; $fn"
  refused "lib.sh: ${fn%% *} on svp-stg" "$work/out" "for the local cluster k3d-svp only, not context svp-stg"
  no_cluster_call "lib.sh: ${fn%% *} on svp-stg"
done

# --- 2. deploy/k8s/gitops.sh on svp-stg: what stops it before any kubectl.
new_state
gitops_run "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "gitops.sh on svp-stg without CLUSTER_VALUES" "$work/out" "CLUSTER_VALUES is not set"
no_cluster_call "gitops.sh on svp-stg without CLUSTER_VALUES"
new_state
gitops_run "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" CLUSTER_VALUES="$work/none.json"
refused "gitops.sh with CLUSTER_VALUES not a file" "$work/out" "is not a file"
grep -v '^rdsAddress:' "$example" >"$work/missing.yaml"
new_state
gitops_run "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" CLUSTER_VALUES="$work/missing.yaml"
refused "gitops.sh with CLUSTER_VALUES missing a key of the contract" "$work/out" "rdsAddress is missing"
no_cluster_call "gitops.sh with CLUSTER_VALUES missing a key"
jq '.dbCidrs = "10.0.48.0/24" | .domain = ""' "$work/cluster.json" >"$work/kinds.json"
new_state
gitops_run "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" CLUSTER_VALUES="$work/kinds.json"
refused "gitops.sh with CLUSTER_VALUES of the wrong kinds" "$work/out" "dbCidrs is not a list of strings; domain is not a string"
no_cluster_call "gitops.sh with CLUSTER_VALUES of the wrong kinds"
jq '.name = "svp-prd"' "$work/cluster.json" >"$work/other.json"
new_state
gitops_run "$work/out" SVP_RDS_MASTER_PASSWORD="$rds_password" CLUSTER_VALUES="$work/other.json"
refused "gitops.sh with CLUSTER_VALUES of another cluster" "$work/out" "is of cluster 'svp-prd', not of context svp-stg"
no_cluster_call "gitops.sh with CLUSTER_VALUES of another cluster"
new_state
gitops_run "$work/out" CLUSTER_VALUES="$work/cluster.json"
refused "gitops.sh on svp-stg without SVP_RDS_MASTER_PASSWORD" "$work/out" "SVP_RDS_MASTER_PASSWORD is not set or empty"
no_cluster_call "gitops.sh on svp-stg without SVP_RDS_MASTER_PASSWORD"

# --- 3. deploy/k8s/gitops.sh on svp-stg: a run that passes.
new_state svp-data svp svp-obs svp-secrets
apps_json >"$FAKE_STATE/apps.json"
gitops_run "$work/gitops.out" SVP_RDS_MASTER_PASSWORD="$rds_password" CLUSTER_VALUES="$work/cluster.json"
if [ "$rc" = 0 ]; then
  ok "gitops.sh on svp-stg: the run passes"
else
  fail "gitops.sh on svp-stg: exit $rc:"$'\n'"$(sed 's/^/      /' "$work/gitops.out")"
fi
other=$(grep -v '^--context svp-stg ' "$FAKE_STATE/kubectl.log" || true)
if [ -s "$FAKE_STATE/kubectl.log" ] && [ -z "$other" ]; then
  ok "gitops.sh on svp-stg: every kubectl call names --context svp-stg ($(grep -c . "$FAKE_STATE/kubectl.log") calls)"
else
  fail "gitops.sh on svp-stg: kubectl calls on another context: $other"
fi
other=$(grep -v -e '^template values-json ' -e '^template yj ' -e '^template svp-root ' "$FAKE_STATE/helm.log" |
  grep -v -e '--kube-context svp-stg' || true)
if grep -q -- '--kube-context svp-stg' "$FAKE_STATE/helm.log" && [ -z "$other" ]; then
  ok "gitops.sh on svp-stg: every helm call of the cluster names --kube-context svp-stg, the others are local templates"
else
  fail "gitops.sh on svp-stg: helm calls without --kube-context svp-stg: $other"
fi
if [ ! -s "$FAKE_STATE/k3d.log" ] && [ ! -s "$FAKE_STATE/docker.log" ] && ! grep -q 'k3d-svp' "$FAKE_STATE/kubectl.log" "$FAKE_STATE/helm.log"; then
  ok "gitops.sh on svp-stg: no registry, no k3d cluster (no k3d or docker call, no context k3d-svp)"
else
  fail "gitops.sh on svp-stg: k3d '$(cat "$FAKE_STATE/k3d.log" 2>/dev/null)', docker '$(cat "$FAKE_STATE/docker.log" 2>/dev/null)'"
fi
if grep -q -- "--gitops .* $" "$FAKE_STATE/values-check.log" 2>/dev/null && grep -q 'ghcr.io/v2/' "$FAKE_STATE/curl.log"; then
  ok "gitops.sh on svp-stg: the release images were checked (GHCR, values-check.sh --gitops)"
else
  fail "gitops.sh on svp-stg: the release images were not checked"
fi
# The root as applied: the one document of kind Application in the applied manifests, JSON on one line.
root=$(grep '"kind":"Application"' "$FAKE_STATE/applied.yaml" | head -n 1 || true)
if [ -n "$root" ] && jq -e --arg sha "$gitops_sha" --slurpfile c "$work/cluster.json" '.spec.source.helm.valuesObject
    | .platform == "eks" and .env == "stg" and .nodeArch == "arm64" and .targetRevision == $sha and .cluster == $c[0]' \
  >/dev/null <<<"$root"; then
  ok "gitops.sh on svp-stg: root svp-root with platform eks, env stg, nodeArch arm64, the SHA checked and cluster from CLUSTER_VALUES"
else
  fail "gitops.sh on svp-stg: root as applied: ${root:-none}"
fi
namespaces=$(awk '/^kind: Namespace/ { ns = 1 } /^---/ { ns = 0 } ns && /^  name: / { print $2 }' "$FAKE_STATE/applied.yaml" |
  sort -u | paste -sd ' ' -)
want="argo-rollouts argocd external-dns-stg keda kyverno svp svp-data svp-edge svp-obs svp-secrets"
if [ "$namespaces" = "$want" ]; then
  ok "gitops.sh on svp-stg: namespaces of svp-cluster's values in the root's render, its valuesObject last ($namespaces; no cnpg-system)"
else
  fail "gitops.sh on svp-stg: namespaces '$namespaces', want '$want'"
fi
if [ "$(source_value pg-superuser SVP_PG_SUPERUSER_PASSWORD)" = "$rds_password" ] &&
  ! grep -qF "$(b64 "$env_pg_password")" "$FAKE_STATE/applied.yaml"; then
  ok "gitops.sh on svp-stg: source pg-superuser holds SVP_RDS_MASTER_PASSWORD, not the password of .env"
else
  fail "gitops.sh on svp-stg: source pg-superuser does not hold SVP_RDS_MASTER_PASSWORD alone"
fi
if ! grep -qE '^  name: s3-(root|users)$' "$FAKE_STATE/applied.yaml" && grep -qE '^  name: kafka-users$' "$FAKE_STATE/applied.yaml"; then
  ok "gitops.sh on svp-stg: s3.mode external in svp-cluster's values, so no source s3-root or s3-users"
else
  fail "gitops.sh on svp-stg: sources of the in-cluster object store written, or no sources at all"
fi
if [ "$(source_value glitchtip-runtime SENTRY_AUTH_TOKEN)" = "$FAKE_TOKEN" ] && grep -q 'GlitchTip.s DSN' "$work/gitops.out"; then
  ok "gitops.sh on svp-stg: glitchtip-init.sh filled source glitchtip-runtime"
else
  fail "gitops.sh on svp-stg: glitchtip-init.sh did not fill source glitchtip-runtime"
fi
if grep -q 'kubectl --context svp-stg -n argocd port-forward' "$work/gitops.out" && ! grep -q 'ca.crt' "$work/gitops.out"; then
  ok "gitops.sh on svp-stg: no CA exported, the Argo CD UI named with context svp-stg"
else
  fail "gitops.sh on svp-stg: the end of the run: $(tail -n 4 "$work/gitops.out")"
fi
no_leak "gitops.sh on svp-stg" "$work/gitops.out"

# --- 4. deploy/k8s/secrets.sh on its own.
# secrets_run OUT [VAR=VALUE...]: deploy/k8s/secrets.sh of the throwaway checkout; status in $rc.
secrets_run() {
  local out=$1
  shift
  rc=0
  env PATH="$bin:$PATH" "$@" "$fake/deploy/k8s/secrets.sh" >"$out" 2>&1 || rc=$?
}
new_state svp-data svp svp-obs svp-secrets
secrets_run "$work/out" SVP_KUBE_CONTEXT=svp-stg
refused "secrets.sh on svp-stg without SVP_RDS_MASTER_PASSWORD" "$work/out" "SVP_RDS_MASTER_PASSWORD is not set or empty"
no_cluster_call "secrets.sh on svp-stg without SVP_RDS_MASTER_PASSWORD"
new_state svp-data svp svp-obs
secrets_run "$work/out" SVP_KUBE_CONTEXT=svp-stg SVP_RDS_MASTER_PASSWORD="$rds_password"
refused "secrets.sh on svp-stg without namespace svp-secrets" "$work/out" "cluster svp-stg has no namespace svp-secrets"
if [ ! -s "$FAKE_STATE/applied.yaml" ]; then ok "secrets.sh on svp-stg without svp-secrets: nothing applied"; else fail "secrets.sh on svp-stg without svp-secrets: Secrets applied"; fi
new_state svp-data svp svp-obs svp-secrets
secrets_run "$work/secrets.out" SVP_KUBE_CONTEXT=svp-stg SVP_RDS_MASTER_PASSWORD="$rds_password" SVP_OBJECT_STORE=cluster
if [ "$rc" = 0 ] && grep -qE '^  name: s3-root$' "$FAKE_STATE/applied.yaml" &&
  [ "$(source_value pg-superuser SVP_PG_SUPERUSER_PASSWORD)" = "$rds_password" ] &&
  [ -z "$(grep -v '^--context svp-stg ' "$FAKE_STATE/kubectl.log")" ]; then
  ok "secrets.sh on svp-stg, SVP_OBJECT_STORE=cluster: the store's sources too, pg-superuser from SVP_RDS_MASTER_PASSWORD, context svp-stg"
else
  fail "secrets.sh on svp-stg, SVP_OBJECT_STORE=cluster: exit $rc: $(cat "$work/secrets.out")"
fi
no_leak "secrets.sh on svp-stg" "$work/secrets.out"
new_state svp-data svp svp-obs svp-secrets
secrets_run "$work/k3d.out" SVP_RDS_MASTER_PASSWORD="$rds_password"
if [ "$rc" = 0 ] && grep -qx 'ok    source Secrets of svp-secrets applied from .env: pg-superuser, pg-roles, s3-root, s3-users, kafka-admin, kafka-users, jwt-signing, jwt-verify, web, obs' "$work/k3d.out" &&
  [ "$(source_value pg-superuser SVP_PG_SUPERUSER_PASSWORD)" = "$env_pg_password" ] &&
  [ -z "$(grep -v '^--context k3d-svp ' "$FAKE_STATE/kubectl.log")" ]; then
  ok "secrets.sh on k3d-svp as before: pg-superuser from .env (SVP_RDS_MASTER_PASSWORD ignored), the store's sources, context k3d-svp"
else
  fail "secrets.sh on k3d-svp: exit $rc: $(cat "$work/k3d.out")"
fi
no_leak "secrets.sh on k3d-svp" "$work/k3d.out"

# --- 5. reset_register_limit of deploy/compose/lib.sh.
# rl_run OUT [VAR=VALUE...]: sources deploy/compose/lib.sh of the throwaway checkout; status in $rc.
rl_run() {
  local out=$1
  shift
  rc=0
  env PATH="$bin:$PATH" "$@" bash -c '. "$0/deploy/compose/lib.sh"' "$fake" >"$out" 2>&1 || rc=$?
}
new_state
rl_run "$work/out" SVP_STACK=eks SVP_KUBE_CONTEXT=svp-stg
if [ "$rc" = 0 ] && grep -q '2 keys deleted in Valkey db 10 of cluster svp-stg' "$work/out" &&
  [ "$(grep -c '^--context svp-stg -n svp-data exec deploy/valkey' "$FAKE_STATE/kubectl.log")" = 3 ]; then
  ok "compose/lib.sh SVP_STACK=eks: SCAN and DEL in the Valkey of context svp-stg"
else
  fail "compose/lib.sh SVP_STACK=eks: exit $rc, kubectl '$(cat "$FAKE_STATE/kubectl.log")': $(cat "$work/out")"
fi
for bad in k3d-svp '' svp-dev arn:aws:eks:ap-southeast-1:000000000000:cluster/svp-stg; do
  new_state
  rl_run "$work/out" SVP_STACK=eks SVP_KUBE_CONTEXT="$bad"
  refused "compose/lib.sh SVP_STACK=eks, SVP_KUBE_CONTEXT='$bad'" "$work/out" "got '$bad'"
  no_cluster_call "compose/lib.sh SVP_STACK=eks, SVP_KUBE_CONTEXT='$bad'"
done
new_state
rl_run "$work/out" SVP_STACK=k3d SVP_KUBE_CONTEXT=svp-stg
if [ "$rc" = 0 ] && [ -z "$(grep -v '^--context k3d-svp ' "$FAKE_STATE/kubectl.log")" ]; then
  ok "compose/lib.sh SVP_STACK=k3d: still context k3d-svp"
else
  fail "compose/lib.sh SVP_STACK=k3d: kubectl '$(cat "$FAKE_STATE/kubectl.log")'"
fi

# --- 6. deploy/k8s/eks-seed.sh against a fake API. FAKE_EXPLORE is how many items explore lists.
api_bin=$work/api-bin
mkdir -p "$api_bin"
cat >"$api_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/stdout fmt= method=GET url= cfg=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -w) fmt=$2; shift ;;
    -X) method=$2; shift ;;
    -K) cfg=$2; method=POST; shift ;;
    -H | --data-binary | --max-time) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
[ -z "$cfg" ] || url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg")
printf '%s %s\n' "$method" "$url" >>"$FAKE_STATE/curl.log"
code=200 body=
case "$method $url" in
  "GET "*/readyz) ;;
  "POST "*/auth/register) code=201 body="{\"user_id\":\"$(openssl rand -hex 8)\"}" ;;
  "POST "*/auth/login) body='{"access_token":"fake"}' ;;
  "POST "*/videos/*/complete) code=202 body='{"status":"PROCESSING"}' ;;
  "POST "*/videos) code=201 body="{\"video_id\":\"$(openssl rand -hex 8)\",\"upload_url\":\"https://uploads.stg.svp.example/\",\"form_fields\":{\"key\":\"uploads/x\",\"policy\":\"p\"}}" ;;
  "POST https://uploads.stg.svp.example/") code=204 ;;
  "GET "*/videos/*) body='{"status":"READY"}' ;;
  "GET "*/feed/explore*) body=$(jq -cn --argjson n "$FAKE_EXPLORE" '{items: [range($n) | {video_id: "v\(.)"}]}') ;;
  *) code=404 ;;
esac
printf '%s' "$body" >"$out"
fmt=${fmt//%\{http_code\}/$code}
printf '%s' "${fmt//%\{content_type\}/application/json}"
EOF
chmod 755 "$api_bin/curl"
# seed_run OUT EXPLORE: deploy/k8s/eks-seed.sh on context svp-stg, explore listing EXPLORE videos; status in $rc.
seed_run() {
  rc=0
  env PATH="$bin:$api_bin:$PATH" SVP_STACK=eks SVP_KUBE_CONTEXT=svp-stg FAKE_EXPLORE="$2" \
    perl -e 'alarm 120; exec @ARGV' "$fake/deploy/k8s/eks-seed.sh" https://api.stg.svp.example >"$1" 2>&1 || rc=$?
}
new_state
seed_run "$work/seed.out" 32
other=$(grep -v -e ' https://api\.stg\.svp\.example/' -e '^POST https://uploads\.stg\.svp\.example/$' "$FAKE_STATE/curl.log" || true)
if [ "$rc" = 0 ] && grep -q '32 videos READY' "$work/seed.out" && grep -q 'holds 32 READY videos' "$work/seed.out" &&
  [ "$(grep -c '^POST https://uploads' "$FAKE_STATE/curl.log")" = 32 ] && [ -z "$other" ]; then
  ok "eks-seed.sh: 4 users, 32 videos uploaded, completed and READY, explore 32, every request to https://api.stg.svp.example or the form"
else
  fail "eks-seed.sh: exit $rc, other requests '$other':"$'\n'"$(sed 's/^/      /' "$work/seed.out")"
fi
if [ -z "$(grep -v '^--context svp-stg ' "$FAKE_STATE/kubectl.log")" ] && grep -q 'register rate limit reset' "$work/seed.out"; then
  ok "eks-seed.sh: register rate limit reset in the Valkey of context svp-stg"
else
  fail "eks-seed.sh: kubectl '$(cat "$FAKE_STATE/kubectl.log")'"
fi
new_state
seed_run "$work/out" 29
refused "eks-seed.sh with 29 videos in explore" "$work/out" "GET /feed/explore holds at least 30 READY videos (status 200, 29)"
new_state
rc=0
env PATH="$bin:$api_bin:$PATH" SVP_KUBE_CONTEXT=svp-stg "$fake/deploy/k8s/eks-seed.sh" https://api.stg.svp.example \
  >"$work/out" 2>&1 || rc=$?
refused "eks-seed.sh without SVP_STACK=eks" "$work/out" "SVP_STACK=eks is not set"
no_cluster_call "eks-seed.sh without SVP_STACK=eks"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures case(s) of deploy/k8s/eks-context-test.sh" >&2
  exit 1
fi
echo "ok    deploy/k8s/eks-context-test.sh: every case"
