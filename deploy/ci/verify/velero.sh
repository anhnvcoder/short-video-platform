# shellcheck shell=bash
# Scenario velero of deploy/ci/verify-run.sh, which sources this file: Velero backing up and restoring Redpanda's
# volumes through CSI snapshots, to the object store of the k3d cluster of the dev path (job k3d of
# .github/workflows/verify.yml). make k8s-up (Redpanda on the CSI hostpath driver's StorageClass), Velero installed,
# deploy/k8s/cloud/velero/drill-restore.sh check and run, then its sweep and Velero uninstalled as at the end of a
# cloud session. unwritten is described in verify-run.sh.

build=k8s-up
job_minutes_default=330
k3d=1

scenario_targets() {
  local drill=deploy/k8s/cloud/velero/drill-restore.sh
  step k8s-up 60 make k8s-up
  step velero-install 20 bash -c 'unwritten velero-install'
  step drill-restore-check 5 "$drill" --context k3d-svp check
  step drill-restore 45 "$drill" --context k3d-svp run
  step drill-restore-sweep 15 "$drill" --context k3d-svp sweep
  step velero-uninstall 15 bash -c 'unwritten velero-uninstall'
}
