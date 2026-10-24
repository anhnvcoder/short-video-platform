# Local Kubernetes targets (k3d cluster svp, docs/adr/0014-kubernetes-local-stage4.md), included by the root Makefile.
# docker and k3d run without DOCKER_DEFAULT_PLATFORM and kubectl/helm always name --context k3d-svp; the shell helpers
# behind these targets are in deploy/k8s/lib.sh.

K8S_LIB := . deploy/k8s/lib.sh

.PHONY: k8s-exclusive k8s-up k8s-down k8s-status k8s-ca k8s-secrets k8s-images k8s-smoke drill-k8s-keda drill-k8s-pdb \
	k8s-glitchtip-init k8s-ui-grafana k8s-ui-prometheus k8s-ui-alertmanager k8s-ui-glitchtip k8s-gitops-up \
	measure-gitops k8s-ui-argocd k8s-traffic-start k8s-traffic-stop drill-k8s-canary measure-canary drill-k8s-threats \
	drill-k8s-supplychain k8s-web-sourcemaps k8s-web-e2e drill-k8s-web-obs cloud-check drill-k8s-backup

# Compose and k3d never run together on the 16 GB machine (CLAUDE.md): the cluster is not created or started beside a
# running compose stack. `make up` refuses the other way round (deploy/compose/compose.mk).
k8s-exclusive:
	@running=$$(env -u DOCKER_DEFAULT_PLATFORM docker compose -p svp ps -q); \
	  if [ -n "$$running" ]; then echo "make k8s-up: the compose stack svp is running; run 'make down' first" >&2; exit 1; fi

# env-required: the Secrets come from .env (deploy/k8s/secrets.sh, run by install.sh once the namespaces exist).
k8s-up: k8s-exclusive env-required ## Create (or start) the registry 127.0.0.1:5111 and cluster svp (API 127.0.0.1:6550, HTTPS 127.0.0.1:8443), build and push the seven images, install deploy/argocd/apps/components.json, with drill traffic while a canary of the gateway or the web client runs; idempotent (LOCAL LAB ONLY: a canary's drill traffic resets register rate limit keys in the cluster's Valkey db 10)
	@bash -c '$(K8S_LIB) && ensure_registry && ensure_cluster'
	deploy/k8s/install.sh

# The GitOps path (docs/adr/0014-kubernetes-local-stage4.md, section 12; its images:
# docs/adr/0015-cicd-devsecops-stage5.md, section 9). GITOPS_REV is what Argo CD follows: a branch of origin (its
# values are read from origin/<branch> as last fetched) or a full commit SHA. Releases are built, signed and promoted
# by CI (.github/workflows/images.yml): no target builds one on this machine.
GITOPS_REV ?= main

k8s-gitops-up: k8s-exclusive env-required ## Create a new cluster svp that Argo CD builds from GitHub: ARGOCD_DEPLOY_KEY=<private key file of a read-only deploy key> (GitHub repo Settings > Deploy keys, "Allow write access" unticked) [GITOPS_REV=main]; first checks that the seven release digests at that revision are on GHCR (anonymous pull), signed, with a clean vuln attestation at most 48 h old; applies the Secrets of .env, installs Argo CD, waits until every Application is Synced and Healthy
	@test -n '$(ARGOCD_DEPLOY_KEY)' || { echo "make k8s-gitops-up: set ARGOCD_DEPLOY_KEY=<private key file of a read-only deploy key>" >&2; exit 1; }
	ARGOCD_DEPLOY_KEY='$(ARGOCD_DEPLOY_KEY)' GITOPS_REV='$(GITOPS_REV)' deploy/k8s/gitops.sh

measure-gitops: ## On the GitOps cluster, time release commit REV=<commit> (the merge of a promote pull request) from its push (reflog of origin/main, else GitHub's PushEvent) through Argo CD's sync to the first and last pod Ready with the new digest; JSON in .k8s/drills/ (read only)
	@test -n '$(REV)' || { echo "make measure-gitops: set REV=<commit>" >&2; exit 1; }
	deploy/k8s/drills/gitops.sh '$(REV)'

