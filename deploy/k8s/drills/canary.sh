#!/usr/bin/env bash
# Canary of the gateway on cluster svp.
#
#   canary.sh drill    (make drill-k8s-canary) on the dev path, the gateway's Helm release from the working tree, no
#     git; with drill traffic running (deploy/k8s/drills/traffic.sh; started here unless one runs, and then stopped):
#     1. good revision: the image of the stable one, its pod template changed by annotation svp-canary-drill (the dev
#        tag follows the image ID, so "a new image of the same code" would make no revision). The canary must go
#        through 25%, 50%, the gate and 100% and be promoted; both of its AnalysisRuns, the background one and the
#        gate's, Successful with every metric measured successfully and no measurement failed, inconclusive or in error.
#     2. bad revision: FEED_SERVICE_ADDR to a Service that does not exist. The canary pod is ready (/healthz) but the
#        feeds answer 503; the AnalysisRun must fail and abort the Rollout by itself, the canary's weight back to 0,
#        the stable pods untouched (same UIDs, no restart).
#     3. the good values back: the template is the stable one again, and the Rollout must be Healthy again.
#     Then the measurement below of the abort of step 2, the canary pods at each step, and the checks; table on the
#     terminal, JSON in .k8s/drills/canary-drill-<time>.json.
#
#   canary.sh measure  (make measure-canary) reads back, after the fact and changing nothing, the latest canary of the
#     gateway that its analysis aborted (newest Failed AnalysisRun), from what stays after it: the AnalysisRun, the
#     HTTPRoute's managed fields (the plugin's last write of the weights), the drill traffic's log, Prometheus. The
#     drill prints the same measurement, so both give the same numbers. JSON in .k8s/drills/canary-measure-<time>.json.
#
# The timeline of an abort:
#   canary started        startedAt of the AnalysisRun, which starts with the canary (analysis from step 0)
#   canary got traffic    the first feed request of the drill traffic that got a 5xx after that: only the bad canary
#                         answers 5xx (Envoy's own counters, scraped every 15 s, are printed beside it)
#   AnalysisRun Failed    its completedAt
#   abort done            the plugin's last write of HTTPRoute api, the one that set the canary's weight to 0
#                         (managedFields, manager gatewayAPI; Kubernetes keeps it to the second)
# Client numbers count the feed requests of the drill traffic from canary start to 5 s after the abort; more than 1%
# of them 401 or 429 makes the result "inconclusive" (exit 1): broken traffic proves nothing. The stable backend's 5xx
# in the same window come from Envoy's counters (must be 0).
#
# Usage: through make (SVP_STACK=k3d, CURL_CA_BUNDLE). The drill takes about 7 minutes. LOCAL LAB ONLY: the drill
# deletes the register rate limit keys in the cluster's Valkey db 10 (deploy/compose/lib.sh).
set -euo pipefail

mode=${1:-}
case $mode in
  drill) ;;
  measure) drill_read_only=1 ;;
  *)
    echo "usage: canary.sh drill|measure" >&2
    exit 2
    ;;
