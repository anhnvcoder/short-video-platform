#!/usr/bin/env bash
# Creates the SASL SCRAM-SHA-256 user of each Kafka client and grants it the least ACLs it needs
# (threat model IN-4, FF-6): a service writes only the topics of
# the events it owns (and the dead-letter topics of the topics it consumes), reads only the topics it consumes, with
# its own consumer group only. No application user gets CREATE, ALTER, DELETE or any right on the cluster.
# Run by the redpanda-init Job of chart svp-data after create-topics.sh, as the superuser svp-admin (RPK_USER,
# RPK_PASS, RPK_SASL_MECHANISM in the environment). Idempotent: an existing user gets its password reset to the
# current one, and creating an ACL that exists is a no-op.
#
# Each user's password is the file of that name in $KAFKA_USERS_DIR (Secret kafka-users). rpk takes a new user's
# password only as a flag, so it is on the command line of rpk inside this Job's container alone; it is never printed.
set -euo pipefail

users_dir=${KAFKA_USERS_DIR:?}

# run DESCRIPTION COMMAND...: runs an rpk command quietly; rpk reports some failures in its result table on stdout, so
# the output is kept and printed (it holds no password) when the command fails.
run() {
  local what=$1 out
  shift
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out" >&2
    echo "redpanda-init: $what failed" >&2
    return 1
  fi
}

existing=$(rpk security user list --format json) || {
  echo "redpanda-init: listing SASL users failed" >&2
  exit 1
}

# user NAME: creates NAME with the password in $users_dir/NAME, or sets that password when NAME exists.
user() {
  local pw
  pw=$(<"$users_dir/$1")
  if [[ -z $pw ]]; then
    echo "redpanda-init: the password of $1 is empty in Secret kafka-users; run make env, then make k8s-secrets" >&2
    return 1
  fi
  if grep -Fq "\"$1\"" <<<"$existing"; then
    run "updating user $1" rpk security user update "$1" --new-password "$pw" --mechanism SCRAM-SHA-256
  else
    run "creating user $1" rpk security user create "$1" --new-password "$pw" --mechanism SCRAM-SHA-256
  fi
  echo "redpanda-init: user $1 ok"
}

# allow USER OPERATION --topic T... | --group G...: grants USER the operation on the named topics or groups, matched by
# exact name (literal), never by prefix.
allow() {
  local who=$1 op=$2
  shift 2
  run "granting $op to $who on $*" rpk security acl create --allow-principal "User:$who" --operation "$op" \
    --resource-pattern-type literal "$@"
  echo "redpanda-init: acl $who $op $* ok"
}

# The ACL table (each service may touch only the topics and groups its code uses); topic and group
# names are those in the services' code. Producers are idempotent, which Redpanda allows with WRITE on any topic (no
# IDEMPOTENT_WRITE on the cluster); READ and WRITE imply DESCRIBE, which metadata and offset lookups need.
user svp-user-service
allow svp-user-service write --topic user.follows.v1

user svp-video-service
allow svp-video-service write --topic video.lifecycle.v1 --topic media.transcodes.v1.dlq
allow svp-video-service read --topic media.transcodes.v1
allow svp-video-service read --group video-service

user svp-engagement-service
allow svp-engagement-service write --topic engagement.views.v1 --topic engagement.views.v1.dlq
allow svp-engagement-service read --topic engagement.views.v1
allow svp-engagement-service read --group engagement-service

user svp-feed-service
allow svp-feed-service write --topic user.follows.v1.dlq --topic video.lifecycle.v1.dlq
allow svp-feed-service read --topic user.follows.v1 --topic video.lifecycle.v1
allow svp-feed-service read --group feed-service

user svp-media-worker
allow svp-media-worker write --topic media.transcodes.v1 --topic video.lifecycle.v1.dlq
allow svp-media-worker read --topic video.lifecycle.v1
allow svp-media-worker read --group media-worker

# KEDA's Kafka scaler only reads the lag of media-worker's group: metadata of the topic, the group's committed and the
# partitions' end offsets. DESCRIBE alone gives that and lets it neither consume nor join the group.
user svp-keda
allow svp-keda describe --topic video.lifecycle.v1
allow svp-keda describe --group media-worker
