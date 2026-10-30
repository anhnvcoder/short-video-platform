#!/usr/bin/env bash
# Tests for deploy/ci/promote.sh, the promote to stg of the deployment repository svp-gitops, and for the list of
# releases deploy/ci/rescan.sh reads there. Two throwaway repositories on disk stand for this repository (deploy/ci/,
# lib.sh and the files the charts' derived values come from, with its own origin) and for svp-gitops (envs/stg and
# envs/prd with charts.yaml and images/, reached as file://); a fake gh first on PATH records its arguments and answers
# from fixtures, so no test reaches GitHub. Checked:
#   - a dry run pushes bot/promote-stg (one commit of the app's bot on top of main of svp-gitops) changing
#     envs/stg/images/<service>.yaml and envs/stg/charts.yaml only: the release of this run, and revision = this run's
#     commit with podSecurityVersion and collectorConfigSha256 computed from it as gitops-check.sh does; it prints the
#     pull request for svp-gitops and its auto-merge, and asks gh nothing but the bot's id;
#   - never back: an older run leaves stg's release and revision as main has them (nothing pushed);
#   - a run with no release (the charts changed) changes charts.yaml alone;
#   - a release newer than the charts' revision is refused, left as main has it, and the run fails;
#   - the open pull request of the app counts (its release stays in), a person's or a fork's from a branch of that
#     name does not, so a closed one never comes back;
#   - --force-with-lease: bot/promote-stg moved between the clone and the push fails the run, saying so, and keeps the
#     other commit;
#   - on a machine: an address of svp-gitops off its disk is refused before anything is read, and one that
#     pushInsteadOf turns into one off it too; with PROMOTE_DRY_RUN=1 the push is printed instead and the branch does
#     not move; an address on its disk is pushed for real, the pull request and its auto-merge printed, gh only reads;
#   - the app's pull request is read again after a real push: still open, it is edited; merged in between (no longer
#     listed), the run fails, saying so, and turns on no auto-merge;
#   - rescan.sh list: the releases of every environment of main of svp-gitops, of bot/promote-stg while the app's pull
#     request is open, of a values_ref of svp-gitops, and of a values_ref that is a commit of this repository from
#     before svp-gitops (deploy/k8s/values/services/); a values_ref that is neither fails; a host that does not answer
#     whether the pull request is open fails the list after main's and values_ref's releases are printed.
#   - release source web (promote.sh --source web, run from this checkout on a throwaway clone of svp-web,
#     SVP_CODE_ROOT): its first release takes web.yaml over from backend (a line "takeover"), on bot/promote-stg-web by
#     its own app's bot, changing that file alone, its first comment sentence that of svp-web and the rest of the
#     comment kept (its first paragraph wrapped again, a later one as it is), charts.yaml never; then never back on main of svp-gitops (an older commit of svp-web changes
#     nothing); a release of another service under its prefix is refused; a run of backend that built web leaves
#     web.yaml of svp-web as it is, saying so, and promotes the rest; promote.sh --header puts the sentence on top of
#     a file without a comment; rescan.sh list of backend leaves the release of svp-web out, saying so, and
#     rescan.sh list --source web lists it alone, from main and from bot/promote-stg-web of its own app; on a machine
#     with no dry run, the open pull request of its own app is read again after the push (edited, auto-merge by its
#     number) and one merged before the push fails the run.
# Every run is a machine's (the local platform of platform.sh, whose job variables platform-test.sh covers): env -i
# leaves none of a CI job's variables to the scripts. This run's commit is HEAD of the throwaway checkout.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/promote-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
real_git=$(command -v git)

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# --- Fakes. gh writes each call to gh.log (one line of %q-quoted arguments), answers pr list from gh/prs.json and
# api users/... with gh/user.json through its --jq filter; any other call (pr create, edit, merge) only records. git
# runs the real git; with RACE_GIT_DIR set, a push first moves bot/promote-stg of that repository to RACE_COMMIT, as
# another run would between the clone and the push; with RACE_PRS set, a push first makes it gh's answer to pr list,
# as auto-merge merging the pull request between the first read and the push would.
mkdir -p "$work/bin" "$work/gh" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
"api -X")
  path=$4
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  case $path in
  users/*) jq -r "$2" "$FAKE_GH_DIR/user.json" ;;
  *) exit 1 ;;
  esac
  ;;
esac
EOF
cat >"$work/bin/git" <<EOF
#!/usr/bin/env bash
# A fetch in the throwaway clone of svp-web (whose origin must be on github.com) reads its bare repository instead.
if [ -n "\${FAKE_WEB_DIR:-}" ] && [ "\$1" = -C ] && [ "\$2" = "\$FAKE_WEB_DIR" ] && [ "\$3" = fetch ]; then
  args=()
  for a in "\$@"; do if [ "\$a" = origin ]; then args+=("\$FAKE_WEB_ORIGIN"); else args+=("\$a"); fi; done
  exec "$real_git" "\${args[@]}"
fi
for a in "\$@"; do
  if [ "\$a" = push ]; then
    [ -z "\${RACE_GIT_DIR:-}" ] ||
      "$real_git" --git-dir="\$RACE_GIT_DIR" update-ref refs/heads/bot/promote-stg "\$RACE_COMMIT"
    [ -z "\${RACE_PRS:-}" ] || printf '%s\\n' "\$RACE_PRS" >"\$FAKE_GH_DIR/prs.json"
    break
  fi
done
exec "$real_git" "\$@"
EOF
chmod 755 "$work/bin/gh" "$work/bin/git"
echo '[]' >"$work/gh/prs.json"
echo '{"id": 271828}' >"$work/gh/user.json"
bot="svp-gitops-promoter[bot] 271828+svp-gitops-promoter[bot]@users.noreply.github.com"

# on COMMAND...: runs COMMAND as a machine would, with no variable of the caller's but these (env -i: none of a CI
# job's). git reads no configuration of this machine.
on() {
  env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" "$@"
}
fresh() { : >"$work/gh.log"; }
gh_line() { printf '%q ' "$@"; }
# printed ARGS...: the line a dry run prints for a gh call with ARGS.
printed() {
  local line
  line="dry run: gh $(gh_line "$@")"
  echo "${line% }"
}
# run_at COMMIT: makes COMMIT this run's (HEAD of the throwaway checkout; deploy/ci/ is the same in every commit).
run_at() { g checkout -q --detach "$1"; }

# --- This repository: deploy/ci/, lib.sh, the policy's values and release sources, and the two files the charts'
# derived values come from.
tree=$work/code
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-cluster" "$tree/deploy/helm/svp-policy" \
  "$tree/deploy/observability/otelcol"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
printf '# The chart.\npodSecurityVersion: v1.36\n' >"$tree/deploy/helm/svp-cluster/values.yaml"
echo "receivers: {}" >"$tree/deploy/observability/otelcol/k8s-config.yaml"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
"$real_git" init -q --bare "$work/code-origin.git"
g remote add origin "$work/code-origin.git"
c0=$(g rev-parse HEAD)
echo "# one" >"$tree/README.md" && g add README.md && g commit -qm one
c1=$(g rev-parse HEAD)
echo "podSecurityVersion: v1.37" >"$tree/deploy/helm/svp-cluster/values.yaml"
echo "receivers: {otlp: {}}" >"$tree/deploy/observability/otelcol/k8s-config.yaml"
g commit -qam "charts: a newer standard, another collector config"
c2=$(g rev-parse HEAD)
echo "# three" >>"$tree/README.md" && g commit -qam three
c3=$(g rev-parse HEAD)
g push -q origin main
# derived REV: the two derived lines of charts.yaml for commit REV, as gitops-check.sh computes them.
derived() {
  echo "podSecurityVersion: $(g show "$1:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')"
  echo "collectorConfigSha256: $(g show "$1:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1)"
}
digest() { echo "sha256:$(printf "$1%.0s" $(seq 64))"; }
digest_a=$(digest a) digest_b=$(digest b) digest_c=$(digest c) digest_d=$(digest d)

# --- svp-gitops: stg and prd at c0, the gateway released there at c0; base/ beside them.
gtree=$work/gitops-src
gs() {
  GIT_DIR=$gtree/.git GIT_WORK_TREE=$gtree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" \
    -c user.name=owner -c user.email=owner@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$gtree/base"
echo "replicas: 1" >"$gtree/base/gateway.yaml"
for env in stg prd; do
  mkdir -p "$gtree/envs/$env/images"
  { echo "# The commit of the code repository whose charts this environment runs."
    echo "revision: $c0"
    echo "# Derived from that commit."
    derived "$c0"; } >"$gtree/envs/$env/charts.yaml"
  for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
    printf '# The release image of %s in %s.\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: ""\n  digest: ""\n' \
      "$svc" "$env" "$svc" >"$gtree/envs/$env/images/$svc.yaml"
  done
  printf '# The release image of gateway in %s.\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/gateway\n  tag: "%s"\n  digest: "%s"\n' \
    "$env" "${c0:0:12}" "$digest_a" >"$gtree/envs/$env/images/gateway.yaml"
done
gs init -q -b main && gs add -A && gs commit -qm init
"$real_git" init -q --bare "$work/gitops.git"
gs remote add origin "$work/gitops.git" && gs push -q origin main
gitops_url="file://$work/gitops.git"
# remote ARGS...: git in svp-gitops's own repository.
remote() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" --git-dir="$work/gitops.git" "$@"; }
# merge_bot: what auto-merge does: main of svp-gitops gets one new commit with the tree of bot/promote-stg (squash).
merge_bot() {
  local c
  c=$(GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=o@example.invalid GIT_COMMITTER_NAME=owner \
    GIT_COMMITTER_EMAIL=o@example.invalid remote commit-tree "bot/promote-stg^{tree}" -p main -m "squash")
  remote update-ref refs/heads/main "$c"
}
# release DIR SERVICE COMMIT DIGEST: an artifact release-<service> of the job sign in DIR.
release() {
  mkdir -p "$1/release-$2"
  echo "ghcr.io/anhnvcoder/short-video-platform/$2" >"$1/release-$2/repository"
  echo "${3:0:12}" >"$1/release-$2/tag"
  echo "$4" >"$1/release-$2/digest"
}
# promote NAME WANT_RC RELEASES [VAR=VALUE...]: promote.sh of the throwaway checkout, output in promote.out.
promote() {
  local name=$1 want=$2 releases=$3 rc=0
  shift 3
  fresh
  on env PROMOTE_GITOPS_URL="$gitops_url" "$@" "$tree/deploy/ci/promote.sh" "$releases" >"$work/promote.out" 2>&1 ||
    rc=$?
  same "promote.sh: $name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed 's/^/      | /' "$work/promote.out" >&2
}
image_of() { remote show "$1:envs/$2/images/$3.yaml" | grep -E '^  (tag|digest):' | sed 's/^ *//' | paste -sd ' ' -; }
changed_files() { remote diff --name-only main "$1" | paste -sd ' ' -; }

