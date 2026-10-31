# shellcheck shell=bash
# Helpers shared by the scripts and make targets of the local Kubernetes cluster `svp` (deploy/k8s/, deploy/k8s/k8s.mk):
# the pinned docker/k3d/kubectl/helm calls, bounded waits, the registry and the cluster themselves, the CA export.
# Written for bash 3.2 (the macOS /bin/bash). Sourcing it only defines things and exports the variables below.
#
# Rules every helper keeps: docker and k3d run without DOCKER_DEFAULT_PLATFORM (the global shell sets linux/amd64 for
# another project; the nodes must run native arm64), kubectl and helm always name the context k3d-svp (the current
# context may be another cluster), every wait has a deadline, no Secret value is ever printed.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# k3d's own helper images, pinned by digest (multi-arch index): k3d otherwise picks them by its version tag.
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-proxy
export K3D_IMAGE_LOADBALANCER=ghcr.io/k3d-io/k3d-proxy:5.9.0@sha256:7be40abfeb6ac9a81d0d4157a7cbf3aacc68a64a1780ca2efb160f1aea915177
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-tools
export K3D_IMAGE_TOOLS=ghcr.io/k3d-io/k3d-tools:5.9.0@sha256:c57abce697e66feeb826922718738fe186b47779312d49d4e51e6fb9b8a6f34d
# The local registry: k3d prefixes the name, so the container is k3d-svp-registry; inside it listens on
# 5000, published on 127.0.0.1:5111 only.
# renovate: datasource=docker depName=docker.io/library/registry
registry_image=docker.io/library/registry:3.1.2@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3
# Deadline of `k3d cluster create` and `k3d cluster start`, which otherwise wait forever for a node's "up and running"
# log line (k3d v5.9.0 sets one only when --timeout > 0). k3d applies it to each step of a create (network, containers
# with their image pulls, start) on its own, so 300 s covers a first run that still pulls the k3s image on a slow link.
k3d_timeout=300s

# Helm keeps its repository list, index cache and plugins under .k8s/helm (gitignored) instead of the user's own
# directories: a repository on the machine with a missing index makes `helm --repo` fail, and the scripts must not add
# repositories to the user's configuration.
export HELM_CACHE_HOME="$repo_root/.k8s/helm/cache"
export HELM_CONFIG_HOME="$repo_root/.k8s/helm/config"
export HELM_DATA_HOME="$repo_root/.k8s/helm/data"

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}

docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
k3d_() { env -u DOCKER_DEFAULT_PLATFORM k3d "$@"; }
kc() { kubectl --context k3d-svp "$@"; }
hc() { helm --kube-context k3d-svp "$@"; }

# wait_until SECONDS DESCRIPTION COMMAND...: runs COMMAND every 2 s until it succeeds; fails naming DESCRIPTION once
# SECONDS have passed. For conditions `kubectl wait` cannot express, such as a resource that does not exist yet.
wait_until() {
  local limit=$1 what=$2 deadline=$((SECONDS + $1))
  shift 2
  until "$@" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "$what within ${limit}s"
    sleep 2
  done
}

# port_free PORT: true when nothing accepts connections on 127.0.0.1:PORT. The lab's ports are fixed, so a taken port is
# an error to report, never a reason to pick another.
port_free() { ! nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

# ensure_registry: creates the registry k3d-svp-registry on 127.0.0.1:5111, starts it when it exists but is stopped,
# leaves it alone when it runs. Shared by every target that pushes images or creates the cluster.
ensure_registry() {
  local state
  state=$(docker_ inspect --format '{{.State.Running}}' k3d-svp-registry 2>/dev/null || true)
  case $state in
    true) ok "registry k3d-svp-registry already running (127.0.0.1:5111)" ;;
    false)
      docker_ start k3d-svp-registry >/dev/null || fail "start the stopped registry k3d-svp-registry"
      ok "registry k3d-svp-registry started (127.0.0.1:5111)"
      ;;
    *)
      port_free 5111 || fail "127.0.0.1:5111 (registry) is already in use by another process; free it and run again"
      k3d_ registry create svp-registry --port 127.0.0.1:5111 --image "$registry_image" >/dev/null ||
        fail "create the registry k3d-svp-registry"
      ok "registry k3d-svp-registry created (127.0.0.1:5111)"
      ;;
  esac
  wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
}

# ensure_cluster: run after ensure_registry. Creates the cluster svp from deploy/k8s/k3d.yaml, starts its stopped nodes, or leaves a running one
# alone; then checks every node is Ready and runs the machine's own architecture (an amd64 node here would mean
# DOCKER_DEFAULT_PLATFORM leaked into k3d, and every pod would run emulated).
ensure_cluster() {
  local all running on_net port want archs node binds bind src psa psa_versions exists= recreate=
  # Where k3d.yaml mounts deploy/k8s/pod-security-admission.yaml in the server node, and the API server reads it.
  local psa_in_node=/etc/rancher/k3s/pod-security-admission.yaml
  if k3d_ cluster get svp >/dev/null 2>&1; then
    exists=1
    # An existing cluster mounts the file and its API server reads it again each time the node starts, which Docker
    # may already have done with the broken file (see below): fixing the file alone is not enough, the cluster is
    # recreated once it is right.
    recreate="; cluster svp mounts this file and its API server reads it again each time the node starts: once the file is right, recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
  fi
  # The admission configuration's three versions must be the one every labelled namespace enforces
  # (podSecurityVersion of chart svp-cluster), or a namespace with labels and one without would be held to different
  # rules. Checked for an existing cluster too: its API server reads the file again each time its node starts.
  psa=$repo_root/deploy/k8s/pod-security-admission.yaml
  [ -f "$psa" ] || fail "$psa is missing; k3d.yaml mounts it into the server node$recreate"
  want=$(sed -n 's/^podSecurityVersion: *//p' "$repo_root/deploy/helm/svp-cluster/values.yaml")
  psa_versions=$(sed -nE 's/^ +(enforce|audit|warn)-version: *//p' "$psa" | tr '\n' ' ')
  [ -n "$want" ] && [ "$psa_versions" = "$want $want $want " ] ||
    fail "enforce-, audit- and warn-version of deploy/k8s/pod-security-admission.yaml (${psa_versions% }) must all equal podSecurityVersion of deploy/helm/svp-cluster/values.yaml ('$want')$recreate"
  if [ -n "$exists" ]; then
    # Pod Security "restricted" by default exists only in a cluster created with it: the argument and
    # mount k3d.yaml gives the server node at creation. A cluster made before them enforces nothing in namespaces
    # without PSA labels (default, kube-public, kube-node-lease) and is not changed in place.
    node=$(docker_ inspect --format '{{join .Config.Cmd " "}}' k3d-svp-server-0) &&
      binds=$(docker_ inspect --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' k3d-svp-server-0) ||
      fail "read the arguments and mounts of node k3d-svp-server-0"
    # One bind per line ("SOURCE:TARGET[:OPTIONS]"), so a source path with spaces stays whole.
    src=
    while IFS= read -r bind; do
      case $bind in *":$psa_in_node" | *":$psa_in_node:"*) src=${bind%":$psa_in_node"*} ;; esac
    done <<<"$binds"
    case $node in
      *"admission-control-config-file=$psa_in_node"*) ;;
      *) src= ;;
    esac
    [ -n "$src" ] ||
      fail "cluster svp was created without the Pod Security admission configuration (deploy/k8s/pod-security-admission.yaml); recreate it, which deletes its data: make k8s-down && make k8s-up"
    # The mount is the file on the machine at the path the cluster was created from, and the API server reads it
    # again each time the node starts: on every `k3d cluster start`, and whenever Docker starts the node by itself
    # (restart policy unless-stopped, e.g. after Docker or the laptop restarts), so a running cluster is checked too.
    # Repository moved or renamed, or a checkout without the file: Docker creates an empty directory at the old
    # path, mounts it, and the API server never comes up (k3d cluster start would only time out after 300 s). A file
    # there that differs from this repository's would be read unchecked. Either way the cluster is recreated from
    # this checkout; another clone with the same content is fine.
    [ -f "$src" ] ||
      fail "node k3d-svp-server-0 mounts the Pod Security admission configuration from '$src', which is no longer a file (repository moved or renamed, or the file deleted): its API server would not start again; recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
    [ "$src" = "$psa" ] || cmp -s "$src" "$psa" ||
      fail "node k3d-svp-server-0 mounts the Pod Security admission configuration from '$src', which differs from $psa; recreate the cluster from this checkout, which deletes its data: make k8s-down && make k8s-up"
    all=$(docker_ ps -aq --filter label=k3d.cluster=svp | wc -l)
    running=$(docker_ ps -q --filter label=k3d.cluster=svp | wc -l)
    if [ "$running" -lt "$all" ]; then
      # Same address race as the create below: before starting the nodes, k3d recreates its tools container with the
      # network's first free address, which a running registry may hold, so the tools container takes the fixed
      # address of the server node and the server fails with "Address already in use" (k3d v5.9.0,
      # GatherEnvironmentInfo and GetHostIP). The registry is stopped meanwhile and started after the nodes.
      docker_ stop k3d-svp-registry >/dev/null || fail "stop the registry k3d-svp-registry before starting the cluster"
      if ! k3d_ cluster start svp --wait --timeout "$k3d_timeout" >/dev/null; then
        docker_ start k3d-svp-registry >/dev/null
        fail "k3d cluster start svp (k3d's log above gives the cause)"
      fi
      docker_ start k3d-svp-registry >/dev/null || fail "start the registry k3d-svp-registry"
      wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
      ok "cluster svp started"
    else
      ok "cluster svp already running"
    fi
    # A registry created again beside an existing cluster (deleted by hand, or broken) sits on Docker's default bridge
    # only: the nodes then cannot resolve k3d-svp-registry and every pull of k3d-svp-registry:5111/... fails. Connected
    # once the nodes run, so it cannot take the fixed address of a node that is still stopped (see the create below).
    on_net=$(docker_ inspect --format '{{if index .NetworkSettings.Networks "k3d-svp"}}yes{{end}}' k3d-svp-registry)
    if [ -z "$on_net" ]; then
      docker_ network connect k3d-svp k3d-svp-registry ||
        fail "connect the registry k3d-svp-registry to network k3d-svp"
      ok "registry k3d-svp-registry connected to network k3d-svp"
    fi
  else
    # k3d.yaml mounts the admission configuration from ${SVP_REPO_ROOT}, which k3d expands from the environment: Docker
    # refuses a relative bind source. A missing file only makes k3d warn, and Docker would mount an empty directory in
    # its place, which stops the API server; so it must exist (checked above, with its versions).
    export SVP_REPO_ROOT=$repo_root
    for port in 6550 8443; do
      port_free "$port" || fail "127.0.0.1:$port (cluster svp) is already in use by another process; free it and run again"
    done
    # k3d reserves the network's first free address for its tools container in memory only, while Docker hands that
    # same address to the running registry when k3d connects it; the server node may then be given the address the
    # tools container takes a moment later (always when its image is still being pulled) and fails to start with
    # "Address already in use" (k3d v5.9.0, ClusterPrepNetwork and ClusterRun in pkg/client/cluster.go). Connected
    # while stopped, the registry gets an address only when started again, after the nodes have theirs.
    docker_ stop k3d-svp-registry >/dev/null || fail "stop the registry k3d-svp-registry before creating the cluster"
    # On failure, a timeout included, k3d deletes what it had created (rollback), network k3d-svp too; the stopped
    # registry would still name that network and never start again ("network k3d-svp not found"), so it is detached
    # first (an error only means k3d already detached it). The next run then starts clean.
    # One step has no deadline: k3d creates its tools container (pulling k3d-tools when missing) on a context
    # without --timeout, so a pull that hangs keeps this command waiting. It is not killed from outside: k3d would
    # stop halfway without its rollback, leaving a half-made cluster that is harder to clean up than a hang the
    # user sees. When it hangs: Ctrl-C, then `make k8s-down` and `make k8s-up`.
    if ! k3d_ cluster create --config "$repo_root/deploy/k8s/k3d.yaml" --timeout "$k3d_timeout"; then
      docker_ network disconnect k3d-svp k3d-svp-registry >/dev/null 2>&1
      docker_ start k3d-svp-registry >/dev/null
      fail "k3d cluster create (k3d rolled back what it had created; its log above gives the cause)"
    fi
    docker_ start k3d-svp-registry >/dev/null || fail "start the registry k3d-svp-registry"
    wait_until 30 "registry API on 127.0.0.1:5111" curl -sf --max-time 2 http://127.0.0.1:5111/v2/
    ok "cluster svp created"
  fi
  kc wait --for=condition=Ready node --all --timeout=120s >/dev/null || fail "every node of svp Ready within 120s"
  case $(uname -m) in
    arm64 | aarch64) want=arm64 ;;
    *) want=amd64 ;;
  esac
  archs=$(kc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' | sort -u)
  [ "$archs" = "$want" ] || fail "nodes of svp run '$archs', expected $want only (DOCKER_DEFAULT_PLATFORM leaked?)"
  ok "nodes Ready, kubernetes.io/arch=$want"
}

