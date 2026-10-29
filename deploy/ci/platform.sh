# shellcheck shell=bash
# The one place that knows which CI platform runs a script and how to talk to it. The scripts under deploy/ci/, and
# the scripts of deploy/k8s/ that hint at a CI run or read the repository host's API, call these functions instead of
# reading the platform's variables or calling its CLI: moving CI to another platform is then a new branch in each
# function below (and new workflow files that call the same make targets and scripts), not a hunt through every
# script. Sourcing it only defines functions; common.sh sources it, and so do the scripts that do not source common.sh.
# Written for bash 3.2 too (macOS).
#
# Two platforms are implemented, told apart by ci_platform:
#   github  a job of GitHub Actions (GITHUB_ACTIONS=true): outputs, the job summary and masks through the files and
#           workflow commands of the runner; pull requests, dispatches and events through gh, with the job's token.
#   local   a machine: outputs and summaries go to stdout, nothing is masked (there is no log to hide a value from),
#           and nothing is written through the platform's API: a write prints the command it would run instead. Reads
#           (open pull requests, events) still reach GitHub, where the repository lives, through the machine's gh login.
# Any other CI stops the script that asks: guessing where an output, a summary or a mask goes would lose it silently,
# and a step whose output is lost looks green.
#
# What a gitlab branch would use (GitLab CI, gitlab.com or a self-managed instance):
#   ci_platform           GITLAB_CI=true
#   ci_output             no output file per step: a dotenv report (artifacts:reports:dotenv, one line per value, 5 KB)
#                         that later jobs read; between steps of one job, a shell variable
#   ci_summary            no job summary: the job log, or a file in the job's artifacts
#   ci_mask               no command masks a value made during a job: only variables masked in the project's
#                         settings are hidden, so a value read at run time must never reach the log at all
#   ci_warning            no annotation: a plain line
#   ci_temp_dir           no runner temp directory: ${TMPDIR:-/tmp}
#   ci_repo               CI_PROJECT_PATH
#   ci_run_id             CI_PIPELINE_ID
#   ci_run_url            CI_PIPELINE_URL
#   ci_run_attempt_url    CI_JOB_URL (a retried job gets a new id; there is no attempt number)
#   ci_builder_id         https:// + the ci_config_ref_uri claim of the id_tokens token
#                         (<host>/<CI_PROJECT_PATH>//<CI_CONFIG_PATH>@refs/heads/<branch>), which is also the subject
#                         of a keyless signature made with it
#   ci_repo_url           CI_PROJECT_URL
#   ci_ref                refs/heads/CI_COMMIT_BRANCH (refs/tags/CI_COMMIT_TAG for a tag pipeline)
#   ci_commit             CI_COMMIT_SHA
#   ci_workflow_path/_ref CI_CONFIG_PATH, and the ref of the ci_config_ref_uri claim
#   ci_dispatch_input     no variable holds a pipeline's inputs (they are written into the configuration as
#                         $[[ inputs.NAME ]]), so the pipeline hands each one to the job in a variable of its own
#   ci_bot_name/_email   the bot user of the project access token the promote job pushes with
#   ci_git_auth           a credential helper that answers with that token (username any non-empty name, password the
#                         token) for HTTPS pushes to the configuration project
#   ci_change_request_*   merge requests (glab mr list, glab mr create, glab mr update), with that token: the job's own
#                         CI_JOB_TOKEN may read merge requests but not open one; auto-merge is "merge when pipeline
#                         succeeds" (glab mr merge --auto-merge)
#   ci_dispatch_hint      glab ci run with --input (pipeline variables are turned off for new projects on gitlab.com),
#                         with --repo naming the code project
#   ci_push_time          the project's push events, from GitLab's events API
#   ci_hosted_runner      no variable says a runner is GitLab's own: gitlab.com's hosted runners carry tags
#                         (saas-linux-*) that a project's own runner may carry too, so false until a job can prove it
#   ci_artifact_runs      the pipelines API (sha=, status, source push or web), then each pipeline's jobs: an artifact
#                         belongs to a job there (artifacts:name), and expires at the job's artifacts expire_at
#   ci_artifact_fetch     the job artifacts API with the job's id (glab job artifact), with the job's CI_JOB_TOKEN
#   ci_is_run_url         CI_SERVER_URL/<code project>/-/pipelines/<id>
#   ci_run_workflow       the pipelines API (GET .../pipelines/<id>): its ref; a project has one configuration file, so
#                         the pipeline's source (schedule, web) and the jobs it ran tell the scenario run apart
#   ci_deployment_record  the deployments API of the configuration project (POST .../deployments with status success,
#                         ref the commit, an environment of that name), with the project access token; a deployment
#                         there holds no payload, so the record's JSON goes into a file of a release or a commit
#                         note the check reads back
#   ci_deployment_list    the deployments API of the configuration project, environment=<name>, newest first
# CI_SERVER_URL is the instance's own URL, so on a self-managed instance every URL above starts with the company's
# domain, not gitlab.com.

