#!/usr/bin/env bash
# platform-guard.sh: fails when a file under deploy/ or the Makefile reads a variable of GitHub Actions (GITHUB_...)
# or calls gh to reach the repository host (gh api, gh pr, gh run, gh workflow). Only deploy/ci/platform.sh knows the
# CI platform; every other script asks it through its ci_* functions, so moving CI to another platform stays a change
# of that one file. A script that reads such a variable itself works on GitHub and silently loses its output on any
# other platform, which nothing else would catch. Left out: platform.sh, the two tests that play a GitHub job on
# purpose (platform-test.sh, verify-collect-test.sh) and this file, whose own pattern would match. The workflow files
# under .github/ belong to the platform and are not checked.
#
# Another release source's repository (svp-web) runs the same check on its own tree, from the checkout of this
# repository its workflows pin under .backend/: ROOT names that tree. It has no deploy/, its scripts and Makefile sit
# anywhere, so every file is read except .github/ (the platform's) and .backend/ (this repository's scripts, checked
# here). Without ROOT, or with ROOT this repository's own root, the check is the one above.
#
# Reads the files git tracks plus the untracked ones it does not ignore, so a new script is checked before its first
# commit. Symbolic links are skipped (two of them point at directories, which grep cannot read, and the files the
# others point at are checked where they are), and so are tracked files deleted from the working tree: either would
# make grep exit 2 and hide whether anything matched. Prints file:line: of every match.
#
# Exit 0 clean, 1 on a match, 2 when the files cannot be listed or read.
#
# Usage, from anywhere: deploy/ci/platform-guard.sh [ROOT]
set -euo pipefail

own=$(cd "$(dirname "$0")/../.." && pwd -P)
root=$own
if [ $# -gt 0 ]; then
  root=$(cd "$1" 2>/dev/null && pwd -P) || {
    echo "FAIL  $1 is not a directory" >&2
    exit 2
  }
fi
pattern='GITHUB_[A-Z_]+|\bgh (api|pr|run|workflow)\b'
list=$(mktemp) || exit 2
trap 'rm -f "$list"' EXIT

if [ "$root" = "$own" ]; then
  paths=(deploy Makefile)
else
  paths=(. ':(exclude).github' ':(exclude).backend')
fi
git -C "$root" ls-files -z --cached --others --exclude-standard -- "${paths[@]}" >"$list" || {
  echo "FAIL  cannot list the files of $root" >&2
  exit 2
}
files=()
while IFS= read -r -d '' f; do
  if [ "$root" = "$own" ]; then
    case $f in
    deploy/ci/platform.sh | deploy/ci/platform-test.sh | deploy/ci/verify-collect-test.sh | deploy/ci/platform-guard.sh)
      continue
      ;;
    esac
  fi
  [ -f "$root/$f" ] && [ ! -L "$root/$f" ] || continue
  files+=("$f")
done <"$list"
# grep with no file would read stdin.
[ ${#files[@]} -gt 0 ] || exit 0

rc=0
(cd "$root" && grep -n -H -I -E -- "$pattern" "${files[@]}") || rc=$?
case $rc in
0)
  echo "FAIL  the lines above read GitHub's variables or call gh themselves: go through a ci_* function of" \
    "deploy/ci/platform.sh (add one there when none fits)" >&2
  exit 1
  ;;
1) ;;
*)
  echo "FAIL  grep could not read the files" >&2
  exit 2
  ;;
esac