# export_ca: writes the cluster CA (key ca.crt of Secret svp-local-ca, a public certificate) to .k8s/ca.crt for
# `curl --cacert .k8s/ca.crt`. Written through a private temporary file and checked to parse before it replaces the
# old one.
export_ca() {
  local tmp
  mkdir -p "$repo_root/.k8s"
  tmp=$(mktemp "$repo_root/.k8s/ca.crt.XXXXXX")
  if ! kc -n cert-manager get secret svp-local-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$tmp" ||
    ! openssl x509 -noout -in "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "read the CA certificate from Secret cert-manager/svp-local-ca"
  fi
  chmod 644 "$tmp"
  mv "$tmp" "$repo_root/.k8s/ca.crt"
  ok "CA written to .k8s/ca.crt"
}

# secret NAMESPACE NAME TYPE KEY=VALUE...: prints one Secret manifest, with the one label in $label ("key: value") when
# the call sets it (label=... secret ...). The values are base64-encoded through a pipe; none is an argument of any
# program. For `kc apply --server-side -f -` on stdin: no value goes through a file or a command line, and a
# server-side apply keeps them out of the last-applied-configuration annotation a client-side apply would copy them
# into. An empty value is written "", so its key is there all the same: an ExternalSecret that names it would
# otherwise fail on a key that does not exist.
secret() {
  local ns=$1 name=$2 type=$3 kv
  shift 3
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
  if [ -n "${label:-}" ]; then printf '  labels:\n    %s\n' "$label"; fi
  printf 'type: %s\ndata:\n' "$type"
  for kv in "$@"; do
    printf '  %s: "%s"\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | base64 | tr -d '\n')"
  done
}

# es_force_sync [NAMESPACE/NAME...]: has External Secrets Operator build ExternalSecrets NAME (every ExternalSecret of
# the cluster when none is named) again from their store, and waits up to 120 s until each has. Their refreshPolicy is
# OnChange (chart svp-cluster, templates/external-secrets.yaml): a changed source reaches a Secret only through a
# change of its ExternalSecret, here a new value of annotation force-sync. ESO then syncs once and writes
# status.syncedResourceVersion (<generation>-<hash of labels and annotations>), new with the annotation, as soon as
# that sync succeeds, whether or not the Secret it builds differs from the one there: an unchanged Secret is left as it
# is (no new resourceVersion, so no pod restarts for it). Waiting for a new resourceVersion of every Secret would hang
# on each whose values did not change. An ExternalSecret whose generation changes meanwhile (Argo CD applied another
# revision) stops the wait, since the sync seen may be of that spec; so does one that is gone. Prints nothing but a
# failure: the reason and message of the Ready condition of each ExternalSecret not done, which ESO keeps to what is
# safe to show.
es_force_sync() {
  local want=" $* " stamp list before id left deadline=$((SECONDS + 120))
  list=$(kc get externalsecrets.external-secrets.io -A -o json) || fail "list the ExternalSecrets of the cluster"
  before=$(jq -c --arg want "$want" '[.items[] | {id: "\(.metadata.namespace)/\(.metadata.name)",
    gen: .metadata.generation, rv: (.status.syncedResourceVersion // "")}
    | .id as $id | select($want == "  " or ($want | contains(" " + $id + " ")))] | map({key: .id, value: .})
    | from_entries' \
    <<<"$list") || fail "read the ExternalSecrets of the cluster"
  for id in "$@"; do
    jq -e --arg id "$id" 'has($id)' <<<"$before" >/dev/null || fail "ExternalSecret $id not found"
  done
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)
  for id in $(jq -r 'keys[]' <<<"$before"); do
    kc -n "${id%%/*}" annotate externalsecrets.external-secrets.io "${id#*/}" --overwrite "force-sync=$stamp" \
      >/dev/null || fail "annotate ExternalSecret $id with force-sync"
  done
  while :; do
    list=$(kc get externalsecrets.external-secrets.io -A -o json) || fail "list the ExternalSecrets of the cluster"
    left=$(jq -r --argjson before "$before" '
      (.items | map({key: "\(.metadata.namespace)/\(.metadata.name)", value: .}) | from_entries) as $now
      | $before | to_entries[] | .key as $id | .value as $b | $now[$id] as $es
      | if $es == null then "stop \($id): gone"
        elif $es.metadata.generation != $b.gen then "stop \($id): its spec changed (generation \($b.gen) to \($es.metadata.generation))"
        else (($es.status.conditions // []) | map(select(.type == "Ready")) | first // {}) as $r
          | if ($es.status.syncedResourceVersion // "") != $b.rv and $r.status == "True" then empty
            else "wait \($id): Ready \($r.status // "-") \($r.reason // "-"): \($r.message // "" | gsub("\n"; " "))" end
        end' <<<"$list") || fail "read the ExternalSecrets of the cluster"
    [ -n "$left" ] || return 0
    if grep -q '^stop ' <<<"$left"; then
      printf '%s\n' "$left" | sed -n 's/^stop /      /p' >&2
      fail "an ExternalSecret changed while it was being synced again (above): Argo CD applied a new revision? Run this again"
    fi
    if ((SECONDS >= deadline)); then
      printf '%s\n' "$left" | sed 's/^wait /      /' >&2
      fail "ExternalSecrets built again from their store within 120s (those above are not)"
    fi
    sleep 2
  done
}

# The deployment configuration lives in its own repository, svp-gitops: base/ (the values of every component, the only
# layer the dev path reads), envs/<env>/ (overlays, charts.yaml, images/) and argocd/ (components.json, the root chart,
# AppProject, Argo CD's own install). Every script reads it through gitops_dir; this repository holds the charts.
gitops_url=https://github.com/anhnvcoder/svp-gitops.git
# The clone CI jobs read (make gitops-clone), inside the checkout and gitignored. A machine reads its own (gitops_dir).
gitops_ci_clone=$repo_root/.gitops/svp-gitops

# gitops_is_clone DIR: true when DIR is the top of a git work tree whose remote origin is svp-gitops (over HTTPS or
# SSH): the check every reader of the configuration makes before it trusts a folder.
gitops_is_clone() {
  local top url
  [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ "$top" = "$(cd "$1" && pwd -P)" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)anhnvcoder/svp-gitops(\.git)?$ ]]
}

# gitops_dir: prints the absolute path of the clone of svp-gitops to read. SVP_GITOPS_DIR when set (CI sets it to the
# clone of make gitops-clone; on a machine it may name another clone, the one being edited); otherwise
# <workspace>/gitops, where <workspace> holds the main checkout of this repository: the parent of the folder of git's
# common directory (<workspace>/backend/.git, the same from the main checkout and from a worktree under
# <workspace>/.worktrees/, which --show-toplevel would not give). The dev path reads that clone's working tree as it is,
# uncommitted changes included, and never clones, fetches or switches a branch in it. Fails, printing the command that
# makes the clone, when the folder is not a clone of svp-gitops: no other copy of the configuration is ever read in its
# place.
gitops_dir() {
  local dir common
  if [ -n "${SVP_GITOPS_DIR:-}" ]; then
    dir=$SVP_GITOPS_DIR
    gitops_is_clone "$dir" ||
      fail "SVP_GITOPS_DIR=$dir is not a clone of svp-gitops: clone it there (git clone $gitops_url '$dir'), or in CI run make gitops-clone first, which sets it"
  else
    # --path-format=absolute: otherwise git prints the common directory relative to the current directory.
    common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      fail "$repo_root is not a git checkout, so the workspace that holds the clone of svp-gitops is unknown; set SVP_GITOPS_DIR"
    dir=$(dirname "$(dirname "$common")")/gitops
    gitops_is_clone "$dir" ||
      fail "$dir is not a clone of svp-gitops, the deployment configuration this path reads: git clone $gitops_url '$dir' (or set SVP_GITOPS_DIR to a clone)"
  fi
  (cd "$dir" && pwd -P)
}

# gitops_clone: CI's copy of the configuration (make gitops-clone). Clones svp-gitops anonymously into $gitops_ci_clone
# (the whole history, which the bootstrap and measure-gitops read), or fetches it when it is there, then checks out
# GITOPS_REF (default main: a branch, as origin/<branch>, or a full commit SHA) detached, and exports SVP_GITOPS_DIR to
# that folder for what this shell runs next. Refuses a clone there with uncommitted changes, or a folder that is no
# clone of svp-gitops, instead of overwriting either. A clone with no index was never checked out (a run that stopped
# between the clone and the checkout, as on a GITOPS_REF that is no branch): it holds nothing to lose, so the next run
# checks it out instead of reading every file as deleted. Touches nothing outside .gitops/ of this checkout.
gitops_clone() {
  local dir=$gitops_ci_clone ref=${GITOPS_REF:-main} target sha
  # No credential helper and no prompt: the clone is anonymous, as Argo CD's is.
  local git_=(env GIT_TERMINAL_PROMPT=0 git -c credential.helper=)
  if [ -e "$dir" ]; then
    gitops_is_clone "$dir" ||
      fail "$dir is not a clone of svp-gitops; remove it (rm -rf .gitops) and run make gitops-clone again"
    [ ! -e "$(git -C "$dir" rev-parse --path-format=absolute --git-path index)" ] ||
      [ -z "$(git -C "$dir" status --porcelain)" ] ||
      fail "$dir has uncommitted changes, which make gitops-clone does not overwrite; commit or remove them first"
    "${git_[@]}" -C "$dir" fetch -q --prune origin || fail "git fetch of $gitops_url into $dir"
  else
    mkdir -p "$(dirname "$dir")" || fail "create $(dirname "$dir")"
    "${git_[@]}" clone -q --no-checkout "$gitops_url" "$dir" || fail "git clone $gitops_url into $dir"
  fi
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    target=$ref
  else
    target=refs/remotes/origin/$ref
  fi
  sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}") ||
    fail "GITOPS_REF=$ref is neither a branch of $gitops_url nor a full commit SHA of it"
  git -C "$dir" checkout -q --detach "$sha" || fail "check out $ref ($sha) in $dir"
  export SVP_GITOPS_DIR=$dir
  ok "svp-gitops at ${sha:0:12} ($ref) in ${dir#"$repo_root"/}"
}

# The web client's source lives in its own repository, svp-web; this repository holds none of it.
web_url=https://github.com/anhnvcoder/svp-web.git
# The clone CI jobs build and test from (make web-clone), inside the checkout and gitignored. A machine reads its own
# (web_dir).
web_ci_clone=$repo_root/.web/svp-web
# Repository of the web releases svp-web's CI pushes; the tag of such a release names a commit of svp-web.
web_release_repository=ghcr.io/anhnvcoder/svp-web/web

# web_is_clone DIR: true when DIR is the top of a git work tree whose remote origin is svp-web, as gitops_is_clone.
web_is_clone() {
  local top url
  [ -d "$1" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) && [ "$top" = "$(cd "$1" && pwd -P)" ] || return 1
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [[ $url =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)anhnvcoder/svp-web(\.git)?$ ]]
}

