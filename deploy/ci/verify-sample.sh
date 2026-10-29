#!/usr/bin/env bash
# Samples the machine of a verification run in the background, so a red run can be told apart from a runner that ran
# short of disk, RAM or CPU. Linux only (/proc, GNU df, setsid).
#
#   verify-sample.sh start   records free -m, swapon --show, nproc and the kernel in host-start.txt, then starts the
#                            sampler (this script's internal loop mode) detached, its pid in
#                            $SVP_VERIFY_OUT/sampler.pid; refuses to start a second one
#   verify-sample.sh stop    stops the process of that pid (only when its command line is this script's loop), then
#                            writes the summary below and prints runner.txt
#   verify-sample.sh peak START END [LABEL]
#                            ram-peak.json and ram-peak.txt (ram-peak-LABEL.* with a LABEL of a-z, 0-9 and -: a
#                            scenario that runs the drill twice) from the docker.tsv samples between START and END
#                            (seconds since the epoch; deploy/ci/verify-run.sh gives the start and end of the
#                            drill-k8s-keda right before): the highest median of 6 samples in a row that each saw 2
#                            workers transcoding (the cluster's peak), with the same median of MEM USAGE minus
#                            active_file, the longest run of such samples, and the highest sample; also on macOS (awk
#                            and jq only)
#   verify-sample.sh s3-peak START END
#                            ram-s3-upload.json and ram-s3-upload.txt from the compose.tsv samples of container svp-s3-1
#                            (the object store) between START and END (deploy/ci/verify-run.sh gives the start and end
#                            of measure-upload, a ~100 MB upload from the browser): its highest sample, when it was
#                            taken, and the last sample before START (the store before the upload); exits 1 when no
#                            sample of the window saw the container, or the highest is not under its 512 MiB
#                            mem_limit; also on macOS (awk and jq only)
#                            Both wait first, while the sampler runs, for its first docker.tsv sample after END (60 s at
#                            most; a line saying so when none came): a sample is timed when it starts and written once
#                            docker stats and the cluster answered, seconds later, so the samples of the window's last
#                            seconds may still be on their way when the target that END closes has ended. The loop
#                            writes compose.tsv before docker.tsv in each sample and samples one after the other, so a
#                            docker.tsv line after END means every sample up to END is written.
#   verify-sample.sh sample  takes one docker.tsv, compose.tsv, restarts.tsv and k6.tsv sample now, as the loop does
#                            every 10 s (deploy/ci/verify-collect-test.sh runs it with a fake docker, kubectl and pgrep;
#                            deploy/ci/verify-run.sh just before it removes the compose containers)
#
# Samples, in $SVP_VERIFY_OUT/samples/ (one line each, seconds since the epoch first):
#   host.tsv         every 5 s   MemAvailable (KiB), swap in use (KiB), CPU busy % since the line before (/proc/stat;
#                                iowait counted idle)
#   docker.tsv       every 10 s  MEM USAGE of docker stats --no-stream summed over the k3d containers (k3d-svp-*, the
#                                registry included, as the cluster's RAM budget counts it) and over the compose
#                                containers (svp-*), in MiB; CPU % of k3d-svp-server-0 and k3d-svp-agent-0; the Running
#                                media-worker pods and the nodes not Ready ("-" when the API did not answer, or without
#                                a cluster); the state of container k3d-svp-server-0 (running or stopped), its
#                                RestartCount and StartedAt ("-" without it); the Running media-worker pods that
#                                transcode now, that is run an ffmpeg process (below); anon, active_file and kernel of
#                                memory.stat summed over the two k3d nodes, in MiB ("-" unless both were read)
#   compose.tsv      every 10 s  MEM USAGE of each compose container (svp-*) in MiB, from the same docker stats as
#                                docker.tsv: container name, MiB as docker stats gives it, not rounded (one line per
#                                container; the object store's peak during an upload is read from it and compared
#                                with its limit, so 511.6 MiB must not read as 512)
#   restarts.tsv     every 10 s  RestartCount of each container of compose project svp, running or not: container
#                                name, its creation time (which tells a container made anew under the same name from
#                                the one before it), RestartCount
#   pods.tsv         every 30 s  kubectl top pods --containers of namespaces svp, svp-data, cnpg-system and svp-obs:
#                                namespace, pod, container, CPU in millicores, working set in MiB (the web pods, the
#                                Postgres pods with the Barman Cloud sidecar, the plugin itself: what the web's resources
#                                and the plugin's 256 Mi limit are set from; Tempo, the Collector, Prometheus and Loki
#                                under load: what their memory limits are set from)
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
#   k6.tsv           every 10 s  for each pod of namespace svp-load (the k6 Job of deploy/k6/cloud/run.sh) that runs a
#                                k6 process now: pod UID, nr_periods and nr_throttled of cpu.stat (counters since the
#                                container started) of the cgroup that process is in, the k6 container of the pod, where
#                                its CPU limit is enforced, and the quota of that cgroup's cpu.max ("max": no CPU limit,
#                                so the kernel never throttles it and both counters stay 0; "-" when not read); found
#                                like the workers' ffmpeg (below), read on the runner under /sys/fs/cgroup
# The summary: runner.json and runner.txt (lowest MemAvailable, highest swap and CPU, lowest free disk, containers
# OOMKilled, OOM lines of the kernel, compose containers that restarted (from restarts.tsv and a last reading: every
# container the samples saw, also one removed since, as make down and a drill that recreates a service do; a new
# container starts again at 0), nodes not Ready or not answering, a k3s
# server restart or stop, the events above and the target outputs that mention a 429, the highest working set of each
# container sampled in pods.tsv, the targets the deadline cut (results.tsv of deploy/ci/verify-run.sh: timeout,
# cancelled, or skipped for the deadline), whether verify-run.sh reached its end (its run-end mark), and the criteria of the table "runner đủ" for the scenario of
# $SVP_VERIFY_OUT/scenario), df-after.txt, and while the cluster runs make k8s-status and kubectl get events -A
# (k8s-status.txt, events.txt), or while compose runs make ps (compose-ps.txt). Only numbers, states and names reach
# the log: never an event's text, never a service's log. runner.json also has the highest MEM USAGE of each compose
# container sampled in compose.tsv.
#
# Workers transcoding: media-worker starts ffmpeg for each transcode and for nothing else, and the runner's kernel shows
# every process of the k3d nodes' containers, each in the cgroup of its pod (".../pod<uid>/<container>" with the
# cgroupfs driver of k3s, "...-pod<uid with _>.slice" with systemd's). So a sample counts the Running media-worker
# pods whose UID is in the cgroup of an ffmpeg process at that instant: two pods Running while only one transcodes
# (the other waits for a partition) count 1, and the ffmpeg runs on the runner itself (the drills make their test
# videos so) have no pod in their cgroup. Not kubectl top: its CPU is an average over the last scrape of
# metrics-server, so it lags the start and end of a transcode by up to a scrape, which is a sample or two of the
# 6 in a row the peak needs, and it needs a threshold of its own.
#
# The criteria of the k3d scenarios beyond those of every scenario:
#   every k3d scenario       k3d_server_kept, k3d_nodes_ready, k3d_no_eviction (below)
#   gitops                   gitops_keda_two_transcoding: each drill-k8s-keda-<n> that ran (results.tsv: not skipped)
#                            had at least 6 docker.tsv samples in a row with 2 workers transcoding within its own start
#                            and end; "unmeasured" when none ran
#   k6-cloud-mini, chaos     k6_cpu_throttle_5pct: in each window of $SVP_VERIFY_OUT/k6-windows.tsv, no k6 pod had more
#                            than 5% of its CPU periods throttled (the growth of nr_throttled over that of nr_periods,
#                            from its first to its last k6.tsv sample in the window, compared as counts, never as a
#                            rounded share; a pod with no period in the window, as one without a CPU limit, had none
#                            throttled). false when a pod measured is over 5%; otherwise "unmeasured" when the file is
#                            missing or empty, has a line not of the format below, or a window is not measured: a pod
#                            seen in it has a single sample there (it ended or started within the window, so part of
#                            its load went unseen), or fewer pods have two samples there than the window's pods. k6
#                            short of CPU drops iterations by itself, which says nothing of the system under load
# The windows file is written by the scenario's k6 step, one line per window whose load counts (k6-cloud-mini: the
# hold of each level it counts; chaos: the hold under the experiments): label (a-z, 0-9, -), start, end, in seconds
# since the epoch, and the number of k6 pods the step ran in it (1 or more), tab separated. runner.json lists each
# window with its pods seen and measured, those without a CPU limit, and the highest throttled share, rounded up to
# 0.01% so that a share over 5% never reads as 5.
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
# Where ffmpeg_pods and k6_sample read the processes' cgroups, and where k6_sample reads a cgroup's cpu.stat;
# deploy/ci/verify-collect-test.sh points them at fixtures.
proc=${SVP_VERIFY_PROC:-/proc}
cgroup_root=${SVP_VERIFY_CGROUP:-/sys/fs/cgroup}
pod_uid_re='pod\([0-9a-f]\{8\}[-_][0-9a-f]\{4\}[-_][0-9a-f]\{4\}[-_][0-9a-f]\{4\}[-_][0-9a-f]\{12\}\)'

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

