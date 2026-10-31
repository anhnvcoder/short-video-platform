#!/usr/bin/env bash
# The GitOps path: a new cluster svp on which Argo CD builds everything from GitHub: the deployment configuration from
# svp-gitops (root chart argocd/apps, base/, envs/stg/), the charts of this repository (deploy/helm/*) at the commit
# envs/stg/charts.yaml there pins. This script installs only what git cannot hold or what must exist before Argo CD:
#   1. the release images, before anything is created:
#      image.repository and image.digest of the seven files envs/stg/images/ of svp-gitops at the commit the cluster is
#      built at, which the promote pull requests write (one per release source); each must be a release of
#      <imagePrefix><service> of a release source of chart svp-policy that publishes that service
#      (deploy/helm/svp-policy/files/sources.json: ghcr.io/anhnvcoder/short-video-platform/ for every service of this
#      repository, ghcr.io/anhnvcoder/svp-web/ for web) that GHCR serves to an anonymous pull (the nodes pull without
#      credentials), signed by images.yml on main of that source's repository, with a vuln attestation that is clean
#      and at most 48 hours old (Kyverno refuses new pods at 72), and with a build provenance attestation when chart
#      svp-policy checks provenance in stg at that revision (its values at the commit of envs/stg/charts.yaml, then
#      envs/stg/svp-policy.yaml: deploy/ci/values-check.sh --gitops);
#   2. the registry and the cluster (as `make k8s-up`); nothing is built here, the images come from GHCR;
#   3. the Secrets from .env (deploy/k8s/secrets.sh), which never go to git: with externalSecrets of chart svp-cluster
#      on in envs/stg (every revision of svp-gitops), only their source, the Secrets of namespace svp-secrets, from
#      which External Secrets Operator (component external-secrets) builds every Secret once Argo CD has installed it;
#   4. Argo CD (argocd/bootstrap.json: chart, version and values file base/argo-cd.yaml) in namespace argocd with Pod
#      Security "restricted", AppProject svp and the emptied AppProject default (argocd/project.yaml) and root
#      Application svp-root (chart argocd/apps at that same commit, told the architecture of the nodes, the
#      environment, stg: this cluster runs as staging, and, when that commit has the platform layer platforms/, the
#      platform, k3d). No repository Secret: both repositories are public and Argo CD
#      reads them over HTTPS without credentials, so this path holds no key or token; a repository that turned private
#      again would need a read-only credential here;
#   5. a bounded wait until every Application is Synced and Healthy with its last sync Succeeded, with GlitchTip's DSN
#      put into Secret svp/sentry once GlitchTip is up (deploy/k8s/glitchtip-init.sh), so the services report errors
#      on this path too. An error Argo CD keeps reporting for 180 s stops the wait early;
#   6. with GITOPS_REV a branch, only then the root follows the branch (follow_branch below), so that the cluster takes
#      every later release as staging does.
# On an EKS cluster (make eks-gitops-up: SVP_KUBE_CONTEXT svp-stg or svp-prd, the alias of a cluster the infrastructure
# repository has made) the same steps run but 2 and 6: the cluster exists already, and it stays at the commit checked,
# whatever GITOPS_REV names (a later release reaches it by another run). The root gets platform eks, and value cluster,
# the map of CLUSTER_VALUES (the infrastructure repository's output cluster_values, as JSON or YAML), which must hold
# every key of deploy/ci/cluster-values.example.yaml, each of the same kind, before any kubectl call. The namespaces of
# step 3 then carry the values Argo CD will give chart svp-cluster: those of its Application in a render of the root
# with these values (its values files, in their order, then its valuesObject), not a guess of them; and step 3 writes
# the source Secrets of the object store only when those values keep it in the cluster (s3.mode). No CA is exported:
# the certificates there are public ones.
# The release images, Argo CD's install and the list of Applications come from git at that one commit, never from a
# working tree, and Argo CD builds the cluster at that commit too, not at the branch: what this script checks is what
# Argo CD deploys, even when a release reaches the branch meanwhile (that release would go out as a canary, which no
# traffic promotes while the cluster is being built, and the restarts of step 5 wait for Rollouts to be Healthy).
#
# Environment (set by `make k8s-gitops-up`):
#   GITOPS_REV         the revision of svp-gitops: a branch of the clone's origin (default main; read from
#                      refs/remotes/origin/<branch> as fetched last, without a fetch), whose commit the cluster is built
#                      at, then follows the branch (Argo CD gets refs/heads/<branch>); or a full commit SHA of the
#                      clone, at which the cluster is built and stays.
#   SVP_GITOPS_DIR     the clone of svp-gitops (deploy/k8s/lib.sh, gitops_dir; CI's make gitops-clone sets it).
#   SVP_ATTEST_MAX_AGE drills only (never in .env): a shorter limit than 48h for the age of the vuln attestations.
#   SVP_KUBE_CONTEXT   unset: the local cluster k3d-svp; svp-stg or svp-prd: that EKS cluster (deploy/k8s/lib.sh).
#   CLUSTER_VALUES     EKS only: the file of the root's value cluster.
#
# Secrets live outside git, so a changed .env reaches this cluster by hand: `make k8s-secrets` (which, with External
# Secrets, writes the source in svp-secrets and has every ExternalSecret built again from it), then a sync of
# Application svp-data, whose init Jobs set the new passwords in Postgres, the object store and Redpanda
# (kubectl --context k3d-svp -n argocd patch applications.argoproj.io svp-data --type merge
#  -p '{"operation":{"sync":{}}}'), then `kubectl --context k3d-svp -n <namespace> rollout restart deployment/<name>` of
# each workload whose Secret changed: five of the services, kps-grafana, glitchtip, keda-operator. The gateway and the
# web client (Secret web-env) are Argo Rollouts Rollouts: a restart that stamps the pod template is a new revision,
# hence a canary, so each restarts through spec.restartAt instead (its pods are evicted one at a time, the template
# unchanged):
#   for r in gateway web; do kubectl --context k3d-svp -n svp patch rollout "$r" --type merge \
#     -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"; done
# `make k8s-up` does the same on the dev path and refuses a cluster Argo CD manages.
#
# deploy/k8s/gitops.sh follow BRANCH: step 6 alone, on the cluster this script made: the root follows refs/heads/BRANCH
# of svp-gitops from then on. For a cluster built at a commit (the verification run builds at one, and follows main
# only once its checks are over).
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# ci_dispatch_hint: the command that starts a CI run, for the message when the releases need a fresh attestation.
# shellcheck source=deploy/ci/platform.sh
. "$repo_root/deploy/ci/platform.sh"
# Written for a cloud cluster too: kc and hc may reach the EKS cluster SVP_KUBE_CONTEXT names (deploy/k8s/lib.sh).
kube_cloud_ok=1

