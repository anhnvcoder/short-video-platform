---
env: compose
deployment: none
started_at: 2026-10-24T07:24:49Z
restored_at: 2026-10-24T07:27:53Z
fix_commits: []
---
# Game day: engagement-service dừng dưới tải, like và lượt xem trả 503

- Ngày: 2026-10-24 (UTC)
- Trạng thái: Nháp
- Môi trường: compose `make up OBS=lgtm`, tải nền k6 profile `local` (`make gameday`)
- Cảnh báo: `CircuitBreakerOpen` (`target="engagement-service"`), `severity=page`
- Runbook đã dùng: [circuit-breaker-open.md](../runbooks/circuit-breaker-open.md)

## Tóm tắt

Buổi game day đầu tiên ([ADR-0020](../adr/0020-reliability-stage6.md) §13): dưới tải k6 ~23 request/s, engagement-service bị
dừng lúc 07:24:49 UTC. Trong 152 s, mọi request like và ghi lượt xem trả 503 (450 request lỗi theo k6), feed vẫn 200 không lỗi.
Cảnh báo page cháy sau 75 s; người trực đi theo runbook, chẩn đoán xong sau 141 s, bật lại service, breaker của gateway tự đóng
4 s sau đó. Nguyên nhân gốc là service bị dừng (sự cố tiêm có chủ ý). Runbook dẫn đúng tới nguyên nhân nhưng thiếu năm chỗ, đã
sửa; một cảnh báo page khác (`RateLimitFallbackActive`) cháy vì Redis quá hạn dưới cùng tải và chặn hai lượt tiêm sau đó.

## Tác động

Cửa sổ đo: T0 (07:24:49) tới mốc `recovered` (07:27:53), 184 s; tác động thật nằm trong 152 s đầu (tới khi breaker đóng).

| Chỉ số | Giá trị | Nguồn |
| --- | --- | --- |
| Thời gian người dùng bị ảnh hưởng | 152 s (07:24:49 → 07:27:21,7) | `compose stop` lúc T0; log gateway `"to":"closed"` |
| Like (`PUT /videos/{video_id}/like`) lỗi / tổng | 150 / 183 (k6); 158 / 181 (gateway) | `report.txt` của buổi (k6 REST API); Prometheus bên dưới |
| Ghi lượt xem (`POST /videos/{video_id}/views`) lỗi / tổng | 300 / 365 (k6); 316 / 361 (gateway) | như trên |
| Feed explore, following, `POST /videos`, web `/`, `/v/[id]`, `/login` lỗi | 0 / 3 875 (k6) | `report.txt` |
| 429 | 0 | `report.txt` (`svp_rate_limited`) |
| Request chậm trước khi breaker mở | ~11 request explore > 100 ms trong phút đầu (trước đó 0); ~3 like > 1 s | Prometheus, bucket `le="0.1"`, `le="1"` |
| Ngân sách lỗi đã tiêu | 0: like và lượt xem không có SLO; `feed-availability`, `upload-init-availability`, `web-availability` còn 1 trước và sau | `slo:period_error_budget_remaining:ratio` lúc T0 và T0 + 300 s |
| Dữ liệu mất hay sai | Like và lượt xem của các request 503 không được ghi (k6 không thử lại); dữ liệu đã ghi không mất (service dừng êm) | log `grpc server stopped`, mã thoát 0 |

- Số k6 là hiệu của bộ đếm theo route giữa hai ảnh chụp (T0 và `recovered`); "lỗi" là 5xx hay lỗi kết nối
  (`http_req_failed`). Số gateway là `increase(http_server_request_duration_seconds_count{service_name="gateway"}[184s])` lúc
  07:27:53, có ngoại suy nên lệch k6 vài phần trăm.
- Mỗi giây có 1 like và 2 lượt xem, nên 150 và 300 là **mọi** like và lượt xem trong 152 s: tỷ lệ lỗi của hai route này trong
  sự cố là 100 %.
- Trước khi breaker mở (5 s đầu) gateway còn gọi engagement-service: like chờ tới hạn 3 s (p99 like của k6 cả lượt 2 544 ms),
  feed chờ `GetStats` tới 100 ms (p99 explore của k6 cả lượt 105,9 ms, lượt `make load-local` không sự cố là 17,1 ms). Từ lúc
  breaker mở, 503 trả ngay.