esac
base=${SVP_CANARY_BASE:-https://api.svp.localhost:8443}
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

ns=svp
rollout=gateway
chart="$repo_root/deploy/helm/svp-service"
stable_cluster="httproute/$ns/api/rule/0/backend/0"
canary_cluster="httproute/$ns/api/rule/0/backend/1"
drills="$repo_root/.k8s/drills"
traffic="$repo_root/deploy/k8s/drills/traffic.sh"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$drills"

own_traffic=
bad_values=
canary_exit() {
  local rc=$?
  trap - EXIT
  # A drill stopped between steps 2 and 3 would leave the release with the broken FEED_SERVICE_ADDR: put it back.
  if [ -n "$bad_values" ]; then
    echo "note  putting FEED_SERVICE_ADDR of release $rollout back to feed-service:9104" >&2
    hc upgrade "$rollout" "$chart" --namespace "$ns" --reuse-values --server-side=false \
      --set-string env.FEED_SERVICE_ADDR=feed-service:9104 >/dev/null || rc=1
  fi
  prometheus_stop
  if [ -n "$own_traffic" ] && running=$("$traffic" status) && [ "${running%% *}" = "$own_traffic" ]; then
    "$traffic" stop >/dev/null || rc=1
  fi
  rm -rf "$work"
  exit "$rc"
}
trap canary_exit EXIT

# now_ms: unix time in ms.
now_ms() {
  local t
  t=$(now)
  echo "${t%.*}${t#*.}"
}
# hms MS: unix ms as HH:MM:SS.mmm (UTC). GNU date (Linux, the CI runner) reads an epoch with -d @SECONDS; BSD date
# (macOS) has no -d for it and needs -r instead.
if date -u -d @0 +%s >/dev/null 2>&1; then
  hms() { printf '%s.%03d' "$(date -u -d "@$(($1 / 1000))" +%H:%M:%S)" $(($1 % 1000)); }
else
  hms() { printf '%s.%03d' "$(date -u -r $(($1 / 1000)) +%H:%M:%S)" $(($1 % 1000)); }
fi
# secs MS: a duration in ms as seconds with one decimal.
secs() { printf '%d.%d' $(($1 / 1000)) $((($1 % 1000) / 100)); }
# iso_ms ISO: a Kubernetes time (RFC 3339, seconds) as unix ms.
iso_ms() { jq -rn --arg t "$1" '($t | fromdateiso8601) * 1000'; }

# rollout_json: the Rollout as JSON (into $work/rollout.json).
rollout_json() { kc -n "$ns" get rollout "$rollout" -o json >"$work/rollout.json" || fail "read rollout $ns/$rollout"; }
rget() { jq -r "$1" "$work/rollout.json"; }

# route_weights: "<stable weight> <canary weight>" of HTTPRoute api.
route_weights() {
  kc -n "$ns" get httproute api -o json | jq -r '[.spec.rules[0].backendRefs[] | (.weight // 1 | tostring)] | join(" ")'
}

# envoy_increase CLUSTER CLASS FROM_S TO_S: responses of CLUSTER (of class CLASS, or all when CLASS is "") Envoy
# counted between two times, rounded; 0 when the series does not exist.
envoy_increase() {
  local sel="envoy_cluster_name=\"$1\"" range=$(($4 - $3))
  [ -z "$2" ] || sel="$sel,envoy_response_code_class=\"$2\""
  promql "round(sum(increase(envoy_cluster_upstream_rq_xx{$sel}[${range}s]))) or on() vector(0)" "$4" |
    jq -r '.[0].value[1] // "0"'
}

# traffic_log FROM_MS TO_MS: the drill traffic log that holds every request between the two times ("" when none).
traffic_log() {
  local f first last
  for f in $(ls -r "$drills"/traffic-*.log 2>/dev/null); do
    first=$(awk '!/^#/ { print $1; exit }' "$f")
    last=$(awk '!/^#/ { t = $1 } END { print t }' "$f")
    [ -n "$first" ] && [ -n "$last" ] || continue
    if ((first <= $1 && last >= $2)); then
      echo "$f"
      return 0
    fi
  done
}

# client_stats LOG FROM_MS TO_MS: "<feed requests> <5xx> <401 or 429> <no answer> <first 5xx ms> <last 5xx ms>" of
# the feed requests of LOG that started between the two times (0 when no 5xx). Only explore and following count: the
# log also holds the logins and the web client's requests (web-login, web-asset), which go to route web, not route api.
client_stats() {
  awk -v a="$2" -v b="$3" '!/^#/ && ($3 == "explore" || $3 == "following") && $1 >= a && $1 <= b {
      n++
      if ($4 ~ /^5/) { e++; if (!f) f = $1; l = $1 }
      if ($4 == "401" || $4 == "429") x++
      if ($4 == "000") z++
    }
    END { printf "%d %d %d %d %d %d\n", n, e, x, z, f, l }' "$1"
}

