#!/usr/bin/env bash
# Installs or upgrades every component of deploy/argocd/apps/components.json into the running cluster svp, in
# ascending wave order (files order within a wave), with `helm upgrade --install --wait`: the dev path of
# docs/adr/0014-kubernetes-local-stage4.md, section 7. The GitOps path builds Argo CD Applications from the same file,
# so both install the same charts, versions and values.
#
# A component is an upstream chart (repo + chart + version; a Helm OCI repository is written oci://...) or a chart in
# this repository (path), with an optional values file relative to the repository root. Run by `make k8s-up` after the
# registry and the cluster exist; running it again only upgrades what changed.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"

components="$repo_root/deploy/argocd/apps/components.json"
command -v jq >/dev/null || fail "jq not found (brew install jq)"
kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
# A cluster made by `make k8s-gitops-up` belongs to Argo CD: Helm releases installed over its Applications would be
# reverted by its self-heal, or fight it on every sync. It changes through git (deploy/k8s/gitops.sh says how a
# changed .env reaches it).
if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then
  fail "cluster svp is managed by Argo CD (Application argocd/svp-root): change it through git, or start over on the dev path with make k8s-down && make k8s-up"
fi

# The services' images first, so a build that fails stops the run before anything is installed. Each release of
# chart svp-service then gets its image with --set (never written to a file): the local registry, the service's dev
# tag and an empty digest (image_sets). The repository, tag and digest in deploy/k8s/values/services/ name releases on
# GHCR for the GitOps path (docs/adr/0015-cicd-devsecops-stage5.md, section 9); this path neither reads nor pulls them.
service_chart=deploy/helm/svp-service
build_dev_images

# image_sets SERVICE: sets the array image_sets to the --set flags of SERVICE's dev image. The upgrade and canary_ahead
# both use them, so the template canary_ahead compares is the one the upgrade applies: any difference there would be
# a new revision of the gateway, a canary of unchanged code.
image_sets() {
  local tag_var="dev_tag_${1//-/_}"
  [ -n "${!tag_var:-}" ] || fail "no image was built for $1 (not in svp_services of deploy/k8s/lib.sh)"
  image_sets=(--set "image.repository=k3d-svp-registry:5111/svp/$1" --set "image.tag=${!tag_var}" --set "image.digest=")
}

# A process reads the Secret it gets as environment variables only when it starts, and nothing restarts a pod when
# that Secret changes; no chart can roll its pods by a checksum of the Secret in the pod template either, since
# deploy/k8s/secrets.sh makes these Secrets outside Helm and Argo CD. So once a service's release is installed, its
# Deployment is restarted here if <service>-env changed since its pods read it (restart_on_secret_change of
# deploy/k8s/lib.sh). Not earlier: the services' releases come after svp-data, whose init Jobs have set the passwords
# of .env in Postgres, MinIO and Redpanda by then; a pod restarted before that would start with a password its backend
# does not take yet, and never get ready.
#
# The KEDA operator likewise keeps the Kafka scaler it built with Secret keda/keda-kafka, and its connections logged in
# as svp-keda, for as long as they work; nothing makes it read a changed Secret at once. It is restarted after
# svp-data, once the init Job has set svp-keda's new password in Redpanda.

# The migrate Job of chart svp-service restarts its container inside one pod (restartPolicy OnFailure, see the
# chart), and once the Job fails the Job controller deletes that pod and its log with it: Helm then reports only
# BackoffLimitExceeded. watch_migrate NAMESPACE JOB OLD_UID runs in the background while a service's release installs
# and copies the log of the Job's latest failed attempt to $migrate_log every 2 s, while the pod is there; OLD_UID is
# the Job of the previous run, which Helm replaces, and is not read. It ends with this script.
migrate_log=$(mktemp)
trap 'rm -f "$migrate_log"; stop_canary_traffic' EXIT
watch_migrate() {
  local ns=$1 job=$2 old=$3 state uid out
  while kill -0 $$ 2>/dev/null && sleep 2; do
    state=$(kc -n "$ns" get job "$job" -o jsonpath='{.metadata.uid} {.status.active}' 2>/dev/null) || continue
    uid=${state% *}
    # Only a pod that still runs or waits to restart keeps the log of its previous attempt.
    if [ "$uid" = "$old" ] || [ "${state#* }" != 1 ]; then continue; fi
    out=$(kc -n "$ns" logs -l "batch.kubernetes.io/controller-uid=$uid" --previous --tail=40 2>/dev/null) || continue
    # Once the pod is being deleted the kubelet answers with this line instead of the log; the copy already kept is
    # the one to print.
    case $out in "" | "unable to retrieve container logs"*) continue ;; esac
    printf '%s\n' "$out" >"$migrate_log"
  done
}

