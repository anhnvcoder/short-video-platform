#!/usr/bin/env bash
# Tests for deploy/ci/dora.sh, the DORA metrics of stg, on fixed made-up data: a throwaway copy of this repository
# (deploy/ci/, lib.sh, services, charts, postmortems) and a throwaway repository standing for svp-gitops, every commit at
# a fixed time, and a fake gh that answers the records of stg, their statuses and the runs they name. Now is
# 2026-10-30T12:00:00Z. The story:
#   code   k0 (09-01), release commit of the old promote (09-04), k1..k5 gateway (09-05 00:00..04:00), docs (09-05),
#          release commit (10-02), k8 chart (10-04), k7 feed-service (10-10), k9 video-service (10-19)
#   gitops G0 (09-02) every release at k0 = set A, G1 (09-06) gateway at k5, G2a (10-05) base/ (configuration),
#          G2 (10-05 01:00) charts at k8, G3 (10-14) feed-service at k7, G4 (10-16) "revert: ..." with Refs: G3 (feed
#          back), G5 (10-20) video-service at k9, merged but never recorded, G6 (10-21) prd images
#   stg    D0 = G0 (09-03), D1 = G1 (09-07), D2 = G2 with three records (10-06, 10-08, 10-12; the second inactive now
#          but success before), D3 = G3 (10-15), D4 = G4 (10-17); left out: a record with no success left, one made by
#          someone else, one of a run of images.yml, a failed one, one whose payload has no charts
# Checked:
#   - a deployment with evidence; three records of one (R, set): one deployment, three checks, its lead time from the
#     deployed_at of the first record; R1/A → R2/A (only the charts and base/ changed): two deployments, no rollback;
#     A → B → A over three revisions with a revert: three deployments, the last a rollback, the middle one failed;
#   - a release merged with no record (G5): no deployment, no lead time, listed as merged, not deployed, counted as a
#     promote; the release commits of the code repository counted apart, before the split;
#   - one lead time sample per change at the earliest deployment that holds it; none for the first deployment; the
#     docs commit is no change;
#   - a postmortem pointing at D3: its started_at and restored_at give the recovery; one with deployment none listed
#     as not caused by a deployment; one without front matter warned about;
#   - the 30-day window against since the split, and --days 60; the first commit of svp-gitops (G0, the import at the
#     split) is no promote in any window;
#   - prd: "chưa có dữ liệu prd"; below the thresholds "chưa đủ dữ liệu" with n, never a number; a median once there
#     are 5 samples; no record at all: deployment frequency is insufficient data, not 0;
#   - records left out are listed with why; 100 records, as many as one list returns: warned about; a bad --days is
#     refused; the JSON goes into a directory that does not exist yet;
#   - release source web: with no record holding a web release of svp-web, --clones names nothing and the run needs
#     no clone of svp-frontend (none exists); records that do (G7 at wa, G8 at wc of a throwaway clone of svp-web, after G4
#     of backend's web): --clones names web, the run without a clone stops
#     saying why, and with one (SVP_WEB_DIR) the lead time of web counts the commits of svp-web: none at the first
#     deployment of its web, wb and wc at the next; once a later commit of the code repository drops web from
#     backend's services in the table, the record whose web is backend's still counts (judged by the table at its
#     charts revision);
#   - the rename (tables of release sources written as they were, not the working tree's): the records above name
#     their runs under the code repository's former name and count; G9 runs the charts of the rename with the six
#     services of the new backend and web of the retired oldweb, G10 web of the new web source; with the working
#     tree's table dropping the retired sources, every record still counts, --clones names web once, the lead time
#     goes on through the rename on one history per repository (the first deployment of the new backend samples only
#     what G4 did not hold, the web of oldweb and of web share the clone of svp-frontend, wd alone new at G10).
# Every run is a machine's (env -i: no variable of a CI job running this test). Runs on macOS and Linux: no network.
#
# Usage, from anywhere: deploy/ci/dora-test.sh
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
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
expect() {
  if grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1: no '$3' in:"$'\n'"$(sed 's/^/      /' "$2")"; fi
}
refuse() {
  if grep -qF -- "$3" "$2"; then fail "$1: '$3' in:"$'\n'"$(sed 's/^/      /' "$2")"; else ok "$1"; fi
}

services=(gateway user-service video-service engagement-service feed-service media-worker web)
prefix=ghcr.io/anhnvcoder/short-video-platform
hex() { printf '%s' "$1" | shasum -a 256 | cut -c1-"$2"; }
digest() { echo "sha256:$(hex "$1" 64)"; }
gitops_url=https://github.com/anhnvcoder/svp-gitops.git
run_base=https://github.com/anhnvcoder/short-video-platform/actions/runs

# --- Fake gh: each call to gh.log; api: the records of stg from gh/deployments.json, the statuses of each from
# gh/statuses-<id>.json, a run of the code repository from gh/run-<id>.json (none: the host fails), through its --jq
# filter.
mkdir -p "$work/bin" "$work/gh" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"api -X")
  path=$4
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  case $path in
  */deployments/*/statuses) id=${path%/statuses} && jq -r "$2" "$FAKE_GH_DIR/statuses-${id##*/}.json" ;;
  */deployments) jq -r "$2" "$FAKE_GH_DIR/deployments.json" ;;
  */actions/runs/*)
    [ -f "$FAKE_GH_DIR/run-${path##*/}.json" ] || { echo "HTTP 404: Not Found" >&2 && exit 1; }
    jq -r "$2" "$FAKE_GH_DIR/run-${path##*/}.json"
    ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$work/bin/gh"

