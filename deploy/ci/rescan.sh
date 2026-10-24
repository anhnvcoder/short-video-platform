#!/usr/bin/env bash
# rescan.sh: the daily rescan of released images (docs/adr/0015-cicd-devsecops-stage5.md, section 7). A release was
# clean when it was built; new vulnerabilities are published every day, and Kyverno accepts a vuln attestation for
# 72 hours only, so every released digest is scanned again with the newest DB and its attestation replaced.
#
#   rescan.sh scan-index REPOSITORY DIGEST OUT
#     Reads the index REPOSITORY@DIGEST from the registry, finds its two manifests (linux/amd64, linux/arm64) and scans
#     EACH from the registry with the gate's flags (trivy reads one platform per scan, so scanning the index would
#     prove nothing about arm64). Writes OUT/amd64 and OUT/arm64 in the layout vuln-predicate.sh reads and prints the
#     two manifest digests.
#
#   rescan.sh run OUT MAIN_REF [REF...]   (CI only: it attests)
#     For image.repository + image.digest of the seven files deploy/k8s/values/services/*.yaml at each git REF (MAIN_REF
#     is main's; others are the open promote PR and the dispatch input values_ref), read as data with `git show`, never
#     run: an empty digest is skipped; a repository other than ghcr.io/anhnvcoder/short-video-platform/<service>, a
#     malformed digest, or a digest without a signature of images.yml on main is not attested and fails the run, so
#     whatever a REF lists, only digests this workflow signed on main get a fresh attestation. Each digest left is
#     scanned (scan-index), its predicate built by vuln-predicate.sh --allow-critical and attested with
#     `cosign attest --replace --type vuln`, so the attestation always holds the real result: a CRITICAL found today is
#     recorded (Kyverno then refuses new pods because of it, not because of an old attestation) and fails the run, which
#     mails the owner. A secret found today is never attested: it fails the run before anything is written, as at build
#     time. SARIF of the digests of MAIN_REF go to OUT/sarif for the Security tab. The drill images are in no values
#     file, so they are never rescanned.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

# scan_index REPOSITORY DIGEST OUT: see scan-index above.
scan_index() {
  local repo=$1 digest=$2 out=$3 index arch child dir args a
  mkdir -p "$out" || fail "create $out"
  index=$out/index.json
  [ "$(fetch_manifest "$repo@$digest" "$index")" = "$digest" ] || fail "read the index $repo@$digest, byte for byte"
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(trivy_scan_args)
  trivy_mounts=(-v "$out:/out")
  [ -f "$trivyignore" ] && trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
  for arch in amd64 arm64; do
    child=$(jq -r --arg a "$arch" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a)]
      | if length == 1 then .[0].digest else empty end' "$index")
    is_digest "$child" || fail "$repo@$digest has no single linux/$arch manifest"
    dir=$out/$arch
    mkdir -p "$dir"
    echo "linux/$arch" >"$dir/platform"
    echo "$child" >"$dir/digest"
    [ "$(fetch_manifest "$repo@$child" "$dir/manifest.json")" = "$child" ] || fail "read $repo@$child, byte for byte"
    jq -r .config.digest "$dir/manifest.json" >"$dir/config-digest"
    now_utc >"$dir/scan-started"
    # A DB that cannot be downloaded fails the scan: never an attestation from a DB of unknown age.
    trivy_ image --image-src remote "${args[@]}" --output "/out/$arch/trivy.json" "$repo@$child" ||
      fail "scan $repo@$child"
    now_utc >"$dir/scan-finished"
    trivy_db_updated_at >"$dir/db-updated-at"
    echo "scanned linux/$arch $child"
  done
}

# release_of REF SERVICE: prints "repository digest" of SERVICE's values file at REF; nothing when not released.
release_of() {
  local file=deploy/k8s/values/services/$2.yaml values repo digest
  values=$(git -C "$repo_root" show "$1:$file") || fail "read $file at $1"
  digest=$(values_field digest <<<"$values") || fail "$file at $1: image.digest is not one plain line"
  repo=$(values_field repository <<<"$values") || fail "$file at $1: image.repository is not one plain line"
  [ -z "$digest" ] || echo "$repo $digest"
}

