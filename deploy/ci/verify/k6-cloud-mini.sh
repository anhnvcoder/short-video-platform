# shellcheck shell=bash
# Scenario k6-cloud-mini of deploy/ci/verify-run.sh, which sources this file: the k6 Job of profile cloud
# (deploy/k6/cloud/run.sh) scaled down on the k3d cluster of the dev path (job k3d of .github/workflows/verify.yml), at
# 1, 2, 4 and 8 pods, each pod the share of load of a pod of the 20-pod design. make k8s-up, the READY videos the load
# reads, then one step per level. unwritten is described in verify-run.sh.

build=k8s-up
job_minutes_default=330
k3d=1

# k6_level PODS: the Job at PODS pods: started, waited for, its pods' summaries read, deleted.
k6_level() {
  local rc=0 run=(deploy/k6/cloud/run.sh --context k3d-svp --domain svp.localhost)
  "${run[@]}" --pods "$1" start || return 1
  kc -n svp-load wait --for=condition=complete job/svp-k6 --timeout=20m || rc=1
  "${run[@]}" logs || rc=1
  "${run[@]}" delete || rc=1
  return "$rc"
}
export -f k6_level

scenario_targets() {
  local pods
  step k8s-up 60 make k8s-up
  # At least 30 READY videos: fewer, and most views stop at the gateway's one-per-minute rule.
  step seed-videos 40 bash -c 'unwritten seed-videos'
  for pods in 1 2 4 8; do
    step "k6-pods-$pods" 25 bash -c 'k6_level "$1"' _ "$pods"
  done
}
