# Attestation `vuln` quá 72 giờ

- Không có cảnh báo riêng. Dấu hiệu: pod `svp` mới trên cluster GitOps bị Kyverno từ chối với message `vuln attestation older
  than 72h (scanFinishedOn)`; `make k8s-gitops-up` dừng trước khi tạo gì; check `gitops-ok` của PR trong `svp-gitops` đỏ.
- Mọi lệnh ghi lên GitHub (dispatch workflow, bật workflow) do **người học chạy**.

## Ý nghĩa và tác động tới người dùng

Mỗi digest phát hành có một attestation `vuln` (kết quả trivy của hai nền tảng, ký keyless). Rescan hằng ngày (`images.yml`,
cron `17 1 * * *` UTC, script `deploy/ci/rescan.sh`) quét lại mọi digest của `main` và của PR promote đang mở rồi ghi lại
attestation. Ngưỡng tuổi ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §7–8):

- **72 giờ**: Kyverno (đường GitOps, Enforce) từ chối pod mới.
- **48 giờ**: check `gitops-ok` của PR trong `svp-gitops` (bước 5 của `deploy/ci/gitops-check.sh`), `make k8s-gitops-up`
  (`deploy/k8s/gitops.sh`) và `deploy/ci/verify-release.sh` dừng, để còn ít nhất 24 giờ trước ngưỡng của Kyverno.

Rescan không chạy hơn 3 ngày thì attestation của bản đang chạy quá 72 giờ. Pod đang chạy không bị đụng; người dùng chưa thấy
gì cho tới khi một pod cần tạo lại (restart, drain, scale, phát hành): service mất replica và không lên lại được. Đường dev
(Audit) không bị chặn.

## Kiểm tra nhanh (5 phút)

```sh
# lịch rescan có chạy không, lượt cuối xanh hay đỏ
gh run list --workflow images.yml --event schedule --limit 5
gh workflow list --all | grep -i images
# pod bị từ chối và message (GitOps)
kubectl --context k3d-svp -n svp get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -n 10
# tuổi attestation của từng bản phát hành stg và prd ở origin/main của bản clone svp-gitops (ẩn danh, cosign trên PATH hay
# COSIGN_IMAGE; ngưỡng 48 giờ); chạy từ gốc repo code, GITOPS là bản clone svp-gitops
GITOPS=../gitops
git -C "$GITOPS" fetch origin main
rev=$(git -C "$GITOPS" rev-parse origin/main)
for env in stg prd; do
  for f in $(git -C "$GITOPS" ls-tree --name-only "$rev" "envs/$env/images/"); do
    svc=$(basename "$f" .yaml)
    digest=$(git -C "$GITOPS" show "$rev:$f" | awk '$1 == "digest:" { gsub(/"/, "", $2); print $2; exit }')
    [ -n "$digest" ] && deploy/ci/verify-release.sh --gitops "$GITOPS" --rev "$rev" --env "$env" \
      "ghcr.io/anhnvcoder/short-video-platform/$svc" "$digest"
  done
done
```

Đọc kết quả: lượt `schedule` cuối cũ hơn 1 ngày hay không có → lịch không chạy. Lượt có chạy mà đỏ → đọc log của job `rescan`
(CRITICAL mới thì attestation ghi đúng kết quả và Kyverno từ chối với message `CRITICAL`, không phải message tuổi).

## Nguyên nhân thường gặp

1. **Lịch bị GitHub tắt**: workflow `schedule` của repo công khai bị tắt tự động khi repo không có hoạt động 60 ngày
   (`gh workflow list --all` thấy `disabled_inactivity`); hay bị tắt tay (`disabled_manually`).
2. **GitHub Actions hay Sigstore có sự cố** đúng giờ chạy lịch: lượt đỏ ở bước ký, không có attestation mới.
3. **Digest không có trong tập của rescan**: digest chỉ có ở một nhánh khác `main` và không phải PR promote đang mở, hay cluster
   dựng từ revision cũ (`GITOPS_REV`) có digest đã rời `main`.
4. **PR đổi values để quá 72 giờ rồi mới merge** (giới hạn ghi ở ADR-0015 §7): check của PR không chạy lại lúc merge.

## Giảm thiểu

Làm mới attestation (người học chạy, rồi chờ lượt xanh):

```sh
gh workflow enable images.yml                                         # nếu lịch bị tắt
gh workflow run images.yml --ref main -f rescan=true                  # digest của main (và PR promote đang mở)
gh workflow run images.yml --ref main -f rescan=true -f values_ref=<SHA hay refs/pull/<số PR>/head>   # digest của một revision hay PR
gh run list --workflow images.yml --event workflow_dispatch --limit 3
```

Kết quả attestation `vuln` không được cache ở Kyverno (payload quá lớn cho ngân sách cache, ADR-0015 §8), nên lần tạo pod kế
đọc attestation mới; ReplicaSet tự thử lại, hay đẩy nhanh bằng
`kubectl --context k3d-svp -n svp rollout restart deployment/<service>`. Gateway và web là Argo Rollouts Rollout, không phải
Deployment: restart bằng `spec.restartAt` như khối ở
[web-availability-budget-burn.md](web-availability-budget-burn.md#giảm-thiểu) (đổi `web` thành `gateway`).

**Không** hạ Kyverno về Audit hay sửa `maxAttestationAge` trên cluster để vượt qua: cluster GitOps lấy policy từ git (Argo CD
trả về), và đó là bỏ một lớp kiểm của chuỗi cung ứng.

## Khôi phục và xác nhận

```sh
# vòng lặp verify-release.sh ở trên: mỗi service in "ok ... within 2880 minutes"
kubectl --context k3d-svp -n svp get pods                             # đủ replica, Ready
kubectl --context k3d-svp -n svp get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp | tail -n 3
gh run list --workflow images.yml --event schedule --limit 2          # lịch chạy lại ở ngày kế
```

## Leo thang

- Rescan đỏ vì CRITICAL mới: không phải hết hạn; bản đang chạy có lỗ hổng nghiêm trọng. Build lại service để lấy bản vá (dispatch
  `services=<tên>`, hay PR cập nhật base image), hoặc thêm ngoại lệ có lý do vào `.trivyignore.yaml` (tối đa 30 ngày, qua PR).
- Sigstore hay GitHub sự cố kéo dài gần ngưỡng 72 giờ: tránh mọi thao tác làm tạo lại pod `svp` trên cluster GitOps (drain,
  restart) cho tới khi làm mới được; ghi vào postmortem.

## Liên kết

- ADR: [ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §7 (rescan, 48 giờ, `values_ref`), §8 (Kyverno, 72 giờ),
  [threat model](../threat-model.md) FF-8, SC-1, SC-7.
- Diễn tập tái hiện: `make drill-k8s-supplychain` ca (f) (attestation quá hạn với policy tạm tuổi tối đa 5 s); kiểm ngưỡng 48
  giờ bằng `SVP_ATTEST_MAX_AGE=1m` với `make k8s-gitops-up` (dừng trước khi tạo gì, roadmap giai đoạn 5).
