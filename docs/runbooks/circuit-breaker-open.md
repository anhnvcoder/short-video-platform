# CircuitBreakerOpen

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`, cảnh báo theo từng instance gateway và
  từng `target`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Breaker của **một instance gateway** tới service đích `target` (`user-service`, `video-service`, `feed-service`,
`engagement-service`) không đóng ở **mọi mẫu trong 1 phút** (≥ 5 mẫu, `svp_breaker_state` 1 = half-open, 2 = open). Breaker
mở khi 5 lời gọi lỗi liên tiếp, hoặc ≥ 20 lời gọi trong 10 s với ≥ 50% lỗi; "lỗi" chỉ là `UNAVAILABLE` mức kết nối (service
chết, không tới được) và `DEADLINE_EXCEEDED` (hạn 3 s). Mở 5 s rồi half-open cho 1 lời gọi thử
([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §4). Lúc mở, gateway trả **503 ngay**, không gọi mạng.

Lỗi phụ thuộc của service đích (`DEPENDENCY_UNAVAILABLE`, ví dụ Redpanda chết khi ghi lượt xem, MinIO chết khi
`CompleteUpload`) **không** mở breaker: service còn sống thì breaker đóng, chỉ method đó trả 503.

| `target` | Người dùng thấy | Vẫn chạy |
| --- | --- | --- |
| `engagement-service` | Like, unlike, ghi lượt xem trả 503 nhanh (< 100 ms) | Feed 200 nhưng không có `stats` (lượt like, lượt xem) |
| `feed-service` | Feed following và khám phá 503; `FeedAvailabilityBudgetBurn` sẽ cháy theo | Đăng nhập, upload, xem video theo link |
| `video-service` | Tạo video, hoàn tất upload, đọc video, danh sách video 503; `UploadInitAvailabilityBudgetBurn` cháy theo | Feed (đọc từ feed-service) |
| `user-service` | Đăng ký, đăng nhập, refresh, follow, hồ sơ 503 | Request có access token còn hạn tới feed, video, like (gateway tự kiểm JWT) |

`/readyz` của gateway lỗi khi `user-service`, `video-service` hay `feed-service` không trả lời health check (không khi
`engagement-service` tắt: feed vẫn chạy không `stats`). Probe readiness của gateway trên k3d dùng `/healthz`, nên gateway vẫn
nhận traffic.

Trước khi breaker mở (vài giây đầu: game day đo 5 s từ lúc dừng engagement-service tới log `closed` → `open`), gateway vẫn
gọi target: like, xem chờ tới hạn 3 s (game day: vài like 1–2,5 s), feed chờ `GetStats` tới hạn 100 ms rồi trả không
`stats`. Sau đó mới là 503 nhanh.

Cảnh báo chỉ cháy khi có traffic chạm `target`: không ai gọi thì breaker không đổi trạng thái. Cảnh báo hết khi có một mẫu
`svp_breaker_state` = 0, hoặc sau tối đa 45 s khi instance gateway đó ngừng gửi metric (gateway bị thay: đó là mất
telemetry, không phải đã hồi).

## Kiểm tra nhanh (5 phút)

Compose:

```sh
# 1. Target nào, instance nào, từ lúc nào; đặt T theo cột target cho các bước sau
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="CircuitBreakerOpen"' | jq -c '.[] | [.labels.target, .labels.instance, .status.state, .startsAt]'
# 2. Container của target còn chạy không (STATUS, health); `make ps` lẫn nhiều container init `Exited (0)` nên gọi riêng target
T=engagement-service                    # thay bằng target của bước 1
dc ps -a "$T"
# 3. Gateway thấy breaker đổi trạng thái lúc nào (from/to); `make logs` chỉ lấy 200 dòng cuối, dưới tải chừng vài giây log
#    của gateway, nên lần mở đầu tiên không có trong đó: đọc theo thời gian
dc logs --no-log-prefix --since 15m gateway | grep 'circuit breaker state changed' | head -n 3
# 4. Log của target: dừng, panic, lỗi kết nối Postgres
dc logs --no-log-prefix --tail 20 "$T"
# 5. Trạng thái breaker hiện tại mọi instance (0 đóng, 1 half-open, 2 mở)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=svp_breaker_state{service_name="gateway"}' | jq -c '.data.result[] | [.metric.target, .value[1]]'
# 6. Mã lỗi gateway nhận từ target (cách đọc ở dưới)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (rpc_method, rpc_response_status_code) (rate(rpc_client_call_duration_seconds_count{service_name="gateway",rpc_response_status_code!="OK"}[5m])) > 0' | jq -c '.data.result[] | [.metric.rpc_method, .metric.rpc_response_status_code, .value[1]]'
# 7. Người dùng đang mất gì: 5xx của gateway theo route (đối chiếu bảng ở mục trên)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (http_route, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name="gateway",http_response_status_code=~"5.."}[2m])) > 0' | jq -c '.data.result[] | [.metric.http_route, .metric.http_response_status_code, .value[1]]'
```

Dashboard `svp-pipeline`, hàng "Gateway resilience": "Circuit breaker state by target"; `svp-red`: "HTTP 5xx ratio by route"
(tác động, như bước 7), "Gateway gRPC client p99 by method" (target chậm) và "gRPC non-OK calls by code" (phía server của
target).

k3d:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="CircuitBreakerOpen"' | jq -c '.[] | [.labels.target, .labels.instance, .status.state, .startsAt]'
T=engagement-service                    # thay bằng target của dòng trên
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name="$T" -o wide      # READY, RESTARTS
kubectl --context k3d-svp -n svp describe pods -l app.kubernetes.io/name="$T" | tail -n 30   # Events: OOMKilled, probe, FailedCreate
kubectl --context k3d-svp -n svp get endpointslices -l kubernetes.io/service-name="$T"
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=gateway --since=15m --tail=2000 | grep 'circuit breaker state changed'
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name="$T" --since=15m --tail=200
```

