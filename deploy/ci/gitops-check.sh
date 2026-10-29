#!/usr/bin/env bash
# gitops-check.sh GITOPS_DIR [BASE]: the check of a tree of the deployment repository svp-gitops (base/, envs/,
# argocd/), run by that repository's workflow from a checkout of this repository at a pinned commit, and on a machine
# against a clone. Exit 0 when every step passes; each step prints one line per thing it checked, FAIL lines on stderr.
#
#   1. The tree: envs/ holds exactly stg and prd. Each envs/<env>/charts.yaml holds exactly revision (a full commit of
#      this repository on origin/main), podSecurityVersion and collectorConfigSha256, both equal to what that commit
#      gives (podSecurityVersion of deploy/helm/svp-cluster/values.yaml, the sha256 of
#      deploy/observability/otelcol/k8s-config.yaml). envs/<env>/images/ holds exactly one file per service, each the
#      image block alone (repository of that service on GHCR, tag, digest), and the commit each tag names is revision
#      or one of its ancestors: an image never runs with charts older than its code (a new environment variable the
#      chart does not set yet).
#   2. The root chart argocd/apps for each environment on amd64 and arm64 nodes (helm lint and template): it fails
#      when an overlay or an image file breaks its rules. Argo Rollouts gets exactly one traffic router plugin on each
#      architecture, the asset built for it, both of one release.
#   3. The charts of this repository (deploy/helm/*, at the revision of each environment) with base/ alone and with
#      the environment's overlay and image file, as Argo CD reads them (helm lint and template); no render of prd names
#      svp.localhost. Chart svp-cluster: no ExternalSecret or SecretStore with base/ alone (the dev path's), one
#      ExternalSecret per entry of its files/external-secrets.yaml and one SecretStore per namespace there in each
#      environment (provider kubernetes in stg, aws in prd, no svp-secrets in prd), valid against the CRDs of the
#      External Secrets chart components.json pins (kubeconform -strict in KUBECONFORM_IMAGE of the Makefile).
#   4. Every third-party image of every component and of Argo CD (argocd/bootstrap.json) pinned by digest, and no
#      overlay changing an image: deploy/k8s/check-image-digests.sh on a copy of the tree laid out as it reads one.
#   5. deploy/ci/values-check.sh --gitops on the image files changed from commit BASE to HEAD of GITOPS_DIR (every one
#      without BASE): signed release, vuln attestation, and the build provenance the environment's policy asks for.
#
# GITOPS_DIR is read, never written: everything else happens in a temporary directory. Needs bash, git, jq, helm,
# docker and network access (chart repositories, GHCR), and the history of this repository up to every revision and
# image tag (a full clone, origin/main fetched). With BASE, GITOPS_DIR must be the top of its own git repository.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"

