#!/usr/bin/env bash
# Tests for deploy/ci/platform.sh, the functions the CI scripts call for everything that depends on the CI platform,
# and for the scripts that call them. Everything runs in a temporary directory: the variables of a GitHub Actions job
# are made up, and a fake gh and a fake cosign first on PATH record their arguments and answer from fixtures, so no
# test reaches GitHub, a registry or Sigstore. Checked:
#   - github (a made-up job): outputs, the job summary, masks, warnings and run links land where GitHub reads them,
#     and pull requests are written through gh with the job's repository;
#   - local: everything on stdout, no mask, links "local", and no write through the platform's API (reads still are);
#   - another CI (GitLab CI, a CI=true one): a clear error, nothing written;
#   - the author of the pull request a run checks, read from the event (an app's bot, a person), nothing for a push, a
#     dispatch or a machine without SVP_CHANGE_REQUEST_AUTHOR, a failure naming the problem for a pull request event
#     whose author is missing, of another shape or unreadable, and on GitLab CI; the sender of that event the same way
#     (sender.login; SVP_CHANGE_REQUEST_SENDER on a machine);
#   - pull requests of another repository (svp-gitops) and of an app's bot, auto-merge for a given head, the bot of an
#     app (its id read from the host), the credential helper a push gets the job's token from, and the push time of a
#     commit of another repository;
#   - the records of an environment (deployments of svp-gitops): a record is a deployment with auto_merge false and
#     required_contexts [], then a status success that leaves earlier records active, its id printed; a dry run and a
#     machine print both requests and write nothing; a record of a short ref, an environment that is not a plain name
#     or a payload that is not JSON is refused before gh; the list gives each record its latest state and every
#     status the host returns, newest first; a run URL is a run of the code repository;
#   - the scripts give what they gave when they read GitHub's variables themselves: plan.sh, vuln-predicate.sh,
#     provenance-predicate.sh (the workflow, ref and commit of the run, and the services input of a dispatch),
#     scan-gate.sh and values-check.sh (the signing identity is read from the table of release sources of the
#     policy's chart; promote.sh has a test of its own, promote-test.sh);
#   - scan-gate.sh --grype on grype reports written by hand: a Critical match blocks and is named, --allow-critical lets
#     it through, High and below are only counted; an entry of .trivyignore.yaml covers a match by its id or a related
#     id with the same purl (qualifiers and escapes aside), never another version; an expired entry fails the gate;
#     a report that is not grype's exits 2;
#   - platform-guard.sh passes the throwaway checkout and fails, naming file:line, a script that reads GITHUB_OUTPUT or
#     calls gh itself;
#   - verify-release.sh with a fake cosign that answers from fixtures, on a tree laid out as svp-gitops: without
#     requireProvenance in the policy's values at the commit charts.yaml pins or in the overlays only the signature and
#     the vuln attestation are asked for; with it on (in the values at that commit, in the overlay of an environment,
#     at a commit of the tree with --rev, for one environment with --env, in the clone gitops_dir finds) the release
#     also needs exactly one provenance attestation whose builder.id, workflow repository and ref match the policy and
#     whose commit the certificate names, each fault with its own message; an overlay holding anything else, and a
#     charts.yaml naming no commit, are refused; a provenance cosign cannot read (registry out of reach, or a first
#     call that failed and a second that verified) asks to check again, never for a new release; the ok line it prints
#     is the one tag_provenance_mismatch of common.sh reads (image.tag against the provenance's commit); an image is
#     verified with the identity of the release source whose prefix it is under, in the table at the commit an
#     environment's charts.yaml pins (a commit from before the table reads as its one source backend), a service its
#     source does not publish is refused before cosign, and every environment must admit it without --env;
#   - the release sources in common.sh: sign_identity and provenance_source without a source name are backend's,
#     oci_labels names its source's repository and the commit of SVP_CODE_ROOT, and drill_images is drillImages of
#     source backend;
#   - values-check.sh --gitops on a pull request of that tree: one that turns provenance on in an overlay, or moves an
#     environment's charts.yaml, checks every release of that environment and none of the other; one of an image file
#     checks that file; one of another file checks none;
#   - plan.sh on a push to main that builds no image: promote_charts when a file under deploy/helm/ or one a symbolic
#     link there points to changed, not for docs/;
#   - gitops_no_provenance of deploy/ci/verify/gitops.sh: the newest web release in the history of web.yaml that the
#     fake cosign finds signed without provenance, passing over without cosign a release built from a commit holding
#     provenance-predicate.sh; none found and an error of cosign each exit with their own status;
#   - changed-services.sh builds all six images of this repository (never web, which svp-web builds) for a change of
#     platform.sh, as for common.sh and rescan.sh, and none for a change under web/ (a file added, then deleted) or of
#     this test, of promote-test.sh, of platform-guard.sh, of sourcemaps-image.sh and its test (another
#     source's CI pushes that image), of a scenario file under deploy/ci/verify/, of the
#     scripts of other workflows and of svp-gitops's check (record-stg.sh, gitops-check.sh with values-check.sh and
#     verify-release.sh, dora.sh and the tests of
#     these and of release-set.sh, promote-prd.sh), of the policy's values or of docs/; all six for a change of
#     release-set.sh and promote-prd.sh (job promote-prd of images.yml), and of the GRYPE_IMAGE line of the Makefile,
#     none for another line of it;
#   - platform-guard.sh reads the scenario files under deploy/ci/verify/ too; given another repository's tree as ROOT
#     (svp-web's) it reads every file there but .github/ and .backend/, and a ROOT that is no directory or no git
#     tree exits 2;
#   - rescan.sh run attests only the releases of the source of the run's repository, as that source's signing
#     workflow: a run of svp-web without --source web, a run of backend with --source web, and a run of svp-web from
#     another workflow fail, naming both sources (or the identity), before the host or cosign is asked anything; the
#     scheduled run of backend and the run of svp-web with --source web each read their own promote pull request and
#     ask cosign for their own releases only, leaving the other source's to it; on a machine the run is refused first;
#   - another repository's tree (SVP_CODE_ROOT, a checkout whose origin is svp-web): on a machine ci_repo, ci_repo_url
#     and ci_commit are that checkout's (and a checkout with no origin on github.com is refused, an origin's
#     credential never shown); plan.sh of svp-web's run builds the services of its release source at every run, with
#     no base, refuses a service or a drill its source does not have and a tree whose HEAD is not the run's commit, and
#     in this checkout refuses a run of svp-web that forgot SVP_CODE_ROOT and a run of a fork; in this checkout plan.sh
#     builds the six for services all and refuses services web, and build-image.sh refuses web before it builds
#     anything; scan-gate.sh reads that tree's .trivyignore.yaml and stops, naming it, when the tree has none.
# Runs on macOS and Linux: no network, no Docker, no cluster.
#
# Usage, from anywhere: deploy/ci/platform-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  failures=$((failures + 1))
}
# check NAME COMMAND...: ok when COMMAND succeeds.
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
# same NAME WANT GOT: ok when the two strings are equal; shows both otherwise.
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"$'\n'"      want: $2"$'\n'"      got:  $3"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# --- Fakes. gh writes each call to gh.log, one line of %q-quoted arguments, and answers pr list from gh/prs.json; api
# with gh/runs.json for a workflow's runs, gh/artifacts-<run>.json for a run's artifacts (none when the file is missing),
# gh/run-<run>.json for a run (the host fails when the file is missing), gh/pulls.json for the pull requests of a commit (none when the file is missing), gh/user.json for a user, and
# gh/events.json otherwise, run through its --jq filter; run download writes the file image-digest into its --dir.
# With FAKE_GH_FAIL set it fails as the host would; with FAKE_GH_DOWNLOAD_FAIL set only run download fails, naming the
# signed link it was sent to, as gh does, and with GH_DEBUG or DEBUG set run download prints its request line as gh's
# debug log does. cosign records its arguments and refuses every signature; with FAKE_COSIGN_DIR set it accepts every
# signature, prints FAKE_COSIGN_DIR/<type>.jsonl for verify-attestation --type <type> (refusing without that file), and
# with --certificate-github-workflow-sha accepts only the commit in FAKE_COSIGN_DIR/cert-sha.
mkdir -p "$work/bin" "$work/gh" "$work/runner-temp" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  echo "HTTP 502: Bad Gateway" >&2
  exit 1
