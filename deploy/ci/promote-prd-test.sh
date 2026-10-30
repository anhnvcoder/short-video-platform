#!/usr/bin/env bash
# Tests for deploy/ci/promote-prd.sh, the promote of a whole set of releases from a record of stg to prd in
# svp-gitops, on a throwaway repository on disk that stands for svp-gitops (main at R2; stg ran R1 with release A of
# every service, then R2 with release B of the gateway) and a fake gh that answers the records of stg and the pull
# requests. Checked:
#   - no record named: the newest that counts (#12, of R2) goes to bot/promote-prd, one commit of the app's bot on top
#     of main changing envs/prd/images/ (the seven releases of the record, the other lines of each file kept) and
#     envs/prd/charts.yaml (its three keys) and nothing else; the pull request is printed with the record, the commit
#     of stg and the run that checked it, and nothing turns on auto-merge;
#   - an older record (#11, R1: rollback): its own set;
#   - records that do not count (a failed one, one made by someone else, one whose payload breaks its form, one whose
#     run is of another workflow or of a branch, one whose run the host does not answer for) are named and left out,
#     and naming one fails; a record whose commit is not on main of svp-gitops fails;
#   - main already running the record's set: no push, no pull request;
#   - a record whose web is a release of svp-web (another release source): prd's web.yaml gets its repository and the
#     first sentence of its comment that of svp-web; the rollback to a record of backend's web puts backend's back;
#   - a machine refuses an address of svp-gitops off its disk, and with PROMOTE_DRY_RUN=1 prints the push instead.
# Every run is a machine's (env -i: no variable of a CI job running this test). Runs on macOS and Linux: no network.
#
# Usage, from anywhere: deploy/ci/promote-prd-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
real_git=$(command -v git)

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
# printed ARGS...: the line a dry run prints for a gh call with ARGS.
printed() {
  local line
  line="dry run: gh $(printf '%q ' "$@")"
  echo "${line% }"
}
expect() {
  if has "$2" "$3"; then ok "$1"; else fail "$1: no '$3' in:"$'\n'"$(sed 's/^/      /' "$2")"; fi
}

services=(gateway user-service video-service engagement-service feed-service media-worker web)
prefix=ghcr.io/anhnvcoder/short-video-platform
hex() { printf '%s' "$1" | shasum -a 256 | cut -c1-"$2"; }
digest() { echo "sha256:$(hex "$1" 64)"; }
tag=6ca2d8a795dd
run=https://github.com/anhnvcoder/short-video-platform/actions/runs

# --- Fake gh: each call to gh.log; pr list from gh/prs.json; api: the records of stg from gh/deployments.json, the
# statuses of each from gh/statuses-<id>.json, a run of the code repository from gh/run-<id>.json (none: the host
# fails), a user from gh/user.json, through its --jq filter. Anything else only records.
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
  */deployments/*/statuses) id=${path%/statuses} && jq -r "$2" "$FAKE_GH_DIR/statuses-${id##*/}.json" ;;
  */deployments) jq -r "$2" "$FAKE_GH_DIR/deployments.json" ;;
  */actions/runs/*)
    [ -f "$FAKE_GH_DIR/run-${path##*/}.json" ] || { echo "HTTP 404: Not Found" >&2 && exit 1; }
    jq -r "$2" "$FAKE_GH_DIR/run-${path##*/}.json"
    ;;
  *) exit 1 ;;
  esac
  ;;
esac
EOF
chmod 755 "$work/bin/gh"
echo '[]' >"$work/gh/prs.json"
echo '{"id": 271828}' >"$work/gh/user.json"