Đọc kết quả:

- Container `Exited (0)` và log cuối là `grpc server stopping` rồi `grpc server stopped` → service được dừng êm (SIGTERM:
  `docker stop`, `dc stop`, `make down`, máy ngủ), không phải crash: bật lại được ngay. `Exited (137)` → bị kill (SIGKILL
  hay hết RAM: `env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.State.OOMKilled}}' svp-engagement-service-1`, container
  của target khác là `svp-<target>-1`); mã khác → crash, đọc log tới lỗi đầu.
- Service chết vẫn cho **cả** `UNAVAILABLE` lẫn `DEADLINE_EXCEEDED` ở bước 6: `GetStats` chỉ có 100 ms, trong hạn đó gRPC còn
  đang thử nối lại nên hết hạn trước. `DEADLINE_EXCEEDED` chỉ nghĩa là "chậm" khi container hay pod đang chạy, Ready.
- Breaker mở thì gateway không gọi target nữa (trừ lời gọi thử mỗi 5 s), nên số ở bước 6 nhỏ dần; tác động thật xem ở bước 7.
- Container hay pod không Ready/không có endpoint → service đích chết; pod Ready mà mã lỗi là `DEADLINE_EXCEEDED` → service
  chậm (xem dưới); `FailedCreate` có message của webhook Kyverno → [kyverno-down.md](kyverno-down.md)
hay [vuln-attestation-expired.md](vuln-attestation-expired.md).

## Nguyên nhân thường gặp

1. **Service đích dừng hay crash:** compose container bị dừng (diễn tập, `docker stop`, máy ngủ), k3d CrashLoopBackOff (không
   nối được Postgres, migrate lỗi, OOMKilled).
2. **Service đích quá chậm** (> 3 s): node k3d bão hoà CPU khi media-worker transcode
   ([liveness-timeout-cpu-saturation.md](liveness-timeout-cpu-saturation.md)), Postgres chậm hay khoá dòng lâu.
3. **Không tới được qua mạng** (chỉ k3d): pod mới chưa có trong rule NetworkPolicy, Service không có endpoint vì readiness
   lỗi.
4. **Pod mới không tạo được** (chỉ k3d, đường GitOps): Kyverno từ chối, nên sau một lần restart không còn pod nào.

## Giảm thiểu

