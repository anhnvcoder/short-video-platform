#!/usr/bin/env bash
# Negative cases of deploy/ci/gitops-check.sh and of the root chart argocd/apps of a tree of the deployment repository
# svp-gitops. Each case changes one thing in a fresh copy of TREE and must fail with its own message; the root chart is
# also rendered on its own (helm template), since Argo CD relies on its render failing, not on the check:
#   - envs/stg/images/ with six of the seven image files;
#   - an image file with a key besides image;
#   - an overlay of a release of chart svp-service that sets image;
#   - an unknown environment: a directory envs/qa for the check, env=nope for the chart;
#   - an empty revision in envs/stg/charts.yaml;
#   - an image newer than the charts: revision set to the parent of an image's commit (derived values from that
#     parent), so the image's tag is no ancestor of it;
#   - a wrong collectorConfigSha256;
#   - a short targetRevision (main, not refs/heads/main) for the sources of svp-gitops in argocd/apps/values.yaml;
#   - the release sources of the image files (gitops-check.sh --tree, on a throwaway copy of this repository with a
#     commit from before the table of release sources and one with it, and a throwaway clone of svp-web): stg pinning
#     the commit with the table runs web of svp-web while prd pins the commit before it, in one tree, and passes; the
#     same tree without any release of svp-web passes with no clone of svp-web at all; a web tag that is no commit on
#     main of svp-web, a release of svp-web where the charts' table knows no such source, and SVP_SOURCE_DIR_WEB
#     naming a clone of another repository each fail with their own message; values-check.sh refuses an image file
#     naming the repository of another service before it verifies any release;
#   - the author of a pull request (gitops-check.sh --tree TREE BASE on the same throwaway repositories, the author in
#     SVP_CHANGE_REQUEST_AUTHOR): the bot of svp-web takes web.yaml over from backend and moves it to another release
#     of its own; it writing a release of backend, changing gateway.yaml, charts.yaml, envs/prd/ (whose charts, from
#     before the table, know no such bot), an overlay of stg or base/, deleting web.yaml and adding the image file of
#     a service it does not publish each fail; the bot of backend promotes stg with charts.yaml and prd, but changing
#     the workflow of the check or taking web back from svp-web fails; a person is not limited; a bot that promotes no
#     source fails on envs/ and passes on base/; an author that is no login fails, a run of no pull request skips;
#     the sender of the event (SVP_CHANGE_REQUEST_SENDER): the bot of svp-web pushing onto the pull request of the bot
#     of backend and a bot pushing onto a person's fail, a person pushing onto a bot's pull request and the author
#     itself pass, a sender that is no login fails;
#   - envs/prd/ against the records of stg (gitops-check.sh --records, a fake gh listing the records): exactly the set
#     of one record passes; a set mixed from two records, the seven releases of a record with other charts, and a set
#     merged into envs/stg/images/ of main that no record holds each fail with their own message; a record whose
#     commit is not on main of svp-gitops is left out; the whole check stops at that step for a mixed set.
#   - tag_provenance_mismatch of common.sh, which step 5 reads the release checks with (offline, synthetic checks):
#     image.tag against the commit the provenance names, and a check that names no provenance commit in an environment
#     requiring provenance (a reworded line of verify-release.sh) fails instead of passing.
# First, gitops_dir of deploy/k8s/lib.sh, which every script asks for the clone of svp-gitops, in a draft workspace laid
# out as the lab's (<workspace>/backend, a git repository holding a copy of lib.sh; a worktree of it in
# <workspace>/.worktrees/; <workspace>/gitops): from the main checkout, from a folder inside it and from the worktree it
# names <workspace>/gitops once that is a clone of svp-gitops; SVP_GITOPS_DIR names another clone; a missing folder, a
# folder that is no git repository, a repository with another origin and a folder inside a clone are refused with the
# command that makes the clone, and nothing is cloned. Then gitops_clone: a GITOPS_REF that is no branch fails, and
# the next run checks out the clone it left (no index, every file read as deleted) instead of refusing it; a change to
# a checked-out clone is still refused.
# Every case fails before the check reaches the network (chart repositories, GHCR): needs bash, git, jq, helm and the
# history of this repository up to the tree's revisions and image tags (a full clone, origin/main fetched).
#
# Usage, from anywhere: deploy/ci/gitops-check-test.sh [TREE]
#   TREE: a tree of svp-gitops (base/, envs/, argocd/), never written. Without it, main of
#   https://github.com/anhnvcoder/svp-gitops is cloned anonymously into a temporary directory, as this repository does
#   not hold that tree.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}

