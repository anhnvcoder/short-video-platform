#!/usr/bin/env bash
# Installs or upgrades every component of argocd/apps/components.json of the deployment configuration svp-gitops (the
# working tree of its clone, gitops_dir of deploy/k8s/lib.sh) into the running cluster svp, in ascending wave order
# (files order within a wave), with `helm upgrade --install --wait`: the dev path. Only base/ of that clone is read,
# never envs/: the dev path builds its own images. The GitOps path builds Argo CD Applications from the same file, so
# both install the same charts, versions and base values.
#
# A component is an upstream chart (repo + chart + version; a Helm OCI repository is written oci://...) or a chart in
# this repository (path, read from this working tree), with an optional values file relative to the top of the clone
# of svp-gitops. A component with gitopsOnly (External Secrets Operator) belongs to the GitOps path alone and is
# skipped here: the dev path's Secrets come from .env through deploy/k8s/secrets.sh. So is a component whose platforms
# leave out k3d (a controller of the cloud, such as AWS Load Balancer Controller): the dev path's cluster is k3d, and no
# platforms means every platform. Run by `make k8s-up` after the registry and the cluster exist; running it again only
# upgrades what changed.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"

gitops=$(gitops_dir) || exit 1
components="$gitops/argocd/apps/components.json"
# The components the dev path installs, a jq filter on an entry of components.json (see the header).
dev_path='.gitopsOnly != true and ((has("platforms") | not) or (.platforms | index("k3d")) != null)'
command -v jq >/dev/null || fail "jq not found (brew install jq)"
# The GitOps root gives a component on k3d the values of platforms/k3d/ too (a file, and what it renders from a
# template on the values of the root, which only the root has); this path reads base/ alone. base/ is written for
# k3d, the dev path's cluster, so a value of k3d goes there, read by both paths: a file under platforms/k3d/ would
# make this path install something other than what Argo CD runs on k3d, without a word.
for f in "$gitops"/platforms/k3d/*; do
  [ -e "$f" ] && [ "$(basename "$f")" != README.md ] || continue
  fail "${f#"$gitops"/} is read on k3d by the GitOps root but not by the dev path: put values of k3d into base/, which both paths read"
done
kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
# A cluster made by `make k8s-gitops-up` belongs to Argo CD: Helm releases installed over its Applications would be
# reverted by its self-heal, or fight it on every sync. It changes through git (deploy/k8s/gitops.sh says how a
# changed .env reaches it).
if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then
  fail "cluster svp is managed by Argo CD (Application argocd/svp-root): change it through git, or start over on the dev path with make k8s-down && make k8s-up"
fi
# A cluster made while the object store was MinIO (StatefulSet svp-data/minio) is made again, never upgraded in place:
# the upgrade would leave MinIO's volume behind and move ObjectStore svp-pg-backup to a new, empty store while WAL is
# being archived, some backups on each side. The cluster made again has a new Postgres too, so nothing points at the
# old objects.
old_store=$(kc -n svp-data get statefulset minio --ignore-not-found -o name) || fail "read StatefulSet svp-data/minio"
if [ -n "$old_store" ]; then
  fail "cluster svp still runs MinIO (StatefulSet svp-data/minio), from before the object store became s3: it is not upgraded in place; start over with make k8s-down && make k8s-up"
fi

# The services' images first, so a build that fails stops the run before anything is installed. Each release of
# chart svp-service then gets its image with --set (never written to a file): the local registry, the service's dev
# tag and an empty digest (image_sets). The repository, tag and digest in envs/<env>/images/ of svp-gitops name
# releases on GHCR for the GitOps path; this path neither reads nor pulls them, except the web client's unless
# WEB_FROM=clone builds it from the clone of svp-web (web_source of lib.sh: stg by default, or image with WEB_IMAGE):
# then web is not built and its release runs, by digest, pulled by the nodes from GHCR without credentials.
service_chart=deploy/helm/svp-service
web_source
if [ -n "$web_release" ]; then
  build_dev_images "${built_services[@]}"
  ok "web runs release $web_release (WEB_FROM=${WEB_FROM:-stg}), with the build id CI gave it: make k8s-web-sourcemaps needs SOURCEMAPS_DIR with its maps"
else
  build_dev_images
fi

# image_sets SERVICE: sets the array image_sets to the --set flags of SERVICE's dev image, or of the web release
# web_source chose. The upgrade and canary_ahead
# both use them, so the template canary_ahead compares is the one the upgrade applies: any difference there would be
# a new revision of the release, a canary of unchanged code.
image_sets() {
  if [ "$1" = web ] && [ -n "$web_release" ]; then
    image_sets=(--set "image.repository=${web_release%@*}" --set "image.tag=" --set "image.digest=${web_release#*@}")
    return
  fi
  local tag_var="dev_tag_${1//-/_}"
  [ -n "${!tag_var:-}" ] || fail "no image was built for $1 (not in svp_services of deploy/k8s/lib.sh)"
  image_sets=(--set "image.repository=k3d-svp-registry:5111/svp/$1" --set "image.tag=${!tag_var}" --set "image.digest=")
}

# A process reads the Secret it gets as environment variables only when it starts, and nothing restarts a pod when
# that Secret changes; no chart can roll its pods by a checksum of the Secret in the pod template either, since
# deploy/k8s/secrets.sh makes these Secrets outside Helm and Argo CD. So once a service's release is installed, its
# Deployment is restarted here if <service>-env changed since its pods read it (restart_on_secret_change of
# deploy/k8s/lib.sh). Not earlier: the services' releases come after svp-data, whose init Jobs have set the passwords
# of .env in Postgres, the object store and Redpanda by then; a pod restarted before that would start with a password
# its backend does not take yet, and never get ready.
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

# The gateway and the web client are Argo Rollouts Rollouts: an upgrade that changes the pod template (new code,
# or a value a drill left in the release) is a new revision, which goes out as a canary only when Envoy has measured
# enough responses of it, and helm --wait does not know Rollouts. So when the Rollout already exists and a canary is
# ahead (canary_ahead), drill traffic (deploy/k8s/drills/traffic.sh, which requests both) runs before the release's
# upgrade, the upgrade is followed by wait_rollout, and the traffic stops once that is over, a
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
# kubectl-argo-rollouts plugin: its abort and retry are these
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

# pg_backup_sets: sets the array pg_sets to the flag that keeps the archive generation of the running Cluster svp-pg,
# for the upgrade of chart svp-data. Each restore of make
# drill-k8s-backup creates svp-pg again archiving into a new generation (value postgres.backup.serverName), and the
# chart's default is the first generation's: an upgrade without the flag would point the restored Cluster's WAL
# archiving back at the generation it was restored from, whose archive is not empty, and archiving would fail. As on
# the rest of this path the value is passed with --set, never written to a file. A new cluster, or a Cluster made
# before the backups (no serverName yet), gets the chart's default. A Cluster that is gone while Backups of it remain was
# deleted after it had data (a restore drill stopped half way): the chart would create an empty database in its place,
# so the script stops before chart svp-data is upgraded. So it does for a Cluster still being restored (bootstrap.recovery
# set and not Ready yet): the upgrade would remove bootstrap.recovery and externalClusters, which the chart renders only
# on the drill's own command line, while the restore still reads them.
pg_backup_sets() {
  local found server backups restoring origin
  pg_sets=()
  found=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg --ignore-not-found -o name 2>/dev/null) || found=
  if [ -n "$found" ]; then
    restoring=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
      -o jsonpath='{.spec.bootstrap.recovery.source} {.status.conditions[?(@.type=="Ready")].status}') ||
      fail "read Cluster svp-data/svp-pg"
    case $restoring in
      " "* | *" True") ;;
      *)
        # recovery.source names the entry of externalClusters; the generation is that entry's serverName.
        origin=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
          -o jsonpath="{.spec.externalClusters[?(@.name==\"${restoring%% *}\")].plugin.parameters.serverName}") || origin=
        fail "Cluster svp-data/svp-pg has bootstrap.recovery (restored from generation ${origin:-unknown}) and is not Ready: while the restore runs, installing svp-data would remove bootstrap.recovery, which it reads. Wait until it is Ready (kubectl --context k3d-svp -n svp-data wait --for=condition=Ready cluster/svp-pg --timeout=900s), then run make k8s-up again; a restore that fails: docs/runbooks/postgres-restore.md" ;;
    esac
    server=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
      -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}') ||
      fail "read Cluster svp-data/svp-pg"
    if [ -n "$server" ]; then
      pg_sets=(--set-string "postgres.backup.serverName=$server")
      ok "Postgres svp-pg keeps archive generation $server"
    fi
    return 0
  fi
  backups=$(kc -n svp-data get backups.postgresql.cnpg.io -o jsonpath='{range .items[?(@.spec.cluster.name=="svp-pg")]}{.metadata.name}{" "}{end}' 2>/dev/null) ||
    backups=
  [ -z "$backups" ] ||
    fail "Cluster svp-data/svp-pg is missing while Backups of it remain (${backups% }): it was deleted after it had data, a restore drill stopped half way? Installing svp-data would create an empty database in its place. Finish the restore as docs/runbooks/postgres-restore.md says (make drill-k8s-backup printed its commands), or start over with no data: make k8s-down && make k8s-up"
}

# rollouts_plugin_check: Argo Rollouts' Gateway API traffic router plugin is a native binary, which the controller
# downloads when it starts and executes at the first reconcile of a Rollout with a canary. Its values file
# base/argo-rollouts.yaml pins the linux-arm64 asset, for the nodes of a Mac; on amd64 nodes (a Linux
# x86_64 host, such as a CI runner) that binary cannot run: the controller fails to start the plugin on every reconcile,
# before it scales the Rollout's ReplicaSet, so the gateway never gets a pod. There the file archValues of
# components.json names for amd64 is read after it, as on the GitOps path, and replaces the plugin with the asset of
# the same release built for amd64. Both files must name one release, so a new release cannot update one pin and leave
# the other behind: each holds exactly one plugin location, and the locations differ only in the asset's name.
rollouts_plugin_check() {
  local file loc release='' all
  all=$(jq -r '.components[] | select(.name == "argo-rollouts") | .values, ((.archValues // {})[])' "$components") ||
    fail "read the values files of argo-rollouts in $components"
  for file in $all; do
    loc=$(sed -n 's/^ *location: *//p' "$gitops/$file")
    [[ $loc =~ ^https://[^[:space:]]+/[^/[:space:]]+$ ]] ||
      fail "$file pins no single plugin location (got '$loc')"
    if [ -z "$release" ]; then
      release=${loc%/*}
    elif [ "${loc%/*}" != "$release" ]; then
      fail "$file pins the plugin of ${loc%/*}, the other values files of argo-rollouts that of $release: change every pin to one release"
    fi
  done
  ok "Argo Rollouts gets the Gateway API plugin built for $node_arch nodes (release ${release##*/})"
}

