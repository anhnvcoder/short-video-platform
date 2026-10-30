#!/usr/bin/env bash
# Tests for deploy/ci/sourcemaps-image.sh. Everything runs in a throwaway checkout (deploy/ci/, deploy/k8s/lib.sh, the
# policy's table of release sources and the Makefile's pins), every script under `env -i` so no variable of the job
# running the test reaches it. A fake docker answers the ORAS commands from files (one per reference, blobs by
# digest), so nothing reaches GHCR. The context of a CI run comes from FAKE_CI_* variables that a test-only block
# appended to the checkout's platform.sh turns into ci_* functions. Checked:
#   - DIR refused before the registry is read: a file beside _next/ and image-digest, a link under _next/, a digest of
#     another form or of two lines, a file under _next/ that is no chunk or map, a chunk without its sourceMappingURL;
#     an ARCH other than amd64 or arm64;
#   - a dry run of a tag not pushed: says it would push, pushes nothing, sends no credentials;
#   - a run that is not the signing workflow of the source (a machine, another workflow), and a run of a repository that
#     is no release source: nothing pushed;
#   - the signing workflow of svp-web: pushed with the credentials of docker login as <prefix>web-sourcemaps:amd64-<hex
#     of image-digest>, one gzipped tar layer, the artifact type and the source annotation; read back by image_maps of
#     gitops-sourcemaps.sh (its own checks of the manifest and the layer), which unpacks the very tree of DIR/_next;
#   - the same tree again, packed into other bytes: nothing pushed, the tag read with credentials; another tree under the
#     same tag: refused, the tag unchanged (also as a dry run); the tag holding something that is no image of source
#     maps, or a registry out of reach: refused, nothing pushed;
#   - a table of release sources whose web source names web-sourcemaps among its services: refused.
# Runs on macOS and Linux: no network, no Docker.
#
# Usage, from anywhere: deploy/ci/sourcemaps-image-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# expect NAME WANT_STATUS PATTERN STATUS OUTPUT: ok when STATUS is WANT_STATUS and OUTPUT holds PATTERN (grep -E).
expect() {
  if [ "$4" = "$2" ] && grep -qE -- "$3" <<<"$5"; then
    ok "$1"
  else
    fail "$1 (want exit $2 and /$3/, got exit $4):"$'\n'"$(sed 's/^/      /' <<<"$5")"
  fi
}
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }

# --- The throwaway checkout.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$work/bin" "$work/home/.docker" "$work/registry"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
grep -E '^(ORAS|COSIGN)_IMAGE[[:space:]]*:=' "$src/Makefile" >"$tree/Makefile"
cat >>"$tree/deploy/ci/platform.sh" <<'EOF'

# Test only (sourcemaps-image-test.sh): with FAKE_CI set, the context of a CI run comes from FAKE_CI_* variables.
if [ -n "${FAKE_CI:-}" ]; then
  ci_builder_id() { printf '%s\n' "$FAKE_CI_BUILDER"; }
  ci_repo_url() { printf '%s\n' "$FAKE_CI_REPO"; }
  ci_commit() { echo 0123456789abcdef0123456789abcdef01234567; }
fi
EOF

# --- The fake registry.
oras_image=fake.invalid/oras@sha256:$(printf '0%.0s' $(seq 64))
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: `docker run [flags] IMAGE ORAS-ARGS...` of the pinned ORAS, answered from files under FAKE_REGISTRY: one
# file per reference holding its manifest, one per repository@digest holding a blob. Logs each ORAS command, and
# whether credentials were mounted.
set -euo pipefail
reg=$FAKE_REGISTRY
[ "${1:-}" = run ] || { echo "fake docker: only run, got: $*" >&2; exit 99; }
shift
host= auth=no
while [ $# -gt 0 ]; do
  case $1 in
  --rm | -i) shift ;;
  --user | -e | -w) shift 2 ;;
  -v)
    case $2 in
    *:/work) host=${2%:/work} ;;
    *:/auth/config.json:ro) auth=yes ;;
    esac
    shift 2
    ;;
  *) break ;;
  esac
done
[ "$1" = "$FAKE_ORAS_IMAGE" ] || { echo "fake docker: unexpected image $1" >&2; exit 99; }
shift
echo "auth=$auth $*" >>"$reg/oras.log"
file() { echo "$reg/$(tr '/:@' '___' <<<"$1")"; }
if [ -n "${FAKE_REGISTRY_DOWN:-}" ]; then
  echo 'Error: Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: i/o timeout' >&2
  exit 1
