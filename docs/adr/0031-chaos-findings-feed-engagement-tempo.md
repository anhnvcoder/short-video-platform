# 0031. Sửa ba phát hiện của Chaos Mesh và k6 trên runner: feed-service luôn hai replica, engagement-service lỗi nhanh có kiểm soát khi Postgres chậm hay mất, Tempo tự giới hạn bộ nhớ, không sampling

- Trạng thái: Chấp nhận (người học duyệt 2026-10-29); chưa hiện thực, kiểm trên runner sau push (mục Kết quả)
- Ngày: 2026-10-29

## Bối cảnh

Phần 3 của giai đoạn 6b chạy kịch bản `chaos` và `k6-cloud-mini` của [ADR-0021](0021-deferred-verification-stage6b.md) trên runner
`ubuntu-24.04` (4 vCPU, amd64; Chaos Mesh và Job k6 trên k3d của runner, [ADR-0020](0020-reliability-stage6.md) §7). Kết quả ở
ADR-0020, mục Kết quả "Chaos Mesh trên runner" và "k6 thu nhỏ trên runner". Ba phát hiện dưới đây; số đọc từ artifact của các lượt
nêu tên.

**feed-service một replica.**

- Lượt [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895), thí nghiệm (a) kill pod (`pod-kill`,
  `mode: one`, `gracePeriod: 0`) dưới k6 1 pod: feed-service lúc đó HPA 1–2 theo CPU 70 %, không PDB
  ([ADR-0014](0014-kubernetes-local-stage4.md) §10), lúc kill chỉ có 1 replica; pod thay Ready sau 2 s. Feed 5xx **0,28 %** trong cửa sổ
  10 phút quanh lần kill (giả thuyết < 0,1 %), k6 explore và following lỗi 0,33 % cả lượt, p99 9,6 → 9,5 ms, không cảnh báo page.
  Cùng lượt, gateway (2 replica lúc kill) qua lần kill với feed 5xx 0.
- Gateway thử lại `GetExploreFeed`, `GetFollowingFeed` khi `UNAVAILABLE`, tối đa 3 lần, chờ 0,05 s rồi 0,1 s nhân hệ số ngẫu nhiên
  0,8–1,2 (mục Kiểm chứng), và `retryThrottling` ngừng thử lại sau vài lỗi (ADR-0010 §4): tổng chờ khoảng 0,15 s, tối đa 0,18 s, hết trước 2 s
  không có pod nào Ready.
- Một pod feed-service trên runner (mẫu 30 s của `kubectl top`, `pods.tsv` của sampler): working set tối đa **35 MiB**, CPU tối đa
  116m ở `k6-cloud-mini` [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867) (ở lượt đó HPA đã
  chạy pod thứ hai suốt phần sau của lượt), 24 MiB và 56m ở lượt chaos trên. Request 100m / 64 Mi, limit 1 / 256 Mi.

**engagement-service khi Postgres chậm.**

- Lượt 40712072895, thí nghiệm (b): `NetworkChaos` `delay` 200 ± 20 ms, không `target`, 5 phút trên pod engagement-service: mọi gói
  pod đó gửi đi bị chậm, cả gói tới Postgres. Feed giữ (200, `stats` vắng, 5xx 0, p99 149,1 ms); breaker không mở,
  `CircuitBreakerOpen` không cháy. Nhưng **556 / 2 149** request like + view trả 5xx: like lỗi 18,5 %, p99 3 004 ms, đúng `callTimeout`
  3 s của gateway nên thành 504; view 0 lỗi (`RecordView` chỉ produce, không chạm Postgres), p99 455 ms.
- Đọc code ở `64554bb`: Like, Unlike là một transaction `Begin`, `InsertLike`/`DeleteLike`, `IncrementLikeCount`/`DecrementLikeCount`
  khi dòng thật sự đổi, `Commit` (`inTx` của `services/engagement-service/internal/server/server.go`): 4 round trip nối tiếp trên kết nối
  ấm, mỗi round trip ≥ 200 ms dưới thí nghiệm. Pool là mặc định của pgx, max(4, NumCPU) = 4 trên runner (URL chỉ đặt
  `sslmode=require`, `pg_url` của `deploy/k8s/secrets.sh`), dùng chung với `GetStats` mà gateway cắt ở 100 ms (`statsTimeout`) cho mỗi
  trang feed. Dưới trễ 200 ms mọi `GetStats` hết hạn giữa truy vấn, pgx đóng kết nối đó và pool phải dựng lại (TCP, TLS, SCRAM) trong
  khi Like chờ `Acquire`. Phần từ khoảng 1 s tới 3 s là suy luận từ code, **chưa đo**: artifact không có metric `pgxpool.*`.
