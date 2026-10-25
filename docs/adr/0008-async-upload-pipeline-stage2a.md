# 0008. Luồng upload bất đồng bộ của giai đoạn 2 phần A: franz-go, aws-sdk-go-v2, outbox có khoá relay, media-worker trên alpine + ffmpeg

- Trạng thái: Chấp nhận; §9 (đúng một replica media-worker) chỉnh bởi [0014](0014-kubernetes-local-stage4.md) cho k8s
- Ngày: 2026-10-11

## Bối cảnh

- Giai đoạn 2 phần A làm thật luồng upload của [architecture §7.1](../architecture.md#71-upload-tới-khi-vào-feed-saga-dạng-choreography):
  `InitUpload` trả presigned POST, client đẩy file lên MinIO, `CompleteUpload` `HEAD` rồi ghi outbox, relay phát
  `video.uploaded`, media-worker transcode ra HLS, phát `transcode.completed` / `transcode.failed`, video-service chuyển
  `READY` hoặc `FAILED` (bước bù). Redis, rate limit, engagement-service và feed-service thuộc các phần sau của giai đoạn 2.
- Các ADR trước đã chốt hướng: Redpanda, outbox, at-least-once, DLQ ([ADR-0003](0003-async-events-outbox.md)); presigned
  POST, HLS, hai bucket ([ADR-0004](0004-direct-upload-and-hls.md)); topic theo luồng thực thể, envelope, bỏ qua nhánh
  `oneof` chưa biết ([ADR-0006](0006-contract-ids-and-event-envelope.md)); cấu hình bằng biến môi trường, image distroless
  ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md)). ADR này chọn thư viện, image, cấu hình hạ tầng và chi tiết
  hiện thực mà code phần A dùng; tên biến, version, cổng, đường dẫn lấy từ đây.
- Biện pháp bắt buộc ở giai đoạn 2 của [threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn) cho phần này: UP-1
  tới UP-6, FF-1 tới FF-4, FF-6, FF-7, IN-5.
- Ràng buộc máy: Apple M2, 16 GB; Docker VM có 7,65 GiB và 8 CPU (`docker info`, 2026-10-11); compose profile `core` gồm
  service + Redpanda + MinIO (plan, mục Ràng buộc máy); chạy native arm64.

## Kiểm chứng (đã kiểm ngày 2026-10-11)

| Kiểm gì | Lệnh | Kết quả |
| --- | --- | --- |
| Version module | `go list -m -json <module>@latest` trong thư mục tạm ngoài repo (đã xoá) | Bảng ở mục 1 và 2; mọi module khai báo `go` ≤ 1.26.0, build được bằng Go 1.27.2 |
| `PresignPostObject` | Đọc `presign_post.go` của `service/s3` v1.114.3 trong module cache; chạy thử một chương trình ký | Mục 2 |
| Redpanda | `env -u DOCKER_DEFAULT_PLATFORM docker pull redpandadata/redpanda:v26.2.4`, `docker run --rm --entrypoint rpk ... version` | arm64, `rpk` v26.2.4, build 2026-10-06 |
| alpine + ffmpeg | `docker run --rm alpine:3.24.2 sh -c 'apk add ffmpeg; ffmpeg -h full; ffmpeg -encoders'` | arm64; ffmpeg 8.1.2 (gói `ffmpeg` 8.1.2-r0); có `-format_whitelist`, `-codec_whitelist`, `-protocol_whitelist`; có encoder `libx264`, `aac` |
| MinIO chính thức | `docker manifest inspect minio/minio:latest`, `minio/mc:latest`, `quay.io/minio/minio:<tag>` | Docker Hub: `denied`; Quay: không có manifest hoặc đòi đăng nhập với mọi tag đã thử (mục 6) |
| MinIO thay thế | `docker pull cgr.dev/chainguard/minio@sha256:7df55d...`, `docker run --rm --network none ... --version` | arm64, MinIO `RELEASE.2026-09-22T19-25-18Z`, go1.27.2, image tạo 2026-10-10; có `/usr/bin/mc` và `/bin/sh`; chạy uid 65532 |
| Cổng | `lsof -nP -iTCP -sTCP:LISTEN` | Không tiến trình nào nghe ở 9000, 9001, 19092 |

## 1. Thư viện Kafka

### Các lựa chọn về thư viện Kafka

#### A. `github.com/twmb/franz-go`

- Được: thuần Go, build `CGO_ENABLED=0` và chạy trên distroless như service hiện có; producer idempotent và `acks=all` là
  mặc định; consumer group với commit tay (`kgo.DisableAutoCommit`, `CommitRecords`); heartbeat chạy nền nên handler chạy lâu
  không làm consumer bị loại khỏi group; phát triển đều, tài liệu Redpanda dùng nó cho Go. Có `kfake`, Kafka giả trong bộ nhớ
  (module riêng), để test consumer, producer và relay chạy trong `make check` mà không cần Docker.
- Mất: API cấp thấp hơn các thư viện "một hàm `ReadMessage`": vòng poll, commit, xử lý rebalance phải tự viết (gói
  `internal/kafkax`, mục 8). `kfake` không gắn tag, phải ghim pseudo-version.

#### B. `github.com/confluentinc/confluent-kafka-go`

- Được: bọc librdkafka, thư viện client Kafka trưởng thành nhất.
- Mất: cần cgo và librdkafka; phá image static distroless, build chéo kiến trúc ở CI phức tạp hơn.

#### C. `github.com/segmentio/kafka-go`

- Được: API đơn giản, thuần Go.
- Mất: consumer group hạn chế (khó kiểm soát commit và rebalance theo partition), phát triển chậm trong vài năm gần đây.

`IBM/sarama` cũng thuần Go nhưng API nặng và cấu hình mặc định dễ sai (producer không idempotent mặc định); không xét thêm.

### Quyết định về thư viện Kafka

Chọn **A**.

| Module | Version | `go` trong `go.mod` | Dùng ở |
| --- | --- | --- | --- |
| `github.com/twmb/franz-go` | `v1.22.1` | 1.26.0 | Producer (relay outbox, media-worker, DLQ), consumer group |
| `github.com/twmb/franz-go/pkg/kfake` | `v0.0.0-20261007040850-d3792b34935a` | 1.26.0 | Chỉ test. Không có tag nên version là pseudo-version; kéo `franz-go/pkg/kadm` v1.18.0 làm dependency gián tiếp |

Không dùng `kadm` trong code: topic là hạ tầng, tạo bằng `rpk` (mục 5), service không tạo hay sửa topic.

## 2. Thư viện object storage

### Các lựa chọn về thư viện object storage

#### A. `github.com/aws/aws-sdk-go-v2/service/s3`

