# shellcheck shell=bash
# Scenario k6-cloud-mini of deploy/ci/verify-run.sh, which sources this file: the k6 Job of profile cloud
# (deploy/k6/cloud/run.sh) scaled down on the k3d cluster of the dev path (job k3d of .github/workflows/verify.yml), at
# 1, 2, 4 and 8 pods, each pod the share of load of a pod of the 20-pod design. make k8s-up, the READY videos the load
# reads (seed-videos), then one step per level, k6-pods-<n>; the first level that does not pass stops the scenario, the
# later ones are skipped. The highest level that passed is the most load this runner carries: a limit of 4 vCPUs shared
# by the whole system and the load, not the system's capacity.
#
# seed-videos: 32 videos of 2 s at 320x240 (8 for each of 4 new users: the upload limit allows 10 at once per user),
# uploaded through Envoy and waited for until READY, then at least 30 in GET /feed/explore: with fewer, most views
# would stop at the gateway's one-per-minute rule for a user and a video (RL-3).
#
# k6-pods-<n>, each:
#   1. LOCAL LAB ONLY, as every k3d drill: deletes the register rate limit keys svp:gw:rl:register:* in the cluster's
#      Valkey db 10 (deploy/compose/lib.sh does it as it is sourced), so that each level starts with none; deletes a Job
#      a level cut short left behind.
#   2. run.sh start with n pods, 2 min up, 10 min held, 1 min down (the deadline of the Job follows).
#   3. Once every pod has logged the end of setup(), counts the register keys: one per pod, as each pod registers its
#      pool from its own address (D23).
#   4. Waits for the Job to end, reads each pod's summary (run.sh logs, .k6/cloud-<time>/pod-<i>.json), deletes it.
#   5. The hold window: from 2 min after the last pod ended setup() to 12 min after the first did, 10 s in from each
#      end; written to $SVP_VERIFY_OUT/k6-windows.tsv for the throttle criterion of deploy/ci/verify-sample.sh.
#   6. Prometheus of the cluster over that window (a port-forward on 127.0.0.1:19090, as the drills open it): p95 and
#      p99 of the gateway by route and of Envoy by route backend, p99_E (Envoy's stable backend of route web, the series
#      the canary analysis reads), the web pods' average CPU, its share of their limit, their throttled periods and
#      highest working set.
#   7. The runner, for this level: every criterion of the runner summary of verify-sample.sh (runner.json, written once
#      at the end of the whole run) read again from the same samples over this level's window, so that a level is
#      counted only when the runner held up to its end: the last level is the one expected to fail, and a runner short
#      during it says nothing of the levels before. Each check is true, false, or null when no sample of its source
#      fell in the window (unmeasured). The checks, their sources and the cases of the self-test below (k6mini_test:
#      one false and one unmeasured case each):
#        mem_available_2gib    host.tsv, MemAvailable every 5 s: the lowest in the window at least 2 GiB
#                              (mem-low, mem-none)
#        k6_cpu_throttle_5pct  k6.tsv, cpu.stat of each k6 pod every 10 s: no pod over 5% of its periods throttled
#                              between its first and last sample in the window, every pod seen there has two samples,
#                              and at least the level's pods are measured (k6-over, k6-one-sample, k6-fewer)
#        no_oom                read once the Job has ended (k6mini_oom, not a sample): no OOM line of the kernel, no
#                              container the Docker daemon marks OOMKilled, no container of a pod of the cluster whose
#                              last end was an OOM kill, since the run began (the runner is new for each job)
#                              (oom-kernel, oom-pod, oom-unread)
#        disk                  disk.tsv every 30 s: no sample up to the window's end under 15% + 1 GiB free; a sample
#                              in the window (disk-low, disk-none)
#        k3d_server_kept       docker.tsv every 10 s: from the first sample with container k3d-svp-server-0 running up
#                              to the window's end, every sample sees it running with the same RestartCount and
#                              StartedAt (a restart between two levels counts, as the summary of the whole run counts
#                              it); a sample in the window (server-restart, server-none)
#        k3d_nodes_ready       docker.tsv: from the first sample with every node Ready up to the window's end, every
#                              sample reads the nodes and finds them Ready; a sample in the window (nodes-notready,
#                              nodes-none)
#        k3d_no_eviction       events.tsv and event-polls.tsv every 60 s: no event Evicted, EvictionThresholdMet or
#                              FreeDiskSpaceFailed read up to the window's end (the API server keeps an event for an
#                              hour, so one before the window is still read in it); a poll that worked in the window
#                              (evict, evict-none)
#      Not read per level: within_deadline (a level that its step's limit stops has no summary), the disk gate before
#      make k8s-up and compose_no_restart (of compose-obs). The runner is enough when every check is true; short when
#      one is false; unmeasured otherwise.
#   8. .k6/cloud-<time>/summary.json beside the pods' summaries, and a table in the step's output. Passes when every
#      pod wrote its summary with every threshold passed, dropped_iterations is 0, no request met a 429, the register
#      keys equal the pods, and the runner was enough. A level that fails names why: "runner" when the runner was
#      short, "system" otherwise, "runner unmeasured" when the system passed but a check of the runner has no sample.
# Linux only (GNU date), as verify-run.sh. Run as a script, bash deploy/ci/verify/k6-cloud-mini.sh test, it runs the
# self-test of step 7 over fixtures (no cluster, no Docker: fake sudo, docker and kubectl), also on macOS.

build=k8s-up
job_minutes_default=330
k3d=1

