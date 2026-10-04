# Short-video platform — lộ trình học DevOps + Solution Architect từ A tới Z

> Ngày lập: 2026-10-04
>
> Trạng thái: chưa bắt đầu

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

| Service | Sở hữu dữ liệu | Giao tiếp |
| --- | --- | --- |
| `gateway` | — | REST/OpenAPI ra ngoài, gRPC vào trong; JWT, rate limit, timeout, circuit breaker |
| `user-service` | user, follow | gRPC; phát `user.followed` |
| `video-service` | metadata video, trạng thái | gRPC; presigned upload (MinIO/S3); outbox phát `video.uploaded` |
| `media-worker` | — | Tiêu thụ `video.uploaded`, ffmpeg → HLS, phát `video.ready` / `video.failed` |
| `engagement-service` | like, view, bộ đếm | Tiêu thụ `view.recorded`; phát `like.toggled` |
| `feed-service` | read model feed | Tiêu thụ event, dựng bảng đọc (CQRS), cache Redis |

- **Dữ liệu:** mỗi service một database Postgres riêng, không service nào đọc database của service khác.
- **Repo:** monorepo `services/<tên>/`, dùng chung `proto/`, `deploy/`, `docs/`.

**Giả định quy mô** (để thiết kế và đo, không phải số thật):
- 100k người dùng hoạt động mỗi ngày;
- feed 1.000 request/giây lúc cao điểm;
- 1.000 video upload mỗi ngày, mỗi video tối đa 3 phút.

**SLO đề xuất:**
- feed p99 < 150 ms;
- upload khởi tạo thành công 99,9%;
- video 1 phút sẵn sàng phát trong p95 < 2 phút.

## Bản đồ kiến thức

| Mảng | Học chính | So sánh / tuỳ chọn | Giai đoạn |
| --- | --- | --- | --- |
| Backend | Go: `net/http`, gRPC, `pgx` + `sqlc`, `log/slog`, test với `-race`, `pprof` | — | 1 |
| API contract | Protobuf + `buf` (lint, breaking check), OpenAPI ở gateway | — | 0–1 |
| Dữ liệu | Postgres (migration bằng `goose`), Redis | — | 1 |
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
  - mỗi service một database, có migration; Redis;
  - unit test và integration test trên Postgres/Redis native;
  - golangci-lint + git hook;
  - Docker multi-stage, docker compose.
- **Xong khi:** `make up` chạy được luồng đăng ký → tạo video → đọc lại; `go test -race ./...` xanh.

### 2. Bất đồng bộ và pattern — 3 cuối tuần

- **Làm:**
  - Redpanda;
  - upload presigned lên MinIO; `media-worker` transcode bằng ffmpeg;
  - outbox; consumer idempotent + DLQ;
  - saga cho luồng upload: lỗi transcode thì phát `video.failed` và dọn dẹp;
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

- [ ] 0. Thiết kế
- [ ] G. Nền tảng Go (song song với 0)
- [ ] 1. Service lõi
- [ ] 2. Bất đồng bộ và pattern
- [ ] 3. Observability
- [ ] 4. Kubernetes local
- [ ] 5. CI/CD và DevSecOps
- [ ] 6. Reliability
- [ ] 7. AWS
- [ ] 8. GCP
- [ ] 9. SA capstone

## Quyết định đã chốt

- Domain: nền tảng video ngắn mini.
- Ngôn ngữ: Go; ML chỉ ở mức tối thiểu, nếu cần thì dùng Python riêng. Người học bắt đầu Go từ con số 0 (đã quen TypeScript/NestJS), học qua chặng G với AI làm mentor.
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
- Đã có sẵn: kubectl, helm, k6, terraform, gcloud, gh (đăng nhập tài khoản `anhnvcoder`). Chưa có: k3d, kind, buf, golangci-lint.
- Postgres native 5432, Redis native 6379.

## Câu hỏi mở

- Không còn.
