#!/usr/bin/env bash
# gitops-check.sh GITOPS_DIR [BASE]: the check of a tree of the deployment repository svp-gitops (base/, envs/,
# argocd/), run by that repository's workflow from a checkout of this repository at a pinned commit, and on a machine
# against a clone. Exit 0 when every step passes; each step prints one line per thing it checked, FAIL lines on stderr.
#
# gitops-check.sh --worktree GITOPS_DIR: the same render of a clone of svp-gitops (main, in CI), with the charts of this
# repository's working tree standing for the revision of every environment: what `make helm-check` runs on a change of
# the charts before it is merged. Step 1 then checks the shape of charts.yaml and of the image files only, since the
# revision they pin and what derives from it are svp-gitops's own check, and step 5 (the release images, which are
# svp-gitops's) is left out.
#
#   1. The tree: envs/ holds exactly stg and prd. Each envs/<env>/charts.yaml holds exactly revision (a full commit of
#      this repository on origin/main), podSecurityVersion and collectorConfigSha256, both equal to what that commit
#      gives (podSecurityVersion of deploy/helm/svp-cluster/values.yaml, the sha256 of
#      deploy/observability/otelcol/k8s-config.yaml). envs/<env>/images/ holds exactly one file per service, each the
#      image block alone (repository, tag, digest), the repository that service's image of a release source of the
#      table chart svp-policy reads at revision (release_source_of of deploy/k8s/lib.sh: what the policy of <env>
#      admits). A release of source backend, this repository, which also holds the charts: the commit its tag names is
#      revision or one of its ancestors, so an image never runs with charts older than its code (a new environment
#      variable the chart does not set yet). A release of another source: its tag is the 12 hex of a commit on main of
#      that source's repository, read from a clone of it with its whole history: SVP_SOURCE_DIR_<NAME> (the source's
#      name in upper case, SVP_SOURCE_DIR_WEB) when set, a clone whose origin is that repository word for word;
#      otherwise an anonymous clone (--filter=blob:none) of the source's repository URL into the temporary directory,
#      made only when a file names such a release. The workflow of svp-gitops sets no SVP_SOURCE_DIR_*: a renamed
#      repository is named by its old URL in a table of an older revision (and by a retired source) and by its new URL
#      in a newer one, and one clone has one origin, so each source is cloned from the URL its table gives, which the
#      host redirects to the repository whatever its name now.
#      Its configuration reaches it through base/ and the overlays of svp-gitops, not through the charts, so it is not
#      compared with revision. gitops-check.sh --tree GITOPS_DIR [BASE] runs this step and step 1c alone (their test).
#   1c. With BASE, on a pull request opened by the bot of a release source (ci_change_request_author of platform.sh,
#      read from the platform's event; <promoter>[bot] of the table of release sources): each file changed from BASE
#      to HEAD is judged with the table at the revision the environment holding it pins at HEAD (the revision after
#      the change). The bot of source N changes only envs/stg/images/<svc>.yaml with <svc> in N's services, the image
#      after the change a release of N (<imagePrefix><svc> of N), and the image before a release of N, of backend (the
#      source whose repository holds the charts), or of a retired source that publishes <svc> (one without promoter:
#      its repository was renamed, and its successor takes its services over): a takeover goes one way, from backend
#      or from a retired source; a person moves a service back. No bot is the bot of a retired source, so none writes
#      its releases. The bot of backend also changes envs/stg/charts.yaml, envs/prd/charts.yaml and
#      envs/prd/images/<svc>.yaml (prd's content is step 1b's rule). No bot of a source deletes a file under envs/, and
#      no bot of a source changes a file outside envs/. A bot whose login is no promoter of the table changes nothing
#      under envs/. A pull request of a person is not limited here. The author does not name who pushed onto the pull
#      request's branch, so the event's sender (ci_change_request_sender: who opened it, or who pushed the commit
#      checked) counts too: a bot other than the author fails, whoever the author is (the bot of svp-frontend pushing
#      onto the pull request of the bot of backend would otherwise pass as backend's); a person pushing onto a bot's
#      pull request is judged by the author's rule as before. A pull request whose author or sender cannot be read
#      fails; without BASE, or for a run of no pull request (a push, a dispatch, a machine without
#      SVP_CHANGE_REQUEST_AUTHOR), the step prints one skip line; on a machine, SVP_CHANGE_REQUEST_SENDER names the
#      sender, none when unset.
#   1b. With BASE, when envs/prd/images/ or envs/prd/charts.yaml changed from BASE to HEAD: the seven releases
#      (repository, tag, digest) and the charts (revision, podSecurityVersion, collectorConfigSha256) of envs/prd/
#      together are exactly the payload of one record of stg that counts (deploy/ci/release-set.sh records: state
#      success, made by the app, its run one of verify.yml on main of the code repository, read through
#      ci_deployment_list and ci_run_workflow of platform.sh) whose commit is on origin/main of GITOPS_DIR. A set whose pieces each come from some record, a set that was only merged into envs/stg/images/, and
#      the releases of a record with other charts all fail, each saying so. Skipped without BASE.
#      gitops-check.sh --records GITOPS_DIR BASE runs this step alone (its test).
#   2. The root chart argocd/apps for each environment on amd64 and arm64 nodes (helm lint and template): it fails when
#      an overlay or an image file breaks its rules. Every source it reads from svp-gitops names a full ref
#      (refs/heads/<branch>) or a commit as targetRevision, never a short name, which Argo CD may resolve to a tag of
#      that name. Argo Rollouts gets exactly one traffic router plugin on each architecture, the asset built for it,
#      both of one release.
#   3. The charts of this repository (deploy/helm/*, at the revision of each environment) with base/ alone and with
#      the environment's overlay and image file, as Argo CD reads them (helm lint and template); no render of prd names
#      svp.localhost. Chart svp-cluster: no ExternalSecret or SecretStore with base/ alone (the dev path's), one
#      ExternalSecret per entry of its files/external-secrets.yaml and one SecretStore per namespace there in each
#      environment (provider kubernetes in stg, aws in prd, no svp-secrets in prd), valid against the CRDs of the
#      External Secrets chart components.json pins (kubeconform -strict in KUBECONFORM_IMAGE of the Makefile).
#   4. Every third-party image pinned by digest. Renders, with `helm template --include-crds`, every component of
#      components.json with its base/ values (upstream charts at their pinned versions, the charts of this repository
#      at each revision) and Argo CD as argocd/bootstrap.json installs it, and lists every image: the values of image
#      fields (image:, imageName:, ...), and image references inside args, env and config files (an operator's
#      --xxx-image=... flag, an env value it starts pods from). A setting whose name says it holds an image (an env
#      name or upper-case key with the word IMAGE, a flag with "image") counts even without a registry, as busybox:1.37
#      or alpine. The service images (a service's image of any release source) are left out: the CI of their source
#      signs them and Kyverno verifies them, and Kyverno checks nothing else at admission, so the images of the
#      platform namespaces are held to their digests here instead: a
#      tag can be pushed again to other content, a digest cannot. Every environment runs the images built once for the
#      base: each component with an overlay in envs/<env>/ is rendered again with it after its values, and the images
#      of that render, the seven service images included, must be exactly those of the base render.
#   5. deploy/ci/values-check.sh --gitops on the image files changed from commit BASE to HEAD of GITOPS_DIR (every one
#      without BASE): signed release, vuln attestation, and the build provenance the environment's policy asks for.
#      For a release whose provenance was checked, image.tag must be the 12 hex of the commit the provenance names
#      (tag_provenance_mismatch of common.sh); in an environment that requires provenance, a check of a release that
#      names no provenance commit fails too.
#      When it fails on a set that matched a record of stg (step 1b, a rollback), prints the rescan of that record's
#      commit.
#
# GITOPS_DIR is read, never written: everything else happens in a temporary directory. Needs bash, git, jq, helm,
# docker and network access (chart repositories, GHCR), and, without --worktree, the history of this repository up to
# every revision and image tag (a full clone, origin/main fetched). With BASE, GITOPS_DIR must be the top of its own git
# repository.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

