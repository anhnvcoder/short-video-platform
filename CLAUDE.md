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

Người học chưa biết Go (đã quen TypeScript/NestJS) và ưu tiên học DevOps + SA. Từ 2026-10-11 chặng học Go
hoãn lại; học lại sau, dùng chính code của project làm tài liệu.

- **Code Go** (service, lab): AI viết, kèm test và chạy đủ lệnh ở mục Kiểm tra. Mỗi lần giao code, tóm tắt
  cấu trúc và các chỗ Go đáng chú ý, kèm cách viết tương đương trong TypeScript và chỗ hai bên khác nhau,
  để người học đọc hiểu được.
- **Thiết kế** (`docs/`, ADR, `.proto`) **và hạ tầng** (compose, Makefile, Helm, Terraform, CI): AI soạn
  và giải thích lý do từng quyết định; người học duyệt.
- Khi học lại Go: bài tập và lab học Go thì người học tự viết, AI gợi ý và review. Bài giao và nhật ký
  review ở [`plans/261004-go-foundations/plan.md`](plans/261004-go-foundations/plan.md).

## Quy ước

- **Ngôn ngữ lập trình:** Go, ưu tiên thư viện chuẩn; thêm dependency phải có lý do.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt; mọi thứ trong code (comment, log, tên test, error
  message, `.env.example`) viết tiếng Anh.
- **Comment trong code** tự đủ nghĩa: nói lý do ngay tại chỗ, người đọc không cần mở ADR mới hiểu. Tham chiếu ADR chỉ là phần
  phụ để đọc sâu hơn (comment vẫn viết tiếng Anh).
- **Monorepo:** `services/<tên>/`, `proto/`, `deploy/`, `docs/`. Thư mục nào tạo khi tới giai đoạn cần nó.
- **ADR** ở `docs/adr/NNNN-<slug>.md`, theo mẫu trong [`docs/adr/README.md`](docs/adr/README.md). Đảo một quyết
  định cũ thì viết ADR mới và đánh dấu ADR cũ là "Bị thay bởi".
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
  | GlitchTip (profile `obs`, tracker lỗi) | `svp_glitchtip` | — |
  | test (`make test`) | `svp_<...>_test` | db 15 |

  Redis db 0, db 5 và db 7 đang chứa dữ liệu của dự án khác: không dùng, không `FLUSHDB` ở đó. Lệnh luôn ghi
  rõ port (`psql -h 127.0.0.1 -p 5432`, `redis-cli -p 6379 -n 14`).
- **Docker, compose, k3d chỉ chạy qua `Makefile`.** Mọi target gọi `env -u DOCKER_DEFAULT_PLATFORM docker ...`:
  shell global đặt `DOCKER_DEFAULT_PLATFORM=linux/amd64` cho dự án khác, nếu không bỏ biến này thì
  container chạy amd64 qua giả lập, chậm và tốn RAM. Chạy tay ngoài Makefile cũng phải thêm tiền tố đó.
  Image cho cloud build đa kiến trúc ở CI.
- **kubectl/helm** chỉ chạy vào cluster k3d, luôn ghi `--context k3d-<tên>` trong lệnh.
- **Git:** conventional commits, mô tả tiếng Việt. Không commit `.env`, secret, token, file state Terraform.

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
  `gitleaks`, `sloth` sinh rule SLO); `buf` cài bằng Homebrew.
- `make generate`: chạy sau khi sửa `proto/` hoặc SQL của `sqlc`; code sinh ra (`gen/go`, code `sqlc`) được commit.
- `make check`: `gofmt`, `go vet`, `golangci-lint run`, `buf lint` + `buf build`, `go test -race ./...` (có integration
  test trên Postgres native `127.0.0.1:5432` qua `SVP_TEST_POSTGRES_URL` và Redis native db 15 qua `SVP_TEST_REDIS_URL`,
  mặc định `redis://127.0.0.1:6379/15` trong `Makefile`). Thu hẹp bằng `make test PKGS=./services/user-service/...`.
- `make cover`: `go test -race` như `make test` nhưng ghi coverage vào `cover.out` (đã gitignore) và in tổng; thu hẹp bằng
  `PKGS=`, xem từng dòng bằng `go tool cover -html=cover.out`.
