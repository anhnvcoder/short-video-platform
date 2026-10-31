# 0030. DevSecOps bổ sung: govulncheck chặn lỗ hổng Go mà code gọi tới (ngoại lệ có hạn, image Go build bằng đúng bản Go đã quét), fuzz native của Go cho 10 hàm parse input không tin cậy, Schemathesis theo OpenAPI ở job `stack` (chỉ báo), CodeQL default setup bật bằng cài đặt repo (chỉ báo); không Semgrep/Opengrep, không ZAP; grype quét SBOM syft của mọi image trước push

- Trạng thái: Chấp nhận (người học duyệt ADR, gồm mục 6, và phần hạ tầng ngày 2026-10-28); hiện thực và kiểm trên PR #28, SHA
  `d58e67d`, ngày 2026-10-29 (mục Kết quả; rule Renovate của mục 1 thêm sau SHA đó, cùng PR). **Kiểm sau push:** SARIF grype lên tab Security, cảnh báo CodeQL #36, #37 đóng trên
  `main`, lượt `stack` và CodeQL trên `main`, PR Renovate thật đầu tiên đổi cùng lúc directive `go`, image `golang` và `setup-go` (mục Kết quả)
- Ngày: 2026-10-28

## Bối cảnh

- Phần 3b của giai đoạn 6b ([plan](../../plans/261004-devops-sa-roadmap/plan.md), khối "Phần 3b"): người học giao ngày 2026-10-28 "xem
  best practice như nào thì làm" và đã chốt công cụ: `govulncheck` vào `make check` (chặn PR), fuzz native của Go cho hàm parse input
  (seed chạy trong `make test`), Schemathesis (DAST theo `services/gateway/openapi.yaml`) trên stack compose ở job `stack` (chỉ báo),
  CodeQL **default setup** bật trong cài đặt repo (không file workflow). Không thêm Semgrep/Opengrep, không ZAP lúc này. ADR này không
  chọn lại công cụ: nó ghi trạng thái ngành của từng công cụ và của phương án bị loại (có nguồn, đọc ngày 2026-10-28), rồi chốt cách
  dùng đủ chi tiết để phần hiện thực không phải đoán.
- Đây là hai dòng "để sau" của [ADR-0015](0015-cicd-devsecops-stage5.md) §12: govulncheck ("trivy đã đọc module trong binary Go;
  govulncheck bớt cảnh báo giả nhưng thêm một công cụ ghim") và DAST ("cần stack chạy trong CI; giai đoạn 6 có k6 và stack đo"). Job
  `stack` của `ci.yml` có từ giai đoạn 6 ([ADR-0020](0020-reliability-stage6.md) §15), nên điều kiện của DAST đã có.
- **Lỗ hổng đang có** (govulncheck v1.9.0 chạy ngày 2026-10-28 khi soạn ADR):
  - GO-2026-6809 (`crypto/x509`, `Certificate.Verify`, sửa ở go1.27.3 [N4]), mức symbol: code gọi tới qua đường TLS của
    `internal/objstore` (`Store.Download`). Máy dev có go1.27.2, CI ghim `go-version: 1.27.3` ở mọi job, còn
    `deploy/docker/service.Dockerfile` và `deploy/docker/media-worker.Dockerfile` vẫn build bằng `golang:1.27.2-trixie@sha256:…`: image
    phát hành mang lỗ hổng này mà govulncheck trên CI (Go 1.27.3) không thấy. Trivy quét image có đọc phiên bản thư viện chuẩn trong
    binary, nhưng chỉ chặn CRITICAL (ADR-0015 §6). Nguyên nhân gốc: `go.mod` chỉ khai `go 1.27` ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md)
    phần module), không có gì buộc ba nơi dùng cùng một Go; nhóm Renovate "go toolchain and base images" (ADR-0015 §10) chỉ gom PR,
    không chặn lệch.
  - `golang.org/x/net` v0.60.0: GO-2026-6866 (`html.Render`), GO-2026-6860 (`html.Parse…`), sửa ở v0.62.0 (phát hành 2026-10-27) [N5];
    code không gọi.
  - `golang.org/x/crypto` v0.58.0: GO-2026-5932 (mọi gói `x/crypto/openpgp…`, không có bản vá) [N6]; code không import `openpgp`.
- Ràng buộc: repo public (log, artifact, SARIF ai cũng đọc; SC-9); CI trung lập nền tảng, YAML chỉ nối bước ([ADR-0023](0023-ci-platform-neutral.md));
  Actions chỉ cho action của GitHub và `sigstore/cosign-installer`, bắt ghim SHA (ADR-0015 §11); công cụ chạy bằng version hay image
  ghim, Renovate đọc được (ADR-0015 §10); máy 16 GB, `make up` chỉ khi cần; thêm dependency phải có lý do (`go.mod` không có thư viện
  YAML).

## 1. govulncheck

### Các lựa chọn

Trạng thái ngành: govulncheck là công cụ chính thức của nhóm Go, đọc cơ sở dữ liệu `vuln.go.dev` và phân tích theo đồ thị gọi
(**hiện hành**); bản mới nhất v1.9.0, phát hành 2026-10-11 [N1][N3]. Nó báo ba mức: module (module có lỗ hổng nằm trong build), package
(gói lỗi được import), symbol (code gọi tới hàm lỗi); ở chế độ chữ, exit 3 khi có finding đúng mức quét (mặc định `symbol`), còn với
`-format json` luôn exit 0 [N1][N2]. Nó **không có cách bỏ qua một finding** ("There is no support for silencing vulnerability findings",
go.dev/issue/61211) [N1].

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ như cũ: trivy quét image, Dependabot alerts | Không thêm gì | Theo module, không biết code có gọi tới không; trivy chỉ chặn CRITICAL; GO-2026-6809 đã lọt |
| govulncheck chặn mọi mức | Chặt nhất | Đỏ vì lỗ hổng ở gói không bao giờ chạy (GO-2026-5932 không có bản vá: đỏ mãi) |
| **govulncheck chặn mức symbol, mức module và package chỉ báo** | Chặn đúng thứ chạm được từ code; ít cảnh báo giả | Phân tích tĩnh: gọi qua `reflect` hay chỉ qua interface có thể lọt hay báo thừa [N1] |
| govulncheck chỉ báo | Không chặn PR | Lỗ hổng được gọi tới vẫn vào `main` |
| `-mode binary` trên image | Quét đúng binary phát hành | Không có trace, mức module như trivy, trùng cổng image [N1] |
| **Gate riêng đọc `-format json` + tệp ngoại lệ có hạn** | Có đường cho lỗ hổng chưa có bản vá; lý do, hạn, review qua PR | Thêm một tool nhỏ phải viết và test |
| Dùng exit 3 của chế độ chữ | Không code thêm | Không có ngoại lệ: lỗ hổng chưa vá mà code gọi tới chặn mọi PR |

Giữ một Go cho máy, CI và image:

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Dòng `toolchain go1.27.3` trong `go.mod` | Renovate cập nhật mặc định [N9]; máy go1.27.2 tự đổi sang 1.27.3 (`GOTOOLCHAIN=auto`) [N7] | Image `golang` đặt `GOTOOLCHAIN=local` [N8] nên bỏ qua dòng này: Dockerfile vẫn build được bằng bản cũ, đúng lỗi hôm nay |
| Directive `go 1.27.3` làm sàn, govulncheck quét bản sàn, không gì so với image | Toolchain từ chối module có `go` cao hơn nó khi `GOTOOLCHAIN=local` [N7]: Dockerfile **dưới** sàn không build được | Dockerfile **trên** sàn build xanh mà bản quét vẫn là sàn: lỗ hổng chỉ có ở bản của image (hồi quy trong một bản vá) lọt. Renovate nâng image và `setup-go` nhưng mặc định không nâng directive `go` [N9], nên lệch kiểu này là trạng thái thường gặp, không phải hiếm |
| **Directive `go 1.27.3` là bản Go phát hành: govulncheck quét đúng bản đó, gate đòi mọi `FROM golang:` của Dockerfile cùng bản** | Bản quét bằng bản build của mọi image Go: image dưới thì build đỏ, trên thì `check` đỏ; Renovate đổi directive, image, `setup-go` trong một PR khi directive được bật `rangeStrategy: bump` [N9] | Gate đọc thêm dòng `FROM` của Dockerfile; máy dev có Go mới hơn vẫn chạy test bằng Go của máy (không vào image) |
| Quét bằng Go đọc từ tag của Dockerfile, directive giữ `go 1.27` | Quét đúng image, không cần so | Hai Dockerfile khác bản thì phải quét từng bản; directive thành chỗ thứ ba không ai kiểm |
| Script riêng so `go.mod`, `setup-go`, Dockerfile | Bắt mọi lệch | Đọc YAML của workflow (gắn với GitHub, ADR-0023); tách khỏi phép quét nên vẫn phải nói quét bản nào |

### Quyết định

- **Ghim:** trong khối ghim đầu `Makefile`:

  ```make
  # renovate: datasource=go depName=golang.org/x/vuln
  GOVULNCHECK_VERSION        := v1.9.0
  ```

  `make tools` thêm `GOBIN=$(GOBIN) go install golang.org/x/vuln/cmd/govulncheck@$(GOVULNCHECK_VERSION)`. Dòng này nằm trong nhóm
  Renovate "tools" có sẵn; nó không phải dòng `TRIVY_IMAGE`/`SYFT_IMAGE`/`COSIGN_IMAGE` nên đổi nó không build lại image
  (`deploy/ci/changed-services.sh`).
- **Target `make vulncheck`** (dòng `##` cho `make help`), nằm trong `check-go` trước `test`:
  `check-go: fmt-check vet lint actionlint buf-lint vulncheck test`. Job `check` của `ci.yml` đã chạy `make tools ci-tools` rồi
  `make check-go`, nên không sửa workflow; cache GOBIN khoá theo hash `Makefile` nên bản ghim mới được cài lại. Recipe:
  1. Đọc bản Go phát hành: `go list -m -f '{{.GoVersion}}'` (directive `go` của module chính); không có số patch (`1.27`) thì dừng:
     "the go directive of go.mod must name a patch release (go 1.27.3)".
  2. `GOTOOLCHAIN=go<bản đó> govulncheck -format json ./... > "$$tmp/vuln.json"` (tệp tạm, `trap` xoá): govulncheck lấy phiên bản thư
     viện chuẩn từ `go env GOVERSION` và ghi nó vào `config.go_version` [N2], nên mọi máy quét đúng thư viện chuẩn của bản phát hành
     (toolchain tải về và kiểm qua checksum database như module [N7]), dù Go cài trên máy cũ hơn hay mới hơn. Exit ≠ 0 của govulncheck
     (mất mạng, không build được, cờ sai) làm target đỏ: ghi ra tệp rồi kiểm exit code, không dùng pipe (không cần `pipefail`, `sh` của
     make không chắc có).
  3. `go run ./tools/vulngate $(wildcard deploy/docker/*.Dockerfile) < "$$tmp/vuln.json"` quyết exit code (đối số là các Dockerfile mà
     gate so Go của image với bản đã quét, dưới đây).
- **Cần mạng** (`vuln.go.dev` [N1]; lần đầu tải toolchain của bản phát hành): mất mạng là đỏ, cả trên máy. Không có biến bỏ qua (một
  công tắc như thế sớm muộn vào CI); máy offline chạy từng target khác của `check-go`. Không dùng `-db file://…` (bản sao DB phải tự
  giữ mới).
- **Không `-mode binary`:** image đã có trivy quét module và thư viện chuẩn trong binary (ADR-0015 §6); binary không có thông tin gọi
  nên chỉ được mức module [N1], trùng việc trivy làm. Thay vào đó gate bảo đảm mọi image Go build bằng đúng bản Go mà phép quét mã
  nguồn đã dùng (quy tắc "Go của image" dưới đây), nên kết quả mức symbol áp đúng cho binary phát hành.
- **Gate `tools/vulngate/`** (Go, chỉ thư viện chuẩn, cùng kiểu `tools/jwtkey/`): đọc luồng JSON từ stdin. Định dạng là chuỗi object
  `Message`, mỗi object đúng một trường: `config` (đầu tiên; `protocol_version`, `go_version`, `db`, `db_last_modified`), `progress`,
  `SBOM`, `osv`, `finding` [N2]. `finding` có `osv` (id), `fixed_version` (rỗng khi chưa có bản vá), `trace` (frame đầu là symbol lỗi;
  mức module: một frame không package; mức package: một frame không function) [N2]. Quy tắc:
  - `config.protocol_version` khác `v1.0.0`, thiếu `config` hay `config.go_version`, JSON hỏng → đỏ ("unexpected govulncheck output"):
    bản govulncheck mới đổi giao thức thì PR Renovate đỏ ngay, không lặng lẽ bỏ sót.
  - **Go của image:** đọc từng Dockerfile ở đối số. Mỗi dòng `FROM` (không phân biệt hoa thường, bỏ qua `--platform=…`) có image
    `golang` (hay `docker.io/library/golang`) phải có tag mở đầu bằng bản đủ ba số (`golang:1.27.3-trixie@sha256:…`), và `go` + bản đó phải bằng `config.go_version`.
    Lệch → đỏ, mỗi dòng một khối: `FAIL  deploy/docker/service.Dockerfile:11: golang image is go1.27.4, govulncheck scanned go1.27.3
    (go directive of go.mod): use one Go release in both`. Tag không đủ ba số (`golang:1.27-trixie`, `golang:latest`) → đỏ "pin a
    patch release". Không có dòng `FROM golang` nào trong mọi tệp được truyền → đỏ "no golang build stage in <tệp…>": đổi tên tệp hay
    image builder không làm gate lặng lẽ bỏ qua. Tệp không có `FROM golang` (`web.Dockerfile`) được bỏ qua.
  - **Mức symbol** = finding có frame đầu mang `function`. Một id có nhiều finding chỉ tính một lần (khoá: id + `module`@`version` của
    frame đầu). Mỗi lỗ hổng mức symbol không có mục ngoại lệ hợp lệ → đỏ, in một khối:
    `FAIL  GO-2026-6809 stdlib@v1.27.2 (fixed in v1.27.3)` hay `(no fix)`, rồi một trace (frame từ điểm vào tới symbol lỗi, mỗi frame
    `package.Receiver.Function file:line`).
  - **Mức module và package:** không đỏ; in một dòng đếm và danh sách id: `INFO  2 vulnerabilities in required modules, not called:
    GO-2026-6866 golang.org/x/net@v0.60.0, …`.
  - Xanh: `ok    govulncheck: no called vulnerability (go1.27.3, 2 golang images match, vuln.go.dev modified <db_last_modified>)`.
  - Mọi lỗi của tệp ngoại lệ (dưới đây) → đỏ, dòng `FAIL  .govulncheck-ignore.json: entry <n> (<id>): <lý do>`. Exit 0 khi xanh, 1 khi
    đỏ.