# pg_base_backup: after chart svp-data, that Postgres svp-pg archives its WAL and that its archive generation has a base
# backup to restore from. On a new cluster ScheduledBackup svp-pg-daily
# takes the first one at once (immediate; a hook of the chart, made once the s3-init Job has made bucket pg-backups
# and its login). On the upgrade that adds the plugin to a Cluster made before it, though, CloudNativePG starts that
# Backup on whichever primary pod is Ready, which may still be the old one, without the plugin's sidecar: the Backup
# then fails, for good (CloudNativePG never retries one; the schedule's next run is at 03:00 UTC). So once the primary
# runs the sidecar and no Backup of svp-pg is in progress, a generation with no successful base backup in the status of
# ObjectStore svp-pg-backup gets one here. Then WAL archiving must work (condition ContinuousArchiving, which the WAL
# switch of a base backup sets at the latest).
pg_base_backup() {
  local gen last name
  wait_until 600 "the primary of Postgres svp-pg Ready with the Barman Cloud plugin's sidecar (kubectl --context k3d-svp -n svp-data get cluster svp-pg)" \
    pg_primary_has_sidecar
  wait_until 600 "every Backup of svp-pg in progress completed or failed (kubectl --context k3d-svp -n svp-data get backups)" \
    pg_no_backup_running
  gen=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
    -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}') && [ -n "$gen" ] ||
    fail "read the archive generation of Cluster svp-data/svp-pg"
  last=$(kc -n svp-data get objectstores.barmancloud.cnpg.io svp-pg-backup -o json |
    jq -r --arg gen "$gen" '.status.serverRecoveryWindow[$gen].lastSuccessfulBackupTime // ""') ||
    fail "read the status of ObjectStore svp-data/svp-pg-backup"
  if [ -z "$last" ]; then
    name=svp-pg-base-$(date -u +%Y%m%d%H%M%S)
    pg_backup "$name"
    last="Backup $name, taken now: generation $gen had none"
  fi
  wait_until 300 "Postgres svp-pg archives WAL (condition ContinuousArchiving True; docs/runbooks/postgres-wal-archiving-failing.md)" \
    test_output True kc -n svp-data get clusters.postgresql.cnpg.io svp-pg \
    -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'
  ok "Postgres svp-pg archives WAL into generation $gen; last base backup: $last"
}

