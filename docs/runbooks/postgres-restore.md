# Phục hồi Postgres `svp-pg` từ backup (k3d)

- Quy trình làm tay, không có cảnh báo riêng. Chỉ cho cluster k3d **đường dev** (`make k8s-up`); compose dùng Postgres native,
  không có backup ở đây. Cluster GitOps (có Application `svp-root`, bước 4 dưới) không dùng được quy trình này: Argo CD sửa
  Cluster về git và `make k8s-up` bị từ chối; xem Leo thang.
- Cùng các bước với `make drill-k8s-backup` (`deploy/k8s/drills/backup.sh`, [ADR-0020](../adr/0020-reliability-stage6.md) §5).
  Diễn tập dừng giữa chừng thì nó in đúng các lệnh còn lại với tên thế hệ của lần chạy đó; trang này giải thích từng lệnh.

## Ý nghĩa và tác động tới người dùng

Mở trang này khi database `svp-pg` mất hay hỏng: PVC mất, Cluster bị xoá, Postgres không khởi động lại được, hay cần quay về
một thời điểm trước một thao tác sai (PITR). Trong lúc phục hồi, 4 service có Postgres (user, video, engagement, feed) và
GlitchTip lỗi; gateway trả 5xx cho mọi request cần chúng; web hiện lỗi. Dữ liệu từ lần lưu WAL cuối tới lúc mất bị mất (RPO);
với PITR, mọi thứ sau thời điểm mục tiêu bị bỏ, kể cả dữ liệu đúng.

Mỗi lần phục hồi tạo **thế hệ lưu trữ** mới (`serverName` `svp-pg-<yymmddhhmmss>` UTC): Job phục hồi từ chối lưu WAL vào thế hệ
đã có WAL, và hai thế hệ chung một chỗ sẽ trộn backup. Nguồn phục hồi là thế hệ mà Cluster bị mất đang lưu vào.

## Kiểm tra nhanh (5 phút)

Compose: không có.

k3d, ở gốc repo:

```sh
# 1. Cluster còn không, phase, thế hệ đang lưu
kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.phase} gen={.spec.plugins[0].parameters.serverName}{"\n"}'
# 2. Các thế hệ có trong bucket và cửa sổ phục hồi của từng cái (còn đọc được khi Cluster đã mất)
kubectl --context k3d-svp -n svp-data get objectstores.barmancloud.cnpg.io svp-pg-backup -o jsonpath='{.status.serverRecoveryWindow}' | jq .
# 3. Các Backup đã completed
kubectl --context k3d-svp -n svp-data get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STOPPED:.status.stoppedAt | tail -5
# 4. Ai đang quản cluster: có Application svp-root là đường GitOps, quy trình này không dùng được
kubectl --context k3d-svp -n argocd get applications.argoproj.io svp-root
```

Thế hệ nguồn (`OLD` bên dưới) là thế hệ ở bước 1 khi Cluster còn; khi Cluster đã mất, là thế hệ mới nhất ở bước 2 (tên có
thời điểm lớn nhất; thế hệ đầu tên `svp-pg`).

## Nguyên nhân thường gặp

1. **Diễn tập `make drill-k8s-backup` dừng giữa chừng**: Cluster đã xoá, chưa dựng lại. `make k8s-up` từ chối chạy lúc này
   (Cluster mất mà còn Backup của nó), để không tạo database rỗng đè lên.
2. **PVC hay dữ liệu Postgres hỏng**: pod `svp-pg-1` CrashLoopBackOff với lỗi đọc dữ liệu, Cluster `phase` báo lỗi.
3. **Thao tác sai trên dữ liệu** (xoá nhầm): cần PITR tới trước thời điểm đó.

## Giảm thiểu

Không có cách giữ service chạy khi database mất. Báo trạng thái (lab: ghi lại thời điểm cho postmortem) và phục hồi.

## Khôi phục và xác nhận

Đặt hai biến (ví dụ `OLD=svp-pg`, `NEW=svp-pg-$(date -u +%y%m%d%H%M%S)`); `NEW` phải khác mọi thế hệ ở bước 2.

```sh
OLD=<thế hệ nguồn>
NEW=svp-pg-$(date -u +%y%m%d%H%M%S)
```

1. **Chỉ khi Cluster còn nhưng hỏng** (nguyên nhân 2, 3): xoá Cluster và PVC của nó. Lệnh này xoá database; backup và bucket
   không bị đụng.

   ```sh
   kubectl --context k3d-svp -n svp-data delete cluster svp-pg --wait=true --timeout=300s
   kubectl --context k3d-svp -n svp-data get pvc -l cnpg.io/cluster=svp-pg   # phải rỗng; còn thì xoá đúng các PVC này
   ```