fi
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
"api -X")
  method=$3 path=$4
  # A body (--input FILE, - for stdin) is appended to inputs.jsonl, one compact line.
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = --input ]; then
      j=$((i + 1))
      if [ "${!j}" = - ]; then jq -c . >>"$FAKE_GH_DIR/inputs.jsonl"; else jq -c . "${!j}" >>"$FAKE_GH_DIR/inputs.jsonl"; fi
    fi
  done
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  case $method:$path in
  POST:*/deployments) file=$FAKE_GH_DIR/deployment-made.json ;;
  POST:*/deployments/*/statuses) file=$FAKE_GH_DIR/status-made.json ;;
  GET:*/deployments/*/statuses)
    id=${path%/statuses}
    file=$FAKE_GH_DIR/statuses-${id##*/}.json
    [ -f "$file" ] || file=$FAKE_GH_DIR/no-pulls.json
    ;;
  GET:*/deployments) file=$FAKE_GH_DIR/deployments.json ;;
  esac
  [ -z "${file:-}" ] || { jq -r "$2" "$file"; exit; }
  case $path in
  */actions/workflows/*/runs) file=$FAKE_GH_DIR/runs.json ;;
  */actions/runs/*/artifacts)
    id=${path%/artifacts}
    file=$FAKE_GH_DIR/artifacts-${id##*/}.json
    [ -f "$file" ] || file=$FAKE_GH_DIR/no-artifacts.json
    ;;
  */actions/runs/*)
    file=$FAKE_GH_DIR/run-${path##*/}.json
    [ -f "$file" ] || { echo "HTTP 404: Not Found" >&2 && exit 1; }
    ;;
  */commits/*/pulls)
    file=$FAKE_GH_DIR/pulls.json
    [ -f "$file" ] || file=$FAKE_GH_DIR/no-pulls.json
    ;;
  users/*) file=$FAKE_GH_DIR/user.json ;;
  *) file=$FAKE_GH_DIR/events.json ;;
  esac
  jq -r "$2" "$file"
  ;;
"run download")
  if [ -n "${GH_DEBUG:-}${DEBUG:-}" ]; then
    echo "> GET /a/archive.zip?sv=2025-01-05&sig=SIGNEDQUERY%3D HTTP/1.1" >&2
  fi
  if [ -n "${FAKE_GH_DOWNLOAD_FAIL:-}" ]; then
    echo "error downloading web-sourcemaps-amd64: HTTP 403: Server failed to authenticate the request." \
      "(https://results.blob.example/a/archive.zip?sv=2025-01-05&se=2026-10-26T14%3A00Z&sig=SIGNEDQUERY%3D)" >&2
    echo "error downloading web-sourcemaps-amd64: Get \"https://results.blob.example:443/a/archive.zip?sig=SIGNEDQUERY\":" \
      "dial tcp: lookup results.blob.example: no such host" >&2
    exit 1
  fi
  while [ $# -gt 0 ] && [ "$1" != --dir ]; do shift; done
  echo "$FAKE_GH_DIGEST" >"$2/image-digest"
  ;;
esac
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
if [ -n "${FAKE_COSIGN_DIR:-}" ]; then
  case $1 in
  verify) exit 0 ;;
  verify-attestation)
    type= sha=
    while [ $# -gt 0 ]; do
      case $1 in
      --type) type=$2 && shift ;;
      --certificate-github-workflow-sha) sha=$2 && shift ;;
      esac
      shift
    done
    # FAKE_COSIGN_DOWN=TYPE: the registry is out of reach for that type; with FAKE_COSIGN_DOWN_ONCE=FILE only for the
    # first call, which writes FILE.
    if [ "${FAKE_COSIGN_DOWN:-}" = "$type" ] && { [ -z "${FAKE_COSIGN_DOWN_ONCE:-}" ] || [ ! -e "$FAKE_COSIGN_DOWN_ONCE" ]; }; then
      [ -z "${FAKE_COSIGN_DOWN_ONCE:-}" ] || : >"$FAKE_COSIGN_DOWN_ONCE"
      echo "Error: GET https://ghcr.io/v2/: dial tcp: i/o timeout" >&2
      exit 1
    fi
    if [ ! -f "$FAKE_COSIGN_DIR/$type.jsonl" ]; then
      echo "Error: none of the attestations matched the predicate type: $type" >&2
      exit 1
    fi
    if [ -n "$sha" ] && [ "$sha" != "$(cat "$FAKE_COSIGN_DIR/cert-sha")" ]; then
      echo "Error: expected GitHub Workflow SHA not found in certificate" >&2
      exit 1
    fi
    cat "$FAKE_COSIGN_DIR/$type.jsonl"
    exit 0
    ;;
  esac
fi
echo "Error: no signatures found" >&2
exit 1
EOF
chmod 755 "$work/bin/gh" "$work/bin/cosign"
echo '[]' >"$work/gh/prs.json"
echo '{"total_count": 0, "artifacts": []}' >"$work/gh/no-artifacts.json"
echo '[]' >"$work/gh/no-pulls.json"
echo '{"id": 271828}' >"$work/gh/user.json"
echo '{"id": 9001, "sha": "x"}' >"$work/gh/deployment-made.json"
echo '{"id": 1, "state": "success"}' >"$work/gh/status-made.json"

# on PLATFORM COMMAND...: runs COMMAND with the variables of PLATFORM and none of the others': github (a made-up job of
# repository octo/repo), local (none), gitlab (GitLab CI's own). git reads no configuration of this machine.
on() {
  local platform=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u CI -u GITLAB_CI -u JENKINS_URL
    -u TF_BUILD -u GIT_DIR -u GIT_WORK_TREE -u PROMOTE_DRY_RUN -u PROMOTE_DRY_RUN_PRS -u RUNNER_ENVIRONMENT
    -u FAKE_GH_FAIL -u FAKE_GH_DOWNLOAD_FAIL -u SVP_CODE_ROOT -u SVP_CHANGE_REQUEST_AUTHOR
    -u SVP_CHANGE_REQUEST_SENDER
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" FAKE_GH_DIGEST=sha256:fetched FAKE_COSIGN_LOG="$work/cosign.log")
  case $platform in
  github)
    "${base[@]}" GITHUB_ACTIONS=true CI=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main GITHUB_REF=refs/heads/main \
      GITHUB_SHA=89abcdef0123456789abcdef0123456789abcdef GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$work/event.json" \
      RUNNER_TEMP="$work/runner-temp" "$@"
    ;;
  local) "${base[@]}" "$@" ;;
  gitlab) "${base[@]}" GITLAB_CI=true CI=true "$@" ;;
  esac
}
# fn PLATFORM SNIPPET: runs SNIPPET in bash after sourcing platform.sh, on PLATFORM.
fn() { on "$1" "$BASH" -c ". \"\$0\"; $2" "$here/platform.sh"; }
# fresh: empties the files the platform and the fakes write to.
fresh() { : >"$work/output" && : >"$work/summary" && : >"$work/gh.log" && : >"$work/cosign.log"; }
# gh_line ARGS...: a line of gh.log as the fake writes it for a call with ARGS.
gh_line() { printf '%q ' "$@"; }

# --- ci_platform.
same "github: GITHUB_ACTIONS=true is GitHub Actions" github "$(fn github ci_platform)"
same "local: no CI variable is a machine" local "$(fn local ci_platform)"
same "local: CI=false is no CI" local "$(on local env CI=false "$BASH" -c '. "$0"; ci_platform' "$here/platform.sh")"
for ci in GITLAB_CI=true CI=true CI=1 JENKINS_URL=https://jenkins.example TF_BUILD=True; do
  if out=$(on local env "$ci" "$BASH" -c '. "$0"; ci_platform' "$here/platform.sh" 2>&1); then
    fail "$ci: refused (got '$out')"
  else
    case $out in
    *"only GitHub Actions and local runs are implemented; add a branch in deploy/ci/platform.sh for another CI"*)
      ok "$ci: refused, naming what to do" ;;
    *) fail "$ci: refused, naming what to do (got '$out')" ;;
    esac
  fi
done

# --- github, with the variables of a made-up job.
fresh
got=$(fn github 'ci_output mode build && ci_output base "" && ci_output legs "{\"include\":[]}"')
same "github: outputs go to GITHUB_OUTPUT, not stdout" "" "$got"
same "github: GITHUB_OUTPUT holds KEY=VALUE lines" $'mode=build\nbase=\nlegs={"include":[]}' "$(cat "$work/output")"
fresh
if fn github "ci_output two \$'a\\nb'" 2>/dev/null; then fail "github: a value of two lines is refused"; else
  check "github: a value of two lines is refused, nothing written" test ! -s "$work/output"
fi
if fn github 'ci_output "bad name" x' 2>/dev/null; then fail "github: an output name with a blank is refused"; else
  ok "github: an output name with a blank is refused"
fi
out=$(on github env -u GITHUB_OUTPUT "$BASH" -c '. "$0"; ci_output a b' "$here/platform.sh" 2>&1) &&
  fail "github: no GITHUB_OUTPUT fails" || same "github: no GITHUB_OUTPUT fails, naming it" \
  "FAIL  GITHUB_OUTPUT is empty: the CI platform sets it for every job" "$out"
fresh
got=$(fn github 'ci_summary "line 1" "line 2"; printf "from stdin\n" | ci_summary; printf "both\n" | ci_summary_tee')
same "github: the summary goes to GITHUB_STEP_SUMMARY, tee to stdout as well" both "$got"
same "github: GITHUB_STEP_SUMMARY holds every line" $'line 1\nline 2\nfrom stdin\nboth' "$(cat "$work/summary")"
check "github: the summary is a page apart from the log" fn github ci_has_summary
same "github: a mask is ::add-mask:: with % written %25" '::add-mask::a%25b%25' "$(fn github 'ci_mask "a%b%"')"
same "github: a warning is an annotation" '::warning::look here' "$(fn github 'ci_warning "look here"')"
same "github: the temp directory is RUNNER_TEMP" "$work/runner-temp" "$(fn github ci_temp_dir)"
same "github: the repository" octo/repo "$(fn github ci_repo)"
same "github: the run id" 4242 "$(fn github ci_run_id)"
same "github: the run's page" https://github.example/octo/repo/actions/runs/4242 "$(fn github ci_run_url)"
same "github: the attempt's page" https://github.example/octo/repo/actions/runs/4242/attempts/3 \
  "$(fn github ci_run_attempt_url)"
same "github: attempt 1 when GITHUB_RUN_ATTEMPT is unset" \
  https://github.example/octo/repo/actions/runs/4242/attempts/1 \
  "$(on github env -u GITHUB_RUN_ATTEMPT "$BASH" -c '. "$0"; ci_run_attempt_url' "$here/platform.sh")"
same "github: the builder is the workflow file at its ref" \
  https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main "$(fn github ci_builder_id)"
same "github: the repository's page" https://github.example/octo/repo "$(fn github ci_repo_url)"
same "github: the ref and the commit of the run" "refs/heads/main 89abcdef0123456789abcdef0123456789abcdef" \
  "$(fn github 'echo "$(ci_ref) $(ci_commit)"')"
same "github: the workflow file and the ref it was read at" ".github/workflows/images.yml refs/heads/main" \
  "$(fn github 'echo "$(ci_workflow_path) $(ci_workflow_ref)"')"
same "github: a ref holding @ stays whole" "a.yml refs/heads/x@y" "$(on github env \
  GITHUB_WORKFLOW_REF=octo/repo/a.yml@refs/heads/x@y "$BASH" -c '. "$0"; echo "$(ci_workflow_path) $(ci_workflow_ref)"' \
  "$here/platform.sh")"
for bad in other/repo/.github/workflows/images.yml@refs/heads/main octo/repo/.github/workflows/images.yml \
  octo/repo/@refs/heads/main octo/repo/a.yml@; do
  if out=$(on github env GITHUB_WORKFLOW_REF="$bad" "$BASH" -c '. "$0"; ci_workflow_path || exit 1; ci_workflow_ref' \
    "$here/platform.sh" 2>&1); then
    fail "github: workflow ref $bad is refused (got '$out')"
  else
    same "github: workflow ref $bad is refused, naming it" \
      "FAIL  GITHUB_WORKFLOW_REF '$bad' is not <repository>/<path>@<ref> of octo/repo" "$out"
  fi
done
jq -n '{inputs: {services: "gateway web", rescan: false}}' >"$work/event.json"
same "github: no dispatch input on a push" "" "$(fn github 'ci_dispatch_input services')"
dispatch() { on github env GITHUB_EVENT_NAME=workflow_dispatch "$BASH" -c ". \"\$0\"; $1" "$here/platform.sh"; }
same "github: a dispatch input, read from the event" "gateway web" "$(dispatch 'ci_dispatch_input services')"
same "github: a dispatch input not given, or false, is empty" "|" \
  "$(dispatch 'echo "$(ci_dispatch_input values_ref)|$(ci_dispatch_input rescan)"')"
if dispatch 'ci_dispatch_input "a b"' 2>/dev/null; then fail "github: an input name with a blank is refused"; else
  ok "github: an input name with a blank is refused"
fi
echo 'not json' >"$work/event.json"
if dispatch 'ci_dispatch_input services' >/dev/null 2>&1; then fail "github: an unreadable event fails"; else
  ok "github: an unreadable event fails"
fi
# The author of a pull request, from the event: the bot of an app, a person; nothing for a push or a dispatch; a pull
# request event without a login, with a login of another shape or unreadable fails, naming the problem.
pr() { on github env GITHUB_EVENT_NAME="$1" "$BASH" -c '. "$0"; ci_change_request_author' "$here/platform.sh"; }
jq -n '{pull_request: {user: {login: "svp-web-promoter[bot]"}}}' >"$work/event.json"
same "github: the author of a pull request, an app's bot, from the event" "svp-web-promoter[bot]" "$(pr pull_request)"
jq -n '{pull_request: {user: {login: "anhnvcoder"}}}' >"$work/event.json"
same "github: the author of a pull request, a person" anhnvcoder "$(pr pull_request)"
same "github: no author on a push or a dispatch" "|" "$(pr push)|$(pr workflow_dispatch)"
for event in '{"pull_request": {}}' '{"pull_request": {"user": {"login": "a b"}}}' '{"pull_request": {"user": {"login": "-x"}}}' \
  '{"pull_request": {"user": {"login": "x[bot][bot]"}}}' 'not json'; do
  printf '%s\n' "$event" >"$work/event.json"
  if out=$(pr pull_request 2>&1); then
    fail "github: a pull request event $event fails (got '$out')"
  else
    case $event in
    'not json') want="FAIL  the pull_request event in $work/event.json cannot be read" ;;
    '{"pull_request": {}}') want="FAIL  the author of the pull request is '', not a login of the host" ;;
    *) want="FAIL  the author of the pull request is '$(jq -r .pull_request.user.login <<<"$event")', not a login of the host" ;;
    esac
    same "github: a pull request event $event fails, naming it" "$want" "$out"
  fi
done
out=$(on github env -u GITHUB_EVENT_PATH GITHUB_EVENT_NAME=pull_request "$BASH" -c '. "$0"; ci_change_request_author' \
  "$here/platform.sh" 2>&1) && fail "github: a pull request without GITHUB_EVENT_PATH fails" ||
  same "github: a pull request without GITHUB_EVENT_PATH fails, naming it" \
    "FAIL  GITHUB_EVENT_PATH is empty: the CI platform sets it for every job" "$out"
same "local: no author unless SVP_CHANGE_REQUEST_AUTHOR names one" "|renovate[bot]" \
  "$(fn local ci_change_request_author)|$(on local env SVP_CHANGE_REQUEST_AUTHOR='renovate[bot]' "$BASH" -c \
    '. "$0"; ci_change_request_author' "$here/platform.sh")"
if on local env SVP_CHANGE_REQUEST_AUTHOR='not a login' "$BASH" -c '. "$0"; ci_change_request_author' \
  "$here/platform.sh" >/dev/null 2>&1; then
  fail "local: an author that is no login fails"
else
  ok "local: an author that is no login fails"
fi
if fn gitlab ci_change_request_author >/dev/null 2>&1; then fail "gitlab: the author of a merge request is not implemented"; else
  ok "gitlab: the author of a merge request is not implemented"
fi
# The sender of the pull request's event (who pushed the commit a synchronize event checks), read the same way.
sender() { on github env GITHUB_EVENT_NAME="$1" "$BASH" -c '. "$0"; ci_change_request_sender' "$here/platform.sh"; }
jq -n '{pull_request: {user: {login: "svp-gitops-promoter[bot]"}}, sender: {login: "svp-web-promoter[bot]"}}' >"$work/event.json"
same "github: the sender of a pull request event, not its author" "svp-web-promoter[bot]|svp-gitops-promoter[bot]" \
  "$(sender pull_request_target)|$(pr pull_request)"
same "github: no sender on a push or a dispatch" "|" "$(sender push)|$(sender workflow_dispatch)"
jq -n '{pull_request: {user: {login: "svp-gitops-promoter[bot]"}}}' >"$work/event.json"
out=$(sender pull_request 2>&1) && fail "github: a pull request event without a sender fails (got '$out')" ||
  same "github: a pull request event without a sender fails, naming it" \
    "FAIL  the sender of the pull request is '', not a login of the host" "$out"
echo 'not json' >"$work/event.json"
out=$(sender pull_request 2>&1) && fail "github: an unreadable event has no sender (got '$out')" ||
  same "github: an unreadable event has no sender, naming it" \
    "FAIL  the pull_request event in $work/event.json cannot be read" "$out"
same "local: no sender unless SVP_CHANGE_REQUEST_SENDER names one" "|anhnvcoder" \
  "$(fn local ci_change_request_sender)|$(on local env SVP_CHANGE_REQUEST_SENDER=anhnvcoder "$BASH" -c \
    '. "$0"; ci_change_request_sender' "$here/platform.sh")"
if on local env SVP_CHANGE_REQUEST_SENDER='a b' "$BASH" -c '. "$0"; ci_change_request_sender' \
  "$here/platform.sh" >/dev/null 2>&1; then
  fail "local: a sender that is no login fails"
else
  ok "local: a sender that is no login fails"
fi
out=$(on github env -u GITHUB_SHA "$BASH" -c '. "$0"; ci_commit' "$here/platform.sh" 2>&1) &&
  fail "github: no GITHUB_SHA fails" || same "github: no GITHUB_SHA fails, naming it" \
  "FAIL  GITHUB_SHA is empty: the CI platform sets it for every job" "$out"
same "github: the bot" 'github-actions[bot] 41898282+github-actions[bot]@users.noreply.github.com' \
  "$(fn github 'echo "$(ci_bot_name) $(ci_bot_email)"')"
fresh
same "github: the bot of an app, its id read from the host" \
  'svp-gitops-promoter[bot] 271828+svp-gitops-promoter[bot]@users.noreply.github.com' \
  "$(fn github 'echo "$(ci_bot_name svp-gitops-promoter) $(ci_bot_email svp-gitops-promoter)"')"
same "github: the bot's user is asked for by its escaped name" \
  "$(gh_line api -X GET 'users/svp-gitops-promoter%5Bbot%5D' --jq .id)" "$(cat "$work/gh.log")"
echo '{"message": "Not Found"}' >"$work/gh/user.json"
if fn github 'ci_bot_email no-such-app' >/dev/null 2>&1; then fail "github: an app with no bot user fails"; else
  ok "github: an app with no bot user fails"
fi
echo '{"id": 271828}' >"$work/gh/user.json"

# The credential helper of a push: git asks it, and it answers with GH_TOKEN of that moment; none without a token.
got=$(on github env GH_TOKEN=s3cret-token "$BASH" -c '. "$0"; ci_git_auth' "$here/platform.sh")
same "github: two git options, the first clearing every other helper" 2 "$(grep -c . <<<"$got")"
check "github: the token is not in the options" test "${got/s3cret-token/}" = "$got"
auth=()
while IFS= read -r o; do auth+=(-c "$o"); done <<<"$got"
same "github: git gets the token from the helper" $'username=x-access-token\npassword=s3cret-token' \
  "$(printf 'protocol=https\nhost=github.com\npath=anhnvcoder/svp-gitops.git\n\n' |
    on github env GH_TOKEN=s3cret-token GIT_TERMINAL_PROMPT=0 git "${auth[@]}" credential fill | grep -E '^(username|password)=')"
if on github env -u GH_TOKEN "$BASH" -c '. "$0"; ci_git_auth' "$here/platform.sh" >/dev/null 2>&1; then
  fail "github: no GH_TOKEN, no credential helper"
else ok "github: no GH_TOKEN, no credential helper"; fi

# Pull requests through gh, with the job's repository.
fresh
fn github 'ci_change_request_write 7 bot/promote main "chore(release): x y" /tmp/body' >/dev/null
same "github: an open pull request is edited" "$(gh_line pr edit 7 --repo octo/repo --title "chore(release): x y" \
  --body-file /tmp/body)" "$(cat "$work/gh.log")"
fresh
fn github 'ci_change_request_write "" bot/promote main "chore(release): x y" /tmp/body' >/dev/null
same "github: no open pull request, one is created" "$(gh_line pr create --repo octo/repo --base main \
  --head bot/promote --title "chore(release): x y" --body-file /tmp/body)" "$(cat "$work/gh.log")"
fresh
got=$(fn github 'ci_change_request_write --dry-run 7 bot/promote main "chore(release): x y" /tmp/body')
same "github: --dry-run prints the command" "dry run: gh $(gh_line pr edit 7 --repo octo/repo --title \
  "chore(release): x y" --body-file /tmp/body)" "$got "
check "github: --dry-run runs no gh" test ! -s "$work/gh.log"
fresh
jq -n '[{number: 3, isCrossRepository: true, author: {login: "app/github-actions"}},
  {number: 4, isCrossRepository: false, author: {login: "someone"}},
  {number: 5, isCrossRepository: false, author: {login: "app/github-actions"}}]' >"$work/gh/prs.json"
same "github: the bot's own pull request is picked, not a fork's or a person's" 5 \
  "$(fn github 'ci_change_request_list bot/promote main | ci_change_request_pick')"
same "github: the list asks gh for up to 500 open pull requests of the branch" "$(gh_line pr list --repo octo/repo \
  --head bot/promote --base main --state open --limit 500 --json number,isCrossRepository,author)" \
  "$(cat "$work/gh.log")"
jq -n '[range(500) | {number: ., isCrossRepository: true, author: {login: "x"}}]' >"$work/gh/prs.json"
if fn github 'ci_change_request_list bot/promote main' >/dev/null 2>&1; then
  fail "github: a full list of 500 fails rather than guess"
else ok "github: a full list of 500 fails rather than guess"; fi
echo '[]' >"$work/gh/prs.json"
same "github: no pull request, nothing picked" "" "$(fn github 'ci_change_request_list bot/promote main |
  ci_change_request_pick')"

# Pull requests of another repository, opened by an app.
fresh
jq -n '[{number: 5, isCrossRepository: false, author: {login: "app/github-actions"}},
  {number: 6, isCrossRepository: true, author: {login: "app/svp-gitops-promoter"}},
  {number: 7, isCrossRepository: false, author: {login: "app/svp-gitops-promoter"}}]' >"$work/gh/prs.json"
same "github: the app's own pull request of the other repository is picked" 7 \
  "$(fn github 'ci_change_request_list bot/promote-stg main anhnvcoder/svp-gitops | ci_change_request_pick svp-gitops-promoter')"
same "github: the list asks for the other repository" "$(gh_line pr list --repo anhnvcoder/svp-gitops \
  --head bot/promote-stg --base main --state open --limit 500 --json number,isCrossRepository,author)" \
  "$(cat "$work/gh.log")"
echo '[]' >"$work/gh/prs.json"
fresh
fn github 'ci_change_request_write "" bot/promote-stg main "chore(stg): x" /tmp/body anhnvcoder/svp-gitops' >/dev/null
same "github: a pull request opened in the other repository" "$(gh_line pr create --repo anhnvcoder/svp-gitops \
  --base main --head bot/promote-stg --title "chore(stg): x" --body-file /tmp/body)" "$(cat "$work/gh.log")"
fresh
fn github "ci_change_request_auto_merge 7 $(printf 'a%.0s' $(seq 40)) anhnvcoder/svp-gitops" >/dev/null
same "github: auto-merge, squashed, only while the head is that commit" "$(gh_line pr merge 7 \
  --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$(printf 'a%.0s' $(seq 40))")" "$(cat "$work/gh.log")"
fresh
got=$(fn github "ci_change_request_auto_merge --dry-run bot/promote-stg $(printf 'b%.0s' $(seq 40)) anhnvcoder/svp-gitops")
same "github: auto-merge --dry-run prints the command" "dry run: gh $(gh_line pr merge bot/promote-stg \
  --repo anhnvcoder/svp-gitops --auto --squash --match-head-commit "$(printf 'b%.0s' $(seq 40))")" "$got "
check "github: auto-merge --dry-run runs no gh" test ! -s "$work/gh.log"
if fn github 'ci_change_request_auto_merge 7 main anhnvcoder/svp-gitops' >/dev/null 2>&1; then
  fail "github: auto-merge takes only a full commit as the head"
else ok "github: auto-merge takes only a full commit as the head"; fi

# --- local: stdout, nothing masked, no write through the API.
fresh
same "local: outputs on stdout" $'mode=build\nbase=' "$(fn local 'ci_output mode build; ci_output base ""')"
same "local: the summary on stdout" $'a\nb' "$(fn local 'ci_summary a; echo b | ci_summary')"
if fn local ci_has_summary; then fail "local: no summary page apart from the log"; else
  ok "local: no summary page apart from the log"
fi
same "local: tee prints once" x "$(fn local 'echo x | ci_summary_tee')"
same "local: a mask prints nothing (it would print the value)" "" "$(fn local 'ci_mask "s3cret-value"')"
same "local: a warning is a plain line" 'warning: look here' "$(fn local 'ci_warning "look here"')"
same "local: the temp directory is /tmp" /tmp "$(fn local ci_temp_dir)"
same "local: this repository" anhnvcoder/short-video-platform "$(fn local ci_repo)"
same "local: links are local" "local local local local" \
  "$(fn local 'echo "$(ci_run_id) $(ci_run_url) $(ci_run_attempt_url) $(ci_builder_id)"')"
same "local: the repository's page on GitHub" https://github.com/anhnvcoder/short-video-platform \
  "$(fn local ci_repo_url)"
same "local: the ref, the workflow file and its ref are local, no dispatch input" "local local local " \
  "$(fn local 'echo "$(ci_ref) $(ci_workflow_path) $(ci_workflow_ref) $(ci_dispatch_input services)"')"
same "local: the commit is HEAD of the checkout platform.sh is in" "$(git -C "$here" rev-parse --verify HEAD)" \
  "$(fn local ci_commit)"
check "local: no file of a job was written" test ! -s "$work/output" -a ! -s "$work/summary"

# A checkout of svp-web, another release source's repository, whose CI runs these scripts from a pinned checkout of
# this one: SVP_CODE_ROOT names it, and on a machine the repository and commit of the run are its own.
webtree=$work/svp-web
mkdir -p "$webtree"
printf 'vulnerabilities: []\n' >"$webtree/.trivyignore.yaml"
gw() {
  GIT_DIR=$webtree/.git GIT_WORK_TREE=$webtree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
gw init -q -b main && gw add -A && gw commit -qm web
gw remote add origin https://github.com/anhnvcoder/svp-web.git
web_head=$(gw rev-parse HEAD)
same "local, SVP_CODE_ROOT: the repository, its page and the commit are the checkout's" \
  "anhnvcoder/svp-web https://github.com/anhnvcoder/svp-web $web_head" \
  "$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; echo "$(ci_repo) $(ci_repo_url) $(ci_commit)"' \
    "$here/platform.sh")"
gw remote set-url origin git@github.com:anhnvcoder/svp-web.git
same "local, SVP_CODE_ROOT: an ssh origin names the same repository" anhnvcoder/svp-web \
  "$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo' "$here/platform.sh")"
gw remote set-url origin https://gitlab.example/anhnvcoder/svp-web.git
if out=$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo_url' "$here/platform.sh" 2>&1); then
  fail "local, SVP_CODE_ROOT: an origin off github.com is refused (got '$out')"
else
  same "local, SVP_CODE_ROOT: an origin off github.com is refused, naming it" \
    "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://gitlab.example/anhnvcoder/svp-web.git'): its repository cannot be named" \
    "$out"
fi
gw remote set-url origin https://x-access-token:ghs_faketoken0123456789@github.com/anhnvcoder/svp-web.git
if out=$(on local env SVP_CODE_ROOT="$webtree" "$BASH" -c '. "$0"; ci_repo' "$here/platform.sh" 2>&1); then
  fail "local, SVP_CODE_ROOT: an origin carrying a credential is refused (got '$out')"
else
  same "local, SVP_CODE_ROOT: an origin carrying a credential is refused, the credential not shown" \
    "FAIL  SVP_CODE_ROOT=$webtree has no remote origin on github.com (got 'https://github.com/anhnvcoder/svp-web.git'): its repository cannot be named" \
    "$out"
fi
gw remote set-url origin https://github.com/anhnvcoder/svp-web.git
got=$(fn local 'ci_change_request_write "" bot/promote main "chore(release): x" /tmp/body')
same "local: a pull request is printed, not written" "dry run: gh $(gh_line pr create \
  --repo anhnvcoder/short-video-platform --base main --head bot/promote --title "chore(release): x" \
  --body-file /tmp/body)" "$got "
check "local: gh is not called to write" test ! -s "$work/gh.log"
got=$(fn local "ci_change_request_auto_merge 7 $(printf 'a%.0s' $(seq 40)) anhnvcoder/svp-gitops")
same "local: auto-merge is printed, not turned on" "dry run: gh $(gh_line pr merge 7 --repo anhnvcoder/svp-gitops \
  --auto --squash --match-head-commit "$(printf 'a%.0s' $(seq 40))")" "$got "
check "local: gh is not called for auto-merge" test ! -s "$work/gh.log"
same "local: no credential helper" "" "$(fn local ci_git_auth)"
same "local: the dispatch hint names the code repository" \
  "gh workflow run images.yml --repo anhnvcoder/short-video-platform --ref main -f rescan=true -f values_ref=abc" \
  "$(fn local 'ci_dispatch_hint images.yml main rescan=true values_ref=abc')"
same "github: the dispatch hint names the code repository, not the job's" \
  "gh workflow run images.yml --repo anhnvcoder/short-video-platform --ref main" \
  "$(fn github 'ci_dispatch_hint images.yml main')"
sha=0123456789abcdef0123456789abcdef01234567
jq -n --arg sha "$sha" '[{type: "PushEvent", payload: {head: "ffff"}, created_at: "2026-10-01T00:00:00Z"},
  {type: "PushEvent", payload: {head: $sha}, created_at: "2026-10-02T03:04:05Z"},
  {type: "PullRequestEvent", payload: {head: $sha}, created_at: "2026-10-03T00:00:00Z"}]' >"$work/gh/events.json"
pulls_filter="[.[] | select(.merge_commit_sha == \"$sha\" and .merged_at != null)] | first // empty
        | \"\(.merged_at) merged_at of PR #\(.number)\""
events_filter="[.[] | select(.type == \"PushEvent\" and .payload.head == \"$sha\") | .created_at] | last // empty
          | \"\(.) PushEvent of the repository's events\""
same "local: no pull request of the commit, the push time is read from the host's events" \
  "2026-10-02T03:04:05Z PushEvent of the repository's events" "$(fn local "ci_push_time $sha")"
same "local: the pull requests, then the events, are read for this repository" "$(gh_line api -X GET \
  repos/anhnvcoder/short-video-platform/commits/$sha/pulls -f per_page=100 --jq "$pulls_filter")
$(gh_line api -X GET repos/anhnvcoder/short-video-platform/events -f per_page=100 --jq "$events_filter")" \
  "$(cat "$work/gh.log")"
# A pull request merged as the commit gives its merged_at, and the events are not read; one merged as another commit,
# or not merged, is skipped.
jq -n --arg sha "$sha" '[{number: 7, merge_commit_sha: "eeee", merged_at: "2026-10-04T00:00:00Z"},
  {number: 8, merge_commit_sha: $sha, merged_at: null},
  {number: 9, merge_commit_sha: $sha, merged_at: "2026-10-02T03:00:00Z"}]' >"$work/gh/pulls.json"
fresh
same "github: a pull request merged as the commit gives its merged_at" "2026-10-02T03:00:00Z merged_at of PR #9" \
  "$(fn github "ci_push_time $sha")"
check "github: the events are not read when the pull request answers" test "$(wc -l <"$work/gh.log")" -eq 1
jq -n --arg sha "$sha" '[{number: 7, merge_commit_sha: "eeee", merged_at: "2026-10-04T00:00:00Z"},
  {number: 8, merge_commit_sha: $sha, merged_at: null}]' >"$work/gh/pulls.json"
same "github: pull requests merged as another commit or not merged are skipped, the events answer" \
  "2026-10-02T03:04:05Z PushEvent of the repository's events" "$(fn github "ci_push_time $sha")"
rm "$work/gh/pulls.json"
fresh
if got=$(fn local "export FAKE_GH_FAIL=1; ci_push_time $sha" 2>/dev/null); then
  fail "local: a host error is not an answer ($got)"
else
  ok "local: a host error is not an answer"
fi
check "local: a failed read of the pull requests is not answered from the events" test "$(wc -l <"$work/gh.log")" -eq 1
if fn local 'ci_push_time "x\" or true"' 2>/dev/null; then fail "local: ci_push_time takes only a full SHA"; else
  ok "local: ci_push_time takes only a full SHA"
fi
fresh
same "local: the push time of a commit of another repository" \
  "2026-10-02T03:04:05Z PushEvent of the repository's events" "$(fn local "ci_push_time $sha anhnvcoder/svp-gitops")"
same "local: the pull requests, then the events, are read for that repository" "$(gh_line api -X GET \
  repos/anhnvcoder/svp-gitops/commits/$sha/pulls -f per_page=100 --jq "$pulls_filter")
$(gh_line api -X GET repos/anhnvcoder/svp-gitops/events -f per_page=100 --jq "$events_filter")" \
  "$(cat "$work/gh.log")"
if fn local "ci_push_time $sha 'a b/c'" 2>/dev/null; then fail "local: ci_push_time takes a repository as owner/name"; else
  ok "local: ci_push_time takes a repository as owner/name"
fi

# --- ci_hosted_runner: true only on a runner GitHub hands out for the job; silent either way.
check "github: a github-hosted runner is a hosted runner" on github env RUNNER_ENVIRONMENT=github-hosted "$BASH" -c \
  '. "$0"; ci_hosted_runner' "$here/platform.sh"
same "github: a hosted runner prints nothing" "" "$(on github env RUNNER_ENVIRONMENT=github-hosted "$BASH" -c \
  '. "$0"; ci_hosted_runner' "$here/platform.sh" 2>&1)"
for runner in self-hosted ""; do
  rc=0
  out=$(on github env RUNNER_ENVIRONMENT="$runner" "$BASH" -c '. "$0"; ci_hosted_runner' "$here/platform.sh" 2>&1) ||
    rc=$?
  same "github: RUNNER_ENVIRONMENT='$runner' is no hosted runner, silently" "1 " "$rc $out"
done
rc=0
out=$(fn github ci_hosted_runner 2>&1) || rc=$?
same "github: no RUNNER_ENVIRONMENT is no hosted runner, silently" "1 " "$rc $out"
rc=0
out=$(on local env RUNNER_ENVIRONMENT=github-hosted "$BASH" -c '. "$0"; ci_hosted_runner' "$here/platform.sh" 2>&1) ||
  rc=$?
same "local: a machine is no hosted runner, whatever RUNNER_ENVIRONMENT says, silently" "1 " "$rc $out"
rc=0
out=$(on gitlab env RUNNER_ENVIRONMENT=github-hosted "$BASH" -c '. "$0"; ci_hosted_runner' "$here/platform.sh" 2>&1) ||
  rc=$?
case "$rc $out" in "1 FAIL  this runs on GitLab CI"*) ok "gitlab: ci_hosted_runner fails, naming GitLab CI" ;;
*) fail "gitlab: ci_hosted_runner fails, naming GitLab CI (got '$rc $out')" ;; esac

# --- ci_artifact_runs, ci_artifact_fetch. Runs of images.yml: two builds of the commit that hold the artifact (a push,
# then a dispatch that built it again, started later), a red run that still released it, and runs that must not be
# listed: a pull request's, one still running, one whose artifact expired, the latest one with no such artifact (and
# another artifact), and a run of another commit.
other=fedcba9876543210fedcba9876543210fedcba98
jq -n --arg sha "$sha" --arg other "$other" '[
  {id: 101, head_sha: $sha, event: "push", status: "completed", conclusion: "success",
    run_started_at: "2026-10-01T00:00:00Z"},
  {id: 102, head_sha: $sha, event: "workflow_dispatch", status: "completed", conclusion: "success",
    run_started_at: "2026-10-03T00:00:00Z"},
  {id: 103, head_sha: $sha, event: "push", status: "completed", conclusion: "failure",
    run_started_at: "2026-10-02T00:00:00Z"},
  {id: 104, head_sha: $sha, event: "pull_request", status: "completed", conclusion: "success",
    run_started_at: "2026-10-04T00:00:00Z"},
  {id: 105, head_sha: $sha, event: "push", status: "in_progress", conclusion: null,
    run_started_at: "2026-10-05T00:00:00Z"},
  {id: 106, head_sha: $sha, event: "push", status: "completed", conclusion: "success",
    run_started_at: "2026-10-06T00:00:00Z"},
  {id: 107, head_sha: $sha, event: "workflow_dispatch", status: "completed", conclusion: "failure",
    run_started_at: "2026-10-07T00:00:00Z"},
  {id: 108, head_sha: $other, event: "push", status: "completed", conclusion: "success",
    run_started_at: "2026-10-08T00:00:00Z"}
] | {total_count: length, workflow_runs: .}' >"$work/gh/runs.json"
for id in 101 102 103 104 105 108; do
  jq -n '{total_count: 1, artifacts: [{name: "web-sourcemaps-amd64", expired: false}]}' >"$work/gh/artifacts-$id.json"
done
jq -n '{total_count: 1, artifacts: [{name: "web-sourcemaps-amd64", expired: true}]}' >"$work/gh/artifacts-106.json"
jq -n '{total_count: 1, artifacts: [{name: "release-web", expired: false}]}' >"$work/gh/artifacts-107.json"
runs_jq="\"\\(.total_count) \\(.workflow_runs | length)\", (.workflow_runs
        | map(select(.head_sha == \"$sha\" and .status == \"completed\"
          and (.event == \"push\" or .event == \"workflow_dispatch\")))
        | sort_by(.run_started_at, .id) | reverse | .[].id)"
for p in github local; do
  [ $p = github ] && repo=octo/repo || repo=anhnvcoder/short-video-platform
  fresh
  rc=0
  got=$(fn $p "ci_artifact_runs images.yml $sha web-sourcemaps-amd64") || rc=$?
  same "$p: ci_artifact_runs lists every finished push or dispatch build holding the artifact, latest started first" \
    "0 102 103 101" "$rc $(echo $got)"
  same "$p: ci_artifact_runs asks for the workflow's finished runs of the commit in the repository" "$(gh_line api \
    -X GET "repos/$repo/actions/workflows/images.yml/runs" -f head_sha=$sha -f status=completed -f per_page=100 \
    --jq "$runs_jq")" "$(head -n 1 "$work/gh.log")"
  check "$p: ci_artifact_runs asks a candidate run for its artifact" has "$work/gh.log" "$(gh_line api -X GET \
    "repos/$repo/actions/runs/102/artifacts" -f name=web-sourcemaps-amd64 -f per_page=100 --jq \
    '[.artifacts[] | select(.name == "web-sourcemaps-amd64" and .expired == false)] | length')"
  same "$p: ci_artifact_runs asks only the five finished push or dispatch runs of the commit for artifacts" \
    "107 106 102 103 101" "$(sed -n 's|.*/actions/runs/\([0-9]*\)/artifacts .*|\1|p' "$work/gh.log" | tr '\n' ' ' |
      sed 's/ $//')"
