#!/usr/bin/env bash
# Tests for the artifact filter of the verification runs, deploy/ci/verify-collect.sh, and for deploy/ci/verify-mask.sh
# it calls. Everything is a fixture in a temporary directory: a fake checkout with a fake .env (the repository's .env is
# never read), a fake results folder, and a fake kubectl first on PATH that lists made-up Secrets or fails. The fake
# secrets, the JWT and the private key header are made at run time, so no file of the repository holds one. Before the
# filter, unready_report of deploy/k8s/lib.sh, with the same fake kubectl listing made-up pods and their logs; its
# output is one of the fake results, as is a migrate Job's log marked by mark_log of the same file. verify-mask.sh
# cluster on a binary value of 200 KiB, timed, and on small ones against the cut it made before. Then the
# deadline criterion of the summary of deploy/ci/verify-sample.sh, with a fake docker and a fake sudo first on PATH;
# and its count of the compose containers' restarts over a fixture of restarts.tsv; one sample of its docker.tsv
# (workers transcoding, memory.stat of the nodes), compose.tsv and restarts.tsv with a fake docker, kubectl and pgrep
# and a fixture of /proc; its peak over a fixture of docker.tsv, and the object store's peak over one of compose.tsv,
# also with its last sample written late by a fake sampler; its k6.tsv over fixtures of /proc and of the cgroup tree;
# the criteria of the k3d scenarios of part 3 (two KEDA drills of gitops, the k6 pods' CPU throttling).
# Then deploy/ci/verify-run.sh with a fake make (and a fake psql and docker for the copy back to MinIO): the scenarios
# of compose-obs and dev-k3d, each scenario of part 3 by its name, and made-up scenario files for what a scenario file
# can get wrong and for a drill run twice. Then the self-test of deploy/ci/verify-tempo.sh.
# Last, that deploy/ci/changed-services.sh builds no image for a change of these scripts, in a throwaway git repository
# holding a copy of it. Runs on macOS and Linux, no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/verify-collect-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# --- The fake secrets: three of .env (one with special characters), one of a cluster Secret, one line of a cluster
# Secret of several lines; values that are not secrets, or too short to count; a JWT and a private key header.
env_secret=$(openssl rand -hex 16)
quoted_secret="p!a#s%s&w*o(r)d-$(openssl rand -hex 4)"
dsn_secret="http://$(openssl rand -hex 16)@127.0.0.1:8000/1"
cluster_secret=$(openssl rand -hex 20)
kafka_secret=$(openssl rand -hex 20)
line_secret="token-$(openssl rand -hex 12)"
helm_payload="H4sIAAAAAAAC$(openssl rand -hex 12)"
# A binary value of a cluster Secret: secrets between a carriage return, other control characters, a newline and bytes
# that are not UTF-8. Each must be masked on a line of its own, and no mask line may hold a control character.
cr_secret="cr-$(openssl rand -hex 8)"
ctl_secret="ctl-$(openssl rand -hex 8)"
nl_secret="nl-$(openssl rand -hex 8)"
bin_secret="bin-$(openssl rand -hex 8)"
binary_value="$cr_secret"$'\r'"$ctl_secret"$'\x01\x1b'"$nl_secret"$'\n'"$bin_secret"$'\xff\xfe'"$cr_secret"
role_name=svp_video_app_user
jwt="eyJ$(openssl rand -hex 8).eyJ$(openssl rand -hex 8).$(openssl rand -hex 8)"
private_key_header="-----BEGIN ""RSA PRIVATE KEY-----"
printf '%s\n' "$env_secret" "$quoted_secret" "$dsn_secret" "$jwt" "$(b64 "$env_secret")" >"$work/env-secrets"
{
  cat "$work/env-secrets"
  printf '%s\n' "$cluster_secret" "$kafka_secret" "$line_secret" "$(b64 "$cluster_secret")"
  printf '%s\n' "$cr_secret" "$ctl_secret" "$nl_secret" "$bin_secret" "$(b64 "$binary_value")"
} >"$work/all-secrets"

repo=$work/repo
mkdir -p "$repo/.k8s/drills" "$repo/.k6/local-1" "$repo/web/test-results/lighthouse/.lighthouseci" \
  "$repo/web/test-results/playwright" "$work/bin"
cat >"$repo/.env" <<EOF
# a comment
SVP_FAKE_APP_DB_PASSWORD=$env_secret
SVP_QUOTED_PASSWORD='$quoted_secret'
SVP_SHORT_TOKEN=abc12
GLITCHTIP_ADMIN_EMAIL=admin@svp.local
SENTRY_ORG=svp
SENTRY_DSN=$dsn_secret
JWT_SIGNING_KID=kid-of-the-signing-key
EOF

# The fake kubectl: kubectl --context k3d-svp --request-timeout=10s -n NS get secrets -o json. FAKE_KUBECTL_FAIL=1
# makes it fail, as for a cluster that no longer answers. For unready_report: kubectl --context k3d-svp -n NS get pods
# -o json prints pods-NS.json; kubectl --context k3d-svp -n NS logs POD -c CONTAINER [--previous] --tail=40 prints
# logs/NS.POD.CONTAINER[.previous]; both are recorded in calls.
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && { echo "The connection to the server was refused" >&2; exit 1; }
if [ "$1 $2 $3" = "--context k3d-svp -n" ]; then
  echo "$*" >>"$FAKE_KUBECTL_DIR/calls"
  if [ "$5 $6 $7 $8" = "get pods -o json" ]; then cat "$FAKE_KUBECTL_DIR/pods-$4.json"; exit; fi
  [ "$5 $7" = "logs -c" ] || exit 2
  f=$FAKE_KUBECTL_DIR/logs/$4.$6.$8
  case " $* " in *" --previous "*) f=$f.previous ;; esac
  if [ -f "$f" ]; then cat "$f"; else echo "Error from server (NotFound): no log" >&2; exit 1; fi
  exit
fi
[ "$1 $2 $3" = "--context k3d-svp --request-timeout=10s" ] && [ "$4" = -n ] &&
  [ "$6 $7 $8 $9" = "get secrets -o json" ] || exit 2
f=$FAKE_KUBECTL_DIR/$5.json
if [ -f "$f" ]; then cat "$f"; else echo '{"items":[]}'; fi
EOF
chmod 755 "$work/bin/kubectl"
mkdir -p "$work/kube"
# b64v NAME=VALUE...: a Secret's data, each VALUE in base64.
b64v() {
  local kv
  for kv in "$@"; do jq -n --arg k "${kv%%=*}" --arg v "$(b64 "${kv#*=}")" '{($k): $v}'; done | jq -s 'add'
}
# Shaped like deploy/k8s/secrets.sh: next to each secret, the identifiers it stores under keys of their own (user
# names, an email, a key id, a SASL mechanism), which the drills print and must stay unmasked and searchable.
jq -n --argjson backup "$(b64v ACCESS_KEY_ID=svp-pg-backup "ACCESS_SECRET_KEY=$cluster_secret" "username=$role_name")" \
  --argjson s3root "$(b64v S3_ROOT_USER=svp-admin "S3_ROOT_PASSWORD=$cluster_secret")" \
  --argjson keda "$(b64v sasl=scram_sha256 tls=disable username=svp-keda "password=$kafka_secret")" \
  --arg multi "$(b64 "route:
  receiver: telegram
  $line_secret
")" --arg helm "$(b64 "$helm_payload")" '{items: [
    {type: "Opaque", metadata: {name: "pg-backup-s3"}, data: $backup},
    {type: "Opaque", metadata: {name: "s3-root"}, data: $s3root},
    {type: "Opaque", metadata: {name: "keda-kafka"}, data: $keda},
    {type: "Opaque", metadata: {name: "alertmanager-svp"}, data: {"alertmanager.yaml": $multi}},
    {type: "helm.sh/release.v1", metadata: {name: "sh.helm.release.v1.svp-data.v1"}, data: {release: $helm}}]}' \
  >"$work/kube/svp-data.json"
jq -n --argjson feed "$(b64v KAFKA_SASL_USERNAME=svp-feed-service "KAFKA_SASL_PASSWORD=$kafka_secret")" \
  --argjson user "$(b64v JWT_SIGNING_KID=kid-of-the-signing-key "KAFKA_SASL_USERNAME=svp-user-service")" '{items: [
    {type: "Opaque", metadata: {name: "feed-service-env"}, data: $feed},
    {type: "Opaque", metadata: {name: "user-service-env"}, data: $user}]}' >"$work/kube/svp.json"
jq -n --argjson admin "$(b64v GLITCHTIP_ADMIN_EMAIL=admin@svp.local "GLITCHTIP_ADMIN_PASSWORD=$cluster_secret")" \
  --argjson grafana "$(b64v admin-user=admin-of-grafana "admin-password=$kafka_secret")" \
  --arg binary "$(b64 "$binary_value")" '{items: [
    {type: "Opaque", metadata: {name: "glitchtip-admin"}, data: $admin},
    {type: "Opaque", metadata: {name: "grafana-admin"}, data: $grafana},
    {type: "Opaque", metadata: {name: "operator-config"}, data: {"config.gz": $binary}}]}' >"$work/kube/svp-obs.json"
identifiers="svp-pg-backup svp-admin scram_sha256 svp-keda svp-feed-service svp-user-service admin@svp.local
admin-of-grafana kid-of-the-signing-key"
export FAKE_KUBECTL_DIR=$work/kube

# --- unready_report of deploy/k8s/lib.sh: which containers it reports, and whose log it prints. In svp-data a Redpanda
# broker in a crash loop (its log, and the attempt before, printed), its ready sidecar (not reported), a Postgres pod
# of CloudNativePG and a completed Job; in svp-obs GlitchTip; in svp two services. Every log the fake kubectl could
# print is a marker, so what reaches the output shows.
# unready_pods ITEMS NAMESPACE: the pods NAMESPACE lists, ITEMS a jq expression of their array.
unready_pods() {
  jq -n "{items: $1}" >"$work/kube/pods-$2.json"
}
unready_pods '[
  {metadata: {name: "redpanda-0", labels: {"app.kubernetes.io/name": "redpanda"}},
   spec: {containers: [{name: "redpanda", terminationMessagePolicy: "FallbackToLogsOnError"}, {name: "sidecar"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "redpanda", ready: false, restartCount: 2, state: {waiting: {reason: "CrashLoopBackOff"}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "INFRA-MESSAGE-MARKER"}}},
     {name: "sidecar", ready: true, restartCount: 0, state: {running: {}}}]}},
  {metadata: {name: "svp-pg-1", labels: {"cnpg.io/cluster": "svp-pg"}},
   spec: {containers: [{name: "postgres", terminationMessagePolicy: "FallbackToLogsOnError"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "postgres", ready: false, restartCount: 1, state: {running: {}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "PG-MESSAGE-MARKER"}}}]}},
  {metadata: {name: "redpanda-init-x"}, spec: {containers: [{name: "init"}]},
   status: {phase: "Succeeded", containerStatuses: [
     {name: "init", ready: false, restartCount: 0, state: {terminated: {reason: "Completed", exitCode: 0}}}]}}]' \
  svp-data
unready_pods '[
  {metadata: {name: "glitchtip-abc", labels: {"app.kubernetes.io/name": "glitchtip"}},
   spec: {containers: [{name: "glitchtip"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "glitchtip", ready: false, restartCount: 0, state: {waiting: {reason: "CrashLoopBackOff"}}}]}}]' svp-obs
unready_pods '[
  {metadata: {name: "gateway-abc"}, spec: {containers: [{name: "gateway"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "gateway", ready: false, restartCount: 3, state: {waiting: {reason: "CrashLoopBackOff"}},
      lastState: {terminated: {reason: "Error", exitCode: 2, message: "TERM-FILE-MARKER"}}}]}},
  {metadata: {name: "media-worker-abc"},
   spec: {containers: [{name: "media-worker", terminationMessagePolicy: "FallbackToLogsOnError"}]},
   status: {phase: "Running", containerStatuses: [
     {name: "media-worker", ready: false, restartCount: 1, state: {running: {}},
      lastState: {terminated: {reason: "Error", exitCode: 1, message: "APP-FALLBACK-MARKER"}}}]}}]' svp
mkdir -p "$work/kube/logs"
printf '%s\n' "Could not initialize seastar: std::runtime_error (insufficient physical memory: needed 1073741824" \
  "" INFRA-TAIL-MARKER >"$work/kube/logs/svp-data.redpanda-0.redpanda"
echo INFRA-PREVIOUS-MARKER >"$work/kube/logs/svp-data.redpanda-0.redpanda.previous"
echo SIDECAR-MARKER >"$work/kube/logs/svp-data.redpanda-0.sidecar"
echo 'ERROR: duplicate key, STATEMENT: INSERT ... PG-LOG-MARKER' >"$work/kube/logs/svp-data.svp-pg-1.postgres"
echo 'GET /api/1/envelope/?sentry_key=GLITCHTIP-MARKER' >"$work/kube/logs/svp-obs.glitchtip-abc.glitchtip"
for f in svp.gateway-abc.gateway svp.gateway-abc.gateway.previous svp.media-worker-abc.media-worker \
  svp.media-worker-abc.media-worker.previous; do
  echo "APP-LOG-MARKER of $f" >"$work/kube/logs/$f"
done
: >"$work/kube/calls"
unready=$work/unready.txt
(
  PATH=$work/bin:$PATH
  . "$here/../k8s/lib.sh"
  for ns in svp-data svp-obs svp; do unready_report "$ns"; done
) 2>"$unready" >/dev/null
has_line() { if grep -qxF -- "$2" "$unready"; then ok "unready: $1"; else fail "unready: $1"; fi; }
has_line "an infrastructure container's state, how it ended and its message" \
  "pod svp-data/redpanda-0, container redpanda: waiting CrashLoopBackOff, 2 restart(s); attempt before: terminated Error (exit 1): INFRA-MESSAGE-MARKER"
has_line "its log, each line marked with its namespace" "    [svp-data] INFRA-TAIL-MARKER"
has_line "an empty line of its log marked too" "    [svp-data] "
has_line "the log of its attempt before" "    [svp-data] INFRA-PREVIOUS-MARKER"
has_line "a service's state, how it ended and its message from the termination log file" \
  "pod svp/gateway-abc, container gateway: waiting CrashLoopBackOff, 3 restart(s); attempt before: terminated Error (exit 2): TERM-FILE-MARKER"
has_line "a service whose message falls back to its log: state and exit only" \
  "pod svp/media-worker-abc, container media-worker: running, 1 restart(s); attempt before: terminated Error (exit 1)"
