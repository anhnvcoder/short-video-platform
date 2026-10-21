# Docker and compose targets, included by the root Makefile. Every docker call drops
# DOCKER_DEFAULT_PLATFORM, which the global shell sets to linux/amd64 for another project:
# containers here run native arm64 (CLAUDE.md).

COMPOSE_ARGS := --env-file .env -f deploy/compose/compose.yaml
COMPOSE   := env -u DOCKER_DEFAULT_PLATFORM docker compose $(COMPOSE_ARGS) --profile core
# Every profile, so down, ps and logs never miss a container of the observability stacks.
COMPOSE_ALL := $(COMPOSE) --profile obs --profile obs-elastic
# `make up OBS=...` (docs/adr/0011-observability-stage3.md, sections 9 and 10). Unset: core only,
# telemetry SDKs on with no backend to reach. lgtm: core and the obs profile. elastic: core and
# the obs-elastic profile, the comparison of docs/adr/0012-elastic-vs-grafana-stage3.md. off: core
# with telemetry off in every service, the baseline for measuring its overhead; the compose file
# reads these three variables, which are set nowhere else.
OBS ?=
OBS_VALUES := lgtm elastic off
TELEMETRY_OFF := SVP_OTEL_SDK_DISABLED=true SVP_PYROSCOPE_SERVER_ADDRESS= SENTRY_DSN=
COMPOSE_UP_ := $(COMPOSE)
# The Telegram bot token reaches Alertmanager as a compose secret, and compose refuses to create a
# secret from a variable that is not set at all. A .env made before stage 3 lacks the line, so an
# absent variable is passed as empty; a value in .env is never overridden (ADR-0011, section 8).
TELEGRAM_TOKEN_ABSENT = $(shell grep -q '^SVP_ALERT_TELEGRAM_BOT_TOKEN=' .env 2>/dev/null || echo SVP_ALERT_TELEGRAM_BOT_TOKEN=)
COMPOSE_UP_lgtm = env -u DOCKER_DEFAULT_PLATFORM $(TELEGRAM_TOKEN_ABSENT) docker compose $(COMPOSE_ARGS) --profile core --profile obs
COMPOSE_UP_elastic := env -u DOCKER_DEFAULT_PLATFORM docker compose $(COMPOSE_ARGS) --profile core --profile obs-elastic
COMPOSE_UP_off := env -u DOCKER_DEFAULT_PLATFORM $(TELEMETRY_OFF) docker compose $(COMPOSE_ARGS) --profile core
# The two observability stacks never run together (16 GB machine, ADR-0011, section 9), and a
# stack measured as core only or with telemetry off has neither (the overhead states of section
# 10): the long-running services of the profiles `make up OBS=<value>` does not choose, which it
# refuses to start beside.
OBS_OTHER_lgtm := elasticsearch kibana apm-server otelcol-elastic
OBS_OTHER_elastic := otelcol lgtm alertmanager glitchtip
OBS_OTHER_ := $(OBS_OTHER_elastic) $(OBS_OTHER_lgtm)
OBS_OTHER_off := $(OBS_OTHER_)
SMOKE_URL ?= http://127.0.0.1:8080
# Roles whose passwords `make env` generates (deploy/postgres/bootstrap.sql).
DB_PASSWORD_VARS := SVP_USER_MIGRATOR_DB_PASSWORD SVP_USER_APP_DB_PASSWORD SVP_VIDEO_MIGRATOR_DB_PASSWORD SVP_VIDEO_APP_DB_PASSWORD \
	SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD SVP_ENGAGEMENT_APP_DB_PASSWORD SVP_FEED_MIGRATOR_DB_PASSWORD SVP_FEED_APP_DB_PASSWORD \
	SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD SVP_GLITCHTIP_APP_DB_PASSWORD
