#!/usr/bin/env bash
# The verification run of the GitOps path (job gitops of .github/workflows/verify.yml, scenario gitops of
# deploy/ci/verify/gitops.sh) needs the source maps of the web image the cluster runs, and two digests GHCR serves to
# anyone. Where the maps are depends on the release source of that image (deploy/helm/svp-policy/files/sources.json):
#   - backend, this repository: its CI exports the maps beside each web build as the artifact web-sourcemaps-amd64
#     (the runner's nodes are amd64) holding the chunks and maps (_next/static/...) and the file image-digest, the
#     digest of the linux/amd64 manifest that build pushed;
#   - another source (svp-web): its CI pushes the maps of each build as an image of their own beside the web image,
#     <imagePrefix>web-sourcemaps tagged amd64-<the 64 hex of that linux/amd64 manifest>, whose layers hold _next/
#     alone. An artifact of a run of another repository is never downloaded (that needs a token of that repository):
#     the image is pulled like a node pulls, anonymously.
#
#   gitops-sourcemaps.sh fetch
#       The job's step before the scenario, the only part that talks to the CI platform's API (its token reads the
#       repository's runs and artifacts; nothing is written there). It clones the deployment configuration first, as
#       make gitops-clone does (gitops_clone of deploy/k8s/lib.sh, GITOPS_REF, default main). The web release Argo CD
#       will run is the one at origin/<GITOPS_REV, default main> of that clone of svp-gitops (deploy/k8s/gitops.sh
#       follows the same): image.repository of envs/stg/images/web.yaml there, the web of a release source, and
#       image.digest, an index whose linux/amd64 manifest is read from GHCR without credentials. A release of another
#       source: the image of its maps above is pulled, each layer checked against its digest and listed before it is
#       unpacked (regular files and folders under _next/ only: no link, nothing outside it), and its _next/ taken;
#       a tag GHCR does not serve to an anonymous pull counts as no match. A release of backend: image.tag, the first
#       12 hex digits of the commit of this repository that built it, made a full SHA by git (the checkout holds the
#       whole history). Every finished images.yml run of that
#       commit that still holds web-sourcemaps-amd64 is tried, the latest first, each downloaded into an empty folder of
#       its own; the first whose image-digest is that linux/amd64 manifest is taken. A commit can be built more than
#       once (a dispatch that rebuilds web makes another bundle under another digest), so the commit alone never picks
#       the maps: an artifact of the right commit with another digest is never taken. The artifact is another run's
#       output, so only image-digest (one line, sha256:<64 hex>) is read here, nothing in it is run, and the maps are
#       checked again, with the debug ids the web serves, by deploy/observability/glitchtip/sourcemaps.sh before any
#       upload.
#       Leaves in <temp>/gitops-sourcemaps (ci_temp_dir of deploy/ci/platform.sh: the runner's temp directory, never
#       uploaded): status, one of
#         ok       maps/ holds the _next/ folder of the artifact taken;
#         skipped  no artifact matches, on a run of a branch of this repository other than main, which may follow a
#                  release built before CI exported maps: the steps that need them skip (the scenario reads this);
#         fail     no artifact matches on main, where a release always has its maps, or anything went wrong (the
#                  platform's API, GHCR, git), on any branch;
#       and reason, one line naming the digest, the commit and how many runs were tried. Exit 0 for ok and skipped, 1 for
#       fail: the job carries on to the scenario either way (the steps that do not need the maps still run).
#   gitops-sourcemaps.sh web-amd64
#       Prints <image.repository>@<digest of the linux/amd64 manifest> of the same release, read from the clone
#       gitops_dir names (SVP_GITOPS_DIR, which the scenario's run sets): a real image of a release source that no
#       signature or attestation names (they name the index), which the supply chain drill sends as its unsigned web
#       image.
#   gitops-sourcemaps.sh newest IMAGE
#       Prints ghcr.io/anhnvcoder/short-video-platform/IMAGE@<digest> of the newest index of IMAGE (drill-vulnerable,
#       drill-unsigned) on GHCR: its tags of 12 hex digits name the commit of main that CI built them at, and the newest
#       commit of this clone among them wins.
# GHCR is read like a node pulls: an anonymous token for the repository, then the manifest by digest or tag, its bytes
# hashed to the digest asked for. Sourcing this file only defines its functions (deploy/ci/gitops-sourcemaps-test.sh
# replaces the ones that reach the network). Written for bash 3.2 too (macOS).
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../k8s/lib.sh"
# ci_temp_dir, ci_artifact_runs, ci_artifact_fetch: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

sourcemaps_workflow=images.yml
sourcemaps_artifact=web-sourcemaps-amd64

