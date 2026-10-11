# Architecture Decision Records

Mỗi ADR ghi một quyết định kiến trúc: bối cảnh lúc quyết, các lựa chọn đã cân nhắc, chọn gì, và cái giá phải trả. Mục đích
là để người đọc sau (kể cả chính mình sáu tháng sau) hiểu **vì sao**, không chỉ thấy **cái gì**.

## Khi nào viết

- Quyết định khó đảo ngược hoặc ảnh hưởng nhiều service: ranh giới service, giao thức, cách lưu dữ liệu, chọn công cụ.
- Đổi công cụ đã chốt trong plan, hoặc kết luận một bài so sánh (ví dụ Elastic với Grafana).
- Không viết cho chi tiết hiện thực đổi được trong một buổi.

## Quy ước

- Tên file `NNNN-<slug>.md`, số tăng dần, không dùng lại số.
- Trạng thái: **Đề xuất** (chờ duyệt) → **Chấp nhận**; về sau có thể thành **Bị thay bởi NNNN** hoặc **Bỏ**. ADR vẫn đứng
  nhưng có một chi tiết được ADR sau chỉnh thì ghi **Chấp nhận; <phần> chỉnh bởi NNNN**.
- ADR đã chấp nhận không sửa nội dung quyết định. Đổi ý thì viết ADR mới và cập nhật trạng thái ADR cũ.

## Mẫu

```markdown
# NNNN. <Quyết định, viết thành một mệnh đề>

- Trạng thái: Đề xuất
- Ngày: YYYY-MM-DD

## Bối cảnh

Vấn đề cần giải, ràng buộc, số liệu liên quan (dẫn tới docs/architecture.md nếu có).

## Các lựa chọn

### A. <Tên>

- Được: ...
- Mất: ...

## Quyết định

Chọn ..., vì ...

## Hệ quả

- Được: ...
- Phải trả: ...
- Xem lại khi: <điều kiện đo được>
```

## Danh sách

| ADR | Quyết định | Trạng thái |
| --- | --- | --- |
| [0001](0001-service-boundaries-and-data-ownership.md) | 6 service theo ranh giới nghiệp vụ, mỗi service một database | Chấp nhận |
| [0002](0002-sync-rest-edge-grpc-internal.md) | REST/JSON ở biên, gRPC bên trong, contract quản lý bằng `buf` | Chấp nhận; đường dẫn `.proto` chỉnh bởi [0006](0006-contract-ids-and-event-envelope.md) |
| [0003](0003-async-events-outbox.md) | Event qua Redpanda, transactional outbox, at-least-once + consumer idempotent + DLQ | Chấp nhận |
| [0004](0004-direct-upload-and-hls.md) | Upload thẳng lên object storage bằng presigned URL, transcode bất đồng bộ ra HLS | Chấp nhận |
| [0005](0005-feed-fan-out-on-write.md) | Feed dựng sẵn khi ghi (fan-out on write), Redis chỉ cache key nóng | Chấp nhận |
| [0006](0006-contract-ids-and-event-envelope.md) | Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1` | Chấp nhận |
| [0007](0007-go-monorepo-toolchain-and-stage1-scope.md) | Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi giai đoạn 1 thu về luồng đồng bộ | Chấp nhận |