# measure_abort: the measurement of the latest abort described at the top; prints the table and writes the JSON
# object to $work/measure.json. Sets measure_ok=0 when a number cannot be measured and inconclusive=1 when the traffic
# was broken.
measure_abort() {
  local runs run run_name hash started_ms failed_ms run_msg newer plugin_ms log win_end stats n e x z f l
  local stable5 canary5 canary_all t_s first_ms metrics
  measure_ok=1 inconclusive=0
  runs=$(kc -n "$ns" get analysisruns -o json) || fail "list the AnalysisRuns of $ns"
  run=$(jq -c --arg r "$rollout" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $r))
    | select(.status.phase == "Failed")] | sort_by(.metadata.creationTimestamp) | last' <<<"$runs")
  [ "$run" != null ] || fail "no failed AnalysisRun of rollout $ns/$rollout: no canary of it was aborted by its analysis"
  run_name=$(jq -r '.metadata.name' <<<"$run")
  hash=$(jq -r '.metadata.labels["rollouts-pod-template-hash"]' <<<"$run")
  started_ms=$(iso_ms "$(jq -r '.status.startedAt // .metadata.creationTimestamp' <<<"$run")")
  failed_ms=$(iso_ms "$(jq -r '.status.completedAt' <<<"$run")")
  run_msg=$(jq -r '.status.message // ""' <<<"$run")
  metrics=$(jq -c '[.status.metricResults[] | {name, phase, successful: (.successful // 0), failed: (.failed // 0),
    inconclusive: (.inconclusive // 0), values: [.measurements[] | {at: .finishedAt, phase, value}]}]' <<<"$run")
  # A canary started after this one has rewritten the route since: its plugin write is not this abort's.
  newer=$(jq --arg r "$rollout" --arg c "$(jq -r '.metadata.creationTimestamp' <<<"$run")" '[.items[]
    | select(any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $r))
    | select(.metadata.creationTimestamp > $c)] | length' <<<"$runs")
  plugin_ms=$(kc -n "$ns" get httproute api -o json --show-managed-fields |
    jq -r '[.metadata.managedFields[] | select(.manager == "gatewayAPI" and .subresource == null) | .time] | max // ""')
  if [ -n "$plugin_ms" ]; then plugin_ms=$(iso_ms "$plugin_ms"); fi
  if [ "$newer" != 0 ] || [ -z "$plugin_ms" ] || ((plugin_ms < failed_ms)); then
    echo "note  abort done not measurable: the route was written by a later canary ($newer AnalysisRuns since)," \
      "or never by the plugin after the failure"
    plugin_ms=0 measure_ok=0
  fi

  win_end=$((plugin_ms > 0 ? plugin_ms + 5000 : failed_ms + 5000))
  # Read once the window is over for the traffic log too, and once Prometheus has scraped its end (every 15 s).
  t_s=$((win_end / 1000 + 30))
  while (($(date +%s) < t_s)); do sleep 2; done
  log=$(traffic_log "$started_ms" "$win_end")
  if [ -n "$log" ]; then
    read -r n e x z f l <<<"$(client_stats "$log" "$started_ms" "$win_end")"
  else
    echo "note  no drill traffic log covers $(hms "$started_ms") to $(hms "$win_end"): client numbers not measured"
    n=0 e=0 x=0 z=0 f=0 l=0 measure_ok=0
  fi
  if ((n > 0 && x * 100 > n)); then inconclusive=1; fi

  # Envoy's counters over the same window.
  stable5=$(envoy_increase "$stable_cluster" 5 $((started_ms / 1000)) "$t_s")
  canary5=$(envoy_increase "$canary_cluster" 5 $((started_ms / 1000)) "$t_s")
  canary_all=$(envoy_increase "$canary_cluster" "" $((started_ms / 1000)) "$t_s")
  first_ms=$f
  if ((first_ms == 0)); then
    echo "note  no client 5xx after the canary started: the time it got traffic is not measured"
    measure_ok=0
  fi

  echo
  echo "Abort of the canary of rollout $ns/$rollout: AnalysisRun $run_name (template $hash): $run_msg"
  printf '  %-36s %-14s %s\n' "event" "time (UTC)" "after"
  printf '  %-36s %-14s %s\n' "canary started (AnalysisRun)" "$(hms "$started_ms")" ""
  if ((first_ms > 0)); then
    printf '  %-36s %-14s %s\n' "canary got traffic (1st client 5xx)" "$(hms "$first_ms")" "+$(secs $((first_ms - started_ms))) s after start"
    printf '  %-36s %-14s %s\n' "AnalysisRun Failed" "$(hms "$failed_ms")" "+$(secs $((failed_ms - first_ms))) s after traffic"
  else
    printf '  %-36s %-14s %s\n' "AnalysisRun Failed" "$(hms "$failed_ms")" "+$(secs $((failed_ms - started_ms))) s after start"
  fi
  if ((plugin_ms > 0)); then
    printf '  %-36s %-14s %s\n' "abort done (route back to 100/0)" "$(hms "$plugin_ms")" "+$(secs $((plugin_ms - failed_ms))) s after Failed"
  fi
  if ((l > 0)); then printf '  %-36s %-14s %s\n' "last client 5xx" "$(hms "$l")" ""; fi
  if ((first_ms > 0 && plugin_ms > 0)); then
    echo "  canary got traffic -> abort done: $(secs $((plugin_ms - first_ms))) s"
  fi
  echo "  client (drill traffic, ${log:+$(basename "$log")}): $n feed requests, $e 5xx, $x 401/429, $z without answer"
  echo "  Envoy: canary $canary5 5xx of $canary_all responses; stable backend $stable5 5xx"
  echo "  measurements: $(jq -r '[.[] | "\(.name) \([.values[] | .value] | join(" "))"] | join("; ")' <<<"$metrics")"

  jq -n --arg run "$run_name" --arg hash "$hash" --arg msg "$run_msg" --argjson started "$started_ms" \
    --argjson traffic "$first_ms" --argjson failed "$failed_ms" --argjson abort "$plugin_ms" --argjson last5 "$l" \
    --arg log "$log" --argjson n "$n" --argjson e "$e" --argjson x "$x" --argjson z "$z" \
    --argjson stable5 "$stable5" --argjson canary5 "$canary5" --argjson canaryall "$canary_all" \
    --argjson metrics "$metrics" --argjson ok "$measure_ok" --argjson inconclusive "$inconclusive" '{
      analysis_run: $run, template_hash: $hash, message: $msg,
      times_ms: {canary_started: $started, canary_got_traffic: (if $traffic > 0 then $traffic else null end),
        analysis_failed: $failed, abort_done: (if $abort > 0 then $abort else null end),
        last_client_5xx: (if $last5 > 0 then $last5 else null end)},
      seconds: {traffic_to_failed: (if $traffic > 0 then ($failed - $traffic) / 1000 else null end),
        failed_to_abort_done: (if $abort > 0 then ($abort - $failed) / 1000 else null end),
        traffic_to_abort_done: (if $traffic > 0 and $abort > 0 then ($abort - $traffic) / 1000 else null end)},
      client: {log: $log, feed_requests: $n, status_5xx: $e, status_401_429: $x, no_answer: $z},
      envoy: {canary_5xx: $canary5, canary_responses: $canaryall, stable_5xx: $stable5},
      metrics: $metrics, complete: ($ok == 1), inconclusive: ($inconclusive == 1)}' >"$work/measure.json"
}

