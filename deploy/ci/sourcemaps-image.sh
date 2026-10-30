#!/usr/bin/env bash
# sourcemaps-image.sh push [--dry-run] ARCH DIR: pushes the source maps of one web build as an image of their own,
# <imagePrefix>web-sourcemaps:ARCH-<64 hex>, which deploy/ci/gitops-sourcemaps.sh pulls anonymously (image_maps) when
# the web of stg is a release of another source than backend: an artifact of a run of another repository is never
# downloaded, the registry is read like a node reads it.
#
#   DIR    the folder build-image.sh --sourcemaps-artifact packed for that leg: exactly the folder _next (chunks and maps
#          under _next/static/, regular files only, each chunk still naming its map) and the regular file image-digest,
#          one line sha256:<64 hex>, the manifest digest of that leg's web image as pushed. Anything else beside them, a
#          link anywhere, or a digest of another form fails before anything is read from the registry.
#   ARCH   amd64 or arm64, the architecture of that leg (DIR does not say it): the tag is ARCH-<hex of image-digest>.
#
# The image goes under the prefix of the release source this run builds for (use_build_source of common.sh), which
# must publish web; web-sourcemaps must not be one of its services or drill images, so the policy never admits it in a
# pod. It is an OCI artifact pushed with the pinned ORAS (ORAS_IMAGE of the Makefile): one layer, _next/ as a gzipped
# tar (application/vnd.oci.image.layer.v1.tar+gzip, the type gitops-sourcemaps.sh takes). The maps are not signed:
# they describe code that is public anyway, and the debug ids the web serves check them before any upload
# (deploy/observability/glitchtip/sourcemaps.sh).
#
# A tag is never written twice. When it exists, its layer is pulled, checked like gitops-sourcemaps.sh checks it
# (gzipped tar of regular files and folders under _next/ only) and unpacked, and its tree compared with DIR/_next file
# by file: the same tree is left as it is, another one fails and nothing is written. The bytes of the tar are not
# compared: the leg of the same commit built again may push the very same web manifest, while tar packs the same files
# into other bytes. The reads go with the credentials of docker login (the package may still be private, and an
# anonymous read would take an existing tag for a missing one); "not found" and "denied" alone mean absent, any other
# error fails.
#
# Only the workflow that signs the source's releases (ci_builder_id against its subject: images.yml on main) pushes,
# so a branch, another workflow or a machine never writes under the release prefix. Needs `docker login` to the
# registry when not a dry run. --dry-run reads the registry without credentials and only says what it would do.
#
# Written for bash 3.2 too (macOS).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

maps_name=web-sourcemaps
maps_artifact_type=application/vnd.anhnvcoder.svp.web-sourcemaps.v1
maps_media_type=application/vnd.oci.image.layer.v1.tar+gzip

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT

# oras_ [--auth] ARGS...: the pinned ORAS, as the calling user, seeing $work as its working directory. With --auth it
# also reads the credentials docker login wrote (only the file, read-only; a credential helper of the machine is not
# reachable from the container). The same as in contract.sh.
oras_() {
  local image auth=() config
  image=$(tool_image ORAS_IMAGE) || return 1
  if [ "$1" = --auth ]; then
    shift
    config=${DOCKER_CONFIG:-$HOME/.docker}/config.json
    [ -f "$config" ] || fail "no $config: docker login to the registry first"
    auth=(-v "$config:/auth/config.json:ro")
    set -- "$@" --registry-config /auth/config.json
  fi
  docker_ run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp ${auth[@]+"${auth[@]}"} -v "$work:/work" -w /work \
    "$image" "$@"
}