# repoURL and chartRepoURL of argocd/apps/values.yaml of svp-gitops, both in sourceRepos of AppProject svp.
chart_repo_url=https://github.com/anhnvcoder/short-video-platform.git
rev=${GITOPS_REV:-main}

command -v jq >/dev/null || fail "jq is not installed (brew install jq): it reads components.json and Argo CD's status"

# follow_branch BRANCH: points root svp-root at refs/heads/BRANCH of svp-gitops (Argo CD gets the full name: a short one
# may resolve to a tag of that name), for its own source and for the values source of every Application it makes, and
# waits up to 180 s for Argo CD to compare it there. When the branch is still at the commit the root ran (the
# cluster's), nothing is rolled out: the children get the new name with the same commit, so only the root syncs, and
# the wait goes on until it is Synced. When the branch has moved, Argo CD now deploys its newer commit as any release
# that reaches the branch, which this says on a line of its own with both full commits (the verification run reads
# them) and does not wait for: a gateway or web that changes goes out as a canary, which promotes only under traffic.
follow_branch() {
  local target=refs/heads/$1 app=applications.argoproj.io/svp-root from now patch
  git check-ref-format "$target" || fail "'$1' is not a branch name"
  from=$(kc -n argocd get "$app" -o jsonpath='{.status.sync.revision}') || fail "read Application argocd/svp-root"
  patch=$(jq -cn --arg t "$target" '{spec: {source: {targetRevision: $t, helm: {valuesObject: {targetRevision: $t}}}}}')
  kc -n argocd patch "$app" --type merge -p "$patch" >/dev/null || fail "point Application svp-root at $target"
  wait_until 180 "Application svp-root compared at $target of svp-gitops" \
    test_output "$target" kc -n argocd get "$app" -o jsonpath='{.status.sync.comparedTo.source.targetRevision}'
  now=$(kc -n argocd get "$app" -o jsonpath='{.status.sync.revision}') || fail "read Application argocd/svp-root"
  if [ "$now" = "$from" ]; then
    wait_until 180 "Application svp-root Synced at $target" \
      test_output Synced kc -n argocd get "$app" -o jsonpath='{.status.sync.status}'
    ok "Application svp-root follows $target of svp-gitops, still at ${now:0:12}: nothing new to roll out"
  else
    echo "note  Application svp-root follows $target of svp-gitops, which moved from $from (the commit the cluster runs) to $now: Argo CD deploys it now, a release like any other; a changed gateway or web goes out as a canary, whose analysis promotes it only under traffic (make k8s-traffic-start)"
  fi
}