# pg_primary_has_sidecar: true when Cluster svp-pg is Ready and its current primary pod is Ready and has the plugin's
# sidecar (init container plugin-barman-cloud, restartPolicy Always), which the operator adds only to the pods it makes
# once the Cluster names the plugin. The Cluster's Ready alone may still be the one from before the upgrade.
pg_primary_has_sidecar() {
  local primary
  [ "$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] ||
    return 1
  primary=$(kc -n svp-data get clusters.postgresql.cnpg.io svp-pg -o jsonpath='{.status.currentPrimary}') &&
    [ -n "$primary" ] || return 1
  [ "$(kc -n svp-data get pod "$primary" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.spec.initContainers[?(@.name=="plugin-barman-cloud")].name}')" = \
    "True plugin-barman-cloud" ]
}

# pg_no_backup_running: true when no Backup of svp-pg is in a phase other than completed or failed (none yet, pending,
# started, running and the like).
pg_no_backup_running() {
  local phases
  phases=$(kc -n svp-data get backups.postgresql.cnpg.io \
    -o jsonpath='{range .items[?(@.spec.cluster.name=="svp-pg")]}[{.status.phase}]{end}') || return 1
  [ -z "$(printf '%s' "$phases" | sed -e 's/\[completed\]//g' -e 's/\[failed\]//g')" ]
}

# after_install NAME: what must hold after a component before the next wave may rely on it, beyond the pods --wait
# already waited for.
after_install() {
  case $1 in
    svp-cluster)
      # The two certificates of Gateway svp are issued asynchronously by cert-manager, and Envoy Gateway programs the
      # Gateway and creates its proxy Deployment after the release is applied.
      for cert in svp-wildcard svp-apex; do
        kc -n svp-edge wait --for=condition=Ready "certificate/$cert" --timeout=120s >/dev/null ||
          fail "certificate svp-edge/$cert Ready within 120s"
      done
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
      ok "certificates svp-wildcard, svp-apex and cnpg-webhook Ready, gateway svp Programmed, Envoy proxy available"
      export_ca
      # The Secrets go into the namespaces this chart has just created, before any later wave reads them.
      "$repo_root/deploy/k8s/secrets.sh"
      ;;
    cloudnative-pg)
      # cert-manager's cainjector writes the webhook's certificate into the operator's two webhook configurations soon
      # after this release made them (base/cloudnative-pg.yaml of svp-gitops); until then the API server cannot call
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
      # namespace svp only; the services (wave 7) start after that.
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
      pg_base_backup
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
# Gateway, of wave 0, binds a Role in each namespace it watches (base/envoy-gateway.yaml), and Helm
# cannot create a Role in a namespace that does not exist yet. svp-cluster takes them over (--take-ownership below).
wave0=$(jq -c "[.components[] | select(.wave == 0 and $dev_path) | {name: .namespace}] | unique" "$components") ||
  fail "read the namespaces of wave 0 in $components"
