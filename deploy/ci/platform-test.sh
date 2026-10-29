#!/usr/bin/env bash
# Tests for deploy/ci/platform.sh, the functions the CI scripts call for everything that depends on the CI platform,
# and for the scripts that call them. Everything runs in a temporary directory: the variables of a GitHub Actions job
# are made up, and a fake gh and a fake cosign first on PATH record their arguments and answer from fixtures, so no
# test reaches GitHub, a registry or Sigstore. Checked:
#   - github (a made-up job): outputs, the job summary, masks, warnings and run links land where GitHub reads them,
#     and pull requests are written through gh with the job's repository;
#   - local: everything on stdout, no mask, links "local", and no write through the platform's API (reads still are);
#   - another CI (GitLab CI, a CI=true one): a clear error, nothing written;
#   - the scripts give what they gave when they read GitHub's variables themselves: plan.sh, vuln-predicate.sh,
#     provenance-predicate.sh (the workflow, ref and commit of the run, and the services input of a dispatch),
#     scan-gate.sh, values-check.sh (the signing identity is read from the policy's values) and promote.sh (a dry run
#     and a local run in a throwaway git repository with a throwaway origin; on a machine, an origin with any push URL
#     off its disk is refused, or with PROMOTE_DRY_RUN=1 the push is printed, and the branch never moves);
#   - scan-gate.sh --grype on grype reports written by hand: a Critical match blocks and is named, --allow-critical lets
#     it through, High and below are only counted; an entry of .trivyignore.yaml covers a match by its id or a related
#     id with the same purl (qualifiers and escapes aside), never another version; an expired entry fails the gate;
#     a report that is not grype's exits 2;
#   - platform-guard.sh passes the throwaway checkout and fails, naming file:line, a script that reads GITHUB_OUTPUT or
#     calls gh itself;
#   - verify-release.sh with a fake cosign that answers from fixtures: without requireProvenance in the policy's values
#     or the overlays only the signature and the vuln attestation are asked for; with it on (in the base values, in the
#     overlay of an environment, at a commit with --rev, for one environment with --env) the release also needs exactly
#     one provenance attestation whose builder.id, workflow repository and ref match the policy and whose commit the
#     certificate names, each fault with its own message; an overlay holding anything else is refused;
#   - plan.sh and values-check.sh on a pull request: one that changes only the policy's values (an overlay turning
#     provenance on, or values.yaml) runs the values check on every release in the values, one of docs/ only on none;
#   - gitops_no_provenance of deploy/ci/verify/gitops.sh: the newest web release in the history of web.yaml that the
#     fake cosign finds signed without provenance, passing over without cosign a release built from a commit holding
#     provenance-predicate.sh; none found and an error of cosign each exit with their own status;
#   - changed-services.sh builds all seven images for a change of platform.sh, as for common.sh, and none for a change
#     of this test, of platform-guard.sh, of a scenario file under deploy/ci/verify/, of the policy's values or of
#     docs/; all seven for a change of the GRYPE_IMAGE line of the Makefile, none for another line of it;
#   - platform-guard.sh reads the scenario files under deploy/ci/verify/ too.
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
# gh/pulls.json for the pull requests of a commit (none when the file is missing), and gh/events.json otherwise, run through its --jq filter; run download writes the file image-digest into its --dir.
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
  path=$4
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  case $path in
  */actions/workflows/*/runs) file=$FAKE_GH_DIR/runs.json ;;
  */actions/runs/*/artifacts)
    id=${path%/artifacts}
    file=$FAKE_GH_DIR/artifacts-${id##*/}.json
    [ -f "$file" ] || file=$FAKE_GH_DIR/no-artifacts.json
    ;;
  */commits/*/pulls)
    file=$FAKE_GH_DIR/pulls.json
    [ -f "$file" ] || file=$FAKE_GH_DIR/no-pulls.json
    ;;
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

# on PLATFORM COMMAND...: runs COMMAND with the variables of PLATFORM and none of the others': github (a made-up job of
# repository octo/repo), local (none), gitlab (GitLab CI's own). git reads no configuration of this machine.
on() {
  local platform=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u GITHUB_REF -u GITHUB_SHA -u GITHUB_EVENT_NAME
    -u GITHUB_EVENT_PATH -u RUNNER_TEMP -u CI -u GITLAB_CI -u JENKINS_URL
    -u TF_BUILD -u GIT_DIR -u GIT_WORK_TREE -u PROMOTE_DRY_RUN -u PROMOTE_DRY_RUN_PRS -u RUNNER_ENVIRONMENT
    -u FAKE_GH_FAIL -u FAKE_GH_DOWNLOAD_FAIL
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
out=$(on github env -u GITHUB_SHA "$BASH" -c '. "$0"; ci_commit' "$here/platform.sh" 2>&1) &&
  fail "github: no GITHUB_SHA fails" || same "github: no GITHUB_SHA fails, naming it" \
  "FAIL  GITHUB_SHA is empty: the CI platform sets it for every job" "$out"
same "github: the bot" 'github-actions[bot] 41898282+github-actions[bot]@users.noreply.github.com' \
  "$(fn github 'echo "$(ci_bot_name) $(ci_bot_email)"')"

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
got=$(fn local 'ci_change_request_write "" bot/promote main "chore(release): x" /tmp/body')
same "local: a pull request is printed, not written" "dry run: gh $(gh_line pr create \
  --repo anhnvcoder/short-video-platform --base main --head bot/promote --title "chore(release): x" \
  --body-file /tmp/body)" "$got "
check "local: gh is not called to write" test ! -s "$work/gh.log"
same "local: the dispatch hint" "gh workflow run images.yml --ref main -f rescan=true -f values_ref=abc" \
  "$(fn local 'ci_dispatch_hint images.yml main rescan=true values_ref=abc')"
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
# policy's values and the seven values files (the gateway released at the first commit). GIT_DIR is set for every git
# call of the test itself, so git can never reach another repository.
tree=$work/tree
mkdir -p "$tree/deploy/k8s/values/services" "$tree/deploy/helm/svp-policy" "$tree/docs"
cp -R "$here" "$tree/deploy/ci"
cp "$src/deploy/k8s/lib.sh" "$tree/deploy/k8s/"
cp "$src/deploy/helm/svp-policy/values.yaml" "$tree/deploy/helm/svp-policy/"
echo "# A decision" >"$tree/docs/decision.md"
for svc in gateway user-service video-service engagement-service feed-service media-worker web; do
  printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/%s\n  tag: ""\n  digest: ""\n' "$svc" \
    >"$tree/deploy/k8s/values/services/$svc.yaml"
done
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
printf 'image:\n  repository: ghcr.io/anhnvcoder/short-video-platform/gateway\n  tag: "%s"\n  digest: "%s"\n' \
  "${base:0:12}" "$digest_a" >"$tree/deploy/k8s/values/services/gateway.yaml"
g commit -qam "release gateway" && g push -q origin main

# plan.sh: a drill run on main hands its seven outputs on, in this order, and writes its summary.
want_plan='mode=drill
images=["drill-vulnerable","drill-unsigned"]
legs={"include":[{"image":"drill-vulnerable","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-vulnerable","arch":"arm64","runner":"ubuntu-24.04-arm"},{"image":"drill-unsigned","arch":"amd64","runner":"ubuntu-24.04"},{"image":"drill-unsigned","arch":"arm64","runner":"ubuntu-24.04-arm"}]}
has_images=true
base=
values_changed=false
values_ref='
fresh
got=$(on github env EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on github: nothing on stdout" "" "$got"
same "plan.sh on github: the seven outputs in GITHUB_OUTPUT" "$want_plan" "$(cat "$work/output")"
same "plan.sh on github: the summary" "Mode: drill. Images: drill-vulnerable drill-unsigned." "$(cat "$work/summary")"
got=$(on local env EVENT_NAME=workflow_dispatch GIT_REF=refs/heads/main INPUT_DRILL=true "$tree/deploy/ci/plan.sh")
same "plan.sh on a machine: summary then outputs on stdout" \
  "Mode: drill. Images: drill-vulnerable drill-unsigned."$'\n'"$want_plan" "$got"

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

# values-check.sh: the identity cosign is asked for is the policy's (the values Kyverno checks), and a failed check
# prints and summarizes the dispatch that refreshes the attestations.
fresh
if on github env PR_NUMBER=42 "$tree/deploy/ci/values-check.sh" "" >/dev/null 2>"$work/vc.err"; then
  fail "values-check.sh: an unsigned release fails"
else ok "values-check.sh: an unsigned release fails"; fi
same "values-check.sh: cosign is asked for the policy's issuer and subject" \
  "verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/short-video-platform/gateway@$digest_a" \
  "$(cat "$work/cosign.log")"
hint="gh workflow run images.yml --ref main -f rescan=true -f values_ref=refs/pull/42/head"
check "values-check.sh: the dispatch in the log" has "$work/vc.err" "  $hint"
same "values-check.sh: the dispatch in the summary" "values-check failed: refresh the vuln attestations with \`$hint\`; a missing provenance needs a new release (above)" "$(cat "$work/summary")"

# promote.sh: a dry run on github, then a run on a machine, in the throwaway checkout. The gateway of this run is a
# newer build of the commit main runs, so it wins; the branch is pushed to the throwaway origin for real.
mkdir -p "$work/releases/release-gateway"
echo ghcr.io/anhnvcoder/short-video-platform/gateway >"$work/releases/release-gateway/repository"
echo "${base:0:12}" >"$work/releases/release-gateway/tag"
echo "$digest_b" >"$work/releases/release-gateway/digest"
title="chore(release): phát hành gateway ${base:0:12}"
fresh
on github env PROMOTE_DRY_RUN=1 "$tree/deploy/ci/promote.sh" "$work/releases" >"$work/promote.out" 2>&1 ||
  fail "promote.sh dry run on github exits 0 ($(tail -n 1 "$work/promote.out"))"
check "promote.sh dry run: no gh call at all" test ! -s "$work/gh.log"
line=$(grep '^dry run: gh ' "$work/promote.out" || true)
case $line in
"dry run: gh pr create --repo octo/repo --base main --head bot/promote --title "*" --body-file "*)
  ok "promote.sh dry run on github: the pull request it would open, for the job's repository" ;;
*) fail "promote.sh dry run on github: the pull request it would open (got '$line')" ;;
esac
check "promote.sh dry run on github: the body links the run" has "$work/promote.out" \
  "dry run: body | Lượt chạy: https://github.example/octo/repo/actions/runs/4242"
# origin GIT_ARGS...: git in the throwaway origin.
origin() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git --git-dir="$work/origin.git" "$@"; }
same "promote.sh dry run on github: the summary" \
  "Promote: \`bot/promote\` at $(origin rev-parse --short=12 bot/promote): $title" "$(cat "$work/summary")"
same "promote.sh: the branch is the bot's commit" \
  "github-actions[bot] 41898282+github-actions[bot]@users.noreply.github.com $title" \
  "$(origin log -1 --format='%an %ae %s' bot/promote)"
same "promote.sh: the branch carries this run's digest" "  digest: \"$digest_b\"" \
  "$(origin show bot/promote:deploy/k8s/values/services/gateway.yaml | grep '^  digest:')"

# On a machine only an origin on its own disk takes the push. A release of a newer build of the same commit (digest c)
# makes every run below reach the push. An origin off the disk (https, host:path; never reached: the script refuses
# before reading anything) stops the run, naming PROMOTE_DRY_RUN=1 and not the URL; with PROMOTE_DRY_RUN=1 and a push
# URL off the disk (fetches still go to the throwaway origin) the push is printed instead. The branch never moves.
digest_c=sha256:$(printf 'c%.0s' $(seq 64))
mkdir -p "$work/releases-c/release-gateway"
cp "$work/releases/release-gateway/repository" "$work/releases/release-gateway/tag" "$work/releases-c/release-gateway/"
echo "$digest_c" >"$work/releases-c/release-gateway/digest"
pushed=$(origin rev-parse bot/promote)
refusal="FAIL  origin is not a repository on this machine's disk: only CI pushes bot/promote there, since its pull request belongs to CI. PROMOTE_DRY_RUN=1 runs everything else and prints the push and the pull request"
for url in https://example.invalid/octo/repo.git git@example.invalid:octo/repo.git; do
  g remote set-url origin "$url"
  fresh
  if on local "$tree/deploy/ci/promote.sh" "$work/releases-c" >"$work/promote.out" 2>&1; then
    fail "promote.sh on a machine, origin $url: refused"
  else
    same "promote.sh on a machine, origin $url: refused before anything else, naming PROMOTE_DRY_RUN=1" "$refusal" \
      "$(cat "$work/promote.out")"
  fi
  check "promote.sh on a machine, origin $url: no gh call" test ! -s "$work/gh.log"
done
g remote set-url origin "$work/origin.git"
g remote set-url --push origin https://example.invalid/octo/repo.git
fresh
on local env PROMOTE_DRY_RUN=1 "$tree/deploy/ci/promote.sh" "$work/releases-c" >"$work/promote.out" 2>&1 ||
  fail "promote.sh dry run on a machine, push URL off the disk, exits 0 ($(tail -n 1 "$work/promote.out"))"
check "promote.sh dry run on a machine, push URL off the disk: the push is printed" has "$work/promote.out" \
  "dry run: git push --quiet --force-with-lease=refs/heads/bot/promote:$pushed origin "
check "promote.sh dry run on a machine, push URL off the disk: not pushed" lacks "$work/promote.out" "ok    pushed"
check "promote.sh dry run on a machine: the pull request and its body are printed" has "$work/promote.out" \
  "dry run: body | Lượt chạy: local"
check "promote.sh dry run on a machine: no gh call" test ! -s "$work/gh.log"
same "promote.sh on a machine, origin off the disk: the branch did not move" "$pushed" "$(origin rev-parse bot/promote)"
g config --unset remote.origin.pushurl

# git push origin pushes to every push URL: one off the disk among them, first or second, refuses the run as one alone
# does. So does a URL on the disk that pushInsteadOf turns into one off it. No URL is printed.
off_disk=https://example.invalid/octo/repo.git
for order in "$work/origin.git $off_disk" "$off_disk $work/origin.git" pushinsteadof; do
  if [ "$order" = pushinsteadof ]; then
    g config "url.$off_disk.pushInsteadOf" "$work/origin.git"
  else
    for url in $order; do g remote set-url --add --push origin "$url"; done
  fi
  fresh
  if on local "$tree/deploy/ci/promote.sh" "$work/releases-c" >"$work/promote.out" 2>&1; then
    fail "promote.sh on a machine, push URLs ($order): refused"
  else
    same "promote.sh on a machine, push URLs ($order): refused before anything else, no URL printed" "$refusal" \
      "$(cat "$work/promote.out")"
  fi
  check "promote.sh on a machine, push URLs ($order): no gh call" test ! -s "$work/gh.log"
  same "promote.sh on a machine, push URLs ($order): the branch did not move" "$pushed" "$(origin rev-parse bot/promote)"
  g config --unset-all remote.origin.pushurl || g config --remove-section "url.$off_disk"
done

# With the throwaway origin, as before: pushed for real, the pull request printed.
fresh
on local "$tree/deploy/ci/promote.sh" "$work/releases-c" >"$work/promote.out" 2>&1 ||
  fail "promote.sh on a machine exits 0 ($(tail -n 1 "$work/promote.out"))"
same "promote.sh on a machine: gh only lists, never writes" "$(gh_line pr list \
  --repo anhnvcoder/short-video-platform --head bot/promote --base main --state open --limit 500 \
  --json number,isCrossRepository,author)" "$(cat "$work/gh.log")"
check "promote.sh on a machine: the pull request is printed" has "$work/promote.out" \
  "dry run: gh pr create --repo anhnvcoder/short-video-platform --base main --head bot/promote --title "
check "promote.sh on a machine: the summary on stdout" has "$work/promote.out" "Promote: \`bot/promote\` at "
check "promote.sh on a machine, origin on the disk: pushed" has "$work/promote.out" "ok    pushed bot/promote "
same "promote.sh on a machine, origin on the disk: the branch carries the new digest" "  digest: \"$digest_c\"" \
  "$(origin show bot/promote:deploy/k8s/values/services/gateway.yaml | grep '^  digest:')"

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

# --- changed-services.sh: platform.sh is part of the image pipeline (common.sh sources it), so a change of it builds
# all seven; this test, platform-guard.sh, provenance-predicate-test.sh, the scripts of the verification runs, the
# policy's values and docs/ are read by no image job.
changed_by() {
  echo "# changed" >>"$tree/$1"
  g commit -qam "change $1"
  on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
all="engagement-service feed-service gateway media-worker user-service video-service web"
same "changed-services: a change of platform.sh builds all seven" "$all" "$(changed_by deploy/ci/platform.sh)"
same "changed-services: a change of platform-test.sh builds nothing" "" "$(changed_by deploy/ci/platform-test.sh)"
same "changed-services: a change of platform-guard.sh builds nothing" "" "$(changed_by deploy/ci/platform-guard.sh)"
same "changed-services: a change of provenance-predicate-test.sh builds nothing" "" \
  "$(changed_by deploy/ci/provenance-predicate-test.sh)"
same "changed-services: a change under deploy/ci/verify/ builds nothing" "" "$(changed_by deploy/ci/verify/gitops.sh)"
same "changed-services: a change of verify-tempo.sh builds nothing" "" "$(changed_by deploy/ci/verify-tempo.sh)"
same "changed-services: a change of gitops-sourcemaps.sh builds nothing" "" "$(changed_by deploy/ci/gitops-sourcemaps.sh)"
same "changed-services: a change of gitops-sourcemaps-test.sh builds nothing" "" \
  "$(changed_by deploy/ci/gitops-sourcemaps-test.sh)"
same "changed-services: a change of common.sh builds all seven" "$all" "$(changed_by deploy/ci/common.sh)"
same "changed-services: a change of the policy's values builds nothing" "" \
  "$(changed_by deploy/helm/svp-policy/values.yaml)"
same "changed-services: a change under docs/ builds nothing" "" "$(changed_by docs/decision.md)"
# The Makefile counts only for the lines pinning the tools of the gate.
printf 'TRIVY_IMAGE := trivy@sha256:1\nGRYPE_IMAGE := grype@sha256:1\nK6_IMAGE := k6@sha256:1\n' >"$tree/Makefile"
g add Makefile && g commit -qm "add the Makefile"
sed 's/^GRYPE_IMAGE := grype@sha256:1$/GRYPE_IMAGE := grype@sha256:2/' "$tree/Makefile" >"$work/Makefile" &&
  cp "$work/Makefile" "$tree/Makefile" && g commit -qam "bump grype"
same "changed-services: a change of the GRYPE_IMAGE line builds all seven" "$all" \
  "$(on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null)"
same "changed-services: a change of another line of the Makefile builds nothing" "" "$(changed_by Makefile)"

# --- verify-release.sh: build provenance, only where the policy checks it. A copy of the throwaway checkout, whose
# history the cases below change freely; the fake cosign answers from $fx.
vr=$work/vr
cp -R "$tree" "$vr"
gv() {
  GIT_DIR=$vr/.git GIT_WORK_TREE=$vr GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=test \
    -c user.email=test@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
fx=$work/cosign-fixtures
mkdir -p "$fx" "$vr/deploy/k8s/envs/stg" "$vr/deploy/k8s/envs/prd"
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
# release NAME WANT_RC [ARGS...]: verify-release.sh [ARGS...] web $digest_a on a machine, output in vr.out.
release() {
  local name=$1 want=$2 rc=0
  shift 2
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/verify-release.sh" "$@" "$image" "$digest_a" >"$work/vr.out" 2>&1 ||
    rc=$?
  same "verify-release.sh: $name (exit $want)" "$want" "$rc"
}
overlay() { printf 'imageVerification:\n  requireProvenance: %s\n' "$2" >"$vr/deploy/k8s/envs/$1/svp-policy.yaml"; }

rm -f "$fx/slsaprovenance1.jsonl"
release "provenance off everywhere: signature and vuln only" 0
check "verify-release.sh: provenance off: no provenance asked for" lacks "$work/cosign.log" slsaprovenance1
check "verify-release.sh: provenance off: the ok line names no provenance" lacks "$work/vr.out" "provenance of"

overlay stg true
release "on in the stg overlay, the release has no provenance" 1
check "verify-release.sh: names the missing provenance and the release to build again" has "$work/vr.out" \
  "has no provenance attestation of images.yml on main, which the policy requires here: a release built before CI attested provenance; release it again (gh workflow run images.yml --ref main -f services=web)"
release "on in stg only, checked for prd: no provenance needed" 0 --env prd
check "verify-release.sh: for prd no provenance asked for" lacks "$work/cosign.log" slsaprovenance1

provenance
release "on, a provenance that matches the policy and the certificate" 0
check "verify-release.sh: the ok line names the provenance's commit" has "$work/vr.out" \
  "provenance of ${commit:0:12} by $subject"
check "verify-release.sh: the certificate is asked for the provenance's commit" has "$work/cosign.log" \
  "verify-attestation --type slsaprovenance1 --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity $subject --certificate-github-workflow-sha $commit $image@$digest_a"

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

# At a commit (--rev, as deploy/k8s/gitops.sh reads it), not the working tree.
rm -f "$fx/slsaprovenance1.jsonl"
before=$(gv rev-parse HEAD)
gv add -A deploy/k8s/envs && gv commit -qm "provenance on in stg"
on_stg=$(gv rev-parse HEAD)
rm "$vr/deploy/k8s/envs/stg/svp-policy.yaml"
release "off in the working tree" 0
release "on at a commit (--rev --env stg), no provenance" 1 --rev "$on_stg" --env stg
check "verify-release.sh: on at a commit: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
release "at the commit before (--rev), off" 0 --rev "$before" --env stg

# On in the base values: every environment without an overlay inherits it; one that turns it off is off.
sed 's/^  requireProvenance: false$/  requireProvenance: true/' "$tree/deploy/helm/svp-policy/values.yaml" \
  >"$vr/deploy/helm/svp-policy/values.yaml"
release "on in the base values, no provenance" 1
check "verify-release.sh: on in the base values: the provenance is missing" has "$work/vr.out" "has no provenance attestation"
overlay stg false
release "on in the base, off in the stg overlay, checked for stg" 0 --env stg
release "on in the base, prd without overlay, checked for any environment" 1
cp "$tree/deploy/helm/svp-policy/values.yaml" "$vr/deploy/helm/svp-policy/values.yaml"

# Overlays of another shape: refused, never read as off.
printf 'imageVerification:\n  requireProvenance: "true"\n' >"$vr/deploy/k8s/envs/stg/svp-policy.yaml"
release "an overlay with a quoted value" 1
check "verify-release.sh: a quoted value: names the overlay" has "$work/vr.out" \
  "deploy/k8s/envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification:\n  requireProvenance: false\n  mode: Audit\n' >"$vr/deploy/k8s/envs/stg/svp-policy.yaml"
release "an overlay that sets another key" 1
check "verify-release.sh: another key: names the overlay" has "$work/vr.out" \
  "deploy/k8s/envs/stg/svp-policy.yaml: the overlay of svp-policy holds exactly"
printf 'imageVerification: {requireProvenance: true}\n' >"$vr/deploy/k8s/envs/stg/svp-policy.yaml"
release "an overlay in flow style" 1
check "verify-release.sh: an overlay refused: cosign never asked" test ! -s "$work/cosign.log"

# --- plan.sh and values-check.sh in the copy: a pull request that changes only the policy's values (the one that turns
# provenance on) runs the values check on every release in the values; one that changes docs/ only checks nothing.
overlay stg false
gv add deploy/k8s/envs/stg/svp-policy.yaml && gv commit -qm "provenance off in stg"
gv update-ref refs/remotes/origin/main HEAD
pr_base=$(gv rev-parse HEAD)
echo "# Another decision" >>"$vr/docs/decision.md"
gv add docs/decision.md && gv commit -qm "a decision"
# plan_values NAME WANT: plan.sh of a pull request into main hands on values_changed=WANT.
plan_values() {
  fresh
  on github env EVENT_NAME=pull_request GIT_REF=refs/pull/7/merge PR_BASE_REF=main "$vr/deploy/ci/plan.sh" \
    >/dev/null 2>&1 || fail "plan.sh: $1: exits 0"
  same "plan.sh: $1" "values_changed=$2" "$(grep '^values_changed=' "$work/output")"
}
# values_check NAME WANT_RC: values-check.sh with the pull request's base, on a machine, output in vc.out.
values_check() {
  local rc=0
  fresh
  on local env FAKE_COSIGN_DIR="$fx" "$vr/deploy/ci/values-check.sh" "$pr_base" >"$work/vc.out" 2>&1 || rc=$?
  same "values-check.sh: $1 (exit $2)" "$2" "$rc"
}
plan_values "a pull request of docs/ only runs no values check" false
values_check "docs/ only: nothing to check" 0
check "values-check.sh: docs/ only: cosign never asked" test ! -s "$work/cosign.log"
overlay stg true
gv add deploy/k8s/envs/stg/svp-policy.yaml && gv commit -qm "provenance on in stg"
plan_values "a pull request that turns provenance on in an overlay runs the values check" true
values_check "provenance turned on, a release in the values has none" 1
check "values-check.sh: provenance turned on: says the policy's values changed" has "$work/vc.out" \
  "note  the values of chart svp-policy changed since ${pr_base:0:12} (deploy/k8s/envs/stg/svp-policy.yaml)"
check "values-check.sh: provenance turned on: names the release without provenance" has "$work/vc.out" \
  "ghcr.io/anhnvcoder/short-video-platform/gateway@$digest_a has no provenance attestation"
check "values-check.sh: provenance turned on: every service is read" has "$work/vc.out" "ok    web: no digest"
provenance
values_check "provenance turned on, the release has it" 0
echo "# A comment" >>"$vr/deploy/helm/svp-policy/values.yaml"
gv add deploy/helm/svp-policy/values.yaml && gv commit -qm "a comment in the policy's values"
plan_values "a change of the policy's values.yaml runs the values check" true

# --- gitops_no_provenance (deploy/ci/verify/gitops.sh) in the copy: the newest web release in the history of web.yaml
# that cosign finds signed without provenance. A release built from a commit holding provenance-predicate.sh is passed
# over without asking cosign; an error of cosign is never "no provenance".
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