- Breaker (`classify` của `services/gateway/internal/breaker/breaker.go`): `UNAVAILABLE` không `ErrorInfo` và `DEADLINE_EXCEEDED` là
  lỗi, trừ `DEADLINE_EXCEEDED` của `GetStats`. Like hết hạn được tính, nhưng view thành công xen giữa (k6 gửi view gấp đôi like) nên
  không có chuỗi 5 lỗi và tỉ lệ lỗi dưới 50 %: breaker đóng suốt. Mục tiêu của (b) ở ADR-0020 §7: feed vẫn sống, like và view không 5xx
  chậm, breaker chỉ mở khi engagement-service hỏng thật.

**Tempo OOM.**

- Container `tempo` của `svp-obs/tempo-0` (Tempo 3.1.0 single binary, metrics-generator `service-graphs` + `span-metrics`, request
  128 Mi, limit **768 Mi**, `deploy/k8s/values/tempo.yaml`) là pod `OOMKilled` duy nhất ở cả hai lượt chaos
  ([40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770) và 40712072895; mỗi thí nghiệm một lượt
  k6 1 pod, khoảng 55 req/s): lượt k6 của bản thử (khoảng 11 phút) không OOM, dòng OOM đầu tiên của kernel nằm trong lượt k6 của (a), cuối
  lượt Tempo đã restart 16 và 10 lần, `CrashLoopBackOff`.
- `k6-cloud-mini` 40620333867: mức 1 và 2 pod (mỗi mức lên 2 phút, giữ 10) không OOM; mức 4 pod (khoảng 220 req/s) Tempo chết trong 1–2
  phút đầu cửa sổ giữ, restart 6 lần, mỗi lần replay WAL nên không lên lại dưới tải.
- `MemAvailable` của runner thấp nhất 6,4–8,3 GiB ở các lượt đó: Tempo chạm limit của chính nó, máy không hết RAM. Runner ghi
  `no_oom=false`, nên các bước chaos đỏ dù thí nghiệm đạt và mức 4 pod ghi `fail: runner`.
- Không values nào đặt sampler (`OTEL_TRACES_SAMPLER` không có trong `deploy/`): service Go chạy mặc định của SDK, giữ mọi trace.
  Collector có `memory_limiter` đứng đầu pipeline traces (`deploy/observability/otelcol/k8s-config.yaml`).
- **Chưa đo:** sampler của runner không lấy namespace `svp-obs` vào `pods.tsv`, nên không có chuỗi RAM của Tempo; artifact không có
  metric ingest hay live traces của Tempo. Tốc độ span chỉ là ước lượng từ số span mỗi request (4–6 span mỗi request API): khoảng
  250–350 span/s ở 1 pod, 1 000–1 400 span/s ở 4 pod.

## Kiểm chứng (đã kiểm ngày 2026-10-29)

Không dựng stack hay cluster. Source của thư viện đọc trong module cache, đúng version ghim ở `go.mod`; code của repo đọc ở `64554bb`.

