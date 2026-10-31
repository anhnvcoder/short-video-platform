# Runbook

Runbook là trang người trực mở đầu tiên khi có cảnh báo hay sự cố: cảnh báo này nghĩa là gì, người dùng đang mất gì, kiểm gì
trong 5 phút đầu, làm gì để giảm thiểu rồi khôi phục, khi nào dừng tự xử lý. Runbook không giải thích lại thiết kế: lý do nằm
ở ADR, runbook dẫn tới đó.

Ở dự án này người trực là người học, chạy trên một máy (stack compose hay cluster k3d `svp`). Mỗi cảnh báo `severity=page`
có đúng một runbook, link nằm trong annotation `runbook_url` của rule nên thông báo Telegram và giao diện Alertmanager dẫn
thẳng tới đây. Sự cố đã gặp mà chưa có cảnh báo riêng, và quy trình vận hành làm tay, cũng có runbook theo cùng mẫu.

## Mẫu cố định

Mỗi runbook có đủ các mục sau, theo đúng thứ tự (mục nào không áp dụng thì ghi "Không có" và lý do):

1. **Ý nghĩa và tác động tới người dùng**: điều kiện của rule bằng lời (hay dấu hiệu, với sự cố không có cảnh báo), người
   dùng thấy gì, thứ gì vẫn chạy. Một alertname có nhiều rule thì nêu từng biến thể.
2. **Kiểm tra nhanh (5 phút)**: lệnh và truy vấn chép được cho **compose** và **k3d**, theo thứ tự nên chạy, kèm cách đọc
   kết quả.
3. **Nguyên nhân thường gặp**: theo thứ tự hay gặp, mỗi cái có dấu hiệu nhận ra trong kết quả của bước 2.
4. **Giảm thiểu**: bước làm ngay để người dùng bớt bị ảnh hưởng, kể cả khi chưa biết nguyên nhân gốc.
5. **Khôi phục và xác nhận**: đưa hệ thống về bình thường và bằng chứng đã về (truy vấn, cảnh báo resolve, `make smoke`).
6. **Leo thang**: khi nào dừng xử lý tại chỗ, bước nặng hơn là gì, ai cần biết (dự án khác dùng chung Redis, Postgres native),
   khi nào mở postmortem ([mẫu](../postmortems/README.md)).
7. **Liên kết**: dashboard, ADR, diễn tập tái hiện được sự cố (`make drill-…`, `make measure-…`); không có diễn tập thì ghi
   rõ.

Số liệu trong runbook (ngưỡng, thời gian đo được) lấy từ ADR hay mục Tiến độ của roadmap, ghi nguồn ngay cạnh.

## Tên file

- Runbook của cảnh báo: tên alert viết kebab-case, chữ viết tắt giữ thành một khối: `CircuitBreakerOpen` →
  `circuit-breaker-open.md`, `KafkaDLQRecords` → `kafka-dlq-records.md`.
- Sự cố và quy trình: slug ngắn mô tả dấu hiệu hay việc làm, ví dụ `kyverno-down.md`, `jwt-key-rotation.md`.
- `runbook_url` của rule là `https://github.com/anhnvcoder/svp-backend/blob/main/docs/runbooks/<file>.md`: link đọc
  từ `main`, nên runbook sửa trên nhánh chỉ có hiệu lực ở link sau khi merge. Thêm cảnh báo page mới thì thêm runbook và
  `runbook_url` trong cùng thay đổi (rule viết tay: `deploy/observability/prometheus/rules/svp-alerts.yaml`; SLO:
  `page_alert.annotations` của `deploy/observability/slo/svp-slos.yaml` rồi `make slo`), và thêm `runbook_url` vào
  `exp_annotations` của ca test trong `svp-alerts.test.yaml`.

## Chuẩn bị trong terminal

Các runbook dùng chung ba biến và một hàm. Chạy ở gốc repo.

Compose (`make up OBS=lgtm`; Prometheus không publish cổng, truy vấn đi qua datasource proxy của Grafana, chỉ loopback). Dòng
`unalias dc` cần khi shell đã có alias `dc` (máy của dự án có `dc=docker-compose`): zsh báo `defining function based on alias`
và không định nghĩa hàm, còn `dc …` sau đó gọi `docker-compose` không có các cờ dưới đây. Dán từng dòng hay cả khối vào
terminal đều được, chỉ không gộp `unalias` và định nghĩa hàm vào một dòng (alias được thay khi đọc dòng, trước khi `unalias`
chạy):

