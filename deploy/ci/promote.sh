#!/usr/bin/env bash
# promote.sh [--source NAME] RELEASES: the job promote of images.yml of release source NAME (backend, this repository,
# when not given; a source of deploy/helm/svp-policy/files/sources.json, whose CI runs this script from a pinned
# checkout of this repository with SVP_CODE_ROOT its own checkout: code_root of common.sh). What changes for another
# source is told at the end of this header; the rest is the run of backend. Promotes to stg in the deployment
# repository svp-gitops: clones
# it, rebuilds the branch bot/promote-stg from its main with the newest release of every service stg does not run yet
# (envs/stg/images/<service>.yaml) and the charts of this run's commit (envs/stg/charts.yaml), pushes it, opens or
# updates its pull request there and turns on auto-merge: svp-gitops merges it once its required check is green, with
# no review, since no code owner owns envs/stg/. Argo CD of stg then deploys it. Nothing is ever written to main of
# either repository, nor to any branch of this one.
#
# RELEASES holds the artifacts release-<service> of the job sign: files repository, tag and digest of each signed
# index. download-artifact puts a single matching artifact straight into RELEASES and several each into a directory of
# its own, so they are found by their digest file wherever they are; none at all is fine (no release in this run: a
# run that changed only the charts, or one whose every signature failed).
#
# Each value is chosen so that stg never goes back. For a service's release the candidates are: stg's on main of
# svp-gitops; that of bot/promote-stg, only while its pull request is open (a merged one is in main already; a closed
# one was given up, and taking it again would bring back what the owner rolled back), and only for the services that
# pull request changes (any other file there is main's value as of the commit the branch was built on: taking it would
# undo a rollback merged on main since); the release this run signed. A candidate's commit is its image.tag, which
# must be a commit of main of this repository; an empty tag means "not released" and loses to any other. The candidate
# whose commit is a descendant of (or the same as) every other's wins: commits are compared by ancestry, never by time,
# so a run re-run late cannot replace a newer release. On the same commit the newest build wins: this run's, then
# bot/promote-stg's, then main's (same code, newer packages such as Alpine's ffmpeg). The charts' revision (the commit
# of this repository whose deploy/helm/* stg runs) is chosen among this run's commit, bot/promote-stg's (same rule)
# and main's by the same ancestry rule, and written with what derives from it, as gitops-check.sh computes it again:
# podSecurityVersion of deploy/helm/svp-cluster/values.yaml and the sha256 of
# deploy/observability/otelcol/k8s-config.yaml at that commit. Every image chosen must be built at or before that
# revision (an image never runs with charts older than its code). A tag that is not a commit of main, candidates none
# of which descends from all the others, or an image newer than the charts leave that value as main has it and fail
# the job, saying why.
#
# The branch is one commit on top of main of svp-gitops, by the bot of the app that writes there (ci_bot_name,
# ci_bot_email of platform.sh), made with git plumbing on a temporary index in a temporary clone: neither the working
# tree nor the index of this checkout changes. It changes envs/stg/images/ and envs/stg/charts.yaml only. It is pushed
# with --force-with-lease on the commit of bot/promote-stg read at the start: a change made since (another run, or the
# owner by hand) fails the push instead of being overwritten. The open pull request is read again after the push: one
# merged or closed in between fails the job (never green with the release on a branch no pull request holds), and a
# run of the job again builds the branch from main as it is then. When nothing differs from main: no push, no pull
# request.
# When bot/promote-stg already holds exactly this on top of main: no push (its check would only run again).
#
# Each source writes only the image files of its own releases: a service whose file on main of svp-gitops names a
# release of another source is left as it is, one line saying so, and is no failure (backend leaves web.yaml alone once
# svp-frontend releases web, even when a run of backend still builds web). Two exceptions, a takeover each, where this
# source writes the file while main still names another's release (its first release, a line "takeover" naming the
# old source), and main's release is no candidate then (its tag may be a commit of another repository):
#   - the move of a service from backend to another source (a run of another source over a release of backend);
#   - a release of a retired source (one without promoter in the table: its repository was renamed) that publishes the
#     service, taken over by the run of the source that publishes it now, in either mode: backend still compares its
#     releases with the charts. A retired source's release is never written back, and no run is a retired source's
#     (--source of one fails).
# A file that changes source gets, instead of the first sentence of its comment, the sentence of the new source (its
# repository and the workflow that built and signed it); the rest of the comment is kept, its first paragraph wrapped
# again around the new sentence. The comments of envs/stg/charts.yaml are kept, with the URL of a renamed repository
# replaced by that of its current name (current_repo_urls of common.sh).
# A repository under the prefix of no source is a failure, never a guess.
# Another source: its releases are under its imagePrefix; its branch is bot/promote-stg-<NAME>, its bot that of its
# promoter (the app of its own credential), so the pull requests of two sources never touch each other's branch;
# commits are those of main of its own repository (code_root); envs/stg/charts.yaml is neither read nor written (the
# charts are backend's, and their revision is no commit of that repository), so no release is compared with it.
#
# promote.sh --header SERVICE ENV SOURCE: prints the image file read on stdin with the first sentence of its comment
# that of release source SOURCE for SERVICE in ENV, as a promote writes it when the file changes source
# (deploy/ci/promote-prd.sh uses it too).
#
# Environment: the CI platform's own (the link to this run, the code repository's address: ci_run_url, ci_repo_url of
# platform.sh) and the token of the app, which may write to svp-gitops alone (GH_TOKEN on GitHub): pull requests and
# auto-merge through ci_change_request_*, the push through ci_git_auth. A machine writes no pull request: it prints the
# command instead. PROMOTE_DRY_RUN=1 does the same in CI, and takes the open pull requests of bot/promote-stg from
# PROMOTE_DRY_RUN_PRS, as ci_change_request_list prints them (empty: none). PROMOTE_GITOPS_URL replaces the address of
# svp-gitops, for trying the script on a scratch repository. git runs for real either way, with one limit: a machine
# pushes only to a repository on its own disk. svp-gitops's bot/promote-stg is the branch of the pull request CI keeps
# up to date: a push from a machine would put new commits under that pull request's title and body, which only CI
# writes. So when the address of svp-gitops is another (https, ssh, host:path) a machine refuses before reading
# anything, and with PROMOTE_DRY_RUN=1 prints the push instead of running it.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

