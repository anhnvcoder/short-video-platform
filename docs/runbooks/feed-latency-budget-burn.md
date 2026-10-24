# FeedLatencyBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO `feed-latency` của
  `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

SLO: 99% request `GET /feed/following` và `GET /feed/explore` ở gateway trả lời trong bucket 150 ms (NFR p99 150 ms) trong 30
ngày; ngân sách 1% request chậm. Page cháy khi hơn **14,4%** request chậm hơn 150 ms trên cả 1 giờ và 5 phút, hoặc hơn **6%**
trên cả 6 giờ và 30 phút ([ADR-0011](../adr/0011-observability-stage3.md) §8). Request 5xx cũng được tính theo thời gian của
nó; lỗi thuần thì xem [feed-availability-budget-burn.md](feed-availability-budget-burn.md).

Người dùng: feed mở chậm, cuộn chờ trang sau. Không mất dữ liệu.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="FeedLatencyBudgetBurn"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
# p99 theo route (giây)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.99, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket{service_name="gateway",http_request_method="GET",http_route=~"/feed/following|/feed/explore"}[5m])))' | jq -c '.data.result[] | [.metric.http_route, .value[1]]'
# phần nào chậm: gRPC gateway gọi ra theo method (GetFollowingFeed, GetExploreFeed, GetStats)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.99, sum by (le, rpc_method) (rate(rpc_client_call_duration_seconds_bucket{service_name="gateway"}[5m])))' | jq -c '.data.result[] | [.metric.rpc_method, .value[1]]'
# Redis của feed-service (cache khám phá): thời gian dùng kết nối p99 (ms) và số lệnh quá hạn
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.99, sum by (le, service_name) (rate(db_client_connections_use_time_milliseconds_bucket{db_system="redis",type="command"}[5m])))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_name) (increase(db_client_connections_use_time_milliseconds_count{db_system="redis",error_type="context_timeout"}[15m]))' | jq -c '.data.result[] | [.metric.service_name, .value[1]]'
# số lần khám phá đọc Postgres (cache hụt hay Redis quá hạn)
make logs SVC=feed-service | grep -c 'explore page loaded from database'
# CPU, RAM các container
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream
```

k3d: các truy vấn Prometheus như trên, rồi

```sh
kubectl --context k3d-svp top nodes
kubectl --context k3d-svp -n svp top pods
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=media-worker      # transcode đang chiếm CPU node?
```

Trace chậm: dashboard `svp-red` → "HTTP p99 by route (feed NFR 150 ms)", bấm exemplar để mở trace trong Tempo và xem span nào
dài. `svp-use`: pool Postgres (chờ kết nối), pool Redis.

## Nguyên nhân thường gặp

1. **Máy hay node bão hoà CPU**: media-worker đang transcode (2 vCPU mỗi worker), máy chạy pin, Low Power Mode, giới hạn nhiệt;
   p99 mọi route cùng tăng. Trên k3d xem [liveness-timeout-cpu-saturation.md](liveness-timeout-cpu-saturation.md).
2. **Cache khám phá hụt hay Redis quá hạn 50 ms**: mỗi request khám phá đọc Postgres
   ([explore-cache-redis-timeout.md](explore-cache-redis-timeout.md)); chỉ `/feed/explore` chậm.
3. **`GetStats` của engagement-service hay `GetProfiles` của user-service chậm**: gateway gọi song song hai lời gọi này, mỗi
   lời gọi chờ tối đa 100 ms rồi trả feed thiếu `stats` hay `author`; một trong hai chậm đều làm mọi trang feed chậm thêm tới
   100 ms.
4. **Postgres chậm** (`svp_feed`): truy vấn timeline, pool chờ kết nối.
5. **Lần đầu sau khởi động**: kết nối gRPC lười, cache trống; lượt đầu của mỗi buổi đo luôn chậm nhất (sóng 1 p50 141–238 ms
   so với 47–106 ms các lượt sau, `measure-explore-cache` giai đoạn 3, roadmap).

## Giảm thiểu

- CPU: dừng việc nặng không cần thiết trên máy (build, test song song, app khác), cắm sạc, tắt Low Power Mode. Không dừng
  media-worker khi có video đang chờ; chờ hàng đợi rút.
- Redis: theo [explore-cache-redis-timeout.md](explore-cache-redis-timeout.md); **không** nới hạn 50 ms tại chỗ (quyết định
  của [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md), xem lại theo [ADR-0020](../adr/0020-reliability-stage6.md) §4).
- engagement-service chậm: kiểm nó như [circuit-breaker-open.md](circuit-breaker-open.md); `GetStats` quá hạn không mở breaker.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=slo:sli_error:ratio_rate5m{sloth_slo="feed-latency"}' | jq -c '.data.result[] | .value[1]'
make measure-explore-cache N=100    # compose: p50/p95 hai sóng, số lần đọc Postgres (LOCAL LAB ONLY: xoá svp:feed:explore:* ở db 14)
```

Tỉ lệ request chậm 5 phút dưới 1% và page hết trong tối đa ~30 phút. Số tham chiếu `measure-explore-cache` (compose `core`,
giai đoạn 3): sóng 1 p50 181,3 / p95 203,0 ms, sóng 2 p50 97,1 / p95 118,6 ms.

## Leo thang

- p99 cao kéo dài khi máy yên, Redis và Postgres khoẻ: lấy profile CPU của gateway và feed-service ở Pyroscope (`make up
  OBS=lgtm`), mở postmortem.
- Chậm chỉ khi có tải: ghi số và xem lại bằng k6 (`make load-local`, [ADR-0020](../adr/0020-reliability-stage6.md) §2);
  số đo năng lực thật để giai đoạn 7 trên cluster cloud.

## Liên kết

- Dashboard: `svp-slo`, `svp-red`, `svp-use`.
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8, [ADR-0009](../adr/0009-engagement-feed-stage2b.md) (feed, hạn
  `GetStats` 100 ms), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §3–4.
- Diễn tập, đo: `make measure-explore-cache N=100`; tải theo SLO `make load-local` (k6, ADR-0020 §2). Chưa có diễn tập làm cảnh
  báo này cháy.
