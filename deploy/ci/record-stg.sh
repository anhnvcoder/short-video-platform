#!/usr/bin/env bash
# record-stg.sh RELEASE_SET: job record-stg of verify.yml, on main once the scenario step of job gitops passed and wrote
# RELEASE_SET (output recorded of that job; the wait for a release after it does not count). Records in svp-gitops that
# stg ran the set of releases of RELEASE_SET (release-set.json of that job's artifact, written by
# deploy/ci/release-set.sh verify) through every check of the run: a deployment record of environment stg whose ref is
# the commit of svp-gitops stg synced and whose payload is the file as it is, state success (ci_deployment_record of
# platform.sh). A pull request to envs/prd/ of svp-gitops is checked against these records (deploy/ci/gitops-check.sh),
# and promote prd copies one (deploy/ci/promote-prd.sh).
#
# Before writing: the file must be a payload of the form release-set.sh counts (release-set.sh check), and its run_url
# this very run (ci_run_url), so an artifact of another run is never recorded as this one's. The payload holds
# repositories, tags, digests, commits, times and step names only; it is printed before it is sent.
#
# Environment: the token of the app, with deployments write on svp-gitops alone (GH_TOKEN on GitHub). A machine writes
# nothing: it prints the requests instead.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 1 ] || fail "usage: record-stg.sh RELEASE_SET"
file=$1
[ -f "$file" ] ||
  fail "no $file: job gitops puts release-set.json into its artifact only when the set stg ran could be recorded (its step release-set)"
"$ci_dir/release-set.sh" check "$file"
run=$(ci_run_url) || exit 1
got=$(jq -r .run_url "$file")
[ "$got" = "$run" ] || fail "$file is of run $got, not of this run $run: only this run's checks are recorded here"
ref=$(jq -r .ref "$file")
echo "record of stg in $gitops_repo: svp-gitops ${ref:0:12}, charts $(jq -r '.charts.revision[0:12]' "$file"), deployed at $(jq -r .deployed_at "$file")"
jq -r '.images | to_entries[] | "  \(.key): \(.value.repository):\(.value.tag)@\(.value.digest)"' "$file"
id=$(ci_deployment_record "$gitops_repo" stg "$ref" "$file" "stg ran this set through the checks of the run" "$run") ||
  fail "record the set of stg in $gitops_repo"
if [ "$(ci_platform)" = local ]; then
  printf '%s\n' "$id"
  exit 0
fi
echo "ok    deployment record #$id of stg in $gitops_repo, ref ${ref:0:12}"
ci_summary "Record of stg: deployment #$id in $gitops_repo, svp-gitops \`${ref:0:12}\`, the seven releases of \`release-set.json\`."