# ffmpeg_pods: the UIDs of the pods that run an ffmpeg process now, one per line (see "Workers transcoding" above).
ffmpeg_pods() {
  local pid
  for pid in $(pgrep -x ffmpeg); do
    sed -n "s/.*$pod_uid_re.*/\\1/p" "$proc/$pid/cgroup" 2>/dev/null
  done | tr _ - | sort -u
}

# k6_sample T: one k6.tsv line per pod of namespace svp-load that runs a k6 process now (see k6.tsv above).
k6_sample() {
  local t=$1 pids uids pid path uid stat quota
  pids=$(pgrep -x k6) || return 0
  uids=$(kc -n svp-load get pods -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null) || return 0
  [ -n "$uids" ] || return 0
  for pid in $pids; do
    # cgroup v2: one line "0::<path>", the path from the root of the runner's hierarchy.
    path=$(sed -n 's/^0:://p' "$proc/$pid/cgroup" 2>/dev/null)
    uid=$(printf '%s\n' "$path" | sed -n "s/.*$pod_uid_re.*/\\1/p" | tr _ -)
    [ -n "$uid" ] && printf '%s\n' "$uids" | grep -qxF -- "$uid" || continue
    stat=$(awk '$1 == "nr_periods" { p = $2 } $1 == "nr_throttled" { n = $2 } END { if (p != "" && n != "") print p "\t" n }' \
      "$cgroup_root$path/cpu.stat" 2>/dev/null) || continue
    # cpu.max: "<quota> <period>", the quota "max" without a CPU limit.
    quota=$(awk '{ print $1; exit }' "$cgroup_root$path/cpu.max" 2>/dev/null)
    [ -n "$stat" ] && printf '%s\t%s\t%s\t%s\n' "$t" "$uid" "$stat" "${quota:--}"
  done | sort -u -t "$(printf '\t')" -k 2,2 >>"$samples/k6.tsv"
}

