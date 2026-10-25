#!/bin/sh
# Creates the buckets, their CORS rules, the anonymous read policy of `media` and one user per
# service on the local object store (RustFS). Each service gets its own user and policy limited to
# the prefixes it needs, and never the root credential, so a compromised service cannot read or
# write the other's objects; `media` allows anonymous GetObject only, never listing, and `uploads`
# nothing anonymous (threat model UP-4, UP-5, UP-6, FF-4). Browsers may read answers cross-origin
# only from the origins in S3_CORS_ALLOWED_ORIGINS and only for what the web client does: POST a
# presigned form to uploads, GET (and HEAD) under media (WEB-10). The store's global CORS list stays
# empty, so a bucket without rules of its own sends no CORS header at all.
#
# Run by the one-shot s3-init container, with the store's image: its curl signs each request
# (SigV4) as the root user and calls the S3 API and RustFS's admin API (/rustfs/admin/v3, which
# takes plain JSON). Idempotent: running it again keeps the buckets and their objects, and resets
# the users' secret keys and policies, the bucket policies and the CORS rules to what this script
# and its environment say. Prints no secret.
#
# Optional, each made only when its secret key is set:
# - SVP_PG_BACKUP_S3_SECRET_KEY (the k3d cluster's init Job): bucket pg-backups and user
#   svp-pg-backup, for the backups of Postgres svp-pg (threat model BAK-1).
# - SVP_S3_PROBE_SECRET_KEY (compose only): bucket objstore-probe and user svp-objstore-probe, used
#   only by the integration tests of internal/objstore. A multipart upload needs
#   AbortMultipartUpload to clean up, which the service users do not have and must not get.
set -eu

: "${S3_ROOT_PASSWORD:?}" "${SVP_VIDEO_S3_SECRET_KEY:?}" "${SVP_MEDIA_WORKER_S3_SECRET_KEY:?}" "${S3_CORS_ALLOWED_ORIGINS:?}"
dir=$(dirname "$0")
endpoint=http://s3:9000
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "s3-init: $*" >&2
  exit 1
}

# call METHOD PATH [CURL_ARG...]: one request signed as the root user; prints the status code and
# leaves the answer's body in $tmp/resp. The root password reaches curl as a config line on its
# standard input, never on a command line, where every process in the container could read it.
call() {
  method=$1 path=$2
  shift 2
  printf 'user = "svp-admin:%s"\n' "$S3_ROOT_PASSWORD" |
    curl -sS -K - --aws-sigv4 aws:amz:us-east-1:s3 -X "$method" -o "$tmp/resp" -w '%{http_code}' "$@" "$endpoint$path"
}

# error_code: the error code in the last answer (S3's XML or the admin API's JSON), or nothing.
error_code() {
  sed -n -e 's:.*<Code>\([A-Za-z]*\)</Code>.*:\1:p' -e 's:.*"Code" *\: *"\([A-Za-z]*\)".*:\1:p' "$tmp/resp" | head -n 1
}

# must WHAT STATUSES METHOD PATH [CURL_ARG...]: call, and stop unless the status is one of
# STATUSES (space-separated). The error names WHAT, the status and the store's error code, never
# a body.
must() {
  what=$1 statuses=$2
  shift 2
  status=$(call "$@") || fail "$what: no answer from $endpoint"
  case " $statuses " in *" $status "*) return 0 ;; esac
  fail "$what: status $status $(error_code)"
}

# bucket NAME: creates the bucket unless the root user already owns it.
bucket() {
  status=$(call PUT "/$1") || fail "bucket $1: no answer from $endpoint"
  case $status in
    200) ;;
    409) [ "$(error_code)" = BucketAlreadyOwnedByYou ] || fail "bucket $1: status 409 $(error_code)" ;;
    *) fail "bucket $1: status $status $(error_code)" ;;
  esac
}

# private BUCKET: no bucket policy (nothing anonymous) and no CORS rules (no cross-origin reads).
private() {
  must "bucket policy of $1" "200 204" DELETE "/$1?policy"
  must "CORS of $1" "200 204" DELETE "/$1?cors"
}