| Kiểm gì | Nguồn | Kết quả |
| --- | --- | --- |
| Thời gian thử lại của gateway | `retryConfig`, `feedBackend` của `services/gateway/cmd/gateway/main.go`; grpc-go v1.84.0 `stream.go` dòng 875–878 (`shouldRetry`) | `maxAttempts` 3, `initialBackoff` 0,05 s, `backoffMultiplier` 2; mỗi lần chờ nhân `0.8 + 0.4*rand`: 0,04–0,06 s rồi 0,08–0,12 s |
| Kết nối gateway → feed-service | `dial` của `main.go` (`grpc.NewClient`, `FEED_SERVICE_ADDR: feed-service:9104` ở `deploy/k8s/values/services/gateway.yaml`); grpc-go v1.84.0 `clientconn.go` dòng 272–273, `service_config.go` dòng 190–195 | `NewClient` dùng resolver `dns`; service config của gateway không đặt `loadBalancingConfig` nên là `pick_first`: tên của ClusterIP cho một địa chỉ, mỗi pod gateway một kết nối HTTP/2, kube-proxy chọn pod feed lúc kết nối mở. Gateway HPA 2–4 |
| Trải pod của chart | `deploy/helm/svp-service/templates/deployment.yaml` (`topologySpreadConstraints`), `templates/autoscaling.yaml` (`fail` khi có `pdb`) | `maxSkew: 1`, `topologyKey: kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway`: chỉ ưu tiên; chart từ chối `pdb` khi `hpa.minReplicas` < 2 |
| Chế độ thực thi của pgx | pgx v5.11.0 `conn.go` dòng 192, 524, 546 | Mặc định `QueryExecModeCacheStatement`; câu không tham số (`begin`, `commit`) đi simple protocol, 1 round trip; câu chưa có trong cache của kết nối thì `Prepare` rồi `execPrepared`: 2 round trip, đã có: 1 |
| Ping trước khi trao kết nối | pgx v5.11.0 `pgxpool/pool.go` dòng 265–266, 647 | `ShouldPing` mặc định: kết nối rảnh quá 1 s được ping trước khi `Acquire` trả về: thêm 1 round trip |
| Kích thước pool mặc định | pgx v5.11.0 `pgxpool/pool.go` dòng 384–385 | `MaxConns` = max(4, `runtime.NumCPU()`) khi URL không đặt `pool_max_conns` |
| Kết nối bị đóng khi hạn hết giữa truy vấn | pgx v5.11.0 `pgconn/config.go` dòng 472–473, `pgconn/pgconn.go` dòng 1919–1935 | Handler mặc định `DeadlineContextWatcherHandler` đặt deadline trên socket; `ResultReader` đọc lỗi thì `asyncClose` kết nối |
| Huỷ bằng cancel request | pgx v5.11.0 `pgconn/pgconn.go` dòng 1097–1112, 3089 | `CancelRequest` mở một kết nối mạng mới tới server để gửi lệnh huỷ |
| Puddle đếm cả kết nối đang dựng | puddle v2.2.2 `pool.go` dòng 354–410 (`acquire`), 413–470 (`initResourceValue`) | Lấy chỗ của semaphore `acquireSem` (cỡ `MaxSize`) trước `createNewResource`; constructor chạy trong goroutine với `newValueCancelCtx(ctx, p.baseAcquireCtx)` (dòng 422), không theo hạn của người gọi; chỗ chỉ được trả khi constructor lỗi (dòng 432) hay khi kết nối dựng xong được trả về pool (dòng 455) |
| Hạn dựng một kết nối | `internal/pgpool/pgpool.go` (`ConnectTimeout`) | 5 s khi URL không đặt `connect_timeout` |
| Pushback âm dừng thử lại | grpc-go v1.84.0 `stream.go` dòng 827, 833–840 | Chỉ xét khi response là Trailers-Only; trailer `grpc-retry-pushback-ms` không parse được hay âm thì không thử lại và trừ một token của `retryThrottling` |
| Luật thử lại lúc khởi động | `Retryable` của `internal/pgretry/pgretry.go` | Chỉ nhận lỗi bọc `*pgconn.ConnectError` (lỗi lúc mở kết nối); lỗi sau khi đã nối không phải `Retryable` |
| Số liệu của hai pool | otelpgx v0.13.0 `meter.go` dòng 43–53, `options.go` dòng 246 | Mặc định mỗi pool mang `db.client.connection.pool.name` = `host:port/database`: hai pool cùng URL cho cùng series; `WithStatsAttributes` thêm thuộc tính |
| Thứ tự khoá likes → like_counts | `services/engagement-service/migrations/00001_create_likes.sql` | Transaction khoá dòng `likes` trước, `like_counts` sau, nên like đồng thời trên một video không deadlock; `CHECK (like_count >= 0)` |
| Phần Tempo giữ trong bộ nhớ và tham số chặn | source Tempo v3.1.0, chart tempo 3.2.0 | Chưa đọc ở ADR này: phần hiện thực đọc source đúng tag ghim, ghi nguồn và phép tính ở comment của `deploy/k8s/values/tempo.yaml` |

## 1. feed-service luôn hai replica

### Các lựa chọn

#### A. Giữ HPA 1–2, ghi nhận

- Được: không thêm pod.
- Mất: mỗi lần pod duy nhất chết, bị evict hay node bị drain, feed lỗi tới khi pod thay Ready (đo được 2 s); PDB không
  đặt được (chart từ chối PDB dưới 2 replica).

#### B. HPA 2–2, PDB `minAvailable: 1`, ưu tiên trải hai node, như gateway

- Được: mất một pod còn một pod phục vụ; drain lấy từng pod một; cùng cách với gateway và web, không đổi chart.
- Mất: thêm một pod; hai pod vẫn có thể cùng node; tải chia theo kết nối, có thể lệch (mục Quyết định).

#### C. HPA 2–N với N > 2

- Được: co giãn khi tải tăng.
- Mất: ngoài phạm vi lượt sửa (mục tiêu là sống sót khi mất một pod) và ngân sách RAM của cluster trên máy 16 GB
  ([ADR-0014](0014-kubernetes-local-stage4.md) §2; đường GitOps đã không đạt (b), [ADR-0017](0017-gitops-capacity-media-worker-max2.md));
  replica thêm chỉ nhận tải từ kết nối mở sau khi nó Ready.

#### D. Cân bằng tải phía client ngay (Service headless, `round_robin`, `MaxConnectionAge` phía server)