# check_dir DIR: prints the digest DIR/image-digest holds when DIR is laid out as described in the header; fails
# naming the first problem otherwise. The top level is checked as artifact_digest of gitops-sourcemaps.sh checks an
# artifact, the tree under _next/ as check_sourcemaps of build-image.sh checks what it packs.
check_dir() {
  local dir=$1 top digest bad js
  [ -d "$dir" ] && [ ! -L "$dir" ] || fail "$dir is not a folder"
  top=$(cd "$dir" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')
  [ "$top" = "./_next ./image-digest " ] || fail "$dir holds '$top', not exactly _next/ and image-digest"
  [ -d "$dir/_next" ] && [ ! -L "$dir/_next" ] || fail "$dir/_next is not a folder"
  [ -f "$dir/image-digest" ] && [ ! -L "$dir/image-digest" ] || fail "$dir/image-digest is not a regular file"
  digest=$(head -c 100 "$dir/image-digest")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$dir/image-digest does not hold one line sha256:<64 hex>"
  bad=$(cd "$dir/_next" && find . -mindepth 1 \( -name '.*' -o \( ! -type f ! -type d \) \) -print)
  [ -z "$bad" ] || fail "$dir/_next holds hidden entries or entries that are not regular files: $bad"
  bad=$(cd "$dir" && find _next -type f | grep -vE '^_next/static/.+\.(js|map)$' || true)
  [ -z "$bad" ] || fail "$dir holds files other than chunks and maps under _next/static/: $bad"
  [ -n "$(find "$dir/_next" -type f -name '*.js.map' | head -n 1)" ] || fail "$dir/_next holds no *.js.map"
  while IFS= read -r js; do
    grep -qE '^//# sourceMappingURL=[^[:space:]]+$' "$js" || fail "${js#"$dir"/} has lost its sourceMappingURL comment"
  done < <(find "$dir/_next" -type f -name '*.js')
  echo "$digest"
}

# published AUTH REF: writes to $work/manifest.json the manifest REF names and prints its digest; prints nothing when
# REF does not exist. GHCR answers "not found" for a tag missing from a package and "denied" for a package that does not
# exist yet (or a private one read without credentials); with credentials that may push, which include read, denied
# means no package. Any other error fails, so a registry out of reach is never taken for a tag not pushed yet.
published() {
  local err rc=0 flag=()
  [ "$1" = true ] && flag=(--auth)
  err=$(oras_ ${flag[@]+"${flag[@]}"} manifest fetch "$2" 2>&1 >"$work/manifest.json") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case $err in
    *": not found"* | *"denied: requested access to the resource is denied"*) return 0 ;;
    esac
    printf '%s\n' "$err" | tail -n 1 >&2
    fail "read $2 from the registry"
  fi
  echo "sha256:$(shasum -a 256 "$work/manifest.json" | cut -d' ' -f1)"
}

# layer_of: prints the digest of the one layer of $work/manifest.json when it is an image of source maps (its artifact
# type, one gzipped tar layer); status 1 otherwise.
layer_of() {
  jq -re --arg type "$maps_artifact_type" --arg media "$maps_media_type" '
    select(.artifactType == $type and (.layers | length) == 1 and .layers[0].mediaType == $media)
    | .layers[0].digest | select(test("^sha256:[0-9a-f]{64}$"))' "$work/manifest.json" 2>/dev/null
}

# same_tree AUTH REPOSITORY LAYER DIR: pulls blob LAYER of REPOSITORY, checks it is a gzipped tar of regular files and
# folders under _next/ only (as gitops-sourcemaps.sh does before it unpacks one), unpacks it and compares the tree with
# DIR/_next; status 0 when every file and folder is the same, 1 otherwise (the differences on stderr).
same_tree() {
  local flag=() bad
  [ "$1" = true ] && flag=(--auth)
  rm -rf "$work/existing" "$work/existing.tgz"
  mkdir "$work/existing" || fail "create $work/existing"
  oras_ ${flag[@]+"${flag[@]}"} blob fetch --output existing.tgz "$2@$3" >/dev/null || fail "pull layer $3 of $2"
  [ "sha256:$(shasum -a 256 "$work/existing.tgz" | cut -d' ' -f1)" = "$3" ] ||
    fail "the registry answered layer $3 of $2 with other bytes"
  tar -tzf "$work/existing.tgz" >"$work/names" && tar -tvzf "$work/existing.tgz" >"$work/long" ||
    fail "layer $3 of $2 is no readable gzipped tar"
  bad=$({
    grep -Ev '^(\./)?_next(/|$)|^\./$' "$work/names" || :
    grep -E '(^|/)\.\.(/|$)' "$work/names" || :
    grep -v '^[-d]' "$work/long" || :
  } | head -n 3 | paste -sd ' ' -)
  [ -z "$bad" ] || fail "layer $3 of $2 holds more than regular files and folders under _next/: $bad"
  tar -xzf "$work/existing.tgz" -C "$work/existing" || fail "unpack layer $3 of $2"
  [ "$(cd "$work/existing" && ls -A)" = _next ] || return 1
  # File names only: chunks and maps are single lines of up to megabytes, so a full diff would copy a bundle into the log.
  diff -rq "$work/existing/_next" "$4/_next" >&2
}

