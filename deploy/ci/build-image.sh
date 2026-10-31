#!/usr/bin/env bash
# build-image.sh IMAGE ARCH OUT: steps 1-3 of one leg of the image pipeline, shared by the pull request
# job (which stops here) and the main job (which then pushes):
#   1. `docker buildx build --load` from the existing Dockerfile, on this host's own architecture (no emulation, no
#      cross-compiling: the Dockerfiles stay what `make up` and `make k8s-up` use), OCI labels of the commit, no
#      BuildKit provenance or SBOM so the image is one plain manifest;
#   2. `docker save` to OUT/image.tar; trivy reads that very tar (read-only mount), so what is scanned is what step 4
#      pushes, compared by config digest;
#   3. scan-gate.sh on the report, then grype on the SBOM syft writes of the same tar and scan-gate.sh --grype on its
#      report. A blocked image (by either gate: both always run, so the summary shows both) exits non-zero and nothing
#      after it runs.
# IMAGE is one of the services or drill images (built only to drill admission, never run) of the release source this
# run builds for (use_build_source of common.sh: the source whose repository runs the job), so an image no source of
# this run publishes is refused before anything is built. The code is that of code_root: this checkout, or the
# checkout of another release source's repository named by SVP_CODE_ROOT, whose CI runs this script from a pinned
# checkout of this one; its HEAD must be the commit of the run (check_code_tree). This checkout builds only its six
# services (built_services of deploy/k8s/lib.sh) and the drill images: web, still a service of its release source
# while prd runs that release, has no source here. In another repository's tree, the image builds from its top with
# the Dockerfile there, and its Dockerfile, pnpm-lock.yaml and .trivyignore.yaml must be there. The web image gets
# SVP_BUILD_ID set to the first 12 hex digits of the commit, the image's tag: both architectures of a commit get the
# same id, which Next uses as its deploymentId and the server as its release name.
# trivy then reads the package.json of every package in the image's node_modules, so npm packages go
# through the same CRITICAL and secret gate, and syft lists them in the SBOM. ARCH (amd64, arm64) must be this host's
# architecture. OUT receives:
#   image.tar, local-tag, platform, config-digest, trivy.json, trivy.sarif, sbom.spdx.json, grype.json, grype.sarif,
#   scan-started, scan-finished, db-updated-at, and, for web only, sourcemaps/ (below).
# Only drill-vulnerable passes --allow-critical to the gates; the secret gate holds for every image.
#
# Web source maps. The image serves its browser chunks without their maps; stage `sourcemaps` of the web Dockerfile
# holds them. Right after the image, the same builder builds that stage with the same context and build argument into
# OUT/sourcemaps, so it comes from the image's own build cache: a build without cache may make another bundle (Server
# Action ids are random per build), whose maps would match no chunk the image serves. The leg then copies the image's
# own chunks out of the image and fails unless the debug id of every chunk that carries one is a chunk of
# OUT/sourcemaps: a bundle that differs stops the leg instead of shipping maps of another bundle. The bundle is built
# natively on each architecture, so the maps go per architecture.
#
# build-image.sh --sourcemaps-artifact OUT DIGEST_FILE DEST: run in the main job after push-image.sh, packs
# OUT/sourcemaps into DEST for the artifact web-sourcemaps-<arch>: the tree _next/static/... of chunks (as built, each
# still ending with the sourceMappingURL comment that names its map) and maps, nothing else, plus the file image-digest
# holding the content of DIGEST_FILE: the manifest digest of this leg as pushed (OUT/digest), the very digest the
# signed index lists for linux/<arch>. A commit can be built more than once (a dispatch that rebuilds web makes another
# bundle and another digest), so that digest, not the commit, tells which image the maps belong to. A missing or
# malformed digest fails: an artifact nobody can match to an image is never packed.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

# check_sourcemaps DIR: DIR holds only regular files under _next/static/, each a .js chunk or a .map, no hidden entry,
# at least one *.js.map, and every chunk still carries its sourceMappingURL comment (the upload pairs a chunk with its
# map through that comment and reads the debug id from the chunk). The named map may be missing: a vendored file such as
# the hls.js worker names a map next never writes, and goes as it is, like in the upload from a machine.
check_sourcemaps() {
  local dir=$1 bad js
  [ -d "$dir" ] || fail "$dir is not a directory"
  bad=$(cd "$dir" && find . -mindepth 1 \( -name '.*' -o \( ! -type f ! -type d \) \) -print)
  [ -z "$bad" ] || fail "$dir holds hidden entries or entries that are not regular files: $bad"
  bad=$(cd "$dir" && find . -type f | grep -vE '^\./_next/static/.+\.(js|map)$' || true)
  [ -z "$bad" ] || fail "$dir holds files other than chunks and maps under _next/static/: $bad"
  [ -n "$(find "$dir" -type f -name '*.js.map' | head -n 1)" ] || fail "$dir holds no *.js.map"
  while IFS= read -r js; do
    grep -qE '^//# sourceMappingURL=[^[:space:]]+$' "$js" || fail "${js#"$dir"/} has lost its sourceMappingURL comment"
  done < <(find "$dir" -type f -name '*.js')
}

