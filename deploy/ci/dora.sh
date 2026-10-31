#!/usr/bin/env bash
# dora.sh [--days N] [--now TIME] JSON: the software delivery metrics of DORA (deployment frequency, change lead
# time, change fail rate, failed deployment recovery time, deployment rework rate) of environment stg, computed from
# evidence that a release ran there, never from merges. Writes JSON (the whole result) and prints a Markdown summary,
# which on CI also goes to the summary page of the job (ci_summary_tee of platform.sh). Reads only; every number of stg
# is labelled "stg lab": stg is a cluster built and torn down inside one run of scenario gitops, so the numbers measure
# the rhythm of those runs as much as the delivery itself. prd has no records before it runs for real, so every metric
# of prd reads "no data", never 0. No level (elite, high, ...) is ever assigned.
#
# Sources:
#   - the deployment records of stg in svp-gitops (ci_deployment_list of platform.sh). A record counts when it was
#     made by the bot of the app that writes there, its payload has the form release-set.sh writes (release-set.sh
#     check --at-charts: its releases judged by the table of release sources at its own charts revision, so a record
#     from before a service moved to another source still counts once the old source no longer publishes it), names
#     its own commit, holds a deployed_at, and its run_url is a run of verify.yml on main of the code repository
#     (ci_run_workflow), the same filter as the check of a pull request to prd; a run_url under a former name of the
#     code repository counts (ci_is_run_url: records made before a rename stay in reach of --days for years). Its state:
#     success counts; inactive counts with a warning when an earlier status of it was success (a record made before
#     records were kept active); anything else is left out. Every record left out is listed with why, so a loss shows
#     instead of making a number quietly smaller.
#   - git: origin/main of this checkout (full history) and of the clone of svp-gitops (gitops_dir of
#     deploy/k8s/lib.sh), as last fetched; nothing is fetched here. A release is a commit of the repository of its
#     release source in the table at its record's charts revision (deploy/helm/svp-policy/files/sources.json there, as
#     release_sources of lib.sh reads it), named as that repository is called now (ci_repo_current of platform.sh): a
#     source that names a renamed repository by its former name, retired since or dropped from the table, builds commits
#     of the same history as the source that names it by its current name. A release built in another repository than
#     this one (the web of svp-frontend): only when a record that counts holds one, the history of that repository is
#     read too, from its clone (svp-frontend: web_dir of deploy/k8s/lib.sh, SVP_WEB_DIR or <workspace>/frontend, with
#     its origin/main; CI: make web-clone WEB_REF=main). Such a record without that clone stops the run, saying so;
#     without such a record no clone is asked for.
#   - the front matter of docs/postmortems/*.md (README.md aside): env, deployment, started_at, restored_at,
#     fix_commits.
#
# Definitions:
#   - A deployment is one (revision R of svp-gitops, set of seven repository@digest) of the records that count. Several
#     records of the same pair are re-checks of one deployment: it takes the deployed_at of the first record made, the
#     others count as checks. Another R is another deployment, even with the same set (a change of charts or
#     configuration is deployed too). A set equal to an older one is no rollback by itself.
#   - A change is a commit of main: of the code repository that changed-services.sh lists a service s for (a change of
#     s), of another repository whose release of s a deployment holds (every commit there is a change of s: such a
#     repository holds that service alone; the first deployment holding a release of s from that repository, under
#     whichever of its names, takes no sample of it, as the first deployment of all), or that touches the charts
#     (deploy/helm/, and the collector config whose hash envs/<env>/charts.yaml holds); of svp-gitops that touches what
#     stg deploys besides images and charts (base/, argocd/, envs/stg/ but its images/ and charts.yaml). Its one lead
#     time sample is taken at the earliest deployment that holds it (the commit of the image of s, the charts revision,
#     or R is it or a descendant of it): deployed_at minus its committer date. Changes the first deployment already
#     holds have no sample: when they ran is unknown. Merge commits are no change.
#   - A rollback is the first deployment whose R holds a revert commit of svp-gitops (subject "revert: ..." with a
#     footer "Refs: <sha>", or git revert's 'Revert "..."' with "This reverts commit <sha>."), when the reverted commit
#     was deployed before: the latest earlier deployment whose R holds it failed. A revert of a commit never deployed
#     fails nothing and is listed. A postmortem of env stg whose deployment names an R marks the first deployment of
#     that R failed.
#   - Recovery of a failed deployment: from started_at of its postmortem (deployed_at of the deployment otherwise) to
#     restored_at of it (otherwise the earliest deployed_at of its rollback or of the first deployment holding one of
#     its fix_commits); none yet: "not restored", no sample.
#   - Rework: deployments that are a rollback, or the first to hold a fix commit of a postmortem of env stg.
#   - Postmortems of another env or with deployment none are incidents not caused by a deployment: listed only.
#   - Promote frequency (not a DORA metric): commits of main of svp-gitops that change envs/<env>/images/, its first
#     commit aside (the import of what the code repository held at the split, no promote: that release is a commit
#     "chore(release): ..." of the code repository already), and, before the configuration moved to svp-gitops, the
#     commits "chore(release): ..." of main of the code repository.
#   - Merged, not deployed: each repository@digest that envs/stg/images/ ever held on main of svp-gitops and that no
#     record that counts holds.
#   - Windows: the last N days up to now (--days, 30 by default), and since the first commit of svp-gitops. A rate
#     needs at least 10 deployments in the window and a median at least 5 samples; below that the result says
#     "insufficient data" with n and what was counted, never a percentage or a median.
#
# Needs bash, git, jq; a token that reads the deployments of svp-gitops and the runs of the code repository (both
# public: GH_TOKEN on CI only lifts the rate limit) or a machine's gh login. Writes only JSON (making its directory
# when missing) and a temporary directory it removes.
#
# dora.sh --clones: prints, one per line (nothing when none), the repositories other than this one whose commits built
# a release a record that counts holds: web for the web client's (svp-frontend, under its current or a former name,
# whose clone .github/workflows/dora.yml makes only then), owner/name for any other (none so far: the run stops on it,
# knowing no clone of it). Writes nothing.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

