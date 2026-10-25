# 0022. Object store của đường local (compose và k3d) đổi từ MinIO (image Chainguard) sang RustFS, CORS theo bucket, tên trung tính `s3`; MinIO Chainguard là đường quay lại

- Trạng thái: Chấp nhận, trừ mục 12 (Velero) kiểm ở phần 3. Hiện thực và kiểm ngày 2026-10-25: mục 1–11 và 13 của kế hoạch kiểm
  đạt trên code cuối (mục Kết quả); mục 12 đạt ở phần 3 của giai đoạn 6b thì bỏ phần "trừ", trượt thì theo "Xem lại khi"
- Ngày: 2026-10-24
- Chỉnh 2026-10-25 (trước lượt hiện thực, không đổi lựa chọn E, không nới hợp đồng nào): tắt console RustFS (Quyết định 7),
  Velero kiểm ở phần 3 và điều kiện trạng thái (Quyết định 8), user thử `svp-objstore-probe`, ca multipart CRC32 kiểm cả dạng
  header lẫn trailer và hai ca chữ ký POST (Quyết định 9, mục 3), từ chối cluster k3d còn MinIO (Quyết định 10), nơi chạy từng
  mục của kế hoạch kiểm, bước chép không bao giờ xoá ở đích; sửa "ba user service" và danh sách file. Nguồn đọc lại ngày
  2026-10-25 ở mục Nguồn.

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
  - **Barman Cloud** (ADR-0020 §5): sidecar plugin v0.15.1 chạy barman 3.20.1 với boto3 1.43.105 [B1], tức có checksum CRC
    mặc định của boto3 ≥ 1.36: dạng trailer `aws-chunked` chỉ khi endpoint là `https`, còn qua `endpointURL` nội bộ `http://` của
    k3d thì gửi trong header [B10]; cần `head_bucket`, `list_objects_v2`, multipart, `delete_objects` (lùi về xoá từng
    key khi store đòi `Content-MD5`) [B2]. **Velero** (diễn tập giai đoạn 6b): plugin AWS v1.14.4 vẫn ép checksum CRC32 cho
    upload multipart trên 5 MiB (dạng trailer qua HTTPS như báo cáo [B5], trong header qua `http://` [B10]),
    `checksumAlgorithm: ""` của BackupStorageLocation [B4] không tắt được [B5].
    Đọc ngày 2026-10-25: [B5] đóng ngày 2026-09-29 khi PR #335 (uploader multipart theo `RequestChecksumCalculation` của client)
    merge vào `main` [B7]; cherry-pick #338 vào `release-1.14` còn mở, chưa merge [B8]; bản phát hành mới nhất vẫn là v1.14.4
    (2026-09-28, trước ngày merge) [B9], nên mọi bản đã phát hành vẫn ép CRC32 cho multipart.
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
| **E. RustFS 1.0.3** | Có, qua thư viện `s3s`: kiểm chữ ký SigV4 POST (cờ `allow_post_signature` mặc định bật ở `s3s` [R2]; RustFS 1.0.3 có tắt không: chưa kiểm được; ngày 2026-10-25 tìm mã nhánh mặc định của RustFS không thấy chỗ nào đặt cờ [R16], vẫn kiểm bằng hai ca chữ ký của mục 3), hạn trước khi đọc file, `eq`, `starts-with`, `content-length-range` [R2]; trước alpha.83 (2026-02) không kiểm điều kiện nào [R3] | **Theo bucket** (`PutBucketCors`, preflight khớp 200, không khớp 403) và danh sách toàn cục `RUSTFS_CORS_ALLOWED_ORIGINS`, mặc định rỗng: không header CORS [R4] | Policy IAM JSON kiểu AWS theo user, `arn:aws:s3:::bucket/prefix/*`, điều kiện `s3:prefix` [R5]; bucket policy ẩn danh tải object "không cho liệt kê ẩn danh" [R6] | **Barman: e2e của chính plugin chạy trên RustFS** từ 2026-09-24 (PR #1109) [R13]; checksum CRC32, CRC32C, CRC64NVME, SHA, lỗi multipart với checksum đã sửa [R14]. Velero: chưa kiểm được | Apache-2.0; 1.0.0 ngày 2026-09-16, 1.0.3 ngày 2026-10-17 [R1]; công ty RustFS, Inc.; **CLA cho công ty quyền phát hành lại dưới giấy phép bất kỳ, kể cả độc quyền** [R10]; **43 advisory, 42 trong 2026** (4 critical, 17 high), nhiều cái về policy, xác thực [R9] | `rustfs/rustfs:1.0.3` amd64 + arm64, có digest; Alpine có `sh`, `curl`; `USER` uid 10001 [R7]; chart chính chủ non-root, read-only, drop ALL nhưng không đặt seccomp [R8]; health `/health/*` và bí danh `/minio/health/*` [R11]; CLI `rc` ở repo riêng, Apache-2.0 [R12]; RAM: chưa kiểm được |
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
   R2) không phải đổi tên nữa. Hai user service (`svp-video-service`, `svp-media-worker`), user `svp-pg-backup`, tên bucket,
   key, `S3_*` của service không đổi.
3. **CORS theo bucket** thay biến toàn cục: job init đặt `PutBucketCors` cho `uploads` (`POST` từ origin web) và `media`
   (`GET`, `HEAD` từ origin web), origin lấy từ biến của job (compose `http://localhost:3001,http://localhost:3002`, k3d
   `https://svp.localhost:8443`); `RUSTFS_CORS_ALLOWED_ORIGINS` để rỗng, nên bucket không có cấu hình thì không có header CORS
   (đóng khi thiếu). WEB-10 chặt hơn hôm nay: preflight `POST` vào `media` hay `GET` ở `uploads` từ origin web cũng bị từ chối.
4. **Init:** viết lại `init.sh` (giữ hợp đồng: idempotent, đặt lại secret key và policy theo `.env`, root chỉ ở store và job
   init, `pg-backups` chỉ khi có `SVP_PG_BACKUP_S3_SECRET_KEY`). Công cụ theo thứ tự: CLI `rc` của RustFS ghim digest nếu nó
   tạo được user với secret key chọn sẵn, policy, bucket policy ẩn danh và CORS; không được thì `curl --aws-sigv4` (có trong
   image RustFS) gọi API admin `/rustfs/admin/v3/add-user`, `add-canned-policy` [R5] và API S3. Không dùng `mc` của repo đã
   archive. Ba file policy và `media-anonymous.json` giữ nguyên nội dung nếu RustFS nhận; sửa gì thì ghi lý do. User thử
   `svp-objstore-probe` và bucket `objstore-probe` theo Quyết định 9 (chỉ khi có `SVP_S3_PROBE_SECRET_KEY`).
