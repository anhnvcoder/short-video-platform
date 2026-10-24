# shellcheck shell=bash
# Helpers shared by the scripts and make targets of the local Kubernetes cluster `svp` (deploy/k8s/, deploy/k8s/k8s.mk):
# the pinned docker/k3d/kubectl/helm calls, bounded waits, the registry and the cluster themselves, the CA export.
# Written for bash 3.2 (the macOS /bin/bash). Sourcing it only defines things and exports the variables below.
#
# Rules every helper keeps: docker and k3d run without DOCKER_DEFAULT_PLATFORM (the global shell sets linux/amd64 for
# another project; the nodes must run native arm64), kubectl and helm always name the context k3d-svp (the current
# context may be another cluster), every wait has a deadline, no Secret value is ever printed.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# k3d's own helper images, pinned by digest (multi-arch index): k3d otherwise picks them by its version tag
# (docs/adr/0014-kubernetes-local-stage4.md, section 1).
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-proxy
export K3D_IMAGE_LOADBALANCER=ghcr.io/k3d-io/k3d-proxy:5.9.0@sha256:7be40abfeb6ac9a81d0d4157a7cbf3aacc68a64a1780ca2efb160f1aea915177
# renovate: datasource=docker depName=ghcr.io/k3d-io/k3d-tools
export K3D_IMAGE_TOOLS=ghcr.io/k3d-io/k3d-tools:5.9.0@sha256:c57abce697e66feeb826922718738fe186b47779312d49d4e51e6fb9b8a6f34d
# The local registry (ADR-0014 section 6): k3d prefixes the name, so the container is k3d-svp-registry; inside it listens on
# 5000, published on 127.0.0.1:5111 only.
# renovate: datasource=docker depName=docker.io/library/registry
registry_image=docker.io/library/registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
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

# port_free PORT: true when nothing accepts connections on 127.0.0.1:PORT. The lab's ports are fixed (ADR-0014 sections 2
# and 6), so a taken port is an error to report, never a reason to pick another.
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
    # Pod Security "restricted" by default (ADR-0014 section 3) exists only in a cluster created with it: the argument and
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
# into.
secret() {
  local ns=$1 name=$2 type=$3 kv
  shift 3
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "$name" "$ns"
  if [ -n "${label:-}" ]; then printf '  labels:\n    %s\n' "$label"; fi
  printf 'type: %s\ndata:\n' "$type"
  for kv in "$@"; do
    printf '  %s: %s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | base64 | tr -d '\n')"
  done
}

# argocd_root_app REPO_URL REVISION: prints the root Application svp-root of the GitOps path, as JSON for
# `kc apply -f -`: chart deploy/argocd/apps of REPO_URL at REVISION, which hands the same revision to every Application
# it makes (its value targetRevision). Built by jq from --arg values, so the revision is always a JSON string: a
# branch named 2026, true or 1e3 written into YAML as it is would be read as a number or a boolean, which the
# Application CRD refuses (targetRevision is a string).
#
# The root compares with Argo CD's default diff, not with the server-side diff the controller uses for every other
# Application (deploy/k8s/values/argo-cd.yaml): the root applies its child Applications client-side (no
# ServerSideApply=true), so their fields belong to a field manager of operation Update. A server-side dry run is an
# Apply, which never removes a field another manager entry owns: a field deleted from chart deploy/argocd/apps (an
# ignoreDifferences, a retry block, managedNamespaceMetadata) would stay in the predicted and the live Application
# alike, so the root would stay Synced and the child keep the field for good. The default diff compares with the
# kubectl.kubernetes.io/last-applied-configuration annotation of a client-side apply and sees the deletion. The
# children apply their own objects server-side (ServerSideApply=true), for which the server-side diff is right.
argocd_root_app() {
  jq -n --arg repo "$1" --arg rev "$2" '{
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
        path: "deploy/argocd/apps",
        helm: {valuesObject: {targetRevision: $rev}}
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
# it selects, not by that name, which is Kyverno's to change (docs/adr/0015-cicd-devsecops-stage5.md, section 8).
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
# renders as one: docs/adr/0014-kubernetes-local-stage4.md, section 13), deployment otherwise. Before Argo Rollouts is
# installed the kind does not exist and the answer is deployment.
workload_kind() {
  if kc -n "$1" get rollouts.argoproj.io "$2" >/dev/null 2>&1; then echo rollout; else echo deployment; fi
}

# restart_workload NAMESPACE NAME: restarts the pods of Deployment or Rollout NAME without a new revision and waits
# until the new pods are ready. A Deployment: `kubectl rollout restart`, which stamps its pod template (a rolling
# update). A Rollout: not that, since any change of its template is a new revision and so a canary; spec.restartAt
# instead, which Argo Rollouts reads as "evict every pod created before this time", one at a time and through the
# PodDisruptionBudget, the template unchanged. It is done once status.restartedAt equals it and the Rollout is Healthy.
# restartAt is a field no chart writes, so neither Helm nor Argo CD puts it back.
restart_workload() {
  local ns=$1 name=$2 at
  if [ "$(workload_kind "$ns" "$name")" = rollout ]; then
    at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    kc -n "$ns" patch rollout "$name" --type merge -p "{\"spec\":{\"restartAt\":\"$at\"}}" >/dev/null ||
      fail "restart rollout $ns/$name (spec.restartAt)"
    wait_until 300 "rollout $ns/$name restarted (status.restartedAt $at) and Healthy" \
      test_output "$at Healthy" kc -n "$ns" get rollout "$name" -o jsonpath='{.status.restartedAt} {.status.phase}'
  else
    kc -n "$ns" rollout restart deployment "$name" >/dev/null || fail "restart deployment $ns/$name"
    kc -n "$ns" rollout status deployment "$name" --timeout=300s >/dev/null ||
      fail "deployment $ns/$name ready again within 300s of its restart"
  fi
}

# test_output WANT COMMAND...: true when COMMAND prints exactly WANT.
test_output() {
  local want=$1 got
  shift
  got=$("$@") || return 1
  [ "$got" = "$want" ]
}

# pg_backup NAME: creates Backup svp-data/NAME of Postgres svp-pg, a base backup by the Barman Cloud plugin into the
# archive generation the Cluster archives to (docs/adr/0020-reliability-stage6.md, section 5), owned by nothing, so
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

# The seven services whose images the cluster runs, in the order they are built: web last, since the six Go images
# share the Go module cache and build fast, so their errors show before the web build, the longest of all.
svp_services=(gateway user-service video-service engagement-service feed-service media-worker web)

# dockerfile SERVICE: the Dockerfile that builds SERVICE's image, relative to the repository root.
dockerfile() {
  case $1 in
  media-worker) echo deploy/docker/media-worker.Dockerfile ;;
  web) echo deploy/docker/web.Dockerfile ;;
  *) echo deploy/docker/service.Dockerfile ;;
  esac
}