# The gateway is an Argo Rollouts Rollout (docs/adr/0014-kubernetes-local-stage4.md, section 13): an upgrade that
# changes its pod template (new code, or a value a drill left in the release) is a new revision, which goes out as a
# canary only when Envoy has measured enough responses of it, and helm --wait does not know Rollouts. So when the
# Rollout already exists and a canary is ahead (canary_ahead), drill traffic (deploy/k8s/drills/traffic.sh) runs
# before the gateway's upgrade, the upgrade is followed by wait_rollout, and the traffic stops once that is over, a
# failure included (the EXIT trap). An upgrade that leaves the template alone makes no revision (the dev tags follow
# the image ID) and starts no traffic. Traffic that was already running (make k8s-traffic-start) is used and left
# running; only the pid this script started is stopped.
traffic=$repo_root/deploy/k8s/drills/traffic.sh
own_traffic=
start_canary_traffic() {
  local running
  if running=$("$traffic" status); then
    ok "drill traffic already running (pid ${running%% *}); used for the canary of $1 and left running"
    return 0
  fi
  SVP_STACK=k3d CURL_CA_BUNDLE="$repo_root/.k8s/ca.crt" "$traffic" start || fail "start drill traffic for the canary of $1"
  running=$("$traffic" status) || fail "drill traffic for the canary of $1 not running after its start"
  own_traffic=${running%% *}
}
stop_canary_traffic() {
  local running
  [ -n "$own_traffic" ] || return 0
  if running=$("$traffic" status) && [ "${running%% *}" = "$own_traffic" ]; then "$traffic" stop || true; fi
  own_traffic=
}

# canary_ahead NAMESPACE NAME VALUES SET...: false only when the coming upgrade of release NAME (chart svp-service,
# values file VALUES, the image flags SET... of image_sets) renders Rollout NAME exactly as the release's current
# revision does and that Rollout is Healthy: no canary will run, so no drill traffic is started (each start registers
# users and deletes the register rate limit keys). A Rollout that differs in anything, or whose canary is in progress,
# paused or aborted, counts as a canary ahead. The chart reads nothing from the cluster, so `helm template` renders
# what the upgrade will.
canary_ahead() {
  local ns=$1 name=$2 values=$3 new old
  shift 3
  [ "$(kc -n "$ns" get rollout "$name" -o jsonpath='{.status.phase}')" = Healthy ] || return 0
  new=$(hc template "$name" "$repo_root/$service_chart" --namespace "$ns" --values "$values" "$@" | rollout_doc) ||
    return 0
  old=$(hc get manifest "$name" --namespace "$ns" | rollout_doc) || return 0
  [ -z "$new" ] || [ "$new" != "$old" ]
}

# rollout_doc: the document of kind Rollout in the rendered manifest on stdin, whose documents start with a --- line.
# awk runs its END rule after exit too, so the document is printed once, there.
rollout_doc() {
  awk '/^---/ { if (r) exit; d = ""; next } { d = d $0 "\n" } /^kind: Rollout$/ { r = 1 } END { if (r) printf "%s", d }'
}