- Feed trả item không có `stats` theo thiết kế ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §4,
  kiểm bằng `make drill-engagement-down`); lượt này k6 không kiểm nội dung response.

## Dòng thời gian (UTC)

| Giờ (UTC) | Sự kiện | Nguồn |
| --- | --- | --- |
| 07:22:13 | `make gameday` bắt đầu: không có page nào đang cháy, Telegram có receiver | `timeline.tsv` |
| 07:22:19 | Tải k6 profile `local` chạy (20 user, 5 phiên web, 50 video `READY`) | `timeline.tsv`, `k6.log` |
| 07:24:49 | Trạng thái ổn định sau 30 s lên tải và 120 s: 0 request lỗi, không page | `timeline.tsv` |
| 07:24:49 | **T0**: dừng container engagement-service | `timeline.tsv` (`compose stop`) |
| 07:24:50,1 | engagement-service log `grpc server stopping`, `grpc server stopped` | log engagement-service |
| 07:24:54,8 | Gateway: breaker tới engagement-service `closed` → `open` | log gateway |
| 07:26:04,4 | **T1**: `CircuitBreakerOpen` (`target="engagement-service"`) `startsAt`; 1 thông báo Telegram | Alertmanager; `alertmanager_notifications_total{integration="telegram"}` |
| 07:26:14 | Người trực chạy bước 1 của runbook | lệnh đã chạy |
| 07:27:10 | **Chẩn đoán xong**: container `Exited (0)`, log cuối là dừng êm → nguyên nhân 1 của runbook | `make gameday-mark M=diagnosed` |
| 07:27:15 | `dc start engagement-service` (mục Giảm thiểu của runbook) | lệnh đã chạy |
| 07:27:17 | Container engagement-service chạy lại | output của `dc start` |
| 07:27:21,7 | Gateway: breaker `half-open` → `closed`; hết tác động | log gateway |
| 07:27:27 | Prometheus: `max(svp_breaker_state{target="engagement-service"})` = 0 | `timeline.tsv` (tự ghi) |
| 07:27:32 | **Giảm thiểu xong** (người trực xác nhận breaker 0) | `make gameday-mark M=mitigated` |
| 07:27:38 | Cảnh báo hết trong Alertmanager | `timeline.tsv` (tự ghi) |
| 07:27:48 | `make smoke` qua (mục Khôi phục của runbook) | output `make smoke` |
| 07:27:53 | **Hồi phục** | `make gameday-mark M=recovered` |
| 07:27:58 | `make gameday-end`: stack chạy lại đủ, tải dừng | `timeline.tsv`, `make ps` |

- Thời gian tới phát hiện (TTD = T1 − T0): **75 s**.
- Thời gian tới giảm thiểu: **152 s** theo log gateway (hết tác động); 163 s theo mốc người trực. Tính từ T1: 77 s.
- Thời gian tới hồi phục: **184 s** (mốc `recovered`, sau `make smoke`).

## Phát hiện

- Máy phát hiện: `CircuitBreakerOpen` cháy 75 s sau T0, tức 70 s sau khi breaker mở. Phần lớn là điều kiện của rule (mọi mẫu
  trong 80 s > 0, ít nhất 5 mẫu cách 15 s, nên tối thiểu ~60 s) cộng chu kỳ scrape và đánh giá. Cố ý: một lần mở 5 s rồi đóng
  không gọi người dậy.
- Cảnh báo có đủ thông tin để bắt đầu: nhãn `target` và `instance`, annotation `runbook_url`. Alertmanager gửi 1 thông báo
  Telegram; nội dung tin (có link runbook không, ADR-0020 §12) chưa kiểm ở buổi này.
- Người dùng mất like và lượt xem ngay từ T0, nhưng không SLO nào đo hai route này: sự cố chỉ được thấy qua breaker. Với tác động
  một phần đã thiết kế (feed vẫn chạy), như vậy đủ; nếu like/lượt xem trở thành luồng chính thì cần SLO riêng.

## Nguyên nhân gốc và yếu tố góp phần

