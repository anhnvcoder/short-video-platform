#!/usr/bin/env bash
# Static check of the manifests written for the cloud cluster, run by
# `make cloud-check`. Nothing here reaches a cluster or reads .env; it needs helm, jq, git, docker and network access
# (chart repositories, GitHub).
#
#   1. Renders every chart of deploy/k8s/cloud/charts.json with its values (`helm template`, Helm's homes in a temporary
#      directory as in `make helm-check`), and gathers every manifest under deploy/k8s/cloud/ but the values files, every
#      *.yaml / *.yml under deploy/k6/ (none yet is fine: the k6 Jobs come later), and the output of
#      deploy/k6/cloud/render.sh when that script exists (run with no argument, manifests on stdout).
#   2. Turns into JSON schemas, with /openapi2jsonschema of KUBECONFORM_IMAGE (no network), the CRDs of each kind used:
#      the crds/ folder of each pinned chart but Velero's; Velero's from config/crd/ of velero-io/velero at the tag of the
#      image in values/velero.yaml (the chart's crds/ folder is from 1.18.2, the image's CRDs are what the cluster gets);
#      VolumeSnapshotClass from client/config/crd/ of kubernetes-csi/external-snapshotter at snapshotter_tag below,
#      the snapshot controller of the EKS add-on. A kind without a schema fails: there is no -ignore-missing-schemas.
#   3. kubeconform -strict against the Kubernetes schemas of CLOUD_K8S_VERSION at a pinned commit of
#      yannh/kubernetes-json-schema first, then against those CRD schemas. Strict: an unknown field fails, at the root
#      too (DENY_ROOT_ADDITIONAL_PROPERTIES).
#   4. What a schema cannot say: every Chaos Mesh experiment has a duration of at most 30 minutes and a selector bound
#      to the one namespace it lives in (svp or svp-data, never kube-system or any other) with a label, expression or
#      pod selector; every image in the rendered charts and the manifests is pinned by exactly one @sha256:<64 hex>.
#
# Usage: deploy/k8s/cloud/check.sh [ROOT]
#   ROOT: a directory laid out like this repository (default: the repository), from which deploy/k8s/cloud/ and
#   deploy/k6/ are read; a copy with one field broken shows what the check reports for it. Nothing is written outside a
#   temporary directory. KUBECONFORM_IMAGE and CLOUD_K8S_VERSION come from the Makefile.
set -euo pipefail

root=$(cd "${1:-$(dirname "$0")/../../..}" && pwd)
cloud=$root/deploy/k8s/cloud
: "${KUBECONFORM_IMAGE:?set KUBECONFORM_IMAGE (run make cloud-check)}"
: "${CLOUD_K8S_VERSION:?set CLOUD_K8S_VERSION (run make cloud-check)}"

# yannh/kubernetes-json-schema at a commit, not master: the schemas a check passes against do not move under it.
k8s_schemas_commit=f7d855e49c34b039c9ef2196444910275e31e09e
# The snapshot CRDs: v8.7.0 was the newest release at least 3 days old when this was written. Stage 7 aligns it with the
# EKS snapshot controller add-on.
snapshotter_tag=v8.7.0
# Namespaces an experiment may target: svp (experiments a and b) and svp-data (experiment c, Redpanda).
chaos_namespaces='["svp","svp-data"]'

fail() {
  echo "FAIL  $1" >&2
  exit 1
}

