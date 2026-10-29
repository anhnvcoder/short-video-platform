# Dựng và kiểm cài đặt GitHub của `svp-gitops` (App promote, environment `promote`, ruleset)

- Quy trình làm tay, không có cảnh báo. Mở khi dựng `svp-gitops` lần đầu, khi dựng lại sau khi gỡ App, khi xoay khoá App, khi nghi
  khoá hay token của App bị lộ, hay khi một lượt promote đỏ ở bước lấy token.
- Mọi thao tác ghi (UI Settings, tạo App, đặt secret, nhập ruleset) do **người học chạy** với quyền admin. Mọi lệnh "Kiểm" ở đây
  chỉ `GET`, chạy bằng đăng nhập `gh` của người học (token scope `repo` là đủ).
- Thiết kế và lý do ở [ADR-0025](../adr/0025-gitops-config-repo.md) (§5 check, §6 App, §7 ruleset và CODEOWNERS, §9 trình tự chuyển);
  trang này chỉ nói làm gì, vì sao từng ô, kiểm thế nào.
- **Không ghi giá trị nào** (Client ID, khoá `.pem`, token) vào repo, issue, PR hay chat: hai repo đều public.

## Ý nghĩa và tác động tới người dùng

Ba vai, và Argo CD chỉ đọc:

```mermaid
flowchart LR
  subgraph code["repo code: anhnvcoder/short-video-platform"]
    ci["images.yml: build, quét, ký"] --> promote["job promote<br/>environment promote (chỉ main)<br/>variable Client ID + secret khoá .pem"]
  end
  app["GitHub App svp-gitops-promoter<br/>token 1 giờ, chỉ svp-gitops,<br/>chỉ quyền đã cấp"]
  subgraph gitops["repo anhnvcoder/svp-gitops"]
    pr["PR của bot<br/>bot/promote-stg"] --> rules["ruleset main + owners<br/>CODEOWNERS<br/>check gitops-ok"] --> main["main<br/>(auto-merge stg; prd cần duyệt)"]
  end
  promote -- "khoá ký JWT, đổi lấy token" --> app
  app -- "token: đẩy nhánh, mở PR, bật auto-merge" --> pr
  argo["Argo CD"] -- "HTTPS ẩn danh, chỉ đọc refs/heads/main" --> main
  argo -- "chart ở commit ghim" --> code
```

**Vì sao phải có App** (ADR-0025 §6):

- `GITHUB_TOKEN` của một workflow chỉ ghi được repo của chính workflow đó: job `promote` ở repo code không đẩy được nhánh lên
  `svp-gitops` bằng nó. Thêm nữa, PR mở bằng `GITHUB_TOKEN` không sinh lượt `pull_request`, nên check `gitops-ok` không chạy và
  auto-merge không bao giờ xảy ra.
- PAT (personal access token) là khoá dài hạn đứng tên một người, quyền theo người đó (mọi repo người đó ghi được); lộ thì kẻ lấy
  được làm mọi thứ người học làm được, tới khi ai đó nhận ra.
- App: khoá dài hạn chỉ dùng để xin **installation token hạn 1 giờ**, token chỉ tới repo App được cài (`svp-gitops`), chỉ quyền đã
  cấp, job còn thu hẹp thêm theo từng bước; PR và commit đứng tên `svp-gitops-promoter[bot]`, không phải người học, nên người học
  duyệt được PR của bot (tác giả không tự duyệt PR của mình).

Cài sai thì người dùng của nền tảng không thấy gì ngay (cluster đang chạy giữ bản cũ), nhưng: promote stg đỏ hay PR không tự merge
(bản phát hành mới không tới stg); hay ngược lại, một ô để mở làm cổng triển khai yếu đi mà không ai biết (bot tự duyệt, force push
vào `main`, PR fork chạy workflow không ai duyệt). Vì vậy mỗi bước dưới có lệnh kiểm.

## Kiểm tra nhanh (5 phút)

Toàn bộ phần kiểm được bằng API, một lượt (chỉ `GET`). Mỗi lệnh in một dòng (`-q` in JSON gọn, khoá theo thứ tự chữ cái; không có
`-q` thì `gh api` không xuống dòng sau body và output của các lệnh dính vào nhau). Kết quả mong đợi ở cột phải của bảng dưới; dòng
nào khác là sai, xem mục của bước đó ở "Khôi phục và xác nhận".

```sh
G=repos/anhnvcoder/svp-gitops
C=repos/anhnvcoder/short-video-platform
# 1. Cài đặt repo svp-gitops
gh api $G -q '{default_branch, allow_auto_merge, allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge}'
gh api $G/actions/permissions -q '{enabled, allowed_actions, sha_pinning_required}'
gh api $G/actions/permissions/selected-actions -q .
gh api $G/actions/permissions/workflow -q .
gh api $G/actions/permissions/fork-pr-contributor-approval -q .
gh api $G -q '.security_and_analysis | {secret_scanning: .secret_scanning.status, push_protection: .secret_scanning_push_protection.status}'
gh api -i $G/vulnerability-alerts | head -1
# 4. Environment promote của repo code (chỉ tên biến, secret; không API nào trả giá trị secret)
gh api $C/environments/promote -q '{name, deployment_branch_policy, rules: [.protection_rules[].type]}'
gh api $C/environments/promote/deployment-branch-policies -q '.branch_policies[] | {name, type}'
gh api $C/environments/promote/variables -q '{total_count, names: [.variables[].name]}'
gh api $C/environments/promote/secrets -q '{total_count, names: [.secrets[].name]}'
# B. Ruleset (sau khi nhập)
gh api $G/rulesets -q '.[] | {id, name, target, enforcement}'
gh api $G/rules/branches/main -q '.[] | .type'
gh api "$G/tags?per_page=100" -q '.[].name'
```