has_line "GlitchTip's state" "pod svp-obs/glitchtip-abc, container glitchtip: waiting CrashLoopBackOff, 0 restart(s)"
has_line "Postgres' state, without its message" \
  "pod svp-data/svp-pg-1, container postgres: running, 1 restart(s); attempt before: terminated Error (exit 1)"
for m in APP-LOG-MARKER APP-FALLBACK-MARKER GLITCHTIP-MARKER PG-LOG-MARKER PG-MESSAGE-MARKER SIDECAR-MARKER \
  redpanda-init-x; do
  if grep -qF -- "$m" "$unready"; then fail "unready: no $m in its output"; else ok "unready: no $m in its output"; fi
done
if grep -E ' logs (gateway|media-worker|glitchtip|svp-pg)-' "$work/kube/calls" | grep -q .; then
  fail "unready: no log of a service, GlitchTip or Postgres is read"
else
  ok "unready: no log of a service, GlitchTip or Postgres is read"
fi
shown=$(. "$here/../k8s/lib.sh" && echo " $log_tail_namespaces ")
case $shown in
  *" svp "* | *" envoy-gateway-system "* | *" kube-system "* | "  ") fail "unready: log_tail_namespaces has neither svp, Envoy nor kube-system, and is not empty" ;;
  *) ok "unready: log_tail_namespaces has neither svp, Envoy nor kube-system, and is not empty" ;;
esac

# --- mark_log of deploy/k8s/lib.sh, which marks the log of a failed migrate Job in deploy/k8s/install.sh: every line
# marked, an empty one, one with control characters and bytes that are not UTF-8, and the last one without a newline
# (given one); an empty log prints nothing.
# mark_log_of NAMESPACE < LOG: mark_log of lib.sh itself.
mark_log_of() { (. "$here/../k8s/lib.sh" && mark_log "$1"); }
printf 'first\n\npanic: x\r\001y\377z\nlast' | mark_log_of svp >"$work/marked"
printf '    [svp] first\n    [svp] \n    [svp] panic: x\r\001y\377z\n    [svp] last\n' >"$work/marked.want"
cmp -s "$work/marked" "$work/marked.want" && ok "mark_log: every line marked, whatever its bytes, the last one ended" ||
  fail "mark_log: every line marked, whatever its bytes, the last one ended"
printf 'one\n' | mark_log_of svp >"$work/marked"
[ "$(cat "$work/marked")" = "    [svp] one" ] && ok "mark_log: one line, one marked line" || fail "mark_log: one line, one marked line"
mark_log_of svp </dev/null >"$work/marked"
[ ! -s "$work/marked" ] && ok "mark_log: an empty log prints nothing" || fail "mark_log: an empty log prints nothing"
grep -qF 'mark_log "$namespace" <"$migrate_log" >&2' "$here/../k8s/install.sh" &&
  ok "mark_log: install.sh marks a failed migrate Job's log with it" ||
  fail "mark_log: install.sh marks a failed migrate Job's log with it"

# --- The fake results of a k3d run.
out=$work/out
mkdir -p "$out/logs" "$out/samples"
echo dev-k3d >"$out/scenario"
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$out/results.tsv"
printf '01\tk8s-up\tok\t0\t100\t160\t60\t\n02\tk8s-smoke\tfail\t1\t160\t170\t10\t\n' >>"$out/results.tsv"
printf '03\tdrill-k8s-keda\tfail\t1\t170\t180\t10\t\n04\tdrill-k8s-threats\tfail\t1\t180\t190\t10\t\n' >>"$out/results.tsv"
printf '05\tdrill-alert-to-sentry\tfail\t1\t190\t200\t10\t\n06\tdrill-obs-threats\tok\t0\t200\t210\t10\t\n' \
  >>"$out/results.tsv"
printf '12\tk8s-up\tfail\t1\t210\t220\t10\t\n13\tk8s-up\tfail\t1\t220\t230\t10\t\n' >>"$out/results.tsv"
# A target that quotes service logs: the log of a failed migrate Job (JSON records, one with a secret, and a panic),
# marked by mark_log as install.sh marks it, and the gateway's access log line of a trace, between lines of its own.
{
  echo "ok    cluster ready"
  echo "Job svp/feed-service-migrate failed; log of its last failed attempt, copied before its pod was deleted:"
  {
    echo '{"time":"2026-10-25T08:00:00Z","level":"WARN","msg":"database not reachable, retrying","attempt":1}'
    echo "{\"time\":\"2026-10-25T08:00:01Z\", \"level\": \"ERROR\", \"msg\":\"dsn $quoted_secret\"}"
    echo "panic: MIGRATE-PANIC-MARKER"
  } | mark_log_of svp
  echo "FAIL  install feed-service"
} >"$out/logs/01-k8s-up.log"
# A failed make k8s-up with the report of unready_report above, and two log lines of namespaces whose logs never get
# in, as a mistake of unready_report would print them; another whose broker log holds a cluster secret.
{
  echo "helm upgrade --install redpanda (wave 3, namespace svp-data)"
  cat "$unready"
  echo "    [svp] APP-FORGED-MARKER"
  echo "    [envoy-gateway-system] ENVOY-MARKER"
  echo "FAIL  install redpanda"
} >"$out/logs/12-k8s-up.log"
printf '    [svp-data] SECRET-TAIL-MARKER sasl password %s\nFAIL  install redpanda\n' "$kafka_secret" \
  >"$out/logs/13-k8s-up.log"
{
  echo "ok    T2 08:00:05Z: earliest error trace after T0 abc"
  echo 'ok    T3 08:00:09Z: gateway access log of trace abc: {"route":"/feed","status":"503","user_id":"USER-ID-MARKER"}'
  echo "FAIL  T4 GlitchTip has an event"
} >"$out/logs/05-drill-alert-to-sentry.log"
# A failed target that printed a secret on stdout and a JWT on stderr, both into its log as verify-run.sh sends them.
{
  echo "ok    step 1"
  echo "response body: password=$quoted_secret"
  echo "Authorization header seen: $jwt" >&2
  echo "FAIL  step 2"
} >"$out/logs/02-k8s-smoke.log" 2>&1
{
  for i in $(seq 1 60); do echo "sample $i lag 3"; done
  echo "FAIL  KEDA-TAIL-MARKER scale down took too long"
} >"$out/logs/03-drill-k8s-keda.log"
# The output of a threat model drill: item headings, verdicts, what the probes got back (in the forms the filter must
# not take for one of its own lines), the closing table.
{
  echo "== IN-2/IN-4"
  echo "ok    IN-4: svp-feed-service may only read its topics (svp-admin)"
  echo "probe answered: PROBE-BODY-MARKER"
  echo "== NP-1"
  echo "FAIL  NP-1: probe reached s3"
  # An item stopped under set -e: bash's own line is left out, the drill's line after it is kept.
  echo "deploy/k8s/drills/threats.sh: line 1742: BASH-ERROR-MARKER: unbound variable"
  echo "FAIL  NP-1: the item ended with exit status 1"
  echo "== PROBE-HEADING-MARKER: body"
  echo "  PROBE-INDENT-MARKER   PASS with more"
  echo "== WEB-7"
  echo "ok    user @drill_ab12 registered: 303, session cookie __Host-Http-svp_sid in the drill's cookie jar"
  echo
  echo "drill-k8s-threats (20261025T080000Z-ab12)"
  printf '  %-14s %s\n' ITEM RESULT IN-2/IN-4 PASS NP-1 FAIL
} >"$out/logs/04-drill-k8s-threats.log"
# Verdict lines of a threat drill holding the session cookie in a form its value is written in, one file each: a
# header, a cookie jar line, JSON, and the name ending a line. A plain target output that names the cookie in prose.
printf 'FAIL  WEB-2: sent Cookie: __Host-Http-svp_sid=SID-MARKER\n' >"$out/logs/07-drill-k8s-threats.log"
printf 'ok    jar: svp.localhost\tFALSE\t/\tTRUE\t0\t__Host-Http-svp_sid\tSID-MARKER\n' >"$out/logs/08-drill-k8s-threats.log"
printf 'FAIL  WEB-9: got {"name":"svp_sid","value":"SID-MARKER"}\n' >"$out/logs/09-drill-obs-threats.log"
printf 'FAIL  WEB-9: the cookie jar holds svp_sid\n' >"$out/logs/10-drill-obs-threats.log"
printf 'ok    session cookie __Host-Http-svp_sid in the jar\n' >"$out/logs/11-k8s-web-e2e.log"
printf 'ok    OPS-1: 8 loopback ports\nprobe answered: PROBE-OBS-MARKER\ndrill-obs-threats: all checks passed\n' \
  >"$out/logs/06-drill-obs-threats.log"
printf '100\t4000000\t0\t12\n' >"$out/samples/host.tsv"
echo 4242 >"$out/sampler.pid"
echo '{"label":"start","mem_usage_median_mib":5800}' >"$out/ram-rest-start.json"
printf 'RAM at rest (start): MEM USAGE median 5800 MiB\nfree -m of the runner at rest:\n%s\n' \
  "Mem:  15995  9000  1200  50  5795  6700" >"$out/ram-rest-start.txt"
echo '{}' >"$out/.hidden.json"
echo 230 >"$out/run-end"

# --- The fake checkout's results.
d=$repo/.k8s/drills
echo '{"result":"PASS","screenshot":"data:image/jpeg;base64,/9j/eyJabcdefghijklmnopqrstuvwxyz0123"}' >"$d/canary-drill-1.json"
echo "{\"restored\":true,\"s3\":\"$cluster_secret\"}" >"$d/backup-1.json"
echo "{\"blob\":\"$(b64 "$env_secret")\"}" >"$d/b64-1.json"
echo "{\"config\":\"$line_secret\"}" >"$d/multiline-1.json"
echo "{\"roles\":[\"$role_name\"],\"admin\":\"admin@svp.local\",\"org\":\"svp\",\"kid\":\"kid-of-the-signing-key\",\"release\":\"$helm_payload\"}" \
  >"$d/names-1.json"
printf '%s\n' "$identifiers" | jq -R -s '{identifiers: .}' >"$d/identifiers-1.json"
echo "{\"kafka\":\"$kafka_secret\"}" >"$d/kafka-1.json"
# A JWT and nothing else: the only file whose drop the jwt rule alone decides.
echo "{\"t\":\"$jwt\"}" >"$d/jwt-1.json"
echo "{\"frame\":\"$bin_secret\"}" >"$d/binary-piece-1.json"
echo "probe output" >"$d/threats-1.log"
echo "1792332629000 u1 explore 200 12" >"$d/traffic-1.log"
head -c 6000000 /dev/zero | tr '\0' a >"$d/big-1.json"
ln -s ../../.env "$d/link-1.json"
echo "CA" >"$repo/.k8s/ca.crt"
echo '{"metrics":{"http_reqs":{"count":10}}}' >"$repo/.k6/local-1/summary.json"
echo '{"raw":true}' >"$repo/.k6/local-1/machine.json"
# The summaries of the k6 Job's pods (deploy/k6/cloud/run.sh logs): one clean, one holding a cluster secret.
k6c=$repo/.k6/cloud-20261026T080000Z
mkdir -p "$k6c"
echo '{"thresholds_ok":true,"dropped_iterations":0}' >"$k6c/pod-0.json"
echo "{\"thresholds_ok\":true,\"header\":\"$cluster_secret\"}" >"$k6c/pod-1.json"
echo '{"raw":true}' >"$k6c/machine.json"
l=$repo/web/test-results/lighthouse
echo "<html>Set-Cookie: svp=1</html>" >"$l/a.report.html"
echo '{"audits":{}}' >"$l/b.report.json"
echo '{}' >"$l/.lighthouseci/lhr-1.json"
echo 'zip' >"$repo/web/test-results/playwright/trace.zip"
echo '{"status":"failed","failedTests":["abc-123"]}' >"$repo/web/test-results/playwright/.last-run.json"
echo '{"header":"Bearer abc"}' >"$repo/web/test-results/glitchtip-chromium.json"
echo '{"cookie":"svp_sid=abc"}' >"$repo/web/test-results/measure-web-1.json"
echo "{\"key\":\"$private_key_header\"}" >"$repo/web/test-results/measure-upload-1.json"

# job: the variables a GitHub Actions job runs the two scripts with (deploy/ci/platform.sh prints masks and warnings
# as the runner's commands only there), with the job's temp directory in $work.
job=(GITHUB_ACTIONS=true RUNNER_TEMP="$work")
# collect NAME SECRETS_DIR [VAR=VALUE...]: runs verify-collect.sh into $work/art-NAME, its stdout and stderr in
# $work/NAME.log.
collect() {
  local name=$1 secrets=$2
  shift 2
  rm -rf "$work/art-$name"
  env "${job[@]}" PATH="$work/bin:$PATH" SVP_VERIFY_REPO="$repo" SVP_VERIFY_OUT="$out" \
    SVP_VERIFY_ARTIFACT="$work/art-$name" \
    SVP_VERIFY_SECRETS="$secrets" "$@" "$here/verify-collect.sh" >"$work/$name.log" 2>&1 ||
    fail "$name: verify-collect.sh exits 0"
}
# expect NAME SRC kept|RULE: the line of SRC in files.txt of run NAME.
expect() {
  local got
  got=$(awk -F '\t' -v s="$2" '$2 == s { print ($1 == "kept" ? "kept" : $3) }' "$work/art-$1/files.txt")
  if [ "$got" = "$3" ]; then ok "$1: $2 $3"; else fail "$1: $2: want $3, got '${got:-not listed}'"; fi
}
# no_leak NAME [LIST]: no fake secret (of LIST, default all of them) in the output of run NAME outside the
# ::add-mask:: lines, none in its artifact.
no_leak() {
  local list=$work/${2:-all-secrets}
  if grep -v '^::add-mask::' "$work/$1.log" | grep -qF -f "$list"; then
    fail "$1: a secret reached the job's log outside ::add-mask::"
  else
    ok "$1: no secret in the job's log outside ::add-mask::"
  fi
  if grep -rqaF -f "$list" "$work/art-$1"; then
    fail "$1: a secret reached the artifact"
  else
    ok "$1: no secret in the artifact"
  fi
}
has() { if grep -qF -- "$3" "$work/$1.log"; then ok "$1: $2"; else fail "$1: $2"; fi; }
lacks() { if grep -qF -- "$3" "$work/$1.log"; then fail "$1: $2"; else ok "$1: $2"; fi; }
same() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: want '$2', got '$3'"; fi; }