# --- gitops_dir
ws=$work/ws
mkdir -p "$ws/backend/deploy/k8s"
cp "$repo_root/deploy/k8s/lib.sh" "$ws/backend/deploy/k8s/"
gw() { git -C "$1" -c user.name=test -c user.email=test@example.invalid "${@:2}"; }
git init -q "$ws/backend"
gw "$ws/backend" add deploy
gw "$ws/backend" commit -q -m lib
gw "$ws/backend" worktree add -q -b worktree-x "$ws/.worktrees/backend-x"
ws_real=$(cd "$ws" && pwd -P)
# lookup DIR LIB [VAR=VALUE...]: gitops_dir of LIB (a copy of lib.sh), run from DIR without SVP_GITOPS_DIR unless one
# of VAR=VALUE sets it; prints its output, then "rc=<exit status>".
lookup() {
  local dir=$1 lib=$2 out rc=0
  shift 2
  out=$(cd "$dir" && env -u SVP_GITOPS_DIR "$@" bash -c '. "$1" && gitops_dir' _ "$lib" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
# expect NAME OUTPUT WANT...: OUTPUT holds each WANT.
expect() {
  local name=$1 out=$2 w
  shift 2
  for w in "$@"; do
    [[ $out == *"$w"* ]] || {
      fail "$name: no '$w' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
      return
    }
  done
  ok "$name"
}
main_lib=$ws/backend/deploy/k8s/lib.sh
wt_lib=$ws/.worktrees/backend-x/deploy/k8s/lib.sh
clone_hint="git clone https://github.com/anhnvcoder/svp-gitops.git '$ws_real/gitops'"
expect "gitops_dir: no clone in the workspace, the command that makes it" "$(lookup "$ws/backend" "$main_lib")" \
  "$clone_hint" rc=1
mkdir "$ws/gitops"
expect "gitops_dir: a folder that is no git repository is refused" "$(lookup "$ws/backend" "$main_lib")" "$clone_hint" rc=1
git init -q "$ws/gitops"
gw "$ws/gitops" remote add origin https://github.com/someone/other.git
expect "gitops_dir: a repository with another origin is refused" "$(lookup "$ws/backend" "$main_lib")" "$clone_hint" rc=1
gw "$ws/gitops" remote set-url origin https://github.com/anhnvcoder/svp-gitops.git
mkdir -p "$ws/gitops/base"
expect "gitops_dir: the clone beside the main checkout" "$(lookup "$ws/backend" "$main_lib")" "$ws_real/gitops"$'\n'rc=0
expect "gitops_dir: the same from a folder inside the main checkout" "$(lookup "$ws/backend/deploy" "$main_lib")" \
  "$ws_real/gitops"$'\n'rc=0
expect "gitops_dir: the same from a worktree under .worktrees/, not .worktrees/gitops" \
  "$(lookup "$ws/.worktrees/backend-x" "$wt_lib")" "$ws_real/gitops"$'\n'rc=0
git init -q "$ws/other"
gw "$ws/other" remote add origin git@github.com:anhnvcoder/svp-gitops.git
expect "gitops_dir: SVP_GITOPS_DIR names another clone (an SSH remote)" \
  "$(lookup "$ws/.worktrees/backend-x" "$wt_lib" SVP_GITOPS_DIR="$ws/other")" "$ws_real/other"$'\n'rc=0
expect "gitops_dir: SVP_GITOPS_DIR inside a clone is refused" \
  "$(lookup "$ws/backend" "$main_lib" SVP_GITOPS_DIR="$ws/gitops/base")" \
  "SVP_GITOPS_DIR=$ws/gitops/base is not a clone of svp-gitops" "make gitops-clone" rc=1
expect "gitops_dir: SVP_GITOPS_DIR that does not exist is refused" \
  "$(lookup "$ws/backend" "$main_lib" SVP_GITOPS_DIR="$ws/missing")" "git clone https://github.com/anhnvcoder/svp-gitops.git '$ws/missing'" rc=1
[ ! -e "$ws/missing" ] && [ ! -e "$ws/backend/.gitops" ] && ok "gitops_dir: nothing was cloned" ||
  fail "gitops_dir: nothing was cloned"

# --- gitops_clone, from a local repository (the draft backend) standing for svp-gitops: gitops_is_clone is replaced so
# that a clone whose origin is that folder counts, since its own checks are above.
src_branch=$(git -C "$ws/backend" symbolic-ref --short HEAD)
# clone_run [VAR=VALUE...]: gitops_clone of the draft lib.sh into $ws/ci-clone; prints its output, then "rc=<status>".
clone_run() {
  local out rc=0
  out=$(env "$@" bash -c '. "$1" && gitops_url=file://$2 && gitops_ci_clone=$3 &&
    gitops_is_clone() { [ -d "$1/.git" ]; } && gitops_clone' _ "$main_lib" "$ws/backend" "$ws/ci-clone" 2>&1) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
expect "gitops_clone: a GITOPS_REF that is no branch is refused" "$(clone_run GITOPS_REF=typo)" \
  "GITOPS_REF=typo is neither a branch" rc=1
expect "gitops_clone: the next run checks out the clone that run left with no index" \
  "$(clone_run GITOPS_REF="$src_branch")" "svp-gitops at" rc=0
echo changed >>"$ws/ci-clone/deploy/k8s/lib.sh"
expect "gitops_clone: a checked-out clone with a change is still refused" "$(clone_run GITOPS_REF="$src_branch")" \
  "has uncommitted changes" rc=1

if [ $# -ge 1 ]; then
  tree=$(cd "$1" && pwd)
else
  # No credential helper and no prompt: the clone is anonymous, as the clusters' is.
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q --depth 1 https://github.com/anhnvcoder/svp-gitops.git \
    "$work/clone" || { echo "FAIL  clone https://github.com/anhnvcoder/svp-gitops.git" >&2; exit 1; }
  tree=$work/clone
fi
for f in argocd/apps/Chart.yaml envs/stg/charts.yaml envs/stg/images/gateway.yaml; do
  [ -f "$tree/$f" ] || { echo "FAIL  $tree has no $f: not a tree of svp-gitops" >&2; exit 1; }
done

# copy: prints a fresh copy of the tree, without .git (the check needs none without BASE), symlinks kept.
copy() {
  local dir
  dir=$(mktemp -d "$work/case.XXXXXX")
  (cd "$tree" && tar -cf - --exclude .git .) | tar -xf - -C "$dir"
  echo "$dir"
}
# check NAME DIR MESSAGE: gitops-check.sh on DIR must fail with MESSAGE on stderr.
check() {
  local out
  if out=$("$here/gitops-check.sh" "$2" 2>&1 >/dev/null); then
    fail "$1: gitops-check.sh passed"
  elif [[ $out == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1: gitops-check.sh failed without '$3':"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
# render NAME DIR ENV MESSAGE: helm template of DIR/argocd/apps for ENV must fail with MESSAGE.
render() {
  local out
  if out=$(helm template svp-root "$2/argocd/apps" --namespace argocd --set-string "env=$3" 2>&1 >/dev/null); then
    fail "$1: the root chart rendered"
  elif [[ $out == *"$4"* ]]; then
    ok "$1"
  else
    fail "$1: the root chart failed without '$4':"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}

t=$(copy)
rm "$t/envs/stg/images/web.yaml"
check "six image files of seven" "$t" "envs/stg/images/ holds"
render "six image files of seven (root chart)" "$t" stg "envs/stg/images/web.yaml is missing"

t=$(copy)
echo 'replicas: 2' >>"$t/envs/stg/images/gateway.yaml"
check "an image file with another key" "$t" "envs/stg/images/gateway.yaml holds replicas besides image"
render "an image file with another key (root chart)" "$t" stg \
  "envs/stg/images/gateway.yaml holds image, replicas: an image file holds the image block alone"

t=$(copy)
printf 'image:\n  tag: "000000000000"\n' >>"$t/envs/stg/gateway.yaml"
check "an overlay that sets image" "$t" "envs/stg/gateway.yaml sets image, canary or httpRoute.name"
render "an overlay that sets image (root chart)" "$t" stg "envs/stg/gateway.yaml sets image, canary or httpRoute.name"

t=$(copy)
cp -R "$t/envs/stg" "$t/envs/qa"
check "an unknown environment" "$t" "envs/ holds 'prd qa stg': the environments are exactly prd and stg"
render "an unknown environment (root chart)" "$t" nope 'env is "nope": envs/ has no directory of that name'

t=$(copy)
sed -i.bak 's/^revision:.*/revision:/' "$t/envs/stg/charts.yaml" && rm "$t/envs/stg/charts.yaml.bak"
check "an empty revision" "$t" "envs/stg/charts.yaml: revision is '', the full commit (40 hex)"
render "an empty revision (root chart)" "$t" stg 'envs/stg/charts.yaml: revision is "", the full commit (40 hex)'

t=$(copy)
tag=$(sed -n 's/^  tag: "\{0,1\}\([0-9a-f]*\)"\{0,1\}$/\1/p' "$t/envs/stg/images/gateway.yaml")
parent=$(git -C "$repo_root" rev-parse --verify "$tag^1^{commit}")
psv=$(git -C "$repo_root" show "$parent:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')
sum=$(git -C "$repo_root" show "$parent:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1)
printf 'revision: %s\npodSecurityVersion: %s\ncollectorConfigSha256: %s\n' "$parent" "$psv" "$sum" \
  >"$t/envs/stg/charts.yaml"
check "an image newer than the charts" "$t" \
  "envs/stg/images/gateway.yaml: tag $tag is no ancestor of revision ${parent:0:12} of envs/stg/charts.yaml"

t=$(copy)
sed -i.bak "s/^collectorConfigSha256:.*/collectorConfigSha256: $(printf '0%.0s' $(seq 64))/" "$t/envs/stg/charts.yaml" &&
  rm "$t/envs/stg/charts.yaml.bak"
check "a wrong collectorConfigSha256" "$t" "envs/stg/charts.yaml: collectorConfigSha256 is '$(printf '0%.0s' $(seq 64))'"

t=$(copy)
sed -i.bak 's|^targetRevision: .*|targetRevision: main|' "$t/argocd/apps/values.yaml" && rm "$t/argocd/apps/values.yaml.bak"
check "a short targetRevision" "$t" \
  "every source of https://github.com/anhnvcoder/svp-gitops.git must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not main"

# --- the release sources of the image files (step 1 alone: gitops-check.sh --tree). A throwaway copy of this
# repository: k0 holds the policy's values as they were before the table of release sources (its one source backend
# is read from them), k1 the table; origin/main is k1. A throwaway clone of svp-web: w0 on its main, w1 on a branch.
services=(gateway user-service video-service engagement-service feed-service media-worker web)
code=$work/code
mkdir -p "$code/deploy/k8s" "$code/deploy/helm/svp-policy" "$code/deploy/helm/svp-cluster" "$code/deploy/observability/otelcol"
cp -R "$here" "$code/deploy/ci"
cp "$repo_root/deploy/k8s/lib.sh" "$code/deploy/k8s/"
printf 'podSecurityVersion: v1.36\n' >"$code/deploy/helm/svp-cluster/values.yaml"
echo "receivers: {}" >"$code/deploy/observability/otelcol/k8s-config.yaml"
cat >"$code/deploy/helm/svp-policy/values.yaml" <<'VALUES'
imageVerification:
  imagePrefix: ghcr.io/anhnvcoder/short-video-platform/
  issuer: https://token.actions.githubusercontent.com
  subject: https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
  provenanceRepository: https://github.com/anhnvcoder/short-video-platform
  provenanceRef: refs/heads/main
  requireProvenance: false
VALUES
cg() { git -C "$code" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
cg init -q && cg add -A && cg commit -q -m "before the table"
k0=$(cg rev-parse HEAD)
cp "$repo_root/deploy/helm/svp-policy/values.yaml" "$code/deploy/helm/svp-policy/values.yaml"
cp -R "$repo_root/deploy/helm/svp-policy/files" "$code/deploy/helm/svp-policy/"
cg add -A && cg commit -q -m "the table of release sources"
k1=$(cg rev-parse HEAD)
cg update-ref refs/remotes/origin/main "$k1"
web=$work/svp-web
git init -q "$web"
wg() { git -C "$web" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
wg remote add origin https://github.com/anhnvcoder/svp-web
wg commit -q --allow-empty -m w0 && w0=$(wg rev-parse HEAD)
wg commit -q --allow-empty -m w1 && w1=$(wg rev-parse HEAD)
wg update-ref refs/remotes/origin/main "$w0"
other=$work/other
git init -q "$other"
git -C "$other" remote add origin https://github.com/someone/svp-web
# sources_tree WEB_STG: a copy of the tree with stg at k1 and prd at k0 of the throwaway repository, every release of
# backend built at k0, web of stg WEB_STG ("repository tag"), of prd backend's.
sources_tree() {
  local t env rev svc repo tag
  t=$(copy)
  for env in stg prd; do
    rev=$k1
    [ "$env" = stg ] || rev=$k0
    printf 'revision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$rev" \
      "$(shasum -a 256 <"$code/deploy/observability/otelcol/k8s-config.yaml" | cut -d' ' -f1)" >"$t/envs/$env/charts.yaml"
    for svc in "${services[@]}"; do
      repo=ghcr.io/anhnvcoder/short-video-platform/$svc tag=${k0:0:12}
      if [ "$env/$svc" = stg/web ]; then read -r repo tag <<<"$1"; fi
      printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "sha256:%064d"\n' "$repo" "$tag" 0 \
        >"$t/envs/$env/images/$svc.yaml"
    done
  done
  echo "$t"
}
# tree_check NAME WANT_RC MESSAGE DIR [VAR=VALUE...]: gitops-check.sh --tree of the throwaway repository on DIR, with
# no network (git may use local paths only); MESSAGE on its output.
tree_check() {
  local name=$1 want=$2 msg=$3 dir=$4 out rc=0
  shift 4
  out=$(env -u SVP_SOURCE_DIR_WEB GIT_ALLOW_PROTOCOL=file "$@" "$code/deploy/ci/gitops-check.sh" --tree "$dir" 2>&1) || rc=$?
  if [ "$want" = 0 ] && [ "$rc" != 0 ]; then
    fail "$name: gitops-check.sh --tree failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$want" != 0 ] && [ "$rc" = 0 ]; then
    fail "$name: gitops-check.sh --tree passed"
  elif [[ $out == *"$msg"* ]]; then
    ok "$name"
  else
    fail "$name: no '$msg' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
t=$(sources_tree "ghcr.io/anhnvcoder/svp-web/web ${w0:0:12}")
tree_check "sources: web of svp-web in stg (charts with the table), backend's in prd (charts before it)" 0 \
  "ok    envs/stg/images/: seven releases, each of a release source the policy of ${k1:0:12} admits" "$t" \
  SVP_SOURCE_DIR_WEB="$web"
t=$(sources_tree "ghcr.io/anhnvcoder/short-video-platform/web ${k0:0:12}")
tree_check "sources: no release of svp-web, no clone of svp-web needed" 0 \
  "ok    envs/prd/images/: seven releases, each of a release source the policy of ${k0:0:12} admits" "$t"
t=$(sources_tree "ghcr.io/anhnvcoder/svp-web/web ${w1:0:12}")
tree_check "sources: a web tag that is no commit on main of svp-web" 1 \
  "envs/stg/images/web.yaml: tag ${w1:0:12} is no commit on main of https://github.com/anhnvcoder/svp-web (release source web)" \
  "$t" SVP_SOURCE_DIR_WEB="$web"
t=$(sources_tree "ghcr.io/anhnvcoder/svp-web/web ${w0:0:12}")
cp "$t/envs/stg/images/web.yaml" "$t/envs/prd/images/web.yaml"
tree_check "sources: a release of svp-web where the charts know no such source" 1 \
  "envs/prd/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/short-video-platform/web with its tag and digest" \
  "$t" SVP_SOURCE_DIR_WEB="$web"
t=$(sources_tree "ghcr.io/anhnvcoder/svp-web/web ${w0:0:12}")
tree_check "sources: SVP_SOURCE_DIR_WEB names a clone of another repository" 1 \
  "SVP_SOURCE_DIR_WEB=$other is not a clone of https://github.com/anhnvcoder/svp-web (its origin is 'https://github.com/someone/svp-web')" \
  "$t" SVP_SOURCE_DIR_WEB="$other"
# values-check.sh on such a tree, as a machine runs it (env -i: no CI job's variables): the gateway's file naming the
# repository of user-service is refused before any release is verified (no other file carries a digest, so cosign is
# never asked).
t=$(sources_tree "ghcr.io/anhnvcoder/short-video-platform/web ${k0:0:12}")
for f in "$t"/envs/*/images/*.yaml; do sed -i.bak 's/^  digest: .*/  digest: ""/' "$f" && rm "$f.bak"; done
printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/user-service\n  tag: "%s"\n  digest: "sha256:%064d"\n' \
  "${k0:0:12}" 0 >"$t/envs/stg/images/gateway.yaml"
rc=0
out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" "$code/deploy/ci/values-check.sh" --gitops "$t" "" 2>&1) ||
  rc=$?
want="FAIL  envs/stg/images/gateway.yaml: image.repository is ghcr.io/anhnvcoder/short-video-platform/user-service, a repository of user-service, not of gateway"
if [ "$rc" = 1 ] && [[ $out == *"$want"* ]] && [[ $out != *"check envs/"* ]]; then
  ok "values-check: an image file naming the repository of another service"
else
  fail "values-check: an image file naming the repository of another service (exit $rc, want 1, '$want', no release verified):"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi

# --- step 1c, the author of a pull request (gitops-check.sh --tree DIR BASE of the throwaway repository, as a machine
# runs it: env -i, so no CI job's variables, the author in SVP_CHANGE_REQUEST_AUTHOR). The tree becomes a git
# repository: a0 runs web of backend in stg (before the takeover), a1 web of svp-web; each case commits one change on
# top of one of them. stg pins k1 (the table, which knows the bot of svp-web), prd k0 (one source backend, read from
# the values).
at=$(sources_tree "ghcr.io/anhnvcoder/short-video-platform/web ${k0:0:12}")
ag() { git -C "$at" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
ag init -q && ag add -A && ag commit -q -m "web of backend"
a0=$(ag rev-parse HEAD)
# image FILE REPOSITORY TAG DIGEST_SEED: writes the image block of FILE in the tree.
image() {
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "sha256:%s"\n' "$2" "$3" \
    "$(printf '%s' "$4" | shasum -a 256 | cut -c1-64)" >"$at/$1"
}
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/svp-web/web "${w0:0:12}" a1
ag commit -q -am "web of svp-web"
a1=$(ag rev-parse HEAD)
web_bot=svp-web-promoter[bot] backend_bot=svp-gitops-promoter[bot]
# from BASE: the tree back at BASE, on a branch of its own, for the next case's change.
from() { ag checkout -q -f -B "case" "$1"; }
# author_case NAME WANT_RC MESSAGE AUTHOR [BASE] [SENDER]: the change of the tree committed, then gitops-check.sh
# --tree against BASE (a0 by default) as a pull request of AUTHOR whose event SENDER caused (none by default); MESSAGE
# on its output.
author_case() {
  local name=$1 want=$2 msg=$3 out rc=0 sender=()
  [ -z "${6:-}" ] || sender=(SVP_CHANGE_REQUEST_SENDER="$6")
  ag add -A && ag commit -q -m "$name" --allow-empty
  out=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" GIT_ALLOW_PROTOCOL=file SVP_SOURCE_DIR_WEB="$web" \
    SVP_CHANGE_REQUEST_AUTHOR="$4" ${sender[@]+"${sender[@]}"} "$code/deploy/ci/gitops-check.sh" --tree "$at" \
    "${5:-$a0}" 2>&1) || rc=$?
  if [ "$want" = 0 ] && [ "$rc" != 0 ]; then
    fail "author: $name: gitops-check.sh --tree failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$want" != 0 ] && [ "$rc" = 0 ]; then
    fail "author: $name: gitops-check.sh --tree passed"
  elif [[ $out == *"$msg"* ]]; then
    ok "author: $name"
  else
    fail "author: $name: no '$msg' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
from "$a0"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/svp-web/web "${w0:0:12}" t1
author_case "the bot of svp-web takes web over from backend" 0 \
  "ok    envs/stg/images/web.yaml: $web_bot, the bot of release source web, takes web over from release source backend" \
  "$web_bot"
from "$a1"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/svp-web/web "${w0:0:12}" t2
author_case "the bot of svp-web moves web to another of its releases" 0 \
  "ok    the pull request of $web_bot, the promoter of a release source: its 1 changed files are all files its source may change" \
  "$web_bot" "$a1"
from "$a0"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/short-video-platform/web "${k0:0:12}" t3
author_case "the bot of svp-web writes a release of backend" 1 \
  "envs/stg/images/web.yaml: $web_bot, the bot of release source web, wrote image 'ghcr.io/anhnvcoder/short-video-platform/web': it writes releases of its own source only, ghcr.io/anhnvcoder/svp-web/web" \
  "$web_bot"
from "$a0"
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/short-video-platform/gateway "${k0:0:12}" t4
author_case "the bot of svp-web changes gateway.yaml" 1 \
  "envs/stg/images/gateway.yaml: changed by $web_bot, the bot of release source web, which publishes web" "$web_bot"
from "$a0"
echo '# changed' >>"$at/envs/stg/charts.yaml"
author_case "the bot of svp-web changes charts.yaml" 1 \
  "envs/stg/charts.yaml: changed by $web_bot, the bot of release source web: only the bot of backend" "$web_bot"
from "$a0"
echo '# changed' >>"$at/envs/prd/images/web.yaml"
author_case "the bot of svp-web changes envs/prd/, whose charts know no such bot" 1 \
  "envs/prd/images/web.yaml: changed by $web_bot, which promotes no release source of the charts envs/prd runs (${k0:0:12})" \
  "$web_bot"
from "$a0"
echo '# changed' >>"$at/envs/stg/svp-cluster.yaml"
author_case "the bot of svp-web changes an overlay of stg" 1 \
  "envs/stg/svp-cluster.yaml: changed by $web_bot, the bot of release source web: a bot changes the image files of its services in envs/stg/images/ only" \
  "$web_bot"
from "$a0"
rm "$at/envs/stg/images/web.yaml"
author_case "the bot of svp-web deletes web.yaml" 1 \
  "envs/stg/images/web.yaml: deleted by $web_bot, the bot of release source web: a bot changes the image file of a service, never deletes it" \
  "$web_bot"
from "$a0"
image envs/stg/images/search.yaml ghcr.io/anhnvcoder/svp-web/search "${w0:0:12}" t5
author_case "the bot of svp-web adds the image file of a service it does not publish" 1 \
  "envs/stg/images/search.yaml: changed by $web_bot, the bot of release source web, which publishes web" "$web_bot"
from "$a0"
echo '# changed' >>"$at/base/tempo.yaml"
author_case "the bot of svp-web changes base/" 1 \
  "base/tempo.yaml: changed by $web_bot, the promoter of a release source, which changes nothing outside envs/" "$web_bot"
from "$a0"
echo '# changed' >>"$at/.github/workflows/check.yml"
author_case "the bot of backend changes the workflow of the check" 1 \
  ".github/workflows/check.yml: changed by $backend_bot, the promoter of a release source, which changes nothing outside envs/" \
  "$backend_bot"
from "$a0"
echo '# changed' >>"$at/envs/stg/charts.yaml"
echo '# changed' >>"$at/envs/prd/images/gateway.yaml"
echo '# changed' >>"$at/envs/prd/charts.yaml"
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/short-video-platform/gateway "${k0:0:12}" t6
author_case "the bot of backend promotes stg with charts.yaml and prd (prd's charts from before the table)" 0 \
  "ok    the pull request of $backend_bot, the promoter of a release source: its 4 changed files are all files its source may change" \
  "$backend_bot"
from "$a1"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/short-video-platform/web "${k0:0:12}" t7
author_case "the bot of backend takes web back from svp-web" 1 \
  "envs/stg/images/web.yaml: the image before (ghcr.io/anhnvcoder/svp-web/web) is a release of source web: $backend_bot, the bot of release source backend, takes a service over only from backend" \
  "$backend_bot" "$a1"
from "$a1"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/short-video-platform/web "${k0:0:12}" t8
echo '# changed' >>"$at/base/tempo.yaml"
author_case "a person moves web back and changes base/" 0 \
  "ok    the pull request is by anhnvcoder, a person: the files it changes are not limited by release source" anhnvcoder "$a1"
from "$a0"
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/short-video-platform/gateway "${k0:0:12}" t9
author_case "a bot that promotes no release source changes envs/" 1 \
  "envs/stg/images/gateway.yaml: changed by renovate[bot], which promotes no release source of the charts envs/stg runs (${k1:0:12})" \
  "renovate[bot]"
from "$a0"
echo '# changed' >>"$at/base/tempo.yaml"
author_case "a bot that promotes no release source changes base/" 0 \
  "ok    the pull request of renovate[bot], a bot that promotes no release source: none of its 1 changed files is under envs/" \
  "renovate[bot]"
from "$a0"
image envs/stg/images/web.yaml ghcr.io/anhnvcoder/svp-web/web "${w0:0:12}" t10
author_case "an author that is no login fails closed" 1 \
  "the author of the pull request cannot be read (above): the files a bot may change depend on which bot it is" "not a login"
author_case "a run of no pull request skips the rule" 0 \
  "skip  the author of a pull request: this run checks no pull request" ""
# The sender of the event: the bot of svp-web pushing onto the pull request of the bot of backend fails, though the
# files are ones backend's bot may change; so does a bot pushing onto a person's; a person pushing onto a bot's pull
# request, or the author itself, is judged by the author's rule.
from "$a0"
image envs/stg/images/gateway.yaml ghcr.io/anhnvcoder/short-video-platform/gateway "${k0:0:12}" t11
author_case "the bot of svp-web pushes onto the pull request of the bot of backend" 1 \
  "the commit checked was pushed by $web_bot onto the pull request of $backend_bot: a bot pushes onto its own pull requests only" \
  "$backend_bot" "$a0" "$web_bot"
author_case "a person pushes onto the pull request of the bot of backend" 0 \
  "ok    the pull request of $backend_bot, the promoter of a release source: its 1 changed files are all files its source may change" \
  "$backend_bot" "$a0" anhnvcoder
author_case "the bot of backend pushes onto its own pull request" 0 \
  "ok    the pull request of $backend_bot, the promoter of a release source: its 1 changed files are all files its source may change" \
  "$backend_bot" "$a0" "$backend_bot"
author_case "a bot pushes onto the pull request of a person" 1 \
  "the commit checked was pushed by renovate[bot] onto the pull request of anhnvcoder" anhnvcoder "$a0" "renovate[bot]"
author_case "a sender that is no login fails closed" 1 \
  "the sender of the pull request's event cannot be read (above)" "$backend_bot" "$a0" "not a login"
from "$a0"

# --- envs/prd/ against the records of stg (step 1b), with a fake gh first on PATH that lists the records and their
# states as the host would, each run a run of verify.yml on main. The copy becomes a git repository whose first commit is the base and origin/main; each
# case commits a change of envs/prd/ on top of it.
mkdir -p "$work/bin" "$work/gh"
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
"api -X")
  path=$4
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  case $path in
  */deployments/*/statuses) echo '[{"state": "success"}]' | jq -r "$2" ;;
  */deployments) jq -r "$2" "$FAKE_GH_DIR/deployments.json" ;;
  */actions/runs/*) echo '{"path": ".github/workflows/verify.yml", "head_branch": "main"}' | jq -r "$2" ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
FAKE
chmod 755 "$work/bin/gh"
rt=$(copy)
rg() { git -C "$rt" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
rg init -q && rg add -A && rg commit -q -m base
b0=$(rg rev-parse HEAD)
rg update-ref refs/remotes/origin/main "$b0"
rg checkout -q -b side && rg commit -q --allow-empty -m side && side=$(rg rev-parse HEAD) && rg checkout -q -
# The releases of envs/stg/images/ of the copy as a payload's images; set X: those and the charts of
# envs/stg/charts.yaml; set Y: X with other releases of the gateway and of web.
stg_images=$(for svc in "${services[@]}"; do
  f=$rt/envs/stg/images/$svc.yaml
  jq -c -n --arg s "$svc" --arg r "$(sed -n 's/^  repository: *//p' "$f")" \
    --arg t "$(sed -n 's/^  tag: *"\{0,1\}\([0-9a-f]*\)"\{0,1\}$/\1/p' "$f")" \
    --arg d "$(sed -n 's/^  digest: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f")" '{($s): {repository: $r, tag: $t, digest: $d}}'
done | jq -s -c 'add')
charts_x=$(jq -c -n --arg r "$(sed -n 's/^revision: *//p' "$rt/envs/stg/charts.yaml")" \
  --arg p "$(sed -n 's/^podSecurityVersion: *//p' "$rt/envs/stg/charts.yaml")" \
  --arg s "$(sed -n 's/^collectorConfigSha256: *//p' "$rt/envs/stg/charts.yaml")" \
  '{revision: $r, podSecurityVersion: $p, collectorConfigSha256: $s}')
other_digest() { echo "sha256:$(printf '%s' "$1" | shasum -a 256 | cut -c1-64)"; }
set_x=$(jq -c -n --argjson i "$stg_images" --argjson c "$charts_x" '{images: $i, charts: $c}')
set_y=$(jq -c --arg g "$(other_digest y-gateway)" --arg w "$(other_digest y-web)" \
  '.images.gateway.digest = $g | .images.web.digest = $w' <<<"$set_x")
# record ID REF SET: a record as the host lists it, made by the app.
record() {
  jq -c -n --argjson id "$1" --arg ref "$2" --argjson set "$3" '{id: $id, sha: $ref, ref: $ref,
    created_at: "2026-10-30T00:00:00Z", creator: {login: "svp-gitops-promoter[bot]"},
    payload: ($set + {environment: "stg", ref: $ref, deployed_at: "2026-10-30T00:00:00Z",
      run_url: "https://github.com/anhnvcoder/short-video-platform/actions/runs/\($id)", steps: []})}'
}
{ record 23 "$side" "$set_y"; record 22 "$b0" "$set_y"; record 21 "$b0" "$set_x"; } | jq -s . >"$work/gh/deployments.json"
# prd_case SET: envs/prd/ of the repository at origin/main, then SET written there, committed.
prd_case() {
  local svc
  rg checkout -q -f "$(rg rev-parse refs/remotes/origin/main)"
  for svc in "${services[@]}"; do
    jq -r --arg s "$svc" '.images[$s] | "# The release image of \($s) in prd.\nimage:\n  repository: \(.repository)\n  tag: \"\(.tag)\"\n  digest: \"\(.digest)\""' \
      <<<"$1" >"$rt/envs/prd/images/$svc.yaml"
  done
  jq -r '.charts | "# The charts prd runs.\nrevision: \(.revision)\npodSecurityVersion: \(.podSecurityVersion)\ncollectorConfigSha256: \(.collectorConfigSha256)"' \
    <<<"$1" >"$rt/envs/prd/charts.yaml"
  rg commit -q -am prd --allow-empty
}
# records NAME WANT_EXIT MESSAGE [BASE]: gitops-check.sh --records on the repository against BASE (the first commit);
# MESSAGE on its output.
records() {
  local out rc=0
  out=$(PATH="$work/bin:$PATH" FAKE_GH_DIR="$work/gh" "$here/gitops-check.sh" --records "$rt" "${4:-$b0}" 2>&1) || rc=$?
  if [ "$2" = 0 ] && [ "$rc" != 0 ]; then
    fail "$1: gitops-check.sh --records failed:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  elif [ "$2" != 0 ] && [ "$rc" = 0 ]; then
    fail "$1: gitops-check.sh --records passed"
  elif [[ $out == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1: no '$3' in:"$'\n'"$(sed 's/^/      /' <<<"$out")"
  fi
}
mixed=$(jq -c --arg w "$(jq -r .images.web.digest <<<"$set_x")" '.images.web.digest = $w' <<<"$set_y")
prd_case "$set_y"
records "prd: exactly the set of one record" 0 "ok    envs/prd/ runs exactly the set of record #22 of stg (svp-gitops ${b0:0:12}"
records "prd: a record whose commit is not on main is left out" 0 \
  "skip  record #23: its commit ${side:0:12} is not on main of svp-gitops"
prd_case "$mixed"
records "prd: a set mixed from two records" 1 \
  "envs/prd/images/ mixes releases of several records of stg (gateway as in #22; user-service as in #22 #21;"
records "prd: a set mixed from two records names web's" 1 "web as in #21)"
prd_case "$(jq -c '.charts.podSecurityVersion = "v1.99"' <<<"$set_y")"
records "prd: the seven releases of a record with other charts" 1 \
  "envs/prd/images/ holds the seven releases of record #22 of stg, but envs/prd/charts.yaml is not its charts"
# A set merged into envs/stg/images/ of main with no record: release Z of the gateway.
set_z=$(jq -c --arg g "$(other_digest z-gateway)" '.images.gateway.digest = $g' <<<"$set_x")
rg checkout -q -f "$b0"
sed -i.bak "s|^  digest: .*|  digest: \"$(jq -r .images.gateway.digest <<<"$set_z")\"|" "$rt/envs/stg/images/gateway.yaml" &&
  rm "$rt/envs/stg/images/gateway.yaml.bak"
rg commit -q -am "stg: gateway z"
b1=$(rg rev-parse HEAD)
rg update-ref refs/remotes/origin/main "$b1"
prd_case "$set_z"
records "prd: a set only in the history of envs/stg/" 1 \
  "envs/prd/images/ is the set of envs/stg/images/ at ${b1:0:12} of svp-gitops, but no record of stg holds it" "$b1"
rg update-ref refs/remotes/origin/main "$b0"
# The same step in the whole check, before anything reaches the network. As a machine runs it (env -i): in a CI job
# of a pull request, step 1c would judge the files by that pull request's author.
prd_case "$mixed"
rc=0
out=$(env -i PATH="$work/bin:$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" FAKE_GH_DIR="$work/gh" \
  "$here/gitops-check.sh" "$rt" "$b0" 2>&1) || rc=$?
if [ "$rc" != 0 ] && [[ $out == *"mixes releases of several records of stg"* ]] &&
  [[ $out == *"FAIL  envs/prd/ against the records of stg: the problems above"* ]]; then
  ok "prd: the whole check stops at the records"
else
  fail "prd: the whole check stops at the records (exit $rc):"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi

# tag_provenance_mismatch of common.sh (step 5 of the check, which needs the network): image.tag against the commit the
# release's check names, and no pass when an environment requiring provenance gets a check that names none.
tp=$work/tag-provenance
mkdir -p "$tp/envs/stg/images" "$tp/envs/prd/images"
printf 'image:\n  tag: "aaaaaaaaaaaa"\n  digest: "sha256:%064d"\n' 0 >"$tp/envs/stg/images/gateway.yaml"
cp "$tp/envs/stg/images/gateway.yaml" "$tp/envs/prd/images/gateway.yaml"
# tp_case NAME ENVS WANT OK_LINE: the check of envs/stg/images/gateway.yaml printed OK_LINE; the output must be WANT.
tp_case() {
  local got
  printf 'check envs/stg/images/gateway.yaml\n%s\n' "$4" >"$tp/out"
  got=$(bash -c '. "$1/common.sh" && tag_provenance_mismatch "$2" "$3" "$4"' _ "$here" "$tp" "$tp/out" "$2")
  [ "$got" = "$3" ] && ok "tag/provenance: $1" || fail "tag/provenance: $1: got '$got'"
}
prov_ok="ok    ghcr.io/x/gateway@sha256:0 signed, one vuln attestation, both platforms, no CRITICAL, within 2880 minutes"
tp_case "the tag is the commit the provenance names" "stg" "" \
  "$prov_ok, provenance of aaaaaaaaaaaa by https://example.invalid/images.yml@refs/heads/main"
tp_case "another commit is a mismatch" "stg" \
  "envs/stg/images/gateway.yaml: image.tag is aaaaaaaaaaaa, but its provenance says it was built from bbbbbbbbbbbb" \
  "$prov_ok, provenance of bbbbbbbbbbbb by https://example.invalid/images.yml@refs/heads/main"
tp_case "no provenance where it is required is a problem" "stg prd" \
  "envs/stg/images/gateway.yaml: stg requires provenance, but the check of its release names no provenance commit" \
  "$prov_ok"
tp_case "a reworded provenance line fails, it does not pass" "stg" \
  "envs/stg/images/gateway.yaml: stg requires provenance, but the check of its release names no provenance commit" \
  "$prov_ok, provenance from aaaaaaaaaaaa signed by https://example.invalid/images.yml@refs/heads/main"
tp_case "no provenance where none is required passes" "prd" "" "$prov_ok"

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
