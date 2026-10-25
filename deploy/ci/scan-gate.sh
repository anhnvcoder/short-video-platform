#!/usr/bin/env bash
# scan-gate.sh [--allow-critical] LABEL REPORT: the gate between scanning an image and pushing or attesting it.
# REPORT is the JSON of `trivy image --scanners vuln,secret` run
# with every severity and .trivyignore.yaml; LABEL names the image in the output (for example gateway linux/arm64).
# scan-gate.sh --fs LABEL REPORT: the same rules for the JSON of `trivy fs` on a lockfile (make web-lockfile-scan): the
# web image shows trivy only the few npm packages left in its node_modules, since the bundler folds the server's
# dependencies into its chunks, so the lockfile is where every npm package and its version can still be seen. A
# blocked lockfile fails the check that ran it; there is no push to stop.
# scan-gate.sh --check-ignorefile: checks only the rules of .trivyignore.yaml (below), with no image and no report, and
# those of deploy/ci/trivy-config-ignore.yaml, the misconfigurations make trivy-config leaves out.
# Job config of ci.yml runs it on every pull request and
# push: a pull request that changes nothing but .trivyignore.yaml builds no image, so without it a broken entry would
# reach main unchecked, then stop the daily rescan from attesting any service, and 72 hours later Kyverno would refuse
# new pods. The image gate reads only .trivyignore.yaml: trivy-config-ignore.yaml never reaches it.
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
config_ignore=$ci_dir/trivy-config-ignore.yaml