# ghcr_token NAME: prints an anonymous pull token of repository NAME (without ghcr.io/) of GHCR.
ghcr_token() {
  local token
  token=$(curl -fsS --max-time 10 "https://ghcr.io/token?scope=repository:$1:pull&service=ghcr.io" |
    jq -r '.token // empty') && [ -n "$token" ] && echo "$token"
}

# ghcr_get NAME PATH OUT: GET https://ghcr.io/v2/NAME/PATH (NAME without ghcr.io/) into OUT with an anonymous pull
# token, asking for an index or a manifest of either format. The token goes to curl on stdin, never on a command line.
ghcr_get() {
  local token
  token=$(ghcr_token "$1") || return 1
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --max-time 20 -H @- -o "$3" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://ghcr.io/v2/$1/$2"
}

# ghcr_blob NAME DIGEST OUT: the blob DIGEST of repository NAME into OUT, anonymously, following GHCR's redirect to its
# storage (curl sends the token to ghcr.io alone, never to the host it is redirected to).
ghcr_blob() {
  local token
  token=$(ghcr_token "$1") || return 1
  printf 'Authorization: Bearer %s\n' "$token" | curl -fsSL --max-time 300 -H @- -o "$3" "https://ghcr.io/v2/$1/blobs/$2"
}

# manifest NAME REF OUT: writes the manifest or index NAME:REF (REF a tag or sha256:<64 hex>) to OUT, byte for byte as
# GHCR stores it, and prints the sha256 digest of those bytes; a REF that is a digest must be that digest.
manifest() {
  local got
  ghcr_get "$1" "manifests/$2" "$3" || {
    echo "FAIL  GHCR does not serve ghcr.io/$1 ${2} to an anonymous pull" >&2
    return 1
  }
  got=sha256:$(shasum -a 256 "$3" | cut -d' ' -f1)
  case $2 in
  sha256:*)
    [ "$got" = "$2" ] || {
      echo "FAIL  GHCR answered ghcr.io/$1@$2 with other bytes ($got)" >&2
      return 1
    }
    ;;
  esac
  echo "$got"
}

# web_release: sets rev (origin/<GITOPS_REV, default main> of svp-gitops, which Argo CD follows), rev_sha, web_repo,
# web_tag and web_index (image.repository, image.tag and image.digest of envs/stg/images/web.yaml there), web_source
# and web_prefix (the name and imagePrefix of the release source image.repository is the web of).
web_release() {
  local gitops values repo src file=envs/stg/images/web.yaml
  gitops=$(gitops_dir) || exit 1
  rev="origin/${GITOPS_REV:-main} of svp-gitops"
  rev_sha=$(git -C "$gitops" rev-parse --verify --quiet "refs/remotes/origin/${GITOPS_REV:-main}^{commit}") ||
    fail "origin/${GITOPS_REV:-main} is not in the clone of svp-gitops $gitops"
  values=$(git -C "$gitops" show "$rev_sha:$file") || fail "read $file at $rev (${rev_sha:0:12})"
  repo=$(values_field repository <<<"$values") || fail "read image.repository of $file at $rev"
  src=$(release_source_of web "$repo") ||
    fail "image.repository of $file at $rev is '$repo', not a release of web ($(release_repositories web))"
  web_repo=$repo
  web_source=$(jq -r .name <<<"$src")
  web_prefix=$(jq -r .imagePrefix <<<"$src")
  web_tag=$(values_field tag <<<"$values") || fail "read image.tag of $file at $rev"
  web_index=$(values_field digest <<<"$values") || fail "read image.digest of $file at $rev"
  [ -n "$web_tag" ] && [ -n "$web_index" ] || fail "$file at $rev names no web release yet (image.tag or image.digest empty)"
}

# web_amd64 DIR: prints the digest of the linux/amd64 manifest of index web_index, read into DIR.
web_amd64() {
  local child
  manifest "${web_repo#ghcr.io/}" "$web_index" "$1/web-index.json" >/dev/null || return 1
  child=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest]
    | if length == 1 then .[0] else "" end' "$1/web-index.json") || child=
  [[ $child =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "FAIL  $web_repo@$web_index is not an index with one linux/amd64 manifest" >&2
    return 1
  }
  echo "$child"
}

# artifact_digest DIR: prints the digest an artifact downloaded into DIR was built as: DIR must hold exactly the folder
# _next and the regular file image-digest, of one line sha256:<64 hex>; prints nothing otherwise.
artifact_digest() {
  local top digest
  top=$(cd "$1" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')
  [ "$top" = "./_next ./image-digest " ] && [ -d "$1/_next" ] && [ ! -L "$1/_next" ] &&
    [ -f "$1/image-digest" ] && [ ! -L "$1/image-digest" ] || return 0
  digest=$(head -c 100 "$1/image-digest")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] && echo "$digest"
  return 0
}

