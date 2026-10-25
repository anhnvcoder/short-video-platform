#!/usr/bin/env bash
# values-check.sh BASE: for every file of deploy/k8s/values/services/ that changed from commit BASE to HEAD (all seven
# when BASE is empty), a non-empty image.digest must name a release that may enter main: right repository, signed by
# images.yml on main, one vuln attestation covering both platforms, no CRITICAL, at most 48 hours old
# (verify-release.sh). Kyverno accepts attestations up to 72 hours,
# so a digest that enters main with an older one (a rolled-up promote PR, a revert to an old digest) would have its
# new pods refused; this check catches it before the merge. Uses no token.
#
# On failure prints the dispatch that refreshes the attestations of exactly these values (PR_NUMBER from the
# environment when the run is a pull request; otherwise the commit).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 1 ] || fail "usage: values-check.sh BASE"
dir=deploy/k8s/values/services
if [ -n "$1" ]; then
  files=$(git -C "$repo_root" diff --name-only --no-renames "$1" HEAD -- "$dir") ||
    fail "list the values changed since $1"
else
  files=$(for svc in "${svp_services[@]}"; do echo "$dir/$svc.yaml"; done)
fi

failed=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  svc=$(basename "$file" .yaml)
  if ! printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$svc"; then
    echo "FAIL  $file is not the values file of a service" >&2
    failed=1
    continue
  fi
  if [ ! -f "$repo_root/$file" ]; then
    echo "FAIL  $file was removed: the GitOps path needs the values of all seven services" >&2
    failed=1
    continue
  fi
  if ! digest=$(values_field digest <"$repo_root/$file") || ! repo=$(values_field repository <"$repo_root/$file"); then
    echo "FAIL  $file: image.repository or image.digest is not one plain line in the image block" >&2
    failed=1
    continue
  fi
  if [ -z "$digest" ]; then
    echo "ok    $svc: no digest, not released yet, nothing to verify"
    continue
  fi
  if [ "$repo" != "$ghcr_prefix/$svc" ]; then
    echo "FAIL  $svc: image.repository is $repo, a release must come from $ghcr_prefix/$svc" >&2
    failed=1
    continue
  fi
  "$ci_dir/verify-release.sh" "$repo" "$digest" || failed=1
done <<<"$files"

if [ "$failed" -ne 0 ]; then
  ref=refs/pull/${PR_NUMBER:-}/head
  [ -n "${PR_NUMBER:-}" ] || ref=$(git -C "$repo_root" rev-parse HEAD)
  refresh=$(ci_dispatch_hint images.yml main rescan=true "values_ref=$ref") || exit 1
  echo "Refresh the attestations of these values, then run this check again:" >&2
  echo "  $refresh" >&2
  ci_summary "values-check failed: refresh with \`$refresh\`"
fi
exit "$failed"