- `make env`: sinh `.env` local (mode 600, mật khẩu DB, mật khẩu root MinIO và secret key S3 của từng service ngẫu nhiên,
  khoá JWT mới; thêm `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`, mật khẩu hai role `svp_glitchtip_*` và
  `GLITCHTIP_ADMIN_EMAIL=admin@svp.local`). `.env` có sẵn thì chỉ bổ sung biến còn thiếu hoặc đang rỗng, không đổi giá trị
  đã đặt.
- Quy tắc đọc `.env` (`deploy/observability/glitchtip/dotenv.sh`, dùng chung cho `make env`, `make test-stack`,
  `make glitchtip-init`, bootstrap Postgres và script diễn tập): mỗi dòng là dòng trống, comment `#` ở cột 1, hoặc
  `KEY=value` với `KEY` ở cột 1 và `=` ngay sau; giá trị trơn (ASCII in được, không khoảng trắng, nháy, `\`, `$`) hoặc nằm
  trong đúng một cặp nháy `"..."`/`'...'` bao ngoài, bỏ nháy khi đọc (`KEY=""` là rỗng). Dòng có `$`/`${`, khoảng trắng
  đầu dòng hay `export`, khoá lặp, giá trị nhiều dòng, CRLF, byte NUL → dừng, nêu `FILE:dòng:` và tên biến, không in giá
  trị, không ghi gì.
- `make up` / `make smoke` / `make down`: dựng stack compose profile `core` (bootstrap Postgres, Redpanda + tạo topic,
  MinIO + bucket/user/policy, migrate, gateway, user-service, video-service, media-worker, engagement-service,
  feed-service), chạy luồng đầu-cuối qua gateway ở `127.0.0.1:8080` (gồm follow, upload video bằng presigned POST lên
  MinIO, chờ `READY`, tải HLS và thumbnail, video vào feed following và explore, like/unlike, lượt xem, unfollow), rồi
  gỡ stack (giữ volume). Gateway dùng Redis native db 10 (rate limit), feed-service db 14 (cache feed khám phá), qua
  `host.docker.internal:6379`. Cổng publish chỉ trên `127.0.0.1`: 8080 gateway, 9000 MinIO API, 9001 MinIO console,
  19092 Redpanda (Kafka API). `make ps` và `make logs SVC=<tên>` để xem. `make smoke` và mọi script diễn tập cần
  `redis-cli` trên máy và Redis native đang chạy: trước khi chạy, script xoá khoá rate limit đăng ký theo IP
  `svp:gw:rl:register:*` ở db 10 (`SCAN` + `DEL`, không `FLUSHDB`), vì mọi request đi ra từ một IP bridge của Docker và
  vài lần chạy trong một giờ sẽ cạn burst 20. Việc xoá này **chỉ dùng ở lab local**, không trỏ script vào stack dùng
  chung.
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
- `make glitchtip-init`: migrate và khởi tạo GlitchTip (admin, organization và project `svp`, API token chỉ đọc), thêm
  `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`, `SENTRY_API_URL` vào `.env` khi còn thiếu hay rỗng;
  idempotent, không đổi giá trị đã đặt. `make up OBS=lgtm` tự gọi nó. Database `svp_glitchtip` trên Postgres native, hai
  role `svp_glitchtip_migrator`, `svp_glitchtip_app` do bootstrap Postgres của `make up` tạo.
- `make otelcol-validate`: `validate` của Collector ghim (`--network none`) cho cấu hình `obs` và cấu hình `obs-elastic`
  (file `deploy/observability/elastic/otelcol-config.yaml` ghép đè lên file `obs`); chạy lại sau khi sửa một trong hai.
- `make slo`: sinh `deploy/observability/prometheus/rules/slo-generated.yaml` từ `deploy/observability/slo/svp-slos.yaml`
  bằng Sloth; file sinh được commit, chạy lại sau khi sửa spec. `make slo-check`: promtool của image LGTM ghim, không
  mạng: `check config` cho cấu hình Prometheus và hai file rule, rồi `test rules` (`svp-alerts.test.yaml`).
- `make test-stack`: `go test -race` trên stack đang chạy (`make up`), đặt các biến `SVP_TEST_*` cho MinIO và Redpanda,
  nên integration test của `internal/objstore` chạy thật thay vì SKIP. Chỉ hai secret S3 lấy từ `.env`; endpoint,
  access key, broker, `SVP_TEST_POSTGRES_URL` và `SVP_TEST_REDIS_URL` cố định trong `deploy/compose/compose.mk` và
  `Makefile`. Thu hẹp bằng `PKGS=` như `make test`.
- `make clean-data`: gỡ stack (mọi profile) và xoá volume của nó (topic Redpanda, bucket MinIO, thư mục tạm của
  media-worker, dữ liệu LGTM, silence của Alertmanager, chỉ mục Elasticsearch); Postgres native (cả `svp_glitchtip`) không
  bị đụng. Chỉ chạy khi cần làm lại dữ liệu từ đầu.
- `make drill-kill-worker`, `make drill-duplicates`, `make measure-ready N=5`: diễn tập trên stack đang chạy, script ở
  `deploy/compose/drills/`. Lần lượt: kill media-worker giữa lúc transcode rồi kiểm video vẫn `READY` đúng một lần; phát
  lại event bằng `rpk group seek` rồi kiểm không gì đổi; đo `CompleteUpload` → `READY` cho N video 60 s 1080p (p50, p95,
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
  bị tắt) thì login vẫn bị giới hạn bằng bộ đếm dự phòng còn feed, like, lượt xem vẫn chạy; N request đồng thời (mặc định
  100, tối đa 150) lúc cache trống chỉ đọc Postgres một lần, script xoá khoá `svp:feed:explore:*` ở db 14 trước khi đo;
  video bỏ dở quá hạn chuyển `FAILED` và object `uploads/<id>` bị xoá (mọi video khác nằm `UPLOADING` quá 20 s cũng bị
  dọn).
- `make drill-alert-to-sentry`, `make drill-obs-threats`: diễn tập giai đoạn 3, chỉ trên stack `make up OBS=lgtm`, cần
  GlitchTip đã khởi tạo (`SENTRY_DSN`, `SENTRY_AUTH_TOKEN` trong `.env`, do `make up OBS=lgtm` hay `make glitchtip-init`
  ghi; script chỉ nhận `SENTRY_API_URL=http://127.0.0.1:8000`, không cổng loopback nào khác). Lần lượt: tắt feed-service,
  đo từ lúc cảnh báo page `FeedAvailabilityBudgetBurn` có trong Alertmanager (T1) tới khi trace (Tempo), dòng log (Loki)
  và event GlitchTip cùng một `trace_id` đều tìm thấy (T4), đạt khi T4 − T1 < 5 phút; trước khi tắt, script chờ cảnh báo
  của lần chạy trước resolve (tới khoảng 30 phút) và 31 s không có 5xx ở feed. Kiểm các dòng giai đoạn 3 của threat
  model: JWT-8 (trace, log, event GlitchTip của request login/feed/follow, cả lúc user-service tắt, không có email, mật
  khẩu, token), UP-8 (`video created`, `upload completed` có `user_id`, `video_id`, `trace_id`), OPS-1 (`/debug/pprof/`,
  `/metrics` trả 404; project publish đúng 7 cổng loopback), RL-2 (gateway dựng lại với Redis `.invalid` thì metric
  `store="fallback"` > 0 và cảnh báo `RateLimitFallbackActive` trong 4 phút). **Telegram tuỳ chọn:** người học tự tạo bot
  và điền `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` vào `.env`; có đủ cả hai thì Alertmanager gửi cảnh
  báo `severity=page` tới `api.telegram.org` (ngoại lệ hẹp về mạng ngoài của lab) và `drill-alert-to-sentry` kiểm số
  thông báo đã gửi; thiếu thì không gửi gì, bước đó SKIP. Có cả hai biến mà Alertmanager đang chạy chưa nạp receiver thì
  FAIL trước khi tắt service.
- Script diễn tập dừng/khởi động container, chỉ `SELECT` trên `svp_video`, `svp_engagement`, `svp_feed`, và luôn bật lại
  mọi service khi kết thúc. Trên Redis, ngoài hai thao tác xoá ở trên (`svp:gw:rl:register:*` ở db 10,
  `svp:feed:explore:*` ở db 14) script chỉ đọc. `drill-rate-limit`, `drill-obs-threats` và `drill-upload-cleanup` dựng lại
  gateway hay video-service với cấu hình diễn tập qua `SVP_GATEWAY_REDIS_URL`, `SVP_UPLOAD_ABANDON_AFTER`,
  `SVP_UPLOAD_SWEEP_INTERVAL` rồi trả về mặc định; ba biến này **chỉ dùng cho diễn tập**, không đặt trong `.env` (hạn dọn
  upload dưới 15 phút ngắn hơn hạn form upload). Hai diễn tập giai đoạn 3 đọc Prometheus, Tempo, Loki qua datasource proxy
  của Grafana, API Alertmanager và API GlitchTip bằng token chỉ đọc, không in giá trị nào của `.env`.
- `make hooks`: bật git hook ở `.githooks/` một lần cho mỗi clone. `pre-commit` chạy `gofmt` trên file Go đã stage,
  `golangci-lint run`, `buf lint` và `gitleaks` trên thay đổi đã stage.

Quy ước test:

- Test dùng database riêng tên `svp_<...>_test` (service: `svp_<svc>_<pkg>_test`, ví dụ `svp_engagement_server_test`,
  `svp_feed_projector_test`; gói dùng chung như `internal/dbmigrate` và test lượt xem của engagement-service
  `svp_engagement_views_<x>_test`: mỗi test một database), tạo từ `SVP_TEST_POSTGRES_URL`; helper ở `internal/pgtest` từ
  chối tên không khớp `^svp_[a-z0-9_]+_test$`, nên test không chạm được database thật của service.
- Test gateway gọi service qua `bufconn` (gRPC trong bộ nhớ), không mở cổng.
- Test Kafka dùng `kfake` (cluster Kafka giả trong bộ nhớ của franz-go), không cần Docker, nên `make check` chạy được khi
  stack đang tắt.
- Test cần MinIO hay Redpanda thật đọc `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` /
  `SVP_TEST_S3_VIDEO_SECRET_KEY`, `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`,
  `SVP_TEST_KAFKA_BROKERS`; thiếu biến thì test gọi `t.Skip`. `make test-stack` đặt các biến này; hiện chưa có test nào
  dùng `SVP_TEST_KAFKA_BROKERS`.
- Test Redis dùng db 15 qua `SVP_TEST_REDIS_URL`; helper `internal/redistest` từ chối URL nào khác `127.0.0.1:6379` /
  `localhost:6379` db 15, cho mỗi test một tiền tố khoá ngẫu nhiên `svp:test:<hex>:` và khi xong chỉ xoá khoá của tiền tố
  đó. Không `FLUSHDB`/`FLUSHALL`, kể cả ở db 15. Thiếu biến thì test gọi `t.Skip`.
- Test telemetry không cần Collector, LGTM hay GlitchTip: span, metric đọc bằng exporter và reader trong bộ nhớ của OTel
  SDK (`tracetest.NewSpanRecorder`, `tracetest.NewInMemoryExporter`, `sdkmetric.NewManualReader`); lỗi gửi tới tracker
  đọc bằng transport Sentry giả trong bộ nhớ, hoặc một server `httptest` do test tự mở làm GlitchTip giả (DSN trỏ host
  `.invalid` khi chỉ cần reporter bật mà không có mạng). Test không gọi cổng localhost đoán sẵn: endpoint OTLP rỗng thì
  không dựng exporter, Collector "không tới được" là cổng do chính test mở rồi đóng.
- Luồng đầu-cuối (đăng ký, đăng nhập, tạo và đọc video, follow, upload tới `READY` và phát HLS, feed, like/view,
  unfollow) kiểm bằng `make smoke` trên stack đang chạy; độ bền và số đo của luồng upload và luồng feed kiểm bằng các
  target diễn tập ở trên.