# --- verify-mask.sh env on its own: what it masks, what it keeps, and the marker only once.
mask() {
  env "${job[@]}" SVP_VERIFY_REPO="$repo" SVP_VERIFY_SECRETS="$work/mask-secrets" "$here/verify-mask.sh" env \
    >"$work/$1.log" 2>&1
}
mask mask1
# A % of a value goes out as %25, which the runner reads back as %.
for v in "$env_secret" "${quoted_secret//%/%25}" "$dsn_secret" "$(b64 "$quoted_secret")"; do
  grep -qxF "::add-mask::$v" "$work/mask1.log" || fail "mask: a secret of .env (or its base64) is masked"
done
ok "mask: the secrets of .env are masked, raw and base64, special characters included (% as %25)"
for v in abc12 admin@svp.local svp kid-of-the-signing-key; do
  if grep -qF "::add-mask::$v" "$work/mask1.log"; then fail "mask: '$v' is not masked"; fi
done
ok "mask: a short value, the admin email, the org and a key id are not masked"
[ "$(grep -c '^mask-check: ' "$work/mask1.log")" = 1 ] && ok "mask: one mask-check line" || fail "mask: one mask-check line"
marker=$(sed -n 's/^mask-check: //p' "$work/mask1.log")
grep -qxF "::add-mask::$marker" "$work/mask1.log" && ok "mask: the marker is masked before it is printed" ||
  fail "mask: the marker is masked before it is printed"
# GNU stat first: BSD stat rejects -c, while GNU stat takes -f too, for something else.
[ "$(stat -c %a "$work/mask-secrets/env.values" 2>/dev/null || stat -f %Lp "$work/mask-secrets/env.values")" = 600 ] &&
  ok "mask: env.values has mode 600" || fail "mask: env.values has mode 600"
mask mask2
if grep -q '::add-mask::\|^mask-check:' "$work/mask2.log"; then
  fail "mask: a second call masks nothing new and prints no marker"
else
  ok "mask: a second call masks nothing new and prints no marker"
fi

# --- verify-mask.sh cluster on binary values, each a Secret of namespace svp-obs of a cluster of its own. The cut it
# made with jq's splits() took minutes for 200 KiB (its time grows with the square of the value): a value that size is
# done in seconds now. On small values it keeps what that cut kept: random bytes, and text with CR, NUL, tab, the C1
# control NEL, U+FFFD itself, a byte that is not UTF-8, blanks around a line, several lines.
# mask_cluster NAME DIR FILE...: verify-mask.sh cluster with a fake kubectl listing one Secret per FILE (raw bytes), in a
# list of its own ($work/NAME.secrets/cluster.values); its output in $work/NAME.log.
mask_cluster() {
  local name=$1 dir=$2 f i=0
  shift 2
  mkdir -p "$dir"
  for f in "$@"; do
    i=$((i + 1))
    base64 <"$f" | tr -d '\n' | jq -R -s --arg k "v$i" '{($k): .}'
  done | jq -s '{items: [{type: "Opaque", metadata: {name: "binary"}, data: add}]}' >"$dir/svp-obs.json"
  env "${job[@]}" PATH="$work/bin:$PATH" FAKE_KUBECTL_DIR="$dir" SVP_VERIFY_SECRETS="$work/$name.secrets" \
    "$here/verify-mask.sh" cluster >"$work/$name.log" 2>&1 || fail "$name: verify-mask.sh cluster exits 0"
}
mb=$work/mask-bin
mkdir -p "$mb"
head -c 204800 /dev/urandom >"$mb/big"
started=$SECONDS
mask_cluster mask-big "$mb/kube-big" "$mb/big"
took=$((SECONDS - started))
[ "$took" -le 10 ] && ok "mask: a binary value of 200 KiB is cut in ${took} s (10 at most)" ||
  fail "mask: a binary value of 200 KiB is cut in ${took} s (10 at most)"
# comm, not grep -xF: BSD grep runs out of memory on a pattern that long.
{ base64 <"$mb/big" | tr -d '\n'; echo; } >"$mb/big.b64"
[ "$(LC_ALL=C comm -12 "$mb/big.b64" "$work/mask-big.secrets/cluster.values" | grep -c .)" = 1 ] &&
  ok "mask: the binary value of 200 KiB is kept whole in base64" || fail "mask: the binary value of 200 KiB is kept whole in base64"
for i in 1 2 3; do head -c 3000 /dev/urandom >"$mb/small-$i"; done
printf '%s' "$binary_value" >"$mb/small-4"
printf '  lead-and-trail-%s  \r\ncr-nul-%s\000tab-%s\tnel-%s\302\205fffd-%s\357\277\275bad-%s\377end-of-it\n\n' \
  "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" \
  "$(openssl rand -hex 4)" "$(openssl rand -hex 4)" >"$mb/small-5"
mask_cluster mask-small "$mb/kube-small" "$mb"/small-*
# The cut as it was, with the length rule of verify-mask.sh, over the same values.
for f in "$mb"/small-*; do base64 <"$f" | tr -d '\n'; echo; done |
  jq -R -r '., (@base64d | [splits("[[:cntrl:]\ufffd]")][] | gsub("^\\s+|\\s+$"; ""))' |
  while IFS= read -r v || [ -n "$v" ]; do [ "${#v}" -lt 8 ] || printf '%s\n' "$v"; done | LC_ALL=C sort -u >"$mb/want"
cmp -s "$mb/want" "$work/mask-small.secrets/cluster.values" &&
  ok "mask: small binary and text values give the pieces the regex cut gave ($(wc -l <"$mb/want" | tr -d ' ') lines)" ||
  fail "mask: small binary and text values give the pieces the regex cut gave"

# --- k3d run, cluster readable.
collect k3d "$work/secrets-k3d"
for src in '$SVP_VERIFY_OUT/results.tsv' '$SVP_VERIFY_OUT/scenario' '$SVP_VERIFY_OUT/samples/host.tsv' \
  '$SVP_VERIFY_OUT/logs/01-k8s-up.log' '$SVP_VERIFY_OUT/logs/03-drill-k8s-keda.log' \
  '$SVP_VERIFY_OUT/logs/04-drill-k8s-threats.log (verdict lines)' '$SVP_VERIFY_OUT/ram-rest-start.json' \
  '$SVP_VERIFY_OUT/ram-rest-start.txt' \
  '$SVP_VERIFY_OUT/logs/06-drill-obs-threats.log (verdict lines)' \
  '$SVP_VERIFY_OUT/logs/05-drill-alert-to-sentry.log' .k8s/drills/canary-drill-1.json .k8s/drills/names-1.json \
  .k8s/drills/identifiers-1.json .k8s/drills/traffic-1.log .k6/local-1/summary.json \
  web/test-results/lighthouse/b.report.json; do
  expect k3d "$src" kept
done
expect k3d .k8s/drills/kafka-1.json secret-value
expect k3d .k8s/drills/jwt-1.json jwt
expect k3d .k8s/drills/binary-piece-1.json secret-value
expect k3d '$SVP_VERIFY_OUT/logs/02-k8s-smoke.log' secret-value
expect k3d '$SVP_VERIFY_OUT/sampler.pid' not-allowed
expect k3d '$SVP_VERIFY_OUT/run-end' not-allowed
lacks k3d "verify-run.sh's end mark is dropped without a warning" 'run-end'
expect k3d '$SVP_VERIFY_OUT/.hidden.json' hidden
expect k3d .k8s/drills/backup-1.json secret-value
expect k3d .k8s/drills/b64-1.json secret-value
expect k3d .k8s/drills/multiline-1.json secret-value
expect k3d .k8s/drills/threats-1.log not-allowed
expect k3d .k8s/drills/big-1.json too-large
expect k3d .k8s/drills/link-1.json not-regular
expect k3d .k6/local-1/machine.json not-allowed
expect k3d .k6/cloud-20261026T080000Z/pod-0.json kept
expect k3d .k6/cloud-20261026T080000Z/pod-1.json secret-value
expect k3d .k6/cloud-20261026T080000Z/machine.json not-allowed
[ -f "$work/art-k3d/k6/cloud-20261026T080000Z/pod-0.json" ] && ok "k3d: a k6 pod's summary lands under k6/" ||
  fail "k3d: a k6 pod's summary lands under k6/"
expect k3d web/test-results/lighthouse/a.report.html set-cookie
expect k3d web/test-results/lighthouse/.lighthouseci/lhr-1.json hidden
expect k3d web/test-results/playwright/trace.zip not-allowed
expect k3d web/test-results/playwright/.last-run.json not-allowed
lacks k3d "Playwright's .last-run.json is dropped without a warning" '.last-run.json'
has k3d "another hidden file still gets a warning" 'lighthouse/.lighthouseci/lhr-1.json: hidden'
expect k3d web/test-results/glitchtip-chromium.json bearer
expect k3d web/test-results/measure-web-1.json session-cookie
expect k3d web/test-results/measure-upload-1.json private-key
for n in 07-drill-k8s-threats 08-drill-k8s-threats 09-drill-obs-threats 10-drill-obs-threats; do
  expect k3d "\$SVP_VERIFY_OUT/logs/$n.log (verdict lines)" session-cookie
done
expect k3d '$SVP_VERIFY_OUT/logs/11-k8s-web-e2e.log' session-cookie
grep -rqa SID-MARKER "$work/art-k3d" && fail "k3d: no session cookie value in the artifact" ||
  ok "k3d: no session cookie value in the artifact"
[ -f "$work/art-k3d/k8s-drills/canary-drill-1.json" ] && [ -f "$work/art-k3d/k6/local-1/summary.json" ] &&
  [ -f "$work/art-k3d/web-test-results/lighthouse/b.report.json" ] && ok "k3d: the checkout's files under visible folders" ||
  fail "k3d: the checkout's files under visible folders"
[ -z "$(find "$work/art-k3d" -name '.*')" ] && ok "k3d: no hidden file in the artifact" || fail "k3d: no hidden file in the artifact"
[ ! -e "$work/art-k3d/ca.crt" ] && ! grep -q 'ca.crt' "$work/art-k3d/files.txt" && ok "k3d: .k8s/ca.crt not a candidate" ||
  fail "k3d: .k8s/ca.crt not a candidate"
grep -q 'PROBE-BODY-MARKER' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" &&
  fail "k3d: the threat drill's probe output is left out" || ok "k3d: the threat drill's probe output is left out"
grep -q '^FAIL  NP-1' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" && ok "k3d: the threat drill's verdicts kept" ||
  fail "k3d: the threat drill's verdicts kept"
grep -q '^ok    IN-4: svp-feed-service .*(svp-admin)' "$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log" &&
  ok "k3d: a verdict naming Kafka users and svp-admin is kept" || fail "k3d: a verdict naming Kafka users and svp-admin is kept"
v=$work/art-k3d/logs/04-drill-k8s-threats.verdicts.log
want=$(printf '%s\n' "== IN-2/IN-4" "ok    IN-4: svp-feed-service may only read its topics (svp-admin)" "== NP-1" \
  "FAIL  NP-1: probe reached s3" "FAIL  NP-1: the item ended with exit status 1" "== WEB-7" \
  "ok    user @drill_ab12 registered: 303, session cookie __Host-Http-svp_sid in the drill's cookie jar" \
  "drill-k8s-threats (20261025T080000Z-ab12)" "$(printf '  %-14s %s' ITEM RESULT)" \
  "$(printf '  %-14s %s' IN-2/IN-4 PASS)" "$(printf '  %-14s %s' NP-1 FAIL)")
[ "$(cat "$v")" = "$want" ] &&
  ok "k3d: the threat drill keeps its item headings, verdicts (the session cookie named in prose) and closing table, nothing else" ||
  fail "k3d: the threat drill keeps its item headings, verdicts (the session cookie named in prose) and closing table, nothing else"
v=$work/art-k3d/logs/06-drill-obs-threats.verdicts.log
[ "$(cat "$v")" = "$(printf '%s\n' "ok    OPS-1: 8 loopback ports" "drill-obs-threats: all checks passed")" ] &&
  ok "k3d: the threat drill's closing line is kept, its probe output left out" ||
  fail "k3d: the threat drill's closing line is kept, its probe output left out"
masked=0
for v in $identifiers; do
  grep -qxF -e "::add-mask::$v" -e "::add-mask::$(b64 "$v")" "$work/k3d.log" && masked=1
done
[ "$masked" = 0 ] && ok "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked" ||
  fail "k3d: user names, emails, key ids and mechanisms of the Secrets are not masked"
grep -qxF "::add-mask::$kafka_secret" "$work/k3d.log" && ok "k3d: a password beside a user name is masked" ||
  fail "k3d: a password beside a user name is masked"
# Service log lines quoted by a target are left out of its copy, and files.txt counts them.
a=$work/art-k3d/logs
if grep -qE '"(msg|level)"' "$a/01-k8s-up.log" || grep -q 'USER-ID-MARKER' "$a/05-drill-alert-to-sentry.log"; then
  fail "k3d: service log lines are left out of the targets' outputs"
else
  ok "k3d: service log lines are left out of the targets' outputs"
fi
grep -q '^FAIL  install feed-service' "$a/01-k8s-up.log" && grep -q '^FAIL  T4' "$a/05-drill-alert-to-sentry.log" &&
  ok "k3d: the targets' own lines around them are kept" || fail "k3d: the targets' own lines around them are kept"
grep -qF "$(printf 'kept\t$SVP_VERIFY_OUT/logs/01-k8s-up.log\tlogs/01-k8s-up.log\t3 service log line(s) left out')" \
  "$work/art-k3d/files.txt" && ok "k3d: files.txt counts the lines left out" || fail "k3d: files.txt counts the lines left out"
grep -q MIGRATE-PANIC-MARKER "$a/01-k8s-up.log" && fail "k3d: a migrate Job's log line that is no JSON is left out" ||
  ok "k3d: a migrate Job's log line that is no JSON is left out"
# The log tails of unready_report: an infrastructure container's kept, a line of namespace svp or of Envoy left out,
# in the artifact and in the end of the failed target printed to the job's log alike.
expect k3d '$SVP_VERIFY_OUT/logs/12-k8s-up.log' kept
expect k3d '$SVP_VERIFY_OUT/logs/13-k8s-up.log' secret-value
grep -qxF "    [svp-data] INFRA-TAIL-MARKER" "$a/12-k8s-up.log" && grep -qF INFRA-MESSAGE-MARKER "$a/12-k8s-up.log" &&
  grep -q '^pod svp/gateway-abc, container gateway: ' "$a/12-k8s-up.log" &&
  ok "k3d: the log tail of an infrastructure container and every container's state are kept" ||
  fail "k3d: the log tail of an infrastructure container and every container's state are kept"
