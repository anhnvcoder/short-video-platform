# 0002. REST/JSON ở biên, gRPC bên trong, contract Protobuf quản lý bằng buf

- Trạng thái: Chấp nhận; đường dẫn file .proto chỉnh bởi [ADR-0006](0006-contract-ids-and-event-envelope.md)
- Ngày: 2026-10-04

## Bối cảnh

- Client (ở đây là k6, curl, trang thử HLS; về sau có thể là app) cần API dễ gọi, dễ debug, đi qua được mọi proxy và CDN.
- Bên trong, gateway gọi 4 service; mỗi request feed gọi ít nhất 2 service nối tiếp, ngân sách p99 cả chuỗi là 150 ms.
- Cần contract chặt giữa các service: đổi field ở một service phải bị phát hiện trước khi làm hỏng service khác.
- Mỗi lời gọi nội bộ phải mang theo deadline và cho huỷ được, để một service chậm không giữ tài nguyên của cả chuỗi.

## Các lựa chọn

### A. REST/JSON ở mọi nơi, mô tả bằng OpenAPI

- Được: quen thuộc (giống NestJS), debug bằng curl.
- Mất: contract nội bộ lỏng (JSON không kiểm kiểu lúc compile); tự viết client cho từng service; deadline và huỷ phải tự
  truyền qua header.

### B. gRPC ở mọi nơi, kể cả client (gRPC-Web)

- Được: một loại contract duy nhất.
- Mất: trình duyệt cần proxy gRPC-Web; khó debug, khó cache ở CDN; client bên ngoài kém thân thiện.

### C. REST/JSON ở biên, gRPC bên trong

- Được: client nhận REST quen thuộc; bên trong có contract kiểu chặt, code client/server sinh từ `.proto`, HTTP/2
  multiplexing, deadline lan truyền tự động qua `context`; `buf breaking` chặn thay đổi phá vỡ contract ngay ở CI.
- Mất: hai loại contract (OpenAPI cho ngoài, proto cho trong); gateway phải chuyển đổi; debug gRPC cần `grpcurl`.
- Biến thể: ConnectRPC cho một handler trả lời được cả gRPC lẫn HTTP/JSON. Không chọn vì mục tiêu là học gRPC chuẩn mà
  phần lớn hệ thống và tài liệu (OpenTelemetry, Envoy, Istio) đang dùng.

### D. GraphQL ở biên

- Được: client tự chọn field, gộp nhiều nguồn trong một request.
- Mất: thêm cả một mảng (resolver, N+1, cache theo query, giới hạn độ phức tạp) không phục vụ mục tiêu DevOps/SA của lộ trình.

## Quyết định

Chọn **C**, với các quy ước:

- `.proto` đặt ở `proto/<service>/v1/`, package `svp.<service>.v1`; `buf lint` (bộ luật `STANDARD`) và `buf breaking`
  (so với nhánh `main`) chạy trong CI.
- Gateway viết handler REST bằng `net/http`, không sinh tự động từ proto (như grpc-gateway). Lý do: gateway phải **ghép**
  dữ liệu từ nhiều service (feed + bộ đếm, xem [architecture.md §7.2](../architecture.md#72-đọc-feed)), việc mà proxy sinh tự động 1-1 không
  làm được. OpenAPI viết tay hay sinh từ code: chốt ở giai đoạn 1.
- Mọi lời gọi gRPC đều có deadline. Gateway đặt deadline tổng cho request; các service truyền tiếp bằng `context`, không
  tự đặt lại dài hơn.

## Hệ quả

- Được: contract nội bộ chặt, thay đổi phá vỡ bị chặn ở CI; client ngoài dùng REST bình thường.
- Phải trả: thêm toolchain (`buf`, `protoc-gen-go`, `protoc-gen-go-grpc`); phải giữ OpenAPI và proto khớp nhau; cần
  `grpcurl` hoặc server reflection để gọi thử.
- Xem lại khi: xuất hiện client thứ hai có nhu cầu dữ liệu khác hẳn (ví dụ trang quản trị). Lúc đó cân nhắc BFF riêng
  cho từng loại client.

## Hiện thực ở

- Contract gRPC: `proto/svp/`, `buf.yaml`, `buf.gen.yaml`, code sinh ở `gen/go/`; `buf lint`, `buf breaking` ở job `check` và
  `buf` của `.github/workflows/ci.yml`.
- Biên REST/JSON: `services/gateway/` (`internal/api/api.go` dịch REST sang gRPC và đặt hạn cho mỗi call, service chỉ chuyển
  tiếp hạn đó), contract REST viết tay ở `services/gateway/openapi.yaml`.
