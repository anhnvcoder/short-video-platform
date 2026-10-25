#!/usr/bin/env bash
# Tests for object-store-copy.sh on scratch data only: two volumes svp-scratch-objcopy-<hex>-minio
# and -s3, a database svp_objcopy_test on the native Postgres (127.0.0.1:5432) with a minimal videos
# table, and an env file with a random root password, all made here and removed on exit; the real
# volumes, svp_video and .env are never touched. Each case seeds the stores through containers of
# its own (removed before the script runs, which refuses while a container uses a volume), runs the
# script, then reads the target again: a refusal must leave it as it was, keys, sizes, ETags and
# modification times included, and create no bucket and no volume. It removes only what it made: the
# script's containers and networks are found by their target volume, one of this test's, so a copy
# running meanwhile is left alone, and the database only when this run created it. Prints one ok/FAIL
# line per check and exits non-zero when one fails. Written for bash 3.2 (the macOS /bin/bash); needs
# docker, psql, jq and openssl.
#
# Usage: deploy/compose/object-store-copy-test.sh [CASE...]   (default: every case, in order)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
script=$here/object-store-copy.sh
dk() { env -u DOCKER_DEFAULT_PLATFORM docker "$@"; }
minio_image=$(sed -n 's/^minio_image=//p' "$script")
s3_image=$(sed -n 's/^x-s3-image: *&s3-image *//p' "$repo/deploy/compose/compose.yaml")

umask 077
work=$(mktemp -d)
tag=svp-scratch-objcopy-$(openssl rand -hex 3)
db=svp_objcopy_test
s3_root=$(openssl rand -hex 20)
printf 'SVP_S3_ROOT_PASSWORD=%s\n' "$s3_root" > "$work/env"
export SVP_OBJCOPY_TEST_MINIO_VOLUME=$tag-minio SVP_OBJCOPY_TEST_S3_VOLUME=$tag-s3 SVP_OBJCOPY_TEST_DATABASE=$db \
  SVP_OBJCOPY_TEST_ENV_FILE=$work/env
failures=0
db_made=

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
die() {
  echo "FAIL  $1" >&2
  exit 1
}

psql_() { PGOPTIONS='-c client_min_messages=warning' psql -h 127.0.0.1 -p 5432 -U postgres -w -X -q -At -v ON_ERROR_STOP=1 "$@"; }

# script_containers, script_networks: what the script made in this test's runs, told apart by their
# target volume, one of this test's scratch volumes; another copy's resources never match.
script_containers() {
  local v
  for v in "$tag-minio" "$tag-s3"; do dk ps -aq --filter "label=svp.object-store-copy.to=$v"; done
}
script_networks() {
  local v
  for v in "$tag-minio" "$tag-s3"; do dk network ls -q --filter "label=svp.object-store-copy.to=$v"; done
}
# stores_down: removes this test's own seeding containers and network, never a volume.
stores_down() {
  local ids
  ids=$(dk ps -aq --filter "label=svp.objcopy-test=$tag")
  # shellcheck disable=SC2086 # one ID per word
  if [[ -n $ids ]]; then dk rm -f $ids > /dev/null; fi
  dk network rm "$tag" > /dev/null 2>&1 || true
}
cleanup() {
  local rc=$? ids
  trap - EXIT INT TERM
  stores_down || true
  dk network rm "$tag-foreign" > /dev/null 2>&1 || true
  # Anything the script left behind in this test's runs is a failure of the case that ran it; it is
  # removed here either way.
  ids=$(script_containers)
  # shellcheck disable=SC2086
  if [[ -n $ids ]]; then dk rm -f $ids > /dev/null || true; fi
  ids=$(script_networks)
  # shellcheck disable=SC2086
  if [[ -n $ids ]]; then dk network rm $ids > /dev/null || true; fi
  dk volume rm "$tag-minio" "$tag-s3" > /dev/null 2>&1 || true
  # Only a database this run made: one already there may belong to another run of this test.
  if [[ -n $db_made ]]; then psql_ -d postgres -c "DROP DATABASE IF EXISTS $db" > /dev/null || rc=1; fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -z $(dk ps -q --filter label=com.docker.compose.project=svp) ]] || die "the compose stack svp is running; run make down first"
