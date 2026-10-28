# 0019. Giai đoạn 5b phần C: web chạy trên k3d và đi qua chuỗi cung ứng như sáu service, gateway tin trace context khi mọi đường vào đã bỏ của client, lỗi trình duyệt tới GlitchTip qua route cùng origin, OTel ở server Next và RUM web-vitals

- Trạng thái: Chấp nhận; hiện thực và đã kiểm trên máy ngày 2026-10-24 (compose và cluster k3d đường dev, mục "Kết quả
  phần C"); cluster GitOps với image web đã ký, canary web dưới traffic, diễn tập đầy đủ, đo RAM và cổng CI quét lockfile npm
  dời giai đoạn 6b "Kiểm chứng dồn" (mục 12). Ghi chú 2026-10-24: trước ghi giai đoạn 7; giai đoạn 6b chạy trên runner CI 16 GB
  hay VM thuê theo giờ, không cần dịch vụ AWS/GCP; quyết định không đổi. Ghi chú 2026-10-25: phần 1 của giai đoạn 6b đã chạy
  trên runner ([0021](0021-deferred-verification-stage6b.md), mục Kết quả): `drill-obs-threats` (WEB-9), `drill-k8s-threats`, RAM
  và `resources` của web trên cluster dev, cổng CI quét lockfile npm đạt; cluster GitOps với image web đã ký, Kyverno từ chối web
  chưa ký, source map của image CI và canary web ở phần sau của giai đoạn 6b. Ghi chú 2026-10-28: phần 3 của giai đoạn 6b đã chạy
  trên runner (ADR-0021, mục "Phần 3 theo dòng dời"): cluster GitOps với image web đã ký (D3), Kyverno từ chối web chưa ký (D4),
  canary web dưới traffic và client trình duyệt (D6, D14, D18) đạt; source map của image CI kiểm sau merge (D5); §9 (source map
  của image CI kéo từ giai đoạn 7 về giai đoạn 6b, artifact `web-sourcemaps-<arch>` của `images.yml`) và §3 (ngưỡng p99 canary
  của web 250 ms theo số k6) chỉnh bởi 0021; §6 (CORS toàn cục của MinIO ở k3d) bị thay một phần bởi
  [0022](0022-local-object-store-minio-replacement.md) (CORS theo bucket trên RustFS, cùng origin `https://svp.localhost:8443`)
- Ngày: 2026-10-22

## Bối cảnh

- [ADR-0016](0016-web-client.md) §11 chỉ chốt khung của phần C: image distroless qua pipeline ký và quét, release Helm `web`
  (HTTPRoute `svp.localhost`, 2 replica, PDB, canary, NetworkPolicy), GlitchTip, OTel, RUM, và "gateway tin `traceparent`
  chỉ từ pod web". Tới phần B web chỉ chạy ở compose; pipeline giai đoạn 5 ([ADR-0015](0015-cicd-devsecops-stage5.md)) build
  sáu image Go.
- Hiện trạng code ảnh hưởng tới thiết kế (đọc ngày 2026-10-22, chi tiết ở mục Kiểm chứng):
  - Gateway `svp` có một listener `https` với hostname `*.svp.localhost`, Certificate `svp-wildcard` chỉ có tên wildcard; wildcard
    không phủ tên gốc `svp.localhost`.
  - Chart `svp-service` ghi cứng tên HTTPRoute `api` (cả cluster Envoy mà phân tích canary đọc), chỉ cho PDB khi
    `hpa.minReplicas` ≥ 2, và ngưỡng canary cố định cho mọi release (p99 150 ms, 5xx 1%).
  - Gateway dùng propagator rỗng: mỗi request là trace gốc mới ([ADR-0011](0011-observability-stage3.md) §3). Pod Envoy và pod
    web cùng nằm trong dải pod `10.42.0.0/16` ([ADR-0014](0014-kubernetes-local-stage4.md) §9), nên cách "tin theo dải như
    `TRUSTED_PROXY_CIDRS`" mà ADR-0016 §11 dự kiến không tách được hai nguồn đó.
  - Next 16.4.2 sinh khoá Server Action ngẫu nhiên lúc build và ghi vào output; image sẽ công khai trên GHCR. Web có Server
    Action chỉ ở hai module `"use server"` (`web/server/auth-actions.ts`, `profile-actions.ts`), không action nào bắt biến.
  - Ngân sách bundle gần hết ở lớp tải lần đầu: login 196,71/200 kB, upload 195,52/200 kB, feed 311,73/330 kB, `/v/[id]`
    305,52/330 kB ([ADR-0018](0018-web-profiles-public-video-upload.md), Kết quả phần B). SDK trình duyệt của Sentry không vừa.
  - Valkey của cluster không mật khẩu, không persistence, `noeviction`, 64 MB; NetworkPolicy cho gateway và feed-service vào.
  - Container `web` của compose chạy root fs chỉ đọc qua e2e 68/68: server Next không ghi file nào.
- Ràng buộc: máy 16 GB, tối đa **một buổi k3d đường dev** và một lượt compose `core` cho cả phần C; cluster GitOps, canary
  dưới traffic, diễn tập đầy đủ và đo RAM dời giai đoạn 6b (mục 12). Repo và image công khai. Dependency npm chỉ trong danh
  sách ADR-0016 §10.

## Kiểm chứng (đã kiểm ngày 2026-10-22)

| Kiểm gì | Nguồn hay lệnh | Kết quả |
| --- | --- | --- |
| Khoá Server Action lúc chạy | `web/node_modules/next/dist/server/app-render/encryption-utils.js` dòng 78 (Next 16.4.2) | `process.env.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY \|\| serverActionsManifest.encryptionKey`: biến môi trường lúc chạy thắng khoá ghi trong output |
| Khoá lúc build | `build/index.js` dòng 654, `server/app-render/encryption-utils-server.js` dòng 92–99, `build/webpack-config.js` dòng 420, 446, 1951, `build/turbopack-build/impl.js` dòng 44 | Không có biến thì build sinh khoá AES-256 ngẫu nhiên; khoá đó là cả `serverReferenceHashSalt` (id của Server Action) và khoá mặc định ghi vào `server-reference-manifest`. Tài liệu Next (`guides/self-hosting.md`, `data-security.md`) khuyên đặt biến lúc build cho nhiều instance, và ghi "The key is embedded in the build output" |
| Server Action của app | `grep -rnE "use server\|\.bind\(" web/app web/server web/features web/components` | Chỉ `web/server/auth-actions.ts`, `profile-actions.ts` (cấp module), không `.bind`, không action nội tuyến bắt biến |
| Build ID và `deploymentId` | `web/node_modules/next/dist/docs/.../deploymentId.md`, `guides/self-hosting.md` §Version Skew, `server/config.js` dòng 731, `build/index.js` dòng 443–449, `server/app-render/app-render.js` dòng 189–192, `build/templates/app-page-runtime.js`, `client/components/router-reducer/fetch-server-response.js` dòng 163–165, 490 | Không có `deploymentId`: mỗi build sinh build ID ngẫu nhiên (nanoid), gửi là trường `b` của payload RSC; replica của một image chung id. Có `deploymentId`: build ID thành một hằng, id đi trong header (request gửi `x-deployment-id`, response điều hướng mang `x-nextjs-deployment-id`) và thêm `?dpl=<id>` vào URL asset. Cả hai cách, client so id của response điều hướng với id của mình, khác thì điều hướng MPA (tải cả trang). Next không định tuyến theo `?dpl=`. Biến `NEXT_DEPLOYMENT_ID` lúc build cũng đặt được |
| Server Action tới bản build khác | `server/app-render/action-handler.js` dòng 64–69, 381–396; `client/components/router-reducer/reducers/server-action-reducer.js` dòng 102–106; `client/components/unrecognized-action-error.d.ts`; `docs/01-app/02-guides/server-actions.md` §Deployment considerations | Server không có id đó trả **409** `Server Action unavailable.` kèm header `x-nextjs-action-not-found: 1` (400 khi id sai dạng); client ném `UnrecognizedActionError` (nhận bằng `unstable_isUnrecognizedActionError` của `next/navigation`), lỗi tới error boundary, **không** tải lại trang. Client gửi `x-deployment-id` kèm action nhưng không file nào dưới `server/` đọc header đó. Tài liệu: id action đổi theo build, Next xoay id tối đa 14 ngày một lần kể cả khi code không đổi, khuyên đưa lỗi này thành đường thử lại bằng cách tải lại trang |
| Debug ID ở Turbopack | `docs/.../turbopack.md` (Version History: `turbopack.debugIds` từ 16.0.0) | Sinh debug ID (đề xuất TC39) trong bundle và source map, kèm polyfill ghi `globalThis._debugIds` |
| Source map trình duyệt | `docs/.../productionBrowserSourceMaps.md` | Map nằm cạnh file JS, Next tự phục vụ nếu file có mặt |
| SIGTERM của server standalone | `server/lib/start-server.js` dòng 330–380 | Thoát ngay (`process.exit(143)`), không chờ request đang chạy, trừ khi đặt `NEXT_MANUAL_SIG_HANDLE` |
| Source map ở GlitchTip | <https://glitchtip.com/documentation/cli>, `/documentation/error-tracking#source-maps`, `/sdkdocs/javascript-nextjs` (đọc 2026-10-22) | Chỉ mô tả cách theo debug ID (`glitchtip-cli sourcemaps inject`, `sourcemaps upload`; CLI ghi "Beta", là binary); không nêu scope token, không nêu cách theo release + URL, không nêu version. Trang Next.js có ví dụ `tunnel` cùng origin |
| Biên vào k3d | `deploy/helm/svp-cluster/templates/gateway.yaml`, `certificates.yaml` | Một listener `https` cổng 443 hostname `*.svp.localhost`; Certificate `svp-wildcard` `dnsNames` chỉ wildcard |
| Chart `svp-service` | `templates/httproute.yaml`, `canary.yaml`, `autoscaling.yaml` dòng 49 | Tên route `api` cố định; cluster canary `httproute/<ns>/api/rule/0/backend/1`; PDB đòi `hpa.minReplicas` ≥ 2; p99 < 150, 5xx < 1% cố định |
| Gateway bỏ trace context | `services/gateway/internal/httpx/middleware.go` dòng 47 | `otelhttp.WithPropagators(propagation.NewCompositeTextMapPropagator())`: không đọc `traceparent`, `tracestate`, `baggage` |
| Metric HTTP trùng tên | `deploy/observability/slo/svp-slos.yaml`, `grafana/dashboards/svp-red.json` | Mọi query `http_server_request_duration_seconds` lọc `service_name="gateway"`: metric HTTP của web không lẫn vào SLO |
| Valkey của cluster | `deploy/helm/svp-data/templates/valkey.yaml` dòng 32 | `--save "" --appendonly no --maxmemory 64mb --maxmemory-policy noeviction` |
| Route mới không trùng | `find web/app`, `web/proxy.ts` (`matcher`), `web/server/csrf.ts` | Chưa có `/monitoring`, `/rum`; hai đường đi qua `matcher` của proxy, nên POST phải có `Sec-Fetch-Site: same-origin` (hay `Origin` đúng) như mọi route |
| Chi phí debug ID | Nối một đoạn polyfill mẫu (khoảng 230 byte, debug ID ngẫu nhiên) vào 13 chunk tải lần đầu của login trong `web/.next/size-limit/`, so gzip | Thêm khoảng 1,5 kB gzip. Ước lượng: đoạn thật của Turbopack chưa đo |

## Tên chốt

Code, cấu hình, diễn tập và tài liệu dùng đúng các tên này; đổi tên nào thì sửa ADR này trước.

| Nhóm | Tên | Giá trị, ý nghĩa |
| --- | --- | --- |
| Image | `svp_services` (`deploy/k8s/lib.sh`) | Thêm `web` ở cuối, thành bảy |
| Image | `dockerfile web`, context | `deploy/docker/web.Dockerfile`, context `web/`; không build arg `SERVICE` |
| Image | `image_paths web` | `web`, `deploy/docker/web.Dockerfile` |
| Image | Repository GHCR | `ghcr.io/anhnvcoder/short-video-platform/web`; values `deploy/k8s/values/services/web.yaml` |
| Build | Build arg `SVP_BUILD_ID` | CI: 12 hex đầu của commit (bằng tag image). Đường dev k3d: `dev-` + 12 hex đầu của SHA-256 trên nội dung context build theo `web/.dockerignore` cùng Dockerfile (hàm `web_build_id` của `deploy/k8s/lib.sh`, mục 1). Rỗng: compose, `next build` của `make web-check` |
| Build | Biến lúc chạy `SVP_BUILD_ID` | Image chép build arg thành `ENV`; server đọc làm `release` của GlitchTip và `service.version` của OTel; rỗng thì không đặt |
| Build | `next.config.ts` | `deploymentId: SVP_BUILD_ID` (vắng khi rỗng), `turbopack.debugIds: true`, `productionBrowserSourceMaps: true` |
| Build | Stage `sourcemaps` của `web.Dockerfile` | `FROM scratch`, chứa JS và map của `.next/static` cùng bản build; stage runtime vẫn là stage cuối |
| Web, biến | `SENTRY_DSN` | Tuỳ chọn; rỗng là tắt báo lỗi (`/monitoring` 404, SDK server không bật). Compose `${SENTRY_DSN:-}`, k3d Secret `svp/sentry` |
| Web, biến | `SENTRY_ENVIRONMENT` | Mặc định `local`; k3d `k3d` |
| Web, biến | `OTEL_EXPORTER_OTLP_ENDPOINT` và `OTEL_*` khác | Như service Go: compose `http://otelcol:4317` (`x-telemetry-env`), k3d `http://otel-collector.svp-obs:4317`; rỗng thì không dựng exporter; `OTEL_SDK_DISABLED=true` tắt hẳn |
| Web, biến | `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | Base64 của 32 byte ngẫu nhiên. k3d: Secret `svp/web-env`; compose: `.env` (`make env` sinh) |
| Web, biến k3d | `GATEWAY_URL`, `REDIS_URL`, `APP_ORIGIN`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN` | `http://gateway:8080`, `redis://valkey.svp-data:6379/9`, `https://svp.localhost:8443`, `https://s3.svp.localhost:8443`, `https://s3.svp.localhost:8443` |
| Gateway, biến | `TRUST_TRACE_CONTEXT` | `true`: nhận `traceparent`/`tracestate` của request đến; `false` hay rỗng: như hôm nay (mặc định); giá trị khác: gateway không khởi động, lỗi nêu tên biến. Compose `true`, k3d `true` (mục 7) |
| Route web | `POST /monitoring` | `web/app/monitoring/route.ts`: báo lỗi trình duyệt, body JSON ≤ 32 KiB, 20 báo cáo/phút mỗi tiến trình, ngân sách riêng không chung với lỗi server (mục 8) |
| Route web | `POST /rum` | `web/app/rum/route.ts`: số đo web-vitals, body ≤ 4 KiB, 600 beacon/phút mỗi tiến trình (mục 11) |
| Client | Khoá `sessionStorage` | `svp:skew-reload:<deploymentId>` (`dev` khi không có): đã tải lại một lần vì lệch bản build (lỗi tải chunk hay `UnrecognizedActionError`, mục 3) |
| Client | Helper tải lại | `reloadOnceOnSkew(error): boolean` của `web/features/monitoring/skew-reload.ts`; gọi từ ba error boundary, listener `unhandledrejection` và nhánh `catch` của `loadHls()` trong `web/features/feed/player-pool.ts` (mục 3) |
| Metric | `svp.web.vital.lcp`, `.inp`, `.fcp`, `.ttfb` (đơn vị `s`) | Prometheus: `svp_web_vital_<tên>_seconds_{bucket,sum,count}` |
| Metric | `svp.web.vital.cls` (không đơn vị) | Prometheus: `svp_web_vital_cls_{bucket,sum,count}` |
| Metric | Nhãn | `route` ∈ `/`, `/following`, `/login`, `/register`, `/me`, `/upload`, `/u/[handle]`, `/v/[id]`; cùng resource `service_name="web"` |
| Dashboard | `deploy/observability/grafana/dashboards/svp-web.json` | uid `svp-web`: LCP, INP, CLS p75 theo route, số mẫu |
| k3d | Release, Service, cổng | `web` của chart `svp-service`, Service `web:3001`, `protocol: http`, probe `/healthz` |
| k3d | HTTPRoute | `web` (giá trị `httpRoute.name`, mặc định tên release; gateway đặt `api` nên giữ tên cũ), hostname `svp.localhost` |
| k3d | Listener, chứng chỉ | Listener `https-apex` (hostname `svp.localhost`, cổng 443) trên Gateway `svp`; Certificate `svp-apex`, Secret `svp-apex-tls`; value `apexHost` của `svp-cluster`; route chọn listener bằng `httpRoute.sectionName` (mặc định `https`) |
| k3d | Canary | Service `web-canary`, AnalysisTemplate `web-canary`, `web-canary-gate`, cluster Envoy `httproute/svp/web/rule/0/backend/1`; ngưỡng theo release `canaryLimits.p99Ms` (gateway 150, web 500), `canaryLimits.errorRatio` (0.01 cả hai) |
| k3d | Tắt êm | `preStopSleepSeconds` (web 5; release khác không đặt) |
| k3d | Peer NetworkPolicy `web` | namespace `svp`, nhãn `app.kubernetes.io/name: web`, `app.kubernetes.io/component: server`, cổng 3001; peer `gateway` thêm cổng 8080 |
| k3d | Luồng | web: `ingressFrom: [envoy]`, `egressTo: [gateway, valkey, collector, glitchtip]`; gateway: `ingressFrom: [envoy, web]`; Valkey, Collector (`services.otlp`), GlitchTip (`services.errors`) nhận thêm web |
| k3d | Cài đặt | `components.json`: `web` wave 7, sau `gateway`; Argo CD `ignoreDifferences` trọng số của route `web` như `api` |
| GlitchTip | Token tải source map | APIToken nhãn `svp-sourcemaps`; compose `.env` `SENTRY_SOURCEMAPS_TOKEN`; k3d Secret `svp-obs/glitchtip-sourcemaps` khoá `SENTRY_SOURCEMAPS_TOKEN` |
| Make | Tải source map | `make web-sourcemaps` (GlitchTip của compose), `make k8s-web-sourcemaps` (của cluster qua port-forward `127.0.0.1:8000`) |
| Dependency | `sentry` 0.45.0 (CLI getsentry/cli, dev, ghim chính xác) | Thêm vào danh sách ADR-0016 §10, đúng bản mà `@sentry/nextjs` 11.8.0 đã kéo qua `@sentry/bundler-plugins` (mục 9); `@sentry/nextjs` chỉ được import ở code server |
| Diễn tập | `traffic.sh` | Thêm route log `web-login`, `web-asset` (mục 3) |

## 1. Image `web` trong chuỗi cung ứng

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **`web` là image thứ bảy của cùng pipeline, context `web/`** | Một đường build, quét, ký, attest, promote, Kyverno cho mọi image | Script viết cho Go (`dockerfile`, `build_image`, `image_paths`) phải biết một image có context và Dockerfile khác |
| Workflow riêng cho web | Không đụng script của sáu image | Hai đường ký và promote phải giữ khớp; Kyverno, `verify-release.sh` vẫn phải biết image thứ bảy |
| Build ID mặc định của Next (ngẫu nhiên mỗi build) | Không cấu hình; Next đã phát hiện lệch khi điều hướng (id trong payload RSC khác thì tải cả trang), kể cả hai bản build của cùng một commit | Id ngẫu nhiên, không ai biết trước: không dùng được làm khoá tải lại, `release` của GlitchTip, `service.version` của OTel; hai kiến trúc của một commit có id khác nhau |
| **Build ID theo commit (CI) hay theo nội dung context build (dev), làm `deploymentId`** | Một id đã biết, cùng giá trị cho hai kiến trúc của một commit: khoá tải lại (mục 3), `release`, `service.version`; cùng context cho cùng image ID ở đường dev | Thêm một build arg và một hàm tính; hai bản build ra bundle khác mà cùng id (build lại không dùng cache) thì Next không còn thấy lệch khi điều hướng (mục Quyết định) |
| **Khoá Server Action đặt lúc chạy từ Secret** | Image công khai không mang khoá đang dùng; mọi replica chung khoá | Id của action vẫn tính từ khoá ngẫu nhiên lúc build, nên đổi mỗi build và hai kiến trúc của một commit khác nhau: action gửi từ trang của bản build này tới pod của bản khác (canary, tab mở từ trước lần phát hành) bị từ chối, client phải tải lại trang (mục 3) |
| Khoá thật đặt lúc build (tài liệu Next gợi ý) | Id action ổn định qua các build | Khoá nằm trong output, tức công khai trên GHCR |
| Khoá cố định không bí mật lúc build, khoá thật lúc chạy | Id action ít đổi giữa các build và giữa hai kiến trúc | Khoá cố định nằm trong repo và image, giống nhau ở mọi bản build, là khoá mã hoá khi thiếu biến lúc chạy; Next vẫn xoay id tối đa 14 ngày một lần kể cả khi code không đổi (mục Kiểm chứng), nên vẫn cần đường tải lại |

### Quyết định

Chọn image thứ bảy, build ID theo commit hay nội dung, khoá đặt lúc chạy.

- `svp_services` thêm `web` **ở cuối**: sáu image Go chung cache module Go và build nhanh, lỗi của chúng hiện trước bản build web
  lâu nhất. Chỗ nào in danh sách đã sắp xếp (`changed-services.sh`) vẫn sắp xếp.
- `dockerfile web` là `deploy/docker/web.Dockerfile`, context là `web/` (file `web/.dockerignore` quyết định context; compose đã
  build như vậy), không build arg `SERVICE`. `image_paths web` là `web` và `deploy/docker/web.Dockerfile`: đổi `go.mod`,
  `internal/` hay `.dockerignore` gốc không build web, đổi một file dưới `web/` chỉ build web. Luật "đổi đường build, quét,
  ký thì build lại tất cả" (ADR-0015 §3) giữ nguyên, nên lần merge của phần C phát hành lại cả bảy một lần.
- Repository `ghcr.io/anhnvcoder/short-video-platform/web`, tag và digest như sáu image, PR promote ghi
  `deploy/k8s/values/services/web.yaml`. Kyverno `svp-images` nhận theo prefix của repo nên policy không đổi. Trước khi CI phát
  hành web lần đầu và PR promote merge, `make k8s-gitops-up` từ chối vì `web.yaml` chưa có digest, đúng như với service chưa
  phát hành.
- **Quét:** trivy `--scanners vuln,secret` như sáu image. Trong image, trivy đọc `package.json` của từng gói trong
  `node_modules` của bản standalone (gói loại `node-pkg`), nên lỗ hổng npm vào cùng cổng CRITICAL và bí mật; SBOM syft liệt kê
  cùng các gói. Đo ở một chân build thật (`deploy/ci/build-image.sh web arm64`, 2026-10-22): cổng qua (0 CRITICAL, 0 HIGH, 0 bí
  mật), trivy thấy **14 gói** `node-pkg`, SBOM syft 80 gói trong đó 63 gói npm (phần lớn là `next/dist/compiled/*`). Ít vì
  Turbopack gộp dependency của server (`redis`, `zod`, `@sentry/*`, `next-intl`...) vào chunk server của `.next`, nên các gói
  đó không còn `package.json` trong image và **CVE của chúng không hiện trong quét gói của image**. Với chúng, lớp đỡ là
  lockfile `web/pnpm-lock.yaml` (Renovate, cảnh báo lỗ hổng không chờ 3 ngày); chưa có cổng nào trong CI quét lockfile như trivy
  quét image (việc còn lại, xem mục 12). Node của
  image distroless không phải gói dpkg nên trivy có thể không thấy CVE của chính runtime Node (**chưa xác nhận**); lớp đỡ là
  Renovate nâng digest base image.
- **`SVP_BUILD_ID`** (build arg, khai ngay trước `RUN pnpm build` để đổi id không làm mất cache bước cài gói):
  - CI (`deploy/ci/build-image.sh`): 12 hex đầu của commit, bằng tag image. Hai kiến trúc của một commit cùng id.
  - Đường dev k3d (`build_image web` của `lib.sh`): `dev-` + 12 hex đầu của SHA-256 trên danh sách `<SHA-256 nội dung> <đường>`,
    sắp theo đường, của đúng các file mà context build nhận, cộng `deploy/docker/web.Dockerfile` (hàm `web_build_id`). Tập file
    lấy theo `web/.dockerignore`, **không theo git**: file git bỏ qua mà `.dockerignore` không loại (`.DS_Store` của Finder) có
    tính, file đã track mà `.dockerignore` loại (`web/design/`) không tính. Nhờ vậy cùng id khi và chỉ khi cùng context: build
    cache cho cùng image ID và `make k8s-up` không tạo ReplicaSet (hay canary) mới khi context không đổi; context đổi thì id
    mới, nên một file mà git không thấy không tạo được hai bản build khác nhau cùng `deploymentId`, và sửa file ngoài context
    không tạo canary.
    - Hàm chỉ hiểu dạng mà `web/.dockerignore` đang có: mỗi dòng (bỏ dòng trống và dòng `#`) là một mẫu glob một tầng, không
      `/`, `!` hay `**`, khớp tên ở gốc context (như Docker: mẫu không có `/` chỉ khớp ở gốc) và loại cả cây bên dưới. Gặp dòng
      dạng khác thì hàm dừng và nêu dòng đó, để không lệch với Docker mà không ai biết; thêm dạng mới thì sửa hàm cùng lúc.
    - Symlink tính theo chuỗi đích (context gửi symlink nguyên dạng); quyền file không tính.
    - Còn lại: xoá build cache (`docker builder prune`) hay chỉ đổi quyền file thì cùng id mà build lại ra bundle khác (id
      action và chunk ngẫu nhiên mỗi build), image ID mới nên `make k8s-up` vẫn chạy canary. Giữa hai bản đó Next **không**
      thấy lệch khi điều hướng (header mang cùng `deploymentId`; build ID mặc định thì thấy, vì ngẫu nhiên mỗi build), và id
      action khác nhau: chỉ đường tải lại của mục 3 đỡ (action 409, chunk 404), một lần cho id đó vì khoá theo
      `deploymentId`, lần lệch sau tới error boundary. CI cũng vậy khi build lại đúng commit đã phát hành (dispatch
      `services=web`). Chấp nhận: cả hai hiếm (xoá cache giữa hai lần `k8s-up` khi cluster đang chạy, dispatch build lại cùng
      commit), và hậu quả là một trang hay một video lỗi có báo GlitchTip, không mất dữ liệu.
    - `make k8s-web-sourcemaps` dùng cùng hàm.
  - Compose và `next build` của `make web-check`: rỗng. Compose chạy một replica nên không có lệch phiên bản.
  - `next.config.ts` đặt `deploymentId` bằng biến này khi có. Phát hiện lệch khi điều hướng không phải cái được thêm: không
    có `deploymentId`, build ID ngẫu nhiên mỗi build trong payload RSC đã làm Next tải lại cả trang khi response điều hướng
    đến từ bản build khác (mục Kiểm chứng). `deploymentId` thay id ngẫu nhiên đó bằng một id đã biết trước, đi trong header
    điều hướng và `?dpl=<id>` của URL asset, cùng giá trị cho hai kiến trúc của một commit; cái được là id đó làm khoá tải lại
    (mục 3), `release` và `service.version` (bên dưới). Cái giá là trường hợp cùng id khác bundle ở trên. Server Action gửi
    tới bản build khác thì cả hai cách Next đều không tải lại gì, client tự xử lý (mục 3).
  - Stage runtime chép build arg thành `ENV SVP_BUILD_ID`: server đọc làm `release` của sự kiện GlitchTip và `service.version`
    của OTel. Không phải bí mật.
- **Khoá Server Action:** server đọc `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` lúc chạy (k3d: Secret `svp/web-env`, do
  `deploy/k8s/secrets.sh` tạo từ `.env`; compose: `.env`), **không** đặt lúc build. `make env` sinh base64 của 32 byte ngẫu
  nhiên (AES-256, định dạng Next đòi). Secret `svp/web-env` luôn được tạo, vì Deployment của chart đọc `envFrom` Secret
  `<release>-env` không `optional`. Compose truyền `${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:-}`: rỗng thì Next dùng khoá trong
  image, chạy được vì compose một replica và app chưa có action bắt biến.
  - Vì sao không đặt lúc build như tài liệu Next gợi ý: khoá lúc build nằm trong `server-reference-manifest` của image, mà image
    công khai. Biến lúc chạy thắng khoá của manifest (mục Kiểm chứng), nên khoá thật không bao giờ vào image.
  - Khoá ngẫu nhiên lúc build vẫn còn trong image: nó chỉ mã hoá biến bị action nội tuyến bắt (app không có) và làm muối cho id
    action. Id action không phải bí mật: trình duyệt nhận id của mọi form nó render, mỗi action tự kiểm phiên. Khoá preview mode
    trong `prerender-manifest` cũng công khai theo cách đó; app không dùng draft mode và mọi trang render động, nên cookie bypass
    không đổi được gì (threat model WEB-23).
  - Cái giá: id action đổi mỗi build, và bản amd64 với arm64 của một commit có bundle trình duyệt khác nhau (chứa id khác nhau),
    nên debug ID và source map khác nhau theo kiến trúc (mục 9). Cluster chỉ một kiến trúc nên không có lệch giữa hai bản.
    Action (đăng nhập, đăng ký, đổi tên hiển thị) gửi từ trang của bản build này tới pod của bản khác bị từ chối (409, mục
    Kiểm chứng): lúc canary (25%, 50%, không ghim phiên theo pod) và từ tab mở trước lần phát hành. Client tải lại trang một
    lần (mục 3); người dùng mất nội dung form đang gõ và gửi lại.
  - Vì sao không đặt khoá cố định không bí mật lúc build để giữ id: nó chỉ bớt số lần lệch, không bỏ được đường tải lại (Next
    vẫn xoay id tối đa 14 ngày một lần kể cả khi code không đổi), mà thêm một khoá nằm trong repo, giống nhau ở mọi bản
    build và thành khoá mã hoá khi biến lúc chạy thiếu (compose với `.env` cũ chưa chạy lại `make env`). Đường tải lại cần
    cho cả hai cách, nên chọn cách không thêm khoá. Xem lại khi số đo ở giai đoạn 6b cho thấy tải lại vì action là đáng kể
    (canary web dưới traffic: phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `web-canary`)).
    Số đo 2026-10-28 ([40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955), hai build cùng nguồn khác `SVP_BUILD_ID`): ở hai canary tốt 30 trên 133 Server Action trả 409
    (22,6 %, trên mức 10 % mà D6 đặt), mỗi client tải lại nhiều nhất 2 lần mỗi canary (giới hạn 2). Đường tải lại giữ đúng giới
    hạn, nhưng tỷ lệ đó mở việc xét khoá cố định bằng ADR riêng (chưa làm).