# MinIO root password and per-service secret keys (deploy/minio/init.sh). MinIO caps secret keys at
# 40 characters, hence 20 random bytes in hex.
S3_SECRET_VARS := SVP_MINIO_ROOT_PASSWORD SVP_VIDEO_S3_SECRET_KEY SVP_MEDIA_WORKER_S3_SECRET_KEY
# GlitchTip's Django secret key and its admin password: random per clone like the S3 secrets above, so no fixed
# credential is committed (ADR-0011, section 7).
GLITCHTIP_SECRET_VARS := GLITCHTIP_SECRET_KEY GLITCHTIP_ADMIN_PASSWORD
# Login of GlitchTip's admin user: a fixed local address, not anyone's real mailbox.
GLITCHTIP_ADMIN_EMAIL := admin@svp.local
# Written together by tools/jwtkey: one key pair, so they are generated all or none.
JWT_VARS := JWT_SIGNING_KID JWT_SIGNING_KEY JWT_VERIFY_KEYS
# Used by the k3d cluster only (deploy/k8s/secrets.sh, docs/adr/0014-kubernetes-local-stage4.md section 8): the
# superuser of the in-cluster Postgres, Redpanda's superuser svp-admin, the Kafka user of KEDA and of each service with
# Kafka (compose runs Redpanda without SASL), and Grafana's admin login.
K8S_SECRET_VARS := SVP_PG_SUPERUSER_PASSWORD SVP_KAFKA_ADMIN_PASSWORD SVP_KAFKA_KEDA_PASSWORD \
	SVP_KAFKA_USER_SERVICE_PASSWORD SVP_KAFKA_VIDEO_SERVICE_PASSWORD SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD \
	SVP_KAFKA_FEED_SERVICE_PASSWORD SVP_KAFKA_MEDIA_WORKER_PASSWORD SVP_GRAFANA_ADMIN_PASSWORD

.PHONY: env env-required obs-valid obs-exclusive k3d-exclusive db-bootstrap glitchtip-init up down clean-data ps logs compose-config compose-hash slo-check smoke test-stack drill-kill-worker drill-duplicates measure-ready \
	drill-duplicates-feed drill-engagement-down measure-freshness drill-rate-limit measure-explore-cache drill-upload-cleanup \
	drill-alert-to-sentry drill-obs-threats

# .env is read with the strict rule of deploy/observability/glitchtip/dotenv.sh, the same as
# glitchtip-init: a line it refuses stops make env, naming the variable, before anything is written.
env: ## Create .env (mode 600) with random secrets and a new JWT key, or fill in the ones it lacks or has empty; never changes a set value
	@set -e; umask 077; \
	tmp=$$(mktemp .env.tmp.XXXXXX); trap 'rm -f "$$tmp"' EXIT; \
	if [ ! -e .env ]; then \
	  { echo "# Generated by make env. Local secrets: do not commit, do not share."; \
	    for v in $(DB_PASSWORD_VARS); do pw=$$(openssl rand -hex 24); echo "$$v=$$pw"; done; \
	    for v in $(S3_SECRET_VARS); do pw=$$(openssl rand -hex 20); echo "$$v=$$pw"; done; \
	    for v in $(GLITCHTIP_SECRET_VARS); do pw=$$(openssl rand -hex 32); echo "$$v=$$pw"; done; \
	    for v in $(K8S_SECRET_VARS); do pw=$$(openssl rand -hex 24); echo "$$v=$$pw"; done; \
	    echo "GLITCHTIP_ADMIN_EMAIL=$(GLITCHTIP_ADMIN_EMAIL)"; \
	    go run ./tools/jwtkey; } > "$$tmp"; \
	  chmod 600 "$$tmp"; mv -n "$$tmp" .env; \
	  echo "wrote .env (mode 600)"; exit 0; \
	fi; \
	. deploy/observability/glitchtip/dotenv.sh; \
	has() { cur=$$(dotenv_value .env "$$1") || exit 1; [ -n "$$cur" ]; }; \
	added=; \
	for v in $(DB_PASSWORD_VARS); do has $$v || { pw=$$(openssl rand -hex 24); echo "$$v=$$pw" >> "$$tmp"; added="$$added $$v"; }; done; \
	for v in $(S3_SECRET_VARS); do has $$v || { pw=$$(openssl rand -hex 20); echo "$$v=$$pw" >> "$$tmp"; added="$$added $$v"; }; done; \
	for v in $(GLITCHTIP_SECRET_VARS); do has $$v || { pw=$$(openssl rand -hex 32); echo "$$v=$$pw" >> "$$tmp"; added="$$added $$v"; }; done; \
	for v in $(K8S_SECRET_VARS); do has $$v || { pw=$$(openssl rand -hex 24); echo "$$v=$$pw" >> "$$tmp"; added="$$added $$v"; }; done; \
	has GLITCHTIP_ADMIN_EMAIL || { echo "GLITCHTIP_ADMIN_EMAIL=$(GLITCHTIP_ADMIN_EMAIL)" >> "$$tmp"; added="$$added GLITCHTIP_ADMIN_EMAIL"; }; \
	jwt_missing=; for v in $(JWT_VARS); do has $$v || jwt_missing="$$jwt_missing $$v"; done; \
	if [ "$$jwt_missing" = " $(JWT_VARS)" ]; then go run ./tools/jwtkey >> "$$tmp"; added="$$added$$jwt_missing"; \
	elif [ -n "$$jwt_missing" ]; then echo "make env: .env lacks or has empty$$jwt_missing but has the other JWT variables; remove all three to get a new key pair" >&2; exit 1; fi; \
	if [ -z "$$added" ]; then echo ".env already has every variable; left unchanged"; exit 0; fi; \
	new=$$(mktemp .env.new.XXXXXX); trap 'rm -f "$$tmp" "$$new"' EXIT; \
	dotenv_fill .env "$$tmp" > "$$new"; \
	chmod 600 "$$new"; mv "$$new" .env; \
	echo "added to .env (mode 600):$$added"

