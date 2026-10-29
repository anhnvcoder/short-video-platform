#!/usr/bin/env bash
# Tests for deploy/ci/provenance-predicate.sh and the provenance step of deploy/ci/sign-image.sh. Everything runs in a
# throwaway checkout (deploy/ci/, deploy/k8s/lib.sh and the policy's values, in a git repository of its own), every
# script under `env -i` so no variable of the job running the test (a CI job is one) reaches it. The context of a CI run
# is made up through FAKE_CI_* variables that a test-only block appended to the checkout's platform.sh turns into the
# ci_* functions the predicate reads; without FAKE_CI the real functions of a machine answer. A fake docker serves a
# made-up index and a fake cosign records its arguments, so nothing reaches a registry or Sigstore. Checked:
#   - a made-up push run: the predicate is exactly the fields the attestation carries, no other;
#   - a dispatch with services set: inputs.services is recorded; left empty: no inputs at all;
#   - each value of the context missing, or malformed (a commit not 40 hex, a repository URL with a user, a blank):
#     exit 1 and nothing written; no OUT: exit 2;
#   - on a machine: a complete predicate whose run values are "local" and whose commit is HEAD of the checkout;
#   - sign-image.sh on a release: sign, SBOM on each manifest, vuln then provenance on the index, all in the older
#     format with --replace, the provenance being the predicate of this run; a builder other than the signing identity
#     (a machine, another workflow) or a context that cannot make the predicate: nothing signed at all;
#   - sign-image.sh on the drill image drill-vulnerable: signed and vuln attested, no provenance, even on a machine.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/provenance-predicate-test.sh
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
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}

# --- The throwaway checkout.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$work/bin" "$work/home"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/helm/svp-policy/values.yaml" "$tree/deploy/helm/svp-policy/"
cat >>"$tree/deploy/ci/platform.sh" <<'EOF'

# Test only (provenance-predicate-test.sh): with FAKE_CI set, the context of a CI run comes from FAKE_CI_* variables.
if [ -n "${FAKE_CI:-}" ]; then
  _fake() {
    [ -n "${!1:-}" ] || {
      _ci_fail "$1 is empty"
      return 1
    }
    printf '%s\n' "${!1}"
  }
  ci_builder_id() { _fake FAKE_CI_BUILDER; }
  ci_run_attempt_url() { _fake FAKE_CI_INVOCATION; }
  ci_repo_url() { _fake FAKE_CI_REPOSITORY; }
  ci_ref() { _fake FAKE_CI_REF; }
  ci_commit() { _fake FAKE_CI_COMMIT; }
  ci_workflow_path() { _fake FAKE_CI_WORKFLOW_PATH; }
  ci_workflow_ref() { _fake FAKE_CI_WORKFLOW_REF; }
  ci_dispatch_input() { [ "$1" != services ] || printf '%s\n' "${FAKE_CI_SERVICES:-}"; }
