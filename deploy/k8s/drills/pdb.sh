#!/usr/bin/env bash
# PodDisruptionBudget drill on cluster svp (docs/adr/0014-kubernetes-local-stage4.md, section 10): the gateway runs
# two replicas with PDB minAvailable 1, so a voluntary disruption takes one pod at a time.
#
# Waits until the gateway has exactly two ready pods that are not being deleted (a pod evicted by a previous run may
# still be shutting down) and the budget allows one disruption, and reports their nodes (the spread over the two nodes
# is soft, so it is not required). Then drains, as `kubectl drain` does: marks every schedulable node unschedulable
# (cordon) and asks the Eviction API to evict both pods one after the other. The first is evicted (201); its
# replacement cannot be scheduled on a cordoned node and stays Pending, so the budget allows no disruption for as long
# as the check needs, however slowly it runs, and the second eviction is refused with 429. The nodes are then made
# schedulable again (on any exit, a failure included; only the nodes this run cordoned), and the drill waits until two
# pods are ready again and the gateway answers /readyz through Envoy. Prints the API's answers.
#
# Usage (from the repo root, cluster up): make drill-k8s-pdb. While the nodes are cordoned (a few seconds) no new pod
# of the cluster is scheduled. A run killed outright leaves them cordoned: kubectl --context k3d-svp uncordon <node>.
set -euo pipefail

base=${1:-https://api.svp.localhost:8443}
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

selector=app.kubernetes.io/name=gateway,app.kubernetes.io/component=server

cordoned=
drill_exit() {
  local rc=$?
  trap - EXIT
  for node in $cordoned; do
    if ! kc uncordon "$node" >/dev/null 2>&1; then
      echo "FAIL  make node $node schedulable again; run: kubectl --context k3d-svp uncordon $node" >&2
      rc=1
    fi
  done
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT

# gateway_pods: "NAME NODE" of every gateway pod that is Ready and not being deleted.
gateway_pods() {
  kc -n svp get pods -l "$selector" -o json | jq -r '.items[]
    | select(.metadata.deletionTimestamp == null)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | "\(.metadata.name) \(.spec.nodeName)"'
}

# disruptions_allowed: status.disruptionsAllowed of PDB gateway.
disruptions_allowed() { kc -n svp get pdb gateway -o jsonpath='{.status.disruptionsAllowed}'; }

# evict POD: asks the Eviction API (subresource eviction of the pod, what a node drain calls) to evict POD of svp;
# leaves kubectl's answer in $work/evict and returns kubectl's status. kubectl has no command to evict one pod, so the
# request goes through `kubectl create --raw` (a POST with kubectl's own login): 201 prints the API's Status, a
# refusal prints "Error from server (<reason>): <message>".
evict() {
  printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"svp"}}' "$1" >"$work/eviction.json"
  kc create --raw "/api/v1/namespaces/svp/pods/$1/eviction" -f "$work/eviction.json" >"$work/evict" 2>&1
}

deadline=$((SECONDS + 120))
until gateway_pods >"$work/pods" && [[ $(wc -l <"$work/pods" | tr -d ' ') == 2 && $(disruptions_allowed) == 1 ]]; do
  ((SECONDS < deadline)) ||
    fail "gateway with exactly 2 ready pods not being deleted and PDB gateway allowing 1 disruption within 120s (now: $(wc -l <"$work/pods" | tr -d ' ') pods, allowed '$(disruptions_allowed)')"
  sleep 2
done
read -r pod1 node1 <<<"$(sed -n 1p "$work/pods")"
read -r pod2 node2 <<<"$(sed -n 2p "$work/pods")"
if [[ $node1 != "$node2" ]]; then
  ok "gateway pods $pod1 on $node1, $pod2 on $node2 (one per node)"
else
  echo "note  both gateway pods run on $node1: the spread over nodes is soft (ScheduleAnyway)"
fi
ok "PDB gateway: minAvailable 1, disruptionsAllowed 1"

# Only the nodes that are schedulable now: a node someone cordoned before stays cordoned after the drill.
schedulable=$(kc get nodes -o json | jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name')
for node in $schedulable; do
  kc cordon "$node" >/dev/null || fail "cordon node $node"
  cordoned="$cordoned $node"
done
ok "nodes cordoned, as a drain does:$cordoned"

evict "$pod1" || fail "first eviction ($pod1) accepted: $(cat "$work/evict")"
[[ $(jq -r '.status // empty' "$work/evict") == Success ]] || fail "first eviction ($pod1) answers Status Success: $(cat "$work/evict")"
ok "eviction of $pod1: 201 Success"
# The budget counts the evicted pod out at once; the ReplicaSet's replacement stays Pending on the cordoned nodes.
deadline=$((SECONDS + 30))
pending=
until [[ $(disruptions_allowed) == 0 && -n $pending ]]; do
  ((SECONDS < deadline)) ||
    fail "PDB gateway allows no disruption and a replacement is Pending within 30s of the first eviction (now: allowed '$(disruptions_allowed)', Pending '$pending')"
  sleep 1
  pending=$(kc -n svp get pods -l "$selector" --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}')
done
ok "PDB gateway: disruptionsAllowed 0, replacement $pending Pending on the cordoned nodes"
if evict "$pod2"; then fail "second eviction ($pod2) refused while $pod1's replacement is not ready (it was accepted)"; fi
grep -q 'TooManyRequests' "$work/evict" ||
  fail "second eviction ($pod2) refused with 429 TooManyRequests (got: $(cat "$work/evict"))"
ok "eviction of $pod2: 429 $(cat "$work/evict")"

# The Pending replacement binds to the first node that opens, and pod2, which stays, runs on node2: opening node1, the
# node of the evicted pod, first keeps the two pods on two nodes, where opening in name order could put both on one.
# $cordoned keeps every node until the loop is done, so the exit trap still opens them all if a step fails.
opened=
for node in $node1 $cordoned; do
  [[ " $cordoned " == *" $node "* && " $opened " != *" $node "* ]] || continue
  kc uncordon "$node" >/dev/null || fail "uncordon node $node"
  opened="$opened $node"
done
cordoned=
ok "nodes schedulable again, opened in this order:$opened"

deadline=$((SECONDS + 120))
# The gateway is an Argo Rollouts Rollout (ADR-0014 section 13), not a Deployment: its status counts ready pods the same way.
until [[ $(kc -n svp get rollout gateway -o jsonpath='{.status.readyReplicas}') == 2 ]]; do
  ((SECONDS < deadline)) || fail "rollout gateway back at 2 ready replicas within 120s"
  sleep 2
done
ok "rollout gateway back at 2 ready replicas; $pod2 was never evicted: $(kc -n svp get pod "$pod2" -o jsonpath='{.status.phase}')"
if [[ $node1 != "$node2" ]]; then
  nodes_after=$(gateway_pods | awk '{ print $2 }' | sort -u | wc -l | tr -d ' ')
  if [[ $nodes_after == 2 ]]; then ok "gateway pods back on two nodes"; else echo "note  gateway pods are on $nodes_after node(s) after the drill: the spread over nodes is soft (ScheduleAnyway)"; fi
fi
wait_gateway_ready 30

echo "drill-k8s-pdb: all checks passed"
