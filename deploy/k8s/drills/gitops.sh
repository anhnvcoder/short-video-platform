#!/usr/bin/env bash
# Measures, after the fact, how long a commit took from the push to the pods that run it on the GitOps path:
# `make measure-gitops REV=<commit>` on a cluster made by
# `make k8s-gitops-up`. Read only: git, GitHub's events and the cluster are read, nothing is changed. A release commit
# is the merge of a promote pull request, which changes image.digest in deploy/k8s/values/services/.
#
#   push           the reflog entry "update by push" of refs/remotes/origin/main that moved it to REV (a push from
#                  this machine); else the PushEvent of GitHub's events API whose head is REV (ci_push_time of
#                  deploy/ci/platform.sh), which is how a pull request merged on GitHub arrives (this machine only
#                  fetches it later); else "not measurable", and the times count from the start of Argo CD's sync
#                  instead. Never the commit's own date: a commit can be made long before it is pushed.
#   sync           the entries for REV in status.history of the Applications that synced it: when the first started
#                  and when the last finished;
#   pods           the services whose image.digest REV changes (values files at REV against its first parent): when
#                  the first and the last pod running the new digest turned Ready, once every pod of those services
#                  runs it.
#                  Pods that restarted since, or that were made outside the rollout (the HPA scaling out, a pod that
#                  replaced an evicted one), no longer hold the time the rollout made them Ready: they are left out
#                  and named.
#   restarts       per service REV releases: the restarts of its pods running the new digest and, for a service with a
#                  database (migrate: true in its values at REV), its migrate Job (the PreSync hook that migrates the
#                  schema before the new pods start): whether it was made during the sync of REV measured above and is
#                  complete, its pods and their restarts; for both, how often they retried the database connection at
#                  startup (the log lines "database not reachable, retrying" and "database connected after retries",
#                  counted, never printed: none of either is a connection at the first try). Reported, not judged
#                  here: the verification run of the GitOps path fails a release whose pods or migrate Job restarted.
# Prints a table and writes it as JSON to .k8s/drills/gitops-<commit>.json. A commit not pushed yet, not synced yet,
# or whose pods are not all Ready yet is reported as such (exit 2), never as a number; so is a service whose
# Application runs a sync, or starts one while the pods and the Job are read: what was read may be that sync's. A
# commit that can no longer be measured is reported so (exit 1) instead of waiting for good: Argo CD went on to a later
# commit without syncing it (pushed together with that commit, or replaced before Argo CD's next poll), a service it
# releases has synced a later commit since, whose rollout may have replaced the pods to time, or every pod of such a
# service is left out.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/../lib.sh"
# ci_repo, ci_push_time: the repository on its host, and when a commit was pushed there.
# shellcheck source=deploy/ci/platform.sh
. "$repo_root/deploy/ci/platform.sh"

host_repo=$(ci_repo) || exit 1
values_dir=deploy/k8s/values/services

waiting() {
  echo "WAIT  $1" >&2
  exit 2
}
# epoch RFC3339: seconds since the epoch of a UTC timestamp such as 2026-10-18T14:10:29Z; iso EPOCH: the reverse.
# GNU date (Linux, the CI runner) parses with -d; BSD date (macOS) has no -d for this and needs -j -f / -r instead.
if date -u -d @0 +%s >/dev/null 2>&1; then
  epoch() { date -u -d "$1" +%s; }
  iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
else
  epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
  iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
fi

