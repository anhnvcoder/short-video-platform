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

  Trong cluster k3d (giai đoạn 4) cùng tên database (cả `svp_glitchtip`) nằm trên Postgres `svp-pg` của CloudNativePG
  (`svp-pg-rw.svp-data:5432`), gateway và feed-service dùng db 10 và db 14 của Valkey `valkey.svp-data:6379`; Postgres và
  Redis native không bị đụng.
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
  `actionlint`, `gitleaks`, `sloth` sinh rule SLO, `k3d`); `buf`, Helm cài bằng Homebrew (CI cài hai thứ đó bằng
  `make ci-tools`, chỉ chạy trên Linux amd64).
- `make generate`: chạy sau khi sửa `proto/` hoặc SQL của `sqlc`; code sinh ra (`gen/go`, code `sqlc`) được commit.
- `make generate-check`: chạy `make generate` trong bản sao tạm của working tree (file đã track và file chưa track không bị
  ignore, không `.env`), in file lệch và diff, exit ≠ 0 khi lệch; không bao giờ ghi vào working tree.
- `make check`: `gofmt`, `go vet`, `golangci-lint run` (gồm gosec), `actionlint` (mọi file của `.github/workflows/`),
  `buf lint` + `buf build`, `go test -race ./...` (có integration test trên Postgres native `127.0.0.1:5432` qua
  `SVP_TEST_POSTGRES_URL` và Redis native db 15 qua `SVP_TEST_REDIS_URL`, mặc định `redis://127.0.0.1:6379/15` trong
  `Makefile`). Thu hẹp bằng `make test PKGS=./services/user-service/...`; `TESTFLAGS` thêm cờ cho `go test` của
  `make test`, `make cover`, `make check` (`make test TESTFLAGS=-count=1` chạy lại không dùng cache, như CI), `LINTFLAGS`
  thêm cờ cho golangci-lint của `make lint`.
- `make cover`: `go test -race` như `make test` nhưng ghi coverage vào `cover.out` (đã gitignore) và in tổng; thu hẹp bằng
  `PKGS=`, xem từng dòng bằng `go tool cover -html=cover.out`.
- `make env`: sinh `.env` local (mode 600, mật khẩu DB, mật khẩu root MinIO và secret key S3 của từng service ngẫu nhiên,
  khoá JWT mới; thêm `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`, mật khẩu hai role `svp_glitchtip_*` và
  `GLITCHTIP_ADMIN_EMAIL=admin@svp.local`; cho cluster k3d, compose bỏ qua: `SVP_PG_SUPERUSER_PASSWORD`,
  `SVP_KAFKA_ADMIN_PASSWORD`, `SVP_KAFKA_KEDA_PASSWORD`, `SVP_KAFKA_<SERVICE>_PASSWORD` cho 5 service có Kafka,
  `SVP_GRAFANA_ADMIN_PASSWORD`). `.env` có sẵn thì chỉ bổ sung biến còn thiếu hoặc đang rỗng, không đổi giá trị đã đặt.
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
- `make otelcol-validate`: `validate` của Collector ghim (`--network none`) cho cấu hình `obs`, cấu hình `obs-elastic`
  (file `deploy/observability/elastic/otelcol-config.yaml` ghép đè lên file `obs`) và cấu hình của cluster k3d
  (`deploy/observability/otelcol/k8s-config.yaml`); chạy lại sau khi sửa một trong ba.
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
- Giai đoạn 4, cluster k3d `svp` ([ADR-0014](docs/adr/0014-kubernetes-local-stage4.md)), target ở `deploy/k8s/k8s.mk`.
  Ràng buộc chung: chỉ chạy qua Makefile (`docker`/`k3d` với `env -u DOCKER_DEFAULT_PLATFORM`, `kubectl`/`helm` luôn
  `--context k3d-svp`, cache Helm ở `.k8s/helm`); `k3d` ghim cài bằng `make tools`. **Không chạy cùng compose:**
  `make k8s-up`, `k8s-gitops-up` từ chối khi stack compose `svp` đang chạy; `make up` từ chối khi node của
  cluster hay registry `k3d-svp-registry` đang chạy. Cổng chỉ trên `127.0.0.1`: API 6550, HTTPS của Envoy 8443
  (`api.svp.localhost`, `s3.svp.localhost`, đều phân giải về loopback), registry 5111. Postgres (CloudNativePG), Valkey,
  Redpanda (SASL + ACL), MinIO nằm trong cluster: target giai đoạn 4 không đụng Postgres/Redis native. File sinh ra nằm ở
  `.k8s/` (gitignore). Biến chỉ đặt ở cluster: service có Kafka đăng nhập SASL SCRAM bằng `KAFKA_SASL_USERNAME`,
  `KAFKA_SASL_PASSWORD` (đặt cả hai hay không biến nào; compose không đặt, broker không xác thực); gateway tin một hop
  `X-Forwarded-For` từ dải pod của Envoy qua `TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16` (compose: không
  đặt, 0 hop; giá trị không hợp lệ thì gateway không khởi động). API server có PSA `restricted` mặc định cho mọi namespace
  trừ `kube-system` (`deploy/k8s/pod-security-admission.yaml`, mount từ đường của repo lúc tạo cluster, đọc lại mỗi lần
  node server khởi động): sửa `k3d.yaml` hay dời repo phải `make k8s-down && make k8s-up`, sửa file đó có hiệu lực ở lần
  khởi động sau; `make k8s-up` từ chối cluster tạo khi chưa có cấu hình này, hay khi nguồn mount không còn là file, khác
  file của repo hiện tại, hay version lệch `podSecurityVersion`.
