#!/usr/bin/env bash
# plan.sh: the first job of images.yml. Decides what
# this run does and hands it to the jobs after it as outputs (ci_output of platform.sh; stdout on a machine):
#   mode            build | rescan | drill
#   images          JSON array of the images to build (build: changed services; drill: the two drill images)
#   legs            JSON matrix {"include": [{image, arch, runner}]}, every image on amd64 and arm64 (native runners)
#   has_images      true | false
#   base            the commit the changes were compared with ("" when none could be used)
#   values_changed  true when a file of deploy/k8s/values/services/ changed since base (or base is unknown); read only
#                   off main, where the values check runs
#   values_ref      the dispatch input values_ref, checked (rescan only)
#
# Inputs come from the environment only, never interpolated into a script: EVENT_NAME, GIT_REF (github.ref),
# PR_BASE_REF (github.base_ref), INPUT_SERVICES, INPUT_RESCAN, INPUT_DRILL, INPUT_VALUES_REF, LAST_SUCCESS_JSON (the
# answer of the job last-success, possibly empty).
#
# Mode: rescan on schedule or dispatch rescan=true; drill on dispatch drill=true; otherwise build. Both inputs at once,
# rescan or drill off main, services outside build or values_ref outside rescan: refused (the run fails), never
# guessed. Base of the build (section 3; never github.event.before, which loses the changes of a queued run that was
# replaced and of a run that failed):
#   push to main       head_sha of the newest successful push run of images.yml on main (last-success.sh); none →
#                      all seven
#   pull request       merge-base of HEAD with the PR's base branch
#   workflow_dispatch  merge-base of HEAD with origin/main; input services (all, or names from the seven) overrides
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

event=${EVENT_NAME:?} ref=${GIT_REF:?}
on_main=false
[ "$ref" = refs/heads/main ] && [ "$event" != pull_request ] && on_main=true

mode=build
if [ "$event" = schedule ] || [ "${INPUT_RESCAN:-}" = true ]; then mode=rescan; fi
if [ "${INPUT_DRILL:-}" = true ]; then
  [ "$mode" = build ] || fail "rescan and drill are two runs: dispatch them one at a time"
  mode=drill
fi
[ "$mode" = build ] || [ "$on_main" = true ] ||
  fail "$mode runs only on main: it signs with the identity of images.yml on refs/heads/main"
values_ref=${INPUT_VALUES_REF:-}
if [ -n "$values_ref" ]; then
  [ "$mode" = rescan ] || fail "values_ref is an input of the rescan only"
  [[ $values_ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "values_ref must match ^[A-Za-z0-9][A-Za-z0-9._/-]*\$"
fi
[ -z "${INPUT_SERVICES:-}" ] || [ "$mode" = build ] || fail "services is an input of a build run only"

base=
images=()
values_changed=false
case $mode in
drill) images=("${drill_images[@]}") ;;
rescan) ;;
build)
  if [ "$event" = push ] && [ "$on_main" = true ]; then
    base=$(printf '%s' "${LAST_SUCCESS_JSON:-}" | "$ci_dir/last-success.sh")
    [ -n "$base" ] || ci_summary "No successful push run of images.yml on main to compare with: every service is built."
  elif [ "$event" = pull_request ]; then
    base=$(git -C "$repo_root" merge-base HEAD "origin/${PR_BASE_REF:?}") ||
      base=
  else
    base=$(git -C "$repo_root" merge-base HEAD origin/main) || base=
  fi
  if [ -n "${INPUT_SERVICES:-}" ]; then
    if [ "$INPUT_SERVICES" = all ]; then
      images=("${svp_services[@]}")
    else
      # read -a splits on blanks without expanding wildcards; every name must be one of the seven.
      read -r -a names <<<"$INPUT_SERVICES"
      for name in "${names[@]}"; do
        printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$name" || fail "services: '$name' is not one of the seven"
      done
      while IFS= read -r name; do images+=("$name"); done < <(printf '%s\n' "${names[@]}" | sort -u)
    fi
    ci_summary "Images chosen by the dispatch input services: ${images[*]}"
  else
    reason=$(mktemp) || fail "create a temporary file"
    list=$("$ci_dir/changed-services.sh" "$base" HEAD 2>"$reason") || {
      cat "$reason" >&2
      fail "choose the services to build"
    }
    ci_summary "Base: \`${base:-none}\`." "$(sed 's/^/- /' "$reason")"
    rm -f "$reason"
    read -r -a names <<<"$list"
    images=(${names[@]+"${names[@]}"})
  fi
  if [ "$on_main" != true ]; then
    if [ -z "$base" ] ||
      [ -n "$(git -C "$repo_root" diff --name-only "$base" HEAD -- deploy/k8s/values/services/)" ]; then
      values_changed=true
    fi
  fi
  ;;
esac

json_images=$(printf '%s\n' ${images[@]+"${images[@]}"} | jq -Rnc '[inputs | select(length > 0)]')
legs=$(jq -nc --argjson images "$json_images" '{include: [$images[] as $i
  | {image: $i, arch: "amd64", runner: "ubuntu-24.04"}, {image: $i, arch: "arm64", runner: "ubuntu-24.04-arm"}]}')
has_images=false
[ ${#images[@]} -eq 0 ] || has_images=true
ci_summary "Mode: $mode. Images: ${images[*]:-none}."

ci_output mode "$mode"
ci_output images "$json_images"
ci_output legs "$legs"
ci_output has_images "$has_images"
ci_output base "$base"
ci_output values_changed "$values_changed"
ci_output values_ref "$values_ref"
