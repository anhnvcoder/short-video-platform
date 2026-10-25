# 0003. Event qua Redpanda; transactional outbox; at-least-once với consumer idempotent và DLQ

- Trạng thái: Chấp nhận
- Ngày: 2026-10-04

## Bối cảnh

- Luồng upload → transcode → phát hành → vào feed kéo dài cỡ phút và đi qua 4 service. Không thể là một chuỗi gọi đồng bộ:
  client không chờ được, và một service chậm sẽ giữ cả chuỗi.
- Mỗi bước có dạng "ghi database của mình, rồi báo cho service khác". Hai việc này nằm ở hai hệ thống khác nhau (Postgres
  và broker), không có transaction chung. Đây là bài toán **dual write**: commit database xong mà gửi event thất bại thì
  video kẹt mãi ở `PROCESSING`; gửi event trước mà commit thất bại thì có event cho một video không tồn tại.
- Không có cách giao "đúng một lần" (exactly-once) xuyên suốt khi có tác dụng phụ ra ngoài broker (ghi database khác, ghi
  object storage). Phải chọn giữa "có thể mất" và "có thể trùng".
- Broker đã chốt trong plan: Redpanda (Kafka API, một binary, nhẹ cho máy 16 GB; khái niệm dùng lại cho Kafka/MSK).

## Các lựa chọn cách phát event

### A. Dual write: commit database rồi produce

- Được: đơn giản.
- Mất: crash giữa hai bước là mất event. Không chấp nhận được với `video.uploaded`.

### B. Transactional outbox + relay polling

Ghi event vào bảng `outbox` **trong cùng transaction** với thay đổi dữ liệu. Một goroutine relay trong service đọc các
dòng chưa gửi (`FOR UPDATE SKIP LOCKED`), produce lên Redpanda, rồi đánh dấu đã gửi.

- Được: thay đổi dữ liệu và event là nguyên tử; chỉ cần Postgres và một đoạn code nhỏ.
- Mất: thêm độ trễ bằng chu kỳ poll (~100–500 ms); relay crash sau khi produce mà trước khi đánh dấu thì event được gửi
  lại, nên consumer bắt buộc phải chịu được trùng; bảng outbox phải dọn định kỳ.

### C. Change data capture (Debezium, Redpanda Connect) đọc WAL của Postgres

- Được: không phải poll; không phải sửa code ghi dữ liệu.
- Mất: thêm một hệ thống phải vận hành (connector, replication slot; slot bị kẹt sẽ giữ WAL và làm đầy đĩa Postgres);
  nặng cho máy 16 GB.

### D. `LISTEN/NOTIFY` của Postgres

- Mất: thông báo không bền, mất khi không có ai đang nghe. Loại.

## Quyết định

Chọn **B**, cùng các luật sau:

1. **At-least-once + consumer idempotent.** Mỗi event có `event_id` duy nhất. Consumer nào có tác dụng không tự idempotent
   thì ghi `event_id` vào bảng `processed_events` trong cùng transaction với tác dụng đó; gặp lại thì bỏ qua. Consumer có
   tác dụng tự idempotent thì không cần bảng (ghi đè object theo đường dẫn cố định, `INSERT ... ON CONFLICT DO NOTHING`,
   chuyển trạng thái chỉ theo một chiều).
2. **Retry rồi DLQ.** Lỗi tạm thời thì retry có backoff, giới hạn số lần. Hết lượt hoặc lỗi vĩnh viễn (event hỏng, vi
   phạm nghiệp vụ) thì đẩy sang topic `<topic>.dlq` kèm lý do, rồi commit offset để partition không bị chặn. DLQ có cảnh
   báo và có cách phát lại.
3. **Key theo thực thể.** Key của event là id của thực thể (`video_id`, `follower_id`), nên mọi event của một thực thể vào
   cùng partition và giữ thứ tự. Thứ tự giữa các thực thể khác nhau không được đảm bảo, và không thiết kế gì dựa vào nó.
4. **Event không đi kèm thay đổi dữ liệu thì produce thẳng** (`acks=all`), không qua outbox. Outbox chỉ để làm nguyên tử
   cặp "ghi database + phát event"; `view.recorded` không ghi database nào nên không cần.
5. **Event về một thực thể chỉ do service sở hữu nó phát** ([ADR-0001](0001-service-boundaries-and-data-ownership.md)). Vì vậy so với bảng trong plan:
   media-worker phát `transcode.completed` / `transcode.failed` (kết quả job của nó), còn `video.ready` do video-service
   phát sau khi đã chuyển trạng thái. Event chưa có service nhận (`video.failed`, `like.toggled`) thì chưa tạo.
6. **Schema event viết bằng Protobuf**, cùng chỗ và cùng `buf lint` / `buf breaking` với API gRPC. Envelope (các field
   chung như `event_id`, thời điểm xảy ra) chốt ở bước viết contract.

Saga upload chạy theo **choreography**: không có bộ điều phối trung tâm, mỗi service nghe event rồi làm phần của mình; lỗi
transcode thì video-service chạy bước bù (chuyển `FAILED`, dọn file). Luồng đầy đủ ở [architecture.md §7.1](../architecture.md#71-upload-tới-khi-vào-feed-saga-dạng-choreography).
Chọn choreography vì saga chỉ có 3 bước và một nhánh lỗi; orchestration (một service điều phối, hoặc Temporal) đáng
cân nhắc khi số bước và nhánh lỗi tăng tới mức khó theo dõi luồng qua event.

## Hệ quả

- Được: không mất event khi crash; không thêm hệ thống nào ngoài Postgres và Redpanda.
- Phải trả:
  - mọi consumer phải idempotent và phải có test gửi trùng;
  - outbox cần job dọn các dòng đã gửi;
  - trễ thêm một chu kỳ poll ở mỗi bước có outbox;
  - luồng nghiệp vụ nằm rải rác ở nhiều consumer, phải dựa vào tracing để nhìn được toàn cảnh.
- Xem lại khi: poll outbox thành tải đáng kể cho Postgres, hoặc cần độ trễ thấp hơn chu kỳ poll. Lúc đó cân nhắc CDC.

## Hiện thực ở

- Outbox và relay: `internal/outbox/`; bảng outbox ở `services/user-service/migrations/00003_create_outbox.sql`,
  `services/video-service/migrations/00002_create_outbox.sql`.
- Consumer at-least-once, commit tay, DLQ: `internal/kafkax/`; consumer idempotent ở `services/feed-service/internal/projector/`,
  `services/video-service/internal/server/transcode.go`, `services/engagement-service/internal/server/views.go`.
- Kiểm gửi trùng: `deploy/compose/drills/duplicate-events.sh`, `deploy/compose/drills/duplicate-feed-events.sh`.
