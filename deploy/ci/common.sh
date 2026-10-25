# shellcheck shell=bash
# Helpers shared by the image pipeline scripts under deploy/ci/.
# Sourcing it only defines things. It sources deploy/k8s/lib.sh for the list of services, the Dockerfile of each and
# the paths each image is built from, so CI and `make k8s-up` never disagree on them. Written for bash 3.2 too (the
# scripts are tried on macOS before they run on the Ubuntu runners).
#
# Rules every script keeps: docker runs without DOCKER_DEFAULT_PLATFORM (the image must be the runner's own
# architecture, never emulated), trivy and syft run from the images pinned in the Makefile, nothing prints a secret
# (trivy masks secrets in its findings; scripts print rule, file and line, never the raw report).

ci_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/k8s/lib.sh
. "$ci_dir/../k8s/lib.sh"
# Everything that depends on the CI platform (outputs, job summary, run links, pull requests): ci_* functions.
# shellcheck source=deploy/ci/platform.sh
. "$ci_dir/platform.sh"

# Every image of the project lives under ghcr_prefix (deploy/k8s/lib.sh).
# The images built only to drill admission: never run by any chart.
# shellcheck disable=SC2034 # read by the scripts that source this file
drill_images=(drill-vulnerable drill-unsigned)
# sign_identity: sets sign_issuer and sign_subject, the keyless identity every signature and attestation must carry
# (the OIDC issuer of the CI platform, and the workflow that signs releases on main). Kyverno checks the same two
# values, so both are read from imageVerification.issuer and .subject of deploy/helm/svp-policy/values.yaml, the one
# place to change them when CI moves to another platform. Read when a check needs them, not when this file is sourced:
# most scripts never verify a signature. Fails unless each is one https:// URL.
sign_identity() {
  local values=$repo_root/deploy/helm/svp-policy/values.yaml
  sign_issuer=$(sed -n 's/^  issuer: *//p' "$values") && sign_subject=$(sed -n 's/^  subject: *//p' "$values") ||
    fail "read $values"
  [[ $sign_issuer =~ ^https://[^[:space:]]+$ && $sign_subject =~ ^https://[^[:space:]]+$ ]] ||
    fail "imageVerification.issuer and subject of $values must each be one plain https:// URL"
}
# Where trivy looks for its vulnerability DB, in this order (its default for v0.76.0, written out so the attestation
# can name it): mirror.gcr.io first, GHCR on 429 or 5xx.
trivy_db_repository=mirror.gcr.io/aquasec/trivy-db:2,ghcr.io/aquasecurity/trivy-db:2
trivyignore=$repo_root/.trivyignore.yaml

# tool_image NAME: prints the pinned image reference NAME (TRIVY_IMAGE, SYFT_IMAGE, COSIGN_IMAGE): from the
# environment when set, otherwise from the line `NAME := ...` of the Makefile, so the machine and CI run the very same
# digest. Fails unless the reference carries a digest.
tool_image() {
  local ref=${!1:-}
  [ -n "$ref" ] || ref=$(sed -n "s/^$1[[:space:]]*:=[[:space:]]*//p" "$repo_root/Makefile")
  case $ref in
  *@sha256:*) echo "$ref" ;;
  *) fail "$1 is neither in the environment nor pinned by digest in the Makefile" ;;
  esac
}

# runner_arch: the architecture docker builds for on this host, as amd64 or arm64.
runner_arch() {
  case $(docker_ version --format '{{.Server.Arch}}') in
  amd64 | x86_64) echo amd64 ;;
  arm64 | aarch64) echo arm64 ;;
  *) fail "docker runs on an architecture the pipeline does not build" ;;
  esac
}

# now_utc: the current time in RFC 3339, UTC, to the second: the form cosign's vuln predicate requires.
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# trivy_cache: the directory trivy keeps its DB in (CI saves it with actions/cache, one key per day).
trivy_cache() {
  local dir=${SVP_TRIVY_CACHE:-${TMPDIR:-/tmp}/svp-trivy-cache}
  mkdir -p "$dir" || fail "create the trivy cache $dir"
  echo "$dir"
}

# trivy_ ARGS...: runs the pinned trivy as the calling user (files it writes stay readable for the cache and the
# artifacts), with its cache and DB repositories set. Callers add their own volumes through the array trivy_mounts.
trivy_mounts=()
trivy_() {
  local image
  image=$(tool_image TRIVY_IMAGE) || return 1
  # The odd expansion keeps an empty array from tripping `set -u` in bash 3.2.
  docker_ run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$(trivy_cache):/cache" \
    ${trivy_mounts[@]+"${trivy_mounts[@]}"} "$image" "$@" --cache-dir /cache
}

# trivy_scan_args: the scan flags, the same for the build gate and the rescan: vulnerabilities
# and secrets, every severity, JSON. The ignore file is passed only when it exists (trivy fails on a missing one); it is
# mounted at /ignore.yaml by the caller.
trivy_scan_args() {
  printf '%s\n' --scanners vuln,secret --db-repository "$trivy_db_repository" --format json
  [ -f "$trivyignore" ] && printf '%s\n' --ignorefile /ignore.yaml
  return 0
}

# trivy_db_updated_at: prints UpdatedAt of the DB in the cache (RFC 3339), the version the vuln predicate records.
trivy_db_updated_at() {
  # Trivy writes nanoseconds; cut to seconds so every time in the predicate has one form.
  trivy_ version --format json | jq -er '.VulnerabilityDB.UpdatedAt | sub("\\.[0-9]+"; "")' ||
    fail "read the trivy DB version"
}