# _ci_fail WORDS...: the error line of every function below; they return 1 and leave exiting to the caller.
_ci_fail() { echo "FAIL  $*" >&2; }

# _ci_need NAME: prints the variable NAME, which the platform sets for every job; fails naming it when it is empty.
_ci_need() {
  local value=${!1:-}
  [ -n "$value" ] || {
    _ci_fail "$1 is empty: the CI platform sets it for every job"
    return 1
  }
  printf '%s\n' "$value"
}

# ci_platform: prints github or local; fails on any other CI. GitHub Actions, GitLab CI, Bitbucket Pipelines and most
# others set CI=true; Jenkins sets JENKINS_URL, Azure Pipelines TF_BUILD. CI=false (or 0) on a machine, which some
# build tools read, is not a CI.
ci_platform() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo github
    return 0
  fi
  local which=
  if [ -n "${GITLAB_CI:-}" ]; then
    which="GitLab CI"
  elif [ -n "${JENKINS_URL:-}" ]; then
    which=Jenkins
  elif [ -n "${TF_BUILD:-}" ]; then
    which="Azure Pipelines"
  elif [ -n "${CI:-}" ] && [ "$CI" != false ] && [ "$CI" != 0 ]; then
    which="a CI that sets CI=$CI"
  fi
  if [ -n "$which" ]; then
    _ci_fail "this runs on $which, but only GitHub Actions and local runs are implemented;" \
      "add a branch in deploy/ci/platform.sh for another CI"
    return 1
  fi
  echo local
}

# ci_output KEY VALUE: hands VALUE to the steps and jobs after this one under KEY (a step output on GitHub); prints
# KEY=VALUE on a machine. One line only: a value of several lines needs the platform's multi-line form.
ci_output() {
  local platform file
  platform=$(ci_platform) || return 1
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    _ci_fail "output name '$1' is not a plain name"
    return 1
  }
  case $2 in *$'\n'* | *$'\r'*)
    _ci_fail "output $1 holds a line break: outputs are one line"
    return 1
    ;;
  esac
  case $platform in
  github)
    file=$(_ci_need GITHUB_OUTPUT) || return 1
    printf '%s=%s\n' "$1" "$2" >>"$file"
    ;;
  local) printf '%s=%s\n' "$1" "$2" ;;
  esac
}

# ci_summary [LINE...]: adds LINEs (stdin when none) to the summary page of the job; prints them on a machine.
ci_summary() {
  local platform file
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    file=$(_ci_need GITHUB_STEP_SUMMARY) || return 1
    if [ $# -gt 0 ]; then printf '%s\n' "$@" >>"$file"; else cat >>"$file"; fi
    ;;
  local) if [ $# -gt 0 ]; then printf '%s\n' "$@"; else cat; fi ;;
  esac
}

# ci_has_summary: true when the job summary is a page apart from the log (so a line written there only is not in the
# log); false on a machine, where ci_summary prints.
ci_has_summary() {
  local platform
  platform=$(ci_platform) || return 1
  [ "$platform" = github ]
}

# ci_summary_tee: copies stdin to stdout and, where the job summary is a page of its own, to the summary too.
ci_summary_tee() {
  local platform file
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    file=$(_ci_need GITHUB_STEP_SUMMARY) || return 1
    tee -a "$file"
    ;;
  local) cat ;;
  esac
}

# ci_mask VALUE: hides VALUE wherever the job's log shows it from now on. On GitHub the mask command's data reads %25
# as %, so a % of the value is written that way. A machine prints nothing: there, the command would print the value.
ci_mask() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) printf '::add-mask::%s\n' "${1//%/%25}" ;;
  local) ;;
  esac
}

