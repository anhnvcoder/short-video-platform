#!/usr/bin/env bash
# Tests for deploy/ci/gitops-sourcemaps.sh. Each case sources the script in a subshell and replaces what would reach
# the network: ci_artifact_runs and ci_artifact_fetch (the CI platform's API) answer from fixtures, ghcr_get (GHCR)
# serves a made-up index, ci_temp_dir points into the test's own directory, and gitops_clone (the clone of svp-gitops)
# leaves the draft below where the clone would be. Two throwaway git repositories stand for the two of the project:
# the code repository, with a build commit and a later one, on branch main or feat/stage6b-test; and the deployment
# configuration svp-gitops (remote origin named as the real one, never fetched), whose origin/main holds
# envs/stg/images/web.yaml naming the build commit (tag) and the index's digest, while the clone's own working tree
# names another release, which must not be read. Checked:
#   - two runs of the build commit, the latest with another digest, the older with the linux/amd64 manifest: the older
#     is taken, its maps are left in maps/, nothing else of either run stays;
#   - no run matches: skipped on a branch of the code repository, fail on main, the reason naming the digest, the
#     commit and the runs tried;
#   - the clone of svp-gitops failing: fail, with the reason, before any run is listed;
#   - ci_artifact_runs exit 3 counts as no match, exit 1 fails on a branch and on main alike; so does ci_artifact_fetch
#     exit 1, while its exit 3 (the artifact gone since it was listed) only skips that run;
#   - an artifact without image-digest, with one in another form, of two lines, as a link, or with a file beside
#     _next/ and image-digest is never taken, even when the digest matches;
#   - GHCR answering the index's digest with other bytes fails; web-amd64 prints the linux/amd64 manifest; newest picks
#     the tag of the newest commit, past tags that are no commit of the clone.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/gitops-sourcemaps-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
# has NAME HAYSTACK NEEDLE: ok when HAYSTACK holds NEEDLE.
has() {
  case $2 in *"$3"*) ok "$1" ;; *) fail "$1"$'\n'"      want in: $2"$'\n'"      the text: $3" ;; esac
}

sha() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
child=sha256:$(sha amd64-manifest)
arm=sha256:$(sha arm64-manifest)
other=sha256:$(sha amd64-manifest-of-a-rebuild)

# --- The release: an index of two manifests, its digest the sha256 of its bytes.
jq -nc --arg a "$child" --arg b "$arm" '{schemaVersion: 2,
  mediaType: "application/vnd.oci.image.index.v1+json",
  manifests: [{digest: $a, platform: {os: "linux", architecture: "amd64"}},
    {digest: $b, platform: {os: "linux", architecture: "arm64"}}]}' >"$work/index.json"
index=sha256:$(shasum -a 256 "$work/index.json" | cut -d' ' -f1)

repo=$work/repo
g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --initial-branch=build "$repo"
g commit -q --allow-empty -m build
build=$(g rev-parse HEAD)
g commit -q --allow-empty -m later
release=$(g rev-parse HEAD)
for b in main feat/stage6b-test; do
  g branch -q -f "$b" "$release"
done