- Được: SDK chính chủ của S3; giai đoạn 7 dùng lại nguyên code, chỉ đổi cách lấy credential (credential chain, Pod
  Identity) và gọi thêm MediaConvert cùng SDK; GCS ở giai đoạn 8 nói được XML API tương thích S3 với HMAC key. Có
  `PresignPostObject` (đã kiểm, xem dưới).
- Mất: nhiều module nhỏ (`aws`, `credentials`, `service/s3` và các module nội bộ chúng kéo theo); mặc định của SDK hướng
  tới AWS (checksum mới, virtual-hosted style) nên phải chỉnh cho MinIO.

#### B. `github.com/minio/minio-go/v7` (`v7.3.0`, go 1.25.0)

- Được: một module, `PostPolicy` trưởng thành, chạy với MinIO, S3, GCS.
- Mất: lệch hệ sinh thái AWS ở giai đoạn 7 (credential chain, Pod Identity, MediaConvert vẫn phải dùng aws-sdk-go-v2, nên
  khi đó repo có hai SDK cho cùng một việc).

### Quyết định về thư viện object storage

Chọn **A**.

| Module | Version | `go` trong `go.mod` | Dùng |
| --- | --- | --- | --- |
| `github.com/aws/aws-sdk-go-v2` | `v1.47.3` | 1.24 | Gói `aws` (kiểu cấu hình, `aws.String`...) |
| `github.com/aws/aws-sdk-go-v2/credentials` | `v1.20.9` | 1.24 | `credentials.NewStaticCredentialsProvider` |
| `github.com/aws/aws-sdk-go-v2/service/s3` | `v1.114.3` | 1.24 | Client S3, `PresignClient` |

- **Không dùng gói `config`** (`config.LoadDefaultConfig`): nó đọc `~/.aws/config`, `~/.aws/credentials` và biến
  `AWS_*` của môi trường, nên service có thể vô tình nhận credential khác với biến đã khai. Dựng thẳng `s3.Options`:
  `Region` = `S3_REGION`, `BaseEndpoint` = `S3_ENDPOINT`, `UsePathStyle: true`, `Credentials` = static credentials từ
  `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY`, `RequestChecksumCalculation` và `ResponseChecksumValidation` =
  `aws.RequestChecksumCalculationWhenRequired` / `aws.ResponseChecksumValidationWhenRequired` (mặc định mới của SDK gửi
  checksum CRC mà MinIO bản cũ và GCS không nhận đủ). Giai đoạn 7 đổi phần credential, phần còn lại giữ.
- **Presigned POST** bằng `s3.NewPresignClient(client).PresignPostObject(ctx, &s3.PutObjectInput{Bucket, Key}, opts)`, với
  `opts.Expires = 15 * time.Minute` và `opts.Conditions` gồm `[]any{"content-length-range", 1, size}` và
  `map[string]string{"Content-Type": contentType}`. Đọc mã nguồn v1.114.3 (`presign_post.go`, `createPolicyDocument`):
  - policy luôn có `{"bucket": ...}`; nếu `Conditions` không có điều kiện nào về `key` thì SDK tự thêm `{"key": key}`,
    tức **khớp chính xác** key (UP-1). Code không được thêm `["starts-with", "$key", ...]`, vì có nó thì SDK bỏ điều kiện
    khớp chính xác;
  - điều kiện bổ sung được nối nguyên vào policy, nên `content-length-range` [1, `size` đã khai] và `Content-Type` khớp chính
    xác nằm trong phần đã ký (UP-1);
  - `Values` trả về gồm `key`, `policy`, `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Signature`, **không có
    `Content-Type`**: service tự thêm `Content-Type` vào `form_fields`, không thì storage từ chối form vì policy đòi field đó;
  - với `UsePathStyle`, URL = `<endpoint>/<bucket>`; policy không chứa host.

## 3. Hai endpoint cho storage

### Các lựa chọn về endpoint

#### A. Hai endpoint: nội bộ cho service, công khai cho URL trả client

- Được: service gọi MinIO qua mạng compose; client nhận URL mở được từ máy host; trên AWS hai biến cùng giá trị nên code
  không có nhánh riêng cho local.
- Mất: thêm một biến và một presign client thứ hai.

#### B. `host.docker.internal` cho cả hai phía

- Mất: container gọi được, nhưng máy host không phân giải tên này ổn định (tuỳ phiên bản Docker Desktop và cấu hình
  `/etc/hosts`), nên URL trả client lúc được lúc không.

#### C. `network_mode: host` cho service

- Mất: mất cô lập mạng của compose; cổng gRPC lộ ra máy (ngược IN-2).

### Quyết định về endpoint

Chọn **A**.

- Service gọi API S3 (`HeadObject`, `DeleteObject`, `GetObject`, `PutObject`) qua `S3_ENDPOINT=http://minio:9000`.
- `upload_url` trả client ký bằng một presign client riêng dựng với `BaseEndpoint` = `S3_PUBLIC_ENDPOINT`
  (`http://127.0.0.1:9000` ở local). Ký presigned chỉ là tính toán cục bộ, không gọi mạng, nên client này không cần tới
  được endpoint công khai.
- Vì sao cần hai client dù chữ ký POST không ký host: SigV4 của POST policy ký chuỗi policy, không ký host, nên về chữ ký thì
  dùng chung một client cũng được; nhưng SDK ghép URL trả về từ endpoint của client, và presigned GET/PUT (giai đoạn sau có
  thể cần) thì có ký host. Hai endpoint là cách đúng cho mọi loại presigned.

## 4. Object key và bucket

### Các lựa chọn về key

#### A. Key trong contract là nguyên văn key trong bucket; bucket chọn theo tiền tố

- Được: không cắt ghép chuỗi ở đâu cả; key trong database, trong event, trong policy IAM theo tiền tố và đường dẫn CDN
  (giai đoạn 7: origin là bucket `media`, path = key) trùng nhau; nhìn key là biết object nằm ở đâu.
- Mất: tên bucket lặp trong đường dẫn (`media/media/...`) khi dùng path-style ở local.

#### B. Bỏ tiền tố khi ghi (`uploads/<id>` thành key `<id>` trong bucket `uploads`)

- Được: URL local gọn hơn.
- Mất: mọi chỗ đọc ghi phải nhớ cắt và ghép tiền tố; quên một chỗ là đọc sai object; policy IAM và đường dẫn CDN lệch key
  trong contract.

### Quyết định về key

Chọn **A**.

- Key trong contract (`uploads/<video_id>`, `media/<video_id>/...`) là key trong bucket. Tiền tố `uploads/` → bucket
  `S3_UPLOADS_BUCKET` (mặc định `uploads`); tiền tố `media/` → bucket `S3_MEDIA_BUCKET` (mặc định `media`).
