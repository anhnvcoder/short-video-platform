#!/usr/bin/env bash
# Tests for the rules on the table of release sources (deploy/helm/svp-policy/files/sources.json), which are written
# twice: in the template of chart svp-policy, which fails the render of a table the policy would get wrong, and in
# _release_sources_check of deploy/k8s/lib.sh, which every script reading the table goes through. Each broken table
# below must be refused by both, each with its own message, so that a rule changed on one side only fails here:
#   - an imagePrefix that starts with another source's, or equals it;
#   - a service in three sources (web in a retired source too);
#   - a quote, a backslash or white space in a value (they go into CEL string literals);
#   - two sources with one name, or one promoter (a retired source given another's promoter too);
#   - a promoter that is empty, a number or null (a retired source leaves the key out);
#   - a file that is not JSON;
#   - an imagePrefix that does not end in /, a provenanceRef that is not a refs/... ref.
# The table of the working tree passes both, with its retired sources (no promoter), and its render selects exactly
# two globs per published name (matchImageReferences) and has one attestor per source, named after it; a source that
# loses its promoter is accepted by both too. Each case renders a copy of the chart with its own table, under Helm
# homes in a temporary directory, so no cache or repository of the machine is read or written.
# Needs bash, jq and helm: no network, no cluster.
#
# Usage, from anywhere: deploy/ci/sources-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
table=$src/deploy/helm/svp-policy/files/sources.json

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# render FILE: helm template of a copy of the chart whose files/sources.json is FILE; output and errors in $work/out.
render() {
  rm -rf "$work/chart"
  cp -R "$src/deploy/helm/svp-policy" "$work/chart"
  cp "$1" "$work/chart/files/sources.json"
  HELM_CACHE_HOME=$work/helm/cache HELM_CONFIG_HOME=$work/helm/config HELM_DATA_HOME=$work/helm/data \
    helm template svp-policy "$work/chart" >"$work/out" 2>&1
}

# check FILE: _release_sources_check of deploy/k8s/lib.sh on FILE, in a shell of its own (its fail exits);
# output and errors in $work/out.
check() {
  bash -c '. "$1/deploy/k8s/lib.sh" && _release_sources_check test <"$2"' check "$src" "$1" >"$work/out" 2>&1
}

# refused NAME JQ HELM_MESSAGE LIB_MESSAGE: the table of the working tree changed by the jq filter JQ (raw text, not
# JSON, when JQ starts with "raw:") fails the render with HELM_MESSAGE and the check with LIB_MESSAGE.
refused() {
  local name=$1 filter=$2 file=$work/case.json
  if [[ $filter == raw:* ]]; then
    printf '%s\n' "${filter#raw:}" >"$file"
  else
    jq "$filter" "$table" >"$file"
  fi
  if render "$file"; then
    fail "$name: helm template renders the table"
  elif grep -qF -- "$3" "$work/out"; then
    ok "$name: helm template refuses it ($3)"
  else
    fail "$name: helm template fails without \"$3\": $(tail -n 1 "$work/out")"
  fi
  if check "$file"; then
    fail "$name: _release_sources_check accepts the table"
  elif grep -F -- "release sources of test: " "$work/out" | grep -qF -- "$4"; then
    ok "$name: _release_sources_check refuses it ($4)"
  else
    fail "$name: _release_sources_check fails without \"$4\": $(tail -n 1 "$work/out")"
  fi
}

# --- The table of the working tree: both accept it, the check prints it back unchanged.
if render "$table" && grep -q 'kind: ImageValidatingPolicy' "$work/out"; then
  ok "the table of the working tree renders the policy"
else
  fail "the table of the working tree: helm template fails: $(tail -n 3 "$work/out")"
fi
# matchImageReferences: exactly <imagePrefix><name>@* and <imagePrefix><name>:* for every name of every source, no glob
# of a whole prefix (an image under a prefix with a name nobody publishes would make Kyverno ask the registry first).
want=$(jq -r '.sources[] | .imagePrefix as $p | (.services + .drillImages)[] | ($p + . + "@*"), ($p + . + ":*")' \
  "$table" | sort)
got=$(sed -n '/^  matchImageReferences:$/,/^  [^ ]/p' "$work/out" | sed -n 's/^    - glob: "\(.*\)"$/\1/p' | sort)
if [ -n "$got" ] && [ "$got" = "$want" ] && ! grep -q '/\*$' <<<"$got"; then
  ok "matchImageReferences is one @* and one :* glob per published name ($(grep -c . <<<"$got") globs), none of a whole prefix"
else
  fail "matchImageReferences: want $(tr '\n' ' ' <<<"$want")got $(tr '\n' ' ' <<<"$got")"
fi
if check "$table" && [ "$(cat "$work/out")" = "$(jq -c . "$table")" ]; then
  ok "_release_sources_check accepts the table of the working tree and prints it"
else
  fail "_release_sources_check on the table of the working tree: $(tail -n 1 "$work/out")"
fi

