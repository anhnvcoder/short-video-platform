# Kyverno chết hay bị gỡ

- Không có cảnh báo riêng. Dấu hiệu: Deployment ở namespace `svp` có event `FailedCreate` với lỗi gọi webhook của Kyverno, hay
  ngược lại webhook của Kyverno biến mất. Chỉ cluster k3d `svp`.

## Ý nghĩa và tác động tới người dùng

Kyverno kiểm mọi Pod ở namespace `svp` qua `ImageValidatingPolicy` `svp-images` (chart `deploy/helm/svp-policy`): chỉ image
của một nguồn phát hành trong `deploy/helm/svp-policy/files/sources.json` (`backend`: `ghcr.io/anhnvcoder/short-video-platform/<tên>`,
`web`: `ghcr.io/anhnvcoder/svp-web/web`; một glob mỗi tên được phát hành, không glob cả prefix) theo digest, ký keyless bởi
`images.yml@refs/heads/main` của repo nguồn đó, attestation `vuln` đủ hai nền tảng, không CRITICAL, không quá 72 giờ
([ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §8, [ADR-0033](../adr/0033-svp-web-repo.md) §2). Hai chế độ:

- **GitOps** (`make k8s-gitops-up`): Enforce, `failurePolicy: Fail`.
- **Dev** (`make k8s-up`): Audit, `failurePolicy: Ignore`; Kyverno chết không chặn gì, chỉ mất PolicyReport.

Hai kiểu sự cố, ngược chiều nhau (đã thấy trên cluster dev và trong `make drill-k8s-supplychain`, ADR-0015 §8):

1. **Kyverno chết** (crash, pod không lịch được, mất node) trên GitOps: cấu hình webhook còn mà không endpoint nào trả lời →
   **mọi pod `svp` mới bị từ chối**. Pod đang chạy không bị đụng; người dùng chưa thấy gì cho tới khi một pod cần tạo lại
   (restart, drain node, scale, phát hành mới): lúc đó service mất replica và không lên lại được.
2. **Kyverno bị scale về 0 hay bị gỡ**: Kyverno v1.19.1 tự xoá mọi cấu hình webhook của nó khi admission controller dừng →
   **mọi pod `svp` được nhận không kiểm**. Người dùng không thấy gì; đây là lỗ hổng bảo mật im lặng (SC-1 tạm mất). Chỉ ai sửa
   được Deployment ở namespace `kyverno` làm được; trên GitOps Argo CD self-heal trả `replicas` về 1.

## Kiểm tra nhanh (5 phút)

```sh
kubectl --context k3d-svp -n kyverno get deploy,pods -o wide
# webhook của policy svp-images còn không (tên: ivpol.validate.kyverno.svc-fail-finegrained-svp-images)
kubectl --context k3d-svp get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o jsonpath='{range .webhooks[*]}{.name}{" "}{.failurePolicy}{"\n"}{end}'
# pod svp bị từ chối
kubectl --context k3d-svp -n svp get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -n 10
# chế độ của policy (Deny trên GitOps, Audit trên dev)
kubectl --context k3d-svp get imagevalidatingpolicy svp-images -o jsonpath='{.spec.validationActions}{" "}{.spec.failurePolicy}{"\n"}'
# vì sao admission controller không chạy
kubectl --context k3d-svp -n kyverno get events --sort-by=.lastTimestamp | tail -n 20      # FailedScheduling, OOMKilled, BackOff
kubectl --context k3d-svp -n kyverno logs deployment/kyverno-admission-controller --tail=200
```

Đọc kết quả: pod admission controller không Ready và event `FailedCreate` nói không gọi được webhook → kiểu 1. Không có
cấu hình webhook (lệnh thứ hai báo `NotFound` hay không có dòng `svp-images`) trong khi policy còn → kiểu 2. Event `FailedCreate`
có message của rule (`image without a keyless signature`, `vuln attestation older than 72h`…) → Kyverno đang chạy đúng, xem
[vuln-attestation-expired.md](vuln-attestation-expired.md).

## Nguyên nhân thường gặp

1. **Pod admission controller không lịch được hay crash**: thiếu tài nguyên node, `nodeSelector` không khớp (cách ca (g) của
   diễn tập làm Kyverno "tắt"), OOM.
2. **Node chứa Kyverno chết hay đứng** ([k3s-server-down-under-transcode.md](k3s-server-down-under-transcode.md)).
3. **Kyverno bị scale về 0 hay gỡ** (kiểu 2): thao tác tay, hay Application `kyverno` bị xoá.

## Giảm thiểu

- Kiểu 1: đưa admission controller chạy lại, **không** xoá cấu hình webhook hay scale Kyverno về 0 để "mở đường": làm vậy là mở
  cửa cho image chưa ký (kiểu 2). Chỉ làm khi người học quyết vì sự cố nặng hơn, và ghi vào postmortem.

```sh
kubectl --context k3d-svp -n kyverno rollout restart deployment/kyverno-admission-controller
kubectl --context k3d-svp -n kyverno rollout status deployment/kyverno-admission-controller --timeout=180s
```

- Kiểu 2 trên GitOps: Argo CD self-heal trả lại; kiểm Application `kyverno` Synced/Healthy. Trên dev: `make k8s-up` cài lại.
- Pod `svp` đã bị từ chối: ReplicaSet tự thử lại (backoff); khi webhook đã trả lời có thể đẩy nhanh bằng
  `kubectl --context k3d-svp -n svp rollout restart deployment/<service>`. Gateway và web là Argo Rollouts Rollout, không phải
  Deployment: restart bằng `spec.restartAt` như khối ở
  [web-availability-budget-burn.md](web-availability-budget-burn.md#giảm-thiểu) (đổi `web` thành `gateway`).

## Khôi phục và xác nhận

```sh
kubectl --context k3d-svp -n kyverno get pods
kubectl --context k3d-svp get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o jsonpath='{range .webhooks[*]}{.name}{"\n"}{end}' | grep svp-images
kubectl --context k3d-svp -n svp get pods                     # đủ replica, Ready
make k8s-smoke                                                # LOCAL LAB ONLY
```

Kiểu 2: kiểm thêm mọi pod `svp` tạo trong lúc không có webhook chạy image hợp lệ: so image của pod với digest trong
`envs/<env>/images/<service>.yaml` của repo `svp-gitops` (env của cluster; bản clone `../gitops`, sau `git -C ../gitops fetch origin main`, đọc bằng `git -C ../gitops show origin/main:envs/<env>/images/<service>.yaml`).

```sh
kubectl --context k3d-svp -n svp get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].image}{"\n"}{end}'
```

## Leo thang

- Admission controller không lên sau 15 phút: đọc log, kiểm tài nguyên node (`kubectl --context k3d-svp top nodes`); cluster lab
  có thể dựng lại.
- Kiểu 2 không rõ ai làm: xử lý như sự cố bảo mật, mở postmortem, xem lại ai có quyền sửa namespace `kyverno` (threat model mục 6).

## Liên kết

- ADR: [ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §8 (Kyverno, hai chế độ, webhook tự xoá), [threat model](../threat-model.md)
  SC-1, SC-7, mục 6 (Kyverno một replica).
- Diễn tập tái hiện: `make drill-k8s-supplychain` ca (g): admission controller không lịch được thì pod `svp` bị từ chối, pod ở
  `svp-probe` được nhận, webhook trở lại như trước khi kết thúc.
