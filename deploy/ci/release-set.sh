#!/usr/bin/env bash
# release-set.sh: the set of releases staging ran while the checks of a run of scenario gitops passed, and the
# records of it (deployment records of environment stg in svp-gitops). In the run the cluster is built at one commit of
# svp-gitops and stays there until the wait for a release after the checks, so the set should not change during them;
# it is still read twice, once before smoke and once after the last check, and recorded only when nothing moved in
# between and it is exactly what svp-gitops said.
#
#   release-set.sh snapshot [--settle] FILE
#     With --settle, first waits (settle below) for every Application to be Synced and Healthy on two reads in a row.
#     Reads the cluster k3d-svp into FILE (JSON): every Application of namespace argocd (sync and health, the phase of
#     its last operation, the revision each source synced, the last entry of status.history), and for each of the seven
#     services its workload (Rollout or Deployment named after it in namespace svp) and every pod of it, chosen by its
#     labels (app.kubernetes.io/name = the service, app.kubernetes.io/component = server), not by name: KEDA and the
#     drills make new pods of the same release, and a Deployment of a drill carries another name. Then prints what
#     would keep the set from being recorded (see verify); exit 1 when anything would, the file written all the same.
#
#   release-set.sh verify BEFORE AFTER OUT [RESULTS]
#     Writes OUT (release-set.json) only when, in both snapshots, every Application is Synced and Healthy, its last
#     sync Succeeded and none running; every source of svp-gitops (the root's, and the values source of each
#     Application) synced the same commit R; every source of a chart of the code repository names one and the same
#     commit C (targetRevision and synced revision alike, which may well differ from R); each service's workload is
#     Healthy and all its pods, Ready or not, run one image, pinned by digest, at least one pod Ready. And between the
#     two: R, C, every Application's last history entry (a sync to B and back to A adds entries though R ends as it
#     started) and each service's image are the same. And R's own configuration agrees: envs/stg/images/<service>.yaml
#     of svp-gitops at R names exactly the image of the pods, envs/stg/charts.yaml at R names revision C. R is read
#     with git from the clone of svp-gitops (gitops_dir; fetched anonymously when it lacks R), never from an API.
#     Otherwise prints every reason (the service, its image before and after, the revisions) and exits 1, OUT not
#     written. With RESULTS (results.tsv of deploy/ci/verify-run.sh), k8s-smoke must have passed after
#     release-set-before. OUT, the payload of a record:
#       environment  stg
#       ref          R
#       images       per service: repository, tag (of envs/stg/images/ at R) and digest
#       charts       envs/stg/charts.yaml at R: revision (C), podSecurityVersion, collectorConfigSha256
#       deployed_at  the latest deployedAt of a history entry of R (when the last Application finished syncing it); of
#                    the last entry of each Application when none synced R (a commit that changed no Application)
#       run_url      this run (ci_run_url of platform.sh)
#       steps        the steps of RESULTS that ran between the two snapshots, each with its status
#       window       the times of the two snapshots
#
#   release-set.sh records
#     Prints, as a JSON array, newest first, the records of stg in svp-gitops that count (ci_deployment_list of
#     platform.sh): state success, made by the bot of the app that writes there, run_url a run of verify.yml on main
#     of the code repository (as the host knows the run: ci_run_workflow), and a payload of the form above (seven
#     services, each a release of its repository on GHCR with a tag of 12 hex and a digest; charts with its three
#     keys) whose ref is the record's commit. Each {id, ref, created_at, payload}. Every record left out is named on
#     stderr with why, a run the host does not answer for too. Whether ref is on main of svp-gitops is the caller's to
#     check, in its own clone.
#
#   release-set.sh check FILE
#     Exit 0 when FILE is a payload of that form; 1 naming what is wrong otherwise.
#
# Needs bash, git, jq; snapshot needs kubectl and the cluster; records a token that reads svp-gitops (GH_TOKEN on
# GitHub) or a machine's gh login, and reads the runs of the code repository (public). Writes nothing but FILE and
# OUT.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

