#!/usr/bin/env bash
# KEDA drill on cluster svp: media-worker scales on the lag of
# group media-worker on video.lifecycle.v1 and back, and a scale-down while a job runs loses and repeats no video.
#
# Uploads at least N videos (default 9; the same generated 60 s 1080p clip, about 45 s of transcode each) through
# https://api.svp.localhost:8443, and more while their records would not cover every partition of the topic:
# video-service keys each record by its video id, and KEDA asks for at most one replica per partition with lag, so the
# maximum of 2 replicas needs records on 2 of the 3 partitions;
# on all 3, every member has records waiting, the one owning two partitions too. kafka_partition (lib.sh) predicts
# each one's partition before it is completed; the drill checks the prediction against the topic at the end. Then
# completes all of them within a second or two, so they all wait at once. A sampler records, every ~2 s, media-worker's
# desired and ready replicas, the group's lag as Redpanda reports it (rpk group describe), the value KEDA serves to its
# HPA (external metrics API), which partitions each member's address owns, and kubectl top of every worker pod; a
# watcher records when each video is READY.
#
# Scale-down while a job runs: once media-worker runs its maximum of ready replicas and each owns a partition (with 3
# partitions and 2 members, one owns two), the drill picks a pod that is transcoding (a job directory in its /work) and
# owns a partition with at least 2 records not committed, so it is still busy, with this job or the next, when it
# stops. The pod gets the lowest controller.kubernetes.io/pod-deletion-cost, so the ReplicaSet removes it first, and
# the ScaledObject is pinned one replica lower with annotation autoscaling.keda.sh/paused-replicas (KEDA's own way to
# hold a workload at a count): KEDA scales the Deployment down, the path an HPA scale-down takes too, and the pod gets
# SIGTERM. Its log must show "transcode job interrupted" (the record in hand stays uncommitted);
# the annotation is then removed and KEDA scales on the lag again. Each interrupted video must end READY like the
# others, done again by another member after the rebalance.
#
# Prints:
#   - the time from the first CompleteUpload to each count of desired and of ready replicas from 2 to the maximum;
#   - for each pod added, the time from Ready to owning a partition: the member joins the group at once, but
#     BlockRebalance holds the rebalance until every worker has finished the record in hand;
#   - the peak lag, how many of the topic's 3 partitions the records landed on, each video's time to READY (from its own
#     CompleteUpload and from the first one);
#   - the scale-down while a job ran: when, which pod and video, how long the pod took to stop, which pod did the
#     video again and when it was READY;
#   - the time from the last READY to one replica. The HPA's scale-down window of 300 s counts from the last time KEDA
#     served more than one replica (with only one partition still holding lag), which comes before the last READY, so
#     this is shorter than 300 s plus KEDA's polling, not equal to it;
#   - the peak CPU and RAM of a worker pod and the peak RAM of all of them together.
# It fails when media-worker does not reach its maximum of ready replicas with every pod owning a partition within
# 5 minutes, the pinned scale-down does not stop the chosen pod (and only it) within 90 s or the pod logs no
# interrupted job, a video is not READY within 15 minutes, any video has other than exactly one transcode.completed in
# media.transcodes.v1 and one video.ready in video.lifecycle.v1 (a scale up or down while a job ran must not transcode a
# video twice nor lose one), a record landed on another partition than predicted, or media-worker is not back at one
# replica within 10 minutes of the last READY, or the k3s server restarted while the drill ran. That last one is
# why media-worker stops at 2 replicas: with 3 workers transcoding at once the VM ran out of CPU, kine's compaction
# hit its 20 s limit and k3s exited, the API server gone for minutes. Container k3d-svp-server-0's RestartCount and
# State.StartedAt are read with docker inspect at the start and again when the drill ends, failed or not (so a run
# that failed because kubectl lost the API server still names the restart); docker not answering either time is a
# failure too.
#
# Usage (from the repo root, cluster up): make drill-k8s-keda [N=9], N from 6 to 12: below 6 the scale-down may find
# no pod with 2 records waiting (2 workers drain the queue slower than 3 did, so 6 still leaves enough when the second
# one owns a partition); 12 videos on 2 workers are 6 rounds of ~45 s, well within the 15 minutes for READY. One test
# user per 3 videos: the gateway allows a user at most 3 open upload forms. The pause annotation and the pod's deletion
# cost are removed when the drill ends, failed or not. LOCAL LAB ONLY: resets the register rate limit in the cluster's
# Valkey db 10.
set -euo pipefail