5. **Barman Cloud:** `ObjectStore` `svp-pg-backup` chỉ đổi `endpointURL`. Không đặt trước
   `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; chỉ thêm qua `instanceSidecarConfiguration.env` [B3] nếu
   `drill-k8s-backup` trượt vì checksum, kèm lý do.
6. **RAM:** giữ giới hạn 512 MiB ở compose và k3d tới khi có số đo nghỉ và đỉnh (upload ~100 MB, base backup); chỉnh theo số
   đo, ghi vào mục Kết quả.
7. **Console RustFS tắt** ở compose và k3d: `RUSTFS_CONSOLE_ENABLE=false` trong môi trường của container store. Ở 1.0.3 biến này
   là cờ `--console-enable` (mặc định bật, nghe `:9001`), tắt thì không mở listener console, và listener S3 không bao giờ phục vụ
   console [R15]; image đặt sẵn `RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS="*"` cho console [R7]. Lượt hiện thực kiểm lại tên biến ở
   đúng bản ghim. Compose bỏ cổng `127.0.0.1:9001`, k3d không khai cổng 9001 ở pod hay Service; OPS-1 còn **7** cổng loopback
   (mục 8 của kế hoạch kiểm). Lý do: RustFS có lịch sử advisory dày (43 advisory, nhiều cái về xác thực và policy [R9]), console
   là thêm một giao diện đăng nhập bằng root mà không luồng nào của lab cần; ít giao diện là ít mặt tấn công. Xem object thì
   dùng công cụ dòng lệnh của init (Quyết định 4) trong container tạm, không cần mở cổng.
8. **Velero (mục 12) kiểm ở phần 3** của giai đoạn 6b: kịch bản `velero` của [ADR-0021](0021-deferred-verification-stage6b.md)
   §7 (bucket `velero`, user `svp-velero` riêng chỉ bucket đó, Secret `velero/velero-s3`, BAK-2) chạy trên RustFS, không trên
   MinIO. Lý do: kịch bản đó chưa có ở phần 2, dựng riêng để kiểm một đích sắp bỏ là việc thừa; rủi ro chính đã biết (plugin ép
   CRC32 cho multipart > 5 MiB, [B5] mà bản phát hành của plugin chưa sửa; trên runner Velero gọi `s3Url` nội bộ `http://` nên CRC32
   đi trong header, qua HTTPS thì dạng trailer `aws-chunked`) được kiểm sớm ở phần 2 bằng ca multipart của mục 3 ở cả hai dạng
   (Quyết định 9). Ca đó **chỉ giảm rủi ro**, không thay được backup và restore qua BackupStorageLocation: client, cấu hình
   uploader và luồng của Velero khác test. **Điều kiện trạng thái:** mục 1–11 và 13 đạt thì trạng thái là "Chấp nhận, trừ mục 12
   (Velero) kiểm ở phần 3", không "Chấp nhận" trọn; mục 12 đạt ở phần 3 thì bỏ phần "trừ"; mục 12 trượt thì theo "Xem lại khi".
9. **User thử `svp-objstore-probe`** cho ca multipart CRC32 của mục 3: quyền chỉ trên bucket riêng `objstore-probe`
   (ghi, đọc, xoá, `AbortMultipartUpload`, liệt kê phần), không CORS, không gì ẩn danh. Init chỉ tạo user và bucket khi có
   `SVP_S3_PROBE_SECRET_KEY`: compose có (`make env` sinh như secret key S3 khác, `make test-stack` đưa vào test), cluster không
   (`deploy/k8s/secrets.sh` không chuyển biến này). Lý do: không nới policy của user service chỉ để test (thêm multipart hay bucket
   mới cho `svp-video-service`, `svp-media-worker` là mở rộng UP-4), và rủi ro CRC32 thuộc store, không phụ thuộc bucket nào. Mục 3
   cũng thêm hai ca chữ ký POST, vì RustFS có giữ kiểm chữ ký của `s3s` hay không vẫn chưa kiểm được trong mã (bảng, phương án E):
   policy bị sửa sau khi ký (nới `content-length-range`) bị từ chối; form không có trường chữ ký bị từ chối.
   Ca multipart gọi thẳng `CreateMultipartUpload`, `UploadPart`, `CompleteMultipartUpload` (hai phần: 5 MiB và 1 MiB) với
   `ChecksumAlgorithm` CRC32, như uploader của plugin Velero làm [B5]; client của ca để `RequestChecksumCalculation` mặc định,
   client của service đặt `WhenRequired` (`internal/objstore/objstore.go`) nên không thay được ca này; không thêm module
   `feature/s3/manager`. Kích thước và mặc định SDK **không** đủ để có trailer: `aws-sdk-go-v2` ghim chỉ gửi CRC32 dạng trailer
   `aws-chunked` khi URL của request là `https`, qua `http://` thì tính trước và gửi trong header `x-amz-checksum-crc32` [B10], mà
   `make test-stack` đặt `SVP_TEST_S3_ENDPOINT=http://127.0.0.1:9000`. Nên ca chạy hai lượt, mỗi lượt kiểm dạng mà request thực
   sự mang:
   - **(a) header:** thẳng vào endpoint `http://`, đúng dạng Velero (`s3Url` nội bộ trên runner) và Barman (`endpointURL` nội
     bộ) gửi trong cluster; đạt khi mọi `UploadPart` có header `x-amz-checksum-crc32` và không có `Content-Encoding: aws-chunked`.
   - **(b) trailer:** qua proxy TLS do chính test mở trên `127.0.0.1` (`httptest`, chứng chỉ tự ký chỉ client của test tin),
     chuyển tiếp tới endpoint đó và giữ nguyên header `Host` để chữ ký SigV4 vẫn khớp, đúng dạng của báo cáo [B5]; đạt khi mọi
     `UploadPart` có `Content-Encoding: aws-chunked`, `x-amz-trailer: x-amz-checksum-crc32`,
     `x-amz-content-sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER` và không có header `x-amz-checksum-crc32`.
   - **Cả hai lượt:** header được ghi bởi một `RoundTripper` bọc HTTP client của ca, tức đúng cái gửi đi; store nhận mọi request,
     object đọc lại đúng từng byte (store không giải `aws-chunked` thì byte khung chunk lọt vào object), upload dở bị
     `AbortMultipartUpload`. Request không mang đúng dạng của lượt thì ca **FAIL**, không PASS hay SKIP: ca không chứng minh được
     dạng nó kiểm thì không giảm được rủi ro nào.
10. **k3d không nâng tại chỗ:** `make k8s-up` từ chối cluster còn StatefulSet `minio` ở `svp-data` (tạo trước khi đổi) và in lệnh
    dựng lại cluster (`make k8s-down`, `make k8s-up`). Lý do: nâng tại chỗ để lại PVC của MinIO, đưa `ObjectStore` của Barman sang
    store rỗng giữa lúc WAL đang lưu, nửa cũ nửa mới; mục Cách chuyển đã chọn cluster mới, từ chối biến lựa chọn đó thành kiểm
    soát thay vì lời dặn. Đường GitOps luôn tạo cluster mới nên không bị chạm.

## Kế hoạch kiểm (viết trước, chạy ở lượt hiện thực)

Thứ tự là thứ tự chạy ở mỗi nơi; một dòng trượt thì dừng, sửa hay quay lại A, không chạy tiếp để "xem cho biết". Mục 13 dùng
target `object-store-copy` mà lượt hiện thực thêm (chưa có trong `make help` hôm nay); mọi target khác đã có.

