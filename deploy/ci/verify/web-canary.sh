# shellcheck shell=bash
# Scenario web-canary of deploy/ci/verify-run.sh, which sources this file: the canary of the web's Rollout on the k3d
# cluster of the dev path, under the drill traffic and browser clients (job k3d of .github/workflows/verify.yml). make
# k8s-up, make k8s-smoke, make drill-k8s-web-canary (a good release promoted, a bad one aborted).

build=k8s-up
job_minutes_default=330
k3d=1

scenario_targets() {
  step k8s-up 60 make k8s-up
  step k8s-smoke 15 make k8s-smoke
  step drill-k8s-web-canary 60 make drill-k8s-web-canary
}