- Nguyên nhân gốc: container engagement-service bị dừng (`compose stop`, sự cố tiêm của game day). Bằng chứng: mã thoát 0, log
  cuối `grpc server stopping`/`grpc server stopped` lúc 07:24:50, gateway nhận `UNAVAILABLE` và `DEADLINE_EXCEEDED` từ mọi
  method của engagement-service.
- Yếu tố góp phần: không có trong hệ thống; thiết kế giới hạn tác động ở like và lượt xem (breaker, hạn 100 ms của `GetStats`).
  Kéo dài: 5 s đầu trước khi breaker mở, request like chờ tới 3 s.

## Cái làm tốt, chưa tốt, may mắn

- Làm tốt:
  - Cảnh báo đúng target, có link runbook; runbook dẫn tới nguyên nhân trong 66 s kể từ T1, bảng tác động của runbook khớp
    đúng số đo (like, lượt xem 503; feed 200).
  - Breaker tự đóng 4 s sau khi service lên, không phải restart gateway; feed không lỗi request nào.
  - `make gameday` trả stack về và ghi đủ mốc; mốc tự ghi (service chạy, breaker 0, cảnh báo hết) cho nguồn kiểm lại mốc của
    người trực.
- Chưa tốt (runbook, đã sửa ở [circuit-breaker-open.md](../runbooks/circuit-breaker-open.md) và
  [README](../runbooks/README.md)):
  - Hàm `dc` của mục "Chuẩn bị trong terminal" không định nghĩa được khi shell đã có alias `dc` (zsh: `defining function based
    on alias`); người trực mất một lượt lệnh để nhận ra.
  - Bước 2 dùng `make ps`: container đích `Exited (0)` lẫn giữa các container init cũng `Exited (0)`; runbook không nói mã thoát
    0 cùng log dừng êm nghĩa là service bị dừng chứ không crash.
  - Bước 3 dùng `make logs SVC=gateway` (200 dòng cuối): dưới tải đó chỉ là ~5 s log, không có lần breaker mở đầu tiên, tức
    mất mốc bắt đầu cho postmortem.
  - Bước 6 ghi "UNAVAILABLE: chết; DEADLINE_EXCEEDED: chậm", nhưng service chết cho cả hai (`GetStats` hết hạn 100 ms trong lúc
    gRPC còn nối lại); truy vấn in cả series bằng 0.
  - Không có bước đo tác động tới người dùng (5xx theo route), dù dashboard `svp-red` có panel "HTTP 5xx ratio by route".
  - Runbook không nói vài giây đầu trước khi breaker mở request chậm tới 3 s.
- Chưa tốt (ngoài runbook):
  - Hai lượt `make gameday` sau buổi này (thử đường thoát của script) bị chặn trước T0 vì `RateLimitFallbackActive` (page) cháy
    trong lúc chờ ổn định: gateway log `rate limit store unavailable, using fallback` với `i/o timeout` tới
    `host.docker.internal:6379` vài lần mỗi phút dưới tải k6 `local`, và rule page khi có **một** quyết định dự phòng trong 1
    phút. Script làm đúng (không tiêm khi đang có page), nhưng một page ồn dưới tải bình thường làm hỏng game day và sẽ đánh
    thức người trực thật (Alertmanager có receiver Telegram cho mọi page).
  - Khi thử đường thoát, một tín hiệu thứ hai tới giữa lúc dọn làm script dừng giữa chừng, container k6 còn chạy; đã sửa (bỏ qua
    INT/TERM trong lúc dọn) và thử lại bằng hai SIGTERM liền: stack về, k6 dừng.
- May mắn:
  - Lượt chính không gặp `RateLimitFallbackActive`; hai lượt sau đều gặp. Game day đầu có thể đã không tiêm được.
  - Người trực biết trước sự cố được tiêm (cùng người dựng buổi): thời gian chẩn đoán đo được là cận dưới. Các lệnh chạy đúng
    theo runbook và chỗ thiếu ghi từ những gì runbook cho thấy, nhưng game day "mù" (người khác chọn sự cố) mới đo được thật.

## Việc cần làm

