#!/usr/bin/env bash
# values-check.sh --gitops DIR BASE: the release check of a tree of the deployment repository svp-gitops
# (gitops-check.sh runs it in that repository's check; the bootstrap of the GitOps path runs it too), whose release
# images are envs/<env>/images/<service>.yaml. For every such file of DIR's git repository that changed from commit BASE
# to HEAD, a non-empty image.digest must name a release that may enter that environment: right repository, signed by
# images.yml on main, one vuln attestation covering both platforms, no CRITICAL, at most 48 hours old, and a build
# provenance attestation when chart svp-policy checks provenance in that environment (verify-release.sh --gitops DIR
# --env <env>: the chart's values.yaml at the commit envs/<env>/charts.yaml pins, then envs/<env>/svp-policy.yaml of
# DIR, as Argo CD hands them to the chart). Every image file of an environment whose policy changed since BASE (its
# envs/<env>/svp-policy.yaml or envs/<env>/charts.yaml: policy_values_paths of common.sh), since what every release
# there must carry may have changed: the pull request that turns provenance on fails while a release of that
# environment has none. Every image file of every environment when BASE is empty (DIR need not be a git repository
# then). Kyverno accepts attestations up to 72 hours, so a digest that enters an environment with an older one (a
# rolled-up promote PR, a revert to an old digest) would have its new pods refused; this check catches it before the
# merge. Uses no token.
#
# On failure prints the dispatch of the code repository's images.yml that refreshes the vuln attestations of the
# releases svp-gitops names.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 3 ] && [ "$1" = --gitops ] || fail "usage: values-check.sh --gitops DIR BASE"
tree=$(cd "$2" 2>/dev/null && pwd -P) || fail "$2 is not a directory"
base=$3
envs=$(cd "$tree/envs" 2>/dev/null && for e in */; do [ -d "$e" ] && echo "${e%/}"; done) || envs=
[ -n "$envs" ] || fail "$tree/envs holds no environment"
# all_of ENV...: the image files of the environments ENV.
all_of() {
  local e svc
  for e in "$@"; do for svc in "${svp_services[@]}"; do echo "envs/$e/images/$svc.yaml"; done; done
}
if [ -n "$base" ]; then
  [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" = "$tree" ] ||
    fail "$tree is not the top of a git repository, so nothing changed since $base can be listed"
  files=$(git -C "$tree" diff --name-only --no-renames "$base" HEAD -- 'envs/*/images/*') ||
    fail "list the image files changed since $base"
  policy=$(git -C "$tree" diff --name-only --no-renames "$base" HEAD -- "${policy_values_paths[@]}") ||
    fail "list the policy files of the environments changed since $base"
  if [ -n "$policy" ]; then
    # shellcheck disable=SC2046 # one environment name per word
    set -- $(sed -n 's|^envs/\([^/]*\)/[^/]*$|\1|p' <<<"$policy" | sort -u)
    echo "note  what the releases of $* must carry may have changed since ${base:0:12} ($(paste -sd ' ' - <<<"$policy")): every release there is checked"
    files=$(printf '%s\n' "$files" "$(all_of "$@")" | sed '/^$/d' | sort -u)
  fi
else
  # shellcheck disable=SC2086 # one environment name per word
  files=$(all_of $envs)
fi

failed=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  svc=$(basename "$file" .yaml)
  env=$(sed -n 's|^envs/\([^/]*\)/images/[^/]*$|\1|p' <<<"$file")
  if ! printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$svc" || [ -z "$env" ]; then
    echo "FAIL  $file is not the image file of a service" >&2
    failed=1
    continue
  fi
  if [ ! -f "$tree/$file" ]; then
    echo "FAIL  $file was removed: the GitOps path needs the image files of all seven services" >&2
    failed=1
    continue
  fi
  if ! digest=$(values_field digest <"$tree/$file") || ! repo=$(values_field repository <"$tree/$file"); then
    echo "FAIL  $file: image.repository or image.digest is not one plain line in the image block" >&2
    failed=1
    continue
  fi
  if [ -z "$digest" ]; then
    echo "ok    $file: no digest, not released yet, nothing to verify"
    continue
  fi
  if [ "$repo" != "$ghcr_prefix/$svc" ]; then
    echo "FAIL  $file: image.repository is $repo, a release must come from $ghcr_prefix/$svc" >&2
    failed=1
    continue
  fi
  echo "check $file"
  "$ci_dir/verify-release.sh" --gitops "$tree" --env "$env" "$repo" "$digest" || failed=1
done <<<"$files"

if [ "$failed" -ne 0 ]; then
  refresh=$(ci_dispatch_hint images.yml main rescan=true) || exit 1
  echo "Refresh the vuln attestations of these releases, then run this check again:" >&2
  echo "  $refresh" >&2
  echo "A missing provenance needs a new release instead, as named above: a rescan does not add one." >&2
  ci_summary "values-check failed: refresh the vuln attestations with \`$refresh\`; a missing provenance needs a new release (above)"
fi
exit "$failed"
