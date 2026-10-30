#!/usr/bin/env bash
# rescan.sh: the daily rescan of released images. A release was
# clean when it was built; new vulnerabilities are published every day, and Kyverno accepts a vuln attestation for
# 72 hours only, so every released digest is scanned again with the newest DB and its attestation replaced.
#
#   rescan.sh scan-index REPOSITORY DIGEST OUT
#     Reads the index REPOSITORY@DIGEST from the registry, finds its two manifests (linux/amd64, linux/arm64) and scans
#     EACH from the registry with the gate's flags (trivy reads one platform per scan, so scanning the index would
#     prove nothing about arm64). Writes OUT/amd64 and OUT/arm64 in the layout vuln-predicate.sh reads and prints the
#     two manifest digests.
#
#   rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF]   (CI only: it attests)
#     For every release `list` prints: an empty digest is skipped; a repository other than the service's image of
#     release source NAME (backend, this repository, when not given; deploy/helm/svp-policy/files/sources.json of this
#     checkout), a malformed digest, or a digest without a signature of that source's images.yml on main is not attested
#     and fails the run, so whatever a ref lists, only digests the workflow running this signed on main get a fresh
#     attestation: no repository attests another's releases. Each digest left is scanned (scan-index), its predicate
#     built by vuln-predicate.sh --allow-critical and attested with `cosign attest --replace --type vuln`, so the
#     attestation always holds the real result: a CRITICAL found today is recorded (Kyverno then refuses new pods
#     because of it, not because of an old attestation) and fails the run, which mails the owner. A secret found today
#     is never attested: it fails the run before anything is written, as at build time. SARIF of the digests of main of
#     svp-gitops go to OUT/sarif for the Security tab. The drill images are in no image file, so they are never
#     rescanned.
#
#   rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]
#     Prints the releases a run of source NAME rescans, one per line: service, repository, digest (both empty when not
#     released) and where it was read, separated by tabs. Read as data with `git show`, never run: image.repository
#     and image.digest of envs/<env>/images/<service>.yaml of every environment of the deployment repository
#     svp-gitops, at its main, at the promote branch of that source (bot/promote-stg for backend,
#     bot/promote-stg-<NAME> otherwise) while its pull request is open there (the source's promoter app's own, never a
#     fork's from a branch of that name), and at VALUES_REF when given (a branch, a full commit or refs/pull/<n>/head
#     of svp-gitops). A file naming a release of another source is left out with a line on stderr (that source's CI
#     rescans it); one under the prefix of no source is listed, so the run fails on it. For backend only, a
#     VALUES_REF that svp-gitops has not, and that is a full commit of this repository from before svp-gitops held the
#     releases, is read there instead, from deploy/k8s/values/services/<service>.yaml: a release only that history
#     names (a web release from before CI attested provenance, which the supply chain drill needs) gets a fresh
#     attestation too. GITOPS_DIR is a clone of svp-gitops (CI's, from make gitops-clone): the refs are fetched into
#     it under refs/svp/rescan/, anonymously; the open pull request is asked of the repository's host with the job's
#     own token, a read of a public repository. Fails, after printing every release it could read, when a file cannot
#     be read or the host does not say whether the pull request is open (main and VALUES_REF are still listed); fails
#     at once when VALUES_REF is neither.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