**Nơi chạy** (chỉnh 2026-10-25): máy 16 GB chỉ chạy một lượt `make up` + `make smoke`, phần còn lại chạy bằng đúng target `make`
trên runner của giai đoạn 6b ([ADR-0021](0021-deferred-verification-stage6b.md)) hay job `stack` của `ci.yml`. Lý do: compose đủ
profile, e2e hai trình duyệt, đo RAM và k3d không vừa máy cùng lúc với việc khác; runner chạy cùng lệnh nên kết quả vẫn là của repo.

- **Máy:** bước chép chiều đi trên dữ liệu thật (mục Cách chuyển), mục 1, `make up` lần 1 (mục 2, init trên volume vừa chép), mục 3,
  4, 6.
- **Runner `compose-obs` của `verify.yml`:** `make up` lần 2 (mục 2: chạy lại init trên volume đã init), mục 3, 7, 8, 9 và mục 13
  (chiều ngược trên volume của runner, rồi `make up`, `make smoke` trên RustFS).
- **Job `stack` của `ci.yml`** trên PR: mục 4, 5, 6 (e2e). Job này chỉ báo, ngoài `ci-ok`, nên lượt hiện thực đọc kết quả của nó
  trên PR; xanh mới tính là đạt.
- **Runner `dev-k3d`:** mục 10, 11. **Phần 3, kịch bản `velero`:** mục 12 (Quyết định 8).
- Volume `svp_minio-data` của máy chỉ xoá khi mục 1–11 và 13 đã qua, do người học chạy.

| # | Kiểm gì | Nơi chạy | Lệnh | Đạt khi |
| --- | --- | --- | --- | --- |
| 1 | File hợp lệ, test đơn vị không đổi | Máy; job `check`, `config` của `ci.yml` | `make compose-config`, `make helm-check`, `make check` | Sạch; `make check` xanh (không sửa hay bỏ test có sẵn; chỉ thêm ca của mục 3, 6) |
| 2 | Bucket, user, policy, CORS tạo được, chạy lại không đổi gì | Máy (lần 1), `compose-obs` (lần 2) | `make up` hai lần | Job init thành công cả hai lần; log init không in secret |
| 3 | UP-1, UP-4, chữ ký POST, multipart CRC32 trên store thật | Máy, `compose-obs` | `make test-stack PKGS=./internal/objstore/...` | `TestIntegrationPresignedPost` (form đúng; đổi key sang upload khác, sang `media`; quá 1 byte; rỗng; sai và thiếu `Content-Type`; hết hạn; URL endpoint công khai; **policy sửa sau khi ký**, nới `content-length-range`; **form không có trường chữ ký**), `TestIntegrationWorkerPermissions`, `TestIntegrationVideoServicePermissions`, `TestIntegrationDeletePrefix`, và ca mới multipart > 5 MiB có CRC32 bằng user `svp-objstore-probe`, hai lượt: header qua `http://` và trailer `aws-chunked` qua proxy TLS của test, mỗi lượt kiểm header của request đúng dạng (Quyết định 9; đọc lại đúng nội dung, upload dở bị `AbortMultipartUpload`) đều PASS, không SKIP |
| 4 | Luồng đầu-cuối, UP-5, UP-6 | Máy, job `stack` | `make smoke` | Xanh: upload tới `READY`, phát HLS, thumbnail; đọc ẩn danh `uploads` bị từ chối; liệt kê ẩn danh `media` bị từ chối |
| 5 | Upload từ trình duyệt qua CORS | Job `stack` | `make web-e2e` | Xanh ở Chromium và WebKit, gồm project `*-publishing` |
| 6 | WEB-10 compose | Máy (chỉ test WEB-10), job `stack` | Test WEB-10 có sẵn của `web/e2e/security.e2e.ts` (chạy trong `make web-e2e`) thêm hai ca mới; cùng hai ca vào WEB-10 của `deploy/k8s/drills/threats.sh` (chạy ở mục 10); không curl tay | `Origin: http://evil.example` → không `Access-Control-Allow-Origin` ở `/uploads` (`POST`) và `/media/...` (`GET`); `http://localhost:3001` → đúng origin; hai ca mới: `POST` vào `/media` và `GET` ở `/uploads` từ `http://localhost:3001` → không header |
| 7 | Dọn upload bỏ dở | `compose-obs` | `make drill-upload-cleanup` | PASS; script tra object bằng công cụ mới, không còn `mc stat` |
| 8 | Telemetry không lộ form, cổng loopback | `compose-obs` | `make up OBS=lgtm`, `make drill-obs-threats` | PASS; OPS-1 đúng **7** cổng loopback (tên service mới, không còn 9001: Quyết định 7); log khởi động của `s3` ghi console tắt |
| 9 | RAM compose | `compose-obs` | `docker stats` của container `s3` lúc nghỉ và trong `make measure-upload` | Đỉnh < 512 MiB, ghi số |
| 10 | k3d: luồng, policy, BAK-1, WEB-10 | `dev-k3d` | `make k8s-up`, `make k8s-smoke`, `make drill-k8s-threats` | `k8s-smoke` xanh; `drill-k8s-threats` toàn PASS, gồm WEB-10 (origin `https://svp.localhost:8443`, cả hai ca mới của mục 6), BAK-1 (`svp-pg-backup` chỉ `pg-backups`, user service không tới bucket đó; mã lỗi của RustFS khớp lại nếu khác `AccessDenied`/`NoSuchKey`), OPS-2, IN-2/FF-5 với tên `s3` |
| 11 | Backup và phục hồi | `dev-k3d` | `make drill-k8s-backup`, `make drill-k8s-backup MODE=pitr` | WAL lưu liên tục không lỗi sau khi job init xong; cả hai chế độ phục hồi và `k8s-smoke` qua; RTO, RPO ghi lại, so với lượt MinIO của ADR-0020 (lệch nhiều thì ghi lý do) |
| 12 | Velero, BAK-2 | Phần 3, kịch bản `velero` | Theo ADR-0021 §7 | BackupStorageLocation `Available` trên RustFS; backup có file trên 5 MiB (multipart CRC32 [B5], trong header vì `s3Url` nội bộ là `http://`) và restore qua; D13 của ADR-0021 đạt; user `svp-velero` chỉ tới bucket `velero`, user service không tới bucket đó |
| 13 | Đường quay lại chạy thử | `compose-obs` | Sau mục 4 của lượt runner: dừng ghi như quy tắc 1 của Cách chuyển, `make object-store-copy TO=minio` (đích là volume `minio-data` mới của runner), rồi `make up`, `make smoke` | Kiểm của bước chép đạt, gồm các video `READY` tạo trên RustFS ở lượt đó; không revert; stack chạy lại trên RustFS và `make smoke` xanh |

## Cách chuyển

- **Một thay đổi, một lần:** compose, k3d, policy, script, tài liệu cùng một PR; không có giai đoạn chạy song song hai store
  trong repo.
