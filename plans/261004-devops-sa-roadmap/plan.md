# Short-video platform — lộ trình học DevOps + Solution Architect từ A tới Z

> Ngày lập: 2026-10-04
>
> Trạng thái: giai đoạn 0, 1 và 2 xong (2026-10-11); chặng G hoãn; tiếp theo là giai đoạn 3 (observability)

## Mục tiêu

Một hệ thống thật, làm xuyên suốt từ thiết kế, code, hạ tầng, vận hành tới cloud: nền tảng video ngắn mini (upload video, transcode HLS, feed, like/view). Mỗi giai đoạn có mục tiêu học, việc làm, tiêu chí xong đo được và ADR cho các quyết định.

## Nguyên tắc

- **Công cụ chọn theo hiện trạng ngành, có lý do** (mục Quyết định đã chốt); đổi công cụ thì viết ADR.
- **Một công cụ chính cho mỗi mảng, học sâu.** Công cụ thứ hai chỉ dựng để so sánh, kết luận bằng một ADR; không chạy song song hai công cụ cho cùng một việc lâu dài.
- **Mỗi giai đoạn kết thúc ở trạng thái chạy được và có số đo**, không dừng ở "đã cài".
- **Local trước, cloud sau.** Cloud dựng lên và xoá trong cùng buổi. AI viết Terraform/Helm/script và soạn lệnh; mọi lệnh chạm tài khoản AWS/GCP do người học tự chạy.
- **Máy 16 GB RAM:** chạy theo profile, không bật toàn bộ stack cùng lúc (xem mục Ràng buộc máy).
- **Gặp đâu học đó:** bài toán nào cần so sánh nhiều cách giải thì tách ra lab riêng trong `labs/`, đo xong đem cách thắng về project.

## Hệ thống

> Bảng dưới là phác thảo lúc lập plan. Thiết kế hiện hành ở [`docs/architecture.md`](../../docs/architecture.md); danh mục event đã chỉnh ở đó (mục 6, lý do ở ADR-0003).

| Service | Sở hữu dữ liệu | Giao tiếp |
| --- | --- | --- |
| `gateway` | — | REST/OpenAPI ra ngoài, gRPC vào trong; JWT, rate limit, timeout, circuit breaker |
| `user-service` | user, follow | gRPC; phát `user.followed` |
| `video-service` | metadata video, trạng thái | gRPC; presigned upload (MinIO/S3); outbox phát `video.uploaded` và `video.ready` |
| `media-worker` | — | Tiêu thụ `video.uploaded`, ffmpeg → HLS, phát `transcode.completed` / `transcode.failed` |
| `engagement-service` | like, view, bộ đếm | Tiêu thụ `view.recorded` |
| `feed-service` | read model feed | Tiêu thụ event, dựng bảng đọc (CQRS), cache Redis |

- **Dữ liệu:** mỗi service một database Postgres riêng, không service nào đọc database của service khác.
- **Repo:** monorepo `services/<tên>/`, dùng chung `proto/`, `deploy/`, `docs/`.

**Giả định quy mô** (để thiết kế và đo, không phải số thật):
- 100k người dùng hoạt động mỗi ngày;
- feed 1.000 request/giây lúc cao điểm;
- 1.000 video upload mỗi ngày, mỗi video tối đa 3 phút.

1.000 req/s là mục tiêu tải cho k6 (khoảng 50 lần cao điểm thật của 100k DAU); 100k DAU dùng để ước lượng dung lượng, băng thông, chi phí ([`docs/architecture.md`](../../docs/architecture.md) §3.3).

**SLO đề xuất:**
- feed p99 < 150 ms;
- upload khởi tạo thành công 99,9%;
- video 1 phút sẵn sàng phát trong p95 < 2 phút.

## Bản đồ kiến thức

