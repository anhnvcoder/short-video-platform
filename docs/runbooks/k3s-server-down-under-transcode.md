# k3s server chết khi nhiều media-worker cùng transcode

- Không có cảnh báo riêng: Prometheus chạy trong chính cluster, nên khi API server chết không còn gì để gửi cảnh báo. Dấu hiệu
  thấy từ máy (lệnh `kubectl`, diễn tập lỗi).
- Chỉ cluster k3d `svp` trên máy 16 GB; trên cluster cloud control plane là managed
  ([ADR-0020](../adr/0020-reliability-stage6.md) §9).

## Ý nghĩa và tác động tới người dùng

Sự cố đã gặp ngày 2026-10-21 trên cluster GitOps ([ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md), Bối cảnh):
khoảng 25 s sau khi 3 media-worker cùng transcode, Docker VM bận 99% CPU, compaction của kine (SQLite của k3s) chạy `DELETE`
20,03 s, chạm hạn 20 s, k3s thoát `level=fatal "Transaction commit failed"`; Docker khởi động lại container `k3d-svp-server-0`.
API server mất 2,5 phút; ở lượt khác mọi pod và Application tự hồi sau 13 phút.

Trong lúc đó: `kubectl` lỗi (connection refused hay TLS handshake timeout ở `127.0.0.1:6550`), Envoy có thể trả 503, controller
mất lease và restart, Prometheus mất mẫu. Pod đang chạy trên node agent vẫn có thể phục vụ, nhưng không gì được lịch lại.

Sau đó media-worker bị giới hạn **tối đa 2 replica** (ADR-0017). Với 2 worker cùng transcode, node server vẫn đứng ~40 s một
lần (probe timeout, Envoy Gateway mất leader) nhưng k3s không restart.

## Kiểm tra nhanh (5 phút)

```sh
# 1. API server trả lời không
kubectl --context k3d-svp get --raw /readyz
# 2. container server có restart không (so với lần đọc trước)
env -u DOCKER_DEFAULT_PLATFORM docker inspect -f '{{.RestartCount}} {{.State.StartedAt}} {{.State.Status}}' k3d-svp-server-0
# 3. vì sao: compaction chậm, commit lỗi
env -u DOCKER_DEFAULT_PLATFORM docker logs --since 20m k3d-svp-server-0 2>&1 | grep -E 'Slow SQL|Transaction commit failed|level=fatal' | tail -n 20
# 4. CPU và RAM của hai node lúc này
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream k3d-svp-server-0 k3d-svp-agent-0
# 5. khi API server đã trả lời: số worker, giới hạn KEDA, pod restart
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=media-worker -o wide
kubectl --context k3d-svp -n svp get scaledobject media-worker -o jsonpath='{.spec.maxReplicaCount}{"\n"}'
make k8s-status
```

Đọc kết quả: `RestartCount` tăng và log có `Transaction commit failed` → đúng sự cố này. API server chậm mà không restart →
node bão hoà CPU, xem [liveness-timeout-cpu-saturation.md](liveness-timeout-cpu-saturation.md).

## Nguyên nhân thường gặp

1. **Nhiều worker cùng transcode** trên node chung với k3s server: mỗi worker giới hạn 2 CPU; 3 worker giữ 6/8 vCPU của Docker
   VM, phần còn lại không đủ cho API server và kine.
2. **Máy host thiếu tài nguyên**: chạy pin, Low Power Mode, giới hạn nhiệt, nhiều app mở (swap 15–17 GB, roadmap giai đoạn 5),
   test hay build chạy song song (lượt 1 ngày 2026-10-21).
3. **`maxReplicaCount` bị nâng lại quá 2** (khoá `keda.maxReplicas` ở `base/services/media-worker.yaml` của repo `svp-gitops`; sửa bằng PR vào repo đó).

## Giảm thiểu

- Chờ: Docker tự khởi động lại container server; API server thường lên lại sau vài phút. Không `make k8s-down` vội: mất cluster
  và mọi số đo.
- Bớt tải lên node trong lúc chờ: dừng việc nặng khác trên máy, cắm sạc, tắt Low Power Mode.
- Khi API server trả lời mà hàng đợi transcode còn dài, giữ media-worker ở 1 replica tới khi xong (cách diễn tập KEDA dùng, nhớ
  bỏ ghim):

```sh
kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas=1 --overwrite
# khi lag về 0:
kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas-
```

Trên cluster GitOps Argo CD có thể ghi đè annotation không có trong git; kiểm lại sau vài phút.

## Khôi phục và xác nhận

```sh
kubectl --context k3d-svp get --raw /readyz
kubectl --context k3d-svp get nodes
make k8s-status                    # mọi pod Running/Ready, không CrashLoopBackOff
make k8s-smoke                     # luồng đầu-cuối (LOCAL LAB ONLY)
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk group describe media-worker | grep -E 'MEMBERS|TOTAL-LAG'
```

Video đang transcode lúc server chết được làm lại (record chưa commit) và tới `READY` đúng một lần (tính chất của pipeline,
`make drill-kill-worker`).

## Leo thang

- Container server không lên lại sau 15 phút, hay restart lặp: `make k8s-down && make k8s-up` (dựng lại cluster dev; volume
  compose, Postgres native không bị đụng; dữ liệu trong cluster mất). Cluster GitOps: dựng lại bằng `make k8s-gitops-up`.
- Lặp lại với 2 worker: tiêu chí (c) của ADR-0017 không đạt; theo ADR-0017 thì cắt tiếp, hay dời đo năng lực lên cluster cloud
  (giai đoạn 7, node pool riêng cho media-worker, ADR-0020 §9). Mở postmortem.

## Liên kết

- ADR: [ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md) (sự cố, tiêu chí (c), tối đa 2),
  [ADR-0014](../adr/0014-kubernetes-local-stage4.md) §2 (ngân sách RAM, cách đo), [ADR-0020](../adr/0020-reliability-stage6.md) §9.
- Diễn tập tái hiện: `make drill-k8s-keda N=9` (tự kiểm (c): `RestartCount` và `StartedAt` của `k3d-svp-server-0` không đổi).
  Máy 16 GB: chỉ chạy khi cần, cắm sạc, đóng bớt app; đo năng lực để cluster cloud.
