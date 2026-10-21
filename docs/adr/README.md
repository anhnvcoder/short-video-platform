# Architecture Decision Records

Mỗi ADR ghi một quyết định kiến trúc: bối cảnh lúc quyết, các lựa chọn đã cân nhắc, chọn gì, và cái giá phải trả. Mục đích
là để người đọc sau (kể cả chính mình sáu tháng sau) hiểu **vì sao**, không chỉ thấy **cái gì**.

## Khi nào viết

- Quyết định khó đảo ngược hoặc ảnh hưởng nhiều service: ranh giới service, giao thức, cách lưu dữ liệu, chọn công cụ.
- Đổi công cụ đã chốt trong plan, hoặc kết luận một bài so sánh (ví dụ Elastic với Grafana).
- Không viết cho chi tiết hiện thực đổi được trong một buổi.

## Quy ước

- Tên file `NNNN-<slug>.md`, số tăng dần, không dùng lại số.
- Trạng thái: **Đề xuất** (chờ duyệt) → **Chấp nhận**; về sau có thể thành **Bị thay bởi NNNN** hoặc **Bỏ**. ADR vẫn đứng
  nhưng có một chi tiết được ADR sau chỉnh thì ghi **Chấp nhận; <phần> chỉnh bởi NNNN**.
- ADR đã chấp nhận không sửa nội dung quyết định. Đổi ý thì viết ADR mới và cập nhật trạng thái ADR cũ.

## Mẫu

```markdown
# NNNN. <Quyết định, viết thành một mệnh đề>

- Trạng thái: Đề xuất
- Ngày: YYYY-MM-DD

## Bối cảnh

Vấn đề cần giải, ràng buộc, số liệu liên quan (dẫn tới docs/architecture.md nếu có).

## Các lựa chọn

### A. <Tên>

- Được: ...
- Mất: ...

## Quyết định

Chọn ..., vì ...

## Hệ quả

- Được: ...
- Phải trả: ...
- Xem lại khi: <điều kiện đo được>
```

## Danh sách

