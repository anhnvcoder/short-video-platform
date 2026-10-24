#!/usr/bin/env bash
# Samples the machine of a verification run in the background, so a red run can be told apart from a runner that ran
# short (docs/adr/0021-deferred-verification-stage6b.md, section 2, "runner đủ"). Linux only (/proc, GNU df, setsid).
#
#   verify-sample.sh start   records free -m, swapon --show, nproc and the kernel in host-start.txt, then starts the
#                            sampler (this script's internal loop mode) detached, its pid in
#                            $SVP_VERIFY_OUT/sampler.pid; refuses to start a second one
#   verify-sample.sh stop    stops the process of that pid (only when its command line is this script's loop), then
#                            writes the summary below and prints runner.txt
#
# Samples, in $SVP_VERIFY_OUT/samples/ (one line each, seconds since the epoch first):
#   host.tsv         every 5 s   MemAvailable (KiB), swap in use (KiB), CPU busy % since the line before (/proc/stat;
#                                iowait counted idle)
#   docker.tsv       every 10 s  MEM USAGE of docker stats --no-stream summed over the k3d containers (k3d-svp-*, the
#                                registry included: the cluster budget of ADR-0014 section 2) and over the compose
#                                containers (svp-*), in MiB; CPU % of k3d-svp-server-0 and k3d-svp-agent-0; the Running
#                                media-worker pods and the nodes not Ready ("-" when the API did not answer, or without
#                                a cluster); the state of container k3d-svp-server-0 (running or stopped), its
#                                RestartCount and StartedAt ("-" without it)
#   pods.tsv         every 30 s  kubectl top pods --containers of namespaces svp, svp-data and cnpg-system: namespace,
#                                pod, container, CPU in millicores, working set in MiB (the web pods, the Postgres pods
#                                with the Barman Cloud sidecar, the plugin itself: what the web's resources and the
#                                plugin's 256 Mi limit are set from)
#   disk.tsv         every 30 s  free and total bytes of the filesystem of Docker's data, and 1 when free is under 15%
#                                of the total + 1 GiB: then it also creates $SVP_VERIFY_OUT/disk-low, and
#                                deploy/ci/verify-run.sh starts no further target (kubelet would otherwise evict pods
#                                mid-drill, far from the cause)
#   events.tsv       every 60 s  the cluster's events Evicted, EvictionThresholdMet and FreeDiskSpaceFailed and those
#                                whose message has "429 Too Many Requests" (an image pull refused): uid, namespace,
#                                reason, kind and name of the object, 429 or "-"; never the message. The API server
#                                keeps an event for an hour only (k3s's default --event-ttl), so a run of several hours
#                                is read all along, not once at the end
#   event-polls.tsv  every 60 s  ok or fail: whether that read of the events worked
# The summary: runner.json and runner.txt (lowest MemAvailable, highest swap and CPU, lowest free disk, containers
# OOMKilled, OOM lines of the kernel, compose containers that restarted, nodes not Ready or not answering, a k3s
# server restart or stop, the events above and the target outputs that mention a 429, the highest working set of each
# container sampled in pods.tsv, the targets the deadline cut (results.tsv of deploy/ci/verify-run.sh: timeout,
# cancelled, or skipped for the deadline), and the criteria of the table "runner đủ" for the scenario of
# $SVP_VERIFY_OUT/scenario), df-after.txt, and while the cluster runs make k8s-status and kubectl get events -A
# (k8s-status.txt, events.txt), or while compose runs make ps (compose-ps.txt). Only numbers, states and names reach
# the log: never an event's text, never a service's log.
#
# Of the k3d criteria, a sample the cluster could not answer counts against the runner, never for it: from the first
# sample of a running k3s server on, every sample must see it running with the same RestartCount and StartedAt; from
# the first sample with every node Ready on (before it the cluster is still being made), every sample must read the
# nodes and find them Ready; and the events must have been read at least once.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# ci_temp_dir and the other ci_* functions: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
samples=$out/samples
pidfile=$out/sampler.pid
gib=$((1024 * 1024 * 1024))
worker_selector=app.kubernetes.io/name=media-worker,app.kubernetes.io/component=server