## 2. Release Helm `web`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Release thứ bảy của chart `svp-service`** | Cùng securityContext, probe HTTP, NetworkPolicy theo peer, canary, ServiceAccount không token | Chart thêm vài value (tên route, listener, ngưỡng canary, PDB không HPA) |
| Chart riêng cho web | Tự do | Lặp lại phần lớn chart; hai nơi giữ luật FF-3, FF-4 |
| Thêm SAN `svp.localhost` vào Certificate wildcard, listener thứ hai | Một chứng chỉ | Chứng chỉ của kết nối tới `svp.localhost` hợp lệ cho cả `s3.svp.localhost`, cùng IP: trình duyệt gộp request HLS vào kết nối HTTP/2 đó (RFC 9113 §9.1.1), Envoy chọn filter chain theo SNI của listener apex, và request tới `s3` không khớp route nào trừ khi Envoy Gateway trả 421 (**chưa xác nhận**) |
| **Listener `https-apex` với chứng chỉ riêng chỉ có `svp.localhost`** | Chứng chỉ không phủ tên khác nên không trình duyệt nào gộp kết nối giữa hai listener | Thêm một Certificate |
| Bỏ hostname của listener (nhận mọi tên) | Một listener | Route của namespace được phép tự nhận tên bất kỳ; chứng chỉ trả cho mọi SNI |

