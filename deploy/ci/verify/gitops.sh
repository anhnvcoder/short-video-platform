# shellcheck shell=bash
# Scenario gitops of deploy/ci/verify-run.sh, which sources this file: a new cluster k3d-svp that Argo CD builds from
# the deployment configuration svp-gitops (main, the clone verify-run.sh makes with make gitops-clone) and the charts
# of this repository at the commit its envs/stg/charts.yaml pins, running the signed release images of GHCR by digest
# (job gitops of .github/workflows/verify.yml). The scripts of this run's checkout drive it (the bootstrap, the drills).
# make k8s-gitops-up at the commit of main of svp-gitops the clone holds (the cluster runs as staging, and stays at
# that commit through every check, so a release merged meanwhile changes nothing the checks read), the staging overlay
# seen applied, the set of releases stg runs read, make k8s-smoke, RAM at rest, the supply chain drill (Kyverno
# enforcing), the threat model drill, the source maps of the image CI built, the web's e2e tests with GlitchTip, its
# observability drill, KEDA with two workers transcoding twice (each with the RAM peak of it), RAM at rest again, and
# the set of releases stg ran through all of it, which job record-stg of verify.yml records in svp-gitops on a run of
# main whose scenario step passed with release-set.json in the artifact, whatever the wait for a release after it
# gives. Dispatched, or weekly on main with the other scenarios (SVP_VERIFY_SCHEDULED=true, set by the job on a
# scheduled run only; any other value is a dispatch): on a scheduled run there is no wait for a release (both its
# targets are skipped, with the reason), and drill-k8s-supplychain leaves out cases c and l when their image is too old
# (below). ram-rest-<label> and ram-peak-<n> are described in verify-run.sh.
#
# Two parts of the job run in steps of their own around this scenario, since they need the job's token (it reads the
# repository's runs, artifacts and events; nothing is written) and the scenario's step must not hold it:
#   before it   deploy/ci/gitops-sourcemaps.sh fetch clones svp-gitops (as make gitops-clone), finds the source maps CI
#               exported beside the web image Argo CD is about to run and leaves them, or why there are none, in
#               <temp>/gitops-sourcemaps (ci_temp_dir of deploy/ci/platform.sh): status (ok, skipped or fail), reason,
#               maps/;
#   after it    "Waiting for a release on main": this file run as a script, `bash deploy/ci/verify/gitops.sh release`
#               (release_wait below), the targets wait-release and measure-gitops. On a run of main it has the cluster
#               follow main of svp-gitops from then on, waits for a release reaching it and measures it with make
#               measure-gitops (a release that reached main while the cluster stayed at the commit of the checks is
#               named, never measured); on a run of another branch of this repository, or on a scheduled run, it only says why
#               it waits for nothing. Both names are in the scenario's list, so the dispatch's targets can name them (or leave them
#               out) as any other; they get no line in results.tsv, the step's result is theirs, and it never decides
#               whether the set is recorded.
#
# Steps that are not a make target of their own:
#   gitops-env             the overlays of envs/stg of svp-gitops reached the cluster: Application gateway reads
#                          envs/stg/gateway.yaml after its values, and every running gateway pod has
#                          SENTRY_ENVIRONMENT=stg (the only variable of the pod spec read)
#   gitops-external-secrets the cluster's ExternalSecrets are exactly those of files/external-secrets.yaml of chart
#                          svp-cluster at the commit the cluster runs its charts at (envs/stg/charts.yaml of
#                          svp-gitops at origin/main of the clone), each Ready, and the Secret each builds exists with
#                          the type and exactly the keys
#                          its ExternalSecret names (those of its template, or of its data without one): one line per
#                          Secret. Only the names of the keys leave kubectl's pipe, never a value
#   gitops-argocd-metrics  Prometheus scrapes Argo CD's view of the Applications (PodMonitor argocd-application-controller
#                          of chart svp-observability): within 180 s, argocd_app_info has one series per Application of
#                          namespace argocd and every one is Synced and Healthy, and no ArgoCDApplication* alert fires.
#                          Read through a port-forward of Prometheus on 127.0.0.1:19091. When the charts stg runs
#                          (envs/stg/charts.yaml of svp-gitops) predate that PodMonitor, it says so and passes: the
#                          check starts with the first promote that brings it
#   release-set-before     deploy/ci/release-set.sh snapshot --settle: first waits, for up to 300 s, until every Application
#                          is Synced and Healthy on two reads in a row (a service's autoscaler is briefly Degraded
#                          until metrics-server has a sample of its new pods), then records what stg runs right before k8s-smoke (the revision of
#                          svp-gitops and of the charts every Application synced, its last history entry, the image of
#                          every pod of each service) into $SVP_VERIFY_OUT/release-set/before.json; fails when that could
#                          not be recorded now (a sync running, a rollout not over, two digests for a service)
#   release-set            after the last check (ram-rest-end), before the wait for a release:
#                          deploy/ci/release-set.sh snapshot again, then verify, which writes
#                          $SVP_VERIFY_OUT/release-set.json (into the artifact) only when nothing of the first snapshot
#                          moved and the set is exactly envs/stg/images/ and envs/stg/charts.yaml of svp-gitops at the
#                          revision stg synced, k8s-smoke passed in between; the steps of the window go into it. Skipped,
#                          with the reason (which fails the run), when the dispatch's targets leave out any target of
#                          the scenario but wait-release and measure-gitops (the set was not checked by every step), or
#                          when k8s-smoke or release-set-before did not pass or
#                          was not chosen. The release the wait after the scenario may roll out is never recorded here:
#                          the record is of the set the checks passed on, and a later run records that release
#   drill-k8s-supplychain  make drill-k8s-supplychain with the images it needs, read from GHCR without credentials
#                          (deploy/ci/gitops-sourcemaps.sh): the linux/amd64 manifest of the web release the cluster runs
#                          as the unsigned image (no signature or attestation names it, they name its index), the newest
#                          drill-vulnerable, and the newest drill-unsigned for when Kyverno admits the first. An image
#                          that cannot be read is left out (its case SKIPs) and the step fails after the drill. For case
#                          l (a release without build provenance) the newest web release in the history of this
#                          repository, where the releases lived before svp-gitops, that cosign finds signed without a
#                          provenance attestation (gitops_no_provenance); none found and case l SKIPs, which fails
#                          nothing, while a release
#                          cosign cannot answer for is left out like the images above. Case l passes only when that
#                          release's vuln attestation is within 72 hours: dispatch the rescan the drill names
#                          (images.yml -f rescan=true -f values_ref=<a commit whose values name it>) less than 72 hours
#                          before this run. Case c likewise needs drill-vulnerable built within 72 hours
#                          (images.yml -f drill=true). Nobody dispatches either before a scheduled run, so there
#                          gitops_stale leaves out the image of c or l whose vuln attestation is past the policy's
#                          maximum age (its case SKIPs, failing nothing), with a NOTE line naming the case, its age and
#                          that dispatch; every other case must pass as on a dispatch, which keeps both and fails them
#   gitops-sourcemaps      make k8s-web-sourcemaps SOURCEMAPS_DIR=<maps/ the step before found>, which checks them
#                          against the chunks the web serves before the upload; fails with the reason when that step
#                          failed or left nothing. When it found none on a branch other than main (status skipped: the
#                          release there was built before CI exported maps), this step is skipped with its reason,
#                          k8s-web-e2e runs without SVP_E2E_GLITCHTIP=1, and drill-k8s-web-obs leaves out its GlitchTip
#                          check, with a reason (SVP_WEB_OBS_SKIP_ERRORS). On main every release has its maps, so a
#                          missing one fails and both steps after it run in full.