- **Tệp ngoại lệ `.govulncheck-ignore.json`** ở gốc repo, **chỉ tạo khi có mục đầu tiên** (vắng tệp là không ngoại lệ):

  ```json
  {
    "ignore": [
      {
        "id": "GO-2026-0000",
        "module": "example.com/mod",
        "version": "v1.2.3",
        "statement": "Why the call is not exploitable here, and what removes it.",
        "expired_at": "2026-11-27"
      }
    ]
  }
  ```

  - Khoá gốc duy nhất `ignore` (mảng không rỗng; tệp có mảng rỗng → đỏ "delete the file"); mỗi mục đúng năm trường trên, trường lạ ở
    mọi mức → đỏ (`DisallowUnknownFields`).
  - `id` khớp `^GO-[0-9]{4}-[0-9]{4,}$`; `module` là đường module đúng như frame đầu ghi (`stdlib` cho thư viện chuẩn [N2]); `version`
    đúng phiên bản frame đầu ghi (`v1.2.3`; thư viện chuẩn dạng `v1.27.3`); `statement` không rỗng sau khi bỏ khoảng trắng; `expired_at`
    dạng `YYYY-MM-DD`.
  - Hạn: mục thôi tác dụng từ **00:00 UTC** ngày `expired_at` (như `.trivyignore.yaml`, ADR-0015 §6); `expired_at` ≤ hôm nay (UTC) → đỏ
    "expired"; > hôm nay + **30 ngày** → đỏ "more than 30 days ahead". 30 ngày như quy tắc lỗ hổng của trivy: lỗ hổng chưa vá có thể có
    bản vá bất kỳ lúc nào, nên mỗi tháng phải có người xem lại.
  - Trùng (`id`, `module`, `version`) → đỏ. Mục không khớp finding mức symbol nào (đã nâng, code thôi gọi, sai phiên bản) → đỏ "stale
    entry": tệp không giữ mục chết.
  - **Có bản vá thì luôn nâng, không ghi ngoại lệ:** mục khớp một finding có `fixed_version` khác rỗng → đỏ "fix available in <v>:
    upgrade instead". Ngoại lệ chỉ dành cho lỗ hổng chưa có bản vá mà code gọi tới.
  - Vì sao JSON, không YAML: `tools/vulngate` nằm trong module chính (như `tools/jwtkey`), một thư viện YAML sẽ vào `go.mod` của ứng
    dụng chỉ vì một tệp cấu hình; `encoding/json` có sẵn và từ chối trường lạ. JSON không có comment, nên lý do nằm ở `statement`.
  - Vì sao tool Go dưới `tools/`, không script dưới `deploy/ci/`: mọi thay đổi dưới `deploy/ci/` (trừ các tệp liệt kê ở đầu
    `changed-services.sh`) làm build lại cả bảy image; `tools/` không là dependency của service nào nên không. Quy tắc tệp được kiểm mỗi
    lần gate chạy (tức ở mọi PR qua `check`), không cần thêm bước vào job `config` như `scan-gate.sh --check-ignorefile`.
- **Một bản Go phát hành** (chỉnh ADR-0007 phần module: directive `go 1.27` thành bản có số patch):
  - `go.mod`: `go 1.27.3`, không dòng `toolchain`. Directive là **bản Go phát hành**: govulncheck quét đúng bản này (bước 2 của
    recipe) và mọi image Go build bằng đúng bản này (quy tắc "Go của image" của gate). Với máy dev nó là sàn: máy go1.27.2 tự đổi sang
    go1.27.3 (`GOTOOLCHAIN=auto`) [N7]; máy có Go mới hơn chạy test bằng Go của máy, không đổi bản quét hay image. golangci-lint v2.14.0
    chỉ so phiên bản ngôn ngữ (1.27) với Go đã build nó, nên bản cài bằng go1.27.2 vẫn lint được [N10].
  - Hai Dockerfile: `golang:1.27.3-trixie@sha256:<digest index>` (giữ dạng và chỗ của dòng hiện có; digest đọc bằng
    `docker buildx imagetools inspect`). Image `golang` có `GOTOOLCHAIN=local` [N8]: Dockerfile dưới directive dừng ở `go mod download`
    ("go.mod requires go >= 1.27.3") [N7]; trên directive thì build được, nên gate chặn trường hợp đó ở `check`.
  - `setup-go` của CI giữ `go-version: 1.27.3` như hiện có; gate không đọc workflow. Go của CI chạy test và lint, không vào image phát
    hành và không đổi bản quét (`GOTOOLCHAIN` ở bước 2); đọc YAML của workflow sẽ gắn gate với GitHub (ADR-0023).
  - **Renovate:** `renovate.json` thêm một rule `{"matchManagers": ["gomod"], "matchDepNames": ["go"], "matchDepTypes": ["golang"],
    "rangeStrategy": "bump"}` (description nói lý do: directive là bản Go phát hành, phải đi cùng image `golang`) để directive `go` được
    đề xuất [N9]; nó rơi vào nhóm "go toolchain and base images" có sẵn (rule `matchDepNames: ["go"]`), nên một PR đổi directive,
    `setup-go` và image `golang` cùng lúc và xanh. Kiểm bằng `make renovate-check`. PR nào chỉ đổi image (Renovate tách nhóm, hay sửa
    tay) đỏ ở `check` với dòng `FAIL` của gate: người duyệt thêm đổi directive vào chính PR đó.
  - Nâng Go khi govulncheck đỏ vì thư viện chuẩn: cùng một PR đổi directive, hai Dockerfile và `go-version` ở mọi job của `ci.yml`,
    `verify.yml`. Bỏ sót Dockerfile hay directive: `check` đỏ (image trên directive) hoặc build image đỏ (dưới); bỏ sót `setup-go`: CI
    chạy test bằng Go khác, bản quét và image không đổi. Không đường nào để image phát hành mang Go khác bản đã quét.
- **Lỗ hổng hôm nay:** GO-2026-6809 sửa bằng directive `go 1.27.3` và hai Dockerfile như trên. `golang.org/x/net` (mức module, code
  không gọi): để Renovate nâng như mọi module (v0.62.0 mới 1 ngày, dưới `minimumReleaseAge` 3 ngày của ADR-0015 §10), không nâng tay ở
  phần này.
  `golang.org/x/crypto` GO-2026-5932: không có bản vá, code không import `openpgp`: chỉ đếm ở dòng `INFO`. Không tạo
  `.govulncheck-ignore.json` khi không có lỗ hổng mức symbol nào chưa vá.
- Không vào git hook `pre-commit` (cần mạng, vài chục giây).

## 2. Fuzz native của Go

### Các lựa chọn

Trạng thái ngành: fuzz native có trong `go test` từ Go 1.18 (**hiện hành**); seed corpus (`f.Add` và `testdata/fuzz/FuzzXxx/`) chạy như
test thường khi không có `-fuzz`; `-fuzz` nhận regex khớp **một** fuzz test; corpus sinh ra nằm trong `$GOCACHE/fuzz`, input làm lỗi
được ghi vào `testdata/fuzz/FuzzXxx/` và từ đó chạy ở mọi `go test`; tham số chỉ được là `string`, `[]byte`, số nguyên, số thực, `bool`;
coverage instrumentation chỉ có trên AMD64 và ARM64; target phải nhanh, tất định, không dựa vào trạng thái toàn cục; hạn mỗi lần gọi
1 s; OSS-Fuzz chạy được fuzz native [N11]. go-fuzz (dvyukov) là đường cũ (**cũ**), GitLab coverage-guided fuzzing còn dùng nó và đã bị
đánh dấu deprecated [N29].

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Fuzz native, seed trong `make test`, `make fuzz` chạy tay** | Không công cụ mới; seed giữ mọi lỗi đã sửa mãi | Fuzz thật chỉ chạy khi có người chạy |
| Thêm lịch fuzz trong `verify.yml` | Fuzz đều đặn | Kịch bản mới, bộ lọc artifact, cache corpus giữa các lượt; ~25 phút runner mỗi tuần (miễn phí ở repo public) cho parser nhỏ, ít đổi |
| OSS-Fuzz / ClusterFuzzLite | Fuzz liên tục, hạ tầng của Google | Phải được nhận vào OSS-Fuzz hay thêm action bên thứ ba vào CI; quá tầm một lab |

### Quyết định

- **Mười target, mỗi gói một `fuzz_test.go`.** Tính chất kiểm bằng oracle độc lập với hàm đang kiểm (regexp hay kiểm tra viết lại
  trong test, `proto.Marshal`, chữ ký ed25519), không gọi lại chính hàm làm oracle; "không panic" là tối thiểu, không phải tính chất duy
  nhất.

  | Gói | Target (tham số) | Tính chất | Threat model |
  | --- | --- | --- | --- |
  | `internal/pagetoken` | `FuzzDecode(token string)` | Không panic; `len(token) > MaxLen` luôn `ErrInvalid`; mọi lỗi đều `errors.Is(err, ErrInvalid)`; giải mã được thì thời gian trong năm 1–9999, location UTC, `len(Encode(c)) ≤ MaxLen` và `Decode(Encode(c))` bằng `c` (`Time.Equal`, `VideoID`). Không đòi `Encode(Decode(t)) == t`: `Decode` bỏ qua field lạ và nhận mọi thứ tự field | PG-2 |
  | `internal/pagetoken` | `FuzzRoundTrip(micros int64, id []byte)` | `id` lấy 16 byte đầu (thiếu thì đệm 0) làm `VideoID`; `len(Encode(c)) ≤ MaxLen` với mọi `c` (token dài nhất 39 ký tự); `micros` trong khoảng năm 1–9999 thì `Decode(Encode(c))` bằng `c`, ngoài khoảng thì `ErrInvalid` | PG-2 |
  | `internal/authtoken` | `FuzzVerify(token string)` | Khoá ed25519 dựng từ seed 32 byte cố định trong test (tất định giữa các worker, không bí mật). (1) `Verify` thành công ⇒ chuỗi có đúng ba đoạn, header có `alg` `EdDSA` và `kid` đã cấu hình, và `ed25519.Verify(pub, đoạn1 + "." + đoạn2, chữ ký)` đúng (chữ ký giải bằng `base64.RawURLEncoding` như thư viện); tức chỉ chuỗi do khoá của test ký mới qua, không `alg: none`, không HS256 dùng khoá công khai. (2) chuỗi bằng token do `Issuer` của chính tiến trình cấp lúc dựng ⇒ hợp lệ và trả đúng user id. Seed: token hợp lệ, `alg: none`, HS256 ký bằng khoá công khai, khoá khác, `kid` lạ, thiếu `exp`, sai `iss`/`aud`, `jku`/`jwk` trong header | JWT-1, JWT-2 |
  | `services/gateway/internal/httpx` | `FuzzClientAddr(remoteAddr, xff1, xff2 string, hops uint8)` | `ClientAddr` dựng với `hops % 3` và dải tin cậy `10.42.0.0/16`, request có 0–2 header `X-Forwarded-For` từ `xff1`, `xff2`. (1) `hops` 0, hay host của `RemoteAddr` không phải IP trong dải tin cậy ⇒ kết quả là host của kết nối. (2) Kết quả khác host ⇒ là IP hợp lệ, viết dạng chuẩn (`netip.ParseAddr(kq)` được và `.String() == kq`, không dạng IPv4-mapped). (3) RL-1: kết nối tin cậy và danh sách có ≥ `hops` phần tử thì thêm một header `X-Forwarded-For` tuỳ ý **trước** các header có sẵn không đổi kết quả | RL-1 |
  | `services/gateway/internal/httpx` | `FuzzRequireAuth(auth1, auth2 string, n uint8)` | Request có `n % 3` header `Authorization` (`auth1`, `auth2`), verifier như `FuzzVerify`. Handler sau `RequireAuth` được gọi ⇒ đúng một header, scheme khớp `Bearer` không phân biệt hoa thường, phần token qua được tính chất (1) của `FuzzVerify`. Không được gọi ⇒ 401, `WWW-Authenticate: Bearer`, problem `INVALID_TOKEN`, cùng một `detail` | JWT-1, JWT-3 |
  | `services/gateway/internal/httpx` | `FuzzValidUTF8(path, query string)` | URL dựng bằng `url.ParseRequestURI("/" + path + "?" + query)` (không parse được thì bỏ qua input). Handler sau `ValidUTF8` được gọi ⇒ `r.URL.Path` và mọi khoá, giá trị của `r.URL.Query()` marshal được thành `wrapperspb.String(v)` bằng `proto.Marshal` (proto3 từ chối chuỗi không UTF-8: đúng lỗi 500 mà middleware chặn trước). Không được gọi ⇒ 400 `INVALID_UTF8` và ít nhất một chuỗi đó không marshal được | IN-8 |
  | `services/user-service/internal/server` | `FuzzHandle(s string)` | `h := normalizeHandle(s)`: luỹ đẳng (`normalizeHandle(h) == h`); `h` không còn byte `A`–`Z`; `validPickedHandle(h)` đúng **khi và chỉ khi** `h` khớp `^[a-z][a-z0-9_]{2,29}$` **và không** khớp `^u_[0-9a-f]{12}$` (hai regexp biên dịch trong test). Seed: `alice`, ` Alice `, `u_name` (hợp lệ), `u_0123456789ab` (bị từ chối), Kelvin sign `Kate` (bị từ chối), độ dài 2, 3, 30, 31 | WEB-17 |
  | `services/user-service/internal/server` | `FuzzEmail(s string)` | `(e, ok) := normalizeEmail(s)`: `!ok` ⇒ `e == ""`; `ok` ⇒ luỹ đẳng (`normalizeEmail(e) == (e, true)`), `len(e) ≤ MaxEmailBytes`, `e == strings.TrimSpace(e)`, `e == strings.ToLower(e)`, `mail.ParseAddress(e)` cho `Name` rỗng và `Address == e` | JWT-5, JWT-8 |
  | `services/user-service/internal/server` | `FuzzDisplayName(s string)` | `(n, empty, ok)`: `!ok` ⇒ `!empty`, không ràng buộc `n` (tên không có ký tự nhìn thấy như chỉ U+200D trả về `n` đã trim cùng `ok` false, và cả hai chỗ gọi bỏ `n` khi `!ok`); `empty` ⇒ `ok`, `n == ""`; `ok && !empty` ⇒ UTF-8 hợp lệ, `n == strings.TrimSpace(n)`, 1–50 rune, mỗi rune là U+200D hay thuộc `Variation_Selector` hoặc không thuộc Cc, Cf, `Other_Default_Ignorable_Code_Point`, U+2028, U+2029, U+2800 (bảng `unicode` viết lại trong test), có ít nhất một rune không phải khoảng trắng và không phải U+200D/`Variation_Selector`, và luỹ đẳng (`normalizeDisplayName(n) == (n, false, true)`). Seed: U+202E đầu tên, chỉ U+200D, U+3164, U+2800, emoji gia đình (có U+200D), 50 và 51 rune | WEB-18 |
  | `internal/objstore` | `FuzzIsMediaKey(key string, id []byte)` | `videoID` là chuỗi chuẩn của UUID từ 16 byte đầu của `id` (đệm 0), như mọi chỗ gọi (`id.String()`). `IsMediaKey(key, videoID)` đúng **khi và chỉ khi** `key` khớp `^media/<videoID>/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$` và không đoạn nào là `.` hay `..`; đúng ⇒ `path.Clean(key) == key`. Seed: `master.m3u8`, `720p/seg_000.ts`, `../x`, `%2e%2e/x`, `a\b`, `//x`, chuỗi rỗng sau prefix, `videoID` khác | FF-6 |

  Đọc code thấy khác đề xuất ban đầu của ADR ở hai chỗ, đã ghi vào bảng: oracle của `FuzzVerify` không được là "chuỗi khác token đã cấp thì
  không hợp lệ", vì `golang-jwt` mặc định giải base64 không strict [N31] nên 4 bit đệm của ký tự cuối đoạn chữ ký đổi được mà chữ ký vẫn
  đúng (cùng claim, cùng chữ ký: không phải giả mạo); và token cấp ở mỗi worker khác nhau (`iat`, `jti`), nên tính chất (2) chỉ so với
  token của chính tiến trình. Không bật `jwt.WithStrictDecoding()` ở phần này: không gì lưu hay so access token theo chuỗi (refresh
  token là chuỗi mờ, không phải JWT).
