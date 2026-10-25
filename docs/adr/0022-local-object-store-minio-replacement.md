# 0022. Object store của đường local (compose và k3d) đổi từ MinIO (image Chainguard) sang RustFS, CORS theo bucket, tên trung tính `s3`; MinIO Chainguard là đường quay lại

- Trạng thái: Đề xuất
- Ngày: 2026-10-24

## Bối cảnh

- MinIO community đã ngừng: repo `minio/minio` archive ngày 2026-04-25, README ghi "THIS REPOSITORY IS NO LONGER MAINTAINED"
  và chỉ phát mã nguồn, không phát binary; bản community cuối `RELEASE.2025-10-15T17-29-55Z` [M1]. `minio/mc` archive ngày
  2026-07-14 [M2]. Bảy CVE công bố năm 2026 (hai cái cho ghi không xác thực: CVE-2026-40344, CVE-2026-41145) chỉ được vá ở
  bản thương mại AIStor [M3]. [ADR-0008](0008-async-upload-pipeline-stage2a.md) §6 đã chọn image `cgr.dev/chainguard/minio`
  ghim digest và hẹn "chuyển sang SeaweedFS, Garage hoặc RustFS bằng ADR mới"; [ADR-0016](0016-web-client.md) §11 và
  [ADR-0020](0020-reliability-stage6.md) §16 dời việc thay MinIO cho đường local sang giai đoạn 6b. ADR này là ADR đó.
- **Phạm vi:** đường local của lab, cả hai nơi đang chạy MinIO: compose (`deploy/compose/compose.yaml`, `deploy/minio/init.sh`
  và ba file policy) và cluster k3d (`deploy/helm/svp-data/templates/minio.yaml` chạy đúng `init.sh` đó qua symlink, bucket
  `pg-backups` của plugin Barman Cloud, đích Velero của diễn tập giai đoạn 6b). Cloud dùng S3/R2/GCS ở giai đoạn 7, 8, không
  thuộc ADR này; kiểm R2 vẫn ở giai đoạn 7. Không tách phạm vi (ví dụ chỉ compose): hai nơi dùng chung script, policy và hợp
  đồng, giữ hai store là phải kiểm hai bộ.
- **Hợp đồng bản thay phải giữ** (đều đã kiểm trên MinIO, không nới cái nào):
  - **Presigned POST** ([ADR-0004](0004-direct-upload-and-hls.md), ADR-0008 §2–3, [ADR-0018](0018-web-profiles-public-video-upload.md)
    §8; UP-1, UP-2, UP-4): `internal/objstore` ký bằng `PresignPostObject` của `aws-sdk-go-v2` (SigV4, path-style) policy có
    `{"key": <exact>}`, `{"Content-Type": ...}`, `["content-length-range", 1, size]`, hạn 15 phút; field `Content-Type` thêm
    vào form; URL form dùng endpoint công khai, service gọi endpoint nội bộ. Store phải **từ chối** form sai key, quá cỡ, rỗng,
    sai hay thiếu `Content-Type`, hết hạn. Thiếu một điều kiện là loại, không nới UP-x.
  - **Quyền theo user** (UP-4, UP-5, BAK-1): mỗi service một access key với policy theo bucket **và tiền tố**
    (`deploy/minio/*-policy.json`: video-service chỉ `PutObject`/`GetObject`/`DeleteObject` dưới `uploads/uploads/*`, liệt kê
    `media` với `s3:prefix` `media/*` và xoá dưới `media/media/*`; media-worker đọc `uploads/uploads/*`, ghi `media/media/*`);
    user `svp-pg-backup` chỉ bucket `pg-backups`; root chỉ ở store và job init. Chỉ có một cặp key toàn quyền, hay chỉ có cờ
    đọc/ghi theo bucket, là mất tách quyền service và BAK-1: không coi là tương đương.
  - **Đọc ẩn danh** (UP-5, UP-6): `media` cho `GetObject` từng object dưới `media/media/*`, không `ListBucket`; `uploads` và
    `pg-backups` không có gì ẩn danh. URL phát là `<origin>/media/<key>` path-style (`playlist_url` của gateway).
  - **CORS** (WEB-10, ADR-0018 §9): chỉ origin của web (compose `http://localhost:3001`, `http://localhost:3002`; k3d
    `https://svp.localhost:8443`), trả lời preflight `OPTIONS` cho `POST` vào `uploads` và `GET` ở `media`. MinIO community chỉ
    có biến toàn cục `MINIO_API_CORS_ALLOW_ORIGIN`; `PutBucketCors` là handler giả trả `NotImplemented` [M7].
  - **Barman Cloud** (ADR-0020 §5): sidecar plugin v0.15.1 chạy barman 3.20.1 với boto3 1.43.105 [B1], tức có checksum CRC và
    `aws-chunked` mặc định của boto3 ≥ 1.36; cần `head_bucket`, `list_objects_v2`, multipart, `delete_objects` (lùi về xoá từng
    key khi store đòi `Content-MD5`) [B2]. **Velero** (diễn tập giai đoạn 6b): plugin AWS v1.14.4 vẫn ép checksum CRC32 dạng
    trailer cho upload multipart trên 5 MiB, `checksumAlgorithm: ""` của BackupStorageLocation [B4] không tắt được [B5].
  - **Vận hành:** image đa kiến trúc (amd64 cho runner CI, arm64 cho máy) ghim `@sha256:`; chạy non-root với
    `readOnlyRootFilesystem`, drop ALL, seccomp `RuntimeDefault` (PSA `restricted` của `svp-data`); endpoint health không xác
    thực (compose healthcheck, probe, `threats.sh` gọi `/minio/health/live` qua Envoy); tạo bucket, user (secret key do
    `.env` chọn, 40 hex), policy bằng script idempotent; RAM nhỏ (compose `mem_limit` 512 MiB, k3d giới hạn 512 MiB, ADR-0014
    §2).