# attestors: one per source, named after it, with that source's identity (rendered again: the check above wrote
# $work/out).
want=$(jq -r '.sources[] | "\(.name) \(.issuer) \(.subject)"' "$table")
render "$table" || true
got=$(sed -n '/^  attestors:$/,/^  [^ ]/p' "$work/out" | awk '
  /^    - name: / { name = $3 } /- issuer: / { issuer = $3 } /^ *subject: / { gsub(/"/, "", issuer); gsub(/"/, "", $2)
    print name, issuer, $2 }')
if [ -n "$got" ] && [ "$got" = "$want" ]; then
  ok "attestors: one per source, named after it, with its identity ($(grep -c . <<<"$got") attestors)"
else
  fail "attestors: want $(tr '\n' ';' <<<"$want") got $(tr '\n' ';' <<<"$got")"
fi
retired=$(jq -r '[.sources[] | select(has("promoter") | not) | .name] | join(", ")' "$table")
if [ -n "$retired" ]; then
  ok "the table of the working tree has retired sources (no promoter), which both accept above: $retired"
else
  ok "the table of the working tree has no retired source"
fi

# accepted NAME JQ: the table of the working tree changed by the jq filter JQ renders the policy and passes the check.
accepted() {
  local file=$work/case.json
  jq "$2" "$table" >"$file"
  if render "$file" && grep -q 'kind: ImageValidatingPolicy' "$work/out"; then
    ok "$1: helm template renders the policy"
  else
    fail "$1: helm template fails: $(tail -n 1 "$work/out")"
  fi
  if check "$file"; then
    ok "$1: _release_sources_check accepts it"
  else
    fail "$1: _release_sources_check refuses it: $(tail -n 1 "$work/out")"
  fi
}
accepted "a source without promoter (retired)" 'del(.sources[1].promoter)'

# --- Broken tables, each from the working tree's (source 0 backend, 1 web, 2 oldbackend and 3 oldweb, the last two
# retired: no promoter).
web_under_backend='.sources[1].imagePrefix = .sources[0].imagePrefix + "web/"'
refused "imagePrefix under another source's" "$web_under_backend" \
  "starts with ghcr.io/anhnvcoder/svp-backend/ of source backend" \
  "the imagePrefix of one source starts with the imagePrefix of another"
refused "imagePrefix equal to another source's" '.sources[1].imagePrefix = .sources[0].imagePrefix' \
  "starts with ghcr.io/anhnvcoder/svp-backend/ of source" \
  "the imagePrefix of one source starts with the imagePrefix of another"
third='.sources += [.sources[1] | .name = "third" | .imagePrefix = "ghcr.io/anhnvcoder/third/" | .promoter = "third-promoter"]'
refused "a service in three sources" "$third" \
  "service web is in more than two sources" \
  "a service is in more than two sources"
refused "web in three sources, one of them retired" '.sources[2].services += ["web"]' \
  "service web is in more than two sources" \
  "a service is in more than two sources"
refused "a quote in a value" '.sources[1].subject += "\""' \
  "subject of source web goes into CEL string literals" \
  "must each be a string without quote, backslash or white space"
refused "a single quote in a value" '.sources[1].issuer += "'"'"'"' \
  "issuer of source web goes into CEL string literals" \
  "must each be a string without quote, backslash or white space"
refused "a backslash in a value" '.sources[0].provenanceRef += "\\x"' \
  "provenanceRef of source backend goes into CEL string literals" \
  "must each be a string without quote, backslash or white space"
refused "white space in a value" '.sources[1].repository = "https://github.com/anhnvcoder/svp web"' \
  "repository of source web goes into CEL string literals" \
  "must each be a string without quote, backslash or white space"
refused "two sources with one name" '.sources[1].name = "backend"' \
  "two sources are named backend" \
  "two sources share a name"
refused "two sources with one promoter" '.sources[1].promoter = .sources[0].promoter' \
  "two sources are promoted by svp-gitops-promoter" \
  "two sources share a promoter"
refused "a retired source given the promoter of another" '.sources[3].promoter = .sources[1].promoter' \
  "two sources are promoted by svp-web-promoter" \
  "two sources share a promoter"
refused "an empty promoter" '.sources[1].promoter = ""' \
  "source web has no promoter string" \
  "source web: promoter, when given, must be a string"
refused "a promoter that is a number" '.sources[1].promoter = 5' \
  "source web has no promoter string" \
  "source web: promoter, when given, must be a string"
refused "a promoter that is null" '.sources[3].promoter = null' \
  "source oldweb has no promoter string" \
  "source oldweb: promoter, when given, must be a string"
refused "white space in a promoter" '.sources[1].promoter = "svp web"' \
  "promoter of source web goes into CEL string literals" \
  "source web: promoter, when given, must be a string without quote, backslash or white space"
refused "a file that is not JSON" 'raw:{"sources": [' \
  "files/sources.json must be a JSON object whose key sources lists at least one release source" \
  "is not readable JSON"
refused "an imagePrefix without the trailing /" '.sources[1].imagePrefix |= rtrimstr("/")' \
  "imagePrefix of source web must end in /" \
  "imagePrefix of every source must end in /"
refused "a provenanceRef that is not a refs/... ref" '.sources[1].provenanceRef = "heads/main"' \
  "provenanceRef of source web must be a refs/... ref" \
  "provenanceRef of every source must be a refs/... ref"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