# image_maps OUT CHILD: the maps of a release of another source (see fetch in the header): prints the reason; exit 0
# with OUT/maps/_next in place, 3 when GHCR serves no image of them, 1 on any error (its FAIL line on stderr).
image_maps() {
  local out=$1 child=$2 name tag dir type digest bad
  name=${web_prefix#ghcr.io/}web-sourcemaps
  tag=amd64-${child#sha256:}
  dir=$out/image
  mkdir -p "$dir/root" || fail "create $dir"
  if ! manifest "$name" "$tag" "$dir/manifest.json" >/dev/null 2>&1; then
    rm -rf "$dir"
    echo "GHCR serves no ghcr.io/$name:$tag to an anonymous pull, the source maps of $child, the linux/amd64" \
      "manifest of web@$web_index at $rev"
    return 3
  fi
  jq -e '(.layers | type) == "array" and (.layers | length) > 0' "$dir/manifest.json" >/dev/null 2>&1 ||
    fail "ghcr.io/$name:$tag is no image manifest with layers"
  while read -r type digest; do
    case $type in
    application/vnd.oci.image.layer.v1.tar+gzip | application/vnd.docker.image.rootfs.diff.tar.gzip) ;;
    *) fail "ghcr.io/$name:$tag has a layer of type $type, not a gzipped tar" ;;
    esac
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "ghcr.io/$name:$tag names a layer '$digest', not sha256:<64 hex>"
    ghcr_blob "$name" "$digest" "$dir/layer" || fail "GHCR does not serve layer $digest of ghcr.io/$name:$tag"
    [ "sha256:$(shasum -a 256 "$dir/layer" | cut -d' ' -f1)" = "$digest" ] ||
      fail "GHCR answered layer $digest of ghcr.io/$name:$tag with other bytes"
    # Another build's output, unpacked here: only regular files and folders under _next/ (the long listing starts
    # each entry with its type, - or d), no link, no .., nothing outside.
    tar -tzf "$dir/layer" >"$dir/names" && tar -tvzf "$dir/layer" >"$dir/long" ||
      fail "layer $digest of ghcr.io/$name:$tag is no readable gzipped tar"
    bad=$({
      grep -Ev '^(\./)?_next(/|$)|^\./$' "$dir/names" || :
      grep -E '(^|/)\.\.(/|$)' "$dir/names" || :
      grep -v '^[-d]' "$dir/long" || :
    } | head -n 3 | paste -sd ' ' -)
    [ -z "$bad" ] ||
      fail "layer $digest of ghcr.io/$name:$tag holds more than regular files and folders under _next/: $bad"
    tar -xzf "$dir/layer" -C "$dir/root" || fail "unpack layer $digest of ghcr.io/$name:$tag"
    rm -f "$dir/layer"
  done < <(jq -r '.layers[] | "\(.mediaType) \(.digest)"' "$dir/manifest.json")
  [ "$(cd "$dir/root" && ls -A)" = _next ] && [ -d "$dir/root/_next" ] ||
    fail "ghcr.io/$name:$tag holds no folder _next"
  mkdir "$out/maps" && mv "$dir/root/_next" "$out/maps/_next" && rm -rf "$dir" ||
    fail "move the maps of ghcr.io/$name:$tag into $out/maps"
  echo "ghcr.io/$name:$tag holds the source maps of $child, the linux/amd64 manifest of $web_repo@$web_index at $rev"
}

