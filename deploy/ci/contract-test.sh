#!/usr/bin/env bash
# Tests for deploy/ci/contract.sh. Everything runs in a throwaway checkout (deploy/ci/, deploy/k8s/lib.sh, the policy's
# values, the Makefile's pins and the gateway's spec, in a git repository of its own), every script under `env -i` so
# no variable of the job running the test (a CI job is one) reaches it.
#
# check, with the pinned oasdiff (Docker, --network none; the image is pulled once if missing):
#   - nothing to compare: the spec unchanged, a base of all zeros (a push that created the branch), a base without the
#     spec: exit 0;
#   - a description changed: red without a raise, green with a patch;
#   - an operation added: red with only a patch, green with a minor;
#   - an operation removed (breaking): red with the version kept or only a minor, green with a major; below 1.0.0
#     green with a minor;
#   - the version lowered, or not MAJOR.MINOR.PATCH: red; a base that is no commit: red.
# publish, against a fake registry (a fake docker answers the ORAS commands from files) and a fake cosign that records
# what it signs, so nothing reaches GHCR or Sigstore. The context of a CI run comes from FAKE_CI_* variables that a
# test-only block appended to the checkout's platform.sh turns into ci_* functions:
#   - a dry run of a version not published: says it would push, pushes and signs nothing, sends no credentials;
#   - a run that is not the signing workflow (a machine, another workflow): nothing pushed;
#   - the signing workflow: pushed with the artifact type, one OpenAPI layer and the source annotation, with the
#     credentials of docker login, then signed in the older format on the pushed digest;
#   - the same again: nothing pushed, nothing signed; the version published but not signed: signed, not pushed again;
#   - the same version with other content: refused, the registry and the signatures unchanged (also as a dry run);
#   - the tag holding something that is no contract, or a registry out of reach: refused, nothing pushed.
# Runs on macOS and Linux; needs Docker for the check cases.
#
# Usage, from anywhere: deploy/ci/contract-test.sh
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

# --- The throwaway checkout.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/services/gateway" "$work/bin" "$work/home/.docker" \
  "$work/registry"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
grep -E '^(OASDIFF|ORAS|COSIGN)_IMAGE[[:space:]]*:=' "$src/Makefile" >"$tree/Makefile"
spec=$tree/services/gateway/openapi.yaml
cat >>"$tree/deploy/ci/platform.sh" <<'EOF'