### Quyết định

- **Biên vào:** Gateway `svp` thêm listener **`https-apex`**: cổng 443, HTTPS, hostname `svp.localhost` (value `apexHost` của
  `svp-cluster`), TLS `Terminate` với Secret `svp-apex-tls` của Certificate **`svp-apex`** (`dnsNames: [svp.localhost]`, cùng
  ClusterIssuer `svp-ca`, ECDSA P-256), `allowedRoutes` như listener `https`. Certificate wildcard giữ nguyên. Client vẫn chỉ
  tin `.k8s/ca.crt` (cùng CA). Đây là thay đổi so với dự kiến "thêm SAN vào Certificate" của ADR-0016 §7, vì lý do gộp kết nối
  ở bảng trên.
- **HTTPRoute** đặt tên theo value `httpRoute.name`, mặc định là tên release: web có route `web`; `gateway.yaml` đặt `api` nên
  canary, Argo CD, `measure-canary` và diễn tập của gateway không đổi. Listener chọn bằng `httpRoute.sectionName` (mặc định
  `https`, web đặt `https-apex`). Mọi chỗ trong chart suy từ tên route: plugin Gateway API của Rollout, cluster Envoy của phân
  tích (`httproute/<namespace>/<tên route>/rule/0/backend/1`).
- **Workload:** `protocol: http`, port **3001** (cổng của image, như compose), probe readiness và liveness `/healthz` (đường
  probe HTTP có sẵn của chart; `/healthz` trả lời không cần Redis hay gateway). **2 replica cố định, không HPA**: tải SSR của lab
  nhỏ, HPA chưa có số đo để đặt (k6 giai đoạn 6). PDB `minAvailable: 1`: chart nới luật PDB thành "luôn ít nhất hai replica",
  tức `hpa.minReplicas` ≥ 2 **hoặc** không HPA/KEDA và `replicas` ≥ 2. `spreadAcrossNodes: true`.
- **Bảo mật pod:** như sáu service (FF-4): non-root 65532, root fs chỉ đọc, drop ALL, seccomp `RuntimeDefault`, không token
  ServiceAccount, PSA `restricted`. **Không thư mục ghi được**: server không ghi file (mọi trang render theo request, ảnh không
  tối ưu, `.next/cache` rỗng), compose đã chạy `read_only` qua toàn bộ e2e.
- **Resources:** request 100m / 128Mi, limit 1 CPU / 384Mi. Compose đo 53 MiB lúc nghỉ, 96 MiB sau e2e (chưa có OTel và SDK
  Sentry server); limit để chỗ cho hai thứ đó, đo lại ở giai đoạn 6b. Compose giữ `mem_limit: 256m`. Đo lại trên runner
  (2026-10-25, cluster dev, [ADR-0021](0021-deferred-verification-stage6b.md) D9): working set mỗi pod web 85–90 MiB ở điểm nghỉ
  60 s, 136–139 MiB ở điểm nghỉ cuối, cao nhất 144 MiB trong e2e ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)); theo quy tắc
  của ADR-0021 mục 8 giữ limit 384Mi, request 128Mi; phần 3 áp lại với số k6.
- **Tắt êm:** `lifecycle.preStop.sleep` **5 s** (value `preStopSleepSeconds`, hành động `sleep` có sẵn của Kubernetes, không cần
  shell trong image distroless), `terminationGracePeriodSeconds` mặc định 30 s. Server standalone thoát ngay khi nhận SIGTERM;
  Envoy Gateway gửi thẳng tới IP pod theo EndpointSlice, nên trong lúc pod bị gỡ khỏi endpoint, request mới vẫn có thể tới. 5 s
  chờ cho Envoy cập nhật trước khi tiến trình thoát.
- **Cài đặt:** `components.json` thêm `web` wave 7, đứng sau `gateway` (web khởi động không cần gateway: `/healthz` không gọi
  nó). Argo CD bỏ qua trọng số của mọi route có canary (`web` như `api`). `make k8s-up` chờ Rollout `web` như gateway.
- **Cache header:** `/_next/static/*` do Next đặt `public, max-age=31536000, immutable` (proxy không chạy cho đường này); HTML và
  mọi route qua proxy giữ `private, no-store`; Envoy không thêm hay đổi header cache nào. Đã kiểm ở k3d ngày 2026-10-24 bằng
  `curl -sI` qua Envoy: asset `public, max-age=31536000, immutable`, `/login` `private, no-store` (mục Kết quả phần C).

## 3. Canary của web và lệch phiên bản

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Canary Argo Rollouts như gateway, ngưỡng riêng** | Cùng cơ chế, cùng phân tích từ metric Envoy | Cần traffic vào web đủ mẫu; SSR chậm hơn API nên ngưỡng p99 của gateway không dùng được |
| Rolling update của Deployment | Đơn giản | Không tự abort bản lỗi |
| Asset ở bucket/CDN giữ nhiều bản | Hết 404 asset khi lệch | Hạ tầng của giai đoạn 7 (CDN) |

### Quyết định

- `canary: true` cho web, cùng bước của gateway (25%, 60 s, 50%, 60 s, bước gate, 100%) và cùng hai AnalysisTemplate, đọc cluster
  `httproute/svp/web/rule/0/backend/1`, vẫn đòi ít nhất 30 response không phải 4xx mỗi phút. Ngưỡng thành value theo release
  (`canaryLimits`): 5xx < 1% cho cả hai; p99 **< 500 ms** cho web (gateway giữ 150 ms). Vì sao 500: trang SSR gọi gateway rồi
  render, pod canary mới khởi động còn lạnh, web chưa có SLO độ trễ (đặt ở giai đoạn 6 với k6); 500 ms là một biên bucket mặc
  định của Envoy (250, 500, 1000) nên p99 nội suy ít sai.
- **Traffic diễn tập** (`deploy/k8s/drills/traffic.sh`) thêm web qua `https://svp.localhost:8443`: `GET /login` khoảng 3 lần/s
  (route log `web-login`; trang không cần phiên, không gọi gateway) và khoảng 1 lần/s một file `/_next/static/...` đọc từ HTML
  của lần `/login` trước (route log `web-asset`). Ở 25% canary nhận khoảng 45 response `/login` mỗi phút, trên ngưỡng 30. Asset
  của bản build khác trả 404 (4xx, không vào mẫu số): số 404 của `web-asset` trong log là số đo lệch asset dưới canary.