# way_out NAMESPACE NAME ABORTED: how to leave a canary wait_rollout gave up on, printed before it fails. A canary not
# aborted (ABORTED false) keeps its weight, and its pods their share of the requests, until it is. The lab pins no
# kubectl-argo-rollouts plugin (docs/adr/0014-kubernetes-local-stage4.md, section 1): its abort and retry are these
# patches of the Rollout's status subresource, which kubectl makes as well.
way_out() {
  local patch="kubectl --context k3d-svp -n $1 patch rollout $2 --subresource status --type merge -p"
  if [ "$3" != true ]; then
    echo "      every request back to the stable pods (abort): $patch '{\"status\":{\"abort\":true}}'" >&2
  fi
  echo "      then fix the cause and run make k8s-up again (a new pod template is a new canary), or run this revision's" \
    "canary again (an analysis failed by noise): make k8s-traffic-start; $patch '{\"status\":{\"abort\":false}}';" \
    "make k8s-up; make k8s-traffic-stop" >&2
}

# wait_rollout NAMESPACE NAME: once the controller has seen the Rollout's current generation, waits until it is
# Healthy: at once when the upgrade made no new revision (or one whose template is the stable one again), otherwise
# after the canary's steps (25%, 60 s, 50%, 60 s, 100%) with its background analysis, about 3 minutes. Fails when the
# canary is aborted (its AnalysisRun failed, or a step passed the progress deadline) or paused by an inconclusive
# AnalysisRun, which never promotes on its own, and names the AnalysisRun; also after 900 s, beyond the progress
# deadline of 600 s. Each failure first prints the way out (way_out). The progress lines and an abort name the
# background AnalysisRun; an inconclusive pause names the run that is Inconclusive, the gate step's
# (currentStepAnalysisRunStatus) or the background one, since either pauses the Rollout.
wait_rollout() {
  local ns=$1 name=$2 deadline=$((SECONDS + 900)) json gen obs phase abort reasons step weight run hash irun last=
  while :; do
    json=$(kc -n "$ns" get rollout "$name" -o json) || fail "read rollout $ns/$name"
    IFS=$'\t' read -r gen obs phase abort reasons step weight run hash irun <<<"$(jq -r '[
      .metadata.generation, (.status.observedGeneration // "-"), (.status.phase // "-"), (.status.abort // false),
      ([.status.pauseConditions[]?.reason] | join(",") | if . == "" then "-" else . end),
      (.status.currentStepIndex // "-"), (.status.canary.weights.canary.weight // 0),
      (.status.canary.currentBackgroundAnalysisRunStatus.name // "-"), (.status.currentPodHash // "-"),
      ([.status.canary.currentStepAnalysisRunStatus, .status.canary.currentBackgroundAnalysisRunStatus]
        | map(select(. != null)) | map(select(.status == "Inconclusive")) + . | .[0].name // "-")] | @tsv' <<<"$json")"
    if [ "$obs" = "$gen" ]; then
      [ "$phase" != Healthy ] || break
      if [ "$abort" = true ] || [ "$phase" = Degraded ]; then
        # An abort clears the Rollout's reference to its background AnalysisRun: the newest run of the canary's
        # template is the one that failed (or was stopped by a manual abort).
        if [ "$run" = - ]; then
          run=$(kc -n "$ns" get analysisruns -l "rollouts-pod-template-hash=$hash" --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null) || true
          run=${run:--}
        fi
        way_out "$ns" "$name" "$abort"
        fail "canary of rollout $ns/$name aborted ($(kc -n "$ns" get rollout "$name" -o jsonpath='{.status.message}')); AnalysisRun $run: kubectl --context k3d-svp -n $ns get analysisrun $run -o yaml"
      fi
      case ,$reasons, in
        *,InconclusiveAnalysisRun,*)
          way_out "$ns" "$name" false
          fail "canary of rollout $ns/$name paused by an inconclusive analysis at weight $weight%, never promoted: AnalysisRun $irun (kubectl --context k3d-svp -n $ns get analysisrun $irun -o yaml); too few responses reached the canary?"
          ;;
      esac
      if [ "$step/$weight" != "$last" ]; then
        echo "      canary of $name: step $step, weight $weight%, phase $phase, AnalysisRun $run"
        last="$step/$weight"
      fi
    fi
    if ((SECONDS >= deadline)); then
      way_out "$ns" "$name" "$abort"
      fail "rollout $ns/$name Healthy within 900s (now $phase)"
    fi
    sleep 5
  done
  ok "rollout $name Healthy"
}

# after_install NAME: what must hold after a component before the next wave may rely on it, beyond the pods --wait
# already waited for.
after_install() {
  case $1 in
    svp-cluster)
      # The wildcard certificate is issued asynchronously by cert-manager, and Envoy Gateway programs the Gateway and
      # creates its proxy Deployment after the release is applied.
      kc -n svp-edge wait --for=condition=Ready certificate/svp-wildcard --timeout=120s >/dev/null ||
        fail "certificate svp-edge/svp-wildcard Ready within 120s"
      # The CloudNativePG operator (wave 2) serves its webhooks from this certificate's Secret; started without it, it
      # would make one of its own, which cert-manager then overwrites (templates/cnpg-webhook-certificate.yaml of
      # svp-cluster).
      kc -n cnpg-system wait --for=condition=Ready certificate/cnpg-webhook --timeout=120s >/dev/null ||
        fail "certificate cnpg-system/cnpg-webhook Ready within 120s"
      kc -n svp-edge wait --for=condition=Programmed gateway/svp --timeout=180s >/dev/null ||
        fail "gateway svp-edge/svp Programmed within 180s"
      wait_until 120 "Envoy proxy Deployment of gateway svp available" \
        kc -n envoy-gateway-system wait --for=condition=Available deployment \
        -l gateway.envoyproxy.io/owning-gateway-name=svp --timeout=5s
      ok "certificates svp-wildcard and cnpg-webhook Ready, gateway svp Programmed, Envoy proxy available"
      export_ca
      # The Secrets go into the namespaces this chart has just created, before any later wave reads them.
      "$repo_root/deploy/k8s/secrets.sh"
      ;;
    cloudnative-pg)
      # cert-manager's cainjector writes the webhook's certificate into the operator's two webhook configurations soon
      # after this release made them (deploy/k8s/values/cloudnative-pg.yaml); until then the API server cannot call
      # them, and the Cluster of svp-data (wave 4) would be refused.
      for webhook_kind in mutating validating; do
        wait_until 60 "cainjector writes the CA into cnpg-$webhook_kind-webhook-configuration" \
          cnpg_ca_injected "$webhook_kind"
      done
      ok "CloudNativePG's webhook configurations carry the CA of certificate cnpg-webhook"
      ;;
    kube-prometheus-stack)
      # Prometheus and Alertmanager are StatefulSets the operator makes from their custom resources, outside the
      # release, so --wait did not wait for them.
      kc -n svp-obs wait --for=condition=Available prometheus/kps-prometheus --timeout=300s >/dev/null ||
        fail "Prometheus svp-obs/kps-prometheus Available within 300s (kubectl --context k3d-svp -n svp-obs describe prometheus kps-prometheus)"
      kc -n svp-obs wait --for=condition=Available alertmanager/kps-alertmanager --timeout=300s >/dev/null ||
        fail "Alertmanager svp-obs/kps-alertmanager Available within 300s"
      ok "Prometheus and Alertmanager available"
      # Grafana reads its admin password from Secret grafana-admin only when it starts (it keeps no database between
      # starts), so a changed SVP_GRAFANA_ADMIN_PASSWORD takes a restart, as a service's Secret does.
      restart_on_secret_change svp-obs kps-grafana grafana-admin
      ;;
    kyverno)
      # Kyverno's admission controller registers its webhook configurations itself once it is ready, none of them in
      # the chart: kyverno-policy-validating-webhook-cfg checks the policy chart svp-policy installs next, and
      # kyverno-resource-validating-webhook-cfg will carry that policy's webhook.
      wait_until 120 "Kyverno registers its webhook configurations" kc get validatingwebhookconfigurations \
        kyverno-policy-validating-webhook-cfg kyverno-resource-validating-webhook-cfg
      ok "Kyverno's webhook configurations registered"
      ;;
    svp-policy)
      # The policy counts only once Kyverno has compiled it and registered its webhook, which takes the requests of
      # namespace svp only; the services (wave 7) start after that (docs/adr/0015-cicd-devsecops-stage5.md, section 8).
      wait_until 120 "ImageValidatingPolicy svp-images ready, its webhook registered for namespace svp" \
        image_policy_ready svp-images
      ok "ImageValidatingPolicy svp-images ready (Audit: violations go to PolicyReports), its webhook takes namespace svp only"
      ;;
    keda)
      # The HPA KEDA makes for a ScaledObject reads the lag through this API; until the metrics server behind it
      # answers, the HPA reports no metric and never scales.
      kc wait --for=condition=Available apiservice/v1beta1.external.metrics.k8s.io --timeout=120s >/dev/null ||
        fail "KEDA's metrics API (apiservice v1beta1.external.metrics.k8s.io) Available within 120s"
      ok "KEDA's metrics API available"
      ;;
    svp-data)
      restart_on_secret_change keda keda-operator keda-kafka
      ;;
    svp-observability)
      # GlitchTip reads Secret glitchtip-env only when it starts, like a service (its init Job, a hook of this release,
      # has already run with the current one). Then its DSN and API token go into Secrets, before the services (wave
      # 7) start and read the DSN; services already running restart there when the DSN is new to them.
      restart_on_secret_change svp-obs glitchtip glitchtip-env
      "$repo_root/deploy/k8s/glitchtip-init.sh"
      ;;
    media-worker)
      # Ready once the operator has built the Kafka scaler (logged in as svp-keda, read the group) and its HPA.
      kc -n svp wait --for=condition=Ready scaledobject/media-worker --timeout=120s >/dev/null ||
        fail "ScaledObject svp/media-worker Ready within 120s (kubectl --context k3d-svp -n svp describe scaledobject media-worker)"
      ok "ScaledObject media-worker Ready"
      ;;
    gateway | feed-service)
      wait_hpa "$1"
      ;;
  esac
}