- Kyverno ([ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md) §8), cùng `ImageValidatingPolicy` `svp-images` (chart
  `deploy/helm/svp-policy`) trên hai đường, chỉ namespace `svp`: `make k8s-up` cài **Audit** (`failurePolicy: Ignore`,
  image `dev-*` chưa ký của registry k3d vẫn chạy, vi phạm ghi vào PolicyReport), `make k8s-gitops-up` **Enforce**
  (`Deny` + `Fail`: chỉ nhận image `ghcr.io/anhnvcoder/short-video-platform/*` theo digest, ký keyless bởi
  `images.yml@refs/heads/main`, có attestation `vuln` đủ hai nền tảng, không CRITICAL, không quá 72 giờ; Kyverno chết thì
  pod `svp` mới bị từ chối, namespace khác không qua webhook).
- `make k8s-up` / `make k8s-down` / `make k8s-status`: `k8s-up` tạo (hay khởi động) registry và cluster, build và push sáu
  image tag `dev-<image ID>` (chỉ `--set`, không ghi file), cài `deploy/argocd/apps/components.json` theo wave bằng
  `deploy/k8s/install.sh` (trong đó chạy `secrets.sh` sau `svp-cluster`, `glitchtip-init.sh` sau `svp-observability`),
  xuất CA ra `.k8s/ca.crt`; idempotent, cần `.env` (`make env`), từ chối cluster do Argo CD quản (có Application
  `svp-root`). Khi pod template của gateway (Argo Rollout) đổi, tức có canary, `k8s-up` tự chạy traffic diễn tập trong lúc
  canary rồi dừng, chờ Rollout `Healthy` có hạn; abort hay inconclusive thì FAIL kèm lệnh gỡ (**LOCAL LAB ONLY**: traffic
  xoá khoá rate limit đăng ký ở Valkey db 10 của cluster). `k8s-down` xoá cluster và registry (volume compose và Postgres
  native không bị đụng). `k8s-status` in container, node và pod mọi namespace trừ `kube-system`.