| Mảng | Học chính | So sánh / tuỳ chọn | Giai đoạn |
| --- | --- | --- | --- |
| Backend | Go: `net/http`, gRPC, `pgx` + `sqlc`, `log/slog`, test với `-race`, `pprof` | — | 1 |
| API contract | Protobuf + `buf` (lint, breaking check), OpenAPI ở gateway | — | 0–1 |
| Dữ liệu | Postgres (migration bằng `goose`) ở giai đoạn 1; Redis từ giai đoạn 2 | — | 1, 2 |
| Messaging | Redpanda (Kafka API) | SQS/SNS (AWS), Pub/Sub (GCP) | 2, 7, 8 |
| Pattern | Outbox, saga dạng choreography, CQRS, idempotent consumer + DLQ, cache-aside + singleflight, rate limit, timeout/retry/circuit breaker/bulkhead, API gateway/BFF, backpressure | — | 2 |
| Container | Docker multi-stage, image distroless, docker compose | — | 1 |
| Kubernetes | k3d; Helm; **Gateway API + Envoy Gateway** (thay ingress-nginx đã ngừng bảo trì); cert-manager; probe, resource, PDB, HPA; KEDA (scale theo lag); NetworkPolicy; RBAC | Kustomize | 4 |
| GitOps / release | Argo CD (app-of-apps), Argo Rollouts (canary có phân tích từ Prometheus) | Flux (đọc) | 4 |
| CI | GitHub Actions | GitLab CI (tuỳ chọn) | 5 |
| DevSecOps | golangci-lint, gosec, gitleaks, trivy, syft (SBOM), cosign, Kyverno, Renovate | — | 5 |
| Instrument | **OpenTelemetry** (SDK trong service + Collector): chuẩn chung, học sâu nhất vì đổi backend không phải sửa code | — | 3 |
| Metric | Prometheus (PromQL) + Grafana, dashboard RED/USE; trên k8s dùng kube-prometheus-stack; Alertmanager | CloudWatch, Managed Prometheus của AWS/GCP | 3, 4, 7, 8 |
| Log | Loki (LogQL), log có `trace_id` | Elastic: gửi cùng dữ liệu OTel qua Collector để so sánh (1 cuối tuần, ADR) | 3 |
| Trace | Tempo (TraceQL) | Jaeger, X-Ray, Cloud Trace | 3 |
| APM | Grafana: service graph + RED sinh từ trace, nhảy qua lại metric ↔ trace ↔ log ↔ profile | Elastic APM (trong bài so sánh Elastic) | 3 |
| Error tracking | Sentry (gói SaaS miễn phí) | — | 3 |
| Profiling | Pyroscope | — | 3 |
| SLO / alert | Sloth (sinh rule Prometheus), cảnh báo theo burn rate qua Alertmanager | — | 3 |
| Uptime | blackbox exporter | Uptime Kuma | 3 |
| Reliability | k6, Chaos Mesh, Velero, backup/restore Postgres, runbook, postmortem | — | 6 |
| Service mesh | Istio ambient mode (mTLS, retry, metric, không sidecar) | Linkerd (đọc) | 6 (tuỳ chọn) |
| IaC | Terraform: module, remote state, nhiều môi trường | Pulumi (đọc) | 7, 8 |
| AWS | VPC, EKS (Karpenter, Pod Identity, Load Balancer Controller, ExternalDNS), ECR, RDS, ElastiCache, S3, CloudFront, MediaConvert, Route 53 + ACM, Secrets Manager + External Secrets, CloudWatch/AMP/AMG/X-Ray, Budgets, Organizations (thiết kế) | — | 7 |
| GCP | VPC, GKE Autopilot, Artifact Registry, Cloud SQL, Memorystore, GCS, Pub/Sub, Cloud CDN, Transcoder API, Workload Identity, Secret Manager, Cloud Monitoring/Trace | — | 8 |
| SA | Yêu cầu + NFR, ước lượng quy mô, C4, ADR, threat model (STRIDE), Well-Architected review, mô hình chi phí, DR (RPO/RTO), multi-region | — | 0, 9 |

**Cố ý không đưa vào:**
- **Ansible:** project không có VM cần cấu hình; khái niệm config management học qua Helm/Terraform.
- **Jenkins:** GitHub Actions thay thế, khái niệm pipeline dùng lại được.
- **Multi-cloud active-active:** chỉ thiết kế trên giấy ở giai đoạn 9.

Cần thì bổ sung sau.

## Các giai đoạn

Thời gian là ước lượng thô theo số cuối tuần, vừa học vừa làm.

### 0. Thiết kế (SA) — 1 cuối tuần

- **Làm:**
  - yêu cầu chức năng và NFR;
  - ước lượng quy mô (QPS, dung lượng lưu, băng thông);
  - sơ đồ C4 mức context và container;
  - ADR chia service và sở hữu dữ liệu;
  - file `.proto` và schema event;
  - threat model nhẹ.
- **Xong khi:** có `docs/architecture.md` + ít nhất 3 ADR, `buf lint` sạch.

### G. Nền tảng Go — 4 tuần, chạy song song với giai đoạn 0

> Hoãn từ 2026-10-11: người học chọn tập trung DevOps + SA trước. AI viết code Go từ giai đoạn 1; chặng G học lại sau, dùng code của project làm tài liệu.

Người học chưa biết Go, đã quen TypeScript/NestJS. Giai đoạn 0 không cần Go (trừ file `.proto`), nên học Go song song.

| Tuần | Học | Tài liệu | Bài tập |
| --- | --- | --- | --- |
| 1 | Cú pháp, kiểu dữ liệu, struct, slice/map, con trỏ, zero value, xử lý lỗi bằng giá trị trả về (không có exception) | A Tour of Go; Go by Example để tra | Các chương đầu của Learn Go with Tests |
| 2 | Package và module (`go.mod`), interface ngầm định (không có class/implements), test có sẵn (`go test`, table-driven test), `gofmt`, `golangci-lint` | Learn Go with Tests; Effective Go | API CRUD nhỏ bằng `net/http` + Postgres (`pgx`), có test |
| 3 | Goroutine, channel, `sync`, `context` (timeout, huỷ), race detector (`-race`) | Learn Go with Tests (phần concurrency) | Lab `rate-limiter` |
| 4 | gRPC + protobuf cơ bản, `log/slog`, graceful shutdown, Dockerfile multi-stage | Tài liệu gRPC-Go quickstart | Lab `cache-stampede` |

Khác biệt cần chú ý khi chuyển từ TypeScript:
- lỗi là giá trị, kiểm tra ngay sau mỗi lời gọi;
- không có class; dùng struct + method, interface do phía dùng khai báo;
- concurrency có sẵn trong ngôn ngữ (goroutine) thay cho async/await;
- ưu tiên thư viện chuẩn thay vì framework;
- chữ hoa đầu tên là public, chữ thường là private.