# cnpg_ca_injected KIND: true when every webhook of KIND (mutating or validating) webhook configuration
# cnpg-KIND-webhook-configuration has a CA bundle. The chart renders none and the operator writes none
# (MANAGE_WEBHOOK_CONFIGURATIONS=false), so on a new cluster one there is cainjector's.
cnpg_ca_injected() {
  local bundles
  bundles=$(kc get "${1}webhookconfiguration" "cnpg-$1-webhook-configuration" \
    -o jsonpath='{range .webhooks[*]}[{.clientConfig.caBundle}]{end}') || return 1
  [ -n "$bundles" ] && [[ $bundles != *"[]"* ]]
}

# wait_hpa NAME: waits until HPA svp/NAME reads the CPU of its pods (condition ScalingActive) and its Deployment (the
# gateway: Rollout) has at least minReplicas ready pods. The chart renders no replicas for such a workload, so it
# starts with one pod and the HPA raises it; a cluster without metrics-server, or with its API not serving, fails here
# instead of leaving an HPA that never scales.
wait_hpa() {
  local name=$1 min kind
  kc wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s >/dev/null ||
    fail "metrics-server's API (apiservice v1beta1.metrics.k8s.io) Available within 120s"
  # metrics-server has a pod's CPU only after its first scrapes of a new pod, up to a minute.
  kc -n svp wait --for=condition=ScalingActive "hpa/$name" --timeout=180s >/dev/null ||
    fail "HPA svp/$name reads its pods' CPU within 180s (kubectl --context k3d-svp -n svp describe hpa $name)"
  min=$(kc -n svp get hpa "$name" -o jsonpath='{.spec.minReplicas}') || fail "read HPA svp/$name"
  kind=$(workload_kind svp "$name")
  wait_until 120 "$kind svp/$name with $min ready replicas" \
    test_ge "$min" kc -n svp get "$kind" "$name" -o jsonpath='{.status.readyReplicas}'
  ok "HPA $name reads CPU, $kind $name has at least $min ready replicas"
}

