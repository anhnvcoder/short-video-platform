# Short-video platform

Nền tảng video ngắn mini: upload video, transcode ra HLS, feed "đang theo dõi" và "khám phá", like, lượt xem. Mục đích là
học DevOps và Solution Architect: làm xuyên suốt từ thiết kế, code, hạ tầng, quan sát, độ tin cậy tới cloud. Mỗi giai đoạn kết
thúc bằng hệ thống chạy được, có số đo và có ADR cho các quyết định. Thiết kế và lý do nằm ở
[`docs/architecture.md`](docs/architecture.md).

## Chạy thử nhanh

Yêu cầu trên máy:

- Docker, và Go, Node, pnpm theo các version ghim trong repo (`go.mod`, `web/.nvmrc`, `packageManager` của `web/package.json`).
- Postgres và Redis chạy trên máy, không nằm trong compose: Postgres `127.0.0.1:5432`, Redis `127.0.0.1:6379`. Các bước dưới
  dùng database và db Redis riêng của từng service, mô tả ở [`CLAUDE.md`](CLAUDE.md).
- Công cụ dòng lệnh trên máy: `psql` (`make up` tạo role và database trên Postgres native), `redis-cli`, `curl`, `jq`, `openssl`
  và `ffmpeg` (`make smoke` sinh video thử và gọi API).

Từ gốc repo:

```sh
make help        # liệt kê mọi target
make env         # tạo .env (mode 600) với secret ngẫu nhiên; không bao giờ in giá trị
make up          # tạo role/database trên Postgres native rồi dựng stack compose: Redpanda, object storage, các service, web
make smoke       # luồng đầu-cuối qua gateway: đăng ký, upload tới READY, phát HLS, feed, like, follow
```

Mở `http://localhost:3001` (dùng đúng `localhost`, không dùng `127.0.0.1`: object store chỉ nhận CORS từ `localhost`). Gateway
ở `http://127.0.0.1:8080`. Gỡ stack bằng `make down`; `make down` giữ volume, dữ liệu còn nguyên.
Object store là service `s3` (compose và k3d): một endpoint tương thích S3 API (không phải AWS S3), hiện chạy RustFS (trước là MinIO);
code của service gọi nó qua `internal/objstore`.

Muốn xem thêm telemetry (Grafana, Alertmanager, GlitchTip) thì `make up OBS=lgtm`. Không dùng `OBS` thì chỉ chạy các service.
Chỉ chạy một bộ observability một lúc vì máy 16 GB RAM không đủ cho hai bộ.

Sổ lệnh đầy đủ (kiểm tra, diễn tập, k3d, cloud, CI) nằm ở [`CLAUDE.md`](CLAUDE.md), mục "Kiểm tra" và "Quy ước". Đừng chạy
`make up` và `make k8s-up` cùng lúc: mỗi bên từ chối khi bên kia đang chạy.

## Bản đồ thư mục

| Thư mục | Chứa gì, khi nào cần mở |
| --- | --- |
| `services/` | Sáu service Go, mỗi service một thư mục (xem bảng dưới). Mở khi sửa logic nghiệp vụ của một service. |
| `services/gateway/` | Biên REST/JSON: route, auth, rate limit, retry và circuit breaker tới gRPC, `openapi.yaml`. |
| `services/user-service/` | Đăng ký, đăng nhập, JWT, refresh token, hồ sơ, follow (database `svp_user`). |
| `services/video-service/` | Metadata video, presigned POST, `CompleteUpload`, job dọn upload bỏ dở (database `svp_video`). |
| `services/media-worker/` | Consumer transcode bằng ffmpeg ra HLS, không có database. |
| `services/engagement-service/` | Like, unlike, lượt xem gom theo lô (database `svp_engagement`). |
| `services/feed-service/` | Feed following (fan-out on write), feed khám phá có cache (database `svp_feed`). |
| `internal/` | Thư viện dùng chung của các service: kết nối Postgres và retry, Kafka, outbox, Redis, telemetry, gRPC, env. Mở khi một service cần một phần chung. |
| `proto/` | Contract `.proto` của gRPC và event, quản lý bằng buf. Sửa ở đây rồi chạy `make generate`. |
| `gen/` | Code Go sinh từ `proto/` (`gen/go`); commit cùng thay đổi, không sửa tay. Code sinh từ SQL (sqlc) nằm ở `services/*/internal/store`. |
| `tools/` | Công cụ nhỏ: `fakefollows` (tạo follow giả cho diễn tập), `jwtkey` (sinh khoá JWT). |
| `web/` | Web client Next.js và BFF (giai đoạn 5b): `app/` route, `server/` phía server, `features/`, `components/`, `e2e/` Playwright. |
| `deploy/compose/` | Stack compose `make up`, script smoke và diễn tập. |
| `deploy/docker/` | Dockerfile của service Go, media-worker và web. |
| `deploy/postgres/`, `deploy/redpanda/`, `deploy/s3/` | Bootstrap database, topic Kafka (compose), bucket, user, policy và CORS của object storage (RustFS, service `s3`). ACL Kafka của cluster k3d nằm trong chart Helm. |
| `deploy/observability/` | Collector, Prometheus và rule SLO, Alertmanager, Grafana LGTM, GlitchTip, Elastic (so sánh). |
| `deploy/k8s/` | Cluster k3d: script `install.sh`, `k8s.mk`, values, PSA, và thư mục `drills/` (diễn tập), `cloud/` (manifest cho cluster đo thật). |
| `deploy/helm/` | Chart Helm: `svp-service` (chung cho mọi service), `svp-cluster`, `svp-data`, `svp-observability`, `svp-policy` (Kyverno). |
| `deploy/argocd/` | Application và AppProject của Argo CD cho đường GitOps. |
| `deploy/k6/` | Kịch bản tải k6 theo SLO, chạy bằng image ghim. |
| `deploy/ci/` | Script của pipeline: build, quét, ký, attest, promote image. Phần lớn logic CI nằm ở đây, không nằm trong YAML. |
| `.githooks/` | Git hook `pre-commit` (gofmt, golangci-lint, buf lint, gitleaks); bật một lần bằng `make hooks`. |
| `.github/rulesets/` | Ruleset của nhánh `main` (check bắt buộc `ci-ok`, `images-ok`). |
| `.github/workflows/` | `ci.yml` (kiểm tra và stack), `images.yml` (image và chuỗi cung ứng), `verify.yml` (kiểm chứng dồn trên runner, chạy tay và hằng tuần). |
| `docs/architecture.md` | Thiết kế hiện tại: yêu cầu, ước lượng quy mô, C4, luồng chính, contract. |
| `docs/adr/` | Quyết định kiến trúc, mỗi quyết định một file (mục lục ở `docs/adr/README.md`). |
| `docs/runbooks/` | Một runbook cho mỗi cảnh báo mức page và các sự cố đã gặp. Mở khi có cảnh báo. |
| `docs/postmortems/`, `docs/rfc/` | Postmortem không đổ lỗi, và đề xuất một trang cho người không làm kỹ thuật. |
| `docs/threat-model.md` | Mối đe doạ theo mã (JWT-8, UP-8, RL-2, WEB-9…) và cách kiểm từng mối. |