# ci_warning MESSAGE: a warning the run's page shows beside the log line (an annotation on GitHub); a plain line on a
# machine.
ci_warning() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) printf '::warning::%s\n' "$1" ;;
  local) printf 'warning: %s\n' "$1" ;;
  esac
}

# ci_temp_dir: a directory for the job's own files, emptied when the job ends (RUNNER_TEMP on GitHub); /tmp on a
# machine.
ci_temp_dir() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need RUNNER_TEMP ;;
  local) echo /tmp ;;
  esac
}

# The code repository (owner/name on its host): the one that holds deploy/ci/ and the workflows that build, sign and
# promote releases. Change it here when the repository moves.
_ci_code_repo=anhnvcoder/short-video-platform

# ci_repo: owner/name of the repository on its host. On a machine, the code repository's.
ci_repo() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_REPOSITORY ;;
  local) echo "$_ci_code_repo" ;;
  esac
}

# ci_run_id: the id of this workflow run, the same for every job and attempt of it; "local" on a machine.
ci_run_id() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_RUN_ID ;;
  local) echo local ;;
  esac
}

# ci_run_url: the page of this run; "local" on a machine.
ci_run_url() {
  local platform server repo id
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && repo=$(_ci_need GITHUB_REPOSITORY) && id=$(_ci_need GITHUB_RUN_ID) ||
      return 1
    echo "$server/$repo/actions/runs/$id"
    ;;
  local) echo local ;;
  esac
}

# ci_run_attempt_url: the page of this attempt of the run (a re-run is a new attempt of the same run); "local" on a
# machine.
ci_run_attempt_url() {
  local platform url
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    url=$(ci_run_url) || return 1
    echo "$url/attempts/${GITHUB_RUN_ATTEMPT:-1}"
    ;;
  local) echo local ;;
  esac
}

# ci_builder_id: the workflow file that runs this job, at the ref it ran from, as a URL: the builder an attestation
# names, and the subject of the keyless certificate this job gets (server URL + job_workflow_ref on GitHub); "local" on
# a machine.
ci_builder_id() {
  local platform server ref
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && ref=$(_ci_need GITHUB_WORKFLOW_REF) || return 1
    echo "$server/$ref"
    ;;
  local) echo local ;;
  esac
}

# ci_repo_url: the web address of the repository on its host. On a machine, this repository's on GitHub.
ci_repo_url() {
  local platform server repo
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    server=$(_ci_need GITHUB_SERVER_URL) && repo=$(_ci_need GITHUB_REPOSITORY) || return 1
    echo "$server/$repo"
    ;;
  local) echo "https://github.com/$(ci_repo)" ;;
  esac
}

# ci_ref: the git ref this run was started for (refs/heads/main for a push to main or a dispatch on it); "local" on a
# machine.
ci_ref() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_REF ;;
  local) echo local ;;
  esac
}

# ci_commit: the full SHA of the commit this run checked out and builds. On a machine, HEAD of the checkout this file
# is in, which is what a build there starts from.
ci_commit() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_SHA ;;
  local) git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --verify HEAD ;;
  esac
}

# _ci_workflow_ref_parts: on GitHub, prints the path of the workflow file that runs this job and the ref it was read
# at, one per line, from GITHUB_WORKFLOW_REF (<owner>/<repo>/<path>@<ref>). Fails when that is not a file of this
# repository at a ref.
_ci_workflow_ref_parts() {
  local whole repo rest
  whole=$(_ci_need GITHUB_WORKFLOW_REF) && repo=$(_ci_need GITHUB_REPOSITORY) || return 1
  rest=${whole#"$repo"/}
  [[ $rest != "$whole" && $rest =~ ^[^@]+@.+$ ]] || {
    _ci_fail "GITHUB_WORKFLOW_REF '$whole' is not <repository>/<path>@<ref> of $repo"
    return 1
  }
  printf '%s\n%s\n' "${rest%%@*}" "${rest#*@}"
}

# ci_workflow_path: the path, in the repository, of the workflow file that runs this job (.github/workflows/images.yml);
# "local" on a machine.
ci_workflow_path() {
  local platform parts
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    parts=$(_ci_workflow_ref_parts) || return 1
    sed -n 1p <<<"$parts"
    ;;
  local) echo local ;;
  esac
}