- Được: mỗi pod gateway chia request cho mọi pod feed; pod mới nhận tải sớm.
- Mất: đổi chart (Service headless), dial của gateway và server gRPC của feed-service cho một vấn đề chưa thấy ở 2 replica; cần ADR riêng.

#### E. Trải cứng (`whenUnsatisfiable: DoNotSchedule` hay anti-affinity bắt buộc)

- Được: hai pod chắc ở hai node.
- Mất: khi một trong hai node bị cordon hay hết chỗ, pod thay có thể nằm Pending tới khi node về; đổi chart dùng chung với gateway và web.

#### F. Gateway thử lại lâu hơn (nhiều lần hơn, backoff dài hơn 2 s)

- Được: không thêm pod.
- Mất: 2 s chỉ là lần đo này (pod thay khởi động nhanh); request chờ quá p99 150 ms của SLO feed; thử lại nhiều hơn nhân tải khi
  feed-service chết thật; một pod vẫn là điểm hỏng duy nhất khi drain.

### Quyết định

Chọn **B**. Values gốc của feed-service (đường dev `make k8s-up` và đường GitOps qua Argo CD cùng đọc): `hpa.minReplicas: 2`,
`hpa.maxReplicas: 2`, `cpuUtilization` giữ 70, `pdb.minAvailable: 1`, `spreadAcrossNodes: true`. Overlay prd
([ADR-0024](0024-multi-environment.md)) đã có `hpa.minReplicas: 2`, `pdb`, `spreadAcrossNodes` theo chính sách riêng của prd, giữ
nguyên dù nay trùng gốc.

- **Trải node là ưu tiên, không bảo đảm:** chart dùng `whenUnsatisfiable: ScheduleAnyway`, nên hai pod có thể cùng một node (node kia
  hết chỗ hay lúc lịch). Lượt runner kiểm vị trí thật của hai pod.
- **`maxReplicas` giữ 2 vì phạm vi và ngân sách hiện tại**, không phải vì replica thứ ba vô dụng: mục tiêu lượt này là sống sót khi mất
  một pod; RAM của cluster dev trên máy 16 GB. HPA nay không co giãn; giữ để nâng tối đa sau, khi có số tải (giai đoạn 7).
- **Rủi ro phân bố tải:** gateway gọi `feed-service:9104` qua ClusterIP bằng resolver DNS mặc định và `pick_first` của grpc-go, nên mỗi
  pod gateway giữ một kết nối HTTP/2 sống lâu tới pod feed mà kube-proxy chọn lúc nối (bất kỳ backend nào). Gateway HPA tới 4 pod, nên
  tải chia theo số kết nối và có thể lệch: vài pod gateway cùng ghim một pod feed; pod feed mới chỉ nhận kết nối mở sau khi nó Ready.
- **Chi phí:** thêm 1 pod, request 100m / 64 Mi (limit 1 / 256 Mi), working set đo được tối đa 35 MiB mỗi pod (Bối cảnh), so với hàng
  "6 service lúc nghỉ" 300 MiB của ngân sách ADR-0014 §2 và đường GitOps đã vượt (b) của ADR-0017. RAM nghỉ của cluster sau đổi **chưa
  đo**; lượt runner sau đo.
- PDB không chặn `pod-kill` của Chaos Mesh (xoá thẳng, không qua eviction, ADR-0020 §7): thứ giữ feed khi kill là 2 replica Ready. PDB
  giữ feed khi drain và evict.
- **Kiểm chứng:** `make drill-k8s-pdb` mở rộng cho feed-service: in vị trí hai pod trước và sau, evict pod đầu 201, pod thứ hai 429 khi
  pod thay còn Pending, phục hồi 2 pod Ready sau uncordon; hai pod cùng node chỉ là ghi chú, không FAIL. Kịch bản `chaos` (a) feed-service
  trên runner với giả thuyết như gateway.

## 2. engagement-service lỗi nhanh có kiểm soát khi Postgres chậm hay mất

### Các lựa chọn về số round trip của Like

#### A. Giữ transaction 4 câu

- Mất: 4 round trip trên kết nối ấm (5 khi kết nối rảnh quá 1 s), mỗi câu `Prepare` lần đầu thêm một: dưới trễ 200 ms là 0,8–1,0 s
  trước khi tính chờ kết nối, không vừa một hạn ghi ngắn.

#### B. Một câu SQL (CTE), giữ chế độ thực thi mặc định của pgx

- Được: một câu đơn vẫn nguyên tử (một transaction ngầm); 1 round trip trên kết nối ấm; không đổi cách mã hoá tham số.
- Mất: câu lần đầu trên một kết nối vẫn 2 round trip (`Prepare` rồi Exec).

#### C. Một câu SQL với `QueryExecModeExec`