if [ "$mode" = measure ]; then
  prometheus_forward
  measure_abort
  out="$drills/canary-measure-$stamp.json"
  cp "$work/measure.json" "$out"
  echo "JSON: $out"
  if ((inconclusive)); then fail "inconclusive: more than 1% of the drill traffic's feed requests got 401 or 429 in the window"; fi
  if ((!measure_ok)); then fail "measurement incomplete (notes above)"; fi
  echo "measure-canary: done"
  exit 0
fi

# ---- drill

# stable_pods: "name uid restarts" of every pod of the stable ReplicaSet, sorted.
stable_pods() {
  local h
  rollout_json
  h=$(rget '.status.stableRS')
  kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout,rollouts-pod-template-hash=$h" -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null)
      | "\(.metadata.name) \(.metadata.uid) \([.status.containerStatuses[]?.restartCount] | add // 0)"' | sort
}

# upgrade LABEL --set-string KEY=VALUE: helm upgrade of release gateway with its last values (--reuse-values keeps
# the image tag make k8s-up set) and one change, client-side like deploy/k8s/install.sh does for this release (the
# selectors and weights Argo Rollouts writes would make a server-side apply conflict). No --wait: Helm does not know
# Rollouts; follow_rollout waits.
upgrade() {
  local label=$1
  shift
  hc upgrade "$rollout" "$chart" --namespace "$ns" --reuse-values --server-side=false "$@" >/dev/null ||
    fail "helm upgrade $rollout ($label)"
}