# ci_workflow_ref: the git ref the workflow file of this job was read at (refs/heads/main); "local" on a machine.
ci_workflow_ref() {
  local platform parts
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    parts=$(_ci_workflow_ref_parts) || return 1
    sed -n 2p <<<"$parts"
    ;;
  local) echo local ;;
  esac
}

# ci_dispatch_input NAME: the value of input NAME of a run started by hand (a workflow_dispatch on GitHub, read from
# the event the platform wrote, not from a variable a step could set); nothing for a run started otherwise, for an
# input left empty, and on a machine.
ci_dispatch_input() {
  local platform event file
  platform=$(ci_platform) || return 1
  [[ ${1:-} =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
    _ci_fail "input name '${1:-}' is not a plain name"
    return 1
  }
  case $platform in
  github)
    event=$(_ci_need GITHUB_EVENT_NAME) || return 1
    [ "$event" = workflow_dispatch ] || return 0
    file=$(_ci_need GITHUB_EVENT_PATH) || return 1
    jq -r --arg name "$1" '.inputs[$name] // "" | tostring' "$file" || {
      _ci_fail "the dispatch event in $file cannot be read"
      return 1
    }
    ;;
  local) ;;
  esac
}

# ci_bot_name [APP], ci_bot_email [APP]: the author of the commits CI makes (the promote branch), as the host shows
# it: the platform's own bot, or the bot user of app APP (a GitHub App, whose token the commits are pushed with). The
# bot's address holds the id of its user, read from the host (a read, so a machine asks GitHub too). A machine commits
# the same way, so a dry run makes the very commit CI would.
ci_bot_name() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in github | local) echo "${1:-github-actions}[bot]" ;; esac
}
ci_bot_email() {
  local platform id
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    if [ -z "${1:-}" ]; then
      echo '41898282+github-actions[bot]@users.noreply.github.com'
      return 0
    fi
    _ci_name app "$1" || return 1
    id=$(gh api -X GET "users/$1%5Bbot%5D" --jq .id) || return 1
    [[ $id =~ ^[0-9]+$ ]] || {
      _ci_fail "the host names no bot user of app $1 (got id '$id')"
      return 1
    }
    echo "$id+$1[bot]@users.noreply.github.com"
    ;;
  esac
}

# ci_git_auth: prints, one per line, the git options (each for git -c) that let git push over HTTPS to the repository
# host with the token the job writes pull requests with (GH_TOKEN on GitHub, the token of an app when the job made
# one). A credential helper hands git the token when git asks for it, from the environment of that moment: it is never
# written to a file, a remote URL or a command line. Nothing on a machine, which pushes only to a repository on its own
# disk.
ci_git_auth() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github)
    [ -n "${GH_TOKEN:-}" ] || {
      _ci_fail "GH_TOKEN is empty: the job hands git the token it pushes with there"
      return 1
    }
    echo 'credential.helper='
    # shellcheck disable=SC2016 # expanded by the helper's shell when git asks, not here
    echo 'credential.helper=!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'
    ;;
  local) ;;
  esac
}

# ci_change_request_list BRANCH BASE [REPO]: prints, in the host's own form (read only by ci_change_request_pick), the
# open change requests (pull requests) from a branch named BRANCH into BASE of REPO (owner/name; ci_repo when empty).
# GitHub's --head matches the bare branch name, so a fork's pull request from a branch of that name is listed too. gh
# lists 30 by default, newest first: 30 fork pull requests from such a branch opened after the bot's would hide it. So
# the list goes up to 500 (gh pages through), and a list that comes back full fails rather than guess. A read, so a
# machine asks GitHub too.
ci_change_request_list() {
  local platform repo list
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    repo=${3:-$(ci_repo)} || return 1
    list=$(gh pr list --repo "$repo" --head "$1" --base "$2" --state open --limit 500 \
      --json number,isCrossRepository,author) || return 1
    [ "$(jq length <<<"$list")" -lt 500 ] || {
      _ci_fail "500 or more open pull requests from a branch $1: close the forks' before promoting"
      return 1
    }
    echo "$list"
    ;;
  esac
}