# scan_index REPOSITORY DIGEST OUT: see scan-index above.
scan_index() {
  local repo=$1 digest=$2 out=$3 index arch child dir args a
  mkdir -p "$out" || fail "create $out"
  index=$out/index.json
  [ "$(fetch_manifest "$repo@$digest" "$index")" = "$digest" ] || fail "read the index $repo@$digest, byte for byte"
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(trivy_scan_args)
  trivy_mounts=(-v "$out:/out")
  [ -f "$trivyignore" ] && trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
  for arch in amd64 arm64; do
    child=$(jq -r --arg a "$arch" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a)]
      | if length == 1 then .[0].digest else empty end' "$index")
    is_digest "$child" || fail "$repo@$digest has no single linux/$arch manifest"
    dir=$out/$arch
    mkdir -p "$dir"
    echo "linux/$arch" >"$dir/platform"
    echo "$child" >"$dir/digest"
    [ "$(fetch_manifest "$repo@$child" "$dir/manifest.json")" = "$child" ] || fail "read $repo@$child, byte for byte"
    jq -r .config.digest "$dir/manifest.json" >"$dir/config-digest"
    now_utc >"$dir/scan-started"
    # A DB that cannot be downloaded fails the scan: never an attestation from a DB of unknown age.
    trivy_ image --image-src remote "${args[@]}" --output "/out/$arch/trivy.json" "$repo@$child" ||
      fail "scan $repo@$child"
    now_utc >"$dir/scan-finished"
    trivy_db_updated_at >"$dir/db-updated-at"
    echo "scanned linux/$arch $child"
  done
}

# image_line FILE REF WHERE (stdin: FILE at REF): prints "service<TAB>repository<TAB>digest<TAB>WHERE" of an image
# file; status 1, naming FILE at REF, when its image block cannot be read.
image_line() {
  local values svc repo digest
  values=$(cat)
  svc=$(basename "$1" .yaml)
  digest=$(values_field digest <<<"$values") || {
    echo "FAIL  $1 at $2: image.digest is not one plain line" >&2
    return 1
  }
  repo=$(values_field repository <<<"$values") || {
    echo "FAIL  $1 at $2: image.repository is not one plain line" >&2
    return 1
  }
  printf '%s\t%s\t%s\t%s\n' "$svc" "$repo" "$digest" "$3"
}

# source_args ARGS...: reads an optional --source NAME off ARGS; sets source (backend by default), source_branch and
# source_app (its promote branch and promoter app), and args to the rest.
source_args() {
  local src
  source=backend
  if [ "${1:-}" = --source ]; then
    source=${2:-}
    shift 2 || fail "--source needs a name"
  fi
  src=$(release_source "$source") || exit 1
  source_app=$(jq -r .promoter <<<"$src")
  source_branch=$gitops_promote_branch
  [ "$source" = backend ] || source_branch=$gitops_promote_branch-$source
  args=("$@")
}

