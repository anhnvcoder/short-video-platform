#!/usr/bin/env bash
# promote.sh RELEASES: the job promote of images.yml. Rebuilds the
# branch bot/promote from origin/main with the newest release of every service that main does not run yet, pushes it
# and opens or updates its pull request. The owner reads it, approves its workflow runs, and merges it; Argo CD then
# deploys the digests. Nothing is ever written to main.
#
# RELEASES holds the artifacts release-<service> of the job sign: files repository, tag and digest of each signed
# index. download-artifact puts a single matching artifact straight into RELEASES and several each into a directory of
# its own, so they are found by their digest file wherever they are; none at all is fine (no release in this run).
#
# Each service's value is chosen so that a release never goes back. Candidates: main's values; those
# of bot/promote, only while its pull request is open (a merged one is in main already; a closed one was given up, and
# taking it again would bring back what the owner rolled back), and only for the services that pull request changes
# (any other file there is main's value as of the commit the branch was built on: taking it would undo a rollback
# merged on main since); the release this run signed. A candidate's commit is its image.tag, which must be a commit
# of main; an empty tag means "not released" and loses to any other. The candidate whose commit is a descendant of (or
# the same as) every other's wins: commits are compared by ancestry, never by time, so a run re-run late cannot replace
# a newer release. On the same commit the newest build wins: this run's, then bot/promote's, then main's (same code,
# newer packages such as Alpine's ffmpeg). A tag that is not a commit of main, or candidates none of which descends
# from all the others, leave the service as main has it and fail the job, saying why.
#
# The branch is one commit on top of origin/main, by the CI platform's bot (ci_bot_name, ci_bot_email of platform.sh),
# made with git plumbing on a temporary index: neither the working tree nor the index of the checkout changes, so this
# run keeps running its own scripts. It is pushed with --force-with-lease on the commit of bot/promote read at the
# start: a change made since (another run, or the owner by hand) fails the push instead of being overwritten. When
# nothing differs from main: no push, no pull request. When bot/promote already holds exactly this on top of main: no
# push (each push makes the owner approve the pull request's workflow runs again).
#
# Environment: the CI platform's own (the repository, the link to this run: ci_repo, ci_run_url of platform.sh) and the
# token its pull requests are written with (GH_TOKEN on GitHub). A machine writes no pull request: it prints the
# command instead. PROMOTE_DRY_RUN=1 does the same in CI, and takes the open pull requests of bot/promote from
# PROMOTE_DRY_RUN_PRS, as ci_change_request_list prints them (empty: none): for trying the script on a scratch
# repository. git runs for real either way, with one limit: a machine pushes bot/promote only to an origin on its own
# disk (the scratch repository of a test). The real origin's bot/promote is the branch of the release pull request CI
# keeps up to date: a push from a machine would put new commits under that pull request's title and body, which only
# CI writes. So when any push URL of origin is another (https, ssh, host:path) a machine refuses before reading
# anything, and with PROMOTE_DRY_RUN=1 prints the push instead of running it.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -eq 1 ] || fail "usage: promote.sh RELEASES"
releases=$1
branch=bot/promote
values_dir=deploy/k8s/values/services
dry=${PROMOTE_DRY_RUN:-}
run_url=$(ci_run_url) && bot_name=$(ci_bot_name) && bot_email=$(ci_bot_email) && platform=$(ci_platform) || exit 1

git_() { git -C "$repo_root" "$@"; }

