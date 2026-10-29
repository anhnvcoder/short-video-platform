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

Front matter YAML ở đầu file là dữ liệu máy đọc cho DORA metrics ([ADR-0028](../adr/0028-dora-metrics.md) §5, §7):
`deploy/ci/dora.sh` đọc nó, không đọc phần còn lại của postmortem.

- `env`: `stg`, `prd`, `compose` hay `k3d`, môi trường xảy ra sự cố.
- `deployment`: revision (40 hex) của `svp-gitops` của deployment gây ra sự cố, hay `none` khi sự cố không do triển khai nào
  (game day, sự cố tiêm có chủ ý, lỗi hạ tầng). Postmortem `env: stg` có `deployment` là 40 hex đánh dấu deployment đầu tiên
  của revision đó là thất bại (change fail rate); postmortem khác chỉ được liệt kê dưới "sự cố không do triển khai".
- `started_at`, `restored_at`: T0 và mốc hồi phục, RFC 3339 UTC (`2026-10-24T07:24:49Z`), lấy đúng từ dòng thời gian có nguồn
  bên dưới; là mốc của failed deployment recovery time. Chưa hồi phục thì để trống `restored_at:`.
- `fix_commits`: danh sách `<owner/repo>@<40 hex>` các commit đã sửa, của repo nào cũng được (`[]` khi không có). Deployment
  đầu tiên chứa một commit trong đó được tính là rework.
- Sai dạng (thiếu front matter, giá trị lạ) thì `dora.sh` bỏ postmortem đó và in cảnh báo, không đoán.

```markdown
---
env: stg                    # stg | prd | compose | k3d
deployment: <40 hex>        # revision of svp-gitops of the deployment that caused it, or none
started_at: <RFC 3339 UTC>  # T0, same source as the timeline
restored_at: <RFC 3339 UTC> # recovery, same source as the timeline
fix_commits: []             # <repository>@<40 hex> of the commits that fixed it, either repository
---
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
