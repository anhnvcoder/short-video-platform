#!/usr/bin/env bash
# The data a load test of an EKS cluster of the project reads (make eks-seed): 4 users, each uploading 8 short videos
# (2 s, 320x240) through the public API, every one completed and waited for until READY, then GET /feed/explore must
# hold at least 30 READY videos. The k6 profile cloud reads its pool of videos from explore at setup and fails without
# enough; these are the videos the local seed of the verification runs makes too.
#
# Only the API helpers of deploy/compose/lib.sh, with SVP_STACK=eks: the gateway at BASE (https://api.<domain>, whose
# certificate is a public one, so curl needs no CA of its own), the register rate limit reset in the Valkey of the
# cluster SVP_KUBE_CONTEXT names (svp-stg or svp-prd). Needs curl, jq, openssl, ffmpeg and kubectl on the host.
#
# LOCAL LAB ONLY: deploy/compose/lib.sh deletes the register rate limit keys in the cluster's Valkey db 10. Never point
# it at a shared or production stack.
#
# Usage: SVP_STACK=eks SVP_KUBE_CONTEXT=svp-stg deploy/k8s/eks-seed.sh https://api.<domain>
set -euo pipefail

[ $# = 1 ] && [[ $1 == https://* ]] || {
  echo "FAIL  usage: deploy/k8s/eks-seed.sh https://api.<domain>" >&2
  exit 1
}
[ "${SVP_STACK:-}" = eks ] || {
  echo "FAIL  SVP_STACK=eks is not set; run make eks-seed" >&2
  exit 1
}
base=$1
# shellcheck source=deploy/compose/lib.sh
source "$(dirname "$0")/../compose/lib.sh"

users=4
per_user=8
want=30

wait_gateway_ready 120
make_video "$work/clip.mp4" 2 320x240
size=$(file_size "$work/clip.mp4")
n=0
for ((u = 1; u <= users; u++)); do
  new_user "seed$u"
  # One video at a time: each form is completed before the next is created, so no user holds more than one open
  # upload (video-service refuses a fourth).
  for ((v = 1; v <= per_user; v++)); do
    name="v${u}_$v"
    create_video "$name" "$work/seed$u.auth" "seed $name $(openssl rand -hex 4)" "$size" video/mp4
    status=$(upload_file "$name" "$work/clip.mp4")
    [[ $status == 2?? ]] || fail "upload video $name to its presigned form (status $status, code $(storage_error_code))"
    status=$(complete_upload "$name" "$work/seed$u.auth")
    [[ $status == 202 && $(field status) == PROCESSING ]] ||
      fail "complete video $name is 202 PROCESSING (status $status, $(problem_summary), video status $(field status))"
    n=$((n + 1))
  done
done
ok "$n videos uploaded and completed"
for ((u = 1; u <= users; u++)); do
  for ((v = 1; v <= per_user; v++)); do
    wait_ready "v${u}_$v" "$work/seed$u.auth" 600
  done
done
ok "$n videos READY"
# Explore is cached for a while (feed-service), so the new videos may take a moment to show there.
count=0
for _ in $(seq 1 60); do
  status=$(request GET "/feed/explore?page_size=50" "$work/seed1.auth")
  count=$(jq '.items | length' "$work/body" 2>/dev/null || echo 0)
  [[ $status == 200 && $count -ge $want ]] && break
  sleep 5
done
[[ $status == 200 && $count -ge $want ]] ||
  fail "GET /feed/explore holds at least $want READY videos (status $status, $count)"
ok "GET /feed/explore holds $count READY videos"