k8s-down: ## Delete cluster svp and its registry (compose volumes and the host's Postgres are not touched)
	@if env -u DOCKER_DEFAULT_PLATFORM k3d cluster get svp >/dev/null 2>&1; then \
	  env -u DOCKER_DEFAULT_PLATFORM k3d cluster delete svp; else echo "cluster svp not found"; fi
	@if env -u DOCKER_DEFAULT_PLATFORM docker inspect k3d-svp-registry >/dev/null 2>&1; then \
	  env -u DOCKER_DEFAULT_PLATFORM k3d registry delete svp-registry; else echo "registry k3d-svp-registry not found"; fi

k8s-status: ## Show the containers, nodes and the pods of every namespace but kube-system of cluster svp
	@env -u DOCKER_DEFAULT_PLATFORM docker ps -a --filter name=k3d-svp --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@if env -u DOCKER_DEFAULT_PLATFORM k3d cluster get svp >/dev/null 2>&1; then \
	  kubectl --context k3d-svp get nodes -o wide && \
	  kubectl --context k3d-svp get pods --all-namespaces --field-selector metadata.namespace!=kube-system; \
	else echo "cluster svp not found; run make k8s-up"; fi

k8s-secrets: env-required ## Create or update the cluster's Secrets from .env (no value printed; a changed Redpanda admin password needs redpanda-0 running), restart MinIO or Redpanda if their password changed; then run make k8s-up: the init Jobs set the new passwords and each service whose Secret changed restarts with them (on the GitOps cluster: the steps at the top of deploy/k8s/gitops.sh)
	deploy/k8s/secrets.sh

# Needs no .env: both values are GlitchTip's own, read inside its pod (deploy/k8s/glitchtip-init.sh).
k8s-glitchtip-init: ## Put GlitchTip's DSN into Secret svp/sentry and its read-only API token into Secret svp-obs/glitchtip-api (never into .env, nothing printed), then restart each service whose pods started without the current DSN; idempotent, run by make k8s-up
	deploy/k8s/glitchtip-init.sh

k8s-ca: ## Write the CA of the cluster's TLS certificates to .k8s/ca.crt (curl --cacert .k8s/ca.crt https://<name>.svp.localhost:8443/)
	@bash -c '$(K8S_LIB) && export_ca'

# The dev tags depend only on the images' content (deploy/k8s/lib.sh, build_dev_images), so this target and the build
# inside `make k8s-up` give the same tags for the same working tree.
k8s-images: ## Build the seven service images from the working tree and push them to the registry 127.0.0.1:5111 as svp/<service>:dev-<image ID>
	@bash -c '$(K8S_LIB) && ensure_registry && build_dev_images'

# deploy/compose/smoke.sh through Envoy: curl trusts the cluster's CA for api.svp.localhost and s3.svp.localhost (both
# resolve to loopback), and the register rate limit is reset in the cluster's Valkey (SVP_STACK=k3d).
k8s-smoke: ## Run the end-to-end smoke test against cluster svp at https://api.svp.localhost:8443 (CA .k8s/ca.crt; LOCAL LAB ONLY: deletes the register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make k8s-smoke: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	SVP_STACK=k3d CURL_CA_BUNDLE=$(CURDIR)/.k8s/ca.crt deploy/compose/smoke.sh https://api.svp.localhost:8443

# Drills on cluster svp (deploy/k8s/drills/), through Envoy like k8s-smoke. N defaults to 9 for drill-k8s-keda (the
# compose drills' default of 5 applies to their own targets only).
K8S_DRILL_ENV := SVP_STACK=k3d CURL_CA_BUNDLE=$(CURDIR)/.k8s/ca.crt

drill-k8s-keda: ## Upload and complete N (default 9, 6-12; more until the records cover all 3 partitions) 60 s 1080p videos at once; time media-worker's KEDA scale-out to its 2 replicas and back to 1, peak lag, each READY, worker CPU/RAM; scale down a pod mid-transcode; every video transcoded once; the k3s server must not restart (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-keda: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) N='$(if $(filter file,$(origin N)),9,$(N))' deploy/k8s/drills/keda.sh https://api.svp.localhost:8443

