#!/usr/bin/env bash
# Builds the public artifact of a verification run: copies
# the files of an allow list into $SVP_VERIFY_ARTIFACT (default verify-artifact in ci_temp_dir of
# deploy/ci/platform.sh: $RUNNER_TEMP on GitHub), each only after a scan, and prints to the job's log a summary taken
# from the copies alone. Anyone can read the artifact and the log of a public repository, so it fails closed: a file
# it is unsure of is left out, with a warning (ci_warning of platform.sh, an annotation on GitHub) naming the file and
# the rule, never the text that matched.
#
# The allow list. From the run's results ($SVP_VERIFY_OUT, default verify in ci_temp_dir; never uploaded as a whole):
#   written on the runner itself  results.tsv, scenario, host-start.txt, runner.json, runner.txt, df-before.txt,
#                                 df-after.txt, samples/*.tsv (deploy/ci/verify-run.sh, verify-host.sh,
#                                 verify-sample.sh; the samples that come from the cluster are numbers, states, names
#                                 and event reasons, never an event's text)
#   read from the stack/cluster   logs/*.log (each make target's own output; of the two threat model drills, whose
#                                 output holds what their probes got back, only the verdict lines, ok, PASS, FAIL,
#                                 SKIP, WARN, with the item headings, the closing table and the last line around
#                                 them), ram-*.json, ram-*.txt, rate-limit-load.json, lcp.json, k8s-status.txt,
#                                 events.txt, compose-ps.txt, release-set.json (the set of releases stg ran, which job
#                                 record-stg of verify.yml records: repositories, tags, digests, commits, times; the
#                                 snapshots under release-set/ it was read from stay out)
# A target's output may quote a container's log, and no service log may reach the artifact. make k8s-up prints the log
# of a failed migrate Job and, after a release that did not get ready, the last lines of each unready container's log
# (unready_report of deploy/k8s/lib.sh), each line as "    [NAMESPACE] LINE"; drill-alert-to-sentry prints the gateway's
# access log line it found in Loki. The copy of a target's output leaves out every such line of a namespace not in
# log_tail_namespaces of deploy/k8s/lib.sh (third-party servers and operators only: never svp, the project's services),
# every line of a JSON log record (a "msg" or "level" key, the form of the services' slog and of most third-party
# servers) and every line quoting an access log ("access log of trace"), and files.txt says how many lines it left out.
# What is kept of a third-party log goes through the scan below like the rest of the file.
# From the checkout (all read from the stack/cluster): .k8s/drills/*.json and traffic-*.log (each line a time, a user,
# a route, a status and a duration), .k6/<run>/summary.json, the summary of each pod of the k6 Job
# (.k6/cloud-<time>/pod-<i>.json of deploy/k6/cloud/run.sh logs, whose table is in the target's output),
# and, from the clone of the web client's repository svp-web the run's web targets ran in (.web/svp-web, the folder of
# make web-clone), test-results/measure-*.json and glitchtip-*.json, the Lighthouse reports
# test-results/lighthouse/*.json and *.html, and the error-context.md Playwright writes for a failed test
# (test-results/playwright/<test>/: the error and the page's accessibility tree at that moment, text, so the next red
# e2e test has evidence; its trace stays out). Everything else under those places is listed in files.txt as
# not-allowed: .env, kubeconfig, .k8s/ca.*, .k8s/helm/, .k8s/drills/threats-*.log, Playwright traces,
# videos, screenshots, HAR and HTML report, k6's machine.json, hidden files and every service log never get in. A
# hidden file is dropped with its own rule and a warning, except test-results/playwright/.last-run.json, which
# Playwright writes on every run (the ids of the tests that failed): known, so not-allowed without a warning.
#
# Each candidate is refused when it is hidden, not a regular file (a link could point at .env), over 5 MiB, or when it
# matches (grep -a: binary files are read as text):
#   secret-value   a value of $SVP_VERIFY_SECRETS/env.values or cluster.values (deploy/ci/verify-mask.sh: every secret
#                  of .env and every value of the cluster's Secrets, raw and base64, 8 characters or more); both lists
#                  are read again here, the cluster's while it still runs
#   jwt            eyJ<8+>.eyJ<8+>. (header and payload of a JWT or JWS; eyJ alone also occurs in the base64 of the
#                  screenshots Lighthouse embeds, which have no dots)
#   session-cookie svp_sid (in the verdict lines of a threat model drill: svp_sid not followed by a space, see rule)
#   bearer "Bearer "; set-cookie "Set-Cookie"; private-key "-----BEGIN ... PRIVATE KEY-----"
# A file read from the stack or the cluster is copied only when every list it needs was read: .env's always, the
# cluster's too unless the scenario is compose-obs. A list that could not be read (an .env that breaks its rule, a
# cluster that died before its Secrets were read once) leaves only the files written on the runner itself
# (no-secret-list). The cluster's list keeps every value read while the cluster ran, so a cluster gone by now still
# has one.
#
# The artifact holds files.txt (every candidate: kept, with the lines left out of it if any, or dropped with its
# rule), the results under their own names,
# and the checkout's files under k8s-drills/, k6/ and web-test-results/ (upload-artifact leaves hidden folders such as
# .k8s out). Exits 0 whatever it dropped; 1 only when it cannot build the artifact folder.
#
# SVP_VERIFY_REPO (default: this checkout) points it at another tree, for deploy/ci/verify-collect-test.sh.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${SVP_VERIFY_REPO:-$(cd "$here/../.." && pwd)}
# ci_temp_dir, ci_warning: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
art=${SVP_VERIFY_ARTIFACT:-$tmp_root/verify-artifact}
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
export SVP_VERIFY_REPO=$repo SVP_VERIFY_SECRETS=$secrets
max_bytes=$((5 * 1024 * 1024))
jwt_re='eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.'
service_log_re='"(msg|level)"[[:space:]]*:|access log of trace'
# The namespaces whose container log lines may stay, read from deploy/k8s/lib.sh, which prints them; none (every
# such line left out) when it cannot be read.
log_tail_namespaces=$(. "$here/../k8s/lib.sh" >/dev/null 2>&1 && printf '%s' "$log_tail_namespaces") || log_tail_namespaces=
# The lines of a threat model drill that reach the artifact, each a fixed form with no probe output in it: a verdict;
# the "== ITEM" heading of drill-k8s-threats each check falls under; its closing table, "  ITEM  PASS|FAIL" under a
# header "  ITEM  RESULT" and a title "drill-k8s-threats (<time>-<hex>)"; the closing "...: all checks passed".
verdict_re='^(ok|PASS|FAIL|SKIP|WARN)[[:space:]]'
item_re='^== [A-Za-z0-9/-]+$'
table_re='^  [A-Za-z0-9/-]+ +(PASS|FAIL|RESULT)$|^drill-k8s-threats \([0-9]{8}T[0-9]{6}Z-[0-9a-f]+\)$'
drill_end_re='^drill-(k8s|obs)-threats: all checks passed$'