if grep -qE 'APP-FORGED-MARKER|ENVOY-MARKER' "$a/12-k8s-up.log"; then
  fail "k3d: a log line of namespace svp or envoy-gateway-system is left out"
else
  ok "k3d: a log line of namespace svp or envoy-gateway-system is left out"
fi
grep -qF "$(printf 'kept\t$SVP_VERIFY_OUT/logs/12-k8s-up.log\tlogs/12-k8s-up.log\t2 service log line(s) left out')" \
  "$work/art-k3d/files.txt" && ok "k3d: files.txt counts the log lines of other namespaces" ||
  fail "k3d: files.txt counts the log lines of other namespaces"
has k3d "the log tail of an infrastructure container of a failed target is printed" '    [svp-data] INFRA-TAIL-MARKER'
lacks k3d "a log line of namespace svp of a failed target is not printed" APP-FORGED-MARKER
lacks k3d "a log line of Envoy of a failed target is not printed" ENVOY-MARKER
lacks k3d "a log tail with a secret is not printed" SECRET-TAIL-MARKER
lacks k3d "a failed target's service log lines are not printed" 'USER-ID-MARKER'
no_leak k3d
has k3d "the end of a failed target's clean output is printed" KEDA-TAIL-MARKER
has k3d "the verdicts of a failed threat drill are printed" 'FAIL  NP-1'
has k3d "the closing table of a failed threat drill is printed" "$(printf '  %-14s %s' NP-1 FAIL)"
lacks k3d "the probe output of a threat drill is not printed" 'PROBE-'
lacks k3d "the output of a failed target with a secret is not printed" 'step 2'
has k3d "a dropped file gets a warning with its rule" '::warning::.k8s/drills/backup-1.json: secret-value'
lacks k3d "not-allowed files get no warning" '::warning::.k6/local-1/machine.json'
if grep -qF "::add-mask::$helm_payload" "$work/k3d.log" || grep -qF "::add-mask::$role_name" "$work/k3d.log"; then
  fail "k3d: Helm release payloads and user names are not masked"
else
  ok "k3d: Helm release payloads and user names are not masked"
fi
grep -qxF "::add-mask::$cluster_secret" "$work/k3d.log" && grep -qxF "::add-mask::$line_secret" "$work/k3d.log" &&
  ok "k3d: a cluster Secret and a line of a Secret of several lines are masked" ||
  fail "k3d: a cluster Secret and a line of a Secret of several lines are masked"
masked=1
for v in "$cr_secret" "$ctl_secret" "$nl_secret" "$bin_secret" "$(b64 "$binary_value")"; do
  grep -qxF "::add-mask::$v" "$work/k3d.log" || masked=0
done
[ "$masked" = 1 ] &&
  ok "k3d: each piece of a binary value between control characters or bytes not UTF-8 is masked, and the value whole" ||
  fail "k3d: each piece of a binary value between control characters or bytes not UTF-8 is masked, and the value whole"
# The replacement character U+FFFD in UTF-8: what a byte that is not UTF-8 becomes when decoded as text.
if grep -a '^::add-mask::' "$work/k3d.log" | LC_ALL=C grep -q -e '[[:cntrl:]]' -e $'\xef\xbf\xbd'; then
  fail "k3d: no mask line holds a control character or U+FFFD"
else
  ok "k3d: no mask line holds a control character or U+FFFD"
fi

# --- k3d run, the cluster never read: only the files written on the runner itself.
collect dead "$work/secrets-dead" FAKE_KUBECTL_FAIL=1
for src in '$SVP_VERIFY_OUT/results.tsv' '$SVP_VERIFY_OUT/scenario' '$SVP_VERIFY_OUT/samples/host.tsv'; do
  expect dead "$src" kept
done
for src in '$SVP_VERIFY_OUT/logs/01-k8s-up.log' '$SVP_VERIFY_OUT/logs/03-drill-k8s-keda.log' \
  '$SVP_VERIFY_OUT/ram-rest-start.json' .k8s/drills/canary-drill-1.json .k8s/drills/backup-1.json .k6/local-1/summary.json; do
  expect dead "$src" no-secret-list
done
no_leak dead
lacks dead "no target output is printed" KEDA-TAIL-MARKER
has dead "the missing list is a warning" '::warning::verify-collect: a secret list could not be read'

# --- k3d run, cluster gone at the end but read while it ran: that list still counts.
collect late "$work/secrets-k3d" FAKE_KUBECTL_FAIL=1
expect late .k8s/drills/backup-1.json secret-value
expect late .k8s/drills/canary-drill-1.json kept
has late "it says the earlier list is used" 'the list read while it ran is used'
no_leak late

# --- k3d run, a Secret made again with a new value (drill-k8s-backup rebuilds Postgres): both values are searched for.
rebuilt_secret=$(openssl rand -hex 20)
printf '%s\n' "$rebuilt_secret" >>"$work/all-secrets"
cp -R "$work/kube" "$work/kube.orig"
for ns in svp-data svp-obs; do
  jq --arg old "$(b64 "$cluster_secret")" --arg new "$(b64 "$rebuilt_secret")" \
    '.items[].data |= map_values(if . == $old then $new else . end)' "$work/kube.orig/$ns.json" >"$work/kube/$ns.json"
done
echo "{\"s3\":\"$rebuilt_secret\"}" >"$d/rebuilt-1.json"
collect rebuilt "$work/secrets-k3d"
expect rebuilt .k8s/drills/backup-1.json secret-value
expect rebuilt .k8s/drills/rebuilt-1.json secret-value
no_leak rebuilt
rm -rf "$work/kube" "$d/rebuilt-1.json"
mv "$work/kube.orig" "$work/kube"

# --- compose-obs run: no cluster list needed, .env's still applies.
echo compose-obs >"$out/scenario"
# The object store's files of a compose-obs run: the samples of each compose container, the store's RAM over
# measure-upload and that target's summary, the outputs of the object store's tests and of the copy back to MinIO; and
# a copy's output that printed the store's root password (a value of .env).
printf '100\tsvp-s3-1\t130.6\n100\tsvp-gateway-1\t40\n' >"$out/samples/compose.tsv"
printf '100\tsvp-web-1\t2026-10-25T08:00:00.123456789Z\t1\n' >"$out/samples/restarts.tsv"
echo '{"container":"svp-s3-1","samples":30,"peak_mib":210,"limit_mib":512,"peak_under_limit":true}' \
  >"$out/ram-s3-upload.json"
echo 'RAM of svp-s3-1 during measure-upload: peak 210 MiB at 1970-01-01T00:01:40Z over 30 sample(s)' \
  >"$out/ram-s3-upload.txt"
printf '%s\n' '=== RUN   TestIntegrationPresignedPost' \
  '    integration_test.go:250: POST http://127.0.0.1:9000/media: status 400' \
  '--- PASS: TestIntegrationPresignedPost (0.20s)' \
  'object store tests: 39 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0' \
  >"$out/logs/14-test-stack-objstore.log"
printf '%s\n' 'object-store-copy: bucket media at MinIO: 12 object(s), 3456789 byte(s)' \
  "object-store-copy: READY videos' keys lost before this copy: 0" \
  's3-init (after the copy, on a store already initialised): 6 log line(s), 0 with a secret value of .env' \
  >"$out/logs/19-object-store-roundtrip.log"
printf 'object-store-copy: root %s\n' "$env_secret" >"$out/logs/20-object-store-roundtrip.log"
jq -n '{measured_at: "2026-10-25T08:00:00Z", browser: "chromium", file_mb: 100.2, duration_s: 160, upload_ms: 4200,
  throughput_mb_s: 23.9, cpu: {window_ms: 4300, task_ms: 300, script_ms: 120, task_share_pct: 7}, ready_ms: 190000}' \
  >"$repo/web/test-results/measure-upload-2.json"
collect compose "$work/secrets-compose" FAKE_KUBECTL_FAIL=1
for src in '$SVP_VERIFY_OUT/samples/compose.tsv' '$SVP_VERIFY_OUT/samples/restarts.tsv' \
  '$SVP_VERIFY_OUT/ram-s3-upload.json' \
  '$SVP_VERIFY_OUT/ram-s3-upload.txt' '$SVP_VERIFY_OUT/logs/14-test-stack-objstore.log' \
  '$SVP_VERIFY_OUT/logs/19-object-store-roundtrip.log' web/test-results/measure-upload-2.json; do
  expect compose "$src" kept
done
expect compose '$SVP_VERIFY_OUT/logs/20-object-store-roundtrip.log' secret-value
expect compose .k8s/drills/canary-drill-1.json kept
expect compose .k8s/drills/b64-1.json secret-value
expect compose '$SVP_VERIFY_OUT/logs/02-k8s-smoke.log' secret-value
# A compose run has no cluster, so a value only a cluster Secret would hold is no secret of that run.
expect compose .k8s/drills/backup-1.json kept
no_leak compose env-secrets

# --- An .env that breaks its rule: nothing masked, no value printed, nothing from the stack copied.
cp "$repo/.env" "$work/env.good"
printf 'SVP_BROKEN_PASSWORD=$%s\n' "$env_secret" >>"$repo/.env"
collect broken "$work/secrets-broken"
expect broken '$SVP_VERIFY_OUT/results.tsv' kept
expect broken .k8s/drills/canary-drill-1.json no-secret-list
has broken "the broken line is named" 'SVP_BROKEN_PASSWORD'
no_leak broken
cp "$work/env.good" "$repo/.env"

# --- verify-sample.sh stop: the criterion "the job ended in time" of runner.json, from results.tsv. A fake docker
# that fails (no container, no cluster) and a fake sudo whose dmesg prints nothing; the samples are a few lines.
sb=$work/sample-bin
so=$work/sample-out
mkdir -p "$sb" "$so/samples"
printf '#!/bin/sh\nexit 1\n' >"$sb/docker"
printf '#!/bin/sh\nexit 0\n' >"$sb/sudo"
chmod 755 "$sb/docker" "$sb/sudo"
echo compose-obs >"$so/scenario"
printf '100\t4000000\t0\t12\n105\t3900000\t0\t40\n' >"$so/samples/host.tsv"
printf '100\t50000000000\t100000000000\t0\n' >"$so/samples/disk.tsv"
for f in docker pods events event-polls; do : >"$so/samples/$f.tsv"; done
# Two compose containers, the object store sampled three times.
printf '100\tsvp-s3-1\t120\n100\tsvp-web-1\t300\n110\tsvp-s3-1\t260\n120\tsvp-s3-1\t140\n' >"$so/samples/compose.tsv"
# sample [--no-end] NAME [ROW...]: verify-sample.sh stop over a results.tsv of ROWs (none: no results.tsv) and, with
# ROWs and without --no-end, the end mark of verify-run.sh; prints within_deadline of runner.json and the targets it
# lists as cut, its output in $work/sample-NAME.log.
sample() {
  local name end=1
  [ "$1" = --no-end ] && { end=; shift; }
  name=$1
  shift
  rm -f "$so/results.tsv" "$so/runner.json" "$so/run-end"
  if [ "$#" -gt 0 ]; then
    printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$so/results.tsv"
    printf '%s\n' "$@" >>"$so/results.tsv"
    [ -z "$end" ] || echo 200 >"$so/run-end"
  fi
  env "${job[@]}" PATH="$sb:$PATH" SVP_VERIFY_OUT="$so" "$here/verify-sample.sh" stop >"$work/sample-$name.log" 2>&1 ||
    fail "sample $name: verify-sample.sh stop exits 0"
  jq -r '"\(.runner_enough.within_deadline) \(.targets_cut | join(","))"' "$so/runner.json" 2>/dev/null
}
# expect_deadline NAME WANT GOT
expect_deadline() {
  if [ "$3" = "$2" ]; then ok "sample $1: within_deadline and cut targets '$2'"; else fail "sample $1: want '$2', got '$3'"; fi
}
row() { local IFS=$'\t'; printf '%s' "$*"; }
expect_deadline in-time "true " "$(sample in-time "$(row 01 up ok 0 100 160 60 '')" "$(row 02 smoke fail 1 160 170 10 '')" \
  "$(row 03 lcp skipped '' 170 170 0 'disk: free space under 15% + 1 GiB')")"
expect_deadline timeout "false smoke=timeout" "$(sample timeout "$(row 01 up ok 0 100 160 60 '')" \
  "$(row 02 smoke timeout 124 160 1060 900 'stopped after 900 s')")"
expect_deadline deadline "false lcp=skipped" "$(sample deadline "$(row 01 up ok 0 100 160 60 '')" \
  "$(row 02 lcp skipped '' 170 170 0 deadline)")"
expect_deadline cancelled "false lcp=cancelled" "$(sample cancelled "$(row 01 up ok 0 100 160 60 '')" \
  "$(row 02 lcp cancelled '' 170 180 10 'the run was cancelled or the step timed out')")"
expect_deadline no-results "false " "$(sample no-results)"
# Cancelled, or stopped by the step's timeout-minutes, before the running target got its line: every line there is
# looks fine, only the end mark is missing.
expect_deadline no-end "false " "$(sample --no-end no-end "$(row 01 up ok 0 100 160 60 '')")"
grep -q '^runner: results.tsv read true, verify-run.sh reached its end false, ' "$work/sample-no-end.log" &&
  ok "sample: runner.txt says verify-run.sh did not reach its end" ||
  fail "sample: runner.txt says verify-run.sh did not reach its end"
same "sample: runner.json has the highest MEM USAGE of each compose container, with its time" \
  "svp-s3-1=260@1970-01-01T00:01:50Z svp-web-1=300@1970-01-01T00:01:40Z" \
  "$(jq -r '.compose_container_memory_max_mib | to_entries | map("\(.key)=\(.value.mib)@\(.value.at)") | join(" ")' \
    "$so/runner.json")"
# Restarts of compose containers, also of those removed since (make down, a drill that recreates a service): web
# restarted once, then was made anew (count 0 again); the store restarted twice, was made anew and restarted once more;
# the gateway never. The fake docker lists no container now, as after make down.
printf '%s\n' '100 svp-web-1 2026-10-25T08:00:00.1Z 0' '110 svp-web-1 2026-10-25T08:00:00.1Z 1' \
  '120 svp-web-1 2026-10-25T08:30:00.1Z 0' '100 svp-s3-1 2026-10-25T08:00:00.2Z 2' \
  '120 svp-s3-1 2026-10-25T08:30:00.2Z 0' '130 svp-s3-1 2026-10-25T08:30:00.2Z 1' \
  '100 svp-gateway-1 2026-10-25T08:00:00.3Z 0' | tr ' ' '\t' >"$so/samples/restarts.tsv"
