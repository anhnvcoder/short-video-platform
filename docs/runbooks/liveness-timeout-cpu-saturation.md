# Liveness quá hạn khi node bão hoà CPU

- Không có cảnh báo riêng; thường lộ ra qua cảnh báo khác (`CircuitBreakerOpen`, SLO availability, `FeedLatencyBudgetBurn`)
  hay diễn tập lỗi. Chỉ cluster k3d `svp`.

## Ý nghĩa và tác động tới người dùng

Sự cố đã gặp ở giai đoạn 4 (roadmap, "Ghi nhận"): máy chạy pin với Low Power Mode, transcode một video 60 s 1080p mất 91–253
s, Docker VM 8 vCPU bận 99%; probe của service cùng node quá hạn 1 s nên kubelet **restart pod còn sống** (video-service
restart 2 lần), readiness của user-service và gateway lỗi nên pod bị rút khỏi Service; `make drill-k8s-keda` FAIL 2/2. Ở lượt
khác máy bị giới hạn nhiệt: API server chậm, controller mất lease và restart, Envoy trả 503, cluster tự hồi sau ~3 phút.

Người dùng: 503 từ Envoy hay gateway trong lúc pod bị rút hay restart, request chậm.

Từ giai đoạn 6 probe của chart `svp-service` đã nới ([ADR-0020](../adr/0020-reliability-stage6.md) §10): liveness
`timeoutSeconds: 5` (period 10 s, failure 3), readiness 2 s (period 5 s), startup gRPC 2 s × 30 lần. Còn bị restart với
cấu hình đó nghĩa là node bận hơn mức probe chịu được.

## Kiểm tra nhanh (5 phút)

```sh
# pod restart, lý do lần kết thúc trước
kubectl --context k3d-svp -n svp get pods -o wide
kubectl --context k3d-svp -n svp get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
# event probe: "Liveness probe failed ... context deadline exceeded", "Readiness probe failed"
kubectl --context k3d-svp -n svp get events --sort-by=.lastTimestamp | grep -E 'Unhealthy|Killing|BackOff' | tail -n 20
# CPU của node và pod
kubectl --context k3d-svp top nodes
kubectl --context k3d-svp -n svp top pods
env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream k3d-svp-server-0 k3d-svp-agent-0
# có media-worker nào đang transcode, trên node nào
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=media-worker -o wide
# probe đang áp dụng (timeoutSeconds) của một Deployment
kubectl --context k3d-svp -n svp get deployment video-service -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}{"\n"}'
```

Trên máy: kiểm có đang chạy pin, Low Power Mode, nhiều app mở không. Ở Docker VM này PSI cpu không dùng làm bằng chứng nghẽn
CPU (đọc 58–84% cả khi `/proc/stat` chỉ 8–11% bận, roadmap giai đoạn 5).

## Nguyên nhân thường gặp

1. **media-worker transcode trên cùng node với service**: mỗi worker tới 2 CPU; hai worker chiếm phần lớn VM.
2. **Máy host yếu đi**: pin, Low Power Mode, nhiệt, swap.
3. **Việc nặng khác cùng lúc**: build image, test, cluster khác.
4. **Pod chưa có probe mới** (cluster dựng trước khi đổi chart): `timeoutSeconds` trong lệnh cuối không có hay là 1.

## Giảm thiểu

- Cắm sạc, tắt Low Power Mode, đóng bớt app, dừng việc nặng khác.
- Giữ media-worker ở 1 replica tới khi hàng đợi rút:

```sh
kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas=1 --overwrite
```

  Chờ tới khi lag của group `media-worker` về 0 (`TOTAL-LAG` 0), **rồi mới** bỏ ghim để KEDA scale lại theo lag:

```sh
kubectl --context k3d-svp -n svp-data exec redpanda-0 -c redpanda -- rpk group describe media-worker | grep -E 'MEMBERS|TOTAL-LAG'
```

```sh
# khi lag về 0:
kubectl --context k3d-svp -n svp annotate scaledobject media-worker autoscaling.keda.sh/paused-replicas-
```

- Pod chưa có probe mới: `make k8s-up` (đường dev) để render lại chart; pod template đổi nên gateway và web chạy canary.
- Không nới probe thêm tại chỗ bằng `kubectl edit`: liveness dài hơn làm tiến trình treo thật bị giết chậm hơn; đổi probe là đổi
  chart qua PR và ADR.

## Khôi phục và xác nhận

```sh
kubectl --context k3d-svp -n svp get pods                     # mọi pod Ready, RESTARTS không tăng trong 10 phút
kubectl --context k3d-svp top nodes
make k8s-smoke                                                # LOCAL LAB ONLY
```

## Leo thang

- Pod vẫn restart khi máy cắm sạc, yên, không worker nào transcode: không phải do CPU; đọc log và `lastState` của pod.
- Lặp lại mỗi lần có hai worker: đây là giới hạn của máy 16 GB; tách CPU của media-worker (node pool riêng, taint và
  toleration) là việc của cluster cloud giai đoạn 7 (ADR-0020 §9, §10). Ghi số vào postmortem nếu có người dùng bị ảnh hưởng.

## Liên kết

- ADR: [ADR-0020](../adr/0020-reliability-stage6.md) §10 (probe), §9; [ADR-0017](../adr/0017-gitops-capacity-media-worker-max2.md);
  [ADR-0014](../adr/0014-kubernetes-local-stage4.md) (workload, PDB).
- Diễn tập tái hiện: `make drill-k8s-keda N=9` (2 worker cùng transcode); chỉ chạy khi cần, cắm sạc, đóng bớt app.
