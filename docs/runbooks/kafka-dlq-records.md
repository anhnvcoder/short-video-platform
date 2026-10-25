# KafkaDLQRecords

- Severity: `page`. Rule: `deploy/observability/prometheus/rules/svp-alerts.yaml`, nhãn `service_name`, `group`, `topic`.
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Trong 10 phút qua consumer group `group` của `service_name` đã chép ít nhất một record của `topic` sang dead-letter topic
`<topic>.dlq` rồi commit record gốc: consumer **bỏ qua** record đó. Hai lý do (header `dlq-reason`):

- `permanent`: handler báo record không bao giờ xử lý được (payload hỏng, sai schema, dữ liệu không hợp lệ);
- `retries-exhausted`: lỗi tạm kéo dài hết số lần thử (phụ thuộc chết lâu).

Mỗi record trong DLQ là một việc không xảy ra: video không thành `READY`/`FAILED` (`media.transcodes.v1`), video không được
transcode hay không vào feed (`video.lifecycle.v1`), follow không vào feed (`user.follows.v1`), lượt xem không được đếm
(`engagement.views.v1`). Số người dùng bị ảnh hưởng tối đa bằng số record.

Cảnh báo hết 10 phút sau record DLQ cuối cùng; nó không tự nói đã xử lý xong các record đó.

## Kiểm tra nhanh (5 phút)

Compose:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="KafkaDLQRecords"' | jq -c '.[] | [.labels.service_name, .labels.group, .labels.topic, .startsAt]'
# lý do, lỗi, topic/partition/offset gốc của từng record (service_name của cảnh báo)
make logs SVC=feed-service | grep 'kafka record sent to dead-letter topic'
# record đã ghi trước đó: các lần thử lỗi tạm
make logs SVC=feed-service | grep 'kafka handler failed, retrying'
# số record trong DLQ (HIGH-WATERMARK của partition 0)
dc exec -T redpanda rpk topic describe user.follows.v1.dlq -p
# số record DLQ trong 1 giờ theo service, group, topic
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (service_name, group, topic) (increase(svp_kafka_dlq_records_total[1h]))' | jq -c '.data.result[] | [.metric, .value[1]]'
```

k3d:

```sh
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=feed-service --since=1h --tail=5000 | grep 'kafka record sent to dead-letter topic'
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk topic describe user.follows.v1.dlq -p
```

Dòng log có `trace_id`: mở trace đó trong Grafana Explore → Tempo để thấy lần xử lý lỗi. Dashboard `svp-pipeline` → "DLQ records
(per 10 min)".

## Nguyên nhân thường gặp

1. **Phụ thuộc chết lâu hơn số lần thử** (`retries-exhausted`): Postgres của service, object store `s3` (video-service, media-worker).
   Dấu hiệu: nhiều record cùng lúc, lỗi kết nối trong `error`.
2. **Bản phát hành mới đọc sai event** (`permanent`): producer và consumer lệch schema, envelope sai
   ([ADR-0006](../adr/0006-contract-ids-and-event-envelope.md)). Dấu hiệu: bắt đầu ngay sau deploy, mọi record của một loại event.
3. **Một record hỏng lẻ** (`permanent`): dữ liệu ngoài dự kiến; một record, một lỗi giải mã hay kiểm dữ liệu.

## Giảm thiểu

- Nguyên nhân 1: khôi phục phụ thuộc; record mới sẽ không vào DLQ nữa.
- Nguyên nhân 2: dừng deploy, quay về bản trước (compose: checkout bản trước rồi `make up OBS=lgtm`; GitOps: PR revert của
  commit promote, theo ruleset `main`).
- Record đã vào DLQ không tự chạy lại; dữ liệu gốc còn trong topic gốc (giữ 7 ngày, DLQ giữ 14 ngày, `deploy/redpanda/create-topics.sh`).

## Khôi phục và xác nhận

Xử lý lại record đã bỏ qua, **sau khi đã sửa nguyên nhân** và chỉ khi người trực quyết: handler của dự án idempotent (diễn
tập `make drill-duplicates`, `make drill-duplicates-feed` phát lại event mà không gì đổi), nên có thể đưa offset của group về
offset gốc ghi trong header/log (`dlq-topic`, `dlq-partition`, `dlq-offset`). `rpk group seek` chỉ chạy khi group không có
member, và phát lại **mọi** record từ offset đó trên partition đó:

```sh
# compose, ví dụ group feed-service, record gốc user.follows.v1 partition 2 offset 1234 (lấy từ log ở trên)
dc stop feed-service
printf '%s %s %s\n' user.follows.v1 2 1234 | dc exec -T redpanda rpk group seek feed-service --to-file /dev/stdin --topics user.follows.v1
dc start feed-service
dc exec -T redpanda rpk group describe feed-service
```

Trên k3d cùng bước với `kubectl --context k3d-svp -n svp scale deployment/feed-service --replicas=0`, `rpk` qua
`kubectl --context k3d-svp -n svp-data exec -i redpanda-0 -c redpanda -- rpk …`, rồi scale lại số replica cũ (media-worker do
KEDA quản: ghim bằng annotation `autoscaling.keda.sh/paused-replicas` như `deploy/k8s/drills/keda.sh`, nhớ bỏ ghim). Các lệnh
seek trên k3d chưa chạy thử.

**Không áp dụng cho group `engagement-service`** (topic `engagement.views.v1`): handler đếm lượt xem bỏ qua mọi record dưới
`next_offset` đã lưu trong `svp_engagement` (bảng `consumer_offsets`, cùng transaction với bộ đếm), nên seek group về trước
không đếm lại gì; và record DLQ của nó chỉ có thể là `permanent` (payload không giải mã được, lỗi database thì thử lại cả lô
không giới hạn), nên chạy lại cũng lỗi lần nữa. Lượt xem trong các record đó mất: ghi số record và `video_id` (nếu đọc được)
vào postmortem, không seek.

Xác nhận: không có dòng `dead-letter` mới, `TOTAL-LAG` về 0, thực thể bị ảnh hưởng đúng trạng thái (video `READY`, follow có
trong feed), cảnh báo hết sau 10 phút.

## Leo thang

- Record `permanent` do code: sửa handler hay producer, thêm test bằng chính payload đó (lấy từ DLQ, bỏ dữ liệu người dùng).
- Không chắc phát lại có an toàn (handler mới, chưa có diễn tập trùng lặp): không seek, ghi các id bị ảnh hưởng vào postmortem.
- Hơn vài record, hay ảnh hưởng tới video của người dùng: mở postmortem.

## Liên kết

- Dashboard: `svp-pipeline` (DLQ records, consumer lag).
- ADR: [ADR-0003](../adr/0003-async-events-outbox.md) (DLQ `<topic>.dlq`), [ADR-0011](../adr/0011-observability-stage3.md)
  §8 (rule), §11 (hạn ghi DLQ).
- Diễn tập tái hiện: chưa có diễn tập đưa record vào DLQ. Phát lại an toàn: `make drill-duplicates`,
  `make drill-duplicates-feed`.
