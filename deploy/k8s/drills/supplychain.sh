#!/usr/bin/env bash
# Drill: the image policy of namespace svp (Kyverno ImageValidatingPolicy svp-images, chart deploy/helm/svp-policy)
# on cluster svp. Every case prints one PASS, FAIL or SKIP
# line with Kyverno's message; a refusal passes only with the message of the rule that should refuse it, not any
# refusal. The pods are sent as server-side dry runs (admission runs, Kyverno verifies, nothing is created), but for
# case b, which is a real Deployment:
#   a  the image a pod of svp runs, a signed release on GHCR: admitted, twice in a row (the second answer comes from
#      Kyverno's verification cache, the time of both is printed);
#   b  SUPPLYCHAIN_UNSIGNED (drill-unsigned, pushed by CI without a signature; or the linux/amd64 manifest of a signed
#      release's index, which the signature and the attestations do not name) in a Deployment of svp: its ReplicaSet
#      reports FailedCreate with the signature rule's message; the Deployment is deleted. When Kyverno admits that
#      image instead (its pod is created), a WARN line says so, and with SUPPLYCHAIN_UNSIGNED_FALLBACK set (the digest of
#      drill-unsigned) the case is run again with that image, which then stands for "unsigned" in h and i too;
#      without it the case fails;
#   c  SUPPLYCHAIN_VULNERABLE (drill-vulnerable, signed and attested with CRITICAL vulnerabilities): refused with the
#      CRITICAL rule's message. Kyverno stops at the first check that fails, and CRITICAL is checked before the age, so
#      the drill image (never rescanned) is still refused with that message once its attestation is past the maximum
#      age: the message cannot show the age rule holds. The drill reads scanFinishedOn of the image's vuln attestation
#      itself (cosign, anonymous) and fails the case, without sending the pod, when it is older than the maximum age
#      of the policy (72 hours after the drill images' dispatch);
#   d  an image of the local registry (k3d-svp-registry:5111) and one of Docker Hub by digest: refused by the prefix
#      rule, each answer within 1 s (Kyverno asks no registry for an image outside the prefix);
#   e  an image of the project by tag, without a digest: refused by Kyverno's digest check, before any registry is
#      asked;
#   f  an attestation too old: a temporary copy of the policy (same chart, maximum age 5 seconds) that applies only to
#      pods of svp labelled svp-drill=supplychain-stale refuses such a pod with image a, with the age rule's message;
#      the copy is deleted again. Its webhook keeps namespace svp only. Image a's vuln attestation is always older
#      than 5 seconds when the drill runs (CI attests before the release is promoted), so the case neither waits nor
#      reads a clock; it only checks first, with cosign, that image a has a vuln attestation at all, and fails without
#      the temporary policy when it has none (Kyverno would then refuse it for the missing attestation, which shows
#      nothing about the age);
#   g  the admission controller down: its Deployment keeps its replica, but the pod is stopped and its replacement
#      cannot be scheduled (strategy Recreate and a nodeSelector no node has), as when it crashes or its node is gone.
#      Not by scaling it to 0: Kyverno v1.19.1 deletes all its webhook configurations when it stops while its
#      Deployment asks for 0 replicas (IsGoingDown, pkg/utils/runtime/utils.go), so a scale to 0 lets every pod through.
#      A pod of svp is refused (the webhook fails closed), a pod of namespace svp-probe (made for the case, Pod Security
#      restricted, outside the webhook's scope) is admitted; the Deployment still wants its replica and has no ready
#      pod between the probes; then the Deployment is put back and ready. The webhooks of the policy (selectors,
#      failurePolicy, rules) are the same before and after. On the GitOps cluster the automated sync of the root
#      Application svp-root, then of Application kyverno, is turned off first, so Argo CD does not undo the change in
#      the middle of the case, and turned on again at the end;
#   h  an ephemeral container (what kubectl debug adds) in a running pod of svp: with an unsigned image refused, with
#      image a admitted;
#   i  an UPDATE of a running pod of svp that sets a container's image to an unsigned one: refused;
#   l  SUPPLYCHAIN_NO_PROVENANCE (a release signed before CI attested build provenance): refused with the provenance
#      rule's message, only when the running policy checks provenance (requireProvenance of chart svp-policy: it has
#      attestation provenance); otherwise SKIP "policy off". Kyverno checks provenance after every other rule, so the
#      refusal shows the provenance rule only if the image passes all of them: before sending the pod the drill checks
#      with cosign (anonymous) that the image is signed, has exactly one vuln attestation of both platforms, no
#      CRITICAL, scanned within the policy's maximum age, and has no provenance attestation; otherwise the case fails,
#      naming the dispatch that rescans that release (an old release is out of the values, so the daily rescan skips
#      it). With the provenance rule on, case a admitted shows a release with provenance passes it;
#   k  the keyless path with another vendor's public image (CloudNativePG's operator v1.28.1 on GHCR, signed by its
#      release workflow; identity from docs/src/security.md of cloudnative-pg/cloudnative-pg and the certificate of
#      its signature): two temporary policies, one with the right subject, one with a wrong one, each for its own drill
#      label: admitted by the first, refused by the second. Runs only while svp-images is in Audit (the dev path,
#      before the Enforce cases), since Enforce refuses that image by its prefix.
# "Unsigned" in h and i is SUPPLYCHAIN_UNSIGNED when set (the signature rule's message), otherwise the dev image of the
# local registry (the prefix rule's message). A case whose image is not available is printed SKIP with the reason:
# b without SUPPLYCHAIN_UNSIGNED, c without SUPPLYCHAIN_VULNERABLE, l without SUPPLYCHAIN_NO_PROVENANCE, a, f and the
# admitted half of h while no pod of svp
# runs an image of GHCR (the dev path).
#
# The dev path (`make k8s-up`) installs the policy in Audit, which refuses nothing: the drill refuses to run there
# unless SUPPLYCHAIN_ENFORCE_TMP=1, which runs case k first, then upgrades release svp-policy to Enforce for the other
# cases and puts Audit back at the end. On any exit, in this order: Kyverno's Deployment put back and ready (without a
# running admission controller, Kyverno's own webhook refuses every change to a policy), the temporary policies
# deleted and their webhooks gone, Audit back (dev path), namespace svp-probe and the Deployment of case b deleted, Argo CD's automated sync
# back on the Application, then the root, as they were. Then the webhooks of the policy must match the snapshot taken
# at the start.
#
# Results as JSON in .k8s/drills/supplychain-<time>.json. Calls no API of the gateway, so it deletes no rate limit key.
#
# Usage (from the repo root, cluster up): make drill-k8s-supplychain [SUPPLYCHAIN_UNSIGNED=ghcr.io/...@sha256:...]
#   [SUPPLYCHAIN_UNSIGNED_FALLBACK=ghcr.io/...@sha256:...] [SUPPLYCHAIN_VULNERABLE=ghcr.io/...@sha256:...]
#   [SUPPLYCHAIN_NO_PROVENANCE=ghcr.io/...@sha256:...] [SUPPLYCHAIN_ENFORCE_TMP=1].
set -euo pipefail

