# 0020. Giai đoạn 6: reliability chia hai phần, phần local đo nhỏ (k6 theo SLO bằng image ghim, SLO web, backup/restore Postgres bằng CloudNativePG và plugin Barman Cloud có RTO/RPO đo trên k3d, runbook, game day, RFC, stack trong CI) và phần đo thật dời giai đoạn 6b và 7 (k6 tải lớn và 1 000 req/s, Chaos Mesh, Velero, hai media-worker) chỉ viết và kiểm tĩnh

- Trạng thái: Chấp nhận; phần local hiện thực và đã kiểm trên máy ngày 2026-10-24 (mục Kết quả). Ghi chú 2026-10-24: phần đo
  thật chia giai đoạn 6b "Kiểm chứng dồn" (không cần dịch vụ AWS/GCP) và giai đoạn 7 (dịch vụ cloud), mục 1. Ghi chú 2026-10-25:
  phần 1 của giai đoạn 6b đã chạy trên runner ([0021](0021-deferred-verification-stage6b.md), mục Kết quả): job `stack`, canary
  gateway dưới probe mới, RAM plugin, hai lượt backup trên runner, điều kiện mới của `RateLimitFallbackActive` đạt; LCP `/` (và
  `/v/{id}` ở lượt cuối) chưa đạt; k6 tải lớn, Chaos Mesh, Velero, hai media-worker trên cluster GitOps ở phần sau của giai đoạn 6b. §2 (`render.sh` nhận số
  pod), §6, §7 (Velero, Chaos Mesh trên k3d của runner) sẽ chỉnh bởi 0021 khi hiện thực phần đó; quyết định giữ `Suspense` của
  feed (Kết quả "LCP") đảo theo D17 của 0021 (đòn bẩy (a) đã làm, LCP `/` vẫn chưa đạt). Đích MinIO của backup (§5, Tên chốt:
  user, policy, `endpointURL`) và việc tồn "Thay MinIO" (§16) bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md) (RustFS, `s3.svp-data:9000`;
  bucket, user `svp-pg-backup`, policy giữ nguyên; backup hai chế độ kiểm lại trên RustFS ngày 2026-10-25)
- Ngày: 2026-10-24

## Bối cảnh

- Giai đoạn 6 của [plan](../../plans/261004-devops-sa-roadmap/plan.md): kịch bản k6 theo SLO (báo p95/p99); Chaos Mesh (kill
  pod, làm chậm mạng, tắt Redpanda); diễn tập backup/restore (Postgres + Velero); runbook; game day + postmortem; tuỳ chọn
  Istio ambient. **Xong khi:** có báo cáo tải, báo cáo chaos và RTO đo thật của lần restore. Ghi chú 2026-10-21: máy 16 GB
  không chịu đo tải hay chaos trên k3d ([ADR-0017](0017-gitops-capacity-media-worker-max2.md)), nên chia phần chạy được ở
  local và phần đo thật trên cluster cloud ở giai đoạn 7. Ghi chú 2026-10-24: k6 và SLO đo cả web, e2e web và Lighthouse vào
  CI cùng "stack chạy trong CI", LCP mobile chưa đạt ([ADR-0018](0018-web-profiles-public-video-upload.md), Kết quả phần B),
  MinIO community đã archive.
- Hiện trạng code (đọc ngày 2026-10-24, chi tiết ở mục Kiểm chứng):
  - Bốn SLO của [ADR-0011](0011-observability-stage3.md) §8 đo ở gateway và video-service; web chỉ có dashboard RUM, SLO INP
    hẹn giai đoạn 6 ([ADR-0019](0019-web-k3d-supply-chain-observability.md) §11).
  - Gateway có 8 lớp rate limit theo IP hay `user_id` ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §2); compose
    tin 0 hop proxy, k3d tin 1 hop từ dải pod; video-service giữ tối đa 3 video `UPLOADING` có form còn hạn mỗi user (UP-7). k6
    chạy từ một địa chỉ chạm các giới hạn theo IP trước khi chạm hệ thống.
  - Postgres: compose dùng Postgres native chung với dự án khác (`CLAUDE.md`); k3d có Cluster CloudNativePG `svp-pg` một
    instance, image `minimal` (không có binary Barman), chưa backup, chưa PodMonitor (giai đoạn 4 ghi "không có `cnpg_*`");
    NetworkPolicy của `svp-data` chỉ mở 5432 cho client và 8000 cho operator.
  - Probe của chart `svp-service` không đặt `timeoutSeconds` (mặc định 1 s); giai đoạn 4 thấy node bão hoà CPU làm liveness quá
    hạn và kubelet restart pod còn sống.
  - Mọi pod mới có Postgres trên k3d restart một lần vì lần nối đầu bị từ chối (giai đoạn 5, "Còn mở"); `measure-gitops` vì thế
    không đo được bản phát hành của service có Postgres.
  - Hạn 50 ms của lệnh Redis (ADR-0010) chưa có số p99 dưới tải.
  - k6 có trên máy qua Homebrew (không ghim); repo chưa có kịch bản tải, chưa có công cụ kiểm schema manifest.
  - `ci.yml` có 7 job kiểm tĩnh và test, chưa job nào dựng stack.
- Ràng buộc: máy 16 GB (Apple M2) không đo năng lực, chaos hay tải lớn; tối đa **một buổi k3d đường dev** cho cả giai đoạn;
  compose một lượt mỗi phép kiểm. Repo công khai. Mọi lệnh chạm AWS do người học chạy.

## Kiểm chứng (đã kiểm ngày 2026-10-24)

Không dựng stack hay cluster. Release, tag và mã nguồn đọc bằng `gh api` (chỉ đọc) ở đúng tag ghim; package npm đọc từ tarball
của registry trong thư mục tạm ngoài repo; chart tải vào thư mục tạm ngoài repo với `HELM_CACHE_HOME`, `HELM_CONFIG_HOME`,
`HELM_DATA_HOME` trỏ vào đó (`helm show values --version`, `helm template`); digest đọc bằng Registry HTTP API (token ẩn danh,
`Accept` OCI index + Docker manifest list, header `Docker-Content-Digest`, băm lại thân để so, rồi đọc index để thấy
`linux/amd64` và `linux/arm64`). "Mới nhất" là bản phát hành không phải prerelease và đủ 3 ngày tuổi, như `minimumReleaseAge`
của Renovate ([ADR-0015](0015-cicd-devsecops-stage5.md) §10).

| Kiểm gì | Nguồn hay lệnh | Kết quả |
| --- | --- | --- |
| Version k6 | `gh api repos/grafana/k6/releases`; release notes v2.0.0–v2.3.0 | v2.3.0 (2026-09-21) là bản cao nhất; v1.8.2 (2026-10-12) mới hơn theo ngày nhưng chỉ là bản vá bảo mật của nhánh v1 (ghi chú v2.0.0: nhánh v1 chỉ còn nhận bản vá bảo mật). Thay đổi phá vỡ của v2 không chạm thứ dự án dùng: executor `ramping-arrival-rate`, `constant-arrival-rate` (`lib/executor/`), threshold `metric{tag:value}` (`metrics/metric.go`), tag của `k6/http`, `parseHTML` của `k6/html`, `handleSummary` vẫn nhận dạng cũ (`internal/cmd/run.go`), `k6 inspect`, `dropped_iterations` (`metrics/builtin.go`). Bị bỏ: `k6/experimental/redis`, executor `externally-controlled`; `http.get` với hơn 2 tham số chỉ cảnh báo và bỏ tham số thứ ba |
| Image k6 | Registry API `registry-1.docker.io/v2/grafana/k6/manifests/2.3.0`; config một nền tảng; `Dockerfile@v2.3.0` | Index OCI `sha256:9c2dee7f…5aeb34`: `linux/amd64` `sha256:98305727…e428c2`, `linux/arm64` `sha256:06181d5d…73dcb2`, cộng hai manifest attestation. User 12345, entrypoint `k6`, workdir `/home/k6`, nền alpine-minirootfs 3.24.1. Tag `latest`, `v2` là index khác (chỉ khác attestation): ghim `2.3.0` |
| `k6 inspect` cần mạng không | `internal/cmd/inspect.go`, `test_load.go` @v2.3.0 | Chỉ chạy init context của script; chỉ ra mạng khi import `https://` hay `k6/x/*` (tự tìm extension, tắt bằng `K6_AUTO_EXTENSION_RESOLUTION=false`) |
| Dữ liệu của `handleSummary` | `internal/js/summary.go@v2.3.0` dòng 130–178 | Đối tượng truyền vào có `setup_data` (giá trị trả về của `setup()`): ghi nguyên đối tượng ra file là ghi token, cookie của pool user |
| kubeconform | `gh api repos/yannh/kubeconform/releases`; `Readme.md`, `Dockerfile`, `.goreleaser.yml`, `acceptance-nonetwork.bats` @v0.8.0; Registry API `ghcr.io/v2/yannh/kubeconform/manifests/v0.8.0` | v0.8.0 (2026-06-04), image chỉ có trên GHCR, `FROM scratch` (không shell), chứa `/kubeconform` và `/openapi2jsonschema` (bản Go, mới ở v0.8.0), chạy root, entrypoint `/kubeconform`. Index Docker manifest list `sha256:faffaf43…c0f64e`: `linux/amd64` `sha256:5103f6f5…4222f9e0`, `linux/arm64` `sha256:5ec810f2…87b223d`. Cờ `-strict`, `-schema-location` (lặp được; biến `{{.Group}}`, `{{.ResourceKind}}`, `{{.ResourceAPIVersion}}`, `{{.NormalizedKubernetesVersion}}`, `{{.StrictSuffix}}`), `-kubernetes-version`, `-summary`, `-output`; đường dẫn cục bộ đọc bằng loader file, chạy được không mạng |
| Schema CRD có sẵn | datreeio/CRDs-catalog `main` `501527ab` (2026-10-18) | Không có `chaos-mesh.org`; `velero.io` sinh từ Velero 1.17.1 (commit `ddca122f`, 2026-01-11) |
| CRD của Velero theo bản vá | `gh api repos/velero-io/velero/compare/v1.18.2...v1.18.4`; `git/ref/tags/v1.18.4` | CRD `velero.io_restores.yaml` đổi giữa v1.18.2 (appVersion của chart 12.2.1) và v1.18.4; tag v1.18.4 là commit `4ee1e79a7aed367fd9b767b8219ec65bd0c96892` |
| Schema Kubernetes | yannh/kubernetes-json-schema `master` `f7d855e49c34b039c9ef2196444910275e31e09e` (2026-10-23) | Có `v1.35.0`–`v1.35.9`, `v1.36.0`–`v1.36.5`, `v1.37.0`, `v1.37.1` dạng `-standalone-strict` (không `$ref`) |
| Metric HTTP của server web | `@opentelemetry/instrumentation-http` 0.223.0 (tarball npm, `build/src/http.js`, `utils.js`); `web/server/telemetry/otel.ts` | Chỉ semconv ổn định, không đọc `OTEL_SEMCONV_STABILITY_OPT_IN`: histogram `http.server.request.duration`, đơn vị `s`, bucket `[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]`; thuộc tính `http.request.method`, `url.scheme`, `network.protocol.version` (khi có), `http.response.status_code`, `error.type` (= mã khi 5xx), `http.route` chỉ khi framework đặt `rpcMetadata.route`. Ghi cho mọi request, kể cả request mà sampler của web bỏ span (`_closeHttpSpan`), vì web không đặt `ignoreIncomingRequestHook`. Prometheus: `http_server_request_duration_seconds_{bucket,count,sum}{service_name="web"}`, cùng tên với metric của gateway |
| Next có đặt route cho metric | `packages/next/src/server/base-server.ts@v16.4.2` dòng 887–962; tìm `setRPCMetadata` trong repo `vercel/next.js` | Next ghi `http.route` (template, ví dụ `/v/[id]`) lên span của nó và span cha, nhưng không gọi `setRPCMetadata`: histogram không có `http.route` |
| Vì sao web không có histogram server (đọc và thử ngày 2026-10-24, sau lượt k6 đầu) | `next/dist/server/lib/start-server.js@16.4.2` dòng 31; `@opentelemetry/instrumentation` 0.223.0 `build/src/platform/node/instrumentation.js` (`enable()`, `_onRequire`, `_warnOnPreloadedModules`); `require-in-the-middle` 8.0.1 `index.js` dòng 137–150, 192–200; chunk server của `next build` (`.next/standalone/.next/server/chunks/`); chạy `server.js` standalone với `node -r <probe>` giữ tham chiếu `http.Server.prototype.emit` từ trước khi có hook, `OTEL_LOG_LEVEL=debug` | `start-server.js` require `http` ở đầu module, trước `register()`. `enable()` của instrumentation chỉ đăng ký hook cho các lần `require`/`process.getBuiltinModule` **sau** đó (hook của `require-in-the-middle` vá cả module lõi đã nạp, ở lần nạp kế tiếp đi qua nó), không vá module đang có. Mọi chỗ khác dùng `http` là code đã gộp: chunk gọi `require("http")`/`require("node:http")` qua `e.x(...)` của Turbopack, mỗi id module chạy một lần rồi giữ trong cache của bundle. Không lần nạp nào tới hook sau `sdk.start()`: probe thấy `Server.prototype.emit` không bị bọc sau request, log debug không có dòng "Applying instrumentation patch"; `_warnOnPreloadedModules` đọc `globalThis.require`, không có trong module CJS, nên cũng không cảnh báo. Thêm một lần `process.getBuiltinModule("node:http")` sau `sdk.start()` (code gộp không đổi lệnh này): log có "Applying instrumentation patch for nodejs core module on require hook {module: 'http'}" và "incomingRequest" mỗi request, probe thấy `emit` đã bọc |
| Form đăng nhập không JavaScript | `web/server/auth-actions.ts`, `web/server/csrf.ts`; `packages/next/src/server/app-render/action-handler.ts@v16.4.2` dòng 636–700, 725–770 | Action của `/login` chạy như nhau với form không JS. Next 16.4.2 không nhận MPA action dạng `application/x-www-form-urlencoded` (trả `null`, chỉ render trang), chỉ `multipart/form-data`; host của `Origin` phải bằng `x-forwarded-host` hay `Host`, lệch thì từ chối ("Invalid Server Actions request"). CSRF của web: không có `Sec-Fetch-Site` thì `Origin` phải đúng `APP_ORIGIN` |
| Lớp rate limit và khoá | `services/gateway/internal/ratelimit/ratelimit.go`, `keys.go`; `internal/api/api.go` dòng 93–125, 176–218, 498, 640–660; `internal/httpx/clientaddr.go`; `web/server/gateway.ts` dòng 10–30 | Bảng ở mục 2. BFF chuyển nguyên `X-Forwarded-For` nó nhận, không thêm hop |
| UP-7 | `services/video-service/internal/server/server.go` dòng 50–57, 209–236 | `MaxOpenUploads = 3` video `UPLOADING` tạo trong `uploadFormTTL` 15 phút mỗi tác giả; quá thì gateway trả 429 `TOO_MANY_UPLOADS` |
| Metric Redis | `internal/redisx/redisx.go`; `extra/redisotel/metrics.go@v9.23.0`; `internal/telemetry/telemetry.go` dòng 118–131 | Histogram `db.client.connections.use_time` (ms; `type` = `command`/`pipeline`, `status` = `ok`/`nil`/`error`, `error_type` = `none`/`context_canceled`/`context_timeout`/`other`): từ lúc mượn tới lúc trả kết nối, gần đúng thời gian một lệnh; bucket mặc định của SDK Go (View chỉ đổi ba metric HTTP/RPC). Prometheus `db_client_connections_use_time_milliseconds_*{db_system="redis"}` |
| Log cache khám phá | `services/feed-service/internal/server/server.go` dòng 52–54, 185–200, 236–290 | WARN `read explore cache` tối đa một lần mỗi phút (`cacheWarnInterval`, chung cho đọc, ghi, giải mã); mỗi lần đọc Postgres có INFO `explore page loaded from database` với `cache=` và `cache_write=` |
| Sloth tắt cảnh báo page | `pkg/prometheus/api/v1/v1.go@v0.16.0` dòng 153–162 | `page_alert.disable: true` bỏ hẳn rule page; ticket giữ cửa sổ mặc định 3× (1d/2h) và 1× (3d/6h) |
| Mặc định của probe | `pkg/apis/core/v1/defaults.go@v1.36.5` dòng 233–246; `deploy/helm/svp-service/templates/deployment.yaml` dòng 90–118 | `timeoutSeconds` 1, `periodSeconds` 10, `failureThreshold` 3; chart chỉ đặt `periodSeconds` (readiness 5, liveness 10, startup gRPC 2 × 30 lần) |
| Envoy, Rollouts dựa vào probe không | `grep -rn 'healthCheck\|BackendTrafficPolicy' deploy/`; `deploy/helm/svp-service/templates/canary.yaml` | Envoy không có health check chủ động, chỉ theo EndpointSlice (tức readiness); phân tích canary đọc metric Envoy, không đọc probe |
| CloudNativePG | chart `cloudnative-pg` 0.29.1 (`helm show chart`); `docs/src/wal_archiving.md`, `release_notes/v1.30.md`, `internal/webhook/v1/cluster_webhook.go` @v1.30.1; README của `cloudnative-pg/postgres-containers` | Operator 1.30.1. `spec.backup.barmanObjectStore` deprecated từ 1.26; webhook 1.30.1 cảnh báo "will be completely removed in CloudNativePG 1.31.0" (trên `main` đổi thành 1.32.0, chưa phát hành). Image `minimal` và `standard` không có binary Barman, chỉ image `system` (deprecated) có |
| Plugin Barman Cloud | chart `plugin-barman-cloud` 0.8.1 (`helm show values`, `helm template`); `plugin-barman-cloud@v0.15.1` (`docs/`, `go.mod`, `internal/cnpgi/operator/manager.go`, `lifecycle.go`, CRD trong chart); Registry API | Chart 0.8.1 (2026-09-30), plugin v0.15.1, cần CloudNativePG ≥ 1.26, cài cùng namespace với operator, build trên CloudNativePG v1.30.1. Cần cert-manager (Issuer tự ký, Certificate `barman-cloud-server`, `barman-cloud-client`). Pod và sidecar đạt PSA `restricted`. Service `barman-cloud` cổng 9090 (mTLS). Chart không ghim digest nhưng nhận `tag: v0.15.1@sha256:…`: `ghcr.io/cloudnative-pg/plugin-barman-cloud` index `sha256:c75acad19a36e8176cfe2885761ff1b836c6ef977d7257e298c99a28b5c302ef`, sidecar `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar` index `sha256:2287a793a804db751edd0d07d44cd549e357677e98a800eb12e2cf7c0d53f9b0`, cả hai `linux/amd64` + `linux/arm64`. RBAC của chart: ClusterRole đọc, tạo, xoá Secret và tạo Role, RoleBinding ở mọi namespace; manager dựng cache cho cả cluster (`ctrl.NewManager` không giới hạn namespace), không có cờ thu hẹp |
| Sidecar của plugin | plugin `internal/cnpgi/operator/lifecycle.go` dòng 346–358, 452–469 | Native sidecar (initContainer `restartPolicy: Always`) `plugin-barman-cloud` trong pod instance và pod Job phục hồi, securityContext đạt `restricted`, resources lấy từ `ObjectStore.spec.instanceSidecarConfiguration` (mặc định rỗng). RAM: tài liệu không nêu; issue #825 (đỉnh do page cache) khuyên đặt limit bộ nhớ |
| Operator giới hạn namespace có thấy plugin | `internal/configuration/configuration.go` dòng 254–258, 295–307; `pkg/multicache/multinamespaced_cache.go` dòng 50–77, 80–86, 145–162; `internal/cmd/manager/controller/controller.go` dòng 140–181, 338; `internal/controller/plugin_controller.go` dòng 362–375; `plugin_predicates.go` dòng 45–50 @v1.30.1 (commit `2a35abb4`) | `WatchedNamespaces()` tách `WATCH_NAMESPACE` theo dấu phẩy, bỏ khoảng trắng và phần tử rỗng. Có `WATCH_NAMESPACE` thì cache là `DelegatingMultiNamespacedCacheBuilder(watched, OPERATOR_NAMESPACE)`: informer và `List` chỉ từ các namespace được watch, namespace operator chỉ có trong cache phụ cho `Get` theo tên (namespace có ở cả hai là một khoá map, vô hại). Controller `plugin` watch `Service` (và `Secret`) qua cache đó, predicate chỉ nhận Service ở namespace operator có nhãn `cnpg.io/pluginName` và ba annotation client/server Secret, port: watch chỉ `svp-data` thì không bao giờ thấy Service `cnpg-system/barman-cloud` (chart 0.8.1 render đủ nhãn, annotation). Informer EndpointSlice đã ghim vào namespace operator (dòng 165–170); Secret loại type `helm.sh/release.v1` ở mức informer (dòng 140–151). Không có biến hay cờ nào khác cho namespace tìm plugin |
| Thế hệ lưu trữ | `docs/src/recovery.md@v1.30.1` dòng 619–637; plugin `docs/usage.md` dòng 134–193, `internal/cnpgi/restore/restore.go` dòng 103–119, `config/config.go` dòng 155–171 | `serverName` của lưu WAL và của nguồn phục hồi đều mặc định là tên Cluster; Job phục hồi kiểm đích lưu WAL rỗng **trước** khi phục hồi, không rỗng thì Cluster đứng ở "Setting up primary" với "Expected empty archive". Tài liệu: dùng chung ObjectStore thì mỗi Cluster một `serverName` |
| `bootstrap` trên Cluster có sẵn | `internal/controller/cluster_controller.go` dòng 1119–1121, `cluster_create.go` dòng 1140–1165, `internal/webhook/v1/cluster_webhook.go` dòng 227–250 @v1.30.1 | Chỉ dùng khi tạo primary đầu (chưa có instance nào); sửa sau đó không có tác dụng; webhook không khoá field này |
| `archive_timeout` | `pkg/postgres/configuration.go@v1.30.1` dòng 561 | Mặc định `5min`, không nằm trong danh sách cố định, đổi được qua `postgresql.parameters` |
| Metric backup | `pkg/management/postgres/webserver/metricserver/pg_collector.go@v1.30.1`; plugin `internal/cnpgi/instance/metrics.go` dòng 37–53, 123–141, `docs/observability.md` | Cổng 9187 (`metrics`): `cnpg_pg_stat_archiver_{archived,failed}_count`, `_last_archived_time`, `_last_failed_time` (−1 trước sự kiện đầu), `cnpg_collector_pg_wal_archive_status{value="ready"\|"done"}`. Với plugin, `cnpg_collector_last_available_backup_timestamp` luôn 0; plugin xuất qua cùng exporter `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp`, `_first_recoverability_point`, `_last_failed_backup_timestamp` (0 trước backup đầu). Pod instance có nhãn `cnpg.io/cluster`, `cnpg.io/podRole: instance`; pod Job phục hồi có `cnpg.io/cluster` và nhãn `inheritedMetadata` nhưng không có cổng `metrics` |
| Chaos Mesh | chart `chaos-mesh` (`https://charts.chaos-mesh.org`, `helm show values`, `helm template`); `chaos-mesh/chaos-mesh` @v2.8.5–v2.8.6 (`.github/workflows/e2e_test.yml`, `api/v1alpha1/`, `controllers/chaosimpl/podchaos/podfailure/impl.go`, `pkg/selector/`, `images/chaos-daemon/Dockerfile`); `chaos-mesh/website` `versioned_docs/version-2.8.5/`; Registry API | v2.8.6 (2026-10-21) chưa đủ 3 ngày: ghim **2.8.5** (2026-10-16; 2.8.6 chỉ sửa IOChaos, PhysicalMachineChaos, dashboard). Image `ghcr.io/chaos-mesh/chaos-mesh:v2.8.5` index `sha256:942bff26d591537f655df50532e3880d73fa8b6fca34a233fc69f8ccfd36188d`, `ghcr.io/chaos-mesh/chaos-daemon:v2.8.5` index `sha256:d794bf427ab1dfacfd51c2f417d26731ce46919637b1c83620f0afd40f580bd4`, đủ hai nền tảng. CI e2e chạy Kubernetes 1.33–1.35. chaos-daemon luôn `hostPID`, mặc định `privileged`, hostPath socket runtime, `/sys`, `/lib/modules`: namespace phải PSA `privileged`. `clusterScoped: false` chỉ cho một namespace đích (`controllerManager.targetNamespace`), RBAC thành RoleBinding ở namespace đó; `clusterScoped: true` (mặc định) thì ClusterRoleBinding đọc, sửa Secret ở mọi namespace. Dashboard mặc định NodePort, tắt bằng `dashboard.create: false`; `securityMode: true` còn bật webhook phân quyền của controller. `pod-failure` đổi image mọi container thành image pause (mặc định `gcr.io/google-containers/pause:latest`, chỉ amd64): Kyverno ở `svp` từ chối UPDATE đó trên đường Enforce. Chart sinh lại chứng chỉ và annotation ngẫu nhiên mỗi lần render. chaos-daemon ép iptables-legacy, AMI EKS AL2023 dùng iptables-nft; delay không `target` chỉ dùng `tc netem` |
| Velero | chart `velero` 12.2.1 (`https://vmware-tanzu.github.io/helm-charts`); `velero-io/velero@v1.18.4` (`README.md`, `site/content/docs/`, `pkg/`), `velero-io/velero-plugin-for-aws@v1.14.4`; Registry API | Chart 12.2.1 (2026-10-08) mặc định Velero 1.18.2; bản mới nhất 1.18.4 (2026-09-28). Velero 1.18 thử trên Kubernetes 1.33–1.35. Plugin AWS v1.14.4 cho Velero 1.18. `velero/velero:v1.18.4` index `sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b`, `velero/velero-plugin-for-aws:v1.14.4` index `sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa`, đều có `linux/amd64`, `linux/arm64`. Backup mặc định gồm mọi object của namespace, cả Secret. CSI snapshot có sẵn nhưng vẫn cần `--features=EnableCSI`; data mover và file-system backup cần node-agent (data mover chạy pod root; file-system backup hostPath `/var/lib/kubelet/pods`, namespace PSA `privileged`). Chart mặc định bind ServiceAccount `velero-server` vào `cluster-admin`. Restore bỏ qua object đã có (PVC có sẵn thì dữ liệu không được phục hồi) |

