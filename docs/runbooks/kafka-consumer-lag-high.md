# KafkaConsumerLagHigh

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`, hai biến thể cùng tên, nhãn
  `redpanda_group` cho biết group.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Consumer group có lag > 0 (ít nhất một record chưa commit) kéo dài: số lấy từ Redpanda (`redpanda_kafka_consumer_group_lag_max`,
Collector scrape broker). Lag > 0 bắt cả một record kẹt mãi, không chờ backlog hàng trăm
([ADR-0011](../adr/0011-observability-stage3.md) §8).

| Biến thể | Group | `for` | Đọc topic | Người dùng thấy khi kẹt |
| --- | --- | --- | --- | --- |
| 1 | `video-service` | 2 m | `media.transcodes.v1` | Video đứng `PROCESSING`, không thành `READY`/`FAILED`; `VideoReadyLatencyBudgetBurn` cháy theo |
| 1 | `feed-service` | 2 m | `video.lifecycle.v1`, `user.follows.v1` | Video mới không vào feed following, follow/unfollow không đổi feed (NFR độ tươi 10 s) |
| 1 | `engagement-service` | 2 m | `engagement.views.v1` | Lượt xem không tăng trong `stats` |
| 2 | `media-worker` | 20 m | `video.lifecycle.v1` | Video không được transcode; 20 phút vì một lần transcode hợp lệ giữ record tới 15 phút |

Nếu broker chết hay Collector không scrape được, metric mất và cảnh báo **không** cháy (hay tự hết): không có cảnh báo lag
không có nghĩa là pipeline chạy.

## Kiểm tra nhanh (5 phút)

Compose (`<group>` là nhãn `redpanda_group` của cảnh báo):

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="KafkaConsumerLagHigh"' | jq -c '.[] | [.labels.redpanda_group, .status.state, .startsAt]'
# MEMBERS 0: consumer không chạy; TOTAL-LAG; từng partition CURRENT-OFFSET so với LOG-END-OFFSET
dc exec -T redpanda rpk group describe feed-service
make ps
# lỗi tạm đang thử lại, record vào DLQ, lỗi fetch
make logs SVC=feed-service | grep -E 'kafka handler failed, retrying|dead-letter|kafka fetch error'
# lag theo group và topic
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=max by (redpanda_group) (redpanda_kafka_consumer_group_lag_max)' | jq -c '.data.result[] | [.metric.redpanda_group, .value[1]]'
```

k3d:

```sh
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk group describe feed-service
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=feed-service
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=30m --tail=2000 | grep -E 'kafka handler failed, retrying|dead-letter|kafka fetch error'
# media-worker: KEDA scale theo lag, tối đa 2 replica (ADR-0017)
kubectl --context k3d-svp -n svp get scaledobject media-worker
kubectl --context k3d-svp -n svp get hpa
```

Dashboard `svp-pipeline`: "Consumer lag by group (max over partitions)", "Consumer lag by group and topic", "Video CompleteUpload →
READY / FAILED p50 / p95", "Transcode duration p50 / p95".

## Nguyên nhân thường gặp

1. **Consumer không chạy**: `MEMBERS` 0, container dừng hay pod CrashLoopBackOff.
2. **Handler lỗi tạm và đang thử lại**: log `kafka handler failed, retrying` lặp với cùng offset; thường do phụ thuộc chết
   (Postgres của service, object store `s3` với media-worker và video-service). Hết số lần thử thì record vào DLQ
   ([kafka-dlq-records.md](kafka-dlq-records.md)) và lag tự hết.
3. **Xử lý chậm hơn tốc độ vào** (thường là media-worker): burst upload, máy bận CPU. Số tham chiếu: một video 60 s 1080p tới
   `READY` 41,5–41,7 s trên compose `core`, p50 54,8 s trên `OBS=lgtm` (`make measure-ready N=5`, giai đoạn 3); trên k3d lúc
   máy chạy pin và Low Power Mode một video mất 91–253 s (giai đoạn 4, roadmap).
4. **Rebalance liên tục**: pod bị restart lặp (probe, OOM), group không giữ được partition.

## Giảm thiểu

- Consumer dừng: compose `make up OBS=lgtm` (hay `dc start <service>`); k3d
  `kubectl --context k3d-svp -n svp rollout restart deployment/<service>`.
- Phụ thuộc chết: khôi phục phụ thuộc trước; consumer tự xử lý tiếp, không cần restart.
- media-worker chậm vì burst: chờ, hàng đợi được rút theo thứ tự; trên máy 16 GB **không** nâng `maxReplicaCount` quá 2 (k3s
  server chết khi 3 worker cùng transcode, [k3s-server-down-under-transcode.md](k3s-server-down-under-transcode.md)). Cắm
  sạc, tắt Low Power Mode.
- **Không** `rpk group seek` để bỏ qua record: mất event (video không bao giờ `READY`, follow không vào feed). Bỏ qua record là
  quyết định leo thang.

## Khôi phục và xác nhận

```sh
dc exec -T redpanda rpk group describe feed-service | grep -E 'MEMBERS|TOTAL-LAG'                                             # compose
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk group describe feed-service | grep -E 'MEMBERS|TOTAL-LAG'   # k3d
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="KafkaConsumerLagHigh"' | jq -c '.[] | [.labels.redpanda_group, .status.state]'
make smoke          # compose: upload tới READY, feed, view (LOCAL LAB ONLY)
make k8s-smoke      # k3d
```

`TOTAL-LAG` 0 và `MEMBERS` ≥ 1; cảnh báo hết ở lần đánh giá kế khi lag về 0. Với video-service và media-worker, mọi video kẹt
phải tới `READY` hay `FAILED` (`make smoke` chứng minh luồng mới chạy; video cũ kiểm theo id trong log).

## Leo thang

- Lag tăng mãi khi consumer chạy và log không có lỗi: nghi handler treo; lấy trace của span `process <topic>` trong Tempo
  (dashboard `svp-red`, "Recent gateway traces" hay Explore → Tempo), mở postmortem.
- Một record lỗi vĩnh viễn mà không vào DLQ (thử lại mãi với cùng offset): lỗi phân loại lỗi tạm/vĩnh viễn trong handler;
  sửa code. Bỏ qua record bằng `rpk group seek` chỉ khi đã ghi lại offset và chấp nhận mất event đó, ghi vào postmortem.
- media-worker lag trên k3d kèm API server chậm hay node NotReady: chuyển sang
  [k3s-server-down-under-transcode.md](k3s-server-down-under-transcode.md).

## Liên kết

- Dashboard: `svp-pipeline`.
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8, §11; [ADR-0008](../adr/0008-async-upload-pipeline-stage2a.md)
  (pipeline upload); [ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md) (media-worker tối đa 2).
- Diễn tập gần nhất: không có diễn tập giữ lag đủ 2 m/20 m để cảnh báo cháy. `make drill-kill-worker` (worker bị kill giữa
  lúc transcode, video vẫn `READY` đúng một lần) và `make drill-k8s-keda N=9` (k3d: lag đỉnh, KEDA scale lên 2 rồi về 1) tạo
  lag ngắn.