if [ "${1:-}" = --sourcemaps-artifact ]; then
  [ $# -eq 4 ] || fail "usage: build-image.sh --sourcemaps-artifact OUT DIGEST_FILE DEST"
  out=$2 digest_file=$3 dest=$4
  [ -s "$digest_file" ] || fail "no manifest digest at $digest_file: this leg was not pushed (push-image.sh writes it)"
  digest=$(cat "$digest_file")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "$digest_file does not hold one manifest digest of the form sha256:<64 hex>"
  [ "$digest" != "$(cat "$out/config-digest")" ] ||
    fail "$digest_file holds the config digest of the image, not the digest of its pushed manifest"
  check_sourcemaps "$out/sourcemaps"
  [ ! -e "$dest" ] || [ -z "$(ls -A "$dest")" ] || fail "$dest is not empty"
  mkdir -p "$dest" || fail "create $dest"
  cp -R "$out/sourcemaps/." "$dest/" || fail "copy the source maps to $dest"
  printf '%s\n' "$digest" >"$dest/image-digest"
  [ "$(cd "$dest" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')" = "./_next ./image-digest " ] ||
    fail "$dest holds more than _next/ and image-digest"
  maps=$(find "$dest" -type f -name '*.js.map' | wc -l | tr -d ' ')
  chunks=$(find "$dest" -type f -name '*.js' | wc -l | tr -d ' ')
  ok "packed $maps source maps and $chunks chunks for manifest $digest"
  exit 0
fi

[ $# -eq 3 ] || fail "usage: build-image.sh IMAGE ARCH OUT"
image=$1 arch=$2 out=$3
use_build_source "$image"
check_code_tree
rev=$(git -C "$code_root" rev-parse HEAD)
build_args=()
context=$code_root
case $image in
drill-vulnerable) file=$script_root/deploy/ci/drill/vulnerable.Dockerfile ;;
# Built exactly like a clean service (the gateway's code) so the only difference with a release is the missing
# signature.
drill-unsigned) file=$script_root/$(dockerfile gateway) build_args=(--build-arg SERVICE=gateway) ;;
*)
  if [ "$code_root" = "$script_root" ]; then
    printf '%s\n' "${built_services[@]}" | grep -qxF -- "$image" ||
      fail "$image is not an image this repository builds (${built_services[*]}): its source is another repository's"
    file=$code_root/$(dockerfile "$image")
  else
    # Another repository's tree is one image: its Dockerfile at the top, the whole tree its context.
    require_code_files Dockerfile pnpm-lock.yaml .trivyignore.yaml
    file=$code_root/Dockerfile
  fi
  case $image in
  media-worker) ;;
  web) build_args=(--build-arg "SVP_BUILD_ID=${rev:0:12}") ;;
  *) build_args=(--build-arg "SERVICE=$image") ;;
  esac
  ;;
esac
[ "$(runner_arch)" = "$arch" ] || fail "this host builds $(runner_arch), not $arch: the pipeline never emulates"
mkdir -p "$out" || fail "create $out"
out=$(cd "$out" && pwd)

labels=()
while IFS= read -r label; do labels+=(--label "$label"); done < <(oci_labels "$build_source_name")
tag="${SVP_LOCAL_REPO:-svp-ci}/$image:${rev:0:12}-$arch"

echo "build $image for linux/$arch from $file, context $context"
docker_ buildx build --load --provenance=false --sbom=false --file "$file" \
  ${build_args[@]+"${build_args[@]}"} \
  "${labels[@]}" --tag "$tag" "$context" || fail "build $image"
echo "$tag" >"$out/local-tag"
echo "linux/$arch" >"$out/platform"

