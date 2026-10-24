# UploadInitAvailabilityBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO
  `upload-init-availability` của `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

SLO: 99,9% request `POST /videos` (tạo video, nhận form presigned để upload) ở gateway không trả 5xx trong 30 ngày. Page cháy
khi tỉ lệ 5xx vượt **1,44%** trên cả 1 giờ và 5 phút, hoặc **0,6%** trên cả 6 giờ và 30 phút
([ADR-0011](../adr/0011-observability-stage3.md) §8). 429 (`RATE_LIMITED`, `TOO_MANY_UPLOADS` khi đã có 3 video đang upload)
không phải lỗi của SLO này.

Người dùng: bấm đăng video thì lỗi ngay, chưa tải byte nào lên. Video đã upload xong vẫn transcode bình thường (đường đó đo ở
[video-ready-latency-budget-burn.md](video-ready-latency-budget-burn.md)); feed vẫn chạy.

Traffic `POST /videos` ở lab rất thưa: vài lần lỗi trong một giờ yên đã đủ vượt ngưỡng. Page tự hết tối đa ~30 phút sau khi
hết lỗi.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="UploadInitAvailabilityBudgetBurn"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
# số request và số 5xx theo mã trong 1 giờ (traffic thưa: nhìn số tuyệt đối)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (http_response_status_code) (increase(http_server_request_duration_seconds_count{service_name="gateway",http_request_method="POST",http_route="/videos"}[1h]))' | jq -c '.data.result[] | [.metric.http_response_status_code, .value[1]]'
make ps
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="CircuitBreakerOpen"' | jq -c '.[] | [.labels.target, .status.state]'
make logs SVC=video-service
```

k3d:

```sh
kubectl --context k3d-svp -n svp get pods -l 'app.kubernetes.io/name in (gateway,video-service)' -o wide
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=video-service --since=1h --tail=1000
kubectl --context k3d-svp -n svp-data get cluster svp-pg
```

Trace của request lỗi: dashboard `svp-red` (exemplar, "Recent gateway traces"), lỗi ở GlitchTip.

## Nguyên nhân thường gặp

1. **video-service chết hay không tới được**: 503, `CircuitBreakerOpen` target `video-service`
   ([circuit-breaker-open.md](circuit-breaker-open.md)).
2. **Postgres `svp_video` lỗi**: `InitUpload` đếm video đang upload và `INSERT` trong một transaction có advisory lock theo tác giả
   (UP-7, [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §5); Postgres lỗi hay khoá chờ lâu thì 5xx/504.
3. **Bản phát hành mới lỗi**: bắt đầu ngay sau deploy.

`InitUpload` không được retry ở gateway (mỗi lần gọi tạo một video mới), nên một lần lỗi mạng ngắn cũng thành 5xx. Form
presigned ký tại chỗ, không gọi MinIO: MinIO chết hay khoá S3 lệch không làm `POST /videos` lỗi mà làm bước tải lên MinIO
hay `CompleteUpload` lỗi sau đó.

## Giảm thiểu

- video-service chết: compose `dc start video-service` hay `make up OBS=lgtm`; k3d
  `kubectl --context k3d-svp -n svp rollout restart deployment/video-service`.
- Lỗi sau deploy: quay về bản trước như [feed-availability-budget-burn.md](feed-availability-budget-burn.md#giảm-thiểu).

## Khôi phục và xác nhận

```sh
make smoke        # compose: tạo video, upload presigned, chờ READY (LOCAL LAB ONLY)
make k8s-smoke    # k3d
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=slo:sli_error:ratio_rate5m{sloth_slo="upload-init-availability"}' | jq -c '.data.result[] | .value[1]'
```

## Leo thang

- Page của SLO này mở postmortem (số lần tạo video lỗi, thời gian).
- Lỗi chỉ ở một tác giả (khoá UP-7 giữ lâu): ghi `author_id` (không ghi email) và truy vấn khoá đang chờ trong `svp_video`
  (`SELECT` trên `pg_locks`, không huỷ phiên của dự án khác).

## Liên kết

- Dashboard: `svp-slo`, `svp-red`.
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8, [ADR-0004](../adr/0004-direct-upload-and-hls.md) (upload trực tiếp,
  presigned), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §4–5 (không retry `InitUpload`, UP-7).
- Diễn tập tái hiện: chưa có. `make drill-rate-limit` kiểm 429 `TOO_MANY_UPLOADS` (không phải lỗi của SLO này).