build=k8s-gitops-up
job_minutes_default=330
k3d=1

# The repository: verify-run.sh's when sourced, this file's own when run as a script.
gitops_repo=${repo:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
# The branch of this repository the job checked out: on main only, a release is waited for after the scenario.
gitops_branch=$(git -C "$gitops_repo" symbolic-ref --short -q HEAD) || gitops_branch=
# The branch of svp-gitops: main, the ref make gitops-clone checked out. The cluster is built at its commit in the clone
# and follows it only in the step after the scenario (release_wait).
gitops_rev=main
export gitops_branch gitops_rev

# gitops_up: make k8s-gitops-up at the commit of main of svp-gitops in the clone (SVP_GITOPS_DIR, which verify-run.sh
# sets once it has cloned it), given as that commit: the cluster stays at it until release_wait has it follow main.
gitops_up() {
  local sha
  sha=$(git -C "${SVP_GITOPS_DIR:?the clone of svp-gitops, which verify-run.sh sets}" rev-parse --verify --quiet \
    "refs/remotes/origin/$gitops_rev^{commit}") || {
    echo "FAIL  origin/$gitops_rev is not in the clone of svp-gitops ($SVP_GITOPS_DIR)"
    return 1
  }
  make k8s-gitops-up GITOPS_REV="$sha"
}

# gitops_charts_rev: prints the commit of this repository whose charts the cluster runs, revision of
# envs/stg/charts.yaml at origin/main of the clone of svp-gitops (SVP_GITOPS_DIR, which verify-run.sh sets once it has
# cloned it; the revision the bootstrap read).
gitops_charts_rev() {
  git -C "${SVP_GITOPS_DIR:?the clone of svp-gitops, which verify-run.sh sets}" show \
    "refs/remotes/origin/$gitops_rev:envs/stg/charts.yaml" | sed -n 's/^revision: *//p'
}

# gitops_env: see gitops-env in the header.
gitops_env() {
  # shellcheck disable=SC2016 # $values is Argo CD's name of the values source, written as it is
  local want='$values/envs/stg/gateway.yaml' files pods values
  files=$(kc -n argocd get applications.argoproj.io gateway -o json |
    jq -r '[.spec.sources[] | .helm.valueFiles // [] | .[]] | join(" ")') || {
    echo "FAIL  gitops-env: read Application gateway"
    return 1
  }
  echo "Application gateway reads: $files"
  case " $files " in
  *" $want "*) ;;
  *)
    echo "FAIL  gitops-env: Application gateway does not read $want"
    return 1
    ;;
  esac
  pods=$(kc -n svp get pods -l app.kubernetes.io/name=gateway --field-selector=status.phase=Running -o json) || {
    echo "FAIL  gitops-env: list the gateway's pods"
    return 1
  }
  # One line per running pod: its name and the value of SENTRY_ENVIRONMENT in its gateway container, nothing else.
  values=$(jq -r '.items[] | .metadata.name + " " + ([.spec.containers[] | select(.name == "gateway") | .env[]?
    | select(.name == "SENTRY_ENVIRONMENT") | .value] | first // "unset")' <<<"$pods") || {
    echo "FAIL  gitops-env: read SENTRY_ENVIRONMENT of the gateway's pods"
    return 1
  }
  if [ -n "$values" ]; then sed 's/^/SENTRY_ENVIRONMENT of /' <<<"$values"; else echo "no running gateway pod"; fi
  if [ -z "$values" ] || awk '$2 != "stg" { bad = 1 } END { exit !bad }' <<<"$values"; then
    echo "FAIL  gitops-env: every running gateway pod must have SENTRY_ENVIRONMENT=stg"
    return 1
  fi
  echo "ok    the staging overlay is applied"
}

