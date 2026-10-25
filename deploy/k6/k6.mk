# Load test targets (k6), included by the root Makefile. k6 runs only as
# K6_IMAGE (pinned in the Makefile), never a k6 installed on the machine; every docker call drops DOCKER_DEFAULT_PLATFORM
# (CLAUDE.md).

.PHONY: k6-check load-local load-ci

K6_PROFILES := local ci cloud

# k6 inspect runs the init context of the scripts with each profile and works out what its scenarios need, with no
# network: K6_AUTO_EXTENSION_RESOLUTION=false keeps k6 from looking up an extension, and the scripts import nothing from
# the internet. Prints nothing when every profile passes; the output of the failing one otherwise.
k6-check: ## k6 inspect --execution-requirements of deploy/k6/main.js with each profile (local, ci, cloud), in K6_IMAGE with no network (prints nothing on success)
	@for p in $(K6_PROFILES); do \
	  out=$$(env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -e K6_AUTO_EXTENSION_RESOLUTION=false \
	    -e K6_NO_USAGE_REPORT=true -v $(CURDIR)/deploy/k6:/scripts:ro $(K6_IMAGE) \
	    inspect --execution-requirements -e SVP_K6_PROFILE=$$p /scripts/main.js 2>&1) || \
	    { printf '%s\n' "$$out" >&2; echo "FAIL  k6 inspect deploy/k6/main.js with SVP_K6_PROFILE=$$p" >&2; exit 1; }; \
	done

# Both need the stack of `make up` (OBS=lgtm to read the server side in Prometheus) and refuse to run without it or
# beside the k3d cluster. LOCAL LAB ONLY: they delete the gateway's register rate limit keys in Redis db 10 first, as
# make smoke does (deploy/k6/load.sh). The stack must hold a READY video (make smoke publishes one).
load-local: ## On the stack of make up: k6 profile local (about 24 req/s held 5 min, thresholds of the SLOs with latency); summary in .k6/local-<time>/ (LOCAL LAB ONLY: resets the register rate limit)
	K6_IMAGE='$(K6_IMAGE)' deploy/k6/load.sh local

load-ci: ## On the stack of make up: k6 profile ci (a few req/s for 60 s, error thresholds only; the CI job stack); summary in .k6/ci-<time>/ (LOCAL LAB ONLY: resets the register rate limit)
	K6_IMAGE='$(K6_IMAGE)' deploy/k6/load.sh ci
