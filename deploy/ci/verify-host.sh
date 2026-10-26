#!/usr/bin/env bash
# Checks and prepares the machine of a verification run before any make target: the GitHub runner
# ubuntu-24.04, or the rented Linux VM that stands in for it. Fails
# with the numbers, so a run that would have died hours later for want of disk or a name stops here.
#
#   verify-host.sh compose-obs|dev-k3d|gitops|web-canary|k6-cloud-mini|chaos|velero
#
# 1. Disk: free space of the filesystem of Docker's data directory must be at least need + 15% of its size + 2 GiB,
#    need being what the scenario adds (16 GiB for compose-obs: 1.25 times the 12.7 GiB its first run on the runner
#    used; 30 GiB for a k3d scenario: build cache of seven images, the images of about 40 third-party containers in the
#    containerd store of two nodes, volumes, Playwright's browsers). The 15% keeps kubelet below its default image
#    garbage collection threshold (85%). Short of it, the toolsets of the runner image that this repository never uses
#    are deleted (Android, .NET, GHC, CodeQL; not the Go or Node of the hosted tool cache that setup-go and setup-node
#    use), then it measures again and fails if still short. df and docker system df go to
#    $SVP_VERIFY_OUT/df-before.txt and to the log.
# 2. k3d only: the line "127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost" in /etc/hosts (the drills and the
#    browsers reach Envoy by those names, and k3d publishes 127.0.0.1:8443 only, so a name that also resolves to ::1
#    costs a refused connection or a failure), then getent ahosts of each name must give 127.0.0.1 and nothing else.
# 3. k3d only: kubectl of the machine within one minor version of the cluster's k3s (K3S_IMAGE_TAG of the Makefile),
#    as kubectl's version skew policy allows.
# 4. compose-obs only: make web-lighthouse launches Playwright's Chromium through Lighthouse, with Chrome's sandbox,
#    which needs unprivileged user namespaces. Ubuntu 23.10 and later restrict those through AppArmor
#    (kernel.apparmor_restrict_unprivileged_userns=1) for every binary without a profile of its own, and Playwright's
#    download has none, so Chrome stops with "No usable sandbox". The restriction is lifted on this machine (it is
#    thrown away after the run, and the job already has root through sudo), so the sandbox stays on; Playwright's own
#    launches (the e2e tests) turn the sandbox off themselves and need nothing.
# 5. k3d only: prints vm.min_free_kbytes. Seastar takes it off the broker's cgroup limit before it checks --memory, and
#    deploy/k8s/values/redpanda.yaml leaves room for it (66 MiB on an x86_64 runner, 44 MiB in Docker Desktop's VM).
# 6. chaos only: sudo modprobe sch_netem, the kernel module the network delay of Chaos Mesh needs (the k3d nodes share
#    the runner's kernel), and writes loaded or absent to $SVP_VERIFY_OUT/sch-netem. Absent does not stop the run: the
#    scenario's network delay step reads the file and skips, and the other experiments still run.
# It writes the scenario's name to $SVP_VERIFY_OUT/scenario for deploy/ci/verify-collect.sh. Linux only (GNU df).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# ci_temp_dir and the other ci_* functions: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
out=${SVP_VERIFY_OUT:-$tmp_root/verify}
gib=$((1024 * 1024 * 1024))
hosts_line='127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost'

fail() {
  echo "FAIL  verify-host: $1" >&2
  exit 1
}
# Docker without DOCKER_DEFAULT_PLATFORM, as every docker call of the repository (inherited, that variable makes docker
# pull and run images of another architecture, emulated).
docker_() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

scenario=${1:-}
case $scenario in
  compose-obs) need_gib=16 k3d=0 ;;
  # 30 GiB for each k3d scenario until its first run measures its own.
  dev-k3d | gitops | web-canary | k6-cloud-mini | chaos | velero) need_gib=30 k3d=1 ;;
  *) fail "usage: verify-host.sh compose-obs|dev-k3d|gitops|web-canary|k6-cloud-mini|chaos|velero (got '$scenario')" ;;
esac
[ "$(uname -s)" = Linux ] || fail "runs on Linux only (the runner or the rented VM)"
mkdir -p "$out"
printf '%s\n' "$scenario" >"$out/scenario"

root=$(docker_ info -f '{{.DockerRootDir}}') || fail "docker info answers"
# disk: sets size and avail, in bytes, of the filesystem holding Docker's data.
disk() { read -r size avail < <(df -B1 --output=size,avail "$root" | tail -n 1); }
disk
required=$((need_gib * gib + size * 15 / 100 + 2 * gib))
report() { echo "disk: $((avail / gib)) GiB free of $((size / gib)) GiB on the filesystem of $root; the scenario needs $((required / gib)) GiB free"; }
report
if [ "$avail" -lt "$required" ]; then
  echo "disk: short; deleting the runner image's toolsets this repository does not use"
  sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL
  disk
  report
  [ "$avail" -ge "$required" ] || fail "disk: $((avail / gib)) GiB free, $((required / gib)) GiB needed, even after the clean-up"
fi
{
  df -h "$root"
  echo
  docker_ system df
} >"$out/df-before.txt"
cat "$out/df-before.txt"

if [ "$scenario" = compose-obs ]; then
  userns=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)
  if [ "$userns" = 1 ]; then
    sudo sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null ||
      fail "lift kernel.apparmor_restrict_unprivileged_userns for Chrome's sandbox"
    userns=0
  fi
  echo "apparmor: kernel.apparmor_restrict_unprivileged_userns $userns (Chrome's sandbox for make web-lighthouse)"
fi

[ "$k3d" = 1 ] || exit 0

if ! grep -qxF "$hosts_line" /etc/hosts; then
  echo "$hosts_line" | sudo tee -a /etc/hosts >/dev/null
fi
for name in svp.localhost api.svp.localhost s3.svp.localhost; do
  addrs=$(getent ahosts "$name" | awk '{ print $1 }' | sort -u | tr '\n' ' ')
  [ "$addrs" = "127.0.0.1 " ] || fail "$name resolves to '${addrs% }', not 127.0.0.1 alone"
done
echo "hosts: svp.localhost, api.svp.localhost, s3.svp.localhost resolve to 127.0.0.1 only"

k3s_minor=$(sed -n 's/^K3S_IMAGE_TAG *:= *v1\.\([0-9][0-9]*\)\..*/\1/p' "$repo/Makefile")
[ -n "$k3s_minor" ] || fail "read the minor version of K3S_IMAGE_TAG in the Makefile"
# --client asks no server, and a context the kubeconfig does not hold yet (before make k8s-up) does not fail it; the
# context is named all the same, as in every kubectl call of the repository.
client_minor=$(kubectl --context k3d-svp version --client -o json | jq -r '.clientVersion.minor' | tr -dc '0-9')
[ -n "$client_minor" ] || fail "read the minor version of kubectl"
skew=$((client_minor - k3s_minor))
[ "${skew#-}" -le 1 ] || fail "kubectl 1.$client_minor is more than one minor version from k3s 1.$k3s_minor"
echo "kubectl: 1.$client_minor for k3s 1.$k3s_minor (within one minor version)"

echo "memory: vm.min_free_kbytes $(cat /proc/sys/vm/min_free_kbytes) kB (Seastar takes it off the Redpanda broker's limit)"

if [ "$scenario" = chaos ]; then
  netem=absent
  sudo modprobe sch_netem 2>/dev/null && netem=loaded
  printf '%s\n' "$netem" >"$out/sch-netem"
  echo "netem: kernel module sch_netem $netem (the network delay experiment)"
fi