| Lệnh | Mong đợi |
| --- | --- |
| cài đặt repo | `"allow_auto_merge":true`, `"allow_squash_merge":true`, `"allow_merge_commit":false`, `"allow_rebase_merge":false`, `"delete_branch_on_merge":false`; `"default_branch":"main"` sau push đầu (repo rỗng báo `master`, chưa có nghĩa gì) |
| `actions/permissions` | `{"allowed_actions":"selected","enabled":true,"sha_pinning_required":true}` |
| `selected-actions` | `{"github_owned_allowed":true,"patterns_allowed":[],"verified_allowed":false}` |
| `actions/permissions/workflow` | `{"can_approve_pull_request_reviews":false,"default_workflow_permissions":"read"}` |
| `fork-pr-contributor-approval` | `{"approval_policy":"all_external_contributors"}` (như repo code) |
| `security_and_analysis` | `{"push_protection":"enabled","secret_scanning":"enabled"}` |
| `vulnerability-alerts` | `HTTP/2.0 204 No Content` (Dependabot alerts bật; `404` là tắt) |
| environment | `{"deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false},"name":"promote","rules":["branch_policy"]}` |
| branch policies | đúng một dòng `{"name":"main","type":"branch"}` |
| variables | `{"names":["SVP_GITOPS_APP_CLIENT_ID"],"total_count":1}` |
| secrets | `{"names":["SVP_GITOPS_APP_PRIVATE_KEY"],"total_count":1}` |
| rulesets | ba dòng, `main` và `owners` (`"target":"branch"`), `tags` (`"target":"tag"`), cả ba `"enforcement":"active"` |
| `rules/branches/main` | `deletion`, `non_fast_forward`, `pull_request` (hai lần: một của mỗi ruleset nhắm nhánh), `required_status_checks` |
| `tags` | không dòng nào (repo không dùng tag; tag lạ xem "Giảm thiểu") |

Không kiểm được bằng `gh` của người học: **App và bản cài của nó** (bước A2, A3) và **Renovate** (A5). `GET /apps/svp-gitops-promoter`
trả 404 (App chỉ cho tài khoản này, token người dùng không thấy), `GET repos/anhnvcoder/svp-gitops/installation` cần JWT ký bằng khoá
App (401 `A JSON web token could not be decoded`), `GET user/installations` cần token người dùng do chính một App cấp (403); đã thử
2026-10-29. Kiểm bằng UI ở mục của từng bước, và bằng lượt promote đầu tiên (phần C).

## Nguyên nhân thường gặp

Theo thứ tự hay gặp, mỗi cái kèm dấu hiệu trong kết quả của "Kiểm tra nhanh":

1. **Client ID đặt ở secret thay vì variable** (đã gặp 2026-10-29): `variables` rỗng, `secrets` có hai tên. Workflow đọc
   `vars.SVP_GITOPS_APP_CLIENT_ID`, biến không có thì là chuỗi rỗng: bước tạo token của job `promote` đỏ ngay vì thiếu client id.
   Sửa ở bước A4.
2. **Duyệt workflow PR fork chỉ cho người mới** (`first_time_contributors`, mặc định của GitHub) thay vì mọi người ngoài: không lỗi
   nào hiện ra, chỉ lệnh kiểm thấy. Sửa ở bước A1.
3. **Khoá `.pem` dán thiếu dòng** (thiếu `-----BEGIN …-----` hay `-----END …-----`, hay dán nội dung file khác): bước tạo token đỏ
   với lỗi đọc khoá hay ký JWT. Đặt lại secret từ file (bước A4).
4. **App cài "All repositories"** hay thêm repo khác: không lỗi nào, token xin được cho repo thừa. Chỉ UI thấy (bước A3).
5. **Ruleset nhập trước khi workflow có trên `main`**: push thẳng `main` bị từ chối, nên commit thêm `check.yml` phải đi qua PR. PR
   đó tự chạy `check.yml` của chính nó (trigger `pull_request`) và báo `gitops-ok`; PR nào không chứa workflow (nhánh tách từ `main`
   trước khi có nó) thì chờ `gitops-ok` mãi. Xem phần B.
6. **Nhánh mặc định không phải `main`**: ruleset nhắm `~DEFAULT_BRANCH`, nên bảo vệ nhầm nhánh. Xem phần B.

## Giảm thiểu

**Nghi khoá App hay token của App bị lộ** (khoá lọt vào log, commit, máy bị xâm nhập), làm theo thứ tự:

1. **Suspend bản cài** (cắt ngay mọi token đang còn hạn, không cần chờ 1 giờ): https://github.com/settings/installations →
   `svp-gitops-promoter` → **Configure** → cuối trang (Danger zone) **Suspend**. Từ lúc này mọi job `promote` đỏ ở bước gọi API;
   không có gì tới stg, cluster giữ bản đang chạy.
2. **Xoá khoá bị lộ, tạo khoá mới** theo "Xoay khoá App" bên dưới, bước 1, 2 và 4 (xoá khoá cũ ngay). Chưa kiểm bằng lượt promote
   (bước 3 của mục đó): bản cài còn suspend nên bước tạo token đỏ dù khoá mới đúng, trông như khoá mới hỏng.