Đưa service đích chạy lại; breaker tự đóng sau lời gọi thử thành công đầu tiên (half-open sau 5 s), **không cần** restart
gateway.

```sh
# compose: bật lại mọi container đang dừng của stack (idempotent; build lại nếu code đổi)
make up OBS=lgtm
# hoặc chỉ service đích ($T như ở Kiểm tra nhanh; start cũng chạy lại các container một lần nó phụ thuộc, như
# engagement-migrate: vô hại, ~2 s)
dc start "$T"
dc restart "$T"

# k3d: tạo lại pod của service đích (service đích là Deployment; gateway và web là Argo Rollout)
kubectl --context k3d-svp -n svp rollout restart deployment/"$T"
kubectl --context k3d-svp -n svp rollout status deployment/"$T" --timeout=180s
```

Target là `engagement-service`: tác động đã được thiết kế để nhỏ (feed vẫn đọc được); ưu tiên tìm nguyên nhân trước khi
restart lặp lại. Target là `feed-service`, `video-service`, `user-service`: restart ngay vì luồng chính đang 503.

## Khôi phục và xác nhận

```sh
# mọi instance về 0
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=max by (target) (svp_breaker_state{service_name="gateway"})' | jq -c '.data.result[] | [.metric.target, .value[1]]'
# cảnh báo hết (danh sách rỗng hoặc state không còn "active")
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="CircuitBreakerOpen"' | jq -c '.[] | [.labels.target, .status.state]'
# luồng đầu-cuối (LOCAL LAB ONLY: xoá khoá rate limit đăng ký ở db 10)
make smoke          # compose
make k8s-smoke      # k3d
```

Breaker chỉ đóng khi có lời gọi tới target: không có traffic thì `svp_breaker_state` giữ 2 và cảnh báo vẫn cháy dù service đã
lên. Gửi một request chạm target (`make smoke` làm việc đó) để breaker thử lại. Có traffic thì breaker đóng vài giây sau khi
service lên; game day đo (dưới tải k6 `local`): gateway log `closed` 4 s sau khi container chạy lại, Prometheus thấy 0 sau
khoảng 10 s, cảnh báo hết trong Alertmanager sau khoảng 21 s.

Mốc cho postmortem: giờ breaker đóng chính xác nằm ở log của gateway (`"to":"closed"`, lệnh bước 3), không phải ở Prometheus
(mẫu cách 15 s).

## Leo thang

- Service đích không đứng được sau 2 lần restart hay sau 15 phút: đọc log tới lỗi đầu tiên, kiểm phụ thuộc của nó (Postgres
  native `pg_isready -h 127.0.0.1 -p 5432`; k3d `kubectl --context k3d-svp -n svp-data get cluster svp-pg`). Postgres native
  dùng chung với dự án khác: không restart nó, báo chủ máy.
- Target là feed, video hay user và cảnh báo SLO availability cùng cháy: ghi mốc thời gian ngay (cho postmortem), sau sự cố
  mở postmortem.
- Breaker mở mà service đích khoẻ, không lỗi (log không có `UNAVAILABLE`/`DEADLINE_EXCEEDED`): nghi ngưỡng breaker hay cách
  tính lỗi; ghi lại số liệu, xem lại bằng tải k6 (mục "Xem lại khi" của ADR-0010, [ADR-0020](../adr/0020-reliability-stage6.md)
  §16).

## Liên kết

- Dashboard: `svp-pipeline` (Gateway resilience), `svp-red` (gRPC non-OK calls by code, trace gần đây).
- ADR: [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §4 (breaker), [ADR-0011](../adr/0011-observability-stage3.md)
  §8 (rule, độ mới của gauge), [ADR-0020](../adr/0020-reliability-stage6.md) §13 (game day).
- Diễn tập tái hiện: `make drill-engagement-down` (compose: tắt engagement-service, breaker mở sau 6 like trong 3,3 s, like
  503 chậm nhất 8,7 ms, bật lại 204 sau 1,6 s; số đo giai đoạn 3 trong roadmap); `make gameday` (cùng sự cố dưới tải k6,
  ADR-0020 §13; lần chạy 2026-10-24: [postmortem](../postmortems/261024-gameday-engagement-down.md)).
