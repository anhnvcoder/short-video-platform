# Short-video platform — lab học DevOps + Solution Architect

Nền tảng video ngắn mini (upload, transcode HLS, feed, like/view), làm xuyên suốt từ thiết kế,
code, hạ tầng, vận hành tới cloud. Mục đích là học; mỗi giai đoạn kết thúc bằng hệ thống chạy được,
có số đo và có ADR cho các quyết định.

Đọc trước khi làm bất cứ việc gì:

- [`plans/261004-devops-sa-roadmap/plan.md`](plans/261004-devops-sa-roadmap/plan.md): lộ trình, quyết định đã chốt,
  môi trường máy, tiến độ. Quyết định đã chốt thì làm theo; muốn đổi thì đề xuất kèm ADR.
- [`docs/architecture.md`](docs/architecture.md) và [`docs/adr/`](docs/adr/): thiết kế hiện tại và lý do.

## Nguyên tắc

- **Công cụ chọn theo hiện trạng ngành, có lý do.** Đổi công cụ thì viết ADR.
- **Một công cụ chính cho mỗi mảng, học sâu.** Công cụ thứ hai chỉ dựng để so sánh, kết luận bằng ADR.
- **Mỗi giai đoạn kết thúc ở trạng thái chạy được và có số đo**, không dừng ở "đã cài".
- **Local trước, cloud sau.** Cloud dựng lên và xoá trong cùng buổi.
- **Máy 16 GB RAM:** compose chạy theo profile, không bật hai bộ observability cùng lúc, không chạy
  song song k3d và compose.
- **Gặp đâu học đó:** bài toán cần so sánh nhiều cách giải thì tách thành lab riêng, đo xong đem cách
  thắng về project.

## Chế độ mentor

Người học ưu tiên học DevOps + SA.

- **Code Go** (service, lab): AI viết, kèm test và chạy đủ lệnh ở mục Kiểm tra. Mỗi lần giao code, tóm tắt
  cấu trúc và các chỗ đáng chú ý để người học đọc hiểu được.
- **Thiết kế** (`docs/`, ADR, `.proto`) **và hạ tầng** (compose, Makefile, Helm, Terraform, CI): AI soạn
  và giải thích lý do từng quyết định; người học duyệt.

## Quy ước

- **Ngôn ngữ lập trình:** Go, ưu tiên thư viện chuẩn; web client ở `web/` viết TypeScript (Next.js,
  [ADR-0016](docs/adr/0016-web-client.md)), chỉ dùng gói trong danh sách của ADR-0016 §10. Thêm dependency phải có lý do.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt; mọi thứ trong code (comment, log, tên test, error
  message, `.env.example`) viết tiếng Anh.
- **Comment trong code** tự đủ nghĩa: nói lý do ngay tại chỗ, người đọc không cần mở tài liệu nào mới hiểu. **Trong code không nhắc
  ADR** (Go, TypeScript, shell, YAML, Dockerfile, Makefile, workflow, `.proto`, `.env.example`, file cấu hình): số mục của ADR đổi hay
  ADR bị thay thì tham chiếu thành sai. Tìm ngược từ quyết định tới code qua mục "Hiện thực ở" của mỗi ADR. File `.md` vẫn link ADR
  như cũ. Comment viết tiếng Anh.
- **Monorepo:** `services/<tên>/`, `proto/`, `deploy/`, `docs/`. Thư mục nào tạo khi tới giai đoạn cần nó.
- **ADR** ở `docs/adr/NNNN-<slug>.md`, theo mẫu trong [`docs/adr/README.md`](docs/adr/README.md). Đảo một quyết
  định cũ thì viết ADR mới và đánh dấu ADR cũ là "Bị thay bởi".
- **Runbook, postmortem, RFC** ([ADR-0020](docs/adr/0020-reliability-stage6.md) §12, §14): `docs/runbooks/` (mẫu và mục lục ở
  `README.md`): một runbook mỗi cảnh báo `severity=page`, tên file là tên alert kebab-case, rule page mang `runbook_url` trỏ file
  đó trên `main` (thêm cảnh báo page thì thêm runbook trong cùng thay đổi); sự cố đã gặp và quy trình tay cũng ở đây.
  `docs/postmortems/<yymmdd>-<slug>.md`: postmortem không đổ lỗi theo mẫu của `README.md`, mốc thời gian UTC có nguồn.
  `docs/rfc/NNNN-<slug>.md`: một trang cho người không làm kỹ thuật (vấn đề, phương án, chi phí có nguồn, rủi ro, đề xuất).
- **Mỗi service một database riêng; không service nào đọc database của service khác.** Cần dữ liệu
  của service khác thì gọi API của nó hoặc dựng bản sao từ event.

  | Service | Postgres `127.0.0.1:5432` | Redis `127.0.0.1:6379` |
  | --- | --- | --- |
  | `gateway` | — | db 10 |
  | `user-service` | `svp_user` | db 11 |
  | `video-service` | `svp_video` | db 12 |
  | `engagement-service` | `svp_engagement` | db 13 |
  | `feed-service` | `svp_feed` | db 14 |
  | `media-worker` | — | — |
  | `web` | — | db 9 |
  | GlitchTip (profile `obs`, tracker lỗi) | `svp_glitchtip` | — |
  | test (`make test`) | `svp_<...>_test` | db 15 |

  Redis db 0, db 5 và db 7 đang chứa dữ liệu của dự án khác: không dùng, không `FLUSHDB` ở đó. Lệnh luôn ghi
  rõ port (`psql -h 127.0.0.1 -p 5432`, `redis-cli -p 6379 -n 14`).

  Trong cluster k3d (giai đoạn 4) cùng tên database (cả `svp_glitchtip`) nằm trên Postgres `svp-pg` của CloudNativePG
  (`svp-pg-rw.svp-data:5432`), gateway, feed-service và web dùng db 10, db 14 và db 9 (session) của Valkey
  `valkey.svp-data:6379`; Postgres và Redis native không bị đụng.
- **Service có Postgres thử lại kết nối lúc khởi động** (`internal/pgretry`, gọi từ `internal/pgpool.New` và
  `internal/dbmigrate.Up`; [ADR-0020](docs/adr/0020-reliability-stage6.md) §11): chỉ lỗi mạng (từ chối kết nối, quá hạn dial,
  mất kết nối lúc bắt tay, DNS quá hạn), trong cửa sổ 30 s, chờ 250 ms gấp đôi tới 2 s, mỗi lần vẫn bị hạn kết nối 5 s; lỗi xác
  thực, database không có, TLS bị từ chối, tên miền không có thì dừng ngay. Mỗi lần lỗi một dòng WARN `database not reachable,
  retrying` (`attempt`, `error`, không URL), nối được sau khi lỗi thì INFO `database connected after retries` (`attempts`,
  `elapsed_ms`).
- **engagement-service mở tối đa `DATABASE_MAX_CONNS` kết nối Postgres mỗi process** ([ADR-0031](docs/adr/0031-chaos-findings-feed-engagement-tempo.md)
  §2): số nguyên ≥ 2, không đặt thì 10, giá trị khác thì service không khởi động; chia hai pool cùng URL: pool đọc (chỉ `GetStats`)
  ⌊n/2⌋, pool ghi (Like, Unlike, consumer lượt xem) phần còn lại. Values k3d đặt `"10"`, compose không đặt. Like/Unlike có hạn
  Postgres 1 s phía server; hết hạn hay Postgres không tới được thì `UNAVAILABLE` + `DEPENDENCY_UNAVAILABLE`, gateway không thử lại
  (503 ngay). Service khác giữ pool mặc định của pgx.
- **Docker, compose, k3d chỉ chạy qua `Makefile`.** Mọi target gọi `env -u DOCKER_DEFAULT_PLATFORM docker ...`:
  shell global đặt `DOCKER_DEFAULT_PLATFORM=linux/amd64` cho dự án khác, nếu không bỏ biến này thì
  container chạy amd64 qua giả lập, chậm và tốn RAM. Chạy tay ngoài Makefile cũng phải thêm tiền tố đó.
  Image cho cloud build đa kiến trúc ở CI.
- **kubectl/helm** chỉ chạy vào cluster k3d, luôn ghi `--context k3d-<tên>` trong lệnh.
- **Git:** conventional commits, mô tả tiếng Việt. Không commit `.env`, secret, token, file state Terraform. Từ khi bật
  ruleset `main` (`.github/rulesets/main.json`, [ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md) §11), mọi thay đổi
  vào `main` đi qua PR có `ci-ok` và `images-ok` xanh, cả của người học; không force push, hoàn tác bằng PR revert.

## An toàn cloud

- **AI không chạy lệnh nào chạm tài khoản AWS/GCP, kể cả lệnh chỉ đọc:** `aws`, `gcloud`, `gsutil`, `bq`,
  `eksctl`, `terraform init/plan/apply/destroy/import/state/output`, `kubectl`/`helm` vào cluster
  EKS/GKE, script dùng SDK cloud.
- AI được chạy: `terraform fmt`, `terraform init -backend=false` + `terraform validate`, `aws --version`,
  `gcloud --version`, đọc và sửa code IaC.
- **AI soạn lệnh để người học tự chạy:** ghi profile/project và region ngay trong lệnh
  (`AWS_PROFILE=anhnv-sso aws ... --region ...`, `gcloud ... --project ...`), mỗi bước một khối, nói rõ cần
  dán lại output nào và tìm gì trong đó. Nhiều bước thì viết thành script để người học đọc rồi chạy.
- Trước mọi lệnh ghi, người học chạy `aws sts get-caller-identity` (hoặc `gcloud config list`) với cùng
  profile/project, hai bên cùng kiểm tra đúng account.
- Mỗi buổi cloud kết thúc bằng lệnh destroy và lệnh quét tài nguyên sót; AI nhắc cho tới khi người học
  xác nhận đã chạy cả hai. Budget alert bật từ ngày đầu ở cả hai cloud.

## Kiểm tra

Từ gốc repo, cho `proto/`:

- `buf lint` (phải sạch, không output) và `buf build -o /dev/null`.
- `buf breaking --against '.git#branch=main'` khi sửa `proto/`. **Chỉ dùng được sau khi `proto/` đã có trong một commit
  trên `main`**; trước đó buf báo "Module had no .proto files".

Từ giai đoạn 1, cho code Go (`services/`, `internal/`, `tools/`), mọi lệnh chạy từ gốc repo qua `Makefile` (`make help`
liệt kê target):

- `make tools`: cài một lần các công cụ ghim version (`protoc-gen-go`, `protoc-gen-go-grpc`, `sqlc`, `golangci-lint`,
  `actionlint`, `gitleaks`, `govulncheck`, `sloth` sinh rule SLO, `k3d`); `buf`, Helm cài bằng Homebrew (CI cài hai thứ đó bằng
  `make ci-tools`, chỉ chạy trên Linux amd64).
- `make generate`: chạy sau khi sửa `proto/` hoặc SQL của `sqlc`; code sinh ra (`gen/go`, code `sqlc`) được commit.
- `make generate-check`: chạy `make generate` trong bản sao tạm của working tree (file đã track và file chưa track không bị
  ignore, không `.env`), in file lệch và diff, exit ≠ 0 khi lệch; không bao giờ ghi vào working tree.
- `make check` = `make check-go` + `make web-check`. `make check-go`: `gofmt`, `go vet`, `golangci-lint run` (gồm gosec),
  `actionlint` (mọi file của `.github/workflows/`), `buf lint` + `buf build`, `make vulncheck` (govulncheck, dưới đây),
  `go test -race ./...` (có integration test trên Postgres native `127.0.0.1:5432` qua
  `SVP_TEST_POSTGRES_URL` và Redis native db 15 qua `SVP_TEST_REDIS_URL`, mặc định `redis://127.0.0.1:6379/15` trong
  `Makefile`). Thu hẹp bằng `make test PKGS=./services/user-service/...`; `TESTFLAGS` thêm cờ cho `go test` của
  `make test`, `make cover`, `make check` (`make test TESTFLAGS=-count=1` chạy lại không dùng cache, như CI), `LINTFLAGS`
  thêm cờ cho golangci-lint của `make lint`.
- Web client (`web/`, giai đoạn 5b, [ADR-0016](docs/adr/0016-web-client.md)): cần **Node 26** (`web/.nvmrc`, cài bằng nvm)
  và **pnpm 12** đúng version ở `packageManager` của `web/package.json` (`npm install -g pnpm@<version>`, Node 25 trở đi
  không có Corepack). Mọi target `web-*` tự đặt Node 26 mới nhất của nvm lên đầu `PATH`, kiểm major Node và version pnpm,
  lệch thì in lệnh cài và dừng. `make web-install`: `pnpm install --frozen-lockfile` (setting chuỗi cung ứng ở
  `web/pnpm-workspace.yaml`). `make web-dev`: `next dev` ở `http://localhost:3002`, trỏ gateway `127.0.0.1:8080`, Redis
  db 9 và object store `http://127.0.0.1:9000` (`MEDIA_ORIGIN`, `UPLOAD_ORIGIN`: origin nhận presigned POST, bắt buộc, `http` chỉ
  cho loopback, [ADR-0018](docs/adr/0018-web-profiles-public-video-upload.md) §8). `make web-generate`: sinh `web/gen/api.d.ts` từ `services/gateway/openapi.yaml` (commit); `make generate` gồm cả
  `generate-go` lẫn `web-generate`, còn `make generate-check` chỉ kiểm phần Go. `make web-generate-check`: so bản sinh tạm
  với `web/gen/api.d.ts`, không ghi gì. `make web-check`: ESLint, Prettier, typecheck, Vitest (Redis db 15 qua
  `SVP_TEST_REDIS_URL`), `next build`, khởi động thử server standalone (cổng loopback tự chọn, đợi `GET /healthz` 200 tối
  đa 30 s: bắt module server thiếu lúc nạp), ngân sách bundle size-limit (feed ≤ 200 kB trên runtime, ≤ 330 kB tải lần đầu; login
  ≤ 80/210 kB; `/v/[id]` ≤ 200/330 kB; `/upload` ≤ 80/210 kB; tải lần đầu của login và upload nới từ 200 lên 210 kB ở
  [ADR-0019](docs/adr/0019-web-k3d-supply-chain-observability.md) §12). `make web-e2e`: Playwright trên Chromium và
  WebKit vào stack
  `make up` (`http://localhost:3001`; trình duyệt cài một lần bằng `pnpm exec playwright install chromium webkit` trong
  `web/`); test làm video `READY` (gắn `@publishes`) chạy ở project `chromium-publishing`/`webkit-publishing` sau hai
  project chính. `make measure-web`: chạy toàn bộ e2e (không
  chạy `web-e2e` riêng), in thời gian tới khung đầu sau khi vuốt (p50/p95 mỗi trình duyệt) và bộ nhớ container `web` (cgroup
  theo `docker stats`) lúc nghỉ và sau e2e, JSON ở `web/test-results/`. `SVP_E2E_EVIDENCE=<thư mục tuyệt đối>` (với
  `web-e2e` hay `measure-web`) bật trace và video mỗi test, ảnh cuối mỗi test chỉ trên Chromium (WebKit không chụp được, xem
  `web/playwright.config.ts`), báo cáo HTML và JSON, và ảnh toàn trang các màn ở cỡ mobile 390×844 và desktop 1440×900
  (`web/e2e/evidence.e2e.ts`, chạy trên cả hai trình duyệt) vào thư mục đó. `make measure-upload`: tải một video ~100 MB
  (160 s 1080p, ffmpeg sinh trong thư mục tạm) từ Chromium qua `/upload`, in thời gian và thông lượng XHR, CPU main thread
  của trang và thời gian tới `READY`, JSON ở `web/test-results/`. `make web-lighthouse`: Lighthouse mobile (mặc định của
  Lighthouse, throttling mô phỏng), một lượt mỗi trang: feed `/` đã đăng nhập (user mới, cookie qua `extraHeaders`, không in)
  và `/v/{id}` không đăng nhập; ngưỡng LCP 2 500 ms, CLS 0,1, TBT 200 ms (đỏ không chặn PR, chưa vào CI), báo cáo ở
  `web/test-results/lighthouse/`; không trỏ vào media origin có ghi log header (ADR-0018 §10). **LOCAL LAB ONLY:** seed của
  e2e, mỗi worker Playwright (`web/e2e/fixtures.ts`), `measure-upload` và `web-lighthouse` xoá khoá
  `svp:gw:rl:register:*` ở db 10 như `make smoke`. Phần C
  ([ADR-0019](docs/adr/0019-web-k3d-supply-chain-observability.md)): `make web-sourcemaps` tải source map trình
  duyệt của đúng bản build mà container `web` của stack `make up OBS=lgtm` chạy (stage `sourcemaps` của
  `deploy/docker/web.Dockerfile`; image không có file `.map`, bundle không có `sourceMappingURL`; trước khi tải kiểm mọi chunk
  `/login` đang phục vụ có debug ID trong bộ map) lên GlitchTip `http://127.0.0.1:8000` bằng CLI `sentry` của
  `web/package.json` với `SENTRY_SOURCEMAPS_TOKEN` của `.env` (chỉ trong subshell, không in). `SVP_E2E_GLITCHTIP=1` (với
  `web-e2e` trên stack có GlitchTip, hay `k8s-web-e2e`; sau khi tải source map) thêm `web/e2e/glitchtip.e2e.ts` ở hai trình
  duyệt: lỗi trình duyệt cố ý (trang Khám phá nhận response bị sửa bằng `page.route`) tới GlitchTip qua `/monitoring` với frame
  đã map về `turbopack:///[project]/…`, kết quả ở `web/test-results/glitchtip-<project>.json`. Web của compose nhận
  `SENTRY_DSN` (rỗng thì `/monitoring` trả 404), `SENTRY_ENVIRONMENT`, `x-telemetry-env` như service Go và
  `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` của `.env`; gateway compose đặt `TRUST_TRACE_CONTEXT=true` (chỉ loopback, WEB-24).