done
rc=0
got=$(fn local "ci_artifact_runs images.yml $sha web-sourcemaps-arm64" 2>&1) || rc=$?
same "local: ci_artifact_runs exits 3, silently, when no run holds the artifact" "3 " "$rc $got"
rc=0
got=$(fn local "ci_artifact_runs images.yml 1111111111111111111111111111111111111111 web-sourcemaps-amd64" 2>&1) ||
  rc=$?
same "local: ci_artifact_runs exits 3 for a commit with no run" "3 " "$rc $got"
for args in "images.yml ${sha:0:12} web-sourcemaps-amd64" "images.yml $(tr a-f A-F <<<"$sha") web-sourcemaps-amd64" \
  "'images.yml\" or true' $sha web-sourcemaps-amd64" "images.yml $sha 'web\") or true'" "images.yml $sha ''" \
  "images.yml $sha"; do
  fresh
  rc=0
  fn local "ci_artifact_runs $args" >/dev/null 2>"$work/err" || rc=$?
  same "local: ci_artifact_runs $args is refused before gh is called" "1 0" "$rc $(wc -l <"$work/gh.log" | tr -d ' ')"
done
rc=0
fn local "export FAKE_GH_FAIL=1; ci_artifact_runs images.yml $sha web-sourcemaps-amd64" >/dev/null 2>"$work/err" ||
  rc=$?
