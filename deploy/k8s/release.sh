#!/usr/bin/env bash
# Releases a service for the GitOps path (docs/adr/0014-kubernetes-local-stage4.md, sections 6 and 12): builds its
# image from the commit at HEAD, pushes it to the registry as svp/<service>:<first 12 hex digits of the commit>, and
# writes that tag as image.tag of deploy/k8s/values/services/<service>.yaml. The learner reviews, commits and pushes
# the values file; Argo CD then deploys the tag. Nothing is committed or pushed here.
#
# Usage: release.sh <service>|all (`make k8s-release SVC=...`). Refused while a path the image is built from has a
# change that is not committed: the image would not hold it, and the tag would name a commit that does not match the
# code in front of the learner. Needs the registry only, not the cluster: it is created when missing.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"

usage="usage: make k8s-release SVC=<service>|all (services: ${svp_services[*]})"
[ $# = 1 ] && [ -n "$1" ] || fail "$usage"
if [ "$1" = all ]; then
  services=("${svp_services[@]}")
else
  case " ${svp_services[*]} " in
    *" $1 "*) services=("$1") ;;
    *) fail "unknown service '$1'; $usage" ;;
  esac
fi

head=$(git -C "$repo_root" rev-parse --verify --quiet 'HEAD^{commit}') || fail "HEAD is not a commit"
paths=()
for svc in "${services[@]}"; do
  while IFS= read -r p; do paths+=("$p"); done < <(image_paths "$svc")
done
# Untracked files count too (git archive leaves them out of the image).
dirty=$(git -C "$repo_root" status --porcelain --untracked-files=all -- "${paths[@]}") ||
  fail "read git status of the image paths"
if [ -n "$dirty" ]; then
  printf '%s\n' "$dirty" >&2
  fail "the paths above, which the image of ${services[*]} is built from, have changes that are not committed; commit them (or stash them) and run again"
fi

ensure_registry
files=()
for svc in "${services[@]}"; do
  build_release_image "$svc" "$head"
  file="deploy/k8s/values/services/$svc.yaml"
  set_values_tag "$repo_root/$file" "$release_tag"
  files+=("$file")
  ok "$file: image.tag $release_tag"
done

echo
echo "Review, commit and push the release (Argo CD deploys it within about 60 s of the push, 120 s at worst):"
echo "  git diff -- ${files[*]}"
echo "  git add ${files[*]}"
echo "  git commit -m 'chore(k8s): phát hành ${services[*]} ${release_tag}'"
echo "  git push origin main"