hc template svp-cluster "$repo_root/deploy/helm/svp-cluster" --show-only templates/namespaces.yaml \
  --set-json "platformNamespaces=$wave0" |
  kc apply --server-side --field-manager=svp-pod-security -f - >/dev/null ||
  fail "create and label the namespaces of wave 0 and the project's with Pod Security restricted"
ok "namespaces of wave 0 ($(jq -r 'map(.name) | join(", ")' <<<"$wave0")) and the project's enforce Pod Security restricted"

# The architecture of the nodes, which ensure_cluster has checked all run the host's: a component with archValues in
# components.json gets the values file named there for it after its values, as the GitOps path does
# (chart argocd/apps of svp-gitops; rollouts_plugin_check says why).
node_arch=$(kc get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/arch}') ||
  fail "read the architecture of the nodes of svp"
case $node_arch in
  amd64 | arm64) ;;
  *) fail "nodes of svp run '$node_arch': the release images and the plugin of Argo Rollouts exist for amd64 and arm64 only" ;;
esac

# One line per component, fields separated by the ASCII unit separator: empty fields (no path, no values) must survive
# `read`, which collapses runs of whitespace separators such as tabs.
sep=$'\x1f'
lines=$(jq -r --arg arch "$node_arch" '.components | sort_by(.wave) | .[] | select('"$dev_path"')
  | [.name, .namespace, (.wave | tostring), (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
     (.values // ""), (.canaryRoute // ""), ((.archValues // {})[$arch] // "")] | join("\u001f")' "$components") ||
  fail "read $components"

while IFS=$sep read -r name namespace wave path repo chart version values canary_route arch_values; do
  args=(upgrade --install "$name")
  helm_wait=--wait
  if [ -n "$path" ]; then
    args+=("$repo_root/$path")
  elif [[ $repo == oci://* ]]; then
    args+=("$repo/$chart" --version "$version")
  else
    args+=("$chart" --repo "$repo" --version "$version")
  fi
  if [ -n "$values" ]; then args+=(--values "$gitops/$values"); fi
  if [ -n "$arch_values" ]; then args+=(--values "$gitops/$arch_values"); fi
  if [ "$name" = svp-data ]; then
    pg_backup_sets
    args+=(${pg_sets[@]+"${pg_sets[@]}"})
  fi
  if [ "$name" = argo-rollouts ]; then rollouts_plugin_check; fi
  # A CI runner's job only (scenario velero of deploy/ci/verify-run.sh sets SVP_K8S_RUNNER_CSI=1): Redpanda's volume on
  # the StorageClass of the CSI hostpath driver, whose snapshots Velero takes. The driver goes in right before this
  # release, whose --wait needs the PVC bound; deploy/k8s/cloud/runner/csi/install.sh refuses any machine but such a
  # runner, and fails before Redpanda is installed when the driver or the StorageClass is not ready. Unset, nothing here
  # runs and the values of the dev and GitOps paths are untouched.
  if [ "$name" = redpanda ] && [ -n "${SVP_K8S_RUNNER_CSI:-}" ]; then
    [ "$SVP_K8S_RUNNER_CSI" = 1 ] || fail "SVP_K8S_RUNNER_CSI is 1 or unset"
    # A PVC's StorageClass cannot change, and a StatefulSet's volumeClaimTemplates neither: a Redpanda installed
    # without the variable keeps its volume, so the cluster is made again (always the case on a runner, whose cluster
    # is new).
    rp_class=$(kc -n "$namespace" get pvc datadir-redpanda-0 --ignore-not-found -o jsonpath='{.spec.storageClassName}') ||
      fail "read PVC $namespace/datadir-redpanda-0"
    if [ -n "$rp_class" ] && [ "$rp_class" != csi-hostpath ]; then
      fail "Redpanda's volume is on StorageClass $rp_class, which cannot change to csi-hostpath in place: start over with make k8s-down && SVP_K8S_RUNNER_CSI=1 make k8s-up"
    fi
    "$repo_root/deploy/k8s/cloud/runner/csi/install.sh" ||
      fail "the CSI hostpath driver is not ready (deploy/k8s/cloud/runner/csi/install.sh): Redpanda is not installed"
    args+=(--set storage.persistentVolume.storageClass=csi-hostpath)
  fi
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
    # A release with canary set (the gateway, the web client) is applied client-side. Argo Rollouts writes into two
    # objects of the chart: the selectors of Services <release> and <release>-canary (rollouts-pod-template-hash) and
    # the weights in the release's HTTPRoute. Helm 4's server-side apply sends the chart's whole selector and rules,
    # both atomic fields now managed by the controller and its plugin, and the upgrade fails on the conflict (with
    # --force-conflicts it would strip the selectors instead, sending every request to stable and canary pods alike
    # until the controller notices).
    # A client-side upgrade patches only what changed between the previous release's manifest and this one, so an
    # unchanged Service or route is left as the controller set it. Helm's --wait (kstatus) never sees the Rollout as
    # ready and would hold until --timeout: Helm waits for hooks only, wait_rollout below for the Rollout.
    if grep -qx 'canary: true' "$gitops/$values"; then
      args+=(--server-side=false) helm_wait=--wait=hookOnly
      # The GitOps path ignores the weights of the route components.json names (chart argocd/apps): without it there,
      # Argo CD's selfHeal would set them back in the middle of every canary.
      [ -n "$canary_route" ] || fail "$values sets canary: true, but component $name has no canaryRoute in $components"
    elif [ -n "$canary_route" ]; then
      fail "component $name has canaryRoute $canary_route in $components, but $values does not set canary: true"
    fi
    : >"$migrate_log"
    old_job=$(kc -n "$namespace" get job "$name-migrate" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    watch_migrate "$namespace" "$name-migrate" "$old_job" &
    watcher=$!
    kind=$(workload_kind "$namespace" "$name")
    if [ "$kind" = rollout ] && canary_ahead "$namespace" "$name" "$gitops/$values" "${image_sets[@]}"; then
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
  # path keeps the values file's Enforce.
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
      # Marked as unready_report marks a log line (mark_log of deploy/k8s/lib.sh): the log of a service is shown on
      # the machine that runs this, and the public artifact of a verification run leaves out every log line of
      # namespace svp.
      mark_log "$namespace" <"$migrate_log" >&2
    fi
    unready_report "$namespace" || true
    fail "install $name"
  fi
  ok "$name"
  if [ "$path" = "$service_chart" ]; then
    # The release may have just turned a Deployment into the Rollout (or the reverse): read the kind again.
    kind=$(workload_kind "$namespace" "$name")
    if [ "$kind" = rollout ]; then
      kc -n "$namespace" get httproute "$canary_route" >/dev/null 2>&1 ||
        fail "canaryRoute $canary_route of component $name in $components names no HTTPRoute of release $name"
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