2. **Dựng lại `svp-pg` cùng tên từ backup** bằng chart `svp-data`, lưu WAL vào thế hệ mới. PITR thêm
   `--set-string postgres.recovery.targetTime=<RFC 3339, ví dụ 2026-10-24T05:28:17.000000Z>`. `initJobs.waitSeconds=900`: Job
   `pg-bootstrap` (hook của release) chờ server tới khi phục hồi xong.

   ```sh
   helm --kube-context k3d-svp upgrade svp-data deploy/helm/svp-data --namespace svp-data \
     --set-string postgres.backup.serverName="$NEW" --set-string postgres.recovery.source="$OLD" \
     --set initJobs.waitSeconds=900 --wait=hookOnly --timeout 20m
   kubectl --context k3d-svp -n svp-data wait --for=condition=Ready cluster/svp-pg --timeout=900s
   ```

   Không chạy `make k8s-up` trong lúc chờ: nó sẽ bỏ `bootstrap.recovery` khỏi một Cluster còn đang phục hồi, nên nó từ chối chạy
   khi Cluster có `bootstrap.recovery` mà chưa Ready.
   Không Ready: `kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.phase}: {.status.phaseReason}{"\n"}'`
   và log Job phục hồi `kubectl --context k3d-svp -n svp-data logs -l cnpg.io/cluster=svp-pg,cnpg.io/jobRole=full-recovery --all-containers --tail=100`.
   "Expected empty archive" là `NEW` trùng một thế hệ đã có: xoá Cluster (bước 1) và làm lại với `NEW` khác.

3. **Restart một lần các workload đang CrashLoopBackOff** (back-off tới 5 phút làm thời gian hồi ngẫu nhiên):

   ```sh
   kubectl --context k3d-svp -n svp rollout restart deployment user-service video-service engagement-service feed-service
   kubectl --context k3d-svp -n svp-obs rollout restart deployment glitchtip
   kubectl --context k3d-svp -n svp rollout status deployment feed-service --timeout=300s
   ```

4. **Xác nhận luồng đầu-cuối**: `make k8s-smoke` (LOCAL LAB ONLY: xoá khoá `svp:gw:rl:register:*` ở Valkey db 10 của cluster).

5. **Backup cơ sở cho thế hệ mới** (lần nâng chart ở bước 2 tạo lại ScheduledBackup nhưng nó không chạy `immediate` lần hai):
   lệnh ở [postgres-backup-too-old.md](postgres-backup-too-old.md#giảm-thiểu), chờ `completed`; hay để bước 6 lấy. Rồi kiểm WAL
   lưu được:
   `kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'` là `True`.

6. **`make k8s-up`** khi tiện: `deploy/k8s/install.sh` đọc thế hệ từ Cluster đang chạy và giữ nó (`--set`), bỏ
   `bootstrap.recovery` khỏi Cluster; CloudNativePG chỉ đọc `bootstrap` khi tạo instance đầu nên database không đổi. Sau chart
   `svp-data` nó chờ WAL lưu được và lấy một backup cơ sở khi thế hệ đang chạy chưa có cái nào (`pg_base_backup`).

Không bao giờ xoá Backup hay object của bucket `pg-backups` để "dọn": retention 7 ngày của ObjectStore làm việc đó.

## Leo thang

- Mọi thế hệ ở bước 2 đều không có backup `completed` (bucket mất cùng MinIO): không phục hồi được ở lab (backup cùng cluster,
  cùng ổ, BAK-1); dựng lại từ đầu bằng `make k8s-down && make k8s-up`, mất toàn bộ dữ liệu cluster. Ghi postmortem
  ([mẫu](../postmortems/README.md)).
- Phục hồi lỗi hai lần với `NEW` mới: dừng, giữ nguyên trạng thái (không xoá gì thêm), ghi log Job phục hồi và của plugin
  (`kubectl --context k3d-svp -n cnpg-system logs deployment/plugin-barman-cloud --since=1h`).
- Đường GitOps: Argo CD tự sửa `serverName` về giá trị trong git (và bỏ value phục hồi chỉ có trong lệnh), `make k8s-up` bị
  từ chối (`deploy/k8s/install.sh`), nên quy trình này không dùng được; phục hồi từ backup trên cluster đó chưa có quy trình
  (ADR-0020 §5). **Không đụng gì thêm:** bucket `pg-backups` của MinIO trong cluster là bản duy nhất còn đưa dữ liệu về được,
  và `make k8s-down` xoá cả MinIO lẫn bucket đó, biến mất mát còn phục hồi được thành mất hẳn. Không xoá Cluster, PVC, Backup
  hay object, không dựng lại cluster; ghi trạng thái (bước 1–3 của Kiểm tra nhanh, log như ý trên) và giữ nguyên tới khi có
  quy trình phục hồi cho đường GitOps; mở postmortem ([mẫu](../postmortems/README.md)). Chỉ dựng lại cluster GitOps từ đầu
  (`make k8s-down`, rồi `make k8s-gitops-up` như lần đầu, mất toàn bộ dữ liệu trong cluster) khi mọi thế hệ ở bước 2 đều không
  có backup `completed`, như ý đầu.

## Liên kết

- ADR: [ADR-0020](../adr/0020-reliability-stage6.md) §5 (thế hệ lưu trữ, diễn tập, RTO/RPO); threat model BAK-1.
- Cấu hình: `deploy/helm/svp-data/templates/postgres.yaml` (`plugins`, `bootstrap.recovery`, `externalClusters`),
  `templates/backup.yaml`, `deploy/k8s/install.sh` (`pg_backup_sets`, `pg_base_backup`).
- Diễn tập tái hiện: `make drill-k8s-backup` (`MODE=latest`) và `make drill-k8s-backup MODE=pitr`, JSON ở
  `.k8s/drills/backup-<time>.json` (RTO, RPO, số dòng mỗi bảng trước và sau). Số đo của buổi k3d ghi ở mục Kết quả của
  ADR-0020.