fi
case "$1 ${2:-}" in
"manifest fetch")
  f=$(file "$3")
  if [ ! -f "$f" ]; then
    echo "Error response from registry: failed to fetch the content of \"$3\": $3: not found" >&2
    exit 1
  fi
  cat "$f"
  ;;
"blob fetch")
  [ "$3" = --output ] || { echo "fake docker: blob fetch without --output" >&2; exit 99; }
  f=$(file "$5")
  [ -f "$f" ] || { echo "Error: $5: not found" >&2; exit 1; }
  cp "$f" "$host/$4"
  ;;
"push "*)
  ref=$2
  shift 2
  type= annotations='{}' layer=
  while [ $# -gt 0 ]; do
    case $1 in
    --artifact-type) type=$2; shift 2 ;;
    --annotation) annotations=$(jq -c --arg kv "$2" '. + {($kv | split("=")[0]): ($kv | split("=")[1:] | join("="))}' <<<"$annotations"); shift 2 ;;
    --registry-config) shift 2 ;;
    *) layer=$1; shift ;;
    esac
  done
  path=$host/${layer%%:*}
  digest=sha256:$(shasum -a 256 "$path" | cut -d' ' -f1)
  cp "$path" "$(file "${ref%:*}@$digest")"
  jq -nc --arg type "$type" --arg media "${layer#*:}" --arg digest "$digest" --argjson size "$(wc -c <"$path")" \
    --argjson ann "$annotations" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
      artifactType: $type, config: {mediaType: "application/vnd.oci.empty.v1+json",
        digest: "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", size: 2},
      layers: [{mediaType: $media, digest: $digest, size: $size}], annotations: $ann}' | tr -d '\n' >"$(file "$ref")"
  ;;
*) echo "fake docker: unexpected ORAS command: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/bin/docker"
echo '{"auths":{}}' >"$work/home/.docker/config.json"

