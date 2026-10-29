# DAST target (Schemathesis against the gateway's OpenAPI contract), included by the root Makefile. Schemathesis runs
# only as SCHEMATHESIS_IMAGE (pinned in the Makefile), never one installed on the machine; deploy/dast/run.sh drops
# DOCKER_DEFAULT_PLATFORM on every docker call (CLAUDE.md).

.PHONY: dast

# Needs the stack of `make up` (core is enough) and refuses to run without it or beside the k3d cluster. LOCAL LAB ONLY:
# it deletes the gateway's register rate limit keys in Redis db 10 before and after the run, as make smoke does. It uses
# up the gateway's per-IP and per-user rate limits for a minute or so: run it after the other checks.
dast: ## On the stack of make up: Schemathesis against services/gateway/openapi.yaml through the gateway; reports in .dast/<time>/ (LOCAL LAB ONLY: resets the register rate limit)
	SCHEMATHESIS_IMAGE='$(SCHEMATHESIS_IMAGE)' deploy/dast/run.sh
