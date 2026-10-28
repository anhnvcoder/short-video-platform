#!/usr/bin/env bash
# Installs the CSI hostpath driver with snapshot support on the k3d cluster svp of a CI runner: the snapshot CRDs of
# kubernetes-csi/external-snapshotter, its snapshot controller, the driver, StorageClass csi-hostpath and the
# VolumeSnapshotClass Velero picks (the manifests beside this script). Run by deploy/k8s/install.sh right before the
# release redpanda when SVP_K8S_RUNNER_CSI=1 (scenario velero of deploy/ci/verify-run.sh): Redpanda's helm --wait needs
# its PVC bound, so the StorageClass must work by then. Idempotent: running it again applies the same objects.
#
# Only on a runner the CI platform made for this one job, running Linux (ci_hosted_runner of deploy/ci/platform.sh):
# the driver runs privileged pods with hostPath mounts of the node, which the 16 GB laptop's cluster has no use for.
# A guard against accidents, not a security boundary. Exits non-zero, naming what is missing, when the driver is not
# ready or the StorageClass is not there, so Redpanda is never installed onto a class nothing provisions.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/k8s/lib.sh
. "$here/../../../lib.sh"
# shellcheck source=deploy/ci/platform.sh
. "$repo_root/deploy/ci/platform.sh"

[ "$(uname -s)" = Linux ] && ci_hosted_runner 2>/dev/null ||
  fail "the CSI hostpath driver is installed only on a Linux runner the CI platform made for this job (scenario velero of verify.yml)"
command -v sha256sum >/dev/null || fail "sha256sum not found"

# The snapshot CRDs at the commit of tag v8.7.0 of external-snapshotter (the same tag `make cloud-check` validates
# VolumeSnapshotClass against, and the tag of the snapshot controller and the csi-snapshotter sidecar), each checked
# against its SHA-256: the content applied never moves under the pin, whatever happens to the tag.
snapshotter_commit=9cc6050ab00a0c56d84ba0279e518a00367363e7
crds="75e6565aac2c0f2949ed13ea884bbaa388cb7be576b558b709cf1168e011828d snapshot.storage.k8s.io_volumesnapshotclasses
895a3c1e73b60f06a0deb566dd123d01bdf1b2efc5d5ff5231ff8bbcf42dafc7 snapshot.storage.k8s.io_volumesnapshotcontents
b032116e987fb1d7d93cec7d942833adeb9d95c9bdc7e00c10b280c2fe4a6c33 snapshot.storage.k8s.io_volumesnapshots
0ac1b24c628e73fbe3352c21c7929707453252a64072184727a82d2f3c42fc51 groupsnapshot.storage.k8s.io_volumegroupsnapshotclasses
dc148b9798e4aa080ab3e2dc0681e029ef75ca31adfdf96cf0a14ec309ea9c79 groupsnapshot.storage.k8s.io_volumegroupsnapshotcontents
59abaccbe9e85a611848489da53d855db4ab606894b0c4cab109a574b4a95b10 groupsnapshot.storage.k8s.io_volumegroupsnapshots"
driver=hostpath.csi.k8s.io
ns=csi-hostpath

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# apply FILE...: server-side, under a field manager of its own, so a second run changes nothing it did not set.
apply() { kc apply --server-side --field-manager=svp-runner-csi "${@/#/--filename=}" >/dev/null; }

apply "$here/namespace.yaml" || fail "create namespace $ns (Pod Security privileged)"

# The controller of v8 watches group snapshots too (a GA feature on by default), and stays unready without their CRDs.
names=()
while read -r sum crd; do
  curl -fsSL --max-time 60 -o "$tmp/$crd.yaml" \
    "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/$snapshotter_commit/client/config/crd/$crd.yaml" ||
    fail "download CRD $crd of external-snapshotter at $snapshotter_commit"
  echo "$sum  $tmp/$crd.yaml" | sha256sum -c --status - || fail "CRD $crd: SHA-256 differs from the pinned one"
  names+=("crd/${crd#*_}.${crd%%_*}")
done <<<"$crds"
apply "$tmp"/*.yaml || fail "apply the snapshot CRDs"
kc wait --for=condition=Established "${names[@]}" --timeout=60s >/dev/null || fail "snapshot CRDs Established within 60s"
ok "snapshot CRDs of external-snapshotter v8.7.0 established (${#names[@]})"

apply "$here/snapshot-controller.yaml" "$here/hostpath-plugin.yaml" "$here/storage.yaml" ||
  fail "apply the snapshot controller, the CSI hostpath driver, StorageClass csi-hostpath and VolumeSnapshotClass csi-hostpath-velero"

# driver_registered: true once the kubelet of a node lists the driver (its node-driver-registrar has registered it).
driver_registered() {
  kc get csinodes -o json | jq -e --arg d "$driver" '[.items[].spec.drivers[]? | select(.name == $d)] | length > 0' >/dev/null
}
if ! kc -n "$ns" rollout status deployment/snapshot-controller --timeout=300s >/dev/null ||
  ! kc -n "$ns" rollout status statefulset/csi-hostpathplugin --timeout=300s >/dev/null; then
  unready_report "$ns" || true
  fail "the snapshot controller and the CSI hostpath driver ready in namespace $ns within 300s each"
fi
wait_until 120 "the CSI driver $driver registered on a node (CSINode)" driver_registered
kc get storageclass csi-hostpath >/dev/null 2>&1 || fail "StorageClass csi-hostpath is missing after the apply"
kc get volumesnapshotclass csi-hostpath-velero >/dev/null 2>&1 ||
  fail "VolumeSnapshotClass csi-hostpath-velero is missing after the apply"
ok "CSI hostpath driver ready on node $(kc -n "$ns" get pod csi-hostpathplugin-0 -o jsonpath='{.spec.nodeName}'), StorageClass csi-hostpath, VolumeSnapshotClass csi-hostpath-velero (Retain, Velero's label)"
