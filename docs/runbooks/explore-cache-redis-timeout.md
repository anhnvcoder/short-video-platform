# Cache khám phá: Redis quá hạn 50 ms, `measure-explore-cache` chập chờn

- Không có cảnh báo riêng. Dấu hiệu: `make measure-explore-cache` đếm thừa lần đọc Postgres hay FAIL, log feed-service có WARN
  `read explore cache`, `FeedLatencyBudgetBurn` chỉ ở `/feed/explore`.
- Chuẩn bị biến `PROM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

feed-service cache trang đầu của feed khám phá ở Redis db 14 (TTL 5 s, singleflight cho mỗi khoá). Mỗi lệnh Redis có hạn
**50 ms**: quá hạn hay lỗi thì đọc Postgres, không báo lỗi cho client ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §3).
Hạn ngắn là có chủ đích: đường Redis phải thất bại nhanh để giữ p99 feed.

Người dùng: không thấy lỗi; request khám phá đọc Postgres nên chậm hơn một chút, Postgres nhận thêm truy vấn.

Sự cố đã gặp (roadmap, giai đoạn 3): ở trạng thái stack `core` có SDK telemetry bật mà không có Collector, 2 trong 7 lượt
`measure-explore-cache` FAIL vì một lần GET cache quá hạn 50 ms (WARN `read explore cache ... i/o timeout`), feed-service đọc
Postgres theo đường dự phòng nên đếm 2 lần đọc thay vì 1; hai trạng thái khác 0 trong 19 lượt. Nguyên nhân chưa kết luận. Từ
giai đoạn 4 bài đo đếm riêng lần đọc do Redis quá hạn: mỗi dòng `explore page loaded from database` có `cache=` (`miss`,
`timeout`, `error`) và `cache_write=`; đạt khi mọi lần đọc trừ một là do Redis quá hạn.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
# lý do mỗi lần đọc Postgres
make logs SVC=feed-service | grep 'explore page loaded from database'
make logs SVC=feed-service | grep 'read explore cache'
# Redis native: độ trễ (chỉ PING, Ctrl-C sau ~10 s)
redis-cli -h 127.0.0.1 -p 6379 -n 14 --latency
# p99 lệnh Redis theo service (ms) và số lệnh quá hạn trong 15 phút
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.99, sum by (le, service_name) (rate(db_client_connections_use_time_milliseconds_bucket{db_system="redis",type="command"}[5m])))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_name) (increase(db_client_connections_use_time_milliseconds_count{db_system="redis",error_type="context_timeout"}[15m]))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
# máy đang bận không
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream
```

k3d (Valkey trong cluster):

```sh
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=15m --tail=3000 | grep -E 'explore page loaded from database|read explore cache'
kubectl --context k3d-svp -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 14 --latency
kubectl --context k3d-svp top nodes
```

Dashboard `svp-use` → "Redis pool (redisotel)": "Connection use time p95", "Pool misses, waits and timeouts".

## Nguyên nhân thường gặp

1. **Máy hay Docker VM bận**: lệnh Redis đi từ container qua `host.docker.internal` tới Redis native; một khựng ngắn của VM là
   đủ vượt 50 ms. Hay gặp ở lượt đầu của buổi đo, khi máy chạy pin hay Low Power Mode.
2. **Redis native bận vì dự án khác** (Redis dùng chung, db 0, 5, 7 không phải của dự án này).
3. **Telemetry không có Collector** (stack `core` không `OBS`): exporter của mỗi service phân giải lại DNS `otelcol` và chờ hết
   hạn 5 s mỗi kỳ (roadmap giai đoạn 3); trùng thời điểm với lỗi ở trên nhưng chưa chứng minh là nguyên nhân.
4. **Thật sự có stampede** (lỗi code): lần đọc thừa có `cache=miss` mà không có `cache_write=timeout` ngay trước; bài đo FAIL
   đúng.

## Giảm thiểu

- Không có tác động tới người dùng cần giảm thiểu ngay.
- Đo lại khi máy yên: cắm sạc, tắt Low Power Mode, đóng bớt app; chạy bài đo trên `make up OBS=lgtm` hay `OBS=off`, không trên
  `core` có telemetry mà không Collector.
- **Không** nới hạn 50 ms tại chỗ, **không** `FLUSHDB` db 14. Bài đo tự xoá khoá `svp:feed:explore:*` ở db 14 trước khi đo.

## Khôi phục và xác nhận

```sh
make measure-explore-cache N=100     # compose; in tổng lần đọc, số do timeout/miss/error, p50/p95 hai sóng (LOCAL LAB ONLY)
```

Đạt: tổng ≥ 1 và tổng − `timeout` − số dòng sau SET quá hạn ≤ 1. Số tham chiếu (compose `core`, giai đoạn 3): sóng 1 p50 181,3 /
p95 203,0 ms, 1 lần đọc; sóng 2 p50 97,1 / p95 118,6 ms.

## Leo thang

- Lần đọc thừa không do Redis quá hạn (nguyên nhân 4): lỗi singleflight hay TTL; sửa code, thêm test.
- Lệnh Redis quá hạn khi máy yên, hay p99 lệnh Redis ≥ 25 ms dưới tải k6: theo quy tắc của
  [ADR-0020](../adr/0020-reliability-stage6.md) §4 ghi số và quyết lại hạn 50 ms ở giai đoạn 7 trên ElastiCache; không đổi code ở
  giai đoạn 6.

## Liên kết

- Dashboard: `svp-use` (Redis pool), `svp-red` (p99 `/feed/explore`).
- ADR: [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §1 (timeout Redis), §3 (cache khám phá);
  [ADR-0020](../adr/0020-reliability-stage6.md) §4 (đo p99 Redis dưới k6).
- Diễn tập tái hiện: `make measure-explore-cache N=100`; dưới tải `make load-local` (ADR-0020 §4).