# --- 1. A dry run: this run (c1) released the gateway.
mkdir -p "$work/none"
release "$work/r1" gateway "$c1" "$digest_b"
run_at "$c1"
promote "a dry run" 0 "$work/r1" PROMOTE_DRY_RUN=1
head=$(remote rev-parse bot/promote-stg)
same "dry run: the branch is one commit on top of main of svp-gitops" "$(remote rev-parse main)" \
  "$(remote rev-parse "$head^")"
same "dry run: the commit is the app's bot's" "$bot" "$(remote log -1 --format='%an %ae' "$head")"
same "dry run: only the gateway's image file and charts.yaml of stg change" \
  "envs/stg/charts.yaml envs/stg/images/gateway.yaml" "$(changed_files "$head")"
same "dry run: the gateway is this run's release" "tag: \"${c1:0:12}\" digest: \"$digest_b\"" \
  "$(image_of "$head" stg gateway)"
same "dry run: revision is this run's commit, the derived values computed from it" \
  "revision: $c1"$'\n'"$(derived "$c1")" "$(remote show "$head:envs/stg/charts.yaml" | grep -v '^#')"
check "dry run: the comments of charts.yaml are kept" test \
  "$(remote show "$head:envs/stg/charts.yaml" | grep -c '^#')" -eq 2