- **Seed chạy trong `make test`** (`go test` chạy seed như test thường, có `-race` như mọi test). `testdata/fuzz/FuzzXxx/` chỉ chứa input
  tái hiện lỗi đã sửa hay seed cố ý, không đổ corpus sinh ra (corpus nằm trong `$GOCACHE/fuzz`).
- **`make fuzz FUZZTIME=<thời lượng>`** (dòng `##` cho `make help`), mặc định `FUZZTIME=30s`, thu hẹp bằng `PKGS=` như `make test`:
  - Tìm target **không chạy binary test** nào: `go list -f '{{.ImportPath}} {{.Dir}}' $(PKGS)` rồi tìm `^func (Fuzz[A-Za-z0-9_]*)\(` trong
    `*_test.go` của mỗi thư mục. (`go test -list` chạy `TestMain`, mà `TestMain` của user-service dựng database.)
  - Chạy lần lượt từng target: `go test -run '^$$' -fuzz '^FuzzXxx$$' -fuzztime $(FUZZTIME) <gói>`, cùng `SVP_TEST_POSTGRES_URL`,
    `SVP_TEST_REDIS_URL` như `make test`; dừng ở target đầu tiên đỏ, in tên target và đường dẫn input go ghi ra. Không `-race` (fuzz chậm
    đi nhiều lần; seed đã chạy với `-race` trong `make test`), `-parallel` mặc định (`GOMAXPROCS`).
  - `TestMain` nào dựng database phải bỏ qua bước đó khi cờ `test.fuzz` khác rỗng hay `test.fuzzworker` bật: tiến trình điều phối và
    từng worker đều chạy lại `TestMain`, và `internal/pgtest` DROP rồi CREATE database theo tên cố định, nên các worker sẽ phá database
    của nhau. Ngoài chế độ fuzz, `TestMain` giữ nguyên hành vi.
  - Lỗi fuzz tìm ra: sửa hàm, commit input tái hiện ở `testdata/fuzz/FuzzXxx/` (test đỏ trước khi sửa, xanh sau).
- **Không lịch fuzz trong CI ở phần này.** Chi phí nếu làm: một kịch bản `verify.yml` mới (`fuzz`), thêm tệp vào danh sách cho phép của
  `verify-collect.sh` (input lỗi), cache `$GOCACHE/fuzz` giữa các lượt (cache của Actions, khoá theo tuần), ~10 target × 2 phút + build,
  khoảng 25 phút runner mỗi tuần (miễn phí ở repo public). Không đáng với mười parser nhỏ ít đổi; xem lại theo mục Hệ quả.

## 3. Schemathesis (DAST theo OpenAPI)

### Các lựa chọn

Trạng thái ngành: Schemathesis sinh request theo OpenAPI/GraphQL bằng property-based testing (Hypothesis), phát hành vài lần mỗi tuần
(4.32.4 ngày 22/10, 4.32.5 ngày 25/10, 4.32.7 ngày 27/10) [N12] (**hiện hành**); image chính thức `schemathesis/schemathesis` có
`linux/amd64` và `linux/arm64` [N13]. ZAP (nay mang tên "ZAP by Checkmarx") có script `zap-api-scan.py` nhập OpenAPI rồi chạy active scan
"tuned to APIs"; đăng nhập qua context file và `-U` [N26] (**hiện hành**, hướng ứng dụng web).

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Schemathesis theo `openapi.yaml`, image ghim digest** | Đọc đúng contract đã viết tay; kiểm cả lệch spec (status, schema, content type) lẫn 5xx, 401; một container nhẹ | Chỉ thấy những gì spec khai; rate limit của gateway làm mất độ phủ |
| ZAP API scan | Bộ quy tắc tấn công web lâu năm | JVM nặng (máy 16 GB, job `stack` đã chạy cả stack); đăng nhập qua context file; phần lớn quy tắc là của ứng dụng web có HTML |
| `--checks all` | Không phải chọn | `positive_data_acceptance`, `use_after_free`, `ensure_resource_availability`, `object_level_authorization`, `allow_header_conformance` cần điều spec không có hay báo giả có hệ thống (bên dưới) |
| Token qua `-H Authorization` | Đơn giản | `ignored_auth` không kết luận khi có header `Authorization` không khai trong spec [N16]; token nằm trên dòng lệnh |

### Quyết định

- **Ghim** cạnh `K6_IMAGE` trong `Makefile`:

  ```make
  # renovate: datasource=docker depName=schemathesis/schemathesis
  SCHEMATHESIS_IMAGE := schemathesis/schemathesis:4.32.4@sha256:b501f25d00fa6e2b393ddd1b525a11bb560d593fd06268491595c2e439090bf0
  ```

  4.32.4 là bản mới nhất có image đã đẩy lên Docker Hub ≥ 3 ngày lúc viết (`minimumReleaseAge` của ADR-0015 §10): tag `4.32.4` đẩy
  2026-10-22T17:55Z, còn `4.32.5` đẩy 2026-10-25T23:05Z, chỉ đủ 3 ngày từ 2026-10-28T23:05Z [N13]. Ba bản sau không sửa gì cách dùng ở
  đây cần (4.32.5 sửa request treo khi không đặt `--request-timeout`, ở đây có đặt; 4.32.6 hiệu năng và phase `coverage` rộng hơn;
  4.32.7 tương thích pytest) [N12]; Renovate đề xuất chúng theo lịch. Digest là `digest` của tag `4.32.4` theo API Docker Hub [N13],
  phần hiện thực kiểm lại bằng `docker buildx imagetools inspect` (index có `linux/amd64`, `linux/arm64`).
- **Tệp:** `deploy/dast/dast.mk` (target `dast`, `include` từ `Makefile` như `deploy/k6/k6.mk`), `deploy/dast/run.sh` (logic),
  `deploy/dast/schemathesis.toml` (cấu hình), báo cáo ở `.dast/<yyyymmddThhmmssZ>/` (thêm `.dast/` vào `.gitignore`; thư mục tạo
  mode 700 vì log, JUnit và HAR trong đó mang body của response, có token của user thử).
- **`make dast`** trên stack `make up` đang chạy (chỉ `core` là đủ):
  1. Từ chối khi container `gateway` của project `svp` không chạy, mạng `svp_web` không có, hay node/registry của cluster k3d `svp` đang
     chạy (như `deploy/k6/load.sh`); không khởi động gì.
  2. **LOCAL LAB ONLY:** `reset_register_limit` của `deploy/compose/lib.sh` (xoá `svp:gw:rl:register:*` ở Redis db 10, `SCAN` + `DEL`)
     trước và sau lượt; `wait_gateway_ready` trước khi chạy (lỗi do stack chưa sẵn sàng khác lỗi API).
  3. Đăng ký và đăng nhập một user thử (handle, email, mật khẩu ngẫu nhiên, qua `http://127.0.0.1:8080` như `new_user` của smoke). Access
     token vào biến `SVP_DAST_TOKEN` của script, không in, không `set -x`.
  4. `env -u DOCKER_DEFAULT_PLATFORM docker run --rm --name svp-dast-<time> --network svp_web --user "$(id -u):$(id -g)"
     -e SVP_DAST_TOKEN` (không giá trị: docker lấy từ môi trường, token không nằm trên dòng lệnh) với
     `services/gateway/openapi.yaml` và `deploy/dast/schemathesis.toml` mount chỉ đọc, thư mục báo cáo mount ghi; lệnh
     `--config-file /config/schemathesis.toml run /schema/openapi.yaml --url http://gateway:8080` (`--config-file` là tuỳ chọn chung,
     đứng trước `run` [N14]) cộng các cờ bên dưới. Stdout và stderr của `docker run` vào `.dast/<time>/schemathesis.log`
     (`> tệp 2>&1`), **không bao giờ ra terminal** (mục "Output và báo cáo"). Container riêng có địa chỉ riêng trên `svp_web`, nên
     bucket rate limit theo IP của nó tách khỏi bucket của bước đăng ký ở 3 (đi qua cổng publish) và của các bước khác.
  5. Hạn cả lượt **10 phút**: một tiến trình canh `docker stop svp-dast-<time>` khi quá hạn (macOS không có `timeout`), lượt quá hạn là
     đỏ. Chạy quá thì giảm `--max-examples`, không nới hạn.
  6. Dựng `summary.json` từ HAR, dò bí mật trên hai tệp công bố, rồi mới in tóm tắt từ chúng (dưới đây); exit theo Schemathesis: 0 mọi
     check đạt, 1 có check trượt, 2 không chạy được (cấu hình, schema, lỗi nội bộ, không test gì) [N14]; quá hạn hay lộ bí mật là 1.
- **Xác thực:** `[auth.openapi.bearerAuth]` với `bearer = "${SVP_DAST_TOKEN}"` trong `schemathesis.toml` (tên phải khớp
  `securitySchemes` của spec; chỉ `${VAR}` được thay, biến chưa đặt là lỗi) [N15]. Cách này để Schemathesis biết operation nào cần token
  nên `ignored_auth` gửi thêm request không token và token sai tới đúng các operation có `security: bearerAuth`, đòi 401 hay 403 [N16].
- **Check bật** (`--checks`): `not_a_server_error` (không 5xx), `status_code_conformance` (status có khai), `content_type_conformance`
  (content type có khai), `response_schema_conformance` (body khớp schema), `response_headers_conformance` (header có khai như
  `Retry-After` của 429 khớp schema), `ignored_auth` (401 khi không token hay token sai), `negative_data_rejection` (input sai schema bị
  từ chối) [N16]. Lý do riêng cho hai check sau: xác thực là ranh giới chính của gateway (JWT-1, JWT-3), và input không hợp lệ phải dừng
  ở 4xx thay vì đi xuống service (IN-8). `negative_data_rejection` đặt `expected-statuses = [400, 401, 403, 404, 405, 409, 413, 415,
  422, 429]` trong `schemathesis.toml` [N15]: mặc định của nó không có 404 [N16], mà gateway trả một 404 cho mọi id sai dạng ở route công
  khai (WEB-14) và 429 khi rate limit chặn trước.
- **Check tắt và vì sao:** `positive_data_acceptance` (`page_token` là chuỗi mờ và luật phía server như giới hạn upload không viết được
  trong schema, nên input "hợp lệ theo schema" bị 400 là bình thường: báo giả vĩnh viễn); `use_after_free`, `ensure_resource_availability`
  (cần stateful và `links`, spec không có [N16]); `object_level_authorization` (cần hai danh tính trong `[auth.wfc]` [N16]; UP-3 đã có
  test của service); `missing_required_header` (spec không khai header bắt buộc nào ngoài xác thực, `ignored_auth` đã phủ);
  `unsupported_method`, `allow_header_conformance` (`ServeMux` cho pattern `GET` nhận cả `HEAD` [N17] mà spec chỉ khai `GET`: báo giả
  theo hành vi chuẩn của HTTP, không phải rủi ro; 405 có `Allow` đã có test của gateway).