```sh
PROM=http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus
AM=http://127.0.0.1:9093
unalias dc 2>/dev/null
dc() { env -u DOCKER_DEFAULT_PLATFORM docker compose --env-file .env -f deploy/compose/compose.yaml --profile core --profile obs "$@"; }
```

k3d (cluster `svp`; mỗi port-forward chạy ở một terminal riêng tới khi xong, Ctrl-C để đóng):

```sh
make k8s-ui-prometheus     # terminal 2: http://127.0.0.1:9090
make k8s-ui-alertmanager   # terminal 3: http://127.0.0.1:9093
make k8s-ui-grafana        # tuỳ chọn, terminal 4: http://127.0.0.1:3000, đăng nhập admin + SVP_GRAFANA_ADMIN_PASSWORD
PROM=http://127.0.0.1:9090
AM=http://127.0.0.1:9093
```

Truy vấn Prometheus và đọc cảnh báo đang cháy (cùng lệnh cho hai môi trường):

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=<PromQL>' | jq -c '.data.result[] | [.metric, .value[1]]'
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="<Alert>"' | jq -c '.[] | [.labels, .status.state, .startsAt]'
```

Dashboard: `http://127.0.0.1:3000/d/<uid>`, uid `svp-slo` (SLO), `svp-red` (RED HTTP, gRPC, trace), `svp-pipeline` (Kafka,
vòng nền, pipeline video, rate limit, breaker), `svp-use` (Go runtime, pool Postgres, pool Redis, Collector), `svp-web` (RUM).
Log: Grafana → Explore → Loki, `{service_name="<service>"} |= "<chuỗi>"`; hoặc `make logs SVC=<service>` (compose, 200 dòng
cuối) và `kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=<service> --since=15m --tail=2000` (k3d).

## Quy tắc cho lệnh trong runbook

- Docker và compose qua `make` (`make ps`, `make logs SVC=…`, `make up OBS=lgtm`); lệnh tay luôn có tiền tố
  `env -u DOCKER_DEFAULT_PLATFORM` (hàm `dc` ở trên). Không chạy `dc config` không có `--quiet`: nó in `.env` đã điền.
- `kubectl` luôn có `--context k3d-svp`; không lệnh nào vào cluster khác.
- Cổng ghi rõ trong lệnh: Redis native `redis-cli -h 127.0.0.1 -p 6379 -n <db>` (gateway db 10, feed-service db 14, web db
  9), Postgres native `-h 127.0.0.1 -p 5432`. Redis native và Postgres native **dùng chung với dự án khác**: không restart,
  không `FLUSHDB`/`FLUSHALL`, không xoá khoá ngoài hai tiền tố mà `CLAUDE.md` cho phép (`svp:gw:rl:register:*` ở db 10,
  `svp:feed:explore:*` ở db 14).
- Không in giá trị secret: không `cat .env`, không `env` trong container, không `kubectl get secret -o yaml`. Cần đổi secret
  thì sửa `.env` bằng trình soạn thảo rồi chạy target của Makefile.
- Lệnh chạm GitHub để ghi (dispatch workflow, mở PR, merge) và mọi lệnh chạm AWS/GCP do người học chạy; runbook ghi rõ
  "người học chạy".
- Diễn tập và `make smoke` xoá khoá rate limit đăng ký `svp:gw:rl:register:*`: **LOCAL LAB ONLY**, không trỏ vào stack dùng
  chung.
- Lệnh của runbook viết theo mã và tài liệu tại lúc viết; lệnh nào đã thử thật trong một buổi (game day, diễn tập) thì
  runbook ghi kèm ngày.

## Mục lục

Cảnh báo `severity=page` (rule viết tay ở `svp-alerts.yaml`, SLO ở `svp-slos.yaml`):