allow_critical=false
check_only=false
artifact=image
if [ "${1:-}" = --check-ignorefile ]; then
  [ $# -eq 1 ] || fail "usage: scan-gate.sh --check-ignorefile"
  check_only=true
elif [ "${1:-}" = --allow-critical ]; then
  allow_critical=true
  shift
elif [ "${1:-}" = --fs ]; then
  artifact=fs
  shift
fi
[ "$check_only" = true ] || [ $# -eq 2 ] || fail "usage: scan-gate.sh [--allow-critical | --fs] LABEL REPORT"
label=${1:-} report=${2:-}

# statement_awk: the awk function both checks below read a statement line with (sq is the single quote, passed with -v).
# read_statement(LINE) sets statement to the reason the line gives, as trivy's YAML parser reads it: plain text up to
# a " #" comment, or the text in one pair of quotes. A value YAML reads as empty (nothing, null, ~, "" or '', blanks,
# a lone comment) leaves statement empty, so the entry fails as having no reason. It returns 0 for a value it does not
# read, refused rather than guessed: an escape in quotes, or plain text that does not start with a letter or digit (a
# tag, an alias, a flow or block value).
statement_awk='
  function read_statement(line,   v, q, end, rest) {
    statement = ""
    v = line; sub(/^ *statement:[ ]*/, "", v)
    q = substr(v, 1, 1)
    if (q == "\"" || q == sq) {
      end = index(substr(v, 2), q)
      if (!end) return 0
      rest = substr(v, end + 2); v = substr(v, 2, end - 1)
      # A backslash escapes in double quotes, two single quotes make one in single quotes: neither is read here.
      if ((q == "\"" && index(v, "\\")) || (rest !~ /^[ ]*$/ && rest !~ /^[ ]+#/)) return 0
    } else {
      if (v ~ /^#/) v = ""
      sub(/[ \t]+#.*$/, "", v)
      if (v ~ /^(null|Null|NULL|~)[ ]*$/) v = ""
      else if (v != "" && v !~ /^[A-Za-z0-9]/) return 0
    }
    if (v ~ /[^ \t]/) statement = v
    return 1
  }'

# check_ignorefile: .trivyignore.yaml, when present, may only list vulnerabilities (the format also has secrets,
# misconfigurations and licenses sections, and trivy would apply them), each with an id, a statement giving the reason
# (plain text or in quotes, on its line) and an expired_at (yyyy-mm-dd) at most 30 days after today (UTC), so no
# exception lives longer than 30 days without another reviewed change. Read line by line in the shape below; anything
# else is refused rather than guessed:
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
  awk -v limit="$limit" -v sq="'" "$statement_awk"'
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
    /^    statement:/ {
      list = 0
      if (!read_statement($0)) bad("statement is neither plain text nor text in quotes: " $0)
      next
    }
    /^    expired_at:/ {
      list = 0; expired = $0; sub(/^    expired_at:[ ]*/, "", expired); gsub(/"/, "", expired); next
    }
    /^    (purls|paths):[ ]*$/ { list = 1; next }
    /^      - [^ ]/ { if (!list) bad("list item outside purls: or paths:"); next }
    { bad("unexpected line (only id, statement, expired_at, purls, paths): " $0) }
    END { close_item(); exit failed }' "$trivyignore"
}

# check_config_ignorefile: deploy/ci/trivy-config-ignore.yaml may only list misconfigurations, each with an id
# (DS-0026, KSV-0048, ...), the paths it applies to (files of the repository, no pattern: an id is never left out for
# the whole repository, and an entry whose file is gone fails until it is removed), a statement giving the reason and an
# expired_at (yyyy-mm-dd) at most 90 days after today (UTC): a misconfiguration changes only when the repository does,
# so it gets about one stage, not the 30 days of a vulnerability. The statement is on its line (plain text or in quotes)
# or folded (>-) onto the lines below it. Read line by line in the shape below; anything else is refused rather than
# guessed:
#   misconfigurations:
#     - id: DS-0026
#       paths:
#         - deploy/docker/service.Dockerfile
#       statement: >-
#         why this is a deliberate choice
#       expired_at: 2027-01-22
check_config_ignorefile() {
  [ -f "$config_ignore" ] || return 0
  local limit listed failed=0
  limit=$(date -u -d '+90 days' +%F 2>/dev/null || date -u -v+90d +%F)
  listed=$(mktemp)
  awk -v limit="$limit" -v file="${config_ignore#"$repo_root"/}" -v listed="$listed" -v sq="'" "$statement_awk"'
    function bad_at(line, msg) { printf "FAIL  %s:%d: %s\n", file, line, msg; failed = 1 }
    function bad(msg) { bad_at(NR, msg) }
    function close_item() {
      if (!item) return
      if (paths == 0) bad_at(start, "entry " id " has no paths (an id is never ignored for the whole repository)")
      if (statement == "") bad_at(start, "entry " id " has no statement (the reason it is ignored)")
      if (expired !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        bad_at(start, "entry " id " has no expired_at yyyy-mm-dd")
      else if (expired > limit)
        bad_at(start, "entry " id " expires " expired ", more than 90 days from today (" limit ")")
    }
    /^[ ]*(#.*)?$/ { next }
    /^misconfigurations:[ ]*$/ { if (root++) bad("misconfigurations: twice"); next }
    /^[^ ]/ { bad("only misconfigurations may be ignored here: " $0); next }
    !root { bad("entry outside misconfigurations:"); next }
    /^  - id:[ ]*[^ ]/ {
      close_item()
      item = 1; start = NR; statement = ""; expired = ""; paths = 0; list = 0; folded = 0
      id = $0; sub(/^  - id:[ ]*/, "", id)
      if (id !~ /^[A-Z]+-[0-9]+$/) bad("id " id " is not a check id such as DS-0026 or KSV-0048")
      next
    }
    /^    statement:[ ]*[>|]-?[ ]*$/ { list = 0; folded = 1; statement = ""; next }
    /^    statement:/ {
      list = 0; folded = 0
      if (!read_statement($0)) bad("statement is not plain text, text in quotes or a folded block (>-): " $0)
      next
    }
    /^    expired_at:/ {
      list = 0; folded = 0; expired = $0; sub(/^    expired_at:[ ]*/, "", expired); gsub(/"/, "", expired); next
    }
    /^    paths:[ ]*$/ { list = 1; folded = 0; next }
    /^      - [^ ]/ {
      if (!list) { bad("list item outside paths:"); next }
      path = $0; sub(/^      - /, "", path)
      if (path !~ /^[A-Za-z0-9._\/-]+$/ || path ~ /(^|\/)\.\.?(\/|$)/)
        bad("path " path " is not a plain relative path; name each file, no pattern")
      else print NR "\t" path > listed
      paths++
      next
    }
    /^      [^ -]/ { if (folded) { statement = statement $0; next } }
    { bad("unexpected line (only id, paths, statement, expired_at): " $0) }
    END { close_item(); exit failed }' "$config_ignore" || failed=1
  # Each path must be a file of the repository: not a directory (which would cover a whole tree), not a file gone.
  while IFS=$'\t' read -r line path; do
    [ -f "$repo_root/$path" ] || {
      echo "FAIL  ${config_ignore#"$repo_root"/}:$line: path $path is not a file of the repository"
      failed=1
    }
  done <"$listed"
  rm -f "$listed"
  return "$failed"
}

if [ "$check_only" = true ]; then
  checked=0
  if check_ignorefile; then echo "ok    .trivyignore.yaml keeps its rules"; else checked=1; fi
  if check_config_ignorefile; then
    echo "ok    ${config_ignore#"$repo_root"/} keeps its rules"
  else checked=1; fi
  [ "$checked" -eq 0 ] || fail "an ignore file breaks its rules"
  exit 0
fi

# Each mode takes only its own kind of report, so an image report cut short (no ImageID) never passes as a lockfile's.
if [ "$artifact" = image ]; then
  jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 ||
    {
      echo "FAIL  $label: $report is not a trivy JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
      exit 2
    }
  what=Image place="in the image" outcome="nothing is pushed, signed or attested"
else
  jq -e '.SchemaVersion == 2 and .ArtifactType == "filesystem"' "$report" >/dev/null 2>&1 ||
    {
      echo "FAIL  $label: $report is not a trivy fs JSON report (SchemaVersion 2, ArtifactType filesystem)" >&2
      exit 2
    }
  what=Lockfile place="" outcome="the check fails"
fi

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

ci_summary "| $what | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN | Secrets |" \
  "| --- | --- | --- | --- | --- | --- | --- |" \
  "| $label | $critical | $high | $medium | $low | $unknown | $secrets |" ""
# The table went to a summary page apart from the log: the counts go to the log too.
if ci_has_summary; then
  echo "$label: CRITICAL $critical, HIGH $high, MEDIUM $medium, LOW $low, UNKNOWN $unknown, secrets $secrets"
fi

if [ "$secrets" -gt 0 ]; then
  echo "FAIL  $label: $secrets secret(s) found${place:+ $place}; $outcome" >&2
  # Rule, file and line only: the matched text stays out of logs and summaries of a public repository.
  jq -r '.Results[]? | .Target as $t | .Secrets[]? | "secret  \(.RuleID) (\(.Severity)) in \($t) line \(.StartLine)"' \
    "$report" | ci_summary_tee >&2
  blocked=1
fi
if [ "$critical" -gt 0 ]; then
  jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]? | select(.Severity == "CRITICAL")
    | "critical  \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) (fixed: \(.FixedVersion // "none")) in \($t)"' \
    "$report" | ci_summary_tee >&2
  if [ "$allow_critical" = true ]; then
    echo "note  $label: $critical CRITICAL vulnerabilities let through (--allow-critical)" >&2
  else
    echo "FAIL  $label: $critical CRITICAL vulnerabilities; $outcome" >&2
    blocked=1
  fi
fi
[ "$blocked" -eq 0 ] && echo "ok    $label passes the scan gate"
exit "$blocked"