usage="usage: promote.sh [--source NAME] RELEASES | promote.sh --header SERVICE ENV SOURCE"

# image_header SERVICE ENV SOURCE: see --header above. The first paragraph of the comment at the top of the file (its
# "#" lines up to the first empty one, "#" alone) is written again, wrapped at 118 characters, with its first sentence
# (up to its first ". ", or "." at its end; the whole paragraph when it has none) replaced and the words of the rest
# kept; every later line is kept as it is. A file without such a comment gets the sentence on top.
image_header() {
  local src repo subject workflow sentence
  src=$(release_source "$3") || exit 1
  repo=$(jq -r .repository <<<"$src")
  subject=$(jq -r .subject <<<"$src")
  workflow=${subject#"$repo"/}
  workflow=${workflow%@*}
  sentence="The release image of $1 in $2, nothing else: the release on GHCR that CI of $repo built, scanned and signed ($workflow there)."
  awk -v sentence="$sentence" '
    function wrap(text,   n, i, w, line, out) {
      n = split(text, w, " ")
      line = "#"
      for (i = 1; i <= n; i++) {
        if (w[i] == "") continue
        if (line != "#" && length(line) + 1 + length(w[i]) > 118) { out = out line "\n"; line = "#" }
        line = line " " w[i]
      }
      return out line "\n"
    }
    function flush(   rest) {
      rest = ""
      if (match(para, /\.( |$)/)) rest = substr(para, RSTART + RLENGTH)
      printf "%s", wrap(sentence " " rest)
      done = 1
    }
    !done && /^#/ && !/^# *$/ { text = substr($0, 2); sub(/^ /, "", text); para = para " " text; next }
    !done { flush() }
    { print }
    END { if (!done) flush() }'
}

if [ "${1:-}" = --header ]; then
  [ $# -eq 4 ] || fail "$usage"
  image_header "$2" "$3" "$4"
  exit 0
fi
source=backend
if [ "${1:-}" = --source ]; then
  [ $# -eq 3 ] || fail "$usage"
  source=$2
  shift 2
fi
[ $# -eq 1 ] || fail "$usage"
releases=$1
source_json=$(active_source "$source") || exit 1
prefix=$(jq -r .imagePrefix <<<"$source_json")
app=$(jq -r .promoter <<<"$source_json")
src_services=$(jq -r '.services[]' <<<"$source_json")
# backend holds the charts: only its run writes envs/stg/charts.yaml, and compares its releases with them.
charts_owner=
[ "$source" != backend ] || charts_owner=yes
branch=$gitops_promote_branch
[ -n "$charts_owner" ] || branch=$gitops_promote_branch-$source
images_dir=envs/stg/images
charts_file=envs/stg/charts.yaml
url=${PROMOTE_GITOPS_URL:-$gitops_url}
dry=${PROMOTE_DRY_RUN:-}
platform=$(ci_platform) || exit 1

# push: empty when this run must not push (a machine with an address off its disk in a dry run; see the top of this
# file). check_on_disk URLS: applies that rule to each line of URLS, the address of svp-gitops before anything is read,
# then every push URL git would really use (pushInsteadOf applied, never printed: one may hold a token).
push=yes
check_on_disk() {
  local u
  [ "$platform" = local ] || return 0
  while IFS= read -r u; do
    case $u in
    /* | ./* | ../* | file://*) ;;
    *)
      [ -n "$dry" ] || fail "svp-gitops is not a repository on this machine's disk: only CI pushes $branch there, since its pull request belongs to CI. PROMOTE_DRY_RUN=1 runs everything else and prints the push, the pull request and its auto-merge"
      push=
      ;;
    esac
  done <<<"$1"
}
check_on_disk "$url"
run_url=$(ci_run_url) && code_url=$(ci_repo_url) && bot_name=$(ci_bot_name "$app") &&
  bot_email=$(ci_bot_email "$app") && auth_opts=$(ci_git_auth) || exit 1
# auth: git options of the push, one -c per line of ci_git_auth.
auth=()
while IFS= read -r opt; do [ -z "$opt" ] || auth+=(-c "$opt"); done <<<"$auth_opts"

# git_: git in the repository of the code this source releases.
git_() { git -C "$code_root" "$@"; }
tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
gitops=$tmp/svp-gitops
# gg: git in the clone of svp-gitops. Never a prompt for a credential: a push without one fails.
gg() { GIT_TERMINAL_PROMPT=0 git -C "$gitops" "$@"; }
# is_ancestor A B: true when commit A of this repository is B or one of B's ancestors.
is_ancestor() { git_ merge-base --is-ancestor "$1" "$2"; }
# put KIND SERVICE VALUE / get KIND SERVICE: one variable per kind and service (bash 3.2 has no associative arrays).
put() { printf -v "${1}_${2//-/_}" '%s' "$3"; }
get() {
  local var="${1}_${2//-/_}"
  echo "${!var:-}"
}
write=(ci_change_request_write)
merge=(ci_change_request_auto_merge)
[ -z "$dry" ] || write+=(--dry-run) merge+=(--dry-run)

# --- this run's releases: "repository|tag|digest" in new_<service>. "|" never occurs in a value (values_field), and
# unlike a blank it keeps an empty field in its place when read back.
if [ -d "$releases" ]; then
  while IFS= read -r file; do
    dir=$(dirname "$file")
    if ! { r=$(cat "$dir/repository") && t=$(cat "$dir/tag") && d=$(cat "$dir/digest"); }; then
      fail "$dir: a release needs the files repository, tag and digest"
    fi
    svc=${r#"$prefix"}
    if ! grep -qxF -- "$svc" <<<"$src_services" || [ "$r" != "$prefix$svc" ]; then
      fail "$dir: $r is not the repository of a service of release source $source ($prefix<service>)"
    fi
    [[ $t =~ ^[0-9a-f]{12}$ ]] || fail "$dir: tag '$t' is not the 12 hex digits of a commit"
    is_digest "$d" || fail "$dir: digest '$d' is not sha256:<64 hex>"
    [ -z "$(get new "$svc")" ] || fail "$releases holds two releases of $svc"
    put new "$svc" "$r|$t|$d"
  done < <(find "$releases" -type f -name digest | sort)
fi

# --- main of this repository and this run's commit, the charts this run would have stg run.
git_ fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" || fail "fetch main of this repository"
main=$(git_ rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") || fail "origin/main is not a commit"
run_commit=$(ci_commit) && run_commit=$(git_ rev-parse --verify --quiet "$run_commit^{commit}") ||
  fail "this run's commit is not in this clone"
is_ancestor "$run_commit" "$main" || fail "this run's commit ${run_commit:0:12} is not on main of this repository"

# --- svp-gitops as it is now: its main, and bot/promote-stg, whose commit read here is the lease of the push. An
# anonymous clone: the token is handed to the push alone.
GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --quiet --no-tags "$url" "$gitops" 2>"$tmp/clone.err" || {
  cat "$tmp/clone.err" >&2
  fail "clone svp-gitops"
}
push_urls=$(gg remote get-url --push --all origin) || fail "the clone of svp-gitops has no remote origin"
check_on_disk "$push_urls"
gmain=$(gg rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") || fail "svp-gitops has no branch main"
lease=$(gg rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") || lease=

if [ -n "$dry" ]; then
  prs=${PROMOTE_DRY_RUN_PRS:-[]}
else
  prs=$(ci_change_request_list "$branch" main "$gitops_repo") ||
    fail "ask the repository's host whether the pull request of $branch is open in $gitops_repo"
fi
pr=$(ci_change_request_pick "$app" <<<"$prs") || fail "read the open pull requests of $branch"
[[ $pr =~ ^[0-9]*$ ]] || fail "unexpected pull request number '$pr'"
use_bot=
if [ -n "$pr" ] && [ -n "$lease" ]; then
  use_bot=yes
  # What the pull request is compared with: the commit of main bot/promote-stg was built on, or a newer one once main
  # was merged into it ("Update branch" on GitHub).
  bot_base=$(gg merge-base "$gmain" "$lease") || fail "$branch shares no history with main of svp-gitops"
fi
state="no open pull request"
[ -z "$pr" ] || state="pull request #$pr open"
echo "svp-gitops main ${gmain:0:12}; $branch ${lease:-absent}${lease:+ ($state)}; this run ${run_commit:0:12}"

# bot_changes FILE: true when the open pull request changes FILE (see the top of this file); status 2 when that
# cannot be told.
bot_changes() {
  local rc=0
  [ -n "$use_bot" ] || return 1
  gg diff --quiet "$bot_base" "$lease" -- "$1" || rc=$?
  case $rc in
  0) return 1 ;;
  1) return 0 ;;
  *) return 2 ;;
  esac
}

# release_at REF SERVICE: prints "repository|tag|digest" of SERVICE's image file of stg at REF of svp-gitops (each may
# be empty).
release_at() {
  local content r t d
  content=$(gg show "$1:$images_dir/$2.yaml") || return 1
  r=$(values_field repository <<<"$content") && t=$(values_field tag <<<"$content") &&
    d=$(values_field digest <<<"$content") || return 1
  echo "$r|$t|$d"
}

# revision_at REF: prints the revision of stg's charts.yaml at REF of svp-gitops.
revision_at() {
  local content
  content=$(gg show "$1:$charts_file") || return 1
  sed -n 's/^revision: *//p' <<<"$content"
}

# commit_of TAG: prints the commit of main whose first 12 hex digits are TAG (or the full commit TAG).
commit_of() {
  local c
  c=$(git_ rev-parse --verify --quiet "$1^{commit}") && is_ancestor "$c" "$main" && echo "$c"
}

# newest COMMIT...: prints the index of the first COMMIT that every other is an ancestor of (or equal to); status 1
# when none descends from all the others.
newest() {
  local commits=("$@") i j ok
  for i in "${!commits[@]}"; do
    ok=yes
    for j in "${!commits[@]}"; do
      is_ancestor "${commits[$j]}" "${commits[$i]}" || ok=
    done
    if [ -n "$ok" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# choose SERVICE: sets choice to the winning "repository|tag|digest" of SERVICE and choice_from to where it comes
# from; returns 1 (with the reason in problem) when no candidate can be trusted to be the newest. With takeover set,
# main's release (another source's) is no candidate.
choose() {
  local svc=$1 src cand r t d c i rc sources=() values=() commits=()
  problem=
  for src in new bot main; do
    case $src in
    new) cand=$(get new "$svc") ;;
    bot)
      rc=0
      bot_changes "$images_dir/$svc.yaml" || rc=$?
      case $rc in
      0) ;;
      1) continue ;;
      *)
        problem="its image file on $branch cannot be compared with main"
        return 1
        ;;
      esac
      cand=$(release_at "$lease" "$svc") || {
        problem="its image file on $branch cannot be read"
        return 1
      }
      ;;
    main)
      [ -z "$takeover" ] || continue
      cand=$(get main "$svc")
      ;;
    esac
    [ -n "$cand" ] || continue
    IFS="|" read -r r t d <<<"$cand"
    [ -n "$t" ] || continue
    if [ "$src" != main ] && { [ "$r" != "$prefix$svc" ] || ! is_digest "$d"; }; then
      problem="its release on $src ($r tag $t digest ${d:-none}) is not a release of $prefix$svc"
      return 1
    fi
    c=$(commit_of "$t") || {
      problem="tag $t of its release on $src is not a commit of main of this repository; not guessing what it is"
      return 1
    }
    sources+=("$src")
    values+=("$r|$t|$d")
    commits+=("$c")
  done
  choice=$(get main "$svc")
  choice_from=main
  [ ${#sources[@]} -gt 0 ] || return 0
  i=$(newest "${commits[@]}") || {
    problem="none of the commits of its candidates (${sources[*]}: ${commits[*]}) descends from all the others"
    return 1
  }
  choice=${values[$i]}
  choice_from=${sources[$i]}
}

failed=0
# --- the charts (backend only): this run's commit, bot/promote-stg's revision when its pull request changes
# charts.yaml, main's.
if [ -n "$charts_owner" ]; then
  main_rev=$(revision_at "$gmain") && [[ $main_rev =~ ^[0-9a-f]{40}$ ]] ||
    fail "$charts_file on main of svp-gitops names no revision (a full commit of this repository)"
  main_rev_commit=$(commit_of "$main_rev") ||
    fail "$charts_file on main of svp-gitops: revision ${main_rev:0:12} is not a commit of main of this repository"
  rev_sources=(new)
  rev_commits=("$run_commit")
  rc=0
  bot_changes "$charts_file" || rc=$?
  case $rc in
  0)
    bot_rev=$(revision_at "$lease") && [[ $bot_rev =~ ^[0-9a-f]{40}$ ]] && bot_rev=$(commit_of "$bot_rev") ||
      fail "$charts_file on $branch: its revision is not a commit of main of this repository; not guessing what it is"
    rev_sources+=(bot)
    rev_commits+=("$bot_rev")
    ;;
  1) ;;
  *) fail "$charts_file on $branch cannot be compared with main" ;;
  esac
  rev_sources+=(main)
  rev_commits+=("$main_rev_commit")
  if i=$(newest "${rev_commits[@]}"); then
    revision=${rev_commits[$i]}
    revision_from=${rev_sources[$i]}
  else
    echo "FAIL  charts: none of the revisions of their candidates (${rev_sources[*]}: ${rev_commits[*]}) descends from all the others; left as main has it" >&2
    ci_summary "- charts: **not promoted**: none of the revisions of their candidates descends from all the others"
    revision=$main_rev_commit
    revision_from=main
    failed=1
  fi