**Cách học:** AI đóng vai mentor. Người học tự viết code; AI gợi ý hướng, giải thích, review. AI chỉ viết thay khi được nhờ.

**Xong khi:** tự viết được API CRUD có test và chạy `-race` sạch; hoàn thành 2 lab `rate-limiter` và `cache-stampede` có README và số đo.

### 1. Service lõi bằng Go, chạy local — 3–4 cuối tuần

- **Làm:**
  - cài Go, khung monorepo;
  - `gateway` + `user-service` + `video-service` (metadata);
  - mỗi service một database, có migration; Redis chuyển sang giai đoạn 2 theo [ADR-0007](../../docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md) (giai đoạn 1 chưa có chỗ nào dùng nó);
  - unit test và integration test trên Postgres native;
  - golangci-lint + git hook;
  - Docker multi-stage, docker compose.
- **Xong khi:** `make up` chạy được luồng đăng ký → tạo video → đọc lại; `go test -race ./...` xanh.

### 2. Bất đồng bộ và pattern — 3 cuối tuần

- **Làm:**
  - Redis (chuyển từ giai đoạn 1, ADR-0007): rate limit ở gateway, cache feed;
  - Redpanda;
  - upload presigned lên MinIO; `media-worker` transcode bằng ffmpeg;
  - outbox; consumer idempotent + DLQ;
  - saga cho luồng upload: lỗi transcode thì media-worker phát `transcode.failed`, video-service chuyển `FAILED` và dọn file (bước bù);
  - `engagement-service` (bộ đếm gom ghi theo lô);
  - `feed-service` (CQRS + cache + singleflight);
  - rate limit ở gateway; timeout/retry/circuit breaker cho mọi lời gọi.
- **Xong khi:**
  - kill worker giữa chừng, video không mất và không xử lý trùng;
  - video mới vào feed trong thời gian đã định;
  - gửi trùng event không làm sai bộ đếm.

### 3. Observability — 3 cuối tuần

- **Làm:**
  - OpenTelemetry SDK trong mọi service + Collector;
  - local dùng image `grafana/otel-lgtm` (Collector + Prometheus + Loki + Tempo + Pyroscope + Grafana trong một container, chỉ dành cho dev);
  - dashboard RED/USE, lag của consumer, service graph sinh từ trace;
  - log có cấu trúc kèm `trace_id`, nhảy được từ trace sang log;
  - Sentry cho lỗi ứng dụng; Pyroscope cho profiling;
  - Alertmanager gửi Slack/Telegram; SLO bằng Sloth + cảnh báo theo burn rate;
  - bài so sánh: Collector gửi song song sang Elastic (Elasticsearch + Kibana + APM), kết luận bằng ADR.
- **Xong khi:** diễn tập từ một cảnh báo lần ra trace, ra log, ra lỗi trong Sentry trong vòng 5 phút.

### 4. Kubernetes local — 3 cuối tuần

- **Làm:**
  - k3d; Helm chart cho từng service;
  - Gateway API + Envoy Gateway + cert-manager;
  - observability tách thành các deployment riêng: kube-prometheus-stack, Loki, Tempo, Pyroscope, OpenTelemetry Collector (Helm);
  - probe, resource, PDB, HPA; KEDA scale `media-worker` theo lag;
  - NetworkPolicy, RBAC;
  - Argo CD app-of-apps; Argo Rollouts canary có phân tích tự động.
- **Xong khi:** đẩy code lên git thì Argo CD tự đồng bộ, và bản canary lỗi tự rollback.

### 5. CI/CD và DevSecOps — 2 cuối tuần

- **Làm:**
  - GitHub Actions chỉ build service có thay đổi;
  - image đa kiến trúc lên GHCR;
  - quét bảo mật: trivy, gosec, gitleaks;
  - tạo SBOM bằng syft, ký image bằng cosign;
  - Kyverno chỉ cho chạy image đã ký và đạt policy cơ bản;
  - Renovate; đánh version; promote image qua pull request GitOps.
- **Xong khi:** cluster từ chối image chưa ký hoặc có lỗ hổng nghiêm trọng.

### 6. Reliability — 2–3 cuối tuần

- **Làm:**
  - kịch bản k6 theo SLO (báo p95/p99);
  - Chaos Mesh: kill pod, làm chậm mạng, tắt Redpanda;
  - diễn tập backup/restore (Postgres + Velero);
  - runbook; game day + postmortem;
  - tuỳ chọn Istio ambient mode (mTLS giữa các service).
- **Xong khi:** có báo cáo tải, báo cáo chaos và RTO đo thật của lần restore.

### 7. AWS — 4–6 cuối tuần

- **Terraform:**
  - module network, eks, data, edge; remote state S3 + lock;
  - EKS + Karpenter + Pod Identity + Load Balancer Controller + ExternalDNS + External Secrets;
  - RDS, ElastiCache; S3 + CloudFront;
  - MediaConvert (dùng lại module của `media-sdk`); Route 53 + ACM.
- **Observability:** ADR chọn giữa tự dựng stack Grafana trên EKS, Amazon Managed Prometheus/Grafana + X-Ray, hoặc Grafana Cloud gói miễn phí. Code không đổi vì đã dùng OpenTelemetry.
- **CI:** đăng nhập AWS qua OIDC, đẩy image lên ECR.
- **Chi phí:** Budgets + tag; báo cáo chi phí chia theo dịch vụ.
- **Well-Architected review.**
- **Xong khi:** cả hệ thống chạy trên EKS và đạt SLO dưới tải k6; có báo cáo chi phí; destroy và quét không còn tài nguyên sót.