# test_ge MIN COMMAND...: true when COMMAND prints an integer of at least MIN.
test_ge() {
  local min=$1 got
  shift
  got=$("$@") || return 1
  [ "${got:-0}" -ge "$min" ]
}

# Pod Security "restricted" on the namespaces of wave 0 (cert-manager, envoy-gateway-system) before their charts' first
# pod. Chart svp-cluster labels every namespace of a later wave, but comes after these charts, whose CRDs it needs. The
# Namespaces are rendered by svp-cluster's own template (the same labels, at the same version) and applied server-side
# under a field manager of their own: a namespace that a previous run's --create-namespace made gets the labels added,
# and no release's later apply removes them. The loop below then finds the namespace and passes no --create-namespace.
# The project's namespaces (namespaces of svp-cluster's values, with the same labels too) are made here as well: Envoy
# Gateway, of wave 0, binds a Role in each namespace it watches (deploy/k8s/values/envoy-gateway.yaml), and Helm
# cannot create a Role in a namespace that does not exist yet. svp-cluster takes them over (--take-ownership below).
wave0=$(jq -c '[.components[] | select(.wave == 0) | {name: .namespace}] | unique' "$components") ||
  fail "read the namespaces of wave 0 in $components"
hc template svp-cluster "$repo_root/deploy/helm/svp-cluster" --show-only templates/namespaces.yaml \
  --set-json "platformNamespaces=$wave0" |
  kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
  fail "create and label the namespaces of wave 0 and the project's with Pod Security restricted"
