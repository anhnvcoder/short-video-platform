# 0016. Giai đoạn 5b: web client Next.js 16 với BFF và session phía server, refresh token xoay vòng có phát hiện dùng lại

- Trạng thái: Chấp nhận; phần chuẩn bị backend và phần A đã kiểm trên máy ngày 2026-10-22 (mục Kết quả phần A); chi tiết
  phần B (§6 origin upload, §8 trạng thái follow, §11) chốt ở [0018](0018-web-profiles-public-video-upload.md), phần B
  đã kiểm trên máy cùng ngày (mục "Kết quả phần B" của 0018); phần C còn làm
- Ngày: 2026-10-21

## Bối cảnh

- Tới giai đoạn 5, client duy nhất là `curl`, k6 và trang thử HLS; web client nằm ngoài phạm vi
  ([architecture §1](../architecture.md#1-phạm-vi): "thêm sau thì viết ADR"). Giai đoạn 5b thêm một web client mức
  production cho luồng F1–F7: đăng ký, đăng nhập, feed dọc phát HLS, like, lượt xem, follow, rồi upload và trang chia sẻ.
  Nó chạy trên compose và k3d và đi qua pipeline của giai đoạn 5 ([ADR-0015](0015-cicd-devsecops-stage5.md)).
- Hiện trạng ảnh hưởng tới thiết kế:
  - Access token là JWT EdDSA hạn **1 giờ**, **không có refresh token**
    ([threat model JWT-3](../threat-model.md#41-jwt-và-đăng-nhập); câu "There is no refresh token in the MVP" ở
    `proto/svp/user/v1/user_service.proto`). JWT-3 hẹn xem lại "khi có app client thật". Web là client đó: không thể bắt
    người dùng gõ lại mật khẩu mỗi giờ.
  - Mọi route trừ register/login cần Bearer. Rate limit `register`/`login` đếm theo IP, các route khác theo `user_id`
    ([ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §2). Ở k3d gateway tin một hop `X-Forwarded-For` từ dải
    pod `10.42.0.0/16` ([ADR-0014](0014-kubernetes-local-stage4.md) §9).
  - Gateway bỏ `traceparent` của client và mở trace gốc mới ([ADR-0011](0011-observability-stage3.md), mục propagation).
  - `playlist_url`, `thumbnail_url` là URL tuyệt đối tới MinIO (compose `http://127.0.0.1:9000/media`, k3d
    `https://s3.svp.localhost:8443/media`), khác origin với web.
  - Redis native: db 0, 5, 7 của dự án khác, project dùng db 10–15; db 9 đã kiểm là trống.
  - Compose đã publish `127.0.0.1:3000` cho Grafana (profile `obs`).
- Ràng buộc: máy 16 GB, compose và k3d không chạy cùng lúc; repo public; mỗi dependency mới cần lý do
  (`CLAUDE.md`); chỉ action của GitHub và `sigstore/cosign-installer` được chạy trong CI (ADR-0015 §11).
- ADR này chốt những gì code của phần chuẩn bị backend và phần A cần làm theo mà không phải đoán: định dạng và vòng đời
  refresh token, contract gRPC và REST, session, cookie, CSRF, CSP, cổng, danh sách dependency. Các phần B và C chỉ có
  quyết định khung ở đây; chi tiết của chúng được chốt khi tới phần đó (mục 11).

## Kiểm chứng (đã kiểm ngày 2026-10-21)

| Kiểm gì | Nguồn hay lệnh | Kết quả |
| --- | --- | --- |
| Version gói npm | `npm view <gói> version` (registry npmjs) | `next` 16.4.2, `react` 19.3.1, `next-intl` 4.14.9 (peer `next` có `^16.0.0`), `redis` 6.3.0, `hls.js` 1.7.3, `lucide-react` 1.60.0, `openapi-fetch` 0.17.0, `openapi-typescript` 7.13.0 (peer `typescript ^5.x`), `@tanstack/react-query` 5.104.5, `zod` 4.6.7, `server-only` 0.0.1, `tailwindcss` và `@tailwindcss/postcss` 4.3.3, `eslint-config-next` 16.4.2 (kéo theo `typescript-eslint`, `eslint-plugin-react`, `eslint-plugin-react-hooks`, `eslint-plugin-jsx-a11y`, `@next/eslint-plugin-next`), `eslint` 10.13.0, `prettier` 3.9.10, `typescript` 7.0.2 (bản mới nhất; dùng dòng 6.0, mục 10), `vitest` 5.0.5, `@playwright/test` 1.64.1, `pnpm` 12.14.0 |
| Cookie `Secure` trên `http://localhost` ở WebKit | <https://bugs.webkit.org/show_bug.cgi?id=232088>, <https://bugs.webkit.org/show_bug.cgi?id=231035> | 232088 "Unable to set Secure cookie for localhost": **NEW** (chưa sửa), bình luận cuối 2026-04-20 nói phần còn thiếu là kho cookie chưa nhận cookie `Secure` cho tên loopback. 231035 đóng là bản trùng của 218980 ("Treat loopback addresses ... as potentially trustworthy URL", NEW). Kết luận: Safari/WebKit **bỏ** cookie `Secure` đặt từ `http://localhost` |
| Tiền tố tên cookie | MDN `Set-Cookie` (<https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie>) | `__Host-`: bắt buộc `Secure`, đặt từ trang an toàn, không `Domain`, `Path=/`. `__Http-`: thêm bắt buộc `HttpOnly`. `__Host-Http-`: gộp cả hai. Trình duyệt không hiểu tiền tố thì nhận cookie như thường ("prefixed cookies will always be accepted"). MDN ghi "The `https:` requirements are ignored when the `Secure` attribute is set by localhost" nhưng không nói trình duyệt nào; WebKit thì không (dòng trên) |
| `SameSite=Lax` mặc định và ngoại lệ 2 phút | MDN `Set-Cookie` | Bản Lax *mặc định* (cookie không ghi `SameSite`) được gửi kèm POST trong 2 phút đầu; cookie ghi rõ `SameSite=Lax` không có ngoại lệ đó |
| Xoay refresh token | RFC 9700 §4.14.2 (<https://www.rfc-editor.org/rfc/rfc9700.html>) | "issues a new refresh token with every access token refresh response. The previous refresh token is invalidated"; khi token đã vô hiệu bị trình lại, máy chủ "cannot determine which party submitted the invalid refresh token, but it will revoke the active refresh token". RFC chỉ bắt thu hồi token đang hoạt động; thu hồi cả họ là lựa chọn chặt hơn của ADR này (mục 2) |
| Gateway retry | `services/gateway/cmd/gateway/main.go` (`backend.retry`) | Chỉ retry `UNAVAILABLE` cho method idempotent có tên trong danh sách (user-service: `Follow`, `Unfollow`); timeout mỗi lời gọi gRPC 3 s (`callTimeout` ở `internal/api`) |
| Cổng đang publish ở compose | `deploy/compose/compose.yaml` | `8080` gateway, `9000`/`9001` MinIO, `19092` Redpanda, `3000` Grafana, `9093` Alertmanager, `8000` GlitchTip, `5601` Kibana; `3001`, `3002` trống |
| Corepack | Tài liệu Node v25 (`corepack.html`), <https://github.com/nodejs/corepack#default-installs> | Node 25 trở đi không còn kèm Corepack |
| CVE của RSC trong Next | Advisory của Next <https://nextjs.org/blog/CVE-2025-66478>, <https://github.com/vercel/next.js/security/advisories/GHSA-9qr9-h5gf-34mp>; blog của React <https://react.dev/blog/2025/12/03/critical-security-vulnerability-in-react-server-components> (đọc lại 2026-10-22) | Lỗ gốc ở React (CVE-2025-55182); CVE-2025-66478 theo dõi tác động lên app Next dùng App Router, gói bị ảnh hưởng là `next`. Advisory của Next: "There is no workaround—upgrading to a patched version is required"; blog của React liệt kê `next` trong các framework bị ảnh hưởng và cách vá cho Next là nâng `next` |
| CSP nonce ở Next | <https://nextjs.org/docs/app/guides/content-security-policy> (cập nhật 2026-03-20) | Next gắn nonce lúc render ở server, lấy từ header `Content-Security-Policy` **của request** (mẫu `'nonce-<giá trị>'`), cho script framework, bundle JS của trang, script và style inline do Next sinh; ví dụ của tài liệu đặt CSP vào request qua `NextResponse.next({ request: { headers } })` và đặt lại vào response. Trang phải render động. `'unsafe-eval'` chỉ cần ở dev. Ví dụ `matcher` của tài liệu loại `api` và request prefetch |
| Khoá `env` của `next.config` | <https://nextjs.org/docs/app/api-reference/config/next-config-js/env> | Giá trị khai ở khoá `env` "will **always** be included in the JavaScript bundle", tên có tiền tố `NEXT_PUBLIC_` hay không cũng vậy |
| Cookie không cách ly theo cổng | RFC 6265 §8.5 (<https://www.rfc-editor.org/rfc/rfc6265#section-8.5>) | "Cookies do not provide isolation by port": cookie của một host được gửi tới mọi cổng của host đó, và service trên cổng khác ghi được nó |

## 1. Framework và vị trí trong lộ trình

### Các lựa chọn

#### A. Next.js 16 App Router, `output: 'standalone'`, tự host trong container

- Được: mặc định của ngành, tài liệu và hệ sinh thái lớn nhất; SSR và `generateMetadata` cho trang chia sẻ có OG; Route
  Handler và Server Action làm BFF ngay trong app; `proxy.ts` (tên mới của `middleware.ts` ở Next 16) là chỗ đặt CSP nonce
  và kiểm Origin cho mọi request.
- Mất: CSP nonce ép mọi trang render động, nên static, ISR, PPR không dùng được; nhiều replica cần chung
  `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` và `deploymentId` theo commit để không lệch version; bề mặt tấn công của RSC/Server
  Actions có CVE nghiêm trọng (CVE-2025-55182, "React2Shell") nên phải vá nhanh. Advisory của Next ghi gói bị ảnh hưởng
  là `next` và cách vá duy nhất là nâng `next` lên bản đã vá, nên phải theo dõi advisory của `next`, không chỉ của `react`.

#### B. React Router 8 framework mode

- Được: không RSC, server không trạng thái, nonce truyền thẳng vào `renderToPipeableStream`; loader/action đặt cookie ở
  mọi response.
- Mất: ít tài liệu và template hơn; mode framework của v8 mới ra 2026-06.

#### C. SPA (Vite) + BFF Go

- Mất: OG cho trang chia sẻ cần nhánh render thứ hai ở Go; nội dung đầu hiện chậm.

### Quyết định

Chọn **A**: **Next.js 16 App Router, `output: 'standalone'`**, một package ở `web/` (một package pnpm, không workspace).
Cái giá của A được xử lý như sau, không bỏ qua:

- Mọi trang render động (`dynamic` theo request vì nonce). Không ISR/PPR, nên **không cần** `cacheHandler` dùng chung.
- `images.unoptimized: true`: thumbnail đã do media-worker sinh; bỏ image optimizer và `sharp` khỏi bề mặt tấn công.
- `poweredByHeader: false`.
- `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (Secret) và `deploymentId` theo commit làm ở phần C, khi có 2 replica; compose chạy
  một replica.
- Vá CVE: Renovate (manager npm, mục 10) cùng cảnh báo lỗ hổng mở PR ngay. pnpm kiểm tuổi phát hành cả lúc cài
  `--frozen-lockfile`, nên bản vá mới hơn 3 ngày cần ngoại lệ theo quy trình ở mục 10.

**Vị trí:** giai đoạn **5b**, giữa 5 và 6, vì web cần pipeline ký, quét, promote của giai đoạn 5; giai đoạn 6 (k6, chaos,
SLO) đo cả web.

## 2. Refresh token (đóng JWT-3)

Mục này chỉnh [ADR-0006](0006-contract-ids-and-event-envelope.md) §5 ("MVP không có refresh token").

### Các lựa chọn

#### A. Token mờ ngẫu nhiên, lưu hash, xoay mỗi lần dùng, phát hiện dùng lại thì thu hồi cả họ

- Được: thu hồi được (logout, dùng lại); token không mang dữ liệu nên không cần ký hay mã hoá; phát hiện token bị đánh cắp
  khi cả kẻ cắp lẫn client thật cùng dùng.
- Mất: một bảng mới và một transaction mỗi lần refresh; hai request song song cùng một token làm mất cả họ (client phải
  single-flight).

#### B. Refresh token là JWT dài hạn, không lưu

- Mất: không thu hồi được nếu không thêm danh sách đen; không phát hiện được dùng lại.

#### C. Token mờ không xoay (dùng lại được tới hết hạn)

- Mất: token lộ dùng được suốt hạn mà không ai biết; RFC 9700 §4.14.2 yêu cầu client công khai dùng xoay vòng hoặc ràng
  buộc theo người gửi.

#### D. Có cửa sổ chồng (token cũ còn dùng được vài giây sau khi xoay)

- Được: hai request refresh song song, hay mất response rồi thử lại, không làm mất phiên.
- Mất: trong cửa sổ đó kẻ cắp dùng token cũ được mà không bị phát hiện, và có hai nhánh token sống cùng lúc.

### Quyết định

Chọn **A**, **không** cửa sổ chồng (D). Client duy nhất là BFF và BFF làm single-flight (mục 5). Cái giá là một response bị
mất (timeout, mạng đứt sau khi user-service đã xoay) làm lần thử sau thành "dùng lại", và người dùng phải đăng nhập lại.
Ca này hiếm và chỉ tốn một lần đăng nhập.

**Định dạng token:**

- 32 byte từ `crypto/rand`, mã hoá base64url **không padding**: luôn 43 ký tự.
- Kiểm trước khi chạm database: đúng 43 ký tự của bảng base64url và giải ra đúng 32 byte. Sai thì trả lỗi chung (bên
  dưới); rỗng hay quá dài không bao giờ tới Postgres.
- Database chỉ lưu `token_hash` = **SHA-256 của 32 byte đã giải mã**. Không salt, không HMAC: token có 256 bit ngẫu nhiên
  nên hash không đảo ngược được bằng từ điển (salt chỉ cần cho mật khẩu có ít entropy), và tra cứu theo hash phải tất định.
  Database bị lộ thì không lấy được token dùng được.
- Token thô chỉ sống trong `secret.String` ở Go (tự che khi log), không vào log, span, problem hay database (JWT-8).

**Bảng `refresh_tokens`** ở `svp_user` (migration của user-service):

| Cột | Kiểu | Ý nghĩa |
| --- | --- | --- |
| `id` | `uuid` PK | UUIDv7, định danh của token (vai trò `jti`); được ghi log, token thô thì không |
| `family_id` | `uuid NOT NULL` | Họ token của một lần login; bằng `id` của token đầu tiên, các token xoay sau giữ nguyên |
| `user_id` | `uuid NOT NULL`, FK `users(id) ON DELETE CASCADE` | Chủ token; xoá user là xoá token |
| `token_hash` | `bytea NOT NULL UNIQUE`, `CHECK (octet_length(token_hash) = 32)` | SHA-256 của token |
| `created_at` | `timestamptz NOT NULL` | Lúc cấp |
| `expires_at` | `timestamptz NOT NULL` | Hạn của token này |
| `family_expires_at` | `timestamptz NOT NULL` | Hạn tuyệt đối của họ (login + 30 ngày), chép sang mọi token của họ |
| `used_at` | `timestamptz NULL` | Lúc token bị đổi lấy token mới; khác `NULL` là đã dùng |
| `revoked_at` | `timestamptz NULL` | Lúc họ bị thu hồi (logout hay phát hiện dùng lại); đặt cho mọi token của họ |

Có index trên `family_id` cho câu thu hồi cả họ. `family_expires_at` nằm trên từng dòng thay vì một bảng họ riêng: token xoay
cần biết trần của họ, và dòng của token đầu có thể bị dọn trước khi họ hết hạn. Thời gian do service tính bằng đồng hồ của
nó (tiêm được trong test) và truyền vào câu SQL, không dùng `now()` của Postgres, để test hết hạn không phải chờ.

**Hạn:**

| Thứ | Hạn | Lý do |
| --- | --- | --- |
| Access token | **1 giờ**, giữ nguyên (`authtoken.TTL`) | `make smoke`, các diễn tập và k6 dựa vào nó; ngắn hơn thì thêm lượt refresh mà không đóng thêm được gì vì access token vẫn không thu hồi được (JWT-3) |
| Mỗi refresh token | **14 ngày trượt**: mỗi lần xoay, token mới hết hạn sau 14 ngày tính từ lúc xoay | Người dùng quay lại trong 2 tuần không phải đăng nhập lại; bỏ app quá 14 ngày thì phải đăng nhập |
| Cả họ | **Trần 30 ngày** sau login: `expires_at` của token mới = `min(now + 14 ngày, family_expires_at)` | Kẻ cắp xoay token trước client thật thì client thật không bao giờ trình lại token cũ và việc dùng lại không lộ ra; trần 30 ngày giới hạn thời gian đó, đổi lại mỗi tháng gõ mật khẩu một lần |

Ba hạn là hằng số trong code (như `authtoken.TTL`), không thêm biến môi trường.

**Luồng ở user-service:**

- **Login:** mật khẩu đúng thì cấp access token và một refresh token mở **họ mới** (`id = family_id`, `expires_at` = +14
  ngày, `family_expires_at` = +30 ngày). Mỗi lần login một họ riêng: đăng nhập trên máy thứ hai không làm máy thứ nhất mất
  phiên. Ghi dòng lỗi thì login trả `INTERNAL`, không trả access token một mình.
- **Refresh**, trong **một transaction** (`READ COMMITTED`):
  1. `SELECT family_id ... WHERE token_hash = $1`; không có dòng → lỗi chung.
  2. **Khoá theo họ:** `SELECT pg_advisory_xact_lock(hashtextextended('refresh-family:' || family_id, 0))`, cùng cách
     khoá theo tác giả của [ADR-0009](0009-engagement-feed-stage2b.md) mục 7 (không cần bảng; hash 64 bit trùng chỉ làm
     chờ thêm, không sai).
  3. Đọc lại dòng token **sau** khoá: ở `READ COMMITTED` mỗi câu lấy snapshot mới, nên câu này thấy mọi thay đổi của
     transaction vừa nhả khoá.
  4. `revoked_at` khác `NULL` → lỗi chung.
  5. `used_at` khác `NULL` → **dùng lại**: `UPDATE ... SET revoked_at = $now WHERE family_id = $f AND revoked_at IS NULL`,
     commit, log WARN `refresh token reused` kèm `user_id`, `family_id`, `token_id` (không token), trả lỗi chung. Kiểm cả
     khi token đã hết hạn: họ có thể còn token con đang sống.
  6. `expires_at <= $now` → lỗi chung, không đổi gì.
  7. Đánh dấu đã dùng có điều kiện (`WHERE id = $id AND used_at IS NULL AND revoked_at IS NULL AND expires_at > $now`,
     phải đổi đúng 1 dòng; khoá ở bước 2 đã đủ, điều kiện là lớp thứ hai), chèn token mới cùng họ, **ký access token trước
     khi commit** (ký lỗi sau commit thì token cũ đã mất mà client không nhận được token mới), rồi commit.
- **Logout:** token sai định dạng hay không tìm thấy → thành công. Có dòng thì khoá theo họ như trên, thu hồi mọi token chưa
  thu hồi của họ, commit, log INFO `refresh token family revoked` (`user_id`, `family_id`). Lỗi database → `INTERNAL`
  (client cần biết thu hồi chưa xảy ra). Gọi lại bao nhiêu lần cũng như nhau.
- Mọi đường đọc/ghi token của một họ đều qua cùng khoá, nên `Refresh(token mới)` chạy song song với `Logout` hay với việc
  trình lại token tổ tiên không chèn được token con sau khi họ đã bị thu hồi.
- N request song song cùng một token: đúng một cái xoay được; các cái sau thấy `used_at` và thu hồi cả họ, kể cả token vừa
  cấp. Đây là hành vi cố ý, lý do BFF phải single-flight.

**Lỗi:** mọi ca thất bại của `Refresh` (sai định dạng, không biết, hết hạn, đã thu hồi, đã dùng) trả **một** lỗi:
`UNAUTHENTICATED`, reason **`INVALID_REFRESH_TOKEN`**, message `invalid refresh token`. Không lộ token có tồn tại hay đã
bị gì. Lỗi database → `INTERNAL` message chung như các RPC khác.

**Dọn dòng hết hạn: hoãn**, chưa làm ở 5b. Mỗi phiên đang dùng sinh khoảng một dòng mỗi giờ (một lần refresh khi access
token hết hạn), mỗi dòng cỡ 200 byte; ở quy mô lab bảng chỉ vài nghìn dòng. Dòng đã dùng vẫn cần giữ tới khi họ hết hạn để
phát hiện dùng lại. Khi làm: job như job dọn upload của ADR-0010 mục 5 (advisory lock, chạy định kỳ), xoá
`WHERE family_expires_at < now() - interval '1 day'`.

## 3. Contract gRPC

`proto/svp/user/v1/user_service.proto`, chỉ **thêm** field và RPC (số field cũ giữ nguyên, `buf breaking` sạch):

- `LoginResponse` thêm `refresh_token = 3` (string) và `refresh_expires_at = 4` (`google.protobuf.Timestamp`).
- `rpc Refresh(RefreshRequest) returns (RefreshResponse)`: `RefreshRequest{refresh_token = 1}`, `RefreshResponse{access_token
  = 1, expires_at = 2, refresh_token = 3, refresh_expires_at = 4}`.
- `rpc Logout(LogoutRequest) returns (LogoutResponse)`: `LogoutRequest{refresh_token = 1}`, `LogoutResponse{}`.
- Cả hai **không cần caller** (refresh token là thứ xác thực), nên vào `PublicMethods` của user-service. Comment proto ghi
  lỗi như các RPC hiện có; bỏ câu "There is no refresh token in the MVP".
- Gateway **không retry** `Refresh` (không idempotent: lần thử hai là dùng lại và thu hồi cả họ). `Logout` idempotent nên
  được thêm vào danh sách retry `UNAVAILABLE` như `Follow`, `Unfollow`.

## 4. Contract REST và rate limit `refresh`

Gateway làm theo; `services/gateway/openapi.yaml` ghi lại.

- `POST /auth/login`: response 200 (schema `AccessToken`) thêm `refresh_token` (string) và `refresh_expires_at`
  (date-time), cả hai bắt buộc.
- `POST /auth/refresh`: body `{"refresh_token": "<token>"}` (`application/json`, giới hạn thân như các route auth). 200 cùng
  schema với login (`access_token`, `token_type: Bearer`, `expires_at`, `refresh_token`, `refresh_expires_at`). 401
  `INVALID_REFRESH_TOKEN` cho mọi ca token không dùng được. Thân không phải JSON hay có field lạ → 400 như login; field
  thiếu hay rỗng được chuyển cho user-service, nên vẫn là 401 `INVALID_REFRESH_TOKEN`.
- `POST /auth/logout`: body `{"refresh_token": "<token>"}` → **204**, kể cả với token lạ (idempotent, không lộ trạng thái).
  user-service lỗi → 5xx như các route khác; client (BFF) vẫn xoá phiên của mình.
- Cả hai **không cần Bearer**: access token có thể đã hết hạn đúng lúc cần refresh. Refresh token không bao giờ vào access
  log, span hay problem (JWT-8).
- **Rate limit:** class mới **`refresh`** (thêm vào bảng lớp của ADR-0010 §2) dùng chung cho `/auth/refresh` và
  `/auth/logout`, khoá theo IP client như `login-ip` (chưa có `user_id` đã xác thực ở hai route này), kiểm **trước** khi đọc
  thân:

  | Lớp | Route | Khoá | Redis tốt | Redis lỗi |
  | --- | --- | --- | --- | --- |
  | `refresh` | `POST /auth/refresh`, `POST /auth/logout` | IP | 60/phút, burst 30 | đóng mềm: 30/phút, burst 15 |

  Lý do: mỗi phiên refresh khoảng một lần mỗi giờ, nên 60/phút cho mỗi IP đủ cho cả nghìn phiên sau một NAT. Đoán token
  256 bit là vô vọng, nên giới hạn này chống tải lên user-service (một transaction mỗi lần), không chống dò. Đóng mềm như
  các route auth khác (ADR-0010 §2 và §4.4 của threat model): không bao giờ để route xác thực không giới hạn. Vượt ngưỡng →
  429 `RATE_LIMITED` có `Retry-After`; metric `svp.ratelimit.decisions` có `class="refresh"` như các lớp khác.
- **IP mà gateway thấy khi request đi qua BFF:**
  - **Compose:** gateway đặt 0 hop tin cậy, nên chỉ thấy địa chỉ của container `web`: **mọi người dùng web chung một
    bucket** cho các lớp theo IP (`register`, `login-ip`, `refresh`; `login-email` thành theo email). Các lớp theo
    `user_id` (`upload`, `write`, `read`, `view-once`) vẫn tách theo người. Chấp nhận ở lab một người, như RL-1. Diễn tập và
    e2e chạy qua web phải xoá khoá `register` như `make smoke` (burst 20 mỗi giờ).
  - **k3d (phần C):** BFF **chuyển nguyên** `X-Forwarded-For` nhận từ Envoy, không thêm hop. Pod web nằm trong
    `10.42.0.0/16`, nên gateway (1 hop tin cậy) đọc đúng phần tử Envoy ghi, như khi Envoy gọi thẳng; không sửa gateway. Ca
    `X-Forwarded-For` giả qua web vào diễn tập WEB-8.

## 5. BFF: session, cookie, CSRF, proxy

### Các lựa chọn

#### A. Session phía server ở Redis, cookie chỉ mang id ngẫu nhiên

- Được: logout thu hồi được ở server; refresh single-flight làm đúng được vì có một chỗ giữ token mới nhất; token không bao
  giờ tới trình duyệt.
- Mất: thêm dependency `redis` và một db.

#### B. Cookie không trạng thái (JWE chứa token)

- Mất: cookie bị copy thì logout không thu hồi được; hai tab refresh song song ghi đè cookie của nhau, mà mỗi lần refresh
  lặp là một lần "dùng lại" (mục 2).

#### C. Thư viện auth (Auth.js, Better Auth)

- Mất: Better Auth tự giữ user và mật khẩu, trùng user-service; Auth.js chỉ còn vá bảo mật. Phần cần là vài trăm dòng.

### Quyết định

Chọn **A**, tự viết. Mọi module đọc session, giữ token hay gọi gateway nằm ở `web/server/` và có `import 'server-only'`:
import nhầm từ component client là lỗi lúc build.

**Biến môi trường** (chỉ đọc ở server, kiểm bằng `zod` lúc chạy, không lúc `next build`; thiếu hay sai thì lỗi rõ):

| Biến | Ví dụ compose | Ý nghĩa |
| --- | --- | --- |
| `GATEWAY_URL` | `http://gateway:8080` | Host gateway cố định; BFF không gọi host nào khác |
| `REDIS_URL` | `redis://host.docker.internal:6379/9` | Session; `make web-dev` dùng `redis://127.0.0.1:6379/9` |
| `APP_ORIGIN` | `http://localhost:3001` | Origin của app: kiểm CSRF, chọn dạng cookie, kiểm `next` |
| `MEDIA_ORIGIN` | `http://127.0.0.1:9000` | Origin của HLS và thumbnail, cho CSP |
| `UPLOAD_ORIGIN` | `http://127.0.0.1:9000` | Từ phần B ([ADR-0018](0018-web-profiles-public-video-upload.md) §8), bắt buộc: origin storage nhận presigned POST, cho CSP `connect-src` và kiểm `upload_url` trước khi gửi file; http(s) không path, `http` chỉ cho host loopback (`localhost`, `127.0.0.1`, `[::1]`) |

Phần A **không có biến `NEXT_PUBLIC_*` nào**: trình duyệt không cần cấu hình (URL media đến từ API). `next.config`
**không dùng khoá `env`**: giá trị khai ở đó luôn được chép vào bundle client lúc build, bất kể tên. `APP_ORIGIN` scheme
`http` chỉ nhận host `localhost`; khác thế thì server không khởi động.

**Session** (Redis db 9 ở compose và máy, Valkey db 9 ở k3d):

- `sid`: 32 byte `crypto.randomBytes`, base64url. Khoá `svp:web:sess:<sha256(sid) hex>`: Redis không chứa sid thô, nên đọc
  được Redis (`KEYS`, dump) không dựng lại được cookie.
- Giá trị JSON: `ver` (số tăng mỗi lần ghi, cho compare-and-set), `user_id`, `access_token`, `access_expires_at`,
  `refresh_token`, `refresh_expires_at`, `created_at`.
- TTL của khoá = `refresh_expires_at` (`PEXPIREAT`): **idle timeout 14 ngày** chính là hạn trượt của refresh token (mỗi lần
  refresh đẩy TTL lên), **hạn tuyệt đối 30 ngày** là trần của họ. Không có thao tác "chạm" riêng mỗi request. Mọi khoá
  `svp:web:` đều có TTL (quy tắc của ADR-0010 mục 1).
- **Login** (Server Action, chạy được cả khi chưa có JS): gọi `POST /auth/login` (chuyển `X-Forwarded-For`), có session cũ
  thì xoá nó và gọi `/auth/logout` cho refresh token cũ (best-effort), tạo **sid mới** (chống fixation), `Set-Cookie`,
  redirect 303 tới `next` đã kiểm. `next` hợp lệ khi bắt đầu bằng `/`, không bắt đầu bằng `//` hay `/\`, và
  `new URL(next, APP_ORIGIN).origin === APP_ORIGIN`; sai thì `/`. Register thành công thì đăng nhập luôn bằng cùng thông
  tin.
- **Logout:** Route Handler `POST /logout` (form thường, chạy cả khi chưa có JS; Server Action không đặt được header
  response tuỳ ý như `Clear-Site-Data`): gọi `/auth/logout` với refresh token (lỗi thì log WARN và vẫn tiếp), xoá khoá
  session, xoá cookie (cùng tên và thuộc tính, `Max-Age=0`), `Clear-Site-Data: "cache"`, `Cache-Control: no-store`, 303 về
  `/login`. Không `"cookies"` trong `Clear-Site-Data`: nó xoá cả cookie ngôn ngữ.

**Cookie theo scheme của `APP_ORIGIN`:**

| Origin | Cookie |
| --- | --- |
| `https://...` (k3d `https://svp.localhost:8443`, cloud) | `__Host-Http-svp_sid=<sid>; HttpOnly; Secure; Path=/; SameSite=Lax; Max-Age=2592000` |
| `http://localhost:<cổng>` (chỉ compose và `make web-dev`) | `svp_sid=<sid>; HttpOnly; Path=/; SameSite=Lax; Max-Age=2592000` |

- Vì sao hai dạng: WebKit/Safari bỏ cookie `Secure` đặt từ `http://localhost` (WebKit bug 232088 còn mở), và tiền tố
  `__Host-` bắt buộc `Secure`. Dùng một dạng cho cả hai thì e2e WebKit trên compose không đăng nhập được. Dạng không tiền
  tố chỉ dùng trên loopback, nơi không ai khác ở giữa đường truyền. Ca đầy đủ (`__Host-Http-`, `Secure`) kiểm ở k3d qua
  `https://svp.localhost:8443` (phần C).
- Cookie **không cách ly theo cổng** (RFC 6265 §8.5): `svp_sid` của `localhost` đi kèm mọi request tới `http://localhost:<cổng
  khác>` (Grafana, GlitchTip khi mở bằng `localhost`, `web-dev` 3002), và một server bất kỳ trên cổng khác của `localhost`
  đặt hay ghi đè được nó. Chấp nhận ở lab một người: các cổng đó là service của chính project; sid mới mỗi lần login làm
  sid bị cài sẵn mất tác dụng; sid lạ không có khoá Redis thì là chưa đăng nhập. Hệ quả thực tế: `web` (3001) và `web-dev`
  (3002) chạy cùng lúc dùng chung cookie và Redis db 9, tức chung một phiên: đăng nhập hay đăng xuất ở bên này áp cho cả
  bên kia.
- `__Host-Http-`: không `Domain` nên site anh em (`s3.svp.localhost`, `api.svp.localhost`) không ghi đè được cookie;
  `HttpOnly` nên script trên trang không đọc được. Trình duyệt chưa hiểu `__Http-` vẫn áp phần `__Host-`.
- `Max-Age` 30 ngày (= trần của họ) đặt một lần lúc login. Refresh có thể chạy trong lúc render Server Component, nơi không
  đặt được cookie; cookie chỉ mang sid không đổi nên không cần đặt lại. Hạn thật nằm ở TTL của khoá Redis.
- **Vì sao `SameSite=Lax` chứ không `Strict`:** mở link video từ app khác (chat, mạng xã hội) là điều hướng top-level từ
  site khác; với Strict, lượt mở đầu thấy chưa đăng nhập. CSRF được chặn ở lớp riêng (bên dưới), không dựa vào SameSite.

**CSRF** ở `proxy.ts`, cho **mọi method trừ `GET` và `HEAD`** (Server Action, Route Handler, `/api/*`):

- Có `Sec-Fetch-Site`: chỉ nhận đúng `same-origin`. `same-site`, `cross-site`, `none` → 403. Phải là `same-origin`, không
  phải `same-site`: `s3.svp.localhost` (MinIO phục vụ file do người dùng upload) cùng site với `svp.localhost`, và cookie
  `SameSite=Lax` vẫn đi kèm request từ site anh em.
- Không có `Sec-Fetch-Site` (trình duyệt cũ): `Origin` phải bằng đúng `APP_ORIGIN`; `Origin: null` → 403.
- Thiếu cả hai → 403. Lỗi trả `application/problem+json` code `CSRF_REJECTED`.
- Không route nào đổi trạng thái bằng `GET`; không CORS ở web (không trả `Access-Control-*`). Server Action của Next còn tự
  so `Origin` với `Host`, là lớp thứ hai.
- Origin chuẩn của compose là `http://localhost:3001` (`APP_ORIGIN`: kiểm `next`, chọn dạng cookie). Mở bằng
  `http://127.0.0.1:3001` vẫn chạy: trình duyệt gửi `Sec-Fetch-Site: same-origin` cho POST của chính trang, lớp kiểm này
  nhận trước khi so `Origin`; cookie khi đó là cookie riêng của host `127.0.0.1`, không chung phiên với `localhost`. Chỉ
  trình duyệt không gửi `Sec-Fetch-Site` mới bị 403 ở `127.0.0.1` (`Origin` khác `APP_ORIGIN`).

**Proxy `/api/*`** (Route Handler `web/app/api/[...path]/route.ts`), cho component client gọi gateway mà không có token:

- **Danh sách route cho phép** của phần A, khớp `openapi.yaml`: `GET /feed/explore`, `GET /feed/following` (query chỉ
  `cursor`, `page_size`), `GET /videos/{video_id}`, `PUT`/`DELETE /videos/{video_id}/like`, `POST /videos/{video_id}/views`,
  `PUT`/`DELETE /me/following/{user_id}`; segment id phải là UUID dạng chuẩn. Path ngoài danh sách (cả `..`, `%2e%2e`,
  `%2F`) → 404, method sai → 405, query lạ → 400. URL tới gateway dựng từ `GATEWAY_URL` cố định và segment đã kiểm, không
  bao giờ từ chuỗi của client (chống SSRF, WEB-7).
- Request tới gateway: chỉ `Content-Type: application/json`, `Accept`, `X-Forwarded-For` **nguyên văn** như nhận (vắng thì
  không đặt), `Authorization: Bearer` từ session. Bỏ `Cookie`, `Authorization` và mọi header khác của trình duyệt. Thân chỉ
  `application/json`, tối đa 64 KiB (bằng giới hạn của gateway).
- Response: status, `Content-Type`, `Retry-After`, `Allow`, thân; bỏ `Set-Cookie` của gateway; `Cache-Control: no-store`.
  Không có session → 401 problem.

**Refresh single-flight:**

- Refresh khi `access_expires_at - 30 s < now` (30 s là độ lệch đồng hồ gateway cho phép).
- Trong một process: `Map<sha256(sid), Promise>`, request thứ hai cùng sid chờ promise của request đầu.
- Giữa các replica: `SET svp:web:lock:<sha256(sid)> <16 byte ngẫu nhiên> NX PX 5000`.
  - Lấy được khoá: đọc lại session (replica khác có thể vừa refresh xong); vẫn cũ thì gọi `/auth/refresh` với **timeout 4
    s** (lớn hơn timeout 3 s của gateway để 504 của gateway về trước). Lease 5 s > 4 s + biên 1 s, nên người giữ khoá luôn
    xong hay huỷ lời gọi trước khi lease hết.
  - Ghi session mới bằng **compare-and-set** (Lua: khoá còn và `ver` còn bằng giá trị đã đọc thì ghi với `ver + 1` và
    `PEXPIREAT` mới, không thì không ghi). Khoá đã mất nghĩa là logout xảy ra trong lúc refresh: không ghi sống lại session,
    gọi `/auth/logout` cho refresh token vừa nhận (best-effort), trả 401.
  - Nhả khoá bằng compare-and-delete (Lua, so giá trị ngẫu nhiên): không xoá khoá của người khác khi lease của mình đã hết.
  - Không lấy được khoá: đọc lại session mỗi 100 ms, tối đa 5 s; thấy `ver` mới thì dùng token mới, hết hạn chờ thì 503.
- Refresh trả 401 `INVALID_REFRESH_TOKEN` → xoá session (compare-and-delete theo `ver`), trả 401 (`/api/*`) hay redirect
  `/login?next=` (trang). 429, 5xx, timeout → **giữ** session, trả lỗi tương ứng, **không tự thử lại** refresh (thử lại sau
  timeout có thể là dùng lại, mục 2).
- **Refresh không rõ kết quả** (timeout, mạng đứt, 5xx: không biết user-service đã xoay hay chưa): **fail-closed**, không
  cửa sổ chồng. Session giữ nguyên, request đó không thử lại; access token cũ còn hạn thì dùng tiếp, đã hết hạn thì request
  đó nhận lỗi ở dòng trên (trang cần đăng nhập báo lỗi, chỗ chỉ hỏi "ai đang đăng nhập" coi là chưa). Request sau thử refresh lại: nếu lần trước đã xoay thì token cũ là "dùng lại", user-service thu hồi
  cả họ và trả 401, BFF xoá session và người dùng đăng nhập lại (cái giá đã nhận ở mục 2). Lời gọi refresh bị cắt bằng
  `AbortSignal.timeout(lease − biên − thời gian đã trôi)` trước khi lease 5 s hết, nên hai lời gọi cùng một token không
  bao giờ chồng nhau giữa các replica.

## 6. Header bảo mật và CSP

`proxy.ts` sinh nonce mỗi request (`crypto.randomBytes(16)`, base64), dựng chuỗi CSP bên dưới với nonce đó, rồi đặt nó ở
**cả request lẫn response**:

1. **Request chuyển cho renderer:** `const headers = new Headers(request.headers)`, `headers.set('Content-Security-Policy',
   csp)`, `headers.set('x-nonce', nonce)`, rồi `NextResponse.next({ request: { headers } })`. Next gắn nonce lúc render ở
   server và lấy nó từ header `Content-Security-Policy` **của request**. Thiếu bước này thì response có CSP mà thẻ
   `<script>` của framework, bundle của trang và payload RSC không có nonce: `'strict-dynamic'` chặn hết, trang không
   hydrate. Dùng `set` (ghi đè) nên header cùng tên do trình duyệt gửi không tới được renderer. `x-nonce` cho code tự đọc
   bằng `headers()` (như `<Script nonce>`); phần A chưa cần.
2. **Response:** cùng chuỗi CSP (cùng nonce) và các header bảo mật bên dưới, đặt lên response mà `NextResponse.next(...)`
   trả về.
3. **Mọi trang render động:** root layout gọi `await connection()` (`next/server`). Trang render tĩnh lúc build không có
   request nên không có nonce, và script của nó bị chặn. Trang có session đã động vì đọc cookie; `/login` và trang lỗi thì
   không chắc, nên không dựa vào đó.
4. **`matcher` của proxy** chỉ bỏ file tĩnh (`/_next/static`, `/_next/image`, `/favicon.ico`). **Không** bỏ `/api` hay
   request prefetch như ví dụ `matcher` trong tài liệu Next: proxy còn kiểm CSRF (mục 5) cho mọi method không an toàn, và
   header do client đặt (`next-router-prefetch`, `purpose`) không được quyết định có kiểm hay không. Response của `/api/*`
   cũng mang các header dưới đây, vô hại với JSON.

```text
Content-Security-Policy: default-src 'self'; script-src 'self' 'nonce-<n>' 'strict-dynamic'; style-src 'self' 'nonce-<n>';
  img-src 'self' <MEDIA_ORIGIN> data: blob:; media-src 'self' <MEDIA_ORIGIN> blob:; connect-src 'self' <MEDIA_ORIGIN>;
  worker-src 'self' blob:; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'
  [; upgrade-insecure-requests   chỉ khi APP_ORIGIN là https]
Strict-Transport-Security: max-age=63072000; includeSubDomains   (chỉ khi APP_ORIGIN là https)
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
Cross-Origin-Opener-Policy: same-origin
X-Content-Type-Options: nosniff
Cache-Control: private, no-store   (HTML có session)
```

- **Kiểm** (test của proxy và e2e): HTML thô của một trang có session và của `/login` có `nonce="<n>"` trên mọi thẻ
  `<script>`, với `<n>` đúng bằng nonce trong header CSP của chính response đó; hai request liền nhau có nonce khác nhau;
  trang hydrate (bấm like được) và console không có vi phạm CSP. Đọc nonce trên HTML thô của response, không trên DOM:
  trình duyệt giấu giá trị thuộc tính `nonce` khỏi DOM.
- **`next dev`** thêm `'unsafe-eval'` vào `script-src` (React cần nó để dựng lại stack lỗi lúc dev, theo tài liệu CSP của
  Next); bản build không bao giờ có. Bản build không có `'unsafe-inline'` ở đâu. Ví dụ cho dev của tài liệu Next còn thay
  nonce của `style-src` bằng `'unsafe-inline'`; `next dev` chỉ làm vậy khi style thật sự bị chặn (chưa xác nhận).
- `'self'` trong `script-src` chỉ là đường lui cho trình duyệt không hiểu `'strict-dynamic'`.
- hls.js tải playlist và segment bằng XHR (`connect-src`), đẩy vào `MediaSource` qua URL `blob:` (`media-src blob:`), worker
  dựng từ `blob:` (`worker-src`). iOS dưới 17.1 không có MSE/MMS thì gán thẳng URL HLS cho `<video>` (`media-src
  <MEDIA_ORIGIN>`). Phần B thêm origin upload `UPLOAD_ORIGIN` vào `connect-src` (XHR presigned POST,
  [ADR-0018](0018-web-profiles-public-video-upload.md) §8).
- **Không thuộc tính `style` trong HTML do server render:** CSP chặn thuộc tính `style` khi không có `'unsafe-inline'`, nonce
  không áp cho thuộc tính. Giá trị động (thanh tiến độ, vị trí) gán qua ref (CSSOM), không bị CSP chặn. Kiểm bằng e2e:
  console không có vi phạm CSP.
- Không `Cross-Origin-Embedder-Policy: require-corp`: chặn HLS và thumbnail khác origin khi MinIO/CDN không gửi CORP.
- Trusted Types (report-only) để phần C, khi có đường nhận báo cáo qua BFF; React/Next chạy với Trusted Types **chưa xác
  nhận**.

## 7. Host và cổng

| Môi trường | Origin web | Cổng |
| --- | --- | --- |
| Compose, container `web` (profile `core`) | `http://localhost:3001` | publish `127.0.0.1:3001`, cổng trong container cũng 3001 |
| `make web-dev` trên máy | `http://localhost:3002` | `next dev` cổng 3002, trỏ gateway `127.0.0.1:8080` |
| k3d (phần C) | `https://svp.localhost:8443` | HTTPRoute `svp.localhost` qua Envoy; thêm SAN `svp.localhost` vào Certificate (wildcard `*.svp.localhost` không phủ tên gốc) |

- **Sửa so với dự kiến ban đầu (`127.0.0.1:3000`):** Grafana của profile `obs` đã giữ `127.0.0.1:3000`, và `make up OBS=lgtm`
  chạy cả `core` lẫn `obs`. Container dùng cùng số cổng bên trong và bên ngoài như các service khác, nên log và healthcheck
  không phải đổi số. `web-dev` lấy 3002 để chạy được cùng lúc với container khi cần so sánh.
- Origin là `localhost` (không `127.0.0.1`) vì trình duyệt coi `localhost` là ngữ cảnh an toàn; cookie vẫn theo bảng ở mục
  5. API vẫn ở `api.svp.localhost` cho client khác (k6, curl).

## 8. Feed, phát video, lượt xem, follow

- **Player:** `hls.js` bản light (`hls.js/dist/hls.light`: bỏ alt audio, phụ đề, DRM, CMCD mà clip của mình không dùng), điều
  khiển React tự viết. Kiểm `Hls.isSupported()` trước (iOS 17.1+ đi qua ManagedMediaSource); chỉ khi không có MSE/MMS mới
  gán `video.src` native. Không kiểm `canPlayType` HLS trước: Chrome gần đây có HLS native và từng lỗi phát.
- **Feed dọc:** CSS `scroll-snap-type: y mandatory` + `scroll-snap-stop: always`, mỗi item `100dvh`; IntersectionObserver
  chọn item hiện tại (`scrollsnapchange` mới có ở Chromium); **pool cố định 3 `<video>`** + 3 instance hls.js (trước, hiện
  tại, kế), đổi nguồn thay vì tạo phần tử mới (tạo/xoá `<video>` liên tục làm phình bộ nhớ trên iOS, WebKit bug 216820).
  Bắt đầu `muted playsinline`, bật tiếng trong handler chạm; bắt promise của `play()`; dừng khi `visibilitychange`; poster là
  `thumbnail_url`.
- **Lượt xem:** gọi `POST /api/videos/{id}/views` sau **2 s phát thật**: cộng dồn chênh lệch `currentTime` giữa hai
  `timeupdate` liên tiếp khi đang phát, bỏ khoảng có `seeking`; mỗi lần mount item tối đa một lần gọi. Gateway đã chặn trùng
  60 s (RL-3).
- **Like** lạc quan: đổi UI trước, lỗi thì trả lại. `stats` vắng (engagement-service chậm quá 100 ms) thì ẩn số đếm, không
  hiện 0.
- **Follow:** gateway không trả `followed_by_me`. Feed "Đang theo dõi" coi mọi tác giả là đã follow (nút Bỏ theo dõi); feed
  "Khám phá" hiện nút Theo dõi và đổi trạng thái sau khi bấm thành công (trạng thái giữ trong bộ nhớ của trang). Video của
  chính mình không có nút. Đọc trạng thái follow thật cần API mới: phần B thêm `followed_by_me` cho trang hồ sơ
  (`GET /profiles/{handle}`, [ADR-0018](0018-web-profiles-public-video-upload.md) §3); feed vẫn như trên.
- Phần A **ẩn** nút chia sẻ, mục Tải lên và Hồ sơ (route của chúng ở phần B); tác giả chỉ có avatar màu sinh từ id.
- Dữ liệu: `openapi-typescript` sinh `web/gen/api.d.ts` từ `services/gateway/openapi.yaml` (commit, kiểm không lệch như
  code Go sinh ra); `openapi-fetch` dùng ở cả server (gọi gateway) và client (gọi `/api/*` cùng path); TanStack Query cho
  feed vô hạn theo `next_cursor`, like lạc quan, chờ `Retry-After` khi 429.

## 9. i18n, font, icon

- **i18n: `next-intl`**, tiếng Việt (mặc định) và tiếng Anh, **không tiền tố URL** (link chia sẻ giống nhau mọi ngôn ngữ).
  Locale lấy từ cookie `svp_locale` (đặt khi người dùng đổi ngôn ngữ), không có thì từ `Accept-Language`, không khớp thì
  `vi`. Message chia theo namespace ở `web/messages/<vi|en>/<ns>.json` (`auth`, `common`, `errors`, `feed`, `shell`); client
  chỉ nhận namespace nó cần. Vì sao không i18next (+ `react-i18next`): `next-intl` viết cho App Router, dịch
  được trong Server Component (`getTranslations`) mà không đẩy toàn bộ message xuống bundle client; i18next cần thêm lớp nối
  cho RSC. Số rút gọn bằng `Intl.NumberFormat(locale, {notation: 'compact'})`.
- **Font Be Vietnam Pro tự host bằng `next/font/local`**, file woff2 (chỉ các độ đậm thiết kế dùng, subset Latin và tiếng
  Việt) commit trong `web/app/styles/fonts/` kèm giấy phép OFL. Không dùng `next/font/google`: nó tải font từ Google lúc
  `next build`, nên build trong Docker và CI phụ thuộc mạng ra ngoài và nội dung font không ghim được. Font phục vụ từ
  chính origin (`font-src 'self'`).
- **Icon: `lucide-react`** (import từng icon, tree-shake), thay font icon tải từ CDN: không thêm origin vào CSP, không request
  ra ngoài.
- Thiết kế do người học làm bằng Claude Design (bản chép ở `web/design/`): token màu, chữ, khoảng cách chép 1:1 vào `@theme`
  của Tailwind v4; component tính năng chỉ nhận props, không gọi API, để thay giao diện không đụng BFF và player.

## 10. Dependency npm và công cụ

Mọi gói ghim version chính xác (`rangeStrategy: pin` của Renovate ở phần C; lúc cài dùng `pnpm add --save-exact`). Thêm gói
ngoài danh sách này cần hỏi trước. Phần A **chỉ cài gói của phần A**.

**Phần A, chạy lúc runtime:**

| Gói | Lý do |
| --- | --- |
| `next`, `react`, `react-dom` | Framework (mục 1) |
| `server-only` | Import nhầm module server từ client là lỗi build |
| `redis` | Session và khoá single-flight (mục 5); client chính thức của Redis cho Node |
| `zod` | Kiểm biến môi trường và form |
| `openapi-fetch` | Client có kiểu theo `openapi.yaml`, cả server và client |
| `@tanstack/react-query` | Feed vô hạn, like lạc quan, retry theo `Retry-After` |
| `next-intl` | i18n (mục 9) |
| `hls.js` | Phát HLS (mục 8) |
| `lucide-react` | Icon (mục 9) |

**Phần A, chỉ lúc dev, build, test:**

| Gói | Lý do |
| --- | --- |
| `typescript` (dòng **6.0**), `@types/react`, `@types/react-dom`, `@types/node` | Kiểu. Không TS 7: `typescript-eslint` chưa nhận; `openapi-typescript` khai peer `^5.x` (cảnh báo peer với 6.0, đã chấp nhận, kiểm lúc cài) |
| `tailwindcss`, `@tailwindcss/postcss` | CSS tĩnh từ token `@theme`; Next dùng PostCSS |
| `eslint`, `eslint-config-next` | Lint; cấu hình của Next đã gồm `typescript-eslint`, `react`, `react-hooks`, `jsx-a11y`; thêm luật cấm `dangerouslySetInnerHTML` (WEB-1) |
| `prettier` | Định dạng |
| `openapi-typescript` | Sinh `web/gen/api.d.ts` |
| `vitest`, `@vitejs/plugin-react`, `jsdom`, `@testing-library/react`, `@testing-library/dom`, `msw` | Unit và component test; MSW giả `/api/*` |
| `@playwright/test`, `@axe-core/playwright` | E2E trên Chromium và WebKit, a11y không lỗi `serious`/`critical` |
| `size-limit`, `@size-limit/file` | Ngân sách bundle gzip, hai lớp mỗi route (bên dưới) |

**Ngân sách bundle** (`web/.size-limit.json`, `make web-check` chạy sau `next build`, gzip; kB của size-limit là 1000 byte):

| Route | Lớp 1: JS của route trên runtime của Next | Lớp 2: tải lần đầu (runtime + lớp 1) |
| --- | --- | --- |
| Feed `/` (gồm hls.js light tải lười) | ≤ 200 kB | ≤ 330 kB |
| Login `/login` | ≤ 80 kB | ≤ 200 kB |

- Lớp 1 là mọi `entryJSFiles` trong client reference manifest của route (layout gốc và nhóm, page, boundary error,
  not-found, global-error) cộng chunk chúng tải lười, trừ `rootMainFiles` của `build-manifest.json` (React, react-dom,
  router của Next, giống nhau ở mọi route). Lớp 2 cộng lại `rootMainFiles`, nên runtime phình ra cũng làm kiểm đỏ.
  Polyfill `nomodule` (trình duyệt hiện đại bỏ qua) không nằm trong lớp nào. Turbopack đặt tên chunk theo hash, nên mỗi tập
  được chép vào `.next/size-limit/<tập>/` trước khi đo.
- Feed đo trên `/` (Khám phá); `/following` dùng cùng layout và component.

**Phần B:** `@lhci/cli` (Lighthouse CI trên container đã build). Upload là XHR tự viết, không thêm gói.

**Phần C:** `@sentry/nextjs` (lỗi tới GlitchTip qua tunnel cùng origin), `@opentelemetry/api`, `@opentelemetry/sdk-node`,
exporter OTLP gRPC và instrumentation `http`/`undici` (trace server qua `instrumentation.ts`), `web-vitals` (RUM).

**Công cụ:**

- **Node 26** (`web/.nvmrc`, `engines`). Node 26 thành Active LTS ngày 2026-10-28.
- **pnpm 12**, version ghim **một chỗ**: `packageManager` của `web/package.json` (manager npm của Renovate cập nhật field
  này). Node 25 trở đi không kèm Corepack, nên máy dev (nvm), runner CI và Dockerfile **cùng một cách**:
  `npm install -g pnpm@<ver>`, với `<ver>` đọc từ `packageManager` lúc chạy (`node -p` trên `web/package.json`) thay vì chép
  số; chỗ nào buộc phải ghi số thì có chú thích `# renovate: datasource=npm depName=pnpm` ngay trên dòng (dạng của ADR-0015
  §10). `make web-install` kiểm `pnpm --version` khớp, lệch thì in đúng lệnh cài. CI **không** dùng `pnpm/action-setup`
  (repo chỉ cho action của GitHub và `sigstore/cosign-installer`).
- Setting pnpm ở `web/pnpm-workspace.yaml`: `minimumReleaseAge: 4320` (3 ngày, khớp Renovate), `strictDepBuilds: true`,
  `allowBuilds` chỉ liệt kê gói thật cần script cài đặt (mặc định rỗng, mỗi gói thêm vào có lý do), `trustPolicy:
  no-downgrade`, `blockExoticSubdeps: true`. CI và Dockerfile cài bằng `--frozen-lockfile`. Thêm `ignoredOptionalDependencies:
  [sharp]` (optimizer ảnh, đã tắt bằng `images.unoptimized`, không để nó vào image).
- **Ngoại lệ `trustPolicyExclude: [semver@6.3.1]`:** `trustPolicy: no-downgrade` từ chối bản này vì nó là bản backport (vá
  ReDoS CVE-2023-25883 cho dòng 6.x) đăng ngày 2023-07-10 **không** provenance, sau khi 7.5.4 đã có provenance; thứ tự đăng
  làm nó trông như bị hạ cấp. `eslint-plugin-import` (qua `eslint-config-next`) cần `^6.3.1`. Ngoại lệ ghim đúng một
  version, kiểm bằng tay; gói khác không được miễn.
- **Quy trình ngoại lệ cho bản vá bảo mật mới hơn 3 ngày:** `minimumReleaseAge` chặn cả Renovate, `pnpm install
  --frozen-lockfile` ở CI lẫn Dockerfile, nên bản vá CVE (ví dụ của `next`) vừa phát hành không cài được. PR vá thêm
  `minimumReleaseAgeExclude: [<gói>@<version>]` vào `web/pnpm-workspace.yaml`, ghi lý do và link advisory trong comment
  cạnh dòng đó và trong mô tả PR; PR Renovate kế tiếp sau đủ 3 ngày xoá dòng ấy. Ngoại lệ chỉ theo đúng version của gói
  cần vá; quy tắc chung không nới.
- **CI** (`.github/workflows/ci.yml`): job `web` (Node theo `web/.nvmrc`, pnpm `npm install -g pnpm@<packageManager>`, cache
  store pnpm theo hash lockfile, Redis db 15 là service container) chạy `make web-install`, `make web-check`, `make
  web-generate-check`; job `check` chạy `make check-go`; `ci-ok` cần đủ 7 job (thêm `web`).

## 11. Phạm vi các phần và việc để sau

- **Phần chuẩn bị backend:** mục 2–4 (user-service, gateway, `openapi.yaml`, `make smoke` thêm refresh và logout).
- **Phần A (compose):** mục 5–10; container `web` trong profile `core`; `make web-install`, `web-dev`, `web-generate`,
  `web-check`, `web-e2e`. Xong khi e2e xanh trên Chromium và WebKit, axe không lỗi serious/critical, console không vi phạm
  CSP, size-limit đạt, và có số đo thời gian tới khung đầu (vuốt → `playing`, p50/p95 trên 20 lần) cùng bộ nhớ container
  web (cgroup theo `docker stats`).
- **Phần B:** upload XHR, `/v/:id` công khai có OG (route đọc công khai ở gateway, chỉ video `READY`, rate limit theo IP), hồ
  sơ tối thiểu và "video của tôi", CORS MinIO đúng origin web (`MINIO_API_CORS_ALLOW_ORIGIN`), Lighthouse CI. Chi tiết
  chốt ở [ADR-0018](0018-web-profiles-public-video-upload.md): handle không đổi và tên hiển thị, RPC và route hồ sơ, danh
  sách video theo tác giả, `author` ghép song song `stats`, `GET /public/videos/{id}` với lớp rate limit `public`, route web,
  upload và `UPLOAD_ORIGIN`, CORS MinIO, Lighthouse chạy local (`make web-lighthouse`, chưa vào CI), ngân sách bundle của
  `/v/[id]` và `/upload`. Kết quả kiểm ở mục "Kết quả phần B" của ADR-0018.
- **Phần C (k3d):** image distroless, ký, quét, Kyverno, promote; release Helm `web` (HTTPRoute `svp.localhost`, 2 replica,
  PDB, canary, NetworkPolicy); GlitchTip, OTel, RUM. **Gateway tin `traceparent` chỉ từ pod web** (nguồn tin cậy như
  `TRUSTED_PROXY_CIDRS`); khi làm, ADR-0011 được đánh dấu "chỉnh bởi" ADR ghi chi tiết đó. Trace từ trình duyệt (SDK
  OTel browser còn 0.x) chưa làm.
- **E2E trong CI:** giai đoạn 6, cùng "stack chạy trong CI" mà ADR-0015 §12 đã dời. 5b chạy e2e local; CI chạy lint, type,
  unit, size-limit và kiểm `web/gen/api.d.ts` không lệch.
- **MinIO community đã archive:** ngoài phạm vi 5b; quyết ở giai đoạn 6/7 bằng ADR riêng. CORS toàn cục đủ cho lab.

## Kết quả phần A (đo ngày 2026-10-22)

Điều kiện chung: MacBook (Mac14,7, 16 GB RAM, macOS 27.0), cắm điện; stack compose profile `core` (`make up`, không `obs`,
không k3d), ngay sau `make smoke`; Playwright 1.64.1, Chromium 156.0.8078.4, WebKit 27.2, một worker, chạy lần lượt hai
trình duyệt. Một lượt `make measure-web` (gồm toàn bộ e2e) ở chế độ chứng cứ (`SVP_E2E_EVIDENCE`: trace và video của mọi
test bật), nên số đo có thêm tải ghi trace và video.

| Kiểm | Kết quả |
| --- | --- |
| e2e (`make measure-web`) | 32/32 pass: Chromium 16/16, WebKit 16/16 (luồng chính, WEB-1/2/4/6, CSP, axe ở login, register, feed, đuôi feed lúc tải trang sau, Back trước và sau 5 s, khung đầu, ảnh chứng cứ) |
| Thời gian tới khung đầu (vuốt → `playing`, 20 lần mỗi trình duyệt) | Chromium p50 13 ms, p95 21 ms, max 21 ms; WebKit p50 20 ms, p95 141 ms, max 149 ms. Cuộn `instant` và video kế đã được pool tải trước, nên đây là thời gian đổi video trong pool, không gồm tải playlist qua mạng thật. Từ phần B video kế chỉ nạp khi video hiện tại đã chạy, nên số này tăng (ADR-0018, mục Kết quả phần B) |
| Bộ nhớ container `web` (`docker stats`, bộ nhớ cgroup trừ file cache không hoạt động; không phải RSS của tiến trình Node) | 52,8 MiB lúc nghỉ (sau `make up` và `make smoke`, trước e2e), 96,3 MiB ngay sau e2e; giới hạn 256 MiB |
| size-limit (gzip, `make web-check`) | Feed: 177,19 kB / 200 kB trên runtime, 308,45 kB / 330 kB tải lần đầu. Login: 48,42 kB / 80 kB, 179,68 kB / 200 kB |
| Cookie `svp_sid` trên `http://localhost:3001` ở WebKit | Nhận và gửi lại bình thường: mọi luồng đăng nhập của WebKit qua; test WEB-6 thấy `HttpOnly`, `SameSite=Lax`, `Path=/`, không `Secure`, sid mới sau login (sid cài sẵn bị thay), cookie cũ sau logout → 401. Dạng `__Host-Http-` + `Secure` kiểm ở k3d (phần C) |
| `make smoke` | 45 bước pass, gồm refresh 200, refresh lại token đã dùng → 401 `INVALID_REFRESH_TOKEN` và token mới nhất của họ cũng 401, logout hai lần 204, refresh sau logout 401 |
| Test đơn vị và integration | `make check` xanh; thêm ba lượt `make test TESTFLAGS=-count=1` (42 gói ok, 1 143 test PASS mỗi lượt, 4 SKIP cố định của `internal/objstore` cần stack) và ba lượt Vitest với Redis db 15 (30 file, 405 test, không skip) |

Lượt e2e đầu tiên ở chế độ chứng cứ đỏ 13 test WebKit vì chính công cụ: Playwright chèn `<style>` vào trang mỗi lần chụp ảnh
ở WebKit, CSP chặn và watcher CSP của e2e báo. Chạy lại đúng các file đó: đỏ y hệt khi bật chứng cứ, 14/14 xanh khi tắt.
Chế độ chứng cứ vì thế không chụp ảnh tự động cuối test ở WebKit, và spec chụp màn hình không gắn watcher CSP; các spec còn
lại vẫn kiểm CSP trên cùng các trang.

**Liệt kê tài khoản (threat model WEB-12)**, đo qua gateway `127.0.0.1:8080` ngay sau smoke: login sai mật khẩu (5 tài
khoản vừa đăng ký, mỗi tài khoản 4 lần) và login email không tồn tại (20 email khác nhau), xen kẽ, cách nhau 1,1 s, chỉ tính
401 `INVALID_CREDENTIALS` (40/40 mẫu hợp lệ). Sai mật khẩu p50 58,7 ms, p95 61,0 ms; email không tồn tại p50 59,9 ms, p95
64,8 ms. Chênh lệch nằm trong nhiễu của 20 mẫu: user-service so hash giả (`VerifyDummy`) khi không thấy email. Đăng ký lại
email đã có trả 409 `EMAIL_ALREADY_REGISTERED`, đường dò email có chủ ý (JWT-6).

**Chưa chạy ở phần A** (máy 16 GB, dời lên giai đoạn cloud): `make up OBS=lgtm` + `make drill-obs-threats`. Riêng OPS-1
với cổng mới đã kiểm tĩnh: `docker compose config` của `core` + `obs` publish đúng 8 cổng trên `127.0.0.1` (thêm `web`
3001), khớp danh sách mong đợi của `deploy/compose/drills/obs-threats.sh`.

## Hệ quả

- Được:
  - JWT-3 có thu hồi: logout và việc phát hiện dùng lại cắt được phiên; token bị lộ từ một nhánh bị phát hiện khi nhánh kia
    dùng.
  - Token không bao giờ ra trình duyệt; XSS không lấy được token (chỉ dùng được phiên trong lúc trang đang mở).
  - CSRF chặn bằng Fetch Metadata/Origin, không dựa vào SameSite; nonce + `strict-dynamic` chặn script lạ.
  - Contract chỉ thêm field và RPC, client cũ (k6, smoke) không phải đổi.
- Phải trả:
  - Thêm dependency `redis` cho Node, db Redis 9, một bảng ở `svp_user`, và một transaction mỗi lần refresh.
  - Access token còn sống tới 1 giờ sau logout (JWT-3, phần chấp nhận); không có danh sách thu hồi theo `jti` của access
    token.
  - Response refresh bị mất làm người dùng phải đăng nhập lại (không cửa sổ chồng).
  - Ở compose mọi người dùng web chung bucket IP; cookie không `Secure` trên `http://localhost` và đi kèm mọi cổng của
    `localhost`.
  - Mọi trang render động; vá CVE của Next phải nhanh.
  - Bảng `refresh_tokens` chưa có job dọn.
- Xem lại khi:
  - Log `refresh token reused` vượt 0,1% số lần refresh trong một ngày (dấu hiệu single-flight hỏng hay mạng chập chờn): xét
    cửa sổ chồng ngắn.
  - Có client thứ hai không làm single-flight được (app di động): xét cửa sổ chồng hay ràng buộc token theo người gửi
    (DPoP).
  - Trước bài k6 của giai đoạn 6 (k6 login hàng loạt) hay khi `refresh_tokens` vượt 1 triệu dòng: làm job dọn.
  - Lên cloud (giai đoạn 7): IP client thật qua load balancer, Redis/Valkey có xác thực và TLS cho session.
  - WebKit sửa bug 232088: bỏ dạng cookie không tiền tố.
