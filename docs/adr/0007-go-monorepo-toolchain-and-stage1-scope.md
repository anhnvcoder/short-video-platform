# 0007. Một Go module cho cả monorepo, công cụ ghim ở Makefile, cấu hình bằng biến môi trường, phạm vi giai đoạn 1 thu về luồng đồng bộ

- Trạng thái: Chấp nhận
- Ngày: 2026-10-11

## Bối cảnh

- Giai đoạn 1 bắt đầu viết Go: `gateway`, `user-service`, `video-service` chạy local, mỗi service một database có
  migration, có unit test và integration test, lint, Docker multi-stage và compose (plan, giai đoạn 1). Module, cách sinh
  code, dependency, tên biến môi trường, cổng, cách nối database và image là nền của mọi service: đổi về sau là sửa tất cả
  cùng lúc. Code giai đoạn 1 lấy tên biến, cổng, đường dẫn và version từ ADR này.
- Các quyết định trước để lại cho giai đoạn 1: cách đặt `go_package` ([ADR-0006](0006-contract-ids-and-event-envelope.md)
  mục 1), thư viện sinh UUIDv7 (ADR-0006 mục 2), OpenAPI viết tay hay sinh từ code
  ([ADR-0002](0002-sync-rest-edge-grpc-internal.md)).
- Ràng buộc: Go 1.27.2 (Homebrew), `buf` 1.73.0; Postgres 15 native ở `127.0.0.1:5432`, Redis native ở `6379`; máy 16 GB,
  compose chạy theo profile; các biện pháp giai đoạn 1 của [threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn)
  (JWT-1 tới JWT-3, JWT-5, JWT-7 tới JWT-10, UP-3, UP-8, RL-4, RL-5, IN-1, IN-2, IN-6, IN-8, SEC-1, SEC-2, OPS-1, OPS-3).
- Phạm vi giai đoạn 1 lệch danh sách "Làm" của plan ở ba chỗ (Redis, outbox, presigned upload); mục 8 ghi lý do.

## 1. Go module và bố cục thư mục

### Các lựa chọn về module

#### A. Một `go.mod` ở gốc repo

- Được: một `go.sum`; mọi service dùng cùng version dependency, nên các service deploy cùng một commit chạy cùng code thư
  viện; code sinh từ proto và code dùng chung import thẳng, không cần `replace`; `go test ./...` từ gốc chạy hết.
- Mất: không nâng dependency cho riêng một service được; `go.mod` chứa hợp các dependency của mọi service (binary chỉ link
  gói nó import, nên image không phình).

#### B. `go.work` + mỗi service một module

- Được: version dependency độc lập theo service; ranh giới module rõ.
- Mất: phải tách thêm module cho code sinh từ proto và code dùng chung, kèm `replace` hoặc gắn tag version cho chúng; các
  service lệch version dependency dù deploy cùng commit; nhiều `go.sum` phải cập nhật. Lợi ích hay được nêu, "chỉ build
  service có thay đổi" ở CI (giai đoạn 5), làm được bằng lọc đường dẫn mà không cần tách module.

### Quyết định về module

Chọn **A**: `go.mod` ở gốc, module `github.com/anhnvcoder/short-video-platform`, directive `go 1.27` (gói chuẩn `uuid` mới
có từ Go 1.27, mục 3).

```text
go.mod, go.sum, Makefile
buf.yaml, buf.gen.yaml
proto/svp/<domain>/v1/        contract (ADR-0006)
gen/go/svp/<domain>/v1/       code sinh từ proto, có commit
internal/                     code dùng chung giữa các service
services/<svc>/cmd/<svc>/     main.go
services/<svc>/internal/      code riêng của service
services/<svc>/sqlc.yaml      cấu hình sqlc của service
tools/<tên>/                  công cụ cho dev, không deploy
deploy/docker/, deploy/compose/, deploy/postgres/
docs/
```

Ngoài các thư mục `CLAUDE.md` đã liệt kê (`services/`, `proto/`, `deploy/`, `docs/`), thêm ba thư mục:

- `gen/`: tách code sinh khỏi code viết tay, không ai sửa tay trong đó. Cấp `gen/go/` chừa chỗ cho ngôn ngữ khác nếu có (ví
  dụ Python cho phần ML).