env-required:
	@test -f .env || { echo ".env not found; run 'make env' first" >&2; exit 1; }

db-bootstrap: env-required ## Create or update the Postgres roles and databases (idempotent)
	deploy/postgres/bootstrap.sh .env

obs-valid:
	@case '$(OBS)' in '' $(foreach v,$(OBS_VALUES),| $(v))) ;; \
	  *) echo "OBS='$(OBS)' is not valid: leave it unset or use one of: $(OBS_VALUES)" >&2; exit 1 ;; esac

obs-exclusive: env-required
	@running=$$($(COMPOSE_ALL) ps -q $(OBS_OTHER_$(OBS))); \
	  if [ -n "$$running" ]; then echo "make up$(if $(OBS), OBS=$(OBS)): a container of an observability profile it does not start is running (one of: $(OBS_OTHER_$(OBS))); run 'make down' first" >&2; exit 1; fi

# Compose and the k3d cluster svp never run together on the 16 GB machine (CLAUDE.md,
# docs/adr/0014-kubernetes-local-stage4.md section 2): no node of the cluster (label k3d.cluster=svp) and not its
# registry may be running. `make k8s-up` refuses the other way round (deploy/k8s/k8s.mk).
k3d-exclusive:
	@running=$$(env -u DOCKER_DEFAULT_PLATFORM docker ps -q --filter label=k3d.cluster=svp; \
	  env -u DOCKER_DEFAULT_PLATFORM docker ps -q --filter name=^k3d-svp-registry$$); \
	  if [ -n "$$running" ]; then echo "make up: the k3d cluster svp or its registry is running; run 'make k8s-down' first" >&2; exit 1; fi

# The DSN and API token exist only once GlitchTip is initialized, and compose reads .env when it
# creates a container: `make up OBS=lgtm` writes them to .env first, so even the first run starts
# the Go services with SENTRY_DSN set (deploy/observability/glitchtip/init.sh).
GLITCHTIP_INIT = COMPOSE='$(COMPOSE_UP_lgtm)' deploy/observability/glitchtip/init.sh .env

glitchtip-init: env-required db-bootstrap ## Migrate and bootstrap GlitchTip (admin, org/project svp, drill token), add SENTRY_* to .env; idempotent, never changes a set value
	$(GLITCHTIP_INIT)

up: k3d-exclusive env-required obs-valid obs-exclusive db-bootstrap ## Bootstrap Postgres, build, migrate and start the core stack; OBS=lgtm adds Grafana LGTM (127.0.0.1:3000) and GlitchTip (127.0.0.1:8000), OBS=elastic adds Elasticsearch, Kibana (127.0.0.1:5601) and APM Server instead, OBS=off turns telemetry off (drills keep it off); refuses while a container of a profile not chosen runs (make down first)
	$(if $(filter lgtm,$(OBS)),$(GLITCHTIP_INIT))
	$(COMPOSE_UP_$(OBS)) up -d --build --wait

down: ## Stop and remove the containers of every profile and the network (no volume is touched)
	$(COMPOSE_ALL) down

clean-data: ## Stop every profile and delete the stack's volumes (Redpanda topics, MinIO buckets, media-worker scratch, LGTM data, Alertmanager silences, Elasticsearch indices)
	@echo "Removing the svp stack and these volumes with all their data (Postgres on the host is not touched):"
	@env -u DOCKER_DEFAULT_PLATFORM docker volume ls -q --filter label=com.docker.compose.project=svp | sed 's/^/  /'
	$(COMPOSE_ALL) down -v

ps: ## Show the containers of every profile
	$(COMPOSE_ALL) ps -a