- **Phase:** `examples`, `coverage`, `fuzzing`; **không `stateful`** (spec không có `links`) [N14].
- **Phạm vi:** mọi operation của spec trừ `/healthz`, `/readyz` (`--exclude-path`): probe không nhận input, không xác thực, và `/readyz`
  trả 503 khi một dependency chập chờn là 5xx giả với `not_a_server_error`. Còn 20 operation.
- **Ngân sách** theo rate limit của gateway (`services/gateway/internal/ratelimit/ratelimit.go`): `register` 60/giờ burst 20 theo IP,
  `login-ip` 60/phút burst 30, `login-email` 10/giờ burst 5, `refresh` (cả logout) 60/phút burst 30, `public` 120/phút burst 60 theo IP;
  theo user: `upload` 30/giờ burst 10 (cộng tối đa 3 upload mở, 429 `TOO_MANY_UPLOADS`), `write` 120/phút burst 60, `read` 600/phút burst
  200. Cờ: `--rate-limit 5/s`, `--max-examples 25` (fuzzing, mỗi operation; không tác dụng ở examples, coverage [N14]), `--workers 1`,
  `--request-timeout 10`, `--mode all`, `--seed <số ngẫu nhiên của lượt>` (script sinh; `report.json` ghi lại [N32] để chạy lại cùng seed),
  `--generation-database none` (không ghi `.hypothesis/` vào repo). 5 request/giây vượt nhịp bền của `write` (2/giây) và mọi lớp theo
  IP sau vài chục request: 429 đã khai trong spec nên không làm check trượt, chỉ mất độ phủ; `summary.json` đo tỷ lệ đó. Không dùng
  `--rate-limit auto` (chờ `Retry-After`: với `register` là hàng phút mỗi lần).
- **Output và báo cáo:** với mỗi check trượt, Schemathesis in body của response (chỉ cắt ngắn, `--output-truncate`) và lệnh curl tái
  hiện; làm sạch (`--output-sanitize`, giữ mặc định bật) chỉ che header và khoá có tên nhạy cảm, báo cáo ghi nguyên body [N15][N32].
  Trong phạm vi có response mang bí mật: `POST /auth/register`, `/auth/login`, `/auth/refresh` trả access token và refresh token (chuỗi
  base64url mờ, không mẫu nào bắt chắc được), `POST /videos` trả form presigned (policy, chữ ký). Log job của repo public đọc được ngay
  và không thu hồi được (SC-9), nên dò sau khi in là muộn:
  - **Output thô không ra terminal:** terminal (cũng là log job) chỉ có dòng do `run.sh` in từ hai tệp công bố **sau khi** chúng qua
    phép dò: version, seed, exit code, `stop_reason`, số operation và test case, mỗi nhóm lỗi một dòng (`code`, `title`, `count`,
    operation), tiêu đề lỗi chạy, phân bố status và tỷ lệ 429. Exit 2 cũng vậy: tiêu đề lỗi có trong `report.json`, chi tiết đọc ở
    `schemathesis.log` trên máy (lượt CI đỏ thì chạy lại trên máy với seed của `report.json`; dữ liệu stack khác nên không chắc trùng).
  - `--report json,junit,har` với `--report-json-path /reports/report.json`, `--report-junit-path /reports/junit.xml`,
    `--report-har-path /reports/requests.har` [N14][N32]. Report `json` chỉ có số đếm, trạng thái phase, nhóm lỗi (`type`, `code`,
    `title`, `severity`, `count`, `operations`), tiêu đề lỗi chạy, seed và dòng lệnh, không body, không curl [N32]. JUnit ghi mỗi lỗi
    bằng đúng văn bản của terminal (body và curl) [N32], HAR ghi nguyên body [N15]: hai tệp này và `schemathesis.log` **chỉ nằm trên
    máy hay runner** trong `.dast/<time>/`, không in, không tải.
  - `summary.json` (script dựng từ HAR bằng `jq`, chỉ số và nhãn): thời điểm, thời gian, số request, phân bố status, phân bố status theo
    operation (method + path template của spec, nối request với template theo từng đoạn tĩnh), tỷ lệ 429.
  - **Tệp công bố** chỉ `report.json` và `summary.json`. Dò bí mật trên hai tệp đó trước khi in hay tải: mẫu `eyJ[A-Za-z0-9_-]{8,}` (JWT,
    và policy presigned là base64 của JSON), `"access_token"`, `"refresh_token"`, `X-Amz-Signature`, `X-Amz-Credential` (không phân
    biệt hoa thường), `svp_sid`, `Bearer [A-Za-z0-9]`, và **chính giá trị access token của lượt** (đưa vào `grep -F -f` qua process
    substitution, không trên dòng lệnh). Khớp thì lượt đỏ, chỉ in tên tệp và tên mẫu, không tải gì. Không dùng chữ `password` như bước
    k6: tiêu đề nhóm lỗi có thể nhắc tên trường.
- **Job `stack` của `ci.yml`:** bước `make dast` (`id: dast`, `continue-on-error: true`, `timeout-minutes: 15`) **sau**
  `make web-lighthouse` và trước `Container state`/`make down`: DAST làm cạn rate limit theo IP và theo user nên chạy cuối. Rồi bước chọn
  báo cáo (chạy khi `steps.dast.outcome` là `success` hay `failure`, dò lại như trên, chỉ chép `report.json` và `summary.json` khi
  sạch) và `actions/upload-artifact` ghim SHA như các bước khác, artifact `dast`. Job vẫn chỉ báo, ngoài `ci-ok` (ADR-0020 §15). Đo
  thời gian bước; job vượt ~40 phút thì nới `timeout-minutes` của job kèm lý do trong comment.
- Những gì Schemathesis ghi vào stack (user thử, tên hiển thị đổi, video `UPLOADING` do `POST /videos`, follow tới id ngẫu nhiên 404) nằm
  trong stack của lượt; video `UPLOADING` bị job dọn upload chuyển `FAILED` sau hạn. Không request nào ra ngoài stack.
- Lỗi thật Schemathesis tìm ra: spec lệch code hay handler gateway trả 5xx với input lạ thì sửa (spec đổi thì `make web-generate`); lỗi ở
  service sau gateway ghi thành việc riêng.

## 4. CodeQL default setup

### Các lựa chọn

Trạng thái ngành: CodeQL là SAST theo luồng dữ liệu của GitHub (**hiện hành**), default setup do GitHub dựng và quản workflow, đủ điều kiện
khi Actions bật và repo public [N19]; quét ở mỗi push lên nhánh mặc định hay nhánh bảo vệ, ở PR vào các nhánh đó **trừ PR từ fork**, và
hằng tuần nếu 180 ngày qua có push hay PR [N20]. API `PATCH /repos/{owner}/{repo}/code-scanning/default-setup` nhận `state`
(`configured`/`not-configured`), `query_suite` (`default`/`extended`), `threat_model` (`remote`/`remote_and_local`), `languages`
(gồm `actions`, `go`, `javascript-typescript`), `runner_type` [N18]. Bộ `extended` là `default` cộng các query độ chính xác và mức
nghiêm trọng thấp hơn, nhiều kết quả giả hơn [N21].

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Default setup bằng cài đặt repo** | Không file workflow: YAML của repo giữ trung lập nền tảng (ADR-0023); GitHub tự giữ action và bản CodeQL | Cấu hình nằm ngoài git (chỉ ghi lệnh trong tài liệu); không chọn được query riêng |
| Advanced setup (`codeql.yml` với `github/codeql-action`) | Toàn quyền cấu hình; `build-mode: manual` với lệnh build cố định trong YAML, nên script build của PR không chạy trong job CodeQL [N35] | Thêm workflow chỉ chạy được trên GitHub, thêm action phải ghim, quyền `security-events: write` trong YAML của repo |
| CodeQL CLI trong `Makefile` | Chạy trên máy, nền tảng nào cũng gọi được | Giấy phép CLI chỉ cho CI/CD với codebase mã nguồn mở host trên GitHub.com (hay khi có license GHAS trả phí) [N23]; repo chưa có tệp LICENSE |

### Quyết định

- **Bật** (người điều phối chạy, không card nào chạy `gh` ghi):

  ```sh
  gh api -X PATCH repos/anhnvcoder/short-video-platform/code-scanning/default-setup \
    -f state=configured -f query_suite=default -f threat_model=remote -f runner_type=standard \
    -f 'languages[]=actions' -f 'languages[]=go' -f 'languages[]=javascript-typescript'
  ```

  Đọc lại: `gh api repos/anhnvcoder/short-video-platform/code-scanning/default-setup` (đạt khi `state` là `configured`, đủ ba ngôn ngữ,
  `schedule` là `weekly` [N18]); lượt "CodeQL" đầu tiên trong tab Actions xanh; cảnh báo: `gh api
  'repos/anhnvcoder/short-video-platform/code-scanning/alerts?tool_name=CodeQL&state=open'`. Tắt: `-f state=not-configured`.
- **Ngôn ngữ:** `go` (service, `internal/`, `tools/`), `javascript-typescript` (`web/`), `actions` (`.github/workflows/`: script
  injection, checkout code không tin cậy, thứ actionlint không phân tích theo luồng dữ liệu; phủ một phần zizmor mà ADR-0015 §12 để sau).
- **`query_suite=default`, `threat_model=remote`:** chỉ báo nên ưu tiên ít báo giả; `extended` khi `default` đã sạch một thời gian
  (Xem lại khi).
- **Chỉ báo:** không thêm rule code scanning nào vào `.github/rulesets/main.json`; check CodeQL hiện trên PR (từ nhánh của repo) nhưng
  không bắt buộc. Cảnh báo giả được dismiss trong tab Security kèm lý do.
- **Tương thích với cài đặt Actions của ADR-0015 §11:** default setup chạy `github/codeql-action`, action của GitHub, nằm trong
  `github_owned_allowed`. Việc `sha_pinning_required: true` có chặn workflow động của default setup hay không **chưa kiểm được** ở tài
  liệu (đọc 2026-10-28): kiểm khi bật, bằng lượt CodeQL đầu tiên. Bị chặn thì **không** nới `sha_pinning_required`; tắt default setup,
  ghi kết quả và đưa lựa chọn (nới cài đặt, hay advanced setup) lại cho người học.
- **Chồng lấn:** gosec (trong golangci-lint, chặn ở `make check`) bắt mẫu trong từng hàm; CodeQL theo luồng dữ liệu qua hàm và tệp. Cùng
  phát hiện có thể hiện hai lần (category `golangci-lint` và CodeQL); gosec vẫn là cổng chặn. Default setup chỉ chặn tải lên SARIF **có
  kết quả của CodeQL** [N22], nên job `sarif` (golangci-lint, gitleaks, trivy-config, trivy-lockfile-web) không đổi.
- **Quyền, và code của PR chạy trong job CodeQL:** workflow của default setup do GitHub quản, không nằm trong quy tắc "mọi job của
  lượt PR chỉ `contents: read`" của ADR-0015 §1 (áp cho YAML của repo); job tải kết quả lên code scanning, việc mà mọi workflow cần
  `security-events: write` [N36]. Với Go, default setup dùng build mode `autobuild` (`none` chỉ cho C/C++, C#, Java, Rust; Go chỉ có
  `autobuild` hay `manual`) [N19][N33]. Autobuild Go **chạy script build của repo trước khi trích xuất**: gọi `make`, `ninja`,
  `./build`, `./build.sh` theo thứ tự tới khi một lệnh thành công và `go list ./...` sau đó thành công [N33]; mã autobuilder tìm
  `Makefile`, `makefile`, `GNUmakefile`, `build.ninja`, `build`, `build.sh`, chạy lệnh tương ứng không đối số, dừng ở lệnh đầu tiên
  thành công [N34]. Repo này có `Makefile` (không có tệp nào khác trong danh sách), nên job CodeQL chạy `make` không đối số của **commit
  được quét**: đọc Makefile (mọi `$(shell …)` ở mức parse, hôm nay `go env GOPATH`, `cat web/.nvmrc`, `ls` thư mục nvm; ba tệp
  `-include` `deploy/compose/compose.mk`, `deploy/k8s/k8s.mk`, `deploy/k6/k6.mk`, trong đó `compose.mk` có `$(shell grep … .env)` và
  `docker inspect`) rồi recipe của `.DEFAULT_GOAL` (`help`, hôm nay chỉ `grep`/`awk`). Vậy một PR sửa Makefile (đổi `.DEFAULT_GOAL`,
  recipe `help`, thêm `$(shell …)`) hay thêm `GNUmakefile` chạy lệnh của nó trong job có `security-events: write` trước khi ai duyệt;
  việc workflow do GitHub quản không loại bỏ điều đó.
  - **Ai mở được PR mà default setup quét:** chỉ PR từ nhánh của chính repo (PR từ fork không được quét [N20]; với advanced setup,
    lượt `pull_request` từ fork có mọi quyền ghi của token bị hạ về chỉ đọc [N37]). Đẩy nhánh lên repo cá nhân này được: chủ repo và
    collaborator [N38] (đọc 2026-10-28 bằng `gh api .../collaborators`: chỉ `anhnvcoder`), app Renovate có quyền ghi nội dung (SC-8), và
    `GITHUB_TOKEN` của job `promote` ghi nhánh `bot/promote` (ADR-0015 §9; chạy từ `images.yml` trên `main`, đã qua PR).
  - **Rủi ro còn lại:** một PR nội bộ (tài khoản người học hay app bị chiếm, SC-8) chạy lệnh tuỳ ý với token của job CodeQL. Quyền đầy
    đủ của token đó không ghi trong tài liệu đã đọc: **kiểm ở lượt CodeQL đầu tiên** (mục "GITHUB_TOKEN Permissions" ở đầu log, ghi vào
    Kết quả). Thứ chắc chắn ghi được là tab Security (xoá, làm nhiễu cảnh báo). **Chấp nhận ở lab** vì: tập người đẩy được nhánh là chủ
    repo, Renovate và job `promote`, đều có từ giai đoạn 5 (SC-3, SC-8 đã xét), và kẻ có quyền đó đã chạy được code trong mọi job lượt
    PR của `ci.yml`, `images.yml`; CodeQL chỉ báo, không là check bắt buộc, nên làm nhiễu nó không mở đường merge; `main` vẫn chỉ nhận
    PR có `ci-ok`, `images-ok`. Token có quyền ngoài `security-events` (ví dụ `contents: write`, `packages: write`) thì không chấp
    nhận: tắt default setup, ghi kết quả, chuyển phương án dưới.
  - **Phương án thay nếu không chấp nhận:** advanced setup với `build-mode: manual` và lệnh build cố định trong YAML (`go build ./...`,
    không gọi Makefile) [N35]; Go không có `build-mode: none` nên không bỏ được bước build [N33]. Đổi lại: một file workflow chỉ chạy trên
    GitHub (trái ADR-0023), action phải ghim SHA, `security-events: write` khai trong YAML của repo.