- `make cover`: `go test -race` như `make test` nhưng ghi coverage vào `cover.out` (đã gitignore) và in tổng; thu hẹp bằng
  `PKGS=`, xem từng dòng bằng `go tool cover -html=cover.out`.
- `make vulncheck` ([ADR-0030](docs/adr/0030-devsecops-supplement.md) §1, trong `make check-go` trước test, cần mạng tới
  `vuln.go.dev`, không biến bỏ qua): govulncheck `-format json ./...` bằng đúng Go của directive `go` trong `go.mod`
  (`GOTOOLCHAIN=go<directive>`; directive phải có số patch, `go 1.27.3`), rồi gate `tools/vulngate` quyết: lỗ hổng mức symbol
  (code gọi tới) đỏ, in id, module@version, bản sửa và trace; mức module, package chỉ một dòng `INFO`; mọi dòng `FROM golang:` của
  `deploy/docker/*.Dockerfile` phải mang đúng bản Go đã quét (lệch, tag không đủ ba số, hay không còn dòng nào là đỏ). Nâng Go thì
  cùng một PR đổi directive, hai Dockerfile và `go-version` của workflow. Ngoại lệ chỉ ở `.govulncheck-ignore.json` (gốc repo,
  chỉ tạo khi có mục đầu tiên; hiện không có): khoá `ignore`, mỗi mục đúng `id`, `module`, `version` (như frame đầu, `stdlib`
  cho thư viện chuẩn), `statement` có nội dung, `expired_at` sau hôm nay (UTC) và không quá 30 ngày; chỉ cho lỗ hổng chưa có bản
  vá (có bản vá thì nâng), mục trùng, hết hạn hay không còn khớp finding nào là đỏ.
- `make fuzz [FUZZTIME=30s] [PKGS=…]` (ADR-0030 §2): chạy lần lượt mọi `FuzzXxx` (mỗi gói một `fuzz_test.go`: `pagetoken`,
  `authtoken`, `objstore`, `httpx` của gateway, `server` của user-service; 10 target) bằng `go test -fuzz`, không `-race`,
  dừng ở target đầu tiên đỏ và in đường dẫn input go ghi ra dưới `testdata/fuzz/<target>/`; seed chạy trong `make test`. Lỗi
  tìm ra thì sửa hàm và commit input đó (test đỏ trước khi sửa). Chỉ chạy tay, không có trong CI.