- `internal/` ở gốc: code mà ít nhất hai service cần (đọc biến môi trường, log, interceptor đọc `x-user-id`, kiểm UUID, ký
  và kiểm JWT). Go chỉ cho package nằm trong cây chứa thư mục `internal/` import nó: mọi thứ trong repo dùng được, module
  ngoài thì không. Code chỉ một service dùng không đưa lên đây.
- `tools/`: chương trình phụ trợ cho dev, không đóng vào image (ví dụ `tools/jwtkey` sinh cặp khoá Ed25519 cho `make env`).

Code riêng của một service nằm ở `services/<svc>/internal/`: Go cấm mọi package ngoài `services/<svc>/` import nó, nên
gateway không import được repository của user-service. Ranh giới của [ADR-0001](0001-service-boundaries-and-data-ownership.md)
được compiler ép ở mức code; ở mức database thì ép bằng role (mục 6).

## 2. Sinh code từ proto

### Các lựa chọn về gắn package Go cho proto

#### A. Ghi tay `option go_package` trong từng file `.proto`

- Được: `protoc` thuần cũng sinh đúng; đọc proto là thấy package Go.
- Mất: contract vốn trung lập ngôn ngữ bị gắn với module path của Go; đổi module path phải sửa mọi file proto; với luật
  breaking `FILE`, đổi `go_package` bị tính là thay đổi phá vỡ.

#### B. Managed mode trong `buf.gen.yaml`

- Được: không sửa `proto/`; module path nằm ở một chỗ.
- Mất: chỉ `buf generate` sinh đúng; muốn biết package Go phải đọc `buf.gen.yaml`.

### Các lựa chọn về plugin

#### C. Remote plugin trên BSR

- Được: không phải cài plugin.
- Mất: mỗi lần sinh code phụ thuộc mạng và một dịch vụ ngoài, trong khi ADR-0006 giữ `buf` chạy offline, không dùng BSR.

#### D. Plugin local, cài bằng `go install` với version ghim

- Được: chạy offline; version nằm trong `Makefile` của repo.
- Mất: máy dev và CI phải chạy `make tools` trước.

### Các lựa chọn về code sinh ra

#### E. Không commit, sinh lúc build

- Được: repo gọn, không có diff code sinh.
- Mất: clone xong không build được nếu chưa cài `buf` và plugin; Docker build phải cài chúng; review không thấy contract đổi
  làm code đổi gì.

#### F. Commit code sinh ra

- Được: clone xong là `go build`, `go test` chạy được; Docker build chỉ cần Go; diff cho thấy code sinh thay đổi.
- Mất: diff to hơn; sửa proto mà quên sinh lại thì code lệch contract.

### Quyết định về sinh code

Chọn **B + D + F**.

- `buf.gen.yaml` v2 ở gốc repo, chạy bằng `buf generate` từ gốc:

  ```yaml
  version: v2
  managed:
    enabled: true
    override:
      - file_option: go_package_prefix
        value: github.com/anhnvcoder/short-video-platform/gen/go
  plugins:
    - local: protoc-gen-go
      out: gen/go
      opt: paths=source_relative
    - local: protoc-gen-go-grpc
      out: gen/go
      opt: paths=source_relative
  ```

- Code ra ở `gen/go/svp/<domain>/v1/`, package `userv1`, `videov1`, `eventv1`... Không sửa `proto/`.
- Commit cả code sinh từ proto lẫn code `sqlc` sinh ra. `make generate` chạy `buf generate` rồi `sqlc generate`; CI ở giai
  đoạn 5 chạy `make generate` rồi `git diff --exit-code` để bắt code lệch contract.

## 3. Dependency và công cụ

Version là bản ổn định mới nhất trên Go module proxy ngày 2026-10-11 (`go list -m -json <module>@latest`). Mọi module dưới
đây khai báo `go` trong `go.mod` của chúng không cao hơn 1.27.2, nên build được bằng toolchain hiện có.

### Các lựa chọn và quyết định về dependency runtime