# web_dir: prints the absolute path of the web client's source that images are built from. SVP_WEB_DIR when set (CI
# sets it to the clone of make web-clone; on a machine it may name another clone), which must be a clone of svp-web;
# otherwise <workspace>/frontend (the workspace as for gitops_dir), which must be one too. The working tree is read as
# it is, uncommitted changes included; nothing is cloned, fetched or switched. No folder there, or one that is no clone
# of svp-web, fails, printing the command that makes the clone, instead of building something else in its place.
web_dir() {
  local dir common
  if [ -n "${SVP_WEB_DIR:-}" ]; then
    dir=$SVP_WEB_DIR
    web_is_clone "$dir" ||
      fail "SVP_WEB_DIR=$dir is not a clone of svp-web: clone it there (git clone $web_url '$dir'), or in CI run make web-clone first and set SVP_WEB_DIR to its folder"
  else
    # --path-format=absolute: otherwise git prints the common directory relative to the current directory.
    common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
      fail "$repo_root is not a git checkout, so the workspace that holds the clone of svp-web is unknown; set SVP_WEB_DIR"
    dir=$(dirname "$(dirname "$common")")/frontend
    web_is_clone "$dir" ||
      fail "$dir is not a clone of svp-web, the web client's source: git clone $web_url '$dir' (or set SVP_WEB_DIR to a clone)"
  fi
  (cd "$dir" && pwd -P)
}

# web_dockerfile DIR: the Dockerfile that builds the web image from DIR (printed by web_dir), at the top of the clone.
web_dockerfile() { echo "$1/Dockerfile"; }

# web_clone: CI's copy of the web client's source (make web-clone), as gitops_clone: clones svp-web anonymously into
# $web_ci_clone (the whole history), or fetches it when it is there, then checks out WEB_REF detached and exports
# SVP_WEB_DIR to that folder for what this shell runs next. WEB_REF is a branch (as origin/<branch>) or a full commit
# SHA; unset, it is the commit of the web release staging runs (image.tag of envs/stg/images/web.yaml in the
# clone of svp-gitops, gitops_dir), so the tests run the code of the image that runs there; a release of
# another repository there has no commit of svp-web, and WEB_REF must then be given. Refuses a clone there with
# uncommitted changes, or a folder that is no clone of svp-web. Touches nothing outside .web/ of this checkout.
web_clone() {
  local dir=$web_ci_clone ref=${WEB_REF:-} target sha gitops file repo tag=
  local git_=(env GIT_TERMINAL_PROMPT=0 git -c credential.helper=)
  if [ -z "$ref" ]; then
    gitops=$(gitops_dir) || exit 1
    file=$gitops/envs/stg/images/web.yaml
    [ -f "$file" ] || fail "$file not found; set WEB_REF to a branch or a full commit SHA of svp-web"
    repo=$(values_field repository <"$file") || fail "cannot read image.repository in $file (above)"
    [ "$repo" = "$web_release_repository" ] ||
      fail "staging runs web from $repo (envs/stg/images/web.yaml), not a release of svp-web: set WEB_REF to a branch or a full commit SHA of svp-web"
    tag=$(values_field tag <"$file") || fail "cannot read image.tag in $file (above)"
    [ -n "$tag" ] || fail "image.tag is empty in $file; set WEB_REF to a branch or a full commit SHA of svp-web"
    ref=$tag
  fi
  if [ -e "$dir" ]; then
    web_is_clone "$dir" ||
      fail "$dir is not a clone of svp-web; remove it (rm -rf .web) and run make web-clone again"
    [ ! -e "$(git -C "$dir" rev-parse --path-format=absolute --git-path index)" ] ||
      [ -z "$(git -C "$dir" status --porcelain)" ] ||
      fail "$dir has uncommitted changes, which make web-clone does not overwrite; commit or remove them first"
    "${git_[@]}" -C "$dir" fetch -q --prune origin || fail "git fetch of $web_url into $dir"
  else
    mkdir -p "$(dirname "$dir")" || fail "create $(dirname "$dir")"
    "${git_[@]}" clone -q --no-checkout "$web_url" "$dir" || fail "git clone $web_url into $dir"
  fi
  # A release's tag is the first 12 hex digits of its commit; WEB_REF itself is a branch or a full SHA.
  if [ -n "$tag" ] || [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    target=$ref
  else
    target=refs/remotes/origin/$ref
  fi
  sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}") ||
    fail "WEB_REF=$ref is neither a branch of $web_url nor a commit of it"
  git -C "$dir" checkout -q --detach "$sha" || fail "check out $ref ($sha) in $dir"
  export SVP_WEB_DIR=$dir
  ok "svp-web at ${sha:0:12} ($ref) in ${dir#"$repo_root"/}"
}

# argocd_root_app REPO_URL REVISION ENV CHART_REPO_URL: prints the root Application svp-root of the GitOps path, as
# JSON for `kc apply -f -`: chart argocd/apps of svp-gitops (REPO_URL) at REVISION, which hands the same revision to
# every Application it makes for its values files (its value targetRevision), reads the charts of this repository from
# CHART_REPO_URL at the commit envs/ENV/charts.yaml pins (its value chartRepoURL) and adds the overlays of environment
# ENV (its value env, a directory of envs/). REVISION is a full ref (refs/heads/<branch>) or a commit, never a short
# name: Argo CD fetches every branch and tag and may resolve a short name to a tag of that name, so a tag named main
# pushed with a stolen token could be deployed. Built by jq from --arg values, so the revision and the environment are always JSON
# strings: a branch named 2026, true or 1e3 written into YAML as it is would be read as a number or a boolean, which the
# Application CRD refuses (targetRevision is a string).
#
# The root compares with Argo CD's default diff, not with the server-side diff the controller uses for every other
# Application (base/argo-cd.yaml of svp-gitops): the root applies its child Applications client-side (no
# ServerSideApply=true), so their fields belong to a field manager of operation Update. A server-side dry run is an
# Apply, which never removes a field another manager entry owns: a field deleted from chart argocd/apps (an
# ignoreDifferences, a retry block, managedNamespaceMetadata) would stay in the predicted and the live Application
# alike, so the root would stay Synced and the child keep the field for good. The default diff compares with the
# kubectl.kubernetes.io/last-applied-configuration annotation of a client-side apply and sees the deletion. The
# children apply their own objects server-side (ServerSideApply=true), for which the server-side diff is right.
argocd_root_app() {
  jq -n --arg repo "$1" --arg rev "$2" --arg env "$3" --arg charts "$4" '{
    apiVersion: "argoproj.io/v1alpha1",
    kind: "Application",
    metadata: {
      name: "svp-root",
      namespace: "argocd",
      annotations: {"argocd.argoproj.io/compare-options": "ServerSideDiff=false"}
    },
    spec: {
      project: "svp",
      source: {
        repoURL: $repo,
        targetRevision: $rev,
        path: "argocd/apps",
        helm: {valuesObject: {targetRevision: $rev, env: $env, chartRepoURL: $charts}}
      },
      destination: {server: "https://kubernetes.default.svc", namespace: "argocd"},
      syncPolicy: {
        automated: {prune: true, selfHeal: true},
        retry: {limit: 10, backoff: {duration: "10s", factor: 2, maxDuration: "3m"}}
      }
    }
  }'
}