# gitops_argocd_metrics: see gitops-argocd-metrics in the header.
gitops_argocd_metrics() {
  local file=deploy/helm/svp-observability/templates/argocd.yaml port=19091 rev apps pid deadline got healthy firing
  # The commit itself must be there: a clone without it would read as charts without the PodMonitor and pass.
  rev=$(gitops_charts_rev) && [[ $rev =~ ^[0-9a-f]{40}$ ]] && git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null || {
    echo "FAIL  gitops-argocd-metrics: read the commit envs/stg/charts.yaml of svp-gitops pins"
    return 1
  }
  if ! git -C "$repo" cat-file -e "$rev:$file" 2>/dev/null; then
    echo "skipped: the charts stg runs (${rev:0:12}) have no $file yet; checked from the first promote that brings it"
    return 0
  fi
  apps=$(kc -n argocd get applications.argoproj.io -o name | grep -c .) || {
    echo "FAIL  gitops-argocd-metrics: list the Applications of namespace argocd"
    return 1
  }
  kc -n svp-obs port-forward --address 127.0.0.1 service/kps-prometheus "$port:9090" >/dev/null 2>&1 &
  pid=$!
  # q QUERY: the value of the first sample of QUERY, 0 when it has none or Prometheus did not answer.
  q() {
    curl -sf --max-time 10 "http://127.0.0.1:$port/api/v1/query" --data-urlencode "query=$1" |
      jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0
  }
  deadline=$((SECONDS + 180))
  while :; do
    got=$(q 'count(argocd_app_info)')
    healthy=$(q 'count(argocd_app_info{sync_status="Synced",health_status="Healthy"})')
    [ "$got" = "$apps" ] && [ "$healthy" = "$apps" ] && break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 10
  done
  firing=$(q 'count(ALERTS{alertname=~"ArgoCDApplication.*",alertstate="firing"})')
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "Applications: $apps; argocd_app_info series: $got, Synced and Healthy: $healthy; ArgoCDApplication* firing: $firing"
  if [ "$got" != "$apps" ] || [ "$healthy" != "$apps" ] || [ "$firing" != 0 ]; then
    echo "FAIL  gitops-argocd-metrics: Prometheus must see every Application Synced and Healthy within 180 s, with no ArgoCDApplication* alert firing"
    return 1
  fi
  echo "ok    Prometheus sees every Application of Argo CD, all Synced and Healthy"
}

