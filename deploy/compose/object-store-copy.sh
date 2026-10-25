#!/usr/bin/env bash
# Copies the buckets uploads and media between the two local object stores, either way: from the
# MinIO data of volume svp_minio-data to the RustFS data of volume svp_s3-data (`make
# object-store-copy TO=s3`), or back (`TO=minio`). Video rows in svp_video on the native Postgres
# outlive a change of store, so every object they point to must be on the store that runs next.
#
# It never deletes and never overwrites at the target. Before anything is written (a bucket
# included) it lists both sides of uploads and media and refuses, writing nothing, when the target
# has a key the source lacks or the same key with another size: such a key holds data made on the
# target alone (a segment, a rendition playlist, the uploaded file of an UPLOADING video), and making
# the target a copy of the source would delete it. Deleting at the target is left to a person,
# outside this script. It also refuses while a video is PROCESSING (media-worker is writing it). The
# keys a READY video needs (its playlist, thumbnail, and every rendition playlist and segment those
# playlists name) that are on neither side are listed as lost before the copy, without stopping it.
# After `mc mirror` (without its flags that remove or overwrite at the target) it checks that both
# sides hold the same keys with the same sizes, and every object of the source has the same
# Content-Type at the target; it exits non-zero when they differ.
#
# Refuses while a container of the compose project svp, a node or the registry of the k3d cluster
# svp, or any container using one of the two volumes runs: nothing may write to a store while it is
# copied. Runs both stores for the time of the copy on a network of their own with no route out and
# no published port: MinIO with the image pinned below and a new random root password each run
# (MinIO keeps its buckets and objects when started with another root), RustFS with the stack's
# image and the root password of .env, and `mc` of the MinIO image as the client, since that image
# runs anyway to read the MinIO volume. A missing target volume is created, labelled so that compose
# takes it as its own. On exit, Ctrl-C and errors included, it removes the containers and the network
# it made; it removes no volume and no object. Passwords reach the containers through their
# environment, never a command line, and are never printed. Reads svp_video with SELECT only, in a
# read-only transaction, as the local superuser on 127.0.0.1:5432. Written for bash 3.2 (the macOS
# /bin/bash); needs docker, psql, jq and openssl.
#
# Usage: deploy/compose/object-store-copy.sh s3|minio
#
# For deploy/compose/object-store-copy-test.sh only: SVP_OBJCOPY_TEST_MINIO_VOLUME and
# SVP_OBJCOPY_TEST_S3_VOLUME (volumes named svp-scratch-*), SVP_OBJCOPY_TEST_DATABASE (a database
# named svp_*_test) and SVP_OBJCOPY_TEST_ENV_FILE replace the real volumes, svp_video and .env.
set -euo pipefail

usage() {
  echo "usage: $0 s3|minio  (s3: copy MinIO's volume svp_minio-data to RustFS's svp_s3-data; minio: back)" >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
case $1 in s3 | minio) to=$1 ;; *) usage ;; esac

fail() {
  echo "object-store-copy: $*" >&2
  exit 1
}
say() { echo "object-store-copy: $*"; }
dk() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo/deploy/observability/glitchtip/dotenv.sh"