| Alert | Runbook | Nguồn rule |
| --- | --- | --- |
| `KafkaConsumerLagHigh` | [kafka-consumer-lag-high.md](kafka-consumer-lag-high.md) | `svp-alerts.yaml` (2 biến thể) |
| `RateLimitFallbackActive` | [rate-limit-fallback-active.md](rate-limit-fallback-active.md) | `svp-alerts.yaml` |
| `KafkaDLQRecords` | [kafka-dlq-records.md](kafka-dlq-records.md) | `svp-alerts.yaml` |
| `CircuitBreakerOpen` | [circuit-breaker-open.md](circuit-breaker-open.md) | `svp-alerts.yaml` |
| `BackgroundLoopStalled` | [background-loop-stalled.md](background-loop-stalled.md) | `svp-alerts.yaml` (4 biến thể) |
| `FeedAvailabilityBudgetBurn` | [feed-availability-budget-burn.md](feed-availability-budget-burn.md) | SLO `feed-availability` |
| `UploadInitAvailabilityBudgetBurn` | [upload-init-availability-budget-burn.md](upload-init-availability-budget-burn.md) | SLO `upload-init-availability` |
| `FeedLatencyBudgetBurn` | [feed-latency-budget-burn.md](feed-latency-budget-burn.md) | SLO `feed-latency` |
| `VideoReadyLatencyBudgetBurn` | [video-ready-latency-budget-burn.md](video-ready-latency-budget-burn.md) | SLO `video-ready-latency` |
| `WebAvailabilityBudgetBurn` | [web-availability-budget-burn.md](web-availability-budget-burn.md) | SLO `web-availability` |
| `PostgresWALArchivingFailing` | [postgres-wal-archiving-failing.md](postgres-wal-archiving-failing.md) | `svp-alerts.yaml`, nhóm `postgres-backup` (chỉ k3d) |
| `ArgoCDApplicationDegraded` | [argocd-application-degraded.md](argocd-application-degraded.md) | `svp-alerts.yaml`, nhóm `argocd` (chỉ cluster GitOps) |

Cảnh báo `ticket` (cùng tên với page của SLO, cửa sổ 1 d/2 h và 3 d/6 h, chỉ hiện ở Alertmanager) dùng chung runbook của
SLO đó; `WebINPBudgetBurn` chỉ có ticket và không có runbook riêng (dashboard `svp-web`, [ADR-0020](../adr/0020-reliability-stage6.md) §3).
Cảnh báo ticket viết tay `PostgresBackupTooOld` (nhóm `postgres-backup`, chỉ k3d, 2 biến thể) có runbook
[postgres-backup-too-old.md](postgres-backup-too-old.md); `ArgoCDApplicationNotConverged` (nhóm `argocd`, chỉ cluster GitOps) dùng chung
[argocd-application-degraded.md](argocd-application-degraded.md).

Sự cố đã gặp và quy trình:

| Runbook | Khi nào mở |
| --- | --- |
| [k3s-server-down-under-transcode.md](k3s-server-down-under-transcode.md) | API server k3d không trả lời, container `k3d-svp-server-0` restart khi nhiều media-worker cùng transcode |
| [liveness-timeout-cpu-saturation.md](liveness-timeout-cpu-saturation.md) | Pod k3d bị restart vì probe quá hạn trong lúc node bận CPU |
| [explore-cache-redis-timeout.md](explore-cache-redis-timeout.md) | `make measure-explore-cache` FAIL hay đếm thừa lần đọc Postgres; WARN `read explore cache` |
| [github-push-run-missing.md](github-push-run-missing.md) | Merge vào `main` mà không có lượt `images.yml`/`ci.yml` của push |
| [kyverno-down.md](kyverno-down.md) | Pod `svp` mới bị từ chối vì webhook Kyverno không trả lời, hay webhook biến mất |
| [vuln-attestation-expired.md](vuln-attestation-expired.md) | Kyverno từ chối pod vì attestation `vuln` quá 72 giờ; `make k8s-gitops-up` dừng vì attestation cũ |
| [jwt-key-rotation.md](jwt-key-rotation.md) | Đổi khoá ký JWT theo `kid` (định kỳ hay khi nghi lộ khoá) |
| [postgres-restore.md](postgres-restore.md) | Postgres `svp-pg` của k3d mất hay hỏng, cần PITR, hay `make drill-k8s-backup` dừng giữa chừng |
| [svp-gitops-setup.md](svp-gitops-setup.md) | Dựng hay kiểm cài đặt GitHub của `svp-gitops` (App `svp-gitops-promoter`, environment `promote`, ruleset), promote stg và prd, bản ghi stg, rollback, bump commit chart và checker, việc tay khi đổi tên repo code và repo web (C6), xoay khoá App, nghi khoá App bị lộ |
| [svp-frontend-setup.md](svp-frontend-setup.md) | Dựng hay kiểm cài đặt GitHub của repo web `svp-frontend` (repo rỗng, cài đặt, App `svp-web-promoter`, environment `promote`, package GHCR public, Renovate, CodeQL, ruleset), PR tiếp quản `bot/promote-stg-web`, 12 package GHCR mới public sau đổi tên repo (E1), xoay khoá App web, nghi khoá App web bị lộ |

## Sau sự cố

Mỗi sự cố có cảnh báo page, và mỗi buổi game day, có postmortem theo [mẫu](../postmortems/README.md). Chỗ runbook thiếu hay
sai mà sự cố lộ ra được sửa ngay sau buổi đó, và postmortem ghi lại đã sửa gì.