## Tên chốt

Code, cấu hình, diễn tập và tài liệu dùng đúng các tên này; đổi tên nào thì sửa ADR này trước.

| Nhóm | Tên | Giá trị, ý nghĩa |
| --- | --- | --- |
| Image | `K6_IMAGE` (`Makefile`) | `grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34` |
| Image | `KUBECONFORM_IMAGE` (`Makefile`) | `ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e` |
| Make | `make k6-check` | `deploy/k6/k6.mk`: `k6 inspect --execution-requirements` file vào với từng profile, trong `K6_IMAGE`, `--network none`, `K6_AUTO_EXTENSION_RESOLUTION=false` |
| Make | `make load-local`, `make load-ci` | Profile `local`, `ci` vào stack `make up` đang chạy; từ chối khi stack tắt hay cluster k3d chạy; trước khi chạy xoá `svp:gw:rl:register:*` ở Redis native db 10 (`reset_register_limit` của `deploy/compose/lib.sh`; **LOCAL LAB ONLY**) |
| Make | `make cloud-check` | `deploy/k8s/k8s.mk`: kubeconform mọi manifest cloud (mục 8) |
| Make | `make drill-k8s-backup` | `deploy/k8s/drills/backup.sh`, `MODE=latest` (mặc định) hay `MODE=pitr` (mục 5) |
| Make | `make gameday`, `make gameday-mark M=<mốc>`, `make gameday-end` | `deploy/compose/drills/gameday.sh start\|mark\|end` (mục 13) |
| k6 | File | `deploy/k6/main.js` (file vào, chạy scenario của `api.js` và `web.js` trong một tiến trình), `deploy/k6/lib/` (helper), `deploy/k6/load.sh` (của `make load-local`, `make load-ci`); Job cloud ở `deploy/k6/cloud/`: `job.yaml.in` (mẫu), `render.sh` (in manifest), `run.sh` (người học chạy) |
| k6 | Biến | `SVP_K6_PROFILE` (`local`, `ci`, `cloud`), `SVP_API_URL`, `SVP_WEB_URL`, `SVP_WEB_ORIGIN`, `SVP_K6_RESULTS`, `SVP_K6_HOLD` (thời gian giữ tải, mặc định theo profile), `SVP_K6_FORWARDED_FOR` (chỉ Job cloud khi chốt 2 hop: IP pod, `render.sh --forwarded-for`); không dùng tiền tố `K6_` (của chính k6) |
| k6 | Tag | `route`: template của route (đường OpenAPI của gateway như `/videos/{video_id}/like`, route của Next như `/v/[id]`), đặt cả làm `name` để tóm tắt không nổ theo URL; `app`: `api` hay `web`; `phase`: `setup` hay `load` |
| k6 | Metric riêng | `svp_rate_limited` (Counter, response 429, tag `route`) |
| k6 | Kết quả | `.k6/<profile>-<yyyymmddThhmmssZ>/summary.json` (gitignore): metric, threshold, điều kiện chạy; không `setup_data`, cookie, token, mật khẩu |
| SLO | `web-availability` | 99,9% response của server web không 5xx; cảnh báo `WebAvailabilityBudgetBurn` (page và ticket) |
| SLO | `web-inp` | 75% lượt có INP ≤ 200 ms; cảnh báo `WebINPBudgetBurn`, chỉ ticket |
| Backup | Component | `plugin-barman-cloud` trong `deploy/argocd/apps/components.json`, namespace `cnpg-system`, wave 3, chart `plugin-barman-cloud` 0.8.1 của `https://cloudnative-pg.github.io/charts`, values `deploy/k8s/values/plugin-barman-cloud.yaml` |
| Backup | Bucket, user MinIO | Bucket `pg-backups`; user `svp-pg-backup` với policy `deploy/minio/pg-backup-policy.json` (chỉ bucket đó; bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md): store RustFS, policy ở `deploy/s3/pg-backup-policy.json`); secret key `SVP_PG_BACKUP_S3_SECRET_KEY` trong `K8S_SECRET_VARS` (chỉ cluster) |
| Backup | Secret | `svp-data/pg-backup-s3`, khoá `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
| Backup | ObjectStore | `svp-pg-backup` (`barmancloud.cnpg.io/v1`): `destinationPath: s3://pg-backups/`, `endpointURL: http://minio.svp-data:9000` (bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md): `http://s3.svp-data:9000`), nén `gzip` cho WAL và dữ liệu, `retentionPolicy: "7d"` |
| Backup | ScheduledBackup | `svp-pg-daily`: `schedule: "0 0 3 * * *"` (03:00 UTC; cron 6 trường có giây), `immediate: true`, `method: plugin`, `backupOwnerReference: none`; là hook Helm `post-install,post-upgrade` (Argo CD: PostSync) weight 1, `before-hook-creation` (mục 5) |
| Backup | `serverName` | Value `postgres.backup.serverName` của chart `svp-data`, mặc định `svp-pg`; mỗi lần phục hồi một thế hệ mới `svp-pg-<yymmddhhmmss>` (UTC) |
| Backup | Diễn tập | Database `svp_drill` trong `svp-pg`, bảng `markers`; JSON `.k8s/drills/backup-<time>.json` |
| Metric | PodMonitor | `svp-pg` trong chart `svp-observability`: `namespaceSelector` `svp-data`, nhãn `cnpg.io/cluster: svp-pg` và `cnpg.io/podRole: instance`, cổng `metrics` |
| Cảnh báo | Backup | `PostgresWALArchivingFailing` (page), `PostgresBackupTooOld` (ticket), nhóm `postgres-backup` của `deploy/observability/prometheus/rules/svp-alerts.yaml` |
| Tài liệu | Runbook | `docs/runbooks/README.md`; `docs/runbooks/<tên alert kebab-case>.md`; sự cố đã gặp và quy trình ở `docs/runbooks/<tên>.md` (mục 12); `runbook_url` = `https://github.com/anhnvcoder/short-video-platform/blob/main/docs/runbooks/<file>.md` |
| Tài liệu | Postmortem, RFC | `docs/postmortems/README.md`, `docs/postmortems/<yymmdd>-<slug>.md`; `docs/rfc/README.md`, `docs/rfc/0001-reliability.md` |
| CI | Job | `stack` của `ci.yml`, không nằm trong `ci-ok`; artifact `lighthouse` và `k6-summary` |
| Cloud | Thư mục | `deploy/k8s/cloud/`: `charts.json` (chart chỉ cho cloud, cùng trường với `components.json`), `values/chaos-mesh.yaml`, `values/velero.yaml`, `chaos/*.yaml`, `velero/*.yaml`, `velero/drill-restore.sh`; Job k6 ở `deploy/k6/cloud/` |
| Cloud | Namespace | `svp-load` (Job k6), `chaos-mesh`, `velero` |
| Cloud | Version Kubernetes của kiểm tĩnh | `CLOUD_K8S_VERSION := 1.35.9` (`deploy/k8s/k8s.mk`), chốt lại theo EKS ở giai đoạn 7 |

## 1. Hai phần, mỗi phần có "Xong khi" riêng

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Làm hết ở local (compose, k3d) | Một chỗ, không tốn tiền cloud | Máy không chịu: k3s server chết khi 3 worker cùng transcode (ADR-0017); số tải và chaos trên laptop không nói gì về hệ thống, chỉ nói về laptop |
| Dời hết sang giai đoạn 7 | Máy nhẹ | Buổi cloud tính tiền theo giờ phải vừa viết vừa chạy mọi thứ; lên cloud mà chưa có runbook, chưa từng khôi phục dữ liệu |
| **Chia hai: local làm phần chạy được, cloud chỉ viết và kiểm tĩnh** | Phần học không cần tải lớn xong ở giai đoạn 6; buổi cloud chỉ còn chạy lệnh đã viết sẵn | "Xong khi" của roadmap chỉ đạt trọn ở giai đoạn 7 |

### Quyết định

Chọn chia hai. Giai đoạn 6 đóng khi phần local đạt; "Xong khi" của roadmap (báo cáo tải, báo cáo chaos, RTO đo thật) đạt trọn
ở giai đoạn 7, khi phần cloud chạy.

**Phần local (giai đoạn 6), xong khi:**

| Việc | Xong khi | Mục |
| --- | --- | --- |
| Kịch bản k6 theo SLO | `make k6-check` sạch; một lượt `make load-local` trên `make up OBS=lgtm`: p95/p99 theo route phía k6 và phía server, tỷ lệ 5xx, 429 = 0, `dropped_iterations`, điều kiện máy, câu "không kết luận năng lực" ở mục Kết quả | 2 |
| SLO web | `web-availability`, `web-inp` trong spec Sloth; `make slo-check` sạch với ca test mới | 3 |
| Hạn 50 ms của Redis | Quy tắc mục 4 áp trên số của lượt k6 local, kết luận ghi ở Kết quả | 4 |
| Backup/restore Postgres | `make drill-k8s-backup` PASS hai lượt liền trên cluster dev (`MODE=latest` rồi `MODE=pitr`), RTO và RPO đo thật ở Kết quả | 5 |
| Probe, thử lại kết nối Postgres | Kiểm trên buổi k3d: không pod nào restart, log thử lại có số lần | 10, 11 |
| Runbook, postmortem | Runbook cho mọi cảnh báo `severity=page` và sự cố đã gặp, `runbook_url` trên mọi rule page; mẫu postmortem | 12 |
| Game day | Một buổi `make gameday` dưới tải k6, postmortem viết từ mốc thật | 13 |
| RFC | `docs/rfc/0001-reliability.md` | 14 |
| Stack trong CI | Job `stack` chạy ở lượt PR đầu (**kiểm sau push**) | 15 |
| LCP | LCP mobile `/` và `/v/{id}` ≤ 2 500 ms (median 3 lượt `make web-lighthouse`) | 16 |
| Kiểm tĩnh phần cloud | `make cloud-check` sạch, có ca cố ý làm hỏng một field thì FAIL | 6–8 |

**Phần cloud (chạy ở giai đoạn 7, ở đây viết và kiểm tĩnh)**: k6 1 000 req/s (mục 2), Chaos Mesh (mục 7), Velero (mục 6), hai
media-worker cùng transcode và RAM nghỉ (mục 9). Mỗi mục ghi sẵn lệnh và tiêu chí đạt; mọi lệnh chạm cloud do người học chạy, với
context của cluster cloud ghi trong lệnh; script cloud từ chối context `k3d-*` và context rỗng trước khi làm gì.

**Sửa 2026-10-24** (người học chốt, sau khi viết các mục dưới): roadmap thêm **giai đoạn 6b "Kiểm chứng dồn"** trước giai đoạn 7,
gom mọi việc dời vì máy 16 GB mà không cần dịch vụ AWS/GCP; nơi chạy là runner GitHub Actions 16 GB hay VM thuê theo giờ, chốt
bằng ADR của giai đoạn 6b. Phần đo thật vì vậy chia hai:

- **Giai đoạn 6b:** k6 tải lớn nhất nơi chạy chịu được (profile `cloud` thu nhỏ), ba thí nghiệm Chaos Mesh (mục 7), Velero với
  đích MinIO trong cluster (mục 6; script hôm nay từ chối context `k3d-*`, mở có điều kiện ở giai đoạn 6b), hai media-worker cùng
  transcode và RAM nghỉ (mục 9), ngưỡng p99 canary và HPA của web theo số đo (mục 3), thay MinIO cho đường local (mục 16), ngưỡng
  page của `RateLimitFallbackActive` dưới tải lab (Kết quả, "p99 Redis").
- **Giai đoạn 7:** k6 1 000 req/s bằng Job 20 pod trên EKS (mục 2), diễn tập phục hồi RDS (mục 5), Velero với S3 và snapshot EBS
  (mục 6), R2/CDN, hạn 50 ms của Redis trên ElastiCache (mục 4).

Các mục dưới giữ thiết kế đã viết cho cluster cloud; phần nào đổi cho nơi chạy của giai đoạn 6b ghi ở ADR của giai đoạn đó.

## 2. k6: image ghim, kịch bản theo SLO, ba profile, user và rate limit

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Image `grafana/k6` ghim digest trong `Makefile`** | Cùng một bản trên máy, trong CI và trong cluster cloud; không cài gì; Renovate cập nhật như `TRIVY_IMAGE` | Mỗi lượt là một `docker run`; container phải vào được mạng của stack |
| k6 Homebrew có sẵn trên máy | Không cấu hình | Không ghim; CI và cluster chạy bản khác |
| `go install go.k6.io/k6` trong `make tools` | Ghim version | Build k6 kéo vài trăm module bằng Go của máy ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) §3); cluster cloud vẫn cần image |
| k6 Cloud (Grafana Cloud) | Tải từ nhiều vùng, dashboard sẵn | SaaS: kết quả, có khi cả token của kịch bản ra ngoài; tính tiền theo VUh; tải từ internet đo cả đường mạng tới cluster |
| k6-operator (CRD `TestRun`) | Chia tải nhiều pod, khởi động đồng bộ | Thêm operator và CRD; một Job Indexed chia execution segment đủ cho 1 000 req/s |
| Chạy tải cloud từ laptop | Không cần Job | 1 000 req/s qua mạng nhà đo đường mạng nhà, không đo hệ thống |

### Quyết định

- **`K6_IMAGE := grafana/k6:2.3.0@sha256:9c2dee7f…5aeb34`** với dòng `# renovate: datasource=docker depName=grafana/k6`, cạnh
  `TRIVY_IMAGE`. Chọn v2.3.0 thay v1.8.2: nhánh v1 chỉ còn nhận bản vá bảo mật, và không thay đổi phá vỡ nào của v2 chạm tính
  năng kịch bản dùng (mục Kiểm chứng). Theo v2: không dùng `k6/experimental/redis` (đã bỏ; xoá khoá rate limit là việc của
  target, không của kịch bản), `http.get(url, params)` đúng hai tham số.
- **Kịch bản** ở `deploy/k6/`: module `api` (feed khám phá và following, like, lượt xem, `POST /videos` khởi tạo upload, đúng
  route của SLO) và `web` (SSR `/` đã đăng nhập, `/v/{id}` khách, `/login`), chạy chung một tiến trình qua `deploy/k6/main.js`.
  Profile chọn bằng `SVP_K6_PROFILE`. Mỗi request mang tag `route` là template (không phải URL có id), trùng nhãn `http_route`
  của gateway và nhãn `route` của RUM, nên số phía k6 và phía server ghép được theo route.
- **Phân loại response:** `http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }))`, nên `http_req_failed` chỉ
  đếm 5xx và lỗi kết nối, như SLO đếm 5xx. 429 đếm riêng vào `svp_rate_limited`: 429 do kịch bản gây ra là lỗi cỡ pool user của
  kịch bản, không phải lỗi hệ thống. Mỗi request có `check` mã mong đợi.
- **Bí mật không ra ngoài:** mật khẩu user giả sinh ngẫu nhiên mỗi lượt trong `setup()`; token, cookie chỉ nằm trong bộ nhớ của
  k6. `handleSummary` ghi một đối tượng chọn lọc (metric, threshold, profile, thời gian, điều kiện), **không** `setup_data` (đối
  tượng k6 truyền vào có nó, mục Kiểm chứng), không dùng `--summary-export` hay `--out json`. Kết quả ở
  `.k6/<profile>-<thời gian>/summary.json`; target kiểm bằng grep rằng thư mục không có token, cookie, mật khẩu.
- **Đường tới stack:**
  - Compose: container k6 vào mạng `svp_web` của compose (gateway và web cùng mạng đó), gọi `http://gateway:8080` và
    `http://web:3001` với header `Host: localhost:3001` và `Origin: http://localhost:3001` cho web (Next so host của `Origin`
    với `Host`, CSRF của web so `Origin` với `APP_ORIGIN`). Gateway thấy địa chỉ của container k6, tách khỏi khoá của container
    `web`.
  - Cluster cloud: Job trong cluster, gọi Service của Envoy trong cluster (không qua load balancer công khai): đo hệ thống từ
    Envoy vào, không đo đường internet, và mỗi pod giữ IP nguồn riêng.
- **Đăng nhập web:** k6 làm như trình duyệt không JavaScript: `GET /login`, đọc mọi `input` ẩn của form bằng `k6/html`
  (`$ACTION_REF_1`, `$ACTION_1:0`, `$ACTION_1:1`, `$ACTION_KEY`, `next`), gửi lại kèm email, mật khẩu dạng
  `multipart/form-data` do kịch bản tự dựng (Next 16.4.2 bỏ qua MPA action dạng urlencoded; không tải `jslib` từ mạng) với
  `Origin` đúng `APP_ORIGIN`; response 303 đặt cookie phiên vào jar của VU. Cách Playwright của `web/lighthouse/session.ts` là dự
  phòng cho `local` nếu cách này hỏng, không dùng cho cloud (không có trình duyệt trong pod k6).

**Bảng route → lớp → khoá → giới hạn** (`ratelimit.go`, `api.go`, UP-7):