- **Lệch phiên bản:** trang của một bản build gửi ba loại request có thể tới pod của bản kia (lúc canary không ghim phiên theo
  pod, hay từ tab mở trước lần phát hành):
  - Điều hướng phía client (RSC): Next lo, thấy id của response khác id của trang thì tải lại cả trang; hai bản cùng id
    (build lại không dùng cache, mục 1) thì không thấy.
  - Server Action (đăng nhập, đăng ký, đổi tên hiển thị): Next **không** lo. Pod của bản kia không có id action đó (mục 1) nên
    trả 409 kèm `x-nextjs-action-not-found`, client ném `UnrecognizedActionError`, lỗi tới error boundary (mục Kiểm chứng).
    Action chưa chạy gì ở server, nên tải lại rồi gửi lại là an toàn.
  - Chunk chỉ có ở bản kia: 404. App có hai chunk tải lười tường minh (không `next/dynamic` hay `lazy()`): hls.js
    (`import("hls.js/light")` trong `loadHls` của `web/features/feed/hls-loader.ts`, dùng ở feed và `/v/{id}`) và `web-vitals`
    (`import("web-vitals")` trong `web/features/rum/vitals-reporter.tsx`, sau sự kiện `load`, mục 11). Lỗi tải chunk
    `web-vitals` bị nuốt có chủ ý: không tải lại, không báo lỗi, chỉ mất số đo RUM của lần tải trang đó. Chunk của component
    mà trang hay điều hướng cần thì Next tải; 404 thì Next ném lỗi tải chunk, lỗi tới error boundary hay
    `unhandledrejection`.

  Một helper dùng chung, **`reloadOnceOnSkew(error)`** (`web/features/monitoring/skew-reload.ts`, cạnh reporter của mục 8),
  **tải lại trang đúng một lần** cho mỗi build khi gặp lỗi của hai loại cuối (action, chunk). Nó được gọi từ **mọi** nơi bắt
  các lỗi đó:
  - error boundary `app/error.tsx`, `global-error.tsx`, `components/shell/route-error.tsx`;
  - listener `unhandledrejection` của `window` (cùng chỗ với reporter, mục 8);
  - nhánh `catch` của `loadHls()` trong `attach` của `web/features/feed/player-pool.ts`. Lỗi tải chunk hls.js không tới hai chỗ
    trên: `player-pool.ts` bắt lời hứa bị từ chối và chỉ đánh dấu video `error` (`fail(slot)`). Nhánh đó gọi helper trước
    `fail(slot)`; helper không tải lại thì nhánh đó báo lỗi qua reporter (mục 8), vì không error boundary nào báo thay, rồi
    `fail(slot)` như hôm nay. `hls-loader.ts` không đổi (nó vẫn đặt lại `loading` để video sau thử lại). Test của
    `player-pool.ts` tiêm loader bị từ chối, nên phủ được nhánh này. Phần web hiện thực sửa `player-pool.ts` cùng
    `web/features/monitoring/`.

  `UnrecognizedActionError` nhận bằng `unstable_isUnrecognizedActionError` của `next/navigation` (API `unstable_` của bản ghim:
  nâng Next mà hàm đổi thì test bắt); lỗi tải chunk (cả lỗi của `import()` động) nhận theo tên và message của Turbopack, kiểm
  bằng test chặn chunk khi hiện thực. Nếu `sessionStorage` chưa có khoá `svp:skew-reload:<deploymentId>` thì helper đặt khoá,
  gọi `location.reload()` và trả `true`; lỗi khác hay khoá đã có thì trả `false`, nơi gọi đi tiếp đường của nó (error boundary
  hiện và báo lỗi, video lỗi và báo lỗi). Trang tải lại có thể đến từ bản kia (id khác) nên lần lệch sau vẫn được tải lại một
  lần: lúc canary có hai bản nên tối đa hai lần rồi tới error boundary hay video lỗi; asset mất thật thì không thành vòng lặp.
  Lỗi tải chunk vì mạng chập chờn không phân biệt được với lệch bản từ trình duyệt: cũng chỉ tải lại một lần rồi theo đường
  cũ. Cái giá: nội dung form đang gõ và vị trí đang xem trong feed mất, người dùng gửi lại hay cuộn lại (đúng cách tài liệu
  Next khuyên cho action). Test của phần web phủ hai lỗi và ba nơi gọi: mỗi lỗi một ca tải lại và một ca đã có khoá;
  loader bị từ chối vì lỗi tải chunk thì `player-pool.ts` gọi helper, đã có khoá thì báo lỗi, rồi video vẫn `error` như cũ.
- 409 của action lệch bản là 4xx nên không vào mẫu số của phân tích canary, không làm abort.
- Đo dưới traffic thật (số 404 asset, số lần tải lại vì chunk và vì action, abort hay promote) dời giai đoạn 6b (mục 12);
  phần sau của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md) mục 5, kịch bản `web-canary`). Kết quả mục 12.
- `canaryLimits.p99Ms` của web: 500 → 250 ms (2026-10-28, quy tắc của ADR-0021 §8 trên p99 upstream của Envoy 50 ms ở mức k6 cao
  nhất đạt, [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867)); canary với ngưỡng mới promote bản tốt, không abort oan ([40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955)).

## 4. NetworkPolicy của web (đóng WEB-13 ở k3d)

- **Vào:** chỉ Envoy (`ingressFrom: [envoy]`), cổng 3001. Không pod nào khác của cluster, kể cả gateway, gọi được web.
- **Ra:** gateway 8080, Valkey 6379, Collector 4317, GlitchTip 8000 (`egressTo: [gateway, valkey, collector, glitchtip]`), DNS
  (policy `allow-dns` có sẵn). Không Postgres, Redpanda, MinIO, cổng gRPC, Pyroscope (web không đẩy profile), API server hay
  internet.
- **Phía đích:** gateway `ingressFrom: [envoy, web]`; Valkey (chart `svp-data`), Collector (`services.otlp`) và GlitchTip
  (`services.errors`) của `svp-observability` nhận thêm pod web. Peer `gateway` của chart có thêm cổng 8080 để làm đích egress.
- Bảng "Luồng được mở" của ADR-0014 §3 thêm các dòng:

| Nguồn (namespace) | Đích (namespace) | Cổng TCP | Lý do |
| --- | --- | --- | --- |
| Envoy proxy | web, gồm pod canary (`svp`) | 3001 | HTTPRoute `web` |
| web (`svp`) | gateway (`svp`) | 8080 | BFF gọi API (ADR-0016 §5) |
| web (`svp`) | Valkey (`svp-data`) | 6379 | Session db 9 (mục 5) |
| web (`svp`) | Collector, GlitchTip (`svp-obs`) | 4317; 8000 | OTLP; lỗi |

- Compose: thêm `otelcol` và `glitchtip` (profile `obs`) vào mạng `web`, **không** đưa `web` vào mạng `default`. Container web
  vẫn tới mọi cổng loopback qua `host.docker.internal` (WEB-13 vẫn chấp nhận ở compose); hai đích mới vốn đã tới được qua đường
  đó.

## 5. Session ở Valkey db 9 của cluster

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Dùng Valkey chung, db 9, không mật khẩu, NetworkPolicy mở cho web** | Không thêm thành phần hay bí mật | Pod nào tới được 6379 (gateway, feed-service, web) cũng đọc và ghi được session |
| ACL của Valkey theo tiền tố khoá (`~svp:web:*` cho web) | Cô lập theo client | Ba mật khẩu, Secret, URL có credential; diễn tập xoá khoá qua `kubectl exec` cần credential quản trị |
| Valkey riêng cho session, chỉ web tới được | Cô lập bằng NetworkPolicy, không mật khẩu | Thêm một workload và RAM; lệch với ADR-0016 §5 |

### Quyết định

Chọn **Valkey chung db 9**, mở rộng phần chấp nhận của IN-7, ở lab local:

- Giá trị session là JSON có **access token và refresh token** của người dùng (ADR-0016 §5); khoá là
  `svp:web:sess:<sha256(sid)>`, nên đọc Valkey không dựng lại được cookie, nhưng lấy được token.
- Ai lợi dụng được: pod gateway bị chiếm vốn đã giả được mọi người dùng qua gRPC (`x-user-id`, IN-2), nên không thêm gì. Pod
  feed-service bị chiếm thì **có thêm** đường mới: nó không tới được gateway, user-service hay internet (NetworkPolicy), nên token
  đọc được không dùng được từ chính pod đó; nhưng nó ghi được session, nên kẻ tấn công có phiên web của chính mình (biết sid của
  mình, tức biết khoá) chép token của người khác vào phiên đó rồi dùng web như người đó. Chấp nhận ở lab một máy một người, như
  IN-7; ghi ở threat model WEB-22.
- Valkey không persistence: pod Valkey khởi động lại thì mọi phiên mất, người dùng đăng nhập lại (refresh token ở user-service
  vẫn còn hạn tới khi tự hết). `noeviction`: đầy 64 MB thì ghi lỗi (login lỗi), không xoá phiên của ai. Chấp nhận ở lab.
- **Xem lại khi:** lên cloud (giai đoạn 7): Redis/Valkey có AUTH, ACL theo client và TLS, hay instance riêng cho session; hoặc
  sớm hơn nếu feed-service thêm đường ra mới.

## 6. CORS của MinIO ở k3d (WEB-10)

**Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)** (2026-10-25): store của chart `svp-data` là RustFS, Job `s3-init` đặt CORS theo bucket
(`S3_CORS_ALLOWED_ORIGINS=https://svp.localhost:8443`, `uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`); origin của web, route
`s3` và `MEDIA_ORIGIN`, `UPLOAD_ORIGIN` không đổi. Phần dưới giữ nguyên như lúc quyết.

- MinIO của chart `svp-data` đặt `MINIO_API_CORS_ALLOW_ORIGIN=https://svp.localhost:8443`, đúng một origin (không `*`, không
  origin của `web-dev`). Biến toàn cục mọi bucket như compose (ADR-0018 §9), áp cho cả phát HLS lẫn upload.
- Web ở k3d đặt `MEDIA_ORIGIN` và `UPLOAD_ORIGIN` là `https://s3.svp.localhost:8443` (route `s3` của Envoy), khớp
  `MEDIA_PUBLIC_BASE_URL` của gateway và `S3_PUBLIC_ENDPOINT` của video-service; CSP của web nhận origin đó.

## 7. Trace context từ web tới gateway (chỉnh ADR-0011 §3 và cơ chế của ADR-0016 §11)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Tin theo dải nguồn như `TRUSTED_PROXY_CIDRS` (ADR-0016 §11) | Không cần thêm gì ở Envoy | Pod Envoy và pod web cùng dải `10.42.0.0/16`, IP pod đổi mỗi lần tạo: không tách được |
| **Envoy bỏ trace context của client trên mọi route, gateway có công tắc tin trace context, NetworkPolicy chỉ cho Envoy và web vào gateway** | Mọi đường vào gateway đều không mang context do client đặt; web là nguồn duy nhất còn lại | Cấu hình ở ba chỗ; compose không có Envoy |
| Header bí mật giữa web và gateway | Gateway biết chắc request từ web | Thêm một bí mật, phải xoay; không cần khi NetworkPolicy đã chặn đường |
| Danh tính bằng mTLS (Istio, giai đoạn 6 tuỳ chọn) | Đúng bài | Chưa có |

### Quyết định

- **Gateway:** biến `TRUST_TRACE_CONTEXT`. `false` hay rỗng (mặc định): như hôm nay, propagator rỗng, mỗi request trace gốc mới.
  `true`: middleware HTTP đọc `traceparent` và `tracestate` theo W3C TraceContext (không `baggage`), server span là con của
  context hợp lệ, trace đi tiếp xuống gRPC và outbox như cũ; context sai dạng (version lạ, trace id toàn 0) thì trace gốc mới.
  **Cờ sampled của request đến không được quyết**: gateway lấy trace id và span cha, còn quyết định ghi span như với span gốc,
  nên client không tắt được trace ở gateway. Sampler mặc định không tự làm vậy: `parentbased_always_on` coi parent từ xa có cờ
  sampled = 0 là `AlwaysOff` (`remoteParentNotSampled`) và bỏ span. Nên propagator bọc của gateway, khi extract, đặt cờ sampled
  của context đọc được thành 1 (bỏ lựa chọn của nguồn), và `parentbased_always_on` (mặc định; compose và k3d không đặt
  `OTEL_TRACES_SAMPLER`) ghi span; cách tương đương được nhận: sampler dựng với `remoteParentNotSampled` là AlwaysOn. Test:
  request có `traceparent` cờ `00` vẫn có span gateway được ghi, cùng trace id. Giá trị khác `true`/`false` thì gateway không
  khởi động, lỗi nêu tên biến, như `TRUSTED_PROXY_HOPS`.
- **Envoy (k3d):** mọi HTTPRoute của chart `svp-service` (`api`, `web`) có filter `RequestHeaderModifier` mức rule `remove:
  [traceparent, tracestate, baggage, sentry-trace]`, đứng cạnh filter `x-svp-backend` của từng backendRef (canary vẫn có cluster
  riêng). Route `s3` không cần: MinIO không đọc các header này và không dẫn tới gateway.
- **NetworkPolicy:** chỉ Envoy và web vào cổng 8080 của gateway (mục 4).
- **Web chỉ inject, không extract:** propagator toàn cục của server Next là W3C TraceContext bọc lại sao cho `extract` trả
  nguyên context (bỏ mọi header đến) còn `inject` ghi `traceparent` của span hiện tại. Request đến web luôn mở trace gốc mới (cả
  span tự sinh của Next, vốn cũng đọc qua propagator toàn cục); lời gọi BFF tới gateway mang context của web. Lý do: ở compose
  không gì bỏ `traceparent` trước web (web publish thẳng `127.0.0.1:3001`), ở k3d Envoy bỏ thêm một lớp.