# gitops_external_secrets: see gitops-external-secrets in the header.
gitops_external_secrets() {
  local file=deploy/helm/svp-cluster/files/external-secrets.yaml rev list want have es secrets report ns
  rev=$(gitops_charts_rev) && [[ $rev =~ ^[0-9a-f]{40}$ ]] &&
    list=$(git -C "$repo" show "$rev:$file") || {
    echo "FAIL  gitops-external-secrets: read $file at the commit envs/stg/charts.yaml of svp-gitops pins"
    return 1
  }
  echo "charts of ${rev:0:12} (envs/stg/charts.yaml of svp-gitops)"
  want=$(awk '/^- namespace: / { ns = $3 } /^  name: / { if (ns != "") print ns "/" $2; ns = "" }' <<<"$list" | sort)
  es=$(kc get externalsecrets.external-secrets.io -A -o json) || {
    echo "FAIL  gitops-external-secrets: list the ExternalSecrets"
    return 1
  }
  have=$(jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' <<<"$es" | sort)
  # Name, type and key names of each Secret of the namespaces with ExternalSecrets; the values go no further than jq.
  secrets=$(for ns in $(jq -r '[.items[].metadata.namespace] | unique[]' <<<"$es"); do
    kc -n "$ns" get secrets -o json | jq -c --arg ns "$ns" \
      '.items[] | {id: "\($ns)/\(.metadata.name)", type, keys: ((.data // {}) | keys)}' || exit 1
  done | jq -s 'map({key: .id, value: .}) | from_entries') || {
    echo "FAIL  gitops-external-secrets: read the key names of the Secrets"
    return 1
  }
  report=$(jq -r --argjson secrets "$secrets" '.items[] | "\(.metadata.namespace)/\(.metadata.name)" as $id
    | ((.status.conditions // []) | map(select(.type == "Ready")) | first // {}) as $r
    | ((.spec.target.template.data // null | if . == null then null else keys end)
        // [.spec.data[]?.secretKey] | sort) as $want
    | (.spec.target.template.type // "Opaque") as $type
    | $secrets[$id] as $s
    | if $r.status != "True" then
        "FAIL  \($id): ExternalSecret Ready \($r.status // "-") \($r.reason // "-"): \($r.message // "" | gsub("\n"; " "))"
      elif $s == null then "FAIL  \($id): no Secret"
      elif ($s.keys | sort) != $want then "FAIL  \($id): Secret keys \($s.keys | sort | join(",")), want \($want | join(","))"
      elif $s.type != $type then "FAIL  \($id): Secret type \($s.type), want \($type)"
      else "ok    \($id): Ready, Secret \($type) with keys \($want | join(","))" end' <<<"$es") || {
    echo "FAIL  gitops-external-secrets: compare the ExternalSecrets with their Secrets"
    return 1
  }
  [ -z "$report" ] || printf '%s\n' "$report"
  if [ "$have" != "$want" ]; then
    echo "FAIL  gitops-external-secrets: the cluster's ExternalSecrets (>) differ from files/external-secrets.yaml at ${rev:0:12} (<):"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | grep '^[<>]'
    return 1
  fi
  if grep -q '^FAIL' <<<"$report"; then return 1; fi
  echo "ok    $(grep -c . <<<"$want") ExternalSecrets Ready, each Secret with its type and keys"
}

# gitops_no_provenance: prints REPOSITORY@DIGEST (values of <commit>) of the newest web release named in the history of
# this repository's deploy/k8s/values/services/web.yaml (from HEAD), where the releases were promoted before svp-gitops
# held them (every release svp-gitops names has a provenance attestation), that carries a signature of images.yml on
# main and no provenance attestation of it, read anonymously with cosign. Every release since CI attests provenance has
# one, so the search passes over, without asking GHCR, a release whose tag (the commit it was built from) already holds
# deploy/ci/provenance-predicate.sh: it stays a couple of cosign calls however many releases came since. Status 1, the
# reason on stderr, when the history has none (case l SKIPs); 2 when cosign could not answer for a release (the registry
# or Sigstore out of reach), so an error is never read as "no provenance".
gitops_no_provenance() (
  # shellcheck source=deploy/ci/common.sh
  . "$here/common.sh" || exit 1
  sign_identity
  file=deploy/k8s/values/services/web.yaml
  seen=" "
  for c in $(git -C "$repo" log --format=%H -- "$file"); do
    content=$(git -C "$repo" show "$c:$file" 2>/dev/null) || continue
    digest=$(values_field digest <<<"$content" 2>/dev/null) &&
      image_repo=$(values_field repository <<<"$content" 2>/dev/null) || continue
    # Unreadable, the tag only costs a cosign call.
    tag=$(values_field tag <<<"$content" 2>/dev/null) || tag=
    [ -n "$digest" ] && [ "$image_repo" = "$ghcr_prefix/web" ] || continue
    case $seen in *" $digest "*) continue ;; esac
    seen="$seen$digest "
    if [ -n "$tag" ] && git -C "$repo" cat-file -e "$tag^{commit}:deploy/ci/provenance-predicate.sh" 2>/dev/null; then
      continue
    fi
    rc=0
    provenance_absent "$sign_issuer" "$sign_subject" "$image_repo@$digest" || rc=$?
    case $rc in
    1) continue ;;
    0)
      if ! verify_signature "$image_repo" "$digest"; then
        echo "$image_repo@$digest has no provenance, but cosign verifies no signature of it (above)" >&2
        exit 2
      fi
      echo "$image_repo@$digest (values of ${c:0:12})"
      exit 0
      ;;
    *)
      echo "$image_repo@$digest: cosign could not tell whether it carries a provenance attestation (above)" >&2
      exit 2
      ;;
    esac
  done
  echo "no signed web release without provenance in the history of $file" >&2
  exit 1
)

# gitops_stale CASE IMAGE [VALUES_COMMIT]: status 0, after printing a NOTE line that names the case, the age and the
# dispatch that makes it pass again, when the vuln attestation of IMAGE (REPOSITORY@DIGEST) was scanned longer ago than
# the policy's maximum age (imageVerification.maxAttestationAge of chart svp-policy) less an hour, read as
# drill-k8s-supplychain reads it: the oldest scanFinishedOn of the attestations cosign verifies, anonymously. CASE c is
# drill-vulnerable, which only a new build of the drill images scans again; CASE l is the release without provenance,
# rescanned with VALUES_COMMIT as values_ref. Status 1 otherwise, also when cosign or the time cannot be read: the drill then reads it
# again and fails the case with what it got.
gitops_stale() (
  # shellcheck source=deploy/ci/common.sh
  . "$here/common.sh" || exit 1
  sign_identity
  max_age=$(sed -n 's/^  maxAttestationAge: *//p' "$repo_root/deploy/helm/svp-policy/values.yaml")
  [[ $max_age =~ ^[0-9]+[hms]$ ]] || exit 1
  case $max_age in
  *h) max_s=$((${max_age%h} * 3600)) ;;
  *m) max_s=$((${max_age%m} * 60)) ;;
  *s) max_s=${max_age%s} ;;
  esac
  envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$sign_issuer" \
    --certificate-identity "$sign_subject" "$2" 2>/dev/null) || exit 1
  scanned=$(jq -rs '[.[].payload | @base64d | fromjson | .predicate.metadata.scanFinishedOn] | min // empty' \
    <<<"$envelopes" 2>/dev/null) || exit 1
  [[ $scanned =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || exit 1
  age=$(jq -nr --arg t "$scanned" 'now - ($t | fromdateiso8601) | floor') && [[ $age =~ ^[0-9]+$ ]] || exit 1
  # An hour short of the maximum: the drill and Kyverno read the age again minutes later, after the cases before c.
  [ "$age" -gt "$((max_s - 3600))" ] || exit 1
  if [ "$1" = c ]; then
    hint=$(ci_dispatch_hint images.yml main drill=true) || exit 1
  else
    hint=$(ci_dispatch_hint images.yml main rescan=true \
      "values_ref=${3:-<a full commit of this repository whose deploy/k8s/values/services/ names it>}") || exit 1
  fi
  echo "NOTE  case $1 left out on this scheduled run (it SKIPs): $2 was scanned at $scanned, $((age / 3600)) h ago," \
    "within an hour of $max_age or more; nobody rescans it before a scheduled run, so it is checked on a dispatch run within $max_age" \
    "of: $hint"
)

# gitops_supplychain: see drill-k8s-supplychain in the header.
gitops_supplychain() {
  local unsigned vulnerable fallback no_provenance missing= rc=0 values_short values_full
  unsigned=$("$here/gitops-sourcemaps.sh" web-amd64) || missing="$missing the web release's linux/amd64 manifest;"
  vulnerable=$("$here/gitops-sourcemaps.sh" newest drill-vulnerable) || missing="$missing drill-vulnerable;"
  fallback=$("$here/gitops-sourcemaps.sh" newest drill-unsigned) || missing="$missing drill-unsigned;"
  no_provenance=$(gitops_no_provenance) || {
    # 1: none in the history, case l SKIPs; otherwise GHCR did not answer, as for the images above.
    [ $? -eq 1 ] || missing="$missing a web release without provenance;"
    no_provenance=
  }
  # A scheduled run: see SVP_VERIFY_SCHEDULED in the header.
  if [ "${SVP_VERIFY_SCHEDULED:-}" = true ]; then
    if [ -n "$vulnerable" ] && gitops_stale c "$vulnerable"; then vulnerable=; fi
    if [ -n "$no_provenance" ]; then
      values_short=$(sed -n 's/.*(values of \([0-9a-f]*\))$/\1/p' <<<"$no_provenance")
      values_full=$(git -C "$repo" rev-parse --verify -q "${values_short:-none}^{commit}") || values_full=
      if gitops_stale l "${no_provenance%% *}" "$values_full"; then no_provenance=; fi
    fi
  fi
  echo "unsigned: ${unsigned:-none}; vulnerable: ${vulnerable:-none}; unsigned if Kyverno admits that: ${fallback:-none}"
  echo "without provenance: ${no_provenance:-none, case l SKIPs}"
  make drill-k8s-supplychain SUPPLYCHAIN_UNSIGNED="$unsigned" SUPPLYCHAIN_VULNERABLE="$vulnerable" \
    SUPPLYCHAIN_UNSIGNED_FALLBACK="$fallback" SUPPLYCHAIN_NO_PROVENANCE="${no_provenance%% *}" || rc=$?
  if [ -n "$missing" ]; then
    echo "FAIL  drill-k8s-supplychain ran without what GHCR did not give (above):$missing"
    return 1
  fi
  return "$rc"
}

# gitops_sourcemaps DIR: see gitops-sourcemaps in the header; DIR is where the step before the scenario left its result.
gitops_sourcemaps() {
  local status reason
  status=$(cat "$1/status" 2>/dev/null) || status=
  reason=$(cat "$1/reason" 2>/dev/null) || reason=
  case $status in
  ok)
    echo "the source maps of the web image CI built: $reason"
    make k8s-web-sourcemaps SOURCEMAPS_DIR="$1/maps"
    ;;
  fail)
    echo "FAIL  the source maps of the web image CI built: $reason"
    return 1
    ;;
  *)
    echo "FAIL  no result of deploy/ci/gitops-sourcemaps.sh fetch in $1 (the job runs it before the scenario)"
    return 1
    ;;
  esac
}
export -f gitops_up gitops_charts_rev gitops_env gitops_external_secrets gitops_argocd_metrics gitops_no_provenance \
  gitops_stale gitops_supplychain gitops_sourcemaps