# ci_change_request_pick [APP]: reads a list of ci_change_request_list on stdin and prints the number of the one CI
# itself opened from the listed repository (by the platform's own bot, or by app APP when given), or nothing. A
# fork's, or one a person opened from a branch of the same name, is not CI's: counting it would bring stale values of
# the branch back, and put CI's title on someone else's diff.
ci_change_request_pick() {
  local platform
  platform=$(ci_platform) || return 1
  [ -z "${1:-}" ] || _ci_name app "$1" || return 1
  case $platform in
  github | local)
    jq -r --arg author "app/${1:-github-actions}" \
      '[.[] | select(.isCrossRepository == false and .author.login == $author)][0].number // empty'
    ;;
  esac
}

# _ci_print_or_run DRY COMMAND...: with DRY set prints the command ("dry run: gh ..."), otherwise runs it.
_ci_print_or_run() {
  local dry=$1
  shift
  if [ -n "$dry" ]; then
    printf 'dry run:'
    printf ' %q' "$@"
    echo
  else
    "$@"
  fi
}

# ci_change_request_write [--dry-run] NUMBER BRANCH BASE TITLE BODY_FILE [REPO]: updates the title and body of change
# request NUMBER of REPO (owner/name; ci_repo when empty), or, when NUMBER is empty, opens one from BRANCH into BASE.
# With --dry-run, and always on a machine, prints the command it would run instead ("dry run: gh ...").
ci_change_request_write() {
  local platform dry= repo
  platform=$(ci_platform) || return 1
  if [ "${1:-}" = --dry-run ]; then
    dry=1
    shift
  fi
  [ $# -eq 5 ] || [ $# -eq 6 ] || {
    _ci_fail "usage: ci_change_request_write [--dry-run] NUMBER BRANCH BASE TITLE BODY_FILE [REPO]"
    return 1
  }
  [ "$platform" != local ] || dry=1
  repo=${6:-$(ci_repo)} || return 1
  local args
  if [ -n "$1" ]; then
    args=(pr edit "$1" --repo "$repo" --title "$4" --body-file "$5")
  else
    args=(pr create --repo "$repo" --base "$3" --head "$2" --title "$4" --body-file "$5")
  fi
  _ci_print_or_run "$dry" gh "${args[@]}"
}

# ci_change_request_auto_merge [--dry-run] SELECTOR HEAD REPO: turns on auto-merge for the change request SELECTOR (its
# number, or its branch) of REPO: the host merges it, squashed, once the checks and reviews REPO's rules require are
# there, and only while its head is still commit HEAD (a push since then needs this asked again). With --dry-run, and
# always on a machine, prints the command it would run instead.
ci_change_request_auto_merge() {
  local platform dry=
  platform=$(ci_platform) || return 1
  if [ "${1:-}" = --dry-run ]; then
    dry=1
    shift
  fi
  [ $# -eq 3 ] && [ -n "$1" ] && [[ $2 =~ ^[0-9a-f]{40}$ ]] && [ -n "$3" ] || {
    _ci_fail "usage: ci_change_request_auto_merge [--dry-run] SELECTOR HEAD REPO (HEAD a full commit SHA)"
    return 1
  }
  [ "$platform" != local ] || dry=1
  case $platform in
  github | local) _ci_print_or_run "$dry" gh pr merge "$1" --repo "$3" --auto --squash --match-head-commit "$2" ;;
  esac
}

# ci_dispatch_hint WORKFLOW REF [NAME=VALUE...]: prints the command a person runs to start WORKFLOW of the code
# repository on REF with those inputs, for a message that asks for such a run; runs nothing. The command names the
# repository, so it starts the right workflow from any directory, a clone of svp-gitops included.
ci_dispatch_hint() {
  local platform hint kv
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    hint="gh workflow run $1 --repo $_ci_code_repo --ref $2"
    shift 2
    for kv in "$@"; do hint="$hint -f $kv"; done
    echo "$hint"
    ;;
  esac
}