fail() {
  echo "FAIL  verify-sample: $1" >&2
  exit 1
}
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
# Bounded: a cluster too busy to answer delays a sample, never stops the sampler.
kc() { kubectl --context k3d-svp --request-timeout=10s "$@"; }

# running: true when the pid of $pidfile runs this script's loop; sets pid.
running() {
  pid=
  [ -s "$pidfile" ] || return 1
  read -r pid <"$pidfile" || return 1
  case $pid in '' | *[!0-9]*) return 1 ;; esac
  case $(ps -p "$pid" -o args= 2>/dev/null) in
    *verify-sample.sh\ loop*) return 0 ;;
    *) return 1 ;;
  esac
}

cluster_up() { [ "$(docker_ inspect -f '{{.State.Running}}' k3d-svp-server-0 2>/dev/null)" = true ]; }

# awk_mem: the awk function mib(S), MEM USAGE of docker stats ("1.5GiB / 15.6GiB", its first half) in MiB.
awk_mem='function mib(s,   n, u) {
    n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
    if (u == "GiB") return n * 1024; if (u == "MiB") return n; if (u == "KiB") return n / 1024
    if (u == "GB") return n * 1e9 / 1048576; if (u == "MB") return n * 1e6 / 1048576; if (u == "kB") return n * 1e3 / 1048576
    return n / 1048576
  }'