| Route (`route` của k6) | Lớp | Khoá gateway đếm | Giới hạn (Redis) | Ảnh hưởng tới kịch bản |
| --- | --- | --- | --- | --- |
| `POST /auth/register` | `register` | IP | 60/giờ, burst 20 | Chỉ ở `setup()`. Register chỉ trả `user_id`, nên mỗi user còn phải đăng nhập |
| `POST /auth/login` | `login-ip`, rồi `login-email` | IP; (IP, SHA-256 email) | 60/phút burst 30; 10/giờ burst 5 | Mỗi user đăng nhập một lần mỗi đường (API, web) |
| `GET /feed/explore`, `GET /feed/following` | `read` | `user_id` | 600/phút, burst 200 (10/s) | Tốc độ feed chia đều cho pool |
| `PUT /videos/{video_id}/like` | `write` | `user_id` | 120/phút, burst 60 (2/s) | Idempotent, lặp được |
| `POST /videos/{video_id}/views` | `write`, rồi một lượt mỗi 60 s mỗi (`user_id`, `video_id`) | `user_id`; cặp | 2/s; RL-3 | Lặp trong 60 s nhận 202 mà không tới engagement-service: muốn lượt xem chạm engagement thì mỗi user cần đủ video `READY` khác nhau |
| `POST /videos` | `upload`, rồi UP-7 ở video-service | `user_id` | 30/giờ burst 10; tối đa 3 video `UPLOADING` có form còn hạn 15 phút | UP-7 chặt hơn: 3 lần mỗi 15 phút mỗi user. k6 không tải file, nên mỗi lần tạo một video `UPLOADING` mà job dọn chuyển `FAILED` sau 1 giờ |
| Web `/` đã đăng nhập (SSR gọi `GET /feed/explore`) | `read` | `user_id` của phiên | như `read` | |
| Web `/v/[id]` khách (BFF gọi `GET /public/videos/{video_id}`) | `public` | IP gateway thấy | 120/phút, burst 60 (2/s) | Giới hạn theo IP, không theo user |
| Web form `POST /login` (Server Action gọi `POST /auth/login`) | `login-ip`, `login-email` | IP gateway thấy | như login | |
| Web `GET /login` | — | — | không gọi gateway khi chưa có phiên | |
| `POST /auth/refresh`, `/auth/logout` | `refresh` | IP | 60/phút, burst 30 | k6 không gọi: access token sống 1 giờ, dài hơn mọi lượt |

**IP gateway thấy:** compose tin 0 hop, nên đi thẳng là địa chỉ container k6, đi qua web là địa chỉ container `web` (mọi khách
qua web chung một khoá: `/v/[id]` khách tối đa ~2 req/s cho cả kịch bản). k3d tin 1 hop từ `10.42.0.0/16`: qua Envoy, và qua
Envoy rồi web (BFF chuyển nguyên `X-Forwarded-For`), khoá là IP pod k6 do Envoy ghi. Cloud: như k3d nếu giai đoạn 7 chốt 1 hop;
nếu chốt 2 hop (load balancer L7 trước Envoy) thì Job gọi thẳng Envoy chỉ có một phần tử trong `X-Forwarded-For` và gateway rơi về
địa chỉ Envoy, nên mỗi pod k6 tự ghi `X-Forwarded-For: <IP pod>` (Downward API `status.podIP`) để đóng vai load balancer, chỉ ghi
IP của chính nó.

**Cỡ pool và tốc độ theo profile:**

| | `local` (`make load-local`) | `ci` (`make load-ci`) | `cloud` (Job, giai đoạn 7) |
| --- | --- | --- | --- |
| Nơi chạy, IP | Một container, một IP | Một container trên runner | Job Indexed `parallelism` = `completions` = 20 pod, 20 IP |
| Tạo user | (a): target xoá khoá `register` trước (**LOCAL LAB ONLY**), `setup()` đăng ký 20 user (burst 20) | (a), 5 user | (c): mỗi pod đăng ký 12 user của nó (burst 20 mỗi IP), không xoá khoá nào; pool 240 |
| Đăng nhập | 20 lần qua gateway (burst 30 của IP k6); 5 user thêm qua form web (khoá của container `web`) | 5 qua gateway, 2 qua web | Mỗi pod 12 qua gateway, 2 qua web: 14 lần ≤ burst 30; mỗi cặp (IP, email) 2 lần ≤ burst 5 |
| `GET /feed/explore` + `/feed/following` | 9 + 7 req/s (0,8/s mỗi user) | 1 + 1 | 550 + 450 req/s: **1 000 req/s feed**, mục tiêu tải của NFR ([architecture](../architecture.md) §2); 4,2/s mỗi user |
| Like, lượt xem | 1 + 2 req/s (ít video `READY` nên phần lớn lượt xem dừng ở RL-3, chỉ đo route) | 0,5 + 0,5 | 50 + 100 req/s; 0,63/s mỗi user. Cần ≥ 30 video `READY` (25 lượt xem mỗi user mỗi phút) để lượt xem tới engagement-service thay vì nhận 202 ngay ở gateway (RL-3) |
| `POST /videos` | 1 lần mỗi 20 s (≤ 1 mỗi user mỗi 15 phút) | 2 lần cả lượt | 0,5 req/s: 450 lần mỗi 15 phút, 1,9 mỗi user (< 3 của UP-7) |
| Web `/`, `/v/[id]`, `GET /login` | 3 + 1 + 1 req/s | 1 + 0,5 + 0,5 | 60 + 30 + 10 req/s; `/v/[id]` 1,5/s mỗi IP (< 2 của `public`) |
| Executor, thời lượng | `ramping-arrival-rate`: 30 s lên, giữ 5 phút | `constant-arrival-rate` 60 s | `ramping-arrival-rate`: 10 phút lên, giữ ≥ 10 phút, 1 phút xuống; pod i nhận `--execution-segment` thứ i của 20 |
| Threshold | Bảng dưới, cả độ trễ | Chỉ lỗi (5xx, 429, check): runner chia sẻ | Bảng dưới, mỗi pod trên phần tải của nó |

Cách tạo user: **(a) cho compose** vì chỉ có một IP và đó là lab một người (cùng cách `make smoke` đã làm); **(c) cho cloud** vì
pool 240 user cần 12 lần burst `register` và ít nhất 15 IP cho 30 req/s `/v/[id]` khách (lớp `public` 2/s mỗi IP), mà xoá khoá trên Valkey/ElastiCache của cloud cần một pod
có credential Redis xen giữa các đợt đăng ký. Bỏ (b) (seed user thẳng vào `svp_user`): ghi vào database của user-service từ ngoài
service, gắn kịch bản vào schema bảng `users` và cách băm argon2id. **Không thêm cờ tắt rate limit vào gateway.** Cloud tổng
khoảng 1 250 req/s (feed 1 000, phần còn lại thêm trên đó): 10 000 lượt xem/giây của architecture §3.2 là bài của Kafka và
engagement-service (lab `hot-counter`), không phải của HTTP: với lớp `write` 2/s mỗi user, 10 000 lượt xem/giây cần 5 000 user.

**Bảng SLO → threshold k6** (`local`, `cloud`; `ci` chỉ giữ dòng lỗi):

| SLO (Sloth) | Mục tiêu | Route k6 | Threshold |
| --- | --- | --- | --- |
| `feed-availability` | 99,9% không 5xx | `/feed/explore`, `/feed/following` | `http_req_failed{route:/feed/explore,phase:load}`: `rate<0.001`; như vậy cho `/feed/following` |
| `feed-latency` | 99% ≤ 150 ms | như trên | `http_req_duration{route:/feed/explore,phase:load}`: `p(99)<150`; như vậy cho `/feed/following` (không có ở `ci`) |
| `upload-init-availability` | 99,9% không 5xx | `POST /videos` | `http_req_failed{route:/videos,phase:load}`: `rate<0.001` |
| `video-ready-latency` | 95% `READY` ≤ 120 s | — | Không ánh xạ: k6 không tải file; đo bằng `make measure-ready` |
| `web-availability` (mục 3) | 99,9% không 5xx | `/`, `/v/[id]`, `/login` | `http_req_failed{app:web,phase:load}`: `rate<0.001` |
| `web-inp` (mục 3) | 75% INP ≤ 200 ms | — | Không ánh xạ: INP đo trong trình duyệt (RUM), k6 HTTP không chạy JavaScript |
| Không có SLO | — | like, lượt xem | `http_req_failed`: `rate<0.001`; độ trễ chỉ báo |
| Không có SLO | — | web SSR (độ trễ) | Không threshold; p95/p99 theo route ghi lại (mục 3) |
| Kịch bản đúng cỡ | — | mọi route | `svp_rate_limited`: `count==0`; `checks{phase:load}`: `rate>0.999`; `dropped_iterations`: `count==0` (không có ở `ci`) |

Số phía k6 gồm cả mạng từ k6 tới gateway (bridge Docker ở compose, trong cluster ở cloud); Kết quả ghi cả p95/p99 phía server
(`http_server_request_duration_seconds` của gateway và web).

**`make k6-check`:** `k6 inspect --execution-requirements` cho `main.js` với từng profile, trong `K6_IMAGE`, `--network none`,
`K6_AUTO_EXTENSION_RESOLUTION=false`, `deploy/k6` mount chỉ đọc; vào job `config` của CI (mục 15).

**Job trong cluster cloud** (`deploy/k6/cloud/`, người học chạy ở giai đoạn 7): namespace `svp-load` (ngoài `svp`, không qua
Kyverno), Job Indexed 20 pod, kịch bản từ ConfigMap tạo bằng `deploy/k6`, image là đúng `K6_IMAGE` điền vào manifest lúc render
(`deploy/k6/cloud/render.sh` in manifest ra stdout; `run.sh` của người học và `make cloud-check` cùng dùng nó): một nơi ghim
image. Mỗi pod in tóm tắt của nó ra log; người học gom bằng `kubectl --context <cluster cloud> logs`. `run.sh --context <tên>`
từ chối context `k3d-*` và context rỗng.

## 3. SLO của web

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| SLI SSR lọc theo route trang | Đúng "request trang" | Histogram không có `http.route` (Next không đặt `rpcMetadata.route`): không lọc được `/rum`, `/monitoring`, `/healthz`, `/_next/static` |
| **SLI 5xx trên mọi response của server web** | Có ngay từ metric đang có; một 5xx của trang, của Server Action hay của `/rum` đều là lỗi người dùng gặp | Probe `/healthz` và asset tĩnh (gần như luôn 200) pha loãng tỷ lệ: SLI lạc quan hơn tỷ lệ lỗi thật của trang |
| SLO độ trễ SSR trên mọi response | Có ngay | Asset nhanh và `/rum` kéo phân vị xuống: con số không phải độ trễ trang |
| Span metric (`traces_spanmetrics_*`) theo tên span `GET /v/[id]` | Có route; có sẵn trên cả compose (Tempo trong LGTM) lẫn k3d (`deploy/k8s/values/tempo.yaml`, `dimensions: [service_name, operation, status_code]`) | `status_code` là trạng thái span, không phải mã HTTP (500 trả về mà không ném lỗi có thể là `UNSET`); đi theo tỷ lệ lấy mẫu trace; Tempo của LGTM nướng cấu hình trong image nên compose không thêm được dimension mã HTTP |
| Histogram server của web: nạp OTel trước Next (`node --import <preload>` trong `CMD` của image) | Instrumentation http vá `http` trước mọi `require` | Standalone chỉ chép `@opentelemetry/api` vào `node_modules` (Next gộp SDK vào chunk server): cần `serverExternalPackages` và một file preload ngoài bundle, cấu hình SDK ở hai nơi, `CMD` của image đổi |
| Histogram server của web: connector `spanmetrics` của Collector trên span server của web | Có route template | Mã HTTP vẫn lấy từ span; Collector đã sát 256 MiB (RSS) ở lượt k6 đầu, phải nâng limit, `GOMEMLIMIT`, `memory_limiter` ở cả compose lẫn k3d |
| **Histogram server của web: nạp lại `http` qua hook của instrumentation ngay sau `sdk.start()`** | Một dòng trong `startSdk` (`web/server/telemetry/otel.ts`): module được vá tại chỗ, server Next đã tạo tra `Server.prototype.emit` đã vá ở mỗi request; giữ propagation inject-only và sampler; không đổi image, Collector | Thêm một span server mỗi request (cha của span Next); dựa vào việc `require-in-the-middle` bọc cả `process.getBuiltinModule` (8.0.1), giữ bằng test `web/server/telemetry/http-server.test.ts` |
| SLO INP với cảnh báo page của Sloth | Như các SLO khác | Ngân sách lỗi 25% làm burn 14,4× và 6× không bao giờ chạm (14,4 × 25% > 100%) |
| **SLO INP chỉ cảnh báo ticket** | Burn 3× (75% lượt chậm trong 1 ngày) và 1× chạm được | Không gọi ai dậy; RUM ít lượt ở lab nên cảnh báo cũng không đáng tin |

### Quyết định

- **`web-availability`, mục tiêu 99,9%**: error = `sum(rate(http_server_request_duration_seconds_count{service_name="web",http_response_status_code=~"5.."}[{{.window}}])) or vector(0)`,
  total = `sum(rate(http_server_request_duration_seconds_count{service_name="web"}[{{.window}}]))`. Cảnh báo
  `WebAvailabilityBudgetBurn` page và ticket như các SLO cũ, có runbook.
- **Histogram của SLI** là `http.server.request.duration` của instrumentation http. Lựa chọn này đổi sau khi đo: lượt k6 đầu
  (2026-10-24) cho thấy web không có histogram này, vì `http` đã nạp trước khi instrumentation đăng ký hook (mục Kiểm chứng, dòng
  "Vì sao web không có histogram server"). Chọn nạp lại `http` qua hook ngay sau `sdk.start()` thay vì preload hay `spanmetrics`:
  một dòng code, mã HTTP thật, không đổi image hay Collector. Tên metric và nhãn đúng như truy vấn ở trên, nên spec SLO, rule test
  và runbook không đổi. Span metrics của Tempo vẫn là nguồn số độ trễ theo route để ghi lại (mục Kết quả), không làm SLI.
- **Không có SLO độ trễ SSR** tới khi histogram có nhãn route. Xem lại khi: instrumentation-http hay Next đặt `http.route` cho
  metric, hoặc web tự ghi histogram theo template route.
- **`web-inp`, mục tiêu 75%**: error = `sum(rate(svp_web_vital_inp_seconds_count{service_name="web"}[{{.window}}])) - sum(rate(svp_web_vital_inp_seconds_bucket{service_name="web",le="0.2"}[{{.window}}]))`,
  total = `sum(rate(svp_web_vital_inp_seconds_count{service_name="web"}[{{.window}}]))` (bucket 0,2 có sẵn ở
  `web/server/telemetry/vitals.ts`). `page_alert.disable: true`, ticket `WebINPBudgetBurn`. Không lượt RUM nào thì total không
  có series, không ra tỷ lệ giả (quy tắc đầu spec).
- Ngưỡng p99 canary của web (`canaryLimits.p99Ms: 500`) và HPA web giữ nguyên; p95/p99 SSR của lượt k6 local chỉ ghi lại, quyết
  lại ở giai đoạn 6b theo số k6 tải lớn (mục 1); phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, mục 8, D14).

## 4. Hạn 50 ms của lệnh Redis

Lượt k6 local chạy trên `make up OBS=lgtm` để có Prometheus. Trong cửa sổ giữ tải đọc:

- p99 lệnh Redis theo service: `histogram_quantile(0.99, sum by (le, service_name) (rate(db_client_connections_use_time_milliseconds_bucket{db_system="redis",type="command"}[1m])))`
  cho gateway (rate limit, db 10) và feed-service (cache khám phá, db 14).
- Số lệnh quá hạn: `increase(db_client_connections_use_time_milliseconds_count{db_system="redis",error_type="context_timeout"}[<cửa sổ>])`,
  đối chiếu với số dòng `explore page loaded from database` có `cache=timeout` và dòng WARN `read explore cache` trong Loki (WARN
  tối đa một dòng mỗi phút, nên chỉ cho biết có hay không).

**Quy tắc:** p99 local < 25 ms và không lệnh nào quá hạn → giữ 50 ms. Ngược lại ghi số và quyết lại ở giai đoạn 7 trên
ElastiCache. Không đổi code ở giai đoạn này. Bucket mặc định của histogram (0, 5, 10, 25, 50, … ms) đủ để phân biệt dưới 25 ms
và quá 50 ms.

## 5. Backup/restore Postgres: CloudNativePG + plugin Barman Cloud, diễn tập DR tại chỗ trên k3d

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| `pg_dump` trên compose | Nhẹ, không cần k3d | Compose dùng Postgres native chung với dự án khác: bật `archive_mode` phải đổi cấu hình và restart server đó (không được phép); dump logic không phải cách RDS/Cloud SQL phục hồi (bản sao vật lý + WAL, PITR, ra instance mới), nên RTO không chuyển sang cloud |
| `barmanObjectStore` có sẵn trong CloudNativePG | Không thêm component | Deprecated, webhook 1.30.1 báo bỏ ở 1.31.0; cần image `system` (deprecated) vì image `minimal` đang ghim không có Barman |
| **Plugin Barman Cloud 0.8.1 (v0.15.1)** | Đường thay chính thức; Barman nằm ở sidecar nên giữ image `minimal`; WAL liên tục, PITR | Thêm component, cert-manager, một sidecar trong pod Postgres; RBAC của plugin rộng (bên dưới) |
| Plugin Barman Cloud chạy làm sidecar của pod operator, nối qua socket ở `PLUGIN_SOCKET_DIR` (CloudNativePG 1.30.1 nạp plugin từ đó: `internal/configuration/configuration.go` dòng 93–95, `internal/cmd/manager/controller/controller.go` dòng 270–275) | Không cần Service của plugin ở namespace operator, nên operator không phải watch `cnpg-system` | Sidecar chạy bằng ServiceAccount của operator: operator phải mang thêm quyền Secret toàn cluster của plugin (manager của plugin cache mọi Secret, bên dưới), tức token operator bị lấy là lộ mọi Secret, đúng thứ ADR-0014 §12 đã thu hẹp |
| Velero snapshot PVC của `svp-pg` | Một công cụ cho mọi PV | Snapshot crash-consistent, không có WAL nên không PITR; k3d `local-path` không có CSI snapshot |
| Diễn tập ra Cluster mới tên khác | Không đụng Cluster đang chạy | RTO không gồm lúc service nối lại; Service, Secret của service phải trỏ tên mới |

### Quyết định

**Plugin Barman Cloud, đích là MinIO trong cluster, diễn tập DR tại chỗ trên cluster dev.** (**Bị thay một phần bởi
[0022](0022-local-object-store-minio-replacement.md)**, 2026-10-25: đích là object store RustFS `s3` trong cluster, Job `s3-init` tạo bucket và user; ObjectStore chỉ
đổi `endpointURL`; phần dưới giữ nguyên như lúc quyết.)

- **Component** `plugin-barman-cloud` (wave 3, sau `cloudnative-pg` wave 2 và cert-manager wave 0, trước `svp-data` wave 4) trong
  `components.json`, cả đường dev và GitOps. Values: image plugin và sidecar ghim `tag: v0.15.1@sha256:…` (mục Kiểm chứng),
  `replicaCount: 1`, resources (requests 20m/64Mi, limit bộ nhớ 256Mi: cache của manager giữ mọi Secret của cluster). Chart đạt
  PSA `restricted` sẵn.
- **RBAC của plugin: giữ ClusterRole của chart.** Manager của plugin dựng cache cho cả cluster và không có cờ giới hạn namespace,
  nên Role theo namespace như cách đã làm với CloudNativePG (`svp-cluster/templates/cnpg-rbac.yaml`) sẽ làm informer lỗi quyền.
  Cái giá: ServiceAccount của plugin đọc được mọi Secret của cluster (cả khoá ký JWT ở `svp`): ghi ở threat model BAK-1 và mục 6
  (chấp nhận ở lab; cloud dùng RDS, không có plugin). `drill-k8s-threats` in ngoại lệ này kèm lý do như với CloudNativePG.
- **Operator CloudNativePG watch thêm `cnpg-system`** (`WATCH_NAMESPACE=svp-data,cnpg-system` ở
  `deploy/k8s/values/cloudnative-pg.yaml`). **Sửa 2026-10-24**, phát hiện ở buổi k3d đầu: với `WATCH_NAMESPACE=svp-data` của
  ADR-0014 §12, plugin chạy (pod Running dưới PSA `restricted`, chứng chỉ Ready) nhưng `make k8s-up` dừng ở wave 4 vì Cluster
  `svp-pg` báo `Unknown plugin: 'barman-cloud.cloudnative-pg.io'`. Lý do trong mã 1.30.1 (mục Kiểm chứng): operator tìm plugin qua
  Service của plugin, Service đó phải ở namespace của operator, mà operator chỉ thấy Service qua informer của các namespace được
  watch; namespace của operator chỉ được đọc theo tên, không có informer. Plugin không đặt sang `svp-data` được (operator chỉ nhận
  Service ở namespace của mình). Đường tìm plugin còn lại là socket ở `PLUGIN_SOCKET_DIR` (plugin làm sidecar của pod operator),
  bị loại vì operator khi đó phải mang quyền Secret toàn cluster của plugin (bảng trên). Nên thêm `cnpg-system` vào danh sách watch
  là cách hẹp nhất. Tác dụng phụ: operator chạy informer cho mọi kind nó cache ở `cnpg-system` (vài object của chính nó và plugin;
  Secret của Helm release bị loại sẵn) và không reconcile gì ở đó vì không có Cluster hay resource CloudNativePG nào ở đó.
- **Quyền của operator ở `cnpg-system` thu hẹp** (sửa 2026-10-24, ADR-0014 §12). Plugin chạy ở `cnpg-system` với ServiceAccount
  đọc mọi Secret của cluster, nên Role của operator ở đó mà mang đủ `commonRules` như ở `svp-data` (tạo pod, `pods/exec`, sửa
  Deployment, tạo Secret, ServiceAccount, Role) là một đường leo quyền: token operator bị lấy exec vào pod plugin, chạy pod hay sửa
  Deployment của plugin bằng ServiceAccount của nó, hay tạo Secret kiểu `kubernetes.io/service-account-token` cho ServiceAccount đó,
  rồi đọc khoá ký JWT ở `svp`. `drill-k8s-threats` trước đó chỉ kiểm quyền trực tiếp nên không thấy đường này. Cách chặn
  (`svp-cluster/templates/cnpg-rbac.yaml`):
  - Role `svp-cloudnative-pg` ở `cnpg-system` chỉ `get/list/watch` mọi kind mà informer cần, ghi Secret (`create`, `get`, `patch`,
    `update`, không `delete`), event và Lease bầu leader; không pod, `pods/exec`, Deployment, Job, PVC, ServiceAccount, Role ghi,
    `update services`. Role ở `svp-data` giữ đủ `commonRules`.
  - Operator 1.30.1 vẫn phải tạo Secret ở `cnpg-system` (PKI của nó: `cnpg-ca-secret` kiểu `Opaque` lúc khởi động khi thiếu, cập
    nhật khi sắp hết hạn), mà RBAC không giới hạn `create` theo tên. ValidatingAdmissionPolicy `svp-cnpg-operator-secrets` (cùng
    template, `failurePolicy: Fail`, chạy trong API server, không webhook có thể chết) chỉ cho ServiceAccount của operator tạo hay
    sửa `cnpg-ca-secret` kiểu `Opaque`, và sửa `cnpg-webhook-cert` kiểu `kubernetes.io/tls`, ở `cnpg-system`: không tạo được Secret
    token cho ServiceAccount của plugin. Bỏ PKI của operator bằng `WEBHOOK_CERT_DIR` không được: khi có biến đó operator đọc file
    `apiserver.crt`/`apiserver.key`, còn chart 0.29.1 mount Secret của cert-manager với `tls.crt`/`tls.key`.
  - Còn lại khi token operator bị lấy: đọc Secret của `cnpg-system` (gồm Secret TLS của plugin) và ghi hai Secret trên; quyền ở
    `svp-data` như ADR-0014 §12. `make drill-k8s-threats` kiểm bằng `kubectl auth can-i` và tạo thử (dry run phía server) dưới tên
    operator, mỗi ca có đối chứng (mục Kiểm chứng sau).