- `make k8s-secrets`, `make k8s-glitchtip-init`, `make k8s-ca`: `k8s-secrets` tạo/cập nhật Secret từ `.env` bằng
  `kubectl apply` qua stdin, không in giá trị; mật khẩu superuser Redpanda đổi thì đặt vào broker đang chạy trước khi apply
  (cần `redpanda-0` chạy; Admin API không trả lời hay không nhận mật khẩu nào thì dừng, không đổi Secret nào), MinIO hay
  Redpanda chạy với mật khẩu khác `.env` thì restart; sau đó `make k8s-up` để Job init đặt mật khẩu mới và restart service
  có Secret đổi (cluster GitOps: các bước tay ở đầu `deploy/k8s/gitops.sh`). `k8s-glitchtip-init` ghi DSN vào Secret
  `svp/sentry` và token API chỉ đọc vào `svp-obs/glitchtip-api` (không vào `.env`, không in), restart service khởi động
  khi chưa có DSN hiện tại; idempotent, `k8s-up` tự gọi, không cần `.env`. `k8s-ca` ghi CA của chứng chỉ TLS ra
  `.k8s/ca.crt`.
- `make k8s-images`: build sáu image từ working tree và push lên `127.0.0.1:5111` tag `dev-<image ID>` (đường dev).
  `make k8s-release` **đã bỏ** (giai đoạn 5): image phát hành build, quét, ký trong CI (`images.yml`, bên dưới), job
  `promote` ghi `image.repository`, `image.tag`, `image.digest` vào `deploy/k8s/values/services/<svc>.yaml` trên nhánh
  `bot/promote` và mở hay cập nhật một PR cuộn; người học duyệt lượt chạy của PR ("Approve workflows to run") rồi merge.
  Đường dev `make k8s-up` giữ registry k3d và tag dev (chỉ `--set`).
- `make k8s-gitops-up ARGOCD_DEPLOY_KEY=<file> [GITOPS_REV=main]`, `make measure-gitops REV=<commit>`: đường GitOps
  (ADR-0014 §12, ADR-0015 §9), tạo cluster `svp` **mới** mà Argo CD dựng từ GitHub, kéo image từ GHCR theo digest, ẩn
  danh. Trước khi tạo gì, kiểm ở đúng revision (`origin/<nhánh>` như lần fetch cuối, không `git fetch`) cả 6 file values:
  có digest (PR promote đã merge), repository `ghcr.io/anhnvcoder/short-video-platform/<svc>`, manifest kéo ẩn danh được
  (package GHCR đã public), chữ ký và attestation `vuln` đúng identity, không CRITICAL, không quá 48 giờ
  (`deploy/ci/verify-release.sh` bằng `COSIGN_IMAGE`; quá hạn thì in lệnh dispatch rescan với `values_ref=<revision>`);
  thiếu một điều là dừng, không tạo gì. Rồi tạo namespace và Secret từ `.env`, cài Argo CD (namespace `argocd`, PSA
  `restricted`), Secret repo bằng deploy key **chỉ đọc** do người học tạo trên GitHub (file mode 600, không passphrase;
  không in, không chép), AppProject `svp` và `default` đã khoá, root `svp-root`; chờ mọi Application `Synced`, Healthy,
  sync cuối `Succeeded` (lỗi còn sau 180 s thì dừng). `measure-gitops` đo commit phát hành (merge của PR promote) từ lúc
  push (reflog `origin/main`, không có thì PushEvent qua `gh api`, chỉ đọc) qua sync của Argo CD tới pod đầu và cuối Ready
  với digest mới; chỉ đọc, JSON ở `.k8s/drills/`. Với image GHCR cả hai target **kiểm sau push**.
- `make k8s-traffic-start` / `make k8s-traffic-stop`: traffic diễn tập chạy nền, 4 user, ~10 request/s vào
  `GET /feed/explore`, `/feed/following` qua `https://api.svp.localhost:8443`, mỗi request một dòng ở
  `.k8s/drills/traffic-<time>.log`, chạy tới khi dừng (qua cả lúc push phát hành trên cluster GitOps); `stop` chỉ dừng
  đúng pid đã ghi và in số request theo status. **LOCAL LAB ONLY:** đăng ký user mới và xoá khoá rate limit đăng ký ở
  Valkey db 10 của cluster.