# --- This repository: deploy/ci/, lib.sh, the table of release sources, a file of each service, the charts, the
# collector config, docs.
tree=$work/code
mkdir -p "$tree/deploy/k8s/values/services" "$tree/deploy/helm/svp-cluster" "$tree/deploy/observability/otelcol" \
  "$tree/docs/postmortems"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
mkdir -p "$tree/deploy/helm/svp-policy/files"
cp "$src/deploy/helm/svp-policy/values.yaml" "$tree/deploy/helm/svp-policy/"
# sources NAME: writes table NAME of release sources into the tree (history, not the working tree's: the story spans
# the rename of both repositories). before: backend under short-video-platform publishing web too, web under svp-web;
# rename: backend and web under the new names beside the retired oldbackend and oldweb under the old ones; after: the
# two new sources alone, the retired ones dropped.
sources() {
  local old_b='{"name": "oldbackend", "repository": "https://github.com/anhnvcoder/short-video-platform",
    "imagePrefix": "ghcr.io/anhnvcoder/short-video-platform/", "drillImages": [],
    "services": ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker"],
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main",
    "provenanceRef": "refs/heads/main"}'
  local old_w='{"name": "oldweb", "repository": "https://github.com/anhnvcoder/svp-web",
    "imagePrefix": "ghcr.io/anhnvcoder/svp-web/", "services": ["web"], "drillImages": [],
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main",
    "provenanceRef": "refs/heads/main"}'
  local new_b='{"name": "backend", "repository": "https://github.com/anhnvcoder/svp-backend",
    "imagePrefix": "ghcr.io/anhnvcoder/svp-backend/", "drillImages": ["drill-vulnerable", "drill-unsigned"],
    "services": ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker"],
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main",
    "provenanceRef": "refs/heads/main", "promoter": "svp-gitops-promoter"}'
  local new_w='{"name": "web", "repository": "https://github.com/anhnvcoder/svp-frontend",
    "imagePrefix": "ghcr.io/anhnvcoder/svp-frontend/", "services": ["web"], "drillImages": [],
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "https://github.com/anhnvcoder/svp-frontend/.github/workflows/images.yml@refs/heads/main",
    "provenanceRef": "refs/heads/main", "promoter": "svp-web-promoter"}'
  local table
  case $1 in
  before)
    table="[$(jq -c '.name = "backend" | .services += ["web"] | .drillImages = ["drill-vulnerable", "drill-unsigned"]
      | .promoter = "svp-gitops-promoter"' <<<"$old_b"), $(jq -c '.name = "web" | .promoter = "svp-web-promoter"' <<<"$old_w")]" ;;
  rename) table="[$new_b, $new_w, $old_b, $old_w]" ;;
  after) table="[$new_b, $new_w]" ;;
  esac
  jq '{sources: .}' <<<"$table" >"$tree/deploy/helm/svp-policy/files/sources.json"
}
sources before
for svc in "${services[@]}"; do
  [ "$svc" = web ] && continue
  mkdir -p "$tree/services/$svc" && echo "package main // $svc" >"$tree/services/$svc/main.go"
done
echo "podSecurityVersion: v1.36" >"$tree/deploy/helm/svp-cluster/values.yaml"
echo "receivers: {}" >"$tree/deploy/observability/otelcol/k8s-config.yaml"
echo "# notes" >"$tree/docs/notes.md"
echo "image: {}" >"$tree/deploy/k8s/values/services/gateway.yaml"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
# cg_at TIME MESSAGE FILE TEXT: appends TEXT to FILE of the code tree and commits it at TIME; prints the commit.
cg_at() {
  echo "$4" >>"$tree/$3"
  g add -A
  GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1 g commit -q -m "$2"
  g rev-parse HEAD
}
g init -q -b main
k0=$(cg_at 2026-09-01T00:00:00Z base docs/notes.md "# base")
cg_at 2026-09-04T00:00:00Z "chore(release): phát hành gateway 000000000000 (#1)" deploy/k8s/values/services/gateway.yaml "# 1" >/dev/null
k1=$(cg_at 2026-09-05T00:00:00Z "feat(gateway): one" services/gateway/main.go "// 1")
k2=$(cg_at 2026-09-05T01:00:00Z "feat(gateway): two" services/gateway/main.go "// 2")
k3=$(cg_at 2026-09-05T02:00:00Z "feat(gateway): three" services/gateway/main.go "// 3")
k4=$(cg_at 2026-09-05T03:00:00Z "feat(gateway): four" services/gateway/main.go "// 4")
k5=$(cg_at 2026-09-05T04:00:00Z "feat(gateway): five" services/gateway/main.go "// 5")
k6=$(cg_at 2026-09-05T05:00:00Z "docs: notes" docs/notes.md "# more")
cg_at 2026-10-02T00:00:00Z "chore(release): phát hành gateway 111111111111 (#2)" deploy/k8s/values/services/gateway.yaml "# 2" >/dev/null
k8=$(cg_at 2026-10-04T00:00:00Z "feat(helm): chart" deploy/helm/svp-cluster/values.yaml "# chart")
k7=$(cg_at 2026-10-10T00:00:00Z "feat(feed): one" services/feed-service/main.go "// 1")
k9=$(cg_at 2026-10-19T00:00:00Z "feat(video): one" services/video-service/main.go "// 1")
g update-ref refs/remotes/origin/main HEAD

