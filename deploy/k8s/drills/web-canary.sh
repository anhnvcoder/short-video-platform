#!/usr/bin/env bash
# Canary of the web client on cluster svp (make drill-k8s-web-canary), on the dev path: the web's Helm release from
# the working tree, no git. With drill traffic running (deploy/k8s/drills/traffic.sh, which requests /login and one
# static asset; started here unless one runs, and then stopped) and, during each canary, browser clients of their own
# (web/e2e/canary/clients.ts, Chromium of web/node_modules: users logged in through the login page, client-side
# navigations, a Server Action, GET /api/feed/explore every second; read its header for what it counts):
#   0. builds: the web image of the working tree (A, build id web_build_id, the one make k8s-up runs: checked) and a
#      second build of the same source with build id <A>-canary (B), so its deploymentId, Server Action ids and chunks
#      can differ from A's: a real other build, which an annotation on the same image is not (no skew to meet).
#      Built by build_image of deploy/k8s/lib.sh and pushed to the registry k3d-svp-registry as dev-<image ID>
#      (the dev path's tag; Kyverno's policy is Audit there). B with A's image ID fails here, before any canary.
#   1. good revision: image B. The clients start on stable A, the first of them an old tab that opens /me before the
#      upgrade and keeps sending its form. The canary must go through 25%, 50%, the gate and 100% and be promoted, both
#      AnalysisRuns Successful with every metric measured and none failed, inconclusive or in error.
#   2. bad revision: GATEWAY_URL to a Service that does not exist (gateway-missing). The canary pod is ready (/healthz
#      reads no backend) and so is /login, which never calls the gateway; the BFF's GET /api/feed/explore, which the
#      clients send every second, answers 502 there: that is the route the bad revision really breaks. The
#      AnalysisRun must fail and abort the Rollout by itself, the canary's weight back to 0, the stable pods untouched
#      (same UIDs, no restart).
#   3. GATEWAY_URL back: the template is the stable one (B) again, no canary.
#   4. build A back, as a canary with the clients again (the old tab now on B): promoted like step 1, which leaves the
#      release as make k8s-up made it.
# Measured: the times of 25%, 50% and the promotion of each good canary; the abort of step 2 as for the gateway
# (canary started, first client 5xx, AnalysisRun Failed, the plugin's last write of HTTPRoute web); the drill traffic's
# web-asset requests and their 404s (an asset only the other build has) in each canary; per client and canary its
# reloads by cause (Server Action 409 x-nextjs-action-not-found, chunk 404, other), its full-page navigations (a
# deployment id mismatch, other), its signals of skew, its Server Actions and how many were 409; restarts of any web pod
# while a canary runs (none may happen).
#
# Pass: steps 1 to 4 as above, no web pod restarted, every client reloaded at most twice in each canary. The reload
# limit counts only when skew happened: the old tab of a good canary must get at least one signal of the other build
# (action 409, chunk 404 or a deployment id mismatch) and reloadOnceOnSkew must then reload it once, for its own build.
# When no old tab got a signal, the reload limit is "not checked" and the drill ends inconclusive (exit 1) after
# writing everything else. A share of Server Actions answered 409 above 10% in the good canaries is printed as a task
# to open (consider a fixed Server Action key), not a failure. More than 1% of the web requests (drill traffic's web
# routes and the clients' API requests) answered 401 or 429 in a canary's window makes the drill inconclusive.
# Table on the terminal, JSON in .k8s/drills/web-canary-<time>.json (counts, times and route names only).
#
# A drill that fails or is interrupted (Ctrl-C, or SIGTERM from a job's timeout) puts GATEWAY_URL back, then build A
# back: the release's image to tag A, which ends any canary in progress, at once when A is still the stable revision
# (its template is the stable one again); once B was promoted, A is promoted in full right away (no steps, no
# analysis: it is the build the drill started from), so no canary stays paused or aborted and HTTPRoute web is 100/0.
# The clients and the drill traffic it started are stopped by their pids.
#
# Usage: through make (SVP_STACK=k3d, CURL_CA_BUNDLE, NODE_EXTRA_CA_CERTS, Node of web/ first on PATH). About 20
# minutes. LOCAL LAB ONLY: the drill, the traffic and each start of the clients delete the register rate limit keys in
# the cluster's Valkey db 10 (deploy/compose/lib.sh).
set -euo pipefail

case ${1:-} in
  drill) ;;
  *)
    echo "usage: web-canary.sh drill" >&2
    exit 2
    ;;