| Module | Version | Vì sao cần | Đã cân nhắc |
| --- | --- | --- | --- |
| `google.golang.org/grpc` | `v1.84.0` | Server và client gRPC (ADR-0002). Gói `health` (health service chuẩn, dùng cho healthcheck của compose và probe gRPC của k8s ở giai đoạn 4) và `test/bufconn` (test gRPC qua bộ nhớ, không mở cổng) nằm sẵn trong module này | ConnectRPC (ADR-0002 đã loại) |
| `google.golang.org/protobuf` | `v1.36.12` | Runtime của code sinh từ proto | — |
| `google.golang.org/genproto/googleapis/rpc` | `v0.0.0-20261005182115-fad411399dd8` | Gói `errdetails` để gắn `google.rpc.ErrorInfo` vào status (architecture §8.4). Module này không gắn tag, nên version là pseudo-version | Tự định nghĩa message lỗi: lệch chuẩn `google.rpc`, `grpcurl` và client gRPC chung không hiểu |
| `github.com/jackc/pgx/v5` | `v5.11.0` | Driver Postgres: pool `pgxpool`, kiểu `uuid`/`timestamptz`; gói `stdlib` cho goose chạy qua `database/sql`. Code `sqlc` sinh ra dùng pgx/v5 | `lib/pq` (ở chế độ bảo trì); chỉ `database/sql` (mất pool và kiểu dữ liệu riêng của pgx) |
| `github.com/pressly/goose/v3` | `v3.28.0` | Migration SQL dùng **như thư viện**: file `.sql` nhúng vào binary bằng `embed`, chạy bằng lệnh con `<svc> migrate`; image distroless không cần thêm CLI. Mỗi migration chạy trong một transaction, lỗi thì rollback sạch | golang-migrate (cũng nhúng được, nhưng migration lỗi để database ở trạng thái `dirty`, phải sửa tay bằng `force`); Atlas (khai báo schema mong muốn rồi tự tính diff: thêm một mô hình và một CLI ngoài trọng tâm của lộ trình) |
| `github.com/golang-jwt/jwt/v5` | `v5.3.1` | Ký và kiểm JWT. Thư viện JWT phổ biến nhất của Go; có `WithValidMethods` (JWT-1), `WithIssuer`, `WithAudience`, `WithExpirationRequired` (JWT-2), `WithLeeway` (lệch đồng hồ 30 giây); hỗ trợ EdDSA với khoá `crypto/ed25519` | Tự viết bằng thư viện chuẩn (ít dependency nhưng tự gánh mọi ca biên của một ranh giới bảo mật); `lestrrat-go/jwx`, `go-jose` (bề mặt API lớn hơn nhiều so với nhu cầu ký/kiểm một loại token) |
| `golang.org/x/crypto` | `v0.58.0` | Gói `argon2` cho argon2id (threat model §4.1, JWT-7); thư viện chuẩn chưa có | bcrypt (threat model §4.1 đã loại) |

Dùng thư viện chuẩn, không thêm dependency:

- **UUIDv7:** gói chuẩn `uuid` của Go 1.27 (`uuid.NewV7`, `uuid.Parse`, `UUID.String`). Cân nhắc `github.com/google/uuid`
  (`v1.6.0`): làm được việc tương tự nhưng là thêm một dependency. `uuid.Parse` nhận cả dạng `{…}`, `urn:uuid:…`, dạng không
  gạch và chữ hoa, trong khi contract chỉ nhận dạng chuẩn 36 ký tự chữ thường (ADR-0006 mục 2). Kiểm ở biên bằng
  `u, err := uuid.Parse(s)` rồi bắt buộc `u.String() == s` (`String` luôn trả chữ thường có gạch).
- **Router REST:** `net/http.ServeMux` (pattern có method và wildcard từ Go 1.22, ví dụ `GET /v1/videos/{id}`). Cân nhắc
  chi, gin, echo: gateway có ít route, không cần middleware của framework; mux tự tạo bằng `http.NewServeMux`, không dùng
  `http.DefaultServeMux` (OPS-1).
- **Log:** `log/slog` với `JSONHandler`.
- **Cấu hình:** `os.Getenv` + một helper nhỏ trong `internal/`, không thư viện config (mục 4).
- **Test:** chỉ gói `testing`, không thư viện assert.
- **Ed25519, nhúng file:** `crypto/ed25519`, `embed`.

**Redis driver: không thêm ở giai đoạn 1** (mục 8). Giai đoạn 2 thêm `github.com/redis/go-redis/v9` (bản mới nhất ngày
2026-10-11 là `v9.23.0`; chốt version lúc thêm).

### Các lựa chọn về cách ghim công cụ

#### A. Directive `tool` trong `go.mod` (Go 1.24+)