# Test only (contract-test.sh): with FAKE_CI set, the context of a CI run comes from FAKE_CI_* variables.
if [ -n "${FAKE_CI:-}" ]; then
  ci_builder_id() { printf '%s\n' "$FAKE_CI_BUILDER"; }
  ci_repo_url() { echo https://github.com/anhnvcoder/short-video-platform; }
  ci_commit() { echo 0123456789abcdef0123456789abcdef01234567; }
fi
EOF
g() {
  env -i PATH="$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree" \
    -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q && g add -A && g commit -qm "no spec yet"
no_spec=$(g rev-parse HEAD)
# The spec of the repository at version 1.0.0, and at 0.1.0 in a commit of its own for the rules below 1.0.0.
sed 's/^  version: .*/  version: 0.1.0/' "$src/services/gateway/openapi.yaml" >"$spec"
g add -A && g commit -qm "spec 0.1.0"
v0=$(g rev-parse HEAD)
sed 's/^  version: .*/  version: 1.0.0/' "$src/services/gateway/openapi.yaml" >"$spec"
g add -A && g commit -qm "spec 1.0.0"
v1=$(g rev-parse HEAD)
original=$work/original.yaml
cp "$spec" "$original"

# The check runs real Docker, so it keeps this shell's HOME (docker's context lives there) and DOCKER_* variables.
check() {
  local rc=0 out
  out=$(env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
    ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$tree/deploy/ci/contract.sh" check "$1" 2>&1) || rc=$?
  printf '%s\n' "$rc" "$out"
}
# case_ NAME BASE WANT_STATUS PATTERN: runs the check of the working tree's spec against BASE.
case_() {
  local res
  res=$(check "$2")
  expect "$1" "$3" "$4" "$(head -n 1 <<<"$res")" "$(tail -n +2 <<<"$res")"
}
# version V: sets info.version of the working tree's spec.
version() { sed -i.bak "s/^  version: .*/  version: $1/" "$spec" && rm -f "$spec.bak"; }
restore() { cp "$original" "$spec"; }
# describe: changes the first line of the API's description.
describe() { sed -i.bak 's/^    JSON fields are snake_case/    Every JSON field is snake_case/' "$spec" && rm -f "$spec.bak"; }
# drop PATH: removes the path PATH (with every operation under it) from the working tree's spec.
drop() {
  awk -v p="  $1:" '$0 == p { skip = 1; next } skip && /^  [^ ]/ { skip = 0 } skip && /^[^ ]/ { skip = 0 } !skip' \
    "$spec" >"$spec.new" && mv "$spec.new" "$spec"
}
# add_health2: adds GET /healthz2, a copy of GET /healthz.
add_health2() {
  awk '
    $0 == "  /healthz:" { grab = 1 }
    grab && $0 != "  /healthz:" && (/^  [^ ]/ || /^[^ ]/) { grab = 0 }
    grab { b = b $0 "\n" }
    $0 == "paths:" { at = NR }
    { lines[NR] = $0 }
    END {
      gsub(/  \/healthz:/, "  /healthz2:", b)
      gsub(/operationId: healthz/, "operationId: healthz2", b)
      for (i = 1; i <= NR; i++) { print lines[i]; if (i == at) printf "%s", b }
    }' "$spec" >"$spec.new" && mv "$spec.new" "$spec"
}

grep -q '^  /healthz:' "$spec" || { echo "FAIL  the spec has no /healthz path: the cases below need one" >&2; exit 1; }

# --- check: nothing to compare.
case_ "check: the spec unchanged" "$v1" 0 "is the same as at"
case_ "check: a base of all zeros" 0000000000000000000000000000000000000000 0 "there is no base commit"
case_ "check: a base without the spec" "$no_spec" 0 "has no services/gateway/openapi.yaml"
case_ "check: a base that is no commit" no-such-ref 1 "is not a commit of this clone"

# --- check: a description (no entry in the changelog).
describe
case_ "check: a description changed, the version kept" "$v1" 1 "is not greater than 1\\.0\\.0"
version 1.0.1
case_ "check: a description changed, a patch" "$v1" 0 "1\\.0\\.0 -> 1\\.0\\.1 \\(patch\\)"
version 0.9.0
case_ "check: the version lowered" "$v1" 1 "is not greater than 1\\.0\\.0"
version 1.1
case_ "check: a version that is not MAJOR.MINOR.PATCH" "$v1" 1 "is '1\\.1', not MAJOR\\.MINOR\\.PATCH"
version '"1.0.1"'
case_ "check: a quoted version" "$v1" 1 "not MAJOR\\.MINOR\\.PATCH"
restore

# --- check: an operation added (an entry, not breaking).
add_health2
grep -q '^  /healthz2:' "$spec" || fail "the test could not add /healthz2 to the spec"
version 1.0.1
case_ "check: an operation added, only a patch" "$v1" 1 "the minor \\(or the major\\) must go up"
version 1.1.0
case_ "check: an operation added, a minor" "$v1" 0 "ok    the version rule holds"
restore

# --- check: an operation removed (breaking).
drop /healthz
grep -q '^  /healthz:' "$spec" && fail "the test could not remove /healthz from the spec"
case_ "check: a breaking change, the version kept" "$v1" 1 "api-version-not-bumped"
version 1.1.0
case_ "check: a breaking change, only a minor" "$v1" 1 "api-major-version-not-bumped"
version 2.0.0
res=$(check "$v1")
expect "check: a breaking change, a major" 0 "1 breaking" "$(head -n 1 <<<"$res")" "$(tail -n +2 <<<"$res")"
expect "check: the changelog names the removed operation" 0 "ERR api-path-removed-without-deprecation GET /healthz" \
  "$(head -n 1 <<<"$res")" "$(tail -n +2 <<<"$res")"
version 0.2.0
case_ "check: a breaking change below 1.0.0, a minor" "$v0" 0 "0\\.1\\.0 -> 0\\.2\\.0 \\(minor\\)"
version 0.1.1
case_ "check: a breaking change below 1.0.0, only a patch" "$v0" 1 "the minor \\(or the major\\) must go up"
restore

# --- publish, against the fake registry.
oras_image=fake.invalid/oras@sha256:$(printf '0%.0s' $(seq 64))
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: `docker run [flags] IMAGE ORAS-ARGS...` of the pinned ORAS, answered from files under FAKE_REGISTRY
# (one file per reference, holding the manifest). Logs each ORAS command, and whether credentials were mounted.
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
  jq -nc --arg type "$type" --arg media "${layer#*:}" --arg digest "$digest" --argjson ann "$annotations" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: $type,
      layers: [{mediaType: $media, digest: $digest}], annotations: $ann}' | tr -d '\n' >"$(file "$ref")"
  ;;
*) echo "fake docker: unexpected ORAS command: $*" >&2; exit 99 ;;
esac
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
# Fake cosign: sign records the last argument, verify succeeds for what was signed.
set -euo pipefail
echo "$*" >>"$FAKE_REGISTRY/cosign.log"
ref=${*: -1}
case $1 in
sign) echo "$ref" >>"$FAKE_REGISTRY/signed" ;;
verify) grep -qxF "$ref" "$FAKE_REGISTRY/signed" 2>/dev/null ;;
*) exit 99 ;;
esac
EOF
chmod +x "$work/bin/docker" "$work/bin/cosign"
echo '{"auths":{}}' >"$work/home/.docker/config.json"

