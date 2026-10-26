#!/usr/bin/env bash
# Prints the manifests of the k6 Job of the cloud cluster on stdout:
# namespace svp-load, ConfigMap svp-k6-scripts with the scripts of deploy/k6/ as they are in this working tree, and the
# Indexed Job of job.yaml.in. Reaches no cluster and reads no .env; needs jq. run.sh applies its output, and
# `make cloud-check` checks it (run with no argument).
#
# The image is K6_IMAGE as the root Makefile pins it, read from there: one place to pin k6 for make load-local, CI and
# this Job, and Renovate updates that line only.
#
# Usage: deploy/k6/cloud/render.sh [--domain <domain>] [--web-origin <origin>] [--envoy-ip <ClusterIP>] [--forwarded-for] [--ca-file <file>] [--pods <n>] [--ramp <duration>] [--hold <duration>] [--cpu-request <cpu>] [--cpu-limit <cpu>]
#   --domain         the web's host; the API is api.<domain> (default svp.invalid, for the static check only)
#   --web-origin     the origin users open the web at, which its CSRF check compares Origin with (default
#                    https://<domain>; the k3d cluster's is https://svp.localhost:8443, while the pods still dial
#                    https://svp.localhost, Envoy's port 443 inside the cluster)
#   --envoy-ip       ClusterIP of Envoy's Service, which the public names resolve to inside the pods (default
#                    192.0.2.1, a documentation address, for the static check only)
#   --forwarded-for  each pod writes its own IP in X-Forwarded-For: only when stage 7 trusts two hops (threat model RL-7)
#   --ca-file        PEM file of the CA that signs Envoy's certificate, when a private CA does (job.yaml.in, lines
#                    marked @CA@): a ConfigMap svp-k6-ca holds it, and the pods trust it in addition to whatever
#                    roots the image holds in /etc/ssl/certs (SSL_CERT_FILE replaces only the bundle file, not that
#                    directory). Certificates only: a file holding a private key is refused. Without it the pods trust
#                    the image's roots.
#   --pods           how many pods run the load, 1 to 20 (default 20, the design): each keeps the load of one pod of
#                    the design, so the totals shrink with the count (lib/config.js, SVP_K6_PODS)
#   --ramp, --hold   how long the rate ramps up and holds (SVP_K6_RAMP, SVP_K6_HOLD; a whole number of s, m or h, like
#                    2m; default the profile's 10m each); either one sets the Job's deadline from the run's length
#                    instead of the default 3600 s
#   --cpu-request    the CPU each pod requests (default 1; a k3d cluster on a 4 vCPU runner has no room for 8 pods
#                    of 1 CPU next to the stack)
#   --cpu-limit      a CPU limit for each pod (default none), so that a pod short of CPU shows as throttled periods
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
k6dir=$(cd "$here/.." && pwd)
repo=$(cd "$k6dir/../.." && pwd)

die() {
  echo "render.sh: $1" >&2
  exit 1
}

# The design's pod count and the run of profile cloud (lib/config.js): ramp 10m, hold 10m, down 1m.
design_pods=20 profile_ramp=10m profile_hold=10m ramp_down_seconds=60
# What the deadline adds to the run itself (job.yaml.in): pull and schedule the pods, setup(), the summary.
deadline_margin_seconds=900
duration_re='^[1-9][0-9]*[smh]$'

# seconds DURATION: DURATION (already checked against duration_re) in seconds.
seconds() {
  local n=${1%?}
  case $1 in
    *s) echo "$n" ;;
    *m) echo $((n * 60)) ;;
    *h) echo $((n * 3600)) ;;
  esac
}

domain=svp.invalid web_origin= envoy_ip=192.0.2.1 forwarded_for= ca_file= pods=$design_pods ramp= hold= cpu_request=1 cpu_limit=
while [ $# -gt 0 ]; do
  case $1 in
    --domain) [ $# -ge 2 ] || die "--domain needs a value"; domain=$2; shift 2 ;;
    --web-origin) [ $# -ge 2 ] || die "--web-origin needs a value"; web_origin=$2; shift 2 ;;
    --envoy-ip) [ $# -ge 2 ] || die "--envoy-ip needs a value"; envoy_ip=$2; shift 2 ;;
    # Kubernetes expands $(SVP_K6_POD_IP), the variable set from status.podIP just before it in the Job.
    --forwarded-for) forwarded_for='$(SVP_K6_POD_IP)'; shift ;;
    --ca-file) [ $# -ge 2 ] || die "--ca-file needs a value"; ca_file=$2; shift 2 ;;
    --pods) [ $# -ge 2 ] || die "--pods needs a value"; pods=$2; shift 2 ;;
    --ramp) [ $# -ge 2 ] || die "--ramp needs a value"; ramp=$2; shift 2 ;;
    --hold) [ $# -ge 2 ] || die "--hold needs a value"; hold=$2; shift 2 ;;
    --cpu-request) [ $# -ge 2 ] || die "--cpu-request needs a value"; cpu_request=$2; shift 2 ;;
    --cpu-limit) [ $# -ge 2 ] || die "--cpu-limit needs a value"; cpu_limit=$2; shift 2 ;;
    *) die "unknown argument $1 (see the top of this file)" ;;
  esac