- URL phát = `MEDIA_PUBLIC_BASE_URL` + `/` + key. Local `MEDIA_PUBLIC_BASE_URL=http://127.0.0.1:9000/media`, nên URL là
  `http://127.0.0.1:9000/media/media/<id>/master.m3u8`. Chấp nhận chữ `media` lặp: đó là tên bucket (path-style) cộng tiền tố
  key; trên CDN, `MEDIA_PUBLIC_BASE_URL` là domain CDN và URL thành `https://<cdn>/media/<id>/master.m3u8`.
- Path-style luôn bật ở giai đoạn này (MinIO local không có DNS cho virtual-hosted style). Xem lại ở giai đoạn 7: S3 vẫn
  nhận path-style cho bucket hiện có nhưng AWS khuyên virtual-hosted.

## 5. Redpanda

### Các lựa chọn về tạo topic

#### A. Bật auto-create, topic tự sinh khi produce lần đầu

- Mất: gõ sai tên topic là có topic mới lặng lẽ; số partition, retention lấy mặc định của broker; cấu hình topic không nằm
  trong repo.

#### B. Service tạo topic lúc khởi động (`kadm`)

- Mất: service cần quyền quản trị broker (ngược IN-4 ở giai đoạn 4); topology rải trong code nhiều service, ai khởi động
  trước thì cấu hình người đó thắng.

#### C. Tắt auto-create; container one-shot `redpanda-init` tạo topic bằng `rpk`

- Được: topology là hạ tầng, nằm ở một chỗ trong repo, giống Job k8s hay Terraform về sau; service chỉ cần quyền
  produce/consume.
- Mất: thêm một container one-shot; thêm topic phải sửa script init.

### Các lựa chọn về số partition