logs: ## Show recent logs of every profile; narrow with SVC=<service>
	$(COMPOSE_ALL) logs --tail=200 $(SVC)

# Validation only: `config` without --quiet would print the file with the passwords, S3 secrets
# and JWT signing key from .env filled in.
compose-config: env-required ## Check the compose file is valid for core, core + obs, core + obs-elastic and OBS=off (prints nothing on success)
	$(COMPOSE_UP_) config --quiet
	$(COMPOSE_UP_lgtm) config --quiet
	$(COMPOSE_UP_elastic) config --quiet
	$(COMPOSE_UP_off) config --quiet

# One line per service with the config hash compose computes from .env (`config --hash`): a sha256
# of the service's whole resolved config, never a value. OBS= picks the profiles as for make up.
# deploy/observability/glitchtip/dotenv-test.sh runs it on fixtures to check compose reads quoted
# values as dotenv.sh does.
compose-hash: env-required obs-valid
	@$(COMPOSE_UP_$(OBS)) config --hash '*'

# promtool of the pinned LGTM image (the same image as `lgtm` in compose.yaml), with no network:
# the Prometheus config and its rule files at the paths compose mounts them, then the rule tests.
# renovate: datasource=docker depName=grafana/otel-lgtm
LGTM_IMAGE := grafana/otel-lgtm:0.36.0@sha256:57c04cbd8e7022f32bb84c4ac005d79baf8b08e2c5be44facf11f5f1f9944ba2
PROMTOOL := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none \
	-v $(CURDIR)/deploy/observability/prometheus/prometheus.yaml:/otel-lgtm/prometheus.yaml:ro \
	-v $(CURDIR)/deploy/observability/prometheus/rules:/otel-lgtm/svp-rules:ro \
	--workdir /otel-lgtm/svp-rules --entrypoint /otel-lgtm/prometheus/promtool $(LGTM_IMAGE)

slo-check: ## promtool: check the Prometheus config and alert rules, run the rule tests (svp-alerts.test.yaml)
	$(PROMTOOL) check config /otel-lgtm/prometheus.yaml
	$(PROMTOOL) test rules svp-alerts.test.yaml

smoke: ## Through the gateway at SMOKE_URL: register, log in, follow, upload to READY, play HLS, feed, like and view, unfollow
	deploy/compose/smoke.sh $(SMOKE_URL)

# Failure drills on the running stack (deploy/compose/drills/). They stop, kill and start
# containers through $(COMPOSE), run rpk inside the Redpanda container and only SELECT from
# svp_video, svp_engagement and svp_feed; every service runs again when a drill ends, passed or not.
# measure-freshness also produces fake follow events to Redpanda (tools/fakefollows) and removes
# them with unfollow events when it ends. drill-rate-limit and drill-upload-cleanup recreate the
# gateway or video-service with drill-only settings and put the defaults back when they end.
# Every script (smoke too) deletes the per-IP register rate limit keys in Redis db 10 first: lab
# only, since every run registers from the one Docker bridge address (ADR-0010, section 7).
# N defaults to 5, but to 100 for measure-explore-cache.
N ?= 5
FOLLOWERS ?= 10000
# A drill recreates services (the drill-only settings, and the restore when it ends), so it runs
# compose with the telemetry state the stack was started with: on a stack from `make up OBS=off`
# (its Go services run with OTEL_SDK_DISABLED=true) telemetry stays off, instead of coming back on
# halfway through an overhead measurement (ADR-0011, section 10). The inspect template prints
# `off` or nothing, never another setting of the containers.
TELEMETRY_OFF_RUNNING = $(shell ids=`$(COMPOSE) ps -q`; test -z "$$ids" || env -u DOCKER_DEFAULT_PLATFORM docker inspect \
	--format '{{range .Config.Env}}{{if eq . "OTEL_SDK_DISABLED=true"}}off{{end}}{{end}}' $$ids | grep -m 1 -x off)
DRILL_COMPOSE = $(if $(TELEMETRY_OFF_RUNNING),$(COMPOSE_UP_off),$(COMPOSE))

drill-kill-worker: env-required ## Kill media-worker mid-transcode, restart it; check the video still goes READY, once
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/kill-worker.sh $(SMOKE_URL)

drill-duplicates: env-required ## Replay transcode.completed and video.uploaded with rpk group seek; check nothing changes
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/duplicate-events.sh $(SMOKE_URL)

drill-duplicates-feed: env-required ## Replay view.recorded, user.followed and video.ready; check counters and feed rows do not change
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/duplicate-feed-events.sh $(SMOKE_URL)

