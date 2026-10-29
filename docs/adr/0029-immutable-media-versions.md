# 0029. Output HLS bất biến theo version: `media/<video_id>/<version>/…` với version là `event_id` của `video.uploaded`, mỗi lần thử ghi thư mục riêng và master chỉ tạo một lần, `Cache-Control: max-age=31536000, immutable`; CMAF (fMP4) chỉ đánh giá, làm khi chạm transcode

- Trạng thái: Chấp nhận (người học duyệt 2026-10-28); hiện thực 2026-10-29 (mục Hiện thực ở): unit test, lint, `buf breaking`
  đạt trên máy; ghi có điều kiện và `Cache-Control` của RustFS, policy của worker, smoke và hai diễn tập trên stack đạt trên runner
  2026-10-29 (kịch bản `compose-obs`, `dev-k3d`), header qua Envoy trên cluster GitOps đạt 2026-10-29 sau khi bản media-worker phát
  hành ghi key có version, nên kịch bản `gitops` thôi đặt `SVP_SMOKE_LEGACY_MEDIA` (mục Kiểm chứng sau); video `READY` cũ trên volume
  chưa kiểm riêng
- Ngày: 2026-10-28

## Bối cảnh

- [ADR-0004](0004-direct-upload-and-hls.md) (phần Phát) ghi output HLS vào đường dẫn cố định `media/<video_id>/` "nên transcode lại
  một video chỉ ghi đè: worker idempotent mà không cần bảng chống trùng". [ADR-0008](0008-async-upload-pipeline-stage2a.md) §8
  dựa vào đó: media-worker gặp lại `video.uploaded` (phát lại, consumer bị kill rồi nhận lại partition) thì transcode lại và ghi
  đè cùng key; §10 chốt layout `media/<id>/master.m3u8`, `media/<id>/<rendition>/index.m3u8`, segment `seg_NNN.ts` trong
  `media/<id>/<rendition>/`, `media/<id>/thumbnail.jpg`. Hiện thực ở `services/media-worker/internal/worker/worker.go` (prefix
  `objstore.MediaPrefix + id + "/"`) và `services/media-worker/internal/transcode/transcode.go` (tên file cố định).
- Ghi đè cùng key xung đột với cache dài: libx264 đa luồng không cho kết quả bit-exact (ADR-0008 §8: `make drill-duplicates`
  chỉ đòi playlist biến thể giống hệt, `BANDWIDTH` trong master lệch ≤ 5 %), nên một lần transcode lại đổi byte của segment
  dưới cùng URL. Với cache một năm ở trình duyệt hay CDN, người xem có thể nhận segment của hai lần chạy khác nhau, và không có
  cách nào "xoá" bản đã nằm trong cache của trình duyệt. Hiện object không mang `Cache-Control` nào (`objstore.Upload` chỉ đặt
  `Content-Type`), nên trình duyệt và CDN tự đoán thời hạn cache.