# The origins go into XML: each must be a bare http(s) origin, so a typo cannot widen the rule
# (a `*`, a path) or break the document. Commas without spaces, as in S3_CORS_ALLOWED_ORIGINS.
origins=
old_ifs=$IFS
IFS=,
# No pathname expansion while splitting, so a `*` stays a `*` and is refused.
set -f
for o in $S3_CORS_ALLOWED_ORIGINS; do
  printf '%s\n' "$o" | grep -Eqx 'https?://[A-Za-z0-9.-]+(:[0-9]+)?' ||
    fail "S3_CORS_ALLOWED_ORIGINS: '$o' is not an origin like http://localhost:3001"
  origins="$origins<AllowedOrigin>$o</AllowedOrigin>"
done
set +f
IFS=$old_ifs
case ",$S3_CORS_ALLOWED_ORIGINS," in *,,*) fail "S3_CORS_ALLOWED_ORIGINS has an empty item" ;; esac

# cors BUCKET RULE: replaces the bucket's CORS rules with one rule for the origins above; RULE holds
# its methods and headers.
cors() {
  printf '<CORSConfiguration><CORSRule>%s%s<MaxAgeSeconds>600</MaxAgeSeconds></CORSRule></CORSConfiguration>' \
    "$origins" "$2" > "$tmp/cors.xml"
  must "CORS of $1" "200 204" PUT "/$1?cors" --data-binary "@$tmp/cors.xml"
}

bucket uploads
bucket media
# uploads: no anonymous access at all (UP-5). The upload page posts with XHR and reads the
# Retry-After of a refusal, which a cross-origin answer only shows when exposed.
private uploads
cors uploads '<AllowedMethod>POST</AllowedMethod><AllowedHeader>*</AllowedHeader><ExposeHeader>Retry-After</ExposeHeader>'
# media: anonymous GetObject on single objects under media/ only, never ListBucket (UP-6). hls.js
# loads playlists and segments with XHR; HEAD answers like GET.
must "bucket policy of media" "200 204" PUT /media?policy --data-binary "@$dir/media-anonymous.json"
cors media '<AllowedMethod>GET</AllowedMethod><AllowedMethod>HEAD</AllowedMethod><AllowedHeader>*</AllowedHeader>'
echo "s3-init: buckets uploads, media ok"

# user NAME POLICY_FILE SECRET_KEY: creates or overwrites the policy NAME, creates the user NAME or
# resets its secret key (and enables it), and makes NAME its only policy.
user() {
  # The key goes into a JSON body: letters and digits only, as `make env` writes them.
  case $3 in *[!0-9A-Za-z]*) fail "the secret key of $1 must be letters and digits only" ;; esac
  must "policy $1" "200 204" PUT "/rustfs/admin/v3/add-canned-policy?name=$1" --data-binary "@$2"
  # A file in the private temporary directory, not a command line argument.
  printf '{"secretKey":"%s","status":"enabled"}' "$3" > "$tmp/user.json"
  must "user $1" "200 204" PUT "/rustfs/admin/v3/add-user?accessKey=$1" --data-binary "@$tmp/user.json"
  rm -f "$tmp/user.json"
  must "policy of user $1" "200 204" PUT "/rustfs/admin/v3/set-user-or-group-policy?policyName=$1&userOrGroup=$1&isGroup=false"
  echo "s3-init: user $1 ok"
}

user svp-video-service "$dir/video-service-policy.json" "$SVP_VIDEO_S3_SECRET_KEY"
user svp-media-worker "$dir/media-worker-policy.json" "$SVP_MEDIA_WORKER_S3_SECRET_KEY"

# Cluster only (see the top). Barman does not create its bucket. Nothing anonymous, and the user may
# list, read, write and delete in pg-backups alone: the backups hold every database, and no service's
# user may read them, nor this user any service's bucket.
if [ -n "${SVP_PG_BACKUP_S3_SECRET_KEY:-}" ]; then
  bucket pg-backups
  private pg-backups
  echo "s3-init: bucket pg-backups ok"
  user svp-pg-backup "$dir/pg-backup-policy.json" "$SVP_PG_BACKUP_S3_SECRET_KEY"
fi

# Compose only (see the top): nothing anonymous, no CORS, and the probe user reaches this bucket
# alone.
if [ -n "${SVP_S3_PROBE_SECRET_KEY:-}" ]; then
  bucket objstore-probe
  private objstore-probe
  echo "s3-init: bucket objstore-probe ok"
  user svp-objstore-probe "$dir/objstore-probe-policy.json" "$SVP_S3_PROBE_SECRET_KEY"
fi