base=${1:-https://api.svp.localhost:8443}
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"

n=${N:-9}
[[ $n =~ ^[0-9]+$ ]] && ((n >= 6 && n <= 12)) || fail "N is 6 to 12 (got '$n')"
# Videos beyond N are uploaded only while the records would miss a partition; past this many the drill gives up.
max_videos=$((n + 9))
start_timeout=420
spread_timeout=300
ready_timeout=900
down_timeout=600
topic=video.lifecycle.v1
group=media-worker
selector=app.kubernetes.io/name=media-worker,app.kubernetes.io/component=server
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

sampler_pid=
watcher_pid=
follower_pid=
victim=
paused=
server_before=
server_checked=

# server_state: "RESTART_COUNT STARTED_AT" of container k3d-svp-server-0 (k3s server, API server, kine); false when
# docker cannot tell, so missing data never passes for "not restarted".
server_state() {
  local out re='^[0-9]+ [0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+$'
  out=$(docker_ inspect --format '{{.RestartCount}} {{.State.StartedAt}}' k3d-svp-server-0 2>/dev/null) || return 1
  [[ $out =~ $re && $out != *" 0001-"* ]] || return 1
  printf '%s' "$out"
}

# check_server: criterion (c), the k3s server did not restart since the drill read server_state at the start.
check_server() {
  local after
  server_checked=1
  if ! after=$(server_state); then
    echo "FAIL  k3s server not restarted during the drill: docker inspect k3d-svp-server-0 gave no RestartCount and StartedAt (before: '$server_before')" >&2
    return 1
  fi
  if [[ $after != "$server_before" ]]; then
    echo "FAIL  k3s server not restarted during the drill: container k3d-svp-server-0 RestartCount and StartedAt went from '$server_before' to '$after' (docker logs k3d-svp-server-0 shows why, e.g. kine compaction past 20 s)" >&2
    return 1
  fi
  ok "k3s server not restarted during the drill (k3d-svp-server-0: RestartCount ${after%% *}, started ${after#* })"
}

drill_exit() {
  local rc=$?
  trap - EXIT
  for pid in "$sampler_pid" "$watcher_pid" "$follower_pid"; do
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  if [[ -n $server_before && -z $server_checked ]]; then
    check_server || rc=1
  fi
  if [[ -n $paused ]] &&
    ! kc -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas- >/dev/null 2>&1; then
    echo "FAIL  remove the pause of ScaledObject svp/media-worker; run: kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas-" >&2
    rc=1
  fi
  if [[ -n $victim ]]; then
    kc -n svp annotate pod "$victim" controller.kubernetes.io/pod-deletion-cost- >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT

# worker_replicas: prints "DESIRED READY" of Deployment media-worker (0 for a missing count).
worker_replicas() {
  local out d r
  out=$(kc -n svp get deployment media-worker -o jsonpath='{.spec.replicas} {.status.readyReplicas}') || return 1
  read -r d r <<<"$out"
  printf '%s %s' "${d:-0}" "${r:-0}"
}

# group_lag: the group's TOTAL-LAG ("" while the group rebalances and describe fails).
group_lag() { rpk group describe "$group" 2>/dev/null | awk '$1 == "TOTAL-LAG" { print $2; exit }' || true; }

# worker_pods: "NAME IP" of every worker pod that is Ready and not being deleted.
worker_pods() {
  kc -n svp get pods -l "$selector" -o json | jq -r '.items[]
    | select(.metadata.deletionTimestamp == null)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | "\(.metadata.name) \(.status.podIP)"'
}

# describe_now: rpk group describe into $work/describe.now; false while the group rebalances.
describe_now() { rpk group describe "$group" >"$work/describe.now" 2>/dev/null; }

# owners_now: how many distinct member addresses own a partition of $topic in $work/describe.now.
owners_now() { awk -v tp="$topic" '$1 == tp && NF >= 9 { o[$9] = 1 } END { for (a in o) c++; print c + 0 }' "$work/describe.now"; }

# busy_pod: "POD VIDEO_ID" of a Ready worker pod with a job directory in /work (the video it transcodes) whose
# partitions of $topic hold at least 2 records not committed; nothing when none.
busy_pod() {
  local pod ip lag job
  describe_now || return 0
  while read -r pod ip; do
    lag=$(awk -v tp="$topic" -v a="$ip" '$1 == tp && NF >= 9 && $9 == a { s += $6 } END { print s + 0 }' "$work/describe.now")
    ((lag >= 2)) || continue
    job=$(kc -n svp exec "$pod" -c media-worker -- ls /work </dev/null 2>/dev/null | grep -E "$uuid_re" | head -n 1 || true)
    if [[ -n $job ]]; then
      echo "$pod $job"
      return 0
    fi
  done < <(worker_pods)
}

# stopping POD: true once worker pod POD is being deleted or is gone.
stopping() {
  local out
  out=$(kc -n svp get pod "$1" --ignore-not-found -o jsonpath='{.metadata.name} {.metadata.deletionTimestamp}') || return 1
  [[ -z $out || $out == *" "?* ]]
}

# video_name ID: the drill's name (v<i>) of the video with ID, "" when none.
video_name() {
  local i id_var
  for ((i = 1; i <= n; i++)); do
    id_var="v${i}_id"
    if [[ ${!id_var} == "$1" ]]; then
      echo "v$i"
      return 0
    fi
  done
}

# --- Preconditions -------------------------------------------------------------------------------------------------
server_before=$(server_state) ||
  fail "read RestartCount and State.StartedAt of container k3d-svp-server-0 (docker inspect), to tell a k3s restart during the drill"
[[ $(kc -n svp get scaledobject media-worker -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]] ||
  fail "ScaledObject svp/media-worker is Ready (make k8s-up installs it)"
[[ -z $(kc -n svp get scaledobject media-worker -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}') ]] ||
  fail "ScaledObject svp/media-worker is not paused (a drill stopped short? kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas-)"
metric=$(kc -n svp get hpa keda-hpa-media-worker -o jsonpath='{.spec.metrics[0].external.metric.name}') ||
  fail "read HPA svp/keda-hpa-media-worker, which KEDA makes for the ScaledObject"
[[ -n $metric ]] || fail "HPA keda-hpa-media-worker names an external metric"
partitions=$(rpk topic list | awk -v t="$topic" '$1 == t { print $2 }')
max_replicas=$(kc -n svp get scaledobject media-worker -o jsonpath='{.spec.maxReplicaCount}')
# KEDA asks for at most one replica per partition with lag (limitToPartitionsWithLag), so a maximum above the partition
# count is never reached; below it a member owns several partitions. The topic keeps 3 partitions while media-worker
# stops at 2. The scale-down pins one replica below the maximum, so the maximum is at least 2.
[[ $partitions =~ ^[0-9]+$ && $max_replicas =~ ^[0-9]+$ && $max_replicas -ge 2 && $partitions -ge $max_replicas ]] ||
  fail "topic $topic has at least as many partitions as ScaledObject media-worker's maxReplicaCount, which is at least 2 (got '$partitions' and '$max_replicas')"
ok "ScaledObject media-worker Ready, up to $max_replicas replicas; its HPA reads external metric $metric"

# A previous run (or real uploads) may still hold extra workers: they go about 5 minutes after the lag is gone.
deadline=$((SECONDS + start_timeout))
until [[ $(worker_replicas || true) == "1 1" && $(group_lag) == 0 ]]; do
  ((SECONDS < deadline)) ||
    fail "media-worker at 1 replica and group $group without lag within ${start_timeout}s (now: replicas '$(worker_replicas || true)', lag '$(group_lag)')"
  sleep 5
done
ok "media-worker at 1 replica, group $group without lag"

wait_gateway_ready 60
make_video "$work/clip.mp4" 60 1920x1080
ok "generated a 60 s 1080p test video ($(file_size "$work/clip.mp4") bytes)"
count=0
covered=
while ((count < n)) || (($(printf '%s' "$covered" | wc -c) < partitions)); do
  ((count < max_videos)) || fail "the records of $count videos cover all $partitions partitions"
  if ((count % 3 == 0)); then new_user "u$((count / 3 + 1))"; fi
  count=$((count + 1))
  create_and_upload "v$count" "$work/u$(((count - 1) / 3 + 1)).auth" "$work/clip.mp4"
  id_var="v${count}_id"
  p=$(kafka_partition "${!id_var}" "$partitions")
  printf -v "v${count}_partition" '%s' "$p"
  [[ $covered == *"$p"* ]] || covered="$covered$p"
done
if ((count > n)); then
  echo "note  $((count - n)) videos more than N=$n, so that the records cover all $partitions partitions"
fi
n=$count
ok "$n videos uploaded, none completed yet; their records will land on all $partitions partitions"

# --- Sampler -------------------------------------------------------------------------------------------------------
# samples: T DESIRED READY LAG KEDA OWNERS (OWNERS: comma-separated addresses of the members owning a partition, "-"
# for none; LAG and KEDA "-" when unknown). pods: T NAME IP READY. top: T NAME CPU_MILLICORES MEM_MIB.
: >"$work/samples"
: >"$work/pods"
: >"$work/top"
metric_path="/apis/external.metrics.k8s.io/v1beta1/namespaces/svp/$metric?labelSelector=scaledobject.keda.sh%2Fname%3Dmedia-worker"
(
  set +e
  while :; do
    t=$(now)
    reps=$(worker_replicas) || reps="- -"
    rpk group describe "$group" >"$work/describe" 2>/dev/null || : >"$work/describe"
    lag=$(awk '$1 == "TOTAL-LAG" { print $2; exit }' "$work/describe")
    owners=$(awk -v tp="$topic" '$1 == tp && NF >= 9 { print $9 }' "$work/describe" | sort -u | paste -sd, -)
    # A quantity such as "3" or "1500m".
    keda=$(kc get --raw "$metric_path" 2>/dev/null | jq -r '.items[0].value // empty' 2>/dev/null |
      awk '/m$/ { printf "%.1f", $0 / 1000; next } { print }')
    echo "$t $reps ${lag:--} ${keda:--} ${owners:--}" >>"$work/samples"
    kc -n svp get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null |
      awk -v t="$t" 'NF == 3 { print t, $0 }' >>"$work/pods"
    kc -n svp top pod -l "$selector" --no-headers 2>/dev/null |
      awk -v t="$t" '{ c = $2; m = $3; sub(/m$/, "", c); if (m ~ /Gi$/) m = m * 1024; sub(/Mi$/, "", m); print t, $1, c + 0, m + 0 }' >>"$work/top"
    sleep 1
  done
) &
sampler_pid=$!

# --- Complete all; a watcher records each READY ---------------------------------------------------------------------
for ((i = 1; i <= n; i++)); do
  complete "v$i" "$work/u$(((i - 1) / 3 + 1)).auth"
  printf -v "v${i}_completed" '%s' "$(now)"
done
t0=$v1_completed
ok "$n videos completed within $(awk -v a="$t0" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }') s"

# ready: INDEX TIME per video once READY. In the background, so that the scale-down below delays no READY time; it
# alone sends API requests meanwhile (request leaves its answer in the shared $work/body).
: >"$work/ready"
(
  left=$n
  deadline=$((SECONDS + ready_timeout))
  while ((left > 0)); do
    for ((i = 1; i <= n; i++)); do
      ! grep -q "^$i " "$work/ready" || continue
      id_var="v${i}_id"
      status=$(request GET "/videos/${!id_var}" "$work/u$(((i - 1) / 3 + 1)).auth")
      [[ $status == 200 ]] || fail "read video v$i (status $status, $(problem_summary))"
      case $(field status) in
        READY)
          echo "$i $(now)" >>"$work/ready"
          left=$((left - 1))
          ;;
        FAILED) fail "video v$i (${!id_var}) went FAILED instead of READY" ;;
      esac
    done
    ((left == 0)) && break
    ((SECONDS < deadline)) || fail "every video READY within ${ready_timeout}s ($left still not READY)"
    sleep 1
  done
) &
watcher_pid=$!

# --- Scale down while a job runs -----------------------------------------------------------------------------------
deadline=$((SECONDS + spread_timeout))
until [[ $(worker_replicas || true) == "$max_replicas $max_replicas" ]] && describe_now && (($(owners_now) == max_replicas)); do
  ((SECONDS < deadline)) ||
    fail "media-worker at $max_replicas ready replicas, each owning a partition, within ${spread_timeout}s of the first complete (now: replicas '$(worker_replicas || true)')"
  sleep 2
done
t_spread=$(now)
ok "media-worker at $max_replicas ready replicas, each owning a partition of $topic"

deadline=$((SECONDS + 60))
until busy=$(busy_pod) && [[ -n $busy ]]; do
  ((SECONDS < deadline)) || fail "a worker pod transcoding with 2 records waiting on its partition within 60s"
  sleep 2
done
read -r victim held <<<"$busy"
others=$(worker_pods | awk -v v="$victim" '$1 != v { print $1 }')
kc -n svp logs -f "$victim" -c media-worker >"$work/victim.log" 2>/dev/null &
follower_pid=$!
kc -n svp annotate pod "$victim" controller.kubernetes.io/pod-deletion-cost=-1000 --overwrite >/dev/null ||
  fail "give pod $victim the lowest deletion cost"
pin=$((max_replicas - 1))
kc -n svp annotate scaledobject media-worker "autoscaling.keda.sh/paused-replicas=$pin" --overwrite >/dev/null ||
  fail "pin ScaledObject media-worker at $pin replicas"
paused=1
t_pause=$(now)
pause_second=$(date -u +%Y-%m-%dT%H:%M:%S)
ok "pod $victim transcodes $(video_name "$held") ($held): media-worker pinned at $pin replicas"

deadline=$((SECONDS + 90))
until stopping "$victim"; do
  ((SECONDS < deadline)) ||
    fail "pod $victim stopping within 90s of pinning media-worker at $pin replicas (kubectl --context k3d-svp -n svp describe scaledobject media-worker)"
  sleep 1
done
t_stop=$(now)
for pod in $others; do
  ! stopping "$pod" || fail "the scale-down stopped $victim alone (pod $pod is stopping too)"
done
# The follower ends with the container, within its grace period of 30 s.
deadline=$((SECONDS + 60))
while kill -0 "$follower_pid" 2>/dev/null; do
  ((SECONDS < deadline)) || fail "pod $victim stopped within 60s of its SIGTERM"
  sleep 1
done
follower_pid=
t_gone=$(now)
kc -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas- >/dev/null ||
  fail "remove the pause of ScaledObject media-worker"
paused=
t_resume=$(now)
victim_done=$victim
victim=
interrupted=$(jq -R -r --arg t "$pause_second" 'fromjson?
  | select(.msg == "transcode job interrupted" and .time[0:19] >= $t) | .video_id' "$work/victim.log" | sort -u)
[[ -n $interrupted ]] ||
  fail "pod $victim_done logged 'transcode job interrupted' when it stopped (it was transcoding $held; it may have stopped between two jobs: run the drill again)"
for id in $interrupted; do
  [[ -n $(video_name "$id") ]] || fail "pod $victim_done interrupted video $id, which this drill did not upload"
done
ok "pod $victim_done stopped mid-transcode: interrupted $(for id in $interrupted; do video_name "$id"; done | paste -sd' ' -)"
ok "pause removed: KEDA scales media-worker on the lag again"

wait "$watcher_pid" || fail "every video READY (the watcher's error is above)"
watcher_pid=
t_ready=$(awk '$2 > m { m = $2 } END { printf "%.3f", m }' "$work/ready")
ok "all $n videos READY $(awk -v a="$t0" -v b="$t_ready" 'BEGIN { printf "%.1f", b - a }') s after the first CompleteUpload"
while read -r i t; do printf -v "v${i}_ready" '%s' "$t"; done <"$work/ready"
# Which member transcoded each interrupted video again, from the logs of the workers still running (none has scaled
# in yet: the HPA's window holds them for 5 minutes after the lag is gone).
kc -n svp logs -l "$selector" -c media-worker --tail=-1 --prefix --max-log-requests=10 2>/dev/null >"$work/worker.logs" || true

[[ -n $(kc -n svp get hpa keda-hpa-media-worker --ignore-not-found -o name) ]] ||
  fail "KEDA made HPA keda-hpa-media-worker again once the pause was removed"
deadline=$((SECONDS + down_timeout))
until [[ $(worker_replicas || true) == "1 1" ]]; do
  ((SECONDS < deadline)) || fail "media-worker back at 1 replica within ${down_timeout}s of the last READY (now '$(worker_replicas || true)')"
  sleep 2
done
t_one=$(now)
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=

# --- Results -------------------------------------------------------------------------------------------------------
since() { awk -v a="$t0" -v b="$1" 'BEGIN { printf "%.1f", b - a }'; }
between() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# first_sample COLUMN MIN: the first sample time whose COLUMN (2 desired, 3 ready) is at least MIN, "" when none.
first_sample() { awk -v c="$1" -v m="$2" -v t0="$t0" '$1 >= t0 && $c != "-" && $c + 0 >= m { print $1; exit }' "$work/samples"; }
fmt_since() { if [[ -n $1 ]]; then echo "$(since "$1") s"; else echo "not reached"; fi; }

read_topic media.transcodes.v1 "$work/transcodes"
read_topic "$topic" "$work/lifecycle"
for ((i = 1; i <= n; i++)); do
  id_var="v${i}_id"
  p_var="v${i}_partition"
  got=$(awk -v k="${!id_var}" '$1 == k && $2 == "12" { print $3; exit }' "$work/lifecycle")
  [[ $got == "${!p_var}" ]] ||
    fail "video.uploaded of v$i (${!id_var}) is on partition ${!p_var}, as kafka_partition predicted (it is on '$got')"
done
landed=$(for ((i = 1; i <= n; i++)); do p_var="v${i}_partition" && echo "${!p_var}"; done | sort -u | wc -l | tr -d ' ')

peak_ready=$(awk -v t0="$t0" '$1 >= t0 && $3 != "-" && $3 + 0 > p { p = $3 + 0 } END { print p + 0 }' "$work/samples")
peak_lag=$(awk -v t0="$t0" '$1 >= t0 && $4 != "-" && $4 + 0 > p { p = $4 + 0 } END { print p + 0 }' "$work/samples")
peak_keda=$(awk -v t0="$t0" '$1 >= t0 && $5 != "-" && $5 + 0 > p { p = $5 + 0 } END { print p + 0 }' "$work/samples")
samples=$(awk -v t0="$t0" '$1 >= t0' "$work/samples" | wc -l | tr -d ' ')

echo
echo "      drill-k8s-keda: N=$n, $samples samples"
# reached COLUMN: the time from the first complete to each replica count from 2 to the maximum ("A / B" for 2 and 3).
reached() {
  local r out=
  for ((r = 2; r <= max_replicas; r++)); do out="${out:+$out / }$(fmt_since "$(first_sample "$1" "$r")")"; done
  echo "$out"
}
counts=$(for ((r = 2; r <= max_replicas; r++)); do echo "$r"; done | paste -sd/ - | sed 's|/| / |g')
printf '      %-52s %s\n' "desired replicas $counts after first complete" "$(reached 2)"
printf '      %-52s %s\n' "ready replicas $counts after first complete" "$(reached 3)"
printf '      %-52s %s\n' "$max_replicas ready replicas, each owning a partition" "$(since "$t_spread") s"
printf '      %-52s %s\n' "peak ready replicas" "$peak_ready"
printf '      %-52s %s\n' "partitions holding the $n video.uploaded" "$landed of $partitions (as predicted)"
printf '      %-52s %s\n' "peak lag of group media-worker (rpk)" "$peak_lag"
printf '      %-52s %s\n' "peak lag KEDA served to its HPA" "$peak_keda"

# For each pod that became Ready after the first complete: Ready -> its address owns a partition.
awk -v t0="$t0" '
  FNR == NR { if ($4 == "True" && !($2 in ready)) { ready[$2] = $1; ip[$2] = $3 }; next }
  { n = split($6, o, ","); for (i = 1; i <= n; i++) if (!(o[i] in owns)) owns[o[i]] = $1 }
  END {
    for (p in ready) {
      if (ready[p] < t0) continue
      a = ip[p]
      if (a in owns && owns[a] >= ready[p]) printf "      %-52s %.1f s\n", "rebalance wait of " p, owns[a] - ready[p]
      else if (a in owns) printf "      %-52s %s\n", "rebalance wait of " p, "owned a partition before Ready"
      else printf "      %-52s %s\n", "rebalance wait of " p, "never owned a partition"
    }
  }' "$work/pods" "$work/samples"

printf '      %-52s %s\n' "scale-down: pinned at $pin replicas" "$(since "$t_pause") s after first complete; $victim_done transcoding $(video_name "$held")"
printf '      %-52s %s\n' "scale-down: pod stopping / gone" "$(between "$t_pause" "$t_stop") / $(between "$t_pause" "$t_gone") s after the pin"
printf '      %-52s %s\n' "scale-down: pin removed" "$(since "$t_resume") s after first complete"
for id in $interrupted; do
  name=$(video_name "$id")
  r_var="${name}_ready"
  redo=$(awk -v id="$id" 'index($0, "\"transcode job finished\"") && index($0, "\"video_id\":\"" id "\"") {
      sub(/^\[pod\//, ""); sub(/\/.*/, ""); print; exit }' "$work/worker.logs")
  printf '      %-52s %s\n' "scale-down: $name interrupted, done again by" "${redo:-a pod gone since}; READY $(between "$t_stop" "${!r_var}") s after the SIGTERM"
done

for ((i = 1; i <= n; i++)); do
  c_var="v${i}_completed"
  r_var="v${i}_ready"
  id_var="v${i}_id"
  printf '      %-52s %s s (%s s after the first)\n' "READY of v$i ${!id_var}" \
    "$(between "${!c_var}" "${!r_var}")" "$(since "${!r_var}")"
done
printf '      %-52s %s s\n' "last READY -> 1 replica" "$(between "$t_ready" "$t_one")"
read -r top_cpu top_mem top_sum <<<"$(awk -v t0="$t0" '$1 >= t0 {
    if ($3 > c) c = $3; if ($4 > m) m = $4; s[$1] += $4
  } END { for (t in s) if (s[t] > ms) ms = s[t]; printf "%d %d %d", c, m, ms }' "$work/top")"
printf '      %-52s %s\n' "peak of one worker pod (kubectl top)" "CPU ${top_cpu}m (limit 2000m), RAM ${top_mem} MiB (limit 2048 MiB)"
printf '      %-52s %s\n' "peak RAM of all worker pods together" "${top_sum} MiB"
echo

((peak_ready >= max_replicas)) || fail "media-worker ran $max_replicas ready replicas (peak $peak_ready)"
ok "media-worker scaled out to $peak_ready ready replicas and back to 1"

for ((i = 1; i <= n; i++)); do
  id_var="v${i}_id"
  completed=$(count_key "$work/transcodes" "${!id_var}" 12)
  ready=$(count_key "$work/lifecycle" "${!id_var}" 1a)
  [[ $completed == 1 && $ready == 1 ]] ||
    fail "video v$i (${!id_var}) has one transcode.completed and one video.ready (got $completed and $ready)"
done
ok "every video transcoded exactly once, the interrupted one included: one transcode.completed and one video.ready each"
check_server || exit 1

echo "drill-k8s-keda: all checks passed"
