# 0012. Giữ Grafana LGTM là bộ observability chính; Elastic 9.5.5 qua APM Server chỉ là profile so sánh

- Trạng thái: Chấp nhận
- Ngày: 2026-10-17

## Bối cảnh

- [ADR-0011 §9 và §12](0011-observability-stage3.md#12-bài-so-sánh-elastic) chốt LGTM là bộ chính và để lại bài so
  sánh Elastic: cùng dữ liệu OTel qua Collector, chạy **lần lượt** (máy 16 GB, không bật hai bộ cùng lúc), heap
  Elasticsearch 1 GB, security tắt chỉ vì dev local, chỉ publish Kibana trên loopback; image/digest Elastic chốt ở đây.
- Tiêu chí so sánh của ADR-0011 §12: RAM nghỉ/đỉnh, thời gian khởi động, số dòng cấu hình, truy vấn (PromQL/LogQL/
  TraceQL với ES|QL/KQL), nhảy trace ↔ log, công vận hành, chi phí khi lên cloud. Không so error tracker hay profile.
- Máy Apple M2 16 GB; Docker Desktop đã nâng lên khoảng **9,7 GiB** (`docker info` MemTotal 10 419 650 560 byte,
  8 CPU) trước bài đo. Postgres/Redis native nằm ngoài số đo container.

## 1. Đường dữ liệu và cách dựng profile `obs-elastic`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Collector → APM Server (OTLP) → Elasticsearch, Kibana đọc** | Đường được Elastic hỗ trợ cho upstream OTel; Kibana APM hiểu dữ liệu; index template do plugin `apm-data` của Elasticsearch tự cài, không cần Fleet | Thêm container APM Server |
| Exporter `elasticsearch` của Collector ghi thẳng | Bớt một container | Tài liệu Elastic cảnh báo bỏ qua pipeline xử lý, không hỗ trợ cho Kibana APM theo đường này (ADR-0011 §12); chưa kiểm |
| Một service `otelcol` đổi file cấu hình theo biến | Đúng một tên service như ADR-0011 §1 viết | Phải sửa service của profile `obs`; một biến sai là LGTM nhận cấu hình Elastic |

### Quyết định

Giữ đường APM Server. Profile `obs-elastic` trong `deploy/compose/compose.yaml` gồm:

- `elasticsearch`: `discovery.type=single-node`, `xpack.security.enabled=false`, `ES_JAVA_OPTS=-Xms1g -Xmx1g`,
  `mem_limit: 2g`, volume `elasticsearch-data`, không publish; tắt `ingest.geoip.downloader` để không tải gì từ Elastic.
- `kibana`: cấu hình `deploy/observability/elastic/kibana.yml` (tắt telemetry, newsfeed, Fleet ở chế độ air-gapped),
  publish **chỉ** `127.0.0.1:5601`, `mem_limit: 1536m`.
- `apm-server`: cấu hình `deploy/observability/elastic/apm-server.yml` (nhận OTLP gRPC/HTTP ở 8200, ghi vào
  Elasticsearch, không token vì security tắt), `mem_limit: 512m`, không publish.
- `otelcol-elastic`: cùng image Collector ghim digest của `otelcol`, chạy với hai `--config`: chính
  `deploy/observability/otelcol/config.yaml` của `obs`, rồi `deploy/observability/elastic/otelcol-config.yaml` ghép đè
  lên (Collector gộp map theo khoá, list thay cả list). File thứ hai chỉ thêm exporter `apm-server:8200` và trỏ ba
  pipeline cùng metric tự thân của Collector sang đó; receiver và processor (memory limiter, xoá attribute nhạy cảm ở
  signal và resource theo JWT-8, batch) **chỉ có một nguồn** là file `obs`, không chép tay. Exporter `otlp_grpc/lgtm`
  của file `obs` vẫn được khai báo nhưng không nằm trong pipeline nào nên Collector không khởi động nó.
  `make otelcol-validate` chạy `validate` của Collector ghim (`--network none`) cho cả cấu hình `obs` lẫn cấu hình ghép.
  Nằm ở `default` và `worker` với **alias mạng `otelcol`**, nên service vẫn gửi `otelcol:4317`, không đổi biến.

Cách dựng này **chỉnh** câu "Một service compose `otelcol` dùng cho cả hai cách chạy, chỉ chọn một cấu hình lúc khởi
động" của [ADR-0011 §1](0011-observability-stage3.md#1-đường-đi-telemetry-và-collector): giữ một **tên** mạng `otelcol`
và một bộ receiver/processor, nhưng là hai service compose (`otelcol`, `otelcol-elastic`), không phải một service đổi
file cấu hình theo biến (dòng thứ ba của bảng trên). [README](README.md) ghi ADR-0011 "§1 chỉnh bởi 0012".

`make up OBS=elastic` thêm `--profile obs-elastic`; `make up OBS=lgtm` và `OBS=elastic` từ chối khi container chạy lâu
dài của bộ kia đang chạy, báo chạy `make down` trước. `make down`/`ps`/`logs` đã gồm mọi profile; `make compose-config`
kiểm thêm tổ hợp `core`+`obs-elastic`. Không service `core` nào phụ thuộc profile này.

Image, tra và kéo ngày 2026-10-17 (9.5.5 là bản ổn định mới nhất trên Docker Hub lúc tra, sau 9.4.8 và 8.19.23):

| Image | Tag | Digest manifest list (dùng trong compose) | Digest manifest linux/arm64 |
| --- | --- | --- | --- |
| `docker.elastic.co/elasticsearch/elasticsearch` | `9.5.5` | `sha256:13b4a40bb095774f5fda635e45fd5677cc6a26565e42b24997b0c72b88e75984` | `sha256:35c5cab56b4f04452bf82ab52638d14ada25c1abdeb5abd096157f9d75ec55c5` |
| `docker.elastic.co/kibana/kibana` | `9.5.5` | `sha256:13b72ce7222c36e4213229004ae62a87aeb32fd372ebfa6fb38f7a3285fdbb78` | `sha256:da3a6d265226f85f8ad4c9474a7547d77b55501e0e8c858484ec3d735fec81ad` |
| `docker.elastic.co/apm/apm-server` | `9.5.5` | `sha256:9262426d04743c1160ed133d149e85bcad3361ef24e47f902f7f5d23d2fbf60e` | `sha256:887fcc20b79a6090c8457b6904a14e0ac837a9f592b3ed4ffd1273ab4b3d2b1e` |

Cả ba manifest list có linux/amd64 và linux/arm64. Image APM Server không có `curl`/`wget`/`grep`: healthcheck dùng
`bash` mở `/dev/tcp/127.0.0.1/8200`. File cấu hình bind mount thuộc user máy host nên APM Server chạy với
`--strict.perms=false`.

Không cần bước tay nào: APM Server ghi các data stream `traces-apm*`, `metrics-apm*`, `logs-apm*` ngay khi khởi động,
Kibana APM đọc chúng. `vm.max_map_count` trong VM Docker Desktop đã là **262144** (đọc `/proc/sys/vm/max_map_count`
trong container), và `single-node` không bắt bootstrap check, nên không phải chỉnh máy host. Profile này không có
Pyroscope: service vẫn healthy, sau hơn 2 phút log gateway và feed-service có **0** dòng WARN/pyroscope (client
Pyroscope bỏ dữ liệu im lặng). `SENTRY_DSN` vẫn trỏ GlitchTip không chạy; lỗi không được báo trong lượt này.

## 2. Cách đo

Cùng code, cùng file compose, image Go đã build trước (`make up` rồi `make down` một lượt khởi động nguội), mỗi bộ:

1. `make ps` rỗng; chạy nền một vòng lặp `docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'`
   (mẫu cách nhau 2–3 s, vì mỗi lệnh tự mất khoảng 2 s) và một vòng `docker ps --format '{{.Names}}\t{{.Status}}'` mỗi
   1 s ghi lúc từng container lên và lúc `(healthy)` đầu tiên. Mọi lệnh docker có tiền tố `env -u DOCKER_DEFAULT_PLATFORM`.
2. `time make up OBS=lgtm` / `time make up OBS=elastic` (`--wait`: tới khi mọi service healthy).
3. Chờ 60 s cho ổn định; **RAM nghỉ** là trung vị các mẫu trong khoảng 90–100 s tiếp theo, không có request.
4. `make smoke` 3 lần liền (mỗi lần có upload tới `READY`, HLS, feed, like, view); **RAM đỉnh** là mẫu lớn nhất từ lúc
   bắt đầu tới 4 s sau lần smoke cuối. Lượt LGTM đầu lấy mẫu mỗi 4–5 s, nên chạy lại 3 smoke với mẫu 2–3 s và lấy số
   lượt cuối (LGTM vì vậy đã nhận 6 smoke trước 3 lượt lấy số đỉnh, Elastic không có lượt nào trước).
5. Các truy vấn mẫu bên dưới, đo `curl -w '%{time_total}'` một lần, từ host qua UI: Grafana datasource proxy
   (`/api/datasources/proxy/uid/<uid>/...`) và Kibana (`/api/console/proxy?path=/_query` cho ES|QL, các API
   `/internal/apm/...` mà trang Kibana APM gọi). Không thao tác trên trình duyệt: các thao tác UI ghi dưới đây là API
   mà trang đó gọi, đã gọi thật và kiểm kết quả.
6. `make down`, `make ps` rỗng. Elastic khởi động thêm một lượt với volume đã có (ấm) để so với LGTM vốn có volume
   `lgtm-data` từ các buổi trước (không xoá volume để đo nguội: `make clean-data` không nằm trong bài này).

Trace có lỗi lấy từ thân 404 `VIDEO_NOT_FOUND` của `GET /videos/<id không tồn tại>` với một user vừa đăng ký (gateway
→ video-service); trace ≥ 3 service là trace của `POST /videos/{video_id}/complete` (gateway → video-service → outbox →
media-worker → feed-service).

## 3. Số đo (2026-10-17)

RAM theo `docker stats` (MiB; cgroup không tính page cache không hoạt động). Đỉnh của từng container lấy riêng, không
cùng một mẫu; dòng tổng là tổng của cùng một mẫu.

| Container | LGTM nghỉ | LGTM đỉnh smoke | Elastic nghỉ | Elastic đỉnh smoke | `mem_limit` |
| --- | --- | --- | --- | --- | --- |
| `lgtm` | 1 120 | 1 282 | — | — | 1 536 |
| `otelcol` / `otelcol-elastic` | 254 | 108 | 67 | 72 | 256 |
| `alertmanager` + `glitchtip` (chỉ có ở `obs`, ngoài phạm vi so) | 42 + 195 | 42 + 195 | — | — | 64 + 512 |
| `elasticsearch` | — | — | 1 712 | 1 724 | 2 048 |
| `kibana` | — | — | 1 167 | 951 | 1 536 |
| `apm-server` | — | — | 48 | 65 | 512 |
| **Backend so sánh** (`otelcol`+`lgtm` / `otelcol`+ES+Kibana+APM) | **1 374** | — | **2 995** | — | 1 792 / 4 352 |
| Core cùng lượt (8 container chạy lâu dài: redpanda, minio, 5 service gRPC/HTTP, media-worker) | 666 | — | 590 | — | — |
| **Tổng stack** (tổng mỗi mẫu, trung vị nghỉ / lớn nhất lúc smoke) | **2 276** | **2 676** | **3 585** | **3 759** | — |

| Khởi động (`make up --wait`, image đã build) | LGTM | Elastic |
| --- | --- | --- |
| Toàn stack, ấm | **19 s** và 20 s (gồm `glitchtip-init`) | **44 s** |
| Toàn stack, nguội (volume mới) | không đo | **74 s** |
| Backend tới healthy sau khi container lên | `lgtm` 5,8 s | ấm: ES 15 s, APM 2 s sau ES, Kibana khoảng 21 s sau ES; nguội: ES 19 s, Kibana 47 s |

`otelcol` của LGTM ở 254/256 MiB lúc nghỉ rồi về 108 MiB lúc smoke: số `docker stats` của Collector Go dao động theo
GC và bộ nhớ trang, không phải dấu hiệu tải; memory limiter giữ heap dưới 192 MiB. Kibana cũng có "đỉnh smoke" (951)
thấp hơn lúc nghỉ (1 167): hai cột lấy ở hai khoảng thời gian khác nhau (nghỉ ở giây 60–160 sau khi stack lên, smoke
sau đó), và RAM của tiến trình Node.js lên xuống theo GC heap, nên mẫu nghỉ có thể rơi vào lúc heap đầy hơn. Bài đo
không tách được phần nào do tác vụ nền lúc khởi động; cột "đỉnh" chỉ là mẫu lớn nhất trong khoảng smoke, không phải
mức cao nhất từ lúc khởi động. Không container nào bị OOM hay khởi
động lại. Lúc nghỉ Elasticsearch dùng 84% giới hạn, Kibana 76%. Sau lượt đo Elasticsearch giữ 10,4 MB chỉ mục
(`_cat/allocation`), cụm `yellow` vì 20 replica không có node thứ hai (đúng với một node).

Số dòng cấu hình đã viết (không tính dòng trống và comment):

| Phần | LGTM (`obs`) | Elastic (`obs-elastic`) |
| --- | --- | --- |
| Collector | 85 (`otelcol/config.yaml`) | 85 dùng chung + 31 (`elastic/otelcol-config.yaml`, chỉ exporter) |
| Backend | Loki 45, datasource Grafana 51 (liên kết trace ↔ log ↔ metric, service map) | APM Server 5, Kibana 7 |
| Service compose | `otelcol` 8, `lgtm` 31 | ES 18, Kibana 18, APM 17, Collector 13 |
| **Tổng tới UI có trace ↔ log** | **220** | **194** |
| Ngoài phạm vi so | Prometheus 45 (rule, Alertmanager), rule SLO/cảnh báo và 4 dashboard (5 247 dòng sinh/viết), Alertmanager, GlitchTip | — |

Bảng đếm lại sau khi Collector `obs` thêm metric tự thân (13 dòng), `lgtm` thêm ba biến tắt tải plugin và file Collector
Elastic thành file ghép; lúc đo RAM, hai file Collector là hai bản 72 dòng chép tay và tổng là 204 / 149.

## 4. Truy vấn mẫu

| Việc | LGTM (qua Grafana) | Elastic (qua Kibana) |
| --- | --- | --- |
| Trace theo `trace_id` ở thân 404 | Tempo `GET /api/traces/<id>`: **0,053 s**, 6 span, gateway + video-service | ES\|QL `FROM traces-apm* \| WHERE trace.id == "<id>" \| STATS spans = COUNT(*) BY service.name, processor.event`: **0,068 s**, 2 transaction + 4 span, cùng hai service |
| Log của trace đó | LogQL `{service_name=~".+"} \| trace_id = "<id>"`: **0,032 s**, 2 dòng (gateway, video-service) | `FROM logs-apm* \| WHERE trace.id == "<id>" \| KEEP @timestamp, service.name, log.level, message`: **0,060 s**, 2 dòng như bên kia |
| Trace ≥ 3 service | TraceQL `{ resource.service.name = "media-worker" }` (search): **0,022 s**; trace `complete` có gateway, video-service, media-worker, feed-service; log của trace 0,023 s, 4 service | `STATS services = COUNT_DISTINCT(service.name), names = VALUES(service.name) BY trace.id \| WHERE services >= 3`: **0,059 s**; trang trace Kibana APM (`/internal/apm/unified_traces/<id>`): **0,052 s**, 56 mục, cùng 4 service, gốc `POST /videos/{video_id}/complete` của gateway; log của trace 0,035 s, 4 service |
| Tỉ lệ lỗi theo route (10 phút) | PromQL 5xx/tổng theo `http_request_method, http_route` như dashboard RED: **0,009 s**, mọi route 0; `increase(...{http_response_status_code=~"[45].."})`: 0,003 s, thấy 401/404 ở `GET /videos/{video_id}`, 400 ở `GET /feed/following` | `FROM traces-apm* \| WHERE processor.event == "transaction" AND service.name == "gateway" \| STATS total = COUNT(*), failed = COUNT(*) WHERE event.outcome == "failure", http_4xx_5xx = COUNT(*) WHERE http.response.status_code >= 400 BY transaction.name`: **0,076 s**, failure 0 mọi route, 4xx: 7 ở `GET /videos/{video_id}`, 3 ở `GET /feed/following` |
| p99 feed (10 phút) | `histogram_quantile(0.99, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket{service_name="gateway", http_route=~"/feed/.*"}[10m])))`: **0,003 s**; following 47,1 ms, explore 22,0 ms | `STATS p99_ms = PERCENTILE(transaction.duration.us, 99) / 1000 BY transaction.name`: **0,048 s**; following 33,4 ms (n = 12), explore 16,9 ms (n = 27) |
| Service map | Tempo service graph → Prometheus, có sẵn (dashboard pipeline) | `/internal/apm/service-map`: **403**, "must be subscribed to an Elastic Platinum license"; license đang chạy là `basic` |

Hai cột p99 không cùng phép tính: PromQL nội suy trong bucket histogram của metric (luôn đủ, không phụ thuộc
sampling), ES|QL tính percentile trên duration của từng transaction (chỉ đúng khi giữ 100% trace, như lab hiện nay).
Mẫu nhỏ: p99 gần như là request chậm nhất. Thời gian truy vấn là một lần chạy trên vài nghìn document, chỉ cho thấy cả
hai đều dưới 0,1 s ở quy mô lab (ES|QL đầu tiên quét mọi data stream mất 0,31 s), không phải benchmark.

Quan sát thêm khi truy vấn:

- **Trace ↔ log:** Elastic có sẵn: log OTLP vào `logs-apm.app.<service>` với `trace.id`/`span.id` thành field chuẩn,
  trang trace của Kibana APM tra log theo `trace.id` mà không cần cấu hình. LGTM cần datasource provisioning (derived
  field Loki → Tempo, `tracesToLogs` Tempo → Loki) và override nhãn OTLP của Loki (ADR-0011 §4); bù lại tách rõ nhãn
  index (`service_name`) với metadata.
- **Field của log:** attribute log thành `labels.*` và đều được index (`labels.route`, `labels.user_id`, cả
  `labels.trace_id` nhân đôi `trace.id`). Elasticsearch không có giới hạn cardinality nhãn như Loki, nhưng mỗi field
  tốn index và mapping; user ID vẫn là dữ liệu được phép trong log (ADR-0011 §7).
- **Lỗi từ span:** APM Server biến exception event của span thành document `logs-apm.error`, nên Kibana có tab Errors
  ngay: thấy `ERR unknown subcommand 'maint_notifications'` từ go-redis ở gateway và feed-service (bắt tay của client
  với Redis native, không làm request lỗi). Trong LGTM cùng event chỉ nằm trong span ở Tempo.
- **Ngôn ngữ:** LGTM dùng ba ngôn ngữ (PromQL, LogQL, TraceQL) nhưng PromQL là thứ Sloth, Alertmanager và rule
  ADR-0011 §8 dùng. ES|QL dùng một cú pháp cho trace, log, metric; cảnh báo SLO/burn rate phải viết lại bằng Kibana
  alerting (chưa kiểm license của các tính năng đó).

## 5. Chi phí khi lên cloud

Dùng lại mốc giá niêm yết ở [ADR-0011 §12](0011-observability-stage3.md#12-bài-so-sánh-elastic), tra nguồn chính thức
ngày **2026-10-16**, không tra lại trong bài này:

- [Grafana Cloud](https://grafana.com/pricing/): Free 10k active series và 50 GB ingest/tháng cho từng logs/traces/
  profiles, giữ 14 ngày; Pro từ 19 USD/tháng + usage, metric từ 6,50 USD/1k series.
- [Elastic Observability Serverless Complete](https://www.elastic.co/pricing/serverless-observability/): ingest logs/
  traces từ 0,09 USD/GB, metric từ 0,023 USD/GB; retention 0,019 và 0,005 USD/GB-tháng; egress 50 GB miễn phí rồi
  0,05 USD/GB.

Lab chưa có lượng ingest, active series và retention thật nên không quy ra hoá đơn. Điểm tự host đo được: bộ Elastic
cần thêm khoảng **1,6 GiB RAM** lúc nghỉ so với LGTM ở cùng tải (2 995 so với 1 374 MiB backend), tức máy/node lớn hơn
nếu tự chạy trên cloud; service map và các tính năng trả phí khác cần license Platinum hoặc bản managed. Giá AWS/GCP
managed (AMP/AMG, OpenSearch, Cloud Monitoring) so ở buổi cloud.

## 6. Quyết định

**Giữ Grafana LGTM là bộ chính** (như ADR-0011), vì ở cùng dữ liệu và cùng tải lab:

- RAM backend lúc nghỉ 1,34 GiB so với 2,92 GiB; tổng stack 2,2 GiB so với 3,5 GiB. Bộ Elastic vừa ngân sách
  3–3,5 GiB trên core mà ADR-0011 §13 dự toán, nhưng chỉ chạy được khi Docker Desktop đã nâng lên ~9,7 GiB.
- Khởi động ấm 19–20 s so với 44 s (nguội 74 s), chủ yếu do Kibana.
- Đường SLO/cảnh báo của giai đoạn 3 (Sloth, Prometheus rule, Alertmanager) và dashboard đều dựa trên PromQL; service
  graph của Tempo miễn phí còn service map của Kibana cần Platinum.
- Truy vấn mẫu nào cũng làm được ở cả hai bộ trong dưới 0,1 s; Elastic không thắng ở tiêu chí nào đủ để đổi.

**Profile `obs-elastic` giữ lại** để học và so lại; không cảnh báo, không dashboard, không GlitchTip. Không thay APM
Server bằng exporter `elasticsearch`: chưa kiểm, và tài liệu Elastic không hỗ trợ đường đó cho Kibana APM.

**Nên chọn Elastic khi:** tổ chức đã vận hành Elasticsearch hoặc dùng Elastic cho SIEM/security; cần tìm kiếm
full-text trên khối log lớn với field tuỳ ý (mọi field đều được index, không bị giới hạn nhãn như Loki); muốn một ngôn
ngữ truy vấn (ES|QL) cho cả ba tín hiệu và trace ↔ log có sẵn không cần cấu hình; chấp nhận license trả phí hoặc
Elastic Cloud cho service map, ML và các tính năng APM nâng cao.

## Kiểm chứng (đã kiểm ngày 2026-10-17)

| Kiểm gì | Lệnh / cách kiểm | Kết quả |
| --- | --- | --- |
| Cấu hình compose | `make compose-config` | Exit 0 cho `core`, `core`+`obs`, `core`+`obs-elastic`, `OBS=off`, không in gì |
| Version, digest | Docker Hub API danh sách tag của `elasticsearch` và `elastic/apm-server`; `docker buildx imagetools inspect <image>:9.5.5`; `docker pull` theo digest | Bảng ở mục 1; Elasticsearch báo 9.5.5 (`GET /` qua Kibana proxy) |
| Hai bộ không chạy cùng | Đang chạy `obs-elastic`: `make up OBS=lgtm`; đang chạy `obs`: `make up OBS=elastic` | Cả hai exit 2: "the other observability stack is running; run 'make down' first"; `make ps` rỗng giữa các lượt |
| Stack Elastic chạy | `make up OBS=elastic`, `make smoke` 3 lần | Mọi service healthy; 3 × 38 bước ok; Kibana thấy 6 service, trace 4 service, log có `trace.id` |
| Stack LGTM chạy | `make up OBS=lgtm`, `make smoke` 9 lần (3 lượt mẫu thưa, 3 lượt ghi sai mốc giờ, 3 lượt đo) | Mọi service healthy; mọi lượt 38 bước ok |
| Telemetry Kibana | Log Kibana | "Telemetry is not opted-in"; license `basic` |
| Collector ghép cấu hình | `make otelcol-validate`; một file ghép đè trỏ pipeline tới exporter không có; `make up OBS=elastic`, `make smoke`, ES\|QL qua Kibana | Validate exit 0 cho `obs` và cấu hình ghép, bản lỗi bị từ chối ("references exporter ... which is not configured"); stack healthy, smoke 38 bước ok; 10 phút gần nhất `traces-apm*` có span của 6 service, `logs-apm*` có log mang `trace.id` của 6 service, `metrics-apm*` có 177 document của `service.name` `otelcol` (metric tự thân của Collector); exporter chỉ retry trong lúc APM Server khởi động (2026-10-17) |
| Dọn | `make down` sau mỗi lượt, cuối cùng `make ps` và `docker ps -a --filter label=com.docker.compose.project=svp` | Không còn container svp |

Chưa làm: thao tác bằng trình duyệt trên Kibana/Grafana (đã gọi API của các trang đó), đo khởi động nguội của LGTM, đo
CPU, so lượng đĩa giữa hai bộ, thử exporter `elasticsearch`, đo overhead a/b/c của ADR-0011 §10.

## Hệ quả

- **Được:**
  - Kết luận "LGTM là bộ chính" có số đo trên cùng tải, không chỉ dựa vào hiện trạng ngành.
  - Collector đổi backend chỉ bằng exporter và alias mạng: service, SDK và processor xoá dữ liệu nhạy cảm giữ nguyên,
    đúng mục tiêu học OpenTelemetry.
  - Có profile Elastic chạy được bằng một lệnh để thử ES|QL, Kibana APM khi cần.
- **Phải trả:**
  - Cấu hình Collector Elastic là file ghép sau file `obs`: đổi tên exporter hay pipeline ở `obs` phải chạy lại
    `make otelcol-validate`; image Elastic ghim digest phải nâng riêng.
  - Elastic chạy không đăng nhập (security tắt), Kibana có Dev Tools ghi/xoá được chỉ mục: chỉ chấp nhận vì loopback,
    dữ liệu lab, như Grafana anonymous Admin (threat model OPS-2). Không dùng cấu hình này ngoài máy local.
  - Lượt `obs-elastic` không có Pyroscope, GlitchTip, cảnh báo hay dashboard; không dùng nó cho diễn tập giai đoạn 3.
- **Xem lại khi:**
  - Lên cloud có lượng ingest/series/retention thật: tính chi phí Grafana Cloud, Elastic Cloud và dịch vụ AWS/GCP bằng
    giá ngày đó.
  - Cần tìm kiếm full-text log hoặc SIEM, hay tổ chức đã có Elastic: đo lại với license và retention thật.
  - Elastic hỗ trợ chính thức đường exporter thẳng cho Kibana APM, hoặc Kibana đưa service map vào license miễn phí.

## Hiện thực ở

- Profile `obs-elastic` của `deploy/compose/compose.yaml`, chọn bằng `make up OBS=elastic` (`deploy/compose/compose.mk`).
- Cấu hình ở `deploy/observability/elastic/` (`apm-server.yml`, `kibana.yml`, `otelcol-config.yaml` ghép đè lên
  `deploy/observability/otelcol/config.yaml`, chỉ đổi exporter).