fi

# --- the tree: main's of svp-gitops, with every service whose choice differs from main and the charts' revision.
export GIT_INDEX_FILE=$tmp/index
gg read-tree "$gmain" || fail "read the tree of main of svp-gitops"
changed=()
for svc in $src_services; do
  line=$(release_at "$gmain" "$svc") || fail "the image file of $svc on main of svp-gitops cannot be read (above)"
  put main "$svc" "$line"
  # Whose release main names: this source's, one this source takes over (backend's, or a retired source's of this
  # service), or another's, left alone.
  IFS="|" read -r r t d <<<"$line"
  owner=$(source_of_repository "$r" 2>/dev/null) ||
    fail "$svc: main of svp-gitops names $r, under the prefix of no release source; not guessing whose it is"
  takeover=
  if [ "$owner" != "$source" ]; then
    owner_json=$(release_source "$owner") || exit 1
    if ! jq -e 'has("promoter")' <<<"$owner_json" >/dev/null &&
      jq -e --arg s "$svc" '.services | index($s)' <<<"$owner_json" >/dev/null; then
      echo "takeover: $svc.yaml on main is $r:$t (source $owner, retired); first release of source $source"
    elif [ -z "$charts_owner" ] && [ "$owner" = backend ]; then
      echo "takeover: $svc.yaml on main is $r:$t (source $owner); first release of source $source"
    else
      echo "ok    $svc: released by source $owner (main's $r:$t), left as it is"
      continue
    fi
    takeover=yes
  fi
  if ! choose "$svc"; then
    echo "FAIL  $svc: $problem; left as main has it" >&2
    ci_summary "- $svc: **not promoted**: $problem"
    failed=1
    choice=$line
  fi
  IFS="|" read -r r t d <<<"$choice"
  # Never an image newer than the charts: gitops-check.sh refuses that tree. (Main's own already passed that check.)
  # Another source's releases are not compared with the charts.
  if [ -n "$charts_owner" ] && [ "$choice" != "$line" ] && ! is_ancestor "$(commit_of "$t")" "$revision"; then
    echo "FAIL  $svc: its release $t is newer than the charts' revision ${revision:0:12}; left as main has it" >&2
    ci_summary "- $svc: **not promoted**: its release $t is newer than the charts' revision ${revision:0:12}"
    failed=1
    choice=$line
  fi
  if [ "$choice" = "$line" ]; then
    echo "ok    $svc: main's ($line) stays"
    continue
  fi
  file=$images_dir/$svc.yaml
  header=(cat)
  [ -z "$takeover" ] || header=(image_header "$svc" stg "$source")
  blob=$(gg show "$gmain:$file" | values_set_image "$r" "$t" "$d" | "${header[@]}" | gg hash-object -w --stdin) ||
    fail "write the release of $svc into $file"
  gg update-index --cacheinfo "100644,$blob,$file" || fail "stage $file in the temporary index"
  changed+=("$svc")
  put chosen "$svc" "$choice"
  echo "ok    $svc: $r:$t@$d (from $choice_from)"
