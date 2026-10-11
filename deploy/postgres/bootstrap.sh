#!/usr/bin/env bash
# Creates or updates the Postgres roles and databases of user-service and video-service on the
# local Postgres (127.0.0.1:5432) as the superuser, by running bootstrap.sql once per service.
# Idempotent. Reads only the role passwords from the env file, without sourcing it, and never
# prints them.
#
# Usage: deploy/postgres/bootstrap.sh <env-file>
set -euo pipefail

env_file=${1:?usage: bootstrap.sh <env-file>}
sql="$(dirname "$0")/bootstrap.sql"
# Local dev superuser password (CLAUDE.md); ignored while pg_hba trusts loopback.
export PGPASSWORD=${PGPASSWORD:-postgres}

# value prints the value of the last NAME=... line of the env file and fails when it is empty.
value() {
  local v
  v=$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)
  if [[ -z $v ]]; then
    echo "bootstrap: $1 is missing or empty in $env_file" >&2
    return 1
  fi
  printf '%s' "$v"
}

for svc in user video; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  migrator_password=$(value "SVP_${upper}_MIGRATOR_DB_PASSWORD")
  app_password=$(value "SVP_${upper}_APP_DB_PASSWORD")
  SVP_MIGRATOR_PASSWORD=$migrator_password SVP_APP_PASSWORD=$app_password \
    psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -X -q \
    -v db="svp_${svc}" -v migrator="svp_${svc}_migrator" -v app="svp_${svc}_app" \
    -f "$sql"
  echo "bootstrap: database svp_${svc} and roles svp_${svc}_migrator, svp_${svc}_app ok"
done
