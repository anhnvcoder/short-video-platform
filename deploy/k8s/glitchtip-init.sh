#!/usr/bin/env bash
# Puts GlitchTip's DSN and the drills' API token into the cluster's Secrets once GlitchTip runs in svp-obs
# (docs/adr/0014-kubernetes-local-stage4.md, sections 8 and 11), the cluster's side of what
# deploy/observability/glitchtip/init.sh does for compose:
#   Secret svp/sentry            SENTRY_DSN, the DSN of project svp with host glitchtip.svp-obs:8000, read by the five
#                                services that report errors (optional reference: until it exists they run without)
#   Secret svp-obs/glitchtip-api SENTRY_AUTH_TOKEN, the read-only API token svp-drill (event:read, project:read)
# Both are GlitchTip's own values, made by its init Job (bootstrap.py): they never go to .env, a file or the terminal.
# They are read inside the running GlitchTip pod through its ORM and come back on stdout into a shell variable only.
#
# Then each service that reads Secret sentry restarts when its pods started before the Secret's current version, so
# it reports errors from then on (restart_on_secret_change of deploy/k8s/lib.sh, annotation
# svp-sentry-secret-version): a workload without that annotation may have started before the Secret existed (the
# GitOps path starts the services beside GlitchTip), so it restarts too. For a Deployment `kubectl rollout restart`
# only adds the annotation kubectl.kubernetes.io/restartedAt to the pod template, the same one Argo CD's own restart
# action writes; the gateway, a Rollout, gets spec.restartAt instead, which restarts its pods without a new revision
# (a changed template would be a canary). The version goes into the workload's metadata. None of these is in the
# manifests in git, and Argo CD's diff, a three-way merge against what it last applied, does not report fields it
# never applied, nor does a sync remove them. A workload whose template does not read Secret sentry yet (a release from
# before error tracking) is left alone: its next upgrade rolls it with the new template, which reads the Secret then.
#
# Needs only GlitchTip ready (its init Job has run); run by deploy/k8s/install.sh after chart svp-observability, by
# `make k8s-glitchtip-init` on its own, and by the GitOps path once Argo CD reports GlitchTip healthy. Idempotent: the
# DSN and token do not change between runs (bootstrap.py never makes a second key or token), so a second run applies
# the same Secrets, which keep their resourceVersion, and restarts nothing.
set -euo pipefail

# shellcheck source=deploy/k8s/lib.sh
. "$(dirname "$0")/lib.sh"

kc get --raw /readyz >/dev/null 2>&1 || fail "cluster svp is not reachable (context k3d-svp); run make k8s-up"
kc -n svp-obs rollout status deployment/glitchtip --timeout=300s >/dev/null ||
  fail "GlitchTip (deployment svp-obs/glitchtip) ready within 300s; install it with make k8s-up"

# The first active key of project svp and the oldest token labelled svp-drill: the two bootstrap.py hands out. Prefixed
# lines, so nothing else Django may print can be taken for them. The values are printed to this script's pipe only.
# The code goes to `manage.py shell -c`, not on stdin: the shell reads stdin only when it already holds data the moment
# Django has started, and otherwise opens an interactive console, whose prompt would come before the values. It holds
# no secret, so it may be on the command line. It is read into a variable, not written as a heredoc inside $(...),
# which bash 3.2 parses badly; read returns 1 at the end of its input, which is expected here.
read -r -d '' read_creds <<'PY' || true
from apps.api_tokens.models import APIToken
from apps.projects.models import ProjectKey

key = (
    ProjectKey.objects.filter(project__organization__slug="svp", project__slug="svp", is_active=True)
    .order_by("pk")
    .first()
)
token = APIToken.objects.filter(label="svp-drill").order_by("pk").first()
if key is None or not key.get_dsn():
    raise SystemExit("glitchtip-init: project svp has no active key; did the init Job run bootstrap.py?")
if token is None:
    raise SystemExit("glitchtip-init: no API token labelled svp-drill; did the init Job run bootstrap.py?")
print("svp-dsn=" + key.get_dsn())
print("svp-token=" + token.token)
PY
creds=$(kc -n svp-obs exec deployment/glitchtip -c glitchtip -- python manage.py shell -c "$read_creds") ||
  fail "read the DSN and API token inside GlitchTip (kubectl --context k3d-svp -n svp-obs logs deployment/glitchtip)"
dsn=$(printf '%s\n' "$creds" | sed -n 's/^svp-dsn=//p')
token=$(printf '%s\n' "$creds" | sed -n 's/^svp-token=//p')
creds=
[ -n "$dsn" ] && [ -n "$token" ] || fail "GlitchTip gave no DSN or no API token"

# GlitchTip names itself by the address the port-forward listens on (GLITCHTIP_DOMAIN of chart svp-observability); the
# services reach it by its Service.
service_dsn=${dsn/@127.0.0.1:8000\//@glitchtip.svp-obs:8000/}
[ "$service_dsn" != "$dsn" ] || fail "the DSN does not name 127.0.0.1:8000; check GLITCHTIP_DOMAIN in deploy/helm/svp-observability/values.yaml"

{
  secret svp sentry Opaque SENTRY_DSN="$service_dsn"
  secret svp-obs glitchtip-api Opaque SENTRY_AUTH_TOKEN="$token"
} | kc apply --server-side --field-manager=svp-secrets --force-conflicts -f - >/dev/null ||
  fail "apply Secrets svp/sentry and svp-obs/glitchtip-api"
ok "GlitchTip's DSN in Secret svp/sentry, its read-only API token in Secret svp-obs/glitchtip-api"

for svc in "${svp_services[@]}"; do
  kind=$(workload_kind svp "$svc")
  ref=$(kc -n svp get "$kind" "$svc" --ignore-not-found \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SENTRY_DSN")].valueFrom.secretKeyRef.name}') ||
    fail "read $kind svp/$svc"
  [ "$ref" = sentry ] || continue
  restart_on_secret_change svp "$svc" sentry svp-sentry-secret-version restart
done
ok "every service that reports errors runs with the current DSN"
