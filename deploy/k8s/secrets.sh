#!/usr/bin/env bash
# Creates or updates the cluster's Secrets from .env (docs/adr/0014-kubernetes-local-stage4.md, section 8): .env stays
# the one source of local secrets for compose and the cluster, and no Secret is ever in git. Read with the strict rule
# of deploy/observability/glitchtip/dotenv.sh, the one compose agrees with.
#
# Every value is read and checked before anything is applied: a variable missing or empty in .env (a clone from before
# the variable existed) stops the script naming it, with no Secret created or changed. The manifests go to
# `kubectl apply --server-side` on stdin, never through a file or a command line, and no value is printed.
# Server-side apply also keeps the values out of the last-applied-configuration annotation that a client-side apply
# would copy them into.
#
# Run by deploy/k8s/install.sh once chart svp-cluster has created the namespaces, before any chart that reads these
# Secrets; on its own with `make k8s-secrets` (after changing .env; then `make k8s-up` runs the init Jobs again, which
# set the new passwords in Postgres, MinIO and Redpanda, and restarts each service whose Secret changed). A changed
# password of Redpanda's superuser is set in the running broker before any Secret is applied, and the script stops
# when the broker does not run to take it (see redpanda_admin below). MinIO or Redpanda running with another password
# than the one now in .env is restarted (see the end of this script).
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo_root/deploy/observability/glitchtip/dotenv.sh"

env_file="$repo_root/.env"
[ -f "$env_file" ] || fail ".env not found; run make env"

# Read every variable below into a shell variable of the same name.
vars=(SVP_PG_SUPERUSER_PASSWORD
  SVP_USER_MIGRATOR_DB_PASSWORD SVP_USER_APP_DB_PASSWORD SVP_VIDEO_MIGRATOR_DB_PASSWORD SVP_VIDEO_APP_DB_PASSWORD
  SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD SVP_ENGAGEMENT_APP_DB_PASSWORD SVP_FEED_MIGRATOR_DB_PASSWORD
  SVP_FEED_APP_DB_PASSWORD SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD
  SVP_MINIO_ROOT_PASSWORD SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY
  SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_KEDA_PASSWORD SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD
  SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD
  JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS SVP_GRAFANA_ADMIN_PASSWORD
  GLITCHTIP_SECRET_KEY GLITCHTIP_ADMIN_EMAIL GLITCHTIP_ADMIN_PASSWORD)
missing=
for v in "${vars[@]}"; do
  # dotenv_value has named the offending line (never a value) on stderr when it fails.
  val=$(dotenv_value "$env_file" "$v") || fail "read $env_file"
  [ -n "$val" ] || missing="$missing $v"
  printf -v "$v" '%s' "$val"
done
[ -z "$missing" ] || fail ".env lacks or has empty:$missing; run make env, then this again"
# Telegram is optional: the learner fills in both variables by hand, and without them alerts stay in the UI.
SVP_ALERT_TELEGRAM_BOT_TOKEN=$(dotenv_value "$env_file" SVP_ALERT_TELEGRAM_BOT_TOKEN) || fail "read $env_file"
SVP_ALERT_TELEGRAM_CHAT_ID=$(dotenv_value "$env_file" SVP_ALERT_TELEGRAM_CHAT_ID) || fail "read $env_file"

for ns in svp-data svp svp-obs; do
  kc get namespace "$ns" >/dev/null 2>&1 || fail "namespace $ns not found; run make k8s-up"
done

