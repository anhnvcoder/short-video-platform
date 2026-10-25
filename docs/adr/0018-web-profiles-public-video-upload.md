# 0018. Giai đoạn 5b phần B: handle không đổi và tên hiển thị ở user-service, danh sách video theo tác giả, route công khai `GET /public/videos/{id}` có rate limit theo IP, upload từ trình duyệt

- Trạng thái: Chấp nhận; contract chốt ngày 2026-10-22, hiện thực và đã kiểm trên máy cùng ngày (mục "Kết quả phần B");
  ngưỡng LCP của Lighthouse chưa đạt, chấp nhận ở phần B (§10); §9 (CORS toàn cục của MinIO) bị thay một phần bởi
  [0022](0022-local-object-store-minio-replacement.md) (CORS theo bucket trên RustFS, cùng origin web)
- Ngày: 2026-10-22

## Bối cảnh

- [ADR-0016](0016-web-client.md) §11 chỉ chốt khung của phần B: upload XHR, `/v/:id` công khai có Open Graph, hồ sơ tối
  thiểu và "Video của tôi", CORS MinIO đúng origin web, Lighthouse. Phần B cần backend mới ở ba service và gateway, nên ADR
  này chốt contract trước khi viết code: RPC, field, REST, mã lỗi, giới hạn, lớp rate limit, route web. Code của service,
  gateway và web làm theo các mục dưới đây; chỗ nào thiếu thì sửa ADR trước.
- Hiện trạng ảnh hưởng tới thiết kế:
  - user-service chỉ giữ email, hash mật khẩu và follow. Không có gì hiển thị được thay cho người dùng: email là dữ liệu
    riêng (JWT-8), feed chỉ có `author_id`, nên web phần A chỉ vẽ avatar màu (ADR-0016 §8).
  - video-service chỉ đọc từng video (`GetVideo`, cần caller); không có danh sách theo tác giả. Video chưa `READY` chỉ tác
    giả thấy (UP-3).
  - Mọi route trừ `/auth/*` cần Bearer; mọi RPC trừ `Register`, `Login`, `Refresh`, `Logout` cần caller (`x-user-id`,
    [ADR-0006](0006-contract-ids-and-event-envelope.md) §5). Link chia sẻ mở từ app chat cho người chưa đăng nhập cần một
    đường đọc không xác thực.
  - Gateway ghép `stats` bằng một `GetStats` cho cả trang, hạn 100 ms, không retry
    ([ADR-0009](0009-engagement-feed-stage2b.md) §9); feed p99 < 150 ms ([architecture §2](../architecture.md)).
  - Upload: presigned POST hạn 15 phút, ≤ 500 MiB, tối đa 3 video `UPLOADING` tạo trong 15 phút mỗi user (`TOO_MANY_UPLOADS`),
    job dọn chuyển video bỏ dở sang `FAILED` sau 1 giờ ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §5).
    MinIO community chỉ có CORS toàn cục `MINIO_API_CORS_ALLOW_ORIGIN`, mặc định `*` (threat model WEB-10).
  - Thiết kế ở `web/design/`: hồ sơ có tên hiển thị, `@handle`, nút theo dõi, lưới video có lượt xem và thời lượng (M35–M37,
    D10); "Video của tôi" có nhãn trạng thái và tiến độ tải (M33–M34, D09); trang chia sẻ M38–M40, D04, D11; luồng tải lên
    M20–M32, D05–D06. Thiết kế không có ô handle ở form đăng ký hay màn đổi tên hiển thị.
- Ràng buộc: contract chỉ **thêm** field và RPC (`buf breaking` sạch); `make smoke`, các diễn tập, k6 và seed e2e chạy không
  đổi; không thêm dependency Go, gói npm chỉ trong danh sách ADR-0016 §10; máy 16 GB.

## Kiểm chứng (đã kiểm ngày 2026-10-22)

