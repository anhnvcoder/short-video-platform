# Build, generate, lint and test entry point for the monorepo. `make help` lists the targets.

# Pinned tool versions, installed by `make tools` rather than as `tool` directives in go.mod: sqlc and golangci-lint
# would pull hundreds of modules into the application's dependency graph, and `go install` builds each of them with
# this machine's Go.
# The "# renovate:" line above a pin names where Renovate looks up its new versions (renovate.json; go = the Go module
# proxy, the module `go install` builds).
# renovate: datasource=go depName=google.golang.org/protobuf
PROTOC_GEN_GO_VERSION      := v1.36.12
# renovate: datasource=go depName=google.golang.org/grpc/cmd/protoc-gen-go-grpc
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2
# renovate: datasource=go depName=github.com/sqlc-dev/sqlc
SQLC_VERSION               := v1.31.1
# renovate: datasource=go depName=github.com/golangci/golangci-lint/v2
GOLANGCI_LINT_VERSION      := v2.14.0
# renovate: datasource=go depName=github.com/zricethezav/gitleaks/v8
GITLEAKS_VERSION           := v8.30.1
# SLO rule generator: Sloth turns the SLO spec into Prometheus recording and burn-rate alert rules. `go install` leaves
# the version empty and Sloth would then write "dev" in the header of the file it generates.
# renovate: datasource=go depName=github.com/slok/sloth
SLOTH_VERSION              := v0.16.0
# Local Kubernetes (k3d, cluster svp). Without both -X flags k3d reports v5-dev and
# pulls its proxy and tools images as :latest, and its default node image is an older k3s; the node image itself is
# pinned by digest in deploy/k8s/k3d.yaml.
# renovate: datasource=go depName=github.com/k3d-io/k3d/v5
K3D_VERSION                := v5.9.0
# renovate: datasource=docker depName=rancher/k3s
K3S_IMAGE_TAG              := v1.36.5-k3s1
# One line on purpose: a backslash-newline inside the single quotes of a recipe reaches the shell as a literal backslash
# on GNU Make 4.x (Make 3.81 joined the lines), and the linker then gets a broken -ldflags.
K3D_LDFLAGS                := -X github.com/k3d-io/k3d/v5/version.Version=$(K3D_VERSION) -X github.com/k3d-io/k3d/v5/version.K3sVersion=$(K3S_IMAGE_TAG)
# Linter of the GitHub Actions workflows, run by `make actionlint` inside `make check`. It also runs shellcheck on every
# `run:` script when shellcheck is on PATH: the CI runner has it, a dev machine need not.
# renovate: datasource=go depName=github.com/rhysd/actionlint
ACTIONLINT_VERSION         := v1.7.12
# Go vulnerability scanner of `make vulncheck`: reports only what the code can reach through its call graph.
# renovate: datasource=go depName=golang.org/x/vuln
GOVULNCHECK_VERSION        := v1.9.0

# CI only (`make ci-tools`, Linux amd64 runner): a dev machine installs buf and Helm with Homebrew at these versions.
# Helm's archive is checked against the sha256 published with the release (helm-<version>-linux-amd64.tar.gz.sha256sum),
# so the two lines change together; `go install` of Helm is not a documented way and reports a wrong version.
# renovate: datasource=go depName=github.com/bufbuild/buf
BUF_VERSION                := v1.74.0
# renovate: datasource=github-releases depName=helm/helm
HELM_VERSION               := v4.3.1
HELM_LINUX_AMD64_SHA256    := 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
# Scanner and SBOM generator, run from their official images pinned by digest, the same reference on a dev machine and
# in CI: nothing to install and no setup action to trust (both trivy setup actions were hijacked in March 2026), and a
# digest cannot be moved like a tag.
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=ghcr.io/anchore/syft
SYFT_IMAGE  := ghcr.io/anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa
# Second vulnerability gate of every image, on the SBOM syft writes (deploy/ci/build-image.sh, make grype).
# renovate: datasource=docker depName=ghcr.io/anchore/grype
GRYPE_IMAGE := ghcr.io/anchore/grype:v0.121.0@sha256:621d56d1d68106b787022c81546f7e0a36202a25d1239f0c20195fab8c16f7ea
# cosign on a dev machine, to verify releases only (deploy/ci/verify-release.sh, and `make k8s-gitops-up` before it
# creates anything): signing happens in CI alone, with the cosign that sigstore/cosign-installer installs there.
# renovate: datasource=docker depName=ghcr.io/sigstore/cosign/cosign
COSIGN_IMAGE := ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8
# Load generator of the SLO scripts in deploy/k6/, from its official image
# pinned by digest: the same k6 on a dev machine, in CI and as a Job in the cloud cluster, where the 1 000 req/s run has to
# start inside the cluster to measure the system rather than the home network. The k6 of Homebrew is not pinned. v2: the v1
# line only gets security fixes.
# renovate: datasource=docker depName=grafana/k6
K6_IMAGE := grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34
# DAST of the gateway against its OpenAPI contract (make dast), from the official image pinned by digest, the same on a
# dev machine and in the CI job stack.
# renovate: datasource=docker depName=schemathesis/schemathesis
SCHEMATHESIS_IMAGE := schemathesis/schemathesis:4.32.4@sha256:b501f25d00fa6e2b393ddd1b525a11bb560d593fd06268491595c2e439090bf0
# Schema check of the manifests written for the cloud cluster (make cloud-check), with nothing
# installed: the image is FROM scratch with kubeconform and openapi2jsonschema, which turns the CRDs of the pinned charts
# into schemas, so no Python is needed. It runs as root unless docker run gets --user.
# renovate: datasource=docker depName=ghcr.io/yannh/kubeconform
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e

# Tools installed by `go install` land here; the PATH of the caller is not assumed to contain it.
GOBIN ?= $(shell go env GOPATH)/bin
export PATH := $(GOBIN):$(PATH)

# Packages for vet, lint and test; narrow them with e.g. `make test PKGS=./services/user-service/...`.
PKGS ?= ./...
# Extra flags put before the packages, empty by default: `make test TESTFLAGS=-count=1` runs every test again instead of
# reporting cached results; CI passes LINTFLAGS to add a SARIF report beside golangci-lint's text output.
TESTFLAGS ?=
LINTFLAGS ?=