[[ -z $(psql_ -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$db'") ]] ||
  die "database $db exists: another run of this test may be going, or one was killed; once none runs: psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'DROP DATABASE $db'"
psql_ -d postgres -c "CREATE DATABASE $db" > /dev/null
db_made=1
# The columns object-store-copy.sh reads, as in video-service's migrations.
psql_ -d "$db" -c "CREATE TABLE videos (id uuid PRIMARY KEY, status text NOT NULL, playlist_key text, thumbnail_key text)"

# rows ID:STATUS...: the videos table holds these rows only; READY ones get the keys media-worker writes.
rows() {
  local r id status sql="TRUNCATE videos;"
  for r in "$@"; do
    id=${r%%:*} status=${r#*:}
    if [[ $status == READY ]]; then
      sql+="INSERT INTO videos VALUES ('$id', 'READY', 'media/$id/master.m3u8', 'media/$id/thumbnail.jpg');"
    else
      sql+="INSERT INTO videos VALUES ('$id', '$status', NULL, NULL);"
    fi
  done
  psql_ -d "$db" -c "$sql"
}

# reset: both scratch volumes gone, so a case starts from nothing.
reset() {
  stores_down
  dk volume rm "$tag-minio" "$tag-s3" > /dev/null 2>&1 || true
}

# stores_up: MinIO on the -minio volume, RustFS on the -s3 one, and a client with aliases minio and s3,
# on an internal network of this test.
stores_up() {
  local minio_root deadline side
  minio_root=$(openssl rand -hex 20)
  dk network create --internal "$tag" > /dev/null
  MINIO_ROOT_PASSWORD=$minio_root dk run -d --name "$tag-minio" --label "svp.objcopy-test=$tag" --network "$tag" \
    --network-alias minio -e MINIO_ROOT_USER=svp-admin -e MINIO_ROOT_PASSWORD -v "$tag-minio:/data" \
    "$minio_image" server /data > /dev/null
  RUSTFS_SECRET_KEY=$s3_root dk run -d --name "$tag-s3" --label "svp.objcopy-test=$tag" --network "$tag" \
    --network-alias s3 --user 10001:10001 -e RUSTFS_ACCESS_KEY=svp-admin -e RUSTFS_SECRET_KEY \
    -e RUSTFS_CONSOLE_ENABLE=false -v "$tag-s3:/data" "$s3_image" > /dev/null
  MC_HOST_minio=http://svp-admin:$minio_root@minio:9000 MC_HOST_s3=http://svp-admin:$s3_root@s3:9000 \
    dk run -d --name "$tag-client" --label "svp.objcopy-test=$tag" --network "$tag" -e MC_HOST_minio -e MC_HOST_s3 \
    --entrypoint sleep "$minio_image" infinity > /dev/null
  for side in minio s3; do
    deadline=$((SECONDS + 60))
    until mct ls "$side" > /dev/null 2>&1; do
      ((SECONDS < deadline)) || die "seeding store $side does not answer within 60 s"
      sleep 1
    done
  done
}
mct() { dk exec "$tag-client" mc "$@"; }

# put SIDE BUCKET KEY TYPE FILE: uploads FILE with Content-Type TYPE, creating the bucket if needed.
put() {
  mct mb --ignore-existing "$1/$2" > /dev/null
  dk exec -i "$tag-client" bash -c 'cat > /tmp/o && mc cp --quiet --attr "Content-Type=$1" /tmp/o "$2" > /dev/null' \
    _ "$4" "$1/$2/$3" < "$5"
}
# blob SIZE: a new file of SIZE random bytes; prints its path.
blob() {
  local f
  f=$(mktemp "$work/blob.XXXXXX")
  head -c "$1" /dev/urandom > "$f"
  echo "$f"
}
# text CONTENT: a new file holding CONTENT (printf format); prints its path.
text() {
  local f
  f=$(mktemp "$work/text.XXXXXX")
  # shellcheck disable=SC2059 # the content is the format
  printf "$1" > "$f"
  echo "$f"
}
# video SIDE ID [SKIP_KEY]: the objects of a READY video as media-worker writes them (master, two
# renditions of two segments each, thumbnail) and its uploaded file; SKIP_KEY is left out.
video() {
  local side=$1 id=$2 skip=${3:-} r s
  maybe() { [[ $3 == "$skip" ]] || put "$side" "$1" "$3" "$2" "$4"; }
  maybe media application/vnd.apple.mpegurl "media/$id/master.m3u8" \
    "$(text '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n0/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n1/index.m3u8\n')"
  for r in 0 1; do
    maybe media application/vnd.apple.mpegurl "media/$id/$r/index.m3u8" \
      "$(text '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg_000.ts\n#EXTINF:2.5,\nseg_001.ts\n#EXT-X-ENDLIST\n')"
    for s in 000 001; do maybe media video/mp2t "media/$id/$r/seg_$s.ts" "$(blob 3000)"; done
  done
  maybe media image/jpeg "media/$id/thumbnail.jpg" "$(blob 1500)"
  maybe uploads video/mp4 "uploads/$id" "$(blob 7000)"
}

# snapshot SIDE: every bucket of SIDE, then "bucket key size etag lastModified" of each object.
snapshot() {
  local b
  for b in $(mct ls --json "$1" | jq -r '.key | rtrimstr("/")'); do
    echo "bucket $b"
    mct ls --json --recursive "$1/$b" | jq -r --arg b "$b" '"\($b) \(.key) \(.size) \(.etag) \(.lastModified)"'
  done
}
# types SIDE BUCKET: "key Content-Type" of every object.
types() {
  mct stat --json --recursive "$1/$2" | jq -r --arg b "$2/" '"\(.name | ltrimstr($b)) \(.metadata["Content-Type"])"' | LC_ALL=C sort
}

# copy TO NAME: runs the script towards TO; its output in $work/NAME.out, its status in $status.
copy() {
  status=0
  "$script" "$1" > "$work/$2.out" 2>&1 || status=$?
  if grep -qF "$s3_root" "$work/$2.out" || grep -q 'svp-admin:' "$work/$2.out"; then
    fail "$2: the output holds a password"
  fi
}
# leftovers NAME: no container or network of the script remains.
leftovers() {
  if [[ -n $(script_containers) || -n $(script_networks) ]]; then
    fail "$1: the script left a container or network behind"
  fi
}
# refused NAME TO SIDE WANT: the script towards TO exits 1 with WANT in its output, and SIDE (the
# target) is as it was before.
refused() {
  local name=$1 side=$3 want=$4
  stores_up
  snapshot "$side" > "$work/$name.before"
  stores_down
  copy "$2" "$name"
  leftovers "$name"
  stores_up
  snapshot "$side" > "$work/$name.after"
  stores_down
  if [[ $status -ne 1 ]] || ! grep -qF "$want" "$work/$name.out"; then
    fail "$name: want status 1 and '$want', got status $status:"
    sed 's/^/      /' "$work/$name.out" >&2
  elif ! cmp -s "$work/$name.before" "$work/$name.after"; then
    fail "$name: the target changed"
    diff "$work/$name.before" "$work/$name.after" | sed 's/^/      /' >&2 || true
  else
    ok "$name: refused ($(grep -m 1 -F "$want" "$work/$name.out" | sed 's/^object-store-copy: //' | cut -c 1-110)), target unchanged"
  fi
}
# same NAME FROM TO: both sides hold the same keys and sizes, and the same Content-Type for each.
same() {
  local b
  for b in uploads media; do
    if ! cmp -s <(mct ls --json --recursive "$2/$b" | jq -r '"\(.key) \(.size)"' | LC_ALL=C sort) \
      <(mct ls --json --recursive "$3/$b" | jq -r '"\(.key) \(.size)"' | LC_ALL=C sort); then
      fail "$1: bucket $b differs in keys or sizes"
    elif ! cmp -s <(types "$2" "$b") <(types "$3" "$b"); then
      fail "$1: bucket $b differs in Content-Type"
    else
      ok "$1: bucket $b the same on both sides ($(mct ls --recursive "$3/$b" | wc -l | tr -d ' ') objects, keys, sizes, Content-Type)"
    fi
  done
}

v1=11111111-1111-4111-8111-111111111111
v2=22222222-2222-4222-8222-222222222222
v3=33333333-3333-4333-8333-333333333333
v4=44444444-4444-4444-8444-444444444444
v5=55555555-5555-4555-8555-555555555555

# The forward copy of a READY video, an UPLOADING one with its file and a FAILED one, to a target
# volume that does not exist yet; then the same run again changes nothing.
case_forward() {
  reset
  rows "$v1:READY" "$v2:UPLOADING" "$v3:FAILED"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  # Over mc's 16 MiB part size, so the copy of an uploaded file goes multipart as a real one does.
  put minio uploads "uploads/$v2" video/mp4 "$(blob 20971520)"
  stores_down
  dk volume rm "$tag-s3" > /dev/null 2>&1 || true
  copy s3 forward
  leftovers forward
  if [[ $status -eq 0 ]] && grep -q 'ok: RustFS holds every object' "$work/forward.out"; then
    ok "forward: status 0 ($(grep -c 'copied' "$work/forward.out") buckets copied)"
  else
    fail "forward: want status 0, got $status:"
    sed 's/^/      /' "$work/forward.out" >&2
  fi
  stores_up
  same forward minio s3
  local want got
  want="media/$v1/0/seg_000.ts video/mp2t
media/$v1/master.m3u8 application/vnd.apple.mpegurl
media/$v1/thumbnail.jpg image/jpeg"
  got=$(types s3 media | grep -E '/0/seg_000.ts|master.m3u8|thumbnail.jpg')
  if [[ $got == "$want" && $(types s3 uploads) == "uploads/$v1 video/mp4"$'\n'"uploads/$v2 video/mp4" ]]; then
    ok "forward: HLS, JPEG and video Content-Types kept at the target"
  else
    fail "forward: Content-Types at the target: $got / $(types s3 uploads)"
  fi
  snapshot s3 > "$work/forward.snapshot"
  stores_down

  copy s3 again
  leftovers again
  stores_up
  snapshot s3 > "$work/again.snapshot"
  stores_down
  if [[ $status -eq 0 ]] && cmp -s "$work/forward.snapshot" "$work/again.snapshot" &&
    grep -q 'bucket media: copied 0 object' "$work/again.out" && grep -q 'bucket uploads: copied 0 object' "$work/again.out"; then
    ok "again: a second run copies nothing, changes nothing at the target and passes"
  else
    fail "again: status $status, target $(cmp -s "$work/forward.snapshot" "$work/again.snapshot" && echo unchanged || echo changed):"
    sed 's/^/      /' "$work/again.out" >&2
  fi
}

# Back to MinIO after a forward copy: RustFS gained a video, MinIO keeps its older copies of the rest.
case_back() {
  reset
  rows "$v1:READY" "$v4:READY"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  stores_down
  copy s3 back-forward
  [[ $status -eq 0 ]] || { fail "back: the forward copy failed (status $status)"; sed 's/^/      /' "$work/back-forward.out" >&2; return; }
  stores_up
  video s3 "$v4"
  stores_down
  copy minio back
  leftovers back
  if [[ $status -eq 0 ]] && grep -q 'ok: MinIO holds every object' "$work/back.out"; then
    ok "back: status 0, the video made on RustFS copied to MinIO, MinIO's older copies kept"
  else
    fail "back: want status 0, got $status:"
    sed 's/^/      /' "$work/back.out" >&2
  fi
  stores_up
  same back s3 minio
  stores_down
}

# A source with an empty bucket uploads and no bucket media: both buckets made, empty, at the target.
case_empty_buckets() {
  reset
  rows
  dk volume create "$tag-minio" > /dev/null
  stores_up
  mct mb minio/uploads > /dev/null
  stores_down
  copy s3 empty-buckets
  leftovers empty-buckets
  stores_up
  if [[ $status -eq 0 ]] && [[ $(snapshot s3) == "bucket media"$'\n'"bucket uploads" ]]; then
    ok "empty-buckets: status 0, buckets uploads and media made, empty, at the target"
  else
    fail "empty-buckets: want status 0 and two empty buckets, got status $status, target: $(snapshot s3 | tr '\n' ' ')"
    sed 's/^/      /' "$work/empty-buckets.out" >&2
  fi
  stores_down
}

# One segment of a READY video only at the target; the source has its playlists, thumbnail and file.
case_segment_only_at_target() {
  reset
  rows "$v1:READY"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1" "media/$v1/1/seg_001.ts"
  put s3 media "media/$v1/1/seg_001.ts" video/mp2t "$(blob 3000)"
  stores_down
  refused segment-only-at-target s3 s3 "1 key(s) that MinIO's lacks"
  stores_up
  if [[ -z $(mct ls --json s3 | jq -r 'select(.key == "uploads/")') ]]; then
    ok "segment-only-at-target: bucket uploads not created at the target"
  else
    fail "segment-only-at-target: bucket uploads was created at the target"
  fi
  stores_down
}

# The uploaded file of an UPLOADING video only at the target.
case_upload_only_at_target() {
  reset
  rows "$v1:READY" "$v2:UPLOADING"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  put s3 uploads "uploads/$v2" video/mp4 "$(blob 4000)"
  stores_down
  refused upload-only-at-target s3 s3 "bucket uploads has 1 key(s) that MinIO's lacks"
}

# The same key with another size on each side.
case_other_size() {
  reset
  rows "$v1:READY"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  put s3 media "media/$v1/thumbnail.jpg" image/jpeg "$(blob 1499)"
  stores_down
  refused other-size s3 s3 "1 key(s) of bucket media have another size"
}

# An empty source (no bucket at all) and a target with an object.
case_empty_source() {
  reset
  rows
  dk volume create "$tag-minio" > /dev/null
  stores_up
  put s3 uploads "uploads/$v2" video/mp4 "$(blob 4000)"
  stores_down
  refused empty-source s3 s3 "1 key(s) that MinIO's lacks"
}

# A video PROCESSING: refused before anything starts; the missing target volume is not created.
case_processing() {
  reset
  rows "$v1:READY" "$v2:PROCESSING"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  stores_down
  dk volume rm "$tag-s3" > /dev/null
  copy s3 processing
  leftovers processing
  if [[ $status -eq 1 ]] && grep -q '1 video(s) PROCESSING' "$work/processing.out" &&
    ! dk volume inspect "$tag-s3" > /dev/null 2>&1; then
    ok "processing: refused, target volume not created"
  else
    fail "processing: want status 1, PROCESSING named and no target volume; got status $status:"
    sed 's/^/      /' "$work/processing.out" >&2
  fi
}

# Keys a READY video needs on neither side, a segment its playlist names included: listed, not blocking.
case_lost_before() {
  reset
  rows "$v1:READY" "$v4:READY" "$v5:READY"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  video minio "$v4" "media/$v4/0/seg_001.ts"
  stores_down
  copy s3 lost-before
  leftovers lost-before
  if [[ $status -eq 0 ]] && grep -q "lost before this copy: 3$" "$work/lost-before.out" &&
    grep -q "  media/$v4/0/seg_001.ts$" "$work/lost-before.out" && grep -q "  media/$v5/master.m3u8$" "$work/lost-before.out" &&
    grep -q "  media/$v5/thumbnail.jpg$" "$work/lost-before.out"; then
    ok "lost-before: status 0, the segment and the two keys of a video gone from both sides listed"
  else
    fail "lost-before: want status 0 and three keys listed, got status $status:"
    sed 's/^/      /' "$work/lost-before.out" >&2
  fi
}

# TO other than s3 or minio: usage, nothing done.
case_bad_to() {
  reset
  status=0
  "$script" rustfs > "$work/bad-to.out" 2>&1 || status=$?
  local status_none=0
  "$script" > "$work/bad-to-none.out" 2>&1 || status_none=$?
  if [[ $status -eq 2 && $status_none -eq 2 ]] && grep -q '^usage:' "$work/bad-to.out" &&
    ! dk volume inspect "$tag-minio" > /dev/null 2>&1 && ! dk volume inspect "$tag-s3" > /dev/null 2>&1; then
    ok "bad-to: TO=rustfs and no TO print the usage, exit 2, create nothing"
  else
    fail "bad-to: want usage and status 2, got $status and $status_none"
  fi
}

# A running container of the compose project svp, or a node of the k3d cluster svp: refused.
case_stack_running() {
  local label id
  reset
  rows
  dk volume create "$tag-minio" > /dev/null
  for label in com.docker.compose.project=svp k3d.cluster=svp; do
    id=$(dk run -d --label "$label" --label "svp.objcopy-test=$tag" --network none --entrypoint sleep "$minio_image" 300)
    copy s3 stack-running
    dk rm -f "$id" > /dev/null
    leftovers stack-running
    if [[ $status -eq 1 ]] && grep -qE 'compose stack svp|k3d cluster svp' "$work/stack-running.out" &&
      ! dk volume inspect "$tag-s3" > /dev/null 2>&1; then
      ok "stack-running: a container labelled $label refuses the copy, creating nothing"
    else
      fail "stack-running: $label: want status 1, got $status:"
      sed 's/^/      /' "$work/stack-running.out" >&2
    fi
  done
}

# Any running container that uses one of the two volumes: refused.
case_volume_in_use() {
  local id
  reset
  rows
  dk volume create "$tag-minio" > /dev/null
  dk volume create "$tag-s3" > /dev/null
  id=$(dk run -d --init --label "svp.objcopy-test=$tag" --network none -v "$tag-s3:/data" --entrypoint sleep "$minio_image" 300)
  copy s3 volume-in-use
  dk rm -f "$id" > /dev/null
  leftovers volume-in-use
  if [[ $status -eq 1 ]] && grep -q "a container using volume $tag-s3 is running" "$work/volume-in-use.out"; then
    ok "volume-in-use: a running container on the target volume refuses the copy"
  else
    fail "volume-in-use: want status 1, got $status:"
    sed 's/^/      /' "$work/volume-in-use.out" >&2
  fi
}

# Stopped mid-run (TERM, as a Ctrl-C does): the containers and network go, both volumes stay.
case_interrupted() {
  local pid deadline rc=0
  reset
  rows "$v1:READY"
  dk volume create "$tag-minio" > /dev/null
  stores_up
  video minio "$v1"
  stores_down
  "$script" s3 > "$work/interrupted.out" 2>&1 &
  pid=$!
  deadline=$((SECONDS + 60))
  # The label this test finds the script's resources by: without it, leftovers would go unseen.
  until [[ -n $(dk ps -q --filter "label=svp.object-store-copy.to=$tag-s3") ]]; do
    ((SECONDS < deadline)) || { fail "interrupted: no running container labelled svp.object-store-copy.to=$tag-s3 within 60 s"; break; }
    sleep 0.2
  done
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  leftovers interrupted
  if [[ $rc -eq 143 ]] && dk volume inspect "$tag-minio" > /dev/null 2>&1 && dk volume inspect "$tag-s3" > /dev/null 2>&1 &&
    [[ -z $(script_containers) ]]; then
    ok "interrupted: status 143, containers and network removed, both volumes kept"
  else
    fail "interrupted: status $rc:"
    sed 's/^/      /' "$work/interrupted.out" >&2
  fi
}

# Another copy runs (its container and network, labelled as the script labels them, target the real
# volume) while a second run of this test stops before its first case, since this run holds the
# database: that run's cleanup leaves the other copy and this run's database alone.
case_foreign_copy() {
  local id net rc=0 state
  id=$(dk run -d --init --label svp.object-store-copy=svp-objcopy-foreign --label svp.object-store-copy.to=svp_s3-data \
    --label "svp.objcopy-test=$tag" --network none --entrypoint sleep "$minio_image" 300)
  net=$(dk network create --internal --label svp.object-store-copy=svp-objcopy-foreign \
    --label svp.object-store-copy.to=svp_s3-data "$tag-foreign")
  "$0" bad_to > "$work/foreign-copy.out" 2>&1 || rc=$?
  # Nor is the other copy taken for something this run's script left behind.
  leftovers foreign-copy
  if [[ $rc -eq 1 ]] && grep -q "database $db exists" "$work/foreign-copy.out" &&
    [[ $(dk inspect -f '{{.State.Running}}' "$id" 2> /dev/null) == true ]] && dk network inspect "$net" > /dev/null 2>&1 &&
    [[ -n $(psql_ -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$db'") ]]; then
    ok "foreign-copy: a second run refused; another copy's container and network and this run's database kept"
  else
    state=$(dk inspect -f '{{.State.Status}}' "$id" 2> /dev/null) || state=gone
    fail "foreign-copy: status $rc, container $state, network $(dk network inspect "$net" > /dev/null 2>&1 && echo kept || echo gone):"
    sed 's/^/      /' "$work/foreign-copy.out" >&2
  fi
  # Either may be gone already when the check failed; the cleanup removes what is left by label and name.
  dk rm -f "$id" > /dev/null 2>&1 || true
  dk network rm "$net" > /dev/null 2>&1 || true
}

cases=(forward back empty_buckets segment_only_at_target upload_only_at_target other_size empty_source processing lost_before bad_to
  stack_running volume_in_use interrupted foreign_copy)
if (($#)); then cases=("$@"); fi
start=$SECONDS
for c in "${cases[@]}"; do "case_$c"; done
echo "$((SECONDS - start)) s"
if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
