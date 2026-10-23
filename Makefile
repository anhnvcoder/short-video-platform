# Build, generate, lint and test entry point for the monorepo. `make help` lists the targets.

# Pinned tool versions, installed by `make tools` rather than as `tool` directives in go.mod: sqlc and golangci-lint
# would pull hundreds of modules into the application's dependency graph, and `go install` builds each of them with
# this machine's Go (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 3).
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
# SLO rule generator (docs/adr/0011-observability-stage3.md, section 8). `go install` leaves the
# version empty and Sloth would then write "dev" in the header of the file it generates.
# renovate: datasource=go depName=github.com/slok/sloth
SLOTH_VERSION              := v0.16.0
# Local Kubernetes (docs/adr/0014-kubernetes-local-stage4.md, section 1). Without both -X flags k3d reports v5-dev and
# pulls its proxy and tools images as :latest, and its default node image is an older k3s; the node image itself is
# pinned by digest in deploy/k8s/k3d.yaml.
# renovate: datasource=go depName=github.com/k3d-io/k3d/v5
K3D_VERSION                := v5.9.0
# renovate: datasource=docker depName=rancher/k3s
K3S_IMAGE_TAG              := v1.36.5-k3s1
# One line on purpose: a backslash-newline inside the single quotes of a recipe reaches the shell as a literal backslash
# on GNU Make 4.x (Make 3.81 joined the lines), and the linker then gets a broken -ldflags.
K3D_LDFLAGS                := -X github.com/k3d-io/k3d/v5/version.Version=$(K3D_VERSION) -X github.com/k3d-io/k3d/v5/version.K3sVersion=$(K3S_IMAGE_TAG)
# Linter of the GitHub Actions workflows, run by `make actionlint` inside `make check`
# (docs/adr/0015-cicd-devsecops-stage5.md, section 1). It also runs shellcheck on every `run:` script when shellcheck is
# on PATH: the CI runner has it, a dev machine need not.
# renovate: datasource=go depName=github.com/rhysd/actionlint
ACTIONLINT_VERSION         := v1.7.12

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
# digest cannot be moved like a tag (ADR-0015, section 1).
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=ghcr.io/anchore/syft
SYFT_IMAGE  := ghcr.io/anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa
# cosign on a dev machine, to verify releases only (deploy/ci/verify-release.sh, and `make k8s-gitops-up` before it
# creates anything): signing happens in CI alone, with the cosign that sigstore/cosign-installer installs there.
# renovate: datasource=docker depName=ghcr.io/sigstore/cosign/cosign
COSIGN_IMAGE := ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8

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
# and never need FLUSHDB (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1).
SVP_TEST_REDIS_URL ?= redis://127.0.0.1:6379/15

.DEFAULT_GOAL := help