manifests() {
  # Superuser of the Postgres svp-pg: CloudNativePG sets its password from this Secret, and the pg-bootstrap Job logs
  # in with it. No service gets it. CloudNativePG follows changes only to the Secrets it made itself or to those
  # labelled cnpg.io/reload; without the label a changed password stays out of Postgres until something else makes the
  # operator reconcile the Cluster, and the pg-bootstrap Job, which logs in with it, fails.
  label='cnpg.io/reload: "true"' secret svp-data pg-superuser kubernetes.io/basic-auth \
    username=postgres password="$SVP_PG_SUPERUSER_PASSWORD"
  # Passwords of each service's migrator and app roles, for the pg-bootstrap Job (deploy/postgres/bootstrap.sql).
  secret svp-data pg-roles Opaque \
    SVP_USER_MIGRATOR_DB_PASSWORD="$SVP_USER_MIGRATOR_DB_PASSWORD" \
    SVP_USER_APP_DB_PASSWORD="$SVP_USER_APP_DB_PASSWORD" \
    SVP_VIDEO_MIGRATOR_DB_PASSWORD="$SVP_VIDEO_MIGRATOR_DB_PASSWORD" \
    SVP_VIDEO_APP_DB_PASSWORD="$SVP_VIDEO_APP_DB_PASSWORD" \
    SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD="$SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD" \
    SVP_ENGAGEMENT_APP_DB_PASSWORD="$SVP_ENGAGEMENT_APP_DB_PASSWORD" \
    SVP_FEED_MIGRATOR_DB_PASSWORD="$SVP_FEED_MIGRATOR_DB_PASSWORD" \
    SVP_FEED_APP_DB_PASSWORD="$SVP_FEED_APP_DB_PASSWORD" \
    SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD="$SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD" \
    SVP_GLITCHTIP_APP_DB_PASSWORD="$SVP_GLITCHTIP_APP_DB_PASSWORD"
  # MinIO's root login, as in compose (deploy/minio/init.sh logs in as svp-admin): MinIO and its init Job only.
  secret svp-data minio-root Opaque \
    MINIO_ROOT_USER=svp-admin MINIO_ROOT_PASSWORD="$SVP_MINIO_ROOT_PASSWORD"
  # Secret keys of the MinIO users svp-video-service and svp-media-worker, for the minio-init Job.
  secret svp-data minio-users Opaque \
    SVP_VIDEO_S3_SECRET_KEY="$SVP_VIDEO_S3_SECRET_KEY" \
    SVP_MEDIA_WORKER_S3_SECRET_KEY="$SVP_MEDIA_WORKER_S3_SECRET_KEY"
  # Redpanda's only superuser, svp-admin: the chart's bootstrap user and sidecar, and the redpanda-init Job. The
  # chart makes every line of redpanda-superusers a superuser, so it holds svp-admin alone.
  secret svp-data redpanda-bootstrap Opaque \
    password="$SVP_KAFKA_ADMIN_PASSWORD"
  secret svp-data redpanda-superusers Opaque \
    users.txt="svp-admin:$SVP_KAFKA_ADMIN_PASSWORD:SCRAM-SHA-256"
  # Password of each application's Kafka user, one key per user name, for the redpanda-init Job.
  secret svp-data kafka-users Opaque \
    svp-keda="$SVP_KAFKA_KEDA_PASSWORD" \
    svp-user-service="$SVP_KAFKA_USER_SERVICE_PASSWORD" \
    svp-video-service="$SVP_KAFKA_VIDEO_SERVICE_PASSWORD" \
    svp-engagement-service="$SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD" \
    svp-feed-service="$SVP_KAFKA_FEED_SERVICE_PASSWORD" \
    svp-media-worker="$SVP_KAFKA_MEDIA_WORKER_PASSWORD"
}

# pg_url SERVICE ROLE PASSWORD: the connection string of role svp_<SERVICE>_<ROLE> to database svp_<SERVICE> on
# svp-pg. sslmode=require: the server's certificate is CloudNativePG's own, so the link is encrypted but the CA is not
# checked (that is IN-3, stage 6). The passwords are hex, so nothing needs URL-encoding.
pg_url() { printf 'postgres://svp_%s_%s:%s@svp-pg-rw.svp-data:5432/svp_%s?sslmode=require' "$1" "$2" "$3" "$1"; }

