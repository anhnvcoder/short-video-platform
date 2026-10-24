# VideoReadyLatencyBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO `video-ready-latency`
  của `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

SLO: 95% video đã `CompleteUpload` tới `READY` trong bucket 120 s (NFR p95 120 s); video `FAILED` luôn tính là xấu, dù nhanh.
Ngân sách 5%. Page cháy khi hơn **72%** video xấu (14,4 × 5%) trên cả 1 giờ và 5 phút, hoặc hơn **30%** (6 ×) trên cả 6 giờ và
30 phút ([ADR-0011](../adr/0011-observability-stage3.md) §8). Metric `svp_video_ready_duration_seconds` do video-service ghi
lúc video đổi sang `READY` hay `FAILED`; video còn kẹt `PROCESSING` **chưa** được tính cho tới khi nó kết thúc.

Người dùng: video vừa đăng không xem được sau 2 phút, hoặc thành `FAILED`.

Traffic upload ở lab rất thưa: một hay hai video `FAILED` trong một giờ yên là đủ vượt 72%. Trước khi leo thang, xem video
`FAILED` có phải do file đầu vào hỏng hay quá 3 phút (đúng thiết kế) không.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="VideoReadyLatencyBudgetBurn"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
# số video theo outcome trong 1 giờ: ready chậm hay failed
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (outcome) (increase(svp_video_ready_duration_seconds_count{service_name="video-service"}[1h]))' | jq -c '.data.result[] | [.metric.outcome, .value[1]]'
# p95 CompleteUpload -> READY và thời gian transcode của worker (giây)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.95, sum by (le, outcome) (rate(svp_video_ready_duration_seconds_bucket{service_name="video-service"}[1h])))' | jq -c '.data.result[] | [.metric.outcome, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=histogram_quantile(0.95, sum by (le, outcome) (rate(svp_transcode_duration_seconds_bucket{service_name="media-worker"}[1h])))' | jq -c '.data.result[] | [.metric.outcome, .value[1]]'
# hàng đợi: lag của media-worker (video.lifecycle.v1) và video-service (media.transcodes.v1)
dc exec -T redpanda rpk group describe media-worker | grep -E 'MEMBERS|TOTAL-LAG'
dc exec -T redpanda rpk group describe video-service | grep -E 'MEMBERS|TOTAL-LAG'
make logs SVC=media-worker
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream
```

k3d:

```sh
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=media-worker -o wide
kubectl --context k3d-svp -n svp get scaledobject media-worker
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk group describe media-worker
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=media-worker --since=1h --tail=1000
kubectl --context k3d-svp top nodes
```

Dashboard `svp-pipeline`: "Video CompleteUpload → READY / FAILED p50 / p95 (SLO 120 s)", "Transcode duration p50 / p95", consumer
lag. Log của media-worker và video-service có `video_id`, `trace_id` (UP-8).

## Nguyên nhân thường gặp

1. **Video `FAILED`**: file hỏng, không phải video, dài hơn 3 phút (đúng thiết kế); hay MinIO lỗi khi worker đọc/ghi (lỗi
   kết nối trong log worker). Phân biệt bằng lỗi trong log của `video_id` đó.
2. **Hàng đợi transcode dài**: burst upload; compose có 1 worker, k3d tối đa 2
   ([ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md)); lag media-worker tăng.
3. **Transcode chậm vì CPU**: máy chạy pin, Low Power Mode, nhiệt; k3d trên pin một video 60 s 1080p mất 91–253 s thay vì
   ~45–64 s (giai đoạn 4, roadmap).
4. **media-worker chết hay restart giữa chừng**: video được worker khác (hay lần chạy sau) làm lại, chậm thêm một lần transcode
   (diễn tập `make drill-kill-worker`: `READY` 80 s sau khi worker khởi động lại).
5. **video-service không đọc `media.transcodes.v1`**: worker xong nhưng video không đổi trạng thái; lag group `video-service`
   ([kafka-consumer-lag-high.md](kafka-consumer-lag-high.md)).

## Giảm thiểu

- Worker dừng: compose `dc start media-worker`; k3d `kubectl --context k3d-svp -n svp rollout restart deployment/media-worker`.
- CPU: cắm sạc, tắt Low Power Mode, dừng việc nặng khác. Không nâng số worker trên máy 16 GB.
- MinIO lỗi: compose `make up OBS=lgtm` bật lại `minio`; k3d `kubectl --context k3d-svp -n svp-data get pods` rồi xử lý pod MinIO.
- Video `FAILED` do đầu vào: không cần giảm thiểu; ghi nhận trong postmortem nếu cảnh báo cháy chỉ vì nó.

## Khôi phục và xác nhận

```sh
make smoke                       # compose: một video tới READY và phát HLS (LOCAL LAB ONLY)
make k8s-smoke                   # k3d
make measure-ready N=5           # compose: p50, p95, max CompleteUpload -> READY, CPU/RAM worker
```

Lag media-worker về 0, video kẹt tới `READY` (hay `FAILED` có lý do), page hết trong tối đa ~30 phút. Số tham chiếu
`measure-ready N=5` (giai đoạn 3): 41,5–41,7 s trên `core`, p50 54,8 s, p95 64,2 s trên `OBS=lgtm`.

## Leo thang

- Nhiều video `FAILED` do lỗi hạ tầng (MinIO, Postgres), hay video kẹt `PROCESSING` quá 15 phút: mở postmortem với danh sách
  `video_id`.
- Trên k3d API server chậm hay node NotReady khi transcode: [k3s-server-down-under-transcode.md](k3s-server-down-under-transcode.md).

## Liên kết

- Dashboard: `svp-slo`, `svp-pipeline`.
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8, [ADR-0008](../adr/0008-async-upload-pipeline-stage2a.md) (pipeline
  upload, transcode), [ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md).
- Diễn tập, đo: `make measure-ready N=5`, `make drill-kill-worker`, `make drill-duplicates`; k3d `make drill-k8s-keda N=9`.