- `make k8s-smoke`, `make drill-k8s-keda N=9`, `make drill-k8s-pdb`, `make drill-k8s-canary`, `make measure-canary`,
  `make drill-k8s-threats`: trên cluster đang chạy, qua Envoy với `.k8s/ca.crt` (thiếu thì chạy `make k8s-ca`), script ở
  `deploy/k8s/drills/` (`k8s-smoke` dùng `deploy/compose/smoke.sh`). Lần lượt: luồng đầu-cuối như `make smoke`; N (mặc
  định 9, 6–12) video 60 s 1080p cùng lúc, đo KEDA scale media-worker lên tối đa 2 replica và về 1, lag đỉnh, mỗi
  `READY`, CPU/RAM, scale down một pod đang transcode (ghim `paused-replicas` của KEDA thấp hơn một, pod tắt êm) rồi kiểm
  mọi video transcode đúng một lần, và k3s server không restart suốt diễn tập (`RestartCount`, `StartedAt` của container
  `k3d-svp-server-0`, [ADR-0017](docs/adr/0017-gitops-capacity-media-worker-max2.md)); cordon node và evict lần lượt hai pod gateway như drain: PDB cho pod đầu (201), từ chối
  pod thứ hai (429) khi pod thay còn Pending, rồi uncordon; canary của gateway trên cluster dev dưới traffic diễn tập:
  bản tốt qua 25%, 50%, 100% và được promote, bản lỗi (`FEED_SERVICE_ADDR` trỏ Service không có) bị phân tích abort,
  trọng số về 0, pod stable không đổi, rồi trả bản tốt; `measure-canary` đọc lại lần abort canary gần nhất (chỉ đọc);
  các dòng giai đoạn 4 của threat model, mỗi dòng có ca đối chứng (pod thử ở namespace `svp-probe` tạo rồi xoá,
  NetworkPolicy, ACL Kafka, PSA, `pg_hba`, RL-1 với `X-Forwarded-For` giả, pprof/metrics, UI không lộ, Grafana 401,
  RBAC: không ServiceAccount nào của `svp` đọc Secret hay pod, CloudNativePG và Envoy Gateway chỉ có quyền ở các
  namespace đã thu hẹp, ngoại lệ còn lại in kèm lý do), log ở `.k8s/drills/threats-<time>.log` được dò các giá trị
  Secret đã đọc. Kết quả và JSON ở `.k8s/drills/`; script trả cluster về như cũ khi kết thúc (uncordon, bỏ ghim KEDA,
  trả bản gateway tốt). **LOCAL LAB ONLY:** trừ `measure-canary`, mọi target này xoá khoá `svp:gw:rl:register:*` ở
  Valkey db 10 của cluster (qua `kubectl exec`).