# build_context SERVICE: the directory SERVICE's image is built from, relative to the repository root. The Go images
# need the whole module (go.mod, gen/, internal/); the web image only web/, whose own .dockerignore decides what
# reaches the build, as compose builds it.
build_context() {
  if [ "$1" = web ]; then echo web; else echo .; fi
}

# web_build_id: prints the build id of the web image on the dev path (SVP_BUILD_ID, which Next uses as its
# deploymentId and the server as its release name): dev- and the first 12 hex digits of the SHA-256 of the list
# "<SHA-256 of the content> <path>", sorted by path, of every file the build context web/ sends (by web/.dockerignore,
# not by git: a .DS_Store git ignores counts, a tracked file .dockerignore leaves out does not) plus the Dockerfile.
# The same context gives the same id, so the build cache gives the same image ID and `make k8s-up` starts no new
# ReplicaSet (or canary); any change of the context gives a new id, so two different builds never share one
# deploymentId through a file git does not see. A symlink counts by the path it points to (the context sends it as it
# is); file modes do not count.
#
# Only the form web/.dockerignore has is understood: each line (blank lines and # comments aside) is a one-level name
# pattern of letters, digits, . _ - * and ?, which, as in Docker, matches a name at the root of the context only and
# leaves out its whole tree. Any other line fails, naming it, instead of drifting from what Docker sends unnoticed;
# a new form means teaching this function the same rule in the same change.
web_build_id() {
  local ignore=$repo_root/web/.dockerignore line path name pattern list kept
  local patterns=() entries=()
  [ -f "$ignore" ] || {
    echo "web_build_id: $ignore is missing" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    case $line in
    *[!A-Za-z0-9._*?-]* | *'**'*)
      echo "web_build_id: web/.dockerignore line '$line' is not a one-level name pattern (letters, digits, . _ - * ?); teach web_build_id of deploy/k8s/lib.sh this form first" >&2
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
    [ -z "$kept" ] || entries+=("web/$name")
  done < <(find "$repo_root/web" -mindepth 1 -maxdepth 1 -print0)
  [ ${#entries[@]} -gt 0 ] || {
    echo "web_build_id: web/.dockerignore leaves nothing of web/ in the build context" >&2
    return 1
  }
  # In a subshell with pipefail, so a failed find or shasum fails the whole list. shasum prints "<hash>  <path>"; the
  # two spaces become one. find does not follow symlinks, so a symlink is hashed by its target path, never its content.
  list=$(
    set -o pipefail
    cd "$repo_root" || exit 1
    {
      find "${entries[@]}" deploy/docker/web.Dockerfile -type f -print0 | xargs -0 shasum -a 256 -- |
        sed 's/^\([0-9a-f]\{64\}\)  /\1 /' || exit 1
      find "${entries[@]}" -type l -print0 | while IFS= read -r -d '' path; do
        printf '%s %s\n' "$(readlink "$path" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)" "$path"
      done || exit 1
    } | LC_ALL=C sort -k2
  ) || {
    echo "web_build_id: cannot hash the files of the build context web/" >&2
    return 1
  }
  echo "dev-$(printf '%s\n' "$list" | shasum -a 256 | cut -c1-12)"
}

# build_image SERVICE CONTEXT: builds SERVICE's image from the source tree CONTEXT (native architecture, the
# Dockerfiles compose uses) and sets image_id to its ID, without the sha256: prefix. The web image gets SVP_BUILD_ID
# from web_build_id, which reads the working tree: build_dev_images passes that tree as CONTEXT.
build_image() {
  local args=(--file "$2/$(dockerfile "$1")") id
  case $1 in
  media-worker) ;;
  web)
    id=$(web_build_id) || return 1
    args+=(--build-arg "SVP_BUILD_ID=$id")
    ;;
  *) args+=(--build-arg "SERVICE=$1") ;;
  esac
  # --quiet prints only the image ID; a failed build still prints its error.
  image_id=$(docker_ build --quiet "${args[@]}" "$2/$(build_context "$1")") || return 1
  image_id=${image_id#sha256:}
}