- Được: 1 round trip cả khi câu chưa có trong cache của kết nối.
- Mất: đổi cách mã hoá tham số của mọi câu (dạng text, kiểu đoán theo kiểu Go, pgx v5.11.0 `conn.go`, chú thích của
  `QueryExecModeExec`) cho một lợi ích chỉ có ở kết nối mới.

### Các lựa chọn về cách ly `GetStats` với Like

#### D. Chỉ tăng kích thước pool

- Mất: dưới trễ 200 ms mỗi `GetStats` hết hạn đóng một kết nối, và kết nối thay mất ≥ 1,2 s để dựng (dưới đây); ở khoảng 25 req/s
  explore của lượt đo là khoảng 30 kết nối đang dựng thường trực (ước lượng), tăng theo tải feed: pool lớn hơn chỉ dời điểm Like hết chỗ.

#### E. Một pool, hạn `Acquire` cộng `statement_timeout` phía server

- Được: không thêm pool.
- Mất: không tách `GetStats` khỏi Like; không chặn việc dựng lại kết nối (constructor của puddle chạy tiếp sau khi `Acquire` bị huỷ).

#### F. Một pool, semaphore cho `GetStats`

- Mất: semaphore trả chỗ lúc RPC trả lời hay lúc hạn nền 1 s hết, nhưng constructor của puddle vẫn chạy tiếp tới `connect_timeout` 5 s
  của `internal/pgpool`, nên hai đợt `GetStats` cách nhau 1 s dựng được gấp đôi số chỗ; muốn đúng phải theo dõi vòng đời constructor,
  phức tạp hơn hai pool.

#### G. Hai pool tách ngân sách, tổng tường minh

- Được: puddle đã tính kết nối đang dựng vào `MaxConns` của từng pool (Kiểm chứng), nên churn của `GetStats` nằm trong chỗ của pool đọc,
  không lấy kết nối của Like; không semaphore tự viết.
- Mất: Like không mượn được chỗ trống của pool đọc; hai lần kiểm khởi động.

#### H. Huỷ bằng cancel request của pgx (`CancelRequestContextWatcherHandler`)

- Được: kết nối không bị đóng khi `GetStats` hết hạn.
- Mất: mỗi lần huỷ mở thêm một kết nối mạng tới server; không giúp khi mọi gói đều trễ.

### Các lựa chọn về hạn và lỗi

#### I. Hạn theo method ở gateway

- Mất: không dừng việc ở Postgres; lỗi vẫn bị retry policy của gateway thử lại trong hạn 3 s.

#### J. Hạn ghi phía server, lỗi Postgres là lỗi phụ thuộc không thử lại

- Được: engagement-service tự dừng việc ở Postgres trước hạn của gateway; gateway trả 503 ngay; breaker không tính, nên Postgres chậm
  không cắt `RecordView` (qua Kafka).
- Mất: lỗi Postgres tạm thời của Like không còn được gateway thử lại (Hệ quả).

### Quyết định

Chọn **B**, **G**, **J**. Mục tiêu theo ADR-0020 §7 (b): feed sống, like và view không 5xx chậm, breaker chỉ mở khi engagement-service
hỏng thật.

- **Like/Unlike một câu SQL** (CTE: insert hay delete dòng `likes`, rồi đổi `like_counts` chỉ khi dòng thật sự đổi) thay transaction
  `Begin`/2 câu/`Commit`. Câu đơn vẫn nguyên tử; thứ tự khoá `likes` → `like_counts` giữ như migration. Ngữ nghĩa không đổi: like hai lần
  đếm một, unlike khi chưa like không đổi gì.
- **Số round trip, đúng như pgx v5.11.0 làm** (chế độ mặc định `QueryExecModeCacheStatement`, không đổi; Kiểm chứng):
  - kết nối đã dùng câu đó: 1 round trip; kết nối rảnh quá 1 s thêm 1 (ping của pgxpool);
  - câu lần đầu trên một kết nối: 2 (`Prepare` rồi Exec);
  - kết nối mới: thêm dial và xác thực SCRAM (≥ 4 round trip: TCP, startup, hai bước SASL), thêm SSLRequest và bắt tay TLS khi URL bật TLS
    như ở k3d (`sslmode=require`).
  - Trước đây (transaction, kết nối ấm): 4.
  - Dưới trễ 200 ms mỗi round trip: kết nối ấm 0,2 s (0,4 s khi rảnh quá 1 s), câu lạnh 0,4 s (0,6 s), trong hạn 1 s; kết nối mới
    ≥ 1,2 s, quá hạn, thành 503 nhanh (Hệ quả).
