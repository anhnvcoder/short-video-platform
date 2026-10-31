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
#   - sign-image.sh on the drill image drill-vulnerable: signed and vuln attested, no provenance, even on a machine;
#     on drill-no-provenance the same without --allow-critical, which it refuses before anything is signed;
#   - a run of svp-frontend (another release source's repository, running these scripts from a checkout of this one): the
#     predicate names svp-frontend's repository and commit, on CI and on a machine with SVP_CODE_ROOT; its web release is
#     signed with the provenance of svp-frontend; nothing is signed when its builder is the backend's subject, when the image
#     is under the backend's prefix (or the backend's run signs under svp-frontend's), when the image is no service or
#     drill image of svp-frontend's source, or when the run's repository is no source at all;
#   - push-image.sh and merge-index.sh of that run refuse an image svp-frontend does not publish, and a tree whose HEAD is
#     not the run's commit, before docker is called.
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
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
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

subject=https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main
commit=0123456789abcdef0123456789abcdef01234567
# run [NAME=VALUE...] COMMAND...: COMMAND with no variable of this shell but PATH (fakes first), HOME and the fakes'.
run() {
  env -i PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    FAKE_COSIGN_LOG="$work/cosign.log" FAKE_DOCKER_LOG="$work/docker.log" FAKE_INDEX="$work/index.json" \
    FAKE_ATTESTED="$work/attested" "$@"
}
# push_run [NAME=VALUE...] COMMAND...: COMMAND in a made-up push run of images.yml on main.
push_run() {
  run FAKE_CI=1 FAKE_CI_BUILDER="$subject" \
    FAKE_CI_INVOCATION=https://github.com/anhnvcoder/svp-backend/actions/runs/77/attempts/2 \
    FAKE_CI_REPOSITORY=https://github.com/anhnvcoder/svp-backend FAKE_CI_REF=refs/heads/main \
    FAKE_CI_COMMIT=$commit FAKE_CI_WORKFLOW_PATH=.github/workflows/images.yml FAKE_CI_WORKFLOW_REF=refs/heads/main "$@"
}
predicate=$tree/deploy/ci/provenance-predicate.sh
want_push='{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"ref":"refs/heads/main","repository":"https://github.com/anhnvcoder/svp-backend","path":".github/workflows/images.yml"}},"resolvedDependencies":[{"uri":"git+https://github.com/anhnvcoder/svp-backend@refs/heads/main","digest":{"gitCommit":"0123456789abcdef0123456789abcdef01234567"}}]},"runDetails":{"builder":{"id":"https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main"},"metadata":{"invocationId":"https://github.com/anhnvcoder/svp-backend/actions/runs/77/attempts/2"}}}'

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
  "{\"buildDefinition\":{\"buildType\":\"https://actions.github.io/buildtypes/workflow/v1\",\"externalParameters\":{\"workflow\":{\"ref\":\"local\",\"repository\":\"https://github.com/anhnvcoder/svp-backend\",\"path\":\"local\"}},\"resolvedDependencies\":[{\"uri\":\"git+https://github.com/anhnvcoder/svp-backend@local\",\"digest\":{\"gitCommit\":\"$head_commit\"}}]},\"runDetails\":{\"builder\":{\"id\":\"local\"},\"metadata\":{\"invocationId\":\"local\"}}}" \
  "$(jq -c . "$out")"