## 5. Không Semgrep/Opengrep, không ZAP; threat model; GitLab

### Vì sao không Semgrep/Opengrep, không ZAP

- **Semgrep CE:** engine LGPL 2.1, nhưng bộ rule do Semgrep duy trì theo "Semgrep Rules License v1.0", "available only for internal
  business use" [N25] (**hiện hành**, rule bị hạn chế). **Opengrep:** fork của Semgrep v1.100.0, LGPL 2.1, lập ra khi Semgrep chuyển tính
  năng quan trọng sang giấy phép thương mại [N24]; phát hành đều (1.31.0 ngày 15/10, 1.32.0 ngày 22/10, 1.33.0 ngày 27/10) [N24]
  (**mới nổi**). Repo đã có gosec (mẫu theo hàm, chặn) và CodeQL (luồng dữ liệu, báo): công cụ thứ ba cần bộ rule tự viết hay rule
  cộng đồng, thêm một luồng cảnh báo để đọc, mà không phủ mảng nào hai công cụ kia bỏ trống. Xem lại khi cần rule riêng của project
  (ví dụ cấm một API nội bộ) mà gosec và CodeQL không viết được gọn.
- **ZAP:** script API scan có sẵn [N26] (**hiện hành**), nhưng là JVM nặng trên máy 16 GB và trong job `stack` vốn đã dựng cả stack;
  quy tắc chủ yếu cho ứng dụng web có HTML (XSS, header của trang). API của gateway là JSON có OpenAPI viết tay: Schemathesis đọc đúng
  contract đó. Xem lại khi quét web client (`web/`, trang HTML, CSP, cookie) bằng DAST.

### Ánh xạ vào threat model

| Công cụ | Dòng có sẵn | Thêm gì |
| --- | --- | --- |
| govulncheck | SC-1 (lớp chặn trước image), FF-8 (cùng ý cho Go) | **Dòng mới đề xuất** (số kế tiếp còn trống của 4.8, hôm nay là SC-13): "Dependency Go và thư viện chuẩn có lỗ hổng đã công bố mà code gọi tới" (T, E, I): govulncheck chặn mức symbol ở `ci-ok`, ngoại lệ ≤ 30 ngày chỉ khi chưa có bản vá, image Go build bằng đúng bản Go đã quét (directive `go` có số patch, gate so dòng `FROM golang` của Dockerfile); mức module do Renovate và trivy |
| Fuzz | PG-2 (`pagetoken`), JWT-1, JWT-2 (`Verify`), JWT-3 (`RequireAuth`), RL-1 (`ClientAddr`), IN-8 (`ValidUTF8`), WEB-17 (handle), WEB-18 (tên hiển thị), FF-6 (`IsMediaKey`) | Cột "Kiểm bằng" của các dòng đó thêm target fuzz tương ứng |
| Schemathesis | JWT-1, JWT-3 (`ignored_auth`: route cần token trả 401), IN-8 (không 5xx, problem đúng schema), WEB-14 (route công khai), RL-1/RL-4 gián tiếp (429 có `Retry-After` đúng spec) | Không dòng mới; SC-10 (job `stack`) thêm artifact `dast` (chỉ `report.json`, `summary.json`, đã dò) vào danh sách đã lọc, và log bước không có output thô của Schemathesis (body của response) |
| CodeQL | SC-3 (script injection, query `actions`), WEB-1 (XSS ở `web/`), UP-4 (key ghép từ input), IN-8 | Không dòng mới; SC-3 thêm: job CodeQL của default setup (do GitHub quản, có `security-events: write`) chạy `make` không đối số của commit được quét (autobuild Go), chỉ với PR từ nhánh của repo (chủ repo, Renovate SC-8, `bot/promote`); chấp nhận ở lab vì CodeQL chỉ báo và `main` vẫn chỉ nhận PR có `ci-ok`, `images-ok`; quyền thật của token đọc ở lượt đầu (mục 4) |

Sửa `docs/threat-model.md` là việc của phần tài liệu; ADR chỉ nêu.

### Tương đương GitLab

| Công cụ | Trên GitLab |
| --- | --- |
| govulncheck | `make vulncheck` (trong `make check-go`) chạy nguyên trong job của `.gitlab-ci.yml`, mọi bậc; cần runner ra được `vuln.go.dev` và proxy module |
| Fuzz | `make fuzz` chạy trên runner nào cũng được. Coverage-guided fuzzing của GitLab: Ultimate, dùng go-fuzz (không phải fuzz native), deprecated từ 18.0, dự kiến bỏ ở 19.0 [N29]: không dùng |
| Schemathesis | `make dast` trong job dựng stack, như job `stack`. Bản có sẵn của GitLab là API security testing (trước là DAST API), Ultimate, nhận OpenAPI v2/v3 [N30] |
| CodeQL | **Không có trên GitLab:** giấy phép CodeQL CLI chỉ cho CI/CD khi codebase mã nguồn mở được host trên GitHub.com, hay khi có license GitHub Advanced Security trả phí [N23]. Tương đương: SAST của GitLab (analyzer dựa trên Semgrep, Go được hỗ trợ; chạy và tải báo cáo JSON ở mọi bậc, widget MR và vulnerability report chỉ Ultimate) [N27]; GitLab Advanced SAST (Ultimate, taint qua hàm và tệp, có Go) [N28] |

## 6. grype trên SBOM syft

### Bối cảnh riêng

Người điều phối kiểm ngày 2026-10-28 bản phát hành web `ghcr.io/anhnvcoder/short-video-platform/web@sha256:bc355bf1…` (tag
`39dcedeacb80`, `linux/amd64`): trivy (`TRIVY_IMAGE` ghim, 0.76.0) thấy 15 gói Debian và 64 package npm, **không thấy runtime Node.js**:
image distroless cài `node` không qua dpkg, nên không có cơ sở dữ liệu gói nào cho trivy đọc. syft (`SYFT_IMAGE` ghim) thấy `node 26.12.0`
bằng `binary-classifier-cataloger` (purl `pkg:generic/node@26.12.0`, CPE `cpe:2.3:a:nodejs:node.js:26.12.0`). SBOM đó đã được attest từ
giai đoạn 5 nhưng không ai đối chiếu nó với cơ sở dữ liệu lỗ hổng: một bản vá bảo mật của Node.js không bị CI nào bắt.

### Các lựa chọn

Trạng thái ngành: grype (Anchore, Apache-2.0) là bộ quét lỗ hổng đi cặp với syft, đọc ảnh, thư mục và **SBOM** (SPDX, CycloneDX, JSON
của syft) [N39] (**hiện hành**); phát hành đều (v0.120.0 ngày 2/10, v0.120.1 ngày 6/10, v0.121.0 ngày 19/10) [N40]. DB của nó build
hằng ngày, gom NVD, GitHub Advisory, Go vulndb, các distro (Debian, Alpine, Wolfi, Chainguard, …), KEV và EPSS (đọc từ `descriptor.db`
của report). Gói `pkg:generic` có CPE được khớp qua matcher `stock` (`match.stock.using-cpes: true` mặc định) [N41]. trivy (Aqua) và grype
(Anchore) là hai bộ quét image mã nguồn mở đang phát hành đều; hai DB và hai cách khớp khác nhau, nên chạy thêm grype bớt điểm mù của
một nguồn.

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ trivy một mình | Không thêm gì | Binary ngoài trình quản lý gói (node của web) không được quét: đúng lỗ hổng hôm nay |
| `trivy sbom` trên SBOM syft | Một công cụ, một ngoại lệ | Đã thử ngày 2026-10-28 với SPDX có `node 22.1.0` (`pkg:generic` + CPE): trivy không báo gì; nó không khớp CPE |
| grype đọc lại `image.tar` | Không phụ thuộc SBOM | Catalog lại cả image (lâu hơn), và cái được quét không còn chắc là cái đã attest |
| **grype trên chính SBOM syft của chân image** | Quét đúng danh sách gói đã attest; thấy `node` qua CPE (SPDX `node 22.1.0`: 1 Critical, 14 High); DB thứ hai cho cả gói Debian, npm, Go | Một image ghim nữa, một DB ~200 MB tải về (3,1 GB khi giải nén); hai bộ quét có thể xếp mức khác nhau cho cùng CVE |
| Cấu hình ignore của grype (`.grype.yaml`) | Có sẵn | Danh sách rủi ro thứ hai không có `--check-ignorefile`, hạn, lý do; dễ lệch với `.trivyignore.yaml` |

### Quyết định

- **Ghim:** `GRYPE_IMAGE := ghcr.io/anchore/grype:v0.121.0@sha256:621d56d1…` (digest của index, có `linux/amd64` và `linux/arm64`) trong
  khối ghim của `Makefile`, dòng `# renovate: datasource=docker depName=ghcr.io/anchore/grype` ngay trên (custom manager có sẵn đọc được, nhóm
  "tools"). Bản mới nhất đã phát hành ≥ 72 giờ ở ngày viết. Script đọc qua `tool_image GRYPE_IMAGE`.
- **Chọn image cần build:** `deploy/ci/changed-services.sh` coi dòng `GRYPE_IMAGE` như `TRIVY_IMAGE`, `SYFT_IMAGE`, `COSIGN_IMAGE`: PR chỉ
  nâng grype build và quét cả bảy image trước khi merge; dòng khác của `Makefile` không tính.
- **Chạy** (`grype_sbom` của `deploy/ci/common.sh`, gọi từ `build-image.sh` ngay sau syft): `grype sbom:/out/sbom.spdx.json`, ra
  `grype.json` và SARIF; container chạy bằng user gọi, có mạng chỉ để tải DB. Không đọc cấu hình nào của grype: thư mục làm việc và
  `HOME` là tmpfs trống, không mount gì vào đó (đã thử: `.grype.yaml` nằm ở thư mục làm việc thì grype đọc và bỏ qua lỗ hổng theo nó, nên
  thư mục làm việc không bao giờ là thư mục của repo hay OUT). DB tải được hoặc chân đỏ: `GRYPE_DB_REQUIRE_UPDATE_CHECK=true`, giữ kiểm
  tuổi mặc định (DB build quá 5 ngày thì từ chối) [N41]; đã thử: cache trống và không mạng thì exit 1. Cache theo ngày trong `images.yml`
  (`SVP_GRYPE_CACHE`, key `grype-db-<ngày>`), như DB của trivy; grype tự kiểm DB mới khi lần kiểm trước đã quá 2 giờ.
- **Cổng** `scan-gate.sh [--allow-critical] --grype LABEL REPORT`, cùng quy tắc với cổng trivy: mỗi match `vulnerability.severity` là
  `Critical` còn lại sau ngoại lệ → exit 1, in id (kèm CVE liên quan), package@version, purl, bản sửa (không in report thô); High trở
  xuống chỉ đếm, bảng một hàng `<image> <nền tảng> (grype)` trong summary (và log) cạnh bảng trivy, có cột số match được ngoại lệ.
  `--allow-critical` chỉ cho `drill-vulnerable`. Report không phải của grype → exit 2. `build-image.sh` chạy **cả hai cổng** rồi mới
  dừng, nên summary luôn có hai hàng; một cổng đỏ là chân đỏ, không push.
- **Ngoại lệ: tái dùng `.trivyignore.yaml`**, không file mới, không cấu hình ignore của grype. Một mục che một match khi **cả hai**: `id`
  của mục bằng `vulnerability.id` hay một `relatedVulnerabilities[].id` của match (grype hay báo GHSA khi mục ghi CVE: log4j 2.14.1 ra
  `GHSA-jfh8-c2jp-5v3q` với `CVE-2021-44228` ở liên quan), và một `purls` của mục bằng `artifact.purl` của match sau khi bỏ qualifier
  (`?…`), subpath (`#…`) và giải mã `%XX` ở cả hai phía (grype viết `%2B`, trivy viết `+`). Mục không có `purls` không che gì ở grype.
  **Nghiêm hơn trivy:** trivy bỏ mục hết hạn rồi đánh giá phần còn lại; cổng grype đỏ khi `.trivyignore.yaml` có mục hết hạn (từ đúng
  ngày `expired_at`, như trivy đọc), kể cả với report sạch, để ngày hết hạn được xử lý trước khi có gì phát hành. Mục hết hạn không che
  match nào. File sai quy tắc cũng làm cổng đỏ, như cổng trivy.
