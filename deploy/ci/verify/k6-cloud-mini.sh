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
#   7. The runner over that window, from verify-sample.sh's samples: the lowest MemAvailable and the highest share of
#      throttled CPU periods of a k6 pod.
#   8. .k6/cloud-<time>/summary.json beside the pods' summaries, and a table in the step's output. Passes when every
#      pod wrote its summary with every threshold passed, dropped_iterations is 0, no request met a 429, the register
#      keys equal the pods, and the runner was enough (MemAvailable at least 2 GiB, no k6 pod throttled for more than
#      5% of its periods). A level that fails names why: "runner" when the runner was short, "system" otherwise,
#      "runner unmeasured" when the system passed but no sample of the runner fell in the window.
# Linux only (GNU date), as verify-run.sh.

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

# k6mini_runner FROM TO PODS: step 7 above, a JSON object on stdout, from samples/host.tsv and samples/k6.tsv (their
# formats are in deploy/ci/verify-sample.sh).
k6mini_runner() {
  local samples=$SVP_VERIFY_OUT/samples
  jq -n --rawfile host <(cat "$samples/host.tsv" 2>/dev/null) --rawfile k6 <(cat "$samples/k6.tsv" 2>/dev/null) \
    --argjson a "$1" --argjson b "$2" --argjson pods "$3" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    def inside: (.[0] | tonumber) as $t | $t >= $a and $t <= $b;
    (rows($host) | map(select(length >= 2 and (.[0] | test("^[0-9]+$")) and (.[1] | test("^[0-9]+$")) and inside)
      | .[1] | tonumber) | min) as $mem |
    (rows($k6) | map(select(length == 5 and all(.[0], .[2], .[3]; test("^[0-9]+$")) and inside)) | group_by(.[1])
      | map(select(length >= 2) | sort_by(.[0] | tonumber) | {periods: ((.[-1][2] | tonumber) - (.[0][2] | tonumber)),
        throttled: ((.[-1][3] | tonumber) - (.[0][3] | tonumber)), no_limit: all(.[]; .[4] == "max")})) as $m |
    {
      mem_available_min_mib: (if $mem then $mem / 1024 | floor else null end),
      k6_pods_measured: ($m | length),
      k6_pods_without_cpu_limit: ($m | map(select(.no_limit)) | length),
      k6_throttled_pct_max: ($m | map(if .periods > 0 then .throttled * 10000 / .periods | ceil / 100 else 0 end) | max),
      k6_over_5pct: any($m[]; .throttled * 20 > .periods)
    } | .throttle_measured = (.k6_pods_measured >= $pods)
      # null when no MemAvailable sample fell in the window, or when a k6 pod has no cpu.stat pair in it: unmeasured,
      # neither enough nor short, so the level cannot pass without proof that k6 itself was not throttled.
      | .enough = (if .mem_available_min_mib == null or (.throttle_measured | not) then null
        else .mem_available_min_mib >= 2048 and (.k6_over_5pct | not) end)'
}

# k6mini_level PODS: the level k6-pods-<PODS> (see above). Exits 0 when it passed.
k6mini_level() {
  local pods=$1 run=("$repo/deploy/k6/cloud/run.sh" --context k3d-svp --domain svp.localhost) started ends
  local keys_before keys=null ended= setup_done=0 videos_min=null first last from to out dir server runner rc=0
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
  out=$("${run[@]}" logs) || rc=1
  printf '%s\n' "$out"
  dir=$(sed -n 's/^summaries in //p' <<<"$out")
  [ -n "$dir" ] || dir=.k6/cloud-$(date -u +%Y%m%dT%H%M%SZ)
  dir=$repo/$dir
  mkdir -p "$dir"
  "${run[@]}" delete || rc=1
  # 5.-7.
  server='{}' runner='{}'
  if [ -n "${from:-}" ] && [ "$from" -lt "$to" ]; then
    printf 'k6-pods-%s\t%s\t%s\t%s\n' "$pods" "$from" "$to" "$pods" >>"$SVP_VERIFY_OUT/k6-windows.tsv"
    server=$(k6mini_server "$from" "$to")
    runner=$(k6mini_runner "$from" "$to" "$pods")
  else
    from= to=
    echo "no hold window: setup() did not end in time, or the pods ended it too far apart"
  fi
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
      # A runner short of RAM or CPU explains whatever the system did; one not measured cannot make a level pass.
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
    "  runner: MemAvailable min \(.runner.mem_available_min_mib | n) MiB, k6 throttled max \(.runner.k6_throttled_pct_max | n)% (\(.runner.k6_pods_measured | n) pod(s) measured), enough \(.runner.enough | n)",
    (.k6.thresholds[] | select(.ok | not) | "  FAIL  threshold \(.metric): \(.expression)")
  ' "$dir/summary.json"
  echo "level summary in ${dir#"$repo"/}/summary.json"
  [ "$(jq -r .result "$dir/summary.json")" = pass ] && [ "$rc" = 0 ]
}
export -f k6mini_seed k6mini_job_ended k6mini_setup_ends k6mini_register_keys k6mini_server k6mini_runner k6mini_level

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