sample restarts "$(row 01 up ok 0 100 160 60 '')" >/dev/null
same "sample: a restart counts after its container was made anew; the counts of each container of a name are summed" \
  "svp-s3-1=3 svp-web-1=1 false" \
  "$(jq -r '"\(.compose_restarts | join(" ")) \(.runner_enough.compose_no_restart)"' "$so/runner.json")"
grep -q '^runner: OOMKilled \[\], kernel OOM lines 0, compose restarts \[svp-s3-1=3 svp-web-1=1\]$' \
  "$work/sample-restarts.log" && ok "sample: runner.txt names the restarts" ||
  fail "sample: runner.txt names the restarts"
printf '100\tsvp-web-1\t2026-10-25T08:00:00.1Z\t0\n' >"$so/samples/restarts.tsv"
sample no-restart "$(row 01 up ok 0 100 160 60 '')" >/dev/null
same "sample: no restart, compose_no_restart" " true" \
  "$(jq -r '"\(.compose_restarts | join(" ")) \(.runner_enough.compose_no_restart)"' "$so/runner.json")"
: >"$so/samples/restarts.tsv"
grep -q '^runner enough: within_deadline=false ' "$work/sample-deadline.log" &&
  ok "sample: the runner enough line names within_deadline" || fail "sample: the runner enough line names within_deadline"
# Targets verify-run.sh skipped after a failed build target, or left out by SVP_VERIFY_TARGETS, did not run out of time.
expect_deadline infrastructure "true " "$(sample infrastructure "$(row 01 up fail 2 100 160 60 '')" \
  "$(row 02 smoke skipped '' 160 160 0 'infrastructure step failed')")"
expect_deadline unchosen "true " "$(sample unchosen "$(row 01 up ok 0 100 160 60 '')" \
  "$(row 02 smoke skipped '' 160 160 0 'not in targets')")"

# --- verify-sample.sh sample: one line of docker.tsv. Three media-worker pods Running (A, B, C); ffmpeg runs twice in
# A (cgroupfs path), once in B (systemd path), once on the runner itself (no pod), once in another pod D, and one pid
# has gone by the time its cgroup is read: 2 transcoding. memory.stat of both nodes, summed in MiB, exact keys only.
ss=$work/sample2-out
sb2=$work/sample2-bin
sp=$work/sample2-proc
mkdir -p "$ss" "$sb2"
uid_a=0a1b2c3d-0000-4000-8000-00000000000a
uid_b=0a1b2c3d-0000-4000-8000-00000000000b
uid_c=0a1b2c3d-0000-4000-8000-00000000000c
uid_d=0a1b2c3d-0000-4000-8000-00000000000d
cgroup_of() { mkdir -p "$sp/$1" && printf '0::%s\n' "$2" >"$sp/$1/cgroup"; }
cgroup_of 101 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/burstable/pod$uid_a/$(printf 'c%.0s' {1..64})"
cgroup_of 102 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/burstable/pod$uid_a/$(printf 'd%.0s' {1..64})"
cgroup_of 103 "/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${uid_b//-/_}.slice/cri-containerd-abc.scope"
cgroup_of 104 /user.slice/user-1001.slice/session-1.scope
cgroup_of 105 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/besteffort/pod$uid_d/$(printf 'f%.0s' {1..64})"
cat >"$sb2/pgrep" <<'EOF'
#!/bin/sh
[ "$*" = "-x ffmpeg" ] || exit 2
printf '101\n102\n103\n104\n105\n106\n'
EOF
cat >"$sb2/docker" <<'EOF'
#!/bin/sh
case $1 in
  stats)
    printf 'k3d-svp-server-0\t150.00%%\t3GiB / 15.6GiB\nk3d-svp-agent-0\t120.00%%\t2.5GiB / 15.6GiB\nk3d-svp-registry\t0.00%%\t20MiB / 15.6GiB\n'
    [ -z "${FAKE_COMPOSE:-}" ] ||
      printf 'svp-s3-1\t3.00%%\t%s / 512MiB\nsvp-web-1\t1.00%%\t1.25GiB / 1.5GiB\nother-1\t0.00%%\t9MiB / 1GiB\n' \
        "${FAKE_S3_MEM:-130.6MiB}" ;;
  ps)
    [ "$*" = "ps -aq --filter label=com.docker.compose.project=svp" ] || exit 2
    [ -z "${FAKE_COMPOSE:-}" ] || printf 'c0ffee000001\nc0ffee000002\n' ;;
  inspect)
    if [ "$3" = '{{.Name}} {{.Created}} {{.RestartCount}}' ]; then
      [ "$4 $5" = "c0ffee000001 c0ffee000002" ] || exit 2
      printf '/svp-s3-1 2026-10-25T00:00:01.5Z 0\n/svp-web-1 2026-10-25T00:00:02.5Z 1\n'
    else
      echo "running 0 2026-10-25T00:00:00Z"
    fi ;;
  exec)
    [ "$2" = "${FAKE_EXEC_FAIL:-}" ] && exit 1
    case $2 in
      k3d-svp-server-0) printf 'anon 1073741824\nanon_thp 999\nactive_file 524288000\ninactive_file 999\nkernel 104857600\n' ;;
      k3d-svp-agent-0) printf 'anon 536870912\nactive_file 209715200\nkernel_stack 999\nkernel 52428800\n' ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
cat >"$sb2/kubectl" <<'EOF'
#!/bin/sh
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && exit 1
case "$*" in
  *" get pods -l app.kubernetes.io/name=media-worker,app.kubernetes.io/component=server --field-selector=status.phase=Running -o jsonpath="*)
    printf '%s\n' "$FAKE_UIDS" ;;
  *" get nodes --no-headers") printf 'k3d-svp-server-0   Ready   control-plane   1h   v1.36.0+k3s1\nk3d-svp-agent-0   Ready,SchedulingDisabled   <none>   1h   v1.36.0+k3s1\n' ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$sb2/pgrep" "$sb2/docker" "$sb2/kubectl"
# take_sample [VAR=VALUE...]: verify-sample.sh sample; prints the new line of docker.tsv without its time.
take_sample() {
  rm -rf "$ss/samples"
  env "${job[@]}" PATH="$sb2:$PATH" SVP_VERIFY_OUT="$ss" SVP_VERIFY_PROC="$sp" \
    FAKE_UIDS="$(printf '%s\n' "$uid_a" "$uid_b" "$uid_c")" "$@" "$here/verify-sample.sh" sample >"$work/sample2.log" 2>&1 ||
    fail "sample: verify-sample.sh sample exits 0"
  cut -f 2- "$ss/samples/docker.tsv"
}
row_tail() { local IFS=$'\t'; printf '%s' "$*"; }
same "sample: 3 Running workers, 2 transcoding (ffmpeg in their pod), memory.stat of both nodes summed" \
  "$(row_tail 5652 0 150.00 120.00 3 0 running 0 2026-10-25T00:00:00Z 2 1536 700 150)" "$(take_sample)"
same "sample: no worker Running counts 0 transcoding" \
  "$(row_tail 5652 0 150.00 120.00 0 0 running 0 2026-10-25T00:00:00Z 0 1536 700 150)" "$(take_sample FAKE_UIDS=)"
[ ! -s "$ss/samples/compose.tsv" ] && [ ! -s "$ss/samples/restarts.tsv" ] &&
  ok "sample: no compose container, no compose.tsv or restarts.tsv line" ||
  fail "sample: no compose container, no compose.tsv or restarts.tsv line"
same "sample: compose containers are summed in docker.tsv" \
  "$(row_tail 5652 1411 150.00 120.00 3 0 running 0 2026-10-25T00:00:00Z 2 1536 700 150)" "$(take_sample FAKE_COMPOSE=1)"
same "sample: compose.tsv has a line per compose container, in MiB as docker stats gives it" \
  "svp-s3-1 130.6|svp-web-1 1280" "$(cut -f 2,3 "$ss/samples/compose.tsv" | tr '\t' ' ' | paste -sd '|' -)"
same "sample: restarts.tsv has each compose container's name, creation time and RestartCount" \
  "svp-s3-1 2026-10-25T00:00:01.5Z 0|svp-web-1 2026-10-25T00:00:02.5Z 1" \
  "$(cut -f 2- "$ss/samples/restarts.tsv" | tr '\t' ' ' | paste -sd '|' -)"
# The store just under its limit, as docker stats prints it: the sample keeps 511.6 and s3-peak passes on it.
take_sample FAKE_COMPOSE=1 FAKE_S3_MEM=511.6MiB >/dev/null
t_s3=$(awk -F '\t' '$2 == "svp-s3-1" { print $1 }' "$ss/samples/compose.tsv")
if env "${job[@]}" SVP_VERIFY_OUT="$ss" "$here/verify-sample.sh" s3-peak "$t_s3" "$t_s3" \
  >"$work/s3-peak-sampled.log" 2>&1; then
  same "sample: 511.6MiB of docker stats is under the 512 MiB limit of s3-peak" "511.6 true" \
    "$(jq -r '"\(.peak_mib) \(.peak_under_limit)"' "$ss/ram-s3-upload.json")"
else
  fail "sample: 511.6MiB of docker stats is under the 512 MiB limit of s3-peak (s3-peak failed)"
fi
same "sample: the API not answering gives - for the workers; one node's memory.stat unread gives - for all three" \
  "$(row_tail 5652 0 150.00 120.00 - - running 0 2026-10-25T00:00:00Z - - - -)" \
  "$(take_sample FAKE_KUBECTL_FAIL=1 FAKE_EXEC_FAIL=k3d-svp-agent-0)"

# --- verify-sample.sh peak START END over a fixture of docker.tsv (time, MEM USAGE k3d, compose, CPU server, agent,
# Running workers, nodes not Ready, server state, RestartCount, StartedAt, workers transcoding, anon, active_file,
# kernel). 5 samples with 2 Running workers but 1 transcoding and the highest MEM USAGE (run 5's window) must not count;
# then 8 with 2 transcoding (3 windows of 6), one the API missed, 5 more (no window), 1 worker; one sample before START
# and one after END.
po=$work/peak-out
mkdir -p "$po/samples"
peak_row() { local IFS=$'\t'; printf '%s\t%s\t0\t100.00\t100.00\t%s\t0\trunning\t0\t2026-10-25T00:00:00Z\t%s\t3000\t%s\t200\n' "$@"; }
{
  peak_row 90 99999 2 2 1000
  for t in 100 110 120 130 140; do peak_row "$t" $((9100 + t)) 2 1 1000; done
  peak_row 150 8000 2 2 -
  i=0
  for m in 8800 8820 8840 8860 8900 8950 9100; do
    peak_row $((160 + i * 10)) "$m" 2 2 $((1000 + i * 100))
    i=$((i + 1))
  done
  peak_row 230 8500 2 - 1000
  for t in 240 250 260 270 280; do peak_row "$t" 8500 2 2 1000; done
  peak_row 290 7000 1 0 1000
  peak_row 300 99999 2 2 1000
} >"$po/samples/docker.tsv"
env "${job[@]}" SVP_VERIFY_OUT="$po" "$here/verify-sample.sh" peak 100 295 >"$work/peak.log" 2>&1 ||
  fail "peak: verify-sample.sh peak exits 0"
same "peak: only samples with 2 workers transcoding count, 6 in a row; the median minus active_file over the same 6" \
  "20 19 13 8 1970-01-01T00:02:30Z 1970-01-01T00:03:40Z 3 8880 1970-01-01T00:02:50Z 7530 9240 9100 true" \
  "$(jq -r '[.samples, .samples_with_2_running, .samples_with_2_transcoding, .longest_run_with_2_transcoding.samples,
    .longest_run_with_2_transcoding.from, .longest_run_with_2_transcoding.to, .windows_of_6_with_2_transcoding,
    .peak_median_of_6_mib, .peak_window_from, .peak_median_of_6_minus_active_file_mib, .highest_sample_mib,
    .highest_sample_with_2_transcoding_mib, .peak_within_8_7_gib] | map(tostring) | join(" ")' "$po/ram-peak.json")"
has peak "ram-peak.txt is printed" "RAM peak during drill-k8s-keda: median of 6 with 2 workers transcoding 8880 MiB (3 window(s), longest run 8 samples)"
printf '%s\n' "$(peak_row 100 8000 2 1 1000)" >"$po/samples/docker.tsv"
env "${job[@]}" SVP_VERIFY_OUT="$po" "$here/verify-sample.sh" peak 100 295 >"$work/peak-none.log" 2>&1 ||
  fail "peak: verify-sample.sh peak exits 0 without a window"
same "peak: no 6 samples in a row with 2 transcoding gives no peak" "0 null null null" \
  "$(jq -r '[.windows_of_6_with_2_transcoding, .peak_median_of_6_mib, .peak_window_from, .peak_within_8_7_gib]
    | map(tostring) | join(" ")' "$po/ram-peak.json")"
if env "${job[@]}" SVP_VERIFY_OUT="$po" "$here/verify-sample.sh" peak 100 >/dev/null 2>&1; then
  fail "peak: a missing END is refused"
else
  ok "peak: a missing END is refused"
fi

# --- verify-sample.sh s3-peak START END over a fixture of compose.tsv: the object store's samples before, in and after
# the window, another container higher than it.
# s3_peak NAME LINE...: s3-peak 100 200 over a compose.tsv of LINEs ("time name MiB"); prints its exit status and the
# fields of ram-s3-upload.json, its output in $work/s3-peak-NAME.log.
s3_peak() {
  local name=$1 rc=0
  shift
  printf '%s\n' "$@" | tr ' ' '\t' >"$po/samples/compose.tsv"
  rm -f "$po/ram-s3-upload.json"
  env "${job[@]}" SVP_VERIFY_OUT="$po" "$here/verify-sample.sh" s3-peak 100 200 >"$work/s3-peak-$name.log" 2>&1 || rc=$?
  printf '%s ' "$rc"
  jq -r '[.samples, .before_mib, .before_at, .peak_mib, .peak_at, .peak_under_limit] | map(tostring) | join(" ")' \
    "$po/ram-s3-upload.json"
}
same "s3-peak: the highest sample of svp-s3-1 in the window, the last one before it" \
  "0 3 125 1970-01-01T00:01:30Z 300 1970-01-01T00:02:30Z true" \
  "$(s3_peak ok '80 svp-s3-1 110' '90 svp-s3-1 125' '90 svp-web-1 900' '100 svp-s3-1 200' '150 svp-s3-1 300' \
    '150 svp-web-1 1400' '200 svp-s3-1 180' '210 svp-s3-1 600')"