fi
EOF
g() {
  env -i PATH="$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$tree" \
    -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q && g add -A && g commit -qm base
head_commit=$(g rev-parse HEAD)

subject=https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
commit=0123456789abcdef0123456789abcdef01234567
# run [NAME=VALUE...] COMMAND...: COMMAND with no variable of this shell but PATH (fakes first), HOME and the fakes'.
run() {
  env -i PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    FAKE_COSIGN_LOG="$work/cosign.log" FAKE_INDEX="$work/index.json" FAKE_ATTESTED="$work/attested" "$@"
}
# push_run [NAME=VALUE...] COMMAND...: COMMAND in a made-up push run of images.yml on main.
push_run() {
  run FAKE_CI=1 FAKE_CI_BUILDER="$subject" \
    FAKE_CI_INVOCATION=https://github.com/anhnvcoder/short-video-platform/actions/runs/77/attempts/2 \
    FAKE_CI_REPOSITORY=https://github.com/anhnvcoder/short-video-platform FAKE_CI_REF=refs/heads/main \
    FAKE_CI_COMMIT=$commit FAKE_CI_WORKFLOW_PATH=.github/workflows/images.yml FAKE_CI_WORKFLOW_REF=refs/heads/main "$@"
}
predicate=$tree/deploy/ci/provenance-predicate.sh
want_push='{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"ref":"refs/heads/main","repository":"https://github.com/anhnvcoder/short-video-platform","path":".github/workflows/images.yml"}},"resolvedDependencies":[{"uri":"git+https://github.com/anhnvcoder/short-video-platform@refs/heads/main","digest":{"gitCommit":"0123456789abcdef0123456789abcdef01234567"}}]},"runDetails":{"builder":{"id":"https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main"},"metadata":{"invocationId":"https://github.com/anhnvcoder/short-video-platform/actions/runs/77/attempts/2"}}}'

# --- provenance-predicate.sh
out=$work/provenance.json
push_run "$predicate" "$out" >/dev/null
same "a push run: exactly the fields of the attestation" "$want_push" "$(jq -c . "$out")"
same "only OUT is written beside it" provenance.json "$(ls "$work" | grep '^provenance')"

push_run FAKE_CI_SERVICES="gateway web" "$predicate" "$out" >/dev/null
same "a dispatch with services: inputs.services recorded" \
  "$(jq -c '.buildDefinition.externalParameters += {inputs: {services: "gateway web"}}' <<<"$want_push")" \
  "$(jq -c . "$out")"
push_run FAKE_CI_SERVICES= "$predicate" "$out" >/dev/null
same "a dispatch with services empty: no inputs" "$want_push" "$(jq -c . "$out")"

# refused NAME [NAME=VALUE...]: provenance-predicate.sh in the push run changed by the assignments exits 1 and writes
# no file at all.
refused() {
  local name=$1 rc=0
  shift
  rm -f "$out"
  push_run "$@" "$predicate" "$out" >/dev/null 2>"$work/err" || rc=$?
  if [ "$rc" = 1 ] && [ ! -e "$out" ] && [ -z "$(ls "$work" | grep '^provenance')" ]; then
    ok "$name: exit 1, nothing written"
  else
    fail "$name: exit 1, nothing written (exit $rc; $(ls "$work" | grep '^provenance' | tr '\n' ' '))"
  fi
}
for var in FAKE_CI_BUILDER FAKE_CI_INVOCATION FAKE_CI_REPOSITORY FAKE_CI_REF FAKE_CI_COMMIT FAKE_CI_WORKFLOW_PATH \
  FAKE_CI_WORKFLOW_REF; do
  refused "$var missing" "$var="
done
refused "a commit that is not 40 hex" FAKE_CI_COMMIT=0123456789abcdef
refused "a commit in upper case" FAKE_CI_COMMIT=0123456789ABCDEF0123456789ABCDEF01234567
refused "a repository URL with a user and token" FAKE_CI_REPOSITORY=https://x-access-token:tok@github.com/o/r
refused "a repository that is not https://" FAKE_CI_REPOSITORY=http://github.com/o/r
refused "a ref with a blank" "FAKE_CI_REF=refs/heads/a b"
rc=0
push_run "$predicate" >/dev/null 2>&1 || rc=$?
same "no OUT: usage, exit 2" 2 "$rc"

run "$predicate" "$out" >/dev/null
same "on a machine: run values local, commit HEAD of the checkout" \
  "{\"buildDefinition\":{\"buildType\":\"https://actions.github.io/buildtypes/workflow/v1\",\"externalParameters\":{\"workflow\":{\"ref\":\"local\",\"repository\":\"https://github.com/anhnvcoder/short-video-platform\",\"path\":\"local\"}},\"resolvedDependencies\":[{\"uri\":\"git+https://github.com/anhnvcoder/short-video-platform@local\",\"digest\":{\"gitCommit\":\"$head_commit\"}}]},\"runDetails\":{\"builder\":{\"id\":\"local\"},\"metadata\":{\"invocationId\":\"local\"}}}" \
  "$(jq -c . "$out")"

# --- sign-image.sh, with a fake docker serving the index and a fake cosign. cosign logs one line per call and keeps a
# copy of the predicate of each attestation of the index, by type.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "buildx imagetools inspect --raw $FAKE_REF" ] || {
  echo "fake docker: unexpected call: $*" >&2
  exit 1
}
cat "$FAKE_INDEX"
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
type='' file=''
while [ $# -gt 0 ]; do
  case $1 in
  --type) type=$2 ;;
  --predicate) file=$2 ;;
  esac
  shift
done
[ -z "$type" ] || cp "$file" "$FAKE_ATTESTED/$type.json"
EOF
chmod 755 "$work/bin/docker" "$work/bin/cosign"
digest_amd64=sha256:$(printf 'a%.0s' $(seq 64))
digest_arm64=sha256:$(printf 'b%.0s' $(seq 64))
config=sha256:$(printf 'c%.0s' $(seq 64))
jq -nc --arg a "$digest_amd64" --arg b "$digest_arm64" '{schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
    {digest: $a, platform: {os: "linux", architecture: "amd64"}},
    {digest: $b, platform: {os: "linux", architecture: "arm64"}}]}' >"$work/index.json"
