#!/usr/bin/env bash
# verify-release.sh REPOSITORY DIGEST: true when the release REPOSITORY@DIGEST may enter main and the GitOps cluster
# (docs/adr/0015-cicd-devsecops-stage5.md, section 7): REPOSITORY is an image of this repository, DIGEST carries a
# signature and exactly one vuln attestation of images.yml on main, and that attestation covers linux/amd64 and
# linux/arm64, lists no CRITICAL and is at most 48 hours old (SVP_ATTEST_MAX_AGE in drills). 48 hours leaves at least
# 24 before Kyverno refuses new pods at 72. Anonymous: needs no token, so a pull request job (contents: read) and a
# machine can run it; cosign from PATH, otherwise COSIGN_IMAGE.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 2 ] || fail "usage: verify-release.sh REPOSITORY DIGEST"
repo=$1 digest=$2
case $repo in "$ghcr_prefix"/*) ;; *) fail "$repo is not under $ghcr_prefix" ;; esac
is_digest "$digest" || fail "$digest is not sha256:<64 hex>"
max=$(attest_max_age)

verify_signature "$repo" "$digest" || fail "$repo@$digest has no signature of images.yml on main"
envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
  --certificate-identity "$sign_subject" "$repo@$digest" 2>/dev/null) ||
  fail "$repo@$digest has no vuln attestation of images.yml on main"
count=$(printf '%s\n' "$envelopes" | grep -c . || true)
# More than one and Kyverno would read any one of them (ADR section 7): the release is not trusted.
[ "$count" -eq 1 ] || fail "$repo@$digest carries $count vuln attestations, not exactly one"
problem=$(printf '%s\n' "$envelopes" | jq -r '.payload | @base64d' | check_vuln_statement "$digest" "$max") ||
  fail "$repo@$digest: vuln attestation $problem"
echo "ok    $repo@$digest signed, one vuln attestation, both platforms, no CRITICAL, within $((max / 60)) minutes"
