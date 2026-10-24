#!/usr/bin/env bash
# Prints the manifests of the k6 Job of the cloud cluster (docs/adr/0020-reliability-stage6.md, section 2) on stdout:
# namespace svp-load, ConfigMap svp-k6-scripts with the scripts of deploy/k6/ as they are in this working tree, and the
# Indexed Job of job.yaml.in. Reaches no cluster and reads no .env; needs jq. run.sh applies its output, and
# `make cloud-check` checks it (run with no argument).
#
# The image is K6_IMAGE as the root Makefile pins it, read from there: one place to pin k6 for make load-local, CI and
# this Job, and Renovate updates that line only.
#
# Usage: deploy/k6/cloud/render.sh [--domain <domain>] [--envoy-ip <ClusterIP>] [--forwarded-for] [--ca-file <file>]
#   --domain         the web's host; the API is api.<domain> (default svp.invalid, for the static check only)
#   --envoy-ip       ClusterIP of Envoy's Service, which the public names resolve to inside the pods (default
#                    192.0.2.1, a documentation address, for the static check only)
#   --forwarded-for  each pod writes its own IP in X-Forwarded-For: only when stage 7 trusts two hops (threat model RL-7)
#   --ca-file        PEM file of the CA that signs Envoy's certificate, when a private CA does (job.yaml.in, lines
#                    marked @CA@): a ConfigMap svp-k6-ca holds it and the pods trust it alone. Certificates only: a
#                    file holding a private key is refused. Without it the pods trust the image's roots.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
k6dir=$(cd "$here/.." && pwd)
repo=$(cd "$k6dir/../.." && pwd)

die() {
  echo "render.sh: $1" >&2
  exit 1
}

domain=svp.invalid envoy_ip=192.0.2.1 forwarded_for= ca_file=
while [ $# -gt 0 ]; do
  case $1 in
    --domain) [ $# -ge 2 ] || die "--domain needs a value"; domain=$2; shift 2 ;;
    --envoy-ip) [ $# -ge 2 ] || die "--envoy-ip needs a value"; envoy_ip=$2; shift 2 ;;
    # Kubernetes expands $(SVP_K6_POD_IP), the variable set from status.podIP just before it in the Job.
    --forwarded-for) forwarded_for='$(SVP_K6_POD_IP)'; shift ;;
    --ca-file) [ $# -ge 2 ] || die "--ca-file needs a value"; ca_file=$2; shift 2 ;;
    *) die "unknown argument $1 (see the top of this file)" ;;
  esac
done
[[ $domain =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || die "--domain is not a host name: $domain"
[[ $envoy_ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[0-9a-f:]+$ ]] || die "--envoy-ip is not an IP address: $envoy_ip"

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
# Lines marked @CA@ lose the mark with --ca-file and go away without it.
if [ -n "$ca_file" ]; then ca_lines='s| # @CA@$||'; else ca_lines='/ # @CA@$/d'; fi
rendered=$(sed -e '1,/^apiVersion:/{/^#/d;}' -e "s|@K6_IMAGE@|$image|g" -e "s|@DOMAIN@|$domain|g" \
  -e "s|@ENVOY_IP@|$envoy_ip|g" -e "s|@FORWARDED_FOR@|$forwarded_for|g" -e "s|@SCRIPT_ITEMS@|$items|g" \
  -e "$ca_lines" "$here/job.yaml.in")
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
