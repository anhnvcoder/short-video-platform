# 0006. Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1`

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh

- [ADR-0002](0002-sync-rest-edge-grpc-internal.md) chọn gRPC bên trong, contract Protobuf quản lý bằng `buf`;
  [ADR-0003](0003-async-events-outbox.md) chọn event Protobuf trên Redpanda, outbox, at-least-once, key theo thực thể, và để
  envelope "chốt ở bước viết contract". Contract ở [`proto/`](../../proto/), tóm tắt ở
  [architecture.md §8](../architecture.md#8-contract).
- Những thứ dưới đây rất tốn để đổi về sau: kiểu ID nằm trong mọi bảng, mọi API, mọi event; event nằm lâu trên topic (giữ
  7 ngày, phát lại được), nên schema event giống schema dữ liệu hơn là giống API. Cách mã hoá cursor và bảng đổi mã lỗi
  sang HTTP đổi được ở một chỗ, nên ghi ở architecture §8, không ở ADR này.
- Ràng buộc: `buf` 1.73.0, bộ luật `STANDARD`, không dùng BSR hay dependency mạng; Postgres local là bản 15; outbox cần
  biết `event_id` trước khi commit; consumer của `user.follows` phải thấy follow và unfollow của một người theo đúng thứ tự
  (ADR-0003 luật 3).

## 1. Bố cục thư mục và cấu hình `buf`

### Các lựa chọn về bố cục

#### A. `proto/<service>/v1/` với package `svp.<service>.v1` (đúng chữ ADR-0002)

- Mất: trượt luật `PACKAGE_DIRECTORY_MATCH` của `STANDARD`. Luật này bắt package `svp.user.v1` phải nằm trong thư mục
  `svp/user/v1` tính từ gốc module. Đã thử với buf 1.73.0.

#### B. Bỏ tiền tố, package `user.v1` ở `proto/user/v1/`

- Được: đường dẫn ngắn, khớp ADR-0002 về thư mục.
- Mất: tên package chung chung dễ đụng với package của thư viện khác (`user.v1` không nói gì về hệ thống); đổi tên package
  sau này là thay đổi phá vỡ mọi thứ.

#### C. Giữ A, tắt luật `PACKAGE_DIRECTORY_MATCH`

- Mất: đường dẫn file không còn đoán được từ package (và ngược lại); `import` trong proto lệch với tên package; bỏ một luật
  của bộ chuẩn chỉ để giữ một câu chữ trong ADR thì không đáng.

#### D. `proto/svp/<domain>/v1/` với package `svp.<domain>.v1`

- Được: lint sạch với `STANDARD` nguyên vẹn; package có tiền tố riêng của hệ thống; đường dẫn import
  (`svp/event/v1/event.proto`) đọc ra ngay package.
- Mất: thêm một cấp thư mục; lệch chữ với ADR-0002.

### Quyết định về bố cục

Chọn **D**. Đây là chỉnh nhỏ về đường dẫn trong ADR-0002, không đổi quyết định chính (gRPC + `buf`) của nó.

- `buf.yaml` (v2) ở gốc repo: `modules: [{path: proto}]`, `lint.use: [STANDARD]`, `breaking.use: [FILE]`, không có `deps`.
  Lệnh chạy từ gốc repo: `buf lint`, `buf build`.
- Domain: `user`, `video`, `engagement`, `feed` (4 service gRPC), `media` (event của media-worker, không có service gRPC),
  `event` (envelope dùng chung). Domain là chủ đề của contract, không phải tên service: `media` là kết quả transcode chứ
  không phải "media-worker".
- File: `<domain>_service.proto` cho API, `events.proto` cho event, `svp/event/v1/event.proto` cho envelope.
- Chỉ import well-known types (`google/protobuf/timestamp.proto`, `duration.proto`), có sẵn trong `buf`. Không import
  `google/rpc/*`, `google/api/*`: cần `deps` từ BSR, mà chưa có lý do. Chi tiết lỗi gắn bằng gói Go `errdetails` lúc chạy,
  không cần nằm trong proto (xem architecture §8).
- `FILE` là bộ luật breaking chặt nhất: chặn cả việc chuyển message sang file khác, vì code Go sinh ra theo file.
- Chưa đặt `option go_package`: chưa có `go.mod` nên chưa biết module path. Giai đoạn 1 chọn giữa ghi tay trong từng file
  hoặc managed mode trong `buf.gen.yaml`.

## 2. Kiểu ID: UUIDv7

### Các lựa chọn về kiểu ID

#### A. `bigserial`

- Được: 8 byte, nhỏ nhất, nhanh nhất cho index.
- Mất: chỉ database sinh được, nên outbox không biết `event_id`/`video_id` trước khi `INSERT`; lộ số lượng người dùng và
  video (đoán được tốc độ tăng trưởng, duyệt lần lượt `/videos/1`, `/videos/2`...); trùng nhau giữa các database khi gộp
  hay phát lại event.

#### B. UUIDv4

- Được: sinh ở đâu cũng được, không lộ gì.
- Mất: hoàn toàn ngẫu nhiên, nên mỗi lần chèn rơi vào một chỗ bất kỳ của index B-tree: trang index bị tách liên tục, cache
  của Postgres chứa đầy trang nguội, index phình.

#### C. ULID

- Được: có thứ tự thời gian như UUIDv7.
- Mất: không phải chuẩn IETF; Postgres không có kiểu riêng (lưu `text` 26 ký tự hoặc ép sang `uuid`); thư viện và công cụ
  ít hơn.

#### D. Snowflake (64 bit: thời gian + máy + số thứ tự)

- Được: 8 byte, có thứ tự.
- Mất: phải cấp số máy cho mỗi instance (khó khi pod tự scale); JSON của JavaScript mất chính xác với số > 2^53, gateway
  phải trả dạng chuỗi.

#### E. UUIDv7 (RFC 9562)

- Được: 48 bit đầu là mili giây Unix, phần còn lại ngẫu nhiên, nên vừa sinh được ở bất kỳ instance nào không cần hỏi
  database, vừa chèn vào cuối index như số tăng dần; không lộ số lượng; là chuẩn, Postgres lưu bằng kiểu `uuid` 16 byte.
- Mất: 16 byte, gấp đôi `bigint`; lộ thời điểm tạo (với video và event thì vốn không bí mật).

### Quyết định về kiểu ID

Chọn **E** cho mọi thực thể (user, video) và cho `event_id`.

- **Trong proto:** `string` dạng chuẩn 36 ký tự, chữ thường (`0192f1c4-...`). Cân nhắc `bytes` 16 byte (gọn hơn một nửa trên
  dây), nhưng `string` đọc được ngay bằng `grpcurl` và trong log, gateway trả JSON không phải đổi. Service kiểm định dạng ở
  biên, sai thì `INVALID_ARGUMENT`.
- **Trong Postgres:** cột `uuid`, không phải `text`.
- **Sinh ở code Go** của service sở hữu thực thể (thư viện chọn ở giai đoạn 1). Không dựa vào hàm `uuidv7()` của Postgres:
  hàm này chỉ có từ bản 18, máy đang cài `postgresql@15`; và outbox cần `event_id` ngay trong code trước khi commit.
- Cursor keyset (`published_at`, `video_id`) ([ADR-0005](0005-feed-fan-out-on-write.md) luật 5) dùng `video_id` làm khoá
  phụ, nhưng khoá phụ chỉ cần duy nhất và so sánh được: Postgres so `uuid` theo byte nên UUIDv4 cũng dùng được. Đây không
  phải lý do chọn UUIDv7; thời điểm nằm trong `video_id` là lúc `InitUpload`, không phải `published_at`.
- Sắp theo `id` ra gần đúng thứ tự tạo là tiện ích khi debug, cũng không phải lý do chọn.

## 3. Envelope event và cách chia topic

### Các lựa chọn cách chia topic

#### A. Một topic cho mỗi loại event (`user.followed`, `user.unfollowed`, ...)

- Được: mỗi topic một schema, đơn giản; consumer chỉ subscribe loại mình cần.
- Mất: Kafka chỉ giữ thứ tự **trong một partition của một topic**. `user.followed` rồi `user.unfollowed` của cùng một
  `follower_id` nằm ở hai topic khác nhau thì feed-service có thể đọc unfollow trước follow (hai consumer, hai lag khác
  nhau), xoá một cạnh chưa có rồi thêm cạnh vào: bản sao follow sai vĩnh viễn. Luật 3 của ADR-0003 (mọi event của một thực
  thể giữ thứ tự) không đứng được.

#### B. Một topic cho một luồng thực thể của một producer

- Được: mọi event về một thực thể (cùng key) vào cùng partition, giữ thứ tự; số topic ít.
- Mất: một topic chứa nhiều loại event, nên cần một cách để biết record là loại nào; consumer chỉ cần một loại vẫn phải đọc
  (và bỏ qua) các loại kia.

### Các lựa chọn envelope (khi một topic có nhiều loại)

#### C. Metadata để hết trong header Kafka (kiểu CloudEvents binary mode), value là payload trần

- Được: theo chuẩn CloudEvents; router đọc được loại event mà không giải mã value.
- Mất: header là map chuỗi không kiểu, `buf` không kiểm được; quên header là mất `event_id`; loại event là một chuỗi tự do,
  consumer phải tự ánh xạ chuỗi sang message.

#### D. Message bọc chung với payload `google.protobuf.Any`

- Được: một message bọc duy nhất cho mọi topic.
- Mất: danh sách loại event của một topic không nằm ở đâu trong contract; `buf breaking` không thấy khi một loại bị bỏ;
  consumer giải mã theo chuỗi `type_url`.

#### E. Mỗi topic một message bọc: field 1 là envelope, sau đó `oneof` các loại event

- Được: kiểu chặt, `buf` kiểm cả envelope lẫn từng nhánh; contract ghi rõ topic nào chứa loại nào; consumer `switch` theo
  nhánh `oneof` (Go sinh ra một interface với mỗi nhánh một kiểu), compiler bắt lỗi gõ sai tên loại; thêm loại event = thêm
  một nhánh, không phá contract.
- Mất: mỗi topic một message bọc phải viết; consumer cũ gặp nhánh mới thì thấy `oneof` rỗng và phải bỏ qua có chủ ý.

### Quyết định về topic và envelope

Chọn **B + E**.

- Envelope `svp.event.v1.EventMeta { string event_id = 1; google.protobuf.Timestamp occurred_at = 2; }`, chỉ hai field.
  `event_id` là UUIDv7, sinh trước khi commit outbox, gửi lại vẫn giữ nguyên để consumer chống trùng. `occurred_at` là
  thời điểm thay đổi xảy ra ở producer, không phải lúc relay gửi; payload không lặp lại field này.
- Mỗi message bọc có `meta` ở field 1, `oneof event` từ field 2. Tên trong danh mục event (`user.followed`) ứng với một
  nhánh `oneof`. Comment của message bọc ghi tên topic, producer, key và topic DLQ.

  | Topic | Message bọc | Nhánh `oneof` | Key |
  | --- | --- | --- | --- |
  | `user.follows.v1` | `svp.user.v1.FollowEvent` | `UserFollowed`, `UserUnfollowed` | `follower_id` |
  | `video.lifecycle.v1` | `svp.video.v1.VideoEvent` | `VideoUploaded`, `VideoReady` | `video_id` |
  | `media.transcodes.v1` | `svp.media.v1.TranscodeEvent` | `TranscodeCompleted`, `TranscodeFailed` | `video_id` |
  | `engagement.views.v1` | `svp.engagement.v1.ViewEvent` | `ViewRecorded` | `video_id` |

- Tên topic: `<domain>.<luồng>.v<N>`. DLQ theo ADR-0003: `<topic>.dlq`.
- **Trace context** (`traceparent`, `tracestate`) đi trong **header Kafka** theo quy ước OpenTelemetry, không nằm trong
  proto: đó là dữ liệu hạ tầng, thư viện instrumentation của OpenTelemetry tự đọc ghi header, contract nghiệp vụ không phải
  đổi khi đổi cách tracing.
- Key partition là key của Kafka record, không lặp trong envelope; consumer đọc nó từ payload.

## 4. Versioning

- Package `v1` đi cùng hậu tố topic `.v1`.
- Trong một version chỉ thay đổi tương thích: thêm field, thêm nhánh `oneof`, thêm RPC, thêm giá trị enum. `buf breaking`
  với luật `FILE` chặn phần còn lại (đổi số field, đổi kiểu, đổi tên, xoá) ở CI.
- Trong `v1` không xoá field, nhánh `oneof` hay giá trị enum: đánh `[deprecated = true]` và ngừng dùng. Luật `FILE` báo lỗi
  khi xoá field kể cả khi số và tên đã `reserved` (`FIELD_NO_DELETE`, đã thử với buf 1.73.0), vì `FILE` giữ tương thích cả
  mã nguồn sinh ra: code Go đang dùng field đó sẽ không biên dịch được. `WIRE` chỉ giữ tương thích trên dây nên lỏng hơn.
- Xoá thật chỉ khi sang package `v2`: message trong `v2` khai báo `reserved` cả số lẫn tên của field cũ, để không ai dùng
  lại số cũ với nghĩa mới.
- Cân nhắc: `WIRE_JSON`, cho phép xoá field nếu đã `reserved` số và tên, vẫn giữ tương thích trên dây và JSON. Giữ `FILE`
  vì mọi service trong monorepo dùng chung code Go sinh từ proto: xoá một field trong `v1` làm vỡ build của service khác,
  trong khi `deprecated` đã đủ để ngừng dùng mà không phá gì.
- Thay đổi phá vỡ: tạo package `v2` và topic `.v2`; producer phát song song cả hai bản trong thời gian chuyển, consumer
  chuyển dần, xong thì ngừng `v1`. Với gRPC: server phục vụ cả `v1` và `v2` cho tới khi không còn client gọi `v1`.
- Cân nhắc: schema registry (Confluent/Redpanda). Kiểm tương thích lúc chạy, theo từng topic; nhưng thêm một hệ thống phải
  vận hành, trong khi `buf breaking` ở CI đã chặn trước khi code lên. Xem lại khi có producer ngoài monorepo này.

## 5. Danh tính người gọi

### Các lựa chọn về danh tính

#### A. Mỗi request mang `user_id` của người gọi

- Mất: service phải tin field do gateway điền, mà field nằm chung với dữ liệu nghiệp vụ, rất dễ có một handler lấy luôn giá
  trị client gửi lên; contract lẫn lộn "ai đang gọi" với "gọi về ai".

#### B. Truyền JWT xuống, mỗi service tự kiểm

- Được: không service nào phải tin gateway.
- Mất: mọi service phải có khoá công khai và logic kiểm JWT; thêm vài trăm micro giây mỗi chặng.

#### C. Gateway kiểm JWT, đặt `user_id` đã xác thực vào gRPC metadata `x-user-id`

- Được: request chỉ mang id của **thực thể khác** (`followee_id`, `video_id`), danh tính tách khỏi dữ liệu; một interceptor
  ở mỗi service đọc metadata vào `context`; đúng [architecture.md §7.4](../architecture.md#74-xác-thực).
- Mất: service tin metadata do bất kỳ ai gọi được tới nó đặt. Bên trong cluster tạm tin nhau qua mạng; mTLS để giai đoạn 6.

### Quyết định về danh tính

Chọn **C**. Comment của mỗi service ghi RPC nào cần người gọi; thiếu hoặc sai định dạng `x-user-id` thì `UNAUTHENTICATED`.
Rủi ro giả mạo header này (gọi thẳng service, gateway quên xoá header client gửi lên) do threat model xét.

**Mã lỗi đăng ký và đăng nhập:**

- `Register` với email đã tồn tại trả `ALREADY_EXISTS`. Như vậy client dò được email nào đã đăng ký. Chấp nhận ở MVP, giảm
  bằng rate limit ở gateway; cách triệt để (luôn trả thành công rồi gửi email xác nhận) cần hệ thống email, ngoài phạm vi.
- `Login` sai email hay sai mật khẩu đều trả `UNAUTHENTICATED` với **cùng `reason`** (`INVALID_CREDENTIALS`) và **cùng
  message**, không phân biệt hai trường hợp.
- Gateway trả `ErrorInfo.reason` ra client thành `code` và message thành `detail` (architecture §8.4), nên trường hợp nào
  cần che thì phải giống nhau ở cả ba: mã gRPC, `reason`, message. Tương tự với video: `GetVideo` trả `NOT_FOUND` khi video
  không tồn tại, hoặc chưa `READY` mà người gọi không phải tác giả (video đã `READY` thì ai cũng xem được); `CompleteUpload`
  trả `NOT_FOUND` khi video không tồn tại hoặc của người khác. Mọi trường hợp đó cùng `VIDEO_NOT_FOUND` và cùng message.
- MVP không có refresh token: token hết hạn thì đăng nhập lại.

## 6. Đường dẫn media trong contract

### Các lựa chọn về đường dẫn media

#### A. API và event mang URL tuyệt đối (`https://cdn.example.com/media/<id>/master.m3u8`)

- Mất: URL gắn với môi trường lúc phát event. Phát lại event từ local lên cloud, đổi CDN hay đổi domain thì bản sao ở
  feed-service chứa URL sai, phải dựng lại read model.

#### B. API và event mang object key (`uploads/<video_id>`, `media/<video_id>/master.m3u8`)

- Được: dữ liệu không phụ thuộc môi trường; gateway ghép URL công khai từ cấu hình (MinIO local, CDN trên cloud), đổi CDN
  chỉ là đổi cấu hình.
- Mất: gateway phải biết base URL; client không dùng được dữ liệu thô từ service (vốn không gọi thẳng service).

### Quyết định về đường dẫn media

Chọn **B**. Ngoại lệ duy nhất là `upload_url` của `InitUpload`: đó là chữ ký ngắn hạn cho endpoint của storage, không được
lưu và không đi vào event.

## Hệ quả

- Được:
  - ID sinh ở đâu cũng được, chèn index theo thứ tự, không lộ số lượng; outbox có `event_id` trước khi commit.
  - Thứ tự event của một thực thể giữ được kể cả khi topic có nhiều loại event; kiểu event được `buf` kiểm như API.
  - Contract không chứa gì phụ thuộc môi trường; `buf lint` và `buf breaking` chạy offline, không cần BSR.
- Phải trả:
  - ID 16 byte và chuỗi 36 ký tự trên dây; service phải kiểm định dạng UUID ở biên.
  - Consumer phải bỏ qua có chủ ý nhánh `oneof` chưa biết (và nhánh của loại mình không cần).
  - Thay đổi phá vỡ tốn một đợt chạy song song `v1`/`v2`.
  - Các service tin `x-user-id` cho tới khi có mTLS (giai đoạn 6).
- Xem lại khi: có producer hoặc consumer ngoài monorepo (cân nhắc schema registry); một topic có consumer chỉ cần một phần
  nhỏ loại event mà đọc thừa thành đáng kể; có service bên ngoài cluster gọi thẳng vào service nội bộ.