docker_sample() {
  local t=$1 stats server agent workers=- notready=- nodes state
  stats=$(docker_ stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null) || stats=
  read -r k3d_mib compose_mib server agent < <(printf '%s\n' "$stats" | awk -F '\t' "$awk_mem"'
    { split($3, m, " / "); v = mib(m[1]); cpu = $2; sub(/%$/, "", cpu) }
    $1 ~ /^k3d-svp-/ { k += v } $1 ~ /^svp-/ { c += v }
    $1 == "k3d-svp-server-0" { s = cpu } $1 == "k3d-svp-agent-0" { a = cpu }
    END { printf "%.0f %.0f %s %s\n", k, c, (s == "" ? "-" : s), (a == "" ? "-" : a) }')
  # The server's state also once it stopped: a server that went away must show in the samples, not drop out of them.
  state=$(docker_ inspect -f '{{if .State.Running}}running{{else}}stopped{{end}} {{.RestartCount}} {{.State.StartedAt}}' \
    k3d-svp-server-0 2>/dev/null) || state="- - -"
  if [ "${state%% *}" = running ]; then
    workers=$(kc -n svp get pods -l "$worker_selector" --field-selector=status.phase=Running --no-headers 2>/dev/null |
      wc -l | tr -d ' ')
    if nodes=$(kc get nodes --no-headers 2>/dev/null) && [ -n "$nodes" ]; then
      # Only the first field of STATUS: a cordoned node shows "Ready,SchedulingDisabled" and is still Ready (make
      # drill-k8s-pdb cordons every node for a while), while "NotReady,SchedulingDisabled" is not.
      notready=$(printf '%s\n' "$nodes" | awk '{ split($2, s, ",") } s[1] != "Ready"' | wc -l | tr -d ' ')
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$k3d_mib" "$compose_mib" "$server" "$agent" "$workers" "$notready" \
    "${state// /$'\t'}" >>"$samples/docker.tsv"
}

pods_sample() {
  local t=$1
  # kubectl top prints CPU as <n>m and memory as <n>Mi.
  kc top pods -A --containers --no-headers 2>/dev/null | awk -v t="$t" -v OFS='\t' '
    $1 == "svp" || $1 == "svp-data" || $1 == "cnpg-system" {
      cpu = $4; sub(/m$/, "", cpu); mem = $5; sub(/Mi$/, "", mem); print t, $1, $2, $3, cpu, mem }' \
    >>"$samples/pods.tsv"
}

events_sample() {
  local t=$1
  if kc get events -A -o json 2>/dev/null | jq -r --arg t "$t" '
    .items[] | ((.message // "") | test("429 Too Many Requests")) as $pull
    | select($pull or (.reason | IN("Evicted", "EvictionThresholdMet", "FreeDiskSpaceFailed")))
    | [$t, .metadata.uid, .metadata.namespace, .reason, (.involvedObject.kind // "-"), (.involvedObject.name // "-"),
      (if $pull then "429" else "-" end)] | @tsv' >>"$samples/events.tsv" 2>/dev/null; then
    printf '%s\tok\n' "$t" >>"$samples/event-polls.tsv"
  else
    printf '%s\tfail\n' "$t" >>"$samples/event-polls.tsv"
  fi
}

disk_sample() {
  local t=$1 root size avail low=0
  root=$(docker_ info -f '{{.DockerRootDir}}' 2>/dev/null) || root=/
  read -r size avail < <(df -B1 --output=size,avail "$root" | tail -n 1) || return 0
  if [ "$avail" -lt $((size * 15 / 100 + gib)) ]; then
    low=1
    touch "$out/disk-low"
  fi
  printf '%s\t%s\t%s\t%s\n' "$t" "$avail" "$size" "$low" >>"$samples/disk.tsv"
}

loop() {
  local tick=0 t prev_total=0 prev_idle=0 total idle busy mem
  while :; do
    t=$(date +%s)
    read -r total idle < <(awk '/^cpu / { print $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9, $5 + $6 }' /proc/stat)
    busy=-
    if [ "$prev_total" -gt 0 ] && [ "$total" -gt "$prev_total" ]; then
      busy=$(((100 * ((total - prev_total) - (idle - prev_idle))) / (total - prev_total)))
    fi
    prev_total=$total prev_idle=$idle
    mem=$(awk '/^MemAvailable:/ { a = $2 } /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
      END { printf "%s\t%s", a, st - sf }' /proc/meminfo)
    printf '%s\t%s\t%s\n' "$t" "$mem" "$busy" >>"$samples/host.tsv"
    [ $((tick % 2)) = 0 ] && docker_sample "$t"
    [ $((tick % 6)) = 0 ] && disk_sample "$t"
    if cluster_up; then
      [ $((tick % 6)) = 0 ] && pods_sample "$t"
      [ $((tick % 12)) = 0 ] && events_sample "$t"
    fi
    tick=$((tick + 1))
    sleep $((t + 5 - $(date +%s) > 0 ? t + 5 - $(date +%s) : 1))
  done
}

summary() {
  local oom kernel_log kernel_oom restarted logs429 root scenario results=$out/results.tsv results_read=true
  scenario=$(cat "$out/scenario" 2>/dev/null) || scenario=unknown
  # No results.tsv: verify-run.sh never ran to its first line, so the job cannot be said to have ended in time.
  [ -f "$results" ] || results=/dev/null results_read=false
  root=$(docker_ info -f '{{.DockerRootDir}}' 2>/dev/null) || root=/
  {
    df -h "$root"
    echo
    docker_ system df
  } >"$out/df-after.txt" 2>&1
  oom=$(docker_ ps -aq | xargs -r env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.Name}} {{.State.OOMKilled}}' 2>/dev/null |
    awk '$2 == "true" { sub(/^\//, "", $1); printf "%s%s", (n++ ? " " : ""), $1 }')
  restarted=$(docker_ ps -aq --filter label=com.docker.compose.project=svp |
    xargs -r env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.Name}} {{.RestartCount}}' 2>/dev/null |
    awk '$2 > 0 { sub(/^\//, "", $1); printf "%s%s=%s", (n++ ? " " : ""), $1, $2 }')
  # A count only: the lines name processes, and the log is public. "unknown" when dmesg needs a password (a VM).
  if kernel_log=$(sudo -n dmesg 2>/dev/null); then
    kernel_oom=$(printf '%s\n' "$kernel_log" | grep -Eci 'out of memory|oom-kill') || :
  else
    kernel_oom=unknown
  fi
  # A refused docker pull (the image builds, compose) shows only in the output of the target that ran it.
  logs429=$(grep -lsF '429 Too Many Requests' "$out"/logs/*.log | wc -l | tr -d ' ')
  if cluster_up; then
    events_sample "$(date +%s)"
    kc get events -A -o wide >"$out/events.txt" 2>&1 || :
    (cd "$repo" && timeout 120 make -s k8s-status) >"$out/k8s-status.txt" 2>&1 || :
  fi
  if [ -n "$(docker_ ps -q --filter label=com.docker.compose.project=svp)" ]; then
    (cd "$repo" && timeout 120 make -s ps) >"$out/compose-ps.txt" 2>&1 || :
  fi

  jq -n --rawfile host "$samples/host.tsv" --rawfile docker "$samples/docker.tsv" --rawfile disk "$samples/disk.tsv" \
    --rawfile pods "$samples/pods.tsv" --rawfile events "$samples/events.tsv" --rawfile polls "$samples/event-polls.tsv" \
    --rawfile results "$results" --argjson results_read "$results_read" \
    --arg scenario "$scenario" --arg oom "$oom" --arg kernel_oom "$kernel_oom" --arg restarted "$restarted" \
    --argjson logs429 "$logs429" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    def num: if . == "-" or . == null then null else tonumber end;
    # from_first(f): the rows from the first one where f holds, [] when none does.
    def from_first(f): . as $a | ([range(0; length) | select($a[.] | f)] | first) as $i | if $i then $a[$i:] else [] end;
    (rows($host)) as $h | (rows($docker)) as $d | (rows($disk)) as $k | (rows($pods)) as $p |
    (rows($events) | unique_by(.[1])) as $e | (rows($polls)) as $q |
    ($d | from_first(.[7] == "running")) as $up |
    ($d | from_first(.[6] == "0")) as $ready |
    {
      scenario: $scenario,
      samples: {host: ($h | length), docker: ($d | length), disk: ($k | length), pods: ($p | length)},
      mem_available_min_mib: ($h | map(.[1] | num) | min | if . then (. / 1024 | floor) else null end),
      swap_used_max_mib: ($h | map(.[2] | num) | max | if . then (. / 1024 | floor) else null end),
      cpu_busy_max_pct: ($h | map(.[3] | num) | map(select(. != null)) | max),
      k3d_mem_usage_max_mib: ($d | map(.[1] | num) | max),
      compose_mem_usage_max_mib: ($d | map(.[2] | num) | max),
      disk_free_min_gib: ($k | map(.[1] | num) | min | if . then (. / 1073741824 * 10 | floor / 10) else null end),
      disk_low_seen: ($k | any(.[3] == "1")),
      k3d_server_seen: (($up | length) > 0),
      k3d_server_states: ($up | map(select(.[7] == "running") | [.[8], .[9]]) | unique | length),
      k3d_server_not_running_samples: ($up | map(select(.[7] != "running")) | length),
      nodes_all_ready_seen: (($ready | length) > 0),
      nodes_not_ready_samples: ($ready | map(select((.[6] | num // 0) > 0)) | length),
      nodes_unanswered_samples: ($ready | map(select(.[6] == "-")) | length),
      event_polls: {ok: ($q | map(select(.[1] == "ok")) | length), failed: ($q | map(select(.[1] == "fail")) | length)},
      evictions: ($e | map(select(.[3] | IN("Evicted", "EvictionThresholdMet", "FreeDiskSpaceFailed"))) | length),
      eviction_reasons: ($e | map(select(.[3] | IN("Evicted", "EvictionThresholdMet", "FreeDiskSpaceFailed")) | .[3])
        | group_by(.) | map({key: .[0], value: length}) | from_entries),
      image_pulls_429: ($e | map(select(.[6] == "429")) | length),
      target_outputs_with_429: $logs429,
      container_memory_max_mib: ($p | group_by(.[1] + "/" + .[3])
        | map(max_by(.[5] | tonumber? // 0) | {key: (.[1] + "/" + .[3]),
          value: {mib: (.[5] | tonumber? // null), pod: .[2], at: (.[0] | tonumber | todate)}}) | from_entries),
      oom_killed: ($oom | split(" ") | map(select(length > 0))),
      kernel_oom_lines: $kernel_oom,
      compose_restarts: ($restarted | split(" ") | map(select(length > 0))),
      results_read: $results_read,
      # A target stopped by its own limit or by the deadline, one cancelled when the step ended, one never started
      # for the deadline: each means the scenario did not fit the time of the job.
      targets_cut: (rows($results) | .[1:] | map(select(.[2] == "timeout" or .[2] == "cancelled"
        or (.[2] == "skipped" and .[7] == "deadline")) | "\(.[1])=\(.[2])"))
    } | .runner_enough = ({
      within_deadline: (.results_read and (.targets_cut | length) == 0),
      mem_available_2gib: ((.mem_available_min_mib // 0) >= 2048),
      no_oom: ((.oom_killed | length) == 0 and .kernel_oom_lines == "0"),
      disk: (.disk_low_seen | not)
    } + if $scenario == "compose-obs" then {
      compose_no_restart: ((.compose_restarts | length) == 0)
    } elif $scenario == "dev-k3d" then {
      k3d_server_kept: (.k3d_server_seen and .k3d_server_states == 1 and .k3d_server_not_running_samples == 0),
      k3d_nodes_ready: (.nodes_all_ready_seen and .nodes_not_ready_samples == 0 and .nodes_unanswered_samples == 0),
      k3d_no_eviction: (.event_polls.ok > 0 and .evictions == 0)
    } else {} end)' >"$out/runner.json" || { echo "verify-sample: summary not written" >&2; return 1; }
  jq -r '"runner (\(.scenario)): MemAvailable min \(.mem_available_min_mib) MiB, swap max \(.swap_used_max_mib) MiB, CPU busy max \(.cpu_busy_max_pct)%",
    "runner: disk free min \(.disk_free_min_gib) GiB (low seen: \(.disk_low_seen)), k3d MEM USAGE max \(.k3d_mem_usage_max_mib) MiB, compose \(.compose_mem_usage_max_mib) MiB",
    "runner: OOMKilled [\(.oom_killed | join(" "))], kernel OOM lines \(.kernel_oom_lines), compose restarts [\(.compose_restarts | join(" "))]",
    "runner: k3s server states \(.k3d_server_states), samples with it not running \(.k3d_server_not_running_samples); nodes not Ready in \(.nodes_not_ready_samples) sample(s), not answering in \(.nodes_unanswered_samples)",
    "runner: events read \(.event_polls.ok) time(s) (\(.event_polls.failed) failed), evictions \(.evictions), pulls refused 429 \(.image_pulls_429), target outputs with a 429 \(.target_outputs_with_429)",
    "runner: results.tsv read \(.results_read), targets cut short [\(.targets_cut | join(" "))]",
    "runner enough: " + (.runner_enough | to_entries | map("\(.key)=\(.value)") | join(" "))' "$out/runner.json" |
    tee "$out/runner.txt"
}

case ${1:-} in
  start)
    running && fail "a sampler already runs (pid $pid)"
    mkdir -p "$samples"
    for f in host docker pods disk events event-polls; do : >"$samples/$f.tsv"; done
    {
      echo "kernel: $(uname -r)  cpus: $(nproc)"
      free -m
      echo "swap:"
      swapon --show 2>&1 || :
    } >"$out/host-start.txt"
    cat "$out/host-start.txt"
    setsid bash "$0" loop </dev/null >>"$samples/sampler.err" 2>&1 &
    echo $! >"$pidfile"
    echo "sampler started (pid $!)"
    ;;
  loop)
    loop
    ;;
  stop)
    if running; then
      kill "$pid" 2>/dev/null || :
      for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 1; done
      echo "sampler stopped (pid $pid)"
    else
      echo "no sampler running"
    fi
    [ -d "$samples" ] || fail "no samples in $samples: verify-sample.sh start never ran"
    summary
    ;;
  *)
    fail "usage: verify-sample.sh start|stop"
    ;;
esac
