# shellcheck shell=bash
# Scenario gitops of deploy/ci/verify-run.sh, which sources this file: a new cluster k3d-svp that Argo CD builds from
# this repository, running the signed release images of GHCR by digest (job gitops of .github/workflows/verify.yml).
# make k8s-gitops-up on the branch this run checked out, make k8s-smoke, RAM at rest, the supply chain drill (Kyverno
# enforcing), the threat model drill, the source maps of the image CI built, the web's e2e tests with GlitchTip, its
# observability drill, KEDA with two workers transcoding twice (each with the RAM peak of it), RAM at rest again.
# ram-rest-<label> and ram-peak-<n> are described in verify-run.sh.
#
# Two parts of the job run in steps of their own around this scenario, since they need the job's token (it reads the
# repository's runs, artifacts and events; nothing is written) and the scenario's step must not hold it:
#   before it   deploy/ci/gitops-sourcemaps.sh fetch finds the source maps CI exported beside the web image Argo CD is
#               about to run and leaves them, or why there are none, in <temp>/gitops-sourcemaps (ci_temp_dir of
#               deploy/ci/platform.sh): status (ok, skipped or fail), reason, maps/;
#   after it    "Waiting for a release on main": this file run as a script, `bash deploy/ci/verify/gitops.sh release`
#               (release_wait below), the targets wait-release and measure-gitops. On a run of main it waits for a
#               release merged while the cluster runs and measures it with make measure-gitops; on a branch it only says
#               why there is nothing to wait for. Both names are in the scenario's list, so the dispatch's targets can
#               name them (or leave them out) as any other; they get no line in results.tsv, the step's result is theirs.
#
# Steps that are not a make target of their own:
#   drill-k8s-supplychain  make drill-k8s-supplychain with the images it needs, read from GHCR without credentials
#                          (deploy/ci/gitops-sourcemaps.sh): the linux/amd64 manifest of the web release the cluster runs
#                          as the unsigned image (no signature or attestation names it, they name its index), the newest
#                          drill-vulnerable, and the newest drill-unsigned for when Kyverno admits the first. An image
#                          that cannot be read is left out (its case SKIPs) and the step fails after the drill
#   gitops-sourcemaps      make k8s-web-sourcemaps SOURCEMAPS_DIR=<maps/ the step before found>, which checks them
#                          against the chunks the web serves before the upload; fails with the reason when that step
#                          failed or left nothing. When it found none on a branch other than main (status skipped: the
#                          release there was built before CI exported maps), this step is skipped with its reason,
#                          k8s-web-e2e runs without SVP_E2E_GLITCHTIP=1, and drill-k8s-web-obs leaves out its GlitchTip
#                          check, with a reason (SVP_WEB_OBS_SKIP_ERRORS). On main every release has its maps, so a
#                          missing one fails and both steps after it run in full.

build=k8s-gitops-up
job_minutes_default=330
k3d=1

# The repository: verify-run.sh's when sourced, this file's own when run as a script.
gitops_repo=${repo:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
# The branch the job checked out; Argo CD follows it as origin/<branch>, which a checkout of the whole history holds.
gitops_rev=$(git -C "$gitops_repo" symbolic-ref --short -q HEAD) || gitops_rev=
export gitops_rev

# gitops_up: make k8s-gitops-up on the run's branch; fails on a detached HEAD, which Argo CD could not follow.
gitops_up() {
  if [ -z "$gitops_rev" ]; then
    echo "FAIL  k8s-gitops-up: the checkout is on no branch, so Argo CD has no revision to follow"
    return 1
  fi
  make k8s-gitops-up GITOPS_REV="$gitops_rev"
}

# gitops_supplychain: see drill-k8s-supplychain in the header.
gitops_supplychain() {
  local unsigned vulnerable fallback missing= rc=0
  unsigned=$("$here/gitops-sourcemaps.sh" web-amd64) || missing="$missing the web release's linux/amd64 manifest;"
  vulnerable=$("$here/gitops-sourcemaps.sh" newest drill-vulnerable) || missing="$missing drill-vulnerable;"
  fallback=$("$here/gitops-sourcemaps.sh" newest drill-unsigned) || missing="$missing drill-unsigned;"
  echo "unsigned: ${unsigned:-none}; vulnerable: ${vulnerable:-none}; unsigned if Kyverno admits that: ${fallback:-none}"
  make drill-k8s-supplychain SUPPLYCHAIN_UNSIGNED="$unsigned" SUPPLYCHAIN_VULNERABLE="$vulnerable" \
    SUPPLYCHAIN_UNSIGNED_FALLBACK="$fallback" || rc=$?
  if [ -n "$missing" ]; then
    echo "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above):$missing"
    return 1
  fi
  return "$rc"
}

# gitops_sourcemaps DIR: see gitops-sourcemaps in the header; DIR is where the step before the scenario left its result.
gitops_sourcemaps() {
  local status reason
  status=$(cat "$1/status" 2>/dev/null) || status=
  reason=$(cat "$1/reason" 2>/dev/null) || reason=
  case $status in
  ok)
    echo "the source maps of the web image CI built: $reason"
    make k8s-web-sourcemaps SOURCEMAPS_DIR="$1/maps"
    ;;
  fail)
    echo "FAIL  the source maps of the web image CI built: $reason"
    return 1
    ;;
  *)
    echo "FAIL  no result of deploy/ci/gitops-sourcemaps.sh fetch in $1 (the job runs it before the scenario)"
    return 1
    ;;
  esac
}
export -f gitops_up gitops_supplychain gitops_sourcemaps

