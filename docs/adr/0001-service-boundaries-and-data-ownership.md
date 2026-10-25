# 0001. Chia hệ thống thành 6 service theo ranh giới nghiệp vụ, mỗi service sở hữu một database

- Trạng thái: Chấp nhận
- Ngày: 2026-10-04

## Bối cảnh

- Tải thật nhỏ ([architecture.md §3](../architecture.md#3-ước-lượng-quy-mô)): feed ~21 req/s, upload ~2 video/phút lúc cao điểm.
  Một ứng dụng duy nhất trên một Postgres chịu được thoải mái, kể cả ở mục tiêu tải 1.000 req/s.
- Mục tiêu của project là **học** vận hành hệ phân tán: deploy độc lập, lời gọi qua mạng có thể hỏng, event, trace xuyên
  service, scale từng phần, canary từng service. Một khối duy nhất không có chỗ để học những thứ này.
- Các phần của hệ thống có hình dạng tải khác nhau thật sự:
  - transcode ngốn CPU, mỗi job vài chục giây tới vài phút, tới dồn cục;
  - feed đọc nhiều nhất, cần độ trễ thấp;
  - lượt xem là ghi dồn dập, tập trung vào vài video viral;
  - tài khoản và follow ít thay đổi nhưng chứa dữ liệu nhạy cảm (mật khẩu).

## Các lựa chọn

### A. Monolith: một ứng dụng, một database

- Được: đơn giản nhất; transaction ACID trên mọi bảng; debug trong một process.
- Mất: transcode giành CPU với feed; scale cả khối dù chỉ một phần cần; không có chất liệu cho phần lớn lộ trình.

### B. Modular monolith + worker transcode riêng

- Được: **đây là lựa chọn đúng cho một team thật ở quy mô này.** Module tách rõ nên sau này tách service dễ; worker riêng đã
  giải quyết khác biệt tải lớn nhất (CPU của transcode).
- Mất: outbox giữa service, saga, gRPC, service graph, canary từng service gần như không có chỗ thực hành.

### C. Microservices theo ranh giới nghiệp vụ, mỗi service một database

- Được: mỗi phần scale, deploy và hỏng độc lập (feed vẫn chạy khi transcode nghẽn); đủ chất liệu cho mọi giai đoạn sau.
- Mất: vận hành phức tạp hơn hẳn (nhiều deploy, lỗi mạng, dữ liệu nhất quán sau cùng, dữ liệu trùng lặp); tốn công nhiều
  hơn mức tải thật đòi hỏi.

## Quyết định

Chọn **C**, vì mục tiêu học, không phải vì tải. Ghi rõ điều này để không tự lừa mình: với cùng yêu cầu nhưng mục tiêu là
kinh doanh, nên chọn B.

**Cách chia:**

| Service | Sở hữu | Vì sao là một service riêng |
| --- | --- | --- |
| `gateway` | không có dữ liệu | Một cửa vào: xác thực JWT, rate limit, ghép dữ liệu cho client |
| `user-service` | tài khoản, hash mật khẩu, follow | Dữ liệu nhạy cảm nằm gọn một chỗ, ít người chạm. Follow đi cùng user vì luôn là câu hỏi về quan hệ giữa các user; tách riêng một service "social graph" chưa đáng |
| `video-service` | metadata, vòng đời video, đường dẫn object | Nguồn sự thật duy nhất về video; điều phối các bước của saga upload |
| `media-worker` | không có database | CPU nặng, chạy theo job, scale theo hàng chờ; lỗi ở đây không chạm đường đọc |
| `engagement-service` | like, bộ đếm | Ghi nóng dồn vào vài key; cần gom ghi riêng mà không làm chậm phần khác |
| `feed-service` | timeline; bản sao follow và video đã phát hành | Đọc nhiều nhất; mô hình dữ liệu tối ưu cho đọc (CQRS), dựng lại được từ nguồn |

**Luật sở hữu dữ liệu:**

1. Mỗi service một database Postgres riêng (`svp_<service>`) với user chỉ có quyền trên database đó. Local dùng chung một
   instance Postgres native để tiết kiệm RAM: ranh giới là database và quyền, không phải instance.
2. Không service nào đọc database của service khác, không join xuyên service. Cần dữ liệu của service khác thì:
   - gọi API (gRPC) khi cần dữ liệu mới nhất và chấp nhận phụ thuộc vào service kia lúc chạy;
   - giữ bản sao cập nhật bằng event khi cần đọc nhanh và không muốn phụ thuộc (feed-service giữ bản sao follow, video).
3. Event về một thực thể chỉ do service sở hữu thực thể đó phát. Ví dụ chỉ video-service phát `video.ready`; media-worker
   chỉ báo kết quả job của nó.

## Hệ quả

- Được: scale, deploy, hỏng độc lập; ranh giới dữ liệu rõ, đọc code biết ngay ai được ghi bảng nào.
- Phải trả:
  - không có transaction xuyên service, nên cần outbox và saga ([ADR-0003](0003-async-events-outbox.md));
  - dữ liệu trùng lặp (follow lưu hai nơi, ~8 GB mỗi bản ở quy mô giả định) và chỉ nhất quán sau cùng;
  - nhiều thứ phải deploy và theo dõi; debug một request cần tracing (giai đoạn 3).
- Xem lại khi: hai service luôn phải sửa cùng nhau, hoặc gọi nhau đồng bộ ở hầu hết mọi request. Đó là dấu hiệu ranh giới
  đặt sai, nên gộp lại.

## Hiện thực ở

- Mỗi service một thư mục `services/<tên>/` (gateway, user-service, video-service, engagement-service, feed-service,
  media-worker); database và role riêng của từng service tạo ở `deploy/postgres/bootstrap.sql`, `deploy/postgres/bootstrap.sh`
  (cluster k3d dùng cùng file qua liên kết `deploy/helm/svp-data/files/bootstrap.sql`).
- Không khoá ngoại xuyên service: `services/video-service/migrations/00001_create_videos.sql` (`author_id`),
  `services/feed-service/migrations/00001_create_feed.sql` (bản sao follow và video dựng từ event).
