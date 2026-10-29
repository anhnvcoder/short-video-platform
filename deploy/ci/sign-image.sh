#!/usr/bin/env bash
# sign-image.sh [--allow-critical] INDEX DIR DIR: signs and attests one released image,
# keyless: cosign gets a short-lived certificate from Fulcio for the OIDC identity of this
# workflow run (images.yml on refs/heads/main) and records the signature in Rekor; there is no key to leak or rotate.
# INDEX is the directory merge-index.sh wrote (repository, tag, digest); each DIR is one platform leg (platform,
# digest, config-digest, trivy.json, scan times, sbom.spdx.json).
#
# Before anything is signed, the index is read back and must hold exactly the two scanned manifests; the vuln
# predicate is built from the two gating scans (vuln-predicate.sh, which refuses a CRITICAL unless --allow-critical,
# given only for the drill image drill-vulnerable). Then:
#   - cosign sign on the index digest (pods run the index digest, so that is what Kyverno verifies);
#   - cosign attest --type spdxjson of each platform's SBOM on that platform's manifest digest;
#   - cosign attest --type vuln of the predicate on the index digest;
#   - cosign attest --type slsaprovenance1 of the build provenance (provenance-predicate.sh: workflow, ref, commit and
#     run of this CI run) on the index digest. Not for the drill images: they are no release.
# The provenance names the workflow at its ref as its builder; it is attested only when that builder is the identity
# this job signs as (the subject of the keyless certificate), so a predicate made on a machine ("local") or by another
# workflow is never signed. Both predicates are written before anything is signed: a run that cannot write one signs
# nothing.
# Every command uses cosign's older format (.sig/.att images) with --replace: in that format a new vuln attestation
# replaces the previous one, so the index always carries exactly one, which Kyverno v1.19.1 needs (it keeps one
# payload per type, not the newest). --replace swaps only the layer of the same type, so the provenance and the vuln
# attestation of the index stay side by side, and the daily rescan's new vuln leaves the provenance as it is (a fact
# of one build, it never ages). The two format flags go together: --new-bundle-format=false alone is refused
# while the signing config is on. Never mix formats on one digest: one bundle and verifiers read only bundles.
# Needs cosign on PATH, `docker login ghcr.io`, and the id-token permission of the job.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

predicate_flags=()
if [ "${1:-}" = --allow-critical ]; then
  predicate_flags=(--allow-critical)
  shift
fi
[ $# -eq 3 ] || fail "usage: sign-image.sh [--allow-critical] INDEX DIR DIR"
index=$1 a=$2 b=$3
repo=$(cat "$index/repository") digest=$(cat "$index/digest")
case $repo in "$ghcr_prefix"/*) ;; *) fail "$repo is not an image of this repository" ;; esac
is_digest "$digest" || fail "$index has no index digest"
if [ ${#predicate_flags[@]} -gt 0 ] && [ "$repo" != "$ghcr_prefix/drill-vulnerable" ]; then
  fail "--allow-critical is only for the drill image drill-vulnerable"
fi
check_index "$repo" "$digest" "$a" "$b" || fail "$repo@$digest is not an index of exactly the two scanned manifests"

release=true
for drill in "${drill_images[@]}"; do [ "$repo" != "$ghcr_prefix/$drill" ] || release=false; done

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT
predicate=$work/vuln.json provenance=$work/provenance.json
"$ci_dir/vuln-predicate.sh" ${predicate_flags[@]+"${predicate_flags[@]}"} "$predicate" "$a" "$b" ||
  fail "build the vuln predicate of $repo@$digest"
if [ "$release" = true ]; then
  sign_identity
  builder=$(ci_builder_id) || fail "read the builder of this run"
  [ "$builder" = "$sign_subject" ] ||
    fail "the provenance would name builder '$builder', but releases are signed only as $sign_subject"
  "$ci_dir/provenance-predicate.sh" "$provenance" || fail "build the provenance predicate of $repo@$digest"
fi

legacy=(--yes --new-bundle-format=false --use-signing-config=false)
cosign sign "${legacy[@]}" "$repo@$digest" || fail "sign $repo@$digest"
for dir in "$a" "$b"; do
  cosign attest "${legacy[@]}" --replace --type spdxjson --predicate "$dir/sbom.spdx.json" \
    "$repo@$(cat "$dir/digest")" ||
    fail "attest the SBOM of $(cat "$dir/platform") on $repo@$(cat "$dir/digest")"
done
cosign attest "${legacy[@]}" --replace --type vuln --predicate "$predicate" "$repo@$digest" ||
  fail "attest the vuln predicate on $repo@$digest"
if [ "$release" = true ]; then
  cosign attest "${legacy[@]}" --replace --type slsaprovenance1 --predicate "$provenance" "$repo@$digest" ||
    fail "attest the provenance on $repo@$digest"
  echo "ok    $repo@$digest signed; SBOM on both manifests, vuln and provenance on the index"
else
  echo "ok    $repo@$digest signed; SBOM on both manifests, vuln on the index (a drill image: no provenance)"
fi
