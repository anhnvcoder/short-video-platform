#!/usr/bin/env bash
# `make k8s-web-e2e`, run from web/ (the Makefile puts Node and pnpm of web/ first on PATH): the end-to-end tests of
# e2e/*.e2e.ts against the web of cluster svp at https://svp.localhost:8443 instead of the compose stack
# (e2e/stack.ts), on Chromium and WebKit.
# - .k8s/ca.crt and the cluster's API must be there, or nothing runs. Then SVP_STACK=k3d, and curl (e2e/seed.sh) and
#   Node (the specs' own fetch) trust the cluster's CA through CURL_CA_BUNDLE and NODE_EXTRA_CA_CERTS; the browsers
#   skip the certificate check (e2e/stack.ts says why).
# - SVP_E2E_GLITCHTIP=1 adds e2e/glitchtip.e2e.ts, which reads the cluster's GlitchTip API: the read-only token of
#   Secret svp-obs/glitchtip-api goes into SVP_E2E_GLITCHTIP_TOKEN of the run's environment only (never printed, never
#   on a command line), and a port-forward to service/glitchtip on 127.0.0.1:8000 (the port of make k8s-ui-glitchtip
#   and make k8s-web-sourcemaps) lives as long as the run, stopped by its pid however the run ends.
# SVP_E2E_EVIDENCE and every argument pass on to `playwright test`, as with make web-e2e.
#
# LOCAL LAB ONLY, like make web-e2e: e2e/seed.sh and every Playwright worker delete the gateway's register rate limit
# keys (svp:gw:rl:register:*) in Valkey db 10 of the cluster (kubectl exec, context k3d-svp). Never point it at a
# shared cluster.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/../../deploy/k8s/lib.sh"

ca=$repo_root/.k8s/ca.crt
[ -s "$ca" ] || fail ".k8s/ca.crt missing; run make k8s-up (or make k8s-ca)"
kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
export SVP_STACK=k3d CURL_CA_BUNDLE=$ca NODE_EXTRA_CA_CERTS=$ca

glitchtip=http://127.0.0.1:8000
forward_pid=
cleanup() {
  if [ -n "$forward_pid" ]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "${SVP_E2E_GLITCHTIP:-}" = 1 ]; then
  # Read into a variable only; jsonpath of a missing Secret or key prints nothing.
  token=$(kc -n svp-obs get secret glitchtip-api --ignore-not-found -o jsonpath='{.data.SENTRY_AUTH_TOKEN}' |
    base64 -d) || fail "read Secret svp-obs/glitchtip-api"
  [ -n "$token" ] || fail "Secret svp-obs/glitchtip-api has no SENTRY_AUTH_TOKEN; run make k8s-glitchtip-init first"
  port_free 8000 || fail "127.0.0.1:8000 is taken (make k8s-ui-glitchtip?); stop it, the run opens its own port-forward"
  # kubectl itself, not the kc function: in the background a function runs in a subshell, $! would be that subshell's
  # pid, and killing it would leave kubectl running, holding the port.
  kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1 service/glitchtip 8000:8000 >/dev/null 2>&1 &
  forward_pid=$!
  wait_until 30 "GlitchTip through the port-forward on 127.0.0.1:8000" \
    curl -fs -o /dev/null --max-time 5 "$glitchtip/_health/"
  export SVP_E2E_GLITCHTIP_TOKEN=$token
  token=
fi

# Not exec: the EXIT trap must still stop the port-forward.
status=0
pnpm e2e "$@" || status=$?
exit "$status"