push() {
  local dry=false arch dir digest repo ref layer want builder found
  if [ "${1:-}" = --dry-run ]; then
    dry=true
    shift
  fi
  [ $# -eq 2 ] || fail "usage: sourcemaps-image.sh push [--dry-run] ARCH DIR"
  arch=$1 dir=$2
  case $arch in amd64 | arm64) ;; *) fail "ARCH must be amd64 or arm64, not '$arch'" ;; esac
  digest=$(check_dir "$dir") || exit 1
  use_build_source web
  ! jq -e --arg n "$maps_name" '.services + .drillImages | index($n)' <<<"$build_source" >/dev/null ||
    fail "$maps_name is an image of release source $build_source_name, so the policy would admit it in a pod: rename it"
  repo=$build_prefix$maps_name
  ref=$repo:$arch-${digest#sha256:}
  if [ "$dry" = false ]; then
    sign_identity "$build_source_name"
    builder=$(ci_builder_id) || fail "read the workflow of this run"
    [ "$builder" = "$sign_subject" ] ||
      fail "this run is $builder, but source maps go under $build_prefix only from $sign_subject"
  fi
  # COPYFILE_DISABLE keeps the tar of macOS from adding AppleDouble entries (._*); GNU tar ignores it.
  COPYFILE_DISABLE=1 tar -czf "$work/maps.tgz" -C "$dir" _next || fail "pack $dir/_next"
  want=sha256:$(shasum -a 256 "$work/maps.tgz" | cut -d' ' -f1)

  found=$(published "$([ "$dry" = true ] && echo false || echo true)" "$ref")
  if [ -n "$found" ]; then
    layer=$(layer_of) || fail "$ref already exists and is not an image of source maps: nothing written"
    if ! same_tree "$([ "$dry" = true ] && echo false || echo true)" "$repo" "$layer" "$dir"; then
      fail "$ref already holds other source maps than $dir/_next: a tag is never written twice"
    fi
    echo "ok    $ref already holds these source maps ($found): nothing to do" | ci_summary_tee
    return 0
  fi
  if [ "$dry" = true ]; then
    echo "dry run: $ref is not readable without credentials (not pushed yet, or private): would push $dir/_next ($want)" |
      ci_summary_tee
    return 0
  fi
  oras_ --auth push "$ref" --artifact-type "$maps_artifact_type" \
    --annotation "org.opencontainers.image.source=$(ci_repo_url)" \
    --annotation "org.opencontainers.image.revision=$(ci_commit)" \
    "maps.tgz:$maps_media_type" >/dev/null || fail "push $ref"
  found=$(published true "$ref")
  [ -n "$found" ] && layer=$(layer_of) && [ "$layer" = "$want" ] || fail "$ref read back after the push is not these maps"
  echo "ok    $ref pushed: the source maps of $digest ($found)" | ci_summary_tee
}

case ${1:-} in
push)
  shift
  push "$@"
  ;;
*) fail "usage: sourcemaps-image.sh push [--dry-run] ARCH DIR" ;;
esac
