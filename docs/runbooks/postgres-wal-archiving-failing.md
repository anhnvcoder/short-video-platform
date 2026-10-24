# PostgresWALArchivingFailing

- Severity: `page`. Rule: nhóm `postgres-backup` của `deploy/observability/prometheus/rules/svp-alerts.yaml`.
- Chỉ có ở cluster k3d (Postgres `svp-pg` của CloudNativePG, backup bằng plugin Barman Cloud,
  [ADR-0020](../adr/0020-reliability-stage6.md) §5). Compose dùng Postgres native, không backup, không có series này.
- Chuẩn bị biến `PROM`, `AM` (phần k3d): [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Lần lưu WAL gần nhất của `svp-pg` lên bucket `pg-backups` (MinIO trong cluster) **lỗi**, và tình trạng đó kéo dài 5 phút:
`cnpg_pg_stat_archiver_last_failed_time > cnpg_pg_stat_archiver_last_archived_time` (thời điểm lỗi cuối sau thời điểm lưu
được cuối). Rule so thời điểm chứ không đo "lâu chưa lưu", vì lab nhàn rỗi có thể hàng giờ không sinh WAL.

Người dùng chưa thấy gì: đọc, ghi vẫn chạy. Cái mất là **đường lui**:

- mọi thay đổi từ lần lưu được cuối chỉ nằm trên ổ của cluster; mất PVC hay node lúc này là mất chúng (RPO tăng dần);
- WAL chưa lưu không được xoá, dồn trong PVC 2 GiB của `svp-pg` tới đầy thì Postgres dừng ghi: lúc đó mọi service có
  Postgres lỗi 5xx. Vì vậy cảnh báo này là page.

Backup cơ sở mới (`ScheduledBackup` `svp-pg-daily`) cũng sẽ lỗi khi đích không ghi được: xem thêm
[postgres-backup-too-old.md](postgres-backup-too-old.md).

## Kiểm tra nhanh (5 phút)

Compose: không có (không có backup Postgres ở compose).

k3d, chạy ở gốc repo:

```sh
PG=$(kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.currentPrimary}')
# 1. Trạng thái Cluster: ContinuousArchiving False kèm lý do, phase
kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.phase}{"\n"}{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
# 2. Bộ đếm của archiver: failed_count tăng, last_failed_wal là segment đang kẹt
kubectl --context k3d-svp -n svp-data exec "$PG" -c postgres -- psql -X -A -U postgres -c 'select archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time from pg_stat_archiver'
# 3. Lỗi cụ thể: log của sidecar Barman trong pod Postgres
kubectl --context k3d-svp -n svp-data logs "$PG" -c plugin-barman-cloud --since=30m --tail=50
# 4. PVC còn bao nhiêu chỗ, pg_wal chiếm bao nhiêu
kubectl --context k3d-svp -n svp-data exec "$PG" -c postgres -- sh -c 'df -h /var/lib/postgresql/data; du -sh /var/lib/postgresql/data/pgdata/pg_wal'
# 5. MinIO và plugin có chạy không
kubectl --context k3d-svp -n svp-data get pods -l app.kubernetes.io/name=minio
kubectl --context k3d-svp -n cnpg-system get pods -l app.kubernetes.io/name=plugin-barman-cloud
```

Prometheus (k3d, `make k8s-ui-prometheus`):

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=increase(cnpg_pg_stat_archiver_failed_count[15m])' | jq -c '.data.result[] | [.metric.pod, .value[1]]'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=cnpg_collector_pg_wal_archive_status' | jq -c '.data.result[] | [.metric.pod, .metric.value, .value[1]]'
```

`cnpg_collector_pg_wal_archive_status{value="ready"}` là số segment đang chờ lưu: tăng đều là WAL đang dồn.

## Nguyên nhân thường gặp

1. **MinIO không chạy hay chưa Ready** (pod `minio-0` restart, PVC của MinIO đầy). Dấu hiệu: log sidecar có lỗi kết nối tới
   `minio.svp-data:9000`, bước 5 MinIO không `Running`.
2. **Credential lệch**: `SVP_PG_BACKUP_S3_SECRET_KEY` trong `.env` đổi, `make k8s-secrets` đã cập nhật Secret
   `svp-data/pg-backup-s3` nhưng Job `minio-init` chưa chạy lại để đặt key mới cho user `svp-pg-backup` (hay ngược lại).
   Dấu hiệu: log sidecar có `InvalidAccessKeyId`, `SignatureDoesNotMatch` hay `AccessDenied`.
3. **Đích lưu không rỗng** ("Expected empty archive"): Cluster `svp-pg` được tạo lại (initdb hay phục hồi) mà vẫn dùng
   `serverName` của một thế hệ đã có WAL. Dấu hiệu: log sidecar hay log của Job phục hồi nêu archive không rỗng; thường sau
   một lần phục hồi làm tay không đổi `postgres.backup.serverName`.
4. **Bucket `pg-backups` không có** (dữ liệu MinIO bị xoá, `minio-init` chưa chạy). Dấu hiệu: `NoSuchBucket` trong log.
5. **NetworkPolicy chặn**: policy `postgres-backup` (egress Postgres → MinIO 9000) hay rule ingress `cnpg.io/cluster: svp-pg`
   của policy `minio` (chart `svp-data`) bị sửa hay thiếu. Dấu hiệu: log sidecar quá hạn kết nối, MinIO vẫn chạy.

## Giảm thiểu

Chưa có gì cần làm cho người dùng; việc gấp là để PVC không đầy trước khi sửa xong:

- Bước 4 thấy PVC dùng > 80%: ưu tiên sửa nguyên nhân ngay; PVC `local-path` không mở rộng được tại chỗ. Không xoá file trong
  `pg_wal` bằng tay (mất WAL là mất khả năng phục hồi, có thể hỏng database).
- Không tắt lưu WAL (bỏ plugin khỏi Cluster) để "chữa cháy": WAL dồn sẽ được xoá nhưng đường lui mất hẳn.

## Khôi phục và xác nhận

Cảnh báo cháy ở cả hai đường k3d. Trước hết biết cluster đi đường nào: có Application `svp-root` là cluster GitOps, `make k8s-up`
từ chối nó (`deploy/k8s/install.sh`); các bước tay thay cho nó ở đầu `deploy/k8s/gitops.sh`.

```sh
kubectl --context k3d-svp -n argocd get applications.argoproj.io svp-root    # NotFound: đường dev
```

Ở dưới, "áp lại chart `svp-data`" là `make k8s-up` trên đường dev; trên cluster GitOps là một lần sync Application `svp-data`
(chạy lại các Job init của nó, gồm `minio-init`):

```sh
kubectl --context k3d-svp -n argocd patch applications.argoproj.io svp-data --type merge -p '{"operation":{"sync":{}}}'
kubectl --context k3d-svp -n argocd get applications.argoproj.io svp-data -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
```

- Nguyên nhân 1: `kubectl --context k3d-svp -n svp-data rollout restart statefulset/minio` hay sửa PVC của MinIO; rồi chờ.
- Nguyên nhân 2: sửa `.env` cho đúng (hay giữ giá trị mới), rồi `make k8s-secrets` và áp lại chart `svp-data`: Job `minio-init`
  đặt lại key của user `svp-pg-backup` theo `.env`.
- Nguyên nhân 3: Cluster đang chạy phải lưu vào thế hệ mới, rỗng. Đường dev: cách an toàn là phục hồi lại theo
  [postgres-restore.md](postgres-restore.md) với `serverName` mới; không xoá object của thế hệ cũ. Cluster GitOps: Argo CD giữ
  `serverName` theo git, nên quy trình đó không dùng được. Không xoá gì (Cluster, PVC, Backup, object của bucket) và không dựng
  lại cluster: Cluster vừa được tạo lại thì backup của thế hệ cũ là bản duy nhất của dữ liệu; làm theo
  [Leo thang của postgres-restore.md](postgres-restore.md#leo-thang).
- Nguyên nhân 4: áp lại chart `svp-data` (Job `minio-init` tạo bucket và user). Nếu dữ liệu MinIO đã mất thì backup cũ cũng
  mất: lấy ngay một backup cơ sở mới (lệnh ở [postgres-backup-too-old.md](postgres-backup-too-old.md)).
- Nguyên nhân 5: đường dev `make k8s-up` áp lại NetworkPolicy của chart. Cluster GitOps: policy bị sửa tay thì self-heal của
  Argo CD trả về bản trong git (hay sync như trên); policy sai nằm trong git thì sửa bằng PR (hoàn tác bằng PR revert).

Xác nhận: archiver tự thử lại segment đang kẹt, không cần làm gì thêm.

```sh
kubectl --context k3d-svp -n svp-data exec "$PG" -c postgres -- psql -X -A -U postgres -c 'select last_archived_wal, last_archived_time, last_failed_time from pg_stat_archiver'
kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="PostgresWALArchivingFailing"' | jq -c '.[] | [.status.state, .startsAt]'
```

`last_archived_time` sau `last_failed_time`, `ContinuousArchiving` `True`, cảnh báo hết ở lượt đánh giá kế. Sau đó lấy một
backup cơ sở để có điểm phục hồi mới (lệnh ở [postgres-backup-too-old.md](postgres-backup-too-old.md)).

## Leo thang

- Postgres đã dừng vì PVC đầy: service lỗi 5xx, chuyển sang sự cố có tác động người dùng; mở postmortem
  ([mẫu](../postmortems/README.md)). Phục hồi từ backup ([postgres-restore.md](postgres-restore.md)) chỉ khi database không
  khởi động lại được.
- Lỗi lặp lại mà không rõ nguyên nhân: log của plugin `kubectl --context k3d-svp -n cnpg-system logs deployment/plugin-barman-cloud --since=1h`
  và của operator `kubectl --context k3d-svp -n cnpg-system logs deployment/cloudnative-pg --since=1h | grep -i barman`; ghi
  lại cho postmortem.
- Không có ai khác dùng chung: Postgres và MinIO này chỉ thuộc cluster lab.

## Liên kết

- ADR: [ADR-0020](../adr/0020-reliability-stage6.md) §5 (plugin, thế hệ lưu trữ, NetworkPolicy, cảnh báo); threat model BAK-1.
- Cấu hình: `deploy/helm/svp-data/templates/backup.yaml` (ObjectStore, ScheduledBackup), `templates/postgres.yaml` (plugin
  của Cluster), `deploy/k8s/values/plugin-barman-cloud.yaml`, `deploy/minio/pg-backup-policy.json`.
- Diễn tập: `make drill-k8s-backup` dừng trước khi xoá gì nếu `ContinuousArchiving` không `True`; chưa có diễn tập làm hỏng
  việc lưu WAL có chủ đích.
