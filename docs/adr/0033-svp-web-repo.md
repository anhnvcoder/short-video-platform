# 0033. Web client tách sang repo `svp-web` để mô phỏng team FE và team BE riêng: hợp đồng OpenAPI có version semver, kiểm breaking ở PR backend và phát hành có chữ ký trên GHCR; image web có nguồn phát hành và identity ký riêng, mọi nguồn khai ở một file của chart `svp-policy` mà Kyverno và script cùng đọc; `svp-web` promote riêng `envs/stg/images/web.yaml` sang `svp-gitops` bằng GitHub App thứ hai; script CI dùng chung chạy ở commit ghim của repo backend

- Trạng thái: Chấp nhận (người học duyệt 2026-10-30, chọn (a) ở cả sáu dòng "Cần người học chọn"; các điểm thiết kế còn lại theo
  đề xuất). Bước 1–5 của mục 9 xong 2026-10-30: PR-1 merge (`28bf2ca`, PR #43; sửa tiếp PR #45, #48), repo `svp-web` với lịch sử chụp
  ở `28bf2ca`, check của `svp-gitops` theo nguồn (PR #20), bản phát hành đầu của `svp-web` chạy ở stg (PR #22 của `svp-gitops`); PR-2
  (cắt `web/`) hiện thực 2026-10-31, chưa merge; promote prd có web của `svp-web` và PR-3 chưa (mục Kết quả, Hiện thực ở)
- Ngày: 2026-10-30

## Bối cảnh

- **Yêu cầu** (lộ trình của lab, mục "Bài SA bổ sung", dòng "Tách web sang repo riêng `svp-web`", chốt 2026-10-25; giai đoạn 6b phần
  4b): ba repo `short-video-platform` (trong ADR này gọi là **backend**), `svp-web`, `svp-gitops`; phát hành hợp đồng API (OpenAPI của
  gateway có version, kiểm breaking ở PR backend, web sinh type từ bản đã phát hành); e2e của web kéo image backend theo digest; CI và
  promote riêng của repo web dùng lại cơ chế PR sang `svp-gitops` của [ADR-0025](0025-gitops-config-repo.md); Renovate, ruleset, adapter CI ở
  cả hai repo; dọn `web/` khỏi backend, giữ lịch sử.
- **Lý do thật của việc tách:** mô phỏng tổ chức có team FE và team BE riêng, mỗi team một repo, một pipeline, một nhịp phát hành, nói
  chuyện với nhau qua hợp đồng API. Mô hình này thường gặp ở công ty Việt Nam, nhất là trên GitLab self-managed. Hệ thống một người làm
  **không cần** tách: monorepo hiện tại đổi API và web trong một PR, một lượt CI kiểm cả hai. Mọi cái giá ở bảng 11 được trả để học cách
  vận hành ranh giới đó (hợp đồng có version, kiểm chéo, hai nguồn phát hành, hai credential), không phải vì hệ thống tốt hơn nhờ nó.
- **Đã chốt trước ADR này** (không đưa vào "Cần người học chọn"): ba repo public ở tài khoản cá nhân; người học tạo `svp-web` và cấp quyền
  GitHub App (lúc viết repo chưa có: `gh repo view anhnvcoder/svp-web` trả "Could not resolve to a Repository", 2026-10-30); lịch sử chuyển
  bằng `git filter-repo` (người học chọn); bố cục workspace: `frontend/` là bản clone `svp-web` cạnh `backend/` và `gitops/`, tới lúc tách
  web vẫn ở `backend/web/` (`CLAUDE.md` của workspace).
- **Hiện trạng** (backend `main` ở `ec12f11`; `svp-gitops` đọc từ bản clone `gitops/`):
  - Mã: `web/` (Next.js 16 và BFF, spec e2e Playwright, `lighthouse/`, client canary), `deploy/docker/web.Dockerfile` (context `web/`, có
    stage `sourcemaps` `FROM scratch`); các target `web-*`, `measure-web`, `measure-upload`, `web-lighthouse`, `web-sourcemaps` của
    `Makefile`. Script `generate` của `web/package.json` chạy `openapi-typescript ../services/gateway/openapi.yaml`, `make
    web-generate-check` so `web/gen/api.d.ts` với bản commit. `info.version` của `services/gateway/openapi.yaml` là `0.1.0` từ đầu, không
    luật nào bắt tăng.
  - Pipeline: `web` là image thứ bảy ([ADR-0019](0019-web-k3d-supply-chain-observability.md) §1) trong `svp_services`, `image_paths`,
    `build_dev_images` của `deploy/k8s/lib.sh`; `images.yml` build, quét, ký, attest `vuln` và provenance, xuất artifact
    `web-sourcemaps-<arch>`; job `promote` (token của App `svp-gitops-promoter`) ghi cả bảy `envs/stg/images/<svc>.yaml`; `rescan.sh` đòi
    mọi digest là `ghcr_prefix/<svc>` có chữ ký của `images.yml` backend và `--replace` attestation `vuln` bằng identity đó, cả của web.
  - Một nguồn phát hành: `ghcr_prefix` (`lib.sh`) và `imagePrefix`, `issuer`, `subject`, `provenanceRepository`, `provenanceRef` của
    `deploy/helm/svp-policy/values.yaml` (identity viết một chỗ, [ADR-0023](0023-ci-platform-neutral.md) §4); `sign_identity`,
    `provenance_source` của `deploy/ci/common.sh` đọc các dòng đó bằng `sed`. ImageValidatingPolicy `svp-images` có một attestor, một glob
    `<imagePrefix>*`, phép 1 nhận mọi tên dưới prefix; image diễn tập `drill-vulnerable`, `drill-unsigned` nằm dưới cùng prefix.
  - Luật của `svp-gitops` ([ADR-0025](0025-gitops-config-repo.md) §2): `gitops-check.sh` đòi mỗi `envs/<env>/images/<svc>.yaml` là
    `ghcr_prefix/<svc>` với `tag` là tổ tiên của `revision` trong `envs/<env>/charts.yaml`, xét trên lịch sử backend; `promote.sh` chọn ứng
    viên theo luật tổ tiên trên `main` backend (tag không phải commit của `main` backend thì giữ giá trị của `main` và job đỏ);
    `release-set.sh` kiểm payload bản ghi stg với `ghcr_prefix`; `dora.sh` đọc lịch sử backend và `svp-gitops`.
  - Kiểm: job `web` của `ci.yml` (`make web-check`, `web-generate-check`, `web-lockfile-scan`); job `stack` build web từ `web/`, chạy
    `web-e2e`, `load-ci` (gọi cả `http://web:3001`), `web-lighthouse`. `verify.yml`: `compose-obs` (`web-lighthouse` ×3, `measure-upload`),
    `dev-k3d` (`k8s-web-sourcemaps`, `k8s-web-e2e`, `drill-k8s-web-obs`), `web-canary` (build web hai lần từ working tree), `gitops`
    (`k8s-web-e2e`, source map của image CI qua `deploy/ci/gitops-sourcemaps.sh`, tải artifact của lượt `images.yml` cùng repo).
    `web/e2e/seed.sh` source `deploy/compose/lib.sh`, `web/e2e/k3d-e2e.sh` source `deploy/k8s/lib.sh`: mã test của web dựa vào harness
    của backend.
- **Ràng buộc:** CI trung lập nền tảng (ADR-0023: YAML chỉ nối bước, logic ở script, API nền tảng qua hàm `ci_*`); action chỉ của GitHub và
  `sigstore/cosign-installer`, ghim SHA ([ADR-0015](0015-cicd-devsecops-stage5.md) §11); công cụ mới phải có lý do và người học chọn; repo
  public: không giá trị secret, id cài đặt App hay token trong repo nào, ADR chỉ ghi tên biến; một cluster lab mỗi lúc, máy 16 GB, kiểm
  nặng trên runner.
- **Hiện trạng ngành** (đọc 2026-10-30; nhãn cũ / hiện hành / mới nổi là nhận định của ADR này dựa trên nguồn, ghi ở bảng "Cần người
  học chọn"):
  - **Kiểm breaking OpenAPI.** oasdiff đang hoạt động: v1.35.0 ngày 2026-10-28, Apache-2.0; v1.34.1 là bản vá bảo mật cho ai dùng `--open`
    hay GitHub Action của nó [W1]. Hỗ trợ OpenAPI 3.1 "generally available starting with `v1.15.0`", còn thiếu `$dynamicRef` và `pathItems`
    trong components [W3]. Có phép kiểm version: `api-version-not-bumped` (có breaking mà `info.version` không đổi), `api-version-decreased`,
    `api-major-version-not-bumped`; mặc định mức `INFO` nên "never fail a build on their own", muốn chặn thì nâng bằng `--severity-levels` và
    `--fail-on ERR`; version không phải semver thì bỏ qua [W2]. openapi-diff của OpenAPITools: Java, README ghi "Supports OpenAPI spec
    v3.0", không nhắc 3.1, bản 2.1.7 ngày 26/1 (năm suy từ bản trước) [W5]. Optic: repo "archived by the owner on Jan 12, 2026", bản cuối
    v1.0.9 [W4]. openapi-changes (pb33f): "Supports OpenAPI 3.2, 3.1 and 3.0", bản v0.2.13 ngày 11/10 (trang không in năm), action đọc file
    luật từ nhánh base [W6].
  - **Phát hành artifact không phải image.** ORAS là dự án CNCF Sandbox, tự nhận "the de facto tool for working with OCI Artifacts", bản
    v1.3.6 ngày 2026-10-24; GHCR nằm trong danh sách registry hỗ trợ OCI artifact [W7]. cosign "can sign anything in a registry"; ví dụ của
    tài liệu đẩy bằng ORAS rồi ký theo digest [W8]. npm trên GitHub Packages: "You need an access token to publish, install, and delete
    private, internal, and public packages", chỉ PAT classic [W9]. Trang "About releases" của GitHub không nói tải asset ẩn danh [W10].
  - **Token giữa hai repo.** Quyền của `GITHUB_TOKEN` "limited to the repository that contains your workflow" [W11];
    `actions/download-artifact` cần `github-token` khi tải từ repo khác, ví dụ dùng PAT "with actions:read permissions on target repo"
    [W12]. Tải artifact của lượt `svp-web` bằng `GITHUB_TOKEN` của backend vì vậy chưa chứng minh, và tài liệu nghiêng về không được.
  - **Reusable workflow** gọi được ở repo khác theo SHA; job gọi nó không dùng được `environment` [W16]. Job chạy reusable workflow nhận
    claim OIDC `job_workflow_ref` trỏ tới reusable workflow [W17]; SAN của chứng chỉ Fulcio là `server_url` + `job_workflow_ref` (comment
    của `deploy/helm/svp-policy/values.yaml`), nên identity ký thành workflow của repo **được gọi**.
  - **Kyverno** ImageValidatingPolicy (Stable từ v1.19): `attestors` là danh sách, `verifyImageSignatures(image, [attestors.x])` nhận danh
    sách attestor; mọi ví dụ của trang chỉ có một attestor, trang không nói cách chọn attestor theo image [W13].
  - **GitLab.** CI/CD component có ở Free, gọi bằng `include: component:` theo SHA hay tag, chỉ trong cùng instance; dùng component của
    gitlab.com trên self-managed phải mirror (Premium, Ultimate) [W14]. Multi-project pipeline `trigger: project:` có ở Free; lấy artifact
    của pipeline project khác (`needs:project`) cần Premium [W15].
  - **Renovate**: custom manager regex với datasource `docker` đọc tag của registry tuỳ ý; trang không nói gì về OCI artifact không phải
    image [W18].
  - **`git filter-repo`**: "recommended by the git project" thay `filter-branch`; `--path` chọn đường, `--path-rename` đổi tên, "a rename
    directive does not select paths"; thao tác phá huỷ, chạy trên bản clone riêng [W19].

## Các lựa chọn

### 1. Hợp đồng API

Công cụ kiểm breaking ở PR backend:

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. oasdiff, chạy bằng image ghim digest như trivy, kubeconform** | OpenAPI 3.1 GA [W3]; phép kiểm version semver có sẵn [W2]; một binary Go, chạy trên máy như trên CI; không cần GitHub Action | Thêm một công cụ; hai chỗ 3.1 chưa hỗ trợ (spec hiện không dùng, kiểm lúc hiện thực); phải tự nâng mức `err` cho ba phép kiểm version |
| B. openapi-changes | 3.0, 3.1, 3.2 [W6] | Chưa 1.0; bộ luật breaking tự viết; không thấy phép kiểm version |
| C. openapi-diff (OpenAPITools) | `--fail-on-incompatible` [W5] | README chỉ ghi 3.0 trong khi spec là `openapi: 3.1.0`; cần JVM |
| D. Optic | — | Repo đã archive [W4] |
| E. Tự viết so sánh | Không thêm công cụ | So schema, `$ref`, `required`, enum đúng là việc khó, dễ sót |

Nơi phát hành, để web tải ẩn danh và kiểm được toàn vẹn:

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. OCI artifact trên GHCR đẩy bằng ORAS, ký keyless bằng cosign theo digest** | Cùng cơ chế với image: package public kéo ẩn danh, ghim digest, chữ ký keyless đúng identity của backend [W7][W8]; GitLab có Container Registry tương ứng | Thêm ORAS (image ghim); Renovate với OCI artifact chưa có tài liệu [W18] |
| B. Image `FROM scratch` chứa file spec, build và đẩy bằng docker có sẵn, ký như A | Không thêm công cụ; Renovate đọc như mọi image | Artifact không chạy được trình bày thành image; lấy file ra phải `docker create` rồi `docker cp`; cách làm của ADR này, không có nguồn ngành |
| C. Asset của GitHub Release, ký bằng `cosign sign-blob --bundle` | Renovate có datasource cho release | Tải ẩn danh chưa xác nhận trong tài liệu [W10]; mốc phát hành là tag git đổi được trong repo backend; API khác hẳn trên GitLab |
| D. npm trên GitHub Packages | Công cụ npm quen | Cần token kể cả gói public [W9]: mọi máy và CI của web phải giữ PAT classic |
| E. Không phát hành: web đọc file ở commit backend ghim, kèm sha256 | Không thêm gì | Không chữ ký; "bản phát hành" chỉ là một commit, không version nói được tương thích |

Luật version: **semver theo loại thay đổi, máy kiểm** (đề xuất), so với "tăng tay tuỳ ý, chỉ kiểm breaking" (người đọc version không suy ra
gì) hay "version là commit" (không nói tương thích).

### 2. Image và nguồn phát hành của web

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Image ở `ghcr.io/anhnvcoder/svp-web/web`** | Mỗi repo đẩy dưới prefix của mình bằng `GITHUB_TOKEN` của chính nó; policy chọn attestor theo prefix; bản cũ và mới phân biệt được bằng đường | Đổi đường ở file image của `svp-gitops`, policy, script, diễn tập |
| B. Giữ `ghcr.io/anhnvcoder/short-video-platform/web` | Không đổi đường | Package đang gắn repo backend, `svp-web` phải được cấp quyền ghi package của repo khác (cài đặt của package, chưa kiểm); hai identity ký cùng một đường nên policy phải chọn attestor theo thứ khác ngoài prefix |

| Một chỗ khai mọi nguồn phát hành | Được | Mất |
| --- | --- | --- |
| **A. File `deploy/helm/svp-policy/files/sources.json` của chart: template đọc bằng `.Files.Get`, script đọc bằng `jq`** | Một file, một định dạng `jq` đọc chắc; nằm trong chart nên theo `revision` của `charts.yaml`: thêm hay gỡ một nguồn tới stg trước prd | Năm dòng rời `values.yaml` (chỉnh ADR-0023 §4); overlay của env không đổi được nguồn (cố ý: nguồn là danh tính của code, không phải cấu hình env) |
| B. Danh sách trong `values.yaml` | Chỗ cũ | Script đang đọc dòng phẳng bằng `sed`; danh sách YAML cần parser mà repo không có (không `yq`) |
| C. Mỗi repo tự khai identity của mình | Repo tự chủ | Hai chỗ: Kyverno và script của repo kia lệch nhau |

| Policy chọn attestor | Được | Mất |
| --- | --- | --- |
| **A. Một policy `svp-images`, mỗi nguồn một attestor, CEL chọn attestor theo prefix của image** | Giữ tên, thứ tự mười phép kiểm, một webhook; diễn tập và script vẫn đọc một policy | Tài liệu không có ví dụ nhiều attestor [W13]: phải chứng minh bằng ca chéo trên cluster |
| B. Mỗi nguồn một policy, render bằng `range` | Mỗi policy một attestor như ví dụ tài liệu | Phép 1 phải lặp ở mọi policy hay thành policy thứ ba; diễn tập và `image_policy_ready` đọc nhiều tên; mỗi pod qua nhiều webhook |
| C. Một attestor nhiều identity | Ít thay đổi nhất | Identity `svp-web` ký được image backend và ngược lại: trái yêu cầu |

### 3. Luật của `svp-gitops` cho image của nguồn khác

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Luật theo nguồn: backend giữ luật tổ tiên với `revision`; nguồn khác: tag là commit trên `main` của repo nguồn, provenance `gitCommit` bằng tag** | Giữ phép "image không mới hơn chart" cho sáu service dùng chart theo code; web có phép kiểm tương đương trong repo của nó | Check phải có lịch sử `svp-web`; không máy nào kiểm thứ tự "web cần cấu hình mới" (bên dưới) |
| B. Luật tổ tiên cho cả web | — | Không làm được: tag của web là commit của repo khác, không có quan hệ tổ tiên với `revision` |
| C. Một luật "tag là commit trên `main` của repo nguồn" cho mọi image | Một luật | Mất phép kiểm image backend mới hơn chart ([ADR-0025](0025-gitops-config-repo.md) §2) |

### 4. Promote, credential, rescan

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Nhánh bot riêng `bot/promote-stg-web`, PR chỉ đổi `envs/stg/images/web.yaml`** | Hai repo không đua `--force-with-lease` trên một nhánh; PR của web tự merge độc lập | Hai PR stg có thể merge sát nhau (mỗi cái một commit của `svp-gitops`) |
| B. Dùng chung `bot/promote-stg` | Một PR stg | Hai workflow ghi đè nhánh của nhau, mỗi lượt đọc lại thấy nhánh đổi và đỏ |

| Credential của `svp-web` | Được | Mất |
| --- | --- | --- |
| **A. GitHub App thứ hai `svp-web-promoter`, chỉ cài trên `svp-gitops`, `contents` và `pull_requests` write** | Khoá riêng, thu hồi riêng; tác giả PR cho biết repo nào mở nên check của `svp-gitops` giới hạn được bot nào sửa file nào; không quyền `deployments` (bản ghi stg vẫn do App backend tạo) | Người học tạo và quản thêm một App, xoay hai khoá |
| B. Dùng chung `svp-gitops-promoter` | Một App | Cùng một khoá ở environment của hai repo (lộ một chỗ là mất cả hai); tác giả PR như nhau nên check không biết repo nào mở, chỉ còn tên nhánh do chính token chọn; thu hồi khoá dừng cả hai |

| Rescan | Được | Mất |
| --- | --- | --- |
| **A. Mỗi repo chỉ quét và attest image dưới prefix của nguồn mình** | Attestation `vuln` luôn mang identity của nguồn, đúng thứ policy đòi | Hai lịch rescan |
| B. Backend quét mọi digest như nay | Một lịch | Attestation `vuln` của web mang identity backend: policy chọn attestor theo nguồn sẽ từ chối |

### 5. Script CI dùng chung ([ADR-0023](0023-ci-platform-neutral.md))

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Workflow của `svp-web` checkout backend ở commit ghim (`BACKEND_COMMIT`, như `CHECKER_COMMIT` của `svp-gitops`) và chạy `deploy/ci/*.sh` của commit đó** | Một bản logic; job ký chạy trong workflow của `svp-web` nên identity ký là của `svp-web`; chạy được trên máy; mẫu đã dùng ở `svp-gitops` (ADR-0025 §5) | Đổi script mà `svp-web` dùng cần PR bump commit; script backend phải giữ chạy được với cây `svp-web` |
| B. Chép script sang `svp-web` | Repo tự đủ | Hai bản lệch dần |
| C. Reusable workflow của backend (GitHub) hay CI/CD component (GitLab) | Hiện hành trên cả hai nền tảng [W14][W16] | Logic dời vào YAML (trái ADR-0023); identity ký thành workflow của backend [W17], policy không còn phân biệt nguồn bằng identity; phải mở allow list cho workflow của repo khác; job gọi không dùng được `environment` [W16] |
| D. Repo thứ tư `svp-ci` giữ script dùng chung | Đúng mô hình platform team của công ty lớn | Thêm một repo với CI, ruleset của nó; script gắn với harness `deploy/k8s/lib.sh` của backend phải tách theo |

### 6. Kiểm thử chéo

| e2e ở CI của `svp-web` | Được | Mất |
| --- | --- | --- |
| **A. Compose của backend ở commit `revision` của `envs/stg/charts.yaml`, sáu image backend của stg theo digest, web build từ PR** | Đúng bộ backend đang chạy ở stg; image stg là bản build mới nhất của code từng service tới `revision` (luật tổ tiên cộng quy tắc chỉ build service đổi), nên compose, migrate, seed ở commit đó khớp với image; không build Go trong CI web | Compose backend cần chế độ chạy image phát hành (mới); web được kiểm với backend của stg, không phải của prd |
| B. Cluster k3d đường GitOps | Gần prd nhất | Dựng khoảng 10 phút, nặng, chạy mỗi PR |
| C. Mock (MSW) | Nhanh | Không bắt được lệch hành vi ngoài kiểu (phiên, rate limit, upload, HLS) |

| Backend kiểm gì về web sau tách | Được | Mất |
| --- | --- | --- |
| **A. Image web của stg theo digest cho `smoke`, `load-ci`, `dast`; e2e của `svp-web` ở commit của web stg chạy trên stack build từ PR (chỉ báo, như cả job `stack`)** | Bắt PR backend làm hỏng web đang chạy, kể cả lệch hành vi mà oasdiff không thấy | Một bản clone nữa trong job; e2e đỏ không chặn merge |
| B. Không chạy e2e web ở backend | Đơn giản | Chỉ oasdiff đỡ, hành vi không ai kiểm cho tới lượt CI kế của `svp-web` |

### 7. Đường dev, runner, source map

| Web ở đường dev (`make up`, `make k8s-up`) | Được | Mất |
| --- | --- | --- |
| **A. Mặc định image stg theo digest; `WEB_FROM=clone` build từ thư mục web (`SVP_WEB_DIR`, mặc định `<workspace>/frontend`)** | Team BE chạy stack với bản FE đã phát hành, không cần Node, máy 16 GB bớt một build; dev FE và diễn tập build vẫn có đường | `make up` cần bản clone `svp-gitops` (đường dev k3d đã cần) |
| B. Luôn đòi bản clone `svp-web` | Như hiện nay | Team BE phải cài Node, pnpm, build web mỗi lần |
| C. Luôn image stg | Đơn giản | Không còn đường build web từ mã cho `web-canary`, `dev-k3d` |

| Source map của image `svp-web` cho `drill-k8s-web-obs` | Được | Mất |
| --- | --- | --- |
| **A. Đẩy stage `sourcemaps` của chính lần build thành image `ghcr.io/anhnvcoder/svp-web/web-sourcemaps`, tag theo digest manifest con; kéo ẩn danh** | Không token chéo repo; docker có sẵn; tồn tại lâu như package (artifact lượt chạy hết hạn) | Thêm một package public; map là mã đã công khai nên không ký, toàn vẹn kiểm bằng debug ID như nay (ADR-0019 §9) |
| B. Artifact của lượt `svp-web`, tải bằng `GITHUB_TOKEN` của backend | Như hiện nay | Chưa chứng minh, tài liệu nghiêng về không được [W11][W12] |
| C. Token App hay PAT đọc `actions` của `svp-web` | Chắc chắn tải được | Thêm credential dài hạn ở repo public chỉ để đọc map |
| D. `SVP_WEB_OBS_SKIP_ERRORS=<lý do>` | Không làm gì | Mất phép kiểm frame đã map trên đường GitOps |

### 8. Lịch sử

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. `git filter-repo` trên bản clone tạm: `--path` cho `web/` và `deploy/docker/web.Dockerfile`, `--path-rename` đưa `web/` thành gốc** (người học đã chọn công cụ) | Lịch sử từng file đi theo, kể cả Dockerfile nằm ngoài `web/` [W19] | Hash mới; message nhắc `#<số>` PR của backend thành link sai nếu không sửa |
| B. `git subtree split` | Có sẵn trong git | Một `--prefix` mỗi lần: Dockerfile ngoài `web/` không đi theo |
| C. Không giữ (như [ADR-0025](0025-gitops-config-repo.md) §4) | Commit đầu sạch | Lịch sử code của web là thứ team FE đọc hằng ngày (blame), khác cấu hình |

### 9. Trình tự chuyển

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Brownfield: chuẩn bị ở backend (hai nguồn được nhận), chụp lịch sử, `svp-web` phát hành, cắt `web/` ở backend, gỡ nguồn cũ sau khi prd chạy web mới** | Mỗi bước lùi được; không lúc nào cluster từ chối bản đang chạy | Một cửa sổ đóng băng `web/` ở backend; nhiều PR |
| B. Cắt một lần | Ít bước | Lỗi chỉ lộ sau merge; trong lúc chờ phát hành đầu của `svp-web` không ai phát hành được web |

### 10. Repo `svp-web`

Không có lựa chọn đáng cân nhắc: dùng lại cài đặt của repo backend (ADR-0015 §11) và `svp-gitops` (ADR-0025 §7), chỉ đổi tên.

### 11. Tách web so với monorepo

| | Monorepo (hiện tại) | Ba repo (ADR này) |
| --- | --- | --- |
| Đổi API và web cùng lúc | Một PR, một lượt CI | Hai PR theo thứ tự: backend thêm (minor), phát hành hợp đồng, web nâng ghim và dùng, rồi backend mới bỏ phần cũ (major) |
| Biết web có hỏng vì backend | `make check`, `stack` của cùng PR | oasdiff ở PR backend; e2e của web ở `stack` (chỉ báo) và ở CI `svp-web` với backend stg |
| Nguồn phát hành | Một prefix, một identity | Hai prefix, hai identity, khai ở một file; policy chọn attestor theo prefix |
| Credential ghi `svp-gitops` | Một App | Hai App, hai khoá |
| Đường dev | Một working tree | Backend dùng web stg; build web từ bản clone khi cần |
| Script CI | Một bộ | Một bộ ở backend, `svp-web` chạy ở commit ghim |
| Lịch sử | Một | Web có lịch sử riêng (viết lại hash một lần) |
| Mô hình | Một team | Team FE và team BE riêng, ranh giới là hợp đồng (mục đích học) |

## Quyết định

Chọn 1A (oasdiff, OCI artifact bằng ORAS, semver), 2A (cả ba bảng), 3A, 4A (cả ba bảng), 5A, 6A (cả hai bảng), 7A (cả hai bảng), 8A,
9A, 10. Sáu điểm chờ "Cần người học chọn": bốn là lựa chọn công cụ hay việc người học phải làm (công cụ kiểm breaking, nơi phát hành hợp
đồng, App thứ hai, đường image: dòng 1, 2, 4, 6), hai là cách dùng công cụ đã có (script CI chung, source map: dòng 3, 5). Lý do chung: ranh giới giữa hai team là hợp đồng có version và chữ ký; mỗi
nguồn phát hành có prefix, identity, credential riêng nhưng được khai ở một chỗ mà policy và script cùng đọc; logic CI vẫn một bản
(ADR-0023); mọi thay đổi chart và nguồn đi stg trước prd như digest (ADR-0025 §2).

### 1. Hợp đồng API

- Spec ở backend, `services/gateway/openapi.yaml`, là nguồn duy nhất; Schemathesis (`make dast`) vẫn đọc file đó trong repo.
- **Luật version** (semver của `info.version`, viết thành comment đầu file spec):
  - **major** khi oasdiff thấy ít nhất một thay đổi mức `ERR` (breaking với client) giữa base và PR;
  - **minor** khi không có `ERR` nhưng `oasdiff changelog` có mục (thêm operation, field tuỳ chọn, giá trị enum…);
  - **patch** khi file đổi mà changelog rỗng (mô tả, ví dụ).
  - PR đổi file spec (theo byte) mà `info.version` không lớn hơn của base: đỏ. Version giảm, hay có breaking mà major không tăng: đỏ (ba
    phép kiểm version của oasdiff nâng lên `err` [W2]). Changelog có mục mà chỉ tăng patch: đỏ (script).
  - PR chuẩn bị đổi `0.1.0` thành `1.0.0`: ở `0.y.z` semver cho mọi thay đổi là có thể breaking, luật major không nói gì.
  - Thay đổi breaking đi theo expand/contract: thêm cái mới (minor), web chuyển sang, bỏ cái cũ (major) khi web của stg và prd đều không
    còn dùng.
- **Kiểm ở PR backend:** `deploy/ci/contract.sh check` (mới), target `make api-contract-check BASE=<ref>`, job mới `api-contract` của
  `ci.yml` (base tính như job `buf`), vào `ci-ok`. oasdiff chạy bằng `OASDIFF_IMAGE` ghim digest của `Makefile`, `--network none`
  (spec không có `$ref` ra ngoài); không dùng GitHub Action của oasdiff (allow list ADR-0015 §11, logic ở script theo ADR-0023).
- **Phát hành:** job `contract` (mới) của backend `images.yml`, `deploy/ci/contract.sh publish`, ở mọi lượt build trên `main` (push,
  hay dispatch không rescan, drill, promote prd; idempotent nên dispatch ký bù được bản thiếu chữ ký): `info.version` ở HEAD chưa là
  tag của `ghcr.io/anhnvcoder/short-video-platform/api/gateway` thì đẩy file bằng ORAS (`ORAS_IMAGE` ghim) với tag `<version>`,
  `artifactType` `application/vnd.anhnvcoder.svp.api-contract.v1`, một layer `application/vnd.oai.openapi`, rồi ký keyless digest đó
  bằng cosign, cùng cờ định dạng cũ như image (ADR-0015 §7). Identity
  là `images.yml@refs/heads/main` của backend (nguồn `backend`, mục 2). Tag đã có với cùng layer thì bỏ qua (thiếu chữ ký thì ký bù); khác thì đỏ, không ghi
  đè (hai PR cùng tăng lên một version: PR sau tăng tiếp). Package public (người học bật, như image). Đường `api/gateway` không thuộc
  `services` nào của nguồn nào nên không pod nào chạy được nó (phép 1, mục 2).
- **Ở `svp-web`:** file ghim `api/contract.json` (`repository`, `version`, `digest`); `make generate` kéo artifact theo digest (ORAS),
  `cosign verify` với identity của nguồn `backend` đọc từ `sources.json` ở `BACKEND_COMMIT` (mục 5), rồi sinh `gen/api.d.ts` bằng
  `openapi-typescript` như nay; `make generate-check` ở CI. File spec không commit vào `svp-web`: một nguồn. Renovate nâng `version` và
  `digest` bằng custom manager datasource `docker` (Kiểm chứng sau); không được thì nâng tay bằng `make contract-bump VERSION=<x>`.

### 2. Image và nguồn phát hành

- Image web: `ghcr.io/anhnvcoder/svp-web/web`; source map: `ghcr.io/anhnvcoder/svp-web/web-sourcemaps` (mục 7). Identity ký:
  issuer `https://token.actions.githubusercontent.com`, subject
  `https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main`.
- **Một chỗ:** `deploy/helm/svp-policy/files/sources.json` (mới) của backend, dạng:

  ```json
  {
    "sources": [
      {
        "name": "backend",
        "repository": "https://github.com/anhnvcoder/short-video-platform",
        "imagePrefix": "ghcr.io/anhnvcoder/short-video-platform/",
        "services": ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker", "web"],
        "drillImages": ["drill-vulnerable", "drill-unsigned"],
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main",
        "provenanceRef": "refs/heads/main",
        "promoter": "svp-gitops-promoter"
      },
      {
        "name": "web",
        "repository": "https://github.com/anhnvcoder/svp-web",
        "imagePrefix": "ghcr.io/anhnvcoder/svp-web/",
        "services": ["web"],
        "drillImages": [],
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "https://github.com/anhnvcoder/svp-web/.github/workflows/images.yml@refs/heads/main",
        "provenanceRef": "refs/heads/main",
        "promoter": "svp-web-promoter"
      }
    ]
  }
  ```

  - `web` trong `services` của `backend` là **nguồn cũ** của lúc chuyển (mục 9); `repository` là `provenanceRepository` của
    [ADR-0027](0027-slsa-build-provenance.md) §4; `drillImages` thay mảng `drill_images` của `common.sh`: image diễn tập phải qua phép 1 để
    tới đúng phép kiểm mà ca diễn tập nhắm (chữ ký, CRITICAL).
  - Rời `values.yaml`: `imagePrefix`, `issuer`, `subject`, `provenanceRepository`, `provenanceRef`. Ở lại: `mode`, `namespace`,
    `maxAttestationAge`, `requireProvenance`, `name`, `objectSelector`. Overlay `envs/<env>/svp-policy.yaml` của `svp-gitops` vẫn chỉ
    `requireProvenance`.
  - Template từ chối: tên nguồn trùng; prefix không kết thúc `/` hay là tiền tố của prefix khác; giá trị có nháy, `\`, xuống dòng (vào CEL);
    một service có ở hơn hai nguồn; `promoter` trùng; `ref` không bắt đầu `refs/`.
- **Policy `svp-images`** (giữ tên): `matchImageReferences` một glob mỗi tên được phát hành (`<prefix><tên>@*`, `<prefix><tên>:*`):
  Kyverno kéo từ registry mọi image khớp glob trước khi chạy phép nào, nên với một glob mỗi prefix, image dưới prefix mang tên nguồn đó
  không phát hành bị từ chối bằng lỗi registry (GHCR `DENIED` cho repository không có) thay vì message phép 1 (lượt `verify.yml`
  [41081463084](https://github.com/anhnvcoder/short-video-platform/actions/runs/41081463084), ca (m)); `attestors` một mục mỗi nguồn; phép 1: mỗi image của pod
  là `<prefix><tên>@sha256:<64 hex>` với `<tên>` thuộc `services` hay `drillImages` của nguồn có prefix đó (hiện nay: mọi tên dưới
  prefix); phép 2–10: image xác minh với attestor của nguồn có prefix của nó (CEL chọn theo `startsWith` của prefix), provenance so
  `subject`, `repository`, `provenanceRef` của nguồn đó; message nêu tên nguồn. Hệ quả cần có: identity `svp-web` không ký được image dưới
  prefix backend và ngược lại. Nếu Kyverno không chọn attestor theo cách này (Kiểm chứng sau), lùi về lựa chọn B (mỗi nguồn một policy).
- **Script:** `release_sources` (mới) của `deploy/k8s/lib.sh` (để `release_image`, `stg_release` của đường dev dùng được không cần
  `common.sh`; `common.sh` source file đó) đọc `sources.json` bằng `jq`, nhận một revision (cây đang chạy hay commit
  của `charts.yaml`) và có đường lùi cho revision chưa có file (mục 3); `sign_identity`, `provenance_source`, `verify-release.sh`,
  `release_image` của `lib.sh` nhận service hay prefix và tra nguồn; `ghcr_prefix` còn là prefix nơi CI backend đẩy image của nó.
  `deploy/k8s/drills/supplychain.sh` hôm nay đọc `imagePrefix`, `issuer`, `subject` của `values.yaml` bằng `sed` (cho ca c, image diễn tập
  dưới prefix) và `maxAttestationAge`: ba dòng đầu chuyển sang `release_sources` (nguồn `backend`), `maxAttestationAge` ở lại `values.yaml`
  (`verify/gitops.sh` cũng chỉ đọc dòng đó). `svp-web` đọc file này ở `BACKEND_COMMIT`. Đổi identity của một nguồn: PR backend thêm identity mới bên cạnh (nhận cả hai),
  chờ stg và prd chạy chart đó, đổi workflow của repo nguồn, rồi gỡ identity cũ.
- **Chuyển tiếp và gỡ nguồn cũ:** web được nhận từ cả hai nguồn cho tới khi prd chạy web của `svp-web`. Gỡ là PR backend bỏ `web` khỏi
  `services` của `backend` (PR-3, mục 9), chỉ mở khi `envs/prd/images/web.yaml` ở `main` của `svp-gitops` đã là bản của `svp-web`. Vì
  nguồn nằm trong chart, chart không còn nguồn cũ tới prd chỉ cùng một bản ghi stg (ADR-0025 §2), mà stg lúc đó đã chạy web của
  `svp-web`: prd không bao giờ nhận chart đó khi còn chạy web cũ. Sau khi gỡ, rollback web về một digest dưới
  `short-video-platform/web` bị Kyverno từ chối ở phép 1 (như rollback về bản trước provenance, ADR-0027 §6): phải revert PR-3 trước.

### 3. Luật của `svp-gitops`

- `gitops-check.sh` đọc `sources.json` ở `revision` của `envs/<env>/charts.yaml` (đúng bản mà Kyverno của env đó áp), rồi với mỗi
  `envs/<env>/images/<svc>.yaml`:
  - `repository` là `<imagePrefix><svc>` của một nguồn có `<svc>` trong `services`;
  - nguồn `backend`: `tag` là tổ tiên của `revision` như nay;
  - nguồn khác: `tag` (12 hex) là commit trên `main` của `repository` của nguồn, đọc từ bản clone đủ lịch sử: `SVP_SOURCE_DIR_<TÊN>` nếu
    đặt, không thì bản clone ẩn danh `--filter=blob:none` mà check tự tạo; không so với `revision`. Khi env bật provenance: `gitCommit` bằng tag (`tag_provenance_mismatch`, đã có) và
    `workflow.repository` bằng `repository` của nguồn.
  - Vì sao web không có luật "không mới hơn chart": chart `svp-service` dùng chung, cấu hình của web nằm ở `base/services/web.yaml` và
    overlay của `svp-gitops`; web cần biến mới thì đi expand/contract qua values như mọi thay đổi cấu hình (ADR-0025 §3). Cái giá: không
    máy nào kiểm thứ tự đó cho web.
- **`revision` chưa có `sources.json`** (commit backend trước PR-1): check chạy mọi env ở mọi PR của `svp-gitops` (`envs="prd stg"` của
  `gitops-check.sh`), và prd còn ghim commit trước PR-1 từ lúc bump `CHECKER_COMMIT` (bước 4, mục 9) tới lần promote prd đầu có chart mới
  (bước 7); rollback prd về một bản ghi stg cũ hơn (ADR-0024 §8) cũng trỏ về commit như vậy. Không có đường lùi thì mọi PR của
  `svp-gitops` đỏ trong khoảng đó, kể cả promote stg của hai bot. Vì vậy `release_sources` (mục 2) nhận một revision và, khi cây ở đó không
  có `deploy/helm/svp-policy/files/sources.json`, dựng **một nguồn `backend`** từ chính cây đó: `imagePrefix`, `issuer`, `subject`,
  `provenanceRepository`, `provenanceRef` đọc từ các dòng của `deploy/helm/svp-policy/values.yaml` (như `sign_identity`, `provenance_source`
  đọc hôm nay), `services` là `svp_services` của `deploy/k8s/lib.sh` ở revision đó (gồm `web`), `drillImages` là `drill_images` của
  `common.sh`, `promoter` là `svp-gitops-promoter`. Với nguồn dựng như vậy mọi luật y như trước ADR này (luật tổ tiên cho cả bảy file). Mọi
  nơi đọc nguồn theo revision (`gitops-check.sh`, `verify-release.sh --gitops`, `release-set.sh`) đi qua cùng hàm nên cùng đường lùi;
  `gitops-check-test.sh` thêm ca: env ghim revision không có `sources.json` và env ghim revision có, trong một cây. Đường lùi bỏ được khi
  không `revision` nào ở `main` của `svp-gitops` và không bản ghi stg nào mà promote prd còn chép tới trước PR-1.
- **Tác giả PR** (bot `<promoter>[bot]` của một nguồn; tác giả đọc qua một hàm `ci_*` mới của `platform.sh` từ sự kiện PR, không qua tên
  nhánh). Bot nào thuộc nguồn nào đọc từ bảng nguồn của env chứa file bị đổi, ở `revision` của env đó **sau** thay đổi (không phải
  `revision` của env kia, cũng không phải cây của checker): giữa bước 4 và 7, prd còn đi đường lùi không biết `svp-web-promoter`, nhưng PR
  tiếp quản ở bước 5 chỉ đổi `envs/stg/`, nên đọc bảng của stg.
  - Luật chỉ chạy khi check có base và lượt là sự kiện PR; push, dispatch, lịch (và trên máy khi không đặt `SVP_CHANGE_REQUEST_AUTHOR`)
    in một dòng `skip`. Lượt PR mà không đọc được tác giả (sự kiện hỏng, login thiếu hay sai dạng) thì đỏ: thà chặn hơn coi như không
    phải PR.
  - Người gửi sự kiện (`sender.login`, người push commit mà lượt `synchronize` kiểm) là bot khác tác giả thì đỏ: bot của nguồn này không
    push được lên PR của bot nguồn khác. Người thật push lên PR của bot thì luật theo tác giả như cũ.
  - Bot của nguồn N chỉ được đổi `envs/stg/images/<svc>.yaml` với `<svc>` trong `services` của N, và image **sau** thay đổi phải thuộc N
    (`<imagePrefix><svc>` của N). Image **trước** phải thuộc N, hay thuộc `backend` (nguồn chủ chart) và cũng là bản của `<svc>`: đó là lần
    **tiếp quản** (bước 5, mục 9: `web.yaml` còn ghi `short-video-platform/web` của nguồn `backend` khi `svp-web-promoter` mở PR đầu); không
    đòi trước và sau cùng nguồn, vì thế thì PR tiếp quản không bao giờ qua. Tiếp quản chỉ một chiều, từ `backend`: image trước của nguồn
    thứ ba hay không là bản nào trong bảng thì đỏ, và bot backend không lấy lại được web (`promote.sh` của backend cũng để nguyên file của
    nguồn khác, mục 4); người học trả web về digest backend bằng PR của mình (cách lùi, mục 9).
  - Riêng bot của **nguồn chủ chart** (nguồn mà chart `deploy/helm/` nằm ở repo của nó: `backend`, cố định trong check, không khai thêm
    khoá) còn được đổi `envs/stg/charts.yaml` (promote stg) và mọi file `envs/prd/images/`, `envs/prd/charts.yaml` (job `promote-prd`, ADR-0024
    §8): nội dung của prd kiểm bằng luật bản ghi stg (bước 1b của `gitops-check.sh`, cả bộ bảy bằng payload), không bằng luật nguồn, nên
    `envs/prd/images/web.yaml` thuộc nguồn nào theo bản ghi. Bot `svp-web-promoter` không được đổi file nào khác (`charts.yaml`, overlay,
    `envs/prd/`). Không bot nào xoá file; bot của một nguồn không đổi gì ngoài `envs/`.
  - Bot `[bot]` không là `promoter` của nguồn nào (Renovate) không đổi gì dưới `envs/`; ngoài `envs/` nó vẫn đổi được (`renovate.json`
    của `svp-gitops` quản `base/`, `components.json`).
  - PR của người học không bị giới hạn ở đây (bypass có ghi, ADR-0025 §7).
- `svp-gitops`: PR bump `CHECKER_COMMIT` lên commit có luật mới và thêm bước clone `svp-web` vào `check.yml` (file có Code Owner).
- **Không đổi:** chart `svp-service` của release `web` ở backend, ghim qua `charts.yaml`; bản ghi stg (payload bảy `repository@digest`,
  `charts`, R) và job `record-stg` ở backend; promote prd chép cả bộ bảy (job `promote-prd` của backend). `release-set.sh` kiểm prefix theo
  nguồn thay `ghcr_prefix`.
- **DORA** (`dora.sh`, [ADR-0028](0028-dora-metrics.md)): deployment đọc như cũ; lead time của web tính từ commit của `svp-web` (bản clone
  thứ ba), của sáu service từ backend.

### 4. Promote

- `svp-web` job `promote` của `images.yml`: chạy `promote.sh` của backend ở `BACKEND_COMMIT` với chế độ nguồn (`--source web`, mới): nhánh
  `bot/promote-stg-web` của `svp-gitops`, chỉ ghi `envs/stg/images/web.yaml`, không đọc và không bao giờ ghi `charts.yaml` (không có phép
  "không mới hơn chart", mục 3); luật không lùi theo tổ tiên trên `main` của `svp-web`; `--force-with-lease`, đọc lại PR sau push, bật
  auto-merge như stg của backend. PR chỉ đổi `envs/stg/` (không Code Owner) nên tự merge khi `gitops-ok` xanh.
  - **Ứng viên của nguồn khác** (file ở `main` hay nhánh bot của `svp-gitops` ghi `repository` không dưới prefix của nguồn mình): hôm nay
    `promote.sh` tra `commit_of` cho mọi ứng viên và một tag không phải commit của `main` làm nó giữ giá trị của `main` và đỏ; với web lúc
    tiếp quản (bước 5, mục 9) tag ở `main` của `svp-gitops` là commit backend, filter-repo đã viết lại nên không có trên `main` của
    `svp-web`. Chế độ `--source` vì vậy **không tra** ứng viên của nguồn khác: bỏ nó khỏi tập so tổ tiên, in một dòng
    `takeover: web.yaml on main is <repository>:<tag> (source backend); first release of source web`, chọn trong các ứng viên còn lại (lượt
    này; nhánh bot nếu đã ghi prefix của mình) và ghi. Luật không lùi chỉ so các ứng viên **cùng nguồn**. Từ lần kế, file ở `main` đã dưới
    prefix `svp-web`, tag là commit của `main` `svp-web`, luật chạy như backend. Một `repository` không thuộc nguồn nào trong `sources.json`
    vẫn là lỗi (không đoán).
- Backend `promote.sh`: chỉ xét service trong `svp_services` của backend **và** có file ở `main` của `svp-gitops` đang ghi prefix backend;
  file ghi prefix nguồn khác thì để nguyên, in một dòng, không đỏ. Từ lúc web của stg là bản `svp-web`, backend không bao giờ ghi lại
  `web.yaml`, kể cả khi một thay đổi `deploy/ci/` build lại cả bảy trước PR-2.
- **Credential:** App `svp-web-promoter` (người học tạo): quyền repository `contents: write`, `pull_requests: write`, `metadata: read`,
  không quyền nào khác; webhook tắt; chỉ cài trên `svp-gitops`. Khoá ở environment `promote` của `svp-web` (deployment branch chỉ `main`,
  không người duyệt): biến `SVP_WEB_APP_CLIENT_ID`, secret `SVP_WEB_APP_PRIVATE_KEY`. Token 1 giờ bằng `actions/create-github-app-token`
  ghim SHA như ADR-0025 §6, chỉ `svp-gitops`. `release-set.sh records` vẫn chỉ nhận bản ghi do App backend tạo.
- **Rescan:** backend `rescan.sh` chỉ digest dưới prefix của nguồn `backend` (theo `sources.json` của `main` backend), gồm web cũ khi một env
  còn chạy nó; file ghi prefix khác thì bỏ qua, không đỏ. `svp-web` chạy `rescan.sh --source web` (mới) hằng ngày với identity của nó, chỉ
  prefix `svp-web`. Không repo nào attest image của nguồn khác.

### 5. Script CI dùng chung

- Mỗi workflow của `svp-web` checkout backend ở `BACKEND_COMMIT` (SHA đủ, ghi một chỗ: file `.backend-commit` ở gốc `svp-web`, workflow và
  `Makefile` cùng đọc; Renovate theo dõi bằng datasource `git-refs` như `CHECKER_COMMIT`) vào thư mục `.backend/` (gitignore), rồi chạy
  script của nó: `build-image.sh`, `scan-gate.sh`, `sign-image.sh`, `provenance-predicate.sh`, `vuln-predicate.sh`, `promote.sh --source
  web`, `rescan.sh --source web`. Ngữ cảnh CI đi qua `platform.sh` của chính checkout đó, đọc biến của lượt `svp-web`.
- Script backend thôi giả định repo của build là backend: repo, prefix đẩy, identity lấy từ `ci_repo` và `sources.json` (nhãn
  `org.opencontainers.image.source` của `oci_labels`, giá trị `local` của `ci_repo`, kiểm `builder.id` của `sign-image.sh`).
- Script riêng của `svp-web` (`Makefile`, runner e2e) source `platform.sh` từ `.backend/`, không chép. `platform-guard.sh` nhận thư mục gốc
  (mới) và chạy trên cây `svp-web` ở job `config` của nó.
- Không reusable workflow: job ký chạy trong workflow của `svp-web`, nên identity ký là
  `svp-web/.github/workflows/images.yml@refs/heads/main` [W17].
- Bảng ánh xạ GitLab cho phần mới (bổ sung bảng của ADR-0023 và ADR-0025 §11):

  | Khái niệm | GitHub (ADR này) | GitLab | Bậc GitLab |
  | --- | --- | --- | --- |
  | Script CI chung ở commit ghim | checkout repo backend ở SHA | clone project backend ở SHA; hay CI/CD component `include: component:` theo SHA hay tag (đổi identity như reusable workflow: chưa kiểm) | Free; component của gitlab.com trên self-managed phải mirror: Premium [W14] |
  | e2e của web cần backend | job dựng compose backend ở commit `revision` | như GitHub; hay multi-project pipeline `trigger: project:` sang project backend | Free [W15] |
  | Lấy file của pipeline project khác | không dùng (map và hợp đồng qua registry) | `needs:project` | Premium [W15] |
  | Credential promote của web | GitHub App thứ hai | project access token thứ hai trên project cấu hình | gitlab.com Premium; self-managed mọi license (ADR-0023) |
  | Hợp đồng, image, source map | GHCR, kéo ẩn danh | Container Registry; OCI artifact của ORAS trên đó: chưa kiểm | Free (ADR-0023) |
  | Chữ ký keyless | Fulcio công khai, identity theo workflow | gitlab.com: `ci_config_ref_uri`; self-managed: Sigstore riêng hay khoá (ADR-0023) | — |

### 6. Kiểm thử chéo

- **CI `svp-web`**, job `stack` (cùng tên và chỉ báo như job `stack` của backend, [ADR-0020](0020-reliability-stage6.md) §15; xét đưa vào `ci-ok` sau 20
  lượt xanh liền không lượt đỏ do môi trường): clone `svp-gitops` ở `main`, đọc `revision` của `envs/stg/charts.yaml` và sáu file image của
  backend; checkout backend ở `revision`; `make up IMAGES=stg WEB_FROM=clone SVP_WEB_DIR=<checkout của PR>` (chế độ mới: `compose_images` của
  `deploy/k8s/lib.sh` đặt biến image mà `deploy/compose/compose.yaml` đọc, `<repository>@<digest>` cho sáu service và bốn job migrate,
  `docker pull` trước rồi `pull_policy: never`, không build Go; `make stg-check` của `svp-web` đòi backend ở đúng `revision`); chạy
  smoke, e2e và Lighthouse (chỉ báo) của PR; `make down` luôn chạy.
- **CI backend:** job `web` của `ci.yml` bỏ (sang `svp-web`); job `stack` chạy `make gitops-clone`, `make up` dùng web của stg theo digest
  (mặc định mục 7), `smoke`, `load-ci`, `dast` như cũ; rồi `make web-clone` ở commit của web stg và `make web-e2e`, `make web-lighthouse`
  (wrapper sang `svp-web`, mục 7) trên stack build từ PR; cả job vẫn chỉ báo.

### 7. Đường dev, runner, source map

- `web_dir` (mới) của `deploy/k8s/lib.sh`, như `gitops_dir`: `SVP_WEB_DIR` nếu đặt, không thì `<workspace>/frontend`; phải là bản clone
  `svp-web` (gốc work tree, `origin` là `svp-web`), không thì in lệnh clone và dừng; đọc working tree, không clone, fetch hay đổi nhánh.
  `make web-clone [WEB_REF=…]` (CI): clone ẩn danh vào `.web/svp-web` (gitignore), checkout `WEB_REF` (SHA đủ hay nhánh; mặc định commit
  của `tag` trong `envs/stg/images/web.yaml` của bản clone `svp-gitops`, để test cùng commit với image đang chạy; web của stg chưa là bản
  `svp-web` thì dừng và đòi `WEB_REF`); job đặt `SVP_WEB_DIR` tới thư mục đó (hàm `web_clone` chỉ export trong shell của nó).
- `make up`, `make k8s-up`: web mặc định là image của stg theo digest (đọc từ bản clone `svp-gitops`; k3d kéo ẩn danh từ GHCR, policy
  Audit ở dev); `WEB_FROM=clone` build từ `web_dir` (`web_build_id` đọc `web_dir`), `WEB_FROM=image WEB_IMAGE=<ghcr.io/…@sha256:…>`
  một bản cho sẵn. Mặc định đổi ở PR-2 (trước đó không đặt `WEB_FROM` là `clone`, và `web_dir` lùi về `web/` của repo này khi không có
  bản clone).
- Target cần mã web (`web-e2e`, `measure-web`, `measure-upload`, `web-lighthouse`, `web-sourcemaps`, `k8s-web-e2e`, `k8s-web-sourcemaps`,
  `drill-k8s-web-canary`) giữ tên trong `Makefile` backend để bước của `verify.yml` không đổi, và thành wrapper gọi target của `svp-web`
  trong `web_dir`. Mã test và đo (spec e2e, `lighthouse/run.sh`, client canary, `measure-upload.e2e.ts`) ở `svp-web`; harness (stack,
  cluster, `deploy/compose/lib.sh`, `deploy/k8s/lib.sh`, xoá khoá rate limit) ở backend. `svp-web` tìm backend qua `SVP_BACKEND_DIR`
  (mặc định `<workspace>/backend`; CI: checkout của bước đó). Không target nào chép giữa hai repo.
- Kịch bản `verify.yml`: `compose-obs`, `dev-k3d`, `web-canary`, `gitops` chạy `make web-clone` trước bước dựng (bước riêng
  `verify-run.sh --clones`, trước khi cài Node theo `.nvmrc` của bản clone); `dev-k3d` và `web-canary`
  đặt `WEB_FROM=clone` (diễn tập build từ mã như nay), `compose-obs` và `gitops` dùng image stg; input mới `web_ref` của `verify.yml` đổi
  commit.
- **Source map:** mỗi chân build web của `svp-web` (amd64, arm64) đẩy stage `sourcemaps` của chính lần build đó (cùng cache nên cùng bundle,
  ADR-0019 §9) thành image `ghcr.io/anhnvcoder/svp-web/web-sourcemaps`, tag `<arch>-<hex của digest manifest con>`, bằng ORAS ghim
  (`ORAS_IMAGE`, công cụ đã thêm cho hợp đồng ở mục 1; OCI artifact một layer tar+gzip của `_next/`, không cần `Dockerfile` hay build), sau
  khi đẩy image. Tag đã có thì so theo nội dung (cây file), không ghi đè. `gitops-sourcemaps.sh fetch`: web của stg dưới prefix `svp-web`
  thì kéo ẩn danh image map theo manifest `linux/amd64` của digest đang chạy, lấy `_next/` ra; dưới prefix backend thì đường artifact cũ
  (bỏ khi không env nào còn chạy web cũ). Kéo không được: trên nhánh `skipped` như nay (kèm `SVP_WEB_OBS_SKIP_ERRORS=<lý do>`), trên
  `main` `fail`. Không tải artifact chéo repo, không PAT. Lần kiểm thật đầu là bản phát hành đầu của `svp-web` và lượt `gitops` trên `main`
  sau nó. `web-sourcemaps` không thuộc `services` hay `drillImages` của nguồn nào nên không pod nào chạy được nó.

### 8. Lịch sử

- Bản clone tạm, mới, của `main` backend ở commit S (mục 9), rồi:

  ```sh
  git filter-repo --path web/ --path deploy/docker/web.Dockerfile \
    --path-rename web/: --path-rename deploy/docker/web.Dockerfile:Dockerfile
  ```

  `web/` thành gốc; Dockerfile thành `Dockerfile` ở gốc, context là gốc repo (đường `../deploy/docker/web.Dockerfile` của compose và
  `dockerfile web` đổi theo).
- Kiểm lúc chạy (chưa đọc tài liệu cho hai điểm này): commit chỉ đụng đường khác bị bỏ; message nhắc `#<số>` được viết lại thành
  `anhnvcoder/short-video-platform#<số>` (`--replace-message`) để không trỏ nhầm PR của `svp-web`.
- `commit-map` của filter-repo (commit cũ → mới) giữ làm bằng chứng trong `plans/` (không commit vào repo nào): tag 12 hex của image web
  cũ tra được commit tương ứng ở `svp-web`.
- Người điều phối push lên `main` rỗng của `svp-web`; commit kế tiếp thêm CI, `Makefile`, `README.md` và đổi đường. Không viết lại lịch sử
  backend; backend bỏ `web/` bằng PR thường (PR-2).

### 9. Trình tự chuyển, đóng băng, cách lùi

1. ADR chấp nhận. Người học tạo repo `svp-web` (public, rỗng), App `svp-web-promoter` cài trên `svp-gitops`, environment `promote` của
   `svp-web` với biến và secret ở mục 4.
2. **PR-1 backend (chuẩn bị, web chưa rời):** `sources.json` hai nguồn (`web` ở cả hai), policy chọn attestor theo nguồn, script theo nguồn
   (`promote.sh` bỏ qua file của nguồn khác, `rescan.sh`, `gitops-check.sh` với luật và tác giả PR, `release-set.sh`, `verify-release.sh`),
   job `api-contract` và `contract` (spec `1.0.0`), chế độ `IMAGES=stg` của compose, `web_dir`, `web-clone`, đường source map mới,
   `renovate.json` bỏ qua `web/**`. Merge; hợp đồng `1.0.0` được phát hành.
3. **Chụp lịch sử** ở commit S của `main` backend (sau PR-1), filter-repo, push `svp-web`. **Đóng băng bắt đầu:** từ S tới khi PR-2 merge,
   không merge thay đổi nào dưới `web/` hay `deploy/docker/web.Dockerfile` ở backend, kể cả PR Renovate npm (đã chặn ở bước 2). Thay đổi
   web từ đây làm ở `svp-web`.
4. PR ở `svp-gitops`: bump `CHECKER_COMMIT` lên PR-1, thêm clone `svp-web` vào `check.yml`. prd lúc này còn ghim `revision` trước PR-1:
   check đọc nguồn qua đường lùi của mục 3, nên PR này và mọi PR sau nó vẫn xanh.
5. `svp-web`: CI xanh, người học nhập ruleset và cài đặt (mục 10); bản phát hành đầu từ `main`, PR `bot/promote-stg-web` tự merge, stg
   chạy web của `svp-web`. Lượt `gitops` của backend `verify.yml` trên `main`: policy nhận web mới, e2e và source map của image mới.
6. **PR-2 backend (cắt):** trước merge, `git diff S origin/main -- web deploy/docker/web.Dockerfile` rỗng (đóng băng được giữ); xoá `web/`,
   `deploy/docker/web.Dockerfile`, job `web` của `ci.yml`; danh sách image repo này build (`built_services` của `deploy/k8s/lib.sh`,
   sáu) tách khỏi danh sách bảy bản triển khai (`svp_services`, giữ `web`: rescan, promote prd, bản ghi stg, check `svp-gitops`, DORA
   vẫn đọc đủ bảy); target web thành wrapper; `stack` và kịch bản dùng web
   stg hay bản clone; `renovate.json` bỏ luật của web. Kịch bản `dev-k3d`, `compose-obs`, `web-canary` trên nhánh xanh. Merge: **hết đóng
   băng**.
7. Promote prd một bản ghi stg có web của `svp-web` (người học duyệt PR prd).
8. **PR-3 backend:** bỏ `web` khỏi `services` của nguồn `backend` (chỉ khi bước 7 đã merge); tới stg rồi prd qua `charts.yaml` như mọi
   thay đổi chart.

Cách lùi:

- Trước bước 5: không cluster nào đổi; PR-1 tương thích ngược (policy nhận cả hai nguồn, backend vẫn build web).
- Sau bước 5, trước PR-2: web mới hỏng thì PR ở `svp-gitops` trả `envs/stg/images/web.yaml` về digest web của backend (vẫn là nguồn được
  nhận); backend vẫn có `web/` và build được.
- Sau PR-2, trước PR-3: revert PR-2 để backend build lại web; trả `web.yaml` về digest backend như trên.
- Sau PR-3: revert PR-3 trước (nguồn cũ trở lại, đi stg rồi prd), rồi như trên.
- Không xoá `svp-web`; không viết lại lịch sử backend.

### 10. Repo `svp-web`

- Cây: gốc là web (`package.json`, `src/`…, `e2e/`, `lighthouse/`), `Dockerfile`, `Makefile` (target web chuyển từ backend:
  `check`, `generate`, `generate-check`, `lockfile-scan`, `e2e`…, cùng kiểm Node và pnpm), `api/contract.json`, `.backend-commit`,
  `.github/workflows/ci.yml` (lint, test, build, `generate-check`, `lockfile-scan`, `platform-guard`, e2e chỉ báo), `.github/workflows/images.yml`
  (build hai kiến trúc, quét, ký, provenance, source map, promote, rescan hằng ngày), `.github/rulesets/main.json`, `renovate.json`,
  `README.md`.
- **Check tổng:** `ci-ok` và `images-ok`, cùng tên và ý nghĩa như backend (mỗi repo một không gian tên).
- **Ruleset `main`:** PR bắt buộc, `ci-ok` và `images-ok` từ app GitHub Actions, cấm xoá và force push, không ai bypass; 0 approval (như
  backend: cổng triển khai nằm ở `svp-gitops`). Không CODEOWNERS (backend cũng không).
- **Cài đặt** như `svp-gitops` (ADR-0025 §7) ở điểm khác backend, còn lại như repo backend (ADR-0015 §11): quyền mặc định của `GITHUB_TOKEN`
  chỉ đọc; "Allow GitHub Actions to create and approve pull requests" **tắt** như `svp-gitops` (backend bật nó, ADR-0015 §11; `svp-web`
  không cần: PR promote mở bằng token App ở `svp-gitops`, không workflow nào của `svp-web` mở hay duyệt PR trong chính nó); Actions chỉ
  action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc; duyệt workflow của PR fork cho mọi người ngoài; secret scanning và
  push protection; Dependabot alerts; CodeQL default setup (`actions`, `javascript-typescript`, như
  [ADR-0030](0030-devsecops-supplement.md) §4); package GHCR `svp-web/web`, `svp-web/web-sourcemaps` public.
- **Renovate:** App Mend cài thêm `svp-web`; `renovate.json` mang các luật web của backend (ghim npm chính xác, nhóm npm non-major, nhóm
  `sentry`, nhóm Node gồm `.nvmrc`, `engines` và base image của `Dockerfile`), action, `.backend-commit` (`git-refs`), `api/contract.json`
  (custom manager); cùng lịch thứ Bảy, `minimumReleaseAge` 3 ngày, không automerge.

## Cần người học chọn

Đề xuất đứng trước (a). Trạng thái ngành đọc ngày 2026-10-30; nhãn là nhận định của ADR từ nguồn ghi bên cạnh.

| # | Câu hỏi | Lựa chọn và trạng thái ngành | Nguồn | Đề xuất |
| --- | --- | --- | --- | --- |
| 1 | Công cụ kiểm breaking của hợp đồng | (a) oasdiff: **hiện hành** (v1.35.0 ngày 2026-10-28, 3.1 GA, phép kiểm version). (b) openapi-changes: **mới nổi** (v0.2.x, 3.0–3.2). (c) openapi-diff: **cũ** (Java, README chỉ ghi 3.0, vẫn có bản 2026). (d) Optic: **dừng** (archive 2026-01-12) | [W1]–[W6] | (a): đủ 3.1 cho spec hiện tại, phép kiểm version có sẵn, chạy được trên máy bằng image ghim |
| 2 | Nơi phát hành hợp đồng | (a) OCI artifact bằng ORAS, ký cosign: **hiện hành** (ORAS CNCF Sandbox, bản 2026-10-24; GHCR hỗ trợ OCI artifact; cosign ký mọi thứ trong registry). (b) Image `FROM scratch` bằng docker có sẵn: không phải cách chuẩn cho artifact không chạy (nhận định, không nguồn). (c) GitHub Release + `cosign sign-blob`: **hiện hành**, tải ẩn danh chưa xác nhận trong tài liệu. (d) npm trên GitHub Packages: **hiện hành nhưng cần token** kể cả gói public | [W7]–[W10] | (a). Không muốn thêm ORAS thì (b): cùng chữ ký và digest, đổi lấy một artifact đội lốt image |
| 3 | Cách `svp-web` dùng script CI chung | (a) checkout backend ở commit ghim: **hiện hành** (`actions/checkout` v7 có input `repository` và `ref` nhận SHA [W20]; cùng mẫu `CHECKER_COMMIT` của `svp-gitops`, ADR-0025 §5). (b) reusable workflow / GitLab CI/CD component: **hiện hành**, nhưng identity ký thành workflow của repo được gọi. (c) chép script: **cũ** (nhận định: hai bản lệch dần, không nguồn). (d) repo thứ tư: **hiện hành ở tổ chức lớn** (mô hình platform team; nhận định, không nguồn) | [W14], [W16], [W17], [W20] | (a): một bản logic, identity ký vẫn là của `svp-web` |
| 4 | Credential promote của `svp-web` | (a) App thứ hai `svp-web-promoter`. (b) dùng chung `svp-gitops-promoter`. Không phải lựa chọn công cụ: GitHub App đã chốt ở ADR-0025 §6, đây chỉ chọn một hay hai App | ADR-0025 §6 | (a): khoá riêng, tác giả PR phân biệt được, check giới hạn được bot. Người học tạo App |
| 5 | Source map của image `svp-web` cho `drill-k8s-web-obs` | (a) image `web-sourcemaps` trên GHCR, kéo ẩn danh: cùng cơ chế OCI artifact công khai như dòng 2 (**hiện hành** cho artifact trên registry [W7]; chở file bằng image docker là cách của ADR này, nhận định, không nguồn). (b) artifact của lượt `svp-web` bằng `GITHUB_TOKEN` của backend: tài liệu nghiêng về không được. (c) token App hay PAT đọc `actions`: **hiện hành** (cách README của `download-artifact` nêu cho repo khác [W12]), nhưng là credential dài hạn chỉ để đọc map | [W7], [W11], [W12] | (a), lùi: `skipped` có lý do trên nhánh |
| 6 | Đường image của web | (a) `ghcr.io/anhnvcoder/svp-web/web`. (b) giữ `…/short-video-platform/web`. Không phải lựa chọn công cụ | — | (a): mỗi repo đẩy dưới prefix của mình, policy chọn attestor theo prefix |

Các điểm còn lại (luật version, một policy nhiều attestor, luật `svp-gitops` theo nguồn, e2e trên compose stg, web stg ở đường dev, trình
tự) là quyết định thiết kế theo đề xuất; người học đổi được khi duyệt.

## Kiểm chứng sau

Chỉ kiểm được sau push (repo `svp-web` chưa có, App thứ hai chưa tạo, ghi GHCR và Sigstore chỉ trong CI). Mỗi dòng nêu phép kiểm; kết quả và
ngày ghi vào cột cuối.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Lượt `contract` đầu đẩy được OCI artifact bằng ORAS lên GHCR, ký keyless, package public kéo ẩn danh; tag không bị ghi đè | Sau merge PR-1: `cosign verify` với identity backend trên `ghcr.io/anhnvcoder/short-video-platform/api/gateway@<digest>` không đăng nhập; chạy lại job thì "bỏ qua", đổi spec mà không tăng version thì PR đỏ | Đạt phần đẩy và tải (2026-10-30): lượt `images.yml` [41079830814](https://github.com/anhnvcoder/short-video-platform/actions/runs/41079830814) phát hành `1.0.0` (`sha256:141b0b10…`), kéo ẩn danh 200; `make generate-check` của `svp-web` kiểm digest và chữ ký identity backend trên máy và ở CI ([41108867928](https://github.com/anhnvcoder/svp-web/actions/runs/41108867928)). Chạy lại job, PR đổi spec không tăng version: chưa có lượt thật (ca có ở `contract-test.sh`) |
| Renovate nhận bản hợp đồng mới qua custom manager datasource `docker` trên OCI artifact (tài liệu không nói [W18]) | PR backend tăng minor, lượt Renovate kế ở `svp-web` mở PR nâng `api/contract.json` | Chưa kiểm (chưa có version thứ hai) |
| Kyverno v1.19 chọn attestor theo prefix trong một policy: image `svp-web` nhận, image dưới prefix `svp-web` ký bằng identity backend bị từ chối, và ngược lại | Ca `m` của `make drill-k8s-supplychain` trên kịch bản `gitops`: trước bản phát hành đầu của `svp-web` chỉ phần tên chạy (`svp-web/gateway` bị phép 1 từ chối), phần identity SKIP; sau bản đó, digest web của `svp-web` dưới prefix backend và digest web cũ của backend (image ca `l`) dưới prefix `svp-web` bị phép chữ ký từ chối nêu đúng nguồn, web của `svp-web` được nhận | Đạt (2026-10-30), cách kiểm đổi: đặt digest của nguồn này dưới prefix nguồn kia chỉ nhận lỗi registry (GHCR không có manifest đó), nên ca chéo identity gửi bản phát hành đang chạy dưới bản sao tạm của policy đổi chéo identity hai nguồn. Lượt `gitops` trên `main` [41098400504](https://github.com/anhnvcoder/short-video-platform/actions/runs/41098400504) (trước bản `svp-web`): tên lạ dưới prefix `svp-web` bị phép 1 từ chối, chiều web → backend PASS; [41112757906](https://github.com/anhnvcoder/short-video-platform/actions/runs/41112757906) (stg chạy web của `svp-web`): hai chiều PASS với message nêu nguồn, bản `svp-web` được nhận dưới Enforce. Glob mỗi prefix ban đầu làm tên lạ bị lỗi registry ([41081463084](https://github.com/anhnvcoder/short-video-platform/actions/runs/41081463084)), sửa thành glob mỗi tên (PR #45) |
| Lượt `images.yml` đầu của `svp-web`: image dưới prefix `svp-web` ký với identity `svp-web`, provenance có `workflow.repository` là `svp-web`, `verify-release.sh` của backend qua | Bước 5 của trình tự: `cosign verify`, `cosign verify-attestation --type slsaprovenance1`, check của `svp-gitops` trên PR promote | Đạt (2026-10-30): [41111181126](https://github.com/anhnvcoder/svp-web/actions/runs/41111181126) build, ký `svp-web/web@sha256:d2c90e46…`; `cosign verify` identity `svp-web` rc 0, identity backend rc 12; provenance `builder.id` của nguồn `web`, `gitCommit` `8dd59c9`; một attestation `vuln` hai nền tảng; check của PR #22 [41112183849](https://github.com/anhnvcoder/svp-gitops/actions/runs/41112183849) qua |
| Token App thứ hai mở PR `bot/promote-stg-web`, PR tự merge sau `gitops-ok`; check từ chối PR của bot web đổi file khác `envs/stg/images/web.yaml` | Bước 5; PR thử của bot web đổi `envs/stg/charts.yaml` (đỏ) | Đạt phần mở và tự merge: PR #22 của `svp-gitops` (tác giả, người merge `svp-web-promoter[bot]`, chỉ `envs/stg/images/web.yaml`, merge `d9dcc82`). PR thử đổi `charts.yaml`: chưa kiểm (ca âm có ở `gitops-check-test.sh`) |
| Tiếp quản: PR đầu của bot web (image trước thuộc nguồn `backend`) qua luật tác giả; `promote.sh --source web` in dòng `takeover` thay vì đỏ; PR kế dùng luật không lùi trên `main` của `svp-web` | Bước 5, hai lượt `images.yml` đầu của `svp-web` (luật tác giả và chế độ `--source` còn có ca ở `gitops-check-test.sh`, `promote-test.sh`, kiểm được trước push) | Đạt lần tiếp quản: check của PR #22 in `takes web over from release source backend`, `1 changed files are all files its source may change`. PR kế dưới luật không lùi: chưa có bản thứ hai |
| Backend `promote.sh` để nguyên `web.yaml` của nguồn khác; rescan hai repo mỗi bên chỉ attest image của mình | Lượt `images.yml` backend đầu sau bước 5 (dòng "web: released by svp-web"), lượt rescan hằng ngày của cả hai | Chưa kiểm (chưa có lượt backend nào sau bản web đầu, đọc 2026-10-30) |
| Image `web-sourcemaps` kéo ẩn danh được, `drill-k8s-web-obs` PASS phép `errors` với image của `svp-web` | Lượt `gitops` trên `main` sau bản phát hành đầu của `svp-web` | Đạt (2026-10-30): [41112757906](https://github.com/anhnvcoder/short-video-platform/actions/runs/41112757906) kéo `svp-web/web-sourcemaps:amd64-d382029b…` ẩn danh, 30 map, mọi chunk `/login` có debug ID trong bộ map; `drill-k8s-web-obs` `errors` PASS có frame đã map, không `SVP_WEB_OBS_SKIP_ERRORS` |
| e2e của `svp-web` chạy trên compose backend ở `revision` với sáu image stg; `stack` của backend chạy với web stg và e2e của `svp-web` | Lượt CI đầu của mỗi repo sau PR-1 và PR-2 | Đạt phía `svp-web`: PR #1 [41108867928](https://github.com/anhnvcoder/svp-web/actions/runs/41108867928), job `stack` xanh (smoke qua; e2e suy từ kết luận job, log của GitHub bị cụt). Phía backend sau PR-2: chưa chạy |
| Gỡ nguồn cũ: rollback web về digest backend bị từ chối đúng message của phép 1 | Ca mới của `drill-k8s-supplychain` sau PR-3 | Chưa kiểm (PR-3 chưa) |
| DORA tính lead time của web từ lịch sử `svp-web` | Lượt `dora.yml` sau bản phát hành đầu của `svp-web` | Chưa kiểm |

## Kết quả

Lượt thật theo trình tự của mục 9 (bằng chứng: `results.tsv` và log của artifact `verify-gitops`, log job, `cosign` ẩn danh):

- **PR-1 trên nhánh** (PR #43, 2026-10-30): `ci` [41073538624](https://github.com/anhnvcoder/short-video-platform/actions/runs/41073538624) và `images` [41073538643](https://github.com/anhnvcoder/short-video-platform/actions/runs/41073538643)
  xanh (14/14 chân `build-nopush`); `verify.yml` `gitops` [41068690228](https://github.com/anhnvcoder/short-video-platform/actions/runs/41068690228) 18/18 bước (policy cũ: kịch bản dựng
  chart ở `revision` của `main`), `dev-k3d` [41068705757](https://github.com/anhnvcoder/short-video-platform/actions/runs/41068705757) 14/14 (policy mới ở Audit). Enforce của policy mới chưa
  chứng minh được trên nhánh.
- **PR-1 trên `main`** (`28bf2ca`): `images.yml` [41079830814](https://github.com/anhnvcoder/short-video-platform/actions/runs/41079830814) dựng bảy bản, phát hành hợp đồng `1.0.0`, PR bot #13
  của `svp-gitops` tự merge. Lượt `gitops` đầu [41081463084](https://github.com/anhnvcoder/short-video-platform/actions/runs/41081463084) đỏ ở một ca: tên lạ dưới prefix `svp-web` bị từ chối bằng
  lỗi registry thay vì phép 1 (vẫn từ chối, fail-closed); sửa ở PR #45 (glob mỗi tên), lượt lại [41098400504](https://github.com/anhnvcoder/short-video-platform/actions/runs/41098400504) 18/18,
  Enforce nhận bảy bản, bản ghi stg Deployment `7445904100`.
- **`svp-web` PR #1** (repo base, CI, image): `ci` [41108867928](https://github.com/anhnvcoder/svp-web/actions/runs/41108867928) và `images` [41108867921](https://github.com/anhnvcoder/svp-web/actions/runs/41108867921) xanh;
  check của PR #20 ở `svp-gitops` ([41106509655](https://github.com/anhnvcoder/svp-gitops/actions/runs/41106509655)). Lighthouse của job `stack` vượt ngưỡng LCP, TBT trên runner (chỉ
  báo).
- **Bản phát hành đầu của `svp-web`** (`8dd59c9`): [41111181126](https://github.com/anhnvcoder/svp-web/actions/runs/41111181126); PR #22 của `svp-gitops` do `svp-web-promoter[bot]`
  mở, check [41112183849](https://github.com/anhnvcoder/svp-gitops/actions/runs/41112183849) qua, tự merge `d9dcc82`. Lượt `gitops` trên `main` backend [41112757906](https://github.com/anhnvcoder/short-video-platform/actions/runs/41112757906):
  18/18 bước, stg chạy web `ghcr.io/anhnvcoder/svp-web/web@sha256:d2c90e46…` dưới Enforce, ca chéo nguồn của `drill-k8s-supplychain`
  PASS, `k8s-web-e2e` 66 test qua, source map từ image `web-sourcemaps`, bản ghi stg Deployment `7447977996` (`images.web` là bản
  `svp-web`).
- **PR-2** (cắt `web/`, nhánh `feat/stage6b-svp-web-cut`): kiểm trên máy (`make check`, test của `deploy/ci/`); CI và các kịch bản
  `verify.yml` trên nhánh: chưa chạy.

## Hệ quả

- **Được:**
  - Ranh giới FE/BE là một hợp đồng có version, kiểm breaking bằng máy ở PR backend, phát hành có chữ ký, web ghim theo digest.
  - Mỗi nguồn phát hành có prefix, identity, credential riêng; lộ khoá hay identity của một repo không ký hay promote được image của repo
    kia; mọi nguồn vẫn khai ở một file, đi stg trước prd như chart.
  - Team BE chạy stack không cần mã FE; team FE kiểm với đúng backend của stg.
  - Bài học GitLab: bảng ánh xạ cho script chung, multi-project, credential thứ hai.
- **Phải trả:**
  - Đổi API mà web dùng thành ít nhất hai PR ở hai repo, theo thứ tự; breaking cần ba bước expand/contract.
  - Thêm hai công cụ (oasdiff, ORAS) nếu chọn đề xuất; thêm một App, một khoá dài hạn ở environment của `svp-web`.
  - Web mất phép kiểm "image không mới hơn chart"; thứ tự cấu hình trước code của web chỉ là quy ước.
  - `svp-web` phụ thuộc `main` của backend qua `BACKEND_COMMIT` và `sources.json`; đổi script dùng chung cần PR bump ở `svp-web`.
  - Lịch sử web viết lại hash một lần; một cửa sổ đóng băng `web/` ở backend.
  - e2e chéo chỉ báo: một PR backend làm hỏng web vẫn merge được nếu oasdiff không thấy.
- **Xem lại khi:**
  - Có người thứ hai ở mỗi team: CODEOWNERS và duyệt bắt buộc ở `svp-web`, PR hợp đồng có người của team FE duyệt.
  - Kyverno ghi rõ chọn attestor theo image, hay chọn được không (Kiểm chứng sau): giữ A hay chuyển B của bảng policy.
  - GitHub ghi rõ tải artifact chéo repo bằng `GITHUB_TOKEN`: xét bỏ image `web-sourcemaps`.
  - Có repo thứ ba dùng script chung (giai đoạn 7 có repo `infra/`): xét repo `svp-ci` riêng.
  - Mang CI sang GitLab thật: viết lại bằng component hay multi-project, đo lại (ADR-0023).
- **ADR cũ được chỉnh** (đã ghi "chỉnh bởi 0033" ở trạng thái của cả tám ADR dưới, ở `docs/adr/README.md` và ở mục Hiện thực ở của sáu
  ADR đầu, 2026-10-31):
  - [ADR-0016](0016-web-client.md): vị trí `web/` và các target `web-*` (sang `svp-web`, backend giữ wrapper); dữ liệu §8 (`gen/api.d.ts` sinh
    từ hợp đồng đã phát hành, không từ file trong repo); §10 (danh sách gói npm và Renovate của web ở `svp-web`).
  - [ADR-0019](0019-web-k3d-supply-chain-observability.md) §1 (web rời pipeline chung, đường `ghcr.io/anhnvcoder/svp-web/web`, `SVP_BUILD_ID`
    theo commit của `svp-web`, "Kyverno nhận theo prefix của repo nên policy không đổi" thành chọn attestor theo nguồn); §9 (source map của
    image CI là image `web-sourcemaps` thay artifact lượt chạy).
  - [ADR-0021](0021-deferred-verification-stage6b.md) §3 (kịch bản cần mã web lấy từ `make web-clone`, input `web_ref`, `WEB_FROM`); §6
    (`gitops-sourcemaps.sh` kéo image map); job `stack` của `ci.yml` (web stg, e2e của `svp-web`).
  - [ADR-0023](0023-ci-platform-neutral.md) §4 (identity một chỗ thành `sources.json` nhiều nguồn); §1 (`platform-guard.sh` nhận thư mục gốc,
    chạy cả ở `svp-web`); hàm `ci_*` đọc tác giả PR; bảng ánh xạ thêm dòng của mục 5.
  - [ADR-0025](0025-gitops-config-repo.md) §2 (luật tổ tiên chỉ cho nguồn backend; nguồn khác theo mục 3), §5 (check đọc lịch sử
    `svp-web`, luật tác giả PR), §6 (App thứ hai), mục "Xem lại khi" về App của 4b (đã chốt ở đây).
  - [ADR-0027](0027-slsa-build-provenance.md) §4, §5 (`provenanceRepository`, `provenanceRef`, identity theo nguồn; `verify-release.sh` theo
    nguồn), §6 (rollback về web của nguồn cũ sau khi gỡ bị từ chối như rollback về bản trước provenance).
  - Ngoài sáu ADR trên: [ADR-0015](0015-cicd-devsecops-stage5.md) §3, §7, §9 (`images.yml` backend không build web sau PR-2, thêm job
    `contract`, rescan theo nguồn) và [ADR-0028](0028-dora-metrics.md) (lead time đọc lịch sử ba repo).
- **Tài liệu cập nhật khi hiện thực:** `CLAUDE.md` (mục Kiểm tra: `api-contract-check`, `web-clone`, `WEB_FROM`, `IMAGES=stg`, target web
  thành wrapper, job `api-contract`, bỏ job `web`), `README.md`, `docs/architecture.md`, `docs/ci-cd.md`, `docs/threat-model.md` (khoá App
  thứ hai, identity thứ hai, nguồn cũ, hợp đồng ký), runbook dựng `svp-web` (`docs/runbooks/svp-web-setup.md`, mới, theo mẫu
  [`svp-gitops-setup.md`](../runbooks/svp-gitops-setup.md)).

## Hiện thực ở

PR-1 của mục 9 (phần chuẩn bị ở repo này), merge 2026-10-30 (`28bf2ca`, PR #43; glob mỗi tên của policy ở PR #45, `e66dd58`):

- Hợp đồng (mục 1): `services/gateway/openapi.yaml` (`1.0.0`, luật version ở comment đầu file); `deploy/ci/contract.sh` (`check BASE`,
  `publish [--dry-run]`) và test `deploy/ci/contract-test.sh`; `Makefile` (`OASDIFF_IMAGE`, `ORAS_IMAGE`, target `api-contract-check`);
  job `api-contract` của `.github/workflows/ci.yml` (`ci-ok` đủ tám job), job `contract` của `.github/workflows/images.yml` (trong
  `images-ok`); `deploy/ci/changed-services.sh` (hai script hợp đồng không làm build lại image).
- Nguồn phát hành (mục 2): `deploy/helm/svp-policy/files/sources.json`, `deploy/helm/svp-policy/values.yaml` (năm dòng identity rời
  đi), `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml` (một glob mỗi tên được phát hành, một attestor mỗi nguồn, kiểm bảng lúc render),
  `deploy/helm/svp-policy/Chart.yaml`; `deploy/k8s/lib.sh` (`release_sources` với đường lùi theo revision, `release_source`,
  `source_of_repository`, `release_source_of`, `release_repositories`, `release_image` theo nguồn); `deploy/ci/common.sh`
  (`use_release_source`, `sign_identity` và `provenance_source` nhận tên nguồn, `release_source_in`, `verify_signature` theo prefix,
  `oci_labels` theo nguồn, `drill_images` bằng `drillImages` của `backend`); `deploy/ci/verify-release.sh`;
  `deploy/k8s/drills/supplychain.sh` (prefix và identity qua bảng nguồn, biến `SUPPLYCHAIN_*` nhận prefix của mọi nguồn);
  `deploy/ci/verify/gitops.sh` (`gitops_stale` đọc bằng identity của nguồn); `deploy/k8s/gitops.sh`.
- Luật `svp-gitops` (mục 3): `deploy/ci/gitops-check.sh` (bước 1 theo nguồn với `SVP_SOURCE_DIR_<TÊN>` hay clone ẩn danh, `--tree`;
  bước 1c `author_rule`) và `deploy/ci/gitops-check-test.sh`; `ci_change_request_author` của `deploy/ci/platform.sh` và
  `deploy/ci/platform-test.sh`; `deploy/ci/values-check.sh`; `deploy/ci/release-set.sh` (prefix theo nguồn, `check --at-charts`) và
  test; `deploy/ci/dora.sh` (`--clones`, lịch sử repo của nguồn) và test, `.github/workflows/dora.yml` (bước clone `svp-web` khi cần).
- Promote, rescan (mục 4): `deploy/ci/promote.sh` (`--source`, `--header`, dòng `takeover`, để nguyên file của nguồn khác) và
  `deploy/ci/promote-test.sh`; `deploy/ci/promote-prd.sh` (câu đầu comment của file đổi nguồn) và test; `deploy/ci/rescan.sh`
  (`run`, `list` với `--source`).
- Script dùng chung (mục 5): `deploy/ci/common.sh` (`script_root`, `code_root` theo `SVP_CODE_ROOT`, `use_build_source`,
  `check_code_tree`, `require_code_files`), `deploy/ci/platform.sh` (`ci_repo`, `ci_repo_url`, `ci_commit` trên máy theo
  `SVP_CODE_ROOT`), `deploy/ci/build-image.sh`, `deploy/ci/push-image.sh`, `deploy/ci/merge-index.sh`, `deploy/ci/sign-image.sh`,
  `deploy/ci/provenance-predicate.sh` và test, `deploy/ci/scan-gate.sh`, `deploy/ci/plan.sh` (cây của nguồn khác build mọi service
  của nguồn).
- Đường dev và runner (mục 6, 7): `deploy/k8s/lib.sh` (`web_is_clone`, `web_dir`, `web_dockerfile`, `web_clone`, `stg_release`,
  `web_source`, `compose_images`, `compose_up_images`, `build_dev_images [SERVICE...]`, `web_build_id` và `build_image` đọc `web_dir`);
  `deploy/compose/compose.yaml` (image và `pull_policy` qua biến), `deploy/compose/compose.mk` (`IMAGES`, `WEB_FROM`, `WEB_IMAGE`),
  `deploy/k8s/k8s.mk` (`web-clone`, `k8s-up` với `WEB_FROM`), `deploy/k8s/install.sh`, `deploy/observability/glitchtip/sourcemaps.sh`
  (build từ `web_dir`, từ chối web chạy bản phát hành), `.gitignore` (`.web/`); `deploy/ci/gitops-sourcemaps.sh` (kéo image
  `web-sourcemaps` khi web của stg thuộc nguồn khác) và test.
- Phần còn lại của PR-1 (mục 9 bước 2): `renovate.json` (`ignorePaths` thêm `web/**`, `deploy/docker/web.Dockerfile`: không PR
  Renovate nào cho npm, Node hay image của web ở repo này); `deploy/ci/platform-guard.sh [ROOT]` (`ROOT` là cây của nguồn khác: mọi
  file trừ `.github/`, `.backend/`; không `ROOT` như cũ) và test ở `deploy/ci/platform-test.sh`; input `web_ref` của
  `.github/workflows/verify.yml` (kiểm ở bước đầu như ref), `deploy/ci/verify-run.sh` (`make web-clone WEB_REF=…`, `pnpm install` trong
  bản clone, `SVP_WEB_DIR` cho mọi target; chỉ kịch bản khai `web=1`: `deploy/ci/verify/dev-k3d.sh`, `web-canary.sh`, `gitops.sh`) và
  test ở `deploy/ci/verify-collect-test.sh`; ca `m` của `deploy/k8s/drills/supplychain.sh` (tên của nguồn khác dưới prefix của một
  nguồn bị phép 1 từ chối; bản phát hành của một nguồn đặt dưới prefix của nguồn kia bị phép chữ ký từ chối nêu nguồn đó; bản của nguồn
  khác `backend` được nhận; phần nào cần bản phát hành `svp-web` chưa có thì SKIP) và biến `SUPPLYCHAIN_*` kiểm theo
  `<imagePrefix>(services|drillImages)` của bảng nguồn.
- Cài đặt GitHub do người học làm: [`docs/runbooks/svp-web-setup.md`](../runbooks/svp-web-setup.md).

Sau PR-1, hai script mà CI `svp-web` gọi từ checkout ghim (PR #48, `f59c4ca`, merge 2026-10-30; `.backend-commit` của `svp-web` ghim
commit này):

- Rescan (mục 4): `deploy/ci/rescan.sh run` đòi `--source` bằng nguồn của repo của lượt (`use_build_source`) và `ci_builder_id` bằng
  `subject` của nguồn, trước khi đọc gì; test ở `deploy/ci/platform-test.sh`.
- Source map (mục 7): `deploy/ci/sourcemaps-image.sh push [--dry-run] ARCH DIR` và test `deploy/ci/sourcemaps-image-test.sh` (job
  `config` của `.github/workflows/ci.yml`); `deploy/ci/changed-services.sh` (hai file này không làm build lại image).

PR-2 của mục 9 (cắt `web/`, 2026-10-31, nhánh `feat/stage6b-svp-web-cut`, chưa merge):

- Xoá `web/`, `deploy/docker/web.Dockerfile`. `Makefile`: `check` là `check-go`, `generate` là `generate-go`; target chỉ của web bỏ;
  `web-e2e`, `measure-web`, `measure-upload`, `web-lighthouse`, `web-sourcemaps` là wrapper `IN_WEB` gọi `make e2e`, `measure-web`,
  `measure-upload`, `lighthouse`, `sourcemaps` của `web_dir` với `SVP_BACKEND_DIR`; `deploy/k8s/k8s.mk`: `k8s-web-sourcemaps`,
  `k8s-web-e2e` là wrapper (`k8s-sourcemaps`, `k8s-e2e`), `drill-k8s-web-canary` đọc `web_dir`, help `k8s-up` sáu image.
- `deploy/k8s/lib.sh`: `web_dir` chỉ `SVP_WEB_DIR` hay `<workspace>/frontend`; `built_services` (sáu, repo này build) cạnh
  `svp_services` (bảy bản triển khai); `dockerfile`, `image_paths` không còn `web`; `web_source` mặc định `WEB_FROM=stg`.
  `deploy/k8s/install.sh`, `deploy/compose/compose.mk`, `deploy/compose/compose.yaml` (mặc định web bản phát hành, `pull_policy: never`),
  `deploy/observability/glitchtip/sourcemaps.sh` theo đó.
- CI: `deploy/ci/plan.sh`, `deploy/ci/changed-services.sh` chỉ `built_services`; `deploy/ci/build-image.sh` từ chối `web` của checkout
  này; `.github/workflows/images.yml` bỏ bước source map của web; `.github/workflows/ci.yml` bỏ job `web` và SARIF lockfile, `ci-ok` bảy
  job, job `stack` với `make gitops-clone`, `make web-clone`, web bản stg, `make web-e2e`, `make web-lighthouse` của bản clone;
  `deploy/ci/scan-gate.sh` (`--fs` giữ cho `svp-web`).
- Runner: `.github/workflows/verify.yml` (bước `Clone svp-gitops and svp-web`, Node và Playwright theo bản clone), `deploy/ci/verify-run.sh`
  (`--clones`), `deploy/ci/verify/compose-obs.sh` (`web=1`), `dev-k3d.sh`, `web-canary.sh` (`WEB_FROM=clone`), `gitops.sh`;
  `deploy/ci/verify-collect.sh` (kết quả web ở `.web/svp-web/test-results`); `deploy/k8s/drills/web-canary.sh`, `web-obs.sh`.
- `.trivyignore.yaml` (bỏ mục `@lhci/cli`), `deploy/ci/trivy-config-ignore.yaml`, `renovate.json` (bỏ luật npm, Node, Sentry), `.gitignore`;
  test `deploy/ci/platform-test.sh`, `dora-test.sh`, `deploy/ci/verify-collect-test.sh`, `tools/vulngate/main_test.go`.

Ở repo khác:

- `svp-gitops` (PR #20, 2026-10-30): `.github/workflows/check.yml` (`CHECKER_COMMIT` `28bf2ca`, checkout `svp-web` đủ lịch sử,
  `SVP_SOURCE_DIR_WEB`), `base/services/web.yaml` (comment), `README.md`.
- `svp-web` (PR #1, `8dd59c9`, 2026-10-30): `Dockerfile` ở gốc, `Makefile`, `.backend-commit`, `scripts/backend.sh`, `api/contract.json`,
  `scripts/contract.sh` (`make generate`), `.github/workflows/ci.yml` (`check`, `config`, `gitleaks`, `stack`, `sarif`, `ci-ok`),
  `.github/workflows/images.yml` (`plan`, build, ký, provenance, image `web-sourcemaps`, `promote` với App `svp-web-promoter`, `rescan`,
  `images-ok`), `.github/rulesets/main.json`, `renovate.json`, `.trivyignore.yaml`, `README.md`, `CLAUDE.md`.
- Cài đặt GitHub (người học, theo [`docs/runbooks/svp-web-setup.md`](../runbooks/svp-web-setup.md)): App `svp-web-promoter`, environment
  `promote` của `svp-web` và package `svp-web/web`, `svp-web/web-sourcemaps`, `short-video-platform/api/gateway` public đã dùng ở các lượt
  của mục Kết quả.

Chưa hiện thực:

- PR-3: bỏ `web` khỏi `services` của nguồn `backend` (sau khi prd chạy web của `svp-web`); trước đó promote prd một bản ghi stg có web
  của `svp-web` (bước 7).
- `make contract-bump` (mục 1, chỉ khi Renovate không nâng được `api/contract.json`; chưa cần, Kiểm chứng sau).

## Nguồn

Đọc ngày 2026-10-30.

- [W1] oasdiff, README và trang Releases (v1.35.0 ngày 2026-10-28, "Latest"; v1.34.1 vá bảo mật cho `--open` và GitHub Action; Apache-2.0;
  image `tufin/oasdiff`): <https://github.com/oasdiff/oasdiff>, <https://github.com/oasdiff/oasdiff/releases>
- [W2] oasdiff, `docs/VERSIONING.md` (`api-version-not-bumped`, `api-version-decreased`, `api-major-version-not-bumped`; "Their default
  level is `INFO`, so they never fail a build on their own"; `--severity-levels`, `--fail-on ERR`; version không phải semver bị bỏ qua):
  <https://github.com/oasdiff/oasdiff/blob/main/docs/VERSIONING.md>
- [W3] oasdiff, `docs/OPENAPI-31.md` ("OpenAPI 3.1 support is generally available starting with `v1.15.0`"; `$dynamicRef`/`$dynamicAnchor`
  không phân giải, `pathItems` trong components bị bỏ): <https://github.com/oasdiff/oasdiff/blob/main/docs/OPENAPI-31.md>
- [W4] Optic ("This repository was archived by the owner on Jan 12, 2026"; bản cuối v1.0.9): <https://github.com/opticdev/optic>,
  <https://github.com/opticdev/optic/releases>
- [W5] OpenAPITools openapi-diff (README: "Supports OpenAPI spec v3.0", "Requirements: Java 8", `--fail-on-incompatible`; bản 2.1.7 ngày
  26/1, năm suy ra 2026 từ bản 2.1.6 ngày 26/11): <https://github.com/OpenAPITools/openapi-diff>,
  <https://github.com/OpenAPITools/openapi-diff/releases>
- [W6] pb33f openapi-changes ("Supports OpenAPI 3.2, 3.1 and 3.0"; v0.2.13 ngày 11/10, trang không in năm; action đọc luật từ base):
  <https://github.com/pb33f/openapi-changes>, <https://github.com/pb33f/openapi-changes/blob/main/GITHUB_ACTION.md>
- [W7] ORAS ("We are a Cloud Native Computing Foundation Sandbox Project"; "the de facto tool for working with OCI Artifacts"; GHCR trong
  "Registries supporting OCI Artifacts"; CLI v1.3.6 ngày 2026-10-24): <https://oras.land/docs/>,
  <https://oras.land/docs/compatible_oci_registries>, <https://github.com/oras-project/oras/releases>
- [W8] Sigstore, "Signing Other Types" ("Cosign can sign anything in a registry"; ví dụ đẩy bằng ORAS rồi ký theo digest):
  <https://docs.sigstore.dev/cosign/signing/other_types/>
- [W9] GitHub Docs, "Working with the npm registry" ("You need an access token to publish, install, and delete private, internal, and public
  packages"; chỉ PAT classic):
  <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry>
- [W10] GitHub Docs, "About releases" (không nói tải asset ẩn danh) và REST "Release assets":
  <https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>, <https://docs.github.com/en/rest/releases/assets>
- [W11] GitHub Docs, "GITHUB_TOKEN" ("The token's permissions are limited to the repository that contains your workflow"):
  <https://docs.github.com/en/actions/concepts/security/github_token>
- [W12] `actions/download-artifact`, README mục "Download Artifacts from other Workflow Runs or Repositories" (mặc định chỉ trong lượt hiện
  tại; `github-token` bắt buộc cho repo khác; ví dụ PAT "with actions:read permissions on target repo"):
  <https://github.com/actions/download-artifact>
- [W13] Kyverno, "ImageValidatingPolicy" (Stable, v1.19; `attestors` là danh sách; `verifyImageSignatures(image, [attestors.notary])`; ví
  dụ chỉ một attestor): <https://kyverno.io/docs/policy-types/image-validating-policy/>
- [W14] GitLab Docs, "CI/CD components" (Free; `include: component:`; version theo SHA, tag; "You can only reference components in the same
  GitLab instance as your project"; component gitlab.com trên self-managed phải mirror, Premium): <https://docs.gitlab.com/ci/components/>
- [W15] GitLab Docs, "Downstream pipelines" (multi-project `trigger: project:` ở Free; lấy artifact của pipeline project khác ở Premium):
  <https://docs.gitlab.com/ci/pipelines/downstream_pipelines/>
- [W16] GitHub Docs, "Reuse workflows" (`{owner}/{repo}/.github/workflows/{filename}@{ref}`, "Using the commit SHA is the safest option";
  "The job that calls the reusable workflow can't use the `environment` keyword"):
  <https://docs.github.com/en/actions/sharing-automations/reusing-workflows>
- [W17] GitHub Docs, "OpenID Connect reference" (claim `job_workflow_ref`: với job dùng reusable workflow, là đường tới reusable workflow;
  đọc qua kết quả tìm kiếm trên bản Enterprise Server 3.19 của cùng trang, bản github.com chưa mở lại):
  <https://docs.github.com/en/actions/reference/security/oidc>
- [W18] Renovate, "Custom Manager Support using Regex" và "Docker datasource" (datasource `docker` cho registry tuỳ ý; không nói về OCI
  artifact không phải image): <https://docs.renovatebot.com/modules/manager/regex/>, <https://docs.renovatebot.com/modules/datasource/docker/>
- [W19] `git filter-repo`, README và manual ("recommended by the git project"; `--path`, `--path-rename`; "a rename directive does not select
  paths"; thao tác phá huỷ): <https://github.com/newren/git-filter-repo>,
  <https://github.com/newren/git-filter-repo/blob/main/Documentation/git-filter-repo.txt>
- [W20] `actions/checkout` README ("Checkout v7"; input `repository` "Repository name with owner", mặc định `${{ github.repository }}`; input
  `ref` "The branch, tag or SHA to checkout"; ví dụ "Checkout multiple repos (side by side)"; token mặc định "scoped to the current
  repository" nên repo khác **private** cần PAT, trang không nói về repo public: backend là public, kiểm ở lượt CI đầu của `svp-web`):
  <https://github.com/actions/checkout>