- **Hạn ghi phía server 1 s** cho phần Postgres của Like/Unlike, tính cả chờ kết nối của pool, dưới `callTimeout` 3 s của gateway. Hết hạn
  của chính nó, hay **Postgres không tới được**, thì trả `UNAVAILABLE` kèm `ErrorInfo` `DEPENDENCY_UNAVAILABLE` (như `RecordView` khi broker
  lỗi) và trailer `grpc-retry-pushback-ms: -1`, để retry policy của gateway không thử lại (handler unary trả lỗi là Trailers-Only). Gateway
  trả 503 ngay; breaker không tính vì có `ErrorInfo`. "Không tới được" gồm:
  - lỗi lúc mở kết nối: refused, timeout, cắt lúc bắt tay;
  - lỗi sau khi đã nối: EOF, reset, lỗi đọc hay ghi socket giữa truy vấn;
  - Postgres trả SQLSTATE lớp `08` (lỗi kết nối) hay `57P01`–`57P03` (server đang tắt hay chưa nhận kết nối).
  Phân loại này nằm ở engagement-service. **Luật thử lại lúc khởi động của `internal/pgretry` giữ nguyên**: `Retryable` cố ý chỉ nhận
  `*pgconn.ConnectError`. Hạn của người gọi hết trước thì giữ như hiện nay (`DEADLINE_EXCEEDED`, `CANCELLED`); lỗi khác vẫn `INTERNAL`.
- **Hai pool tách ngân sách, tổng tường minh** (bulkhead bằng chính pool, không semaphore tự viết). engagement-service đọc
  `DATABASE_MAX_CONNS` = tổng kết nối Postgres của một process: số nguyên ≥ 2; không đặt thì 10; giá trị khác thì service không khởi động.
  Values của k3d đặt `"10"`; compose không đặt. Pool **đọc** (chỉ `GetStats`) có ⌊n/2⌋ kết nối, pool **ghi** (Like, Unlike, consumer
  lượt xem) có phần còn lại; cùng URL, cùng role.
  - Vì sao đúng: puddle v2.2.2 lấy chỗ của semaphore `acquireSem` trước khi dựng kết nối và chỉ trả khi dựng lỗi hay khi kết nối được trả
    về pool, nên `MaxConns` của mỗi pool đã tính cả kết nối **đang dựng** ở nền sau khi `Acquire` bị huỷ. `GetStats` bị gateway huỷ ở
    100 ms làm pgx đóng kết nối và pool đọc phải dựng lại, nhưng việc đó bị chặn trong ⌊n/2⌋ chỗ của chính nó, không lấy kết nối của Like.
  - Vì sao có `DATABASE_MAX_CONNS`: mặc định max(4, NumCPU) của pgx đổi theo máy (runner 4, laptop 8 trở lên, node EKS khác).
  - `internal/pgpool` nhận kích thước và tên pool qua tuỳ chọn; user-, video-, feed-service gọi như cũ, không đổi hành vi. Số liệu pool của
    otelpgx phân biệt hai pool bằng thuộc tính tên (mặc định hai pool cùng URL trùng tên, Kiểm chứng).
- **Breaker không đổi code:** tính `UNAVAILABLE` không `ErrorInfo` và `DEADLINE_EXCEEDED` (trừ của `GetStats`); không tính
  `DEPENDENCY_UNAVAILABLE`. Postgres chậm hay mất không mở breaker (`RecordView` qua Kafka vẫn chạy); engagement-service chết (từ chối kết
  nối) hay treo (Like hết hạn 3 s của gateway) thì mở.
- **Đảo một phần [ADR-0010](0010-redis-ratelimit-cache-resilience-stage2c.md) §4:** bulkhead lựa chọn A "không thêm" (nay hai pool tách
  ngân sách ở engagement-service) và timeout lựa chọn A "một hạn chung" (nay thêm hạn ghi 1 s phía server cho Like/Unlike); câu "Mã
  `UNAVAILABLE` vẫn được retry" của đoạn về lỗi phụ thuộc không còn đúng với Like/Unlike. Phần còn lại của §4 giữ.
- **Kiểm chứng:** test Go của Like/Unlike và hai pool trên Postgres chậm giả (proxy của `internal/pgretry/pgretrytest`); test gateway:
  Like nhận lỗi phụ thuộc có pushback âm thì không bị thử lại và breaker vẫn đóng. Kịch bản `chaos` (b) trên runner: giả thuyết "like,
  view không 5xx" giữ.

## 3. Tempo tự giới hạn bộ nhớ, không sampling

**Giả thuyết, chưa đo:** OOM ở tải thấp (k6 1 pod) sau thời gian dài, trong khi mức 2 pod giữ 10 phút không OOM, gợi ý phần Tempo giữ
trong bộ nhớ tăng theo thời gian mà không bị chặn; mức 4 pod chết sớm hơn theo tốc độ. Artifact không có chuỗi RAM của Tempo hay metric
ingest, live traces, nên nguyên nhân ghi theo source Tempo v3.1.0 mà phần hiện thực đọc và theo số của lượt runner sau (mục Kết quả).

