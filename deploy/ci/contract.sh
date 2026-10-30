#!/usr/bin/env bash
# The REST contract of the gateway, services/gateway/openapi.yaml, as a versioned release: the web client builds its
# types from a published, signed version of it, not from a file of this repository. Two commands:
#
#   contract.sh check BASE
#       The check of a pull request (make api-contract-check, job api-contract of ci.yml). Compares the spec of the
#       working tree with the spec at commit BASE, by bytes and with oasdiff (OASDIFF_IMAGE of the Makefile, no
#       network, external $refs refused), and fails when the version rule written at the top of the spec is broken:
#         - info.version of either side is not MAJOR.MINOR.PATCH;
#         - the file changed and info.version is not greater than at BASE;
#         - oasdiff finds a breaking change while the major stays (from 1.0.0 on; below it every change may break,
#           as semver allows) or the version went down: its checks api-version-not-bumped,
#           api-major-version-not-bumped and api-version-decreased, raised from INFO to ERR here;
#         - the changelog of oasdiff is not empty (an operation, a field, an enum value...) and only PATCH went up.
#       BASE all zeros (a push that created the branch), or a BASE without the spec: nothing to compare, a line in the
#       job summary and exit 0. The changelog goes to the log and the job summary.
#
#   contract.sh publish [--dry-run]
#       The release, on main only. Pushes the spec as an OCI artifact (ORAS_IMAGE of the Makefile) to
#       <ghcr_prefix>/api/gateway:<info.version>, then signs that digest keyless with cosign in the same older format
#       as the images (the identity of release source backend in files/sources.json of chart svp-policy, read by
#       sign_identity of common.sh, the one Kyverno and every verifier read). A version is never published twice: a
#       tag that already holds this very file (same layer digest) is left as it is, only signed if its signature is
#       missing; a tag holding anything else fails and nothing is written (the next version has to be published
#       instead). Before anything is pushed, the run must be one that signs as that identity (ci_builder_id), so a
#       run of another workflow, a branch or a machine never pushes a version it cannot sign. --dry-run reads the
#       registry without credentials and only says what it would do. Needs `docker login` to the registry and the
#       id-token of the job (cosign on PATH) when not a dry run.
#       Two runs must not publish at once: the check above and the push are two requests, so the workflow runs them
#       one after the other (a concurrency group that never cancels on main).
#
# Written for bash 3.2 too (macOS).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

spec_path=services/gateway/openapi.yaml
spec=$repo_root/$spec_path
contract_repository=$ghcr_prefix/api/gateway
# What a client asks the registry for. The layer's type is the one registered for OpenAPI documents (YAML or JSON).
contract_artifact_type=application/vnd.anhnvcoder.svp.api-contract.v1
contract_media_type=application/vnd.oai.openapi
# oasdiff's own version checks, INFO by default (they never fail anything on their own).
version_checks=(api-version-not-bumped api-major-version-not-bumped api-version-decreased)

work=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$work"' EXIT

