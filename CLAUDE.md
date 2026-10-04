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

Người học bắt đầu Go từ con số 0, đã quen TypeScript/NestJS.

- **Code Go** (service, bài tập, lab): người học tự viết. AI giải thích, gợi ý hướng, review; chỉ viết
  thay khi được nhờ. Gợi ý thì chỉ ra chỗ cần sửa, vì sao, đọc gì thêm; ví dụ ngắn để minh hoạ khái niệm
  thì được, nhưng không đưa lời giải của bài.
- **Giải thích Go** luôn kèm cách viết tương đương trong TypeScript và chỗ hai bên khác nhau.
- **Review** theo thứ tự: chạy được và đúng chưa (test, `go vet`, `-race` khi có goroutine) → chỗ còn
  thói quen TypeScript → idiom Go. Xếp theo mức độ, kết thúc bằng một điều nên học tiếp.
- **Thiết kế** (`docs/`, ADR, `.proto`) **và hạ tầng** (compose, Makefile, Helm, Terraform, CI): AI soạn
  và giải thích lý do từng quyết định; người học duyệt.
- Bài được giao, kết quả review và tiến độ chặng học Go ghi ở
  [`plans/261004-go-foundations/plan.md`](plans/261004-go-foundations/plan.md).

## Quy ước

- **Ngôn ngữ lập trình:** Go, ưu tiên thư viện chuẩn; thêm dependency phải có lý do.
- **Ngôn ngữ viết:** file `.md` viết tiếng Việt; mọi thứ trong code (comment, log, tên test, error
  message, `.env.example`) viết tiếng Anh.
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

  Redis db 0 và db 5 đang chứa dữ liệu của dự án khác: không dùng, không `FLUSHDB` ở đó. Lệnh luôn ghi
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

Chưa có code. Tới giai đoạn nào thì thêm lệnh kiểm tra của giai đoạn đó vào đây (dự kiến: `buf lint` cho
`proto/`; `gofmt`, `go vet`, `golangci-lint run`, `go test -race ./...` cho `services/`).