if [ "${1:-}" = follow ]; then
  [ $# = 2 ] && [ -n "$2" ] || fail "usage: deploy/k8s/gitops.sh follow BRANCH"
  kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1 ||
    fail "cluster svp has no Application argocd/svp-root: it was not made by make k8s-gitops-up"
  follow_branch "$2"
  exit 0
fi
[ $# = 0 ] || fail "usage: deploy/k8s/gitops.sh, or deploy/k8s/gitops.sh follow BRANCH"

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT

# values_json FILE...: prints, on one line of JSON, the values helm makes of the values files FILE... (YAML or JSON)
# merged in that order, later ones winning, maps merged and lists replaced: how Helm reads the values of a chart, the
# values files and valuesObject of an Application among them. A chart of its own, which renders nothing else; no
# cluster is asked. Fails on a file that is no YAML map.
values_json() {
  local chart=$work/values-json f args=()
  if [ ! -d "$chart" ]; then
    mkdir -p "$chart/templates" &&
      printf 'apiVersion: v2\nname: values-json\nversion: 0.1.0\n' >"$chart/Chart.yaml" &&
      echo '# json {{ toJson .Values }}' >"$chart/templates/values.yaml" || return 1
  fi
  for f in "$@"; do args+=(--values "$f"); done
  helm template values-json "$chart" ${args[@]+"${args[@]}"} | sed -n 's/^# json //p'
}

# On EKS, the root's value cluster first: a file that misses a key of the contract would deploy charts whose templates
# fail on it, or worse, render an empty address. Nothing has asked the cluster anything yet.
cluster_json=
if cloud_context; then
  [ -n "${CLUSTER_VALUES:-}" ] ||
    fail "CLUSTER_VALUES is not set: the file of the root's value cluster (terraform output -json cluster_values of the infrastructure repository) for context $kube_context"
  [ -f "$CLUSTER_VALUES" ] || fail "CLUSTER_VALUES=$CLUSTER_VALUES is not a file"
  contract=$(values_json "$repo_root/deploy/ci/cluster-values.example.yaml") && [ -n "$contract" ] ||
    fail "read the keys of the contract in deploy/ci/cluster-values.example.yaml"
  cluster_json=$(values_json "$CLUSTER_VALUES" 2>"$work/err") && [ -n "$cluster_json" ] ||
    fail "CLUSTER_VALUES=$CLUSTER_VALUES is no YAML or JSON map: $(grep -v '^$' "$work/err" | head -n 3 | paste -sd ' ' -)"
  # Each key of the contract with a value of its kind in the example: a string, or a list of strings, never empty.
  problems=$(jq -rn --argjson want "$contract" --argjson got "$cluster_json" '
    $want | to_entries[] | .key as $k | (.value | type) as $kind | $got[$k] as $v
    | if $v == null then "\($k) is missing"
      elif $kind == "array" then
        (if ($v | type) != "array" or ($v | length) == 0 or any($v[]; type != "string" or . == "")
         then "\($k) is not a list of strings" else empty end)
      elif ($v | type) != "string" or $v == "" then "\($k) is not a string"
      else empty end') || fail "compare CLUSTER_VALUES=$CLUSTER_VALUES with the contract"
  [ -z "$problems" ] ||
    fail "CLUSTER_VALUES=$CLUSTER_VALUES does not hold the root's value cluster (keys of deploy/ci/cluster-values.example.yaml): $(paste -sd ';' - <<<"$problems" | sed 's/;/; /g'); nothing was created"
  [ "$(jq -r .name <<<"$cluster_json")" = "$kube_context" ] ||
    fail "CLUSTER_VALUES=$CLUSTER_VALUES is of cluster '$(jq -r .name <<<"$cluster_json")', not of context $kube_context: the values of one cluster on another; nothing was created"
  ok "CLUSTER_VALUES: every key of the contract for cluster $kube_context"
  # The master password of the managed Postgres, for the source Secret pg-superuser (deploy/k8s/secrets.sh, step 3):
  # checked now, so a missing one stops the run before anything is created, and kept out of the environment of every
  # program but that script.
  [ -n "${SVP_RDS_MASTER_PASSWORD:-}" ] ||
    fail "SVP_RDS_MASTER_PASSWORD is not set or empty: the master password of the managed Postgres of cluster $kube_context, which the session's script reads from AWS; nothing was created"
  rds_master_password=$SVP_RDS_MASTER_PASSWORD
  unset SVP_RDS_MASTER_PASSWORD
fi

gitops=$(gitops_dir) || exit 1

# --- the revision of svp-gitops and its release images, before anything is created.
if sha=$(git -C "$gitops" rev-parse --verify --quiet "refs/remotes/origin/$rev^{commit}"); then
  if cloud_context; then
    branch=
    echo "revision: origin/$rev of svp-gitops = $sha (as last fetched in $gitops; this script does not fetch): the cluster is built at this commit and stays at it (an EKS cluster follows no branch: a later release reaches it by another run)"
  else
    branch=$rev
    echo "revision: origin/$rev of svp-gitops = $sha (as last fetched in $gitops; this script does not fetch): the cluster is built at this commit, then follows refs/heads/$rev"
  fi
elif [[ $rev =~ ^[0-9a-f]{40}$ ]] && sha=$(git -C "$gitops" rev-parse --verify --quiet "$rev^{commit}"); then
  branch=
  echo "revision: commit $sha of svp-gitops: the cluster is built at this commit and stays at it"
else
  fail "GITOPS_REV=$rev is neither a branch of origin (refs/remotes/origin/$rev) nor a full commit SHA of the clone $gitops"
fi
# at FILE: prints FILE of svp-gitops at the revision.
at() { git -C "$gitops" show "$sha:$1"; }
# The environment the root hands to chart argocd/apps (value env). Always stg: a lab cluster only ever runs as
# staging, and prd is rendered by the checks alone, so there is nothing to choose.
env=stg
# Only staging runs on EKS so far: a prd cluster would get the overlay, digests and secret store of staging here.
[ "$kube_context" != svp-prd ] || fail "context svp-prd: this script builds staging only; prd on EKS has a path of its own"
# The platform it hands too (value platform), when the revision has the platform layer platforms/: k3d, the platform of
# this cluster. A revision from before that layer knows no platform, and its root gets none.
# On EKS, eks, which only a revision with the layer knows.
platform=
if cloud_context; then
  git -C "$gitops" cat-file -e "$sha:platforms/eks" 2>/dev/null ||
    fail "${sha:0:12} of svp-gitops has no platforms/eks, so Argo CD could not build $env on EKS from it; nothing was created"
  platform=eks
elif git -C "$gitops" cat-file -e "$sha:platforms" 2>/dev/null; then
  platform=k3d
fi
for f in argocd/apps/Chart.yaml argocd/apps/components.json argocd/project.yaml argocd/bootstrap.json \
  "envs/$env/charts.yaml"; do
  git -C "$gitops" cat-file -e "$sha:$f" 2>/dev/null ||
    fail "${sha:0:12} of svp-gitops has no $f, so Argo CD could not build $env from it; nothing was created"
done
# The commit of this repository whose charts stg runs; the namespaces below are rendered from its chart svp-cluster.
chart_rev=$(at "envs/$env/charts.yaml" | sed -n 's/^revision: *//p')
[[ $chart_rev =~ ^[0-9a-f]{40}$ ]] ||
  fail "envs/$env/charts.yaml at ${sha:0:12} of svp-gitops: revision is '$chart_rev', not a full commit of this repository"
git -C "$repo_root" cat-file -e "$chart_rev^{commit}" 2>/dev/null ||
  fail "envs/$env/charts.yaml at ${sha:0:12} of svp-gitops pins commit ${chart_rev:0:12} of this repository, which this clone does not hold: git fetch origin, and run again"
echo "env: $env${platform:+ on platform $platform} (overlays and release images of envs/$env, charts of this repository at ${chart_rev:0:12})"

# Every service is checked before the script stops, so one run names every release that is missing. release_image
# (deploy/k8s/lib.sh) reads the image file from git and asks GHCR; deploy/ci/values-check.sh --gitops then checks each
# release's signature and vuln attestation anonymously, with the pinned cosign image COSIGN_IMAGE when cosign is not
# installed, and its build provenance when chart svp-policy checks it in this environment: on a copy of envs/$env at the
# revision alone, so the releases of the other environments are not checked here.
unready=
for svc in "${svp_services[@]}"; do
  file="envs/$env/images/$svc.yaml"
  if ! content=$(at "$file" 2>/dev/null); then
    echo "FAIL  $svc: $file is missing at ${sha:0:12} of svp-gitops" >&2
    unready=1
  elif ! release_image "$svc" "$file at ${sha:0:12} of svp-gitops" <<<"$content" >/dev/null; then
    unready=1
  fi
done
[ -z "$unready" ] ||
  fail "the release images at ${sha:0:12} of svp-gitops are not ready for the GitOps path (above); nothing was created"
mkdir -p "$work/release" &&
  git -C "$gitops" archive "$sha" "envs/$env" | tar -x -C "$work/release" ||
  fail "unpack envs/$env of ${sha:0:12} of svp-gitops with git archive"
if ! "$repo_root/deploy/ci/values-check.sh" --gitops "$work/release" ""; then
  refresh=$(ci_dispatch_hint images.yml main rescan=true) || exit 1
  fail "a release at ${sha:0:12} of svp-gitops is not signed, its vuln attestation is not clean and fresh, or the provenance the policy requires is missing or wrong (above); nothing was created. Refresh the vuln attestations of the releases: $refresh, then run this again once that run is green (a missing provenance needs a new release instead, as named above)"
fi
ok "release images at ${sha:0:12} of svp-gitops: GHCR serves all seven anonymously, each signed by its release source with a fresh, clean vuln attestation"
# The Applications to wait for: the root and one per component of components.json at the revision, the copy the root
# renders, that runs on the platform (no platforms in components.json: every platform).
want_apps=$(at argocd/apps/components.json | jq -r --arg p "$platform" \
  '.components[] | select($p == "" or (has("platforms") | not) or (.platforms | index($p)) != null) | .name') &&
  [ -n "$want_apps" ] ||
  fail "read the component names of argocd/apps/components.json at ${sha:0:12} of svp-gitops"
want_apps=$(printf 'svp-root\n%s\n' "$want_apps")

if cloud_context; then
  # --- the EKS cluster, made by the infrastructure repository: only reached here.
  kc get --raw /readyz >/dev/null 2>&1 ||
    fail "cluster $kube_context is not reachable: add it to the kubeconfig under that name (the command of output update_kubeconfig of the infrastructure repository), with the AWS profile of the session"
  ok "cluster $kube_context reachable"
else
  # --- a new cluster only: the dev path's releases (Helm) and Argo CD's would fight over the same objects.
  if k3d_ cluster get svp >/dev/null 2>&1; then
    fail "cluster svp already exists; the GitOps path starts from a new cluster: run make k8s-down first"
  fi
  # The registry stays although nothing is pushed to it on this path: deploy/k8s/k3d.yaml, shared by both paths, names
  # it as the nodes' registry, and the cluster cannot be created without it.
  ensure_registry
  ensure_cluster
fi

# The nodes' architecture, which the root hands to chart argocd/apps (value nodeArch): Argo Rollouts' traffic
# router plugin is a native binary, and a component with archValues in components.json gets the values file of that
# architecture (argo-rollouts-amd64.yaml on a Linux x86_64 host such as a CI runner). The first node's, and every
# other node must run the same: one plugin binary serves the controller wherever it is scheduled.
node_archs=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}') ||
  fail "read the architecture of the nodes of svp"
node_arch=$(head -n 1 <<<"$node_archs")
[ -z "$(grep -vxF -- "$node_arch" <<<"$node_archs")" ] ||
  fail "the nodes of svp run different architectures ($(sort -u <<<"$node_archs" | paste -sd ' ' -)): Argo Rollouts gets one plugin binary, built for one of them"
case $node_arch in
  amd64 | arm64) ok "nodes run $node_arch: the root Application gets nodeArch=$node_arch" ;;
  *) fail "nodes of svp run '$node_arch': the release images and the plugin of Argo Rollouts exist for amd64 and arm64 only" ;;