# Local dev Postgres superuser DSN, published in CLAUDE.md; integration tests create their own databases from it.
SVP_TEST_POSTGRES_URL ?= postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
# Local Redis, db 15: the project's test database, used by no service or other project, so tests never touch their data
# and never need FLUSHDB.
SVP_TEST_REDIS_URL ?= redis://127.0.0.1:6379/15

.DEFAULT_GOAL := help

.PHONY: help tools ci-tools generate generate-go generate-check slo otelcol-validate fmt-check vet lint actionlint buf-lint vulncheck test fuzz \
	cover check check-go helm-check trivy-config web-lockfile-scan grype renovate-check hooks web-install web-dev web-generate web-generate-check \
	web-check web-e2e measure-web measure-upload web-lighthouse web-sourcemaps

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned code generators, linters, vulnerability and secret scanners, SLO generator and k3d into GOBIN
	GOBIN=$(GOBIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(GOBIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	GOBIN=$(GOBIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(GOBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	GOBIN=$(GOBIN) go install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)
	GOBIN=$(GOBIN) go install golang.org/x/vuln/cmd/govulncheck@$(GOVULNCHECK_VERSION)
	GOBIN=$(GOBIN) go install github.com/zricethezav/gitleaks/v8@$(GITLEAKS_VERSION)
	GOBIN=$(GOBIN) go install -ldflags='-X github.com/slok/sloth/internal/info.Version=$(SLOTH_VERSION)' \
		github.com/slok/sloth/cmd/sloth@$(SLOTH_VERSION)
	GOBIN=$(GOBIN) go install -ldflags='$(K3D_LDFLAGS)' github.com/k3d-io/k3d/v5@$(K3D_VERSION)

# Refuses anything but Linux x86_64: the Helm it installs is the linux-amd64 build, and GOBIN comes first on PATH, so on
# a Mac it would shadow Homebrew's helm and break every helm call with "exec format error".
ci-tools: ## CI only (Linux amd64): install buf and Helm at the pinned versions into GOBIN (a dev machine uses Homebrew)
	@[ "$$(uname -sm)" = "Linux x86_64" ] || { echo "make ci-tools runs only on Linux x86_64 (CI), not on \
	$$(uname -sm): a dev machine installs buf and Helm with Homebrew" >&2; exit 1; }
	GOBIN=$(GOBIN) go install github.com/bufbuild/buf/cmd/buf@$(BUF_VERSION)
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	curl -fsSL -o "$$tmp/helm.tar.gz" https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz || exit 1; \
	echo "$(HELM_LINUX_AMD64_SHA256)  $$tmp/helm.tar.gz" | sha256sum -c - || exit 1; \
	tar -xzf "$$tmp/helm.tar.gz" -C "$$tmp" linux-amd64/helm || exit 1; \
	install -m 755 "$$tmp/linux-amd64/helm" $(GOBIN)/helm

generate: generate-go web-generate ## Generate all code: Go (generate-go) and the web client's API types (web-generate)

generate-go: ## Generate Go code from proto/ (buf) and from SQL (sqlc, per service)
	buf generate
	@for f in $(wildcard services/*/sqlc.yaml); do echo "sqlc generate -f $$f"; sqlc generate -f $$f || exit 1; done

# Generated Go code must match its sources. `make generate-go` runs
# in a scratch copy of the files git tracks plus the untracked ones it does not ignore (so .env is never read), and the
# result is compared with a second, untouched copy of the same files: the working tree is never written, so uncommitted
# edits of generated code survive, and a file that generation adds counts as a difference too. A tracked file deleted
# from the working tree is left out of both copies. The copy has no web/node_modules, so the web client's types are
# checked by web-generate-check instead.
generate-check: ## Fail when make generate-go would change or add a file: list them and print the diff (writes nothing here)
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	git ls-files -z -co --exclude-standard > "$$tmp/listed" || exit 1; \
	xargs -0 sh -c 'for f; do if [ -e "$$f" ] || [ -L "$$f" ]; then printf "%s\0" "$$f"; fi; done' sh \
		< "$$tmp/listed" > "$$tmp/files" || exit 1; \
	COPYFILE_DISABLE=1 tar -cf "$$tmp/tree.tar" --null -T "$$tmp/files" || exit 1; \
	mkdir "$$tmp/before" "$$tmp/after" && tar -xf "$$tmp/tree.tar" -C "$$tmp/before" \
		&& tar -xf "$$tmp/tree.tar" -C "$$tmp/after" || exit 1; \
	$(MAKE) --no-print-directory -C "$$tmp/after" generate-go || exit 1; \
	cd "$$tmp" || exit 1; \
	if git diff --no-index --quiet before after; then echo "generated code is up to date"; exit 0; fi; \
	echo "make generate-go changes or adds these files (run make generate-go and commit the result):"; \
	git -c core.quotepath=off diff --no-index --no-color --no-ext-diff --name-status before after; \
	git -c core.quotepath=off diff --no-index --no-color --no-ext-diff before after; \
	exit 1

slo: ## Generate the SLO recording and burn-rate alert rules from deploy/observability/slo/svp-slos.yaml (Sloth)
	sloth generate --no-color -i deploy/observability/slo/svp-slos.yaml -o deploy/observability/prometheus/rules/slo-generated.yaml

# The Collector image of `otelcol` and `otelcol-elastic` in deploy/compose/compose.yaml and of
# deploy/k8s/values/otel-collector.yaml (keep the four in step), run with no network and the config
# files at the paths compose mounts them.
# renovate: datasource=docker depName=otel/opentelemetry-collector-contrib
OTELCOL_IMAGE := otel/opentelemetry-collector-contrib:0.162.0@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6
OTELCOL := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none \
	-v $(CURDIR)/deploy/observability/otelcol/config.yaml:/etc/otelcol/config.yaml:ro \
	-v $(CURDIR)/deploy/observability/elastic/otelcol-config.yaml:/etc/otelcol/elastic.yaml:ro \
	-v $(CURDIR)/deploy/observability/otelcol/k8s-config.yaml:/etc/otelcol/k8s.yaml:ro \
	$(OTELCOL_IMAGE)

otelcol-validate: ## Validate the Collector configs with the pinned Collector: obs, obs-elastic (the obs file with the Elastic file merged over it) and the cluster's (k8s-config.yaml)
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml --config=/etc/otelcol/elastic.yaml
	$(OTELCOL) validate --config=/etc/otelcol/k8s.yaml

# web/node_modules is left out: npm packages may ship Go sources of their own (flatted does).
fmt-check: ## Fail and list the files that gofmt would change (generated code excluded)
	@out=$$(find . -name '*.go' -not -path './gen/*' -not -path './.roster/*' -not -path './web/node_modules/*' -print0 \
		| xargs -0 grep -L --null '^// Code generated .* DO NOT EDIT\.$$' | xargs -0 gofmt -l) \
		|| { echo "gofmt failed (syntax error?)" >&2; exit 1; }; \
	if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet: ## go vet
	go vet $(PKGS)

lint: ## golangci-lint run (LINTFLAGS adds flags)
	golangci-lint run $(LINTFLAGS) $(PKGS)

actionlint: ## Lint every workflow of .github/workflows (actionlint)
	@command -v actionlint >/dev/null 2>&1 || { echo "actionlint not found: run make tools" >&2; exit 1; }
	actionlint

buf-lint: ## buf lint and buf build
	buf lint
	buf build -o /dev/null

# The go directive of go.mod is the Go release of the images: govulncheck scans the standard library of exactly that
# release (GOTOOLCHAIN downloads it when the installed Go differs), and tools/vulngate fails when a golang build stage
# of deploy/docker/ uses another one, so the result holds for the released binaries. govulncheck exits 0 in JSON mode
# whatever it finds: the gate decides. The output goes to a file, not a pipe, so a failure of govulncheck itself
# (no network to vuln.go.dev, a build error) fails the target too.
vulncheck: ## govulncheck ./... with the Go of the go directive; called vulnerabilities fail unless excepted in .govulncheck-ignore.json
	@command -v govulncheck >/dev/null 2>&1 || { echo "govulncheck not found: run make tools" >&2; exit 1; }
	@gover=$$(go list -m -f '{{.GoVersion}}') || exit 1; \
	case "$$gover" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "the go directive of go.mod must name a patch release \
	(go 1.27.3), not go $$gover" >&2; exit 1;; esac; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	GOTOOLCHAIN=go$$gover govulncheck -format json ./... > "$$tmp/vuln.json" \
		|| { echo "govulncheck failed (exit $$?): see the error above" >&2; exit 1; }; \
	go run ./tools/vulngate $(wildcard deploy/docker/*.Dockerfile) < "$$tmp/vuln.json"

test: ## go test -race (SVP_TEST_POSTGRES_URL and SVP_TEST_REDIS_URL default to the local Postgres and Redis db 15; TESTFLAGS adds flags, e.g. TESTFLAGS=-count=1)
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race $(TESTFLAGS) $(PKGS)

cover: ## go test -race with coverage into cover.out (same test variables and TESTFLAGS as test), print the total
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race -coverprofile=cover.out $(TESTFLAGS) $(PKGS)
	@go tool cover -func=cover.out | tail -1
	@echo "per line in a browser: go tool cover -html=cover.out"

# How long `make fuzz` fuzzes each target.
FUZZTIME ?= 30s

# go test -fuzz takes one target of one package per run, so the targets run one after another and the first failure
# stops the rest. They are found by reading the *_test.go files, not with go test -list: listing runs TestMain, and a
# TestMain may build a database. No -race: it slows fuzzing down several times, and make test already runs every seed
# with -race. The generated corpus stays in GOCACHE; a failing input goes to testdata/fuzz/<target>/ of its package,
# to be fixed and committed so the seeds keep it.
fuzz: ## Fuzz each Fuzz target of PKGS for FUZZTIME (default 30s), one at a time; stop at the first failure and print its input
	@list=$$(go list -f '{{.ImportPath}} {{.Dir}}' $(PKGS)) || exit 1; \
	targets=$$(printf '%s\n' "$$list" | while read -r pkg dir; do \
		for file in "$$dir"/*_test.go; do [ -f "$$file" ] && sed -nE 's/^func (Fuzz[A-Za-z0-9_]*)\(.*/\1/p' "$$file"; done \
			| sort -u | sed "s|^|$$pkg $$dir |"; \
	done); \
	[ -n "$$targets" ] || { echo "no Fuzz targets in $(PKGS)" >&2; exit 1; }; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	printf '%s\n' "$$targets" | while read -r pkg dir target; do \
		echo "== $$target ($$pkg) for $(FUZZTIME)"; touch "$$tmp/start"; \
		SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' \
			go test -run '^$$' -fuzz "^$$target\$$" -fuzztime $(FUZZTIME) "$$pkg" < /dev/null && continue; \
		echo "fuzz failed: $$target in $$pkg" >&2; \
		find "$$dir/testdata/fuzz/$$target" -type f -newer "$$tmp/start" 2>/dev/null | sed 's|^|failing input: |' >&2; \
		exit 1; \
	done

check: check-go web-check ## Run every check: Go (check-go) and the web client (web-check)

check-go: fmt-check vet lint actionlint buf-lint vulncheck test ## Run the Go, workflow and proto checks

# Every chart of the repository, as the GitOps path renders it: each component of components.json
# with a `path`, under its release name and namespace, with its values file, and the app-of-apps chart itself. A release
# of svp-service whose values carry no image.digest yet (none before the first promotion) gets an all-zero digest, so it
# goes down the digest branch of the GitOps path instead of failing on the dev tag the dev path passes. Helm's cache,
# config and data live in a scratch directory, never in .k8s/helm.
# Each environment of deploy/k8s/envs too: a chart with an overlay there is linted and rendered again with the overlay
# after its values, as Argo CD reads them, and the app-of-apps chart is rendered with value env set to each (it refuses
# an overlay that names no component, or that sets an image or the canary of a service). Production is never deployed by
# this lab, so its render is held to having overridden every k3d name: no svp.localhost anywhere in it.
# The app-of-apps chart is rendered once per node architecture (value nodeArch, which deploy/k8s/gitops.sh sets from
# the nodes): Argo Rollouts' Gateway API plugin is a native binary, so Application argo-rollouts names one more values
# file on amd64 nodes (archValues of components.json). The plugin each architecture gets is read back by merging the
# values files that Application names, in its order, with Helm itself (a scratch chart that prints only the plugin list;
# no upstream chart is fetched): exactly one plugin, the asset built for that architecture, both of the same plugin
# and release, as deploy/k8s/install.sh checks on the dev path.
ZERO_DIGEST := sha256:0000000000000000000000000000000000000000000000000000000000000000
# The Secrets of the GitOps path (chart svp-cluster, externalSecrets): the base render, the dev path's, has no
# ExternalSecret or SecretStore; each environment's has one ExternalSecret per entry of
# deploy/helm/svp-cluster/files/external-secrets.yaml and one SecretStore per namespace that holds them (stg: provider
# kubernetes; prd: provider aws and no namespace svp-secrets). External Secrets Operator runs without its admission
# webhook, so the API server checks these against the CRDs' schemas only: kubeconform -strict (KUBECONFORM_IMAGE, no
# network) checks them against schemas made from the CRDs of the chart version components.json pins, the other kinds
# of that template (ServiceAccount, Role, RoleBinding, the admission policy) left to helm lint and the API server.
# Provider crd of SecretStore is taken out of its schema: one of its fields is named additionalProperties, which
# openapi2jsonschema turns into a boolean, and kubeconform, which compiles schemas as draft 4, then finds no schema at
# all for SecretStore. No store here uses that provider, so -strict refuses it instead.
helm-check: ## helm lint and helm template every chart of the repository with the values of the GitOps path, alone and with the overlays of each environment of deploy/k8s/envs (prd without svp.localhost), the app-of-apps chart for each environment on amd64 and arm64 nodes, each with the plugin of Argo Rollouts built for it; the ExternalSecrets and SecretStores of each environment against the CRD schemas of the pinned External Secrets chart (kubeconform)
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	export HELM_CACHE_HOME="$$tmp/cache" HELM_CONFIG_HOME="$$tmp/config" HELM_DATA_HOME="$$tmp/data"; \
	envs=; for d in deploy/k8s/envs/*/; do [ -d "$$d" ] && envs="$$envs $$(basename "$$d")"; done; \
	[ -n "$$envs" ] || { echo "helm-check: deploy/k8s/envs holds no environment" >&2; exit 1; }; \
	jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' \
		deploy/argocd/apps/components.json > "$$tmp/charts" || exit 1; \
	tab=$$(printf '\t'); \
	while IFS="$$tab" read -r name ns path values; do \
	  set --; \
	  if [ -n "$$values" ]; then set -- -f "$$values"; fi; \
	  if [ "$$path" = deploy/helm/svp-service ] && ! grep -Eq '^  digest: "?sha256:[0-9a-f]{64}"?$$' "$$values"; then \
	    set -- "$$@" --set image.digest=$(ZERO_DIGEST); fi; \
	  echo "helm lint and template: $$name ($$path $$*)"; \
	  helm lint --quiet --namespace "$$ns" "$$path" "$$@" || exit 1; \
	  helm template "$$name" "$$path" --namespace "$$ns" "$$@" > "$$tmp/base-$$name.yaml" || exit 1; \
	  for env in $$envs; do \
	    overlay=deploy/k8s/envs/$$env/$$name.yaml; \
	    if [ -f "$$overlay" ]; then \
	      echo "helm lint and template: $$name in $$env (-f $$overlay)"; \
	      helm lint --quiet --namespace "$$ns" "$$path" "$$@" -f "$$overlay" || exit 1; \
	      helm template "$$name" "$$path" --namespace "$$ns" "$$@" -f "$$overlay" > "$$tmp/$$env-$$name.yaml" || exit 1; \
	    else cp "$$tmp/base-$$name.yaml" "$$tmp/$$env-$$name.yaml" || exit 1; fi; \
	  done; \
	done < "$$tmp/charts"; \
	mkdir -p "$$tmp/plugins/templates" || exit 1; \
	printf 'apiVersion: v2\nname: plugins\nversion: 0.1.0\n' > "$$tmp/plugins/Chart.yaml" || exit 1; \
	printf '%s\n' '{{- range .Values.controller.trafficRouterPlugins }}' \
		'# plugin {{ .name }} {{ .location }} {{ .sha256 }}' '{{- end }}' > "$$tmp/plugins/templates/plugins.yaml" || exit 1; \
	for env in $$envs; do \
	  for arch in arm64 amd64; do \
	    echo "helm lint and template: svp-root (deploy/argocd/apps --set env=$$env --set nodeArch=$$arch)"; \
	    helm lint --quiet --namespace argocd deploy/argocd/apps --set-string env=$$env --set nodeArch=$$arch || exit 1; \
	    helm template svp-root deploy/argocd/apps --namespace argocd --set-string env=$$env --set nodeArch=$$arch \
		> "$$tmp/root-$$env-$$arch.yaml" || exit 1; \
	    set --; \
	    for f in $$(awk '/^---/ { app = 0 } /^  name: argo-rollouts$$/ { app = 1 } \
		app && /^ *- \$$values\// { sub(/^ *- \$$values\//, ""); print }' "$$tmp/root-$$env-$$arch.yaml"); do \
	      set -- "$$@" -f "$$f"; done; \
	    [ $$# -gt 0 ] || { echo "helm-check: Application argo-rollouts names no values file on $$arch nodes in $$env" >&2; \
		exit 1; }; \
	    helm template plugins "$$tmp/plugins" "$$@" | sed -n 's/^# plugin //p' > "$$tmp/plugin-$$arch" || exit 1; \
	    echo "  argo-rollouts on $$arch nodes ($$*): $$(cat "$$tmp/plugin-$$arch")"; \
	    [ "$$(grep -c . "$$tmp/plugin-$$arch")" = 1 ] && \
		grep -Eq "^[^ ]+ https://[^ ]+/[^ /]+-linux-$$arch [0-9a-f]{64}$$" "$$tmp/plugin-$$arch" || \
		{ echo "helm-check: Argo Rollouts on $$arch nodes must get exactly one plugin, the asset built for linux-$$arch" >&2; \
		exit 1; }; \
	  done; \
	  read -r arm_name arm_loc arm_sum < "$$tmp/plugin-arm64"; read -r amd_name amd_loc amd_sum < "$$tmp/plugin-amd64"; \
	  [ "$$arm_name" = "$$amd_name" ] && [ "$${arm_loc%/*}" = "$${amd_loc%/*}" ] && [ "$$arm_sum" != "$$amd_sum" ] || \
		{ echo "helm-check: Argo Rollouts gets $$arm_name of $${arm_loc%/*} on arm64 nodes, $$amd_name of $${amd_loc%/*} on amd64 nodes in $$env: pin the two assets of one release" >&2; \
		exit 1; }; \
	  echo "  argo-rollouts in $$env: plugin $$arm_name of $${arm_loc%/*} on both, the asset built for each architecture"; \
	  if [ "$$env" = prd ]; then \
	    if grep -n 'svp\.localhost' "$$tmp"/prd-*.yaml "$$tmp"/root-prd-*.yaml > "$$tmp/leftover"; then \
	      sed "s|^$$tmp/||" "$$tmp/leftover" >&2; \
	      echo "helm-check: the prd render above still names svp.localhost: override it in deploy/k8s/envs/prd" >&2; \
	      exit 1; fi; \
	    echo "  prd: no svp.localhost in the render of any chart of the repository"; \
	  fi; \
	done; \
	if grep -Eq '^kind: (ExternalSecret|SecretStore)$$' "$$tmp/base-svp-cluster.yaml"; then \
	  echo "helm-check: the base render of svp-cluster (the dev path's) has an ExternalSecret or a SecretStore" >&2; exit 1; fi; \
	want_es=$$(grep -c '^- namespace: ' deploy/helm/svp-cluster/files/external-secrets.yaml); \
	want_ss=$$(sed -n 's/^- namespace: //p' deploy/helm/svp-cluster/files/external-secrets.yaml | sort -u | grep -c .); \
	eso=$$(jq -r '.components[] | select(.name == "external-secrets") | "\(.repo) \(.chart) \(.version) \(.values)"' \
		deploy/argocd/apps/components.json) && [ -n "$$eso" ] || \
		{ echo "helm-check: no component external-secrets in deploy/argocd/apps/components.json" >&2; exit 1; }; \
	set -- $$eso; mkdir -p "$$tmp/eso/crds" "$$tmp/eso/schemas" "$$tmp/eso/manifests" || exit 1; \
	helm template external-secrets "$$2" --repo "$$1" --version "$$3" --namespace external-secrets -f "$$4" \
		--show-only templates/crds/externalsecret.yaml --show-only templates/crds/secretstore.yaml \
		> "$$tmp/eso/crds/crds.yaml" || exit 1; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none \
		-v "$$tmp/eso/crds:/crds:ro" -v "$$tmp/eso/schemas:/schemas" --workdir /schemas \
		-e 'FILENAME_FORMAT={kind}-{fullgroup}-{version}' -e DENY_ROOT_ADDITIONAL_PROPERTIES=1 \
		--entrypoint /openapi2jsonschema $(KUBECONFORM_IMAGE) /crds/crds.yaml > "$$tmp/eso/o2j.log" 2>&1 || \
		{ cat "$$tmp/eso/o2j.log" >&2; echo "helm-check: schemas from the CRDs of external-secrets $$3" >&2; exit 1; }; \
	ss_schema="$$tmp/eso/schemas/secretstore-external-secrets.io-v1.json"; \
	jq -e '.properties.spec.properties.provider.properties.crd' "$$ss_schema" > /dev/null || \
		{ echo "helm-check: no provider crd in $${ss_schema##*/}: drop the line that removes it" >&2; exit 1; }; \
	jq 'del(.properties.spec.properties.provider.properties.crd)' "$$ss_schema" > "$$tmp/eso/ss.json" && \
		mv "$$tmp/eso/ss.json" "$$ss_schema" || exit 1; \
	for env in $$envs; do \
	  f="$$tmp/$$env-svp-cluster.yaml"; \
	  es=$$(grep -c '^kind: ExternalSecret$$' "$$f"); ss=$$(grep -c '^kind: SecretStore$$' "$$f"); \
	  [ "$$es" = "$$want_es" ] && [ "$$ss" = "$$want_ss" ] || \
		{ echo "helm-check: svp-cluster in $$env renders $$es ExternalSecrets and $$ss SecretStores, want $$want_es and $$want_ss" >&2; exit 1; }; \
	  provider=$$(awk '/^kind: SecretStore$$/ { s = 1 } s && /^    [a-z]+:$$/ { sub(/:$$/, ""); print $$1; s = 0 }' "$$f" | sort -u | paste -sd ' ' -); \
	  if [ "$$env" = prd ]; then \
	    [ "$$provider" = aws ] || { echo "helm-check: the SecretStores of prd use provider '$$provider', want aws" >&2; exit 1; }; \
	    if grep -n 'svp-secrets' "$$f" >&2; then \
	      echo "helm-check: the prd render of svp-cluster above still names svp-secrets, the lab's source namespace" >&2; exit 1; fi; \
	  else \
	    [ "$$provider" = kubernetes ] || { echo "helm-check: the SecretStores of $$env use provider '$$provider', want kubernetes" >&2; exit 1; }; \
	  fi; \
	  helm template svp-cluster deploy/helm/svp-cluster --namespace cert-manager -f deploy/k8s/envs/$$env/svp-cluster.yaml \
		--show-only templates/external-secrets.yaml > "$$tmp/eso/manifests/$$env.yaml" || exit 1; \
	  env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" --network none \
		-v "$$tmp/eso/manifests:/manifests:ro" -v "$$tmp/eso/schemas:/schemas:ro" $(KUBECONFORM_IMAGE) \
		-strict -summary -skip ServiceAccount,Role,RoleBinding,ValidatingAdmissionPolicy,ValidatingAdmissionPolicyBinding \
		-schema-location '/schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json' \
		"/manifests/$$env.yaml" > "$$tmp/eso/kubeconform.log" 2>&1 || \
		{ cat "$$tmp/eso/kubeconform.log" >&2; echo "helm-check: kubeconform on the ExternalSecrets and SecretStores of $$env" >&2; exit 1; }; \
	  grep -q "Valid: $$((es + ss)), Invalid: 0, Errors: 0" "$$tmp/eso/kubeconform.log" || \
		{ cat "$$tmp/eso/kubeconform.log" >&2; echo "helm-check: kubeconform did not find $$((es + ss)) valid ExternalSecrets and SecretStores in $$env" >&2; exit 1; }; \
	  echo "  svp-cluster in $$env: $$es ExternalSecrets, $$ss SecretStores (provider $$provider), valid against the CRDs of external-secrets $$3 (kubeconform -strict)"; \
	  [ "$$env" != prd ] || echo "  prd: no svp-secrets in the render of svp-cluster"; \
	done; \
	echo "  base: no ExternalSecret or SecretStore in the render of svp-cluster (the dev path's)"

# Misconfiguration scan of the Dockerfiles, charts and manifests with the pinned trivy. It only
# reports: exit 0 whatever it finds. The findings that are deliberate choices are left out by
# deploy/ci/trivy-config-ignore.yaml, each for its paths and until its expired_at, with the reason in the file.
# TRIVY_CONFIG_SARIF set to an absolute path writes a SARIF
# report there (CI uploads it); unset, a table goes to the terminal. The repository is mounted read-only and the container runs as the caller,
# so the report belongs to them; the policy bundle trivy downloads goes to a cache inside the container.
TRIVY_CONFIG_SARIF ?=
trivy-config: ## trivy config on the repository, report only (TRIVY_CONFIG_SARIF=<absolute path> writes SARIF)
	@if [ -n "$(TRIVY_CONFIG_SARIF)" ]; then \
	  set -- -v "$$(dirname "$(TRIVY_CONFIG_SARIF)"):/out" $(TRIVY_IMAGE) config --format sarif \
		--output "/out/$$(basename "$(TRIVY_CONFIG_SARIF)")"; \
	else set -- $(TRIVY_IMAGE) config --format table; fi; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -v "$(CURDIR):/src:ro" --workdir /src \
		"$$@" --quiet --cache-dir /tmp/trivy --ignorefile deploy/ci/trivy-config-ignore.yaml --exit-code 0 .

# Vulnerability gate of the web client's npm dependencies, read from the lockfile: the web image shows trivy only the
# few packages left in its node_modules, since the bundler folds the server's dependencies into its chunks.
# Development dependencies count too: they run in CI and
# build the bundle that ships. deploy/ci/scan-gate.sh decides as for an image: any CRITICAL left after
# .trivyignore.yaml fails, fixed upstream or not; HIGH and below are only counted. Only the lockfile is mounted
# (read-only), at web/pnpm-lock.yaml under the scan root so the findings point at the file of the repository. A report
# with no npm package fails too: a lockfile format trivy no longer reads would otherwise pass with nothing scanned.
# trivy needs the network for its DB, and a DB it cannot download fails the target: no scan against a DB of unknown
# age. WEB_LOCKFILE (absolute path of a file named pnpm-lock.yaml) scans another lockfile, for a negative check.
# WEB_LOCKFILE_SARIF set to an absolute path writes a SARIF report of the HIGH and CRITICAL findings there, before the
# gate decides, so a blocked lockfile still shows on main (CI uploads it). SVP_TRIVY_CACHE, when set, keeps the DB in
# that directory (CI restores it with actions/cache, as images.yml does); unset, the DB goes to a cache inside the
# container.
WEB_LOCKFILE ?= $(CURDIR)/web/pnpm-lock.yaml
WEB_LOCKFILE_SARIF ?=
web-lockfile-scan: ## trivy fs on web/pnpm-lock.yaml, dev dependencies included; fails on any CRITICAL (WEB_LOCKFILE_SARIF=<absolute path> writes SARIF)
	@lockfile='$(WEB_LOCKFILE)'; \
	[ "$$(basename "$$lockfile")" = pnpm-lock.yaml ] && [ -f "$$lockfile" ] || { echo "WEB_LOCKFILE=$$lockfile is not \
	a file named pnpm-lock.yaml" >&2; exit 1; }; \
	lockfile="$$(cd "$$(dirname "$$lockfile")" && pwd)/pnpm-lock.yaml" || exit 1; label=$${lockfile#$(CURDIR)/}; \
	tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	set -- -v "$$lockfile:/scan/web/pnpm-lock.yaml:ro" -v "$$tmp:/out"; \
	if [ -n "$(SVP_TRIVY_CACHE)" ]; then mkdir -p "$(SVP_TRIVY_CACHE)" || exit 1; \
	  set -- "$$@" -v "$(SVP_TRIVY_CACHE):/cache"; cache=/cache; else cache=/tmp/trivy; fi; \
	if [ -f .trivyignore.yaml ]; then set -- "$$@" -v "$(CURDIR)/.trivyignore.yaml:/ignore.yaml:ro"; fi; \
	trivy() { env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp "$$@"; }; \
	trivy "$$@" $(TRIVY_IMAGE) fs --scanners vuln --include-dev-deps --list-all-pkgs --format json \
		--output /out/trivy.json --quiet --cache-dir "$$cache" \
		$$([ -f .trivyignore.yaml ] && echo --ignorefile /ignore.yaml) /scan || exit 1; \
	packages=$$(jq '[.Results[]? | select(.Type == "pnpm") | .Packages[]?] | length' "$$tmp/trivy.json") || exit 1; \
	echo "$$label: $$packages npm packages scanned"; \
	[ "$$packages" -gt 0 ] || { echo "FAIL  $$label: trivy read no npm package from it" >&2; exit 1; }; \
	if [ -n "$(WEB_LOCKFILE_SARIF)" ]; then \
	  trivy "$$@" -v "$$(dirname "$(WEB_LOCKFILE_SARIF)"):/sarif" $(TRIVY_IMAGE) convert --format sarif \
		--severity HIGH,CRITICAL --output "/sarif/$$(basename "$(WEB_LOCKFILE_SARIF)")" /out/trivy.json || exit 1; fi; \
	deploy/ci/scan-gate.sh --fs "$$label" "$$tmp/trivy.json"

# The grype gate of the image pipeline, from a machine: grype on an SPDX SBOM, then deploy/ci/scan-gate.sh --grype (any
# Critical left after .trivyignore.yaml fails; an expired entry there fails too). SBOM=<absolute path> scans that
# document; IMAGE=<ref>@sha256:<digest> [ARCH=amd64|arm64] first has the pinned syft read the image of that platform
# from its registry, anonymously. grype needs the network for its DB, and a DB it cannot fetch fails the target.
# SVP_GRYPE_CACHE, when set, keeps the DB in that directory (it is about 3 GB unpacked); unset, in $TMPDIR.
SBOM ?=
IMAGE ?=
ARCH ?= amd64
grype: ## grype + gate on an SBOM (SBOM=<absolute path of SPDX JSON>) or an image (IMAGE=<ref@sha256:...> [ARCH=amd64|arm64])
	@bash -c '. deploy/ci/common.sh && grype_check "$$1" "$$2" "$$3"' grype '$(SBOM)' '$(IMAGE)' '$(ARCH)'

# Checks renovate.json as the GitHub App reads it, a repository config (--no-global), and fails on any error or on an
# option that needs migrating (--strict): with the pinned Renovate image, no network, the repository mounted read-only
# (renovate.json must stay readable by the image's uid 12021). The App runs the Renovate version Mend deploys, which can
# lag this one by up to a week.
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
RENOVATE_IMAGE := ghcr.io/renovatebot/renovate:44.165.1@sha256:455f4169a364a4c8bdc38a08694e3509649f3d7cb9aaea35c86946b38015ac47
renovate-check: ## Validate renovate.json with the pinned Renovate (renovate-config-validator --strict, no network)
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(RENOVATE_IMAGE) renovate-config-validator --strict --no-global renovate.json

hooks: ## Point git at .githooks (run once per clone)
	git config core.hooksPath .githooks

# Web client in web/. Node's major is pinned in web/.nvmrc and pnpm's exact
# version in the packageManager field of web/package.json; every web target checks both before it runs anything and,
# on a mismatch, prints the command that installs the right one. nvm leaves PATH to the shell and its default may be
# another major, so the newest nvm install of the pinned major goes first on PATH; without one (CI's setup-node) PATH
# is used as it is. Next's anonymous telemetry is off for every web target.
WEB_NODE_MAJOR := $(shell cat web/.nvmrc 2>/dev/null)
NVM_DIR ?= $(HOME)/.nvm
WEB_NODE_BIN := $(shell ls -d $(NVM_DIR)/versions/node/v$(WEB_NODE_MAJOR).*/bin 2>/dev/null | sort -V | tail -1)
WEB := cd web && export $(if $(WEB_NODE_BIN),PATH="$(WEB_NODE_BIN):$$PATH") NEXT_TELEMETRY_DISABLED=1 && \
	node_major=$$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null); \
	if [ "$$node_major" != "$(WEB_NODE_MAJOR)" ]; then echo "web/ needs Node $(WEB_NODE_MAJOR) (web/.nvmrc), found \
	$$(node --version 2>/dev/null || echo none): nvm install $(WEB_NODE_MAJOR)" >&2; exit 1; fi; \
	pnpm_want=$$(node -p 'require("./package.json").packageManager.split("@")[1]') || exit 1; \
	if [ "$$(pnpm --version 2>/dev/null)" != "$$pnpm_want" ]; then echo "web/ needs pnpm $$pnpm_want (packageManager of \
	web/package.json), found $$(pnpm --version 2>/dev/null || echo none): npm install -g pnpm@$$pnpm_want" >&2; exit 1; fi;

web-install: ## Install the web client's packages exactly as web/pnpm-lock.yaml pins them
	@$(WEB) pnpm install --frozen-lockfile

# next dev on loopback only, against the gateway of `make up` and the web's session database (Redis db 9). The
# browser origin is http://localhost:3002, not 127.0.0.1: POST requests from any other origin are refused as CSRF.
web-dev: ## Run the web client in dev mode at http://localhost:3002 against the gateway at 127.0.0.1:8080
	@$(WEB) GATEWAY_URL=http://127.0.0.1:8080 REDIS_URL=redis://127.0.0.1:6379/9 APP_ORIGIN=http://localhost:3002 \
		MEDIA_ORIGIN=http://127.0.0.1:9000 UPLOAD_ORIGIN=http://127.0.0.1:9000 \
		pnpm dev --port 3002 --hostname 127.0.0.1

web-generate: ## Generate web/gen/api.d.ts from services/gateway/openapi.yaml (openapi-typescript)
	@$(WEB) pnpm generate

# Generates into a scratch directory and compares with web/gen/api.d.ts; the working tree is never written. The input
# is the one of the generate script in web/package.json.
web-generate-check: ## Fail when make web-generate would change web/gen/api.d.ts: print the diff (writes nothing here)
	@$(WEB) tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	pnpm --silent exec openapi-typescript ../services/gateway/openapi.yaml --output "$$tmp/api.d.ts" >/dev/null || exit 1; \
	if diff -q gen/api.d.ts "$$tmp/api.d.ts" >/dev/null; then echo "web/gen/api.d.ts is up to date"; exit 0; fi; \
	echo "make web-generate changes web/gen/api.d.ts (run make web-generate and commit the result):"; \
	diff -u gen/api.d.ts "$$tmp/api.d.ts"; exit 1

# Bundle budgets on the output of next build, gzip, checked by size-limit with web/.size-limit.json. Each route has
# two budgets. The first covers what the route adds to Next's
# runtime: the chunks the build's client reference manifest lists for the route's layouts, page and error boundaries
# (the scripts of its HTML), plus the chunks those load lazily (hls.js on the feed and /v/[id]). The second covers the
# whole first load, that set plus the runtime (rootMainFiles of build-manifest.json: React, react-dom, Next's router,
# the same on every route), so a runtime that grows fails the check too. The nomodule polyfill, which current browsers
# skip, is left out of both. Turbopack names chunks by a content hash, so each set is copied to .next/size-limit/<set>/
# first, where the config's globs find it. The copy drops each chunk's last line, the sourceMappingURL comment, as the
# image's build does (deploy/docker/web.Dockerfile): the budgets count the bytes the image serves, debug id included.
define WEB_SIZE_CHUNKS
const fs = require("node:fs");
const runtime = JSON.parse(fs.readFileSync(".next/build-manifest.json", "utf8")).rootMainFiles;
function routeChunks(page) {
  globalThis.__RSC_MANIFEST = {};
  require(process.cwd() + "/.next/server/app/" + page + "_client-reference-manifest.js");
  const chunks = new Set(Object.values(globalThis.__RSC_MANIFEST["/" + page].entryJSFiles).flat());
  for (const chunk of chunks) {
    const refs = fs.readFileSync(".next/" + chunk, "utf8").match(/static\/chunks\/[\w-]+\.js/g) ?? [];
    for (const ref of refs) if (!runtime.includes(ref)) chunks.add(ref);
  }
  return [...chunks].filter((chunk) => !runtime.includes(chunk));
}
const sets = {
  runtime,
  feed: routeChunks("(main)/page"),
  login: routeChunks("(auth)/login/page"),
  upload: routeChunks("(main)/upload/page"),
  video: routeChunks("v/[id]/page"),
};
fs.rmSync(".next/size-limit", { recursive: true, force: true });
for (const [name, chunks] of Object.entries(sets)) {
  fs.mkdirSync(".next/size-limit/" + name, { recursive: true });
  for (const chunk of chunks) {
    const served = fs.readFileSync(".next/" + chunk, "utf8").replace(/^\/\/# sourceMappingURL=.*\n?/gm, "");
    fs.writeFileSync(".next/size-limit/" + name + "/" + chunk.split("/").pop(), served);
  }
}
endef
export WEB_SIZE_CHUNKS

# The standalone server of next build, the one the image runs, started once and asked for /healthz: a module its
# instrumentation hook loads but the build left out (a require the bundler and the trace cannot follow) passes the
# unit tests and next build, yet makes every route of the image answer 500. On 127.0.0.1 only, at a free port the
# check picks itself; the server gets a fixed environment, not this shell's, whose hosts end in .invalid: /healthz
# reads neither Redis nor the gateway, so nothing is reached. Stopped by its own handle once it answers.
define WEB_STANDALONE_BOOT
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const net = require("node:net");
(async () => {
  const probe = net.createServer().listen(0, "127.0.0.1");
  await once(probe, "listening");
  const port = String(probe.address().port);
  probe.close();
  const server = spawn(process.execPath, ["server.js"], {
    cwd: ".next/standalone",
    env: {
      NODE_ENV: "production",
      NEXT_TELEMETRY_DISABLED: "1",
      HOSTNAME: "127.0.0.1",
      PORT: port,
      GATEWAY_URL: "http://gateway.invalid",
      REDIS_URL: "redis://redis.invalid:6379/9",
      APP_ORIGIN: "http://localhost:" + port,
      MEDIA_ORIGIN: "https://media.invalid",
      UPLOAD_ORIGIN: "https://upload.invalid",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const output = [];
  server.stdout.on("data", (chunk) => output.push(chunk));
  server.stderr.on("data", (chunk) => output.push(chunk));
  let exit = null;
  const exited = once(server, "exit").then(([code, signal]) => (exit = signal ?? code));
  let status = "no answer within 30 s";
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (exit !== null) {
      status = "none, the server exited (" + exit + ")";
      break;
    }
    try {
      status = (await fetch("http://127.0.0.1:" + port + "/healthz", { signal: AbortSignal.timeout(5000) })).status;
      break;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
  }
  server.kill();
  await exited;
  if (status === 200) {
    console.log("standalone server: GET /healthz 200");
    return;
  }
  process.stderr.write(Buffer.concat(output));
  console.error("standalone server: GET /healthz " + status);
  process.exitCode = 1;
})();
endef
export WEB_STANDALONE_BOOT

web-check: ## Lint, format check, typecheck, unit tests (Redis db 15 as for test), production build, a start of its standalone server and bundle budgets of the web client
	@$(WEB) pnpm lint && pnpm format:check && pnpm typecheck && \
		SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' pnpm test && pnpm build && \
		node -e "$$WEB_STANDALONE_BOOT" && node -e "$$WEB_SIZE_CHUNKS" && pnpm size

# Both need the compose stack (make up) and the Playwright browsers (pnpm exec playwright install chromium webkit in
# web/). LOCAL LAB ONLY: the seed (web/e2e/seed.sh) and every Playwright worker (web/e2e/fixtures.ts) delete the
# gateway's register rate limit keys in Redis db 10, as make smoke does.
web-e2e: ## Playwright end-to-end tests of the web client on Chromium and WebKit against the stack of make up (pnpm e2e)
	@$(WEB) pnpm e2e

measure-web: ## Run web-e2e and print time to first frame after a swipe (p50/p95 per browser) and the memory of container web at rest and after; JSON in web/test-results/
	@$(WEB) bash e2e/measure-web.sh

# Needs the stack (make up), ffmpeg and jq; LOCAL LAB ONLY like web-e2e (the seed runs first).
measure-upload: ## Upload a ~100 MB video from Chromium through /upload; print time, throughput, page CPU and time to READY; JSON in web/test-results/
	@$(WEB) bash e2e/measure-upload.sh

# Needs the stack (make up) and Playwright's Chromium (pnpm exec playwright install chromium in web/); one run per page,
# so the numbers carry noise. Not in CI until the stack runs there. LOCAL LAB ONLY like web-e2e: web/lighthouse/run.sh
# registers a fresh user and deletes the gateway's register rate limit keys in Redis db 10 first.
web-lighthouse: ## Lighthouse (mobile, one run per page) of the feed logged in and /v/{id} logged out: LCP/CLS/TBT thresholds, reports in web/test-results/lighthouse/
	@$(WEB) bash lighthouse/run.sh

# Needs the stack with GlitchTip (make up OBS=lgtm, which writes SENTRY_SOURCEMAPS_TOKEN to .env); builds the stage
# sourcemaps of the web image from the working tree, which the build cache answers with the maps of the image make up
# built (deploy/observability/glitchtip/sourcemaps.sh).
web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build the stack of make up OBS=lgtm runs, to its GlitchTip (http://127.0.0.1:8000); checks first that the web serves that build
	@$(WEB) bash ../deploy/observability/glitchtip/sourcemaps.sh compose

# Docker and compose targets live in their own file (stage 1, compose card).
-include deploy/compose/compose.mk
# Local Kubernetes targets (k3d cluster svp, stage 4).
-include deploy/k8s/k8s.mk
# Load test targets (k6, stage 6).
-include deploy/k6/k6.mk
# DAST target (Schemathesis, stage 6b).
-include deploy/dast/dast.mk