- Được: version công cụ nằm trong `go.mod`, chạy bằng `go tool <tên>`, không cần bước cài.
- Mất: dependency của công cụ vào chung đồ thị module của ứng dụng. `sqlc` và `golangci-lint` kéo hàng trăm module vào
  `go.mod`/`go.sum`, và có thể ép nâng version dependency mà service đang dùng.

#### B. Ghim version trong `Makefile`, cài bằng `make tools`

- Được: `go.mod` chỉ chứa dependency của ứng dụng; mỗi công cụ build bằng chính Go 1.27.2 của máy.
- Mất: phải tự cập nhật version trong `Makefile` (tới khi có Renovate ở giai đoạn 5); máy dev và CI chạy `make tools` trước.

### Quyết định về công cụ

Chọn **B**. `make tools` chạy `go install <module>@<version>` cho từng công cụ:

| Công cụ | `go install` | Ghi chú |
| --- | --- | --- |
| `protoc-gen-go` | `google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12` | Cùng version với runtime `google.golang.org/protobuf` |
| `protoc-gen-go-grpc` | `google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2` | Module riêng, version riêng với `grpc` |
| `sqlc` | `github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1` | Parser Postgres của sqlc là thư viện C (`pg_query_go`), nên build cần cgo và trình biên dịch C (máy có clang của Xcode Command Line Tools; CI cần `gcc`) |
| `golangci-lint` | `github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0` | Hỗ trợ go1.27 từ v2.13.0 (CHANGELOG). Tài liệu golangci-lint khuyên cài binary dựng sẵn; chọn `go install` để công cụ được build bằng chính Go 1.27.2, vì golangci-lint chỉ phân tích được module có `go` không mới hơn bản Go đã build nó |
| `gitleaks` | `github.com/zricethezav/gitleaks/v8@v8.30.1` | Quét bí mật trong git hook (SEC-1) |

`buf` 1.73.0 đã cài qua Homebrew từ giai đoạn 0 (ADR-0006), không nằm trong `make tools`.

## 4. Cấu hình

### Các lựa chọn về cấu hình

#### A. Chỉ biến môi trường (12-factor)

- Được: cùng một image chạy ở compose, k8s và cloud, chỉ đổi biến; bí mật đưa vào lúc chạy qua cơ chế sẵn có của từng nền
  tảng (`.env` của compose, Secret của k8s, External Secrets ở giai đoạn 7).
- Mất: không có cấu hình lồng nhau; giá trị nào cũng là chuỗi, phải tự parse và kiểm.

#### B. File cấu hình (YAML) + thư viện như viper, koanf

- Được: cấu hình có cấu trúc, có mặc định trong file.
- Mất: thêm dependency; file phải mount vào container; bí mật vẫn phải đi đường riêng, nên có hai nguồn cấu hình.

### Quyết định về cấu hình

Chọn **A**. Mỗi service chỉ đọc biến của mình, không có file cấu hình. Thiếu biến bắt buộc hoặc giá trị sai định dạng thì
service thoát ngay lúc khởi động với lỗi nêu tên biến (không in giá trị).

| Service | Biến | Mặc định | Ý nghĩa |
| --- | --- | --- | --- |
| `user-service` | `LISTEN_ADDR` | `127.0.0.1:9101` | Địa chỉ gRPC |
| `user-service` | `DATABASE_URL` | — (bắt buộc) | DSN Postgres tới `svp_user` |
| `user-service` | `JWT_SIGNING_KID` | — (bắt buộc) | `kid` ghi vào header token |
| `user-service` | `JWT_SIGNING_KEY` | — (bắt buộc) | Seed Ed25519 32 byte, mã hoá base64 chuẩn. Chỉ user-service nhận khoá ký (JWT-10) |
| `video-service` | `LISTEN_ADDR` | `127.0.0.1:9102` | Địa chỉ gRPC |
| `video-service` | `DATABASE_URL` | — (bắt buộc) | DSN Postgres tới `svp_video` |
| `gateway` | `LISTEN_ADDR` | `127.0.0.1:8080` | Địa chỉ HTTP |
| `gateway` | `USER_SERVICE_ADDR` | `127.0.0.1:9101` | Địa chỉ gRPC của user-service |
| `gateway` | `VIDEO_SERVICE_ADDR` | `127.0.0.1:9102` | Địa chỉ gRPC của video-service |
| `gateway` | `JWT_VERIFY_KEYS` | — (bắt buộc) | `<kid>:<base64 chuẩn của khoá công khai 32 byte>[,…]`; giữ được cả khoá cũ và khoá mới trong lúc đổi khoá (SEC-4) |