- `make env`: sinh `.env` local (mode 600, mật khẩu DB, mật khẩu root của object store `SVP_S3_ROOT_PASSWORD`, secret key S3 của
  từng service và của user thử `svp-objstore-probe` (`SVP_S3_PROBE_SECRET_KEY`, chỉ compose và `make test-stack`) ngẫu nhiên,
  khoá JWT mới, khoá Server Action của web `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (base64 của 32 byte); thêm
  `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`, mật khẩu hai role `svp_glitchtip_*` và
  `GLITCHTIP_ADMIN_EMAIL=admin@svp.local`; cho cluster k3d, compose bỏ qua: `SVP_PG_SUPERUSER_PASSWORD`,
  `SVP_KAFKA_ADMIN_PASSWORD`, `SVP_KAFKA_KEDA_PASSWORD`, `SVP_KAFKA_<SERVICE>_PASSWORD` cho 5 service có Kafka,
  `SVP_GRAFANA_ADMIN_PASSWORD`, `SVP_PG_BACKUP_S3_SECRET_KEY` (user `svp-pg-backup` của backup Postgres; 20 byte hex
  như secret key S3 khác: 40 ký tự là độ dài secret key của AWS và giới hạn của MinIO, store của đường quay lại)). `.env` có
  sẵn thì chỉ bổ sung biến còn thiếu hoặc đang rỗng, không đổi giá trị đã đặt; `SVP_MINIO_ROOT_PASSWORD` của `.env` cũ còn đó
  thì không ai đọc.
- Quy tắc đọc `.env` (`deploy/observability/glitchtip/dotenv.sh`, dùng chung cho `make env`, `make test-stack`,
  `make glitchtip-init`, bootstrap Postgres và script diễn tập): mỗi dòng là dòng trống, comment `#` ở cột 1, hoặc
  `KEY=value` với `KEY` ở cột 1 và `=` ngay sau; giá trị trơn (ASCII in được, không khoảng trắng, nháy, `\`, `$`) hoặc nằm
  trong đúng một cặp nháy `"..."`/`'...'` bao ngoài, bỏ nháy khi đọc (`KEY=""` là rỗng). Dòng có `$`/`${`, khoảng trắng
  đầu dòng hay `export`, khoá lặp, giá trị nhiều dòng, CRLF, byte NUL → dừng, nêu `FILE:dòng:` và tên biến, không in giá
  trị, không ghi gì.
- `make up` / `make smoke` / `make down`: dựng stack compose profile `core` (bootstrap Postgres, Redpanda + tạo topic,
  object store `s3` (RustFS, [ADR-0022](docs/adr/0022-local-object-store-minio-replacement.md)) + job `s3-init` tạo
  bucket, user, policy, CORS, migrate, gateway, user-service, video-service, media-worker, engagement-service,
  feed-service, web client `web`), chạy luồng đầu-cuối qua gateway ở `127.0.0.1:8080` (gồm refresh token, dùng lại token
  cũ thì cả họ bị thu hồi, logout, follow, hồ sơ: handle tự chọn, trùng handle 409, handle sinh `u_…`, `GET`/`PATCH /me`
  không có email, `followed_by_me`, danh sách video theo tác giả chỉ tác giả thấy video chưa `READY`, upload video bằng
  presigned POST lên object store, chờ `READY`, tải HLS và thumbnail, output HLS bất biến
  ([ADR-0029](docs/adr/0029-immutable-media-versions.md): master ở `media/<id>/<version>/master.m3u8`, version là `event_id` của
  `video.uploaded`, biến thể và thumbnail dưới thư mục lần thử `<version>/<attempt>/`; master, một playlist biến thể, một segment
  và thumbnail mang `Cache-Control: max-age=31536000, immutable`), `GET /public/videos/{id}` không token 200 với video `READY`
  và một 404 cho video chưa `READY` lẫn id ngẫu nhiên, video vào feed following và explore kèm `author`, like/unlike, lượt
  xem, unfollow), rồi gỡ stack (giữ volume). Gateway dùng Redis native db 10 (rate limit), feed-service db 14 (cache feed
  khám phá), qua `host.docker.internal:6379`; web dùng db 9 (session). Object store chỉ nhận CORS từ `http://localhost:3001` và
  `http://localhost:3002`, theo bucket (`s3-init` đặt `PutBucketCors`: `uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`; danh
  sách toàn cục `RUSTFS_CORS_ALLOWED_ORIGINS` rỗng nên bucket khác không có header CORS; WEB-10): mở web bằng
  `127.0.0.1:3001` thì đăng nhập được nhưng không phát và không tải video lên được. Cổng publish chỉ trên `127.0.0.1`: 8080 gateway, 3001 web (mở
  bằng `http://localhost:3001`), 9000 object store (API S3; console tắt, không cổng 9001), 19092 Redpanda (Kafka API). Xem object bằng
  `curl --aws-sigv4` chạy trong container `s3` (như `make drill-upload-cleanup`), không mở cổng nào thêm. `make ps` và `make logs SVC=<tên>` để xem. `make smoke` và mọi script diễn tập cần
  `redis-cli` trên máy và Redis native đang chạy: trước khi chạy, script xoá khoá rate limit đăng ký theo IP
  `svp:gw:rl:register:*` ở db 10 (`SCAN` + `DEL`, không `FLUSHDB`), vì mọi request đi ra từ một IP bridge của Docker và
  vài lần chạy trong một giờ sẽ cạn burst 20. Việc xoá này **chỉ dùng ở lab local**, không trỏ script vào stack dùng
  chung. **Biến chuyển tiếp `SVP_SMOKE_LEGACY_MEDIA=1`** (chỉ cho smoke, cả `make k8s-smoke`): master không có version
  (`media/<id>/master.m3u8`, layout của media-worker trước ADR-0029) qua với một dòng `NOTE`, không kiểm `Cache-Control`; master có
  version thì luôn kiểm đủ. Từ giai đoạn 6b phần 4 (PR-B) không target hay kịch bản nào đặt biến này nữa: mọi bản phát hành ghi
  key có version, nên smoke chặt trên mọi đường, cả kịch bản `gitops` (lượt 40954609229: dòng `versioned key …`, không dòng `NOTE`);
  biến còn trong `deploy/compose/smoke.sh` để đọc được bucket cũ bằng tay.
- `make up OBS=lgtm|elastic|off` (ADR-0011 §9–10, ADR-0012). Không đặt `OBS`: chỉ `core`, SDK telemetry bật nhưng không có
  Collector để tới (export lỗi bị bỏ, không làm service lỗi). `OBS=lgtm` thêm profile `obs`: `otelcol` (Collector, không
  publish), `lgtm` (Grafana `127.0.0.1:3000` cùng Prometheus, Loki, Tempo, Pyroscope trong một container),
  `alertmanager` (`127.0.0.1:9093`), `glitchtip` (`127.0.0.1:8000`), chạy `make glitchtip-init` trước. `OBS=elastic`
  thêm `obs-elastic` thay cho `obs`: Elasticsearch, Kibana (`127.0.0.1:5601`), APM Server, `otelcol-elastic`; chỉ để so
  sánh, không cảnh báo hay GlitchTip. `OBS=off`: chỉ `core`, telemetry tắt hẳn (`OTEL_SDK_DISABLED=true`, Pyroscope và
  Sentry rỗng), mốc đo overhead; target diễn tập dựng lại service trên stack này vẫn giữ tắt. **Chỉ một bộ observability
  mỗi lúc:** `make up` từ chối khi container của profile nó không chọn đang chạy, báo chạy `make down` trước; `make down`,
  `make ps`, `make logs` gồm mọi profile. Grafana anonymous Admin và Kibana không đăng nhập chỉ chấp nhận vì chỉ publish
  trên loopback (OPS-2).
- `make compose-config`: kiểm file compose hợp lệ cho `core`, `core`+`obs`, `core`+`obs-elastic` và `OBS=off`, chỉ bằng
  `config --quiet` (không in file đã điền secret); sạch là không in gì.
- `make glitchtip-init`: migrate và khởi tạo GlitchTip (admin, organization và project `svp`, API token chỉ đọc, token tải
  source map `svp-sourcemaps` scope `project:releases`), thêm `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`,
  `SENTRY_PROJECT`, `SENTRY_API_URL`, `SENTRY_SOURCEMAPS_TOKEN` vào `.env` khi còn thiếu hay rỗng;
  idempotent, không đổi giá trị đã đặt. `make up OBS=lgtm` tự gọi nó. Database `svp_glitchtip` trên Postgres native, hai
  role `svp_glitchtip_migrator`, `svp_glitchtip_app` do bootstrap Postgres của `make up` tạo.
- `make otelcol-validate`: `validate` của Collector ghim (`--network none`) cho cấu hình `obs`, cấu hình `obs-elastic`
  (file `deploy/observability/elastic/otelcol-config.yaml` ghép đè lên file `obs`) và cấu hình của cluster k3d
  (`deploy/observability/otelcol/k8s-config.yaml`); chạy lại sau khi sửa một trong ba.
- `make slo`: sinh `deploy/observability/prometheus/rules/slo-generated.yaml` từ `deploy/observability/slo/svp-slos.yaml`
  bằng Sloth; file sinh được commit, chạy lại sau khi sửa spec. `make slo-check`: promtool của image LGTM ghim, không
  mạng: `check config` cho cấu hình Prometheus và hai file rule, rồi `test rules` (`svp-alerts.test.yaml`).
- `make test-stack`: `go test -race -count=1 -v` trên stack đang chạy (`make up`), đặt các biến `SVP_TEST_*` cho object store
  và Redpanda, nên integration test của `internal/objstore` chạy thật thay vì SKIP (gồm ca multipart CRC32 bằng user thử
  `svp-objstore-probe`, dạng header qua `http://` và dạng trailer qua proxy TLS của test; `Cache-Control` lưu và trả lại khi GET
  ẩn danh, ghi có điều kiện `If-None-Match: *` chỉ một lần thành công, user của media-worker đọc và liệt kê được `media/`). Chỉ ba secret S3 (hai service và
  user thử) lấy từ `.env`; endpoint,
  access key, broker, `SVP_TEST_POSTGRES_URL` và `SVP_TEST_REDIS_URL` cố định trong `deploy/compose/compose.mk` và
  `Makefile`. Thu hẹp bằng `PKGS=` như `make test`, `TESTFLAGS` thêm cờ.
- `make clean-data`: gỡ stack (mọi profile) và xoá volume của nó (topic Redpanda, bucket của object store `s3-data`, thư mục
  tạm của media-worker, dữ liệu LGTM, silence của Alertmanager, chỉ mục Elasticsearch); Postgres native (cả `svp_glitchtip`)
  không bị đụng; volume của project mà compose không còn khai (`svp_minio-data`, dữ liệu MinIO trước khi đổi store, đường
  quay lại) được giữ và in ra. Chỉ chạy khi cần làm lại dữ liệu từ đầu.
- `make object-store-copy TO=s3|minio` (script `deploy/compose/object-store-copy.sh`, [ADR-0022](docs/adr/0022-local-object-store-minio-replacement.md)
  mục Cách chuyển): chép bucket `uploads`, `media` từ volume MinIO `svp_minio-data` sang volume RustFS `svp_s3-data` (`s3`)
  hay ngược lại (`minio`, đường quay lại), dựng tạm hai store trên network nội bộ không publish cổng (MinIO bằng image
  Chainguard ghim digest trong script, mật khẩu root ngẫu nhiên mỗi lượt), chép bằng `mc mirror` của image đó không
  `--remove`, không `--overwrite`, rồi kiểm key, kích thước, `Content-Type` hai phía. Từ chối khi stack compose hay cluster
  k3d đang chạy, container nào đang dùng một trong hai volume, còn video `PROCESSING` (`SELECT` trên `svp_video`), hay đích có
  key mà nguồn không có hoặc cùng key khác kích thước (không ghi gì); in key của video `READY` đã mất từ trước ở cả hai phía
  (không chặn). Không bao giờ xoá hay ghi đè object, không xoá volume nào; xoá ở đích hay xoá volume cũ là việc của người học.
- `make drill-kill-worker`, `make drill-duplicates`, `make measure-ready N=5`: diễn tập trên stack đang chạy, script ở
  `deploy/compose/drills/`. Lần lượt: kill media-worker giữa lúc transcode rồi kiểm video vẫn `READY` đúng một lần và master
  trỏ đúng một thư mục lần thử (thư mục của thumbnail); phát lại event bằng `rpk group seek` rồi kiểm không gì đổi: media-worker
  thấy master của version, không transcode (log `transcode output exists`), không object nào dưới `media/<id>/` thêm hay ghi lại
  (key và ETag, liệt kê bằng request có chữ ký trong container `s3`), `transcode.completed` phát lại giống từng byte; đo `CompleteUpload` → `READY` cho N video 60 s 1080p (p50, p95,
  max, CPU/RAM của media-worker).
- `make drill-duplicates-feed`, `make drill-engagement-down`, `make measure-freshness FOLLOWERS=10000 N=10`: diễn tập
  phần feed, cùng chỗ. Lần lượt: phát lại `view.recorded`, `user.followed`/`user.unfollowed` và `video.ready` bằng
  `rpk group seek` rồi kiểm bộ đếm và dòng feed không đổi; tắt engagement-service rồi kiểm circuit breaker của gateway mở
  (like trả 503 trong < 100 ms), feed vẫn 200 không có `stats`, bật lại thì breaker tự đóng và like trả 204; đo độ tươi
  `video.ready` → dòng timeline cuối cho N video (tối đa 10: một tác giả, burst upload 10) tới FOLLOWERS follower giả
  (`tools/fakefollows` phát `user.followed` vào Redpanda, dọn bằng `user.unfollowed` khi kết thúc).
- `make drill-rate-limit`, `make measure-explore-cache N=100`, `make drill-upload-cleanup`: diễn tập phần Redis, cache và
  job dọn, cùng chỗ. Lần lượt: vượt ngưỡng thì 429 `RATE_LIMITED` có `Retry-After`, mở quá 3 form upload thì 429
  `TOO_MANY_UPLOADS`, Redis không tới được (gateway dựng lại với `REDIS_URL` trỏ tên miền `.invalid`, Redis native không
  bị tắt) thì login vẫn bị giới hạn bằng bộ đếm dự phòng còn feed, like, lượt xem vẫn chạy; hai sóng N request đồng thời
  (mặc định 100, tối đa 150, sóng đầu lúc cache trống) chỉ đọc Postgres một lần, không kể lần đọc do Redis quá hạn 50 ms
  (dòng `explore page loaded from database` có `cache=timeout`, hoặc đứng ngay sau dòng có `cache_write=timeout`: SET
  quá hạn nên lần đọc sau không thấy trang; đạt khi tổng ≥ 1 và tổng − `timeout` − số dòng sau SET quá hạn ≤ 1, in tổng,
  `timeout`, `miss`, `error`, số dòng sau SET quá hạn), script xoá khoá `svp:feed:explore:*` ở db 14 trước khi đo; video
  bỏ dở quá hạn chuyển `FAILED` và object `uploads/<id>` bị xoá (mọi video khác nằm `UPLOADING` quá 20 s cũng bị dọn).
- `make drill-alert-to-sentry`, `make drill-obs-threats`: diễn tập giai đoạn 3, chỉ trên stack `make up OBS=lgtm`, cần
  GlitchTip đã khởi tạo (`SENTRY_DSN`, `SENTRY_AUTH_TOKEN` trong `.env`, do `make up OBS=lgtm` hay `make glitchtip-init`
  ghi; script chỉ nhận `SENTRY_API_URL=http://127.0.0.1:8000`, không cổng loopback nào khác). Lần lượt: tắt feed-service,
  đo từ lúc cảnh báo page `FeedAvailabilityBudgetBurn` có trong Alertmanager (T1) tới khi trace (Tempo), dòng log (Loki)
  và event GlitchTip cùng một `trace_id` đều tìm thấy (T4), đạt khi T4 − T1 < 5 phút; trước khi tắt, script chờ cảnh báo
  của lần chạy trước resolve (tới khoảng 30 phút) và 31 s không có 5xx ở feed. Kiểm các dòng giai đoạn 3 của threat
  model: JWT-8 (trace, log, event GlitchTip của request login/feed/follow, cả lúc user-service tắt, không có email, mật
  khẩu, token), UP-8 (`video created`, `upload completed` có `user_id`, `video_id`, `trace_id`), OPS-1 (`/debug/pprof/`,
  `/metrics` trả 404; project publish đúng 7 cổng loopback, gồm web 3001 và `s3` 9000, không 9001), RL-2 (gateway dựng lại với Redis `.invalid` thì metric
  `store="fallback"` > 0 và cảnh báo `RateLimitFallbackActive` trong 4 phút), WEB-9 (giai đoạn 5b phần C: email, token,
  sid, `?next=`, chữ ký presigned từ form của web, `/rum` và `/monitoring` không có trong GlitchTip, Tempo, Loki, Prometheus;
  đối chứng có dữ liệu của web). **Telegram tuỳ chọn:** người học tự tạo bot
  và điền `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` vào `.env`; có đủ cả hai thì Alertmanager gửi cảnh
  báo `severity=page` tới `api.telegram.org` (ngoại lệ hẹp về mạng ngoài của lab) và `drill-alert-to-sentry` kiểm số
  thông báo đã gửi; thiếu thì không gửi gì, bước đó SKIP. Có cả hai biến mà Alertmanager đang chạy chưa nạp receiver thì
  FAIL trước khi tắt service.
- Giai đoạn 6, tải k6 ([ADR-0020](docs/adr/0020-reliability-stage6.md) §2), target ở `deploy/k6/k6.mk`, k6 chỉ chạy bằng
  `K6_IMAGE` ghim của `Makefile` (không dùng k6 cài trên máy). `make k6-check`: `k6 inspect --execution-requirements` của
  `deploy/k6/main.js` với từng profile (`local`, `ci`, `cloud`), `--network none`, sạch là không in gì. `make load-local`
  (profile `local`, ~24 req/s giữ 5 phút, threshold theo SLO gồm độ trễ) và `make load-ci` (profile `ci`, vài req/s 60 s, chỉ
  threshold lỗi; job `stack` của CI dùng): trên stack `make up` đang chạy (`OBS=lgtm` để đọc phía server trong Prometheus), có
  video `READY` (`make smoke` tạo); từ chối khi stack tắt hay cluster k3d chạy; container k6 vào mạng `svp_web`, gọi
  `http://gateway:8080` và `http://web:3001` (`Host`, `Origin` là `http://localhost:3001`); tóm tắt ở
  `.k6/<profile>-<time>/summary.json` (gitignore; không `setup_data`, token, cookie, mật khẩu, grep kiểm), exit ≠ 0 khi một
  threshold trượt. **LOCAL LAB ONLY:** cả hai xoá khoá `svp:gw:rl:register:*` ở db 10 như `make smoke`.
- `make dast` (giai đoạn 6b, DAST theo OpenAPI, [ADR-0030](docs/adr/0030-devsecops-supplement.md) §3, target ở
  `deploy/dast/dast.mk`, logic ở `deploy/dast/run.sh`, cấu hình `deploy/dast/schemathesis.toml`): Schemathesis chỉ bằng
  `SCHEMATHESIS_IMAGE` ghim của `Makefile`, trên stack `make up` đang chạy (`core` là đủ); từ chối khi gateway không chạy, mạng
  `svp_web` không có hay cluster k3d chạy. Đăng ký và đăng nhập một user thử (token chỉ trong môi trường, không in), container
  vào `svp_web` gọi `http://gateway:8080` với 20 operation của `services/gateway/openapi.yaml` (trừ `/healthz`, `/readyz`), phase
  `examples`, `coverage`, `fuzzing`, check không 5xx, status, content type, schema và header của response, `ignored_auth`,
  `negative_data_rejection`; `--rate-limit 5/s`, `--max-examples 25`, seed ngẫu nhiên (`SVP_DAST_SEED=<n>` chạy lại seed của
  `report.json`), hạn cả lượt 10 phút (gồm pull image). Mọi output của Schemathesis vào `.dast/<time>/schemathesis.log` (mode 700,
  gitignore; cùng `junit.xml`, `requests.har` mang body của response, không bao giờ rời máy), terminal chỉ có tóm tắt in từ
  `report.json` và `summary.json` (phân bố status, tỷ lệ 429) sau khi hai tệp qua phép dò bí mật (JWT, token, cookie, chữ ký
  presigned, chính token của lượt); exit theo Schemathesis (0 đạt, 1 check trượt, 2 không chạy được), quá hạn hay lộ bí mật là 1.
  Một lượt ~3 phút 40 s, làm cạn rate limit theo IP và theo user: chạy sau các bước khác. **LOCAL LAB ONLY:** xoá khoá
  `svp:gw:rl:register:*` ở db 10 trước và sau lượt như `make smoke`.
- `make gameday`, `make gameday-mark M=diagnosed|mitigated|recovered`, `make gameday-end` (game day, ADR-0020 §13, script
  `deploy/compose/drills/gameday.sh`): chỉ trên stack `make up OBS=lgtm` có video `READY`. `gameday` chạy suốt buổi ở một
  terminal: tải nền k6 `local` (container `svp-gameday-k6`, giữ `SVP_K6_HOLD`, mặc định 60 phút), chờ 2 phút ổn định, **T0**
  dừng engagement-service, **T1** khi `CircuitBreakerOpen` có trong Alertmanager; người trực xử lý theo runbook
  `docs/runbooks/circuit-breaker-open.md` và ghi mốc bằng `gameday-mark` ở terminal khác. `gameday-end` hay Ctrl-C: dừng tải,
  bật lại service (chỉ khi đã qua T0), ghi dòng thời gian, báo cáo và tóm tắt k6 ở `.k6/gameday-<time>/`. Container
  `svp-gameday-k6` còn sót thì `gameday` từ chối chạy và in lệnh xoá. Postmortem viết từ mốc thật ở `docs/postmortems/`.
  **LOCAL LAB ONLY:** xoá khoá `svp:gw:rl:register:*` ở db 10 như `make smoke`.
- Script diễn tập dừng/khởi động container, chỉ `SELECT` trên `svp_video`, `svp_engagement`, `svp_feed`, và luôn bật lại
  mọi service khi kết thúc. Trên Redis, ngoài hai thao tác xoá ở trên (`svp:gw:rl:register:*` ở db 10,
  `svp:feed:explore:*` ở db 14) script chỉ đọc. `drill-rate-limit`, `drill-obs-threats` và `drill-upload-cleanup` dựng lại
  gateway hay video-service với cấu hình diễn tập qua `SVP_GATEWAY_REDIS_URL`, `SVP_UPLOAD_ABANDON_AFTER`,
  `SVP_UPLOAD_SWEEP_INTERVAL` rồi trả về mặc định; ba biến này **chỉ dùng cho diễn tập**, không đặt trong `.env` (hạn dọn
  upload dưới 15 phút ngắn hơn hạn form upload). Hai diễn tập giai đoạn 3 đọc Prometheus, Tempo, Loki qua datasource proxy
  của Grafana, API Alertmanager và API GlitchTip bằng token chỉ đọc, không in giá trị nào của `.env`.
- Giai đoạn 4, cluster k3d `svp` ([ADR-0014](docs/adr/0014-kubernetes-local-stage4.md)), target ở `deploy/k8s/k8s.mk`.
  Ràng buộc chung: chỉ chạy qua Makefile (`docker`/`k3d` với `env -u DOCKER_DEFAULT_PLATFORM`, `kubectl`/`helm` luôn
  `--context k3d-svp`, cache Helm ở `.k8s/helm`); `k3d` ghim cài bằng `make tools`. **Không chạy cùng compose:**
  `make k8s-up`, `k8s-gitops-up` từ chối khi stack compose `svp` đang chạy; `make up` từ chối khi node của
  cluster hay registry `k3d-svp-registry` đang chạy. Cổng chỉ trên `127.0.0.1`: API 6550, HTTPS của Envoy 8443
  (`api.svp.localhost`, `s3.svp.localhost` với chứng chỉ wildcard; web ở `svp.localhost`, listener `https-apex` với chứng
  chỉ riêng; đều phân giải về loopback), registry 5111. Postgres (CloudNativePG; từ giai đoạn 6 backup cơ sở và WAL lưu
  liên tục qua plugin Barman Cloud, component `plugin-barman-cloud` ở `cnpg-system`, vào bucket `pg-backups` của object store
  trong cluster bằng user riêng `svp-pg-backup`, [ADR-0020](docs/adr/0020-reliability-stage6.md) §5), Valkey,
  Redpanda (SASL + ACL), object store (RustFS, StatefulSet `s3`, `s3.svp-data:9000`, Job `s3-init`) nằm trong cluster: target giai đoạn 4 không đụng Postgres/Redis native. File sinh ra nằm ở
  `.k8s/` (gitignore). Biến chỉ đặt ở cluster: service có Kafka đăng nhập SASL SCRAM bằng `KAFKA_SASL_USERNAME`,
  `KAFKA_SASL_PASSWORD` (đặt cả hai hay không biến nào; compose không đặt, broker không xác thực); gateway tin một hop
  `X-Forwarded-For` từ dải pod của Envoy qua `TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16` (compose: không
  đặt, 0 hop; giá trị không hợp lệ thì gateway không khởi động); gateway `TRUST_TRACE_CONTEXT=true` (nhận
  `traceparent`/`tracestate` của request đến; `false` hay rỗng là mặc định, giá trị khác thì không khởi động) vì Envoy bỏ
  `traceparent`, `tracestate`, `baggage`, `sentry-trace` của client trên mọi route và chỉ Envoy, web vào được gateway
  (WEB-24). Web (giai đoạn 5b phần C, [ADR-0019](docs/adr/0019-web-k3d-supply-chain-observability.md)):
  `GATEWAY_URL=http://gateway:8080`,
  `REDIS_URL=redis://valkey.svp-data:6379/9`, `APP_ORIGIN=https://svp.localhost:8443`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN`
  `https://s3.svp.localhost:8443` (object store chỉ nhận CORS từ `https://svp.localhost:8443`, theo bucket như compose), `SENTRY_ENVIRONMENT=k3d`,
  `SENTRY_DSN` từ Secret `svp/sentry`, `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` từ Secret `svp/web-env`; `SVP_BUILD_ID` là build arg
  chép thành `ENV` của image (12 hex của commit ở CI, `dev-` + hash nội dung context ở đường dev, rỗng ở compose), dùng làm
  `deploymentId`, `release` của GlitchTip và `service.version`. API server có PSA `restricted` mặc định cho mọi namespace
  trừ `kube-system` (`deploy/k8s/pod-security-admission.yaml`, mount từ đường của repo lúc tạo cluster, đọc lại mỗi lần
  node server khởi động): sửa `k3d.yaml` hay dời repo phải `make k8s-down && make k8s-up`, sửa file đó có hiệu lực ở lần
  khởi động sau; `make k8s-up` từ chối cluster tạo khi chưa có cấu hình này, hay khi nguồn mount không còn là file, khác
  file của repo hiện tại, hay version lệch `podSecurityVersion`. Probe của chart `svp-service` (ADR-0020 §10, cùng cho mọi
  release): liveness `timeoutSeconds: 5` (chu kỳ 10 s, 3 lần), readiness 2 (chu kỳ 5 s), startup của service gRPC 2 (chu kỳ
  2 s × 30 lần); media-worker không có probe.
- Kyverno ([ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md) §8), cùng `ImageValidatingPolicy` `svp-images` (chart
  `deploy/helm/svp-policy`) trên hai đường, chỉ namespace `svp`: `make k8s-up` cài **Audit** (`failurePolicy: Ignore`,
  image `dev-*` chưa ký của registry k3d vẫn chạy, vi phạm ghi vào PolicyReport), `make k8s-gitops-up` **Enforce**
  (`Deny` + `Fail`: chỉ nhận image `ghcr.io/anhnvcoder/short-video-platform/*` theo digest, ký keyless bởi
  `images.yml@refs/heads/main`, có attestation `vuln` đủ hai nền tảng, không CRITICAL, không quá 72 giờ; Kyverno chết thì
  pod `svp` mới bị từ chối, namespace khác không qua webhook). **Build provenance** ([ADR-0027](docs/adr/0027-slsa-build-provenance.md)
  §4): giá trị `imageVerification.requireProvenance` của chart (mặc định `false`, render giống hệt trước; `provenanceRepository`,
  `provenanceRef` ở `values.yaml` của chart) bật thì policy thêm attestation `provenance` và bốn phép kiểm sau sáu phép cũ, mỗi phép
  một message: provenance ký đúng identity, `builder.id` bằng identity, `workflow.repository` là repo này, `workflow.ref` là
  `refs/heads/main`. Chỉ bật bằng overlay `envs/<env>/svp-policy.yaml` của repo `svp-gitops` (đường GitOps), chứa đúng
  `imageVerification:` + `requireProvenance: true|false` (nội dung khác thì `verify-release.sh`, `values-check.sh`, `gitops.sh`
  dừng); **đã bật ở cả stg và prd** từ commit khởi tạo của `svp-gitops` (cả bảy bản phát hành của `6ca2d8a` mang provenance, ADR-0027
  §6); kịch bản `gitops` lượt 40954609229: policy `Deny` có kiểm provenance, ca (a) và (l) của `drill-k8s-supplychain` PASS. Đường
  dev giữ mặc định `false`. Rollback về digest trước provenance khi đã bật bị từ chối: trỏ bản có provenance hay tắt trước bằng PR ở
  `svp-gitops`.
- `make k8s-up` / `make k8s-down` / `make k8s-status`: `k8s-up` tạo (hay khởi động) registry và cluster, build và push bảy
  image (sáu service Go và `web`) tag `dev-<image ID>` (chỉ `--set`, không ghi file), cài
  `argocd/apps/components.json` của bản clone `svp-gitops` theo wave với values `base/` của nó (thư mục cấu hình, mục
  `make gitops-clone` dưới đây; không có thì in lệnh clone và dừng trước khi tạo gì) bằng
  `deploy/k8s/install.sh` (trong đó chạy `secrets.sh` sau `svp-cluster`, `glitchtip-init.sh` sau `svp-observability`),
  xuất CA ra `.k8s/ca.crt`. Với Postgres: giữ `serverName` (thế hệ lưu trữ) của Cluster `svp-pg` đang chạy bằng `--set`; từ
  chối nâng `svp-data` khi `svp-pg` đang phục hồi (`bootstrap.recovery` có mà chưa Ready) hay đã mất mà còn Backup của nó;
  sau `svp-data` chờ WAL lưu liên tục và thế hệ đang chạy có backup cơ sở (chưa có thì chụp một bản; cluster mới chờ thêm vài
  phút); idempotent, cần `.env` (`make env`), từ chối cluster do Argo CD quản (có Application
  `svp-root`) và cluster tạo khi object store còn là MinIO (StatefulSet `svp-data/minio`: in lệnh dựng lại `make k8s-down`,
  `make k8s-up`, không nâng tại chỗ). Khi pod template của gateway hay web (Argo Rollout) đổi, tức có canary, `k8s-up` tự chạy traffic diễn tập
  trong lúc
  canary rồi dừng, chờ Rollout `Healthy` có hạn; abort hay inconclusive thì FAIL kèm lệnh gỡ (**LOCAL LAB ONLY**: traffic
  xoá khoá rate limit đăng ký ở Valkey db 10 của cluster). `k8s-down` xoá cluster và registry (volume compose và Postgres
  native không bị đụng). `k8s-status` in container, node và pod mọi namespace trừ `kube-system`.
- `make k8s-secrets`, `make k8s-glitchtip-init`, `make k8s-ca`: `k8s-secrets` tạo/cập nhật Secret từ `.env` bằng
  `kubectl apply` qua stdin, không in giá trị (gồm `svp/web-env` chỉ chứa `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`, phải là base64
  chuẩn của 32 byte, sai dạng thì dừng; `svp-data/pg-backup-s3` là đăng nhập của user `svp-pg-backup` của object store, chỉ sidecar của
  plugin Barman Cloud trong pod Postgres đọc); mật khẩu superuser Redpanda đổi thì đặt vào broker đang chạy trước khi apply
  (cần `redpanda-0` chạy; Admin API không trả lời hay không nhận mật khẩu nào thì dừng, không đổi Secret nào), object store
  (Secret `s3-root`, `s3-users`) hay Redpanda chạy với mật khẩu khác `.env` thì restart; sau đó `make k8s-up` để Job init đặt mật khẩu mới và restart service
  có Secret đổi (cluster GitOps: các bước tay ở đầu `deploy/k8s/gitops.sh`). **Hai chế độ, chọn theo namespace `svp-secrets`:**
  cluster dev (không có namespace đó) nhận chính các Secret như trên; cluster GitOps dựng từ revision mà overlay stg bật
  `externalSecrets` của chart `svp-cluster` (có `svp-secrets`) chỉ nhận **nguồn**: mỗi entry của
  `deploy/helm/svp-cluster/files/external-secrets.yaml` một Secret ở `svp-secrets` (10 entry từ `.env`, key đặt tên như `.env`;
  entry thứ 11 `glitchtip-runtime` tạo rỗng khi chưa có và không bao giờ bị đổi ở đây), rồi khi ExternalSecret đã có thì dựng lại từng cái từ
  nguồn mới (`force-sync`, chờ `status.syncedResourceVersion` đổi và `Ready`; `es_force_sync` của `deploy/k8s/lib.sh`) trước khi
  restart như trên. External Secrets Operator ([ADR-0026](docs/adr/0026-secrets-gitops.md)) dựng 28 Secret từ đó; cluster GitOps
  từ revision không có External Secrets thì nhận Secret như đường dev. `k8s-glitchtip-init` ghi DSN vào Secret
  `svp/sentry`, token API chỉ đọc vào `svp-obs/glitchtip-api` và token tải source map vào `svp-obs/glitchtip-sourcemaps`
  (không vào `.env`, không in; cluster có `svp-secrets`: ghi vào nguồn `svp-secrets/glitchtip-runtime` rồi `force-sync` ba
  ExternalSecret đó), restart service khởi động
  khi chưa có DSN hiện tại; idempotent, `k8s-up` tự gọi, không cần `.env`. `k8s-ca` ghi CA của chứng chỉ TLS ra
  `.k8s/ca.crt`.
- `make k8s-images`: build bảy image từ working tree (`web` từ context `web/` với `SVP_BUILD_ID=dev-<hash nội dung>`) và
  push lên `127.0.0.1:5111` tag `dev-<image ID>` (đường dev).
  `make k8s-release` **đã bỏ** (giai đoạn 5): image phát hành build, quét, ký trong CI (`images.yml`, bên dưới), job
  `promote` ghi khối `image` vào `envs/stg/images/<svc>.yaml` của repo `svp-gitops` (cùng `envs/stg/charts.yaml`) trên nhánh
  `bot/promote-stg` của repo đó và mở hay cập nhật một PR cuộn tự merge khi `gitops-ok` xanh (mục `images.yml` bên dưới). Đường dev
  `make k8s-up` giữ registry k3d và tag dev (chỉ `--set`).
- **Thư mục cấu hình, `make gitops-clone [GITOPS_REF=main]`** (giai đoạn 6b phần 4,
  [ADR-0025](docs/adr/0025-gitops-config-repo.md) §3): cấu hình triển khai (values gốc `base/`, overlay và digest của mỗi env
  `envs/{stg,prd}/`, Argo CD `argocd/`) nằm ở repo public `svp-gitops`, không còn trong repo này; chart vẫn ở `deploy/helm/`. Mọi
  script đọc thư mục cấu hình qua `gitops_dir` của `deploy/k8s/lib.sh`: `SVP_GITOPS_DIR` nếu đặt, không thì `<workspace>/gitops`
  (thư mục `gitops/` cạnh `backend/`, tính từ `git rev-parse --git-common-dir` nên đúng cả từ worktree ở `.worktrees/`); thư mục đó
  không có hay không phải bản clone `svp-gitops` (gốc work tree, `origin` là `svp-gitops`) thì in lệnh
  `git clone https://github.com/anhnvcoder/svp-gitops.git <workspace>/gitops` và dừng. Đường dev đọc working tree của bản clone
  (`base/`, `components.json`), **không tự clone, không fetch, không đổi nhánh**; sửa thử base: sửa trong bản clone, `make k8s-up`,
  rồi mở PR ở `svp-gitops`. `make gitops-clone` (cho CI): clone ẩn danh, đủ lịch sử vào `.gitops/svp-gitops` (gitignore), có rồi thì
  fetch, rồi checkout `GITOPS_REF` (nhánh, mặc định `main`, hay SHA đủ 40 hex); bản clone có thay đổi chưa commit thì từ chối, bản
  clone dừng giữa chừng (chưa checkout) thì lượt sau làm tiếp; job cần cấu hình đặt `SVP_GITOPS_DIR` tới đó. Thay đổi chéo hai repo
  theo thứ tự: values mới dùng được với chart đang ghim merge ở `svp-gitops` trước, chart dùng values đó sau; bỏ value thì ngược
  lại. Cây, check và cổng của `svp-gitops`: mục CI bên dưới.
- `make k8s-gitops-up [GITOPS_REV=main]`, `make measure-gitops REV=<commit của svp-gitops>`: đường GitOps (ADR-0014 §12, ADR-0015
  §9, [ADR-0025](docs/adr/0025-gitops-config-repo.md) §8), tạo cluster `svp` **mới** đóng vai stg
  ([ADR-0024](docs/adr/0024-multi-environment.md): `base/` cộng overlay `envs/stg/` và digest `envs/stg/images/` của `svp-gitops`,
  `gitops.sh` luôn đặt `env=stg` cho root, không có biến chọn env) mà Argo CD dựng từ GitHub qua HTTPS ẩn danh (không deploy key,
  không Secret repo; [ADR-0021](docs/adr/0021-deferred-verification-stage6b.md) §6): root `svp-root` và nguồn values đọc
  `svp-gitops`, chart `deploy/helm/*` đọc repo này ở commit `revision` của `envs/stg/charts.yaml`; kéo image từ GHCR theo digest, ẩn
  danh. `GITOPS_REV` là revision của `svp-gitops` trong thư mục cấu hình: nhánh của `origin` (đọc `refs/remotes/origin/<nhánh>` như lần
  fetch cuối, không `git fetch`) hay SHA đủ 40 hex. Cluster luôn **dựng ở đúng commit đã kiểm** (root và mọi nguồn values đọc SHA đó),
  nên PR promote merge giữa lúc dựng không đổi gì (lượt 40984138133 đỏ vì Argo CD theo nhánh, triển khai bản mới thành canary không
  traffic, `restartAt` của Rollout `web` không bao giờ Healthy); `GITOPS_REV` là nhánh thì sau vòng chờ root mới chuyển sang
  `refs/heads/<nhánh>` (Argo CD nhận tên đầy đủ, không bao giờ tên ngắn, vì tên ngắn có thể phân giải sang tag cùng tên; `follow_branch`,
  cũng chạy riêng được: `deploy/k8s/gitops.sh follow <nhánh>`): nhánh không đổi thì chỉ root sync, dòng `ok … follows refs/heads/…,
  still at <sha>`; nhánh đã đi tiếp thì một dòng `note` nêu hai commit, Argo CD triển khai bản mới như mọi lần phát hành (canary của
  gateway, web cần traffic: `make k8s-traffic-start`), script không chờ; `GITOPS_REV` là SHA thì cluster ở yên đó. `restart_workload`
  của `deploy/k8s/lib.sh` (restart sau khi Secret đổi, cả `glitchtip-init.sh`) gặp Rollout đang canary (pod template khác `stableRS`,
  pause, abort), trước hay giữa lúc restart, thì dừng ngay, nêu canary và cách gỡ, không chờ 300 s. Trước khi tạo gì, kiểm ở đúng revision đó cả 7 file `envs/stg/images/`: repository
  `ghcr.io/anhnvcoder/short-video-platform/<svc>`, manifest kéo ẩn danh được (package GHCR đã public), chữ ký và attestation `vuln`
  đúng identity, không CRITICAL, không quá 48 giờ (`deploy/ci/values-check.sh --gitops` trên bản trích `envs/stg` của revision, gọi
  `verify-release.sh --gitops`, bằng `cosign` trên PATH, không có thì `COSIGN_IMAGE`; quá hạn thì in lệnh dispatch rescan), và khi
  `svp-policy` bật provenance cho stg (values của chart ở commit `charts.yaml` rồi `envs/stg/svp-policy.yaml`) thì đúng một
  attestation provenance qua cùng phép kiểm như Kyverno, có `gitCommit` bằng commit trong chứng chỉ của chữ ký
  (`--certificate-github-workflow-sha`; thiếu thì in lệnh dispatch build lại service đó);
  thiếu một điều là dừng, không tạo gì. Rồi tạo namespace (chart `svp-cluster` ở commit `charts.yaml`; overlay stg bật
  `externalSecrets` nên có cả `svp-secrets`) và Secret từ `.env` (chế độ của `make k8s-secrets` ở trên), cài Argo CD theo
  `argocd/bootstrap.json` (chart, version, values `base/argo-cd.yaml`; namespace `argocd`, PSA `restricted`) với plugin Gateway API
  của Argo Rollouts theo kiến trúc node (`nodeArch` đọc từ node, cluster lẫn kiến trúc thì dừng; bản amd64 ở
  `base/argo-rollouts-amd64.yaml`, cùng file `install.sh` của đường dev đọc), AppProject `svp` và `default` đã khoá
  (`argocd/project.yaml`), root `svp-root` (`env=stg`); chờ mọi Application `Synced`, Healthy, sync cuối `Succeeded` (lỗi còn sau
  180 s thì dừng). Hết hạn chờ thì in trạng thái từng Application, tài nguyên chưa Healthy của nó (đọc thẳng từ cluster: Argo CD 3.x
  không ghi health của tài nguyên vào Application; workload theo pod ready, Job, PVC, condition của CR), condition của CR `Prometheus`,
  `Alertmanager`, đuôi log operator của kube-prometheus-stack và sự kiện, rồi dừng. kube-prometheus-stack trong `svp-gitops` có sync
  wave (CRD wave 0, operator 1, CR `Prometheus`/`Alertmanager` 2) vì operator chỉ dò CRD một lần lúc khởi động (lượt 40938235138
  kẹt bootstrap trước khi có wave). Component `external-secrets` của `components.json`
  (External Secrets Operator 2.14.0, namespace `external-secrets`, wave 0, values `base/external-secrets.yaml`: chỉ
  controller, không webhook, không cert-controller) có `gitopsOnly: true`, nên chỉ đường này cài, `make k8s-up` bỏ qua; chart
  `svp-cluster` với overlay stg render SecretStore `svp-store` (provider `kubernetes`, ServiceAccount `svp-secrets-reader` chỉ
  `get` theo tên đúng các entry namespace đó đọc), 28 ExternalSecret (`refreshPolicy: OnChange`, mọi cái có `target.template`),
  namespace và NetworkPolicy của `svp-secrets`, ValidatingAdmissionPolicy `svp-external-secrets-writes` (controller chỉ ghi Secret
  ở bốn namespace đích, không bao giờ Secret token) và `svp-store-serviceaccount-pods`, `-tokens` (ở mọi namespace không pod nào
  chạy dưới `svp-secrets-reader`, không Secret nào giữ token của nó; controller lấy token bằng TokenRequest); overlay prd render
  store `aws` (Secrets Manager `svp/prd/<entry>`, role mỗi namespace, giá trị giữ chỗ tới giai đoạn 7; controller thêm egress
  TCP 80 chỉ tới agent EKS Pod Identity `169.254.170.23/32`). Đã kiểm trên cluster: lượt `gitops` 40857855305 (28 ExternalSecret
  `Ready`) và 40954609229 (đọc `svp-gitops`, 26/26 Application Synced/Healthy, 28/28 ExternalSecret `Ready`).
  `measure-gitops` đo commit phát hành của `svp-gitops` (merge của PR
  promote ở repo đó) từ lúc push (reflog `origin/main` của bản clone, không có thì `merged_at` của PR có `merge_commit_sha` là commit
  đó, rồi PushEvent, cả hai qua `gh api` vào repo `svp-gitops` (`ci_push_time SHA REPO`), chỉ đọc, ghi nguồn) qua sync của Argo CD tới pod đầu
  và cuối Ready với digest mới; service có `migrate: true` ở revision đó thì Job migrate phải tạo trong cửa sổ của đúng sync
  đã đo và `restartCount` 0 (thiếu Job là FAIL, sync đang chạy là exit 2: đo lại); chỉ đọc, JSON ở `.k8s/drills/`. `k8s-gitops-up` đọc
  `svp-gitops` đã kiểm trên nhánh PR-B (lượt 40954609229, dựng 610 s); `measure-gitops` đo commit của `svp-gitops` **kiểm sau push**
  (bước chờ phát hành chỉ chạy trên `main`).
- `make k8s-traffic-start` / `make k8s-traffic-stop`: traffic diễn tập chạy nền, 4 user, ~10 request/s vào
  `GET /feed/explore`, `/feed/following` qua `https://api.svp.localhost:8443` và ~4 request/s vào web
  `https://svp.localhost:8443` (`GET /login`, một asset `/_next/static/...`; dòng log `web-login`, `web-asset`), mỗi
  request một dòng ở
  `.k8s/drills/traffic-<time>.log`, chạy tới khi dừng (qua cả lúc push phát hành trên cluster GitOps); `stop` chỉ dừng
  đúng pid đã ghi và in số request theo status. **LOCAL LAB ONLY:** đăng ký user mới và xoá khoá rate limit đăng ký ở
  Valkey db 10 của cluster.
- `make k8s-smoke`, `make drill-k8s-keda N=9`, `make drill-k8s-pdb`, `make drill-k8s-canary`, `make measure-canary`,
  `make drill-k8s-threats`: trên cluster đang chạy, qua Envoy với `.k8s/ca.crt` (thiếu thì chạy `make k8s-ca`), script ở
  `deploy/k8s/drills/` (`k8s-smoke` dùng `deploy/compose/smoke.sh`). Lần lượt: luồng đầu-cuối như `make smoke`; N (mặc
  định 9; chỉ 6, 9 hay 12) video 60 s 1080p, dàn đều đúng N/3 video mỗi partition (video tạo thừa để `UPLOADING`, job dọn
  upload xử lý sau 1 giờ), chờ tới 240 s cho tới khi mọi pod worker cùng có job liền 60 s trước khi ghim (không có thì FAIL
  riêng, không phải lỗi KEDA), đo KEDA scale media-worker lên tối đa 2 replica và về 1, lag đỉnh, mỗi
  `READY`, CPU/RAM, scale down một pod đang transcode (ghim `paused-replicas` của KEDA thấp hơn một, pod tắt êm) rồi kiểm
  mọi video transcode đúng một lần, và k3s server không restart suốt diễn tập (`RestartCount`, `StartedAt` của container
  `k3d-svp-server-0`, [ADR-0017](docs/adr/0017-gitops-capacity-media-worker-max2.md)); cordon node và evict lần lượt hai pod gateway rồi hai pod feed-service
  (feed-service hai replica, PDB `minAvailable: 1`, [ADR-0031](docs/adr/0031-chaos-findings-feed-engagement-tempo.md) §1) như drain:
  mỗi service PDB cho pod đầu (201), từ chối pod thứ hai (429) khi pod thay còn Pending, rồi uncordon, chờ lại 2 pod Ready và in
  node của hai pod trước và sau (hai pod cùng node chỉ là ghi chú: trải node là ưu tiên); canary của gateway trên cluster dev dưới traffic diễn tập:
  bản tốt qua 25%, 50%, 100% và được promote, bản lỗi (`FEED_SERVICE_ADDR` trỏ Service không có) bị phân tích abort,
  trọng số về 0, pod stable không đổi, rồi trả bản tốt; `measure-canary` đọc lại lần abort canary gần nhất (chỉ đọc);
  các dòng giai đoạn 4 của threat model, mỗi dòng có ca đối chứng (pod thử ở namespace `svp-probe` tạo rồi xoá,
  NetworkPolicy, ACL Kafka, PSA, `pg_hba`, RL-1 với `X-Forwarded-For` giả, pprof/metrics, UI không lộ, Grafana 401,
  RBAC: không ServiceAccount nào của `svp` đọc Secret hay pod, CloudNativePG và Envoy Gateway chỉ có quyền ở các
  namespace đã thu hẹp, ngoại lệ còn lại in kèm lý do) và các dòng web của giai đoạn 5b phần C (WEB-7, WEB-2, WEB-10,
  WEB-13, WEB-8; pod web ở FF-3, FF-4, IN-2; route `svp/web` ở OPS-2) và giai đoạn 6 (BAK-1:
  request S3 có chữ ký qua Envoy, user `svp-pg-backup` chỉ tới `pg-backups`, user service không tới được bucket đó; operator
  CloudNativePG ở `cnpg-system` không tạo pod, không exec, không sửa Deployment, không lấy token cho ServiceAccount nào, kiểm bằng
  `kubectl auth can-i` và tạo thử dry run dưới tên operator mà policy `svp-cnpg-operator-secrets` từ chối; ngoại lệ RBAC của
  plugin Barman Cloud in kèm lý do) và giai đoạn 6b phần 4 (SEC-5, SEC-6, SEC-7, chỉ trên cluster có External Secrets Operator,
  nơi khác in một dòng bỏ qua: ServiceAccount store mỗi namespace chỉ `get` đúng entry nguồn của namespace đó theo tên, không
  list/watch, không Secret nào khác (đối chứng: store của `svp` lấy được `pg-roles`, không lấy được `pg-superuser`), không kind
  `ClusterSecretStore`; controller chỉ lấy token cho ServiceAccount của store, dry run dưới tên controller ghi Secret Opaque ở
  `argocd` và Secret token ở `svp` bị `svp-external-secrets-writes` từ chối (đối chứng: Opaque ở `svp` qua), quyền đọc mọi Secret
  của controller in thành ngoại lệ SEC-5 kèm lý do, không webhook của ESO, pod thử không mở được cổng metrics 8080 của controller;
  không ServiceAccount nào của `svp` tạo được ExternalSecret hay SecretStore, ClusterRole `view`/`edit`/`admin` không cấp gì trên
  `external-secrets.io`; mục `SEC-6-reader`, cùng điều kiện: dry run ở `svp-data` (namespace có `svp-secrets-reader`), pod chạy dưới
  ServiceAccount đó và Secret token của nó bị `svp-store-serviceaccount-pods`, `-tokens` từ chối đúng message, đối chứng cùng pod với
  `default` và Secret token của `default` được nhận), log ở
  `.k8s/drills/threats-<time>.log` được dò các giá trị
  Secret đã đọc. Kết quả và JSON ở `.k8s/drills/`; script trả cluster về như cũ khi kết thúc (uncordon, bỏ ghim KEDA,
  trả bản gateway tốt). **LOCAL LAB ONLY:** trừ `measure-canary`, mọi target này xoá khoá `svp:gw:rl:register:*` ở
  Valkey db 10 của cluster (qua `kubectl exec`).
- `make drill-k8s-backup [MODE=latest|pitr]` (giai đoạn 6, ADR-0020 §5, script `deploy/k8s/drills/backup.sh`): diễn tập DR
  tại chỗ, chỉ cluster dev (`k3d-svp` trên `127.0.0.1:6550`, không cluster GitOps vì Argo CD tự sửa `serverName` về git): tạo
  database `svp_drill` (bảng `markers`, không đụng bảng của service), backup theo yêu cầu, 60 s dòng đánh dấu (`pitr` ép
  `pg_switch_wal` và đặt mục tiêu ở giữa), xoá Cluster `svp-pg` và PVC, **T0** dựng lại cùng tên bằng `bootstrap.recovery` vào
  thế hệ lưu trữ mới `svp-pg-<yymmddhhmmss>`, restart một lần 4 service có Postgres và GlitchTip, **T1** khi luồng
  `k8s-smoke` qua; RTO = T1 − T0, RPO theo dòng đánh dấu còn lại (không dòng nào trở lại thì in cận dưới `RPO at least N s`),
  số dòng mọi bảng của service trước/sau; WAL không lưu được hay backup chưa xong thì dừng trước khi xoá gì; **không bao giờ
  xoá backup**. JSON ở `.k8s/drills/backup-<time>.json`. Cần `.k8s/ca.crt`. **LOCAL LAB ONLY:** xoá khoá
  `svp:gw:rl:register:*` ở Valkey db 10 của cluster như `k8s-smoke`.
- `make drill-k8s-supplychain [SUPPLYCHAIN_UNSIGNED=<digest GHCR>] [SUPPLYCHAIN_VULNERABLE=<digest GHCR>]
  [SUPPLYCHAIN_NO_PROVENANCE=<digest GHCR>] [SUPPLYCHAIN_ENFORCE_TMP=1]` (giai đoạn 5, script `deploy/k8s/drills/supplychain.sh`): policy Kyverno của `svp`, mỗi ca
  một dòng PASS/FAIL/SKIP và chỉ PASS khi đúng message của rule cần từ chối; pod gửi bằng `--dry-run=server` (trừ ca b là
  Deployment thật, xoá sau). Ca: (a) bản phát hành đã ký, sạch được nhận, hai lần liền (lần hai từ cache); (b)
  `drill-unsigned` bị từ chối vì thiếu chữ ký; (c) `drill-vulnerable` bị từ chối vì CRITICAL, ca này tự đọc
  `scanFinishedOn` bằng cosign và FAIL khi quá 72 giờ, nên chạy trong 72 giờ sau khi dispatch image diễn tập (`gh workflow
  run images.yml --ref main -f drill=true`, người học chạy); (d) image registry k3d và Docker Hub bị từ chối vì prefix,
  mỗi lần dưới 1 s; (e) image không digest; (f) attestation quá hạn (policy tạm tuổi tối đa 5 s); (g) admission
  controller không lịch được: pod `svp` bị từ chối, pod ở namespace thử `svp-probe` được nhận; (h) ephemeral container
  chưa ký bị từ chối, đã ký được nhận; (i) UPDATE image chưa ký bị từ chối; (k) đường keyless với image công khai của nhà
  cung cấp khác (đúng identity nhận, sai identity từ chối; chỉ trên dev); (l) bản phát hành ký trước khi CI attest provenance
  (`SUPPLYCHAIN_NO_PROVENANCE`) bị từ chối đúng message của phép provenance, chỉ khi policy đang chạy kiểm provenance (có
  attestation `provenance`), không thì SKIP "policy off"; trước khi gửi pod, cosign (ẩn danh) kiểm image có chữ ký, đúng một
  `vuln` hai nền tảng không CRITICAL trong tuổi tối đa và không có provenance, thiếu một điều thì FAIL kèm lệnh rescan bản đó:
  bản cũ không còn trong `envs/*/images/` của `svp-gitops` nên rescan hằng ngày bỏ qua nó, phải `gh workflow run images.yml --ref
  main -f rescan=true -f values_ref=<SHA đủ 40 hex của commit repo code có digest đó>` (người học chạy; script in SHA đó, tìm trong
  lịch sử `deploy/k8s/values/services/` của repo này, nơi digest phát hành nằm trước khi tách `svp-gitops`) trong 72 giờ trước lượt
  diễn tập; kịch bản `gitops` tự tìm bản web mới nhất trong lịch sử đó có chữ ký mà không provenance, không có thì (l) SKIP. Đường dev là Audit nên script từ chối chạy trừ
  khi `SUPPLYCHAIN_ENFORCE_TMP=1`: chạy (k), nâng tạm `svp-policy` lên Enforce cho các ca còn lại rồi trả Audit; trên
  đường dev chưa có image ký nên (a), (b), (c), (f) và nửa nhận của (h) SKIP. Trên cluster GitOps (lượt 40954609229, nhánh PR-B):
  a–i và (l) PASS, (l) đúng message của phép provenance, (k) SKIP như thiết kế. Khi kết thúc script trả Kyverno, Argo CD sync, Audit về như cũ, xoá policy tạm, `svp-probe`, và so
  webhook với ảnh chụp đầu; JSON ở `.k8s/drills/`. Không gọi API của gateway, không xoá khoá rate limit nào.
- `make k8s-ui-grafana`, `k8s-ui-prometheus`, `k8s-ui-alertmanager`, `k8s-ui-glitchtip`, `k8s-ui-argocd`: port-forward chỉ
  trên `127.0.0.1` (lần lượt 3000, 9090, 9093, 8000, 8081) trong lúc target chạy (Ctrl-C để đóng); không HTTPRoute,
  LoadBalancer hay NodePort nào cho UI (OPS-2). Grafana đăng nhập `admin` + `SVP_GRAFANA_ADMIN_PASSWORD`, GlitchTip bằng
  `GLITCHTIP_ADMIN_EMAIL`/`GLITCHTIP_ADMIN_PASSWORD`, Argo CD (cluster GitOps, chứng chỉ tự ký) `admin` với mật khẩu đọc
  bằng lệnh target in ra; Prometheus và Alertmanager không có đăng nhập nên chỉ mở khi forward đang chạy.
- `make k8s-web-sourcemaps`, `make k8s-web-e2e`, `make drill-k8s-web-obs` (giai đoạn 5b phần C,
  [ADR-0019](docs/adr/0019-web-k3d-supply-chain-observability.md)), trên
  cluster dev: `k8s-web-sourcemaps` như `web-sourcemaps` với bản build mà cluster chạy (`web_build_id`) và token của Secret
  `svp-obs/glitchtip-sourcemaps`, qua port-forward riêng `127.0.0.1:8000`; `SOURCEMAPS_DIR=<thư mục tuyệt đối>` tải chunk và
  map của thư mục đó thay vì build (artifact `web-sourcemaps-amd64` của CI cho image mà cluster GitOps chạy, kịch bản `gitops`),
  vẫn kiểm mọi chunk `/login` đang phục vụ có debug ID trong bộ map; `k8s-web-e2e` chạy e2e của web vào
  `https://svp.localhost:8443` (`web/e2e/k3d-e2e.sh`: `SVP_STACK=k3d`, CA `.k8s/ca.crt`, cookie `__Host-Http-svp_sid` +
  `Secure`), `SVP_E2E_GLITCHTIP=1` đọc token chỉ đọc của Secret `svp-obs/glitchtip-api` vào môi trường của lượt chạy và tự mở
  forward `127.0.0.1:8000`, `SVP_E2E_EVIDENCE` như `web-e2e`; `drill-k8s-web-obs` (chỉ đọc, sau `k8s-web-e2e`) kiểm Tempo có
  trace với span của `web` và gateway, Prometheus có histogram RUM LCP, CLS (INP khi có tương tác) với nhãn route đóng và
  in p75, event GlitchTip của lượt `SVP_E2E_GLITCHTIP=1` có frame đã map (`SVP_WEB_OBS_SKIP_ERRORS=<lý do>` bỏ riêng phép kiểm
  này, in `SKIP  errors (<lý do>)`; rỗng hay chỉ khoảng trắng bị từ chối; chỉ kịch bản `gitops` trên nhánh đặt); forward riêng `127.0.0.1:13200` (Tempo), `19090`
  (Prometheus), `8000` (GlitchTip), cổng bị chiếm thì dừng. **LOCAL LAB ONLY:** `k8s-web-e2e` xoá khoá
  `svp:gw:rl:register:*` ở Valkey db 10 của cluster.
- `make drill-k8s-web-canary` (giai đoạn 6b phần 3, script `deploy/k8s/drills/web-canary.sh`, client trình duyệt
  `web/e2e/canary/clients.ts` chạy bằng Node 26 và Playwright của `web/`; chỉ trên runner, không chạy trên máy 16 GB): trên
  cluster dev, build lại web từ working tree với `SVP_BUILD_ID` khác (`build_image` của `deploy/k8s/lib.sh`, image khác bản đang
  chạy thì mới đi tiếp) làm canary 25 %, 50 %, 100 % dưới traffic diễn tập và bốn client trình duyệt (một tab cũ mở trước canary
  gửi Server Action đều đặn), phải promote; bản lỗi (`GATEWAY_URL` trỏ Service không có, `/api/feed/explore` 502) phải bị phân
  tích abort, route về 100/0, pod stable không đổi; rồi trả build cũ bằng canary thứ hai. AnalysisRun nền đạt khi trong giới
  hạn khai ở chính spec của nó, mỗi lần đo trượt in một dòng `note`. Đếm mỗi client số lần tải lại theo nguyên nhân (action 409,
  chunk 404), điều hướng toàn trang do lệch `deploymentId`, tỷ lệ Server Action 409 (> 10 % in dòng `TASK`), 404 của
  `web-asset`, restart pod web; không tín hiệu lệch bản nào là "inconclusive" (exit 1). Trap trả `GATEWAY_URL` và build cũ (chỉ
  khi `GATEWAY_URL` đã về), dừng client và traffic đúng pid. JSON ở `.k8s/drills/web-canary-<time>.json`. **LOCAL LAB ONLY:**
  xoá khoá `svp:gw:rl:register:*` ở Valkey db 10 của cluster.
- `make cloud-check` (giai đoạn 6, ADR-0020 §8, script `deploy/k8s/cloud/check.sh`): kiểm tĩnh manifest viết sẵn cho cluster
  đo thật (giai đoạn 6b, 7) không cần cluster hay `.env`: `helm template` chart của `deploy/k8s/cloud/charts.json` (Chaos
  Mesh, Velero), manifest của `deploy/k8s/cloud/chaos/`, `velero/`, Job k6 do `deploy/k6/cloud/render.sh` in, rồi
  kubeconform `-strict` (`KUBECONFORM_IMAGE` ghim; schema Kubernetes `CLOUD_K8S_VERSION` của `deploy/k8s/k8s.mk` ở commit
  ghim, schema CRD sinh từ CRD của đúng bản chart ghim; kind không có schema là FAIL); mọi thí nghiệm Chaos Mesh có
  `duration` và chỉ chọn pod của namespace của nó, mọi image ghim `@sha256:`; render cả bản có values phủ chỉ cho runner
  (`runnerValues` của `charts.json`: `deploy/k8s/cloud/runner/chaos-mesh/`, `velero/`) và manifest `deploy/k8s/cloud/runner/csi/`
  (driver CSI hostpath, external-snapshotter, schema CRD của bản ghim), kiểm controller Chaos Mesh chỉ có quyền ở namespace đích.
  Cần mạng (repo chart, GitHub). `deploy/k6/cloud/render.sh --pods N` (mặc định 20, pod i chạy segment i/N, giữ phần tải mỗi
  pod của thiết kế 20 pod), `--ramp`, `--hold` (cú pháp `SVP_K6_HOLD`; hạn Job tính theo cả lượt khi đặt), `run.sh --pods N
  [--ramp D] [--hold D] start`. Lệnh chạy thật (`deploy/k6/cloud/run.sh`, `deploy/k8s/cloud/velero/drill-restore.sh`, `helm`,
  `kubectl apply` của Chaos Mesh) do người học chạy với context của cluster đo ghi trong lệnh; script từ chối context `k3d-*` và
  context rỗng, trừ **chế độ runner**: context đúng `k3d-svp` khi `ci_hosted_runner` của `deploy/ci/platform.sh` exit 0 (job trên
  runner dùng một lần do nền tảng CI cấp) và `uname -s` là `Linux`, kiểm trước mọi `kubectl` (chặn tai nạn cho máy, không phải
  ranh giới bảo mật). Ở chế độ đó `run.sh` thêm CA `.k8s/ca.crt`, origin web `https://svp.localhost:8443`, request CPU 250m và
  limit 1 CPU cho pod k6; `drill-restore.sh` backup `svp-data` theo nhãn của Redpanda và fixture, chỉ xoá StatefulSet, PVC của
  Redpanda và ConfigMap fixture, bỏ bước Argo CD khi cluster không có Argo CD, tự chạy `make k8s-smoke`. `SVP_K8S_RUNNER_CSI=1`
  (chỉ kịch bản `velero`, chỉ mở ở chế độ runner) cho `make k8s-up` cài driver CSI hostpath ngay trước release `redpanda`.
- `make hooks`: bật git hook ở `.githooks/` một lần cho mỗi clone. `pre-commit` chạy `gofmt` trên file Go đã stage,
  `golangci-lint run`, `buf lint` và `gitleaks` trên thay đổi đã stage.
- Giai đoạn 5, CI trên GitHub Actions ([ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md)); từ giai đoạn 6b thêm workflow
  thứ ba `verify.yml` ([ADR-0021](docs/adr/0021-deferred-verification-stage6b.md)) và thứ tư `dora.yml`
  ([ADR-0028](docs/adr/0028-dora-metrics.md)). Bốn workflow, mọi action
  ghim SHA commit, `permissions: {}` ở đầu file và quyền khai theo job; mọi job của lượt `pull_request` (cả PR từ fork)
  chỉ có `contents: read` và không secret; không `pull_request_target`, `workflow_run`. CI trung lập nền tảng
  ([ADR-0023](docs/adr/0023-ci-platform-neutral.md)): YAML chỉ nối bước, logic ở `Makefile` và `deploy/ci/`; mọi chỗ đọc
  ngữ cảnh CI hay gọi API của nền tảng (output, summary, mask, link lượt chạy, PR, dispatch) đi qua hàm `ci_*` của adapter
  `deploy/ci/platform.sh` (chế độ `github` trong Actions, `local` khi chạy script trên máy; CI khác thì dừng);
  `deploy/ci/platform-guard.sh` báo script nào khác đọc biến `GITHUB_*` hay gọi `gh api|pr|run|workflow`:
  - `.github/workflows/ci.yml` (PR, push `main`, dispatch): `check` (`make check-go TESTFLAGS=-count=1`, Postgres và
    Redis là service container trên `127.0.0.1`, ffmpeg), `web` (Node theo `web/.nvmrc`, pnpm theo `packageManager`, Redis
    service container; `make web-install`, `make web-check`, `make web-generate-check`, `make web-lockfile-scan` chạy cả khi
    bước trước đỏ, SARIF `trivy-lockfile-web`), `generate` (`make generate-check`), `buf` (`buf breaking` so với
    merge-base của PR, `main` trước push, hay merge-base với `origin/main` khi dispatch), `config`
    (đủ lịch sử, `make gitops-clone` và `SVP_GITOPS_DIR` ở `env` của job; `deploy/ci/scan-gate.sh --check-ignorefile`,
    `deploy/ci/platform-guard.sh`, `deploy/ci/platform-test.sh`, `deploy/ci/promote-test.sh`, `deploy/ci/promote-prd-test.sh`,
    `deploy/ci/release-set-test.sh`, `deploy/ci/dora-test.sh`, `deploy/ci/provenance-predicate-test.sh`,
    `deploy/ci/verify-collect-test.sh`, `make slo-check`, `make otelcol-validate`, `make env` rồi `make compose-config`,
    `make helm-check`, `deploy/ci/gitops-check-test.sh "$SVP_GITOPS_DIR"`, `make k6-check`, `make cloud-check`),
    `gitleaks` (toàn lịch sử, `--redact`), `trivy-config` (chỉ báo), `sarif` (chỉ `main`), check tổng `ci-ok` (cần đủ 7 job,
    trừ `sarif` và `stack`). Job `stack` (giai đoạn 6, ADR-0020 §15; **chỉ báo, ngoài `ci-ok`**, không chặn merge; xem lại
    khi 20 lượt liên tiếp xanh, không lượt đỏ do môi trường, thì đưa vào `ci-ok`): `ubuntu-24.04`, tối đa 45 phút,
    `contents: read`, không secret; Postgres, Redis là service container publish trên `127.0.0.1` và IP bridge `172.17.0.1`
    (`make ci-bridge-check` dừng job khi gateway của network `bridge` khác địa chỉ đó; chỉ cho CI), gói apt
    `postgresql-client redis-tools ffmpeg jq`, rồi `make env`, `make up`, `make smoke`, `make web-install`, Playwright
    Chromium và WebKit, `make web-e2e`, `make load-ci`, `make web-lighthouse` (đỏ không làm job đỏ), `make dast` (cuối cùng,
    hạn bước 15 phút, đỏ không làm job đỏ), `make ps` khi lỗi, `make down` luôn chạy; artifact chỉ `k6-summary`
    (`summary.json` đã grep bí mật), `lighthouse` (báo cáo đã lọc cookie) và `dast` (chỉ `report.json`, `summary.json`, dò bí
    mật lại trước khi chép; tệp nghi bị bỏ kèm `::warning::`). Trước `make web-lighthouse` job bỏ hạn chế AppArmor `kernel.apparmor_restrict_unprivileged_userns` của runner
    (Chrome của Playwright cần user namespace cho sandbox). Đã kiểm ngày 2026-10-24 (lượt PR
    [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424), ba lần chạy liền xanh,
    quyền ở đầu log chỉ `Contents: read`, artifact chỉ hai loại).
  - `.github/workflows/images.yml` (PR, push `main`, dispatch, lịch hằng ngày): chỉ build service đổi so với base
    (`deploy/ci/changed-services.sh`; đổi `images.yml`, `deploy/ci/` (trừ `trivy-config-ignore.yaml`, script và test của
    `verify.yml`, `platform-test.sh`, `platform-guard.sh`, `promote-test.sh`, `record-stg.sh`, `gitops-check.sh` cùng `values-check.sh`, `verify-release.sh` (chỉ check `svp-gitops`,
    `make k8s-gitops-up` và diễn tập chạy hai script này), `dora.sh` và test
    `gitops-check-test.sh`, `dora-test.sh`, `release-set-test.sh`, `promote-prd-test.sh`: không job image nào đọc chúng;
    `release-set.sh`, `promote-prd.sh` vẫn tính vì job `promote-prd` chạy chúng), `deploy/k8s/lib.sh` hay dòng
    `TRIVY_IMAGE`/`SYFT_IMAGE`/`GRYPE_IMAGE`/`COSIGN_IMAGE` của `Makefile` thì cả bảy; `web` chỉ build khi đổi file dưới `web/` hay
    `deploy/docker/web.Dockerfile`, context `web/`, `SVP_BUILD_ID` là 12 hex của commit). Base: push `main` so với lượt
    push `main` thành
    công cuối (lượt dispatch không đẩy base, nên thay đổi chỉ dispatch đã phát hành, như push GitHub không chạy workflow,
    được build lại ở push kế); PR so với merge-base với nhánh base; dispatch so với merge-base với `origin/main` (trên
    `main` là chính HEAD, nên không build gì), input `services` (`all` hay tên cách bằng khoảng trắng) ghi đè phép so. Mỗi
    service hai chân amd64, arm64 build native,
    trivy chặn bí mật (mọi severity) và CRITICAL **trước** push; grype ([ADR-0030](docs/adr/0030-devsecops-supplement.md) §6)
    quét SBOM syft của chân đó, cũng trước push: CRITICAL còn lại sau `.trivyignore.yaml` chặn (`--allow-critical` chỉ cho image
    diễn tập `drill-vulnerable`), HIGH trở xuống chỉ đếm, một hàng `(grype)` trong summary cạnh hàng trivy, thấy cả binary ngoài
    trình quản lý gói (`node` của web) mà trivy không thấy; DB grype cache theo ngày (`SVP_GRYPE_CACHE`), SARIF category
    `grype-image-<svc>-<arch>/` chỉ lên tab Security ở `main`; push lên `ghcr.io/anhnvcoder/short-video-platform/<svc>`
    đúng bản đã quét, ghép index, ký keyless bằng cosign kèm attestation `vuln` (kết quả trivy của hai nền tảng; attestation,
    Kyverno và rescan hằng ngày không đọc grype), SBOM syft mỗi nền tảng và **build provenance**
    ([ADR-0027](docs/adr/0027-slsa-build-provenance.md); chỉ bản phát hành, không image diễn tập): predicate SLSA v1 do
    `deploy/ci/provenance-predicate.sh` dựng chỉ từ hàm `ci_*` của `platform.sh` (`buildType` GitHub workflow/v1, workflow
    `ref`/`repository`/`path`, input `services` của dispatch khi có, commit, `builder.id`, `invocationId`), dựng và kiểm **trước**
    khi ký gì (`builder.id` phải bằng identity ký của values `svp-policy`, không thì không ký), attest `--type slsaprovenance1` định
    dạng cũ `--replace` trên digest index sau `vuln`; mức SLSA ghi trung thực là Build L1 (predicate do script của repo dựng); rồi
    **promote stg sang `svp-gitops`** ([ADR-0025](docs/adr/0025-gitops-config-repo.md) §2, §6): job `promote` (chỉ `main`,
    environment `promote` chỉ nhận deployment branch `main`, biến `SVP_GITOPS_APP_CLIENT_ID` và secret `SVP_GITOPS_APP_PRIVATE_KEY`
    của GitHub App `svp-gitops-promoter` chỉ cài trên `svp-gitops`) đổi khoá thành token 1 giờ bằng `actions/create-github-app-token`
    (ghim SHA; chỉ repo `svp-gitops`, chỉ `contents`, `pull_requests` write, thu hồi cuối job; `GITHUB_TOKEN` của job chỉ
    `contents: read`, mọi checkout `persist-credentials: false`), rồi `deploy/ci/promote.sh` clone `svp-gitops` ẩn danh, dựng nhánh
    `bot/promote-stg` một commit của bot App trên `main` của repo đó, chỉ ghi `envs/stg/images/<svc>.yaml` và `envs/stg/charts.yaml`
    (`revision` = commit của lượt, hai khoá dẫn xuất `podSecurityVersion`, `collectorConfigSha256` tính từ đúng commit đó; không bao
    giờ lùi theo luật tổ tiên, image mới hơn `revision` bị từ chối), push `--force-with-lease`, mở hay cập nhật PR và bật
    auto-merge (squash, `--match-head-commit`); đọc lại PR sau push, PR đã merge hay đóng giữa chừng thì job đỏ. PR chỉ đổi
    `envs/stg/` (không Code Owner) nên tự merge khi `gitops-ok` xanh, không ai duyệt. Lượt push `main` không build image nào mà đổi
    `deploy/helm/` hay file chart đó đọc qua symlink (`promote_charts` của `plan.sh`) vẫn chạy `promote`, chỉ ghi `charts.yaml`. Lượt PR
    chỉ build và quét (`build-nopush`); job `values-check` đã bỏ (digest không còn ở repo này; `values-check.sh --gitops` chạy trong
    check của `svp-gitops`). Dispatch `-f services=<tên…|all>` build, ký và promote lại các service đó ở commit được dispatch,
    `-f rescan=true [-f values_ref=<ref>]` quét lại mọi digest phát hành (lịch hằng ngày làm việc này): job `rescan` chạy
    `make gitops-clone` rồi `rescan.sh run`, tập digest là `envs/*/images/` của `svp-gitops` ở `main`, ở PR `bot/promote-stg` đang mở và
    ở `values_ref` (ref của `svp-gitops`, hay SHA đủ 40 hex của commit repo này trước khi tách, còn `deploy/k8s/values/services/`, cho
    ca (l) của `drill-k8s-supplychain`); đọc PR bot lỗi thì vẫn quét `main` và `values_ref` rồi mới đỏ; `-f drill=true` đẩy hai image
    diễn tập. **Promote prd** (ADR-0024 §8): dispatch `-f promote_prd=true [-f record=<id>]` trên `main` (một mình, không kèm
    `services`, `rescan`, `values_ref`, `drill`; `plan` bỏ qua mọi job khác) chạy job `promote-prd` (environment `promote`, token App
    `contents`, `pull_requests` write, `deployments` read): `deploy/ci/promote-prd.sh` chép **cả bộ** bảy release và `charts` của một
    bản ghi stg (mặc định mới nhất; bản cũ hơn là rollback) vào `envs/prd/images/`, `envs/prd/charts.yaml` trên nhánh `bot/promote-prd`,
    mở PR không auto-merge (Code Owner duyệt), mô tả ghi id bản ghi, commit stg, lượt kiểm; bản ghi có `ref` không còn trên `main`
    của `svp-gitops` bị từ chối. Check tổng `images-ok` (dispatch promote prd: `plan` skipped vẫn xanh). Provenance trên bản phát hành
    thật đã kiểm (bảy bản của `6ca2d8a`, `cosign verify-attestation --type slsaprovenance1` và lượt `gitops` 40954609229). Lần promote
    stg đầu, auto-merge của PR bot, promote prd và rescan đọc `svp-gitops`: **kiểm sau push**.
  - `.github/workflows/verify.yml` (giai đoạn 6b, [ADR-0021](docs/adr/0021-deferred-verification-stage6b.md); không check
    bắt buộc nào, không chạy ở PR): kiểm chứng trên runner `ubuntu-24.04` những gì máy 16 GB không chạy nổi, bằng đúng
    target `make` như trên máy. Trigger: `workflow_dispatch` (chỉ người có quyền ghi; ref `main` hay `feat/stage6b-*`, ref
    khác dừng ở bước đầu) và lịch hằng tuần trên `main` (00:37 UTC thứ Bảy, 07:37 giờ Việt Nam; `compose-obs`, `dev-k3d` và
    `gitops` song song, mọi bước, xong trước `dora.yml`; **kiểm sau push**). Kịch bản: `compose-obs` (job `compose`, hạn 120 phút: `make up OBS=lgtm`, `make smoke`,
    `make drill-duplicates`, `make drill-kill-worker`, `make drill-obs-threats`, `make load-local` dưới quan sát Alertmanager (`RateLimitFallbackActive` không được cháy),
    `make web-lighthouse` ×3 và median LCP, `make test-stack PKGS=./internal/objstore/...` (một ca SKIP là đỏ; gồm ba test của output bất biến),
    `make drill-upload-cleanup`, `make measure-upload` và RAM đỉnh của `s3` trong lúc đó (dưới 512 MiB), `make
    drill-alert-to-sentry` với Telegram SKIP, cuối cùng đường quay lại `object-store-roundtrip`: `make down`, `make
    object-store-copy TO=minio` vào volume mới của runner, rồi `make up` lần hai (init chạy lại trên store đã init) và `make
    smoke` trên RustFS) và `dev-k3d` (job `k3d`, hạn 330
    phút: `make k8s-up`, `make k8s-smoke`, RAM nghỉ, `make drill-k8s-threats`, `make drill-k8s-pdb`, `make drill-k8s-canary`,
    `make k8s-web-sourcemaps`, `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e`, `make drill-k8s-web-obs`, `make drill-k8s-keda N=9` và
    RAM đỉnh, `make drill-k8s-backup` rồi `MODE=pitr`, RAM nghỉ cuối). Phần 3 (chỉ dispatch, không vào lịch, trừ `gitops` vào lịch từ
    2026-10-30): `gitops` (job `gitops`, hạn 330 phút: bước `Find the source maps of the web image`, rồi bước kịch bản 175 phút: `make k8s-gitops-up`
    (vai stg; `make gitops-clone` trước; `GITOPS_REV` là SHA của `origin/main` trong bản clone, nên cluster ở yên commit đó suốt các bước
    kiểm, bộ mà `release-set` ghi không đổi giữa chừng), `gitops-env` (overlay stg có trên pod
    gateway), `gitops-external-secrets` (ExternalSecret của cluster đúng bằng danh sách của chart, mỗi cái `Ready`, Secret đích đúng
    type và đúng tên key, không đọc giá trị), `release-set-before` (`deploy/ci/release-set.sh snapshot --settle`: chờ tới ~300 s mọi
    Application Synced, Healthy, không sync đang chạy qua hai lần đọc liền rồi mới chụp; hết hạn vẫn ghi bản chụp nhưng bước đỏ;
    lượt 40944295274 đỏ vì HPA Degraded thoáng qua trước khi có bước chờ), `gitops-argocd-metrics` (trong 180 s Prometheus thấy
    `argocd_app_info` của mọi Application, đều Synced và Healthy, không cảnh báo `ArgoCDApplication*` nào cháy; chart stg đang chạy
    chưa có PodMonitor của Argo CD thì nói vậy và qua), `make k8s-smoke` (chặt, không biến chuyển tiếp), RAM nghỉ,
    `make drill-k8s-supplychain` (ca
    chưa ký là manifest con `linux/amd64` của digest web đang chạy; ca (l) là bản web mới nhất có chữ ký mà không provenance,
    tìm bằng cosign ẩn danh, bỏ qua bản build từ commit đã có `provenance-predicate.sh`; chỉ ở lượt lịch, `SVP_VERIFY_SCHEDULED=true`,
    image của ca (c) hay (l) có attestation `vuln` quá 72 giờ thì không đưa cho drill: ca đó SKIP kèm dòng `NOTE` nêu tuổi và lệnh
    dispatch dựng lại image diễn tập hay rescan, mọi ca khác vẫn phải PASS; lượt dispatch quá hạn là đỏ, nên (c), (l) chỉ được chứng
    minh ở lượt dispatch sau lượt đó), `make drill-k8s-threats`, source map của image CI
    (`deploy/ci/gitops-sourcemaps.sh` chọn lượt `images.yml` có `image-digest` bằng manifest con đó; trên nhánh `feat/stage6b-*`
    không có thì `skipped`, e2e không GlitchTip, `drill-k8s-web-obs` bỏ riêng `errors`; trên `main` thì FAIL), `make
    k8s-web-e2e`, `make drill-k8s-web-obs`, `make drill-k8s-keda N=9` hai lần mỗi lần kèm RAM đỉnh, RAM nghỉ cuối, `release-set`
    (chụp lại sau bước kiểm cuối; `verify` chỉ ghi `release-set.json` khi revision `svp-gitops` R như nhau ở hai lần chụp và ở mọi
    Application, history không thêm mục, mọi pod của mỗi service một digest và bộ bảy digest bằng `envs/stg/images/` ở R, chart của
    mọi Application một commit bằng `envs/stg/charts.yaml` ở R; `k8s-smoke` không chạy hay đỏ, hay `targets` bỏ một bước nào của kịch
    bản ngoài `wait-release`, `measure-gitops`, thì SKIP); rồi bước
    `Waiting for a release on main` 115 phút: trên `main` bật traffic diễn tập, chuyển root sang `refs/heads/main`
    (`deploy/k8s/gitops.sh follow main`, dòng `ok`/`note` vào log job; nhánh đã đi tiếp trong lúc ghim thì các commit đó chỉ triển
    khai lúc này, thời gian từ push sẽ tính cả lúc ghim nên không đo: một dòng `not measured` nêu hai commit và các bản phát hành trong
    đó, vòng chờ tính từ commit Argo CD vừa nhận), chờ tối đa 90 phút một commit của `main` `svp-gitops`
    đổi đúng một digest ở `envs/stg/images/` (bản phát hành tới bằng auto-merge của PR bot, không cần merge tay), `make
    measure-gitops`; trên nhánh hay ở lượt lịch thì `skipped`; bước này không chụp lại, không ghi đè `release-set.json`). Job
    `record-stg` (`needs: gitops`, chỉ khi output `recorded` của job đó là `true`, tức bước kịch bản xanh và `release-set.json` có
    trong artifact, bước chờ phát hành đỏ không chặn; lượt không bị huỷ, ref `main`; environment `promote`, token App chỉ `deployments` write trên `svp-gitops`; không
    chạy kịch bản nào): `deploy/ci/record-stg.sh` tạo Deployment GitHub environment `stg` trên `svp-gitops` (`ref` = R, payload
    = `release-set.json`: bảy `repository@digest`, `charts`, R, `deployed_at`, URL lượt; `auto_merge: false`, `required_contexts: []`;
    trạng thái `success`): đó là **bản ghi stg** mà promote prd chép và check prd so. Lượt `gitops` 40954609229 (nhánh PR-B, mọi
    bước) 17/17 target ok; `record-stg` và bước chờ phát hành trên `main`: **kiểm sau push**), `web-canary` (`make k8s-up`, `make k8s-smoke`, `make drill-k8s-web-canary`), `k6-cloud-mini`
    (`make k8s-up`, seed ≥ 30 video `READY`, Job k6 profile `cloud` 1, 2, 4, 8 pod qua `run.sh --pods N`, mỗi mức lên 2 phút,
    giữ 10, xuống 1, dừng ở mức đầu tiên trượt; mỗi mức ghi số k6, khoá rate limit bằng số pod, p95/p99 phía server, CPU,
    throttle, working set của web; sau mỗi mức step `tempo-ingest-<n>`; **LOCAL LAB ONLY:** xoá khoá đăng ký giữa hai mức), `chaos` (`make k8s-up`, seed, cài Chaos
    Mesh với values phủ của runner (chỉ controller không multi-cluster; controller phải giữ cùng pod, 0 restart, không dòng
    `is forbidden` trong 150 s), bản thử NetworkChaos trên pod thử (nạp `sch_netem`, thiếu thì cài `linux-modules-extra-<kernel>`;
    không nạp được thì FAIL và (b) không chạy), thí nghiệm (a), (b), (c) (mỗi `apply` chờ webhook có endpoint Ready),
    mỗi thí nghiệm một lượt k6 1 pod riêng dưới 55 phút có cửa sổ ổn định 5 phút riêng, sau mỗi thí nghiệm step
    `tempo-ingest-chaos-<x>`, gỡ bằng lệnh của buổi cloud và kiểm không còn gì). Step `tempo-ingest-*` (`deploy/ci/verify-tempo.sh`,
    [ADR-0031](docs/adr/0031-chaos-findings-feed-engagement-tempo.md) §3) đọc cửa sổ giữ tải của step trước ở `k6-windows.tsv` (không
    có thì skip, kết quả không chặn step sau): đạt khi 0 span bị receiver của Collector từ chối hay lỗi, exporter `otlp_grpc/tempo`
    gửi lỗi hay không vào được hàng đợi, Tempo bỏ (`tempo_discarded_spans_total`), container `tempo` không khởi động lại trong cửa sổ,
    tìm và lấy được theo id một trace của gateway có ≥ 2 service, cạnh gateway → feed-service của service graph tăng; mức 8 pod chỉ ghi
    số; JSON ở `.k8s/drills/tempo-ingest-<nhãn>-<time>.json`; `velero` (`SVP_K8S_RUNNER_CSI=1 make k8s-up`, bucket và user `svp-velero`, cài Velero, kiểm NetworkPolicy, seed bằng
    smoke và fixture, `drill-restore.sh` chế độ runner, sweep, gỡ). Dispatch và đọc kết quả (AI được chạy, chỉ khi người
    học giao): `gh workflow run verify.yml --ref <main|feat/stage6b-…> -f
    scenario=<compose-obs|dev-k3d|gitops|web-canary|k6-cloud-mini|chaos|velero> [-f targets='<bước> …']` (`targets` rỗng là mọi
    bước, bước dựng luôn chạy; tên bước ở `results.tsv`), `gh run view <id> --log`, `gh run download <id> -n verify-<kịch
    bản>`. Job `compose`, `k3d` chỉ `contents: read`; job `gitops` thêm `actions: read` (artifact source map) và
    `pull-requests: read` (`merged_at` của PR promote cho mốc push của `measure-gitops`), `GH_TOKEN` chỉ ở bước tìm source map
    và bước chờ phát hành; không job nào chạy kịch bản hay build gì có secret hay environment, chỉ `record-stg` (chỉ chạy
    `deploy/ci/record-stg.sh` của `main`) có environment `promote`; `concurrency` một lượt mỗi kịch bản. Trình tự mỗi kịch bản ở
    `deploy/ci/verify/<kịch bản>.sh` (bước dựng, hạn job mặc định, danh sách bước). Script `deploy/ci/verify-*.sh` (chạy được
    trên VM Linux thay runner):
    `verify-host.sh` (cổng đĩa, `/etc/hosts` cho ba tên `*.svp.localhost`, lệch version kubectl, hạn chế AppArmor, `sudo
    modprobe sch_netem` cho `chaos`), `verify-run.sh` (nạp trình tự của kịch bản, hạn mỗi target, output mỗi target vào file thay
    vì log job, dừng sớm khi bước dựng đỏ),
    `verify-sample.sh` (mẫu RAM, CPU, đĩa, `docker stats`, `memory.stat` của node, `kubectl top` mỗi container của namespace
    `svp`, `svp-data`, `cnpg-system`, `svp-obs` ở `pods.tsv`, số pod media-worker đang chạy `ffmpeg`,
    số restart của từng container compose, `cpu.stat` của pod k6 trong cửa sổ giữ ghi ở `k6-windows.tsv`;
    `runner.json`, `runner.txt` "runner đủ"), `verify-mask.sh` (`::add-mask::` giá trị bí mật của `.env` sau mỗi target và
    của Secret trong cluster, gồm `chaos-mesh`, `svp-load`, `velero`, `svp-secrets`), `verify-collect.sh` (artifact `verify-<kịch bản>`, giữ 30 ngày: chỉ file theo danh sách cho
    phép, quét theo giá trị bí mật đã biết và theo mẫu, file nghi bị bỏ kèm `::warning::`, `files.txt` liệt kê file giữ và
    bỏ; đầu ra target bỏ dòng log JSON, access log và dòng log container `    [<namespace>] …` ngoài `log_tail_namespaces` của
    `deploy/k8s/lib.sh`: chỉ đuôi log hạ tầng bên thứ ba mà `make k8s-up` in khi release không Ready, không bao giờ `svp`; giữ
    `release-set.json` ở gốc artifact). `verify-run.sh` chạy `make gitops-clone` và export `SVP_GITOPS_DIR` trước kịch bản k3d (clone
    lỗi thì không target nào chạy). `deploy/ci/verify-collect-test.sh` chạy trên máy và ở job `config` (giá trị giả,
    `docker`/`kubectl` giả, không mạng).
  - `.github/workflows/dora.yml` (giai đoạn 6b phần 4, [ADR-0028](docs/adr/0028-dora-metrics.md)): lịch thứ Bảy 09:17 UTC (sau
    lịch của `verify.yml`) và dispatch `gh workflow run dora.yml --ref main [-f days=<1..3650>]` (mặc định 30); không `pull_request`;
    job `dora` chỉ `contents: read`, `actions: read` (đọc lượt mà mỗi bản ghi chỉ tới), không secret, không environment; `make
    gitops-clone` rồi `deploy/ci/dora.sh --days N <file>`: deployment frequency, change lead time, change fail rate, failed deployment
    recovery time, deployment rework rate của **stg lab**, tính trên bản ghi stg `success` của `svp-gitops` (bằng chứng triển khai,
    không phải merge; nhiều bản ghi cùng revision và bộ digest là một deployment), lịch sử git hai repo và front matter của
    `docs/postmortems/`; chỉ số thiếu dữ liệu in "chưa đủ dữ liệu" kèm lý do (ngưỡng 5 mẫu lead time, 10 deployment cho tỷ lệ),
    prd in "chưa có dữ liệu prd"; số PR promote đã merge (bỏ commit khởi tạo của `svp-gitops`) và digest đã merge chưa triển khai in
    riêng; danh sách đủ 100 bản ghi (trần của `ci_deployment_list`) thì cảnh báo. Bảng vào tóm tắt của lượt, JSON vào artifact
    `dora` (30 ngày). Chạy trên máy: `deploy/ci/dora.sh <file>` (chế độ `local`, đọc bản clone `../gitops`, chỉ đọc). Lượt đầu:
    **kiểm sau push**.
  - **`svp-gitops`** (`https://github.com/anhnvcoder/svp-gitops`, public, không secret; [ADR-0025](docs/adr/0025-gitops-config-repo.md),
    quy trình tay ở [`docs/runbooks/svp-gitops-setup.md`](docs/runbooks/svp-gitops-setup.md)): `base/` (values gốc của chart upstream,
    `argo-cd.yaml`, `services/<svc>.yaml` không khối `image`), `envs/{stg,prd}/` (overlay, `svp-policy.yaml`, `charts.yaml` ghim
    commit chart của repo này cùng hai giá trị dẫn xuất, `images/<svc>.yaml` chỉ khối `image`), `argocd/` (`project.yaml`,
    `bootstrap.json`, chart app-of-apps `apps/` với `components.json`), `CODEOWNERS` (`*` của người học, `/envs/stg/` không chủ),
    `renovate.json` (chart upstream, image ghim trong `base/`, commit checker; bỏ qua `envs/**`). Check: `.github/workflows/check.yml`
    (PR và push `main`, chỉ `contents: read`, `deployments: read`, không secret) checkout repo này ở `CHECKER_COMMIT` (SHA đủ, một chỗ
    trong workflow; đổi bằng PR ở `svp-gitops`) rồi chạy `deploy/ci/gitops-check.sh <cây> <base>`: cây và `charts.yaml` (`revision`
    trên `main` repo này, hai giá trị dẫn xuất tính lại, tag mỗi image là tổ tiên của `revision`, khi provenance bật thì 12 hex của
    `gitCommit` bằng tag), PR đổi `envs/prd/images/` hay `envs/prd/charts.yaml` thì cả bộ phải bằng đúng payload của một bản ghi stg
    `success` do App tạo, lượt `verify.yml` trên `main`, `ref` trên `main` của `svp-gitops` (ghép từ hai bản ghi, bộ chỉ có trong lịch sử
    `envs/stg/`, chart khác bản ghi đều đỏ), render root theo env × kiến trúc (mọi `targetRevision` vào `svp-gitops` phải tên đầy đủ),
    chart repo ở `revision` của env với `base/` và overlay, External Secrets qua kubeconform, mọi image bên thứ ba ghim digest (thay
    `deploy/k8s/check-image-digests.sh` đã xoá), `values-check.sh --gitops` cho env có file image, `charts.yaml` hay `svp-policy.yaml`
    đổi; check tổng `gitops-ok`. `CHECKER_COMMIT` đang ghim `c59c742` (checker trước PR-B, chưa có bước so bản ghi prd): sau merge
    PR-B người học bump bằng PR ở `svp-gitops`, cùng lúc đưa `GH_TOKEN: ${{ github.token }}` cho bước chạy `gitops-check.sh` (đọc bản
    ghi stg), thiếu thì PR prd đỏ "records of stg cannot be read". Ba ruleset (`.github/rulesets/`): `main` (PR, `gitops-ok` bắt buộc, cấm xoá và force push, không ai
    bypass), `owners` (duyệt của Code Owner; vai admin bypass chỉ ở chế độ `pull_request`, có bản ghi), `tags` (cấm tạo, sửa, xoá tag;
    chỉ admin bypass), cộng dồn: PR bot chỉ đổi `envs/stg/` tự merge, PR prd và Renovate cần người học duyệt, PR của người học trên file
    có chủ merge bằng bypass `owners` mà vẫn cần `gitops-ok`. Đã kiểm: commit khởi tạo `55258e1`, commit thêm check `a84e26d`, lượt
    `check` đầu 40902199532 xanh (token chỉ `Contents: read`), ba ruleset `active` (2026-10-29); chặn PR chưa duyệt, bypass có bản
    ghi: **kiểm sau push**.
  - Check bắt buộc của ruleset `main`: `ci-ok`, `images-ok`, chỉ nhận từ app GitHub Actions. Ruleset, năm cài đặt repo
    của ADR-0015 §11 (quyền mặc định của `GITHUB_TOKEN` chỉ đọc kèm "Allow GitHub Actions to create and approve pull
    requests"; Actions chỉ cho action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc; duyệt workflow của PR
    fork cho mọi người ngoài; secret scanning + push protection; Dependabot alerts) và package GHCR public do người học bật
    (ADR-0015 §5, §11): **kiểm sau push**. Quyền deploy không còn ở repo này: push vào `main` không đổi cluster nào, chỉ PR vào
    `svp-gitops` đổi được thứ đang chạy; environment `promote` của repo này giữ khoá App, chỉ ba job trên `main` khai nó
    (`promote`, `promote-prd` của `images.yml`, `record-stg` của `verify.yml`), không job `pull_request` nào.
  - CodeQL **default setup** ([ADR-0030](docs/adr/0030-devsecops-supplement.md) §4): bật bằng cài đặt repo, không file workflow
    trong repo (GitHub dựng và giữ workflow động "CodeQL"); ngôn ngữ `actions`, `go`, `javascript-typescript`, query suite
    `default`, threat model `remote`; quét mỗi push `main`, PR từ nhánh của repo (không PR từ fork) và hằng tuần. **Chỉ báo:**
    không là check bắt buộc, cảnh báo ở tab Security (giả thì dismiss kèm lý do), gosec vẫn là cổng chặn. Job CodeQL chạy `make`
    không đối số của commit được quét (autobuild Go), token chỉ có quyền ghi `security-events` (đọc từ log ngày 2026-10-29).
    Lệnh bật, tắt và đọc kết quả (người học chạy) ở [`docs/ci-cd.md`](docs/ci-cd.md) mục 7.
  - Chạy lại một job trên máy, từ gốc repo: `make check-go TESTFLAGS=-count=1`; `make web-check`,
    `make web-generate-check`, `make web-lockfile-scan`; `make generate-check`;
    `buf breaking --against '.git#ref=<base>'`; `deploy/ci/scan-gate.sh --check-ignorefile`, `deploy/ci/platform-guard.sh`,
    `deploy/ci/platform-test.sh`, `deploy/ci/provenance-predicate-test.sh`, `make slo-check`,
    `deploy/ci/promote-test.sh`, `deploy/ci/promote-prd-test.sh`, `deploy/ci/release-set-test.sh`, `deploy/ci/dora-test.sh`,
    `make otelcol-validate`, `make compose-config`, `make helm-check`, `deploy/ci/gitops-check-test.sh ../gitops`, `make k6-check`,
    `make cloud-check`; check của `svp-gitops` trên bản clone: `deploy/ci/gitops-check.sh ../gitops` (cần mạng tới repo chart, GHCR;
    ~5 phút); `gitleaks git --redact --no-banner`; `make trivy-config`; một chân image (build, quét, cổng, không push):
    `deploy/ci/build-image.sh <svc> arm64 "$(mktemp -d)"`; riêng cổng grype của một chân: `make grype IMAGE=<ref>@sha256:<digest>
    [ARCH=amd64|arm64]` (syft ghim đọc image từ registry, ẩn danh) hay `make grype SBOM=<đường tuyệt đối tới SPDX JSON>`, in số
    gói và binary ngoài trình quản lý gói; bước `dast` của job `stack`: `make dast` trên stack `make up`; service nào sẽ build: `deploy/ci/changed-services.sh <base>
    HEAD`; bộ lọc artifact và sampler của `verify.yml`: `deploy/ci/verify-collect-test.sh`. Push GHCR, ký, attest chỉ chạy
    trong CI: không đăng nhập GHCR hay Sigstore từ máy. `deploy/ci/promote.sh` và `promote-prd.sh` trên máy (chế độ `local` của
    `platform.sh`) không gọi API nào (in lệnh `gh` thay vì chạy) và chỉ push khi địa chỉ `svp-gitops` (`PROMOTE_GITOPS_URL` thay được,
    push URL sau `pushInsteadOf`) là đường dẫn trên đĩa (`/…`, `./…`, `../…`, `file://…`); địa chỉ mạng thì dừng, trừ khi
    `PROMOTE_DRY_RUN=1` (in lệnh push thay vì push).
  - `make helm-check` (`deploy/ci/gitops-check.sh --worktree`, cùng script với check của `svp-gitops`; cần bản clone `../gitops`
    hay `SVP_GITOPS_DIR`): `helm lint` và `helm template` mọi chart của working tree với `base/` của bản clone (`HELM_*_HOME` trong
    thư mục tạm), cộng overlay và file image của từng môi trường `envs/<stg|prd>/` ([ADR-0024](docs/adr/0024-multi-environment.md);
    prd chỉ render, render prd không được còn `svp.localhost`) và root chart `argocd/apps` của bản clone theo env × kiến trúc node
    (từ chối `targetRevision` tên ngắn vào `svp-gitops`); chart của working tree đứng thay `revision` của mọi env, nên không kiểm
    revision, giá trị dẫn xuất hay bản phát hành (việc của check `svp-gitops`);
    Secret của đường GitOps ([ADR-0026](docs/adr/0026-secrets-gitops.md)): render gốc của `svp-cluster` (đường dev) không có
    ExternalSecret hay SecretStore, mỗi env đúng 28 ExternalSecret và 4 SecretStore (stg provider `kubernetes`; prd provider `aws`
    và không còn `svp-secrets`), qua kubeconform `-strict` (`KUBECONFORM_IMAGE`, `--network none`) theo schema sinh từ CRD của
    chart External Secrets đúng version `components.json` ghim (provider `crd` bỏ khỏi schema SecretStore vì openapi2jsonschema
    sinh sai; không store nào dùng nó); cuối cùng mọi image bên thứ ba (`helm template --include-crds` mọi component với values
    `base/` và Argo CD theo `bootstrap.json`; ngoài 7 image của project) phải ghim `@sha256:`, image của render có overlay phải bằng
    render gốc (bước 4 của `gitops-check.sh`; `deploy/k8s/check-image-digests.sh` đã gộp vào đây). Cần Docker và mạng tới mọi repo
    chart. `make trivy-config`: trivy quét cấu hình Dockerfile, chart, chỉ báo,
    trừ các mục của `deploy/ci/trivy-config-ignore.yaml` (dưới đây). `make web-lockfile-scan`: trivy `fs` bằng `TRIVY_IMAGE`
    trên `web/pnpm-lock.yaml` (gồm dev dependency, chỉ mount lockfile), `.trivyignore.yaml` như cổng image, rồi
    `scan-gate.sh --fs`: CRITICAL chặn (cả chưa có bản vá), HIGH trở xuống chỉ đếm; báo lỗi khi trivy đọc được 0 gói npm;
    `WEB_LOCKFILE=<đường tuyệt đối>` quét bản sao khác (ca âm), `WEB_LOCKFILE_SARIF=<đường tuyệt đối>` ghi SARIF HIGH/CRITICAL.
    `make renovate-check`: `renovate-config-validator --strict` trong `RENOVATE_IMAGE` ghim, không mạng. trivy, syft,
    grype, cosign, Renovate, k6, Schemathesis, kubeconform chạy trên máy chỉ bằng image ghim digest của `Makefile` (`TRIVY_IMAGE`,
    `SYFT_IMAGE`, `GRYPE_IMAGE`, `COSIGN_IMAGE`, `RENOVATE_IMAGE`, `K6_IMAGE`, `SCHEMATHESIS_IMAGE`, `KUBECONFORM_IMAGE`), không cài;
    govulncheck là công cụ Go ghim `GOVULNCHECK_VERSION`, cài bằng `make tools`. Riêng cosign, script (`cosign_` của `deploy/ci/common.sh`) dùng `cosign`
    trên PATH trước nếu có (CI cài bằng `sigstore/cosign-installer`), không có thì `COSIGN_IMAGE`.
  - `.trivyignore.yaml` ở gốc repo (cổng trivy và cổng grype của image, `make grype`, `make web-lockfile-scan` đọc; hiện có các mục của cây dev `@lhci/cli`,
    [ADR-0016](docs/adr/0016-web-client.md) §10): chỉ phần `vulnerabilities`, mỗi mục có `id`, `statement` (lý do),
    `expired_at` không quá 30 ngày sau ngày chạy và `purls` đúng gói@version (cùng CVE ở gói hay version khác vẫn báo);
    thêm qua PR; bí mật không bỏ qua được. Cổng grype dùng cùng tệp: một mục che một match khi `id` bằng id của match hay một
    id liên quan (grype hay báo GHSA, CVE nằm ở liên quan) và một `purls` bằng purl của match sau khi bỏ qualifier, subpath và
    giải mã `%XX`; mục không có `purls` không che gì; **nghiêm hơn trivy:** một mục hết hạn (từ đúng ngày `expired_at`) làm cổng
    grype đỏ cả khi report sạch. `deploy/ci/trivy-config-ignore.yaml` (chỉ `make trivy-config` đọc,
    [ADR-0021](docs/adr/0021-deferred-verification-stage6b.md) §9): chỉ phần `misconfigurations`, mỗi mục có `id` (`DS-…`,
    `KSV-…`), `paths` bắt buộc (file có thật, không pattern, thư mục hay `..`), `statement` có nội dung và `expired_at` không
    quá 90 ngày; chỉ lựa chọn có chủ đích vào đây, cảnh báo sửa được thì sửa. `scan-gate.sh --check-ignorefile` kiểm cả hai
    file ở job `config`: file sai quy tắc làm job đỏ ở mọi PR.
  - Renovate: GitHub App Mend, repo này và `svp-gitops` (người học cài, **kiểm sau push**); `renovate.json`: sáng thứ Bảy giờ Việt
    Nam, `minimumReleaseAge` 3 ngày (trừ cảnh báo lỗ hổng), không automerge, không đụng `deploy/ci/drill/` và `gen/`; values của
    chart nền tảng, version chart trong `components.json`, bản cài Argo CD và digest phát hành ở `svp-gitops`, do `renovate.json` của
    repo đó quản (bỏ qua `envs/**`). Ghim mới trong `Makefile`, `lib.sh` hay values bên thứ ba theo dạng của
    ADR-0015 §10 (chú thích `# renovate: datasource=… depName=…` ngay trên dòng khi manager có sẵn không đọc được).

Quy ước test:

- Test dùng database riêng tên `svp_<...>_test` (service: `svp_<svc>_<pkg>_test`, ví dụ `svp_engagement_server_test`,
  `svp_feed_projector_test`; gói dùng chung như `internal/dbmigrate` và test lượt xem của engagement-service
  `svp_engagement_views_<x>_test`: mỗi test một database), tạo từ `SVP_TEST_POSTGRES_URL`; helper ở `internal/pgtest` từ
  chối tên không khớp `^svp_[a-z0-9_]+_test$`, nên test không chạm được database thật của service.
- Test gateway gọi service qua `bufconn` (gRPC trong bộ nhớ), không mở cổng.
- Fuzz test (`FuzzXxx` trong `fuzz_test.go` của gói) kiểm tính chất bằng oracle độc lập với hàm (regexp, bảng `unicode`,
  `ed25519.Verify`, `proto.Marshal`), không chỉ "không panic"; tất định, không dựa trạng thái toàn cục. `TestMain` nào dựng
  database (user-service) bỏ bước đó khi cờ `test.fuzz` khác rỗng hay `test.fuzzworker` bật: mỗi worker chạy lại `TestMain`
  và `internal/pgtest` DROP rồi CREATE database theo tên cố định.
- Test thử lại kết nối Postgres (`internal/pgretry`, `internal/pgpool`, `internal/dbmigrate`) dùng helper của
  `internal/pgretry/pgretrytest` (`ClosedPort`, `Blackhole`, `DelayedProxy`: proxy đóng mọi kết nối một lúc rồi mới chuyển tiếp
  tới database test; `LatencyProxy`: proxy trễ mỗi chiều, đổi được trễ, cắt kết nối giữa chừng, cho test Postgres chậm của
  engagement-service), mọi cổng do chính test mở; test đo thời gian với cửa sổ thử lại rút ngắn còn 1,5 s.
- Test Kafka dùng `kfake` (cluster Kafka giả trong bộ nhớ của franz-go), không cần Docker, nên `make check` chạy được khi
  stack đang tắt.
- Test cần object store hay Redpanda thật đọc `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` /
  `SVP_TEST_S3_VIDEO_SECRET_KEY`, `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`,
  `SVP_TEST_S3_PROBE_ACCESS_KEY` / `SVP_TEST_S3_PROBE_SECRET_KEY`,
  `SVP_TEST_KAFKA_BROKERS`; thiếu biến thì test gọi `t.Skip`. `make test-stack` đặt các biến này; hiện chưa có test nào
  dùng `SVP_TEST_KAFKA_BROKERS`.
- Test Redis dùng db 15 qua `SVP_TEST_REDIS_URL`; helper `internal/redistest` từ chối URL nào khác `127.0.0.1:6379` /
  `localhost:6379` db 15, cho mỗi test một tiền tố khoá ngẫu nhiên `svp:test:<hex>:` và khi xong chỉ xoá khoá của tiền tố
  đó. Không `FLUSHDB`/`FLUSHALL`, kể cả ở db 15. Thiếu biến thì test gọi `t.Skip`.
- Test web (Vitest) theo cùng quy tắc: helper `web/server/testing/redis.ts` chỉ nhận db 15 của `127.0.0.1:6379` /
  `localhost:6379` qua `SVP_TEST_REDIS_URL` (`make web-check` đặt), mỗi test một tiền tố ngẫu nhiên `svp:test:<hex>:` và
  chỉ xoá khoá của tiền tố đó; thiếu biến thì nhóm test Redis bị bỏ qua (`describe.skipIf`). Request mạng không có handler
  MSW thì test lỗi. Test e2e (`web/e2e/*.e2e.ts`, Playwright) chỉ chạy trên stack `make up`, mỗi lượt đăng ký user mới với
  handle ngẫu nhiên dạng người chọn (`web/e2e/fixtures.ts`); tác giả do seed tạo có handle sinh `u_…`.
- Test telemetry không cần Collector, LGTM hay GlitchTip: span, metric đọc bằng exporter và reader trong bộ nhớ của OTel
  SDK (`tracetest.NewSpanRecorder`, `tracetest.NewInMemoryExporter`, `sdkmetric.NewManualReader`); lỗi gửi tới tracker
  đọc bằng transport Sentry giả trong bộ nhớ, hoặc một server `httptest` do test tự mở làm GlitchTip giả (DSN trỏ host
  `.invalid` khi chỉ cần reporter bật mà không có mạng). Test không gọi cổng localhost đoán sẵn: endpoint OTLP rỗng thì
  không dựng exporter, Collector "không tới được" là cổng do chính test mở rồi đóng.
- Luồng đầu-cuối (đăng ký, đăng nhập, tạo và đọc video, follow, upload tới `READY` và phát HLS, feed, like/view,
  unfollow) kiểm bằng `make smoke` trên stack đang chạy; độ bền và số đo của luồng upload và luồng feed kiểm bằng các
  target diễn tập ở trên.