- **Bật ở đâu:** k3d `true` (`gateway.yaml`). Compose `true`: gateway compose chỉ publish trên `127.0.0.1:8080` và mạng compose
  của project, web chỉ inject context của chính nó; tiến trình trên máy (`curl`, k6, smoke) gửi `traceparent` thì chọn được
  trace id của request đó, chấp nhận ở lab (threat model WEB-24); đổi lại có trace web → gateway ở compose, nơi bộ `obs` hay
  chạy nhất. Cloud (giai đoạn 7): chỉ bật khi biên vào bỏ các header này như Envoy ở đây.
- ADR-0011 §3 ("HTTP `otelhttp` dùng propagator rỗng") thành mặc định khi tắt; `trace_id` trong problem response vẫn là trace
  id của span gateway, giờ có thể là trace của web.

## 8. Lỗi web tới GlitchTip

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| `@sentry/nextjs` cả trình duyệt và server | Đủ tính năng Sentry | SDK trình duyệt lớn hơn phần ngân sách còn lại (login tải lần đầu còn 3,3 kB), kể cả tải lười, vì ngân sách tính cả chunk tải lười |
| **Reporter tự viết ở trình duyệt, `@sentry/nextjs` chỉ ở server** | Vài trăm byte ở client; server kiểm và che mọi trường ở một chỗ | Tự parse stack, tự gắn debug ID |
| Chỉ báo lỗi server | Không code client | Mất mục tiêu "lỗi client hiện trong GlitchTip với stack đã map" |
| Tunnel Sentry chuẩn (client dựng envelope có DSN, server chuyển) | Theo mẫu của Sentry | Client phải biết DSN; server phải kiểm envelope tuỳ ý do client dựng |
| **Client gửi báo cáo JSON nhỏ, server dựng event** | Client không cần DSN; schema đóng, kiểm bằng zod | Không dùng lại được SDK trình duyệt |

### Quyết định

- **Trình duyệt** (`web/instrumentation-client.ts`, chạy trước hydrate; logic ở `web/features/monitoring/`): lắng nghe `error`
  và `unhandledrejection` của `window`; error boundary (`app/error.tsx`, `global-error.tsx`, `components/shell/route-error.tsx`)
  và nhánh `catch` của `loadHls()` trong `player-pool.ts` (mục 3) gọi cùng hàm báo, sau khi `reloadOnceOnSkew` không tải
  lại. Báo cáo gửi `POST /monitoring` (`fetch` `keepalive`, thân là chuỗi JSON với `Content-Type: text/plain`, kiểu
  CORS-safelisted, cùng origin):

  ```json
  {"name": "TypeError", "message": "…", "stack": "…", "path": "/v/…", "debug_ids": {"<URL chunk>": "<debug ID>"}}
  ```

  `path` chỉ là pathname (không query, không fragment); `debug_ids` lấy từ `globalThis._debugIds` (mục 9), chỉ các chunk có mặt
  trong `stack`, URL bỏ query. Tối đa 10 báo cáo mỗi lần tải trang, bỏ báo cáo trùng (cùng `name`, `message`, frame đầu). Server
  trả 404 (tắt báo lỗi) thì ngừng gửi tới hết trang. Client không biết DSN, không gửi cookie hay header thêm; không có SDK nào
  của Sentry trong bundle trình duyệt (`size-limit` bắt nếu có).
- **`POST /monitoring`** (`web/app/monitoring/route.ts`, logic ở `web/server/sentry/` có `import "server-only"`): đi qua proxy như
  mọi route (CSRF: `Sec-Fetch-Site: same-origin`). `SENTRY_DSN` rỗng → 404. Thân quá 32 KiB → 413; không phải JSON hay sai schema
  zod (`name` ≤ 200, `message` ≤ 1 000, `stack` ≤ 16 000 ký tự, `path` ≤ 500, `debug_ids` ≤ 64 mục) → 400. Quá **20 báo cáo mỗi
  phút** của tiến trình (bộ đếm trong bộ nhớ, không theo IP: ở k3d mọi client chung tối đa hai IP, RL-1) → 429; đây là ngân
  sách riêng của báo cáo trình duyệt (mỗi trang tối đa 10 báo cáo, lab một người dùng). Hợp lệ → server dựng event và trả
  **202** ngay, không chờ GlitchTip: GlitchTip chậm hay chết không làm request treo.
  - Event: `platform: javascript`, `level: error`, `exception` một giá trị (`type` = `name`, `value` = message đã che, frame từ
    `stack` đã parse theo dạng của Chromium, WebKit, Firefox), `request.url` = `APP_ORIGIN` + `path` (không query), tag
    `service=web`, `runtime=browser`, `route` (template của mục 11 hay `other`), `release` = `SVP_BUILD_ID`, `environment` =
    `SENTRY_ENVIRONMENT`, `debug_meta.images` = `{type: sourcemap, code_file: <URL chunk>, debug_id}` cho mỗi chunk của
    frame có debug ID và có URL cùng origin dưới `/_next/static/`. Không trường nào khác của báo cáo vào event.
  - Gửi bằng SDK server (`captureEvent`), nên đi qua cùng `beforeSend` (luật che) với lỗi server, nhưng **không** tính vào
    ngân sách 60 event/phút của lỗi server: bộ giới hạn đếm riêng theo loại, event có tag `runtime=browser` (chỉ route này đặt)
    đã được route đếm. Báo cáo rác vì vậy tối đa 20 mỗi phút và không đẩy được lỗi server của web ra khỏi ngân sách của nó;
    phương án lui bên dưới dùng cùng ngân sách 20. Mọi thứ SDK tự gắn từ request `/monitoring` (header, cookie, IP, thân) bị
    bỏ. SDK server giữ nguyên `platform` và `debug_meta` của event dựng tay: **đã xác nhận** (test với transport trong bộ nhớ
    của SDK thật, và GlitchTip ở k3d map được frame theo `debug_meta`, mục Kết quả phần C), nên phương án lui (POST envelope
    thẳng tới endpoint envelope của GlitchTip suy từ `SENTRY_DSN`) không cần.
- **Server** (`web/instrumentation.ts`, chỉ runtime Node): `@sentry/nextjs` `init` với `SENTRY_DSN` (rỗng: không init),
  `environment`, `release`; **không tracing** (không `tracesSampleRate`), không session, không Replay;
  **`enableOpenTelemetrySetup: false`** (tên của Sentry 11; bản trước gọi là `skipOpenTelemetrySetup`): Sentry không dựng
  provider, propagator hay context manager OTel của nó, OTel do mục 10 dựng. Mọi mục của `dataCollection` (Sentry 11 thay
  `sendDefaultPii`) tắt, integration mặc định của server tắt hết trừ `linkedErrors` (chúng vá `http`/`fetch`, thêm
  `sentry-trace`/`baggage` vào lời gọi BFF tới gateway, ghi console và dữ liệu request), nên server không có breadcrumb tự sinh.
  Không dùng `withSentryConfig` (không plugin build, không tự tải source map, không route tunnel của Sentry). Lỗi request báo qua
  `onRequestError` (`captureRequestError`); error boundary phía server và lỗi Route Handler, Server Action chưa xử lý cũng tới
  đó. `@sentry/nextjs` báo lỗi server khi không có `withSentryConfig`: **đã xác nhận** trên server standalone đã build với
  GlitchTip giả (lỗi render tới thành event), nên không cần bọc config.
- **Che theo WEB-9, một bộ luật cho cả lỗi server lẫn báo cáo trình duyệt** (`beforeSend`, `beforeBreadcrumb`), cùng tinh thần
  JWT-8 của service Go:
  - Bỏ hẳn `request` trừ `url` không query; bỏ `user`, `server_name`, cookie, header, thân, `extra` tuỳ ý.
  - Trong message, giá trị exception, breadcrumb, tag: che email và JWT bằng hai mẫu của ADR-0011 §7, chuỗi base64url 43 ký tự
    (sid, refresh token) và mọi query của URL (gồm chữ ký presigned `X-Amz-*`); `upload_url`, `form_fields` không bao giờ được
    đưa vào lỗi.
  - Breadcrumb fetch/XHR tới `UPLOAD_ORIGIN`, `MEDIA_ORIGIN` bỏ URL; breadcrumb console giữ message hằng của code.
  - Tag `trace_id`, `span_id` của span OTel đang chạy (lỗi server), để tìm cùng trace trong Tempo như service Go.
  - Giới hạn như `sentryx`: mỗi fingerprint 1 event/30 s; lỗi server cả tiến trình 60 event/phút; báo cáo trình duyệt 20 mỗi
    phút, đếm ở `/monitoring` (trên), không chung bộ đếm với lỗi server; phần vượt bỏ.
- **Compose:** service `web` nhận `SENTRY_DSN: ${SENTRY_DSN:-}` và `SENTRY_ENVIRONMENT` như service Go; DSN trỏ
  `glitchtip:8000`, tới được qua mạng `web` (mục 4). **k3d:** `errorTracking: true` (Secret `svp/sentry`, host
  `glitchtip.svp-obs:8000`), `SENTRY_ENVIRONMENT=k3d`.

## 9. Source map

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Debug ID của Turbopack, map xuất từ một stage của cùng bản build, tải lên bằng CLI của Sentry** | Khớp theo nội dung, không phụ thuộc URL hay release; cách duy nhất tài liệu GlitchTip mô tả | Polyfill debug ID thêm vài trăm byte mỗi chunk; công cụ tải chưa thử với GlitchTip |
| Release + URL (cách cũ của Sentry) | Không thêm byte vào chunk | Tài liệu GlitchTip hiện không mô tả |
| Tải trong CI | Map của đúng image phát hành | GlitchTip local không tới được từ runner GitHub; cần artifact và bước tải về |
| `glitchtip-cli` | Công cụ chính hãng | Binary "Beta" chưa có trên máy, cài thêm cần duyệt |

### Quyết định

- `next.config.ts`: `turbopack.debugIds: true` và `productionBrowserSourceMaps: true`, cho mọi bản build (cả `make web-check`,
  để ngân sách đo đúng thứ sẽ phát).
- `web.Dockerfile`, stage build: sau `pnpm build`, chuyển mọi `*.map` của `.next/static` sang thư mục riêng cùng bản JS của
  chúng, bỏ dòng `//# sourceMappingURL=` khỏi JS và CSS của `.next/static` (map "hidden": bundle không trỏ tới map nào), xoá
  `*.map` còn lại của `.next/standalone`. Stage **`sourcemaps`** (`FROM scratch`) chỉ chứa thư mục đó; stage runtime vẫn là
  stage cuối, không có file `.map` nào. Xuất bằng `docker build --target sourcemaps --output type=local,dest=<thư mục tạm>`
  với đúng context và build arg của image đang chạy, nên trúng cache của stage build và ra **đúng bundle** đó (mỗi build có id
  action ngẫu nhiên, mục 1, nên build lại không cache là bundle khác). Script kiểm ít nhất một debug ID của map có trong chunk
  mà web đang phục vụ trước khi tải, lệch thì dừng.
- **Tải lên:** `make web-sourcemaps` (GlitchTip của compose, `http://127.0.0.1:8000`) và `make k8s-web-sourcemaps` (của cluster,
  qua port-forward `127.0.0.1:8000` như `make k8s-ui-glitchtip`, `SVP_BUILD_ID` từ `web_build_id`), script
  `deploy/observability/glitchtip/sourcemaps.sh`: `pnpm --dir web exec sentry sourcemap upload <thư mục>`, **không**
  `--no-rewrite`: CLI đọc debug ID Turbopack đã ghi (`//# debugId=`, file để nguyên) và đặt nó làm header `debug-id` của từng
  file trong manifest của bundle; địa chỉ và đích qua biến `SENTRY_URL=http://127.0.0.1:8000`,
  `SENTRY_ORG=svp`, `SENTRY_PROJECT=svp` (CLI này không có cờ `--url`, `--org`, `--project`), token `SENTRY_AUTH_TOKEN` chỉ
  export trong subshell của đúng lệnh đó, không in, thư mục tạm và port-forward gỡ khi xong. GlitchTip hay token không có thì
  dừng và nêu lệnh cần chạy trước; mọi chunk của `/login` mà web đang phục vụ phải có debug ID trong bộ map xuất ra.
- **CLI `sentry` 0.45.0 (getsentry/cli) thành dev dependency trực tiếp** (thêm vào danh sách ADR-0016 §10): `@sentry/nextjs`
  11.8.0 không còn kéo `@sentry/cli` mà kéo gói npm `sentry` qua `@sentry/bundler-plugins`, nên gói đã nằm trong lockfile; pnpm
  chỉ đặt lệnh của dependency trực tiếp vào `node_modules/.bin`, nên `pnpm exec` cần nó là dependency trực tiếp. Ghim đúng bản
  đó, `--save-exact`; gói không có script cài đặt (`allowBuilds` không đổi); giấy phép FSL-1.1-Apache-2.0 (thành Apache-2.0 sau
  hai năm), dùng được cho lab. Không cài gì vào máy, chạy thẳng trên máy tới `127.0.0.1:8000`. Renovate gom `sentry` với
  `@sentry/nextjs` vào một nhóm `sentry` (`renovate.json`), có `separateMajorMinor: false` để bản major của gói này và bản minor
  của gói kia vẫn chung một PR: hai gói lên cùng nhau, như lúc ghim.
