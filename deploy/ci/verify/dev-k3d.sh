# shellcheck shell=bash
# Scenario dev-k3d of deploy/ci/verify-run.sh, which sources this file: the k3d cluster of the dev path (job k3d of
# .github/workflows/verify.yml). make k8s-up, make k8s-smoke, RAM at rest, the threat model drill, the
# PodDisruptionBudget, the gateway's canary, the web's source maps, its e2e tests with GlitchTip, its observability
# drill, KEDA with two workers transcoding and the RAM peak of it, the Postgres restore twice (latest, then point in
# time), RAM at rest again. ram-rest-<label> and ram-peak are described in verify-run.sh.

build=k8s-up
job_minutes_default=330
k3d=1
# make k8s-up WEB_FROM=clone builds the web image from the clone of svp-frontend (verify-run.sh), so make
# k8s-web-sourcemaps can build its source maps, and the e2e tests run the same commit: web_ref of the dispatch, or the
# commit of the web release staging runs.
web=1

scenario_targets() {
  step k8s-up 60 make k8s-up WEB_FROM=clone
  step k8s-smoke 15 make k8s-smoke
  step ram-rest-start 15 bash -c 'ram_rest start'
  step drill-k8s-threats 30 make drill-k8s-threats
  step drill-k8s-pdb 20 make drill-k8s-pdb
  step drill-k8s-canary 30 make drill-k8s-canary
  step k8s-web-sourcemaps 20 make k8s-web-sourcemaps
  step k8s-web-e2e 40 env SVP_E2E_GLITCHTIP=1 make k8s-web-e2e
  step drill-k8s-web-obs 15 make drill-k8s-web-obs
  step drill-k8s-keda 40 make drill-k8s-keda N=9
  if [ "$last_status" = skipped ]; then
    skip ram-peak "drill-k8s-keda did not run"
  else
    step ram-peak 2 "$here/verify-sample.sh" peak "$last_start" "$last_end"
  fi
  step drill-k8s-backup 40 make drill-k8s-backup MODE=latest
  step drill-k8s-backup-pitr 40 make drill-k8s-backup MODE=pitr
  step ram-rest-end 15 bash -c 'ram_rest end'
}