### Các lựa chọn

#### A. Chỉ nâng limit

- Được: một dòng values.
- Mất: phần tăng theo thời gian vẫn không có trần, chỉ chết muộn hơn; RAM của cluster dev.

#### B. Cấu hình của Tempo chặn từng phần giữ bộ nhớ, cộng trần ingest

- Được: bộ nhớ có trần ước lượng được; quá trần thì Tempo từ chối span (mất có kiểm soát, đo được) thay vì OOM (mất mọi trace và replay
  WAL mỗi lần lên); giữ 100 % trace cho diễn tập.
- Mất: phải đọc source để chọn tham số; span quá trần bị từ chối.

#### C. Head sampling ở SDK (`parentbased_traceidratio`)

- Được: bớt span ở nguồn, mọi thành phần nhẹ theo.
- Mất: `drill-alert-to-sentry`, `drill-obs-threats` tìm trace của đúng một request; sampling ngẫu nhiên làm chúng hụt.

#### D. Tail sampling ở Collector

- Được: giữ trace lỗi và chậm.
- Mất: Collector giữ trace trong bộ nhớ chờ quyết định (chuyển áp lực sang Collector); cùng vấn đề với diễn tập tìm trace của một request
  bình thường.

#### E. Tắt metrics-generator (bước cắt 2 của ADR-0014 §2)

- Mất: service graph và span metrics, mà lượt runner dùng để chứng minh Tempo còn thu; chưa biết generator là phần lớn.

#### F. Tiêu chí "runner đủ" bỏ qua OOM ở `svp-obs`

- Mất: che lỗi cấu hình của project; Tempo vẫn chết và mất trace dưới tải.

### Quyết định

Chọn **B**.

- Cấu hình Tempo 3.1.0 chặn từng phần giữ bộ nhớ; ADR ghi nguyên tắc, tham số, giá trị và phép tính ở `deploy/k8s/values/tempo.yaml`
  (mục Hiện thực ở). metrics-generator giữ.
- `limits.memory` nâng tối đa 1 Gi, chỉ khi phép tính cần; `requests.memory` giữ 128 Mi. RAM nghỉ của cluster dev **chưa đo sau đổi**;
  lượt runner sau đo.
- **Trần ingest đặt trên tốc độ span ở k6 4 pod, có biên** (hôm nay chỉ có ước lượng 1 000–1 400 span/s; lượt runner đo số thật), nên tới
  mức đó Tempo không từ chối span.
- **Tiêu chí mất dữ liệu**, ở mọi thí nghiệm chaos và các mức 1, 2, 4 pod của `k6-cloud-mini`: 0 span bị Collector từ chối ở receiver
  (memory_limiter đứng đầu pipeline, `otelcol_receiver_refused_spans`), 0 span exporter gửi lỗi hay không vào được hàng đợi, 0 span bị
  Tempo từ chối. Span bị từ chối tính là có thể mất: SDK có thể thử lại nhưng không đo được, nên không kết luận "không mất" khi có từ
  chối. Mức 8 pod (vượt mức đã đo) chỉ ghi số.
- **Tempo còn thu và đọc được**, mỗi cửa sổ giữ tải: tìm thấy trace của gateway bắt đầu trong cửa sổ, lấy được trace đó theo id, cạnh
  gateway → feed-service của service graph có tốc độ > 0; working set đỉnh của `tempo` dưới limit, 0 OOM. Sampler của runner lấy thêm
  `svp-obs` vào `pods.tsv` để có chuỗi RAM.
- **Không sampling ở giai đoạn này** (C, D bị loại vì diễn tập giai đoạn 3 tìm trace của đúng một request); quyết lại ở giai đoạn 7
  (1 000 req/s).

## Kết quả

Chưa có lượt runner nào trên cấu hình này.

## Hệ quả

- **Được:**
  - Mất một pod feed-service (kill, crash, evict, drain một node) còn một pod phục vụ feed.
  - Postgres chậm hay mất: like trả 503 trong khoảng 1 s thay vì 504 sau 3 s; feed và lượt xem chạy tiếp; breaker không mở oan và vẫn
    mở khi engagement-service chết.
  - Kích thước pool của engagement-service không còn đổi theo máy; `GetStats` không lấy được kết nối của Like.
  - Tempo có trần bộ nhớ thay vì OOM lặp; lượt runner có tiêu chí mất span và đọc trace đo được.
