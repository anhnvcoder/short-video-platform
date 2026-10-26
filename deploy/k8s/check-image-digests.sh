#!/usr/bin/env bash
# Static check that every third-party image the cluster's charts render is pinned by digest.
# A tag can be pushed again to other content; a digest cannot, and
# Kyverno checks only the seven service images at admission, so the images of the platform namespaces are held to their
# digests here, before a merge, instead.
#
# Renders, with `helm template --include-crds` and the values the GitOps path uses, every component of
# deploy/argocd/apps/components.json (upstream charts at their pinned versions, the repository's own charts) and the
# Argo CD chart deploy/k8s/gitops.sh installs (its version read from that script). Lists every image: the values of
# image fields (image:, imageName:, ...), and image references inside args, env and config files (an operator's
# --xxx-image=... flag, an env value it starts pods from). A setting whose name says it holds an image (an env name or
# upper-case key with the word IMAGE, a flag with "image") counts even without a registry, as busybox:1.37 or alpine.
# The seven service images are left out: CI signs them and Kyverno verifies them. Exits 1 listing every other image
# without exactly one @sha256:<64 hex>.
#
# Every environment runs the images built once for the base: a component with an overlay in deploy/k8s/envs/<env>/ is
# rendered again with it after its values, as Argo CD reads them, and the images of that render, the seven service
# images included, must be exactly those of the base render. Exits 1 naming each overlay that adds, drops or changes
# one.
#
# Usage: deploy/k8s/check-image-digests.sh [ROOT]
#   ROOT: a directory laid out like this repository (default: the repository), from which components.json, every values
#   file and overlay, the repository's charts and gitops.sh are read; a copy with one values file changed shows what the check
#   reports for it. Nothing is written outside a temporary directory; no cluster is needed. Needs helm, jq and network
#   access to the chart repositories.
set -euo pipefail

root=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
components=$root/deploy/argocd/apps/components.json
gitops=$root/deploy/k8s/gitops.sh
service_chart=deploy/helm/svp-service

fail() {
  echo "FAIL  $1" >&2
  exit 1
}

# Images a chart renders without any value to override them, so they cannot carry a digest: "image|reason", the image
# as rendered. None at the moment. Images an operator starts from its own code and the chart never renders (the Envoy
# proxy of Envoy Gateway, CloudNativePG's default Postgres image) are not seen here at all; the values files say where
# each of them is pinned.
exceptions=()

[ -f "$components" ] || fail "$components is missing"
argocd_version=$(sed -n 's/^argocd_chart_version=//p' "$gitops")
[ -n "$argocd_version" ] || fail "no argocd_chart_version= line in $gitops"

tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
# Helm's repository list, index cache and pulled charts stay in the temporary directory: no repository is added to the
# user's configuration, and .k8s/helm of the dev path is not touched.
export HELM_CACHE_HOME=$tmp/helm/cache HELM_CONFIG_HOME=$tmp/helm/config HELM_DATA_HOME=$tmp/helm/data
mkdir -p "$tmp/out"

# A service release whose values have no tag yet (none released, or no digest written yet) fails the chart's
# `required`; it is rendered again with a syntactically valid placeholder for both, which goes down the same branch a
# release does. The service image itself is left out of the check below, so the placeholder never counts.
placeholder=(--set-string image.tag=000000000000
  --set-string image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000)