# --- svp-gitops.
config=$work/svp-gitops
gw() {
  GIT_DIR=$config/.git GIT_WORK_TREE=$config GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
image_file() { # ENV SERVICE COMMIT DIGEST
  mkdir -p "$config/envs/$1/images"
  printf '# The release of %s.\nimage:\n  repository: %s/%s\n  tag: "%s"\n  digest: "%s"\n' \
    "$2" "$prefix" "$2" "${3:0:12}" "$4" >"$config/envs/$1/images/$2.yaml"
}
charts_file() { # ENV COMMIT
  printf '# Charts.\nrevision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$2" "$(hex collector 64)" \
    >"$config/envs/$1/charts.yaml"
}
gc_at() { # TIME MESSAGE: commits everything at TIME, prints the commit
  gw add -A
  GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1 gw commit -q -m "$2"
  gw rev-parse HEAD
}
mkdir -p "$config/base"
gw init -q -b main
gw remote add origin "$gitops_url"
for env in stg prd; do
  for svc in "${services[@]}"; do image_file "$env" "$svc" "$k0" "$(digest "A-$svc")"; done
  charts_file "$env" "$k0"
done
echo "replicas: 1" >"$config/base/app.yaml"
r0=$(gc_at 2026-09-02T00:00:00Z "chore: khởi tạo")
image_file stg gateway "$k5" "$(digest B-gateway)"
r1=$(gc_at 2026-09-06T00:00:00Z "chore(release): gateway")
echo "replicas: 2" >"$config/base/app.yaml"
r2a=$(gc_at 2026-10-05T00:00:00Z "feat: two replicas")
charts_file stg "$k8"
r2=$(gc_at 2026-10-05T01:00:00Z "chore(release): charts")
image_file stg feed-service "$k7" "$(digest C-feed-service)"
r3=$(gc_at 2026-10-14T00:00:00Z "chore(release): feed-service")
image_file stg feed-service "$k0" "$(digest A-feed-service)"
r4=$(gc_at 2026-10-16T00:00:00Z "revert: chore(release): feed-service"$'\n\n'"Feed broke on stg."$'\n\n'"Refs: ${r3:0:12}")
image_file stg video-service "$k9" "$(digest D-video-service)"
gc_at 2026-10-20T00:00:00Z "chore(release): video-service" >/dev/null
image_file prd gateway "$k5" "$(digest B-gateway)"
gc_at 2026-10-21T00:00:00Z "chore(release): prd" >/dev/null
gw update-ref refs/remotes/origin/main HEAD

# --- The records of stg (newest first) and the runs they name.
# record ID R DEPLOYED_AT CREATED_AT RUN CREATOR GATEWAY FEED: one record of the list; the other services at k0, set A.
record() {
  local images='{}' svc commit dg
  for svc in "${services[@]}"; do
    commit=$k0 dg=$(digest "A-$svc")
    [ "$svc" != gateway ] || { [ "$7" = A ] || { commit=$k5 && dg=$(digest B-gateway); }; }
    [ "$svc" != feed-service ] || { [ "$8" = A ] || { commit=$k7 && dg=$(digest C-feed-service); }; }
    images=$(jq -c --arg s "$svc" --arg r "$prefix/$svc" --arg t "${commit:0:12}" --arg d "$dg" \
      '. + {($s): {repository: $r, tag: $t, digest: $d}}' <<<"$images")
  done
  jq -c -n --argjson id "$1" --arg r "$2" --arg at "$3" --arg c "$4" --arg run "$run_base/$5" --arg who "$6" \
    --argjson images "$images" --arg charts "$9" --arg sum "$(hex collector 64)" '{id: $id, sha: $r, ref: $r,
      created_at: $c, creator: {login: $who}, payload: {environment: "stg", ref: $r, images: $images,
        charts: {revision: $charts, podSecurityVersion: "v1.36", collectorConfigSha256: $sum}, deployed_at: $at,
        run_url: $run, steps: [], window: {}}}'
}
bot="svp-gitops-promoter[bot]"
{
  record 43 "$r4" 2026-10-18T00:00:00Z 2026-10-18T01:00:00Z 113 "$bot" B A "$k8"
  record 42 "$r4" 2026-10-18T00:00:00Z 2026-10-18T01:00:00Z 112 "$bot" B A "$k8"
  record 41 "$r4" 2026-10-18T00:00:00Z 2026-10-18T01:00:00Z 111 someone B A "$k8"
  record 40 "$r4" 2026-10-18T00:00:00Z 2026-10-18T01:00:00Z 110 "$bot" B A "$k8"
  record 44 "$r4" 2026-10-18T00:00:00Z 2026-10-18T01:00:00Z 114 "$bot" B A "$k8" | jq -c 'del(.payload.charts)'
  record 30 "$r4" 2026-10-17T00:00:00Z 2026-10-17T01:00:00Z 104 "$bot" B A "$k8"
  record 29 "$r3" 2026-10-15T00:00:00Z 2026-10-15T01:00:00Z 103 "$bot" B C "$k8"
  record 28 "$r2" 2026-10-12T00:30:00Z 2026-10-12T01:00:00Z 102 "$bot" B A "$k8"
  record 27 "$r2" 2026-10-08T00:30:00Z 2026-10-08T01:00:00Z 101 "$bot" B A "$k8"
  record 26 "$r2" 2026-10-06T00:30:00Z 2026-10-06T01:00:00Z 100 "$bot" B A "$k8"
  record 25 "$r1" 2026-09-07T00:00:00Z 2026-09-07T01:00:00Z 99 "$bot" B A "$k0"
  record 24 "$r0" 2026-09-03T00:00:00Z 2026-09-03T01:00:00Z 98 "$bot" A A "$k0"
} | jq -s . >"$work/gh/deployments.json"
for id in 24 25 26 28 29 30 41 42 44; do echo '[{"state": "success"}]' >"$work/gh/statuses-$id.json"; done
echo '[{"state": "inactive"}, {"state": "success"}]' >"$work/gh/statuses-27.json"
echo '[{"state": "inactive"}, {"state": "in_progress"}]' >"$work/gh/statuses-40.json"
echo '[{"state": "failure"}]' >"$work/gh/statuses-43.json"
for run in 98 99 100 101 102 103 104 110 111 113 114; do
  echo '{"path": ".github/workflows/verify.yml", "head_branch": "main"}' >"$work/gh/run-$run.json"
