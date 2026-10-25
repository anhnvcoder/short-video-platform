#!/usr/bin/env bash
# Tests for the artifact filter of the verification runs, deploy/ci/verify-collect.sh, and for deploy/ci/verify-mask.sh
# it calls. Everything is a fixture in a temporary directory: a fake checkout with a fake .env (the repository's .env is
# never read), a fake results folder, and a fake kubectl first on PATH that lists made-up Secrets or fails. The fake
# secrets, the JWT and the private key header are made at run time, so no file of the repository holds one. Then the
# deadline criterion of the summary of deploy/ci/verify-sample.sh, with a fake docker and a fake sudo first on PATH.
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
# makes it fail, as for a cluster that no longer answers.
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && { echo "The connection to the server was refused" >&2; exit 1; }
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
  --argjson minio "$(b64v MINIO_ROOT_USER=svp-admin "MINIO_ROOT_PASSWORD=$cluster_secret")" \
  --argjson keda "$(b64v sasl=scram_sha256 tls=disable username=svp-keda "password=$kafka_secret")" \
  --arg multi "$(b64 "route:
  receiver: telegram
  $line_secret
")" --arg helm "$(b64 "$helm_payload")" '{items: [
    {type: "Opaque", metadata: {name: "pg-backup-s3"}, data: $backup},
    {type: "Opaque", metadata: {name: "minio-root"}, data: $minio},
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

# --- The fake results of a k3d run.
out=$work/out
mkdir -p "$out/logs" "$out/samples"
echo dev-k3d >"$out/scenario"
printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$out/results.tsv"
printf '01\tk8s-up\tok\t0\t100\t160\t60\t\n02\tk8s-smoke\tfail\t1\t160\t170\t10\t\n' >>"$out/results.tsv"
printf '03\tdrill-k8s-keda\tfail\t1\t170\t180\t10\t\n04\tdrill-k8s-threats\tfail\t1\t180\t190\t10\t\n' >>"$out/results.tsv"
printf '05\tdrill-alert-to-sentry\tfail\t1\t190\t200\t10\t\n06\tdrill-obs-threats\tok\t0\t200\t210\t10\t\n' \
  >>"$out/results.tsv"
# A target that quotes service logs: the log of a failed migrate Job (JSON records, one with a secret) and the
# gateway's access log line of a trace, between lines of its own.
{
  echo "ok    cluster ready"
  echo "Job svp/feed-service-migrate failed; log of its last failed attempt, copied before its pod was deleted:"
  echo '{"time":"2026-10-25T08:00:00Z","level":"WARN","msg":"database not reachable, retrying","attempt":1}'
  echo "{\"time\":\"2026-10-25T08:00:01Z\", \"level\": \"ERROR\", \"msg\":\"dsn $quoted_secret\"}"
  echo "FAIL  install feed-service"
} >"$out/logs/01-k8s-up.log"
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
  echo "FAIL  NP-1: probe reached minio"
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
l=$repo/web/test-results/lighthouse
echo "<html>Set-Cookie: svp=1</html>" >"$l/a.report.html"
echo '{"audits":{}}' >"$l/b.report.json"
echo '{}' >"$l/.lighthouseci/lhr-1.json"
echo 'zip' >"$repo/web/test-results/playwright/trace.zip"
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
expect k3d '$SVP_VERIFY_OUT/.hidden.json' hidden
expect k3d .k8s/drills/backup-1.json secret-value
expect k3d .k8s/drills/b64-1.json secret-value
expect k3d .k8s/drills/multiline-1.json secret-value
expect k3d .k8s/drills/threats-1.log not-allowed
expect k3d .k8s/drills/big-1.json too-large
expect k3d .k8s/drills/link-1.json not-regular
expect k3d .k6/local-1/machine.json not-allowed
expect k3d web/test-results/lighthouse/a.report.html set-cookie
expect k3d web/test-results/lighthouse/.lighthouseci/lhr-1.json hidden
expect k3d web/test-results/playwright/trace.zip not-allowed
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
  "FAIL  NP-1: probe reached minio" "== WEB-7" \
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
grep -qF "$(printf 'kept\t$SVP_VERIFY_OUT/logs/01-k8s-up.log\tlogs/01-k8s-up.log\t2 service log line(s) left out')" \
  "$work/art-k3d/files.txt" && ok "k3d: files.txt counts the lines left out" || fail "k3d: files.txt counts the lines left out"
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
collect compose "$work/secrets-compose" FAKE_KUBECTL_FAIL=1
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
# sample NAME [ROW...]: verify-sample.sh stop over a results.tsv of ROWs (none: no results.tsv); prints
# within_deadline of runner.json and the targets it lists as cut, its output in $work/sample-NAME.log.
sample() {
  local name=$1
  shift
  rm -f "$so/results.tsv" "$so/runner.json"
  if [ "$#" -gt 0 ]; then
    printf 'id\tname\tstatus\texit\tstart\tend\tseconds\tnote\n' >"$so/results.tsv"
    printf '%s\n' "$@" >>"$so/results.tsv"
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
grep -q '^runner enough: within_deadline=false ' "$work/sample-deadline.log" &&
  ok "sample: the runner enough line names within_deadline" || fail "sample: the runner enough line names within_deadline"

# --- changed-services.sh: a change of a verification script builds no image; one of verify-release.sh, which the image
# jobs run, still builds all seven. GIT_DIR is set for the throwaway repository, so git can never reach another one.
cs=$work/changed-services
mkdir -p "$cs/deploy/ci" "$cs/deploy/k8s"
cp "$here/changed-services.sh" "$here/common.sh" "$here/platform.sh" "$here/verify-run.sh" "$here/verify-release.sh" \
  "$cs/deploy/ci/"
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
got=$(changed_by deploy/ci/verify-release.sh)
[ "$got" = "engagement-service feed-service gateway media-worker user-service video-service web" ] &&
  ok "changed-services: a change of verify-release.sh builds all seven" ||
  fail "changed-services: a change of verify-release.sh builds all seven (got '$got')"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