drill-engagement-down: env-required ## Stop engagement-service; check the breaker opens (likes 503 in < 100 ms), the feed answers without stats, the breaker closes on restart
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/engagement-down.sh $(SMOKE_URL)

drill-rate-limit: env-required ## Rate limits: 429 RATE_LIMITED with Retry-After, UP-7 TOO_MANY_UPLOADS; with Redis unreachable the fallback still limits logins
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/rate-limit.sh $(SMOKE_URL)

measure-explore-cache: env-required ## N (default 100, max 150) concurrent explore requests on an empty cache read Postgres once, a second wave never
	COMPOSE='$(DRILL_COMPOSE)' N='$(if $(filter file,$(origin N)),100,$(N))' deploy/compose/drills/measure-explore-cache.sh $(SMOKE_URL)

drill-upload-cleanup: env-required ## Abandon an upload with a 20 s limit; check it goes FAILED and its object is deleted, a completed one is untouched
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/upload-cleanup.sh $(SMOKE_URL)

# The two observability drills need the stack of `make up OBS=lgtm`. They read Prometheus, Tempo and
# Loki through Grafana's datasource proxy, Alertmanager's API and GlitchTip's API, with the
# read-only token SENTRY_AUTH_TOKEN read from .env and never printed (docs/adr/0011-observability-stage3.md,
# sections 7 to 9).
drill-alert-to-sentry: env-required ## OBS=lgtm: stop feed-service; time the page alert, then find its trace (Tempo), log line (Loki) and GlitchTip event; T4 - T1 under 5 min
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/alert-to-sentry.sh $(SMOKE_URL)

drill-obs-threats: env-required ## OBS=lgtm: JWT-8 (no email, password, token in traces, logs, GlitchTip), UP-8 (log ids), OPS-1 (no pprof, /metrics, loopback ports only), RL-2 (fallback metric and alert)
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/obs-threats.sh $(SMOKE_URL)

measure-ready: env-required ## Time CompleteUpload to READY for N (default 5) 60 s 1080p videos; p50, max, worker CPU/RAM
	COMPOSE='$(DRILL_COMPOSE)' N='$(N)' deploy/compose/drills/measure-ready.sh $(SMOKE_URL)

measure-freshness: env-required ## Time video.ready to the last timeline row for N (at most 10) videos to FOLLOWERS (default 10000) fake followers
	COMPOSE='$(DRILL_COMPOSE)' N='$(N)' FOLLOWERS='$(FOLLOWERS)' deploy/compose/drills/measure-freshness.sh $(SMOKE_URL)

# test-stack reads the S3 secret keys from .env with the strict rule of
# deploy/observability/glitchtip/dotenv.sh, as deploy/postgres/bootstrap.sh and compose do: no
# sourcing, no echo, and they reach go test through the environment, not its command line.
test-stack: env-required ## go test -race against the running stack (make up): MinIO and Redpanda test variables set
	@set -e; \
	. deploy/observability/glitchtip/dotenv.sh; \
	value() { v=$$(dotenv_value .env "$$1") || return 1; \
	  if [ -z "$$v" ]; then echo "test-stack: $$1 is missing or empty in .env; run make env" >&2; return 1; fi; \
	  printf '%s' "$$v"; }; \
	SVP_TEST_S3_VIDEO_SECRET_KEY=$$(value SVP_VIDEO_S3_SECRET_KEY); \
	SVP_TEST_S3_WORKER_SECRET_KEY=$$(value SVP_MEDIA_WORKER_S3_SECRET_KEY); \
	export SVP_TEST_S3_VIDEO_SECRET_KEY SVP_TEST_S3_WORKER_SECRET_KEY; \
	export SVP_TEST_POSTGRES_URL='$(SVP_TEST_POSTGRES_URL)' SVP_TEST_REDIS_URL='$(SVP_TEST_REDIS_URL)'; \
	export SVP_TEST_S3_ENDPOINT=http://127.0.0.1:9000; \
	export SVP_TEST_S3_VIDEO_ACCESS_KEY=svp-video-service SVP_TEST_S3_WORKER_ACCESS_KEY=svp-media-worker; \
	export SVP_TEST_KAFKA_BROKERS=127.0.0.1:19092; \
	echo "go test -race $(PKGS) (SVP_TEST_* set for MinIO http://127.0.0.1:9000 and Redpanda 127.0.0.1:19092)"; \
	go test -race $(PKGS)