[ $# -ge 1 ] && [ $# -le 2 ] || fail "usage: gitops-check.sh GITOPS_DIR [BASE]"
tree=$(cd "$1" 2>/dev/null && pwd -P) || fail "$1 is not a directory"
base=${2:-}
for tool in git jq helm docker; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
main=origin/main
envs="prd stg"
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
# revision_of ENV: the revision of envs/ENV/charts.yaml, once step 1 has checked it.
revision_of() {
  charts_field "$1" revision
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
  if ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
    problem "envs/$env/charts.yaml: revision is '$rev', the full commit (40 hex) of this repository whose charts $env runs"
    continue
  fi
  if ! git -C "$repo_root" cat-file -e "$rev^{commit}" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision $rev is no commit of this clone of the code repository (fetch its whole history)"
    continue
  fi
  if ! git -C "$repo_root" merge-base --is-ancestor "$rev" "$main" 2>/dev/null; then
    problem "envs/$env/charts.yaml: revision ${rev:0:12} is not on $main of the code repository"
    continue
  fi
  want=$(git -C "$repo_root" show "$rev:deploy/helm/svp-cluster/values.yaml" | sed -n 's/^podSecurityVersion: *//p')
  got=$(charts_field "$env" podSecurityVersion)
  [ "$got" = "$want" ] ||
    problem "envs/$env/charts.yaml: podSecurityVersion is '$got', deploy/helm/svp-cluster/values.yaml at ${rev:0:12} pins '$want'"
  want=$(git -C "$repo_root" show "$rev:deploy/observability/otelcol/k8s-config.yaml" | shasum -a 256 | cut -d' ' -f1)
  got=$(charts_field "$env" collectorConfigSha256)
  [ "$got" = "$want" ] ||
    problem "envs/$env/charts.yaml: collectorConfigSha256 is '$got', deploy/observability/otelcol/k8s-config.yaml at ${rev:0:12} has sha256 $want"
  echo "ok    envs/$env/charts.yaml: charts of ${rev:0:12} on $main, podSecurityVersion and collectorConfigSha256 as that commit gives them"

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
    if [ "$repo" != "$ghcr_prefix/$svc" ] || [ -z "$tag" ] || [ -z "$digest" ]; then
      problem "$file: the image must be a release of $ghcr_prefix/$svc with its tag and digest, not '$repo' '$tag' '$digest'"
      continue
    fi
    if ! commit=$(git -C "$repo_root" rev-parse --verify --quiet "$tag^{commit}"); then
      problem "$file: tag $tag names no commit of this clone of the code repository"
      continue
    fi
    git -C "$repo_root" merge-base --is-ancestor "$commit" "$rev" ||
      problem "$file: tag $tag is no ancestor of revision ${rev:0:12} of envs/$env/charts.yaml: the image would run with charts older than its code"
  done
  echo "ok    envs/$env/images/: seven releases of $ghcr_prefix, each built at or before ${rev:0:12}"
done
step "the tree $tree"

# The charts of this repository at each environment's revision, unpacked with git archive: neither the working tree
# nor the index of this clone is read. All of deploy/, since files of the charts are symlinks to files beside them
# (deploy/postgres/bootstrap.sql, the Collector's config, the Prometheus rules).
for env in $envs; do
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
  echo "ok    argocd/apps in $env on arm64 and amd64 nodes; Argo Rollouts gets plugin $arm_name of ${arm_loc%/*}, the asset built for each"
done

# --- 3. the charts of this repository
jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' "$components" >"$tmp/charts"
while IFS=$'\t' read -r name ns path values; do
  for env in $envs; do
    rev=$(revision_of "$env")
    chart=$tmp/code/$rev/$path
    [ -d "$chart" ] || fail "component $name: no chart $path at ${rev:0:12} (revision of envs/$env/charts.yaml)"
    set -- --namespace "$ns"
    [ -z "$values" ] || set -- "$@" -f "$tree/$values"
    # Alone, base/ has no image for a release of chart svp-service: a placeholder renders it as the dev path's does.
    if [ "$path" = "$service_chart" ]; then
      base_args=("$@" --set-string "image.repository=$ghcr_prefix/$name" --set-string image.tag=000000000000
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
        fail "helm lint and template of $name ($path at ${rev:0:12}) with the values of $kind"
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
  rev=$(revision_of "$env")
  if grep -Eq '^kind: (ExternalSecret|SecretStore)$' "$tmp/render/base-$env-svp-cluster.yaml"; then
    fail "svp-cluster at ${rev:0:12} with base/ alone (the dev path's) renders an ExternalSecret or a SecretStore"
  fi
  list=$tmp/code/$rev/deploy/helm/svp-cluster/files/external-secrets.yaml
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
  helm template svp-cluster "$tmp/code/$rev/deploy/helm/svp-cluster" "$@" --show-only templates/external-secrets.yaml \
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

# --- 4. image digests: deploy/k8s/check-image-digests.sh reads a tree laid out as this repository, so each revision
# of the charts gets one: components.json with its values under deploy/k8s/values/, base/ there, the overlays of the
# environments of that revision under deploy/k8s/envs/, the charts at that revision, and the version of the Argo CD
# chart where the script reads it. The release images are left out of its pin check; they are the image files, which
# step 1 and step 5 check, so the copy has none.
bootstrap=$tree/argocd/bootstrap.json
[ "$(jq -r '"\(.repo) \(.chart)"' "$bootstrap")" = "https://argoproj.github.io/argo-helm argo-cd" ] ||
  fail "argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm"
argocd_version=$(jq -r '.version' "$bootstrap")
argocd_values=$(jq -r '.values' "$bootstrap")
[ -f "$tree/$argocd_values" ] || fail "argocd/bootstrap.json: values file $argocd_values is missing"
for rev in $(for env in $envs; do revision_of "$env"; done | sort -u); do
  layout=$tmp/digests/$rev
  mkdir -p "$layout/deploy/argocd/apps" "$layout/deploy/k8s/envs"
  jq '.components[] |= (if .values then .values |= sub("^base/"; "deploy/k8s/values/") else . end
    | if .archValues then .archValues |= map_values(sub("^base/"; "deploy/k8s/values/")) else . end)' \
    "$components" >"$layout/deploy/argocd/apps/components.json"
  cp -R "$tree/base" "$layout/deploy/k8s/values"
  cp "$tree/$argocd_values" "$layout/deploy/k8s/values/argo-cd.yaml"
  # The repository of each release without tag or digest, which the script then renders with a placeholder for both.
  for svc in "${svp_services[@]}"; do
    printf 'image:\n  repository: %s\n  tag: ""\n  digest: ""\n' "$ghcr_prefix/$svc" \
      >>"$layout/deploy/k8s/values/services/$svc.yaml"
  done
  cp -R "$tmp/code/$rev/deploy/helm" "$tmp/code/$rev/deploy/postgres" "$tmp/code/$rev/deploy/redpanda" \
    "$tmp/code/$rev/deploy/s3" "$tmp/code/$rev/deploy/observability" "$layout/deploy/"
  printf 'argocd_chart_version=%s\n' "$argocd_version" >"$layout/deploy/k8s/gitops.sh"
  for env in $envs; do
    [ "$(revision_of "$env")" = "$rev" ] || continue
    mkdir -p "$layout/deploy/k8s/envs/$env"
    find "$tree/envs/$env" -maxdepth 1 -type f -name '*.yaml' ! -name charts.yaml -exec cp {} "$layout/deploy/k8s/envs/$env/" \;
  done
  echo "check-image-digests.sh: charts of ${rev:0:12}, base/, the overlays of $(ls "$layout/deploy/k8s/envs" | paste -sd ' ' -)"
  "$repo_root/deploy/k8s/check-image-digests.sh" "$layout" || fail "image digests with the charts of ${rev:0:12} (above)"
done

# --- 5. the release images
"$ci_dir/values-check.sh" --gitops "$tree" "$base" || fail "the release images (above)"
echo "ok    $tree passes every check"
