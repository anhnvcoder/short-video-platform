#!/usr/bin/env bash
# plan.sh: the first job of images.yml. Decides what
# this run does and hands it to the jobs after it as outputs (ci_output of platform.sh; stdout on a machine):
#   mode            build | rescan | drill
#   images          JSON array of the images to build (build: changed services; drill: the drill images)
#   legs            JSON matrix {"include": [{image, arch, runner}]}, every image on amd64 and arm64 (native runners)
#   has_images      true | false
#   base            the commit the changes were compared with ("" when none could be used)
#   promote_charts  true on a build of main that builds no image but changes what the charts of this repository read
#                   (a file under deploy/helm/, or a file a symbolic link there points to, such as
#                   deploy/observability/otelcol/k8s-config.yaml) since base: job promote still runs and moves the
#                   charts stg runs (envs/stg/charts.yaml of svp-gitops) to this commit
#   values_ref      the dispatch input values_ref, checked (rescan only): a ref of svp-gitops, or a commit of this
#                   repository from before svp-gitops held the releases
#
# Inputs come from the environment only, never interpolated into a script: EVENT_NAME, GIT_REF (github.ref),
# PR_BASE_REF (github.base_ref), INPUT_SERVICES, INPUT_RESCAN, INPUT_DRILL, INPUT_VALUES_REF, LAST_SUCCESS_JSON (the
# answer of the job last-success, possibly empty).
#
# Mode: rescan on schedule or dispatch rescan=true; drill on dispatch drill=true; otherwise build. Both inputs at once,
# rescan or drill off main, services outside build or values_ref outside rescan: refused (the run fails), never
# guessed. Base of the build (never github.event.before, which loses the changes of a queued run that was
# replaced and of a run that failed):
#   push to main       head_sha of the newest successful push run of images.yml on main (last-success.sh); none →
#                      all six
#   pull request       merge-base of HEAD with the PR's base branch
#   workflow_dispatch  merge-base of HEAD with origin/main; input services (all, or names from the six this repository
#                      builds: built_services of deploy/k8s/lib.sh, never web, which svp-frontend builds) overrides
#
# Another repository's tree (SVP_CODE_ROOT, code_root of common.sh, is not this checkout: the CI of another release
# source runs this script from a pinned checkout of this one): its whole tree is the code of its images, so a build
# builds every service of the release source the run builds for (use_build_source of common.sh; HEAD of the tree must
# be the run's commit), with no base and no comparison; input services may name only those services (or all). A drill
# builds its drillImages and is refused when it has none; the charts are this repository's, so promote_charts stays
# false. Either tree, the run must be of the repository of one release source and HEAD of the tree its commit: a job
# of another source that forgot SVP_CODE_ROOT stops here, not with a plan made from the diff of this checkout.
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
promote_charts=false
use_build_source
check_code_tree
if [ "$code_root" != "$script_root" ]; then
  case $mode in
  drill)
    read -r -a images <<<"$(jq -r '.drillImages | join(" ")' <<<"$build_source")"
    [ ${#images[@]} -gt 0 ] || fail "release source $build_source_name has no drill image to build"
    ;;
  rescan) ;;
  build)
    read -r -a published <<<"$(jq -r '.services | join(" ")' <<<"$build_source")"
    if [ -z "${INPUT_SERVICES:-}" ] || [ "$INPUT_SERVICES" = all ]; then
      images=("${published[@]}")
    else
      read -r -a names <<<"$INPUT_SERVICES"
      for name in "${names[@]}"; do
        printf '%s\n' "${published[@]}" | grep -qxF -- "$name" ||
          fail "services: '$name' is not an image of release source $build_source_name (${published[*]})"
      done
      while IFS= read -r name; do images+=("$name"); done < <(printf '%s\n' "${names[@]}" | sort -u)
    fi
    ci_summary "Release source $build_source_name: its tree is the code of ${images[*]}, built at every run."
    ;;
  esac
fi
# This repository's own tree: what changed decides.
[ "$code_root" != "$script_root" ] || case $mode in
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
      images=("${built_services[@]}")
    else
      # read -a splits on blanks without expanding wildcards; every name must be one of the six.
      read -r -a names <<<"$INPUT_SERVICES"
      for name in "${names[@]}"; do
        printf '%s\n' "${built_services[@]}" | grep -qxF -- "$name" ||
          fail "services: '$name' is not an image this repository builds (${built_services[*]})"
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
  # A comparable base only: without one every image is built, and a newer run already promoted an older HEAD's charts.
  if [ "$on_main" = true ] && [ ${#images[@]} -eq 0 ] && [ -n "$base" ] &&
    git -C "$repo_root" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    # What the charts read: deploy/helm/, and the files its symbolic links point to (each resolved from the link's own
    # folder), which a change of the link's target alone leaves out of a diff of deploy/helm/.
    chart_paths=(deploy/helm)
    while IFS= read -r link; do
      target=$(git -C "$repo_root" show "HEAD:$link") || fail "read the symbolic link $link"
      # The link's folder, then the target, with . and .. folded: a path of the repository.
      IFS=/ read -r -a parts <<<"$(dirname "$link")/$target"
      path=()
      for part in "${parts[@]}"; do
        case $part in
        '' | .) ;;
        ..) unset 'path[${#path[@]}-1]' ;;
        *) path+=("$part") ;;
        esac
      done
      chart_paths+=("$(IFS=/ && echo "${path[*]}")")
    done < <(git -C "$repo_root" ls-tree -r HEAD -- deploy/helm | awk -F '\t' '$1 ~ /^120000 / { print $2 }')
    changed=$(git -C "$repo_root" diff --name-only --no-renames "$base" HEAD -- "${chart_paths[@]}") ||
      fail "list the files of the charts changed since $base"
    if [ -n "$changed" ]; then
      promote_charts=true
      ci_summary "No image to build, but the charts changed since \`${base:0:12}\`: promote moves stg's charts to this commit." \
        "$(sed 's/^/- /' <<<"$changed")"
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
ci_output promote_charts "$promote_charts"
ci_output values_ref "$values_ref"
