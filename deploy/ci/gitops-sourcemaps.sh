#!/usr/bin/env bash
# The verification run of the GitOps path (job gitops of .github/workflows/verify.yml, scenario gitops of
# deploy/ci/verify/gitops.sh) needs the source maps of the web image the cluster runs, and two digests GHCR serves to
# anyone. The image comes from CI, which exports the maps beside each web build as the artifact web-sourcemaps-amd64
# (the runner's nodes are amd64) holding the chunks and maps (_next/static/...) and the file image-digest, the digest
# of the linux/amd64 manifest that build pushed.
#
#   gitops-sourcemaps.sh fetch
#       The job's step before the scenario, the only part that talks to the CI platform's API (its token reads the
#       repository's runs and artifacts; nothing is written there). The web release Argo CD will run is the one at
#       origin/<branch of the checkout> (deploy/k8s/gitops.sh follows the same): image.digest of
#       deploy/k8s/values/services/web.yaml there, an index whose linux/amd64 manifest is read from GHCR without
#       credentials, and image.tag, the first 12 hex digits of the commit that built it, made a full SHA by git (the
#       checkout holds the whole history). Every finished images.yml run of that commit that still holds
#       web-sourcemaps-amd64 is tried, the latest first, each downloaded into an empty folder of its own; the first whose
#       image-digest is that linux/amd64 manifest is taken. A commit can be built more than once (a dispatch that
#       rebuilds web makes another bundle under another digest), so the commit alone never picks the maps: an artifact
#       of the right commit with another digest is never taken. The artifact is another run's output, so only
#       image-digest (one line, sha256:<64 hex>) is read here, nothing in it is run, and the maps are checked again,
#       with the debug ids the web serves, by deploy/observability/glitchtip/sourcemaps.sh before any upload.
#       Leaves in <temp>/gitops-sourcemaps (ci_temp_dir of deploy/ci/platform.sh: the runner's temp directory, never
#       uploaded): status, one of
#         ok       maps/ holds the _next/ folder of the artifact taken;
#         skipped  no artifact matches, on a branch other than main: the web release there was often built before CI
#                  exported maps, and the steps that need them skip (the scenario reads this);
#         fail     no artifact matches on main, where a release always has its maps, or anything went wrong (the
#                  platform's API, GHCR, git), on any branch;
#       and reason, one line naming the digest, the commit and how many runs were tried. Exit 0 for ok and skipped, 1 for
#       fail: the job carries on to the scenario either way (the steps that do not need the maps still run).
#   gitops-sourcemaps.sh web-amd64
#       Prints ghcr.io/anhnvcoder/short-video-platform/web@<digest of the linux/amd64 manifest> of the same release: a
#       real image of the project's repository that no signature or attestation names (they name the index), which the
#       supply chain drill sends as its unsigned web image.
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

# ghcr_get NAME PATH OUT: GET https://ghcr.io/v2/NAME/PATH (NAME without ghcr.io/) into OUT with an anonymous pull
# token, asking for an index or a manifest of either format. The token goes to curl on stdin, never on a command line.
ghcr_get() {
  local token
  token=$(curl -fsS --max-time 10 "https://ghcr.io/token?scope=repository:$1:pull&service=ghcr.io" |
    jq -r '.token // empty') && [ -n "$token" ] || return 1
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --max-time 20 -H @- -o "$3" \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://ghcr.io/v2/$1/$2"
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

# web_release: sets rev (origin/<branch of the checkout>, which Argo CD follows), rev_sha, web_tag and web_index
# (image.tag and image.digest of deploy/k8s/values/services/web.yaml there) once image.repository is the project's web.
web_release() {
  local branch values repo file=deploy/k8s/values/services/web.yaml
  branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD) ||
    fail "the checkout is on no branch, so there is no origin/<branch> for Argo CD to follow"
  rev=origin/$branch
  rev_sha=$(git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/$rev^{commit}") ||
    fail "$rev is not in this clone (fetched with its whole history?)"
  values=$(git -C "$repo_root" show "$rev_sha:$file") || fail "read $file at $rev (${rev_sha:0:12})"
  repo=$(values_field repository <<<"$values") || fail "read image.repository of $file at $rev"
  [ "$repo" = "$ghcr_prefix/web" ] || fail "image.repository of $file at $rev is '$repo', not $ghcr_prefix/web"
  web_tag=$(values_field tag <<<"$values") || fail "read image.tag of $file at $rev"
  web_index=$(values_field digest <<<"$values") || fail "read image.digest of $file at $rev"
  [ -n "$web_tag" ] && [ -n "$web_index" ] || fail "$file at $rev names no web release yet (image.tag or image.digest empty)"
}

# web_amd64 DIR: prints the digest of the linux/amd64 manifest of index web_index, read into DIR.
web_amd64() {
  local child
  manifest "${ghcr_prefix#ghcr.io/}/web" "$web_index" "$1/web-index.json" >/dev/null || return 1
  child=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest]
    | if length == 1 then .[0] else "" end' "$1/web-index.json") || child=
  [[ $child =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "FAIL  $ghcr_prefix/web@$web_index is not an index with one linux/amd64 manifest" >&2
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

# lookup OUT: see fetch in the header. Prints the reason; exit 0 with OUT/maps/_next in place, 3 when no artifact
# matches, 1 on any error (its FAIL line on stderr).
lookup() {
  local out=$1 child commit runs rc=0 id dir got tried=0 notes=
  web_release
  child=$(web_amd64 "$out") || exit 1
  commit=$(git -C "$repo_root" rev-parse --verify --quiet "$web_tag^{commit}") && [[ $commit == "$web_tag"* ]] ||
    fail "commit $web_tag (image.tag of web at $rev) is not in this clone"
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
  local out status reason rc=0 branch
  out=$(ci_temp_dir)/gitops-sourcemaps || exit 1
  rm -rf "$out"
  mkdir -p "$out" || fail "create $out"
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
    echo "$ghcr_prefix/web@$child"
    ;;
  newest) newest "${2:-}" "$tmp" ;;
  *) fail "usage: gitops-sourcemaps.sh fetch | web-amd64 | newest IMAGE" ;;
  esac
fi