- **SARIF:** `grype.sarif` chỉ HIGH, CRITICAL không bị ngoại lệ che (như trivy), category `grype-image-<image>-<arch>/`. grype đặt tên rule
  `<lỗ hổng>-<tên gói>` và result không mang purl, nên một result được giữ khi có một match cùng rule được giữ: hai version của một gói mà
  một bị ngoại lệ thì cả hai vẫn hiện (không bao giờ ít hơn số cổng đếm). Artifact `sarif-<image>-<arch>` của job `build` trên `main` mang
  cả `trivy.sarif` và `grype.sarif`; job `sarif` tải mọi `*.sarif` rồi upload **mỗi công cụ một lần** (mọi `trivy.sarif` cùng SARIF của
  rescan, rồi mọi `grype.sarif`): `upload-sarif` gộp mọi file không phải CodeQL nó nhận thành một SARIF log [N44] và GitHub từ chối log
  quá 20 run [N43], mà bảy image (14 chân) là 28 run; mỗi công cụ tối đa 14. Trước mỗi upload job đếm run bằng `jq` của runner, quá 20
  thì công cụ đó không upload và job đỏ với số run và giới hạn (công cụ kia vẫn upload). PR chỉ có summary, như trivy.
- **Trên máy:** `make grype SBOM=<đường tuyệt đối tới SPDX JSON>` (grype và cổng trên SBOM đó) và `make grype IMAGE=<ref@sha256:…>
  [ARCH=amd64|arm64]` (syft ghim đọc image của nền tảng đó từ registry, ẩn danh, rồi như trên); image ghim, `env -u DOCKER_DEFAULT_PLATFORM`.
  In số gói của SBOM và các binary ngoài trình quản lý gói (`node@26.12.0` với bản web ở trên).
- **Ngoài phạm vi:** attestation `vuln`, Kyverno và lượt rescan hằng ngày vẫn chỉ đọc trivy: một lỗ hổng Node.js công bố **sau** khi
  phát hành chỉ bị bắt ở lần build `web` kế tiếp (Xem lại khi).

### Số đo (2026-10-28, Mac arm64)

| Đo | Kết quả |
| --- | --- |
| `make grype IMAGE=…web@sha256:bc355bf1… ARCH=amd64` | 130 gói, có `node@26.12.0`; Critical 0, High 13, Medium 10, Low 3, Negligible 7; exit 0 |
| `make grype SBOM=<SPDX chỉ có log4j-core 2.14.1>` | Critical 2 (`CVE-2021-44228`, `CVE-2021-45046` qua GHSA), High 1, Medium 5; exit 1 |
| Thêm vào mỗi chân `build-image.sh` (DB đã cache) | gateway arm64 5 s, web arm64 7 s |
| Lần tải DB đầu (cache trống) | 2 phút 13 s; archive 196 MB, 3,1 GB trên đĩa |
| Cùng chân web arm64, trivy và grype | trivy: High 0, Medium 25, Low 8; grype: High 13 (gói Debian gcc, glibc, zlib) — hai nguồn xếp mức khác nhau |

Sự kiện 2026-10-30 (lượt `images.yml` 41068691476): grype chặn cả hai chân `media-worker` vì CVE-2026-58016 (glib 2.88.1-r1, Critical,
chưa có bản vá ở Alpine 3.24 lẫn edge; trivy không xếp Critical). glib không gỡ được: ffmpeg cần libavfilter (filter `scale`, `split`
của worker), libavfilter link harfbuzz, harfbuzz link `libglib-2.0`. Lỗi nằm ở `g_dbus_node_info_new_for_xml()` của `libgio` (parser
XML introspection D-Bus), thư viện mà ffmpeg, ffprobe không nạp, trong container không có D-Bus: thêm mục vào `.trivyignore.yaml`
(hạn 2026-11-29). Bản phát hành `media-worker` đang chạy ở stg và prd (`sha256:1d2adefe…`, tag `ec12f1141e57`) cũng mang glib 2.88.1-r1
(`make grype IMAGE=…@sha256:1d2adefe… ARCH=arm64`: Critical 0, Excepted 1, ngày 2026-10-30), nên điều kiện "Xem lại khi" về grype ở mục
Hệ quả đã tới: rescan và attestation `vuln` (Kyverno đọc) chỉ có kết quả trivy, không thấy CVE này. Có đưa grype vào rescan hay không là
quyết định riêng, chưa làm.

### Ánh xạ vào threat model

| Công cụ | Dòng có sẵn | Thêm gì |
| --- | --- | --- |
| grype | SC-1 (image chạy trong cluster có lỗ hổng nghiêm trọng) | Cột "Kiểm bằng" của SC-1 thêm: grype trên SBOM syft của mỗi chân image, cùng cổng Critical và ngoại lệ của `.trivyignore.yaml`, bắt runtime cài ngoài trình quản lý gói (node của web) mà trivy không thấy; giới hạn: attestation và rescan hằng ngày chỉ trivy |

### Tương đương GitLab

| Công cụ | Trên GitLab |
| --- | --- |
| grype | Container Scanning của GitLab mặc định dùng trivy; analyzer grype deprecated ở 16.9, không còn bảo trì từ 17.0, ngừng chạy ở 19.0 [N42]: không dùng. `make grype` và `build-image.sh` chạy nguyên trong job của `.gitlab-ci.yml` (cần Docker và mạng tới `grype.anchore.io`); report JSON của grype không phải định dạng báo cáo bảo mật của GitLab, nên chỉ có log và artifact; muốn vào vulnerability report thì tự viết bước chuyển theo tài liệu tích hợp scanner của GitLab [N42] |

## Hệ quả

- Được:
  - Lỗ hổng Go mà code gọi tới chặn PR ở `ci-ok`; GO-2026-6809 hết khỏi image phát hành; image Go build bằng đúng bản Go đã quét, lệch
    là `check` đỏ.
  - Mười parser nhận input không tin cậy có tính chất kiểm bằng fuzz, seed giữ mọi lỗi đã sửa trong `make test`.
  - Contract `openapi.yaml` được kiểm với gateway thật ở mỗi lượt `stack`: lệch spec, 5xx, route cần token mà không đòi token.
  - CodeQL theo luồng dữ liệu cho Go, TypeScript và workflow mà không thêm YAML nào vào repo.
  - Mọi image qua thêm một DB lỗ hổng trước push, trên đúng SBOM đã attest; runtime ngoài trình quản lý gói (node của web) được quét.
- Phải trả:
  - `make check-go` cần mạng và chậm thêm thời gian của govulncheck (đo khi hiện thực); `vuln.go.dev` lỗi là `check` đỏ, chạy lại job.
  - Nâng Go đổi bốn chỗ trong một PR (Renovate làm cả bốn nhờ rule `rangeStrategy: bump` của directive [N9]); gate đọc dòng `FROM`
    của Dockerfile, nên đổi cách build image Go (builder khác image `golang`) phải sửa gate cùng lúc.
  - Một tool Go nhỏ (`tools/vulngate`) và tệp ngoại lệ phải giữ; mỗi ngoại lệ sống tối đa 30 ngày.
  - Fuzz thật chỉ chạy khi có người chạy `make fuzz`.
  - DAST làm job `stack` dài thêm tới 10 phút; 429 làm mất độ phủ của các route có rate limit chặt (`register`, `login`, `upload`).
  - Lượt DAST đỏ trên CI chỉ cho biết check, operation và số lần; body và lệnh tái hiện chỉ có khi chạy lại `make dast` trên máy.
  - Cấu hình CodeQL nằm ngoài git; cảnh báo trùng với gosec phải dismiss tay; PR từ fork không được CodeQL quét.
  - Job CodeQL chạy `make` của commit được quét với token ghi được tab Security: một PR nội bộ sửa Makefile chạy lệnh của nó ở đó
    trước khi duyệt (rủi ro chấp nhận ở lab, mục 4).
  - grype: mỗi chân image thêm vài giây (DB đã cache) hay ~2 phút (tải DB); cache DB ~480 MB mỗi entry (`grype-db-2026-10-29` 482 MB
    theo `gh cache list`), một entry mỗi ngày trên `main` cộng mỗi ref PR, tức ~0,5–1 GB mỗi ngày của quota cache 10 GB của repo, nên
    cache khác (tools, pnpm, trivy) bị đẩy ra sớm hơn; một nguồn lỗ hổng thứ hai có thể
    chặn image vì Critical mà trivy không xếp Critical; mục hết hạn của `.trivyignore.yaml` làm đỏ mọi chân image (mục 6).
- Xem lại khi:
  - govulncheck đỏ vì `vuln.go.dev` (không phải vì lỗ hổng) quá 2 lượt `main` trong một tháng: cân nhắc cache DB theo ngày như trivy.
  - Một tệp ngoại lệ được gia hạn quá 2 lần cho cùng một id: thay dependency thay vì gia hạn.
  - `make fuzz` tìm ra lỗi, thêm parser mới nhận input không tin cậy, hay review bảo mật giai đoạn 9: thêm kịch bản `fuzz` vào
    `verify.yml` theo chi phí ở mục 2.
  - Repo có collaborator hay app thứ ba mới có quyền ghi nội dung, CodeQL thành check bắt buộc, hay token của job CodeQL có quyền ngoài
    `security-events`: chuyển CodeQL sang advanced setup `build-mode: manual` với lệnh build cố định (mục 4).
  - Tỷ lệ 429 của lượt DAST trên 50 % ở một operation trong 5 lượt `stack` liên tiếp: tách lượt theo lớp rate limit hay giảm tốc độ.
  - 20 lượt `stack` liên tiếp có bước `dast` xanh: xét đưa DAST thành check bắt buộc cùng job `stack` (điều kiện của ADR-0020 §15).
  - CodeQL `default` không còn cảnh báo mở nào trong 4 tuần: thử `extended`; có cảnh báo thật đầu tiên được sửa: xét rule code scanning
    trong ruleset `main`.
  - Có bề mặt HTML mới cần quét động (web client): xét lại ZAP.
  - grype chặn một image vì lỗ hổng mà bản phát hành đang chạy cũng có, hay một CVE của Node.js công bố giữa hai lần build `web`: đưa
    grype vào lượt rescan hằng ngày và attestation `vuln` (Kyverno đọc), thay vì chỉ ở build.
  - grype đỏ vì tải DB (không phải vì lỗ hổng) quá 2 lượt `main` trong một tháng: xem lại cách cache.

## Hiện thực ở

Từ 2026-10-31 mã web ở repo `svp-web` ([ADR-0033](0033-svp-web-repo.md)): mỗi đường `web/<x>` dưới đây là `<x>` của repo đó; `gen/api.d.ts` của web từ đó sinh từ hợp đồng đã phát hành.

- `renovate.json`: rule `rangeStrategy: bump` cho directive `go` (mục 1).
- `Makefile`: `GOVULNCHECK_VERSION`, `GRYPE_IMAGE`, `SCHEMATHESIS_IMAGE` (dòng `# renovate:` ngay trên); `make tools` cài
  govulncheck; `make vulncheck` trong `check-go` trước `test`; `make fuzz` (`FUZZTIME`); `make grype`; `-include deploy/dast/dast.mk`.
- `tools/vulngate/` (`main.go`, `main_test.go`): gate đọc luồng JSON của govulncheck, `.govulncheck-ignore.json` và dòng `FROM golang`
  của Dockerfile (mục 1).
- `.govulncheck-ignore.json`: chưa có, chỉ tạo khi có ngoại lệ đầu tiên.
- `go.mod`: directive `go 1.27.3`; `deploy/docker/service.Dockerfile`, `deploy/docker/media-worker.Dockerfile`:
  `golang:1.27.3-trixie@sha256:…`.
- Fuzz (mục 2): `fuzz_test.go` ở `internal/pagetoken/`, `internal/authtoken/`, `internal/objstore/`,
  `services/gateway/internal/httpx/`, `services/user-service/internal/server/`; `TestMain` của
  `services/user-service/internal/server/server_test.go` bỏ dựng database ở chế độ fuzz; helper ký token của
  `internal/authtoken/authtoken_test.go` và `services/gateway/internal/httpx/middleware_test.go` nhận `testing.TB`. Chưa có
  `testdata/fuzz/` (fuzz chưa tìm ra lỗi).
- DAST (mục 3): `deploy/dast/dast.mk`, `deploy/dast/run.sh`, `deploy/dast/schemathesis.toml`; `.gitignore` (`.dast/`);
  `.github/workflows/ci.yml` (bước `dast`, chọn và tải artifact `dast` của job `stack`). Lỗi Schemathesis tìm ra, sửa ở
  `services/gateway/internal/httpx/json.go` (`DecodeJSON` từ chối body không phải object và `null` ở cấp đầu),
  `services/gateway/internal/api/api.go` (`page_size` có mặt mà rỗng là 400), `services/gateway/openapi.yaml`
  (`RefreshTokenRequest`), `web/gen/api.d.ts` (sinh lại).
- CodeQL (mục 4): cài đặt repo GitHub, không file nào; lệnh bật, tắt, đọc ở `docs/ci-cd.md` mục 7. Hai cảnh báo đầu tiên sửa ở
  `services/gateway/cmd/gateway/main.go` (service config gRPC dựng bằng `json.Marshal`) và `web/e2e/security.e2e.ts` (regex cờ `i`).
- grype (mục 6): `Makefile` (`GRYPE_IMAGE`, `make grype`); `deploy/ci/common.sh` (`grype_sbom`, `grype_sarif`, `trivyignore_json`,
  `grype_ignore_jq`, `sbom_binaries`, `grype_check`); `deploy/ci/build-image.sh` (bước grype sau syft, hai cổng); `deploy/ci/scan-gate.sh`
  (`--grype`); `deploy/ci/changed-services.sh` (dòng `GRYPE_IMAGE`); `deploy/ci/platform-test.sh` (ca cổng grype, `changed-services`);
  `.github/workflows/images.yml` (cache DB grype, `grype.sarif` trong artifact `sarif-*`, job `sarif` upload mỗi công cụ một lần).
- Tài liệu: `CLAUDE.md` (mục Kiểm tra), `docs/ci-cd.md`, `docs/threat-model.md` (SC-1, SC-3, SC-10, SC-13 và các dòng có target
  fuzz).

## Kết quả

