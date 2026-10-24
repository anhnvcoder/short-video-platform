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
#     scan-gate.sh, values-check.sh (the signing identity is read from the policy's values) and promote.sh (a dry run
#     and a local run in a throwaway git repository with a throwaway origin; on a machine, an origin off its disk is
#     refused, or with PROMOTE_DRY_RUN=1 the push is printed, and the branch never moves);
#   - platform-guard.sh passes the throwaway checkout and fails, naming file:line, a script that reads GITHUB_OUTPUT or
#     calls gh itself;
#   - changed-services.sh builds all seven images for a change of platform.sh, as for common.sh, and none for a change
#     of this test, of platform-guard.sh, of the policy's values or of docs/.
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

# --- Fakes. gh writes each call to gh.log, one line of %q-quoted arguments, and answers pr list from gh/prs.json and
# api with gh/events.json run through its --jq filter; cosign refuses every signature and records its arguments.
mkdir -p "$work/bin" "$work/gh" "$work/runner-temp" "$work/home"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$FAKE_GH_LOG"
echo >>"$FAKE_GH_LOG"
case "$1 $2" in
"pr list") cat "$FAKE_GH_DIR/prs.json" ;;
"api -X")
  while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
  jq -r "$2" "$FAKE_GH_DIR/events.json"
  ;;
esac
EOF
cat >"$work/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_COSIGN_LOG"
echo "Error: no signatures found" >&2
exit 1
EOF
chmod 755 "$work/bin/gh" "$work/bin/cosign"
echo '[]' >"$work/gh/prs.json"

# on PLATFORM COMMAND...: runs COMMAND with the variables of PLATFORM and none of the others': github (a made-up job of
# repository octo/repo), local (none), gitlab (GitLab CI's own). git reads no configuration of this machine.
on() {
  local platform=$1
  shift
  local base=(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u GITHUB_REPOSITORY -u GITHUB_SERVER_URL
    -u GITHUB_RUN_ID -u GITHUB_RUN_ATTEMPT -u GITHUB_WORKFLOW_REF -u RUNNER_TEMP -u CI -u GITLAB_CI -u JENKINS_URL
    -u TF_BUILD -u GIT_DIR -u GIT_WORK_TREE -u PROMOTE_DRY_RUN -u PROMOTE_DRY_RUN_PRS
    PATH="$work/bin:$PATH" HOME="$work/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    FAKE_GH_LOG="$work/gh.log" FAKE_GH_DIR="$work/gh" FAKE_COSIGN_LOG="$work/cosign.log")
  case $platform in
  github)
    "${base[@]}" GITHUB_ACTIONS=true CI=true GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
      GITHUB_REPOSITORY=octo/repo GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3 \
      GITHUB_WORKFLOW_REF=octo/repo/.github/workflows/images.yml@refs/heads/main RUNNER_TEMP="$work/runner-temp" "$@"
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
same "local: a push time is read from the host's events" 2026-10-02T03:04:05Z "$(fn local "ci_push_time $sha")"
same "local: the events are read for this repository" "$(gh_line api -X GET \
  repos/anhnvcoder/short-video-platform/events -f per_page=100 --jq \
  "[.[] | select(.type == \"PushEvent\" and .payload.head == \"$sha\") | .created_at] | last // empty")" \
  "$(cat "$work/gh.log")"
if fn local 'ci_push_time "x\" or true"' 2>/dev/null; then fail "local: ci_push_time takes only a full SHA"; else
  ok "local: ci_push_time takes only a full SHA"
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
same "values-check.sh: the dispatch in the summary" "values-check failed: refresh with \`$hint\`" "$(cat "$work/summary")"

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
rc=0
on local "$tree/deploy/ci/platform-guard.sh" >"$work/guard.out" 2>&1 || rc=$?
same "platform-guard.sh: a match exits 1" 1 "$rc"
check "platform-guard.sh: names the untracked script's line" has "$work/guard.out" "deploy/ci/new-step.sh:2:"
check "platform-guard.sh: names the tracked script's line" has "$work/guard.out" \
  "deploy/ci/rescan.sh:$(wc -l <"$tree/deploy/ci/rescan.sh" | tr -d ' '):gh pr view 1"
rm "$tree/deploy/ci/new-step.sh" "$tree/deploy/ci/linked-dir"
g checkout -q -- deploy/ci/rescan.sh

# --- changed-services.sh: platform.sh is part of the image pipeline (common.sh sources it), so a change of it builds
# all seven; this test, platform-guard.sh, the policy's values and docs/ are read by no image job.
changed_by() {
  echo "# changed" >>"$tree/$1"
  g commit -qam "change $1"
  on local "$tree/deploy/ci/changed-services.sh" HEAD~1 HEAD 2>/dev/null
}
all="engagement-service feed-service gateway media-worker user-service video-service web"
same "changed-services: a change of platform.sh builds all seven" "$all" "$(changed_by deploy/ci/platform.sh)"
same "changed-services: a change of platform-test.sh builds nothing" "" "$(changed_by deploy/ci/platform-test.sh)"
same "changed-services: a change of platform-guard.sh builds nothing" "" "$(changed_by deploy/ci/platform-guard.sh)"
same "changed-services: a change of the policy's values builds nothing" "" \
  "$(changed_by deploy/helm/svp-policy/values.yaml)"
same "changed-services: a change under docs/ builds nothing" "" "$(changed_by docs/decision.md)"

if ((failures)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