grep -qx 'RAM of svp-s3-1 during measure-upload: peak 300 MiB at 1970-01-01T00:02:30Z over 3 sample(s), before it 125 MiB, under the 512 MiB limit: true' \
  "$work/s3-peak-ok.log" && ok "s3-peak: ram-s3-upload.txt is printed" || fail "s3-peak: ram-s3-upload.txt is printed"
same "s3-peak: a sample at the limit fails" "1 2 null null 512 1970-01-01T00:02:30Z false" \
  "$(s3_peak limit '120 svp-s3-1 300' '150 svp-s3-1 512')"
same "s3-peak: a sample a fraction under the limit passes" "0 2 null null 511.6 1970-01-01T00:02:30Z true" \
  "$(s3_peak under '120 svp-s3-1 300' '150 svp-s3-1 511.6')"
same "s3-peak: no sample of the store in the window fails, with no peak" "1 0 110 1970-01-01T00:01:20Z null null null" \
  "$(s3_peak none '80 svp-s3-1 110' '150 svp-web-1 900' '210 svp-s3-1 600')"
if env "${job[@]}" SVP_VERIFY_OUT="$po" "$here/verify-sample.sh" s3-peak 100 >/dev/null 2>&1; then
  fail "s3-peak: a missing END is refused"
else
  ok "s3-peak: a missing END is refused"
fi

# --- s3-peak while the sampler runs: the window's last sample is taken before END but written after the step that
# reads the window has started (docker stats and the cluster take seconds to answer). A fake sampler, its command line
# that of the loop, writes it 2 s late, then a docker.tsv sample after END: s3-peak waits for that one, so its JSON
# holds every sample of compose.tsv in the window, the late one the highest.
lo=$work/late-out
ls_dir=$work/late-sampler
mkdir -p "$lo/samples" "$ls_dir"
printf '%s\n' '90 svp-s3-1 200' '100 svp-s3-1 250' '150 svp-s3-1 300' | tr ' ' '\t' >"$lo/samples/compose.tsv"
printf '150\t5000\n' >"$lo/samples/docker.tsv"
cat >"$ls_dir/verify-sample.sh" <<'EOF2'
sleep 2
printf '195\tsvp-s3-1\t338\n' >>"$LATE_OUT/samples/compose.tsv"
printf '195\t5000\n205\t5000\n' >>"$LATE_OUT/samples/docker.tsv"
for _ in $(seq 1 30); do sleep 1; done
EOF2
LATE_OUT=$lo bash "$ls_dir/verify-sample.sh" loop &
late_pid=$!
echo "$late_pid" >"$lo/sampler.pid"
if env "${job[@]}" SVP_VERIFY_OUT="$lo" "$here/verify-sample.sh" s3-peak 100 200 >"$work/s3-peak-late.log" 2>&1; then
  ok "s3-peak: exits 0 with the late sample"
else
  fail "s3-peak: exits 0 with the late sample"
fi
kill "$late_pid" 2>/dev/null || :
wait "$late_pid" 2>/dev/null || :
same "s3-peak: the last sample of the window, written late, is the peak" "3 338 1970-01-01T00:03:15Z" \
  "$(jq -r '[.samples, .peak_mib, .peak_at] | map(tostring) | join(" ")' "$lo/ram-s3-upload.json")"
same "s3-peak: its JSON matches compose.tsv over the window" \
  "$(awk -F '\t' '$2 == "svp-s3-1" && $1 >= 100 && $1 <= 200 { n++; if ($3 > m) m = $3 } END { print n, m }' \
    "$lo/samples/compose.tsv")" \
  "$(jq -r '"\(.samples) \(.peak_mib)"' "$lo/ram-s3-upload.json")"

# --- verify-sample.sh sample: one k6.tsv line per pod of namespace svp-load running k6, with nr_periods, nr_throttled
# and the cpu.max quota of the cgroup of its k6 process. k6 runs in pods E (cgroupfs path, a CPU limit), F (systemd
# path, none) and H (no cpu.max read) of svp-load, in pod G of another namespace, and in a container that is no pod
# (the compose stack's k6); pod E's cpu.stat has other keys around the two.
kb=$work/k6-bin
kp=$work/k6-proc
kg=$work/k6-cgroup
ko=$work/k6-out
mkdir -p "$kb" "$kp" "$kg" "$ko"
uid_e=0a1b2c3d-0000-4000-8000-0000000000e1
uid_f=0a1b2c3d-0000-4000-8000-0000000000f1
uid_g=0a1b2c3d-0000-4000-8000-0000000000a1
uid_h=0a1b2c3d-0000-4000-8000-0000000000f2
# k6_cgroup PID PATH NR_PERIODS NR_THROTTLED [CPU_MAX]: the cgroup of PID, its cpu.stat and, given, its cpu.max.
k6_cgroup() {
  mkdir -p "$kp/$1" "$kg$2"
  printf '0::%s\n' "$2" >"$kp/$1/cgroup"
  printf 'usage_usec 900\nnr_periods %s\nnr_throttled %s\nthrottled_usec 77\n' "$3" "$4" >"$kg$2/cpu.stat"
  [ -z "${5:-}" ] || printf '%s\n' "$5" >"$kg$2/cpu.max"
}
k6_cgroup 301 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/burstable/pod$uid_e/$(printf 'c%.0s' {1..64})" 1000 30 \
  '100000 100000'
k6_cgroup 302 "/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod${uid_f//-/_}.slice/cri-containerd-f.scope" 0 0 \
  'max 100000'
k6_cgroup 303 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/besteffort/pod$uid_g/$(printf 'd%.0s' {1..64})" 500 400 \
  '50000 100000'
k6_cgroup 304 "/system.slice/docker-$(printf 'a%.0s' {1..64}).scope" 700 600 '50000 100000'
k6_cgroup 305 "/system.slice/docker-$(printf 'e%.0s' {1..64}).scope/kubepods/burstable/pod$uid_h/$(printf 'b%.0s' {1..64})" 900 9
cat >"$kb/pgrep" <<'EOF2'
#!/bin/sh
[ "$*" = "-x k6" ] || exit 1
printf '301\n302\n303\n304\n305\n'
EOF2
cat >"$kb/kubectl" <<'EOF2'
#!/bin/sh
case "$*" in
  *" -n svp-load get pods -o jsonpath="*) printf '%s\n' "$FAKE_K6_UIDS" ;;
  *) exit 1 ;;
esac
EOF2
chmod 755 "$kb/pgrep" "$kb/kubectl"
env "${job[@]}" PATH="$kb:$sb2:$PATH" SVP_VERIFY_OUT="$ko" SVP_VERIFY_PROC="$kp" SVP_VERIFY_CGROUP="$kg" \
  FAKE_K6_UIDS="$(printf '%s\n' "$uid_e" "$uid_f" "$uid_h")" "$here/verify-sample.sh" sample >"$work/k6-sample.log" 2>&1 ||
  fail "k6 sample: verify-sample.sh sample exits 0"
same "k6 sample: a line per k6 pod of svp-load, its cgroup's nr_periods, nr_throttled and CPU quota" \
  "$uid_e 1000 30 100000|$uid_f 0 0 max|$uid_h 900 9 -" "$(cut -f 2- "$ko/samples/k6.tsv" | tr '\t' ' ' | paste -sd '|' -)"

# --- verify-sample.sh stop: the criteria of the k3d scenarios of part 3, over the fixtures of the sample tests above.
# gitops: each drill-k8s-keda-<n> that ran needs 6 samples in a row with 2 workers transcoding within its own window.
# keda_rows FIRST_RUN_IN_A_ROW SECOND_RUN_IN_A_ROW: docker.tsv with that many samples in a row with 2 transcoding at the
# start of the windows 100-200 and 300-400, then one with 1, then 4 more with 2.
keda_rows() {
  local t
  for t in $(seq 100 10 $((100 + ($1 - 1) * 10))); do peak_row "$t" 8000 2 2 1000; done
  peak_row $((100 + $1 * 10)) 8000 2 1 1000
  for t in 170 180 190 200; do peak_row "$t" 8000 2 2 1000; done
  for t in $(seq 300 10 $((300 + ($2 - 1) * 10))); do peak_row "$t" 8000 2 2 1000; done
  peak_row $((300 + $2 * 10)) 8000 2 1 1000
  for t in 370 380 390 400; do peak_row "$t" 8000 2 2 1000; done
}
keda1="$(row 02 drill-k8s-keda-1 ok 0 100 200 100 '')"
keda2="$(row 04 drill-k8s-keda-2 ok 0 300 400 100 '')"
echo gitops >"$so/scenario"
keda_rows 6 6 >"$so/samples/docker.tsv"
sample keda-both "$(row 01 k8s-gitops-up ok 0 50 100 50 '')" "$keda1" "$(row 03 ram-peak-1 ok 0 200 201 1 '')" "$keda2" \
  >/dev/null
same "sample: gitops, both drill-k8s-keda runs with 6 samples in a row with 2 transcoding" \
  "true drill-k8s-keda-1=6 drill-k8s-keda-2=6" \
  "$(jq -r '"\(.runner_enough.gitops_keda_two_transcoding) \(.keda_runs | map("\(.name)=\(.longest_run_with_2_transcoding)") | join(" "))"' \
    "$so/runner.json")"
grep -q '^runner: drill-k8s-keda, longest run of samples with 2 workers transcoding: drill-k8s-keda-1=6 drill-k8s-keda-2=6$' \
  "$work/sample-keda-both.log" && ok "sample: runner.txt names each drill-k8s-keda run" ||
  fail "sample: runner.txt names each drill-k8s-keda run"
keda_rows 6 5 >"$so/samples/docker.tsv"
sample keda-one "$(row 01 k8s-gitops-up ok 0 50 100 50 '')" "$keda1" "$keda2" >/dev/null
same "sample: gitops, one drill-k8s-keda run with only 5 in a row fails the criterion" "false 6 5" \
  "$(jq -r '"\(.runner_enough.gitops_keda_two_transcoding) \(.keda_runs | map(.longest_run_with_2_transcoding) | join(" "))"' \
    "$so/runner.json")"
sample keda-none "$(row 01 k8s-gitops-up ok 0 50 100 50 '')" "$(row 02 drill-k8s-keda-1 skipped '' 100 100 0 'not in targets')" \
  >/dev/null
same "sample: gitops, no drill-k8s-keda run: unmeasured, not passed" "unmeasured" \
  "$(jq -r '.runner_enough.gitops_keda_two_transcoding' "$so/runner.json")"
same "sample: every k3d scenario has the k3d criteria" "true" \
  "$(jq -r '.runner_enough | has("k3d_server_kept") and has("k3d_nodes_ready") and has("k3d_no_eviction")' "$so/runner.json")"
: >"$so/samples/docker.tsv"
# k6-cloud-mini, chaos: no k6 pod throttled over 5% of its CPU periods in a window of k6-windows.tsv. In 100-200 pod A
# 40 of 1000 periods (4%), pod B 20 of 1000 (2%); 100-300 adds pod C, 6 of 100 (6%); in 400-500 pods D and E without a
# CPU limit (no period counted); in 600-700 pod F 1 251 of 25 000 (5.004%); in 800-900 pod G 1 000 of 20 000 (5%); in
# 1000-1100 pod H 40 of 1000 and pod I a single sample (it ended); 1500-1600 has no sample.
printf '%s\n' '100 a 1000 10 50000' '110 a 1500 30 50000' '200 a 2000 50 50000' '100 b 3000 0 50000' \
  '200 b 4000 20 50000' '300 b 4100 21 50000' '250 c 0 0 50000' '300 c 100 6 50000' \
  '400 d 0 0 max' '500 d 0 0 max' '400 e 0 0 max' '450 e 0 0 max' \
  '600 f 1000 0 100000' '700 f 26000 1251 100000' '800 g 0 0 100000' '900 g 20000 1000 100000' \
  '1000 h 0 0 100000' '1100 h 1000 40 100000' '1000 i 0 0 100000' | tr ' ' '\t' >"$so/samples/k6.tsv"
# throttle NAME SCENARIO [WINDOW...]: verify-sample.sh stop with k6-windows.tsv of WINDOWs ("label from to pods"; none:
# no file); prints the criterion and each window's highest share, pods measured and pods it ran.
throttle() {
  local name=$1
  echo "$2" >"$so/scenario"
  shift 2
  rm -f "$so/k6-windows.tsv"
  [ "$#" = 0 ] || printf '%s\n' "$@" | tr ' ' '\t' >"$so/k6-windows.tsv"
  sample "$name" "$(row 01 k8s-up ok 0 50 100 50 '')" >/dev/null
  jq -r '"\(.runner_enough.k6_cpu_throttle_5pct) \(.k6_windows | map("\(.label)=\(.throttled_pct_max)/\(.pods_measured)/\(.pods)") | join(" "))"' \
    "$so/runner.json"
}
same "sample: k6-cloud-mini, every k6 pod at 5% or less of its periods throttled" "true level-1=4/2/2" \
  "$(throttle k6-ok k6-cloud-mini 'level-1 100 200 2')"
grep -qxF 'runner: k6 windows, highest share of CPU periods throttled in a pod: level-1=4% (2 of 2 pod(s) measured, 2 seen, 0 without a CPU limit)' \
  "$work/sample-k6-ok.log" && ok "sample: runner.txt names each k6 window" || fail "sample: runner.txt names each k6 window"
same "sample: chaos, a k6 pod over 5% fails the criterion" "false level-1=4/2/2 level-2=6/3/3" \
  "$(throttle k6-over chaos 'level-1 100 200 2' 'level-2 100 300 3')"
same "sample: k6 pods without a CPU limit are measured, none throttled" "true hold=0/2/2 2" \
  "$(throttle k6-no-limit chaos 'hold 400 500 2') $(jq -r '.k6_windows[0].pods_without_cpu_limit' "$so/runner.json")"
same "sample: 1 251 of 25 000 periods (5.004%) is over 5%, its share rounded up" "false level-8=5.01/1/1" \
  "$(throttle k6-just-over k6-cloud-mini 'level-8 600 700 1')"