- `make drill-k8s-supplychain [SUPPLYCHAIN_UNSIGNED=<digest GHCR>] [SUPPLYCHAIN_VULNERABLE=<digest GHCR>]
  [SUPPLYCHAIN_ENFORCE_TMP=1]` (giai đoạn 5, script `deploy/k8s/drills/supplychain.sh`): policy Kyverno của `svp`, mỗi ca
  một dòng PASS/FAIL/SKIP và chỉ PASS khi đúng message của rule cần từ chối; pod gửi bằng `--dry-run=server` (trừ ca b là
  Deployment thật, xoá sau). Ca: (a) bản phát hành đã ký, sạch được nhận, hai lần liền (lần hai từ cache); (b)
  `drill-unsigned` bị từ chối vì thiếu chữ ký; (c) `drill-vulnerable` bị từ chối vì CRITICAL, ca này tự đọc
  `scanFinishedOn` bằng cosign và FAIL khi quá 72 giờ, nên chạy trong 72 giờ sau khi dispatch image diễn tập (`gh workflow
  run images.yml --ref main -f drill=true`, người học chạy); (d) image registry k3d và Docker Hub bị từ chối vì prefix,
  mỗi lần dưới 1 s; (e) image không digest; (f) attestation quá hạn (policy tạm tuổi tối đa 5 s); (g) admission
  controller không lịch được: pod `svp` bị từ chối, pod ở namespace thử `svp-probe` được nhận; (h) ephemeral container
  chưa ký bị từ chối, đã ký được nhận; (i) UPDATE image chưa ký bị từ chối; (k) đường keyless với image công khai của nhà
  cung cấp khác (đúng identity nhận, sai identity từ chối; chỉ trên dev). Đường dev là Audit nên script từ chối chạy trừ
  khi `SUPPLYCHAIN_ENFORCE_TMP=1`: chạy (k), nâng tạm `svp-policy` lên Enforce cho các ca còn lại rồi trả Audit; trên
  đường dev chưa có image ký nên (a), (b), (c), (f) và nửa nhận của (h) SKIP. Mọi ca đủ trên cluster GitOps sau push
  (**kiểm sau push**). Khi kết thúc script trả Kyverno, Argo CD sync, Audit về như cũ, xoá policy tạm, `svp-probe`, và so
  webhook với ảnh chụp đầu; JSON ở `.k8s/drills/`. Không gọi API của gateway, không xoá khoá rate limit nào.
- `make k8s-ui-grafana`, `k8s-ui-prometheus`, `k8s-ui-alertmanager`, `k8s-ui-glitchtip`, `k8s-ui-argocd`: port-forward chỉ
  trên `127.0.0.1` (lần lượt 3000, 9090, 9093, 8000, 8081) trong lúc target chạy (Ctrl-C để đóng); không HTTPRoute,
  LoadBalancer hay NodePort nào cho UI (OPS-2). Grafana đăng nhập `admin` + `SVP_GRAFANA_ADMIN_PASSWORD`, GlitchTip bằng
  `GLITCHTIP_ADMIN_EMAIL`/`GLITCHTIP_ADMIN_PASSWORD`, Argo CD (cluster GitOps, chứng chỉ tự ký) `admin` với mật khẩu đọc
  bằng lệnh target in ra; Prometheus và Alertmanager không có đăng nhập nên chỉ mở khi forward đang chạy.
- `make hooks`: bật git hook ở `.githooks/` một lần cho mỗi clone. `pre-commit` chạy `gofmt` trên file Go đã stage,
  `golangci-lint run`, `buf lint` và `gitleaks` trên thay đổi đã stage.