- **Lệnh `migrate`** của user-service và video-service cũng đọc `DATABASE_URL`: compose đưa URL của role migrator cho
  container migrate, URL của role app cho container chạy service (mục 6).
- **Bind mặc định `127.0.0.1`:** chạy native thì cổng gRPC không lộ ra mạng (IN-2). Trong container đặt
  `LISTEN_ADDR=:<cổng>` để nhận kết nối từ mạng của compose; compose chỉ publish gateway (mục 5).
- **Bí mật chỉ đưa vào lúc chạy** (SEC-2). Local dùng `.env` ở gốc repo (đã gitignore), do `make env` sinh: mật khẩu
  database ngẫu nhiên và một khoá Ed25519 mới (`tools/jwtkey`). `make env` không ghi đè `.env` đã có. `.env.example` chỉ có
  tên biến, không có giá trị (SEC-1).
- **Test:** integration test đọc `SVP_TEST_POSTGRES_URL` (DSN superuser tới Postgres local ở `127.0.0.1:5432`) để tự tạo
  database riêng cho test. `make test` đặt giá trị local mặc định; chạy `go test` mà không đặt biến này thì integration
  test gọi `t.Skip`, unit test vẫn chạy.

## 5. Cổng

### Các lựa chọn về cổng

#### A. Cổng gRPC quen thuộc `50051` cho mọi service

- Mất: chạy native nhiều service trên một máy thì đụng nhau, vẫn phải đánh số riêng.

#### B. Mỗi service một cổng cố định trong dải riêng

- Được: chạy native và trong compose dùng cùng số; nhìn cổng biết service.

### Quyết định về cổng

Chọn **B**:

| Service | Giao thức | Cổng |
| --- | --- | --- |
| `gateway` | HTTP | 8080 |
| `user-service` | gRPC | 9101 |
| `video-service` | gRPC | 9102 |

- Kiểm ngày 2026-10-11 bằng `lsof -nP -iTCP -sTCP:LISTEN`: không tiến trình nào nghe ở 8080, 9101, 9102.
- Service sau lấy số tiếp theo trong dải `91xx` (engagement-service, feed-service ở giai đoạn 2).
- Compose chỉ publish gateway, và chỉ ở `127.0.0.1:8080` (IN-2). Cổng gRPC không publish ra máy.
- Cổng quản trị (pprof, `/metrics`) để giai đoạn 3. Giai đoạn 1 giữ OPS-1 bằng cách không dùng `http.DefaultServeMux`.

## 6. Compose nối Postgres native và role database

### Các lựa chọn về Postgres cho compose

#### A. Postgres chạy trong compose

- Mất: thêm một container ăn RAM trong khi máy đã có Postgres native; dữ liệu local tách thành hai nơi.

#### B. Container nối ra Postgres native

- Được: đúng ràng buộc máy của plan (giai đoạn compose dùng Postgres/Redis native); chạy native hay trong compose dùng cùng
  database.
- Mất: phụ thuộc cách Docker trỏ về máy host.

### Các lựa chọn về role

#### C. Một role cho mỗi service, vừa chạy migration vừa chạy service

- Mất: service đang chạy có quyền `CREATE`, `DROP` bảng; bị chiếm thì xoá được schema của chính nó.

#### D. Hai role cho mỗi service: migrator và app

- Được: service đang chạy chỉ đọc ghi dữ liệu, không đổi được schema (IN-6).
- Mất: thêm role, thêm một DSN phải quản lý; bảng mới phải được cấp quyền cho role app (giải bằng default privileges).

### Quyết định về Postgres

Chọn **B + D**.

- Container nối tới `host.docker.internal:5432` (Docker Desktop có sẵn tên này). Compose thêm
  `extra_hosts: ["host.docker.internal:host-gateway"]` để chạy được trên Linux.
- Mỗi service có database (`svp_user`, `svp_video`) như bảng trong `CLAUDE.md`, và hai role, đều `LOGIN`, không
  `SUPERUSER`, `CREATEDB`, `CREATEROLE`:
  - `svp_<svc>_migrator` sở hữu database `svp_<svc>` và chạy migration;
  - `svp_<svc>_app` chỉ có `CONNECT` trên database của mình và quyền DML (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) trên bảng,
    cấp bằng `ALTER DEFAULT PRIVILEGES FOR ROLE svp_<svc>_migrator IN SCHEMA public`, nên bảng do migration tạo sau này tự có
    quyền; không tạo được bảng.