Bảng service: database và Redis db của từng service nằm ở `CLAUDE.md`, không lặp ở đây.

## Thứ tự đọc gợi ý

1. [`docs/architecture.md`](docs/architecture.md) §1–§3: phạm vi, yêu cầu phi chức năng, ước lượng quy mô. Đọc để biết hệ thống
   nhằm làm gì và con số nào là giả định.
2. [`docs/architecture.md`](docs/architecture.md) §5 và §7: các container và luồng upload, feed, like.
3. [`docs/adr/README.md`](docs/adr/README.md), rồi các ADR theo giai đoạn ở mục dưới. ADR 0001 (ranh giới service) và ADR 0003
   (outbox, event) là nền của gần như mọi thứ khác.
4. [`docs/ci-cd.md`](docs/ci-cd.md) khi đọc một lượt chạy GitHub Actions: job nào chạy khi nào, vì sao skip, đọc kết quả ở đâu.
5. [`docs/threat-model.md`](docs/threat-model.md) khi làm bảo mật, và [`docs/runbooks/`](docs/runbooks/) khi có cảnh báo.
6. [`CLAUDE.md`](CLAUDE.md) khi cần một lệnh cụ thể: sổ lệnh đầy đủ và quy tắc an toàn (cloud, database) nằm ở đó.

## Các giai đoạn

| Giai đoạn | Nội dung | ADR chính |
| --- | --- | --- |
| 0 | Lộ trình, thiết kế: ranh giới service, REST ở biên và gRPC bên trong, outbox, presigned upload, feed fan-out | [0001](docs/adr/0001-service-boundaries-and-data-ownership.md) – [0006](docs/adr/0006-contract-ids-and-event-envelope.md) |
| 1 | Monorepo Go, luồng đồng bộ đầu-cuối qua gateway | [0007](docs/adr/0007-go-monorepo-toolchain-and-stage1-scope.md) |
| 2 | Upload bất đồng bộ tới HLS, engagement và feed, Redis cho rate limit và cache, retry và breaker | [0008](docs/adr/0008-async-upload-pipeline-stage2a.md), [0009](docs/adr/0009-engagement-feed-stage2b.md), [0010](docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md) |
| 3 | Quan sát: OpenTelemetry, LGTM, GlitchTip, SLO và cảnh báo burn rate | [0011](docs/adr/0011-observability-stage3.md), [0012](docs/adr/0012-elastic-vs-grafana-stage3.md) |
| 4 | Kubernetes trên k3d với Helm, Envoy Gateway, Argo CD, canary | [0014](docs/adr/0014-kubernetes-local-stage4.md), [0017](docs/adr/0017-gitops-capacity-media-worker-max2.md) |
| 5 | CI/CD và chuỗi cung ứng: image đa kiến trúc, ký, quét, Kyverno, promote bằng PR GitOps | [0015](docs/adr/0015-cicd-devsecops-stage5.md) |
| 5b | Web client Next.js (BFF, session, hồ sơ, upload từ trình duyệt, web trên k3d) | [0016](docs/adr/0016-web-client.md), [0018](docs/adr/0018-web-profiles-public-video-upload.md), [0019](docs/adr/0019-web-k3d-supply-chain-observability.md) |
| 6 | Độ tin cậy: k6 theo SLO, SLO web, backup và phục hồi Postgres, runbook, game day | [0020](docs/adr/0020-reliability-stage6.md) |

Các ADR sau giai đoạn 6 (kiểm chứng dồn trên runner, object store của đường local, CI trung lập nền tảng) có trong
[`docs/adr/`](docs/adr/).