# Only the cluster's API: deploy/compose/lib.sh (the gateway's API helpers, which delete rate limit keys) is left out.
# shellcheck disable=SC2034 # read by deploy/k8s/drills/lib.sh
drill_read_only=1
# shellcheck source=deploy/k8s/drills/lib.sh
source "$(dirname "$0")/lib.sh"
# cosign_ (cosign from PATH, otherwise the pinned COSIGN_IMAGE; verification only) for cases c, f and l, and
# check_vuln_statement and provenance_absent for l.
# shellcheck source=deploy/ci/common.sh
source "$repo_root/deploy/ci/common.sh"

policy=svp-images
policy_values=$repo_root/deploy/helm/svp-policy/values.yaml
prefix=$(sed -n 's/^  imagePrefix: *//p' "$policy_values")
[[ $prefix == */ ]] || fail "read imageVerification.imagePrefix of deploy/helm/svp-policy/values.yaml (got '$prefix')"
# The identity and the maximum age the policy checks, for case c's own reading of the drill image's attestation.
policy_issuer=$(sed -n 's/^  issuer: *//p' "$policy_values")
policy_subject=$(sed -n 's/^  subject: *//p' "$policy_values")
[[ $policy_issuer == https://* && $policy_subject == https://* ]] ||
  fail "read imageVerification.issuer and subject of deploy/helm/svp-policy/values.yaml (got '$policy_issuer', '$policy_subject')"
max_age=$(sed -n 's/^  maxAttestationAge: *//p' "$policy_values")
[[ $max_age =~ ^[0-9]+[hms]$ ]] ||
  fail "read imageVerification.maxAttestationAge of deploy/helm/svp-policy/values.yaml as <number>h, m or s (got '$max_age')"
case $max_age in
*h) max_age_s=$((${max_age%h} * 3600)) ;;
*m) max_age_s=$((${max_age%m} * 60)) ;;
*s) max_age_s=${max_age%s} ;;
esac
psa_version=$(sed -n 's/^podSecurityVersion: *//p' "$repo_root/deploy/helm/svp-cluster/values.yaml")
[[ $psa_version =~ ^v1\.[0-9]+$ ]] || fail "read podSecurityVersion of deploy/helm/svp-cluster/values.yaml (got '$psa_version')"
for v in SUPPLYCHAIN_UNSIGNED SUPPLYCHAIN_UNSIGNED_FALLBACK SUPPLYCHAIN_VULNERABLE SUPPLYCHAIN_NO_PROVENANCE; do
  [[ -z ${!v:-} || ${!v} =~ ^${prefix//./\\.}[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] ||
    fail "$v must be ${prefix}<name>@sha256:<64 hex> (got '${!v}')"
done
unsigned=${SUPPLYCHAIN_UNSIGNED:-}
unsigned_fallback=${SUPPLYCHAIN_UNSIGNED_FALLBACK:-}
vulnerable=${SUPPLYCHAIN_VULNERABLE:-}
no_provenance=${SUPPLYCHAIN_NO_PROVENANCE:-}
# Docker Hub's busybox 1.37.0 (multi-arch index), only ever named in a dry run.
dockerhub=docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
# Case k: CloudNativePG's operator v1.28.1, signed with cosign's older format (a .sig image beside it, as the project's
# releases are) by its release workflow.
vendor_image=ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1@sha256:0edcdaefaa83d68822158cf4370d83d185c54db2b6beb7e0848aca16eafa6344
vendor_subject=https://github.com/cloudnative-pg/cloudnative-pg/.github/workflows/release-publish.yml@refs/tags/v1.28.1
github_issuer=https://token.actions.githubusercontent.com

run_id=$(date -u +%Y%m%dT%H%M%SZ)
owner=svp-drill-supplychain
probe_ns=svp-probe
deploy_name=drill-supplychain-unsigned
admission=kyverno-admission-controller
mkdir -p "$repo_root/.k8s/drills"
json_out="$repo_root/.k8s/drills/supplychain-$run_id.json"

# What the exit trap undoes, set as each step is taken.
enforce_tmp=
temp_policies=
parked=
probe_created=
deploy_created=
argo_paused=

: >"$work/results"
failed=
# result CASE PASS|FAIL|SKIP DETAIL [MS]: one line of the run and one JSON object of the results file.
result() {
  printf '%-4s  (%s) %s%s\n' "$2" "$1" "$3" "${4:+ [${4} ms]}"
  jq -nc --arg c "$1" --arg r "$2" --arg d "$3" --arg ms "${4:-}" \
    '{case: $c, result: $r, detail: $d, latency_ms: (if $ms == "" then null else ($ms | tonumber) end)}' >>"$work/results"
  [[ $2 != FAIL ]] || failed+=" $1"
}

# pod NAME NAMESPACE IMAGE [LABEL]: a pod that meets Pod Security "restricted" in every respect, so what refuses it is
# the image policy, never PSA; LABEL is the value of label svp-drill.
pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels:
    app.kubernetes.io/managed-by: $owner
    svp-drill: ${4:-supplychain}
EOF
  pod_spec "$3"
}

# pod_spec IMAGE: the spec of those pods, at the indentation of a Pod (sed indents it for a pod template).
pod_spec() {
  cat <<EOF
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: c
      image: $1
      command: ["sleep", "60"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
EOF
}

# timed COMMAND...: runs COMMAND; sets out (its stdout and stderr), rc and ms (wall time). Never at the end of a pipe,
# where it would run in a subshell and set nothing.
timed() {
  local t0 t1
  t0=$(now)
  rc=0
  out=$("$@" 2>&1) || rc=$?
  t1=$(now)
  ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", (b - a) * 1000 }')
}

# dry_run NAME NAMESPACE IMAGE [LABEL]: a server-side dry run of pod NAME; out, rc, ms as timed.
dry_run() {
  pod "$@" >"$work/pod.yaml"
  timed kc create --dry-run=server -f "$work/pod.yaml"
}

# reason: Kyverno's message out of $out (what follows "denied the request: "), or the first line of $out.
reason() {
  local r
  r=$(sed -n 's/.*denied the request: //p' <<<"$out" | head -n 1)
  printf '%s' "${r:-$(head -n 1 <<<"$out")}"
}

# admitted CASE WHAT [MARK]: PASS when the command succeeded and $out holds MARK, the line kubectl prints for an admitted
# dry run: "(server dry run)" for create (the default), "pod/<name> patched" for patch, which prints no dry-run suffix.
admitted() {
  local mark=${3:-"(server dry run)"}
  if [[ $rc == 0 && $out == *"$mark"* ]]; then
    result "$1" PASS "$2: admitted" "$ms"
  else
    result "$1" FAIL "$2: admitted (got: $(reason))" "$ms"
  fi
}

# refused CASE WANT WHAT [MAX_MS]: PASS when the request was refused with a message holding WANT (and, with MAX_MS, in
# less than MAX_MS).
refused() {
  if [[ $rc == 0 ]]; then
    result "$1" FAIL "$3: refused with '$2' (it was admitted)" "$ms"
  elif [[ $out != *"$2"* ]]; then
    result "$1" FAIL "$3: refused with '$2' (got: $(reason))" "$ms"
  elif [[ -n ${4:-} ]] && ((ms >= $4)); then
    result "$1" FAIL "$3: refused within $4 ms (took $ms ms): $(reason)" "$ms"
  else
    result "$1" PASS "$3: $(reason)" "$ms"
  fi
}

# Webhooks of the image policies (names starting ivpol.) in Kyverno's resource webhook configuration: what scopes them
# (selectors, rules, match conditions) and failurePolicy, as sorted JSON. Kyverno writes them; the drill must leave
# them as it found them.
webhooks() {
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json | jq -S -c '[.webhooks[]
    | select(.name | startswith("ivpol."))
    | {name, failurePolicy, namespaceSelector, objectSelector, rules, matchConditions, timeoutSeconds}] | sort_by(.name)'
}

# policy_checks_provenance NAME: prints yes when ImageValidatingPolicy NAME has attestation provenance (chart svp-policy
# rendered with requireProvenance), no otherwise.
policy_checks_provenance() {
  kc get imagevalidatingpolicies.policies.kyverno.io "$1" -o json |
    jq -r 'if any(.spec.attestations[]?; .name == "provenance") then "yes" else "no" end'
}

# values_commit DIGEST: the full SHA of the newest commit of this repository's history (from HEAD) whose
# deploy/k8s/values/services/ names DIGEST, the values_ref a rescan of that release needs. A release without
# provenance predates svp-gitops, so only this history names it (rescan.sh reads a full commit of this repository
# there); status 1 without one.
values_commit() {
  local c
  for c in $(git -C "$repo_root" log --format=%H -S"$1" HEAD -- deploy/k8s/values/services); do
    # -S also lists the commit that removed DIGEST: only one whose tree still names it is a values_ref.
    if git -C "$repo_root" grep -qF -- "$1" "$c" -- 'deploy/k8s/values/services/*'; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# policy_mode NAME: Deny or Audit, the validationActions of ImageValidatingPolicy NAME.
policy_mode() { kc get imagevalidatingpolicies.policies.kyverno.io "$1" -o jsonpath='{.spec.validationActions[*]}'; }

# kyverno_up: the admission controller has its replica ready and policy svp-images is ready with its webhook.
kyverno_up() {
  kc -n kyverno rollout status deployment "$admission" --timeout=180s >/dev/null ||
    fail "deployment kyverno/$admission ready within 180s"
  wait_until 120 "ImageValidatingPolicy $policy ready with its webhook" image_policy_ready "$policy"
}

# set_mode MODE: release svp-policy upgraded with imageVerification.mode MODE (the dev path only), then waits until
# Kyverno has the policy ready with the webhook of that failurePolicy.
set_mode() {
  local want=Ignore
  [[ $1 == Enforce ]] && want=Fail
  hc upgrade svp-policy "$repo_root/deploy/helm/svp-policy" --namespace kyverno \
    --set "imageVerification.mode=$1" --wait --timeout 2m >/dev/null || fail "upgrade release svp-policy to $1"
  wait_until 120 "ImageValidatingPolicy $policy ready in $1 with a webhook of failurePolicy $want" \
    image_policy_ready "$policy" "$want"
}

# apply_policy NAME FILE: applies temporary ImageValidatingPolicy NAME (manifest FILE) and waits until Kyverno has it
# ready with its webhook; NAME is recorded first, so the exit trap deletes it whatever happens.
apply_policy() {
  temp_policies+=" $1"
  kc apply -f "$2" >/dev/null || fail "apply the temporary ImageValidatingPolicy $1"
  wait_until 120 "temporary ImageValidatingPolicy $1 ready with its webhook" image_policy_ready "$1" Fail
}

# drill_webhooks_gone: no webhook of a temporary policy is left. Each selects pods by label svp-drill, which policy
# svp-images never does. Kyverno removes a deleted policy's webhook a moment after the policy (informer, queue, then
# an update of the configuration), so whatever compares the webhooks afterwards waits for this first.
drill_webhooks_gone() {
  kc get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json | jq -e '[.webhooks[]
    | select(.name | startswith("ivpol."))
    | select((.objectSelector.matchLabels // {})["svp-drill"] != null)] | length == 0' >/dev/null
}

# probe_ns_up: namespace svp-probe with Pod Security restricted, as deploy/k8s/drills/threats.sh makes it; one of that
# name without this drill's label is someone else's.
probe_ns_up() {
  local who
  if kc get namespace "$probe_ns" >/dev/null 2>&1; then
    who=$(kc get namespace "$probe_ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
    [[ $who == "$owner" || $who == svp-drill-threats ]] ||
      fail "namespace $probe_ns exists without the label of a drill: not this drill's, delete it yourself"
    kc delete namespace "$probe_ns" --wait=true --timeout=120s >/dev/null || fail "delete namespace $probe_ns left by an earlier run"
  fi
  probe_created=1
  kc apply -f - >/dev/null <<EOF || fail "create namespace $probe_ns"
apiVersion: v1
kind: Namespace
metadata:
  name: $probe_ns
  labels:
    app.kubernetes.io/managed-by: $owner
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: $psa_version
EOF
}

# Argo CD on the GitOps cluster: the root svp-root makes Application kyverno with automated sync and selfHeal, and
# would put that back as well as the replica the drill scales to 0. argo_pause turns off the automated sync of the root,
# then of kyverno, each once no sync of it runs; argo_restore puts the syncPolicy each had back, kyverno first, and
# checks it is the same as before.
argo_pause() {
  local app deadline
  for app in svp-root kyverno; do
    kc -n argocd get applications.argoproj.io "$app" -o json | jq -S -c '.spec.syncPolicy' >"$work/syncpolicy-$app" ||
      fail "read the syncPolicy of Application argocd/$app"
    argo_paused="$app $argo_paused"
    if jq -e '.automated != null' "$work/syncpolicy-$app" >/dev/null; then
      kc -n argocd patch applications.argoproj.io "$app" --type json \
        -p '[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' >/dev/null ||
        fail "turn off the automated sync of Application argocd/$app"
    fi
    deadline=$((SECONDS + 300))
    while [[ $(kc -n argocd get applications.argoproj.io "$app" -o jsonpath='{.status.operationState.phase}') == Running ]]; do
      ((SECONDS < deadline)) || fail "the running sync of Application argocd/$app ends within 300s"
      sleep 2
    done
    ok "Application $app: automated sync off, no sync running"
  done
}
argo_restore() {
  local app now
  for app in $argo_paused; do
    kc -n argocd patch applications.argoproj.io "$app" --type merge \
      -p "{\"spec\":{\"syncPolicy\":$(cat "$work/syncpolicy-$app")}}" >/dev/null || return 1
    now=$(kc -n argocd get applications.argoproj.io "$app" -o json | jq -S -c '.spec.syncPolicy') || return 1
    [[ $now == "$(cat "$work/syncpolicy-$app")" ]] || {
      echo "FAIL  Application argocd/$app: syncPolicy $now, before the drill $(cat "$work/syncpolicy-$app")" >&2
      return 1
    }
    ok "Application $app: syncPolicy back as before the drill"
  done
  argo_paused=
}

# unpark (case g): the admission controller's strategy and nodeSelector back as they were, then the pod and the policy
# ready.
unpark() {
  kc -n kyverno patch deployment "$admission" --type json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/strategy\", \"value\": $(cat "$work/strategy")},
    {\"op\": \"remove\", \"path\": \"/spec/template/spec/nodeSelector/svp-drill-supplychain\"}]" >/dev/null || return 1
  kyverno_up
}

# down (case g): the Deployment still asks for its replicas, with the drill's nodeSelector, and no pod of it is ready;
# read between the probes, so nothing brought Kyverno back in the middle.
down() {
  local d
  d=$(kc -n kyverno get deployment "$admission" -o json) || return 1
  [[ $(jq -r --arg r "$replicas" '(.spec.replicas | tostring) == $r
    and .spec.template.spec.nodeSelector["svp-drill-supplychain"] == "no-such-node"
    and (.status.readyReplicas // 0) == 0' <<<"$d") == true ]]
}

drill_exit() {
  local rc=$? p
  trap - EXIT
  set +e
  # Kyverno first: without a running admission controller its own webhook refuses every change to a policy.
  if [[ -n $parked ]]; then
    if (unpark); then
      ok "deployment kyverno/$admission back as it was and ready, policy $policy ready"
    else
      echo "FAIL  put deployment kyverno/$admission back: remove nodeSelector svp-drill-supplychain and set spec.strategy to $(cat "$work/strategy" 2>/dev/null) (make k8s-up on the dev path)" >&2
      rc=1
    fi
  fi
  for p in $temp_policies; do
    if kc delete imagevalidatingpolicies.policies.kyverno.io "$p" --ignore-not-found --wait=true >/dev/null; then
      ok "temporary ImageValidatingPolicy $p deleted"
    else
      echo "FAIL  delete the temporary policy: kubectl --context k3d-svp delete imagevalidatingpolicies.policies.kyverno.io $p" >&2
      rc=1
    fi
  done
  # In a subshell: wait_until's fail would otherwise leave this trap before the steps below.
  if [[ -n $temp_policies ]] && ! (wait_until 120 "Kyverno removed the webhooks of the temporary policies" drill_webhooks_gone); then
    rc=1
  fi
  if [[ -n $enforce_tmp ]]; then
    if (set_mode Audit); then
      ok "release svp-policy back in Audit"
    else
      echo "FAIL  put release svp-policy back in Audit: make k8s-up" >&2
      rc=1
    fi
  fi
  if [[ -n $deploy_created ]]; then
    kc -n svp delete deployment "$deploy_name" --ignore-not-found --wait=true >/dev/null ||
      { echo "FAIL  delete deployment svp/$deploy_name" >&2; rc=1; }
  fi
  if [[ -n $probe_created ]]; then
    if kc delete namespace "$probe_ns" --ignore-not-found --wait=true --timeout=120s >/dev/null; then
      ok "namespace $probe_ns deleted"
    else
      echo "FAIL  delete namespace $probe_ns: kubectl --context k3d-svp delete namespace $probe_ns" >&2
      rc=1
    fi
  fi
  if [[ -n $argo_paused ]]; then
    argo_restore || {
      echo "FAIL  turn the automated sync back on: kubectl --context k3d-svp -n argocd patch applications.argoproj.io <svp-root|kyverno> (syncPolicy of git: automated prune and selfHeal)" >&2
      rc=1
    }
  fi
  if [[ -n ${webhooks_start:-} ]]; then
    if [[ $(webhooks 2>/dev/null) == "$webhooks_start" ]]; then
      ok "the policy's webhooks are as at the start of the drill: $(jq -r 'map("\(.name) \(.failurePolicy) \(.namespaceSelector | tostring)") | join("; ")' <<<"$webhooks_start")"
    else
      echo "FAIL  the policy's webhooks differ from the start of the drill (start: $webhooks_start; now: $(webhooks 2>&1))" >&2
      rc=1
    fi
  fi
  if [[ -s $work/results ]]; then
    jq -s --arg run "$run_id" --arg path "${path_name:-}" '{run: $run, path: $path, cases: .}' "$work/results" >"$json_out" &&
      echo "JSON: ${json_out#"$repo_root"/}"
  fi
  rm -rf "$work"
  exit "$rc"
}
trap drill_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- where the drill runs.
if kc -n argocd get applications.argoproj.io svp-root >/dev/null 2>&1; then path_name=gitops; else path_name=dev; fi
mode=$(policy_mode "$policy") || fail "read ImageValidatingPolicy $policy (is Kyverno installed? make k8s-up)"
image_policy_ready "$policy" || fail "ImageValidatingPolicy $policy is not ready with its webhook"
checks_provenance=$(policy_checks_provenance "$policy") || fail "read the attestations of ImageValidatingPolicy $policy"
webhooks_start=$(webhooks) || fail "read Kyverno's webhook configuration kyverno-resource-validating-webhook-cfg"
ok "cluster on the $path_name path, policy $policy in ${mode:-?}, provenance checked: $checks_provenance; its webhooks: $(jq -r 'map("\(.name) \(.failurePolicy) \(.namespaceSelector | tostring)") | join("; ")' <<<"$webhooks_start")"

# A running pod of svp and its images: the GHCR release (case a) and the dev image (d, h, i) when there is one.
target=$(kc -n svp get pods -l app.kubernetes.io/component=server --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}') || target=
[[ -n $target ]] || fail "a Running pod of svp (app.kubernetes.io/component=server) to patch in cases h and i"
target_container=$(kc -n svp get pod "$target" -o jsonpath='{.spec.containers[0].name}')
signed=$(kc -n svp get pods -o json | jq -r --arg p "$prefix" '[.items[].spec.containers[].image
  | select(startswith($p) and test("@sha256:[0-9a-f]{64}$"))] | first // empty')
local_image=$(kc -n svp get pods -o json | jq -r '[.items[].spec.containers[].image
  | select(startswith("k3d-svp-registry:5111/"))] | first // empty')
local_image=${local_image:-k3d-svp-registry:5111/svp/gateway:dev-000000000000}
bad=${unsigned:-$local_image}
if [[ -n $unsigned ]]; then bad_rule="image without a keyless signature by"; else bad_rule="image not allowed in namespace svp"; fi
echo "      pod to patch: svp/$target (container $target_container); signed image: ${signed:-none (no pod of svp runs one)}"

# --- the dev path: case k under Audit, then Enforce for the rest.
if [[ $mode != Deny ]]; then
  [[ $path_name == dev && ${SUPPLYCHAIN_ENFORCE_TMP:-} == 1 ]] ||
    fail "policy $policy is in $mode, which refuses nothing (the dev path's mode): run SUPPLYCHAIN_ENFORCE_TMP=1 make drill-k8s-supplychain, which switches release svp-policy to Enforce for the drill and back to Audit at its end"

  # Case k. The two policies differ in the subject only; each applies to the pods of its own label.
  for which in right wrong; do
    subject=$vendor_subject
    [[ $which == wrong ]] && subject=${vendor_subject%@*}@refs/heads/main
    cat >"$work/policy.yaml" <<EOF
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: svp-drill-keyless-$which
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  evaluation:
    background:
      enabled: false
  autogen:
    podControllers:
      controllers: []
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: svp
    objectSelector:
      matchLabels:
        svp-drill: keyless-$which
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
  matchImageReferences:
    - glob: "ghcr.io/cloudnative-pg/cloudnative-pg*"
  # As svp-images: a verification Kyverno has not cached can take most of the default 10 s.
  webhookConfiguration:
    timeoutSeconds: 30
  validationConfigurations:
    mutateDigest: false
    verifyDigest: true
    required: true
  attestors:
    - name: vendor
      cosign:
        keyless:
          identities:
            - issuer: $github_issuer
              subject: $subject
  validations:
    - expression: (images.containers + images.initContainers).all(i, verifyImageSignatures(i, [attestors.vendor]) > 0)
      message: no keyless signature by $subject
EOF
    apply_policy "svp-drill-keyless-$which" "$work/policy.yaml"
  done
  dry_run drill-supplychain-k svp "$vendor_image" keyless-right
  admitted k "CloudNativePG's operator v1.28.1 with its release workflow's identity ($vendor_subject)"
  dry_run drill-supplychain-k svp "$vendor_image" keyless-wrong
  refused k "no keyless signature by ${vendor_subject%@*}@refs/heads/main" "the same image with the subject on refs/heads/main"
  for p in $temp_policies; do
    kc delete imagevalidatingpolicies.policies.kyverno.io "$p" --wait=true >/dev/null || fail "delete policy $p"
  done
  wait_until 120 "Kyverno removed the webhooks of the temporary policies of case k" drill_webhooks_gone
  temp_policies=

  enforce_tmp=1
  set_mode Enforce
  ok "release svp-policy in Enforce for the drill (SUPPLYCHAIN_ENFORCE_TMP=1)"
  webhooks_enforce=$(webhooks)
else
  result k SKIP "the policy is in Enforce, which refuses a vendor's image by its prefix; case a shows the keyless path with the project's own identity"
  webhooks_enforce=$webhooks_start
fi

# --- a: a signed release, twice (the second from the verification cache).
if [[ -n $signed ]]; then
  dry_run drill-supplychain-a svp "$signed"
  admitted a "$signed (first)"
  dry_run drill-supplychain-a svp "$signed"
  admitted a "$signed (again, from Kyverno's verification cache)"
else
  result a SKIP "no pod of svp runs a release of GHCR (the dev path's images are unsigned dev builds)"
fi

# --- b: unsigned, through a real Deployment.
# unsigned_deployment IMAGE: Deployment $deploy_name of svp with IMAGE, read until its ReplicaSet reports FailedCreate
# or a pod of it exists (90 s at most), then deleted with its ReplicaSet and pods (foreground: no pod of it is left to
# count for the next image); sets msg (the FailedCreate message, empty without one) and pods (how many it had).
unsigned_deployment() {
  local deadline
  deploy_created=1
  {
    cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deploy_name
  namespace: svp
  labels:
    app.kubernetes.io/managed-by: $owner
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $deploy_name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $deploy_name
        app.kubernetes.io/managed-by: $owner
EOF
    pod_spec "$1" | sed 's/^/    /'
  } | kc apply -f - >/dev/null || fail "create deployment svp/$deploy_name"
  msg=
  pods=0
  deadline=$((SECONDS + 90))
  while [[ -z $msg && $pods == 0 ]] && ((SECONDS < deadline)); do
    sleep 3
    msg=$(kc -n svp get events --field-selector reason=FailedCreate -o json | jq -r --arg d "$deploy_name-" '
      [.items[] | select(.involvedObject.kind == "ReplicaSet" and (.involvedObject.name | startswith($d)))
       | .message] | last // empty')
    pods=$(kc -n svp get pods -l "app.kubernetes.io/name=$deploy_name" -o name | wc -l | tr -d ' ')
  done
  kc -n svp delete deployment "$deploy_name" --cascade=foreground --wait=true >/dev/null ||
    fail "delete deployment svp/$deploy_name"
  deploy_created=
}
if [[ -n $unsigned ]]; then
  unsigned_deployment "$unsigned"
  # The digest of a release's linux/amd64 manifest is not the index that was signed and attested, but Kyverno might
  # still trace it back to that index: then it admits the pod, and the case says so and uses drill-unsigned instead.
  if [[ -z $msg && $pods != 0 && -n $unsigned_fallback ]]; then
    result b WARN "deployment svp/$deploy_name with $unsigned: Kyverno admitted it ($pods pod(s) created), so the case runs again with SUPPLYCHAIN_UNSIGNED_FALLBACK $unsigned_fallback, which also stands for the unsigned image in h and i"
    unsigned=$unsigned_fallback bad=$unsigned_fallback
    unsigned_deployment "$unsigned"
  fi
  out=$msg rc=1 ms=
  if [[ -z $msg && $pods != 0 ]]; then
    result b FAIL "deployment svp/$deploy_name with $unsigned: Kyverno admitted it ($pods pod(s) created)"
  elif [[ -z $msg ]]; then
    result b FAIL "deployment svp/$deploy_name with $unsigned: no FailedCreate event of its ReplicaSet within 90 s"
  else
    refused b "image without a keyless signature by" "deployment svp/$deploy_name with $unsigned: ReplicaSet FailedCreate"
    [[ $pods == 0 ]] && ok "deployment svp/$deploy_name has no pod" ||
      result b FAIL "deployment svp/$deploy_name has no pod (got $pods)"
  fi
else
  result b SKIP "SUPPLYCHAIN_UNSIGNED is not set (digest of drill-unsigned, which CI pushes without a signature)"
fi

# --- c: CRITICAL, once the drill image's attestation is shown to be within the maximum age (the header says why).
if [[ -n $vulnerable ]]; then
  envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$policy_issuer" \
    --certificate-identity "$policy_subject" "$vulnerable" 2>"$work/cosign.err") || envelopes=
  # The oldest when there are several: Kyverno may read any one of them.
  scanned=$(jq -rs '[.[].payload | @base64d | fromjson | .predicate.metadata.scanFinishedOn] | min // empty' \
    <<<"$envelopes" 2>/dev/null) || scanned=
  age=
  if [[ $scanned =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    age=$(jq -nr --arg t "$scanned" 'now - ($t | fromdateiso8601) | floor') || age=
  fi
  if [[ -z $envelopes ]]; then
    result c FAIL "$vulnerable: a vuln attestation of $policy_subject that cosign verifies (got: $(tail -n 1 "$work/cosign.err"))"
  elif [[ ! $age =~ ^-?[0-9]+$ ]]; then
    result c FAIL "$vulnerable: read scanFinishedOn of its vuln attestation as RFC 3339 (got '$scanned')"
  elif ((age > max_age_s)); then
    rebuild=$(ci_dispatch_hint images.yml main drill=true) || exit 1
    result c FAIL "$vulnerable: its vuln attestation was scanned at $scanned, more than $max_age ago, so a refusal for CRITICAL would not show the age rule holds; build the drill images again ($rebuild) and once that run is green run this with SUPPLYCHAIN_VULNERABLE set to the digest it pushed for drill-vulnerable"
  else
    dry_run drill-supplychain-c svp "$vulnerable"
    refused c "vuln attestation reports a CRITICAL vulnerability" "$vulnerable (scanned at $scanned, within $max_age)"
  fi
else
  result c SKIP "SUPPLYCHAIN_VULNERABLE is not set (digest of drill-vulnerable, signed and attested with CRITICAL vulnerabilities)"
fi

# --- l: a release without provenance, once it is shown to pass every other rule (the header says why).
if [[ $checks_provenance != yes ]]; then
  result l SKIP "policy off: $policy has no provenance attestation to check (requireProvenance of chart svp-policy is off at the revision the cluster runs)"
elif [[ -z $no_provenance ]]; then
  result l SKIP "SUPPLYCHAIN_NO_PROVENANCE is not set (digest of a release signed before CI attested build provenance)"
else
  rescan=$(ci_dispatch_hint images.yml main rescan=true \
    "values_ref=$(values_commit "${no_provenance#*@}" || echo '<a full commit of this repository whose deploy/k8s/values/services/ names it>')") || exit 1
  envelopes=$(cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$policy_issuer" \
    --certificate-identity "$policy_subject" "$no_provenance" 2>"$work/cosign.err") || envelopes=
  if ! cosign_ verify --certificate-oidc-issuer "$policy_issuer" --certificate-identity "$policy_subject" \
    "$no_provenance" >/dev/null 2>"$work/cosign.err"; then
    result l FAIL "$no_provenance: a signature of $policy_subject that cosign verifies (got: $(tail -n 1 "$work/cosign.err"))"
  elif [[ $(grep -c . <<<"$envelopes") != 1 ]]; then
    result l FAIL "$no_provenance: exactly one vuln attestation of $policy_subject (got $(grep -c . <<<"$envelopes")); rescan it ($rescan)"
  elif ! problem=$(jq -r '.payload | @base64d' <<<"$envelopes" | check_vuln_statement "${no_provenance#*@}" "$max_age_s"); then
    result l FAIL "$no_provenance: its vuln attestation $problem, so Kyverno would refuse it before the provenance rule; rescan it ($rescan), then run this within $max_age"
  else
    absent=0
    provenance_absent "$policy_issuer" "$policy_subject" "$no_provenance" 2>"$work/cosign.err" || absent=$?
    case $absent in
    0)
      dry_run drill-supplychain-l svp "$no_provenance"
      refused l "image without a provenance attestation signed by" "$no_provenance (signed, clean vuln attestation within $max_age, no provenance)"
      ;;
    1) result l FAIL "$no_provenance carries a provenance attestation of $policy_subject: set SUPPLYCHAIN_NO_PROVENANCE to a release from before provenance" ;;
    *) result l FAIL "$no_provenance: cosign could not tell whether it carries a provenance attestation (got: $(tail -n 1 "$work/cosign.err"))" ;;
    esac
  fi
fi

# --- d: outside the prefix, without any registry asked.
dry_run drill-supplychain-d svp "$local_image"
refused d "image not allowed in namespace svp" "$local_image (local registry)" 1000
dry_run drill-supplychain-d svp "$dockerhub"
refused d "image not allowed in namespace svp" "$dockerhub (Docker Hub)" 1000

# --- e: the project's image by tag.
dry_run drill-supplychain-e svp "${prefix}gateway:latest"
refused e "does not have a digest" "${prefix}gateway:latest (tag, no digest)" 1000

# --- f: an attestation older than the limit, through a temporary copy of the policy (the header says why 5 seconds).
stale_age=5s
if [[ -z $signed ]]; then
  result f SKIP "no signed image of GHCR runs in svp to send under the temporary policy"
elif ! cosign_ verify-attestation --type vuln --certificate-oidc-issuer "$policy_issuer" \
  --certificate-identity "$policy_subject" "$signed" >/dev/null 2>"$work/cosign.err"; then
  result f FAIL "$signed: a vuln attestation of $policy_subject that cosign verifies (got: $(tail -n 1 "$work/cosign.err"))"
else
  hc template svp-drill-stale "$repo_root/deploy/helm/svp-policy" --set imageVerification.mode=Enforce \
    --set "imageVerification.maxAttestationAge=$stale_age" --set name=svp-drill-stale \
    --set-json 'objectSelector={"matchLabels":{"svp-drill":"supplychain-stale"}}' >"$work/policy.yaml" ||
    fail "render chart svp-policy as svp-drill-stale"
  apply_policy svp-drill-stale "$work/policy.yaml"
  dry_run drill-supplychain-f svp "$signed" supplychain-stale
  refused f "vuln attestation older than $stale_age" "$signed under a copy of the policy with a maximum age of $stale_age"
  # Each webhook's own scope, not its selector as a whole: Kyverno ANDs the policy's match on namespace svp with the
  # selector of its ConfigMap (NotIn kube-system, NotIn kyverno). A label selector ANDs matchLabels with every
  # matchExpressions term, so once the match on svp is there any term only narrows the scope; only a missing or
  # different match on svp widens it. The check also asks for NotIn only, stricter than that needs: it is all Kyverno
  # writes today, and any other term is worth a look.
  scope=$(webhooks | jq -c '[.[] | select((.namespaceSelector.matchLabels // {})["kubernetes.io/metadata.name"] != "svp"
    or any(.namespaceSelector.matchExpressions[]?; .operator != "NotIn")) | {name, namespaceSelector}]') || scope=
  if [[ $scope == '[]' ]]; then
    ok "with the temporary policy, every webhook of the image policies selects namespace svp only (kubernetes.io/metadata.name=svp, only NotIn besides)"
  else
    result f FAIL "every webhook of the image policies selects namespace svp only (got ${scope:-no webhook configuration})"
  fi
  kc delete imagevalidatingpolicies.policies.kyverno.io svp-drill-stale --wait=true >/dev/null ||
    fail "delete policy svp-drill-stale"
  wait_until 120 "Kyverno removed the webhook of the temporary policy svp-drill-stale" drill_webhooks_gone
  temp_policies=
fi

# --- h: an ephemeral container (kubectl debug), as a server-side dry run of the pod's subresource.
ephemeral() {
  jq -nc --arg i "$1" --arg t "$target_container" '{spec: {ephemeralContainers: [{
    name: "drill-debug", image: $i, command: ["sleep", "1"], targetContainerName: $t,
    securityContext: {runAsNonRoot: true, runAsUser: 65532, allowPrivilegeEscalation: false,
      readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}, seccompProfile: {type: "RuntimeDefault"}}}]}}'
}
timed kc -n svp patch pod "$target" --subresource=ephemeralcontainers --type=strategic --dry-run=server -p "$(ephemeral "$bad")"
refused h "$bad_rule" "ephemeral container $bad in pod svp/$target"
if [[ -n $signed ]]; then
  timed kc -n svp patch pod "$target" --subresource=ephemeralcontainers --type=strategic --dry-run=server -p "$(ephemeral "$signed")"
  admitted h "ephemeral container $signed in pod svp/$target" "pod/$target patched"
else
  result h SKIP "admitted half: no signed image of GHCR runs in svp"
fi

# --- i: UPDATE of a container's image.
timed kc -n svp patch pod "$target" --type=strategic --dry-run=server \
  -p "{\"spec\":{\"containers\":[{\"name\":\"$target_container\",\"image\":\"$bad\"}]}}"
refused i "$bad_rule" "pod svp/$target with container $target_container set to $bad (UPDATE)"

# --- g: the admission controller down. Last of the cases: it changes the most and the exit trap undoes it.
before=$(webhooks)
[[ $before == "$webhooks_enforce" ]] || fail "the webhooks changed during the cases before g (now: $before)"
if [[ $path_name == gitops ]]; then argo_pause; fi
replicas=$(kc -n kyverno get deployment "$admission" -o jsonpath='{.spec.replicas}')
[[ $replicas =~ ^[1-9][0-9]*$ ]] || fail "read the replicas of deployment kyverno/$admission (got '$replicas')"
kc -n kyverno get deployment "$admission" -o json | jq -c '.spec.strategy' >"$work/strategy" ||
  fail "read the strategy of deployment kyverno/$admission"
probe_ns_up
# Recreate stops the running pod before its replacement, which waits for a node labelled
# svp-drill-supplychain=no-such-node that never comes; the replicas stay as they are, so Kyverno keeps its webhooks.
parked=1
kc -n kyverno patch deployment "$admission" --type json -p '[
  {"op": "replace", "path": "/spec/strategy", "value": {"type": "Recreate"}},
  {"op": "add", "path": "/spec/template/spec/nodeSelector/svp-drill-supplychain", "value": "no-such-node"}]' >/dev/null ||
  fail "make deployment kyverno/$admission unschedulable"
wait_until 120 "no ready pod of kyverno/$admission, its replacement Pending" down
ok "kyverno/$admission: $replicas replica(s) wanted, none ready (the replacement waits for a node)"
dry_run drill-supplychain-g svp "${signed:-$local_image}"
refused g "failed calling webhook" "a pod of svp while the admission controller is down"
if down; then ok "kyverno/$admission still without a ready pod"; else result g FAIL "kyverno/$admission stayed down through the probes"; fi
dry_run drill-supplychain-g "$probe_ns" "${signed:-$local_image}"
admitted g "a pod of $probe_ns (outside the webhook's scope) while the admission controller is down"
if down; then ok "kyverno/$admission still without a ready pod"; else result g FAIL "kyverno/$admission stayed down through the probes"; fi
unpark || fail "put deployment kyverno/$admission back"
parked=
after=$(webhooks)
if [[ $after == "$before" ]]; then
  result g PASS "the policy's webhooks after Kyverno came back match the snapshot before (selectors, failurePolicy, rules)"
else
  result g FAIL "the policy's webhooks after Kyverno came back match the snapshot before (before: $before; after: $after)"
fi

echo
echo "drill-k8s-supplychain ($run_id, $path_name path)"
jq -r '"  \(.case)  \(.result)  \(.detail)"' "$work/results"
if [[ -n $failed ]]; then
  echo "FAIL  drill-k8s-supplychain:$failed" >&2
  exit 1
fi
echo "drill-k8s-supplychain: no case failed"