scenario_targets() {
  local round maps maps_status maps_reason no_maps
  # Where deploy/ci/gitops-sourcemaps.sh fetch left its result.
  maps=$(ci_temp_dir)/gitops-sourcemaps || maps=
  maps_status=$(cat "$maps/status" 2>/dev/null) || maps_status=
  maps_reason=$(head -n 1 "$maps/reason" 2>/dev/null) || maps_reason=
  step k8s-gitops-up 60 bash -c gitops_up
  step k8s-smoke 15 make k8s-smoke
  step ram-rest-start 15 bash -c 'ram_rest start'
  step drill-k8s-supplychain 40 bash -c gitops_supplychain
  step drill-k8s-threats 30 make drill-k8s-threats
  # The source maps of the web image CI built and the cluster runs, uploaded to the cluster's GlitchTip, then the
  # browser error that must map to them; without maps on a branch, both checks of the mapping are left out.
  if [ "$maps_status" = skipped ]; then
    no_maps="no source maps from CI for the web image the cluster runs on $gitops_rev (gitops-sourcemaps skipped)"
    skip gitops-sourcemaps "$maps_reason"
    step k8s-web-e2e 40 make k8s-web-e2e
    step drill-k8s-web-obs 15 env SVP_WEB_OBS_SKIP_ERRORS="$no_maps, so the e2e run sent no browser error" \
      make drill-k8s-web-obs
  else
    step gitops-sourcemaps 20 bash -c 'gitops_sourcemaps "$1"' _ "$maps"
    step k8s-web-e2e 40 env SVP_E2E_GLITCHTIP=1 make k8s-web-e2e
    step drill-k8s-web-obs 15 make drill-k8s-web-obs
  fi
  # Twice, each drill followed by the RAM peak over its own samples.
  for round in 1 2; do
    step "drill-k8s-keda-$round" 40 make drill-k8s-keda N=9
    if [ "$last_status" = skipped ]; then
      skip "ram-peak-$round" "drill-k8s-keda-$round did not run"
    else
      step "ram-peak-$round" 2 "$here/verify-sample.sh" peak "$last_start" "$last_end" "$round"
    fi
  done
  step ram-rest-end 15 bash -c 'ram_rest end'
  # The two targets of the job's step after this one (release_wait), named only while verify-run.sh lists the names it
  # checks the dispatch's targets against: run here, they would hold the job's token in this step.
  if [ -n "${listing:-}" ]; then
    skip wait-release ""
    skip measure-gitops ""
  fi
}