| | Được | Mất |
| --- | --- | --- |
| 1 partition | Đơn giản, thứ tự toàn cục | Chỉ một media-worker chạy được; không học được scale consumer |
| **3 partition** | Tối đa 3 media-worker song song, khớp "≥ 3 worker" ở [architecture §3.2](../architecture.md#32-kết-quả) | Thứ tự chỉ trong một partition (đủ, vì key theo `video_id`, ADR-0003 luật 3) |
| 6+ partition | Dư chỗ scale | Thừa với tải hiện tại; tăng partition về sau thì được, giảm thì không |

### Quyết định về Redpanda

Chọn **C** và **3 partition**.

- Image `redpandadata/redpanda:v26.2.4` (đã kiểm arm64; digest lúc kiểm
  `sha256:c98c2f04a751e6646012cc701bac5183252cee44c88ba1dfa412e4c7124f2e89`). Một node, chạy
  `--smp 1 --memory 1G --overprovisioned`; giới hạn container 1,5 GB RAM, 1 CPU.
- Listener: `redpanda:9092` cho mạng compose; listener thứ hai quảng bá `127.0.0.1:19092`, publish `127.0.0.1:19092` cho
  test và `rpk` từ máy host. Admin API, schema registry, HTTP proxy không publish.
- `auto_create_topics_enabled=false` đặt tường minh lúc khởi động.
- `redpanda-init` dùng cùng image, chạy `rpk topic create` cho từng topic, bỏ qua lỗi "đã tồn tại" (idempotent); service
  chờ nó xong (`service_completed_successfully`).

| Topic | Partition | Replication | Retention |
| --- | --- | --- | --- |
| `video.lifecycle.v1` | 3 | 1 | 7 ngày (`retention.ms=604800000`) |
| `media.transcodes.v1` | 3 | 1 | 7 ngày |
| `video.lifecycle.v1.dlq` | 1 | 1 | 14 ngày (`retention.ms=1209600000`) |
| `media.transcodes.v1.dlq` | 1 | 1 | 14 ngày |

- Consumer group: `media-worker` (đọc `video.lifecycle.v1`, ghi DLQ `video.lifecycle.v1.dlq`), `video-service` (đọc
  `media.transcodes.v1`, ghi DLQ `media.transcodes.v1.dlq`). DLQ giữ lâu hơn topic gốc để kịp xem và phát lại.
- Topic của user-service (`user.follows.v1`) và engagement-service (`engagement.views.v1`) tạo ở phần sau của giai đoạn 2,
  cùng lúc với code phát chúng.

## 6. MinIO

### Bối cảnh riêng: MinIO ngừng phát hành image chính thức

Kiểm ngày 2026-10-11: `minio/minio` và `minio/mc` trên Docker Hub trả `denied`; `quay.io/minio/minio` không có manifest hoặc
đòi đăng nhập với mọi tag đã thử (`latest`, `RELEASE.2025-10-15T17-29-55Z`, `RELEASE.2025-09-07...`,
`RELEASE.2025-07-23...`, `RELEASE.2025-04-22...`). Theo báo cáo của bên thứ ba (issue `milvus-io/milvus#53430`, bài trên
byteiota.com, trang hỗ trợ IBM node 7289585): image trên Docker Hub bị xoá khoảng 2026-09-11, Quay bắt đầu đòi xác thực
khoảng 2026-09-24; repo GitHub của MinIO đã archive, bản community không còn nhận bản vá. Ghim `minio/minio:RELEASE.*`
như dự định ban đầu là không làm được.

### Các lựa chọn về image MinIO

#### A. `cgr.dev/chainguard/minio`, ghim digest

- Được: Chainguard build MinIO từ mã nguồn và vẫn cập nhật (bản đã kiểm: `RELEASE.2026-09-22T19-25-18Z`, go1.27.2, image tạo
  2026-10-10); chạy không root (uid 65532); có sẵn `mc` (`/usr/bin/mc`, version báo `DEVELOPMENT.GOGET` vì build bằng
  `go get`) và `/bin/sh`, nên `minio-init` dùng cùng image; API S3 và POST policy là của chính MinIO.
- Mất: gói miễn phí chỉ phát tag `latest`, nên phải ghim theo digest; cập nhật bằng cách đổi digest bằng tay; phụ thuộc chính
  sách của một nhà cung cấp.

#### B. `derklaro/minio:RELEASE.2025-10-15T17-29-55Z`

- Được: bản dựng lại bản community cuối cùng, có tag.
- Mất: một cá nhân dựng, không kiểm được nguồn; đóng băng ở bản cũ, không có bản vá. Loại.

#### C. Đổi sang object storage khác

SeaweedFS (`chrislusf/seaweedfs`), Garage (`dxflrs/garage:v2.1.0`), RustFS (`rustfs/rustfs`).

- Được: dự án còn phát triển, đều có image arm64.
- Mất: mỗi cái phải kiểm lại POST policy (`content-length-range`, khớp key chính xác), bucket policy ẩn danh và user IAM theo
  tiền tố trước khi dùng; thay đổi lớn, đáng một ADR riêng.

### Quyết định về MinIO

Chọn **A**: `cgr.dev/chainguard/minio@sha256:7df55d002b698e4494a131b848dd553361bbe58b7e19f62d9623c29af1ba9ccf` cho cả
`minio` và `minio-init`.

- MinIO chỉ chạy local, sau `127.0.0.1`; giai đoạn 7 dùng S3, giai đoạn 8 dùng GCS. Rủi ro của một bản community không còn
  bảo trì chính chủ vì vậy chỉ nằm trên máy dev.
- Container `minio`: giới hạn 512 MB RAM; API publish `127.0.0.1:9000`, console `127.0.0.1:9001`; image chạy uid 65532 nên
  volume dữ liệu phải ghi được bởi uid này (kiểm khi viết compose).
- Container one-shot `minio-init` (`--entrypoint /bin/sh`, script dùng `mc`) tạo bucket, policy, user; idempotent (chạy lại
  không lỗi, không đổi gì). Root credential (`MINIO_ROOT_USER` ghi trong compose, `MINIO_ROOT_PASSWORD` =
  `SVP_MINIO_ROOT_PASSWORD`) chỉ có ở `minio` và `minio-init`, service không bao giờ nhận (UP-5).
- User theo service (UP-4, UP-5, FF-4), mỗi user một policy gắn riêng:

  | User (access key) | Quyền |
  | --- | --- |
  | `svp-video-service` | `s3:PutObject`, `s3:GetObject` (cần cho `HeadObject`), `s3:DeleteObject` trên `arn:aws:s3:::uploads/uploads/*`; `s3:ListBucket` trên `arn:aws:s3:::media` với điều kiện `StringLike` `s3:prefix` = `media/*` (`StringEquals` không khớp `media/<id>/`, liệt kê để dọn bị từ chối); `s3:DeleteObject` trên `arn:aws:s3:::media/media/*` (dọn HLS dở của video `FAILED`) |
  | `svp-media-worker` | `s3:GetObject` trên `arn:aws:s3:::uploads/uploads/*`; `s3:PutObject` trên `arn:aws:s3:::media/media/*` |

  Secret key lấy từ `SVP_VIDEO_S3_SECRET_KEY` và `SVP_MEDIA_WORKER_S3_SECRET_KEY`.
- Bucket `media`: ẩn danh chỉ `s3:GetObject` trên `arn:aws:s3:::media/media/*`, **không** `s3:ListBucket` (UP-6). Đặt bằng
  `mc anonymous set-json` với policy viết tay, không dùng policy dựng sẵn `download` của `mc` (policy đó cho cả liệt kê
  bucket). Test của phần compose kiểm: đọc ẩn danh một object được, liệt kê ẩn danh bị từ chối.
- Bucket `uploads`: không có quyền ẩn danh nào.
- Ba biến bí mật mới trong `.env`: `SVP_MINIO_ROOT_PASSWORD`, `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`.
  `make env` thêm biến còn thiếu vào `.env` có sẵn, không đổi biến đã có (để `.env` của giai đoạn 1 dùng tiếp được); dòng có
  tên biến mà giá trị rỗng tính là thiếu.
- Xem lại khi: digest đang ghim không pull được nữa; Chainguard đổi chính sách gói miễn phí; có lỗ hổng chưa vá ảnh hưởng cách
  dùng local (ví dụ lỗ hổng khai thác được từ chính máy host). Khi đó chuyển sang lựa chọn C bằng ADR mới.

## 7. Outbox

Hiện thực phương án B của [ADR-0003](0003-async-events-outbox.md).

### Các lựa chọn về cách relay lấy dòng

#### A. `SELECT ... FOR UPDATE SKIP LOCKED` (câu chữ của ADR-0003)

- Được: nhiều replica cùng relay song song, mỗi replica lấy một lô khác nhau.
- Mất: hai event cùng key có thể rơi vào hai lô ở hai replica; replica giữ lô sau có thể produce trước, nên event lệch thứ tự
  trên partition, vi phạm ADR-0003 luật 3 (ví dụ `video.ready` tới trước `video.uploaded` của cùng video).

#### B. Một relay tại một thời điểm, khoá bằng `pg_try_advisory_xact_lock`

- Được: dòng được gửi đúng thứ tự `id`, nên đúng thứ tự theo key (với bất biến ghi ở phần quyết định); không cần thêm
  hệ thống khoá nào ngoài Postgres; replica không giữ được khoá thì bỏ vòng đó, không chặn gì.
- Mất: thông lượng relay bằng một replica. Với vài event mỗi giây của luồng upload thì thừa.

### Quyết định về outbox

Chọn **B**. Đây là chỉnh nhỏ so với câu "`FOR UPDATE SKIP LOCKED`" của ADR-0003, vì lý do thứ tự ở trên; phần còn lại của
ADR-0003 giữ nguyên.

- Bảng `outbox` nằm trong database của từng service, tạo bằng migration goose của service đó:

  ```sql
  CREATE TABLE outbox (
      id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      event_id     uuid        NOT NULL UNIQUE,
      topic        text        NOT NULL,
      record_key   text        NOT NULL,
      payload      bytea       NOT NULL,              -- bytes của message bọc, ví dụ svp.video.v1.VideoEvent
      headers      jsonb       NOT NULL DEFAULT '{}', -- header Kafka, gồm traceparent
      created_at   timestamptz NOT NULL DEFAULT now(),
      published_at timestamptz
  );
  CREATE INDEX outbox_unpublished_idx ON outbox (id) WHERE published_at IS NULL;
  ```

- Bất biến khi ghi: transaction nghiệp vụ khoá dòng thực thể trước (`UPDATE ... WHERE` hoặc `SELECT ... FOR UPDATE`), rồi
  mới chèn dòng outbox trong cùng transaction. Nhờ vậy hai transaction cùng một thực thể nối đuôi nhau, `id` của outbox tăng
  theo thứ tự commit; chèn outbox trước khi khoá thì transaction lấy `id` 10 có thể commit sau transaction lấy `id` 11, và
  relay gửi event lệch thứ tự.
- Relay là goroutine trong service, code ở gói dùng chung `internal/outbox`. Mỗi vòng là một transaction:
  1. `pg_try_advisory_xact_lock(<hằng số int64 của internal/outbox>)`; không được khoá thì commit và chờ. Khoá advisory
     thuộc phạm vi database, mỗi service một database, nên một hằng số chung cho mọi service là đủ;
  2. đọc tối đa 100 dòng `published_at IS NULL` theo `id` tăng dần;
  3. produce đồng bộ (`ProduceSync`) giữ key, payload, header;
  4. `UPDATE ... SET published_at = now()` cho các dòng đã gửi, commit (khoá tự nhả khi transaction kết thúc).
- Lấy đủ 100 dòng thì chạy vòng tiếp ngay; ít hơn thì chờ 200 ms. Produce lỗi thì rollback, chờ rồi thử lại; dòng đã produce
  mà chưa kịp đánh dấu sẽ được gửi lại (at-least-once, consumer chịu được trùng).
- Dọn: mỗi 10 phút xoá theo lô (vài nghìn dòng một lệnh) các dòng `published_at < now() - interval '24 hours'`. Xoá là
  idempotent, chạy cùng lúc ở nhiều replica cũng không sai, nên không cần khoá.
- Phải trả: transaction của relay mở trong lúc produce (tối đa bằng timeout produce); không đo được lag outbox tới khi có
  metric ở giai đoạn 3.

## 8. Consumer

### Các lựa chọn về commit offset

#### A. Auto-commit định kỳ

- Mất: offset có thể được commit trước khi handler xong; worker chết giữa chừng là mất event (ngược tiêu chí "kill worker
  giữa chừng, video không mất" của giai đoạn 2).

#### B. Commit tay sau khi handler xong (at-least-once)

- Được: event chỉ được coi là xong khi tác dụng đã xảy ra; kết hợp handler idempotent thì trùng không gây sai.
- Mất: phải tự viết vòng xử lý, retry, DLQ.

### Các lựa chọn về retry

| | Được | Mất |
| --- | --- | --- |
| **Retry trong process có backoff, rồi DLQ** | Đơn giản; lỗi tạm thời ngắn (storage timeout) tự hết | Partition bị chặn trong lúc retry (mặc định tối đa ~7,5 s chờ; media-worker vài phút, mục 9) |
| Topic retry riêng (`<topic>.retry.N`) | Không chặn partition | Thêm topic và consumer; mất thứ tự theo key, mà thứ tự là luật 3 của ADR-0003 |

### Quyết định về consumer

Chọn **B** và **retry trong process**, hiện thực một lần ở gói dùng chung `internal/kafkax`:

- Commit tay sau khi handler trả về (thành công, hoặc đã đẩy sang DLQ, hoặc bỏ qua có chủ ý).
- Lỗi tạm thời: `MaxAttempts` là tổng số lần gọi handler cho một record, kể cả lần đầu (mặc định 5); giữa hai lần là backoff
  mũ từ 0,5 s tới trần 10 s, có jitter (mặc định tối đa 0,5 + 1 + 2 + 4 = 7,5 s chờ). Consumer đặt ngân sách riêng được
  (media-worker, mục 9). Handler nhận biết lần thử
  hiện tại có phải lần cuối không (media-worker cần để phát `transcode.failed` với `RETRIES_EXHAUSTED` thay vì để event
  vào DLQ).
- Lỗi vĩnh viễn (handler bọc bằng `kafkax.Permanent(err)`: event không parse được, thiếu field bắt buộc, vi phạm nghiệp vụ)
  hoặc hết lượt: produce sang `<topic>.dlq` giữ nguyên key, value, header gốc, thêm header `dlq-reason`
  (`permanent` | `retries-exhausted`, gạch nối), `dlq-error`, `dlq-topic`, `dlq-partition`, `dlq-offset`; rồi commit (IN-5).
- Nhánh `oneof` chưa biết hoặc không cần: bỏ qua và commit (ADR-0006).
- `traceparent` đọc từ header Kafka khi nhận và ghi vào header khi produce (cùng key với metadata gRPC, ADR-0007 mục 8).
- Job dài và rebalance: handler của media-worker chạy tới 10 phút. Heartbeat của franz-go chạy nền nên worker không bị loại
  khỏi group vì job dài. Consumer bật `BlockRebalance` (media-worker bật): rebalance **chờ** handler đang chạy xong và commit
  của nó vào, không huỷ handler; vì commit lên partition đã bị thu về sẽ mất. `RebalanceTimeout` vì vậy phải phủ trọn ngân
  sách retry của một record (mọi lần thử cộng mọi backoff), không thì group loại thành viên không kịp vào lại; ở media-worker
  là 164 phút (mục 9). Với balancer mặc định cooperative-sticky, chỉ việc thu partition bị chờ; giao partition của thành viên
  đã chết không bị chặn. Khi worker dừng (huỷ context), handler bị huỷ và event đó không được commit; worker nhận partition
  sẽ làm lại từ đầu, ghi đè cùng đường dẫn (mục 9).
- **`processed_events`** (`event_id uuid PRIMARY KEY`, `consumer text NOT NULL`, `processed_at timestamptz NOT NULL DEFAULT
  now()`) là thiết kế cho consumer có tác dụng không tự idempotent (ADR-0003 luật 1). Phần A **không tạo** bảng này: hai
  consumer đều tự idempotent. video-service chuyển trạng thái một chiều (`PROCESSING` → `READY`/`FAILED`) kèm outbox trong
  cùng transaction, gặp lại event thì trạng thái đã khác `PROCESSING` và không làm gì; media-worker ghi đè đường dẫn cố định.
  Idempotent của transcode nghĩa là cùng kết quả nghiệp vụ, không phải cùng từng byte (libx264 đa luồng không cho kết quả
  bit-exact): playlist biến thể giống hệt, `master.m3u8` giống hệt sau khi che `BANDWIDTH`/`AVERAGE-BANDWIDTH`, và các giá
  trị bandwidth đo được lệch nhau ≤ 5 % (`make drill-duplicates` kiểm).
  Tạo khi có consumer cần (bộ đếm của engagement-service).

## 9. media-worker

### Các lựa chọn về image runtime

| | Được | Mất |
| --- | --- | --- |
| distroless `static` (như service) | Không shell, không package | Không có ffmpeg; chép ffmpeg vào thì phải chép cả thư viện động của nó |
| **`alpine` ghim tag + `apk add ffmpeg`** | Nhỏ; ffmpeg do Alpine build và vá; có `ffprobe` | Có shell và package manager trong image (bù bằng `read_only`, `cap_drop`, không root) |
| `debian-slim` + `apt install ffmpeg` | Bản ffmpeg phổ biến | Image nặng hơn nhiều (kéo theo hàng trăm thư viện) |
| ffmpeg static tải ngoài (ví dụ johnvansickle) | Bản ffmpeg mới nhất | Khó kiểm nguồn và chuỗi cung ứng; tự gánh cập nhật |

### Quyết định về media-worker

Chọn **alpine + `apk add ffmpeg`**.

- Không database, không cổng, không gRPC (FF-4). Nhận `video.lifecycle.v1`, phát `media.transcodes.v1` bằng produce thẳng
  (không có database nên không có outbox, ADR-0003 luật 4).
- Image riêng `deploy/docker/media-worker.Dockerfile`: stage build Go giống `service.Dockerfile` (`golang:1.27.2-trixie`,
  `CGO_ENABLED=0`, `-trimpath`); runtime `alpine:3.24.2` (digest lúc kiểm
  `sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6`) + `apk add --no-cache ffmpeg`. Không ghim version
  gói `ffmpeg`: Alpine xoá bản cũ khỏi repo khi có bản vá, ghim cứng sẽ làm build gãy; tag alpine ghim giữ nhánh 3.24, bản vá
  trong nhánh được nhận khi build lại. Bản đã kiểm: ffmpeg 8.1.2-r0. Thư mục `/work` tạo sẵn trong image, chủ là
  65532:65532; chạy `USER 65532:65532`.
- Compose: `read_only: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, seccomp mặc định; 2 CPU, 2 GB
  RAM; named volume gắn vào `/work` làm thư mục tạm (không dùng tmpfs, vì tmpfs tính vào RAM, mà một job cần tới gần 1 GB).
- Mạng: media-worker chỉ nối vào một mạng compose riêng `worker` (`internal: true`, không ra internet) chứa thêm `redpanda`
  và `minio`; không nối mạng mặc định nơi có gateway và các service gRPC (FF-4; lớp NetworkPolicy đầy đủ ở giai đoạn 4,
  FF-5).
- Mỗi worker xử lý một job một lúc. Job tải file gốc về `/work/<video_id>/` (FF-2 bắt buộc file cục bộ), xoá thư mục job khi
  xong (thành công hay lỗi), xoá thư mục sót lại trong `/work` lúc khởi động. Đĩa mỗi job < 1 GB (gốc ≤ 500 MiB + đầu ra của
  video ≤ 3 phút).
- Ghi kết quả: upload segment và playlist biến thể trước, `master.m3u8` sau cùng, rồi mới phát `transcode.completed`. Người
  xem chỉ tới được bản HLS qua master playlist, nên không ai thấy master trỏ tới segment chưa có.
- Phân loại lỗi của media-worker:
  - **vĩnh viễn**, phát `transcode.failed` ngay (`INVALID_INPUT` hoặc `DURATION_EXCEEDED`): file hỏng, ngoài whitelist, vượt
    giới hạn, ffprobe/ffmpeg thoát lỗi, bị tín hiệu giết (crash trên file độc, chạm giới hạn RAM) hoặc hết giờ (30 s / 10
    phút). File độc chỉ chạy một lần, không chặn partition qua các lần retry;
  - **tạm thời**, thử lại: storage, Kafka, mạng, và hết `tryTimeout` (15 phút) của một lần thử (tải về, ffprobe, ffmpeg,
    upload). Lần cuối vẫn lỗi thì phát `transcode.failed` với `RETRIES_EXHAUSTED`;
  - event hỏng (không parse được, thiếu field, key sai dạng): `kafkax.Permanent`, sang DLQ.
- Ngân sách retry của media-worker: 10 lần thử, backoff 1 s tới trần 60 s (tổng chờ khoảng 4 phút), để sự cố storage hay
  broker một hai phút không thành `RETRIES_EXHAUSTED` (khiến video-service xoá file gốc của người dùng). `RebalanceTimeout`
  = 10 × (15 phút + 30 s produce) + 9 × 60 s = 164 phút.
- Không healthcheck HTTP ở phần A (không có server); probe liveness/readiness để giai đoạn 4.

## 10. HLS và ffmpeg

### Các lựa chọn về độ dài segment

| | Được | Mất |
| --- | --- | --- |
| 2 s | Khởi phát nhanh nhất, đổi bitrate nhanh | Gấp đôi số object và request; playlist dài hơn |
| **4 s** | Ít object hơn một nửa; video ngắn vẫn khởi phát nhanh (segment đầu của 360p chỉ ~400 KB) | Đổi bitrate chậm hơn một nhịp |
| 6 s (mặc định cũ của Apple) | Ít object nhất | Khởi phát chậm thấy rõ với video 15–60 s |

### Các lựa chọn về preset `libx264`

| | Được | Mất |
| --- | --- | --- |
| `ultrafast` | Nhanh nhất | File to hơn rõ ở cùng chất lượng, tốn egress (khoản chi lớn nhất, architecture §3.3) |
| **`veryfast`** | Giữ được mục tiêu ~60 s cho video 60 s trên 2 vCPU (A8) | File to hơn `medium` một chút |
| `medium` (mặc định) | File nhỏ hơn | Chậm gấp vài lần, khó giữ p95 < 2 phút |

### Quyết định về HLS và ffmpeg

Segment **4 s**, preset **`veryfast`**; đo lại thời gian transcode và kích thước đầu ra ở cuối phần A, đổi nếu số đo lệch.

- Ladder theo cạnh ngắn (video dọc là chủ yếu, ADR-0004), bitrate theo A6:

  | Rendition | Cạnh ngắn | Bitrate video |
  | --- | --- | --- |
  | `360p` | 360 | 0,8 Mbps |
  | `720p` | 720 | 2,5 Mbps |
  | `1080p` | 1080 | 5 Mbps |

  Không upscale: chỉ tạo các bậc có cạnh ngắn ≤ cạnh ngắn của nguồn. Nguồn nhỏ hơn 360p thì một bản ở kích thước gốc (làm
  tròn xuống cạnh chẵn), tên `source`, bitrate 0,8 Mbps.
- H.264 (`libx264`, `-preset veryfast`) + AAC 128 kbps; nguồn không có audio thì đầu ra không có audio.
- Segment MPEG-TS 4 s (`-hls_time 4`), keyframe mỗi 2 s không phụ thuộc fps
  (`-force_key_frames "expr:gte(t,n_forced*2)"`), `-sc_threshold 0`, `-hls_playlist_type vod`.
- Một lần chạy ffmpeg cho mọi bản: `-filter_complex` với `split` + `scale`, `-var_stream_map` đặt tên theo rendition,
  `-master_pl_name master.m3u8`.
- Thumbnail JPEG lấy ở giây 1 (video ngắn hơn 1 s thì ở giữa video), một lần chạy ffmpeg riêng với cùng các giới hạn.
- Đường dẫn: `media/<id>/master.m3u8`, `media/<id>/<rendition>/index.m3u8`, segment trong `media/<id>/<rendition>/`,
  `media/<id>/thumbnail.jpg`.
- Biện pháp threat model bắt buộc:
  - **FF-1:** chạy `ffprobe` trước (JSON, `-show_format -show_streams`), chỉ nhận:
    - container: MP4/MOV (`format_name` `mov,mp4,m4a,3gp,3g2,mj2`) hoặc WebM/Matroska (`matroska,webm`);
    - codec video `h264`, `hevc`, `vp8`, `vp9`, `av1`; audio `aac`, `mp3`, `opus`, `vorbis`.

    ffprobe và ffmpeg đều chạy với `-format_whitelist` (demuxer `mov`, `matroska`) và `-codec_whitelist` cùng danh sách. Tên
    trong `-codec_whitelist` là tên **decoder** của bản ffmpeg trong image, có thể khác tên codec (ví dụ AV1 có thể giải bằng
    `libdav1d`, MP3 bằng `mp3float`); chuỗi chính xác chốt khi viết code, có test cho file hợp lệ và file bị từ chối. Sai
    whitelist thì `transcode.failed` với `INVALID_INPUT`.
  - **FF-2:** `-protocol_whitelist file`; demuxer playlist/tham chiếu (HLS, concat...) không có trong whitelist định dạng;
    ffmpeg và ffprobe chạy với môi trường rỗng (`cmd.Env = []string{}`) trên file cục bộ trong `/work/<video_id>/`.
  - **FF-3:** `ffprobe` kiểm thời lượng ≤ 181 s (1 s dung sai), cạnh dài ≤ 4096 px, fps ≤ 120, ≤ 8 stream, có ít nhất một
    video stream; quá thời lượng thì `DURATION_EXCEEDED`, sai giới hạn khác thì `INVALID_INPUT`. ffmpeg vẫn ép `-t 180` vì
    metadata có thể nói dối. Timeout bằng `exec.CommandContext`: 30 s cho ffprobe, 10 phút cho ffmpeg.
  - **FF-7:** `-map_metadata -1`, luôn mã hoá lại, không `-c copy`.

## 11. Cấu hình mới

### Các lựa chọn về cấu hình storage và broker

#### A. Biến môi trường như ADR-0007 mục 4

- Được: cùng một image chạy ở compose, k8s, cloud; đúng quy ước đã có.
- Mất: danh sách biến của video-service dài thêm.

#### B. Một biến URL gộp (ví dụ `S3_URL=http://key:secret@minio:9000/uploads`)

- Mất: trộn bí mật với địa chỉ; phải tự parse; không khớp cách SDK nhận cấu hình.

### Quyết định về cấu hình

Chọn **A**. Thiếu biến bắt buộc hoặc sai định dạng thì service thoát ngay lúc khởi động với lỗi nêu tên biến (không in giá
trị), như ADR-0007.

| Service | Biến | Mặc định | Ý nghĩa |
| --- | --- | --- | --- |
| `video-service` | `KAFKA_BROKERS` | — (bắt buộc) | Danh sách `host:port` cách nhau bởi dấu phẩy; compose `redpanda:9092` |
| `video-service` | `S3_ENDPOINT` | — (bắt buộc) | Endpoint S3 service gọi; compose `http://minio:9000` |
| `video-service` | `S3_PUBLIC_ENDPOINT` | = `S3_ENDPOINT` | Endpoint ghép vào `upload_url`; local `http://127.0.0.1:9000` |
| `video-service` | `S3_REGION` | `us-east-1` | Region ký SigV4 |
| `video-service` | `S3_ACCESS_KEY_ID` | — (bắt buộc) | Local `svp-video-service` |
| `video-service` | `S3_SECRET_ACCESS_KEY` | — (bắt buộc) | Local từ `SVP_VIDEO_S3_SECRET_KEY` |
| `video-service` | `S3_UPLOADS_BUCKET` | `uploads` | Bucket của tiền tố `uploads/` |
| `video-service` | `S3_MEDIA_BUCKET` | `media` | Bucket của tiền tố `media/` |
| `media-worker` | `KAFKA_BROKERS` | — (bắt buộc) | Như video-service |
| `media-worker` | `S3_ENDPOINT` | — (bắt buộc) | Như video-service (worker không ký URL nên không có `S3_PUBLIC_ENDPOINT`) |
| `media-worker` | `S3_REGION` | `us-east-1` | Như video-service |
| `media-worker` | `S3_ACCESS_KEY_ID` | — (bắt buộc) | Local `svp-media-worker` |
| `media-worker` | `S3_SECRET_ACCESS_KEY` | — (bắt buộc) | Local từ `SVP_MEDIA_WORKER_S3_SECRET_KEY` |
| `media-worker` | `S3_UPLOADS_BUCKET` | `uploads` | Như video-service |
| `media-worker` | `S3_MEDIA_BUCKET` | `media` | Như video-service |
| `media-worker` | `WORK_DIR` | `/work` | Thư mục tạm của job |
| `gateway` | `MEDIA_PUBLIC_BASE_URL` | — (bắt buộc) | Gốc URL phát (mục 4); local `http://127.0.0.1:9000/media` |

- Biến bí mật trong `.env` (mục 6): `SVP_MINIO_ROOT_PASSWORD`, `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`.
- **Test:** `SVP_TEST_S3_ENDPOINT`, `SVP_TEST_S3_VIDEO_ACCESS_KEY` / `SVP_TEST_S3_VIDEO_SECRET_KEY`,
  `SVP_TEST_S3_WORKER_ACCESS_KEY` / `SVP_TEST_S3_WORKER_SECRET_KEY`, `SVP_TEST_KAFKA_BROKERS`. Thiếu biến nào thì test cần
  biến đó gọi `t.Skip`; test chỉ cần Kafka mà không cần broker thật dùng `kfake`, nên `make check` vẫn chạy được không cần
  Docker. `make test-stack` đặt các biến này từ `.env` (MinIO `http://127.0.0.1:9000`, Redpanda `127.0.0.1:19092`) khi stack
  đang chạy.

## 12. Cổng và RAM

### Các lựa chọn về cổng

#### A. Cổng mặc định của từng phần mềm, chỉ trên `127.0.0.1`

- Được: tài liệu, `mc`, `rpk` dùng mặc định là chạy; nhìn cổng biết phần mềm.
- Mất: đụng nếu máy có phần mềm khác dùng cùng cổng (đã kiểm: không có).

#### B. Dời vào dải riêng của project (ví dụ `92xx`)

- Mất: phải nhớ ánh xạ, đổi cấu hình mặc định của công cụ, không thêm lợi ích gì khi cổng đang trống.

### Quyết định về cổng và RAM

Chọn **A**:

| Thành phần | Cổng publish | Ghi chú |
| --- | --- | --- |
| MinIO API | `127.0.0.1:9000` | Client upload, test, URL phát local |
| MinIO console | `127.0.0.1:9001` | Xem bucket bằng trình duyệt |
| Redpanda (Kafka API) | `127.0.0.1:19092` | Test và `rpk` từ host; trong compose là `redpanda:9092` |

Giới hạn bộ nhớ trên Docker VM 7,65 GiB:

| Container | Giới hạn |
| --- | --- |
| `redpanda` | 1,5 GB, 1 CPU |
| `minio` | 512 MB |
| `media-worker` | 2 GB, 2 CPU |
| `gateway`, `user-service`, `video-service` | Không đổi (vài chục MB mỗi cái) |
| `redpanda-init`, `minio-init`, migrate | One-shot, thoát sau vài giây |

Tổng giới hạn < 4,5 GB, còn chỗ cho Postgres/Redis native ngoài VM và cho profile `obs` ở giai đoạn 3 (không bật cùng
`obs-elastic`).

## 13. Phạm vi phần A

### Các lựa chọn về phạm vi

#### A. Làm đủ mọi biện pháp giai đoạn 2 của luồng upload cùng lúc

- Mất: job dọn upload bỏ dở cần khoá phân tán (lab `distributed-cron-lock`), giới hạn số video `UPLOADING` đi cùng rate limit
  cần Redis; gộp vào làm phần A phình to, khó đo từng phần.

#### B. Phần A làm luồng upload chạy đầu-cuối có số đo; các phần cần Redis hoặc lab riêng làm ở phần sau

- Được: phần A kết thúc ở trạng thái chạy được (upload → HLS → `READY`/`FAILED`), đúng nguyên tắc của plan.
- Mất: trong khoảng giữa hai phần, upload bỏ dở và gọi `InitUpload` liên tục chưa bị chặn (chỉ chạy local, chấp nhận).

### Quyết định về phạm vi

Chọn **B**. Ngoài phần A (ghi lại ở Hệ quả):

- Job dọn upload bỏ dở ([ADR-0004](0004-direct-upload-and-hls.md) luật 4) và giới hạn số video `UPLOADING` mỗi user (UP-7):
  làm cùng rate limit ở phần sau của giai đoạn 2.
- Phát lại DLQ: làm bằng `rpk` (đọc `<topic>.dlq`, produce lại vào topic gốc), chưa có công cụ riêng; cảnh báo DLQ ở giai
  đoạn 3.
- SASL/ACL của Redpanda (IN-4): giai đoạn 4.

## Hệ quả

- Được:
  - Luồng upload chạy thật trên local: storage tự ép key, kích thước, content type (UP-1); credential theo service với quyền
    tối thiểu (UP-4, UP-5, FF-4); bucket `media` không liệt kê được (UP-6).
  - Không mất event khi crash (outbox + commit tay); event cùng video giữ thứ tự (relay một luồng, key theo `video_id`); event
    hỏng không chặn partition (DLQ).
  - ffmpeg chạy sau ba lớp whitelist (định dạng, codec, giao thức), giới hạn tài nguyên và container không quyền, không mạng
    ra ngoài (FF-1 tới FF-4, FF-7).
  - Event `transcode.*` giả không đổi được video (FF-6): video-service chỉ nhận khi video đang `PROCESSING`, và mọi key phải
    dạng `media/<video_id>/<seg>/...`, mỗi đoạn chỉ gồm `[A-Za-z0-9._-]`, không phải `.` hay `..`. Lý do: gateway ghép key vào
    URL phát, mà trình duyệt chuẩn hoá `%2e%2e` và `\` khi phân tích URL, nên key như `media/<id>/%2e%2e/<id khác>/...`
    trỏ được sang video khác.
  - Code storage và Kafka dùng lại được ở giai đoạn 7: cùng SDK S3, cùng Kafka API cho MSK; `make check` không cần Docker nhờ
    `kfake`.
- Phải trả:
  - Thêm 5 dependency trực tiếp (`franz-go`, `kfake` cho test, `aws-sdk-go-v2`, `credentials`, `service/s3`) và các module
    nội bộ của SDK AWS trong `go.sum`.
  - MinIO dùng image Chainguard ghim digest: cập nhật bằng tay, phụ thuộc chính sách của Chainguard.
  - media-worker có image riêng trên alpine (có shell, package manager), khác chuẩn distroless của service.
  - Relay outbox một luồng cho mỗi service; transaction mở trong lúc produce.
  - Retry trong process chặn partition trong lúc retry: mặc định tối đa ~7,5 s chờ mỗi event lỗi; media-worker khoảng 4
    phút chờ cộng thời gian các lần thử, vì lỗi của nó thường là storage hay broker gián đoạn.
  - Chưa có: job dọn upload bỏ dở, giới hạn `UPLOADING` mỗi user (UP-7), rate limit (phần sau của giai đoạn 2); công cụ phát
    lại và cảnh báo DLQ (giai đoạn 3); SASL/ACL Redpanda (IN-4, giai đoạn 4); probe cho media-worker (giai đoạn 4).
- Xem lại khi:
  - Digest MinIO không pull được, Chainguard đổi chính sách, hoặc có lỗ hổng chưa vá ảnh hưởng local: chuyển sang SeaweedFS,
    Garage hoặc RustFS bằng ADR mới.
  - Lag outbox (từ `created_at` tới `published_at`) p95 vượt 1 s, hoặc số event mỗi giây vượt khả năng một relay: cân nhắc
    relay theo phân đoạn key hoặc CDC (ADR-0003).
  - Thời gian transcode video 60 s trên 2 CPU vượt 90 s, hoặc kích thước HLS lệch A6 quá 30%: đổi preset hoặc ladder.
  - Thời gian tới khung hình đầu tiên ở 360p vượt 2 s trên mạng 4G giả lập: thử segment 2 s.
  - Cần nhiều hơn 3 media-worker song song: tăng partition của `video.lifecycle.v1` (chỉ tăng được, không giảm được).

## Hiện thực ở

- Kafka và consumer (§1, §8): `internal/kafkax/` (franz-go, commit tay, DLQ); bảng `processed_events` và xử lý event ở
  `services/video-service/internal/server/transcode.go`.
- Object storage (§2–§4): `internal/objstore/` (aws-sdk-go-v2, presigned POST, hai endpoint, object key), test chạy thật ở
  `internal/objstore/integration_test.go`.
- Redpanda (§5): `deploy/redpanda/bootstrap.yaml`, `deploy/redpanda/create-topics.sh`. MinIO (§6): `deploy/minio/init.sh`,
  service `minio` của `deploy/compose/compose.yaml`.
- Outbox một relay (§7): `internal/outbox/`, `services/video-service/migrations/00002_create_outbox.sql`.
- media-worker, HLS và ffmpeg (§9, §10): `services/media-worker/` (`cmd/media-worker/main.go`, `internal/worker/`,
  `internal/transcode/`), `deploy/docker/media-worker.Dockerfile`; trên k3d `deploy/k8s/values/services/media-worker.yaml`,
  `deploy/k8s/drills/keda.sh`.
- Cấu hình mới, cổng và RAM (§11, §12): `services/video-service/cmd/video-service/main.go`,
  `services/video-service/internal/server/server.go`, `deploy/compose/compose.yaml`.
- Diễn tập: `deploy/compose/drills/kill-worker.sh`, `deploy/compose/drills/duplicate-events.sh`,
  `deploy/compose/drills/measure-ready.sh`.
