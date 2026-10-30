#!/usr/bin/env bash
# verify-release.sh [--gitops DIR] [--rev REV] [--env ENV] REPOSITORY DIGEST: true when the release REPOSITORY@DIGEST
# may enter an environment of the deployment configuration: REPOSITORY is <imagePrefix><service> of a release source
# whose services name <service>, DIGEST carries a signature and exactly one vuln attestation of that source's
# images.yml on main, and that attestation covers linux/amd64 and linux/arm64, lists no CRITICAL and is at most 48
# hours old (SVP_ATTEST_MAX_AGE in drills). 48 hours leaves at least 24 before Kyverno refuses new pods at 72.
# Anonymous: needs no token, so a pull request job (contents: read) and a machine can run it; cosign from PATH,
# otherwise COSIGN_IMAGE.
# The policy of an environment is chart svp-policy at the commit its envs/ENV/charts.yaml pins, in environment ENV
# (every environment without --env) of the deployment configuration DIR (a tree of svp-gitops; gitops_dir of
# deploy/k8s/lib.sh without --gitops) at its commit REV (DIR as it is on disk without --rev). Its table of release
# sources decides the source, so the identity, of REPOSITORY (release_source_in of common.sh), as Kyverno picks the
# attestor by prefix. When it checks build provenance (requireProvenance: its values.yaml, then envs/ENV/svp-policy.yaml,
# provenance_required of common.sh), the release must also carry exactly one provenance attestation of the same
# identity that passes what Kyverno checks (builder.id, workflow repository and ref of its source), whose source commit
# is the commit the certificate of its signature names (cosign --certificate-github-workflow-sha): a provenance that
# claims another commit than the run that signed it is refused.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

rev= env= dir=
while [ $# -gt 2 ]; do
  case $1 in
  --gitops) dir=$2 ;;
  --rev) rev=$2 ;;
  --env) env=$2 ;;
  *) break ;;
  esac
  shift 2
done
[ $# -eq 2 ] || fail "usage: verify-release.sh [--gitops DIR] [--rev REV] [--env ENV] REPOSITORY DIGEST"
repo=$1 digest=$2
is_digest "$digest" || fail "$digest is not sha256:<64 hex>"
max=$(attest_max_age)
provenance=$(provenance_required "$rev" "$env" "$dir") || fail "read whether chart svp-policy checks build provenance (above)"
source=$(release_source_in "$repo" "$rev" "$env" "$dir") || fail "find the release source of $repo (above)"
use_release_source "$source"

cosign_ verify --certificate-oidc-issuer "$sign_issuer" --certificate-identity "$sign_subject" "$repo@$digest" \
  >/dev/null || fail "$repo@$digest has no signature of $sign_subject (release source $source_name)"
envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
  --certificate-identity "$sign_subject" "$repo@$digest" 2>/dev/null) ||
  fail "$repo@$digest has no vuln attestation of $sign_subject"
count=$(printf '%s\n' "$envelopes" | grep -c . || true)
# More than one and Kyverno would read any one of them: the release is not trusted.
[ "$count" -eq 1 ] || fail "$repo@$digest carries $count vuln attestations, not exactly one"
problem=$(printf '%s\n' "$envelopes" | jq -r '.payload | @base64d' | check_vuln_statement "$digest" "$max") ||
  fail "$repo@$digest: vuln attestation $problem"
if [ "$provenance" = true ]; then
  if [ "$source_name" = backend ]; then
    rebuild=$(ci_dispatch_hint images.yml main "services=${repo##*/}") || exit 1
  else
    # Another source's release is built by that repository's own workflow, not by a dispatch of this one.
    rebuild="a run of images.yml on main of $provenance_repository"
  fi
  envelopes=$(cosign_ verify-attestation --type slsaprovenance1 --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$repo@$digest" 2>/dev/null) || {
    # Only cosign's own "no attestation of this type" means a release from before provenance; any other error (GHCR or
    # Sigstore out of reach) is no reason to build it again.
    absent=0
    why=$(provenance_absent "$sign_issuer" "$sign_subject" "$repo@$digest" 2>&1) || absent=$?
    [ "$absent" -ne 0 ] ||
      fail "$repo@$digest has no provenance attestation of $sign_subject, which the policy requires here: a release built before CI attested provenance; release it again ($rebuild)"
    fail "$repo@$digest: its provenance attestation could not be verified (${why:-cosign failed once, then verified one}); check again, do not build it again"
  }
  count=$(printf '%s\n' "$envelopes" | grep -c . || true)
  # As for vuln: Kyverno keeps one payload per type, so with two it could read either.
  [ "$count" -eq 1 ] || fail "$repo@$digest carries $count provenance attestations, not exactly one"
  commit=$(printf '%s\n' "$envelopes" | jq -r '.payload | @base64d' | check_provenance_statement "$digest") ||
    fail "$repo@$digest: provenance $commit"
  cosign_ verify-attestation --type slsaprovenance1 --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" --certificate-github-workflow-sha "$commit" "$repo@$digest" >/dev/null 2>&1 ||
    fail "$repo@$digest: the provenance names commit $commit, the certificate of its signature another (or none)"
  provenance=", provenance of ${commit:0:12} by $sign_subject"
else
  provenance=
fi
echo "ok    $repo@$digest signed, one vuln attestation, both platforms, no CRITICAL, within $((max / 60)) minutes$provenance"