same "local: ci_artifact_runs exits 1 when the host fails" 1 "$rc"
check "local: ci_artifact_runs shows the host's error" has "$work/err" "HTTP 502: Bad Gateway"
jq '.total_count = 101' "$work/gh/runs.json" >"$work/gh/runs-more.json" &&
  mv "$work/gh/runs-more.json" "$work/gh/runs.json"
rc=0
got=$(fn local "ci_artifact_runs images.yml $sha web-sourcemaps-amd64" 2>"$work/err") || rc=$?
same "local: ci_artifact_runs fails, listing nothing, when the host has more runs than one page" "1 " "$rc $got"
check "local: ci_artifact_runs says a page is missing" has "$work/err" \
  "FAIL  the host has 101 finished runs of images.yml at $sha but returned 8: read the next page"
rc=0
fn gitlab "ci_artifact_runs images.yml $sha web-sourcemaps-amd64" >/dev/null 2>"$work/err" || rc=$?
same "gitlab: ci_artifact_runs fails" 1 "$rc"
check "gitlab: ci_artifact_runs names GitLab CI" has "$work/err" "this runs on GitLab CI"

for p in github local; do
  [ $p = github ] && repo=octo/repo || repo=anhnvcoder/short-video-platform
  fresh
  rm -rf "$work/fetch" && mkdir "$work/fetch"
  rc=0
  fn $p "ci_artifact_fetch 102 web-sourcemaps-amd64 '$work/fetch'" >/dev/null || rc=$?
  same "$p: ci_artifact_fetch downloads the run's artifact into the directory" "0 sha256:fetched" \
    "$rc $(cat "$work/fetch/image-digest" 2>/dev/null)"
  same "$p: ci_artifact_fetch checks the artifact, then downloads it by name from the repository" "$(gh_line api \
    -X GET "repos/$repo/actions/runs/102/artifacts" -f name=web-sourcemaps-amd64 -f per_page=100 --jq \
    '[.artifacts[] | select(.name == "web-sourcemaps-amd64" and .expired == false)] | length')"$'\n'"$(gh_line run \
    download 102 --repo "$repo" --name web-sourcemaps-amd64 --dir "$work/fetch")" "$(cat "$work/gh.log")"
done
for run in 106 107 999; do
  fresh
  rm -rf "$work/fetch" && mkdir "$work/fetch"
  rc=0
  got=$(fn local "ci_artifact_fetch $run web-sourcemaps-amd64 '$work/fetch'" 2>&1) || rc=$?
  same "local: ci_artifact_fetch exits 3, silently, for run $run (artifact expired, absent, no run)" "3 " "$rc $got"
  check "local: ci_artifact_fetch downloads nothing from run $run" lacks "$work/gh.log" "run download"
done
rm -rf "$work/fetch" && mkdir "$work/fetch"
echo old >"$work/fetch/.left-over"
fresh
rc=0
fn local "ci_artifact_fetch 102 web-sourcemaps-amd64 '$work/fetch'" >/dev/null 2>"$work/err" || rc=$?
same "local: ci_artifact_fetch refuses a directory that is not empty" "1 0" "$rc $(wc -l <"$work/gh.log" | tr -d ' ')"
check "local: ci_artifact_fetch names the directory that is not empty" has "$work/err" \
  "FAIL  $work/fetch is not an empty directory"
same "local: ci_artifact_fetch leaves that directory as it was" .left-over "$(ls -A "$work/fetch")"
for args in "102 web-sourcemaps-amd64 '$work/no-such-dir'" \
  "'102 or true' web-sourcemaps-amd64 '$work/empty'" "-1 web-sourcemaps-amd64 '$work/empty'" \
  "102 'web\") or true' '$work/empty'" "102 web-sourcemaps-amd64"; do
  fresh
  rm -rf "$work/empty" && mkdir "$work/empty"
  rc=0
  fn local "ci_artifact_fetch $args" >/dev/null 2>"$work/err" || rc=$?
  same "local: ci_artifact_fetch $args is refused before gh is called" "1 0" "$rc $(wc -l <"$work/gh.log" | tr -d ' ')"
done
rm -rf "$work/empty" && mkdir "$work/empty"
rc=0
fn local "export FAKE_GH_FAIL=1; ci_artifact_fetch 102 web-sourcemaps-amd64 '$work/empty'" >/dev/null 2>"$work/err" ||
  rc=$?
same "local: ci_artifact_fetch exits 1 when the host fails" 1 "$rc"
check "local: ci_artifact_fetch shows the host's error" has "$work/err" "HTTP 502: Bad Gateway"
for p in github local; do
  rm -rf "$work/empty" && mkdir "$work/empty"
  rc=0
  fn $p "export FAKE_GH_DOWNLOAD_FAIL=1 GH_DEBUG=api DEBUG=1
    ci_artifact_fetch 102 web-sourcemaps-amd64 '$work/empty'" >"$work/out" 2>"$work/err" || rc=$?
  same "$p: ci_artifact_fetch exits 1 when the download fails" 1 "$rc"
  same "$p: ci_artifact_fetch shows gh's error with each link cut to its scheme and host, and no debug log" \
    "error downloading web-sourcemaps-amd64: HTTP 403: Server failed to authenticate the request. \
(https://results.blob.example/<hidden>
error downloading web-sourcemaps-amd64: Get \"https://results.blob.example/<hidden>\": dial tcp: lookup \
results.blob.example: no such host" "$(cat "$work/err")"
  same "$p: ci_artifact_fetch prints nothing on stdout when the download fails" "" "$(cat "$work/out")"
  check "$p: ci_artifact_fetch never prints the signed part of the link" lacks "$work/err" SIGNEDQUERY
done

# --- ci_is_run_url, ci_run_workflow, ci_deployment_record, ci_deployment_list: the records of an environment in
# svp-gitops and the runs they name.
check "github: a run of the code repository is a run URL" fn github \
  'ci_is_run_url https://github.com/anhnvcoder/short-video-platform/actions/runs/4242'
for bad in https://github.com/someone/fork/actions/runs/4242 https://github.com/anhnvcoder/short-video-platform/actions/runs/x \
  "https://github.com/anhnvcoder/short-video-platform/actions/runs/4242/attempts/1" ""; do
  if fn local "ci_is_run_url '$bad'"; then fail "local: '$bad' is no run URL"; else ok "local: '$bad' is no run URL"; fi
done
echo '{"id": 4242, "path": ".github/workflows/verify.yml", "head_branch": "main", "event": "schedule"}' >"$work/gh/run-4242.json"
for p in github local; do
  fresh
  same "$p: ci_run_workflow prints the workflow file and the branch of a run" ".github/workflows/verify.yml main" \
    "$(fn "$p" 'ci_run_workflow https://github.com/anhnvcoder/short-video-platform/actions/runs/4242')"
  check "$p: ci_run_workflow asks the host for the run of the code repository" grep -qF -- \
    "$(gh_line api -X GET repos/anhnvcoder/short-video-platform/actions/runs/4242)" "$work/gh.log"
  if fn "$p" 'ci_run_workflow https://github.com/anhnvcoder/short-video-platform/actions/runs/4243' >/dev/null 2>&1; then
    fail "$p: ci_run_workflow fails when the host knows no such run"
  else
    ok "$p: ci_run_workflow fails when the host knows no such run"
  fi
  fresh
  if fn "$p" 'ci_run_workflow https://github.com/someone/fork/actions/runs/4242' >/dev/null 2>&1; then
    fail "$p: ci_run_workflow refuses a run of another repository"
  else
    ok "$p: ci_run_workflow refuses a run of another repository"
  fi
  check "$p: a refused run URL calls no gh" test ! -s "$work/gh.log"
done
rev=$(printf 'c%.0s' $(seq 40))
echo '{"environment": "stg", "ref": "'"$rev"'", "images": {}}' >"$work/payload.json"
fresh
: >"$work/gh/inputs.jsonl"
same "github: ci_deployment_record prints the id of the record" 9001 "$(fn github "ci_deployment_record anhnvcoder/svp-gitops stg $rev '$work/payload.json' 'stg checked' https://github.com/anhnvcoder/short-video-platform/actions/runs/4242")"
same "github: a deployment, then its status" \
  "$(gh_line api -X POST repos/anhnvcoder/svp-gitops/deployments --input - --jq .id)"$'\n'"$(gh_line api -X POST repos/anhnvcoder/svp-gitops/deployments/9001/statuses --input - --jq .state)" \
  "$(cat "$work/gh.log")"
same "github: the deployment: ref, environment, payload, no auto-merge, no required contexts" \
  "$rev stg stg false [] false" \
  "$(sed -n 1p "$work/gh/inputs.jsonl" | jq -r '"\(.ref) \(.environment) \(.payload.environment) \(.auto_merge) \(.required_contexts | tojson) \(.transient_environment)"')"
same "github: the status: success, the run as its log, earlier records left active" \
  "success https://github.com/anhnvcoder/short-video-platform/actions/runs/4242 false" \
  "$(sed -n 2p "$work/gh/inputs.jsonl" | jq -r '"\(.state) \(.log_url) \(.auto_inactive)"')"
fresh
got=$(fn github "ci_deployment_record --dry-run anhnvcoder/svp-gitops stg $rev '$work/payload.json' 'stg checked' https://example.invalid/run")
check "github: ci_deployment_record --dry-run runs no gh" test ! -s "$work/gh.log"
check "github: ci_deployment_record --dry-run prints the deployment" grep -qF \
  'dry run: gh api -X POST repos/anhnvcoder/svp-gitops/deployments --input -' <<<"$got"
check "github: ci_deployment_record --dry-run prints the body" grep -qF '"auto_merge":false,"required_contexts":[]' <<<"$got"
got=$(fn local "ci_deployment_record anhnvcoder/svp-gitops stg $rev '$work/payload.json' 'stg checked' https://example.invalid/run")
check "local: ci_deployment_record writes nothing" test ! -s "$work/gh.log"
check "local: ci_deployment_record prints the status it would write" grep -qF '"state":"success"' <<<"$got"
for args in "anhnvcoder/svp-gitops stg main '$work/payload.json' d https://example.invalid/run" \
  "anhnvcoder/svp-gitops 'st g' $rev '$work/payload.json' d https://example.invalid/run" \
  "anhnvcoder/svp-gitops stg $rev '$work/gh.log' d https://example.invalid/run"; do
  if fn github "ci_deployment_record $args" >/dev/null 2>&1; then fail "github: ci_deployment_record refuses $args"; else
    ok "github: ci_deployment_record refuses $args"
  fi
done
check "github: a refused record calls no gh" test ! -s "$work/gh.log"
echo '[{"id": 12, "sha": "'"$rev"'", "ref": "'"$rev"'", "created_at": "2026-10-30T02:00:00Z", "creator": {"login": "svp-gitops-promoter[bot]"}, "payload": {"environment": "stg"}},
  {"id": 11, "sha": "'"$rev"'", "ref": "'"$rev"'", "created_at": "2026-10-30T01:00:00Z", "creator": {"login": "someone"}, "payload": "text"}]' \
  >"$work/gh/deployments.json"
echo '[{"state": "success"}, {"state": "in_progress"}]' >"$work/gh/statuses-12.json"
fresh
same "github: ci_deployment_list: each record with its latest state, newest first" \
  '12 svp-gitops-promoter[bot] success stg|11 someone  text' \
  "$(fn github 'ci_deployment_list anhnvcoder/svp-gitops stg' | jq -r 'map("\(.id) \(.creator) \(.state) \(.payload.environment? // .payload)") | join("|")')"
check "github: ci_deployment_list asks for the environment" grep -qF -- "$(gh_line api -X GET repos/anhnvcoder/svp-gitops/deployments -f environment=stg -f per_page=100)" "$work/gh.log"
same "github: ci_deployment_list: every status of each record, newest first" '12 success,in_progress|11 ' \
  "$(fn github 'ci_deployment_list anhnvcoder/svp-gitops stg' | jq -r 'map("\(.id) \(.states | join(","))") | join("|")')"
check "github: ci_deployment_list reads every status of a record" grep -qF -- \
  "$(gh_line api -X GET repos/anhnvcoder/svp-gitops/deployments/12/statuses -f per_page=100)" "$work/gh.log"
if on github env FAKE_GH_FAIL=1 "$BASH" -c '. "$0"; ci_deployment_list anhnvcoder/svp-gitops stg' "$here/platform.sh" \
  >/dev/null 2>&1; then
  fail "github: ci_deployment_list fails when the host does"
else
  ok "github: ci_deployment_list fails when the host does"
fi

# --- another CI: a clear error, nothing written.
fresh
if out=$(fn gitlab 'ci_output mode build; ci_summary x; ci_mask y' 2>&1); then
  fail "gitlab: every function fails"
else
  case $out in *"this runs on GitLab CI"*) ok "gitlab: every function fails, naming GitLab CI" ;;
  *) fail "gitlab: every function fails, naming GitLab CI (got '$out')" ;; esac