# The services' Secrets in svp, one per pod, each with only what that pod uses (ADR section 8). <service>-env goes to
# the service's container as environment variables; <service>-migrate-env holds the migrator role, for the migrate
# Job only. The JWT signing key is in user-service-env alone; the gateway gets the public keys (threat model JWT-10).
svp_manifests() {
  secret svp user-service-env Opaque \
    DATABASE_URL="$(pg_url user app "$SVP_USER_APP_DB_PASSWORD")" \
    JWT_SIGNING_KID="$JWT_SIGNING_KID" JWT_SIGNING_KEY="$JWT_SIGNING_KEY" \
    KAFKA_SASL_USERNAME=svp-user-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_USER_SERVICE_PASSWORD"
  secret svp video-service-env Opaque \
    DATABASE_URL="$(pg_url video app "$SVP_VIDEO_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-video-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_VIDEO_SERVICE_PASSWORD" \
    S3_SECRET_ACCESS_KEY="$SVP_VIDEO_S3_SECRET_KEY"
  secret svp engagement-service-env Opaque \
    DATABASE_URL="$(pg_url engagement app "$SVP_ENGAGEMENT_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-engagement-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD"
  secret svp feed-service-env Opaque \
    DATABASE_URL="$(pg_url feed app "$SVP_FEED_APP_DB_PASSWORD")" \
    KAFKA_SASL_USERNAME=svp-feed-service KAFKA_SASL_PASSWORD="$SVP_KAFKA_FEED_SERVICE_PASSWORD"
  secret svp media-worker-env Opaque \
    KAFKA_SASL_USERNAME=svp-media-worker KAFKA_SASL_PASSWORD="$SVP_KAFKA_MEDIA_WORKER_PASSWORD" \
    S3_SECRET_ACCESS_KEY="$SVP_MEDIA_WORKER_S3_SECRET_KEY"
  secret svp gateway-env Opaque \
    JWT_VERIFY_KEYS="$JWT_VERIFY_KEYS"
  secret svp user-service-migrate-env Opaque DATABASE_URL="$(pg_url user migrator "$SVP_USER_MIGRATOR_DB_PASSWORD")"
  secret svp video-service-migrate-env Opaque DATABASE_URL="$(pg_url video migrator "$SVP_VIDEO_MIGRATOR_DB_PASSWORD")"
  secret svp engagement-service-migrate-env Opaque \
    DATABASE_URL="$(pg_url engagement migrator "$SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD")"
  secret svp feed-service-migrate-env Opaque DATABASE_URL="$(pg_url feed migrator "$SVP_FEED_MIGRATOR_DB_PASSWORD")"
}

# Redpanda user svp-keda for KEDA's Kafka scaler (ClusterTriggerAuthentication keda-kafka of chart svp-data, which
# media-worker's ScaledObject names), keys named after the scaler's parameters: SCRAM-SHA-256 without TLS, like the
# services. It may only DESCRIBE video.lifecycle.v1 and group media-worker, enough to read the group's lag. In
# namespace keda, the only one whose Secrets the KEDA operator may read (deploy/k8s/values/keda.yaml).
keda_manifests() {
  secret keda keda-kafka Opaque \
    sasl=scram_sha256 tls=disable username=svp-keda password="$SVP_KAFKA_KEDA_PASSWORD"
}

# Alertmanager's routing, the one deploy/observability/alertmanager/entrypoint.sh writes for compose (keep the two in
# step; ADR-0011 section 8): alerts grouped by name and severity, severity="page" to Telegram when .env has both a bot
# token and an integer chat id, everything else (and every alert, without Telegram) only listed in the UI and API.
# severity="ticket" always stays in the UI: the 1d/3d SLO windows keep firing for days after a drill. The bot token is
# never in this config: Alertmanager reads it from the file Secret alertmanager-telegram is mounted as
# (alertmanagerSpec.secrets of deploy/k8s/values/kube-prometheus-stack.yaml). The chat id is in it, as in compose; it
# is an identifier, not a credential.
telegram=off
if [ -n "$SVP_ALERT_TELEGRAM_BOT_TOKEN" ] && [ -n "$SVP_ALERT_TELEGRAM_CHAT_ID" ]; then
  # chat_id is an integer in Alertmanager's config; anything else would make the operator refuse the whole config.
  if printf '%s' "$SVP_ALERT_TELEGRAM_CHAT_ID" | grep -Eqx -- '-?[0-9]+'; then
    telegram=on
  else
    echo "SVP_ALERT_TELEGRAM_CHAT_ID in .env is not an integer; Telegram receiver off" >&2
  fi
