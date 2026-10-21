#!/usr/bin/env bash
# sign-image.sh [--allow-critical] INDEX DIR DIR: signs and attests one released image (docs/adr/0015-cicd-devsecops-
# stage5.md, section 7), keyless: cosign gets a short-lived certificate from Fulcio for the OIDC identity of this
# workflow run (images.yml on refs/heads/main) and records the signature in Rekor; there is no key to leak or rotate.
# INDEX is the directory merge-index.sh wrote (repository, tag, digest); each DIR is one platform leg (platform,
# digest, config-digest, trivy.json, scan times, sbom.spdx.json).
#
# Before anything is signed, the index is read back and must hold exactly the two scanned manifests; the vuln
# predicate is built from the two gating scans (vuln-predicate.sh, which refuses a CRITICAL unless --allow-critical,
# given only for the drill image drill-vulnerable). Then:
#   - cosign sign on the index digest (pods run the index digest, so that is what Kyverno verifies);
#   - cosign attest --type spdxjson of each platform's SBOM on that platform's manifest digest;
#   - cosign attest --type vuln of the predicate on the index digest.
# Every command uses cosign's older format (.sig/.att images) with --replace: in that format a new vuln attestation
# replaces the previous one, so the index always carries exactly one, which Kyverno v1.19.1 needs (it keeps one
# payload per type, not the newest). The two format flags go together: --new-bundle-format=false alone is refused
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

predicate=$(mktemp) || fail "create a temporary file"
trap 'rm -f "$predicate"' EXIT
"$ci_dir/vuln-predicate.sh" ${predicate_flags[@]+"${predicate_flags[@]}"} "$predicate" "$a" "$b" ||
  fail "build the vuln predicate of $repo@$digest"

legacy=(--yes --new-bundle-format=false --use-signing-config=false)
cosign sign "${legacy[@]}" "$repo@$digest" || fail "sign $repo@$digest"
for dir in "$a" "$b"; do
  cosign attest "${legacy[@]}" --replace --type spdxjson --predicate "$dir/sbom.spdx.json" \
    "$repo@$(cat "$dir/digest")" ||
    fail "attest the SBOM of $(cat "$dir/platform") on $repo@$(cat "$dir/digest")"
done
cosign attest "${legacy[@]}" --replace --type vuln --predicate "$predicate" "$repo@$digest" ||
  fail "attest the vuln predicate on $repo@$digest"
echo "ok    $repo@$digest signed; SBOM on both manifests, vuln on the index"