# k6mini_seed: see seed-videos above. The API helpers of deploy/k8s/drills/lib.sh, through Envoy with the cluster's CA.
k6mini_seed() {
  set -euo pipefail
  local u v name n=0 status count
  # The variables deploy/k8s/drills/lib.sh reads.
  export SVP_STACK=k3d CURL_CA_BUNDLE=$repo/.k8s/ca.crt
  base=https://api.svp.localhost:8443
  # shellcheck source=deploy/k8s/drills/lib.sh
  . "$repo/deploy/k8s/drills/lib.sh"
  wait_gateway_ready 120
  make_video "$work/clip.mp4" 2 320x240
  for u in 1 2 3 4; do
    new_user "seed$u"
    for v in 1 2 3 4 5 6 7 8; do
      name="v${u}_$v"
      create "$name" "$work/seed$u.auth" "$work/clip.mp4"
      upload "$name" "$work/clip.mp4"
      complete "$name" "$work/seed$u.auth"
      n=$((n + 1))
    done
  done
  ok "$n videos uploaded and completed"
  for u in 1 2 3 4; do
    for v in 1 2 3 4 5 6 7 8; do
      wait_ready "v${u}_$v" "$work/seed$u.auth" 600
    done
  done
  ok "$n videos READY"
  # Explore is cached for a while (feed-service), so the new videos may take a moment to show there.
  for _ in $(seq 1 60); do
    status=$(request GET "/feed/explore?page_size=50" "$work/seed1.auth")
    count=$(jq '.items | length' "$work/body" 2>/dev/null || echo 0)
    [[ $status == 200 && $count -ge 30 ]] && break
    sleep 5
  done
  [[ $status == 200 && $count -ge 30 ]] || fail "GET /feed/explore holds at least 30 READY videos (status $status, $count)"
  ok "GET /feed/explore holds $count READY videos"
}

# k6mini_job_ended: prints Complete or Failed once Job svp-load/svp-k6 has ended, nothing before.
k6mini_job_ended() {
  kc -n svp-load get job svp-k6 -o json 2>/dev/null |
    jq -r '[.status.conditions[]? | select(.status == "True" and (.type == "Complete" or .type == "Failed")) | .type] | first // empty'
}

# k6mini_setup_ends: one line per pod of the Job that has logged the end of setup(): the time of that line (seconds
# since the epoch) and the READY videos it read. setup() logs "setup: <users> users, <sessions> web sessions,
# <videos> READY videos (...)" and nothing else of the pool.
k6mini_setup_ends() {
  local pod line
  for pod in $(kc -n svp-load get pods -l batch.kubernetes.io/job-name=svp-k6 -o jsonpath='{.items[*].metadata.name}'); do
    line=$(kc -n svp-load logs --timestamps "$pod" 2>/dev/null | grep -m 1 'msg="setup: ') || continue
    printf '%s %s\n' "$(date -u -d "${line%% *}" +%s)" "$(sed -n 's/.* \([0-9][0-9]*\) READY videos.*/\1/p' <<<"$line")"
  done
}

# k6mini_register_keys: how many register rate limit keys the cluster's Valkey db 10 holds.
k6mini_register_keys() {
  kc -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 10 --scan --pattern 'svp:gw:rl:register:*' | grep -c . || :
}

# k6mini_server FROM TO: step 6 above, a JSON object on stdout; {} when Prometheus did not answer.
k6mini_server() {
  local from=$1 to=$2 port=19090 pid w gw envoy cpu limit throttled ws
  w="$((to - from))s"
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$port:9090" \
    >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 20); do
    curl -sf --max-time 2 "http://127.0.0.1:$port/-/ready" >/dev/null && break
    sleep 1
  done
  # q QUERY: .data.result of QUERY at the end of the window, [] when it did not answer.
  q() {
    local r
    r=$(curl -sf --max-time 20 "http://127.0.0.1:$port/api/v1/query" --data-urlencode "query=$1" \
      --data-urlencode "time=$to") && jq -ce '.data.result // []' <<<"$r" || echo '[]'
  }
  gw=$(for p in 0.95 0.99; do
    q "histogram_quantile($p, sum by (le, http_route) (increase(http_server_request_duration_seconds_bucket{service_name=\"gateway\"}[$w])))"
  done | jq -sc '.')
  envoy=$(for p in 0.95 0.99; do
    q "histogram_quantile($p, sum by (le, envoy_cluster_name) (increase(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~\"httproute/svp/.+\"}[$w])))"
  done | jq -sc '.')
  local sel='namespace="svp",container="web"'
  cpu=$(q "avg(rate(container_cpu_usage_seconds_total{$sel}[$w]))")
  limit=$(q "max(kube_pod_container_resource_limits{$sel,resource=\"cpu\"})")
  throttled=$(q "sum(increase(container_cpu_cfs_throttled_periods_total{$sel}[$w])) / sum(increase(container_cpu_cfs_periods_total{$sel}[$w]))")
  ws=$(q "max(max_over_time(container_memory_working_set_bytes{$sel}[$w]))")
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  jq -n --argjson gw "$gw" --argjson envoy "$envoy" --argjson cpu "$cpu" --argjson limit "$limit" \
    --argjson throttled "$throttled" --argjson ws "$ws" '
    def v: if . == null or . == "NaN" or . == "+Inf" then null else tonumber end;
    def one: .[0].value[1] | v;
    # by(LABEL; SCALE): {label value: {p95, p99}} from the two results of a quantile pair, times SCALE, rounded to 0.1.
    def by($l; $s): [.[0][] | {k: .metric[$l], p95: (.value[1] | v)}] as $a | [.[1][] | {k: .metric[$l], p99: (.value[1] | v)}] as $b
      | ($a + $b) | group_by(.k) | map({key: .[0].k, value: {
          p95_ms: (map(.p95) | map(select(. != null)) | first | if . then . * $s * 10 | round / 10 else null end),
          p99_ms: (map(.p99) | map(select(. != null)) | first | if . then . * $s * 10 | round / 10 else null end)}})
      | from_entries;
    ($cpu | one) as $c | ($limit | one) as $l |
    {
      gateway_by_route: ($gw | by("http_route"; 1000)),
      envoy_by_backend: ($envoy | by("envoy_cluster_name"; 1)),
      p99_E_ms: (($envoy | by("envoy_cluster_name"; 1))["httproute/svp/web/rule/0/backend/0"].p99_ms),
      web: {
        cpu_avg_cores_per_pod: (if $c then $c * 1000 | round / 1000 else null end),
        cpu_limit_cores: $l,
        cpu_share_of_limit: (if $c and $l then $c / $l * 1000 | round / 1000 else null end),
        cpu_throttled_share: ($throttled | one | if . then . * 10000 | round / 10000 else null end),
        working_set_max_mib: ($ws | one | if . then . / 1048576 | round else null end)
      }
    }' || echo '{}'
}

