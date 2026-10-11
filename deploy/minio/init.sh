#!/bin/sh
# Creates the buckets, the anonymous read policy of `media` and one user per service on the
# compose MinIO (docs/adr/0008-async-upload-pipeline-stage2a.md, section 6; threat model UP-4,
# UP-5, UP-6, FF-4). Run by the one-shot minio-init container with the root password and the two
# service secret keys in its environment. Idempotent: running it again keeps the buckets and their
# objects, and resets the users' secret keys and policies to what this script and the .env say.
set -eu

: "${MINIO_ROOT_PASSWORD:?}" "${SVP_VIDEO_S3_SECRET_KEY:?}" "${SVP_MEDIA_WORKER_S3_SECRET_KEY:?}"
dir=$(dirname "$0")

# The alias comes from the environment, so the root password is never on a command line.
export MC_HOST_svp="http://svp-admin:${MINIO_ROOT_PASSWORD}@minio:9000"

mc mb --ignore-existing svp/uploads svp/media >/dev/null
# uploads: no anonymous access at all (UP-5). media: anonymous GetObject on single objects only,
# never ListBucket (UP-6); mc's ready-made `download` policy would allow listing too.
mc anonymous set none svp/uploads >/dev/null
mc anonymous set-json "$dir/media-anonymous.json" svp/media >/dev/null
echo "minio-init: buckets uploads, media ok"

# user NAME POLICY_FILE SECRET_KEY: creates or overwrites the policy NAME, creates the user NAME or
# resets its secret key, and attaches the policy (attaching it again is not an error).
user() {
  mc admin policy create svp "$1" "$2" >/dev/null
  mc admin user add svp "$1" "$3" >/dev/null
  mc admin policy attach svp "$1" --user "$1" >/dev/null
  echo "minio-init: user $1 ok"
}

user svp-video-service "$dir/video-service-policy.json" "$SVP_VIDEO_S3_SECRET_KEY"
user svp-media-worker "$dir/media-worker-policy.json" "$SVP_MEDIA_WORKER_S3_SECRET_KEY"
