#!/usr/bin/env bash
# The GitOps path of docs/adr/0014-kubernetes-local-stage4.md, section 12: a new cluster svp on which Argo CD builds
# everything from GitHub. This script installs only what git cannot hold or what must exist before Argo CD:
#   1. the release tags: read from the revision Argo CD will follow, and each one checked to be a commit of this clone,
#      before anything is created;
#   2. the registry and the cluster (as `make k8s-up`), then every release image the registry lacks, built from its
#      commit (the registry is deleted with the cluster);
#   3. the Secrets from .env (deploy/k8s/secrets.sh), which never go to git;
#   4. Argo CD (deploy/k8s/values/argo-cd.yaml) in namespace argocd with Pod Security "restricted", its repository
#      Secret with the read-only deploy key, AppProject svp and the emptied AppProject default
#      (deploy/argocd/project.yaml) and root Application svp-root (chart deploy/argocd/apps at the same revision);
#   5. a bounded wait until every Application is Synced and Healthy with its last sync Succeeded, with GlitchTip's DSN
#      put into Secret svp/sentry once GlitchTip is up (deploy/k8s/glitchtip-init.sh), so the services report errors
#      on this path too. An error Argo CD keeps reporting for 180 s stops the wait early.
# The release tags and the list of Applications come from git, never from the working tree: what this script checks
# is what Argo CD deploys.
#
# Environment (set by `make k8s-gitops-up`):
#   ARGOCD_DEPLOY_KEY  path of the private half of a deploy key of the GitHub repository, made with "Allow write
#                      access" left unticked (GitHub's side cannot be checked from here): Argo CD only reads git.
#                      Read from its file into the Secret on stdin; never printed, copied or written anywhere else.
#   GITOPS_REV         what Argo CD follows: a branch of origin (default main; its tags are read from
#                      refs/remotes/origin/<branch> as fetched last, without a fetch) or a full commit SHA.
#
# Secrets live outside git, so a changed .env reaches this cluster by hand: `make k8s-secrets`, then a sync of
# Application svp-data, whose init Jobs set the new passwords in Postgres, MinIO and Redpanda
# (kubectl --context k3d-svp -n argocd patch applications.argoproj.io svp-data --type merge
#  -p '{"operation":{"sync":{}}}'), then `kubectl --context k3d-svp -n <namespace> rollout restart deployment/<name>` of
# each workload whose Secret changed: five of the services, kps-grafana, glitchtip, keda-operator. The gateway is an
# Argo Rollouts Rollout: a restart that stamps its pod template is a new revision, hence a canary, so it restarts
# through spec.restartAt instead (its pods are evicted one at a time, the template unchanged):
#   kubectl --context k3d-svp -n svp patch rollout gateway --type merge \
#     -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
# `make k8s-up` does the same on the dev path and refuses a cluster Argo CD manages.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"

repo_url=git@github.com:anhnvcoder/short-video-platform.git
argocd_chart_version=10.10.5
rev=${GITOPS_REV:-main}
key_file=${ARGOCD_DEPLOY_KEY:-}

