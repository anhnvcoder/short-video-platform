# 0011. Giai đoạn 3: OpenTelemetry qua Collector riêng tới LGTM, GlitchTip tự host, Pyroscope và cảnh báo SLO bằng Sloth

- Trạng thái: Chấp nhận
- Ngày: 2026-10-16

## Bối cảnh

- Giai đoạn 2 đã có luồng upload, feed, like/view, retry, circuit breaker và job nền. Hiện chỉ có log JSON và
  `traceparent` tự truyền; chưa có span, metric hay cảnh báo để phân biệt một request chậm với consumer đứng.
- NFR ở [architecture §2](../architecture.md#2-yêu-cầu-phi-chức-năng): feed p99 < 150 ms, đọc feed và khởi tạo upload
  sẵn sàng 99,9%, video một phút tới `READY` p95 < 120 s, độ tươi feed p95 < 10 s. Timeout vòng nền còn treo ở
  [ADR-0010 §4](0010-redis-ratelimit-cache-resilience-stage2c.md#4-timeout-retry-circuit-breaker-bulkhead).
- Giữ contract header của [ADR-0006](0006-contract-ids-and-event-envelope.md), trace gốc do gateway tạo của
  [ADR-0007 §8](0007-go-monorepo-toolchain-and-stage1-scope.md#8-phạm-vi-giai-đoạn-1), outbox và mạng worker của
  [ADR-0008](0008-async-upload-pipeline-stage2a.md). Không đổi proto hay envelope nghiệp vụ.
- Máy Apple M2, 16 GB RAM; Postgres/Redis native dùng chung. Chạy native arm64, lần lượt LGTM và Elastic; không chạy
  compose cùng k3d. Đây là cấu hình dev local, chưa phải mô hình triển khai production.
- Điều chỉnh plan giai đoạn 3 đã được duyệt: Collector riêng và Alertmanager bên cạnh LGTM; GlitchTip thay Sentry SaaS
  vì máy chủ động chặn `sentry.io` trong `/etc/hosts`; bài Elastic chạy lần lượt, không gửi đồng thời hai backend.
  Không sửa cấu hình máy để vượt chặn. SDK lỗi vẫn là `sentry-go`, nên đổi sang Sentry sau này bằng DSN.
- Các ranh giới bảo mật cần giữ: JWT-8, UP-8, RL-2, OPS-1/2 và FF-5 trong
  [threat model](../threat-model.md). Không ghi password, token, email vào telemetry; không gửi header, thân request,
  form presigned hay query chứa chữ ký. Bộ lọc Collector và bộ lọc lỗi chỉ là lớp phụ cho việc kiểm dữ liệu ở nguồn.

## 1. Đường đi telemetry và Collector

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Service gửi vào Collector có sẵn trong LGTM | Ít container, ít một chặng | Endpoint gắn với backend; khó giữ cùng cấu hình xử lý khi đổi sang Elastic và Helm |
| **Collector contrib riêng** | Một endpoint cho service; chủ động lọc dữ liệu, giới hạn RAM và scrape Redpanda; dùng lại ở giai đoạn 4 | Thêm container, cấu hình và một chặng truyền |
| SDK riêng của từng backend | Có tích hợp đặc thù | Đổi backend phải sửa service, đi ngược mục tiêu học OpenTelemetry |

### Quyết định

Service → **OTLP/gRPC** → `otelcol:4317`. Collector `otel/opentelemetry-collector-contrib` nằm trong cả hai mạng
`default` và `worker`; cổng 4317 **không publish**. media-worker vẫn chỉ ở mạng `worker` nội bộ, không có route ra
internet, không nối sang mạng service. Collector nhận telemetry, không làm proxy HTTP hay router cho worker.

- `obs`: Collector xuất OTLP/gRPC tới `lgtm:4317`; Collector trong LGTM chuyển trace tới Tempo, log tới Loki, metric
  tới OTLP receiver của Prometheus. Không bỏ Collector có sẵn ra khỏi image.
- `obs-elastic`: cùng endpoint nhận `otelcol:4317`, cấu hình exporter khác → APM Server OTLP intake → Elasticsearch;
  Kibana đọc dữ liệu đó. Một service compose `otelcol` dùng cho cả hai cách chạy, chỉ chọn một cấu hình lúc khởi động.
- Receiver `otlp` bật gRPC; receiver `prometheus` scrape `redpanda:9644/public_metrics` mỗi **15 s**.
- Processor theo thứ tự: `memory_limiter` (kiểm mỗi 1 s, `limit_mib: 192`, `spike_limit_mib: 48` trong container
  256 MiB), xoá attribute nhạy cảm, `batch` (timeout 1 s, `send_batch_size: 1024`). Lọc cả attribute của signal và
  resource: `http.request.header.authorization`, `http.request.header.cookie`, `user.email`, `user.name`.
  Áp dụng cho trace/log/metric; không chỉ xoá trên span rồi để resource lọt qua.
- Collector tự xuất metric của nó (hàng đợi exporter, dữ liệu bị từ chối, gửi lỗi) bằng `service.telemetry`: đẩy
  OTLP/gRPC mỗi **15 s** thẳng tới `lgtm:4317`, không qua pipeline của chính nó (pipeline đang từ chối dữ liệu thì
  metric vẫn tới), `service.name=otelcol` để tách với Collector trong LGTM (`otelcol-contrib`). Không mở `:8888` cho
  scrape. Dashboard USE vẽ hàng đợi và drop của cả hai Collector.
- Giai đoạn 4 mang cấu hình xử lý này sang Helm. Tail sampling để giai đoạn 7; hiện không thêm hàng đợi đĩa.

## 2. Gói Go, version và route HTTP

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **OTel API/SDK và instrumentation cùng đợt phát hành** | Ít lệch semantic convention; đã build cùng dependency hiện có | Một số module còn v0.x; phải ghim và kiểm khi nâng |
| Trộn các version hoặc chỉ chọn module v1.x | Có vẻ ít API thử nghiệm hơn | Không có log exporter/bridge v1.x tương đương trong đợt này; dễ lệch API và tên metric |
| Tự viết mọi instrumentation | Ít module | Tự gánh span, pool metric và semantic convention cho HTTP/gRPC/SQL/Redis/S3 |

### Quyết định

Tra bằng Go module proxy ngày 2026-10-16. Các module OTel dưới đây cùng đợt **2026-10-02**, yêu cầu Go 1.26.0,
build được bằng Go **1.27.2**. Gói v0.x là version phát hành thật, chưa cam kết tương thích API như v1.x; vẫn dùng
vì chưa có lựa chọn ổn định tương đương. Không hiểu “cùng đợt” thành “cùng số version”.

| Module | Version | Ai dùng / mục đích |
| --- | --- | --- |
| `go.opentelemetry.io/otel` | `v1.47.0` | Mọi service; API, propagator, resource và semantic convention `semconv/v1.43.0` |
| `go.opentelemetry.io/otel/sdk` | `v1.47.0` | `internal/telemetry`: trace provider, resource, sampler |
| `go.opentelemetry.io/otel/sdk/metric` | `v1.47.0` | `internal/telemetry`: meter provider, periodic reader, View |
| `go.opentelemetry.io/otel/sdk/log` | `v1.47.0` | `internal/telemetry`: logger provider và batch processor |
| `go.opentelemetry.io/otel/log` | `v1.47.0` | API log của bridge/telemetry |
| `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc` | `v1.47.0` | Trace exporter gRPC |
| `go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc` | `v1.47.0` | Metric exporter gRPC |
| `go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc` | `v0.23.0` | Log exporter gRPC |
| `go.opentelemetry.io/contrib/bridges/otelslog` | `v0.21.0` | `internal/logx`: slog → OTel log |
| `go.opentelemetry.io/contrib/instrumentation/runtime` | `v0.72.0` | Mọi service: metric Go runtime |
| `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` | `v0.72.0` | Gateway HTTP server |
| `go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc` | `v0.72.0` | Gateway client và `internal/grpcserver` |
| `go.opentelemetry.io/contrib/instrumentation/github.com/aws/aws-sdk-go-v2/otelaws` | `v0.72.0` | `internal/objstore`: middleware S3 SDK, video-service và media-worker |
| `github.com/exaring/otelpgx` | `v0.13.0` | `internal/pgpool`: pgx tracer, `RecordStats` |
| `github.com/redis/go-redis/extra/redisotel/v9` | `v9.23.0` | `internal/redisx`: trace và metric pool, khớp go-redis |
| `github.com/getsentry/sentry-go` | `v0.50.0` | `internal/sentryx`: giao thức lỗi tới GlitchTip |
| `github.com/grafana/pyroscope-go` | `v1.4.3` | Năm service Go có kết nối tới LGTM, mục 6 |

Module phụ `otel/trace` và `otel/metric` cùng **v1.47.0**. Probe lấy bản sao module của repo ra thư mục tạm, `go get`
toàn bộ version trên, import mọi gói rồi build thành công. Minimal version selection giữ nguyên:

| Dependency đang dùng | Version sau probe |
| --- | --- |
| `google.golang.org/grpc` | `v1.84.0` |
| `google.golang.org/protobuf` | `v1.36.12` |
| `golang.org/x/net` | `v0.60.0` |
| `github.com/jackc/pgx/v5` | `v5.11.0` |
| `github.com/redis/go-redis/v9` | `v9.23.0` |
| `github.com/aws/aws-sdk-go-v2` | `v1.47.3` |
| `github.com/aws/aws-sdk-go-v2/service/s3` | `v1.114.3` |

`otelaws` v0.72.0 có chú thích upstream **deprecated, không còn được hỗ trợ** trong `aws.go`. Giữ lựa chọn đã chốt
cho S3 hiện tại vì đã build tương thích; phải xét lại trước khi nâng AWS SDK hoặc chuyển lên cloud. Đây không phải
cam kết upstream còn vá gói đó. Với pgx không bật `WithIncludeQueryParameters`; Redis trace dùng
`redisotel.WithDBStatement(false)` để không đưa key/value hay script vào span.

Không dùng các gói sau:

| Gói | Lý do |
| --- | --- |
| `franz-go/plugin/kotel` | Hook theo client ghi header trên mọi record, có thể đè context từng dòng outbox; API propagator OTel đủ cho `kafkax`/`outbox` |
| `sentry-go/otel` | Trace chỉ lưu ở Tempo; không tạo hệ tracing thứ hai |
| `sentry-go/slog` | Handler mặc định không thực thi allowlist và quy tắc bỏ nội dung tự do của JWT-8 ở mục 7 |
| `prometheus/client_golang` | Metric đẩy OTLP; không mở `/metrics` trong service |

**Route HTTP:** `go doc log/slog NewMultiHandler` xác nhận Go 1.27 có API đó. Source `otelhttp` v0.72.0 đọc
`r.Pattern` sau mux cho metric và đổi tên span thành `METHOD /pattern`; bỏ method khỏi `http.route`. Tuy nhiên
attribute request của span được lấy trước mux. Thêm nữa, `AccessLog`/`ValidUTF8` hiện sao chép request bằng
`WithContext`: pattern ở bản sao sâu hơn không tự quay về request mà `otelhttp` giữ.

Vì vậy gateway dùng phương án tường minh đã chốt: middleware **bọc từng route, ngoài auth/rate limit**, sau khi mux
khớp, thêm `semconv.HTTPRoute(route)` qua `otelhttp.LabelerFromContext(ctx).Add(...)`, đặt tên span
`METHOD /pattern` và attribute `http.route` qua `trace.SpanFromContext(ctx)`. `route` là phần path pattern của
`r.Pattern`, bỏ tiền tố method, ví dụ `/videos/{video_id}/complete`. Không dùng URL thật; route không khớp để rỗng
(PromQL coi label thiếu như giá trị rỗng), tên span chỉ là method. Cách này cũng ghi nhận 401/429 theo route đúng.

## 3. Lan truyền trace và sampling

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Tin trace header của client, mang cả Baggage | Ghép được trace của client bên ngoài | Client điều khiển trace gốc và đưa dữ liệu/cardinality tùy ý vào hệ thống |
| **W3C TraceContext nội bộ; gateway tạo trace gốc mới** | Giữ ranh giới ADR-0007, đủ nối HTTP → gRPC → Kafka | Không nối trace trình duyệt với backend trong giai đoạn này |
| Tạo một producer span cho cả lô outbox | Ít span | Gộp sai những dòng thuộc nhiều request/trace khác nhau |

### Quyết định

- Global propagator chỉ `propagation.TraceContext{}`, **không Baggage**. HTTP `otelhttp` dùng propagator rỗng để bỏ
  `traceparent`/`tracestate` của client; mỗi request nghiệp vụ mở trace gốc mới, không tạo link tới context client.
  Filter bỏ `/healthz` và `/readyz` khỏi instrumentation HTTP (cả trace và metric), trước khi tạo span; probe vẫn chạy
  handler và trả status như cũ. Không bỏ theo tiền tố khiến route nghiệp vụ vô tình bị loại.
- gRPC dùng `otelgrpc.NewClientHandler` ở gateway và `NewServerHandler` ở `internal/grpcserver` qua stats handler;
  filter bỏ `/grpc.health.v1.Health/Check` khỏi trace. Metadata danh tính vẫn được dựng mới trước khi OTel inject.
- Kafka giữ key `traceparent`, `tracestate` chỉ khi khác rỗng. `kafkax.Produce` là **nơi duy nhất** mở/kết thúc span
  kind Producer, tên `send <topic>`, mỗi record một span; inject context của span này, thay header trace đã lưu.
- `outbox.Write` inject context hiện tại vào `headers` jsonb; không migration, dòng cũ `{}` vẫn đọc được. Relay chỉ
  extract từng dòng và gắn parent vào context của record; không mở producer span và không inject header lần nữa.
  Deadline produce của lô vẫn áp dụng cho mọi record, không mất khi chọn parent riêng của từng dòng.
- Consumer từng record extract rồi mở span kind Consumer `process <topic>` làm con. Consumer theo lô mở một span
  cho cả lô và link tới từng context hợp lệ, tối đa **128 link**; không nhận parent của record đầu làm parent cả lô.
- Header hỏng/thiếu thì mở trace gốc mới, không làm xử lý nghiệp vụ lỗi. Xoá `internal/traceparent` khi không còn ai
  dùng; `trace_id` trong problem response lấy từ SpanContext.
- Local mặc định `parentbased_always_on` (100%), đổi bằng `OTEL_TRACES_SAMPLER`. Chưa tail sampling.

Test bắt buộc khi hiện thực: một lô outbox chứa nhiều trace, mỗi producer span có đúng parent của dòng tương ứng;
không có producer span trùng; header hỏng/thiếu không lỗi. Một trace phải đi từ
`POST /videos/{video_id}/complete` → relay → media-worker → `transcode.completed` → video-service → `video.ready`
→ fan-out feed-service, kể cả khi relay gửi sau khi request HTTP đã kết thúc.

## 4. Log có cấu trúc và Loki

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Đọc stdout container bằng agent | Không cần log SDK trong service | Docker Desktop giữ log trong VM; mount `/var/lib/docker/containers` mong manh, cấu hình khác khi sang k8s |
| **slog ra stdout và bridge OTLP** | Giữ `make logs`, có trace context chuẩn và cùng đường Collector ở compose/k8s | Mỗi bản ghi đi hai đường, thêm hàng đợi có thể bỏ log khi quá tải |

### Quyết định

Giữ `log/slog`; trong nhánh `serve`, `logx.New` dùng `slog.NewMultiHandler` cho JSON stdout, bridge `otelslog` và
handler lỗi ở mục 7. Logger trước khi chọn lệnh con chỉ ghi JSON stdout, không tự khởi tạo SDK/exporter.
JSON lấy `trace_id`, `span_id` từ `trace.SpanContextFromContext(ctx)` khi context hợp lệ; bỏ cách tự thêm
`logx.With("trace_id", ...)`. OTLP log mang trace context trong field chuẩn. Stdout vẫn dùng được khi Collector tắt.

Log → Collector → Loki **bằng OTLP**. Loki trong image dùng schema **v13**, nhận `/otlp/v1/logs`; tên attribute có
dấu chấm đổi thành gạch dưới. Resource, scope và attribute log không thành index label thì lưu structured metadata;
body là dòng log, `trace_id`/`span_id` là metadata, không phải label index.

Mount cấu hình Loki đặt `limits_config.allow_structured_metadata: true`; trong
`limits_config.otlp_config.resource_attributes` đặt `ignore_defaults: true`, chỉ `service.name` có action
`index_label`. Vì mặc định image không hạn chế resource labels, phải có override này. Probe `/loki/api/v1/series`
trả đúng `{service_name="svp-adr0011-probe"}`; kết quả query còn có `severity_text`, `detected_level`, trace/span và
resource khác dưới dạng metadata. Không đưa `service.instance.id`, user/video ID, IP hay trace ID vào label index.
Mức log do Loki phát hiện có thể hiện khi query, không mở thêm label cardinality cao.

Grafana Tempo → Loki dùng `service.name` ánh xạ `service_name`, query
`{service_name="<service>"} | trace_id = "<trace>"`; Loki derived field `trace_id` trỏ về datasource `tempo`.
Mật khẩu/token/email vẫn phải bị chặn ngay ở nguồn; bộ lọc Collector không làm sạch được bí mật đã nối vào log body.

## 5. Metric, tên series và cardinality

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Prometheus scrape `/metrics` của từng service | Mô hình pull quen thuộc | Thêm cổng/handler, hai đường cấu hình metric và telemetry |
| **Periodic reader đẩy OTLP** | Chung Collector, không thêm bề mặt quản trị, đổi backend bằng cấu hình | Khi không export được thì mất mẫu; phải kiểm tên đã dịch trước khi viết PromQL |
| Chỉ sinh RED từ trace | Ít instrumentation metric | Sampling làm SLO sai; thiếu metric nghiệp vụ và pool |

### Quyết định

SDK periodic reader mỗi **15 s**, đẩy OTLP qua Collector vào Prometheus của LGTM. Không service nào có endpoint
`/metrics`. SLO dùng metric trực tiếp; RED/service graph sinh từ trace chỉ hỗ trợ tìm nguyên nhân.

Resource `service.name` là đúng tên compose/service (`gateway`, `user-service`, `video-service`, `media-worker`,
`engagement-service`, `feed-service`); `service.instance.id` duy nhất mỗi tiến trình. Không đặt `service.namespace`
ở local để `job` đúng bằng tên service. Prometheus image bật `keep_identifying_resource_attributes` và promote
`service.name`/`service.instance.id`: **có cả `job` và `service_name`, `instance` và `service_instance_id`**.
Dashboard/rule lọc bằng `service_name`, không gán nhầm metric Redpanda cho một Go service.

Đặt tên OTel và đơn vị chính xác như bảng. Counter nghiệp vụ không đặt unit; gauge breaker không unit; timestamp
loop có unit `s`. Histogram thời gian có unit `s`, aggregation explicit bucket qua SDK View. Prometheus dịch dấu
chấm thành gạch dưới, thêm `_seconds` và `_total` theo unit/type. Histogram có cả `_bucket`, `_sum`, `_count`, với
bucket cuối `+Inf` tự thêm. Không dùng native histogram thay cho các series `_bucket` của SLO.

- **H:** `[0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5, 10]` s.
- **V:** `[10, 20, 30, 45, 60, 90, 120, 180, 300, 600]` s.
- **F:** `[0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]` s.

Các tên HTTP/RPC và nghiệp vụ dưới đây đã kiểm bằng telemetry OTLP mẫu đi qua Collector của image tới Prometheus;
tên instrument RPC được đối chiếu source `otelgrpc` v0.72.0 (mặc định semantic convention mới, đơn vị giây).
Không đặt `OTEL_SEMCONV_STABILITY_OPT_IN=rpc/old` hay `rpc/dup`.

| Tên OTel | Tên trong Prometheus | Label nghiệp vụ / semantic convention | Bucket |
| --- | --- | --- | --- |
| `http.server.request.duration` | `http_server_request_duration_seconds_{bucket,sum,count}` | `http_route`, `http_request_method`, `http_response_status_code`; bucket thêm `le` | H |
| `rpc.server.call.duration` | `rpc_server_call_duration_seconds_{bucket,sum,count}` | `rpc_system_name="grpc"`, `rpc_method` (service/method đầy đủ), `rpc_response_status_code`; có thể có `error_type`, địa chỉ server cố định | H |
| `rpc.client.call.duration` | `rpc_client_call_duration_seconds_{bucket,sum,count}` | Như RPC server, thêm địa chỉ/port server theo instrumentation | H |
| `svp.ratelimit.decisions` | `svp_ratelimit_decisions_total` | `class`, `result="allowed\|limited"`, `store="redis\|fallback"` | — |
| `svp.breaker.state` | `svp_breaker_state` | `target`; giá trị 0 đóng, 1 half-open, 2 mở | — |
| `svp.kafka.dlq.records` | `svp_kafka_dlq_records_total` | `topic`, `group` | — |
| `svp.loop.last_success` | `svp_loop_last_success_seconds` | `loop="outbox-relay\|outbox-cleanup\|upload-sweep\|timeline-prune"` | — |
| `svp.video.ready.duration` | `svp_video_ready_duration_seconds_{bucket,sum,count}` | `outcome="ready\|failed"`, video-service | V |
| `svp.transcode.duration` | `svp_transcode_duration_seconds_{bucket,sum,count}` | `outcome="ready\|failed"`, media-worker | V |
| `svp.feed.freshness` | `svp_feed_freshness_seconds_{bucket,sum,count}` | Không thêm ID; feed-service | F |
| Redpanda scrape (không phải instrument Go) | `redpanda_kafka_consumer_group_lag_max`, `redpanda_kafka_consumer_group_lag_sum` | `redpanda_group`, `shard` (lag tổng có thể rỗng); thêm `job`/`instance` của scrape | — |

Label chung là resource ở trên. Label HTTP/RPC khác của instrumentation chỉ giữ giá trị hữu hạn; không gắn
`user_id`, `video_id`, `trace_id`, email, IP vào metric. `http.route` là pattern, không chứa ID thật.

**Định nghĩa nghiệp vụ:**

- Gateway ghi quyết định rate limit (RL-2), state breaker; `kafkax` tăng DLQ counter **sau khi** produce DLQ thành công.
  Trước khi nhận request/poll Kafka, gọi `Add(ctx, 0, ...)` cho mọi tổ hợp label đã biết: gateway là mỗi `class` cấu
  hình × `result=allowed|limited` × `store=redis|fallback`; DLQ là mỗi topic nguồn trong cấu hình consumer × group.
  Không đợi sự kiện đầu mới tạo series. Mẫu 0 có thể chưa kịp export trước sự kiện đầu; rule mục 8 xử lý cả trường
  hợp mẫu đầu Prometheus nhận đã khác 0, không dựa vào `created-timestamp-zero-ingestion` (image chưa bật).
- Gauge breaker giữ **trạng thái chuyển gần nhất**, khởi tạo 0 cho từng target, cập nhật 0/1/2 trong
  `gobreaker.OnStateChange`, lưu an toàn đồng thời rồi callback metric chỉ đọc giá trị đó. Không gọi `cb.State()`
  trong callback: hàm này có thể tự chuyển open → half-open khi hết 5 s. Chuyển 2 → 1 không phải phục hồi;
  chỉ chuyển về 0 mới xác nhận breaker đóng lại. Khi không có traffic, gauge giữ lần chuyển gần nhất.
- Loop ghi thời điểm Unix của bước thành công, gồm lượt không có việc và lượt không lấy được advisory lock. Vòng xử lý
  nhiều lô ghi sau từng lô thành công để không bị báo đứng khi đang dọn backlog; lỗi không làm mới timestamp. Chưa từng
  thành công thì xuất 0, không giả một lần thành công lúc khởi động. Rule xử lý 0 riêng với thời gian chờ đủ chu kỳ,
  không lấy `time() - 0` làm tuổi lần thành công. Chu kỳ/timeout và ngưỡng ở mục 8, 11.
  Callback gauge xuất giá trị đang giữ ở **mỗi lần collect 15 s**, kể cả 0 hay timestamp thành công không đổi;
  timestamp của mẫu OTLP là lúc collect, không phải giá trị Unix của lần thành công. Breaker cũng xuất mỗi kỳ như vậy.
- video-service thêm migration `services/video-service/migrations/00004_add_processing_at.sql`, cột
  `processing_at timestamptz`, NULL cho dòng cũ. `markProcessing` đặt `now()` đúng lần đổi `UPLOADING → PROCESSING` tại
  `CompleteUpload`. Sau transaction `markReady` **commit thành công**, đúng lần đổi trạng thái mới ghi
  `now() - processing_at`, `outcome="ready"`. `PROCESSING → FAILED` ghi cùng thời lượng, `outcome="failed"` sau ghi bền
  thành công; event lặp không thêm mẫu. NULL thì không ghi; job dọn `UPLOADING` không phải mẫu xử lý video.
  Đây là cùng khoảng đo `CompleteUpload → READY` của `make measure-ready`.
- `svp.transcode.duration` chỉ đo bước transcode ở worker, không đại diện thời gian tới `READY`; chỉ dùng dashboard.
- Feed freshness đo từ `occurred_at` của `video.ready` tới sau khi transaction fan-out commit; không ghi trước commit.
- Video kẹt ở `PROCESSING` vì consumer đứng không sinh mẫu kết thúc: SLO này không tự thấy nó. Lag > 0 kéo dài,
  `BackgroundLoopStalled` khi relay đứng, và cảnh báo DLQ mới giúp phát hiện đường xử lý bị ngừng.

**Lag Redpanda:** v26.2.4 xác nhận hai gauge trên là lag lớn nhất/tổng trên các topic-partition của **group**, không
có label topic/partition trên hai gauge tổng hợp. `redpanda_kafka_consumer_group_committed_offset` có
`redpanda_group`, `redpanda_topic`, `redpanda_partition`, `shard`. Trong `redpanda-init` chạy idempotent:

```sh
rpk cluster config set enable_consumer_group_metrics '[group,partition,consumer_lag]'
```

Không chỉ sửa `.bootstrap.yaml`: file đó chỉ áp dụng khi tạo cluster lần đầu, volume cũ không nhận thay đổi.
Engagement vẫn commit offset group qua `kafkax.BatchConsumer.commit` sau ghi Postgres, nên lag phía broker có nghĩa.

**Metric thư viện:** dùng `otelpgx.RecordStats`, `runtime.Start`, `redisotel.InstrumentMetrics`. Các tên dưới đây
đối chiếu source của version ghim; bảng chỉ rõ đơn vị gốc để dashboard không đọc nanosecond thành second. Dùng
metric mặc định của thư viện, không đổi sang tên tự đặt; bucket thư viện không tham gia SLO.

| Tên OTel | Tên Prometheus theo phép dịch đã kiểm | Label / bucket |
| --- | --- | --- |
| `pgxpool.acquired_connections`, `.constructing_connections`, `.idle_connections`, `.max_connections`, `.total_connections` | `pgxpool_acquired_connections`, `pgxpool_constructing_connections`, `pgxpool_idle_connections`, `pgxpool_max_connections`, `pgxpool_total_connections` | Resource; không bucket |
| `pgxpool.acquires`, `.canceled_acquires`, `.empty_acquire`, `.max_idle_destroys`, `.max_lifetime_destroys`, `.new_connections` | Tên thay dấu chấm bằng `_`, thêm `_total`, ví dụ `pgxpool_acquires_total` | Resource; không bucket |
| `pgxpool.acquire_duration`, `pgxpool.empty_acquire_wait_time` (counter, `ns`) | `pgxpool_acquire_duration_nanoseconds_total`, `pgxpool_empty_acquire_wait_time_nanoseconds_total` | Resource; không bucket |
| `go.memory.used`, `.limit`, `.allocated`, `.gc.goal` (`By`) | `go_memory_used_bytes`, `go_memory_limit_bytes`, `go_memory_allocated_bytes_total`, `go_memory_gc_goal_bytes` | Resource; không bucket |
| `go.memory.allocations`, `go.goroutine.count`, `go.processor.limit`, `go.config.gogc` | `go_memory_allocations_total`, `go_goroutine_count`, `go_processor_limit`, `go_config_gogc_percent` | Resource; không bucket |
| `db.client.connections.idle.max`, `.idle.min`, `.max`, `.usage` | `db_client_connections_idle_max`, `db_client_connections_idle_min`, `db_client_connections_max`, `db_client_connections_usage` | Resource, `state="idle\|used"` cho usage |
| `db.client.connections.waits`, `.timeouts`, `.hits`, `.misses`, `.waits_duration` (`ns`) | `db_client_connections_waits`, `db_client_connections_timeouts`, `db_client_connections_hits`, `db_client_connections_misses`, `db_client_connections_waits_duration_nanoseconds` | Mặc định redisotel là UpDownCounter, không `_total`; resource và attribute cố định của client |
| `db.client.connections.create_time`, `.use_time` (`ms`) | `db_client_connections_create_time_milliseconds_{bucket,sum,count}`, `db_client_connections_use_time_milliseconds_{bucket,sum,count}` | Bucket mặc định SDK theo đơn vị ms, không ghi đè View H |

Không bật runtime metric cũ bằng `OTEL_GO_X_DEPRECATED_RUNTIME_METRICS`. `otelpgx` đọc stats tối thiểu mỗi 1 s,
nhưng export vẫn 15 s; metric stats không cần query dữ liệu nghiệp vụ.

## 6. Profiling và cổng quản trị

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Pull pprof ở cổng quản trị riêng | Dùng trực tiếp công cụ Go | Thêm listener, route và quyền truy cập; phải bảo vệ theo OPS-1 |
| **pyroscope-go đẩy profile** | Profile liên tục, không mở cổng app, Grafana xem cùng telemetry | Thêm overhead SDK; profile chưa đi cùng pipeline OTel ổn định |
| Profile cả media-worker | Có profile tiến trình Go của worker | Phần CPU chính nằm trong ffmpeg con; phải nới mạng để tới Pyroscope |

### Quyết định

Gateway, user-, video-, engagement-, feed-service đẩy thẳng bằng `pyroscope-go` tới `http://lgtm:4040`, không qua
Collector vì tín hiệu profile OTel còn thử nghiệm. Bật CPU, alloc space, inuse space và goroutine; không mutex/block.
`PYROSCOPE_SERVER_ADDRESS` rỗng thì tắt. media-worker không profile: ffmpeg là tiến trình con và mạng worker không
tới LGTM; dùng CPU/RAM container và metric thời gian transcode để xem nó.

Không import `net/http/pprof`, không handler pprof, không `/metrics`, vì vậy không cần cổng quản trị ở các service.
Test gateway phải xác nhận `/debug/pprof/` và `/metrics` trả **404**; vẫn dùng mux riêng, không `http.DefaultServeMux`.

## 7. Theo dõi lỗi bằng GlitchTip và ranh giới dữ liệu

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Sentry SaaS | Không tốn RAM local, học đúng UI Sentry | Máy chặn `sentry.io` có chủ đích nên UI/login/API không dùng được; cần tài khoản và đưa dữ liệu ra ngoài |
| Sentry tự host | Đúng sản phẩm, dữ liệu ở local | Cần khoảng 16 GB RAM riêng theo ràng buộc plan, không vừa máy |
| **GlitchTip tự host, giao thức Sentry** | Không tài khoản ngoài, dữ liệu ở local; SDK đổi sang SaaS bằng DSN; bản hiện tại chạy được không Valkey | UI/tính năng khác Sentry, thêm database, migration và vận hành |
| Lọc mọi chuỗi bằng regex rồi gửi lỗi đầy đủ | Giữ nhiều nội dung để đọc ngay trong tracker | Mật khẩu và giá trị panic tùy ý không có mẫu nhận diện đáng tin |

### Quyết định

Chọn **GlitchTip 6.2.6** (image/digest ở mục 9), `sentry-go` và gói `internal/sentryx` giữ tên như kế hoạch.
Không cần tra quota Sentry SaaS cho cấu hình này. Không tạo tài khoản ngoài, không sửa `/etc/hosts`. Dù tracker ở
local, vẫn giữ JWT-8 để không tích luỹ bí mật và giữ an toàn khi đổi DSN sang SaaS sau này.

**Hợp đồng ứng dụng:**

- `sentryx.Init(service)` đọc `SENTRY_DSN`: rỗng → tắt, không gọi mạng. `SENTRY_ENVIRONMENT` mặc định `local`.
  `SendDefaultPII=false`, `AttachStacktrace=true`, tắt tracing Sentry; flush tối đa **2 s** lúc tắt. Một organization
  `svp`, một project `svp` chung mọi service; tag `service` phân biệt nguồn.
- Handler slog gửi bản ghi mức ≥ ERROR. Panic đã log ERROR kèm stack; gateway log ERROR khi trả 5xx từ gRPC;
  `grpcserver` log ERROR cho `UNKNOWN`, `INTERNAL`, `DATA_LOSS`. Không biến lỗi 4xx dự kiến thành event lỗi.
- Event có tag `service`, `trace_id`, `span_id`, context `trace`. Chỉ chuyển attribute allowlist có giá trị đã kiểm là
  ID/mã cố định: `method`, `route`, `status`, `code`, `target`, `topic`, `partition`, `offset`, `loop`, `video_id`,
  `user_id`, `event_id`. Không coi một chuỗi bất kỳ đặt dưới key allowlist là đã an toàn; route phải là pattern.
- Message là hằng của log như `"internal error"`, không nối giá trị động. Exception chỉ mang **kiểu lỗi trong cùng**
  theo chuỗi `errors.Unwrap` (`%T`, ví dụ `*pgconn.PgError`) và mã an toàn nếu có (SQLSTATE, gRPC code), không mang
  `err.Error()`. Panic chỉ mang kiểu, không giá trị. Stack chỉ có frame (hàm/file/dòng), không biến. Nội dung lỗi đầy
  đủ chỉ nằm trong log local stdout/Loki, tìm bằng `trace_id`. Bỏ nội dung tự do là biện pháp chính, regex là lớp phụ.
- `BeforeSend` bỏ hẳn `Request` (header, cookie, body, query); `User` chỉ giữ `id`. Che email theo
  `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}` và JWT theo
  `eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+` trong message, exception, extra, tag và breadcrumb.
- Mỗi fingerprint (`service` + message + `route`) tối đa **1 event/30 s**; cả tiến trình tối đa **60 event/phút**.
  Phần vượt bỏ, báo bằng metric hoặc WARN có giới hạn để không tạo vòng lặp. Transport mặc định bất đồng bộ;
  GlitchTip không tới được thì bỏ event, không chặn request và không retry vô hạn trong luồng request.
- media-worker **không gửi lỗi** tới GlitchTip: giữ mạng worker như ADR-0008 §9; không thêm tracker vào mạng đó.
  Lỗi worker thấy qua trace/log/metric và DLQ. Collector là đích telemetry duy nhất được thêm cho worker.

**Thành phần local và database:**

GlitchTip 6.2.6 có web Granian và worker `django-vtasks` chạy **all-in-one** trong một container `glitchtip`, một
process web worker. Đặt `GLITCHTIP_EMBED_WORKER=true`, `VALKEY_URL=""` **tường minh**: queue/cache/session dùng
PostgreSQL; không bỏ biến rồi rơi về mặc định `redis://redis:6379/0`. Không dùng Redis native hay thêm Valkey ở tải
lab hiện tại. Nếu sau này cần Valkey, chỉ dựng container riêng profile `obs`, không lấy thêm db Redis native.
Khả năng không Valkey được xác nhận cả [tài liệu cài đặt chính thức](https://glitchtip.com/documentation/install/)
(tra 2026-10-16) và source/settings/runtime của image.

Chọn database native **`svp_glitchtip`** ở `127.0.0.1:5432`, container tới qua `host.docker.internal:5432`, thay vì
container Postgres thứ hai: dùng lại bản native, tiết kiệm RAM và giữ cách bootstrap của project. Tạo role riêng
`svp_glitchtip_migrator` (owner, không superuser/CREATEDB/CREATEROLE) và `svp_glitchtip_app` (DML), revoke quyền
PUBLIC và default privileges như `deploy/postgres/bootstrap.sql`. Không truy cập database của service nghiệp vụ.

`DATABASE_URL` dùng app role; `MAINTENANCE_DATABASE_URL` dùng migrator role để quản lý partition và retention.
All-in-one giữ cả hai credential vì worker làm bảo trì partition; đây là quyền DDL giới hạn trong database tracker,
không phải mức cô lập credential như hai container web/worker tách riêng. Probe đã chạy với app role không có quyền
CREATE schema và không superuser. Chọn `VTASKS_CONCURRENCY=2`, `DATABASE_POOL_MAX_SIZE=4`, `GRANIAN_WORKERS=1`;
tắt uptime, log ingest, DuckDB và API metric GlitchTip để chỉ học error tracking. Không bật tracing tự theo dõi của nó.

**Khởi tạo bằng lệnh, không bấm tay:** một job `glitchtip-init` dùng cùng image, xong mới cho web chạy. Thứ tự:

```sh
python manage.py migrate --no-input --database maintenance
python manage.py createcachetable --database maintenance
python manage.py maintain_partitions
python manage.py shell < /init/bootstrap.py
```

Đây là lệnh **trong container**, sau này bọc bằng Makefile/compose. Main all-in-one đặt `SKIP_INIT=true`.
`createcachetable` phải chạy bằng migrator: script mặc định gọi nó bằng default app role và lần đầu sẽ lỗi quyền
CREATE. File cache không được tạo bởi migration Django. Không nới quyền app để né bước init này.

`bootstrap.py` dùng ORM của image, đã probe thành công và idempotent:

1. `User.objects.get_or_create(email=...)`; chỉ khi tạo mới mới `set_password`, đặt `is_staff/is_superuser`.
   `EmailAddress.objects.get_or_create(..., defaults={primary: True, verified: True})` cho tài khoản local.
2. `Organization.objects.get_or_create(slug="svp", ...)`; thêm user bằng `org.add_user` nếu chưa là thành viên.
3. `Project.objects.get_or_create(organization=org, slug="svp", ...)`; `Team` slug `svp`, thêm organization-user và
   project vào team. Signal của project tạo `ProjectKey`; lấy key đang active và `get_dsn()`.
4. `APIToken.objects.get_or_create(user=admin, label="svp-drill")`, `add_permissions(["event:read", "project:read"])`.
   Model sinh token ngẫu nhiên; không dùng `bootstrap_dev` vì lệnh đó cần DEBUG và hard-code password/token.
5. Ghi DSN/token cho script host bằng kênh output được capture, không echo lên terminal; script cập nhật `.env`
   nguyên tử mode 600, giữ giá trị hiện có. DSN cho Go service đổi host sang `glitchtip:8000`; DSN browser dùng
   `127.0.0.1:8000`. Không nhầm địa chỉ loopback của container với host.

`make env` sinh ngẫu nhiên `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_PASSWORD`,
`SVP_GLITCHTIP_MIGRATOR_DB_PASSWORD`, `SVP_GLITCHTIP_APP_DB_PASSWORD`, và ghi admin email local cố định
`GLITCHTIP_ADMIN_EMAIL=admin@svp.local` (địa chỉ không có hộp thư thật; đổi trong `.env` thì giữ giá trị đã đặt). `SECRET_KEY` trong container lấy từ `GLITCHTIP_SECRET_KEY`. **DSN và API token sinh sau
init**, thành `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`; `SENTRY_ORG=svp`, `SENTRY_PROJECT=svp`,
`SENTRY_API_URL=http://127.0.0.1:8000` cho script host. `.env` không commit; lệnh đo/diễn tập không in các giá trị này.
`EMAIL_URL=consolemail://` cho local, không SMTP; tắt self-registration (`ENABLE_USER_REGISTRATION=false`), DEBUG tắt.

**API diễn tập:** Bearer token hai scope ở trên. Đã kiểm HTTP 200 với event có tag `trace_id`:

| Mục đích | GET path dưới `SENTRY_API_URL` |
| --- | --- |
| Tìm issue theo trace | `/api/0/projects/svp/svp/issues/?query=trace_id%3A<hex-trace-id>` |
| Liệt kê event của issue | `/api/0/issues/<issue-id>/events/` |
| Đọc event bằng SDK event ID | `/api/0/projects/svp/svp/events/<event-id>/` |

Query issue là tìm trong tập tag đã ghi của issue; không suy rằng event mới nhất của issue là event vừa tìm.
Diễn tập phải đọc event và kiểm tag/context trace đúng; theo pagination nếu có. Không dùng API endpoint Sentry SaaS
hoặc giả định mọi API Sentry đều được GlitchTip hỗ trợ. Retention lỗi local đặt **14 ngày**, không bật cold storage.

## 8. SLO và cảnh báo

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Tự viết mọi recording/alert rule SLO | Toàn quyền công thức | Dễ lệch cửa sổ và burn rate giữa các SLO |
| **Sloth sinh rule; Alertmanager định tuyến** | Một đặc tả SLO, quy tắc nhiều cửa sổ có sẵn, test được bằng promtool | Thêm CLI và file sinh phải giữ khớp |
| SLO riêng cho mọi metric kể cả freshness | Nhiều mục tiêu định lượng | Event local thưa, burn rate ít có ý nghĩa; báo động khó giải thích |
| Gộp `max by (service_name, loop)` trước khi tính tuổi | Instance mới khoẻ che được series cũ sau restart | Một replica khoẻ cũng che replica đang đứng |
| **Chỉ xét mẫu gauge mới hơn 45 s, giữ từng instance** | Loại series đã ngừng gửi mà vẫn phát hiện từng replica lỗi | Khoảng mất telemetry từ 45 s reset thời gian chờ cảnh báo; không phát hiện được tiến trình đã ngừng export |

### Quyết định

Ghim **`github.com/slok/sloth/cmd/sloth@v0.16.0`**, cài qua `make tools`, không thêm đồ thị công cụ vào module app.
Spec `deploy/observability/slo/svp-slos.yaml`; `make slo` sinh
`deploy/observability/prometheus/rules/slo-generated.yaml`, commit cả file sinh. `make tools` ghi version vào binary
bằng `-ldflags`, nếu không `go install` để version rỗng và header file sinh ghi `dev`; chạy `make slo` lại cho cùng
file. Cửa sổ **30 ngày**; page mặc định
**14,4×** với 1 h/5 m và **6×** với 6 h/30 m; ticket **3×** với 1 d/2 h và **1×** với 3 d/6 h.

**SLI 30 ngày tính thẳng từ query của SLI.** Mặc định Sloth "tối ưu" cửa sổ 30 ngày: `slo:sli_error:ratio_rate30d` là
trung bình các ratio 5 m của 30 ngày (`sum_over_time / count_over_time`). Một cửa sổ 5 m không có request cho ratio
0/0 = NaN, và chỉ một NaN đã làm cả trung bình NaN; ở lab gần như lúc nào cũng có khoảng không traffic, nên SLI 30 ngày,
`slo:period_burn_rate:ratio` và `slo:period_error_budget_remaining:ratio` luôn NaN. Spec khai `slo_plugins` với
`overridePrevious: true` và đúng chuỗi plugin mặc định của Sloth v0.16 (`validate`, `sli_rules`, `metadata_rules`,
`alert_rules`), chỉ đặt `disableOptimized: true` cho `sloth.dev/core/sli_rules/v1`: rule 30 ngày dùng chính error/total
query trên `[30d]` như các cửa sổ ngắn hơn. Sloth vẫn sinh mỗi rule một lần (không viết thêm rule cùng tên bên cạnh),
`make slo` hai lần cho cùng file, và chỉ bốn rule `ratio_rate30d` đổi. Ratio hữu hạn khi 30 ngày có ít nhất một
request, cân mỗi request như nhau thay vì mỗi cửa sổ 5 m như nhau; không có request nào trong 30 ngày thì vẫn không có
giá trị, không báo SLO tốt giả. Đổi lại Prometheus đọc 30 ngày series gốc mỗi lần đánh giá (15 s) thay vì series ghi
sẵn 5 m: ở lab vài chục series gateway và vài giờ dữ liệu mỗi buổi nên không đáng kể; lên cluster có traffic thật thì
đo lại và cân nhắc bật lại tối ưu (traffic liên tục thì không còn cửa sổ NaN) hoặc cho nhóm rule SLO chu kỳ dài hơn.

Prometheus giữ dữ liệu **30 ngày** bằng `storage.tsdb.retention.time: 30d` trong file cấu hình ghi đè (cờ dòng lệnh
cùng tên đã deprecated ở 3.15.0). Mặc định của binary là 15 ngày: lỗi ở ngày thứ 5 bị xoá quanh ngày thứ 20 trong khi
vẫn thuộc cửa sổ, nên `slo:sli_error:ratio_rate30d` và ngân sách lỗi còn lại bỏ sót nó. Block chỉ bị xoá khi toàn bộ
block đã cũ hơn hạn, nên 30 ngày gần nhất luôn còn đủ; đĩa và RAM ở mục 13.

Đếm histogram `_count` làm tổng request; mọi selector HTTP có `service_name="gateway"` và method/route dưới đây.
`http.route` không có method. Với video dùng `service_name="video-service"`.

| SLO | Mục tiêu | Tổng / sự kiện xấu |
| --- | --- | --- |
| `feed-availability` | 99,9% | Tổng HTTP `GET`, route `/feed/following` hoặc `/feed/explore`; xấu là `http_response_status_code=~"5.."` |
| `upload-init-availability` | 99,9% | Tổng `POST /videos`; xấu là 5xx |
| `feed-latency` | 99% trong bucket 150 ms | Tổng hai route feed GET; xấu = `_count` trừ `_bucket{le="0.15"}` của `http_server_request_duration_seconds` |
| `video-ready-latency` | 95% trong bucket 120 s | Tổng `svp_video_ready_duration_seconds_count` mọi outcome; tốt là `_bucket{outcome="ready",le="120"}`, xấu = tổng − tốt |

Sloth dùng `rate` trên `{{.window}}`, tổng hợp cùng bộ label trước khi trừ. Hai SLO availability tổng hợp toàn bộ
route của SLO bằng `sum` không `by`; error query là `sum(rate(<selector 5xx>[{{.window}}])) or vector(0)` để trả
0 khi đã có request nhưng chưa có series 5xx. Total query giữ `sum(rate(<selector tổng>[{{.window}}]))`, không
thêm request hay ép mẫu số thành 1: không có traffic thì không báo SLO tốt giả. SLO video cũng dùng
`sum(rate(<selector tổng>[{{.window}}])) - (sum(rate(<selector ready, le="120">[{{.window}}])) or vector(0))`
cho error query, để chỉ có `failed` vẫn có lỗi. Không đặt `or vector(0)` sau cả phép trừ vì sẽ che mất tổng failed.
`FAILED` luôn xấu dù rất nhanh. Bucket `le` có biên bao gồm đúng ngưỡng; đây là cách biểu diễn bằng histogram của
NFR p99 150 ms/p95 120 s. Freshness p95 < 10 s là panel
và `make measure-freshness`, chưa là SLO vì local quá ít event để burn rate hữu ích.

Rule viết tay ở `deploy/observability/prometheus/rules/svp-alerts.yaml`, evaluation interval **15 s**:

| Alert | Điều kiện | `for` | Severity |
| --- | --- | --- | --- |
| `KafkaConsumerLagHigh` | `max by (redpanda_group) (redpanda_kafka_consumer_group_lag_max) > 0`, nhóm video/feed/engagement | 2 m | page |
| `KafkaConsumerLagHigh` | Cùng điều kiện, nhóm media-worker; biên rộng hơn một lần thử hợp lệ 15 phút | 20 m | page |
| `BackgroundLoopStalled` | Mẫu mới hơn 45 s; last-success > 0 và tuổi **tính tại thời điểm mẫu** quá ngưỡng + `for` của bảng dưới, hoặc mọi mẫu = 0 suốt ngưỡng + `for`; công thức bên dưới | 0 s | page |
| `RateLimitFallbackActive` | Counter fallback tăng trong 1 m **hoặc** series mới quan sát đã > 0; công thức bên dưới | 0 s | page |
| `KafkaDLQRecords` | Counter DLQ tăng trong 10 m **hoặc** series mới quan sát đã > 0; công thức bên dưới | 0 s | page |
| `CircuitBreakerOpen` | Mẫu mới hơn 45 s và `svp_breaker_state{service_name="gateway"} > 0` ở **mọi mẫu của 1 phút** (≥ 5 mẫu) theo target/instance; công thức bên dưới | 0 s | page |

Hai rule counter dùng công thức sau. Kiểm series mới trên **đủ label, gồm instance**, trước khi tổng hợp; không
để instance cũ che lần khởi động mới. Nhánh `unless ... offset` bắt mẫu đầu đã > 0, kể cả burst nằm trong một kỳ
export 15 s; chỉ `increase` và khởi tạo 0 trong SDK không bảo đảm Prometheus từng nhận được mẫu 0.

```promql
sum(increase(svp_ratelimit_decisions_total{service_name="gateway",store="fallback"}[1m])) > 0
or
sum(svp_ratelimit_decisions_total{service_name="gateway",store="fallback"}
    unless svp_ratelimit_decisions_total{service_name="gateway",store="fallback"} offset 1m) > 0
```

```promql
sum by (service_name,topic,group) (increase(svp_kafka_dlq_records_total[10m])) > 0
or
sum by (service_name,topic,group) (svp_kafka_dlq_records_total
    unless svp_kafka_dlq_records_total offset 10m) > 0
```

Series mới bằng 0 không bắn. Counter dương không đổi, đã có đủ lịch sử trong cửa sổ, hết bắn. Sau một khoảng mất
dữ liệu dài, nhánh này có thể cảnh báo lại counter dương cũ: chấp nhận cảnh báo thận trọng khi chưa có mốc so sánh,
không diễn giải nó thành số event mới chính xác. Breaker 2 ↔ 1 không ngắt chuỗi mẫu mở; một mẫu 0 reset cảnh báo.

**Độ mới của gauge:** series đẩy OTLP không có stale marker khi tiến trình dừng; mẫu cuối vẫn có thể được chọn
trong lookback mặc định **5 phút**. Vì mỗi lần khởi động có `service_instance_id` mới, series cũ không được báo lỗi
sau khi instance mới đã khoẻ. Mọi nhánh của `BackgroundLoopStalled` và `CircuitBreakerOpen` thêm
`and (timestamp(<cùng selector gauge>) > time() - 45)`, khớp **đủ label gồm instance**, không tổng hợp trước, không
dùng so sánh `bool`. `timestamp()` đọc thời điểm mẫu, khác giá trị last-success của loop. Biên **45 s = 2 × 15 s
export + 15 s đánh giá**; mẫu đúng 45 s tuổi bị loại. Không lấy `timestamp()` của recording rule trung gian vì
timestamp đánh giá rule có thể làm mẫu nguồn cũ trông như mới.

Bộ lọc này chưa đủ nếu thời lượng đo bằng `for`: trong tối đa 45 s sau mẫu cuối, series cũ vẫn qua bộ lọc nên
pending tiếp tục tích luỹ. promtool 3.15.0 với rule `for` cũ: breaker cũ mở 30 s (mẫu 45–75 s) rồi instance bị thay
lúc 90 s vẫn bắn lúc 105 s; relay thành công lần cuối lúc 31 s, mẫu cuối lúc 135 s, vẫn bắn lúc 165 s. Vì vậy
**thời lượng đo bằng mẫu thật, rule không có `for`**: breaker đếm mẫu trong cửa sổ, loop so thời điểm của chính mẫu với
last-success nó mang. Một instance bị thay chỉ bắn khi chính các mẫu nó đã gửi chứng minh đủ thời lượng, và hết sau
tối đa 45 s.

Cửa sổ đếm mẫu dài hơn thời lượng cần chứng minh **20 s**: 15 s cho mẫu ở đầu chuỗi, 5 s cho độ trễ tới Prometheus
(batch 1 s của Collector) và jitter export. Cửa sổ vừa khít (`[75s]`, ≥ 5 mẫu) chứa đúng 5 mẫu chỉ khi mẫu mới nhất đã
tới; nếu pha export trùng pha đánh giá trong vòng độ trễ đó thì lần đánh giá nào cũng chỉ thấy 4 mẫu và cảnh báo không
bao giờ bắn, hoặc bật tắt liên tục khi jitter. Đổi lại cảnh báo bắn sau 60–75 s thay vì đúng 60 s. Breaker:

```promql
(min_over_time(svp_breaker_state{service_name="gateway"}[80s]) > 0)
and (count_over_time(svp_breaker_state{service_name="gateway"}[80s]) >= 5)
and (timestamp(svp_breaker_state{service_name="gateway"}) > time() - 45)
```

Khi loop đứng nhưng SDK vẫn export giá trị cũ mỗi 15 s, mẫu vẫn mới và cảnh báo phải bắn đúng hạn. Khi không còn
mẫu mới, điều kiện mất sau tối đa 45 s kể từ mẫu cuối (cộng tối đa một kỳ đánh giá) và cảnh báo đang firing được
resolve; đó là **mất telemetry**, không khẳng định loop đã phục hồi. Cảnh báo này không thay kiểm tra service/Collector
sống.

Lag > 0 phát hiện cả một record bị kẹt; không chọn ngưỡng hàng trăm record khiến một video đứng mãi bị bỏ qua.
Ngưỡng local có chủ đích báo khi backlog kéo dài; cần đo lại với tải liên tục trước production. Worker retry có thể
kéo dài hơn 20 phút khi phụ thuộc hỏng, lúc đó alert là hữu ích dù job chưa hết mọi lần thử.

Ngưỡng vòng nền ≥ `max(3 × chu kỳ + thời gian xử lý hợp lệ tối đa, 2 × 15 s export + 15 s đánh giá)`, làm tròn lên
và cộng thêm `for` của bảng. Cột `for` là phần thời lượng cộng vào ngưỡng, rule không đặt `for:`. Bao gồm hạn rollback
5 s, không coi một lần thành công không có việc là đứng:

| `loop` | Chu kỳ | Hạn xử lý và thu hồi tối đa dùng tính biên | Ngưỡng không thành công | `for` |
| --- | --- | --- | --- | --- |
| `outbox-relay` | 200 ms khi rảnh; backoff lỗi tối đa 10 s | 5 s đọc/khoá + 10 s produce + 5 s đánh dấu/commit + 5 s rollback | 60 s | 1 m |
| `outbox-cleanup` | 10 phút | 30 s cả lượt + 5 s rollback nếu có transaction | 31 phút (1860 s) | 1 m |
| `upload-sweep` | 5 phút | 30 s/lô + 5 s rollback; làm mới sau từng lô | 16 phút (960 s) | 2 m |
| `timeline-prune` | 1 giờ | 2 phút cả lượt + 5 s rollback | 3 giờ 5 phút (11100 s) | 5 m |

`promtool test rules` khi hiện thực phải có cả vòng khoẻ (các lần export, no-op và xử lý sát timeout không bắn) lẫn
vòng đứng thật (qua ngưỡng + `for` thì bắn), theo từng loop. Không dùng một ngưỡng chung vài giây cho cả bốn vòng.

Mỗi loop một rule, hai nhánh loại trừ nhau, `D` = ngưỡng + `for` của bảng: relay **120 s**, cleanup **1920 s**, sweep
**1080 s**, prune **11400 s** (3 h 10 m):

```promql
(
  (timestamp(svp_loop_last_success_seconds{loop="..."}) - svp_loop_last_success_seconds{loop="..."} > D)
  and (svp_loop_last_success_seconds{loop="..."} > 0)
  or
  (max_over_time(svp_loop_last_success_seconds{loop="..."}[D + 20s]) == 0)
  and (count_over_time(svp_loop_last_success_seconds{loop="..."}[D + 20s]) >= D / 15 + 1)
)
and (timestamp(svp_loop_last_success_seconds{loop="..."}) > time() - 45)
```

Nhánh đầu là loop đã từng thành công: tuổi last-success đo tại thời điểm của mẫu, nên bắn trễ tối đa một kỳ export so
với `time()`. Nhánh sau là loop chưa từng thành công: mọi mẫu suốt `D` bằng 0 (9 / 129 / 73 / 761 mẫu), không lấy
`time() - 0` làm tuổi. Thời gian nhánh 0 tính bằng mẫu Prometheus đã nhận liên tục của cùng instance; mất series hay
restart thì đếm lại, không coi mất telemetry là bằng chứng loop đã chạy. Một lần prune đầu lỗi rồi lần sau thành công
sau 1 giờ không bắn oan ở phút 5. Hai nhánh gộp bằng `or` vì cùng không có `for`; label `loop` tĩnh của rule trùng
label của selector, chỉ để `promtool check rules` phân biệt bốn rule cùng tên (lint rule trùng). Vì lý do đó rule lag
của media-worker cũng có label tĩnh `redpanda_group: media-worker`.

Test ở `deploy/observability/prometheus/rules/svp-alerts.test.yaml`, chạy bằng `make slo-check` (promtool của image
LGTM ghim, không mạng; `check config` cho cấu hình Prometheus và hai file rule, rồi `test rules`). Mẫu cách 15 s, series
dừng viết bằng `_` (thiếu mẫu), **không dùng `stale`**. Các ca:

- Counter: `0 → 1` rồi giữ nguyên bắn rồi hết; series sinh ra ở > 0 (DLQ đầu tiên, burst fallback trước export đầu)
  bắn tới khi đủ lịch sử; restart instance (cũ dừng ở 5, mới sinh ở 2) bắn; toàn 0 và counter store Redis tăng không
  bắn.
- Breaker: 2/1 xen kẽ với traffic thưa bắn sau 1 phút mẫu, một mẫu 0 thì hết; mở dưới 1 phút không bắn; gateway dựng
  lại khi breaker đang mở 30 s và 45 s (instance cũ dừng, instance mới đóng) không bắn tới 5 phút sau; breaker mở ở
  mẫu cuối của instance cũ không bắn; một instance mở bắn dù instance khác đóng, và hết sau khi nó dừng export.
- Từng loop: vòng khoẻ (relay có lượt chậm 50 s, các vòng khác mỗi lượt xong trễ 30 s) không bắn; vòng đứng sau một lần
  thành công mà vẫn export bắn đúng mẫu đầu tiên quá `D`, instance khác khoẻ không che, và còn bắn ở tuổi mẫu 30 s, hết
  từ 45 s; chưa từng thành công bắn đúng lúc đủ `D`, không bắn sớm một mẫu; thành công đầu trước biên không bắn;
  instance bị thay khi sát biên (relay: thành công lần cuối 31 s, mẫu cuối 135 s, instance mới từ 150 s) và khi chưa
  từng thành công (nhánh 0 thiếu một mẫu) không bắn tới 5 phút sau.
- Lag: feed-service lag 2 phút bắn, media-worker lag trong một lần transcode 10 phút không bắn.
- Recording rule Sloth: chỉ 2xx có traffic cho error ratio 0; 5xx tính lỗi; một nửa request feed quá 150 ms cho
  0,5; cửa sổ chỉ có video failed cho ratio 1; không traffic không có ratio (không tạo request tốt giả); traffic thưa
  (2 phút request rồi 2 giờ không) cho ratio 5 m NaN nhưng SLI 30 ngày, burn rate kỳ và ngân sách còn lại hữu hạn, đúng
  tỉ lệ lỗi trên tổng request (rule tối ưu cũ cho NaN ở cùng ca).

Chạy chính bộ test với rule `for` cũ thì hai ca dựng lại instance (breaker mở 30 s, relay 31/135 s) bắn như mô tả ở
trên, nên bộ test bắt được lỗi đã sửa.

Prometheus nạp cả rule sinh và rule viết tay, gửi `alertmanager:9093`. Alertmanager riêng, profile `obs`, publish
UI/API **`127.0.0.1:9093`**. `group_wait: 10s`, `group_interval: 1m`, `repeat_interval: 4h`. Receiver mặc định rỗng;
chỉ `severity="page"` đi Telegram khi có đủ `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID`. Ticket
luôn ở receiver chỉ xem UI: cửa sổ 1 d/3 d còn bắn nhiều ngày sau diễn tập trên volume giữ lại, không gửi mỗi 4 giờ.

Alertmanager không tự thay biến môi trường trong YAML. Script khởi động render cấu hình theo việc có đủ hai biến,
ghi token vào file riêng mode 600 cho `bot_token_file`, không echo token; token/chat ID rỗng thì cấu hình vẫn hợp lệ
với receiver rỗng. Token vào container bằng **compose secret** lấy từ biến trong `.env` (không phải biến môi trường
nên `docker inspect` không thấy); compose từ chối secret từ biến chưa đặt nên `make up OBS=lgtm` truyền biến rỗng khi
`.env` không có dòng đó. Chat ID phải là số nguyên, sai thì tắt Telegram. Không thêm Slack: một kênh đủ cho bài học.
Luồng kiểm UI/API vẫn chạy được không tài khoản ngoài; Telegram chỉ kiểm sau khi người học điền hai biến.

Silence và notification log của Alertmanager nằm ở volume có tên `alertmanager-data` (`/alertmanager`), không ở volume
ẩn danh của image: restart không quên silence, không gửi lại cảnh báo đang firing trước `repeat_interval`; `make down`
giữ volume, `make clean-data` xoá nó cùng các volume khác của stack.

## 9. Stack local, image và đường dẫn cấu hình

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **LGTM dev image + Collector/Alertmanager/GlitchTip riêng** | Nhanh có UI và liên kết tín hiệu; các thành phần cần kiểm soát vẫn tách rõ | LGTM gộp nhiều tiến trình; phụ thuộc đường dẫn image, chỉ dùng dev |
| Tách mọi backend thành container riêng ngay | Giới hạn tài nguyên/nâng version riêng | Nhiều cấu hình, volume và healthcheck trước khi học luồng telemetry |
| Bật cả LGTM và Elastic | So song song ngay | Vượt mục đích và ngân sách RAM 16 GB |

### Quyết định

Profile `obs` gồm **`otelcol`, `lgtm`, `alertmanager`, `glitchtip`** và job `glitchtip-init` một lần.
`obs-elastic` gồm `otelcol` cấu hình Elastic, Elasticsearch, Kibana, APM Server; image/digest Elastic chốt ở
ADR-0012 sau bài so sánh. Không bao giờ bật cả hai bộ. GlitchTip chỉ cần trong `obs` của bài học lỗi chính;
bài so sánh Elastic không so error tracker hay profile.

| Image | Tag cụ thể | Digest manifest list / OCI index đa kiến trúc |
| --- | --- | --- |
| `grafana/otel-lgtm` | `0.36.0` | `sha256:57c04cbd8e7022f32bb84c4ac005d79baf8b08e2c5be44facf11f5f1f9944ba2` |
| `otel/opentelemetry-collector-contrib` | `0.162.0` | `sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6` |
| `prom/alertmanager` | `v0.34.1` | `sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a` |
| `glitchtip/glitchtip` | `6.2.6` | `sha256:a3d8eb1b36c1e1603d55ab32711ea3dd8115874742a781a57391a62a16e0dff6` |

Compose dùng `repository:tag@sha256:...`, không `latest`; các index trên đều có **linux/arm64 và linux/amd64**.
LGTM chứa Grafana **13.2.3**, Prometheus **3.15.0**, Tempo **3.1.0**, Loki **3.7.8**, Pyroscope **2.3.1**,
Collector **0.162.0** (đọc env/label trong image). Không nhầm digest manifest arm64 với digest index ở bảng.

Đã kiểm script và thử bind mount read-only lúc chạy:

| Thành phần | Đường dẫn trong LGTM / cách nạp | Thiết lập cần giữ |
| --- | --- | --- |
| Prometheus | `/otel-lgtm/prometheus.yaml`, `run-prometheus.sh` đọc trực tiếp `--config.file` | OTLP receiver, remote-write receiver, exemplar; thêm `rule_files`, `alerting.alertmanagers` và evaluation 15 s; dữ liệu `/data/prometheus` |
| Tempo | `/otel-lgtm/tempo-config.yaml`, `run-tempo.sh` | `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]`; remote-write `http://127.0.0.1:9090/api/v1/write`, `send_exemplars: true` |
| Loki | `/otel-lgtm/loki-config.yaml`, `run-loki.sh` | Schema v13, filesystem `/data/loki`, override nhãn OTLP ở mục 4 |
| Collector tích hợp | `/otel-lgtm/otelcol-config.yaml` | Đường tới Prometheus `/api/v1/otlp`, Loki `/otlp`, Tempo `127.0.0.1:4418` |
| Grafana datasource | `/otel-lgtm/grafana/conf/provisioning/datasources/grafana-datasources.yaml` | UID `prometheus`, `tempo`, `loki`, `pyroscope`; giữ liên kết hai chiều và serviceMap tới `prometheus`, timeInterval 15 s |
| Grafana dashboard | `/otel-lgtm/grafana/conf/provisioning/dashboards/` | Mount provider YAML tại đây; provider trỏ thư mục dashboard JSON được mount riêng |

Script không render đè các file cấu hình trên. `run-grafana.sh` đặt `GF_PATHS_HOME=/data/grafana` nhưng runtime vẫn
nạp provisioning từ cây `/otel-lgtm/grafana/conf/provisioning`; probe đổi tên datasource và API xác nhận có hiệu lực.
Không suy ra đường dẫn mount từ `GF_PATHS_HOME` rồi gắn vào `/data/grafana/conf` vốn không tồn tại ở image mới.
LGTM `/data` giữ dữ liệu backend; rule, provisioning và dashboard là file quản lý trong repo, không sửa tay trong UI.

| Lệnh Makefile | Hành vi cần hiện thực |
| --- | --- |
| `make up` | Giữ mặc định chỉ `core`; SDK bật nhưng backend observability không có |
| `make up OBS=lgtm` | `core` + `obs` |
| `make up OBS=elastic` | `core` + `obs-elastic` |
| `make up OBS=off` | `core`, `OTEL_SDK_DISABLED=true`, Pyroscope/Sentry rỗng để đo mốc tắt hẳn |
| `make down` | Gỡ mọi profile, giữ volume; không để profile obs chạy sót |

Publish chỉ loopback: Grafana **3000**, GlitchTip **8000**, Alertmanager **9093**, Kibana **5601**. Cổng 8000 đã kiểm
chưa có listener ngày 2026-10-16. Giữ các cổng core hiện có. Không publish Collector **4317**, Prometheus **9090**,
Tempo **3200** (OTLP nội bộ **4417/4418**), Loki **3100**, Pyroscope **4040**. Script host truy vấn qua Grafana:

```text
/api/datasources/proxy/uid/prometheus/api/v1/query
/api/datasources/proxy/uid/loki/loki/api/v1/query_range
/api/datasources/proxy/uid/tempo/api/traces/<trace-id>
/api/datasources/proxy/uid/pyroscope/...
```

**Grafana không tải plugin lúc chạy.** Image gọi grafana.com mỗi lần khởi động: `run-grafana.sh` thêm
`grafana-llm-app` vào `GF_PLUGINS_PREINSTALL`, Grafana 13 tự thêm các app Drilldown (Metrics/Logs/Traces/Profiles) và
advisor, `preinstall_auto_update = true` cập nhật chúng lên bản mới nhất, không ghim version. Đó là lưu lượng ra ngoài
ngoài danh sách được phép của lab (module Go, `go install`, pull image) và là code không ghim chạy trong Grafana
anonymous Admin. Compose đặt `GF_PLUGINS_PREINSTALL_DISABLED=true`, `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`,
`GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED=true` (khoá ký plugin dùng bản có sẵn trong binary, không tải mỗi 10 ngày),
cùng ba `GF_ANALYTICS_*=false` đã có. **Chấp nhận mất** app Drilldown và LLM trên volume `lgtm-data` mới; volume đã
có giữ bản đã tải, không cập nhật nữa. Datasource Prometheus, Tempo, Loki, Pyroscope đi kèm bản Grafana của image,
không phải plugin tải về; dashboard, Explore và liên kết trace ↔ log không phụ thuộc các app đó. Đã kiểm bằng
`run-grafana.sh` của image ghim, `--network none`, thư mục dữ liệu mới: mặc định `plugin.backgroundinstaller` ghi
"Installing plugins" và lỗi gọi `https://grafana.com/api/plugins/...`; với các biến trên, sau 60 s không có dòng nào của
installer, không lỗi tới grafana.com, API vẫn liệt kê đủ datasource. Trên stack `make up OBS=lgtm` với volume cũ
(2026-10-17): môi trường của tiến trình Grafana có đủ ba biến, mọi kết nối TCP đã thiết lập trong container chỉ tới
loopback và mạng compose, thư mục plugin giữ nguyên thời điểm tải hôm trước. Image bỏ stdout của Grafana
(`ENABLE_LOGS_GRAFANA` không đặt) và không ghi file log, nên lượt này không có log Grafana để đọc.

Grafana anonymous Admin của image chỉ chấp nhận vì **loopback, dev local** (OPS-2); giai đoạn 4 có đăng nhập.
GlitchTip dùng tài khoản admin ngẫu nhiên ở mục 7. Profile không tự biến các UI này thành endpoint công khai.

Biến compose cho service: `OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol:4317`,
`OTEL_EXPORTER_OTLP_INSECURE=true`, `PYROSCOPE_SERVER_ADDRESS=http://lgtm:4040`, `SENTRY_DSN=${SENTRY_DSN:-}`,
`SENTRY_ENVIRONMENT=local`. Bỏ Pyroscope/Sentry ở worker. Profile tắt thì DNS `otelcol` không tồn tại, service vẫn
chạy theo mục 10. LGTM và service không phụ thuộc readiness backend observability để khởi động.

## 10. Backend observability không tới được và phép đo overhead

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Export đồng bộ, lỗi thì dừng service | Ít mất telemetry | Collector hỏng làm API hỏng theo, trái mục tiêu quan sát hệ thống |
| **Export bất đồng bộ, hàng đợi có hạn, bỏ khi đầy** | Request không chờ backend; chạy core độc lập | Mất telemetry trong sự cố, không dùng làm audit log bền |
| Luôn dùng endpoint mặc định SDK | Ít cấu hình | Native/test tự gọi `localhost:4317` ngoài địa chỉ được phép |

### Quyết định

- Chỉ nhánh **`serve`** (kể cả mặc định không có đối số) khởi tạo OTel, Sentry và Pyroscope, một lần mỗi tiến trình
  phục vụ. Thực hiện sau khi chọn lệnh con, trước khi mở listener/chạy consumer; flush/shutdown thuộc cùng vòng đời.
  `healthcheck`, `migrate` và lệnh không hợp lệ chỉ có logger stdout, không provider, resource instance, profiler hay
  Sentry handler, kể cả khi kế thừa đủ biến endpoint/DSN từ compose. Không đặt Setup cạnh `logx.New` hiện ở đầu main.
  Compose chạy `/app healthcheck` mỗi 10 s; tách vòng đời này tránh hàng nghìn instance metric/profile và event lỗi
  probe mỗi ngày. Test lệnh con với exporter/transport giả phải thấy **0 lần khởi tạo/gửi**; test HTTP `/healthz`,
  `/readyz` và gRPC Health/Check không tạo span, còn request nghiệp vụ vẫn tạo trace như mục 3.
- `telemetry.Setup` dùng gRPC dial lười, không lỗi vì Collector chưa có. Batch span processor và batch log processor
  hàng đợi **2048** mỗi loại, đầy thì bỏ, không block request; metric reader **15 s**, export timeout **5 s**.
- Shutdown cả ba provider dùng **một ngân sách chung 5 s**, không lần lượt 5 s mỗi provider. Lỗi nội bộ OTel qua
  `otel.SetErrorHandler` log WARN tối đa **một dòng/phút**, tránh bão log khi DNS/backend hỏng.
- `OTEL_SDK_DISABLED=true` không dựng provider. Endpoint `OTEL_EXPORTER_OTLP_ENDPOINT` **rỗng hoặc không đặt** thì
  không dựng exporter, không rơi về `localhost:4317` của SDK. Tương tự địa chỉ Pyroscope/DSN rỗng thì tắt hẳn.
- Profile `obs` tắt không làm readiness của ứng dụng lỗi. Test đơn vị dùng cổng do chính test mở rồi đóng, không thử
  tới một cổng localhost đoán sẵn; kiểm Setup, request và Shutdown có hạn. Kiểm `make smoke` khi obs tắt.
- Đo cùng tải ba trạng thái: **a** `OBS=off`; **b** `OBS=lgtm`, backend tới được; **c** `make up`, SDK bật/backend
  không tới được. Ghi p50/p95 độ trễ, CPU, RAM; công bố riêng **b−a** và **c−a**, không dùng trạng thái c làm mốc
  “telemetry tắt”. Phép đo này thuộc giai đoạn hiện thực; RAM probe mục 13 chưa phải kết quả overhead ứng dụng.

## 11. Hạn của pool và vòng nền

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ context vòng đời tiến trình cho I/O nền | Ít context/cancel | Một khoá Postgres treo làm vòng đứng mãi; shutdown cũng có thể chờ mãi |
| **Deadline từng bước/lần thử, rollback có hạn riêng** | Khoá được nhả và vòng thử lại được; không phụ thuộc timeout server | Phải tách hạn bước Postgres khỏi produce, trả lỗi timeout như lỗi tạm |
| Một deadline 5 s cho mọi việc nền | Đơn giản | Cắt fan-out hợp lệ và transcode, gây retry/DLQ oan |
| Giữ producer idempotent mặc định, chỉ thêm deadline context | Giữ chống trùng khi Kafka chưa xác nhận kết quả | `ProduceSync` có thể chờ quá deadline cho record đang gửi, giữ khoá relay hoặc RPC |
| **Cho huỷ produce idempotent đang gửi** | Deadline giải phóng lời gọi ngay cả khi kết quả broker chưa rõ | Gửi lại record đã huỷ có thể tạo bản sao; phải phân biệt timeout với chắc chắn chưa ghi |

### Quyết định

Bổ sung kiểm kê ADR-0010 §4 bằng bảng sau; không đổi ngân sách gRPC/Redis/HTTP hiện có. Hạn xử lý luôn gồm commit;
rollback không dùng context đã hết hạn.

| Lời gọi / thao tác | Hạn mới hoặc hạn giữ | Nơi áp dụng |
| --- | --- | --- |
| Mở pool và kiểm kết nối | `ConnectTimeout` 5 s nếu URL chưa đặt; `Ping` với ngân sách startup 5 s | `internal/pgpool.New(ctx, url)` thay `pgxpool.New`/`Ping` lặp lại trong bốn service dùng Postgres |
| Relay: Begin, advisory lock, đọc dòng | 5 s chung bước đọc/khoá | `internal/outbox/relay.go`, `sendBatch`/`readUnsent` |
| Relay: produce cả lô | Giữ 10 s, context riêng sau bước đọc | `internal/outbox/relay.go`; không để deadline đọc hết hạn huỷ produce |
| Relay: đánh dấu `published_at` và commit | 5 s chung bước ghi/commit | `internal/outbox/relay.go`, `sendBatch` |
| Dọn outbox | 30 s cả lượt, các statement/lô dùng cùng deadline | `internal/outbox/relay.go`, `cleanup`; lần sau tiếp tục backlog |
| Consumer `transcode.*` tại video-service | `HandlerTimeout: 10s` mỗi lần thử, gồm Postgres và việc handler gọi S3 | `internal/kafkax.ConsumerConfig` và `services/video-service/internal/server/transcode.go` |
| Consumer projector feed | `HandlerTimeout: 30s` mỗi lần thử, gồm khoá tác giả, fan-out, commit | `internal/kafkax` và `services/feed-service/internal/projector/projector.go` |
| Consumer theo lô engagement | `HandlerTimeout: 30s` mỗi lần thử; cả `EndOffsets`/ListOffsets và transaction | `internal/kafkax.BatchConsumerConfig`, `batch.go`, `services/engagement-service/internal/server/views.go` |
| Dọn timeline | 2 phút cả lượt | `services/feed-service/cmd/feed-service/main.go`, `runPrune`, và projector `PruneTimeline` |
| Dọn upload | Giữ 30 s mỗi lô 100 video, Postgres/S3/commit chung hạn | `services/video-service/internal/server/sweep.go`, `sweepBatch` |
| Media-worker | Giữ 15 phút mỗi lần thử; ffprobe 30 s, ffmpeg 10 phút, produce kết quả 30 s | `services/media-worker/internal/worker/worker.go`, `internal/transcode` |
| Produce DLQ | 10 s riêng cho một record DLQ | `internal/kafkax/consumer.go`, `deadLetter`, kể cả đường batch |
| Commit offset Kafka | Giữ 10 s, dẫn xuất từ `context.WithoutCancel(ctx)` | `internal/kafkax/consumer.go`, `batch.go` |
| Rollback transaction nền/consumer | 5 s riêng từ `context.WithoutCancel(ctx)`, luôn gọi cancel | Relay `sendBatch`, video `markReady`/transcode và `sweepBatch`, transaction projector/prune, transaction consumer lượt xem |

`internal/pgpool` dùng `pgxpool.ParseConfig`, gắn tracer `otelpgx` không query parameter, tạo pool rồi `Ping`;
đăng ký `otelpgx.RecordStats` cùng vòng đời pool. Giữ `connect_timeout` người dùng đã đặt trong URL; deadline Ping
vẫn ràng buộc startup. Không sửa cấu hình Postgres native hay đặt statement_timeout toàn server.

`HandlerTimeout` được dựng **mới cho từng lần thử**; hết hạn là lỗi tạm, backoff ở ngoài context lần thử đó.
Context cha dừng consumer thì không DLQ chỉ vì shutdown. Media-worker giữ hạn riêng 15 phút hiện có, không nhận
mặc định 10/30 s. Fan-out 200.000 follower đã đo khoảng 1 s ở giai đoạn 2, nên 30 s có biên hợp lý.

Giữ các timeout/retry mặc định franz-go **v1.22.1**: dial 10 s, request timeout overhead 10 s, produce request timeout
10 s, record delivery timeout 0 (không hạn mặc định), retry record gần như không giới hạn (`math.MaxInt64`), request retries 20,
backoff 250 ms → tối đa 5 s (jitter), session 45 s, rebalance 60 s. **Thêm
`kgo.AllowIdempotentProduceCancellation()` tại `internal/kafkax.NewClient`**, áp dụng cả client producer và client
consumer có produce DLQ; giữ idempotency và `acks=all`, không dùng transactional ID. Đây là ngoại lệ cần thiết so
với giữ toàn bộ mặc định: `ProduceSync` chờ callback cho mọi record; mặc định không cho huỷ khi `unsureIfProduced`.
Option cho phép context huỷ cả record đang gửi/chưa rõ kết quả; không chỉ giới hạn lúc chờ metadata/kết nối.

Context produce ứng dụng giữ hạn: outbox **10 s**, lượt xem **2 s**, kết quả worker **30 s**, DLQ **10 s**. Context
của từng record sau khi ghép trace parent phải mang cùng deadline/cancellation của lời gọi, không dùng context đã
bỏ huỷ để produce. Không bọc `ProduceSync` bằng goroutine rồi chỉ bỏ chờ: record/goroutine và khoá có thể sống tiếp.
Giữ override rebalance worker 164 phút của ADR-0008; không lẫn timeout handler với session heartbeat.

Đánh đổi: retry nội bộ chưa huỷ vẫn được producer dedupe; sau huỷ, broker có thể đã ghi, nên **timeout không khẳng
định record chưa tồn tại**. Gửi lại từ ứng dụng có thể tạo bản sao. Relay không đánh dấu published khi lỗi, retry
giữ `event_id`; consumer nghiệp vụ vẫn phải idempotent. DLQ có thể có bản sao, không commit record nguồn khi chưa
ACK DLQ. `RecordView` không tự retry produce sau timeout; gateway vẫn không retry RPC này theo ADR-0010. Offset
Postgres của consumer lượt xem chỉ chống đọc lại **cùng offset**, không chống một lần client gửi lại thành record
mới; không hứa exactly-once qua một request có kết quả không rõ.

Test hiện thực phải giữ khoá hàng bằng transaction khác trên database test, cho handler/relay/prune chờ khoá rồi
xác nhận trả về hữu hạn và rollback cũng có hạn; Kafka lỗi thì DLQ produce không đứng mãi. Thu hẹp timeout trong
test, không chờ timeout production đầy đủ. Metric vòng nền và lag ở mục 5/8 quan sát hậu quả của những lỗi này.
Test Kafka phải có record **đã in-flight**: broker trả `REQUEST_TIMED_OUT` rồi mất kết nối, và broker giữ/mất ACK
đến khi context hết hạn; xác nhận `kafkax.Produce`/produce DLQ trả lỗi hữu hạn, callback kết thúc, relay nhả khoá và
không đánh dấu published, DLQ lỗi không commit nguồn. Dùng kfake và đồng bộ theo lúc broker nhận produce, không chỉ
test một port chưa có listener. Test retry relay giữ cùng event ID; không khẳng định broker chỉ có một bản sao sau
huỷ. Các test này cần chứng minh cả deadline của lô có nhiều record với trace parent khác nhau.

## 12. Bài so sánh Elastic

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Collector → APM Server OTLP intake → Elasticsearch** | Đi qua đường xử lý Observability được hỗ trợ, Kibana APM hiểu dữ liệu | Thêm một container APM Server |
| Collector contrib `elasticsearch` exporter, mapping OTel, ghi thẳng data stream | Bỏ APM Server, cấu hình có thể nhẹ hơn | Phải kiểm Kibana APM/version hỗ trợ; tài liệu hiện cảnh báo bỏ qua pipeline và không hỗ trợ theo đường này |
| Chạy cả hai backend đồng thời | Một lượt tạo dữ liệu | Không so được tài nguyên riêng, vượt ràng buộc RAM |

### Quyết định

Giữ **APM Server** cho biến thể so sánh đã chốt; xét biến thể exporter trực tiếp trong ADR-0012 nhưng không tự
thay trước khi chứng minh tương thích. [Tài liệu Elastic chính thức về upstream OTel](https://www.elastic.co/docs/solutions/observability/apm/opentelemetry/upstream-opentelemetry-collectors-language-sdks)
(tra 2026-10-16) yêu cầu OTLP, cảnh báo exporter `elasticsearch` bỏ qua pipeline xử lý và không được hỗ trợ cho
Elastic Observability theo hướng đó. Vì vậy chưa thể khẳng định “mapping OTel là Kibana APM đọc được”. ADR-0012
phải kiểm version cụ thể; nếu chỉ thử được log tìm kiếm thì không gọi đó là APM tương đương.

Chạy **lần lượt** `OBS=lgtm`, dừng bộ đó, rồi `OBS=elastic`; mỗi bộ cùng tải `make smoke` **3 lần + một upload tới
READY**, cùng dữ liệu mẫu và cách lấy RAM. Heap Elasticsearch **1 GB**; tắt security chỉ vì dev local, chỉ publish
Kibana trên loopback. Không so profile. Ghi RAM nghỉ/đỉnh, thời gian khởi động và số dòng cấu hình, PromQL/LogQL/
TraceQL với KQL/ES|QL, khả năng nhảy trace ↔ log và công vận hành; kết luận ADR-0012 bằng số đo.

Mốc giá managed, USD, tra nguồn chính thức **2026-10-16**; đây là giá niêm yết, chưa phải dự toán tải project:

| Dịch vụ | Mốc đã kiểm | Nguồn |
| --- | --- | --- |
| Grafana Cloud | Free 10k active series và 50 GB ingest/tháng cho từng logs/traces/profiles, giữ 14 ngày; Pro từ 19 USD/tháng + usage, metric từ 6,50 USD/1k series | [Grafana pricing](https://grafana.com/pricing/) |
| Elastic Observability Serverless Complete | Ingest logs/traces từ 0,09 USD/GB, metric từ 0,023 USD/GB; retention tương ứng 0,019 và 0,005 USD/GB-tháng; egress 50 GB miễn phí rồi 0,05 USD/GB | [Elastic pricing](https://www.elastic.co/pricing/serverless-observability/) |

Cần lượng ingest, active series, retention và region thật mới tính chi phí; không biến giá “từ” thành hoá đơn cố
định. Khi lên AWS/GCP, so thêm dịch vụ managed tương ứng bằng giá tại buổi cloud, không liên hệ tài khoản cloud
trong bước local này.

## 13. Ngân sách tài nguyên

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ toàn bộ backend luôn bật | Mở UI ngay | Tốn RAM cả khi học phần khác; khó phân biệt overhead ứng dụng và backend |
| **Profile tùy chọn, giới hạn từng container, đo bằng cùng tải** | Chạy vừa máy 16 GB, có số để quyết định | Phải chờ backend khởi động, dữ liệu có khoảng trống khi tắt |
| Nâng Docker VM hết RAM máy | Ít OOM trong VM | macOS, IDE, Postgres/Redis native bị ép swap |

### Quyết định

Core đã đo khoảng **896 MiB lúc nghỉ** ở phần 2C. Ngân sách container cho phần mới:

| Container | `mem_limit` dự kiến | RAM probe 2026-10-16 |
| --- | --- | --- |
| `lgtm` | 1536 MiB | 533–635 MiB khi nghỉ/telemetry mẫu, một mẫu 597 MiB trước mount override |
| `otelcol` | 256 MiB | Chưa đo Collector riêng dưới tải app; processor giới hạn mềm ở mục 1 |
| `alertmanager` | 64 MiB | Chưa đo dưới cảnh báo thật |
| `glitchtip` | 512 MiB | 188 MiB lúc nghỉ và sau ingest/query event mẫu, hai role, không Valkey |
| `glitchtip-init` | 512 MiB | Job một lần; không cộng thành RAM nghỉ lâu dài |

Mẫu lấy bằng `docker stats --no-stream` trên arm64, không phải benchmark hay số đỉnh. RAM Postgres native của
tracker nằm ngoài thống kê container; số bảng/partition và retention cũng tốn đĩa. Dự toán `obs` tăng **1,25–2 GiB**
so với core, gồm GlitchTip; tổng trần các container mới chạy lâu dài khoảng **2,31 GiB**. Elastic dự toán tăng
**3–3,5 GiB** so với core và phải đo riêng. Không cộng hai bộ cùng lúc.

Prometheus giữ **30 ngày** (mục 8), gấp đôi mặc định. RAM gần như không đổi: trong RAM chỉ có head block khoảng 2–3 giờ
gần nhất, block cũ hơn nằm trên đĩa và chỉ được đọc (mmap) khi truy vấn; mẫu 2026-10-17 có 19 630 series trong head,
`lgtm` 915 MiB / 1536 MiB. Đĩa tăng theo **giờ stack chạy**, không theo ngày lịch: lúc đo có khoảng 3 440 series đang
nhận mẫu, mỗi series một mẫu mỗi 15 s, khoảng 230 mẫu/s hay 20 triệu mẫu mỗi ngày chạy. Block đã ghi đo được 4,4
byte/mẫu (16 186 series, 165 244 mẫu: mỗi lần khởi động tạo series mới theo instance nên index lớn so với mẫu); series
sống lâu khoảng 1,5–2 byte/mẫu. Chạy liên tục 30 ngày tốn khoảng **1,2–2,6 GB** trong volume `lgtm-data`; vài giờ mỗi
buổi thì vài trăm MB. Lúc đo `/data/prometheus` là 6 MB, cả volume 618 MB (Grafana 509 MB, phần lớn là plugin).

Docker Desktop hiện khoảng **7,7 GB**; khuyến nghị nâng khoảng **10 GB** cho giai đoạn 3–4 nếu bộ Elastic gây áp
lực, vẫn chừa phần còn lại cho host. Người học tự chỉnh tài nguyên máy. Không chạy k3d song song compose; không
đổi giới hạn chỉ để che OOM, đo tải và xem lại dự toán trước. So với plan “obs một container”, Collector tách để
đổi backend/kiểm processor, Alertmanager tách để học định tuyến, GlitchTip thêm vì SaaS không truy cập được.

## Kiểm chứng (đã kiểm ngày 2026-10-16)

Đây là bằng chứng chọn cấu hình/version, không phải báo cáo đã hiện thực toàn giai đoạn 3. Probe dùng dữ liệu giả,
container tiền tố `svp-adr0011-`, không publish cổng; các truy vấn backend thực hiện **bên trong container**.
Lệnh Docker luôn có tiền tố `env -u DOCKER_DEFAULT_PLATFORM`; ngoại lệ probe độc lập đã được duyệt cho bước này.

| Kiểm gì | Lệnh / cách kiểm đã chạy | Kết quả |
| --- | --- | --- |
| Toolchain/API slog | `go version`; `go doc log/slog NewMultiHandler` | Go 1.27.2 darwin/arm64, có MultiHandler |
| Version Go | `go list -m -json <module>@latest` cho tất cả module ở mục 2 và Sloth | Version/GoVersion như bảng; không sửa module repo |
| Tương thích dependency | Trong module tạm ngoài repo: copy `go.mod`/`go.sum`, `go get <các-version-ghim>`, `go build -o probe .`, `go list -m`, `go mod graph` | Build exit 0, 779 cạnh đồ thị; grpc/protobuf/x/net, pgx, Redis, AWS SDK giữ version ở mục 2 |
| Semantic convention | Đọc `otelhttp/handler.go`, `internal/semconv/server.go`, `otelgrpc/config.go`/`stats_handler.go`, source pool/runtime/Redis | Pattern/name có hỗ trợ nhưng span route cần bổ sung; RPC mới đơn vị s; otelaws deprecated |
| Image/index | `docker pull`, `docker image inspect`, `docker buildx imagetools inspect <tag> --format '{{json .Manifest}}'` | Tag/digest ở mục 9; mọi index có arm64/amd64; Alertmanager `--version` là 0.34.1 |
| File trong image | `docker create` + `docker cp <container>:<path> -` đọc YAML và `run-*.sh`; source GlitchTip dưới `/code` | Đúng đường dẫn/binary/config và UID; `VALKEY_URL` rỗng chọn backend PostgreSQL |
| LGTM mount runtime | `docker run` mạng tạm, memory 1536m, bind RO Prometheus/Tempo/Loki/datasource + rule mẫu; GET `/api/v1/rules`, `/api/v1/alertmanagers`, Grafana `/api/datasources` | Rule mẫu healthy, evaluation 15 s, đích Alertmanager 9093, tên datasource thay đổi, bốn UID đúng; toàn stack ready |
| OTLP → Prometheus | `docker exec -i ... curl --data-binary @- http://127.0.0.1:4318/v1/metrics` với histogram/counter/gauge mẫu; query API Prometheus | Tên series, labels, `le="0.15"`, `le="120"`, timestamp `_seconds` đúng mục 5; probe HTTP vào Collector trong image, không giả là đã test exporter gRPC app |
| Loki/Tempo/proxy | Gửi OTLP JSON `/v1/logs`, `/v1/traces` trong container; query qua Grafana datasource proxy; Loki `/series` | Có trace, route và log cùng trace ID; `/series` chỉ có index label `service_name`; trace/span ở metadata |
| Redpanda thật | `make up`; `docker exec svp-redpanda-1 rpk cluster config get/set enable_consumer_group_metrics`; curl `:9644/public_metrics` trong broker | Core healthy; thấy lag max/sum và nhãn group như mục 5; trả property về `[group,partition]` trước `make down` |
| GlitchTip thật | Native test DB/role qua `psql -h 127.0.0.1 -p 5432`; bootstrap SQL, migrate/maintain/cachetable bằng maintenance; all-in-one app + maintenance URL | Health 200; app không superuser/CREATE schema; init hai lần không trùng user/org/project/token; đã sửa probe để cachetable chạy bằng maintenance |
| Lỗi và API | Trong GlitchTip: `manage.py shell`, SDK Sentry gửi event giả; Bearer GET issue query theo tag và GET event ID | Cả hai 200, event giữ trace ID; token/DSN/password không in ra terminal |
| Tài nguyên | `docker stats --no-stream` trên LGTM/GlitchTip | Các mẫu RAM ở mục 13; chưa đo overhead a/b/c, chưa chạy tải Elastic |
| Dọn và kiểm phạm vi | `make down`; xoá container/mạng/thư mục module probe, database test/role tạo cho probe; `docker ps -a` theo project/tên; `git diff --check`, `git status --short`, `git diff -- go.mod go.sum` | Không còn container/mạng probe hay container svp; không thay module/code; chỉ hai file ADR và symlink `AGENTS.md` trong working tree |

Rà soát bổ sung cùng ngày: `go doc github.com/twmb/franz-go/pkg/kgo AllowIdempotentProduceCancellation` và đọc
`producer.go`/`sink.go`/`config.go` v1.22.1 xác nhận mặc định chờ kết quả record đang gửi, option cho huỷ và đánh đổi
chống trùng ở mục 11. Đọc `gobreaker` v2.4.0, breaker gateway, các main, cấu hình healthcheck compose và test Kafka/
outbox hiện có xác nhận các ca biên ở mục 5/8/10. Lượt bổ sung chỉ sửa tài liệu, không chạy lại probe ingestion,
không chạy test Go hay `promtool test rules`; những ca test mới ghi ở trên là yêu cầu cho bước hiện thực.

Kiểm bổ sung bằng `python3` trong bộ nhớ: mô hình mẫu mỗi 15 s, lookback 5 phút tái hiện relay cũ bắn sau 135 s
khi ngừng gửi; lọc tuổi mẫu 45 s loại cảnh báo đó và breaker cũ, vẫn giữ cảnh báo vòng đứng còn export và nhánh 0
cho cả bốn loop. Đây là kiểm mô hình thời gian, **không phải chạy PromQL/promtool**. Lượt này không dựng container
hay chạy lại các probe version/image/ingestion ở bảng trên. Lúc hiện thực rule (2026-10-17), `make slo-check` chạy
promtool 3.15.0 của image LGTM trên rule thật: mô hình trên đúng cho series đã ngừng hẳn nhưng bỏ sót 45 s mà `for`
còn tích luỹ sau mẫu cuối, nên rule đổi sang đo thời lượng bằng mẫu (mục 8); mọi ca test mục 8 pass.

Một lần LGTM probe `--network none` dừng ở Pyroscope trước ready; mạng Docker tạm cho stack ready. Kết quả mount/
ingestion ở trên lấy từ lần chạy mạng tạm, không lấy từ container đã dừng. Không chạy npx/markdownlint, test Go toàn
repo hay diễn tập ứng dụng vì thay đổi này chỉ là ADR; các test bắt buộc khi hiện thực đã ghi trong từng mục.

## Hệ quả

- **Được:**
  - Một trace nối được request, outbox và fan-out mà không đổi contract nghiệp vụ; metric SLO không phụ thuộc sampling.
  - Service chỉ biết Collector; đổi backend và đưa sang Helm giữ đường instrumentation. Khi backend hỏng, API vẫn chạy.
  - Có đường cảnh báo → metric → trace → log → lỗi theo trace ID; error tracker chạy local, không cần tài khoản ngoài.
  - Không mở handler quản trị trong service; worker giữ cô lập mạng và không nhận thêm credential tracker/profiler.
- **Phải trả:**
  - Thêm SDK/instrumentation, chi phí CPU/RAM, hàng đợi có thể mất telemetry, và các module v0.x cần kiểm khi nâng.
  - `otelaws` không còn hỗ trợ upstream; không được quên rủi ro này khi nâng SDK/cloud.
  - Collector, Alertmanager, GlitchTip và database/partition của tracker tăng công vận hành; all-in-one có credential
    maintenance trong cùng container web. LGTM gộp tiến trình chỉ phù hợp dev, không là production blueprint.
  - SLO video chỉ đếm mẫu kết thúc; video kẹt phải nhờ lag/loop/DLQ. Burn rate local ít traffic không thay số đo k6.
  - Produce có hạn kể cả khi chưa rõ broker đã ghi hay chưa; gửi lại sau huỷ có thể tạo bản sao, không bảo đảm
    exactly-once ở biên request. Cảnh báo counter mới có thể bắn lại sau khoảng mất dữ liệu dài.
  - Chỉ gửi loại lỗi/mã/stack an toàn làm tracker ít thông tin hơn log; cần tra Loki bằng trace ID để đọc lỗi đầy đủ.
- **Xem lại khi:**
  - Kết quả overhead a/b/c làm feed vượt 150 ms hoặc vượt ngân sách RAM: xem sampling, chu kỳ export và profile trước
    khi tăng tài nguyên; chỉ đổi quyết định bằng bằng chứng/ADR.
  - Collector drop dữ liệu, queue đầy hoặc tracker chạm 512 MiB: đo ingest/cardinality; xét giảm dữ liệu, tách worker,
    rồi mới thêm Valkey riêng. Không lấy db Redis native của dự án khác.
  - Lên k8s/cloud: tách backend dev image, bật xác thực UI, quản lý secret, TLS/NetworkPolicy và retention/chi phí thật.
  - Nâng OTel/LGTM/GlitchTip: kiểm lại tên metric, unit/bucket/route, datasource/provisioning, startup/cachetable và API
    tag query; không chỉ đổi tag image. Nâng AWS SDK thì kiểm lại phương án thay otelaws.
