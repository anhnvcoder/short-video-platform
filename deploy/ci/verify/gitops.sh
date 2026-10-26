# shellcheck shell=bash
# Scenario gitops of deploy/ci/verify-run.sh, which sources this file: a new cluster k3d-svp that Argo CD builds from
# this repository, running the signed release images of GHCR by digest (job gitops of .github/workflows/verify.yml).
# make k8s-gitops-up on the branch this run checked out, make k8s-smoke, RAM at rest, the supply chain drill (Kyverno
# enforcing), the threat model drill, the source maps of the image CI built, the web's e2e tests with GlitchTip, its
# observability drill, KEDA with two workers transcoding twice (each with the RAM peak of it), the wait for a release
# merged on main while the cluster runs and make measure-gitops on it, RAM at rest again. ram-rest-<label>, ram-peak-<n>
# and unwritten are described in verify-run.sh.

build=k8s-gitops-up
job_minutes_default=330
k3d=1

# The branch the job checked out; Argo CD follows it as origin/<branch>, which a checkout of the whole history holds.
gitops_rev=$(git -C "$repo" symbolic-ref --short -q HEAD) || gitops_rev=
export gitops_rev

# gitops_up: make k8s-gitops-up on the run's branch; fails on a detached HEAD, which Argo CD could not follow.
gitops_up() {
  if [ -z "$gitops_rev" ]; then
    echo "FAIL  k8s-gitops-up: the checkout is on no branch, so Argo CD has no revision to follow"
    return 1
  fi
  make k8s-gitops-up GITOPS_REV="$gitops_rev"
}
export -f gitops_up

scenario_targets() {
  local round
  step k8s-gitops-up 60 bash -c gitops_up
  step k8s-smoke 15 make k8s-smoke
  step ram-rest-start 15 bash -c 'ram_rest start'
  step drill-k8s-supplychain 40 make drill-k8s-supplychain
  step drill-k8s-threats 30 make drill-k8s-threats
  # The source maps of the web image CI built and the cluster runs, uploaded to the cluster's GlitchTip.
  step gitops-sourcemaps 20 "$here/gitops-sourcemaps.sh"
  step k8s-web-e2e 40 env SVP_E2E_GLITCHTIP=1 make k8s-web-e2e
  step drill-k8s-web-obs 15 make drill-k8s-web-obs
  # Twice, each drill followed by the RAM peak over its own samples.
  for round in 1 2; do
    step "drill-k8s-keda-$round" 40 make drill-k8s-keda N=9
    if [ "$last_status" = skipped ]; then
      skip "ram-peak-$round" "drill-k8s-keda-$round did not run"
    else
      step "ram-peak-$round" 2 "$here/verify-sample.sh" peak "$last_start" "$last_end" "$round"
    fi
  done
  # A release merged on main while the cluster runs, then the time from its push to the last pod Ready.
  step wait-release 90 bash -c 'unwritten wait-release'
  step measure-gitops 20 bash -c 'unwritten measure-gitops'
  step ram-rest-end 15 bash -c 'ram_rest end'
}