# lookup OUT: see fetch in the header. Prints the reason; exit 0 with OUT/maps/_next in place, 3 when no artifact
# (or image of maps) matches, 1 on any error (its FAIL line on stderr).
lookup() {
  local out=$1 child commit runs rc=0 id dir got tried=0 notes=
  web_release
  child=$(web_amd64 "$out") || exit 1
  if [ "$web_source" != backend ]; then
    image_maps "$out" "$child"
    return
  fi
  commit=$(git -C "$repo_root" rev-parse --verify --quiet "$web_tag^{commit}") && [[ $commit == "$web_tag"* ]] ||
    fail "commit $web_tag (image.tag of web at $rev) is not in this clone of the code repository"
  runs=$(ci_artifact_runs "$sourcemaps_workflow" "$commit" "$sourcemaps_artifact") || rc=$?
  case $rc in
  0) ;;
  3) runs= ;;
  *) fail "list the $sourcemaps_workflow runs of $commit that hold $sourcemaps_artifact (exit $rc)" ;;
  esac
  for id in $runs; do
    tried=$((tried + 1))
    dir=$(mktemp -d "$out/run-XXXXXX") || fail "create a folder for the artifact of run $id"
    rc=0
    ci_artifact_fetch "$id" "$sourcemaps_artifact" "$dir" || rc=$?
    case $rc in
    0) ;;
    3)
      notes="$notes; run $id: gone since it was listed"
      continue
      ;;
    *) fail "download $sourcemaps_artifact of run $id (exit $rc)" ;;
    esac
    got=$(artifact_digest "$dir")
    if [ "$got" = "$child" ]; then
      mkdir "$out/maps" && mv "$dir/_next" "$out/maps/_next" && rm -rf "$dir" ||
        fail "move the maps of run $id into $out/maps"
      echo "run $id of $sourcemaps_workflow at $commit built web@$web_index, whose linux/amd64 manifest $child its $sourcemaps_artifact names; $tried run(s) tried$notes"
      return 0
    fi
    notes="$notes; run $id: ${got:-no image-digest of the form sha256:<64 hex>}"
    rm -rf "$dir"
  done
  echo "no $sourcemaps_workflow run of $commit holds $sourcemaps_artifact for $child, the linux/amd64 manifest of web@$web_index at $rev: $tried run(s) tried$notes"
  return 3
}

# fetch: see the header.
fetch() {
  local out status reason rc=0 branch clone
  out=$(ci_temp_dir)/gitops-sourcemaps || exit 1
  rm -rf "$out"
  mkdir -p "$out" || fail "create $out"
  # In a subshell, so a failed clone exits it alone and is recorded as fail.
  if ! clone=$( (gitops_clone) 2>&1); then
    printf '%s\n' "$clone" >&2
    printf 'fail\n' >"$out/status"
    sed -n 's/^FAIL  //p' <<<"$clone" | tail -n 1 >"$out/reason"
    echo "fail: $(cat "$out/reason")"
    return 1
  fi
  echo "$clone"
  export SVP_GITOPS_DIR=$gitops_ci_clone
  branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD) || branch=
  reason=$(lookup "$out" 2>"$out/lookup.err") || rc=$?
  cat "$out/lookup.err" >&2
  case $rc in
  0) status=ok ;;
  3) if [ "$branch" = main ]; then status=fail; else status=skipped; fi ;;
  *)
    status=fail
    reason=$(sed -n 's/^FAIL  //p' "$out/lookup.err" | tail -n 1)
    reason=${reason:-the lookup stopped with exit status $rc}
    ;;
  esac
  rm -f "$out/lookup.err" "$out/web-index.json"
  printf '%s\n' "$status" >"$out/status"
  printf '%s\n' "$reason" >"$out/reason"
  echo "$status: $reason"
  [ "$status" != fail ]
}

# newest IMAGE DIR: see the header; GHCR's answers go to DIR.
newest() {
  local image=$1 tmp=$2 name tag commit commits= best digest
  [[ $image =~ ^[a-z0-9-]+$ ]] || fail "newest: '$image' is not an image name"
  name=${ghcr_prefix#ghcr.io/}/$image
  ghcr_get "$name" "tags/list?n=1000" "$tmp/tags.json" || fail "GHCR does not list the tags of ghcr.io/$name anonymously"
  for tag in $(jq -r '.tags[]? | select(test("^[0-9a-f]{12}$"))' "$tmp/tags.json"); do
    commit=$(git -C "$repo_root" rev-parse --verify --quiet "$tag^{commit}") && [[ $commit == "$tag"* ]] || continue
    commits="$commits $commit"
  done
  [ -n "$commits" ] ||
    fail "ghcr.io/$name has no tag that is a commit of this clone: build it ($(ci_dispatch_hint images.yml main drill=true))"
  # The first of the commits in topological order is one that none of the others descends from: on main, where CI
  # builds them, the newest (two commits of the same second still in their order).
  # shellcheck disable=SC2086 # full SHAs, split on spaces
  best=$(git -C "$repo_root" rev-list --topo-order --max-count=1 $commits) || fail "order the commits of the tags"
  digest=$(manifest "$name" "${best:0:12}" "$tmp/index.json") || exit 1
  echo "$ghcr_prefix/$image@$digest"
}

# Run as a script, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  case ${1:-} in
  fetch) fetch ;;
  web-amd64)
    web_release
    child=$(web_amd64 "$tmp") || exit 1
    echo "$web_repo@$child"
    ;;
  newest) newest "${2:-}" "$tmp" ;;
  *) fail "usage: gitops-sourcemaps.sh fetch | web-amd64 | newest IMAGE" ;;
  esac
fi