# The canaries of the gateway and the web client (docs/adr/0014-kubernetes-local-stage4.md, section 13;
# docs/adr/0019-web-k3d-supply-chain-observability.md, section 3). The drill traffic runs in the background until
# stopped, for hours if need be (through the push of a release on the GitOps cluster); `make k8s-up` starts and stops
# its own while a canary of either is in progress.
k8s-traffic-start: ## Start drill traffic in the background: 4 users, ~10 requests/s to GET /feed/explore and /feed/following through https://api.svp.localhost:8443, and ~4 requests/s to the web client at https://svp.localhost:8443 (GET /login, one /_next/static asset), each request logged in .k8s/drills/traffic-<time>.log (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make k8s-traffic-start: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	@$(K8S_DRILL_ENV) deploy/k8s/drills/traffic.sh start

k8s-traffic-stop: ## Stop the drill traffic started by k8s-traffic-start (the pid it recorded, nothing else) and print its requests by status
	@deploy/k8s/drills/traffic.sh stop

drill-k8s-canary: ## Canary drill of the gateway on the dev cluster: with drill traffic, a good revision (pod template changed by an annotation) goes 25%, 50%, 100% and is promoted; a bad one (FEED_SERVICE_ADDR to a Service that does not exist) is aborted by its analysis, weight back to 0, stable pods untouched; the good one back; table and JSON in .k8s/drills/ (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-canary: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) deploy/k8s/drills/canary.sh drill