done
[[ $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "--domain is not a host name: $domain"
web_origin=${web_origin:-https://$domain}
[[ $web_origin =~ ^https://[a-z0-9.-]+(:[1-9][0-9]{0,4})?$ ]] || die "--web-origin is not an https origin with no path: $web_origin"
[[ $envoy_ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[0-9a-f:]+$ ]] || die "--envoy-ip is not an IP address: $envoy_ip"
[[ $pods =~ ^[1-9][0-9]*$ ]] && [ "$pods" -le "$design_pods" ] || die "--pods is not a whole number from 1 to $design_pods: $pods"
[ -z "$ramp" ] || [[ $ramp =~ $duration_re ]] || die "--ramp is not a whole number of s, m or h, like 2m: $ramp"
[ -z "$hold" ] || [[ $hold =~ $duration_re ]] || die "--hold is not a whole number of s, m or h, like 10m: $hold"
[[ $cpu_request =~ ^[1-9][0-9]*m?$ ]] || die "--cpu-request is not a whole number of CPUs or millicores, like 250m: $cpu_request"
[ -z "$cpu_limit" ] || [[ $cpu_limit =~ ^[1-9][0-9]*m?$ ]] || die "--cpu-limit is not a whole number of CPUs or millicores, like 1: $cpu_limit"

deadline=3600
if [ -n "$ramp$hold" ]; then
  deadline=$(($(seconds "${ramp:-$profile_ramp}") + $(seconds "${hold:-$profile_hold}") + ramp_down_seconds +
    deadline_margin_seconds))
fi

if [ -n "$ca_file" ]; then
  [ -f "$ca_file" ] && [ -r "$ca_file" ] || die "--ca-file $ca_file is not a readable file"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$ca_file" || die "--ca-file $ca_file holds no PEM certificate"
  # A ConfigMap is readable by anyone who can read the namespace: never put a key there.
  ! grep -q -- 'PRIVATE KEY' "$ca_file" || die "--ca-file $ca_file holds a private key; give the CA certificate alone"
fi

image=$(sed -n 's/^K6_IMAGE := //p' "$repo/Makefile")
[[ $image =~ ^grafana/k6:[^@]+@sha256:[0-9a-f]{64}$ ]] || die "no K6_IMAGE := grafana/k6:<tag>@sha256:<digest> line in the Makefile"

# Every script k6 loads: main.js, api.js, web.js and lib/*.js. ConfigMap keys cannot hold a /, so lib/x.js is key
# lib.x.js, put back at lib/x.js by the volume's items.
files=()
while IFS= read -r f; do files+=("$f"); done < <(cd "$k6dir" && find . -maxdepth 1 -name '*.js' | sed 's#^\./##' | sort
  find lib -maxdepth 1 -name '*.js' | sort)
[ "${#files[@]}" -gt 0 ] || die "no script under $k6dir"
args=()
for f in "${files[@]}"; do args+=(--rawfile "$f" "$k6dir/$f"); done
configmap=$(jq -n "${args[@]}" '
  {apiVersion: "v1", kind: "ConfigMap",
   metadata: {name: "svp-k6-scripts", namespace: "svp-load"},
   data: ($ARGS.named | with_entries(.key |= gsub("/"; ".")))}')
items=$(printf '%s\n' "${files[@]}" | jq -R . | jq -cs 'map({key: gsub("/"; "."), path: .})')

# The template without its leading comment, then: the Namespace, the ConfigMap (JSON, which is YAML too), the Job, so
# that kubectl apply creates the scripts before the pods that mount them.
# Lines marked @CA@ lose the mark with --ca-file and go away without it; so do those marked @PODS@ with fewer pods than
# the design's, @RAMP@ with --ramp, @HOLD@ with --hold and @CPU_LIMIT@ with --cpu-limit. The marks go before the values that share their names.
fewer=
[ "$pods" = "$design_pods" ] || fewer=1
marks=()
for m in CA:"$ca_file" PODS:"$fewer" RAMP:"$ramp" HOLD:"$hold" CPU_LIMIT:"$cpu_limit"; do
  if [ -n "${m#*:}" ]; then marks+=(-e "s| # @${m%%:*}@\$||"); else marks+=(-e "/ # @${m%%:*}@\$/d"); fi
done
rendered=$(sed -e '1,/^apiVersion:/{/^#/d;}' "${marks[@]}" -e "s|@K6_IMAGE@|$image|g" -e "s|@DOMAIN@|$domain|g" \
  -e "s|@WEB_ORIGIN@|$web_origin|g" -e "s|@ENVOY_IP@|$envoy_ip|g" -e "s|@FORWARDED_FOR@|$forwarded_for|g" \
  -e "s|@SCRIPT_ITEMS@|$items|g" -e "s|@PODS@|$pods|g" -e "s|@DEADLINE@|$deadline|g" \
  -e "s|@CPU_REQUEST@|$cpu_request|g" -e "s|@CPU_LIMIT@|$cpu_limit|g" -e "s|@RAMP@|$ramp|g" -e "s|@HOLD@|$hold|g" "$here/job.yaml.in")
namespace=${rendered%%$'\n'---$'\n'*}
job=${rendered#*$'\n'---$'\n'}
[ "$namespace" != "$rendered" ] || die "job.yaml.in has no --- between the Namespace and the Job"
if [ -n "$ca_file" ]; then
  configmap+=$'\n---\n'$(jq -n --rawfile ca "$ca_file" '
    {apiVersion: "v1", kind: "ConfigMap",
     metadata: {name: "svp-k6-ca", namespace: "svp-load"},
     data: {"ca.crt": $ca}}')
fi
printf '%s\n---\n%s\n---\n%s\n' "$namespace" "$configmap" "$job"