3. **Xem bot đã làm gì** trong thời gian nghi lộ (chỉ đọc):

   ```sh
   gh pr list --repo anhnvcoder/svp-gitops --author 'app/svp-gitops-promoter' --state all --limit 20 \
     --json number,title,state,createdAt,mergedAt
   gh api repos/anhnvcoder/svp-gitops/branches -q '.[].name'
   gh api 'repos/anhnvcoder/svp-gitops/tags?per_page=100' -q '.[] | {name, sha: .commit.sha}'
   gh api 'repos/anhnvcoder/svp-gitops/releases?per_page=20' -q '.[] | {id, tag_name, created_at, author: .author.login}'
   gh api 'repos/anhnvcoder/svp-gitops/deployments?per_page=20' -q '.[] | {id, environment, ref, created_at, creator: .creator.login}'
   ```

   Token App không bỏ được ruleset trên `main`: mọi thay đổi vào `main` vẫn qua PR có `gitops-ok` (chặn digest không ký bởi
   `images.yml` của `main`), file ngoài `envs/stg/` vẫn cần người học duyệt. Nhưng ruleset `main`, `owners` chỉ nhắm nhánh
   (`"target": "branch"`), còn quyền Contents write của App đẩy được **tag** và tạo **release**. Chỉ ruleset `tags` (phần B: không ai
   ngoài vai admin tạo, sửa, xoá tag) chặn việc đó, và chỉ từ lúc nó được nhập và `active`. Repo không dùng tag hay release nào, nên
   mọi dòng của hai lệnh `tags`, `releases` là lạ.

   Tag nguy hiểm nhất là tag trùng tên nhánh Argo CD theo dõi (`main`). Với `targetRevision` tên ngắn, Argo CD lấy ref **đầu tiên**
   có tên ngắn trùng, nhánh hay tag như nhau, trong danh sách ref không có thứ tự cố định (hàm `lsRemote` của
   [`util/git/client.go`](https://github.com/argoproj/argo-cd/blob/v3.5.5/util/git/client.go), bản Argo CD của chart ghim; danh sách
   đọc từ map của go-git). Nên với `targetRevision: main`, tag `main` của kẻ có token có thể được sync lên stg: commit chưa qua
   `gitops-ok` lẫn Code Owner. Vì vậy Argo CD đọc `svp-gitops` bằng tên đầy đủ `refs/heads/main` (root `svp-root` và nguồn `$values`
   của mọi Application), tên không bao giờ khớp tag. Có cluster GitOps chạy trong thời gian nghi lộ thì kiểm cả hai: mọi nguồn
   `svp-gitops` đọc tên đầy đủ, và mọi revision `svp-gitops` Argo CD đã sync là commit của `main` (lịch sử giữ 10 lượt sync gần nhất
   mỗi Application, mặc định của Argo CD):

   ```sh
   # targetRevision của mọi nguồn svp-gitops: refs/heads/main
   kubectl --context k3d-svp -n argocd get applications.argoproj.io -o json | jq -r '.items[] | .metadata.name as $a
     | (.spec.sources // [.spec.source])[] | select((.repoURL // "") | test("svp-gitops")) | [$a, .targetRevision] | @tsv'
   # lịch sử sync: Application, thời điểm, SHA svp-gitops đã đọc
   kubectl --context k3d-svp -n argocd get applications.argoproj.io -o json | jq -r '.items[] | .metadata.name as $a
     | .status.history[]? | .deployedAt as $t
     | (if .sources then [.sources, .revisions] | transpose[] else [.source, .revision] end)
     | select((.[0].repoURL // "") | test("svp-gitops")) | [$a, $t, .[1]] | @tsv'
   # mỗi SHA khác nhau ở trên: identical hay ahead là commit của main
   gh api repos/anhnvcoder/svp-gitops/compare/<SHA>...main -q .status
   ```

   SHA cho `behind`, `diverged` hay 404 là Argo CD đã sync code lạ lên stg: xử lý như sự cố (mục Leo thang). Nguồn nào còn tên ngắn
   thì sửa thành tên đầy đủ bằng PR trước bước 4.

   Người học dọn (lệnh ghi):

   - PR lạ: đóng. Nhánh lạ: xoá.
   - Release lạ: `gh release delete <tag> --repo anhnvcoder/svp-gitops --cleanup-tag` (xoá cả tag của nó). Tag lạ còn lại:
     `gh api -X DELETE repos/anhnvcoder/svp-gitops/git/refs/tags/<tag>`. Ruleset `tags` chưa có hay không `active` thì nhập hay bật
     nó ngay (phần B).
   - Bản ghi Deployment lạ: token lộ ghi được bản ghi giả có URL lượt `verify.yml` thật, tức khớp đúng thứ check của PR prd đòi
     (ADR-0025 §6); khớp bản ghi chỉ chặn nhầm lẫn, chặn kẻ tấn công là duyệt của Code Owner trên PR prd. Đừng chỉ ghi lại id: đặt
     bản ghi về `inactive` rồi xoá, để không PR prd nào khớp được nó
     (GitHub chỉ cho xoá Deployment `inactive` khi repo có hơn một Deployment,
     [REST deployments](https://docs.github.com/en/rest/deployments/deployments)):

     ```sh
     gh api -X POST repos/anhnvcoder/svp-gitops/deployments/<id>/statuses -f state=inactive
     gh api -X DELETE repos/anhnvcoder/svp-gitops/deployments/<id>
     ```

     Không phân biệt được bản ghi thật với bản giả trong thời gian nghi lộ thì làm vậy với mọi bản ghi `stg` tạo trong thời gian đó;
     lượt `gitops` kế của `verify.yml` trên `main` ghi lại bản ghi thật bằng khoá mới.
4. **Unsuspend** (cùng trang, **Unsuspend**) khi secret đã là khoá mới, khoá cũ đã xoá và bước 3 đã dọn xong. Rồi mới kiểm khoá mới
   bằng bước 3 của "Xoay khoá App".

**Gỡ hẳn** (không dùng App nữa, hay dựng lại từ đầu): cùng trang → **Uninstall**, rồi trang App
https://github.com/settings/apps/svp-gitops-promoter → **Advanced** → **Delete GitHub App**; xoá secret và variable của environment
`promote` (Settings → Environments → `promote`). Dựng lại theo bước A2–A4.

## Khôi phục và xác nhận

Dựng từ đầu theo đúng thứ tự phụ thuộc của ADR-0025 §9: phần **A** trước khi commit khởi tạo lên `svp-gitops` (A1 phải xong trước
khi commit thứ hai, có `.github/workflows/`, được push); phần **B** sau commit thứ hai và lượt đầu xanh của workflow trên `main`;
phần **C** sau khi repo code chuyển job `promote` sang `svp-gitops`.

### A1. Cài đặt repo `svp-gitops`

**Làm gì** (https://github.com/anhnvcoder/svp-gitops/settings):

- **General** → mục **Pull Requests**: bật **Allow squash merging**, tắt **Allow merge commits** và **Allow rebase merging**; bật
  **Allow auto-merge**; **không** bật **Automatically delete head branches**.
- **Actions** → **General**:
  - **Actions permissions**: chọn **Allow anhnvcoder, and select non-anhnvcoder, actions and reusable workflows**, chỉ tích
    **Allow actions created by GitHub** (không tích Marketplace verified creators, ô danh sách action để trống); tích **Require
    actions to be pinned to a full-length commit SHA**. **Save**.
  - **Approval for running fork pull request workflows from contributors**: **Require approval for all external contributors**.
    **Save**.
  - **Workflow permissions**: **Read repository contents and packages permissions**; **bỏ tích** **Allow GitHub Actions to create
    and approve pull requests**. **Save**.
- **Advanced Security**: bật **Dependabot alerts**; **Secret Protection** (secret scanning) và **Push protection** bật (repo public
  thường đã bật sẵn, kiểm lại).

**Vì sao:**

- Chỉ squash: mỗi lần promote là đúng một commit trên `main`; rollback một lần promote là revert một commit, lịch sử Argo CD đọc
  được theo từng bản.
- Auto-merge: PR promote stg của bot tự merge khi `gitops-ok` xanh, không ai phải bấm (ADR-0025 §7).
- Không tự xoá nhánh: `bot/promote-stg` là nhánh cuộn, job `promote` tự dựng lại và đẩy nó bằng `--force-with-lease`; GitHub xoá
  nhánh sau merge là thêm một bên thứ hai đổi nhánh đó giữa hai lượt promote.
- Chỉ action của GitHub, ghim SHA bắt buộc: tag của action có thể bị đẩy sang code khác (vụ `tj-actions/changed-files` 3/2025,
  `aquasecurity/trivy-action` 3/2026, [ADR-0015](../adr/0015-cicd-devsecops-stage5.md)); SHA thì không. Ô "bắt buộc" làm workflow
  dùng tag bị từ chối ngay, không cần ai đọc diff mới bắt được.
- Duyệt PR fork của mọi người ngoài: repo public, PR fork chạy `check.yml` với cây của fork (token chỉ đọc, không secret), nhưng
  vẫn là code lạ chạy trên runner; người học xem PR trước khi cho chạy.
- Token mặc định chỉ đọc, tắt "create and approve pull requests": ô này chỉ quyết `GITHUB_TOKEN` của workflow có mở và duyệt PR được
  không, mà không workflow nào của `svp-gitops` cần ghi hay mở PR (ADR-0025 §7); quyền không ai dùng thì tắt. Bot promote không dính
  ô này: nó mở PR bằng token của App `svp-gitops-promoter[bot]`, không phải `GITHUB_TOKEN`. Để mở cũng không làm cổng Code Owner thành
  hình thức: duyệt của `github-actions[bot]` không có trong `CODEOWNERS` nên không đáp ứng `require_code_owner_review`.
- Secret scanning + push protection: repo không được chứa secret nào; push protection chặn ngay lúc push nếu ai lỡ commit khoá
  (ví dụ file `.pem` của bước A2). Dependabot alerts: ở repo này gần như không báo gì. Dependency graph chỉ thấy action của
  `check.yml`, ghi SHA làm version, mà GitHub chỉ cảnh báo action dùng version semver, không cảnh báo action ghim SHA
  ([About Dependabot alerts](https://docs.github.com/en/code-security/dependabot/dependabot-alerts/about-dependabot-alerts),
  mục Limitations); action được giữ mới bằng PR nâng SHA của Renovate (A5), không bằng cảnh báo. Vẫn bật, như repo code
  ([ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §10, §11): `vulnerabilityAlerts` của `renovate.json` (PR vá lỗ hổng mở ngay,
  ngoài lịch, không chờ `minimumReleaseAge`) đọc chính các cảnh báo này nên cần Dependabot alerts bật (mô tả của khoá đó trong
  `renovate.json` ghi rõ); tắt cảnh báo vì thấy vô dụng là tắt luôn đường đó của Renovate mà không có lỗi nào báo. Thêm nữa, bật không
  tốn gì và phủ ngay một hệ sinh thái mà dependency graph đọc được nếu sau này repo có.

**Kiểm:** bảy lệnh đầu của "Kiểm tra nhanh" (cài đặt repo tới `vulnerability-alerts`), output như bảng.

**Nếu sai:** `allow_auto_merge` false → PR stg mở nhưng không tự merge (job `promote` đỏ ở bước bật auto-merge). `allow_merge_commit`
true → người merge tay có thể tạo merge commit, revert một lần promote khó hơn. `sha_pinning_required` false hay `verified_allowed`
true → workflow dùng tag hay action bên thứ ba vẫn chạy. `can_approve_pull_request_reviews` true → tắt lại ở Workflow permissions.
`approval_policy` khác `all_external_contributors` → chọn lại ô duyệt PR fork. Sửa ở đúng ô rồi chạy lại lệnh kiểm.

### A2. Tạo GitHub App `svp-gitops-promoter`

**Làm gì** (https://github.com/settings/apps/new; hay Settings → Developer settings → GitHub Apps → **New GitHub App**):

- **GitHub App name**: `svp-gitops-promoter`. **Homepage URL**: `https://github.com/anhnvcoder/short-video-platform`.
- **Callback URL** để trống, không tích **Request user authorization (OAuth) during installation**.
- **Webhook**: **bỏ tích Active**.
- **Permissions** → **Repository permissions**: **Contents** Read and write, **Pull requests** Read and write, **Deployments** Read
  and write; **Metadata** Read-only (tự có, bắt buộc). Mọi quyền khác No access, đặc biệt **Workflows**, **Actions**,
  **Administration**, **Checks**, **Commit statuses**. Không quyền nào ở **Organization permissions**, **Account permissions**.
- **Where can this GitHub App be installed?**: **Only on this account**. **Create GitHub App**.
- Trên trang App vừa tạo: đọc **Client ID** (mục About, dạng `Iv…`, để dán ở A4); mục **Private keys** → **Generate a private key**:
  trình duyệt tải một file `.pem`, để ở thư mục tạm ngoài mọi repo. Không bấm **Generate a new client secret**: App không dùng OAuth.

**Vì sao:**

- Contents write: đẩy nhánh `bot/promote-stg`/`bot/promote-prd`, merge PR (auto-merge). Pull requests write: mở, sửa PR, bật
  auto-merge. Deployments write: ghi bản ghi triển khai `stg` sau khi phép kiểm trên stg qua; PR prd đòi khớp bản ghi đó.
- Không Workflows: GitHub từ chối mọi push đổi file trong `.github/workflows/` của token không có quyền này, nên bot không sửa được
  chính check đang chặn nó. Không Administration: bot không đổi được ruleset, cài đặt repo.
- Webhook tắt: App không cần nhận sự kiện nào (job tự gọi API); bật thì phải có URL và secret, GitHub gửi payload sự kiện của repo
  tới URL đó.
- Only on this account: không ai khác cài được App này. Client ID là định danh, không phải bí mật; khoá `.pem` là bí mật duy nhất.

**Kiểm** (UI, API không đọc được, xem "Kiểm tra nhanh"): https://github.com/settings/apps/svp-gitops-promoter → **Permissions &
events**: đúng bốn quyền repository trên, không quyền organization/account, không sự kiện nào được tích; trang **General**: Webhook
không Active, **Private keys** có đúng một khoá (ngày tạo hôm nay); tab **Advanced** còn nút **Make public** (tức App vẫn chỉ cài
được trên tài khoản này).

**Nếu sai:** thiếu Deployments → bước ghi bản ghi stg của `verify.yml` báo 403 `Resource not accessible by integration`; thiếu
Contents/Pull requests → job `promote` đỏ khi push hay mở PR với cùng message. Thừa quyền → bỏ ở Permissions & events: GitHub yêu cầu
bản cài chấp nhận khi **thêm** quyền, bớt quyền thì có hiệu lực ngay.

### A3. Cài App chỉ lên `svp-gitops`

**Làm gì:** trang App → **Install App** → dòng `anhnvcoder` → **Install** → **Only select repositories** → chọn
`anhnvcoder/svp-gitops` → **Install**.

**Vì sao:** token của App chỉ tới repo đã cài. Cài cả repo code thì token bị lộ đẩy được nhánh, mở PR ở chính repo build image.

**Kiểm** (UI): https://github.com/settings/installations → `svp-gitops-promoter` → **Configure**: **Repository access** là "Only
select repositories" với đúng một dòng `anhnvcoder/svp-gitops`; phần quyền liệt kê đúng bốn quyền của A2.

**Nếu sai:** chọn lại repo ở cùng trang, **Save**. "All repositories" thì đổi sang "Only select repositories".

### A4. Environment `promote` ở repo code

**Làm gì** (https://github.com/anhnvcoder/short-video-platform/settings/environments → **New environment**):

- **Name**: `promote` → **Configure environment**.
- **Deployment protection rules**: không tích **Required reviewers**, không **Wait timer** (stg tự động; cổng prd là Code Owner của PR
  prd ở `svp-gitops`).
- **Deployment branches and tags**: **Selected branches and tags** → **Add deployment branch or tag rule** → Ref type **Branch**, Name
  pattern `main` → **Add rule**.
- **Environment variables** → **Add environment variable**: Name `SVP_GITOPS_APP_CLIENT_ID`, Value là Client ID của A2.
- **Environment secrets** → **Add environment secret**: Name `SVP_GITOPS_APP_PRIVATE_KEY`, Value là **toàn bộ** nội dung file `.pem`
  (cả dòng `-----BEGIN RSA PRIVATE KEY-----` và `-----END …-----`). Hay từ terminal, không qua clipboard:

  ```sh
  gh secret set SVP_GITOPS_APP_PRIVATE_KEY --env promote --repo anhnvcoder/short-video-platform < /đường/tới/khoá.pem
  ```

  Rồi xoá file `.pem` (khoá mới tạo lại được bất cứ lúc nào ở trang App; không cần giữ bản sao).

**Vì sao:**

- Secret của environment chỉ tới job khai `environment: promote`, và chỉ khi job chạy trên nhánh khớp luật. Luật chỉ `main`: một
  nhánh hay PR có workflow sửa thêm `environment: promote` bị GitHub từ chối trước khi job chạy, không lấy được khoá.
- Client ID là **variable**: không bí mật (vô dụng khi không có khoá), đọc lại được để kiểm; workflow đọc `vars.SVP_GITOPS_APP_CLIENT_ID`.
  Khoá `.pem` là **secret**: GitHub không trả lại giá trị qua API hay UI, che trong log.

**Kiểm:** bốn lệnh "Environment promote" của "Kiểm tra nhanh"; `variables` đúng một tên `SVP_GITOPS_APP_CLIENT_ID`, `secrets` đúng
một tên `SVP_GITOPS_APP_PRIVATE_KEY`. Thời điểm đặt khoá (không có giá trị):

```sh
gh api repos/anhnvcoder/short-video-platform/environments/promote/secrets/SVP_GITOPS_APP_PRIVATE_KEY -q '{name, updated_at}'
```

**Nếu sai:**

- Client ID nằm ở secret (`variables` rỗng, `secrets` có hai tên): `vars.SVP_GITOPS_APP_CLIENT_ID` rỗng, bước tạo token của job
  `promote` báo thiếu client id. Sửa: **Add environment variable** cùng tên với Client ID (đọc lại ở trang App), rồi ở **Environment
  secrets** xoá `SVP_GITOPS_APP_CLIENT_ID` (biểu tượng thùng rác). Chạy lại hai lệnh `variables`, `secrets`.
- `deployment_branch_policy` là `null` (No restriction) hay `protected_branches: true`: sửa lại ô Deployment branches như trên.
- Khoá sai (bước tạo token báo lỗi đọc khoá, hay 401 khi đổi JWT lấy token): tạo khoá mới và đặt lại theo "Xoay khoá App".

### A5. Renovate cho `svp-gitops`

**Làm gì:** https://github.com/apps/renovate → **Configure** → `anhnvcoder` → **Only select repositories** → thêm
`anhnvcoder/svp-gitops` (giữ `short-video-platform`) → **Save**.

**Vì sao:** `svp-gitops/renovate.json` đề xuất nâng chart upstream, image ghim digest, action của `check.yml` và commit checker
(`CHECKER_COMMIT` của `check.yml`); không có thì các ghim đó cũ dần (ADR-0025 §10). Mọi PR của Renovate đổi file có Code Owner, nên
người học duyệt từng cái.

**Kiểm** (UI): https://github.com/settings/installations → **Renovate** → **Configure**: danh sách repo có `svp-gitops`. Sau commit
khởi tạo (đã có `renovate.json`, nên không có PR onboarding), vài giờ sau có issue **Dependency Dashboard**:

```sh
gh issue list --repo anhnvcoder/svp-gitops --state all --search 'Dependency Dashboard in:title' --json number,title,author
```

**Nếu sai:** không có issue sau một ngày → xem log của repo ở https://developer.mend.io (đăng nhập GitHub) → `anhnvcoder/svp-gitops`.

### B. Ruleset (sau commit thứ hai và lượt đầu xanh của `check.yml` trên `main`)

Thứ tự này có lý do: ruleset `main` cấm push thẳng `main` và đòi check `gitops-ok`. Nhập trước khi workflow có trên `main` thì commit
thứ hai (thêm workflow) không push thẳng được nữa, phải qua PR. PR đó vẫn qua được: `check.yml` chạy trên `pull_request` bằng bản
workflow của chính PR nên báo `gitops-ok`; chỉ PR không chứa workflow mới chờ `gitops-ok` mãi. Nhập sau lượt xanh trên `main` thì
commit thứ hai push thẳng như commit đầu, và check đã chạy được trên `main` trước khi thành bắt buộc.

**Trước khi nhập**, nhánh mặc định phải là `main` (ruleset nhắm `~DEFAULT_BRANCH`) và lượt cuối của `check.yml` trên `main` xanh:

```sh
gh api repos/anhnvcoder/svp-gitops -q .default_branch                      # main
gh run list --repo anhnvcoder/svp-gitops --workflow check.yml --branch main --limit 1 \
  --json conclusion,headSha,url                                            # "conclusion":"success"
```

Khác `main` → Settings → General → **Default branch** → đổi sang `main`.

**Làm gì** (người học chạy, từ gốc một bản clone của `svp-gitops`, hay từ thư mục tạm `gitops/` của repo code khi còn):

```sh
gh api -X POST repos/anhnvcoder/svp-gitops/rulesets --input .github/rulesets/main.json
gh api -X POST repos/anhnvcoder/svp-gitops/rulesets --input .github/rulesets/owners.json
gh api -X POST repos/anhnvcoder/svp-gitops/rulesets --input .github/rulesets/tags.json
```

(UI tương đương: Settings → **Rules** → **Rulesets** → **New ruleset** → **Import a ruleset**, chọn từng file.) Ba file trong
`.github/rulesets/` chỉ là bản để nhập, nằm trong repo thì không có hiệu lực gì.

**Từng luật và vì sao** (`main`, `owners`: ADR-0025 §7; hai ruleset cùng nhắm nhánh mặc định nên rule cộng dồn, bản chặt nhất thắng;
`tags` nhắm tag, không cộng với hai cái kia):

| Ruleset | Luật | Vì sao |
| --- | --- | --- |
| `main` | `deletion` | Không ai (kể cả token App, kể cả admin) xoá được `main`, tức xoá nguồn Argo CD đọc |
| `main` | `non_fast_forward` | Cấm force push: lịch sử triển khai không viết lại được, revert là cách lùi duy nhất |
| `main` | `pull_request`, 0 approval | Mọi thay đổi qua PR (để check chạy); 0 approval để PR stg của bot tự merge; `dismiss_stale_reviews_on_push`: push mới sau khi duyệt thì mất duyệt |
| `main` | `required_status_checks` `gitops-ok`, `integration_id` 15368 | Check tổng phải xanh; chỉ nhận từ app GitHub Actions (như `ci-ok`, `images-ok` của repo code), status giả do token khác đặt không tính |
| `main` | `bypass_actors: []` | Không ai bỏ qua, cả admin |
| `owners` | `pull_request`, `require_code_owner_review` | PR đổi file có chủ trong `CODEOWNERS` (mọi thứ trừ `envs/stg/`, và `envs/stg/svp-policy.yaml` vẫn có chủ) phải được Code Owner duyệt: PR prd, Renovate, PR sửa `.github/` |
| `owners` | bypass vai admin (`actor_id` 5, `RepositoryRole`), `bypass_mode: pull_request` | Người học không tự duyệt được PR của mình, nên merge PR của mình bằng bypass, chỉ qua PR (có bản ghi bypass); check của `main` vẫn bắt buộc vì ruleset `main` không có bypass |
| `tags` | `creation`, `update`, `deletion` trên mọi tag (`~ALL`) | Repo không dùng tag. Contents write của App đẩy được tag mà hai ruleset nhánh không thấy; tag trùng tên nhánh (`main`) có thể được Argo CD lấy thay nhánh khi đọc bằng tên ngắn (xem "Giảm thiểu"), nên token lộ không được tạo, dời hay xoá tag nào |
| `tags` | bypass chỉ vai admin (`actor_id` 5, `RepositoryRole`) | App, Renovate, workflow không chạm được tag; chỉ người học |

**Kiểm:**

```sh
gh api repos/anhnvcoder/svp-gitops/rulesets -q '.[] | {id, name, target, enforcement}'
# ba dòng: main, owners ("target":"branch"), tags ("target":"tag"), "enforcement":"active"
gh api repos/anhnvcoder/svp-gitops/rules/branches/main -q '.[] | .type'
# deletion, non_fast_forward, pull_request, pull_request, required_status_checks
id=$(gh api repos/anhnvcoder/svp-gitops/rulesets -q '.[] | select(.name=="owners") | .id')
gh api repos/anhnvcoder/svp-gitops/rulesets/$id -q '{bypass_actors, current_user_can_bypass}'
# [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}], "pull_requests_only"
id=$(gh api repos/anhnvcoder/svp-gitops/rulesets -q '.[] | select(.name=="tags") | .id')
gh api repos/anhnvcoder/svp-gitops/rulesets/$id \
  -q '{target, include: .conditions.ref_name.include, rules: ([.rules[].type] | sort), bypass: [.bypass_actors[] | {actor_id, actor_type}]}'
# {"bypass":[{"actor_id":5,"actor_type":"RepositoryRole"}],"include":["~ALL"],"rules":["creation","deletion","update"],"target":"tag"}
gh api 'repos/anhnvcoder/svp-gitops/tags?per_page=100' -q '.[].name'
# không dòng nào
```

UI: Settings → Rules → Rulesets → `owners` → **Bypass list** có "Repository admin", "For pull requests only".

**Nếu sai:** `actor_id` 5 không phải vai admin (bypass list trống hay ghi vai khác) → sửa bypass list ở UI (**Add bypass** →
Repository admin → For pull requests only). Ruleset `disabled`/`evaluate` → mở ruleset → **Enforcement status** → Active. Nhập
trùng (hai ruleset cùng tên) → xoá bản thừa ở UI. Thiếu `tags` → nhập `tags.json` như trên. Lệnh `tags` có dòng nào → tag lạ (repo không dùng
tag): xử lý như "Giảm thiểu" bước 3.

### C. Sau khi job `promote` của repo code chuyển sang `svp-gitops`

Không bước tay nào mới; người học duyệt PR prd và PR của Renovate do bot mở. Lượt promote đầu tiên là phép kiểm của A2–A4 mà API
không làm được:

```sh
# lượt images.yml trên main có job promote xanh
gh run list --repo anhnvcoder/short-video-platform --workflow images.yml --branch main --limit 1 --json conclusion,url
# PR của bot: tác giả app/svp-gitops-promoter, chỉ đổi envs/stg/, đã tự merge
gh pr list --repo anhnvcoder/svp-gitops --author 'app/svp-gitops-promoter' --state all --limit 1 --json number,state,mergedAt
gh pr view <số PR> --repo anhnvcoder/svp-gitops --json files -q '.files[].path'      # chỉ envs/stg/images/…, envs/stg/charts.yaml
# job promote chỉ chạy được trên main (bản ghi environment của repo code)
gh api 'repos/anhnvcoder/short-video-platform/deployments?environment=promote&per_page=3' -q '.[] | {ref, created_at}'   # ref main
```

Sau lượt `gitops` đầu tiên của `verify.yml` trên `main`: bản ghi `stg` trên `svp-gitops` do bot tạo.

```sh
gh api 'repos/anhnvcoder/svp-gitops/deployments?environment=stg&per_page=3' -q '.[] | {id, ref, creator: .creator.login}'
# creator svp-gitops-promoter[bot]
```

### Xoay khoá App

Định kỳ (vài tháng một lần), hay ngay khi nghi lộ (sau bước Suspend của "Giảm thiểu"). App có nhiều khoá cùng lúc được, nên xoay
không làm gián đoạn:

1. Trang App https://github.com/settings/apps/svp-gitops-promoter → **Private keys** → **Generate a private key** (tải `.pem` mới).
2. Đặt secret bằng khoá mới (lệnh `gh secret set` của A4), xoá file `.pem`.
3. Kiểm `updated_at` của secret là lúc vừa đặt (lệnh ở A4); với lượt promote tiếp theo (hay dispatch `images.yml -f services=<một
   service>` do người học chạy), bước tạo token xanh. Khi nghi lộ, phần lượt promote chỉ làm sau **Unsuspend** (bước 4 của "Giảm
   thiểu"): bản cài còn suspend thì bước tạo token đỏ với mọi khoá.
4. Trang App → **Private keys** → **Delete** khoá cũ (khoá còn lại có ngày tạo hôm nay). Khi nghi lộ thì xoá khoá cũ **ngay** sau
   bước 2, không chờ lượt promote.

## Leo thang

- Bước tạo token vẫn đỏ sau khi đã kiểm đủ A2–A4 bằng UI và lệnh: so input của bước tạo token trong `.github/workflows/images.yml` với
  tên ở đây (`client-id` đọc `vars.SVP_GITOPS_APP_CLIENT_ID`, `private-key` đọc `secrets.SVP_GITOPS_APP_PRIVATE_KEY`, `owner`,
  `repositories: svp-gitops`); lệch tên thì sửa bằng PR ở repo code.
- PR stg của bot không tự merge dù `gitops-ok` xanh: PR đổi file có chủ (ngoài `envs/stg/`, hay chính `envs/stg/svp-policy.yaml`),
  tức ruleset `owners` đang làm đúng việc; đọc diff trước khi duyệt.
- Nghi lộ mà bot đã tạo PR, nhánh hay bản ghi lạ đã merge vào `main`, hay Argo CD đã sync một revision không thuộc `main` ("Giảm
  thiểu" bước 3): revert bằng PR (revision lạ: xoá tag, kiểm lại lịch sử sync), ghi lại mốc thời gian và mở postmortem
  ([mẫu](../postmortems/README.md)).

## Liên kết

- [ADR-0025](../adr/0025-gitops-config-repo.md) §5 (check `gitops-ok`), §6 (App, environment), §7 (ruleset, CODEOWNERS, cài đặt repo),
  §9 (trình tự chuyển), §10 (Renovate); mục "Kiểm chứng sau" của ADR đó: các phép kiểm sau push của auto-merge, Code Owner, bypass.
- [ADR-0015](../adr/0015-cicd-devsecops-stage5.md) §11: cài đặt tương ứng của repo code.
- `README.md` của `svp-gitops` (https://github.com/anhnvcoder/svp-gitops): cây, ai duyệt gì, promote.
- Không có diễn tập; phép kiểm sau push là lượt promote đầu (phần C).

## Đã kiểm

- 2026-10-29, phần A, bằng các lệnh của "Kiểm tra nhanh" và UI:
  - A1 đạt: auto-merge bật, chỉ squash, không tự xoá nhánh; chỉ action của GitHub, ghim SHA bắt buộc; token mặc định `read`,
    `can_approve_pull_request_reviews` false; secret scanning và push protection bật; Dependabot alerts 204. Lần kiểm đầu lệch
    duyệt PR fork (`first_time_contributors`), đã sửa cùng ngày: `all_external_contributors`. Sau commit khởi tạo `default_branch` là `main`.
  - A2, A3 đạt (UI): bốn quyền repository, cài "Only select repositories" chỉ `anhnvcoder/svp-gitops`.
  - A4 đạt sau sửa: luật nhánh `main`; lần kiểm đầu `SVP_GITOPS_APP_CLIENT_ID` nằm ở secret (`variables` rỗng), đã chuyển sang variable cùng
    ngày theo "Nếu sai" của A4; secret chỉ còn `SVP_GITOPS_APP_PRIVATE_KEY`.
  - A5 đạt (UI): Renovate có `svp-gitops`.
- Commit khởi tạo của `svp-gitops` (`55258e1`, không workflow) đã push 2026-10-29.
- Phần B, C, xoay khoá, gỡ khẩn cấp: chưa làm.
