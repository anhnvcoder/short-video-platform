#!/usr/bin/env bash
# merge-index.sh IMAGE DIR DIR OUT: joins the two manifests pushed by push-image.sh (one DIR per platform, as the
# leg artifacts hold them) into the multi-arch index ghcr.io/anhnvcoder/short-video-platform/IMAGE:<12 hex of the
# commit>, with the OCI annotations of the commit on the index.
# Reads the index back and checks it holds exactly those two manifests, linux/amd64 and linux/arm64.
# Writes OUT/repository, OUT/tag and OUT/digest: the index digest is what is signed, attested and promoted.
# Needs `docker login ghcr.io` done by the caller.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 4 ] || fail "usage: merge-index.sh IMAGE DIR DIR OUT"
image=$1 out=$4
repo=$ghcr_prefix/$image
sources=()
for dir in "$2" "$3"; do
  [ "$(cat "$dir/repository")" = "$repo" ] || fail "$dir holds a push to another repository than $repo"
  digest=$(cat "$dir/digest")
  is_digest "$digest" || fail "$dir has no manifest digest"
  sources+=("$repo@$digest")
done
[ "$(cat "$2/platform" "$3/platform" | sort | paste -sd' ' -)" = "linux/amd64 linux/arm64" ] ||
  fail "the two legs are not linux/amd64 and linux/arm64"

rev=$(git -C "$repo_root" rev-parse HEAD)
tag=${rev:0:12}
annotations=()
while IFS= read -r label; do annotations+=(--annotation "index:$label"); done < <(oci_labels)
docker_ buildx imagetools create --tag "$repo:$tag" "${annotations[@]}" "${sources[@]}" ||
  fail "create the index $repo:$tag"

mkdir -p "$out"
digest=$(fetch_manifest "$repo:$tag" "$out/index.json") || fail "read $repo:$tag back from GHCR"
check_index "$repo" "$digest" "$2" "$3" ||
  fail "$repo@$digest is not an index of exactly the two scanned manifests"
echo "$repo" >"$out/repository"
echo "$tag" >"$out/tag"
echo "$digest" >"$out/digest"
echo "ok    $repo:$tag is index $digest of linux/amd64 and linux/arm64"