# build_dev_images: builds the seven images from the working tree, pushes each to the registry as
# 127.0.0.1:5111/svp/<service>:dev-<first 12 hex digits of its image ID>, and sets dev_tag_<service with _ for -> to
# that tag (ADR-0014 section 6). The build cache gives the same image ID for the same inputs, so a run with no code
# change yields the same tags, the pod templates do not change, and no new ReplicaSet (later: no canary) starts. Run
# after ensure_registry.
build_dev_images() {
  local svc id tag ref
  for svc in "${svp_services[@]}"; do
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
# what reaches the build. The web image is built from web/ alone (its .dockerignore inside it) and its Dockerfile, so
# a change of go.mod, internal/ or the root .dockerignore does not build it, and a change under web/ builds only it.
# CI builds a release of SERVICE when one of them changed (deploy/ci/changed-services.sh).
image_paths() {
  if [ "$1" = web ]; then
    printf '%s\n' web "$(dockerfile web)"
  else
    printf '%s\n' go.mod go.sum gen internal "services/$1" "$(dockerfile "$1")" .dockerignore
  fi
}

# Release images (docs/adr/0015-cicd-devsecops-stage5.md, sections 5 and 9): built, scanned and signed by CI only,
# under this prefix on GHCR, one image per service; nothing else may be pushed there. The promote pull request writes
# a release's repository, tag (first 12 hex digits of its commit, for people) and digest (what pods run) into
# deploy/k8s/values/services/<service>.yaml; the GitOps cluster pulls them anonymously by digest. The dev path never
# reads them: `make k8s-up` passes its own registry, tag and an empty digest (deploy/k8s/install.sh).
# shellcheck disable=SC2034 # read by the scripts that source this file
ghcr_prefix=ghcr.io/anhnvcoder/short-video-platform

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

# release_image SERVICE WHERE: reads SERVICE's values file on stdin (WHERE names it in messages, such as
# "deploy/k8s/values/services/gateway.yaml at 1a2b3c4d5e6f") and prints REPOSITORY@DIGEST of the release it names
# once the GitOps cluster can pull it: image.digest set (the promote pull request writes it), image.repository
# exactly $ghcr_prefix/SERVICE, and that manifest served to an anonymous pull by GHCR. Fails naming the cause
# otherwise; creates nothing. Whether the release carries a signature and a fresh vuln attestation is
# deploy/ci/verify-release.sh's check.
release_image() {
  local svc=$1 where=$2 values repo digest code
  values=$(cat)
  digest=$(values_field digest <<<"$values") ||
    fail "$svc: no release in $where (image.digest above); the promote pull request (branch bot/promote) writes it: merge it on GitHub, fetch, and run again"
  [ -n "$digest" ] ||
    fail "$svc: image.digest is empty in $where: $svc has no release there yet; merge the promote pull request (branch bot/promote) on GitHub, fetch, and run again"
  repo=$(values_field repository <<<"$values") || fail "$svc: cannot read image.repository in $where (above)"
  [ "$repo" = "$ghcr_prefix/$svc" ] ||
    fail "$svc: image.repository is '$repo' in $where; the GitOps path runs only releases of $ghcr_prefix/$svc"
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