# keep_own: reads the lines of list on stdin and prints those of source's releases and those of no source; one of
# another source's is named on stderr instead.
keep_own() {
  local line svc repo where owner
  # Split by hand: read with IFS=<tab> would merge the two tabs around an empty digest.
  while IFS= read -r line; do
    svc=${line%%$'\t'*}
    repo=${line#*$'\t'}
    repo=${repo%%$'\t'*}
    where=${line##*$'\t'}
    if owner=$(source_of_repository "$repo" 2>/dev/null) && [ "$owner" != "$source" ]; then
      echo "skip  $svc in $where: $repo is a release of source $owner, which its own CI rescans" >&2
      continue
    fi
    printf '%s\n' "$line"
  done
}

# list GITOPS_DIR [VALUES_REF]: see `list` above (source_args first).
list() {
  local dir=$1 values_ref=${2:-} refs=() labels=() prs open i ref e svc file status=0 code=
  [ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$dir" 2>/dev/null && pwd -P)" ] ||
    fail "$dir is not a clone of svp-gitops (make gitops-clone)"
  # gf ARGS...: an anonymous fetch from svp-gitops into the clone.
  gf() { GIT_TERMINAL_PROMPT=0 git -C "$dir" -c credential.helper= fetch --quiet --no-tags origin "$@"; }
  gf "+refs/heads/main:refs/svp/rescan/main" || fail "fetch main of svp-gitops"
  refs+=(refs/svp/rescan/main) labels+=("main of svp-gitops")
  # Unanswered, the releases of main and of VALUES_REF are still listed (and rescanned) before the run fails: they are
  # what stg and prd run, whose attestations must not age out because the host did not answer.
  if ! prs=$(ci_change_request_list "$source_branch" main "$gitops_repo"); then
    echo "FAIL  ask the repository's host whether the promote pull request of $gitops_repo is open; $source_branch not read" >&2
    status=1
  elif ! open=$(ci_change_request_pick "$source_app" <<<"$prs"); then
    echo "FAIL  read the open pull requests of $source_branch; $source_branch not read" >&2
    status=1
  elif [ -n "$open" ]; then
    gf "+refs/heads/$source_branch:refs/svp/rescan/promote" || fail "fetch $source_branch of svp-gitops"
    refs+=(refs/svp/rescan/promote) labels+=("$source_branch of svp-gitops (pull request #$open)")
  fi
  if [ -n "$values_ref" ]; then
    if gf "+$values_ref:refs/svp/rescan/values-ref" 2>/dev/null; then
      refs+=(refs/svp/rescan/values-ref) labels+=("$values_ref of svp-gitops")
    elif [ "$source" = backend ] && [[ $values_ref =~ ^[0-9a-f]{40}$ ]]; then
      # A clone of the code repository may be shallow (CI's checkout): the commit is fetched when it is not there.
      git -C "$repo_root" cat-file -e "$values_ref^{commit}" 2>/dev/null ||
        git -C "$repo_root" fetch --quiet --no-tags --depth 1 origin "$values_ref" 2>/dev/null || true
      git -C "$repo_root" cat-file -e "$values_ref:deploy/k8s/values/services" 2>/dev/null ||
        fail "values_ref $values_ref is neither a commit of svp-gitops nor one of this repository with deploy/k8s/values/services/"
      code=$values_ref
    else
      fail "values_ref $values_ref is no ref of svp-gitops"
    fi
  fi
  for i in "${!refs[@]}"; do
    ref=${refs[$i]}
    for e in $(git -C "$dir" ls-tree --name-only "$ref:envs" 2>/dev/null); do
      for svc in "${svp_services[@]}"; do
        file=envs/$e/images/$svc.yaml
        if ! git -C "$dir" show "$ref:$file" 2>/dev/null | image_line "$file" "${labels[$i]}" "${labels[$i]}, $file" |
          keep_own; then
          status=1
        fi
      done
    done
  done
  if [ -n "$code" ]; then
    for svc in "${svp_services[@]}"; do
      file=deploy/k8s/values/services/$svc.yaml
      if ! git -C "$repo_root" show "$code:$file" 2>/dev/null |
        image_line "$file" "${code:0:12}" "commit ${code:0:12} of the code repository, $file" | keep_own; then
        status=1
      fi
    done
  fi
  return "$status"
}

# rescan_one SERVICE REPOSITORY DIGEST DIR SARIF_DIR: scans, gates secrets, attests, then fails on CRITICAL for one
# release; SARIF_DIR empty for a digest that is not main's. Run in a subshell, so a failure (fail exits) stops this
# digest only.
rescan_one() {
  local svc=$1 repo=$2 digest=$3 dir=$4 sarif=$5 arch blocked=0 critical
  verify_signature "$repo" "$digest" || fail "$repo@$digest has no signature of its source's images.yml on main; not attested"
  echo "rescan $repo@$digest"
  scan_index "$repo" "$digest" "$dir"
  # The gate runs before anything is written, with --allow-critical: the rescan's exception covers CRITICAL only. A
  # secret (or a broken .trivyignore.yaml) blocks as at build time: the attestation is public and Rekor keeps its whole
  # envelope for good, so the report's secret findings would be published with it. The old attestation then ages out
  # and Kyverno refuses new pods after 72 hours; the red run mails the owner now.
  for arch in amd64 arm64; do
    "$ci_dir/scan-gate.sh" --allow-critical "$svc linux/$arch (rescan)" "$dir/$arch/trivy.json" || blocked=1
    [ -n "$sarif" ] || continue
    trivy_mounts=(-v "$dir/$arch:/in:ro" -v "$sarif:/out")
    trivy_ convert --format sarif --severity HIGH,CRITICAL --output "/out/$svc-$arch.sarif.tmp" /in/trivy.json ||
      fail "convert the report of $svc linux/$arch to SARIF"
    jq --arg c "trivy-image-$svc-$arch/" '.runs[].automationDetails.id = $c' "$sarif/$svc-$arch.sarif.tmp" \
      >"$sarif/$svc-$arch.sarif"
    rm -f "$sarif/$svc-$arch.sarif.tmp"
  done
  [ "$blocked" -eq 0 ] || fail "$repo@$digest is blocked by the scan gate; not attested"
  "$ci_dir/vuln-predicate.sh" --allow-critical "$dir/predicate.json" "$dir/amd64" "$dir/arm64" ||
    fail "build the vuln predicate of $repo@$digest"
  cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type vuln \
    --predicate "$dir/predicate.json" "$repo@$digest" || fail "attest $repo@$digest"
  echo "ok    $repo@$digest attested with today's scan"
  # A CRITICAL is now recorded (Kyverno refuses new pods because of it, not because of an old attestation) and fails
  # the run.
  critical=$(jq -s '[.[].Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' \
    "$dir/amd64/trivy.json" "$dir/arm64/trivy.json") || fail "count CRITICAL of $repo@$digest"
  [ "$critical" -eq 0 ] || fail "$repo@$digest: $critical CRITICAL vulnerabilities, recorded in its vuln attestation"
}

run() {
  local platform
  platform=$(ci_platform) || exit 1
  [ "$platform" != local ] || fail "rescan.sh run attests with the workflow's identity: CI only"
  source_args "$@"
  set -- ${args[@]+"${args[@]}"}
  [ $# -ge 2 ] && [ $# -le 3 ] || fail "usage: rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF]"
  local out=$1 lines svc repo digest where key sarif n=0 failed=0 seen=" " own
  mkdir -p "$out/sarif" || fail "create $out"
  out=$(cd "$out" && pwd)
  lines=$(list "$2" "${3:-}") || failed=1
  while IFS=$'\t' read -r svc repo digest where; do
    [ -n "$svc" ] || continue
    if [ -z "$digest" ]; then
      ci_summary "- $svc in $where: no digest, not released yet: skipped"
      continue
    fi
    key="$svc@$digest"
    case $seen in *" $key "*) continue ;; esac
    seen="$seen$key "
    n=$((n + 1))
    if ! own=$(release_source_of "$svc" "$repo") || [ "$(jq -r .name <<<"$own")" != "$source" ] || ! is_digest "$digest"; then
      echo "FAIL  $svc in $where: $repo@$digest is not a release of $svc of source $source; not attested" >&2
      failed=1
      continue
    fi
    sarif=
    case $where in "main of svp-gitops,"*) sarif=$out/sarif ;; esac
    (rescan_one "$svc" "$repo" "$digest" "$out/$n-$svc" "$sarif") || failed=1
  done <<<"$lines"
  [ "$n" -gt 0 ] || ci_summary "No released digest to rescan."
  return "$failed"
}

case ${1:-} in
scan-index)
  [ $# -eq 4 ] || fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT"
  is_digest "$3" || fail "$3 is not sha256:<64 hex>"
  scan_index "$2" "$3" "$4"
  ;;
run)
  shift
  run "$@"
  ;;
list)
  shift
  source_args "$@"
  set -- ${args[@]+"${args[@]}"}
  [ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]"
  list "$1" "${2:-}"
  ;;
*) fail "usage: rescan.sh scan-index REPOSITORY DIGEST OUT | rescan.sh run [--source NAME] OUT GITOPS_DIR [VALUES_REF] | rescan.sh list [--source NAME] GITOPS_DIR [VALUES_REF]" ;;
esac
