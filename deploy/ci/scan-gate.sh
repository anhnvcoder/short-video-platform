#!/usr/bin/env bash
# scan-gate.sh [--allow-critical] LABEL REPORT: the gate between scanning an image and pushing or attesting it
# (docs/adr/0015-cicd-devsecops-stage5.md, section 6). REPORT is the JSON of `trivy image --scanners vuln,secret` run
# with every severity and .trivyignore.yaml; LABEL names the image in the output (for example gateway linux/arm64).
# scan-gate.sh --check-ignorefile: checks only the rules of .trivyignore.yaml (below), with no image and no report. Job
# config of ci.yml runs it on every pull request and push: a pull request that changes nothing but .trivyignore.yaml
# builds no image, so without it a broken entry would reach main unchecked, then stop the daily rescan from attesting
# any service, and 72 hours later Kyverno would refuse new pods.
#
# Blocks (exit 1) on:
#   - any secret, whatever its severity: a public package and its signature cannot be taken back, so a secret pushed
#     once is leaked for good. There is no way around it: .trivyignore.yaml may hold only vulnerabilities, and no
#     --skip-files, --skip-dirs or --secret-config is ever passed to trivy.
#   - any CRITICAL vulnerability left after .trivyignore.yaml, fixed upstream or not. --allow-critical lets CRITICAL
#     through (only for the drill image drill-vulnerable and for the daily rescan, which records the real result); it
#     never lets a secret through.
# HIGH and below are only reported: counts in the job summary, details in the SARIF.
# Also blocks when .trivyignore.yaml breaks its rules (below). Exit 2: REPORT is not a trivy report.
#
# Prints counts and, for findings that block, rule or vulnerability ID, package or file, line: never the matched
# text (trivy masks secrets in its findings anyway; the raw report is never printed).
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

allow_critical=false
check_only=false
if [ "${1:-}" = --check-ignorefile ]; then
  [ $# -eq 1 ] || fail "usage: scan-gate.sh --check-ignorefile"
  check_only=true
elif [ "${1:-}" = --allow-critical ]; then
  allow_critical=true
  shift
fi
[ "$check_only" = true ] || [ $# -eq 2 ] || fail "usage: scan-gate.sh [--allow-critical] LABEL REPORT"
label=${1:-} report=${2:-}

# check_ignorefile: .trivyignore.yaml, when present, may only list vulnerabilities (the format also has secrets,
# misconfigurations and licenses sections, and trivy would apply them), each with an id, a statement giving the reason
# and an expired_at (yyyy-mm-dd) at most 30 days after today (UTC), so no exception lives longer than 30 days without
# another reviewed change. Read line by line in the shape below; anything else is refused rather than guessed:
#   vulnerabilities:
#     - id: CVE-2026-12345
#       statement: why this cannot be fixed by a newer base yet
#       expired_at: 2026-11-19
#       purls:
#         - pkg:apk/alpine/ffmpeg
check_ignorefile() {
  [ -f "$trivyignore" ] || return 0
  local limit
  limit=$(date -u -d '+30 days' +%F 2>/dev/null || date -u -v+30d +%F)
  awk -v limit="$limit" '
    function bad_at(line, msg) { printf "FAIL  .trivyignore.yaml:%d: %s\n", line, msg; failed = 1 }
    function bad(msg) { bad_at(NR, msg) }
    function close_item() {
      if (!item) return
      if (statement == "") bad_at(start, "entry " id " has no statement (the reason it is ignored)")
      if (expired !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        bad_at(start, "entry " id " has no expired_at yyyy-mm-dd")
      else if (expired > limit)
        bad_at(start, "entry " id " expires " expired ", more than 30 days from today (" limit ")")
    }
    /^[ ]*(#.*)?$/ { next }
    /^vulnerabilities:[ ]*$/ { if (root++) bad("vulnerabilities: twice"); next }
    /^[^ ]/ { bad("only vulnerabilities may be ignored, never secrets or anything else: " $0); next }
    !root { bad("entry outside vulnerabilities:"); next }
    /^  - id:[ ]*[^ ]/ {
      close_item()
      item = 1; start = NR; statement = ""; expired = ""; list = 0
      id = $0; sub(/^  - id:[ ]*/, "", id)
      next
    }
    /^    statement:[ ]*[^ ]/ { list = 0; statement = $0; next }
    /^    expired_at:/ {
      list = 0; expired = $0; sub(/^    expired_at:[ ]*/, "", expired); gsub(/"/, "", expired); next
    }
    /^    (purls|paths):[ ]*$/ { list = 1; next }
    /^      - [^ ]/ { if (!list) bad("list item outside purls: or paths:"); next }
    { bad("unexpected line (only id, statement, expired_at, purls, paths): " $0) }
    END { close_item(); exit failed }' "$trivyignore"
}

if [ "$check_only" = true ]; then
  check_ignorefile || fail ".trivyignore.yaml breaks its rules"
  echo "ok    .trivyignore.yaml keeps its rules"
  exit 0
fi

jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 ||
  {
    echo "FAIL  $label: $report is not a trivy JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
    exit 2
  }

blocked=0
if ! check_ignorefile; then
  echo "FAIL  .trivyignore.yaml breaks its rules: fix it before anything is pushed" >&2
  blocked=1
fi

counts=$(jq -r '
  [.Results[]?.Vulnerabilities[]?.Severity] as $s
  | [("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN") as $l | [$s[] | select(. == $l)] | length]
  + [[.Results[]?.Secrets[]?] | length]
  | @tsv' "$report")
read -r critical high medium low unknown secrets <<<"$counts"

summary "| Image | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN | Secrets |" \
  "| --- | --- | --- | --- | --- | --- | --- |" \
  "| $label | $critical | $high | $medium | $low | $unknown | $secrets |" ""
[ -z "${GITHUB_STEP_SUMMARY:-}" ] ||
  echo "$label: CRITICAL $critical, HIGH $high, MEDIUM $medium, LOW $low, UNKNOWN $unknown, secrets $secrets"

if [ "$secrets" -gt 0 ]; then
  echo "FAIL  $label: $secrets secret(s) found in the image; nothing is pushed, signed or attested" >&2
  # Rule, file and line only: the matched text stays out of logs and summaries of a public repository.
  jq -r '.Results[]? | .Target as $t | .Secrets[]? | "secret  \(.RuleID) (\(.Severity)) in \($t) line \(.StartLine)"' \
    "$report" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >&2
  blocked=1
fi
if [ "$critical" -gt 0 ]; then
  jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity == "CRITICAL")
    | "critical  \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) (fixed: \(.FixedVersion // "none")) in \($t)"' \
    "$report" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >&2
  if [ "$allow_critical" = true ]; then
    echo "note  $label: $critical CRITICAL vulnerabilities let through (--allow-critical)" >&2
  else
    echo "FAIL  $label: $critical CRITICAL vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
fi
[ "$blocked" -eq 0 ] && echo "ok    $label passes the scan gate"
exit "$blocked"