done
charts_changed=
if [ -n "$charts_owner" ]; then
  psv=$(git_ show "$revision:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p') &&
    [ -n "$psv" ] || fail "deploy/helm/svp-cluster/values.yaml at ${revision:0:12} pins no podSecurityVersion"
  collector=$(git_ show "$revision:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1) &&
    [[ $collector =~ ^[0-9a-f]{64}$ ]] || fail "hash deploy/observability/otelcol/k8s-config.yaml at ${revision:0:12}"
  # Main's file with its three lines replaced, every other line (the comments) kept, a renamed repository's URL in
  # them made its current one.
  charts=$(gg show "$gmain:$charts_file" | current_repo_urls | awk -v rev="$revision" -v psv="$psv" -v sha="$collector" '
    /^revision:/ { n["r"]++; print "revision: " rev; next }
    /^podSecurityVersion:/ { n["p"]++; print "podSecurityVersion: " psv; next }
    /^collectorConfigSha256:/ { n["c"]++; print "collectorConfigSha256: " sha; next }
    { print }
    END { if (n["r"] != 1 || n["p"] != 1 || n["c"] != 1) exit 3 }') ||
    fail "$charts_file on main of svp-gitops must hold revision, podSecurityVersion and collectorConfigSha256 once each"
  blob=$(printf '%s\n' "$charts" | gg hash-object -w --stdin) || fail "write $charts_file"
  gg update-index --cacheinfo "100644,$blob,$charts_file" || fail "stage $charts_file in the temporary index"
  if [ "$blob" != "$(gg rev-parse "$gmain:$charts_file")" ]; then
    charts_changed=yes
    echo "ok    charts: ${revision:0:12} (from $revision_from), podSecurityVersion $psv, collectorConfigSha256 ${collector:0:12}…"
  else
    echo "ok    charts: main's ${revision:0:12} stays"
  fi
fi
tree=$(gg write-tree) || fail "write the tree"
unset GIT_INDEX_FILE

if [ "$tree" = "$(gg rev-parse "$gmain^{tree}")" ]; then
  echo "Nothing differs from main of svp-gitops: no push, no pull request."
  ci_summary "Promote: stg on \`$branch\` would be what main of svp-gitops already runs; nothing pushed."
  exit "$failed"
fi

# --- title, commit message and pull request body. The tag in the title is the newest commit of the release.
newest_tag=
for svc in ${changed[@]+"${changed[@]}"}; do
  IFS="|" read -r r t d <<<"$(get chosen "$svc")"
  if [ -z "$newest_tag" ] || is_ancestor "$(commit_of "$newest_tag")" "$(commit_of "$t")"; then newest_tag=$t; fi
done
if [ ${#changed[@]} -gt 0 ]; then
  title="chore(stg): phát hành ${changed[*]} $newest_tag"
else
  title="chore(stg): chart ${revision:0:12}"
fi
{
  echo "$title"
  echo
  for svc in ${changed[@]+"${changed[@]}"}; do
    IFS="|" read -r r t d <<<"$(get chosen "$svc")"
    echo "- $svc: $r:$t@$d"
  done
  [ -z "$charts_changed" ] || echo "- charts: $revision"
  echo
  echo "Code: $code_url/commit/$run_commit"
  echo "Run: $run_url"
} >"$tmp/message"
{
  if [ -n "$charts_owner" ]; then
    echo "Promote lên stg, do job \`promote\` của \`images.yml\` ở repo code ghi: chỉ \`$images_dir/\` và \`$charts_file\`."
    echo "Nhánh \`$branch\` được dựng lại từ \`main\` mỗi lần, gom bản mới nhất (theo lịch sử commit của repo code) của"
    echo "mọi service chưa merge và chart của commit mới nhất."
  else
    echo "Promote lên stg của nguồn phát hành \`$source\`, do job \`promote\` của \`images.yml\` ở $code_url ghi: chỉ file"
    echo "image của service thuộc nguồn này trong \`$images_dir/\`, không bao giờ \`$charts_file\`. Nhánh \`$branch\` được dựng"
    echo "lại từ \`main\` mỗi lần, gom bản mới nhất (theo lịch sử commit của repo đó) của mọi service chưa merge."
  fi
  echo
  if [ ${#changed[@]} -gt 0 ]; then
    echo "| Service | Tag (commit) | Digest |"
    echo "| --- | --- | --- |"
    for svc in "${changed[@]}"; do
      IFS="|" read -r r t d <<<"$(get chosen "$svc")"
      echo "| \`$svc\` | \`$t\` | \`$d\` |"
    done
    echo
  fi
  if [ -n "$charts_changed" ]; then
    echo "Chart: \`revision\` $code_url/commit/$revision, \`podSecurityVersion\` \`$psv\`,"
    echo "\`collectorConfigSha256\` \`$collector\`."
    echo
  fi
  echo "Commit repo code của lượt chạy: $code_url/commit/$run_commit"
  echo "Lượt chạy: $run_url"
  echo
  echo "Auto-merge bật: merge khi check \`gitops-ok\` xanh, không cần duyệt (\`envs/stg/\` không có code owner)."
  echo "Sau merge Argo CD của stg đồng bộ trong khoảng 60 s (tệ nhất ~120 s)."
} >"$tmp/body"

# listed_pr: asks the host again for the open pull request of $branch and prints its number when this source's app
# opened it (each source's pull request is its own app's), or nothing.
listed_pr() {
  local list
  list=$(ci_change_request_list "$branch" main "$gitops_repo") && ci_change_request_pick "$app" <<<"$list"
}

# --- push, unless bot/promote-stg already holds exactly this tree on top of main.
if [ -n "$lease" ] && [ "$(gg rev-parse "$lease^{tree}")" = "$tree" ] &&
  [ "$(gg rev-list --parents -n 1 "$lease")" = "$lease $gmain" ]; then
  echo "ok    $branch already holds this on top of main ${gmain:0:12}: not pushed again"
  head=$lease
else
  head=$(GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_NAME=$bot_name \
    GIT_COMMITTER_EMAIL=$bot_email gg commit-tree "$tree" -p "$gmain" -F "$tmp/message") || fail "commit"
  # An empty lease: the branch must not exist yet.
  lease_arg="refs/heads/$branch:$lease"
  if [ -z "$push" ]; then
    printf 'dry run: git push --quiet --force-with-lease=%q origin %q\n' "$lease_arg" "$head:refs/heads/$branch"
  else
    gg ${auth[@]+"${auth[@]}"} push --quiet --force-with-lease="$lease_arg" origin "$head:refs/heads/$branch" ||
      fail "push $branch to svp-gitops: it is no longer at ${lease:-<none>} as read at the start (another run, or a change by hand), or the push was refused; nothing was overwritten. Run the job again to rebuild it from what is there now"
    echo "ok    pushed $branch ${head:0:12} (on main ${gmain:0:12} of svp-gitops)"
    # The pull request read at the start may have been merged (auto-merge) or closed since, the push then landing on a
    # branch no open pull request holds; editing it and turning on its auto-merge would still succeed. Read it again.
    if [ -n "$pr" ] && [ -z "$dry" ]; then
      now_pr=$(listed_pr) ||
        fail "ask the repository's host again whether pull request #$pr of $branch is open in $gitops_repo"
      [ "$now_pr" = "$pr" ] ||
        fail "pull request #$pr of $branch in $gitops_repo was merged or closed between the start of this run and its push, so $branch now holds ${head:0:12} with no open pull request. Run the job again: it builds $branch again from main of svp-gitops as it is now and opens a new pull request"
    fi
  fi
fi

"${write[@]}" "$pr" "$branch" main "$title" "$tmp/body" "$gitops_repo" ||
  fail "open or update the pull request of $branch in $gitops_repo"
# Where the pull request is only printed, so is its body.
[ -z "$dry" ] && [ "$platform" != local ] || sed 's/^/dry run: body | /' "$tmp/body"
# Auto-merge needs the number of the pull request: a new one is listed again (a machine, which opened none, and a dry
# run name it by its branch).
selector=$pr
if [ -z "$selector" ]; then
  if [ -z "$dry" ] && [ "$platform" != local ]; then
    selector=$(listed_pr) && [ -n "$selector" ] ||
      fail "the pull request of $branch just opened in $gitops_repo is not listed"
  else
    selector=$branch
  fi
fi
"${merge[@]}" "$selector" "$head" "$gitops_repo" ||
  fail "turn on auto-merge of the pull request of $branch in $gitops_repo (head ${head:0:12})"
ci_summary "Promote: \`$branch\` of $gitops_repo at ${head:0:12}, auto-merge on: $title"
exit "$failed"