# spec_version FILE: prints info.version of the OpenAPI document FILE, the line `  version: X.Y.Z` of its top-level
# info block; fails unless that is a plain MAJOR.MINOR.PATCH without leading zeros (no pre-release, no quotes).
spec_version() {
  local v
  v=$(awk '
    /^info:[[:space:]]*$/ { block = 1; next }
    block && /^[^[:space:]#]/ { exit }
    block && /^  version:/ { sub(/^  version:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$1")
  [[ $v =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo "FAIL  info.version of $2 is '$v', not MAJOR.MINOR.PATCH" >&2
    return 1
  }
  echo "$v"
}

# bump OLD NEW: prints major, minor or patch, the highest part that went up from OLD to NEW, or none when NEW is not
# greater than OLD.
bump() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  if [ "$b1" -ne "$a1" ]; then
    if [ "$b1" -gt "$a1" ]; then echo major; else echo none; fi
  elif [ "$b2" -ne "$a2" ]; then
    if [ "$b2" -gt "$a2" ]; then echo minor; else echo none; fi
  elif [ "$b3" -gt "$a3" ]; then
    echo patch
  else
    echo none
  fi
}

# oasdiff_ ARGS...: the pinned oasdiff, as the calling user, without network, seeing only $work as /specs.
oasdiff_() {
  local image
  image=$(tool_image OASDIFF_IMAGE) || return 1
  docker_ run --rm --network none --user "$(id -u):$(id -g)" -v "$work:/specs:ro" "$image" "$@"
}

check() {
  local base=$1 base_v head_v level changelog counts checks problems=() n_err n_warn n_info entries line
  if [ -z "${base//0/}" ]; then
    ci_summary_tee <<<"API contract: not compared, there is no base commit (the push created the branch)."
    return 0
  fi
  base=$(git -C "$repo_root" rev-parse --quiet --verify "$base^{commit}") || fail "$1 is not a commit of this clone"
  if ! git -C "$repo_root" cat-file -e "$base:$spec_path" 2>/dev/null; then
    ci_summary_tee <<<"API contract: not compared, ${base:0:12} has no $spec_path."
    return 0
  fi
  git -C "$repo_root" show "$base:$spec_path" >"$work/base.yaml" || fail "read $spec_path at $base"
  cp "$spec" "$work/head.yaml" || fail "read $spec_path"
  if cmp -s "$work/base.yaml" "$work/head.yaml"; then
    ci_summary_tee <<<"API contract: $spec_path is the same as at ${base:0:12}."
    return 0
  fi
  base_v=$(spec_version "$work/base.yaml" "$spec_path at ${base:0:12}") || return 1
  head_v=$(spec_version "$work/head.yaml" "$spec_path") || return 1
  level=$(bump "$base_v" "$head_v")

  printf '%s err\n' "${version_checks[@]}" >"$work/severity.txt"
  oasdiff_ changelog /specs/base.yaml /specs/head.yaml --format json --allow-external-refs=false \
    --severity-levels /specs/severity.txt >"$work/changelog.json" || fail "oasdiff could not compare the two specs"
  changelog=$(jq -r '.[] | "\(["", "INFO", "WARN", "ERR"][.level] // .level) \(.id)" +
    (if .operation then " \(.operation) \(.path)" elif .path then " \(.path)" else "" end) + ": \(.text)"' \
    "$work/changelog.json") || fail "read the changelog of oasdiff"
  # Counted without the version checks: they say what the version should be, not what changed.
  checks=$(printf '%s\n' "${version_checks[@]}" | jq -R . | jq -sc .)
  counts=$(jq -r --argjson checks "$checks" '[.[] | select(.id as $id | $checks | index($id) | not)] as $c
    | [($c | length), ([$c[] | select(.level == 3)] | length), ([$c[] | select(.level == 2)] | length),
      ([$c[] | select(.level == 1)] | length)] | join(" ")' "$work/changelog.json") ||
    fail "read the changelog of oasdiff"
  read -r entries n_err n_warn n_info <<<"$counts"

  [ "$level" != none ] || problems+=("$spec_path changed but info.version $head_v is not greater than $base_v at ${base:0:12}")
  while IFS= read -r line; do
    [ -n "$line" ] && problems+=("$line")
  done < <(jq -r --argjson checks "$checks" '.[] | select(.id as $id | $checks | index($id)) | "\(.id): \(.text)"' \
    "$work/changelog.json")
  if [ "$entries" -gt 0 ] && [ "$level" = patch ]; then
    problems+=("the changelog has $entries entries, so the minor (or the major) must go up, not only the patch")
  fi

  {
    echo "API contract: $spec_path changed since ${base:0:12}, info.version $base_v -> $head_v ($level)."
    echo "Changelog: $entries entries ($n_err breaking, $n_warn warnings, $n_info info)."
    [ -z "$changelog" ] || printf '    %s\n' "$changelog"
  } | ci_summary_tee
  if [ ${#problems[@]} -gt 0 ]; then
    printf 'FAIL  %s\n' "${problems[@]}" | ci_summary_tee >&2
    return 1
  fi
  echo "ok    the version rule holds" | ci_summary_tee
}

# oras_ [--auth] ARGS...: the pinned ORAS, as the calling user, seeing $work as its working directory. With --auth it
# also reads the credentials docker login wrote (only the file, read-only; a credential helper of the machine is not
# reachable from the container, so a dry run reads anonymously).
oras_() {
  local image auth=() config
  image=$(tool_image ORAS_IMAGE) || return 1
  if [ "$1" = --auth ]; then
    shift
    config=${DOCKER_CONFIG:-$HOME/.docker}/config.json
    [ -f "$config" ] || fail "no $config: docker login to the registry first"
    auth=(-v "$config:/auth/config.json:ro")
    set -- "$@" --registry-config /auth/config.json
  fi
  docker_ run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp ${auth[@]+"${auth[@]}"} -v "$work:/work" -w /work \
    "$image" "$@"
}

# published AUTH REF: writes to $work/manifest.json the manifest REF names and prints its digest; prints nothing when
# REF does not exist. GHCR answers "not found" for a tag missing from a package, and "denied" for a package that does
# not exist yet (or is private and read without credentials). A denied read can only be taken as "absent" because the
# push after it needs write access, which includes read: with credentials that can read, a denied answer means no
# package. Any other error fails, so a registry out of reach is never taken for a version not yet published.
published() {
  local err rc=0 flag=()
  [ "$1" = true ] && flag=(--auth)
  err=$(oras_ ${flag[@]+"${flag[@]}"} manifest fetch "$2" 2>&1 >"$work/manifest.json") || rc=$?
  if [ "$rc" -ne 0 ]; then
    case $err in
    *": not found"* | *"denied: requested access to the resource is denied"*) return 0 ;;
    esac
    printf '%s\n' "$err" | tail -n 1 >&2
    fail "read $2 from the registry"
  fi
  echo "sha256:$(shasum -a 256 "$work/manifest.json" | cut -d' ' -f1)"
}

# layer_of: prints the digest of the one layer of $work/manifest.json when it is a contract release (its artifact
# type, one layer of the OpenAPI type); fails naming what else it is.
layer_of() {
  jq -re --arg type "$contract_artifact_type" --arg media "$contract_media_type" '
    select(.artifactType == $type and (.layers | length) == 1 and .layers[0].mediaType == $media)
    | .layers[0].digest' "$work/manifest.json" 2>/dev/null
}

publish() {
  local dry=false version ref want digest layer builder
  if [ "${1:-}" = --dry-run ]; then
    dry=true
    shift
  fi
  [ $# -eq 0 ] || fail "usage: contract.sh publish [--dry-run]"
  version=$(spec_version "$spec" "$spec_path") || exit 1
  ref=$contract_repository:$version
  cp "$spec" "$work/openapi.yaml" || fail "read $spec_path"
  want=sha256:$(shasum -a 256 "$work/openapi.yaml" | cut -d' ' -f1)
  sign_identity
  if [ "$dry" = false ]; then
    builder=$(ci_builder_id) || fail "read the workflow of this run"
    [ "$builder" = "$sign_subject" ] ||
      fail "this run is $builder, but a contract is published only by $sign_subject (it signs as that identity)"
  fi

  digest=$(published "$([ "$dry" = true ] && echo false || echo true)" "$ref")
  if [ -n "$digest" ]; then
    layer=$(layer_of) || fail "$ref already exists and is not a contract release: publish another version"
    [ "$layer" = "$want" ] ||
      fail "$ref is already published with other content ($layer, this tree $want): raise info.version, a version is never published twice"
    if verify_signature "$contract_repository" "$digest" 2>/dev/null; then
      echo "ok    $ref is already published with this content and signed ($digest): nothing to do" | ci_summary_tee
      return 0
    fi
    if [ "$dry" = true ]; then
      echo "dry run: $ref holds this content ($digest) but no signature of $sign_subject: would sign it" | ci_summary_tee
      return 0
    fi
    echo "note  $ref holds this content ($digest) without a signature: signing it" >&2
  else
    if [ "$dry" = true ]; then
      echo "dry run: $ref is not published: would push $spec_path ($want) and sign it" | ci_summary_tee
      return 0
    fi
    oras_ --auth push "$ref" --artifact-type "$contract_artifact_type" \
      --annotation "org.opencontainers.image.source=$(ci_repo_url)" \
      --annotation "org.opencontainers.image.revision=$(ci_commit)" \
      --annotation "org.opencontainers.image.version=$version" \
      "openapi.yaml:$contract_media_type" >/dev/null || fail "push $ref"
    digest=$(published true "$ref")
    [ -n "$digest" ] && layer=$(layer_of) && [ "$layer" = "$want" ] ||
      fail "$ref read back after the push is not this spec"
  fi
  cosign_ sign --yes --new-bundle-format=false --use-signing-config=false "$contract_repository@$digest" ||
    fail "sign $contract_repository@$digest"
  verify_signature "$contract_repository" "$digest" || fail "the signature of $contract_repository@$digest does not verify"
  echo "ok    $ref published and signed: $contract_repository@$digest" | ci_summary_tee
}

case ${1:-} in
check)
  [ $# -eq 2 ] || fail "usage: contract.sh check BASE"
  check "$2"
  ;;
publish)
  shift
  publish "$@"
  ;;
*) fail "usage: contract.sh check BASE | publish [--dry-run]" ;;
esac
