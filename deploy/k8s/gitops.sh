#!/usr/bin/env bash
# The GitOps path: a new cluster svp on which Argo CD builds everything from GitHub: the deployment configuration from
# svp-gitops (root chart argocd/apps, base/, envs/stg/), the charts of this repository (deploy/helm/*) at the commit
# envs/stg/charts.yaml there pins. This script installs only what git cannot hold or what must exist before Argo CD:
#   1. the release images, before anything is created:
#      image.repository and image.digest of the seven files envs/stg/images/ of svp-gitops at the revision Argo CD will
#      follow, which the promote pull request writes; each must be a release of
#      ghcr.io/anhnvcoder/short-video-platform/<service> that GHCR serves to an anonymous pull (the nodes pull without
#      credentials), signed by images.yml on main, with a vuln attestation that is clean and at most 48 hours old
#      (Kyverno refuses new pods at 72), and with a build provenance attestation when chart svp-policy checks provenance
#      in stg at that revision (its values at the commit of envs/stg/charts.yaml, then envs/stg/svp-policy.yaml:
#      deploy/ci/values-check.sh --gitops);
#   2. the registry and the cluster (as `make k8s-up`); nothing is built here, the images come from GHCR;
#   3. the Secrets from .env (deploy/k8s/secrets.sh), which never go to git: with externalSecrets of chart svp-cluster
#      on in envs/stg (every revision of svp-gitops), only their source, the Secrets of namespace svp-secrets, from
#      which External Secrets Operator (component external-secrets) builds every Secret once Argo CD has installed it;
#   4. Argo CD (argocd/bootstrap.json: chart, version and values file base/argo-cd.yaml) in namespace argocd with Pod
#      Security "restricted", AppProject svp and the emptied AppProject default (argocd/project.yaml) and root
#      Application svp-root (chart argocd/apps at the same revision, told the architecture of the nodes and the
#      environment, stg: this cluster runs as staging). No repository Secret: both repositories are public and Argo CD
#      reads them over HTTPS without credentials, so this path holds no key or token; a repository that turned private
#      again would need a read-only credential here;
#   5. a bounded wait until every Application is Synced and Healthy with its last sync Succeeded, with GlitchTip's DSN
#      put into Secret svp/sentry once GlitchTip is up (deploy/k8s/glitchtip-init.sh), so the services report errors
#      on this path too. An error Argo CD keeps reporting for 180 s stops the wait early.
# The release images, Argo CD's install and the list of Applications come from git at the revision, never from a
# working tree: what this script checks is what Argo CD deploys.
#
# Environment (set by `make k8s-gitops-up`):
#   GITOPS_REV         the revision of svp-gitops Argo CD follows: a branch of the clone's origin (default main; read
#                      from refs/remotes/origin/<branch> as fetched last, without a fetch; Argo CD gets
#                      refs/heads/<branch>) or a full commit SHA of the clone.
#   SVP_GITOPS_DIR     the clone of svp-gitops (deploy/k8s/lib.sh, gitops_dir; CI's make gitops-clone sets it).
#   SVP_ATTEST_MAX_AGE drills only (never in .env): a shorter limit than 48h for the age of the vuln attestations.
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
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# ci_dispatch_hint: the command that starts a CI run, for the message when the releases need a fresh attestation.
# shellcheck source=deploy/ci/platform.sh
. "$repo_root/deploy/ci/platform.sh"

# repoURL and chartRepoURL of argocd/apps/values.yaml of svp-gitops, both in sourceRepos of AppProject svp.
chart_repo_url=https://github.com/anhnvcoder/short-video-platform.git
rev=${GITOPS_REV:-main}

command -v jq >/dev/null || fail "jq is not installed (brew install jq): it reads components.json and Argo CD's status"
gitops=$(gitops_dir) || exit 1

# --- the revision of svp-gitops and its release images, before anything is created.
if sha=$(git -C "$gitops" rev-parse --verify --quiet "refs/remotes/origin/$rev^{commit}"); then
  target_rev=refs/heads/$rev
  echo "revision: origin/$rev of svp-gitops = $sha (as last fetched in $gitops; this script does not fetch)"
elif [[ $rev =~ ^[0-9a-f]{40}$ ]] && sha=$(git -C "$gitops" rev-parse --verify --quiet "$rev^{commit}"); then
  target_rev=$sha
  echo "revision: commit $sha of svp-gitops"
else
  fail "GITOPS_REV=$rev is neither a branch of origin (refs/remotes/origin/$rev) nor a full commit SHA of the clone $gitops"
fi
# at FILE: prints FILE of svp-gitops at the revision.
at() { git -C "$gitops" show "$sha:$1"; }
# The environment the root hands to chart argocd/apps (value env). Always stg: a lab cluster only ever runs as
# staging, and prd is rendered by the checks alone, so there is nothing to choose.
env=stg
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
echo "env: $env (overlays and release images of envs/$env, charts of this repository at ${chart_rev:0:12})"

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
work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/release" &&
  git -C "$gitops" archive "$sha" "envs/$env" | tar -x -C "$work/release" ||
  fail "unpack envs/$env of ${sha:0:12} of svp-gitops with git archive"
if ! "$repo_root/deploy/ci/values-check.sh" --gitops "$work/release" ""; then
  refresh=$(ci_dispatch_hint images.yml main rescan=true) || exit 1
  fail "a release at ${sha:0:12} of svp-gitops is not signed, its vuln attestation is not clean and fresh, or the provenance the policy requires is missing or wrong (above); nothing was created. Refresh the vuln attestations of the releases: $refresh, then run this again once that run is green (a missing provenance needs a new release instead, as named above)"
