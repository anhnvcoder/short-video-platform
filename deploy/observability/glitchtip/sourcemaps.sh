#!/usr/bin/env bash
# Uploads the source maps of the web client's browser bundle to GlitchTip, so a browser error's stack shows in the
# source:
#   compose  `make web-sourcemaps`: the web of `make up` (http://localhost:3001) and GlitchTip of `make up OBS=lgtm`
#            (http://127.0.0.1:8000), token SENTRY_SOURCEMAPS_TOKEN of .env (written by make glitchtip-init);
#   k3d      `make k8s-web-sourcemaps`: the web of cluster svp (https://svp.localhost:8443, CA .k8s/ca.crt) and its
#            GlitchTip through a port-forward on 127.0.0.1:8000 for the time of the upload, token of Secret
#            svp-obs/glitchtip-sourcemaps (written by make k8s-glitchtip-init).
# MAPS_DIR, when given, is a folder that already holds the chunks and maps of the build the web runs, laid out as stage
# `sourcemaps` writes them (_next/static/...): on the GitOps cluster the image comes from CI, which exports them beside
# it as the artifact web-sourcemaps-<arch> (`make k8s-web-sourcemaps SOURCEMAPS_DIR=...`). Nothing is built then.
# Steps:
#   1. With MAPS_DIR: it is an absolute path to a real folder holding only regular files under _next/static/, each a
#      .js chunk or a .map, no hidden entry or link, at least one *.js.map and one chunk with a debug id; otherwise
#      stop before anything else is asked or sent. The folder may come from another run (an artifact): it is only read,
#      never run.
#   2. GlitchTip answers, the token is there, the web answers: otherwise stop, naming the command to run first,
#      before anything is built or sent.
#   3. Without MAPS_DIR: build stage `sourcemaps` of deploy/docker/web.Dockerfile from the working tree with the build
#      argument the running image got (SVP_BUILD_ID: empty in compose, web_build_id of deploy/k8s/lib.sh on k3d), into
#      a private temporary directory. The build cache gives the stage of that very build, so the maps of the bundle
#      served.
#   4. Every chunk the web serves on /login must carry a debug id found in those chunks: otherwise the web runs
#      another build (the image was built from another tree, or the cache was pruned since; or MAPS_DIR holds another
#      build's), and nothing is sent.
#   5. `sentry sourcemap upload` (the Sentry CLI of web/package.json, through pnpm) sends chunks and maps as an
#      artifact bundle of organization and project svp that GlitchTip matches to an event by debug id. Without
#      --no-rewrite on purpose: the CLI then reads the debug id Turbopack already wrote (`//# debugId=`, the file is left
#      as it is) and puts it in the bundle's manifest as each file's `debug-id` header. With --no-rewrite the CLI sends
#      no such header, and GlitchTip's assemble step drops every artifact that has neither a debug-id header nor a
#      release ("skipped ... no debug-id header and no release" in its log), while the upload itself still succeeds.
#      The token is exported to that process alone, never printed or put on a command line; the CLI's telemetry,
#      update check and configuration directory are off or temporary.
#   6. GlitchTip assembles the bundle after the upload answers and has no API to read it back, so the script can only
#      say it was sent; the check that the stack maps is e2e/glitchtip.e2e.ts (SVP_E2E_GLITCHTIP=1).
# The temporary directory and the port-forward go away when the script ends, however it ends.
#
# Usage: sourcemaps.sh compose|k3d [MAPS_DIR] (run from the Makefile, which puts Node and pnpm of web/ first on PATH).
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/../../k8s/lib.sh"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$repo_root/deploy/observability/glitchtip/dotenv.sh"

stack=${1:-}
maps_dir=${2:-}
glitchtip=http://127.0.0.1:8000
tmp=
forward_pid=
cleanup() {
  if [ -n "$forward_pid" ]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  [ -z "$tmp" ] || rm -rf "$tmp"
}
trap cleanup EXIT

glitchtip_up() { curl -fs -o /dev/null --max-time 5 "$glitchtip/_health/"; }

# debug_ids DIR: the debug ids of the chunks in DIR, sorted; Turbopack ends each chunk with a //# debugId=<uuid> line.
debug_ids() { find "$1" -name '*.js' -exec sed -n 's|^//# debugId=||p' {} + | LC_ALL=C sort -u; }

