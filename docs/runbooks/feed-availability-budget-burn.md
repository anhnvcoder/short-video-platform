# FeedAvailabilityBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO `feed-availability`
  của `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

SLO: 99,9% request `GET /feed/following` và `GET /feed/explore` ở gateway không trả 5xx trong 30 ngày (ngân sách lỗi 0,1%). Page
cháy khi tỉ lệ 5xx vượt **1,44%** (14,4 × ngân sách) trên cả cửa sổ 1 giờ và 5 phút, hoặc **0,6%** (6 ×) trên cả 6 giờ và 30
phút: với tốc độ đó ngân sách 30 ngày hết trong khoảng 2 ngày (14,4 ×) hay 5 ngày (6 ×). Ticket là 3 × (1 ngày và 2 giờ) và
1 × (3 ngày và 6 giờ) ([ADR-0011](../adr/0011-observability-stage3.md) §8).

Người dùng: mở ứng dụng hay web thấy feed lỗi, không cuộn được. Đăng nhập, upload, xem video theo link vẫn có thể chạy.

Page tự hết khi cửa sổ ngắn (5 phút, 30 phút) xuống dưới ngưỡng, tức tối đa ~30 phút sau khi hết lỗi; ticket còn cháy hàng giờ
tới vài ngày.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="FeedAvailabilityBudgetBurn"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
# tỉ lệ lỗi hiện tại (5 phút, 1 giờ) và ngân sách 30 ngày còn lại
curl -sG "$PROM/api/v1/query" --data-urlencode 'query={__name__=~"slo:sli_error:ratio_rate(5m|1h)|slo:period_error_budget_remaining:ratio",sloth_slo="feed-availability"}' | jq -c '.data.result[] | [.metric.__name__, .value[1]]'
# 5xx theo route và mã: 503 (breaker, service chết) hay 504/500
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (http_route, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name="gateway",http_request_method="GET",http_route=~"/feed/following|/feed/explore",http_response_status_code=~"5.."}[5m]))' | jq -c '.data.result[] | [.metric.http_route, .metric.http_response_status_code, .value[1]]'
make ps
# breaker tới feed-service, lỗi gRPC
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="CircuitBreakerOpen"' | jq -c '.[] | [.labels.target, .status.state]'
make logs SVC=feed-service
```

k3d: hai truy vấn Prometheus như trên, rồi

```sh
kubectl --context k3d-svp -n svp get pods -l 'app.kubernetes.io/name in (gateway,feed-service)' -o wide
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=15m --tail=500
kubectl --context k3d-svp -n svp-data get cluster svp-pg
kubectl --context k3d-svp -n svp get rollout gateway      # canary đang chạy hay vừa abort
```

Trace của request lỗi: dashboard `svp-red` → "HTTP latency p50 / p95 / p99 (all routes, exemplars)" (bấm exemplar) hay
"Recent gateway traces"; log cùng `trace_id` ở Loki, lỗi ở GlitchTip `http://127.0.0.1:8000` (k3d: `make k8s-ui-glitchtip`).
Dashboard `svp-slo` cho ngân sách và burn rate theo cửa sổ.

## Nguyên nhân thường gặp

1. **feed-service chết hay không tới được**: 503, `CircuitBreakerOpen` target `feed-service` cháy cùng
   ([circuit-breaker-open.md](circuit-breaker-open.md)).
2. **Postgres `svp_feed` lỗi**: feed-service trả lỗi, gateway 5xx; log feed-service có lỗi Postgres. Redis lỗi **không** làm
   feed 5xx (cache khám phá có đường lui về Postgres).
3. **Bản phát hành mới của gateway hay feed-service lỗi**: lỗi bắt đầu ngay sau deploy; trên k3d canary của gateway có thể đã
   abort ([ADR-0014](../adr/0014-kubernetes-local-stage4.md)).
4. **Quá hạn 3 s**: feed-service chậm (504), node k3d bão hoà CPU.

## Giảm thiểu

- feed-service chết: compose `make up OBS=lgtm` hay `dc start feed-service`; k3d
  `kubectl --context k3d-svp -n svp rollout restart deployment/feed-service`.
- Lỗi sau deploy: quay về bản trước (compose: checkout bản trước, `make up OBS=lgtm`; GitOps: PR revert commit promote). Canary
  của gateway đang chạy với lỗi thì Argo Rollouts tự abort theo phân tích; không promote tay.
- Postgres: compose dùng Postgres native chung với dự án khác (không restart, báo chủ máy); k3d xem trạng thái Cluster `svp-pg`.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=slo:sli_error:ratio_rate5m{sloth_slo="feed-availability"}' | jq -c '.data.result[] | .value[1]'
make smoke        # compose: feed following, explore (LOCAL LAB ONLY)
make k8s-smoke    # k3d
```

Tỉ lệ lỗi 5 phút về 0 (hay không có series khi không có traffic); page hết trong tối đa ~30 phút. Ghi ngân sách còn lại
(`slo:period_error_budget_remaining:ratio`) vào postmortem.

## Leo thang

- Cảnh báo page của SLO này luôn mở postmortem (tác động: số request 5xx, thời gian).
- Không thấy nguyên nhân sau 15 phút và lỗi còn: dựng lại service liên quan (compose `make down && make up OBS=lgtm`, giữ volume),
  ghi lại trước khi làm vì mất trạng thái để điều tra.
- Ngân sách 30 ngày âm: dự án chưa có chính sách ngân sách lỗi thành văn; ghi số vào postmortem để người học quyết có dừng việc
  mới để sửa độ tin cậy hay không.

## Liên kết

- Dashboard: `svp-slo`, `svp-red`.
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8 (SLO, burn rate), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md)
  §3–4 (cache khám phá, breaker).
- Diễn tập tái hiện: `make drill-alert-to-sentry` (compose `OBS=lgtm`: tắt feed-service, đo từ lúc cảnh báo page này có trong
  Alertmanager tới khi trace, log và event GlitchTip cùng `trace_id` đều tìm thấy, đạt khi dưới 5 phút).