scenario=$(cat "$out/scenario" 2>/dev/null) || scenario=unknown
rm -rf "$art" && mkdir -p "$art" || {
  echo "verify-collect: cannot create $art" >&2
  exit 1
}
umask 077
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# --- The value lists. verify-mask.sh also masks any value new since its last call.
lists_ok=1
"$here/verify-mask.sh" env || lists_ok=0
if [ "$scenario" != compose-obs ]; then
  if ! "$here/verify-mask.sh" cluster && [ -f "$secrets/cluster.values" ]; then
    echo "verify-collect: the cluster's Secrets were not read now; the list read while it ran is used"
  fi
  [ -f "$secrets/cluster.values" ] || lists_ok=0
fi
[ -f "$secrets/env.values" ] || lists_ok=0
cat "$secrets/env.values" "$secrets/cluster.values" 2>/dev/null >"$work/values"
if [ "$lists_ok" = 1 ]; then
  echo "verify-collect: secret lists read; files from the stack or cluster are scanned and copied"
else
  ci_warning "verify-collect: a secret list could not be read; only the files written on the runner itself are copied"
fi

: >"$work/files"
kept=0
dropped=0

# drop SRC RULE: records SRC as dropped; a rule other than not-allowed also gets a warning in the log (ci_warning).
drop() {
  printf 'dropped\t%s\t%s\n' "$1" "$2" >>"$work/files"
  dropped=$((dropped + 1))
  [ "$2" = not-allowed ] || ci_warning "$1: $2"
}