stg_images=envs/stg/images
stg_charts=envs/stg/charts.yaml
# The workflow whose scenario gitops checks a set: a record counts only when its run is one of it on main.
record_workflow=.github/workflows/verify.yml
services_json=$(printf '%s\n' "${svp_services[@]}" | jq -R . | jq -s -c .)
# payload_problem: a jq function of a payload (the object verify writes), "" when it has the form a record holds,
# otherwise why not. Needs $prefix (ghcr_prefix) and $svcs (the seven services) bound.
payload_jq='
  def hex($n): type == "string" and test("^[0-9a-f]{\($n)}$");
  def release($s): type == "object" and (keys == ["digest", "repository", "tag"]) and .repository == "\($prefix)/\($s)"
    and (.tag | hex(12)) and (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"));
  def payload_problem: . as $p |
    if type != "object" then "it is no JSON object"
    elif .environment != "stg" then "it is not of environment stg"
    elif (.ref | hex(40) | not) then "its ref is no full commit"
    elif (.images | type) != "object" or (.images | keys) != ($svcs | sort)
      or any($svcs[]; . as $s | $p.images[$s] | release($s) | not) then
      "it does not name one release on GHCR (repository, tag of 12 hex, digest) of each of the seven services"
    elif (.charts | type) != "object" or (.charts | keys) != ["collectorConfigSha256", "podSecurityVersion", "revision"]
      or (.charts.revision | hex(40) | not) or (.charts.collectorConfigSha256 | hex(64) | not)
      or (.charts.podSecurityVersion | type == "string" and test("^v1\\.[0-9]+$") | not) then
      "its charts are not revision (40 hex), podSecurityVersion and collectorConfigSha256"
    elif (.run_url | type) != "string" or (.deployed_at | type) != "string" then "it has no run_url or deployed_at"
    else "" end;'

# settle: waits until every Application of namespace argocd is Synced and Healthy with no sync running, on two reads in
# a row (one read can land on the moment a status flips), for at most SVP_RELEASE_SET_SETTLE_SECONDS (default 300),
# reading every SVP_RELEASE_SET_SETTLE_INTERVAL seconds (default 10; the two variables are for the tests). Right after
# a build Applications are briefly Degraded for reasons that pass on their own (the HorizontalPodAutoscaler of a
# service has no metrics until metrics-server has a sample of its new pods). On timeout prints each Application not
# settled with its last state and returns 1; the snapshot is taken all the same and judged as always.
settle() {
  local limit=${SVP_RELEASE_SET_SETTLE_SECONDS:-300} every=${SVP_RELEASE_SET_SETTLE_INTERVAL:-10} start now apps bad \
    good=0
  start=$(date +%s)
  while :; do
    apps=$(kc -n argocd get applications.argoproj.io -o json) || fail "read the Applications of namespace argocd"
    bad=$(jq -r '.items[] | select((.status.sync.status // "") != "Synced" or (.status.health.status // "") != "Healthy"
        or (.status.operationState.phase // "") == "Running")
      | "      \(.metadata.name): \(.status.sync.status // "no sync status"), \(.status.health.status // "no health")\(
          if (.status.operationState.phase // "") == "Running" then ", a sync is running" else "" end)"' <<<"$apps") ||
      fail "read the Applications of namespace argocd"
    now=$(date +%s)
    if [ -z "$bad" ]; then
      good=$((good + 1))
      if [ "$good" -ge 2 ]; then
        echo "ok    every Application Synced and Healthy on two reads in a row, after waiting $((now - start)) s"
        return 0
      fi
    else
      good=0
    fi
    if [ $((now - start + every)) -gt "$limit" ]; then
      echo "FAIL  not every Application settled within $limit s (waited $((now - start)) s); last state:" >&2
      echo "${bad:-      every Application Synced and Healthy on the last read only, not on two in a row}" >&2
      return 1
    fi
    sleep "$every"
  done
}

# snapshot FILE: see the top of this file.
snapshot() {
  local file=$1 apps deploys rollouts pods
  apps=$(kc -n argocd get applications.argoproj.io -o json) || fail "read the Applications of namespace argocd"
  deploys=$(kc -n svp get deployments.apps -o json) || fail "read the Deployments of namespace svp"
  rollouts=$(kc -n svp get rollouts.argoproj.io -o json) || fail "read the Rollouts of namespace svp"
  pods=$(kc -n svp get pods -o json) || fail "read the pods of namespace svp"
  mkdir -p "$(dirname "$file")" || fail "create the folder of $file"
  # The four lists go in on stdin, not as arguments: Linux refuses any one argument over 128 KiB, and the Applications
  # of stg (their resources and sync results) are well over that.
  printf '%s\n' "$apps" "$deploys" "$rollouts" "$pods" |
    jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson svcs "$services_json" '
    def git_revs: [.revision, (.revisions // [])[]] | map(select(type == "string" and test("^[0-9a-f]{40}$")));
    def want: .spec.replicas // 1;
    [inputs] as [$apps, $deploys, $rollouts, $pods]
    | ($apps.items | map(select(.metadata.name == "svp-root")) | first // {}) as $root
    | {
      taken_at: $now,
      gitops_url: ($root.spec.source.repoURL // ""),
      chart_repo_url: ($root.spec.source.helm.valuesObject.chartRepoURL // ""),
      applications: [$apps.items[] | {
        name: .metadata.name,
        sync: (.status.sync.status // ""),
        health: (.status.health.status // ""),
        operation: (.status.operationState.phase // ""),
        sources: ((if .spec.sources then .spec.sources else [.spec.source] end) as $src
          | (if .spec.sources then (.status.sync.revisions // []) else [.status.sync.revision] end) as $revs
          | [range(0; $src | length) as $i | {repo: ($src[$i].repoURL // ""), target: ($src[$i].targetRevision // ""),
              revision: ($revs[$i] // "")}]),
        history: [.status.history[]? | {id, revisions: git_revs, deployedAt: (.deployedAt // "")}]
      }],
      services: [$svcs[] as $s | {
        name: $s,
        workload: (first(
          ($rollouts.items[] | select(.metadata.name == $s)
            | {kind: "Rollout", healthy: (.status.phase == "Healthy"), state: "phase \(.status.phase // "none")"}),
          ($deploys.items[] | select(.metadata.name == $s)
            | {kind: "Deployment",
               healthy: ((.status.observedGeneration // 0) >= .metadata.generation
                 and (.status.replicas // 0) == want and (.status.updatedReplicas // 0) == want
                 and (.status.availableReplicas // 0) == want and (.status.unavailableReplicas // 0) == 0),
               state: "replicas \(.status.replicas // 0)/\(want), updated \(.status.updatedReplicas // 0), available \(.status.availableReplicas // 0)"}),
          {kind: "workload", healthy: false, state: "missing"})),
        pods: [$pods.items[] | select(.metadata.labels["app.kubernetes.io/name"] == $s
            and .metadata.labels["app.kubernetes.io/component"] == "server")
          | {name: .metadata.name,
             image: (([.spec.containers[] | select(.name == $s)] | first) // .spec.containers[0] | .image),
             ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | first == "True"),
             deleting: (.metadata.deletionTimestamp != null)}]
      }]
    }' >"$file" || fail "write $file"
  judge "$file" >/dev/null
}

# judge FILE [LABEL]: reads a snapshot and prints, as JSON, what it says: problems (every reason it cannot be
# recorded), ref (R), charts (C), images (service → repository@digest), history (Application → id of its last history
# entry) and deployed_at. Also prints each problem on stderr, after LABEL when given; status 1 when there is one.
judge() {
  local verdict
  verdict=$(jq --arg gitops "$gitops_url" '
    def image_of: split("@") | "\(.[0] | sub(":[^/:]*$"; ""))@\(.[1] // "")";
    . as $s
    | [.applications[] | {name, sync, health, operation,
        config: [.sources[] | select(.repo == $gitops) | .revision],
        charts: [.sources[] | select(.repo != "" and .repo == $s.chart_repo_url) | .target, .revision]}] as $apps
    | ([$apps[].config[]] | unique) as $r
    | ([$apps[].charts[]] | unique) as $c
    | (.services | map({key: .name, value: ([.pods[].image | image_of] | unique)}) | from_entries) as $imgs
    | {
      problems: [
        (if $s.gitops_url != $gitops then "Application svp-root reads \($s.gitops_url | if . == "" then "nothing" else . end), not \($gitops)" else empty end),
        ($apps[] | select(.sync != "Synced" or .health != "Healthy")
          | "Application \(.name): \(.sync | if . == "" then "no sync status" else . end), \(.health | if . == "" then "no health" else . end); Synced and Healthy wanted"),
        ($apps[] | select(.operation == "Running") | "Application \(.name): a sync is running"),
        ($apps[] | select(.operation != "Running" and .operation != "Succeeded")
          | "Application \(.name): its last sync is \(.operation | if . == "" then "none" else . end), not Succeeded"),
        (if ($r | length) != 1 or ($r[0] | test("^[0-9a-f]{40}$") | not) then
          "the sources of svp-gitops synced \($r | length) revisions (\($r | map(if . == "" then "none" else .[0:12] end) | join(", "))): one commit wanted" else empty end),
        (if ($c | length) != 1 or ($c[0] | test("^[0-9a-f]{40}$") | not) then
          "the sources of the charts of \($s.chart_repo_url) name \($c | length) revisions (\($c | map(if . == "" then "none" else .[0:12] end) | join(", "))): one commit wanted" else empty end),
        (.services[] | .name as $n | $imgs[$n] as $i
          | if (.workload.healthy | not) then "\($n): \(.workload.kind) \(.workload.state), not Healthy"
            elif (.pods | length) == 0 then "\($n): no pod"
            elif ($i | length) != 1 then "\($n): its pods run \($i | length) images (\($i | join(", "))): a rollout is not over"
            elif ($i[0] | test("@sha256:[0-9a-f]{64}$") | not) then "\($n): \($i[0]) is not pinned by digest"
            elif ([.pods[] | select(.ready)] | length) == 0 then "\($n): no pod Ready"
            else empty end)
      ],
      ref: (if ($r | length) == 1 then $r[0] else null end),
      charts: (if ($c | length) == 1 then $c[0] else null end),
      images: ($imgs | map_values(if length == 1 then .[0] else null end)),
      history: (.applications | map({key: .name, value: ([.history[]] | last | .id // null)}) | from_entries),
      deployed_at: (($r[0] // "") as $ref
        | ([.applications[].history[] | select(.revisions | index($ref)) | .deployedAt] | max)
          // ([.applications[] | [.history[]] | last | .deployedAt // empty] | max))
    }' "$1") || fail "read the snapshot $1"
  jq -r --arg l "${2:+$2: }" '.problems[] | "FAIL  " + $l + .' <<<"$verdict" >&2
  echo "$verdict"
  [ "$(jq '.problems | length' <<<"$verdict")" = 0 ]
}

# verify BEFORE AFTER OUT [RESULTS]: see the top of this file.
verify() {
  local before=$1 after=$2 out=$3 results=${4:-} jb ja problems=() svc r c b a config rc steps file content repo tag \
    digest images='{}' charts_json= psv sum line
  [ -f "$before" ] || fail "no snapshot $before: step release-set-before writes it before k8s-smoke"
  [ -f "$after" ] || fail "no snapshot $after"
  rm -f "$out"
  echo "snapshots: before smoke $(jq -r .taken_at "$before"), after the checks $(jq -r .taken_at "$after")"
  jb=$(judge "$before" "before smoke") || true
  ja=$(judge "$after" "after the checks") || true
  [ "$(jq '.problems | length' <<<"$jb")" = 0 ] || problems+=("the cluster before smoke (above)")
  [ "$(jq '.problems | length' <<<"$ja")" = 0 ] || problems+=("the cluster after the checks (above)")
  r=$(jq -r '.ref // ""' <<<"$ja")
  c=$(jq -r '.charts // ""' <<<"$ja")
  [ "$(jq -r '.ref // ""' <<<"$jb")" = "$r" ] ||
    problems+=("svp-gitops moved during the checks: revision $(jq -r '.ref // "none"' <<<"$jb") before smoke, ${r:-none} after")
  [ "$(jq -r '.charts // ""' <<<"$jb")" = "$c" ] ||
    problems+=("the charts moved during the checks: revision $(jq -r '.charts // "none"' <<<"$jb") before smoke, ${c:-none} after")
  while IFS= read -r line; do problems+=("$line"); done < <(jq -r -n --argjson b "$jb" --argjson a "$ja" '
    ($b.history | keys) as $kb | ($a.history | keys) as $ka
    | (if $kb != $ka then "the Applications changed during the checks: \($kb | join(" ")) before smoke, \($ka | join(" ")) after" else empty end),
      ($ka[] | select($b.history[.] != $a.history[.])
        | "Application \(.) synced during the checks: last history entry \($b.history[.] // "none") before smoke, \($a.history[.] // "none") after"),
      ($a.images | keys[] | select($b.images[.] != $a.images[.])
        | "\(.): its image changed during the checks: \($b.images[.] // "none") before smoke, \($a.images[.] // "none") after (svp-gitops \($b.ref // "none" | .[0:12]) before, \($a.ref // "none" | .[0:12]) after)")')
  if [ -n "$results" ]; then
    steps=$(awk -F '\t' 'seen && $3 != "skipped" { print $2 "\t" $3 } $2 == "release-set-before" { seen = 1 }' "$results") ||
      fail "read $results"
    awk -F '\t' '$1 == "k8s-smoke" && $2 == "ok" { found = 1 } END { exit !found }' <<<"$steps" ||
      problems+=("k8s-smoke did not pass after release-set-before ($results): nothing was checked")
  else
    steps=
  fi
  # R's own configuration, from the clone, against what the pods run.
  if [[ $r =~ ^[0-9a-f]{40}$ ]] && [[ $c =~ ^[0-9a-f]{40}$ ]]; then
    config=$(gitops_dir)
    if ! git -C "$config" cat-file -e "$r^{commit}" 2>/dev/null; then
      GIT_TERMINAL_PROMPT=0 git -C "$config" -c credential.helper= fetch -q origin "$r" 2>/dev/null ||
        GIT_TERMINAL_PROMPT=0 git -C "$config" -c credential.helper= fetch -q origin 2>/dev/null || :
    fi
    if ! git -C "$config" cat-file -e "$r^{commit}" 2>/dev/null; then
      problems+=("revision ${r:0:12} is not in the clone of svp-gitops ($config), even after a fetch")
    else
      for svc in "${svp_services[@]}"; do
        file=$stg_images/$svc.yaml
        rc=0
        content=$(git -C "$config" show "$r:$file" 2>/dev/null) && repo=$(values_field repository <<<"$content") &&
          tag=$(values_field tag <<<"$content") && digest=$(values_field digest <<<"$content") || rc=1
        if [ "$rc" != 0 ]; then
          problems+=("$svc: $file at ${r:0:12} of svp-gitops cannot be read")
          continue
        fi
        a=$(jq -r --arg s "$svc" '.images[$s] // "none"' <<<"$ja")
        if [ "$repo@$digest" != "$a" ]; then
          problems+=("$svc: its pods run $a, but $file at ${r:0:12} of svp-gitops names $repo@$digest")
          continue
        fi
        images=$(jq -c --arg s "$svc" --arg r "$repo" --arg t "$tag" --arg d "$digest" \
          '. + {($s): {repository: $r, tag: $t, digest: $d}}' <<<"$images")
      done
      content=$(git -C "$config" show "$r:$stg_charts" 2>/dev/null) || content=
      b=$(sed -n 's/^revision: *//p' <<<"$content")
      psv=$(sed -n 's/^podSecurityVersion: *//p' <<<"$content")
      sum=$(sed -n 's/^collectorConfigSha256: *//p' <<<"$content")
      if [ "$b" != "$c" ]; then
        problems+=("the charts run at ${c:0:12}, but $stg_charts at ${r:0:12} of svp-gitops names revision ${b:-none}")
      fi
      charts_json=$(jq -c -n --arg r "$b" --arg p "$psv" --arg s "$sum" \
        '{revision: $r, podSecurityVersion: $p, collectorConfigSha256: $s}')
    fi
  fi
  if [ ${#problems[@]} -gt 0 ]; then
    printf 'FAIL  %s\n' "${problems[@]}" >&2
    fail "the set of releases stg ran is not recorded: $out not written"
  fi
  jq -n --arg ref "$r" --argjson images "$images" --argjson charts "$charts_json" \
    --arg deployed "$(jq -r '.deployed_at // ""' <<<"$ja")" --arg run "$(ci_run_url)" --arg steps "$steps" \
    --arg from "$(jq -r .taken_at "$before")" --arg to "$(jq -r .taken_at "$after")" '{
      environment: "stg", ref: $ref, images: $images, charts: $charts, deployed_at: $deployed, run_url: $run,
      steps: ($steps | split("\n") | map(select(length > 0) | split("\t") | {name: .[0], status: .[1]})),
      window: {from: $from, to: $to}
    }' >"$out.tmp" && mv "$out.tmp" "$out" || fail "write $out"
  echo "ok    stg ran svp-gitops ${r:0:12} with the charts of ${c:0:12} from before smoke to after the last check:"
  jq -r '.images | to_entries[] | "      \(.key): \(.value.repository)@\(.value.digest)"' "$out"
  echo "ok    wrote $out (deployed at $(jq -r .deployed_at "$out"))"
}

# records: see the top of this file.
records() {
  local list kept='[]' id run reason wf
  list=$(ci_deployment_list "$gitops_repo" stg) || fail "list the deployment records of stg in $gitops_repo"
  list=$(jq -c --arg bot "$gitops_app[bot]" --arg prefix "$ghcr_prefix" --argjson svcs "$services_json" "$payload_jq"'
    .[] | . as $d | . + {reason: (
      if .state != "success" then "its state is \(.state | if . == "" then "none" else . end), not success"
      elif .creator != $bot then "made by \(.creator), not \($bot)"
      else (.payload as $p | $p | payload_problem | if . != "" then "its payload: " + .
        elif $p.ref != $d.sha then "its payload names \($p.ref), not its commit"
        else "" end) end)}' <<<"$list") || fail "read the deployment records of stg in $gitops_repo"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    id=$(jq -r .id <<<"$rec")
    reason=$(jq -r .reason <<<"$rec")
    run=$(jq -r '.payload.run_url? // ""' <<<"$rec")
    if [ -z "$reason" ] && ! ci_is_run_url "$run"; then reason="its run_url '$run' is no run of the code repository"; fi
    if [ -z "$reason" ]; then
      if ! wf=$(ci_run_workflow "$run"); then
        reason="its run $run cannot be read from the host"
      elif [ "$wf" != "$record_workflow main" ]; then
        reason="its run $run is of ${wf% *} on ${wf#* }, not of $record_workflow on main"
      fi
    fi
    if [ -n "$reason" ]; then
      echo "skip  record #$id: $reason" >&2
      continue
    fi
    kept=$(jq -c --argjson r "$rec" '. + [$r | {id, ref: .sha, created_at, payload}]' <<<"$kept")
  done <<<"$list"
  echo "$kept"
}

# check FILE: see the top of this file.
check() {
  local problem
  problem=$(jq -r --arg prefix "$ghcr_prefix" --argjson svcs "$services_json" "$payload_jq"'
    payload_problem' "$1" 2>/dev/null) || problem="it is no JSON"
  [ -z "$problem" ] || fail "$1 is no payload of a record of stg: $problem"
}

case ${1:-} in
snapshot)
  settle=0
  if [ "${2:-}" = --settle ]; then
    settle=1
    shift
  fi
  [ $# -eq 2 ] || fail "usage: release-set.sh snapshot [--settle] FILE"
  # A wait that ran out is no reason to skip the snapshot: it says the rest of what is wrong. The step is still red,
  # even when the snapshot's own read happens to find every Application healthy a moment later.
  unsettled=0
  [ "$settle" = 0 ] || settle || unsettled=1
  snapshot "$2" || fail "the set of releases stg runs now could not be recorded (above); $2 written all the same"
  [ "$unsettled" = 0 ] || fail "not every Application settled before the snapshot (above); $2 written all the same"
  echo "ok    $2: the set of releases stg runs now could be recorded"
  ;;
verify)
  [ $# -eq 4 ] || [ $# -eq 5 ] || fail "usage: release-set.sh verify BEFORE AFTER OUT [RESULTS]"
  verify "$2" "$3" "$4" "${5:-}"
  ;;
records)
  [ $# -eq 1 ] || fail "usage: release-set.sh records"
  records
  ;;
check)
  [ $# -eq 2 ] || fail "usage: release-set.sh check FILE"
  check "$2"
  ;;
*) fail "usage: release-set.sh snapshot [--settle] FILE | verify BEFORE AFTER OUT [RESULTS] | records | check FILE" ;;
esac