scenario_targets() {
  local round maps maps_status maps_reason no_maps before_status smoke_status listed unchecked=
  # Where deploy/ci/gitops-sourcemaps.sh fetch left its result.
  maps=$(ci_temp_dir)/gitops-sourcemaps || maps=
  maps_status=$(cat "$maps/status" 2>/dev/null) || maps_status=
  maps_reason=$(head -n 1 "$maps/reason" 2>/dev/null) || maps_reason=
  step k8s-gitops-up 60 bash -c gitops_up
  step gitops-env 2 bash -c gitops_env
  step gitops-external-secrets 2 bash -c gitops_external_secrets
  # Up to 300 s of waiting for the Applications to settle (see settle in release-set.sh), then the snapshot: the limit
  # leaves the script time to name the Application that did not settle before the step is cut.
  step release-set-before 8 "$here/release-set.sh" snapshot --settle "$SVP_VERIFY_OUT/release-set/before.json"
  before_status=$last_status
  step gitops-argocd-metrics 5 bash -c gitops_argocd_metrics
  step k8s-smoke 15 make k8s-smoke
  smoke_status=$last_status
  step ram-rest-start 15 bash -c 'ram_rest start'
  step drill-k8s-supplychain 40 bash -c gitops_supplychain
  step drill-k8s-threats 30 make drill-k8s-threats
  # The source maps of the web image CI built and the cluster runs, uploaded to the cluster's GlitchTip, then the
  # browser error that must map to them; without maps on a branch, both checks of the mapping are left out.
  if [ "$maps_status" = skipped ]; then
    no_maps="no source maps from CI for the web image the cluster runs on a run of $gitops_branch (gitops-sourcemaps skipped)"
    skip gitops-sourcemaps "$maps_reason"
    step k8s-web-e2e 40 make k8s-web-e2e
    step drill-k8s-web-obs 15 env SVP_WEB_OBS_SKIP_ERRORS="$no_maps, so the e2e run sent no browser error" \
      make drill-k8s-web-obs
  else
    step gitops-sourcemaps 20 bash -c 'gitops_sourcemaps "$1"' _ "$maps"
    step k8s-web-e2e 40 env SVP_E2E_GLITCHTIP=1 make k8s-web-e2e
    step drill-k8s-web-obs 15 make drill-k8s-web-obs
  fi
  # Twice, each drill followed by the RAM peak over its own samples.
  for round in 1 2; do
    step "drill-k8s-keda-$round" 40 make drill-k8s-keda N=9
    if [ "$last_status" = skipped ]; then
      skip "ram-peak-$round" "drill-k8s-keda-$round did not run"
    else
      step "ram-peak-$round" 2 "$here/verify-sample.sh" peak "$last_start" "$last_end" "$round"
    fi
  done
  step ram-rest-end 15 bash -c 'ram_rest end'
  # A set is recorded only once every check of the scenario ran on it: the dispatch's targets leaving one out (the two
  # of the job's step after this one aside, which run after the last snapshot) checked part of it. names is the list
  # verify-run.sh made of this function's targets, chosen its choice of them.
  if [ -z "${listing:-}" ] && [ -n "${targets:-}" ]; then
    # shellcheck disable=SC2086,SC2154 # names: target names split on spaces, set by verify-run.sh
    for listed in $names; do
      case $listed in
      release-set | wait-release | measure-gitops) ;;
      *) chosen "$listed" || unchecked="$unchecked $listed" ;;
      esac
    done
  fi
  # Whatever ran since release-set-before is in the window; listing (no step has run) keeps the name in the list.
  if [ -n "$unchecked" ]; then
    skip release-set "targets leave out$unchecked: the set of releases stg ran was not checked by every step"
  elif [ -z "${listing:-}" ] && [ "$smoke_status" != ok ]; then
    skip release-set "k8s-smoke did not pass or was not chosen: the set of releases stg ran was not checked"
  elif [ -z "${listing:-}" ] && [ "$before_status" != ok ]; then
    skip release-set "release-set-before did not pass or was not chosen: there is nothing to compare the set with"
  else
    # verify says why after a snapshot that could not be recorded too, with what moved since the first.
    step release-set 3 bash -c '"$1" snapshot "$2/release-set/after.json"
      "$1" verify "$2/release-set/before.json" "$2/release-set/after.json" "$2/release-set.json" "$2/results.tsv"' \
      _ "$here/release-set.sh" "$SVP_VERIFY_OUT"
  fi
  # The two targets of the job's step after this one (release_wait), named only while verify-run.sh lists the names it
  # checks the dispatch's targets against: run here, they would hold the job's token in this step.
  if [ -n "${listing:-}" ]; then
    skip wait-release ""
    skip measure-gitops ""
  fi
}

# gitops_release CLONE COMMIT: prints the services, space-separated, whose image.digest in envs/stg/images/ of
# svp-gitops COMMIT changes against its first parent (the clone CLONE holds both); nothing when COMMIT is no release.
gitops_release() {
  local svc new old changed=
  for svc in "${svp_services[@]}"; do
    new=$(git -C "$1" show "$2:envs/stg/images/$svc.yaml" 2>/dev/null | values_field digest 2>/dev/null) || new=
    old=$(git -C "$1" show "$2^1:envs/stg/images/$svc.yaml" 2>/dev/null | values_field digest 2>/dev/null) || old=
    if [ -n "$new" ] && [ "$new" != "$old" ]; then changed="$changed $svc"; fi
  done
  printf '%s' "${changed# }"
}