# ci_push_time SHA [REPO]: prints when the push whose new head is commit SHA reached repository REPO (owner/name;
# ci_repo when empty) on its host, as one line "TIMESTAMP SOURCE": TIMESTAMP is RFC 3339, UTC, and SOURCE says where it
# was read. The time a pull request that produced SHA as its merge commit was merged comes first: it is exact and is
# there as soon as the merge is, while the host's events list is delayed on purpose and has no promise of when a push
# shows in it. Else the newest 100 events of the repository are searched for the push. Prints nothing when neither
# knows SHA. Fails, with the host's error on stderr, when either cannot be read (a failed first read is not answered
# from the second). A read, so a machine asks GitHub too.
ci_push_time() {
  local platform repo found
  platform=$(ci_platform) || return 1
  [[ $1 =~ ^[0-9a-f]{40}$ ]] || {
    _ci_fail "ci_push_time takes a full commit SHA, not '$1'"
    return 1
  }
  [ -z "${2:-}" ] || [[ $2 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    _ci_fail "ci_push_time takes a repository as owner/name, not '$2'"
    return 1
  }
  case $platform in
  github | local)
    repo=${2:-$(ci_repo)} || return 1
    found=$(gh api -X GET "repos/$repo/commits/$1/pulls" -f per_page=100 \
      --jq "[.[] | select(.merge_commit_sha == \"$1\" and .merged_at != null)] | first // empty
        | \"\(.merged_at) merged_at of PR #\(.number)\"") || return 1
    if [ -z "$found" ]; then
      found=$(gh api -X GET "repos/$repo/events" -f per_page=100 \
        --jq "[.[] | select(.type == \"PushEvent\" and .payload.head == \"$1\") | .created_at] | last // empty
          | \"\(.) PushEvent of the repository's events\"") || return 1
    fi
    [ -z "$found" ] || echo "$found"
    ;;
  esac
}

# ci_hosted_runner: true only in a job on a runner the platform hands out for that one job and then throws away (on
# GitHub, RUNNER_ENVIRONMENT=github-hosted). False on a machine and on a self-hosted runner, which may well be someone's
# own computer; prints nothing either way. A script that would touch whatever cluster sits on the machine asks this
# first: there, the cluster is the job's own.
ci_hosted_runner() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ;;
  local) return 1 ;;
  esac
}