done
echo '{"path": ".github/workflows/images.yml", "head_branch": "main"}' >"$work/gh/run-112.json"

# --- Postmortems.
cat >"$tree/docs/postmortems/README.md" <<'EOF'
# Postmortem
EOF
cat >"$tree/docs/postmortems/261015-feed-broken.md" <<EOF
---
env: stg                    # stg | prd | compose | k3d
deployment: $r3
started_at: 2026-10-15T06:00:00Z
restored_at: 2026-10-16T18:00:00Z
fix_commits: [anhnvcoder/svp-gitops@$r4]
---
# Feed broke on stg
EOF
cat >"$tree/docs/postmortems/261024-gameday.md" <<'EOF'
---
env: compose
deployment: none
started_at: 2026-10-24T07:24:49Z
restored_at: 2026-10-24T07:27:53Z
fix_commits: []
---
# Game day
EOF
printf '# No front matter\n' >"$tree/docs/postmortems/261001-draft.md"

# run NAME ARGS...: runs dora.sh of the throwaway tree as a machine; stdout to NAME.out, stderr to NAME.err, prints
# the exit status.
# extra: VAR=VALUE words the next runs get too.
extra=()
run() {
  local name=$1 rc=0 now=(--now 2026-10-30T12:00:00Z)
  shift
  [ "${1:-}" != --clones ] || now=()
  env -i PATH="$work/bin:$PATH" HOME="$work/home" TMPDIR="${TMPDIR:-/tmp}" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" SVP_GITOPS_DIR="$config" \
    ${extra[@]+"${extra[@]}"} "$tree/deploy/ci/dora.sh" ${now[@]+"${now[@]}"} "$@" >"$work/$name.out" \
    2>"$work/$name.err" || rc=$?
  echo "$rc"
}
j() { jq -r "$1" "$work/dora.json"; }

# --- The story above.
rc=$(run main "$work/dora.json")
same "dora.sh exits 0" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/      /' "$work/main.err" >&2
same "five deployments: G0, G1, G2, G3, G4" "${r0:0:12} ${r1:0:12} ${r2:0:12} ${r3:0:12} ${r4:0:12}" \
  "$(j '[.stg.deployments[].ref[0:12]] | join(" ")')"
same "three records of (G2, A): one deployment, three checks, the deployed_at of the first" \
  "26,27,28 3 2026-10-06T00:30:00Z" "$(j '.stg.deployments[2] | "\(.records | join(",")) \(.checks) \(.deployed_at)"')"
same "R1/A → R2/A: two deployments, neither a rollback nor failed" "false false false false" \
  "$(j '[.stg.deployments[1, 2] | .rollback, .failed] | map(tostring) | join(" ")')"
same "A → B → A with a revert: the last a rollback, the middle failed" "false true true false" \
  "$(j '[.stg.deployments[3, 4] | .rollback, .failed] | map(tostring) | join(" ")')"
