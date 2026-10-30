# Application Argo CD không lên hay không hội tụ

- Cảnh báo: `ArgoCDApplicationDegraded` (`severity=page`) và `ArgoCDApplicationNotConverged` (`severity=ticket`, dùng chung
  runbook này). Chỉ cluster của đường GitOps (`make k8s-gitops-up`, sau này EKS stg/prd): compose và đường dev không có Argo CD
  nên không có series, không cảnh báo nào cháy.

## Ý nghĩa và tác động tới người dùng

Prometheus scrape metric `argocd_app_info` của application controller (PodMonitor `argocd-application-controller` của chart
`svp-observability`): mỗi Application một series, trạng thái sync và health nằm ở nhãn
([ADR-0032](../adr/0032-argocd-deploy-status.md)).

- **`ArgoCDApplicationDegraded`**: một Application ở health `Degraded`, `Missing` hay `Unknown` liền 10 phút. Nghĩa là một lần
  triển khai không lên: pod mới crash hay bị Kyverno từ chối, canary bị phân tích abort, không tài nguyên nào của Application
  còn trên cluster (`Missing`), hay Argo CD không đánh giá được (`Unknown`). Argo CD v3.5.5 không tính health của một tài nguyên
  chưa tạo được vào health của Application (Application chỉ `OutOfSync`, tức cảnh báo ticket bên dưới; `controller/health.go`):
  sync áp không được thì cảnh báo page tới từ root `svp-root`, chuyển `Degraded` khi sync của Application con đã `Failed` hẳn
  (hết 10 lần thử lại, khoảng 20 phút cộng thời gian mỗi lượt sync: chờ 10 s, gấp đôi tới trần 3 phút, tức
  10 + 20 + 40 + 80 + 160 + 5 × 180 = 1 210 s; page của `svp-root` tới sau khoảng 30 phút, cộng `for` 10 phút; health check của
  Application con ở `base/argo-cd.yaml` của `svp-gitops`). Application đang
  bị xoá có chủ đích (bỏ khỏi `components.json`, nhãn `operation="delete"`) không bao giờ page.
- **`ArgoCDApplicationNotConverged`**: một Application không `Synced` hay vẫn `Progressing`/`Suspended` liền 30 phút. Nghĩa là
  một lần triển khai không xong: sync tự động lỗi lặp lại, hook (Job migrate) treo, rollout không hoàn tất, canary dừng vì
  AnalysisRun `Inconclusive`.

Người dùng: thường **chưa thấy gì**. Canary bị abort thì bản stable vẫn phục vụ; Deployment mới không lên thì pod cũ vẫn chạy
(rolling update không bỏ pod cũ khi pod mới chưa Ready). Cảnh báo này nói về **bản phát hành**, cảnh báo SLO nói về người
dùng: có cả hai cùng lúc thì xử lý như sự cố người dùng trước. Application hạ tầng (`kyverno`, `kube-prometheus-stack`,
`svp-data`…) `Degraded` có thể chặn mọi thứ phía sau ([kyverno-down.md](kyverno-down.md)).

## Kiểm tra nhanh (5 phút)

Compose: không áp dụng (không có Argo CD). Cluster GitOps:

```sh
# Application nào, trạng thái gì, đang ở revision nào của svp-gitops
kubectl --context k3d-svp -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision
# tài nguyên nào của Application <app> không Healthy (Argo CD 3.x giữ health của tài nguyên trong resource tree, không trong CR)
make k8s-ui-argocd        # terminal 2: https://127.0.0.1:8081, mở Application <app>, lọc health khác Healthy
# lần sync cuối: thành công hay lỗi, message của nó
kubectl --context k3d-svp -n argocd get applications.argoproj.io <app> \
  -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}{"\n"}'
# pod và sự kiện ở namespace đích (dest_namespace của cảnh báo)
kubectl --context k3d-svp -n <ns> get pods
kubectl --context k3d-svp -n <ns> get events --sort-by=.lastTimestamp | tail -n 20
# gateway, web: Rollout và AnalysisRun của canary
kubectl --context k3d-svp -n svp get rollouts.argoproj.io,analysisruns.argoproj.io
```

Đọc kết quả:

- Event `FailedCreate` với message của rule Kyverno (`image without a keyless signature`, `vuln attestation older than 72h`…)
  → bản phát hành không qua policy: [vuln-attestation-expired.md](vuln-attestation-expired.md).
- Pod `CrashLoopBackOff`, `ImagePullBackOff`, probe trượt → lỗi của bản mới; xem log `kubectl … logs <pod> --previous`.
- Rollout `Degraded` với AnalysisRun `Failed` → canary bị abort đúng thiết kế: bản mới làm tăng lỗi hay độ trễ.
- Rollout `Paused`/`Suspended` với AnalysisRun `Inconclusive` → không đủ traffic để phân tích (cụm ít người dùng).
- `operationState.phase` là `Failed` hay `Error` với message của API server (field không hợp lệ, CRD thiếu) → manifest sai.
  Cảnh báo nêu `svp-root`: message health của nó (`kubectl … get applications.argoproj.io svp-root -o
  jsonpath='{.status.health.message}'`) và Application con `Degraded` cho biết Application nào sync lỗi; đọc tiếp lệnh trên
  với tên đó.
- Job `<svc>-migrate` lỗi hay chạy mãi → migration lỗi hay chờ khoá (Application `Progressing`/`OutOfSync`).

## Nguyên nhân thường gặp

