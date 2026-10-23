#!/usr/bin/env bash
# build-image.sh IMAGE ARCH OUT: steps 1-3 of one leg of the image pipeline (docs/adr/0015-cicd-devsecops-stage5.md,
# sections 4 and 6), shared by the pull request job (which stops here) and the main job (which then pushes):
#   1. `docker buildx build --load` from the existing Dockerfile, on this host's own architecture (no emulation, no
#      cross-compiling: the Dockerfiles stay what `make up` and `make k8s-up` use), OCI labels of the commit, no
#      BuildKit provenance or SBOM so the image is one plain manifest;
#   2. `docker save` to OUT/image.tar; trivy reads that very tar (read-only mount), so what is scanned is what step 4
#      pushes, compared by config digest;
#   3. scan-gate.sh on the report. A blocked image exits non-zero and nothing after it runs.
# IMAGE is one of the seven services, or drill-vulnerable / drill-unsigned (images built only to drill admission, never
# run). The web image builds from the context web/ (build_context of deploy/k8s/lib.sh) with SVP_BUILD_ID set to the
# first 12 hex digits of the commit, the image's tag: both architectures of a commit get the same id, which Next uses
# as its deploymentId and the server as its release name (docs/adr/0019-web-k3d-supply-chain-observability.md,
# section 1). trivy then reads the package.json of every package in the image's node_modules, so npm packages go
# through the same CRITICAL and secret gate, and syft lists them in the SBOM. ARCH (amd64, arm64) must be this host's
# architecture. OUT receives:
#   image.tar, local-tag, platform, config-digest, trivy.json, trivy.sarif, sbom.spdx.json, scan-started,
#   scan-finished, db-updated-at
# Only drill-vulnerable passes --allow-critical to the gate; the secret gate holds for every image.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 3 ] || fail "usage: build-image.sh IMAGE ARCH OUT"
image=$1 arch=$2 out=$3
rev=$(git -C "$repo_root" rev-parse HEAD)
build_args=()
context=.
case $image in
drill-vulnerable) file=deploy/ci/drill/vulnerable.Dockerfile ;;
# Built exactly like a clean service (the gateway's code) so the only difference with a release is the missing
# signature.
drill-unsigned) file=$(dockerfile gateway) build_args=(--build-arg SERVICE=gateway) ;;
*)
  printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$image" || fail "$image is not an image of this repository"
  file=$(dockerfile "$image")
  context=$(build_context "$image")
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
while IFS= read -r label; do labels+=(--label "$label"); done < <(oci_labels)
tag="${SVP_LOCAL_REPO:-svp-ci}/$image:${rev:0:12}-$arch"

echo "build $image for linux/$arch from $file, context $context"
docker_ buildx build --load --provenance=false --sbom=false --file "$repo_root/$file" \
  ${build_args[@]+"${build_args[@]}"} \
  "${labels[@]}" --tag "$tag" "$repo_root/$context" || fail "build $image"
echo "$tag" >"$out/local-tag"
echo "linux/$arch" >"$out/platform"

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

# SBOM of the same tar (ADR section 7): one SPDX document per platform, attested later on the manifest of that
# platform. syft runs with no network; its image has no writable /tmp for a non-root user, hence the tmpfs.
syft_image=$(tool_image SYFT_IMAGE)
rm -f "$out/sbom.spdx.json"
docker_ run --rm --network none --user "$(id -u):$(id -g)" --tmpfs /tmp:mode=1777 -e HOME=/tmp \
  -e SYFT_CHECK_FOR_APP_UPDATE=false -v "$out/image.tar:/image.tar:ro" -v "$out:/out" "$syft_image" \
  docker-archive:/image.tar -o spdx-json=/out/sbom.spdx.json -q || fail "write the SBOM of $image"
jq -e '.spdxVersion' "$out/sbom.spdx.json" >/dev/null 2>&1 || fail "syft wrote no SPDX document for $image"

# SARIF for the Security tab (HIGH and CRITICAL; convert applies the scan's own filters), one category per image and
# architecture, written into the file so one upload carries every category. Written before the gate decides, so a
# blocked image still shows its findings on main.
trivy_ convert --format sarif --severity HIGH,CRITICAL --output /out/trivy.sarif.tmp /out/trivy.json ||
  fail "convert the report of $image to SARIF"
jq --arg c "trivy-image-$image-$arch/" '.runs[].automationDetails.id = $c' "$out/trivy.sarif.tmp" >"$out/trivy.sarif"
rm -f "$out/trivy.sarif.tmp"

gate=()
[ "$image" = drill-vulnerable ] && gate=(--allow-critical)
"$ci_dir/scan-gate.sh" ${gate[@]+"${gate[@]}"} "$image linux/$arch" "$out/trivy.json"