# --- svp-gitops: R1 (stg ran release A of every service), R2 (stg ran release B of the gateway); prd at R1's set but
# with charts of another commit; a side branch with a commit main does not hold.
src=$work/gitops-src
gs() {
  GIT_DIR=$src/.git GIT_WORK_TREE=$src GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" \
    -c user.name=owner -c user.email=owner@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
image_file() {
  printf '# The release image of %s in %s.\nimage:\n  repository: %s/%s\n  tag: "%s"\n  digest: "%s"\n' \
    "$1" "$2" "$prefix" "$1" "$tag" "$3"
}
charts_file() {
  printf '# The commit of the code repository whose charts this environment runs.\nrevision: %s\n# Derived.\npodSecurityVersion: %s\ncollectorConfigSha256: %s\n' \
    "$1" "$2" "$3"
}
charts_a=$(hex charts-a 40) charts_b=$(hex charts-b 40)
sum_a=$(hex sum-a 64) sum_b=$(hex sum-b 64)
for env in stg prd; do
  mkdir -p "$src/envs/$env/images"
  for svc in "${services[@]}"; do image_file "$svc" "$env" "$(digest "A-$svc")" >"$src/envs/$env/images/$svc.yaml"; done
  charts_file "$charts_a" v1.36 "$sum_a" >"$src/envs/$env/charts.yaml"
done
charts_file "$(hex charts-old 40)" v1.35 "$(hex sum-old 64)" >"$src/envs/prd/charts.yaml"
echo "replicas: 1" >"$src/envs/prd/gateway.yaml"
gs init -q -b main && gs add -A && gs commit -qm R1
r1=$(gs rev-parse HEAD)
image_file gateway stg "$(digest B-gateway)" >"$src/envs/stg/images/gateway.yaml"
charts_file "$charts_b" v1.37 "$sum_b" >"$src/envs/stg/charts.yaml"
gs commit -qam R2
r2=$(gs rev-parse HEAD)
gs checkout -q -b side && echo x >"$src/side.txt" && gs add side.txt && gs commit -qm side
side=$(gs rev-parse HEAD)
gs checkout -q main
"$real_git" init -q --bare "$work/gitops.git"
gs remote add origin "$work/gitops.git" && gs push -q origin main side
remote() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" --git-dir="$work/gitops.git" "$@"; }

# payload REF CHARTS PSV SUM GATEWAY_RELEASE: a payload of release-set.sh verify.
payload() {
  local images='{}' svc rel
  for svc in "${services[@]}"; do
    rel=A
    [ "$svc" != gateway ] || rel=$5
    images=$(jq -c --arg s "$svc" --arg r "$prefix/$svc" --arg t "$tag" --arg d "$(digest "$rel-$svc")" \
      '. + {($s): {repository: $r, tag: $t, digest: $d}}' <<<"$images")
  done
  jq -c -n --arg ref "$1" --argjson images "$images" --arg c "$2" --arg p "$3" --arg s "$4" --arg run "$run/77" '{
    environment: "stg", ref: $ref, images: $images,
    charts: {revision: $c, podSecurityVersion: $p, collectorConfigSha256: $s},
    deployed_at: "2026-10-30T01:00:00Z", run_url: $run, steps: [{name: "k8s-smoke", status: "ok"}],
    window: {from: "2026-10-30T01:00:00Z", to: "2026-10-30T03:00:00Z"}}'
}
# record ID REF CREATOR PAYLOAD: one deployment as the host lists it.
record() {
  jq -c -n --argjson id "$1" --arg ref "$2" --arg who "$3" --argjson p "$4" \
    '{id: $id, sha: $ref, ref: $ref, created_at: "2026-10-30T0\($id % 10):00:00Z", creator: {login: $who}, payload: $p}'
}
bot="svp-gitops-promoter[bot]"
{
  record 16 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B | jq -c --arg u "$run/80" '.run_url = $u')"
  record 15 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B | jq -c --arg u "$run/79" '.run_url = $u')"
  record 14 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B | jq -c --arg u "$run/78" '.run_url = $u')"
  record 13 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B | jq -c '.images.web.tag = "main"')"
  record 12 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B)"
  record 11 "$r1" "$bot" "$(payload "$r1" "$charts_a" v1.36 "$sum_a" A)"
  record 10 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B)"
  record 9 "$r2" someone "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B)"
  record 8 "$side" "$bot" "$(payload "$side" "$charts_b" v1.37 "$sum_b" B)"
  record 7 "$r2" "$bot" "$(payload "$r2" "$charts_b" v1.37 "$sum_b" B |
    jq -c --arg d "$(digest W-web)" '.images.web.repository = "ghcr.io/anhnvcoder/svp-web/web" | .images.web.digest = $d')"
} | jq -s . >"$work/gh/deployments.json"
for id in 16 15 14 13 12 11 9 8 7; do echo '[{"state": "success"}]' >"$work/gh/statuses-$id.json"; done
# Run 77 is of verify.yml on main, 78 of images.yml on main, 79 of verify.yml on a branch; the host knows no run 80.
echo '{"path": ".github/workflows/verify.yml", "head_branch": "main"}' >"$work/gh/run-77.json"
echo '{"path": ".github/workflows/images.yml", "head_branch": "main"}' >"$work/gh/run-78.json"
echo '{"path": ".github/workflows/verify.yml", "head_branch": "feat/stage6b-x"}' >"$work/gh/run-79.json"
echo '[{"state": "failure"}, {"state": "in_progress"}]' >"$work/gh/statuses-10.json"