fi
alertmanager_config() {
  local page_receiver=ui-only
  if [ "$telegram" = on ]; then page_receiver=telegram; fi
  cat <<EOF
route:
  receiver: ui-only
  group_by: [alertname, severity]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  routes:
    - matchers: ['severity="page"']
      receiver: $page_receiver
receivers:
  # No integration: alerts routed here are only listed in the UI and API.
  - name: ui-only
EOF
  if [ "$telegram" = on ]; then
    cat <<EOF
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager/secrets/alertmanager-telegram/bot_token
        chat_id: $SVP_ALERT_TELEGRAM_CHAT_ID
        send_resolved: true
EOF
  fi
}

# The Secrets of svp-obs (ADR section 8):
# - grafana-admin, Grafana's admin login (kube-prometheus-stack, grafana.admin.existingSecret): Grafana allows no
#   anonymous user in the cluster (threat model OPS-2), so this is the only way in. Grafana sets the admin password
#   from it when its database is created, which is at every start since it keeps no volume.
# - alertmanager-svp, the config above (alertmanagerSpec.configSecret; the key must be alertmanager.yaml).
# - alertmanager-telegram, the bot token, empty while Telegram is off: Alertmanager's pod mounts it in any case, and
#   would not start without it.
# - glitchtip-env, GlitchTip's Django secret key and its two database logins on svp-pg: the app role for the server,
#   the migrator role (MAINTENANCE_DATABASE_URL) for the migrations of its init Job. GlitchTip and its init Job only.
# - glitchtip-admin, the admin login bootstrap.py creates (its password is set only when the user is created, as in
#   compose). The init Job only.
obs_manifests() {
  local token=
  if [ "$telegram" = on ]; then token=$SVP_ALERT_TELEGRAM_BOT_TOKEN; fi
  secret svp-obs grafana-admin Opaque \
    admin-user=admin admin-password="$SVP_GRAFANA_ADMIN_PASSWORD"
  secret svp-obs alertmanager-svp Opaque alertmanager.yaml="$(alertmanager_config)"
  secret svp-obs alertmanager-telegram Opaque bot_token="$token"
  secret svp-obs glitchtip-env Opaque \
    SECRET_KEY="$GLITCHTIP_SECRET_KEY" \
    DATABASE_URL="$(pg_url glitchtip app "$SVP_GLITCHTIP_APP_DB_PASSWORD")" \
    MAINTENANCE_DATABASE_URL="$(pg_url glitchtip migrator "$SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD")"
  secret svp-obs glitchtip-admin Opaque \
    GLITCHTIP_ADMIN_EMAIL="$GLITCHTIP_ADMIN_EMAIL" GLITCHTIP_ADMIN_PASSWORD="$GLITCHTIP_ADMIN_PASSWORD"
}