# k6mini_oom: the OOM kills of the run so far, a JSON object on stdout (step 7, no_oom). Read when the Job has ended,
# before its pods are deleted. kernel_lines: the kernel's lines of an OOM kill, as verify-sample.sh counts them (a
# count only: the lines name processes, and the log is public; null when dmesg needs a password). containers: the
# containers the Docker daemon marks OOMKilled, as that summary lists them (a k3d node whose cgroup saw an OOM kill of
# a pod inside it is marked too; null when the daemon did not answer). pods: every container of a pod of the cluster
# whose last end was an OOM kill, namespace/pod/container (null when the API did not answer). A container killed at
# its own memory limit counts as well, as in that summary: either way the run did not hold the load.
k6mini_oom() {
  local log kernel=null list containers=null pods
  if log=$(sudo -n dmesg 2>/dev/null); then
    kernel=$(printf '%s\n' "$log" | grep -Eci 'out of memory|oom-kill') || :
  fi
  local states
  # The list and the inspect are two calls to the daemon: an inspect that fails after the list answered leaves the
  # containers unread (null), never an empty list, so a daemon error cannot pass for "no OOM kill".
  if list=$(env -u DOCKER_DEFAULT_PLATFORM docker ps -aq 2>/dev/null); then
    if [ -z "$(printf '%s' "$list" | tr -d '[:space:]')" ]; then
      containers='[]'
    elif states=$(printf '%s\n' "$list" | grep . |
      xargs env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.Name}} {{.State.OOMKilled}}' 2>/dev/null); then
      containers=$(printf '%s\n' "$states" |
        awk '$2 == "true" { sub(/^\//, "", $1); print $1 }' | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
    fi
  fi
  pods=$(kc get pods -A -o json 2>/dev/null | jq -c '[.items[] | .metadata as $m
    | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[] | .name as $c
    | select(any(.state.terminated, .lastState.terminated; .reason? == "OOMKilled"))
    | "\($m.namespace)/\($m.name)/\($c)"] | unique')
  jq -nc --argjson kernel "$kernel" --argjson containers "${containers:-null}" --argjson pods "${pods:-null}" \
    '{kernel_lines: $kernel, containers: $containers, pods: $pods}'
}

