#!/usr/bin/env bash
# promote-prd.sh [RECORD]: job promote-prd of images.yml (a dispatch on main with promote_prd). Promotes to prd in the
# deployment repository svp-gitops the whole set of a record of stg: the seven releases and the charts that ran
# together there through the checks of a run of scenario gitops (deploy/ci/release-set.sh records; RECORD is the id of
# one, the newest when empty). A set never goes to prd in pieces: a release of one service only reaches prd as part of
# a set stg ran with it. Rollback is the same promote with an older record.
#
# Clones svp-gitops, rebuilds the branch bot/promote-prd from its main with envs/prd/images/<service>.yaml of the seven
# releases of the record (repository, tag, digest; every other line of main's file kept, but for the first sentence of
# its comment when the release is of another release source than main's: that of the new source, from
# deploy/ci/promote.sh --header, which names its repository and workflow) and envs/prd/charts.yaml with
# its revision, podSecurityVersion and collectorConfigSha256 (its comments kept, the URL of a renamed repository in
# them made its current one: current_repo_urls of common.sh), pushes it, opens or updates its pull request there. No
# auto-merge: envs/prd/ has a code owner, who must approve, and the check of svp-gitops (deploy/ci/gitops-check.sh)
# compares the set at the head of the pull request with the records again. The record's ref (the commit of svp-gitops
# stg ran) must be on main of svp-gitops: a record of a commit main no longer holds (a force push, a branch) is refused.
# The body names the record, the commit of stg and the run that checked it.
#
# The branch is one commit on top of main of svp-gitops, by the bot of the app that writes there, made with git
# plumbing on a temporary index in a temporary clone, changing envs/prd/images/ and envs/prd/charts.yaml only. Pushed
# with --force-with-lease on the commit of bot/promote-prd read at the start. Nothing differs from main: no push, no
# pull request. bot/promote-prd already holds exactly this on top of main: no push.
#
# Environment as deploy/ci/promote.sh: the token of the app (GH_TOKEN on GitHub), which reads the records (and the
# runs they name, of the public code repository) and writes the pull request; PROMOTE_DRY_RUN=1 prints the push and the pull request instead (the open pull requests from
# PROMOTE_DRY_RUN_PRS); PROMOTE_GITOPS_URL replaces the address of svp-gitops; a machine pushes only to a repository on
# its own disk and never writes a pull request.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -le 1 ] || fail "usage: promote-prd.sh [RECORD]"
want=${1:-}
[[ $want =~ ^[0-9]*$ ]] || fail "RECORD is the id of a deployment record of stg (a number), not '$want'"
branch=bot/promote-prd
images_dir=envs/prd/images
charts_file=envs/prd/charts.yaml
url=${PROMOTE_GITOPS_URL:-$gitops_url}
dry=${PROMOTE_DRY_RUN:-}
platform=$(ci_platform) || exit 1