# web_file TAG DIGEST: an image file of the web release.
web_file() {
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' "$1" "$2"
}
config=$work/gitops
c() { git -C "$config" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --initial-branch=main "$config"
c remote add origin https://github.com/anhnvcoder/svp-gitops.git
mkdir -p "$config/envs/stg/images"
web_file "${build:0:12}" "$index" >"$config/envs/stg/images/web.yaml"
c add envs
c commit -q -m release
c update-ref refs/remotes/origin/main "$(c rev-parse HEAD)"
# The clone's working tree, which the scripts never read for the release Argo CD follows.
web_file 000000000000 "sha256:$(sha uncommitted)" >"$config/envs/stg/images/web.yaml"

# artifact ID DIGEST_LINE: the artifact of run ID, a chunk naming the run and its map, image-digest holding
# DIGEST_LINE (none when empty).
artifact() {
  local d=$work/artifacts/$1
  mkdir -p "$d/_next/static/chunks"
  printf '// run %s\n//# debugId=00000000-0000-0000-0000-%012d\n//# sourceMappingURL=a.js.map\n' "$1" "$1" \
    >"$d/_next/static/chunks/a.js"
  echo '{"version":3}' >"$d/_next/static/chunks/a.js.map"
  [ -z "$2" ] || printf '%s\n' "$2" >"$d/image-digest"
}
artifact 101 "$child"
artifact 202 "$other"
artifact 303 ""
artifact 304 "SHA256:${child#sha256:}"
artifact 305 "$child"$'\n'"$child"
artifact 306 ""
ln -s ../101/image-digest "$work/artifacts/306/image-digest"
artifact 307 "$child"
echo note >"$work/artifacts/307/README"

# run_fetch NAME BRANCH [VAR=VALUE...]: fetch of the script on branch BRANCH of the throwaway repository, its output in
# $work/NAME.out, its folder $work/NAME.tmp/gitops-sourcemaps; prints its exit status. The fakes read:
#   FAKE_RUNS       the run ids ci_artifact_runs prints, latest first (spaces between)
#   FAKE_RUNS_RC    its exit status instead (3: no run; 1: the host failed)
#   FAKE_FETCH_RC   "<id>:<status>" pairs: ci_artifact_fetch of that run exits with that status, nothing downloaded
#   FAKE_INDEX      the file GHCR answers the index with (default the index above)
#   FAKE_CLONE_RC   the exit status of gitops_clone (default 0)
# Each call of a fake is logged to $work/NAME.calls.
run_fetch() {
  local name=$1 branch=$2 rc=0
  shift 2
  g symbolic-ref HEAD "refs/heads/$branch"
  mkdir -p "$work/$name.tmp"
  (
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=deploy/ci/gitops-sourcemaps.sh
    . "$here/gitops-sourcemaps.sh"
    repo_root=$repo
    gitops_ci_clone=$config
    calls=$work/$name.calls
    ci_temp_dir() { echo "$work/$name.tmp"; }
    gitops_clone() {
      echo "gitops_clone" >>"$calls"
      [ "${FAKE_CLONE_RC:-0}" = 0 ] || fail "git clone https://github.com/anhnvcoder/svp-gitops.git into $config"
      export SVP_GITOPS_DIR=$config
    }
    ghcr_get() {
      echo "ghcr_get $1 $2" >>"$calls"
      case $2 in
      "manifests/$index") cp "${FAKE_INDEX:-$work/index.json}" "$3" ;;
      *) return 1 ;;
      esac
    }
    ci_artifact_runs() {
      echo "ci_artifact_runs $*" >>"$calls"
      [ -z "${FAKE_RUNS_RC:-}" ] || return "$FAKE_RUNS_RC"
      printf '%s\n' ${FAKE_RUNS:-}
    }
    ci_artifact_fetch() {
      local pair
      echo "ci_artifact_fetch $1 $2" >>"$calls"
      [ -d "$3" ] && [ -z "$(ls -A "$3")" ] || return 1
      for pair in ${FAKE_FETCH_RC:-}; do
        [ "${pair%%:*}" != "$1" ] || return "${pair#*:}"
      done
      cp -R "$work/artifacts/$1/." "$3/"
    }
    fetch
  ) >"$work/$name.out" 2>&1 || rc=$?
  echo "$rc"
}
out_dir() { echo "$work/$1.tmp/gitops-sourcemaps"; }
status() { cat "$(out_dir "$1")/status"; }
reason() { cat "$(out_dir "$1")/reason"; }

# --- Two runs of one commit: the latest built another digest, the older this one.
rc=$(run_fetch two feat/stage6b-test FAKE_RUNS="202 101")
same "two runs, the older matching: exit 0" 0 "$rc"
same "two runs, the older matching: status ok" ok "$(status two)"
same "two runs, the older matching: its maps are kept" "// run 101" \
  "$(head -n 1 "$(out_dir two)/maps/_next/static/chunks/a.js" 2>/dev/null)"