fi
if grep -qv '^FAIL  ' <<<"$out"; then fail "gitlab: nothing printed but the errors"; else
  ok "gitlab: nothing printed but the errors"
fi

# --- A throwaway checkout, with its own origin, of what the scripts below read: deploy/ci/, deploy/k8s/lib.sh, the
# policy's values, a chart file and a symbolic link of a chart to a file beside the charts. GIT_DIR is set for every git
# call of the test itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s" "$tree/deploy/helm/svp-policy" "$tree/deploy/helm/svp-observability/files" \
  "$tree/deploy/observability/otelcol" "$tree/docs"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp -R "$src/deploy/helm/svp-policy/values.yaml" "$src/deploy/helm/svp-policy/files" "$tree/deploy/helm/svp-policy/"
echo "receivers: {}" >"$tree/deploy/observability/otelcol/k8s-config.yaml"
ln -s ../../../observability/otelcol/k8s-config.yaml "$tree/deploy/helm/svp-observability/files/otelcol-k8s-config.yaml"
echo "# A decision" >"$tree/docs/decision.md"
g() {
  GIT_DIR=$tree/.git GIT_WORK_TREE=$tree GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
g init -q -b main && g add -A && g commit -qm base
git init -q --bare "$work/origin.git"
g remote add origin "$work/origin.git" && g push -q origin main
base=$(g rev-parse HEAD)
digest_a=sha256:$(printf 'a%.0s' $(seq 64))
digest_b=sha256:$(printf 'b%.0s' $(seq 64))

# plan.sh: a drill run on main hands its seven outputs on, in this order, and writes its summary.
want_plan='mode=drill
images=["drill-vulnerable","drill-unsigned"]
legs={"include":[{"image":"drill-vulnerable","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-vulnerable","arch":"arm64","runner":"ubuntu-24.04-arm"},{"image":"drill-unsigned","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-unsigned","arch":"arm64","runner":"ubuntu-24.04-arm"}]}
has_images=true
base=
promote_charts=false
values_ref='
fresh
backend_run=(GITHUB_REPOSITORY=anhnvcoder/short-video-platform GITHUB_SERVER_URL=https://github.com)
got=$(on github env "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main \
  INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on github: nothing on stdout" "" "$got"
same "plan.sh on github: the seven outputs in GITHUB_OUTPUT" "$want_plan" "$(cat "$work/output")"
same "plan.sh on github: the summary" "Mode: drill. Images: drill-vulnerable drill-unsigned." "$(cat "$work/summary")"
got=$(on local env EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on a machine: summary then outputs on stdout" \
  "Mode: drill. Images: drill-vulnerable drill-unsigned."$'\n'"$want_plan" "$got"

# plan.sh of svp-web's run (SVP_CODE_ROOT its checkout, HEAD the run's commit): the services of its release source at
# every run, no base, nothing to promote of the charts.
# web_plan NAME WANT_RC VAR=VALUE...: plan.sh in a made-up run of svp-web on github, its outputs in output.
web_plan() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on github env GITHUB_REPOSITORY=anhnvcoder/svp-web GITHUB_SERVER_URL=https://github.com GITHUB_SHA="$web_head" \
    SVP_CODE_ROOT="$webtree" GIT_REF=refs/heads/main "$@" "$tree/deploy/ci/plan.sh" >/dev/null 2>"$work/plan.err" ||
    rc=$?
  same "plan.sh of svp-web: $name (exit $want)" "$want" "$rc"
}
web_plan "a push to main" 0 EVENT_NAME=push
same "plan.sh of svp-web: a push to main builds web on both architectures, no base" 'mode=build
images=["web"]
legs={"include":[{"image":"web","arch":"amd64","runner":"ubuntu-24.04"},{"image":"web","arch":"arm64","runner":"ubuntu-24.04-arm"}]}
has_images=true
base=
promote_charts=false
values_ref=' "$(cat "$work/output")"
web_plan "a pull request" 0 EVENT_NAME=pull_request PR_BASE_REF=main GIT_REF=refs/pull/7/merge
same "plan.sh of svp-web: a pull request builds web" 'images=["web"]' "$(grep '^images=' "$work/output")"
web_plan "a dispatch with services web" 0 EVENT_NAME=workflow_dispatch INPUT_SERVICES=web
same "plan.sh of svp-web: services web builds web" 'images=["web"]' "$(grep '^images=' "$work/output")"
web_plan "a dispatch with services gateway" 1 EVENT_NAME=workflow_dispatch INPUT_SERVICES=gateway
check "plan.sh of svp-web: services gateway is refused, naming what the source publishes" has "$work/plan.err" \
  "services: 'gateway' is not an image of release source web (web)"
web_plan "a drill" 1 EVENT_NAME=workflow_dispatch INPUT_DRILL=true
check "plan.sh of svp-web: a drill is refused" has "$work/plan.err" "release source web has no drill image to build"
web_plan "a rescan" 0 EVENT_NAME=schedule
same "plan.sh of svp-web: a rescan builds nothing" 'mode=rescan has_images=false' \
  "$(grep '^mode=' "$work/output") $(grep '^has_images=' "$work/output")"
web_plan "a tree at another commit than the run's" 1 EVENT_NAME=push GITHUB_SHA="$base"
check "plan.sh of svp-web: a tree at another commit: names SVP_CODE_ROOT" has "$work/plan.err" \
  "HEAD of $webtree is $web_head, but this run builds $base of https://github.com/anhnvcoder/svp-web: set SVP_CODE_ROOT"
# A job of svp-web that forgot SVP_CODE_ROOT: this checkout is not the run's commit, so plan.sh stops before it plans
# from this checkout's diff; a run of a repository that is no release source (a fork) stops too.
plan_own() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on github env GITHUB_SERVER_URL=https://github.com GIT_REF=refs/heads/main EVENT_NAME=push "$@" \
    "$tree/deploy/ci/plan.sh" >/dev/null 2>"$work/plan.err" || rc=$?
  same "plan.sh in this checkout: $name (exit $want)" "$want" "$rc"
}
plan_own "a run of svp-web without SVP_CODE_ROOT" 1 GITHUB_REPOSITORY=anhnvcoder/svp-web GITHUB_SHA="$web_head"
check "plan.sh in this checkout: a run of svp-web without SVP_CODE_ROOT: names SVP_CODE_ROOT" has "$work/plan.err" \
  "HEAD of $tree is $base, but this run builds $web_head of https://github.com/anhnvcoder/svp-web: set SVP_CODE_ROOT"
lacks "$work/output" "images=" && ok "plan.sh in this checkout: a run of svp-web without SVP_CODE_ROOT: no output" ||
  fail "plan.sh in this checkout: a run of svp-web without SVP_CODE_ROOT: no output"
plan_own "a run of a fork" 1 GITHUB_REPOSITORY=someone/short-video-platform GITHUB_SHA="$base"
check "plan.sh in this checkout: a run of a fork: no release source" has "$work/plan.err" \
  "this run is of https://github.com/someone/short-video-platform, which is the repository of 0 release sources"
# web is still a service of release source backend while prd runs that release, but this repository holds no source of
# it: a dispatch builds the six, never web, and build-image.sh refuses web before anything is built.
plan_own "a dispatch with services all" 0 "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch \
  INPUT_SERVICES=all
same "plan.sh in this checkout: services all builds the six, not web" \
  'images=["gateway","user-service","video-service","engagement-service","feed-service","media-worker"]' \
  "$(grep '^images=' "$work/output")"
plan_own "a dispatch with services web" 1 "${backend_run[@]}" GITHUB_SHA="$base" EVENT_NAME=workflow_dispatch \
  INPUT_SERVICES="gateway web"
check "plan.sh in this checkout: services web is refused, naming the six" has "$work/plan.err" \
  "services: 'web' is not an image this repository builds (gateway user-service video-service engagement-service feed-service media-worker)"
rc=0
on github env "${backend_run[@]}" GITHUB_SHA="$base" "$tree/deploy/ci/build-image.sh" web amd64 "$work/leg" \
  >/dev/null 2>"$work/build.err" || rc=$?
same "build-image.sh in this checkout: web (exit 1)" 1 "$rc"
check "build-image.sh in this checkout: web is refused, its source is another repository's" has "$work/build.err" \
  "web is not an image this repository builds (gateway user-service video-service engagement-service feed-service media-worker): its source is another repository's"
[ ! -e "$work/leg" ] && ok "build-image.sh in this checkout: web: nothing built, no output folder" ||
  fail "build-image.sh in this checkout: web: nothing built, no output folder"

# --- rescan.sh run: a run attests only the releases of the source of its own repository, as the identity of that
# source's signing workflow. A clone of svp-gitops on disk whose main names a gateway of backend and a web of svp-web;
# gh lists no open promote pull request; the fake cosign refuses every signature, so nothing is ever attested.
rg=$work/rescan-gitops
gr() {
  GIT_DIR=$rg/.git GIT_WORK_TREE=$rg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
mkdir -p "$rg/envs/stg/images"
for svc in gateway user-service video-service engagement-service feed-service media-worker; do
  d=
  [ "$svc" != gateway ] || d=$digest_a
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: "%s"\n  digest: "%s"\n' "$svc" \
    "${d:+0123456789ab}" "$d" >"$rg/envs/stg/images/$svc.yaml"
done
printf 'image:\n  repository: ghcr.io/anhnvcoder/svp-web/web\n  tag: "0123456789ab"\n  digest: "%s"\n' "$digest_b" \
  >"$rg/envs/stg/images/web.yaml"
git init -q --bare "$rg.git"
gr init -q -b main && gr add -A && gr commit -qm release && gr remote add origin "$rg.git" && gr push -q origin main
web_run=(GITHUB_REPOSITORY=anhnvcoder/svp-web
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main)
backend_rescan=("${backend_run[@]}"
  GITHUB_WORKFLOW_REF=anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main)
# rescan_run NAME WANT_RC VAR=VALUE... -- [--source NAME]: rescan.sh run in a made-up job on github with the variables,
# its output in rescan-NAME.out, its OUT rescan-NAME.
rescan_run() {
  local name=$1 want=$2 rc=0 vars=()
  shift 2
  while [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  shift
  fresh
  echo '[]' >"$work/gh/prs.json"
  on github env GITHUB_SERVER_URL=https://github.com "${vars[@]}" "$tree/deploy/ci/rescan.sh" run "$@" \
    "$work/rescan-$name" "$rg" >"$work/rescan-$name.out" 2>&1 || rc=$?
  same "rescan.sh run: $name (exit $want)" "$want" "$rc"
}
# nothing_read NAME: neither the host nor cosign was asked, and OUT was not created.
nothing_read() {
  if [ ! -s "$work/gh.log" ] && [ ! -s "$work/cosign.log" ] && [ ! -e "$work/rescan-$1" ]; then
    ok "rescan.sh run: $1: nothing read, nothing attested"
  else
    fail "rescan.sh run: $1: something was read: $(cat "$work/gh.log" "$work/cosign.log")"
  fi
}
rescan_run "the scheduled rescan of backend" 1 "${backend_rescan[@]}" --
check "rescan.sh run: backend: the promote pull request of backend asked for" has "$work/gh.log" "--head bot/promote-stg "
check "rescan.sh run: backend: the web of svp-web left to its source" has "$work/rescan-the scheduled rescan of backend.out" \
  "skip  web in main of svp-gitops, envs/stg/images/web.yaml: ghcr.io/anhnvcoder/svp-web/web is a release of source web"
check "rescan.sh run: backend: the signature of its gateway asked for" has "$work/cosign.log" \
  "--certificate-identity https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/short-video-platform/gateway@$digest_a"
check "rescan.sh run: backend: unsigned, so not attested" lacks "$work/cosign.log" "attest"
rescan_run "svp-web without --source" 1 "${web_run[@]}" --
check "rescan.sh run: svp-web without --source: names both sources" has "$work/rescan-svp-web without --source.out" \
  "FAIL  rescan.sh run --source backend in a run of https://github.com/anhnvcoder/svp-web, the repository of release source web: a run attests only the releases of its own source (--source web)"
nothing_read "svp-web without --source"
rescan_run "backend with --source web" 1 "${backend_rescan[@]}" -- --source web
check "rescan.sh run: backend with --source web: names both sources" has "$work/rescan-backend with --source web.out" \
  "FAIL  rescan.sh run --source web in a run of https://github.com/anhnvcoder/short-video-platform, the repository of release source backend"
nothing_read "backend with --source web"
rescan_run "svp-web with --source web, from another workflow" 1 "${web_run[@]}" \
  GITHUB_WORKFLOW_REF=anhnvcoder/svp-web/.github/workflows/ci.yml@refs/heads/main -- --source web
check "rescan.sh run: another workflow: names the identity" has \
  "$work/rescan-svp-web with --source web, from another workflow.out" \
  "FAIL  this run is https://github.com/anhnvcoder/svp-web/.github/workflows/ci.yml@refs/heads/main, but the releases of source web are attested only as https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main"
nothing_read "svp-web with --source web, from another workflow"
rescan_run "svp-web with --source web" 1 "${web_run[@]}" -- --source web
check "rescan.sh run: svp-web: its own promote pull request asked for" has "$work/gh.log" "--head bot/promote-stg-web "
check "rescan.sh run: svp-web: the gateway of backend left to its source" has "$work/rescan-svp-web with --source web.out" \
  "skip  gateway in main of svp-gitops, envs/stg/images/gateway.yaml: ghcr.io/anhnvcoder/short-video-platform/gateway is a release of source backend"
check "rescan.sh run: svp-web: the signature of its web asked for, as its identity" has "$work/cosign.log" \
  "--certificate-identity https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/svp-web/web@$digest_b"
check "rescan.sh run: svp-web: nothing of backend asked for" lacks "$work/cosign.log" "short-video-platform/"
fresh
rc=0
on local "$tree/deploy/ci/rescan.sh" run "$work/rescan-local" "$rg" >"$work/rescan-local.out" 2>&1 || rc=$?
same "rescan.sh run on a machine: refused first, as CI only" \
  "1 FAIL  rescan.sh run attests with the workflow's identity: CI only" "$rc $(cat "$work/rescan-local.out")"

# vuln-predicate.sh: who made the attestation, from the job's variables; local for each on a machine.
for arch in amd64 arm64; do
  d=$work/leg-$arch
  mkdir -p "$d"
  echo "linux/$arch" >"$d/platform"
  echo "$digest_a" >"$d/digest"
  echo "$digest_b" >"$d/config-digest"
  jq -n --arg c "$digest_b" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Trivy: {Version: "0.76.0"}, Results: []}' \
    >"$d/trivy.json"
  for f in scan-started scan-finished db-updated-at; do echo 2026-10-25T01:02:03Z >"$d/$f"; done
done
on github "$tree/deploy/ci/vuln-predicate.sh" "$work/predicate.json" "$work/leg-amd64" "$work/leg-arm64" >/dev/null
same "vuln-predicate.sh on github: invocation names this attempt, the run and the workflow" \
  '{"uri":"https://github.example/octo/repo/actions/runs/4242/attempts/3","event_id":"4242","builder.id":"https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main","parameters":null}' \
  "$(jq -c .invocation "$work/predicate.json")"
on local "$tree/deploy/ci/vuln-predicate.sh" "$work/predicate.json" "$work/leg-amd64" "$work/leg-arm64" >/dev/null
same "vuln-predicate.sh on a machine: local for each" \
  '{"uri":"local","event_id":"local","builder.id":"local","parameters":null}' "$(jq -c .invocation "$work/predicate.json")"

# provenance-predicate.sh: the run that built, from the job's variables and the dispatch event (its own test covers
# the rest).
jq -n '{inputs: {services: "all"}}' >"$work/event.json"
on github env GITHUB_EVENT_NAME=workflow_dispatch "$tree/deploy/ci/provenance-predicate.sh" "$work/provenance.json" \
  >/dev/null
same "provenance-predicate.sh on github: workflow, input, commit, builder and attempt of this run" \
  '{"buildDefinition":{"buildType":"https://actions.github.io/buildtypes/workflow/v1","externalParameters":{"workflow":{"ref":"refs/heads/main","repository":"https://github.example/octo/repo","path":".github/workflows/images.yml"},"inputs":{"services":"all"}},"resolvedDependencies":[{"uri":"git+https://github.example/octo/repo@refs/heads/main","digest":{"gitCommit":"89abcdef0123456789abcdef0123456789abcdef"}}]},"runDetails":{"builder":{"id":"https://github.example/octo/repo/.github/workflows/images.yml@refs/heads/main"},"metadata":{"invocationId":"https://github.example/octo/repo/actions/runs/4242/attempts/3"}}}' \
  "$(jq -c . "$work/provenance.json")"

# scan-gate.sh: the table in the summary and the counts in the log on github; the table in the log on a machine. A
# secret's line goes to both.
jq -n --arg c "$digest_b" '{SchemaVersion: 2, Metadata: {ImageID: $c}, Results: [{Target: "app",
  Vulnerabilities: [{Severity: "HIGH"}], Secrets: [{RuleID: "aws-key", Severity: "CRITICAL", StartLine: 3}]}]}' \
  >"$work/report.json"
