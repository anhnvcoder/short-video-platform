# 0004. Client upload thẳng lên object storage bằng presigned POST; transcode bất đồng bộ ra HLS

- Trạng thái: Chấp nhận; object store local (MinIO ở Bối cảnh và Quyết định) bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md) (RustFS cho compose
  và k3d; presigned POST, hai bucket và đọc công khai `media` giữ nguyên); phần Phát (đường dẫn `media/<video_id>/` cố định,
  transcode lại ghi đè) chỉnh bởi [0029](0029-immutable-media-versions.md) (output theo version `media/<video_id>/<version>/`, không
  ghi đè, `Cache-Control: max-age=31536000, immutable`)
- Ngày: 2026-10-04

## Bối cảnh

- File gốc trung bình 75 MB, tối đa 3 phút; điện thoại quay bitrate cao có thể tới vài trăm MB. 1.000 upload/ngày, cao
  điểm ~2 upload/phút ([architecture.md §3](../architecture.md#3-ước-lượng-quy-mô)).
- Upload từ mạng di động: chậm, chập chờn, một upload có thể kéo dài vài phút.
- SLO: khởi tạo upload thành công 99,9%; video 1 phút sẵn sàng phát p95 < 2 phút sau khi upload xong.
- Người xem dùng điện thoại với mạng thay đổi liên tục; egress là khoản chi lớn nhất của hệ thống.
- Phải chạy giống nhau trên MinIO (local), S3 (giai đoạn 7), GCS (giai đoạn 8).

## Các lựa chọn: đưa file lên

### A. Upload qua gateway và video-service (proxy stream)

- Được: service kiểm soát hoàn toàn, client chỉ gọi một API.
- Mất: mỗi upload giữ một kết nối và băng thông của service suốt vài phút; timeout dài phải mở ở mọi tầng (load balancer,
  gateway, service); service phải scale theo băng thông thay vì theo số request.

### B. Presigned URL, một request thẳng lên bucket

Service chỉ ký một URL có hạn dùng; client gửi file thẳng tới storage.

- Được: service tốn vài mili giây cho mỗi upload, storage gánh băng thông; cùng một cách làm trên MinIO, S3, GCS.
- Mất: hỏng giữa chừng phải upload lại từ đầu; client làm ba bước thay vì một.
- Hai biến thể: **PUT** (gửi thân file) hoặc **POST** (form kèm policy đã ký). Policy của POST cho phép storage tự
  từ chối file quá kích thước (`content-length-range`), sai content type hoặc sai key. Với PUT, việc ép kích thước tuỳ
  SDK có ký header `Content-Length` hay không.

### C. Presigned multipart upload (S3 multipart, ký từng phần)

- Được: upload lại được từng phần hỏng, gửi song song nhiều phần.
- Mất: phức tạp hơn nhiều (khởi tạo, ký từng phần, hoàn tất, huỷ, dọn upload dở dang). Đáng khi file lớn hơn nhiều so
  với ở đây, hoặc khi đo thấy tỉ lệ upload hỏng cao.

### D. Giao thức resumable riêng (tus)

- Mất: thêm một server tus phải vận hành; S3/GCS không hỗ trợ sẵn.

## Các lựa chọn: định dạng phát

| | Được | Mất |
| --- | --- | --- |
| MP4 tải thẳng | Đơn giản nhất | Một chất lượng cho mọi mạng: mạng yếu thì giật, mạng mạnh thì phí; không đổi chất lượng giữa chừng được |
| **HLS** | Tự đổi chất lượng theo mạng (adaptive bitrate); phát sẵn trên iOS/Safari, trình duyệt khác dùng hls.js; CDN cache từng segment tốt; MediaConvert và Transcoder API xuất sẵn | Nhiều file nhỏ; thêm bước transcode |
| DASH | Chuẩn mở, linh hoạt | iOS/Safari không phát sẵn |

## Quyết định

**Upload: B, biến thể POST.** Giới hạn kích thước phải được ép ở chính storage, không tin client.

1. `InitUpload(title, size, content_type)`: video-service kiểm `size` ≤ 500 MB và content type là video, tạo bản ghi
   `UPLOADING`, trả URL và các field form của presigned POST: key cố định `uploads/<video_id>`, `content-length-range`
   tối đa 500 MB, hết hạn sau 15 phút.
2. Client POST file lên storage, rồi gọi `CompleteUpload`.
3. video-service `HEAD` object để chắc file đã có và đúng kích thước, rồi trong **một transaction** chuyển `PROCESSING` và
   ghi `video.uploaded` vào outbox ([ADR-0003](0003-async-events-outbox.md)).
4. Upload bỏ dở: một job định kỳ chuyển các bản ghi `UPLOADING` quá 1 giờ sang `FAILED` và xoá object nếu có. Job này chỉ
   được chạy ở một instance tại một thời điểm (lab `distributed-cron-lock`).

**Phát: HLS.**

- Ba bản 360p / 720p / 1080p, không upscale quá độ phân giải gốc (tính theo cạnh ngắn, vì video dọc là chủ yếu).
- H.264 + AAC để tương thích rộng nhất. Segment ngắn (2–4 s) để video ngắn bắt đầu phát nhanh; độ dài cụ thể chốt bằng đo
  ở giai đoạn 2.
- Kết quả ghi vào `media/<video_id>/` (playlist chính + thư mục cho từng bản). Đường dẫn cố định theo `video_id` nên
  transcode lại một video chỉ ghi đè: worker idempotent mà không cần bảng chống trùng.
- Hai bucket: `uploads` riêng tư (chỉ service đọc), `media` chỉ đọc được qua CDN trên cloud; local thì MinIO mở đọc công
  khai cho `media`. (**Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)**, 2026-10-25: store local là RustFS, cùng bucket policy ẩn danh
  chỉ đọc từng object của `media`.)
- Transcode chạy trong media-worker bằng ffmpeg. Trên cloud, media-worker sẽ gọi MediaConvert (AWS) hoặc Transcoder API
  (GCP) thay vì tự chạy ffmpeg; event vào ra không đổi.

## Hệ quả

- Được: service không gánh băng thông upload; storage tự từ chối file quá cỡ; định dạng phát hợp với mạng di động và CDN.
- Phải trả:
  - client làm ba bước (xin URL, gửi file, báo xong) và phải xử lý URL hết hạn;
  - cần job dọn upload bỏ dở;
  - mỗi video lưu hai bản (gốc + HLS), ~137 MB thay vì 62 MB. Giữ file gốc bao lâu là câu hỏi mở;
  - ffmpeg đọc file do người dùng gửi lên: đây là bề mặt tấn công lớn nhất của hệ thống, threat model phải xét riêng.
- Xem lại khi: tỉ lệ upload hỏng giữa chừng cao, hoặc nâng giới hạn thời lượng làm file lớn hơn nhiều. Lúc đó chuyển sang C.

## Hiện thực ở

- Upload thẳng bằng presigned POST: `internal/objstore/`; `InitUpload`, `CompleteUpload` và giới hạn 500 MiB ở
  `services/video-service/internal/server/server.go`; job dọn upload bỏ dở ở `services/video-service/internal/server/sweep.go`.
- Transcode bất đồng bộ ra HLS: `services/media-worker/` (`internal/worker/` giới hạn kích thước tải về, `internal/transcode/`
  chạy ffmpeg).
- Upload từ trình duyệt: `web/features/upload/`.