| Kiểm gì | Nguồn | Kết quả |
| --- | --- | --- |
| Bit ngẫu nhiên của UUIDv7 trong Go | `$(go env GOROOT)/src/uuid/uuid.go` (go1.27.2), `NewV7` | 48 bit đầu là mili giây; 12 bit `rand_a` là phần lẻ dưới mili giây, tăng đơn điệu trong một process; byte 8–15 đọc từ `crypto/rand` (trừ 2 bit variant). 12 ký tự hex của nhóm cuối dạng chuẩn là byte 10–15: 48 bit ngẫu nhiên, không có phần thời gian |
| CORS của MinIO | `internal/config/api/api.go` của MinIO (<https://raw.githubusercontent.com/minio/minio/master/internal/config/api/api.go>) | `MINIO_API_CORS_ALLOW_ORIGIN` mặc định `*`; giá trị tách bằng dấu phẩy (`strings.Split(corsList, ",")`), không bỏ khoảng trắng; có phần tử rỗng (`a,,b`, phẩy cuối) thì cấu hình lỗi `invalid cors value` |
| XHR có listener upload thì có preflight | XMLHttpRequest Standard (<https://xhr.spec.whatwg.org/>), `send()` bước 5–6 và ghi chú ở §3.5 | "Registering one or more event listeners on an XMLHttpRequestUpload object will result in a CORS-preflight request": storage phải trả lời `OPTIONS` với `Access-Control-Allow-Origin` là origin của web |
| Kiểu MIME của playlist HLS | RFC 8216 §4 (<https://www.rfc-editor.org/rfc/rfc8216>) | Content-Type phải là `application/vnd.apple.mpegurl` hay `audio/mpegurl` |
| Thẻ Open Graph cho video | <https://ogp.me/> | `og:video` là URL của video, có cùng thuộc tính con với `og:image` (`og:video:type`, `og:video:secure_url`); `video.other` là một `og:type` |
| Cache chung và `Authorization` | RFC 9111 §3.5 (<https://www.rfc-editor.org/rfc/rfc9111#section-3.5>) | Cache chung không dùng response của request có `Authorization` cho request khác, trừ khi response có `public`, `must-revalidate` hay `s-maxage` |
| 404 bị cache theo heuristic | RFC 9110 §15.1, §15.5.5; RFC 9111 §4.2.2 | 404 là mã "heuristically cacheable": thiếu `Cache-Control` thì cache được tự đặt hạn; tài liệu khuyên server gửi chỉ thị rõ nếu không muốn bị cache |

## 1. Handle

### Các lựa chọn

#### A. Handle duy nhất, chọn lúc đăng ký, không đổi được

- Được: link hồ sơ `/u/{handle}` ổn định; không cần bảng lịch sử handle hay chuyển hướng handle cũ; không ai lấy lại được
  handle người khác vừa bỏ để mạo danh qua link cũ.
- Mất: gõ sai lúc đăng ký thì phải giữ.

#### B. Handle đổi được

- Mất: link cũ gãy, hoặc cần bảng chuyển hướng; handle vừa bỏ bị người khác lấy; thêm RPC và lỗi.

#### C. Không có handle, chỉ tên hiển thị và id

- Mất: URL hồ sơ là UUID; tên hiển thị trùng nhau, không có định danh công khai để phân biệt hai người cùng tên.

### Quyết định

Chọn **A**, handle không đổi được ở 5b.

**Dạng người chọn:** sau khi chuẩn hoá, handle phải khớp `^[a-z][a-z0-9_]{2,29}$` (3–30 ký tự: một chữ thường, rồi chữ
thường, số hay `_`) và **không** khớp `^u_[0-9a-f]{12}$` (dạng sinh tự động, bên dưới).

- Chuẩn hoá: `strings.TrimSpace`, rồi hạ chữ thường **chỉ cho `A`–`Z`**; ký tự ngoài ASCII giữ nguyên nên làm handle sai
  dạng. Không dùng hạ chữ thường Unicode: `strings.ToLower` biến dấu Kelvin `K` (U+212A) thành `k`, tức hai chuỗi khác
  nhau thành cùng một handle.
- Vì sao chỉ ASCII: handle nằm trong URL và được gõ lại bằng tay; Unicode mở đường cho ký tự trông giống nhau (`а` Kirin và
  `a` Latin) và cần chuẩn hoá NFKC, tức thêm dependency.
- Không có danh sách handle cấm (`admin`, `support`, `svp`): chấp nhận ở lab (WEB-17).
- Rỗng sau khi trim, kể cả không gửi field, nghĩa là **không gửi**: service sinh handle.
- Ca biên: `Alice` → `alice`; `bob` có khoảng trắng hai đầu → `bob`; `_bob`, `ab` (2 ký tự), 31 ký tự, `bób`,
  `u_0123456789ab` (cả `U_0123456789AB`) → sai dạng; 30 ký tự, `u_bob`, `u_0123456789abc` (13 hex) → hợp lệ.

**Dạng sinh tự động:** `u_` + 12 ký tự hex cuối của `user_id`. Ví dụ `01928c6e-7b3a-7cde-8f01-23456789abcd` →
`u_23456789abcd`.

- 12 ký tự đó là 48 bit từ `crypto/rand` (mục Kiểm chứng), không phải phần thời gian: hai user tạo cùng mili giây vẫn khác
  handle.
- Dạng người chọn cấm đúng mẫu này, nên handle người chọn không bao giờ trùng handle sinh; trùng chỉ có thể xảy ra giữa hai
  handle sinh. Một lần `Register` trùng với N handle sinh đã có với xác suất N / 2^48 (một triệu user: khoảng 3,6 × 10⁻⁹).
- Trùng (vi phạm `users_handle_key` khi client không gửi handle): service tạo `user_id` mới (UUIDv7 mới, dùng lại hash mật
  khẩu đã tính) và chèn lại, tối đa **3 lần chèn**. Client không gửi handle không bao giờ nhận lỗi về handle; hết 3 lần (không
  xảy ra trong thực tế) thì `INTERNAL`.
- Dạng sinh cũng khớp regex chung `^[a-z][a-z0-9_]{2,29}$`, nên tra cứu và CHECK của database chỉ cần một regex.

**Lưu trữ** (migration mới của user-service, có `Down` bỏ hai cột):

| Cột | Kiểu và ràng buộc | Ghi chú |
| --- | --- | --- |
| `handle` | `text NOT NULL`, `CONSTRAINT users_handle_key UNIQUE (handle)`, `CONSTRAINT users_handle_check CHECK (handle ~ '^[a-z][a-z0-9_]{2,29}$')` | Lưu dạng đã chuẩn hoá, nên ràng buộc unique là so sánh không phân biệt hoa thường, như `users_email_key`. Ràng buộc có tên để service đổi vi phạm sang đúng lỗi |
| `display_name` | `text NOT NULL`, `CONSTRAINT users_display_name_check CHECK (char_length(display_name) BETWEEN 1 AND 50)` | Lớp thứ hai; luật đầy đủ ở mục 2 do service kiểm |

- **Backfill** user cũ trong cùng migration: thêm hai cột cho phép `NULL`; `UPDATE users SET handle = 'u_' || right(id::text,
  12), display_name = 'u_' || right(id::text, 12)`; rồi `SET NOT NULL` và thêm ràng buộc. Cùng dạng với handle sinh lúc đăng
  ký, nên người dùng cũ không khác người đăng ký mới mà không chọn handle. goose chạy mỗi migration trong một transaction: hai
  user cũ trùng 12 hex cuối (vài nghìn user ở lab: khoảng 10⁻⁸) thì migration lỗi cả khối và không đổi gì; sửa tay một dòng
  rồi chạy lại.
- **Lúc rollout**, instance của bản trước còn phục vụ trong khi migration chạy, và câu `INSERT` của nó không có hai cột mới.
  `DEFAULT` của cột không đọc được `id` của dòng, nên migration thêm trigger `BEFORE INSERT` (`users_fill_profile`) điền
  handle `u_` + 12 hex cuối và tên hiển thị bằng handle khi `INSERT` bỏ trống, trước khi `NOT NULL` được kiểm; không có
  trigger thì mọi lần đăng ký trong lúc đó lỗi. Bản mới luôn gửi cả hai cột nên trigger không đụng dòng của nó. `Down` bỏ
  trigger, hàm, rồi hai cột.

**Lỗi:**

- Sai dạng → `INVALID_ARGUMENT`, reason **`INVALID_HANDLE`** → 400.
- Handle người chọn đã có chủ → `ALREADY_EXISTS`, reason **`HANDLE_ALREADY_TAKEN`** → 409 (khác
  `EMAIL_ALREADY_REGISTERED`). Trùng cả email lẫn handle: reason theo ràng buộc Postgres báo, không chốt cái nào; client xử
  lý được cả hai.
- `Register` kiểm theo thứ tự email, mật khẩu, handle, tên hiển thị, **trước khi** hash mật khẩu, nên input sai không tốn
  một lần argon2id.
- Hai `Register` song song cùng handle: ràng buộc unique quyết, một thành công, một `HANDLE_ALREADY_TAKEN`; không kiểm rồi
  mới chèn.

**Web luôn gửi handle:** ô bắt buộc ở form đăng ký (cùng kiểu ô email của `AuthForm`), kiểm bằng zod cùng luật (trim, hạ
`A`–`Z`, hai regex), lỗi `INVALID_HANDLE` và `HANDLE_ALREADY_TAKEN` hiện ở ô handle như lỗi email đã dùng (M19). API vẫn nhận
thiếu handle để client cũ chạy không đổi.

## 2. Tên hiển thị

### Các lựa chọn

#### A. Đổi được, mặc định bằng handle, không phát event

- Được: đăng ký không thêm ô bắt buộc; client cũ không phải gửi; không có bản sao nào phải đồng bộ.
- Mất: người không đổi tên thì hiện handle; user cũ hiện `u_…` tới khi đổi tên.

#### B. Bắt buộc nhập lúc đăng ký

- Mất: client cũ (smoke, k6, seed e2e) phải đổi; form đăng ký của thiết kế không có ô này.

#### C. Phát event đổi hồ sơ để service khác giữ bản sao tên

- Được: feed có tên mà không gọi user-service.
- Mất: thêm event, consumer, bảng bản sao và việc đồng bộ khi đổi tên; chưa service nào cần (gateway ghép tên lúc đọc, mục 5).

### Quyết định

Chọn **A**.

- **Luật** (user-service kiểm, ở cả `Register` lẫn `UpdateDisplayName`): UTF-8 hợp lệ; `strings.TrimSpace`; sau đó **1–50
  rune** (`utf8.RuneCountInString`); không chứa:
  - ký tự điều khiển Cc: U+0000–U+001F (gồm NUL, `\t`, `\n`, `\r`) và U+007F–U+009F (gồm U+0085);
  - U+2028, U+2029 (ngắt dòng, ngắt đoạn);
  - ký tự định dạng Cf, trong đó có ký tự định hướng bidi U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069: chúng
    đảo chiều phần chữ đứng sau, nên một tên bắt đầu bằng U+202E làm đảo cả `@handle` và thời gian hiện cạnh nó (WEB-18).
    Cf còn gồm ký tự vô hình như U+200B, U+2060, U+FEFF, và tag character U+E0020–U+E007F, nên cờ vùng dạng chuỗi tag
    (cờ Scotland 🏴󠁧󠁢󠁳󠁣󠁴󠁿) bị từ chối;
  - các code point default-ignorable khác (`Other_Default_Ignorable_Code_Point`: Hangul filler U+115F, U+1160, U+3164,
    U+FFA0, U+034F) và ô Braille trống U+2800: chúng hiện ra như không có gì, nên một tên trông rỗng vẫn qua được bước
    trim.

  Ngoại lệ: ZWJ U+200D (Cf) và variation selector được nhận vì emoji ghép (gia đình, dạng emoji của ký hiệu) cần chúng,
  nhưng không tính là ký tự hiện: tên phải có ít nhất một ký tự hiện không phải khoảng trắng, nên tên chỉ gồm ZWJ bị từ
  chối. Mọi ký tự khác được nhận: dấu tiếng Việt, emoji, khoảng trắng ở giữa. Luật này chặt hơn bản chốt ban đầu (chỉ Cc,
  U+2028/U+2029 và bidi): ký tự vô hình khác cũng làm được tên trông rỗng hay giống tên người khác. Mô tả trong
  `user_service.proto`, `openapi.yaml` (schema `DisplayName`) và bước kiểm trước ở web vẫn theo bản cũ; ở đó tên có ký tự
  vô hình qua được kiểm của web rồi bị user-service trả 400 `INVALID_DISPLAY_NAME`, sửa cho khớp ở phần C.
- Lưu nguyên văn sau khi trim, không escape: nơi hiển thị phải render như text (WEB-1).
- Service **không chuẩn hoá Unicode** (thư viện chuẩn Go không có NFC; `golang.org/x/text` chỉ là dependency gián tiếp).
  Web chuẩn hoá NFC (`String.prototype.normalize("NFC")`) trước khi gửi, để chữ Việt gõ ở dạng tổ hợp (bàn phím macOS có thể
  gửi dạng này) không bị đếm gấp đôi: "Phương" là 6 rune ở NFC, 8 rune ở NFD.
- `Register`: rỗng sau khi trim, kể cả không gửi → bằng handle (handle đã chuẩn hoá, hay handle vừa sinh).
  `UpdateDisplayName`: rỗng sau khi trim → lỗi.
- Lỗi → `INVALID_ARGUMENT`, reason **`INVALID_DISPLAY_NAME`** → 400.
- Không ghi tên hiển thị vào log (chỉ `user_id`), như email (JWT-8): người dùng có thể đặt tên thật.
- Đổi bằng `PATCH /me` `{"display_name": "..."}`, lớp rate limit `write`, trả hồ sơ sau khi đổi. Không event.
- Ca biên phải có test: toàn khoảng trắng; 50 và 51 rune tiếng Việt có dấu (NFC); `\n`, `\t`, NUL, U+0085, U+2028, U+202E;
  U+200B, U+2800, Hangul filler; emoji ghép bằng ZWJ (nhận) và tên chỉ có ZWJ (từ chối); UTF-8 hỏng (`\xff`).

## 3. API hồ sơ

### Các lựa chọn

#### A. Ba RPC: đọc nhiều hồ sơ theo id không cần caller, đọc theo handle cần caller, đổi tên cần caller

- Được: một lời gọi cho tác giả của cả trang (mục 5), dùng được cả ở route công khai; đọc theo handle luôn có caller nên luôn
  tính được `followed_by_me`; user-service không cần chế độ "caller tuỳ chọn".
- Mất: `GET /me` dùng chung RPC đọc nhiều hồ sơ, nên theo luật không retry của nó (bên dưới).

#### B. Thêm một RPC `GetMe` riêng, retry được

- Mất: thêm một RPC chỉ để đọc một hồ sơ mà RPC đọc nhiều đã làm được.

#### C. Đọc theo handle không cần caller, `followed_by_me` khi có caller

- Mất: cần chế độ caller tuỳ chọn ở user-service cho một route vốn cần Bearer (chỉ `/v/{id}` công khai, mục 7).

### Quyết định

Chọn **A**. Contract ở `proto/svp/user/v1/user_service.proto`:

- `RegisterRequest` thêm `handle = 3`, `display_name = 4` (string; rỗng sau khi trim = không gửi). `RegisterResponse` giữ
  nguyên (đọc handle sinh bằng `GET /me`).
- `Profile { user_id = 1; handle = 2; display_name = 3; }`. **Không bao giờ có email.**
- **`GetProfiles(user_ids)` → `profiles`**: **không cần caller** (thêm vào `PublicMethods`). Tối đa 50 id, mỗi id phải là
  UUID dạng chuẩn. id không có user bị bỏ qua (không lỗi), id lặp trả một lần, thứ tự không chốt (người gọi khớp theo
  `user_id`); danh sách rỗng trả rỗng, không đọc database. Lỗi: `INVALID_ARGUMENT` `TOO_MANY_USER_IDS` (> 50),
  `INVALID_USER_ID`.
- **`GetProfileByHandle(handle)` → `profile`, `followed_by_me`**: **cần caller**. Handle chuẩn hoá như mục 1, nên tra cứu
  không phân biệt hoa thường. `followed_by_me` = caller có cạnh follow tới user đó, đọc bằng một câu `EXISTS` trên `follows`;
  caller xem chính mình → false. Lỗi: `NOT_FOUND` `USER_NOT_FOUND` cả khi không ai có handle đó lẫn khi chuỗi không thể là
  handle (không khớp regex chung); ca sau không đọc database. Không trả `INVALID_ARGUMENT` cho handle sai dạng: với người tra
  cứu, "không thể có" và "không có" là một câu trả lời.
- **`UpdateDisplayName(display_name)` → `profile`**: **cần caller**, đổi tên của chính caller. **Idempotent**: đặt lại cùng
  giá trị không đổi gì. Lỗi: `INVALID_ARGUMENT` `INVALID_DISPLAY_NAME`; `NOT_FOUND` `USER_NOT_FOUND` (token còn hạn mà tài
  khoản không còn, ví dụ database dựng lại).

REST (gateway, mọi route cần Bearer, lớp theo `user_id`):

| Route | Lớp | RPC | Trả |
| --- | --- | --- | --- |
| `GET /me` | `read` | `GetProfiles([caller])`, hạn chung 3 s | 200 `Profile`; không có hồ sơ → 404 `USER_NOT_FOUND` |
| `PATCH /me` | `write` | `UpdateDisplayName` | 200 `Profile`; body `{"display_name": "..."}` (`application/json`, field lạ → 400 `INVALID_JSON`, > 64 KiB → 413); thiếu hay rỗng thì chuyển cho user-service, nên là 400 `INVALID_DISPLAY_NAME` |
| `GET /profiles/{handle}` | `read` | `GetProfileByHandle` | 200 `UserProfile` (`user_id`, `handle`, `display_name`, `followed_by_me`); 404 `USER_NOT_FOUND`. Gateway chuyển nguyên `{handle}` cho user-service |

`GET /me` không trả email: web không cần, và email ra khỏi response nào cũng là thêm một chỗ phải che (JWT-8).

## 4. Danh sách video theo tác giả

### Các lựa chọn

#### A. RPC ở video-service, keyset theo (`created_at`, `video_id`)

- Được: video-service sở hữu trạng thái video, nên luật "chỉ tác giả thấy video chưa `READY`" nằm cùng chỗ với `GetVideo`;
  có cả video `UPLOADING`, `PROCESSING`, `FAILED` cho "Video của tôi".
- Mất: thêm một index ở `svp_video`.

#### B. Ở feed-service (bản sao video `READY`)

- Mất: bản sao chỉ có video `READY`, không phục vụ được "Video của tôi"; hai nguồn cho cùng một danh sách.

#### C. Phân trang bằng `OFFSET`

- Mất: lệch trang khi có video mới ([ADR-0005](0005-feed-fan-out-on-write.md)).

### Quyết định

Chọn **A**. Contract ở `proto/svp/video/v1/video_service.proto`:

- **`ListAuthorVideos(author_id, page_size, page_token)` → `videos`, `next_page_token`**: **cần caller**. Caller là tác
  giả → video mọi trạng thái; người khác → chỉ `READY` (cùng luật `GetVideo`, UP-3). Tác giả không có video, hay `author_id`
  không có user (video-service không biết user) → trang rỗng. Lỗi: `INVALID_ARGUMENT` `INVALID_AUTHOR_ID`,
  `INVALID_PAGE_SIZE`, `INVALID_PAGE_TOKEN`.
- **Thứ tự:** `created_at DESC, id DESC`. Danh sách của tác giả trộn trạng thái, mà video chưa `READY` không có
  `published_at`. Người khác cũng theo `created_at`, để một câu SQL và một dạng cursor phục vụ cả hai: video chuyển `READY`
  trong lúc phân trang hiện ở đúng vị trí lúc tạo, không làm lặp hay mất item của trang sau (đã qua vị trí đó thì nó hiện ở
  lần tải lại).
- **Index:** `(author_id, created_at DESC, id DESC)` (migration mới của video-service, có `Down`).
- **Cursor:** cùng định dạng [architecture §8.3](../architecture.md#83-phân-trang-feed) (base64url không padding của bytes
  protobuf mã hoá tay: field 1 varint micro giây Unix, field 2 `video_id` 16 byte), ở đây field 1 là `created_at`; mã hoá
  bằng gói chung `internal/pagetoken`. Dài quá 64 ký tự thì từ chối trước khi giải mã; hỏng → `INVALID_PAGE_TOKEN`. **Không
  ký:** quyền xem đến từ `author_id` của request và caller, không từ token, nên token sửa tay hay lấy của người khác chỉ đổi
  vị trí đọc trong dữ liệu người gọi vốn được xem (PG-1).
- **`page_size`:** 0 → 10, > 50 → 50, âm → `INVALID_PAGE_SIZE` (như feed, AIP-158). Web hỏi 18 cho lưới (3 cột ở mobile, 6 ở
  desktop). Đọc `page_size + 1` dòng để biết còn trang sau.

REST (Bearer, lớp `read`), query `cursor`, `page_size` như feed, trả `VideoPage` (`items`, `next_cursor`; trang rỗng là
`[]`):

| Route | Việc |
| --- | --- |
| `GET /users/{user_id}/videos` | `ListAuthorVideos(author_id = user_id)`: video `READY` của người đó; `user_id` là chính caller thì như `/me/videos` |
| `GET /me/videos` | `ListAuthorVideos(author_id = caller)`: mọi video của caller, mọi trạng thái |

Item là schema `Video` của openapi (`status`, `duration_ms`, `playlist_url`/`thumbnail_url` khi `READY`) kèm `author` và
`stats` như feed (mục 5). `GetStats` hỏi cho mọi id của trang; video chưa `READY` có số đếm 0.

## 5. Tác giả trong response

### Các lựa chọn

#### A. Gateway ghép bằng một `GetProfiles` mỗi trang, song song với `GetStats`, hạn 100 ms, không retry, vắng khi chậm

- Được: cùng cách với `stats` (ADR-0009 §9): một lời gọi cho cả trang; chạy song song nên khi cả hai khoẻ độ trễ của trang
  gần như không tăng; user-service chậm không làm feed lỗi.
- Mất: user-service chậm thì item thiếu tên; user-service vào đường đọc feed.

#### B. feed-service giữ bản sao hồ sơ dựng từ event

- Mất: event mới, consumer, bảng bản sao; danh sách theo tác giả và route công khai (từ video-service) vẫn phải ghép riêng.

#### C. Gọi tuần tự sau `GetStats`, hay có retry

- Mất: cộng thêm độ trễ; ngân sách 100 ms không chứa nổi một lần thử lại (ADR-0010 §4).

### Quyết định

Chọn **A**.

- Áp cho item của `GET /feed/following`, `GET /feed/explore`, `GET /users/{user_id}/videos`, `GET /me/videos`, và video
  của `GET /videos/{video_id}`, `GET /public/videos/{video_id}`.
- **Một** `GetProfiles` với các `author_id` **đã khử trùng** của trang (trang rỗng: không gọi), chạy **song song** với
  `GetStats`; mỗi lời gọi có hạn **100 ms** riêng (`statsTimeout`), không retry. Lỗi hay quá hạn → mọi item vắng `author`, log
  WARN `served without authors` (có `grpc_code`; dòng WARN của `GetStats` cũng bỏ chữ "feed" ở đầu, thành
  `served without stats`, vì giờ dùng cho cả danh sách và một video); id user-service không trả → item đó vắng `author`. Lỗi này không đi qua
  bảng [§8.4](../architecture.md#84-mã-lỗi-grpc-sang-http-ở-gateway).
- `author` = `{user_id, handle, display_name}` (schema `Profile`). Mọi field mới là tuỳ chọn: client cũ không vỡ.
- **Gateway, retry và breaker** (ADR-0010 §4):
  - `GetProfiles` **không** vào danh sách retry `UNAVAILABLE`, và breaker của user-service **không tính** `DEADLINE_EXCEEDED`
    của nó (như `GetStats` ở breaker của engagement-service): user-service chậm mà còn sống không được mở breaker rồi làm
    login, follow trả 503. `UNAVAILABLE` mức kết nối vẫn tính; breaker mở thì `GetProfiles` lỗi ngay, trang vẫn trả, không
    `author`, không chờ 100 ms.
  - Vào danh sách retry `UNAVAILABLE` (idempotent): `GetProfileByHandle`, `UpdateDisplayName`, `ListAuthorVideos`,
    `GetPublicVideo`.
- `GET /videos/{video_id}` thêm `author` và `stats` (trang `/v/{id}` khi đã đăng nhập cần `liked_by_me`): `GetVideo` trước,
  rồi `GetProfiles` và `GetStats` song song cho một id.
- `GET /me` gọi `GetProfiles([caller])` với hạn chung 3 s: đây là dữ liệu chính chứ không phải phần ghép, nên lỗi đi qua bảng
  §8.4, không có hồ sơ → 404 `USER_NOT_FOUND`. Không retry `UNAVAILABLE` (luật của method, phương án A mục 3): chấp nhận, web
  coi lỗi là "chưa biết tên" và chỉ vẽ avatar.

## 6. Route công khai `GET /public/videos/{video_id}`

### Các lựa chọn

#### A. Route riêng `/public/...`, không đọc Bearer, RPC riêng chỉ trả `READY`, schema riêng

- Được: luật của `GET /videos/{id}` (tác giả thấy video chưa `READY`) không đổi; route không xác thực tách hẳn nên rate
  limit, cache và schema của nó riêng; response không có `liked_by_me` vô nghĩa với khách.
- Mất: thêm một route, một RPC, một schema.

#### B. `GET /videos/{id}` nhận cả request không token cho video `READY`

- Mất: một route vừa xác thực vừa không; nhánh kiểm token dễ thành lỗ (token sai thì 401 hay coi như khách?); rate limit
  phải chọn theo IP hay theo user tuỳ request; cùng schema thì `liked_by_me` vô nghĩa với khách.

#### C. Web đọc bằng một tài khoản dịch vụ

- Mất: một credential dài hạn nằm ở web; mọi khách chung một user ở rate limit; log lẫn danh tính.

### Quyết định

Chọn **A**.

- **Không đọc Bearer:** route không qua `RequireAuth`; header `Authorization`, kể cả token sai, bị bỏ qua, không 401.
- **Thứ tự:** rate limit lớp `public` theo IP client **trước** mọi lời gọi service; `GetPublicVideo`; rồi `GetProfiles` và
  `GetStats` song song (100 ms), `GetStats` **không** gửi `x-user-id`.
- **video-service `GetPublicVideo(video_id)` → `video`**: **không cần caller** (danh sách method công khai của
  `callerid.UnaryServerInterceptor`, cùng Health), bỏ qua `x-user-id`. Chỉ trả video `READY`. `video_id` không phải UUID dạng
  chuẩn, không có video, video `UPLOADING`/`PROCESSING`/`FAILED` → **cùng** `NOT_FOUND` `VIDEO_NOT_FOUND`, cùng message với
  `GetVideo`. id sai dạng vẫn bị từ chối trước khi chạm database, nhưng không thành `INVALID_ARGUMENT`: route công khai chỉ có
  một câu trả lời cho "không xem được".
- **engagement-service `GetStats` thành caller tuỳ chọn**; các RPC khác vẫn cần caller:
  - không có `x-user-id` → không caller: `liked_by_me` false cho mọi video, không đọc bảng `likes`;
  - có `x-user-id` → phải đúng một giá trị UUID dạng chuẩn như RPC cần caller, sai → `UNAUTHENTICATED`
    `UNAUTHENTICATED_CALLER`. Header sai dạng chỉ đến từ lỗi ở gateway hay kẻ gọi thẳng gRPC (IN-2), nên không âm thầm coi là
    khách;
  - `callerid.UnaryServerInterceptor` hiện có hai chế độ (cần caller; method công khai bỏ qua `x-user-id`). Thêm chế độ thứ
    ba, **caller tuỳ chọn**, cho một danh sách method riêng, đúng luật trên, để mọi service đọc caller ở một chỗ.
- RPC không cần caller không nới IN-2: chúng chỉ trả thứ ai cũng xem được qua route công khai (hồ sơ, video `READY`, số đếm
  không `liked_by_me`), còn kẻ đã gọi thẳng được gRPC vốn đặt được `x-user-id` bất kỳ.
- **Một 404:** mọi ca không xem được là 404 `VIDEO_NOT_FOUND` cùng `detail`. Path không phải UTF-8 hợp lệ vẫn là 400
  `INVALID_UTF8` của gateway như mọi route.
- **Response** (schema `PublicVideo`): các field của video `READY` như `FeedItem` (`video_id`, `author_id`, `title`,
  `duration_ms`, `playlist_url`, `thumbnail_url`, `published_at`), `author` (tuỳ chọn), `stats` là `PublicVideoStats`
  (`view_count`, `like_count`, **không** `liked_by_me`; tuỳ chọn).
- **Rate limit lớp `public`** (thêm vào bảng lớp của ADR-0010 §2):

  | Lớp | Route | Khoá | Redis tốt | Redis lỗi |
  | --- | --- | --- | --- | --- |
  | `public` | `GET /public/videos/{video_id}` | IP | 120/phút, burst 60 | đóng mềm: 60/phút, burst 30 |

  Lý do: một lượt mở trang chia sẻ là một lời gọi gateway (web dùng chung kết quả cho `generateMetadata` và trang); người
  thật mở vài link mỗi phút, nên 120/phút đủ cho nhiều người sau một NAT, burst 60 cho cả nhóm chat mở cùng một link cùng lúc
  cộng bot xem trước link. Script dò hay cào bị giữ ở 2 request/giây mỗi IP. **Đóng mềm** như `register`, `login`, `refresh`:
  route không xác thực không bao giờ không giới hạn, kể cả khi Redis lỗi (RL-2); ngưỡng dự phòng bằng nửa như các lớp khác.
  Vượt ngưỡng → 429 `RATE_LIMITED` có `Retry-After`; metric `svp.ratelimit.decisions` có `class="public"`.
- **IP mà gateway thấy** (như ADR-0016 §4): ở compose (0 hop tin cậy) mọi khách xem qua web chung **một** bucket, là địa
  chỉ container `web`, tức 120/phút cho cả lab; `curl` thẳng tới gateway có bucket riêng. Ở k3d (phần C) BFF chuyển nguyên
  `X-Forwarded-For`, gateway với 1 hop tin cậy đọc đúng IP client (WEB-8).
- **`Cache-Control`:** 200 → `public, max-age=30`; 404, 429 và 5xx của route → `no-store`.
  - Vì sao `public`: response như nhau với mọi người (không `liked_by_me`, không phụ thuộc `Authorization`); số đếm vốn trễ
    tới khoảng một phút. CDN hay cache chung ở giai đoạn 7 đỡ được đợt mở link dồn dập. RFC 9111 §3.5 cấm cache chung dùng
    lại response của request có `Authorization` trừ khi có `public`, mà route này bỏ qua `Authorization`.
  - Vì sao `no-store` cho 404: 404 bị cache theo heuristic khi thiếu chỉ thị (RFC 9110 §15.5.5), mà video đang `PROCESSING`
    thành `READY` sau vài phút và không được kẹt 404 trong cache. 429 thuộc về từng client.
  - Ở lab chưa có cache nào giữa web và gateway; `fetch` ở server của Next 16 không cache theo mặc định.
- HTML của trang `/v/{id}` vẫn `private, no-store` như mọi trang (ADR-0016 §6): mỗi response mang nonce CSP riêng, cache lại
  HTML là dùng lại nonce.

## 7. Route web

| Route | Đăng nhập | Việc |
| --- | --- | --- |
| `/upload` | cần | tải lên (mục 8), M20–M32, D05–D06 |
| `/me` | cần | "Video của tôi" (M33–M34, D09): hồ sơ của mình (avatar, tên hiển thị, `@handle`), mọi video mọi trạng thái từ `GET /me/videos`, đổi tên hiển thị (Server Action gọi `PATCH /me`), đăng xuất |
| `/u/{handle}` | cần | hồ sơ người khác (M35–M37, D10) từ `GET /profiles/{handle}` rồi `GET /users/{user_id}/videos`; nút theo dõi theo `followed_by_me`, `aria-pressed` |
| `/v/{id}` | **không** | trang chia sẻ (M38–M40, D04, D11): SSR + Open Graph |

- **Chỉ `/v/{id}` công khai.** Hồ sơ cần đăng nhập: link chia sẻ của sản phẩm là link video; hồ sơ công khai thêm một route
  không xác thực và một nguồn liệt kê người dùng mà chưa có nhu cầu.
- `/u/{handle}`: web hạ `A`–`Z`; khác `{handle}` thì chuyển hướng về dạng chữ thường; không khớp `^[a-z][a-z0-9_]{2,29}$` hay
  404 `USER_NOT_FOUND` → trang 404 riêng của hồ sơ; handle của chính mình → chuyển hướng `/me`.
- `/v/{id}`: `{id}` phải là UUID dạng chuẩn, sai → 404 mà không gọi gateway.
  - Không có cookie phiên → `GET /public/videos/{id}` (không Bearer, chuyển `X-Forwarded-For` như BFF), không chạm Redis.
  - Có phiên → `GET /videos/{id}` bằng token của phiên (có `liked_by_me`), chỉ hiện khi `READY`: tác giả xem video chưa
    `READY` của mình ở `/me`. Hai nhánh cùng một trang 404 cho mọi ca không xem được.
  - 429 → màn M40 đếm ngược theo `Retry-After`; lỗi khác → màn lỗi chung (M41).
  - Chưa đăng nhập: like, theo dõi mở lời mời đăng nhập tới `/login?next=/v/{id}`, không ghi lượt xem. Đã đăng nhập: like,
    theo dõi, lượt xem 2 s như feed.
- **Thẻ meta** của `/v/{id}` (`generateMetadata`, dùng chung một lần gọi gateway với trang qua `cache()` của React):

  | Thẻ | Giá trị |
  | --- | --- |
  | `<title>`, `og:title` | `title` của video |
  | `description`, `og:description` | `<display_name> (@<handle>)`; vắng `author` thì bỏ thẻ |
  | `og:type` | `video.other` |
  | `og:url` | `APP_ORIGIN` + `/v/{id}` |
  | `og:image` | `thumbnail_url` |
  | `og:video`, `og:video:type` | `playlist_url`, `application/vnd.apple.mpegurl` (RFC 8216 §4) |
  | `twitter:card` | `summary_large_image` (thẻ `player` cần một trang nhúng iframe, chưa có) |

  URL media chỉ đặt khi origin bằng `MEDIA_ORIGIN`, sai thì bỏ thẻ đó. Mọi giá trị là text do Next escape; không
  `dangerouslySetInnerHTML` (WEB-1, WEB-18).
- **Proxy `/api/*`** (danh sách cho phép của ADR-0016 §5) thêm: `POST /videos`, `POST /videos/{video_id}/complete`, `GET
  /me`, `GET /me/videos`, `GET /users/{user_id}/videos` (query chỉ `cursor`, `page_size`), `GET /profiles/{handle}` (segment
  phải khớp `^[a-z][a-z0-9_]{2,29}$`, như id phải là UUID chuẩn). **Không** vào proxy: `PATCH /me` (Server Action),
  `GET /public/videos/{video_id}` (chỉ server của web gọi).
- Feed hiện tên hiển thị, `@handle` (link `/u/{handle}`) và thời gian tương đối; vắng `author` thì như phần A (chỉ avatar).
  Nút chia sẻ chép `location.origin` + `/v/{id}`.

## 8. Upload từ trình duyệt

### Các lựa chọn

#### A. XHR tự viết gửi presigned POST hiện có

- Được: `upload.onprogress` cho tiến độ thật, `abort()` để huỷ; không gói mới, backend không đổi.
- Mất: không resume; lỗi giữa chừng thì gửi lại cả file (clip ≤ 3 phút, ≤ 500 MiB).

#### B. `fetch` gửi stream

- Mất: chỉ Chromium có, và không có tiến độ upload thật.

#### C. Multipart hay resumable (Uppy với S3 multipart, tus)

- Mất: gateway phải ký thêm ba thao tác multipart, CORS cần `ExposeHeaders: ETag`, thêm gói; tus cần server riêng, phá thiết
  kế upload thẳng. Là phương án khi cần resume.

### Quyết định

Chọn **A** (thiết kế `web/design/UploadFlow.dc.html`).

- **`UPLOAD_ORIGIN`**, biến mới của web (chỉ server đọc, kiểm như `MEDIA_ORIGIN`): compose và `make web-dev`
  `http://127.0.0.1:9000`; k3d (phần C) `https://s3.svp.localhost:8443`. Thêm vào CSP `connect-src` (khác `MEDIA_ORIGIN` thì
  có cả hai, bằng nhau thì không lặp). Trang `/upload` đọc ở server và truyền xuống component client làm prop: cấu hình công
  khai, không `NEXT_PUBLIC_*`.
- **Kiểm trước khi gửi** (kiểm mềm, `ffprobe` ở media-worker mới là chuẩn):
  - `size` ≤ 524 288 000 byte (500 MiB, bằng `maximum` của openapi) → M21;
  - `file.type` bắt đầu bằng `video/`; rỗng thì đoán theo đuôi: `.mp4` → `video/mp4`, `.mov` → `video/quicktime`, `.webm` →
    `video/webm`; kiểu hay đuôi khác → M22;
  - thời lượng ≤ 180 s, đọc bằng `<video preload="metadata">` trên `URL.createObjectURL` (thu hồi URL sau đó) → M23. Trình
    duyệt không đọc được metadata (codec nó không giải mã, ví dụ HEVC trên Chromium) thì **vẫn cho gửi**: worker quyết;
  - tiêu đề 1–200 ký tự sau khi trim (như video-service) → M26.
- **Gửi:** `POST /api/videos` (`title`, `size_bytes`, `content_type`) → `upload_url`, `form_fields`, `expires_at`. **Kiểm
  `new URL(upload_url).origin === UPLOAD_ORIGIN`** trước khi gửi; sai thì báo lỗi, không gửi byte nào. `FormData`: mọi
  `form_fields` trước, `file` cuối; `XMLHttpRequest` `POST`, không `withCredentials`, không header thêm; `upload.onprogress`
  cho % và tốc độ. Listener upload làm request thành preflight CORS (mục Kiểm chứng), nên MinIO phải trả lời `OPTIONS` (mục 9).
- **Thử lại** lỗi mạng, timeout, 5xx (gồm 503 SlowDown) và 429 của storage: backoff mũ có jitter đầy đủ, chờ
  `random(0, min(8 s, 1 s × 2^n))` với n là số lần đã thử lại (hay `Retry-After` nếu storage gửi), tối đa **3 lần thử lại** (4
  lần gửi). Timeout là 30 s không có sự kiện `progress`; không đặt hạn tổng, vì file 500 MiB trên mạng chậm chạy lâu là hợp lệ.
  `navigator.onLine` false thì chờ sự kiện `online` rồi mới gửi, lúc chờ không tính một lần thử. Hết lượt → lỗi có nút thử lại
  tay (M29).
- **Hạn của form** tính theo đồng hồ của server, không theo đồng hồ máy người dùng (có thể lệch vài phút): thời gian còn lại
  = `expires_at` − header `Date` của response `POST /api/videos`, rồi đếm bằng đồng hồ đơn điệu (`performance.now()`).
  Response không có `Date` dùng được thì lấy đồng hồ máy; form luôn được gửi ít nhất một lần trước khi xét hạn, nên đồng hồ
  sai không gây vòng xin form mới.
- **Form hết hạn:** trước mỗi lần gửi, nếu còn dưới 60 s tới `expires_at` thì xin form mới; storage trả **403** thì coi là form
  hết hạn và xin form mới một lần (403 lần nữa với form mới → lỗi, không lặp). Form mới là **video mới** (`InitUpload` không
  idempotent); video cũ nằm `UPLOADING`, vẫn tính vào 3 form mở trong 15 phút, job dọn chuyển nó sang `FAILED` sau 1 giờ (M27).
- **429 `TOO_MANY_UPLOADS`** của gateway → M24, không thử lại; 429 `RATE_LIMITED` → chờ `Retry-After`. 401 →
  `/login?next=/upload`.
- **Huỷ** = `abort()`, về bước chi tiết. Video còn `UPLOADING` và **vẫn chiếm một trong 3 lượt tải trong 15 phút**; message
  cho người dùng ghi rõ điều này.
- **Xong:** `POST /api/videos/{id}/complete`, thử lại được (idempotent) theo cùng backoff cho lỗi mạng, 5xx; 400
  `UPLOAD_NOT_FOUND`, `UPLOAD_MISMATCH`, `VIDEO_FAILED` → lỗi, không thử lại.
- **Chờ xử lý:** poll `GET /api/videos/{id}`, lần đầu sau 2 s, mỗi lần nhân 1,5, trần 10 s, tới `READY` (M31: link `/v/{id}`
  và "Video của tôi") hay `FAILED` (M32); tạm dừng khi tab ẩn, tiếp khi hiện lại.
- `upload_url` và `form_fields` là credential 15 phút (UP-2): không vào log, toast, message lỗi hay telemetry (WEB-9, WEB-19).
  Trạng thái upload chỉ nằm trong bộ nhớ của tab, không `localStorage`; rời trang khi đang tải thì cảnh báo `beforeunload`.

## 9. CORS của MinIO (WEB-10)

**Bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)** (2026-10-25): store là RustFS, CORS đặt theo bucket bằng `PutBucketCors` ở job `s3-init`
(`uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`, cùng origin web), danh sách toàn cục để rỗng; `http://127.0.0.1:3001` vẫn
không nằm trong danh sách. Phần dưới giữ nguyên như lúc quyết.

- Compose: service `minio` đặt `MINIO_API_CORS_ALLOW_ORIGIN=http://localhost:3001,http://localhost:3002` (web và `web-dev`).
  Dấu phẩy, không khoảng trắng: MinIO không bỏ khoảng trắng quanh từng origin, và phần tử rỗng làm cấu hình lỗi.
- Biến này toàn cục cho mọi bucket (MinIO community không có CORS theo bucket), áp cho cả upload (`POST` vào `uploads`) lẫn
  phát (hls.js tải playlist và segment ở `media` bằng XHR).
- `http://127.0.0.1:3001` **không** nằm trong danh sách: mở web bằng origin đó thì đăng nhập vẫn chạy (ADR-0016 §5), nhưng
  phát video và upload bị CORS chặn. Origin chuẩn là `http://localhost:3001`.
- Kiểm: `OPTIONS` với `Origin: http://evil.example` và `Access-Control-Request-Method: POST` → không có
  `Access-Control-Allow-Origin`; với `Origin: http://localhost:3001` → có đúng origin đó.
- k3d (chart `svp-data`, origin `https://svp.localhost:8443`) làm ở phần C. S3 hay CloudFront ở giai đoạn 7 có CORS theo
  bucket: `POST` cho `uploads`, `GET`/`HEAD` cho `media`.

## 10. Lighthouse

### Các lựa chọn

#### A. `@lhci/cli` chạy local trên stack compose (`make web-lighthouse`)

- Được: đo trang thật có dữ liệu (đăng nhập, video `READY`); gói đã có trong danh sách ADR-0016 §10.
- Mất: không chặn PR; mỗi lần đo phải dựng stack.

#### B. Job CI chạy Lighthouse

- Mất: feed và `/v/{id}` cần gateway và dữ liệu; dựng cả stack trên runner là việc "stack chạy trong CI" mà
  [ADR-0015](0015-cicd-devsecops-stage5.md) §12 đã dời sang giai đoạn 6. Chỉ đo `/login` thì không đo được trang cần đo.

### Quyết định

Chọn **A** ở 5b; chuyển vào CI cùng e2e ở giai đoạn 6 (ADR-0016 §11).

- `make web-lighthouse` trên stack `make up` đang chạy, preset **mobile**, **một lượt mỗi trang** (máy 16 GB): feed `/` (đã
  đăng nhập: script đăng ký user mới, truyền cookie phiên qua `extraHeaders`, không in giá trị) và `/v/{id}` của một video
  `READY` (không đăng nhập). Chrome là Chromium của Playwright đã cài.
- Ngưỡng `assert`: LCP < 2 500 ms, CLS < 0,1, TBT < 200 ms. INP không đo được lúc tải trang; RUM ở phần C.
- Báo cáo ghi vào `web/test-results/lighthouse/` (đã gitignore), `upload.target` là filesystem, không gửi tới server LHCI
  nào.
- Một lượt có nhiễu (Lighthouse khuyên lấy trung vị nhiều lượt): số đo ghi kèm điều kiện, dùng để so giữa các lần đo trên
  cùng máy, không làm cam kết.
- **Kết quả và quyết định (2026-10-22):** chưa đạt LCP ≤ 2 500 ms dưới throttling mô phỏng ở cả hai trang; CLS và TBT
  đạt. Số và phân tích ở mục "Kết quả phần B". Chấp nhận ở phần B: lhci **giữ** ngưỡng (đỏ là đúng sự thật), `make
  web-lighthouse` chưa chặn PR. Việc tiếp dời sang giai đoạn 6 (đo hiệu năng cùng k6): thumbnail nhỏ hơn (WebP hay bản rộng
  ~720 px ở media-worker), bớt font tải sớm, poster của video kế chỉ tải sau LCP.
- **Ràng buộc của cách truyền cookie:** Lighthouse gửi `extraHeaders` tới **mọi** origin trang gọi, nên cookie phiên của
  user đo cũng tới MinIO `127.0.0.1:9000`. Ở local vô hại (user vừa tạo, logout khi script thoát, MinIO không ghi log
  header). Không trỏ script vào media origin có ghi log header (CDN ở giai đoạn 7) khi chưa đổi cách truyền cookie (ví dụ
  đặt cookie bằng Puppeteer trước khi đo).

## 11. Ngân sách bundle

Hai lớp như ADR-0016 §10 (`web/.size-limit.json`, `make web-check`, gzip, kB là 1000 byte):

| Route | Lớp 1: JS của route trên runtime của Next | Lớp 2: tải lần đầu |
| --- | --- | --- |
| `/v/[id]` (player hls.js light tải lười, như feed) | ≤ 200 kB | ≤ 330 kB |
| `/upload` (XHR tự viết, không gói mới) | ≤ 80 kB | ≤ 210 kB (≤ 200 kB tới phần B; nới ở phần C cùng login, [ADR-0019](0019-web-k3d-supply-chain-observability.md) §12) |

`/v/[id]` dùng cùng player và cùng cách tải lười với feed nên cùng ngân sách; `/upload` chỉ có form và XHR nên như login.

## 12. Tổng hợp contract

**RPC mới hay đổi:**

| RPC | Caller | Retry `UNAVAILABLE` ở gateway | Breaker không tính `DEADLINE_EXCEEDED` |
| --- | --- | --- | --- |
| `UserService.Register` (thêm `handle`, `display_name`) | không cần | không | — |
| `UserService.GetProfiles` | không cần | không | có |
| `UserService.GetProfileByHandle` | cần | có | — |
| `UserService.UpdateDisplayName` | cần | có | — |
| `VideoService.GetPublicVideo` | không cần (bỏ qua `x-user-id`) | có | — |
| `VideoService.ListAuthorVideos` | cần | có | — |
| `EngagementService.GetStats` | **tuỳ chọn** | không (như cũ) | có (như cũ) |

**Route REST mới hay đổi** (chi tiết ở `services/gateway/openapi.yaml`):

| Route | Xác thực | Lớp | Trả |
| --- | --- | --- | --- |
| `POST /auth/register` | không | `register` | body thêm `handle`, `display_name` tuỳ chọn (schema `RegisterRequest`; `/auth/login` giữ `Credentials`) |
| `GET /me` | Bearer | `read` | `Profile` |
| `PATCH /me` | Bearer | `write` | `Profile` |
| `GET /profiles/{handle}` | Bearer | `read` | `UserProfile` |
| `GET /users/{user_id}/videos`, `GET /me/videos` | Bearer | `read` | `VideoPage` |
| `GET /public/videos/{video_id}` | **không** | `public` | `PublicVideo`, `Cache-Control: public, max-age=30` |
| `GET /videos/{video_id}` | Bearer | `read` | `Video` thêm `author`, `stats` |
| `GET /feed/following`, `GET /feed/explore` | Bearer | `read` | item thêm `author` |

**Mã lỗi mới:**

| `code` (reason) | gRPC | HTTP | Ở đâu |
| --- | --- | --- | --- |
| `INVALID_HANDLE` | `INVALID_ARGUMENT` | 400 | `POST /auth/register` |
| `HANDLE_ALREADY_TAKEN` | `ALREADY_EXISTS` | 409 | `POST /auth/register` |
| `INVALID_DISPLAY_NAME` | `INVALID_ARGUMENT` | 400 | `POST /auth/register`, `PATCH /me` |
| `USER_NOT_FOUND` | `NOT_FOUND` | 404 | `GET /me`, `PATCH /me`, `GET /profiles/{handle}` |
| `INVALID_AUTHOR_ID` | `INVALID_ARGUMENT` | 400 | `GET /users/{user_id}/videos` |
| `INVALID_PAGE_SIZE`, `INVALID_PAGE_TOKEN` | `INVALID_ARGUMENT` | 400 | `GET /users/{user_id}/videos`, `GET /me/videos` |
| `VIDEO_NOT_FOUND` | `NOT_FOUND` | 404 | `GET /public/videos/{video_id}`, mọi ca không xem được |
| `TOO_MANY_USER_IDS`, `INVALID_USER_ID` | `INVALID_ARGUMENT` | — | chỉ ở `GetProfiles`; gateway chỉ gửi id hợp lệ, tối đa 50, và nuốt lỗi khi ghép |

## Kết quả phần B (đo ngày 2026-10-22)

Điều kiện chung: MacBook (Mac14,7, 16 GB RAM, macOS 27.0), cắm điện, không Low Power Mode; stack compose profile `core`
(`make up`, không `obs`, không k3d), ngay sau `make smoke`; Playwright 1.64.1 (Chromium 156, WebKit 27.2), một worker.
e2e chạy một lượt `make measure-web` ở chế độ chứng cứ (`SVP_E2E_EVIDENCE`: trace và video của mọi test), nên số đo có
thêm tải ghi trace và video. Trình duyệt tới MinIO qua loopback, không throttle mạng (trừ Lighthouse).

| Kiểm | Kết quả |
| --- | --- |
| e2e (`make measure-web`, lượt duy nhất) | 68/68 pass trong 5,8 phút, không chạy lại test nào: Chromium 30/30 + 4/4 (project `chromium-publishing`), WebKit 30/30 + 4/4 (`webkit-publishing`). Mới ở phần B: upload clip 60 s 1080p qua `/upload` tới `READY` rồi phát ở `/v/{id}`; mất mạng lúc upload thì trang tự gửi lại và video vẫn `READY`; `/v/{id}` cho khách (tên, `@handle`, không nhận cookie), HTML thô không cookie có thẻ Open Graph, title HTML escape trong trang và thẻ meta, id ngẫu nhiên và video chưa `READY` cùng một 404, khách bấm like được mời đăng nhập rồi quay lại video; `/me` liệt kê video kèm trạng thái, `/u/{handle}` theo dõi rồi bỏ theo dõi, `/u/{handle của mình}` → `/me`, handle chữ hoa → chữ thường; tên hiển thị chứa HTML hiện như text ở `/me` và feed; CSP `connect-src` của `/upload` có origin upload, nonce trên mọi `<script>` của `/v/{id}` cho khách; WEB-10 (preflight); axe không lỗi serious/critical ở `/upload`, `/me`, `/u/{handle}`, `/v/{id}` |
| Cắt mạng lúc upload | Playwright không cắt được upload "giữa chừng" trên loopback: Chromium (CDP `Fetch`) cắt sau khi body đã gửi hết, WebKit (`page.route`) cắt trước byte đầu. Cả hai kiểm đường mất mạng → chờ `online` → gửi lại → `READY` |
| Upload ~100 MB (`make measure-upload`, Chromium, 1 lượt) | File 102,5 MB (160 s 1080p); XHR start → `load` 1 224 ms, 83,8 MB/s; main thread của trang trong cửa sổ 1 287 ms: TaskDuration 83 ms, ScriptDuration 16 ms (6 %; tiến trình mạng không tính); XHR start → `READY` 156,9 s (transcode 160 s 1080p chiếm gần hết). Ba lượt đo trước trên cùng máy: 1 091 / 1 311 / 1 166 ms tải lên, `READY` lần lượt 158,5 / 159,5 / 163,0 s |
| Lighthouse (`make web-lighthouse`, 12.6.1, mobile mặc định: throttling mô phỏng RTT 150 ms, 1,6 Mbit/s, CPU ×4; benchmarkIndex ~3 100; một lượt mỗi trang) | `/` (đã đăng nhập): LCP **4 061 ms**, CLS 0, TBT 129 ms. `/v/{id}` (khách): LCP **3 167 ms**, CLS 0, TBT 69 ms. LCP trượt ngưỡng 2 500 ms ở cả hai, CLS và TBT đạt. Phần tử LCP ở cả hai trang: poster `<img fetchpriority="high">` (`thumbnail.jpg` 88,8 kB từ MinIO) |
| Lighthouse, các lượt trước | Trước khi sửa cách tải poster và player: `/` LCP 6 012 ms, TBT 542 ms, tổng byte 75,6 MB (cả 10 poster và 30 segment HLS tải ngay); `/v/{id}` LCP 2 918 ms, TBT 69 ms. Sau khi sửa (poster đầu ưu tiên, poster khác lazy, hls.js bắt đầu ở 360p với đệm ~3 MB, video kế chỉ nạp khi video hiện tại đã `canplay`/`playing`): `/` LCP 3 692 ms, TBT 64 ms, tổng byte 14,6 MB; `/v/{id}` LCP 3 018 ms, TBT 50 ms. Lượt này (cùng code) `/` 4 061 ms: chênh 370 ms giữa hai lượt cùng code là nhiễu của một lượt |
| Vì sao LCP còn trượt (phân tích báo cáo JSON của lượt sau khi sửa) | LCP thấy thật không throttle chỉ 118–178 ms; số mô phỏng do **byte cần trước LCP** trên 1,6 Mbit/s: `/` ~472 kB (script ~200 kB, hai poster 177,5 kB vì poster kế nằm trong lề lazy của Chrome, font Be Vietnam Pro 4 weight 67,5 kB, HTML, CSS), `/v/{id}` ~376 kB. Riêng truyền đã ~2,0–2,6 s, cộng TTFB mô phỏng ~460 ms và bắt tay tới origin thứ hai (MinIO) |
| size-limit (gzip, `make web-check`) | `/v/[id]`: 174,25 kB / 200 kB trên runtime, 305,52 kB / 330 kB tải lần đầu. `/upload`: 64,25 kB / 80 kB, 195,52 kB / 200 kB. Feed 180,46 / 311,73 kB, login 65,44 / 196,71 kB (đều trong ngân sách) |
| Open Graph (`curl -s` không cookie tới `http://localhost:3001/v/<id READY>`) | 200; có `og:title`, `og:description` (`<tên> (@handle)`), `og:url`, `og:image` (`thumbnail.jpg`), `og:video` (`master.m3u8`), `og:video:type` `application/vnd.apple.mpegurl`, `og:type` `video.other`, `twitter:card` `summary_large_image`; HTML `Cache-Control: private, no-store`, không `Set-Cookie` |
| CORS MinIO (`curl -si -X OPTIONS`) | Tới `/media/...` (`Access-Control-Request-Method: GET`) và `/uploads` (`POST`): `Origin: http://evil.example` → 204 **không** có `Access-Control-Allow-Origin`; `Origin: http://localhost:3001` → `Access-Control-Allow-Origin: http://localhost:3001` |
| Thời gian tới khung đầu sau vuốt (20 lần mỗi trình duyệt) | Chromium p50 19 ms, p95 56 ms, max 98 ms; WebKit p50 225 ms, p95 335 ms, max 395 ms. Chậm hơn phần A (13/21 và 20/141 ms) vì video kế giờ chỉ nạp khi video hiện tại đã chạy, và bắt đầu ở 360p: lúc vuốt video kế có thể chưa đệm xong. Đổi lấy LCP và byte tải lúc mở trang (hàng Lighthouse) |
| Bộ nhớ container `web` (`docker stats`, cgroup) | 113,9 MiB lúc nghỉ (sau `make up`, `make smoke`), 170,9 MiB sau e2e; giới hạn 256 MiB (phần A: 52,8 / 96,3 MiB, ít trang và ít test hơn) |
| `make smoke` | 58 bước pass, thêm ở phần B: đăng ký có handle (viết hoa, service hạ), trùng handle 409 `HANDLE_ALREADY_TAKEN`, `GET /me` không email, `PATCH /me` đổi tên giữ handle, handle sinh `u_` + 12 hex, `followed_by_me` false rồi true, `GET /me/videos` thấy video `UPLOADING` của mình, danh sách của người khác chỉ `READY`, `GET /public/videos/{id}` không token 200 có `author` và số đếm không `liked_by_me`, 404 `VIDEO_NOT_FOUND` cho video `UPLOADING` và id ngẫu nhiên, item feed có `author` |
| Test đơn vị và integration | `make check` xanh; ba lượt `make test TESTFLAGS=-count=1` (44 gói ok, 603 test cấp đầu, 1 284 PASS tính cả subtest mỗi lượt, 4 SKIP cố định của `internal/objstore` cần stack, 0 FAIL); ba lượt Vitest với Redis db 15 (54 file, 926 test, không skip) |

Chứng cứ của lượt e2e (report HTML, `results.json`, trace, video, 44 ảnh màn mỗi trình duyệt ở cỡ mobile 390×844 và
desktop 1440×900, gồm M20–M39 và D03–D11 của phần B) nằm ở thư mục làm việc của máy, không commit (repo public, ~400 MB).

**Chưa kiểm ở phần B:** CORS MinIO và `UPLOAD_ORIGIN` ở k3d (phần C; đã kiểm ngày 2026-10-24, mục "Kết quả phần C" của
[ADR-0019](0019-web-k3d-supply-chain-observability.md)); kiểm `upload_url` khác origin chỉ có ở unit test
của web (trang báo lỗi, không gửi byte nào), không có e2e; `make up OBS=lgtm` + `drill-obs-threats` (WEB-9) dời lên giai
đoạn cloud như phần A.

## Hệ quả

- Được:
  - Hồ sơ có link ổn định; web hiện tên và `@handle` ở feed, hồ sơ, trang chia sẻ mà feed-service không đổi.
  - Link video mở được khi chưa đăng nhập, có Open Graph, mà luật video chưa `READY` (UP-3) không nới.
  - Upload thẳng từ trình duyệt tới storage, có tiến độ, thử lại, huỷ; backend upload không đổi.
  - Contract chỉ thêm: smoke, diễn tập, k6 chạy như cũ.
- Phải trả:
  - Route không xác thực đầu tiên ngoài `/auth/*`; ở compose mọi khách chung một bucket rate limit.
  - Mỗi trang thêm một lời gọi song song tới user-service (user-service vào đường đọc feed); user-service chậm thì thiếu tên.
  - `callerid` có thêm chế độ caller tuỳ chọn.
  - Handle không đổi được; user cũ và user đăng ký qua API không chọn handle mang handle `u_…`.
  - Liệt kê handle (WEB-16) và mạo danh bằng tên hiển thị (WEB-17) chấp nhận ở lab.
  - Huỷ hay form hết hạn để lại video `UPLOADING` chiếm một lượt tải trong 15 phút.
  - CORS MinIO toàn cục; mở web bằng `127.0.0.1:3001` thì không phát, không tải lên được.
  - Lighthouse chưa chặn PR, một lượt mỗi trang.
- Xem lại khi:
  - Có người dùng thật: danh sách handle cấm, đổi handle có chuyển hướng, xác minh tài khoản (cùng JWT-6).
  - p99 của feed vượt 150 ms vì ghép tác giả, hay user-service thành nút cổ chai của đường đọc: bản sao hồ sơ ở feed-service
    (phương án B mục 5) hay cache hồ sơ.
  - Cần resume upload (clip dài hơn, mạng di động): multipart (phương án C mục 8).
  - Giai đoạn 6: Lighthouse vào CI cùng e2e. Giai đoạn 7: CDN trước route công khai, CORS theo bucket.

## Hiện thực ở

- Handle và tên hiển thị (§1, §2): `services/user-service/migrations/00005_add_user_profile.sql`, `services/user-service/internal/server/`;
  phía web `web/features/profile/` (`display-name.ts`, `api.ts`), `web/server/profile-actions.ts`.
- Danh sách video theo tác giả (§4): `services/video-service/internal/server/server.go`,
  `services/video-service/migrations/00005_index_author_videos.sql`, `internal/pagetoken/`.
- Tác giả trong response (§5): `services/gateway/internal/api/api.go`, `services/gateway/cmd/gateway/main.go` (retry của
  `GetProfiles`, đổi tên hiển thị).
- Route công khai (§6): `services/gateway/internal/api/api.go` (`getPublicVideo`), lớp `public` của
  `services/gateway/internal/ratelimit/ratelimit.go`, `services/gateway/openapi.yaml`, `GetStats` không cần caller ở
  `services/engagement-service/internal/server/server.go`; trang `web/app/v/[id]/page.tsx`, `web/server/video-page.ts`,
  `web/features/feed/share-screen.tsx`.
- Route web (§7): `web/app/(main)/u/[handle]/page.tsx`, `web/server/profile-page.ts`, `web/server/auth-state.ts`,
  `web/server/api-proxy.ts`, `web/features/feed/api.ts`.
- Upload từ trình duyệt và CORS (§8, §9): `web/features/upload/`, `UPLOAD_ORIGIN` ở `deploy/compose/compose.yaml`; CORS theo
  bucket ở `deploy/s3/init.sh` (bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md)).
- Lighthouse và ngân sách bundle (§10, §11): `web/lighthouse/run.sh`, target `web-lighthouse`, `web-check` của `Makefile`.
- Kiểm: `deploy/compose/smoke.sh`, `web/e2e/` (`profile.e2e.ts`, `share.e2e.ts`, `upload.e2e.ts`, `measure-upload.e2e.ts`,
  `security.e2e.ts`, `fixtures.ts`), `web/server/auth.test.ts`, `web/features/profile/display-name.test.ts`.