- CLI `sentry` với endpoint chunk upload và artifact bundle của GlitchTip 6.2.6. Buổi k3d ngày 2026-10-24 tải bằng
  `--no-rewrite`: chunk upload qua (CLI báo 31 file, GlitchTip lưu 63 blob) nhưng bước assemble bỏ hết (`assemble_artifacts:
  skipped 62 artifact(s) ... no debug-id header and no release`), không bundle nào được lưu, event trình duyệt giữ frame chưa
  map. Nguyên nhân, đọc trong code: với `--no-rewrite` CLI 0.45.0 gán debug ID rỗng cho mọi file và chỉ ghi header `debug-id`
  vào manifest khi debug ID khác rỗng; `apps/files/assemble.py` của GlitchTip bỏ mọi artifact không có header đó và không có
  release. Bỏ cờ thì CLI lấy debug ID có sẵn trong chunk (chỉ chèn vào file chưa có), nên vẫn là debug ID của Turbopack.
  Đường release không chọn: compose có `SVP_BUILD_ID` rỗng, và GlitchTip từ chối cả bundle khi `release` của manifest khác
  `version` của request. Kiểm trên compose ngày 2026-10-24: tải không cờ thì `sourcecode_debugsymbolbundle` có 31 dòng, đủ
  debug ID và map, có debug ID của chunk đang phục vụ; `glitchtip.e2e.ts` xanh ở Chromium và WebKit (10 và 13 frame map về
  `turbopack:///[project]/…`), tải lại cùng bản build vẫn 31 dòng và spec vẫn xanh; tải bằng `--no-rewrite` thì spec đỏ ở cả
  hai trình duyệt như buổi k3d. GlitchTip assemble sau khi upload đã trả lời và không có API đọc lại bundle, nên script chỉ
  báo đã gửi; kiểm thật là spec `glitchtip.e2e.ts` (`SVP_E2E_GLITCHTIP=1`). Trên k3d (buổi thứ hai, 2026-10-24, bản build
  `dev-455d602734c5`): `make k8s-web-sourcemaps` gửi 31 file, log GlitchTip không còn dòng `skipped`, spec xanh ở Chromium
  (10/10 frame map) và WebKit (13/13), `make drill-k8s-web-obs` đọc lại hai event qua API: PASS.
- **Token ghi:** bootstrap GlitchTip (`bootstrap.py`, dùng chung compose và k3d) tạo APIToken riêng nhãn **`svp-sourcemaps`**,
  scope tối thiểu để tải: **`project:releases`** (GlitchTip chưa ghi scope nào; thiếu thì thêm `project:write` và ghi lý do),
  không đụng token đọc `svp-drill` của diễn tập. Compose: `make glitchtip-init` thêm `SENTRY_SOURCEMAPS_TOKEN` vào `.env` khi
  thiếu hay rỗng (`.env.example` có dòng rỗng kèm comment). k3d: `deploy/k8s/glitchtip-init.sh` ghi Secret
  `svp-obs/glitchtip-sourcemaps`, khoá `SENTRY_SOURCEMAPS_TOKEN`, không vào `.env`, không in. Idempotent như token hiện có.
- **Image phát hành (CI):** map của image GHCR phải từ chính lượt build trong CI, mỗi kiến trúc một bộ (mục 1). Chưa làm ở phần
  C; hiện thực ở giai đoạn 6b (sửa 2026-10-28, [ADR-0021](0021-deferred-verification-stage6b.md) §6, thay cách "giai đoạn 7,
  `REV=<commit>`" cũ): chân build `web` của `images.yml` xuất stage `sourcemaps` ngay sau image cùng cache, kiểm debug ID của
  chunk image có trong bộ map, và ở lượt phát hành upload artifact `web-sourcemaps-<arch>` kèm file `image-digest` sau bước push.
  Commit không đủ để nhận bản build (một commit có thể build lại thành digest khác), nên `deploy/ci/gitops-sourcemaps.sh` chọn lượt
  có `image-digest` bằng manifest con `linux/amd64` của digest đang chạy, rồi `make k8s-web-sourcemaps SOURCEMAPS_DIR=<thư mục>`
  tải thư mục đó, vẫn kiểm mọi chunk `/login` đang phục vụ có debug ID trong bộ map. Trên runner: lượt trên nhánh chưa có artifact
  khớp (bản phát hành build trước khi `images.yml` xuất artifact), kiểm ở lượt `gitops` trên `main` sau merge (D5).

## 10. OTel ở server Next

- `web/instrumentation.ts`, trong `register()`, chỉ khi `NEXT_RUNTIME === "nodejs"`: `NodeSDK` của `@opentelemetry/sdk-node` với
  exporter OTLP gRPC trace và metric tới `OTEL_EXPORTER_OTLP_ENDPOINT` (rỗng: không dựng exporter, như `internal/telemetry` của
  Go; test không gọi cổng đoán sẵn), periodic reader **15 s** như service Go (mặc định của JS là 60 s), resource
  `service.name=web`, `service.version` = `SVP_BUILD_ID` khi có, `service.instance.id` riêng mỗi tiến trình. Instrumentation
  `http` (server) và `undici` (fetch của BFF tới gateway). Propagator: W3C TraceContext chỉ inject (mục 7), không Baggage.
  Sampler theo `OTEL_TRACES_SAMPLER`, mặc định `parentbased_always_on` như Go, bọc trong sampler lọc đường (bên dưới). Dựng
  OTel trước `Sentry.init` (mục 8).
- **Không ghi dữ liệu nhạy cảm vào span:** không bật ghi header (`headersToSpanAttributes` để trống); bỏ query khỏi mọi thuộc
  tính URL (`url.query`, `http.target`, `url.full`) của span server lẫn client; không đặt id người dùng, sid, token, `upload_url`
  vào span. Next tự mở span `BaseServer.handleRequest` cho mọi request với `http.target` = `req.url`, gồm cả query
  (`server/base-server.js` dòng 463–468), ngoài tầm cấu hình của instrumentation `http`; nên việc bỏ query nằm ở một span
  processor (`onStart`) áp cho mọi span, không chỉ ở hook của instrumentation.
- **Không span** cho `/healthz`, `/_next/static/*`, `/favicon.ico`, `/monitoring`, `/rum` (như gateway bỏ probe): nhiều mà không
  có giá trị điều tra. Lọc bằng một **sampler** bọc ngoài sampler chính: span gốc có đường (`url.path`, hay `http.target` bỏ
  query) thuộc danh sách thì không ghi; span con (của Next, của undici) theo cha nên cũng không ghi. Chỉ dùng
  `ignoreIncomingRequestHook` của instrumentation `http` thì không đủ: span của Next khi đó thành gốc và mỗi probe vẫn ra một
  trace. Test: sampler nhận thuộc tính của span Next (`http.target`) và của instrumentation (`url.path`) cho mỗi đường của danh
  sách đều trả không ghi; đường khác vẫn ghi.
- Metric HTTP của instrumentation giữ tên mặc định của version ghim, không thêm nhãn route; mọi rule và dashboard hiện có lọc
  `service_name="gateway"` nên không lẫn.
- Log của web vẫn chỉ ra stdout (không OTLP): exporter log OTLP không có trong danh sách ADR-0016 §10. Loki không có dòng nào của
  web; đọc bằng `make logs SVC=web` hay `kubectl logs`.
- Compose: `web` nhận `x-telemetry-env` như service Go (`OBS=off` tắt được) và tới `otelcol` qua mạng `web` (mục 4).

## 11. RUM

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **`web-vitals` → `sendBeacon` tới route cùng origin → histogram OTel** | Cùng đường Collector, Prometheus, Grafana; không mở gì ra trình duyệt | Endpoint không xác thực, ai cũng bơm được số |
| OTel SDK trình duyệt | Trace từ trình duyệt | SDK còn 0.x, lớn (ADR-0016 §11 dời) |
| Nhãn `rating` | Đọc thẳng tỉ lệ tốt/kém | Gấp ba số series; suy được từ bucket nếu biên bucket trùng ngưỡng |

### Quyết định

- **Client** (`web/features/rum/`): `web-vitals` bản chuẩn (không `attribution`), `onLCP`, `onINP`, `onCLS`, `onFCP`, `onTTFB`
  (FCP, TTFB gần như không thêm byte vì dùng chung phần lõi). Gom các số đo đã chốt, gửi **một beacon** khi trang chuyển
  `hidden` (`visibilitychange` trên `window`, pha bubble): `navigator.sendBeacon("/rum", <chuỗi JSON>)` (kiểu `text/plain`,
  CORS-safelisted), không được thì `fetch` `keepalive`. **Không gửi ở `pagehide`:** `web-vitals` 6.2.3 chỉ báo giá trị cuối
  của CLS (0 với trang không dịch chuyển) và INP từ listener `visibilitychange` pha capture của chính nó, mà khi rời trang
  `pagehide` đến **trước** `visibilitychange` → hidden (thứ tự "unload a document" của HTML), nên beacon gửi ở `pagehide` chỉ
  có LCP, FCP, TTFB: buổi k3d đầu ngày 2026-10-24 (beacon còn gửi ở `pagehide`) không có series CLS nào trong Prometheus. Gửi ở
  `hidden`, sau listener capture của `web-vitals`, thì CLS và INP đã có: buổi thứ hai cùng ngày có 27 mẫu CLS và 37 mẫu INP
  trên 74 beacon. Trang vào bfcache cũng chuyển `hidden`; quay lại thì trạng thái giữ nên vẫn một beacon mỗi lần tải trang.
  **CLS chỉ đến từ trình duyệt Chromium:** WebKit 27.2 không có `layout-shift` trong `PerformanceObserver.supportedEntryTypes`
  (có `largest-contentful-paint`, `event`), và `web-vitals` bỏ qua loại không hỗ trợ, nên beacon của WebKit không bao giờ có
  CLS; p75 CLS trên dashboard là của Chromium. Thân:

  ```json
  {"path": "/v/…", "metrics": [{"name": "LCP", "value": 1830.4}, {"name": "CLS", "value": 0.02}]}
  ```

  `path` là pathname lúc tải trang (chuyển trang phía client không đổi nó: INP, CLS cộng dồn được gán cho trang vào đầu tiên);
  giá trị theo đơn vị của `web-vitals` (ms, CLS không đơn vị). Chỉ `global-error` không gửi (nó thay layout gốc, nơi
  reporter nằm); dưới `app/error.tsx` và boundary lồng nhau layout gốc vẫn còn, nên reporter vẫn gửi số đo của trang trước
  khi lỗi (dữ liệu đúng, không phải số đo của trang lỗi).
- **`POST /rum`** (`web/app/rum/route.ts`, logic ở `web/server/telemetry/` có `import "server-only"`): qua proxy và CSRF như
  mọi route (beacon cùng origin có `Sec-Fetch-Site: same-origin`). Thân quá **4 KiB** → 413; không phải JSON hay sai schema zod
  (`metrics` 1–5 mục, `name` ∈ `LCP`, `INP`, `CLS`, `FCP`, `TTFB`, mỗi tên tối đa một lần, `value` là số) → 400. Quá **600 beacon
  mỗi phút** của tiến trình → 429 (beacon không đọc response). Hợp lệ → **204**, kể cả khi bỏ:
  - `path` map sang template theo danh sách đóng: `/`, `/following`, `/login`, `/register`, `/me`, `/upload`, `/u/[handle]`
    (handle `^[a-z][a-z0-9_]{2,29}$`), `/v/[id]` (UUID dạng chuẩn). Không khớp → bỏ cả beacon, không có nhãn `other`.
  - Mỗi mục: giá trị âm hay vượt trần (LCP, INP, FCP, TTFB > 60 000 ms; CLS > 10) → bỏ mục đó. JSON không có NaN hay Infinity,
    nên `null` hay chuỗi là sai schema.
  - Không ghi id người dùng, sid, URL đầy đủ, User-Agent; route không ghi gì vào log.
- **Metric** (histogram OTel, aggregation explicit bucket qua View):

| Tên OTel | Đơn vị | Prometheus | Bucket |
| --- | --- | --- | --- |
| `svp.web.vital.lcp`, `svp.web.vital.fcp`, `svp.web.vital.ttfb` | `s` | `svp_web_vital_lcp_seconds_*`, `_fcp_seconds_*`, `_ttfb_seconds_*` | W: `[0.1, 0.2, 0.4, 0.8, 1, 1.5, 1.8, 2.5, 3, 4, 6, 10, 20]` |
| `svp.web.vital.inp` | `s` | `svp_web_vital_inp_seconds_*` | I: `[0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1, 2, 5]` |
| `svp.web.vital.cls` | (không) | `svp_web_vital_cls_*` | C: `[0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.25, 0.5, 1]` |

  Nhãn duy nhất ngoài resource là `route`. **Không nhãn `rating`**: biên bucket chứa đúng ngưỡng "tốt" và "kém" của web.dev (LCP
  2,5/4 s, FCP 1,8/3 s, TTFB 0,8/1,8 s, INP 200/500 ms, CLS 0,1/0,25), nên tỉ lệ mỗi mức đọc được từ `_bucket`. Số series:
  5 metric × 8 route × khoảng 13 bucket × số pod, vài nghìn là tối đa.
- **Dashboard `svp-web`** (`deploy/observability/grafana/dashboards/svp-web.json`, compose nạp cả thư mục, k3d qua ConfigMap của
  `svp-observability`): LCP, INP, CLS p75 theo route bằng `histogram_quantile(0.75, sum by (le, route) (increase(..._bucket[...])))`
  trên khoảng của dashboard (mẫu RUM thưa ở lab), số mẫu theo route.
- **SLO INP p75: chưa.** Mẫu ở lab chỉ đến từ e2e và vài lượt tay, ai cũng bơm được số (bên dưới); đặt SLO khi có tải k6 ở giai
  đoạn 6.
- **Rủi ro bơm số đo** (endpoint không xác thực, threat model WEB-21): ai mở được trang đều gửi được beacon tuỳ ý trong khoảng hợp
  lệ, kéo lệch p75. Chặn được: nhãn đóng (không tạo series mới), trần giá trị, thân 4 KiB, 600 beacon/phút mỗi tiến trình. Không
  chặn: số đo giả trong khoảng hợp lệ. Dashboard là chỉ báo, không phải căn cứ cảnh báo.

## 12. Kiểm và dời

**Kiểm ở phần C, trên máy:**

- Tĩnh, không cluster: `make check` (Go + web: lint, typecheck, Vitest, `next build`, size-limit), `make generate-check`,
  `make web-generate-check`, `buf breaking`, `make compose-config`, `make helm-check` (render bảy release, sáu release cũ khác
  trước đúng phần ADR này đổi), `deploy/k8s/check-image-digests.sh`, `make otelcol-validate`, `make slo-check`, `actionlint`,
  `bash -n` các script, hai lượt test Go và Vitest không cache (lượt của `make check` và một lượt thêm; giảm từ ba lượt của các
  phần trước để bớt tải máy 16 GB). Một chân image `web` thật qua cổng trivy (`build-image.sh web
  arm64`), image không có file `.map`.
- **Ngân sách bundle** của ADR-0016 §10 và ADR-0018 §11. Ước lượng lúc thiết kế: debug ID khoảng 1,5 kB gzip ở lớp tải lần đầu
  của login, `web-vitals` khoảng 2 kB, reporter và tải lại một lần dưới 1 kB, tổng khoảng 4 kB, trong khi login còn 3,29 kB và
  upload 4,48 kB, nên **có thể vượt**; vượt ở route nào thì việc hiện thực dừng, ghi số đo, và quyết bằng thay đổi ADR (nới giới
  hạn của route đó hay đổi cách làm, ví dụ bỏ debug ID). Không giấu byte bằng cách dời code ra ngoài phép đo: lớp 2 là số byte
  trình duyệt thật sự tải.
  - **Đo được:** `web-vitals` một mình thêm khoảng 4,8 kB gzip mỗi route (đo lúc thêm RUM), gấp đôi ước lượng. So với cuối phần
    B, lớp tải lần đầu tăng 7,8–8,4 kB mỗi route: login 196,71 → 204,55 kB, upload 195,52 → 203,5 kB, feed 311,73 → 320,12 kB,
    `/v/[id]` 305,52 → 313,73 kB; lớp route tăng 5,9–6,5 kB (login 71,35/80, upload 70,3/80, feed 186,91/200, `/v/[id]`
    180,52/200). Login và upload vượt 200 kB.
  - **Quyết định: nới có chủ đích lớp tải lần đầu của login và upload từ 200 lên 210 kB**; lớp route (80 kB) và mọi route
    khác giữ nguyên. Lý do: source map đã map (cần debug ID) và RUM là mục tiêu của phần C, không phải tính năng tuỳ chọn;
    `web-vitals` nạp lười sau sự kiện `load` nên không chặn LCP; hai cách đổi khác đều mất chức năng (bỏ debug ID thì GlitchTip
    không map được stack, mục 9; bỏ FCP, TTFB không bớt byte đáng kể vì dùng chung phần lõi). Còn khoảng 5,5 kB ở login và 6,5 kB
    ở upload; vượt 210 kB thì lại dừng và quyết như trên. ADR-0016 §10 (login) và ADR-0018 §11 (upload) ghi giới hạn mới.
- **Compose `core` một lượt:** `make up`, `make smoke`, `make web-e2e` (Chromium và WebKit): mốc hồi quy cho code web mới (báo
  lỗi, OTel, RUM, tải lại khi lệch bản).
- **Một buổi k3d đường dev** (`make k8s-up` build bảy image): `make k8s-smoke`; `make k8s-web-sourcemaps`; e2e qua
  `https://svp.localhost:8443` (cookie `__Host-Http-svp_sid` + `Secure`, WEB-6 dạng đầy đủ); lỗi cố ý ở trình duyệt (spec làm hỏng
  response `/api` bằng `page.route`, không thêm đường debug vào sản phẩm) hiện trong GlitchTip với frame đã map về `web/...`; một
  trace có span `service.name=web` và span gateway cùng trace id trong Tempo; series RUM LCP, CLS (INP khi có tương tác) trong
  Prometheus và p75 trên dashboard; header của `/login` và của một asset; Rollout `web` Healthy, 2 pod Ready trên hai node, PDB;
  pod web chỉ đọc, non-root, không token; từ container web Postgres đóng, gateway mở; PolicyReport của Kyverno (Audit) ghi image
  web dev chưa ký như sáu image kia; `kubectl top pod` một lần để biết (không phải số đo RAM chính thức); rồi `make k8s-down`.
- Script diễn tập viết ở phần C, chỉ `bash -n`: `drill-k8s-threats` thêm WEB-2, WEB-7, WEB-8, WEB-10, WEB-13 (mỗi ca có đối
  chứng) và phủ pod web ở FF-3, FF-4, IN-2; mục OPS-2 nhận thêm đúng HTTPRoute `svp/web` (`svp.localhost` tới `web`,
  `web-canary`) bên cạnh `svp/api` và `svp-data/s3`; `drill-obs-threats` thêm WEB-9.

**Dời giai đoạn 6b** (runner CI 16 GB hay VM thuê theo giờ, đủ RAM cho buổi k3d; không chạy trên máy 16 GB ở phần C):

- Cluster GitOps chạy image `web` đã ký từ GHCR (cần push, CI phát hành, PR promote merge) và Kyverno Enforce từ chối image web
  chưa ký; source map của image CI (artifact theo kiến trúc, mục 9). Kết quả ([ADR-0021](0021-deferred-verification-stage6b.md)
  kịch bản `gitops`, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534), 2026-10-28): D3 đạt (7/7 bản phát hành đã ký kéo ẩn danh, 25/25 Application Synced/Healthy,
  Application `web` Healthy, e2e 64/64 hai trình duyệt); D4 đạt (manifest con amd64 của web bị rule chữ ký từ chối); D5 (source
  map của image CI) kiểm sau merge, lượt trên nhánh ghi `skipped` đúng quy tắc.
  Trên cluster dev (runner, 2026-10-25): `make k8s-web-sourcemaps` 32 map, 15 chunk `/login` có debug ID thuộc bản build đang
  chạy; event GlitchTip của e2e có 10/10 (Chromium) và 13/13 (WebKit) frame map về mã nguồn ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985),
  [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)).
