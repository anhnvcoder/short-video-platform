# RateLimitFallbackActive

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Gateway đếm rate limit bằng **bộ đếm dự phòng trong bộ nhớ** vì Redis lỗi hay quá hạn 50 ms: counter
`svp_ratelimit_decisions_total{store="fallback"}` tăng trong 1 phút (hay series mới xuất hiện đã > 0). Redis của gateway là db
10: compose dùng Redis native qua `host.docker.internal:6379`, k3d dùng Valkey `valkey.svp-data:6379`.

Theo bảng của [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §2 (và hai lớp thêm sau, khai cùng chỗ ở
`services/gateway/internal/ratelimit/ratelimit.go`):

- Lớp **đóng mềm** (`register`, `login-ip`, `login-email`, `upload`, `refresh`, `public`) đếm trong bộ nhớ của từng instance
  với ngưỡng bằng nửa: người dùng có thể nhận 429 `RATE_LIMITED` sớm hơn bình thường khi đăng ký, đăng nhập, làm mới phiên,
  tạo video, mở trang chia sẻ công khai.
- Lớp **mở** (`write`, `read`) cho qua không giới hạn; `view-once` chuyển tiếp mọi lượt xem, nên một lượt xem lặp trong 60 s
  có thể được đếm thêm (RL-3 tạm mất).
- Với nhiều instance gateway (k3d: 2 tới 4 pod) mỗi instance đếm riêng: giới hạn thật là ngưỡng × số instance.

Không có lỗi 5xx do việc này. Cùng lúc, cache khám phá của feed-service (Redis db 14) có thể cũng lỗi, khi đó mọi request
khám phá đọc Postgres: xem thêm [explore-cache-redis-timeout.md](explore-cache-redis-timeout.md).

## Kiểm tra nhanh (5 phút)

Compose:

```sh
# 1. Redis native trả lời không, độ trễ (Ctrl-C sau ~10 s; --latency chỉ gửi PING)
redis-cli -h 127.0.0.1 -p 6379 -n 10 ping
redis-cli -h 127.0.0.1 -p 6379 -n 10 --latency
# 2. Gateway nói gì: lỗi kết nối, quá hạn, hay tên miền .invalid (gateway còn cấu hình của diễn tập)
make logs SVC=gateway | grep 'rate limit store unavailable'
# 3. Tỉ lệ quyết định theo store trong 5 phút (redis so với fallback)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[5m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
# 4. Lệnh Redis của gateway quá hạn (error_type="context_timeout") hay lỗi khác
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (error_type) (increase(db_client_connections_use_time_milliseconds_count{service_name="gateway",db_system="redis"}[5m]))' | jq -c '.data.result[] | [.metric.error_type, .value[1]]'
```

k3d:

```sh
kubectl --context k3d-svp -n svp-data get pods -l app.kubernetes.io/name=valkey -o wide
kubectl --context k3d-svp -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 10 ping
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=gateway --since=15m --tail=2000 | grep 'rate limit store unavailable'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[5m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
```

Dashboard `svp-pipeline` → "Rate limit decisions by store (RL-2)"; `svp-use` → "Redis pool (redisotel)" (pool miss, chờ,
timeout, thời gian dùng kết nối p95).

## Nguyên nhân thường gặp

1. **Diễn tập để lại cấu hình** (compose): `make drill-rate-limit` và `make drill-obs-threats` dựng lại gateway với
   `SVP_GATEWAY_REDIS_URL` trỏ tên miền `.invalid` rồi trả về khi kết thúc; script bị ngắt giữa chừng thì gateway vẫn trỏ
   `.invalid`. Dấu hiệu: log bước 2 có `.invalid`, `redis-cli ping` vẫn `PONG`.
2. **Redis native không chạy hay không nhận kết nối** (compose): `ping` lỗi.
3. **Redis chậm hơn 50 ms**: Redis native dùng chung với dự án khác đang bận, máy bão hoà CPU (pin, Low Power Mode), Docker VM
   chậm. Dấu hiệu: `ping` được nhưng `--latency` có max cao, bước 4 có `context_timeout`.
4. **Valkey pod restart, chưa Ready, hay NetworkPolicy chặn** (k3d).

## Giảm thiểu

- Nguyên nhân 1: `make up OBS=lgtm` dựng lại gateway với `REDIS_URL` mặc định (biến diễn tập không nằm trong `.env`). Không
  đặt `SVP_GATEWAY_REDIS_URL` trong `.env`.
- Nguyên nhân 2, 3: Redis native là của cả máy. Bật lại theo cách nó được cài trên máy; **không** restart khi dự án khác đang
  dùng mà chưa hỏi, **không** `FLUSHDB`/`FLUSHALL`. Trong lúc chờ, stack vẫn chạy với giới hạn đóng mềm: không cần làm gì thêm
  cho người dùng.
- Nguyên nhân 4: `kubectl --context k3d-svp -n svp-data rollout restart deployment/valkey`. Valkey không lưu xuống đĩa
  (`--save ""`, `--appendonly no`): restart xoá mọi khoá rate limit, cache khám phá và **mọi phiên đăng nhập của web (db 9)**,
  người dùng web phải đăng nhập lại.

## Khôi phục và xác nhận

```sh
# fallback không còn tăng, redis tăng
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (store) (increase(svp_ratelimit_decisions_total{service_name="gateway"}[1m]))' | jq -c '.data.result[] | [.metric.store, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="RateLimitFallbackActive"' | jq -c '.[] | [.status.state, .startsAt]'
make smoke        # compose (LOCAL LAB ONLY: xoá khoá svp:gw:rl:register:* ở db 10)
make k8s-smoke    # k3d
```

Cảnh báo hết sau khoảng 1 phút không có quyết định fallback nào. Bộ đếm trong bộ nhớ không đồng bộ ngược về Redis: sau khi
hồi, người vừa bị giới hạn ở fallback được tính lại từ trạng thái Redis.

## Leo thang

- Redis native không lên được, hay chậm vì dự án khác: báo chủ của dự án đó (db 0, 5, 7 không phải của dự án này); stack chạy
  tiếp ở chế độ đóng mềm, ghi lại thời gian cho postmortem.
- Fallback kéo dài > 30 phút trên môi trường có người dùng thật: lớp mở (`write`, `read`) không còn giới hạn, đây là rủi ro
  lạm dụng (RL-2 của [threat model](../threat-model.md)); ở lab không có người dùng ngoài nên chỉ ghi nhận.
- Lệnh Redis quá hạn lặp lại khi máy không bận: ghi số `context_timeout` và p99 vào đánh giá hạn 50 ms của
  [ADR-0020](../adr/0020-reliability-stage6.md) §4.

## Liên kết

- Dashboard: `svp-pipeline` (Rate limit decisions by store), `svp-use` (Redis pool).
- ADR: [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §1–2, [ADR-0011](../adr/0011-observability-stage3.md)
  §8, [ADR-0020](../adr/0020-reliability-stage6.md) §4.
- Diễn tập tái hiện: `make drill-rate-limit` (Redis không tới được: login vẫn bị giới hạn bằng bộ đếm dự phòng, feed, like,
  lượt xem vẫn chạy); `make drill-obs-threats` dòng RL-2 (metric `store="fallback"` > 0 và cảnh báo này trong 4 phút, cần
  `make up OBS=lgtm`).