check "dry run: the gateway's tag is an ancestor of revision" g merge-base --is-ancestor \
  "$(remote show "$head:envs/stg/images/gateway.yaml" | sed -n 's/^  tag: "\(.*\)"$/\1/p')" \
  "$(remote show "$head:envs/stg/charts.yaml" | sed -n 's/^revision: //p')"
check "dry run: prd untouched" test "$(image_of "$head" prd gateway)" = "tag: \"${c0:0:12}\" digest: \"$digest_a\""
same "dry run: gh asked only for the bot's id" \
  "$(gh_line api -X GET 'users/svp-gitops-promoter%5Bbot%5D' --jq .id)" "$(cat "$work/gh.log")"
check "dry run: the pull request it would open in svp-gitops" has "$work/promote.out" \
  "$(printed pr create --repo anhnvcoder/svp-gitops --base main --head bot/promote-stg) --title "
same "dry run: the title, as the commit's subject" "chore(stg): phát hành gateway ${c1:0:12}" \
  "$(remote log -1 --format=%s "$head")"
check "dry run: the auto-merge it would turn on, for the pushed head" has "$work/promote.out" \
  "$(printed pr merge bot/promote-stg --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$head")"
check "dry run: the body links the run (none on a machine)" has "$work/promote.out" "dry run: body | Lượt chạy: local"
check "dry run: the body names this run's commit" has "$work/promote.out" \
  "dry run: body | Commit repo code của lượt chạy: https://github.com/anhnvcoder/short-video-platform/commit/$c1"
check "dry run: the summary" has "$work/promote.out" \
  "Promote: \`bot/promote-stg\` of anhnvcoder/svp-gitops at ${head:0:12}, auto-merge on: chore(stg): phát hành gateway ${c1:0:12}"
merge_bot

# --- 2. Never back: a run of the older commit c0, re-run late with a newer build of it.
release "$work/r0" gateway "$c0" "$digest_c"
run_at "$c0"
promote "an older run" 0 "$work/r0" PROMOTE_DRY_RUN=1
check "an older run: nothing differs from main, nothing pushed" has "$work/promote.out" \
  "Nothing differs from main of svp-gitops: no push, no pull request."
same "an older run: the branch did not move" "$head" "$(remote rev-parse bot/promote-stg)"

# --- 3. The charts changed (c2), no image built: charts.yaml alone.
run_at "$c2"
promote "the charts alone" 0 "$work/none" PROMOTE_DRY_RUN=1
head=$(remote rev-parse bot/promote-stg)
same "the charts alone: only charts.yaml changes" "envs/stg/charts.yaml" "$(changed_files "$head")"
same "the charts alone: revision c2, its derived values" "revision: $c2"$'\n'"$(derived "$c2")" \
  "$(remote show "$head:envs/stg/charts.yaml" | grep -v '^#')"
same "the charts alone: the title names the charts" "chore(stg): chart ${c2:0:12}" "$(remote log -1 --format=%s "$head")"
merge_bot

