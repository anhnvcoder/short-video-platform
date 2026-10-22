# 0009. Giai đoạn 2 phần B: event follow, engagement-service đếm theo lô, feed-service fan-out on write

- Trạng thái: Chấp nhận; §9 (ghép thêm tác giả song song với số đếm) chỉnh bởi [0018](0018-web-profiles-public-video-upload.md)
- Ngày: 2026-10-11

## Bối cảnh

- Giai đoạn 2 phần B làm thật F2 (phần event), F5, F6, F7 của [architecture §1](../architecture.md#1-phạm-vi):
  user-service phát `user.followed` / `user.unfollowed`; engagement-service giữ like, nhận lượt xem và giữ bộ đếm;
  feed-service dựng read model từ event và trả feed; gateway thêm route feed, like, lượt xem. Redis, cache, rate limit,
  timeout/retry/circuit breaker thuộc phần C (mục 14).
- NFR liên quan ([architecture §2](../architecture.md#2-yêu-cầu-phi-chức-năng)):
  - **Độ tươi:** video `READY` vào feed follower p95 < 10 s.
  - **Đúng đắn:** event gửi trùng không làm sai bộ đếm.
  - **Nhất quán:** số lượt xem trễ tối đa ~1 phút; like của chính mình thấy ngay.
  - **Độ trễ:** feed p99 < 150 ms tại 1.000 req/s tính cả phần ghép số đếm (đo bằng k6 ở giai đoạn 3, 6).
- Số liệu ([architecture §3](../architecture.md#3-ước-lượng-quy-mô)): ở mục tiêu tải có ~10.000 event lượt xem/giây,
  like ~10/s cao điểm; timeline ~2 triệu dòng/ngày, giữ 30 ngày là ~60 triệu dòng (~7 GB); bản sao follow ~50 triệu
  cạnh; một video fan-out trung bình tới 2.000 follower, tài khoản lớn nhất 200k (A7). §3.3 điểm 3: đọc metadata nhỏ,
  Postgres có index đúng chịu được 1.000 req/s; điểm 4: ghi nóng nằm ở lượt xem, cập nhật từng dòng sẽ tranh khoá dòng
  của video viral.
- Các ADR trước đã chốt hướng: outbox, at-least-once, `processed_events` cho consumer không tự idempotent (luật 1),
  produce thẳng khi không ghi database (luật 4) ([ADR-0003](0003-async-events-outbox.md)); fan-out on write, timeline
  30 ngày, follow mới thì đưa video gần đây vào timeline, keyset (`published_at`, `video_id`)
  ([ADR-0005](0005-feed-fan-out-on-write.md)); topic theo luồng thực thể, envelope, danh tính qua `x-user-id`
  ([ADR-0006](0006-contract-ids-and-event-envelope.md)); relay outbox một luồng nhờ advisory lock, consumer commit tay +
  DLQ trong `internal/kafkax`, topic tạo bằng `rpk` ([ADR-0008](0008-async-upload-pipeline-stage2a.md) mục 5, 7, 8). ADR
  này không sửa ADR nào; chỗ chỉnh chi tiết so với ADR-0005 ghi rõ ở mục 6 và 7.
- Threat model: IN-4 (ai vào được Redpanda là phát được event giả, giai đoạn 4), IN-5 (event hỏng không chặn partition),
  PG-1, PG-2 (page token) ([threat model §4.5, §4.6](../threat-model.md#45-mức-tin-cậy-giữa-các-service)); RL-3, RL-6 để
  phần C.
- Ràng buộc máy như ADR-0008: Docker VM 7,65 GiB, 8 CPU; compose profile `core`; Postgres native `127.0.0.1:5432`.

## Kiểm chứng (đã kiểm ngày 2026-10-11)

| Kiểm gì | Lệnh | Kết quả |
| --- | --- | --- |
| Cổng | `lsof -nP -iTCP -sTCP:LISTEN` | Không tiến trình nào nghe ở 9103, 9104 |
| Dependency | `go.mod` | Đã có `franz-go` v1.22.1, `pgx/v5` v5.11.0, `grpc` v1.84.0, `protobuf` v1.36.12 (có gói `encoding/protowire`); không thêm module nào |
| End offset hiện tại | Đọc `pkg/kgo/client.go`, `pkg/kgo/config.go` của `franz-go` v1.22.1 và `generated.go` của `kmsg` v1.14.0 trong module cache | `(*kgo.Client).Request` chia `ListOffsets` tới leader của từng partition; `ListOffsetsRequestTopicPartition.Timestamp = -1` trả offset mới nhất; `kmsg` v1.14.0 có trong `go.mod` (`// indirect`), `kadm` chỉ có trong `go.sum`; `kgo.BlockRebalanceOnPoll` có |
| Offset khởi đầu của group mới | Đọc `pkg/kgo/config.go` cùng version | Mặc định `ConsumeStartOffset` = `NewOffset().AtStart()`: group chưa có offset (ví dụ sau `make clean-data`) đọc từ đầu topic |
| `hashtextextended` | `grep hashtextextended` trong `postgres.bki` của `postgresql@15` (Homebrew) | Có, `(text, bigint) → bigint`; hàm nội bộ của Postgres (từ bản 11), không nằm trong danh mục hàm có tài liệu |
| Code hiện có | Đọc `internal/kafkax/consumer.go`, `internal/outbox/`, `services/user-service/queries/follows.sql` | Consumer từng record (`MaxAttempts` mặc định 5 rồi DLQ); `outbox.Write(ctx, tx, topic, key, ev)`; `Follow`/`Unfollow` chỉ ghi `follows`, chưa phát event |

## 1. Event follow ở user-service

### Các lựa chọn về cách phát event follow

#### A. Outbox trong `svp_user`, relay `internal/outbox` như video-service

- Được: ghi cạnh và event nguyên tử (ADR-0003 phương án B); dùng lại relay đã chạy ở phần A; thứ tự event của một cạnh
  giữ được nhờ bất biến "khoá dòng thực thể trước" của ADR-0008 mục 7.
- Mất: user-service thêm phụ thuộc Kafka và một relay; mỗi event trễ thêm tối đa một chu kỳ poll (200 ms), nhỏ so
  với ngân sách 10 s.

#### B. Commit database rồi produce thẳng (dual write)

- Mất: crash giữa hai bước là mất `user.followed`; bản sao follow ở feed-service thiếu cạnh vĩnh viễn và không gì tự sửa
  (ADR-0003 phương án A).

#### C. feed-service gọi user-service để lấy danh sách follower

- Mất: ngược ADR-0005 và comment của `FeedService` ("never calls other services"); fan-out 200k follower phải phân trang
  qua gRPC trong lúc fan-out; feed-service lỗi theo user-service.

### Quyết định về event follow

Chọn **A**.

- Migration `services/user-service/migrations/00003_create_outbox.sql` (sẽ tạo), schema giống hệt
  `services/video-service/migrations/00002_create_outbox.sql`.
- `Follow`: một transaction, `INSERT INTO follows ... ON CONFLICT DO NOTHING`; **chỉ khi số dòng bị ảnh hưởng là 1** thì
  `outbox.Write(ctx, tx, "user.follows.v1", follower_id, ev)` với `ev` là `svp.user.v1.FollowEvent` nhánh
  `user_followed` (`follower_id`, `followee_id`). Follow lại cạnh đã có: 0 dòng, không ghi outbox (đúng comment của
  `user_service.proto`).
- `Unfollow`: một transaction, `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`; 1 dòng thì ghi nhánh
  `user_unfollowed`; 0 dòng thì không phát gì.
- Thứ tự: `INSERT` hay `DELETE` trên dòng `follows` là bước khoá thực thể, chạy **trước** `outbox.Write`, nên hai
  transaction trên cùng một cạnh nối đuôi nhau và `id` outbox tăng theo thứ tự commit (ADR-0008 mục 7). Hai follow đồng
  thời cùng cạnh: transaction sau chờ khoá khoá chính, thấy dòng đã có, 0 dòng, không phát. Unfollow chạy cùng lúc với
  follow chưa commit: `DELETE` không thấy dòng chưa commit, 0 dòng, không phát; trạng thái cuối là có cạnh và có đúng
  một `user.followed`. Chỉ cần giữ thứ tự trong một cạnh (`follower_id`, `followee_id`): hai cạnh khác nhau của cùng
  follower lệch thứ tự cũng không đổi kết quả ở feed-service.
- Relay: `outbox.NewRelay(pool, kafkaClient, logger)` chạy cạnh gRPC server, như video-service.
- Biến mới `KAFKA_BROKERS` (bắt buộc với `serve`) cho user-service; compose `redpanda:9092`.

## 2. Like

### Các lựa chọn về bộ đếm like

#### A. Bảng `likes` và bộ đếm riêng `like_counts`, đổi trong cùng transaction

- Được: `GetStats` đọc một dòng theo khoá chính cho mỗi video; đếm đúng tuyệt đối vì bộ đếm chỉ đổi khi `likes` thật sự
  đổi, trong cùng transaction; like chỉ ~10/s cao điểm (§3.2) nên tranh khoá dòng bộ đếm của một video là không đáng kể.
- Mất: thêm một bảng và một câu ghi mỗi like.

#### B. Đếm `count(*)` từ `likes` lúc đọc

- Được: không có bộ đếm phải giữ khớp.
- Mất: một trang feed là `GetStats` 10 video; ở 1.000 req/s là 10.000 lần đếm mỗi giây, và video viral cả triệu like thì
  mỗi lần đếm quét cả triệu mục index; không giữ được p99 < 150 ms.

#### C. Gom like theo lô qua event, như lượt xem

- Mất: NFR "Nhất quán" đòi like của chính mình thấy ngay, nên `likes` vẫn phải ghi đồng bộ; gom chỉ đáng với ghi nóng,
  mà like ~10/s (§3.2) không đáng thêm topic và consumer.

### Quyết định về like

Chọn **A**. Bảng trong `svp_engagement`:

```sql
CREATE TABLE likes (
    video_id   uuid        NOT NULL,
    user_id    uuid        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, user_id)
);

CREATE TABLE like_counts (
    video_id   uuid   PRIMARY KEY,
    like_count bigint NOT NULL CHECK (like_count >= 0)
);
```

- `Like`: một transaction, `INSERT INTO likes (video_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`; chèn được
  1 dòng thì `INSERT INTO like_counts VALUES ($1, 1) ON CONFLICT (video_id) DO UPDATE SET like_count =
  like_counts.like_count + 1`.
- `Unlike`: một transaction, `DELETE FROM likes WHERE video_id = $1 AND user_id = $2`; xoá được 1 dòng thì `UPDATE
  like_counts SET like_count = like_count - 1 WHERE video_id = $1`. `CHECK (like_count >= 0)` bắt lỗi code, không bao
  giờ âm.
- Thứ tự khoá luôn là dòng `likes` trước, dòng `like_counts` sau, nên like và unlike của nhiều người trên cùng video
  không deadlock; like và unlike của cùng một người trên cùng video nối đuôi nhau nhờ khoá khoá chính của `likes`.
- `liked_by_me` đọc `likes` theo khoá chính (`video_id = ANY($ids) AND user_id = $caller`), đồng bộ, nên người gọi thấy
  like của mình ngay sau khi `Like` trả về.

## 3. Ghi lượt xem

### Các lựa chọn về đường ghi lượt xem

#### A. Produce thẳng `view.recorded` (`acks=all`), không outbox, không database

- Được: đường ghi nóng nhất (~10.000 event/s) không chạm Postgres; Redpanda là hàng đệm bền, consumer chết thì lượt xem
  vẫn nằm trên topic; client nhận phản hồi sau khi broker xác nhận.
- Mất: broker lỗi thì lượt xem lỗi (`UNAVAILABLE`), client tự gửi lại; gửi lại sau khi quá hạn có thể thành hai lượt
  (`RecordView` vốn không idempotent theo contract; chặn lạm dụng bằng RL-3 ở phần C).

#### B. `UPDATE view_counts` trực tiếp mỗi lượt xem

- Mất: 10.000 câu `UPDATE` mỗi giây dồn vào vài dòng của video viral, tranh khoá dòng (§3.3 điểm 4).

#### C. Qua outbox

- Mất: thêm một lần ghi Postgres cho mỗi lượt xem chỉ để phát event, đúng thứ cần tránh; ADR-0003 luật 4.

### Quyết định về ghi lượt xem

Chọn **A**.

- `RecordView` produce `svp.engagement.v1.ViewEvent` (envelope mới: `event_id` UUIDv7, `occurred_at` lúc nhận request;
  nhánh `view_recorded` với `video_id` và `viewer_id` = người gọi) vào `engagement.views.v1`, key `video_id`, qua
  `kafkax.Produce` (mang `traceparent`), trong giới hạn **2 s**. Producer của franz-go mặc định idempotent và
  `acks=all`.
- Lỗi produce hoặc quá 2 s: `UNAVAILABLE`, message không lộ chi tiết broker. Không chạm database.
- 2 s: broker một node trả lời trong vài mili giây khi khoẻ; 2 s đủ cho franz-go thử lại nội bộ qua một lần đổi leader
  hay kết nối lại, mà client không phải chờ lâu cho một thao tác phụ.

## 4. Gom ghi lượt xem và chống đếm trùng

Phần khó nhất của phần B. Giao event là at-least-once (ADR-0003): consumer chết sau khi ghi bộ đếm mà trước khi commit
offset lên Kafka, hay rebalance giữa chừng, thì lượt xem được giao lại. Phép cộng không tự idempotent, nên theo ADR-0003
luật 1 phải có cách nhận ra phần đã cộng; mà tải là ~10.000 event/s dồn vào vài video viral (§3.3 điểm 4).

### Các lựa chọn về chống đếm trùng

#### A. `processed_events` theo `event_id` (thiết kế chung của ADR-0003 luật 1)

- Được: đúng mẫu chung, không phụ thuộc offset.
- Mất: 10.000 dòng chèn mỗi giây (~864 triệu dòng/ngày ở mục tiêu tải) chỉ để chống trùng; index phình, phải dọn liên
  tục; mỗi lô 5.000 record phải kiểm và chèn 5.000 khoá, đắt hơn chính phép cộng.

#### B. Chỉ bỏ `event_id` trùng trong một lô

- Được: không thêm bảng.
- Mất: giao lại xảy ra ở lô sau (consumer chết sau khi commit database, trước khi commit Kafka), nên không chặn được
  trường hợp trùng thật.

#### C. `UPDATE` từng event, kèm `processed_events`

- Mất: 10.000 transaction mỗi giây, tranh khoá dòng của video viral (§3.3 điểm 4), cộng toàn bộ chi phí của A.

#### D. Kafka transaction (exactly-once)

- Mất: chỉ nguyên tử khi đích ghi là Kafka (đọc, xử lý, ghi topic khác); đích ở đây là Postgres, offset Kafka và bộ đếm
  vẫn nằm ở hai hệ thống.

#### E. Offset lưu trong Postgres, cùng transaction với bộ đếm

- Được: mỗi lô một transaction; trạng thái chống trùng chỉ là một dòng mỗi partition (3 dòng cho cả topic), không phình;
  cộng và đánh dấu đã cộng là nguyên tử; record giao lại bị lọc bằng một phép so offset; commit offset lên Kafka chỉ còn
  là tối ưu (đỡ đọc lại), không quyết định đúng sai.
- Mất: đúng đắn dựa vào offset Kafka ổn định; topic bị tạo lại thì offset cũ vô nghĩa (cách xử lý và giới hạn ở dưới);
  phải viết consumer theo lô trong `internal/kafkax`.

### Các lựa chọn về kích thước lô

| | Được | Mất |
| --- | --- | --- |
| 500 record / 100 ms | Trễ thêm thấp nhất | Gấp 10 lần số transaction, mỗi transaction lại khoá cùng các dòng video viral |
| **5.000 record / 1 s** | Ở 10.000 event/s, một instance giữ cả 3 partition đầy lô sau ~0,5 s, ~2 transaction/s; trễ thêm ≤ 1 s, xa dưới NFR ~1 phút | Transaction lớn hơn, thử lại một lô tốn hơn |
| 50.000 record / 10 s | Ít transaction nhất | Transaction dài giữ khoá lâu; thử lại một lô rất tốn; giữ nhiều record trong bộ nhớ |

### Quyết định về gom ghi lượt xem

Chọn **E** và lô **tối đa 5.000 record hoặc 1 s** kể từ record đầu tiên của lô, cái nào tới trước. Ba instance mỗi cái
một partition thì mỗi cái nhận ~3.333 event/s, lô đóng ở mốc 1 s, ~1 transaction/s mỗi instance. Bảng trong
`svp_engagement`:

```sql
CREATE TABLE view_counts (
    video_id   uuid        PRIMARY KEY,
    view_count bigint      NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE consumer_offsets (
    consumer_group text        NOT NULL,
    topic          text        NOT NULL,
    partition      int         NOT NULL,
    next_offset    bigint      NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer_group, topic, partition)
);
```

Xử lý một lô (group `engagement-service`, topic `engagement.views.v1`):

1. Giải mã từng record. Record hỏng (không parse được, thiếu nhánh `view_recorded`, `video_id` hay `viewer_id` không
   phải UUID) **luôn** bị trả về là "loại", kể cả khi offset của nó đã được áp dụng ở lần giao trước, để nó vào
   `engagement.views.v1.dlq` ít nhất một lần (`dlq-reason=permanent`); nó không chặn lô và offset của nó vẫn tiến.
2. Mở một transaction. Với mỗi partition có trong lô, theo thứ tự partition tăng dần: chèn dòng `consumer_offsets` với
   `next_offset = 0` nếu chưa có (`ON CONFLICT DO NOTHING`), rồi `SELECT next_offset ... FOR UPDATE`.
3. Topic bị tạo lại (`make clean-data` xoá volume Redpanda, Postgres native giữ nguyên `consumer_offsets`). Chỉ xét
   partition có `next_offset` lưu **lớn hơn** offset cuối của partition đó trong lô + 1, tức offset đã lưu vượt quá cả
   lô; partition khác không cần xét, vì record cuối của lô nằm trên log nên end offset luôn ≥ offset cuối + 1. Với
   partition cần xét, **sau khi** đã khoá dòng ở bước 2 và **ở mỗi lần thử**, hỏi broker end offset hiện tại (Kafka
   `ListOffsets`, timestamp −1); không dùng high watermark của lần fetch tạo nên lô.
   - `next_offset` lưu > end offset vừa hỏi: offset đã lưu là của topic cũ. Log WARN, đặt `next_offset` về offset của
     record đầu tiên của partition đó trong lô, đếm tiếp. Đây là chỗ duy nhất `next_offset` được hạ.
   - Ngược lại: lô này là lô giao lại mà phần đã cộng vượt quá nó (instance khác hay lần trước đã cộng xa hơn); giữ
     nguyên, bước 4 lọc hết.

   Vì sao phép so đúng: end offset của một partition chỉ tăng chừng nào topic còn đó (Redpanda một node, replication 1;
   retention chỉ xoá đầu log). `next_offset` lưu là offset của một record đã đọc cộng 1, do một transaction đã commit
   trước khi bước 2 lấy được khoá; record đó nằm trên log từ trước lúc ấy, nên end offset hỏi sau khi có khoá luôn ≥
   `next_offset` lưu, trừ khi topic bị tạo lại. Hai cách hỏi sai: hỏi trước khi có khoá (instance khác có thể commit
   offset xa hơn trong lúc ta chờ khoá), và dùng high watermark của fetch, vốn cũ đi khi lô được thử lại không giới hạn.
   Ví dụ với cách thứ hai: A fetch 3.000..7.999 với high watermark 8.000; Postgres lỗi lâu hơn `RebalanceTimeout`,
   partition sang B, B cộng tới `next_offset` 12.001; lần thử lại của A thấy 12.001 > 8.000, tưởng topic tạo lại, đặt
   về 3.000 và cộng lại 3.000..7.999.
4. Bỏ record có `offset < next_offset` (đã cộng rồi); cộng dồn record còn lại theo `video_id` trong bộ nhớ.
5. Một câu cho cả lô, hai mảng sắp theo `video_id` để mọi transaction khoá các dòng theo cùng thứ tự (không deadlock
   giữa hai instance):

   ```sql
   INSERT INTO view_counts (video_id, view_count)
   SELECT * FROM unnest($1::uuid[], $2::bigint[])
   ON CONFLICT (video_id) DO UPDATE
   SET view_count = view_counts.view_count + EXCLUDED.view_count, updated_at = now();
   ```

6. Đặt `next_offset = GREATEST(next_offset, offset cuối của partition trong lô + 1)` (tính cả record bị loại), với
   `next_offset` là giá trị sau bước 3; `updated_at = now()`; commit. Không đặt thẳng `offset cuối + 1`: lô giao lại có
   thể nhỏ hơn lô đã cộng (lô đóng ở mốc 1 s). Ví dụ: lô 0..4.999 đã commit `next_offset` 5.000, commit Kafka hỏng, lần
   giao lại thành lô 0..2.999; đặt thẳng thì `next_offset` lùi về 3.000 và lô sau cộng lại 3.000..4.999.
7. **Sau đó** kafkax đẩy record bị loại sang DLQ, rồi commit offset cao nhất của mỗi partition lên Kafka.

Vì sao đúng một lần dù giao nhiều lần:

- Consumer chết, commit Kafka hỏng, hay produce DLQ hỏng giữa bước 6 và 7: offset Kafka chưa tiến, record được giao lại;
  bước 4 lọc bỏ mọi record đã cộng, và bước 6 không để `next_offset` lùi dù lô giao lại nhỏ hơn lô trước; record hỏng
  bị loại lại và vào DLQ lần nữa (DLQ là ít nhất một lần).
- Hai instance cùng tưởng mình giữ một partition (lúc rebalance): `SELECT ... FOR UPDATE` ở bước 2 bắt transaction sau
  chờ transaction trước commit, rồi đọc `next_offset` mới nhất (ở `READ COMMITTED`, `FOR UPDATE` trả bản đã commit sau
  khi chờ), nên phần đã cộng bị lọc.
- Thứ tự khoá cố định (partition tăng dần, rồi `video_id` tăng dần) nên hai transaction không khoá chéo nhau.

Lỗi và rebalance:

- Lỗi tạm thời (Postgres, hay lời hỏi end offset ở bước 3): handler trả lỗi, kafkax thử lại **cả lô** với backoff
  0,5 s → trần 10 s có jitter, **không giới hạn số lần**, log WARN mỗi lần, tới khi được hoặc consumer dừng (dừng thì
  không commit). Không đẩy lô sang DLQ: làm vậy là mất lượt xem, trong khi Redpanda giữ 7 ngày nên chờ là đúng. Lag tăng
  là tín hiệu; cảnh báo theo lag ở giai đoạn 3.
- Consumer theo lô bật `BlockRebalanceOnPoll`: rebalance chờ lô đang xử lý settle. Đúng đắn vẫn dựa vào offset trong
  database, không dựa vào việc chặn rebalance: Postgres lỗi lâu hơn `RebalanceTimeout` thì group loại thành viên,
  partition sang instance khác và instance đó cộng tiếp, commit Kafka của thành viên cũ hỏng. Lần thử lại của thành viên
  cũ khoá dòng offset, thấy `next_offset` lưu vượt quá lô của mình, hỏi end offset mới (≥ `next_offset` lưu) nên không
  coi là topic tạo lại; bước 4 lọc hết, bước 6 giữ nguyên `next_offset`.

Hiện thực ở `internal/kafkax`, **chỉ thêm API**, không đổi API cũ (`NewClient`, `Produce`, `Consumer`, `ConsumerConfig`,
`Handler`, `Permanent`, hằng số header): một consumer theo lô mà handler nhận cả lô, trả về danh sách record bị loại
(kèm lỗi) và một `error`; kafkax đẩy record bị loại sang `<topic>.dlq` với các header DLQ hiện có, rồi commit offset cao
nhất mỗi partition. Thêm một hàm hỏi end offset hiện tại của các partition cho bước 3: `kmsg.ListOffsetsRequest` với
`Timestamp = -1`, gửi qua `(*kgo.Client).Request` (franz-go tự chia request tới leader của từng partition). Tên kiểu và
hàm chọn khi viết code.

Header DLQ mới **`dlq-group`** (consumer group ghi DLQ), cho cả consumer từng record lẫn theo lô: từ phần B,
`video.lifecycle.v1.dlq` có hai group cùng ghi (`media-worker`, `feed-service`), cần biết record hỏng ở consumer nào.

Lab `hot-counter` (plan) có thể đo lại cách này với các cách khác ở giai đoạn 6, bằng k6 ở mức 10.000 event/s.

## 5. Đọc số đếm (`GetStats`)

### Các lựa chọn về bảng bộ đếm

#### A. Ba bảng riêng (`view_counts`, `like_counts`, `likes`), đọc theo khoá chính

- Được: hai đường ghi khác nhịp không đụng nhau: lô lượt xem (mỗi giây, khoá dòng của video viral) không bao giờ làm
  `Like` của người dùng phải chờ.
- Mất: ba câu đọc (hoặc một câu `LEFT JOIN`) thay vì một.

#### B. Gộp `view_count` và `like_count` vào một bảng `video_stats`

- Được: một dòng, một câu đọc.
- Mất: lô lượt xem và `Like` cùng khoá một dòng; video viral là chỗ cả hai cùng nóng, nên like của người dùng chờ theo
  transaction của lô.

### Quyết định về `GetStats`

Chọn **A**.

- Tối đa **50** id; nhiều hơn, hoặc id không phải UUID, thì `INVALID_ARGUMENT`.
- Trả theo thứ tự request, mỗi id một phần tử (id lặp thì trả lặp); id lạ thì `view_count = 0`, `like_count = 0`,
  `liked_by_me = false`.
- `view_count` từ `view_counts`, `like_count` từ `like_counts`, `liked_by_me` từ `likes` (`user_id` = người gọi). Ba câu
  `WHERE video_id = ANY($ids)` theo khoá chính, hoặc một câu `unnest($ids) WITH ORDINALITY ... LEFT JOIN` ba bảng; không
  quét bảng.

## 6. Schema của feed-service

ADR-0005 chọn fan-out on write; mục này chốt bảng cụ thể trong `svp_feed`.

### Các lựa chọn về khoá của timeline

#### A. Khoá chính `(user_id, published_at, video_id)`

- Được: một index làm hai việc: chống trùng (vì `published_at` của một video cố định, lấy từ bảng `videos`, không lấy từ
  event) và phục vụ keyset `ORDER BY published_at DESC, video_id DESC` (quét ngược index); đợt fan-out 200k dòng chỉ cập
  nhật một index.
- Mất: chống trùng dựa vào việc `published_at` của một video không đổi trong feed-service (giữ bằng `ON CONFLICT DO
  NOTHING` ở `videos`); unfollow phải join `videos` để biết dòng nào của tác giả.

#### B. Khoá chính `(user_id, video_id)` + index đọc `(user_id, published_at DESC, video_id DESC)`

- Được: chống trùng không phụ thuộc `published_at`.
- Mất: hai index, gấp đôi chi phí cập nhật index lúc fan-out, đúng ở đợt ghi nặng nhất (A7: 200k dòng); thêm dung lượng
  index trên ~60 triệu dòng (~7 GB, §3.2).

#### C. Thêm `author_id` vào timeline

- Được: unfollow xoá không cần join.
- Mất: thêm 16 byte mỗi dòng trên ~60 triệu dòng (~1 GB) để phục vụ unfollow, thao tác hiếm hơn nhiều so với fan-out.

### Các lựa chọn về giữ timeline 30 ngày

#### A. Lọc khi đọc + job dọn theo lô mỗi giờ

- Được: đơn giản, idempotent, không cần khoá giữa các replica; dòng quá hạn không bao giờ lọt ra feed dù job chậm.
- Mất: không có index theo `published_at` riêng (cố ý, để fan-out chỉ ghi một index), nên mỗi lệnh xoá của job tìm dòng
  cũ bằng cách quét bảng.

#### B. Partition theo ngày, `DROP` partition cũ

- Được: dọn gần như miễn phí.
- Mất: khoá chính phải chứa cột partition; phải tạo partition trước; thêm vận hành, chưa đáng ở ~60 triệu dòng (lab
  `big-table-queries` ở giai đoạn 6).

#### C. Giữ N dòng mới nhất mỗi người

- Mất: phải đếm và xoá theo từng người mỗi lần fan-out; không khớp "30 ngày" của ADR-0005 luật 2.

### Quyết định về schema của feed-service

Chọn **A** cho khoá timeline và **A** cho giữ 30 ngày.

```sql
CREATE TABLE follows (
    followee_id uuid        NOT NULL,
    follower_id uuid        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (followee_id, follower_id)
);

CREATE TABLE videos (
    video_id      uuid        PRIMARY KEY,
    author_id     uuid        NOT NULL,
    title         text        NOT NULL,
    duration_ms   bigint      NOT NULL,
    playlist_key  text        NOT NULL,
    thumbnail_key text        NOT NULL,
    published_at  timestamptz NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX videos_author_published_idx ON videos (author_id, published_at DESC, video_id DESC);
CREATE INDEX videos_published_idx ON videos (published_at DESC, video_id DESC);

CREATE TABLE timeline (
    user_id      uuid        NOT NULL,
    published_at timestamptz NOT NULL,
    video_id     uuid        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_id, published_at, video_id)
);
```

- `follows`: khoá chính `(followee_id, follower_id)` phục vụ fan-out (tìm follower của tác giả) và xoá một cạnh; ngược
  chiều với bảng `follows` của user-service, vì feed-service hỏi theo tác giả. Không thêm index khác.
- `videos`: index `(author_id, published_at DESC, video_id DESC)` cho backfill khi follow; `(published_at DESC, video_id
  DESC)` cho feed khám phá. Ghi `ON CONFLICT (video_id) DO NOTHING`: bản đầu tiên thắng, `published_at` của một video
  không bao giờ đổi, nên khoá chính của timeline chống trùng được.
- `timeline`: không có `author_id`; unfollow xoá bằng join với `videos`. `created_at` dùng `clock_timestamp()` (giờ thật
  lúc chèn từng dòng, không phải giờ bắt đầu transaction như `now()`) để xem một đợt fan-out kéo dài bao lâu.
- Giữ **30 ngày** (ADR-0005 luật 2): mọi câu đọc timeline lọc `published_at > now() - interval '30 days'`; một goroutine
  mỗi giờ xoá theo lô dòng `timeline` có `published_at < now() - interval '30 days'`, mỗi lệnh vài nghìn dòng, lặp tới
  khi hết; idempotent, chạy cùng lúc ở nhiều replica không sai, nên không cần khoá. Không giới hạn số dòng mỗi người.
- Chỉnh chi tiết so với ADR-0005 luật 2 (giữ nguyên quyết định "chỉ giữ 30 ngày"): job dọn đi kèm lọc lúc đọc, để dòng
  quá hạn không hiện ra dù job chưa chạy tới.

## 7. Xử lý event ở feed-service

Một consumer group **`feed-service`** (consumer từng record của `internal/kafkax`) đọc `user.follows.v1` và
`video.lifecycle.v1`.

### Các lựa chọn về đồng bộ giữa follow và fan-out

Hai topic không có thứ tự chung (ADR-0003 luật 3 chỉ giữ thứ tự trong một partition), và về sau feed-service chạy nhiều
replica. Không khoá thì có hai lỗi, cả hai ở mức `READ COMMITTED` mặc định:

- **Video của người đã unfollow còn trong feed.** Transaction T1 fan-out video V của X: câu `INSERT ... SELECT` lấy
  snapshot của `follows`, thấy B. Trong lúc đó T2 xử lý B unfollow X: xoá cạnh, xoá các dòng timeline của B thuộc video
  của X (dòng của V chưa có vì T1 chưa commit), commit. T1 chèn (B, V), commit: V nằm trong feed của B dù B đã unfollow.
- **Follower mới thiếu video.** T1 fan-out V lấy snapshot `follows`, chưa có B. T2 xử lý B follow X: thêm cạnh, backfill
  từ `videos` của X, không thấy V vì T1 chưa commit, commit. T1 commit: mọi follower có V, trừ B.

#### A. `pg_advisory_xact_lock` theo tác giả

- Được: tuần tự hoá đúng những thao tác chạm cùng một tác giả, giữa hai consumer, hai topic và nhiều replica; tác giả
  khác nhau không chờ nhau; khoá tự nhả khi transaction kết thúc; không cần bảng.
- Mất: hash 64 bit có thể trùng giữa hai tác giả (chỉ làm chờ thêm, không sai); fan-out của tài khoản lớn giữ khoá suốt
  đợt ghi, follow và unfollow tác giả đó chờ theo.

#### B. Mức cô lập `SERIALIZABLE`

- Được: Postgres tự phát hiện xung đột.
- Mất: đợt fan-out 200k dòng bị huỷ và chạy lại khi đụng một follow; code phải thử lại; khó đoán thời gian ở đúng đợt
  ghi lớn nhất, nơi NFR 10 s chật nhất.

#### C. Khoá một dòng cho mỗi tác giả (`SELECT ... FOR UPDATE` trên bảng `authors`)

- Mất: thêm bảng chỉ để khoá; tác giả chưa có dòng thì phải chèn trước, bản thân việc chèn cũng phải xử lý đồng thời.
  Advisory lock làm đúng việc này mà không cần bảng.

### Quyết định về xử lý event

Chọn **A**. Mọi thao tác chạm cạnh follow hay fan-out của tác giả X chạy trong một transaction mà **câu đầu tiên** là
`SELECT pg_advisory_xact_lock(hashtextextended('feed-author:' || X, 0))`. Khoá phải đứng đầu: ở `READ COMMITTED` mỗi câu
lấy snapshot mới lúc bắt đầu, nên các câu sau khoá thấy mọi thứ transaction trước đã commit.

- **`user.followed`**: khoá theo `followee_id`; `INSERT INTO follows ... ON CONFLICT DO NOTHING`; backfill **luôn
  chạy**, kể cả khi cạnh đã có (idempotent):

  ```sql
  INSERT INTO timeline (user_id, published_at, video_id)
  SELECT $follower_id, published_at, video_id FROM videos
  WHERE author_id = $followee_id AND published_at > now() - interval '30 days'
  ORDER BY published_at DESC, video_id DESC
  LIMIT 20
  ON CONFLICT DO NOTHING;
  ```

  Tối đa **20** video mới nhất trong 30 ngày. Chỉnh chi tiết so với chữ "vài chục video" của ADR-0005 luật 3: 20 là hai
  trang feed, người dùng thấy kết quả ngay mà mỗi follow chỉ ghi tối đa 20 dòng.
- **`user.unfollowed`**: khoá theo `followee_id`; xoá cạnh; xoá các dòng timeline của follower có video thuộc
  `followee_id`: `DELETE FROM timeline t USING videos v WHERE t.user_id = $follower_id AND t.video_id = v.video_id AND
  v.author_id = $followee_id`.
- **`video.ready`**: kiểm field trước: `video_id`, `author_id` là UUID; `playlist_key`, `thumbnail_key` dạng
  `media/<video_id>/...`, mỗi đoạn chỉ gồm `[A-Za-z0-9._-]`, không phải `.` hay `..` (như FF-6 của ADR-0008, hàm
  `objstore.IsMediaKey` mà video-service cũng gọi); có `published_at` và `duration`. Sai thì `kafkax.Permanent` →
  `video.lifecycle.v1.dlq`. Rồi khoá theo `author_id`; ghi `videos` `ON CONFLICT (video_id) DO NOTHING`; fan-out bằng
  **một câu** trong cùng transaction, lấy `published_at` từ dòng trong `videos`:

  ```sql
  INSERT INTO timeline (user_id, published_at, video_id)
  SELECT f.follower_id, v.published_at, v.video_id
  FROM follows f JOIN videos v ON v.video_id = $video_id
  WHERE f.followee_id = $author_id
  ON CONFLICT DO NOTHING;
  ```

  Tác giả không nhận video của chính mình trong feed following: user-service không cho tự follow
  (`follows_no_self_follow`), nên tác giả không có trong `follows` của chính mình.
- `video.uploaded`, nhánh `oneof` lạ hay rỗng: bỏ qua, commit (ADR-0006). Payload không parse được: `kafkax.Permanent`.
- **Retry:** lỗi tạm thời (Postgres, Kafka) thử lại **không giới hạn số lần**, backoff 0,5 s → trần 10 s; DLQ chỉ cho
  payload hỏng. Với consumer từng record hiện có, đặt `MaxAttempts` = `math.MaxInt` (backoff đã có trần), không đổi API
  của kafkax. Lý do: đẩy `user.followed` hay `video.ready` hợp lệ vào DLQ chỉ vì Postgres chập chờn làm read model lệch
  mà không ai biết, và phát lại từ DLQ sau đó lại có thể sai thứ tự (giới hạn ở dưới). Partition bị chặn trong lúc
  Postgres lỗi là đúng ý: lag tăng, không mất gì.
- **Tài khoản lớn** (A7: 200k follower): ở local giữ fan-out on write thuần (ADR-0005 phương án B), không làm lai; đo độ
  tươi ở 10.000 và 200.000 follower (mục 10). Xem lại khi p95 ở 200k vượt 10 s: chia fan-out thành nhiều transaction có
  điểm dừng, hoặc chuyển sang phương án C của ADR-0005.
- **Giới hạn đã biết:** phát lại phải giữ thứ tự partition (`rpk group seek` cả group); đẩy lại riêng một
  `user.followed` cũ từ DLQ có thể dựng lại một cạnh đã unfollow. Xem lại khi cần phát lại DLQ an toàn: tombstone cạnh
  kèm `occurred_at`, bỏ qua event cũ hơn trạng thái đã có.
- **Giới hạn đã biết:** consumer của feed-service bật `BlockRebalance` với `RebalanceTimeout` 5 phút, nên rebalance chờ
  record đang thử lại. Postgres lỗi lâu hơn 5 phút, có từ 2 replica và rebalance xảy ra giữa chừng thì group loại thành
  viên đang thử lại, partition sang replica khác; lần thử lại cũ của một `user.followed` vẫn chạy và có thể áp sau
  `user.unfollowed` mà chủ mới đã áp, làm cạnh quay lại. Đóng hẳn cần kafkax dừng handler khi partition bị thu về.

## 8. Phân trang feed

[Architecture §8.3](../architecture.md#83-phân-trang-feed) đã chốt token là base64url của bytes protobuf một message nội
bộ, không ký (PG-1); mục này chốt cách mã hoá.

### Các lựa chọn về mã hoá page token

#### A. Mã hoá tay bằng `google.golang.org/protobuf/encoding/protowire`, không có file `.proto`

- Được: đúng định dạng của §8.3 (bytes protobuf, thêm field về sau theo số field); hai field chỉ vài chục dòng code;
  không thêm cấu hình sinh code; gói đã có trong `go.mod`.
- Mất: không có schema viết ra cho message này; số field ghi trong code và ở đây.

#### B. Message `.proto` riêng của feed-service, sinh code

- Mất: `proto/` là contract công khai (§8.3 nói rõ message này không nằm ở đó); đặt chỗ khác thì cần cấu hình `buf` sinh
  code thứ hai, chỉ cho hai field.

#### C. JSON rồi base64url

- Mất: token dài gần gấp đôi; không phải định dạng §8.3 đã chốt.

### Quyết định về phân trang

Chọn **A**.

- Message: field 1 `published_at`, kiểu varint int64, micro giây Unix (độ chính xác của `timestamptz`); field 2
  `video_id`, kiểu bytes, đúng 16 byte. Token = base64url **không padding** của bytes đó (khoảng 36 ký tự).
- Giải mã: token dài quá **64 ký tự** thì từ chối trước khi giải mã (PG-2); không phải base64url, giải mã protowire lỗi,
  thiếu field, sai kiểu wire hay `video_id` không đủ 16 byte: `INVALID_ARGUMENT`, reason **`INVALID_PAGE_TOKEN`**. Field
  lạ bỏ qua, như protobuf.
- `page_size`: 0 → 10; > 50 → 50; âm → `INVALID_ARGUMENT`, reason **`INVALID_PAGE_SIZE`**.
- Đọc `page_size + 1` dòng: có dòng thừa thì `next_page_token` mã hoá (`published_at`, `video_id`) của dòng cuối trang;
  không có thì `next_page_token` rỗng.
- Feed following: từ `timeline` của người gọi (`user_id` lấy từ `x-user-id`, không từ token), lọc 30 ngày, nối `videos`
  lấy metadata; trang sau thêm `(published_at, video_id) < ($token_published_at, $token_video_id)`, `ORDER BY
  published_at DESC, video_id DESC`.
- Feed khám phá: từ bảng `videos` (mọi video `READY`, không giới hạn 30 ngày), cùng điều kiện keyset trên index
  `(published_at DESC, video_id DESC)`.

## 9. Gateway

### Các lựa chọn khi ghép số đếm lỗi

#### A. Một lời gọi `GetStats` cho cả trang, timeout 100 ms, không retry; lỗi thì trả trang không có `stats`

- Được: SLO của feed không phụ thuộc engagement-service ([architecture §7.2](../architecture.md#72-đọc-feed)); một lời
  gọi cho 10 video thay vì 10 lời gọi.
- Mất: khi engagement-service chậm, người dùng thấy feed thiếu số đếm.

#### B. Lỗi `GetStats` thì cả request feed lỗi

- Mất: feed (SLO 99,9%, p99 150 ms) sập theo service kém quan trọng hơn; ngược §7.2 và §8.4.

#### C. Retry `GetStats`

- Mất: ngân sách 100 ms không chứa nổi một lần thử lại có ý nghĩa; retry và circuit breaker giữa service làm đủ ở
  phần C.

### Quyết định về gateway

Chọn **A**. 100 ms: ngân sách p99 của cả request feed là 150 ms; đọc feed-service và `GetStats` (≤ 50 lần đọc theo khoá
chính) khi khoẻ chỉ vài mili giây, 100 ms để dư cho lúc Postgres bận mà vẫn trả được trong 150 ms.

- `GET /feed/following` và `GET /feed/explore`: Bearer JWT; query `cursor` (chuyển nguyên thành `page_token`, gateway
  không đọc) và `page_size`. Trả `{"items": [...], "next_cursor": ""}` (`next_cursor` = `next_page_token`, rỗng là hết
  trang). Mỗi item có `video_id`, `author_id`, `title`, `duration_ms`, `playlist_url`, `thumbnail_url`, `published_at`
  (tên và kiểu giống schema `Video` của `services/gateway/openapi.yaml`; URL = `MEDIA_PUBLIC_BASE_URL` + `/` + key) và
  `stats` (`view_count`, `like_count`, `liked_by_me`).
- Ghép số đếm: một `GetStats` cho mọi `video_id` của trang (bỏ qua khi trang rỗng), timeout **100 ms**, không retry; lỗi
  hay quá hạn thì trả trang **không có field `stats`** ở mọi item (vắng mặt, không phải số 0) và log WARN; lỗi này không
  đi qua bảng mã lỗi §8.4.
- `PUT /videos/{video_id}/like` và `DELETE /videos/{video_id}/like` → 204; `POST /videos/{video_id}/views` → 202. Lỗi
  đổi theo [architecture §8.4](../architecture.md#84-mã-lỗi-grpc-sang-http-ở-gateway) (ví dụ `RecordView` `UNAVAILABLE`
  → 503).
- `/readyz` kiểm thêm feed-service, **không** kiểm engagement-service: engagement lỗi thì feed vẫn phải phục vụ.
- Biến mới: `FEED_SERVICE_ADDR` (mặc định `127.0.0.1:9104`), `ENGAGEMENT_SERVICE_ADDR` (mặc định `127.0.0.1:9103`),
  dial như `USER_SERVICE_ADDR`; mặc định loopback giống `USER_SERVICE_ADDR` / `VIDEO_SERVICE_ADDR` hiện có (IN-2).
  Compose đặt tường minh `feed-service:9104` và `engagement-service:9103`.
- Route mới ghi vào `services/gateway/openapi.yaml` cùng lúc với code.

## 10. Đo độ tươi

NFR "Độ tươi" tính từ `video.ready` tới dòng timeline cuối cùng. Cần đo ở số follower đủ lớn, mà tạo hàng chục nghìn tài
khoản thật qua `Register` (argon2id, JWT-7) thì chậm và không đo thứ cần đo.

### Các lựa chọn về cách tạo follower giả

#### A. Công cụ Go phát `user.followed` vào `user.follows.v1` từ máy host

- Được: đi đúng đường consumer thật của feed-service (event, khoá, `follows`); dọn được bằng chính `user.unfollowed`.
- Mất: công cụ giả danh user-service (IN-4 chưa có ACL tới giai đoạn 4); bản sao follow ở feed-service lệch user-service
  cho tới khi dọn.

#### B. Ghi thẳng vào `svp_feed`

- Mất: bỏ qua consumer, đo thiếu phần đáng đo; làm bẩn read model bằng đường không phải của hệ thống.

### Quyết định về đo độ tươi

Chọn **A**.

- Công cụ `tools/fakefollows` (sẽ tạo) phát `user.followed` vào `user.follows.v1` ở `127.0.0.1:19092` cho N follower giả
  (UUIDv7 mới) của **một tác giả mới**, mỗi lượt đo (mỗi N) một tác giả (không có video cũ, nên follow giả không kéo
  backfill); cuối buổi phát `user.unfollowed` cho đúng các id đó để dọn. Chỉ chạy trên stack local; comment trong code
  ghi rõ nó giả danh user-service.
- Trước video đầu tiên của mỗi lượt đo: chờ tới khi feed-service đã nhận đủ N `user.followed`, tức `SELECT count(*)
  FROM follows WHERE followee_id = $author` trên `svp_feed` bằng N (đọc theo khoá chính). Upload sớm hơn thì follower
  tới sau nhận video qua backfill thay vì fan-out, và thời gian đo gồm cả thời gian nạp follow. Dọn cũng vậy: chờ số
  này về 0.
- Mỗi video: upload clip ngắn qua gateway, chờ `READY`. **Bắt đầu** là `published_at` trong `svp_video` (video-service
  đặt bằng `now()` của Postgres); **kết thúc** là dòng timeline cuối cùng của video: poll `SELECT count(*) FROM timeline
  WHERE video_id = ...` trên `svp_feed` mỗi 100 ms tới khi đủ N dòng, rồi lấy `max(created_at)` của các dòng đó
  (`clock_timestamp()` lúc chèn từng dòng). Hai mốc cùng đồng hồ Postgres, nên không lệch đồng hồ giữa máy và container;
  thời gian một lần poll quét bảng không cộng vào số đo.
- Số đo: **N = 10.000, 10 video** (số chính, so NFR p95 < 10 s) và **N = 200.000, 3 video** (A7, điểm dữ liệu).
- Fan-out là một câu trong một transaction (mục 7), nên số dòng nhảy từ 0 lên N lúc commit; số đo không gồm thời gian
  commit sau dòng cuối (nhỏ so với fan-out), và không gồm chu kỳ poll hay thời gian đếm (`timeline` không có index theo
  `video_id`, nên mỗi lần đếm quét bảng).

## 11. Topic và consumer group

Tạo thêm trong `deploy/redpanda/create-topics.sh`, cùng cách và cùng lý do với ADR-0008 mục 5:

| Topic | Partition | Replication | Retention |
| --- | --- | --- | --- |
| `user.follows.v1` | 3 | 1 | 7 ngày (`retention.ms=604800000`) |
| `engagement.views.v1` | 3 | 1 | 7 ngày |
| `user.follows.v1.dlq` | 1 | 1 | 14 ngày (`retention.ms=1209600000`) |
| `engagement.views.v1.dlq` | 1 | 1 | 14 ngày |

| Consumer group | Đọc | Ghi DLQ |
| --- | --- | --- |
| `feed-service` | `user.follows.v1`, `video.lifecycle.v1` | `user.follows.v1.dlq`, `video.lifecycle.v1.dlq` |
| `engagement-service` | `engagement.views.v1` | `engagement.views.v1.dlq` |

3 partition: tối đa 3 instance mỗi consumer chạy song song; key theo `follower_id` / `video_id` (ADR-0006) giữ thứ tự
theo thực thể.

## 12. Cổng, RAM, database

| Service | Cổng gRPC | Publish ra máy | `mem_limit` |
| --- | --- | --- | --- |
| `engagement-service` | `9103` | Không, chỉ trong mạng compose (IN-2) | 256 MB |
| `feed-service` | `9104` | Không (IN-2) | 256 MB |

- Cổng tiếp dải của user-service (9101) và video-service (9102); `lsof` ngày 2026-10-11 không thấy gì ở 9103, 9104.
- Tổng giới hạn của stack: redpanda 1,5 GB + minio 512 MB + media-worker 2 GB + hai service mới 2 × 256 MB ≈ 4,5 GB,
  cộng vài chục MB mỗi service chưa đặt giới hạn; dưới ~5 GB trên VM 7,65 GiB.
- Database `svp_engagement`, `svp_feed`, mỗi cái hai role `svp_<svc>_migrator` / `svp_<svc>_app`, tạo bằng
  `deploy/postgres/bootstrap.sh` như user/video (IN-6). Biến `.env` mới: `SVP_ENGAGEMENT_MIGRATOR_DB_PASSWORD`,
  `SVP_ENGAGEMENT_APP_DB_PASSWORD`, `SVP_FEED_MIGRATOR_DB_PASSWORD`, `SVP_FEED_APP_DB_PASSWORD`.
- Biến của hai service mới: `LISTEN_ADDR`, `DATABASE_URL`, `KAFKA_BROKERS`; thiếu biến bắt buộc thì thoát ngay với lỗi
  nêu tên biến (ADR-0007). `LISTEN_ADDR` mặc định `127.0.0.1:9103` (engagement-service) và `127.0.0.1:9104`
  (feed-service), giống user-service và video-service: chạy native thì chỉ nghe loopback (IN-2). Compose đặt `:9103` /
  `:9104` để nghe trong mạng compose.

## 13. Dependency và contract

- **Không thêm dependency**: franz-go, pgx, sqlc, grpc, protobuf (cả `protowire`) đã có. Gói
  `github.com/twmb/franz-go/pkg/kmsg` v1.14.0 (mục 4, hỏi end offset) đã nằm trong `go.mod` dạng `// indirect` vì
  franz-go cần nó; kafkax import trực tiếp thì chỉ bỏ chú thích `// indirect`, không thêm module. Không dùng
  `pkg/kadm` (có sẵn `ListEndOffsets`) vì nó chưa có trong `go.mod`.
- **Không đổi `proto/`**: contract của engagement, feed, user và event đã viết ở giai đoạn 0 đủ cho phần B (đã đối chiếu
  từng RPC và từng field ở các mục trên).

## 14. Phạm vi phần B

### Các lựa chọn về phạm vi

#### A. Làm cả phần B và phần C (Redis, cache, rate limit, resilience) cùng lúc

- Mất: hai nhóm việc độc lập dồn vào một lần; không đo riêng được hiệu quả của cache và rate limit so với hệ thống chưa
  có chúng.

#### B. Phần B dừng ở luồng follow → feed → like/xem chạy đầu-cuối có số đo; phần C thêm lớp bảo vệ

- Được: phần B kết thúc ở trạng thái chạy được, có số đo độ tươi và kiểm gửi trùng, đúng nguyên tắc của plan; phần C có
  mốc để so.
- Mất: trong khoảng giữa hai phần, route ghi like và lượt xem chưa có rate limit (chỉ chạy local, chấp nhận).

### Quyết định về phạm vi

Chọn **B**. Sang phần C:

- Redis; cache feed khám phá + singleflight (ADR-0005 luật 6).
- Rate limit ở gateway, gồm RL-3 (một lượt xem mỗi cặp `user_id`/`video_id` trong một khoảng) và RL-6 (rate limit ghi
  like và lượt xem theo user).
- Timeout, retry, circuit breaker giữa service (ngoài timeout 100 ms của `GetStats` ở mục 9).
- Job dọn upload bỏ dở và UP-7 (đã hẹn ở ADR-0008 mục 13).
- k6 ở giai đoạn 6.

## Hệ quả

- Được:
  - Follow, unfollow tới được feed-service mà không mất event (outbox), đúng thứ tự trong từng cạnh.
  - Bộ đếm lượt xem đếm đúng một lần dù event giao nhiều lần, với chi phí chống trùng là một dòng mỗi partition; ghi
    nóng thành ~1–2 transaction/s thay vì 10.000 câu `UPDATE`/s.
  - Like của chính mình thấy ngay; số like đúng tuyệt đối; `GetStats` chỉ đọc theo khoá chính.
  - Read model của feed chịu được event trùng, lệch thứ tự giữa hai topic và nhiều replica, nhờ khoá theo tác giả và
    khoá chính chống trùng; đọc feed là một lần quét index.
  - Feed vẫn phục vụ khi engagement-service lỗi (trang không có `stats`).
  - Độ tươi có số đo ở 10.000 và 200.000 follower, so được với NFR.
- Phải trả:
  - user-service phụ thuộc Kafka và chạy thêm một relay.
  - Đúng đắn của bộ đếm lượt xem dựa vào offset Kafka ổn định. Topic được tạo lại mà đã có số record bằng hoặc lớn hơn
    offset cũ (end offset ≥ `next_offset` lưu) trước khi consumer đọc tới thì không phát hiện được: những lượt xem đầu
    của topic mới bị coi là đã cộng và bị bỏ.
    Chỉ xảy ra ở local sau `make clean-data` (Postgres native giữ `consumer_offsets`).
  - Lô giao lại nằm hẳn dưới offset đã lưu (sau rebalance, hay commit Kafka hỏng) tốn thêm một lời gọi `ListOffsets`
    tới broker trong lúc giữ khoá dòng `consumer_offsets`.
  - Consumer lượt xem và consumer feed thử lại không giới hạn: Postgres lỗi lâu thì partition đứng và lag tăng; chưa có
    cảnh báo lag tới giai đoạn 3.
  - Fan-out của tài khoản lớn là một transaction giữ khoá tác giả suốt đợt ghi; follow và unfollow tác giả đó chờ theo.
  - Job dọn timeline và phép đếm khi đo độ tươi quét bảng `timeline` (không có index theo `published_at` hay `video_id`,
    cố ý để fan-out chỉ ghi một index).
  - `hashtextextended` là hàm nội bộ, không nằm trong danh mục hàm có tài liệu của Postgres; đổi hàm hash là đổi khoá,
    mọi replica phải đổi cùng lúc.
  - Phát lại event phải giữ thứ tự partition; đẩy lại riêng một `user.followed` cũ từ DLQ có thể dựng lại cạnh đã
    unfollow.
  - `tools/fakefollows` giả danh user-service (IN-4 chưa có ACL), để lại bản sao follow lệch tới khi chạy chế độ dọn.
  - Chưa có: Redis, cache, rate limit (RL-3, RL-6), timeout/retry/circuit breaker giữa service, job dọn upload bỏ dở,
    UP-7 (phần C).
- Xem lại khi:
  - Độ tươi p95 ở 200.000 follower vượt 10 s: chia fan-out thành nhiều transaction có điểm dừng, hoặc phương án C của
    ADR-0005.
  - Redpanda trả topic ID trong fetch: lưu topic ID cùng offset để phát hiện topic tạo lại chắc chắn.
  - Chạy Redpanda nhiều node (cloud): kiểm end offset trả về không lùi khi đổi leader, vì phép phát hiện topic tạo lại
    ở mục 4 dựa vào điều đó.
  - Cần phát lại DLQ của `user.follows.v1` an toàn: tombstone cạnh kèm `occurred_at`.
  - Job dọn timeline một lượt chạy quá 5 phút, hoặc tải của nó thấy rõ trên Postgres: partition `timeline` theo ngày
    hoặc thêm index BRIN theo `published_at`.
  - Lag của `engagement-service` vượt 1 phút ở tải thật (NFR "Nhất quán"): tăng kích thước lô, thêm instance (tối đa
    3 partition), hoặc so lại các cách ở lab `hot-counter`.
  - Feed p99 vượt 150 ms ở k6 vì phần ghép số đếm: xem lại timeout 100 ms và cache số đếm (phần C).