# _ci_name WHAT VALUE: fails unless VALUE is a plain name ([A-Za-z0-9._-]), which a query to the host can hold as is.
_ci_name() {
  [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || {
    _ci_fail "$1 '$2' is not a plain name ([A-Za-z0-9._-])"
    return 1
  }
}

# ci_artifact_runs WORKFLOW COMMIT ARTIFACT: prints the id of every finished run of the workflow file WORKFLOW (a push
# or a dispatch, not a pull request) whose head is COMMIT (a full SHA) and that still holds an unexpired artifact named
# ARTIFACT, one per line, the latest started first. Every such run, whatever its conclusion: one commit can be built
# more than once, and a run that failed elsewhere may still have released this build; the caller tells the builds
# apart by what the artifact holds. Exit 0 with at least one id, 3 when there is none, 1 on any other error (the
# host's on stderr). A read, so a machine asks GitHub too.
ci_artifact_runs() {
  local platform repo runs total got id n found=
  platform=$(ci_platform) || return 1
  [ $# -eq 3 ] || {
    _ci_fail "usage: ci_artifact_runs WORKFLOW COMMIT ARTIFACT"
    return 1
  }
  _ci_name workflow "$1" && _ci_name artifact "$3" || return 1
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || {
    _ci_fail "ci_artifact_runs takes a full commit SHA, not '$2'"
    return 1
  }
  case $platform in
  github | local)
    repo=$(ci_repo) || return 1
    # The first line is the number of runs the host matched and the number on this page: a commit has far fewer than
    # 100 runs, but one more than the page holds must fail rather than be skipped.
    runs=$(gh api -X GET "repos/$repo/actions/workflows/$1/runs" -f head_sha="$2" -f status=completed -f per_page=100 \
      --jq "\"\(.total_count) \(.workflow_runs | length)\", (.workflow_runs
        | map(select(.head_sha == \"$2\" and .status == \"completed\"
          and (.event == \"push\" or .event == \"workflow_dispatch\")))
        | sort_by(.run_started_at, .id) | reverse | .[].id)") || return 1
    read -r total got <<<"$runs"
    [ "${total:-x}" = "${got:-y}" ] || {
      _ci_fail "the host has ${total:-?} finished runs of $1 at $2 but returned ${got:-?}: read the next page"
      return 1
    }
    for id in $(tail -n +2 <<<"$runs"); do
      n=$(gh api -X GET "repos/$repo/actions/runs/$id/artifacts" -f name="$3" -f per_page=100 \
        --jq "[.artifacts[] | select(.name == \"$3\" and .expired == false)] | length") || return 1
      if [ "$n" -gt 0 ]; then
        echo "$id"
        found=1
      fi
    done
    [ -n "$found" ] || return 3
    ;;
  esac
}

# ci_artifact_fetch RUN ARTIFACT DIR: downloads the artifact ARTIFACT of run RUN (a number) into DIR, an existing empty
# directory, unpacked. Exit 0 when downloaded, 3 when the run holds no unexpired artifact of that name, 1 on any other
# error (the host's on stderr). The download link is signed: it is never printed. A read, so a machine asks GitHub too.
ci_artifact_fetch() {
  local platform repo n out rc=0
  platform=$(ci_platform) || return 1
  [ $# -eq 3 ] || {
    _ci_fail "usage: ci_artifact_fetch RUN ARTIFACT DIR"
    return 1
  }
  [[ $1 =~ ^[0-9]+$ ]] || {
    _ci_fail "ci_artifact_fetch takes a run id (a number), not '$1'"
    return 1
  }
  _ci_name artifact "$2" || return 1
  [ -d "$3" ] && [ -z "$(ls -A "$3")" ] || {
    _ci_fail "$3 is not an empty directory: the artifact's files must not mix with others"
    return 1
  }
  case $platform in
  github | local)
    repo=$(ci_repo) || return 1
    n=$(gh api -X GET "repos/$repo/actions/runs/$1/artifacts" -f name="$2" -f per_page=100 \
      --jq "[.artifacts[] | select(.name == \"$2\" and .expired == false)] | length") || return 1
    [ "$n" -gt 0 ] || return 3
    # The host answers the download with a redirect to a signed link that anyone holding it can fetch the artifact
    # with until it expires. gh's debug log prints each request of it (path and query alone, past any filter), so the
    # log is turned off; and gh names the link it failed on (an HTTP error, a dropped connection), so everything it
    # prints is held back and shown with each URL cut down to its scheme and host.
    out=$(env -u GH_DEBUG -u DEBUG gh run download "$1" --repo "$repo" --name "$2" --dir "$3" 2>&1) || rc=$?
    [ -z "$out" ] || sed -E 's|([A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9.-]*)[^[:space:]"]*|\1/<hidden>|g' <<<"$out" >&2
    return $rc
    ;;
  esac
}

# ci_is_run_url URL: true when URL is the page of a run of a workflow of the code repository on its host
# (https://github.com/<code repository>/actions/runs/<id>), the form ci_run_url gives on GitHub. Prints nothing.
ci_is_run_url() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github | local) [[ ${1:-} =~ ^https://github\.com/$_ci_code_repo/actions/runs/[0-9]+$ ]] ;;
  esac
}

# ci_run_workflow URL: prints "<workflow file> <branch>" of the run at URL, a run of the code repository (the form
# ci_is_run_url takes), as the host knows it: e.g. ".github/workflows/verify.yml main". Exit 1 when URL has another
# form or the host does not answer (no such run, a network error; its message on stderr). A read, so a machine asks
# GitHub too.
ci_run_workflow() {
  local platform
  platform=$(ci_platform) || return 1
  ci_is_run_url "${1:-}" || {
    _ci_fail "ci_run_workflow takes the URL of a run of $_ci_code_repo, not '${1:-}'"
    return 1
  }
  case $platform in
  github | local)
    gh api -X GET "repos/$_ci_code_repo/actions/runs/${1##*/}" --jq '"\(.path // "") \(.head_branch // "")"'
    ;;
  esac
}

# ci_deployment_record [--dry-run] REPO ENVIRONMENT REF PAYLOAD_FILE DESCRIPTION LOG_URL: records in REPO (owner/name)
# that environment ENVIRONMENT runs commit REF (a full SHA) of REPO, with the JSON object of PAYLOAD_FILE as its
# payload and state success, its log at LOG_URL; prints the id of the record. On GitHub a deployment, then a deployment
# status:
#   - auto_merge false: the default would merge the default branch into REF first, and a record of a commit that ran
#     must never become a record of another;
#   - required_contexts []: the default asks every commit status of REF to be success, which a record made from
#     outside does not depend on;
#   - auto_inactive false on the status: the default marks every earlier success of ENVIRONMENT inactive, and an older
#     record is what a rollback promotes.
# A deployment whose status could not be written is not success, so it counts as no record (the error says so). With
# --dry-run, and always on a machine, prints the two requests and their bodies instead ("dry run: ...") and no id.
ci_deployment_record() {
  local platform dry= body status id
  platform=$(ci_platform) || return 1
  if [ "${1:-}" = --dry-run ]; then
    dry=1
    shift
  fi
  [ $# -eq 6 ] && [[ $1 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [[ $3 =~ ^[0-9a-f]{40}$ ]] && [ -n "$6" ] &&
    [[ $5$6 != *$'\n'* ]] || {
    _ci_fail "usage: ci_deployment_record [--dry-run] REPO ENVIRONMENT REF PAYLOAD_FILE DESCRIPTION LOG_URL" \
      "(REPO owner/name, REF a full commit SHA, DESCRIPTION and LOG_URL one line each)"
    return 1
  }
  _ci_name environment "$2" || return 1
  jq -e 'type == "object"' "$4" >/dev/null 2>&1 || {
    _ci_fail "the payload $4 is not one JSON object"
    return 1
  }
  [ "$platform" != local ] || dry=1
  body=$(jq -c -n --arg ref "$3" --arg env "$2" --arg d "$5" --slurpfile p "$4" '{ref: $ref, environment: $env,
    description: $d, payload: $p[0], auto_merge: false, required_contexts: [], transient_environment: false,
    production_environment: false}') &&
    status=$(jq -c -n --arg url "$6" --arg d "$5" '{state: "success", log_url: $url, description: $d,
      auto_inactive: false}') || return 1
  case $platform in
  github | local)
    if [ -n "$dry" ]; then
      echo "dry run: gh api -X POST repos/$1/deployments --input -"
      echo "dry run: body | $body"
      echo "dry run: gh api -X POST repos/$1/deployments/<id>/statuses --input -"
      echo "dry run: body | $status"
      return 0
    fi
    id=$(gh api -X POST "repos/$1/deployments" --input - --jq .id <<<"$body") || return 1
    [[ $id =~ ^[0-9]+$ ]] || {
      _ci_fail "the host made no deployment of $3 in $1 (got id '$id')"
      return 1
    }
    gh api -X POST "repos/$1/deployments/$id/statuses" --input - --jq .state <<<"$status" >/dev/null || {
      _ci_fail "deployment $id of $1 was made, but not its status success: it counts as no record"
      return 1
    }
    echo "$id"
    ;;
  esac
}

# ci_deployment_list REPO ENVIRONMENT: prints, as one JSON array, the newest 100 records of environment ENVIRONMENT in
# REPO (owner/name), newest first, each {id, sha, ref, created_at, creator, payload, state, states}: creator the login
# that made it (an app's bot is <app>[bot]), payload as recorded, state the latest status (success, failure, inactive,
# ...; "" without one), states every status the host still returns, newest first (it drops all but the latest after 90
# days): a record marked inactive by a later one shows there whether it was success before. An older record is out of
# reach: a set that old goes through the environment again. A read, so a machine asks GitHub too.
ci_deployment_list() {
  local platform list id state states=
  platform=$(ci_platform) || return 1
  [ $# -eq 2 ] && [[ $1 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    _ci_fail "usage: ci_deployment_list REPO ENVIRONMENT (REPO owner/name)"
    return 1
  }
  _ci_name environment "$2" || return 1
  case $platform in
  github | local)
    list=$(gh api -X GET "repos/$1/deployments" -f environment="$2" -f per_page=100 \
      --jq '[.[] | {id, sha, ref, created_at, creator: (.creator.login // ""), payload}]') || return 1
    for id in $(jq -r '.[].id' <<<"$list"); do
      [[ $id =~ ^[0-9]+$ ]] || {
        _ci_fail "the host lists a deployment of $1 with id '$id'"
        return 1
      }
      # The statuses come newest first: the first is the record's state.
      state=$(gh api -X GET "repos/$1/deployments/$id/statuses" -f per_page=100 --jq '[.[].state] | join(" ")') || return 1
      states+="$id $state"$'\n'
    done
    jq -c --arg states "$states" '($states | split("\n") | map(select(length > 0) | split(" ")
      | {key: .[0], value: (.[1:] | map(select(. != "")))}) | from_entries) as $s
      | map(($s[.id | tostring] // []) as $all | . + {state: ($all[0] // ""), states: $all})' <<<"$list"
    ;;
  esac
}