[ -f "$cloud/charts.json" ] || fail "$cloud/charts.json is missing"

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
export HELM_CACHE_HOME=$tmp/helm/cache HELM_CONFIG_HOME=$tmp/helm/config HELM_DATA_HOME=$tmp/helm/data
mkdir -p "$tmp/manifests" "$tmp/crds" "$tmp/schemas" "$tmp/charts" "$tmp/y2j/in" "$tmp/y2j/templates"
docker_run=(env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$(id -u):$(id -g)")

# add_manifest FILE NAME: copies FILE into the set kubeconform and the extra checks read, under NAME (a repository path
# with / turned into __, so a finding names its source).
add_manifest() {
  cp "$1" "$tmp/manifests/$(printf '%s' "$2" | sed 's#/#__#g')"
}

# YAML to JSON lines without a YAML tool: Helm's fromYaml in a throwaway chart, one {"file", "doc"} object per document
# of every file in $tmp/y2j/in.
cat >"$tmp/y2j/Chart.yaml" <<'EOF'
apiVersion: v2
name: y2j
version: 0.0.0
EOF
cat >"$tmp/y2j/templates/out.yaml" <<'EOF'
{{- range $path, $_ := .Files.Glob "in/*" }}
{{- range regexSplit "(?m)^---[ \t]*$" ($.Files.Get $path) -1 }}
{{- $doc := fromYaml . }}
{{- if hasKey $doc "Error" }}{{ fail (printf "%s: %s" $path (get $doc "Error")) }}{{ end }}
{{- if $doc }}
{{ dict "file" (base $path) "doc" $doc | toJson }}
{{- end }}
{{- end }}
{{- end }}
EOF
yaml2json() {
  helm template y2j "$tmp/y2j" | grep '^{' || true
}

# 1. Charts and manifests.
sep=$'\x1f'
list=$(jq -r '.charts[] | [.name, .namespace, .repo, .chart, .version, (.values // "")] | join("\u001f")' \
  "$cloud/charts.json") || fail "read $cloud/charts.json"
charts=0
while IFS=$sep read -r name namespace repo chart version values; do
  args=(template "$name" "$chart" --repo "$repo" --version "$version" --namespace "$namespace")
  if [ -n "$values" ]; then args+=(--values "$root/$values"); fi
  helm "${args[@]}" >"$tmp/manifests/rendered__$name.yaml" 2>"$tmp/err" || { cat "$tmp/err" >&2; fail "helm template $name"; }
  helm pull "$chart" --repo "$repo" --version "$version" --untar --untardir "$tmp/charts/$name" 2>"$tmp/err" ||
    { cat "$tmp/err" >&2; fail "helm pull $name"; }
  # Velero's CRDs come from its source at the image's tag (step 2), not from the chart.
  if [ "$name" != velero ] && [ -d "$tmp/charts/$name/$chart/crds" ]; then
    for f in "$tmp/charts/$name/$chart/crds"/*.yaml; do cp "$f" "$tmp/crds/$name-$(basename "$f")"; done
  fi
  charts=$((charts + 1))
done <<<"$list"

files=0
while IFS= read -r f; do
  add_manifest "$f" "${f#"$root"/}"
  files=$((files + 1))
done < <(find "$cloud" -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path "$cloud/values/*" | sort)
if [ -d "$root/deploy/k6" ]; then
  while IFS= read -r f; do
    add_manifest "$f" "${f#"$root"/}"
    files=$((files + 1))
  done < <(find "$root/deploy/k6" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
fi
if [ -f "$root/deploy/k6/cloud/render.sh" ]; then
  bash "$root/deploy/k6/cloud/render.sh" >"$tmp/manifests/rendered__k6-cloud.yaml" || fail "deploy/k6/cloud/render.sh"
  files=$((files + 1))
fi
echo "rendered $charts charts; $files manifest files"

# 2. CRD schemas. The tag of the Velero image is read from its values file, so a Renovate update of the image moves the
# schemas with it.
cp "$root/deploy/k8s/cloud/values/velero.yaml" "$tmp/y2j/in/velero-values.yaml"
velero_tag=$(yaml2json | jq -r '.doc.image.tag // empty' | sed 's/@.*//')
rm "$tmp/y2j/in/velero-values.yaml"
[[ $velero_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "no vX.Y.Z image tag in deploy/k8s/cloud/values/velero.yaml (got '$velero_tag')"

# sparse_crds URL TAG DIR NAME: the CRD files under DIR of the repository at URL, tag TAG, without the rest of it.
sparse_crds() {
  local dest=$tmp/src/$4
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$2" --filter=blob:none --sparse "$1" "$dest" ||
    fail "git clone $1 at $2"
  git -C "$dest" sparse-checkout set "$3" || fail "sparse checkout of $3 in $1"
  local n=0 f
  while IFS= read -r f; do
    cp "$f" "$tmp/crds/$4-$(basename "$f")"
    n=$((n + 1))
  done < <(find "$dest/$3" -type f -name '*.yaml' | sort)
  [ "$n" -gt 0 ] || fail "no CRD under $3 of $1 at $2"
}
sparse_crds https://github.com/velero-io/velero.git "$velero_tag" config/crd velero
sparse_crds https://github.com/kubernetes-csi/external-snapshotter.git "$snapshotter_tag" client/config/crd snapshotter

crds=()
for f in "$tmp/crds"/*.yaml; do crds+=("/crds/$(basename "$f")"); done
"${docker_run[@]}" --network none -v "$tmp/crds:/crds:ro" -v "$tmp/schemas:/schemas" --workdir /schemas \
  -e 'FILENAME_FORMAT={kind}-{fullgroup}-{version}' -e DENY_ROOT_ADDITIONAL_PROPERTIES=1 \
  --entrypoint /openapi2jsonschema "$KUBECONFORM_IMAGE" "${crds[@]}" >"$tmp/o2j.log" 2>&1 ||
  { cat "$tmp/o2j.log" >&2; fail "openapi2jsonschema"; }
echo "CRD schemas: ${#crds[@]} CRD files (charts but Velero, velero-io/velero $velero_tag, external-snapshotter $snapshotter_tag)"

failed=0

# 3. kubeconform. The Kubernetes schemas are fetched from GitHub at the pinned commit; a CRD kind is not found there and
# falls through to the generated schemas.
if "${docker_run[@]}" -v "$tmp/manifests:/manifests:ro" -v "$tmp/schemas:/schemas:ro" "$KUBECONFORM_IMAGE" \
  -strict -summary -kubernetes-version "$CLOUD_K8S_VERSION" \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$k8s_schemas_commit/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
  -schema-location '/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' \
  /manifests; then
  echo "ok    kubeconform -strict (Kubernetes $CLOUD_K8S_VERSION)"
else
  echo "FAIL  kubeconform -strict (Kubernetes $CLOUD_K8S_VERSION)" >&2
  failed=1
fi

# 4. What the schemas cannot say, on every document as JSON.
cp "$tmp/manifests"/* "$tmp/y2j/in/"
yaml2json >"$tmp/docs.jsonl"

chaos=$(jq -r --argjson allowed "$chaos_namespaces" '
  select((.doc.apiVersion // "") | startswith("chaos-mesh.org/"))
  | (.file | gsub("__"; "/")) as $f | .doc as $d
  | ($d.metadata.namespace // "") as $ns | ($d.spec.selector.namespaces // []) as $sel
  | ($d.spec.duration // "") as $dur
  | [
      (if ($dur | type) != "string" or ($dur | test("^[0-9]+(s|m)$") | not) then
         "spec.duration missing or not <n>s / <n>m (got \($dur | tojson))"
       elif ($dur | test("s$") and (rtrimstr("s") | tonumber) > 1800)
         or ($dur | test("m$") and (rtrimstr("m") | tonumber) > 30) then
         "spec.duration \($dur) is longer than 30 minutes"
       else empty end),
      (if ($ns | IN($allowed[]) | not) then
         "metadata.namespace \($ns | tojson) is not one of \($allowed | join(", "))"
       else empty end),
      (if ($sel | type) != "array" or $sel != [$ns] then
         "spec.selector.namespaces must be exactly [\($ns)], its own namespace (got \($sel | tojson))"
       else empty end),
      (if (($d.spec.selector.labelSelectors // {}) | length) == 0
          and (($d.spec.selector.expressionSelectors // []) | length) == 0
          and (($d.spec.selector.pods // {}) | length) == 0 then
         "no labelSelectors, expressionSelectors or pods: it would hit every pod of the namespace"
       else empty end),
      ((($d.spec.selector.pods // {}) | keys[]) | select(. != $ns) | "spec.selector.pods names namespace \(.)")
    ]
  | .[] | "  \($f): \($d.kind) \($d.metadata.name // "?"): \(.)"
' "$tmp/docs.jsonl") || fail "read the manifests as JSON"
experiments=$(jq -r 'select((.doc.apiVersion // "") | startswith("chaos-mesh.org/")) | .file' "$tmp/docs.jsonl" | wc -l | tr -d ' ')
if [ -n "$chaos" ]; then
  printf 'FAIL  Chaos Mesh experiments without a bounded duration or a selector bound to their namespace:\n%s\n' "$chaos" >&2
  failed=1
elif [ "$experiments" -eq 0 ]; then
  echo "FAIL  no Chaos Mesh experiment found under deploy/k8s/cloud/chaos/" >&2
  failed=1
else
  echo "ok    $experiments Chaos Mesh experiments: duration <= 30m, selector bound to their own namespace"
fi

# Images: every string field named image, and every env value whose name has the word IMAGE (the pause image of
# pod-failure is one), CRDs left out.
images=$(jq -r '
  select(.doc.kind != "CustomResourceDefinition")
  | (.file | gsub("__"; "/")) as $f
  | (.doc | [.. | objects | .image? | strings]
      + [.. | objects | select((.name? | type) == "string" and (.name | test("(^|_)IMAGES?(_|$)")))
         | .value? | strings])[]
  | "\($f)\t\(.)"
' "$tmp/docs.jsonl" | sort -u) || fail "read the images of the manifests"
total=0
missing=
while IFS=$'\t' read -r f ref; do
  [ -n "$ref" ] || continue
  total=$((total + 1))
  [[ $ref =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]] || missing+="  $f: $ref"$'\n'
done <<<"$images"
if [ -n "$missing" ]; then
  printf 'FAIL  images without exactly one @sha256:<64 hex>:\n%s' "$missing" >&2
  failed=1
else
  echo "ok    $total image references, every one pinned by digest"
fi

[ "$failed" -eq 0 ] || exit 1
echo "ok    cloud manifests"