# oci_labels: prints the OCI labels of the commit at HEAD as key=value lines: the source
# repository, the commit, and the commit time in UTC, so the same commit always gets the same labels whatever the build time.
oci_labels() {
  local rev created
  rev=$(git -C "$repo_root" rev-parse HEAD) || fail "read the commit at HEAD"
  created=$(TZ=UTC git -C "$repo_root" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ HEAD) ||
    fail "read the commit time of HEAD"
  echo "org.opencontainers.image.source=https://github.com/anhnvcoder/short-video-platform"
  echo "org.opencontainers.image.revision=$rev"
  echo "org.opencontainers.image.created=$created"
}

# is_digest VALUE: true when VALUE is sha256:<64 lowercase hex>.
is_digest() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }

# fetch_manifest REF FILE: writes to FILE the manifest (or index) REF points to, byte for byte as the registry stores
# it (a file, not a shell variable, which would drop a trailing newline and change the digest), and prints the sha256
# digest of those bytes.
fetch_manifest() {
  docker_ buildx imagetools inspect --raw "$1" >"$2" || return 1
  echo "sha256:$(shasum -a 256 "$2" | cut -d' ' -f1)"
}

# values_field (the strict reader of image.repository, image.tag and image.digest in a service's values file) is in
# deploy/k8s/lib.sh, shared with the GitOps path.

# cosign_ ARGS...: cosign from PATH (CI installs it with sigstore/cosign-installer), otherwise the pinned image
# COSIGN_IMAGE (machine: verification only, never signing).
cosign_() {
  if command -v cosign >/dev/null 2>&1; then
    cosign "$@"
  else
    local image
    image=$(tool_image COSIGN_IMAGE) || return 1
    docker_ run --rm "$image" "$@"
  fi
}

# verify_signature REPOSITORY DIGEST: true when REPOSITORY@DIGEST carries a signature of the identity above.
verify_signature() {
  sign_identity
  cosign_ verify --certificate-oidc-issuer "$sign_issuer" --certificate-identity "$sign_subject" "$1@$2" >/dev/null
}

# check_index REPOSITORY DIGEST DIR DIR: true when REPOSITORY@DIGEST, read back from the registry, is an index of
# exactly two manifests, linux/amd64 and linux/arm64, whose digests are the `digest` files of the two DIRs (one per
# platform, named in their `platform` files), and when DIGEST really is the digest of those bytes. What gets signed
# and attested is then exactly what was scanned.
check_index() {
  local raw want got
  raw=$(mktemp) || return 1
  if [ "$(fetch_manifest "$1@$2" "$raw")" = "$2" ]; then
    want=$(for d in "$3" "$4"; do echo "$(cat "$d/platform") $(cat "$d/digest")"; done | sort)
    got=$(jq -r 'select(.mediaType == "application/vnd.oci.image.index.v1+json"
        or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")
      | .manifests[] | "\(.platform.os)/\(.platform.architecture) \(.digest)"' "$raw" | sort)
  fi
  rm -f "$raw"
  [ -n "${want:-}" ] && [ "$want" = "$got" ]
}

# attest_max_age: the oldest vuln attestation a release may carry when it enters main, in seconds: 48 hours, which
# leaves at least 24 hours before Kyverno's 72-hour limit for the merge and the sync. Only drills
# lower it, through SVP_ATTEST_MAX_AGE (<number>s, m or h; never set in .env).
attest_max_age() {
  local age=${SVP_ATTEST_MAX_AGE:-48h}
  [[ $age =~ ^[0-9]+[smh]$ ]] || fail "SVP_ATTEST_MAX_AGE must look like 48h, 15m or 90s, not '$age'"
  case $age in
  *s) echo "${age%s}" ;;
  *m) echo $((${age%m} * 60)) ;;
  *h) echo $((${age%h} * 3600)) ;;
  esac
}

# check_vuln_statement DIGEST MAX_AGE_SECONDS: reads one in-toto statement (the decoded payload of a vuln
# attestation) on stdin and checks what Kyverno will check, with the tighter age: predicate type, subject DIGEST,
# exactly linux/amd64 then linux/arm64, no CRITICAL, scanFinishedOn at most MAX_AGE_SECONDS old. Prints the first
# problem.
check_vuln_statement() {
  local verdict
  verdict=$(jq -r --arg d "${1#sha256:}" --argjson max "$2" '
    def platforms: .predicate.scanner.result.platforms;
    if .predicateType != "https://cosign.sigstore.dev/attestation/vuln/v1" then "not a vuln attestation"
    elif ([.subject[]?.digest.sha256] | index($d)) == null then "the attestation is not about this digest"
    elif ([platforms[]?.platform] != ["linux/amd64", "linux/arm64"])
      then "does not cover exactly linux/amd64 and linux/arm64"
    elif ([platforms[]?.digest | test("^sha256:[0-9a-f]{64}$")] | all | not) then "a platform digest is malformed"
    elif ([platforms[]?.report.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length) > 0
      then "lists CRITICAL vulnerabilities"
    elif ((.predicate.metadata.scanFinishedOn // "")
      | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not)
      then "scanFinishedOn is not RFC 3339"
    elif (now - (.predicate.metadata.scanFinishedOn | fromdateiso8601)) > $max
      then "scan finished \(.predicate.metadata.scanFinishedOn), more than \($max) seconds ago"
    else "ok" end' 2>/dev/null) || verdict="is not readable JSON"
  [ "$verdict" = ok ] && return 0
  echo "$verdict"
  return 1
}