# follow_rollout LABEL OLD_STABLE: after an upgrade, polls the Rollout every 2 s until the controller has seen the
# new generation and the canary ends; prints each change of step and weight with the ready pods of the new revision,
# keeps them in $work/steps-LABEL. Sets outcome to promoted, aborted, inconclusive or same (the template is the stable one, no
# canary), and target to the template hash of the revision.
follow_rollout() {
  local label=$1 old=$2 deadline=$((SECONDS + 600)) gen obs phase abort reasons step weight hash stable run pods line last=
  : >"$work/steps-$label"
  outcome= target=
  while :; do
    rollout_json
    IFS=$'\t' read -r gen obs phase abort reasons step weight hash stable run <<<"$(jq -r '[.metadata.generation,
      (.status.observedGeneration // "-"), (.status.phase // "-"), (.status.abort // false),
      ([.status.pauseConditions[]?.reason] | join(",") | if . == "" then "-" else . end),
      (.status.currentStepIndex // "-"), (.status.canary.weights.canary.weight // 0), (.status.currentPodHash // "-"),
      (.status.stableRS // "-"), (.status.canary.currentBackgroundAnalysisRunStatus.status // "-")] | @tsv' \
      "$work/rollout.json")"
    if [ "$obs" = "$gen" ]; then
      target=$hash
      # Ready pods of the new revision: the canary's while it runs, the promoted revision's once it is stable.
      pods=$(kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout,rollouts-pod-template-hash=$hash" -o json |
        jq '[.items[] | select(.metadata.deletionTimestamp == null)
          | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
      line="step=$step weight=$weight new_revision_ready_pods=$pods phase=$phase analysis=$run"
      if [ "$line" != "$last" ]; then
        printf '%s %s\n' "$(now)" "$line" >>"$work/steps-$label"
        echo "      $(date -u +%H:%M:%S) $label: $line"
        last=$line
      fi
      if [ "$abort" = true ]; then outcome=aborted; fi
      case ,$reasons, in *,InconclusiveAnalysisRun,*) outcome=inconclusive ;; esac
      if [ "$phase" = Healthy ]; then
        if [ "$stable" = "$old" ]; then outcome=same; else outcome=promoted; fi
      fi
      [ -z "$outcome" ] || return 0
    fi
    ((SECONDS < deadline)) || fail "$label: the canary of rollout $ns/$rollout did not end within 600s (phase $phase)"
    sleep 2
  done
}

# steps_json LABEL: the steps follow_rollout recorded for LABEL, as a JSON array.
steps_json() {
  jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {at_ms: (.[0] | sub("\\."; "") | tonumber)}
    + (.[1:] | map(split("=") | {(.[0]): .[1]}) | add))' "$work/steps-$1"
}

# check_good_runs HASH: checks both AnalysisRuns of the promoted revision HASH, told apart by the label rollout-type
# that Argo Rollouts v1.10.1 gives each run it creates (utils/analysis/factory.go): Background for the background
# analysis (template gateway-canary), Step for an analysis step, here only the gate (gateway-canary-gate). The newest
# run of each type counts: a run paused inconclusive and then resumed leaves an older one beside it. Each must be
# Successful, with every metric of its spec measured successfully at least once and no measurement failed,
# inconclusive or in error. The phase alone proves nothing for the background run: on promotion the controller
# terminates it (rollout/analysis.go, reconcileAnalysisRuns), and a terminated run whose metrics have not failed ends
# Successful even without a single measurement (analysis/analysis.go, assessRunStatus and assessMetricStatus).
# Each run is first given up to 60 s to end (phase Successful, Failed, Error or Inconclusive): the Rollout is Healthy
# as soon as its stable ReplicaSet is the new one (utils/rollout/rolloututil.go), while the background run is only
# told to stop (spec.terminate) once a reconcile of the Rollout sees it fully promoted, and its phase is set after that
# by the analysis controller in a reconcile of its own; until then the run is still Running. Sets good_runs to
# "<background run> <gate run>".
check_good_runs() {
  local deadline=$((SECONDS + 60)) runs type label run name phase metrics measured bad
  good_runs=
  for type in Background Step; do
    if [ "$type" = Background ]; then label=background; else label=gate; fi
    while :; do
      runs=$(kc -n "$ns" get analysisruns -l "rollouts-pod-template-hash=$1" -o json) ||
        fail "list the AnalysisRuns of revision $1"
      run=$(jq -c --arg t "$type" '[.items[] | select(.metadata.labels["rollout-type"] == $t)]
        | sort_by(.metadata.creationTimestamp) | last' <<<"$runs")
      [ "$run" != null ] || fail "good revision: no $label AnalysisRun (rollout-type=$type) of revision $1"
      IFS=$'\t' read -r name phase metrics measured bad <<<"$(jq -r '[.metadata.name, (.status.phase // "-"),
        (.spec.metrics | length), ([.status.metricResults[]? | select((.successful // 0) >= 1)] | length),
        ([.status.metricResults[]? | (.failed // 0) + (.inconclusive // 0) + (.error // 0)] | add // 0)] | @tsv' <<<"$run")"
      case $phase in Successful | Failed | Error | Inconclusive) break ;; esac
      ((SECONDS < deadline)) || fail "good revision: $label AnalysisRun $name still $phase 60s after the promotion"
      sleep 2
    done
    [ "$phase" = Successful ] && [ "$measured" = "$metrics" ] && [ "$bad" = 0 ] ||
      fail "good revision: $label AnalysisRun $name $phase, $measured of $metrics metrics measured successfully, failed/inconclusive/error $bad"
    good_runs="${good_runs:+$good_runs }$name"
  done
}

rollout_json
[ "$(rget '.status.phase')" = Healthy ] ||
  fail "rollout $ns/$rollout is $(rget '.status.phase'), not Healthy; run make k8s-up first"
hc status "$rollout" --namespace "$ns" >/dev/null 2>&1 || fail "no Helm release $rollout in $ns (the dev path, make k8s-up)"
prometheus_forward

baseline=$(promql "histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=\"$stable_cluster\"}[5m])))" |
  jq -r '.[0].value[1] // "NaN"')
ok "stable backend p99 over the last 5 minutes: $baseline ms (the analysis fails a canary at 150 ms)"

if running=$("$traffic" status); then
  ok "drill traffic already running (pid ${running%% *}); left running"
else
  "$traffic" start
  running=$("$traffic" status) || fail "drill traffic not running after its start"
  own_traffic=${running%% *}
fi
traffic_pid=${running%% *}

# 1. Good revision.
stable0=$(rget '.status.stableRS')
echo "1. good revision: pod template changed by annotation svp-canary-drill=good-$stamp (image as stable $stable0)"
t_good=$(now_ms)
upgrade good --set-string "podAnnotations.svp-canary-drill=good-$stamp"
follow_rollout good "$stable0"
[ "$outcome" = promoted ] || fail "good revision: expected promoted, got $outcome"
good_hash=$target
check_good_runs "$good_hash"
msg="good revision $good_hash promoted $(secs $(($(now_ms) - t_good))) s after the upgrade"
ok "$msg; background AnalysisRun ${good_runs% *} and gate AnalysisRun ${good_runs#* } Successful, every metric measured, none failed"
good_steps=$(steps_json good)
# The old ReplicaSet is scaled down 30 s after the promotion; the stable pods of step 2 are the new ones alone.
wait_until 120 "old pods of $stable0 gone after the promotion" test_output "" \
  kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout,rollouts-pod-template-hash=$stable0" -o name
pods_before=$(stable_pods)
ok "stable pods: $(echo "$pods_before" | awk '{printf "%s%s (restarts %s)", sep, $1, $3; sep = ", "}')"

# 2. Bad revision.
echo "2. bad revision: FEED_SERVICE_ADDR=feed-service-missing:9104 (no such Service)"
bad_values=1
upgrade bad --set-string env.FEED_SERVICE_ADDR=feed-service-missing:9104
follow_rollout bad "$good_hash"
[ "$outcome" = aborted ] || fail "bad revision: expected aborted, got $outcome"
bad_hash=$target
wait_until 60 "HTTPRoute api back to 100/0 after the abort" test_output "100 0" route_weights
ok "bad revision $bad_hash aborted by its analysis; HTTPRoute api weights $(route_weights)"
bad_steps=$(steps_json bad)
rollout_json
[ "$(rget '.status.stableRS')" = "$good_hash" ] || fail "stable revision changed during the abort: $(rget '.status.stableRS')"
pods_after=$(stable_pods)
[ "$pods_after" = "$pods_before" ] ||
  fail "stable pods changed during the bad canary: before [$pods_before], after [$pods_after]"
ok "stable pods unchanged (same UIDs, no restart)"

# 3. The good values back.
echo "3. good values back: FEED_SERVICE_ADDR=feed-service:9104"
t_back=$(now_ms)
upgrade back --set-string env.FEED_SERVICE_ADDR=feed-service:9104
bad_values=
follow_rollout back "$good_hash"
[ "$outcome" = same ] || fail "good values back: expected the stable template again (no canary), got $outcome"
back_s=$(secs $(($(now_ms) - t_back)))
ok "good values back: template is stable $good_hash again, Rollout Healthy $back_s s after the upgrade, no canary"
back_steps=$(steps_json back)

# The measurement of step 2's abort.
measure_abort
((measure_ok)) || fail "measurement incomplete (notes above)"
stable5=$(jq -r '.envoy.stable_5xx' "$work/measure.json")
[ "$stable5" = 0 ] || fail "the stable backend answered $stable5 5xx during the bad canary"
client5=$(jq -r '.client.status_5xx' "$work/measure.json")
((client5 > 0)) || fail "no client 5xx: did the bad canary get any traffic?"

out="$drills/canary-drill-$stamp.json"
jq -n --arg stamp "$stamp" --arg baseline "$baseline" --argjson pid "$traffic_pid" --arg own "${own_traffic:+yes}" \
  --arg stable0 "$stable0" --arg good "$good_hash" --arg bad "$bad_hash" --argjson goodsteps "$good_steps" \
  --argjson badsteps "$bad_steps" --argjson backsteps "$back_steps" --arg before "$pods_before" --arg after "$pods_after" \
  --arg back_s "$back_s" --slurpfile m "$work/measure.json" '{
    drill: $stamp, stable_p99_ms_5m: $baseline, traffic: {pid: $pid, started_by_drill: ($own == "yes")},
    good: {from: $stable0, template_hash: $good, steps: $goodsteps, outcome: "promoted"},
    bad: {template_hash: $bad, steps: $badsteps, outcome: "aborted", measurement: $m[0],
      stable_pods_before: ($before | split("\n")), stable_pods_after: ($after | split("\n"))},
    back: {steps: $backsteps, outcome: "stable template again, no canary", healthy_after_s: ($back_s | tonumber)}}' >"$out"
echo "JSON: $out"
if ((inconclusive)); then
  fail "inconclusive: more than 1% of the drill traffic's feed requests got 401 or 429 during the bad canary"
fi
echo "drill-k8s-canary: all checks passed"