# --- 4. A release newer than the charts' revision (built at c3, this run at c2): refused, left as main has it.
release "$work/r3" user-service "$c3" "$digest_d"
promote "a release newer than the charts" 1 "$work/r3" PROMOTE_DRY_RUN=1
check "a release newer than the charts: says why" has "$work/promote.out" \
  "FAIL  user-service: its release ${c3:0:12} is newer than the charts' revision ${c2:0:12}; left as main has it"
check "a release newer than the charts: nothing pushed" has "$work/promote.out" "Nothing differs from main of svp-gitops"

# --- 5. The open pull request of the app. bot/promote-stg holds a newer build of the gateway at c1 (digest c), not
# merged; this run (c3) releases user-service. Open: the gateway of the branch stays in. Opened by a person, or not
# listed (closed): main's gateway.
remote update-ref refs/heads/bot/promote-stg "$(remote rev-parse main)"
gs fetch -q origin && gs checkout -q -B work origin/main
printf '# The release image of gateway in stg.\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/gateway\n  tag: "%s"\n  digest: "%s"\n' \
  "${c1:0:12}" "$digest_c" >"$gtree/envs/stg/images/gateway.yaml"
gs commit -qam "gateway build c" && gs push -q -f origin HEAD:refs/heads/bot/promote-stg
release "$work/r5" user-service "$c3" "$digest_d"
run_at "$c3"
app_pr='[{"number": 9, "isCrossRepository": false, "author": {"login": "app/svp-gitops-promoter"}}]'
promote "the app's pull request open" 0 "$work/r5" PROMOTE_DRY_RUN=1 PROMOTE_DRY_RUN_PRS="$app_pr"
head=$(remote rev-parse bot/promote-stg)
same "the app's pull request open: its gateway stays in" "tag: \"${c1:0:12}\" digest: \"$digest_c\"" \
  "$(image_of "$head" stg gateway)"
same "the app's pull request open: this run's user-service" "tag: \"${c3:0:12}\" digest: \"$digest_d\"" \
  "$(image_of "$head" stg user-service)"
check "the app's pull request open: it is edited" has "$work/promote.out" \
  "$(printed pr edit 9 --repo anhnvcoder/svp-gitops) --title "
check "the app's pull request open: auto-merge by its number" has "$work/promote.out" \
  "$(printed pr merge 9 --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$head")"
person_pr='[{"number": 9, "isCrossRepository": false, "author": {"login": "someone"}},
  {"number": 10, "isCrossRepository": true, "author": {"login": "app/svp-gitops-promoter"}}]'
promote "a person's or a fork's pull request" 0 "$work/r5" PROMOTE_DRY_RUN=1 PROMOTE_DRY_RUN_PRS="$person_pr"
head=$(remote rev-parse bot/promote-stg)
same "a person's or a fork's pull request: main's gateway" "tag: \"${c1:0:12}\" digest: \"$digest_b\"" \
  "$(image_of "$head" stg gateway)"
check "a person's or a fork's pull request: a new one is opened" has "$work/promote.out" \
  "$(printed pr create --repo anhnvcoder/svp-gitops)"

# --- 6. --force-with-lease: another run moves bot/promote-stg between the clone and the push.
other=$(remote rev-parse main)
release "$work/r6" user-service "$c2" "$digest_a"
promote "the branch moved before the push" 1 "$work/r6" PROMOTE_DRY_RUN=1 RACE_GIT_DIR="$work/gitops.git" \
  RACE_COMMIT="$other"
check "the branch moved: says it is no longer where it was read" has "$work/promote.out" \
  "push bot/promote-stg to svp-gitops: it is no longer at $head as read at the start"
same "the branch moved: the other run's commit is kept" "$other" "$(remote rev-parse bot/promote-stg)"
remote update-ref refs/heads/bot/promote-stg "$head"

# --- 7. On a machine. An address off its disk: refused before anything is read. One that pushInsteadOf turns into one
# off its disk: refused too; with PROMOTE_DRY_RUN=1 the push is printed. The branch never moves.
refusal="FAIL  svp-gitops is not a repository on this machine's disk: only CI pushes bot/promote-stg there, since its pull request belongs to CI. PROMOTE_DRY_RUN=1 runs everything else and prints the push, the pull request and its auto-merge"
for url in https://example.invalid/octo/svp-gitops.git git@example.invalid:octo/svp-gitops.git; do
  promote "on a machine, svp-gitops at $url" 1 "$work/r6" PROMOTE_GITOPS_URL="$url"
  same "on a machine, $url: refused before anything else" "$refusal" "$(cat "$work/promote.out")"
  check "on a machine, $url: no gh call" test ! -s "$work/gh.log"
done
off=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.https://example.invalid/svp-gitops.git.pushInsteadOf"
  GIT_CONFIG_VALUE_0="$gitops_url")
