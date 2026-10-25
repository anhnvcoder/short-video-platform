#!/usr/bin/env bash
# Tests for the artifact filter of the verification runs, deploy/ci/verify-collect.sh, and for deploy/ci/verify-mask.sh
# it calls. Everything is a fixture in a temporary directory: a fake checkout with a fake .env (the repository's .env is
# never read), a fake results folder, and a fake kubectl first on PATH that lists made-up Secrets or fails. The fake
# secrets, the JWT and the private key header are made at run time, so no file of the repository holds one. Then the
# deadline criterion of the summary of deploy/ci/verify-sample.sh, with a fake docker and a fake sudo first on PATH;
# one sample of its docker.tsv (workers transcoding, memory.stat of the nodes) with a fake docker, kubectl and pgrep and
# a fixture of /proc; and its peak over a fixture of docker.tsv.
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
  "FAIL  NP-1: probe reached minio" "FAIL  NP-1: the item ended with exit status 1" "== WEB-7" \
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
  stats) printf 'k3d-svp-server-0\t150.00%%\t3GiB / 15.6GiB\nk3d-svp-agent-0\t120.00%%\t2.5GiB / 15.6GiB\nk3d-svp-registry\t0.00%%\t20MiB / 15.6GiB\n' ;;
  inspect) echo "running 0 2026-10-25T00:00:00Z" ;;
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

# --- verify-run.sh: the build target's failure skips the rest at once, SVP_VERIFY_TARGETS picks targets. It runs from
# a copy in a throwaway tree with a fake .env, a fake make first on PATH (it logs its arguments and fails for the
# targets FAKE_MAKE_FAIL names) and the fake kubectl above (no cluster answers), so no target, no cluster and no real
# .env is ever reached. verify-run.sh needs GNU timeout (and GNU date for its time lines: gdate on macOS).
vr=$work/verify-run
vb=$work/verify-run-bin
mkdir -p "$vr/deploy/ci" "$vr/deploy/observability/glitchtip" "$vb"
cp "$here/verify-run.sh" "$here/verify-mask.sh" "$here/platform.sh" "$vr/deploy/ci/"
cp "$here/../observability/glitchtip/dotenv.sh" "$vr/deploy/observability/glitchtip/"
cp "$repo/.env" "$vr/.env"
cat >"$vb/make" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_MAKE_LOG"
case " ${FAKE_MAKE_FAIL:-} " in *" $1 "*) exit 2 ;; esac
EOF
printf '#!/bin/sh\ncommand -v gdate >/dev/null 2>&1 && exec gdate "$@"\nexec /bin/date "$@"\n' >"$vb/date"
chmod 755 "$vb/make" "$vb/date"
# run_verify NAME SCENARIO [VAR=VALUE...]: the copy of verify-run.sh for SCENARIO; its output in $work/run-NAME.log,
# the make calls in $work/run-NAME.make, its results in $work/run-NAME.out; prints its exit status.
run_verify() {
  local name=$1 scenario=$2 rc=0
  shift 2
  : >"$work/run-$name.make"
  env -u GITHUB_ACTIONS PATH="$vb:$work/bin:$PATH" SVP_VERIFY_OUT="$work/run-$name.out" \
    SVP_VERIFY_SECRETS="$work/run-$name.secrets" FAKE_MAKE_LOG="$work/run-$name.make" SVP_VERIFY_TARGETS= "$@" \
    "$vr/deploy/ci/verify-run.sh" "$scenario" >"$work/run-$name.log" 2>&1 </dev/null || rc=$?
  echo "$rc"
}
# results NAME: "id name status note" of each target of run NAME, one per line.
results() { awk -F '\t' 'NR > 1 { print $1, $2, $3, $8 }' "$work/run-$1.out/results.tsv"; }
compose_names="up smoke drill-obs-threats load-local fallback-alert-under-load web-lighthouse-1 web-lighthouse-2
web-lighthouse-3 lcp drill-alert-to-sentry"
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