- **Dữ liệu phải giữ ở compose:** Postgres native (`svp_video`) không đổi khi đổi store, nên mọi key mà một dòng `videos` trỏ
  tới phải có trên store đang chạy. Đó là `media/<id>/…` (playlist, segment, thumbnail) của video `READY` **và** `uploads/<id>`
  của video `READY` lẫn `PROCESSING` (và `UPLOADING` đã gửi file): video-service không xoá file gốc khi video thành `READY`, chỉ xoá cả hai phía khi video
  `FAILED` (`transcode.failed`, hay job dọn với video `UPLOADING` quá hạn). Bỏ `uploads` là mất bản gốc duy nhất của video đã
  phát; video `PROCESSING` thiếu file gốc thì media-worker phát `transcode.failed` lý do `SOURCE_MISSING`, video thành `FAILED`
  và video-service xoá phần còn lại của nó.
- **Bốn quy tắc, cả hai chiều (đi và quay lại):**
  1. **Dừng ghi trước khi chép:** không upload trong buổi chuyển; chờ tới khi không còn video `PROCESSING`
     (`SELECT status, count(*) FROM videos GROUP BY status` trên `svp_video`, chỉ đọc), rồi `make down` (giữ volume), nên
     không service nào ghi vào store nào trong lúc chép. Còn dòng `PROCESSING` thì bước chép từ chối (video đang được ghi).
     Video `UPLOADING` không cần chờ: object đã có thì được chép; form gửi sau đó mà store mới không nhận thì job dọn chuyển video
     sang `FAILED` như upload bỏ dở.
  2. **Không bao giờ xoá ở đích, từ chối mọi key chỉ có ở đích** (chỉnh 2026-10-25): chép **mọi object của `uploads` và
     `media`**, giữ key và `Content-Type` (playlist, segment, thumbnail, file gốc), chỉ thêm key còn thiếu ở đích; không xoá, không
     ghi đè. Trước mọi ghi, liệt kê hai phía của `uploads` và `media`: đích có key mà nguồn không có, hay cùng key mà kích thước
     khác → **từ chối, không ghi gì**, in số key và tối đa vài key mẫu (key chỉ gồm UUID và tên file). Lý do: làm đích giống hệt
     nguồn (`mc mirror --remove`) xoá mọi key thừa ở đích, kể cả segment, rendition playlist hay `uploads/<id>` của video
     `UPLOADING` chỉ có ở đích (dữ liệu tạo sau lần chép trước, hay sau khi đã chạy trên store đích); chỉ kiểm key mà `svp_video`
     ghi (`playlist_key`, `thumbnail_key`) là không đủ vì segment và rendition playlist không nằm trong database. Xoá ở đích chỉ
     bằng quyết định rõ ràng của người học, ngoài script.
  3. **Kiểm xong mới đổi endpoint.** **Tập key cần giữ** của mỗi dòng `READY` trong `svp_video` (chỉ `SELECT`): `playlist_key`,
     `thumbnail_key`, mọi rendition playlist và segment mà các playlist đó (đọc ở phía có) trỏ tới. Thiếu ở nguồn mà có ở đích đã
     bị chặn ở quy tắc 2; thiếu cả hai phía → liệt kê "đã mất từ trước" (ví dụ sau `make clean-data`, xoá volume mà không đụng
     Postgres native), không chặn. `uploads/<id>` của mọi trạng thái, kể cả `UPLOADING`, được giữ bằng chính luật chỉ-có-ở-đích.
     Sau chép: mọi key của nguồn có ở đích cùng kích thước và `Content-Type`; đích không có key nào ngoài nguồn. Kiểm trượt thì
     không đổi endpoint: stack chạy lại trên store cũ.
  4. **Store cũ chỉ xoá khi đường chép ngược đã chạy thử** (mục 13 của kế hoạch kiểm) và mục 1–11 đã qua (mục 12 ở phần 3, không
     chờ); người học chạy lệnh xoá.
- **Bước chép** là target mới `make object-store-copy TO=s3|minio` (script `deploy/compose/object-store-copy.sh`): từ chối khi
  stack compose hay cluster k3d đang chạy (quy tắc 1, máy 16 GB); dựng tạm hai store trên một network nội bộ, không publish cổng:
  MinIO bằng image A ghim digest trên volume `minio-data`, RustFS trên volume `s3-data`; tạo bucket đích nếu chưa có (user, policy,
  bucket policy, CORS do init của stack đích đặt ở `make up` sau đó); kiểm trước khi ghi của quy tắc 1–2; chép bằng `mc mirror`
  **không** `--remove`, **không** `--overwrite` [M11] của chính image A, vì image A đã phải chạy để đọc volume MinIO nên `mc` của
  nó không thêm phụ thuộc mới (init lâu dài vẫn không dùng `mc`); chạy kiểm của quy tắc 3; xong thì gỡ hai container tạm, không xoá
  volume nào. MinIO tạm chạy với mật khẩu root ngẫu nhiên mỗi lượt: MinIO giữ bucket và object khi khởi động với root khác (đã
  kiểm trên image ghim, ghi ở `deploy/k8s/secrets.sh`), nên bước chép không cần biến `.env` cũ của MinIO. Script và digest A ở lại
  trong repo chừng nào RustFS còn chạy: đó là đường quay lại. Quay lại muộn (theo "Xem lại khi") thì cập nhật digest A sang bản
  Chainguard mới nhất trước khi chép.
- **Compose, chiều đi:** trên `main` (MinIO) dừng ghi theo quy tắc 1; sang nhánh của PR, `make object-store-copy TO=s3` trên máy;
  qua kiểm thì chạy các mục của máy trong kế hoạch kiểm (mục 1, `make up` lần 1 của mục 2, mục 3, 4, 6), các mục còn lại ở nơi chạy
  của chúng. Volume cũ (`env -u DOCKER_DEFAULT_PLATFORM docker volume rm svp_minio-data`) chỉ xoá khi mục 1–11 và 13 đã qua, do
  người học chạy.
- **k3d:** cluster mới (`make k8s-down`, `make k8s-up`; `make k8s-up` từ chối cluster cũ còn MinIO, Quyết định 10): Postgres trong
  cluster cũng mới nên không có gì để chép và không có dòng nào trỏ vào object cũ; `install.sh` tự chụp backup cơ sở cho thế hệ
  đang chạy. Lịch sử backup trên MinIO cũ mất cùng cluster (chấp nhận: lab, chưa có dữ liệu cần giữ).
- **Quay lại A** (trong buổi chuyển, hay sau này theo "Xem lại khi"); revert PR một mình không đủ, vì video tạo trên RustFS
  (`make smoke`, `make web-e2e`, dùng thật) có dòng trong `svp_video` mà object chỉ nằm ở `s3-data`:
  1. trên bản RustFS, dừng ghi theo quy tắc 1;
  2. `make object-store-copy TO=minio`: volume `minio-data` đã xoá thì đích rỗng; còn thì đích thường có key mà RustFS đã xoá
     sau lần chép đi (ví dụ khi dọn video `FAILED`), nên bước chép từ chối theo quy tắc 2 và người học quyết định xoá các key đó ở
     đích hay chép vào volume rỗng; kiểm trượt thì dừng, vẫn chạy RustFS;
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
  cổng: 7, không còn 9001), `deploy/observability/glitchtip/dotenv-test.sh`, `.env.example` (`SVP_MINIO_ROOT_PASSWORD` →
  `SVP_S3_ROOT_PASSWORD`, thêm `SVP_S3_PROBE_SECRET_KEY`; thêm ngày 2026-10-25: file có nhắc MinIO mà danh sách đầu bỏ sót).