promote "on a machine, a push URL that pushInsteadOf turns off its disk" 1 "$work/r6" "${off[@]}"
check "on a machine, pushInsteadOf: refused, no URL printed" has "$work/promote.out" "$refusal"
check "on a machine, pushInsteadOf: no URL printed" lacks "$work/promote.out" "example.invalid"
promote "on a machine, pushInsteadOf, PROMOTE_DRY_RUN=1" 0 "$work/r6" "${off[@]}" PROMOTE_DRY_RUN=1
check "on a machine, dry run: the push is printed" has "$work/promote.out" \
  "dry run: git push --quiet --force-with-lease=refs/heads/bot/promote-stg:$head origin "
check "on a machine, dry run: not pushed" lacks "$work/promote.out" "ok    pushed"
same "on a machine, dry run: the branch did not move" "$head" "$(remote rev-parse bot/promote-stg)"

# An address on its disk: pushed for real; the pull request and its auto-merge printed; gh only reads.
promote "on a machine, svp-gitops on its disk" 0 "$work/r6"
check "on a machine: pushed" has "$work/promote.out" "ok    pushed bot/promote-stg "
pushed=$(remote rev-parse bot/promote-stg)
same "on a machine: the branch carries the new release" "tag: \"${c2:0:12}\" digest: \"$digest_a\"" \
  "$(image_of "$pushed" stg user-service)"
same "on a machine: gh only reads (the bot's id, the open pull requests of svp-gitops)" \
  "$(gh_line api -X GET 'users/svp-gitops-promoter%5Bbot%5D' --jq .id)
$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
check "on a machine: the pull request is printed" has "$work/promote.out" \
  "$(printed pr create --repo anhnvcoder/svp-gitops --base main --head bot/promote-stg) --title "
check "on a machine: the auto-merge is printed" has "$work/promote.out" \
  "$(printed pr merge bot/promote-stg --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$pushed")"
check "on a machine: the body links no run" has "$work/promote.out" "Lượt chạy: local"

# The app's pull request, read again after the push: still open, it is edited; merged before the push, the run fails.
pr_list_line=$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg --base main --state open --limit 500 \
  --json number,isCrossRepository,author)
echo "$app_pr" >"$work/gh/prs.json"
release "$work/r7" video-service "$c2" "$digest_b"
promote "on a machine, the app's pull request still open after the push" 0 "$work/r7"
check "pull request still open: pushed" has "$work/promote.out" "ok    pushed bot/promote-stg "
same "pull request still open: listed again after the push" 2 "$(grep -cF -- "$pr_list_line" "$work/gh.log")"
check "pull request still open: it is edited" has "$work/promote.out" "$(printed pr edit 9 --repo anhnvcoder/svp-gitops) --title "
release "$work/r8" feed-service "$c2" "$digest_c"
promote "on a machine, the app's pull request merged before the push" 1 "$work/r8" RACE_PRS='[]'
check "pull request merged before the push: pushed" has "$work/promote.out" "ok    pushed bot/promote-stg "
check "pull request merged before the push: says so" has "$work/promote.out" \
  "FAIL  pull request #9 of bot/promote-stg in anhnvcoder/svp-gitops was merged or closed between the start of this run and its push"
check "pull request merged before the push: no edit" lacks "$work/promote.out" "$(printed pr edit 9)"
check "pull request merged before the push: no auto-merge" lacks "$work/promote.out" "$(printed pr merge)"
check "pull request merged before the push: no summary" lacks "$work/promote.out" "auto-merge on"
echo '[]' >"$work/gh/prs.json"
remote update-ref refs/heads/bot/promote-stg "$pushed"

# --- rescan.sh list: a clone of svp-gitops, as make gitops-clone leaves it.
"$real_git" clone -q "$gitops_url" "$work/clone"
# list NAME WANT_RC [--source NAME] [VALUES_REF]: rescan.sh list on a machine, stdout in list.out, stderr in list.err.
list() {
  local name=$1 want=$2 rc=0 src=()
  shift 2
  if [ "${1:-}" = --source ]; then
    src=("$1" "$2")
    shift 2
  fi
  fresh
  on "$tree/deploy/ci/rescan.sh" list ${src[@]+"${src[@]}"} "$work/clone" "$@" >"$work/list.out" 2>"$work/list.err" ||
    rc=$?
  same "rescan.sh list: $name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed "s/^/      | /" "$work/list.err" >&2
}
tab=$'\t'
echo '[]' >"$work/gh/prs.json"
list "main of svp-gitops" 0
same "rescan.sh list: fourteen image files of main" 14 "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
check "rescan.sh list: the gateway of stg on main" has "$work/list.out" \
  "gateway${tab}ghcr.io/anhnvcoder/short-video-platform/gateway${tab}$digest_b${tab}main of svp-gitops, envs/stg/images/gateway.yaml"
check "rescan.sh list: a service not released, with an empty digest" has "$work/list.out" \
  "web${tab}ghcr.io/anhnvcoder/short-video-platform/web${tab}${tab}main of svp-gitops, envs/prd/images/web.yaml"
same "rescan.sh list: the app's open pull request of svp-gitops is asked for" \
  "$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