fresh
if on github "$tree/deploy/ci/scan-gate.sh" "gw linux/amd64" "$work/report.json" >"$work/gate.out" \
  2>"$work/gate.err"; then
  fail "scan-gate.sh: a secret blocks"
else ok "scan-gate.sh: a secret blocks"; fi
same "scan-gate.sh on github: the table and the secret in the summary" '| Image | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN | Secrets |
| --- | --- | --- | --- | --- | --- | --- |
| gw linux/amd64 | 0 | 1 | 0 | 0 | 0 | 1 |

secret  aws-key (CRITICAL) in app line 3' "$(cat "$work/summary")"
same "scan-gate.sh on github: the counts in the log" \
  "gw linux/amd64: CRITICAL 0, HIGH 1, MEDIUM 0, LOW 0, UNKNOWN 0, secrets 1" "$(cat "$work/gate.out")"
check "scan-gate.sh on github: the secret in the log too" has "$work/gate.err" "secret  aws-key (CRITICAL) in app line 3"
fresh
on local "$tree/deploy/ci/scan-gate.sh" "gw linux/amd64" "$work/report.json" >"$work/gate.out" 2>"$work/gate.err" ||
  true
same "scan-gate.sh on a machine: the table in the log, no counts line" '| Image | CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN | Secrets |
| --- | --- | --- | --- | --- | --- | --- |
| gw linux/amd64 | 0 | 1 | 0 | 0 | 0 | 1 |' "$(cat "$work/gate.out")"
check "scan-gate.sh on a machine: the secret in the log" has "$work/gate.err" "secret  aws-key (CRITICAL) in app line 3"

# scan-gate.sh --grype: reports of grype written by hand. match ID SEVERITY PURL [RELATED_ID]: one match of a report.
match() {
  jq -n --arg id "$1" --arg sev "$2" --arg purl "$3" --arg rel "${4:-}" '{
    vulnerability: {id: $id, severity: $sev, fix: {versions: ["9.9.9"], state: "fixed"}},
    relatedVulnerabilities: (if $rel == "" then [] else [{id: $rel}] end),
    artifact: {name: ($purl | sub("^pkg:[^/]+/(.*/)?"; "") | sub("@.*$"; "")),
      version: ($purl | sub("^[^@]*@"; "") | sub("[?#].*$"; "")), purl: $purl}}'
}
# grype_report FILE MATCH...: a grype JSON report holding the matches.
grype_report() {
  local file=$1
  shift
  jq -s '{descriptor: {name: "grype", version: "0.121.0"}, matches: .}' <<<"$*" >"$file"
}
# ignore_entry ID EXPIRED_AT PURL: one entry of .trivyignore.yaml.
ignore_entry() {
  printf '  - id: %s\n    statement: Accepted for the test.\n    expired_at: %s\n    purls:\n      - %s\n' "$1" "$2" "$3"
}
# gate_grype NAME WANT_EXIT REPORT [FLAG]: runs the grype gate on a machine; ok when it exits WANT_EXIT.
gate_grype() {
  local name=$1 want=$2 report=$3 rc=0
  shift 3
  on local "$tree/deploy/ci/scan-gate.sh" "$@" --grype "web linux/arm64" "$report" >"$work/gate.out" \
    2>"$work/gate.err" || rc=$?
  same "$name (exit code)" "$want" "$rc"
}
soon=$(date -u -d '+10 days' +%F 2>/dev/null || date -u -v+10d +%F)
today=$(date -u +%F)
critical_npm=$(match CVE-2026-1111 Critical pkg:npm/left-pad@1.0.0)
high_npm=$(match CVE-2026-2222 High pkg:npm/zod@3.25.76)

rm -f "$tree/.trivyignore.yaml"
grype_report "$work/grype.json" "$critical_npm" "$high_npm"
gate_grype "scan-gate.sh --grype: a Critical match blocks" 1 "$work/grype.json"
check "scan-gate.sh --grype: id, package@version, purl and fix of the Critical match" has "$work/gate.err" \
  "critical  CVE-2026-1111 left-pad@1.0.0 pkg:npm/left-pad@1.0.0 (fixed: 9.9.9)"
check "scan-gate.sh --grype: the report itself is not printed" lacks "$work/gate.out" '"matches"'
gate_grype "scan-gate.sh --grype: --allow-critical lets a Critical match through" 0 "$work/grype.json" \
  --allow-critical
check "scan-gate.sh --grype: --allow-critical says so" has "$work/gate.err" \
  "note  web linux/arm64 (grype): 1 Critical vulnerabilities let through (--allow-critical)"

grype_report "$work/grype.json" "$high_npm" "$(match CVE-2026-3333 Negligible pkg:deb/debian/libc6@2.41-12)"
fresh
rc=0
on github "$tree/deploy/ci/scan-gate.sh" --grype "web linux/arm64" "$work/grype.json" >"$work/gate.out" 2>&1 || rc=$?
same "scan-gate.sh --grype: High and below only counted" 0 "$rc"
same "scan-gate.sh --grype on github: one grype row in the summary" '| Image | CRITICAL | HIGH | MEDIUM | LOW | NEGLIGIBLE | UNKNOWN | Excepted |
| --- | --- | --- | --- | --- | --- | --- | --- |
| web linux/arm64 (grype) | 0 | 1 | 0 | 0 | 1 | 0 | 0 |' "$(cat "$work/summary")"
grype_report "$work/grype.json"
gate_grype "scan-gate.sh --grype: no match passes" 0 "$work/grype.json"
check "scan-gate.sh --grype: no match still has its row" has "$work/gate.out" \
  "| web linux/arm64 (grype) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |"

# Exceptions from .trivyignore.yaml: by the match's id, by a related id, by a purl that has qualifiers on grype's side
# and an escape (+ as %2B), never by another version.
{
  echo "vulnerabilities:"
  ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0
  ignore_entry CVE-2021-44228 "$soon" pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1
  ignore_entry CVE-2026-4444 "$soon" pkg:deb/debian/libc6@2.41-12+deb13u4
  ignore_entry CVE-2023-54404 "$soon" pkg:npm/zod@3.25.75
} >"$tree/.trivyignore.yaml"
grype_report "$work/grype.json" "$critical_npm" \
  "$(match GHSA-jfh8-c2jp-5v3q Critical pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1 CVE-2021-44228)" \
  "$(match CVE-2026-4444 Critical 'pkg:deb/debian/libc6@2.41-12%2Bdeb13u4?arch=arm64&distro=debian-13.7')"
gate_grype "scan-gate.sh --grype: entries cover by id, by related id, by purl with qualifiers" 0 "$work/grype.json"
check "scan-gate.sh --grype: the three excepted are counted" has "$work/gate.out" \
  "| web linux/arm64 (grype) | 0 | 0 | 0 | 0 | 0 | 0 | 3 |"
grype_report "$work/grype.json" "$(match CVE-2023-54404 Critical pkg:npm/zod@3.25.76)"
gate_grype "scan-gate.sh --grype: an entry of another version does not cover" 1 "$work/grype.json"
check "scan-gate.sh --grype: the uncovered match is named" has "$work/gate.err" \
  "critical  CVE-2023-54404 zod@3.25.76 pkg:npm/zod@3.25.76"

# An expired entry fails the gate on the file: on a clean report, and on a report whose Critical it no longer covers.
{
  echo "vulnerabilities:"
  ignore_entry CVE-2026-1111 "$today" pkg:npm/left-pad@1.0.0
} >"$tree/.trivyignore.yaml"
grype_report "$work/grype.json" "$high_npm"
gate_grype "scan-gate.sh --grype: an expired entry fails a clean report" 1 "$work/grype.json"
check "scan-gate.sh --grype: the expired entry is named" has "$work/gate.out" \
  ".trivyignore.yaml:2: entry CVE-2026-1111 expired on $today"
check "scan-gate.sh --grype: the clean report blocks on the file alone" lacks "$work/gate.err" "critical  "
grype_report "$work/grype.json" "$critical_npm"
gate_grype "scan-gate.sh --grype: an expired entry no longer covers its match" 1 "$work/grype.json"
check "scan-gate.sh --grype: the match it covered is named again" has "$work/gate.err" "critical  CVE-2026-1111 "
rm -f "$tree/.trivyignore.yaml"

gate_grype "scan-gate.sh --grype: a trivy report is refused" 2 "$work/report.json"
check "scan-gate.sh --grype: says it is not a grype report" has "$work/gate.err" "is not a grype JSON report"

# Another repository's tree (SVP_CODE_ROOT): its own .trivyignore.yaml, which must be there.
grype_report "$work/grype.json" "$critical_npm"
{
  echo "vulnerabilities:"
  ignore_entry CVE-2026-1111 "$soon" pkg:npm/left-pad@1.0.0
} >"$webtree/.trivyignore.yaml"
# web_gate NAME WANT_EXIT: the grype gate on a machine with svp-web's tree as SVP_CODE_ROOT.
web_gate() {
  local rc=0
  on local env SVP_CODE_ROOT="$webtree" "$tree/deploy/ci/scan-gate.sh" --grype "web linux/arm64" "$work/grype.json" \
    >"$work/gate.out" 2>"$work/gate.err" || rc=$?
  same "$1 (exit code)" "$2" "$rc"
}
web_gate "scan-gate.sh --grype, svp-web's tree: its .trivyignore.yaml covers the match" 0
mv "$webtree/.trivyignore.yaml" "$work/web-trivyignore.yaml"
web_gate "scan-gate.sh --grype, svp-web's tree without .trivyignore.yaml" 1
check "scan-gate.sh, svp-web's tree without .trivyignore.yaml: names the file" has "$work/gate.err" \
  "$webtree has no file .trivyignore.yaml: SVP_CODE_ROOT must be the checkout whose code is built"
mv "$work/web-trivyignore.yaml" "$webtree/.trivyignore.yaml"

# --- platform-guard.sh, in the throwaway checkout: clean as it is (the adapter and its two tests are left out, and a
# symbolic link to a directory is skipped); a script not yet committed that writes GITHUB_OUTPUT itself and a tracked
# one that calls gh pr fail it, each named by file:line.
ln -s ../k8s "$tree/deploy/ci/linked-dir"
check "platform-guard.sh: clean, a link to a directory skipped" on local "$tree/deploy/ci/platform-guard.sh"
printf '#!/usr/bin/env bash\necho "a=b" >>"$GITHUB_OUTPUT"\n' >"$tree/deploy/ci/new-step.sh"
echo 'gh pr view 1' >>"$tree/deploy/ci/rescan.sh"
# A scenario file of the verification runs reading the run's branch from GitHub itself.
printf '# shellcheck shell=bash\nrev=$GITHUB_REF_NAME\n' >"$tree/deploy/ci/verify/new-scenario.sh"
rc=0
on local "$tree/deploy/ci/platform-guard.sh" >"$work/guard.out" 2>&1 || rc=$?
same "platform-guard.sh: a match exits 1" 1 "$rc"
check "platform-guard.sh: names the untracked script's line" has "$work/guard.out" "deploy/ci/new-step.sh:2:"
check "platform-guard.sh: names the tracked script's line" has "$work/guard.out" \
  "deploy/ci/rescan.sh:$(wc -l <"$tree/deploy/ci/rescan.sh" | tr -d ' '):gh pr view 1"
check "platform-guard.sh: reads the scenario files under deploy/ci/verify/" has "$work/guard.out" \
  "deploy/ci/verify/new-scenario.sh:2:"
rm "$tree/deploy/ci/new-step.sh" "$tree/deploy/ci/linked-dir" "$tree/deploy/ci/verify/new-scenario.sh"
g checkout -q -- deploy/ci/rescan.sh
check "platform-guard.sh: its own root as ROOT is the check without one" on local "$tree/deploy/ci/platform-guard.sh" \
  "$tree/deploy/ci/../.."

# --- platform-guard.sh ROOT, on svp-web's tree: clean as it is; every file it holds is read, wherever it sits, but
# .github/ (the platform's workflows) and .backend/ (the pinned checkout of this repository, even when not ignored).
check "platform-guard.sh ROOT: svp-web's tree is clean" on local "$tree/deploy/ci/platform-guard.sh" "$webtree"
mkdir -p "$webtree/e2e" "$webtree/.github/workflows" "$webtree/.backend/deploy/ci"
printf '#!/usr/bin/env bash\nsha=$GITHUB_SHA\n' >"$webtree/e2e/run.sh"
gw add e2e/run.sh && gw commit -qm "e2e runner"
printf 'release:\n\tgh workflow run images.yml\n' >"$webtree/Makefile"
echo 'sha: ${{ github.sha }} $GITHUB_SHA' >"$webtree/.github/workflows/ci.yml"
echo 'echo a=b >>"$GITHUB_OUTPUT"' >"$webtree/.backend/deploy/ci/step.sh"
rc=0
on local "$tree/deploy/ci/platform-guard.sh" "$webtree" >"$work/guard.out" 2>&1 || rc=$?
same "platform-guard.sh ROOT: a match in svp-web's tree exits 1" 1 "$rc"
check "platform-guard.sh ROOT: names the tracked script's line" has "$work/guard.out" 'e2e/run.sh:2:sha=$GITHUB_SHA'
check "platform-guard.sh ROOT: names the untracked Makefile's line" has "$work/guard.out" "Makefile:2:"
check "platform-guard.sh ROOT: .github/ is not read" lacks "$work/guard.out" ".github/"
check "platform-guard.sh ROOT: .backend/ is not read" lacks "$work/guard.out" ".backend/"
rm -rf "$webtree/Makefile" "$webtree/.github" "$webtree/.backend"
rm "$webtree/e2e/run.sh" && gw commit -qam "no e2e runner"
rc=0
on local "$tree/deploy/ci/platform-guard.sh" "$work/no-such-dir" >"$work/guard.out" 2>&1 || rc=$?
same "platform-guard.sh ROOT: a missing directory exits 2" 2 "$rc"
rc=0
on local "$tree/deploy/ci/platform-guard.sh" "$work/bin" >"$work/guard.out" 2>&1 || rc=$?
same "platform-guard.sh ROOT: a directory outside git exits 2" 2 "$rc"