- Bảng version của goose nằm ở schema riêng `goose` (`goose.goose_db_version`), do role migrator tạo và sở hữu. Default
  privileges chỉ áp cho schema `public`, nên role app không đọc ghi được lịch sử migration: service bị chiếm cũng không
  làm lần `migrate` sau chạy lại hay bỏ qua migration. Nới default privileges ra ngoài `public` sẽ phá điều này.
- Thu quyền `CONNECT` của `PUBLIC` trên các database đó: role của service này không kết nối được database của service khác.
- Tạo idempotent (chạy lại không lỗi, không đổi gì) bằng `make db-bootstrap`, script ở `deploy/postgres/`, kết nối bằng
  superuser `postgres` local. Mật khẩu role lấy từ `.env`.

## 7. Docker và binary

### Các lựa chọn về image runtime

#### A. Image có hệ điều hành (`alpine`, `debian-slim`)

- Được: có shell để debug, có `curl` cho healthcheck.
- Mất: thêm package phải vá lỗ hổng; kẻ chiếm được process có sẵn shell và công cụ.

#### B. `scratch`

- Được: nhỏ nhất.
- Mất: thiếu chứng chỉ CA, `tzdata`, user không phải root; phải tự chép vào.

#### C. distroless `static`, bản `nonroot`

- Được: có chứng chỉ CA, `tzdata`, user `nonroot` (uid 65532); không shell, không package manager.
- Mất: không `exec` vào container để debug được; healthcheck phải do chính binary làm.

### Quyết định về Docker và binary

Chọn **C**.

- Một Dockerfile multi-stage cho mọi service: `deploy/docker/service.Dockerfile`, chọn service bằng `ARG SERVICE`. Builder
  là `golang:1.27.x` ghim tag cụ thể (cùng bản Go của máy, hiện là 1.27.2); build `CGO_ENABLED=0`, `-trimpath`. Runtime là
  distroless `static` bản `nonroot`.
- Không có bí mật trong Dockerfile hay build arg (SEC-2).
- Mỗi service một binary ở `services/<svc>/cmd/<svc>/main.go`, lệnh con:
  - `serve` (mặc định khi không có lệnh con): chạy service;
  - `migrate`: chạy migration goose rồi thoát, chỉ ở service có database (user-service, video-service);
  - `healthcheck`: gọi health service gRPC (với gateway là endpoint HTTP) rồi thoát với mã 0 hoặc 1, vì distroless không
    có shell hay `curl`.
- Compose ở `deploy/compose/compose.yaml`, profile `core`; service migrate của mỗi service chạy một lần, service chính chờ
  nó xong. Target Docker nằm trong `deploy/compose/compose.mk`, được `Makefile` gốc `include`; mọi target gọi
  `env -u DOCKER_DEFAULT_PLATFORM docker ...` (`CLAUDE.md`).

## 8. Phạm vi giai đoạn 1

Danh sách "Làm" của plan có Redis và ngầm có outbox, presigned upload. Giai đoạn 1 chỉ làm phần chạy được và test được mà
không cần hạ tầng bất đồng bộ.

### Các lựa chọn về phạm vi

#### A. Làm đủ danh sách của plan, kể cả Redis

- Mất: thiết kế chưa có chỗ nào dùng Redis ở giai đoạn 1 (rate limit ở gateway và cache feed khám phá đều thuộc giai đoạn
  2). Thêm Redis bây giờ là tạo một chỗ dùng chỉ để đánh dấu đã làm: code giả, phải gỡ hoặc viết lại ở giai đoạn 2.

#### B. Làm luồng đồng bộ đầy đủ, để các phần cần storage và event cho giai đoạn 2

- Được: mọi thứ làm ra đều có test thật; giai đoạn 2 thêm Redis, MinIO, Redpanda cùng lúc với code thật sự cần chúng.
- Mất: `make up` của giai đoạn 1 chưa upload được file.

### Quyết định về phạm vi

Chọn **B**:

