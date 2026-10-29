#!/usr/bin/env bash
# values-check.sh BASE: for every file of deploy/k8s/values/services/ that changed from commit BASE to HEAD, a non-empty
# image.digest must name a release that may enter main: right repository, signed by images.yml on main, one vuln
# attestation covering both platforms, no CRITICAL, at most 48 hours old, and a build provenance attestation when chart
# svp-policy checks provenance in any environment of this revision (verify-release.sh, which reads that from the
# policy's values and overlays in the working tree). All seven files when BASE is empty, or when a values file of chart
# svp-policy changed since BASE (policy_values_paths of common.sh): what every release must carry may have changed, so
# the pull request that turns provenance on fails while a release in the values has none. Kyverno accepts
# attestations up to 72 hours, so a digest that enters main with an older one (a rolled-up promote PR, a revert to an
# old digest) would have its new pods refused; this check catches it before the merge. Uses no token.
#
# On failure prints the dispatch that refreshes the attestations of exactly these values (PR_NUMBER from the
# environment when the run is a pull request; otherwise the commit).
#
# values-check.sh --gitops DIR BASE: the same check on a tree of the deployment repository svp-gitops (gitops-check.sh
# runs it), whose release images are envs/<env>/images/<service>.yaml: the files of DIR's git repository that changed
# from commit BASE to HEAD, all of them when BASE is empty or when the policy's values of an environment changed
# (envs/<env>/svp-policy.yaml, or envs/<env>/charts.yaml, which pins the chart's own values). Each release is checked
# for its environment as Argo CD hands chart svp-policy its values there: the chart's values.yaml at the revision of
# envs/<env>/charts.yaml, then envs/<env>/svp-policy.yaml of DIR. verify-release.sh reads both from a tree laid out
# as this repository, so it runs from a copy of deploy/ci with these two files where it reads them. The refresh
# printed on failure is the rescan of the releases in main's values.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