# Redpanda, unlike MinIO, keeps its superuser svp-admin with its password in its own data: it creates it from Secret
# redpanda-bootstrap once, when the cluster forms, and never reads that Secret again. Every container that logs in as
# svp-admin (the broker's rpk, the sidecar that keeps the superusers in step, the redpanda-init Job) takes the password
# from that Secret when it starts. A changed password applied to the Secret alone would lock all of them out as soon
# as they start again, with the password Redpanda knows gone from everywhere; restarting MinIO, which reads its root
# password from its environment at every start, is all MinIO needs (below).
#
# redpanda_admin: makes Redpanda take the password in .env for svp-admin before any Secret is applied. Inside the
# broker container it logs in with that password; when that fails, with the one of Secret redpanda-bootstrap, then
# with the one the container started with, and sets the new one. It stops the script, before anything is applied,
# when the password changes and no broker runs to take it. The passwords go to the container on stdin; the new one is
# on rpk's command line inside that container only, as in the redpanda-init Job.
redpanda_admin() {
  local current ready err rc=0
  # No data volume yet: the cluster that forms takes svp-admin from the Secret applied below.
  kc -n svp-data get pvc datadir-redpanda-0 >/dev/null 2>&1 || return 0
  current=$(kc -n svp-data get secret redpanda-bootstrap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) ||
    current=
  # The broker container is ready once the Admin API reports it ready (its startup probe); the sidecar's readiness
  # needs svp-admin's login, so it is not waited for.
  ready=$(kc -n svp-data get pod redpanda-0 \
    -o jsonpath='{.status.containerStatuses[?(@.name=="redpanda")].ready}' 2>/dev/null) || true
  if [ "$ready" != true ]; then
    # Nothing changes for Redpanda when the Secret already holds this password. A missing Secret is applied all the
    # same: without it the broker cannot start at all.
    if [ -z "$current" ] || [ "$current" = "$SVP_KAFKA_ADMIN_PASSWORD" ]; then return 0; fi
    fail "SVP_KAFKA_ADMIN_PASSWORD in .env differs from Secret redpanda-bootstrap and broker redpanda-0 is not running to take it; no Secret was changed. Wait until it runs (scaled to 0: kubectl --context k3d-svp -n svp-data scale statefulset redpanda --replicas=1) and run make k8s-secrets again, or put the previous value back in .env"
  fi
  # Exit 10 inside the container means "set", 3 "no password logs in", 4 "the update failed", 5 "the Admin API gave
  # no answer on the password" (refused, timed out, anything but a rejected login); rpk's error, which holds no
  # password, comes back on stderr.
  err=$(printf '%s\n%s\n' "$SVP_KAFKA_ADMIN_PASSWORD" "$current" |
    kc -n svp-data exec -i redpanda-0 -c redpanda -- bash -c '
      IFS= read -r new; IFS= read -r secret
      # The Admin API answers a superuser only. A wrong password is the HTTP 401 rpk reports as "Unauthorized"; any
      # other failure says nothing about the password, so it stops here: trying the next password could not tell
      # more, and only exit 3 may suggest starting over with new data.
      login() {
        out=$(RPK_PASS=$1 rpk security user list 2>&1) && return 0
        case $out in *Unauthorized*) return 1 ;; esac
        printf "%s\n" "$out" >&2
        exit 5
      }
      login "$new" && exit 0
      for old in "$secret" "$RPK_PASS"; do
        if [ -n "$old" ] && login "$old"; then
          out=$(RPK_PASS=$old rpk security user update svp-admin --new-password "$new" --mechanism SCRAM-SHA-256 2>&1) &&
            login "$new" && exit 10
          printf "%s\n" "$out" >&2
          exit 4
        fi
      done
      printf "%s\n" "$out" >&2
      exit 3' 2>&1) || rc=$?
  case $rc in
    0) ;;
    10) ok "password of svp-admin set in Redpanda from .env (logged in with the previous one)" ;;
    3) fail "Redpanda takes none of these passwords for svp-admin: the one in .env, the one of Secret redpanda-bootstrap, the one redpanda-0 started with; no Secret was changed. Put the previous one back in .env, or start over with new data (make k8s-down && make k8s-up). rpk: $err" ;;
    4) fail "set svp-admin's password in Redpanda from .env; no Secret was changed. rpk: $err" ;;
    5) fail "Redpanda's Admin API in redpanda-0 did not answer whether svp-admin's password is right (not a rejected password); no Secret was changed. Run make k8s-secrets again once the broker answers. rpk: $err" ;;
    *) fail "log in to Redpanda as svp-admin inside redpanda-0: $err" ;;
  esac
}
redpanda_admin

# kubectl prints only the kind and name of each object it applied.
manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply the Secrets of namespace svp-data"
ok "Secrets of svp-data applied from .env: pg-superuser, pg-roles, minio-root, minio-users, redpanda-bootstrap, redpanda-superusers, kafka-users"

svp_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply the Secrets of namespace svp"
ok "Secrets of svp applied from .env: <service>-env of each service, <service>-migrate-env of each with a database"