same "two runs, the older matching: the folder holds maps, reason and status only" "maps reason status" \
  "$(cd "$(out_dir two)" && ls | tr '\n' ' ' | sed 's/ $//')"
has "two runs, the older matching: the reason names the run taken and the one passed over" "$(reason two)" \
  "run 101 of images.yml at $build"
has "two runs, the older matching: the latest run's digest is named" "$(reason two)" "run 202: $other"
same "two runs: ci_artifact_runs asked for the build commit's artifact" \
  "ci_artifact_runs images.yml $build web-sourcemaps-amd64" "$(grep '^ci_artifact_runs' "$work/two.calls")"
same "two runs: both downloaded, the latest first" "ci_artifact_fetch 202 web-sourcemaps-amd64
ci_artifact_fetch 101 web-sourcemaps-amd64" "$(grep '^ci_artifact_fetch' "$work/two.calls")"

# --- No run matches.
rc=$(run_fetch nomatch-branch feat/stage6b-test FAKE_RUNS="202")
same "no run matches on a branch: exit 0" 0 "$rc"
same "no run matches on a branch: skipped" skipped "$(status nomatch-branch)"
has "no run matches: the reason names the linux/amd64 manifest" "$(reason nomatch-branch)" "$child"
has "no run matches: the reason names the index" "$(reason nomatch-branch)" "web@$index"
has "no run matches: the reason names the commit" "$(reason nomatch-branch)" "of $build"
has "no run matches: the reason counts the runs tried" "$(reason nomatch-branch)" "1 run(s) tried"
[ ! -e "$(out_dir nomatch-branch)/maps" ] && ok "no run matches: no maps left" || fail "no run matches: no maps left"
rc=$(run_fetch nomatch-main main FAKE_RUNS="202")
same "no run matches on main: exit 1" 1 "$rc"
same "no run matches on main: fail" fail "$(status nomatch-main)"
has "no run matches on main: the same reason" "$(reason nomatch-main)" "1 run(s) tried"

# --- The clone of svp-gitops failing.
rc=$(run_fetch clone-fails feat/stage6b-test FAKE_RUNS="101" FAKE_CLONE_RC=1)
same "the clone of svp-gitops failing: fail, exit 1" "fail 1" "$(status clone-fails) $rc"
has "the clone of svp-gitops failing: the reason says so" "$(reason clone-fails)" "git clone https://github.com/anhnvcoder/svp-gitops.git"
! grep -q '^ci_artifact_runs' "$work/clone-fails.calls" && ok "the clone of svp-gitops failing: no run listed" ||
  fail "the clone of svp-gitops failing: no run listed"

# --- ci_artifact_runs: no run (3), the host failing (1).
rc=$(run_fetch none-branch feat/stage6b-test FAKE_RUNS_RC=3)
same "ci_artifact_runs exit 3 on a branch: skipped, exit 0" "skipped 0" "$(status none-branch) $rc"
has "ci_artifact_runs exit 3: no run tried" "$(reason none-branch)" "0 run(s) tried"
rc=$(run_fetch none-main main FAKE_RUNS_RC=3)
same "ci_artifact_runs exit 3 on main: fail, exit 1" "fail 1" "$(status none-main) $rc"
rc=$(run_fetch api-branch feat/stage6b-test FAKE_RUNS_RC=1)
same "ci_artifact_runs exit 1 on a branch: fail, exit 1" "fail 1" "$(status api-branch) $rc"
has "ci_artifact_runs exit 1: the reason says what failed" "$(reason api-branch)" "list the images.yml runs of $build"
rc=$(run_fetch api-main main FAKE_RUNS_RC=1)
same "ci_artifact_runs exit 1 on main: fail, exit 1" "fail 1" "$(status api-main) $rc"