esac

# The root Application, applied in step 4 below: it reads commit $sha of svp-gitops, and hands the same commit to
# every Application it makes for its values files (value targetRevision of chart argocd/apps), so the releases checked
# above are the ones deployed, whatever reaches the branch meanwhile; it follows the branch only once the cluster is
# built (follow_branch, at the end). argocd_root_app (lib.sh) writes the revision and the environment as strings
# whatever they look like; the nodes' architecture and the platform (a revision with platforms/ only) join them in the
# root's values, strings too, and on EKS the map cluster as CLUSTER_VALUES holds it.
root_app=$(argocd_root_app "$gitops_url" "$sha" "$env" "$chart_repo_url" |
  jq -c --arg arch "$node_arch" --arg platform "$platform" --argjson cluster "${cluster_json:-null}" \
    '.spec.source.helm.valuesObject.nodeArch = $arch
    | if $platform != "" then .spec.source.helm.valuesObject.platform = $platform else . end
    | if $cluster != null then .spec.source.helm.valuesObject.cluster = $cluster else . end') ||
  fail "write Application svp-root"

# --- the Secrets. Chart svp-cluster (wave 1) owns the project's namespaces, but two things need them earlier: the
# Secrets, before the first pod that reads one (wave 2), and Envoy Gateway (wave 0), which binds a Role in each
# namespace it watches (base/envoy-gateway.yaml of svp-gitops) and cannot sync while one is missing. So the namespaces
# of svp-cluster's values are made here from its own template, with the same Pod Security labels, as
# deploy/k8s/install.sh does; Argo CD's apply of svp-cluster then finds them as they are. The chart is the one stg runs,
# at the commit of envs/stg/charts.yaml, unpacked with git archive (neither the working tree nor the index is read), so
# the namespaces match the Envoy Gateway values Argo CD deploys. The values of the platform and the overlay of the
# environment for svp-cluster, when the revision has them, are read too, in the order Argo CD reads them: with
# externalSecrets on, the overlay adds namespace svp-secrets, which deploy/k8s/secrets.sh then fills with the source of
# the Secrets.
cluster_chart=deploy/helm/svp-cluster
cluster_overlay=envs/$env/svp-cluster.yaml
git -C "$repo_root" cat-file -e "$chart_rev:$cluster_chart/Chart.yaml" 2>/dev/null ||
  fail "commit ${chart_rev:0:12} of this repository (envs/$env/charts.yaml) has no $cluster_chart"
mkdir -p "$work/charts" && git -C "$repo_root" archive "$chart_rev" "$cluster_chart" | tar -x -C "$work/charts" ||
  fail "unpack $cluster_chart of ${chart_rev:0:12} with git archive"
overlay_args=()
object_store=
if cloud_context; then
  # On EKS, the values of svp-cluster are those of its Application in a render of the root with the values the root
  # gets above, read as Argo CD reads them: the values files of its source with helm ($values/<path>, in svp-gitops at
  # $sha), in their order, then its valuesObject (the render of platforms/eks/svp-cluster.values.tpl on cluster), which
  # wins. Every namespace of the chart's values is made, the platforms' too: the platform layer chooses them (no
  # cnpg-system without CloudNativePG), and those of components before svp-cluster's wave get their Pod Security
  # labels before their first pod.
  mkdir -p "$work/gitops" && git -C "$gitops" archive "$sha" | tar -x -C "$work/gitops" ||
    fail "unpack ${sha:0:12} of svp-gitops with git archive"
  jq '.spec.source.helm.valuesObject' <<<"$root_app" >"$work/root-values.json" || fail "write the root's values"
  helm template svp-root "$work/gitops/argocd/apps" --namespace argocd --values "$work/root-values.json" \
    >"$work/root.yaml" 2>"$work/err" || {
    grep -v 'found symbolic link in path' "$work/err" >&2 || true
    fail "render the root chart argocd/apps at ${sha:0:12} of svp-gitops for $env on $platform with CLUSTER_VALUES"
  }
  # Each YAML document of the render as one line of JSON, read by Helm itself (fromYaml), as the check of svp-gitops
  # reads it (deploy/ci/gitops-check.sh): no YAML tool of its own.
  mkdir -p "$work/yj/templates" "$work/yj/in" && cp "$work/root.yaml" "$work/yj/in/doc" &&
    printf 'apiVersion: v2\nname: yj\nversion: 0.1.0\n' >"$work/yj/Chart.yaml" &&
    printf '%s\n' '{{- range $doc := regexSplit `(?m)^---.*$` (.Files.Get "in/doc") -1 }}' \
      '{{- if regexMatch `(?m)^[^#\s]` $doc }}' '# json {{ fromYaml $doc | toJson }}' '{{- end }}' '{{- end }}' \
      >"$work/yj/templates/json.yaml" || fail "write a chart in $work"
  app=$(helm template yj "$work/yj" | sed -n 's/^# json //p' |
    jq -c 'select(.kind == "Application" and .metadata.name == "svp-cluster")') ||
    fail "read the Applications of the root's render"
  [ "$(grep -c . <<<"$app")" = 1 ] ||
    fail "the root's render at ${sha:0:12} of svp-gitops for $env on $platform has $(grep -c . <<<"$app") Applications svp-cluster, not one"
  helm_src=$(jq -c '[.spec.sources[] | select(.helm)] | if length == 1 then .[0].helm else error("sources with helm: \(length)") end' \
    <<<"$app") || fail "Application svp-cluster of the root's render has not exactly one source with helm"
  # Only what this script reads: a value string or a parameter would change the values without it seeing them.
  jq -e 'has("values") or has("parameters") | not' <<<"$helm_src" >/dev/null ||
    fail "Application svp-cluster of the root's render sets helm.values or helm.parameters, which this script does not read; only valueFiles and valuesObject"
  value_files=()
  while IFS= read -r f; do
    case $f in
      '$values/'*) path=${f#\$values/} ;;
      *) fail "Application svp-cluster of the root's render reads values file '$f', not one of svp-gitops (\$values/<path>)" ;;
    esac
    case /$path/ in */../* | *//*) fail "Application svp-cluster of the root's render reads values file '$f', outside svp-gitops" ;; esac
    [ -f "$work/gitops/$path" ] || fail "Application svp-cluster reads $path, which ${sha:0:12} of svp-gitops does not hold"
    value_files+=("$work/gitops/$path")
  done < <(jq -r '(.valueFiles // [])[]' <<<"$helm_src")
  if [ "$(jq -r 'has("valuesObject")' <<<"$helm_src")" = true ]; then
    jq '.valuesObject' <<<"$helm_src" >"$work/svp-cluster-object.json" || fail "write the valuesObject of svp-cluster"
    value_files+=("$work/svp-cluster-object.json")
  fi
  for f in ${value_files[@]+"${value_files[@]}"}; do overlay_args+=(--values "$f"); done
  # The object store of those values: the source Secrets of its users only while it runs in the cluster.
  object_store=$(values_json ${value_files[@]+"${value_files[@]}"} | jq -r '.s3.mode // "cluster"') ||
    fail "read s3.mode of the values of svp-cluster"
  project_ns=$(hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
    ${overlay_args[@]+"${overlay_args[@]}"}) ||
    fail "render the namespaces of chart svp-cluster at ${chart_rev:0:12} with the values of its Application"
else
  if [ -n "$platform" ] && git -C "$gitops" cat-file -e "$sha:platforms/$platform/svp-cluster.yaml" 2>/dev/null; then
    at "platforms/$platform/svp-cluster.yaml" >"$work/platform-svp-cluster.yaml" ||
      fail "read platforms/$platform/svp-cluster.yaml at ${sha:0:12} of svp-gitops"
    overlay_args=(--values "$work/platform-svp-cluster.yaml")
  fi
  if git -C "$gitops" cat-file -e "$sha:$cluster_overlay" 2>/dev/null; then
    at "$cluster_overlay" >"$work/svp-cluster.yaml" || fail "read $cluster_overlay at ${sha:0:12} of svp-gitops"
    overlay_args+=(--values "$work/svp-cluster.yaml")
  fi
  project_ns=$(hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
    ${overlay_args[@]+"${overlay_args[@]}"} --set-json 'platformNamespaces=[]') ||
    fail "render the project's namespaces of chart svp-cluster at ${chart_rev:0:12}"
fi
kc apply --server-side --field-manager=svp-pod-security -f - <<<"$project_ns" >/dev/null ||
  fail "create the project's namespaces with Pod Security restricted"
ok "the project's namespaces ($(sed -n 's/^  name: //p' <<<"$project_ns" | paste -sd ' ' -)) enforce Pod Security restricted"
if [ -n "$object_store" ]; then
  SVP_OBJECT_STORE=$object_store SVP_RDS_MASTER_PASSWORD=$rds_master_password "$repo_root/deploy/k8s/secrets.sh"
else
  "$repo_root/deploy/k8s/secrets.sh"
fi

# --- Argo CD, as argocd/bootstrap.json at the revision names it: one object of the form of a component of
# components.json (repo, chart, version, values).
# Pod Security "restricted" on namespace argocd before Argo CD's first pod (every pod of its chart meets it): the
# Namespace of chart svp-cluster's template, as deploy/k8s/install.sh makes those of wave 0. It exists before helm, so
# helm gets no --create-namespace, whose apply would leave the labels out.
hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
  --set-json 'namespaces=[]' --set-json 'platformNamespaces=[{"name":"argocd"}]' |
  kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
  fail "create namespace argocd with Pod Security restricted"
ok "namespace argocd enforces Pod Security restricted"
bootstrap=$(at argocd/bootstrap.json | jq -r '[.repo, .chart, .version, .values] | map(. // "") | join(" ")') ||
  fail "read argocd/bootstrap.json at ${sha:0:12} of svp-gitops"
read -r argocd_repo argocd_chart argocd_version argocd_values <<<"$bootstrap"
[ -n "$argocd_values" ] && [ "$argocd_repo $argocd_chart" = "https://argoproj.github.io/argo-helm argo-cd" ] ||
  fail "argocd/bootstrap.json at ${sha:0:12} of svp-gitops must install chart argo-cd of https://argoproj.github.io/argo-helm with a values file"
at "$argocd_values" >"$work/argo-cd.yaml" || fail "read $argocd_values at ${sha:0:12} of svp-gitops"
echo "helm upgrade --install argocd (argo-cd $argocd_version, namespace argocd)"
hc upgrade --install argocd "$argocd_chart" --repo "$argocd_repo" --version "$argocd_version" \
  --values "$work/argo-cd.yaml" --namespace argocd --wait --timeout 10m >/dev/null || fail "install Argo CD"
ok "Argo CD installed"

# No repository Secret: Argo CD reads $gitops_url and $chart_repo_url over HTTPS without credentials.

# --force-conflicts: argocd-server created AppProject default at its start and owns its fields until this apply
# empties them.
at argocd/project.yaml | kc apply --server-side --field-manager=svp-gitops --force-conflicts -f - >/dev/null ||
  fail "apply AppProjects svp and default"
ok "AppProject svp, AppProject default emptied"

# The root, as written before the namespaces (root_app).
kc apply --server-side --field-manager=svp-gitops -f - <<<"$root_app" >/dev/null || fail "apply Application svp-root"
ok "Application svp-root reads ${sha:0:12} of $gitops_url (HTTPS, no credentials), charts of ${chart_rev:0:12}, nodeArch $node_arch, env $env${platform:+, platform $platform}${cluster_json:+, cluster of CLUSTER_VALUES}"

# app_report: reads the Applications of namespace argocd and prints one line per name of $want_apps:
#   ready NAME             Synced, Healthy and its last sync Succeeded: the criterion of the health check for
#                          Applications in base/argo-cd.yaml of svp-gitops, so a PostSync hook still running or failed
#                          is not ready;
#   wait NAME(S/H/P)       anything else, with its sync status, health and phase of its last sync ("-" when unset);
#   missing NAME           not created by the root yet (a later wave);
# and, after those, one line per problem Argo CD reports:
#   error NAME: ...        a condition whose type ends in Error (ComparisonError: a repository it cannot read, a
#                          revision or path it cannot find; InvalidSpecError; SyncError ...), or a sync that Failed or
#                          ended in Error once its retries were spent;
#   retry NAME: ...        a sync that failed and is being retried, with Argo CD's message.
app_report() {
  kc -n argocd get applications.argoproj.io -o json | jq -r --arg want "$want_apps" '
    (.items | map({key: .metadata.name, value: .}) | from_entries) as $apps
    | [$want | split("\n")[] | select(. != "")] as $names
    | ($names[] as $n | $apps[$n] as $a
        | if $a == null then "missing \($n)"
          else ($a.status.sync.status // "-") as $s | ($a.status.health.status // "-") as $h
            | ($a.status.operationState.phase // "-") as $p
            | if $s == "Synced" and $h == "Healthy" and $p == "Succeeded" then "ready \($n)"
              else "wait \($n)(\($s)/\($h)/\($p))" end
          end),
      ($names[] as $n | $apps[$n] // empty | .status as $st
        | (($st.conditions // [])[] | select(.type | endswith("Error"))
            | "error \($n): \(.type): \(.message // "" | gsub("\n"; " "))"),
          ($st.operationState // empty
            | (.message // "" | gsub("\n"; " ")) as $m
            | if .phase == "Failed" or .phase == "Error" then "error \($n): sync \(.phase): \($m)"
              elif .phase == "Running" and (.retryCount // 0) > 0 then "retry \($n): \($m)"
              else empty end))'
}

# Every Application of $want_apps ready within the deadline. GlitchTip's DSN goes into Secret svp/sentry once
# svp-observability (wave 5) is ready; the services (wave 7) that started before it are restarted by
# glitchtip-init.sh, those that start after read it. Argo CD retries a failed comparison at each poll (60 s), so an
# error is printed when it first shows, and the wait stops once errors have been reported for 180 s without a break
# (three polls: not a passing failure such as a moment without GitHub) instead of running out its 1800 s.
want=$(printf '%s' "$want_apps" | grep -c .)
again="make k8s-down && make k8s-gitops-up"
! cloud_context || again="make eks-gitops-up CONTEXT=$kube_context CLUSTER_VALUES=<file> again"
deadline=$((SECONDS + 1800))
dsn_done=
last=
shown=
errors_since=
while :; do
  report=$(app_report) || fail "list the Applications of namespace argocd"
  if [ -z "$dsn_done" ] && printf '%s\n' "$report" | grep -qx 'ready svp-observability'; then
    "$repo_root/deploy/k8s/glitchtip-init.sh"
    dsn_done=yes
  fi
  ready=$(printf '%s\n' "$report" | grep -c '^ready ' || true)
  if [ "$ready" = "$want" ] && [ -n "$dsn_done" ]; then break; fi
  pending=$(printf '%s\n' "$report" | awk '$1 == "wait" { printf " %s", $2 } $1 == "missing" { m++ }
    END { if (m) printf " and %d not created yet", m }')
  if [ "$pending" != "$last" ]; then
    echo "wait  $ready/$want Applications ready;$pending"
    last=$pending
  fi
  problems=$(printf '%s\n' "$report" | grep -E '^(error|retry) ' || true)
  if [ "$problems" != "$shown" ]; then
    [ -z "$problems" ] || printf '%s\n' "$problems" | sed 's/^/argo  /'
    shown=$problems
  fi
  if printf '%s\n' "$problems" | grep -q '^error '; then
    errors_since=${errors_since:-$SECONDS}
    ((SECONDS - errors_since < 180)) ||
      fail "Argo CD has reported the errors above for 180s, so this script stops; fix their cause (the repository must be public, Argo CD reads it without credentials; the revision; a chart), then $again"
  else
    errors_since=
  fi
  if ((SECONDS >= deadline)); then
    kc -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}: {.status.operationState.message} {.status.conditions[*].message}{"\n"}{end}' >&2
    gitops_timeout_report "$want_apps" || true
    fail "every Application Synced and Healthy within 1800s"
  fi
  sleep 10
done
ok "$want Applications Synced and Healthy, their syncs Succeeded, at ${sha:0:12} of svp-gitops"
[ -z "$branch" ] || follow_branch "$branch"
if cloud_context; then
  echo
  echo "Argo CD UI: kubectl --context $kube_context -n argocd port-forward --address 127.0.0.1 service/argocd-server 8081:443"
  echo "  (https://127.0.0.1:8081, user admin; password:"
  echo "  kubectl --context $kube_context -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  exit 0
fi
export_ca

echo
echo "Argo CD UI: make k8s-ui-argocd (https://127.0.0.1:8081, user admin; password:"
echo "  kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