- **Phải trả:**
  - feed-service thêm một pod (request 100m / 64 Mi), kể cả lúc nghỉ; hai pod có thể cùng node; tải giữa hai pod chia theo kết nối,
    có thể lệch.
  - Like gặp lỗi Postgres tạm thời không còn được gateway thử lại; client thử lại. Like/Unlike idempotent nên lần thử lại không đếm hai
    lần, kể cả khi câu đã commit mà câu trả lời mất.
  - Postgres chậm 1–3 s: trước đây like vẫn thành công chậm, nay 503. Like trên kết nối mới dưới trễ lớn là 503. Postgres treo (không từ
    chối kết nối) thì mỗi like vẫn chờ đủ 1 s rồi mới 503, vì lỗi phụ thuộc không mở breaker (như `RecordView` chờ hạn produce 2 s khi Redpanda chết, ADR-0010 §4).
  - Mỗi 503 có pushback âm trừ một token của `retryThrottling` trên kết nối tới engagement-service: Postgres lỗi kéo dài thì cả thử lại
    của Like/Unlike khi engagement-service khởi động lại cũng tạm tắt, tới khi lời gọi thành công hồi token.
  - `GetStats` vắng `stats` khi Postgres chậm (mỗi truy vấn quá 100 ms) và khi pool đọc đầy. Khi Postgres chậm pool đọc dựng lại kết
    nối liên tục (mỗi `GetStats` bị huỷ đóng một kết nối, tối đa ⌊n/2⌋ đang dựng cùng lúc): thêm backend Postgres và xác thực SCRAM mỗi lần.
  - Like dùng tối đa phần ghi (5 trên 10), không mượn được chỗ trống của pool đọc; mỗi lần khởi động kiểm kết nối hai lần (lần hai nối
    ngay).
  - Tempo từ chối span khi tốc độ vượt trần (mức 8 pod hay tải cao hơn): mất trace có kiểm soát; limit có thể lên tới 1 Gi.
- **Xem lại khi:**
  - Lượt runner sau vẫn là phát hiện ở (a) feed-service (5xx quá 0,1 % quanh lần kill), cần quá 2 replica, hay hai pod feed lệch tải rõ:
    rủi ro còn lại là hai pod gateway cùng ghim vào pod bị kill, và kết nối lại qua ClusterIP lúc EndpointSlice chưa bỏ pod chết vẫn có
    thể lỗi. Bước kế là cân bằng tải phía client (Service headless, `round_robin`, `MaxConnectionAge` phía server), bằng ADR riêng.
  - Like trả `DEPENDENCY_UNAVAILABLE` lúc Postgres khoẻ, hay thời gian chờ kết nối của pool ghi (`pgxpool.*`) tiến gần 1 s dưới tải thật:
    xem lại hạn 1 s và cách chia ⌊n/2⌋.
  - Giai đoạn 7 đổi Postgres (RDS, pooler, nhiều replica): xem lại `DATABASE_MAX_CONNS` theo `max_connections` và số pod.
  - Lượt runner còn OOM của Tempo hay có span bị từ chối ở mức 1, 2, 4 pod: xem lại trần và limit (tối đa 1 Gi), rồi sampling.
  - Giai đoạn 7 (1 000 req/s): quyết sampling (head ở SDK hay tail ở Collector) và cỡ Tempo trên cluster đo thật.

## Hiện thực ở

- feed-service hai replica (§1): `deploy/k8s/values/services/feed-service.yaml` (HPA, PDB, trải node); giả thuyết của
  `deploy/k8s/cloud/chaos/a-pod-kill-feed-service.yaml`; diễn tập drain cho feed-service ở `deploy/k8s/drills/pdb.sh` và target
  `drill-k8s-pdb` của `deploy/k8s/k8s.mk`.
- engagement-service lỗi nhanh (§2): `services/engagement-service/` (`queries/likes.sql`, code sinh ở `internal/store/`, hạn ghi, phân loại
  lỗi và hai pool ở `internal/server/` và `cmd/engagement-service/`); kích thước và tên pool ở `internal/pgpool/`; proxy giả Postgres chậm
  cho test ở `internal/pgretry/pgretrytest/`; `DATABASE_MAX_CONNS` ở `deploy/k8s/values/services/engagement-service.yaml`; test retry và
  breaker của gateway ở `services/gateway/cmd/gateway/main_test.go`; giả thuyết của `deploy/k8s/cloud/chaos/b-network-delay-engagement.yaml`.
- Tempo (§3): giới hạn bộ nhớ và trần ingest, kèm phép tính, ở `deploy/k8s/values/tempo.yaml`; phép kiểm của runner ở
  `deploy/ci/verify-tempo.sh`, step của nó trong `deploy/ci/verify/chaos.sh` và `deploy/ci/verify/k6-cloud-mini.sh`, namespace `svp-obs` của
  `pods.tsv` ở `deploy/ci/verify-sample.sh`, bộ lọc artifact và tự kiểm ở `deploy/ci/verify-collect.sh`, `deploy/ci/verify-collect-test.sh`.