- **Runner** (nơi chạy của kế hoạch kiểm): `deploy/ci/verify-run.sh` và chú thích của `.github/workflows/verify.yml` (bước mới
  của `compose-obs`: `make up` lần 2, `make test-stack PKGS=./internal/objstore/...`, `make drill-upload-cleanup`, RAM trong
  `make measure-upload`, mục 13).
- **k3d:** `deploy/helm/svp-data/templates/minio.yaml` → `s3.yaml`, `deploy/helm/svp-data/values.yaml`, `deploy/helm/svp-data/templates/networkpolicies.yaml`,
  `deploy/helm/svp-data/templates/backup.yaml` (`endpointURL`), `deploy/helm/svp-data/files/minio` (symlink) → `files/s3`,
  `deploy/helm/svp-data/Chart.yaml`, `deploy/helm/svp-cluster/templates/namespaces.yaml`, `deploy/helm/svp-service/values.yaml`
  (đích egress `minio`), `deploy/k8s/values/services/{video-service,media-worker,gateway,web}.yaml`, `deploy/k8s/secrets.sh`
  (Secret, phát hiện mật khẩu root lệch và restart: hành vi của RustFS khi root đổi phải kiểm lại), `deploy/k8s/install.sh`,
  `deploy/k8s/gitops.sh`, `deploy/k8s/k8s.mk` (thêm từ chối cluster còn StatefulSet `minio`), `deploy/k8s/drills/threats.sh`
  (34 chỗ: tên host, `/minio/health/live`, BAK-1, WEB-10 thêm hai ca), `deploy/k8s/drills/backup.sh`, `deploy/k8s/values/plugin-barman-cloud.yaml` (chú thích).
- **Test thêm ca** (mục 3, 6): `internal/objstore/integration_test.go` (hai ca chữ ký POST, ca multipart CRC32 bằng
  `svp-objstore-probe`, hai lượt header và trailer), `web/e2e/security.e2e.ts` (hai ca WEB-10).
- **Code và test (chỉ chú thích, chuỗi ví dụ):** `internal/objstore/objstore.go`, `objstore_test.go`, `integration_test.go`,
  `services/video-service/cmd/video-service/main.go`, `services/media-worker/cmd/media-worker/main.go` (và hai `main_test.go`),
  `proto/svp/video/v1/video_service.proto` (chú thích; `buf breaking` không đổi), `web/server/env.ts`, `web/server/csp.ts`,
  `web/server/env.test.ts`, `web/e2e/{fixtures,measure-upload.e2e,security.e2e,stack}.ts`, `web/e2e/seed.sh`, `renovate.json`.
- **Tài liệu:** `CLAUDE.md`, `AGENTS.md`, `docs/architecture.md`, `docs/threat-model.md` (UP-5, WEB-10, BAK-1, BAK-2, OPS-1 7 cổng),
  `docs/runbooks/*` có nhắc MinIO (9 file), `docs/adr/README.md` (dòng 0022; ADR-0008 ghi "§6 chỉnh bởi 0022").

Rủi ro: `threats.sh` và `secrets.sh` dựa vào hành vi riêng của MinIO (mã lỗi, đọc mật khẩu root lúc khởi động); `init.sh`
viết lại là chỗ dễ nới quyền nhầm nhất, nên mục 3, 4, 10 của kế hoạch kiểm là cổng của nó. Cụm tên `minio` → `s3` rộng nhưng
cơ học; sót một chỗ thì NetworkPolicy hay `S3_ENDPOINT` trỏ vào tên không có và `k8s-smoke` đỏ ngay. Bước chép là chỗ duy nhất
có thể mất dữ liệu: nó không xoá object hay volume nào ở cả hai phía, từ chối trước khi ghi khi đích có key ngoài nguồn hay khác
kích thước (quy tắc 2), và endpoint chỉ đổi sau khi kiểm của nó đạt.

## Kết quả

Chạy ngày 2026-10-25 trên nhánh `feat/stage6b-objstore` (PR #24), store `rustfs/rustfs:1.0.3` ghim digest. Code của store (compose,
chart, `deploy/s3/`, script chép, test) giống nhau ở `50f1cfe`, `f63c484` và `a1741ff`: sau `50f1cfe` chỉ script kiểm của
`compose-obs` (`deploy/ci/verify-*.sh`, chú thích của `verify.yml`) đổi, nên lượt `dev-k3d` trên `50f1cfe`, lượt `compose-obs` và
CI trên `f63c484` là của code store cuối. `a1741ff` sửa hai phép đo của chính `compose-obs` (đếm restart cả của container đã gỡ hay
dựng lại; so RAM với ngưỡng trước khi làm tròn); lượt `compose-obs` trên `a1741ff` ([40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062))
chạy lại mọi bước với hai phép đo đó, và CI của `a1741ff` ([40207239730](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207239730)) xanh cả job `stack`.
Trong cả hai lượt `compose-obs` chỉ `web-lighthouse` ×3 và `lcp` đỏ: LCP của web, việc đã biết ở D17 của
[ADR-0021](0021-deferred-verification-stage6b.md), không thuộc kế hoạch kiểm này.

