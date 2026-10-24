# Merge vào `main` mà GitHub không chạy workflow của push

- Không có cảnh báo: dấu hiệu là PR đã merge mà không có lượt `images.yml` (và `ci.yml`) của push, không có PR promote mới.
- Mọi lệnh ghi lên GitHub (dispatch, mở PR, merge) do **người học chạy**.

## Ý nghĩa và tác động tới người dùng

Sự cố đã gặp ngày 2026-10-21 (roadmap, giai đoạn 5): PR #4 merge lúc 14:39:24Z thành `94c3dbe`; GitHub đang có sự cố Webhooks
(githubstatus "Partially Degraded") và không chạy workflow push nào cho commit đó. Sau ~40 phút đã dispatch
`images.yml -f services=feed-service` để phát hành: PR promote #5 mở sau 3,5 phút và được merge (`983f761`). Nhưng lượt dispatch
không đẩy base của phép so "service nào đổi", nên lượt push của `983f761` so từ lượt push thành công cuối (`bea9954`) và build
lại feed-service cùng code: thêm một PR promote thừa (#6, digest mới, cùng code).

Người dùng: không thấy gì. Bản mới chưa được build, quét, ký, chưa tới cluster GitOps; cluster tiếp tục chạy bản cũ.

## Kiểm tra nhanh (5 phút)

```sh
# lượt push gần nhất của images.yml và ci.yml trên main, so với commit vừa merge
git fetch origin main && git log -3 --format='%h %cI %s' origin/main
gh run list --workflow images.yml --branch main --event push --limit 5
gh run list --workflow ci.yml --branch main --event push --limit 5
# GitHub có sự cố không
curl -s https://www.githubstatus.com/api/v2/status.json | jq -r '.status.description'
# lượt push thành công cuối của images.yml (base của phép so)
gh run list --workflow images.yml --branch main --event push --status success --limit 1 --json headSha --jq '.[0].headSha'
# service nào sẽ được build ở lượt push kế (thay <base> bằng SHA trên)
deploy/ci/changed-services.sh <base> origin/main
```

Đọc kết quả: commit merge mới nhất không có lượt push nào (không phải lượt đỏ, mà không có) → đúng sự cố này. Có lượt mà đỏ →
đọc log của lượt đó, không phải runbook này.

## Nguyên nhân thường gặp

1. **Sự cố của GitHub** (Webhooks, Actions): githubstatus không "All Systems Operational".
2. **Workflow bị tắt** (`gh workflow list --all` thấy `disabled_manually` hay `disabled_inactivity`).
3. **Commit không đổi file nào kích hoạt build**: lượt push có chạy nhưng `changed-services` báo "nothing to build"; đây không
   phải sự cố.

## Giảm thiểu

Không có tác động tới người dùng; không cần làm gấp. Cách được khuyên (roadmap, "Ghi nhận" giai đoạn 5):

1. **Không dispatch** `services=` để phát hành bù: lượt dispatch phát hành được nhưng không đẩy base, nên lượt push kế build
   lại cùng service đó, thêm một PR promote thừa.
2. Đợi GitHub hồi (githubstatus "All Systems Operational").
3. Merge một PR bất kỳ vào `main` (kể cả commit rỗng), qua ruleset như mọi thay đổi (người học chạy). Khối dưới chạy trong
   subshell `( … )`: mỗi bước lỗi thì dừng (`|| exit 1` chỉ thoát subshell, không đóng terminal). Commit chỉ rỗng khi index
   rỗng: file đang stage sẽ đi vào commit, nên khối kiểm index trước khi commit và kiểm commit không đổi file nào trước khi push.

```sh
(
  branch=chore/retrigger-push-$(date -u +%y%m%d%H%M)
  git fetch origin main || exit 1
  git diff --cached --quiet || { echo 'index đang có file stage: bỏ stage hay commit chúng trước' >&2; exit 1; }
  git switch -c "$branch" origin/main || exit 1
  git diff --cached --quiet || { echo 'index có file stage sau khi switch: dừng' >&2; exit 1; }
  msg=$(mktemp) || exit 1
  printf 'chore: chạy lại workflow push sau sự cố GitHub\n' >"$msg" || exit 1
  git commit --allow-empty -F "$msg"; rc=$?; rm -f "$msg"; [ "$rc" = 0 ] || exit 1
  # commit không mang file nào: tree của nó trùng tree của origin/main
  [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse 'origin/main^{tree}')" ] || { echo 'commit không rỗng: dừng, chưa push' >&2; exit 1; }
  git log -1 --format='%h %s' || exit 1
  git push -u origin "$branch" || exit 1
  gh pr create --fill || exit 1
)
# chờ ci-ok, images-ok xanh, rồi merge PR trên GitHub
```

Lượt push của merge đó so từ lượt push thành công cuối, nên build bù đúng các service bị lỡ, một lần.

Workflow bị tắt: `gh workflow enable images.yml` (người học chạy).

## Khôi phục và xác nhận

```sh
gh run list --workflow images.yml --branch main --event push --limit 3      # lượt push của merge mới xanh
gh pr list --head bot/promote                                               # PR promote cuộn có digest của service bị lỡ
```

Merge PR promote; trên cluster GitOps Argo CD sync bản mới (`make measure-gitops REV=<commit merge>` đo push → pod Ready).

## Leo thang

- Đã lỡ dispatch: PR promote thừa có cùng code, digest khác; merge hay đóng đều không đổi hành vi. Người học quyết, ghi lại.
- GitHub sự cố kéo dài hơn một ngày khi cần phát hành gấp: dispatch `services=<tên>` vẫn phát hành được (chấp nhận một PR promote
  thừa sau đó); ghi vào postmortem.
- Attestation của bản đang chạy sắp quá 72 giờ vì lịch rescan cũng không chạy: [vuln-attestation-expired.md](vuln-attestation-expired.md).

## Liên kết

- ADR: [ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §3 (chỉ build service đổi, base của phép so), §9 (PR promote cuộn), §11
  (ruleset `main`).
- Diễn tập tái hiện: không có (sự cố của nền tảng GitHub).
