# 0010. Giai đoạn 2 phần C: Redis cho rate limit và cache feed khám phá, timeout/retry/circuit breaker ở gateway, job dọn upload bỏ dở

- Trạng thái: Chấp nhận; §2 (bảng lớp rate limit, thêm `refresh`) chỉnh bởi [0016](0016-web-client.md)
- Ngày: 2026-10-11

## Bối cảnh

- Phần A và B của giai đoạn 2 đã chạy đầu-cuối: upload tới `READY`, follow, feed, like, lượt xem
  ([ADR-0008](0008-async-upload-pipeline-stage2a.md), [ADR-0009](0009-engagement-feed-stage2b.md)). Hai ADR đó để lại
  cho phần C: Redis; cache feed khám phá + singleflight ([ADR-0005](0005-feed-fan-out-on-write.md) luật 6); rate limit ở
  gateway gồm RL-3 và RL-6; timeout, retry, circuit breaker giữa service; job dọn upload bỏ dở
  ([ADR-0004](0004-direct-upload-and-hls.md) luật 4) và UP-7 (ADR-0008 mục 13, ADR-0009 mục 14).
- Biện pháp giai đoạn 2 của [threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn) còn mở: JWT-4, JWT-6, JWT-9
  (rate limit login/register), UP-7, RL-1 tới RL-3, RL-6. Hành vi khi Redis lỗi đã chốt theo loại route ở
  [§4.4](../threat-model.md#44-rate-limit-ở-gateway); ADR này chốt ngưỡng và cách làm.
- [§4.4](../threat-model.md#44-rate-limit-ở-gateway) hẹn chốt ngưỡng bằng lab `rate-limiter`. Phần C không làm lab đó: ngưỡng ở mục 2 chọn bằng lập luận và xem lại bằng k6 ở giai đoạn 6. Lab
  `cache-stampede` và `distributed-cron-lock` cũng không làm, lý do ở mục 3 và 5.
- NFR liên quan ([architecture §2](../architecture.md#2-yêu-cầu-phi-chức-năng)): feed p99 < 150 ms tại 1.000 req/s; khởi
  tạo upload thành công 99,9%. [architecture §3.3](../architecture.md#33-rút-ra-gì) điểm 3: cache dùng để chống key nóng
  (feed khám phá), không phải vì tổng tải.
- Hiện trạng đo được ở `make drill-engagement-down` (phần B): tắt engagement-service thì feed vẫn trả nhanh không có
  `stats`, nhưng like treo tới timeout 3 s của gateway rồi nhận 504; mỗi request tới service chết đều chờ đủ 3 s.
- Ràng buộc máy: Redis 8.8.0 native ở `127.0.0.1:6379`, dùng chung với dự án khác; bảng db theo service ở `CLAUDE.md`
  (gateway db 10, feed-service db 14). Không thêm container nào cho phần C.

## Kiểm chứng (đã kiểm ngày 2026-10-11)

| Kiểm gì | Lệnh | Kết quả |
| --- | --- | --- |
| Version module | `go list -m -versions <module>`, `go list -m -json <module>@<version>` (chỉ đọc module proxy) | `github.com/redis/go-redis/v9` bản ổn định mới nhất `v9.23.0` (2026-10-05, `go 1.26.0`); `github.com/sony/gobreaker/v2` mới nhất `v2.4.0` (`go 1.22.0`, không có dependency lúc chạy, chỉ `testify` cho test của chính nó). Cả hai build được bằng Go 1.27.2 |
| API go-redis | Đọc `options.go` của `v9.23.0` trong module cache | Có `ParseURL`, `DialTimeout`, `ReadTimeout`, `WriteTimeout`, `PoolTimeout`, `ContextTimeoutEnabled` |
| API gobreaker | Đọc `gobreaker.go` của `v2.4.0` | `Settings` có `MaxRequests`, `Interval`, `BucketPeriod` (cửa sổ trượt theo ô), `Timeout`, `ReadyToTrip`, `OnStateChange`, `IsSuccessful`, `IsExcluded` |
| Retry của grpc-go | Đọc `stream.go` (`shouldRetry`) và `clientconn.go` (`retryThrottler`) của `v1.84.0` | Backoff nhân hệ số ngẫu nhiên 0,8–1,2; token chỉ bị trừ ở lần thử lỗi với mã nằm trong `retryableStatusCodes`, cộng ở mỗi lời gọi thành công; ngưỡng ngừng retry là `maxTokens / 2` |
| `golang.org/x/sync` | `go.mod`, `go.sum` | `v0.24.0` đã có, dạng `// indirect` |
| Redis local | `redis-cli -p 6379 INFO server`, `CONFIG GET maxmemory*`, `INFO keyspace` | Redis 8.8.0; `maxmemory 0`, `maxmemory-policy noeviction`; db 0, 5 và 7 (433 khoá) chứa dữ liệu dự án khác; db 15 trống |
| Đua `CompleteUpload` với `FAILED` | Đọc `services/video-service/internal/server/server.go`, `queries/videos.sql` | `MarkVideoProcessing` chỉ đổi dòng `WHERE status = 'UPLOADING'`; video đã `FAILED` (trước hay trong lúc gọi) trả `FAILED_PRECONDITION` `VIDEO_FAILED` |
| Khoá relay | `internal/outbox/relay.go` | `lockID = 0x7376706f75746278` (ASCII `svpoutbx`) |
| `video_id` trên route | `services/gateway/internal/api/api.go`, `internal/ids/ids.go` | Gateway chuyển `{video_id}` nguyên văn, engagement-service kiểm bằng `ids.Parse` (chỉ nhận UUID dạng chuẩn) |
| Chuẩn hoá email | `services/user-service/internal/server/server.go` | `strings.ToLower(strings.TrimSpace(email))` |
| `title` ở feed-service | `services/feed-service/internal/projector/projector.go` | `validTitle` kiểm bản đã trim nhưng lưu `e.GetTitle()` nguyên văn |

## 1. Redis

### Các lựa chọn về client

#### A. `github.com/redis/go-redis/v9`

- Được: client chính thức của Redis, phổ biến nhất trong Go; `Script` tự dùng `EVALSHA` và nạp lại khi cache script của
  server trống; timeout tách cho dial, đọc/ghi, chờ pool; nhiều ví dụ.
- Mất: kéo thêm vài module phụ vào `go.sum` (`xxhash`, `xxh3`, `go.uber.org/atomic`...).

#### B. `github.com/redis/rueidis`

- Được: nhanh hơn nhờ pipeline tự động; có client-side caching.
- Mất: API khác hẳn (dựng lệnh bằng builder), ít ví dụ và tài liệu hơn; tốc độ và client-side caching không cần ở vài
  nghìn lệnh mỗi giây của lab.

### Các lựa chọn về cách ly dữ liệu test

#### A. Một db riêng cho test, mỗi test một tiền tố khoá ngẫu nhiên, chỉ xoá khoá của mình

- Được: không chạm db của service hay của dự án khác; test chạy song song không giẫm nhau; không cần `FLUSHDB`.
- Mất: test phải dọn bằng `SCAN` theo tiền tố.

#### B. Redis giả trong bộ nhớ (`miniredis`)

- Mất: thêm dependency; Lua và `TIME` của bản giả không chắc giống Redis thật, mà đó đúng là phần cần test nhất.

#### C. `FLUSHDB` trước mỗi test

- Mất: một lần gõ sai số db là xoá dữ liệu của service hay của dự án khác; không chạy song song được.

### Quyết định về Redis

Chọn client **A** (`go-redis` **v9.23.0**, đúng lựa chọn đã hẹn ở
[ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) mục 3) và cách ly test **A**.

- **Cấu hình:** một biến `REDIS_URL` dạng `redis://<host>:<port>/<db>`. Mặc định khi chạy native: gateway
  `redis://127.0.0.1:6379/10`, feed-service `redis://127.0.0.1:6379/14` (bảng db trong `CLAUDE.md`); compose đặt
  `redis://host.docker.internal:6379/<db>` (Redis chạy native trên máy, như Postgres).
- **Gói dùng chung `internal/redisx`** dựng client từ URL với timeout ngắn: dial **100 ms**, đọc/ghi **50 ms**, chờ pool
  **50 ms**, `ContextTimeoutEnabled: true` (hạn của context đè timeout của client). Lỗi không in URL: trên cloud URL
  chứa mật khẩu.
- **Service khởi động được khi Redis lỗi:** không ping bắt buộc lúc start; `/readyz` **không** kiểm Redis. Mọi chỗ dùng
  Redis đều có đường lui (mục 2, 3), nên Redis lỗi không phải lý do để k8s rút pod khỏi load balancer: rút thì mất cả
  đường lui.
- **Tiền tố khoá theo service:** gateway `svp:gw:`, feed-service `svp:feed:`. Thành phần dùng Redis nhận tiền tố qua
  constructor (test truyền tiền tố riêng). Số db không phải ranh giới quyền (IN-7); tiền tố chuẩn bị cho ACL theo tiền
  tố trên cloud.
- **Mọi khoá có TTL.** Redis local `maxmemory 0`, `noeviction`: khoá không TTL thì nằm mãi, và khi đầy bộ nhớ máy thì
  mọi lệnh ghi lỗi, kể cả của dự án khác.
- **Test:** db **15** qua `SVP_TEST_REDIS_URL` (mặc định trong `Makefile`: `redis://127.0.0.1:6379/15`). Helper
  `internal/redistest` từ chối URL không phải `127.0.0.1`/`localhost` cổng 6379 db 15, cho mỗi test một tiền tố ngẫu
  nhiên và khi xong chỉ xoá khoá của tiền tố đó; **không** `FLUSHDB`/`FLUSHALL`. Thiếu biến thì `t.Skip`, như `pgtest`.
  db 0, 5 và **7** đang chứa dữ liệu dự án khác: không dùng.
- **Tài nguyên:** không thêm container. Khoá rate limit ~100 B, sống tối đa bằng thời gian nạp đầy (mục 2); cache khám
  phá tối đa 50 khoá (một khoá mỗi `page_size` 1–50) × vài chục KB, sống 5 s. Tổng cỡ vài MB ở tải lab.

## 2. Rate limit ở gateway

Biện pháp: JWT-4, JWT-6, JWT-9 (rate limit login), UP-7 (phần route), RL-1, RL-2, RL-3, RL-6 ([threat model §4.1, §4.2,
§4.4](../threat-model.md#44-rate-limit-ở-gateway)).

### Các lựa chọn về thuật toán

#### A. Fixed window: `INCR` + `EXPIRE` theo cửa sổ

- Được: đơn giản nhất, hai lệnh.
- Mất: ở mép cửa sổ cho qua gấp đôi ngưỡng (cuối cửa sổ này + đầu cửa sổ sau); không có khái niệm burst tách khỏi tốc
  độ.

#### B. Sliding log bằng `ZSET`

- Được: chính xác tuyệt đối.
- Mất: bộ nhớ O(số request) mỗi khoá; route đọc 600/phút là 600 phần tử mỗi người dùng.

#### C. Sliding window counter (hai khoá, nội suy)

- Được: bộ nhớ nhỏ, sai số nhỏ.
- Mất: là xấp xỉ; hai khoá mỗi lớp; burst vẫn không tách khỏi tốc độ.

#### D. GCRA (generic cell rate algorithm) bằng một Lua script

Tương đương token bucket nhưng chỉ lưu một mốc thời gian TAT (theoretical arrival time) mỗi khoá.

- Được: một khoá, một số; tốc độ và burst là hai tham số riêng; chạy nguyên tử trong Redis; lấy giờ bằng `TIME` của
  Redis nên nhiều instance gateway không lệch đồng hồ nhau; tính sẵn được `Retry-After`.
- Mất: ~30 dòng Lua phải tự viết và test; công thức khó đọc hơn bộ đếm.

#### E. Thư viện `github.com/go-redis/redis_rate`

- Được: GCRA viết sẵn.
- Mất: thêm một dependency cho ~30 dòng Lua; bộ đếm dự phòng trong bộ nhớ (bên dưới) vẫn phải tự viết cùng công thức.

#### F. Chỉ đếm trong bộ nhớ của từng instance

- Mất: không chung giữa các replica: N replica là ngưỡng thật gấp N; mỗi lần deploy là bộ đếm về 0.

### Các lựa chọn về IP client

#### A. Địa chỉ kết nối (`RemoteAddr`), bỏ mọi header do client đặt

- Được: client không giả được (RL-1); đúng ở compose, nơi client nối thẳng vào gateway.
- Mất: sau proxy (Envoy Gateway ở giai đoạn 4, load balancer ở giai đoạn 7) mọi client chung một địa chỉ.

#### B. Đọc `X-Forwarded-For` với số hop proxy tin cậy cấu hình được

- Được: đúng sau proxy.
- Mất: chưa có proxy nào để chốt số hop; đặt sai là mọi client chung bucket hoặc client giả được IP (RL-1).

### Quyết định về rate limit

Chọn thuật toán **D** và IP **A**. Số hop proxy tin cậy là việc bắt buộc của giai đoạn 4 (Hệ quả).

**Ngưỡng** (rate / burst theo GCRA; cột "Redis lỗi" theo bảng §4.4):

| Lớp | Route | Khoá | Redis tốt | Redis lỗi |
| --- | --- | --- | --- | --- |
| `register` | `POST /auth/register` | IP | 60/giờ, burst 20 | đóng mềm: bộ đếm trong bộ nhớ 30/giờ, burst 10 |
| `login-ip` | `POST /auth/login` | IP | 60/phút, burst 30 | đóng mềm: 30/phút, burst 15 |
| `login-email` | `POST /auth/login` | (IP, email) | 10/giờ, burst 5 | đóng mềm: 5/giờ, burst 3 |
| `upload` | `POST /videos` | `user_id` | 30/giờ, burst 10 | đóng mềm: 15/giờ, burst 5 |
| `write` | `PUT`/`DELETE /videos/{id}/like`, `POST /videos/{id}/views`, `PUT`/`DELETE /me/following/{id}`, `POST /videos/{id}/complete` | `user_id` | 120/phút, burst 60 | mở |
| `read` | `GET /feed/following`, `GET /feed/explore`, `GET /videos/{id}` | `user_id` | 600/phút, burst 200 | mở |
| `view-once` (RL-3) | `POST /videos/{id}/views` | (`user_id`, `video_id`) | một lượt mỗi 60 s | mở (chuyển tiếp) |

Lý do từng con số:

- `register` 60/giờ, burst 20: người thật đăng ký một lần. Burst 20 đủ cho `make smoke` và mọi diễn tập chạy trong một
  giờ từ cùng một IP (mọi request diễn tập đi ra từ một IP bridge của Docker). Hết burst thì một tài khoản mỗi phút: dò
  email đã đăng ký (JWT-6) và tạo tài khoản giả để đẩy lượt xem (RL-3) hay ghi id rác (RL-6) chậm lại ở mức một IP.
- `login-ip` 60/phút, burst 30: nhiều người sau cùng một NAT (văn phòng, mạng di động) vẫn đăng nhập được; một IP không
  thử được hàng loạt mật khẩu trên nhiều email nhanh hơn một lần mỗi giây. Semaphore hash ở user-service (JWT-9) vẫn
  chặn RAM phía sau.
- `login-email` 10/giờ, burst 5: người thật gõ sai vài lần vẫn vào được; dò một tài khoản từ một IP còn 10 mật khẩu mỗi
  giờ. Khoá theo (IP, email) chứ không theo email, nên kẻ dò không khoá được chủ thật đăng nhập từ IP khác, và không
  khoá tài khoản sau N lần sai (JWT-4).
- `upload` 30/giờ, burst 10: người đăng một loạt 10 video liền vẫn được; mỗi lần gọi mở quyền ghi 500 MB (UP-7), nên
  trần theo giờ cộng với giới hạn 3 video đang upload (mục 5) chặn việc mở form hàng loạt.
- `write` 120/phút, burst 60: người cuộn nhanh like và xem cỡ một hành động mỗi giây, burst cho lúc app gửi dồn sau khi
  mất mạng; script ghi `video_id` ngẫu nhiên (RL-6) bị giữ ở 2 lần mỗi giây mỗi tài khoản.
- `read` 600/phút, burst 200: người thật đọc vài trang mỗi phút; 200 không chặn ai dùng thật mà vẫn chặn một vòng lặp.
  Chống quá tải ở route đọc là việc của timeout, cache và breaker (§4.4), không phải của rate limit.
- `view-once` 60 s: video dài tối đa 3 phút; xem lại sau một phút vẫn được tính, gọi liên tục thì không.
- k6 (giai đoạn 6) dùng nhiều tài khoản thay vì nới ngưỡng, như §4.4 đã ghi.

**Cách đếm:**

- Mỗi lần gọi đều được đếm, kể cả lần thành công. Route `healthz`/`readyz` không giới hạn.
- GCRA: khoảng phát `T` = chu kỳ / rate (ví dụ `register`: 1 giờ / 60 = 60 s). Mỗi request: `tat' = max(tat, now) + T`;
  cho qua nếu `tat' − now ≤ T × burst`, lưu `tat'` với `PEXPIRE` bằng `tat' − now` (tối đa `T × burst`, thời gian nạp
  đầy); từ chối thì không đổi `tat`, `Retry-After` = `tat' − now − T × burst`. Cả bước đọc, tính và ghi nằm trong **một
  Lua script** (`EVALSHA`), giờ lấy bằng `TIME` của Redis.
- `login`: kiểm `login-ip` trước khi đọc thân request; qua rồi mới decode JSON và kiểm `login-email`. Lớp per-user
  (`upload`, `write`, `read`, `view-once`) chạy **sau** kiểm JWT, khoá theo `user_id` đã xác thực.
- `POST /videos/{id}/views` qua cả `write` lẫn `view-once`.

**Redis lỗi (RL-2):**

- Mỗi lần gọi Redis có hạn **50 ms**; lỗi hoặc quá hạn đều tính là "Redis lỗi".
- **Đóng mềm** = bộ đếm GCRA cùng công thức, viết bằng Go, trong bộ nhớ của từng instance (map + mutex + quét định kỳ
  các khoá đã hết hạn để map không phình mãi), ngưỡng bằng nửa (bảng trên). **Mở** = cho qua.
- Log WARN `rate limit store unavailable, using fallback` không quá một dòng mỗi 10 s. Metric và cảnh báo khi đang chạy
  bộ đếm dự phòng ở giai đoạn 3 (RL-2).

**Vượt ngưỡng:** 429 `application/problem+json` ([architecture
§8.4](../architecture.md#84-mã-lỗi-grpc-sang-http-ở-gateway)) với `code` **`RATE_LIMITED`**, `detail`
`"too many requests"`, header `Retry-After` (giây, làm tròn lên, tối thiểu 1).

**RL-3:** khoá view-once đặt bằng `SET NX PX 60000`. Lượt xem thứ hai của cùng cặp trong 60 s trả **202 như thường nhưng
không gọi engagement-service**: không lộ cho client là bị bỏ, và không có gì để client thử lại. Chuyển tiếp `RecordView`
mà lỗi (503/504) thì `DEL` khoá view-once (best-effort), để lần thử lại của client vẫn được đếm. Redis lỗi thì chuyển
tiếp như thường (mở).

**Khoá:** `svp:gw:rl:<lớp>:<định danh>`.

- IP client lấy từ **địa chỉ kết nối** (`RemoteAddr`), **bỏ qua** `X-Forwarded-For`, `X-Real-IP`, `Forwarded` và mọi
  header do client đặt (RL-1). IPv6 gộp theo /64: một thuê bao thường được cả một /64, không gộp thì đổi địa chỉ trong
  dải là có bucket mới.
- Email trong khoá là SHA-256 (hex, cắt 32 ký tự) của email đã chuẩn hoá như user-service (`TrimSpace` + `ToLower`):
  **không có email thô trong Redis** (JWT-8). Không dùng HMAC có khoá bí mật: thêm một secret phải quản lý, trong khi
  khoá chỉ sống tối đa 30 phút (`login-email`: 5 × 6 phút).
- Khoá per-user dùng `user_id` đã xác thực; `view-once` là `<user_id>:<video_id>`, chỉ đặt khi `{video_id}` là UUID
  dạng chuẩn (`internal/ids.Parse`: 36 ký tự thường). Id khác thì không ghi Redis cho `view-once` và chuyển tiếp như
  hiện nay, engagement-service trả 400 `INVALID_VIDEO_ID`. Không kiểm thì mỗi id rác dài tới ~16 KB (giới hạn header)
  thành một khoá sống 60 s, và cách viết khác của cùng một UUID (chữ hoa, `{...}`) lách được RL-3.

**Vị trí:** `services/gateway/internal/ratelimit` (Lua, bộ đếm dự phòng, lớp quyết định theo route), gắn ở
`services/gateway/internal/api`. 429 của các route ghi vào `services/gateway/openapi.yaml`.

## 3. Cache feed khám phá

[ADR-0005](0005-feed-fan-out-on-write.md) luật 6 và [architecture §3.3](../architecture.md#33-rút-ra-gì) điểm 3: feed
khám phá là một danh sách chung, mọi người dùng mới cùng đọc trang đầu: một key nóng. Hiện mỗi request là một truy vấn
Postgres.

### Các lựa chọn về chỗ đặt cache

#### A. Cache-aside ở feed-service

- Được: feed-service là chủ của read model, biết khi nào dữ liệu đổi; gateway giữ vai trò ghép, không giữ trạng thái
  feed.
- Mất: vẫn tốn một lời gọi gRPC gateway → feed-service mỗi request.

#### B. Cache ở gateway

- Được: bớt được lời gọi gRPC.
- Mất: gateway phải hiểu dữ liệu của feed-service; hai nơi cùng giữ bản của một read model.

### Các lựa chọn về làm mới

#### A. Chỉ TTL ngắn, không xoá chủ động

- Được: đơn giản; không có cuộc đua giữa xoá và ghi lại.
- Mất: video mới vào khám phá chậm tối đa bằng TTL.

#### B. Xoá cache khi có `video.ready`

- Mất: cuộc đua kinh điển của cache-aside: một request đọc Postgres trước khi transaction fan-out commit, consumer xoá
  cache, rồi request đó ghi bản cũ vào cache; bản cũ sống tới hết TTL. Muốn đúng phải thêm version hay xoá trễ hai lần,
  phức tạp hơn cái lợi.

### Các lựa chọn về chống stampede

#### A. Singleflight trong tiến trình

- Được: khi cache trống, N request đồng thời của một instance chỉ sinh một truy vấn; không thêm round trip nào.
- Mất: R replica thì tối đa R truy vấn mỗi lần hết hạn.

#### B. Khoá phân tán bằng `SET NX` trong Redis

- Được: cả cụm chỉ một truy vấn.
- Mất: thêm một round trip; phải giải bài toán khoá hết hạn giữa chừng và người chờ poll lại cache; Redis lỗi thì cần
  đường lui riêng.

#### C. Làm mới sớm theo xác suất (XFetch)

- Mất: vẫn cần A cho lúc cache trống hẳn; thêm tham số để chỉnh mà chưa có số đo cần tới.

### Quyết định về cache feed khám phá

Chọn chỗ đặt **A**, làm mới **A**, chống stampede **A**. Lab `cache-stampede` không cần ở quy mô này: R truy vấn mỗi 5 s
là không đáng kể với Postgres.

- Cache-aside ở **feed-service**, chỉ **trang đầu** (`page_token` rỗng). Khoá
  `svp:feed:explore:v1:first:<page_size đã chuẩn hoá>` (0 → 10, trên 50 → 50, như `parsePage`), giá trị là bytes
  protobuf của `GetExploreFeedResponse`, **TTL 5 s**. `v1` trong khoá để đổi định dạng giá trị mà không đọc nhầm bản cũ.
  Trang sau không cache: không nóng, và mỗi token là một khoá.
- **Không** xoá chủ động khi có video mới (lý do ở lựa chọn B). Video mới vào khám phá chậm tối đa 5 s, chấp nhận vì
  khám phá không có NFR độ tươi riêng (NFR 10 s là của feed following).
- **Singleflight** (`golang.org/x/sync/singleflight`; module `golang.org/x/sync` đã có trong `go.mod` dạng
  `// indirect`, chỉ thành direct, không thêm module) cho mỗi khoá. Lần đọc Postgres của singleflight chạy với context
  tách khỏi request đầu tiên (`context.WithoutCancel` + hạn riêng **2 s**), để client đầu tiên huỷ không làm hỏng các
  request đang chờ cùng kết quả.
- Redis lỗi hoặc quá **50 ms** thì đọc Postgres (vẫn qua singleflight), không báo lỗi cho client; ghi cache lỗi thì bỏ
  qua. Postgres lỗi thì trả lỗi như hiện nay.
- Mỗi lần đọc Postgres cho trang đầu log INFO `explore page loaded from database` kèm `page_size`; diễn tập đếm dòng log
  này.
- **Số đo:** N request đồng thời lúc cache trống → đúng **1** lần đọc Postgres (test Go và diễn tập trên stack). Trước
  thay đổi là N lần theo cấu tạo (mỗi request một truy vấn).

## 4. Timeout, retry, circuit breaker, bulkhead

### Kiểm kê lời gọi ra ngoài

Đọc code ngày 2026-10-11. "Deadline gRPC" là hạn của gateway truyền xuống qua gRPC; pgx và SDK S3 huỷ lời gọi khi
context hết hạn.

| Service | Lời gọi | Hạn đang áp | Ở đâu |
| --- | --- | --- | --- |
| gateway | gRPC tới user, video, feed, engagement (mọi route) | 3 s (`callTimeout`) | `services/gateway/internal/api/api.go` (`callTimeout`, `callContext`) |
| gateway | `GetStats` khi ghép feed | 100 ms (`statsTimeout`) | `api.go` (`statsTimeout`, `addStats`) |
| gateway | `Health/Check` của `/readyz` | 1 s (`readyTimeout`) | `api.go` (`readyTimeout`, `readyz`) |
| gateway | Redis (mới) | 50 ms | mục 1, 2 |
| gateway | HTTP vào (RL-4) | đọc header 5 s, đọc 10 s, ghi 15 s, idle 60 s | `services/gateway/internal/httpx/httpx.go` |
| user-service | Postgres trong RPC | deadline gRPC | `services/user-service/internal/server/server.go` |
| user-service | chờ semaphore hash (JWT-9) | 200 ms | `services/user-service/internal/password/password.go` (`acquireWait`) |
| user-, video-service | relay outbox: produce | 10 s | `internal/outbox/relay.go` (`produceTimeout`) |
| user-, video-service | relay outbox: Postgres (khoá, đọc, đánh dấu, dọn) | không có hạn riêng | `internal/outbox/relay.go` (`sendBatch`, `cleanup`) |
| video-service | Postgres và S3 `HEAD` trong RPC | deadline gRPC; `PresignPost` ký cục bộ, không gọi mạng | `services/video-service/internal/server/server.go` |
| video-service | consumer `transcode.*`: Postgres | không có hạn riêng; commit offset 10 s | `internal/kafkax/consumer.go` (`commitTimeout`) |
| video-service | job dọn upload (mới): Postgres, S3 `Delete` | 30 s cho mỗi lô (cả transaction) | mục 5 |
| engagement-service | Postgres trong RPC | deadline gRPC (`GetStats`: 100 ms) | `services/engagement-service/internal/server/server.go` |
| engagement-service | `RecordView`: produce | 2 s, trong deadline gRPC 3 s | `server.go` (`produceTimeout`) |
| engagement-service | consumer lượt xem: Postgres, `ListOffsets` | gom lô 1 s; Postgres và `ListOffsets` không có hạn riêng; commit 10 s | `internal/kafkax/batch.go`, `services/engagement-service/internal/server/views.go` |
| feed-service | Postgres trong RPC | deadline gRPC | `services/feed-service/internal/server/server.go` |
| feed-service | projector: Postgres | không có hạn riêng; commit 10 s | `services/feed-service/internal/projector/projector.go` |
| feed-service | dọn timeline mỗi giờ | không có hạn riêng | `services/feed-service/cmd/feed-service/main.go` (`runPrune`) |
| feed-service | Redis (mới); Postgres của singleflight (mới) | 50 ms; 2 s | mục 3 |
| media-worker | một lần thử: tải S3, ffprobe, ffmpeg, upload S3 | 15 phút; ffprobe 30 s, ffmpeg 10 phút | `services/media-worker/internal/worker/worker.go` (`tryTimeout`), `services/media-worker/internal/transcode/transcode.go` (`defaultLimits`) |
| media-worker | produce kết quả | 30 s | `worker.go` (`produceTimeout`) |
| gateway | lệnh con `healthcheck` (`/healthz` qua loopback); HTTP `Shutdown` | 3 s; 10 s | `services/gateway/cmd/gateway/main.go` (`healthcheckTimeout`, `shutdownTimeout`) |
| user-, video-, engagement-, feed-service | lệnh con `healthcheck` (gRPC `Health/Check`); `GracefulStop` | 3 s; 10 s | `services/*-service/cmd/*/main.go` (`healthcheckTimeout`), `internal/grpcserver/grpcserver.go` (`shutdownTimeout`) |

- **Mọi lời gọi gRPC đều có deadline.** Chỉ gateway gọi gRPC; không có lời gọi gRPC service → service nào.
- **Khoảng trống ngoài gRPC (việc sau):** Postgres trong các vòng nền đang có (relay, consumer, projector, dọn timeline)
  không có hạn riêng; `DATABASE_URL` không đặt `connect_timeout` hay `statement_timeout`; client Kafka và S3
  dùng timeout mặc định của thư viện. Một câu treo (ví dụ chờ khoá) làm vòng đó đứng nhưng không chặn request của người
  dùng. Xử lý cùng metric lag và cảnh báo ở giai đoạn 3, khi thấy được vòng nào đứng.
- Job dọn upload mới thì có hạn ngay từ đầu (30 s mỗi lô, mục 5): khác các vòng trên, nó giữ khoá dòng của video người
  dùng trong lúc gọi S3, nên một lời gọi treo chặn `CompleteUpload` của các video đó.

### Các lựa chọn về timeout

#### A. Giữ một hạn chung 3 s cho gRPC ở gateway, riêng `GetStats` 100 ms

- Được: 3 s lớn hơn hạn produce 2 s của `RecordView` và thời gian hash argon2id + chờ semaphore của login; deadline
  truyền xuống nên service tự dừng việc khi gateway đã bỏ.
- Mất: service chết thì request chờ đủ 3 s (cần breaker bên dưới để fail nhanh).

#### B. Hạn riêng theo từng method

- Mất: thêm một bảng phải giữ khớp mà chưa có số đo p99 từng method (k6 ở giai đoạn 6) để đặt.

### Các lựa chọn về retry

#### A. `retryPolicy` có sẵn của grpc-go qua service config

- Được: không thêm thư viện; mọi lần thử nằm trong cùng deadline; có `retryThrottling` chống bão retry.
- Mất: cấu hình bằng JSON, sai tên method thì im lặng không retry (test phải bắt).

#### B. Interceptor retry tự viết hoặc `go-grpc-middleware/retry`

- Mất: thêm code hoặc dependency cho việc grpc-go đã làm sẵn.

#### C. Không retry

- Mất: một lần service khởi động lại (kết nối gãy, `UNAVAILABLE`) là lỗi thẳng tới người dùng ở cả route đọc.

### Các lựa chọn về circuit breaker

#### A. `github.com/sony/gobreaker/v2`

- Được: không dependency lúc chạy; half-open và đếm theo thế hệ đã đúng (kết quả của lời gọi bắt đầu ở thế hệ cũ không
  đổi trạng thái mới); có cửa sổ trượt và `IsExcluded`.
- Mất: một dependency mới.

#### B. Tự viết (~100 dòng)

- Mất: phải tự gánh các ca đua của half-open (nhiều lời gọi thử cùng lúc, kết quả về muộn sau khi đổi trạng thái).

#### C. Để service mesh làm (outlier detection của Istio/Envoy)

- Mất: chưa có mesh (giai đoạn 6, tuỳ chọn); compose không có.

### Các lựa chọn về bulkhead

#### A. Không thêm ở phần C

- Được: không có giới hạn đoán mò; semaphore hash ở user-service (JWT-9) đã che chỗ tốn tài nguyên nhất; goroutine của
  gateway rẻ, timeout + breaker đã chặn việc dồn request chờ service chết.
- Mất: một service chậm (chưa chết) vẫn giữ goroutine của gateway tới 3 s.

#### B. Semaphore theo service đích ở gateway

- Mất: chưa có số đo để đặt kích thước; đặt sai là tự chặn tải thật.

### Quyết định về timeout, retry, circuit breaker, bulkhead

Timeout **A**, retry **A**, circuit breaker **A**, bulkhead **A**.

**Timeout:** giữ `callTimeout` **3 s** cho mọi lời gọi gRPC, `statsTimeout` **100 ms** (ADR-0009 mục 9), Redis **50
ms**.

**Retry:** service config lúc dial, chỉ cho method idempotent, chỉ mã `UNAVAILABLE`, mọi lần thử trong cùng deadline 3
s:

```json
{
  "methodConfig": [{
    "name": [
      {"service": "svp.user.v1.UserService", "method": "Follow"},
      {"service": "svp.user.v1.UserService", "method": "Unfollow"},
      {"service": "svp.video.v1.VideoService", "method": "GetVideo"},
      {"service": "svp.video.v1.VideoService", "method": "CompleteUpload"},
      {"service": "svp.feed.v1.FeedService", "method": "GetFollowingFeed"},
      {"service": "svp.feed.v1.FeedService", "method": "GetExploreFeed"},
      {"service": "svp.engagement.v1.EngagementService", "method": "Like"},
      {"service": "svp.engagement.v1.EngagementService", "method": "Unlike"}
    ],
    "retryPolicy": {
      "maxAttempts": 3,
      "initialBackoff": "0.05s",
      "maxBackoff": "0.2s",
      "backoffMultiplier": 2,
      "retryableStatusCodes": ["UNAVAILABLE"]
    }
  }],
  "retryThrottling": {"maxTokens": 10, "tokenRatio": 0.1}
}
```

- Mỗi `ClientConn` chỉ mang phần của service đó. grpc-go v1.84.0 chờ backoff nhân hệ số ngẫu nhiên 0,8–1,2 giữa các lần
  thử: ~50 ms trước lần 2, ~100 ms trước lần 3.
- `retryThrottling`, đếm riêng cho mỗi `ClientConn`: mỗi **lần thử** lỗi với mã retry được (`UNAVAILABLE` ở method có
  `retryPolicy`, kể cả lần cuối) trừ 1 token; mỗi lời gọi thành công trên `ClientConn` đó (mọi method) cộng 0,1; còn ≤ 5
  token thì ngừng retry tới khi hồi lại (`stream.go`, `shouldRetry`). Service chết hẳn thì retry tự tắt sau vài lời gọi
  thay vì nhân ba tải.
- **Không retry:** `Register`, `Login` (tốn hash, dính rate limit), `InitUpload` (mỗi lần tạo một video mới),
  `RecordView` (đếm thêm một lượt), `GetStats` (ngân sách 100 ms không chứa nổi lần thử lại, ADR-0009).
  `DEADLINE_EXCEEDED` không retry: service có thể đã làm xong và hạn chung đã hết.
- grpc-go vẫn tự thử lại trong suốt (transparent retry) với request chưa tới được server, ở mọi method; không đổi được
  và không làm service xử lý hai lần.

**Circuit breaker:** `github.com/sony/gobreaker/v2` **v2.4.0**, **một breaker cho mỗi service đích** ở gateway (user,
video, feed, engagement), gắn bằng unary client interceptor trên `ClientConn`. Retry của grpc-go chạy bên dưới
interceptor, nên breaker thấy kết quả cuối của một lời gọi, sau mọi lần thử.

- **Tính là lỗi:** `UNAVAILABLE` **không kèm `ErrorInfo`** (lỗi mức kết nối/transport: service chết, không tới được),
  `DEADLINE_EXCEEDED`. Riêng `GetStats` (ngân sách 100 ms, best-effort) chỉ tính `UNAVAILABLE` đó; `DEADLINE_EXCEEDED`
  của nó không tính vào đâu cả, để engagement-service chậm mà còn sống không làm like/view trả 503 theo chu kỳ.
- **Không tính là lỗi:** mã nghiệp vụ (`NOT_FOUND`, `INVALID_ARGUMENT`, `FAILED_PRECONDITION`, `RESOURCE_EXHAUSTED`...)
  tính như lời gọi thành công, vì service đã trả lời (`IsSuccessful`); `CANCELLED` (client đóng kết nối) không tính vào
  đâu cả (`IsExcluded`).
- **Lỗi phụ thuộc của service không tính vào đâu cả** (`IsExcluded`): service còn sống nhưng một phụ thuộc của nó chết
  thì trả `UNAVAILABLE` **kèm `ErrorInfo`** domain `svp`, reason `DEPENDENCY_UNAVAILABLE` (qua `internal/grpcerr`):
  engagement-service `RecordView` khi Redpanda chết, video-service `CompleteUpload` khi MinIO chết. Nếu tính, vài lượt
  xem lúc Redpanda chết sẽ mở breaker của cả engagement-service, và `Like`/`Unlike` (chỉ cần Postgres) cũng 503; tương
  tự MinIO chết làm `GetVideo` 503. Breaker chỉ trả lời câu hỏi "service có tới được không"; phụ thuộc của từng method
  là việc của service. Gateway vẫn trả 503 cho client, không lộ reason (5xx theo §8.4). Mã `UNAVAILABLE` vẫn được
  retry như mọi `UNAVAILABLE` của method có `retryPolicy`.
- **Mở** khi 5 lỗi liên tiếp, hoặc ≥ 20 lời gọi với tỉ lệ lỗi ≥ 50% trong cửa sổ trượt 10 s (`Interval` 10 s,
  `BucketPeriod` 1 s). **Mở 5 s** rồi half-open cho **1** lời gọi thử (`MaxRequests` 1); thử thành công thì đóng, lỗi
  thì mở lại 5 s.
- Breaker mở (hoặc half-open đã có lời gọi thử): trả ngay `status.Error(codes.Unavailable, ...)`, không gọi mạng → 503
  theo §8.4. Feed vẫn trả trang không `stats` mà không chờ 100 ms.
- Đổi trạng thái log WARN `circuit breaker state changed` kèm `target` (service đích), `from`, `to`. Không dùng khoá
  `service`: `logx` đã đặt `service=gateway` trên mọi dòng, hai khoá trùng tên trên một dòng JSON thì pipeline log chỉ
  giữ một.
- `grpc.health.v1.Health/Check` của `/readyz` đi qua cùng `ClientConn` nhưng **bỏ qua breaker** (lọc theo tên method):
  readiness phải thấy trạng thái thật của service.
- Service → service: không có lời gọi đồng bộ nào, nên không có breaker.

**Bulkhead:** không thêm; xem lại bằng k6 ở giai đoạn 6.

**Tiêu chí đo:** tắt engagement-service; sau khi breaker mở thì `PUT /videos/{id}/like` trả 503 trong **< 100 ms**; bật
lại thì breaker tự đóng và like trả 204.

## 5. Job dọn upload bỏ dở và UP-7

[ADR-0004](0004-direct-upload-and-hls.md) luật 4: bản ghi `UPLOADING` quá 1 giờ chuyển `FAILED` và xoá object nếu có;
job chỉ chạy ở một instance tại một thời điểm. Threat model UP-7: mỗi user tối đa vài video `UPLOADING` cùng lúc.

### Các lựa chọn về cách chạy job một instance

#### A. Goroutine trong video-service, khoá bằng `pg_try_advisory_xact_lock`

- Được: cùng cách relay outbox đang chạy (ADR-0008 mục 7); không thêm hệ thống khoá nào; khoá tự nhả khi transaction kết
  thúc, kể cả khi instance chết; instance không giữ được khoá thì bỏ lượt.
- Mất: transaction giữ khoá dòng trong lúc gọi S3.

#### B. Khoá phân tán trong Redis (`SET NX PX`, lab `distributed-cron-lock`)

- Mất: video-service phải thêm Redis chỉ cho việc này; khoá hết hạn giữa chừng thì hai instance cùng chạy, phải thêm
  fencing token, trong khi dữ liệu cần bảo vệ nằm ở Postgres vốn đã có khoá.

#### C. CronJob của k8s

- Mất: chưa có k8s tới giai đoạn 4, compose không có; `concurrencyPolicy: Forbid` không chặn được lần chạy tay chồng
  lên.

#### D. Lifecycle rule của bucket `uploads`

- Mất: chỉ xoá object, không đổi trạng thái `UPLOADING` trong database; không phân biệt video còn đang chờ
  `CompleteUpload` với video đã bỏ. Có thể thêm như lớp phụ ở giai đoạn 7.

### Các lựa chọn về giới hạn video đang upload (UP-7)

#### A. Đếm mọi video `UPLOADING` của user

- Mất: người bỏ dở 3 upload bị khoá tới 1 giờ, tới khi job dọn chạy.

#### B. Đếm video `UPLOADING` có form còn hạn (tạo trong 15 phút gần nhất)

- Được: đúng thứ cần giới hạn: số form còn dùng được để ghi vào storage; form hết hạn thì tự giải phóng chỗ.
- Mất: một truy vấn đếm và một khoá advisory mỗi `InitUpload`.

#### C. Bộ đếm trong Redis ở gateway

- Mất: lệch với database (video chuyển `PROCESSING` hay `FAILED` thì bộ đếm không biết); Redis lỗi là mất giới hạn.

### Quyết định về job dọn upload và UP-7

Job **A**, UP-7 **B**. Lab `distributed-cron-lock` không cần: advisory lock của Postgres đã có sẵn và đã dùng ở relay.
Job vẫn giữ đúng luật 4 của ADR-0004 (một instance một lúc), nên **ADR-0004 không bị chỉnh**: lab nêu trong luật đó là
cách làm gợi ý, không phải phần của quyết định.

**Job dọn:**

- Chạy trong **video-service** (goroutine như relay outbox), chu kỳ **5 phút**, hạn `UPLOADING` **1 giờ**, lô **100**
  video mỗi transaction.
- Mỗi lô là một transaction: `pg_try_advisory_xact_lock(<hằng số int64 riêng của job>)`, khác `lockID` của
  `internal/outbox` (ADR-0008 mục 7); không được khoá thì bỏ lượt. Trong transaction đó:
  1. `SELECT ... FOR UPDATE` tối đa 100 video `UPLOADING` có `created_at` quá hạn, `ORDER BY created_at` (cũ nhất
     trước);
  2. xoá object `uploads/<video_id>` từng cái (object không có thì không lỗi);
  3. chuyển `FAILED` **chỉ** các video đã xoá được, `WHERE status = 'UPLOADING'`. Xoá lỗi thì video đó giữ `UPLOADING`,
     lượt sau thử lại.
- **Hạn mỗi lô 30 s**, một context cho cả transaction (Postgres và mọi lời gọi S3 `Delete`). Hết hạn thì transaction
  rollback: mọi video của lô giữ `UPLOADING` (object đã xoá thì lượt sau xoá lại không lỗi), khoá nhả, lượt kết thúc.
  100 lần `Delete` tuần tự cỡ vài giây trên S3, nên 30 s là dư nhiều lần; hạn chỉ để một lời gọi treo không giữ khoá
  dòng mãi.
- **Chạy lô tiếp ngay chỉ khi lô vừa rồi đủ 100 video và cả 100 đã chuyển `FAILED`.** Lô ít hơn 100, có video xoá lỗi,
  hay hết hạn thì kết thúc lượt, chờ chu kỳ sau; video xoá lỗi không được thử lại trong cùng lượt. Không có luật này thì
  S3 lỗi với ≥ 100 video quá hạn thành vòng lặp không nghỉ: lô nào cũng chọn lại đúng 100 video đó, không chuyển được
  video nào, và vẫn "đủ 100". Lỗi xoá S3 thường là lỗi của cả bucket (MinIO chết, sai quyền), không phải của riêng một
  object (`Delete` object không có vẫn thành công), nên dừng lượt không bỏ sót gì; lỗi lẻ vài video thì mỗi lượt vẫn
  chuyển được phần còn lại của lô và lượt sau chọn tới các video xếp sau.
- **Đua với `CompleteUpload`** an toàn nhờ khoá dòng: `CompleteUpload` thắng thì dòng đã `PROCESSING`, `FOR UPDATE` đánh
  giá lại điều kiện và bỏ qua dòng đó; job thắng thì `CompleteUpload` thấy `FAILED` và trả `FAILED_PRECONDITION`
  `VIDEO_FAILED` (code hiện có).
- Biến `UPLOAD_ABANDON_AFTER` (mặc định `1h`) và `UPLOAD_SWEEP_INTERVAL` (mặc định `5m`), chỉ để diễn tập đặt ngắn trên
  stack. Giá trị dưới 15 phút (hạn form) chỉ dùng cho diễn tập: form còn hạn có thể ghi lại object sau khi đã dọn.

**UP-7:**

- Mỗi user tối đa **3** video `UPLOADING` có form còn hạn (`created_at` trong 15 phút gần nhất, bằng hạn form của
  ADR-0004). 3 × 500 MB = tối đa 1,5 GB form đang mở mỗi tài khoản.
- Đếm và `INSERT` trong một transaction dưới
  `pg_advisory_xact_lock(hashtextextended('video-upload-author:' || author_id, 0))`, để hai `InitUpload` đồng thời của
  cùng user không cùng lọt. Khoá theo user nên user khác không chờ nhau.
- Vượt thì `RESOURCE_EXHAUSTED`, reason **`TOO_MANY_UPLOADS`** (→ 429 theo §8.4). Comment của `InitUpload` trong
  `proto/svp/video/v1/video_service.proto` thêm lỗi này (chỉ comment, tương thích).
- Migration `00003` của video-service: hai index một phần `WHERE status = 'UPLOADING'`: `(author_id, created_at)` cho
  UP-7 và `(created_at)` cho job. Index một phần chỉ chứa video đang upload, nên nhỏ và không tốn gì cho video đã
  `READY`.

## 6. Việc treo của phần B: `title` đã trim ở feed-service

feed-service kiểm `title` của `video.ready` sau khi trim nhưng lưu bản nguyên văn. video-service đã trim trước khi lưu
nên hiện không lệch, nhưng kiểm một giá trị và lưu giá trị khác là lỗi chờ xảy ra. feed-service lưu **bản đã trim**:
kiểm và lưu cùng một giá trị.

## 7. Diễn tập và số đo

Diễn tập mới chạy qua `Makefile` trên stack compose, script ở `deploy/compose/drills/`:

| Target | Kiểm gì |
| --- | --- |
| `drill-rate-limit` | Vượt ngưỡng → 429 `RATE_LIMITED` có `Retry-After`; Redis không tới được → login vẫn bị giới hạn bằng bộ đếm dự phòng, feed và like vẫn chạy; UP-7 → 429 `TOO_MANY_UPLOADS` |
| `drill-engagement-down` (sửa) | Sau khi breaker mở: like trả 503 < 100 ms; feed vẫn 200 không `stats`; bật lại engagement-service thì breaker tự đóng |
| `measure-explore-cache` | N request đồng thời lúc cache trống → đúng 1 dòng `explore page loaded from database` |
| `drill-upload-cleanup` | Video bỏ dở quá hạn → `FAILED`, object `uploads/<id>` bị xoá (đặt `UPLOAD_ABANDON_AFTER`, `UPLOAD_SWEEP_INTERVAL` ngắn) |

- **Giả Redis lỗi** bằng cách dựng lại container gateway với `REDIS_URL` trỏ tới tên miền `.invalid` (RFC 2606, không
  phân giải được), **không** tắt Redis native: nó dùng chung với dự án khác.
- **Ngưỡng `register` khi diễn tập:** mọi request diễn tập đi ra từ một IP bridge của Docker, nên chạy lại nhiều lần
  trong một giờ sẽ cạn burst 20. Script diễn tập và smoke xoá khoá `svp:gw:rl:register:*` trong Redis db 10 trước khi
  chạy (`SCAN` + `DEL`, không `FLUSHDB`). Đây là việc **chỉ ở lab local**, ghi rõ trong đầu script; không nâng ngưỡng
  đăng ký theo IP cho vừa diễn tập.
- `make smoke` đổi bước lượt xem theo RL-3: lượt xem thứ hai trong 60 s vẫn nhận 202 nhưng không được đếm.

## Hệ quả

- Được:
  - Route đăng nhập và đăng ký luôn có giới hạn, kể cả khi Redis lỗi (JWT-4, JWT-6, JWT-9); dò mật khẩu một tài khoản
    còn 10 lần mỗi giờ mỗi IP mà không khoá được chủ thật.
  - Spam lượt xem bị chặn ở gateway (RL-3) mà client không biết; ghi rác theo `video_id` ngẫu nhiên bị giữ ở 2 lần/s mỗi
    tài khoản (RL-6); mở form upload hàng loạt bị chặn ở cả gateway và video-service (UP-7).
  - Redis lỗi không làm sập feed: rate limit route đọc mở, cache khám phá lui về Postgres, service vẫn khởi động và vẫn
    ready.
  - Trang đầu feed khám phá: N request đồng thời → 1 truy vấn Postgres mỗi instance mỗi 5 s.
  - Service chết thì gateway fail nhanh (503 < 100 ms) sau khi breaker mở, thay vì giữ mỗi request 3 s; một lần service
    khởi động lại không thành lỗi ở route idempotent nhờ retry.
  - Upload bỏ dở không nằm mãi ở `UPLOADING`, object rác bị xoá.
- Phải trả:
  - Thêm hai dependency trực tiếp (`go-redis`, `gobreaker`) cùng vài module phụ của `go-redis` trong `go.sum`;
    `golang.org/x/sync` thành direct.
  - Route có rate limit thêm 1–3 lần gọi Redis: login 2 (`login-ip`, `login-email`); lượt xem 2 (`write`,
    `view-once`), 3 khi chuyển tiếp lỗi (`DEL`); trang đầu feed khám phá 1 ở gateway (`read`) cộng đọc rồi, khi trống,
    ghi cache ở feed-service. Mỗi lần dưới 1 ms khi Redis khoẻ, tối đa 50 ms khi Redis treo, nên Redis treo cộng tới
    100–150 ms vào các route đó, ngang cả ngân sách p99 150 ms của feed.
  - Bộ đếm dự phòng trong bộ nhớ lỏng đi N lần với N instance gateway, và về 0 mỗi lần deploy.
  - IP client lấy từ `RemoteAddr` **chỉ đúng ở compose**. Sau Envoy Gateway mọi client chung một bucket `login-ip` và
    `register`. Đọc `X-Forwarded-For` với số hop proxy tin cậy (RL-1) là **điều kiện tiên quyết của giai đoạn 4**: không
    đưa gateway ra sau Envoy Gateway trước khi có nó.
  - Khoá `login-email` là SHA-256 không muối: ai đọc được Redis thử được email đoán sẵn, trong tối đa 30 phút khoá còn
    sống.
  - RL-3 chỉ chặn trong 60 s; nhiều tài khoản giả cùng đẩy lượt xem vẫn được (rủi ro đã chấp nhận ở threat model §6).
    Lần thử lại sau lỗi chuyển tiếp chỉ được đếm nếu lệnh `DEL` khoá view-once thành công.
  - Cache khám phá trễ tới 5 s; R replica feed-service là tối đa R truy vấn mỗi lần hết hạn.
  - Breaker chung cho mọi method của một service: một method hỏng (ví dụ chỉ `Like` lỗi vì bảng `likes` bị khoá) làm mọi
    method của engagement-service trả 503 trong lúc mở.
  - Lỗi phụ thuộc (`DEPENDENCY_UNAVAILABLE`) không mở breaker, nên không fail nhanh: Redpanda chết thì mỗi `RecordView`
    vẫn chờ hạn produce 2 s rồi mới 503; MinIO chết thì `CompleteUpload` chờ lời gọi S3 của nó. Service nào gắn nhầm
    `ErrorInfo` vào một `UNAVAILABLE` không phải lỗi phụ thuộc thì breaker không thấy lỗi đó.
  - Retry chỉ cho `UNAVAILABLE`: lời gọi quá hạn hay lỗi tạm khác không được thử lại.
  - `GetStats` không tính `DEADLINE_EXCEEDED`: engagement-service treo (không từ chối kết nối) mà chỉ có lưu lượng đọc
    feed thì breaker không mở, mỗi trang feed vẫn chờ 100 ms như phần B, cho tới khi like/view làm breaker mở.
  - Job dọn upload giữ khoá dòng trong lúc gọi S3, tối đa 30 s (hạn của lô); `CompleteUpload` của chính video đó chờ
    theo. Chỉ gặp khi client gọi `CompleteUpload` sau 1 giờ, lúc form đã hết hạn 45 phút.
  - Job dọn kết thúc lượt ở lô đầu tiên có video xoá lỗi. Nếu ≥ 100 video cũ nhất cùng xoá lỗi mãi vì lỗi riêng của
    từng object (chưa thấy ở S3), các video xếp sau không được dọn cho tới khi lỗi đó hết.
  - Script diễn tập xoá khoá `register` trong Redis db 10 trước khi chạy: chỉ đúng ở lab local.
  - Vòng nền đọc Postgres đang có (relay, consumer, projector, dọn timeline) chưa có hạn riêng (mục 4).
- Xem lại khi:
  - k6 ở giai đoạn 6 cho thấy người dùng giả hợp lệ nhận 429, hoặc vòng lặp lạm dụng lọt dưới ngưỡng: chỉnh bảng ở mục
    2.
  - Redis treo (không phải từ chối kết nối) làm request chịu thêm 50 ms mỗi lần gọi ở p99 (tới 150 ms ở login, lượt xem,
    trang đầu khám phá): bọc Redis bằng circuit breaker.
  - Metric của giai đoạn 3 cho thấy gateway chạy bộ đếm dự phòng quá 1% thời gian, hoặc chạy hơn 3 instance gateway: cân
    nhắc chia ngưỡng dự phòng theo số instance.
  - k6 thấy breaker engagement mở oan (mở trong lúc engagement-service vẫn trả lời p99 < 100 ms), hoặc một method hỏng
    kéo cả service: tách breaker theo method.
  - Trang đầu khám phá vẫn tốn quá 10% thời gian Postgres của feed-service ở 1.000 req/s, hoặc chạy hơn 10 replica
    feed-service: khoá phân tán hoặc làm mới sớm.
  - Có NFR độ tươi cho feed khám phá dưới 5 s: giảm TTL hoặc xoá chủ động có version.
  - Lô của job dọn upload chạm hạn 30 s, hoặc `CompleteUpload` p99 tăng khi job chạy: tách bước gọi S3 ra khỏi
    transaction giữ khoá dòng.
  - Còn video `UPLOADING` tạo hơn 2 giờ trước (quá hạn 1 giờ, tức 12 chu kỳ mà chưa dọn được; metric ở giai đoạn 3): xem
    lỗi xoá S3, và nếu là lỗi riêng từng object thì bỏ qua video lỗi trong lượt thay vì kết thúc lượt.
  - Lượt xem dùng để xếp hạng (feed gợi ý, xu hướng): RL-3 dài hơn 60 s và chống tài khoản giả (threat model §6).