- **Đích:** bucket riêng `pg-backups` (tạo sẵn bằng job init MinIO của cluster: Barman ≥ 3.16 không tự tạo bucket), user MinIO
  riêng `svp-pg-backup` chỉ có quyền bucket đó; secret key `SVP_PG_BACKUP_S3_SECRET_KEY` sinh bằng `make env`, vào Secret
  `svp-data/pg-backup-s3` bằng `secrets.sh`, không in. Compose không đổi.
- **Cluster `svp-pg`:** `plugins: [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true, parameters: {barmanObjectName:
  svp-pg-backup, serverName: <postgres.backup.serverName>}}]`; `archive_timeout` giữ mặc định 5 phút. Sidecar
  `instanceSidecarConfiguration.resources`: requests 50m/128Mi, limit bộ nhớ 256Mi (đo lại ở buổi k3d).
- **Backup cơ sở:** `ScheduledBackup` `svp-pg-daily` mỗi ngày 03:00 UTC, `immediate: true` (cluster vừa dựng có backup đầu ngay,
  không phải chờ lịch), `method: plugin`. ObjectStore `retentionPolicy: "7d"`. ScheduledBackup là hook Helm
  (`post-install,post-upgrade`, weight 1, sau Job init weight 0; Argo CD: PostSync), vì bucket `pg-backups` và user
  `svp-pg-backup` chỉ có sau Job `minio-init`, mà CloudNativePG không chạy lại Backup `immediate` đã lỗi. Hook có
  `before-hook-creation` nên mỗi lần nâng chart hay sync object bị xoá rồi tạo lại; vì vậy `backupOwnerReference: none`: với
  `self`, mỗi lần xoá đó garbage collector xoá theo mọi Backup do lịch tạo. Backup không thuộc object nào thì còn qua lần tạo lại
  và qua lúc diễn tập xoá Cluster; plugin xoá Backup mà retention đã bỏ khỏi bucket.
- **NetworkPolicy:** egress pod `cnpg.io/cluster: svp-pg` → MinIO 9000; ingress MinIO từ cùng nhãn đó (phủ cả pod Job phục hồi);
  Prometheus (`svp-obs`) egress → `svp-data` 9187 và ingress Postgres 9187 từ Prometheus; sidecar tới API server qua nhãn
  `svp-kube-api: allow` đã có trên pod instance (và pod Job, qua `inheritedMetadata`). Operator ↔ plugin 9090 nằm trong
  `cnpg-system`, namespace platform không chặn mặc định.
- **Thế hệ lưu trữ.** Job phục hồi từ chối lưu WAL vào `serverName` đã có WAL, và hai thế hệ chung một `serverName` trộn backup.
  Nên mỗi thế hệ một `serverName`: thế hệ đầu `svp-pg`, mỗi lần phục hồi tạo `svp-pg-<yymmddhhmmss>`; nguồn phục hồi là thế hệ
  đang chạy (thế hệ mới nhất), PITR trong một thế hệ. Giá trị nằm ở value `postgres.backup.serverName` của chart, không phải mặc
  định cứng. Cluster phục hồi dựng bằng chính chart `svp-data` (value `postgres.recovery.*` chỉ trong lệnh của diễn tập) để vẫn
  thuộc release Helm, nên bản render của lần dựng lại có `bootstrap.recovery` và `externalClusters`. **Giữ qua `make k8s-up`:**
  lần nâng chart sau không có value phục hồi, nên Helm 3-way merge xoá `bootstrap.recovery` và `externalClusters` khỏi Cluster
  (ngoài lúc phục hồi chart không render `bootstrap`, nên Helm bỏ cả field và mặc định `initdb` của CloudNativePG điền vào) và
  trả `plugins[].parameters.serverName` về giá trị mặc định của chart. Phần đầu vô hại khi Cluster đã phục hồi xong:
  CloudNativePG chỉ đọc `bootstrap` khi tạo primary đầu, webhook không khoá field này (mục Kiểm chứng); khi Cluster còn đang
  phục hồi (`bootstrap.recovery` có mà chưa Ready) thì không, nên `install.sh` dừng trước khi nâng chart.
  Phần sau thì không vô hại (WAL sẽ lưu về thế hệ cũ, không rỗng), nên `install.sh` đọc `serverName` từ Cluster `svp-pg` đang chạy
  (nếu có) và truyền `--set postgres.backup.serverName=…`, như đường dev vốn chỉ `--set`, không ghi file. **Đường GitOps:** Argo
  CD tự sửa về giá trị trong git, nên diễn tập này **chỉ cho đường dev**.
- **Diễn tập DR tại chỗ** `make drill-k8s-backup` (chỉ context `k3d-svp`; **LOCAL LAB ONLY**):
  1. Tạo database `svp_drill`, bảng `markers(id, written_at)`; không đụng bảng của service.
  2. `Backup` theo yêu cầu (`method: plugin`) của thế hệ đang chạy, chờ `completed`; WAL đang lưu liên tục
     (`ContinuousArchiving` True). Thiếu một trong hai thì dừng trước khi xoá gì.
  3. Ghi một dòng đánh dấu mỗi giây trong 60 s. `MODE=latest`: **không** ép `pg_switch_wal`; `MODE=pitr`: chọn một thời điểm
     mục tiêu ở giữa, ép `pg_switch_wal()` và chờ segment đó lưu xong. Ghi `pg_stat_archiver.last_archived_time` ngay trước khi
     xoá.
  4. Xoá Cluster `svp-pg` và PVC của nó (mất database) theo cách thường: pod tắt êm. Lúc viết dự kiến RPO đo được gồm cả phần
     CloudNativePG lưu được lúc tắt; buổi k3d cho thấy **không**: tắt êm không lưu segment WAL đang mở (`MODE=latest` 0/60 dòng
     đánh dấu trở lại, WAL cuối lưu 66 s trước lúc xoá; mục Kết quả, "Restore RTO/RPO"). Postgres chỉ lưu segment đã đóng (đầy,
     hết `archive_timeout`, `pg_switch_wal`), nên thứ quyết định RPO là `archive_timeout` (5 phút) cộng thời gian lưu, cả khi tắt
     êm lẫn khi mất đột ngột (node, ổ hỏng): đó là cận trên theo cấu hình, không đo ở lab. Không bao giờ xoá backup.
  5. **T0:** dựng lại `svp-pg` cùng tên bằng `bootstrap.recovery` từ `externalClusters` trỏ thế hệ cũ, lưu WAL vào thế hệ mới
     (`MODE=pitr` thêm `recoveryTarget.targetTime`). Tên giữ nguyên nên Service `svp-pg-rw`, Secret của service không đổi.
  6. Khi Cluster Ready, restart một lần Deployment của 4 service có Postgres và GlitchTip (đang CrashLoopBackOff với backoff tới 5
     phút, sẽ làm RTO ngẫu nhiên), ghi rõ trong JSON.
  7. **T1:** luồng `k8s-smoke` qua. **RTO = T1 − T0.**
  8. **RPO** = thời điểm xoá − `written_at` lớn nhất còn lại; JSON ghi kèm `forced_wal_switch`, thời điểm WAL cuối đã lưu, số dòng
     đánh dấu mất. `MODE=pitr` đạt khi dòng cuối còn lại ≤ thời điểm mục tiêu và cách nó dưới 1 s.
  9. `Backup` của thế hệ mới, để thế hệ mới có điểm phục hồi ngay.
  
  Hai lượt liền trên cùng cluster (`latest` rồi `pitr`) đều PASS chứng minh thế hệ lưu trữ. Dừng giữa chừng thì script in trạng
  thái và lệnh tay để hoàn tất phục hồi. JSON ở `.k8s/drills/`.
- **Theo dõi:** PodMonitor `svp-pg` (khắc phục "không có `cnpg_*`" của giai đoạn 4). Hai cảnh báo ở nhóm `postgres-backup` của
  `svp-alerts.yaml` (compose không có series `cnpg_*`, `barman_cloud_*`, nên không bao giờ cháy ở đó), có ca `promtool test rules`
  và runbook:
  - `PostgresWALArchivingFailing` (page): `cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time`
    trong 5 phút. Lần lưu gần nhất lỗi; dựa vào thời điểm chứ không vào "lâu chưa lưu", vì lab nhàn rỗi không có WAL mới. Page vì
    WAL không lưu được thì dồn trong PVC tới đầy ổ và Postgres dừng.
  - `PostgresBackupTooOld` (ticket): `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` > 0 và cũ hơn 26 giờ (lịch
    ngày + 2 giờ); hay bằng 0 liên tục 1 giờ (cluster mới có `immediate` thì backup đầu xong trong vài phút, nên 0 lâu là lỗi). Có
    ca test cluster mới chưa có backup đầu không cháy.
- **Cái giá:** backup nằm cùng cluster, cùng ổ với dữ liệu (cùng miền lỗi, chỉ đúng cho lab); MinIO lab không có KMS nên backup
  không mã hoá lúc nghỉ. Cloud dùng RDS automated backup + PITR; diễn tập phục hồi RDS ra instance mới (lệnh người học chạy) đo lại
  RTO ở giai đoạn 7. RAM dự kiến thêm ~0,2–0,3 GiB (plugin, sidecar), đo ở buổi k3d.

## 6. Velero (chỉ cluster cloud)

