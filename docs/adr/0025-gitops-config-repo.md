# 0025. Cấu hình triển khai chuyển sang repo public `svp-gitops` (values gốc, overlay và digest của mỗi env, manifest Argo CD), PR promote mở bằng GitHub App chỉ cài trên repo đó; chart vẫn ở repo code và mỗi env ghim commit chart của nó cùng bộ digest

- Trạng thái: Chấp nhận (người học duyệt 2026-10-28, chọn (a) ở cả sáu dòng "Cần người học chọn"); §3A chỉnh 2026-10-29 (người học
  quyết bố cục workspace: đường dev đọc bản clone cạnh bên `<workspace>/gitops`, CI vẫn `make gitops-clone`); §7, §8, §9 chỉnh
  2026-10-30 (ruleset thứ ba `tags`, `targetRevision` tên đầy đủ; §8 thêm: dựng ở commit đã kiểm rồi mới theo nhánh); quy ước revert và cài đặt squash của `svp-gitops` (mục 7) chỉnh
  bởi [0028](0028-dora-metrics.md) §5. Hiện thực 2026-10-29 đến 2026-10-30 (phần 4 của giai đoạn 6b, mục Hiện thực ở): `svp-gitops`
  khởi tạo (`55258e1`, rồi `a84e26d` thêm `check.yml`; lượt `check` đầu trên `main` xanh) với ba ruleset; PR-B cắt repo code (nhánh
  `feat/stage6b-gitops-split`, PR #39): CI, kịch bản `dev-k3d` và `gitops` trên nhánh đạt (mục Kiểm chứng sau); auto-merge của PR bot,
  bản ghi stg, promote prd, bypass `owners` kiểm sau merge PR-B
- Ngày: 2026-10-28

## Bối cảnh

- **Yêu cầu** (lộ trình của lab, mục "Bài SA bổ sung", dòng "Tách repo GitOps khỏi repo ứng dụng", thêm 2026-10-24; giai đoạn 6b phần
  4): repo ứng dụng giữ code, test, Dockerfile, CI build, quét, ký; repo cấu hình giữ Helm values, digest đang chạy, manifest Argo CD;
  job promote mở PR sang repo cấu hình; Argo CD chỉ đọc repo cấu hình; quyền merge code tách khỏi quyền deploy (ruleset, CODEOWNERS
  riêng); chuyển kiểu brownfield, hai nguồn không chạy song song quá một buổi; ADR ghi được và mất so với monorepo.
- **Đã chốt trước ADR này** (người học, 2026-10-25 và 2026-10-28; không đưa vào "Cần người học chọn"): `svp-gitops` public, không
  secret, ở tài khoản cá nhân (`https://github.com/anhnvcoder/svp-gitops`, đã tạo rỗng 2026-10-28); PR promote mở bằng GitHub App cài
  riêng trên `svp-gitops`, khoá ở environment `promote` của repo code; Argo CD và runner đọc cả hai repo qua HTTPS ẩn danh.
- **[ADR-0024](0024-multi-environment.md) §8 (Chấp nhận)** đã quyết phần cấu trúc env, ADR này **không thiết kế lại**: values gốc thành
  `base/`, overlay thành `envs/{stg,prd}/`, digest ở `envs/<env>/images/<svc>.yaml` (mỗi file chỉ khối `image`, thứ tự ghép thêm lớp
  này cuối cùng), `base/services/<svc>.yaml` không còn khối `image`; đơn vị promote prd là cả bộ bảy digest, so với payload của một
  bản ghi triển khai stg (Deployment GitHub trên `svp-gitops`); stg tự động sau build, prd qua PR có người duyệt, CODEOWNERS sở hữu
  `envs/prd/` và mọi file chung, không dòng nào cho `envs/stg/`; chart app-of-apps với `env`, không ApplicationSet; mỗi PR đổi
  `envs/prd/` do bot mở. ADR-0024 để lại cho ADR này: chart của repo nằm ở đâu, và mọi thứ của việc tách (đường dev, lịch sử, check,
  App, ruleset, trình tự).
- **Hiện trạng** (`origin/main` ở `744f108`, cộng phần 3 trên nhánh `feat/stage6b-runner-deep`, PR #26 đang mở):
  - Cấu hình triển khai nằm trong repo code: `deploy/k8s/values/` (15 file: values của 13 chart upstream, `argo-rollouts-amd64.yaml`
    theo kiến trúc node, `argo-cd.yaml` của chính Argo CD), `deploy/k8s/values/services/` (7 release của chart `svp-service`, khối
    `image` do PR promote ghi), `deploy/k8s/envs/stg/` (6 file), `deploy/k8s/envs/prd/` (8 file), `deploy/argocd/project.yaml`
    (AppProject `svp`, `default` đã khoá), chart app-of-apps `deploy/argocd/apps/` với `components.json` (24 component: 13 chart
    upstream, 4 chart của repo, 7 release `svp-service`).
  - Năm chart của repo (`deploy/helm/svp-service`, `svp-cluster`, `svp-data`, `svp-observability`, `svp-policy`) là code: đổi cùng
    service (biến môi trường mới, probe, NetworkPolicy), kiểm cùng image ở `make k8s-up` và kịch bản `dev-k3d`.
  - `deploy/argocd/apps/files/` có ba symlink: `envs` (tới `deploy/k8s/envs`), `svp-cluster-values.yaml` (tới
    `deploy/helm/svp-cluster/values.yaml`, đọc `podSecurityVersion` cho nhãn PSA của namespace wave 0) và `otelcol-k8s-config.yaml`
    (tới `deploy/observability/otelcol/k8s-config.yaml`, sha256 của nó vào annotation pod Collector để đổi config thì pod lăn).
    Symlink chỉ đi được trong một repo.
  - Argo CD do `deploy/k8s/gitops.sh` cài bằng helm (`argocd_chart_version` ghi trong script, values `deploy/k8s/values/argo-cd.yaml`;
    `renovate.json` gom hai chỗ đó vào nhóm `argo-cd chart`), không do Argo CD quản.
  - Promote ([ADR-0015](0015-cicd-devsecops-stage5.md) §9): job `promote` của `.github/workflows/images.yml` đẩy nhánh `bot/promote`
    của chính repo code bằng `GITHUB_TOKEN`, người học bấm "Approve workflows to run" rồi merge. ADR-0015 §9 đã loại "token của GitHub
    App riêng hay PAT" vì "khoá dài hạn trong secret của repo public". Ghi sang repo khác thì `GITHUB_TOKEN` không đủ (nó chỉ có quyền
    trên repo của lượt chạy), nên phần 4 cần một credential; người học đã chọn App.
  - Đọc các đường dẫn sẽ dời (`git grep -e deploy/k8s/values -e deploy/argocd -e deploy/k8s/envs`, trừ tài liệu và comment): `Makefile`
    (`helm-check`), `deploy/k8s/{lib,install,gitops,check-image-digests,secrets}.sh`, `deploy/k8s/k8s.mk`,
    `deploy/k8s/drills/{gitops,threats}.sh`, `deploy/ci/{promote,values-check,rescan,plan,gitops-sourcemaps}.sh`,
    `deploy/ci/verify/gitops.sh`, `deploy/ci/platform-test.sh`, `.github/workflows/images.yml`, `renovate.json`.
- **Ràng buộc:** một cluster lab mỗi lúc; kiểm nặng trên runner (`verify.yml`); CI trung lập nền tảng ([ADR-0023](0023-ci-platform-neutral.md):
  YAML chỉ nối bước, logic ở script, API của nền tảng qua `ci_*` của `deploy/ci/platform.sh`); repo public nên không secret, không
  khoá, không id App trong bất kỳ repo nào (ADR chỉ ghi tên biến); ADR 0026–0029 (secret theo GitOps, provenance, DORA, media) viết
  song song và đụng cùng cây cấu hình.
- **Hiện trạng ngành** (đọc 2026-10-28):
  - Kargo gói một bản phát hành thành "Freight", meta-artifact tham chiếu revision của image **và** cấu hình (Helm chart hay commit
    git); Freight đi qua các Stage như một khối vì các artifact "must make the journey together" [N15]. Cùng ý với đơn vị promote
    "cả bộ" của ADR-0024 §8, mở rộng sang chart.
  - Argo CD multi-source: nguồn Helm đọc values từ nguồn git khác qua `ref` và `$values`, chart và values ở hai repo khác nhau được;
    `$values` chỉ đứng đầu đường dẫn [N14].
  - Token của App: `actions/create-github-app-token` xin installation token hạn 1 giờ, thu hẹp được theo `repositories` và
    `permission-*`, thu hồi ở bước `post` của job [N1]. Sự kiện do `GITHUB_TOKEN` tạo không sinh lượt workflow mới; token của App hay
    PAT thì có [N11].

## Các lựa chọn

### 1. Nội dung, cây thư mục, file đang là symlink

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Cây của ADR-0024 §8 cộng `argocd/` (AppProject, chart app-of-apps, `components.json`, bản cài Argo CD), `CODEOWNERS`, `renovate.json`, `.github/`, `README.md`; values và version của chart Argo CD cùng chuyển** | Mọi thứ quyết định cái gì chạy ở stg, prd nằm sau cùng một cổng; Argo CD của giai đoạn 7 (mỗi cluster một bản, ADR-0024 dòng 6) cài từ cùng một chỗ | `gitops.sh` (ở repo code) phải đọc version và values của Argo CD từ bản clone |
| B. Như A nhưng giữ bản cài Argo CD (`argo-cd.yaml`, `argocd_chart_version`) ở repo code | `gitops.sh` không đổi chỗ đọc | Cấu hình của chính công cụ triển khai (health check, chu kỳ poll) đổi được mà không qua cổng của `svp-gitops`; Renovate tách một nhóm ra hai repo |
| **C. Hai symlink sang repo code thành giá trị dẫn xuất (`podSecurityVersion`, sha256 config Collector) ghi cạnh commit chart ghim, check tính lại từ đúng commit đó** | Hai số nhỏ, máy kiểm khớp | Thêm một bước ghi khi đổi commit ghim (promote làm) |
| D. Chép hai file sang `svp-gitops`, check so với bản ở repo code | Chart app-of-apps giữ nguyên `.Files.Get` | Bản sao cả file lệch dần; sửa config Collector phải sửa hai repo |
| E. Đọc file của repo code lúc render bằng Config Management Plugin | Không bản sao | Thêm plugin chạy trong repo-server (quyền, RAM); chart không còn render được bằng `helm template` trần |

### 2. Chart của repo code nằm đâu, ghim thế nào

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Giữ ở repo code; mỗi env ghim một commit repo code trong `envs/<env>/charts.yaml`; promote stg ghi commit đó cùng digest, promote prd chép cả hai từ bản ghi stg** | Chart và image đi cùng nhau như Freight [N15]: thay đổi chart chạy ở stg trước prd, đúng nguyên tắc "prd chỉ nhận bộ đã chạy cùng nhau ở stg" của ADR-0024 §8; check bắt được image mới hơn chart; không thêm pipeline phát hành | Thêm một file mỗi env và một tên dành riêng trong thư mục overlay; payload bản ghi stg thêm commit chart (chỉnh ADR-0024 §8); thay đổi chỉ ở chart (không image nào build) cần promote riêng |
| B. Giữ ở repo code; **một** commit ghim trong file chung của `svp-gitops` (đề xuất của kế hoạch), đổi ghim là PR có CODEOWNERS | Một giá trị; đổi chart luôn có người duyệt | Đổi ghim tới stg và prd cùng lúc, chart mới lên prd chưa từng chạy ở stg; image tự lên stg trước khi chart nó cần được ghim (biến môi trường mới thiếu, pod không khởi động), muốn tránh phải tách mọi thay đổi thành PR chart → bump ghim → PR code, không máy nào kiểm thứ tự |
| C. Gói OCI trên GHCR do CI repo code phát hành, ký | Chart có version, ký như image; Argo CD đọc OCI | Thêm pipeline phát hành, ký, package public cho 5 chart (thêm 5 package GHCR, Kyverno không kiểm chart); version chart phải tăng mỗi lần đổi; vẫn cần chọn A hay B cho việc ghim |
| D. Chart chuyển hẳn sang `svp-gitops` | Một repo cho mọi thứ Argo CD đọc | Đường dev (`make k8s-up`, `dev-k3d`) phải có `svp-gitops` mới cài được; thay đổi code cần chart mới thành hai PR ở hai repo cho cả đường dev; mất kiểm chart cùng code trong một PR |

### 3. Đường dev và CI repo code đọc `base/`, `components.json` ở đâu

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Bản clone `svp-gitops` trong thư mục bị gitignore của repo code (`make gitops-clone`, `main` mặc định), biến trỏ bản clone khác** | Không thêm khái niệm git nào; sửa thử base trên máy rồi `make k8s-up` được; CI clone ẩn danh | Đường dev cần mạng lần đầu; base ở `main` của `svp-gitops` và chart ở working tree có thể lệch (thay đổi chéo hai repo phải theo thứ tự) |
| B. Git submodule ở commit ghim | Commit nào của repo code cũng chỉ rõ bản cấu hình | Mỗi thay đổi cấu hình kéo theo một commit bump ở repo code: cấu hình lại gắn vào lịch sử code, đúng thứ việc tách muốn bỏ; submodule hay quên `--recursive` |
| C. Bản sao giữ trong repo code, đồng bộ bằng script | Đường dev không đổi | Hai bản của cùng dữ liệu, lệch dần; người đọc không biết bản nào đúng |

### 4. Chuyển dữ liệu: giữ lịch sử hay không

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Không giữ: commit khởi tạo ghi SHA nguồn của repo code và bảng đổi đường dẫn** | Lịch sử cũ vẫn đọc được ở repo code public (PR promote #17, #19, #21, #23, #25); commit đầu là đúng cây mới (khối `image` đã tách) | `git log` của `svp-gitops` bắt đầu từ ngày tách; xem lý do của một dòng values cũ phải sang repo code |
| B. `git filter-repo` giữ ba thư mục rồi đổi tên | Lịch sử từng dòng đi theo file | Lịch sử viết lại mang hash mới [N16], commit message nhắc commit khác thành sai; đường dẫn cũ (`deploy/k8s/values/services/`) ở mọi commit cũ khác đường mới; bước tách khối `image` vẫn là một commit lớn |
| C. `git subtree split` | Có sẵn trong git | Mỗi lần một `--prefix` (`git subtree -h`): ba thư mục nguồn không gộp thành một cây được nếu không ghép tay |

### 5. Check của PR trong `svp-gitops` chạy logic ở đâu

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Workflow của `svp-gitops` checkout repo code ở commit ghim trong chính workflow, gọi `deploy/ci/gitops-check.sh` (sẽ tạo)** | Logic ở script như ADR-0023; một bản logic; chạy được trên máy; PR của `svp-gitops` không đổi được bộ kiểm (trừ khi sửa workflow, file có chủ) | Đổi checker là PR ở `svp-gitops` bump commit; checker phải đọc được cây ở mọi commit ghim còn dùng |
| B. Reusable workflow của repo code (`uses: anhnvcoder/short-video-platform/.github/workflows/…@<sha>`) | Một chỗ định nghĩa job | Logic dời vào YAML (trái ADR-0023); cài đặt "chỉ action của GitHub" phải mở thêm workflow của repo code [N8]; GitLab mang sang bằng `include` khác ngữ nghĩa |
| C. Chép script sang `svp-gitops` | Repo tự đủ | Hai bản của checker, `helm-check` của repo code và check của `svp-gitops` lệch dần |

### 6. Credential ghi vào `svp-gitops`

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. GitHub App chỉ cài trên `svp-gitops`, token ngắn hạn bằng `actions/create-github-app-token`, mỗi job xin đúng quyền** (người học đã chốt App) | Token 1 giờ, thu hồi cuối job, thu hẹp theo repo và quyền [N1]; PR do token App mở sinh lượt `pull_request` mà không cần ai bấm duyệt [N11], nên auto-merge được; action nằm trong `actions/`, thuộc "actions created by GitHub" [N8] | Khoá riêng dài hạn của App trong environment `promote` (cái giá ADR-0015 §9 đã nêu); một App phải quản, xoay khoá |
| B. Fine-grained PAT của người học | Không App | Token mang danh người học: PR do "người học" mở thì người học không duyệt được [N6]; hạn dài; gắn với tài khoản cá nhân |
| C. Deploy key có quyền ghi | Hẹp về repo | Push được mà không mở PR qua API, không tạo được Deployment; SSH key dài hạn |
| **D. Khoá ở environment `promote` với deployment branch chỉ `main`** | Secret chỉ tới job khai environment đó [N12], lượt `pull_request` (ref `refs/pull/*`) không lấy được | Mọi job trên `main` khai `promote` đều lấy được: kỷ luật nằm ở review YAML |

### 7. Ruleset, CODEOWNERS, và ai duyệt PR của người học sửa file chung

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Hai ruleset: `main` (PR, check, cấm xoá và force push; không ai bypass) và `owners` (chỉ duyệt của Code Owner; vai admin bypass ở chế độ `pull_request`)** | Rule của các ruleset cộng dồn [N3], nên bypass `owners` không bỏ được check của `main`; bypass chỉ trên PR, có bản ghi bypass (chỉ chế độ `exempt` không tạo bản ghi [N4]); PR của bot vẫn được người học duyệt bình thường | Người học tự merge PR file chung của mình bằng bypass: là "tự duyệt có ghi lại", không phải người thứ hai |
| B. Tài khoản GitHub thứ hai làm người duyệt | Duyệt thật về mặt nút bấm | Điều khoản GitHub: một người tối đa một tài khoản miễn phí, tài khoản máy chỉ cho việc tự động [N13]; một người bấm hai tài khoản là duyệt giả |
| C. Mọi thay đổi do bot mở (người học đẩy nhánh, bot mở PR, người học duyệt) | Đúng "tác giả khác người duyệt" trên giấy | Vết kiểm toán sai: tác giả thật là người học; thêm một đường token mở PR theo yêu cầu |
| D. CODEOWNERS chỉ `envs/prd/` | Không vướng | Trái ADR-0024 dòng 4a: file chung (gốc, danh sách component) tới prd không ai duyệt |

### 8. Argo CD đọc gì

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Root và nguồn `ref: values` đọc `svp-gitops`; nguồn chart của repo đọc repo code ở commit ghim của env** | Đúng multi-source của Argo CD [N14]; repo code đọc ở SHA cố định, push vào `main` của repo code không đổi gì trên cluster | AppProject có hai repo git trong `sourceRepos`; Argo CD fetch theo SHA (kiểm sau) |
| B. Mọi thứ từ `svp-gitops` | Một repo | Chỉ có khi chọn 2D |
| C. ApplicationSet | Mẫu nhiều cluster | Đã loại ở ADR-0024 dòng 5 |

### 9. Trình tự chuyển

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Brownfield một buổi: chuẩn bị cây và checker trước, khởi tạo, rồi PR cắt ở repo code; đóng băng promote ở repo code từ lúc khởi tạo tới lúc cắt, kiểm hai bên bằng nhau trước khi merge** | Hai nguồn không chạy song song quá một buổi (lộ trình); lùi bằng PR revert | Không phát hành được trong cửa sổ đó |
| B. Chạy song song nhiều ngày (promote ghi cả hai) | Lùi dễ | Trái lộ trình; hai nguồn lệch, không biết cluster chạy theo nguồn nào |
| C. Cắt một lần không kiểm trên runner | Nhanh | Lỗi của đường GitOps chỉ lộ sau merge |

### 10. Renovate

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. `svp-gitops` có `renovate.json` riêng quản chart upstream và image ghim trong `base/`, bỏ qua `envs/**`; repo code bỏ manager của đường đã dời** | Mỗi dependency một chủ; PR của Renovate tới file có chủ, người học duyệt được (tác giả là Renovate) | Hai cấu hình Renovate |
| B. Không Renovate ở `svp-gitops`, nâng tay | Ít cấu hình | Mất cập nhật chart và digest ghim đã có từ giai đoạn 5 (ADR-0015 §10) |

### 11. Tách repo so với monorepo hiện tại

| | Monorepo (hiện tại) | Hai repo (ADR này) |
| --- | --- | --- |
| Thay đổi code cần cấu hình mới | Một PR | Hai PR, theo thứ tự: cấu hình tương thích bản cũ trước, code sau (expand/contract chéo repo) |
| Ai đổi được thứ đang chạy | Ai merge được vào `main` của repo code | Chỉ PR vào `svp-gitops`: stg tự động qua check, prd và file chung cần Code Owner |
| Lịch sử | Một: commit code và commit phát hành xen nhau | Hai: lịch sử triển khai đọc riêng (DORA đọc từ `svp-gitops`) |
| CI | Một bộ | Hai bộ (check của `svp-gitops` gọi script của repo code) |
| Credential | `GITHUB_TOKEN` | Khoá App ở environment `promote` |
| Đường dev | Working tree | Working tree + bản clone `svp-gitops` |
| Mô hình | Một team | Platform team giữ repo cấu hình, team ứng dụng giữ code (mục đích học của lộ trình) |

## Quyết định

Chọn 1A + 1C, 2A, 3A, 4A, 5A, 6A + 6D, 7A, 8A, 9A, 10A. Sáu điểm (2A, 3A, 5A, 4A, 7A và bản cài Argo CD của 1A) là đề xuất, chờ
dòng 1–6 của "Cần người học chọn". Lý do chung: cổng triển khai nằm ở diff của `svp-gitops`, mọi thứ quyết định cái gì chạy ở một
env (digest, commit chart, values) đi cùng nhau qua stg rồi mới tới prd, logic kiểm vẫn ở script của repo code, và không thêm
controller, pipeline phát hành hay secret nào ngoài khoá App.

### 1. Cây của `svp-gitops`

```text
svp-gitops/
  README.md                     tiếng Việt: repo là gì, cây, ai duyệt gì, cách promote, không secret
  CODEOWNERS                    mục 7
  renovate.json                 mục 10
  base/                         values gốc: mọi env; đường dev chỉ đọc lớp này
    <component>.yaml            từ deploy/k8s/values/<component>.yaml (cả argo-rollouts-amd64.yaml)
    argo-cd.yaml                values của chính Argo CD (từ deploy/k8s/values/argo-cd.yaml)
    services/<svc>.yaml         từ deploy/k8s/values/services/<svc>.yaml, bỏ khối image
  envs/
    stg/<component>.yaml        overlay (ADR-0024), từ deploy/k8s/envs/stg/
    stg/charts.yaml             commit chart của repo code mà stg chạy (mục 2)
    stg/images/<svc>.yaml       bảy file, chỉ khối image (ADR-0024 §8)
    prd/…                       như stg
  argocd/
    project.yaml                AppProject svp và default (từ deploy/argocd/project.yaml)
    bootstrap.json              chart Argo CD: repo, chart, version, values (base/argo-cd.yaml)
    apps/                       chart app-of-apps (từ deploy/argocd/apps/), components.json ở đây
      files/envs -> ../../../envs
  .github/
    workflows/check.yml         mục 5
    rulesets/main.json, owners.json, tags.json   mục 7
```

- `components.json`: `values` thành `base/<x>.yaml`; component chart của repo giữ `path: deploy/helm/<chart>` (đường trong repo code,
  repo URL do chart app-of-apps đặt). Chart của repo được thêm file values trong `base/` khi GitOps cần khác mặc định của chart (ví dụ
  bật kiểm provenance của `svp-policy` theo ADR-0027): `values.yaml` của chart là mặc định cho đường dev, `base/<chart>.yaml` là cấu
  hình GitOps.
- `bootstrap.json` một object cùng dạng một mục của `components.json` (`name`, `namespace`, `repo`, `chart`, `version`, `values`), để
  custom manager Renovate của `components.json` đọc được và `gitops.sh` đọc bằng `jq` ở đúng revision. `argocd_chart_version` rời
  `deploy/k8s/gitops.sh`.
- Hai symlink sang repo code bỏ (1C): `podSecurityVersion` và `collectorConfigSha256` thành khoá của `envs/<env>/charts.yaml` (mục 2).
  Symlink `files/envs` giữ, giờ nằm trong cùng repo.
- Không chuyển: `deploy/k8s/cloud/values/`, `deploy/k8s/cloud/charts.json` (chart cài tay hay trên runner, không qua Argo CD),
  `deploy/k8s/pod-security-admission.yaml`, `deploy/k8s/k3d.yaml` (tạo cluster, không phải cấu hình env).

### 2. Chart của repo: ở repo code, mỗi env ghim commit của nó (2A)

- `envs/<env>/charts.yaml`:

  ```yaml
  # The commit of the code repository whose charts (deploy/helm/*) this environment runs.
  revision: <40 hex>
  # Derived from that commit; written with it, checked against it.
  podSecurityVersion: v1.36            # deploy/helm/svp-cluster/values.yaml
  collectorConfigSha256: <64 hex>      # sha256 of deploy/observability/otelcol/k8s-config.yaml
  ```

  `charts` là tên dành riêng trong thư mục env: chart app-of-apps từ chối component tên `charts`, đòi file này cho env đang dựng và
  từ chối khoá khác ba khoá trên (lỗi render, như quy tắc overlay của ADR-0024).
- Chart app-of-apps dùng `revision` làm `targetRevision` cho mọi nguồn chart của repo code (`deploy/helm/*`) của env, hai giá trị dẫn
  xuất thay hai symlink.
- **Promote stg** ghi `envs/stg/charts.yaml` cùng `envs/stg/images/` trong cùng PR: `revision` là commit của lượt `images.yml` trên
  `main` (HEAD lượt đó), không bao giờ lùi (cùng luật tổ tiên của `promote.sh`), hai giá trị dẫn xuất tính từ commit đó. Lượt push
  `main` chỉ đổi `deploy/helm/` hay `deploy/observability/otelcol/k8s-config.yaml` (không image nào build) vẫn chạy job promote, chỉ
  ghi `charts.yaml`.
- **Promote prd** và bản ghi stg: payload của bản ghi triển khai stg (ADR-0024 §8) thêm `charts` (ba khoá trên, `revision` đọc từ
  `targetRevision` của Application chart repo đang chạy, phải khớp `envs/stg/charts.yaml` ở commit đã đồng bộ); promote prd chép cả bộ
  bảy digest **và** `charts.yaml`; check prd so cả hai với payload. Rollback prd chép cả hai từ bản ghi cũ.
- **Check** (mục 5), mỗi env: `revision` là commit trên `main` của repo code; commit của mỗi image (`image.tag`, 12 hex) là tổ tiên hay
  chính `revision` (chart không cũ hơn code của image nào: image cần biến môi trường mới không chạy được với chart cũ); hai giá trị dẫn
  xuất bằng giá trị tính từ `revision`.
- Đổi chart vì thế đi qua stg trước prd như digest; `deploy/helm/` không có version phát hành riêng (version trong `Chart.yaml` không
  dùng để ghim).

### 3. Đường dev và CI repo code đọc bản clone (3A)

- Thư mục cấu hình (chỉnh 2026-10-29, theo bố cục workspace người học quyết: thư mục gốc không git chứa `backend/` là repo code,
  `gitops/` là bản clone `svp-gitops`, `.worktrees/` là worktree tạm của repo code): một hàm của `deploy/k8s/lib.sh` trả thư mục cấu
  hình, mọi script đọc qua hàm đó. `SVP_GITOPS_DIR=<thư mục>` nếu đặt (bản clone khác, bản đang sửa; CI đặt tới bản clone của `make
  gitops-clone`); không thì `<workspace>/gitops`, với `<workspace>` là thư mục cha của thư mục chứa `git rev-parse --path-format=absolute
  --git-common-dir` (luôn `backend/.git`, nên đúng cả từ worktree ở `.worktrees/`; `--show-toplevel` từ worktree cho `.worktrees/`).
  Thư mục đó không có hay không phải bản clone `svp-gitops` (gốc một work tree git, remote `origin` là `svp-gitops`) thì in lệnh `git
  clone https://github.com/anhnvcoder/svp-gitops.git <workspace>/gitops` và dừng, không đọc bản nào khác thay. Đường dev **không tự
  clone, không fetch, không đổi nhánh** bản của người học.
- `make gitops-clone` (CI): clone `https://github.com/anhnvcoder/svp-gitops.git` ẩn danh, đủ lịch sử, vào `.gitops/svp-gitops` của
  checkout (thêm vào `.gitignore`), có rồi thì fetch và chuyển tới `GITOPS_REF` (mặc định `main`, nhánh hay SHA đầy đủ); bản clone có
  thay đổi chưa commit thì từ chối, không ghi đè. Job cần cấu hình đặt `SVP_GITOPS_DIR` tới thư mục đó (job `config` khai ở `env` của
  job, `verify-run.sh` export sau khi clone).
- Đường dev (`make k8s-up`, `install.sh`) đọc **working tree** của bản clone như đọc working tree của repo code: `base/` và
  `components.json`, không `envs/`, không `images/` (dev build image của nó, ADR-0024 4A). Sửa thử base: sửa trong bản clone, `make
  k8s-up`, rồi mở PR ở `svp-gitops`.
- CI repo code: job `config` của `ci.yml` và các kịch bản k3d của `verify.yml` chạy `make gitops-clone` (ref `main`) trước `make
  helm-check` và bước dựng; `helm-check` render chart của working tree với `base/` của bản clone (`deploy/ci/gitops-check.sh
  --worktree`, cùng script mà check của `svp-gitops` chạy).
- Thay đổi chéo hai repo theo thứ tự: values mới phải dùng được với chart đang ghim (merge ở `svp-gitops` trước), rồi chart dùng values
  đó (repo code); bỏ một value thì ngược lại.

### 4. Không giữ lịch sử (4A)

Commit khởi tạo của `svp-gitops` có message ghi SHA đầy đủ của repo code mà cây được dựng từ đó và bảng đổi đường dẫn
(`deploy/k8s/values` → `base`, `deploy/k8s/envs` → `envs`, `deploy/argocd` → `argocd`, khối `image` → `envs/<env>/images/`). Lịch sử
cũ ở lại repo code public.

### 5. Check của `svp-gitops` (5A)

- `.github/workflows/check.yml` của `svp-gitops` (sẽ tạo), trigger `pull_request` và `push` lên `main`; `permissions: {}` ở đầu, job
  chỉ `contents: read` và `deployments: read` (đọc bản ghi stg cho PR prd); không secret, không `pull_request_target`; action ghim SHA.
- Job checkout `svp-gitops` (PR head) và repo code ở **commit checker** ghi trong chính workflow (SHA đầy đủ, một chỗ), đủ lịch sử (luật
  tổ tiên), rồi gọi `deploy/ci/gitops-check.sh <cây svp-gitops> <base>` (sẽ tạo) của repo code ở commit đó. Script: render mọi
  env × kiến trúc (root và chart, như `make helm-check` hiện nay, chart repo của mỗi env ở `revision` của env đó), quy tắc overlay,
  `images/`, `charts.yaml`, image chart upstream ghim digest (như `deploy/k8s/check-image-digests.sh`), render prd không còn `svp.localhost`,
  `values-check` cho file `envs/*/images/*.yaml` đổi từ base, luật mục 2, và với PR đổi `envs/prd/images/` hay `envs/prd/charts.yaml`:
  cả bộ khớp payload của một bản ghi stg `success` (ADR-0024 §8; đọc bản ghi qua `ci_*`).
- Check tổng bắt buộc: **`gitops-ok`** (như `ci-ok`, cần mọi job). Commit checker đổi bằng PR ở `svp-gitops` (file `.github/` có chủ,
  mục 7); Renovate theo dõi nó (mục 10). Một PR sửa workflow chạy bản sửa của chính nó (đặc tính của `pull_request`), nên `.github/`
  phải có Code Owner; App không có quyền `workflows` nên không đẩy được thay đổi workflow nào.

### 6. GitHub App

- Tên `svp-gitops-promoter`; quyền repository: `contents: write` (đẩy nhánh bot, merge), `pull_requests: write` (mở, sửa PR),
  `deployments: write` (tạo Deployment và trạng thái của nó [N10]), `metadata: read`; không quyền nào khác (không `workflows`,
  `actions`, `administration`, `checks`, `statuses`); webhook tắt; chỉ tài khoản này; cài "Only select repositories" = `svp-gitops`.
- Repo code, environment `promote`: deployment branch "Selected branches" = `main`, không người duyệt (stg tự động; cổng prd là
  CODEOWNERS của PR prd); biến `SVP_GITOPS_APP_CLIENT_ID`, secret `SVP_GITOPS_APP_PRIVATE_KEY`. Không giá trị nào vào repo.
- Token: `actions/create-github-app-token` ghim SHA (thuộc `actions/`, nằm trong "chỉ action của GitHub" của ADR-0015 §11 [N8]), với
  `client-id` (input `app-id` cũ vẫn nhận [N1]), `owner: anhnvcoder`, `repositories: svp-gitops`, và `permission-*` chỉ của bước đó;
  không `skip-token-revoke`.
- Ba job có environment `promote`, đều chỉ chạy trên `main` ngoài `pull_request`:

  | Job | Quyền token | Việc |
  | --- | --- | --- |
  | `promote` của `images.yml` (push `main`, dispatch `services`) | `contents`, `pull_requests` write | Nhánh `bot/promote-stg` của `svp-gitops`, PR, bật auto-merge |
  | promote prd của `images.yml` (dispatch, nhận id bản ghi) | `contents`, `pull_requests` write | Nhánh `bot/promote-prd`, PR không auto-merge |
  | ghi bản ghi stg của `verify.yml` (bước kịch bản của job `gitops` xanh và `release-set.json` trong artifact, ref `main`; [ADR-0021](0021-deferred-verification-stage6b.md) mục 3) | `deployments` write | Deployment `stg` trên `svp-gitops` |

  Không job `pull_request` nào khai `promote`. Tạo Deployment phải đặt `auto_merge: false` (mặc định `true` merge nhánh mặc định vào
  `ref`) và `required_contexts: []` (mặc định đòi mọi commit status `success`) [N9].
- Check PR prd chỉ nhận bản ghi do chính App tạo, có URL lượt `verify.yml` trên `main` của repo code: token App bị lộ ghi được bản ghi
  giả, nên khớp bản ghi là chặn nhầm lẫn; chặn kẻ xấu là duyệt của Code Owner.
- Khoá App xoay bằng cách tạo khoá mới, thay secret, xoá khoá cũ trên trang App.

### 7. Ruleset và CODEOWNERS (7A)

- `CODEOWNERS` (ở gốc; luật "dòng khớp cuối thắng", dòng không chủ bỏ chủ của đường đó [N5]):

  ```text
  *           @anhnvcoder
  /envs/stg/
  ```

  Mọi file mới mặc định có chủ; chỉ `envs/stg/` (overlay, `charts.yaml`, `images/` của stg) không. File phải nằm trên nhánh base của
  PR [N5].
- Ruleset `main` của `svp-gitops` (file `.github/rulesets/main.json` của repo đó, sẽ tạo; nhánh mặc định, `bypass_actors: []`):
  `deletion`, `non_fast_forward`, `pull_request` (`required_approving_review_count: 0`, `require_code_owner_review: false`,
  `dismiss_stale_reviews_on_push: true`), check bắt buộc
  `gitops-ok` với `integration_id` của app GitHub Actions như ruleset của repo code.
- Ruleset `owners` (file `.github/rulesets/owners.json` của `svp-gitops`, sẽ tạo): chỉ `pull_request` với
  `require_code_owner_review: true`, `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: true` (PR đổi file có chủ
  phải được chính Code Owner duyệt [N2]); bypass: vai admin của repo (`actor_type: RepositoryRole`, id lấy lúc nhập), `bypass_mode:
  pull_request` [N4]. Hai ruleset cộng dồn [N3]: PR của bot chỉ đổi `envs/stg/` cần
  check, không cần duyệt, auto-merge [N7]; PR đổi file có chủ do bot mở (prd, Renovate) cần người học duyệt (tác giả không tự duyệt
  [N6]); PR của người học trên file có chủ merge bằng bypass `owners`, check của `main` vẫn bắt buộc.
- Ruleset `tags` (thêm 2026-10-30, file `.github/rulesets/tags.json` của `svp-gitops`): `target: tag`, mọi tên (`~ALL`), rule
  `creation`, `update`, `deletion`; bypass duy nhất vai admin của repo, `bypass_mode: always` (`pull_request` chỉ áp cho ruleset nhánh
  [N4]). Lý do: token App có `contents: write` đẩy được tag, và Argo CD có thể phân giải `targetRevision` tên ngắn sang tag cùng tên
  [N17], nên một tag `main` do token lộ tạo có thể thành thứ được deploy; lab không dùng tag trong repo cấu hình. Đi cùng mục 8
  (`targetRevision` luôn tên đầy đủ).
- Cài đặt repo: "Allow auto-merge" bật [N7]; "Allow GitHub Actions to create and approve pull requests" tắt (không workflow nào của
  `svp-gitops` mở PR) [N8]; Actions chỉ action của GitHub, ghim SHA bắt buộc; duyệt workflow PR fork cho mọi người ngoài [N8]; secret
  scanning, push protection, Dependabot alerts như repo code (ADR-0015 §11).

### 8. Argo CD (8A)

- Root `svp-root`: `repoURL` `https://github.com/anhnvcoder/svp-gitops.git`, `path: argocd/apps`, `targetRevision` = `GITOPS_REV` (nhánh
  hay SHA của `svp-gitops`), `valuesObject`: `targetRevision`, `env`, `nodeArch` như ADR-0024 §4, thêm `chartRepoURL` =
  `https://github.com/anhnvcoder/short-video-platform.git`.
- **Dựng ở commit đã kiểm, theo nhánh sau** (chỉnh 2026-10-30): `GITOPS_REV` là nhánh thì `gitops.sh` dựng root ở đúng SHA mà nó đã
  kiểm image (`origin/<nhánh>` của bản clone), chờ mọi Application Synced/Healthy ở SHA đó, rồi mới chuyển root sang
  `refs/heads/<nhánh>` (`follow_branch`); `GITOPS_REV` là SHA thì cluster ở yên SHA đó. Lý do: lượt `verify.yml`
  [40984138133](https://github.com/anhnvcoder/short-video-platform/actions/runs/40984138133) dựng theo nhánh, PR promote #4 của
  `svp-gitops` merge giữa lúc dựng, Argo CD triển khai bản mới thành canary không có traffic, `restartAt` của `glitchtip-init.sh` chờ
  Rollout `web` Healthy 300 s rồi đỏ, và các phép kiểm image đã chạy trên commit cũ. Nhánh đã đi tiếp lúc chuyển thì `gitops.sh` in một
  dòng `note` nêu hai commit (bản mới ra như mọi lần phát hành, canary cần traffic) và không chờ. Kịch bản `gitops` của `verify.yml`
  dựng bằng SHA của `origin/main` trong bản clone và giữ SHA đó suốt các bước kiểm (bộ phát hành mà `release-set` ghi không đổi giữa
  chừng); chỉ bước chờ phát hành (`release_wait`) mới chuyển sang `refs/heads/main` (`deploy/k8s/gitops.sh follow main`), sau khi
  traffic diễn tập đã chạy. Bản phát hành merge vào `main` của `svp-gitops` trong lúc ghim chỉ triển khai lúc chuyển, nên thời gian từ
  push tới pod của nó tính cả thời gian ghim (hàng chục phút tới hàng giờ), không phải độ trễ GitOps: `release_wait` không đo nó, in
  một dòng `not measured` nêu commit ghim, commit Argo CD vừa nhận và các bản phát hành ở giữa, rồi chờ bản phát hành sau commit đó.
- Mọi `targetRevision` đọc `svp-gitops` (root, `argocd_root_app` của `deploy/k8s/lib.sh`, mặc định `targetRevision` của
  `argocd/apps/values.yaml`) là tên đầy đủ `refs/heads/<nhánh>` hay SHA 40 hex, không bao giờ tên ngắn (chỉnh 2026-10-30). Lý do: Argo CD
  lấy mọi nhánh và tag của repo, tên ngắn trùng cả nhánh lẫn tag thì có thể bị phân giải sang commit của tag; tài liệu Argo CD khuyên
  dùng tên đầy đủ [N17] (mục 7, ruleset `tags`). `gitops.sh` chuyển `GITOPS_REV` là nhánh thành `refs/heads/<nhánh>`;
  `deploy/ci/gitops-check.sh` từ chối cây mà render của chart app-of-apps có nguồn `svp-gitops` với `targetRevision` tên ngắn.
- Application con: chart upstream như nay; chart repo: `repoURL` repo code, `targetRevision` = `revision` của `envs/<env>/charts.yaml`,
  `path: deploy/helm/<chart>`; nguồn `ref: values` là `svp-gitops` ở revision của root (`$values/base/…`, `$values/envs/<env>/…`,
  `$values/envs/<env>/images/…`).
- AppProject `svp`: `sourceRepos` thêm `svp-gitops`, giữ repo code (chỉ đọc ở SHA do `svp-gitops` ghim) và các repo chart; đích và
  kind không đổi.
- `gitops.sh` (repo code) đọc mọi thứ của revision từ bản clone bằng `git show`/`git archive` như nay đọc repo code: digest ở
  `envs/stg/images/`, `bootstrap.json` và `base/argo-cd.yaml`, `project.yaml`, `components.json`; chart `svp-cluster` cho namespace lấy
  bằng `git archive` repo code ở `revision` của `envs/stg/charts.yaml`.

### 9. Trình tự chuyển (9A)

1. PR-A của repo code (provenance, secret, media; ADR 0026, 0027, 0029) merge; bảy bản phát hành mới vào `main`.
2. Cây khởi tạo dựng trong thư mục tạm `gitops/` của working tree repo code (không commit vào repo code); checker
   `deploy/ci/gitops-check.sh` (sẽ tạo) cùng test vào `main` của repo code bằng một PR nhỏ riêng.
3. Người học: tạo App, cài lên `svp-gitops`, environment `promote` với khoá; cài đặt repo `svp-gitops` (mục 7).
4. Người điều phối push commit khởi tạo (không `.github/workflows/`), rồi commit thứ hai thêm workflow ghim commit checker đã merge; lượt
   đầu của workflow trên `main` phải xanh. Người học nhập ba ruleset (`main`, `owners`, `tags`).
5. **Đóng băng** từ bước 4: không merge PR promote nào ở repo code.
6. PR-B "cắt" ở repo code: đọc bản clone, xoá `deploy/k8s/values/`, `deploy/k8s/envs/`, `deploy/argocd/`, promote sang `svp-gitops`;
   trước merge, kịch bản `dev-k3d` và `gitops` trên nhánh (đọc `svp-gitops` `main`) xanh, và bảy digest của `envs/stg/images/` ở `main`
   của `svp-gitops` bằng bảy digest của `deploy/k8s/values/services/` ở `main` của repo code (khác thì đồng bộ trước). Merge PR-B; đóng
   PR `bot/promote` còn mở của repo code, xoá nhánh đó. Hết đóng băng.
7. `envs/stg/charts.yaml` lên commit merge của PR-B qua lần promote đầu (hay PR tay), commit checker của workflow bump bằng PR; lượt
   `gitops` trên `main`.

Cách lùi: trước merge PR-B, `main` của repo code chưa đổi gì, đường cũ vẫn chạy (cửa sổ đóng băng chỉ dời phát hành). Sau merge mà
đường mới hỏng: PR revert PR-B ở repo code (đường cũ trở lại với digest ở `deploy/k8s/values/services/` lúc cắt), `svp-gitops` giữ
nguyên, không ai đọc; bản phát hành nào đã promote sang `svp-gitops` trong lúc đó thì dispatch `images.yml -f services=<…>` để PR
promote cũ ghi lại. Không xoá `svp-gitops`.

### 10. Renovate (10A)

- `svp-gitops/renovate.json`: chuyển nguyên các manager và nhóm hiện có cho `deploy/k8s/values/*.yaml` (ghim image `tag@sha256`, nhóm
  theo chart), `components.json` (version chart), nhóm `argo-cd chart` thành `argocd/bootstrap.json` + `base/argo-cd.yaml`; action của
  `check.yml`; commit checker (datasource `git-refs` theo `main` của repo code); `ignorePaths: ["envs/**"]`; cùng lịch, `minimumReleaseAge`
  3 ngày, không automerge. Người học cài thêm `svp-gitops` vào App Mend.
- Repo code `renovate.json`: bỏ manager, nhóm và `ignorePaths` của `deploy/k8s/values/`, `deploy/argocd/apps/components.json`,
  `argocd_chart_version`; giữ `deploy/k8s/cloud/`, `Makefile`, `lib.sh`, Dockerfile, action, Go.
- Renovate nâng chart upstream trong `base/` tới stg và prd cùng lúc (cái giá ADR-0024 đã nhận), sau duyệt Code Owner.

### 11. Được và mất so với monorepo

Theo bảng lựa chọn 11. Bảng ánh xạ GitLab ([ADR-0023](0023-ci-platform-neutral.md), thêm khi mang sang):

| Khái niệm | GitHub (ADR này) | GitLab | Bậc GitLab |
| --- | --- | --- | --- |
| Credential bot ghi repo cấu hình | GitHub App, token 1 giờ | project hay group access token trên project cấu hình, biến protected masked của project code | gitlab.com: Premium (ADR-0023, bảng repo) |
| Cổng prd, file chung | CODEOWNERS + ruleset | Code Owners trên protected branch | Premium (ADR-0024 §8) |
| Bypass có ghi của chủ repo | ruleset `owners`, chế độ `pull_request` | quyền "Allowed to merge" của protected branch | chưa kiểm |
| Auto-merge PR bot | auto-merge | auto-merge khi pipeline xanh | chưa kiểm |
| Bản ghi stg | Deployment trên `svp-gitops` | environment và deployment | Free (ADR-0024 §8) |
| Check gọi script của repo khác | checkout repo code ở SHA | clone project code ẩn danh (public) ở SHA | Free |

### 12. Thay đổi ở repo code

Để mục Hiện thực ở và các bước sau dựa vào; tên file mới ghi "(mới)".

| File | Đổi |
| --- | --- |
| `deploy/k8s/lib.sh` | hàm thư mục cấu hình; `release_image` đọc `envs/<env>/images/`; `values_field`, `values_set_image` đọc file chỉ có khối `image` (giữ dạng); `argocd_root_app` thêm `chartRepoURL`, `path: argocd/apps` |
| `deploy/k8s/install.sh` | `components.json`, `base/` từ bản clone; values của chart repo trong `base/` nếu có |
| `deploy/k8s/k8s.mk`, `Makefile`, `.gitignore` | target `gitops-clone` (CI); `k8s-up`, `k8s-gitops-up` chỉ gọi hàm thư mục cấu hình, không clone (CI đặt `SVP_GITOPS_DIR` bằng `make gitops-clone` trước); `helm-check` render với bản clone; `.gitops/` |
| `deploy/k8s/gitops.sh` | repo URL `svp-gitops`; `GITOPS_REV` là revision của `svp-gitops`; digest, `charts.yaml`, `bootstrap.json`, `project.yaml` từ bản clone |
| `deploy/k8s/check-image-digests.sh` | gộp vào `deploy/ci/gitops-check.sh` (mới), không hai bản cùng logic |
| `deploy/ci/gitops-check.sh`, `deploy/ci/gitops-check-test.sh` (mới) | mục 5 |
| `deploy/ci/values-check.sh` | nhận đường `envs/*/images/`, chạy trong check của `svp-gitops` |
| `deploy/ci/promote.sh` | clone `svp-gitops`, nhánh `bot/promote-stg`, chỉ ghi `envs/stg/images/` và `envs/stg/charts.yaml`, giữ luật không lùi và `--force-with-lease`, bật auto-merge |
| `deploy/ci/rescan.sh` | tập digest: `envs/*/images/` của `svp-gitops` ở `main`, ở nhánh PR bot đang mở, ở `values_ref` (ref của `svp-gitops`) |
| `deploy/ci/plan.sh`, `deploy/ci/changed-services.sh` | bỏ đọc `deploy/k8s/values/services`; chế độ promote chỉ chart (mục 2); loại test mới khỏi đường dẫn image |
| `deploy/ci/platform.sh`, `deploy/ci/platform-test.sh` | hàm PR nhận repo đích, bật auto-merge, tạo và đọc Deployment |
| `deploy/ci/gitops-sourcemaps.sh` + test, `deploy/ci/verify/gitops.sh`, `deploy/ci/verify-run.sh` | đọc digest web ở `envs/stg/images/web.yaml` của `svp-gitops`; bước chờ phát hành theo dõi `main` của `svp-gitops`; clone trước bước dựng |
| `deploy/k8s/drills/gitops.sh` | `measure-gitops` đo commit của `svp-gitops` (thời điểm push qua `ci_push_time` của repo đó) |
| `deploy/k8s/drills/supplychain.sh`, `deploy/k8s/drills/threats.sh`, `deploy/k8s/secrets.sh` | đọc `components.json` và digest phát hành từ bản clone |
| `.github/workflows/images.yml` | job `promote` với environment `promote` và token App; job promote prd (mới); bỏ job `values-check` (digest không còn ở repo code) |
| `.github/workflows/verify.yml` | job ghi bản ghi stg (environment `promote`); clone trước bước dựng |
| `.github/workflows/ci.yml` | job `config` clone, chạy `gitops-check-test.sh`, `promote-test.sh` (mới) |
| `renovate.json` | mục 10 |
| `deploy/k8s/values/`, `deploy/k8s/envs/`, `deploy/argocd/` | xoá ở PR-B |

## Cần người học chọn

Mỗi dòng hai phương án trở lên đều dùng được; đề xuất đứng trước. Người học duyệt ngày 2026-10-28: chọn (a) ở cả sáu dòng.

1. **Chart của repo ghim thế nào?** (a) Mỗi env một `envs/<env>/charts.yaml`, promote stg ghi cùng digest, promote prd chép cả hai từ
   bản ghi stg (payload thêm `charts`, chỉnh ADR-0024 §8). Lý do: chart mới chạy ở stg trước prd và máy chặn image mới hơn chart. (b)
   Một commit ghim trong file chung, đổi bằng PR có Code Owner (đề xuất ban đầu của kế hoạch): ít file hơn, nhưng chart mới tới stg và
   prd cùng lúc và thứ tự chart trước image chỉ là quy ước. (c) Gói OCI ký trên GHCR: thêm pipeline phát hành, vẫn phải chọn (a) hay
   (b) để ghim.
2. **Đường dev đọc `base/` ở đâu?** (a) Bản clone gitignore qua `make gitops-clone`. Lý do: không gắn lịch sử cấu hình vào repo code,
   sửa thử base được. (b) Submodule ghim commit: rõ bản cấu hình của mỗi commit code, nhưng mỗi thay đổi cấu hình thêm một commit bump ở
   repo code.
3. **Check của `svp-gitops` chạy logic ở đâu?** (a) Script repo code ở commit checker ghim trong workflow. Lý do: một bản logic, đúng
   ADR-0023. (b) Reusable workflow của repo code: logic vào YAML, phải mở allow list action. (c) Chép script: hai bản lệch dần.
4. **Giữ lịch sử khi chuyển?** (a) Không; commit khởi tạo ghi SHA nguồn và bảng đổi đường dẫn. Lý do: lịch sử cũ còn nguyên ở repo
   code public, đường đổi tên làm lịch sử viết lại khó đọc. (b) `git filter-repo`: lịch sử theo file nhưng hash mới, đường cũ ở mọi
   commit cũ.
5. **PR của người học sửa file có chủ do ai duyệt?** (a) Ruleset `owners` riêng, admin bypass chỉ qua PR; check của ruleset `main`
   vẫn bắt buộc. Lý do: mỗi lần tự merge có bản ghi bypass, không giả một người duyệt thứ hai. (b) Tài khoản thứ hai: trái điều khoản
   (một tài khoản miễn phí mỗi người [N13]), duyệt giả. (c) Mọi thay đổi do bot mở: tác giả trên PR không phải tác giả thật.
6. **Bản cài Argo CD (version chart, `argo-cd.yaml`) ở đâu?** (a) `svp-gitops` (`argocd/bootstrap.json`, `base/argo-cd.yaml`). Lý do:
   cấu hình của công cụ triển khai qua cùng cổng; Argo CD mỗi cluster ở giai đoạn 7 cài từ cùng chỗ. (b) Giữ ở repo code: `gitops.sh`
   không đổi chỗ đọc, nhưng đổi Argo CD không qua cổng của `svp-gitops`.

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết (không push, không ghi GitHub); mỗi dòng nêu phép kiểm; kết quả và ngày ghi vào cột cuối. Dòng
"kiểm sau merge PR-B" cần lượt trên `main` sau khi PR #39 merge.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Token App bật được auto-merge với `contents`, `pull_requests` write (tài liệu không ghi quyền của thao tác này [N7]); PR bot chỉ đổi `envs/stg/` tự merge sau `gitops-ok`, không ai duyệt | Lần promote stg đầu sau PR-B, **kiểm sau push** | Chưa kiểm: lần promote stg đầu chạy sau merge PR-B (kiểm sau merge PR-B) |
| PR do token App mở sinh lượt `pull_request` của `check.yml` không cần bấm duyệt [N11] | Cùng lần trên: check chạy ngay | Chưa kiểm (kiểm sau merge PR-B, cùng lần trên) |
| `require_code_owner_review` với 0 approval vẫn chặn PR đổi file có chủ chưa được Code Owner duyệt; duyệt của App không thay Code Owner | PR thử của bot đổi `base/` (không merge được tới khi người học duyệt); App gửi review approve trên PR thử, vẫn bị chặn | Chưa kiểm (kiểm sau merge PR-B). Ba ruleset `main`, `owners`, `tags` đã nhập, `active` (tạo 2026-10-29 UTC, đọc lại bằng API) |
| Bypass ruleset `owners` của admin để merge PR của mình không bỏ được check `gitops-ok` của ruleset `main`, và có bản ghi bypass | PR thử của người học sửa `README.md` khi check đỏ (không merge được), rồi khi xanh (merge bằng bypass; Rule Insights có dòng bypass) | Chưa kiểm (kiểm sau merge PR-B) |
| Argo CD đọc hai repo ẩn danh, nguồn chart repo code ở SHA 40 hex | Kịch bản `gitops` trên nhánh PR-B: mọi Application Synced, Healthy; Application `svp-cluster` có `targetRevision` bằng `envs/stg/charts.yaml` | Đạt (2026-10-29, `gitops` [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229), nhánh PR-B ở `027f8bd`, `svp-gitops` `cf28b34`): root `svp-root` theo `refs/heads/main` của `svp-gitops` qua HTTPS không credential, nguồn chart của repo code ở `c59c7426663d` (bằng `revision` của `envs/stg/charts.yaml`); 26/26 Application Synced, Healthy, sync cuối `Succeeded` sau 610 s. Lượt trước [40938235138](https://github.com/anhnvcoder/short-video-platform/actions/runs/40938235138) kẹt lúc dựng (`kube-prometheus-stack` Progressing: operator chỉ dò CRD một lần lúc khởi động, CR Prometheus tới trước CRD), sửa bằng sync wave trong `svp-gitops` (PR #2: CRD wave 0, operator 1, CR Prometheus, Alertmanager 2) |
| Check của `svp-gitops` chạy script của repo code ở commit checker ghim, không phải của PR | Lượt đầu của `check.yml` trên `main` (bước 4 của trình tự): log in commit đã checkout; PR thử sửa script ở repo code không đổi kết quả của check | Một phần: lượt `check` đầu trên `main` của `svp-gitops` [40902199532](https://github.com/anhnvcoder/svp-gitops/actions/runs/40902199532) (2026-10-29, `a84e26d`, checker ghim `c59c7426663d`) xanh, `gitops-ok`, token chỉ `Contents: read`. PR thử sửa script ở repo code: chưa kiểm |
| Token App chỉ ghi được `svp-gitops`, chỉ quyền đã xin; không job `pull_request` nào lấy được khoá | Bước thử trong job `promote` đầu: `git push` lên repo code bằng token đó bị từ chối; lượt `pull_request` khai `promote` bị environment từ chối | Chưa kiểm (kiểm sau merge PR-B). Tĩnh: không job `pull_request` nào khai `promote` (`images.yml`, `verify.yml` trên nhánh PR-B) |
| Tạo Deployment với `auto_merge: false`, `required_contexts: []` trả 201 [N9]; check prd chỉ nhận bản ghi của App | Phần 4, lượt `gitops` trên `main` rồi promote prd (theo ADR-0024 Kiểm chứng sau) | Chưa kiểm (kiểm sau merge PR-B: job `record-stg` chỉ chạy trên `main`, ở lượt dispatch hay lượt lịch tuần có bước kịch bản `gitops` xanh, không cần bản phát hành trong lượt) |
| Check chặn image mới hơn chart và hai giá trị dẫn xuất sai | Phần 4, ca âm trong `gitops-check-test.sh` (bản sao tạm): tag image không phải tổ tiên của `revision`; `collectorConfigSha256` sai | Đạt: ca âm của `deploy/ci/gitops-check-test.sh` (tag image không phải tổ tiên của `revision`, `collectorConfigSha256` sai, image mới hơn chart) đỏ đúng message; chạy ở job `config` của CI PR #39 [40954602918](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954602918) (2026-10-29, `027f8bd`) xanh |

## Hệ quả

- **Được:**
  - Quyền deploy tách khỏi quyền merge code: thứ chạy ở stg, prd chỉ đổi qua PR vào `svp-gitops`; push vào `main` của repo code không đổi
    cluster nào.
  - stg nhận bản phát hành không cần ai bấm (auto-merge sau check), bỏ cú bấm "Approve workflows to run" của ADR-0015 §9.
  - Một bản phát hành là bảy digest cộng commit chart, đi qua stg rồi mới tới prd; lịch sử triển khai đọc riêng trong `svp-gitops`.
- **Phải trả:**
  - Thay đổi cần cả code lẫn cấu hình thành hai PR theo thứ tự; CI repo code phụ thuộc `main` của `svp-gitops`.
  - Một khoá dài hạn (khoá App) trong environment `promote`; mọi job trên `main` khai environment đó lấy được nó.
  - Người học tự merge thay đổi file chung bằng bypass: tách quyền ở lab một người là mô phỏng, có ghi lại chứ không có người thứ hai.
  - Thay đổi chỉ ở chart cần một lượt promote; chart mới mà image chưa build lại vẫn chạy với image cũ (như hiện nay).
  - Thêm một tên dành riêng (`charts`) trong thư mục overlay; checker phải đọc được cây ở mọi `revision` còn ghim.
- **Xem lại khi:**
  - Phần 4b (`svp-web`): repo web cần promote sang `svp-gitops`; đề xuất App thứ hai cho repo web (khoá thu hồi riêng) hay cùng App,
    chốt ở ADR của 4b.
  - Có người thứ hai: bỏ bypass ruleset `owners`, bắt duyệt thật.
  - Source Hydrator hay Kargo đủ chín (ADR-0024, Xem lại khi): Freight thay `charts.yaml` + `images/`.
  - Chart cần dùng ngoài lab: xét gói OCI ký (lựa chọn 2C).
- **ADR cũ được chỉnh** (đã ghi "chỉnh bởi 0025" ở trạng thái của chúng và ở `docs/adr/README.md` ngày 2026-10-30):
  - [ADR-0014](0014-kubernetes-local-stage4.md) §12: Argo CD đọc `svp-gitops` (root, values) và repo code ở commit ghim (chart);
    `sourceRepos` thêm `svp-gitops`; values và version của Argo CD ở `svp-gitops`.
  - [ADR-0015](0015-cicd-devsecops-stage5.md) §9: promote sang `svp-gitops` bằng token App (lựa chọn "App riêng" từng bị loại, nay
    dùng vì ghi chéo repo), stg auto-merge, bỏ `values-check` của repo code; §10: Renovate tách hai repo; §11: ruleset, CODEOWNERS và
    cài đặt của `svp-gitops`.
  - [ADR-0021](0021-deferred-verification-stage6b.md) §6: kịch bản `gitops` đọc `svp-gitops`; bước chờ phát hành theo dõi `main` của
    `svp-gitops`, bản phát hành tới không qua merge tay; job ghi bản ghi stg có environment `promote`.
  - [ADR-0023](0023-ci-platform-neutral.md): hàm `ci_*` mới (PR ở repo khác, auto-merge, Deployment); dòng mới của bảng ánh xạ (mục 11).
  - [ADR-0024](0024-multi-environment.md) §8: payload bản ghi stg và check prd thêm `charts`; thư mục env có tên dành riêng `charts.yaml`
    (theo dòng 1 của "Cần người học chọn"); bản cài Argo CD ở `argocd/` (dòng 6).
- **Tài liệu cập nhật khi hiện thực:** `CLAUDE.md` (Kiểm tra: `make gitops-clone`, `k8s-gitops-up`, CI), `docs/architecture.md`,
  `docs/ci-cd.md`, `docs/threat-model.md` (khoá App, bản ghi giả, bypass), runbook dựng `svp-gitops`.

## Hiện thực ở

Hiện thực 2026-10-29 đến 2026-10-30 (PR-B, nhánh `feat/stage6b-gitops-split`, PR #39):

- Repo `svp-gitops` (mục 1, 5, 7, 10): `README.md`, `CODEOWNERS`, `renovate.json`; `base/` (values gốc, `base/argo-cd.yaml`,
  `base/services/<svc>.yaml` không khối `image`); `envs/{stg,prd}/` (overlay, `svp-policy.yaml`, `charts.yaml`, `images/<svc>.yaml`);
  `argocd/project.yaml`, `argocd/bootstrap.json`, `argocd/apps/` (`components.json`, `values.yaml` mặc định `refs/heads/main`,
  `templates/applications.yaml`, symlink `files/envs`); `.github/workflows/check.yml` (job `gitops`, check tổng `gitops-ok`, commit
  checker ghim một chỗ), `.github/rulesets/main.json`, `owners.json`, `tags.json`.
- Thư mục cấu hình và đường dev (mục 3): `gitops_is_clone`, `gitops_dir`, `gitops_clone` của `deploy/k8s/lib.sh`; target `gitops-clone`
  (`GITOPS_REF`) của `deploy/k8s/k8s.mk`; `.gitops/` trong `.gitignore`; `deploy/k8s/install.sh` (`components.json`, `base/` của bản
  clone); `deploy/k8s/drills/threats.sh` đọc `components.json` của bản clone.
- Check (mục 2, 5, 8): `deploy/ci/gitops-check.sh` (cây, `charts.yaml`, luật tổ tiên, bước 1b so PR prd với bản ghi stg, render
  root và chart mỗi env × kiến trúc, từ chối `targetRevision` tên ngắn, image bên thứ ba ghim digest, gộp và thay
  `deploy/k8s/check-image-digests.sh` đã xoá; `--worktree` là `make helm-check` của `Makefile`), test `deploy/ci/gitops-check-test.sh`
  (gồm ca của `gitops_dir`, `gitops_clone`); `deploy/ci/values-check.sh` (chỉ `--gitops DIR BASE`), `deploy/ci/verify-release.sh`
  (`--gitops DIR`), `provenance_required`, `_config_file` của `deploy/ci/common.sh` đọc `envs/<env>/svp-policy.yaml` của thư mục
  cấu hình; `tag_provenance_mismatch` của `common.sh` (bước 5: `image.tag` bằng commit mà dòng `ok` của `verify-release.sh` nêu từ
  provenance; env đòi provenance mà dòng `ok` không nêu commit thì đỏ, không bao giờ qua).
- Argo CD (mục 8): `argocd_root_app` (`path: argocd/apps`, `chartRepoURL`, `targetRevision` tên đầy đủ) của `deploy/k8s/lib.sh`;
  `deploy/k8s/gitops.sh` (revision của `svp-gitops`, bảy bản ở `envs/stg/images/`, `bootstrap.json`, AppProject từ bản clone, namespace
  từ `svp-cluster` ở commit của `charts.yaml`; hết hạn chờ thì `gitops_timeout_report` của `lib.sh` in trạng thái từng Application,
  tài nguyên chưa Healthy đọc thẳng từ cluster và sự kiện; root dựng ở SHA đã kiểm, `follow_branch` và `gitops.sh follow BRANCH` chuyển
  sang nhánh, chỉnh 2026-10-30); `restart_workload` của `lib.sh` dừng ngay khi Rollout đang canary (`rollout_not_canary`); `gitops_up`
  dựng bằng SHA, `release_wait` gọi `gitops.sh follow`, nhánh đã đi tiếp thì `follow_moved`, `gitops_releases_between` nêu bản phát
  hành không đo và chờ từ commit mới (`deploy/ci/verify/gitops.sh`); test ở `deploy/ci/verify-collect-test.sh`.
- Promote stg (mục 2, 6): `deploy/ci/promote.sh` (nhánh `bot/promote-stg`, `envs/stg/images/` và `envs/stg/charts.yaml`, luật không lùi,
  `--force-with-lease`, đọc lại PR sau push, auto-merge), test `deploy/ci/promote-test.sh`; job `promote` của
  `.github/workflows/images.yml` (environment `promote`, token App chỉ `svp-gitops`, `contents` và `pull_requests` write);
  `promote_charts` của `deploy/ci/plan.sh` (promote chỉ chart), bỏ job `values-check`; `deploy/ci/changed-services.sh` (script và test
  không job image nào đọc).
- Bản ghi stg và promote prd (mục 2, 6; ADR-0024 §8): `deploy/ci/release-set.sh` (`snapshot [--settle]`, `verify`, `records`, `check`),
  test `deploy/ci/release-set-test.sh`; bước `release-set-before`, `release-set` của `deploy/ci/verify/gitops.sh`, `release-set.json`
  trong `deploy/ci/verify-collect.sh`; `deploy/ci/record-stg.sh` và job `record-stg` của `.github/workflows/verify.yml` (environment
  `promote`, token chỉ `deployments` write); `deploy/ci/promote-prd.sh` (nhánh `bot/promote-prd`), test `deploy/ci/promote-prd-test.sh`,
  job `promote-prd` của `images.yml` (dispatch `promote_prd`, `record`).
- Rescan (mục 12): `deploy/ci/rescan.sh` (`list`, `run`: `envs/*/images/` của `svp-gitops` ở `main`, ở PR `bot/promote-stg` đang mở, ở
  `values_ref`, hay commit cũ của repo code trước PR-B), job `rescan` của `images.yml` (`make gitops-clone`).
- Adapter (mục 12; [ADR-0023](0023-ci-platform-neutral.md)): `deploy/ci/platform.sh` (PR ở repo đích, `ci_change_request_auto_merge`,
  `ci_git_auth`, `ci_bot_*` theo App, `ci_push_time SHA [REPO]`, `ci_deployment_record`, `ci_deployment_list`, `ci_run_workflow`), test
  `deploy/ci/platform-test.sh`.
- Kịch bản và diễn tập đọc `svp-gitops`: `deploy/ci/verify/gitops.sh`, `deploy/ci/verify-run.sh` (clone trước kịch bản k3d),
  `deploy/ci/gitops-sourcemaps.sh` (test `deploy/ci/gitops-sourcemaps-test.sh`), `deploy/k8s/drills/gitops.sh` (`measure-gitops` đo commit
  của `svp-gitops`), `deploy/k8s/drills/supplychain.sh` (digest ở `envs/stg/images/`).
- CI và Renovate: job `config` của `.github/workflows/ci.yml` (`make gitops-clone`, `gitops-check-test.sh`, `promote-test.sh`,
  `promote-prd-test.sh`, `release-set-test.sh`); `renovate.json` bỏ manager của đường đã dời (mục 10).
- Đã xoá khỏi repo code: `deploy/k8s/values/`, `deploy/k8s/envs/`, `deploy/argocd/`, `deploy/k8s/check-image-digests.sh`.
- Cài đặt GitHub (người học): App `svp-gitops-promoter`, environment `promote` của repo code (biến `SVP_GITOPS_APP_CLIENT_ID`, secret
  `SVP_GITOPS_APP_PRIVATE_KEY`), cài đặt và ba ruleset của `svp-gitops`; quy trình tay ở
  [`docs/runbooks/svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md).

## Nguồn

Đọc ngày 2026-10-28.

- [N1] `actions/create-github-app-token`, README (`client-id`, `owner`, `repositories`, `permission-*`, token hạn 1 giờ, thu hồi ở bước
  `post`): <https://github.com/actions/create-github-app-token>
- [N2] GitHub Docs, "Available rules for rulesets" ("Require review from Code Owners": PR đổi nội dung có Code Owner phải được Code
  Owner duyệt): <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets>
- [N3] GitHub Docs, "About rulesets" (rule của nhiều ruleset cộng dồn, bản chặt nhất thắng):
  <https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets>
- [N4] GitHub REST, "Repository rules" (`bypass_mode`: `always`, `pull_request`, `exempt`; `exempt` không tạo bản ghi bypass; tham số
  rule `pull_request`): <https://docs.github.com/en/rest/repos/rules>
- [N5] GitHub Docs, "About code owners" (dòng khớp cuối thắng, đường không chủ, file trên nhánh base, chủ cần quyền ghi):
  <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners>
- [N6] GitHub Docs, "Approving a pull request with required reviews" ("Pull request authors cannot approve their own pull requests"):
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews>
- [N7] GitHub Docs, "Automatically merging a pull request" (bật ở repo trước; người có quyền ghi bật; merge khi đủ review và check):
  <https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request>
- [N8] GitHub Docs, "Managing GitHub Actions settings for a repository" (action của GitHub ở tổ chức `actions` và `github`; cài đặt
  cho `GITHUB_TOKEN` mở PR; duyệt workflow PR fork):
  <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository>
- [N9] GitHub REST, "REST API endpoints for deployments" (`auto_merge` mặc định `true`, `required_contexts`, `payload`):
  <https://docs.github.com/en/rest/deployments/deployments>
- [N10] GitHub Docs, "Permissions required for GitHub Apps" (Deployments write cho `POST /repos/{owner}/{repo}/deployments` và
  trạng thái của nó; Contents write cho merge PR): <https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps>
- [N11] GitHub Docs, "Triggering a workflow" (sự kiện của `GITHUB_TOKEN` không sinh lượt mới; dùng token App hay PAT):
  <https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow>
- [N12] GitHub Docs, "Managing environments for deployment" (secret chỉ tới job khai environment; deployment branch; Free chỉ repo
  public): <https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments>
- [N13] GitHub Terms of Service, mục B.3 (một tài khoản miễn phí mỗi người; tài khoản máy chỉ cho việc tự động):
  <https://docs.github.com/en/site-policy/github-terms/github-terms-of-service>
- [N14] Argo CD, "Multiple Sources for an Application" (`ref`, `$values`, chart và values ở hai repo):
  <https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>
- [N15] Kargo, "Core Concepts" (Freight gồm image và cấu hình, đi qua các Stage như một khối): <https://docs.kargo.io/user-guide/core-concepts/>
- [N16] `git filter-repo`, README (được dự án git khuyên thay `filter-branch`; commit id cũ ánh xạ sang id mới):
  <https://github.com/newren/git-filter-repo>
- [N17] Argo CD, "Tracking and Deployment Strategies", mục "Handling Ambiguous Git References in Argo CD" (đọc 2026-10-30: "If the
  `targetRevision` matches multiple references, Argo CD attempts to resolve it and may select a different commit than expected"; khuyên
  `refs/heads/<nhánh>`, `refs/tags/<tag>`): <https://argo-cd.readthedocs.io/en/stable/user-guide/tracking_strategies/>
