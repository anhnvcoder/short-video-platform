#!/usr/bin/env bash
# Creates or updates the Postgres roles and databases of user-service, video-service,
# engagement-service, feed-service and the GlitchTip error tracker (svp_glitchtip) on the local
# Postgres (127.0.0.1:5432) as the superuser, by running bootstrap.sql once per database.
# Idempotent. Reads only the role passwords from the env file, with the strict rule of
# deploy/observability/glitchtip/dotenv.sh (the one compose agrees with), never prints them, and
# reads all of them before it changes anything.
#
# Usage: deploy/postgres/bootstrap.sh <env-file>
set -euo pipefail

env_file=${1:?usage: bootstrap.sh <env-file>}
sql="$(dirname "$0")/bootstrap.sql"
. "$(dirname "$0")/../observability/glitchtip/dotenv.sh"
# Local dev superuser password (CLAUDE.md); ignored while pg_hba trusts loopback.
export PGPASSWORD=${PGPASSWORD:-postgres}

# value prints NAME's value in the env file and fails when the file breaks the rule or NAME is
# missing or empty.
value() {
  local v
  v=$(dotenv_value "$env_file" "$1") || return 1
  if [[ -z $v ]]; then
    echo "bootstrap: $1 is missing or empty in $env_file" >&2
    return 1
  fi
  printf '%s' "$v"
}

services=(user video engagement feed glitchtip)
migrator_passwords=()
app_passwords=()
for svc in "${services[@]}"; do
  upper=$(printf '%s' "$svc" | tr '[:lower:]' '[:upper:]')
  migrator_passwords+=("$(value "SVP_${upper}_MIGRATOR_DB_PASSWORD")")
  app_passwords+=("$(value "SVP_${upper}_APP_DB_PASSWORD")")
done

for i in "${!services[@]}"; do
  svc=${services[$i]}
  SVP_MIGRATOR_PASSWORD=${migrator_passwords[$i]} SVP_APP_PASSWORD=${app_passwords[$i]} \
    psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -X -q \
    -v db="svp_${svc}" -v migrator="svp_${svc}_migrator" -v app="svp_${svc}_app" \
    -f "$sql"
  echo "bootstrap: database svp_${svc} and roles svp_${svc}_migrator, svp_${svc}_app ok"
done
