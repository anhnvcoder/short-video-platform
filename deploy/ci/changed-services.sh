#!/usr/bin/env bash
# changed-services.sh BASE HEAD: prints, on one line in alphabetical order, the services whose image must be built
# for the changes from commit BASE to commit HEAD; the reason goes to stderr.
#
# A service is built when a changed path is one of its image paths (`image_paths` of deploy/k8s/lib.sh: go.mod,
# go.sum, gen/, internal/, services/<svc>/, its Dockerfile, .dockerignore for a Go service; web/ and its Dockerfile for
# web, whose build context is web/ alone), or when the pipeline that builds, scans and signs changed: then all seven.
# The pipeline is .github/workflows/images.yml, anything under deploy/ci/ but the files no image job reads:
# trivy-config-ignore.yaml (read only by make trivy-config, so renewing one of its entries, due every 90 days at most,
# releases nothing), the scripts of the verification runs of .github/workflows/verify.yml (verify-host.sh,
# verify-run.sh and the scenario files under deploy/ci/verify/ it sources, verify-sample.sh, verify-mask.sh,
# verify-collect.sh and its test, verify-tempo.sh, gitops-sourcemaps.sh and its test; verify-release.sh is not one of them: values-check.sh runs it), platform-test.sh, the test of platform.sh, platform-guard.sh, the check that no other
# script reads the CI platform itself, provenance-predicate-test.sh, the test of provenance-predicate.sh, and
# promote-test.sh, the test of promote.sh and rescan.sh's list of releases (all four run by job config of ci.yml and on
# a machine; platform.sh itself counts: common.sh sources it, and so does
# provenance-predicate.sh: sign-image.sh runs it), the helpers deploy/ci/ sources from deploy/k8s/lib.sh (docker_, values_field,
# values_set_image, ghcr_prefix), and the lines of the Makefile pinning the images the gate runs (TRIVY_IMAGE,
# SYFT_IMAGE, GRYPE_IMAGE, COSIGN_IMAGE); other Makefile changes do not count. So the weekly Renovate pull request that
# bumps those tools builds and scans every image with the new trivy or grype before it merges, instead of the next
# daily rescan on main meeting it first. The cost is on main too: such a change releases all seven images again (and opens their promote
# pull request) although no service code changed. Comparing is only done when BASE is HEAD or an ancestor of it:
#   - BASE empty, all zeros, unknown to this clone, or not comparable with HEAD (force push, rewritten history): all
#     seven. Building too much costs runner minutes; missing a change would ship an image without it.
#   - HEAD a proper ancestor of BASE (an older run started again after a newer one succeeded): nothing, the newer run
#     built every change up to its own commit.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 2 ] || fail "usage: changed-services.sh BASE HEAD"
head=$(git -C "$repo_root" rev-parse --verify --quiet "$2^{commit}") || fail "HEAD $2 is not a commit of this clone"

all() {
  echo "build every service: $1" >&2
  printf '%s\n' "${svp_services[@]}" | sort | paste -sd' ' -
  exit 0
}

case $1 in
'' | *[!0]*) ;;
*) all "no base commit" ;;
esac
[ -n "$1" ] || all "no base commit"
base=$(git -C "$repo_root" rev-parse --verify --quiet "$1^{commit}") || all "base $1 is not in this clone's history"
if [ "$base" = "$head" ]; then
  echo "nothing to build: base is HEAD" >&2
  echo
  exit 0
fi
if ! git -C "$repo_root" merge-base --is-ancestor "$base" "$head"; then
  if git -C "$repo_root" merge-base --is-ancestor "$head" "$base"; then
    echo "nothing to build: HEAD is older than base ${base:0:12}, whose run already built every change up to it" >&2
    echo
    exit 0
  fi
  all "base ${base:0:12} is not an ancestor of HEAD (history rewritten or force pushed)"
fi

# --no-renames lists both sides of a rename, so a file moved out of a service's tree still counts for it.
changed=$(git -C "$repo_root" diff --name-only --no-renames "$base" "$head") ||
  fail "list the files changed since $base"

# under PATH PREFIX: true when PATH is PREFIX or lies inside the directory PREFIX.
under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

picked=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in
  deploy/ci/trivy-config-ignore.yaml | deploy/ci/verify-host.sh | deploy/ci/verify-run.sh | \
    deploy/ci/verify-sample.sh | deploy/ci/verify-mask.sh | deploy/ci/verify-collect.sh | \
    deploy/ci/verify-collect-test.sh | deploy/ci/verify-tempo.sh | deploy/ci/gitops-sourcemaps.sh | \
    deploy/ci/gitops-sourcemaps-test.sh | deploy/ci/verify/* | deploy/ci/platform-test.sh | deploy/ci/platform-guard.sh | \
    deploy/ci/provenance-predicate-test.sh | deploy/ci/promote-test.sh)
    continue
    ;;
  esac
  if under "$path" .github/workflows/images.yml || under "$path" deploy/ci || under "$path" deploy/k8s/lib.sh; then
    all "the image pipeline changed ($path)"
  fi
done <<<"$changed"
# -G keeps the Makefile only when an added or removed line of its diff is one of the four pins.
tools=$(git -C "$repo_root" diff --name-only --no-renames -G '^(TRIVY|SYFT|GRYPE|COSIGN)_IMAGE[[:space:]]*:=' \
  "$base" "$head" -- Makefile) || fail "compare the tool images of the Makefile since $base"
[ -z "$tools" ] || all "the image pipeline changed (a tool image pinned in the Makefile)"
for svc in "${svp_services[@]}"; do
  hit=
  while IFS= read -r prefix; do
    while IFS= read -r path; do
      [ -n "$path" ] && under "$path" "$prefix" && hit=$path && break
    done <<<"$changed"
    [ -z "$hit" ] || break
  done < <(image_paths "$svc")
  if [ -n "$hit" ]; then
    picked+=("$svc")
    echo "build $svc: $hit changed" >&2
  fi
done
[ ${#picked[@]} -gt 0 ] || echo "nothing to build: no image path changed since ${base:0:12}" >&2
if [ ${#picked[@]} -gt 0 ]; then printf '%s\n' "${picked[@]}" | sort | paste -sd' ' -; else echo; fi
