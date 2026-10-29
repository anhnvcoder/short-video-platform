#!/usr/bin/env bash
# Masks the secret values of a verification run in the log of its GitHub Actions job and keeps them, in a private
# directory, for deploy/ci/verify-collect.sh to search the artifact with. The repository is public, so the job's log
# is too, red or not: masking is the second layer, after the rule that no script prints a secret.
#
#   verify-mask.sh env       the values of .env whose name ends in PASSWORD, SECRET, SECRET_KEY, TOKEN, _KEY or _KEYS,
#                            and SENTRY_DSN, read by the rule of deploy/observability/glitchtip/dotenv.sh (never
#                            sourced); the first call of a job also masks a random marker and prints
#                            "mask-check: <marker>", so the raw log shows the mask works without knowing any secret
#   verify-mask.sh cluster   every value of every Secret in namespaces svp, svp-data, svp-obs, argocd, velero,
#                            chaos-mesh, svp-load and svp-secrets (the source External Secrets Operator builds the
#                            GitOps path's Secrets from) of cluster k3d-svp, each line of a value of several lines on
#                            its own (each run of text between control characters, for a binary value)
#
# Each value is kept as it is and in base64 (a Secret's own form, and what a JSON dump of it shows). Only values of at
# least 8 characters count: a shorter one (svp, a port, a user name of four letters) is no secret worth the name, and
# masking or searching for it would hide or drop half the log and every file that mentions it. For the same reason the
# keys that hold identifiers by design are left out of the cluster's list: username, user, dbname, host, port, the
# public certificates ca.crt and tls.crt, KEDA's sasl and tls (a mechanism, a mode), and any key whose name ends in
# username, _user or -user (KAFKA_SASL_USERNAME, S3_ROOT_USER, Grafana's admin-user), email
# (GLITCHTIP_ADMIN_EMAIL), _key_id (ACCESS_KEY_ID, the S3 user name) or _kid (JWT_SIGNING_KID, the key's public id).
# The drills print those names (drill-k8s-threats names the Kafka users and svp-admin in its verdicts), and
# deploy/k8s/secrets.sh never stores a password, key or token under such a key. Secrets of type helm.sh/release.v1
# are left out too: their value is a whole compressed release, a single line of megabytes, and the cluster's
# credentials come from deploy/k8s/secrets.sh, not from chart values.
#
# Output: a mask (ci_mask of deploy/ci/platform.sh: an ::add-mask:: line on stdout on GitHub, which the runner hides;
# nothing on a machine) for each value not masked before in this job (a mask set twice is harmless), and one fixed
# line saying how many there were. Never set -x here: the trace would print every value. The values go to
# $SVP_VERIFY_SECRETS (default verify-secrets in ci_temp_dir: $RUNNER_TEMP on GitHub; mode 700): env.values
# and cluster.values, one per line, mode 600, never uploaded. Each list only grows: a call adds what it read to what
# the earlier calls of the job kept, so a Secret made again during the run (drill-k8s-backup rebuilds Postgres, and
# CloudNativePG writes new Secrets for it) is still searched for in the files written before. A run that cannot read
# its source exits 1 and leaves the list as it was (verify-collect.sh then decides what it may copy).
#
# SVP_VERIFY_REPO (default: this checkout) and SVP_VERIFY_ENV_FILE (default: .env of it) let
# deploy/ci/verify-collect-test.sh point it at a fake .env; kubectl is the one on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${SVP_VERIFY_REPO:-$(cd "$here/../.." && pwd)}
env_file=${SVP_VERIFY_ENV_FILE:-$repo/.env}
# ci_mask, ci_temp_dir: what depends on the CI platform.
# shellcheck source=deploy/ci/platform.sh
. "$here/platform.sh"
tmp_root=$(ci_temp_dir) || exit 1
secrets=${SVP_VERIFY_SECRETS:-$tmp_root/verify-secrets}
min_len=8
namespaces="svp svp-data svp-obs argocd velero chaos-mesh svp-load svp-secrets"
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$here/../observability/glitchtip/dotenv.sh"

fail() {
  echo "verify-mask: $1" >&2
  exit 1
}

umask 077
mkdir -p "$secrets"
chmod 700 "$secrets"
work=$(mktemp -d "$secrets/work.XXXXXX")
trap 'rm -rf "$work"' EXIT

# secret_name NAME: true for the names of .env whose value is a secret.
secret_name() {
  case $1 in
    SENTRY_DSN | *PASSWORD | *SECRET | *SECRET_KEY | *TOKEN | *_KEY | *_KEYS) return 0 ;;
    *) return 1 ;;
  esac
}