push=yes
check_on_disk() {
  local u
  [ "$platform" = local ] || return 0
  while IFS= read -r u; do
    case $u in
    /* | ./* | ../* | file://*) ;;
    *)
      [ -n "$dry" ] || fail "svp-gitops is not a repository on this machine's disk: only CI pushes $branch there, since its pull request belongs to CI. PROMOTE_DRY_RUN=1 runs everything else and prints the push and the pull request"
      push=
      ;;
    esac
  done <<<"$1"
}
check_on_disk "$url"
run_url=$(ci_run_url) && bot_name=$(ci_bot_name "$gitops_app") && bot_email=$(ci_bot_email "$gitops_app") &&
  auth_opts=$(ci_git_auth) || exit 1
auth=()
while IFS= read -r opt; do [ -z "$opt" ] || auth+=(-c "$opt"); done <<<"$auth_opts"
write=(ci_change_request_write)
[ -z "$dry" ] || write+=(--dry-run)

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
gitops=$tmp/svp-gitops
gg() { GIT_TERMINAL_PROMPT=0 git -C "$gitops" "$@"; }

# --- the record.
records=$("$ci_dir/release-set.sh" records) || fail "read the records of stg in $gitops_repo (above)"
if [ -n "$want" ]; then
  record=$(jq -c --argjson id "$want" '[.[] | select(.id == $id)] | first // empty' <<<"$records")
  [ -n "$record" ] || fail "record #$want is not among the records of stg that count (above, and the newest 100 only)"
else
  record=$(jq -c 'first // empty' <<<"$records")
  [ -n "$record" ] || fail "no record of stg counts yet: a run of verify.yml scenario gitops green on main makes one"
fi
id=$(jq -r .id <<<"$record")
ref=$(jq -r .ref <<<"$record")
record_run=$(jq -r .payload.run_url <<<"$record")
echo "record #$id of stg: svp-gitops ${ref:0:12}, made $(jq -r .created_at <<<"$record"), checked by $record_run"

# --- svp-gitops as it is now, anonymously: the token is handed to the push alone.
GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone --quiet --no-tags "$url" "$gitops" 2>"$tmp/clone.err" || {
  cat "$tmp/clone.err" >&2
  fail "clone svp-gitops"
}
push_urls=$(gg remote get-url --push --all origin) || fail "the clone of svp-gitops has no remote origin"
check_on_disk "$push_urls"
gmain=$(gg rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") || fail "svp-gitops has no branch main"
lease=$(gg rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}") || lease=
gg cat-file -e "$ref^{commit}" 2>/dev/null && gg merge-base --is-ancestor "$ref" "$gmain" ||
  fail "record #$id is of commit ${ref:0:12}, which is not on main of svp-gitops: what stg ran then is not what main holds"

# --- the tree: main's, with the record's seven releases and charts in envs/prd/.
export GIT_INDEX_FILE=$tmp/index
gg read-tree "$gmain" || fail "read the tree of main of svp-gitops"
changed=()
for svc in "${svp_services[@]}"; do
  file=$images_dir/$svc.yaml
  IFS="|" read -r r t d <<<"$(jq -r --arg s "$svc" '.payload.images[$s] | "\(.repository)|\(.tag)|\(.digest)"' <<<"$record")"
  # The release sources of main's release and of the record's: their comment changes with them.
  was=$(gg show "$gmain:$file" | values_field repository) && was=$(source_of_repository "$was") &&
    now=$(source_of_repository "$r") || fail "$svc: the release of main's $file or of the record is of no release source"
  header=(cat)
  [ "$was" = "$now" ] || header=("$ci_dir/promote.sh" --header "$svc" prd "$now")
  blob=$(gg show "$gmain:$file" | values_set_image "$r" "$t" "$d" | "${header[@]}" | gg hash-object -w --stdin) ||
    fail "write the release of $svc into $file of main of svp-gitops"
  gg update-index --cacheinfo "100644,$blob,$file" || fail "stage $file in the temporary index"
  if [ "$blob" != "$(gg rev-parse "$gmain:$file")" ]; then
    changed+=("$svc")
    echo "ok    $svc: $r:$t@$d${header[1]:+ (release source $was → $now)}"
  else
    echo "ok    $svc: prd runs it already"
  fi
done
IFS="|" read -r rev psv sum <<<"$(jq -r '.payload.charts | "\(.revision)|\(.podSecurityVersion)|\(.collectorConfigSha256)"' <<<"$record")"
# Main's file with its three lines replaced, its comments kept, a renamed repository's URL in them made its current one.
charts=$(gg show "$gmain:$charts_file" | current_repo_urls | awk -v rev="$rev" -v psv="$psv" -v sha="$sum" '
  /^revision:/ { n["r"]++; print "revision: " rev; next }
  /^podSecurityVersion:/ { n["p"]++; print "podSecurityVersion: " psv; next }
  /^collectorConfigSha256:/ { n["c"]++; print "collectorConfigSha256: " sha; next }
  { print }
  END { if (n["r"] != 1 || n["p"] != 1 || n["c"] != 1) exit 3 }') ||
  fail "$charts_file on main of svp-gitops must hold revision, podSecurityVersion and collectorConfigSha256 once each"
blob=$(printf '%s\n' "$charts" | gg hash-object -w --stdin) || fail "write $charts_file"
gg update-index --cacheinfo "100644,$blob,$charts_file" || fail "stage $charts_file in the temporary index"
charts_changed=
if [ "$blob" != "$(gg rev-parse "$gmain:$charts_file")" ]; then
  charts_changed=yes
  echo "ok    charts: ${rev:0:12}"
else
  echo "ok    charts: prd runs ${rev:0:12} already"
fi
tree=$(gg write-tree) || fail "write the tree"
unset GIT_INDEX_FILE

if [ "$tree" = "$(gg rev-parse "$gmain^{tree}")" ]; then
  echo "prd on main of svp-gitops already runs the set of record #$id: no push, no pull request."
  ci_summary "Promote prd: main of svp-gitops already runs the set of record #$id; nothing pushed."
  exit 0
fi

# --- title, commit message and pull request body.
title="chore(prd): phát hành bộ của bản ghi stg #$id (svp-gitops ${ref:0:12})"
rescan=$(ci_dispatch_hint images.yml main rescan=true "values_ref=$ref") || exit 1
{
  echo "$title"
  echo
  for svc in "${svp_services[@]}"; do
    jq -r --arg s "$svc" '.payload.images[$s] | "- \($s): \(.repository):\(.tag)@\(.digest)"' <<<"$record"
  done
  echo "- charts: $rev"
  echo
  echo "Record: #$id ($gitops_repo, environment stg, ref $ref)"
  echo "Checked by: $record_run"
  echo "Run: $run_url"
} >"$tmp/message"
{
  echo "Promote lên prd cả bộ của bản ghi triển khai stg **#$id**, do job \`promote-prd\` của \`images.yml\` ở repo code"
  echo "ghi: chỉ \`$images_dir/\` và \`$charts_file\`. Bộ này đã chạy cùng nhau ở stg qua mọi phép kiểm của một lượt"
  echo "\`gitops\`; check của PR so lại cả bộ với bản ghi."
  echo
  echo "- Bản ghi: #$id, commit stg của \`svp-gitops\`: \`$ref\`"
  echo "- Lượt kiểm: $record_run"
  echo "- Lượt promote: $run_url"
  echo
  echo "| Service | Tag (commit) | Digest | Đổi |"
  echo "| --- | --- | --- | --- |"
  for svc in "${svp_services[@]}"; do
    mark=
    case " ${changed[*]-} " in *" $svc "*) mark=có ;; esac
    jq -r --arg s "$svc" --arg m "$mark" '.payload.images[$s] | "| `\($s)` | `\(.tag)` | `\(.digest)` | \($m) |"' <<<"$record"
  done
  echo
  echo "Chart: \`revision\` \`$rev\`, \`podSecurityVersion\` \`$psv\`, \`collectorConfigSha256\` \`$sum\`${charts_changed:+ (đổi)}."
  echo
  echo "Không auto-merge: \`envs/prd/\` có code owner, cần người học duyệt. Check đỏ vì attestation \`vuln\` quá 48 giờ"
  echo "(bản ghi cũ, rollback): quét lại bộ của bản ghi rồi chạy lại check:"
  echo
  echo "    $rescan"
} >"$tmp/body"

# --- push, unless bot/promote-prd already holds exactly this tree on top of main.
if [ -n "$lease" ] && [ "$(gg rev-parse "$lease^{tree}")" = "$tree" ] &&
  [ "$(gg rev-list --parents -n 1 "$lease")" = "$lease $gmain" ]; then
  echo "ok    $branch already holds this on top of main ${gmain:0:12}: not pushed again"
else
  head=$(GIT_AUTHOR_NAME=$bot_name GIT_AUTHOR_EMAIL=$bot_email GIT_COMMITTER_NAME=$bot_name \
    GIT_COMMITTER_EMAIL=$bot_email gg commit-tree "$tree" -p "$gmain" -F "$tmp/message") || fail "commit"
  lease_arg="refs/heads/$branch:$lease"
  if [ -z "$push" ]; then
    printf 'dry run: git push --quiet --force-with-lease=%q origin %q\n' "$lease_arg" "$head:refs/heads/$branch"
  else
    gg ${auth[@]+"${auth[@]}"} push --quiet --force-with-lease="$lease_arg" origin "$head:refs/heads/$branch" ||
      fail "push $branch to svp-gitops: it is no longer at ${lease:-<none>} as read at the start (another run, or a change by hand), or the push was refused; nothing was overwritten. Run the job again"
    echo "ok    pushed $branch ${head:0:12} (on main ${gmain:0:12} of svp-gitops)"
  fi
fi

if [ -n "$dry" ]; then
  prs=${PROMOTE_DRY_RUN_PRS:-[]}
else
  prs=$(ci_change_request_list "$branch" main "$gitops_repo") ||
    fail "ask the repository's host whether the pull request of $branch is open in $gitops_repo"
fi
pr=$(ci_change_request_pick "$gitops_app" <<<"$prs") || fail "read the open pull requests of $branch"
[[ $pr =~ ^[0-9]*$ ]] || fail "unexpected pull request number '$pr'"
"${write[@]}" "$pr" "$branch" main "$title" "$tmp/body" "$gitops_repo" ||
  fail "open or update the pull request of $branch in $gitops_repo"
[ -z "$dry" ] && [ "$platform" != local ] || sed 's/^/dry run: body | /' "$tmp/body"
ci_summary "Promote prd: \`$branch\` of $gitops_repo, the set of record #$id (svp-gitops \`${ref:0:12}\`); a code owner approves the pull request."