same "the first deployment holds no lead time sample" 0 "$(j '.stg.deployments[0].changes')"
same "one sample per change at its earliest deployment (kind, deployed_at, lead time in s)" \
  "$(printf '%s\n' "service gateway ${k1:0:12} 2026-09-07T00:00:00Z 172800" "service gateway ${k2:0:12} 2026-09-07T00:00:00Z 169200" \
    "service gateway ${k3:0:12} 2026-09-07T00:00:00Z 165600" "service gateway ${k4:0:12} 2026-09-07T00:00:00Z 162000" \
    "service gateway ${k5:0:12} 2026-09-07T00:00:00Z 158400" "chart null ${k8:0:12} 2026-10-06T00:30:00Z 174600" \
    "config null ${r2a:0:12} 2026-10-06T00:30:00Z 88200" "service feed-service ${k7:0:12} 2026-10-15T00:00:00Z 432000" | sort)" \
  "$(j '.stg.changes[] | "\(.kind) \(.service) \(.sha[0:12]) \(.deployed_at) \(.lead_time)"' | sort)"
refuse "a docs commit is no change" "$work/dora.json" "$k6"
refuse "a release merged with no record has no lead time" "$work/dora.json" "\"$k9\""
same "merged, not deployed: only the release of G5" "$prefix/video-service@$(digest D-video-service)" \
  "$(j '[.stg.merged_not_deployed[].image] | join(" ")')"
same "the failure: from started_at to restored_at of its postmortem, the rollback named" \
  "${r3:0:12} docs/postmortems/261015-feed-broken.md ${r4:0:12} 129600" \
  "$(j '.stg.failures[] | "\(.ref[0:12]) \(.postmortem) \(.rollbacks | map(.[0:12]) | join(",")) \(.recovery)"')"
same "the records left out, each with why" \
  "40 no success status left (inactive)|41 made by someone, not svp-gitops-promoter[bot]|42 its run $run_base/112 is of .github/workflows/images.yml on main, not of .github/workflows/verify.yml on main|43 its state is failure, not success|44 its payload: its charts are not revision (40 hex), podSecurityVersion and collectorConfigSha256" \
  "$(j '.stg.records_left_out | sort_by(.id) | map("\(.id) \(.reason)") | join("|")')"
expect "an inactive record with an earlier success counts, with a warning" "$work/dora.json" \
  "record #27 is inactive now, but one of its earlier statuses is success: counted"
expect "a postmortem without front matter is warned about" "$work/dora.json" "docs/postmortems/261001-draft.md has no front matter"
refuse "12 records: no warning about the most one list returns" "$work/dora.json" "as many as one list returns"
same "a postmortem with deployment none: not caused by a deployment" "docs/postmortems/261024-gameday.md compose none" \
  "$(j '.incidents_not_from_deployments[] | "\(.file) \(.env) \(.deployment)"')"

# The 30 days up to now hold D2, D3, D4; since the split (G0, 09-02) all five.
same "30 days: three deployments, five checks" "3 5" \
  "$(j '.stg.windows.last_days.deployment_frequency | "\(.count) \(.checks)"')"
same "since the split: five deployments, seven checks" "5 7" \
  "$(j '.stg.windows.since_split.deployment_frequency | "\(.count) \(.checks)"')"
same "30 days: lead time insufficient with three samples" "insufficient 3" \
  "$(j '.stg.windows.last_days.change_lead_time | "\(.status) \(.n)"')"
same "since the split: the median of eight samples (46.5 h)" "ok 8 167400" \
  "$(j '.stg.windows.since_split.change_lead_time | "\(.status) \(.n) \(.median)"')"
same "30 days: change fail rate 1 / 3, insufficient" "insufficient 1 3" \
  "$(j '.stg.windows.last_days.change_fail_rate | "\(.status) \(.numerator) \(.denominator)"')"
same "30 days: rework rate 1 / 3 (the rollback), insufficient" "insufficient 1 3" \
  "$(j '.stg.windows.last_days.deployment_rework_rate | "\(.status) \(.numerator) \(.denominator)"')"
same "30 days: one recovery sample of 36 h" "insufficient 129600" \
  "$(j '.stg.windows.last_days.failed_deployment_recovery_time | "\(.status) \(.values | join(","))"')"
same "promotes in 30 days and since the split (stg, prd, before the split)" "3 1 1 | 4 1 2" \
  "$(j '.stg.windows | "\(.last_days.promotes | "\(.stg) \(.prd) \(.before_split_code_repository)") | \(.since_split.promotes | "\(.stg) \(.prd) \(.before_split_code_repository)")"')"
same "prd: no data" no_data "$(j .prd.status)"
out=$work/main.out
expect "the summary is labelled stg lab" "$out" "## DORA metrics: stg lab (cụm dựng trong một lượt runner)"
expect "the summary: deployment frequency" "$out" "| Deployment frequency | 3 (0,7/tuần), 5 lượt kiểm | 5 (0,6/tuần), 7 lượt kiểm |"
expect "the summary: lead time below the threshold, then a median" "$out" \
  "| Change lead time | chưa đủ dữ liệu (n = 3, cần ≥ 5): 24,5 giờ, 2 ngày, 5 ngày | trung vị 46,5 giờ (n = 8) |"
expect "the summary: change fail rate below the threshold" "$out" \
  "| Change fail rate | chưa đủ dữ liệu (n = 3, cần ≥ 10): 1 / 3 | chưa đủ dữ liệu (n = 5, cần ≥ 10): 1 / 5 |"