- Canary của web dưới traffic diễn tập: promote bản tốt, abort bản lỗi, số 404 của `web-asset` và số lần client tải lại. Canary của
  gateway dưới probe mới đạt hai lượt trên runner (ADR-0021 D18). Kết quả của web (2026-10-28, `make drill-k8s-web-canary`,
  [40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955)): build B cùng nguồn khác `SVP_BUILD_ID` qua 25 %, 50 % và promote sau 128,9 s; bản lỗi (`GATEWAY_URL` tới Service
  không có, BFF trả 502) bị phân tích abort 83,4 s sau khi nhận traffic, route về 100/0, pod stable không đổi; build A trả về bằng
  canary thứ hai, promote 127,4 s. Tab cũ mở trước canary gặp lệch bản thật (action 409, chunk 404, `deploymentId` khác) và tải lại
  2 lần; không client nào tải lại quá 2 lần mỗi canary; `web-asset` 404: 0; Server Action 409 22,6 % (mục 1); không pod web nào
  restart.
- `make drill-k8s-threats` và `make drill-obs-threats` chạy đủ, gồm các ca WEB mới. Ghi chú 2026-10-24: `drill-k8s-threats` đã chạy
  đủ trên cluster dev ở buổi k3d giai đoạn 6 (16/16 mục PASS ở hai lượt, gồm WEB-2, WEB-7, WEB-8, WEB-10, WEB-13; ADR-0020); còn
  `drill-obs-threats` (WEB-9) và cluster GitOps. Kết quả trên runner (ADR-0021 D7, D8): `drill-obs-threats` đạt mọi mục ở
  `compose-obs` ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276); WEB-9: đối chứng có dữ liệu của web ở GlitchTip, Tempo, Prometheus, không giá trị nào
  của form, phiên hay chữ ký); `drill-k8s-threats` 16/16 mục PASS trên cluster dev, gồm WEB-7 ([40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740)). Trên
  cluster GitOps (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534)): `drill-k8s-threats` 16/16 mục PASS.
- Đo RAM của cluster có web (lúc nghỉ, đỉnh) và chỉnh `resources` của web. Kết quả trên runner, cluster dev (ADR-0021 D2, D9):
  RAM nghỉ (b) đạt ở điểm 60 s hai lượt (MEM USAGE trừ `active_file` 6 084 và 5 972 MiB), đỉnh (a) 9 994 và 8 878 MiB không đạt
  ổn định 8,7 GiB, chấp nhận không cắt; `resources` của web giữ limit 384Mi, request 128Mi (mục 2). Cluster GitOps và số k6
  (2026-10-28, ADR-0021 D2, D9): working set web cao nhất 149 MiB trên cluster GitOps, 178 MiB ở mức k6 4 pod, `resources` giữ;
  RAM của cluster GitOps không đạt (b) (7 510 MiB ở 60 s), quyết định cắt hay ghi nhận còn mở.
- Cổng CI quét lỗ hổng của `web/pnpm-lock.yaml` (cùng ngưỡng CRITICAL như cổng image): trivy trong image chỉ thấy 14 gói npm vì
  Turbopack gộp dependency của server vào chunk (mục 1), nên CVE của các gói đó hiện chỉ có Renovate đỡ. Kết quả: đạt
  (2026-10-24, ADR-0021 mục 10, D10): `make web-lockfile-scan` trong job `web` của `ci.yml` đọc 997 gói npm của lockfile pnpm 12
  (gồm dev dependency), ca âm có CRITICAL (`minimist` 1.2.5) làm target exit 2; HIGH của cây dev `@lhci/cli` xử lý ở
  [ADR-0016](0016-web-client.md) §10.

**Không làm ở phần C:** Trusted Types report-only (ADR-0016 §6; cần đường nhận báo cáo CSP riêng, `/monitoring` không nhận),
trace từ trình duyệt (SDK OTel trình duyệt 0.x), log OTLP của web, SLO cho web.

## Kết quả phần C (đo ngày 2026-10-23 và 2026-10-24)

Điều kiện chung: MacBook (Mac14,7, 16 GB RAM, macOS 27.0), cắm điện, không Low Power Mode; Playwright 1.64.1 (Chromium
156.0.8078.4, WebKit 27.2), một worker, headless, không throttle mạng. Trước lượt đầu Docker vừa được dọn sạch (không image,
build cache hay volume nào), nên `make up` và buổi k3d đầu kéo và build lạnh. Volume MinIO mất trong khi Postgres native vẫn
giữ video `READY` của các ngày trước (hàng e2e compose bên dưới).

Thứ tự: kiểm tĩnh, test và compose `core` một lượt (2026-10-23); buổi k3d đường dev thứ nhất (2026-10-24, rạng sáng) đỏ ở hai
chỗ, source map không được GlitchTip lưu (mục 9) và RUM không có CLS (mục 11); sửa hai chỗ đó (`sourcemaps.sh` bỏ
`--no-rewrite`, beacon chỉ gửi ở `hidden`, seed e2e chỉ đếm video phát được, Renovate gom `sentry` với `@sentry/nextjs`), kiểm
bản sửa source map trên compose `OBS=lgtm` một lượt (mục 9), rồi buổi k3d thứ hai trên code cuối. Code Go không đổi sau lượt
test đầu; phần đổi sau buổi k3d đầu chạy lại các kiểm liên quan (hàng Kiểm tĩnh, Vitest).