# release_wait: the job's step "Waiting for a release on main", after the scenario, while the cluster still runs.
# Before the run, a change of a service with Postgres has been merged on main and the promote pull request of its
# release waits, green, unmerged; it is merged while this step runs (the job's steps show which one runs). Then:
#   1. drill traffic starts (make k8s-traffic-start), so the release rolls out under load, and stops at the end;
#   2. every 30 s for at most 90 min, git ls-remote reads main on GitHub (no credentials: the repository is public).
#      Once it moved, the new commit is fetched; when it changes image.digest of a service in
#      deploy/k8s/values/services/ against its first parent it is the release, otherwise it is named and the wait goes
#      on from it. None within 90 min fails ("no release");
#   3. make measure-gitops REV=<release>, again every 30 s while it exits 2 (not pushed, synced or Ready yet), for at
#      most 20 min; its exit status is the step's. measure-gitops reads the push time from GitHub's events through
#      ci_push_time, which needs the job's token: GH_TOKEN is given to that make alone, and taken out of the
#      environment of everything else here (the drill traffic included).
# Only the lines below reach the job's log; the targets' output goes to $SVP_VERIFY_OUT/logs/release-wait.log and
# measure-gitops.log, which deploy/ci/verify-collect.sh copies into the artifact once they pass its scan. On a branch
# other than main nothing is merged for this run to measure (Argo CD follows that branch), so it prints why and exits 0.
# The dispatch's targets (SVP_VERIFY_TARGETS, empty: every target) choose as in verify-run.sh, which has already
# refused a name not in the scenario's list: neither name chosen, it skips (exit 0) without traffic or wait;
# wait-release alone waits and names the release; measure-gitops without wait-release fails at once, as it measures
# the release that wait finds.
release_wait() {
  local token=${GH_TOKEN:-} targets=${SVP_VERIFY_TARGETS:-} wait=1 measure=1 out base head rel= changed deadline rc svc \
    new old
  unset GH_TOKEN
  case $targets in
  *[!a-z0-9\ -]*)
    # Not printed back: the job's log reads a line that starts with :: as a command.
    echo "FAIL  SVP_VERIFY_TARGETS holds a character other than a-z, 0-9, - and space; nothing started"
    return 2
    ;;
  esac
  if [ -n "$targets" ]; then
    case " $targets " in *" wait-release "*) ;; *) wait= ;; esac
    case " $targets " in *" measure-gitops "*) ;; *) measure= ;; esac
  fi
  if [ -z "$wait$measure" ]; then
    echo "skipped: wait-release and measure-gitops are not in targets"
    return 0
  fi
  if [ -z "$wait" ]; then
    echo "FAIL  measure-gitops measures the release wait-release finds: name wait-release in targets with it"
    return 1
  fi
  if [ "$gitops_rev" != main ]; then
    echo "skipped: this run follows $gitops_rev, where no release is merged for it; a release is waited for and measured on a run of main"
    return 0
  fi
  out=${SVP_VERIFY_OUT:-$(ci_temp_dir)/verify}/logs
  mkdir -p "$out" || return 1
  if ! kubectl --context k3d-svp --request-timeout=10s get --raw /readyz >/dev/null 2>&1; then
    echo "FAIL  cluster svp does not answer (did k8s-gitops-up pass?): there is no cluster to roll a release out on"
    return 1
  fi
  base=$(git -C "$gitops_repo" rev-parse --verify --quiet refs/remotes/origin/main) || {
    echo "FAIL  origin/main is not in this clone"
    return 1
  }
  make -C "$gitops_repo" k8s-traffic-start >>"$out/release-wait.log" 2>&1 || {
    echo "FAIL  make k8s-traffic-start (release-wait.log)"
    return 1
  }
  # shellcheck disable=SC2064 # the folder is fixed now
  trap "make -C '$gitops_repo' k8s-traffic-stop >>'$out/release-wait.log' 2>&1" EXIT
  echo "waiting up to 90 min for main to move from ${base:0:12} to a release; drill traffic runs meanwhile"
  deadline=$((SECONDS + 90 * 60))
  while [ -z "$rel" ]; do
    head=$(GIT_TERMINAL_PROMPT=0 git -C "$gitops_repo" ls-remote origin refs/heads/main 2>>"$out/release-wait.log" |
      cut -f1) || head=
    if [[ $head =~ ^[0-9a-f]{40}$ ]] && [ "$head" != "$base" ]; then
      GIT_TERMINAL_PROMPT=0 git -C "$gitops_repo" fetch -q origin "+refs/heads/main:refs/remotes/origin/main" \
        >>"$out/release-wait.log" 2>&1 || {
        echo "FAIL  git fetch of main at ${head:0:12}"
        return 1
      }
      changed=
      for svc in "${svp_services[@]}"; do
        new=$(git -C "$gitops_repo" show "$head:deploy/k8s/values/services/$svc.yaml" 2>/dev/null |
          values_field digest 2>/dev/null) || new=
        old=$(git -C "$gitops_repo" show "$head^1:deploy/k8s/values/services/$svc.yaml" 2>/dev/null |
          values_field digest 2>/dev/null) || old=
        if [ -n "$new" ] && [ "$new" != "$old" ]; then changed="$changed $svc"; fi
      done
      if [ -n "$changed" ]; then
        rel=$head
        echo "main moved to ${head:0:12}, a release of:$changed"
        break
      fi
      echo "main moved to ${head:0:12}, which changes no image.digest of deploy/k8s/values/services/; waiting on"
      base=$head
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL  no release: main did not move to a commit that changes an image.digest within 90 min"
      return 1
    fi
    sleep 30
  done
  if [ -z "$measure" ]; then
    echo "measure-gitops: skipped, not in targets"
    return 0
  fi
  deadline=$((SECONDS + 20 * 60))
  while :; do
    rc=0
    if [ -n "$token" ]; then
      GH_TOKEN=$token make -C "$gitops_repo" measure-gitops REV="$rel" >>"$out/measure-gitops.log" 2>&1 || rc=$?
    else
      make -C "$gitops_repo" measure-gitops REV="$rel" >>"$out/measure-gitops.log" 2>&1 || rc=$?
    fi
    [ "$rc" = 2 ] && [ "$SECONDS" -lt "$deadline" ] || break
    sleep 30
  done
  case $rc in
  0) echo "make measure-gitops REV=${rel:0:12}: measured (measure-gitops.log, .k8s/drills/gitops-${rel:0:12}.json)" ;;
  2)
    echo "FAIL  make measure-gitops REV=${rel:0:12}: still not pushed, synced or Ready after 20 min (measure-gitops.log)"
    rc=1
    ;;
  *) echo "FAIL  make measure-gitops REV=${rel:0:12}: exit $rc (measure-gitops.log)" ;;
  esac
  return "$rc"
}

# Run as a script by the job (see the header), not sourced by verify-run.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  # shellcheck source=deploy/ci/platform.sh
  . "$gitops_repo/deploy/ci/platform.sh"
  # values_field and svp_services.
  # shellcheck source=deploy/k8s/lib.sh
  . "$gitops_repo/deploy/k8s/lib.sh"
  case ${1:-} in
  release) release_wait ;;
  *)
    echo "usage: bash deploy/ci/verify/gitops.sh release" >&2
    exit 2
    ;;
  esac
fi