### 8. GCP — 3–4 cuối tuần

- **Làm:**
  - GKE Autopilot, Cloud SQL, Memorystore, GCS + Cloud CDN;
  - Pub/Sub (ADR: giữ Redpanda trong cluster hay dùng Pub/Sub);
  - Transcoder API, Workload Identity, Artifact Registry;
  - observability: Managed Service for Prometheus + Cloud Trace/Logging, so với stack tự dựng.
- **Xong khi:** đạt cùng tiêu chí như giai đoạn 7, kèm ADR so sánh AWS với GCP về chi phí, công vận hành và trải nghiệm.

### 9. SA capstone — 2 cuối tuần

- **Làm:**
  - tài liệu kiến trúc bản cuối;
  - mô hình chi phí ở 3 quy mô;
  - kế hoạch DR (RPO/RTO, multi-region: thiết kế trên giấy + dựng thử dạng pilot light);
  - review bảo mật và Well-Architected;
  - bản tóm tắt để trình bày.
- **Xong khi:** người khác đọc tài liệu là hiểu vì sao hệ thống được thiết kế như vậy và tốn bao nhiêu ở mỗi quy mô.

Tổng ước lượng: khoảng 8–10 tháng làm cuối tuần, đã tính chặng học nền Go.

## Ràng buộc máy (Apple M2, 16 GB RAM)

- **Chạy compose theo profile:**
  - `core`: service + Redpanda + MinIO;
  - `obs`: `grafana/otel-lgtm` (một container, nhẹ);
  - `obs-elastic`: Elasticsearch + Kibana + APM, chỉ bật trong bài so sánh, heap 1 GB.

  Không bật hai bộ observability cùng lúc.
- **Sentry dùng gói SaaS miễn phí,** vì bản self-host cần khoảng 16 GB RAM riêng cho nó.
- **Chạy native arm64.** Shell global đặt `DOCKER_DEFAULT_PLATFORM=linux/amd64` (phục vụ dự án khác), khiến mọi container, kể cả node k3d, chạy amd64 qua giả lập: chậm và tốn RAM. Project này gọi docker/compose/k3d qua `Makefile` với `env -u DOCKER_DEFAULT_PLATFORM`; image cho cloud build đa kiến trúc ở bước CI.
- **Không chạy song song k3d và compose.** Giai đoạn compose dùng Postgres/Redis native (5432/6379), mỗi service một database riêng. Giai đoạn k8s quyết định bằng ADR: tự vận hành Postgres/Redis trong cluster, hay trỏ ra bản native.

## An toàn cloud

- **AWS:** profile `anhnv-sso`. AI không chạy lệnh nào chạm account; người học chạy `sts get-caller-identity` trước mọi lần ghi; mỗi buổi kết thúc bằng destroy + quét tài nguyên sót.
- **GCP:** project riêng cho lab, cùng cách làm như AWS.
- **Budget alert bật từ ngày đầu ở cả hai cloud.**

## Lab liên quan

| Lab | Dùng ở giai đoạn |
| --- | --- |
| `rate-limiter`, `cache-stampede`, `hot-counter`, `outbox-events` | 2 |
| `distributed-cron-lock` | 2 (job dọn dẹp), 6 |
| `big-table-queries` | 6 |
| `idempotent-webhooks` | Ngoài project này (bài toán payment) |

## Tiến độ

- [x] Khởi tạo repo (2026-10-04): git, `CLAUDE.md` (mục tiêu, nguyên tắc, quy ước, chế độ mentor, an toàn cloud), repo private `anhnvcoder/short-video-platform`.
- [x] 0. Thiết kế (xong 2026-10-11).
  - Thiết kế và ADR [0001–0005](../../docs/adr/README.md) đã chấp nhận (2026-10-11): [`docs/architecture.md`](../../docs/architecture.md) gồm yêu cầu, NFR, ước lượng quy mô, C4 context/container, sở hữu dữ liệu, danh mục event, các luồng chính. Ba quyết định đã chốt:
    - 1.000 req/s là mục tiêu tải cho k6 (khoảng 50 lần cao điểm thật), 100k DAU để ước lượng; không nâng DAU (architecture.md §3.3);
    - `video.ready` do video-service phát qua outbox, media-worker chỉ phát `transcode.completed` / `transcode.failed`;
    - chưa tạo `video.failed`, `like.toggled` vì chưa có service nhận; thêm sau là message proto mới, không phá contract.
  - Hoàn tất ngày 2026-10-11: contract ở `proto/` (`buf lint` sạch) cùng [ADR-0006](../../docs/adr/0006-contract-ids-and-event-envelope.md) chốt ID là UUIDv7, event bọc theo topic của luồng thực thể, bố cục `proto/svp/<domain>/v1`, danh tính người gọi qua metadata `x-user-id`; threat model STRIDE ở [`docs/threat-model.md`](../../docs/threat-model.md); NFR "Độ tươi" và "Nhất quán" đã chốt.
