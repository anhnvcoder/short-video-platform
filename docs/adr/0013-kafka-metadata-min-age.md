# 0013. Mọi client franz-go đặt `MetadataMinAge` 1 s thay mặc định 5 s

- Trạng thái: Chấp nhận
- Ngày: 2026-10-18

## Bối cảnh

- [ADR-0011 §11](0011-observability-stage3.md#11-hạn-của-pool-và-vòng-nền) giữ các timeout/retry mặc định của franz-go
  **v1.22.1**, chỉ thêm `kgo.AllowIdempotentProduceCancellation()` để deadline của lời gọi huỷ được cả record đang gửi.
  Mọi client (producer, consumer, consumer theo lô, producer DLQ bên trong consumer) dựng qua `internal/kafkax.NewClient`.
- Test in-flight của giai đoạn 3 cho thấy hai đường hết hạn khác nhau:
  - Broker giữ ACK, kết nối còn sống: client tự huỷ request khi deadline của record qua, `Produce` trả về đúng hạn
    (relay outbox với hạn 1 s trả về sau ~1,0 s, kể cả khi đặt `MetadataMinAge` 10 s).
  - Kết nối chết giữa chừng (`REQUEST_TIMED_OUT` rồi mất kết nối): record chỉ bị đánh lỗi ở lần làm mới metadata kế tiếp,
    nên `Produce` trả về **trễ tới ~`MetadataMinAge` sau deadline**. Với mặc định 5 s, test hạn 1 s trả về sau ~5,0 s.
- Theo hạn của ADR-0011 §11, trường hợp xấu nhất với mặc định 5 s: relay outbox giữ advisory lock trong bước produce
  ~15 s (hạn 10 s), ghi lượt xem ~7 s (hạn 2 s) trong khi gateway chỉ chờ engagement-service có hạn.
- Mã nguồn franz-go v1.22.1 (`pkg/kgo`, module cache) nói về hai tham số:
  - `MetadataMinAge` (mặc định 5 s, `config.go`): "khoảng tối thiểu giữa hai lần hỏi metadata"; khi metadata thấy lỗi ở
    topic hay partition, client tự làm mới "sớm nhất khi được phép". Vòng `updateMetadataLoop` (`metadata.go`) chờ đủ
    `MetadataMinAge` kể từ lần trước cho mỗi lần làm mới do lỗi kích hoạt; `triggerUpdateMetadata` và `waitmeta` bỏ qua
    yêu cầu nếu lần trước còn trong `MetadataMinAge`. Lần làm mới "ngay" (`triggerUpdateMetadataNow`) bỏ qua lượt chờ
    này; khi còn lỗi bên trong, nó thử lại tối đa 8 lần, cách nhau `min(MetadataMinAge, 250 ms)`.
  - `MetadataMaxAge` (mặc định 5 phút): tuổi tối đa của metadata đã lưu; vòng làm mới chạy theo ticker chu kỳ này lúc khoẻ.
  - Ràng buộc khi dựng client: `MetadataMinAge` ≥ 10 ms và `MetadataMaxAge` ≥ `MetadataMinAge`.
  - `MetadataMinAge` còn là thời gian giữ cache metadata cho request chia theo leader như ListOffsets
    (`resolveTopicMeta`, `client.go`).
- Option áp theo thứ tự (`validateCfg` gọi lần lượt từng `opt.apply`), nên option của người gọi đặt sau thắng option
  mặc định đặt trước.

## Các lựa chọn

### A. Giữ mặc định 5 s

- Được: đúng như ADR-0011 §11 giữ mặc định; ít request metadata nhất khi broker lỗi.
- Mất: produce hết hạn trả về trễ tới ~5 s; relay giữ khoá ~15 s, ghi lượt xem ~7 s ở trường hợp xấu nhất.

### B. 1 s

- Được: trễ sau deadline còn ~1 s (relay ≤ ~11 s, ghi lượt xem ≤ ~3 s); test kết nối chết hạn 1 s trả về sau ~1,0 s.
- Mất: khi broker lỗi, mỗi client hỏi metadata tối đa 1 lần/giây thay vì 1 lần/5 giây.

### C. Thấp hơn (100–250 ms)

- Được: trễ sau deadline gần như bằng 0.
- Mất: broker đang lỗi bị hỏi metadata 4–10 lần/giây từ mỗi client, đúng lúc nó yếu nhất; cache metadata của ListOffsets
  gần như không còn tác dụng. Phần trễ còn lại (~1 s) đã nhỏ so với hạn 2–10 s của các lời gọi.

## Quyết định

Chọn **B**: `internal/kafkax.NewClient` thêm `kgo.MetadataMinAge(time.Second)` vào option mặc định, đặt **trước** option
của người gọi để test hay một service cần giá trị khác vẫn đè được. Giữ nguyên `MetadataMaxAge` 5 phút và mọi mặc định
khác ADR-0011 §11 đã liệt kê. Chỉnh câu "Giữ các timeout/retry mặc định franz-go" của ADR-0011 §11 ở đúng một tham số này;
[README](README.md) ghi ADR-0011 "§11 chỉnh bởi 0013".

Cận trên của test in-flight đi theo giá trị mới: test "kết nối chết" của `internal/kafkax` dùng deadline + `MetadataMinAge`
+ 2 s (từ 8 s xuống 4 s); test "broker giữ ACK" của `internal/outbox` giữ cận hạn produce + 2 s vì đường đó không chờ
làm mới metadata.

## Hệ quả

- Được: lời gọi produce có hạn trả về gần hạn hơn khi kết nối chết; relay nhả khoá sớm hơn ~4 s, ghi lượt xem không vượt
  quá nhiều ngân sách của gateway.
- Phải trả: lúc khoẻ gần như không tốn gì, vì làm mới theo `MetadataMaxAge`; ngoại lệ là ListOffsets
  (`kafkax.EndOffsets`, chỉ gọi khi engagement-service gặp lô giao lại) hỏi metadata trước nếu lần trước đã quá 1 s. Khi
  broker lỗi, mỗi client hỏi metadata thêm tối đa 1 lần/giây; hiện có 9 client trong 5 service (feed-service,
  media-worker, engagement-service, video-service mỗi service một client `NewClient` và một consumer; user-service một
  client), không đáng kể.
- Xem lại khi: số client tăng tới hàng trăm (pod nhân bản trên k8s) và metric request metadata của broker tăng rõ khi
  broker lỗi; hoặc một hạn produce được rút xuống dưới ~2 s, khi đó 1 s trễ trở thành phần lớn của hạn.