# --- changed-services.sh: platform.sh is part of the image pipeline (common.sh sources it), so a change of it builds
# all six, as do release-set.sh and promote-prd.sh (job promote-prd); this test, platform-guard.sh,
# provenance-predicate-test.sh, the scripts of the verification runs and of the other workflows, the policy's values
# and docs/ are read by no image job.
changed_by() {
  echo "# changed" >>"$tree/$1"
  g commit -qam "change $1"
  on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
all="engagement-service feed-service gateway media-worker user-service video-service"
same "changed-services: a change of platform.sh builds all six" "$all" "$(changed_by deploy/ci/platform.sh)"
# The web client's source left this repository: a file under web/ (and its removal) builds no image.
mkdir -p "$tree/web" && echo "export {};" >"$tree/web/page.ts"
same "changed-services: a file added under web/ builds nothing" "" "$(g add web && changed_by web/page.ts)"
g rm -q -r web && g commit -qm "drop web/"
same "changed-services: the removal of web/ builds nothing" "" \
  "$(on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null)"
same "changed-services: a change of platform-test.sh builds nothing" "" "$(changed_by deploy/ci/platform-test.sh)"
same "changed-services: a change of promote-test.sh builds nothing" "" "$(changed_by deploy/ci/promote-test.sh)"
same "changed-services: a change of platform-guard.sh builds nothing" "" "$(changed_by deploy/ci/platform-guard.sh)"
same "changed-services: a change of provenance-predicate-test.sh builds nothing" "" \
  "$(changed_by deploy/ci/provenance-predicate-test.sh)"
same "changed-services: a change under deploy/ci/verify/ builds nothing" "" "$(changed_by deploy/ci/verify/gitops.sh)"
same "changed-services: a change of verify-tempo.sh builds nothing" "" "$(changed_by deploy/ci/verify-tempo.sh)"
same "changed-services: a change of gitops-sourcemaps.sh builds nothing" "" "$(changed_by deploy/ci/gitops-sourcemaps.sh)"
same "changed-services: a change of gitops-sourcemaps-test.sh builds nothing" "" \
  "$(changed_by deploy/ci/gitops-sourcemaps-test.sh)"
for f in sourcemaps-image.sh sourcemaps-image-test.sh; do
  same "changed-services: a change of $f builds nothing" "" "$(changed_by "deploy/ci/$f")"
done
same "changed-services: a change of rescan.sh builds all six" "$all" "$(changed_by deploy/ci/rescan.sh)"
for f in record-stg.sh gitops-check.sh gitops-check-test.sh values-check.sh verify-release.sh dora.sh dora-test.sh \
  release-set-test.sh promote-prd-test.sh; do
  same "changed-services: a change of $f builds nothing" "" "$(changed_by "deploy/ci/$f")"
done
same "changed-services: a change of release-set.sh builds all six" "$all" "$(changed_by deploy/ci/release-set.sh)"
same "changed-services: a change of promote-prd.sh builds all six" "$all" "$(changed_by deploy/ci/promote-prd.sh)"
same "changed-services: a change of common.sh builds all six" "$all" "$(changed_by deploy/ci/common.sh)"
same "changed-services: a change of the policy's values builds nothing" "" \
  "$(changed_by deploy/helm/svp-policy/values.yaml)"
same "changed-services: a change under docs/ builds nothing" "" "$(changed_by docs/decision.md)"
# The Makefile counts only for the lines pinning the tools of the gate.
printf 'TRIVY_IMAGE := trivy@sha256:1\nGRYPE_IMAGE := grype@sha256:1\nK6_IMAGE := k6@sha256:1\n' >"$tree/Makefile"
g add Makefile && g commit -qm "add the Makefile"
sed 's/^GRYPE_IMAGE := grype@sha256:1$/GRYPE_IMAGE := grype@sha256:2/' "$tree/Makefile" >"$work/Makefile" &&
  cp "$work/Makefile" "$tree/Makefile" && g commit -qam "bump grype"
same "changed-services: a change of the GRYPE_IMAGE line builds all six" "$all" \
  "$(on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null)"
same "changed-services: a change of another line of the Makefile builds nothing" "" "$(changed_by Makefile)"

# --- verify-release.sh: build provenance, only where the policy checks it. A copy of the throwaway checkout, whose
# history the cases below change freely, and a tree laid out as svp-gitops (envs/<env>/charts.yaml pinning a commit
# of the copy, overlays envs/<env>/svp-policy.yaml), a git repository whose origin names svp-gitops (never reached);
# the fake cosign answers from $fx.
vr=$work/vr
cp -R "$tree" "$vr"
gv() {
  GIT_DIR=$vr/.git GIT_WORK_TREE=$vr GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
cfg=$work/cfg
gc() {
  GIT_DIR=$cfg/.git GIT_WORK_TREE=$cfg GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
off_rev=$(gv rev-parse HEAD)
sed 's/^  requireProvenance: false$/  requireProvenance: true/' "$tree/deploy/helm/svp-policy/values.yaml" \
  >"$vr/deploy/helm/svp-policy/values.yaml"
gv commit -qam "provenance on in the policy's values"
on_rev=$(gv rev-parse HEAD)
gv checkout -q "$off_rev" -- deploy/helm/svp-policy/values.yaml && gv commit -qm "provenance off again"
off_rev=$(gv rev-parse HEAD)
gv update-ref refs/remotes/origin/main HEAD
# charts ENV REV: envs/ENV/charts.yaml of the tree pins commit REV of the copy.
charts() {
  printf 'revision: %s\npodSecurityVersion: v1.36\ncollectorConfigSha256: %s\n' "$2" "$(printf '0%.0s' $(seq 64))" \
    >"$cfg/envs/$1/charts.yaml"
}
overlay() { printf 'imageVerification:\n  requireProvenance: %s\n' "$2" >"$cfg/envs/$1/svp-policy.yaml"; }
mkdir -p "$cfg/envs/stg/images" "$cfg/envs/prd/images" "$cfg/base"
echo "# The base values" >"$cfg/base/README.md"
for env in stg prd; do
  charts "$env" "$off_rev"
  for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
    printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: ""\n  digest: ""\n' "$svc" \
      >"$cfg/envs/$env/images/$svc.yaml"
  done
done
gc init -q -b main && gc add -A && gc commit -qm init
gc remote add origin https://github.com/anhnvcoder/svp-gitops.git
fx=$work/cosign-fixtures
mkdir -p "$fx"
image=ghcr.io/anhnvcoder/short-video-platform/web
subject=https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
commit=0123456789abcdef0123456789abcdef01234567
# envelope: an in-toto statement on stdin as cosign verify-attestation prints it, one line.
envelope() { jq -c '{payloadType: "application/vnd.in-toto+json", payload: (tojson | @base64)}'; }
jq -n --arg d "${digest_a#sha256:}" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$digest_b" '{
  predicateType: "https://cosign.sigstore.dev/attestation/vuln/v1", subject: [{digest: {sha256: $d}}],
  predicate: {scanner: {result: {platforms: [{platform: "linux/amd64", digest: $p, report: {}},
    {platform: "linux/arm64", digest: $p, report: {}}]}}, metadata: {scanFinishedOn: $t}}}' | envelope >"$fx/vuln.jsonl"
# provenance [JQ]: the provenance.jsonl CI's predicate would give for $digest_a, changed by the jq filter JQ.
provenance() {
  jq -n --arg d "${digest_a#sha256:}" --arg b "$subject" --arg c "$commit" '{
    predicateType: "https://slsa.dev/provenance/v1", subject: [{name: "web", digest: {sha256: $d}}],
    predicate: {buildDefinition: {buildType: "https://actions.github.io/buildtypes/workflow/v1",
      externalParameters: {workflow: {ref: "refs/heads/main",
        repository: "https://github.com/anhnvcoder/short-video-platform", path: ".github/workflows/images.yml"}},
      resolvedDependencies: [{uri: "git+https://github.com/anhnvcoder/short-video-platform@refs/heads/main",
        digest: {gitCommit: $c}}]},
      runDetails: {builder: {id: $b}, metadata: {invocationId: "https://github.com/x/runs/1/attempts/1"}}}}' |
    jq -c "${1:-.}" | envelope >"$fx/slsaprovenance1.jsonl"
}
echo "$commit" >"$fx/cert-sha"
# release NAME WANT_RC [ARGS...]: verify-release.sh --gitops <tree> [ARGS...] web $digest_a on a machine, output in
# vr.out.
release() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/verify-release.sh" --gitops "$cfg" "$@" "$image" "$digest_a" \
    >"$work/vr.out" 2>&1 || rc=$?
  same "verify-release.sh: $name (exit $want)" "$want" "$rc"
}

rm -f "$fx/slsaprovenance1.jsonl"
release "provenance off everywhere: signature and vuln only" 0
check "verify-release.sh: provenance off: no provenance asked for" lacks "$work/cosign.log" slsaprovenance1
check "verify-release.sh: provenance off: the ok line names no provenance" lacks "$work/vr.out" "provenance of"

overlay stg true
release "on in the stg overlay, the release has no provenance" 1
check "verify-release.sh: names the missing provenance and the release to build again" has "$work/vr.out" \
  "has no provenance attestation of https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main, which the policy requires here: a release built before CI attested provenance; release it again (gh workflow run images.yml --repo anhnvcoder/short-video-platform --ref main -f services=web)"
FAKE_COSIGN_DOWN=slsaprovenance1 release "on in the stg overlay, GHCR out of reach for the provenance" 1
check "verify-release.sh: an unreachable registry is not read as a release from before provenance" has "$work/vr.out" \
  "its provenance attestation could not be verified (Error: GET https://ghcr.io/v2/: dial tcp: i/o timeout); check again, do not build it again"
check "verify-release.sh: an unreachable registry asks for no new build" lacks "$work/vr.out" "release it again"
release "on in stg only, checked for prd: no provenance needed" 0 --env prd
check "verify-release.sh: for prd no provenance asked for" lacks "$work/cosign.log" slsaprovenance1

provenance
release "on, a provenance that matches the policy and the certificate" 0
check "verify-release.sh: the ok line names the provenance's commit" has "$work/vr.out" \
  "provenance of ${commit:0:12} by $subject"
check "verify-release.sh: the certificate is asked for the provenance's commit" has "$work/cosign.log" \
  "verify-attestation --type slsaprovenance1 --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity $subject --certificate-github-workflow-sha $commit $image@$digest_a"
# The contract with step 5 of gitops-check.sh: tag_provenance_mismatch of common.sh reads this very ok line.
tp=$work/tag-provenance
mkdir -p "$tp/envs/stg/images"
{ echo "check envs/stg/images/web.yaml" && grep '^ok ' "$work/vr.out"; } >"$work/tp.out"
# tp_case NAME TAG WANT: image.tag TAG in envs/stg/images/web.yaml, stg requiring provenance; the output must be WANT.
tp_case() {
  printf 'image:\n  repository: %s\n  tag: "%s"\n  digest: "%s"\n' "$image" "$2" "$digest_a" >"$tp/envs/stg/images/web.yaml"
  same "tag_provenance_mismatch on the ok line of verify-release.sh: $1" "$3" \
    "$(on local bash -c '. "$1/deploy/ci/common.sh" && tag_provenance_mismatch "$2" "$3" stg' _ "$vr" "$tp" "$work/tp.out")"
}
tp_case "the tag of the provenance's commit agrees" "${commit:0:12}" ""
tp_case "another tag is a mismatch" 89abcdef0123 \
  "envs/stg/images/web.yaml: image.tag is 89abcdef0123, but its provenance says it was built from ${commit:0:12}"
FAKE_COSIGN_DOWN=slsaprovenance1 FAKE_COSIGN_DOWN_ONCE=$work/cosign-once release \
  "on, GHCR out of reach once, then the provenance verifies" 1
rm -f "$work/cosign-once"
check "verify-release.sh: a provenance that verifies on the second call is not read as missing" has "$work/vr.out" \
  "its provenance attestation could not be verified (cosign failed once, then verified one); check again, do not build it again"
check "verify-release.sh: a provenance that verifies on the second call asks for no new build" lacks "$work/vr.out" \
  "release it again"

echo 89abcdef0123456789abcdef0123456789abcdef >"$fx/cert-sha"
release "the certificate names another commit" 1
check "verify-release.sh: says the commits differ" has "$work/vr.out" \
  "the provenance names commit $commit, the certificate of its signature another (or none)"
echo "$commit" >"$fx/cert-sha"

# provenance_case NAME JQ MESSAGE: a provenance changed by JQ is refused with MESSAGE.
provenance_case() {
  provenance "$2"
  release "$1" 1
  check "verify-release.sh: $1: says why" has "$work/vr.out" "$3"
}
provenance_case "another builder" '.predicate.runDetails.builder.id = "https://github.com/x/y/.github/workflows/z.yml@refs/heads/main"' \
  "provenance builder.id is https://github.com/x/y/.github/workflows/z.yml@refs/heads/main, not $subject"
provenance_case "another repository" \
  '.predicate.buildDefinition.externalParameters.workflow.repository = "https://github.com/fork/short-video-platform"' \
  "provenance workflow repository is https://github.com/fork/short-video-platform, not https://github.com/anhnvcoder/short-video-platform"
provenance_case "another ref" '.predicate.buildDefinition.externalParameters.workflow.ref = "refs/heads/feat/x"' \
  "provenance workflow ref is refs/heads/feat/x, not refs/heads/main"
provenance_case "another digest" '.subject[0].digest.sha256 = "'"${digest_b#sha256:}"'"' \
  "provenance the attestation is not about this digest"
provenance_case "not SLSA v1" '.predicateType = "https://slsa.dev/provenance/v0.2"' "provenance not a SLSA v1 provenance"
provenance_case "a short commit" '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit = "0123456"' \
  "provenance resolvedDependencies does not name exactly one commit"
provenance
cat "$fx/slsaprovenance1.jsonl" "$fx/slsaprovenance1.jsonl" >"$fx/two" && mv "$fx/two" "$fx/slsaprovenance1.jsonl"
release "two provenance attestations" 1
check "verify-release.sh: two provenance attestations: says so" has "$work/vr.out" "carries 2 provenance attestations, not exactly one"

# At a commit of the tree (--rev), not as it is on disk.
rm -f "$fx/slsaprovenance1.jsonl"
before=$(gc rev-parse HEAD)
gc add -A envs && gc commit -qm "provenance on in stg"
on_stg=$(gc rev-parse HEAD)
rm "$cfg/envs/stg/svp-policy.yaml"
release "off on disk" 0
release "on at a commit (--rev --env stg), no provenance" 1 --rev "$on_stg" --env stg
check "verify-release.sh: on at a commit: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
release "at the commit before (--rev), off" 0 --rev "$before" --env stg

# Without --gitops: the clone gitops_dir names (SVP_GITOPS_DIR here), as it is on disk.
overlay stg true
rc=0
fresh
on local env FAKE_COSIGN_DIR="$fx" SVP_GITOPS_DIR="$cfg" "$vr/deploy/ci/verify-release.sh" "$image" "$digest_a" \
  >"$work/vr.out" 2>&1 || rc=$?
same "verify-release.sh: the clone of SVP_GITOPS_DIR, on in its stg overlay, no provenance (exit 1)" 1 "$rc"
rc=0
on local env FAKE_COSIGN_DIR="$fx" SVP_GITOPS_DIR="$work/none" "$vr/deploy/ci/verify-release.sh" "$image" "$digest_a" \
  >"$work/vr.out" 2>&1 || rc=$?
same "verify-release.sh: no clone of svp-gitops (exit 1)" 1 "$rc"
check "verify-release.sh: no clone: names what to clone" has "$work/vr.out" "is not a clone of svp-gitops"
rm "$cfg/envs/stg/svp-policy.yaml"

