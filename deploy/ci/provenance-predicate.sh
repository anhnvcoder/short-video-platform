#!/usr/bin/env bash
# provenance-predicate.sh OUT: writes to OUT the predicate of the build provenance attestation of a released image
# (SLSA provenance v1, cosign --type slsaprovenance1), from the context of this CI run and nothing else: every value
# comes from a ci_* function of platform.sh, never from an argument or a variable a step could set.
#
# The predicate has the shape of the GitHub Actions Workflow build type (the one actions/attest writes), and only these
# fields:
#   buildDefinition.buildType                        https://actions.github.io/buildtypes/workflow/v1
#   buildDefinition.externalParameters.workflow      {ref, repository, path}: the workflow file that ran, at its ref
#   buildDefinition.externalParameters.inputs        {services}: only for a run started by hand with that input set
#   buildDefinition.resolvedDependencies             exactly one: git+<repository>@<ref of the run>, {gitCommit}
#   runDetails.builder.id                            the workflow file at its ref, as a URL: on GitHub, the subject of
#                                                    the keyless certificate of the job that signs this predicate
#   runDetails.metadata.invocationId                 the page of this attempt of the run
# No token, no other variable of the run, no time: nothing checks them and each one more is one more to keep honest.
# The subject (the index digest) is added by cosign attest.
#
# The repository, ref and commit are those of the run, whichever repository it is: a job of another release source's
# repository running this script from a pinned checkout of this one records its own repository and commit, never
# this one's. On a machine every value of the run is "local" but the repository and the commit, those of the checkout
# whose code is built (SVP_CODE_ROOT, or this checkout: ci_repo_url and ci_commit), so the predicate is still complete
# and can be tested; it is never signed: only the sign job of CI attests, and sign-image.sh first checks that the
# builder is the identity of the release source it signs for.
#
# Exit 0: OUT written. Exit 1: the CI context is missing or malformed; nothing written. Exit 2: usage.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 1 ] || {
  echo "FAIL  usage: provenance-predicate.sh OUT" >&2
  exit 2
}
out=$1

builder=$(ci_builder_id) && invocation=$(ci_run_attempt_url) && repository=$(ci_repo_url) && ref=$(ci_ref) &&
  commit=$(ci_commit) && workflow_path=$(ci_workflow_path) && workflow_ref=$(ci_workflow_ref) &&
  services=$(ci_dispatch_input services) || fail "read the context of this CI run"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "the commit of this run is not 40 lowercase hex: '$commit'"
[[ $repository =~ ^https://[^[:space:]@]+$ ]] || fail "the repository is not a plain https:// URL: '$repository'"
for value in "$builder" "$invocation" "$ref" "$workflow_path" "$workflow_ref"; do
  [[ $value =~ ^[^[:space:]]+$ ]] || fail "a value of the CI context is empty or holds a blank: '$value'"
done

tmp=$(mktemp "$out.XXXXXX") || fail "create a temporary file beside $out"
trap 'rm -f "$tmp"' EXIT
jq -n \
  --arg builder "$builder" --arg invocation "$invocation" --arg repository "$repository" --arg ref "$ref" \
  --arg commit "$commit" --arg path "$workflow_path" --arg workflow_ref "$workflow_ref" --arg services "$services" '
  {
    buildDefinition: {
      buildType: "https://actions.github.io/buildtypes/workflow/v1",
      externalParameters: (
        {workflow: {ref: $workflow_ref, repository: $repository, path: $path}}
        + if $services == "" then {} else {inputs: {services: $services}} end
      ),
      resolvedDependencies: [{uri: "git+\($repository)@\($ref)", digest: {gitCommit: $commit}}]
    },
    runDetails: {
      builder: {id: $builder},
      metadata: {invocationId: $invocation}
    }
  }' >"$tmp" || fail "write the predicate"
mv "$tmp" "$out"
trap - EXIT
echo "ok    provenance predicate written to $out"
