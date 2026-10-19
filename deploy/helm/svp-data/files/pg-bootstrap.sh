#!/usr/bin/env bash
# Creates or updates the roles and databases of user-service, video-service, engagement-service, feed-service and
# GlitchTip on the in-cluster Postgres svp-pg, by running deploy/postgres/bootstrap.sql (the file compose uses, mounted
# at /init/bootstrap.sql) once per database as the superuser: the Kubernetes counterpart of
# deploy/postgres/bootstrap.sh. Run by the pg-bootstrap Job of chart svp-data after every install and upgrade;
# idempotent.
#
# The connection comes from PGHOST, PGPORT, PGUSER, PGPASSWORD, PGSSLMODE and PGDATABASE; the role passwords from
# SVP_<SERVICE>_{MIGRATOR,APP}_DB_PASSWORD. Every password stays in the environment, never on a command line, and
# none is printed.
set -euo pipefail

wait_seconds=${SVP_WAIT_SECONDS:?}
services=(user video engagement feed glitchtip)

# Read every password before changing anything: a missing one stops the Job with nothing half applied.
for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  for role in MIGRATOR APP; do
    name="SVP_${upper}_${role}_DB_PASSWORD"
    if [[ -z ${!name:-} ]]; then
      echo "pg-bootstrap: $name is missing or empty in Secret pg-roles; run make env, then make k8s-secrets" >&2
      exit 1
    fi
  done
done

# The operator creates the instance asynchronously and sets the superuser password once it runs: wait until a login
# with that password works, for a bounded time, then fail with Postgres's own (terse) error.
deadline=$((SECONDS + wait_seconds))
until err=$(psql -X -q -v VERBOSITY=terse -c 'SELECT 1' 2>&1 >/dev/null); do
  if ((SECONDS >= deadline)); then
    echo "pg-bootstrap: no superuser login to $PGHOST:$PGPORT within ${wait_seconds}s; last error: $err" >&2
    exit 1
  fi
  sleep 3
done

for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  migrator="SVP_${upper}_MIGRATOR_DB_PASSWORD"
  app="SVP_${upper}_APP_DB_PASSWORD"
  SVP_MIGRATOR_PASSWORD=${!migrator} SVP_APP_PASSWORD=${!app} \
    psql -X -q -v db="svp_${svc}" -v migrator="svp_${svc}_migrator" -v app="svp_${svc}_app" -f /init/bootstrap.sql
  echo "pg-bootstrap: database svp_${svc} and roles svp_${svc}_migrator, svp_${svc}_app ok"
done

# bootstrap.sql takes CONNECT away from PUBLIC on the svp_* databases only. The three databases initdb and CloudNativePG
# make, postgres, app and template1, keep Postgres's default grant of CONNECT to PUBLIC, so every service role could log
# in to them (and create temporary tables in the first two). None needs to: each service and its migrations use their
# own svp_* database, and so does GlitchTip (MAINTENANCE_DATABASE_URL names svp_glitchtip). The superuser postgres (this
# Job, the operator's instance manager, which also opens template1) skips privilege checks, and the owner app keeps
# CONNECT on its database. Two roles of the operator are not superusers and get CONNECT by name: the metrics exporter
# logs in as cnpg_metrics_exporter to postgres (the up and WAL metrics) and to the application database app (the
# default monitoring queries), and streaming_replica opens ordinary connections to postgres from a replica, for
# pg_rewind and replication slots (its streaming connections name no database). CREATE DATABASE needs no CONNECT on
# template1.
#
# The instance manager creates those two roles once the server runs, which can be a moment after the superuser login
# above first works: wait for them, within the same bound. The grants come before the revokes in one transaction, so
# there is no moment when the operator's roles cannot connect, and a failed GRANT revokes nothing. Run on every install
# and upgrade, so a cluster made before these lines gets them too (the operator's initdb runs only when the cluster is
# created); GRANT and REVOKE are idempotent.
until [[ $(psql -X -q -At -c "SELECT count(*) FROM pg_catalog.pg_roles
    WHERE rolname IN ('cnpg_metrics_exporter', 'streaming_replica')") == 2 ]]; do
  if ((SECONDS >= deadline)); then
    echo "pg-bootstrap: roles cnpg_metrics_exporter and streaming_replica not created by the operator within" \
      "${wait_seconds}s; CONNECT on postgres, app and template1 left as it was" >&2
    exit 1
  fi
  sleep 3
done
psql -X -q -1 -v ON_ERROR_STOP=1 -v VERBOSITY=terse \
  -c 'GRANT CONNECT ON DATABASE postgres TO cnpg_metrics_exporter, streaming_replica' \
  -c 'GRANT CONNECT ON DATABASE app TO cnpg_metrics_exporter' \
  -c 'REVOKE CONNECT ON DATABASE postgres, app, template1 FROM PUBLIC'
echo "pg-bootstrap: CONNECT on databases postgres, app and template1 revoked from PUBLIC, granted to operator roles"