# The store to go back to. Chainguard's free tier only publishes `latest`, so the image is pinned by
# digest; it stays here as long as RustFS runs, and is moved to Chainguard's newest digest before a
# late copy back.
minio_image=cgr.dev/chainguard/minio@sha256:7df55d002b698e4494a131b848dd553361bbe58b7e19f62d9623c29af1ba9ccf
s3_image=$(sed -n 's/^x-s3-image: *&s3-image *//p' "$repo/deploy/compose/compose.yaml")
[[ $s3_image == */*@sha256:* ]] || fail "no pinned image in the x-s3-image line of deploy/compose/compose.yaml"

minio_volume=${SVP_OBJCOPY_TEST_MINIO_VOLUME:-svp_minio-data}
s3_volume=${SVP_OBJCOPY_TEST_S3_VOLUME:-svp_s3-data}
database=${SVP_OBJCOPY_TEST_DATABASE:-svp_video}
env_file=${SVP_OBJCOPY_TEST_ENV_FILE:-$repo/.env}
# The test variables reach scratch volumes and test databases only, never other data.
for v in SVP_OBJCOPY_TEST_MINIO_VOLUME SVP_OBJCOPY_TEST_S3_VOLUME; do
  if [[ -n ${!v:-} && ! ${!v} =~ ^svp-scratch-[a-z0-9-]+$ ]]; then fail "$v must name a volume svp-scratch-*"; fi
done
if [[ -n ${SVP_OBJCOPY_TEST_DATABASE:-} && ! $database =~ ^svp_[a-z0-9_]+_test$ ]]; then
  fail "SVP_OBJCOPY_TEST_DATABASE must name a database svp_*_test"
fi
[[ $minio_volume != "$s3_volume" ]] || fail "the two volumes are the same"

if [[ $to == s3 ]]; then
  src_volume=$minio_volume dst_volume=$s3_volume src_name=MinIO dst_name=RustFS
else
  src_volume=$s3_volume dst_volume=$minio_volume src_name=RustFS dst_name=MinIO
fi

# --- Refusals that need nothing started. ---
running=$(dk ps -q --filter label=com.docker.compose.project=svp)
[[ -z $running ]] || fail "containers of the compose stack svp are running; run 'make down' first (it keeps the volumes)"
running=$(dk ps -q --filter label=k3d.cluster=svp; dk ps -q --filter 'name=^k3d-svp-')
[[ -z $running ]] || fail "the k3d cluster svp or its registry is running; run 'make k8s-down' first"
for v in "$minio_volume" "$s3_volume"; do
  running=$(dk ps -q --filter "volume=$v")
  [[ -z $running ]] || fail "a container using volume $v is running; stop it first"
done
dk volume inspect "$src_volume" > /dev/null 2>&1 || fail "volume $src_volume does not exist: no $src_name data to copy"

# dotenv_value has named the offending line (never a value) on stderr when it fails.
s3_root=$(dotenv_value "$env_file" SVP_S3_ROOT_PASSWORD) || fail "read $env_file"
[[ -n $s3_root ]] || fail "SVP_S3_ROOT_PASSWORD is missing or empty in $env_file; run make env"
# It goes into the client's MC_HOST_* URLs, as make env writes it.
[[ $s3_root =~ ^[0-9A-Za-z]+$ ]] || fail "SVP_S3_ROOT_PASSWORD in $env_file must be letters and digits only"

umask 077
work=$(mktemp -d)
run=svp-objcopy-$(openssl rand -hex 4)
# Every container and the network of this run carry both labels: the first is what the cleanup below
# removes, the second names the volume written to, so whatever a killed run left behind can be told
# apart from another copy's by its target alone.
own=(--label "svp.object-store-copy=$run" --label "svp.object-store-copy.to=$dst_volume")
network=
cleanup() {
  local rc=$? ids
  trap - EXIT INT TERM
  ids=$(dk ps -aq --filter "label=svp.object-store-copy=$run" 2> /dev/null || true)
  if [[ -n $ids ]]; then
    # Stopped first, so a store ends its writes cleanly; no -v, so no volume is removed.
    # shellcheck disable=SC2086 # one ID per word
    dk stop --time 30 $ids > /dev/null 2>&1 || true
    # shellcheck disable=SC2086
    dk rm $ids > /dev/null 2>&1 || { echo "object-store-copy: could not remove the containers labelled svp.object-store-copy=$run" >&2; rc=1; }
  fi
  if [[ -n $network ]]; then
    dk network rm "$network" > /dev/null 2>&1 || { echo "object-store-copy: could not remove network $network" >&2; rc=1; }
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- svp_video: SELECT only, in a read-only transaction. ---
pg() {
  PGOPTIONS='-c default_transaction_read_only=on' psql -h 127.0.0.1 -p 5432 -U postgres -d "$database" -w -X -q -At \
    -F $'\t' -v ON_ERROR_STOP=1 -c "$1"
}
processing=$(pg "SELECT count(*) FROM videos WHERE status = 'PROCESSING'") || fail "read the videos of $database"
[[ $processing == 0 ]] ||
  fail "$processing video(s) PROCESSING in $database: media-worker may still write them; wait until none is, then run again"
pg "SELECT id, coalesce(playlist_key, ''), coalesce(thumbnail_key, '') FROM videos WHERE status = 'READY' ORDER BY id" \
  > "$work/ready" || fail "read the READY videos of $database"
# The keys go into file paths and mc arguments: each must be media/<its video id>/<plain path>.
while IFS=$'\t' read -r id playlist thumbnail; do
  for k in "$playlist" "$thumbnail"; do
    [[ $k =~ ^media/$id/[A-Za-z0-9._/-]+$ && $k != *..* ]] || fail "READY video $id has a key outside media/$id/: '$k'"
  done
done < "$work/ready"

# --- The two stores and the client, on a network of their own. ---
network=$run
dk network create --internal "${own[@]}" "$network" > /dev/null
if ! dk volume inspect "$dst_volume" > /dev/null 2>&1; then
  labels=()
  # A volume of the compose project (svp_<name>) gets compose's labels, so `make up` takes it as declared.
  if [[ $dst_volume == svp_* ]]; then
    labels=(--label com.docker.compose.project=svp --label "com.docker.compose.volume=${dst_volume#svp_}")
  fi
  dk volume create ${labels[@]+"${labels[@]}"} "$dst_volume" > /dev/null
  say "created the empty volume $dst_volume"
fi
minio_root=$(openssl rand -hex 20)
# Neither store answers outside this network, and the MinIO console is off: nothing here needs it.
MINIO_ROOT_PASSWORD=$minio_root dk run -d --name "$run-minio" "${own[@]}" \
  --network "$network" --network-alias minio --memory 512m --cap-drop ALL --security-opt no-new-privileges:true \
  -e MINIO_ROOT_USER=svp-admin -e MINIO_ROOT_PASSWORD -e MINIO_BROWSER=off \
  -v "$minio_volume:/data" "$minio_image" server /data > /dev/null
# The settings of service s3 in compose.yaml, without its published port.
RUSTFS_SECRET_KEY=$s3_root dk run -d --name "$run-s3" "${own[@]}" \
  --network "$network" --network-alias s3 --memory 512m --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --user 10001:10001 \
  -e RUSTFS_ACCESS_KEY=svp-admin -e RUSTFS_SECRET_KEY -e RUSTFS_CONSOLE_ENABLE=false -e RUSTFS_CORS_ALLOWED_ORIGINS= \
  -e RUSTFS_CHECK_UPDATE=false -e RUSTFS_OBS_LOG_DIRECTORY= \
  -v "$s3_volume:/data" "$s3_image" > /dev/null
if [[ $to == s3 ]]; then
  src_url=http://svp-admin:$minio_root@minio:9000 dst_url=http://svp-admin:$s3_root@s3:9000
else
  src_url=http://svp-admin:$s3_root@s3:9000 dst_url=http://svp-admin:$minio_root@minio:9000
fi
client=$run-client
# --init: sleep, as PID 1, would ignore the stop signal and hold up the cleanup for its 30 s.
MC_HOST_src=$src_url MC_HOST_dst=$dst_url dk run -d --init --name "$client" "${own[@]}" \
  --network "$network" --memory 256m --cap-drop ALL --security-opt no-new-privileges:true \
  -e MC_HOST_src -e MC_HOST_dst --entrypoint sleep "$minio_image" infinity > /dev/null
unset minio_root s3_root src_url dst_url

mcx() { dk exec "$client" mc "$@"; }
for side in src dst; do
  deadline=$((SECONDS + 60))
  until mcx ls --json "$side" > /dev/null 2>&1; do
    ((SECONDS < deadline)) || fail "the $side store does not answer within 60 s (see docker logs of $run-minio, $run-s3)"
    sleep 1
  done
done
say "copying $src_name ($src_volume) to $dst_name ($dst_volume)"

# json_ok FILE WHAT: fails unless every line of mc's JSON output in FILE is a success.
json_ok() {
  jq -e -s 'all(.[]; .status == "success")' "$1" > /dev/null || fail "$2: $(jq -r 'select(.status != "success") | .error.message' "$1" | head -n 3)"
}
# buckets SIDE: the bucket names of SIDE, one per line, in $work/SIDE.buckets.
buckets() {
  mcx ls --json "$1" > "$work/raw" || fail "list the buckets of $1"
  json_ok "$work/raw" "list the buckets of $1"
  jq -r '.key | rtrimstr("/")' "$work/raw" > "$work/$1.buckets"
}
has_bucket() { grep -qx "$2" "$work/$1.buckets"; }
# list SIDE BUCKET: "key<TAB>size" of every object of BUCKET in $work/SIDE.BUCKET, sorted by key;
# empty when SIDE has no such bucket.
list() {
  : > "$work/$1.$2"
  has_bucket "$1" "$2" || return 0
  mcx ls --json --recursive "$1/$2" > "$work/raw" || fail "list $1/$2"
  json_ok "$work/raw" "list $1/$2"
  jq -r 'select(.type == "file") | "\(.key)\t\(.size)"' "$work/raw" | LC_ALL=C sort > "$work/$1.$2"
}
# types SIDE BUCKET: "key<TAB>Content-Type" of every object, sorted by key, in $work/SIDE.BUCKET.types;
# call it after list SIDE BUCKET. mc stat fails on an empty bucket, so one is not asked.
types() {
  : > "$work/$1.$2.types"
  [[ -s $work/$1.$2 ]] || return 0
  mcx stat --json --recursive "$1/$2" > "$work/raw" || fail "read the objects of $1/$2"
  json_ok "$work/raw" "read the objects of $1/$2"
  jq -r --arg b "$2/" 'select(.type == "file") | "\(.name | ltrimstr($b))\t\(.metadata["Content-Type"] // "")"' "$work/raw" |
    LC_ALL=C sort > "$work/$1.$2.types"
}
keys() { cut -f 1 "$1"; }
# report COUNT WHAT FILE: prints COUNT and up to five keys of FILE (first field).
report() {
  echo "object-store-copy:   $1 $2, for example:" >&2
  head -n 5 "$3" | cut -f 1 | sed 's/^/object-store-copy:     /' >&2
}

# --- Before any write: the target holds nothing the source does not. ---
buckets src
buckets dst
refused=
for b in uploads media; do
  list src "$b"
  list dst "$b"
  LC_ALL=C comm -13 <(keys "$work/src.$b") <(keys "$work/dst.$b") > "$work/only-dst.$b"
  LC_ALL=C join -t $'\t' "$work/src.$b" "$work/dst.$b" | awk -F '\t' '$2 != $3' > "$work/size.$b"
  n=$(wc -l < "$work/only-dst.$b" | tr -d ' ')
  if ((n > 0)); then
    echo "object-store-copy: $dst_name's bucket $b has $n key(s) that $src_name's lacks" >&2
    report "$n" "key(s) only at the target" "$work/only-dst.$b"
    refused=1
  fi
  n=$(wc -l < "$work/size.$b" | tr -d ' ')
  if ((n > 0)); then
    echo "object-store-copy: $n key(s) of bucket $b have another size at $dst_name than at $src_name" >&2
    report "$n" "key(s) with another size" "$work/size.$b"
    refused=1
  fi
done
[[ -z $refused ]] ||
  fail "refused, nothing written: copying would leave or hide data that is only at the target. Deleting it there is a decision of yours, outside this script; or copy to an empty volume"

# --- The keys READY videos need, read from the source, which now holds every key either side has. ---
LC_ALL=C sort -u <(keys "$work/src.media") > "$work/have"
present() { LC_ALL=C grep -qxF "$1" "$work/have"; }
# fetch KEYFILE: copies the media objects named in KEYFILE from the source into $work/pl/<key>.
fetch() {
  [[ -s $1 ]] || return 0
  dk exec "$client" rm -rf /tmp/pl
  dk exec -i "$client" bash -c 'while IFS= read -r k; do mc cp --quiet "src/media/$k" "/tmp/pl/$k" > /dev/null || exit 1; done' < "$1" ||
    fail "read playlists from the source"
  mkdir -p "$work/pl"
  dk cp "$client:/tmp/pl/." "$work/pl/" > /dev/null
}
# uris KEY: the keys that the playlist KEY (fetched) names, resolved against its directory. Only plain
# relative names inside the video's directory, as media-worker writes them.
uris() {
  local dir=${1%/*} line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ ^[A-Za-z0-9._/-]+$ && $line != /* && $line != *..* ]] ||
      fail "playlist $1 names '$line', not a plain relative name"
    echo "$dir/$line"
  done < "$work/pl/$1"
}
: > "$work/need"
: > "$work/masters"
while IFS=$'\t' read -r id playlist thumbnail; do
  printf '%s\n%s\n' "$playlist" "$thumbnail" >> "$work/need"
  if present "$playlist"; then echo "$playlist" >> "$work/masters"; fi
done < "$work/ready"
fetch "$work/masters"
: > "$work/renditions"
while IFS= read -r m; do
  uris "$m" > "$work/named"
  cat "$work/named" >> "$work/need"
  while IFS= read -r r; do if present "$r"; then echo "$r" >> "$work/renditions"; fi; done < "$work/named"
done < "$work/masters"
fetch "$work/renditions"
while IFS= read -r r; do uris "$r" >> "$work/need"; done < "$work/renditions"
LC_ALL=C sort -u "$work/need" | LC_ALL=C comm -23 - "$work/have" > "$work/lost"
lost=$(wc -l < "$work/lost" | tr -d ' ')
if ((lost > 0)); then
  say "$lost key(s) of READY videos are on neither store, lost before this copy (not copied, not blocking):"
  sed 's/^/object-store-copy:   /' "$work/lost"
fi

# --- The copy: add what the target lacks, never remove, never overwrite. ---
failed=
for b in uploads media; do
  mcx mb --ignore-existing "dst/$b" > /dev/null || fail "create bucket $b at $dst_name"
  copied=0
  if has_bucket src "$b"; then
    mcx mirror --json "src/$b" "dst/$b" > "$work/mirror.$b" || true
    # A key already at the target with the same size (checked above) is kept as it is. mc reports
    # it as an error when the source copy is newer; any other error is a failure.
    jq -r 'select(.status != "success") | .error.message + " " + (.error.cause.message // "")' "$work/mirror.$b" |
      grep -v 'Overwrite not allowed' > "$work/mirror-errors.$b" || true
    if [[ -s $work/mirror-errors.$b ]]; then
      echo "object-store-copy: mc mirror of bucket $b reported:" >&2
      head -n 5 "$work/mirror-errors.$b" | sed 's/^/object-store-copy:   /' >&2
      failed=1
    fi
    copied=$(jq -s '[.[] | select(.status == "success" and .source != null)] | length' "$work/mirror.$b")
  fi
  say "bucket $b: copied $copied object(s)"
done

# --- After the copy: the same keys and sizes on both sides, and the source's Content-Type at the target. ---
buckets src
buckets dst
for b in uploads media; do
  list src "$b"
  list dst "$b"
  if ! cmp -s "$work/src.$b" "$work/dst.$b"; then
    LC_ALL=C comm -23 "$work/src.$b" "$work/dst.$b" > "$work/diff.$b"
    LC_ALL=C comm -13 <(keys "$work/src.$b") <(keys "$work/dst.$b") > "$work/extra.$b"
    n=$(wc -l < "$work/diff.$b" | tr -d ' ')
    m=$(wc -l < "$work/extra.$b" | tr -d ' ')
    echo "object-store-copy: check failed: bucket $b differs between $src_name and $dst_name: $n source object(s) missing or of another size at the target, $m key(s) only at the target" >&2
    if ((n > 0)); then report "$n" "source object(s)" "$work/diff.$b"; fi
    if ((m > 0)); then report "$m" "key(s) only at the target" "$work/extra.$b"; fi
    failed=1
  fi
  types src "$b"
  types dst "$b"
  LC_ALL=C join -t $'\t' -a 1 -e '<none>' -o 0,1.2,2.2 "$work/src.$b.types" "$work/dst.$b.types" |
    awk -F '\t' '$2 != $3' > "$work/types.$b"
  n=$(wc -l < "$work/types.$b" | tr -d ' ')
  if ((n > 0)); then
    echo "object-store-copy: check failed: $n object(s) of bucket $b have another Content-Type at $dst_name, or are missing" >&2
    report "$n" "object(s)" "$work/types.$b"
    failed=1
  fi
  objects=$(wc -l < "$work/dst.$b" | tr -d ' ')
  bytes=$(awk -F '\t' '{ s += $2 } END { printf "%d", s }' "$work/dst.$b")
  say "bucket $b at $dst_name: $objects object(s), $bytes byte(s)"
done
say "READY videos' keys lost before this copy: $lost"
[[ -z $failed ]] || fail "check failed: keep running on $src_name, do not switch the stack to $dst_name"
say "ok: $dst_name holds every object of $src_name with the same key, size and Content-Type, and nothing else"