# rule FILE [KIND]: prints the first scan rule FILE breaks, nothing when it is clean. KIND verdicts (the verdict lines
# of a threat model drill, the drill's own sentences) narrows session-cookie: the web client's items name the session
# cookie in prose, its name followed by a space ("session cookie __Host-Http-svp_sid in the drill's cookie jar"), and
# no form a cookie's value is written in puts the value after the name and a space (a header has name=value, a cookie
# jar name<TAB>value, JSON "name": ..., "value": ...). So there svp_sid followed by any other character, or ending a
# line, is still refused; in every other file svp_sid at all.
rule() {
  local sid_re=svp_sid
  [ "${2:-}" = verdicts ] && sid_re='svp_sid([^ ]|$)'
  if [ -s "$work/values" ] && grep -qaF -f "$work/values" -- "$1"; then
    echo secret-value
  elif grep -qaE -- "$jwt_re" "$1"; then
    echo jwt
  elif grep -qaE -- "$sid_re" "$1"; then
    echo session-cookie
  elif grep -qaF -- 'Bearer ' "$1"; then
    echo bearer
  elif grep -qaF -- Set-Cookie "$1"; then
    echo set-cookie
  elif grep -qaE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$1"; then
    echo private-key
  fi
}

# consider FILE SRC DEST KIND [NOTE]: copies FILE (shown as SRC) to $art/DEST when it passes; KIND is runner (written
# on the runner itself), stack (read from the stack or the cluster) or verdicts (the verdict lines of a threat model
# drill, read from the stack or the cluster, scanned by rule as such); NOTE goes with it into files.txt.
consider() {
  local file=$1 src=$2 dest=$3 kind=$4 note=${5:-} r size
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    drop "$src" not-regular
    return
  fi
  size=$(wc -c <"$file" | tr -d ' ')
  if [ "$size" -gt "$max_bytes" ]; then
    drop "$src" too-large
    return
  fi
  if [ "$kind" != runner ] && [ "$lists_ok" != 1 ]; then
    drop "$src" no-secret-list
    return
  fi
  r=$(rule "$file" "$kind")
  if [ -n "$r" ]; then
    drop "$src" "$r"
    return
  fi
  mkdir -p "$art/$(dirname "$dest")" && cp "$file" "$art/$dest" || {
    drop "$src" copy-failed
    return
  }
  printf 'kept\t%s\t%s\t%s\n' "$src" "$dest" "$note" >>"$work/files"
  kept=$((kept + 1))
}

# hidden SUB: true when a component of SUB starts with a dot.
hidden() {
  case /$1 in */.*) return 0 ;; *) return 1 ;; esac
}

