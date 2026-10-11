# Build, generate, lint and test entry point for the monorepo. `make help` lists the targets.

# Pinned tool versions (docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md, section 3).
PROTOC_GEN_GO_VERSION      := v1.36.12
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2
SQLC_VERSION               := v1.31.1
GOLANGCI_LINT_VERSION      := v2.14.0
GITLEAKS_VERSION           := v8.30.1

# Tools installed by `go install` land here; the PATH of the caller is not assumed to contain it.
GOBIN ?= $(shell go env GOPATH)/bin
export PATH := $(GOBIN):$(PATH)

# Packages for vet, lint and test; narrow them with e.g. `make test PKGS=./services/user-service/...`.
PKGS ?= ./...

# Local dev Postgres superuser DSN, published in CLAUDE.md; integration tests create their own databases from it.
SVP_TEST_POSTGRES_URL ?= postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable
# Local Redis, db 15: the project's test database (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md, section 1).
SVP_TEST_REDIS_URL ?= redis://127.0.0.1:6379/15

.DEFAULT_GOAL := help

.PHONY: help tools generate fmt-check vet lint buf-lint test check hooks

help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned code generators, linter and secret scanner into GOBIN
	GOBIN=$(GOBIN) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(GOBIN) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
	GOBIN=$(GOBIN) go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)
	GOBIN=$(GOBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	GOBIN=$(GOBIN) go install github.com/zricethezav/gitleaks/v8@$(GITLEAKS_VERSION)

generate: ## Generate Go code from proto/ (buf) and from SQL (sqlc, per service)
	buf generate
	@for f in $(wildcard services/*/sqlc.yaml); do echo "sqlc generate -f $$f"; sqlc generate -f $$f || exit 1; done

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

check: fmt-check vet lint buf-lint test ## Run every check

hooks: ## Point git at .githooks (run once per clone)
	git config core.hooksPath .githooks

# Docker and compose targets live in their own file (stage 1, compose card).
-include deploy/compose/compose.mk