ok "namespaces of wave 0 ($(jq -r 'map(.name) | join(", ")' <<<"$wave0")) and the project's enforce Pod Security restricted"

# One line per component, fields separated by the ASCII unit separator: empty fields (no path, no values) must survive
# `read`, which collapses runs of whitespace separators such as tabs.
sep=$'\x1f'
lines=$(jq -r '.components | sort_by(.wave) | .[]
  | [.name, .namespace, (.wave | tostring), (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
     (.values // "")] | join("\u001f")' "$components") || fail "read $components"

while IFS=$sep read -r name namespace wave path repo chart version values; do
  args=(upgrade --install "$name")
  helm_wait=--wait
  if [ -n "$path" ]; then
    args+=("$repo_root/$path")
  elif [[ $repo == oci://* ]]; then
    args+=("$repo/$chart" --version "$version")
  else
    args+=("$chart" --repo "$repo" --version "$version")
  fi
  if [ -n "$values" ]; then args+=(--values "$repo_root/$values"); fi
  watcher=
  # The Collector mounts ConfigMap otel-collector-config of chart svp-observability, which its own chart cannot
  # checksum, and reads it only when it starts: the checksum of the file that ConfigMap holds goes into the pod
  # template, so a changed config rolls the pod and an unchanged one does not.
  if [ "$name" = otel-collector ]; then
    collector_sum=$(shasum -a 256 <"$repo_root/deploy/observability/otelcol/k8s-config.yaml") ||
      fail "checksum deploy/observability/otelcol/k8s-config.yaml"
    args+=(--set-string "podAnnotations.svp-config-sha256=${collector_sum%% *}")
  fi
  if [ "$path" = "$service_chart" ]; then
    image_sets "$name"
    args+=("${image_sets[@]}")
    # A release with canary set (the gateway) is applied client-side. Argo Rollouts writes into two objects of the
    # chart: the selectors of Services <release> and <release>-canary (rollouts-pod-template-hash) and the weights in
    # HTTPRoute api. Helm 4's server-side apply sends the chart's whole selector and rules, both atomic fields now
    # managed by the controller and its plugin, and the upgrade fails on the conflict (with --force-conflicts it would
    # strip the selectors instead, sending every request to stable and canary pods alike until the controller notices).
    # A client-side upgrade patches only what changed between the previous release's manifest and this one, so an
    # unchanged Service or route is left as the controller set it. Helm's --wait (kstatus) never sees the Rollout as
    # ready and would hold until --timeout: Helm waits for hooks only, wait_rollout below for the Rollout.
    if grep -qx 'canary: true' "$repo_root/$values"; then args+=(--server-side=false) helm_wait=--wait=hookOnly; fi
    : >"$migrate_log"
    old_job=$(kc -n "$namespace" get job "$name-migrate" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    watch_migrate "$namespace" "$name-migrate" "$old_job" &
    watcher=$!
    kind=$(workload_kind "$namespace" "$name")
    if [ "$kind" = rollout ] && canary_ahead "$namespace" "$name" "$repo_root/$values" "${image_sets[@]}"; then
      start_canary_traffic "$name"
    fi
  fi
  # --wait: the next wave relies on this one's CRDs, webhooks and pods being ready (cert-manager's startupapicheck
  # hook, for one, returns only once its webhook answers), so no blind sleep is needed between waves.
  args+=(--namespace "$namespace" "$helm_wait" --timeout 10m)
  # Only for a namespace no chart has made: on a first install Helm 4 server-side applies a Namespace of its own (label
  # name only) under the field manager every release shares, and that apply removes the labels svp-cluster set on an
  # existing namespace of the project, Pod Security "restricted" and svp-gateway-routes included.
  if ! kc get namespace "$namespace" >/dev/null 2>&1; then args+=(--create-namespace); fi
  # svp-cluster makes the platform namespaces of its values (argo-rollouts, cnpg-system, keda) so that Pod Security is
  # enforced there before their chart's first pod. On a cluster created before it did, the platform chart's --create-namespace made
  # such a namespace outside any release, and Helm refuses an existing object that lacks its release's annotations
  # unless told to take it over. Every object svp-cluster renders is the project's own, under a name no other chart
  # uses.
  if [ "$name" = svp-cluster ]; then args+=(--take-ownership); fi
  # The dev path runs unsigned images of the local registry: the image policy only reports what it would refuse, in
  # PolicyReports of namespace svp, and lets every pod through when Kyverno is down (failurePolicy Ignore). The GitOps
  # path keeps the values file's Enforce (docs/adr/0015-cicd-devsecops-stage5.md, section 8).
  if [ "$name" = svp-policy ]; then args+=(--set imageVerification.mode=Audit); fi
  echo "helm upgrade --install $name (wave $wave, namespace $namespace)"
  rc=0
  hc "${args[@]}" >/dev/null || rc=$?
  if [ -n "$watcher" ]; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  fi
  if [ "$rc" != 0 ]; then
    if [ -s "$migrate_log" ] && [ "$(kc -n "$namespace" get job "$name-migrate" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = True ]; then
      echo "Job $namespace/$name-migrate failed; log of its last failed attempt, copied before its pod was deleted:" >&2
      cat "$migrate_log" >&2
    fi
    fail "install $name"
  fi
  ok "$name"
  if [ "$path" = "$service_chart" ]; then
    # The release may have just turned a Deployment into the Rollout (or the reverse): read the kind again.
    kind=$(workload_kind "$namespace" "$name")
    if [ "$kind" = rollout ]; then
      wait_rollout "$namespace" "$name"
      stop_canary_traffic
    fi
    restart_on_secret_change "$namespace" "$name" "$name-env"
    # Secret sentry existed before this release was installed (deploy/k8s/glitchtip-init.sh, after
    # svp-observability), so pods it has just created read the current DSN: a workload new to the annotation only
    # gets it. A release without error tracking (media-worker) does not read the Secret.
    dsn_from=$(kc -n "$namespace" get "$kind" "$name" -o \
      jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SENTRY_DSN")].valueFrom.secretKeyRef.name}') ||
      fail "read $kind $namespace/$name"
    if [ "$dsn_from" = sentry ]; then restart_on_secret_change "$namespace" "$name" sentry svp-sentry-secret-version; fi
  fi
  after_install "$name"
done <<<"$lines"

ok "every component of components.json installed"
