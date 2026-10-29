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
#   - envs/prd/ against the records of stg (gitops-check.sh --records, a fake gh listing the records): exactly the set
#     of one record passes; a set mixed from two records, the seven releases of a record with other charts, and a set
#     merged into envs/stg/images/ of main that no record holds each fail with their own message; a record whose
#     commit is not on main of svp-gitops is left out; the whole check stops at that step for a mixed set.
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
services=(gateway user-service video-service engagement-service feed-service media-worker web)
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
# The same step in the whole check, before anything reaches the network.
prd_case "$mixed"
rc=0
out=$(PATH="$work/bin:$PATH" FAKE_GH_DIR="$work/gh" "$here/gitops-check.sh" "$rt" "$b0" 2>&1) || rc=$?
if [ "$rc" != 0 ] && [[ $out == *"mixes releases of several records of stg"* ]] &&
  [[ $out == *"FAIL  envs/prd/ against the records of stg: the problems above"* ]]; then
  ok "prd: the whole check stops at the records"
else
  fail "prd: the whole check stops at the records (exit $rc):"$'\n'"$(sed 's/^/      /' <<<"$out")"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