# --- The source maps of one leg, as build-image.sh --sourcemaps-artifact packs them.
child=sha256:$(printf '%s' amd64-manifest | shasum -a 256 | cut -d' ' -f1)
hex=${child#sha256:}
good=$work/maps
mkdir -p "$good/_next/static/chunks/app"
printf '// chunk a\n//# debugId=00000000-0000-0000-0000-000000000001\n//# sourceMappingURL=a.js.map\n' \
  >"$good/_next/static/chunks/a.js"
echo '{"version":3,"sources":["a.ts"]}' >"$good/_next/static/chunks/a.js.map"
printf '// page\n//# sourceMappingURL=page.js.map\n' >"$good/_next/static/chunks/app/page.js"
echo '{"version":3,"sources":["page.tsx"]}' >"$good/_next/static/chunks/app/page.js.map"
printf '%s\n' "$child" >"$good/image-digest"
# variant NAME: a copy of the good folder at $work/NAME, printed.
variant() {
  cp -R "$good" "$work/$1"
  echo "$work/$1"
}

web_subject=https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main
web_url=https://github.com/anhnvcoder/svp-web
repo=ghcr.io/anhnvcoder/svp-web/web-sourcemaps
tagfile=$work/registry/$(tr '/:@' '___' <<<"$repo:amd64-$hex")
# push BUILDER [NAME=VALUE...] -- ARGS...: sourcemaps-image.sh push ARGS in a made-up run of svp-web's workflow BUILDER.
push() {
  local builder=$1 rc=0 out extra=()
  shift
  while [ "$1" != -- ]; do
    extra+=("$1")
    shift
  done
  shift
  out=$(env -i PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    FAKE_CI=1 FAKE_CI_BUILDER="$builder" FAKE_CI_REPO="$web_url" FAKE_REGISTRY="$work/registry" \
    FAKE_ORAS_IMAGE="$oras_image" ORAS_IMAGE="$oras_image" ${extra[@]+"${extra[@]}"} \
    "${SCRIPT:-$tree/deploy/ci/sourcemaps-image.sh}" push "$@" 2>&1) || rc=$?
  printf '%s\n' "$rc" "$out"
}
# push_case NAME BUILDER WANT_STATUS PATTERN [NAME=VALUE...] -- ARGS...
push_case() {
  local name=$1 builder=$2 want=$3 pattern=$4 res
  shift 4
  res=$(push "$builder" "$@")
  expect "$name" "$want" "$pattern" "$(head -n 1 <<<"$res")" "$(tail -n +2 <<<"$res")"
}

# --- DIR refused before the registry is read.
d=$(variant extra) && echo note >"$d/README"
push_case "a file beside _next/ and image-digest" "$web_subject" 1 "not exactly _next/ and image-digest" -- amd64 "$d"
d=$(variant link) && ln -s /etc/hosts "$d/_next/static/chunks/hosts"
push_case "a link under _next/" "$web_subject" 1 "entries that are not regular files" -- amd64 "$d"
d=$(variant link-digest) && rm "$d/image-digest" && ln -s "$good/image-digest" "$d/image-digest"
push_case "image-digest as a link" "$web_subject" 1 "image-digest is not a regular file" -- amd64 "$d"
d=$(variant upper) && printf 'SHA256:%s\n' "$hex" >"$d/image-digest"
push_case "a digest of another form" "$web_subject" 1 "does not hold one line sha256:<64 hex>" -- amd64 "$d"
d=$(variant two) && printf '%s\n%s\n' "$child" "$child" >"$d/image-digest"
push_case "a digest of two lines" "$web_subject" 1 "does not hold one line sha256:<64 hex>" -- amd64 "$d"
d=$(variant other-file) && echo x >"$d/_next/static/notes.txt"
push_case "a file under _next/ that is no chunk or map" "$web_subject" 1 "files other than chunks and maps" -- amd64 "$d"
d=$(variant no-url) && printf '// chunk a\n' >"$d/_next/static/chunks/a.js"
push_case "a chunk without its sourceMappingURL" "$web_subject" 1 "has lost its sourceMappingURL comment" -- amd64 "$d"
push_case "an ARCH other than amd64 or arm64" "$web_subject" 1 "ARCH must be amd64 or arm64" -- x86 "$good"
push_case "no ARCH" "$web_subject" 1 "usage: sourcemaps-image.sh push" -- "$good"
[ "$(count "$work/registry/oras.log" .)" = 0 ] && ok "a refused folder: the registry never read" ||
  fail "a refused folder: the registry was read"

# --- A dry run, and runs that may not push.
push_case "a dry run of a tag not pushed" local 0 "would push" -- --dry-run amd64 "$good"
[ ! -f "$tagfile" ] && [ "$(count "$work/registry/oras.log" 'auth=yes')" = 0 ] &&
  ok "the dry run pushed nothing and sent no credentials" || fail "the dry run pushed or sent credentials"
push_case "a run on a machine" local 1 "source maps go under ghcr.io/anhnvcoder/svp-web/ only from $web_subject" -- \
  amd64 "$good"
push_case "a run of another workflow" https://github.com/anhnvcoder/svp-web/.github/workflows/ci.yml@refs/heads/main 1 \
  "only from $web_subject" -- amd64 "$good"
push_case "a run of a repository that is no release source" "$web_subject" 1 "repository of 0 release sources" \
  FAKE_CI_REPO=https://github.com/someone/svp-web -- amd64 "$good"
[ ! -f "$tagfile" ] && ok "a run that may not push pushed nothing" || fail "a run that may not push pushed"

# --- The signing workflow.
push_case "the signing workflow, a new tag" "$web_subject" 0 "pushed: the source maps of $child" -- amd64 "$good"
layer=$(jq -r '.layers[0].digest' "$tagfile" 2>/dev/null || true)
if [ -f "$tagfile" ] && jq -e '.artifactType == "application/vnd.anhnvcoder.svp.web-sourcemaps.v1"
  and (.layers | length) == 1 and .layers[0].mediaType == "application/vnd.oci.image.layer.v1.tar+gzip"
  and .annotations["org.opencontainers.image.source"] == "https://github.com/anhnvcoder/svp-web"' "$tagfile" >/dev/null; then
  ok "pushed one gzipped tar layer, with its artifact type and the source annotation, tagged amd64-<hex>"
else
  fail "the pushed manifest is not the expected one: $(cat "$tagfile" 2>/dev/null)"
fi
grep -q '^auth=yes push ' "$work/registry/oras.log" && ok "pushed with the credentials of docker login" ||
  fail "pushed without the credentials"
grep -q "^auth=yes manifest fetch $repo:amd64-$hex " "$work/registry/oras.log" &&
  ok "the tag was looked up with the credentials" || fail "the tag was looked up without the credentials"

# Read back as the GitOps run reads it: image_maps of gitops-sourcemaps.sh, its GHCR reads answered from the registry.
(
  # shellcheck source=deploy/ci/gitops-sourcemaps.sh
  . "$tree/deploy/ci/gitops-sourcemaps.sh"
  web_prefix=ghcr.io/anhnvcoder/svp-web/ web_repo=ghcr.io/anhnvcoder/svp-web/web
  web_index=sha256:$(printf 'i%.0s' $(seq 64)) rev="origin/main of svp-gitops"
  ghcr_get() { cp "$work/registry/$(tr '/:@' '___' <<<"ghcr.io/$1:${2#manifests/}")" "$3"; }
  ghcr_blob() { cp "$work/registry/$(tr '/:@' '___' <<<"ghcr.io/$1@$2")" "$3"; }
  mkdir "$work/readback"
  image_maps "$work/readback" "$child"
) >"$work/readback.out" 2>&1 && rc=0 || rc=$?
if [ "$rc" = 0 ] && diff -r "$good/_next" "$work/readback/maps/_next" >/dev/null; then
  ok "image_maps of gitops-sourcemaps.sh reads back the very tree of _next/"
else
  fail "image_maps did not read the tree back (exit $rc): $(cat "$work/readback.out")"
fi

# --- The same tree again, packed into other bytes (another mtime).
pushes=$(count "$work/registry/oras.log" ' push ') before=$(cat "$tagfile")
touch -t 202001010000 "$good/_next/static/chunks/a.js"
push_case "the same tree again" "$web_subject" 0 "already holds these source maps" -- amd64 "$good"
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && [ "$(cat "$tagfile")" = "$before" ] &&
  ok "the same tree again: nothing pushed" || fail "the same tree again: pushed"
grep -q "^auth=yes blob fetch --output existing.tgz $repo@$layer " "$work/registry/oras.log" &&
  ok "the same tree again: its layer pulled with the credentials" || fail "the layer was pulled without the credentials"

# --- Another tree under the same tag.
d=$(variant changed) && echo '{"version":3,"sources":["b.ts"]}' >"$d/_next/static/chunks/a.js.map"
push_case "another tree under the same tag" "$web_subject" 1 "already holds other source maps" -- amd64 "$d"
push_case "another tree under the same tag, dry run" local 1 "already holds other source maps" -- --dry-run amd64 "$d"
d=$(variant fewer) && rm "$d/_next/static/chunks/app/page.js" "$d/_next/static/chunks/app/page.js.map"
push_case "a tree with fewer files under the same tag" "$web_subject" 1 "already holds other source maps" -- amd64 "$d"
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && [ "$(cat "$tagfile")" = "$before" ] &&
  ok "another tree: the tag unchanged" || fail "another tree overwrote the tag"

# --- The tag holding something else; the registry out of reach.
echo '{"schemaVersion":2,"artifactType":"application/vnd.oci.image.config.v1+json","layers":[]}' >"$tagfile"
push_case "the tag holds something else" "$web_subject" 1 "is not an image of source maps" -- amd64 "$good"
rm -f "$tagfile"
push_case "the registry out of reach" "$web_subject" 1 "read $repo:amd64-$hex from the registry" \
  FAKE_REGISTRY_DOWN=1 -- amd64 "$good"
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && ok "refused: nothing pushed" ||
  fail "refused, but pushed"

# --- web-sourcemaps named an image of the source.
cp -R "$tree" "$work/tree-named"
jq '(.sources[] | select(.name == "web") | .services) += ["web-sourcemaps"]' \
  "$tree/deploy/helm/svp-policy/files/sources.json" >"$work/tree-named/deploy/helm/svp-policy/files/sources.json"
SCRIPT=$work/tree-named/deploy/ci/sourcemaps-image.sh push_case "web-sourcemaps among the services of the source" \
  "$web_subject" 1 "web-sourcemaps is an image of release source web" -- amd64 "$good"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures of the checks above" >&2
  exit 1
fi
echo "ok    all sourcemaps-image.sh checks passed"