check "rescan.sh list: no pull request open, bot/promote-stg not read" lacks "$work/list.out" "bot/promote-stg"
echo "$app_pr" >"$work/gh/prs.json"
list "the app's pull request open" 0
check "rescan.sh list: the release of bot/promote-stg" has "$work/list.out" \
  "user-service${tab}ghcr.io/anhnvcoder/short-video-platform/user-service${tab}$digest_a${tab}bot/promote-stg of svp-gitops (pull request #9), envs/stg/images/user-service.yaml"
echo "$person_pr" >"$work/gh/prs.json"
list "only a person's and a fork's pull request" 0
check "rescan.sh list: theirs not read" lacks "$work/list.out" "bot/promote-stg"
# The host does not answer pr list (no prs.json): main's releases and values_ref's are still listed, then it fails.
mv "$work/gh/prs.json" "$work/gh/prs.off"
list "the pull requests not answered" 1 bot/promote-stg
same "rescan.sh list: not answered, the fourteen image files of main still listed" 14 \
  "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
check "rescan.sh list: not answered, values_ref still listed" has "$work/list.out" \
  "${tab}$digest_a${tab}bot/promote-stg of svp-gitops, envs/stg/images/user-service.yaml"
check "rescan.sh list: not answered, says so" has "$work/list.err" \
  "FAIL  ask the repository's host whether the promote pull request of anhnvcoder/svp-gitops is open"
mv "$work/gh/prs.off" "$work/gh/prs.json"
echo '[]' >"$work/gh/prs.json"
list "values_ref a branch of svp-gitops" 0 bot/promote-stg
check "rescan.sh list: the releases of values_ref" has "$work/list.out" \
  "${tab}$digest_a${tab}bot/promote-stg of svp-gitops, envs/stg/images/user-service.yaml"
list "values_ref a commit of svp-gitops" 0 "$(remote rev-parse main~1)"
check "rescan.sh list: the releases of that commit" has "$work/list.out" "$(remote rev-parse main~1) of svp-gitops, envs/"
# A commit of this repository from before svp-gitops held the releases: its deploy/k8s/values/services/.
mkdir -p "$tree/deploy/k8s/values/services"
for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: ""\n  digest: ""\n' "$svc" \
    >"$tree/deploy/k8s/values/services/$svc.yaml"
done
printf 'replicas: 1\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' \
  "${c0:0:12}" "$digest_c" >"$tree/deploy/k8s/values/services/web.yaml"
g add -A deploy/k8s/values && g commit -qm "the values before svp-gitops"
old=$(g rev-parse HEAD)
list "values_ref a commit of this repository from before svp-gitops" 0 "$old"
check "rescan.sh list: the web release of that commit" has "$work/list.out" \
  "web${tab}ghcr.io/anhnvcoder/short-video-platform/web${tab}$digest_c${tab}commit ${old:0:12} of the code repository, deploy/k8s/values/services/web.yaml"
list "values_ref a commit of this repository without values" 1 "$c3"
check "rescan.sh list: says it is neither" has "$work/list.err" \
  "values_ref $c3 is neither a commit of svp-gitops nor one of this repository with deploy/k8s/values/services/"
list "values_ref no ref at all" 1 no-such-branch
check "rescan.sh list: says it is no ref of svp-gitops" has "$work/list.err" "values_ref no-such-branch is no ref of svp-gitops"