measure-canary: ## Read back the latest aborted canary of the gateway (Rollout, AnalysisRun, HTTPRoute, the drill traffic's log, Prometheus): canary got traffic -> AnalysisRun Failed -> abort done, client 5xx, stable 5xx; JSON in .k8s/drills/ (read only)
	@test -s .k8s/ca.crt || { echo "make measure-canary: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) deploy/k8s/drills/canary.sh measure

drill-k8s-pdb: ## Cordon the nodes and evict both gateway pods one after the other, as a drain does: the PodDisruptionBudget lets the first go (201) and refuses the second (429) while its replacement is Pending; uncordon (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-pdb: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) deploy/k8s/drills/pdb.sh https://api.svp.localhost:8443

# The stage 4 rows of the threat model (docs/threat-model.md, section 5): the checks of each item are listed at the top
# of deploy/k8s/drills/threats.sh.
drill-k8s-threats: ## Check the stage 4 threat model rows on cluster svp, each with a control case: a probe pod in namespace svp-probe (created, then deleted) and media-worker reach only what the NetworkPolicies allow, Kafka ACLs per user, pod security and PSA, no trust in pg_hba, login rate limit ignores forged X-Forwarded-For, no pprof/metrics, no exposed UI, Grafana 401, no ServiceAccount reads secrets or pods; web client: no token or JWT in pages, RSC or /api JSON and /api/ outside the BFF list 400/404 (WEB-7), cross-site or same-site POSTs 403 CSRF_REJECTED (WEB-2), MinIO CORS for https://svp.localhost:8443 only (WEB-10), web pods reach only gateway, Valkey, Collector, GlitchTip (WEB-13), login rate limit through the /login form counts the address Envoy wrote (WEB-8); MinIO user svp-pg-backup reads only bucket pg-backups and no service's user reads it (BAK-1); PASS/FAIL table, log in .k8s/drills/threats-<time>.log, searched for the Secret values read (LOCAL LAB ONLY: resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-threats: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) deploy/k8s/drills/threats.sh https://api.svp.localhost:8443

# Disaster recovery of Postgres svp-pg in place (docs/adr/0020-reliability-stage6.md, section 5): the steps, the JSON
# and what an interrupted run prints are at the top of deploy/k8s/drills/backup.sh. Dev path only. MODE=latest restores
# to the end of the archive, MODE=pitr to a time between two of its markers; two runs in a row on one cluster both pass.
drill-k8s-backup: ## Delete Postgres svp-pg and its volume and restore it under the same name from its Barman Cloud backups (new archive generation), after a base backup and 60 s of marker rows in database svp_drill; restart the four services with Postgres and GlitchTip once, run the k8s-smoke flow; RTO, RPO, row counts before and after in .k8s/drills/backup-<time>.json; MODE=latest (default) or MODE=pitr; never deletes a backup (LOCAL LAB ONLY: context k3d-svp on 127.0.0.1:6550; resets register rate limit keys in the cluster's Valkey db 10)
	@test -s .k8s/ca.crt || { echo "make drill-k8s-backup: .k8s/ca.crt missing; run make k8s-up (or make k8s-ca)" >&2; exit 1; }
	$(K8S_DRILL_ENV) MODE='$(MODE)' deploy/k8s/drills/backup.sh https://api.svp.localhost:8443

# The image policy of namespace svp (docs/adr/0015-cicd-devsecops-stage5.md, section 8); the cases are listed at the
# top of deploy/k8s/drills/supplychain.sh. It talks to the cluster's API, and for the CRITICAL case to GHCR and Sigstore
# through cosign (anonymous, COSIGN_IMAGE when cosign is not installed), so it needs neither .k8s/ca.crt nor the
# gateway, and deletes no rate limit key.
drill-k8s-supplychain: ## Check Kyverno's image policy of namespace svp: a signed, clean release admitted; unsigned (SUPPLYCHAIN_UNSIGNED=<GHCR digest>), CRITICAL (SUPPLYCHAIN_VULNERABLE=<GHCR digest>, attestation within the maximum age), outside GHCR, without digest, attestation too old, ephemeral container and image UPDATE refused, each with its rule's message; Kyverno down refuses svp only; PASS/FAIL per case, JSON in .k8s/drills/ (dev path, whose policy is Audit: SUPPLYCHAIN_ENFORCE_TMP=1 switches it to Enforce for the drill and back)
	SVP_STACK=k3d SUPPLYCHAIN_UNSIGNED='$(SUPPLYCHAIN_UNSIGNED)' SUPPLYCHAIN_VULNERABLE='$(SUPPLYCHAIN_VULNERABLE)' \
	  SUPPLYCHAIN_ENFORCE_TMP='$(SUPPLYCHAIN_ENFORCE_TMP)' deploy/k8s/drills/supplychain.sh

# The operations UIs have no route, LoadBalancer or NodePort (threat model OPS-2): each is reached by a port-forward
# bound to the host's loopback only, for as long as the target runs (Ctrl-C ends it). The host ports are those of
# compose, so links such as an alert's "Source" (Prometheus' external URL, Grafana's datasource proxy on 3000) open
# the same way.
K8S_PORT_FORWARD := kubectl --context k3d-svp -n svp-obs port-forward --address 127.0.0.1

k8s-ui-grafana: ## Open Grafana of cluster svp on http://127.0.0.1:3000 (port-forward, loopback only; log in as admin with SVP_GRAFANA_ADMIN_PASSWORD of .env)
	$(K8S_PORT_FORWARD) service/kps-grafana 3000:80

k8s-ui-prometheus: ## Open Prometheus of cluster svp on http://127.0.0.1:9090 (port-forward, loopback only; Prometheus has no login, so it stays closed while the forward is not running)
	$(K8S_PORT_FORWARD) service/kps-prometheus 9090:9090

k8s-ui-alertmanager: ## Open Alertmanager of cluster svp on http://127.0.0.1:9093 (port-forward, loopback only; Alertmanager has no login, so it stays closed while the forward is not running)
	$(K8S_PORT_FORWARD) service/kps-alertmanager 9093:9093

k8s-ui-glitchtip: ## Open GlitchTip of cluster svp on http://127.0.0.1:8000 (port-forward, loopback only; log in with GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD of .env)
	$(K8S_PORT_FORWARD) service/glitchtip 8000:8000

# The web image's source maps (docs/adr/0019-web-k3d-supply-chain-observability.md, section 9): built from the working
# tree with the build id `make k8s-up` gave the image (web_build_id of deploy/k8s/lib.sh), checked against the chunks
# https://svp.localhost:8443 serves, uploaded through a port-forward of its own on 127.0.0.1:8000, closed at the end.
# Node and pnpm of web/ as for the web targets of the Makefile (WEB).
k8s-web-sourcemaps: ## Upload the source maps of the web client's browser bundle, from the build cluster svp runs (dev path), to its GlitchTip with the token of Secret svp-obs/glitchtip-sourcemaps; checks first that the web serves that build (port 127.0.0.1:8000 must be free)
	@$(WEB) bash ../deploy/observability/glitchtip/sourcemaps.sh k3d

# The web client's end-to-end tests (`make web-e2e`) against cluster svp at https://svp.localhost:8443, through
# web/e2e/k3d-e2e.sh: it checks .k8s/ca.crt and the cluster, sets SVP_STACK=k3d and the CA for curl and Node, and with
# SVP_E2E_GLITCHTIP=1 also runs web/e2e/glitchtip.e2e.ts with the read-only token of Secret svp-obs/glitchtip-api and a
# port-forward of its own on 127.0.0.1:8000. SVP_E2E_EVIDENCE as for web-e2e. Node and pnpm of web/ as for the web
# targets of the Makefile (WEB); the Playwright browsers as for web-e2e.
k8s-web-e2e: ## Playwright end-to-end tests of the web client on Chromium and WebKit against cluster svp at https://svp.localhost:8443 (CA .k8s/ca.crt); SVP_E2E_GLITCHTIP=1 adds the browser error to GlitchTip check (needs make k8s-web-sourcemaps first, port 127.0.0.1:8000 free); SVP_E2E_EVIDENCE=<absolute folder> as for web-e2e (LOCAL LAB ONLY: deletes the register rate limit keys in the cluster's Valkey db 10)
	@$(WEB) bash e2e/k3d-e2e.sh

# Read only, after make k8s-web-e2e (docs/adr/0019-web-k3d-supply-chain-observability.md, sections 7, 10 and 11): the
# checks and their PASS/FAIL table are at the top of deploy/k8s/drills/web-obs.sh. Tempo, Prometheus and GlitchTip are
# reached through port-forwards of its own on 127.0.0.1 (13200, 19090, 8000), stopped by pid at the end.
drill-k8s-web-obs: ## After make k8s-web-e2e on cluster svp: Tempo holds a trace with spans of service web and of the gateway, Prometheus has the RUM histograms of LCP, CLS (and INP when there was interaction) with closed route labels, p75 of each printed, and the GlitchTip event of SVP_E2E_GLITCHTIP=1 make k8s-web-e2e has frames mapped to the web's source; PASS/FAIL per check (read only; ports 127.0.0.1:13200, 19090, 8000 must be free)
	SVP_STACK=k3d deploy/k8s/drills/web-obs.sh

k8s-ui-argocd: ## Open Argo CD of the GitOps cluster on https://127.0.0.1:8081 (port-forward, loopback only; its own self-signed certificate; log in as admin, password from the command printed first)
	@echo "password of admin: kubectl --context k3d-svp -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	kubectl --context k3d-svp -n argocd port-forward --address 127.0.0.1 service/argocd-server 8081:443

# The manifests written for the cloud cluster of stage 7 (deploy/k8s/cloud/, the k6 Jobs of deploy/k6/;
# docs/adr/0020-reliability-stage6.md, section 8), checked without a cluster: no kubectl, no .env. The steps are at the top
# of deploy/k8s/cloud/check.sh: kubeconform -strict of KUBECONFORM_IMAGE against the Kubernetes schemas of
# CLOUD_K8S_VERSION and against schemas made from the CRDs of the pinned Chaos Mesh, Velero and snapshot controller (no
# kind is skipped for want of a schema; a missing one fails), then the bounds of the Chaos Mesh experiments and a digest
# on every image. Needs network access: chart repositories, GitHub. CLOUD_K8S_VERSION is the newest minor that the CI of
# both Chaos Mesh 2.8 and Velero 1.18 tests (1.33 to 1.35); stage 7 sets it to the EKS version.
CLOUD_K8S_VERSION := 1.35.9

cloud-check: ## Check the cloud cluster's manifests without a cluster: render deploy/k8s/cloud/charts.json, kubeconform -strict (Kubernetes CLOUD_K8S_VERSION, CRD schemas of the pinned Chaos Mesh, Velero and snapshot controller) on them, on deploy/k8s/cloud/ and on deploy/k6/ manifests; every Chaos Mesh experiment bounded (duration, own namespace), every image pinned by digest (needs network)
	KUBECONFORM_IMAGE='$(KUBECONFORM_IMAGE)' CLOUD_K8S_VERSION='$(CLOUD_K8S_VERSION)' deploy/k8s/cloud/check.sh