| Việc | Loại (phòng ngừa, phát hiện, giảm thiểu, runbook) | Người | Hạn | Trạng thái |
| --- | --- | --- | --- | --- |
| `circuit-breaker-open.md`: bước 2, 3, 4 gọi riêng target và log theo thời gian, cách đọc mã thoát và `DEADLINE_EXCEEDED`, bước 7 tác động, vài giây đầu chậm, mốc đóng breaker từ log | runbook | người học duyệt | 2026-10-24 | xong |
| `docs/runbooks/README.md`: `unalias dc` trước khi định nghĩa hàm `dc` | runbook | người học duyệt | 2026-10-24 | xong |
| `make gameday` bỏ qua INT/TERM trong lúc dọn | giảm thiểu | người học duyệt | 2026-10-24 | xong |
| Xem lại ngưỡng `RateLimitFallbackActive` (một quyết định dự phòng/phút là page; đề xuất tỷ lệ hay số phút liên tiếp), viết ADR nếu đổi | phát hiện | người học | 2026-10-31 | mở |
| Tìm nguyên nhân `i/o timeout` 50 ms từ gateway tới Redis native qua `host.docker.internal` dưới tải k6 `local` (lượt `make load-local` trước đó p99 5 ms, không quá hạn) | phòng ngừa | người học | 2026-10-31 | mở |
| Kiểm tin Telegram của page có `runbook_url` (ADR-0020 §12), sửa template nếu thiếu | phát hiện | người học | 2026-10-31 | mở |
| Game day mù: người khác hay script chọn ngẫu nhiên sự cố và target, người trực không biết trước | quy trình | người học | giai đoạn 7 | mở |
| Ghi `make gameday`, `gameday-mark`, `gameday-end` vào mục Kiểm tra của `CLAUDE.md` | runbook | người học | 2026-10-31 | mở |

## Chứng cứ

- Thư mục của buổi, gitignore, nằm ngoài repo: `.k6/gameday-20261024T072213Z/` (`report.txt`: dòng thời gian, thời lượng, bảng
  k6 và gateway theo route; `timeline.tsv`; `k6.log` và `summary.json` cả lượt; `k6-T0.json`, `k6-diagnosed.json`,
  `k6-mitigated.json`, `k6-recovered.json`, `k6-end.json`: bộ đếm của k6 lúc mỗi mốc). Hai lượt bị chặn:
  `.k6/gameday-20261024T072846Z/`, `.k6/gameday-20261024T073219Z/`.
- Prometheus (qua datasource proxy của Grafana), lúc 07:27:53:
  `sum by (http_route, http_response_status_code) (increase(http_server_request_duration_seconds_count{service_name="gateway"}[184s]))`;
  lúc 07:25:49: `sum by (http_route) (increase(http_server_request_duration_seconds_bucket{service_name="gateway",http_route=~"/feed/.*",le="+Inf"}[60s])) - sum by (http_route) (increase(http_server_request_duration_seconds_bucket{service_name="gateway",http_route=~"/feed/.*",le="0.1"}[60s]))`;
  lúc 07:27:21: `sum by (rpc_method, rpc_response_status_code) (increase(rpc_client_call_duration_seconds_count{service_name="gateway",rpc_method=~"svp.engagement.*"}[152s]))`
  (GetStats: 21 `UNAVAILABLE`, 9 `DEADLINE_EXCEEDED`; Like: 3 `UNAVAILABLE`, 2 `DEADLINE_EXCEEDED`; RecordView: 1 `UNAVAILABLE`, 2 `DEADLINE_EXCEEDED`; còn lại
  là 503 do breaker mở, không gọi mạng).
- Log gateway: `circuit breaker state changed` lúc 07:24:54,8 (`closed` → `open`) và 07:27:21,7 (`half-open` → `closed`), 41
  dòng đổi trạng thái trong sự cố; log `rate limit store unavailable, using fallback` lúc 07:29:49, 07:30:01, 07:30:52,
  07:31:23 (lượt bị chặn).
- Alertmanager: `CircuitBreakerOpen` `startsAt` 2026-10-24T07:26:04.428Z; `RateLimitFallbackActive` `startsAt`
  2026-10-24T07:30:04.428Z.
- Máy: MacBook Apple M2 16 GB, cắm sạc, Low Power Mode tắt, không chạy k3d. k6 cả lượt (gồm lúc lên tải và sau hồi phục) rơi 4
  iteration (`dropped_iterations`).
