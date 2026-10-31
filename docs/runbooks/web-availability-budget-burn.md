# WebAvailabilityBudgetBurn

- Severity: `page` (runbook này) và `ticket` (cùng tên, chỉ ở Alertmanager). Rule sinh bằng Sloth từ SLO `web-availability` của
  `deploy/observability/slo/svp-slos.yaml` (`make slo`).
- Chuẩn bị biến `PROM`, `AM`, hàm `dc`: [README](README.md#chuẩn-bị-trong-terminal).

## Ý nghĩa và tác động tới người dùng

SLO: 99,9% response của server web (Next.js: trang, Server Action, `/rum`, `/monitoring`, `/healthz`, asset `/_next/static`)
không phải 5xx trong 30 ngày. Page cháy khi tỉ lệ 5xx vượt **1,44%** trên cả 1 giờ và 5 phút, hoặc **0,6%** trên cả 6 giờ và
30 phút ([ADR-0020](../adr/0020-reliability-stage6.md) §3, [ADR-0011](../adr/0011-observability-stage3.md) §8).

Histogram của web không có nhãn route, nên không biết từ metric là trang nào lỗi; probe và asset (gần như luôn 200) pha loãng
tỉ lệ, nên khi cảnh báo này cháy thì tỉ lệ lỗi của trang thật còn cao hơn con số trên.

Truy vấn 5xx ở dưới không ra dòng nào là bình thường khi không có 5xx. Còn
`sum(rate(http_server_request_duration_seconds_count{service_name="web"}[5m]))` không có series trong lúc web đang nhận request
thì web không ghi histogram (instrumentation http không vá được module `http`, ADR-0020 §3): SLO mù, cảnh báo này không thể cháy.

Người dùng: trang web trắng hay trang lỗi, đăng nhập, đăng video, like từ web thất bại. Client gọi thẳng API của gateway (như
`make smoke`) không bị ảnh hưởng khi chỉ web lỗi.

## Kiểm tra nhanh (5 phút)

Compose (web ở `http://localhost:3001`):

```sh
curl -sG "$AM/api/v2/alerts" --data-urlencode 'filter=alertname="WebAvailabilityBudgetBurn"' | jq -c '.[] | [.labels.severity, .status.state, .startsAt]'
# 5xx theo method và mã (GET: trang, asset; POST: Server Action, /rum, /monitoring)
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=sum by (http_request_method, http_response_status_code) (rate(http_server_request_duration_seconds_count{service_name="web",http_response_status_code=~"5.."}[5m]))' | jq -c '.data.result[] | [.metric.http_request_method, .metric.http_response_status_code, .value[1]]'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3001/healthz
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3001/login
make ps
make logs SVC=web
# web gọi gateway: gateway khoẻ không, có cảnh báo khác cùng lúc không
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
curl -s "$AM/api/v2/alerts" | jq -c '.[] | [.labels.alertname, .labels.severity, .status.state]'
# phiên web nằm ở Redis native db 9
redis-cli -h 127.0.0.1 -p 6379 -n 9 ping
```

k3d (web ở `https://svp.localhost:8443`, CA `.k8s/ca.crt`, thiếu thì `make k8s-ca`):

```sh
curl -s --cacert .k8s/ca.crt -o /dev/null -w '%{http_code}\n' https://svp.localhost:8443/login
kubectl --context k3d-svp -n svp get pods -l app.kubernetes.io/name=web -o wide
kubectl --context k3d-svp -n svp get rollout web
kubectl --context k3d-svp -n svp logs -l app.kubernetes.io/name=web --since=15m --tail=1000
kubectl --context k3d-svp -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 9 ping
```

Lỗi server của web tới GlitchTip (`http://127.0.0.1:8000`, k3d: `make k8s-ui-glitchtip`) với frame đã map nếu đã tải source map;
trace của web và gateway ở Tempo. Dashboard `svp-slo`; `svp-web` cho trải nghiệm phía trình duyệt (RUM).

## Nguyên nhân thường gặp

1. **Gateway hay service phía sau lỗi**: BFF của web gọi gateway; gateway 5xx hay không tới được làm trang và Server Action
   lỗi. Dấu hiệu: cảnh báo SLO hay `CircuitBreakerOpen` khác cùng cháy, `/readyz` của gateway không 200.
2. **Container/pod web chết, restart lặp hay hết RAM**: `make ps` / `get pods` thấy restart, log có lỗi khởi động.
3. **Redis của phiên lỗi** (compose: db 9 Redis native; k3d: Valkey db 9): đọc hay ghi phiên thất bại.
4. **Khoá Server Action lệch giữa các replica** (k3d, 2 replica) hay đổi giữa chừng: Server Action giải mã thất bại. Khoá là
   `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` (compose từ `.env`, k3d Secret `svp/web-env`).
5. **Bản phát hành web mới lỗi**: bắt đầu ngay sau deploy; trên k3d Rollout `web` có canary.

## Giảm thiểu

- Gateway hay service lỗi: theo runbook của cảnh báo đó trước; web tự hồi khi gateway hồi.
- Web chết: compose `dc restart web` hay `make up OBS=lgtm`. k3d (2 replica, PDB `minAvailable: 1`): **không** xoá pod theo
  nhãn, lệnh đó xoá cả hai pod cùng lúc, bỏ qua PDB, kể cả pod còn phục vụ. Một pod lỗi mà pod kia Ready: xoá đúng pod lỗi
  (`kubectl --context k3d-svp -n svp delete pod <tên pod lỗi>`, tên lấy từ `get pods` ở trên), Rollout tạo pod mới. Cần chạy lại
  cả hai: restart tuần tự bằng `spec.restartAt` (Argo Rollouts evict từng pod qua PDB, không đổi pod template nên không có
  revision mới hay canary, như `restart_workload` của `deploy/k8s/lib.sh`):

```sh
at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl --context k3d-svp -n svp patch rollout web --type merge -p "{\"spec\":{\"restartAt\":\"$at\"}}"
# xong khi in "<giá trị $at> Healthy" (deploy/k8s/lib.sh chờ tối đa 300 s)
kubectl --context k3d-svp -n svp get rollout web -o jsonpath='{.status.restartedAt} {.status.phase}{"\n"}'
```

- Khoá Server Action lệch giữa hai pod: chạy lại cả hai pod để cùng đọc Secret `svp/web-env` hiện tại (khối `spec.restartAt` ở
  trên). `.env` đã đổi khoá mà Secret chưa: `make k8s-secrets` trước (kiểm dạng base64 32 byte, không in giá trị); rồi đường dev
  `make k8s-up` (restart web khi Secret đổi), cluster GitOps (có Application `argocd/svp-root`, `make k8s-up` từ chối nó) dùng
  khối `spec.restartAt`. Không đổi khoá khi không cần (người dùng đang mở form phải tải lại trang).
- Lỗi sau deploy: quay về bản trước (GitOps: PR revert commit promote; canary đang chạy thì để phân tích abort).

## Khôi phục và xác nhận

```sh
curl -sG "$PROM/api/v1/query" --data-urlencode 'query=slo:sli_error:ratio_rate5m{sloth_slo="web-availability"}' | jq -c '.data.result[] | .value[1]'
make web-e2e        # compose: Playwright trên Chromium và WebKit, e2e của bản clone svp-web (../frontend hay SVP_WEB_DIR)
                    # (LOCAL LAB ONLY: seed xoá khoá rate limit đăng ký)
make k8s-web-e2e    # k3d, cùng bản clone
```

Tỉ lệ 5xx 5 phút về 0, page hết trong tối đa ~30 phút.

## Leo thang

- Page của SLO này mở postmortem; ghi rõ tỉ lệ đo được là của mọi response (không lọc route).
- Lỗi chỉ ở web mà gateway khoẻ và log web không cho biết nguyên nhân: lấy event GlitchTip và trace của request lỗi, so bản
  build (`SVP_BUILD_ID`, `release` của GlitchTip) với lần chạy tốt trước.

## Liên kết

- Dashboard: `svp-slo`, `svp-web`, `svp-red`.
- ADR: [ADR-0020](../adr/0020-reliability-stage6.md) §3 (SLI của web), [ADR-0016](../adr/0016-web-client.md) (web client, BFF),
  [ADR-0019](../adr/0019-web-k3d-supply-chain-observability.md) (web trên k3d, GlitchTip, source map).
- Diễn tập, đo: chưa có diễn tập làm cảnh báo này cháy. `make web-e2e`, `make k8s-web-e2e`; tải `make load-local` (k6 gồm web,
  ADR-0020 §2).