| Kiểm | Kết quả |
| --- | --- |
| Kiểm tĩnh (2026-10-23) | Xanh: `make check` (gofmt, vet, golangci-lint, actionlint, `buf lint`/`build`, Go test, ESLint, Prettier, typecheck, Vitest, `next build`, size-limit), `make generate-check`, `make web-generate-check`, `buf breaking --against '.git#branch=main'`, `make compose-config`, `make helm-check`, `deploy/k8s/check-image-digests.sh` (mọi image bên thứ ba ghim digest), `make otelcol-validate`, `make slo-check`, `make renovate-check`, `deploy/ci/scan-gate.sh --check-ignorefile`. Sau các bản sửa (2026-10-24): `make web-check`, `make renovate-check`, `bash -n` của `sourcemaps.sh` và `seed.sh`, `make compose-config` xanh |
| Test Go (hai lượt `-count=1`, 2026-10-23) | Mỗi lượt 43 gói ok, 604 test cấp đầu, 1 282 PASS tính cả subtest, 4 SKIP cố định của `internal/objstore` (cần stack), 0 FAIL; lượt thứ hai 91 s |
| Vitest (Redis db 15, không skip) | 2026-10-23: hai lượt 68 file, 1 151 test. 2026-10-24 sau bản sửa RUM: `make web-check` và một lượt `--maxWorkers=2`, mỗi lượt 68 file, 1 153 test (thêm test thứ tự `pagehide` → `visibilitychange` và bfcache) |
| size-limit (gzip) | Feed 186,91/200 kB, tải lần đầu 320,12/330; login 71,35/80, 204,55/210; `/v/[id]` 180,52/200, 313,73/330; `/upload` 70,3/80, 203,5/210 (nới 210 kB và số trước, sau ở mục 12) |
| Compose `core` (2026-10-23) | `make up` 201 s (kéo và build lạnh); `make smoke` 58 bước (10 s). `make web-e2e` 56/60: 4 đỏ (`feed.e2e.ts:17`, `first-frame.e2e.ts:17`, cả hai trình duyệt) do dữ liệu: playlist HLS của mọi video từ trước buổi này trả 404 (volume MinIO đã xoá) mà seed vẫn đếm chúng, nên không tải video mới và test vuốt rơi vào video chết. Sau 14 lượt `make smoke` (thêm video phát được) chạy lại đúng hai test đó: 4/4 xanh. Seed đã sửa để chỉ đếm dãy video phát được từ đầu Khám phá; ca có video chết chưa gặp lại sau bản sửa. Khung đầu sau vuốt (lượt chạy lại, 20 lần): Chromium p50 26 ms, p95 95, max 96; WebKit 42, 127, 138. Container `web` 194 MiB/256 sau e2e (một lần `docker stats`; phần B 170,9) |
| Source map trên compose `OBS=lgtm` (2026-10-24) | Tải bằng `--no-rewrite`: GlitchTip bỏ hết (`skipped 62 artifact(s)`, 0 bundle), `glitchtip.e2e.ts` đỏ hai trình duyệt. Bỏ cờ: 31 bundle đủ debug ID và map, spec xanh ở Chromium (10 frame map) và WebKit (13); tải lại cùng bản build vẫn 31 bundle, spec vẫn xanh |
| `make k8s-up` | Buổi đầu 843 s (cluster và registry mới, build lạnh bảy image). Buổi thứ hai 715 s (cluster và registry mới, build cache Docker còn từ các lượt trước); Rollout `web` Healthy |
| `make k8s-smoke` | 58 bước, 11 s, cả hai buổi |
| `make k8s-web-sourcemaps` (buổi thứ hai) | 32 map của bản build `dev-455d602734c5`, 15 chunk có debug ID của `/login` đang phục vụ đều thuộc bộ map, CLI gửi 31 file, 11 s; log GlitchTip không có dòng `skipped` |
| `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` (buổi thứ hai, chế độ chứng cứ) | 70/70 trong 6,4 phút, không chạy lại test nào: Chromium 31/31 + 4/4 (`chromium-publishing`), WebKit 31/31 + 4/4. Gồm cookie `__Host-Http-svp_sid` + `Secure` (WEB-6), WEB-1, WEB-2, WEB-4, WEB-10, CSP, upload 60 s 1080p tới `READY` và gửi lại sau khi mất mạng, trang công khai, axe. `glitchtip.e2e.ts`: event có 10/10 (Chromium) và 13/13 (WebKit) frame map về `turbopack:///[project]/…`; với lỗi cố ý này (một title là object, React ném khi render) mọi frame nằm trong `react-dom` của Next, không có frame của code app. Khung đầu sau vuốt qua Envoy: Chromium p50 19 ms, p95 25, max 31; WebKit 221, 351, 458. Buổi đầu: 68/70, chỉ `glitchtip.e2e.ts` đỏ (chạy lại một lần, đỏ y hệt) |
| `make drill-k8s-web-obs` (buổi thứ hai) | trace PASS: trace có span của web (8), gateway (5), user-service, video-service, engagement-service (3 mỗi service). rum PASS: mọi series chỉ có nhãn `route` trong 8 template; LCP 74 mẫu, p75 0,31 s (theo route 0,25–0,36 s); CLS 27 mẫu, p75 0,008 (nội suy trong bucket đầu `[0, 0,01]`; `/me` 0,06); INP 37 mẫu, p75 20 ms (`/v/[id]` 125 ms); FCP, TTFB 74 mẫu, p75 0,27 s và 0,08 s. errors PASS: hai event đọc lại qua API. Buổi đầu: trace PASS, rum FAIL (không series CLS), errors FAIL |
| Kiểm tay qua Envoy (cả hai buổi, cùng kết quả) | `/login`: CSP có nonce, `'strict-dynamic'`, `frame-ancestors 'none'`; HSTS `max-age=63072000; includeSubDomains`; `private, no-store`. Asset `/_next/static/…`: `public, max-age=31536000, immutable`, `.map` 404, 0 `sourceMappingURL`. Form `/register` không JavaScript: 303 và `__Host-Http-svp_sid=…; Path=/; Secure; HttpOnly; SameSite=lax`. WEB-24: `traceparent` với id tự chọn tới `api.svp.localhost` → 401 với `trace_id` khác; tới `svp.localhost` `/` và `/api/feed/explore` có phiên → 200, id đã chọn có trong 0 dòng log gateway. Rollout `web` Healthy 2/2, một pod mỗi node; PDB `minAvailable: 1`, cho phép 1 disruption. Pod web: không token ServiceAccount, uid/gid 65532, root fs chỉ đọc (ghi → `EROFS`), drop ALL, seccomp `RuntimeDefault`, PSA `restricted`. Từ container web: Postgres, user-service 9101, Redpanda, MinIO, API server, `1.1.1.1` đóng; gateway, Valkey, Collector, GlitchTip mở. PolicyReport Kyverno (Audit): cả bảy image dev (gồm `web`, hai pod) `fail` cùng message prefix. CORS MinIO ở `s3.svp.localhost`: `Origin: https://evil.example` → 204 không `Access-Control-Allow-Origin`, `https://svp.localhost:8443` → đúng origin đó |
| `kubectl top pod -n svp` (một lần, buổi thứ hai, sau e2e; không phải số đo RAM chính thức) | web 119 và 130 MiB (5–8m CPU), gateway 16 MiB ×2, user-, video-, engagement-, feed-service 13–20 MiB, media-worker 50 MiB |

Số RUM đến từ khoảng 74 lần tải trang của e2e (Playwright headless, loopback, không throttle), không phải người dùng thật: chỉ
để thấy đường số đo chạy đủ, không dùng làm mốc hiệu năng. CLS chỉ có từ Chromium (mục 11). Chứng cứ của buổi k3d thứ hai
(report HTML, `results.json`, trace, video, ảnh màn, log mọi lệnh) và của buổi đầu (log nguyên nhân lỗi source map) nằm ở thư
mục làm việc của máy, không commit (repo public, khoảng 300 MB mỗi buổi).

**Chưa kiểm ở phần C:** các việc dời giai đoạn 6b ở mục 12 (cluster GitOps với image web đã ký, canary web dưới traffic, diễn tập
đầy đủ, đo RAM, cổng CI quét lockfile npm); CI build, ký và promote image `web` kiểm sau push. Kết quả của phần 1 giai đoạn 6b
(diễn tập, RAM, cổng lockfile) ghi ở từng gạch của mục 12; cluster GitOps và canary web của phần 3 (2026-10-28) cũng ghi ở mục 12,
source map của image CI kiểm sau merge.

## Hệ quả

- Được:
  - Web đi cùng một chuỗi build, quét (gồm gói npm), ký, promote, admission như sáu service; Kyverno không đổi.
  - Một trace đi từ server Next qua gateway xuống service mà client bên ngoài không chen trace context vào được ở k3d.
  - Lỗi trình duyệt và server tới GlitchTip với stack đã map, client không biết DSN, mọi trường đi qua một bộ luật che.
  - Số đo người dùng thật (LCP, INP, CLS, FCP, TTFB) theo route trong cùng Prometheus và Grafana, nhãn đóng.
  - WEB-13 đóng ở k3d: pod web chỉ tới gateway, Valkey, Collector, GlitchTip.
- Phải trả:
  - Chart chung thêm value (`httpRoute.name`, `httpRoute.sectionName`, `canaryLimits`, `preStopSleepSeconds`, PDB không HPA);
    thêm listener và Certificate.
  - Khoá Server Action trong Secret và `.env`; id action và bundle đổi theo mỗi build và theo kiến trúc, nên action hay chunk
    (gồm hls.js) tới bản build khác (lúc canary, tab cũ) làm trang tải lại một lần, mất nội dung form đang gõ hay vị trí
    trong feed.
  - Hai endpoint không xác thực (`/monitoring`, `/rum`) nhận được dữ liệu giả trong giới hạn; reporter và parse stack tự viết.
  - Session trong Valkey chung không mật khẩu (WEB-22); phiên mất khi Valkey khởi động lại.
  - Compose bật tin trace context: tiến trình trên máy chọn được trace id (WEB-24).
  - Lớp tải lần đầu của login và upload nới từ 200 lên 210 kB (mục 12), còn khoảng 5,5 và 6,5 kB cho tính năng sau.
- Xem lại khi:
  - Lên cloud (giai đoạn 7): Redis/Valkey có AUTH, ACL và TLS hay instance riêng cho session; biên vào bỏ trace context trước khi
    bật `TRUST_TRACE_CONTEXT`; asset ra bucket/CDN giữ nhiều bản (hết 404 khi lệch); map của image CI.
  - GlitchTip nhận được map theo cách khác debug ID, hay `glitchtip-cli` ổn định: xét bỏ polyfill debug ID (đỡ khoảng 1,5 kB).
  - Có tải thật (k6 giai đoạn 6): đặt SLO INP p75, HPA cho web, ngưỡng p99 canary theo số đo.
  - Số lần tải lại vì action lệch bản (đo 2026-10-28, kịch bản `web-canary`: 409 ở 22,6 % Server Action của canary, xem mục 1) là đáng kể, hay cluster có node khác kiến trúc (hai bản của một
    commit cùng `deploymentId` nhưng khác id action và chunk, nên Next không thấy lệch khi điều hướng và đường tải lại chỉ đỡ
    một lần): xét khoá cố định không bí mật lúc build để id action ít đổi (mục 1).

## Hiện thực ở

- Image `web` trong chuỗi cung ứng (§1): `deploy/docker/web.Dockerfile`, `deploy/ci/build-image.sh` (`SVP_BUILD_ID`),
  `deploy/k8s/k8s.mk`, `deploy/k8s/install.sh`.
- Release `web`, canary và lệch phiên bản (§2, §3): `deploy/k8s/values/services/web.yaml`, `deploy/helm/svp-service/`
  (`templates/canary.yaml`, `templates/httproute.yaml`, `values.yaml`), `deploy/k8s/values/argo-rollouts.yaml`,
  `web/features/monitoring/skew-reload.ts`.
- NetworkPolicy và session ở Valkey (§4, §5): `deploy/k8s/values/services/web.yaml`, `deploy/helm/svp-data/templates/valkey.yaml`.
- CORS ở k3d (§6, bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)): Job `s3-init` của `deploy/helm/svp-data/templates/s3.yaml`, `deploy/s3/init.sh`.
- Trace context từ web tới gateway (§7): `services/gateway/internal/httpx/middleware.go` (`TRUST_TRACE_CONTEXT`),
  `deploy/helm/svp-service/templates/httproute.yaml` (Envoy bỏ header trace của client), `deploy/k8s/values/services/gateway.yaml`,
  `deploy/compose/compose.yaml`.
- Lỗi web tới GlitchTip và source map (§8, §9): `web/server/sentry/`, `web/features/monitoring/reporter.ts`, `web/instrumentation.ts`,
  `web/instrumentation-client.ts`, `deploy/observability/glitchtip/` (`sourcemaps.sh`, `init.sh`, `bootstrap.py`),
  `deploy/k8s/glitchtip-init.sh`, `deploy/k8s/secrets.sh`.
- OTel ở server Next và RUM (§10, §11): `web/server/telemetry/` (`otel.ts`, `rum.ts`, `vitals.ts`), `web/features/rum/beacon.ts`,
  `deploy/observability/grafana/dashboards/svp-web.json`.
- Kiểm (§12): `web/e2e/glitchtip.e2e.ts`, `web/e2e/stack.ts`, `deploy/compose/drills/obs-threats.sh` (WEB-9),
  `deploy/k8s/drills/threats.sh`, `deploy/k8s/drills/traffic.sh`, `deploy/k8s/drills/web-obs.sh`, target `web-sourcemaps`,
  `k8s-web-*` của `Makefile` và `deploy/k8s/k8s.mk`.