# --- Release source web. A throwaway clone of svp-web (origin on github.com, its main in a bare repository beside it):
# w0 and w1 on main. On main of svp-gitops web.yaml of stg is backend's release at c0, its comment as written today.
web=$work/svp-web
wg() {
  GIT_DIR=$web/.git GIT_WORK_TREE=$web GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$web"
wg init -q -b main && wg commit -q --allow-empty -m w0 && w0=$(wg rev-parse HEAD)
wg commit -q --allow-empty -m w1 && w1=$(wg rev-parse HEAD)
"$real_git" init -q --bare "$work/svp-web-origin.git"
wg push -q "$work/svp-web-origin.git" main
wg remote add origin https://github.com/anhnvcoder/svp-web
gs fetch -q origin && gs checkout -q -B work origin/main
web_comment="# The release image of web in stg, nothing else: the release on GHCR that CI of the code repository built,
# scanned and signed (.github/workflows/images.yml there). The tag names the commit for people; the cluster pulls the
# digest. Its configuration is base/services/web.yaml and envs/stg/web.yaml when there is one."
printf '%s\nimage:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' \
  "$web_comment" "${c0:0:12}" "$digest_a" >"$gtree/envs/stg/images/web.yaml"
gs commit -qam "web of backend" && gs push -q origin HEAD:main
web_release() {
  mkdir -p "$1/release-$2"
  echo "ghcr.io/anhnvcoder/svp-web/$2" >"$1/release-$2/repository"
  echo "${3:0:12}" >"$1/release-$2/tag"
  echo "$4" >"$1/release-$2/digest"
}
# promote_web NAME WANT_RC RELEASES [VAR=VALUE...]: promote.sh --source web of this checkout on the clone of svp-web.
promote_web() {
  local name=$1 want=$2 releases=$3 rc=0
  shift 3
  fresh
  on env PROMOTE_GITOPS_URL="$gitops_url" SVP_CODE_ROOT="$web" FAKE_WEB_DIR="$web" \
    FAKE_WEB_ORIGIN="$work/svp-web-origin.git" "$@" "$tree/deploy/ci/promote.sh" --source web "$releases" \
    >"$work/promote.out" 2>&1 || rc=$?
  same "promote.sh --source web: $name (exit $want)" "$want" "$rc"
  [ "$rc" = "$want" ] || sed 's/^/      | /' "$work/promote.out" >&2
}
web_release "$work/w0" web "$w0" "$digest_c"
wg checkout -q --detach "$w0"
promote_web "the first release of svp-web" 0 "$work/w0" PROMOTE_DRY_RUN=1
check "web: a takeover of backend's web.yaml, said so" has "$work/promote.out" \
  "takeover: web.yaml on main is ghcr.io/anhnvcoder/short-video-platform/web:${c0:0:12} (source backend); first release of source web"
head=$(remote rev-parse bot/promote-stg-web)
same "web: on its own branch, one commit on top of main" "$(remote rev-parse main)" "$(remote rev-parse "$head^")"
same "web: the commit is the bot of its own app" \
  "svp-web-promoter[bot] 271828+svp-web-promoter[bot]@users.noreply.github.com" "$(remote log -1 --format='%an %ae' "$head")"
same "web: only web.yaml of stg changes, never charts.yaml" "envs/stg/images/web.yaml" "$(changed_files "$head")"
same "web: the release of svp-web" "ghcr.io/anhnvcoder/svp-web/web
tag: \"${w0:0:12}\" digest: \"$digest_c\"" \
  "$(remote show "$head:envs/stg/images/web.yaml" | sed -n 's/^  repository: //p')
$(image_of "$head" stg web)"
same "web: the first comment sentence is svp-web's, the rest of the paragraph kept and wrapped again" \
  "# The release image of web in stg, nothing else: the release on GHCR that CI of https://github.com/anhnvcoder/svp-web
# built, scanned and signed (.github/workflows/images.yml there). The tag names the commit for people; the cluster
# pulls the digest. Its configuration is base/services/web.yaml and envs/stg/web.yaml when there is one." \
  "$(remote show "$head:envs/stg/images/web.yaml" | grep '^#')"
check "web: the pull request of its own branch" has "$work/promote.out" \
  "$(printed pr create --repo anhnvcoder/svp-gitops --base main --head bot/promote-stg-web) --title "
check "web: backend's branch untouched" test "$(remote rev-parse bot/promote-stg)" = "$pushed"
c=$(GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=o@example.invalid GIT_COMMITTER_NAME=owner \
  GIT_COMMITTER_EMAIL=o@example.invalid remote commit-tree "bot/promote-stg-web^{tree}" -p main -m "squash web")
remote update-ref refs/heads/main "$c"

web_release "$work/w1" web "$w1" "$digest_d"
wg checkout -q --detach "$w1"
promote_web "a newer release of svp-web" 0 "$work/w1" PROMOTE_DRY_RUN=1
check "web, newer: no takeover any more" lacks "$work/promote.out" "takeover"
same "web, newer: its release" "tag: \"${w1:0:12}\" digest: \"$digest_d\"" \
  "$(image_of "$(remote rev-parse bot/promote-stg-web)" stg web)"
same "web, newer: the comment is not written again" "$(remote show main:envs/stg/images/web.yaml | grep '^#')" \
  "$(remote show bot/promote-stg-web:envs/stg/images/web.yaml | grep '^#')"
c=$(GIT_AUTHOR_NAME=owner GIT_AUTHOR_EMAIL=o@example.invalid GIT_COMMITTER_NAME=owner \
  GIT_COMMITTER_EMAIL=o@example.invalid remote commit-tree "bot/promote-stg-web^{tree}" -p main -m "squash web")
remote update-ref refs/heads/main "$c"
web_release "$work/w0b" web "$w0" "$digest_b"
wg checkout -q --detach "$w0"
promote_web "an older commit of svp-web" 0 "$work/w0b" PROMOTE_DRY_RUN=1
check "web, older: never back, nothing pushed" has "$work/promote.out" "Nothing differs from main of svp-gitops"
web_release "$work/wg" gateway "$w0" "$digest_b"
promote_web "a gateway under the prefix of svp-web" 1 "$work/wg" PROMOTE_DRY_RUN=1
check "web: another service under its prefix is refused" has "$work/promote.out" \
  "ghcr.io/anhnvcoder/svp-web/gateway is not the repository of a service of release source web"

# A run of backend that still built web, once web.yaml is svp-web's: left as it is, the gateway promoted.
release "$work/b1" web "$c3" "$digest_c"
release "$work/b1" gateway "$c3" "$digest_c"
run_at "$c3"
promote "backend, web.yaml of svp-web on main" 0 "$work/b1" PROMOTE_DRY_RUN=1
check "backend: web of svp-web left as it is, said so" has "$work/promote.out" \
  "ok    web: released by source web (main's ghcr.io/anhnvcoder/svp-web/web:${w1:0:12}), left as it is"
changed=$(changed_files "$(remote rev-parse bot/promote-stg)")
check "backend: web.yaml not written ($changed)" test "${changed/web.yaml/}" = "$changed"
same "backend: the gateway promoted" "tag: \"${c3:0:12}\" digest: \"$digest_c\"" \
  "$(image_of "$(remote rev-parse bot/promote-stg)" stg gateway)"

printf 'image:\n  repository: x\n' | on "$tree/deploy/ci/promote.sh" --header gateway prd web >"$work/header.out"
same "promote.sh --header: a file without a comment gets the sentence on top" \
  "# The release image of gateway in prd, nothing else: the release on GHCR that CI of
# https://github.com/anhnvcoder/svp-web built, scanned and signed (.github/workflows/images.yml there).
image:
  repository: x" "$(cat "$work/header.out")"
printf '# Old first sentence\n# over two lines. Then the\n# rest.\n#\n#   A later paragraph, as it is.\nimage:\n  repository: x\n' |
  on "$tree/deploy/ci/promote.sh" --header web stg web >"$work/header.out"
same "promote.sh --header: the first paragraph wrapped again around the new sentence, a later one kept" \
  "# The release image of web in stg, nothing else: the release on GHCR that CI of https://github.com/anhnvcoder/svp-web
# built, scanned and signed (.github/workflows/images.yml there). Then the rest.
#
#   A later paragraph, as it is.
image:
  repository: x" "$(cat "$work/header.out")"

# rescan.sh list of each source on the clone: backend leaves web of svp-web out, web lists it alone.
"$real_git" -C "$work/clone" fetch -q origin
list "backend, web of svp-web in stg" 0
check "rescan.sh list: backend leaves web of svp-web out" lacks "$work/list.out" "ghcr.io/anhnvcoder/svp-web/web"
check "rescan.sh list: backend says why" has "$work/list.err" \
  "skip  web in main of svp-gitops, envs/stg/images/web.yaml: ghcr.io/anhnvcoder/svp-web/web is a release of source web, which its own CI rescans"
same "rescan.sh list: backend lists its thirteen others" 13 "$(grep -c "main of svp-gitops, envs/" "$work/list.out")"
web_pr='[{"number": 11, "isCrossRepository": false, "author": {"login": "app/svp-web-promoter"}}]'
echo "$web_pr" >"$work/gh/prs.json"
list "web, its pull request open" 0 --source web
same "rescan.sh list --source web: web of stg from main and from its branch, nothing else" \
  "web${tab}ghcr.io/anhnvcoder/svp-web/web${tab}$digest_d${tab}main of svp-gitops, envs/stg/images/web.yaml
web${tab}ghcr.io/anhnvcoder/svp-web/web${tab}$digest_d${tab}bot/promote-stg-web of svp-gitops (pull request #11), envs/stg/images/web.yaml" \
  "$(cat "$work/list.out")"
same "rescan.sh list --source web: asks for the pull request of its own branch" \
  "$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg-web --base main --state open --limit 500 \
    --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
echo '[]' >"$work/gh/prs.json"

# On a machine, svp-gitops on its disk, no dry run: the open pull request of svp-web's own app is read again after the
# real push and found (it is not the app of backend's): edited, its auto-merge by its number; merged before the push,
# the run fails.
wg checkout -q main
wg commit -q --allow-empty -m w2 && w2=$(wg rev-parse HEAD)
wg commit -q --allow-empty -m w3 && w3=$(wg rev-parse HEAD)
wg push -q "$work/svp-web-origin.git" main
web_pr_list=$(gh_line pr list --repo anhnvcoder/svp-gitops --head bot/promote-stg-web --base main --state open \
  --limit 500 --json number,isCrossRepository,author)
echo "$web_pr" >"$work/gh/prs.json"
web_release "$work/w2" web "$w2" "$digest_a"
wg checkout -q --detach "$w2"
promote_web "on a machine, its pull request still open after the push" 0 "$work/w2"
check "web, on a machine: pushed" has "$work/promote.out" "ok    pushed bot/promote-stg-web "
web_head=$(remote rev-parse bot/promote-stg-web)
same "web, on a machine: the branch carries the release" "tag: \"${w2:0:12}\" digest: \"$digest_a\"" \
  "$(image_of "$web_head" stg web)"
same "web, on a machine: its pull request listed again after the push" 2 "$(grep -cF -- "$web_pr_list" "$work/gh.log")"
check "web, on a machine: its pull request is edited" has "$work/promote.out" \
  "$(printed pr edit 11 --repo anhnvcoder/svp-gitops) --title "
check "web, on a machine: auto-merge by its number" has "$work/promote.out" \
  "$(printed pr merge 11 --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$web_head")"
web_release "$work/w3" web "$w3" "$digest_b"
wg checkout -q --detach "$w3"
promote_web "on a machine, its pull request merged before the push" 1 "$work/w3" RACE_PRS='[]'
check "web, merged before the push: says so" has "$work/promote.out" \
  "FAIL  pull request #11 of bot/promote-stg-web in anhnvcoder/svp-gitops was merged or closed between the start of this run and its push"
check "web, merged before the push: no auto-merge" lacks "$work/promote.out" "$(printed pr merge)"
echo '[]' >"$work/gh/prs.json"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