Ở giai đoạn 7 dữ liệu nằm ở dịch vụ managed (RDS, ElastiCache, S3) có backup riêng, và trạng thái cluster nằm trong git (Argo
CD). Thứ Velero còn bảo vệ: **PV trong cluster**, trước hết của Redpanda nếu giai đoạn 7 còn chạy Redpanda trong cluster (topic,
offset của consumer group); và việc dựng lại một namespace bị xoá nhầm kèm dữ liệu PV, đo được RTO. Secret không cần ở backup:
External Secrets tạo lại từ Secrets Manager, cert-manager cấp lại chứng chỉ, Application của Argo CD nằm trong git. Secret nào
không tạo lại được từ nguồn là lỗi thiết kế cần sửa ở giai đoạn 7, không phải thứ để Velero giữ.

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Không Velero, chỉ GitOps + dịch vụ managed | Ít thành phần | PV trong cluster mất; không có RTO của namespace |
| **Velero + CSI snapshot của EBS, không data mover** | Không node-agent: không pod root, không hostPath, namespace không cần PSA `privileged`; snapshot do EBS giữ | Snapshot nằm ở EBS cùng region, không mang sang cluster hay region khác; cần snapshot-controller và VolumeSnapshotClass |
| Velero + CSI data mover (Kopia lên S3) | Backup độc lập EBS, mang đi được | Cần node-agent; pod data mover chạy root (PSA `baseline`); mật khẩu repo Kopia mặc định `static-passw0rd` phải đổi; upload hết hạn token IRSA sau khoảng 1 giờ (issue #8173 còn mở) |
| Velero file-system backup (node-agent) | Không cần CSI | hostPath `/var/lib/kubelet/pods`, root, PSA `privileged`; chép file trong lúc pod đang ghi |
| Giữ Secret trong backup | Restore không phụ thuộc External Secrets | Bucket backup chứa mọi credential của namespace |

### Quyết định

- **Chart `velero` 12.2.1** (`https://vmware-tanzu.github.io/helm-charts`), image ghim
  `velero/velero:v1.18.4@sha256:c89fb5b6d1fd6afd368e0f483e6f5555fd62851a1eada8ac5c72482e674ca17b` (1.18.3–1.18.4 sửa hàng chờ
  backup bị kẹt; CRD `restores` đổi so với 1.18.2 nên giữ `upgradeCRDs: true`, CRD lấy từ image), plugin
  `velero/velero-plugin-for-aws:v1.14.4@sha256:c85a7fa803569e3128c33e4f5766f84ab156c8d171c9f1dd2715581d45ce98fa`. Namespace
  `velero`, `deployNodeAgent: false`, `configuration.features: EnableCSI`, `snapshotsEnabled: false` (không VolumeSnapshotLocation
  EBS gốc), `defaultSnapshotMoveData: false`. securityContext của pod server đặt đủ cho PSA `restricted` (non-root, drop ALL,
  seccomp RuntimeDefault).
- **Volume:** VolumeSnapshotClass của EBS CSI có nhãn `velero.io/csi-volumesnapshot-class: "true"`, `deletionPolicy: Retain`
  (snapshot còn khi namespace mất).
- **Credential:** EKS Pod Identity cho ServiceAccount `velero/velero-server` (`credentials.useSecret: false`), quyền IAM chỉ bucket
  backup và các lệnh snapshot EBS; plugin AWS dùng chuỗi credential mặc định của SDK nên Pod Identity và IRSA đều chạy được (tài
  liệu chỉ nói IAM user, issue Pod Identity #7421 còn mở: dự phòng IRSA). BackupStorageLocation: bucket S3 riêng của Terraform
  giai đoạn 7, chặn public, `kmsKeyId` (SSE-KMS).
- **Backup:** `Schedule` `svp-daily` 03:00 UTC, `ttl: 72h`, namespace có Redpanda (`svp-data` theo tên hiện nay),
  `excludedResources: [secrets]`. Không có Secret nào trong bucket (BAK-2).
- **RBAC:** chart mặc định bind `cluster-admin`; restore cần quyền tạo mọi kind được phục hồi. Chấp nhận trong buổi cloud: Velero
  cài và gỡ trong cùng buổi.
- **Lệnh** (người học chạy, context của cluster cloud ghi trong lệnh): `helm --kube-context <ctx> upgrade --install velero
  vmware-tanzu/velero --version 12.2.1 -n velero --create-namespace -f deploy/k8s/cloud/values/velero.yaml`, `kubectl --context
  <ctx> apply -f deploy/k8s/cloud/velero/`, diễn tập bên dưới; cuối buổi `helm --kube-context <ctx> uninstall velero -n velero`,
  xoá namespace và snapshot EBS do diễn tập tạo (lệnh quét ở script).
- **Diễn tập** `deploy/k8s/cloud/velero/drill-restore.sh --context <cluster cloud>` (người học chạy; từ chối `k3d-*` và context
  rỗng):
  1. Dừng upload, chờ lag mọi consumer group về 0; ghi offset đã commit của mọi group và high watermark mọi topic.
  2. Tạo `Backup` của namespace không kèm Secret (`excludedResources: [secrets]`; object từ template ở
     `deploy/k8s/cloud/velero/drill/`, như mọi Backup, Restore của diễn tập, không cần velero CLI), chờ `Completed`. Mọi volume
     phải có CSI snapshot và danh sách resource đọc từ bucket không có Secret nào (BAK-2); thiếu một điều thì dừng ở đây, trước
     khi xoá gì.
  3. Tắt auto-sync của Argo CD cho Application của namespace đó (và root), vì self-heal sẽ dựng lại StatefulSet với PVC rỗng
     trước khi Velero kịp phục hồi, mà Velero bỏ qua PVC đã có.
  4. **T0:** xoá namespace. Tạo Restore từ backup, chờ `Completed`, rồi **bật lại auto-sync ngay**: lúc đó PVC (từ snapshot) và
     StatefulSet đã có, nên self-heal không tạo volume rỗng; Secret do chart render (script lifecycle và configurator của
     Redpanda) chỉ trở lại qua Argo CD, như External Secrets và cert-manager tạo lại Secret của chúng. Chờ mọi Application
     Synced: Argo CD chỉ tạo lại các Secret đó, không lệch gì khác so với git.
  5. Mọi pod của namespace Ready, Redpanda healthy, mọi group có member ở bước 1 có member lại (service đã nối lại). Rồi, **trước
     khi có gì mới được ghi**, kiểm: offset đã commit của mọi group bằng lúc ghi ở bước 1 (không mất, không lùi), lag về 0, high
     watermark của topic DLQ không đổi. Kiểm trước smoke vì upload của smoke làm consumer commit tiến lên.
  6. **T1:** người học chạy luồng smoke qua API của cloud (một upload mới tới `READY` đúng một lần) và nhập `passed`: T1 là lúc
     `passed`. **RTO = T1 − T0** (gồm các phép kiểm của bước 5). Sau đó người học kiểm bộ đếm và dòng feed không đổi (consumer
     idempotent, phát lại nếu có không làm sai) và pod `svp` phục hồi qua được Kyverno.
- **Cái giá:** event Redpanda ghi sau lần backup cuối mất khi phục hồi (relay outbox đã đánh dấu gửi), nên RPO của event theo
  lịch backup là tới 24 giờ: Velero chỉ là phục hồi khi mất cả namespace, không phải độ bền của event. Xem lại khi giai đoạn 7 giữ
  Redpanda trong cluster: độ bền event dựa vào replication (3 broker, RF 3) hay Kafka managed, khi đó Velero còn lại PV của
  observability. Pod `svp` phục hồi vẫn phải qua Kyverno (attestation ≤ 72 giờ).

## 7. Chaos Mesh (chỉ cluster cloud)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Chaos Mesh 2.8.5, `clusterScoped: false`** | RBAC của controller là RoleBinding ở một namespace đích; thí nghiệm khai báo bằng manifest, tự hồi khi hết `duration` hay khi xoá | Mỗi lúc một namespace đích: chuyển giữa `svp` và `svp-data` bằng `helm upgrade` |
| Chaos Mesh mặc định (`clusterScoped: true`), lọc bằng `enableFilterNamespace` | Một lần cài cho mọi namespace có annotation | Controller đọc, sửa Secret ở mọi namespace; `enableFilterNamespace` cần quyền đọc namespace, mà quyền này chỉ có khi cluster-scoped |
| Litmus | Nhiều thí nghiệm có sẵn | Roadmap chọn Chaos Mesh; thêm hub, CRD |
| `kubectl delete pod`, `scale` bằng tay | Không cài gì | Không chậm mạng được; không có thời lượng tự hồi |
| AWS FIS | Managed | Chỉ mức node, AZ, API AWS; không chậm mạng giữa hai pod |

### Quyết định

- **Chart `chaos-mesh` 2.8.5** (`https://charts.chaos-mesh.org`; 2.8.6 chưa đủ 3 ngày), image `controllerManager` và `chaosDaemon`
  ghim `tag: v2.8.5@sha256:…` (mục Kiểm chứng), image pause của `pod-failure`
  `registry.k8s.io/pause:3.10.2@sha256:f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4` (đa kiến trúc; mặc định
  của chart chỉ amd64). Người học cài bằng `helm` trong buổi cloud, không qua Argo CD: chart sinh lại chứng chỉ và annotation ngẫu
  nhiên mỗi lần render nên Argo CD luôn thấy lệch.
- **Đặc quyền:** namespace `chaos-mesh` PSA `privileged` (chaos-daemon `hostPID`, privileged, hostPath socket containerd), chỉ trên
  cluster cloud, tạo và xoá trong buổi. `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath:
  /run/containerd/containerd.sock` (AMI EKS AL2023).
- **Phạm vi:** `clusterScoped: false`, `controllerManager.targetNamespace: svp` cho (a), (b), `helm upgrade --set
  controllerManager.targetNamespace=svp-data` cho (c); `replicaCount: 1`, `enableProfiling: false` (tắt pprof),
  `dashboard.create: false` (không UI, không NodePort), `dashboard.securityMode: true` (giữ webhook phân quyền của controller),
  `dnsServer.create: false`. Mọi thí nghiệm có `duration` và `selector.namespaces` (`make cloud-check` kiểm).
- **Ba thí nghiệm** (`deploy/k8s/cloud/chaos/`), chạy dưới tải k6 profile `cloud` ở mức giữ, mỗi cái sau 5 phút ổn định:
  - **(a) Kill pod** (`PodChaos`, `pod-kill`, `mode: one`, `gracePeriod: 0`), một lần cho gateway (Rollout 2 replica) rồi một lần
    cho feed-service. Giả thuyết: feed giữ SLO trong cửa sổ 10 phút quanh lần kill (5xx < 0,1%, p99 ≤ 150 ms ngoài 30 s đầu), pod
    thay Ready dưới 60 s. PDB không can thiệp (`pod-kill` xoá thẳng, không đi qua eviction): thứ giữ là ≥ 2 replica Ready lúc kill
    và `mode: one`. feed-service hôm nay `minReplicas: 1`: lúc kill chỉ có một replica thì lượt đó đo thời gian mất feed tới khi
    pod thay Ready, ghi là phát hiện về số replica tối thiểu, không tính là giả thuyết sai.
  - **(b) Chậm mạng** (`NetworkChaos`, `delay` 200 ms, jitter 20 ms, `mode: all`, `direction: to`, không `target`, `duration:
    5m`) trên pod engagement-service: mọi gói đi ra của engagement-service chậm, nên lời gọi từ gateway chậm theo. Không dùng
    `target` vì nó cần iptables/ipset (chaos-daemon ép iptables-legacy, AL2023 dùng iptables-nft); `tc netem` không cần. Giả thuyết
    theo ADR-0010 §4: feed vẫn 200 (`stats` vắng khi quá hạn 100 ms), feed 5xx < 0,1% và p99 ≤ 150 ms; like, lượt xem không 5xx (200
    ms dưới hạn 3 s); `CircuitBreakerOpen` không cháy (chậm không phải chết). p99 feed vượt 150 ms là phát hiện về ngân sách độ trễ
    của ADR-0010, ghi lại, không phải lỗi thí nghiệm.
  - **(c) Tắt Redpanda** (`PodChaos`, `pod-failure`, `mode: all`, `duration: 5m`) ở `svp-data`: Kyverno ở `svp` từ chối UPDATE đổi
    image của `pod-failure`, nên thí nghiệm này chỉ dùng được ngoài `svp`. Trong lúc tắt, 3 upload tới `READY` qua API (cùng luồng
    upload của `deploy/compose/smoke.sh`). Giả thuyết: `POST /videos` và `complete` vẫn nhận (outbox giữ event), feed giữ SLO; lượt
    xem lỗi trong lúc tắt (`RecordView` produce thẳng, [ADR-0009](0009-engagement-feed-stage2b.md)), đếm riêng; sau khi Redpanda về,
    outbox rút hết, mọi video `READY` đúng một lần, DLQ không tăng, lag về 0.
- **Lệnh** (người học chạy): tạo namespace `chaos-mesh` có nhãn `pod-security.kubernetes.io/enforce=privileged` trước, rồi `helm
  --kube-context <ctx> upgrade --install chaos-mesh chaos-mesh/chaos-mesh --version 2.8.5 -n chaos-mesh -f
  deploy/k8s/cloud/values/chaos-mesh.yaml`; mỗi thí nghiệm `kubectl --context <ctx> apply -f deploy/k8s/cloud/chaos/<file>.yaml`;
  cuối buổi `helm --kube-context <ctx> uninstall chaos-mesh -n chaos-mesh`, xoá namespace và CRD `chaos-mesh.org`.
- **Dừng sớm:** xoá object thí nghiệm (`kubectl --context <ctx> delete podchaos|networkchaos <tên> -n <ns>`) là hồi ngay; dừng khi
  feed 5xx quá 5% hơn 1 phút hay có node NotReady.
- **Không cài trên k3d** ở giai đoạn này (ADR-0017).

## 8. Kiểm tĩnh manifest cloud bằng kubeconform

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Chỉ `helm template` (như `make helm-check`) | Đã có | Không bắt field sai hay kiểu sai: template ra YAML nào cũng được |
| `kubectl apply --dry-run=server` | Đúng schema của API server, cả webhook | Cần cluster có CRD; cluster cloud chỉ có ở giai đoạn 7 |
| kubeconform + CRDs-catalog ghim commit | Không phải sinh schema | Không có Chaos Mesh; Velero sinh từ 1.17.1, lệch bản ghim |
| **kubeconform `-strict`, schema Kubernetes ở commit ghim, schema CRD sinh từ CRD của đúng bản ghim** | Bắt field sai, field thừa, kiểu sai mà không cần cluster; CRD đúng bản đang ghim | Cần mạng lúc kiểm (tải chart, file schema); schema Kubernetes theo version chọn trước, không phải EKS thật |

### Quyết định

- **`KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43…c0f64e`** với dòng `# renovate: datasource=docker
  depName=ghcr.io/yannh/kubeconform`. Image có sẵn `/openapi2jsonschema`, nên sinh schema CRD không cần Python.
- **`make cloud-check`** (`deploy/k8s/k8s.mk`), không cần cluster hay `.env`:
  1. Render: `helm template` mọi chart của `deploy/k8s/cloud/charts.json` với values của nó (`HELM_*_HOME` trong thư mục tạm như
     `make helm-check`), Job k6 bằng `deploy/k6/cloud/render.sh`, cùng manifest của `deploy/k8s/cloud/chaos/`, `velero/`.
  2. Schema CRD: CRD Chaos Mesh từ `crds/` của chart ghim, CRD Velero từ `config/crd/` của `velero-io/velero` ở tag bằng tag image
     trong `values/velero.yaml` (tự theo khi Renovate nâng image); chuyển bằng `/openapi2jsonschema` của `KUBECONFORM_IMAGE` vào
     thư mục tạm.
  3. `kubeconform -strict -summary -kubernetes-version $(CLOUD_K8S_VERSION)` với `-schema-location` thứ nhất là
     `https://raw.githubusercontent.com/yannh/kubernetes-json-schema/f7d855e49c34b039c9ef2196444910275e31e09e/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json`
     (commit ghim), thứ hai là thư mục schema CRD; không `-ignore-missing-schemas`: kind không có schema là FAIL.
  4. Kiểm thêm thứ schema không bắt: mọi thí nghiệm Chaos Mesh có `duration` và `selector.namespaces` (không rỗng, không
     `kube-system`); mọi image trong bản render ghim `@sha256:`.
- **`CLOUD_K8S_VERSION := 1.35.9`**: minor mới nhất mà CI của Chaos Mesh (1.33–1.35) và Velero 1.18 (1.33–1.35) cùng thử; giai đoạn
  7 chốt version EKS.
- Vào job `config` của CI (mục 15).

## 9. Hai media-worker cùng transcode và RAM nghỉ (chỉ cluster cloud)

Dùng lại `make drill-k8s-keda` (tối đa 2 replica, ADR-0017) và cách đo ADR-0014 §2, không thêm script. Giai đoạn 7 thêm tham số
context và host cho `deploy/k8s/drills/` (hôm nay ghim `k3d-svp`, CA local, `*.svp.localhost`).

- **Lệnh** (người học chạy): `make drill-k8s-keda N=9` với context của cluster cloud. **Điều kiện:** media-worker trên node pool
  riêng (taint và toleration), service ở node pool khác, như ghi nhận giai đoạn 4 (transcode làm bão hoà CPU của node chung); một
  lượt chung node để so là tuỳ chọn.
- **Đạt:** KEDA lên 2 replica, có cửa sổ cả 2 worker cùng transcode, mỗi video `READY` đúng một lần trong hạn 15 phút của diễn tập,
  scale down một pod đang transcode êm; không node nào NotReady và API server trả lời suốt diễn tập (tương đương tiêu chí (c) của
  ADR-0017 cho control plane managed); ghi p50/p95 tới `READY` và CPU của node. Xem lại `maxReplicaCount` theo CPU của node (tối đa
  bằng số partition).
- **RAM nghỉ:** 60 s sau khi mọi pod Ready, tổng `kubectl top pod -A` theo namespace và `kubectl top node`, so với cột pod của bảng
  ngân sách ADR-0014 §2; chỉnh `resources` của web (ADR-0019 §12).

## 10. Probe của chart `svp-service`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ mặc định 1 s | Không đổi | Node bão hoà CPU thì probe quá hạn, kubelet restart pod còn sống, restart lại tốn thêm CPU |
| Nới mọi probe như nhau | Một giá trị cho mọi probe | Readiness chậm giữ pod không trả lời được trong Service lâu hơn |
| **Nới liveness và startup, readiness vừa đủ** | Liveness chỉ để bắt tiến trình treo, readiness vẫn rút nhanh pod chậm khỏi traffic | Tiến trình treo thật bị giết chậm hơn (~35 s thay vì ~30 s) |

### Quyết định

Cho cả nhánh HTTP (gateway, web) và gRPC, đặt trong template, cùng cho mọi release:

- **liveness:** `timeoutSeconds: 5`, giữ `periodSeconds: 10`, `failureThreshold: 3`;
- **readiness:** `timeoutSeconds: 2`, giữ `periodSeconds: 5`;
- **startup** (gRPC): `timeoutSeconds: 2` (bằng chu kỳ 2 s), giữ `failureThreshold: 30` (60 s).

Envoy không có health check chủ động (chỉ theo EndpointSlice), phân tích canary của Argo Rollouts đọc metric Envoy: không thứ gì
khác phụ thuộc thời hạn probe. Pod template đổi nên lần `make k8s-up` kế chạy canary của gateway và web dưới traffic diễn tập. Cô
lập CPU của media-worker bằng node pool riêng là việc của giai đoạn 7 (mục 9).

## 11. Thử lại kết nối Postgres lúc khởi động

`internal/pgpool` (`New`) và `internal/dbmigrate` (`Up`) thử lại kết nối **chỉ cho lỗi mạng**: từ chối kết nối, quá hạn dial, mất
kết nối giữa lúc bắt tay. Không thử lại lỗi xác thực (SQLSTATE `28P01`, `28000`), database không có (`3D000`), URL sai, TLS bị từ
chối, tên miền không phân giải: thử lại vô ích và che lỗi cấu hình.

- **Cửa sổ 30 s** tính từ lần thử đầu; chờ 250 ms rồi gấp đôi tới tối đa 2 s giữa hai lần; mỗi lần vẫn bị `ConnectTimeout` 5 s
  chặn. 30 s nhỏ hơn 60 s startup probe của service gRPC, nên kubelet không giết pod đang thử. Context bị huỷ (SIGTERM) thì dừng
  ngay.
- **Log:** mỗi lần thất bại một dòng WARN `database not reachable, retrying` (`attempt`, `error`; không URL, không mật khẩu); nối được
  sau ≥ 1 lần thất bại thì INFO `database connected after retries` (`attempts`, `elapsed_ms`).
- **Kiểm giả thuyết** (rule NetworkPolicy của kube-router chưa có IP pod mới) ở buổi k3d: pod mới có dòng INFO với `attempts` > 0 mà
  `restartCount` 0 thì khớp giả thuyết; `attempts` 0 thì nguyên nhân ở chỗ khác, ghi lại. Quy tắc bỏ pod restart của
  `measure-gitops` giữ nguyên.

## 12. Runbook và postmortem

- **`docs/runbooks/README.md`:** runbook là gì ở dự án, mẫu cố định: Ý nghĩa và tác động tới người dùng; Kiểm tra nhanh (5 phút,
  lệnh và truy vấn chép được cho compose và k3d); Nguyên nhân thường gặp; Giảm thiểu; Khôi phục và xác nhận; Leo thang; Liên kết
  (dashboard, ADR, diễn tập tái hiện được). Lệnh theo quy ước của `CLAUDE.md` (qua `make`, `--context k3d-svp`, cổng ghi rõ, không
  `FLUSHDB`, lệnh chạm cloud ghi là người học chạy).
- **Một runbook mỗi cảnh báo `severity=page`**, tên file là tên alert kebab-case: `kafka-consumer-lag-high.md`,
  `rate-limit-fallback-active.md`, `kafka-dlq-records.md`, `circuit-breaker-open.md`, `background-loop-stalled.md`,
  `feed-availability-budget-burn.md`, `upload-init-availability-budget-burn.md`, `feed-latency-budget-burn.md`,
  `video-ready-latency-budget-burn.md`, `web-availability-budget-burn.md`, `postgres-wal-archiving-failing.md`; thêm
  `postgres-backup-too-old.md` (ticket) và `postgres-restore.md` (các bước tay của phục hồi, mục 5).
- **Sự cố đã gặp và quy trình:** `k3s-server-down-under-transcode.md` (3 worker cùng transcode, ADR-0017),
  `liveness-timeout-cpu-saturation.md` (giai đoạn 4), `explore-cache-redis-timeout.md` (`measure-explore-cache` chập chờn),
  `github-push-run-missing.md` (GitHub mất lượt push của một merge, giai đoạn 5), `kyverno-down.md` (Kyverno chết thì pod `svp` bị
  từ chối, gỡ thì webhook tự xoá và pod không bị kiểm), `vuln-attestation-expired.md` (lịch rescan tắt, attestation quá 72 giờ),
  `jwt-key-rotation.md` (quy trình đổi khoá ký theo `kid`, SEC-4; diễn tập đổi khoá ở giai đoạn 7 cùng Secrets Manager).
- **`runbook_url`** = `https://github.com/anhnvcoder/short-video-platform/blob/main/docs/runbooks/<file>.md` trên mọi rule
  `severity=page`: `page_alert.annotations` của spec Sloth (rồi `make slo`) và `svp-alerts.yaml`. Thông báo page của Alertmanager
  có link; template Telegram mặc định không in annotation đó thì sửa template của receiver ở lượt sửa sau.
- **Postmortem không đổ lỗi:** `docs/postmortems/README.md` (Tóm tắt; Tác động có số; Dòng thời gian UTC với nguồn của từng mốc;
  Phát hiện; Nguyên nhân gốc và yếu tố góp phần; Cái làm tốt, chưa tốt, may mắn; Việc cần làm có người và hạn; Chứng cứ),
  `docs/postmortems/<yymmdd>-<slug>.md`.

## 13. Game day trên compose

### Các lựa chọn

| Sự cố tiêm | Được | Mất |
| --- | --- | --- |
| Tắt feed-service → `FeedAvailabilityBudgetBurn` | Mất trọn feed, tác động rõ | Đường cảnh báo này đã diễn tập ở `drill-alert-to-sentry`; cảnh báo burn cửa sổ 1 giờ còn cháy lâu sau khi hồi, chặn lượt sau |
| **Tắt engagement-service → `CircuitBreakerOpen`** | Runbook chưa được thử; tác động một phần (feed 200 không `stats`, like 503 nhanh theo ADR-0010) nên người trực phải đọc đúng tác động; cảnh báo hết khi breaker đóng, stack về sạch nhanh; logic tiêm có sẵn ở `drill-engagement-down` | Cảnh báo chỉ cháy khi có traffic chạm engagement: cần tải nền |

### Quyết định

Chọn tắt engagement-service. Trình tự trên `make up OBS=lgtm`, có video `READY` (`make smoke`):

- `make gameday` (`deploy/compose/drills/gameday.sh start`, chạy suốt buổi ở một terminal): kiểm stack, chạy tải nền profile `local`
  với thời gian giữ dài hơn (`SVP_K6_HOLD`, mặc định của profile 5 phút), chờ 2 phút ổn định, **T0** dừng container
  engagement-service, ghi **T1** khi `CircuitBreakerOpen` có trong Alertmanager.
- Người trực xử lý **chỉ theo runbook** `circuit-breaker-open.md` và dashboard nó chỉ tới, ghi mốc bằng `make gameday-mark
  M=diagnosed|mitigated|recovered` ở terminal khác.
- `make gameday-end` (ở bất kỳ bước nào, cả lúc chờ ổn định hay chờ cảnh báo) hay Ctrl-C: dừng tải, bật lại service nếu còn tắt,
  ghi dòng thời gian (cả lý do khi buổi dừng vì một bước kiểm lỗi) và tóm tắt k6 (lỗi theo route trong cửa sổ sự cố) ở
  `.k6/gameday-<thời gian>/`. Script luôn trả stack về như trước buổi khi thoát: đã qua T0 thì bật lại mọi service của stack;
  dừng trước T0 (cluster k3d đang chạy, một bước kiểm lỗi, kết thúc sớm) thì không bật container nào, vì buổi chưa đổi gì và
  không được dựng compose cạnh k3d. Tải nền chạy trong container tên `svp-gameday-k6`: khi thoát, script dừng và xoá container
  theo tên, và kết thúc cả tiến trình `docker run` còn đang kéo image hay tạo container (chưa có container để dừng), nên không có
  tải nào khởi động sau khi buổi đã kết thúc; còn container tên đó sót lại thì `make gameday` từ chối chạy và in lệnh xoá. Chỉ
  dừng, bật container của project; Redis chỉ các thao tác xoá có sẵn của `CLAUDE.md`.
- Postmortem viết từ mốc thật (TTD = T1 − T0, thời gian tới giảm thiểu, tới hồi phục), tác động có số từ k6 và Prometheus; chỗ
  runbook thiếu hay sai sửa sau buổi.

## 14. RFC cho người không làm kỹ thuật

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Chỉ ADR | Một loại tài liệu | ADR viết cho người làm kỹ thuật: lý do, cái giá kỹ thuật; người quyết tiền và rủi ro phải tự dịch |
| **RFC một trang mỗi giai đoạn lớn, cạnh ADR** | Người quyết đọc trong 5 phút: vấn đề, phương án, chi phí, rủi ro, đề xuất | Thêm một tài liệu phải giữ khớp với ADR |

`docs/rfc/README.md` (mục đích, khác ADR thế nào, mẫu một trang: Vấn đề; Phương án; Chi phí; Rủi ro; Đề xuất; Quyết định cần từ người
đọc) và `docs/rfc/0001-reliability.md` cho giai đoạn này. Không thuật ngữ chưa giải thích; mọi con số có nguồn (giá trên trang
chính thức kèm ngày tra và giả định) hay ghi rõ là ước lượng từ giả định nào; số về hệ thống lấy từ ADR và roadmap.

## 15. Stack chạy trong CI

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Job `stack` nằm trong `ci-ok` | Mọi PR phải qua luồng đầu-cuối | Thêm 15–25 phút mỗi PR; e2e trên runner chia sẻ chập chờn thì chặn merge |
| **Job `stack` chỉ báo, ngoài `ci-ok`** | Có kết quả đầu-cuối ở mọi PR, không chặn merge | Merge được khi `stack` đỏ; người đọc PR phải tự nhìn |
| Workflow thứ ba hay chạy theo lịch | Tách khỏi `ci.yml` | Thêm workflow ngoài hai workflow của ADR-0015 §1; theo lịch thì lỗi đến muộn, không gắn PR |

### Quyết định

- **Job `stack` trong `ci.yml`** (người học chốt 2026-10-24: không vào `ci-ok`), `ubuntu-24.04`, `permissions: contents: read`,
  không secret, mọi action ghim SHA như các job khác.
- **Postgres, Redis** là service container (cùng image ghim của job `check`), publish trên `127.0.0.1` (lệnh `psql` của
  `deploy/postgres/bootstrap.sh` trên runner) **và** trên IP bridge `docker0` `172.17.0.1` (nơi `host.docker.internal:host-gateway`
  của container compose tới), không trên mọi interface; một bước kiểm gateway của network `bridge` đúng `172.17.0.1` trước khi
  dựng. Khác job `check`, nơi test chỉ cần loopback.
- **Bước:** gói apt của Ubuntu (`postgresql-client`, `redis-tools`, `ffmpeg`, `jq`; không action bên thứ ba), `make env` (`.env` dùng
  một lần, không in, không upload), `make up`, `make smoke`, `make web-install` + `pnpm exec playwright install --with-deps chromium
  webkit`, `make web-e2e`, `make load-ci` (k6 chỉ threshold lỗi, không độ trễ vì runner chia sẻ), `make web-lighthouse` chỉ báo
  (bước không làm job đỏ), `make down` ở bước `if: always()`.
- **Artifact** (repo công khai, ai cũng tải): chỉ báo cáo Lighthouse đã lọc cookie (`web/lighthouse/run.sh`) tên `lighthouse` và tóm
  tắt JSON của k6 tên `k6-summary`. Không trace, video, HAR, báo cáo HTML của Playwright hay log có cookie, token.
- `make k6-check` và `make cloud-check` vào job `config` (thuộc `ci-ok`).
- **Xem lại khi:** 20 lượt `stack` liên tiếp xanh, không lượt đỏ do môi trường → đưa vào `ci-ok`.
- Mọi thứ của mục này **kiểm sau push**.

## 16. Việc tồn

- **LCP mobile** `/` và `/v/{id}` (ADR-0018 Kết quả phần B): làm ở giai đoạn này, ngưỡng 2 500 ms, median 3 lượt
  `make web-lighthouse` mỗi trang, giảm byte cần trước LCP (poster nhỏ hơn, poster video kế tải sau LCP, bớt font tải sớm,
  `preconnect` tới origin media nếu CSP cho phép, không nới CSP); CLS < 0,1 và TBT < 200 ms giữ đạt.
- **`emailPattern`** của `web/server/sentry/scrub.ts` (bậc hai trong mỗi đoạn): sửa ở giai đoạn này cho tuyến tính, không để lọt email
  nào bản cũ che (WEB-9).
- **Thay MinIO: dời giai đoạn 7.** Trên cloud object store là S3/R2/GCS, MinIO chỉ còn ở lab loopback; bộ kiểm tương thích của bản thay
  (presigned POST có policy UP-1…UP-7, CORS, policy theo user) trùng việc kiểm R2 của giai đoạn 7: làm một lần. **Sửa 2026-10-24:**
  thay MinIO cho đường local làm ở giai đoạn 6b, bằng ADR riêng (mục 1); kiểm R2 vẫn ở giai đoạn 7. ADR riêng đó là
  [ADR-0022](0022-local-object-store-minio-replacement.md) (RustFS), hiện thực ở phần 2 của giai đoạn 6b (**bị thay một phần bởi
  0022**, 2026-10-25: đã hiện thực, kết quả ở mục Kết quả của 0022).
- **Istio ambient: dời sau giai đoạn 7.** Máy 16 GB không còn RAM cho ztunnel và istiod. Đường tới Postgres đã có TLS
  (`sslmode=require`) và SCRAM, Redpanda có SASL SCRAM và ACL, NetworkPolicy chặn hai chiều; còn thiếu là mã hoá và danh tính giữa
  gateway và service gRPC (IN-3, chấp nhận tới đó). Xem lại khi cluster cloud đủ RAM, có tenant thứ hai, hay ở review bảo mật giai
  đoạn 9.
- **Mục "Xem lại khi" của ADR-0010 cần k6** (người dùng hợp lệ nhận 429, breaker mở oan, bulkhead, timeout theo method): xét bằng số
  k6 cloud ở giai đoạn 7; lượt local chỉ cho biết pool đúng cỡ không nhận 429.
- **DAST** (ADR-0015 §12): để giai đoạn 9; job `stack` là nền để chạy nó sau này.
- Quyết định cắt RAM (b) của giai đoạn 5 không thuộc ADR này.

## 17. Threat model

Thêm vào [`docs/threat-model.md`](../threat-model.md): **BAK-1** (bucket và credential backup Postgres, plugin Barman Cloud đọc mọi
Secret, đường leo quyền từ operator CloudNativePG sang ServiceAccount của plugin và cách chặn ở mục 5, cùng miền lỗi), **BAK-2** (Velero) ở mục 4.10 mới; **RL-7** (xoá khoá rate limit và pool user của k6) ở 4.4; **SC-10** (job
`stack` trên repo công khai) và **OPS-4** (Chaos Mesh) ở 4.8; hàng giai đoạn 6 của mục 5; các rủi ro chấp nhận mới ở mục 6; IN-3
theo mục 16. Dòng chỉ kiểm được sau ghi "kiểm sau" kèm tên phép kiểm.

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết: cần stack, cluster, CI hay cloud. Mỗi dòng nêu phép kiểm chứng minh nó; kết quả và ngày ghi vào cột
cuối khi đã kiểm.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| `k6 inspect` của mọi profile chạy không mạng với `K6_IMAGE` trên arm64 (máy) và amd64 (runner) | `make k6-check` trên máy; job `config` sau push | arm64: sạch (2026-10-24, lần cuối trên working tree cuối của giai đoạn); amd64: **đạt** (2026-10-24, job `config` của lượt push `main` [40098899515](https://github.com/anhnvcoder/short-video-platform/actions/runs/40098899515) ở `b993162`, [ADR-0021](0021-deferred-verification-stage6b.md) D21) |
| Container k6 trong mạng `svp_web` tới được gateway và web; form đăng nhập `multipart/form-data` có `Origin`, `Host` của `localhost:3001` được Next và CSRF nhận, cookie phiên vào jar | `make load-local` | Đạt (2026-10-24): 303 kèm cookie phiên cho cả 5 user; kịch bản lấy cookie từ response và gửi theo từng request với jar mới, không để trong jar của VU (một VU chạy nhiều phiên) |
| Pool của profile `local` và `ci` không nhận 429 | `make load-local`, `make load-ci`: `svp_rate_limited` = 0 | Đạt (2026-10-24): 0 ở cả hai lượt |
| Thư mục kết quả không có token, cookie, mật khẩu | grep của `make load-local` trên `.k6/` | Đạt (2026-10-24): grep không ra file nào |
| Histogram HTTP của web có trong Prometheus với `service_name="web"` và đúng thuộc tính mục Kiểm chứng, trên compose `OBS=lgtm` và trên k3d | `make load-local` (truy vấn qua Grafana); buổi k3d: `make k8s-up`, traffic web, truy vấn Prometheus qua port-forward loopback | Lượt đầu **không đạt** trên compose (2026-10-24): job `web` chỉ xuất `http_client_request_duration_seconds_*` (fetch của BFF tới gateway), nguyên nhân ở mục Kiểm chứng. Sau khi nạp lại `http` (mục 3), **đạt** trên compose (2026-10-24): `http_server_request_duration_seconds_{bucket,count,sum}{job="web",service_name="web"}`, nhãn `http_request_method`, `http_response_status_code`, `url_scheme`, `network_protocol_version`, không `http_route`; 2 series `_count` (GET 200, POST 303). k3d **đạt** (2026-10-24): sau `make k8s-smoke` và 6 lần `GET /login` qua Envoy, `http_server_request_duration_seconds_count{job="web",service_name="web"}` có series GET 200 |
| Recording rule của `web-availability` có series; `WebINPBudgetBurn` chỉ có rule ticket | `make load-local`; `make slo-check` | Lượt đầu **không đạt** (2026-10-24): `slo:sli_error:ratio_rate5m{sloth_slo="web-availability"}` 0 series vì total query không có series. Sau khi sửa, **đạt** trên compose (2026-10-24): `count(slo:sli_error:ratio_rate5m{sloth_slo="web-availability"})` = 1 (giá trị 0), đủ 8 cửa sổ 5m–30d; `make slo-check` sạch. k3d **đạt** (2026-10-24): `slo:sli_error:ratio_rate*{sloth_slo="web-availability"}` có series ở đủ 8 cửa sổ, giá trị 0 |
| Probe, asset tĩnh không có trace khi span server của instrumentation http là root | Test `web/server/telemetry/http-server.test.ts`; Tempo sau `make load-local` | Đạt trên compose (2026-10-24): TraceQL `span.url.path`/`span.http.target` = `/healthz` hay `/_next/static/…` 0 trace, không span server nào có `url.query`; span `GET` của instrumentation http là root, hai span `BaseServer.handleRequest` của Next là con |
| `db_client_connections_use_time_milliseconds_*` có trong Prometheus cho gateway và feed-service | `make load-local` | Đạt (2026-10-24) |
| Plugin Barman Cloud và sidecar chạy dưới PSA `restricted`, operator nhận plugin, WAL lưu liên tục, backup `immediate` `completed` | Buổi k3d: `make k8s-up`, `make k8s-status`, Backup của `svp-pg-daily` | Lượt đầu **không đạt** (2026-10-24): pod plugin Running dưới PSA `restricted`, nhưng operator không nhận plugin, `svp-pg` không có instance (mục 5, operator watch thêm `cnpg-system`). Sau khi sửa, **đạt** (2026-10-24, cluster mới): pod plugin 1/1, 0 restart ở `cnpg-system` (PSA `restricted` enforce v1.36); sidecar `plugin-barman-cloud` là init container `restartPolicy: Always` của `svp-pg-1` (requests 50m/128Mi, limit 256Mi), `pluginStatus` 0.15.1; `ContinuousArchiving` True; Backup `immediate` `svp-pg-daily-20261024091858` `completed` (09:18:58–09:23:34 UTC), không backup thứ hai |
| Operator watch `svp-data,cnpg-system` nhận plugin, không lỗi quyền, không quản gì ở `cnpg-system` | Buổi k3d chạy lại: `make k8s-up` qua wave 4 (Cluster `svp-pg` Ready); log operator có dòng `Listening for changes` với hai namespace, controller `plugin` nạp `barman-cloud.cloudnative-pg.io`, `grep -i forbidden` không ra dòng nào; `make drill-k8s-threats` vẫn chỉ thấy quyền của operator ở `cnpg-system`, `svp-data` | **Đạt** (2026-10-24): `make k8s-up` cluster mới qua mọi wave; log `"msg":"Listening for changes","watchNamespaces":["svp-data","cnpg-system"]`; controller `plugin` ghi `Registered plugin` cho Service `cnpg-system/barman-cloud` lúc 09:13:54 UTC, sau 14 dòng `Reconciler error` `Secret "barman-cloud-server-tls"`/`"barman-cloud-client-tls" not found` trong 0,4 s ngay trước (cert-manager chưa ghi xong chứng chỉ, tự hết); `grep -ci forbidden` 0, không dòng `unknown plugin`; `drill-k8s-threats` RBAC: operator get/list Secret, tạo và exec pod chỉ ở `cnpg-system`, `svp-data` (trước khi thu hẹp Role ở `cnpg-system`, dòng kế) |
| Plugin chạy với RBAC của chart không lỗi quyền; ngoại lệ RBAC của nó hiện trong diễn tập threat model kèm lý do | Buổi k3d: log plugin; `make drill-k8s-threats` | **Đạt** (2026-10-24): log plugin 0 dòng `forbidden`, 0 dòng `error`; `drill-k8s-threats` in ngoại lệ RBAC của plugin kèm lý do, mọi mục PASS, gồm BAK-1 |
| PodMonitor `svp-pg` cho Prometheus thấy `cnpg_*` và `barman_cloud_*`; hai cảnh báo backup không cháy trên cluster mới | Buổi k3d: truy vấn Prometheus qua port-forward loopback | **Đạt** (2026-10-24): 504 series `cnpg_*`, 3 series `barman_cloud_*` (job `svp-obs/svp-pg`); `PostgresWALArchivingFailing`, `PostgresBackupTooOld` `inactive`, health ok. Cluster mới lưu WAL lỗi 3 lần 09:18:22–24 UTC (MinIO `Forbidden` trên `pg-backups`: Job `minio-init` chạy 09:18:30–38 mới tạo user, policy), lưu được từ 09:18:42; cảnh báo không cháy vì lần lưu thành công tới sau 18 s, trong cửa sổ 5 phút |
| Phục hồi cùng tên với `serverName` thế hệ mới qua được kiểm archive rỗng; lượt hai trên cùng cluster PASS; PITR dừng đúng thời điểm | `make drill-k8s-backup` (`MODE=latest`, rồi `MODE=pitr`) | **Đạt** (2026-10-24): hai lượt liền trên cùng cluster PASS, thế hệ `svp-pg` → `svp-pg-261024092827` → `svp-pg-261024094017`; PITR: dòng cuối còn lại cách mục tiêu 0,5 s, không dòng nào sau mục tiêu (`pitr.ok=true`). Số ở mục Kết quả |
| `make k8s-up` sau diễn tập giữ `serverName` của thế hệ đang chạy, không đổi Cluster đã phục hồi | `make k8s-up` sau diễn tập | **Đạt** (2026-10-24): `Postgres svp-pg keeps archive generation svp-pg-261024094017`; Cluster cùng UID, pod `svp-pg-1` không bị tạo lại hay restart, 30 dòng đánh dấu của lượt PITR còn nguyên; `spec.bootstrap` thành `initdb` (CloudNativePG chỉ đọc lúc tạo instance đầu); 3 phút 5 giây |
| Role của operator ở `cnpg-system` thu hẹp (mục 5) không làm operator lỗi quyền; token operator không leo sang ServiceAccount của plugin | Buổi k3d: `make k8s-up` cluster mới, log operator, `make drill-k8s-backup MODE=pitr`, `make drill-k8s-threats` (can-i và tạo thử dưới tên operator, mỗi ca có đối chứng) | **Đạt** (2026-10-24): `cnpg-ca-secret` (`Opaque`) do operator tạo qua policy; `grep -ci forbidden` 0 cả sau diễn tập, log không có lần từ chối nào của policy; `Registered plugin` ×2; `svp-pg` healthy, `ContinuousArchiving` True, backup `immediate` completed; `drill-k8s-backup MODE=pitr` PASS (RTO 125,6 s, RPO 35,4 s, 0/17 bảng lệch); `drill-k8s-threats` 16/16 PASS: tạo pod, exec, sửa Deployment, tạo ServiceAccount, xoá Secret chỉ `yes` ở `svp-data` (`cnpg-system` `no`), `serviceaccounts/token` không ở đâu; dưới tên operator, tạo Secret token cho ServiceAccount của plugin, Secret token tên `cnpg-ca-secret`, Secret `Opaque` tên khác, và sửa (gắn nhãn) Secret TLS có sẵn `barman-cloud-client-tls` của plugin đều bị policy từ chối; đối chứng: `cnpg-ca-secret` `Opaque` → AlreadyExists (qua policy), sửa nhãn `cnpg-webhook-cert` qua, admin tạo Secret token được |
| RAM plugin và sidecar trong limit, cluster dev còn trong ngân sách ADR-0014 §2 | Buổi k3d: `docker stats` một lần, `kubectl top pod` | Chỉ để biết (2026-10-24): dưới 8,7 GiB ở mẫu này, ngân sách chưa đo, đo ở giai đoạn 6b (ADR-0014 §2 đo ngưỡng nghỉ 6,5 GiB và ngưỡng đỉnh 8,7 GiB dưới tải của nó, không phải một mẫu): `docker stats` trong lúc `drill-k8s-threats`, mẫu cao nhất server 5,24 GiB + agent 2,00 GiB ≈ 7,2 GiB; `kubectl top`: plugin 26 Mi, sidecar 21 Mi (limit 256 Mi mỗi cái), container postgres 99 Mi. Giai đoạn 6b, cluster dev trên runner ([ADR-0021](0021-deferred-verification-stage6b.md) D19): **đạt** (2026-10-25): plugin cao nhất 26 và 31 MiB, sidecar 71 và 67 MiB, dưới limit 256 Mi; cluster đạt (b) ở điểm 60 s ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)) |
| Probe mới render đúng mọi release; không pod nào restart khi `make k8s-up` | `make helm-check`; buổi k3d: `restartCount` | **Đạt** (2026-10-24): trên pod: liveness 10/5/3 (period/timeout/failure), readiness 5/2/3 ở 8 pod có probe, startup 2/2/30 ở 4 service gRPC, media-worker không probe; 0 restart ở mọi pod ngoài `kube-system` sau `make k8s-up` cluster mới và sau `make k8s-up` cuối buổi. Cluster mới không có canary, lượt cuối không đổi pod template, nên canary dưới probe mới chưa chạy (giai đoạn 6b, cùng canary web dưới traffic). Giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) D18): canary gateway dưới probe mới **đạt** hai lượt trên runner (2026-10-25): bản tốt promote sau 129,9 và 124,2 s, bản lỗi abort 88,0 và 87,3 s sau khi canary nhận traffic, 0 restart ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)); canary web: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `web-canary`) |
| Pod mới có Postgres nối được sau vài lần bị từ chối, không restart | Buổi k3d: dòng `database connected after retries`, `restartCount` 0 | **Đạt** (2026-10-24): 8/8 pod (4 Job migrate, 4 Deployment) có đúng một WARN `database not reachable, retrying` (`dial tcp <IP Service svp-pg-rw>:5432: connect: connection refused`) rồi INFO `database connected after retries` `attempts=2` sau 262–268 ms; `restartCount` 0, Job `failed=0`. Postgres đã Ready từ trước, nên khớp giả thuyết của mục 11; log không cho biết chắc rule nào từ chối |
| Sinh schema CRD bằng `/openapi2jsonschema` và kubeconform `-strict` bắt được field sai | `make cloud-check`, cộng một bản sao thí nghiệm cố ý hỏng (ngoài repo) phải FAIL | **Đạt** (2026-10-24): `make cloud-check` sạch, `Valid: 49, Invalid: 0, Errors: 0, Skipped: 0` trên 14 file; bản sao đổi `latency` thành `latancy` ở thí nghiệm (b) FAIL `missing property 'latency' - additional properties 'latancy' not allowed` (48 valid, 1 invalid). Trên amd64: **đạt** (2026-10-24, job `config` của [40098899515](https://github.com/anhnvcoder/short-video-platform/actions/runs/40098899515), `make cloud-check` trong `ci-ok`; [ADR-0021](0021-deferred-verification-stage6b.md) D21) |
| Service container publish trên `172.17.0.1` tới được từ container compose; job `stack` chạy đủ bước; artifact chỉ hai loại; token lượt PR chỉ `contents: read` | Lượt PR đầu sau push (**kiểm sau push**) | **Đạt** (2026-10-24, [ADR-0021](0021-deferred-verification-stage6b.md) D22): lượt PR [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) ở `7df7973`, ba lần chạy liền xanh (`make smoke`, `make web-e2e` 62/62, `make load-ci`, `make web-lighthouse`); quyền ở đầu log `Contents: read` (cùng `Metadata: read` GitHub luôn cấp), artifact chỉ `lighthouse`, `k6-summary`. Các lượt trước đỏ ở e2e WebKit trên Linux, đã sửa (ADR-0021, "Job `stack`") |
| `runbook_url` có trên mọi rule page; thông báo page có link | `make slo-check`; đọc template Telegram | **Đạt** (2026-10-24): đọc mọi rule `severity=page` của `svp-alerts.yaml` và `slo-generated.yaml` (15 rule: 10 viết tay gồm `PostgresWALArchivingFailing`, 5 SLO), mỗi rule có `runbook_url` đúng tiền tố và file runbook có trong repo; `make slo-check` sạch; template mặc định của receiver Telegram (Alertmanager v0.34.1) in mọi annotation nên thông báo page có link, không phải sửa template |
| `CircuitBreakerOpen` cháy dưới tải nền khi engagement-service tắt; stack về sạch sau buổi | `make gameday` | **Đạt** (2026-10-24): cảnh báo có trong Alertmanager 75 s sau T0 (mục Kết quả, "Game day"); sau buổi mọi service của stack chạy lại, tải k6 đã dừng |
| Mỗi pod k6 trên cloud là một khoá rate limit (1 hop; 2 hop với `X-Forwarded-For` tự ghi) | Giai đoạn 7 (EKS), người học: sau `setup()`, `redis-cli --scan --pattern 'svp:gw:rl:register:*'` trên ElastiCache đếm được 20 khoá | Chưa kiểm |
| 20 pod k6 giữ được tốc độ 1 250 req/s | Giai đoạn 7 (EKS): `dropped_iterations` = 0 mọi pod; giai đoạn 6b chạy bản thu nhỏ của profile `cloud` | Chưa kiểm; bản thu nhỏ: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `k6-cloud-mini`) |
| Chaos Mesh 2.8.5 và Velero 1.18.4 chạy trên version EKS chọn (CI của cả hai tới 1.35); kernel AL2023 có `sch_netem` | Giai đoạn 6b: cài, chạy ba thí nghiệm và diễn tập Velero (đích MinIO) trên cluster của nơi chạy 6b, thí nghiệm (b) trên một pod thử trước; giai đoạn 7: version EKS, kernel AL2023 | Chưa kiểm; giai đoạn 6b: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `chaos`, `velero`) |
| Plugin AWS của Velero nhận credential từ Pod Identity | Giai đoạn 7 (EKS): BackupStorageLocation `default` Available (`drill-restore.sh check`), backup Completed | Chưa kiểm |
| Restore namespace có Redpanda giữ offset đã commit, pod `svp` phục hồi qua Kyverno | `drill-restore.sh`: giai đoạn 6b (đích MinIO), giai đoạn 7 (S3, snapshot EBS) | Chưa kiểm; giai đoạn 6b: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `velero`) |
| Hai media-worker cùng transcode trên node pool riêng không làm node NotReady | Giai đoạn 6b: `make drill-k8s-keda N=9` trên node đủ CPU của nơi chạy 6b ([ADR-0017](0017-gitops-capacity-media-worker-max2.md)); node pool riêng ở giai đoạn 7 | Giai đoạn 6b, đường dev trên runner 4 vCPU ([ADR-0021](0021-deferred-verification-stage6b.md) D1, 2026-10-25): `make drill-k8s-keda N=9` PASS hai lượt có hai worker cùng transcode (137 s, khoảng 80 s), không node `NotReady`, k3s server không restart ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)); lượt thứ ba PASS nhưng không có khoảng hai worker cùng transcode (cách chia partition, [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)). Đường GitOps: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `gitops`); node pool riêng: giai đoạn 7 |