obs_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply the Secrets of namespace svp-obs"
ok "Secrets of svp-obs applied from .env: grafana-admin, alertmanager-svp, alertmanager-telegram, glitchtip-env, glitchtip-admin"
if [ "$telegram" = on ]; then
  ok "Alertmanager: severity=page goes to Telegram"
else
  ok "Alertmanager: Telegram receiver off (SVP_ALERT_TELEGRAM_BOT_TOKEN or SVP_ALERT_TELEGRAM_CHAT_ID empty or invalid); alerts are only listed in its UI (make k8s-ui-alertmanager)"
fi

# Namespace keda is made by chart svp-cluster (wave 1, with its Pod Security labels), which deploy/k8s/install.sh
# installs before it runs this script. deploy/k8s/gitops.sh runs it before Argo CD applies anything, so there it is
# made bare here; Argo CD's apply of svp-cluster then adds the labels, before KEDA's first pod (wave 2).
if ! kc get namespace keda >/dev/null 2>&1; then
  kc create namespace keda >/dev/null || fail "create namespace keda"
  ok "namespace keda created for Secret keda-kafka"
fi
keda_manifests | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply the Secret of namespace keda"
ok "Secret of keda applied from .env: keda-kafka"

# A process reads a Secret given to it as an environment variable only when it starts: a changed Secret reaches a
# running pod only through a restart, which Kubernetes does not do by itself. No chart can do it either, by a checksum
# of the Secret in its pod template: these Secrets are made here, outside Helm and Argo CD, which never see them. So
# MinIO and Redpanda are restarted here, on the dev and the GitOps path alike, before the init Jobs of svp-data log in
# to them with the new password. The six services and the KEDA operator are restarted by deploy/k8s/install.sh, after
# those Jobs have set their new passwords (restarted here, a service would start with a password its backend does not
# take yet). The init Jobs need none (each run is a new pod), and CloudNativePG sets a changed superuser password in
# Postgres itself, without a restart (Secret pg-superuser carries its label cnpg.io/reload, above).

# stale POD CONTAINER VAR VALUE: true when CONTAINER of POD runs with an environment variable VAR that differs from
# VALUE. VALUE goes to the container on stdin and is compared there, never printed nor on a command line. A pod that
# does not exist or does not run yet reads the Secret when it starts, so it is not stale.
stale() {
  local pod=$1 container=$2 var=$3 value=$4 started err rc=0
  started=$(kc -n svp-data get pod "$pod" \
    -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state.running.startedAt}" 2>/dev/null) || true
  [ -n "$started" ] || return 1
  # Exit 3 inside the container means "differs", told apart from kubectl's own failures (exit 1).
  err=$(printf '%s\n' "$value" | kc -n svp-data exec -i "$pod" -c "$container" -- \
    sh -c "IFS= read -r v; [ \"\$v\" = \"\$$var\" ] || exit 3" 2>&1) || rc=$?
  case $rc in
    0) return 1 ;;
    3) return 0 ;;
    *) fail "compare $var of $pod/$container with .env: $err" ;;
  esac
}

# restart WORKLOAD: rolls the pods of WORKLOAD so that they read their Secrets again, and waits until they are ready.
restart() {
  kc -n svp-data rollout restart "$1" >/dev/null || fail "restart $1"
  kc -n svp-data rollout status "$1" --timeout=300s >/dev/null || fail "$1 ready again within 300s of its restart"
  ok "$1 restarted: it had started with another password than the one in .env"
}

# MinIO takes the root password from its environment at start; it keeps its buckets and users when it starts with
# another one (checked on the pinned image). Without this the minio-init Job, which logs in with the new password,
# would fail.
if stale minio-0 minio MINIO_ROOT_PASSWORD "$SVP_MINIO_ROOT_PASSWORD"; then
  restart statefulset/minio
fi

# Redpanda takes the password in .env already (redpanda_admin, above); the broker's rpk and the sidecar keep logging
# in with the one they started with until they restart.
if stale redpanda-0 redpanda RPK_PASS "$SVP_KAFKA_ADMIN_PASSWORD"; then
  restart statefulset/redpanda
fi