# --- The run's results.
if [ -d "$out" ]; then
  while IFS= read -r -d '' file; do
    sub=${file#"$out"/}
    src="\$SVP_VERIFY_OUT/$sub"
    if hidden "$sub"; then drop "$src" hidden; continue; fi
    case $sub in
      results.tsv | scenario | host-start.txt | runner.json | runner.txt | df-before.txt | df-after.txt)
        consider "$file" "$src" "$sub" runner ;;
      samples/*/*) drop "$src" not-allowed ;;
      samples/*.tsv) consider "$file" "$src" "$sub" runner ;;
      logs/*/*) drop "$src" not-allowed ;;
      logs/*-drill-k8s-threats.log | logs/*-drill-obs-threats.log)
        grep -aE -e "$verdict_re" -e "$item_re" -e "$table_re" -e "$drill_end_re" "$file" |
          grep -avE -- "$service_log_re" >"$work/verdicts" || :
        consider "$work/verdicts" "$src (verdict lines)" "${sub%.log}.verdicts.log" verdicts ;;
      logs/*.log)
        # A marked log line is "    [NAMESPACE] ", the namespace starting at character 6.
        grep -avE -- "$service_log_re" "$file" | LC_ALL=C awk -v shown=" $log_tail_namespaces " '
          match($0, /^    \[[a-z0-9-]+\] /) && !index(shown, " " substr($0, 6, RLENGTH - 7) " ") { next }
          { print }' >"$work/output" || :
        # grep -c, not wc -l: a last line without a newline counts too.
        removed=$(($(grep -ac '' "$file") - $(grep -ac '' "$work/output")))
        note=
        [ "$removed" = 0 ] || note="$removed service log line(s) left out"
        consider "$work/output" "$src" "$sub" stack "$note" ;;
      */*) drop "$src" not-allowed ;;
      ram-*.json | ram-*.txt | rate-limit-load.json | lcp.json | k8s-status.txt | events.txt | compose-ps.txt | \
        release-set.json)
        consider "$file" "$src" "$sub" stack ;;
      *) drop "$src" not-allowed ;;
    esac
  done < <(find "$out" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
fi

# --- The checkout's results: BASE in the tree, DEST its folder in the artifact. The web client's are in the clone of
# svp-web in the tree, where its targets write them.
web_results=.web/svp-web/test-results
for pair in .k8s/drills:k8s-drills .k6:k6 "$web_results:web-test-results"; do
  base=${pair%%:*}
  dest=${pair#*:}
  [ -d "$repo/$base" ] || continue
  while IFS= read -r -d '' file; do
    sub=${file#"$repo/$base"/}
    src=$base/$sub
    if [ "$src" = "$web_results/playwright/.last-run.json" ]; then drop "$src" not-allowed; continue; fi
    if hidden "$sub"; then drop "$src" hidden; continue; fi
    allowed=0
    case $base:$sub in
      .k8s/drills:*/*) ;;
      .k8s/drills:*.json | .k8s/drills:traffic-*.log) allowed=1 ;;
      .k6:*/*/*) ;;
      .k6:*/summary.json | .k6:cloud-*/pod-*.json) allowed=1 ;;
      "$web_results":lighthouse/*/*) ;;
      "$web_results":lighthouse/*.json | "$web_results":lighthouse/*.html) allowed=1 ;;
      "$web_results":playwright/*/error-context.md) allowed=1 ;;
      "$web_results":*/*) ;;
      "$web_results":measure-*.json | "$web_results":glitchtip-*.json) allowed=1 ;;
    esac
    if [ "$allowed" = 1 ]; then consider "$file" "$src" "$dest/$sub" stack; else drop "$src" not-allowed; fi
  done < <(find "$repo/$base" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
done

# files.txt holds only paths this script chose and rule names; scanned all the same before it is published.
cp "$work/files" "$work/files.txt"
if [ -n "$(rule "$work/files.txt")" ]; then
  ci_warning "files.txt: a file name matched a scan rule; files.txt left out"
else
  cp "$work/files.txt" "$art/files.txt"
fi

echo "verify-collect ($scenario): $kept file(s) kept, $dropped dropped (files.txt in the artifact lists both)"

# --- The summary in the job's log, from the copies only: the result of each target, and the end of the output of
# each target that did not pass, when that output reached the artifact.
if [ -f "$art/results.tsv" ]; then
  echo "results:"
  awk -F '\t' 'NR > 1 { printf "  %-3s %-28s %-8s exit %-4s %6s s  %s\n", $1, $2, $3, $4, $7, $8 }' "$art/results.tsv"
  awk -F '\t' 'NR > 1 && $3 != "ok" && $3 != "skipped" { print $1 "-" $2 }' "$art/results.tsv" |
    while IFS= read -r stem; do
      for log in "$art/logs/$stem.log" "$art/logs/$stem.verdicts.log"; do
        [ -f "$log" ] || continue
        echo "---- last 40 lines of ${log#"$art"/}"
        tail -n 40 "$log"
      done
    done
fi
exit 0