1. **Bản phát hành mới lỗi** (crash, probe, phân tích canary trượt): bản cũ vẫn chạy, Application `Degraded`.
2. **Bản phát hành bị policy từ chối**: attestation `vuln` quá hạn, image chưa ký; pod mới không tạo được.
3. **Migration lỗi hay treo**: hook PreSync không xong, sync không đi tiếp.
4. **Canary không đủ traffic**: AnalysisRun `Inconclusive`, Rollout dừng (`NotConverged`).
5. **Cấu hình trong `svp-gitops` sai**: values hay overlay render ra manifest API server từ chối (check `gitops-ok` lẽ ra đã bắt;
   xem lại check của commit đó).

## Giảm thiểu

- **Bản mới lỗi (1, 2, 3)**: trả bản trước bằng **revert** commit promote trong `svp-gitops` (PR revert, check `gitops-ok`,
  merge); Argo CD kéo về trong khoảng 60 s. Không sửa tay trên cluster: self-heal của Argo CD ghi đè. Quy trình và cách tìm
  commit: [svp-gitops-setup.md](svp-gitops-setup.md) phần C (rollback). Với migration đã chạy: bản trước phải tương thích
  schema mới (expand/contract); không chạy migration `down`.
- **Canary dừng vì `Inconclusive` (4)**: quyết promote hay abort bằng tay sau khi xem số đo của bản mới. Lab không ghim plugin
  `kubectl argo rollouts`; các lệnh dưới ghi đúng patch mà plugin v1.10.1 (bản controller của lab, `base/argo-rollouts.yaml`)
  ghi vào subresource `status` của Rollout (`getPatches` của `pkg/kubectl-argo-rollouts/cmd/promote/promote.go`,
  `pkg/kubectl-argo-rollouts/cmd/abort/abort.go`). Argo CD không so phần `status` nên không trả lại. Không cần `spec.paused`:
  controller dừng canary vì `Inconclusive` bằng `status.pauseConditions` (lý do `InconclusiveAnalysisRun`) và
  `status.controllerPause`, không bao giờ đặt `spec.paused`. Đối chiếu với nguồn, chưa chạy trên cluster của lab (cùng cách
  patch subresource `status` mà `deploy/k8s/drills/web-canary.sh` dùng cho `promoteFull`).

```sh
# ca nào: "<trạng thái phân tích của bước> <controllerPause> <bước hiện tại>"
kubectl --context k3d-svp -n svp get rollout <gateway|web> \
  -o jsonpath='{.status.canary.currentStepAnalysisRunStatus.status}{" "}{.status.controllerPause}{" "}{.status.currentStepIndex}{"\n"}'
# đi tiếp, khi dòng trên là "Inconclusive true <i>" (phân tích của bước gate trước 100 %, i = 4): bỏ dừng và qua bước đó,
# <i+1> là i cộng 1; chỉ xoá pauseConditions ở ca này thì Rollout vẫn kẹt
kubectl --context k3d-svp -n svp patch rollout <gateway|web> --subresource status --type merge \
  -p '{"status":{"pauseConditions":null,"controllerPause":false,"currentStepIndex":<i+1>}}'
# đi tiếp, mọi ca khác (phân tích nền Inconclusive): chỉ bỏ dừng
kubectl --context k3d-svp -n svp patch rollout <gateway|web> --subresource status --type merge \
  -p '{"status":{"pauseConditions":null}}'
# về stable: route về 100/0, Rollout Degraded
kubectl --context k3d-svp -n svp patch rollout <gateway|web> --subresource status --type merge \
  -p '{"status":{"abort":true}}'
```

  Sau abort, Rollout ở `Degraded` (Application `Degraded`, cảnh báo page cháy tiếp) tới khi template trở về bản stable: revert
  commit promote trong `svp-gitops` như ca 1 ở trên; Argo CD áp bản revert thì Rollout về `Healthy` không qua canary.
- **Manifest sai (5)**: revert như trên, rồi sửa bằng PR mới.

## Khôi phục và xác nhận

```sh
kubectl --context k3d-svp -n argocd get applications.argoproj.io <app> \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'         # Synced Healthy
make k8s-smoke                                                                  # LOCAL LAB ONLY
```

Cảnh báo resolve khi series của Application trở lại `Synced`/`Healthy` (kiểm trong Alertmanager, `make k8s-ui-alertmanager`).

## Leo thang

- Revert xong mà Application vẫn không lên: lỗi không nằm ở bản phát hành (node, Kyverno, database): chuyển sang runbook của
  thành phần đó.
- Application hạ tầng (`kyverno`, `svp-data`, `kube-prometheus-stack`) `Degraded` trên prd: dừng mọi promote prd tới khi xong.
- Bản lỗi đã tới prd, hay rollback mất hơn 30 phút: mở postmortem ([mẫu](../postmortems/README.md)).

## Liên kết

- [ADR-0032](../adr/0032-argocd-deploy-status.md) (trạng thái triển khai của Argo CD), ADR-0025 (repo `svp-gitops`),
  ADR-0014 §12 (canary), [svp-gitops-setup.md](svp-gitops-setup.md) (rollback).
- Diễn tập: bước `gitops-argocd-metrics` của kịch bản `gitops` (`verify.yml`) kiểm Prometheus thấy đủ Application
  `Synced`/`Healthy` và không cảnh báo Argo CD nào cháy. Ca canary bị abort tái hiện được bằng `make drill-k8s-canary` (cluster
  dev, không có Argo CD nên không có cảnh báo này); chưa có diễn tập làm cảnh báo cháy trên cluster GitOps.