- [ ] G. Nền tảng Go: hoãn từ 2026-10-11 khi đang ở tuần 1 (giao 2026-10-04, bắt đầu 2026-10-05). Bài giao và nhật ký review ở [`plans/261004-go-foundations/plan.md`](../261004-go-foundations/plan.md).
- [x] 1. Service lõi (xong 2026-10-11): `gateway`, `user-service`, `video-service` chạy bằng `make up` trên compose profile `core`; `make smoke` qua luồng đăng ký → đăng nhập → tạo video → đọc lại → follow/unfollow. Số đo: `make up` 8 s (image đã cache, gồm bootstrap Postgres và migrate); image `svp/gateway` 21,1 MB, `svp/user-service` 26 MB, `svp/video-service` 25,8 MB; `go test -race -count=1 ./...` 10 s (có integration test trên Postgres). `make check`, `buf breaking` và pre-commit hook sạch. Quyết định ở [ADR-0007](../../docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md): một Go module, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, code sinh ra được commit, phạm vi thu về luồng đồng bộ (Redis, outbox, presigned upload sang giai đoạn 2).
- [x] 2. Bất đồng bộ và pattern (xong 2026-10-11)
  - [x] Phần A, luồng upload bất đồng bộ (xong 2026-10-11), quyết định ở
    [ADR-0008](../../docs/adr/0008-async-upload-pipeline-stage2a.md):
    - Đã làm: Redpanda và MinIO trong compose profile `core` (topic tạo bằng container init, bucket `uploads`/`media`, user
      và policy theo service); `POST /videos` trả presigned POST, `POST /videos/{video_id}/complete` (`HEAD` rồi
      `PROCESSING` + outbox trong một transaction); outbox có relay khoá `pg_try_advisory_xact_lock`; consumer commit tay,
      retry có backoff, DLQ; media-worker (alpine + ffmpeg, ba lớp whitelist, mạng riêng không ra ngoài, chỉ đọc, 2 CPU/2 GB)
      transcode HLS 360p/720p/1080p + thumbnail; video-service chuyển `READY` + outbox `video.ready`, hoặc `FAILED` và dọn
      file (bước bù). `make smoke` chạy luồng upload tới `READY` và phát HLS; thêm `make test-stack`, `make clean-data` và ba
      target diễn tập.
    - Thời gian `CompleteUpload` → `READY` của video 60 s 1080p (`make measure-ready N=5`): 46,7 / 47,3 / 46,8 / 47,6 /
      46,7 s, p50 46,8 s, max 47,6 s (với N=5, p95 = max), **đạt** SLO p95 < 2 phút.
    - Diễn tập kill worker (`make drill-kill-worker`): `SIGKILL` media-worker sau 3 s ffmpeg chạy, video `READY` 91 s sau khi
      worker khởi động lại (khoảng 45 s chờ session timeout của consumer group rồi transcode lại), đúng một
      `transcode.completed`, outbox 2 dòng; video không mất, không xử lý trùng.
    - Diễn tập gửi trùng (`make drill-duplicates`): phát lại `transcode.completed` thì video-service bỏ qua; phát lại
      `video.uploaded` thì media-worker transcode lại (`transcode.completed` 1 → 2), video-service bỏ qua; trạng thái,
      `published_at`, outbox không đổi; playlist biến thể giống hệt, `master.m3u8` chỉ lệch BANDWIDTH (tối đa 0,20%).
    - RAM: lúc nghỉ redpanda 285–302 MiB / 1,5 GiB, minio 192–261 MiB / 512 MiB; media-worker khi transcode đỉnh 734 MiB /
      2 GiB, CPU đỉnh 208,7% (giới hạn 200%, phần vượt do cửa sổ lấy mẫu của `docker stats`).
    - Image: `svp/media-worker` 150 MB; `svp/gateway` 21,1 MB, `svp/user-service` 26,1 MB, `svp/video-service` 40,9 MB
      (từ 25,8 MB, thêm SDK S3 và franz-go). `make up` 10,2 s (image đã cache). `go test -race -count=1 ./...` 78,8 s, phần
      lớn là `internal/kafkax` 76,6 s (test retry, backoff, handler chạy lâu trên `kfake`). `make check`, `buf breaking`,
      `make test-stack` (integration test `objstore` chạy trên MinIO thật) sạch.
  - [x] Phần B, luồng follow → feed → like/xem (xong 2026-10-11), quyết định ở
    [ADR-0009](../../docs/adr/0009-engagement-feed-stage2b.md):
    - Đã làm: user-service phát `user.followed` / `user.unfollowed` qua outbox, chỉ khi cạnh đổi; engagement-service
      (like và `like_counts` đổi trong một transaction; `RecordView` produce thẳng `view.recorded`; consumer gom lô
      5.000 record/1 s, đếm đúng một lần nhờ offset lưu trong `svp_engagement` cùng transaction với bộ đếm; `GetStats`
      đọc theo khoá chính); feed-service (bản sao follow và video, fan-out on write bằng một câu `INSERT ... SELECT`
      dưới advisory lock theo tác giả, follow mới nhận 20 video gần nhất, dọn timeline quá 30 ngày mỗi giờ, feed
      following và khám phá phân trang keyset, page token mã hoá bằng `protowire`, tối đa 64 ký tự); `internal/kafkax`
      thêm consumer theo lô và header `dlq-group`; gateway thêm 5 route, ghép `stats` với timeout 100 ms; compose thêm
      hai service (256 MB, không publish cổng) và 4 topic. `make smoke` thêm follow → feed → like/view → unfollow; thêm
      `tools/fakefollows` và ba target `drill-duplicates-feed`, `drill-engagement-down`, `measure-freshness`.
    - Độ tươi (`make measure-freshness`, từ `published_at` tới dòng timeline cuối), **đạt** NFR p95 < 10 s ở cả hai mức:
      - 10.000 follower, N=10: 0,100 / 0,183 / 0,105 / 0,121 / 0,192 / 0,233 / 0,217 / 0,219 / 0,163 / 0,168 s,
        p50 0,168 s, p95 = max 0,233 s (với N < 20, p95 = max); relay outbox 0,045–0,176 s (chu kỳ poll 200 ms), giao
        2–9 ms, fan-out 45–69 ms. Nạp 10.000 follow 13,1 s (763 follow/s), dọn 16,0 s. Hai lần đo trước cho p95
        0,278 s và 0,402 s (lần viết công cụ); lệch do chu kỳ poll của relay, cùng bậc.
      - 200.000 follower (A7), N=3, đo một lần khi viết công cụ, không đo lại: 1,104 / 1,197 / 1,281 s, p50 1,197 s,
        p95 = max 1,281 s; fan-out 0,88–0,96 s (một transaction, tuyến tính theo số follower). Nạp 261,4 s (765
        follow/s), dọn 291,1 s.
    - Diễn tập gửi trùng (`make drill-duplicates-feed`): phát lại 5 `view.recorded` thì `view_count` vẫn 5,
      `like_counts` và `likes` giống hệt; phát lại `user.followed`, rồi cả follow, unfollow và `video.ready`, thì
      `follows`, `timeline`, `videos` giống hệt (so cả `created_at`, `updated_at`), video vẫn không có trong feed sau
      unfollow. Hai diễn tập của phần A vẫn xanh: `drill-kill-worker` (video `READY` 93 s sau khi worker khởi động lại,
      một `transcode.completed`) và `drill-duplicates`.
    - Diễn tập tắt engagement-service (`make drill-engagement-down`): feed following trả 200 trong 0,113 s, khám phá
      0,115 s, không item nào có `stats`; `PUT like` 504 sau 3,05 s (timeout gọi service 3 s của gateway); `/readyz`
      200; bật lại thì `stats` quay lại.
    - RAM lúc nghỉ (sau mọi diễn tập): engagement-service 9,9 MiB, feed-service 21,5 MiB / 256 MiB, user-service
      49,5 MiB, redpanda 471,9 MiB / 1,5 GiB, minio 256,1 MiB / 512 MiB; cả stack ~856 MiB. feed-service khi nạp follow
      đỉnh 20 MiB ở 10.000, 82 MiB ở 200.000.
    - Image: `svp/engagement-service` 32,9 MB, `svp/feed-service` 33,1 MB, `svp/user-service` 33,1 MB (từ 26,1 MB, thêm
      franz-go cho relay outbox); `svp/gateway` 21,2 MB, `svp/video-service` 40,9 MB, `svp/media-worker` 150 MB.
      `go test -race -count=1 ./...` 78,1 s, phần lớn vẫn là `internal/kafkax` 76,8 s. `make check`, `buf breaking`
      (`proto/` không đổi), `make smoke` (8,3 s), `make test-stack` sạch.
  - [x] Phần C, Redis, cache, rate limit, retry/circuit breaker, job dọn upload (xong 2026-10-11), quyết định ở
    [ADR-0010](../../docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md):
    - Đã làm: Redis native (gateway db 10 tiền tố `svp:gw:`, feed-service db 14 tiền tố `svp:feed:`, test db 15 qua
      `internal/redistest`, mọi khoá có TTL, không thêm container) bằng `go-redis` v9.23.0, gói `internal/redisx` (dial
      100 ms, đọc/ghi 50 ms); rate limit GCRA bằng một Lua script ở gateway, 7 lớp (`register`, `login-ip`, `login-email`,
      `upload`, `write`, `read`, `view-once` cho RL-3), 429 `RATE_LIMITED` + `Retry-After`, Redis lỗi thì login,
      register, upload đóng mềm bằng bộ đếm trong bộ nhớ, route ghi và đọc mở; cache trang đầu feed khám phá ở
      feed-service (TTL 5 s, singleflight); retry `UNAVAILABLE` cho method idempotent qua service config của grpc-go và
      circuit breaker `gobreaker` v2.4.0 cho mỗi service đích ở gateway, lỗi phụ thuộc (`DEPENDENCY_UNAVAILABLE`) không
      mở breaker; UP-7 (tối đa 3 video `UPLOADING` có form còn hạn mỗi user, 429 `TOO_MANY_UPLOADS`, migration `00003`
      hai index một phần); job dọn upload bỏ dở trong video-service (5 phút một lượt, quá 1 giờ thì xoá object và chuyển
      `FAILED`, advisory lock); feed-service lưu `title` đã trim. Thêm ba target `drill-rate-limit`,
      `measure-explore-cache`, `drill-upload-cleanup`; `drill-engagement-down` kiểm breaker; smoke và mọi diễn tập xoá
      khoá `register` ở db 10 trước khi chạy (chỉ lab local).
    - Rate limit (`make drill-rate-limit`): Redis tốt thì 5 lần login sai 401, lần 6 là 429 `RATE_LIMITED`, `Retry-After`
      360 s; 3 lần `POST /videos` 201, lần 4 là 429 `TOO_MANY_UPLOADS`. Redis không tới được (gateway trỏ tên miền
      `.invalid`): feed 200, like/unlike 204, lượt xem 202; 3 lần login sai 401 rồi 429, `Retry-After` 720 s (bộ đếm dự
      phòng, nửa ngưỡng); một dòng WARN `rate limit store unavailable, using fallback`. Dựng lại với Redis thật thì khoá
      quay lại db 10.
    - Cache khám phá (`make measure-explore-cache N=100`): 100 request đồng thời lúc cache trống đọc Postgres **1** lần
      (trước thay đổi là 100 theo cấu tạo), p50 191,2 / p95 206,2 / max 226,3 ms; 100 request tiếp theo trong TTL không
      đọc lần nào, p50 78,8 / p95 87,1 / max 88,0 ms.
    - Breaker (`make drill-engagement-down`): tắt engagement-service thì breaker mở sau 6 like (3,4 s); 10 lần like với
      breaker mở trả 503, chậm nhất 8,9 ms (tiêu chí < 100 ms; phần B là 504 sau 3,05 s); feed following 200 trong
      0,014 s, khám phá 0,024 s, không `stats`; `/readyz` 200; bật lại thì like 204 sau 1,1 s, breaker tự đóng.
    - Dọn upload (`make drill-upload-cleanup`, hạn 20 s, chu kỳ 5 s chỉ cho diễn tập): video bỏ dở `FAILED` 23 s sau khi
      tạo, object `uploads/<id>` đã xoá, một dòng log `upload abandoned`; video đã `CompleteUpload` cùng lúc vẫn `READY`.
    - Các diễn tập phần A, B chạy lại trên cùng một lần `make up` với code cuối, đều xanh: `drill-kill-worker` (video
      `READY` 91 s sau khi worker khởi động lại, một `transcode.completed`, outbox 2 dòng), `drill-duplicates` (playlist
      biến thể giống hệt, `master.m3u8` lệch BANDWIDTH tối đa 0,60%), `measure-ready N=5` (47,2 / 47,3 / 46,6 / 47,2 /
      47,3 s, p50 47,2 s, p95 = max 47,3 s; media-worker đỉnh 728 MiB, CPU 207,6%), `drill-duplicates-feed` (5 lượt xem
      thì `view_count` 1 theo RL-3, phát lại vẫn 1; follow, unfollow, `video.ready` phát lại không đổi dòng nào),
      `measure-freshness FOLLOWERS=10000 N=10` (0,338 / 0,331 / 0,163 / 0,296 / 0,267 / 0,232 / 0,264 / 0,352 / 0,195 /
      0,277 s, p50 0,267 s, p95 = max 0,352 s; relay 0,032–0,201 s, fan-out 0,117–0,151 s; nạp 10.000 follow 13,1 s, dọn
      15,4 s, sau đó `svp_feed` còn 0 follow của tác giả giả). `make smoke` xanh (lượt xem thứ hai trong 60 s không được
      đếm). Cả chuỗi đăng ký 14 tài khoản từ một IP, dưới burst 20.
    - RAM lúc nghỉ (sau mọi diễn tập): gateway 27,8 MiB, feed-service 25,0 MiB / 256 MiB, engagement-service 13,2 MiB,
      video-service 10,2 MiB, user-service 53,1 MiB, media-worker 11,1 MiB, redpanda 478,6 MiB / 1,5 GiB, minio
      277,4 MiB / 512 MiB; cả stack ~896 MiB. Redis native (gồm dữ liệu dự án khác) 6,9 MB, đỉnh 10,7 MB; db 10 còn 15
      khoá (11 `login-email`, 4 `upload`, trung bình 96 B, khoá nào cũng có TTL), db 14 và db 15 trống.
    - Image: `svp/gateway` 31,7 MB (từ 21,2 MB, thêm `go-redis` và `gobreaker`), `svp/feed-service` 43,5 MB (từ 33,1 MB,
      thêm `go-redis`), `svp/video-service` 40,9 MB (không đổi). `make up` 21,2 s (gồm build lại image đã đổi).
      `GOFLAGS=-count=1 make check` sạch (40 gói test, `internal/kafkax` 76,9 s, vẫn là gói lâu nhất), `buf breaking`
      sạch (`proto/` chỉ thêm comment), `make test-stack` sạch (test `objstore` chạy trên MinIO thật, không SKIP).
  - Đối chiếu "Xong khi" của giai đoạn 2:
    - Kill worker giữa chừng, video không mất và không xử lý trùng: **đạt**, `drill-kill-worker` (`SIGKILL` sau 3 s
      ffmpeg, `READY` 91 s sau khi worker khởi động lại, đúng một `transcode.completed`, outbox 2 dòng).
    - Video mới vào feed trong thời gian đã định: **đạt**, `measure-freshness` p95 0,352 s với 10.000 follower, dưới NFR
      10 s; trang đầu khám phá trễ thêm tối đa 5 s vì cache (khám phá không có NFR độ tươi riêng).
    - Gửi trùng event không làm sai bộ đếm: **đạt**, `drill-duplicates-feed` (`view_count`, `like_counts`, `likes`,
      `follows`, `timeline`, `videos` không đổi) và `drill-duplicates` (trạng thái, `published_at`, outbox không đổi).
    - Mục "Làm": Redis cho rate limit và cache feed, Redpanda, upload presigned và media-worker, outbox, consumer
      idempotent + DLQ, saga upload (bước bù `transcode.failed` → `FAILED` + dọn file, phần A), engagement-service gom
      lô, feed-service CQRS + cache + singleflight, rate limit ở gateway: đã làm và đo ở phần A, B, C. "Timeout/retry/
      circuit breaker cho mọi lời gọi" theo ADR-0010 mục 4 giới hạn ở **lời gọi gRPC** (chỉ gateway gọi gRPC, mọi lời gọi
      có deadline, có retry và breaker); hạn riêng cho lời gọi ngoài gRPC (Postgres trong relay, consumer, projector, dọn
      timeline; client Kafka và S3) để giai đoạn 3, cùng metric lag và cảnh báo.