# --- the deploy key: a private key file only its owner can read, without a passphrase (Argo CD cannot enter one).
[ -n "$key_file" ] || fail "ARGOCD_DEPLOY_KEY is not set: make k8s-gitops-up ARGOCD_DEPLOY_KEY=<private key file of a read-only deploy key>"
[ -f "$key_file" ] && [ -s "$key_file" ] || fail "ARGOCD_DEPLOY_KEY: $key_file is not a non-empty file"
mode=$(stat -f %Lp "$key_file") || fail "ARGOCD_DEPLOY_KEY: read the mode of $key_file"
[ $((8#$mode & 8#077)) = 0 ] || fail "ARGOCD_DEPLOY_KEY: $key_file has mode $mode; a private key must be readable by its owner only (chmod 600 $key_file)"
ssh-keygen -y -P '' -f "$key_file" >/dev/null 2>&1 ||
  fail "ARGOCD_DEPLOY_KEY: $key_file is not an SSH private key without a passphrase"
command -v jq >/dev/null || fail "jq is not installed (brew install jq): it reads components.json and Argo CD's status"

# --- the revision and its release tags, before anything is created.
if sha=$(git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/origin/$rev^{commit}"); then
  echo "revision: origin/$rev = $sha (as last fetched; this script does not fetch)"
elif [[ $rev =~ ^[0-9a-f]{40}$ ]] && sha=$(git -C "$repo_root" rev-parse --verify --quiet "$rev^{commit}"); then
  echo "revision: commit $sha"
else
  fail "GITOPS_REV=$rev is neither a branch of origin (refs/remotes/origin/$rev) nor a full commit SHA of this clone"
fi

values_dir=deploy/k8s/values/services
release_images=()
if git -C "$repo_root" cat-file -e "$sha:$values_dir" 2>/dev/null; then
  for svc in "${svp_services[@]}"; do
    file="$values_dir/$svc.yaml"
    content=$(git -C "$repo_root" show "$sha:$file" 2>/dev/null) || fail "$svc: $file is missing at ${sha:0:12}"
    tag=$(printf '%s\n' "$content" | values_tag) || fail "$svc: cannot read image.tag of $file at ${sha:0:12}"
    [ -n "$tag" ] || fail "$svc: image.tag is empty in $file at ${sha:0:12}; release it (make k8s-release SVC=$svc), commit the values file and push"
    [[ $tag =~ ^[0-9a-f]{12}$ ]] && git -C "$repo_root" cat-file -e "$tag^{commit}" 2>/dev/null ||
      fail "$svc: image.tag $tag in $file at ${sha:0:12} is not a commit of this clone; release it (make k8s-release SVC=$svc), commit the values file and push"
    release_images+=("$svc:$tag")
  done
  ok "release tags at ${sha:0:12}: ${release_images[*]}"
else
  echo "skip  release images: ${sha:0:12} has no $values_dir; Argo CD will report what the revision lacks"
fi
# Without the app-of-apps chart at this revision Argo CD has nothing to build; the root Application is still created,
# and the error it reports shows whether Argo CD reached the repository.
apps_chart=deploy/argocd/apps/Chart.yaml
has_apps=yes
git -C "$repo_root" cat-file -e "$sha:$apps_chart" 2>/dev/null || has_apps=
# The Applications to wait for: the root and one per component of components.json at the revision, the copy the root
# renders (the working tree's may list more or fewer).
want_apps=
if [ -n "$has_apps" ]; then
  components=deploy/argocd/apps/components.json
  want_apps=$(git -C "$repo_root" show "$sha:$components" 2>/dev/null | jq -r '.components[].name') &&
    [ -n "$want_apps" ] || fail "read the component names of $components at ${sha:0:12}"
  want_apps=$(printf 'svp-root\n%s\n' "$want_apps")
fi

# --- a new cluster only: the dev path's releases (Helm) and Argo CD's would fight over the same objects.
if k3d_ cluster get svp >/dev/null 2>&1; then
  fail "cluster svp already exists; the GitOps path starts from a new cluster: run make k8s-down first"
fi
ensure_registry
ensure_cluster

for image in ${release_images[@]+"${release_images[@]}"}; do
  svc=${image%%:*}
  tag=${image#*:}
  if registry_has "$svc" "$tag"; then
    ok "$svc image $tag already in the registry"
  else
    build_release_image "$svc" "$tag"
  fi
done

# --- the Secrets. Chart svp-cluster (wave 1) owns the project's namespaces, but two things need them earlier: the
# Secrets, before the first pod that reads one (wave 2), and Envoy Gateway (wave 0), which binds a Role in each
# namespace it watches (deploy/k8s/values/envoy-gateway.yaml) and cannot sync while one is missing. So the namespaces of
# svp-cluster's values are made here from its own template, with the same Pod Security labels, as
# deploy/k8s/install.sh does; Argo CD's apply of svp-cluster then finds them as they are. The chart is the one at the
# revision, unpacked with git archive (neither the working tree nor the index is read), so the namespaces match the
# Envoy Gateway values Argo CD deploys from that revision. A revision without it has no Application to build either
# (has_apps): the working tree's chart then makes the namespaces for the Secrets alone.
cluster_chart=deploy/helm/svp-cluster
if git -C "$repo_root" cat-file -e "$sha:$cluster_chart/Chart.yaml" 2>/dev/null; then
  chart_dir=$(mktemp -d) || fail "create a temporary directory for chart svp-cluster of ${sha:0:12}"
  if ! git -C "$repo_root" archive "$sha" "$cluster_chart" | tar -x -C "$chart_dir"; then
    rm -rf "$chart_dir"
    fail "unpack $cluster_chart of ${sha:0:12} with git archive"
  fi
  rc=0
  project_ns=$(hc template svp-cluster "$chart_dir/$cluster_chart" --show-only templates/namespaces.yaml \
    --set-json 'platformNamespaces=[]') || rc=$?
  rm -rf "$chart_dir"
  [ "$rc" = 0 ] || fail "render the project's namespaces of chart svp-cluster at ${sha:0:12}"
else
  echo "skip  namespaces from git: ${sha:0:12} has no $cluster_chart; the working tree's makes them for the Secrets"
  project_ns=$(hc template svp-cluster "$repo_root/$cluster_chart" --show-only templates/namespaces.yaml \
    --set-json 'platformNamespaces=[]') || fail "render the project's namespaces of chart svp-cluster"
fi
kc apply --server-side --field-manager=svp-pod-security -f - <<<"$project_ns" >/dev/null ||
  fail "create the project's namespaces with Pod Security restricted"
ok "the project's namespaces ($(sed -n 's/^  name: //p' <<<"$project_ns" | paste -sd ' ' -)) enforce Pod Security restricted"
"$repo_root/deploy/k8s/secrets.sh"

# --- Argo CD.
# Pod Security "restricted" on namespace argocd before Argo CD's first pod (every pod of its chart meets it): the
# Namespace of chart svp-cluster's template, as deploy/k8s/install.sh makes those of wave 0. It exists before helm, so
# helm gets no --create-namespace, whose apply would leave the labels out.
hc template svp-cluster "$repo_root/deploy/helm/svp-cluster" --show-only templates/namespaces.yaml \
  --set-json 'namespaces=[]' --set-json 'platformNamespaces=[{"name":"argocd"}]' |
  kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
  fail "create namespace argocd with Pod Security restricted"
ok "namespace argocd enforces Pod Security restricted"
echo "helm upgrade --install argocd (argo-cd $argocd_chart_version, namespace argocd)"
hc upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$argocd_chart_version" \
  --values "$repo_root/deploy/k8s/values/argo-cd.yaml" --namespace argocd --wait --timeout 10m \
  >/dev/null || fail "install Argo CD"
ok "Argo CD installed"

# The repository Secret (ADR section 8): the key goes from its file into a shell variable and on stdin to kubectl,
# never onto a command line. GitHub's host keys are in ConfigMap argocd-ssh-known-hosts-cm, which the chart ships.
deploy_key=$(<"$key_file")
label='argocd.argoproj.io/secret-type: repository' secret argocd repo-short-video-platform Opaque \
  type=git url="$repo_url" sshPrivateKey="$deploy_key"$'\n' |
  kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply Secret argocd/repo-short-video-platform"
deploy_key=
ok "Secret argocd/repo-short-video-platform: $repo_url over SSH with the deploy key"

# --force-conflicts: argocd-server created AppProject default at its start and owns its fields until this apply
# empties them.
kc apply --server-side --field-manager=svp-gitops --force-conflicts -f "$repo_root/deploy/argocd/project.yaml" \
  >/dev/null || fail "apply AppProjects svp and default"
ok "AppProject svp, AppProject default emptied"

# The root follows $rev, and hands the same revision to every Application it makes (value targetRevision of chart
# deploy/argocd/apps), so the tags checked above are the ones deployed. argocd_root_app (lib.sh) writes the revision
# as a string whatever it looks like.
argocd_root_app "$repo_url" "$rev" | kc apply --server-side --field-manager=svp-gitops -f - >/dev/null ||
  fail "apply Application svp-root"
ok "Application svp-root follows $rev"

if [ -z "$has_apps" ]; then
  # Argo CD reports a ComparisonError on the root once the repo-server has tried the revision: its message tells a
  # missing path (the repository was read) from a failed login or an unknown revision.
  deadline=$((SECONDS + 180))
  until msg=$(kc -n argocd get applications.argoproj.io svp-root -o jsonpath='{.status.conditions[*].message}') &&
    [ -n "$msg" ]; do
    ((SECONDS < deadline)) || fail "Application svp-root reported no condition within 180s"
    sleep 2
  done
  echo "svp-root: $msg"
  fail "${sha:0:12} has no $apps_chart, so Argo CD has nothing to build yet: push the stage's work to $rev, then make k8s-down && make k8s-gitops-up"
fi

# app_report: reads the Applications of namespace argocd and prints one line per name of $want_apps:
#   ready NAME             Synced, Healthy and its last sync Succeeded: the criterion of the health check for
#                          Applications in deploy/k8s/values/argo-cd.yaml, so a PostSync hook still running or failed
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
      fail "Argo CD has reported the errors above for 180s, so this script stops; fix their cause (the deploy key on GitHub, the revision, a chart), then make k8s-down && make k8s-gitops-up"
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
ok "$want Applications Synced and Healthy, their syncs Succeeded, at ${sha:0:12}"
export_ca

echo
echo "Argo CD UI: make k8s-ui-argocd (https://127.0.0.1:8081, user admin; password:"
echo "  kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
