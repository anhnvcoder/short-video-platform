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
#   - a wrong collectorConfigSha256.
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

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