## Kết quả

### Tổng hợp theo bảng "Xong khi" (mục 1)

Phần local đóng ngày 2026-10-24. Chi tiết và số đo ở các tiểu mục dưới và ở mục Kiểm chứng sau.

| Việc | Kết quả |
| --- | --- |
| Kịch bản k6 theo SLO | Đạt: `make k6-check` sạch; lượt `make load-local` đầu qua mọi threshold (7 573 request, 5xx 0, 429 0, không rơi iteration); lượt sau khi sửa metric web rơi 3 iteration, chưa rõ nguyên nhân ("Tải local (k6)") |
| SLO web | Đạt: `web-availability`, `web-inp` trong spec Sloth, `make slo-check` sạch; recording rule có series trên compose và k3d |
| Hạn 50 ms của Redis | Quy tắc mục 4 áp xong: p99 5 ms ở lượt k6, nhưng game day thấy lệnh quá hạn, nên ghi số và quyết lại ở giai đoạn 7 ("p99 Redis") |
| Backup/restore Postgres | Đạt: `make drill-k8s-backup` `MODE=latest` rồi `MODE=pitr` PASS trên cùng cluster, RTO `latest` 151,2 s, `pitr` hai lượt 85,1 và 125,6 s (lượt thứ hai sau khi thu hẹp quyền operator), RPO ≥ 60 s và 37,3 s ("Restore RTO/RPO"); trên runner (giai đoạn 6b) thêm hai lượt mỗi chế độ |
| Probe, thử lại kết nối Postgres | Đạt: 0 restart ở mọi pod ngoài `kube-system`; 8/8 pod có Postgres nối được sau đúng một lần bị từ chối |
| Runbook, postmortem | Đạt: 15 rule page đều có `runbook_url` trỏ file có trong `docs/runbooks/`, thêm runbook sự cố và quy trình; mẫu postmortem |
| Game day | Đạt: một buổi dưới tải k6, TTD 75 s, hồi phục T0 + 184 s, postmortem từ mốc thật ("Game day") |
| RFC | Đạt: `docs/rfc/0001-reliability.md` |
| Stack trong CI | **Đạt** (2026-10-24, lượt PR [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424), ba lần chạy liền xanh; mục Kiểm chứng sau) |
| LCP | **Chưa đạt** theo số Lighthouse mô phỏng (median `/` 3 666 ms, `/v/{id}` 2 688 ms); quyết định giữ `Suspense`, xem lại ở giai đoạn 6b ("LCP"). Giai đoạn 6b trên runner: `/` vẫn **chưa đạt** sau khi bỏ `Suspense` (median 3 253 ms trước, kịch bản `compose-obs`; 3 144 ms sau, job `stack`), `/v/{id}` đạt (median 2 182 và 2 360 ms), TBT trên 200 ms; sau các sửa cuối của phần 1 (`3f0d4cc`, phần tử LCP là ảnh ở cả hai trang) `/` 2 582 và 3 055 ms, `/v/{id}` 2 917 và 3 130 ms, TBT 303–408 ms: **chưa đạt** cả hai trang, LCP quan sát 174–234 ms, đòn bẩy còn lại là việc riêng ở phần sau ("LCP", đoạn "Giai đoạn 6b") |
| Kiểm tĩnh phần cloud | Đạt: `make cloud-check` sạch (49/49 valid), ca cố ý hỏng FAIL |

Kiểm toàn repo trên working tree cuối của giai đoạn (2026-10-24, trên máy): `make check`, thêm hai lượt
`make test TESTFLAGS=-count=1` (ba lượt tính cả lượt trong `make check`, mọi gói `ok`), `make generate-check`,
`make web-generate-check`, `make helm-check`, `make slo-check`, `make otelcol-validate`, `make compose-config`,
`make renovate-check`, `make k6-check`, `make cloud-check`, `deploy/k8s/check-image-digests.sh` (40/40 image bên thứ ba ghim
digest), `deploy/ci/scan-gate.sh --check-ignorefile`: đều sạch.

### Tải local (k6)

Đo ngày 2026-10-24 trên `make up OBS=lgtm`, sau một lượt `make smoke` (explore có 50 video `READY` từ các lượt trước).

**Không kết luận năng lực.** Lượt này nhỏ (~23 req/s), chạy trên laptop, k6 và mọi service chung một VM Docker: số chỉ nói kịch
bản đúng cỡ (không 429, không rơi iteration) và cho một mốc độ trễ ở tải rất nhẹ, không nói hệ thống chịu được bao nhiêu.