# gitops_releases_between CLONE FROM TO: one line "<commit, 12 digits> (<services>)" per release (gitops_release) on
# the first-parent line of svp-gitops after FROM up to TO, oldest first; exit 1 when CLONE cannot list those commits.
gitops_releases_between() {
  local commits c rel
  commits=$(git -C "$1" rev-list --reverse --first-parent "$2..$3") || return 1
  for c in $commits; do
    rel=$(gitops_release "$1" "$c")
    [ -z "$rel" ] || echo "${c:0:12} ($rel)"
  done
}

# follow_moved: reads the output of deploy/k8s/gitops.sh follow on stdin and prints "FROM TO" when it says the branch
# had moved from FROM, the commit the cluster ran, to TO, which Argo CD deploys now; nothing when it had not.
follow_moved() {
  sed -n 's/^note .* moved from \([0-9a-f]\{40\}\) .* to \([0-9a-f]\{40\}\): .*/\1 \2/p'
}

# release_wait: the job's step "Waiting for a release on main", after the scenario, while the cluster still runs.
# A change of a service with Postgres reaches main of this repository while this step runs (or just before), and its
# release reaches main of svp-gitops through the promote pull request there (the job's steps show which one runs).
# Then:
#   1. drill traffic starts (make k8s-traffic-start), so the release rolls out under load, and stops at the end; then
#      the cluster, built at the commit of main the checks ran on, follows refs/heads/main of svp-gitops
#      (deploy/k8s/gitops.sh follow), its line in the job's log: unchanged, or moved meanwhile, which rolls out now.
#      Moved, the commits since the one the cluster ran reach it only now, so the time from their push would count the
#      wait at that commit, not GitOps: none of them is measured. Their releases are named (the commit fetched into the
#      clone of svp-gitops first), and the wait below starts from the commit Argo CD deploys now;
#   2. every 30 s for at most 90 min, git ls-remote reads main of svp-gitops on GitHub (no credentials: the repository
#      is public). Once it moved, the new commit is fetched into the clone of svp-gitops; when it changes image.digest
#      of a service in envs/stg/images/ against its first parent it is the release, otherwise it is named and the wait
#      goes on from it. None within 90 min fails ("no release");
#   3. make measure-gitops REV=<release, a commit of svp-gitops>, again every 30 s while it exits 2 (not pushed, synced
#      or Ready yet) or exits 0 without the push time (no merged pull request found and GitHub's events do not list the
#      push yet), for at most 20 min; then release_restarts (below) on what it wrote, and the step fails unless both
#      pass. measure-gitops reads the push time (merged_at of the pull request, else GitHub's events) through
#      ci_push_time, which needs the job's token: GH_TOKEN is given to that make alone, and taken out of the environment
#      of everything else here (the drill traffic included).
# Only the lines below reach the job's log; the targets' output goes to $SVP_VERIFY_OUT/logs/release-wait.log and
# measure-gitops.log, which deploy/ci/verify-collect.sh copies into the artifact once they pass its scan. On a run of a
# branch of this repository other than main, it prints why it waits for nothing and exits 0: no change of that branch
# is released. On a scheduled run (SVP_VERIFY_SCHEDULED=true) too: nobody merges a release for it.
# The dispatch's targets (SVP_VERIFY_TARGETS, empty: every target) choose as in verify-run.sh, which has already
# refused a name not in the scenario's list: neither name chosen, it skips (exit 0) without traffic or wait;
# wait-release alone waits and names the release; measure-gitops without wait-release fails at once, as it measures
# the release that wait finds.
# Deadline, the one of verify-run.sh: nothing here starts, and nothing runs, past the job's start
# ($SVP_VERIFY_OUT/job-start) + SVP_VERIFY_JOB_MINUTES - 25 min, the time the collect, upload and k8s-down steps keep
# (without the file, as on a VM, counted from now). The 90 and 20 min of the two waits end there when it comes first,
# and each make measure-gitops is stopped there. Less than a minute left before the wait (or the measure) starts: it
# is skipped with that reason, and the step fails, as a target verify-run.sh skips for its deadline fails the run.
release_wait() {
  local token=${GH_TOKEN:-} targets=${SVP_VERIFY_TARGETS:-} wait=1 measure=1 out base head rel= changed deadline rc \
    json no_push job_start job_minutes cutoff left start_measure follow moved from now skipped
  unset GH_TOKEN
  case $targets in
  *[!a-z0-9\ -]*)
    # Not printed back: the job's log reads a line that starts with :: as a command.
    echo "FAIL  SVP_VERIFY_TARGETS holds a character other than a-z, 0-9, - and space; nothing started"
    return 2
    ;;
  esac
  if [ -n "$targets" ]; then
    case " $targets " in *" wait-release "*) ;; *) wait= ;; esac
    case " $targets " in *" measure-gitops "*) ;; *) measure= ;; esac
  fi
  if [ -z "$wait$measure" ]; then
    echo "skipped: wait-release and measure-gitops are not in targets"
    return 0
  fi
  if [ -z "$wait" ]; then
    echo "FAIL  measure-gitops measures the release wait-release finds: name wait-release in targets with it"
    return 1
  fi
  if [ "${SVP_VERIFY_SCHEDULED:-}" = true ]; then
    echo "skipped: wait-release and measure-gitops: a scheduled run waits for no release (nobody merges one for it, so the wait could only fail); a dispatch on main waits and measures"
    return 0
  fi
  if [ "$gitops_branch" != main ]; then
    echo "skipped: this run is of branch ${gitops_branch:-none} of this repository, whose changes are not released; a release is waited for and measured on a run of main"
    return 0
  fi
  local config=${SVP_GITOPS_DIR:-}
  if ! gitops_is_clone "$config"; then
    echo "FAIL  the clone of svp-gitops (${config:-SVP_GITOPS_DIR unset}) is missing: the scenario's run makes it"
    return 1
  fi
  out=${SVP_VERIFY_OUT:-$(ci_temp_dir)/verify}
  job_start=$(cat "$out/job-start" 2>/dev/null) || job_start=
  case $job_start in '' | *[!0-9]*) job_start=$(date +%s) ;; esac
  job_minutes=${SVP_VERIFY_JOB_MINUTES:-$job_minutes_default}
  case $job_minutes in '' | *[!0-9]*) job_minutes=$job_minutes_default ;; esac
  cutoff=$((job_start + job_minutes * 60 - 25 * 60))
  out=$out/logs
  mkdir -p "$out" || return 1
  if [ $((cutoff - $(date +%s))) -lt 60 ]; then
    echo "skipped: deadline: less than a minute left before $(date -u -d "@$cutoff" +%H:%M:%SZ 2>/dev/null || echo "$cutoff")" \
      "(job start + $job_minutes min - 25 min), so no release is waited for or measured"
    return 1
  fi
  if ! kubectl --context k3d-svp --request-timeout=10s get --raw /readyz >/dev/null 2>&1; then
    echo "FAIL  cluster svp does not answer (did k8s-gitops-up pass?): there is no cluster to roll a release out on"
    return 1
  fi
  base=$(git -C "$config" rev-parse --verify --quiet refs/remotes/origin/main) || {
    echo "FAIL  origin/main is not in the clone of svp-gitops"
    return 1
  }
  # traffic.sh start returns within seconds; the bound only keeps a stuck start from passing the deadline.
  timeout -k 10 $(((cutoff - $(date +%s)) < 120 ? cutoff - $(date +%s) : 120)) \
    make -C "$gitops_repo" k8s-traffic-start >>"$out/release-wait.log" 2>&1 || {
    echo "FAIL  make k8s-traffic-start (release-wait.log)"
    return 1
  }
  # shellcheck disable=SC2064 # the folder is fixed now
  trap "make -C '$gitops_repo' k8s-traffic-stop >>'$out/release-wait.log' 2>&1" EXIT
  follow=$("$gitops_repo/deploy/k8s/gitops.sh" follow "$gitops_rev" 2>&1) || {
    printf '%s\n' "$follow" >>"$out/release-wait.log"
    echo "FAIL  the cluster does not follow refs/heads/$gitops_rev of svp-gitops (deploy/k8s/gitops.sh follow; release-wait.log)"
    return 1
  }
  printf '%s\n' "$follow" >>"$out/release-wait.log"
  printf '%s\n' "$follow" | grep -E '^(ok|note) ' || true
  # Moved while the cluster stayed at the commit the checks ran on (step 1 above): nothing up to the commit Argo CD
  # deploys now is measured, and the wait starts from it.
  moved=$(printf '%s\n' "$follow" | follow_moved)
  if [ -n "$moved" ]; then
    read -r from now <<<"$moved"
    left=$((cutoff - $(date +%s)))
    left=$((left < 60 ? left : 60))
    skipped=
    { [ "$left" -gt 0 ] &&
      GIT_TERMINAL_PROMPT=0 timeout -k 5 "$left" git -C "$config" fetch -q origin \
        "+refs/heads/main:refs/remotes/origin/main" >>"$out/release-wait.log" 2>&1 &&
      skipped=$(gitops_releases_between "$config" "$from" "$now" 2>>"$out/release-wait.log"); } || {
      echo "FAIL  git fetch of main of svp-gitops, or the commits from ${from:0:12} to ${now:0:12} in it (release-wait.log)"
      return 1
    }
    echo "not measured: main of svp-gitops moved from ${from:0:12} to ${now:0:12} while the cluster stayed at ${from:0:12} for the checks; Argo CD rolls that out only now, so the time from a push would count the wait. Releases among those commits: $(printf '%s\n' "${skipped:-none}" | paste -sd, - | sed 's/,/, /g')"
    base=$now
  fi
  deadline=$(($(date +%s) + 90 * 60))
  [ "$cutoff" -lt "$deadline" ] && deadline=$cutoff
  echo "waiting up to $(((deadline - $(date +%s)) / 60)) min for main of svp-gitops to move from ${base:0:12} to a release; drill traffic runs meanwhile"
  while [ -z "$rel" ]; do
    # Each call to GitHub within 60 s and before the deadline (GNU timeout reads 0 as no limit: none starts then).
    left=$((deadline - $(date +%s)))
    left=$((left < 60 ? left : 60))
    head=
    if [ "$left" -gt 0 ]; then
      head=$(GIT_TERMINAL_PROMPT=0 timeout -k 5 "$left" git -C "$config" ls-remote origin refs/heads/main \
        2>>"$out/release-wait.log" | cut -f1) || head=
    fi
    left=$((deadline - $(date +%s)))
    if [[ $head =~ ^[0-9a-f]{40}$ ]] && [ "$head" != "$base" ] && [ "$left" -gt 0 ]; then
      GIT_TERMINAL_PROMPT=0 timeout -k 5 $((left < 60 ? left : 60)) git -C "$config" fetch -q origin \
        "+refs/heads/main:refs/remotes/origin/main" >>"$out/release-wait.log" 2>&1 || {
        echo "FAIL  git fetch of main at ${head:0:12}"
        return 1
      }
      changed=$(gitops_release "$config" "$head")
      if [ -n "$changed" ]; then
        rel=$head
        echo "main of svp-gitops moved to ${head:0:12}, a release of: $changed"
        break
      fi
      echo "main of svp-gitops moved to ${head:0:12}, which changes no image.digest of envs/stg/images/; waiting on"
      base=$head
    fi
    left=$((deadline - $(date +%s)))
    if [ "$left" -le 0 ]; then
      if [ "$deadline" = "$cutoff" ]; then
        echo "FAIL  no release: main of svp-gitops did not move to a commit that changes an image.digest before the job's deadline (job start + $job_minutes min - 25 min)"
      else
        echo "FAIL  no release: main of svp-gitops did not move to a commit that changes an image.digest within 90 min"
      fi
      return 1
    fi
    sleep $((left < 30 ? left : 30))
  done
  if [ -z "$measure" ]; then
    echo "measure-gitops: skipped, not in targets"
    return 0
  fi
  if [ $((cutoff - $(date +%s))) -lt 60 ]; then
    echo "FAIL  measure-gitops: skipped: deadline: less than a minute left of the job (job start + $job_minutes min - 25 min) after the release ${rel:0:12} was found"
    return 1
  fi
  start_measure=$(date +%s)
  deadline=$((start_measure + 20 * 60))
  [ "$cutoff" -lt "$deadline" ] && deadline=$cutoff
  json=$gitops_repo/.k8s/drills/gitops-${rel:0:12}.json
  rc=2
  while :; do
    # GNU timeout: exit 124 once the deadline stops it, 137 when it had to kill it; 0 would be no limit, so none
    # starts then (rc and no_push keep the last try's).
    left=$((deadline - $(date +%s)))
    [ "$left" -gt 0 ] || break
    rc=0 no_push=
    if [ -n "$token" ]; then
      GH_TOKEN=$token timeout -k 30 "$left" make -C "$gitops_repo" measure-gitops REV="$rel" \
        >>"$out/measure-gitops.log" 2>&1 || rc=$?
    else
      timeout -k 30 "$left" make -C "$gitops_repo" measure-gitops REV="$rel" >>"$out/measure-gitops.log" 2>&1 || rc=$?
    fi
    # Measured, but without the push: GitHub's events list a push seconds to minutes after it, and the time from the
    # push is the number this step is for. The sync and the pods are read after the fact, so measuring again later
    # gives the same times, with the push once the events list it.
    if [ "$rc" = 0 ] && [ "$(jq -r '.push // empty' "$json" 2>/dev/null)" = "" ]; then rc=2 no_push=1; fi
    left=$((deadline - $(date +%s)))
    [ "$rc" = 2 ] && [ "$left" -gt 0 ] || break
    sleep $((left < 30 ? left : 30))
  done
  case $rc in
  0)
    echo "make measure-gitops REV=${rel:0:12}: measured (measure-gitops.log, .k8s/drills/gitops-${rel:0:12}.json)"
    release_restarts "$json" || rc=1
    ;;
  2)
    if [ -n "$no_push" ]; then
      echo "FAIL  make measure-gitops REV=${rel:0:12}: synced and Ready, but GitHub's events did not list its push within $(((deadline - start_measure + 59) / 60)) min, so there is no time from the push (measure-gitops.log, .k8s/drills/gitops-${rel:0:12}.json)"
    else
      echo "FAIL  make measure-gitops REV=${rel:0:12}: still not pushed, synced or Ready after $(((deadline - start_measure + 59) / 60)) min (measure-gitops.log)"
    fi
    rc=1
    ;;
  124 | 137)
    echo "FAIL  make measure-gitops REV=${rel:0:12}: stopped when its $(((deadline - start_measure + 59) / 60)) min ran out (20 min, or less to end by the job's deadline) (measure-gitops.log)"
    rc=1
    ;;
  *) echo "FAIL  make measure-gitops REV=${rel:0:12}: exit $rc (measure-gitops.log)" ;;
  esac
  return "$rc"
}

