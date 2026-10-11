# Chặng G — nền tảng Go

> Ngày lập: 2026-10-04
>
> Trạng thái: hoãn từ 2026-10-11 khi đang ở tuần 1 (người học tập trung DevOps + SA trước; AI viết code Go của project)

Chặng học Go song song với giai đoạn 0, theo bảng 4 tuần ở mục G của
[lộ trình](../261004-devops-sa-roadmap/plan.md). Người học tự viết code; AI giao bài, giải thích (so với TypeScript) và review.

## Cách làm

- **Code bài tập ở `~/Dev/anhnv/learning/go/`**, ngoài repo này: bài tập không phải code của hệ thống. Một module `learngo`,
  mỗi chương hoặc bài một thư mục con. Nên `git init` ở đó để review được theo diff (không cần push).
- **Nộp bài:** nhắn "review <tên bài>". AI chạy `gofmt -l .`, `go vet ./...`, `go test ./...` trong thư mục bài, đọc code,
  review theo [chế độ mentor](../../CLAUDE.md#chế-độ-mentor), rồi ghi tóm tắt vào mục Nhật ký review bên dưới.
- Vị trí code của hai lab tuần 3–4 (`rate-limiter`, `cache-stampede`) chốt khi tới tuần 3.

## Tiến độ

| Tuần | Nội dung | Trạng thái |
| --- | --- | --- |
| 1 | Cú pháp, kiểu, struct, slice/map, con trỏ, zero value, lỗi là giá trị | Đang làm (giao 2026-10-04, bắt đầu 2026-10-05) |
| 2 | Package/module, interface ngầm định, table-driven test, `gofmt`, `golangci-lint`; API CRUD `net/http` + `pgx` | Chưa |
| 3 | Goroutine, channel, `sync`, `context`, `-race`; lab `rate-limiter` | Chưa |
| 4 | gRPC + protobuf, `log/slog`, graceful shutdown, Dockerfile multi-stage; lab `cache-stampede` | Chưa |

## Tuần 1

### Chuẩn bị

```sh
mkdir -p ~/Dev/anhnv/learning/go && cd ~/Dev/anhnv/learning/go
go mod init learngo
git init
```

- Lệnh hay dùng, chạy từ gốc module: `go test ./...` (mọi package), `go test ./ladder/ -v -run TestPlan` (một test),
  `go vet ./...`, `gofmt -l .` (liệt kê file chưa format; `go fmt ./...` để sửa).

**Editor: Neovim (LazyVim + extra `lang.go`), học song song với Go.** Kiểm tra ngày 2026-10-05: Mason đã có `gopls`, `goimports`,
`gofumpt`, `golangci-lint`, `delve`; format khi lưu bằng `goimports` + `gofumpt` (kết quả vẫn qua `gofmt -l`).

- Config đã được review và sửa ngày 2026-10-05 (bỏ plugin trùng với LazyVim, sửa phím lỗi, bật extra go, json, markdown,
  yaml, docker, sql, helm, terraform; gỡ AI trong nvim). Phím tắt và nguyên tắc ở `~/dotfiles/docs/Neovim/`
  (`Shortcuts.md`, `Learning.md`; bản chép trong Obsidian ở `Dotfiles/Neovim/`).
- Từ đây **đóng băng config 2 tuần.** Vướng gì thì ghi lại, cuối tuần sửa một lần, tối đa 1 giờ.
- **Chạy test trong terminal, chưa dùng neotest:** `<C-/>` (terminal có sẵn của LazyVim, mở ở thư mục gốc) hoặc một pane WezTerm.
  Cần thuộc tay các cờ `-run`, `-v`, `-race`, `-count=1` vì CI dùng đúng chúng.
- **Phím LSP cần nhớ:** `gd` (hoặc `<C-]>` gốc của vim, quay lại bằng `<C-t>`) tới định nghĩa (vào được tận mã nguồn thư viện chuẩn, khác TypeScript chỉ ra file `.d.ts`), `<C-o>` /
  `<C-i>` quay lại / đi tới, `K` xem tài liệu, `gr` chỗ dùng, `gI` implementation (chính ở tuần 2), `<leader>cr` đổi tên,
  `<leader>ca` code action, `]d` lỗi kế tiếp, `gl` xem lỗi của dòng.
- **Mỗi tuần một kỹ năng vim.** Tuần 1: text object `vaf` (chọn cả hàm), `cif` (viết lại thân hàm), `ci"`, `ci(`.
- **Điều kiện dừng:** thấy mình nghĩ về phím nhiều hơn nghĩ về Go thì phần còn lại của tuần làm bài bằng VS Code.

### Đọc

1. **[A Tour of Go](https://go.dev/tour/)**: cả phần *Basics* (Packages, variables, and functions; Flow control; More types)
   và phần *Methods and interfaces* tới hết trang *Errors*. Bỏ qua Generics và Concurrency (để tuần 3).
2. **[Go Slices: usage and internals](https://go.dev/blog/slices-intro)**: vì sao luôn phải viết `s = append(s, v)`.
3. **[Working with Errors in Go 1.13](https://go.dev/blog/go1.13-errors)**: bọc lỗi bằng `%w`, kiểm tra bằng `errors.Is` / `errors.As`.
4. **[Go by Example](https://gobyexample.com/)**: không đọc hết, dùng để tra khi làm bài.

### Bài tập

**1. [Learn Go with Tests](https://quii.gitbook.io/learn-go-with-tests)**, 7 chương đầu của phần Go fundamentals: Hello, World;
Integers; Iteration; Arrays and slices; Structs, methods & interfaces; Pointers & errors; Maps.

- Mỗi chương một thư mục `lgwt/<chương>/` trong module `learngo` (sách bảo `go mod init` mỗi chương; ở đây không cần).
- Viết test trước như sách, kể cả khi thấy thừa: tuần 2 dùng lại nhịp này.

**2. `ladder/`: chọn các bản HLS cần transcode cho một video.** Đây là quyết định `media-worker` sẽ làm ở giai đoạn 2.

```go
type Source struct {
	Width, Height int
	Duration      time.Duration
}

type Rendition struct {
	Name        string // "360p"
	ShortSide   int    // 360
	BitrateKbps int    // 800
}

func Plan(src Source) ([]Rendition, error)
func EstimatedBytes(r Rendition, d time.Duration) int64
```

Luật:

- Ladder cố định, theo thứ tự: `360p` (360, 800 kbps), `720p` (720, 2 500 kbps), `1080p` (1080, 5 000 kbps).
- Độ phân giải tính theo **cạnh ngắn**: video dọc 1080×1920 là 1080p.
- Không upscale: chỉ lấy bản có cạnh ngắn ≤ cạnh ngắn của source.
- Cạnh ngắn < 360 → trả lỗi bọc `ErrResolutionTooLow`. `Duration` ≤ 0 hoặc > 3 phút → trả lỗi bọc `ErrInvalidDuration`.
  Message lỗi có ngữ cảnh (kích thước, thời lượng của source), nhưng phía gọi vẫn nhận ra bằng `errors.Is`.
- `EstimatedBytes` = bitrate × thời lượng / 8, làm tròn xuống. Ví dụ 720p trong 60 giây = 18 750 000 byte.

Test tối thiểu phải phủ: 1920×1080 → 3 bản; 1080×1920 → 3 bản; 1280×720 → 2 bản; 640×360 → 1 bản; 320×240 → lỗi;
thời lượng 0, đúng 3 phút, 3 phút 1 giây.

**3. `viewcount/`: bộ đếm lượt xem trong bộ nhớ.** Tiền thân của `engagement-service` và lab `hot-counter`.

```go
type VideoCount struct {
	VideoID string
	Count   int
}

func NewCounter() *Counter
func (c *Counter) Record(videoID string)
func (c *Counter) Count(videoID string) int
func (c *Counter) Top(n int) []VideoCount
```

Luật:

- `Count` của video chưa có lượt xem nào trả 0.
- `Top` xếp giảm dần theo `Count`, bằng nhau thì `VideoID` tăng dần; `n` lớn hơn số video thì trả hết; `n` ≤ 0 thì trả rỗng.
  Tra package `slices` (hàm `SortFunc`) và `cmp`.
- Chưa cần an toàn khi nhiều goroutine cùng gọi; tuần 3 quay lại bài này với `-race`.

Ba thí nghiệm, ghi kết luận thành comment trong file test hoặc kể lúc nộp bài:

1. Bỏ dòng khởi tạo map trong `NewCounter`: test nào vỡ, vỡ kiểu gì? Có nên làm cho `var c Counter` (zero value) dùng được luôn không?
2. `json.Marshal` kết quả của `Top(0)` khi hàm trả `nil` và khi trả `[]VideoCount{}`: ra gì? Client TypeScript gọi `.length`
   trên kết quả đó thì sao?
3. Đổi receiver của `Record` từ `*Counter` sang `Counter`: còn đúng không, vì sao? Sau đó thêm field `total int` đếm tổng lượt
   xem, cũng với receiver `Counter`: giờ thì sao?

### Từ TypeScript sang Go (phạm vi tuần 1)

| Khái niệm | TypeScript | Go | Chỗ hay vấp |
| --- | --- | --- | --- |
| Khai báo | `let x = 1` | `x := 1` hoặc `var x int` | `var` không gán thì nhận **zero value** (`0`, `""`, `false`, `nil`), không có `undefined` |
| Số | `number` | `int`, `int64`, `float64`... | Không tự đổi kiểu: phải viết `float64(n)`, `int64(x)` |
| Chuỗi | `"Việt".length` = 4 | `len("Việt")` = 6 | `len` đếm byte UTF-8; đếm ký tự dùng `utf8.RuneCountInString` hoặc `for range` |
| Kiểu dữ liệu | `interface`/`type` mô tả object | `struct` | Gán hay truyền struct là **copy**; muốn sửa bản gốc thì dùng con trỏ `*T` |
| Class, method | `class C { m() {} }` | `func (c *C) M() {}` | Không có class, constructor, kế thừa; constructor là hàm thường `NewC()` theo quy ước |
| Mảng | `T[]`, `arr.push(v)` | `[]T`, `s = append(s, v)` | Quên gán lại kết quả `append` là mất phần tử |
| Map | `Map<K, V>` / `Record` | `map[K]V` | Key không có trả zero value; cần biết có hay không: `v, ok := m[k]`. Ghi vào map `nil` thì **panic** |
| Lỗi | `throw` / `try...catch` | trả `error` làm giá trị cuối | Kiểm tra ngay: `if err != nil { return fmt.Errorf("plan: %w", err) }`; `errors.Is` thay cho `instanceof` |
| Lỗi nghiêm trọng | `throw` | `panic` | Chỉ cho lỗi lập trình (bug), không dùng cho luồng nghiệp vụ |
| Public/private | `export` | Chữ hoa đầu tên | `Plan` dùng được từ package khác, `plan` thì không |
| Vòng lặp | `for`, `while`, `forEach` | chỉ có `for` | `for cond {}` là while; `for i, v := range s {}` là forEach |
| So sánh | `===` | `==` | Struct so sánh được bằng `==` nếu mọi field so sánh được; slice và map thì không |
| Tham số | optional, default, overload | không có | Thường thay bằng struct option hoặc nhiều hàm khác tên |

### Tự kiểm tra cuối tuần

Trả lời được mà không mở tài liệu thì xong tuần 1:

1. `var s []int; s = append(s, 1)` chạy không? `var m map[string]int; m["a"] = 1` thì sao?
2. Khi nào method dùng receiver `*T`, khi nào dùng `T`?
3. Hàm nhận một struct (không phải con trỏ) rồi sửa field của nó: bản gốc có đổi không? Nếu field đó là slice thì sao?
4. `errors.Is(err, ErrX)` khác `err == ErrX` ở chỗ nào?
5. Vì sao Go trả lỗi bằng giá trị thay vì throw? Điều đó thay đổi cách đọc code ra sao?

## Nhật ký review

### 2026-10-05: `lgwt/hello` (đang làm dở, nộp sớm)

- **Kiểm tra:** `gofmt -l`, `go vet` sạch; `go test` báo `[no tests to run]`; `go run ./lgwt/hello` lỗi
  `no non-test Go files`.
- **Lỗi chính:** chương trình (`package main`, `func main`) nằm trong `hello_test.go`. File `_test.go` chỉ được biên dịch khi
  `go test`, nên `go run` không thấy code nào; còn `go test` không thấy hàm `TestXxx` nào. Đổi tên thành `hello.go`.
- **Lỗi của hướng dẫn:** buổi trước AI bảo tạo `hello_test.go` và viết test trước, lệch với thứ tự của sách (sách bắt đầu
  bằng `hello.go` rồi mới tách hàm `Hello` và viết test). Từ giờ đi đúng thứ tự của sách.
- **Bước kế:** tách `Hello()` trả về chuỗi ra khỏi `main`, viết `TestHello` trong `hello_test.go`; commit sau mỗi chương.
- **Học tiếp:** `go help testfunc` (hàm test phải có dạng nào để `go test` nhận ra).
- **Lần 2:** đã đổi tên thành `hello.go`, `go run` in đúng, `gofmt`/`vet` sạch; chưa có test. Giao phần còn lại của chương
  theo 4 mốc của sách, thêm một ngôn ngữ ngoài sách: tiếng Việt `Xin chào, `.
