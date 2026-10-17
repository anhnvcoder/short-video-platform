# Build, generate, lint and test entry point for the monorepo. `make help` lists the targets.

# Pinned tool versions, installed by `make tools` rather than as `tool` directives in go.mod: sqlc and golangci-lint
# would pull hundreds of modules into the application's dependency graph, and `go install` builds each of them with
# this machine's Go (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 3).
PROTOC_GEN_GO_VERSION      := v1.36.12
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2
SQLC_VERSION               := v1.31.1
GOLANGCI_LINT_VERSION      := v2.14.0
GITLEAKS_VERSION           := v8.30.1
# SLO rule generator (docs/adr/0011-observability-stage3.md, section 8). `go install` leaves the
# version empty and Sloth would then write "dev" in the header of the file it generates.
SLOTH_VERSION              := v0.16.0

# Tools installed by `go install` land here; the PATH of the caller is not assumed to contain it.
GOBIN ?= $(shell go env GOPATH)/bin
export PATH := $(GOBIN):$(PATH)

# Packages for vet, lint and test; narrow them with e.g. `make test PKGS=./services/user-service/...`.
PKGS ?= ./...

# Local dev Postgres superuser DSN, published in CLAUDE.md; integration tests create their own databases from it.
SVP_TEST_POSTGRES_URL ?= postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
# Local Redis, db 15: the project's test database, used by no service or other project, so tests never touch their data
# and never need FLUSHDB (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1).
SVP_TEST_REDIS_URL ?= redis://127.0.0.1:6379/15

.DEFAULT_GOAL := help

.PHONY: help tools generate slo otelcol-validate fmt-check vet lint buf-lint test cover check hooks

help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned code generators, linter, secret scanner and SLO generator into GOBIN
	GOBIN=$(GOBIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(GOBIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	GOBIN=$(GOBIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(GOBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	GOBIN=$(GOBIN) go install github.com/zricethezav/gitleaks/v8@$(GITLEAKS_VERSION)
	GOBIN=$(GOBIN) go install -ldflags='-X github.com/slok/sloth/internal/info.Version=$(SLOTH_VERSION)' \
		github.com/slok/sloth/cmd/sloth@$(SLOTH_VERSION)

generate: ## Generate Go code from proto/ (buf) and from SQL (sqlc, per service)
	buf generate
	@for f in $(wildcard services/*/sqlc.yaml); do echo "sqlc generate -f $$f"; sqlc generate -f $$f || exit 1; done

slo: ## Generate the SLO recording and burn-rate alert rules from deploy/observability/slo/svp-slos.yaml (Sloth)
	sloth generate --no-color -i deploy/observability/slo/svp-slos.yaml -o deploy/observability/prometheus/rules/slo-generated.yaml

# The Collector image of `otelcol` and `otelcol-elastic` in deploy/compose/compose.yaml (keep the
# three in step), run with no network and the config files at the paths compose mounts them.
OTELCOL_IMAGE := otel/opentelemetry-collector-contrib:0.162.0@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6
OTELCOL := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none \
	-v $(CURDIR)/deploy/observability/otelcol/config.yaml:/etc/otelcol/config.yaml:ro \
	-v $(CURDIR)/deploy/observability/elastic/otelcol-config.yaml:/etc/otelcol/elastic.yaml:ro \
	$(OTELCOL_IMAGE)

otelcol-validate: ## Validate the Collector configs with the pinned Collector: obs, and obs-elastic (the obs file with the Elastic file merged over it)
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml
	$(OTELCOL) validate --config=/etc/otelcol/config.yaml --config=/etc/otelcol/elastic.yaml

fmt-check: ## Fail and list the files that gofmt would change (generated code excluded)
	@out=$$(find . -name '*.go' -not -path './gen/*' -not -path './.roster/*' -print0 \
		| xargs -0 grep -L --null '^// Code generated .* DO NOT EDIT\.$$' | xargs -0 gofmt -l) \
		|| { echo "gofmt failed (syntax error?)" >&2; exit 1; }; \
	if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet: ## go vet
	go vet $(PKGS)

lint: ## golangci-lint run
	golangci-lint run $(PKGS)

buf-lint: ## buf lint and buf build
	buf lint
	buf build -o /dev/null

test: ## go test -race (SVP_TEST_POSTGRES_URL and SVP_TEST_REDIS_URL default to the local Postgres and Redis db 15)
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race $(PKGS)

cover: ## go test -race with coverage into cover.out (same test variables as test), print the total
	SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)' go test -race -coverprofile=cover.out $(PKGS)
	@go tool cover -func=cover.out | tail -1
	@echo "per line in a browser: go tool cover -html=cover.out"

check: fmt-check vet lint buf-lint test ## Run every check

hooks: ## Point git at .githooks (run once per clone)
	git config core.hooksPath .githooks

# Docker and compose targets live in their own file (stage 1, compose card).
-include deploy/compose/compose.mk