- **user-service:** `Register`, `Login`, `Follow`, `Unfollow` đầy đủ; **chưa phát event**.
- **video-service:**
  - `InitUpload` tạo video `UPLOADING` và chỉ trả `video_id`; `upload_url`, `form_fields`, `expires_at` để trống vì chưa có
    object storage. Giới hạn "500 MB" của [ADR-0004](0004-direct-upload-and-hls.md) hiểu là 500 MiB, tức `500 << 20` =
    524 288 000 byte.
  - `CompleteUpload` trả `UNIMPLEMENTED`: nó cần `HEAD` lên storage và outbox.
  - `GetVideo` đầy đủ, gồm luật hiển thị UP-3 (video chưa `READY` chỉ tác giả thấy, ADR-0006 mục 5).
  - Presigned POST và `CompleteUpload` làm ở giai đoạn 2.
- **gateway:** route REST, kiểm JWT (JWT-1, JWT-2), metadata gRPC dựng từ đầu (IN-1), đổi mã lỗi theo architecture §8.4
  (IN-8), timeout server và giới hạn kích thước thân request (RL-4). Chưa rate limit (RL-5, rủi ro đã chấp nhận).
- **Không dùng Redis ở giai đoạn 1** (lựa chọn A ở trên). Mục "Redis" của plan chuyển sang giai đoạn 2.
- **Chưa tạo bảng outbox:** chưa có relay, chưa có event; bảng tạo ra mà không ai ghi thì không test được. Giai đoạn 2 thêm
  migration goose cho bảng outbox cùng lúc với code ghi outbox trong cùng transaction với thay đổi trạng thái.
- **OpenAPI viết tay** ở `services/gateway/openapi.yaml` (OpenAPI 3.1), trả lời câu hỏi để ngỏ của ADR-0002: gateway ghép
  dữ liệu nhiều service nên handler viết tay; sinh OpenAPI từ code cần thêm dependency (annotation hoặc framework). JSON ở
  biên dùng `snake_case`, khớp tên field trong proto.
- **`trace_id` ở giai đoạn 1:** gateway sinh `traceparent` W3C mới cho mỗi request (bỏ giá trị client gửi lên), truyền xuống
  qua metadata gRPC `traceparent`; service ghi `trace_id` vào log; thân lỗi trả `trace_id` (architecture §8.4).
  OpenTelemetry ở giai đoạn 3 dùng đúng key này, nên chỉ thay chỗ sinh, không đổi đường truyền.

## Hệ quả

- Được:
  - Clone xong là build và test được chỉ với Go; Docker build không cần `buf`, plugin hay `sqlc`.
  - Một version dependency cho cả repo; ranh giới giữa các service được compiler ép (`internal/`) và Postgres ép (role).
  - `go.mod` chỉ có 7 dependency trực tiếp; còn lại là thư viện chuẩn.
  - Service đang chạy không đổi được schema, không kết nối được database của service khác; bí mật không nằm trong repo
    hay image.
  - Mọi thứ giai đoạn 1 làm ra đều có test thật, không có code chỉ để đánh dấu đã làm.
- Phải trả:
  - Code sinh từ proto và `sqlc` nằm trong repo: diff to hơn, phải chạy `make generate` sau khi sửa proto hoặc SQL; CI
    kiểm lệch từ giai đoạn 5.
  - Version công cụ ghim trong `Makefile` và version dependency trong `go.mod` phải tự cập nhật tới khi có Renovate (giai
    đoạn 5); build `sqlc` cần cgo.
  - Redis lùi một giai đoạn; `make up` của giai đoạn 1 chưa upload được file; `CompleteUpload` trả `UNIMPLEMENTED`.
  - Các service tin `x-user-id` tới khi có mTLS ở giai đoạn 6 (ADR-0006 mục 5); giai đoạn 1 chỉ dựa vào bind
    `127.0.0.1` và việc compose không publish cổng gRPC.
- Xem lại khi:
  - Một service cần một version dependency khác hẳn các service còn lại (cân nhắc tách module), hoặc thời gian build CI
    của một thay đổi nhỏ vượt 10 phút.
  - Diff code sinh chiếm phần lớn review của các PR, hoặc CI bắt lệch `make generate` quá một lần mỗi tháng.
  - Một công cụ ghim ở `Makefile` chậm hơn bản mới nhất quá hai minor mà chưa có Renovate.
  - Cần cấu hình lồng nhau hoặc nhiều hơn khoảng 15 biến cho một service (cân nhắc file cấu hình).