- [ ] 3. Observability
- [ ] 4. Kubernetes local
- [ ] 5. CI/CD và DevSecOps
- [ ] 6. Reliability
- [ ] 7. AWS
- [ ] 8. GCP
- [ ] 9. SA capstone

## Quyết định đã chốt

- Domain: nền tảng video ngắn mini.
- Ngôn ngữ: Go; ML chỉ ở mức tối thiểu, nếu cần thì dùng Python riêng. Người học bắt đầu Go từ con số 0 (đã quen TypeScript/NestJS), học qua chặng G với AI làm mentor. Từ 2026-10-11: AI viết code Go, người học tập trung DevOps + SA, chặng G hoãn.
- Monorepo, mỗi service một database.
- Cloud: AWS EKS trước, GCP sau.
- Repo: `anhnvcoder/short-video-platform` trên GitHub, private, quản lý bằng `gh`.
- Docker runtime: Docker Desktop. Cấp cho VM khoảng 8–10 GB RAM và 6 CPU (Settings → Resources), chừa phần còn lại cho macOS, IDE và Postgres/Redis native.
- Công cụ do AI đề xuất theo hiện trạng ngành, lý do bên dưới. Ví dụ ban đầu của người học (ELK, APM) chỉ là ví dụ, không phải lựa chọn.