# promote [VAR=VALUE...] -- [RECORD]: promote-prd.sh as a machine runs it, svp-gitops the repository above; output in
# promote.out and promote.err, exit status in rc.
promote() {
  local vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1") && shift; done
  [ $# -eq 0 ] || shift
  : >"$work/gh.log"
  rc=0
  env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="${TMPDIR:-/tmp}" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" PROMOTE_GITOPS_URL="file://$work/gitops.git" \
    ${vars[@]+"${vars[@]}"} "$here/promote-prd.sh" "$@" >"$work/promote.out" 2>"$work/promote.err" || rc=$?
}
# prd_at REF SERVICE: "repository tag digest" of SERVICE's image file of prd at REF of svp-gitops.
prd_at() {
  remote show "$1:envs/prd/images/$2.yaml" | awk '/^  (repository|tag|digest):/ { gsub("\"", "", $2); printf "%s%s", sep, $2; sep = " " }'
}

# --- 1. The newest record that counts.
promote --
same "newest: exit 0" 0 "$rc"
expect "newest: #13 left out, its payload named" "$work/promote.err" \
  "skip  record #13: its payload: it does not name one release on GHCR"
expect "newest: #10 left out, failed" "$work/promote.err" "skip  record #10: its state is failure, not success"
expect "newest: #9 left out, made by someone else" "$work/promote.err" "skip  record #9: made by someone, not $bot"
expect "newest: #14 left out, a run of another workflow" "$work/promote.err" \
  "skip  record #14: its run $run/78 is of .github/workflows/images.yml on main, not of .github/workflows/verify.yml on main"
expect "newest: #15 left out, a run of a branch" "$work/promote.err" \
  "skip  record #15: its run $run/79 is of .github/workflows/verify.yml on feat/stage6b-x, not of .github/workflows/verify.yml on main"
expect "newest: #16 left out, a run the host does not answer for" "$work/promote.err" \
  "skip  record #16: its run $run/80 cannot be read from the host"
expect "newest: record #12 chosen" "$work/promote.out" "record #12 of stg: svp-gitops ${r2:0:12}"
head=$(remote rev-parse --verify --quiet refs/heads/bot/promote-prd) || head=
[ -n "$head" ] && ok "newest: bot/promote-prd pushed" || fail "newest: bot/promote-prd pushed"
same "newest: one commit on top of main" "$head $r2" "$(remote rev-list --parents -n 1 "$head" 2>/dev/null)"
same "newest: by the app's bot" "$bot 271828+$bot@users.noreply.github.com" \
  "$(remote log -1 --format='%an %ae' "$head" 2>/dev/null)"
same "newest: only the prd gateway and charts.yaml change" "envs/prd/charts.yaml envs/prd/images/gateway.yaml" \
  "$(remote diff --name-only "$r2" "$head" | paste -sd ' ' -)"
same "newest: the gateway of the record" "$prefix/gateway $tag $(digest B-gateway)" "$(prd_at "$head" gateway)"
same "newest: another service as the record names it" "$prefix/web $tag $(digest A-web)" "$(prd_at "$head" web)"
same "newest: the charts of the record, the comments kept" \
  "$(charts_file "$charts_b" v1.37 "$sum_b")" "$(remote show "$head:envs/prd/charts.yaml")"
same "newest: the comment of the image file kept" "# The release image of gateway in prd." \
  "$(remote show "$head:envs/prd/images/gateway.yaml" | head -n 1)"
expect "newest: the pull request is printed" "$work/promote.out" \
  "$(printed pr create --repo anhnvcoder/svp-gitops --base main --head bot/promote-prd) --title"
expect "newest: its title names the record" "$work/promote.out" "stg #12 (svp-gitops ${r2:0:12})' --body-file"
expect "newest: its body names the commit of stg" "$work/promote.out" "dry run: body | - Bản ghi: #12, commit stg của \`svp-gitops\`: \`$r2\`"
expect "newest: its body names the run that checked it" "$work/promote.out" "dry run: body | - Lượt kiểm: $run/77"
expect "newest: its body names the rescan of a rollback" "$work/promote.out" "-f rescan=true -f values_ref=$r2"
lacks "$work/promote.out" "pr merge" && lacks "$work/gh.log" "merge" && ok "newest: no auto-merge" ||
  fail "newest: no auto-merge"

# --- 2. Rollback: an older record.
promote -- 11
same "rollback: exit 0" 0 "$rc"
head=$(remote rev-parse refs/heads/bot/promote-prd)
same "rollback: the gateway of record #11" "$prefix/gateway $tag $(digest A-gateway)" "$(prd_at "$head" gateway)"
same "rollback: only charts.yaml of prd changes (its images are #11's already)" "envs/prd/charts.yaml" \
  "$(remote diff --name-only "$r2" "$head" | paste -sd ' ' -)"

# --- 3. Records that do not count, or not on main.
promote -- 10
[ "$rc" != 0 ] && has "$work/promote.err" "record #10 is not among the records of stg that count" &&
  ok "a failed record named: refused" || fail "a failed record named: refused"
promote -- 14
[ "$rc" != 0 ] && has "$work/promote.err" "record #14 is not among the records of stg that count" &&
  ok "a record of a run of another workflow named: refused" || fail "a record of a run of another workflow named: refused"
promote -- 8
[ "$rc" != 0 ] && has "$work/promote.err" "record #8 is of commit ${side:0:12}, which is not on main of svp-gitops" &&
  ok "a record of a commit not on main: refused" || fail "a record of a commit not on main: refused"
promote -- 1x
[ "$rc" != 0 ] && has "$work/promote.err" "RECORD is the id of a deployment record of stg (a number), not '1x'" &&
  ok "a record id that is no number: refused" || fail "a record id that is no number: refused"

# --- 4. main runs the set already: merge what rollback pushed, promote it again.
remote update-ref refs/heads/main "$head"
before=$(remote rev-parse refs/heads/bot/promote-prd)
promote -- 11
same "main runs it: exit 0" 0 "$rc"
expect "main runs it: says so" "$work/promote.out" "prd on main of svp-gitops already runs the set of record #11: no push, no pull request."
same "main runs it: the branch did not move" "$before" "$(remote rev-parse refs/heads/bot/promote-prd)"
lacks "$work/promote.out" "pr create" && ok "main runs it: no pull request" || fail "main runs it: no pull request"
remote update-ref refs/heads/main "$r2"

# --- 4b. A record whose web is a release of svp-web, then the rollback to one of backend's web.
promote -- 7
same "web of svp-web: exit 0" 0 "$rc"
head=$(remote rev-parse refs/heads/bot/promote-prd)
same "web of svp-web: its release" "ghcr.io/anhnvcoder/svp-web/web $tag $(digest W-web)" "$(prd_at "$head" web)"
same "web of svp-web: the first comment sentence is svp-web's" \
  "# The release image of web in prd, nothing else: the release on GHCR that CI of https://github.com/anhnvcoder/svp-web
# built, scanned and signed (.github/workflows/images.yml there)." \
  "$(remote show "$head:envs/prd/images/web.yaml" | grep '^#')"
same "web of svp-web: the gateway's comment untouched" "# The release image of gateway in prd." \
  "$(remote show "$head:envs/prd/images/gateway.yaml" | head -n 1)"
expect "web of svp-web: says the source changed" "$work/promote.out" "(release source backend → web)"
remote update-ref refs/heads/main "$head"
promote -- 12
head=$(remote rev-parse refs/heads/bot/promote-prd)
same "back to backend's web: its release" "$prefix/web $tag $(digest A-web)" "$(prd_at "$head" web)"
same "back to backend's web: backend's sentence" \
  "# The release image of web in prd, nothing else: the release on GHCR that CI of
# https://github.com/anhnvcoder/short-video-platform built, scanned and signed (.github/workflows/images.yml there)." \
  "$(remote show "$head:envs/prd/images/web.yaml" | grep '^#')"
remote update-ref refs/heads/main "$r2"

# --- 5. An address off the disk.
promote PROMOTE_GITOPS_URL=https://github.com/anhnvcoder/svp-gitops.git --
[ "$rc" != 0 ] && has "$work/promote.err" "svp-gitops is not a repository on this machine's disk" &&
  ok "a machine: an address off its disk is refused" || fail "a machine: an address off its disk is refused"
lacks "$work/gh.log" "deployments" && ok "a machine: refused before anything is read" ||
  fail "a machine: refused before anything is read"
# With the dry run the push of the clone's origin (made an address off the disk by insteadOf) is printed, not run.
printf '[url "https://example.invalid/svp-gitops.git"]\n\tpushInsteadOf = file://%s/gitops.git\n' "$work" >"$work/gitconfig"
before=$(remote rev-parse refs/heads/bot/promote-prd)
promote PROMOTE_DRY_RUN=1 GIT_CONFIG_GLOBAL="$work/gitconfig" --
same "dry run: exit 0" 0 "$rc"
expect "dry run: the push is printed" "$work/promote.out" "dry run: git push --quiet --force-with-lease=refs/heads/bot/promote-prd:$before origin"
same "dry run: the branch did not move" "$before" "$(remote rev-parse refs/heads/bot/promote-prd)"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