# image_policy_ready NAME [FAILURE_POLICY]: true when Kyverno has compiled ImageValidatingPolicy NAME
# (status.conditionStatus.ready) and kyverno-resource-validating-webhook-cfg holds a webhook for it: one of the
# policy's failurePolicy (FAILURE_POLICY when given: Fail or Ignore), objectSelector and rules whose namespaceSelector
# carries the policy's match on namespace svp (Kyverno ANDs it with the selector of its own ConfigMap). A policy with
# its own webhookConfiguration.timeoutSeconds (svp-images and every temporary policy of the drills) gets a webhook of
# its own, ivpol.validate.kyverno.svc-fail-finegrained-<policy> (-ignore- in Audit); the webhook is still found by what
# it selects, not by that name, which is Kyverno's to change.
image_policy_ready() {
  local name=$1 want=${2:-} pol
  pol=$(kc get imagevalidatingpolicies.policies.kyverno.io "$name" -o json 2>/dev/null) || return 1
  [ "$(jq -r '.status.conditionStatus.ready // false' <<<"$pol")" = true ] || return 1
  [ -n "$want" ] || want=$(jq -r '.spec.failurePolicy // "Fail"' <<<"$pol")
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json 2>/dev/null |
    jq -e --arg want "$want" --argjson sel "$(jq -c '.spec.matchConstraints.objectSelector // {}' <<<"$pol")" '
      [.webhooks[] | select(.name | startswith("ivpol."))
        | select(.failurePolicy == $want and (.objectSelector // {}) == $sel)
        | select(any(.rules[]?; .resources | index("pods")))
        | select((.namespaceSelector.matchLabels // {})["kubernetes.io/metadata.name"] == "svp")] | length > 0' >/dev/null
}

# workload_kind NAMESPACE NAME: rollout when NAME is an Argo Rollouts Rollout (the gateway, which chart svp-service
# renders as one for its canary), deployment otherwise. Before Argo Rollouts is
# installed the kind does not exist and the answer is deployment.
workload_kind() {
  if kc -n "$1" get rollouts.argoproj.io "$2" >/dev/null 2>&1; then echo rollout; else echo deployment; fi
}

# restart_workload NAMESPACE NAME: restarts the pods of Deployment or Rollout NAME without a new revision and waits
# until the new pods are ready. A Deployment: `kubectl rollout restart`, which stamps its pod template (a rolling
# update). A Rollout: not that, since any change of its template is a new revision and so a canary; spec.restartAt
# instead, which Argo Rollouts reads as "evict every pod created before this time", one at a time and through the
# PodDisruptionBudget, the template unchanged. It is done once status.restartedAt equals it and the Rollout is Healthy.
# restartAt is a field no chart writes, so neither Helm nor Argo CD puts it back. A Rollout in a canary, before the
# restart or once it has begun (a new release arriving meanwhile), stops it at once (rollout_not_canary).
restart_workload() {
  local ns=$1 name=$2 at deadline
  if [ "$(workload_kind "$ns" "$name")" = rollout ]; then
    rollout_not_canary "$ns" "$name"
    at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    kc -n "$ns" patch rollout "$name" --type merge -p "{\"spec\":{\"restartAt\":\"$at\"}}" >/dev/null ||
      fail "restart rollout $ns/$name (spec.restartAt)"
    deadline=$((SECONDS + 300))
    until test_output "$at Healthy" kc -n "$ns" get rollout "$name" -o jsonpath='{.status.restartedAt} {.status.phase}' \
      >/dev/null 2>&1; do
      ((SECONDS < deadline)) || fail "rollout $ns/$name restarted (status.restartedAt $at) and Healthy within 300s"
      rollout_not_canary "$ns" "$name"
      sleep 2
    done
  else
    kc -n "$ns" rollout restart deployment "$name" >/dev/null || fail "restart deployment $ns/$name"
    kc -n "$ns" rollout status deployment "$name" --timeout=300s >/dev/null ||
      fail "deployment $ns/$name ready again within 300s of its restart"
  fi
}

# rollout_not_canary NAMESPACE NAME: fails, naming the canary and the ways out of it, when Rollout NAME runs one: a pod
# template other than its stable one rolling out (status.currentPodHash is not status.stableRS), a pause or an abort.
# Such a Rollout turns Healthy only once its canary is over, which its analysis decides from the traffic the canary
# gets, so a restart waiting for Healthy would only run out its time and blame the restart.
rollout_not_canary() {
  local ns=$1 name=$2 json why
  json=$(kc -n "$ns" get rollout "$name" -o json) || fail "read rollout $ns/$name"
  why=$(jq -r '(.status // {}) as $s | [
      if ($s.currentPodHash // "") != "" and ($s.stableRS // "") != "" and $s.currentPodHash != $s.stableRS then
        "pod template \($s.currentPodHash) rolling out beside the stable \($s.stableRS), canary weight \($s.canary.weights.canary.weight // 0)%"
      else empty end,
      if (.spec.paused // false) or (($s.pauseConditions // []) | length > 0) then
        "paused (\([$s.pauseConditions[]?.reason] | if length == 0 then "spec.paused" else join(", ") end))"
      else empty end,
      if $s.abort // false then "aborted" else empty end] | join("; ")' <<<"$json") || fail "read rollout $ns/$name"
  [ -n "$why" ] || return 0
  # An aborted Rollout keeps status.abort and the canary's template, so it stays Degraded until the template goes back
  # to the stable one: aborting again cannot get it out.
  case $why in
  *aborted*)
    fail "rollout $ns/$name runs a canary ($why): an aborted Rollout stays Degraded until its pod template goes back to the stable one, so its restart is not waited for. Revert the release (a pull request reverting its promote in svp-gitops on the GitOps path; make k8s-up on the dev path), then run this again"
    ;;
  esac
  fail "rollout $ns/$name runs a canary ($why): it turns Healthy only once the canary is over, so its restart is not waited for. Let the canary finish (its analysis promotes it only under traffic: make k8s-traffic-start) or abort it (kubectl --context k3d-svp -n $ns patch rollout $name --subresource status --type merge -p '{\"status\":{\"abort\":true}}'), then run this again"
}

# test_output WANT COMMAND...: true when COMMAND prints exactly WANT.
test_output() {
  local want=$1 got
  shift
  got=$("$@") || return 1
  [ "$got" = "$want" ]
}

# pg_backup NAME: creates Backup svp-data/NAME of Postgres svp-pg, a base backup by the Barman Cloud plugin into the
# archive generation the Cluster archives to, owned by nothing, so
# that deleting the Cluster leaves it, and waits up to 600 s until it is completed. CloudNativePG never retries a
# Backup: one that fails is final, so this fails at once with the error it recorded. Prints nothing.
pg_backup() {
  local name=$1 state deadline=$((SECONDS + 600))
  kc -n svp-data create -f - >/dev/null <<EOF || fail "create Backup svp-data/$name"
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $name
  namespace: svp-data
spec:
  cluster:
    name: svp-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  while :; do
    state=$(kc -n svp-data get backups.postgresql.cnpg.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null) || state=
    case $state in
      completed) return 0 ;;
      failed) fail "Backup svp-data/$name failed: $(kc -n svp-data get backups.postgresql.cnpg.io "$name" -o jsonpath='{.status.error}')" ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || fail "Backup svp-data/$name completed within 600s (phase '${state:-none}')"
    sleep 3
  done
}

# restart_on_secret_change NAMESPACE WORKLOAD SECRET [ANNOTATION [UNRECORDED]]: restarts Deployment or Rollout WORKLOAD
# (restart_workload) when its pods started before the current version of SECRET, which they read as environment
# variables (a process reads those only when it starts, and nothing restarts a pod when its Secret changes; no chart
# can roll its pods by a checksum of the Secret either, since these Secrets are made outside Helm and Argo CD), and
# waits until the new pods are ready.
#
# The version of the Secret the pods read is kept in annotation ANNOTATION (default svp-env-secret-version) of the
# workload's own metadata, not of its pod template (Helm and Argo CD would see a template that differs from the chart
# and roll it again; for the Rollout it would be a new revision): the Secret's resourceVersion, written once the
# restarted pods are ready. A run that stops before that leaves the old version, so the next run restarts again; a
# Secret deleted and made again has a new resourceVersion too. It holds no value or hash of a secret. A workload
# without the annotation only gets it when UNRECORDED is annotate (the default: it was just created, its pods started
# with the Secret as it is now), and is restarted when UNRECORDED is restart (it may have started before the Secret
# existed).
restart_on_secret_change() {
  local ns=$1 workload=$2 name=$3 key=${4:-svp-env-secret-version} unrecorded=${5:-annotate} kind secret seen
  kind=$(workload_kind "$ns" "$workload")
  secret=$(kc -n "$ns" get secret "$name" -o jsonpath='{.metadata.resourceVersion}') ||
    fail "read the resourceVersion of Secret $ns/$name"
  seen=$(kc -n "$ns" get "$kind" "$workload" -o jsonpath="{.metadata.annotations.$key}") ||
    fail "read $kind $ns/$workload"
  [ "$seen" != "$secret" ] || return 0
  if [ -n "$seen" ] || [ "$unrecorded" = restart ]; then
    restart_workload "$ns" "$workload"
    ok "$kind $workload restarted: Secret $name changed since its pods started"
  fi
  kc -n "$ns" annotate "$kind" "$workload" --overwrite "$key=$secret" >/dev/null ||
    fail "record on $kind $ns/$workload the version of Secret $name its pods read"
}

# The namespaces whose containers' logs unready_report prints, and the only ones whose log lines
# deploy/ci/verify-collect.sh keeps in the public artifact (and job log) of a verification run: third-party servers,
# operators and controllers, whose logs speak of their own start, configuration and peers (Redpanda's startup checks and
# the memory error that stops it, an operator's reconcile errors). Left out: svp (the project's services, whose logs may
# hold user data), envoy-gateway-system (the Envoy proxies' access log holds request paths and query strings, the
# signatures of presigned uploads among them), kube-system and argocd. Within these, unready_report also skips
# GlitchTip (its access log holds the DSN's public key, its errors the events it received) and every Postgres pod of
# CloudNativePG (an error line quotes the statement that failed, values included).
log_tail_namespaces="argo-rollouts cert-manager cnpg-system keda kyverno svp-data svp-obs"

# mark_log NAMESPACE < LOG: prints each line of LOG as "    [NAMESPACE] LINE", the form verify-collect.sh tells a quoted
# container log by, and keeps only for the namespaces of log_tail_namespaces: a line left unmarked (a panic of a
# service, which is no JSON record) would reach the public artifact of a verification run. Every line is marked
# whatever its bytes (LC_ALL=C: sed refuses bytes that are not UTF-8 under a UTF-8 locale), the last one ends with a
# newline even when LOG's does not (else the next line printed would be glued to it), and an empty LOG prints nothing.
mark_log() {
  { cat; echo; } | LC_ALL=C sed -e '${' -e '/^$/d' -e '}' -e "s/^/    [$1] /"
}

# unready_report NAMESPACE: after a release that did not get ready, prints to stderr each container of NAMESPACE that
# is not ready, and each init container that has not exited 0: its state, how its last attempt ended, and, for a
# container whose log may be shown (log_tail_namespaces), the last lines of its log, and of the attempt before when it
# restarted. Helm says no more than "1 pods have failed", and the kubelet keeps the log of the current and the previous
# attempt only, so a container that crashes at every start is gone with its reason once the cluster is: a verification
# run on a machine that is thrown away right after has nothing else to show. Pods that completed (Jobs) are left out.
# Each log line is printed as "    [NAMESPACE] LINE", the form verify-collect.sh keeps only for these namespaces. The
# message of the last attempt is a log tail too when the container's terminationMessagePolicy is
# FallbackToLogsOnError, so it is printed only where the log may be.
unready_report() {
  local ns=$1 sep=$'\x1f' pod container restarts state last show
  kc -n "$ns" get pods -o json 2>/dev/null | jq -r --arg ns "$ns" --arg shown " $log_tail_namespaces " '
    def st: to_entries[0] // {key: "unknown", value: {}}
      | "\(.key)\(if .value.reason then " " + .value.reason else "" end)\(if .value.exitCode != null then " (exit \(.value.exitCode))" else "" end)";
    .items[] | select(.status.phase != "Succeeded") | .metadata.name as $pod
    | (($shown | contains(" " + $ns + " ")) and ((.metadata.labels // {})
        | (has("cnpg.io/cluster") or .["app.kubernetes.io/name"] == "glitchtip") | not)) as $show
    | ([.spec.initContainers[]?, .spec.containers[]?] | map({(.name): (.terminationMessagePolicy // "File")}) | add // {})
      as $policy
    | ((.status.initContainerStatuses // []) | map(select(.state.terminated.exitCode != 0)))
      + ((.status.containerStatuses // []) | map(select(.ready | not)))
    | .[]
    | ($show or $policy[.name] != "FallbackToLogsOnError") as $message
    | [$pod, .name, (.restartCount | tostring), (.state | st),
       (if .lastState.terminated then (.lastState | st)
          + (if $message then .lastState.terminated.message // "" | if . != "" then ": " + . else "" end else "" end)
        else "" end),
       (if $show then "yes" else "" end)]
    | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")' 2>/dev/null |
    while IFS=$sep read -r pod container restarts state last show; do
      echo "pod $ns/$pod, container $container: $state, $restarts restart(s)${last:+; attempt before: $last}" >&2
      if [ -z "$show" ]; then
        echo "  its log is not printed (see log_tail_namespaces of deploy/k8s/lib.sh)" >&2
        continue
      fi
      echo "  last lines of its log:" >&2
      { kc -n "$ns" logs "$pod" -c "$container" --tail=40 </dev/null 2>&1 || true; } | mark_log "$ns" >&2
      if [ "$restarts" != 0 ]; then
        echo "  last lines of the attempt before:" >&2
        { kc -n "$ns" logs "$pod" -c "$container" --previous --tail=40 </dev/null 2>&1 || true; } |
          mark_log "$ns" >&2
      fi
    done
}

# gitops_timeout_report APPS: when the GitOps path's wait for its Applications (APPS, one name per line) ran out,
# prints to stderr what Argo CD's own status line leaves out, so a run on a machine thrown away right after still
# shows why:
#   - each Application of APPS that is not Healthy, and each resource it tracks that is not ready, read from the
#     cluster: Argo CD 3 keeps the health of an Application's resources out of the Application (in its own cache,
#     unless its controller runs with --persist-resource-health), and its API needs a login. Only the kinds of
#     health_kinds below are read, each judged by a rule close to Argo CD's check of it: a Deployment, StatefulSet
#     or DaemonSet by its ready and updated pods and the generation it observed, a Job by its conditions Complete and
#     Failed, a PersistentVolumeClaim by its phase, any other kind by its conditions that say it is ready (Ready,
#     Available, ...) when they are not True, or by having no status at all. One that is not there is "missing";
#   - the CRDs of the Prometheus and Alertmanager objects, when they were created and when they became Established;
#   - the status conditions of every Prometheus and Alertmanager object, or that it has none: no controller has
#     reconciled it;
#   - each container of the Prometheus operator's pods in svp-obs (label app.kubernetes.io/component of chart
#     kube-prometheus-stack): when it started, and the last lines of its log, and of its attempt before when it
#     restarted, marked as unready_report marks them. The operator asks the API server once, at its start, which of
#     its CRDs it serves, and never starts the controller of a CRD that was missing then (it logs a warning "resource
#     ... not installed in the cluster"): a Prometheus object it then never turns into a StatefulSet, with no event.
# Nothing here reads a Secret. Each step that cannot read the cluster prints why and the others still run.
gitops_timeout_report() {
  local apps=$1 out sep=$'\x1f' what a b c d type got pod container restarts started
  local -a list
  # GROUP/KIND ("" for the core group) of the kinds the cluster's charts render that Argo CD judges by their status:
  # with checks of its own (gitops-engine for the workloads, resource_customizations/ of v3.5.5 for the others) or of
  # base/argo-cd.yaml of svp-gitops (Alertmanager, ImageValidatingPolicy). Never Secret, and none of the kinds whose
  # objects are large (CRDs, ConfigMaps, PrometheusRules) and say nothing of readiness.
  local health_kinds="apps/Deployment apps/StatefulSet apps/DaemonSet batch/Job /PersistentVolumeClaim
    monitoring.coreos.com/Prometheus monitoring.coreos.com/Alertmanager postgresql.cnpg.io/Cluster
    external-secrets.io/ExternalSecret external-secrets.io/SecretStore argoproj.io/Rollout cert-manager.io/Certificate
    cert-manager.io/Issuer cert-manager.io/ClusterIssuer keda.sh/ScaledObject gateway.networking.k8s.io/GatewayClass
    gateway.networking.k8s.io/Gateway gateway.networking.k8s.io/HTTPRoute policies.kyverno.io/ImageValidatingPolicy"
  echo "Applications not Healthy, and their resources that are not ready:" >&2
  # One record per Application: app, NAME, HEALTH; then one per namespace and kind of its resources to read:
  # resource, NAMESPACE ("" when cluster-scoped), KIND, GROUP, NAMES (space-separated). Hooks are left out, as Argo CD
  # leaves them out of the health.
  if ! out=$(kc -n argocd get applications.argoproj.io -o json 2>&1); then
    echo "  cannot list the Applications: $out" >&2
  elif ! out=$(jq -r --arg want "$apps" --arg kinds "$health_kinds" '
      [$want | split("\n")[] | select(. != "")] as $names
      | [$kinds | splits("[[:space:]]+") | select(. != "")] as $judged
      | .items[] | .metadata.name as $app | select(any($names[]; . == $app))
      | select((.status.health.status // "-") != "Healthy")
      | ["app", $app, (.status.health.status // "-")],
        ((.status.resources // [])
          | map(select(.hook != true and ("\(.group // "")/\(.kind)" as $k | any($judged[]; . == $k))))
          | group_by([.namespace // "", .group // "", .kind])[]
          | ["resource", (.[0].namespace // ""), .[0].kind, (.[0].group // ""), (map(.name) | join(" "))])
      | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")' <<<"$out" 2>/dev/null); then
    echo "  (Argo CD's answer is not JSON)" >&2
  else
    while IFS=$sep read -r what a b c d; do
      case $what in
        app) echo "  $a: $b" >&2 ;;
        resource)
          type=$b${c:+.$c}
          read -r -a list <<<"$d"
          if ! got=$(kc ${a:+-n "$a"} get "$type" "${list[@]}" --ignore-not-found -o json </dev/null 2>&1); then
            echo "    cannot read $type${a:+ in $a}: $got" >&2
            continue
          fi
          # -s: kubectl prints one object for one name, a List for several, nothing when none is there.
          jq -rs --arg kind "$b" --arg ns "$a" --arg names "$d" '
            def say: "\(.type)=\(.status)\(.reason // "" | if . != "" then " " + . else "" end)\(.message // "" | if . != "" then ": " + . else "" end)";
            def not_ready:
              (.status // {}) as $s
              | if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" then
                  (if .kind == "DaemonSet" then [$s.desiredNumberScheduled, $s.numberReady, $s.updatedNumberScheduled]
                   else [.spec.replicas // 1, $s.readyReplicas, $s.updatedReplicas] end | map(. // 0))
                    as [$want, $ready, $updated]
                  | [if ($s.observedGeneration // 0) < (.metadata.generation // 0)
                       then "generation \(.metadata.generation) not observed yet" else empty end,
                     if $ready < $want or $updated < $want then "\($ready)/\($want) ready, \($updated) updated" else empty end,
                     (($s.conditions // [])[] | select(.reason == "ProgressDeadlineExceeded") | say)]
                elif .kind == "Job" then
                  ($s.conditions // []) as $c
                  | if any($c[]; .type == "Complete" and .status == "True") then []
                    elif any($c[]; .type == "Failed" and .status == "True") then [$c[] | select(.type == "Failed") | say]
                    else ["not complete: \($s.active // 0) active, \($s.failed // 0) failed"] end
                elif .kind == "PersistentVolumeClaim" then
                  if $s.phase == "Bound" then [] else ["phase \($s.phase // "-")"] end
                elif $s == {} then ["no status (no controller has reconciled it)"]
                else [(($s.conditions // []) + ($s.conditionStatus.conditions // []) + [($s.parents // [])[].conditions[]?])[]
                    | select(.status != "True" and (.type | IN("Ready", "Available", "Reconciled", "Healthy", "Accepted",
                        "Programmed", "ResolvedRefs", "WebhookConfigured", "RBACPermissionsGranted")))
                    | say]
                end;
            [.[] | if has("items") then .items[] else . end] as $live
            | $names | split(" ")[] as $name
            | ([$live[] | select(.metadata.name == $name)][0]) as $o
            | (if $o == null then ["missing"] else $o | not_ready end) as $why
            | select($why != [])
            | "    \($kind) \(if $ns != "" then $ns + "/" else "" end)\($name): \($why | join("; "))"
            | gsub("[[:cntrl:]]"; " ")' <<<"$got" >&2 2>/dev/null ||
            echo "    (the answer for $type${a:+ in $a} is not JSON)" >&2
          ;;
      esac
    done <<<"$out"
  fi
  echo "CRDs of the Prometheus and Alertmanager objects:" >&2
  if out=$(kc get customresourcedefinitions.apiextensions.k8s.io prometheuses.monitoring.coreos.com \
    alertmanagers.monitoring.coreos.com --ignore-not-found -o json 2>&1); then
    jq -rs '[.[] | if has("items") then .items[] else . end] as $crds
      | if $crds == [] then "  none" else
          ($crds[] | ((.status.conditions // []) | map(select(.type == "Established")) | .[0]) as $e
            | "  \(.metadata.name): created \(.metadata.creationTimestamp // "-"), Established \($e.status // "-") since \($e.lastTransitionTime // "-")")
        end' <<<"$out" >&2 2>/dev/null || echo "  (the answer is not JSON)" >&2
  else
    echo "  cannot read the CRDs: $out" >&2
  fi
  echo "Prometheus and Alertmanager objects (monitoring.coreos.com):" >&2
  if out=$(kc get prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com -A -o json 2>&1); then
    jq -r 'if (.items // []) == [] then "  none" else
        (.items[] | "  \(.kind) \(.metadata.namespace)/\(.metadata.name): "
          + (if (.status.conditions // []) == [] then "no status conditions (no controller has reconciled it)"
             else [.status.conditions[]
                 | "\(.type)=\(.status)\(.reason // "" | if . != "" then " " + . else "" end)\(.message // "" | if . != "" then ": " + . else "" end)"]
               | join("; ") end)
          | gsub("[[:cntrl:]]"; " "))
      end' <<<"$out" >&2 || echo "  (the answer is not JSON)" >&2
  else
    echo "  cannot list them: $out" >&2
  fi
  echo "The Prometheus operator (svp-obs):" >&2
  if ! out=$(kc -n svp-obs get pods -o json 2>&1); then
    echo "  cannot list the pods of svp-obs: $out" >&2
    return 0
  fi
  jq -r '[.items[] | select((.metadata.labels // {})["app.kubernetes.io/component"] == "prometheus-operator")
      | .metadata.name as $pod | (.status.containerStatuses // [])[]
      | [$pod, .name, (.restartCount | tostring), (.state.running.startedAt // (.state | keys[0]) // "-")]
      | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")]
    | if . == [] then "-" else .[] end' <<<"$out" 2>/dev/null |
    while IFS=$sep read -r pod container restarts started; do
      if [ "$pod" = - ]; then
        echo "  no pod of the operator in svp-obs" >&2
        continue
      fi
      echo "  pod svp-obs/$pod, container $container: started $started, $restarts restart(s); last lines of its log:" >&2
      { kc -n svp-obs logs "$pod" -c "$container" --tail=60 </dev/null 2>&1 || true; } | mark_log svp-obs >&2
      if [ "$restarts" != 0 ]; then
        echo "  last lines of the attempt before:" >&2
        { kc -n svp-obs logs "$pod" -c "$container" --previous --tail=60 </dev/null 2>&1 || true; } |
          mark_log svp-obs >&2
      fi
    done
}

# The seven services whose images the cluster runs, in the order the dev path builds them: web last (from the clone of
# svp-web, web_dir), since the six Go images share the Go module cache and build fast, so their errors show before the
# web build, the longest of all. Every release set (stg, prd, the records of stg) names these seven.
svp_services=(gateway user-service video-service engagement-service feed-service media-worker web)
# The services whose images this repository builds from its own tree, and whose releases its CI builds, signs and
# promotes: the six Go services. web is one of the seven releases, but its source and its releases are svp-web's.
built_services=(gateway user-service video-service engagement-service feed-service media-worker)

# dockerfile SERVICE: the Dockerfile that builds SERVICE's image (one of built_services), relative to the repository
# root.
dockerfile() {
  case $1 in
  media-worker) echo deploy/docker/media-worker.Dockerfile ;;
  *) echo deploy/docker/service.Dockerfile ;;
  esac
}

# web_build_id: prints the build id of the web image on the dev path (SVP_BUILD_ID, which Next uses as its
# deploymentId and the server as its release name): dev- and the first 12 hex digits of the SHA-256 of the list
# "<SHA-256 of the content> <path>", sorted by path, of every file the build context web_dir sends (by its
# .dockerignore, not by git: a .DS_Store git ignores counts, a tracked file .dockerignore leaves out does not) plus the
# Dockerfile (web_dockerfile), each path relative to the clone. The same context gives the same id, so the build cache
# gives the same image ID and `make k8s-up` starts no new ReplicaSet (or canary); any change of the context gives a new
# id, so two different builds never share one deploymentId through a file git does not see. A symlink counts by the
# path it points to (the context sends it as it is); file modes do not count.
#
# Only the form the clone's .dockerignore has is understood: each line (blank lines and # comments aside) is a
# one-level name pattern of letters, digits, . _ - * and ?, which, as in Docker, matches a name at the root of the
# context only and leaves out its whole tree. Any other line fails, naming it, instead of drifting from what Docker
# sends unnoticed; a new form means teaching this function the same rule in the same change.
web_build_id() {
  local dir dockerfile=Dockerfile ignore line path name pattern list kept entry
  local patterns=() entries=() files=()
  dir=$(web_dir) || return 1
  ignore=$dir/.dockerignore
  [ -f "$ignore" ] || {
    echo "web_build_id: $ignore is missing" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    case $line in
    *[!A-Za-z0-9._*?-]* | *'**'*)
      echo "web_build_id: $ignore line '$line' is not a one-level name pattern (letters, digits, . _ - * ?); teach web_build_id of deploy/k8s/lib.sh this form first" >&2
      return 1
      ;;
    esac
    patterns+=("$line")
  done <"$ignore"
  while IFS= read -r -d '' path; do
    name=${path##*/}
    kept=yes
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      # Unquoted on the right, so a glob: * and ? match a leading dot too, as Docker's matcher does.
      # shellcheck disable=SC2053
      if [[ $name == $pattern ]]; then
        kept=
        break
      fi
    done
    [ -z "$kept" ] || entries+=("$name")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
  [ ${#entries[@]} -gt 0 ] || {
    echo "web_build_id: $ignore leaves nothing of $dir in the build context" >&2
    return 1
  }
  # The Dockerfile counts once: a clone's own is usually in its context already.
  files=("${entries[@]}" "$dockerfile")
  for entry in "${entries[@]}"; do
    if [ "$entry" = "$dockerfile" ]; then
      files=("${entries[@]}")
      break
    fi
  done
  # In a subshell with pipefail, so a failed find or shasum fails the whole list. shasum prints "<hash>  <path>"; the
  # two spaces become one. find does not follow symlinks, so a symlink is hashed by its target path, never its content.
  list=$(
    set -o pipefail
    cd "$dir" || exit 1
    {
      find "${files[@]}" -type f -print0 | xargs -0 shasum -a 256 -- |
        sed 's/^\([0-9a-f]\{64\}\)  /\1 /' || exit 1
      find "${entries[@]}" -type l -print0 | while IFS= read -r -d '' path; do
        printf '%s %s\n' "$(readlink "$path" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)" "$path"
      done || exit 1
    } | LC_ALL=C sort -k2
  ) || {
    echo "web_build_id: cannot hash the files of the build context $dir" >&2
    return 1
  }
  echo "dev-$(printf '%s\n' "$list" | shasum -a 256 | cut -c1-12)"
}

# build_image SERVICE CONTEXT [WEB_BUILD_ID]: builds SERVICE's image from the source tree CONTEXT (native architecture,
# the Dockerfiles compose uses) and sets image_id to its ID, without the sha256: prefix. The web image is built from
# web_dir with web_dockerfile instead, whatever CONTEXT is, and gets SVP_BUILD_ID from web_build_id, which reads the
# same folder. WEB_BUILD_ID replaces it for a second build of the same source (make drill-k8s-web-canary): next build
# runs again with that id, so the image is another build, with its own deploymentId and Server Action ids.
build_image() {
  local args=(--file "$2/$(dockerfile "$1")") context=$2 id dir
  case $1 in
  media-worker) ;;
  web)
    dir=$(web_dir) || return 1
    id=${3:-$(web_build_id)} || return 1
    args=(--file "$(web_dockerfile "$dir")" --build-arg "SVP_BUILD_ID=$id")
    context=$dir
    ;;
  *) args+=(--build-arg "SERVICE=$1") ;;
  esac
  # --quiet prints only the image ID; a failed build still prints its error.
  image_id=$(docker_ build --quiet "${args[@]}" "$context") || return 1
  image_id=${image_id#sha256:}
}

# build_dev_images [SERVICE...]: builds the images of SERVICE... (default: the seven of svp_services) from the working
# tree (web from the clone of svp-web, build_image), pushes each to the registry as
# 127.0.0.1:5111/svp/<service>:dev-<first 12 hex digits of its image ID>, and sets dev_tag_<service with _ for -> to
# that tag. The build cache gives the same image ID for the same inputs, so a run with no code
# change yields the same tags, the pod templates do not change, and no new ReplicaSet (later: no canary) starts. Run
# after ensure_registry.
build_dev_images() {
  local svc id tag ref services=("$@")
  [ $# -gt 0 ] || services=("${svp_services[@]}")
  for svc in "${services[@]}"; do
    echo "build $svc"
    build_image "$svc" "$repo_root" || fail "build the image of $svc"
    id=$image_id
    tag="dev-${id:0:12}"
    ref="127.0.0.1:5111/svp/$svc:$tag"
    docker_ tag "$id" "$ref" || fail "tag the image of $svc as $ref"
    docker_ push --quiet "$ref" >/dev/null || fail "push $ref"
    printf -v "dev_tag_${svc//-/_}" '%s' "$tag"
    ok "$svc image $tag pushed to the registry"
  done
}

# image_paths SERVICE: the paths SERVICE's image is built from, relative to the repository root: what its Dockerfile
# copies (go.mod, go.sum, gen/, internal/, services/<service>/), the Dockerfile itself and .dockerignore, which decides
# what reaches the build. SERVICE is one of built_services: CI builds a release of SERVICE when one of them changed
# (deploy/ci/changed-services.sh).
image_paths() {
  printf '%s\n' go.mod go.sum gen internal "services/$1" "$(dockerfile "$1")" .dockerignore
}

# Release images: built, scanned and signed by CI only,
# under this prefix on GHCR, one image per service; nothing else may be pushed there. The promote pull request writes
# a release's repository, tag (first 12 hex digits of its commit, for people) and digest (what pods run) into
# envs/<env>/images/<service>.yaml of svp-gitops; the GitOps cluster pulls them anonymously by digest. The dev path
# never reads them: `make k8s-up` passes its own registry, tag and an empty digest (deploy/k8s/install.sh).
# This is the prefix of this repository's own releases; the release sources below name every prefix the cluster runs.
# shellcheck disable=SC2034 # read by the scripts that source this file
ghcr_prefix=ghcr.io/anhnvcoder/short-video-platform

# Release sources: every repository whose CI builds, signs and publishes images the GitOps path runs. Each has a name,
# its repository URL, the prefix its images live under on GHCR (ending in /), the services it publishes there (a
# service is in two sources only while it moves from one to the other), the drill images it may push there, the
# keyless identity of its images.yml on main (issuer, subject), the ref its build provenance names, and the GitHub App
# that promotes its releases (promoter). They are written once, in this file of chart svp-policy, whose policy admits
# exactly these images with these identities; the scripts read the same file, so what they check is what admission
# checks.
release_sources_file=deploy/helm/svp-policy/files/sources.json

# _release_sources_check WHERE: reads a table of release sources on stdin and prints it as compact JSON when it holds
# what the template of chart svp-policy accepts: at least one source; every field a non-empty string without a quote,
# backslash or white space (they go into CEL string literals); a name of a lowercase letter then letters and digits;
# repository, issuer and subject https:// URLs, provenanceRef a refs/... ref, imagePrefix ending in /; no two sources
# with one name or one promoter; services a non-empty list and drillImages a list of image names; no service in more
# than two sources; no prefix the start of another's (an image under both could not be told apart). Fails naming WHERE
# and the first problem otherwise.
# The jq program of _release_sources_check, kept out of $(...), which bash 3.2 misreads with these quotes inside.
_release_sources_jq='
    def plain: type == "string" and test("^[^\u0027\"\\\\\\s]+$");
    def names: type == "array" and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9._-]*$"));
    if (.sources | type) != "array" or (.sources | length) == 0 then "sources lists no release source"
    else .sources as $s
    | ([$s[] | select(type != "object"
        or ([.name, .repository, .imagePrefix, .issuer, .subject, .provenanceRef, .promoter] | all(plain) | not))
        | (.name? // "?" | tostring)] | first) as $bad
    | if $bad != null then
        "source \($bad): name, repository, imagePrefix, issuer, subject, provenanceRef and promoter must each be a string without quote, backslash or white space"
      elif any($s[]; .name | test("^[a-z][a-z0-9]*$") | not) then "a source name is not a lowercase letter then letters and digits"
      elif any($s[]; [.repository, .issuer, .subject] | all(startswith("https://")) | not)
        then "repository, issuer and subject of every source must be https:// URLs"
      elif any($s[]; .provenanceRef | startswith("refs/") | not) then "provenanceRef of every source must be a refs/... ref"
      elif any($s[]; .imagePrefix | test("^[a-z0-9.:_/-]+/$") | not) then "imagePrefix of every source must end in /"
      elif ([$s[].name] | unique | length) != ($s | length) then "two sources share a name"
      elif ([$s[].promoter] | unique | length) != ($s | length) then "two sources share a promoter"
      elif any($s[]; ((.services | names) and (.services | length) > 0 and (.drillImages | names)) | not)
        then "every source needs a non-empty list services and a list drillImages, of image names"
      elif ([$s[].services[]] | group_by(.) | any(length > 2)) then "a service is in more than two sources"
      elif any($s[] as $a | $s[] as $b | $a.name != $b.name and ($b.imagePrefix | startswith($a.imagePrefix)); .)
        then "the imagePrefix of one source starts with the imagePrefix of another"
      else "ok" end end'
_release_sources_check() {
  local table verdict
  table=$(cat)
  verdict=$(jq -r "$_release_sources_jq" <<<"$table" 2>/dev/null) || verdict="is not readable JSON"
  [ "$verdict" = ok ] || fail "release sources of $1: $verdict"
  jq -c . <<<"$table"
}

# release_sources [REV]: prints the table of release sources ({"sources": [...]}, compact JSON, checked by
# _release_sources_check) of this repository at commit REV, or of the working tree when REV is empty. A commit from
# before the table (an environment of svp-gitops may still pin one, and a rollback of prd may go back to one) gets the
# one source its policy knew, read from that commit as the scripts read it then: name backend; imagePrefix, issuer,
# subject, repository and provenanceRef from the lines imagePrefix, issuer, subject, provenanceRepository and
# provenanceRef of the policy's values.yaml; services from svp_services of deploy/k8s/lib.sh; drillImages from
# drill_images of deploy/ci/common.sh; promoter svp-gitops-promoter. Fails when REV is no commit of this clone, or
# when neither form can be read.
release_sources() {
  local rev=${1:-} table values services drills
  if [ -z "$rev" ]; then
    table=$(cat "$repo_root/$release_sources_file") || fail "read $release_sources_file"
  elif ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    fail "$rev is not a commit of this clone, so its release sources cannot be read"
  elif ! table=$(git -C "$repo_root" show "$rev:$release_sources_file" 2>/dev/null); then
    values=$(git -C "$repo_root" show "$rev:deploy/helm/svp-policy/values.yaml" 2>/dev/null) || values=
    services=$(git -C "$repo_root" show "$rev:deploy/k8s/lib.sh" 2>/dev/null | sed -n 's/^svp_services=(\(.*\))$/\1/p')
    drills=$(git -C "$repo_root" show "$rev:deploy/ci/common.sh" 2>/dev/null | sed -n 's/^drill_images=(\(.*\))$/\1/p')
    table=$(jq -n --arg values "$values" --arg services "$services" --arg drills "$drills" '
      def line($k): [$values | split("\n")[] | select(startswith("  \($k): ")) | ltrimstr("  \($k): ")] | first // "";
      def words: split(" ") | map(select(length > 0));
      {sources: [{name: "backend", repository: line("provenanceRepository"), imagePrefix: line("imagePrefix"),
        services: ($services | words), drillImages: ($drills | words), issuer: line("issuer"), subject: line("subject"),
        provenanceRef: line("provenanceRef"), promoter: "svp-gitops-promoter"}]}') ||
      fail "build the release source of ${rev:0:12}, which has no $release_sources_file"
  fi
  _release_sources_check "${rev:+${rev:0:12} }${rev:-the working tree}" <<<"$table"
}

# release_source NAME [REV]: prints source NAME of the table at REV (release_sources) as compact JSON; fails without
# one.
release_source() {
  local table src
  table=$(release_sources "${2:-}") || exit 1
  src=$(jq -c --arg n "$1" '.sources[] | select(.name == $n)' <<<"$table")
  [ -n "$src" ] || fail "no release source named $1 in $release_sources_file${2:+ at ${2:0:12}}"
  echo "$src"
}

# source_of_repository REPOSITORY [REV]: prints the name of the release source whose imagePrefix REPOSITORY lies
# under, in the table at REV (at most one: no prefix starts another); fails without one.
source_of_repository() {
  local table name
  table=$(release_sources "${2:-}") || exit 1
  name=$(jq -r --arg r "$1" '.sources[] | .imagePrefix as $p | select($r | startswith($p)) | .name' <<<"$table")
  [ -n "$name" ] || fail "$1 is under the prefix of no release source of $release_sources_file${2:+ at ${2:0:12}}"
  echo "$name"
}

# release_source_of SERVICE REPOSITORY [REV]: prints, as compact JSON, the release source in the table at REV of
# which REPOSITORY is SERVICE's image: <imagePrefix>SERVICE of a source whose services name SERVICE, what the policy
# admits for that service. Status 1, printing nothing, when REPOSITORY is none of them (release_repositories names
# what would be).
release_source_of() {
  local table src
  table=$(release_sources "${3:-}") || exit 1
  src=$(jq -c --arg s "$1" --arg r "$2" '.sources[] | select((.services | index($s)) and .imagePrefix + $s == $r)' \
    <<<"$table")
  [ -n "$src" ] || return 1
  echo "$src"
}

# release_repositories SERVICE [REV]: prints the repositories SERVICE's releases may come from in the table at REV,
# joined by " or " (empty when no source publishes SERVICE).
release_repositories() {
  local table
  table=$(release_sources "${2:-}") || exit 1
  jq -r --arg s "$1" '[.sources[] | select(.services | index($s)) | .imagePrefix + $s] | join(" or ")' <<<"$table"
}

# values_field FIELD: reads a service's values file on stdin and prints image.FIELD (repository, tag or digest)
# without quotes, "" when empty. Only the shape these files have is read: exactly one line `  FIELD: <value>` inside
# the top-level `image:` block, the value bare or in double quotes, no comment after it, and of FIELD's form:
# repository [0-9a-z.:/_-]*, tag empty or 12 lowercase hex digits (a commit), digest empty or sha256:<64 hex>. Anything
# else fails, naming the problem on stderr, rather than guess: the result goes to a registry, to cosign and to git.
# Exit status: 3 no such line, 4 the line twice, 5 a value of the wrong form.
values_field() {
  local form value rc=0
  case $1 in
  repository) form='^[0-9a-z.:/_-]*$' ;;
  tag) form='^([0-9a-f]{12})?$' ;;
  digest) form='^(sha256:[0-9a-f]{64})?$' ;;
  *) fail "values_field: unknown field '$1'" ;;
  esac
  # awk only finds the line; the form is checked by bash, whose regular expressions are the same on macOS and on the
  # Ubuntu runner (awk's interval expressions are not).
  value=$(awk -v key="$1" '
    /^image:/ { block = 1; next }
    /^[^ #]/ { block = 0 }
    block && $0 ~ "^  " key ":" {
      v = $0
      sub("^  " key ":[ ]*", "", v)
      if (v ~ /^"[^"]*"$/) v = substr(v, 2, length(v) - 2)
      out = v
      found++
    }
    END {
      if (found == 0) exit 3
      if (found > 1) exit 4
      print out
    }') || rc=$?
  [ "$rc" != 0 ] || [[ $value =~ $form ]] || rc=5
  case $rc in
  0)
    echo "$value"
    return 0
    ;;
  3) echo "image.$1: no line '  $1: ...' in the image block" >&2 ;;
  4) echo "image.$1: more than one line '  $1: ...' in the image block" >&2 ;;
  5) echo "image.$1: '$value' does not have the form $form" >&2 ;;
  *) echo "image.$1: cannot read the values" >&2 ;;
  esac
  return "$rc"
}

# values_set_image REPOSITORY TAG DIGEST: reads a service's values file on stdin and prints it with image.repository,
# image.tag and image.digest set to these values, every other line as it was. The three lines must already be there,
# once each (values_field's rule), and the result must read back as exactly these values, or nothing is printed and it
# fails. The tag and the digest are written in double quotes: a tag of 12 decimal digits would otherwise be a YAML
# number.
values_set_image() {
  local out field want
  out=$(awk -v repo="$1" -v tag="$2" -v digest="$3" '
    /^image:/ { block = 1; buf = buf $0 "\n"; next }
    /^[^ #]/ { block = 0 }
    block && /^  repository:/ { n["repository"]++; buf = buf "  repository: " repo "\n"; next }
    block && /^  tag:/ { n["tag"]++; buf = buf "  tag: \"" tag "\"\n"; next }
    block && /^  digest:/ { n["digest"]++; buf = buf "  digest: \"" digest "\"\n"; next }
    { buf = buf $0 "\n" }
    END {
      if (n["repository"] != 1 || n["tag"] != 1 || n["digest"] != 1) exit 3
      printf "%s", buf
    }' && echo x) || {
    echo "image: repository, tag and digest are not one line each in the image block" >&2
    return 1
  }
  # The x keeps the last newline, which command substitution would drop.
  out=${out%x}
  for field in repository tag digest; do
    case $field in repository) want=$1 ;; tag) want=$2 ;; digest) want=$3 ;; esac
    [ "$(values_field "$field" <<<"$out")" = "$want" ] || {
      echo "image.$field: '$want' cannot be written as a value of that form" >&2
      return 1
    }
  done
  printf '%s' "$out"
}

# ghcr_manifest_status NAME DIGEST: prints the HTTP status GHCR answers an anonymous HEAD of manifest NAME@DIGEST
# with (NAME without ghcr.io/), as a node pulling without credentials gets it: 200 when it can pull it. A package that
# is private or does not exist is refused already by the token endpoint (403), whose status is printed then. 000 when
# GHCR cannot be reached.
ghcr_manifest_status() {
  local resp code token
  resp=$(curl -s --max-time 10 -w '\n%{http_code}' "https://ghcr.io/token?scope=repository:$1:pull&service=ghcr.io") ||
    resp=$'\n000'
  code=${resp##*$'\n'}
  if [ "$code" != 200 ]; then
    echo "$code"
    return 0
  fi
  token=$(jq -r '.token // empty' <<<"${resp%$'\n'*}" 2>/dev/null) || token=
  curl -s --max-time 10 -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/$1/manifests/$2" || true
}

# release_image SERVICE WHERE: reads SERVICE's image file on stdin (WHERE names it in messages, such as
# "envs/stg/images/gateway.yaml at 1a2b3c4d5e6f") and prints REPOSITORY@DIGEST of the release it names
# once the GitOps cluster can pull it: image.digest set (the promote pull request writes it), image.repository
# SERVICE's image of a release source that publishes SERVICE (release_source_of, the working tree's table), and that
# manifest served to an anonymous pull by GHCR. Fails naming the cause
# otherwise; creates nothing. Whether the release carries a signature and a fresh vuln attestation is
# deploy/ci/verify-release.sh's check.
release_image() {
  local svc=$1 where=$2 values repo digest code
  values=$(cat)
  digest=$(values_field digest <<<"$values") ||
    fail "$svc: no release in $where (image.digest above); the promote pull request of svp-gitops writes it: once it is merged, fetch the clone and run again"
  [ -n "$digest" ] ||
    fail "$svc: image.digest is empty in $where: $svc has no release there yet; once the promote pull request of svp-gitops is merged, fetch the clone and run again"
  repo=$(values_field repository <<<"$values") || fail "$svc: cannot read image.repository in $where (above)"
  release_source_of "$svc" "$repo" >/dev/null ||
    fail "$svc: image.repository is '$repo' in $where; the GitOps path runs only releases of $(release_repositories "$svc")"
  code=$(ghcr_manifest_status "${repo#ghcr.io/}" "$digest")
  case $code in
  200) ;;
  401 | 403 | 404)
    fail "$svc: GHCR refuses an anonymous pull of $repo@$digest (HTTP $code): package $repo is not public yet (GitHub: Package settings > Change visibility) or holds no such digest"
    ;;
  *) fail "$svc: GHCR did not answer for $repo@$digest (HTTP ${code:-none}); check the network and run again" ;;
  esac
  echo "$repo@$digest"
}

# stg_release SERVICE: prints REPOSITORY@DIGEST of SERVICE's release in staging: envs/stg/images/SERVICE.yaml in the
# working tree of the clone of svp-gitops (gitops_dir), read as it is (never fetched: pull that clone for the newest),
# checked by release_image (repository, digest, anonymous pull from GHCR).
stg_release() {
  local gitops file
  gitops=$(gitops_dir) || exit 1
  file=$gitops/envs/stg/images/$1.yaml
  [ -f "$file" ] || fail "$1: $file not found, so staging names no release of $1 in that clone"
  release_image "$1" "envs/stg/images/$1.yaml of svp-gitops at $(gitops_at "$gitops")" <"$file"
}

# gitops_at DIR: the commit the clone DIR of svp-gitops is at, and whether envs/stg/images/ differs from it there.
gitops_at() {
  local sha
  sha=$(git -C "$1" rev-parse HEAD) || fail "read the commit of $1"
  if [ -n "$(git -C "$1" status --porcelain -- envs/stg/images)" ]; then
    echo "$sha with uncommitted changes in envs/stg/images/"
  else
    echo "$sha"
  fi
}

# web_source: what the web client of `make up` and `make k8s-up` runs, from WEB_FROM: stg (the default when unset) runs
# the release staging runs (stg_release web); clone builds its image from web_dir, the clone of svp-web; image runs
# WEB_IMAGE, a release given as ghcr.io/<repository>@sha256:<digest>, which GHCR must serve to an anonymous pull as the
# nodes and compose pull it. Sets web_release to REPOSITORY@DIGEST of that release, empty when the image is built. A
# release keeps the SVP_BUILD_ID CI built it with and is never built here, so the targets that build the source maps of
# the web (make web-sourcemaps, and make k8s-web-sourcemaps without SOURCEMAPS_DIR) do not apply to it.
web_source() {
  local repo code
  web_release=
  case ${WEB_FROM:-stg} in
  clone | stg)
    [ -z "${WEB_IMAGE:-}" ] || fail "WEB_IMAGE is set, but WEB_FROM is ${WEB_FROM:-stg}: set WEB_FROM=image to run it, or unset it"
    [ "${WEB_FROM:-stg}" = clone ] || web_release=$(stg_release web) || exit 1
    ;;
  image)
    [[ ${WEB_IMAGE:-} =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] ||
      fail "WEB_FROM=image needs WEB_IMAGE=ghcr.io/<repository>@sha256:<64 hex digits> (got '${WEB_IMAGE:-}')"
    repo=${WEB_IMAGE%@*}
    code=$(ghcr_manifest_status "${repo#ghcr.io/}" "${WEB_IMAGE#*@}")
    [ "$code" = 200 ] ||
      fail "GHCR does not serve $WEB_IMAGE to an anonymous pull (HTTP ${code:-none}): no such digest, a package that is not public, or no network"
    web_release=$WEB_IMAGE
    ;;
  *)
    fail "WEB_FROM='$WEB_FROM' is not valid: stg (default: the release staging runs), clone (build from the clone of svp-web) or image (WEB_IMAGE)"
    ;;
  esac
}

# compose_images: exports what deploy/compose/compose.yaml reads to pick the images of the application for `make up`
# and `make compose-config`. IMAGES unset: the six backend services are built from the working tree, as they always
# were; IMAGES=stg: they run their releases in staging (stg_release), their migrations the same images, so a stack of
# this checkout runs exactly what staging runs, with no Go build. The web client as web_source says: built from
# web_dir (its folder and Dockerfile), or a release. A release runs as already pulled (compose_up_images): pull policy
# never, so compose neither pulls nor builds it. Sets compose_releases to every REPOSITORY@DIGEST to pull and
# compose_notes to one line per choice; prints nothing.
compose_images() {
  local svc var ref dir gitops
  compose_releases=() compose_notes=()
  case ${IMAGES:-} in
  '')
    for svc in "${built_services[@]}"; do
      var=SVP_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')_IMAGE
      export "$var=svp/$svc:dev"
    done
    export SVP_BACKEND_PULL_POLICY=build
    compose_notes+=("the six backend services built from the working tree")
    ;;
  stg)
    for svc in "${built_services[@]}"; do
      var=SVP_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')_IMAGE
      ref=$(stg_release "$svc") || exit 1
      export "$var=$ref"
      compose_releases+=("$ref")
    done
    export SVP_BACKEND_PULL_POLICY=never
    gitops=$(gitops_dir) || exit 1
    compose_notes+=("the six backend services and their migrations run the releases of staging, envs/stg/images/ of svp-gitops at $(gitops_at "$gitops")")
    ;;
  *)
    fail "IMAGES='$IMAGES' is not valid: leave it unset (build the six backend services from the working tree) or stg (run their releases in staging)"
    ;;
  esac
  web_source
  if [ -n "$web_release" ]; then
    # Never built in this mode, but compose checks that a build context exists: any folder of the checkout will do.
    export SVP_WEB_IMAGE=$web_release SVP_WEB_PULL_POLICY=never SVP_WEB_CONTEXT=$repo_root/deploy/compose
    compose_releases+=("$web_release")
    compose_notes+=("web runs release $web_release, with the build id CI gave it: make web-sourcemaps does not apply")
  else
    dir=$(web_dir) || exit 1
    export SVP_WEB_IMAGE=svp/web:dev SVP_WEB_PULL_POLICY=build SVP_WEB_CONTEXT=$dir
    export SVP_WEB_DOCKERFILE
    SVP_WEB_DOCKERFILE=$(web_dockerfile "$dir")
    compose_notes+=("web built from $dir")
  fi
}

# compose_up_images: compose_images, then pulls every release for this machine's own architecture (docker without
# DOCKER_DEFAULT_PLATFORM picks it from the multi-architecture index), so that a release that cannot be pulled stops
# `make up` before anything starts, and prints the choices.
compose_up_images() {
  local ref note
  compose_images
  for ref in ${compose_releases[@]+"${compose_releases[@]}"}; do
    echo "pull $ref"
    docker_ pull --quiet "$ref" >/dev/null || fail "pull $ref"
  done
  for note in "${compose_notes[@]}"; do ok "$note"; done
}