# --- sign-image.sh, with a fake docker serving the index and a fake cosign. cosign logs one line per call and keeps a
# copy of the predicate of each attestation of the index, by type.
cat >"$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
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
# image NAME [PREFIX]: the index directory merge-index.sh would write for image NAME under PREFIX (the backend's
# when empty).
image() {
  rm -rf "$work/index" && mkdir -p "$work/index"
  echo "${2:-ghcr.io/anhnvcoder/svp-backend/}$1" >"$work/index/repository"
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
repo=ghcr.io/anhnvcoder/svp-backend/gateway

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
image drill-no-provenance
for how in push_run run; do
  same "drill-no-provenance ($how): signed and attested" 0 "$(sign $how --)"
  same "drill-no-provenance ($how): vuln, never provenance" "sign spdxjson spdxjson vuln" \
    "$(sed -E 's/^(sign).*/\1/; s/^attest .*--type ([a-z0-9]+) .*/\1/' "$work/cosign.log" | tr '\n' ' ' | sed 's/ $//')"
done
same "drill-no-provenance with --allow-critical: refused" 1 "$(sign push_run -- --allow-critical)"
same "drill-no-provenance with --allow-critical: nothing signed" "" "$(cat "$work/cosign.log")"

# --- A run of svp-frontend: its own repository, commit and identity; a checkout laid out as svp-frontend, with that origin.
web=$work/web
mkdir -p "$web"
printf 'FROM scratch\n' >"$web/Dockerfile"
printf 'lockfileVersion: 9.0\n' >"$web/pnpm-lock.yaml"
printf 'vulnerabilities: []\n' >"$web/.trivyignore.yaml"
gw() {
  env -i PATH="$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$web" \
    -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
gw init -q && gw add -A && gw commit -qm web
gw remote add origin https://github.com/anhnvcoder/svp-frontend.git
web_commit=$(gw rev-parse HEAD)
web_subject=https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main
# web_run [NAME=VALUE...] COMMAND...: COMMAND in a made-up push run of svp-frontend's images.yml on main, its code in $web.
web_run() {
  run FAKE_CI=1 FAKE_CI_BUILDER="$web_subject" \
    FAKE_CI_INVOCATION=https://github.com/anhnvcoder/svp-frontend/actions/runs/88/attempts/1 \
    FAKE_CI_REPOSITORY=https://github.com/anhnvcoder/svp-frontend FAKE_CI_REF=refs/heads/main \
    FAKE_CI_COMMIT="$web_commit" FAKE_CI_WORKFLOW_PATH=.github/workflows/images.yml \
    FAKE_CI_WORKFLOW_REF=refs/heads/main SVP_CODE_ROOT="$web" "$@"
}
want_web=$(jq -c --arg c "$web_commit" '
  .buildDefinition.externalParameters.workflow.repository = "https://github.com/anhnvcoder/svp-frontend"
  | .buildDefinition.resolvedDependencies[0] = {uri: "git+https://github.com/anhnvcoder/svp-frontend@refs/heads/main",
      digest: {gitCommit: $c}}
  | .runDetails.builder.id = "https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main"
  | .runDetails.metadata.invocationId = "https://github.com/anhnvcoder/svp-frontend/actions/runs/88/attempts/1"' \
  <<<"$want_push")
web_run "$predicate" "$out" >/dev/null
same "svp-frontend's run: the predicate names svp-frontend's repository, ref, commit and builder" "$want_web" "$(jq -c . "$out")"
run SVP_CODE_ROOT="$web" "$predicate" "$out" >/dev/null
same "svp-frontend on a machine (SVP_CODE_ROOT): svp-frontend's repository and the HEAD of its checkout" \
  "https://github.com/anhnvcoder/svp-frontend $web_commit" \
  "$(jq -r '"\(.buildDefinition.externalParameters.workflow.repository) \(.buildDefinition.resolvedDependencies[0].digest.gitCommit)"' "$out")"

image web ghcr.io/anhnvcoder/svp-frontend/
same "svp-frontend's web release: signed and attested" 0 "$(sign web_run --)"
same "svp-frontend's web release: sign, SBOMs, vuln, provenance" "sign spdxjson spdxjson vuln slsaprovenance1" \
  "$(sed -E 's/^(sign).*/\1/; s/^attest .*--type ([a-z0-9]+) .*/\1/' "$work/cosign.log" | tr '\n' ' ' | sed 's/ $//')"
same "svp-frontend's web release: the provenance attested is svp-frontend's" "$want_web" \
  "$(jq -c . "$work/attested/slsaprovenance1.json")"
same "svp-frontend's run with the backend's builder.id: refused" 1 "$(sign web_run FAKE_CI_BUILDER="$subject" --)"
same "svp-frontend's run with the backend's builder.id: nothing signed" "" "$(cat "$work/cosign.log")"
grep -qF "releases of source web are signed only as $web_subject" "$work/err" &&
  ok "svp-frontend's run with the backend's builder.id: names the source's subject" ||
  fail "svp-frontend's run with the backend's builder.id: names the source's subject ($(cat "$work/err"))"
same "the backend's run, its builder, on svp-frontend's image: refused" 1 "$(sign push_run --)"
same "the backend's run on svp-frontend's image: nothing signed" "" "$(cat "$work/cosign.log")"
grep -qF "ghcr.io/anhnvcoder/svp-frontend/web is not under ghcr.io/anhnvcoder/svp-backend/" "$work/err" &&
  ok "the backend's run on svp-frontend's image: names the prefix" ||
  fail "the backend's run on svp-frontend's image: names the prefix ($(cat "$work/err"))"

image web
same "svp-frontend's run on the backend's web: refused" 1 "$(sign web_run --)"
same "svp-frontend's run on the backend's web: nothing signed" "" "$(cat "$work/cosign.log")"
grep -qF "is not under ghcr.io/anhnvcoder/svp-frontend/, the prefix of release source web" "$work/err" &&
  ok "svp-frontend's run on the backend's web: names svp-frontend's prefix" ||
  fail "svp-frontend's run on the backend's web: names svp-frontend's prefix ($(cat "$work/err"))"
image gateway ghcr.io/anhnvcoder/svp-frontend/
same "svp-frontend's run on a gateway under its prefix: refused" 1 "$(sign web_run --)"
grep -qF "gateway is not an image of release source web (web)" "$work/err" &&
  ok "svp-frontend's run on a gateway under its prefix: names what it publishes" ||
  fail "svp-frontend's run on a gateway under its prefix: names what it publishes ($(cat "$work/err"))"
image drill-vulnerable ghcr.io/anhnvcoder/svp-frontend/
same "svp-frontend's run on a drill image under its prefix: refused" 1 "$(sign web_run -- --allow-critical)"
same "svp-frontend's run on a drill image under its prefix: nothing signed" "" "$(cat "$work/cosign.log")"
image web ghcr.io/anhnvcoder/svp-frontend/
same "a run of a repository no release source names: refused" 1 \
  "$(sign web_run FAKE_CI_REPOSITORY=https://github.com/octo/repo --)"
grep -qF "this run is of https://github.com/octo/repo, which is the repository of 0 release sources" "$work/err" &&
  ok "a run of a repository no release source names: says so" ||
  fail "a run of a repository no release source names: says so ($(cat "$work/err"))"

# push-image.sh and merge-index.sh of svp-frontend's run: an image it does not publish, or a tree that is not the run's
# commit, is refused before docker is called.
# refused_early NAME WANT_MESSAGE COMMAND...: COMMAND exits 1 naming WANT_MESSAGE, docker never called.
refused_early() {
  local name=$1 want=$2 rc=0
  shift 2
  : >"$work/docker.log"
  "$@" >/dev/null 2>"$work/err" || rc=$?
  if [ "$rc" = 1 ] && grep -qF -- "$want" "$work/err" && [ ! -s "$work/docker.log" ]; then
    ok "$name: refused before docker"
  else
    fail "$name: refused before docker (exit $rc; $(cat "$work/err"); docker: $(cat "$work/docker.log"))"
  fi
}
mkdir -p "$work/leg-out"
refused_early "push-image.sh of svp-frontend's run, image gateway" "gateway is not an image of release source web" \
  web_run "$tree/deploy/ci/push-image.sh" gateway amd64 "$work/leg-out"
refused_early "merge-index.sh of svp-frontend's run, image gateway" "gateway is not an image of release source web" \
  web_run "$tree/deploy/ci/merge-index.sh" gateway "$work/leg-amd64" "$work/leg-arm64" "$work/index-out"
refused_early "push-image.sh of svp-frontend's run, a tree at another commit" \
  "HEAD of $web is $web_commit, but this run builds $commit of https://github.com/anhnvcoder/svp-frontend" \
  web_run FAKE_CI_COMMIT="$commit" "$tree/deploy/ci/push-image.sh" web amd64 "$work/leg-out"
refused_early "merge-index.sh of svp-frontend's run without SVP_CODE_ROOT (the backend's checkout)" \
  "HEAD of $tree is $head_commit, but this run builds $web_commit" \
  web_run SVP_CODE_ROOT= "$tree/deploy/ci/merge-index.sh" web "$work/leg-amd64" "$work/leg-arm64" "$work/index-out"
refused_early "build-image.sh of svp-frontend's run, a tree without its .trivyignore.yaml" \
  "$web has no file .trivyignore.yaml" \
  web_run FAKE_CI_COMMIT="$web_commit" bash -c 'mv "$1/.trivyignore.yaml" "$1/.away" &&
    { "$2" web amd64 "$3"; rc=$?; mv "$1/.away" "$1/.trivyignore.yaml"; exit $rc; }' _ "$web" \
  "$tree/deploy/ci/build-image.sh" "$work/leg-out"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