| # | Kết quả | Nguồn |
| --- | --- | --- |
| 1 | Đạt | CI của PR #24 ([40203127200](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203127200), `f63c484`): job `check` (`make check-go`), `config` (`make compose-config`, `make helm-check`, `deploy/k8s/check-image-digests.sh`, …), `web`, `generate`, `buf` xanh, `ci-ok` xanh; cùng các job xanh ở `a1741ff` ([40207239730](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207239730)). Trên máy: `make compose-config` sạch cho bốn cấu hình, `make helm-check` exit 0, `check-image-digests.sh` "40 pinned by digest, exceptions 0", `make trivy-config` 0 kết quả, `make renovate-check` sạch. Hai ca có sẵn của mục 3 đổi cách kiểm, có lý do (dưới bảng) |
| 2 | Đạt | Máy (lần 1, trên volume vừa chép): `make up` exit 0, `s3-init` exit 0 với 5 dòng `ok`. Runner `compose-obs` [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) và [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062): bước `up` trên volume mới (344 s, 318 s), rồi `make up` lần hai trên store đã init trong `object-store-roundtrip`, mọi lần `s3-init` thành công. Log `s3-init` và `s3`: 0 lần xuất hiện của mọi giá trị bí mật của `.env` (máy: dò 7 giá trị; runner: dò cả danh sách của `verify-mask.sh`) |
| 3 | Đạt | `make test-stack PKGS=./internal/objstore/...` trên máy và ở bước `test-stack-objstore` của [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) và [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062): mỗi lần 39 PASS, 0 FAIL, **0 SKIP**; đủ `TestIntegrationPresignedPost` (13 ca, gồm policy sửa sau khi ký và form không chữ ký), `TestIntegrationWorkerPermissions`, `TestIntegrationVideoServicePermissions`, `TestIntegrationDeletePrefix`, `TestIntegrationMultipartChecksum` (user thử không ghi được `uploads`, `media`; CRC32 dạng header qua `http://`, dạng trailer `aws-chunked` qua proxy TLS của test, đọc lại đúng từng byte) |
| 4 | Đạt | `make smoke` trên máy (58 bước), ở job `stack` của [40203127200](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203127200) và lại sau đường quay lại của [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781): upload tới `READY`, HLS và thumbnail ẩn danh 200, đọc ẩn danh `uploads` 403, liệt kê ẩn danh `media` 403, `EntityTooLarge` 400 |
| 5 | Đạt | Job `stack` của [40203127200](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203127200): `make web-e2e` 64/64 (chromium 29/29, webkit 29/29, chromium-publishing 3/3, webkit-publishing 3/3) |
| 6 | Đạt | Test WEB-10 của `web/e2e/security.e2e.ts` (sáu preflight, gồm hai ca mới) xanh trên Chromium và WebKit ở job `stack` trên; trên máy cùng sáu ca bằng `curl -si -X OPTIONS` (thêm vào e2e, không thay): origin lạ không header, `http://localhost:3001` và `:3002` đúng origin, `POST /media` và `GET /uploads/…` từ origin web không header, bucket `objstore-probe` không header |
| 7 | Đạt | `make drill-upload-cleanup` của [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) (31 s; [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062) cũng PASS, 31 s): video bỏ dở `FAILED` sau 22 s, object `uploads/<id>` bị xoá, video đã hoàn tất không bị đụng; script tra object bằng `curl --aws-sigv4`, không còn `mc stat` |
| 8 | Đạt, một phần đổi cách kiểm | `make drill-obs-threats` của [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) (169 s; [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062) PASS, 186 s): JWT-8, UP-8, RL-2, WEB-9 PASS; OPS-1 đúng 7 cổng loopback (alertmanager, gateway, glitchtip, lgtm, redpanda, `s3` `127.0.0.1:9000`, web), không 9001. "Log khởi động ghi console tắt" không kiểm được: RustFS 1.0.3 ở mức log mặc định không in dòng đó; console tắt kiểm bằng cổng: không listener 9001 trong container (`/proc/net/tcp`, trên máy) và OPS-1 |
| 9 | Đạt | [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781), `docker stats` của `svp-s3-1` mỗi 10 s (`samples/compose.tsv`, mốc bước theo `results.tsv`). `compose-obs` không có bước nghỉ riêng: mẫu không tải duy nhất là 198 MiB cuối bước `up` (`s3-init` đã xong, video-service đã chạy), trước `smoke`; mọi mẫu trước `measure-upload` (cuối `up`, rồi `smoke`, `drill-obs-threats`, `load-local` k6 5 phút, Lighthouse ×3, `test-stack`, `drill-upload-cleanup`: có tải, không phải lúc nghỉ; 91 mẫu) median 247 MiB, cao nhất 282 MiB; trong `measure-upload` (102,5 MB từ Chromium, XHR 799 ms, tới `READY` 189 s) đỉnh **338 MiB** (34 mẫu, mẫu cuối của bước); cao nhất cả lượt 356 MiB, từ mẫu 8 s sau khi `measure-upload` xong (bước `drill-alert-to-sentry`, giữ khoảng 1 phút); dưới 512 MiB. Với phép so mới (không làm tròn), [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062): cuối `up` 190,7 MiB; trước `measure-upload` (90 mẫu, cùng các bước) median 243,2 MiB, cao nhất 286,7 MiB; đỉnh trong `measure-upload` (XHR 361 ms, tới `READY` 197 s) **325,1 MiB** (35 mẫu, mẫu cuối của bước); cao nhất cả lượt 340,8 MiB, từ mẫu 9 s sau khi `measure-upload` xong. Hai đỉnh này tính lại bằng chính `deploy/ci/verify-sample.sh s3-peak` với mốc của `results.tsv` trên `samples/compose.tsv` đủ của artifact: `ram-s3-upload.json` của cả hai lượt thiếu mẫu cuối (322 MiB / 33 mẫu, 305,1 MiB / 34 mẫu) vì bước `ram-s3-upload` đọc file mẫu ngay khi `measure-upload` xong, lúc sampler nền chưa ghi mẫu lấy 1–2 s trước đó; lỗi của script, sửa ở phần 3. Số nghỉ của compose đo trên máy (bảng dưới) |
| 10 | Đạt | `dev-k3d` [40202083397](https://github.com/anhnvcoder/short-video-platform/actions/runs/40202083397), job 121195191303 (`50f1cfe`, 14/14 bước `ok`): `make k8s-up` 1 105 s, `s3-init` Completed, `s3-0` 0 restart; `make k8s-smoke` qua; `make drill-k8s-threats` 16/16 mục PASS, 0 FAIL, SKIP, WARN: WEB-10 (origin lạ và `localhost` không header, `https://svp.localhost:8443` đúng origin, hai ca mới không header), BAK-1 (`svp-pg-backup` liệt kê `pg-backups`, 403 `AccessDenied` ở `uploads`, `media`; user service 403 ở `pg-backups`: mã lỗi của RustFS trùng MinIO), OPS-2 route `svp-data/s3`, IN-2, FF-5, WEB-13 với `s3.svp-data:9000` |
| 11 | Đạt | Cùng lượt: WAL lưu liên tục, backup cơ sở sau `s3-init`; `latest` RTO 89,7 s, RPO ≥ 63,4 s (0/60 dòng đánh dấu còn); `pitr` RTO 89,6 s, RPO 37,1 s (30/60, dòng mới nhất 0,5 s trước mục tiêu); 0/17 bảng lệch, `k8s-smoke` sau phục hồi qua, "Backups and bucket untouched". So lượt MinIO trên runner ([ADR-0021](0021-deferred-verification-stage6b.md) Kết quả, lượt 4, 5): `latest` 95,2/92,8 s, RPO ≥ 63,2/63,4 s; `pitr` 80,8/84,3 s, RPO 38,1/36,1 s: trong cùng khoảng. Không lỗi checksum nào, nên không đặt `AWS_REQUEST_CHECKSUM_CALCULATION` (Quyết định 5) |
| 12 | Chưa chạy (phần 3, Quyết định 8) | — |
| 13 | Đạt | Bước `object-store-roundtrip` của [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) (54 s): không video `PROCESSING`, `make down`, `make object-store-copy TO=minio` vào volume `svp_minio-data` mới của runner: 22 video `READY` tạo trên RustFS ở lượt đó, `uploads` 22 và `media` 219 object, `keys lost before this copy: 0`, "MinIO holds every object of RustFS with the same key, size and Content-Type, and nothing else"; rồi `make up OBS=lgtm`, `make smoke` trên RustFS xanh; không revert. [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062) (56 s): cùng kết quả với 22 video `READY`, 22 + 219 object, 0 key mất, mẫu restart lấy ngay trước `make down`, `compose_no_restart=true` theo cách đếm mới |

**RAM của store** so với giới hạn 512 MiB (Quyết định 6):

| Nơi | Nghỉ | Có tải | Nguồn |
| --- | --- | --- | --- |
| Compose, máy | 126,2 MiB sau `make up`, trước mọi request; 189,1 MiB sau khi `test-stack` và `smoke` xong | Không đo (đo ở runner) | `docker stats`, 2026-10-25 |
| Compose, runner | Không có bước nghỉ riêng; mẫu không tải duy nhất: 198 / 190,7 MiB cuối bước `up`, trước `smoke` | Trước `measure-upload` (`smoke`, diễn tập, `load-local` k6, Lighthouse, `test-stack`; 91 / 90 mẫu gồm cả mẫu cuối `up`): median 247 / 243,2 MiB, cao nhất 282 / 286,7 MiB; đỉnh 338 / 325,1 MiB trong `measure-upload` (tính lại từ `samples/compose.tsv`: JSON thiếu mẫu cuối, xem mục 9); 356 / 340,8 MiB cả lượt, ngay sau `measure-upload` | [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) / [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062), `samples/compose.tsv` với mốc bước của `results.tsv` (đỉnh trong `measure-upload` bằng `verify-sample.sh s3-peak`), `runner.json` (cả lượt) |
| k3d, runner | 112–113 MiB lúc nghỉ đầu; 278–282 MiB lúc nghỉ cuối (sau các diễn tập) | 286 MiB trong `drill-k8s-backup MODE=pitr`; ≤ 219 MiB trong e2e, ≤ 270 MiB trong KEDA | [40202083397](https://github.com/anhnvcoder/short-video-platform/actions/runs/40202083397) `samples/pods.tsv` (`kubectl top`, working set, mỗi 30 s: đỉnh ngắn giữa hai mẫu không thấy) |

Giới hạn giữ 512 MiB ở cả hai nơi: số cao nhất đo được (356 MiB) là 70% giới hạn, còn hơn 150 MiB; hạ giới hạn chỉ vì vài lượt đo là
bỏ khoảng dự phòng cho upload lớn hơn. Trên k3d store giữ ~280 MiB ở điểm nghỉ cuối (sau tải; cache), không trả về mức nghỉ đầu.

**Bước chép chiều đi trên máy** (2026-10-25, quy tắc 1: `svp_video` có `READY` 505, `FAILED` 393, `UPLOADING` 35, không
`PROCESSING`): `make object-store-copy TO=s3` exit 0 (20 s): `uploads` 58 object / 586 687 715 byte, `media` 922 object /
923 504 665 byte ở RustFS, "RustFS holds every object of MinIO with the same key, size and Content-Type, and nothing else". "Đã
mất từ trước": 894 key, playlist và thumbnail của 447/505 video `READY` mà object đã mất từ một lần `make clean-data` trước đó
(volume xoá, Postgres native còn dòng); chúng 404 như trước khi chuyển. Một video cũ chép từ MinIO phát được trên RustFS (playlist,
rendition, segment, thumbnail 200, `Content-Type` đúng); file gốc ở `uploads` vẫn 403 ẩn danh. Test của script
(`deploy/compose/object-store-copy-test.sh`, volume và database thử riêng) 22 ca ok ở hai lượt liền. Volume `svp_minio-data` của
máy còn nguyên; điều kiện xoá của quy tắc 4 (mục 13 đã chạy, mục 1–11 đạt) đã đủ, người học quyết lúc chạy
`env -u DOCKER_DEFAULT_PLATFORM docker volume rm svp_minio-data`; script chép và digest A ở lại trong repo dù volume còn hay mất.

**Khác với lúc viết** (không nới hợp đồng nào; mỗi điểm có lý do):

- **Hai ca có sẵn của mục 3 đổi cách kiểm**, ngoại lệ có chủ đích của "không sửa hay bỏ test có sẵn" (mục 1):
  `TestIntegrationPresignedPost/key_changed_to_another_upload` và `/key_changed_to_media` đòi đúng 403; RustFS 1.0.3 từ chối form đã ký
  bị đổi key hay bucket bằng 400 `InvalidPolicyDocument` ("Policy condition 'eq' for field 'key' failed…"), MinIO và AWS S3 trả 403.
  Hai ca giờ đòi một mã 4xx (ghi mã thật vào log test) **và** giữ nguyên kiểm không object nào được ghi (`assertAbsent`, liệt kê
  `media`): kiểm hành vi, không kiểm mã riêng của một nhà cung cấp. Đã kiểm web không bị ảnh hưởng: `web/features/upload/upload-store.ts`
  coi 403 là form hết hạn (xin form mới một lần), mà RustFS trả 403 `AccessDenied` "Request has expired" cho form hết hạn như MinIO;
  400 chỉ gặp khi form bị sửa, web không sửa form. Bốn ca mới của mục 3 đòi 4xx ngay từ đầu.
- **Init dùng `curl --aws-sigv4`, không `rc`** (Quyết định 4): `rc` (`rustfs/rc:v0.1.36`) có lệnh user, policy, CORS, nhưng
  `rc admin user add` nhận secret key trên dòng lệnh, process khác trong container đọc được, và thêm một image phải ghim; `curl` có
  sẵn trong image RustFS. Root đi qua stdin (`-K -`), secret của user qua file tạm mode 600. API admin `/rustfs/admin/v3/add-user`
  nhận JSON thường, và user mới mặc định bị tắt nên init đặt `"status":"enabled"`.
- Bốn file JSON giữ nguyên nội dung; thêm `deploy/s3/objstore-probe-policy.json` của user thử (Quyết định 9). Secret key giữ 40 hex
  (RustFS chỉ đòi ≥ 8) để cùng `.env` dùng được cho đường quay lại MinIO.
- `RUSTFS_CHECK_UPDATE=false`: RustFS mặc định gọi ra ngoài để kiểm bản mới lúc khởi động; lab không gửi gì ra ngoài. Log ra stdout,
  không ghi file dưới root chỉ đọc. k3d thêm `startupProbe` (2 s × 60) vì chart chính chủ của RustFS hoãn liveness 30 s; root chỉ
  đọc không cần `emptyDir` (compose qua upload 100 MB và multipart, pod `s3-0` chạy suốt lượt `dev-k3d` không restart).
- **Đọc `media` bằng request có ký:** RustFS áp bucket policy ẩn danh của `media` cho mọi request, nên mọi user (cả `svp-pg-backup`,
  `svp-objstore-probe`) đọc được object dưới `media/media/*` như khách, đúng phạm vi UP-6; liệt kê `media` và mọi ghi vẫn 403. Ca
  BAK-1 "`svp-pg-backup` không đọc được `media`" của `threats.sh` đổi sang key ngoài tiền tố công khai (`/media/<obj>`), 403.
- Health `/health/live` của RustFS trả JSON có `version`, `uptime` không cần xác thực (MinIO trả body rỗng); chỉ tới được trên
  loopback, ghi ở mục 6 của [threat model](../threat-model.md).
- Mục 6 trên máy chạy thêm `curl` sáu ca dù kế hoạch ghi "không curl tay": kiểm sớm trước khi job `stack` chạy; kết luận của mục
  vẫn là e2e ở job `stack`.

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

- Store compose (Quyết định 1–3, 7): service `s3`, `s3-init`, volume `s3-data`, anchor image `x-s3-image` của
  `deploy/compose/compose.yaml`; biến `.env`, `test-stack`, `clean-data`, target `object-store-copy` ở `deploy/compose/compose.mk`;
  `.env.example`; Renovate theo version ở `renovate.json`.
- Init, policy, CORS theo bucket, user thử (Quyết định 3, 4, 9): `deploy/s3/init.sh`, `deploy/s3/*-policy.json`,
  `deploy/s3/media-anonymous.json`.
- Store k3d (Quyết định 1–3, 5, 7, 10): `deploy/helm/svp-data/templates/s3.yaml` (StatefulSet, Service, HTTPRoute, Job `s3-init`),
  `deploy/helm/svp-data/files/s3` (symlink tới `deploy/s3/`), `deploy/helm/svp-data/values.yaml`,
  `deploy/helm/svp-data/templates/networkpolicies.yaml`, `deploy/helm/svp-data/templates/backup.yaml` (`endpointURL`),
  `deploy/helm/svp-data/Chart.yaml`, `deploy/helm/svp-cluster/templates/namespaces.yaml`, `deploy/helm/svp-service/values.yaml`,
  `deploy/k8s/values/services/{video-service,media-worker,gateway,web}.yaml`, `deploy/k8s/values/plugin-barman-cloud.yaml`;
  Secret `s3-root`, `s3-users` ở `deploy/k8s/secrets.sh`; từ chối cluster còn MinIO ở `deploy/k8s/install.sh`,
  `deploy/k8s/drills/backup.sh`, `deploy/k8s/k8s.mk`; `deploy/k8s/gitops.sh`; mục KSV-0125 của `s3.yaml` ở
  `deploy/ci/trivy-config-ignore.yaml`.
- Bước chép và đường quay lại (Cách chuyển): `deploy/compose/object-store-copy.sh` (digest A ở `minio_image=`),
  `deploy/compose/object-store-copy-test.sh`.
- Kiểm (Kế hoạch kiểm): `internal/objstore/integration_test.go` (ca chữ ký POST, multipart CRC32 hai lượt),
  `web/e2e/security.e2e.ts` (WEB-10 sáu ca), `deploy/compose/drills/{common,upload-cleanup,obs-threats}.sh`,
  `deploy/k8s/drills/threats.sh`, `deploy/observability/glitchtip/dotenv-test.sh`; trên runner `deploy/ci/verify-run.sh`,
  `deploy/ci/verify-sample.sh`, `deploy/ci/verify-collect-test.sh`, `deploy/ci/verify-mask.sh`, chú thích của
  `.github/workflows/verify.yml`.
- Tên trung tính trong chú thích và chuỗi ví dụ: `internal/objstore/objstore.go`, `objstore_test.go`,
  `services/video-service/cmd/video-service/main.go`, `services/media-worker/cmd/media-worker/main.go` (và hai `main_test.go`),
  `proto/svp/video/v1/video_service.proto` (và `gen/go/svp/video/v1/video_service_grpc.pb.go` sinh lại), `web/server/{env,csp}.ts`,
  `web/server/env.test.ts`, `web/e2e/{fixtures,measure-upload.e2e,stack}.ts`, `web/e2e/seed.sh`.

## Nguồn

Đọc ngày 2026-10-24; dòng nào đọc lại hay thêm ngày 2026-10-25 ghi ngày đó ở cuối dòng.

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
- [R1] <https://github.com/rustfs/rustfs> (README, release 1.0.0–1.0.3; đọc lại 2026-10-25: 1.0.3 vẫn là bản mới nhất)
- [R2] <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/post_policy.rs>, <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/ops/signature.rs>, <https://github.com/s3s-project/s3s/blob/main/crates/s3s/src/config.rs>
- [R3] <https://github.com/rustfs/rustfs/security/advisories/GHSA-w5fh-f8xh-5x3p>, <https://github.com/rustfs/rustfs/issues/984>
- [R4] <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/server/layer.rs>, <https://github.com/rustfs/rustfs/blob/1.0.3/crates/config/src/constants/console.rs>
- [R5] <https://docs.rustfs.com/administration/iam/policies>
- [R6] <https://docs.rustfs.com/administration/data/bucket/policy>
- [R7] <https://github.com/rustfs/rustfs/blob/1.0.3/Dockerfile>, <https://hub.docker.com/v2/repositories/rustfs/rustfs/tags/1.0.3> (đọc lại 2026-10-25: `ENV RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS="*"`, `EXPOSE 9000 9001`)
- [R8] <https://github.com/rustfs/rustfs/blob/1.0.3/helm/rustfs/values.yaml>
- [R9] <https://github.com/rustfs/rustfs/security/advisories>
- [R10] <https://github.com/rustfs/rustfs/blob/1.0.3/CLA.md>
- [R11] <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/server/prefix.rs>
- [R12] <https://github.com/rustfs/cli> (`rc`, v0.1.36)
- [R13] <https://github.com/cloudnative-pg/plugin-barman-cloud/blob/v0.15.1/test/e2e/internal/objectstore/s3.go>, <https://github.com/cloudnative-pg/plugin-barman-cloud/pull/1109>
- [R14] <https://github.com/rustfs/rustfs/blob/1.0.3/crates/checksums/src/lib.rs>
- [R15] <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/config/cli.rs> (`--console-enable`, env `RUSTFS_CONSOLE_ENABLE`), <https://github.com/rustfs/rustfs/blob/1.0.3/crates/config/src/constants/app.rs> (`DEFAULT_CONSOLE_ENABLE = true`, `DEFAULT_CONSOLE_ADDRESS` `:9001`), <https://github.com/rustfs/rustfs/blob/1.0.3/crates/config/src/constants/console.rs>, <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/startup_server.rs> (không listener console khi tắt; listener S3 luôn `console_enable = false`) (2026-10-25)
- [R16] Tìm mã `post_signature` trong repo `rustfs/rustfs` bằng GitHub code search (nhánh mặc định): 0 kết quả; cùng tìm trong `s3s-project/s3s` ra `config.rs`, `ops/signature.rs` (2026-10-25)
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
- [B5] <https://github.com/velero-io/velero/issues/10543> (đọc lại 2026-10-25: đóng 2026-09-29)
- [B6] <https://github.com/cloudnative-pg/plugin-barman-cloud/issues/743>
- [B7] <https://github.com/velero-io/velero-plugin-for-aws/pull/335> (merge vào `main` 2026-09-29) (2026-10-25)
- [B8] <https://github.com/velero-io/velero-plugin-for-aws/pull/338> (cherry-pick #335 vào `release-1.14`, còn mở) (2026-10-25)
- [B9] <https://github.com/velero-io/velero-plugin-for-aws/releases> (bản mới nhất v1.14.4, 2026-09-28) (2026-10-25)
- [B10] <https://github.com/aws/aws-sdk-go-v2/blob/service/internal/checksum/v1.11.7/service/internal/checksum/middleware_compute_input_checksum.go>
  (bản ghim trong `go.mod`: nhánh trailer chỉ khi `req.IsHTTPS()`, `AddInputChecksumTrailer` trả lỗi "HTTPS required" với `http`;
  đặt `content-encoding: aws-chunked`, `x-amz-trailer`, `x-amz-content-sha256: STREAMING-UNSIGNED-PAYLOAD-TRAILER`),
  <https://github.com/boto/botocore/blob/1.43.105/botocore/httpchecksum.py> (`resolve_request_checksum_algorithm`: trailer chỉ khi
  URL là `https`, còn lại header) (2026-10-25)