gitops=
if [ "${1:-}" = --gitops ]; then
  [ $# -eq 3 ] || fail "usage: values-check.sh --gitops DIR BASE"
  gitops=$(cd "$2" 2>/dev/null && pwd -P) || fail "$2 is not a directory"
  shift 2
fi
[ $# -eq 1 ] || fail "usage: values-check.sh BASE | values-check.sh --gitops DIR BASE"
if [ -n "$gitops" ]; then
  tree=$gitops
  envs=$(cd "$tree/envs" 2>/dev/null && for e in */; do [ -d "$e" ] && echo "${e%/}"; done) || envs=
  [ -n "$envs" ] || fail "$tree/envs holds no environment"
  all=$(for e in $envs; do for svc in "${svp_services[@]}"; do echo "envs/$e/images/$svc.yaml"; done; done)
  if [ -n "$1" ]; then
    [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" = "$tree" ] ||
      fail "$tree is not the top of a git repository, so nothing changed since $1 can be listed"
    files=$(git -C "$tree" diff --name-only --no-renames "$1" HEAD -- 'envs/*/images/*') ||
      fail "list the image files changed since $1"
    policy=$(git -C "$tree" diff --name-only --no-renames "$1" HEAD -- 'envs/*/svp-policy.yaml' 'envs/*/charts.yaml') ||
      fail "list the values of chart svp-policy changed since $1"
    if [ -n "$policy" ]; then
      echo "note  the values of chart svp-policy changed since ${1:0:12} ($(paste -sd ' ' - <<<"$policy")): every release must carry what they ask now"
      files=$(printf '%s\n' "$files" "$all" | sed '/^$/d' | sort -u)
    fi
  else
    files=$all
  fi
  tmp=$(mktemp -d) || fail "create a temporary directory"
  trap 'rm -rf "$tmp"' EXIT
  # The copy of deploy/ci has no Makefile to read COSIGN_IMAGE from, so it gets it from the environment.
  if ! command -v cosign >/dev/null 2>&1; then
    COSIGN_IMAGE=$(tool_image COSIGN_IMAGE)
    export COSIGN_IMAGE
  fi
else
  dir=deploy/k8s/values/services
  all=$(for svc in "${svp_services[@]}"; do echo "$dir/$svc.yaml"; done)
  if [ -n "$1" ]; then
    files=$(git -C "$repo_root" diff --name-only --no-renames "$1" HEAD -- "$dir") ||
      fail "list the values changed since $1"
    policy=$(git -C "$repo_root" diff --name-only --no-renames "$1" HEAD -- "${policy_values_paths[@]}") ||
      fail "list the values of chart svp-policy changed since $1"
    if [ -n "$policy" ]; then
      echo "note  the values of chart svp-policy changed since ${1:0:12} ($(paste -sd ' ' - <<<"$policy")): every release in the values must carry what they ask now"
      files=$(printf '%s\n' "$files" "$all" | sed '/^$/d' | sort -u)
    fi
  else
    files=$all
  fi
fi

# checker ENV: prints the verify-release.sh that checks a release of environment ENV of the gitops tree: a copy of
# deploy/ci with lib.sh, the values.yaml of chart svp-policy at the revision of envs/ENV/charts.yaml and the overlay
# envs/ENV/svp-policy.yaml, each where verify-release.sh reads it.
checker() {
  local root=$tmp/root-$1 rev
  if [ ! -d "$root" ]; then
    rev=$(sed -n 's/^revision: *//p' "$tree/envs/$1/charts.yaml" 2>/dev/null) && [ -n "$rev" ] &&
      git -C "$repo_root" cat-file -e "$rev:deploy/helm/svp-policy/values.yaml" 2>/dev/null || {
      echo "FAIL  envs/$1/charts.yaml names no revision of this repository with chart svp-policy" >&2
      return 1
    }
    mkdir -p "$root/deploy/k8s/envs/$1" "$root/deploy/helm/svp-policy" &&
      cp -R "$ci_dir" "$root/deploy/ci" && cp "$repo_root/deploy/k8s/lib.sh" "$root/deploy/k8s/lib.sh" &&
      git -C "$repo_root" show "$rev:deploy/helm/svp-policy/values.yaml" >"$root/deploy/helm/svp-policy/values.yaml" ||
      return 1
    if [ -f "$tree/envs/$1/svp-policy.yaml" ]; then
      cp "$tree/envs/$1/svp-policy.yaml" "$root/deploy/k8s/envs/$1/svp-policy.yaml" || return 1
    fi
  fi
  echo "$root/deploy/ci/verify-release.sh"
}

failed=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  svc=$(basename "$file" .yaml)
  env=
  if [ -n "$gitops" ]; then
    env=$(sed -n 's|^envs/\([^/]*\)/images/[^/]*$|\1|p' <<<"$file")
    root=$tree
  else
    root=$repo_root
  fi
  if ! printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$svc" || { [ -n "$gitops" ] && [ -z "$env" ]; }; then
    echo "FAIL  $file is not the values file of a service" >&2
    failed=1
    continue
  fi
  if [ ! -f "$root/$file" ]; then
    echo "FAIL  $file was removed: the GitOps path needs the values of all seven services" >&2
    failed=1
    continue
  fi
  if ! digest=$(values_field digest <"$root/$file") || ! repo=$(values_field repository <"$root/$file"); then
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
  if [ -n "$gitops" ]; then
    if ! verify=$(checker "$env"); then
      failed=1
      continue
    fi
    echo "check $file"
    "$verify" --env "$env" "$repo" "$digest" || failed=1
  else
    "$ci_dir/verify-release.sh" "$repo" "$digest" || failed=1
  fi
done <<<"$files"

if [ "$failed" -ne 0 ]; then
  ref=refs/pull/${PR_NUMBER:-}/head
  [ -n "${PR_NUMBER:-}" ] || ref=$(git -C "$repo_root" rev-parse HEAD)
  if [ -n "$gitops" ]; then
    # Run from a clone of svp-gitops, gh would pick that repository: images.yml is the code repository's.
    refresh="$(ci_dispatch_hint images.yml main rescan=true) --repo anhnvcoder/short-video-platform" || exit 1
  else
    refresh=$(ci_dispatch_hint images.yml main rescan=true "values_ref=$ref") || exit 1
  fi
  echo "Refresh the vuln attestations of these values, then run this check again:" >&2
  echo "  $refresh" >&2
  echo "A missing provenance needs a new release instead, as named above: a rescan does not add one." >&2
  ci_summary "values-check failed: refresh the vuln attestations with \`$refresh\`; a missing provenance needs a new release (above)"
fi
exit "$failed"
