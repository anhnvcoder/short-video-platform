#!/usr/bin/env bash
# Creates the stage 2 topics and their dead-letter topics on the compose Redpanda
# (docs/adr/0008-async-upload-pipeline-stage2a.md, section 5;
# docs/adr/0009-engagement-feed-stage2b.md, section 11). Run by the one-shot redpanda-init
# container; the broker comes from RPK_BROKERS, the Admin API from RPK_ADMIN_HOSTS. Idempotent:
# a topic that already exists is left as it is, and the cluster property is set to the same value.
set -euo pipefail

week_ms=604800000
two_weeks_ms=1209600000

# create NAME PARTITIONS RETENTION_MS. rpk reports a failed create on stdout, in its result
# table, so the output is kept and printed when the command fails.
create() {
  local out
  if ! out=$(rpk topic create "$1" --if-not-exists -p "$2" -r 1 -c "retention.ms=$3" 2>&1); then
    printf '%s\n' "$out" >&2
    echo "redpanda-init: creating topic $1 failed" >&2
    return 1
  fi
  echo "redpanda-init: topic $1 ok"
}

create video.lifecycle.v1 3 "$week_ms"
create media.transcodes.v1 3 "$week_ms"
create user.follows.v1 3 "$week_ms"
create engagement.views.v1 3 "$week_ms"
create video.lifecycle.v1.dlq 1 "$two_weeks_ms"
create media.transcodes.v1.dlq 1 "$two_weeks_ms"
create user.follows.v1.dlq 1 "$two_weeks_ms"
create engagement.views.v1.dlq 1 "$two_weeks_ms"

# Consumer group lag metrics on /public_metrics, scraped by the obs Collector
# (docs/adr/0011-observability-stage3.md, section 5). Set through the Admin API, not
# .bootstrap.yaml: that file only applies when a cluster first forms, so a volume created earlier
# would never get it.
if ! out=$(rpk cluster config set enable_consumer_group_metrics '[group,partition,consumer_lag]' 2>&1); then
  printf '%s\n' "$out" >&2
  echo "redpanda-init: setting enable_consumer_group_metrics failed" >&2
  exit 1
fi
echo "redpanda-init: enable_consumer_group_metrics ok"
