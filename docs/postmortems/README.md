# Postmortem

Postmortem là bản ghi một sự cố sau khi đã hồi: chuyện gì xảy ra, người dùng mất gì (có số), vì sao, và làm gì để lần sau không
lặp lại hay phát hiện nhanh hơn. Mục đích là học từ sự cố, không tìm người có lỗi.

## Khi nào viết

- Mỗi cảnh báo `severity=page` đã cháy vì sự cố thật (không phải diễn tập đã báo trước).
- Mỗi buổi game day ([ADR-0020](../adr/0020-reliability-stage6.md) §13), dù xử lý suôn sẻ.
- Sự cố không có cảnh báo mà người dùng bị ảnh hưởng, hay mất dữ liệu, hay phải dựng lại stack hoặc cluster.
- Viết trong vòng vài ngày sau sự cố, khi log, trace và số đo còn trong thời gian giữ (Prometheus 30 ngày cả trên compose lẫn
  k3d; log và trace ngắn hơn).

## Không đổ lỗi

- Viết về hệ thống và quyết định, không về người: "cảnh báo không có link runbook nên mất 10 phút tìm lệnh", không phải "người
  trực không biết lệnh".
- Mỗi quyết định được đánh giá theo thông tin người đó có **lúc đó**, không theo điều biết được sau.
- Hành động sai là tín hiệu công cụ, runbook hay thiết kế còn thiếu: việc cần làm sửa chỗ đó.
- Không ghi email, token, mật khẩu, dữ liệu của người dùng; định danh bằng `user_id`, `video_id`, `trace_id`.

## Tên file

`docs/postmortems/<yymmdd>-<slug>.md`: ngày bắt đầu sự cố theo UTC, slug kebab-case ngắn tả sự cố, ví dụ
`261025-gameday-engagement-down.md`.

## Mẫu

Chép khối dưới đây vào file mới; mục nào chưa có dữ liệu thì ghi "chưa có" và vì sao, không bỏ mục.

```markdown
# <Tên sự cố>

- Ngày: <yyyy-mm-dd> (UTC)
- Trạng thái: Nháp | Đã duyệt
- Môi trường: compose `make up OBS=…` | cluster k3d `svp` (đường dev | GitOps) | cloud
- Cảnh báo: <alertname, severity> | không có
- Runbook đã dùng: <link> | không có

## Tóm tắt

Ba tới năm câu: chuyện gì xảy ra, người dùng mất gì, kéo dài bao lâu, nguyên nhân gốc, đã sửa gì.

## Tác động

Có số và nguồn của số:

| Chỉ số | Giá trị | Nguồn |
| --- | --- | --- |
| Thời gian người dùng bị ảnh hưởng | <phút> | dòng thời gian bên dưới |
| Request lỗi / tổng theo route | <số> / <số> | truy vấn Prometheus <PromQL>, tóm tắt k6 |
| Ngân sách lỗi đã tiêu | <% của 30 ngày> | `slo:period_error_budget_remaining:ratio` trước và sau |
| Dữ liệu mất hay sai | <số video, follow, lượt xem> | truy vấn, log |

## Dòng thời gian (UTC)

Mỗi mốc một dòng, có nguồn để người khác kiểm lại được (log, `startsAt` của Alertmanager, lịch sử Argo CD, `make gameday-mark`,
lệnh đã chạy). Mốc bắt buộc: bắt đầu (T0), phát hiện (T1, cảnh báo hay người thấy), chẩn đoán xong, giảm thiểu xong, hồi phục.

| Giờ (UTC) | Sự kiện | Nguồn |
| --- | --- | --- |
| hh:mm:ss | T0 … | … |

- Thời gian tới phát hiện (TTD = T1 − T0): <…>
- Thời gian tới giảm thiểu: <…>
- Thời gian tới hồi phục: <…>

## Phát hiện

Sự cố được phát hiện thế nào (cảnh báo nào, sau bao lâu, người hay máy); cảnh báo có đúng, có link runbook, có đủ thông tin
(target, instance) không; nên phát hiện sớm hơn bằng cách nào.

## Nguyên nhân gốc và yếu tố góp phần

- Nguyên nhân gốc: <điều mà nếu không có thì sự cố không xảy ra>, kèm bằng chứng (log, trace, truy vấn).
- Yếu tố góp phần: <điều làm sự cố dễ xảy ra, lan rộng hay kéo dài hơn>.

## Cái làm tốt, chưa tốt, may mắn

- Làm tốt: …
- Chưa tốt: … (runbook thiếu hay sai ở đâu, công cụ nào chậm)
- May mắn: … (điều đã giúp mà không phải do thiết kế: lần sau có thể không còn)

## Việc cần làm

Mỗi việc có người làm và hạn; việc sửa runbook ghi file và mục.

| Việc | Loại (phòng ngừa, phát hiện, giảm thiểu, runbook) | Người | Hạn | Trạng thái |
| --- | --- | --- | --- | --- |
| … | … | … | yyyy-mm-dd | mở |

## Chứng cứ

Link hay đường dẫn tới chứng cứ đã lưu: tóm tắt k6, truy vấn Prometheus kèm khoảng thời gian, `trace_id`, event GlitchTip, dòng
log (đã bỏ dữ liệu người dùng), JSON của diễn tập. File thô không commit thì ghi đường dẫn và nói nó nằm ngoài repo.
```

## Sau khi viết

- Sửa runbook mà sự cố cho thấy thiếu hay sai ([runbook](../runbooks/README.md)), trong cùng thay đổi hay ghi là việc cần làm.
- Quyết định thiết kế đổi vì sự cố thì viết ADR mới, postmortem dẫn tới ADR đó.