subject=https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
repo=ghcr.io/anhnvcoder/short-video-platform/api/gateway
tagfile=$work/registry/$(tr '/:@' '___' <<<"$repo:1.0.0")
# publish BUILDER [NAME=VALUE...] -- ARGS...: contract.sh publish ARGS in a made-up run of workflow BUILDER.
publish() {
  local builder=$1 rc=0 out
  shift
  local extra=()
  while [ "$1" != -- ]; do
    extra+=("$1")
    shift
  done
  shift
  out=$(env -i PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    FAKE_CI=1 FAKE_CI_BUILDER="$builder" FAKE_REGISTRY="$work/registry" FAKE_ORAS_IMAGE="$oras_image" \
    ORAS_IMAGE="$oras_image" ${extra[@]+"${extra[@]}"} "$tree/deploy/ci/contract.sh" publish "$@" 2>&1) || rc=$?
  printf '%s\n' "$rc" "$out"
}
# pub_case NAME BUILDER WANT_STATUS PATTERN [NAME=VALUE...] -- ARGS...
pub_case() {
  local name=$1 builder=$2 want=$3 pattern=$4 res
  shift 4
  res=$(publish "$builder" "$@")
  expect "$name" "$want" "$pattern" "$(head -n 1 <<<"$res")" "$(tail -n +2 <<<"$res")"
}
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }

pub_case "publish: a dry run of a version not published" local 0 "would push" -- --dry-run
[ ! -f "$tagfile" ] && [ "$(count "$work/registry/cosign.log" '^sign')" = 0 ] &&
  ok "publish: the dry run pushed and signed nothing" || fail "publish: the dry run pushed or signed"
[ "$(count "$work/registry/oras.log" 'auth=yes')" = 0 ] && ok "publish: the dry run sent no credentials" ||
  fail "publish: the dry run mounted the credentials of docker login"