# node_memstat: anon, active_file and kernel of memory.stat summed over the two k3d nodes, in MiB, tab separated;
# "-" three times unless both nodes were read.
node_memstat() {
  local node
  for node in k3d-svp-server-0 k3d-svp-agent-0; do
    docker_ exec "$node" cat /sys/fs/cgroup/memory.stat 2>/dev/null || echo "unread 0"
  done | awk '$1 == "unread" { bad = 1 } $1 == "anon" { a += $2; n++ } $1 == "active_file" { f += $2 }
    $1 == "kernel" { k += $2 }
    END { if (bad || n != 2) print "-\t-\t-"; else printf "%.0f\t%.0f\t%.0f\n", a / 1048576, f / 1048576, k / 1048576 }'
}

# restarts_sample T: one restarts.tsv line per container of compose project svp (see restarts.tsv above).
restarts_sample() {
  docker_ ps -aq --filter label=com.docker.compose.project=svp 2>/dev/null |
    xargs -r env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.Name}} {{.Created}} {{.RestartCount}}' 2>/dev/null |
    awk -v t="$1" -v OFS='\t' '{ sub(/^\//, "", $1); print t, $1, $2, $3 }' >>"$samples/restarts.tsv"
}

docker_sample() {
  local t=$1 stats server agent workers=- notready=- transcoding=- memstat=$'-\t-\t-' nodes state uids
  stats=$(docker_ stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null) || stats=
  read -r k3d_mib compose_mib server agent < <(printf '%s\n' "$stats" | awk -F '\t' "$awk_mem"'
    { split($3, m, " / "); v = mib(m[1]); cpu = $2; sub(/%$/, "", cpu) }
    $1 ~ /^k3d-svp-/ { k += v } $1 ~ /^svp-/ { c += v }
    $1 == "k3d-svp-server-0" { s = cpu } $1 == "k3d-svp-agent-0" { a = cpu }
    END { printf "%.0f %.0f %s %s\n", k, c, (s == "" ? "-" : s), (a == "" ? "-" : a) }')
  printf '%s\n' "$stats" | awk -F '\t' -v t="$t" "$awk_mem"'
    $1 ~ /^svp-/ { split($3, m, " / "); printf "%s\t%s\t%.6g\n", t, $1, mib(m[1]) }' >>"$samples/compose.tsv"
  restarts_sample "$t"
  # The server's state also once it stopped: a server that went away must show in the samples, not drop out of them.
  state=$(docker_ inspect -f '{{if .State.Running}}running{{else}}stopped{{end}} {{.RestartCount}} {{.State.StartedAt}}' \
    k3d-svp-server-0 2>/dev/null) || state="- - -"
  if [ "${state%% *}" = running ]; then
    if uids=$(kc -n svp get pods -l "$worker_selector" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null); then
      workers=$(printf '%s' "$uids" | grep -c .)
      transcoding=0
      [ "$workers" -gt 0 ] && transcoding=$(ffmpeg_pods | grep -cxF -f <(printf '%s\n' "$uids"))
    fi
    if nodes=$(kc get nodes --no-headers 2>/dev/null) && [ -n "$nodes" ]; then
      # Only the first field of STATUS: a cordoned node shows "Ready,SchedulingDisabled" and is still Ready (make
      # drill-k8s-pdb cordons every node for a while), while "NotReady,SchedulingDisabled" is not.
      notready=$(printf '%s\n' "$nodes" | awk '{ split($2, s, ",") } s[1] != "Ready"' | wc -l | tr -d ' ')
    fi
    memstat=$(node_memstat)
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$k3d_mib" "$compose_mib" "$server" "$agent" "$workers" \
    "$notready" "${state// /$'\t'}" "$transcoding" "$memstat" >>"$samples/docker.tsv"
}

pods_sample() {
  local t=$1
  # kubectl top prints CPU as <n>m and memory as <n>Mi.
  kc top pods -A --containers --no-headers 2>/dev/null | awk -v t="$t" -v OFS='\t' '
    $1 == "svp" || $1 == "svp-data" || $1 == "cnpg-system" || $1 == "svp-obs" {
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
      [ $((tick % 2)) = 0 ] && k6_sample "$t"
      [ $((tick % 6)) = 0 ] && pods_sample "$t"
      [ $((tick % 12)) = 0 ] && events_sample "$t"
    fi
    tick=$((tick + 1))
    sleep $((t + 5 - $(date +%s) > 0 ? t + 5 - $(date +%s) : 1))
  done
}

summary() {
  local oom kernel_log kernel_oom restarted logs429 root scenario results=$out/results.tsv results_read=true
  local run_ended=true
  scenario=$(cat "$out/scenario" 2>/dev/null) || scenario=unknown
  # No results.tsv: verify-run.sh never ran to its first line, so the job cannot be said to have ended in time.
  [ -f "$results" ] || results=/dev/null results_read=false
  # No run-end: verify-run.sh was stopped before its last target had its line (a cancelled run, a step stopped by its
  # timeout-minutes). It writes the cancelled line only after the target it stops has exited, which the runner may not
  # wait for, so results.tsv alone can look complete with the running target and every later one missing.
  [ -f "$out/run-end" ] || run_ended=false
  root=$(docker_ info -f '{{.DockerRootDir}}' 2>/dev/null) || root=/
  {
    df -h "$root"
    echo
    docker_ system df
  } >"$out/df-after.txt" 2>&1
  oom=$(docker_ ps -aq | xargs -r env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.Name}} {{.State.OOMKilled}}' 2>/dev/null |
    awk '$2 == "true" { sub(/^\//, "", $1); printf "%s%s", (n++ ? " " : ""), $1 }')
  # The highest count of each container (name and creation time), summed by name.
  restarts_sample "$(date +%s)"
  restarted=$(awk -F '\t' '{ k = $2 "\t" $3; if ($4 + 0 > m[k] + 0) m[k] = $4 + 0 }
    END { for (k in m) { split(k, a, "\t"); c[a[1]] += m[k] } for (x in c) if (c[x] > 0) print x "=" c[x] }' \
    "$samples/restarts.tsv" | sort | paste -sd ' ' -)
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
    --rawfile pods "$samples/pods.tsv" --rawfile compose "$samples/compose.tsv" --rawfile events "$samples/events.tsv" \
    --rawfile polls "$samples/event-polls.tsv" --rawfile k6 <(cat "$samples/k6.tsv" 2>/dev/null) \
    --rawfile windows <(cat "$out/k6-windows.tsv" 2>/dev/null) --rawfile results "$results" \
    --argjson results_read "$results_read" --argjson run_ended "$run_ended" \
    --arg scenario "$scenario" --arg oom "$oom" --arg kernel_oom "$kernel_oom" --arg restarted "$restarted" \
    --argjson logs429 "$logs429" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    def num: if . == "-" or . == null then null else tonumber end;
    # from_first(f): the rows from the first one where f holds, [] when none does.
    def from_first(f): . as $a | ([range(0; length) | select($a[.] | f)] | first) as $i | if $i then $a[$i:] else [] end;
    (rows($host)) as $h | (rows($docker)) as $d | (rows($disk)) as $k | (rows($pods)) as $p | (rows($compose)) as $c |
    (rows($events) | unique_by(.[1])) as $e | (rows($polls)) as $q |
    def at($a; $b): map(select((.[0] | tonumber) >= $a and (.[0] | tonumber) <= $b));
    # The longest run of docker.tsv rows in a row that saw 2 workers transcoding.
    def longest_two: reduce .[] as $x ({n: 0, best: 0};
      if ($x[10] // "-") == "2" then .n += 1 | .best = ([.best, .n] | max) else .n = 0 end) | .best;
    def window_line: length == 4 and (.[0] | test("^[a-z0-9-]+$")) and (.[1] | test("^[0-9]+$"))
      and (.[2] | test("^[0-9]+$")) and (.[3] | test("^[1-9][0-9]*$"));
    (rows($windows) | map(select(window_line)
      | {label: .[0], from: (.[1] | tonumber), to: (.[2] | tonumber), pods: (.[3] | tonumber)})) as $win |
    (rows($windows) | map(select(window_line | not)) | length) as $win_bad |
    (rows($k6) | map(select(length == 5 and all(.[0], .[2], .[3]; test("^[0-9]+$"))))) as $k6rows |
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
      compose_container_memory_max_mib: ($c | group_by(.[1]) | map(max_by(.[2] | tonumber) | {key: .[1],
        value: {mib: (.[2] | tonumber), at: (.[0] | tonumber | todate)}}) | from_entries),
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
      run_ended: $run_ended,
      # Each drill-k8s-keda that ran, with the longest run of samples within its own start and end that saw 2 workers
      # transcoding.
      keda_runs: (rows($results) | .[1:] | map(select((.[1] | test("^drill-k8s-keda(-[0-9]+)?$")) and .[2] != "skipped")
        | (.[4] | tonumber) as $a | (.[5] | tonumber) as $b
        | {name: .[1], from: ($a | todate), to: ($b | todate), longest_run_with_2_transcoding: ($d | at($a; $b) | longest_two)})),
      # Each window of k6-windows.tsv: per pod with two samples in the window, the growth of nr_throttled over that of
      # nr_periods between its first and last one; the window is measured when every pod seen in it has two samples
      # and they are at least the pods the window ran.
      k6_windows: ($win | map(. as $w | ($k6rows | at($w.from; $w.to) | group_by(.[1])
        | map(sort_by(.[0] | tonumber) | {samples: length, no_limit: all(.[]; .[4] == "max"),
          periods: ((.[-1][2] | tonumber) - (.[0][2] | tonumber)),
          throttled: ((.[-1][3] | tonumber) - (.[0][3] | tonumber))})) as $seen
        | ($seen | map(select(.samples >= 2))) as $m
        | {label: $w.label, from: ($w.from | todate), to: ($w.to | todate), pods: $w.pods,
          pods_seen: ($seen | length), pods_measured: ($m | length),
          pods_without_cpu_limit: ($m | map(select(.no_limit)) | length),
          throttled_pct_max: ($m | map(if .periods > 0 then .throttled * 10000 / .periods | ceil / 100 else 0 end) | max),
          over_5pct: any($m[]; .throttled * 20 > .periods)}
        | .measured = (.pods_seen == .pods_measured and .pods_measured >= .pods))),
      k6_windows_malformed_lines: $win_bad,
      # A target stopped by its own limit or by the deadline, one cancelled when the step ended, one never started
      # for the deadline: each means the scenario did not fit the time of the job.
      targets_cut: (rows($results) | .[1:] | map(select(.[2] == "timeout" or .[2] == "cancelled"
        or (.[2] == "skipped" and .[7] == "deadline")) | "\(.[1])=\(.[2])"))
    } | .runner_enough = ({
      within_deadline: (.results_read and .run_ended and (.targets_cut | length) == 0),
      mem_available_2gib: ((.mem_available_min_mib // 0) >= 2048),
      no_oom: ((.oom_killed | length) == 0 and .kernel_oom_lines == "0"),
      disk: (.disk_low_seen | not)
    } + if $scenario == "compose-obs" then {
      compose_no_restart: ((.compose_restarts | length) == 0)
    } elif $scenario | IN("dev-k3d", "gitops", "web-canary", "k6-cloud-mini", "chaos", "velero") then {
      k3d_server_kept: (.k3d_server_seen and .k3d_server_states == 1 and .k3d_server_not_running_samples == 0),
      k3d_nodes_ready: (.nodes_all_ready_seen and .nodes_not_ready_samples == 0 and .nodes_unanswered_samples == 0),
      k3d_no_eviction: (.event_polls.ok > 0 and .evictions == 0)
    } else {} end + if $scenario == "gitops" then {
      gitops_keda_two_transcoding: (if (.keda_runs | length) == 0 then "unmeasured"
        else all(.keda_runs[]; .longest_run_with_2_transcoding >= 6) end)
    } else {} end + if $scenario | IN("k6-cloud-mini", "chaos") then {
      k6_cpu_throttle_5pct: (if any(.k6_windows[]; .over_5pct) then false
        elif (.k6_windows | length) == 0 or .k6_windows_malformed_lines > 0 or any(.k6_windows[]; .measured | not)
        then "unmeasured" else true end)
    } else {} end)' >"$out/runner.json" || { echo "verify-sample: summary not written" >&2; return 1; }
  jq -r '"runner (\(.scenario)): MemAvailable min \(.mem_available_min_mib) MiB, swap max \(.swap_used_max_mib) MiB, CPU busy max \(.cpu_busy_max_pct)%",
    "runner: disk free min \(.disk_free_min_gib) GiB (low seen: \(.disk_low_seen)), k3d MEM USAGE max \(.k3d_mem_usage_max_mib) MiB, compose \(.compose_mem_usage_max_mib) MiB",
    "runner: OOMKilled [\(.oom_killed | join(" "))], kernel OOM lines \(.kernel_oom_lines), compose restarts [\(.compose_restarts | join(" "))]",
    "runner: k3s server states \(.k3d_server_states), samples with it not running \(.k3d_server_not_running_samples); nodes not Ready in \(.nodes_not_ready_samples) sample(s), not answering in \(.nodes_unanswered_samples)",
    "runner: events read \(.event_polls.ok) time(s) (\(.event_polls.failed) failed), evictions \(.evictions), pulls refused 429 \(.image_pulls_429), target outputs with a 429 \(.target_outputs_with_429)",
    "runner: results.tsv read \(.results_read), verify-run.sh reached its end \(.run_ended), targets cut short [\(.targets_cut | join(" "))]",
    (if (.keda_runs | length) > 0 then "runner: drill-k8s-keda, longest run of samples with 2 workers transcoding: " +
      (.keda_runs | map("\(.name)=\(.longest_run_with_2_transcoding)") | join(" ")) else empty end),
    (if (.k6_windows | length) > 0 then "runner: k6 windows, highest share of CPU periods throttled in a pod: " +
      (.k6_windows | map("\(.label)=\(if .pods_measured > 0 then "\(.throttled_pct_max)%" else "-" end)" +
        "\(if .measured then "" else " unmeasured" end) (\(.pods_measured) of \(.pods) pod(s) measured, \(.pods_seen) seen," +
        " \(.pods_without_cpu_limit) without a CPU limit)") | join(" ")) else empty end),
    (if .k6_windows_malformed_lines > 0 then "runner: k6-windows.tsv, lines not label, start, end, pods: \(.k6_windows_malformed_lines)"
      else empty end),
    "runner enough: " + (.runner_enough | to_entries | map("\(.key)=\(.value)") | join(" "))' "$out/runner.json" |
    tee "$out/runner.txt"
}

# await_sample_after END: see "Both wait first" under s3-peak in the header.
await_sample_after() {
  local deadline=$(($(date +%s) + 60))
  running || return 0
  until awk -F '\t' -v e="$1" '$1 > e { found = 1; exit } END { exit !found }' "$samples/docker.tsv" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ] || ! running; then
      echo "verify-sample: no sample after the window's end within 60 s; its last seconds may lack a sample"
      return 0
    fi
    sleep 2
  done
}

# peak START END [LABEL]: see verify-sample.sh peak in the header.
peak() {
  local file=$out/ram-peak${3:+-$3}
  case $1$2 in '' | *[!0-9]*) fail "usage: verify-sample.sh peak START END [LABEL] (seconds since the epoch)" ;; esac
  [ -n "$1" ] && [ -n "$2" ] || fail "usage: verify-sample.sh peak START END [LABEL] (seconds since the epoch)"
  case ${3-x} in '' | *[!a-z0-9-]*) fail "verify-sample.sh peak: LABEL holds a-z, 0-9 and - only" ;; esac
  await_sample_after "$2"
  awk -F '\t' -v a="$1" -v b="$2" '$1 >= a && $1 <= b' "$samples/docker.tsv" |
    jq -R -s --argjson start "$1" --argjson end "$2" '
    def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor]
      else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    def num: if . == "-" or . == null then null else tonumber end;
    def time: if . == null then null else todate end;
    split("\n") | map(select(length > 0) | split("\t") | {t: (.[0] | tonumber), mib: (.[1] | tonumber),
      running: .[5], transcoding: (.[10] // "-"), active_file: (.[12] | num)}) as $r |
    # Every 6 samples in a row that each saw 2 workers transcoding; MEM USAGE minus active_file only when every one of
    # the 6 read memory.stat of both nodes.
    [range(0; ($r | length) - 5) | $r[.:. + 6] | select(all(.transcoding == "2")) | {from: .[0].t,
      median: (map(.mib) | median),
      minus_active_file: (if all(.active_file != null) then (map(.mib - .active_file) | median) else null end)}] as $w |
    ($w | max_by(.median)) as $p |
    ($r | reduce .[] as $x ({n: 0, from: null, best: 0, best_from: null, best_to: null};
      if $x.transcoding == "2" then .n += 1 | (if .n == 1 then .from = $x.t else . end)
        | (if .n > .best then .best = .n | .best_from = .from | .best_to = $x.t else . end)
      else .n = 0 end)) as $run |
    {
      window: {start: ($start | todate), end: ($end | todate)}, samples: ($r | length),
      samples_with_2_running: ($r | map(select(.running == "2")) | length),
      samples_with_2_transcoding: ($r | map(select(.transcoding == "2")) | length),
      longest_run_with_2_transcoding: {samples: $run.best, from: ($run.best_from | time), to: ($run.best_to | time)},
      windows_of_6_with_2_transcoding: ($w | length),
      peak_median_of_6_mib: $p.median, peak_window_from: ($p.from | time),
      peak_median_of_6_minus_active_file_mib: $p.minus_active_file,
      highest_sample_mib: ($r | map(.mib) | max),
      highest_sample_with_2_transcoding_mib: ($r | map(select(.transcoding == "2") | .mib) | max),
      peak_within_8_7_gib: (if $p == null then null else $p.median < 8.7 * 1024 end),
      note: "transcoding counts the Running media-worker pods with an ffmpeg process in their cgroup at each sample (deploy/ci/verify-sample.sh); active_file is that of both k3d nodes"
    }' >"$file.json" || return 1
  jq -r '"RAM peak during drill-k8s-keda: median of 6 with 2 workers transcoding \(.peak_median_of_6_mib) MiB (\(.windows_of_6_with_2_transcoding) window(s), longest run \(.longest_run_with_2_transcoding.samples) samples), minus active_file \(.peak_median_of_6_minus_active_file_mib) MiB, highest sample \(.highest_sample_mib) MiB, within 8.7 GiB: \(.peak_within_8_7_gib)"' \
    "$file.json" | tee "$file.txt"
}

# s3_peak START END: see verify-sample.sh s3-peak in the header.
s3_peak() {
  local file=$out/ram-s3-upload limit=512
  case $1$2 in '' | *[!0-9]*) fail "usage: verify-sample.sh s3-peak START END (seconds since the epoch)" ;; esac
  [ -n "$1" ] && [ -n "$2" ] || fail "usage: verify-sample.sh s3-peak START END (seconds since the epoch)"
  await_sample_after "$2"
  awk -F '\t' '$2 == "svp-s3-1"' "$samples/compose.tsv" |
    jq -R -s --argjson start "$1" --argjson end "$2" --argjson limit "$limit" '
    split("\n") | map(select(length > 0) | split("\t") | {t: (.[0] | tonumber), mib: (.[2] | tonumber)}) as $all |
    ($all | map(select(.t >= $start and .t <= $end))) as $w |
    ($w | max_by(.mib)) as $p |
    ($all | map(select(.t < $start)) | last) as $before |
    {
      container: "svp-s3-1", window: {start: ($start | todate), end: ($end | todate)}, samples: ($w | length),
      before_mib: $before.mib, before_at: (if $before then $before.t | todate else null end),
      peak_mib: $p.mib, peak_at: (if $p then $p.t | todate else null end),
      limit_mib: $limit, peak_under_limit: (if $p then $p.mib < $limit else null end),
      note: "docker stats MEM USAGE of the object store container every 10 s (deploy/ci/verify-sample.sh), over make measure-upload"
    }' >"$file.json" || return 1
  jq -r '"RAM of svp-s3-1 during measure-upload: peak \(.peak_mib) MiB at \(.peak_at) over \(.samples) sample(s), before it \(.before_mib) MiB, under the \(.limit_mib) MiB limit: \(.peak_under_limit)"' \
    "$file.json" | tee "$file.txt"
  jq -e '.peak_under_limit == true' "$file.json" >/dev/null
}

case ${1:-} in
  start)
    running && fail "a sampler already runs (pid $pid)"
    mkdir -p "$samples"
    for f in host docker compose restarts pods disk events event-polls k6; do : >"$samples/$f.tsv"; done
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
  peak)
    peak "${2:-}" "${3:-}" ${4+"$4"}
    ;;
  s3-peak)
    s3_peak "${2:-}" "${3:-}"
    ;;
  sample)
    mkdir -p "$samples"
    t=$(date +%s)
    docker_sample "$t"
    k6_sample "$t"
    ;;
  *)
    fail "usage: verify-sample.sh start|stop|peak START END [LABEL]|s3-peak START END|sample"
    ;;
esac
