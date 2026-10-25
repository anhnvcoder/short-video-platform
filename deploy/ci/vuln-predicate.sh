#!/usr/bin/env bash
# vuln-predicate.sh [--allow-critical] OUT DIR DIR: writes to OUT the predicate of the `vuln` attestation of a
# multi-arch index, from the two scans that gated its two
# manifests. Shared by the build (after the gate) and the daily rescan.
#
# Each DIR describes one manifest of the index (what build-image.sh and push-image.sh, or the rescan, wrote):
#   platform       linux/amd64 or linux/arm64 (one DIR each)
#   digest         sha256:<64 hex> of the manifest inside the signed index
#   config-digest  sha256:<64 hex> of its config; must equal Metadata.ImageID of the report
#   trivy.json     the whole trivy report of that scan (after .trivyignore.yaml)
#   scan-started, scan-finished, db-updated-at   RFC 3339 UTC
#
# The contract Kyverno reads (paths from the in-toto statement): predicate.scanner.result.platforms is exactly
# [linux/amd64, linux/arm64] in that order, each {platform, digest, report}; a CRITICAL anywhere in
# predicate.scanner.result.platforms[].report.Results[].Vulnerabilities[].Severity is refused;
# predicate.metadata.scanFinishedOn is when the OLDER of the two scans finished, so the attestation is as old as its
# oldest result; it must be RFC 3339 (cosign parses it into CosignVulnPredicate and fails otherwise).
#
# Exit 0: OUT written. Exit 2: an input breaks the contract (missing or extra platform, bad digest, ImageID that does
# not match, not a trivy report, bad time); nothing written. Exit 3: a report lists CRITICAL; nothing written, unless
# --allow-critical, which writes OUT with the real findings and exits 0 (only for the rescan, which then fails its job
# after attesting, and for the drill image drill-vulnerable).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

bad() {
  echo "FAIL  $1" >&2
  exit 2
}

allow_critical=false
if [ "${1:-}" = --allow-critical ]; then
  allow_critical=true
  shift
fi
[ $# -eq 3 ] || bad "usage: vuln-predicate.sh [--allow-critical] OUT DIR DIR (one DIR per platform)"
out=$1
shift
rfc3339() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

amd64='' arm64=''
for dir in "$@"; do
  [ -d "$dir" ] || bad "$dir is not a directory"
  for f in platform digest config-digest trivy.json scan-started scan-finished db-updated-at; do
    [ -s "$dir/$f" ] || bad "$dir has no $f"
  done
  platform=$(cat "$dir/platform")
  case $platform in
  linux/amd64)
    [ -z "$amd64" ] || bad "linux/amd64 given twice"
    amd64=$dir
    ;;
  linux/arm64)
    [ -z "$arm64" ] || bad "linux/arm64 given twice"
    arm64=$dir
    ;;
  *) bad "$dir: platform '$platform' is neither linux/amd64 nor linux/arm64" ;;
  esac
  is_digest "$(cat "$dir/digest")" || bad "$platform: digest is not sha256:<64 hex>"
  config=$(cat "$dir/config-digest")
  is_digest "$config" || bad "$platform: config digest is not sha256:<64 hex>"
  for f in scan-started scan-finished db-updated-at; do
    rfc3339 "$(cat "$dir/$f")" || bad "$platform: $f is not RFC 3339 UTC (yyyy-mm-ddThh:mm:ssZ)"
  done
  jq -e --arg c "$config" '.SchemaVersion == 2 and .Metadata.ImageID == $c' "$dir/trivy.json" >/dev/null 2>&1 ||
    bad "$platform: trivy.json is not a trivy report of config $config (Metadata.ImageID differs)"
done
if [ -z "$amd64" ] || [ -z "$arm64" ]; then bad "the predicate needs both linux/amd64 and linux/arm64"; fi

version=$(jq -r '.Trivy.Version // empty' "$amd64/trivy.json")
if [ -z "$version" ] || [ "$version" != "$(jq -r '.Trivy.Version // empty' "$arm64/trivy.json")" ]; then
  bad "the two reports come from different or unknown trivy versions"
fi

criticals=$(jq -s '[.[].Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' \
  "$amd64/trivy.json" "$arm64/trivy.json")
if [ "$criticals" -gt 0 ] && [ "$allow_critical" != true ]; then
  echo "FAIL  $criticals CRITICAL vulnerabilities in the reports: no predicate for an image that must not ship" >&2
  exit 3
fi

# The older scan is the one that finished first; its DB is the one the attestation names.
# (Same-form UTC times compare as strings.)
if [[ $(cat "$arm64/scan-finished") < $(cat "$amd64/scan-finished") ]]; then older=$arm64; else older=$amd64; fi
started=$(cat "$amd64/scan-started")
[[ $(cat "$arm64/scan-started") > $started ]] || started=$(cat "$arm64/scan-started")

# Who made it: this attempt of the CI run, its run id and the workflow file at its ref; "local" for each on a machine.
run_url=$(ci_run_attempt_url) && event=$(ci_run_id) && builder=$(ci_builder_id) || exit 1

tmp=$(mktemp "$out.XXXXXX") || fail "create a temporary file beside $out"
trap 'rm -f "$tmp"' EXIT
jq -n \
  --arg uri "$run_url" --arg event "$event" --arg builder "$builder" \
  --arg version "$version" --arg db_uri "$trivy_db_repository" --arg db_version "$(cat "$older/db-updated-at")" \
  --arg started "$started" --arg finished "$(cat "$older/scan-finished")" \
  --arg amd64_digest "$(cat "$amd64/digest")" --slurpfile amd64 "$amd64/trivy.json" \
  --arg arm64_digest "$(cat "$arm64/digest")" --slurpfile arm64 "$arm64/trivy.json" '
  {
    invocation: {uri: $uri, event_id: $event, "builder.id": $builder, parameters: null},
    scanner: {
      uri: "pkg:github/aquasecurity/trivy@v\($version)",
      version: $version,
      db: {uri: $db_uri, version: $db_version},
      result: {platforms: [
        {platform: "linux/amd64", digest: $amd64_digest, report: $amd64[0]},
        {platform: "linux/arm64", digest: $arm64_digest, report: $arm64[0]}
      ]}
    },
    metadata: {scanStartedOn: $started, scanFinishedOn: $finished}
  }' >"$tmp" || fail "write the predicate"
mv "$tmp" "$out"
trap - EXIT
[ "$criticals" -eq 0 ] || echo "note  predicate records $criticals CRITICAL vulnerabilities (--allow-critical)" >&2
echo "ok    vuln predicate written to $out"
