# shellcheck shell=bash
# Scenario chaos of deploy/ci/verify-run.sh, which sources this file: the three Chaos Mesh experiments on the k3d
# cluster of the dev path under k6 load (job k3d of .github/workflows/verify.yml). make k8s-up, Chaos Mesh installed,
# the k6 Job holding load, a trial of the network delay on a test pod, then the pod kills (a), the network delay (b) and
# the Redpanda failure (c), the k6 Job deleted, Chaos Mesh uninstalled as at the end of a cloud session.
# deploy/ci/verify-host.sh writes $SVP_VERIFY_OUT/sch-netem, loaded or absent: without sch_netem (b) cannot run.
# unwritten is described in verify-run.sh.

build=k8s-up
job_minutes_default=330
k3d=1

scenario_targets() {
  step k8s-up 60 make k8s-up
  step chaos-mesh-install 20 bash -c 'unwritten chaos-mesh-install'
  step k6-hold-start 10 deploy/k6/cloud/run.sh --context k3d-svp --domain svp.localhost --pods 2 start
  step chaos-b-trial 15 bash -c 'unwritten chaos-b-trial'
  step chaos-a 25 bash -c 'unwritten chaos-a'
  step chaos-b 25 bash -c 'unwritten chaos-b'
  step chaos-c 25 bash -c 'unwritten chaos-c'
  step k6-hold-delete 5 deploy/k6/cloud/run.sh --context k3d-svp --domain svp.localhost delete
  step chaos-mesh-uninstall 15 bash -c 'unwritten chaos-mesh-uninstall'
}