# release_restarts JSON: the verdict on the restarts measure-gitops wrote into JSON (its restarts list, one entry per
# service the release changes). The release must change a service with a database (has_database: its values set
# migrate: true), so that a migrate Job ran in the sync measured; every pod running the new digest and, for each
# service with a database, every pod of its migrate Job must have run without a restart (the startup's retries of the
# database connection, counted beside, are how a pod waits for Postgres instead), and that Job must be there, made
# during the service's sync measured (of_rev_sync: a Job a later sync made in its place says nothing of this one) and
# complete. One line per service, then ok or FAIL; exit 1 on a FAIL.
release_restarts() {
  local lines
  lines=$(jq -r '
    def db: if .db_retry_warnings == null then "log not read"
      else "\(.db_retry_warnings) retry warning(s), \(.db_connected_after_retries) connected after retries" end;
    (.restarts // [])[]
    | "\(.service): \(.pods) pod(s), restartCount \(.pod_restarts), database \(db); "
      + (if .migrate == null then (if .has_database then "no migrate Job, though its values set migrate: true" else "no database" end)
         else . as $s | .migrate | "Job \(.job) \(if .complete then "complete" else "not complete" end)\(if .of_rev_sync then "" else " (created \(.created), not during the sync measured, \($s.sync_started) to \($s.sync_finished))" end), \(.pods) pod(s), restartCount \(.restarts), database \(db)" end)' "$1") || {
    echo "FAIL  release restarts: read the restarts of $1"
    return 1
  }
  printf '%s\n' "$lines" | sed 's/^/release     /'
  if ! jq -e '(.restarts // []) | any(.has_database == true)' "$1" >/dev/null; then
    echo "FAIL  release restarts: the release changes no service with a database, so it says nothing of a release of one"
    return 1
  fi
  if ! jq -e '(.restarts // []) | all(.pod_restarts == 0 and (.has_database != true or (.migrate != null and
      (.migrate | .of_rev_sync == true and .complete == true and .pods == 1 and .restarts == 0))))' "$1" >/dev/null; then
    echo "FAIL  release restarts: a pod of the release or of its migrate Job restarted, or a service with a database has no Job made during the sync measured, complete, on one pod (above)"
    return 1
  fi
  echo "ok    release restarts: the release's pods and its migrate Job ran without a restart"
}

# Run as a script by the job (see the header), not sourced by verify-run.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  # shellcheck source=deploy/ci/platform.sh
  . "$gitops_repo/deploy/ci/platform.sh"
  # values_field, svp_services, gitops_is_clone, and the clone of svp-gitops the scenario's run made.
  # shellcheck source=deploy/k8s/lib.sh
  . "$gitops_repo/deploy/k8s/lib.sh"
  export SVP_GITOPS_DIR=${SVP_GITOPS_DIR:-$gitops_ci_clone}
  case ${1:-} in
  release) release_wait ;;
  *)
    echo "usage: bash deploy/ci/verify/gitops.sh release" >&2
    exit 2
    ;;
  esac
fi