pub_case "publish: a run on a machine" local 1 "a contract is published only by $subject" --
pub_case "publish: a run of another workflow" \
  https://github.com/anhnvcoder/short-video-platform/.github/workflows/contract.yml@refs/heads/main 1 \
  "a contract is published only by" --
[ ! -f "$tagfile" ] && ok "publish: a run that cannot sign pushed nothing" || fail "publish: a run that cannot sign pushed"

pub_case "publish: the signing workflow, a new version" "$subject" 0 "published and signed: $repo@sha256:" --
want_layer=sha256:$(shasum -a 256 "$spec" | cut -d' ' -f1)
digest=sha256:$(shasum -a 256 "$tagfile" 2>/dev/null | cut -d' ' -f1)
if [ -f "$tagfile" ] && jq -e --arg l "$want_layer" '.artifactType == "application/vnd.anhnvcoder.svp.api-contract.v1"
  and (.layers | length) == 1 and .layers[0].mediaType == "application/vnd.oai.openapi" and .layers[0].digest == $l
  and .annotations["org.opencontainers.image.source"] == "https://github.com/anhnvcoder/short-video-platform"
  and .annotations["org.opencontainers.image.version"] == "1.0.0"' "$tagfile" >/dev/null; then
  ok "publish: pushed one OpenAPI layer of this spec, with its artifact type and annotations"
else
  fail "publish: the pushed manifest is not the expected one: $(cat "$tagfile" 2>/dev/null)"
fi
grep -q '^auth=yes push ' "$work/registry/oras.log" && ok "publish: pushed with the credentials of docker login" ||
  fail "publish: pushed without the credentials"
grep -qxF "sign --yes --new-bundle-format=false --use-signing-config=false $repo@$digest" "$work/registry/cosign.log" &&
  ok "publish: signed the pushed digest in the older format" ||
  fail "publish: no signature of $repo@$digest: $(cat "$work/registry/cosign.log")"

pushes=$(count "$work/registry/oras.log" ' push ') signs=$(count "$work/registry/cosign.log" '^sign')
pub_case "publish: the same version and content again" "$subject" 0 "nothing to do" --
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && [ "$(count "$work/registry/cosign.log" '^sign')" = "$signs" ] &&
  ok "publish: published again: nothing pushed, nothing signed" || fail "publish: published again: pushed or signed"

: >"$work/registry/signed"
pub_case "publish: the version published but not signed" "$subject" 0 "published and signed" --
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && [ "$(count "$work/registry/cosign.log" '^sign')" = $((signs + 1)) ] &&
  ok "publish: an unsigned release is signed, not pushed again" || fail "publish: the unsigned release was not handled"

before=$(cat "$tagfile") signs=$(count "$work/registry/cosign.log" '^sign')
describe
pub_case "publish: the same version with other content" "$subject" 1 "already published with other content" --
pub_case "publish: the same version with other content, dry run" local 1 "already published with other content" -- --dry-run
[ "$(cat "$tagfile")" = "$before" ] && [ "$(count "$work/registry/cosign.log" '^sign')" = "$signs" ] &&
  ok "publish: other content: the registry and the signatures unchanged" || fail "publish: other content overwrote the release"
restore

echo '{"schemaVersion":2,"artifactType":"application/vnd.oci.image.config.v1+json","layers":[]}' >"$tagfile"
pub_case "publish: the tag holds something else" "$subject" 1 "is not a contract release" --
rm -f "$tagfile"
pushes=$(count "$work/registry/oras.log" ' push ')
pub_case "publish: the registry out of reach" "$subject" 1 "read $repo:1.0.0 from the registry" FAKE_REGISTRY_DOWN=1 --
[ "$(count "$work/registry/oras.log" ' push ')" = "$pushes" ] && ok "publish: a registry out of reach: nothing pushed" ||
  fail "publish: pushed after a failed read"
pub_case "publish: an argument it does not know" "$subject" 1 "usage: contract.sh publish" -- --force

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures of the checks above" >&2
  exit 1
fi
echo "ok    all contract.sh checks passed"
