# BackgroundLoopStalled

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`, bốn biến thể cùng tên, nhãn `loop` và
  `service_name`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Một vòng nền đã không thành công quá ngưỡng, đo bằng gauge `svp_loop_last_success_seconds` (Unix time của lần thành công cuối,
0 khi chưa lần nào) **trong mẫu mới hơn 45 s** của chính instance đó. Hai nhánh: vòng đã từng thành công nhưng lần cuối quá
cũ, hoặc chưa thành công lần nào suốt cả ngưỡng ([ADR-0011](../adr/0011-observability-stage3.md) §8).

| `loop` | Service | Chu kỳ | Cháy sau | Người dùng thấy khi đứng |
| --- | --- | --- | --- | --- |
| `outbox-relay` | `user-service`, `video-service` | 200 ms khi rảnh | 2 phút | Event không ra Redpanda: video upload xong không được transcode, video `READY` và follow không vào feed |
| `outbox-cleanup` | `user-service`, `video-service` | 10 phút | 32 phút | Không thấy gì ngay; bảng outbox lớn dần |
| `upload-sweep` | `video-service` | 5 phút | 18 phút | Không thấy gì ngay; video bỏ dở không chuyển `FAILED`, object `uploads/<id>` không bị xoá |
| `timeline-prune` | `feed-service` | 1 giờ | 3 giờ 10 phút | Không thấy gì ngay; dòng timeline quá 30 ngày không bị xoá |

Cảnh báo chỉ nhìn mẫu mới: service **dừng hẳn** thì metric ngừng và cảnh báo hết sau tối đa 45 s. Cảnh báo hết không có nghĩa
vòng đã hồi; kiểm service còn sống.

## Kiểm tra nhanh (5 phút)

Compose (`<service>` và `<loop>` lấy từ nhãn của cảnh báo):

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="BackgroundLoopStalled"' | jq -c '.[] | [.labels.service_name, .labels.loop, .startsAt]'
# tuổi lần thành công cuối theo instance (giây)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=time() - svp_loop_last_success_seconds > 0' | jq -c '.data.result[] | [.metric.service_name, .metric.loop, .value[1]]'
make ps
# log lỗi của từng vòng
make logs SVC=video-service | grep -E 'outbox relay failed, retrying|outbox cleanup failed|upload sweep failed|delete abandoned upload'
make logs SVC=feed-service | grep -E 'prune timeline|timeline pruned'
# outbox-relay: Redpanda còn nhận không (relay produce vào đó)
dc exec -T redpanda rpk cluster health
```

k3d:

```sh
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=video-service
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=video-service --since=30m --tail=3000 | grep -E 'outbox relay failed|outbox cleanup failed|upload sweep failed|delete abandoned upload'
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=4h --tail=5000 | grep -E 'prune timeline|timeline pruned'
kubectl --context k3d-svp -n svp-data get pods redpanda-0
kubectl --context k3d-svp -n svp-data get cluster svp-pg
```

Dashboard `svp-pipeline` → "Background loops: seconds since last success"; `svp-use` → "Postgres pool" (kết nối đã mượn so với
max, chờ kết nối).

## Nguyên nhân thường gặp

1. **`outbox-relay`: Redpanda không nhận** (broker dừng, k3d: SASL/ACL sai sau khi đổi mật khẩu): log `outbox relay failed,
   retrying` với lỗi produce.
2. **Postgres của service lỗi hay chậm**: mọi vòng của service đó cùng lỗi; pool hết kết nối.
3. **Lỗi object store** (`upload-sweep`): object store (`s3`) chết hay sai quyền, log `delete abandoned upload`; theo thiết kế lượt dừng và thử
   lại ở chu kỳ sau ([ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §5).
4. **Lượt chạy quá hạn** (`timeline-prune` 2 phút, `upload-sweep` 30 s mỗi lô, `outbox-cleanup` 30 s): khoá dòng lâu, Postgres
   chậm; log `prune timeline timed out`.
5. **Goroutine của vòng treo** dù service vẫn export metric: không có log lỗi nào mà tuổi vẫn tăng.

## Giảm thiểu

- Sửa phụ thuộc (Redpanda, Postgres, object store `s3`) trước; vòng tự chạy lại ở chu kỳ kế, không cần restart.
- `outbox-relay` đứng mà phụ thuộc khoẻ (nguyên nhân 5): restart service để vòng chạy lại: compose `dc restart video-service`,
  k3d `kubectl --context k3d-svp -n svp rollout restart deployment/video-service`. Event chưa gửi nằm trong bảng outbox
  (không bị xoá khi chưa gửi), relay gửi bù khi chạy lại.
- Ba vòng dọn dẹp (`outbox-cleanup`, `upload-sweep`, `timeline-prune`) không ảnh hưởng người dùng ngay: không cần restart giữa
  đêm; sửa trong giờ làm việc.

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=max by (service_name, loop) (time() - svp_loop_last_success_seconds)' | jq -c '.data.result[] | [.metric.service_name, .metric.loop, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="BackgroundLoopStalled"' | jq -c '.[] | [.labels.loop, .status.state]'
make smoke        # compose: follow và upload đi qua outbox (LOCAL LAB ONLY)
make k8s-smoke    # k3d
```

Tuổi của vòng quay về dưới một chu kỳ, cảnh báo hết ở lần đánh giá kế. Với `outbox-relay`, video upload trong lúc đứng phải tới
`READY` và follow phải có trong feed.

## Leo thang

- `outbox-relay` đứng quá 15 phút dù Redpanda và Postgres khoẻ: không có goroutine dump để xem (pprof không publish, OPS-1),
  nên ghi lại thời điểm và log, restart, mở postmortem; Pyroscope (`make up OBS=lgtm`) có profile CPU của lúc đó.
- Postgres native (compose) là chung với dự án khác: không restart, báo chủ máy.
- `upload-sweep` lỗi vì quyền của object store: kiểm policy của user `svp-video-service` (`deploy/s3/video-service-policy.json`,
  job `s3-init` đặt lại mỗi lần `make up` hay `make k8s-up`); đổi
  policy là thay đổi cấu hình qua PR.

## Liên kết

- Dashboard: `svp-pipeline` (Background loops), `svp-use` (Postgres pool).
- ADR: [ADR-0011](../adr/0011-observability-stage3.md) §8 (ngưỡng từng vòng), §11 (hạn của pool và vòng nền);
  [ADR-0003](../adr/0003-async-events-outbox.md) (outbox), [ADR-0010](../adr/0010-redis-ratelimit-cache-resilience-stage2c.md) §5
  (job dọn upload).
- Diễn tập: chưa có diễn tập làm vòng đứng đủ lâu để cảnh báo cháy. `make drill-upload-cleanup` chạy `upload-sweep` với hạn
  ngắn (video bỏ dở `FAILED`, object bị xoá) để kiểm vòng còn làm việc.