expect "the summary: recovery below the threshold" "$out" \
  "| Failed deployment recovery time | chưa đủ dữ liệu (n = 1, cần ≥ 5): 36 giờ | chưa đủ dữ liệu (n = 1, cần ≥ 5): 36 giờ |"
expect "the summary: prd has no data" "$out" "| prd (mọi chỉ số) | chưa có dữ liệu prd | chưa có dữ liệu prd |"
expect "the summary: merged, not deployed" "$out" "- \`$prefix/video-service@$(digest D-video-service)\`"
expect "the summary: the deployment with three checks" "$out" "| #26, #27, #28 | 3 |"
expect "the summary: the record left out" "$out" "- #42: its run"
refuse "the summary names no level" "$out" "Elite:"
rc=$(run clones --clones)
same "--clones: no record holds a release of another source, so no clone is named" "0 " "$rc $(cat "$work/clones.out")"

# --days 60 reaches back past the split: D0 and D1 count too, G0 (which changes envs/stg/images/ and envs/prd/images/)
# still is no promote. The JSON goes into a directory that does not exist yet.
rc=$(run days60 --days 60 "$work/new/dir/dora60.json")
same "--days 60: exits 0 and writes into a directory that did not exist" "0 yes" \
  "$rc $([ -f "$work/new/dir/dora60.json" ] && echo yes || echo no)"
same "--days 60: five deployments" 5 "$(jq -r '.stg.windows.last_days.deployment_frequency.count' "$work/new/dir/dora60.json")"
same "--days 60: promotes (stg, prd, before the split) without the first commit of svp-gitops" "4 1 2" \
  "$(jq -r '.stg.windows.last_days.promotes | "\(.stg) \(.prd) \(.before_split_code_repository)"' "$work/new/dir/dora60.json")"
expect "the summary: the first commit of svp-gitops is no promote" "$work/days60.out" \
  "Commit khởi tạo của svp-gitops (bản nhập lúc tách repo) không phải promote, không đếm."

# --- No record of stg at all: every metric of stg insufficient data, never 0; every release merged is not deployed.
echo '[]' >"$work/gh/deployments.json"
rc=$(run empty "$work/empty.json")
same "no record: exits 0" 0 "$rc"
same "no record: deployment frequency insufficient, not 0" "insufficient 0" \
  "$(jq -r '.stg.windows.last_days.deployment_frequency | "\(.status) \(.n)"' "$work/empty.json")"
same "no record: every release ever merged is not deployed" 10 "$(jq -r '.stg.merged_not_deployed | length' "$work/empty.json")"
expect "no record: the summary says insufficient data" "$work/empty.out" \
  "| Deployment frequency | chưa đủ dữ liệu: chưa có bản ghi stg nào được tính | chưa đủ dữ liệu: chưa có bản ghi stg nào được tính |"
expect "no record: lead time insufficient with n = 0" "$work/empty.out" "| Change lead time | chưa đủ dữ liệu (n = 0, cần ≥ 5) |"
expect "no record: prd has no data" "$work/empty.out" "chưa có dữ liệu prd"

# --- 100 records (#1000..#1099, newest first), as many as one list returns: older ones may be out of reach, warned.
# Each a failed one, so each is left out at once.
jq -n --arg r "$r4" '[range(1099; 999; -1) | {id: ., sha: $r, ref: $r, created_at: "2026-10-18T01:00:00Z",
  creator: {login: "svp-gitops-promoter[bot]"}, payload: {}}]' >"$work/gh/deployments.json"
for ((id = 1000; id < 1100; id++)); do echo '[{"state": "failure"}]' >"$work/gh/statuses-$id.json"; done
rc=$(run cap "$work/cap.json")
same "100 records: exits 0" 0 "$rc"
expect "100 records: warned that older ones may be out of reach" "$work/cap.json" \
  "the host lists 100 records of stg, as many as one list returns: any record older than #1000 (2026-10-18T01:00:00Z) is out of reach"
expect "100 records: the warning is in the summary" "$work/cap.out" "- the host lists 100 records of stg, as many as one list returns"

# --- Refusals.
for bad in 0 abc 4000; do
  rc=$(run bad --days "$bad" "$work/bad.json")
  if [ "$rc" != 0 ] && [ ! -e "$work/bad.json" ]; then ok "--days $bad is refused"; else fail "--days $bad is refused (exit $rc)"; fi
done