# k6mini_runner FROM TO PODS OOM: step 7 above, a JSON object on stdout, from the samples of deploy/ci/verify-sample.sh
# in $SVP_VERIFY_OUT/samples (their formats are in that script) and OOM, the object of k6mini_oom. FROM and TO are
# seconds since the epoch; both empty when the level has no hold window: then every sampled check is null.
k6mini_runner() {
  local samples=$SVP_VERIFY_OUT/samples
  jq -n --rawfile host <(cat "$samples/host.tsv" 2>/dev/null) --rawfile k6 <(cat "$samples/k6.tsv" 2>/dev/null) \
    --rawfile docker <(cat "$samples/docker.tsv" 2>/dev/null) --rawfile disk <(cat "$samples/disk.tsv" 2>/dev/null) \
    --rawfile events <(cat "$samples/events.tsv" 2>/dev/null) \
    --rawfile polls <(cat "$samples/event-polls.tsv" 2>/dev/null) \
    --arg a "$1" --arg b "$2" --argjson pods "$3" --argjson oom "$4" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    def digits: test("^[0-9]+$");
    def num: if . == "-" or . == null then null else tonumber end;
    # from_first(f): the rows from the first one where f holds, [] when none does.
    def from_first(f): . as $r | ([range(0; length) | select($r[.] | f)] | first) as $i | if $i then $r[$i:] else [] end;
    (if $a == "" then null else ($a | tonumber) end) as $a | (if $b == "" then null else ($b | tonumber) end) as $b |
    # inside: a row timed in the window; upto: one timed at or before its end (the checks that count what happened
    # since the run began).
    def inside: $a != null and (.[0] | tonumber) >= $a and (.[0] | tonumber) <= $b;
    def upto: $b != null and (.[0] | tonumber) <= $b;
    (rows($host) | map(select(length >= 2 and (.[0] | digits) and (.[1] | digits)))) as $h |
    (rows($docker) | map(select(length >= 10 and (.[0] | digits)))) as $d |
    (rows($disk) | map(select(length == 4 and (.[0] | digits)))) as $k |
    (rows($events) | map(select(length == 7 and (.[0] | digits))) | unique_by(.[1])) as $e |
    (rows($polls) | map(select(length == 2 and (.[0] | digits)))) as $q |
    (rows($k6) | map(select(length == 5 and all(.[0], .[2], .[3]; digits)))) as $k6 |
    ($h | map(select(inside) | .[1] | tonumber) | min) as $mem |
    # Per k6 pod in the window: the growth of nr_throttled over that of nr_periods, first to last sample.
    ($k6 | map(select(inside)) | group_by(.[1]) | map(sort_by(.[0] | tonumber) | {samples: length,
      no_limit: all(.[]; .[4] == "max"), periods: ((.[-1][2] | tonumber) - (.[0][2] | tonumber)),
      throttled: ((.[-1][3] | tonumber) - (.[0][3] | tonumber))})) as $seen |
    ($seen | map(select(.samples >= 2))) as $m |
    ($d | map(select(inside)) | length) as $d_in |
    ($d | map(select(upto)) | from_first(.[7] == "running")) as $up |
    ($d | map(select(upto)) | from_first(.[6] == "0")) as $ready |
    ($e | map(select(upto and (.[3] | IN("Evicted", "EvictionThresholdMet", "FreeDiskSpaceFailed"))))) as $ev |
    {
      mem_available_min_mib: (if $mem then $mem / 1024 | floor else null end),
      host_samples: ($h | map(select(inside)) | length),
      k6_pods_seen: ($seen | length),
      k6_pods_measured: ($m | length),
      k6_pods_without_cpu_limit: ($m | map(select(.no_limit)) | length),
      k6_throttled_pct_max: ($m | map(if .periods > 0 then .throttled * 10000 / .periods | ceil / 100 else 0 end) | max),
      k6_over_5pct: any($m[]; .throttled * 20 > .periods),
      oom: $oom,
      disk_samples: ($k | map(select(inside)) | length),
      disk_low_samples: ($k | map(select(upto and .[3] == "1")) | length),
      k3d_samples: $d_in,
      k3d_server_seen: (($up | length) > 0),
      k3d_server_states: ($up | map(select(.[7] == "running") | [.[8], .[9]]) | unique | length),
      k3d_server_not_running_samples: ($up | map(select(.[7] != "running")) | length),
      nodes_all_ready_seen: (($ready | length) > 0),
      nodes_not_ready_samples: ($ready | map(select((.[6] | num // 0) > 0)) | length),
      nodes_unanswered_samples: ($ready | map(select(.[6] == "-")) | length),
      event_polls_ok: ($q | map(select(inside and .[1] == "ok")) | length),
      evictions: ($ev | length),
      eviction_reasons: ($ev | map(.[3]) | group_by(.) | map({key: .[0], value: length}) | from_entries)
    } | .checks = {
      mem_available_2gib: (if .mem_available_min_mib == null then null else .mem_available_min_mib >= 2048 end),
      # An OOM kill seen is short even when another source could not be read; nothing seen with a source unread is not.
      no_oom: (if ($oom.kernel_lines // 0) > 0 or ($oom.containers // []) != [] or ($oom.pods // []) != [] then false
        elif $oom.kernel_lines == null or $oom.containers == null or $oom.pods == null then null else true end),
      disk: (if .disk_low_samples > 0 then false elif .disk_samples == 0 then null else true end),
      k3d_server_kept: (if .k3d_server_seen and (.k3d_server_states != 1 or .k3d_server_not_running_samples > 0)
        then false elif (.k3d_server_seen | not) or .k3d_samples == 0 then null else true end),
      k3d_nodes_ready: (if .nodes_all_ready_seen and (.nodes_not_ready_samples > 0 or .nodes_unanswered_samples > 0)
        then false elif (.nodes_all_ready_seen | not) or .k3d_samples == 0 then null else true end),
      k3d_no_eviction: (if .evictions > 0 then false elif .event_polls_ok == 0 then null else true end),
      k6_cpu_throttle_5pct: (if .k6_over_5pct then false
        elif .k6_pods_seen != .k6_pods_measured or .k6_pods_measured < $pods then null else true end)
    }
      # Unmeasured is neither enough nor short: the level cannot pass without proof of every check.
      | .enough = (.checks | [.[]] | if any(. == false) then false elif any(. == null) then null else true end)'
}

# k6mini_level PODS: the level k6-pods-<PODS> (see above). Exits 0 when it passed.
k6mini_level() {
  local pods=$1 run=("$repo/deploy/k6/cloud/run.sh" --context k3d-svp --domain svp.localhost) started ends
  local keys_before keys=null ended= setup_done=0 videos_min=null first last from to out dir server runner oom rc=0
  local deadline
  # 1. LOCAL LAB ONLY.
  "${run[@]}" delete || return 1
  SVP_STACK=k3d bash -c '. "$1/deploy/compose/lib.sh"' _ "$repo" || return 1
  keys_before=$(k6mini_register_keys)
  # 2.
  started=$(date +%s)
  "${run[@]}" --pods "$pods" --ramp 2m --hold 10m start || return 1
  # 3. setup() takes 3 min at most; the pods may wait for their image first.
  deadline=$((started + 900))
  while :; do
    ends=$(k6mini_setup_ends)
    setup_done=$(grep -c . <<<"$ends" || :)
    ended=$(k6mini_job_ended)
    [ "$setup_done" -ge "$pods" ] || [ -n "$ended" ] || [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 10
  done
  echo "setup() ended in $setup_done of $pods pod(s)"
  if [ "$setup_done" -gt 0 ]; then
    keys=$(k6mini_register_keys)
    first=$(awk '{ print $1 }' <<<"$ends" | sort -n | head -n 1)
    last=$(awk '{ print $1 }' <<<"$ends" | sort -n | tail -n 1)
    videos_min=$(awk '$2 != "" { print $2 }' <<<"$ends" | sort -n | head -n 1)
    videos_min=${videos_min:-null}
    from=$((last + 120 + 10))
    to=$((first + 120 + 600 - 10))
  fi
  # 4. The Job's deadline is 28 min from its start (2 + 10 + 1 + 15).
  deadline=$((started + 1800))
  until [ -n "$ended" ] || [ "$(date +%s)" -ge "$deadline" ]; do
    sleep 15
    ended=$(k6mini_job_ended)
  done
  echo "Job svp-k6: ${ended:-not ended after 30 min}"
  oom=$(k6mini_oom)
  out=$("${run[@]}" logs) || rc=1
  printf '%s\n' "$out"
  dir=$(sed -n 's/^summaries in //p' <<<"$out")
  [ -n "$dir" ] || dir=.k6/cloud-$(date -u +%Y%m%dT%H%M%SZ)
  dir=$repo/$dir
  mkdir -p "$dir"
  "${run[@]}" delete || rc=1
  # 5.-7.
  server='{}'
  if [ -n "${from:-}" ] && [ "$from" -lt "$to" ]; then
    printf 'k6-pods-%s\t%s\t%s\t%s\n' "$pods" "$from" "$to" "$pods" >>"$SVP_VERIFY_OUT/k6-windows.tsv"
    server=$(k6mini_server "$from" "$to")
  else
    from= to=
    echo "no hold window: setup() did not end in time, or the pods ended it too far apart"
  fi
  runner=$(k6mini_runner "${from:-}" "${to:-}" "$pods" "$oom")
  # 8.
  cat "$dir"/pod-*.json 2>/dev/null | jq -s \
    --argjson pods "$pods" --argjson setup_done "$setup_done" --argjson videos_min "$videos_min" \
    --argjson keys_before "${keys_before:-null}" --argjson keys "$keys" --arg job "${ended:-not ended}" \
    --arg from "${from:-}" --arg to "${to:-}" --argjson server "$server" --argjson runner "$runner" '
    def t: if . == "" then null else tonumber | todate end;
    . as $s |
    ($s | map(.routes[]) | group_by(.route) | map({
      route: .[0].route, app: .[0].app, requests: (map(.requests) | add), per_second: (map(.per_second) | add * 100 | round / 100),
      failed_rate_max: (map(.failed_rate) | max), p95_ms_max: (map(.p95_ms) | max), p99_ms_max: (map(.p99_ms) | max),
      rate_limited: (map(.rate_limited) | add)})) as $routes |
    {
      pods: $pods, job: $job, window: {from: ($from | t), to: ($to | t),
        seconds: (if $from == "" then null else ($to | tonumber) - ($from | tonumber) end)},
      setup: {pods_ended: $setup_done, ready_videos_min: $videos_min},
      register_keys: {before: $keys_before, after_setup: $keys},
      k6: {
        pods_with_summary: ($s | length),
        thresholds_ok: (($s | length) == $pods and all($s[]; .thresholds_ok)),
        thresholds: ($s | map(.thresholds[]) | group_by(.metric + " " + .expression)
          | map({metric: .[0].metric, expression: .[0].expression, ok: all(.[]; .ok)})),
        dropped_iterations: ($s | map(.dropped_iterations) | add // 0),
        rate_limited: ($routes | map(.rate_limited) | add // 0),
        per_second: ($routes | map(.per_second) | add // 0 | . * 100 | round / 100),
        routes: $routes,
        note: "p95_ms_max, p99_ms_max: the highest of the pods (percentiles of separate processes do not add up)"
      },
      server: $server,
      runner: $runner
    } | .d23_one_key_per_pod = (.register_keys.after_setup == $pods and .k6.rate_limited == 0)
      | .system_ok = (.k6.thresholds_ok and .k6.dropped_iterations == 0 and .d23_one_key_per_pod and $setup_done == $pods)
      # A runner that was short explains whatever the system did; one not measured cannot make a level pass.
      | .result = (if .runner.enough == false then "fail: runner" elif (.system_ok | not) then "fail: system"
        elif .runner.enough == true then "pass" else "fail: runner unmeasured" end)
  ' >"$dir/summary.json" || {
    echo "FAIL  k6-pods-$pods: the level's summary was not written"
    return 1
  }
  jq -r '
    def n: if . == null then "-" else tostring end;
    "k6-pods-\(.pods): \(.result); \(.k6.per_second) req/s from \(.k6.pods_with_summary) of \(.pods) pod(s), thresholds \(if .k6.thresholds_ok then "ok" else "FAILED" end), dropped_iterations \(.k6.dropped_iterations), 429 \(.k6.rate_limited)",
    "  hold window \(.window.from | n) to \(.window.to | n) (\(.window.seconds | n) s); register keys after setup() \(.register_keys.after_setup | n) for \(.pods) pod(s) (D23 \(.d23_one_key_per_pod)), READY videos \(.setup.ready_videos_min | n)",
    "  route                        req/s   k6 p95   k6 p99   gw p95   gw p99",
    (.server.gateway_by_route // {}) as $g | (.k6.routes[] | "  \(.route | . + " " * (26 - length))\(.per_second | n | " " * (9 - length) + .)\(.p95_ms_max | n | " " * (9 - length) + .)\(.p99_ms_max | n | " " * (9 - length) + .)\($g[.route].p95_ms | n | " " * (9 - length) + .)\($g[.route].p99_ms | n | " " * (9 - length) + .)"),
    "  Envoy p95/p99 ms: \((.server.envoy_by_backend // {}) | to_entries | map("\(.key) \(.value.p95_ms | n)/\(.value.p99_ms | n)") | join(", "))",
    "  p99_E (web, stable backend) \(.server.p99_E_ms | n) ms; web CPU \(.server.web.cpu_avg_cores_per_pod | n) cores a pod, \(.server.web.cpu_share_of_limit | n) of its limit, throttled \(.server.web.cpu_throttled_share | n), working set max \(.server.web.working_set_max_mib | n) MiB",
    "  runner: MemAvailable min \(.runner.mem_available_min_mib | n) MiB, k6 throttled max \(.runner.k6_throttled_pct_max | n)% (\(.runner.k6_pods_measured | n) pod(s) measured, \(.runner.k6_pods_seen | n) seen), kernel OOM lines \(.runner.oom.kernel_lines | n), OOMKilled containers \(.runner.oom.containers | if . == null then "-" else "[\(join(" "))]" end), pods \(.runner.oom.pods | if . == null then "-" else "[\(join(" "))]" end)",
    "  runner: disk low samples \(.runner.disk_low_samples | n), k3s server states \(.runner.k3d_server_states | n) (not running in \(.runner.k3d_server_not_running_samples | n) sample(s)), nodes not Ready in \(.runner.nodes_not_ready_samples | n), not answering in \(.runner.nodes_unanswered_samples | n), evictions \(.runner.evictions | n) (events read \(.runner.event_polls_ok | n) time(s) in the window)",
    "  runner enough: \(.runner.enough | n); " + ((.runner.checks // {}) | to_entries | map("\(.key)=\(.value | n)") | join(" ")),
    (.k6.thresholds[] | select(.ok | not) | "  FAIL  threshold \(.metric): \(.expression)")
  ' "$dir/summary.json"
  echo "level summary in ${dir#"$repo"/}/summary.json"
  [ "$(jq -r .result "$dir/summary.json")" = pass ] && [ "$rc" = 0 ]
}
export -f k6mini_seed k6mini_job_ended k6mini_setup_ends k6mini_register_keys k6mini_server k6mini_runner k6mini_oom \
  k6mini_level

scenario_targets() {
  local k6mini_pods k6mini_stop=
  step k8s-up 60 make k8s-up
  step seed-videos 40 bash -c 'k6mini_seed'
  case $last_status in fail | timeout) k6mini_stop="seed-videos did not pass" ;; esac
  for k6mini_pods in 1 2 4 8; do
    if [ -n "$k6mini_stop" ]; then
      skip "k6-pods-$k6mini_pods" "$k6mini_stop"
      continue
    fi
    step "k6-pods-$k6mini_pods" 40 bash -c 'k6mini_level "$1"' _ "$k6mini_pods"
    case $last_status in fail | timeout) k6mini_stop="level k6-pods-$k6mini_pods did not pass" ;; esac
  done
}

# k6mini_test: the self-test of step 7 (see the header), over fixtures in a temporary directory: the samples of a
# clean hold window 1000-1600 (seconds since the epoch) of a level of 2 pods, each case changing one source; for
# k6mini_oom a fake sudo, docker and kubectl first on PATH. No cluster, no Docker, no network. Exits 1 when a case fails.
k6mini_test() {
  local work bin samples failures=0 started=2026-10-26T15:01:07Z oom_kernel
  local oom_clean='{"kernel_lines":0,"containers":[],"pods":[]}'
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  bin=$work/bin
  mkdir -p "$bin"
  export SVP_VERIFY_OUT=$work/out
  samples=$SVP_VERIFY_OUT/samples
  ok() { echo "ok    $1"; }
  fail() {
    echo "FAIL  $1" >&2
    failures=$((failures + 1))
  }
  same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
  # The fakes, as the runner's commands answer: sudo -n dmesg prints FAKE_DMESG (exit 1 with FAKE_SUDO_FAIL); docker
  # ps -aq lists FAKE_DOCKER_CONTAINERS and docker inspect marks those of FAKE_DOCKER_OOM OOMKilled (exit 1 with
  # FAKE_DOCKER_FAIL); kubectl get pods prints the file FAKE_PODS_JSON (exit 1 with FAKE_KUBECTL_FAIL).
  cat >"$bin/sudo" <<'EOS'
#!/usr/bin/env bash
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
printf '%s\n' "${FAKE_DMESG:-}"
EOS
  cat >"$bin/docker" <<'EOS'
#!/usr/bin/env bash
[ "${FAKE_DOCKER_FAIL:-}" = 1 ] && exit 1
case $1 in
  ps) printf '%s\n' ${FAKE_DOCKER_CONTAINERS:-} ;;
  inspect) shift 3; for c in "$@"; do case " ${FAKE_DOCKER_OOM:-} " in *" $c "*) echo "/$c true" ;; *) echo "/$c false" ;; esac; done ;;
  *) exit 1 ;;
esac
EOS
  cat >"$bin/kubectl" <<'EOS'
#!/usr/bin/env bash
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && exit 1
cat "$FAKE_PODS_JSON"
EOS
  chmod +x "$bin"/*
  PATH=$bin:$PATH
  kc() { kubectl --context k3d-svp "$@"; }
  # A pod whose container last ended in an OOM kill (as tempo-0 did under load), beside a running one.
  cat >"$work/pods-oom.json" <<'EOS'
{"items": [
  {"metadata": {"namespace": "svp-obs", "name": "tempo-0"}, "status": {"containerStatuses": [
    {"name": "tempo", "state": {"waiting": {"reason": "CrashLoopBackOff"}}, "lastState": {"terminated": {"reason": "OOMKilled"}}}]}},
  {"metadata": {"namespace": "svp", "name": "web-1"}, "status": {"containerStatuses": [
    {"name": "web", "state": {"running": {}}, "lastState": {}}]}}]}
EOS
  cat >"$work/pods-clean.json" <<'EOS'
{"items": [{"metadata": {"namespace": "svp", "name": "web-1"}, "status": {"containerStatuses": [
  {"name": "web", "state": {"running": {}}, "lastState": {}}]}}]}
EOS
  export FAKE_DOCKER_CONTAINERS="k3d-svp-server-0 k3d-svp-agent-0" FAKE_PODS_JSON=$work/pods-clean.json
  export FAKE_DMESG= FAKE_DOCKER_OOM= FAKE_SUDO_FAIL= FAKE_DOCKER_FAIL= FAKE_KUBECTL_FAIL=

  # clean: the samples of a runner that held: the cluster up from 920 on, 8 GiB available, the server running with
  # one RestartCount and StartedAt, every node Ready, disk not low, events read and none of them an eviction, two k6
  # pods a and b with 100 periods per sample and none throttled, under a CPU limit.
  clean() {
    mkdir -p "$samples"
    awk 'BEGIN { for (t = 900; t <= 1700; t += 5) printf "%d\t8388608\t0\t10\n", t }' >"$samples/host.tsv"
    awk -v s="$started" 'BEGIN { OFS = "\t"; for (t = 900; t <= 1700; t += 10)
      if (t < 920) print t, 0, 0, "-", "-", "-", "-", "-", "-", "-", "-", "-", "-", "-"
      else print t, 5000, 0, 50, 20, 1, 0, "running", 0, s, 0, 400, 100, 50 }' >"$samples/docker.tsv"
    awk 'BEGIN { OFS = "\t"; for (t = 900; t <= 1700; t += 30) print t, 80000000000, 150000000000, 0 }' >"$samples/disk.tsv"
    : >"$samples/events.tsv"
    awk 'BEGIN { OFS = "\t"; for (t = 900; t <= 1700; t += 60) print t, "ok" }' >"$samples/event-polls.tsv"
    awk 'BEGIN { OFS = "\t"; for (t = 1000; t <= 1600; t += 10) { n = (t - 1000) * 10
      print t, "a", n, 0, 100000; print t, "b", n, 0, 100000 } }' >"$samples/k6.tsv"
  }
  # edit FILE AWK: rewrites samples/FILE.tsv through an awk program over tab-separated fields.
  edit() { awk -F '\t' -v OFS='\t' "$2" "$samples/$1.tsv" >"$work/edit" && mv "$work/edit" "$samples/$1.tsv"; }
  # verdict KEY [OOM [FROM TO]]: "<checks.KEY> <enough>" of k6mini_runner over the samples now.
  verdict() {
    k6mini_runner "${3-1000}" "${4-1600}" 2 "${2:-$oom_clean}" | jq -r --arg k "$1" '"\(.checks[$k]) \(.enough)"'
  }

  clean
  same "clean: every check true, the runner enough" "true true true true true true true true" \
    "$(k6mini_runner 1000 1600 2 "$oom_clean" | jq -r '[.checks[], .enough] | map(tostring) | join(" ")')"
  same "clean: the checks are those of runner.json for the scenario" \
    "mem_available_2gib no_oom disk k3d_server_kept k3d_nodes_ready k3d_no_eviction k6_cpu_throttle_5pct" \
    "$(k6mini_runner 1000 1600 2 "$oom_clean" | jq -r '.checks | keys_unsorted | join(" ")')"
  same "clean: the window's numbers" "8192 121 2/2/0 20 61/1/0 0/0 10/0" \
    "$(k6mini_runner 1000 1600 2 "$oom_clean" | jq -r '"\(.mem_available_min_mib) \(.host_samples) \(.k6_pods_seen)/\(.k6_pods_measured)/\(.k6_throttled_pct_max) \(.disk_samples) \(.k3d_samples)/\(.k3d_server_states)/\(.k3d_server_not_running_samples) \(.nodes_not_ready_samples)/\(.nodes_unanswered_samples) \(.event_polls_ok)/\(.evictions)"')"
  same "no window: every sampled check unmeasured, the OOM check read" "null true null null null null null null" \
    "$(k6mini_runner "" "" 2 "$oom_clean" | jq -r '[.checks[], .enough] | map(tostring) | join(" ")')"

  clean
  printf '1300\t1000000\t0\t10\n' >>"$samples/host.tsv"
  same "mem-low: 976 MiB available at one sample of the window is short" "false false" "$(verdict mem_available_2gib)"
  clean
  edit host '$1 < 1000'
  same "mem-none: no MemAvailable sample in the window is unmeasured" "null null" "$(verdict mem_available_2gib)"
  clean
  printf '1300\t-\t0\t-\n' >>"$samples/host.tsv"
  same "mem: a host line without a number is not a sample" "true true" "$(verdict mem_available_2gib)"

  clean
  edit k6 '$2 == "b" { $4 = int($3 / 10) } { print }'
  same "k6-over: pod b throttled 10% of its periods is short" "false false" "$(verdict k6_cpu_throttle_5pct)"
  clean
  edit k6 '$2 == "b" { $4 = int($3 / 20) } { print }'
  same "k6: exactly 5% throttled passes" "true true" "$(verdict k6_cpu_throttle_5pct)"
  clean
  edit k6 '$2 != "b" || $1 == 1000'
  same "k6-one-sample: pod b with a single sample in the window is unmeasured" "null null" "$(verdict k6_cpu_throttle_5pct)"
  clean
  edit k6 '$2 != "b"'
  same "k6-fewer: one pod measured of the two the level ran is unmeasured" "null null" "$(verdict k6_cpu_throttle_5pct)"
  clean
  edit k6 '$1 >= 1000 && $1 <= 1300 { $5 = "max" } { print }'
  same "k6: a pod without a CPU limit for part of the window is measured, the limit is per sample" "true true" \
    "$(verdict k6_cpu_throttle_5pct)"

  clean
  same "oom: nothing seen by the three sources" "$oom_clean" "$(k6mini_oom)"
  oom_kernel=$(FAKE_DMESG=$'[1.0] x: Out of memory: Killed process 1 (tempo)\n[2.0] oom-kill:constraint=CONSTRAINT_MEMCG\n[3.0] usb 1-1: new device' \
    k6mini_oom)
  same "oom-kernel: two OOM lines of the kernel, counted, are short" "2 false false" \
    "$(jq -r '.kernel_lines' <<<"$oom_kernel") $(verdict no_oom "$oom_kernel")"
  same "oom-container: a container the daemon marks OOMKilled is short" '["k3d-svp-server-0"] false false' \
    "$(FAKE_DOCKER_OOM=k3d-svp-server-0 k6mini_oom | jq -c '.containers') $(verdict no_oom "$(FAKE_DOCKER_OOM=k3d-svp-server-0 k6mini_oom)")"
  same "oom-pod: a pod's container that last ended in an OOM kill is short, even with dmesg unread" \
    'null ["svp-obs/tempo-0/tempo"] false false' \
    "$(FAKE_SUDO_FAIL=1 FAKE_PODS_JSON=$work/pods-oom.json k6mini_oom | jq -r '"\(.kernel_lines) \(.pods | tojson)"') $(
      verdict no_oom "$(FAKE_SUDO_FAIL=1 FAKE_PODS_JSON=$work/pods-oom.json k6mini_oom)")"
  same "oom-unread: dmesg unread and nothing seen is unmeasured" "null [] [] null null" \
    "$(FAKE_SUDO_FAIL=1 k6mini_oom | jq -r '"\(.kernel_lines) \(.containers | tojson) \(.pods | tojson)"') $(verdict no_oom "$(FAKE_SUDO_FAIL=1 k6mini_oom)")"
  same "oom-unread: the API not answering is unmeasured" "null null" "$(verdict no_oom "$(FAKE_KUBECTL_FAIL=1 k6mini_oom)")"
  same "oom-unread: the daemon not answering is unmeasured" "null null" "$(verdict no_oom "$(FAKE_DOCKER_FAIL=1 k6mini_oom)")"

  clean
  printf '700\t1000\t150000000000\t1\n' >>"$samples/disk.tsv"
  same "disk-low: a sample low on disk before the window counts, since the run began" "false false" "$(verdict disk)"
  clean
  edit disk '$1 < 1000'
  same "disk-none: no disk sample in the window is unmeasured" "null null" "$(verdict disk)"

  clean
  edit docker '$1 >= 1300 { $9 = 1; $10 = "2026-10-26T15:20:00Z" } { print }'
  same "server-restart: a restart of the k3s server in the window is short" "false false" "$(verdict k3d_server_kept)"
  clean
  edit docker '$1 >= 950 { $10 = "2026-10-26T15:20:00Z" } { print }'
  same "server-restart: a restart between two levels (StartedAt changed before the window) is short" "false false" \
    "$(verdict k3d_server_kept)"
  clean
  edit docker '$1 == 1300 { $8 = "stopped" } { print }'
  same "server-restart: the server stopped at a sample is short" "false false" "$(verdict k3d_server_kept)"
  clean
  edit docker '$1 == 1300 { $8 = "-" } { print }'
  same "server-restart: the daemon not answering at a sample is short, not unmeasured" "false false" "$(verdict k3d_server_kept)"
  clean
  edit docker '$1 < 1000'
  same "server-none: no docker sample in the window is unmeasured" "null null" "$(verdict k3d_server_kept)"
  same "nodes-none: the same for the nodes" "null null" "$(verdict k3d_nodes_ready)"
  clean
  edit docker '{ $8 = "-"; $9 = "-"; $10 = "-" } { print }'
  same "server-none: a server never seen running is unmeasured" "null null" "$(verdict k3d_server_kept)"

  clean
  edit docker '$1 == 1300 { $7 = 1 } { print }'
  same "nodes-notready: a node not Ready at a sample of the window is short" "false false" "$(verdict k3d_nodes_ready)"
  clean
  edit docker '$1 == 950 { $7 = 1 } { print }'
  same "nodes-notready: a node not Ready between two levels is short" "false false" "$(verdict k3d_nodes_ready)"
  clean
  edit docker '$1 == 1300 { $7 = "-" } { print }'
  same "nodes-notready: the API not answering at a sample is short, not unmeasured" "false false" "$(verdict k3d_nodes_ready)"
  clean
  edit docker '$7 == 0 { $7 = 1 } { print }'
  same "nodes-none: nodes never all Ready is unmeasured" "null null" "$(verdict k3d_nodes_ready)"

  clean
  printf '1200\tuid-1\tsvp\tEvicted\tPod\tweb-1\t-\n' >>"$samples/events.tsv"
  same "evict: an eviction read in the window is short" "false false" "$(verdict k3d_no_eviction)"
  clean
  printf '950\tuid-1\tsvp\tFreeDiskSpaceFailed\tNode\tk3d-svp-agent-0\t-\n' >>"$samples/events.tsv"
  same "evict: an eviction event read before the window counts, since the run began" "false false" "$(verdict k3d_no_eviction)"
  clean
  printf '1200\tuid-2\tsvp\tFailedPull\tPod\tweb-1\t429\n' >>"$samples/events.tsv"
  same "evict: a refused pull is no eviction" "true true" "$(verdict k3d_no_eviction)"
  clean
  edit event-polls '$1 >= 1000 && $1 <= 1600 { $2 = "fail" } { print }'
  same "evict-none: no read of the events that worked in the window is unmeasured" "null null" "$(verdict k3d_no_eviction)"

  clean
  printf '1300\t1000000\t0\t10\n' >>"$samples/host.tsv"
  edit k6 '$2 != "b"'
  same "enough: one check short beside one unmeasured is short" "false null false" \
    "$(k6mini_runner 1000 1600 2 "$oom_clean" | jq -r '"\(.checks.mem_available_2gib) \(.checks.k6_cpu_throttle_5pct) \(.enough)"')"

  echo "k6mini_test: $failures failure(s)"
  [ "$failures" = 0 ]
}

# Run as a script (not sourced by verify-run.sh): the self-test.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    test) k6mini_test ;;
    *)
      echo "usage: bash deploy/ci/verify/k6-cloud-mini.sh test (the self-test; verify-run.sh sources this file)" >&2
      exit 2
      ;;
  esac
fi
