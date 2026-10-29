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
#   - a short targetRevision (main, not refs/heads/main) for the sources of svp-gitops in argocd/apps/values.yaml.
# First, gitops_dir of deploy/k8s/lib.sh, which every script asks for the clone of svp-gitops, in a draft workspace laid
# out as the lab's (<workspace>/backend, a git repository holding a copy of lib.sh; a worktree of it in
# <workspace>/.worktrees/; <workspace>/gitops): from the main checkout, from a folder inside it and from the worktree it
# names <workspace>/gitops once that is a clone of svp-gitops; SVP_GITOPS_DIR names another clone; a missing folder, a
# folder that is no git repository, a repository with another origin and a folder inside a clone are refused with the
# command that makes the clone, and nothing is cloned.
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

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
