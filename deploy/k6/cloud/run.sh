#!/usr/bin/env bash
# The k6 load test of the cloud cluster of stage 7 (docs/adr/0020-reliability-stage6.md, section 2): 20 pods of profile
# cloud, 1 000 feed requests a second (1 250 req/s in all) held at least 10 minutes. The learner runs it, with the cloud
# cluster's kubectl context; never on k3d (refused before any kubectl call) and never from make. Needs kubectl and jq.
#
# Usage: deploy/k6/cloud/run.sh --context <ctx> --domain <domain> [--forwarded-for] [--ca-file <file>] start|logs|delete
#   --domain         the web's public host (the API is api.<domain>), as Envoy's listeners and certificates name them
#   --forwarded-for  only when stage 7 trusts two hops of X-Forwarded-For (a load balancer before Envoy): each pod then
#                    writes its own IP there, as the load balancer would (threat model RL-7)
#   --ca-file        PEM file of the CA that signs Envoy's certificate, when a private CA does (an Envoy behind a load
#                    balancer that holds the public certificate): the pods trust that CA alone (render.sh)
#   start   finds the ClusterIP of Envoy's Service of Gateway svp, renders the manifests (render.sh) and applies them:
#           namespace svp-load, the scripts' ConfigMap, Job svp-k6. Refuses while a Job svp-k6 exists.
#   logs    after the Job ends: the summary line of each pod into .k6/cloud-<time>/pod-<i>.json, and a table of them
#   delete  deletes namespace svp-load (the Job, its pods and their logs)
#
# Before start: the stack runs on the cloud cluster with at least 30 READY videos (fewer and most views stop at the
# gateway's one-per-minute rule, RL-3), nothing else loads it, and the gateway's trusted hops are decided (RL-1).
# Watch: kubectl --context <ctx> -n svp-load get pods -w; Grafana's SLO dashboard; the gateway's 429s
# (svp_rate_limited in each pod's summary must stay 0).
# Pass: in every pod, every threshold passed and dropped_iterations 0; server-side p95/p99 read from Prometheus over
# the hold window go into the Results of docs/adr/0020-reliability-stage6.md with the pods' numbers.
# Stop early: deploy/k6/cloud/run.sh --context <ctx> --domain <domain> delete.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)

die() {
  echo "FAIL  $1" >&2
  exit 1
}
usage() {
  sed -n 's/^# Usage: //p' "$0" >&2
  exit 2
}

ctx= domain= render_args=() cmd=
while [ $# -gt 0 ]; do
  case $1 in
    --context) [ $# -ge 2 ] || usage; ctx=$2; shift 2 ;;
    --domain) [ $# -ge 2 ] || usage; domain=$2; shift 2 ;;
    --forwarded-for) render_args+=(--forwarded-for); shift ;;
    --ca-file) [ $# -ge 2 ] || usage; render_args+=(--ca-file "$2"); shift 2 ;;
    start | logs | delete) cmd=$1; shift ;;
    *) usage ;;
  esac
done
[ -n "$cmd" ] || usage
# The guard comes before any kubectl call: an empty context would be kubectl's current one, which may be k3d's.
[ -n "$ctx" ] || die "no --context: name the cloud cluster's kubectl context"
case $ctx in
  k3d-*) die "context $ctx is a local k3d cluster; this load test runs on the cloud cluster only" ;;
esac
command -v jq >/dev/null || die "jq not found"
kubectl config get-contexts -o name | grep -qxF -- "$ctx" || die "no context $ctx in the kubeconfig"
kc() { kubectl --context "$ctx" "$@"; }

case $cmd in
  start)
    [ -n "$domain" ] || die "start needs --domain"
    if kc -n svp-load get job svp-k6 >/dev/null 2>&1; then
      die "Job svp-load/svp-k6 exists; read it (logs) and delete it first"
    fi
    envoy_ip=$(kc -n envoy-gateway-system get service -l gateway.envoyproxy.io/owning-gateway-name=svp \
      -o jsonpath='{.items[*].spec.clusterIP}')
    [[ $envoy_ip =~ ^[0-9a-f.:]+$ ]] || die "not exactly one Service of Gateway svp in envoy-gateway-system (got '$envoy_ip')"
    bash "$here/render.sh" --domain "$domain" --envoy-ip "$envoy_ip" ${render_args[@]+"${render_args[@]}"} |
      kc apply -f -
    echo "ok    Job svp-load/svp-k6 started (Envoy $envoy_ip, https://api.$domain and https://$domain)"
    echo "watch: kubectl --context $ctx -n svp-load get pods -w"
    ;;
  logs)
    out=$repo/.k6/cloud-$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$out"
    pods=$(kc -n svp-load get pods -l batch.kubernetes.io/job-name=svp-k6 -o json |
      jq -r '.items[] | "\(.metadata.annotations["batch.kubernetes.io/job-completion-index"]) \(.metadata.name)"')
    [ -n "$pods" ] || die "no pod of Job svp-load/svp-k6"
    while read -r i pod; do
      kc -n svp-load logs "$pod" | sed -n 's/^svp-k6-summary //p' >"$out/pod-$i.json"
      [ -s "$out/pod-$i.json" ] || echo "FAIL  pod $i ($pod) printed no summary (still running, or k6 failed: kubectl --context $ctx -n svp-load logs $pod)" >&2
    done <<<"$pods"
    echo "summaries in ${out#"$repo"/}"
    for f in "$out"/pod-*.json; do
      [ -s "$f" ] || continue
      jq -r --arg f "$(basename "$f" .json)" '
        "\($f): thresholds \(if .thresholds_ok then "ok" else "FAILED" end), dropped_iterations \(.dropped_iterations), " +
        "429 \([.routes[].rate_limited] | add), explore p99 \(.routes[] | select(.route == "/feed/explore") | .p99_ms) ms"' "$f"
    done
    ;;
  delete)
    kc delete namespace svp-load --ignore-not-found
    ;;
esac