usage="usage: dora.sh [--days N] [--now TIME] JSON (N whole days, 1 to 3650; TIME RFC 3339 UTC, e.g. 2026-10-30T09:17:00Z) | dora.sh --clones"
days=30
now=
clones_only= out=
if [ "${1:-}" = --clones ]; then
  [ $# -eq 1 ] || fail "$usage"
  clones_only=1
else
  while [ $# -gt 1 ]; do
    case $1 in
    --days) days=$2 ;;
    --now) now=$2 ;;
    *) fail "$usage" ;;
    esac
    shift 2
  done
  [ $# -eq 1 ] && [ -n "$1" ] || fail "$usage"
  out=$1
fi
[[ $days =~ ^[1-9][0-9]{0,3}$ ]] && [ "$days" -le 3650 ] || fail "--days $days: $usage"
[ -n "$now" ] || now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ $now =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "--now $now: $usage"

main=refs/remotes/origin/main
record_workflow=.github/workflows/verify.yml
code_repo=$(ci_repo)
config=$(gitops_dir)
chart_paths=(deploy/helm deploy/observability/otelcol/k8s-config.yaml)
config_paths=(base argocd envs/stg ':(exclude)envs/stg/images' ':(exclude)envs/stg/charts.yaml')
cg() { git -C "$repo_root" "$@"; }
gg() { git -C "$config" "$@"; }
cg rev-parse --verify -q "$main^{commit}" >/dev/null ||
  fail "$repo_root has no origin/main: check out the code repository with its whole history"
gg rev-parse --verify -q "$main^{commit}" >/dev/null || fail "the clone of svp-gitops ($config) has no origin/main"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/warnings"
: >"$tmp/skipped.jsonl"
: >"$tmp/changes.jsonl"
: >"$tmp/reverts.jsonl"
: >"$tmp/postmortems.jsonl"
warn() {
  echo "warn  $1" >&2
  echo "$1" >>"$tmp/warnings"
}

# Parses an RFC 3339 time (Z or an offset, fractions dropped) into seconds since the epoch; null for anything else.
jq_lib='
  def epoch: if type != "string" then null else
    (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") // null)
    | if . == null then null else ((.d + "Z") | fromdateiso8601) - (if .z == "Z" then 0 else
        ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60) * (if .z[0:1] == "+" then 1 else -1 end) end) end
  end;'

# --- The records of stg that count.
list=$(ci_deployment_list "$gitops_repo" stg) || fail "list the deployment records of stg in $gitops_repo"
# ci_deployment_list returns the newest 100 records at most: at that many, older ones may be out of reach, and the loss
# must show rather than make the oldest deployment kept look like the first.
if [ "$(jq length <<<"$list")" -ge 100 ]; then
  warn "the host lists $(jq length <<<"$list") records of stg, as many as one list returns: any record older than #$(jq -r 'last.id' <<<"$list") ($(jq -r 'last.created_at' <<<"$list")) is out of reach, so the earliest deployments kept may miss their first records and no period before then is computed again"
fi
kept='[]'
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  id=$(jq -r .id <<<"$rec")
  state=$(jq -r .state <<<"$rec")
  reason='' note=''
  if [ "$state" = inactive ] && jq -e '.states | index("success")' <<<"$rec" >/dev/null; then
    note="record #$id is inactive now, but one of its earlier statuses is success: counted"
  elif [ "$state" != success ]; then
    if [ "$state" = inactive ]; then reason="no success status left (inactive)"; else reason="its state is ${state:-none}, not success"; fi
  fi
  if [ -z "$reason" ] && [ "$(jq -r .creator <<<"$rec")" != "${gitops_app}[bot]" ]; then
    reason="made by $(jq -r .creator <<<"$rec"), not ${gitops_app}[bot]"
  fi
  if [ -z "$reason" ]; then
    jq '.payload' <<<"$rec" >"$tmp/payload.json"
    if ! problem=$("$ci_dir/release-set.sh" check --at-charts "$tmp/payload.json" 2>&1); then
      reason="its payload: $(sed -E 's/^FAIL  .* is no payload of a record of stg: //' <<<"$problem" | head -n 1)"
    elif [ "$(jq -r '.payload.ref' <<<"$rec")" != "$(jq -r .sha <<<"$rec")" ]; then
      reason="its payload names $(jq -r '.payload.ref' <<<"$rec"), not its commit"
    elif ! jq -e "$jq_lib"'.payload.deployed_at | epoch' <<<"$rec" >/dev/null; then
      reason="its payload has no deployed_at of RFC 3339"
    fi
  fi
  if [ -z "$reason" ]; then
    run=$(jq -r '.payload.run_url' <<<"$rec")
    if ! ci_is_run_url "$run"; then
      reason="its run_url '$run' is no run of the code repository"
    elif ! wf=$(ci_run_workflow "$run" 2>/dev/null); then
      reason="its run $run cannot be read from the host"
    elif [ "$wf" != "$record_workflow main" ]; then
      reason="its run $run is of ${wf% *} on ${wf#* }, not of $record_workflow on main"
    fi
  fi
  if [ -n "$reason" ]; then
    echo "skip  record #$id: $reason" >&2
    jq -c -n --argjson id "$id" --arg r "$reason" '{id: $id, reason: $r}' >>"$tmp/skipped.jsonl"
    continue
  fi
  [ -z "$note" ] || warn "$note"
  kept=$(jq -c --argjson r "$rec" '. + [$r | {id, sha, created_at, payload}]' <<<"$kept")
done < <(jq -c '.[]' <<<"$list")

# --- The repository each release the records hold was built from, and its clone. A release is judged by the table of
# release sources at its record's charts revision (release_sources of lib.sh, which reads a commit from before the
# table too), the one the policy of stg applied while it ran: a release of a source later dropped from the table keeps
# its repository. That repository is named as it is called now (ci_repo_current of platform.sh): a source of a
# renamed repository gives its former name, and its releases are commits of the same history as the current name's.
# repo_of_release SERVICE REPOSITORY REV: prints that repository (owner/name, its current name) for SERVICE's release
# REPOSITORY under the charts of REV; status 1 when no source of that table publishes it (a record that counts passed
# release-set.sh check --at-charts, so its releases all have one). One table read per revision.
repo_of_release() {
  local file=$tmp/sources-$3.json url
  [ -s "$file" ] || (release_sources "$3") >"$file" || return 1
  url=$(jq -r --arg s "$1" --arg r "$2" \
    '[.sources[] | select((.services | index($s)) and .imagePrefix + $s == $r) | .repository] | first // ""' "$file")
  [ -n "$url" ] || return 1
  ci_repo_current "${url#https://github.com/}"
}
# The web client's repository, as it is called now: its clone is web_dir of lib.sh.
web_repo=${web_url#https://github.com/}
web_repo=$(ci_repo_current "${web_repo%.git}")
others=
while IFS=$'\t' read -r svc r rev; do
  [ -n "$svc" ] || continue
  repo=$(repo_of_release "$svc" "$r" "$rev") ||
    fail "$svc's release $r is of no release source of the table at the charts ${rev:0:12} of its record"
  [ "$repo" = "$code_repo" ] || others=$(printf '%s\n%s' "$others" "$repo" | sed '/^$/d' | sort -u)
done < <(jq -r '[.[].payload | .charts.revision as $c | .images | to_entries[] | [.key, .value.repository, $c]]
  | unique[] | @tsv' <<<"$kept")
if [ -n "$clones_only" ]; then
  for repo in $others; do
    if [ "$repo" = "$web_repo" ]; then echo web; else echo "$repo"; fi
  done
  exit 0
fi
# The clone of each repository and its name (owner/name); bash 3.2 has no associative arrays.
src_dirs=("$repo_root") src_repos=("$code_repo")
for repo in $others; do
  dir=
  # web_dir fails unless SVP_WEB_DIR or <workspace>/frontend is a clone of svp-frontend; no clone leaves dir empty.
  [ "$repo" != "$web_repo" ] || dir=$(web_dir 2>/dev/null) || dir=
  [ -n "$dir" ] && git -C "$dir" rev-parse --verify -q "$main^{commit}" >/dev/null ||
    fail "records of stg hold releases built from commits of https://github.com/$repo: their lead time needs a clone of it with its whole history and origin/main (svp-frontend: SVP_WEB_DIR, or <workspace>/frontend; CI: make web-clone WEB_REF=main)"
  src_dirs+=("$dir") src_repos+=("$repo")
done
# dir_of_repo REPOSITORY: the clone of REPOSITORY (owner/name, its current or a former name): of the code repository,
# of another repository a release was built from, or of svp-gitops; status 1 for any other.
dir_of_repo() {
  local k repo
  repo=$(ci_repo_current "$1")
  [ "$repo" != "$gitops_repo" ] || {
    echo "$config"
    return 0
  }
  for k in "${!src_repos[@]}"; do
    [ "${src_repos[$k]}" != "$repo" ] || {
      echo "${src_dirs[$k]}"
      return 0
    }
  done
  return 1
}

# --- Deployments: the records grouped by (R, set), the first record made of each group, oldest deployed first.
deps=$(jq -c "$jq_lib"'
  group_by(.sha + " " + (.payload.images | [to_entries[] | "\(.value.repository)@\(.value.digest)"] | sort | join(" ")))
  | map(sort_by(.created_at, .id) | {
      ref: .[0].sha, deployed_at: .[0].payload.deployed_at, t: (.[0].payload.deployed_at | epoch),
      first_created: .[0].created_at, records: map(.id), checks: length, images: .[0].payload.images,
      charts: .[0].payload.charts.revision})
  | sort_by(.t, .first_created) | to_entries | map(.value + {i: .key})' <<<"$kept")
n=$(jq length <<<"$deps")

# services_of SHA: the services changed-services.sh builds for commit SHA of the code repository, one per line.
services_of() {
  local file=$tmp/services-$1
  [ -f "$file" ] || { "$ci_dir/changed-services.sh" "$1^" "$1" 2>/dev/null || :; } | tr ' ' '\n' >"$file"
  cat "$file"
}
# change KIND SERVICE REPOSITORY SHA TIME: one change first held by deployment $i.
change() {
  jq -c -n --argjson d "$i" --arg k "$1" --arg s "$2" --arg r "$3" --arg c "$4" --argjson t "$5" \
    '{deployment: $d, kind: $k, service: (if $s == "" then null else $s end), repository: $r, sha: $c, committed: $t}' \
    >>"$tmp/changes.jsonl"
}
# reverted_of SHA: the commits (as written) that commit SHA of svp-gitops reverts; nothing when it is no revert.
reverted_of() {
  local subject body
  subject=$(gg show -s --format=%s "$1")
  body=$(gg show -s --format=%b "$1")
  case $subject in
  'revert: '*) sed -n -E 's/^Refs:[[:space:]]*//p' <<<"$body" | grep -oE '\b[0-9a-f]{7,40}\b' || : ;;
  'Revert "'*) sed -n -E 's/^This reverts commit ([0-9a-f]{7,40})\b.*$/\1/p' <<<"$body" ;;
  esac
}

# The commits each earlier deployment held, as ^<sha> lines that git log --stdin reads: what a deployment holds first
# is what its own commit reaches and none of these does. One list per service and repository (its current name), not
# per release source: the commits of two repositories never meet, while a source that replaced another for a renamed
# repository continues the same history, so the first deployment after a rename finds no new change in it. A
# deployment's points are "<owner/name> <sha>" lines, what holds reads.
for svc in "${svp_services[@]}"; do
  for k in "${!src_repos[@]}"; do : >"$tmp/prev-$svc-${src_repos[$k]//\//_}"; done
done
: >"$tmp/prev-charts"
: >"$tmp/prev-ref"
refs=()
for ((i = 0; i < n; i++)); do
  dep=$(jq -c --argjson i "$i" '.[$i]' <<<"$deps")
  ref=$(jq -r .ref <<<"$dep")
  refs+=("$ref")
  : >"$tmp/points-$i"
  charts=$(jq -r .charts <<<"$dep")
  for svc in "${svp_services[@]}"; do
    tag=$(jq -r --arg s "$svc" '.images[$s].tag' <<<"$dep")
    repo=$(repo_of_release "$svc" "$(jq -r --arg s "$svc" '.images[$s].repository' <<<"$dep")" "$charts") || exit 1
    for k in "${!src_repos[@]}"; do [ "${src_repos[$k]}" != "$repo" ] || break; done
    prev=$tmp/prev-$svc-${repo//\//_}
    if ! point=$(git -C "${src_dirs[$k]}" rev-parse --verify -q "$tag^{commit}"); then
      warn "deployment of svp-gitops ${ref:0:12}: the image tag $tag of $svc is no commit of ${src_repos[$k]}"
      continue
    fi
    echo "${src_repos[$k]} $point" >>"$tmp/points-$i"
    if [ -s "$prev" ]; then
      while read -r sha t; do
        [ -n "$sha" ] || continue
        if [ "$repo" != "$code_repo" ] || services_of "$sha" | grep -qx -- "$svc"; then
          change service "$svc" "${src_repos[$k]}" "$sha" "$t"
        fi
      done < <(git -C "${src_dirs[$k]}" log --no-merges --format='%H %ct' --stdin "$point" -- <"$prev")
    fi
    echo "^$point" >>"$prev"
  done
  if cg rev-parse --verify -q "$charts^{commit}" >/dev/null; then
    echo "$code_repo $charts" >>"$tmp/points-$i"
    if [ "$i" -gt 0 ]; then
      while read -r sha t; do
        [ -z "$sha" ] || change chart "" "$code_repo" "$sha" "$t"
      done < <(cg log --no-merges --format='%H %ct' --stdin "$charts" -- "${chart_paths[@]}" <"$tmp/prev-charts")
    fi
    echo "^$charts" >>"$tmp/prev-charts"
  else
    warn "deployment of svp-gitops ${ref:0:12}: its charts revision $charts is no commit of the code repository"
  fi
  if ! gg cat-file -e "$ref^{commit}" 2>/dev/null; then
    warn "deployment of svp-gitops ${ref:0:12}: no such commit in the clone of svp-gitops"
    continue
  fi
  echo "$gitops_repo $ref" >>"$tmp/points-$i"
  if [ "$i" -gt 0 ]; then
    while read -r sha t; do
      [ -z "$sha" ] || change config "" "$gitops_repo" "$sha" "$t"
    done < <(gg log --no-merges --format='%H %ct' --stdin "$ref" -- "${config_paths[@]}" <"$tmp/prev-ref")
    while read -r sha; do
      [ -n "$sha" ] || continue
      while read -r x; do
        [ -n "$x" ] || continue
        if ! full=$(gg rev-parse --verify -q "$x^{commit}"); then
          warn "revert ${sha:0:12} of svp-gitops names $x, which is no commit of the clone"
          continue
        fi
        failed=null
        for ((j = i - 1; j >= 0; j--)); do
          if gg merge-base --is-ancestor "$full" "${refs[j]}" 2>/dev/null; then
            failed=$j
            break
          fi
        done
        jq -c -n --argjson r "$i" --argjson f "$failed" --arg v "$sha" --arg x "$full" \
          '{rollback: $r, failed: $f, revert: $v, reverted: $x}' >>"$tmp/reverts.jsonl"
      done < <(reverted_of "$sha")
    done < <(gg log --format=%H --stdin "$ref" -- <"$tmp/prev-ref")
  fi
  echo "^$ref" >>"$tmp/prev-ref"
done

# --- Postmortems.
# holds K REPOSITORY SHA: true when deployment K holds commit SHA of REPOSITORY.
holds() {
  local repo point dir
  while read -r repo point; do
    [ "$repo" = "$2" ] && dir=$(dir_of_repo "$repo") || continue
    git -C "$dir" merge-base --is-ancestor "$3" "$point" 2>/dev/null && return 0
  done <"$tmp/points-$1"
  return 1
}
for file in "$repo_root"/docs/postmortems/*.md; do
  [ -f "$file" ] || continue
  name=${file#"$repo_root"/}
  [ "${file##*/}" != README.md ] || continue
  if ! front=$(awk 'NR == 1 { if ($0 != "---") exit 1; inside = 1; next }
      inside && $0 == "---" { done = 1; exit } inside { print } END { exit !done }' "$file"); then
    warn "$name has no front matter (env, deployment, started_at, restored_at, fix_commits): left out"
    continue
  fi
  pm=$(sed -E 's/[[:space:]]+#.*$//' <<<"$front" | jq -R -s -c --arg file "$name" "$jq_lib"'
    split("\n") | map(select(test("\\S")) | capture("^(?<k>[a-z_]+):[[:space:]]*(?<v>.*[^[:space:]])?[[:space:]]*$") // {k: "?", v: .})
    | map({key: .k, value: (.v // "")}) | from_entries as $f
    | ($f.fix_commits // "" | capture("^\\[(?<l>.*)\\]$").l // null
       | if . == null then null else split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) end) as $fixes
    | {file: $file, env: ($f.env // ""), deployment: ($f.deployment // ""),
       started_at: (if ($f.started_at // "") == "" then null else $f.started_at end),
       restored_at: (if ($f.restored_at // "") == "" then null else $f.restored_at end),
       fix_commits: ($fixes // []),
       problem: (
         if ($f | has("?")) then "a line is no key: value"
         elif (["stg", "prd", "compose", "k3d"] | index($f.env // "")) == null then "env is not stg, prd, compose or k3d"
         elif (($f.deployment // "") | test("^([0-9a-f]{40}|none)$")) | not then "deployment is not 40 hex or none"
         elif ([$f.started_at, $f.restored_at] | map(select(. != null and . != "") | epoch) | any(. == null)) then
           "started_at or restored_at is no RFC 3339 time"
         elif $fixes == null then "fix_commits is no list [..]"
         elif ($fixes | any(test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[0-9a-f]{40}$") | not)) then
           "a fix commit is not <owner/name>@<40 hex>"
         else null end)}') || fail "read the front matter of $name"
  problem=$(jq -r '.problem // ""' <<<"$pm")
  if [ -n "$problem" ]; then
    warn "$name: $problem: left out"
    continue
  fi
  failed=null
  fixes='[]'
  if [ "$(jq -r .env <<<"$pm")" = stg ] && [ "$(jq -r .deployment <<<"$pm")" != none ]; then
    failed=$(jq --arg r "$(jq -r .deployment <<<"$pm")" '[.[] | select(.ref == $r) | .i] | first // null' <<<"$deps")
    [ "$failed" != null ] || warn "$name names deployment $(jq -r .deployment <<<"$pm"), of which stg has no record that counts"
    while read -r fix; do
      [ -n "$fix" ] || continue
      # A fix commit may name its repository by a former name (a postmortem written before a rename).
      repo=$(ci_repo_current "${fix%@*}") sha=${fix#*@} at=null
      if [ "$repo" = "$code_repo" ]; then
        cg cat-file -e "$sha^{commit}" 2>/dev/null || warn "$name: fix commit $fix is no commit of the code repository"
      elif [ "$repo" = "$gitops_repo" ]; then
        gg cat-file -e "$sha^{commit}" 2>/dev/null || warn "$name: fix commit $fix is no commit of the clone of svp-gitops"
      elif dir=$(dir_of_repo "$repo"); then
        git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || warn "$name: fix commit $fix is no commit of the clone of $repo"
      else
        warn "$name: fix commit $fix is of none of ${src_repos[*]} $gitops_repo"
      fi
      if [ "$failed" != null ]; then
        for ((k = failed + 1; k < n; k++)); do
          if holds "$k" "$repo" "$sha"; then
            at=$k
            break
          fi
        done
      fi
      fixes=$(jq -c --arg c "$fix" --argjson d "$at" '. + [{commit: $c, deployment: $d}]' <<<"$fixes")
    done < <(jq -r '.fix_commits[]' <<<"$pm")
  fi
  jq -c --argjson f "$failed" --argjson x "$fixes" 'del(.problem) + {failed: $f, fixes: $x}' <<<"$pm" >>"$tmp/postmortems.jsonl"
done

# --- Promotes, and the releases merged into envs/stg/images/ that no record holds.
since_split=$(gg log --max-parents=0 --format=%ct "$main" | sort -n | head -n 1)
# --min-parents=1: the first commit of svp-gitops is the import at the split, no promote.
gg log --min-parents=1 --format=%ct "$main" -- envs/stg/images |
  jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)' >"$tmp/promote-stg"
gg log --min-parents=1 --format=%ct "$main" -- envs/prd/images |
  jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)' >"$tmp/promote-prd"
cg log --format='%ct%x09%s' "$main" | awk -F '\t' 'index($2, "chore(release): ") == 1 { print $1 }' |
  jq -R -s -c 'split("\n") | map(select(. != "") | tonumber)' >"$tmp/promote-code"
: >"$tmp/merged"
while read -r sha t; do
  [ -n "$sha" ] || continue
  for svc in "${svp_services[@]}"; do
    content=$(gg show "$sha:envs/stg/images/$svc.yaml" 2>/dev/null) || continue
    repo=$(values_field repository <<<"$content" 2>/dev/null) && digest=$(values_field digest <<<"$content" 2>/dev/null) || continue
    [ -n "$repo" ] && [ -n "$digest" ] || continue
    printf '%s@%s\t%s\t%s\n' "$repo" "$digest" "$sha" "$t" >>"$tmp/merged"
  done
done < <(gg log --reverse --format='%H %ct' "$main" -- envs/stg/images)
awk -F '\t' '!seen[$1]++' "$tmp/merged" |
  jq -R -s -c 'split("\n") | map(select(. != "") | split("\t") | {image: .[0], commit: .[1], merged: (.[2] | tonumber)})' \
    >"$tmp/merged.json"

# --- The metrics. Every list goes to jq as a file: Linux refuses any one argument over 128 KiB.
echo "$deps" >"$tmp/deps.json"
jq -R -s -c 'split("\n") | map(select(. != ""))' "$tmp/warnings" >"$tmp/warnings.json"
metrics_jq='
  def median: sort | length as $n | if $n % 2 == 1 then .[($n - 1) / 2] else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
  def ratio($num; $den; $need): {n: $den, need: $need, numerator: $num, denominator: $den}
    + if $den < $need then {status: "insufficient"} else {status: "ok", value: ($num / $den)} end;
  def med($xs; $need): {n: ($xs | length), need: $need, values: $xs}
    + if ($xs | length) < $need then {status: "insufficient"} else {status: "ok", median: ($xs | median)} end;
  ($now | epoch) as $to
  | $deps[0] as $deps
  | [$reverts[] | select(.failed != null)] as $rv
  | [$pms[] | select(.env == "stg" and .failed != null)] as $pf
  | [([$rv[].failed, $pf[].failed] | unique)[] as $j
      | [$rv[] | select(.failed == $j)] as $r | ([$pf[] | select(.failed == $j)] | first) as $p
      | {deployment: $j, ref: $deps[$j].ref, deployed_at: $deps[$j].deployed_at,
         rollbacks: ($r | map(.rollback) | unique), postmortem: ($p.file // null),
         start: (($p.started_at | epoch) // $deps[$j].t),
         end: (($p.restored_at | epoch)
           // ([$r[].rollback, ($p.fixes[]? | .deployment | select(. != null))] | map($deps[.].t) | min))}] as $failures
  | ([$rv[].rollback] | unique) as $rollbacks
  | ([$pms[] | select(.env == "stg") | .fixes[]? | .deployment | select(. != null)] | unique) as $fixed
  | (($rollbacks + $fixed) | unique) as $rework
  | def window($from):
      [$deps[] | select(.t > $from and .t <= $to) | .i] as $wi
      | def inw: . as $d | any($wi[]; . == $d);
      (($to - $from) / 86400) as $span
      | def count($xs): [$xs[] | select(. > $from and . <= $to)] | length;
      {from: ($from | todate), to: ($to | todate), days: $span,
       deployment_frequency: (if ($deps | length) == 0 then {status: "insufficient", n: 0}
         else {status: "ok", count: ($wi | length), per_week: (($wi | length) / ($span / 7)),
           checks: ([$deps[] | select(.i | inw) | .checks] | add // 0)} end),
       change_lead_time: med([$changes[] | select(.deployment | inw) | $deps[.deployment].t - .committed]; 5),
       change_fail_rate: ratio([$failures[] | select(.deployment | inw)] | length; $wi | length; 10),
       failed_deployment_recovery_time: (med([$failures[] | select((.deployment | inw) and .end != null) | .end - .start]; 5)
         + {not_restored: [$failures[] | select((.deployment | inw) and .end == null) | .ref]}),
       deployment_rework_rate: ratio([$rework[] | select(inw)] | length; $wi | length; 10),
       promotes: {stg: count($promote_stg[0]), prd: count($promote_prd[0]),
         before_split_code_repository: count($promote_code[0])}};
  {
    generated_at: ($to | todate),
    label: "stg lab (a cluster built inside one run of scenario gitops)",
    gitops: $gitops,
    source: "deployment records of stg in \($gitops) that count; git of both repositories; docs/postmortems/",
    days: $days,
    split: ($split | todate),
    stg: {
      windows: {last_days: window($to - $days * 86400), since_split: window($split)},
      deployments: [$deps[] | . as $d | {ref, deployed_at, records, checks,
        images: (.images | map_values("\(.repository)@\(.digest)")), charts,
        rollback: any($rollbacks[]; . == $d.i), failed: any($failures[]; .deployment == $d.i),
        changes: ([$changes[] | select(.deployment == $d.i)] | length)}],
      changes: [$changes[] | . + {deployed_at: $deps[.deployment].deployed_at, lead_time: ($deps[.deployment].t - .committed),
        committed_at: (.committed | todate)} | del(.deployment, .committed)],
      failures: [$failures[] | {ref, deployed_at, postmortem, rollbacks: [.rollbacks[] | $deps[.].ref],
        started_at: (.start | todate), restored_at: (if .end == null then null else .end | todate end),
        recovery: (if .end == null then null else .end - .start end)}],
      reverts_of_undeployed: [$reverts[] | select(.failed == null) | {revert, reverted, in: $deps[.rollback].ref}],
      merged_not_deployed: [$merged[0][] | . as $m
        | select(any($deps[].images[]; "\(.repository)@\(.digest)" == $m.image) | not)
        | {image, commit, merged_at: (.merged | todate)}],
      records_left_out: $skipped
    },
    prd: {status: "no_data", reason: "no record of prd exists before prd runs for real"},
    incidents_not_from_deployments: [$pms[] | select(.env != "stg" or .deployment == "none")
      | {file, env, deployment, started_at, restored_at}],
    warnings: $warnings[0]
  }'
mkdir -p "$(dirname "$out")" || fail "make the directory of $out"
jq -n --arg now "$now" --argjson days "$days" --argjson split "${since_split:-0}" --arg gitops "$gitops_repo" \
  --slurpfile deps "$tmp/deps.json" --slurpfile changes "$tmp/changes.jsonl" --slurpfile reverts "$tmp/reverts.jsonl" \
  --slurpfile pms "$tmp/postmortems.jsonl" --slurpfile skipped "$tmp/skipped.jsonl" \
  --slurpfile promote_stg "$tmp/promote-stg" --slurpfile promote_prd "$tmp/promote-prd" \
  --slurpfile promote_code "$tmp/promote-code" --slurpfile merged "$tmp/merged.json" \
  --slurpfile warnings "$tmp/warnings.json" "$jq_lib$metrics_jq" >"$out.tmp" && mv "$out.tmp" "$out" ||
  fail "compute the metrics into $out"

# --- The summary, in Vietnamese like every document of the project: the numbers of $out, nothing more.
jq -r '
  def num: if . == (. | floor) then tostring else (. * 10 | round / 10 | tostring) end | sub("\\."; ",");
  def dur: if . < 3600 then "\(. / 60 | num) phút" elif . < 172800 then "\(. / 3600 | num) giờ" else "\(. / 86400 | num) ngày" end;
  def date: .[0:16] | sub("T"; " ");
  def short: .[0:12];
  def lacking: "chưa đủ dữ liệu (n = \(.n), cần ≥ \(.need))";
  def freq: if .status == "ok" then "\(.count) (\(.per_week | num)/tuần), \(.checks) lượt kiểm"
    else "chưa đủ dữ liệu: chưa có bản ghi stg nào được tính" end;
  def median_of: if .status == "ok" then "trung vị \(.median | dur) (n = \(.n))"
    elif .n == 0 then lacking else "\(lacking): \(.values | sort | map(dur) | join(", "))" end;
  def rate: if .status == "ok" then "\(.value * 100 | num) % (\(.numerator) / \(.denominator))"
    else "\(lacking): \(.numerator) / \(.denominator)" end;
  def recovery: median_of + (if (.not_restored | length) > 0
    then "; chưa khôi phục: \(.not_restored | map("`\(short)`") | join(", "))" else "" end);
  .stg.windows as $w
  | "## DORA metrics: stg lab (cụm dựng trong một lượt runner)",
    "",
    "Tính lúc \(.generated_at | date) UTC từ bản ghi Deployment `success` của `stg` trên `\(.gitops)`, không từ merge. Không xếp mức Elite/High/Medium/Low.",
    "",
    "| Chỉ số | \(.days) ngày (từ \($w.last_days.from | date)) | Từ khi tách repo (từ \($w.since_split.from | date)) |",
    "| --- | --- | --- |",
    "| Deployment frequency | \($w.last_days.deployment_frequency | freq) | \($w.since_split.deployment_frequency | freq) |",
    "| Change lead time | \($w.last_days.change_lead_time | median_of) | \($w.since_split.change_lead_time | median_of) |",
    "| Change fail rate | \($w.last_days.change_fail_rate | rate) | \($w.since_split.change_fail_rate | rate) |",
    "| Failed deployment recovery time | \($w.last_days.failed_deployment_recovery_time | recovery) | \($w.since_split.failed_deployment_recovery_time | recovery) |",
    "| Deployment rework rate | \($w.last_days.deployment_rework_rate | rate) | \($w.since_split.deployment_rework_rate | rate) |",
    "| prd (mọi chỉ số) | chưa có dữ liệu prd | chưa có dữ liệu prd |",
    "",
    "- Ngưỡng của lab: tỷ lệ cần ≥ 10 deployment trong cửa sổ, trung vị cần ≥ 5 mẫu.",
    "- stg chỉ sống trong một lượt `gitops`: deployment frequency bị trần bởi số lượt đó, lead time gồm cả thời gian chờ tới lượt kế tiếp, change fail rate thấp vì phép kiểm stg chặn lỗi trước khi có bản ghi.",
    "- prd: chưa có dữ liệu prd (chưa có bản ghi prd nào, tới khi prd chạy thật).",
    "",
    "### Tần suất promote (không phải chỉ số DORA)",
    "",
    "| Commit trên `main` | \(.days) ngày | Từ khi tách repo |",
    "| --- | --- | --- |",
    "| `envs/stg/images/` của svp-gitops | \($w.last_days.promotes.stg) | \($w.since_split.promotes.stg) |",
    "| `envs/prd/images/` của svp-gitops | \($w.last_days.promotes.prd) | \($w.since_split.promotes.prd) |",
    "| Trước tách, repo code (`chore(release): …`) | \($w.last_days.promotes.before_split_code_repository) | \($w.since_split.promotes.before_split_code_repository) |",
    "",
    "Commit khởi tạo của svp-gitops (bản nhập lúc tách repo) không phải promote, không đếm.",
    "",
    "### Deployment stg",
    "",
    (if (.stg.deployments | length) == 0 then "Chưa có bản ghi stg nào được tính." else
      "| deployed_at (UTC) | svp-gitops | chart | Bản ghi | Lượt kiểm | Thay đổi mới | Ghi chú |",
      "| --- | --- | --- | --- | --- | --- | --- |",
      (.stg.deployments[] | "| \(.deployed_at | date) | `\(.ref | short)` | `\(.charts | short)` | \(.records | map("#\(.)") | join(", ")) | \(.checks) | \(.changes) | \([if .rollback then "rollback" else empty end, if .failed then "thất bại" else empty end] | join(", ")) |")
    end),
    "",
    "### Đã merge, chưa triển khai (stg)",
    "",
    (if (.stg.merged_not_deployed | length) == 0 then "Không có." else
      (.stg.merged_not_deployed[] | "- `\(.image)` (merge ở `\(.commit | short)` lúc \(.merged_at | date))") end),
    (if (.stg.failures | length) > 0 then "", "### Deployment thất bại", "",
      (.stg.failures[] | "- `\(.ref | short)` (\(.deployed_at | date)): \(if .postmortem then "postmortem `\(.postmortem)`" else "" end)\(if (.rollbacks | length) > 0 then " rollback ở `\(.rollbacks | map(short) | join(", "))`" else "" end); \(if .recovery == null then "chưa khôi phục" else "khôi phục sau \(.recovery | dur)" end)")
    else empty end),
    (if (.stg.reverts_of_undeployed | length) > 0 then "", "### Revert của commit chưa từng triển khai (không tính)", "",
      (.stg.reverts_of_undeployed[] | "- `\(.revert | short)` revert `\(.reverted | short)`, có từ `\(.in | short)`") else empty end),
    "",
    "### Sự cố không do triển khai (không vào chỉ số)",
    "",
    (if (.incidents_not_from_deployments | length) == 0 then "Không có." else
      (.incidents_not_from_deployments[] | "- `\(.file)`: env `\(.env)`, deployment `\(.deployment)`") end),
    (if (.stg.records_left_out | length) > 0 then "", "### Bản ghi bị bỏ", "",
      (.stg.records_left_out[] | "- #\(.id): \(.reason)") else empty end),
    (if (.warnings | length) > 0 then "", "### Cảnh báo", "", (.warnings[] | "- \(.)") else empty end)
' "$out" | ci_summary_tee
ok "wrote $out"