Nguồn: lượt CI của PR #28 trên SHA `d58e67d` ngày 2026-10-29: `ci.yml` [40804508919](https://github.com/anhnvcoder/short-video-platform/actions/runs/40804508919),
`images.yml` [40804508815](https://github.com/anhnvcoder/short-video-platform/actions/runs/40804508815), CodeQL
[40804504269](https://github.com/anhnvcoder/short-video-platform/actions/runs/40804504269), cả ba xanh, `ci-ok` và `images-ok` đạt;
số trên máy (Mac arm64) đo ngày 2026-10-28 đến 2026-10-29 lúc hiện thực.

**govulncheck (mục 1).**

- Trước khi sửa: `make vulncheck` với directive `go 1.27` dừng ở "the go directive of go.mod must name a patch release"; với
  `go 1.27.2`: `FAIL GO-2026-6809 stdlib@v1.27.2 (fixed in v1.27.3)`, trace `internal/objstore.(*Store).Download objstore.go:275 → … →
  crypto/x509.(*Certificate).Verify`; với `go 1.27.3` mà Dockerfile còn `golang:1.27.2`: hai dòng `FAIL deploy/docker/*.Dockerfile:
  golang image is go1.27.2, govulncheck scanned go1.27.3`.
- Xử lý: directive `go 1.27.3`, hai Dockerfile `golang:1.27.3-trixie@sha256:7b072c59…` (index có amd64, arm64). trivy của hai chân thử
  (gateway, media-worker arm64) đọc `stdlib v1.27.3` trong binary. Không tạo `.govulncheck-ignore.json`.
- Job `check` (job 123220104325, 6 phút 07 s): `ok govulncheck: no called vulnerability (go1.27.3, 2 golang images match, vuln.go.dev
  modified 2026-10-27T21:16:18Z)`; mức module chỉ đếm: `INFO 3 vulnerabilities in required modules, not called: GO-2026-5932
  x/crypto@v0.58.0, GO-2026-6860, GO-2026-6866 x/net@v0.60.0` (để Renovate nâng `x/net`; `x/crypto` chưa có bản vá).
- Thời gian riêng của `make vulncheck`: chưa đo.

**Renovate (mục 1).**

- `renovate.json` có rule `rangeStrategy: bump` cho directive `go` của `gomod`, đặt cạnh nhóm "go toolchain and base images"; thêm
  sau SHA `d58e67d`, cùng PR #28. Kiểm: `make renovate-check` xanh (`renovate-config-validator --strict`). **Kiểm sau push:** PR
  Renovate thật đầu tiên đổi cùng lúc directive, image `golang` và `setup-go`, và xanh ở `check`.

**Fuzz (mục 2).** 10 target như bảng mục 2, không target nào tìm ra lỗi nên không hàm nào đổi và không commit `testdata/fuzz/`.
`make fuzz FUZZTIME=60s` (8 worker): 10 phút 34 s cả lượt; số exec trong 60 s: `FuzzDecode` 21,5 triệu, `FuzzRoundTrip` 20,2 triệu,
`FuzzVerify` 8,80 triệu, `FuzzIsMediaKey` 3,24 triệu, `FuzzEmail` 1,94 triệu, `FuzzRequireAuth` 1,88 triệu, `FuzzClientAddr` 1,74
triệu, `FuzzHandle` 1,70 triệu, `FuzzDisplayName` 0,76 triệu, `FuzzValidUTF8` 0,65 triệu. Đường lỗi kiểm bằng một target luôn đỏ
viết tạm (đã xoá): `make fuzz` dừng, in tên target và tệp input, exit khác 0. Fuzz không chạm database: với `SVP_TEST_POSTGRES_URL=invalid`
`make fuzz` cho user-service xanh, còn `go test` không `-fuzz` cùng gói đỏ ở `pgtest`.

**Schemathesis (mục 3).**

- Lỗi tìm ra ở hai lượt đầu trên máy (check `negative_data_rejection`), đã sửa: (1) `null` cho trường chuỗi được nhận như vắng
  (`POST /auth/register` `display_name: null` → 201, `POST /auth/logout` `refresh_token: null` → 204); (2) body `null` đi qua: cả hai
  giờ là 400 `INVALID_JSON`; (3) `GET /feed/explore?page_size=` → 200, giờ 400 `INVALID_PAGE_SIZE`; (4) `POST /auth/logout` `{}` →
  204 trái `required: [refresh_token]` của spec, trong khi code cố ý chuyển token thiếu tới user-service: sửa spec (bỏ `required`).
  Lỗi (1)–(3) có test đỏ trước, xanh sau.
- Trên máy sau khi sửa, ba lượt xanh: 1 022 request 220 s, 1 021 request 220 s, 1 006 request 216 s; lượt cuối (sau khi sửa vòng canh
  hạn): Schemathesis 4.32.4, 20/20 operation, 1 008 request, 216 s, 429 là 11,5 %. Phân bố status ở một lượt (1 006 test case): 200=99
  201=1 202=24 204=68 400=297 401=181 404=98 405=116 409=2 429=120; 429 nhiều nhất ở `POST /auth/register` (~45/67) và `POST /videos`
  (~46/67), tức hết burst `register` và `upload`: trên 50 % ở hai operation đó, mức của mục Xem lại khi (điều kiện tính trên 5 lượt
  `stack` liên tiếp; phân bố theo operation của lượt CI có trong `summary.json` của artifact, chưa đọc); 405 là method lạ phase
  `coverage` gửi.
- Job `stack` (job 123220104204): bước `make dast` 3 phút 40 s, cả job 19 phút 14 s trên hạn 45 phút (không nới); seed 804157956,
  exit 0, 20/20 operation, 1 007 test case, 0 lỗi, 1 007 request trong 220 s; status 200=89 201=2 202=19 204=73 400=287 401=208
  404=93 405=116 409=1 429=119 (429 là 11,8 %). Artifact `dast` (`report.json`, `summary.json`) và log bước không khớp mẫu bí mật nào;
  khoá `auth` của report chỉ có `reauth_count`, `reauth_broke`.
- Khối lượng phase `coverage` riêng: chưa đo (chỉ có tổng ~1 000 request mỗi lượt cả ba phase). Tiêu đề nhóm lỗi của `report.json`: phép dò
  bí mật trên mọi `report.json`, `summary.json` của các lượt trên máy, cả hai lượt đỏ, không khớp mẫu nào.

**CodeQL (mục 4).**

- Bật ngày 2026-10-29 bằng lệnh của mục 4 (response trả lượt [40801737073](https://github.com/anhnvcoder/short-video-platform/actions/runs/40801737073)).
  Cấu hình đọc lại: `configured`, query suite `default`, threat model `remote`, lịch `weekly`, ngôn ngữ `actions`, `go`,
  `javascript-typescript` (API liệt kê thêm `javascript`, `typescript`).
- `sha_pinning_required: true` không chặn workflow động: lượt CodeQL của PR chạy và xanh, ba job `Analyze` (`javascript-typescript`
  123220092900, `go` 123220093169, `actions` 123220093243).
- **Quyền `GITHUB_TOKEN`** (khối "GITHUB_TOKEN Permissions", giống nhau ở cả ba job của lượt 40804504269): `Actions: read`,
  `Contents: read`, `Metadata: read`, `Packages: read`, `SecurityEvents: write`. Quyền ghi duy nhất là `security-events`, nên điều
  kiện chấp nhận của mục 4 giữ, default setup giữ bật.
- Cảnh báo ban đầu: lượt đầu trên `main` để lại 2 cảnh báo CodeQL mở: #37 `go/unsafe-quoting` (service config gRPC ghép chuỗi
  bằng `Sprintf` trong `services/gateway/cmd/gateway/main.go`) và #36 `js/bad-tag-filter` (regex tìm thẻ `<script>` thiếu cờ `i` trong
  test CSP e2e). Cả hai sửa ở `d58e67d`: service config dựng từ struct Go bằng `json.Marshal` (test so cấu trúc với JSON cũ và
  gRPC nhận config), regex thêm cờ `i`. Trên PR: analysis ở `refs/pull/28/head` (`go` 0 kết quả trên 34 rule, `javascript-typescript` 0 trên 87, `actions` 0
  trên 17), check "No new alerts in code changed by this pull request"; #36, #37 vẫn mở trên `main` tới lượt CodeQL sau merge
  (**kiểm sau push**).

**grype (mục 6).**

- Bản web `web@sha256:bc355bf1…` amd64 trên máy: package `node@26.12.0` là binary ngoài trình quản lý gói duy nhất; 130 gói,
  Critical 0, High 13, Medium 10, Low 3, Negligible 7. Ca âm SBOM log4j-core 2.14.1: hai Critical (`GHSA-jfh8-c2jp-5v3q` /
  CVE-2021-44228, `GHSA-7rjr-3q55-vv33` / CVE-2021-45046), exit khác 0.
- `images.yml` 40804508815: 14 chân (7 image × amd64, arm64) đều qua cổng grype, không mục ngoại lệ nào được dùng; Critical/High/
  Medium/Low/Negligible/Unknown mỗi chân, giống nhau ở hai kiến trúc: gateway, engagement-service, feed-service, video-service
  0/0/0/0/0/2; user-service 0/0/0/0/0/3; media-worker 0/61/81/9/0/4; web 0/13/10/3/7/0 (`node@26.12.0`; chân Go: không binary nào
  ngoài trình quản lý gói).
- Thời gian thêm mỗi chân: trên máy 5 s (gateway arm64), 7 s (web arm64) khi DB đã cache, lần tải DB đầu 2 phút 13 s (archive 196 MB,
  3,1 GB trên đĩa); trên CI 2–8 s mỗi chân, cả 14 chân dùng cache `grype-db-2026-10-29`.
- SARIF grype lên tab Security: lượt PR không có artifact SARIF (job `sarif` chỉ chạy ở `main`): **kiểm sau push**. Final review của
  thay đổi tìm ra job `sarif` ban đầu đưa cả hai công cụ cho một `upload-sarif`: lượt `main` [40733866890](https://github.com/anhnvcoder/short-video-platform/actions/runs/40733866890)
  (chỉ trivy) ghi "Combining SARIF files" cho 14 file, nên lượt `main` đầu tiên build cả bảy image với grype (28 run) sẽ bị từ chối.
  Sửa thành mỗi công cụ một upload (mục 6). Kiểm trên máy bằng file SARIF giả và chính script của bước: 7 image (14 trivy, 14 grype)
  → hai upload 14 run; rescan 14 file → chỉ upload trivy; 21 run một công cụ → `::error::21 trivy SARIF runs in 21 files: GitHub
  rejects an upload with more than 20 runs`, exit 1, công cụ kia vẫn upload; file lạ → dừng. Lượt `images.yml` trên `main` sau merge
  (hai upload xanh, category `grype-image-…` có trên tab Security): **kiểm sau push**.

**Lệch so với quyết định.**

- Mục 3, hạn 10 phút: vòng canh nằm trong chính `run.sh` (mỗi giây) thay vì một tiến trình canh riêng; hạn tính từ lúc `docker run`
  bắt đầu, gồm cả pull image; quá hạn thì `docker stop`, giết client docker và xoá container client kịp tạo. Kiểm: hạn 2 s khi image
  chưa có, hạn 20 s giữa lượt, SIGINT và SIGTERM lúc pull: không container `svp-dast-*` nào còn lại.
- Mục 3, cấu hình thêm: plugin coverage của image tắt (`SCHEMATHESIS_COVERAGE=false`), cache của Schemathesis tắt và thư mục làm việc
  là `/tmp` của container (cache ghi dữ liệu request vào thư mục làm việc).
- Mục 2, tham số: `FuzzClientAddr` lấy số header `X-Forwarded-For` từ `(hops/3)%3`; `FuzzDisplayName` so cả kết quả (`empty`, `ok`)
  với oracle dựng từ quy tắc, chặt hơn các phép kéo theo một chiều của bảng.

## Nguồn

Đọc ngày 2026-10-28.

- [N1] govulncheck v1.9.0, tài liệu lệnh (exit 0 khi không có lỗ hổng, luôn 0 với `-format json`/`sarif`/`openvex`; `-mode binary`
  không có call stack; `-db`; mặc định gọi `https://vuln.go.dev`; Go version của quét mã nguồn lấy từ lệnh `go`; "There is no support
  for silencing vulnerability findings", go.dev/issue/61211; giới hạn với `reflect`, interface): <https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck>
- [N2] Mã nguồn `golang.org/x/vuln` v1.9.0: `internal/govulncheck/govulncheck.go` (`Message`: `config`, `progress`, `SBOM`, `osv`,
  `finding`; `ProtocolVersion` `v1.0.0`; `Finding.FixedVersion` rỗng khi chưa có bản vá; frame của mức module và package; thư viện chuẩn
  là module `stdlib`), `internal/scan/errors.go` (`errVulnerabilitiesFound` exit 3), `internal/scan/text.go` (exit 3 khi finding đúng
  mức quét), `internal/scan/run.go` (`go env GOVERSION`, biến `GOVERSION` ghi đè):
  <https://go.googlesource.com/vuln/+/refs/tags/v1.9.0/internal/govulncheck/govulncheck.go>,
  <https://go.googlesource.com/vuln/+/refs/tags/v1.9.0/internal/scan/run.go>
- [N3] Go module proxy, `golang.org/x/vuln/@latest`: `v1.9.0`, `2026-10-11T03:39:53Z`: <https://proxy.golang.org/golang.org/x/vuln/@latest>
- [N4] GO-2026-6809 (`crypto/x509`, `Certificate.Verify`; trước go1.26.10, go1.27.0 tới trước go1.27.3; công bố 2026-10-21):
  <https://pkg.go.dev/vuln/GO-2026-6809>
- [N5] GO-2026-6866 (`golang.org/x/net/html` `Render`), GO-2026-6860 (`Parse`, `ParseFragment`, …), trước v0.62.0, công bố 2026-10-27:
  <https://pkg.go.dev/vuln/GO-2026-6866>, <https://pkg.go.dev/vuln/GO-2026-6860>
- [N6] GO-2026-5932 (`golang.org/x/crypto/openpgp…`, mọi phiên bản, không có bản vá): <https://pkg.go.dev/vuln/GO-2026-5932>
- [N7] Go, "Go Toolchains" (directive `go` là phiên bản tối thiểu, có thể có số patch; toolchain từ chối module có `go` cao hơn nó;
  `GOTOOLCHAIN=local` luôn chạy toolchain đi kèm; `auto` tải toolchain như module, kiểm qua checksum database): <https://go.dev/doc/toolchain>
- [N8] docker-library/golang, Dockerfile 1.27 trixie (`ENV GOLANG_VERSION 1.27.3`, `ENV GOTOOLCHAIN=local`):
  <https://github.com/docker-library/golang/blob/master/1.27/trixie/Dockerfile>
- [N9] Renovate, manager `gomod` (directive `go`: "Renovate's default behavior is not to propose upgrades to it", bật bằng
  packageRule khớp manager `gomod`, dep `go`, depType `golang` với `rangeStrategy: bump`; directive `toolchain` (depType `toolchain`)
  được đề xuất mặc định): <https://docs.renovatebot.com/modules/manager/gomod/>
- [N10] golangci-lint v2.14.0, `pkg/goutil/version.go` (`CheckGoVersion` so `version.Lang` của Go build ra nó với phiên bản đích đã cắt
  số patch): <https://github.com/golangci/golangci-lint/blob/v2.14.0/pkg/goutil/version.go>
- [N11] Go, "Go Fuzzing" (seed chạy mặc định với `go test`; `-fuzz` khớp một fuzz test; corpus ở `$GOCACHE/fuzz`; input lỗi ghi vào
  `testdata/fuzz/`; kiểu tham số; AMD64 và ARM64; nhanh, tất định, không trạng thái toàn cục; hạn 1 s; OSS-Fuzz): <https://go.dev/doc/security/fuzz/>
- [N12] Schemathesis, releases (4.32.3 ngày 21/10, 4.32.4 ngày 22/10, 4.32.5 ngày 25/10, 4.32.6 và 4.32.7 ngày 27/10; ghi chú phát
  hành của 4.32.5 "`st run` requests hanging indefinitely when `--request-timeout` is not set", 4.32.6 hiệu năng và phase coverage,
  4.32.7 "Compatibility with pytest 9.2"): <https://github.com/schemathesis/schemathesis/releases>
- [N13] Docker Hub API, tag của `schemathesis/schemathesis` (`4.32.4`: `sha256:b501f25d00fa6e2b393ddd1b525a11bb560d593fd06268491595c2e439090bf0`,
  `tag_last_pushed` 2026-10-22T17:55:49Z; `4.32.5`: `tag_last_pushed` 2026-10-25T23:05:00Z; cả hai có amd64 và arm64):
  <https://hub.docker.com/v2/repositories/schemathesis/schemathesis/tags/4.32.4>,
  <https://hub.docker.com/v2/repositories/schemathesis/schemathesis/tags/4.32.5>
- [N14] Schemathesis, CLI reference (`--config-file` là tuỳ chọn chung trước lệnh; `--checks`, `--phases`, `--max-examples` chỉ tác dụng ở
  fuzzing và stateful, `--rate-limit` gồm `auto`, `--exclude-path`, `--workers`, `--seed`, `--generation-database`, `--report`
  `junit`/`har`/`vcr`/`ndjson`/`json`/…, report `json` là "a single JSON document with the run's verdict", `--output-truncate` cắt
  ngắn chứ không bỏ response, `--output-sanitize`; exit 0, 1, 2, 130): <https://schemathesis.readthedocs.io/en/stable/reference/cli/>
- [N15] Schemathesis, configuration reference (`${VAR}` là cách thay biến duy nhất, biến chưa đặt là lỗi; `[auth.openapi.<scheme>]`
  với `bearer`; `expected-statuses` của check; làm sạch output, "Response bodies are written verbatim"; `max-examples` mặc định 100):
  <https://schemathesis.readthedocs.io/en/stable/reference/configuration/>
- [N16] Schemathesis, checks reference (mỗi check kiểm gì, status mặc định; `negative_data_rejection` mặc định 400, 401, 403, 422, 5xx;
  `ignored_auth` không kết luận khi có header `Authorization` không khai; `use_after_free`, `ensure_resource_availability` cần stateful
  và links; `object_level_authorization` cần hai danh tính): <https://schemathesis.readthedocs.io/en/stable/reference/checks/>
- [N17] Go, `net/http.ServeMux` ("GET matches both GET and HEAD requests"): <https://pkg.go.dev/net/http#ServeMux>
- [N18] GitHub REST, "Update a code scanning default setup configuration" và "Get a code scanning default setup configuration"
  (`state`, `query_suite`, `threat_model`, `languages`, `runner_type`; `schedule` `weekly`):
  <https://docs.github.com/en/rest/code-scanning/code-scanning#update-a-code-scanning-default-setup-configuration>
- [N19] GitHub, "Configuring default setup for code scanning" (điều kiện: Actions bật, repo public hay có Code Security; "Default setup
  uses the `none` build mode for C/C++, C#, Java and Rust" và `autobuild` cho ngôn ngữ biên dịch khác; không chọn được build mode):
  <https://docs.github.com/en/code-security/code-scanning/enabling-code-scanning/configuring-default-setup-for-code-scanning>
- [N20] GitHub, "Code scanning setup types" (push lên nhánh mặc định hay bảo vệ; PR vào các nhánh đó "excluding pull requests from
  forks"; hằng tuần nếu 180 ngày có push hay PR): <https://docs.github.com/en/code-security/concepts/code-scanning/setup-types>
- [N21] GitHub, "CodeQL query suites" (`security-extended` là `default` cộng query độ chính xác, mức nghiêm trọng thấp hơn):
  <https://docs.github.com/en/code-security/concepts/code-scanning/codeql/codeql-query-suites>
- [N22] GitHub, "SARIF uploads are blocked when CodeQL default setup is enabled" ("only … SARIF files that contain results created
  using CodeQL"): <https://docs.github.com/en/code-security/reference/code-scanning/sarif-files/troubleshoot-sarif-uploads/default-setup-enabled>
- [N23] GitHub CodeQL Terms and Conditions (phân tích Open Source Codebase; tạo database cho CI/CD chỉ khi codebase được host trên
  GitHub.com; ngoại lệ khi có license GitHub Advanced Security trả phí): <https://github.com/github/codeql-cli-binaries/blob/main/LICENSE.md>
- [N24] Opengrep, README (fork của Semgrep v1.100.0, LGPL 2.1, lý do tách) và releases (1.31.0, 1.32.0, 1.33.0):
  <https://github.com/opengrep/opengrep>, <https://github.com/opengrep/opengrep/releases>
- [N25] Semgrep, Licensing (engine CE LGPL 2.1; rule theo Semgrep Rules License v1.0, "available only for internal business use"):
  <https://docs.semgrep.dev/licensing>
- [N26] ZAP, "API Scan" (nhập OpenAPI, active scan "tuned to APIs", đăng nhập bằng context và `-U`; trang mang tên "ZAP by Checkmarx"):
  <https://www.zaproxy.org/docs/docker/api-scan/>
- [N27] GitLab, "Static Application Security Testing (SAST)" (Free, Premium, Ultimate; báo cáo JSON ở mọi bậc; finding trong MR và
  vulnerability management chỉ Ultimate; Go dùng analyzer Semgrep): <https://docs.gitlab.com/user/application_security/sast/>
- [N28] GitLab, "GitLab Advanced SAST" (Ultimate; taint qua hàm và tệp; có Go): <https://docs.gitlab.com/user/application_security/sast/gitlab_advanced_sast/>
- [N29] GitLab, "Coverage-guided fuzz testing" (Ultimate; deprecated ở 18.0, dự kiến bỏ ở 19.0; Go qua go-fuzz):
  <https://docs.gitlab.com/user/application_security/coverage_fuzzing/>
- [N30] GitLab, "API security testing analyzer" (Ultimate; OpenAPI v2/v3; đổi tên từ DAST API ở 17.0):
  <https://docs.gitlab.com/user/application_security/api_security_testing/>
- [N31] golang-jwt v5.3.1, `parser.go` (`DecodeSegment` dùng `base64.RawURLEncoding`, chỉ strict khi bật `WithStrictDecoding`):
  <https://github.com/golang-jwt/jwt/blob/v5.3.1/parser.go>
- [N32] Mã nguồn Schemathesis v4.32.4: `src/schemathesis/cli/json_report.py` (`build_document`: version, `command`, `seed`, số
  operation và test case, phase, `failures` chỉ `type`, `code`, `title`, `severity`, `count`, `operations`, `errors` chỉ `title`,
  `count`; không body, không curl), `src/schemathesis/core/failures.py` (`format_failures`: thêm payload của response và khối
  "Reproduce with" curl vào văn bản lỗi), `src/schemathesis/reporting/junitxml.py` (văn bản lỗi của JUnit là `group.format(…,
  curl=group.code_sample, …)`), `src/schemathesis/cli/options.py` (`--report-json-path`, `--report-junit-path`, `--report-har-path`),
  `src/schemathesis/config/_report.py` (định dạng `json`, tên mặc định `<định dạng>-<thời điểm>`):
  <https://github.com/schemathesis/schemathesis/blob/v4.32.4/src/schemathesis/cli/json_report.py>,
  <https://github.com/schemathesis/schemathesis/blob/v4.32.4/src/schemathesis/core/failures.py>,
  <https://github.com/schemathesis/schemathesis/blob/v4.32.4/src/schemathesis/reporting/junitxml.py>
- [N33] GitHub, "Build options for compiled languages", autodetection for Go ("Invoke `make`, `ninja`, `./build` or `./build.sh` (in that
  order) until one of these commands succeeds and a subsequent `go list ./...` also succeeds", rồi `go get` theo `go.mod`, rồi trích
  xuất "similar to running `go build ./...`"; "CodeQL supports build modes `autobuild` or `manual` for Go code"):
  <https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages#autodetection-for-go>
- [N34] Mã nguồn CodeQL, `go/extractor/autobuilder/autobuilder.go` trên `main` (`BuildScripts`: `make` cho `Makefile`, `makefile`,
  `GNUmakefile`; `ninja` cho `build.ninja`; `./build`; `./build.sh`; `Autobuild()` chạy từng lệnh không đối số, trả về ở lệnh đầu tiên
  thành công): <https://github.com/github/codeql/blob/main/go/extractor/autobuilder/autobuilder.go>
- [N35] GitHub, "CodeQL code scanning for compiled languages" (`none` chỉ ở C/C++, C#, Java, Rust; `manual`: "CodeQL will analyze
  whatever source code is built by your specified build steps", ví dụ `build-mode: manual` với bước `run` build cố định):
  <https://docs.github.com/en/code-security/code-scanning/creating-an-advanced-setup-for-code-scanning/codeql-code-scanning-for-compiled-languages>
- [N36] GitHub, "Uploading a SARIF file to GitHub" (workflow mẫu: `security-events: write` "required for all workflows"):
  <https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github>
- [N37] GitHub, "Workflow syntax", mục `permissions` (lượt `pull_request` từ fork: "the permissions are adjusted to change any write
  permissions to read only"): <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions>
- [N38] GitHub, "Permission levels for a personal account repository" (collaborator "push (write) changes to the repository", tạo và
  merge PR; chủ repo có toàn quyền):
  <https://docs.github.com/en/account-and-profile/setting-up-and-managing-your-personal-account-on-github/managing-personal-account-settings/permission-levels-for-a-personal-account-repository>

- [N39] grype v0.121.0, README (quét image, thư mục, SBOM; `grype sbom:<file>`; giấy phép Apache-2.0):
  <https://github.com/anchore/grype/blob/v0.121.0/README.md>
- [N40] grype, releases (v0.120.0 2026-10-02, v0.120.1 2026-10-06, v0.121.0 2026-10-19): <https://github.com/anchore/grype/releases>
- [N41] grype v0.121.0, cấu hình mặc định in bằng `grype config` (`db.require-update-check: false`, `db.validate-age: true`,
  `db.max-allowed-built-age: 120h`, `db.max-update-check-frequency: 2h`, `match.stock.using-cpes: true`, `ignore: []`) và tài liệu cấu
  hình: <https://oss.anchore.com/docs/reference/grype/configuration/>
- [N42] GitLab, "Deprecations and removals by version", mục "Grype scanner for container scanning" ("deprecated in GitLab 16.9. From
  GitLab 17.0, the Grype analyzer will no longer be maintained"; image còn cập nhật "until GitLab 19.0, at which point the analyzer will
  stop working"; muốn dùng tiếp thì tự tích hợp theo "Security scanner integration"): <https://docs.gitlab.com/update/deprecations/>
- [N43] GitHub, "SARIF support for code scanning", bảng giới hạn ("Runs per file | 20"; "If any of these objects exceeds its maximum
  value the SARIF file is rejected"; đọc ngày 2026-10-29):
  <https://docs.github.com/en/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning>
- [N44] `github/codeql-action` ở SHA ghim `6f2ac81f` (v4.39.0): `src/upload-lib.ts` (nhiều file mà không phải mọi run do CodeQL tạo thì
  "Merging files in the action" bằng `combineSarifFiles`) và `src/sarif/index.ts` (`combineSarifFiles` nối `runs` của mọi file vào một log;
  đọc ngày 2026-10-29): <https://github.com/github/codeql-action/blob/6f2ac81f5cd81fe351a197ba0b00d91d03cd2aee/src/upload-lib.ts>

Chưa kiểm được ở ngày viết: `sha_pinning_required` có áp cho workflow do default setup dựng hay không (mục 4, kiểm khi bật); quyền đầy
đủ của `GITHUB_TOKEN` trong workflow CodeQL do GitHub quản (mục 4, đọc đầu log lượt đầu; có quyền ngoài `security-events` thì tắt); khối lượng
request của phase `coverage` theo spec này (đo khi hiện thực); tiêu đề nhóm lỗi (`title`) của report `json` có khi nào mang dữ liệu của
response hay không (đọc mã thấy tiêu đề của check; phép dò trước khi in và tải là lớp chặn nếu có).