# On in the values at the commit charts.yaml pins: every environment without an overlay inherits it; one that turns it
# off is off. A charts.yaml naming no commit of the copy is refused.
charts stg "$on_rev"
charts prd "$on_rev"
release "on in the values at the pinned commit, no provenance" 1
check "verify-release.sh: on in the values: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
overlay stg false
release "on in the values, off in the stg overlay, checked for stg" 0 --env stg
release "on in the values, prd without overlay, checked for any environment" 1
charts prd "$(printf 'f%.0s' $(seq 40))"
release "a charts.yaml naming no commit of this clone" 1 --env prd
check "verify-release.sh: a charts.yaml naming no commit: names it" has "$work/vr.out" \
  "envs/prd/charts.yaml names no commit of this clone holding deploy/helm/svp-policy/values.yaml"
charts stg "$off_rev"
charts prd "$off_rev"

# Overlays of another shape: refused, never read as off.
printf 'imageVerification:\n  requireProvenance: "true"\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay with a quoted value" 1
check "verify-release.sh: a quoted value: names the overlay" has "$work/vr.out" \
  "envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification:\n  requireProvenance: false\n  mode: Audit\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay that sets another key" 1
check "verify-release.sh: another key: names the overlay" has "$work/vr.out" \
  "envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification: {requireProvenance: true}\n' >"$cfg/envs/stg/svp-policy.yaml"
release "an overlay in flow style" 1
check "verify-release.sh: an overlay refused: cosign never asked" test ! -s "$work/cosign.log"

# Release sources: each image is verified with the identity of the source whose prefix it is under, at the revision
# the environment's charts.yaml pins. A commit of the copy from before the table (the policy's values with the
# identity lines, no files/sources.json) reads as its one source backend.
web_image=ghcr.io/anhnvcoder/svp-web/web
web_subject=https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main
backend_image=$image
gv rm -q -r deploy/helm/svp-policy/files
awk -v s="$subject" '{ print }
  /^  namespace: / {
    print "  imagePrefix: ghcr.io/anhnvcoder/short-video-platform/"
    print "  issuer: https://token.actions.githubusercontent.com"
    print "  subject: " s
    print "  provenanceRepository: https://github.com/anhnvcoder/short-video-platform"
    print "  provenanceRef: refs/heads/main"
  }' "$tree/deploy/helm/svp-policy/values.yaml" >"$vr/deploy/helm/svp-policy/values.yaml"
gv add deploy/helm/svp-policy/values.yaml && gv commit -qm "the policy before the table of release sources"
legacy_rev=$(gv rev-parse HEAD)
gv checkout -q "$off_rev" -- deploy/helm/svp-policy && gv commit -qm "the table of release sources again"
same "verify-release.sh: the copy is back on the table of release sources" "" "$(gv diff "$off_rev" HEAD)"
overlay stg false
overlay prd false
image=$web_image
release "the web source's image, signed by svp-web" 0 --env stg
check "verify-release.sh: the web source's image is verified with svp-web's identity" has "$work/cosign.log" \
  "verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity $web_subject $web_image@$digest_a"
check "verify-release.sh: the web source's image is never verified with the backend's identity" lacks "$work/cosign.log" \
  "--certificate-identity $subject"
overlay stg true
provenance '.predicate.runDetails.builder.id = "'"$web_subject"'"
  | .predicate.buildDefinition.externalParameters.workflow.repository = "https://github.com/anhnvcoder/svp-web"'
release "the web source's image with svp-web's provenance, on in stg" 0 --env stg
check "verify-release.sh: the ok line names svp-web's identity" has "$work/vr.out" "provenance of ${commit:0:12} by $web_subject"
provenance
release "the web source's image with the backend's provenance" 1 --env stg
check "verify-release.sh: the backend's builder is refused for the web source" has "$work/vr.out" \
  "provenance builder.id is $subject, not $web_subject"
rm -f "$fx/slsaprovenance1.jsonl"
overlay stg false
image=ghcr.io/anhnvcoder/svp-web/gateway
release "the gateway under the web source's prefix" 1 --env stg
check "verify-release.sh: a service the source does not publish: names what is admitted" has "$work/vr.out" \
  "ghcr.io/anhnvcoder/svp-web/gateway is not a release of gateway that the policy of stg admits (at ${off_rev:0:12}: ghcr.io/anhnvcoder/short-video-platform/gateway)"
check "verify-release.sh: a service the source does not publish: cosign never asked" test ! -s "$work/cosign.log"
charts stg "$legacy_rev"
image=$backend_image
release "the backend's web at a commit before the table" 0 --env stg
check "verify-release.sh: before the table, the identity of the values' lines" has "$work/cosign.log" \
  "--certificate-identity $subject $backend_image@$digest_a"
image=$web_image
release "the web source's image at a commit before the table" 1 --env stg
check "verify-release.sh: before the table, the web source is not admitted" has "$work/vr.out" \
  "$web_image is not a release of web that the policy of stg admits (at ${legacy_rev:0:12}: ghcr.io/anhnvcoder/short-video-platform/web)"
charts stg "$off_rev"
charts prd "$legacy_rev"
release "the web source's image, prd before the table, every environment" 1
check "verify-release.sh: every environment: prd before the table refuses it" has "$work/vr.out" \
  "$web_image is not a release of web that the policy of prd admits"
release "the web source's image, prd before the table, checked for stg" 0 --env stg
charts prd "$off_rev"
image=$backend_image
rm "$cfg/envs/stg/svp-policy.yaml" "$cfg/envs/prd/svp-policy.yaml"

# The functions of common.sh that name no source keep to source backend; a repository's source is read by its prefix;
# oci_labels names the repository of its source and the commit of code_root (SVP_CODE_ROOT, this checkout without).
# shellcheck disable=SC2016 # expanded by the inner shell
got=$(on local bash -c '. "$1/deploy/ci/common.sh" && sign_identity && echo "$sign_subject" && sign_identity web &&
  echo "$sign_subject" && provenance_source && echo "$provenance_repository $provenance_ref" &&
  source_of_repository ghcr.io/anhnvcoder/short-video-platform/api/gateway && oci_labels | head -n 2 &&
  oci_labels web | head -n 1' _ "$vr")
same "common.sh: the identity of sources backend and web, and labels of this checkout" \
  "$subject"$'\n'"$web_subject"$'\n'"https://github.com/anhnvcoder/short-video-platform refs/heads/main"$'\n'"backend"$'\n'"org.opencontainers.image.source=https://github.com/anhnvcoder/short-video-platform"$'\n'"org.opencontainers.image.revision=$(gv rev-parse HEAD)"$'\n'"org.opencontainers.image.source=https://github.com/anhnvcoder/svp-web" \
  "$got"
# shellcheck disable=SC2016
got=$(on local env SVP_CODE_ROOT="$cfg" bash -c '. "$1/deploy/ci/common.sh" && echo "$script_root" &&
  oci_labels web | sed -n 2p' _ "$vr")
same "common.sh: SVP_CODE_ROOT labels that tree's commit, scripts stay in this checkout" \
  "$vr"$'\n'"org.opencontainers.image.revision=$(gc rev-parse HEAD)" "$got"
rc=0
on local env SVP_CODE_ROOT="$work/none" bash -c '. "$1/deploy/ci/common.sh"' _ "$vr" >"$work/vr.out" 2>&1 || rc=$?
same "common.sh: an SVP_CODE_ROOT that is no folder (exit 1)" 1 "$rc"
check "common.sh: an SVP_CODE_ROOT that is no folder: says so" has "$work/vr.out" "SVP_CODE_ROOT=$work/none is not a folder"
# shellcheck disable=SC2016
same "common.sh: drill_images are the drillImages of source backend, which the policy admits" \
  "$(jq -r '.sources[] | select(.name == "backend") | .drillImages | join(" ")' "$src/deploy/helm/svp-policy/files/sources.json")" \
  "$(bash -c '. "$1/common.sh" && echo "${drill_images[*]}"' _ "$here")"

# --- values-check.sh --gitops on a pull request of the tree: the policy of one environment changed (its overlay, or
# its charts.yaml) checks every release of that environment and none of the other; an image file checks itself; any
# other file nothing. The gateway is released in both environments.
overlay stg false
for env in stg prd; do
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/gateway\n  tag: "%s"\n  digest: "%s"\n' \
    "${off_rev:0:12}" "$digest_a" >"$cfg/envs/$env/images/gateway.yaml"
done
gc add -A && gc commit -qm "the gateway released"
pr_base=$(gc rev-parse HEAD)
# values_check NAME WANT_RC: values-check.sh --gitops with the pull request's base, on a machine, output in vc.out.
values_check() {
  local rc=0
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/values-check.sh" --gitops "$cfg" "$pr_base" >"$work/vc.out" 2>&1 ||
    rc=$?
  same "values-check.sh: $1 (exit $2)" "$2" "$rc"
}
echo "# More" >>"$cfg/base/README.md"
gc commit -qam "base only"
values_check "a change of base/ only: nothing to check" 0
check "values-check.sh: base/ only: cosign never asked" test ! -s "$work/cosign.log"
rm -f "$fx/slsaprovenance1.jsonl"
overlay stg true
gc commit -qam "provenance on in stg"
values_check "provenance turned on in stg, its gateway has none" 1
check "values-check.sh: provenance on in stg: says stg's policy changed" has "$work/vc.out" \
  "note  what the releases of stg must carry may have changed since ${pr_base:0:12} (envs/stg/svp-policy.yaml)"
check "values-check.sh: provenance on in stg: names the release without provenance" has "$work/vc.out" \
  "ghcr.io/anhnvcoder/short-video-platform/gateway@$digest_a has no provenance attestation"
check "values-check.sh: provenance on in stg: every service of stg is read" has "$work/vc.out" \
  "ok    envs/stg/images/web.yaml: no digest"
check "values-check.sh: provenance on in stg: prd is not read" lacks "$work/vc.out" "envs/prd/"
hint="gh workflow run images.yml --repo anhnvcoder/short-video-platform --ref main -f rescan=true"
check "values-check.sh: the dispatch in the log, naming the code repository" has "$work/vc.out" "  $hint"
provenance
values_check "provenance turned on in stg, the release has it" 0
overlay stg false
gc commit -qam "provenance off in stg"
charts prd "$on_rev"
gc commit -qam "prd runs newer charts"
rm -f "$fx/slsaprovenance1.jsonl"
values_check "prd's charts.yaml moved to values that turn provenance on" 1
check "values-check.sh: prd's charts moved: prd is read" has "$work/vc.out" "check envs/prd/images/gateway.yaml"
check "values-check.sh: prd's charts moved: stg is not" lacks "$work/vc.out" "envs/stg/"
charts prd "$off_rev"
gc commit -qam "prd back"
gc update-ref refs/heads/main HEAD
pr_base=$(gc rev-parse HEAD)
printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' \
  "${off_rev:0:12}" "$digest_a" >"$cfg/envs/stg/images/web.yaml"
gc commit -qam "web released in stg"
values_check "an image file changed: only it is checked" 0
same "values-check.sh: an image file changed: one check" "check envs/stg/images/web.yaml" "$(grep '^check ' "$work/vc.out")"
fresh
if on github "$vr/deploy/ci/values-check.sh" --gitops "$cfg" "" >/dev/null 2>"$work/vc.err"; then
  fail "values-check.sh: no base, unsigned releases fail"
else ok "values-check.sh: no base, unsigned releases fail"; fi
check "values-check.sh: cosign is asked for the policy's issuer and subject" has "$work/cosign.log" \
  "verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/short-video-platform/gateway@$digest_a"
same "values-check.sh: the dispatch in the summary" "values-check failed: refresh the vuln attestations with \`$hint\`; a missing provenance needs a new release (above)" "$(cat "$work/summary")"

# --- plan.sh on a push to main that builds no image (the base: the newest successful push run): promote_charts when
# what the charts read changed (a file under deploy/helm/, or the file a symbolic link there points to), not for docs/.
# plan_charts NAME WANT: plan.sh of a push to main after one commit hands on promote_charts=WANT.
plan_charts() {
  local last
  last=$(jq -nc --arg sha "$(gv rev-parse HEAD~1)" \
    '{workflow_runs: [{head_sha: $sha, conclusion: "success", event: "push", head_branch: "main"}]}')
  fresh
  on github env "${backend_run[@]}" GITHUB_SHA="$(gv rev-parse HEAD)" EVENT_NAME=push GIT_REF=refs/heads/main \
    LAST_SUCCESS_JSON="$last" "$vr/deploy/ci/plan.sh" \
    >/dev/null 2>&1 || fail "plan.sh: $1: exits 0"
  same "plan.sh: $1" "promote_charts=$2 has_images=false" \
    "$(grep '^promote_charts=' "$work/output") $(grep '^has_images=' "$work/output")"
}
echo "# Another decision" >>"$vr/docs/decision.md"
gv commit -qam "a decision"
plan_charts "a push of docs/ only promotes nothing" false
echo "# A comment" >>"$vr/deploy/helm/svp-policy/values.yaml"
gv commit -qam "a comment in a chart"
plan_charts "a push that changes a chart promotes the charts" true
check "plan.sh: the summary names the chart's file" has "$work/summary" "- deploy/helm/svp-policy/values.yaml"
echo "exporters: {}" >>"$vr/deploy/observability/otelcol/k8s-config.yaml"
gv commit -qam "the collector's config"
plan_charts "a push that changes the file a chart's link points to promotes the charts" true

# --- gitops_no_provenance (deploy/ci/verify/gitops.sh) in the copy: the newest web release in the history of web.yaml
# that cosign finds signed without provenance. A release built from a commit holding provenance-predicate.sh is passed
# over without asking cosign; an error of cosign is never "no provenance".
mkdir -p "$vr/deploy/k8s/values/services"
web_release() {
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/web\n  tag: "%s"\n  digest: "%s"\n' "$1" "$2" \
    >"$vr/deploy/k8s/values/services/web.yaml"
  gv add deploy/k8s/values/services/web.yaml && gv commit -qm "release web $1"
}
# A commit this history does not hold, so not one known to hold the provenance script: cosign is asked.
web_release 0123456789ab "$digest_b"
old_values=$(gv rev-parse HEAD)
web_release "$(gv rev-parse --short=12 HEAD)" "$digest_a"
# no_provenance NAME WANT_RC [VAR=VALUE...]: gitops_no_provenance with the variables, stdout in np.out, stderr in np.err.
no_provenance() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  # The file as $1: with it as $0, it would take itself for run as a script.
  on local env repo="$vr" here="$vr/deploy/ci" "$@" "$BASH" -c '. "$1"; gitops_no_provenance' bash \
    "$vr/deploy/ci/verify/gitops.sh" >"$work/np.out" 2>"$work/np.err" || rc=$?
  same "gitops_no_provenance: $name (exit $want)" "$want" "$rc"
}
rm -f "$fx/slsaprovenance1.jsonl"
no_provenance "the older release, signed without provenance" 0 FAKE_COSIGN_DIR="$fx"
same "gitops_no_provenance: names it and the values that name it" \
  "ghcr.io/anhnvcoder/short-video-platform/web@$digest_b (values of ${old_values:0:12})" "$(cat "$work/np.out")"
check "gitops_no_provenance: the release built with the provenance script: cosign never asked" lacks \
  "$work/cosign.log" "web@$digest_a"
provenance
no_provenance "every release asked has provenance" 1 FAKE_COSIGN_DIR="$fx"
check "gitops_no_provenance: none: says so" has "$work/np.err" \
  "no signed web release without provenance in the history of deploy/k8s/values/services/web.yaml"
no_provenance "cosign answers with an error" 2
check "gitops_no_provenance: an error: names the release" has "$work/np.err" \
  "web@$digest_b: cosign could not tell whether it carries a provenance attestation"
check "gitops_no_provenance: an error: cosign's own line" has "$work/np.err" "Error: no signatures found"
same "gitops_no_provenance: an error: nothing on stdout" "" "$(cat "$work/np.out")"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