[ $# = 1 ] && [ -n "$1" ] || fail "usage: make measure-gitops REV=<commit>"
sha=$(git -C "$repo_root" rev-parse --verify --quiet "$1^{commit}") || fail "$1 is not a commit of this clone"
short=${sha:0:12}

# --- the services whose release digest REV changes, from git alone and before the cluster is read: a commit that
# changes no digest (code or docs only) changes no pod, so no rollout follows it, and only this check can say why.
# The first parent of a merge on GitHub is main before it.
parent=$(git -C "$repo_root" rev-parse --verify --quiet "$sha^1") || fail "$short has no parent to compare its release digests with"
changed=()
for svc in "${svp_services[@]}"; do
  new=$(git -C "$repo_root" show "$sha:$values_dir/$svc.yaml" 2>/dev/null | values_field digest 2>/dev/null) || continue
  old=$(git -C "$repo_root" show "$parent:$values_dir/$svc.yaml" 2>/dev/null | values_field digest 2>/dev/null) || old=
  if [ -n "$new" ] && [ "$new" != "$old" ]; then changed+=("$svc@$new"); fi
done
[ ${#changed[@]} -gt 0 ] || fail "$short changes no image.digest in $values_dir, so no pod runs a new release to time; measure the merge commit of a promote pull request"

kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-gitops-up"
kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1 ||
  fail "cluster svp has no Application argocd/svp-root: it was not made by make k8s-gitops-up"

# --- push time. The reflog lists the newest entry first; the oldest push that moved origin/main to REV is the push.
push_ts=
push_src=
while read -r h sel subject; do
  if [ "$h" = "$sha" ] && [ "$subject" = "update by push" ]; then
    push_ts=${sel##*@\{}
    push_ts=${push_ts%\}}
    push_src="reflog of refs/remotes/origin/main (update by push)"
  fi
done < <(git -C "$repo_root" reflog show --format='%H %gd %gs' --date=unix refs/remotes/origin/main 2>/dev/null)
gh_note=
if [ -z "$push_ts" ]; then
  if created=$(ci_push_time "$sha" 2>&1); then
    if [ -n "$created" ]; then
      push_ts=$(epoch "$created")
      push_src="GitHub PushEvent with head $short (events of $host_repo)"
    fi
  else
    gh_note=" (GitHub's events could not be read: ${created%%$'\n'*})"
  fi
fi

# --- Argo CD's syncs of REV: "app started finished" per history entry, oldest first.
apps_json=$(kc -n argocd get applications.argoproj.io -o json) || fail "read the Applications of namespace argocd"
# git_revs: the commit SHAs among a history entry's or sync result's revisions (a chart source's are versions).
git_revs='def git_revs: [.revision, (.revisions // [])[]] | map(select(type == "string" and test("^[0-9a-f]{40}$")));'
syncs=$(printf '%s' "$apps_json" | jq -r --arg sha "$sha" "$git_revs"'
  .items[] | .metadata.name as $app | (.status.history // [])[]
  | select(git_revs | index($sha))
  | "\($app) \(.deployStartedAt // .deployedAt) \(.deployedAt)"')
# A running sync is matched on the revision it asked for and on the one it resolved that to (syncResult): a sync asked
# for a branch (a manual sync of main) names REV only in its result.
running=$(printf '%s' "$apps_json" | jq -r --arg sha "$sha" "$git_revs"'
  .items[] | select(.status.operationState.phase == "Running")
  | select(.status.operationState | ((.operation.sync // {}) | git_revs) + ((.syncResult // {}) | git_revs)
      | index($sha))
  | .metadata.name' | tr '\n' ' ')
# later_than_rev COMMIT: true when COMMIT is a later commit than REV, one REV is an ancestor of.
later_than_rev() { [ "$1" != "$sha" ] && git -C "$repo_root" merge-base --is-ancestor "$sha" "$1" 2>/dev/null; }
if [ -z "$syncs" ]; then
  if [ -n "$running" ]; then waiting "Argo CD is syncing $short: ${running% }"; fi
  # Every Application follows main: once one has synced a later commit, none will sync REV any more.
  for rev in $(printf '%s' "$apps_json" | jq -r "$git_revs"'[.items[].status.history[]? | git_revs[]] | unique[]'); do
    if later_than_rev "$rev"; then
      fail "$short cannot be measured: no Application has a sync of it in its history (Argo CD keeps the last 10 of each), and Argo CD has since synced ${rev:0:12}, a later commit; $short was pushed together with it or replaced before Argo CD's next poll. Measure ${rev:0:12} if it releases a service"
    fi
  done
  if [ -z "$push_ts" ] && ! git -C "$repo_root" merge-base --is-ancestor "$sha" refs/remotes/origin/main 2>/dev/null; then
    waiting "$short is not pushed yet: not in origin/main as last fetched, and GitHub has no PushEvent with head $short$gh_note"
  fi
  waiting "Argo CD has not synced $short yet (it polls GitHub every 60 s; the repo-server's cache of the refs adds up to 60 s more)"
fi
[ -z "$running" ] || waiting "Argo CD is still syncing $short: ${running% }"
sync_apps=$(printf '%s\n' "$syncs" | awk '{print $1}' | sort -u | tr '\n' ' ')
sync_start=$(printf '%s\n' "$syncs" | awk '{print $2}' | sort | head -1)
sync_end=$(printf '%s\n' "$syncs" | awk '{print $3}' | sort | tail -1)

# --- pods of the services whose release digest REV changes.
# A pod's Ready condition holds the time it last turned Ready, and this script reads it after the fact, so two kinds of
# pod are left out of the times and named instead:
# - a pod whose containers restarted: it turned Ready again after its last start, not when the rollout made it;
# - a pod made outside the rollout (the HPA scaling out, a pod replacing an evicted one). The rollout's first pod is
#   made by the service's own sync of REV, so it was created from the start of that sync (status.history of the
#   Application) to rollout_slack seconds after its end: a pod made earlier or later, such as the replacement of an
#   evicted pod once every pod of the rollout is gone, is not the rollout's however old it is. A rolling update then
#   makes each next pod as soon as one before it turns Ready (chart svp-service sets no minReadySeconds), so, oldest
#   first, a pod is part of the rollout when it was created at most GAP seconds (the argument of time_rollout_pods)
#   after the first pod's creation or after the Ready time of a pod of the rollout made before it (for one that
#   restarted, its latest: the first is lost). GAP is rollout_slack, which covers the controllers' reaction and the
#   timestamps' whole seconds, plus, when the service is an Argo Rollouts Rollout, the longest its canary steps can hold
#   it (canary_steps_jq; the gateway: its second pod is made only after the pauses and the analysis step).
# A readiness probe that failed and passed again without a restart cannot be seen in the pod, nor can a pod the HPA
# has removed since.
rollout_slack=10
# canary_steps_jq: reads a Rollout (null when the service has none) with $t the AnalysisTemplates of svp, and prints
# the seconds its canary steps can hold it at most, summed over the steps. A pause holds it for its duration. An
# analysis step holds it until its AnalysisRun ends Successful; its metrics run side by side, so the longest counts,
# each at most (Argo Rollouts v1.10.1, analysis/analysis.go): initialDelay, then count measurements interval apart,
# each taking up to the Prometheus timeout (30 s when unset) and each preceded by up to consecutiveErrorLimit (4 when
# unset) errored ones, every error retried 10 s after it. A metric without a count measures until it fails and gives
# no bound of its own: each analysis step is capped at 600 s, so that such a template cannot widen GAP without limit.
canary_steps_jq='
  def secs: if type == "number" then . else capture("^(?<n>[0-9]+)(?<u>[smh]?)$") | (.n | tonumber) * ({"": 1, s: 1, m: 60, h: 3600}[.u]) end;
  def num: if type == "number" then . else tonumber end;
  def metric_secs:
    (if (.count // 0 | num) > 0 then .count | num elif (.interval // "") == "" then 1 else null end) as $n
    | if $n == null then 600 else
        (.provider.prometheus.timeout // 30) as $to | (.consecutiveErrorLimit // 4 | num) as $e
        | (.initialDelay // 0 | secs) + ($n - 1) * (.interval // 0 | secs) + $n * ($e * ($to + 10) + $to)
      end;
  def step_secs:
    if .pause then .pause.duration // 0 | secs
    elif .analysis then
      [.analysis.templates[].templateName as $name
        | ([$t.items[] | select(.metadata.name == $name)] | first // error("no AnalysisTemplate \($name) in svp"))
        | .spec.metrics[] | metric_secs] | max // 0 | [., 600] | min
    else 0 end;
  [.spec.strategy.canary.steps[]? | step_secs] | add // 0'
ready_times=()
left_out=()
service_json=()

# db_retries POD...: prints "WARNINGS CONNECTED", the number of lines "database not reachable, retrying" and "database
# connected after retries" in the logs of the pods of svp (every container), read through awk and never printed;
# "null null" when a log cannot be read.
db_retries() {
  local pod counts w=0 c=0
  for pod in "$@"; do
    counts=$(kc -n svp logs "pod/$pod" --all-containers=true 2>/dev/null |
      awk '/database not reachable, retrying/ { w++ } /database connected after retries/ { c++ } END { print w + 0, c + 0 }') || {
      echo "null null"
      return 0
    }
    w=$((w + ${counts% *}))
    c=$((c + ${counts#* }))
  done
  echo "$w $c"
}

# app_state APPS APP: "started phase last" of Application APP in APPS (the Applications as JSON): the start and phase of
# its last operation and the id of its last history entry, what changes as soon as it starts a sync and when that ends.
app_state() {
  jq -r --arg app "$2" '.items[] | select(.metadata.name == $app) | .status
    | "\(.operationState.startedAt // "-") \(.operationState.phase // "-") \([.history[]?] | last | .id // "-")"' <<<"$1"
}

# time_rollout_pods START END GAP: reads on stdin the pods of one service ("name image created restarts ready-since",
# oldest first), START and END being the epoch seconds of REV's sync of the service. Appends the Ready time of each pod
# of the rollout to ready_times and names the others in left_out; sets timed to how many it kept.
time_rollout_pods() {
  local start=$1 end=$2 gap=$3 name created restarts ready c r horizon=
  timed=0
  while read -r name _ created restarts ready; do
    c=$(epoch "$created")
    if [ -z "$horizon" ]; then
      if [ "$c" -lt "$start" ]; then
        left_out+=("$name: created $created, before $short was deployed")
        continue
      elif [ "$c" -gt $((end + rollout_slack)) ]; then
        left_out+=("$name: created $created, after the rollout")
        continue
      fi
      horizon=$((c + gap))
    elif [ "$c" -gt "$horizon" ]; then
      left_out+=("$name: created $created, after the rollout")
      continue
    fi
    r=$(($(epoch "$ready") + gap))
    [ "$r" -le "$horizon" ] || horizon=$r
    if [ "$restarts" -gt 0 ]; then
      left_out+=("$name: restartCount $restarts, Ready since its last start")
      continue
    fi
    ready_times+=("$ready")
    timed=$((timed + 1))
  done
}

for image in "${changed[@]}"; do
  svc=${image%%@*}
  digest=${image#*@}
  # The service's own Application (named after it) must have synced REV last: a later sync may have rolled its pods.
  latest=$(printf '%s' "$apps_json" | jq -r --arg app "$svc" "$git_revs"'
    .items[] | select(.metadata.name == $app) | [.status.history[]?] | last // {} | git_revs[0] // ""')
  if [ "$latest" != "$sha" ]; then
    if later_than_rev "$latest"; then
      fail "$short cannot be measured: Application $svc has synced ${latest:0:12}, a later commit, since; its pods may come from that sync. Measure the latest release commit"
    fi
    waiting "Application $svc has not synced $short yet${latest:+ (its last sync: ${latest:0:12})}"
  fi
  # "started finished" of the first sync of REV by the service's Application: the one that applied the new pod template.
  deploy_window=$(printf '%s' "$apps_json" | jq -r --arg app "$svc" --arg sha "$sha" "$git_revs"'
    .items[] | select(.metadata.name == $app) | [.status.history[]? | select(git_revs | index($sha))] | first // empty
    | "\(.deployStartedAt // .deployedAt) \(.deployedAt)"')
  [ -n "$deploy_window" ] || fail "Application $svc has no sync of $short in its history"
  read -r deploy_start deploy_end <<<"$deploy_window"
  # A sync running now, of whatever revision, may be rolling the pods and has replaced the migrate Job (below).
  read -r op_started op_phase _ <<<"$(app_state "$apps_json" "$svc")"
  [ "$op_phase" != Running ] ||
    waiting "Application $svc is running a sync (started $op_started): its pods and migrate Job may be that sync's"
  # Seconds the canary steps can hold the Rollout of the service (0 for a Deployment: no such object).
  rollout=$(kc -n svp get rollouts.argoproj.io "$svc" --ignore-not-found -o json) || fail "read Rollout $svc"
  templates='{"items": []}'
  if [ -n "$rollout" ] &&
    jq -e '[.spec.strategy.canary.steps[]? | select(.analysis)] | length > 0' <<<"$rollout" >/dev/null; then
    templates=$(kc -n svp get analysistemplates.argoproj.io -o json) || fail "read the AnalysisTemplates of svp"
  fi
  steps_total=$(jq -r --argjson t "$templates" "$canary_steps_jq" <<<"${rollout:-null}") ||
    fail "read the canary steps of Rollout $svc"
  # "name image created restarts ready-since" per pod still running (pods being deleted are on their way out of the
  # rollout), oldest first; restarts summed over its containers.
  pods=$(kc -n svp get pods -l "app.kubernetes.io/name=$svc,app.kubernetes.io/component=server" -o json | jq -r '
    [.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp)[]
    | "\(.metadata.name) \(.spec.containers[0].image) \(.metadata.creationTimestamp)"
      + " \([.status.containerStatuses[]?.restartCount] | add // 0)"
      + " \([.status.conditions[]? | select(.type == "Ready" and .status == "True") | .lastTransitionTime][0] // "-")"') ||
    fail "read the pods of $svc"
  total=$(printf '%s\n' "$pods" | grep -c . || true)
  # The chart renders a release as <repository>[:<tag>]@<digest>: a pod runs the new release when its image ends in
  # @<digest>, whatever its tag.
  fresh=$(printf '%s\n' "$pods" | awk -v d="@$digest" \
    'length($2) > length(d) && substr($2, length($2) - length(d) + 1) == d && $5 != "-"' | grep -c . || true)
  [ "$total" -gt 0 ] && [ "$fresh" = "$total" ] ||
    waiting "$svc: $fresh of $total pods run $digest and are Ready"
  first_left=${#left_out[@]}
  time_rollout_pods "$(epoch "$deploy_start")" "$(epoch "$deploy_end")" $((rollout_slack + steps_total)) < <(printf '%s\n' "$pods")
  [ "$timed" -gt 0 ] ||
    fail "$short cannot be measured: no pod of $svc kept the Ready time the rollout gave it ($(printf '%s; ' "${left_out[@]:$first_left}" | sed 's/; $//'))"
  # The restarts (see the header). Every pod of the service runs the new digest by now (checked above).
  pod_restarts=$(printf '%s\n' "$pods" | awk '{ s += $4 } END { print s + 0 }')
  # shellcheck disable=SC2046 # pod names, split on whitespace
  read -r pod_warnings pod_connected <<<"$(db_retries $(printf '%s\n' "$pods" | awk '{ print $1 }'))"
  # The migrate Job, which the chart makes for a service whose values set migrate: true: before-hook-creation replaces
  # it at each sync of the service's Application, so the one there now is the latest sync's. It is the Job of the sync
  # of REV measured only when made during that sync (from deployStartedAt to deployedAt): made before, that sync ran no
  # hook; made after, a later sync (of REV again or of another commit) replaced it, and the restarts of the Job of the
  # sync measured are gone with it. Its pods carry the label of the Job's uid.
  values=$(git -C "$repo_root" show "$sha:$values_dir/$svc.yaml")
  has_database=false
  if grep -Eq '^migrate:[[:space:]]*true[[:space:]]*(#.*)?$' <<<"$values"; then has_database=true; fi
  job=$(kc -n svp get job "$svc-migrate" --ignore-not-found -o json) || fail "read Job $svc-migrate"
  migrate=null
  if [ -n "$job" ]; then
    job_uid=$(jq -r '.metadata.uid' <<<"$job")
    job_created=$(jq -r '.metadata.creationTimestamp' <<<"$job")
    of_sync=false
    if [ "$(epoch "$job_created")" -ge "$(epoch "$deploy_start")" ] &&
      [ "$(epoch "$job_created")" -le "$(epoch "$deploy_end")" ]; then
      of_sync=true
    fi
    # "name restarts" per pod of the Job.
    job_pods=$(kc -n svp get pods -l "batch.kubernetes.io/controller-uid=$job_uid" -o json |
      jq -r '.items[] | "\(.metadata.name) \([.status.containerStatuses[]?.restartCount] | add // 0)"') ||
      fail "read the pods of Job $svc-migrate"
    # shellcheck disable=SC2046 # pod names, split on whitespace
    read -r job_warnings job_connected <<<"$(db_retries $(printf '%s\n' "$job_pods" | awk 'NF { print $1 }'))"
    migrate=$(jq -c --arg created "$job_created" --argjson of_sync "$of_sync" \
      --argjson pods "$(printf '%s\n' "$job_pods" | grep -c . || true)" \
      --argjson restarts "$(printf '%s\n' "$job_pods" | awk '{ s += $2 } END { print s + 0 }')" \
      --argjson warnings "$job_warnings" --argjson connected "$job_connected" '
      {job: .metadata.name, created: $created, of_rev_sync: $of_sync,
        complete: any(.status.conditions[]?; .type == "Complete" and .status == "True"),
        pods: $pods, restarts: $restarts, db_retry_warnings: $warnings, db_connected_after_retries: $connected}' <<<"$job")
  fi
  service_json+=("$(jq -n -c --arg service "$svc" --arg digest "$digest" --arg started "$deploy_start" \
    --arg finished "$deploy_end" --argjson has_database "$has_database" --argjson pods "$total" \
    --argjson restarts "$pod_restarts" --argjson warnings "$pod_warnings" --argjson connected "$pod_connected" \
    --argjson migrate "$migrate" '{service: $service, digest: $digest, sync_started: $started, sync_finished: $finished,
      has_database: $has_database, pods: $pods, pod_restarts: $restarts, db_retry_warnings: $warnings,
      db_connected_after_retries: $connected, migrate: $migrate}')")
done
# What was read must be of the syncs measured: a sync that a service's Application started meanwhile (its last
# operation or history changed) may have rolled pods or replaced the migrate Job between two reads.
apps_after=$(kc -n argocd get applications.argoproj.io -o json) || fail "read the Applications of namespace argocd again"
for image in "${changed[@]}"; do
  svc=${image%%@*}
  [ "$(app_state "$apps_after" "$svc")" = "$(app_state "$apps_json" "$svc")" ] ||
    waiting "Application $svc started a sync while $short was read: its pods and migrate Job may be that sync's"
done
first_ready=$(printf '%s\n' "${ready_times[@]}" | sort | head -1)
last_ready=$(printf '%s\n' "${ready_times[@]}" | sort | tail -1)

# --- table and JSON. Offsets count from the push, or from the start of the sync when the push time is unknown.
if [ -n "$push_ts" ]; then
  origin=$push_ts
  push_at=$(iso "$push_ts")
else
  origin=$(epoch "$sync_start")
  push_at=
  push_src="not measurable: no reflog entry and no GitHub PushEvent for $short$gh_note; offsets count from the sync's start"
fi
offset() { echo $(($(epoch "$1") - origin)); }
printf '%-18s %s\n' "commit" "$short" "released" "${changed[*]}" \
  "push" "${push_at:-not measurable} (${push_src})" \
  "sync started" "$sync_start (+$(offset "$sync_start") s; ${sync_apps% })" \
  "sync finished" "$sync_end (+$(offset "$sync_end") s)" \
  "first pod Ready" "$first_ready (+$(offset "$first_ready") s)" \
  "last pod Ready" "$last_ready (+$(offset "$last_ready") s)"
for note in ${left_out[@]+"${left_out[@]}"}; do printf '%-18s %s\n' "left out" "$note"; done
# connected: how a pod or the Job's pods reached the database, from the two counts of db_retries.
printf '%s\n' "${service_json[@]}" | jq -r '
  def connected: if .db_retry_warnings == null then "log not read"
    elif .db_retry_warnings == 0 and .db_connected_after_retries == 0 then "connected at the first try"
    else "\(.db_retry_warnings) retry warning(s), \(.db_connected_after_retries) connected after retries" end;
  "restarts           \(.service): \(.pods) pod(s), restartCount \(.pod_restarts); database: \(connected)",
  (. as $s | .migrate | if . == null then
      "migrate            \($s.service): \(if $s.has_database then "no Job \($s.service)-migrate, though its values set migrate: true" else "no migrate Job (a service without a database)" end)"
    else "migrate            \(.job) \(if .complete then "complete" else "not complete" end)\(if .of_rev_sync then "" else ", not of the sync measured (created \(.created), the sync ran \($s.sync_started) to \($s.sync_finished))" end), \(.pods) pod(s), restartCount \(.restarts); database: \(connected)" end)'

mkdir -p "$repo_root/.k8s/drills"
out="$repo_root/.k8s/drills/gitops-$short.json"
jq -n --arg commit "$sha" --arg released "${changed[*]}" --arg push "$push_at" --arg push_source "$push_src" \
  --arg sync_apps "${sync_apps% }" --arg sync_started "$sync_start" --arg sync_finished "$sync_end" \
  --arg first_ready "$first_ready" --arg last_ready "$last_ready" \
  --arg left_out "$(printf '%s\n' ${left_out[@]+"${left_out[@]}"})" \
  --argjson s_sync_started "$(offset "$sync_start")" --argjson s_sync_finished "$(offset "$sync_end")" \
  --argjson s_first_ready "$(offset "$first_ready")" --argjson s_last_ready "$(offset "$last_ready")" \
  --argjson services "$(printf '%s\n' "${service_json[@]}" | jq -s -c .)" \
  '{commit: $commit, released: ($released | split(" ")), push: (if $push == "" then null else $push end),
    push_source: $push_source, sync_apps: ($sync_apps | split(" ")), sync_started: $sync_started,
    sync_finished: $sync_finished, first_pod_ready: $first_ready, last_pod_ready: $last_ready,
    pods_left_out: ($left_out | split("\n") | map(select(. != ""))),
    seconds_from: (if $push == "" then "sync_started" else "push" end),
    seconds: {sync_started: $s_sync_started, sync_finished: $s_sync_finished, first_pod_ready: $s_first_ready,
      last_pod_ready: $s_last_ready}, restarts: $services}' >"$out"
ok "written to .k8s/drills/gitops-$short.json"