index_digest=sha256:$(shasum -a 256 "$work/index.json" | cut -d' ' -f1)
for arch in amd64 arm64; do
  d=$work/leg-$arch
  mkdir -p "$d"
  echo "linux/$arch" >"$d/platform"
  if [ $arch = amd64 ]; then echo "$digest_amd64" >"$d/digest"; else echo "$digest_arm64" >"$d/digest"; fi
  echo "$config" >"$d/config-digest"
  jq -n --arg c "$config" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$d/trivy.json"
  for f in scan-started scan-finished db-updated-at; do echo 2026-10-29T01:02:03Z >"$d/$f"; done
  echo '{"spdxVersion": "SPDX-2.3"}' >"$d/sbom.spdx.json"
done
# image NAME: the index directory merge-index.sh would write for image NAME.
image() {
  rm -rf "$work/index" && mkdir -p "$work/index"
  echo "ghcr.io/anhnvcoder/short-video-platform/$1" >"$work/index/repository"
  echo "$index_digest" >"$work/index/digest"
}
# sign [NAME=VALUE...] -- [--allow-critical]: sign-image.sh on the image of the index directory, in the run changed by
# the assignments; prints its exit code.
sign() {
  local env=() rc=0
  while [ "$1" != -- ]; do
    env+=("$1")
    shift
  done
  shift
  : >"$work/cosign.log"
  rm -rf "$work/attested" && mkdir "$work/attested"
  "${env[@]}" FAKE_REF="$(cat "$work/index/repository")@$index_digest" "$tree/deploy/ci/sign-image.sh" "$@" \
    "$work/index" "$work/leg-amd64" "$work/leg-arm64" >/dev/null 2>"$work/err" || rc=$?
  echo "$rc"
}
legacy="--yes --new-bundle-format=false --use-signing-config=false"
repo=ghcr.io/anhnvcoder/short-video-platform/gateway

image gateway
same "a release: signed and attested" 0 "$(sign push_run --)"
same "a release: sign, SBOM on each manifest, vuln then provenance on the index, older format, --replace" \
  "sign $legacy $repo@$index_digest
attest $legacy --replace --type spdxjson --predicate $work/leg-amd64/sbom.spdx.json $repo@$digest_amd64
attest $legacy --replace --type spdxjson --predicate $work/leg-arm64/sbom.spdx.json $repo@$digest_arm64
attest $legacy --replace --type vuln --predicate PREDICATE $repo@$index_digest
attest $legacy --replace --type slsaprovenance1 --predicate PREDICATE $repo@$index_digest" \
  "$(sed -E 's/--predicate [^ ]*(vuln|provenance)\.json/--predicate PREDICATE/' "$work/cosign.log")"
same "a release: the provenance attested is the predicate of this run" "$want_push" \
  "$(jq -c . "$work/attested/slsaprovenance1.json")"
same "a release: the vuln predicate is still the scan's" '"0.76.0"' \
  "$(jq -c .scanner.version "$work/attested/vuln.json")"

same "a release on a machine: refused (builder local)" 1 "$(sign run --)"
same "a release on a machine: nothing signed" "" "$(cat "$work/cosign.log")"
grep -qF "the provenance would name builder 'local'" "$work/err" && ok "a release on a machine: the builder is named" ||
  fail "a release on a machine: the builder is named ($(cat "$work/err"))"
same "a release built by another workflow: refused" 1 \
  "$(sign push_run FAKE_CI_BUILDER="${subject/images.yml/ci.yml}" --)"
same "a release built by another workflow: nothing signed" "" "$(cat "$work/cosign.log")"
same "a release whose context cannot make the predicate: refused" 1 "$(sign push_run FAKE_CI_COMMIT= --)"
same "a release whose context cannot make the predicate: nothing signed" "" "$(cat "$work/cosign.log")"

image drill-vulnerable
for how in push_run run; do
  same "the drill image ($how): signed and attested" 0 "$(sign $how -- --allow-critical)"
  same "the drill image ($how): vuln, no provenance" "sign spdxjson spdxjson vuln" \
    "$(sed -E 's/^(sign).*/\1/; s/^attest .*--type ([a-z0-9]+) .*/\1/' "$work/cosign.log" | tr '\n' ' ' | sed 's/ $//')"
done

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