# push: empty when this run must not push (a machine, an origin off this machine, a dry run; see the top of this
# file). The URLs are git's own, with insteadOf and pushInsteadOf applied, and are never printed: one may hold a token.
# Every push URL is checked, not only the first: git push origin pushes to each of them (every remote.origin.pushurl,
# or every remote.origin.url when there is none), so one off the disk among them is enough to refuse.
push=yes
if [ "$platform" = local ]; then
  origin_urls=$(git_ remote get-url --push --all origin) || fail "this clone has no remote origin"
  while IFS= read -r origin_url; do
    case $origin_url in
    /* | ./* | ../* | file://*) ;;
    *)
      [ -n "$dry" ] || fail "origin is not a repository on this machine's disk: only CI pushes $branch there, since its pull request belongs to CI. PROMOTE_DRY_RUN=1 runs everything else and prints the push and the pull request"
      push=
      ;;
    esac
  done <<<"$origin_urls"
fi
# is_ancestor A B: true when commit A is B or one of B's ancestors.
is_ancestor() { git_ merge-base --is-ancestor "$1" "$2"; }
# put KIND SERVICE VALUE / get KIND SERVICE: one variable per kind and service (bash 3.2 has no associative arrays).
put() { printf -v "${1}_${2//-/_}" '%s' "$3"; }
get() {
  local var="${1}_${2//-/_}"
  echo "${!var:-}"
}
# write: opens or updates the pull request, or in a dry run prints the command it would run.
write=(ci_change_request_write)
[ -z "$dry" ] || write+=(--dry-run)

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# --- this run's releases: "repository|tag|digest" in new_<service>. "|" never occurs in a value (values_field), and
# unlike a blank it keeps an empty field in its place when read back.
if [ -d "$releases" ]; then
  while IFS= read -r file; do
    dir=$(dirname "$file")
    if ! { r=$(cat "$dir/repository") && t=$(cat "$dir/tag") && d=$(cat "$dir/digest"); }; then
      fail "$dir: a release needs the files repository, tag and digest"
    fi
    svc=${r#"$ghcr_prefix"/}
    if ! printf '%s\n' "${svp_services[@]}" | grep -qxF -- "$svc" || [ "$r" != "$ghcr_prefix/$svc" ]; then
      fail "$dir: $r is not the repository of one of the seven services"
    fi
    [[ $t =~ ^[0-9a-f]{12}$ ]] || fail "$dir: tag '$t' is not the 12 hex digits of a commit"
    is_digest "$d" || fail "$dir: digest '$d' is not sha256:<64 hex>"
    [ -z "$(get new "$svc")" ] || fail "$releases holds two releases of $svc"
    put new "$svc" "$r|$t|$d"
  done < <(find "$releases" -type f -name digest | sort)
fi

# --- main and bot/promote as they are now. The commit of bot/promote read here is the lease of the push.
git_ fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" || fail "fetch main"
main=$(git_ rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") || fail "origin/main is not a commit"
lease=
rc=0
git_ ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null || rc=$?
case $rc in
0)
  git_ fetch --quiet --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch" || fail "fetch $branch"
  lease=$(git_ rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") || fail "$branch is not a commit"
  ;;
2) ;; # the branch does not exist: the push must create it, and finds it missing
*) fail "list the branches of origin" ;;
esac

if [ -n "$dry" ]; then
  prs=${PROMOTE_DRY_RUN_PRS:-[]}
else
  prs=$(ci_change_request_list "$branch" main) ||
    fail "ask the repository's host whether the pull request of $branch is open"
fi
pr=$(ci_change_request_pick <<<"$prs") || fail "read the open pull requests of $branch"
[[ $pr =~ ^[0-9]*$ ]] || fail "unexpected pull request number '$pr'"
use_bot=
if [ -n "$pr" ] && [ -n "$lease" ]; then
  use_bot=yes
  # What the pull request is compared with: the commit of main bot/promote was built on, or a newer one once main was
  # merged into it ("Update branch" on GitHub).
  bot_base=$(git_ merge-base "$main" "$lease") || fail "$branch shares no history with main"
fi
state="no open pull request"
[ -z "$pr" ] || state="pull request #$pr open"
echo "main ${main:0:12}; $branch ${lease:-absent}${lease:+ ($state)}"

# release_at REF SERVICE: prints "repository|tag|digest" of SERVICE's values file at REF (each may be empty).
release_at() {
  local content r t d
  content=$(git_ show "$1:$values_dir/$2.yaml") || return 1
  r=$(values_field repository <<<"$content") && t=$(values_field tag <<<"$content") &&
    d=$(values_field digest <<<"$content") || return 1
  echo "$r|$t|$d"
}

# commit_of TAG: prints the commit of main whose first 12 hex digits are TAG.
commit_of() {
  local c
  c=$(git_ rev-parse --verify --quiet "$1^{commit}") && is_ancestor "$c" "$main" && echo "$c"
}

# choose SERVICE: sets choice to the winning "repository|tag|digest" of SERVICE and choice_from to where it comes
# from; returns 1 (with the reason in problem) when no candidate can be trusted to be the newest.
choose() {
  local svc=$1 src cand r t d c i j ok rc sources=() values=() commits=()
  problem=
  for src in new bot main; do
    case $src in
    new) cand=$(get new "$svc") ;;
    bot)
      [ -n "$use_bot" ] || continue
      # Only a service the pull request changes (see the top of this file).
      rc=0
      git_ diff --quiet "$bot_base" "$lease" -- "$values_dir/$svc.yaml" || rc=$?
      case $rc in
      0) continue ;;
      1) ;;
      *)
        problem="its values on $branch cannot be compared with main"
        return 1
        ;;
      esac
      cand=$(release_at "$lease" "$svc") || {
        problem="its values on $branch cannot be read"
        return 1
      }
      ;;
    main) cand=$(get main "$svc") ;;
    esac
    [ -n "$cand" ] || continue
    IFS="|" read -r r t d <<<"$cand"
    [ -n "$t" ] || continue
    if [ "$src" != main ] && { [ "$r" != "$ghcr_prefix/$svc" ] || ! is_digest "$d"; }; then
      problem="its release on $src ($r tag $t digest ${d:-none}) is not a release of $ghcr_prefix/$svc"
      return 1
    fi
    c=$(commit_of "$t") || {
      problem="tag $t of its release on $src is not a commit of main; not guessing what it is"
      return 1
    }
    sources+=("$src")
    values+=("$r|$t|$d")
    commits+=("$c")
  done
  choice=$(get main "$svc")
  choice_from=main
  [ ${#sources[@]} -gt 0 ] || return 0
  # The first candidate, in the order new, bot, main, whose commit every other's is an ancestor of (or equal to).
  for i in "${!sources[@]}"; do
    ok=yes
    for j in "${!sources[@]}"; do
      is_ancestor "${commits[$j]}" "${commits[$i]}" || ok=
    done
    if [ -n "$ok" ]; then
      choice=${values[$i]}
      choice_from=${sources[$i]}
      return 0
    fi
  done
  problem="none of the commits of its candidates (${sources[*]}: ${commits[*]}) descends from all the others"
  return 1
}

# --- the tree: main's, with every service whose choice differs from main.
export GIT_INDEX_FILE=$tmp/index
git_ read-tree "$main" || fail "read the tree of main"
failed=0
changed=()
for svc in "${svp_services[@]}"; do
  line=$(release_at "$main" "$svc") || fail "the values of $svc on main cannot be read (above)"
  put main "$svc" "$line"
  if ! choose "$svc"; then
    echo "FAIL  $svc: $problem; left as main has it" >&2
    ci_summary "- $svc: **not promoted**: $problem"
    failed=1
    continue
  fi
  if [ "$choice" = "$line" ]; then
    echo "ok    $svc: main's ($line) stays"
    continue
  fi
  IFS="|" read -r r t d <<<"$choice"
  file=$values_dir/$svc.yaml
  blob=$(git_ show "$main:$file" | values_set_image "$r" "$t" "$d" | git_ hash-object -w --stdin) ||
    fail "write the release of $svc into $file"
  git_ update-index --cacheinfo "100644,$blob,$file" || fail "stage $file in the temporary index"
  changed+=("$svc")
  put chosen "$svc" "$choice"
  echo "ok    $svc: $r:$t@$d (from $choice_from)"
done
tree=$(git_ write-tree) || fail "write the tree"
unset GIT_INDEX_FILE

if [ "$tree" = "$(git_ rev-parse "$main^{tree}")" ]; then
  echo "Nothing differs from main: no push, no pull request."
  ci_summary "Promote: every service on \`$branch\` would be what main already runs; nothing pushed."
  exit "$failed"
fi

# --- title, commit message and pull request body. The tag in the title is the newest commit of the release.
newest=
for svc in "${changed[@]}"; do
  IFS="|" read -r r t d <<<"$(get chosen "$svc")"
  if [ -z "$newest" ] || is_ancestor "$(commit_of "$newest")" "$(commit_of "$t")"; then newest=$t; fi
done
title="chore(release): phát hành ${changed[*]} $newest"
{
  echo "$title"
  echo
  for svc in "${changed[@]}"; do
    IFS="|" read -r r t d <<<"$(get chosen "$svc")"
    echo "- $svc: $r:$t@$d"
  done
} >"$tmp/message"
{
  echo "Phát hành lên đường GitOps: \`image.repository\`, \`image.tag\`, \`image.digest\` trong"
  echo "\`$values_dir/\`, do job \`promote\` của \`images.yml\` ghi. Nhánh \`$branch\` được dựng lại từ \`main\` mỗi"
  echo "lần, gom bản mới nhất (theo lịch sử commit) của mọi service chưa merge."
  echo
  echo "| Service | Tag (commit) | Digest |"
  echo "| --- | --- | --- |"
  for svc in "${changed[@]}"; do
    IFS="|" read -r r t d <<<"$(get chosen "$svc")"
    echo "| \`$svc\` | \`$t\` | \`$d\` |"
  done
  echo
  echo "Lượt chạy: $run_url"
  echo
  echo "Trước khi merge: bấm \"Approve workflows to run\" để \`ci-ok\`, \`images-ok\` chạy trên commit đầu PR, merge khi cả"
  echo "hai xanh. Sau merge Argo CD đồng bộ trong khoảng 60 s (tệ nhất ~120 s)."
} >"$tmp/body"

# --- push, unless bot/promote already holds exactly this tree on top of main.
if [ -n "$lease" ] && [ "$(git_ rev-parse "$lease^{tree}")" = "$tree" ] &&
  [ "$(git_ rev-list --parents -n 1 "$lease")" = "$lease $main" ]; then
  echo "ok    $branch already holds this on top of main ${main:0:12}: not pushed again"
  head=$lease
else
  head=$(GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_NAME=$bot_name \
    GIT_COMMITTER_EMAIL=$bot_email git_ commit-tree "$tree" -p "$main" -F "$tmp/message") || fail "commit"
  # An empty lease: the branch must not exist yet.
  lease_arg="refs/heads/$branch:$lease"
  if [ -z "$push" ]; then
    printf 'dry run: git push --quiet --force-with-lease=%q origin %q\n' "$lease_arg" "$head:refs/heads/$branch"
  else
    git_ push --quiet --force-with-lease="$lease_arg" origin "$head:refs/heads/$branch" ||
      fail "push $branch: it is no longer at ${lease:-<none>} as read at the start (another run, or a change by hand); nothing was overwritten. Run the job again to rebuild it from what is there now"
    echo "ok    pushed $branch ${head:0:12} (on main ${main:0:12})"
  fi
fi

if [ -n "$pr" ]; then
  "${write[@]}" "$pr" "$branch" main "$title" "$tmp/body" || fail "update pull request #$pr"
else
  "${write[@]}" "" "$branch" main "$title" "$tmp/body" || fail "open the pull request of $branch"
fi
[ -z "$dry" ] || sed 's/^/dry run: body | /' "$tmp/body"
ci_summary "Promote: \`$branch\` at ${head:0:12}: $title"
exit "$failed"
