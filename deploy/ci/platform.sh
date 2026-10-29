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
#   ci_change_request_*   merge requests (glab mr list, glab mr create, glab mr update), with that token: the job's own
#                         CI_JOB_TOKEN may read merge requests but not open one
#   ci_dispatch_hint      glab ci run with --input (pipeline variables are turned off for new projects on gitlab.com)
#   ci_push_time          the project's push events, from GitLab's events API
#   ci_hosted_runner      no variable says a runner is GitLab's own: gitlab.com's hosted runners carry tags
#                         (saas-linux-*) that a project's own runner may carry too, so false until a job can prove it
#   ci_artifact_runs      the pipelines API (sha=, status, source push or web), then each pipeline's jobs: an artifact
#                         belongs to a job there (artifacts:name), and expires at the job's artifacts expire_at
#   ci_artifact_fetch     the job artifacts API with the job's id (glab job artifact), with the job's CI_JOB_TOKEN
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

# ci_repo: owner/name of the repository on its host. On a machine, this repository's: change it here when the
# repository moves.
ci_repo() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github) _ci_need GITHUB_REPOSITORY ;;
  local) echo anhnvcoder/short-video-platform ;;
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

# ci_bot_name, ci_bot_email: the author of the commits CI makes (the promote branch): the platform's own bot, as the
# host shows it. A machine commits the same way, so a dry run makes the very commit CI would.
ci_bot_name() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in github | local) echo 'github-actions[bot]' ;; esac
}
ci_bot_email() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in github | local) echo '41898282+github-actions[bot]@users.noreply.github.com' ;; esac
}

# ci_change_request_list BRANCH BASE: prints, in the host's own form (read only by ci_change_request_pick), the open
# change requests (pull requests) from a branch named BRANCH into BASE. GitHub's --head matches the bare branch name,
# so a fork's pull request from a branch of that name is listed too. gh lists 30 by default, newest first: 30 fork
# pull requests from such a branch opened after the bot's would hide it. So the list goes up to 500 (gh pages
# through), and a list that comes back full fails rather than guess. A read, so a machine asks GitHub too.
ci_change_request_list() {
  local platform repo list
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    repo=$(ci_repo) || return 1
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

# ci_change_request_pick: reads a list of ci_change_request_list on stdin and prints the number of the one CI itself
# opened from this repository, or nothing. A fork's, or one a person opened from a branch of the same name, is not
# CI's: counting it would bring stale values of the branch back, and put CI's title on someone else's diff.
ci_change_request_pick() {
  local platform
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    jq -r '[.[] | select(.isCrossRepository == false and .author.login == "app/github-actions")][0].number // empty'
    ;;
  esac
}

# ci_change_request_write [--dry-run] NUMBER BRANCH BASE TITLE BODY_FILE: updates the title and body of change request
# NUMBER, or, when NUMBER is empty, opens one from BRANCH into BASE. With --dry-run, and always on a machine, prints
# the command it would run instead ("dry run: gh ...").
ci_change_request_write() {
  local platform dry= repo
  platform=$(ci_platform) || return 1
  if [ "${1:-}" = --dry-run ]; then
    dry=1
    shift
  fi
  [ $# -eq 5 ] || {
    _ci_fail "usage: ci_change_request_write [--dry-run] NUMBER BRANCH BASE TITLE BODY_FILE"
    return 1
  }
  [ "$platform" != local ] || dry=1
  repo=$(ci_repo) || return 1
  local args
  if [ -n "$1" ]; then
    args=(pr edit "$1" --repo "$repo" --title "$4" --body-file "$5")
  else
    args=(pr create --repo "$repo" --base "$3" --head "$2" --title "$4" --body-file "$5")
  fi
  if [ -n "$dry" ]; then
    printf 'dry run: gh'
    printf ' %q' "${args[@]}"
    echo
  else
    gh "${args[@]}"
  fi
}

# ci_dispatch_hint WORKFLOW REF [NAME=VALUE...]: prints the command a person runs to start WORKFLOW on REF with those
# inputs, for a message that asks for such a run; runs nothing.
ci_dispatch_hint() {
  local platform hint kv
  platform=$(ci_platform) || return 1
  case $platform in
  github | local)
    hint="gh workflow run $1 --ref $2"
    shift 2
    for kv in "$@"; do hint="$hint -f $kv"; done
    echo "$hint"
    ;;
  esac
}

# ci_push_time SHA: prints when the push whose new head is commit SHA reached the repository host, as one line
# "TIMESTAMP SOURCE": TIMESTAMP is RFC 3339, UTC, and SOURCE says where it was read. The time a pull request that
# produced SHA as its merge commit was merged comes first: it is exact and is there as soon as the merge is, while the
# host's events list is delayed on purpose and has no promise of when a push shows in it. Else the newest 100 events of
# the repository are searched for the push. Prints nothing when neither knows SHA. Fails, with the host's error on
# stderr, when either cannot be read (a failed first read is not answered from the second). A read, so a machine asks
# GitHub too.
ci_push_time() {
  local platform repo found
  platform=$(ci_platform) || return 1
  [[ $1 =~ ^[0-9a-f]{40}$ ]] || {
    _ci_fail "ci_push_time takes a full commit SHA, not '$1'"
    return 1
  }
  case $platform in
  github | local)
    repo=$(ci_repo) || return 1
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