case $stack in compose | k3d) ;; *) fail "usage: sourcemaps.sh compose|k3d [MAPS_DIR]" ;; esac
if [ -n "$maps_dir" ]; then
  [[ $maps_dir == /* ]] || fail "MAPS_DIR must be an absolute path (got '$maps_dir')"
  [ -d "$maps_dir" ] && [ ! -L "$maps_dir" ] || fail "MAPS_DIR $maps_dir is not a folder"
  bad=$(cd "$maps_dir" && find . -mindepth 1 \( -name '.*' -o \( ! -type f ! -type d \) \) -print)
  [ -z "$bad" ] || fail "MAPS_DIR $maps_dir holds hidden entries or entries that are neither files nor folders: $bad"
  bad=$(cd "$maps_dir" && find . -type f | grep -vE '^\./_next/static/.+\.(js|map)$' || true)
  [ -z "$bad" ] || fail "MAPS_DIR $maps_dir holds files other than chunks and maps under _next/static/: $bad"
  [ -n "$(find "$maps_dir" -type f -name '*.js.map' | head -n 1)" ] || fail "MAPS_DIR $maps_dir holds no source map (*.js.map)"
  built=$(debug_ids "$maps_dir")
  [ -n "$built" ] || fail "MAPS_DIR $maps_dir holds no chunk with a debug id"
fi

case $stack in
compose)
  web=http://localhost:3001
  curl_web=(curl -fsS --max-time 10)
  build_id=
  glitchtip_up || fail "GlitchTip does not answer at $glitchtip; run make up OBS=lgtm first"
  [ -f "$repo_root/.env" ] || fail ".env not found; run make env, then make up OBS=lgtm"
  token=$(dotenv_value "$repo_root/.env" SENTRY_SOURCEMAPS_TOKEN) || fail "read .env"
  [ -n "$token" ] || fail "SENTRY_SOURCEMAPS_TOKEN is missing or empty in .env; run make glitchtip-init first"
  ;;
k3d)
  web=https://svp.localhost:8443
  [ -s "$repo_root/.k8s/ca.crt" ] || fail ".k8s/ca.crt missing; run make k8s-up (or make k8s-ca)"
  curl_web=(curl -fsS --max-time 10 --cacert "$repo_root/.k8s/ca.crt")
  kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
  # Read into a variable only; jsonpath of a missing Secret or key prints nothing.
  token=$(kc -n svp-obs get secret glitchtip-sourcemaps --ignore-not-found \
    -o jsonpath='{.data.SENTRY_SOURCEMAPS_TOKEN}' | base64 -d) || fail "read Secret svp-obs/glitchtip-sourcemaps"
  [ -n "$token" ] || fail "Secret svp-obs/glitchtip-sourcemaps has no SENTRY_SOURCEMAPS_TOKEN; run make k8s-glitchtip-init first"
  port_free 8000 ||
    fail "127.0.0.1:8000 is taken (make k8s-ui-glitchtip?); stop it, the upload opens its own port-forward"
  # kubectl itself, not the kc function: in the background a function runs in a subshell, $! would be that subshell's
  # pid, and killing it would leave kubectl running, holding the port.
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/glitchtip 8000:8000 >/dev/null 2>&1 &
  forward_pid=$!
  wait_until 30 "GlitchTip through the port-forward on 127.0.0.1:8000" glitchtip_up
  # The build id names the build made below; a folder given holds a build already.
  [ -n "$maps_dir" ] || build_id=$(web_build_id) || fail "compute the build id of web/"
  ;;
esac

login=$("${curl_web[@]}" "$web/login") || fail "the web does not answer at $web/login; start it first (make up / make k8s-up)"
# The chunk URLs of the page, without the ?dpl= query a deploymentId adds.
served=$(printf '%s\n' "$login" | grep -oE '/_next/static/chunks/[A-Za-z0-9._~-]+\.js' | LC_ALL=C sort -u)
[ -n "$served" ] || fail "$web/login names no chunk under /_next/static/chunks/"

tmp=$(mktemp -d)
if [ -n "$maps_dir" ]; then
  maps=$maps_dir
  build="the build in $maps_dir"
else
  maps=$tmp/maps
  build="build ${build_id:-<empty>}"
  echo "build stage sourcemaps of deploy/docker/web.Dockerfile (SVP_BUILD_ID=${build_id:-<empty>})"
  docker_ build --file "$repo_root/deploy/docker/web.Dockerfile" --target sourcemaps \
    --build-arg "SVP_BUILD_ID=$build_id" --output "type=local,dest=$maps" "$repo_root/web" ||
    fail "build stage sourcemaps of the web image"
  built=$(debug_ids "$maps")
  [ -n "$built" ] || fail "stage sourcemaps holds no chunk with a debug id"
fi
ok "$(find "$maps" -name '*.js.map' | wc -l | tr -d ' ') source maps of $build"

checked=0
for path in $served; do
  id=$("${curl_web[@]}" "$web$path" | sed -n 's|^//# debugId=||p') || fail "fetch $web$path"
  [ -n "$id" ] || continue
  printf '%s\n' "$built" | grep -qxF -- "$id" ||
    fail "$web$path (debug id $id) is not a chunk of $build: the web runs another one; rebuild it (make up / make k8s-up), or give the maps of the build it runs, then run this again"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no chunk of $web/login carries a debug id"
ok "the $checked chunks of $web/login with a debug id are chunks of $build"

# In a subshell: the CLI sees only the SENTRY_* variables set here (none of the caller's, such as a SENTRY_DSN or
# SENTRY_RELEASE of the shell), and the token leaves with the subshell.
(
  while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep '^SENTRY_' || true)
  mkdir "$tmp/config"
  export SENTRY_URL=$glitchtip SENTRY_ORG=svp SENTRY_PROJECT=svp SENTRY_AUTH_TOKEN=$token \
    SENTRY_CONFIG_DIR=$tmp/config SENTRY_CLI_NO_TELEMETRY=1 SENTRY_CLI_NO_UPDATE_CHECK=1
  pnpm --dir "$repo_root/web" exec sentry sourcemap upload "$maps"
) || fail "upload the source maps to GlitchTip at $glitchtip"
token=
ok "source maps of $build sent to GlitchTip (organization svp, project svp)"
case $stack in
compose) e2e="SVP_E2E_GLITCHTIP=1 make web-e2e" ;;
k3d) e2e="SVP_E2E_GLITCHTIP=1 make k8s-web-e2e" ;;
esac
echo "GlitchTip stores them after this answer and cannot be asked whether it did; $e2e checks that a browser error maps"