# rescan_one SERVICE REPOSITORY DIGEST DIR SARIF_DIR: scans, gates secrets, attests, then fails on CRITICAL for one
# release; SARIF_DIR empty for a digest that is not main's. Run in a subshell, so a failure (fail exits) stops this
# digest only.
rescan_one() {
  local svc=$1 repo=$2 digest=$3 dir=$4 sarif=$5 arch blocked=0 critical
  verify_signature "$repo" "$digest" || fail "$repo@$digest has no signature of images.yml on main; not attested"
  echo "rescan $repo@$digest"
  scan_index "$repo" "$digest" "$dir"
  # The gate runs before anything is written, with --allow-critical: the rescan's exception covers CRITICAL only. A
  # secret (or a broken .trivyignore.yaml) blocks as at build time: the attestation is public and Rekor keeps its whole
  # envelope for good, so the report's secret findings would be published with it. The old attestation then ages out
  # and Kyverno refuses new pods after 72 hours; the red run mails the owner now.
  for arch in amd64 arm64; do
    "$ci_dir/scan-gate.sh" --allow-critical "$svc linux/$arch (rescan)" "$dir/$arch/trivy.json" || blocked=1
    [ -n "$sarif" ] || continue
    trivy_mounts=(-v "$dir/$arch:/in:ro" -v "$sarif:/out")
    trivy_ convert --format sarif --severity HIGH,CRITICAL --output "/out/$svc-$arch.sarif.tmp" /in/trivy.json ||
      fail "convert the report of $svc linux/$arch to SARIF"
    jq --arg c "trivy-image-$svc-$arch/" '.runs[].automationDetails.id = $c' "$sarif/$svc-$arch.sarif.tmp" \
      >"$sarif/$svc-$arch.sarif"
    rm -f "$sarif/$svc-$arch.sarif.tmp"
  done
  [ "$blocked" -eq 0 ] || fail "$repo@$digest is blocked by the scan gate; not attested"
  "$ci_dir/vuln-predicate.sh" --allow-critical "$dir/predicate.json" "$dir/amd64" "$dir/arm64" ||
    fail "build the vuln predicate of $repo@$digest"
  cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type vuln \
    --predicate "$dir/predicate.json" "$repo@$digest" || fail "attest $repo@$digest"
  echo "ok    $repo@$digest attested with today's scan"
  # A CRITICAL is now recorded (Kyverno refuses new pods because of it, not because of an old attestation) and fails
  # the run.
  critical=$(jq -s '[.[].Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' \
    "$dir/amd64/trivy.json" "$dir/arm64/trivy.json") || fail "count CRITICAL of $repo@$digest"
  [ "$critical" -eq 0 ] || fail "$repo@$digest: $critical CRITICAL vulnerabilities, recorded in its vuln attestation"
}

run() {
  local platform
  platform=$(ci_platform) || exit 1
  [ "$platform" != local ] || fail "rescan.sh run attests with the workflow's identity: CI only"
  [ $# -ge 2 ] || fail "usage: rescan.sh run OUT MAIN_REF [REF...]"
  local out=$1 main_ref=$2 ref svc line repo digest key sarif n=0 failed=0 seen=" "
  shift
  mkdir -p "$out/sarif" || fail "create $out"
  out=$(cd "$out" && pwd)
  for ref in "$@"; do
    for svc in "${svp_services[@]}"; do
      if ! line=$(release_of "$ref" "$svc"); then
        failed=1
        continue
      fi
      if [ -z "$line" ]; then
        ci_summary "- $svc at \`$ref\`: no digest, not released yet: skipped"
        continue
      fi
      read -r repo digest <<<"$line"
      key="$svc@$digest"
      case $seen in *" $key "*) continue ;; esac
      seen="$seen$key "
      n=$((n + 1))
      if [ "$repo" != "$ghcr_prefix/$svc" ] || ! is_digest "$digest"; then
        echo "FAIL  $svc at $ref: $repo@$digest is not a release of $ghcr_prefix/$svc; not attested" >&2
        failed=1
        continue
      fi
      sarif=
      [ "$ref" != "$main_ref" ] || sarif=$out/sarif
      (rescan_one "$svc" "$repo" "$digest" "$out/$n-$svc" "$sarif") || failed=1
    done
  done
  [ "$n" -gt 0 ] || ci_summary "No released digest to rescan."
  return "$failed"
}

case ${1:-} in
scan-index)
  [ $# -eq 4 ] || fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT"
  is_digest "$3" || fail "$3 is not sha256:<64 hex>"
  scan_index "$2" "$3" "$4"
  ;;
run)
  shift
  run "$@"
  ;;
*) fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT | rescan.sh run OUT MAIN_REF [REF...]" ;;
esac