- Giai đoạn 5, CI trên GitHub Actions ([ADR-0015](docs/adr/0015-cicd-devsecops-stage5.md)). Hai workflow, mọi action
  ghim SHA commit, `permissions: {}` ở đầu file và quyền khai theo job; mọi job của lượt `pull_request` (cả PR từ fork)
  chỉ có `contents: read` và không secret; không `pull_request_target`, `workflow_run`:
  - `.github/workflows/ci.yml` (PR, push `main`, dispatch): `check` (`make check TESTFLAGS=-count=1`, Postgres và Redis
    là service container trên `127.0.0.1`, ffmpeg), `generate` (`make generate-check`), `buf` (`buf breaking` so với
    merge-base của PR, `main` trước push, hay merge-base với `origin/main` khi dispatch), `config`
    (`deploy/ci/scan-gate.sh --check-ignorefile`, `make slo-check`, `make otelcol-validate`, `make env` rồi
    `make compose-config`, `make helm-check`, `deploy/k8s/check-image-digests.sh`), `gitleaks` (toàn lịch sử,
    `--redact`), `trivy-config` (chỉ báo), `sarif` (chỉ `main`), check tổng `ci-ok`.
  - `.github/workflows/images.yml` (PR, push `main`, dispatch, lịch hằng ngày): chỉ build service đổi so với lần push
    `main` thành công cuối (`deploy/ci/changed-services.sh`; đổi `images.yml`, `deploy/ci/`, `deploy/k8s/lib.sh` hay dòng
    `TRIVY_IMAGE`/`SYFT_IMAGE`/`COSIGN_IMAGE` của `Makefile` thì cả sáu); mỗi service hai chân amd64, arm64 build native,
    trivy chặn bí mật (mọi severity) và CRITICAL **trước** push, push lên `ghcr.io/anhnvcoder/short-video-platform/<svc>`
    đúng bản đã quét, ghép index, ký keyless bằng cosign kèm attestation `vuln` (kết quả quét hai nền tảng) và SBOM syft
    mỗi nền tảng, rồi job `promote` mở PR cuộn. Lượt PR chỉ build và quét (`build-nopush`), `values-check` kiểm digest mà
    PR đổi (đã ký, attestation không quá 48 giờ). Dispatch `-f rescan=true [-f values_ref=<ref>]` quét lại mọi digest
    phát hành (lịch hằng ngày làm việc này), `-f drill=true` đẩy hai image diễn tập; check tổng `images-ok`.
  - Check bắt buộc của ruleset `main`: `ci-ok`, `images-ok`, chỉ nhận từ app GitHub Actions. Ruleset, cài đặt repo
    (Actions chỉ cho action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc; secret scanning + push
    protection; Dependabot alerts) và package GHCR public do người học bật (ADR-0015 §5, §11): **kiểm sau push**.
  - Chạy lại một job trên máy, từ gốc repo: `make check TESTFLAGS=-count=1`; `make generate-check`;
    `buf breaking --against '.git#ref=<base>'`; `deploy/ci/scan-gate.sh --check-ignorefile`, `make slo-check`,
    `make otelcol-validate`, `make compose-config`, `make helm-check`, `deploy/k8s/check-image-digests.sh`;
    `gitleaks git --redact --no-banner`; `make trivy-config`; một chân image (build, quét, cổng, không push):
    `deploy/ci/build-image.sh <svc> arm64 "$(mktemp -d)"`; service nào sẽ build: `deploy/ci/changed-services.sh <base>
    HEAD`. Push GHCR, ký, attest, promote chỉ chạy trong CI: không đăng nhập GHCR hay Sigstore từ máy.
  - `make helm-check`: `helm lint` và `helm template` mọi chart của repo với values đường GitOps (`HELM_*_HOME` trong
    thư mục tạm). `deploy/k8s/check-image-digests.sh`: `helm template` mọi chart bên thứ ba với đúng values, mọi image
    (ngoài 6 service) phải ghim `@sha256:`. `make trivy-config`: trivy quét cấu hình Dockerfile, chart, chỉ báo.
    `make renovate-check`: `renovate-config-validator --strict` trong `RENOVATE_IMAGE` ghim, không mạng. trivy, syft,
    cosign, Renovate chạy trên máy chỉ bằng image ghim digest của `Makefile` (`TRIVY_IMAGE`, `SYFT_IMAGE`,
    `COSIGN_IMAGE`, `RENOVATE_IMAGE`), không cài.
  - `.trivyignore.yaml` ở gốc repo (hiện chưa có): chỉ phần `vulnerabilities`, mỗi mục có `id`, `statement` (lý do) và
    `expired_at` không quá 30 ngày sau ngày chạy; thêm qua PR; bí mật không bỏ qua được. File sai quy tắc làm job `config`
    đỏ ở mọi PR.
  - Renovate: GitHub App Mend, chỉ repo này (người học cài, **kiểm sau push**); `renovate.json`: sáng thứ Bảy giờ Việt
    Nam, `minimumReleaseAge` 3 ngày (trừ cảnh báo lỗ hổng), không automerge, không đụng `deploy/k8s/values/services/`
    (của PR promote) và `gen/`. Ghim mới trong `Makefile`, `lib.sh` hay values bên thứ ba theo dạng của
    ADR-0015 §10 (chú thích `# renovate: datasource=… depName=…` ngay trên dòng khi manager có sẵn không đọc được).

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