**Lý do chọn công cụ** (hiện trạng tháng 10/2026):

| Lựa chọn | Lý do |
| --- | --- |
| OpenTelemetry | Chuẩn chung cho metric/trace/log mà mọi backend (Grafana, Elastic, Datadog, AWS, GCP) đều nhận; học một lần, đổi backend chỉ đổi cấu hình Collector |
| Grafana LGTM (Loki, Grafana, Tempo, Prometheus) + Pyroscope | Mã nguồn mở, nhẹ (Loki chỉ index label nên chạy vừa máy 16 GB), một giao diện nối metric ↔ trace ↔ log ↔ profile; Prometheus/PromQL là kiến thức bắt buộc của DevOps; cloud nào cũng có bản managed tương thích |
| Elastic chỉ để so sánh | Mạnh ở tìm kiếm full-text và SIEM, phổ biến ở doanh nghiệp, nhưng nặng RAM; biết qua một bài so sánh là đủ cho hướng này |
| Sentry | Chuẩn de facto cho theo dõi lỗi ứng dụng (gom lỗi, gắn release, báo dev); bổ sung cho trace chứ không trùng |
| Gateway API + Envoy Gateway | ingress-nginx ngừng bảo trì từ 3/2026; Gateway API là chuẩn thay thế chính thức của Kubernetes; Envoy Gateway là bản triển khai thuần Gateway API của CNCF |
| Istio ambient (tuỳ chọn) | Service mesh phổ biến nhất, ambient mode bỏ sidecar nên nhẹ; bản stable của Linkerd không còn phát hành miễn phí |
| Redpanda | Học khái niệm Kafka (topic, partition, consumer group, offset) với một binary nhẹ |
| Argo CD, Kyverno, KEDA, Karpenter, External Secrets, cert-manager | Lựa chọn phổ biến nhất trong mảng của từng công cụ, tài liệu và cộng đồng lớn |
| Terraform | Phổ biến nhất, tài liệu AWS/GCP dùng nhiều nhất, đã có `templates/terraform-base`; OpenTofu tương thích nếu sau này cần |

## Môi trường máy (ghi ngày 2026-10-04)

- Go 1.27.1 cài qua Homebrew; `~/go/bin` đã có trong PATH (dotfiles).
- Docker Desktop: 8 CPU, khoảng 7,7 GB RAM, đủ cho chặng G và giai đoạn 0–2; nâng lên khoảng 10 GB khi tới giai đoạn 3–4.
- Đã có sẵn: kubectl, helm, k6, terraform, gcloud, gh (đăng nhập tài khoản `anhnvcoder`). Đã cài `buf` 1.73.0. Chưa có: k3d, kind, golangci-lint.
- Postgres native 5432, Redis native 6379.

## Câu hỏi mở

- Giữ file gốc bao lâu (50 hay ~25 TB/năm): chốt ở giai đoạn 7 (lifecycle S3) và giai đoạn 9 (mô hình chi phí).
- Trên cloud dùng chung một instance Postgres hay tách: chốt ở giai đoạn 7.
- Chi tiết ở [`docs/architecture.md`](../../docs/architecture.md) §10.