# --- ci_artifact_fetch: the host failing (1), the artifact gone (3).
rc=$(run_fetch fetch-fails feat/stage6b-test FAKE_RUNS="202 101" FAKE_FETCH_RC="202:1")
same "ci_artifact_fetch exit 1 on a branch: fail, exit 1, the older run not tried" "fail 1 1" \
  "$(status fetch-fails) $rc $(grep -c '^ci_artifact_fetch' "$work/fetch-fails.calls")"
has "ci_artifact_fetch exit 1: the reason names the run" "$(reason fetch-fails)" "download web-sourcemaps-amd64 of run 202"
rc=$(run_fetch fetch-gone feat/stage6b-test FAKE_RUNS="202 101" FAKE_FETCH_RC="202:3")
same "ci_artifact_fetch exit 3 skips that run only" "ok 0" "$(status fetch-gone) $rc"
has "ci_artifact_fetch exit 3: the reason says so" "$(reason fetch-gone)" "run 202: gone since it was listed"

# --- Artifacts that are never taken, even with the right digest somewhere in them.
rc=$(run_fetch malformed feat/stage6b-test FAKE_RUNS="303 304 305 306 307")
same "no image-digest, another form, two lines, a link, an extra file: none taken (skipped on a branch)" "skipped 0" \
  "$(status malformed) $rc"
has "malformed: the reason counts the five runs" "$(reason malformed)" "5 run(s) tried"
has "malformed: an artifact without the digest is named so" "$(reason malformed)" \
  "run 303: no image-digest of the form sha256:<64 hex>"
rc=$(run_fetch malformed-then-good feat/stage6b-test FAKE_RUNS="306 305 101")
same "a good artifact after malformed ones is taken" "ok 0 // run 101" \
  "$(status malformed-then-good) $rc $(head -n 1 "$(out_dir malformed-then-good)/maps/_next/static/chunks/a.js" 2>/dev/null)"

# --- GHCR.
printf '%s ' "$(cat "$work/index.json")" >"$work/index-changed.json"
rc=$(run_fetch ghcr-bytes feat/stage6b-test FAKE_RUNS="101" FAKE_INDEX="$work/index-changed.json")
same "GHCR answering the index with other bytes: fail on a branch too" "fail 1" "$(status ghcr-bytes) $rc"
has "GHCR answering with other bytes: the reason says so" "$(reason ghcr-bytes)" "with other bytes"
! grep -q '^ci_artifact_runs' "$work/ghcr-bytes.calls" && ok "GHCR answering with other bytes: no run listed" ||
  fail "GHCR answering with other bytes: no run listed"

# web-amd64 and newest, through the same fakes; newest reads a tag list in which only two tags are commits of the
# clone (the build commit, older, and the release commit, newer).
g symbolic-ref HEAD refs/heads/feat/stage6b-test
jq -nc --arg old "${build:0:12}" --arg new "${release:0:12}" \
  '{tags: [$old, ($new + "-amd64"), $new, "0123456789ab", "sha256-abc.att"]}' >"$work/tags.json"
# Into a file, not a command substitution: bash 3.2 misreads the case patterns of a function inside one.
(
  . "$here/gitops-sourcemaps.sh"
  repo_root=$repo
  export SVP_GITOPS_DIR=$config
  ghcr_get() {
    case $2 in
    "manifests/$index") cp "$work/index.json" "$3" ;;
    "tags/list?n=1000") cp "$work/tags.json" "$3" ;;
    "manifests/${release:0:12}") printf 'newest index' >"$3" ;;
    *) return 1 ;;
    esac
  }
  web_release
  echo "web-amd64 $(web_amd64 "$work")"
  mkdir "$work/newest"
  echo "newest $(newest drill-vulnerable "$work/newest")"
) >"$work/reads.out" 2>&1 || true
got=$(cat "$work/reads.out")
has "web-amd64: the linux/amd64 manifest of the release" "$got" "web-amd64 $child"
has "newest: the index of the newest commit's tag, by the digest of its bytes" "$got" \
  "newest ghcr.io/anhnvcoder/short-video-platform/drill-vulnerable@sha256:$(sha 'newest index')"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