## Các lựa chọn

Mọi nguồn đọc ngày **2026-10-24** (trang web, hay cùng nội dung qua `gh api`); danh sách ở mục Nguồn. "Chưa kiểm được" là
không tìm thấy nguồn, không phải "không có". Không image nào được kéo về máy để thử: số RAM chưa có nguồn đo ở lượt hiện thực.

| Phương án | Presigned POST (UP-1) | CORS (WEB-10) | Quyền theo user, ẩn danh (UP-4…6, BAK-1) | Barman, Velero | Giấy phép, bảo trì | Image, non-root, RAM |
| --- | --- | --- | --- | --- | --- | --- |
| **A. Giữ MinIO, image Chainguard ghim digest** (hiện trạng) | Đủ `eq`, `starts-with`, `content-length-range` [M8]; đã kiểm ở lab (`TestIntegrationPresignedPost`, ADR-0008) | Chỉ toàn cục [M7]; đã kiểm WEB-10 ở compose và k3d (ADR-0018 §9, ADR-0019) | Policy IAM theo user và tiền tố, bucket policy ẩn danh: đã kiểm ở lab (ADR-0008 §6, BAK-1 ADR-0020) | Barman: đã chạy ở k3d (ADR-0020 Kết quả); Barman ghi yêu cầu MinIO ≥ `RELEASE.2025-02-03` cho xoá [B2]. Velero: chưa kiểm | AGPL-3.0 [M1]. Upstream archive; Chainguard giữ fork `chainguard-forks/minio`, đã vá cả 7 CVE 2026 (commit 2026-05-01…06-04) và lỗi header `x-amz-*` không ký (2026-09-22), "best-effort", không nhận đóng góp, không vá nếu cần sửa lớn [M6] | Image tạo 2026-10-23, uid 65532, có shell [M4]; gói miễn phí chỉ tag `latest`, x86_64 + arm64 [M5] nên chỉ ghim digest, Renovate không đọc được version; `mc` đi kèm do Chainguard build từ module của repo `mc` đã archive [M6]. RAM: trong giới hạn 512 MiB hiện nay (lab) |
| **B. Fork `pgsty/silo` (tiền thân `pgsty/minio`)** | Mã MinIO, coi như A; chưa kiểm ở lab | Như A (toàn cục) | Như A | Như A | AGPL-3.0; 12 bản từ 2025-12-03, bản cuối `RELEASE.2026-10-18T00-00-00Z`; một nhóm nhỏ (Pigsty) bảo trì; đổi tên 2026-08-06, không còn binary tên `minio`, client là `mcli` [M9]; tuyên bố đã vá các CVE 2026 [M10] | `pgsty/silo` amd64 + arm64, có bản distroless [M9]; user mặc định: chưa kiểm được; RAM: chưa kiểm được |
| **C. Garage v2.4.1** | Có; kiểm chữ ký SigV4, hạn, `eq`/`starts-with` mọi field, `content-length-range` lúc stream; mọi field phải có điều kiện [G1][G2] | **Chỉ theo bucket**, nhiều origin; preflight vào bucket không phân giải được trả `*` [G3] | **Không đạt:** chỉ cờ `read`/`write`/`owner` theo cặp key–bucket, không bucket policy, không theo tiền tố [G1]; đọc ẩn danh chỉ qua chế độ website, cổng 3902 riêng, chọn bucket theo `Host` [G4] → video-service cần `write` trên `media` để xoá HLS, tức ghi được `media` (mất UP-4); `playlist_url` đổi dạng | Barman: một người dùng báo chạy được [B6]; thiếu tagging, Object Lock [G1]. Velero: chưa kiểm được | AGPL-3.0; bản 3–5 tháng một lần (v2.4.1 đẩy 2026-09-08) [G6] | `dxflrs/garage` đa kiến trúc, `FROM scratch`, root mặc định, chart chính chủ chạy uid 1000, read-only [G5]; không shell (init cần image khác gọi admin API); RAM: chart ghi 512 Mi–1 Gi "indicative" [G5] |
| **D. SeaweedFS 4.48/4.49** | Có; kiểm chữ ký, hạn, `eq`/`starts-with` [W1][W2]; **`content-length-range` chỉ kiểm sau khi đọc hết form** (5 MiB trong RAM, phần còn lại ra file tạm) [W1]: form quá cỡ vẫn tốn đĩa trước khi bị từ chối; trước 4.46 POST bỏ qua kiểm quyền theo key [W8] | Theo bucket + cờ toàn cục `-s3.allowedOrigins`, **mặc định `*` trong mã** (wiki nói khác) [W3][W4] | Danh tính `Write:bucket/prefix`, bucket policy và IAM nhúng, ví dụ đọc ẩn danh `GetObject` [W5][W6]; không cấu hình thì **nhận mọi access key** [W4] | Barman: issue mở WAL archive thoát mã 4 [W12], đã có lỗi trailer lọt vào `backup.info` [W13]; lỗi `aws-chunked` bị `AccessDenied` sửa ở 4.49 [W7] | Apache-2.0; ~15 bản từ 2026-06 tới 2026-10-23 [W9] | `chrislusf/seaweedfs` đa kiến trúc; **4.49 chưa có trên Docker Hub** [W10]; entrypoint chạy root rồi `su-exec` uid 1000 [W11]; `weed mini` gộp master, volume, filer, S3, WebDAV, Iceberg, Admin UI; RAM: chưa kiểm được |
| **E. RustFS 1.0.3** | Có, qua thư viện `s3s`: kiểm chữ ký SigV4 POST (cờ `allow_post_signature` mặc định bật ở `s3s` [R2]; RustFS 1.0.3 có tắt không: chưa kiểm được), hạn trước khi đọc file, `eq`, `starts-with`, `content-length-range` [R2]; trước alpha.83 (2026-02) không kiểm điều kiện nào [R3] | **Theo bucket** (`PutBucketCors`, preflight khớp 200, không khớp 403) và danh sách toàn cục `RUSTFS_CORS_ALLOWED_ORIGINS`, mặc định rỗng: không header CORS [R4] | Policy IAM JSON kiểu AWS theo user, `arn:aws:s3:::bucket/prefix/*`, điều kiện `s3:prefix` [R5]; bucket policy ẩn danh tải object "không cho liệt kê ẩn danh" [R6] | **Barman: e2e của chính plugin chạy trên RustFS** từ 2026-09-24 (PR #1109) [R13]; checksum CRC32, CRC32C, CRC64NVME, SHA, lỗi multipart với checksum đã sửa [R14]. Velero: chưa kiểm được | Apache-2.0; 1.0.0 ngày 2026-09-16, 1.0.3 ngày 2026-10-17 [R1]; công ty RustFS, Inc.; **CLA cho công ty quyền phát hành lại dưới giấy phép bất kỳ, kể cả độc quyền** [R10]; **43 advisory, 42 trong 2026** (4 critical, 17 high), nhiều cái về policy, xác thực [R9] | `rustfs/rustfs:1.0.3` amd64 + arm64, có digest; Alpine có `sh`, `curl`; `USER` uid 10001 [R7]; chart chính chủ non-root, read-only, drop ALL nhưng không đặt seccomp [R8]; health `/health/*` và bí danh `/minio/health/*` [R11]; CLI `rc` ở repo riêng, Apache-2.0 [R12]; RAM: chưa kiểm được |
| **F. VersityGW v1.10.0 (backend POSIX)** | Có từ v1.4.0; hạn bắt buộc, `eq`, `starts-with`, `content-length-range`, mọi field phải có điều kiện, kiểm chữ ký SigV4 [V1] | Theo bucket; toàn cục chỉ **một** origin [V2] | Vai trò `admin`/`user`/`userplus`; quyền theo bucket qua bucket policy (principal theo tài khoản, tiền tố, `s3:prefix`); policy theo user chỉ khi chạy dịch vụ IAM riêng [V3]; đọc ẩn danh không liệt kê: chưa kiểm được | Barman, Velero: chưa thấy báo cáo | Apache-2.0; khoảng một bản mỗi tháng, v1.10.0 ngày 2026-10-22; README "production-ready"; 8 advisory [V6] | `versity/versitygw` amd64 + arm64; **chạy root**, base `alpine:latest` [V4]; chart chạy uid 1000, read-only [V4]; backend POSIX cần xattr hay cờ `--sidecar`/`--nometa`; RAM khuyến nghị ≥ 1 GB [V5] |
| **G. Ceph RGW (Tentacle 20.2.4)** | Có; `eq`, `starts-with`, `content-length-range`, hạn [C1] | Theo bucket trong mã [C1] | Tài khoản, IAM user policy, bucket policy, `s3:prefix` [C2] | Chưa kiểm được; v19 thiếu module checksum mới [C1] | LGPL-2.1/3; còn bảo trì [C5] | `quay.io/ceph/ceph` chạy root, ~517 MiB nén; image demo đã archive; Rook một node dùng `hostPath` (PSA cấm) [C4]; **OSD ≥ 4 GiB, MON ≥ 5 GB** [C3]: không vừa máy 16 GB. Loại |
| **H. Zenko CloudServer 9.5.0** | **Không có POST Object** (PR mở từ 2024, chưa kiểm policy) [Z1] | Theo bucket; issue mở với boto3 ≥ 1.36 [Z3] | Không Vault (độc quyền) thì chỉ tài khoản root trong `authdata.json`, không IAM user [Z2] | Chưa kiểm được | Apache-2.0; nhiều bản 2026 [Z4] | Image GHCR **chỉ amd64**, chạy root, entrypoint ghi vào thư mục app [Z2]. Loại |

### A. Giữ MinIO, image Chainguard ghim digest

- Được: không đổi gì; mọi hợp đồng đã kiểm trên đúng bản này; Chainguard vá CVE trong vài tuần (AIStor vá 2026-03-17…04-14, fork
  Chainguard vá 2026-04-10…06-04) [M3][M6].
- Mất: một nhà cung cấp quyết toàn bộ vòng đời ("best-effort", không đóng góp được, gói miễn phí chỉ `latest`), không theo dõi
  version được; tính năng đóng băng ở MinIO 2025 (CORS chỉ toàn cục, khác S3 của giai đoạn 7); `mc` cũng từ repo đã archive;
  lab dừng ở công cụ mà ngành đang rời bỏ.

### B. Fork `pgsty/silo`

- Được: mã MinIO, đổi ít (image, `mc` → `mcli`), có tag version.
- Mất: nhóm bảo trì nhỏ, đã đổi tên một lần trong năm; AGPL; CORS vẫn toàn cục; user mặc định và RAM chưa kiểm được.

### C. Garage

- Được: nhẹ, AGPL ổn định, POST policy chặt.
- Mất: không có quyền theo tiền tố và không có bucket policy, đọc ẩn danh phải qua cổng website riêng: mất UP-4 và đổi hợp đồng
  URL phát. Loại theo tiêu chí quyền.

### D. SeaweedFS

- Được: Apache-2.0, phát hành dày, quyền theo tiền tố, bucket policy, CORS theo bucket.
- Mất: `content-length-range` kiểm sau khi đã nhận cả form (UP-1 vẫn từ chối nhưng đĩa đã tốn, ngược ý "storage tự từ chối");
  mặc định CORS `*` và nhận mọi key khi thiếu cấu hình (cấu hình sót là mở); bản sửa lỗi `aws-chunked` chưa có image; issue
  Barman còn mở; một process gộp nhiều dịch vụ không cần.

### E. RustFS

- Được: Apache-2.0, đã GA; policy IAM và bucket policy kiểu AWS nên ba file policy và `media-anonymous.json` dùng lại được về
  nội dung; CORS theo bucket như S3 (giai đoạn 7) và mặc định đóng; plugin Barman Cloud kiểm e2e trên RustFS; image non-root có
  tag version; bí danh `/minio/health/*` và tiền tố `/minio/admin/v3` cho công cụ của MinIO [R11].
- Mất: dự án trẻ, lịch sử bảo mật dày (43 advisory, nhiều cái về policy và xác thực, đúng phần lab dựa vào); CLA cho phép đổi
  giấy phép như MinIO đã làm; init phải viết lại (image không có `mc`, `rc` chưa kiểm phần admin); RAM chưa có nguồn.

### F. VersityGW

- Được: Apache-2.0, POST policy chặt, nói rõ production-ready, ít advisory.
- Mất: policy theo user cần thêm dịch vụ IAM riêng (hay dồn quyền vào bucket policy theo principal); CORS toàn cục một origin;
  image chạy root; cần xattr; RAM khuyến nghị 1 GB.

### G. Ceph RGW, H. Zenko CloudServer

Loại: Ceph vượt RAM của máy và cần `hostPath`; CloudServer không có POST Object và không có image arm64.

## Quyết định

Chọn **E. RustFS** cho cả compose và k3d, đổi trong **một lần**, với điều kiện qua đủ kế hoạch kiểm dưới đây; trượt một
điểm của UP-1, UP-4, UP-5, UP-6, WEB-10 hay BAK-1 mà không có bản RustFS đã phát hành sửa trong buổi đó thì **quay lại A**
(MinIO Chainguard, digest đang ghim) theo đường chép ngược ở mục Cách chuyển, không nới kiểm soát nào.

Vì sao E hơn A: A vẫn chạy được và vá được (Chainguard đã vá cả 7 CVE), nhưng mọi thứ của A phụ thuộc một nhà cung cấp làm
"best-effort" trên mã đã đóng băng, không có version để Renovate theo, CORS không theo bucket được. E đạt mọi tiêu chí có
nguồn (D, F mỗi cái hụt một tiêu chí bảo mật hay vận hành; C hụt quyền), dùng lại được policy và health path, và là store mà
chính plugin Barman Cloud chọn để kiểm. Cái giá bảo mật của E (advisory dày) được giới hạn vì store chỉ nghe trên loopback
(compose) hay sau Envoy trên loopback (k3d), và được theo dõi bằng điều kiện xem lại.

Chi tiết cho lượt hiện thực:

1. **Image:** `rustfs/rustfs:<version>@sha256:<index đa kiến trúc>` (bản ≥ 1.0.3 mới nhất lúc làm), một anchor trong compose và
   `values.yaml` của `svp-data`, Renovate theo version như image ghim khác (ADR-0015 §10). Chạy uid 10001 của image (compose
   `user:`, k3d `podSecurityContext` với `fsGroup` và seccomp `RuntimeDefault`), root đọc-chỉ, drop ALL.
2. **Tên trung tính `s3`** thay `minio` ở mọi chỗ đặt tên store: service compose và volume (`s3`, `s3-data`), StatefulSet,
   Service, NetworkPolicy, Job init và nhãn ở `svp-data` (`s3.svp-data:9000`, HTTPRoute vẫn `s3`), Secret `s3-root`,
   `s3-users`, thư mục `deploy/s3/`, biến `.env` `SVP_S3_ROOT_PASSWORD` (`make env` tạo biến mới; biến cũ còn trong `.env`
   thì không ai đọc). Lý do: tên `minio` cho một store không phải MinIO đánh lừa người đọc, và lần đổi sau (quay lại A, hay thử
   R2) không phải đổi tên nữa. Ba user service, tên bucket, key, `S3_*` của service không đổi.
3. **CORS theo bucket** thay biến toàn cục: job init đặt `PutBucketCors` cho `uploads` (`POST` từ origin web) và `media`
   (`GET`, `HEAD` từ origin web), origin lấy từ biến của job (compose `http://localhost:3001,http://localhost:3002`, k3d
   `https://svp.localhost:8443`); `RUSTFS_CORS_ALLOWED_ORIGINS` để rỗng, nên bucket không có cấu hình thì không có header CORS
   (đóng khi thiếu). WEB-10 chặt hơn hôm nay: preflight `POST` vào `media` hay `GET` ở `uploads` từ origin web cũng bị từ chối.
4. **Init:** viết lại `init.sh` (giữ hợp đồng: idempotent, đặt lại secret key và policy theo `.env`, root chỉ ở store và job
   init, `pg-backups` chỉ khi có `SVP_PG_BACKUP_S3_SECRET_KEY`). Công cụ theo thứ tự: CLI `rc` của RustFS ghim digest nếu nó
   tạo được user với secret key chọn sẵn, policy, bucket policy ẩn danh và CORS; không được thì `curl --aws-sigv4` (có trong
   image RustFS) gọi API admin `/rustfs/admin/v3/add-user`, `add-canned-policy` [R5] và API S3. Không dùng `mc` của repo đã
   archive. Ba file policy và `media-anonymous.json` giữ nguyên nội dung nếu RustFS nhận; sửa gì thì ghi lý do.
5. **Barman Cloud:** `ObjectStore` `svp-pg-backup` chỉ đổi `endpointURL`. Không đặt trước
   `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; chỉ thêm qua `instanceSidecarConfiguration.env` [B3] nếu
   `drill-k8s-backup` trượt vì checksum, kèm lý do.
6. **RAM:** giữ giới hạn 512 MiB ở compose và k3d tới khi có số đo nghỉ và đỉnh (upload ~100 MB, base backup); chỉnh theo số
   đo, ghi vào mục Kết quả.

## Kế hoạch kiểm (viết trước, chạy ở lượt hiện thực)

Thứ tự là thứ tự chạy; một dòng trượt thì dừng, sửa hay quay lại A, không chạy tiếp để "xem cho biết". Compose chạy trên máy
một lượt (`make up` profile `core`), sau bước chép ở mục Cách chuyển; k3d chạy trên nơi chạy của giai đoạn 6b
([ADR-0021](0021-deferred-verification-stage6b.md)). Mục 13 dùng target `object-store-copy` mà lượt hiện thực thêm (chưa có
trong `make help` hôm nay); mọi target khác đã có.

| # | Kiểm gì | Lệnh | Đạt khi |
| --- | --- | --- | --- |
| 1 | File hợp lệ, test đơn vị không đổi | `make compose-config`, `make helm-check`, `make check` | Sạch; `make check` xanh (không đụng test) |
| 2 | Bucket, user, policy, CORS tạo được, chạy lại không đổi gì | `make up` hai lần | Job init thành công cả hai lần; log init không in secret |
| 3 | UP-1, UP-4 trên store thật | `make test-stack PKGS=./internal/objstore/...` | `TestIntegrationPresignedPost` (form đúng; đổi key sang upload khác, sang `media`; quá 1 byte; rỗng; sai và thiếu `Content-Type`; hết hạn; URL endpoint công khai), `TestIntegrationWorkerPermissions`, `TestIntegrationVideoServicePermissions`, `TestIntegrationDeletePrefix` đều PASS, không SKIP |
| 4 | Luồng đầu-cuối, UP-5, UP-6 | `make smoke` | Xanh: upload tới `READY`, phát HLS, thumbnail; đọc ẩn danh `uploads` bị từ chối; liệt kê ẩn danh `media` bị từ chối |
| 5 | Upload từ trình duyệt qua CORS | `make web-e2e` | Xanh ở Chromium và WebKit, gồm project `*-publishing` |
| 6 | WEB-10 compose | `curl -si -X OPTIONS` như ADR-0018 §9, thêm hai ca mới | `Origin: http://evil.example` → không `Access-Control-Allow-Origin` ở `/uploads` (`POST`) và `/media/...` (`GET`); `http://localhost:3001` → đúng origin; `POST` vào `/media` và `GET` ở `/uploads` từ `http://localhost:3001` → không header |
| 7 | Dọn upload bỏ dở | `make drill-upload-cleanup` | PASS; script tra object bằng công cụ mới, không còn `mc stat` |
| 8 | Telemetry không lộ form, cổng loopback | `make up OBS=lgtm`, `make drill-obs-threats` | PASS; OPS-1 vẫn đúng 8 cổng loopback (tên service mới) |
| 9 | RAM compose | `docker stats` của container `s3` lúc nghỉ và trong `make measure-upload` | Đỉnh < 512 MiB, ghi số |
| 10 | k3d: luồng, policy, BAK-1, WEB-10 | `make k8s-up`, `make k8s-smoke`, `make drill-k8s-threats` | `k8s-smoke` xanh; `drill-k8s-threats` toàn PASS, gồm WEB-10 (origin `https://svp.localhost:8443`), BAK-1 (`svp-pg-backup` chỉ `pg-backups`, user service không tới bucket đó; mã lỗi của RustFS khớp lại nếu khác `AccessDenied`/`NoSuchKey`), OPS-2, IN-2/FF-5 với tên `s3` |
| 11 | Backup và phục hồi | `make drill-k8s-backup`, `make drill-k8s-backup MODE=pitr` | WAL lưu liên tục không lỗi sau khi job init xong; cả hai chế độ phục hồi và `k8s-smoke` qua; RTO, RPO ghi lại, so với lượt MinIO của ADR-0020 (lệch nhiều thì ghi lý do) |
| 12 | Velero (diễn tập giai đoạn 6b) | Theo ADR-0021 | BackupStorageLocation `Available`; backup có file trên 5 MiB (multipart CRC32 trailer [B5]) và restore qua |
| 13 | Đường quay lại chạy thử (compose, trước khi xoá volume `minio-data`) | Dừng ghi như quy tắc 1 của Cách chuyển, `make object-store-copy TO=minio`, rồi `make up`, `make smoke` | Kiểm của bước chép lệch 0, gồm các video `READY` tạo trên RustFS ở mục 4–5; không revert; stack chạy lại trên RustFS và `make smoke` xanh |

## Cách chuyển

- **Một thay đổi, một lần:** compose, k3d, policy, script, tài liệu cùng một PR; không có giai đoạn chạy song song hai store
  trong repo.
- **Dữ liệu phải giữ ở compose:** Postgres native (`svp_video`) không đổi khi đổi store, nên mọi key mà một dòng `videos` trỏ
  tới phải có trên store đang chạy. Đó là `media/<id>/…` (playlist, segment, thumbnail) của video `READY` **và** `uploads/<id>`
  của video `READY` lẫn `PROCESSING`: video-service không xoá file gốc khi video thành `READY`, chỉ xoá cả hai phía khi video
  `FAILED` (`transcode.failed`, hay job dọn với video `UPLOADING` quá hạn). Bỏ `uploads` là mất bản gốc duy nhất của video đã
  phát; video `PROCESSING` thiếu file gốc thì media-worker phát `transcode.failed` lý do `SOURCE_MISSING`, video thành `FAILED`
  và video-service xoá phần còn lại của nó.
- **Ba quy tắc, cả hai chiều (đi và quay lại):**
  1. **Dừng ghi trước khi chép:** không upload trong buổi chuyển; chờ tới khi không còn video `PROCESSING`
     (`SELECT status, count(*) FROM videos GROUP BY status` trên `svp_video`, chỉ đọc), rồi `make down` (giữ volume), nên
     không service nào ghi vào store nào trong lúc chép. Video `UPLOADING` không cần chờ: object đã có thì được chép; form gửi
     sau đó mà store mới không nhận thì job dọn chuyển video sang `FAILED` như upload bỏ dở.
  2. **Chép đủ, kiểm xong mới đổi endpoint:** chép **mọi object của `uploads` và `media`**, giữ key và `Content-Type` (playlist,
     segment, thumbnail, file gốc), đích làm giống hệt nguồn (thêm, ghi đè, xoá key thừa). Kiểm: danh sách key và kích thước hai
     bên lệch 0; mọi `playlist_key`, `thumbnail_key` và `uploads/<id>` của video `READY`, `PROCESSING` trong `svp_video` (chỉ
     `SELECT`) có trên đích với `Content-Type` như nguồn. Kiểm trượt thì không đổi endpoint: stack chạy lại trên store cũ.
  3. **Store cũ chỉ xoá khi đường chép ngược đã chạy thử** (mục 13 của kế hoạch kiểm) và mục 1–9 đã qua.
- **Bước chép** là target mới `make object-store-copy TO=s3|minio` (script `deploy/compose/object-store-copy.sh`): từ chối khi
  stack compose hay cluster k3d đang chạy (quy tắc 1, máy 16 GB); dựng tạm hai store trên một network nội bộ, không publish cổng:
  MinIO bằng image A ghim digest trên volume `minio-data`, RustFS trên volume `s3-data`; tạo bucket đích nếu chưa có (user, policy,
  bucket policy, CORS do init của stack đích đặt ở `make up` sau đó); chép bằng `mc mirror --overwrite --remove` [M11] của chính
  image A, vì image A đã phải chạy để đọc volume MinIO nên `mc` của nó không thêm phụ thuộc mới (init lâu dài vẫn không dùng
  `mc`); chạy kiểm của quy tắc 2; xong thì gỡ hai container tạm, không xoá volume nào. Script và digest A ở lại trong repo chừng
  nào RustFS còn chạy: đó là đường quay lại. Quay lại muộn (theo "Xem lại khi") thì cập nhật digest A sang bản Chainguard mới nhất
  trước khi chép; đích là volume rỗng hay được làm giống hệt nguồn nên bản nào đọc được cũng đủ.
- **Compose, chiều đi:** trên `main` (MinIO) dừng ghi theo quy tắc 1; sang nhánh của PR, `make object-store-copy TO=s3`; qua
  kiểm thì chạy kế hoạch kiểm mục 1–9 (mục 2 là `make up`), rồi mục 13; qua cả thì xoá volume cũ
  (`env -u DOCKER_DEFAULT_PLATFORM docker volume rm svp_minio-data`) trong cùng buổi.
- **k3d:** cluster mới (`make k8s-down`, `make k8s-up`): Postgres trong cluster cũng mới nên không có gì để chép và không có
  dòng nào trỏ vào object cũ; `install.sh` tự chụp backup cơ sở cho thế hệ đang chạy. Lịch sử backup trên MinIO cũ mất cùng
  cluster (chấp nhận: lab, chưa có dữ liệu cần giữ).
- **Quay lại A** (trong buổi chuyển, hay sau này theo "Xem lại khi"); revert PR một mình không đủ, vì video tạo trên RustFS
  (`make smoke`, `make web-e2e`, dùng thật) có dòng trong `svp_video` mà object chỉ nằm ở `s3-data`:
  1. trên bản RustFS, dừng ghi theo quy tắc 1;
  2. `make object-store-copy TO=minio` (volume `minio-data` còn hay đã xoá đều được: đích được làm giống hệt nguồn); kiểm trượt
     thì dừng, vẫn chạy RustFS;
  3. revert PR (bỏ luôn script), `make up` trên MinIO, `make smoke`; playlist và thumbnail của một video `READY` tạo trên RustFS
     trả 200;
  4. xoá `s3-data` khi đã qua; k3d dựng lại cluster ở bản đã revert như chiều đi.

## Danh sách file phải đổi

Từ `git ls-files | xargs grep -li minio` (bỏ `gen/`, `web/gen/`, `plans/`), ngày 2026-10-24:

- **Compose:** `deploy/compose/compose.yaml` (service, volume, image, CORS chuyển sang init, healthcheck không còn `mc ready`),
  `deploy/minio/` → `deploy/s3/` (`init.sh` viết lại, bốn file JSON), `deploy/compose/compose.mk` (`S3_SECRET_VARS`, chú
  thích giới hạn 40 ký tự, `test-stack`, `clean-data`, target mới `object-store-copy`), script mới
  `deploy/compose/object-store-copy.sh` (bước chép hai chiều của mục Cách chuyển), `deploy/compose/drills/common.sh` (tên service),
  `deploy/compose/drills/upload-cleanup.sh` (`mc stat` trong container), `deploy/compose/drills/obs-threats.sh` (danh sách
  cổng), `deploy/observability/glitchtip/dotenv-test.sh`.
- **k3d:** `deploy/helm/svp-data/templates/minio.yaml` → `s3.yaml`, `deploy/helm/svp-data/values.yaml`, `deploy/helm/svp-data/templates/networkpolicies.yaml`,
  `deploy/helm/svp-data/templates/backup.yaml` (`endpointURL`), `deploy/helm/svp-data/files/minio` (symlink) → `files/s3`,
  `deploy/helm/svp-data/Chart.yaml`, `deploy/helm/svp-cluster/templates/namespaces.yaml`, `deploy/helm/svp-service/values.yaml`
  (đích egress `minio`), `deploy/k8s/values/services/{video-service,media-worker,gateway,web}.yaml`, `deploy/k8s/secrets.sh`
  (Secret, phát hiện mật khẩu root lệch và restart: hành vi của RustFS khi root đổi phải kiểm lại), `deploy/k8s/install.sh`,
  `deploy/k8s/gitops.sh`, `deploy/k8s/k8s.mk`, `deploy/k8s/drills/threats.sh` (34 chỗ: tên host, `/minio/health/live`, BAK-1,
  WEB-10), `deploy/k8s/drills/backup.sh`, `deploy/k8s/values/plugin-barman-cloud.yaml` (chú thích).
- **Code và test (chỉ chú thích, chuỗi ví dụ):** `internal/objstore/objstore.go`, `objstore_test.go`, `integration_test.go`,
  `services/video-service/cmd/video-service/main.go`, `services/media-worker/cmd/media-worker/main.go` (và hai `main_test.go`),
  `proto/svp/video/v1/video_service.proto` (chú thích; `buf breaking` không đổi), `web/server/env.ts`, `web/server/csp.ts`,
  `web/server/env.test.ts`, `web/e2e/{fixtures,measure-upload.e2e,security.e2e,stack}.ts`, `web/e2e/seed.sh`, `renovate.json`.
- **Tài liệu:** `CLAUDE.md`, `AGENTS.md`, `docs/architecture.md`, `docs/threat-model.md` (UP-5, WEB-10, BAK-1, BAK-2),
  `docs/runbooks/*` có nhắc MinIO (9 file), `docs/adr/README.md` (dòng 0022; ADR-0008 ghi "§6 chỉnh bởi 0022").

Rủi ro: `threats.sh` và `secrets.sh` dựa vào hành vi riêng của MinIO (mã lỗi, đọc mật khẩu root lúc khởi động); `init.sh`
viết lại là chỗ dễ nới quyền nhầm nhất, nên mục 3, 4, 10 của kế hoạch kiểm là cổng của nó. Cụm tên `minio` → `s3` rộng nhưng
cơ học; sót một chỗ thì NetworkPolicy hay `S3_ENDPOINT` trỏ vào tên không có và `k8s-smoke` đỏ ngay. Bước chép là chỗ duy nhất
có thể mất dữ liệu: nó không xoá volume nào, và endpoint chỉ đổi sau khi kiểm của nó lệch 0.

## Hệ quả

- Được: object store local có bảo trì, giấy phép Apache-2.0, ghim được theo version; CORS theo bucket như S3 nên WEB-10 chặt
  hơn và gần cấu hình giai đoạn 7; tên `s3` không gắn với sản phẩm; init không còn phụ thuộc `mc` đã archive.
- Phải trả: một lượt sửa rộng (danh sách trên) và một lượt kiểm đủ compose + k3d; dựa vào một dự án trẻ có nhiều advisory về
  xác thực và policy (cập nhật bản vá phải theo sát hơn MinIO Chainguard); dữ liệu cũ: hai bucket `uploads`, `media` của
  compose chép một lần khi đã dừng ghi, backup Postgres trên k3d cũ bỏ; giữ trong repo script chép hai chiều và digest A làm
  đường quay lại.
- **Xem lại khi** (một điều là đủ; quay lại A theo mục Cách chuyển nếu A còn được Chainguard phát, không thì xét D hay F bằng
  ADR mới):
  - một mục của kế hoạch kiểm trượt mà bản RustFS đã phát hành chưa sửa;
  - advisory critical hay high của RustFS chạm phần lab dùng (POST policy, policy IAM, bucket policy, CORS, chữ ký) chưa có bản
    vá sau 30 ngày kể từ ngày công bố;
  - RustFS đổi giấy phép khỏi Apache-2.0 (CLA cho phép), ngừng phát hành quá 6 tháng hay archive repo;
  - image mới mất một trong hai kiến trúc, hay không chạy được non-root;
  - plugin Barman Cloud bỏ RustFS khỏi e2e vì lỗi tương thích;
  - RAM của store vượt 512 MiB ở mục 9 hay 10 của kế hoạch kiểm.

## Hiện thực ở

Chưa hiện thực; file sẽ đổi liệt kê ở mục "Danh sách file phải đổi". Hiện chỉ một chỗ phụ thuộc quyết định này: mục bỏ qua cảnh
báo của MinIO trong chart ở `deploy/ci/trivy-config-ignore.yaml`, bỏ cùng MinIO khi chuyển.

## Nguồn

Đọc ngày 2026-10-24.

- [M1] <https://github.com/minio/minio> (archive 2026-04-25, README, release cuối, giấy phép)
- [M2] <https://github.com/minio/mc> (archive 2026-07-14)
- [M3] <https://github.com/minio/minio/security/advisories> (CVE-2026-33322, -33419, -34204, -39414, -40344, -41145, -42600)
- [M4] <https://images.chainguard.dev/directory/image/minio/specifications>
- [M5] <https://images.chainguard.dev/directory/image/minio/versions>
- [M6] <https://github.com/chainguard-forks/minio> (README, release `RELEASE.2026-10-23T20-06-51Z`, commit vá CVE)
- [M7] <https://raw.githubusercontent.com/minio/minio/master/cmd/dummy-handlers.go>, <https://raw.githubusercontent.com/minio/minio/master/cmd/api-router.go>
- [M8] <https://raw.githubusercontent.com/minio/minio/master/cmd/postpolicyform.go>
- [M9] <https://github.com/pgsty/silo> (README, release)
- [M10] <https://vonng.com/en/db/minio-promise-kept/>
- [M11] <https://github.com/minio/mc/blob/master/cmd/mirror-main.go> (cờ `--overwrite`, `--remove` của `mc mirror`)
- [G1] <https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/>
- [G2] <https://github.com/deuxfleurs-org/garage/blob/main-v2/src/api/s3/post_object.rs>
- [G3] <https://github.com/deuxfleurs-org/garage/blob/main-v2/src/api/common/cors.rs>
- [G4] <https://github.com/deuxfleurs-org/garage/blob/main-v2/doc/book/cookbook/exposing-websites.md>
- [G5] <https://github.com/deuxfleurs-org/garage/blob/main-v2/script/helm/garage/values.yaml>, <https://github.com/deuxfleurs-org/garage/blob/main-v2/Dockerfile>
- [G6] <https://hub.docker.com/v2/repositories/dxflrs/garage/tags/v2.4.1>, <https://github.com/deuxfleurs-org/garage/blob/main-v2/LICENSE>
- [W1] <https://github.com/seaweedfs/seaweedfs/blob/master/weed/s3api/s3api_object_handlers_postpolicy.go>
- [W2] <https://github.com/seaweedfs/seaweedfs/blob/master/weed/s3api/policy/postpolicyform.go>
- [W3] <https://github.com/seaweedfs/seaweedfs/wiki/S3-CORS>
- [W4] <https://github.com/seaweedfs/seaweedfs/blob/master/weed/command/s3.go>
- [W5] <https://github.com/seaweedfs/seaweedfs/blob/master/weed/s3api/policy_engine/README_POLICY_ENGINE.md>
- [W6] <https://github.com/seaweedfs/seaweedfs/blob/master/weed/s3api/auth_credentials.go>
- [W7] <https://github.com/seaweedfs/seaweedfs/issues/11640>
- [W8] <https://github.com/seaweedfs/seaweedfs/pull/11072>
- [W9] <https://github.com/seaweedfs/seaweedfs/releases>
- [W10] <https://hub.docker.com/v2/repositories/chrislusf/seaweedfs/tags>
- [W11] <https://github.com/seaweedfs/seaweedfs/blob/master/docker/entrypoint.sh>
- [W12] <https://github.com/cloudnative-pg/plugin-barman-cloud/issues/679>
- [W13] <https://github.com/EnterpriseDB/barman/issues/1165>
- [R1] <https://github.com/rustfs/rustfs> (README, release 1.0.0–1.0.3)
- [R2] <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/post_policy.rs>, <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/ops/signature.rs>, <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/config.rs>
- [R3] <https://github.com/rustfs/rustfs/security/advisories/GHSA-w5fh-f8xh-5x3p>, <https://github.com/rustfs/rustfs/issues/984>
- [R4] <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/server/layer.rs>, <https://github.com/rustfs/rustfs/blob/1.0.3/crates/config/src/constants/console.rs>
- [R5] <https://docs.rustfs.com/administration/iam/policies>
- [R6] <https://docs.rustfs.com/administration/data/bucket/policy>
- [R7] <https://github.com/rustfs/rustfs/blob/1.0.3/Dockerfile>, <https://hub.docker.com/v2/repositories/rustfs/rustfs/tags/1.0.3>
- [R8] <https://github.com/rustfs/rustfs/blob/1.0.3/helm/rustfs/values.yaml>
- [R9] <https://github.com/rustfs/rustfs/security/advisories>
- [R10] <https://github.com/rustfs/rustfs/blob/1.0.3/CLA.md>
- [R11] <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/server/prefix.rs>
- [R12] <https://github.com/rustfs/cli> (`rc`, v0.1.36)
- [R13] <https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/test/e2e/internal/objectstore/s3.go>, <https://github.com/cloudnative-pg/plugin-barman-cloud/pull/1109>
- [R14] <https://github.com/rustfs/rustfs/blob/1.0.3/crates/checksums/src/lib.rs>
- [V1] <https://github.com/versity/versitygw/releases/tag/v1.4.0>, <https://github.com/versity/versitygw/blob/v1.10.0/auth/post_policy.go>
- [V2] <https://github.com/versity/versitygw/blob/v1.10.0/cmd/versitygw/main.go>, <https://github.com/versity/versitygw/blob/v1.10.0/auth/bucket_cors.go>
- [V3] <https://github.com/versity/versitygw/wiki/Multi-Tenant>, <https://github.com/versity/versitygw/wiki/Bucket-Policies>, <https://github.com/versity/versitygw/wiki/IAM-Policies>
- [V4] <https://github.com/versity/versitygw/wiki/Docker>, <https://github.com/versity/versitygw/blob/v1.10.0/chart/values.yaml>
- [V5] <https://github.com/versity/versitygw/wiki/System-Requirements>
- [V6] <https://github.com/versity/versitygw/blob/v1.10.0/README.md>, <https://github.com/versity/versitygw/releases/tag/v1.10.0>, <https://github.com/versity/versitygw/security/advisories>
- [C1] <https://docs.ceph.com/en/latest/radosgw/s3/>, <https://github.com/ceph/ceph/blob/v20.2.4/src/rgw/rgw_cksum.h> (không có ở tag v19.2.x), <https://github.com/ceph/ceph/blob/main/src/rgw/rgw_policy_s3.cc>, <https://github.com/ceph/ceph/blob/main/src/rgw/rgw_rest_s3.cc>
- [C2] <https://docs.ceph.com/en/latest/radosgw/account/>, <https://docs.ceph.com/en/latest/radosgw/bucketpolicy/>
- [C3] <https://docs.ceph.com/en/latest/start/minimum-hardware/>, <https://docs.ceph.com/en/latest/start/hardware-cpu-memory/>
- [C4] <https://github.com/ceph/ceph-container>, <https://raw.githubusercontent.com/rook/rook/master/deploy/examples/cluster-test.yaml>
- [C5] <https://docs.ceph.com/en/latest/releases/>
- [Z1] <https://github.com/scality/cloudserver/pull/5601>
- [Z2] <https://github.com/scality/cloudserver/blob/development/9.6/docs/DOCKER.rst>
- [Z3] <https://github.com/scality/cloudserver/issues/5784>
- [Z4] <https://github.com/scality/cloudserver/releases>
- [B1] <https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/containers/sidecar-requirements.txt>
- [B2] <https://docs.pgbarman.org/release/3.20.1/user_guide/barman_cloud.html>, <https://github.com/EnterpriseDB/barman/blob/release/3.20.1/src/barman/cloud_providers/aws_s3.py>
- [B3] <https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/web/docs/object_stores.md>
- [B4] <https://github.com/velero-io/velero-plugin-for-aws/blob/v1.14.4/backupstoragelocation.md>
- [B5] <https://github.com/velero-io/velero/issues/10543>
- [B6] <https://github.com/cloudnative-pg/plugin-barman-cloud/issues/743>
