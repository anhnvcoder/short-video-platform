# PostgresBackupTooOld

- Severity: `ticket` (chỉ hiện ở Alertmanager, không gửi Telegram). Rule: nhóm `postgres-backup` của
  `deploy/observability/prometheus/rules/svp-alerts.yaml`, 2 biến thể.
- Chỉ có ở cluster k3d ([ADR-0020](../adr/0020-reliability-stage6.md) §5); compose không backup Postgres.
- Chuẩn bị biến `PROM`, `AM` (phần k3d): [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

Metric `barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` (plugin Barman Cloud, thời điểm backup cơ sở mới nhất
của thế hệ lưu trữ đang chạy; 0 khi chưa có cái nào):

- `backup="stale"`: backup cơ sở mới nhất cũ hơn 26 giờ (lịch `svp-pg-daily` 03:00 UTC mỗi ngày, cộng 2 giờ);
- `backup="none"`: chưa có backup cơ sở nào suốt 1 giờ. `ScheduledBackup` có `immediate: true` và là hook của chart, tạo sau
  Job `s3-init` (bucket, login đã có), nên cluster mới có backup đầu sau vài phút; trên đường dev `make k8s-up` còn tự lấy
  một backup khi thế hệ đang chạy chưa có. 0 lâu là backup đầu lỗi.

Người dùng không thấy gì. WAL vẫn được lưu (nếu không, đã có [PostgresWALArchivingFailing](postgres-wal-archiving-failing.md)),
nên vẫn phục hồi được; chỉ là phục hồi bắt đầu từ backup cơ sở cũ đó và phải phát lại nhiều WAL hơn (RTO dài ra).

## Kiểm tra nhanh (5 phút)

Compose: không có.

k3d:

```sh
# 1. Các Backup gần nhất, pha và lỗi
kubectl --context k3d-svp -n svp-data get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startedAt,STOPPED:.status.stoppedAt,ERROR:.status.error | tail -5
# 2. Lịch: lần chạy gần nhất, lần kế
kubectl --context k3d-svp -n svp-data get scheduledbackups.postgresql.cnpg.io svp-pg-daily -o jsonpath='{.spec.schedule} last={.status.lastScheduleTime} next={.status.nextScheduleTime}{"\n"}'
# 3. Cửa sổ phục hồi theo từng thế hệ trong bucket
kubectl --context k3d-svp -n svp-data get objectstores.barmancloud.cnpg.io svp-pg-backup -o jsonpath='{.status.serverRecoveryWindow}' | jq .
# 4. Thế hệ đang chạy
kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.spec.plugins[0].parameters.serverName}{"\n"}'
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=barman_cloud_cloudnative_pg_io_last_available_backup_timestamp' | jq -c '.data.result[] | [.metric.pod, .value[1]]'
```

## Nguyên nhân thường gặp

1. **Cluster tắt lúc 03:00 UTC** (máy tắt, `k3d cluster stop`): CloudNativePG không chạy bù lịch đã lỡ. Dấu hiệu: bước 1
   không có Backup nào của hôm đó, không có lỗi. Đây là trường hợp thường gặp nhất ở lab.
2. **Backup lỗi**: bước 1 có `PHASE` `failed` và `ERROR`; thường cùng nguyên nhân với lưu WAL lỗi (object store `s3`, credential,
   NetworkPolicy): xem [postgres-wal-archiving-failing.md](postgres-wal-archiving-failing.md). Trên cluster có từ trước plugin,
   Backup `immediate` đầu có thể lỗi vì chạy trên pod Postgres cũ chưa có sidecar; CloudNativePG không chạy lại Backup lỗi, còn
   `make k8s-up` (đường dev) lấy một backup thay nó; cluster GitOps không có bước đó.
3. **Thế hệ mới chưa có backup** (`backup="none"` sau một lần phục hồi làm tay): lần nâng chart tạo lại `ScheduledBackup`,
   nhưng CloudNativePG nhận lại Backup `immediate` cũ thay vì chạy cái mới; `make drill-k8s-backup` và `make k8s-up` tự lấy
   backup cho thế hệ mới (đường dev), làm tay thì lấy (bước dưới).
4. **Plugin không chạy** (`cnpg-system/plugin-barman-cloud`): Backup đứng ở pha đầu không tiến.

## Giảm thiểu

Lấy ngay một backup cơ sở theo yêu cầu, rồi chờ `completed` (vài phút với lab):

```sh
cat <<EOF | kubectl --context k3d-svp -n svp-data create -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: svp-pg-manual-$(date -u +%Y%m%d%H%M%S)
spec:
  cluster:
    name: svp-pg
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl --context k3d-svp -n svp-data get backups.postgresql.cnpg.io -w
```

## Khôi phục và xác nhận

Cluster GitOps (có Application `svp-root`: `kubectl --context k3d-svp -n argocd get applications.argoproj.io svp-root`):
`make k8s-up` bị từ chối (`deploy/k8s/install.sh`) nên không có gì tự lấy backup thay; dùng lệnh ở Giảm thiểu, như nhau ở
hai đường. Sửa cấu hình (Secret, bucket) trên cluster đó theo nhánh GitOps của
[postgres-wal-archiving-failing.md](postgres-wal-archiving-failing.md#khôi-phục-và-xác-nhận).

- Nguyên nhân 1: backup theo yêu cầu ở trên là đủ; lịch chạy lại đêm sau.
- Nguyên nhân 2, 4: sửa theo [postgres-wal-archiving-failing.md](postgres-wal-archiving-failing.md), rồi lấy backup như trên.
- Nguyên nhân 3: lấy backup như trên.

Xác nhận: Backup mới có `PHASE` `completed`; metric ở bước 4 bằng thời điểm của nó (Prometheus scrape 15 s một lần); cảnh báo
hết ở lượt đánh giá kế:

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="PostgresBackupTooOld"' | jq -c '.[] | [.labels.backup, .status.state, .startsAt]'
```

## Leo thang

- Backup theo yêu cầu cũng lỗi mà WAL vẫn lưu được: log sidecar
  `kubectl --context k3d-svp -n svp-data logs "$(kubectl --context k3d-svp -n svp-data get cluster svp-pg -o jsonpath='{.status.currentPrimary}')" -c plugin-barman-cloud --since=1h`
  và log plugin `kubectl --context k3d-svp -n cnpg-system logs deployment/plugin-barman-cloud --since=1h`; ghi lại, không xoá
  Backup hay object nào để "dọn".
- Ticket, không gọi người dậy; ở lab không có ai khác cần biết.

## Liên kết

- ADR: [ADR-0020](../adr/0020-reliability-stage6.md) §5 (lịch, `immediate`, retention, cảnh báo).
- Cấu hình: `deploy/helm/svp-data/templates/backup.yaml`; backup đầu trên đường dev: `deploy/k8s/install.sh`
  (`pg_base_backup`).
- Diễn tập: `make drill-k8s-backup` lấy backup theo yêu cầu ở bước 2 và bước 9 (thế hệ mới); chưa có diễn tập cho lịch bị lỡ.