if [ "$image" = web ]; then
  echo "export stage sourcemaps of $file, same context and build argument, from the build cache of the image"
  rm -rf "$out/sourcemaps"
  docker_ buildx build --provenance=false --sbom=false --file "$file" --target sourcemaps \
    "${build_args[@]}" --output "type=local,dest=$out/sourcemaps" "$context" ||
    fail "export the source maps of $image"
  check_sourcemaps "$out/sourcemaps"
  built=$(find "$out/sourcemaps" -type f -name '*.js' -exec sed -n 's|^//# debugId=||p' {} + | LC_ALL=C sort -u)
  # The image has no shell: copy its chunks out of a container that is created, never started.
  served=$out/image-chunks
  rm -rf "$served" && mkdir "$served" || fail "create $served"
  cid=$(docker_ create "$tag") || fail "create a container of $tag"
  if ! docker_ cp "$cid:/app/.next/static/chunks" "$served/chunks" >/dev/null; then
    docker_ rm "$cid" >/dev/null
    fail "copy the chunks out of $tag"
  fi
  docker_ rm "$cid" >/dev/null || fail "remove container $cid"
  checked=0
  while IFS= read -r chunk; do
    id=$(sed -n 's|^//# debugId=||p' "$chunk")
    [ -n "$id" ] || continue
    printf '%s\n' "$built" | grep -qxF -- "$id" ||
      fail "chunk ${chunk#"$served"/} of $tag (debug id $id) is not in stage sourcemaps: the maps are of another bundle"
    checked=$((checked + 1))
  done < <(find "$served/chunks" -type f -name '*.js')
  rm -rf "$served"
  [ "$checked" -gt 0 ] || fail "no chunk of $tag carries a debug id"
  maps=$(find "$out/sourcemaps" -type f -name '*.js.map' | wc -l | tr -d ' ')
  ok "$maps source maps exported; the debug ids of the $checked chunks of $tag that carry one are all in them"
fi

rm -f "$out/image.tar"
docker_ save --output "$out/image.tar" "$tag" || fail "save $tag to a tar"

trivy_mounts=(-v "$out/image.tar:/image.tar:ro" -v "$out:/out")
[ -f "$trivyignore" ] && trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
args=()
while IFS= read -r a; do args+=("$a"); done < <(trivy_scan_args)
now_utc >"$out/scan-started"
# A DB that cannot be downloaded fails the scan, and so the leg: never a scan against a DB of unknown age.
trivy_ image --input /image.tar "${args[@]}" --output /out/trivy.json || fail "scan $image with trivy"
now_utc >"$out/scan-finished"
trivy_db_updated_at >"$out/db-updated-at"
jq -r .Metadata.ImageID "$out/trivy.json" >"$out/config-digest"

# SBOM of the same tar: one SPDX document per platform, attested later on the manifest of that
# platform. syft runs with no network; its image has no writable /tmp for a non-root user, hence the tmpfs.
syft_image=$(tool_image SYFT_IMAGE)
rm -f "$out/sbom.spdx.json"
docker_ run --rm --network none --user "$(id -u):$(id -g)" --tmpfs /tmp:mode=1777 -e HOME=/tmp \
  -e SYFT_CHECK_FOR_APP_UPDATE=false -v "$out/image.tar:/image.tar:ro" -v "$out:/out" "$syft_image" \
  docker-archive:/image.tar -o spdx-json=/out/sbom.spdx.json -q || fail "write the SBOM of $image"
jq -e '.spdxVersion' "$out/sbom.spdx.json" >/dev/null 2>&1 || fail "syft wrote no SPDX document for $image"

# grype on that SBOM: a second matcher and DB, and it sees what syft found outside any package manager (the node binary
# of the web image), which trivy does not list. A DB that cannot be fetched fails the leg, as for trivy.
started=$SECONDS
grype_sbom "$out" || fail "scan the SBOM of $image with grype"
jq -e '.descriptor.name == "grype"' "$out/grype.json" >/dev/null 2>&1 || fail "grype wrote no report for $image"
binaries=$(sbom_binaries "$out/sbom.spdx.json")
echo "grype scanned the SBOM of $image in $((SECONDS - started)) s; binaries outside a package manager: ${binaries:-none}"

# SARIF for the Security tab (HIGH and CRITICAL; convert applies the scan's own filters), one category per image and
# architecture, written into the file so one upload carries every category. Written before the gate decides, so a
# blocked image still shows its findings on main.
trivy_ convert --format sarif --severity HIGH,CRITICAL --output /out/trivy.sarif.tmp /out/trivy.json ||
  fail "convert the report of $image to SARIF"
jq --arg c "trivy-image-$image-$arch/" '.runs[].automationDetails.id = $c' "$out/trivy.sarif.tmp" >"$out/trivy.sarif"
rm -f "$out/trivy.sarif.tmp"
grype_sarif "$out" "grype-image-$image-$arch/"

gate=()
[ "$image" = drill-vulnerable ] && gate=(--allow-critical)
blocked=0
"$ci_dir/scan-gate.sh" ${gate[@]+"${gate[@]}"} "$image linux/$arch" "$out/trivy.json" || blocked=1
"$ci_dir/scan-gate.sh" ${gate[@]+"${gate[@]}"} --grype "$image linux/$arch" "$out/grype.json" || blocked=1
exit "$blocked"