- Egress là khoản chi lớn nhất ([architecture.md §3](../architecture.md#3-ước-lượng-quy-mô)); giai đoạn 7 đặt CloudFront trước
  bucket `media`. CloudFront cache object theo `Cache-Control: max-age` của origin trong giới hạn TTL của cache policy, trình
  duyệt theo đúng `max-age` [N7]. Muốn cache dài thì URL phải đổi khi nội dung đổi: đó là cách dùng mà `immutable` được thiết kế
  cho [N5].
- Người học đã chốt (2026-10-28): output HLS nằm ở `media/<video_id>/<version>/…`; transcode lại ghi version mới, không sửa object
  cũ; `Cache-Control: max-age=31536000, immutable` cho segment và playlist VOD; CMAF (fMP4) thay `.ts` chỉ đánh giá, làm khi chạm
  transcode. ADR này chốt phần còn lại: version là gì, cách bảo đảm không ghi đè object đã công khai và cách phát lại kết quả,
  header đặt ở đâu, tương thích ngược, bảng so CMAF.
- Ràng buộc của contract và của hạ tầng:
  - Event mang object key, không mang URL ([ADR-0006](0006-contract-ids-and-event-envelope.md) §6); gateway ghép URL từ key.
  - Key do media-worker phát phải qua `objstore.IsMediaKey` (`internal/objstore/objstore.go`, FF-6): `media/<video_id>/` rồi
    một hay nhiều đoạn chỉ gồm chữ, số, `.`, `_`, `-`, không phải `.` hay `..`. video-service
    (`services/video-service/internal/server/transcode.go`) và feed-service
    (`services/feed-service/internal/projector/projector.go`) kiểm lại điều này, không giả định số đoạn.
  - video-service từ chối `transcode.completed` có `duration` không dương (`kafkax.Permanent`) và chỉ nhận khi video đang
    `PROCESSING`; video `READY` bỏ qua event, video `FAILED` xoá `uploads/<id>` và `DeletePrefix("media/<id>/")` lần nữa.
  - Envelope `EventMeta.event_id` (`proto/svp/event/v1/event.proto`): UUIDv7 dạng chữ thường 36 ký tự, sinh trước khi commit
    outbox, gửi lại vẫn giữ nguyên. `CompleteUpload` chỉ ghi `video.uploaded` một lần cho mỗi video (gọi lại khi đã
    `PROCESSING`/`READY` thì trả về như cũ, không ghi event mới).
  - Hai lần thử cùng một event có thể chạy song song: kafkax không huỷ handler khi member mất partition hay bị loại khỏi group
    (`internal/kafkax/consumer.go`; `BlockRebalance` chỉ giữ rebalance trong lúc process còn ở trong group, `RebalanceTimeout`
    của media-worker là 164 phút). Process mất session vẫn chạy handler tới hết, trong khi member khác nhận lại cùng record.
  - User `svp-media-worker` của object store chỉ có `s3:GetObject` trên `uploads/uploads/*` và `s3:PutObject` trên
    `media/media/*` (`deploy/s3/media-worker-policy.json`, dùng chung cho compose và k3d qua `deploy/s3/init.sh`): hiện worker
    không đọc, không liệt kê được bucket `media`. Trên S3, HEAD hay GET một key chưa có trả 404 chỉ khi credential có
    `s3:ListBucket` trên bucket, không có thì 403 [N13]; `objstore` xếp 403 vào `ErrAccessDenied`, lỗi mà các service coi là lỗi
    cấu hình tạm thời và thử lại.

## Các lựa chọn

### 1. Version là gì

#### A. Id ngẫu nhiên mỗi lần chạy

- Được: không cần trạng thái gì.
- Mất: phát lại cùng event (bình thường với at-least-once) ra version khác, nên mỗi lần phát lại để lại một bộ object mồ côi
  không ai trỏ tới; không có cách nào biết "lần chạy trước đã xong chưa", nên không bỏ được việc transcode lại.

#### B. Số đếm tăng dần (`v1`, `v2`, …)

- Được: ngắn, đọc được.
- Mất: phải có trạng thái chung để cấp số (bảng của video-service, hay liệt kê `media/<id>/` để tìm số lớn nhất). Liệt kê thì
  hai worker cùng lúc (worker cũ chưa chết hẳn sau rebalance) có thể lấy cùng số; phát lại một event cũ ra số mới, như A.

#### C. `event_id` của `video.uploaded`

- Được: tất định theo yêu cầu transcode: phát lại cùng record (`rpk group seek`, consumer nhận lại partition, DLQ phát lại giữ
  nguyên value) ra cùng version; một yêu cầu transcode mới sau này là event mới, `event_id` mới, nên version mới. Không cần
  trạng thái ngoài event. UUID chữ thường có gạch nối qua được `IsMediaKey`. Truy ngược từ URL về đúng event (log có `event_id`).
- Mất: đoạn path dài 36 ký tự; UUIDv7 lộ thời điểm `CompleteUpload` (millisecond) trong URL công khai, trong khi
  `published_at` công khai đã lộ thời điểm sau đó vài chục giây; không có thứ tự "version nào mới hơn" ngoài thời gian trong
  UUIDv7.

#### D. Băm nội dung (nguồn cộng thông số encode)

- Được: cùng nguồn, cùng thông số thì cùng version kể cả khi event khác.
- Mất: phải đọc trọn file gốc (tới 500 MiB) để băm trước khi biết version, hoặc tin ETag của store (multipart thì không phải
  MD5); phải định nghĩa "thông số encode" thành một chuỗi ổn định (ladder, preset, version ffmpeg của image); hai yêu cầu cố ý
  transcode lại cùng thông số không ra version mới, ngược với quyết định đã chốt.

### 2. Cách bảo đảm không ghi đè object đã công khai

#### K1. Mọi lần thử ghi chung prefix của version, kiểm master trước, master tải lên cuối

- Được: layout chỉ thêm một đoạn; store chỉ cần HEAD.
- Mất: không chặn được writer cũ. Lần thử A (process mất session, handler còn chạy) và lần thử B cùng thấy "chưa có master";
  B ghi xong master và phát kết quả, A vẫn PUT segment, thumbnail, playlist rendition vào đúng các key B vừa công khai. Ghi
  master có điều kiện cũng không chặn được các PUT của A xảy ra trước đó.

#### K2. `If-None-Match: *` cho mọi object, chung prefix

- Được: store từ chối ghi đè từng object một cách nguyên tử [N14].
- Mất: lần chạy lại sau khi chết giữa chừng gặp 412 ở object của lần trước; coi 412 là "đã có" thì segment của hai lần chạy
  (libx264 không bit-exact) trộn dưới một master; hai lần thử song song thì mỗi lần thắng một phần các key.

#### K3. Khoá theo video (lease ở Redis hay Postgres)

- Được: lúc bình thường chỉ một worker transcode một video.
- Mất: media-worker không có Redis hay database. Lease hết hạn mà process đang treo không biết, nên writer cũ vẫn ghi sau khi
  lease đã sang worker khác; muốn chặn thì store phải kiểm một fencing token kèm mỗi lần ghi, mà S3 không có cơ chế đó.

#### K4. Mỗi lần thử ghi vào thư mục riêng; master là object duy nhất ở cấp version, chỉ tạo một lần bằng `If-None-Match: *`

- Được: writer cũ chỉ ghi được vào thư mục của chính nó, thư mục không playlist công khai nào trỏ tới. Chỉ một lần tạo master
  thành công: nhiều lần ghi có điều kiện cùng key thì lần xong trước thắng, các lần sau nhận 412 [N14]. Chỉ cần quyền
  `s3:PutObject` [N14]; không khoá, không trạng thái ngoài store.
- Mất: worker phải sửa URI trong master (thêm đoạn thư mục của lần thử); thư mục của lần thử thua hay chết giữa chừng thành
  object mồ côi; store phải làm đúng ghi có điều kiện (S3 có [N14]; RustFS 1.0.3 có mã [N10], chưa kiểm hành vi); path dài thêm
  một đoạn.

### 3. Nhận biết master của version đã có

#### E1. HEAD `master.m3u8`

- Được: `objstore.Head` đã có; một request.
- Mất: trên S3, key chưa có trả 403 khi worker thiếu `s3:ListBucket` [N13] và `objstore` xếp 403 vào `ErrAccessDenied`: lần đầu
  của mọi video thành lỗi quyền, thử hết lượt, `RETRIES_EXHAUSTED`, video `FAILED` và mất file gốc. Muốn 404 phải cấp
  `ListBucket`; điều kiện `s3:prefix` (cách video-service đang giới hạn quyền này) có áp vào phép kiểm ngầm của HEAD hay không thì
  chưa nguồn nào đã đọc nói, nên phải cấp không điều kiện cho cả bucket.

#### E2. `ListObjectsV2` với `Prefix` là đúng key master, `MaxKeys` 1

- Được: "có" và "chưa có" là hai kết quả của cùng một request thành công (danh sách có đúng key đó hay không); lỗi, kể cả 403,
  luôn là lỗi. Request mang prefix nên quyền `s3:ListBucket` [N15] giới hạn được bằng `s3:prefix`, y như statement mà
  video-service đang dùng cho `DeletePrefix` trên RustFS.
- Mất: thêm một hàm vào `objstore`; worker thêm quyền liệt kê `media/` (credential nội bộ; UP-6 nói về liệt kê ẩn danh, vẫn
  đóng).

#### E3. Không kiểm trước, chỉ dựa vào 412 lúc tạo master

- Được: không thêm quyền liệt kê.
- Mất: mỗi lần phát lại chạy trọn ffmpeg (tới 10 phút) và để lại một thư mục mồ côi cỡ cả output.

### 4. Lần thử thấy master đã có: lấy `duration` và renditions ở đâu

Nhánh này cần vì `transcode.completed` phải mang `duration` dương và renditions, mà hiện cả hai chỉ có từ kết quả transcode
(`transcode.Result`).

#### R1. Đọc lại `master.m3u8` và playlist rendition đã lưu

- Được: không thêm object, không thêm hợp đồng; dùng lại đúng cách `transcode.go` đang tính (`readMaster`: kích thước từ
  `RESOLUTION` của `#EXT-X-STREAM-INF`; `playlistDuration`: tổng `#EXTINF` của playlist rendition đầu tiên); playlist VOD không
  đổi được [N1] nên đọc lại cho đúng giá trị đã công khai. URI biến thể trong master cho luôn thư mục của lần thử thắng, từ đó ra
  `thumbnail_key`.
- Mất: thêm hai, ba request nhỏ; worker cần quyền đọc bucket `media`; bitrate trong `Rendition` là bitrate mục tiêu của ladder,
  không có trong master (master có `BANDWIDTH` đo được), nên phải tra lại ladder theo tên rendition.

#### R2. Object metadata riêng (`result.json`) ghi ngay trước master

- Được: một GET, giá trị y hệt lần đầu.
- Mất: thêm một object công khai trong bucket đọc ẩn danh, thêm một định dạng phải giữ tương thích; vẫn cần quyền đọc `media`.

#### R3. Transcode lại nhưng không tải lên

- Được: không cần quyền đọc `media`.
- Mất: tốn trọn CPU của một lần transcode (tới 10 phút) chỉ để lấy hai giá trị; `drill-duplicates` vẫn chạy ffmpeg.

## Quyết định

### 1. Version: `event_id` của `video.uploaded` (C); mỗi lần thử một thư mục (K4)

- Layout của một version. `V` là `meta.event_id` của `video.uploaded`; `A` là id của lần thử: một UUIDv7 mới (`ids.New`) mỗi lần
  handler chạy, tức mỗi lần thử của kafkax trên mỗi process, không bao giờ dùng lại:

  | Object | Key | Ai ghi |
  | --- | --- | --- |
  | Master playlist | `media/<video_id>/<V>/master.m3u8` | đúng một lần thử, tạo bằng `If-None-Match: *` |
  | Playlist rendition | `media/<video_id>/<V>/<A>/<rendition>/index.m3u8` | chỉ lần thử `A` |
  | Segment | `media/<video_id>/<V>/<A>/<rendition>/seg_NNN.ts` | chỉ lần thử `A` |
  | Thumbnail | `media/<video_id>/<V>/<A>/thumbnail.jpg` | chỉ lần thử `A` |

- Tên file và thứ tự tải lên giữ như ADR-0008 §9–§10 (segment, thumbnail, playlist rendition, master cuối cùng). URI biến thể
  trong master là đường dẫn tương đối `<A>/<rendition>/index.m3u8`, player tính theo URI của master (RFC 8216 §4.1 [N1]); playlist
  rendition giữ URI segment tương đối như ffmpeg ghi.
- ffmpeg vẫn ghi `<rendition>/index.m3u8` trong master; worker thêm `<A>/` vào dòng URI sau mỗi `#EXT-X-STREAM-INF` trước khi tải
  lên. Master có tag khác mang URI (`#EXT-X-MEDIA`, `#EXT-X-I-FRAME-STREAM-INF`) là lỗi, xử lý như `listFiles` gặp file lạ:
  ladder hiện nay không sinh các tag đó, và sửa sót một URI thì player đi sai đường.
- media-worker kiểm `meta.event_id` là UUID dạng chuẩn (cùng `ids.Parse` đang kiểm `video_id`); sai dạng thì `kafkax.Permanent`
  (sang DLQ), như các field bắt buộc khác. Hai đoạn path do event và worker sinh, không đoạn nào lấy từ nội dung file gốc.
- `transcode.completed` mang `playlist_key` (master của version) và `thumbnail_key` (thumbnail trong thư mục của lần thử mà master
  trỏ tới); `video.ready` chép nguyên hai key đó (như nay). Không thêm field: không consumer nào cần version hay lần thử riêng.
- Transcode lại (một yêu cầu mới, event mới) ra version mới. Hiện không có đường nào phát `video.uploaded` thứ hai cho một
  video, và video-service bỏ qua `transcode.completed` của video `READY`: luồng transcode lại (ai kích hoạt, video-service đổi key
  của video `READY` thế nào, khi nào xoá version cũ) cần thiết kế riêng khi có nhu cầu; layout này không chặn nó.

### 2. Trình tự một lần thử (K4, E2, R1)

Sau khi `decode` nhận event:

1. **Kiểm master** bằng `ListObjectsV2` trên bucket `media`, `Prefix` là `media/<video_id>/<V>/master.m3u8`, `MaxKeys` 1. Danh sách
   có đúng key đó: sang bước 5. Rỗng: sang bước 2. Lỗi, kể cả 403: lỗi storage tạm thời như nay, không bao giờ coi là "chưa có".
   Worker không dùng HEAD hay GET để hỏi "có chưa" (E1). Bước này chỉ để khỏi transcode khi không cần: một câu trả lời "chưa có"
   đã cũ chỉ tốn một lần transcode và một thư mục mồ côi, vì bước 4 mới là chốt.
2. **Transcode:** tải nguồn, chạy ffmpeg vào thư mục job như nay; nhánh `transcode.failed` không đổi (chưa ghi object nào).
3. **Tải lên thư mục của lần thử:** sửa URI trong master (Quyết định 1), rồi tải lên tuần tự segment, thumbnail, playlist
   rendition dưới `media/<video_id>/<V>/<A>/`.
4. **Tạo master** `media/<video_id>/<V>/master.m3u8` bằng `PutObject` có `If-None-Match: *`:
   - thành công: phát `transcode.completed` với key của `A`, `duration` và renditions phân tích từ chính master đã sửa (bản vừa
     tải lên) và playlist rendition thấp nhất của nó, bằng cùng hàm với bước 5;
   - 412: một lần thử khác đã tạo master trước (worker song song, hay chính request này được SDK gửi lại sau khi lần gửi đầu đã
     thành công): sang bước 5; thư mục `A`, nếu master không trỏ tới nó, thành mồ côi;
   - lỗi khác (409 khi một lệnh xoá cùng key xong trước [N14], tức video-service đang xoá prefix của video `FAILED`; 5xx; mạng):
     lỗi tạm thời, lần thử sau bắt đầu lại từ bước 1 với `A` mới.
5. **Master đã có:** không tải nguồn, không transcode, không PUT gì. Tải master và playlist của rendition thấp nhất theo thứ tự
   ladder (như `rungs[0]` hiện nay) mà master trỏ tới vào thư mục job, mỗi file tối đa 1 MiB (playlist video ≤ 3 phút segment 4 s chỉ vài KB):
   - mọi dòng URI sau `#EXT-X-STREAM-INF` có dạng `<A'>/<rendition>/index.m3u8`, với cùng một `A'` là UUID dạng chuẩn và
     `<rendition>` là tên của ladder (`360p`, `720p`, `1080p`, `source`); `RESOLUTION` cho rộng, cao; bitrate mục tiêu tra từ
     ladder theo tên. Dạng khác, hai `A'` khác nhau, thiếu `RESOLUTION` hay không có `#EXT-X-STREAM-INF` nào là lỗi;
   - `duration`: tổng `#EXTINF` của `<A'>/<rendition thấp nhất>/index.m3u8`, phải dương;
   - `thumbnail_key`: `media/<video_id>/<V>/<A'>/thumbnail.jpg` (lần thử `A'` tải nó lên trước master).

   Rồi phát `transcode.completed` với các key đó. Phân tích dùng chung một hàm với bước 4 (tách `readMaster`, `playlistDuration`
   của `transcode.go` ra để đọc từ file), nên hai nhánh không thể ra giá trị khác nhau từ cùng playlist. Lỗi ở bước này (store,
   playlist rendition không còn, playlist không phân tích được) là lỗi tạm thời: kafkax thử lại theo ngân sách của worker, hết lượt
   thì `RETRIES_EXHAUSTED` như lỗi storage khác; **không bao giờ** ghi lại gì của version đó. Playlist rendition mất khi master còn
   chỉ xảy ra lúc video-service đang `DeletePrefix("media/<id>/")` video `FAILED` (xoá từng key theo thứ tự liệt kê; tên thư mục
   lần thử là chữ số hex, đứng trước `master.m3u8`); event kết quả khi đó bị video-service xử lý như video `FAILED`.

Vì sao `immutable` nói thật, kể cả khi hai worker chạy cùng một event:

- Key công khai của một version là master và các object trong thư mục `A*` mà master trỏ tới. Người xem chỉ tới được chúng qua
  `playlist_key`, `thumbnail_key` mà video-service công khai ở `video.ready`, tức sau khi master đã có.
- Master chỉ được tạo, không bao giờ ghi lại: mọi `PutObject` vào key master đều mang `If-None-Match: *`, và store chỉ cho một
  lần thành công [N14].
- Object trong `A*` chỉ lần thử `A*` ghi, và ghi xong (tải lên tuần tự, mỗi lệnh trả về trước lệnh sau) trước khi gửi lệnh tạo
  master. `A` không bao giờ dùng lại, nên sau khi master có không ai ghi vào `A*` nữa. Worker cũ còn chạy (Bối cảnh) chỉ ghi được
  vào thư mục của nó và nhận 412 ở bước 4. Trường hợp duy nhất một key của `A*` nhận thêm một lần ghi là request mà SDK gửi lại
  tới store muộn: cùng file, cùng byte.
- Thư mục mồ côi (lần thử thua, lần thử chết giữa chừng) không có playlist công khai nào trỏ tới; bucket `media` không cho liệt
  kê ẩn danh (UP-6), và `A` là UUIDv7 có 62 bit ngẫu nhiên nên không đoán được.
- Video `FAILED` bị `DeletePrefix("media/<id>/")` xoá mọi version và mọi thư mục; lần phát lại sau đó không thấy master và
  transcode lại, video-service nhận kết quả của video `FAILED` thì xoá lại, như nay.

Quyền của `svp-media-worker` thêm hai statement:

- `s3:GetObject` trên `arn:aws:s3:::media/media/*`: đọc master và playlist rendition ở bước 5;
- `s3:ListBucket` trên `arn:aws:s3:::media` với `StringLike` `s3:prefix` `media/*`: bước 1; cùng dạng statement video-service đang
  có.

`If-None-Match: *` chỉ cần `s3:PutObject` [N14], worker đã có. Quyền liệt kê chỉ cho credential nội bộ của worker, chính là
credential ghi mọi key mà nó thấy được; liệt kê ẩn danh vẫn đóng (UP-6). Ở cloud, hai quyền này vào IAM role của worker. Worker
đọc và liệt kê bằng cùng credential, cùng endpoint nội bộ như mọi lệnh storage khác, không qua URL công khai.

### 3. Header

- `Cache-Control: max-age=31536000, immutable` (365 ngày; `immutable` theo RFC 8246 [N5], `max-age` theo RFC 9111 §5.2.2.1 [N6])
  đặt lúc `PutObject` (header `Cache-Control` của request, S3 lưu thành system metadata và trả lại khi GET [N8], [N7]) cho **mọi**
  object của một version: segment, playlist rendition, master, thumbnail.
  - Playlist rendition là VOD (`-hls_playlist_type vod`): RFC 8216 §4.3.3.5 nói playlist VOD không đổi được [N1]. Master không có
    loại playlist nhưng chỉ được tạo một lần (Quyết định 2).
  - **Thumbnail có theo:** key của nó (`thumbnail_key`) cũng do event mang và nằm dưới version, nên một lần transcode lại ra
    thumbnail mới ở URL mới; không có lý do để thumbnail của version cache ngắn hơn segment, và
    thumbnail hiện ở mọi mục feed, kể cả video người xem không mở.
  - Không thêm `public`: response không cần xác thực vốn đã cache được ở cache dùng chung; giữ đúng chuỗi người học chốt.
- `objstore.Upload` nhận thêm giá trị `Cache-Control` (rỗng là không đặt header); chỉ media-worker gọi `Upload`. Bucket `uploads`
  không đổi: file gốc chỉ service đọc, đi bằng presigned POST, không có `Cache-Control`.
- Store trả lại header đã lưu:
  - RustFS (compose và k3d): mã của 1.0.3 chuyển `Cache-Control` của `PutObject` vào metadata của object [N9]; trả lại header
    đó khi GET ẩn danh thì chưa kiểm, ghi ở Kiểm chứng sau.
  - S3 + CloudFront (giai đoạn 7): CloudFront với Minimum TTL 0 cache theo `max-age` của origin trong giới hạn Maximum TTL, trình
    duyệt theo `max-age` [N7]; cache policy của giai đoạn 7 đặt Maximum TTL ≥ 31536000 nếu muốn edge giữ trọn năm (mặc định
    Maximum TTL của CloudFront là 1 năm, kiểm lại khi viết Terraform).
  - k3d qua Envoy (`s3.svp.localhost:8443`): route của `s3` không có filter sửa header response (không có
    `responseHeaderModifier` nào trong `deploy/helm/`), nên header đi nguyên; chưa đo, ghi ở Kiểm chứng sau.
- Ở compose web và media chạy trên `http://localhost`: RFC 8246 khuyên client bỏ qua `immutable` với resource không qua HTTPS [N5],
  nên trình duyệt có thể vẫn gửi request kiểm lại khi người dùng tải lại trang; `max-age` vẫn có hiệu lực. k3d (HTTPS) và
  CloudFront không bị điều này.

### 4. Tương thích ngược

- Video `READY` trước thay đổi giữ key `media/<id>/master.m3u8` trong `svp_video` và read model của feed-service: không di chuyển
  dữ liệu, không đặt lại header (object cũ không có `Cache-Control`, như nay). Gateway và feed-service chỉ dùng key do event mang,
  nên hai dạng cùng tồn tại không cần code riêng; `IsMediaKey` nhận cả hai.
- `DeletePrefix("media/<id>/")` (video-service, video `FAILED`) xoá mọi version, mọi thư mục lần thử và cả layout cũ.
- Phát lại `video.uploaded` của một video cũ sau khi đổi (diễn tập trên dữ liệu cũ, phát lại DLQ): worker không thấy master ở
  version, transcode và ghi một version mới, video-service bỏ qua vì video đã `READY`; version đó là object mồ côi (tốn chỗ, không
  ai trỏ tới). Chấp nhận ở lab; dọn bằng tay nếu cần.
- Contract `proto/`: chỉ đổi comment, không đổi field, số, tên (`buf breaking` sạch):
  - `svp.media.v1.TranscodeEvent`: thay câu "Transcoding the same video again overwrites the same object keys" bằng: output nằm
    dưới version là `event_id` của `video.uploaded`, một redelivery phát lại đúng key của master đã có và không ghi lại object nào;
  - `TranscodeCompleted.playlist_key`, `VideoReady.playlist_key`: `media/<video_id>/<version>/master.m3u8` (video cũ:
    `media/<video_id>/master.m3u8`); `thumbnail_key` vẫn "under `media/<video_id>/`".
  - Code sinh ở `gen/go` mang comment nên chạy `make generate` cùng thay đổi.

### 5. CMAF (fMP4): đánh giá, làm khi chạm transcode

| Tiêu chí | MPEG-TS `.ts` (hiện nay) | fMP4 / CMAF |
| --- | --- | --- |
| hls.js (web, `hls.js` 1.7.3) | Phát được; hls.js transmux TS sang fMP4 trong trình duyệt trước khi đưa vào MSE [N3] | Đưa thẳng vào MSE, không transmux [N3] |
| Safari, iOS | HLS gốc phát TS trên mọi bản; hls.js trên iOS 17.1+ qua Managed Media Source [N3] | HLS gốc hỗ trợ fMP4/CMAF từ iOS 10, macOS 10.12, tvOS 10 [N4] |
| Codec | H.264 đặt trong TS hay fMP4 đều được; HEVC và AV1 **bắt buộc** fMP4 theo spec của Apple (1.2, 1.5, 1.39) [N2] | Mọi codec của ladder hiện nay và HEVC, AV1 |
| Một bộ file cho HLS và DASH | Chuẩn DASH (ISO/IEC 23009-1) có quy định riêng cho MPEG-2 TS [N16], nên về chuẩn dùng chung được; ADR này chưa kiểm player DASH nào phát segment TS của HLS | Có: Apple mô tả playlist HLS và MPD của DASH dùng chung CMAF Header và Segment, cache chung [N4] |
| LL-HLS | Không cần cho VOD | Apple mô tả partial segment như CMAF Chunk [N11]; hls.js hỗ trợ LL-HLS [N3]; chỉ đáng khi có live |
| Mã hoá, DRM | AES-128 cả file; hls.js chỉ giải SAMPLE-AES "identity" với TS và **không** hỗ trợ FairPlay, PlayReady, Widevine trên TS [N3] | DRM qua EME (FairPlay, PlayReady, Widevine) với fMP4 [N3]; Common Encryption trên Apple theo pattern 1:9 (13.7) [N2], tức scheme `cbcs` |
| ffmpeg | `-hls_segment_type mpegts` (mọi version HLS) | `-hls_segment_type fmp4`, `-hls_fmp4_init_filename` (mặc định `init.mp4`), HLS version 7 trở lên [N12]; playlist có `#EXT-X-MAP` bắt buộc cho mỗi segment fMP4 [N1] (Apple 8.20 [N2]) |
| Số object | Mỗi rendition: segment + playlist | Thêm một init segment mỗi rendition (3 object cho ladder 3 bậc); segment `.m4s`, `Content-Type` `video/iso.segment`, init `video/mp4` [N2] |
| Code của repo | Đang chạy | `hlsArgs`, `listFiles` (từ chối file lạ, đặt `Content-Type`), `make drill-duplicates`, `deploy/compose/smoke.sh` (chỉ tải `.ts`) phải đổi |

**Quyết định:** giữ MPEG-TS bây giờ. Ladder hiện nay chỉ H.264 + AAC, phát được ở mọi đích (hls.js và HLS gốc), không DRM,
không DASH, không live; đổi định dạng là đổi transcode, playlist và hai script kiểm, không đem lại gì đo được cho lab ở lúc
này. Chuyển sang fMP4 (CMAF) trong cùng thay đổi với lần chạm transcode kế tiếp, vì khi đó các file đó đằng nào cũng đổi và version
mới (Quyết định 1) tách sạch output cũ và mới. Xem lại khi một trong các điều sau xảy ra:

- thêm HEVC hay AV1 vào ladder (Apple bắt buộc fMP4 [N2]);
- cần DRM, hay cần phát DASH cho client không có HLS;
- làm live hay LL-HLS;
- đo được thời gian main thread do hls.js transmux đáng kể trên máy yếu (thời gian tới khung đầu của `make measure-web`, hay
  profile trình duyệt) — fMP4 bỏ bước transmux [N3].

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết; mỗi dòng nêu phép kiểm chứng minh nó; kết quả và ngày ghi vào cột cuối. Hai dòng đầu là điều
kiện của K4 và E2 trên store local: sai một trong hai thì K4 hay E2 không đứng được, phải chọn lại bằng ADR mới.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| RustFS 1.0.3 làm đúng ghi có điều kiện | `make test-stack PKGS=./internal/objstore/...`: hai `PutObject` có `If-None-Match: *` cùng key gửi song song cho đúng một thành công, lần kia 412; lần thứ ba cũng 412 và GET trả nội dung của lần thắng | Đạt: `compose-obs` [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823) (2026-10-29, bước `test-stack-objstore`): 70 passed, 0 failed, 0 skipped, gồm `TestIntegrationCreateOnce` |
| Policy thật của `svp-media-worker` đủ cho E2 và R1 | `make test-stack` với credential worker (`SVP_TEST_S3_WORKER_*`): liệt kê với `Prefix` là một key có và một key chưa có trả đúng kết quả, không lỗi; GET playlist trong `media/` trả 200; liệt kê prefix ngoài `media/` bị từ chối | Đạt: `compose-obs` [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823) (2026-10-29, bước `test-stack-objstore`): 70 passed, 0 failed, 0 skipped, gồm `TestIntegrationWorkerReadsMedia` (ca liệt kê theo prefix) |
| RustFS 1.0.3 lưu `Cache-Control` của `PutObject` và trả lại khi GET ẩn danh | `make test-stack PKGS=./internal/objstore/...`: integration test `Upload` với `Cache-Control` rồi `GET` ẩn danh object của bucket `media` đọc đúng chuỗi | Đạt: `compose-obs` [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823) (2026-10-29, bước `test-stack-objstore`): 70 passed, 0 failed, 0 skipped, gồm `TestIntegrationCacheControl` |
| Compose: key có version và lần thử, mọi object mang header | `make smoke`: `playlist_url` có dạng `…/media/<id>/<uuid>/master.m3u8`, URI biến thể trong master dạng `<uuid>/<rendition>/index.m3u8`; `curl -sI` master, một playlist rendition, một segment, thumbnail đều có `Cache-Control: max-age=31536000, immutable` | Đạt: `make smoke` ở [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823): dòng `versioned key … Cache-Control …` trên master, playlist biến thể, segment, thumbnail, không dòng `NOTE` |
| k3d: Envoy giữ nguyên header | `make k8s-smoke` qua `https://s3.svp.localhost:8443` với cùng các phép kiểm header | Đạt: `make k8s-smoke` qua Envoy ở `dev-k3d` [40857870284](https://github.com/anhnvcoder/short-video-platform/actions/runs/40857870284) (2026-10-29) và [40937054425](https://github.com/anhnvcoder/short-video-platform/actions/runs/40937054425) (2026-10-29), và trên cluster GitOps ở `gitops` [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229) (2026-10-29, bản phát hành của `main`): dòng `versioned key media/<id>/<version>/master.m3u8; Cache-Control max-age=31536000, immutable` trên master, biến thể, segment, thumbnail, 0 dòng `NOTE` |
| Hai lần thử song song cùng event không đổi byte nào đã công khai | Unit test của `worker` với store giả làm đúng `If-None-Match: *`: lần thử A dừng giữa lúc tải lên, B chạy hết, A chạy tiếp; đúng một master, master trỏ thư mục của B, không object nào dưới thư mục B bị ghi sau khi master có, A phát `transcode.completed` với đúng key của B | Đạt trên máy 2026-10-29: `make test PKGS=./services/media-worker/... TESTFLAGS=-count=1` (`-race`) |
| Phát lại `video.uploaded` không ghi object nào, kết quả giống hệt | `make drill-duplicates`: số object và ETag dưới `media/<id>/` (liệt kê bằng `curl --aws-sigv4` trong container `s3`) không đổi trước và sau phát lại; worker log nhánh "output exists"; `transcode.completed` phát lại có cùng `playlist_key`, `thumbnail_key`, `duration`, renditions | Đạt: `drill-duplicates` ở `compose-obs` [40873923182](https://github.com/anhnvcoder/short-video-platform/actions/runs/40873923182) (2026-10-29): `no object under media/<id>/ added or written again (10 objects, same ETags)`, `media-worker found the version's master and transcoded nothing` |
| Worker chết trước master thì lần thử sau công khai thư mục của nó, `READY` một lần | `make drill-kill-worker`: `READY` đúng một lần; master trỏ thư mục của lần thử sau, thư mục của lần bị kill (nếu có) không được trỏ tới | Đạt: `drill-kill-worker` ở [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823): `READY` 103 s sau restart, đúng một `transcode.completed`, master trỏ đúng thư mục lần thử |
| Video `READY` cũ (key không version) vẫn phát | Trên volume có video cũ: `GET /public/videos/{id}` của video đó, tải master và segment 200 | Chưa kiểm riêng trên volume có video cũ. Gián tiếp: `gitops` [40857855305](https://github.com/anhnvcoder/short-video-platform/actions/runs/40857855305) (2026-10-29, cluster chạy bản media-worker trước ADR này) `k8s-smoke` qua với key không version (`SVP_SMOKE_LEGACY_MEDIA=1`, dòng `NOTE`) |
| Đọc lại playlist ra cùng `duration`, renditions, `thumbnail_key` như lúc tạo master | Unit test của `transcode` và `worker`: cùng output cho cùng giá trị ở bước 4 và bước 5; URI không có thư mục lần thử, hai thư mục khác nhau, tên rendition lạ, thiếu `RESOLUTION`, playlist rỗng là lỗi; master có `#EXT-X-MEDIA` thì bước sửa URI báo lỗi | Đạt trên máy 2026-10-29: cùng lệnh trên (gói `transcode`, `worker`) |
| Contract không phá vỡ | `buf lint`, `buf breaking --against '.git#branch=main'` sạch | Đạt trên máy 2026-10-29 |

## Hệ quả

- Được:
  - Cache một năm ở trình duyệt và CDN cho toàn bộ output HLS, không lo nội dung đổi dưới cùng URL; giảm request và egress lặp lại,
    nhất là thumbnail của feed.
  - Hai worker chạy cùng event (worker cũ chưa dừng sau khi mất session) không đổi được byte nào dưới URL đã công khai; không cần
    khoá hay trạng thái ngoài store.
  - Phát lại `video.uploaded` (diễn tập, consumer chạy lại) không còn chạy ffmpeg: một lệnh liệt kê và hai GET nhỏ thay cho tới
    10 phút CPU.
  - Đường cho transcode lại (định dạng mới, CMAF) có sẵn: version mới ở URL mới, version cũ vẫn phát cho tới khi đổi key.
- Phải trả:
  - Worker thêm quyền đọc và liệt kê `media/`, và một nhánh code (liệt kê, sửa URI master, tạo master có điều kiện, tải playlist,
    phân tích).
  - Path dài thêm hai đoạn UUID (74 ký tự); UUIDv7 lộ mốc thời gian `CompleteUpload` và mốc của lần thử trong URL.
  - Phụ thuộc vào ghi có điều kiện của store: S3 có [N14]; RustFS phải qua phép kiểm ở Kiểm chứng sau; đổi store (đường quay lại
    MinIO của [ADR-0022](0022-local-object-store-minio-replacement.md) hay store khác) phải qua lại phép kiểm đó trước khi chạy
    media-worker trên nó.
  - Object mồ côi: thư mục của lần thử chết giữa chừng hay thua ở bước 4, version của event cũ phát lại, và (khi có transcode lại)
    version cũ; chưa có job dọn.
  - `make drill-duplicates` đổi tiêu chí (không ghi gì, giống hệt từng byte) thay cho "transcode lại, `BANDWIDTH` lệch ≤ 5 %".
- ADR khác, khi ADR này được chấp nhận (đã ghi vào trạng thái của chúng và bảng ở `README.md` ngày 2026-10-29):
  - [ADR-0004](0004-direct-upload-and-hls.md): phần Phát (đường dẫn `media/<video_id>/` cố định, transcode lại ghi đè) chỉnh bởi
    0029;
  - [ADR-0008](0008-async-upload-pipeline-stage2a.md): §6 (policy của `svp-media-worker` thêm `GetObject` và `ListBucket` trên
    `media`), §8 (media-worker idempotent bằng ghi đè đường dẫn cố định, tiêu chí của `drill-duplicates`), §10 (đường dẫn) chỉnh
    bởi 0029.
- Xem lại khi:
  - Có luồng transcode lại thật: thiết kế việc đổi key của video `READY` và job xoá version cũ sau khi hết hạn cache.
  - Object mồ côi chiếm chỗ đáng kể (so liệt kê `media/` với key trong `svp_video`): job dọn chỉ xoá thư mục lần thử dưới version
    **đã có master** mà master không trỏ tới; version chưa có master có thể còn một lần thử đang chạy, không đụng.
  - Các điều kiện CMAF ở Quyết định 5.

## Hiện thực ở

- `services/media-worker/internal/worker/worker.go`: `decode`/`checkUploaded` lấy version từ `meta.event_id` (UUID dạng chuẩn,
  sai thì `kafkax.Permanent`); `job.run` kiểm master bằng `Storage.Exists` (span `check output`), id lần thử `ids.New()`, tải lên
  dưới `<version>/<attempt>/`, tạo master bằng `Storage.Create`; `job.stored` (span `read output`, log `transcode output exists`)
  đọc lại master và playlist rendition thấp nhất (mỗi file ≤ 1 MiB) rồi phát lại `transcode.completed`; hằng `cacheControl`
  cho mọi object. Test ở `worker_test.go` (store giả làm đúng `If-None-Match: *`): hai lần giao, chết trước master, chết sau
  master rồi phát lại, hai lần thử song song, master không đọc được, `Exists` lỗi, `event_id` sai dạng.
- `services/media-worker/internal/transcode/transcode.go`: `Run` nhận id lần thử, `rewriteMaster` thêm `<attempt>/` vào URI
  biến thể (từ chối `#EXT-X-MEDIA`, `#EXT-X-I-FRAME-STREAM-INF`); `ParseMaster`, `Master.LowestPlaylist`, `PlaylistDuration`
  dùng chung cho kết quả vừa transcode và master đã lưu, bitrate tra theo tên rendition. Test ở `transcode_test.go`.
- `internal/objstore/objstore.go`: `Upload(…, cacheControl)`, `Create` (`If-None-Match: *`, 412 thành `ErrExists`), `Exists`
  (`ListObjectsV2`, `Prefix` là key, `MaxKeys` 1). `internal/objstore/integration_test.go`: `TestIntegrationCacheControl`,
  `TestIntegrationCreateOnce`, `TestIntegrationWorkerReadsMedia` (chạy bằng `make test-stack`).
- `proto/svp/media/v1/events.proto`, `proto/svp/video/v1/events.proto`, `proto/svp/video/v1/video_service.proto`,
  `proto/svp/feed/v1/feed_service.proto`: comment của key; `gen/go` sinh lại.
- `deploy/compose/smoke.sh` (bước 8a, dùng chung cho `make k8s-smoke`): dạng key có version, URI biến thể, thumbnail cùng thư
  mục lần thử, header `Cache-Control` của master, một playlist rendition, một segment, thumbnail; `SVP_SMOKE_LEGACY_MEDIA=1` cho
  key không version qua với một dòng `NOTE` (từ 2026-10-30 không kịch bản nào đặt, `deploy/ci/verify/gitops.sh` bỏ biến này).
  `deploy/compose/drills/duplicate-events.sh`: phát lại không ghi object nào (key và
  ETag), `transcode.completed` giống từng byte; `deploy/compose/drills/kill-worker.sh`: master trỏ một thư mục lần thử, thumbnail
  ở đó. `deploy/ci/verify/compose-obs.sh`: bước `drill-duplicates`, `drill-kill-worker` và ba test integration mới.
- `deploy/s3/media-worker-policy.json`: thêm `s3:GetObject` trên `media/media/*` và `s3:ListBucket` trên `media` với
  `s3:prefix` `media/*`; `deploy/s3/init.sh` đặt lại policy mỗi lần chạy (job `s3-init` của compose mỗi `make up`, hook
  post-install/post-upgrade của chart `svp-data` ở k3d), nên cả hai đường nhận quyền mới không cần bước tay.
  `deploy/ci/verify-collect-test.sh`: trình tự bước mới của `compose-obs` và ba test integration mới trong output giả.

## Nguồn

- [N1] RFC 8216, HTTP Live Streaming (§3.3 "Each fMP4 Segment in a Media Playlist MUST have an EXT-X-MAP tag applied to it";
  §4.1 "Any relative URI is considered to be relative to the URI of the Playlist that contains it"; §4.3.2.5 `EXT-X-MAP` cần
  compatibility version ≥ 6; §4.3.3.5 "If the EXT-X-PLAYLIST-TYPE value is … VOD, the Media Playlist cannot change"):
  <https://www.rfc-editor.org/rfc/rfc8216.html> (đọc 2026-10-28)
- [N2] Apple, "HLS Authoring Specification for Apple Devices" (1.2 H.264 trong fMP4 hay TS; 1.5 HEVC và 1.39 AV1 phải fMP4; 8.20
  `EXT-X-MAP` với fMP4; 10.4 MIME `video/iso.segment`, `video/mp4`; 13.2 FPS dùng `SAMPLE-AES`; 13.7 Common Encryption pattern
  1:9): <https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices>
  (đọc 2026-10-28)
- [N3] hls.js README (fMP4/CMAF đưa thẳng vào MSE, TS được transmux; LL-HLS; AES-128; SAMPLE-AES "identity" chỉ với TS; FairPlay,
  PlayReady, Widevine chỉ với fMP4, không với TS; Managed Media Source trên Safari iOS 17.1+):
  <https://github.com/video-dev/hls.js/blob/master/README.md> (đọc 2026-10-28)
- [N4] Apple, "About the Common Media Application Format with HTTP Live Streaming (HLS)" (playlist HLS và MPD của DASH dùng chung
  CMAF Addressable Objects; HLS hỗ trợ segment fMP4 từ 9/2016; iOS 10.0, macOS 10.12, tvOS 10.0 trở lên hỗ trợ CMAF):
  <https://developer.apple.com/documentation/http-live-streaming/about-the-common-media-application-format-with-http-live-streaming-hls>
  (đọc 2026-10-28)
- [N5] RFC 8246, HTTP Immutable Responses (§1 dùng cho resource đổi URL khi đổi nội dung; §2 client không gửi request có điều
  kiện khi response còn fresh; §3 khuyên bỏ qua `immutable` với resource không qua HTTPS): <https://www.rfc-editor.org/rfc/rfc8246.html>
  (đọc 2026-10-28)
- [N6] RFC 9111, HTTP Caching, §5.2.2.1 `max-age`: <https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.2.1> (đọc 2026-10-28)
- [N7] Amazon CloudFront Developer Guide, "Manage how long content stays in the cache (expiration)" (bảng `Cache-Control:
  max-age` với Minimum/Maximum/Default TTL; trình duyệt cache theo `max-age`; đặt `Cache-Control` làm metadata object S3):
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Expiration.html> (đọc 2026-10-28)
- [N8] Amazon S3 API Reference, `PutObject` (header `Cache-Control`; `If-None-Match: *` ghi chỉ khi key chưa có, nếu không trả
  `412 Precondition Failed`): <https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html> (đọc 2026-10-28)
- [N9] RustFS 1.0.3, `rustfs/src/app/object/put.rs` (dòng 865–879 chuyển `cache_control` của `PutObject` đi tiếp) và
  `rustfs/src/app/object/shared.rs` (`apply_standard_object_metadata`, dòng 741–752 ghi `cache-control` vào metadata object):
  <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/app/object/put.rs>,
  <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/app/object/shared.rs> (đọc 2026-10-28)
- [N10] RustFS 1.0.3, `rustfs/src/storage/options.rs` (dòng 317–323 đọc `If-None-Match` thành điều kiện của thao tác ghi),
  `rustfs/src/app/object/put.rs` (dòng 570 nhận ra ghi có điều kiện; test `should_use_small_eager_put_path_keeps_conditional_1mb_writes_atomic`
  dòng 3077) và `crates/ecstore/src/object_api/types.rs` (dòng 998–1000, comment của `preserve_delete_marker`: "Evaluated with
  `http_preconditions` under the namespace commit lock"; dòng 1384–1387 đổi lỗi điều kiện thành `PreconditionFailed`):
  <https://github.com/rustfs/rustfs/blob/1.0.3/rustfs/src/storage/options.rs>,
  <https://github.com/rustfs/rustfs/blob/1.0.3/crates/ecstore/src/object_api/types.rs> (đọc 2026-10-28)
- [N11] Apple, "Enabling Low-Latency HTTP Live Streaming (HLS)" (partial segment là các file nhỏ "such as CMAF Chunks"; mở rộng
  định nghĩa ở draft-pantos-hls-rfc8216bis từ revision 7):
  <https://developer.apple.com/documentation/http-live-streaming/enabling-low-latency-http-live-streaming-hls> (đọc 2026-10-28)
- [N12] FFmpeg Formats Documentation, muxer `hls` (`hls_segment_type` `mpegts` "compatible with all HLS versions", `fmp4` "may
  be used in HLS version 7 and above"; `hls_fmp4_init_filename` mặc định `init.mp4`): <https://ffmpeg.org/ffmpeg-formats.html#hls>
  (đọc 2026-10-28)
- [N13] Amazon S3 API Reference, `HeadObject`, mục Permissions ("If you have the `s3:ListBucket` permission on the bucket, Amazon S3
  returns an HTTP status code `404 Not Found` error. If you don't have the `s3:ListBucket` permission, Amazon S3 returns an HTTP
  status code `403 Forbidden` error"): <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html> (đọc 2026-10-28)
- [N14] Amazon S3 User Guide, "How to prevent object overwrites with conditional writes" (`If-None-Match` chỉ cần
  `s3:PutObject`; key đã có thì `412 Precondition Failed`; "If multiple conditional writes or copies occur for the same object
  name, the first write operation to finish succeeds"; `409 Conflict` khi một lệnh xoá cùng key xong trước, `PutObject` gửi lại
  được sau 409): <https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html> (đọc 2026-10-28)
- [N15] Amazon S3 API Reference, `ListObjectsV2` (cần quyền `s3:ListBucket`; `Prefix` giới hạn key trả về; `MaxKeys`):
  <https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html> (đọc 2026-10-28)
- [N16] MPEG, "MPEG-DASH Part 1: Media presentation description and segment formats" (ISO/IEC 23009-1 "has specific provisions
  for the MPEG-4 file format and MPEG-2 Transport Streams, but can be used with any media format"):
  <https://www.mpeg.org/standards/MPEG-DASH/1/> (đọc 2026-10-28)