same "sample: exactly 5% of the periods throttled passes" "true level-8=5/1/1" \
  "$(throttle k6-at-5 k6-cloud-mini 'level-8 800 900 1')"
same "sample: a k6 pod with a single sample in the window leaves it unmeasured" "unmeasured level-2=4/1/2" \
  "$(throttle k6-one-sample k6-cloud-mini 'level-2 1000 1100 2')"
grep -qxF 'runner: k6 windows, highest share of CPU periods throttled in a pod: level-2=4% unmeasured (1 of 2 pod(s) measured, 2 seen, 0 without a CPU limit)' \
  "$work/sample-k6-one-sample.log" && ok "sample: runner.txt marks a window unmeasured" ||
  fail "sample: runner.txt marks a window unmeasured"
same "sample: a pod over 5% fails the criterion even beside a window unmeasured" "false level-2=4/1/2 level-4=5.01/1/1" \
  "$(throttle k6-one-over k6-cloud-mini 'level-2 1000 1100 2' 'level-4 600 700 1')"
same "sample: fewer k6 pods with two samples than the window ran: unmeasured" "unmeasured hold=0/2/3" \
  "$(throttle k6-fewer chaos 'hold 400 500 3')"
same "sample: a window without a k6 sample is unmeasured, not passed" "unmeasured level-1=4/2/2 level-3=null/0/1" \
  "$(throttle k6-gap k6-cloud-mini 'level-1 100 200 2' 'level-3 1500 1600 1')"
same "sample: lines of k6-windows.tsv not of its format leave the criterion unmeasured" "unmeasured level-1=4/2/2 3" \
  "$(throttle k6-malformed k6-cloud-mini 'level-1 100 200 2' 'level-1 100 200' 'Level-2 100 200 2' 'level-3 100 200 0') $(
    jq -r '.k6_windows_malformed_lines' "$so/runner.json")"
grep -qxF 'runner: k6-windows.tsv, lines not label, start, end, pods: 3' "$work/sample-k6-malformed.log" &&
  ok "sample: runner.txt counts the lines of k6-windows.tsv not of its format" ||
  fail "sample: runner.txt counts the lines of k6-windows.tsv not of its format"
same "sample: without k6-windows.tsv the criterion is unmeasured" "unmeasured " "$(throttle k6-none k6-cloud-mini)"
same "sample: dev-k3d has no k6 criterion" "null level-1=4/2/2" "$(throttle k6-dev dev-k3d 'level-1 100 200 2')"
rm -f "$so/k6-windows.tsv" "$so/samples/k6.tsv"
echo compose-obs >"$so/scenario"

# --- verify-run.sh: the build target's failure skips the rest at once, SVP_VERIFY_TARGETS picks targets. It runs from
# a copy in a throwaway tree with a fake .env, a fake make first on PATH (it logs its arguments and fails for the
# targets FAKE_MAKE_FAIL names), a fake docker and the fake kubectl above (no cluster answers), so no target, no
# container, no cluster and no real .env is ever reached. verify-run.sh needs GNU timeout (and GNU date for its time
# lines: gdate on macOS).
vr=$work/verify-run
vb=$work/verify-run-bin
mkdir -p "$vr/deploy/ci" "$vr/deploy/observability/glitchtip" "$vb"
cp "$here/verify-run.sh" "$here/verify-mask.sh" "$here/verify-sample.sh" "$here/platform.sh" "$vr/deploy/ci/"
cp -R "$here/verify" "$vr/deploy/ci/"
cp "$here/../observability/glitchtip/dotenv.sh" "$vr/deploy/observability/glitchtip/"
cp "$repo/.env" "$vr/.env"
cat >"$vb/make" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_MAKE_LOG"
[ "$1" = -s ] && shift
[ -f "${FAKE_MAKE_DIR:-/nonexistent}/$1.out" ] && cat "$FAKE_MAKE_DIR/$1.out"
case " ${FAKE_MAKE_FAIL:-} " in *" $1 "*) exit 2 ;; esac
case " ${FAKE_MAKE_SLOW:-} " in *" $1 "*) sleep 60 ;; esac
case " ${FAKE_MAKE_PAUSE:-} " in *" $1 "*) sleep 2 ;; esac
EOF
printf '#!/bin/sh\ncommand -v gdate >/dev/null 2>&1 && exec gdate "$@"\nexec /bin/date "$@"\n' >"$vb/date"
# The fake docker of verify-sample.sh sample: one container of compose project svp, restarted once; docker ps logged
# with the make calls, so its place among them shows. Nothing else answers (no stats, no k3d server).
cat >"$vb/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "ps -aq --filter label=com.docker.compose.project=svp") echo "docker ps" >>"$FAKE_MAKE_LOG"; echo c0ffee000001 ;;
  "inspect -f {{.Name}} {{.Created}} {{.RestartCount}} c0ffee000001") echo "/svp-web-1 2026-10-25T08:00:00.1Z 1" ;;
  *) exit 1 ;;
esac
EOF
# The fake psql of the copy back to MinIO: the count of the videos of a status, FAKE_PSQL_<STATUS> (0 when unset), only
# for the database, user and password verify-run.sh must give.
cat >"$vb/psql" <<'EOF'
#!/usr/bin/env bash
[ "$PGPASSWORD" = postgres ] && [ "$1 $2 $3 $4 $5 $6 $7 $8" = "-h 127.0.0.1 -p 5432 -U postgres -d svp_video" ] || exit 2
case $* in
  *"WHERE status = 'PROCESSING'"*) echo "${FAKE_PSQL_PROCESSING:-0}" ;;
  *"WHERE status = 'READY'"*) echo "${FAKE_PSQL_READY:-0}" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$vb/make" "$vb/date" "$vb/psql" "$vb/docker"
