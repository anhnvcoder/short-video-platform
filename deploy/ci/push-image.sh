#!/usr/bin/env bash
# push-image.sh IMAGE ARCH OUT: step 4 of one leg, only in the
# main job and only after build-image.sh passed the gate on the same OUT. Pushes the local image that was scanned as
# <prefix>IMAGE:<12 hex of the commit>-ARCH, where prefix is the imagePrefix of the release source this run builds for
# (ghcr.io/anhnvcoder/svp-backend/ for this repository; use_build_source of common.sh, which refuses an IMAGE
# that source does not publish before anything is pushed) and the commit HEAD of code_root (check_code_tree), reads
# the pushed manifest back from GHCR
# and compares its config digest with the scanned one (Metadata.ImageID of OUT/trivy.json): Docker compresses the
# layers again on push, so the manifest digest differs from the local one, but the config lists the uncompressed
# digest of every layer, so the same config digest means the same content that was scanned. Any difference fails the
# leg, and that digest is never merged, signed or promoted. Writes OUT/repository and OUT/digest (the manifest digest).
# Needs `docker login ghcr.io` done by the caller.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 3 ] || fail "usage: push-image.sh IMAGE ARCH OUT"
image=$1 arch=$2 out=$3
use_build_source "$image"
check_code_tree
local_tag=$(cat "$out/local-tag") || fail "$out has no local-tag: run build-image.sh first"
scanned=$(cat "$out/config-digest")
[ "$(jq -r .Metadata.ImageID "$out/trivy.json")" = "$scanned" ] || fail "$out/config-digest is not the scanned image"
[ "$(cat "$out/platform")" = "linux/$arch" ] || fail "$out holds a scan of $(cat "$out/platform"), not linux/$arch"
# The local image must still be the one that was scanned (nothing re-tagged it since).
[ "$(docker_ image inspect --format '{{.Id}}' "$local_tag")" = "$scanned" ] ||
  fail "$local_tag is no longer the image that was scanned"

repo=$build_prefix$image
rev=$(git -C "$code_root" rev-parse HEAD)
remote_tag="$repo:${rev:0:12}-$arch"
docker_ tag "$local_tag" "$remote_tag" || fail "tag $local_tag as $remote_tag"
docker_ push --quiet "$remote_tag" >/dev/null || fail "push $remote_tag"

# Read back what GHCR now serves under the tag (not RepoDigests, which keeps digests of earlier pushes); its config
# decides, so whatever answered is accepted only when it is the scanned content.
raw=$out/manifest.json
digest=$(fetch_manifest "$remote_tag" "$raw") || fail "read $remote_tag back from GHCR"
pushed=$(jq -r 'select(.mediaType == "application/vnd.oci.image.manifest.v1+json"
    or .mediaType == "application/vnd.docker.distribution.manifest.v2+json") | .config.digest' "$raw")
[ "$pushed" = "$scanned" ] ||
  fail "$repo@$digest has config ${pushed:-<not a single manifest>}, the scan had $scanned: not the scanned image"

echo "$repo" >"$out/repository"
echo "$digest" >"$out/digest"
echo "ok    pushed $remote_tag as $digest, config $scanned as scanned"