# One line per component, fields separated by the ASCII unit separator so empty fields survive `read`.
sep=$'\x1f'
list=$(jq -r '.components[] | [.name, .namespace, (.path // ""), (.repo // ""), (.chart // ""), (.version // ""),
  (.values // "")] | join("\u001f")' "$components") || fail "read $components"
list+=$'\n'"argocd${sep}argocd${sep}${sep}https://argoproj.github.io/argo-helm${sep}argo-cd${sep}$argocd_version${sep}deploy/k8s/values/argo-cd.yaml"

rendered=0
overlays=0
while IFS=$sep read -r name namespace path repo chart version values; do
  args=(template "$name" --namespace "$namespace" --include-crds)
  if [ -n "$path" ]; then
    args+=("$root/$path")
  elif [[ $repo == oci://* ]]; then
    args+=("$repo/$chart" --version "$version")
  else
    args+=("$chart" --repo "$repo" --version "$version")
  fi
  if [ -n "$values" ]; then args+=(--values "$root/$values"); fi
  out=$tmp/out/$name.yaml
  if ! helm "${args[@]}" >"$out" 2>"$tmp/err"; then
    [ "$path" = "$service_chart" ] && helm "${args[@]}" "${placeholder[@]}" >"$out" 2>"$tmp/err" ||
      { cat "$tmp/err" >&2; fail "helm template $name"; }
    args+=("${placeholder[@]}")
  fi
  rendered=$((rendered + 1))
  # The same render with each environment's overlay of the component last, into env/<env>/<name>.yaml.
  for overlay in "$root"/deploy/k8s/envs/*/"$name.yaml"; do
    [ -f "$overlay" ] || continue
    env=$(basename "$(dirname "$overlay")")
    mkdir -p "$tmp/env/$env"
    helm "${args[@]}" --values "$overlay" >"$tmp/env/$env/$name.yaml" 2>"$tmp/err" ||
      { cat "$tmp/err" >&2; fail "helm template $name with deploy/k8s/envs/$env/$name.yaml"; }
    overlays=$((overlays + 1))
  done
done <<<"$list"

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

images=$tmp/images
for out in "$tmp"/out/*.yaml; do
  image_refs "$(basename "$out" .yaml)" "$out"
done | sort -u >"$images"

# Each overlay's render against the base's, every image compared, the service images included.
drift=
for out in "$tmp"/env/*/*.yaml; do
  [ -f "$out" ] || continue
  name=$(basename "$out" .yaml)
  env=$(basename "$(dirname "$out")")
  image_refs "$name" "$out" | sort -u >"$tmp/env-images"
  if ! diff=$(awk -F '\t' -v n="$name" '$1 == n' "$images" | diff - "$tmp/env-images"); then
    drift+="  deploy/k8s/envs/$env/$name.yaml (< base, > $env):"$'\n'"$(sed 's/^/    /' <<<"$diff")"$'\n'
  fi
done

total=0 pinned=0 excepted=0 services=0
missing=
while IFS=$'\t' read -r name ref; do
  # The seven service images: registry k3d-svp-registry:5111 (dev path) or GHCR (releases), any tag or digest.
  case $ref in
    */svp/gateway[:@]* | */svp/user-service[:@]* | */svp/video-service[:@]* | */svp/engagement-service[:@]* | \
      */svp/feed-service[:@]* | */svp/media-worker[:@]* | */svp/web[:@]* | \
      ghcr.io/anhnvcoder/short-video-platform/gateway[:@]* | ghcr.io/anhnvcoder/short-video-platform/user-service[:@]* | \
      ghcr.io/anhnvcoder/short-video-platform/video-service[:@]* | \
      ghcr.io/anhnvcoder/short-video-platform/engagement-service[:@]* | \
      ghcr.io/anhnvcoder/short-video-platform/feed-service[:@]* | \
      ghcr.io/anhnvcoder/short-video-platform/media-worker[:@]* | ghcr.io/anhnvcoder/short-video-platform/web[:@]*)
      services=$((services + 1))
      continue
      ;;
  esac
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

echo "charts rendered: $rendered, with an environment's overlay: $overlays; third-party images: $total, pinned by digest: $pinned, exceptions: $excepted; service images left out: $services"
if [ -n "$drift" ]; then
  printf 'FAIL  overlays whose render runs other images than the base:\n%s' "$drift" >&2
fi
if [ -n "$missing" ]; then
  printf 'FAIL  images without exactly one @sha256:<64 hex>:\n%s' "$missing" >&2
fi
[ -z "$drift$missing" ] || exit 1
echo "ok    every third-party image is pinned by digest; every overlay runs the images of the base"