# run_verify NAME SCENARIO [VAR=VALUE...]: the copy of verify-run.sh (in run_tree, default $vr) for SCENARIO; its
# output in $work/run-NAME.log,
# the make calls in $work/run-NAME.make, its results in $work/run-NAME.out; prints its exit status. It runs as on a
# machine, without the variables of any CI: a runner sets CI=true, which alone makes platform.sh refuse to run.
run_verify() {
  local name=$1 scenario=$2 rc=0
  shift 2
  : >"$work/run-$name.make"
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$vb:$work/bin:$PATH" \
    SVP_VERIFY_OUT="$work/run-$name.out" \
    SVP_VERIFY_SECRETS="$work/run-$name.secrets" FAKE_MAKE_LOG="$work/run-$name.make" SVP_VERIFY_TARGETS= "$@" \
    "${run_tree:-$vr}/deploy/ci/verify-run.sh" "$scenario" >"$work/run-$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
# results NAME: "id name status note" of each target of run NAME, one per line.
results() { awk -F '\t' 'NR > 1 { print $1, $2, $3, $8 }' "$work/run-$1.out/results.tsv"; }
compose_names="up smoke drill-duplicates drill-kill-worker drill-obs-threats load-local fallback-alert-under-load
web-lighthouse-1 web-lighthouse-2 web-lighthouse-3 lcp test-stack-objstore drill-upload-cleanup measure-upload ram-s3-upload
drill-alert-to-sentry object-store-roundtrip"
k3d_names="k8s-up k8s-smoke ram-rest-start drill-k8s-threats drill-k8s-pdb drill-k8s-canary k8s-web-sourcemaps
k8s-web-e2e drill-k8s-web-obs drill-k8s-keda ram-peak drill-k8s-backup drill-k8s-backup-pitr ram-rest-end"
# want_rows NAMES STATUS_OF_FIRST NOTE_OF_REST [ID NAME STATUS NOTE]...: the rows of a run: the first of NAMES with
# STATUS_OF_FIRST and no note, every other skipped with NOTE_OF_REST, except the rows given whole after it.
want_rows() {
  local i=0 name line names=$1 first=$2 rest=$3
  shift 3
  for name in $names; do
    i=$((i + 1))
    line=$(printf '%02d %s' "$i" "$name")
    if [ "$i" = 1 ]; then line="$line $first "; else line="$line skipped $rest"; fi
    for over in "$@"; do [ "${over%% * * *}" = "$(printf '%02d' "$i")" ] && line=$over; done
    echo "$line"
  done
}
if timeout --version 2>/dev/null | grep -q GNU; then
  rc=$(run_verify infra compose-obs FAKE_MAKE_FAIL=up)
  same "verify-run: a failed build target makes the run fail" 1 "$rc"
  same "verify-run: after a failed build target no other target runs" "up OBS=lgtm" "$(cat "$work/run-infra.make")"
  same "verify-run: every target after a failed build target is skipped for it" \
    "$(want_rows "$compose_names" fail 'infrastructure step failed')" "$(results infra)"
  [ -s "$work/run-infra.out/run-end" ] && ok "verify-run: a run that reached its last target writes its end mark" ||
    fail "verify-run: a run that reached its last target writes its end mark"

  # A run stopped while a target runs (a cancel, the step's timeout-minutes): that target is cancelled, no end mark.
  : >"$work/run-cut.make"
  env -u GITHUB_ACTIONS -u CI -u GITLAB_CI -u JENKINS_URL -u TF_BUILD PATH="$vb:$work/bin:$PATH" \
    SVP_VERIFY_OUT="$work/run-cut.out" SVP_VERIFY_SECRETS="$work/run-cut.secrets" FAKE_MAKE_LOG="$work/run-cut.make" \
    SVP_VERIFY_TARGETS=smoke FAKE_MAKE_SLOW=smoke "$vr/deploy/ci/verify-run.sh" compose-obs >"$work/run-cut.log" 2>&1 \
    </dev/null &
  cut_pid=$!
  for _ in $(seq 1 100); do
    grep -q '^smoke' "$work/run-cut.make" && break
    sleep 0.1
  done
  kill -TERM "$cut_pid"
  wait "$cut_pid" || :
  [ ! -e "$work/run-cut.out/run-end" ] && results cut | grep -qx '02 smoke cancelled the run was cancelled or the step timed out' &&
    ok "verify-run: a run stopped mid-target records it cancelled and writes no end mark" ||
    fail "verify-run: a run stopped mid-target records it cancelled and writes no end mark"

  rc=$(run_verify one dev-k3d SVP_VERIFY_TARGETS=drill-k8s-threats)
  same "verify-run: a run of the chosen targets that pass passes" 0 "$rc"
  same "verify-run: only the build target and the chosen one run" "$(printf 'k8s-up\ndrill-k8s-threats')" \
    "$(cat "$work/run-one.make")"
  same "verify-run: the targets left out keep their ids and are skipped as not in targets" \
    "$(want_rows "$k3d_names" ok 'not in targets' '04 drill-k8s-threats ok ')" "$(results one)"

  rc=$(run_verify one-fails dev-k3d 'SVP_VERIFY_TARGETS=drill-k8s-pdb  drill-k8s-threats' FAKE_MAKE_FAIL=drill-k8s-pdb)
  same "verify-run: a chosen target that fails makes the run fail" 1 "$rc"
  same "verify-run: chosen targets run in the scenario's order, whatever the order given" \
    "$(printf 'k8s-up\ndrill-k8s-threats\ndrill-k8s-pdb')" "$(cat "$work/run-one-fails.make")"

  rc=$(run_verify peak dev-k3d SVP_VERIFY_TARGETS=ram-peak)
  same "verify-run: ram-peak without drill-k8s-keda makes the run fail" 1 "$rc"
  same "verify-run: ram-peak without drill-k8s-keda is skipped for it" \
    "$(want_rows "$k3d_names" ok 'not in targets' '11 ram-peak skipped drill-k8s-keda did not run')" "$(results peak)"

  rc=$(run_verify s3-peak compose-obs SVP_VERIFY_TARGETS=ram-s3-upload)
  same "verify-run: ram-s3-upload without measure-upload makes the run fail" 1 "$rc"
  same "verify-run: ram-s3-upload without measure-upload is skipped for it" \
    "$(want_rows "$compose_names" ok 'not in targets' '15 ram-s3-upload skipped measure-upload did not run')" \
    "$(results s3-peak)"

  # test-stack-objstore over the output of a fake make test-stack: a unit test and the eight integration tests pass, one
  # with a subtest; then a subtest skipped, an integration test missing, go test failing.
  fm=$work/fake-make
  mkdir -p "$fm"
  # objstore NAME [LINE...]: test-stack-objstore over that output plus LINEs (DROP_TEST leaves a test out, FAKE_FAIL
  # makes make fail); prints the step's status and its summary line.
  objstore() {
    local name=$1 t
    shift
    {
      for t in TestNewRejectsMissingConfig TestIntegrationPresignedPost TestIntegrationWorkerPermissions \
        TestIntegrationVideoServicePermissions TestIntegrationDeletePrefix TestIntegrationMultipartChecksum \
        TestIntegrationCacheControl TestIntegrationCreateOnce TestIntegrationWorkerReadsMedia; do
        [ "${DROP_TEST:-}" = "$t" ] || printf '=== RUN   %s\n--- PASS: %s (0.10s)\n' "$t" "$t"
      done
      echo '    --- PASS: TestIntegrationPresignedPost/valid_form (0.01s)'
      [ "$#" = 0 ] || printf '%s\n' "$@"
      printf 'ok  \tgithub.com/anhnvcoder/short-video-platform/internal/objstore\t1.2s\n'
    } >"$fm/test-stack.out"
    run_verify "objstore-$name" compose-obs SVP_VERIFY_TARGETS=test-stack-objstore FAKE_MAKE_DIR="$fm" \
      ${FAKE_FAIL:+FAKE_MAKE_FAIL=test-stack} >/dev/null
    printf '%s ' "$(results "objstore-$name" | awk '$2 == "test-stack-objstore" { print $3 }')"
    grep '^object store tests: ' "$work/run-objstore-$name.out/logs/12-test-stack-objstore.log"
  }
  same "verify-run: test-stack-objstore passes when every test passes" \
    "ok object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" "$(objstore pass)"
  grep -qx 'test-stack PKGS=./internal/objstore/...' "$work/run-objstore-pass.make" &&
    ok "verify-run: test-stack-objstore runs make test-stack on internal/objstore" ||
    fail "verify-run: test-stack-objstore runs make test-stack on internal/objstore"
  same "verify-run: a skipped subtest fails test-stack-objstore" \
    "fail object store tests: 10 passed, 0 failed, 1 skipped (tests and subtests); make test-stack exit 0" \
    "$(objstore skip '    --- SKIP: TestIntegrationMultipartChecksum/trailer (0.00s)')"
  same "verify-run: an integration test that did not run fails test-stack-objstore" \
    "fail object store tests: 9 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 0" \
    "$(DROP_TEST=TestIntegrationMultipartChecksum objstore missing)"
  grep -qx 'FAIL  did not pass: TestIntegrationMultipartChecksum' \
    "$work/run-objstore-missing.out/logs/12-test-stack-objstore.log" &&
    ok "verify-run: the integration test that did not pass is named" ||
    fail "verify-run: the integration test that did not pass is named"
  same "verify-run: go test failing fails test-stack-objstore" \
    "fail object store tests: 10 passed, 0 failed, 0 skipped (tests and subtests); make test-stack exit 2" \
    "$(FAKE_FAIL=1 objstore exit)"

  # object-store-roundtrip with a fake make (the s3-init log, the copy's output) and the fake psql.
  # roundtrip NAME [VAR=VALUE...]: the step over INIT_LOG and a copy that reports LOST keys lost (default 0), 3 READY
  # videos; prints its status.
  roundtrip() {
    local name=$1
    shift
    printf '%s\n' "${INIT_LOG:-s3-init-1  | ok buckets uploads media objstore-probe}" >"$fm/logs.out"
    printf '%s\n' "object-store-copy: bucket media at MinIO: 12 object(s), 3456 byte(s)" \
      "object-store-copy: READY videos' keys lost before this copy: ${LOST:-0}" >"$fm/object-store-copy.out"
    run_verify "roundtrip-$name" compose-obs SVP_VERIFY_TARGETS=object-store-roundtrip FAKE_MAKE_DIR="$fm" \
      FAKE_PSQL_READY=3 "$@" >/dev/null
    results "roundtrip-$name" | awk '$2 == "object-store-roundtrip" { print $3 }'
  }
  rlog() { cat "$work/run-roundtrip-$1.out/logs/17-object-store-roundtrip.log"; }
  same "verify-run: object-store-roundtrip passes when the copy, make up and smoke pass" ok "$(roundtrip pass)"
  same "verify-run: object-store-roundtrip reads the s3-init log, stops the stack, copies back, starts it on RustFS" \
    "$(printf '%s\n' 'up OBS=lgtm' '-s logs SVC=s3-init' down 'object-store-copy TO=minio' 'up OBS=lgtm' \
      '-s logs SVC=s3-init' smoke)" "$(cat "$work/run-roundtrip-pass.make")"
  # With the sampler's samples there, one sample just before make down keeps the restart of a container it removes.
  mkdir -p "$work/run-roundtrip-sampled.out/samples"
  same "verify-run: object-store-roundtrip passes with the sampler's samples" ok "$(roundtrip sampled)"
  same "verify-run: object-store-roundtrip reads the compose containers' restarts just before make down" \
    "$(printf '%s\n' 'docker ps' down)" "$(grep -A 1 -x 'docker ps' "$work/run-roundtrip-sampled.make")"
  same "verify-run: that reading is in restarts.tsv" "svp-web-1 2026-10-25T08:00:00.1Z 1" \
    "$(cut -f 2- "$work/run-roundtrip-sampled.out/samples/restarts.tsv" | tr '\t' ' ')"
  rlog pass | grep -qx 's3-init (before the copy): 1 log line(s), 0 with a secret value of .env' &&
    rlog pass | grep -qx 'videos READY in svp_video, made on RustFS by the targets before: 3' &&
    ok "verify-run: object-store-roundtrip prints the counts" || fail "verify-run: object-store-roundtrip prints the counts"
  same "verify-run: a failed copy fails object-store-roundtrip" fail "$(roundtrip copy FAKE_MAKE_FAIL=object-store-copy)"
  same "verify-run: after a failed copy the stack still comes back on RustFS and smoke runs" \
    "$(printf '%s\n' 'up OBS=lgtm' smoke)" "$(tail -n 3 "$work/run-roundtrip-copy.make" | grep -v '^-s logs')"
  same "verify-run: a READY video's key lost fails object-store-roundtrip" fail "$(LOST=2 roundtrip lost)"
  same "verify-run: no READY video fails object-store-roundtrip" fail "$(roundtrip none FAKE_PSQL_READY=0)"
  same "verify-run: a value of .env in the s3-init log fails object-store-roundtrip" fail \
    "$(INIT_LOG="s3-init-1  | key $env_secret" roundtrip leak)"
  ! rlog leak | grep -qF "$env_secret" && rlog leak | grep -q ' 1 with a secret value of .env$' &&
    ok "verify-run: the s3-init log is counted, never printed" || fail "verify-run: the s3-init log is counted, never printed"

  # Each scenario of part 3 is a name verify-run.sh takes, its file sourced: the build target failing skips every other
  # target at once, and only the build target ran. What comes after it is left to each scenario's own work. The copy
  # is a git checkout on a branch, which gitops gives make k8s-gitops-up as the revision Argo CD follows.
  git -c init.defaultBranch=feat/stage6b-verify init -q "$vr"
  for sc in gitops:k8s-gitops-up web-canary:k8s-up k6-cloud-mini:k8s-up chaos:k8s-up velero:k8s-up; do
    scn=${sc%%:*}
    b=${sc#*:}
    rc=$(run_verify "infra-$scn" "$scn" FAKE_MAKE_FAIL="$b")
    same "verify-run: $scn is a scenario whose failed build target makes the run fail" 1 "$rc"
    same "verify-run: $scn starts with its build target $b, which fails" "01 $b fail " \
      "$(results "infra-$scn" | head -n 1)"
    rows=$(results "infra-$scn" | tail -n +2)
    [ -n "$rows" ] && ! printf '%s\n' "$rows" | grep -qv '^[0-9][0-9] [a-z0-9-]* skipped infrastructure step failed$' &&
      ok "verify-run: $scn skips every target after its build target for it" ||
      fail "verify-run: $scn skips every target after its build target for it"
  done
  same "verify-run: gitops builds the cluster from the branch of the checkout" \
    "k8s-gitops-up GITOPS_REV=feat/stage6b-verify" "$(cat "$work/run-infra-gitops.make")"
  same "verify-run: a k3d scenario of the dev path runs only make k8s-up when it fails" "k8s-up" \
    "$(cat "$work/run-infra-velero.make")"
  rc=$(run_verify no-scenario nope)
  same "verify-run: a name that is no scenario stops it" 2 "$rc"
  [ ! -s "$work/run-no-scenario.make" ] && [ ! -e "$work/run-no-scenario.out/results.tsv" ] &&
    ok "verify-run: an unknown scenario starts nothing" || fail "verify-run: an unknown scenario starts nothing"

  # A second copy whose scenario files are made for the test: one missing, one that declares too little, one whose
  # first target is not its build target, one fake scenario that runs a drill twice, each followed by its RAM peak.
  vr2=$work/verify-run-2
  mkdir -p "$vr2/deploy"
  cp -R "$vr/deploy/ci" "$vr/deploy/observability" "$vr2/deploy/"
  cp "$vr/.env" "$vr2/.env"
  rm "$vr2/deploy/ci/verify/web-canary.sh"
  printf 'build=k8s-up\njob_minutes_default=330\nscenario_targets() { step k8s-up 1 make k8s-up; }\n' \
    >"$vr2/deploy/ci/verify/chaos.sh"
  printf 'build=k8s-up\njob_minutes_default=330\nk3d=1\nscenario_targets() { step other 1 make other; step k8s-up 1 make k8s-up; }\n' \
    >"$vr2/deploy/ci/verify/k6-cloud-mini.sh"
  cat >"$vr2/deploy/ci/verify/velero.sh" <<'EOF2'
build=fake-up
job_minutes_default=60
k3d=0
scenario_targets() {
  local round
  step fake-up 1 make fake-up
  for round in 1 2; do
    step "drill-k8s-keda-$round" 1 make "keda-$round"
    if [ "$last_status" = skipped ]; then
      skip "ram-peak-$round" "drill-k8s-keda-$round did not run"
    else
      step "ram-peak-$round" 1 "$here/verify-sample.sh" peak "$last_start" "$last_end" "$round"
    fi
  done
}
EOF2
  rc=$(run_tree=$vr2 run_verify no-file web-canary)
  same "verify-run: a scenario without its file stops it" 2 "$rc"
  has run-no-file "the missing file is named" "no file deploy/ci/verify/web-canary.sh for scenario web-canary"
  rc=$(run_tree=$vr2 run_verify no-k3d chaos)
  same "verify-run: a scenario file that does not set k3d stops it" 2 "$rc"
  [ ! -s "$work/run-no-k3d.make" ] && ok "verify-run: a scenario file that declares too little starts nothing" ||
    fail "verify-run: a scenario file that declares too little starts nothing"
  rc=$(run_tree=$vr2 run_verify build-second k6-cloud-mini)
  same "verify-run: a scenario whose first target is not its build target stops it" 2 "$rc"
  mkdir -p "$work/run-keda2.out/samples"
  : >"$work/run-keda2.out/samples/docker.tsv"
  rc=$(run_tree=$vr2 run_verify keda2 velero FAKE_MAKE_PAUSE='keda-1 keda-2')
  same "verify-run: a scenario that runs a drill twice passes" 0 "$rc"
  # window NAME ID: the start and end of target ID of run keda2 as verify-sample.sh writes them, and those of the file.
  window() {
    awk -F '\t' -v id="$2" '$1 == id { print $5, $6 }' "$work/run-keda2.out/results.tsv" |
      while read -r a b; do jq -rn --argjson a "$a" --argjson b "$b" '"\($a | todate) \($b | todate)"'; done
  }
  w1=$(window keda2 02)
  w2=$(window keda2 04)
  [ "$w1" != "$w2" ] && ok "verify-run: the two drill runs have windows of their own" ||
    fail "verify-run: the two drill runs have windows of their own"
  same "verify-run: ram-peak-1 reads the window of drill-k8s-keda-1" "$w1" \
    "$(jq -r '"\(.window.start) \(.window.end)"' "$work/run-keda2.out/ram-peak-1.json")"
  same "verify-run: ram-peak-2 reads the window of drill-k8s-keda-2" "$w2" \
    "$(jq -r '"\(.window.start) \(.window.end)"' "$work/run-keda2.out/ram-peak-2.json")"
  rc=$(run_tree=$vr2 run_verify keda2-one velero SVP_VERIFY_TARGETS='drill-k8s-keda-1 ram-peak-1 ram-peak-2')
  same "verify-run: ram-peak-2 without drill-k8s-keda-2 is skipped for it and fails the run" \
    "1 05 ram-peak-2 skipped drill-k8s-keda-2 did not run" \
    "$rc $(results keda2-one | tail -n 1)"

  rc=$(run_verify unknown dev-k3d 'SVP_VERIFY_TARGETS=drill-k8s-threats drill-k8s-thraets')
  same "verify-run: a name that is no target of the scenario stops it" 2 "$rc"
  [ ! -s "$work/run-unknown.make" ] && [ ! -e "$work/run-unknown.out/results.tsv" ] &&
    ok "verify-run: an unknown name stops it before any target or results.tsv" ||
    fail "verify-run: an unknown name stops it before any target or results.tsv"
  # The error names the targets of the scenario: the list that the scenario's own steps make.
  has run-unknown "an unknown name is named, with the scenario's targets" \
    "not a target of dev-k3d: drill-k8s-thraets (its targets: $(printf '%s' "$k3d_names" | tr '\n' ' '))"
  rc=$(run_verify unknown-compose compose-obs SVP_VERIFY_TARGETS=k8s-smoke)
  same "verify-run: a target of the other scenario is unknown" 2 "$rc"
  has run-unknown-compose "the compose-obs targets are listed" \
    "(its targets: $(printf '%s' "$compose_names" | tr '\n' ' '))"

  rc=$(run_verify bad dev-k3d $'SVP_VERIFY_TARGETS=k8s-smoke\n::warning::BAD-TARGET-MARKER')
  same "verify-run: a target list with another character stops it" 2 "$rc"
  [ ! -s "$work/run-bad.make" ] && lacks run-bad "the rejected list is not printed back" BAD-TARGET-MARKER ||
    fail "verify-run: a rejected list starts no target"
else
  echo "skip  verify-run: no GNU timeout on PATH (Linux, or coreutils on macOS)"
fi

# --- verify-tempo.sh: its own self-test (fake kubectl, curl and nc; no cluster, no network), so that job config of CI
# runs it with the rest of the verification scripts' tests.
if bash "$here/verify-tempo.sh" test >"$work/verify-tempo-test.out" 2>&1; then
  ok "verify-tempo.sh: its self-test passes"
else
  sed 's/^/    /' "$work/verify-tempo-test.out" >&2
  fail "verify-tempo.sh: its self-test passes"
fi

# --- changed-services.sh: a change of a verification script builds no image; one of verify-release.sh, which the image
# jobs run, still builds all seven. GIT_DIR is set for the throwaway repository, so git can never reach another one.
cs=$work/changed-services
mkdir -p "$cs/deploy/ci" "$cs/deploy/k8s"
cp "$here/changed-services.sh" "$here/common.sh" "$here/platform.sh" "$here/verify-run.sh" "$here/verify-release.sh" \
  "$cs/deploy/ci/"
cp -R "$here/verify" "$cs/deploy/ci/"
cp "$here/../k8s/lib.sh" "$cs/deploy/k8s/"
g() {
  GIT_DIR=$cs/.git GIT_WORK_TREE=$cs git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null "$@"
}
g init -q && g add -A && g commit -qm base
# changed_by PATH: commits a change of PATH, then prints what changed-services.sh builds for that commit.
changed_by() {
  echo "# changed" >>"$cs/$1"
  g commit -qam "change $1"
  "$cs/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
got=$(changed_by deploy/ci/verify-run.sh)
[ -z "$got" ] && ok "changed-services: a change of verify-run.sh builds nothing" ||
  fail "changed-services: a change of verify-run.sh builds nothing (got '$got')"
got=$(changed_by deploy/ci/verify/dev-k3d.sh)
[ -z "$got" ] && ok "changed-services: a change of a scenario file of verify-run.sh builds nothing" ||
  fail "changed-services: a change of a scenario file of verify-run.sh builds nothing (got '$got')"
got=$(changed_by deploy/ci/verify-release.sh)
[ "$got" = "engagement-service feed-service gateway media-worker user-service video-service web" ] &&
  ok "changed-services: a change of verify-release.sh builds all seven" ||
  fail "changed-services: a change of verify-release.sh builds all seven (got '$got')"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