worktree= records_only= tree_only=
if [ "${1:-}" = --worktree ]; then
  worktree=1
  shift
  [ $# -eq 1 ] || fail "usage: gitops-check.sh --worktree GITOPS_DIR"
elif [ "${1:-}" = --records ]; then
  records_only=1
  shift
  [ $# -eq 2 ] || fail "usage: gitops-check.sh --records GITOPS_DIR BASE"
elif [ "${1:-}" = --tree ]; then
  tree_only=1
  shift
  [ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: gitops-check.sh --tree GITOPS_DIR [BASE]"
fi
[ $# -ge 1 ] && [ $# -le 2 ] ||
  fail "usage: gitops-check.sh GITOPS_DIR [BASE] | gitops-check.sh --worktree GITOPS_DIR | gitops-check.sh --records GITOPS_DIR BASE | gitops-check.sh --tree GITOPS_DIR [BASE]"
tree=$(cd "$1" 2>/dev/null && pwd -P) || fail "$1 is not a directory"
base=${2:-}
tools="git jq helm docker"
[ -z "$records_only$tree_only" ] || tools="git jq"
for tool in $tools; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
main=origin/main
envs="prd stg"
# The release source whose repository holds the charts (this one): its bot also promotes charts.yaml and envs/prd/.
chart_source=backend
service_chart=deploy/helm/svp-service
zero_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
# Helm's repository list, index cache and pulled charts stay in the temporary directory, not in .k8s/helm of the dev
# path nor in the user's configuration.
export HELM_CACHE_HOME=$tmp/helm/cache HELM_CONFIG_HOME=$tmp/helm/config HELM_DATA_HOME=$tmp/helm/data

failed=0
problem() {
  echo "FAIL  $1" >&2
  failed=1
}
# step NAME: stops after a step that found a problem, so a broken tree is not rendered.
step() {
  [ "$failed" -eq 0 ] || fail "$1: the problems above"
}

# prd_set: prints, as JSON, the set envs/prd/ of GITOPS_DIR runs: images (service → repository, tag, digest of
# envs/prd/images/<service>.yaml) and charts (revision, podSecurityVersion, collectorConfigSha256 of
# envs/prd/charts.yaml), the form of the payload of a record of stg. Status 1 when a file cannot be read.
prd_set() {
  local images='{}' svc f r t d charts
  for svc in "${svp_services[@]}"; do
    f=$tree/envs/prd/images/$svc.yaml
    r=$(values_field repository <"$f") && t=$(values_field tag <"$f") && d=$(values_field digest <"$f") || return 1
    images=$(jq -c --arg s "$svc" --arg r "$r" --arg t "$t" --arg d "$d" '. + {($s): {repository: $r, tag: $t, digest: $d}}' \
      <<<"$images")
  done
  charts=$tree/envs/prd/charts.yaml
  [ -f "$charts" ] || return 1
  jq -c -n --argjson images "$images" --arg r "$(sed -n 's/^revision: *//p' "$charts")" \
    --arg p "$(sed -n 's/^podSecurityVersion: *//p' "$charts")" --arg s "$(sed -n 's/^collectorConfigSha256: *//p' "$charts")" \
    '{images: $images, charts: {revision: $r, podSecurityVersion: $p, collectorConfigSha256: $s}}'
}

# stg_set_at COMMIT: prints, as JSON, the releases of envs/stg/images/ at COMMIT of GITOPS_DIR (service → repository,
# tag, digest); status 1 when one cannot be read.
stg_set_at() {
  local images='{}' svc c r t d
  for svc in "${svp_services[@]}"; do
    c=$(git -C "$tree" show "$1:envs/stg/images/$svc.yaml" 2>/dev/null) && r=$(values_field repository <<<"$c" 2>/dev/null) &&
      t=$(values_field tag <<<"$c" 2>/dev/null) && d=$(values_field digest <<<"$c" 2>/dev/null) || return 1
    images=$(jq -c --arg s "$svc" --arg r "$r" --arg t "$t" --arg d "$d" '. + {($s): {repository: $r, tag: $t, digest: $d}}' \
      <<<"$images")
  done
  echo "$images"
}

# prd_records: step 1b (see the header). Sets record_ref to the commit of svp-gitops of the record matched.
record_ref=
prd_records() {
  local changed main_ref set records rec ref id kept=() off_main=0 svc ids where c line
  if [ -z "$base" ]; then
    echo "skip  envs/prd/ against the records of stg: no base, so no change of a pull request or push to compare"
    return 0
  fi
  [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" = "$tree" ] || {
    problem "$tree is not the top of a git repository, so nothing changed since $base can be listed"
    return 0
  }
  changed=$(git -C "$tree" diff --name-only --no-renames "$base" HEAD -- envs/prd/images envs/prd/charts.yaml) || {
    problem "list the files of envs/prd/ changed since $base"
    return 0
  }
  if [ -z "$changed" ]; then
    echo "ok    envs/prd/images/ and envs/prd/charts.yaml unchanged since ${base:0:12}: no record of stg to match"
    return 0
  fi
  main_ref=$(git -C "$tree" rev-parse --verify --quiet "refs/remotes/origin/main^{commit}") || {
    problem "origin/main is not in $tree: a record counts only when its commit is on main of svp-gitops (fetch it)"
    return 0
  }
  set=$(prd_set) || {
    problem "envs/prd/images/ and envs/prd/charts.yaml cannot be read as a set (above)"
    return 0
  }
  records=$("$ci_dir/release-set.sh" records) || {
    problem "the records of stg in $gitops_repo cannot be read (above)"
    return 0
  }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    ref=$(jq -r .ref <<<"$rec")
    if git -C "$tree" cat-file -e "$ref^{commit}" 2>/dev/null && git -C "$tree" merge-base --is-ancestor "$ref" "$main_ref"; then
      kept+=("$rec")
    else
      off_main=$((off_main + 1))
      echo "skip  record #$(jq -r .id <<<"$rec"): its commit ${ref:0:12} is not on main of svp-gitops"
    fi
  done < <(jq -c '.[]' <<<"$records")
  for rec in ${kept[@]+"${kept[@]}"}; do
    if jq -e --argjson s "$set" '.payload.images == $s.images and .payload.charts == $s.charts' <<<"$rec" >/dev/null; then
      id=$(jq -r .id <<<"$rec")
      record_ref=$(jq -r .ref <<<"$rec")
      echo "ok    envs/prd/ runs exactly the set of record #$id of stg (svp-gitops ${record_ref:0:12}, checked by $(jq -r .payload.run_url <<<"$rec"))"
      return 0
    fi
  done
  # Why not, as precisely as the records tell.
  for rec in ${kept[@]+"${kept[@]}"}; do
    if jq -e --argjson s "$set" '.payload.images == $s.images' <<<"$rec" >/dev/null; then
      problem "envs/prd/images/ holds the seven releases of record #$(jq -r .id <<<"$rec") of stg, but envs/prd/charts.yaml is not its charts (revision $(jq -r '.charts.revision' <<<"$set") here, $(jq -r '.payload.charts.revision' <<<"$rec") there, or a derived value): a set goes to prd with the charts it ran with"
      return 0
    fi
  done
  where=
  for svc in "${svp_services[@]}"; do
    ids=$(for rec in ${kept[@]+"${kept[@]}"}; do
      jq -r --arg s "$svc" --argjson set "$set" 'select(.payload.images[$s] == $set.images[$s]) | "#\(.id)"' <<<"$rec"
    done | paste -sd ' ' -)
    if [ -z "$ids" ]; then
      where=
      break
    fi
    where+="${where:+; }$svc as in $ids"
  done
  if [ -n "$where" ]; then
    problem "envs/prd/images/ mixes releases of several records of stg ($where): no record holds the whole set, so it never ran together in stg"
    return 0
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    line=$(stg_set_at "$c") || continue
    if jq -e --argjson s "$set" --argjson at "$line" '$s.images == $at' <<<'{}' >/dev/null; then
      problem "envs/prd/images/ is the set of envs/stg/images/ at ${c:0:12} of svp-gitops, but no record of stg holds it: it was merged for stg, not checked there by a run of scenario gitops"
      return 0
    fi
  done < <(git -C "$tree" log --format=%H -n 200 "$main_ref" -- envs/stg/images)
  problem "envs/prd/ matches no record of stg (${#kept[@]} on main of svp-gitops, $off_main not): prd takes only a whole set stg ran through its checks; promote one with $(ci_dispatch_hint images.yml main promote_prd=true)"
}

if [ -n "$records_only" ]; then
  prd_records
  [ "$failed" -eq 0 ] || fail "envs/prd/ against the records of stg (above)"
  exit 0
fi

# source_clone NAME REPOSITORY: prints a folder holding the history of REPOSITORY (release source NAME) with its
# origin/main: SVP_SOURCE_DIR_<NAME in upper case> when set, which must be a clone whose origin is REPOSITORY word for
# word; otherwise an anonymous clone of REPOSITORY into the temporary directory, made once per source (blobs left out:
# only commits are read). The check of svp-gitops sets no such variable: after a rename one repository is named by two
# URLs (the table of an older revision and a retired source give the old one, the newer table the new one), and a
# clone has one origin; cloning from the URL a table gives always works, since the host redirects an old name to the
# repository. The variable is for a machine, set for a source whose URL its clone's origin names exactly.
source_clone() {
  local var dir url
  var=SVP_SOURCE_DIR_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  dir=${!var:-}
  if [ -n "$dir" ]; then
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=
    [ "${url%.git}" = "$2" ] || {
      # Without its userinfo: an origin may carry a credential (https://user:token@host/...).
      [[ $url =~ ^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@(.*)$ ]] && url=${BASH_REMATCH[1]}${BASH_REMATCH[2]}
      echo "FAIL  $var=$dir is not a clone of $2 (its origin is '${url:-none}')" >&2
      return 1
    }
    echo "$dir"
    return 0
  fi
  dir=$tmp/sources/$1
  if [ ! -d "$dir" ]; then
    mkdir -p "$tmp/sources" || return 1
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= clone -q --no-checkout --filter=blob:none "$2.git" "$dir" || {
      rm -rf "$dir"
      echo "FAIL  clone $2 anonymously to read its history (or set $var to a clone of it)" >&2
      return 1
    }
  fi
  echo "$dir"
}

# author_rule: step 1c (see the header).
author_rule() {
  local author sender login changed status path env rev src name svc prefix after before bsrc bname promoters bad=0 n=0 who
  local chart_files='^envs/(stg|prd)/charts\.yaml$|^envs/prd/images/[a-z0-9-]+\.yaml$'
  if [ -z "$base" ]; then
    echo "skip  the author of a pull request: no base, so no change of a pull request to check"
    return 0
  fi
  if ! author=$(ci_change_request_author); then
    problem "the author of the pull request cannot be read (above): the files a bot may change depend on which bot it is"
    return 0
  fi
  if [ -z "$author" ]; then
    echo "skip  the author of a pull request: this run checks no pull request (on a machine, SVP_CHANGE_REQUEST_AUTHOR names the author of one)"
    return 0
  fi
  if ! sender=$(ci_change_request_sender); then
    problem "the sender of the pull request's event cannot be read (above): a bot other than the author may have pushed onto it"
    return 0
  fi
  if [[ $sender == *'[bot]' ]] && [ "$sender" != "$author" ]; then
    problem "the commit checked was pushed by $sender onto the pull request of $author: a bot pushes onto its own pull requests only, since the files allowed are the author's"
    return 0
  fi
  if [[ $author != *'[bot]' ]]; then
    echo "ok    the pull request is by $author, a person: the files it changes are not limited by release source"
    return 0
  fi
  [ "$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null)" = "$tree" ] || {
    problem "$tree is not the top of a git repository, so the files $author changed since $base cannot be listed"
    return 0
  }
  changed=$(git -C "$tree" diff --name-status --no-renames "$base" HEAD) || {
    problem "list the files $author changed since $base"
    return 0
  }
  login=${author%'[bot]'}
  # The table of release sources of each environment, at the revision it pins after the change.
  mkdir -p "$tmp/author"
  for env in $envs; do
    rev=$(charts_field "$env" revision 2>/dev/null) || rev=
    if ! [[ $rev =~ ^[0-9a-f]{40}$ ]] || ! src=$(release_sources "$rev"); then
      problem "the release sources of the charts of envs/$env cannot be read (above), so neither can which files $author may change"
      return 0
    fi
    echo "$src" >"$tmp/author/$env.json"
  done
  # A retired source has no promoter: no login is its bot.
  promoters=$(jq -r '.sources[] | select(has("promoter")) | .promoter' "$tmp"/author/*.json | sort -u)
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    case $path in
    envs/stg/* | envs/prd/*) env=${path:5:3} ;;
    envs/*)
      problem "$path: changed by $author, a bot: envs/ holds the environments stg and prd only"
      bad=1
      continue
      ;;
    *)
      if grep -qxF -- "$login" <<<"$promoters"; then
        problem "$path: changed by $author, the promoter of a release source, which changes nothing outside envs/"
        bad=1
      fi
      continue
      ;;
    esac
    rev=$(charts_field "$env" revision)
    src=$(jq -c --arg p "$login" '.sources[] | select(.promoter == $p)' "$tmp/author/$env.json")
    if [ -z "$src" ]; then
      problem "$path: changed by $author, which promotes no release source of the charts envs/$env runs (${rev:0:12}): only the promoters of those sources change envs/, each the files of its own source"
      bad=1
      continue
    fi
    name=$(jq -r .name <<<"$src")
    who="$author, the bot of release source $name"
    case $path in
    envs/stg/images/*)
      svc=${path#envs/stg/images/}
      svc=${svc%.yaml}
      prefix=$(jq -r .imagePrefix <<<"$src")
      if ! [[ $path =~ ^envs/stg/images/[a-z0-9-]+\.yaml$ ]] ||
        ! jq -e --arg s "$svc" '.services | index($s)' <<<"$src" >/dev/null; then
        problem "$path: changed by $who, which publishes $(jq -r '.services | join(" ")' <<<"$src"): it changes the image files of those services only"
        bad=1
      elif [ "$status" = D ]; then
        problem "$path: deleted by $who: a bot changes the image file of a service, never deletes it"
        bad=1
      elif ! after=$(values_field repository <"$tree/$path" 2>/dev/null) || [ "$after" != "$prefix$svc" ]; then
        problem "$path: $who, wrote image '${after:-?}': it writes releases of its own source only, $prefix$svc"
        bad=1
      elif [ "$status" = A ]; then
        echo "ok    $path: $who, added a release of $svc of its own source"
      elif ! before=$(git -C "$tree" show "$base:$path" 2>/dev/null | values_field repository 2>/dev/null) ||
        ! bsrc=$(release_source_of "$svc" "$before" "$rev"); then
        problem "$path: the image before (${before:-unreadable} at ${base:0:12}) is no release of $svc of a source of the charts of $env (${rev:0:12}): $who, may not replace it (a person may)"
        bad=1
      else
        bname=$(jq -r .name <<<"$bsrc")
        if [ "$bname" = "$name" ]; then
          echo "ok    $path: $who, moved $svc to another release of its own source"
        elif [ "$bname" = "$chart_source" ]; then
          echo "ok    $path: $who, takes $svc over from release source $chart_source, whose repository holds the charts"
        elif ! jq -e 'has("promoter")' <<<"$bsrc" >/dev/null; then
          echo "ok    $path: $who, takes $svc over from release source $bname, which is retired (no promoter at ${rev:0:12})"
        else
          problem "$path: the image before ($before) is a release of source $bname: $who, takes a service over only from $chart_source, whose repository holds the charts, or from a retired source (a person moves it back)"
          bad=1
        fi
      fi
      ;;
    envs/stg/charts.yaml | envs/prd/charts.yaml | envs/prd/images/*)
      if [ "$name" != "$chart_source" ]; then
        problem "$path: changed by $who: only the bot of $chart_source, whose repository holds the charts, changes envs/stg/charts.yaml and envs/prd/; $name's changes the image files of its services in envs/stg/images/ only"
        bad=1
      elif [ "$status" = D ] || ! [[ $path =~ $chart_files ]]; then
        problem "$path: $([ "$status" = D ] && echo deleted || echo changed) by $who: it changes charts.yaml and the image files of envs/prd/images/, never deletes one"
        bad=1
      else
        echo "ok    $path: $who, promotes the charts or the set of prd (the content of prd is the records' rule)"
      fi
      ;;
    *)
      problem "$path: changed by $who: a bot changes the image files of its services in envs/stg/images/ only (the bot of $chart_source also envs/stg/charts.yaml and envs/prd/images/, envs/prd/charts.yaml)"
      bad=1
      ;;
    esac
  done <<<"$changed"
  [ "$bad" -eq 0 ] || return 0
  if grep -qxF -- "$login" <<<"$promoters"; then
    echo "ok    the pull request of $author, the promoter of a release source: its $n changed files are all files its source may change"
  else
    echo "ok    the pull request of $author, a bot that promotes no release source: none of its $n changed files is under envs/"
  fi
}

# --- 1. the tree
components=$tree/argocd/apps/components.json
for f in argocd/apps/Chart.yaml argocd/apps/values.yaml argocd/apps/templates/applications.yaml \
  argocd/apps/components.json argocd/project.yaml argocd/bootstrap.json; do
  [ -f "$tree/$f" ] || problem "$f is missing"
done
[ "$(readlink "$tree/argocd/apps/files/envs" 2>/dev/null)" = ../../../envs ] ||
  problem "argocd/apps/files/envs must be a symlink to ../../../envs, through which the root chart reads envs/"
step "the layout of $tree"
jq -e '.components | length > 0' "$components" >/dev/null || fail "argocd/apps/components.json lists no component"
# The release checks read the policy's settings from its chart's values and envs/<env>/svp-policy.yaml alone.
if jq -e '.components[] | select(.name == "svp-policy") | has("values")' "$components" >/dev/null; then
  problem "component svp-policy names a values file: its settings are the chart's values and envs/<env>/svp-policy.yaml, the only ones the release checks read"
fi

dirs=$(cd "$tree/envs" 2>/dev/null && for d in */; do [ -d "$d" ] && echo "${d%/}"; done | sort | paste -sd ' ' -) || dirs=
[ "$dirs" = "$envs" ] || problem "envs/ holds '$dirs': the environments are exactly prd and stg"
step "the environments of $tree"

# charts_field ENV KEY: the value of KEY in envs/ENV/charts.yaml.
charts_field() {
  sed -n "s/^$2: *//p" "$tree/envs/$1/charts.yaml"
}
# revision_of ENV: the revision of envs/ENV/charts.yaml, once step 1 has checked it; "worktree" with --worktree.
revision_of() {
  if [ -n "$worktree" ]; then echo worktree; else charts_field "$1" revision; fi
}
# code_of ENV: the folder that holds deploy/ of this repository as ENV runs it: the working tree with --worktree,
# otherwise its revision unpacked (below).
code_of() {
  if [ -n "$worktree" ]; then echo "$repo_root"; else echo "$tmp/code/$(revision_of "$1")"; fi
}
# label_of ENV: how messages name the charts of ENV.
label_of() {
  if [ -n "$worktree" ]; then echo "the working tree"; else revision_of "$1" | cut -c1-12; fi
}

for env in $envs; do
  charts=$tree/envs/$env/charts.yaml
  if [ ! -f "$charts" ]; then
    problem "envs/$env/charts.yaml is missing: it pins the commit of this repository whose charts $env runs"
    continue
  fi
  keys=$(grep -Ev '^[[:space:]]*(#.*)?$' "$charts" | sed 's/:.*//' | sort | paste -sd ' ' -)
  if [ "$keys" != "collectorConfigSha256 podSecurityVersion revision" ]; then
    problem "envs/$env/charts.yaml holds '$keys': exactly revision, podSecurityVersion and collectorConfigSha256, one line each"
    continue
  fi
  rev=$(charts_field "$env" revision)
  if [ -n "$worktree" ]; then
    echo "ok    envs/$env/charts.yaml: revision, podSecurityVersion and collectorConfigSha256 (their values are svp-gitops's own check)"
  elif ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
    problem "envs/$env/charts.yaml: revision is '$rev', the full commit (40 hex) of this repository whose charts $env runs"
    continue
  elif ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision $rev is no commit of this clone of the code repository (fetch its whole history)"
    continue
  elif ! git -C "$repo_root" merge-base --is-ancestor "$rev" "$main" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision ${rev:0:12} is not on $main of the code repository"
    continue
  else
    want=$(git -C "$repo_root" show "$rev:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')
    got=$(charts_field "$env" podSecurityVersion)
    [ "$got" = "$want" ] ||
      problem "envs/$env/charts.yaml: podSecurityVersion is '$got', deploy/helm/svp-cluster/values.yaml at ${rev:0:12} pins '$want'"
    want=$(git -C "$repo_root" show "$rev:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1)
    got=$(charts_field "$env" collectorConfigSha256)
    [ "$got" = "$want" ] ||
      problem "envs/$env/charts.yaml: collectorConfigSha256 is '$got', deploy/observability/otelcol/k8s-config.yaml at ${rev:0:12} has sha256 $want"
    echo "ok    envs/$env/charts.yaml: charts of ${rev:0:12} on $main, podSecurityVersion and collectorConfigSha256 as that commit gives them"
  fi

  images=$tree/envs/$env/images
  want=$(for svc in "${svp_services[@]}"; do echo "$svc.yaml"; done | sort | paste -sd ' ' -)
  got=$(cd "$images" 2>/dev/null && ls -A | sort | paste -sd ' ' -) || got=
  if [ "$got" != "$want" ]; then
    problem "envs/$env/images/ holds '$got': exactly one file per service, $want"
  fi
  for svc in "${svp_services[@]}"; do
    file=envs/$env/images/$svc.yaml
    [ -f "$tree/$file" ] || continue
    other=$(grep -Ev '^([[:space:]]|#|$)' "$tree/$file" | grep -vx 'image:' || true)
    if [ -n "$other" ]; then
      problem "$file holds $(sed 's/:.*//' <<<"$other" | paste -sd ' ' -) besides image: an image file holds the image block alone"
      continue
    fi
    if ! repo=$(values_field repository <"$tree/$file") || ! tag=$(values_field tag <"$tree/$file") ||
      ! digest=$(values_field digest <"$tree/$file"); then
      problem "$file: image.repository, tag and digest must each be one plain line in the image block"
      continue
    fi
    # The table of release sources of the charts env runs (the working tree's with --worktree).
    table_rev=$rev
    [ -z "$worktree" ] || table_rev=
    if ! src=$(release_source_of "$svc" "$repo" "$table_rev") || [ -z "$tag" ] || [ -z "$digest" ]; then
      problem "$file: the image must be a release of $(release_repositories "$svc" "$table_rev") with its tag and digest, not '$repo' '$tag' '$digest'"
      continue
    fi
    [ -z "$worktree" ] || continue
    name=$(jq -r .name <<<"$src")
    if [ "$name" = backend ]; then
      if ! commit=$(git -C "$repo_root" rev-parse --verify --quiet "$tag^{commit}"); then
        problem "$file: tag $tag names no commit of this clone of the code repository"
        continue
      fi
      git -C "$repo_root" merge-base --is-ancestor "$commit" "$rev" ||
        problem "$file: tag $tag is no ancestor of revision ${rev:0:12} of envs/$env/charts.yaml: the image would run with charts older than its code"
      continue
    fi
    url=$(jq -r .repository <<<"$src")
    if ! [[ $tag =~ ^[0-9a-f]{12}$ ]]; then
      problem "$file: tag '$tag' is not the 12 hex of a commit of $url (release source $name)"
    elif ! history=$(source_clone "$name" "$url"); then
      problem "$file: the history of $url (release source $name) cannot be read (above)"
    elif ! commit=$(git -C "$history" rev-parse --verify --quiet "$tag^{commit}") || [[ $commit != "$tag"* ]] ||
      ! git -C "$history" merge-base --is-ancestor "$commit" refs/remotes/origin/main 2>/dev/null; then
      problem "$file: tag $tag is no commit on main of $url (release source $name)"
    fi
  done
  if [ -n "$worktree" ]; then
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy admits"
  else
    echo "ok    envs/$env/images/: seven releases, each of a release source the policy of ${rev:0:12} admits; those of backend built at or before ${rev:0:12}, the others on main of their repository"
  fi
done
# --- 1c. the author of a pull request
author_rule
step "the tree $tree"
[ -z "$tree_only" ] || exit 0

# --- 1b. envs/prd/ against the records of stg
if [ -z "$worktree" ]; then
  prd_records
  step "envs/prd/ against the records of stg"
fi

# The charts of this repository at each environment's revision, unpacked with git archive: neither the working tree
# nor the index of this clone is read. All of deploy/, since files of the charts are symlinks to files beside them
# (deploy/postgres/bootstrap.sql, the Collector's config, the Prometheus rules).
for env in $envs; do
  [ -z "$worktree" ] || break
  rev=$(revision_of "$env")
  [ -d "$tmp/code/$rev" ] && continue
  mkdir -p "$tmp/code/$rev"
  git -C "$repo_root" archive "$rev" deploy | tar -x -C "$tmp/code/$rev" ||
    fail "unpack deploy/ of ${rev:0:12} with git archive"
done

# --- 2. the root chart
mkdir -p "$tmp/render" "$tmp/plugins/templates"
printf 'apiVersion: v2\nname: plugins\nversion: 0.1.0\n' >"$tmp/plugins/Chart.yaml"
# The plugins of Argo Rollouts' values, one line each, as its chart reads them.
printf '%s\n' '{{- range .Values.controller.trafficRouterPlugins }}' \
  '# plugin {{ .name }} {{ .location }} {{ .sha256 }}' '{{- end }}' >"$tmp/plugins/templates/plugins.yaml"
for env in $envs; do
  for arch in arm64 amd64; do
    root=$tmp/render/root-$env-$arch.yaml
    set -- --namespace argocd --set-string "env=$env" --set "nodeArch=$arch"
    if ! helm lint --quiet "$tree/argocd/apps" "$@" >"$tmp/err" 2>&1 ||
      ! helm template svp-root "$tree/argocd/apps" "$@" >"$root" 2>"$tmp/err"; then
      grep -v 'found symbolic link in path' "$tmp/err" >&2 || true
      fail "helm lint and template of argocd/apps for $env on $arch nodes"
    fi
    # The targetRevision right after each repoURL of svp-gitops, as the chart writes a source.
    short=$(awk -v url="$gitops_url" '$0 ~ "repoURL: " url "$" { want = 1; next }
      want && /targetRevision:/ { v = $2; gsub(/"/, "", v)
        if (v !~ /^refs\/heads\/./ && !(v ~ /^[0-9a-f]+$/ && length(v) == 40)) print v; want = 0 }
      want && /^ *- / { want = 0 }' "$root" | sort -u | paste -sd ' ' -)
    [ "$(grep -c "repoURL: $gitops_url\$" "$root" || true)" -gt 0 ] ||
      fail "argocd/apps in $env on $arch nodes reads no values from $gitops_url"
    [ -z "$short" ] ||
      fail "argocd/apps in $env on $arch nodes: every source of $gitops_url must name a full ref (refs/heads/<branch>) or a commit as targetRevision, not $short (Argo CD may resolve a short name to a tag of that name)"
    files=()
    while IFS= read -r f; do files+=(-f "$tree/$f"); done < <(awk '/^---/ { app = 0 } /^  name: argo-rollouts$/ { app = 1 }
      app && /^ *- \$values\// { sub(/^ *- \$values\//, ""); print }' "$root")
    [ ${#files[@]} -gt 0 ] || fail "Application argo-rollouts names no values file on $arch nodes in $env"
    helm template plugins "$tmp/plugins" "${files[@]}" | sed -n 's/^# plugin //p' >"$tmp/plugin-$arch" ||
      fail "read the plugins of Argo Rollouts on $arch nodes in $env"
    [ "$(grep -c . "$tmp/plugin-$arch")" = 1 ] &&
      grep -Eq "^[^ ]+ https://[^ ]+/[^ /]+-linux-$arch [0-9a-f]{64}$" "$tmp/plugin-$arch" ||
      fail "Argo Rollouts on $arch nodes in $env must get exactly one plugin, the asset built for linux-$arch: $(cat "$tmp/plugin-$arch")"
  done
  read -r arm_name arm_loc arm_sum <"$tmp/plugin-arm64"
  read -r amd_name amd_loc amd_sum <"$tmp/plugin-amd64"
  [ "$arm_name" = "$amd_name" ] && [ "${arm_loc%/*}" = "${amd_loc%/*}" ] && [ "$arm_sum" != "$amd_sum" ] ||
    fail "Argo Rollouts gets $arm_name of ${arm_loc%/*} on arm64 nodes, $amd_name of ${amd_loc%/*} on amd64 nodes in $env: pin the two assets of one release"
  echo "ok    argocd/apps in $env on arm64 and amd64 nodes; its sources of svp-gitops name full refs; Argo Rollouts gets plugin $arm_name of ${arm_loc%/*}, the asset built for each"
done

# placeholder_repo SERVICE REV: the repository of SERVICE's release that a render with base/ alone gets: the first of
# the release sources that publish it in the table at REV (the working tree's for "worktree"), so the render's image is
# a service image of those charts, as an environment's would be.
placeholder_repo() {
  local rev=$2
  [ "$rev" != worktree ] || rev=
  release_repositories "$1" "$rev" | sed 's/ or .*//'
}

# --- 3. the charts of this repository
jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' "$components" >"$tmp/charts"
while IFS=$'\t' read -r name ns path values; do
  for env in $envs; do
    chart=$(code_of "$env")/$path
    [ -d "$chart" ] || fail "component $name: no chart $path at $(label_of "$env") (charts of envs/$env)"
    set -- --namespace "$ns"
    [ -z "$values" ] || set -- "$@" -f "$tree/$values"
    # Alone, base/ has no image for a release of chart svp-service: a placeholder renders it as the dev path's does.
    if [ "$path" = "$service_chart" ]; then
      base_args=("$@" --set-string "image.repository=$(placeholder_repo "$name" "$(revision_of "$env")")"
        --set-string image.tag=000000000000
        --set-string "image.digest=$zero_digest")
    else
      base_args=("$@")
    fi
    [ ! -f "$tree/envs/$env/$name.yaml" ] || set -- "$@" -f "$tree/envs/$env/$name.yaml"
    [ "$path" != "$service_chart" ] || set -- "$@" -f "$tree/envs/$env/images/$name.yaml"
    for kind in base "$env"; do
      if [ "$kind" = base ]; then args=("${base_args[@]}"); else args=("$@"); fi
      if ! helm lint --quiet "$chart" "${args[@]}" >"$tmp/err" 2>&1 ||
        ! helm template "$name" "$chart" "${args[@]}" >"$tmp/render/$kind-$env-$name.yaml" 2>"$tmp/err"; then
        cat "$tmp/err" >&2
        fail "helm lint and template of $name ($path at $(label_of "$env")) with the values of $kind"
      fi
    done
  done
  echo "ok    $name: $path with base/ alone and with each environment's values"
done <"$tmp/charts"
if grep -n 'svp\.localhost' "$tmp"/render/prd-prd-*.yaml "$tmp"/render/root-prd-*.yaml >"$tmp/leftover"; then
  sed "s|^$tmp/render/||" "$tmp/leftover" >&2
  fail "the prd render above still names svp.localhost: override it in envs/prd"
fi
echo "ok    prd: no svp.localhost in the render of the root or of any chart of the code repository"

# External Secrets of chart svp-cluster.
eso=$(jq -r '.components[] | select(.name == "external-secrets") | "\(.repo) \(.chart) \(.version) \(.values)"' \
  "$components")
[ -n "$eso" ] || fail "no component external-secrets in argocd/apps/components.json"
read -r eso_repo eso_chart eso_version eso_values <<<"$eso"
mkdir -p "$tmp/eso/crds" "$tmp/eso/schemas" "$tmp/eso/manifests"
helm template external-secrets "$eso_chart" --repo "$eso_repo" --version "$eso_version" --namespace external-secrets \
  -f "$tree/$eso_values" --show-only templates/crds/externalsecret.yaml --show-only templates/crds/secretstore.yaml \
  >"$tmp/eso/crds/crds.yaml" || fail "render the CRDs of external-secrets $eso_version"
kubeconform=$(tool_image KUBECONFORM_IMAGE)
docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$tmp/eso/crds:/crds:ro" -v "$tmp/eso/schemas:/schemas" \
  --workdir /schemas -e 'FILENAME_FORMAT={kind}-{fullgroup}-{version}' -e DENY_ROOT_ADDITIONAL_PROPERTIES=1 \
  --entrypoint /openapi2jsonschema "$kubeconform" /crds/crds.yaml >"$tmp/eso/o2j.log" 2>&1 ||
  { cat "$tmp/eso/o2j.log" >&2; fail "schemas from the CRDs of external-secrets $eso_version"; }
# openapi2jsonschema turns provider crd of SecretStore into a schema no manifest can pass; no store uses it.
ss_schema=$tmp/eso/schemas/secretstore-external-secrets.io-v1.json
jq -e '.properties.spec.properties.provider.properties.crd' "$ss_schema" >/dev/null ||
  fail "no provider crd in ${ss_schema##*/}: drop the step that removes it"
jq 'del(.properties.spec.properties.provider.properties.crd)' "$ss_schema" >"$tmp/eso/ss.json" &&
  mv "$tmp/eso/ss.json" "$ss_schema"
for env in $envs; do
  code=$(code_of "$env")
  if grep -Eq '^kind: (ExternalSecret|SecretStore)$' "$tmp/render/base-$env-svp-cluster.yaml"; then
    fail "svp-cluster at $(label_of "$env") with base/ alone (the dev path's) renders an ExternalSecret or a SecretStore"
  fi
  list=$code/deploy/helm/svp-cluster/files/external-secrets.yaml
  want_es=$(grep -c '^- namespace: ' "$list")
  want_ss=$(sed -n 's/^- namespace: //p' "$list" | sort -u | grep -c .)
  f=$tmp/render/$env-$env-svp-cluster.yaml
  es=$(grep -c '^kind: ExternalSecret$' "$f" || true)
  ss=$(grep -c '^kind: SecretStore$' "$f" || true)
  [ "$es" = "$want_es" ] && [ "$ss" = "$want_ss" ] ||
    fail "svp-cluster in $env renders $es ExternalSecrets and $ss SecretStores, want $want_es and $want_ss"
  provider=$(awk '/^kind: SecretStore$/ { s = 1 } s && /^    [a-z]+:$/ { sub(/:$/, ""); print $1; s = 0 }' "$f" |
    sort -u | paste -sd ' ' -)
  if [ "$env" = prd ]; then
    [ "$provider" = aws ] || fail "the SecretStores of prd use provider '$provider', want aws"
    if grep -n 'svp-secrets' "$f" >&2; then
      fail "the prd render of svp-cluster above still names svp-secrets, the lab's source namespace"
    fi
  else
    [ "$provider" = kubernetes ] || fail "the SecretStores of $env use provider '$provider', want kubernetes"
  fi
  set -- --namespace cert-manager
  [ ! -f "$tree/envs/$env/svp-cluster.yaml" ] || set -- "$@" -f "$tree/envs/$env/svp-cluster.yaml"
  helm template svp-cluster "$code/deploy/helm/svp-cluster" "$@" --show-only templates/external-secrets.yaml \
    >"$tmp/eso/manifests/$env.yaml" || fail "render the ExternalSecrets of svp-cluster in $env"
  docker_ run --rm --user "$(id -u):$(id -g)" --network none -v "$tmp/eso/manifests:/manifests:ro" \
    -v "$tmp/eso/schemas:/schemas:ro" "$kubeconform" -strict -summary \
    -skip ServiceAccount,Role,RoleBinding,ValidatingAdmissionPolicy,ValidatingAdmissionPolicyBinding \
    -schema-location '/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' "/manifests/$env.yaml" \
    >"$tmp/eso/kubeconform.log" 2>&1 || { cat "$tmp/eso/kubeconform.log" >&2; fail "kubeconform on the ExternalSecrets and SecretStores of $env"; }
  grep -q "Valid: $((es + ss)), Invalid: 0, Errors: 0" "$tmp/eso/kubeconform.log" ||
    { cat "$tmp/eso/kubeconform.log" >&2; fail "kubeconform did not find $((es + ss)) valid ExternalSecrets and SecretStores in $env"; }
  echo "ok    svp-cluster in $env: $es ExternalSecrets, $ss SecretStores (provider $provider), valid against the CRDs of external-secrets $eso_version; none with base/ alone"
done

# --- 4. image digests, per folder of charts (one per revision, or the working tree): every component with its base/
# values and Argo CD as argocd/bootstrap.json installs it, then each component with an overlay of an environment of
# those charts again with it.
bootstrap=$tree/argocd/bootstrap.json
[ "$(jq -r '"\(.repo) \(.chart)"' "$bootstrap")" = "https://argoproj.github.io/argo-helm argo-cd" ] ||
  fail "argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm"
argocd_version=$(jq -r '.version' "$bootstrap")
argocd_values=$(jq -r '.values' "$bootstrap")
[ -f "$tree/$argocd_values" ] || fail "argocd/bootstrap.json: values file $argocd_values is missing"

# Images a chart renders without any value to override them, so they cannot carry a digest: "image|reason", the image
# as rendered. None at the moment. Images an operator starts from its own code and the chart never renders (the Envoy
# proxy of Envoy Gateway, CloudNativePG's default Postgres image) are not seen here at all; the values files say where
# each of them is pinned.
exceptions=()

# image_refs NAME FILE: every image reference of the rendered manifests in FILE, "NAME<TAB>image" per line,
# CustomResourceDefinitions left out (their schemas describe image fields, they hold none).
image_refs() {
  awk -v name="$1" '
    function unquote(ref) {
      gsub(/^["'\'']|["'\'',]+$/, "", ref)
      return ref
    }
    function emit(ref) {
      ref = unquote(ref)
      if (ref != "") print name "\t" ref
    }
    # A setting of an image rather than the image itself: FOO_IMAGE_PULL_POLICY, FOO_IMAGE_TAG, --image-pull-secrets=...
    function image_attribute(key) {
      key = tolower(key); gsub(/_/, "-", key)
      return key ~ /images?-?(pull-?policy|pull-?secrets?|tag|digest|version|registry|repository|repo)$/
    }
    # The value of a setting named as an image, shaped like one: a reference with "/", ":" or "@", or a bare name
    # (alpine). Not a number, a duration or a boolean: --imageVerifyCacheMaxSize=1048576 has "image" in its name too.
    function image_value(ref) {
      ref = unquote(ref)
      return ref ~ /[\/:@]/ || (ref ~ /^[a-z][a-z0-9._-]*$/ && ref !~ /^(true|false)$/)
    }
    # An env name or an upper-case key (a ConfigMap loaded as env) with the word IMAGE or IMAGES: OPERATOR_IMAGE_NAME,
    # RELATED_IMAGE_FOO.
    function image_env(key) {
      return key ~ /^[A-Z0-9_]+$/ && key ~ /(^|_)IMAGES?(_|$)/ && !image_attribute(key)
    }
    # Documents are kept whole until their kind is known.
    function flush(   i, n, line, rest, ref, key, flag) {
      if (!crd) for (i = 1; i <= nl; i++) {
        line = lines[i]
        # An env entry renders as two lines, "- name: FOO_IMAGE" then "value: ...": the name is read on the first.
        if (match(line, /^[ \t]*- name:[ \t]+["'\'']?[A-Z0-9_]+["'\'']?[ \t]*$/)) {
          key = line; sub(/^[ \t]*- name:[ \t]+/, "", key); key = unquote(key); sub(/[ \t]+$/, "", key)
          if (image_env(key) && i < nl && match(lines[i + 1], /^[ \t]*value:[ \t]+[^ \t#|>{\[]/)) {
            rest = substr(lines[i + 1], RSTART + RLENGTH - 1)
            sub(/[ \t]+#.*$/, "", rest)
            if (image_value(rest)) emit(rest)
          }
          continue
        }
        # FOO_IMAGE: ... on one line, as in a ConfigMap an operator loads as its environment.
        if (match(line, /^[ \t]*(- )?["'\'']?[A-Z0-9_]+["'\'']?:[ \t]+[^ \t#|>{\[]/)) {
          key = line; sub(/^[ \t]*(- )?/, "", key); sub(/:.*$/, "", key); key = unquote(key)
          rest = substr(line, RSTART + RLENGTH - 1)
          sub(/[ \t]+#.*$/, "", rest)
          if (image_env(key) && image_value(rest)) emit(rest)
        }
        # An image field: image:, imageName:, initImage:, any key ending in image or Image, with a scalar value.
        if (match(line, /^[ \t]*(- )?[A-Za-z]*([Ii]mage|imageName):[ \t]+[^ \t#|>{\[]/)) {
          rest = substr(line, RSTART + RLENGTH - 1)
          sub(/[ \t]+#.*$/, "", rest)
          emit(rest)
          continue
        }
        # A flag whose name holds "image" (--acme-http01-solver-image=..., --prometheus-config-reloader=... is below),
        # its value shaped like an image (image_value).
        rest = line
        while (match(rest, /--[A-Za-z0-9-]*image[A-Za-z0-9-]*=[^ \t"'\'',]+/)) {
          ref = substr(rest, RSTART, RLENGTH); flag = ref; sub(/^[^=]*=/, "", ref); sub(/=.*$/, "", flag)
          if (!image_attribute(flag) && image_value(ref)) emit(ref)
          rest = substr(rest, RSTART + RLENGTH)
        }
        # Anything else shaped like registry/path:tag or registry/path@sha256:..., the registry a host name with a
        # dot: an env value or a flag the operator starts other pods from. A URL is not one (its host follows "/").
        rest = line
        while (match(rest, /(^|[ \t"'\''=,])[a-z0-9-]+(\.[a-z0-9-]+)+(:[0-9]+)?\/[A-Za-z0-9._\/-]+(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]+)?/)) {
          ref = substr(rest, RSTART, RLENGTH); sub(/^[ \t"'\''=,]/, "", ref)
          rest = substr(rest, RSTART + RLENGTH)
          if (ref ~ /\/[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+|@sha256:)/ && line !~ /--[A-Za-z0-9-]*image[A-Za-z0-9-]*=/) emit(ref)
        }
      }
      nl = 0; crd = 0
    }
    /^---/ { flush(); next }
    { lines[++nl] = $0; if ($0 ~ /^kind: CustomResourceDefinition/) crd = 1 }
    END { flush() }
  ' "$2"
}

# One line per component, fields separated by the ASCII unit separator so empty fields survive `read`; Argo CD last.
sep=$'\x1f'
list=$(jq -r '.components[] | [.name, .namespace, (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
  (.values // "")] | join("\u001f")' "$components") || fail "read argocd/apps/components.json"
list+=$'\n'"argocd${sep}argocd${sep}${sep}https://argoproj.github.io/argo-helm${sep}argo-cd${sep}$argocd_version${sep}$argocd_values"
digest_problems=
for rev in $(for env in $envs; do revision_of "$env"; done | sort -u); do
  out=$tmp/digests/$rev
  mkdir -p "$out/base"
  code=
  for env in $envs; do
    if [ "$(revision_of "$env")" = "$rev" ]; then
      code=$(code_of "$env") label=$(label_of "$env")
      mkdir -p "$out/env/$env"
    fi
  done
  rendered=0 overlays=0
  while IFS=$sep read -r name namespace path repo chart version values; do
    args=(template "$name" --namespace "$namespace" --include-crds)
    if [ -n "$path" ]; then
      args+=("$code/$path")
    elif [[ $repo == oci://* ]]; then
      args+=("$repo/$chart" --version "$version")
    else
      args+=("$chart" --repo "$repo" --version "$version")
    fi
    if [ -n "$values" ]; then args+=(--values "$tree/$values"); fi
    # base/ has no image for a release of chart svp-service: the placeholder of step 3, a release's form, which the
    # pin check below leaves out like every service image.
    if [ "$path" = "$service_chart" ]; then
      args+=(--set-string "image.repository=$(placeholder_repo "$name" "$rev")" --set-string image.tag=000000000000
        --set-string "image.digest=$zero_digest")
    fi
    helm "${args[@]}" >"$out/base/$name.yaml" 2>"$tmp/err" || { cat "$tmp/err" >&2; fail "helm template $name ($label)"; }
    rendered=$((rendered + 1))
    for env in $envs; do
      [ "$(revision_of "$env")" = "$rev" ] && [ -f "$tree/envs/$env/$name.yaml" ] || continue
      helm "${args[@]}" --values "$tree/envs/$env/$name.yaml" >"$out/env/$env/$name.yaml" 2>"$tmp/err" ||
        { cat "$tmp/err" >&2; fail "helm template $name ($label) with envs/$env/$name.yaml"; }
      overlays=$((overlays + 1))
    done
  done <<<"$list"

  images=$out/images
  for f in "$out"/base/*.yaml; do
    image_refs "$(basename "$f" .yaml)" "$f"
  done | sort -u >"$images"

  # Each overlay's render against the base's, every image compared, the service images included.
  drift=
  for f in "$out"/env/*/*.yaml; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .yaml)
    env=$(basename "$(dirname "$f")")
    image_refs "$name" "$f" | sort -u >"$tmp/env-images"
    if ! diff=$(awk -F '\t' -v n="$name" '$1 == n' "$images" | diff - "$tmp/env-images"); then
      drift+="  envs/$env/$name.yaml (< base, > $env):"$'\n'"$(sed 's/^/    /' <<<"$diff")"$'\n'
    fi
  done

  total=0 pinned=0 excepted=0 services=0
  missing=
  # Every repository a service's release may come from in the table of these charts.
  table_rev=$rev
  [ "$rev" != worktree ] || table_rev=
  service_repos=$(release_sources "$table_rev" | jq -r '.sources[] | .imagePrefix + .services[]') ||
    fail "read the release sources of $label"
  while IFS=$'\t' read -r name ref; do
    service=
    while IFS= read -r r; do
      case $ref in "$r:"* | "$r@"*) service=1 ;; esac
    done <<<"$service_repos"
    if [ -n "$service" ]; then
      services=$((services + 1))
      continue
    fi
    total=$((total + 1))
    # Exactly one digest, at the end: a chart that appends its own digest to a tag already holding one would render
    # tag@sha256:...@sha256:..., which no runtime pulls.
    if [[ $ref =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]]; then
      pinned=$((pinned + 1))
      continue
    fi
    reason=
    for e in ${exceptions[@]+"${exceptions[@]}"}; do
      [ "${e%%|*}" = "$ref" ] && reason=${e#*|}
    done
    if [ -n "$reason" ]; then
      excepted=$((excepted + 1))
      echo "skip  $name: $ref ($reason)"
    else
      missing+="  $name: $ref"$'\n'
    fi
  done <"$images"

  echo "image digests with the charts of $label: charts rendered: $rendered, with an environment's overlay: $overlays; third-party images: $total, pinned by digest: $pinned, exceptions: $excepted; service images left out: $services"
  if [ -n "$drift" ]; then
    printf 'FAIL  overlays whose render runs other images than the base (charts of %s):\n%s' "$label" "$drift" >&2
  fi
  if [ -n "$missing" ]; then
    printf 'FAIL  images without exactly one @sha256:<64 hex> (charts of %s):\n%s' "$label" "$missing" >&2
  fi
  [ -z "$drift$missing" ] || digest_problems=1
done
[ -z "$digest_problems" ] || fail "image digests (above)"
echo "ok    every third-party image is pinned by digest; every overlay runs the images of the base"

# --- 5. the release images
if [ -n "$worktree" ]; then
  echo "skip  the release images: svp-gitops's own check"
else
  rc=0
  "$ci_dir/values-check.sh" --gitops "$tree" "$base" | tee "$tmp/values-check.out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A rollback to an older record: the rescan that refreshes its set reads svp-gitops at the record's commit.
    [ -z "$record_ref" ] || echo "The set of envs/prd/ is that of a record of stg at ${record_ref:0:12}: refresh its vuln attestations with $(ci_dispatch_hint images.yml main rescan=true "values_ref=$record_ref")" >&2
    fail "the release images (above)"
  fi
  # Each release checked in an environment that requires provenance must carry image.tag = the commit it names. Step 1
  # left envs/ holding exactly these environments.
  prov_envs=
  for e in $envs; do
    required=$(provenance_required "" "$e" "$tree") || fail "read whether $e requires provenance"
    [ "$required" != true ] || prov_envs="$prov_envs $e"
  done
  mismatch=$(tag_provenance_mismatch "$tree" "$tmp/values-check.out" "$prov_envs")
  if [ -n "$mismatch" ]; then
    sed 's/^/FAIL  /' <<<"$mismatch" >&2
    fail "the release images: image.tag must be the commit the release's provenance names, read from its check"
  fi
  echo "ok    every release with provenance checked has the image.tag of the commit its provenance names"
fi
echo "ok    $tree passes every check"