# with_base64 < VALUES: each value line, then its base64 on one line; only lines of min_len or more characters.
with_base64() {
  local v
  while IFS= read -r v || [ -n "$v" ]; do
    [ "${#v}" -ge "$min_len" ] || continue
    printf '%s\n' "$v"
    printf '%s' "$v" | base64 | tr -d '\n'
    printf '\n'
  done
}

# keep LIST: adds LIST to $secrets/LIST.values, then masks what no earlier call of this job masked.
keep() {
  touch "$secrets/$1.values"
  LC_ALL=C sort -u "$work/$1" "$secrets/$1.values" -o "$work/$1"
  mv "$work/$1" "$secrets/$1.values"
  touch "$secrets/masked"
  LC_ALL=C comm -13 "$secrets/masked" "$secrets/$1.values" >"$work/new"
  while IFS= read -r v; do ci_mask "$v"; done <"$work/new"
  LC_ALL=C sort -u "$secrets/masked" "$work/new" -o "$secrets/masked"
  echo "verify-mask $1: $(wc -l <"$work/new" | tr -d ' ') new value(s) masked, $(wc -l <"$secrets/$1.values" | tr -d ' ') kept for the artifact scan"
}

case ${1:-} in
  env)
    if [ ! -e "$env_file" ]; then
      : >"$work/env"
      keep env
      exit 0
    fi
    # The whole file must keep the rule before any value is trusted: dotenv_value names the first line that breaks
    # it and the variable it sets, never a value.
    dotenv_value "$env_file" SVP_VERIFY_NO_SUCH_NAME >/dev/null || fail "$env_file breaks the .env rule: nothing masked"
    names=$(LC_ALL=C sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$env_file")
    : >"$work/raw"
    for name in $names; do
      secret_name "$name" || continue
      value=$(dotenv_value "$env_file" "$name") || fail "read $name of $env_file"
      printf '%s\n' "$value" >>"$work/raw"
    done
    with_base64 <"$work/raw" >"$work/env"
    keep env
    if [ ! -e "$secrets/mask-checked" ]; then
      marker=$(openssl rand -hex 16)
      ci_mask "$marker"
      echo "mask-check: $marker"
      touch "$secrets/mask-checked"
    fi
    ;;
  cluster)
    : >"$work/b64"
    for ns in $namespaces; do
      # A namespace that does not exist lists no Secret and is not an error; an unreachable cluster is. The request is
      # bounded: a cluster too busy to answer must not hold the scenario past its deadline.
      kubectl --context k3d-svp --request-timeout=10s -n "$ns" get secrets -o json >"$work/list.json" 2>/dev/null ||
        fail "read the Secrets of namespace $ns of cluster k3d-svp: the previous list stays"
      jq -r '.items[] | select(.type != "helm.sh/release.v1") | (.data // {}) | to_entries[]
        | select(.key | ascii_downcase
          | test("^(username|user|dbname|host|port|ca\\.crt|tls\\.crt|sasl|tls)$|(username|[_-]user|email|_key_id|_kid)$")
          | not) | .value' \
        "$work/list.json" >>"$work/b64" || fail "read the Secret list of namespace $ns as JSON"
    done
    # Each value as stored (base64) and decoded: whole when it is one line, line by line (blanks around a line taken
    # off) when it is several. The decoded value is cut at every control character, not only at a newline: a mask is
    # one line of the job's log, which a carriage return or any other control character in it would break, leaving
    # the rest of the value unmasked. It is cut at U+FFFD too, what jq decodes a byte that is not UTF-8 to: a piece
    # holding one would never match the bytes a log or a file shows. A binary value (a gzipped config) gets cut into
    # many short pieces that way; masking those is harmless, and the value as stored, plain base64, is masked whole
    # all the same. The cut points are the code points jq's [[:cntrl:]] matches (U+0000-001F, U+007F-009F) and
    # U+FFFD, each turned into a newline and split on, in time proportional to the value: jq's splits() with a regex
    # takes time that grows with the square of it, minutes for a binary value of 200 KiB.
    jq -R -r '., (@base64d | explode | map(if . < 32 or (. >= 127 and . < 160) or . == 65533 then 10 else . end)
      | implode | split("\n")[] | gsub("^\\s+|\\s+$"; ""))' "$work/b64" |
      while IFS= read -r v || [ -n "$v" ]; do [ "${#v}" -lt "$min_len" ] || printf '%s\n' "$v"; done >"$work/cluster"
    keep cluster
    ;;
  *)
    fail "usage: verify-mask.sh env|cluster"
    ;;
esac