esac
base=${SVP_CANARY_BASE:-https://api.svp.localhost:8443}
web_base=https://svp.localhost:8443
media_origin=https://s3.svp.localhost:8443
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

ns=svp
rollout=web
chart="$repo_root/deploy/helm/svp-service"
stable_cluster="httproute/$ns/web/rule/0/backend/0"
canary_cluster="httproute/$ns/web/rule/0/backend/1"
drills="$repo_root/.k8s/drills"
traffic="$repo_root/deploy/k8s/drills/traffic.sh"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
# Three clients that browse, plus the old tab in the good canaries.
clients_n=3
mkdir -p "$drills"

own_traffic=
bad_values=
tag_a=
tag_b=
clients_pid=

# put_a_back: for the EXIT trap, once the drill may have changed the release's image (tag_b set): the image back to
# tag A, then waits up to 60 s for Rollout web Healthy on that template, stable, with HTTPRoute web 100/0. When A is
# still the stable revision, its template is the stable one again: the controller ends a canary of B at once, aborted
# or paused or not. When another revision is stable (B, promoted by step 1), A becomes a canary of its own, which this
# promotes in full right away: the patch of the Rollout's status that kubectl-argo-rollouts' `promote --full` makes
# (the lab pins no plugin), which also clears an abort and an inconclusive pause and skips the steps and the analysis.
# Safe for A, the build the release ran before the drill; and the controller goes on with it if this trap is killed
# (the job's timeout gives it 120 s) before the wait ends. Prints how to finish by hand and returns 1 when it cannot.
put_a_back() {
  local deadline=$((SECONDS + 60)) state gen obs current stable phase patched=
  echo "note  putting the image of release $rollout back to $tag_a (build A, the one the drill started from)" >&2
  if ! hc upgrade "$rollout" "$chart" --namespace "$ns" --reuse-values --server-side=false \
    --set-string "image.tag=$tag_a" >/dev/null; then
    echo "FAIL  helm upgrade $rollout back to image $tag_a; run make k8s-up, which puts the working tree's build back" >&2
    return 1
  fi
  while :; do
    state=$(kc -n "$ns" get rollout "$rollout" -o json | jq -r '[.metadata.generation,
      (.status.observedGeneration // "-"), (.status.currentPodHash // "-"), (.status.stableRS // "-"),
      (.status.phase // "-")] | @tsv')
    IFS=$'\t' read -r gen obs current stable phase <<<"$state"
    if [ "$obs" = "$gen" ]; then
      if [ "$current" = "$stable" ]; then
        [ "$phase" = Healthy ] && [ "$(route_weights)" = "100 0" ] && break
      elif [ -z "$patched" ]; then
        echo "note  build B is the stable revision: promoting build A ($current) in full (no steps, no analysis)" >&2
        kc -n "$ns" patch rollout "$rollout" --subresource status --type merge -p '{"status":{"promoteFull":true}}' \
          >/dev/null || {
          echo "FAIL  promote build A; run make k8s-up, which puts it back with a canary" >&2
          return 1
        }
        patched=1
      fi
    fi
    if ((SECONDS >= deadline)); then
      echo "FAIL  rollout $ns/$rollout not Healthy on build A ($current) with HTTPRoute web 100/0 within 60s (phase $phase, stable $stable);" \
        "the controller goes on with it: kubectl --context k3d-svp -n $ns get rollout $rollout; make k8s-up if it stays so" >&2
      return 1
    fi
    sleep 2
  done
  ok "release $rollout back to build A: template $current stable, Healthy, HTTPRoute web 100/0"
}

web_canary_exit() {
  local rc=$?
  trap - EXIT
  # A second signal (Ctrl-C again, the job's timeout) must not cut the way back short.
  trap '' INT TERM
  set +e
  stop_clients_now
  # GATEWAY_URL first: a drill stopped between steps 2 and 3 would leave the release broken.
  if [ -n "$bad_values" ]; then
    echo "note  putting GATEWAY_URL of release $rollout back to http://gateway:8080" >&2
    hc upgrade "$rollout" "$chart" --namespace "$ns" --reuse-values --server-side=false \
      --set-string env.GATEWAY_URL=http://gateway:8080 >/dev/null || rc=1
  fi
  if [ -n "$tag_b" ]; then put_a_back || rc=1; fi
  prometheus_stop
  if [ -n "$own_traffic" ] && running=$("$traffic" status) && [ "${running%% *}" = "$own_traffic" ]; then
    "$traffic" stop >/dev/null || rc=1
  fi
  rm -rf "$work"
  exit "$rc"
}
trap web_canary_exit EXIT
# Without these bash dies of the signal and runs no EXIT trap: a job's timeout (SIGTERM to the whole process group)
# would leave the release broken or mid-canary.
trap 'exit 130' INT
trap 'exit 143' TERM

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

rollout_json() { kc -n "$ns" get rollout "$rollout" -o json >"$work/rollout.json" || fail "read rollout $ns/$rollout"; }
rget() { jq -r "$1" "$work/rollout.json"; }

# route_weights: "<stable weight> <canary weight>" of HTTPRoute web.
route_weights() {
  kc -n "$ns" get httproute web -o json | jq -r '[.spec.rules[0].backendRefs[] | (.weight // 1 | tostring)] | join(" ")'
}

# envoy_increase CLUSTER CLASS FROM_S TO_S: responses of CLUSTER (of class CLASS, or all when CLASS is "") Envoy
# counted between two times, rounded; 0 when the series does not exist.
envoy_increase() {
  local sel="envoy_cluster_name=\"$1\"" range=$(($4 - $3))
  [ -z "$2" ] || sel="$sel,envoy_response_code_class=\"$2\""
  promql "round(sum(increase(envoy_cluster_upstream_rq_xx{$sel}[${range}s]))) or on() vector(0)" "$4" |
    jq -r '.[0].value[1] // "0"'
}

# traffic_window FROM_MS TO_MS: "<web requests> <401 or 429> <asset requests> <asset 404>" of the drill traffic's web
# routes (web-login, web-asset) that started between the two times, from the log of the traffic running now.
traffic_window() {
  local log
  log=$("$traffic" status | cut -d' ' -f2) || fail "drill traffic stopped during the drill"
  awk -v a="$1" -v b="$2" '!/^#/ && ($3 == "web-login" || $3 == "web-asset") && $1 >= a && $1 <= b {
      n++
      if ($4 == "401" || $4 == "429") x++
      if ($3 == "web-asset") { s++; if ($4 == "404") f++ }
    }
    END { printf "%d %d %d %d\n", n, x, s, f }' "$log"
}

# api_window LOG FROM_MS TO_MS: "<API requests> <5xx> <401 or 429> <no answer> <first 5xx ms> <last 5xx ms>" of the
# clients' GET /api/feed/explore of LOG that started between the two times (0 when no 5xx).
api_window() {
  awk -v a="$2" -v b="$3" '$3 == "api" && $1 >= a && $1 <= b {
      n++
      if ($4 ~ /^5/) { e++; if (!f) f = $1; l = $1 }
      if ($4 == "401" || $4 == "429") x++
      if ($4 == "000") z++
    }
    END { printf "%d %d %d %d %d %d\n", n, e, x, z, f, l }' "$1"
}

# sample_pods: appends "<uid> <name> <restarts> <last termination reason>" of every web pod to $work/pod-samples (and
# keeps the list in $work/pods.json).
sample_pods() {
  kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout" -o json >"$work/pods.json" || fail "list the pods of $rollout"
  jq -r '.items[] | "\(.metadata.uid) \(.metadata.name) \([.status.containerStatuses[]?.restartCount] | add // 0) \([.status.containerStatuses[]?.lastState.terminated.reason // empty] | first // "-")"' \
    "$work/pods.json" >>"$work/pod-samples"
}

# stable_pods: "name uid restarts" of every pod of the stable ReplicaSet, sorted.
stable_pods() {
  local h
  rollout_json
  h=$(rget '.status.stableRS')
  kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout,rollouts-pod-template-hash=$h" -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null)
      | "\(.metadata.name) \(.metadata.uid) \([.status.containerStatuses[]?.restartCount] | add // 0)"' | sort
}

# upgrade LABEL ARGS...: helm upgrade of release web with its last values (--reuse-values keeps the registry and tag
# make k8s-up set) and the changes in ARGS, client-side like deploy/k8s/install.sh does for this release (the
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
# keeps them in $work/steps-LABEL, and samples the web pods' restarts. Sets outcome to promoted, aborted,
# inconclusive or same (the template is the stable one, no canary), and target to the template hash of the revision.
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
    sample_pods
    if [ "$obs" = "$gen" ]; then
      target=$hash
      pods=$(jq --arg h "$hash" '[.items[] | select(.metadata.labels["rollouts-pod-template-hash"] == $h)
        | select(.metadata.deletionTimestamp == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' "$work/pods.json")
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

# check_good_runs HASH: both AnalysisRuns of the promoted revision HASH, told apart by the label rollout-type Argo
# Rollouts gives each run (Background, and Step for the gate): the newest of each must be Successful, with every
# metric of its spec measured successfully at least once and no measurement failed, inconclusive or in error. The
# phase alone proves nothing for the background run, which the promotion terminates whatever it measured; each run
# gets up to 60 s to end, as the controller marks it after the Rollout is already Healthy (canary.sh says more).
# Sets good_runs to "<background run> <gate run>".
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
      fail "good revision $1: $label AnalysisRun $name $phase, $measured of $metrics metrics measured successfully, failed/inconclusive/error $bad"
    good_runs="${good_runs:+$good_runs }$name"
  done
}

# start_clients LABEL OLD_TAB: starts the browser clients for the canary LABEL (OLD_TAB 1: the first is the old tab)
# in the background, from web/ with the Node of the make target, into $work/clients-LABEL; returns once they are set
# up. Each start registers fresh users, so the register rate limit keys are reset first (LOCAL LAB ONLY).
start_clients() {
  local dir="$work/clients-$1" n=$clients_n deadline=$((SECONDS + 180))
  if [ "$2" = 1 ]; then n=$((n + 1)); fi
  mkdir -p "$dir"
  reset_register_limit >/dev/null
  # exec in the subshell, so $! is node's own pid.
  (cd "$repo_root/web" && exec node e2e/canary/clients.ts "$web_base" "$base" "$media_origin" "$dir" "$n" "$2") \
    >"$dir/out" 2>&1 &
  clients_pid=$!
  until [ -e "$dir/ready" ]; do
    if ! kill -0 "$clients_pid" 2>/dev/null; then
      clients_pid=
      cat "$dir/out" >&2
      fail "$1: the browser clients exited while starting (output above)"
    fi
    ((SECONDS < deadline)) || fail "$1: the browser clients not set up within 180s (output in $dir/out)"
    sleep 1
  done
  if [ "$2" = 1 ]; then ok "$1: $n browser clients logged in, c0 the old tab on /me"; else ok "$1: $n browser clients logged in"; fi
}

# stop_clients LABEL: stops the clients by their pid and waits for their counters in $work/clients-LABEL/clients.json.
stop_clients() {
  local dir="$work/clients-$1" deadline=$((SECONDS + 60))
  kill -TERM "$clients_pid" 2>/dev/null || true
  while kill -0 "$clients_pid" 2>/dev/null; do
    ((SECONDS < deadline)) || fail "$1: the browser clients (pid $clients_pid) still running 60s after SIGTERM"
    sleep 1
  done
  wait "$clients_pid" 2>/dev/null || true
  clients_pid=
  [ -s "$dir/clients.json" ] || {
    cat "$dir/out" >&2
    fail "$1: the browser clients wrote no counters (output above)"
  }
}

# stop_clients_now: for the EXIT trap, without waiting for counters.
stop_clients_now() {
  [ -n "$clients_pid" ] || return 0
  kill -TERM "$clients_pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$clients_pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$clients_pid" 2>/dev/null || true
  wait "$clients_pid" 2>/dev/null || true
  clients_pid=
}

# window_json LABEL FROM_MS TO_MS: the drill traffic's and the clients' requests of canary LABEL between the two times,
# as JSON into $work/window-LABEL.json; sets inconclusive_LABEL to 1 when more than 1% of them got 401 or 429.
window_json() {
  local tn tx ts tf an ae ax az
  read -r tn tx ts tf <<<"$(traffic_window "$2" "$3")"
  read -r an ae ax az _ <<<"$(api_window "$work/clients-$1/clients.log" "$2" "$3")"
  printf -v "inconclusive_$1" '%s' "$(((tx + ax) * 100 > (tn + an) ? 1 : 0))"
  jq -n --argjson tn "$tn" --argjson tx "$tx" --argjson ts "$ts" --argjson tf "$tf" --argjson an "$an" \
    --argjson ae "$ae" --argjson ax "$ax" --argjson az "$az" '{
      traffic: {web_requests: $tn, status_401_429: $tx, web_asset: {requests: $ts, status_404: $tf}},
      clients_api: {requests: $an, status_5xx: $ae, status_401_429: $ax, no_answer: $az}}' >"$work/window-$1.json"
  echo "      $1: drill traffic $tn web requests ($tx 401/429), web-asset $ts with $tf 404; clients' API $an requests ($ae 5xx, $ax 401/429, $az no answer)"
}

# clients_table LABEL: one line per client of canary LABEL.
clients_table() {
  jq -r '.[] | "      \(.client) \(.role): start build \(.start_build // "-"), builds seen \(.builds_seen | keys | join(",")),"
    + " signals action-409 \(.signals.action_409) chunk-404 \(.signals.chunk_404) deployment \(.signals.deployment_mismatch);"
    + " reloads \(.reloads.total) (action \(.reloads.action), chunk \(.reloads.chunk), other \(.reloads.other));"
    + " full-page navigations \(.mpa_navigations.total) (deployment \(.mpa_navigations.deployment));"
    + " actions \(.actions.sent) (409: \(.actions.status_409)); API \(.api.requests)"' "$work/clients-$1/clients.json"
}

# good_canary LABEL TAG FROM_BUILD: canary of image TAG, a good revision, under traffic and the clients with the old
# tab, whose page must be of build FROM_BUILD (the stable one); sets good_hash and writes $work/phase-LABEL.json.
good_canary() {
  local label=$1 tag=$2 from=$3 old t0 t_end weights start
  rollout_json
  old=$(rget '.status.stableRS')
  start_clients "$label" 1
  t0=$(now_ms)
  upgrade "$label" --set-string "image.tag=$tag"
  follow_rollout "$label" "$old"
  [ "$outcome" = promoted ] || fail "$label: expected promoted, got $outcome"
  good_hash=$target
  check_good_runs "$good_hash"
  ok "$label: revision $good_hash promoted $(secs $(($(now_ms) - t0))) s after the upgrade; AnalysisRuns ${good_runs% *} (background) and ${good_runs#* } (gate) Successful, every metric measured"
  # The old ReplicaSet is scaled down 30 s after the promotion: skew lasts until then.
  wait_until 120 "$label: old pods of $old gone after the promotion" test_output "" \
    kc -n "$ns" get pods -l "app.kubernetes.io/name=$rollout,rollouts-pod-template-hash=$old" -o name
  stop_clients "$label"
  t_end=$(now_ms)
  start=$(jq -r '[.[] | select(.role == "old-tab")][0].start_build // ""' "$work/clients-$label/clients.json")
  [ "$start" = "$from" ] || fail "$label: the old tab's page was of build '$start', not the stable build $from"
  window_json "$label" "$t0" "$t_end"
  clients_table "$label"
  weights=$(steps_json "$label")
  jq -n --arg label "$label" --arg tag "$tag" --arg hash "$good_hash" --arg runs "$good_runs" --argjson t0 "$t0" --argjson tend "$t_end" \
    --argjson steps "$weights" --slurpfile w "$work/window-$label.json" --slurpfile c "$work/clients-$label/clients.json" '{
      label: $label, image_tag: $tag, template_hash: $hash, outcome: "promoted",
      analysis_runs: {background: ($runs | split(" ")[0]), gate: ($runs | split(" ")[1])},
      upgrade_at_ms: $t0, window_end_ms: $tend, steps: $steps,
      first_at_weight_ms: ([25, 50] | map(tostring as $w | {key: $w, value: ([$steps[] | select(.weight == $w)][0].at_ms // null)})
        | from_entries),
      promoted_after_s: (([$steps[] | select(.phase == "Healthy")] | .[0].at_ms // $tend) - $t0) / 1000,
      requests: $w[0], clients: $c[0]}' >"$work/phase-$label.json"
}

# ---- the drill

rollout_json
[ "$(rget '.status.phase')" = Healthy ] ||
  fail "rollout $ns/$rollout is $(rget '.status.phase'), not Healthy; run make k8s-up first"
hc status "$rollout" --namespace "$ns" >/dev/null 2>&1 || fail "no Helm release $rollout in $ns (the dev path, make k8s-up)"
command -v node >/dev/null || fail "node not found; run the drill through make drill-k8s-web-canary"
values=$(hc get values "$rollout" --namespace "$ns" --all -o json) || fail "read the values of release $rollout"
tag_now=$(jq -r '.image.tag' <<<"$values")
p99_ms=$(jq -r '.canaryLimits.p99Ms' <<<"$values")
error_ratio=$(jq -r '.canaryLimits.errorRatio' <<<"$values")
[ "$(jq -r '.env.GATEWAY_URL' <<<"$values")" = http://gateway:8080 ] ||
  fail "GATEWAY_URL of release $rollout is not http://gateway:8080 (an interrupted drill?); run make k8s-up first"

# 0. The two builds.
build_a=$(web_build_id) || fail "compute the build id of web/"
build_b="$build_a-canary"
echo "0. builds: A $build_a (the working tree's, as make k8s-up builds it), B $build_b (same source, built again)"
build_image web "$repo_root" || fail "build the web image A"
image_a=$image_id
tag_a="dev-${image_a:0:12}"
[ "$tag_now" = "$tag_a" ] ||
  fail "release $rollout runs image tag $tag_now, not the working tree's build $tag_a; run make k8s-up first"
build_image web "$repo_root" "$build_b" || fail "build the web image B"
image_b=$image_id
[ "$image_b" != "$image_a" ] ||
  fail "build B has the image ID of build A ($image_a): no other build to meet, no skew to measure"
tag_b_candidate="dev-${image_b:0:12}"
docker_ tag "$image_b" "127.0.0.1:5111/svp/web:$tag_b_candidate" || fail "tag build B"
docker_ push --quiet "127.0.0.1:5111/svp/web:$tag_b_candidate" >/dev/null || fail "push build B to the registry"
ok "build A $tag_a (running), build B $tag_b_candidate pushed to the registry"

prometheus_forward
baseline=$(promql "histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=\"$stable_cluster\"}[5m])))" |
  jq -r '.[0].value[1] // "NaN"')
ok "stable backend p99 over the last 5 minutes: $baseline ms; the analysis fails a canary at p99 $p99_ms ms or 5xx ratio $error_ratio"

if running=$("$traffic" status); then
  ok "drill traffic already running (pid ${running%% *}); left running"
else
  "$traffic" start
  running=$("$traffic" status) || fail "drill traffic not running after its start"
  own_traffic=${running%% *}
fi
traffic_pid=${running%% *}
: >"$work/pod-samples"
sample_pods

# 1. Good revision: build B.
echo "1. good revision: image $tag_b_candidate (build B) over stable build A"
tag_b=$tag_b_candidate
good_canary good "$tag_b" "$build_a"
good_b_hash=$good_hash
pods_before=$(stable_pods)
ok "stable pods: $(echo "$pods_before" | awk '{printf "%s%s (restarts %s)", sep, $1, $3; sep = ", "}')"

# 2. Bad revision.
echo "2. bad revision: GATEWAY_URL=http://gateway-missing:8080 (no such Service); the clients' GET /api/feed/explore answers 502 on it"
start_clients bad 0
t_bad=$(now_ms)
bad_values=1
upgrade bad --set-string env.GATEWAY_URL=http://gateway-missing:8080
follow_rollout bad "$good_b_hash"
[ "$outcome" = aborted ] || fail "bad revision: expected aborted, got $outcome"
bad_hash=$target
wait_until 60 "HTTPRoute web back to 100/0 after the abort" test_output "100 0" route_weights
ok "bad revision $bad_hash aborted by its analysis; HTTPRoute web weights $(route_weights)"
# The window of the measurement ends 5 s after the abort: the clients run until then.
sleep 6
stop_clients bad
t_bad_end=$(now_ms)
rollout_json
[ "$(rget '.status.stableRS')" = "$good_b_hash" ] || fail "stable revision changed during the abort: $(rget '.status.stableRS')"
pods_after=$(stable_pods)
[ "$pods_after" = "$pods_before" ] ||
  fail "stable pods changed during the bad canary: before [$pods_before], after [$pods_after]"
ok "stable pods unchanged (same UIDs, no restart)"
window_json bad "$t_bad" "$t_bad_end"
clients_table bad

# 3. GATEWAY_URL back: the stable template again.
echo "3. GATEWAY_URL back to http://gateway:8080"
t_back=$(now_ms)
upgrade back --set-string env.GATEWAY_URL=http://gateway:8080
bad_values=
follow_rollout back "$good_b_hash"
[ "$outcome" = same ] || fail "GATEWAY_URL back: expected the stable template again (no canary), got $outcome"
back_s=$(secs $(($(now_ms) - t_back)))
ok "GATEWAY_URL back: template is stable $good_b_hash again, Rollout Healthy $back_s s after the upgrade, no canary"

# The abort of step 2, measured as for the gateway.
run=$(kc -n "$ns" get analysisruns -o json | jq -c --arg h "$bad_hash" '[.items[]
  | select(.metadata.labels["rollouts-pod-template-hash"] == $h) | select(.status.phase == "Failed")]
  | sort_by(.metadata.creationTimestamp) | last')
[ "$run" != null ] || fail "no failed AnalysisRun of the bad revision $bad_hash"
run_name=$(jq -r '.metadata.name' <<<"$run")
started_ms=$(iso_ms "$(jq -r '.status.startedAt // .metadata.creationTimestamp' <<<"$run")")
failed_ms=$(iso_ms "$(jq -r '.status.completedAt' <<<"$run")")
run_msg=$(jq -r '.status.message // ""' <<<"$run")
metrics=$(jq -c '[.status.metricResults[] | {name, phase, successful: (.successful // 0), failed: (.failed // 0),
  inconclusive: (.inconclusive // 0), values: [.measurements[] | {at: .finishedAt, phase, value}]}]' <<<"$run")
# The plugin's last write of the route: the one that set the canary's weight to 0 (step 3 made no canary, so none
# came after it).
abort_ms=$(kc -n "$ns" get httproute web -o json --show-managed-fields |
  jq -r '[.metadata.managedFields[] | select(.manager == "gatewayAPI" and .subresource == null) | .time] | max // ""')
measure_ok=1
if [ -n "$abort_ms" ]; then abort_ms=$(iso_ms "$abort_ms"); else abort_ms=0; fi
if ((abort_ms < failed_ms)); then
  echo "note  abort done not measurable: no write of HTTPRoute web by the plugin after the failure"
  abort_ms=0 measure_ok=0
fi
win_end=$((abort_ms > 0 ? abort_ms + 5000 : failed_ms + 5000))
read -r n e x z f l <<<"$(api_window "$work/clients-bad/clients.log" "$started_ms" "$win_end")"
t_s=$((win_end / 1000 + 30))
while (($(date +%s) < t_s)); do sleep 2; done
stable5=$(envoy_increase "$stable_cluster" 5 $((started_ms / 1000)) "$t_s")
canary5=$(envoy_increase "$canary_cluster" 5 $((started_ms / 1000)) "$t_s")
canary_all=$(envoy_increase "$canary_cluster" "" $((started_ms / 1000)) "$t_s")
echo
echo "Abort of the canary of rollout $ns/$rollout: AnalysisRun $run_name (template $bad_hash): $run_msg"
printf '  %-36s %-14s %s\n' "event" "time (UTC)" "after"
printf '  %-36s %-14s %s\n' "canary started (AnalysisRun)" "$(hms "$started_ms")" ""
if ((f > 0)); then
  printf '  %-36s %-14s %s\n' "canary got traffic (1st client 5xx)" "$(hms "$f")" "+$(secs $((f - started_ms))) s after start"
  printf '  %-36s %-14s %s\n' "AnalysisRun Failed" "$(hms "$failed_ms")" "+$(secs $((failed_ms - f))) s after traffic"
else
  echo "note  no client 5xx after the canary started: the time it got traffic is not measured"
  measure_ok=0
  printf '  %-36s %-14s %s\n' "AnalysisRun Failed" "$(hms "$failed_ms")" "+$(secs $((failed_ms - started_ms))) s after start"
fi
if ((abort_ms > 0)); then
  printf '  %-36s %-14s %s\n' "abort done (route back to 100/0)" "$(hms "$abort_ms")" "+$(secs $((abort_ms - failed_ms))) s after Failed"
else
  measure_ok=0
fi
if ((f > 0 && abort_ms > 0)); then echo "  canary got traffic -> abort done: $(secs $((abort_ms - f))) s"; fi
echo "  clients (GET /api/feed/explore): $n requests, $e 5xx, $x 401/429, $z without answer"
echo "  Envoy: canary $canary5 5xx of $canary_all responses; stable backend $stable5 5xx"
jq -n --arg run "$run_name" --arg hash "$bad_hash" --arg msg "$run_msg" --argjson started "$started_ms" \
  --argjson traffic "$f" --argjson failed "$failed_ms" --argjson abort "$abort_ms" --argjson last5 "$l" \
  --argjson n "$n" --argjson e "$e" --argjson x "$x" --argjson z "$z" --argjson stable5 "$stable5" \
  --argjson canary5 "$canary5" --argjson canaryall "$canary_all" --argjson metrics "$metrics" \
  --argjson ok "$measure_ok" --slurpfile w "$work/window-bad.json" --slurpfile c "$work/clients-bad/clients.json" \
  --argjson steps "$(steps_json bad)" '{
    label: "bad", route: "GET /api/feed/explore (the BFF calls the gateway; /login does not and stays 200)",
    template_hash: $hash, outcome: "aborted", steps: $steps, analysis_run: $run, message: $msg,
    times_ms: {canary_started: $started, canary_got_traffic: (if $traffic > 0 then $traffic else null end),
      analysis_failed: $failed, abort_done: (if $abort > 0 then $abort else null end),
      last_client_5xx: (if $last5 > 0 then $last5 else null end)},
    seconds: {traffic_to_failed: (if $traffic > 0 then ($failed - $traffic) / 1000 else null end),
      failed_to_abort_done: (if $abort > 0 then ($abort - $failed) / 1000 else null end),
      traffic_to_abort_done: (if $traffic > 0 and $abort > 0 then ($abort - $traffic) / 1000 else null end)},
    clients_api_in_abort_window: {requests: $n, status_5xx: $e, status_401_429: $x, no_answer: $z},
    envoy: {canary_5xx: $canary5, canary_responses: $canaryall, stable_5xx: $stable5},
    metrics: $metrics, complete: ($ok == 1), requests: $w[0], clients: $c[0]}' >"$work/phase-bad.json"

# 4. Build A back, as a canary (before any verdict on the abort, so the release ends as make k8s-up made it).
echo "4. build A back: image $tag_a over stable build B"
good_canary original "$tag_a" "$build_b"
tag_b=

# Restarts of web pods while the canaries ran (probes included): the restart count of each pod over its first sample.
sample_pods
restarted=$(awk 'NF >= 3 {
    if (!($1 in first)) { first[$1] = $3 + 0; max[$1] = $3 + 0 }
    if ($3 + 0 >= max[$1]) { max[$1] = $3 + 0; name[$1] = $2; why[$1] = $4 }
  }
  END { for (u in max) if (max[u] > first[u]) printf "%s %d %s\n", name[u], max[u] - first[u], why[u] }' "$work/pod-samples")
pods_seen=$(awk 'NF >= 3 { print $1 }' "$work/pod-samples" | sort -u | wc -l | tr -d ' ')

# The skew control (the good canaries: the bad one runs the build of its stable revision) and the reload limit (every
# canary).
skew=$(jq -s --arg a "$build_a" --arg b "$build_b" '
  def control(from): [.clients[] | select(.role == "old-tab")][0] as $o
    | {start_build: $o.start_build, signals: $o.signals, reloads: $o.reloads, reload_builds: $o.reload_builds,
       skew_met: ($o.signals.total > 0),
       reloaded_once_for_its_build: ($o.reloads.total >= 1 and $o.reload_builds[0] == from
         and ([$o.reload_builds[] | select(. == from)] | length) == 1)};
  {good: (.[0] | control($a)), original: (.[2] | control($b))} as $controls
  | [.[0], .[2] | .clients[]] as $good_clients
  | {controls: $controls,
     skew_met: ($controls.good.skew_met or $controls.original.skew_met),
     max_reloads_per_client: ([.[] | .clients[] | .reloads.total] | max),
     clients_over_two_reloads: [.[] | .label as $p | .clients[] | select(.reloads.total > 2) | "\($p) \(.client)"],
     actions: {sent: ([$good_clients[] | .actions.sent] | add),
       status_409: ([$good_clients[] | .actions.status_409] | add)}}
  | .actions.ratio_409 = (if .actions.sent > 0 then .actions.status_409 / .actions.sent else null end)' \
  "$work/phase-good.json" "$work/phase-bad.json" "$work/phase-original.json")
ratio=$(jq -r '.actions.ratio_409 // "null"' <<<"$skew")

echo
echo "Skew between builds A ($build_a) and B ($build_b), in the two good canaries:"
for phase in good original; do
  jq -r --arg p "$phase" '.controls[$p] | "  \($p): old tab on \(.start_build): signals action-409 \(.signals.action_409), chunk-404 \(.signals.chunk_404), deployment \(.signals.deployment_mismatch); reloads \(.reloads.total) for builds [\(.reload_builds | join(", "))]"' <<<"$skew"
done
echo "  most reloads of one client in one canary: $(jq -r '.max_reloads_per_client' <<<"$skew") (limit 2)"
echo "  Server Actions in the good canaries: $(jq -r '"\(.actions.sent) sent, \(.actions.status_409) answered 409"' <<<"$skew"), ratio $ratio"
if [ "$ratio" != null ] && jq -e '. > 0.1' <<<"$ratio" >/dev/null; then
  echo "  TASK  more than 10% of the Server Actions were answered 409: open a task to consider a fixed, non-secret Server Action key (not done here)"
fi
web_404=$(jq -s '[.[] | .requests.traffic.web_asset.status_404] | add' "$work/phase-good.json" "$work/phase-original.json")
echo "  drill traffic web-asset 404 in the good canaries: $web_404"
echo "  web pods seen $pods_seen, restarted while the canaries ran: ${restarted:-none}"

d6_reload=checked
if [ "$(jq -r '.skew_met' <<<"$skew")" != true ]; then
  d6_reload="not checked: neither old tab got a signal of the other build (no Server Action 409, chunk 404 or deployment id mismatch), so reloadOnceOnSkew never had to run"
fi

out="$drills/web-canary-$stamp.json"
jq -n --arg stamp "$stamp" --arg a "$build_a" --arg b "$build_b" --arg ta "$tag_a" --arg tb "$tag_b_candidate" \
  --argjson p99 "$p99_ms" --argjson ratio_limit "$error_ratio" --arg baseline "$baseline" \
  --argjson pid "$traffic_pid" --arg own "${own_traffic:+yes}" --arg before "$pods_before" --arg after "$pods_after" \
  --arg back_s "$back_s" --arg restarted "$restarted" --argjson seen "$pods_seen" --argjson skew "$skew" \
  --arg d6 "$d6_reload" --slurpfile good "$work/phase-good.json" --slurpfile bad "$work/phase-bad.json" \
  --slurpfile orig "$work/phase-original.json" '{
    drill: $stamp,
    builds: {a: {build_id: $a, image_tag: $ta}, b: {build_id: $b, image_tag: $tb}},
    canary_limits: {p99_ms: $p99, error_ratio: $ratio_limit}, stable_p99_ms_5m: $baseline,
    traffic: {pid: $pid, started_by_drill: ($own == "yes")},
    good: $good[0], bad: ($bad[0] + {stable_pods_before: ($before | split("\n")), stable_pods_after: ($after | split("\n"))}),
    back: {outcome: "stable template again, no canary", healthy_after_s: ($back_s | tonumber)},
    original: $orig[0],
    skew: ($skew + {reload_limit: $d6}),
    pods: {seen: $seen, restarted: ($restarted | split("\n") | map(select(length > 0)))}}' >"$out"
echo "JSON: $out"

((measure_ok)) || fail "measurement of the abort incomplete (notes above)"
[ "$stable5" = 0 ] || fail "the stable backend answered $stable5 5xx during the bad canary"
[ -z "$restarted" ] || fail "web pods restarted while the canaries ran: $restarted"
for phase in good original; do
  if [ "$(jq -r --arg p "$phase" '.controls[$p].skew_met' <<<"$skew")" = true ] &&
    [ "$(jq -r --arg p "$phase" '.controls[$p].reloaded_once_for_its_build' <<<"$skew")" != true ]; then
    fail "$phase: the old tab met the other build but reloadOnceOnSkew did not reload it once for its own build"
  fi
done
over=$(jq -r '.clients_over_two_reloads | join(", ")' <<<"$skew")
[ -z "$over" ] || fail "clients reloaded more than twice in one canary: $over"
for phase in good bad original; do
  v="inconclusive_$phase"
  if [ "${!v}" = 1 ]; then fail "inconclusive: more than 1% of the web requests got 401 or 429 during canary $phase"; fi
done
if [ "$d6_reload" != checked ]; then fail "inconclusive: reload limit $d6_reload"; fi
echo "drill-k8s-web-canary: all checks passed"