- **Điều kiện máy:** MacBook Apple M2, 16 GB, 8 nhân; VM Docker Desktop 8 CPU, 9,7 GiB; cắm sạc, Low Power Mode tắt
  (`.k6/<lượt>/machine.json`); app khác đang mở: vài phiên Claude Code (~1 GB RSS tổng), Stats; không chạy k3d.
- **`make load-ci`** (profile `ci`, 60 s, 308 request): mọi threshold qua, 5xx 0, `svp_rate_limited` 0, check 323/323.
- **`make load-local`** (profile `local`, 30 s lên, giữ 5 phút, 20 user, 5 phiên web): **mọi threshold qua**; 7 573 request,
  5xx 0, `svp_rate_limited` 0 (429 = 0), `dropped_iterations` 0, check 7 624/7 624; grep `.k6/` không ra token, cookie, mật
  khẩu.

| Route (`route`) | Request | req/s | p95 k6 (ms) | p99 k6 (ms) | p95 server (ms) | p99 server (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/feed/explore` | 2 835 | 8,6 | 12,4 | 17,1 | 13,6 | 22,9 |
| `/feed/following` | 2 205 | 6,7 | 9,0 | 12,7 | 8,4 | 17,5 |
| `/videos/{video_id}/like` | 314 | 1,0 | 16,3 | 19,1 | 22,6 | 24,5 |
| `/videos/{video_id}/views` | 630 | 1,9 | 10,4 | 14,9 | 9,5 | 19,7 |
| `/videos` (POST) | 15 | 0,05 | 20,0 | 21,1 | 24,0 | 24,8 |
| web `/` (đã đăng nhập) | 945 | 2,9 | 44,7 | 53,2 | 50,3 | 61,5 |
| web `/v/[id]` (khách) | 314 | 1,0 | 48,1 | 54,6 | 51,2 | 61,4 |
| web `/login` | 315 | 1,0 | 35,6 | 39,8 | 29,1 | 31,8 |

- Số k6 tính cả lượt lên (cả lượt chạy); số server đọc trong cửa sổ giữ tải (04:10:15–04:15:08 UTC) qua datasource proxy của
  Grafana, `histogram_quantile` trên `increase(...[293s])`, nên là nội suy trong bucket (gateway: bucket 10 và 25 ms quanh
  các số này): p99 server lớn hơn p99 k6 ở vài route là do nội suy, không phải mạng âm. Gateway: `http_server_request_duration_seconds`
  theo `http_route`; mọi response đúng mã mong đợi, không 5xx (`/public/videos/{video_id}` mà web gọi: p95 8,4, p99 18,9 ms).
- **Web phía server:** ở lượt này histogram `http_server_request_duration_seconds{service_name="web"}` **không có** trên compose
  (job `web` chỉ xuất `http_client_request_duration_seconds_*`, fetch của BFF tới gateway), nên SLI `web-availability` chưa có
  series; nguyên nhân và cách sửa ở mục Kiểm chứng và mục 3, lượt sau khi sửa ở dưới. Số server của web ở bảng lấy từ span metrics của Tempo trong LGTM
  (`traces_spanmetrics_latency_bucket{service="web",span_kind="SPAN_KIND_SERVER"}`, span `GET /`, `GET /v/[id]`, `GET
  /login`); số lượt trong cửa sổ (885, 295, 295) khớp k6, tức không span nào bị bỏ. Theo mục 3, số SSR chỉ ghi lại: canary
  (`p99Ms: 500`) và HPA của web quyết ở giai đoạn 6b (phần sau, [ADR-0021](0021-deferred-verification-stage6b.md) D14).
- **Metric HTTP của server web, lượt sau khi sửa** (2026-10-24, `make up OBS=lgtm` → `make smoke` → `make load-local`,
  04:54–05:00 UTC; image web build lại có `startSdk`, mục 3): `http_server_request_duration_seconds_*{service_name="web"}` có
  series, `increase(...[6m])` của GET 200 là ~1 538 (k6 gửi 1 571 request web, cộng probe `/healthz` của compose);
  `count(slo:sli_error:ratio_rate5m{sloth_slo="web-availability"})` = **1** (giá trị 0, không 5xx), đủ 8 cửa sổ. Tempo: span
  `GET` của instrumentation http là root của mỗi request trang, không trace nào của `/healthz` hay `/_next/static/`. Lượt k6 này
  **không qua threshold** `dropped_iterations` (3 iteration rơi; 7 619/7 619 check, 5xx 0, 429 0; p95 các route web 37–52 ms):
  mẫu `docker stats` lúc 04:59:20 thấy CPU mọi container cùng vọt (lgtm 61 %, web 48 %, otelcol 15 %), không rõ nguyên nhân, không
  chạy lại (compose một lượt).
- **RAM lượt sau khi sửa** (`docker stats` mỗi ~17 s trong lượt k6): web đỉnh 211 MiB (limit 256 MiB); otelcol 255 MiB lúc vừa
  khởi động và `make smoke`, 186–243 MiB khi giữ tải, nhưng heap Go cao nhất 72 MiB
  (`max_over_time(otelcol_process_runtime_heap_alloc_bytes[10m])`), dưới `limit_mib: 192` của `memory_limiter`: log không có dòng
  "above soft limit", `otelcol_receiver_refused_*` 0. Số sát 256 MiB của `docker stats` là bộ nhớ của container (gồm page cache),
  không phải dữ liệu bị từ chối, nên không nâng limit của Collector. lgtm tăng dần tới 1,46 GiB (limit 1,5 GiB) cuối lượt: xem
  lại trước game day.
- **CPU/RAM lúc đỉnh** (`docker stats`, 5 mẫu trong lúc giữ tải, CPU tính theo một nhân): web 20 % / 201 MiB (limit 256 MiB),
  gateway 8 % / 56 MiB, feed-service 3 % / 36 MiB, user-service 3 % / 31 MiB, engagement-service 3 % / 32 MiB, video-service 1 %
  / 26 MiB, k6 2 % / 29 MiB, lgtm 10 % / 1 019 MiB (limit 1,5 GiB), **otelcol 2 % / 252 MiB (limit 256 MiB, sát trần)**,
  Redpanda 1 % / 424 MiB. RAM của web và otelcol sát limit ngay ở tải nhẹ: xem lại limit trước buổi game day dưới tải.

### p99 Redis

Cùng cửa sổ giữ tải của lượt `make load-local` ở trên, `db_client_connections_use_time_milliseconds` (`type="command"`):

| Service | Lệnh | p95 (ms) | p99 cả cửa sổ (ms) | p99 cao nhất của cửa sổ 1 phút (ms) | `context_timeout` |
| --- | ---: | ---: | ---: | ---: | ---: |
| gateway (rate limit, db 10) | 8 218 | 4,8 | 5,0 | 7,3 | 0 |
| feed-service (cache khám phá, db 14) | 3 631 | 4,8 | 5,0 | 5,0 | 0 |

- Gateway: 8 137/8 218 lệnh (99,0 %) ≤ 5 ms, 100 % ≤ 25 ms. Feed-service: 115 lệnh `status="nil"` (cache trống,
  `error_type="other"`), không lệnh lỗi khác.
- Loki trong cửa sổ: 0 dòng WARN `read explore cache`; 58 dòng `explore page loaded from database`, không dòng nào có
  `cache=timeout`.
- **Quy tắc mục 4, chỉ riêng lượt này:** p99 < 25 ms (5 ms; cao nhất 7,3 ms ở một phút) và không lệnh nào quá hạn.
- **Kết luận theo quy tắc mục 4: ghi số, quyết lại ở giai đoạn 7**, không phải giữ 50 ms. Game day dưới cùng profile k6 `local`
  (mục Kết quả, "Game day") thấy hạn 50 ms của lệnh Redis ở gateway (`services/gateway/internal/ratelimit/ratelimit.go`) bị vượt
  vài lần mỗi phút qua `host.docker.internal`, và `RateLimitFallbackActive` (page) cháy, chặn hai lượt game day trước T0: vế
  "không lệnh nào quá hạn" không giữ được qua các lượt. Không đổi code ở giai đoạn này; giai đoạn 7 đo lại trên ElastiCache bằng
  cùng truy vấn với số của k6 cloud rồi quyết hạn. Cảnh báo page giả dưới tải lab (ngưỡng của `RateLimitFallbackActive`) là việc
  của giai đoạn 6b. Kết quả giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 11, D16): rule mới (tỷ lệ quyết
  định dự phòng của từng instance ≥ 0,5 và ≥ 3 quyết định trong 2 phút, `for: 1m`; ticket `RateLimitFallbackElevated`) qua tám ca
  promtool của `make slo-check`; trên runner (`compose-obs`, hai lượt) không page dưới `make load-local`: 0 cảnh báo trong
  483–484 s, p99 lệnh Redis của gateway 4,95 ms, 0 `context_timeout`, 0 quyết định dự phòng (bằng chứng yếu: Redis tới qua bridge
  Linux, không qua `host.docker.internal`), và RL-2 vẫn page 81 và 91 s sau login đầu (hạn 240 s)
  ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687),
  [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)).

### LCP

Đo ngày 2026-10-24 trên `make up` (không `OBS`), cùng máy với lượt k6 (cắm sạc, Low Power Mode tắt, không k3d), mỗi bước
build lại image rồi chạy `make web-lighthouse` 3 lượt (Lighthouse 12.6.1, mobile mặc định: RTT 150 ms, 1,6 Mbit/s, CPU ×4).
Feed `/` đã đăng nhập, `/v/{id}` là video mới nhất của explore, cả hai lấy video của `make smoke` (clip 1280×720) làm poster
đầu. **Kết quả: chưa đạt 2 500 ms ở `/`; `/v/{id}` giảm từ 3 118 xuống 2 688 ms (median), vẫn trên ngưỡng.** CLS 0 và TBT
≤ 159 ms ở mọi lượt (ngưỡng 0,1 và 200 ms giữ đạt).

| Bước (cộng dồn) | `/` 3 lượt (ms) | `/` median | `/v/{id}` 3 lượt (ms) | `/v/{id}` median | Byte xong trước LCP thật, `/` · `/v/{id}` |
| --- | --- | ---: | --- | ---: | --- |
| Trước (code của giai đoạn 5b) | 3 733, 3 569, 3 847 | 3 733 | 3 118, 3 143, 2 417 | 3 118 | 408 kB (2 poster 106,6, font 67,5, script 205) · 347 kB |
| 1. Poster của video kế chỉ render sau sự kiện `load` | 3 792, 3 276, 3 775 | 3 775 | 2 123, 3 132, 2 823 | 2 823 | 355–365 kB (1 poster) · không đổi |
| 2. Font không `preload` (`preload: false`, vẫn `swap`) | 3 218, 3 772, 3 774 | 3 772 | 1 661, 2 962, 2 674 | 2 674 | 354–364 kB · 288–329 kB |
| 3. `preconnect` tới origin media (**bỏ lại**, xem dưới) | 2 818, 3 780, 3 780 | 3 780 | 2 669, 2 657, 2 989 | 2 669 | như bước 2 |
| 4. Thumbnail cạnh ngắn tối đa 720 px, JPEG `-q:v 5` (video mới) | 3 562, 3 666, 3 785 | **3 666** | 2 533, 2 688, 2 961 | **2 688** | 353 kB (poster 42,3) · 306–318 kB |
| Thí nghiệm, không giữ: feed `/` không bọc `Suspense` | 3 239, 2 666, 2 290 | 2 666 | 1 664, 2 968, 1 674 | 1 674 | 311–346 kB · 265–438 kB |

Bản giữ lại là bước 1, 2, 4. Byte trong bảng là các request **xong trước LCP quan sát** (không throttle) của báo cáo JSON: chỉ
những request đó vào mô hình mô phỏng của Lighthouse (Lantern), nên số mô phỏng phụ thuộc request nào kịp xong trong ~100 ms
đầu, và cùng code chênh tới ~1 300 ms giữa các lượt (`/v/{id}` 1 664–2 968 ms ở hai lượt cuối cùng code).

- **Bước 1** (`features/feed/feed-screen.tsx`): poster kế nằm trong lề lazy của Chrome nên trước đây tải cùng lúc với poster
  đầu; giờ `<img>` của nó chỉ render sau `load` của trang. `<video>` của player pool cho item kế cũng mang poster đó và vẫn chờ
  video hiện tại `canplay`, không chờ `load`: khi đoạn đầu của video hiện tại tới trước poster đầu, playlist, đoạn và poster
  của video kế vẫn tải trước LCP như trước bước này. E2e (`e2e/feed.e2e.ts`) giữ mọi poster và playlist bằng route rồi thả
  lần lượt: playlist còn giữ thì item kế không có `<video>` lẫn `<img>`, chỉ poster đầu được request; video đầu phát mà poster
  đầu còn giữ (chưa `load`) thì item kế có `<video>`, chưa có `<img>`; thả poster thì `<img>` hiện. Code cũ (`<img>` cho cả
  hai hàng xóm ngay từ HTML) trượt ở bước kiểm đầu trên Chromium và WebKit. Byte trước LCP của `/` giảm 53 kB. Không đổi
  cách nạp video kế, nên không chạy lại `make measure-web`.
- **Bước 2** (`app/styles/fonts.ts`): bốn weight đều dùng ở màn đầu của feed (nav 500/700, tên và tiêu đề 600, chữ thường
  400), nên không chọn được weight nào để preload riêng; bỏ preload cả bốn để font không giành băng thông với poster, chữ vẽ
  ngay bằng fallback đã chỉnh cỡ của `next/font`. CLS vẫn 0. Font vẫn tải trước LCP ở `/` (4 file); ở `/v/{id}` có lượt
  chỉ 3.
- **Bước 3, bỏ:** `preconnect` gọi từ server component của feed chỉ tới trình duyệt trong payload RSC (không thành `<link>`
  trong HTML), audit `uses-rel-preconnect` không ước lượng được lợi gì vì `preload` của poster đã mở kết nối; số đo bằng bước 2.
- **Bước 4** (media-worker): thumbnail lấy cỡ rendition cao nhất nhưng cạnh ngắn tối đa 720 px, chất lượng JPEG 5 thay 3; tên
  `thumbnail.jpg`, content type và contract giữ nguyên. Clip 1280×720 của smoke: 53,3 → 42,3 kB; khung 1080p (ffmpeg thử với
  `testsrc2`): 93 → 42 kB ngang, 107 → 39 kB dọc. **Video có trước thay đổi giữ thumbnail cũ**; số bước 4 đo trên video smoke
  mới, mà clip 720p đã dưới mức chặn nên chỉ JPEG 5 tác động. Trên `/v/{id}` bước 4 không đổi median rõ (nằm trong nhiễu).

  Cái giá: poster phủ cột dọc (`object-cover`), nên chiều cao ảnh quyết định độ nét; video ngang chịu nhiều nhất vì cạnh ngắn
  720 px phải phủ cả chiều cao cột. Cột đo trong Chromium: desktop 1440×900 là 450×800 CSS px, điện thoại 412×823 là 412×759,
  390×844 là 390×780 (trừ thanh dưới 64 px). Số px màn hình trên một px ảnh, trước → sau (trên 1 là phóng):

  | Nguồn: thumbnail trước → sau | Desktop ×1 | Desktop ×2 | 412 CSS px ×1,75 | 390 CSS px ×3 |
  | --- | ---: | ---: | ---: | ---: |
  | Dọc 1080×1920: 1080×1920 → 720×1280 | 0,42 → 0,63 | 0,83 → 1,25 | 0,69 → 1,04 | 1,22 → 1,83 |
  | Ngang 1920×1080: 1920×1080 → 1280×720 | 0,74 → 1,11 | 1,48 → 2,22 | 1,23 → 1,84 | 2,17 → 3,25 |
  | Khung đầu của video (rendition 360p), dọc · ngang | 1,25 · 2,22 | 2,5 · 4,44 | 2,08 · 3,69 | 3,66 · 6,5 |

  Video ngang trên điện thoại ×1,75 và desktop ×2 giờ bị phóng ~1,8–2,2 lần (trước 1,2–1,5), mềm thấy được trong lúc chờ khung
  đầu; video dọc phóng tới 1,25 lần, trừ điện thoại ×3 (1,83). Khung đầu thay poster lấy từ rendition thấp nhất (hls.js
  `startLevel: 0`, `features/feed/player-pool.ts`) và mềm hơn poster ở mọi ô, nên poster không phải lúc mờ nhất. Giữ 1920×1080
  cho video ngang (chặn theo chiều cao thay cạnh ngắn) tốn 74,3 kB thay 40,8 kB ở JPEG 5 (`testsrc2`), +33 kB trên phần tử LCP
  (~170 ms ở 1,6 Mbit/s), nên không giữ.
- **Vì sao `/` còn trượt:** ở 9/12 lượt `/` của bước 1–4, LCP quan sát là 406–521 ms thay vì 98–190 ms. Feed stream sau
  skeleton (`Suspense` của `features/feed/feed-route.tsx`, để chuyển tab hiện ngay); React 19.2 gom các lần hiện boundary
  stream từ server, hiện boundary muộn nhất ~300 ms sau lần vẽ trước. Lantern tính mọi request và CPU xong trước LCP quan sát,
  nên cả ~205 kB script và hydrate (×4) vào số LCP mô phỏng (Render Delay 2,6–3,0 s). Thí nghiệm bỏ `Suspense`: LCP quan sát
  118–175 ms, median `/` 2 666 ms (một lượt 2 290 ms đạt). Việc này ảnh hưởng cả LCP thật (~+300 ms trên mạng thật).
- **Byte còn lại trước LCP** (bản giữ): `/` ~353 kB = script ~209 kB (ngân sách tải lần đầu của feed 330 kB không đổi),
  font 67,5 kB, poster 42,3 kB, CSS 10,2 kB, HTML 17,9 kB; `/v/{id}` ~306–318 kB = script 191–203 kB, font 50,5 kB, poster
  42,3 kB.
- **Quyết định (2026-10-24): giữ `Suspense` của feed**, vì stream sau skeleton là cách Next khuyên cho dữ liệu chậm; bỏ nó thì
  chuyển tab mất skeleton hiện ngay và TTFB phải chờ dữ liệu feed. Ở giai đoạn này không làm cách nào trong ba cách đã xét:
  (a) render trang đầu của `/` không qua `Suspense` mà vẫn có skeleton khi chuyển tab (ví dụ bằng trạng thái chờ của link
  tab), lever lớn nhất đã đo (~1 s ở `/`); (b) bớt weight font (ví dụ bỏ 500, chữ `font-medium` về 400): −17 kB mỗi weight,
  đổi thiết kế, có thể đủ cho `/v/{id}` (cách ngưỡng ~190 ms median, có lượt dưới 1 700 ms); (c) tách script không cần cho màn
  đầu, dưới ngân sách hiện có. Dòng LCP của bảng "Xong khi" (mục 1) vì vậy chưa đạt theo số Lighthouse mô phỏng, lý do ở trên:
  Lantern tính cả script và hydrate khi React gom các lần hiện boundary stream (~300 ms). Số thực địa là RUM: LCP p75 0,31 s
  trên k3d ([ADR-0019](0019-web-k3d-supply-chain-observability.md), mục Kết quả). **Xem lại** ở giai đoạn 6b, khi Lighthouse
  chạy trên runner CI.

**Giai đoạn 6b** (runner `ubuntu-24.04`, Lighthouse mô phỏng như trên; [ADR-0021](0021-deferred-verification-stage6b.md) D17):

- **Bản giữ `Suspense`**, kịch bản `compose-obs` lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276), 3 lượt mỗi trang): `/` 3 510, 3 253, 2 760 ms,
  median **3 253 ms** (chưa đạt); `/v/{id}` 2 256, 1 952, 2 182 ms, median **2 182 ms** (đạt); TBT 334–417 ms ở cả sáu lượt;
  `benchmarkIndex` 1 942–2 040. Job `stack` của cùng bản (một lượt mỗi trang mỗi lần chạy, [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) ba lần chạy và
  [40151451875](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151451875)): `/` 2 833–3 793 ms, Render Delay 1 714–3 153 ms chiếm phần lớn; long task của hls.js trên `/` là 7 task
  58–126 ms, đúng 7 segment đã tải, vì bản ESM `hls.light.mjs` không có worker nhúng nên transmux chạy trên main thread.
- **Thay đổi** (theo D17 của ADR-0021, đòn bẩy (a) ở trên thành việc code): trang đầu của feed nằm trong HTML, `features/feed/feed-route.tsx`
  bỏ `Suspense`; chuyển tab gọi `router.push` trong transition, tab mới hiện được chọn và skeleton phủ lên feed cũ trong lúc
  chờ (giữ được "skeleton hiện ngay khi chuyển tab" mà quyết định ở trên muốn giữ); hls.js transmux trong worker (`workerPath` tới
  `hls.worker.js`, `features/feed/player-pool.ts`). Cái giá đã nêu: lần tải đầu `/` chờ trang đầu trước byte HTML đầu (TTFB thêm
  thời gian gọi gateway, tối đa 4 s khi gateway treo).
- **Sau thay đổi**, job `stack` ở `db35f86` ([40160528767](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160528767), ba lần chạy, một lượt mỗi trang mỗi lần): `/` LCP 3 144,
  2 674, 3 152 ms, median **3 144 ms** (chưa đạt), TBT 224, 322, 216 ms (median 224, chưa đạt); `/v/{id}` LCP 2 360, 2 358,
  3 908 ms, median **2 360 ms** (đạt), TBT 195, 220, 236 ms (median 220, chưa đạt); CLS ≤ 0,05; `benchmarkIndex` 2 290–3 640. Pha
  LCP của lần chạy thứ ba: `/` TTFB 454, Load Delay 1 148, Load 255, Render Delay 1 292 ms; `/v/{id}` 453, 337, 147, 2 969 ms. e2e
  29/29 mỗi trình duyệt ở cả ba lần chạy. Median LCP của `/` bớt khoảng 100–350 ms.
- **Bảng pha LCP không phải số mô phỏng.** Ở chế độ `simulate`, Lighthouse 12.6.1 (`core/computed/metrics/lcp-breakdown.js`) lấy
  thời điểm **quan sát** của request ảnh nhân với tỉ lệ LCP mô phỏng / LCP quan sát (3 152 / 165 = 19,1): Load Delay 1 148 ms chỉ
  là 82,7 ms quan sát × 19,1 − TTFB, không phải ảnh tải muộn. Thực tế ở lượt đó: poster được request lúc 82,7 ms, ngay sau CSS
  (69 ms) và trước mọi script (87 ms), `fetchpriority=high`, đã có preload trong `<head>` (`features/feed/feed-screen.tsx`);
  `lcp-discovery-insight` đạt cả ba mục, `prioritize-lcp-image` tiết kiệm 0 ms; pha quan sát TTFB 26, Load Delay 56, Load 15,
  Render Delay 68 ms (LCP 165 ms). Preload ảnh LCP vì vậy không còn là đòn bẩy.
- **LCP mô phỏng của `/` là tổng byte xong trước LCP quan sát.** Lantern đưa vào đồ thị LCP mọi request xong trước LCP quan sát và
  mọi script bắt đầu chạy trước mốc đó (cùng CPU ×4 của chúng). Trên runner trang vẽ ở 165 ms, khi mọi script tải lần đầu đã tải
  xong và chạy (script async chạy ngay khi tới, trước khung đầu), nên đồ thị gồm 345 kB: 17 script 210 kB, 4 font 67 kB, poster
  40 kB, HTML 17 kB, CSS 10 kB. Đo trên máy bằng bản build thật với gateway và origin media giả, Lighthouse 12.6.1 cùng cấu hình
  (LCP mô phỏng 2 940 ms, quan sát ~100 ms), rồi bỏ từng nhóm request khỏi devtools log của cùng một lượt và chạy lại phần audit
  (`lighthouse -A`): bỏ mọi script 1 656 ms (−1 290), chỉ chunk react-dom 74 kB −380, chunk runtime của Next 47 kB −150, năm chunk
  riêng của feed −150, bốn font −150 (FCP 1 369 → 763 ms), sáu script nhỏ (13 kB) 0, poster cùng origin với app +300 ms (chung 6
  kết nối HTTP/1.1 với script). Đường găng là chunk react-dom trên một kết nối mới (slow start) cộng thời gian chạy của nó; số byte
  JS của Next 16 và React 19 không giảm được tới mức cần (khoảng −650 ms trên runner).
- **TBT** (long task hydrate, profile CPU ×4 trên máy): React render khoảng 55 ms và lần đầu nạp dữ liệu ICU của locale 25–33 ms
  trong cùng một task. Chi phí ICU là một lần mỗi trang, ở lệnh `Intl` đầu tiên: để server viết sẵn chuỗi "x giờ trước" thì chi
  phí chuyển sang `Intl.NumberFormat` của số đếm, bỏ cả số đếm thì chuyển sang `resolveLocale` của intl-messageformat (next-intl
  dịch chuỗi có tham số). Tách mỗi mục feed vào một `Suspense` thêm một long task 60–70 ms, task đầu không đổi. Không giữ thay đổi
  nào. Cùng các task đó trên runner dài khoảng gấp đôi trên máy (TBT trên máy 16–78 ms, runner 216–322 ms), vì stack chạy cùng máy.
- **Sửa thêm, đo lại bằng job `stack`** (một lượt mỗi trang mỗi lần chạy):
  - `1b85c10` ([40170693114](https://github.com/anhnvcoder/short-video-platform/actions/runs/40170693114), ba lần chạy): chỉ khối tài khoản của sidebar nằm trong `Suspense` (trước là cả sidebar, nút
    Log out bị tháo khỏi DOM khi tên user tới), feed cũ `inert` dưới skeleton khi chuyển tab, link về feed hiện trạng thái chờ.
    `/` LCP 3 171, 5 104, 5 009 ms (median **5 009 ms**), TBT 438, 543, 383 ms; `/v/{id}` LCP 2 790, 3 091, 2 471 ms (median
    2 790 ms), TBT 361, 369, 342 ms, CLS 0,117 ở lần chạy thứ ba. Ở lần hai và ba, phần tử LCP của `/` là `<video>` của player thay
    `<img>`: `<video>` mang `poster` đúng URL ảnh của `<img>` bên dưới, cùng khung; khi `<img>` chưa vẽ trước lúc hydrate chèn
    `<video>`, hai phần tử vẽ cùng frame, Chrome báo `<video>` và LCP thành mốc vẽ sau hydrate (Render Delay 3 951 ms). Không do
    các thay đổi trên: lượt `/v/{id}` 3 908 ms của `db35f86` đã là `<video>`, và bản trước các thay đổi tái hiện được trên máy. CLS
    `/v/{id}`: dòng gợi ý cho khách ở thanh dưới trang chia sẻ xuống 2 dòng ở font dự phòng, 1 dòng ở Be Vietnam Pro, nên thanh thấp
    đi 20 px khi font tới (tái hiện bằng font dự phòng rộng: CLS 0,046).
  - `3f0d4cc` ([40176522127](https://github.com/anhnvcoder/short-video-platform/actions/runs/40176522127), ba lần chạy): `<video>` không còn `poster` (ảnh của mục là poster duy nhất, `<video>`
    chưa có frame không vẽ gì), dòng gợi ý giữ chỗ 2 dòng. Lần chạy đầu dừng ở e2e (WebKit, ca Back về Khám phá ngay sau like:
    lỗi của feed, không liên quan LCP, sửa sau ở `features/feed/use-feed.ts`), Lighthouse không chạy; lần hai, ba: `/` LCP 2 582,
    3 055 ms, TBT 376, 408 ms, CLS 0; `/v/{id}` LCP 2 917, 3 130 ms, TBT 303, 358 ms, CLS 0,002; phần tử LCP của cả hai trang là
    `<img>`. LCP quan sát ở lần ba: `/` 234 ms, `/v/{id}` 174 ms (`benchmarkIndex` 2 048 và 1 941).
- **Kết luận phần 1 của giai đoạn 6b:** LCP `/` **chưa đạt** theo Lantern (2 582–3 171 ms ở mọi lượt có `<img>` là phần tử LCP),
  `/v/{id}` không ổn định dưới 2 500 ms (median 2 360 ms ở `db35f86`, 2 917 và 3 130 ms ở `3f0d4cc`), TBT 303–543 ms trên ngưỡng
  200 ms. Trang vẽ thật sớm: LCP quan sát 165–234 ms trên runner, RUM p75 0,57 s. Không chỉnh thêm trong phần 1 (tránh vòng
  chỉnh-đo trên cùng một số Lantern dao động vài trăm ms giữa các lần chạy): mỗi đòn bẩy dưới đây là một việc riêng ở phần sau.
- **Chưa đạt, đòn bẩy còn lại** (mỗi cái đo lại bằng job `stack` và `compose-obs`; số là phép bỏ request khỏi log ở trên): bớt JS
  tải lần đầu (chunk react-dom −380 ms, runtime của Next −150 ms, năm chunk riêng của feed −150 ms); font tải sau `load` (bỏ bốn font khỏi đồ thị:
  −150 ms LCP, −600 ms FCP; đổi thiết kế: chữ hiện bằng font dự phòng đã chỉnh cỡ tới sau `load` rồi mới đổi, CLS cần đo lại);
  nén brotli và HTTP/2 ở trước web (compose phục vụ thẳng từ server standalone của Next: gzip, HTTP/1.1, mỗi kết nối mới chịu slow
  start trong mô hình Lantern). Đổi cách chấm cổng (số thực địa RUM thay Lantern) là một quyết
  định riêng, không làm ở đây vì không nới ngưỡng. Số thực địa vẫn là RUM (LCP p75 0,57 s trên cluster dev của runner, ADR-0021).

### Game day

Một buổi `make gameday` ngày 2026-10-24 trên `make up OBS=lgtm` (sau `make smoke`, 50 video `READY`), tải nền k6 `local` giữ
60 phút (`SVP_K6_HOLD` mặc định của target, buổi kết thúc sớm hơn), cùng máy và điều kiện với lượt tải ở trên. Postmortem:
[261024-gameday-engagement-down.md](../postmortems/261024-gameday-engagement-down.md).

- **Mốc:** T0 07:24:49 dừng engagement-service; breaker của gateway mở sau 5 s; **TTD 75 s** (`startsAt` của
  `CircuitBreakerOpen`); chẩn đoán xong T0 + 141 s, hết tác động T0 + 152 s (log gateway `"to":"closed"`, 4 s sau khi bật lại
  service), mốc giảm thiểu của người trực T0 + 163 s, cảnh báo hết T0 + 168 s, hồi phục (sau `make smoke`) **T0 + 184 s**.
- **Tác động** (k6, T0 → hồi phục): like 150/183 và ghi lượt xem 300/365 request lỗi 503, tức mọi request của hai route này
  trong 152 s; feed, `POST /videos` và ba trang web 0/3 875 lỗi; 0 lần 429. Gateway (Prometheus) khớp: 158/181, 316/361. Không SLO
  nào tiêu ngân sách (like, lượt xem không có SLO). 5 s đầu trước khi breaker mở: like chờ tới 2,5 s, ~11 request explore quá
  100 ms (`GetStats`).
- **Runbook** `circuit-breaker-open.md` dẫn đúng nguyên nhân (container `Exited (0)`, log dừng êm) 66 s sau T1; thiếu năm chỗ, đã
  sửa: hàm `dc` hỏng khi shell có alias `dc`, `make ps`/`make logs` không cho thấy target và lần breaker mở đầu dưới tải, cách đọc
  `DEADLINE_EXCEEDED` sai với service chết, thiếu bước đo 5xx theo route, thiếu vài giây chậm trước khi breaker mở.
- **Phát hiện phụ:** hai lượt thử sau đó bị chặn trước T0 vì `RateLimitFallbackActive` (page) cháy dưới cùng tải (Redis native
  quá hạn 50 ms qua `host.docker.internal` vài lần mỗi phút; rule page khi có một quyết định dự phòng trong 1 phút). Xem lại
  ngưỡng là việc cần làm của postmortem. Người trực biết trước sự cố nên thời gian chẩn đoán là cận dưới.

### Restore RTO/RPO

Một buổi k3d ngày 2026-10-24 trên cluster dev mới: Apple M2 16 GB, Docker VM 9,7 GiB, cắm điện, không Low Power Mode;
`make k8s-up` 16 phút 10 giây (registry lạnh, cache build Docker còn). Postgres gần rỗng (17 bảng của service, vài dòng do
`make k8s-smoke`), backup và WAL vào MinIO cùng cluster, cùng ổ. `make drill-k8s-backup` (`MODE=latest`) rồi
`MODE=pitr` trên cùng cluster, mỗi chế độ một lần đo trong bảng dưới, không phải phân bố; cùng ngày một lượt `MODE=pitr` nữa
sau khi thu hẹp quyền operator (mục Kiểm chứng sau): RTO 125,6 s, RPO 35,4 s, nên `pitr` có hai lượt trên máy, 85,1 và 125,6 s.
JSON ở `.k8s/drills/backup-<time>.json`.

| Mốc (giây so với T0; dòng đầu là thời lượng) | `MODE=latest` | `MODE=pitr` |
| --- | --- | --- |
| Backup cơ sở theo yêu cầu, thời lượng (`startedAt` → `stoppedAt`) | 3 phút 51 s | 11 s |
| Bắt đầu xoá Cluster `svp-pg` và PVC | −194,1 | −192,7 |
| **T0:** dựng lại bằng `bootstrap.recovery`, thế hệ mới | 0 | 0 |
| Cluster Ready | 108,3 | 54,3 |
| 4 service có Postgres và GlitchTip restart xong, Ready lại | 133,4 | 72,7 |
| **T1:** luồng `k8s-smoke` qua | 151,2 | 85,1 |
| Backup của thế hệ mới `completed` | 176,5 | 107,3 |
| **RTO = T1 − T0** | **151,2 s** | **85,1 s** |
| **RPO** | **≥ 60 s**: 0/60 dòng đánh dấu trở lại; WAL cuối đã lưu lúc 09:32:20,98 UTC, 66 s trước lúc xoá | 37,3 s theo thiết kế (mục tiêu đặt ở giữa 60 dòng): 30/60 dòng trở lại, dòng cuối cách mục tiêu 0,5 s, không dòng nào sau mục tiêu |
| Số dòng 17 bảng của service trước/sau | không đổi | không đổi |

Lượt `latest` không ép `pg_switch_wal`, nên nó là lượt gần với sự cố thật, nhưng không ra con số RPO: không dòng nào trở lại,
chỉ có cận dưới (≥ 60 s); cận trên theo cấu hình là `archive_timeout` cộng thời gian lưu (phát hiện đầu dưới). RPO của lượt `pitr`
chỉ chứng minh PITR dừng đúng chỗ. Hai lượt khác nhau 66 s ở RTO, chủ yếu vì Cluster Ready (108 s và 54 s); chưa tìm nguyên nhân, cần nhiều lượt
hơn để biết đâu là số thường gặp.

**Giai đoạn 6b** (runner `ubuntu-24.04` 4 vCPU amd64, cluster dev, kịch bản `dev-k3d`; số của runner, không so với máy;
[ADR-0021](0021-deferred-verification-stage6b.md) D20): hai lượt mỗi chế độ đều PASS. `latest`: RTO 95,2 và 92,8 s, RPO ≥ 63,2 và
≥ 63,4 s (không dòng đánh dấu nào trở lại); `pitr`: RTO 80,8 và 84,3 s, RPO 38,1 và 36,1 s (30/60 dòng giữ, dòng mới nhất 0,5 s
trước mục tiêu) ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985),
[40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)).

**Phát hiện:**

- **Tắt êm không lưu WAL đang ghi dở.** Mục 5 bước 4 dự kiến pod tắt êm thì RPO gồm cả phần CloudNativePG lưu được lúc tắt.
  Thực tế lượt `latest` mất cả 60 dòng ghi trong phút trước khi xoá: WAL cuối được lưu trước dòng đầu tiên và không có segment
  nào được lưu lúc tắt. Điều này khớp với việc Postgres chỉ lưu segment đã đóng (đầy, hết `archive_timeout`, `pg_switch_wal`).
  Nên trên lab ít ghi, RPO tới `archive_timeout` (5 phút) cộng thời gian lưu **cả khi tắt êm**, không chỉ khi mất đột ngột; con
  số 5 phút là cận trên theo cấu hình, không đo. Ở buổi này, khi không dòng nào trở lại, script in `RPO -s` và JSON để
  `rpo.seconds` là `null`. `backup.sh` nay đọc `written_at` của dòng đầu trước khi xoá: không dòng nào trở lại thì in
  `RPO at least <N> s` (N = lúc xoá − dòng đầu) và JSON ghi `rpo.seconds` là N, `rpo.at_least` là `true`, kèm
  `rpo.first_marker_written_at`; có dòng trở lại thì `rpo.at_least` là `false`.
- **Xoá Cluster mất ~193 s ở cả hai lượt**, khớp với `smartShutdownTimeout` mặc định 180 s của CloudNativePG (smart shutdown chờ
  các phiên đang mở, gồm pool của service, rồi mới fast shutdown). RTO không tính đoạn này (T0 sau khi xoá xong); từ lúc bắt đầu
  xoá tới T1 là 345 s và 278 s.
- **Backup cơ sở đầu tiên chậm:** 4 phút 36 s (`immediate` của cluster mới) và 3 phút 51 s ở thế hệ đầu, 11–22 s ở các thế hệ
  sau. Backup bắt đầu bằng checkpoint không `immediate` (log Postgres `checkpoint starting: force wait`, xem được ở thế hệ sau:
  84 buffer trong 8,3 s); checkpoint dàn trải theo lượng buffer bẩn khớp với chênh lệch, nhưng log của thế hệ đầu mất cùng pod nên
  chưa chứng minh. RTO không gồm đoạn này; `make k8s-up` cluster mới chờ nó.
- **Cluster mới lưu WAL lỗi 3 lần** (09:18:22–24 UTC, MinIO `Forbidden` trên `pg-backups`) trước khi Job `minio-init` tạo user,
  policy; lưu được từ 09:18:42, Postgres giữ segment tới khi lưu được nên không mất WAL; cảnh báo không cháy.
- **GlitchTip nối lại được** sau mỗi lượt (`/_health/` 200, log không có lỗi kết nối database). `make k8s-up` sau hai lượt giữ
  thế hệ `svp-pg-261024094017`, không tạo lại pod Postgres.
- **Prometheus không gửi được cảnh báo tới Alertmanager** 09:13:55–09:24:10 UTC (16 lần `connection refused` tới IP pod
  Alertmanager đang Running) trong lúc cluster dựng, tự hết; `PrometheusErrorSendingAlertsTo*` chỉ pending rồi tắt. Chưa tìm
  nguyên nhân.
- `make drill-k8s-threats` sau diễn tập: mọi mục PASS (gồm BAK-1 qua Envoy), không FAIL nào. `docker stats` và RAM: dòng "RAM
  plugin và sidecar" ở Kiểm chứng sau.

## Hệ quả

- **Được:**
  - Kịch bản tải theo đúng SLO, chạy bằng một bản k6 ghim trên máy, CI và cluster cloud; bảng route → lớp → khoá cho biết trước
    pool user và tốc độ nào không tự chặn mình bằng rate limit.
  - Lần đầu có SLO cho web (lỗi server, INP) và runbook cho mọi cảnh báo gọi người dậy.
  - Lần đầu có backup Postgres thật, phục hồi đã diễn tập với RTO và RPO đo được, cảnh báo khi lưu WAL lỗi; `cnpg_*` có trong
    Prometheus.
  - Phần đo thật vào giai đoạn 6b và 7 dưới dạng lệnh và manifest đã kiểm schema, tiêu chí đạt viết trước.
  - Pod có Postgres không restart lúc khởi động, probe không giết pod còn sống khi node bận.
- **Phải trả:**
  - Plugin Barman Cloud đọc được mọi Secret của cluster dev (RBAC của chart, BAK-1); backup cùng cluster, cùng ổ với dữ liệu, không
    mã hoá lúc nghỉ ở lab.
  - Diễn tập DR chỉ cho đường dev: đường GitOps tự sửa `serverName` về git.
  - Job `stack` thêm 15–25 phút runner mỗi PR mà không chặn merge.
  - Số tải local nhỏ, phụ thuộc máy, không kết luận năng lực; "Xong khi" của roadmap chờ giai đoạn 6b (báo cáo chaos, tải lớn:
    phần sau của 6b, [ADR-0021](0021-deferred-verification-stage6b.md) mục 5) và giai đoạn 7 (1 000 req/s, phục hồi RDS).
  - Chaos Mesh và Velero cần đặc quyền lớn (daemon privileged, `cluster-admin`) trong buổi đo (giai đoạn 6b, 7); Velero không giữ event Redpanda ghi
    sau lần backup cuối.
  - `make cloud-check` cần mạng (chart, schema trên GitHub).
- **Xem lại khi:**
  - Histogram HTTP của web có nhãn route: thêm SLO độ trễ SSR.
  - RUM có lượt thật đủ nhiều (không chỉ e2e, k6 không chạy JavaScript): đánh giá lại cảnh báo INP.
  - Hạn 50 ms của Redis: đã có lệnh quá hạn ở game day, nên quyết lại trên ElastiCache ở giai đoạn 7 (mục 4, Kết quả "p99
    Redis"); ngưỡng page của `RateLimitFallbackActive` dưới tải lab xét ở giai đoạn 6b (đã đổi: [ADR-0021](0021-deferred-verification-stage6b.md) mục 11, Kết quả "p99
    Redis").
  - Plugin Barman Cloud có cờ giới hạn namespace: thu hẹp RBAC như CloudNativePG.
  - CloudNativePG 1.31 phát hành: nâng operator cùng plugin (`barmanObjectStore` bị bỏ không ảnh hưởng vì đã dùng plugin).
  - Một pod k6 không giữ được tốc độ đặt (`dropped_iterations` > 0): thêm pod hay xét k6-operator.
  - 20 lượt `stack` liên tiếp xanh: đưa vào `ci-ok`.
  - Giai đoạn 7 giữ Redpanda trong cluster: độ bền event bằng replication hay Kafka managed, không bằng Velero.

## Hiện thực ở

- k6 (§2): `deploy/k6/` (`main.js`, `api.js`, `web.js`, `lib/`, `load.sh`, `k6.mk`); Job k6 của cluster cloud ở `deploy/k6/cloud/`
  (`render.sh`, `job.yaml.in`, `run.sh`).
- SLO web và cảnh báo (§3): `deploy/observability/slo/svp-slos.yaml`, `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Backup và phục hồi Postgres (§5): `deploy/helm/svp-data/templates/backup.yaml`, `deploy/helm/svp-data/values.yaml`,
  `deploy/k8s/values/plugin-barman-cloud.yaml`, metric ở `deploy/helm/svp-observability/templates/postgres.yaml`, user
  `svp-pg-backup` ở `deploy/s3/init.sh` (store theo [0022](0022-local-object-store-minio-replacement.md)) và `deploy/k8s/secrets.sh` (biến của `deploy/compose/compose.mk`), giữ thế hệ lưu trữ ở
  `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`; diễn tập `deploy/k8s/drills/backup.sh`; BAK-1 ở `deploy/k8s/drills/threats.sh`;
  ngoại lệ RBAC của plugin ở `deploy/ci/trivy-config-ignore.yaml`.
- Velero, Chaos Mesh, kiểm tĩnh bằng kubeconform (§6–§8): `deploy/k8s/cloud/` (`chaos/`, `velero/`, `values/`, `check.sh`,
  `charts.json`), target `cloud-check` của `deploy/k8s/k8s.mk`, nhóm chart cloud của `renovate.json`.
- Probe của chart `svp-service` (§10): `deploy/helm/svp-service/templates/deployment.yaml`.
- Thử lại kết nối Postgres (§11): `internal/pgretry/`, `internal/pgpool/`, `internal/dbmigrate/`.
- Game day (§13): `deploy/compose/drills/gameday.sh`, `deploy/compose/compose.mk`.
- Job `stack` của CI (§15): `.github/workflows/ci.yml`, target `ci-bridge-check` của `Makefile`.