| ADR | Quyết định | Trạng thái |
| --- | --- | --- |
| [0001](0001-service-boundaries-and-data-ownership.md) | 6 service theo ranh giới nghiệp vụ, mỗi service một database | Chấp nhận |
| [0002](0002-sync-rest-edge-grpc-internal.md) | REST/JSON ở biên, gRPC bên trong, contract quản lý bằng `buf` | Chấp nhận; đường dẫn `.proto` chỉnh bởi [0006](0006-contract-ids-and-event-envelope.md) |
| [0003](0003-async-events-outbox.md) | Event qua Redpanda, transactional outbox, at-least-once + consumer idempotent + DLQ | Chấp nhận; cách khoá relay chỉnh bởi [0008](0008-async-upload-pipeline-stage2a.md) |
| [0004](0004-direct-upload-and-hls.md) | Upload thẳng lên object storage bằng presigned URL, transcode bất đồng bộ ra HLS | Chấp nhận |
| [0005](0005-feed-fan-out-on-write.md) | Feed dựng sẵn khi ghi (fan-out on write), Redis chỉ cache key nóng | Chấp nhận |
| [0006](0006-contract-ids-and-event-envelope.md) | Contract nội bộ: ID là UUIDv7, event bọc theo topic của luồng thực thể, proto đặt ở `proto/svp/<domain>/v1` | Chấp nhận |
| [0007](0007-go-monorepo-toolchain-and-stage1-scope.md) | Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi giai đoạn 1 thu về luồng đồng bộ | Chấp nhận |
| [0008](0008-async-upload-pipeline-stage2a.md) | Luồng upload bất đồng bộ giai đoạn 2 phần A: franz-go, aws-sdk-go-v2 (presigned POST, hai endpoint), MinIO image Chainguard ghim digest, Redpanda tạo topic bằng `rpk`, outbox một relay nhờ advisory lock, consumer commit tay + DLQ, media-worker alpine + ffmpeg có whitelist | Chấp nhận; §9 (đúng một replica media-worker) chỉnh bởi [0014](0014-kubernetes-local-stage4.md) cho k8s |
| [0009](0009-engagement-feed-stage2b.md) | Giai đoạn 2 phần B: user-service phát event follow qua outbox; engagement-service giữ like đồng bộ, gom lượt xem theo lô với offset lưu trong Postgres cùng transaction để đếm đúng một lần; feed-service fan-out on write với khoá advisory theo tác giả, timeline giữ 30 ngày, page token mã hoá bằng `protowire`; gateway ghép số đếm với timeout 100 ms | Chấp nhận |
| [0010](0010-redis-ratelimit-cache-resilience-stage2c.md) | Giai đoạn 2 phần C: Redis (`go-redis`) không bắt buộc lúc khởi động; rate limit GCRA bằng Lua ở gateway, đóng mềm cho login/register/upload và mở cho route ghi/đọc khi Redis lỗi, RL-3 một lượt xem mỗi 60 s; cache trang đầu feed khám phá TTL 5 s + singleflight; retry `UNAVAILABLE` cho method idempotent, circuit breaker `gobreaker` theo service đích; job dọn upload bỏ dở bằng advisory lock, tối đa 3 upload còn hạn mỗi user | Chấp nhận |
| [0011](0011-observability-stage3.md) | Giai đoạn 3: OpenTelemetry qua Collector riêng tới LGTM; GlitchTip tự host bằng giao thức Sentry, Pyroscope đẩy profile, SLO bằng Sloth và Alertmanager gửi Telegram; timeout vòng nền có hạn | Chấp nhận; §1 chỉnh bởi [0012](0012-elastic-vs-grafana-stage3.md), §11 chỉnh bởi [0013](0013-kafka-metadata-min-age.md) |
| [0012](0012-elastic-vs-grafana-stage3.md) | Bài so sánh giai đoạn 3: giữ Grafana LGTM là bộ observability chính; Elastic 9.5.5 (Elasticsearch + Kibana + APM Server qua OTLP) chỉ là profile `obs-elastic` chạy lần lượt, tốn thêm khoảng 1,6 GiB RAM lúc nghỉ, khởi động chậm hơn, service map cần Platinum | Chấp nhận |
| [0013](0013-kafka-metadata-min-age.md) | Mọi client franz-go đặt `MetadataMinAge` 1 s thay mặc định 5 s: produce hết hạn khi kết nối chết trả về trễ tối đa ~1 s thay vì ~5 s, đổi lấy tối đa 1 request metadata/giây mỗi client lúc broker lỗi | Chấp nhận |
| [0014](0014-kubernetes-local-stage4.md) | Giai đoạn 4: k3d (k3s v1.36.5, 1 server + 1 agent, registry local), Envoy Gateway + cert-manager TLS `*.svp.localhost`, dữ liệu trong cluster (CloudNativePG Postgres 15 SCRAM, Valkey, Redpanda SASL + ACL theo service, MinIO), PSA `restricted` và NetworkPolicy mặc định chặn hai chiều, một chart `svp-service` cho 6 service, KEDA scale media-worker theo lag, kube-prometheus-stack + Loki/Tempo/Pyroscope + Collector, Argo CD app-of-apps poll 60 s, Argo Rollouts canary cho gateway phân tích 5xx/p99 từ Envoy | Chấp nhận; §6 và đường image của §12 chỉnh bởi [0015](0015-cicd-devsecops-stage5.md); §2, §10 chỉnh bởi [0017](0017-gitops-capacity-media-worker-max2.md) |
| [0015](0015-cicd-devsecops-stage5.md) | Giai đoạn 5: hai workflow GitHub Actions ghim SHA với quyền theo job, chỉ build service đổi (so với lần phát hành thành công cuối), image amd64 + arm64 build native lên GHCR, trivy chặn bí mật và CRITICAL trước push, SBOM syft mỗi nền tảng, cosign keyless định dạng cũ với attestation `vuln` gộp hai nền tảng và rescan hằng ngày, Kyverno `ImageValidatingPolicy` chỉ ở namespace `svp` (Enforce trên GitOps, Audit trên dev), digest bên thứ ba kiểm tĩnh, promote bằng PR cuộn người học duyệt, Renovate App, ruleset `main` | Chấp nhận; thứ tự cắt RAM của §8 chỉnh bởi [0017](0017-gitops-capacity-media-worker-max2.md) |
| [0017](0017-gitops-capacity-media-worker-max2.md) | media-worker tối đa 2 replica (bước cắt 3 của ADR-0014 §2, topic giữ 3 partition) vì 3 worker cùng transcode làm Docker VM hết CPU và k3s server chết trên cluster GitOps; thêm tiêu chí ổn định (c): k3s server không restart trong `drill-k8s-keda` | Chấp nhận |
