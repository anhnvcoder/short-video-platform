# 0005. Feed dựng sẵn khi ghi (fan-out on write) trong Postgres của feed-service; Redis chỉ cache key nóng

- Trạng thái: Chấp nhận
- Ngày: 2026-10-04

## Bối cảnh

- Feed "đang theo dõi": video `READY` mới nhất của những người mình follow, 10 video mỗi trang, phân trang bằng cursor.
- Mục tiêu tải 1.000 req/s, p99 < 150 ms tính cả phần gateway ghép số đếm. Video mới phải vào feed follower trong p95 < 10 s.
- Số liệu ([architecture.md §3](../architecture.md#3-ước-lượng-quy-mô)): mỗi tài khoản follow trung bình 50 người; mỗi video upload có trung
  bình 2.000 follower, tức ~2 triệu dòng timeline mỗi ngày; tài khoản lớn nhất ~200k follower.
- feed-service không được đọc database của user-service hay video-service ([ADR-0001](0001-service-boundaries-and-data-ownership.md)), nên dù chọn
  cách nào cũng phải giữ bản sao follow và video, cập nhật bằng event.

## Các lựa chọn

### A. Fan-out on read (pull)

Lúc đọc: lấy danh sách người mình follow, tìm video mới nhất của từng người, trộn lại, cắt 10.

- Được: ghi rẻ; không có bảng timeline.
- Mất: chi phí mỗi lần đọc tăng theo số người đang follow (người follow vài nghìn tài khoản sẽ chậm); cursor qua nhiều
  tác giả phức tạp; ở 1.000 req/s, đây là phép tính đắt nhất hệ thống và cứ lặp lại cho cùng một kết quả.

### B. Fan-out on write (push)

Khi một video `READY`: lấy danh sách follower của tác giả, ghi một dòng vào timeline của từng người. Lúc đọc chỉ là quét
một khoảng index theo `user_id`.

- Được: đọc rẻ và ổn định, không phụ thuộc số người đang follow, dễ giữ p99.
- Mất: số dòng ghi nhân theo số follower (write amplification); tài khoản lớn tạo một đợt ghi lớn; tốn chỗ lưu; follow và
  unfollow phải sửa timeline.

### C. Lai: push cho tài khoản thường, pull cho tài khoản quá nhiều follower

- Được: cách làm chuẩn ở quy mô hàng trăm triệu người dùng (tài khoản người nổi tiếng không gây đợt ghi khổng lồ).
- Mất: hai đường code; trộn kết quả và phân trang phức tạp; khó test.

## Quyết định

Chọn **B**. Ở quy mô giả định, đợt ghi lớn nhất là ~200k dòng; ghi theo lô thì mất cỡ vài giây (đo lại ở giai đoạn 2),
vẫn trong SLO 10 s. C chỉ đáng khi có tài khoản cỡ triệu follower. Chưa cần, nhưng ghi sẵn điều kiện chuyển.

1. **Dữ liệu của feed-service:** bản sao `follows` (từ `user.followed` / `user.unfollowed`), bản sao video đã phát hành (từ
   `video.ready`, đủ metadata để trả feed mà không gọi service khác), và `timeline`.
2. **Timeline chỉ giữ 30 ngày** (~60 triệu dòng, ~7 GB) thay vì tăng mãi; một job dọn dòng cũ. Cuộn quá 30 ngày thì feed
   hết.
3. **Follow mới** thì đưa ngay vài chục video gần nhất của người được follow vào timeline, để người dùng thấy kết quả liền.
   **Unfollow** thì xoá video của người đó khỏi timeline của mình.
4. **Ghi timeline theo lô, idempotent nhờ khoá chính:** nhận trùng `video.ready` thì `ON CONFLICT DO NOTHING`, không sinh
   dòng trùng.
5. **Phân trang bằng keyset**, không dùng `OFFSET`: cursor là cặp (`published_at`, `video_id`) của item cuối trang trước.
   Với `OFFSET`, video mới chèn vào đầu làm các trang sau bị lệch (thấy lại video cũ), và trang càng sâu càng chậm.
6. **Cache:**
   - Timeline cá nhân **không cache** lúc đầu. Đọc một trang là một lần quét index vài mili giây. Nếu cache trang đầu,
     mỗi video mới phải xoá cache của mọi follower: một video của tài khoản 200k follower là 200k lần xoá, đúng lúc hệ
     thống đang bận fan-out. Chỉ thêm khi k6 cho thấy p99 không đạt.
   - Feed khám phá là **một danh sách chung**, mọi người dùng mới cùng đọc: một key nóng. Cache-aside trong Redis với TTL
     vài giây, kèm singleflight để khi cache hết hạn chỉ một request đi xuống Postgres thay vì cả nghìn (lab `cache-stampede`).
7. **Số đếm và "đã like chưa" không nằm trong read model:** chúng đổi liên tục và khác nhau theo từng người xem. Gateway
   lấy từ engagement-service lúc đọc ([architecture.md §7.2](../architecture.md#72-đọc-feed)).

## Hệ quả

- Được: đọc rẻ và ổn định; read model tách khỏi dữ liệu nguồn, có thể xoá đi dựng lại.
- Phải trả:
  - dữ liệu trùng lặp (follow, video) và video mới vào feed trễ vài giây;
  - ghi nhân theo số follower;
  - read model hỏng thì phải dựng lại được: cần cách nạp lại từ service nguồn hoặc phát lại event, thiết kế ở giai đoạn 2.
- Xem lại khi: có tài khoản trên ~1 triệu follower, hoặc đo thấy fan-out p95 vượt 10 s. Lúc đó chuyển sang C.