.PHONY: help tools ci-tools generate generate-go generate-check slo otelcol-validate fmt-check vet lint actionlint buf-lint test \
	cover check check-go helm-check trivy-config renovate-check hooks web-install web-dev web-generate web-generate-check \
	web-check web-e2e measure-web measure-upload web-lighthouse web-sourcemaps

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned code generators, linters, secret scanner, SLO generator and k3d into GOBIN
	GOBIN=$(GOBIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(GOBIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	GOBIN=$(GOBIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(GOBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	GOBIN=$(GOBIN) go install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION)
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

# Generated Go code must match its sources (docs/adr/0015-cicd-devsecops-stage5.md, section 2). `make generate-go` runs
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

test: ## go test -race (SVP_TEST_POSTGRES_URL and SVP_TEST_REDIS_URL default to the local Postgres and Redis db 15; TESTFLAGS adds flags, e.g. TESTFLAGS=-count=1)
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race $(TESTFLAGS) $(PKGS)

cover: ## go test -race with coverage into cover.out (same test variables and TESTFLAGS as test), print the total
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race -coverprofile=cover.out $(TESTFLAGS) $(PKGS)
	@go tool cover -func=cover.out | tail -1
	@echo "per line in a browser: go tool cover -html=cover.out"

check: check-go web-check ## Run every check: Go (check-go) and the web client (web-check)

check-go: fmt-check vet lint actionlint buf-lint test ## Run the Go, workflow and proto checks

# Every chart of the repository, as the GitOps path renders it (ADR-0015, section 2): each component of components.json
# with a `path`, under its release name and namespace, with its values file, and the app-of-apps chart itself. A release
# of svp-service whose values carry no image.digest yet (none before the first promotion) gets an all-zero digest, so it
# goes down the digest branch of the GitOps path instead of failing on the dev tag the dev path passes. Helm's cache,
# config and data live in a scratch directory, never in .k8s/helm.
ZERO_DIGEST := sha256:0000000000000000000000000000000000000000000000000000000000000000
helm-check: ## helm lint and helm template every chart of the repository with the values of the GitOps path
	@tmp=$$(mktemp -d) || exit 1; trap 'rm -rf "$$tmp"' EXIT; \
	export HELM_CACHE_HOME="$$tmp/cache" HELM_CONFIG_HOME="$$tmp/config" HELM_DATA_HOME="$$tmp/data"; \
	{ jq -r '.components[] | select(.path) | [.name, .namespace, .path, (.values // "")] | @tsv' \
		deploy/argocd/apps/components.json && printf 'svp-root\targocd\tdeploy/argocd/apps\t\n'; } > "$$tmp/charts" \
		|| exit 1; \
	tab=$$(printf '\t'); \
	while IFS="$$tab" read -r name ns path values; do \
	  set --; \
	  if [ -n "$$values" ]; then set -- -f "$$values"; fi; \
	  if [ "$$path" = deploy/helm/svp-service ] && ! grep -Eq '^  digest: "?sha256:[0-9a-f]{64}"?$$' "$$values"; then \
	    set -- "$$@" --set image.digest=$(ZERO_DIGEST); fi; \
	  echo "helm lint and template: $$name ($$path $$*)"; \
	  helm lint --quiet --namespace "$$ns" "$$path" "$$@" || exit 1; \
	  helm template "$$name" "$$path" --namespace "$$ns" "$$@" > /dev/null || exit 1; \
	done < "$$tmp/charts"

# Misconfiguration scan of the Dockerfiles, charts and manifests with the pinned trivy (ADR-0015, section 2). It only
# reports: exit 0 whatever it finds. TRIVY_CONFIG_SARIF set to an absolute path writes a SARIF report there (CI uploads
# it); unset, a table goes to the terminal. The repository is mounted read-only and the container runs as the caller,
# so the report belongs to them; the policy bundle trivy downloads goes to a cache inside the container.
TRIVY_CONFIG_SARIF ?=
trivy-config: ## trivy config on the repository, report only (TRIVY_CONFIG_SARIF=<absolute path> writes SARIF)
	@if [ -n "$(TRIVY_CONFIG_SARIF)" ]; then \
	  set -- -v "$$(dirname "$(TRIVY_CONFIG_SARIF)"):/out" $(TRIVY_IMAGE) config --format sarif \
		--output "/out/$$(basename "$(TRIVY_CONFIG_SARIF)")"; \
	else set -- $(TRIVY_IMAGE) config --format table; fi; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -v "$(CURDIR):/src:ro" --workdir /src \
		"$$@" --quiet --cache-dir /tmp/trivy --exit-code 0 .

# Checks renovate.json as the GitHub App reads it, a repository config (--no-global), and fails on any error or on an
# option that needs migrating (--strict): with the pinned Renovate image, no network, the repository mounted read-only
# (renovate.json must stay readable by the image's uid 12021). The App runs the Renovate version Mend deploys, which can
# lag this one by up to a week (docs/adr/0015-cicd-devsecops-stage5.md, section 10).
# renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
RENOVATE_IMAGE := ghcr.io/renovatebot/renovate:44.165.1@sha256:455f4169a364a4c8bdc38a08694e3509649f3d7cb9aaea35c86946b38015ac47
renovate-check: ## Validate renovate.json with the pinned Renovate (renovate-config-validator --strict, no network)
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(RENOVATE_IMAGE) renovate-config-validator --strict --no-global renovate.json

hooks: ## Point git at .githooks (run once per clone)
	git config core.hooksPath .githooks

# Web client in web/ (docs/adr/0016-web-client.md, section 10). Node's major is pinned in web/.nvmrc and pnpm's exact
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

# Bundle budgets (docs/adr/0016-web-client.md, section 10; for /upload and /v/[id]
# docs/adr/0018-web-profiles-public-video-upload.md, section 11) on the output of next build, gzip, checked by
# size-limit with web/.size-limit.json. Each route has two budgets. The first covers what the route adds to Next's
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

web-check: ## Lint, format check, typecheck, unit tests (Redis db 15 as for test), production build and bundle budgets of the web client
	@$(WEB) pnpm lint && pnpm format:check && pnpm typecheck && \
		SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' pnpm test && pnpm build && \
		node -e "$$WEB_SIZE_CHUNKS" && pnpm size

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
# so the numbers carry noise. Not in CI until the stack runs there (docs/adr/0018-web-profiles-public-video-upload.md,
# section 10). LOCAL LAB ONLY like web-e2e: web/lighthouse/run.sh registers a fresh user and deletes the gateway's
# register rate limit keys in Redis db 10 first.
web-lighthouse: ## Lighthouse (mobile, one run per page) of the feed logged in and /v/{id} logged out: LCP/CLS/TBT thresholds, reports in web/test-results/lighthouse/
	@$(WEB) bash lighthouse/run.sh

# Needs the stack with GlitchTip (make up OBS=lgtm, which writes SENTRY_SOURCEMAPS_TOKEN to .env); builds the stage
# sourcemaps of the web image from the working tree, which the build cache answers with the maps of the image make up
# built (deploy/observability/glitchtip/sourcemaps.sh; docs/adr/0019-web-k3d-supply-chain-observability.md, section 9).
web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build the stack of make up OBS=lgtm runs, to its GlitchTip (http://127.0.0.1:8000); checks first that the web serves that build
	@$(WEB) bash ../deploy/observability/glitchtip/sourcemaps.sh compose

# Docker and compose targets live in their own file (stage 1, compose card).
-include deploy/compose/compose.mk
# Local Kubernetes targets (k3d cluster svp, stage 4).
-include deploy/k8s/k8s.mk
