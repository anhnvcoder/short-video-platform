#!/usr/bin/env bash
# Runs the glitchtip-init job (migrations, cache table, partitions, bootstrap.py) once with a
# private output directory mounted, then puts the DSN and API token it wrote there into the env
# file (docs/adr/0011-observability-stage3.md, section 7):
#   SENTRY_DSN         the project DSN with host glitchtip:8000, for the Go services in compose
#   SENTRY_AUTH_TOKEN  read-only API token (event:read, project:read) for the drills
#   SENTRY_ORG, SENTRY_PROJECT, SENTRY_API_URL  svp, svp, http://127.0.0.1:8000
# The env file is read with the strict rule of dotenv.sh, the same as `make env`: a line it refuses
# stops the script, naming the variable, with the env file untouched. A variable that already has
# a value is never changed (a different one is reported by name); the env file is replaced
# atomically, mode 600, and only when a variable was added. No value is printed. Idempotent.
#
# Usage: COMPOSE='<docker compose command with the obs profile>' init.sh <env-file>
set -euo pipefail
. "$(dirname "$0")/dotenv.sh"

env_file=${1:?usage: init.sh <env-file>}
: "${COMPOSE:?COMPOSE must hold the docker compose command with the obs profile}"
api_url=http://127.0.0.1:8000
service_host=glitchtip:8000

out=$(mktemp -d)
add=$(mktemp "$env_file.tmp.XXXXXX")
new=
trap 'rm -rf "$out" "$add" ${new:+"$new"}' EXIT

# The output directory is private to the user (mktemp -d), so the job runs as the user's uid and
# gid instead of the image's 5000: on Linux Docker Engine a bind mount keeps host ownership, and
# only the owner can create the file there and read it back. bootstrap.py creates it with mode
# 600, and the trap deletes it.
$COMPOSE run --rm --no-deps -T --user "$(id -u):$(id -g)" -v "$out:/out" \
  -e SVP_GLITCHTIP_OUT=/out/credentials glitchtip-init

dsn=$(sed -n 's/^dsn=//p' "$out/credentials")
token=$(sed -n 's/^token=//p' "$out/credentials")
rm -f "$out/credentials"
if [[ -z $dsn || -z $token ]]; then
  echo "glitchtip-init: bootstrap.py wrote no DSN or token" >&2
  exit 1
fi
# GlitchTip names itself by the host's loopback address (GLITCHTIP_DOMAIN in compose.yaml); inside
# the compose network the services reach it by its service name.
service_dsn=${dsn/@127.0.0.1:8000\//@$service_host/}
if [[ $service_dsn == "$dsn" ]]; then
  echo "glitchtip-init: the DSN does not name 127.0.0.1:8000; check GLITCHTIP_DOMAIN" >&2
  exit 1
fi

added=
# want appends NAME=VALUE to the lines to add when the env file has no value for NAME.
want() {
  local current
  current=$(dotenv_value "$env_file" "$1")
  if [[ -z $current ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$add"
    added="$added $1"
  elif [[ $current != "$2" ]]; then
    echo "glitchtip-init: $1 in $env_file differs from GlitchTip's value; left unchanged" >&2
  fi
}
want SENTRY_DSN "$service_dsn"
want SENTRY_AUTH_TOKEN "$token"
want SENTRY_ORG svp
want SENTRY_PROJECT svp
want SENTRY_API_URL "$api_url"

if [[ -z $added ]]; then
  echo "glitchtip-init: $env_file already has every GlitchTip variable; left unchanged"
  exit 0
fi
new=$(mktemp "$env_file.new.XXXXXX")
dotenv_fill "$env_file" "$add" > "$new"
chmod 600 "$new"
mv "$new" "$env_file"
new=
echo "glitchtip-init: added to $env_file (mode 600):$added"
