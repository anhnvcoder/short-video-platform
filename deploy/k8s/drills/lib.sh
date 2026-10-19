# shellcheck shell=bash
# Helpers shared by the drills on the local k3d cluster svp (deploy/k8s/drills/): the API helpers of
# deploy/compose/lib.sh through Envoy (SVP_STACK=k3d), the kubectl/helm helpers of deploy/k8s/lib.sh, rpk inside the
# broker pod, an upload that ends with CompleteUpload, counting events by record key and the partition a key lands on.
# Written for bash 3.2 (the macOS /bin/bash).
#
# Source it after setting `base` (https://api.svp.localhost:8443); the make target sets SVP_STACK=k3d and
# CURL_CA_BUNDLE to the cluster's CA. kubectl names --context k3d-svp on every call; rpk runs in container redpanda of
# pod redpanda-0 as svp-admin, with the login the container already has in its environment (RPK_USER, RPK_PASS), so no
# password passes through this machine. Topics and groups are only read.
#
# LOCAL LAB ONLY: deploy/compose/lib.sh deletes the gateway's register rate limit keys in the cluster's Valkey db 10.

[[ ${SVP_STACK:-} == k3d ]] || {
  echo "FAIL  SVP_STACK=k3d is not set; run the k8s drills through make" >&2
  exit 1
}
# shellcheck source=deploy/k8s/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# Sourced second: it creates $work and the EXIT trap that removes it. A caller that only reads (measure-canary) sets
# drill_read_only=1 first: deploy/compose/lib.sh deletes the register rate limit keys as it is sourced, so it is left
# out and only the private work directory is made.
if [[ ${drill_read_only:-} == 1 ]]; then
  umask 077
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
else
  # shellcheck source=deploy/compose/lib.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../../compose/lib.sh"
fi

kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"

# now: seconds since the epoch with milliseconds (bash 3.2 has no EPOCHREALTIME).
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# rpk ARGS...: rpk inside the broker container, as svp-admin.
rpk() { kc -n svp-data exec redpanda-0 -c redpanda -- rpk "$@"; }

# check_uuid VALUE: fails unless VALUE is a UUID (it goes into grep patterns).
check_uuid() {
  [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "video id is a UUID (got '$1')"
}

# create_and_upload NAME AUTH_FILE FILE: creates video NAME for FILE and uploads it through the presigned form,
# without completing it; sets <NAME>_id like create_video.
create_and_upload() {
  local name=$1 size status id_var="${1}_id"
  size=$(file_size "$3")
  create_video "$name" "$2" "drill $name $(openssl rand -hex 4)" "$size" video/mp4
  check_uuid "${!id_var}"
  status=$(upload_file "$name" "$3")
  [[ $status == 2?? ]] || fail "upload video $name to the presigned form (status $status, code $(storage_error_code))"
}

# complete NAME AUTH_FILE: CompleteUpload of video NAME, which must answer 202 PROCESSING.
complete() {
  local status
  status=$(complete_upload "$1" "$2")
  [[ $status == 202 && $(field status) == PROCESSING ]] ||
    fail "complete video $1 is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
}

# event_tag HEX: the protobuf tag byte (hex) of the oneof branch of an event envelope whose field 1 is the EventMeta:
# "12" for field 2 (video_uploaded, transcode_completed), "1a" for field 3 (video_ready, transcode_failed); "" when
# the value does not start that way.
event_tag() {
  local hex=$1 n
  [[ ${hex:0:2} == 0a ]] || return 0
  n=$((16#${hex:2:2}))
  ((n < 128)) || return 0 # a two-byte length never happens for EventMeta; refuse to guess
  printf '%s' "${hex:$(((2 + n) * 2)):2}"
}

# read_topic TOPIC FILE: writes "KEY TAG PARTITION" for every record of TOPIC, from its start to its current end, to
# FILE.
read_topic() {
  local p k v
  rpk topic consume "$1" -o :end -f '%p %k %v{hex}\n' >"$work/consume" || fail "read topic $1 with rpk topic consume"
  : >"$2"
  while read -r p k v; do
    printf '%s %s %s\n' "$k" "$(event_tag "$v")" "$p" >>"$2"
  done <"$work/consume"
}

# count_key FILE KEY TAG: how many records of a read_topic FILE have KEY and TAG.
count_key() { awk -v k="$2" -v t="$3" '$1 == k && $2 == t { n++ } END { print n + 0 }' "$1"; }

# kafka_partition KEY PARTITIONS: the partition a record keyed KEY lands on, as the producers of this project pick it:
# franz-go's default partitioner hashes a key with Kafka's murmur2 (seed 0x9747b28c), drops the sign bit and takes it
# modulo the partition count, as Kafka's Java client does. perl, as for `now`: bash 3.2 has no 32-bit arithmetic to
# rely on. mul multiplies modulo 2^32 in 16-bit halves, so no product leaves perl's 64-bit integers.
kafka_partition() {
  perl -e '
    use strict;
    use warnings;
    sub mul { my ($a, $b) = @_; return ((($a & 0xffff) * $b) + (((($a >> 16) * $b) & 0xffff) << 16)) & 0xffffffff; }
    my ($key, $n) = @ARGV;
    my @b = unpack("C*", $key);
    my $m = 0x5bd1e995;
    my $h = (0x9747b28c ^ scalar(@b)) & 0xffffffff;
    my $i = 0;
    for (; $i + 4 <= @b; $i += 4) {
      my $k = $b[$i] | ($b[$i + 1] << 8) | ($b[$i + 2] << 16) | ($b[$i + 3] << 24);
      $k = mul($k, $m);
      $k ^= $k >> 24;
      $k = mul($k, $m);
      $h = mul($h, $m) ^ $k;
    }
    my $r = @b - $i;
    $h ^= $b[$i + 2] << 16 if $r >= 3;
    $h ^= $b[$i + 1] << 8 if $r >= 2;
    if ($r >= 1) { $h ^= $b[$i]; $h = mul($h, $m); }
    $h ^= $h >> 13;
    $h = mul($h, $m);
    $h ^= $h >> 15;
    print +($h & 0x7fffffff) % $n;
  ' "$1" "$2"
}

# Prometheus of svp-obs has no address on the host and its image no HTTP client to exec, so the drills that read it
# open a port-forward on a fixed loopback port for as long as they run: prometheus_forward starts it, prometheus_stop
# (from the caller's EXIT trap) stops it by the pid it recorded.
prom_port=19090
prom_pid=
prometheus_forward() {
  port_free "$prom_port" || fail "127.0.0.1:$prom_port is in use (another port-forward?); free it and run again"
  # kubectl itself, not the kc function: in the background a function runs in a subshell, $! would be that subshell's
  # pid, and killing it would leave kubectl running.
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$prom_port:9090" \
    >"$work/prom-forward.log" 2>&1 &
  prom_pid=$!
  wait_until 20 "port-forward to Prometheus on 127.0.0.1:$prom_port" curl -sf --max-time 2 "http://127.0.0.1:$prom_port/-/ready"
}
prometheus_stop() {
  if [ -n "$prom_pid" ]; then
    kill "$prom_pid" 2>/dev/null || true
    wait "$prom_pid" 2>/dev/null || true
    prom_pid=
  fi
}

# promql QUERY [TIME]: .data.result of an instant query (at TIME, unix seconds, when given), compact JSON on stdout.
promql() {
  local args=(--data-urlencode "query=$1")
  [ -z "${2:-}" ] || args+=(--data-urlencode "time=$2")
  curl -sf --max-time 10 "http://127.0.0.1:$prom_port/api/v1/query" "${args[@]}" | jq -c '.data.result'
}