fi
ok "release images at ${sha:0:12} of svp-gitops: GHCR serves all seven anonymously, each signed with a fresh, clean vuln attestation"
# The Applications to wait for: the root and one per component of components.json at the revision, the copy the root
# renders.
want_apps=$(at argocd/apps/components.json | jq -r '.components[].name') && [ -n "$want_apps" ] ||
  fail "read the component names of argocd/apps/components.json at ${sha:0:12} of svp-gitops"
want_apps=$(printf 'svp-root\n%s\n' "$want_apps")

# --- a new cluster only: the dev path's releases (Helm) and Argo CD's would fight over the same objects.
if k3d_ cluster get svp >/dev/null 2>&1; then
  fail "cluster svp already exists; the GitOps path starts from a new cluster: run make k8s-down first"
fi
# The registry stays although nothing is pushed to it on this path: deploy/k8s/k3d.yaml, shared by both paths, names
# it as the nodes' registry, and the cluster cannot be created without it.
ensure_registry
ensure_cluster

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

# --- the Secrets. Chart svp-cluster (wave 1) owns the project's namespaces, but two things need them earlier: the
# Secrets, before the first pod that reads one (wave 2), and Envoy Gateway (wave 0), which binds a Role in each
# namespace it watches (base/envoy-gateway.yaml of svp-gitops) and cannot sync while one is missing. So the namespaces
# of svp-cluster's values are made here from its own template, with the same Pod Security labels, as
# deploy/k8s/install.sh does; Argo CD's apply of svp-cluster then finds them as they are. The chart is the one stg runs,
# at the commit of envs/stg/charts.yaml, unpacked with git archive (neither the working tree nor the index is read), so
# the namespaces match the Envoy Gateway values Argo CD deploys. The overlay of the environment for svp-cluster, when
# the revision has one, is read too, as Argo CD reads it: with externalSecrets on, it adds namespace svp-secrets, which
# deploy/k8s/secrets.sh then fills with the source of the Secrets.
cluster_chart=deploy/helm/svp-cluster
cluster_overlay=envs/$env/svp-cluster.yaml
git -C "$repo_root" cat-file -e "$chart_rev:$cluster_chart/Chart.yaml" 2>/dev/null ||
  fail "commit ${chart_rev:0:12} of this repository (envs/$env/charts.yaml) has no $cluster_chart"
mkdir -p "$work/charts" && git -C "$repo_root" archive "$chart_rev" "$cluster_chart" | tar -x -C "$work/charts" ||
  fail "unpack $cluster_chart of ${chart_rev:0:12} with git archive"
overlay_args=()
if git -C "$gitops" cat-file -e "$sha:$cluster_overlay" 2>/dev/null; then
  at "$cluster_overlay" >"$work/svp-cluster.yaml" || fail "read $cluster_overlay at ${sha:0:12} of svp-gitops"
  overlay_args=(--values "$work/svp-cluster.yaml")
fi
project_ns=$(hc template svp-cluster "$work/charts/$cluster_chart" --show-only templates/namespaces.yaml \
  ${overlay_args[@]+"${overlay_args[@]}"} --set-json 'platformNamespaces=[]') ||
  fail "render the project's namespaces of chart svp-cluster at ${chart_rev:0:12}"
kc apply --server-side --field-manager=svp-pod-security -f - <<<"$project_ns" >/dev/null ||
  fail "create the project's namespaces with Pod Security restricted"
ok "the project's namespaces ($(sed -n 's/^  name: //p' <<<"$project_ns" | paste -sd ' ' -)) enforce Pod Security restricted"
"$repo_root/deploy/k8s/secrets.sh"

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

# The root follows $target_rev of svp-gitops, and hands the same revision to every Application it makes for its values
# files (value targetRevision of chart argocd/apps), so the releases checked above are the ones deployed.
# argocd_root_app (lib.sh) writes the revision and the environment as strings whatever they look like; the nodes'
# architecture joins them in the root's values, a string too.
argocd_root_app "$gitops_url" "$target_rev" "$env" "$chart_repo_url" |
  jq --arg arch "$node_arch" '.spec.source.helm.valuesObject.nodeArch = $arch' |
  kc apply --server-side --field-manager=svp-gitops -f - >/dev/null ||
  fail "apply Application svp-root"
ok "Application svp-root follows $target_rev of $gitops_url (HTTPS, no credentials), charts of ${chart_rev:0:12}, nodeArch $node_arch, env $env"

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
      fail "Argo CD has reported the errors above for 180s, so this script stops; fix their cause (the repository must be public, Argo CD reads it without credentials; the revision; a chart), then make k8s-down && make k8s-gitops-up"
  else
    errors_since=
  fi
  if ((SECONDS >= deadline)); then
    kc -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}: {.status.operationState.message} {.status.conditions[*].message}{"\n"}{end}' >&2
    fail "every Application Synced and Healthy within 1800s"
  fi
  sleep 10
done
ok "$want Applications Synced and Healthy, their syncs Succeeded, at ${sha:0:12} of svp-gitops"
export_ca

echo
echo "Argo CD UI: make k8s-ui-argocd (https://127.0.0.1:8081, user admin; password:"
echo "  kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