# --- Release source web. A throwaway clone of svp-web: wa (10-22), wb (10-23), wc (10-24) on its main. svp-gitops:
# G7 (10-25) runs web of svp-web at wa, G8 (10-26) at wc. Records: G4 (backend's web), G7, G8.
web=$work/svp-web
wg() {
  GIT_DIR=$web/.git GIT_WORK_TREE=$web GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$real_git" -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$web"
wg init -q -b main
wg remote add origin https://github.com/anhnvcoder/svp-frontend
for c in wa:2026-10-22 wb:2026-10-23 wc:2026-10-24; do
  GIT_AUTHOR_DATE=${c#*:}T00:00:00Z GIT_COMMITTER_DATE=${c#*:}T00:00:00Z wg commit -q --allow-empty -m "${c%%:*}"
done
wa=$(wg rev-parse HEAD~2) wb=$(wg rev-parse HEAD~1) wc=$(wg rev-parse HEAD)
wg update-ref refs/remotes/origin/main HEAD
web_file() { # COMMIT
  printf '# The release of web.\nimage:\n  repository: ghcr.io/anhnvcoder/svp-web/web\n  tag: "%s"\n  digest: "%s"\n' \
    "${1:0:12}" "$(digest "W-$1")" >"$config/envs/stg/images/web.yaml"
}
web_file "$wa" && r7=$(gc_at 2026-10-25T00:00:00Z "chore(stg): web of svp-web")
web_file "$wc" && r8=$(gc_at 2026-10-26T00:00:00Z "chore(stg): web of svp-web")
gw update-ref refs/remotes/origin/main HEAD
# web_record ID R DEPLOYED_AT RUN COMMIT: a record of R whose web is svp-web's release at COMMIT.
web_record() {
  record "$1" "$2" "$3" "$3" "$4" "$bot" B A "$k8" |
    jq -c --arg t "${5:0:12}" --arg d "$(digest "W-$5")" \
      '.payload.images.web = {repository: "ghcr.io/anhnvcoder/svp-web/web", tag: $t, digest: $d}'
}
{
  web_record 52 "$r8" 2026-10-27T00:00:00Z 102 "$wc"
  web_record 51 "$r7" 2026-10-25T01:00:00Z 101 "$wa"
  record 50 "$r4" 2026-10-17T00:00:00Z 2026-10-17T01:00:00Z 100 "$bot" B A "$k8"
} | jq -s . >"$work/gh/deployments.json"
for id in 50 51 52; do echo '[{"state": "success"}]' >"$work/gh/statuses-$id.json"; done
rc=$(run web-clones --clones)
same "web: --clones names web" "0 web" "$rc $(cat "$work/web-clones.out")"
rc=$(run web-none "$work/web-none.json")
[ "$rc" != 0 ] && [ ! -e "$work/web-none.json" ] && ok "web: no clone of svp-web, the run stops" ||
  fail "web: no clone of svp-web, the run stops (exit $rc)"
expect "web: no clone of svp-frontend, says why" "$work/web-none.err" \
  "records of stg hold releases built from commits of https://github.com/anhnvcoder/svp-frontend"
extra=(SVP_WEB_DIR="$web")
rc=$(run web "$work/web.json")
same "web: with a clone of svp-web, exits 0" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/      /' "$work/web.err" >&2
same "web: the commits of svp-web after the first deployment of its web, from its clone, named by its current name" \
  "$(printf '%s\n' "service web anhnvcoder/svp-frontend ${wb:0:12} 2026-10-27T00:00:00Z 345600" \
    "service web anhnvcoder/svp-frontend ${wc:0:12} 2026-10-27T00:00:00Z 259200" | sort)" \
  "$(jq -r '.stg.changes[] | select(.service == "web") | "\(.kind) \(.service) \(.repository) \(.sha[0:12]) \(.deployed_at) \(.lead_time)"' \
    "$work/web.json" | sort)"
same "web: no sample at the first deployment of its web" 0 "$(jq -r '.stg.deployments[1].changes' "$work/web.json")"
# --- The rename. kR (10-28) moves the table to the new names beside the retired sources; G9 (10-28 06:00) runs the
# charts of kR with the six services built at kR by the new backend and web still the release of the retired oldweb;
# wd (10-28 18:00) is a commit of the web client; G10 (10-29) runs its release by the new web source. kD (10-29
# 12:00) drops the retired sources, so the working tree's table knows neither. Records: those above, their runs under
# the code repository's former name, and G9, G10 under its new name.
sources rename
g add -A && GIT_AUTHOR_DATE=2026-10-28T00:00:00Z GIT_COMMITTER_DATE=2026-10-28T00:00:00Z g commit -q -m "chore: the rename"
kR=$(g rev-parse HEAD)
for svc in "${services[@]}"; do
  [ "$svc" = web ] && continue
  printf '# The release of %s.\nimage:\n  repository: ghcr.io/anhnvcoder/svp-backend/%s\n  tag: "%s"\n  digest: "%s"\n' \
    "$svc" "$svc" "${kR:0:12}" "$(digest "N-$svc")" >"$config/envs/stg/images/$svc.yaml"
done
charts_file stg "$kR"
r9=$(gc_at 2026-10-28T06:00:00Z "chore(stg): the six services of the new backend")
GIT_AUTHOR_DATE=2026-10-28T18:00:00Z GIT_COMMITTER_DATE=2026-10-28T18:00:00Z wg commit -q --allow-empty -m wd
wd=$(wg rev-parse HEAD)
wg update-ref refs/remotes/origin/main HEAD
printf '# The release of web.\nimage:\n  repository: ghcr.io/anhnvcoder/svp-frontend/web\n  tag: "%s"\n  digest: "%s"\n' \
  "${wd:0:12}" "$(digest "W-$wd")" >"$config/envs/stg/images/web.yaml"
r10=$(gc_at 2026-10-29T00:00:00Z "chore(stg): web of the new web source")
gw update-ref refs/remotes/origin/main HEAD
sources after
g add -A && GIT_AUTHOR_DATE=2026-10-29T12:00:00Z GIT_COMMITTER_DATE=2026-10-29T12:00:00Z g commit -q -m "chore: drop the retired sources"
g update-ref refs/remotes/origin/main HEAD
# renamed_record ID R DEPLOYED_AT RUN WEB_REPOSITORY WEB_COMMIT: a record of R under the charts of kR, the six services
# of the new backend at kR, web WEB_REPOSITORY at WEB_COMMIT, its run under the new name of the code repository.
renamed_record() {
  local images='{}' svc
  for svc in "${services[@]}"; do
    if [ "$svc" = web ]; then
      images=$(jq -c --arg r "$5" --arg t "${6:0:12}" --arg d "$(digest "W-$6")" \
        '. + {web: {repository: $r, tag: $t, digest: $d}}' <<<"$images")
    else
      images=$(jq -c --arg s "$svc" --arg t "${kR:0:12}" --arg d "$(digest "N-$svc")" \
        '. + {($s): {repository: "ghcr.io/anhnvcoder/svp-backend/\($s)", tag: $t, digest: $d}}' <<<"$images")
    fi
  done
  record "$1" "$2" "$3" "$3" "$4" "$bot" B A "$kR" |
    jq -c --argjson i "$images" --arg run "https://github.com/anhnvcoder/svp-backend/actions/runs/$4" \
      '.payload.images = $i | .payload.run_url = $run'
}
{
  renamed_record 54 "$r10" 2026-10-29T06:00:00Z 106 ghcr.io/anhnvcoder/svp-frontend/web "$wd"
  renamed_record 53 "$r9" 2026-10-28T12:00:00Z 105 ghcr.io/anhnvcoder/svp-web/web "$wc"
  web_record 52 "$r8" 2026-10-27T00:00:00Z 102 "$wc"
  web_record 51 "$r7" 2026-10-25T01:00:00Z 101 "$wa"
  record 50 "$r4" 2026-10-17T00:00:00Z 2026-10-17T01:00:00Z 100 "$bot" B A "$k8"
} | jq -s . >"$work/gh/deployments.json"
for id in 53 54; do echo '[{"state": "success"}]' >"$work/gh/statuses-$id.json"; done
for run in 105 106; do echo '{"path": ".github/workflows/verify.yml", "head_branch": "main"}' >"$work/gh/run-$run.json"; done
rc=$(run renamed-clones --clones)
same "the rename: --clones names web once for the releases of oldweb and web" "0 web" \
  "$rc $(cat "$work/renamed-clones.out")"
rc=$(run renamed "$work/renamed.json")
same "the rename, the working tree's table without the retired sources: exits 0" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/      /' "$work/renamed.err" >&2
same "the rename: every record counts, those of runs under the former name of the code repository too" \
  "${r4:0:12} ${r7:0:12} ${r8:0:12} ${r9:0:12} ${r10:0:12} []" \
  "$(jq -r '[.stg.deployments[].ref[0:12]] | join(" ")' "$work/renamed.json") $(jq -c .stg.records_left_out "$work/renamed.json")"
same "the rename: record #50 of G4, backend's web of before the rename (judged by its charts' table), a deployment" \
  "[50]" "$(jq -c '.stg.deployments[0].records' "$work/renamed.json")"
# G4 held the gateway at k5 (k1..k5 deployed) under the old name; feed-service at k7 and video-service at k9 reach stg
# first with G9. Keyed by release source, G9 would be the first deployment of the new backend and take no sample.
same "the rename: the first deployment of the new backend continues the history of the old one" \
  "$(printf '%s\n' "service feed-service anhnvcoder/svp-backend ${k7:0:12} 2026-10-28T12:00:00Z 1598400" \
    "service video-service anhnvcoder/svp-backend ${k9:0:12} 2026-10-28T12:00:00Z 820800" | sort)" \
  "$(jq -r --arg d 2026-10-28T12:00:00Z '.stg.changes[] | select(.deployed_at == $d and .kind == "service")
    | "\(.kind) \(.service) \(.repository) \(.sha[0:12]) \(.deployed_at) \(.lead_time)"' "$work/renamed.json" | sort)"
same "the rename: web of oldweb and of web on one clone, only wd new at G10" \
  "service web anhnvcoder/svp-frontend ${wd:0:12} 2026-10-29T06:00:00Z 43200" \
  "$(jq -r --arg d 2026-10-29T06:00:00Z '.stg.changes[] | select(.deployed_at == $d and .service == "web")
    | "\(.kind) \(.service) \(.repository) \(.sha[0:12]) \(.deployed_at) \(.lead_time)"' "$work/renamed.json")"
same "the rename: no lead time sample of web at G9 (the release of oldweb G8 already held)" "" \
  "$(jq -r --arg d 2026-10-28T12:00:00Z '.stg.changes[] | select(.deployed_at == $d and .service == "web") | .sha' \
    "$work/renamed.json")"
extra=()

if [ "$failures" -gt 0 ]; then
  echo "FAIL  $failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
