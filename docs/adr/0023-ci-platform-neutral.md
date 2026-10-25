# 0023. CI trung lập nền tảng: YAML của nền tảng chỉ nối bước, logic ở `Makefile` và `deploy/ci/`, mọi chỗ đọc ngữ cảnh CI hay gọi API nền tảng đi qua adapter `deploy/ci/platform.sh` (hiện thực GitHub Actions và chạy trên máy), identity ký viết ở một chỗ; bảng ánh xạ GitHub ↔ GitLab (gitlab.com và self-managed)

- Trạng thái: Chấp nhận; adapter hiện thực 2026-10-25 (nhánh `github`, `local`), kiểm trên CI thật sau push
- Ngày: 2026-10-25

## Bối cảnh

- Dự án để học DevOps; đi làm có thể gặp GitLab (gitlab.com, hay GitLab self-managed của công ty, phổ biến ở Việt Nam). Người học
  chốt 2026-10-25: thiết kế để mang CI sang nền tảng khác dễ, **chưa chạy thật ở đó**, và chỉ xét hai nền tảng GitHub và GitLab
  (cả phần CI lẫn phần repo: PR, nhánh bảo vệ, registry, token).
- Hiện trạng: [ADR-0015](0015-cicd-devsecops-stage5.md) §1 đã đặt logic ở `Makefile` và `deploy/ci/*.sh` ("this file wires jobs,
  permissions and artifacts"), nhưng chỗ gắn GitHub còn rải ngoài `.github/`: `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`,
  `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_SERVER_URL`, `GITHUB_WORKFLOW_REF`, `GITHUB_ACTIONS` và
  `gh pr`/`gh api`/câu gợi ý `gh workflow run` trong `common.sh`, `plan.sh`, `promote.sh`, `rescan.sh`, `scan-gate.sh`,
  `vuln-predicate.sh`, `values-check.sh`, `deploy/k8s/gitops.sh`, `deploy/k8s/drills/gitops.sh`, `drills/supplychain.sh`;
  `RUNNER_TEMP`, `::add-mask::`, `::warning::` trong `deploy/ci/verify-*.sh`
  ([ADR-0021](0021-deferred-verification-stage6b.md) §4); identity ký keyless viết hai lần (`common.sh` và values của chart
  `deploy/helm/svp-policy`).
- Ràng buộc: không đổi hành vi của ba workflow (`ci.yml`, `images.yml`, `verify.yml`: output, summary, PR promote, attestation có
  link lượt chạy); không thêm công cụ; không viết `.gitlab-ci.yml` lúc này.

## Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Để nguyên, ghi danh sách chỗ phải sửa khi chuyển | Không đổi gì | Biến của GitHub rải trong 10+ script; chuyển nền tảng là đi dò từng file, dễ sót chỗ chỉ lỗi lúc chạy (output mất thì bước sau vẫn "xanh") |
| **Adapter shell: một file `deploy/ci/platform.sh`, mỗi hàm một nhánh theo nền tảng** | Cùng ngôn ngữ, cùng cách chạy của script hiện có; chạy được trên máy; thêm nền tảng là thêm nhánh `case` trong một file; test bằng biến giả | Phải giữ kỷ luật: script mới không đọc biến nền tảng trực tiếp (grep là phép kiểm); một số khái niệm không có tương đương (bên dưới) nên adapter không che được hết |
| Dagger (pipeline viết bằng Go/TypeScript/Python, chạy trong container, YAML chỉ gọi `dagger call`) | Pipeline chạy y hệt trên máy và mọi CI; cache theo bước | Thêm một engine (container BuildKit riêng, CLI phải ghim) và cách viết mới cho mọi bước; vẫn cần adapter cho output, summary, mask, PR của nền tảng; job chạy Docker-in-Docker thay vì Docker của runner, đổi đường build/quét/ký đã kiểm ở ADR-0015 §4 |
| Công cụ pipeline-as-code khác (Earthly, Nix, task runner) | Tương tự Dagger | Cùng cái giá: thêm công cụ chính cho một mảng đã có `Makefile`; không bớt phần gắn nền tảng (token OIDC, PR, nhánh bảo vệ) |
| Viết song song `.gitlab-ci.yml` ngay | Chứng minh mang được | Không có project GitLab để chạy; YAML không chạy là YAML không kiểm được; đổi mỗi thay đổi CI thành hai |

## Quyết định

Chọn **adapter shell**: rẻ nhất, cùng công cụ, kiểm được trên máy. Dagger xét lại khi pipeline cần chạy y hệt ở nhiều nơi thật (ví dụ
dự án công ty chạy GitLab), không phải lúc chỉ có một nền tảng chạy thật.

1. **Nguyên tắc.** YAML của nền tảng (`.github/workflows/*.yml`, sau này `.gitlab-ci.yml`) chỉ nối bước: trigger, quyền, runner,
   service container, cache, artifact, gọi target `make` hay script. Logic ở `Makefile` và `deploy/ci/`. Script nào đọc ngữ cảnh CI
   (biến của nền tảng) hay gọi API của nền tảng (PR, sự kiện, dispatch) thì đi qua hàm `ci_*` của `deploy/ci/platform.sh`.
   Phép kiểm: `deploy/ci/platform-guard.sh`, chạy trong job `config` của `ci.yml` (cùng `platform-test.sh` và
   `verify-collect-test.sh`) và trên máy: grep
   `GITHUB_[A-Z_]+|\bgh (api|pr|run|workflow)\b` trên file đã track và file chưa track không bị ignore của `deploy/` và `Makefile`,
   bỏ symlink (hai cái trỏ tới thư mục, grep đọc thư mục thì exit 2 và mã thoát hết tin được) và file đã xoá khỏi working tree,
   loại `platform.sh`, hai test giả lập job GitHub (`platform-test.sh`, `verify-collect-test.sh`) và chính nó; có dòng khớp thì in
   `file:dòng:` và exit 1. Script mới đọc `$GITHUB_OUTPUT` làm job `config` đỏ ngay ở PR, trước cả commit đầu của nó.
2. **Ngoại lệ có chủ ý, giữ trong YAML:** job `last-success` của `images.yml` gọi `gh api` ngay trong YAML vì job đó giữ
   `actions: read` và không checkout, không chạy code của repo (ADR-0015 §3); các bước `docker login ghcr.io` bằng `GITHUB_TOKEN`;
   `$GITHUB_OUTPUT`, `$GITHUB_ENV`, `$GITHUB_PATH`, `::error::` của chính YAML; `$GITHUB_STEP_SUMMARY` do YAML của `ci.yml` ghi
   thẳng: bảng SARIF (anchor `sarif-summary`: golangci-lint, lockfile web, gitleaks, trivy-config) và dòng bỏ qua của `buf`. Các
   dòng này thuộc file của nền tảng, khi chuyển thì viết lại cùng file đó.
3. **`platform.sh`** (source từ `common.sh`; script không source `common.sh` thì source thẳng). Chỉ định nghĩa hàm; mỗi hàm trả 1
   và in `FAIL  ...` khi lỗi, để script gọi tự dừng. Hai nền tảng được hiện thực:
   - `github`: `GITHUB_ACTIONS=true`;
   - `local`: trên máy, output và summary ra stdout, không mask (in lệnh mask là in chính giá trị), **không ghi gì qua API**: lệnh
     ghi (mở/sửa PR) chỉ in lệnh sẽ chạy. Lệnh đọc (PR đang mở, sự kiện push) vẫn hỏi GitHub bằng `gh` đã đăng nhập trên máy, vì repo
     nằm ở đó. Push git cũng không lên remote mạng: `promote.sh` trên máy chỉ push `bot/promote` khi URL push của `origin` là đường
     dẫn trên đĩa (`/…`, `./…`, `../…`, `file://…`: repo tạm của test). Origin khác (`https://`, `ssh://`, `git@host:`…) thì dừng
     trước khi đọc gì, không in URL (có thể chứa token), gợi ý `PROMOTE_DRY_RUN=1`; với `PROMOTE_DRY_RUN=1` script chạy hết và in
     lệnh push thay vì push. Lý do: `bot/promote` của origin thật là nhánh của PR phát hành CI giữ; push từ máy đẩy commit mới vào PR
     đó trong khi tiêu đề và body vẫn cũ.
   - Nền tảng khác (`GITLAB_CI`, `JENKINS_URL`, `TF_BUILD`, hay `CI` khác rỗng, `false`, `0`) → dừng: "only GitHub Actions and local
     runs are implemented; add a branch in deploy/ci/platform.sh for another CI". Đoán chỗ ghi output hay mask là làm mất nó trong
     im lặng, và bước có output mất vẫn xanh.

   **Tên chốt:**

   | Hàm | `github` | `local` | Nhánh `gitlab` sau này |
   | --- | --- | --- | --- |
   | `ci_platform` | `github` | `local` | `GITLAB_CI=true` |
   | `ci_output KEY VALUE` | dòng `KEY=VALUE` vào `$GITHUB_OUTPUT` | in `KEY=VALUE` | báo cáo dotenv (`artifacts:reports:dotenv`) |
   | `ci_summary [LINE...]` (không đối số: stdin), `ci_summary_tee`, `ci_has_summary` | `$GITHUB_STEP_SUMMARY`; tee ra cả log | stdout | không có trang summary: log hay file artifact |
   | `ci_mask VALUE` | `::add-mask::` (`%` viết `%25`) | không in gì | không có (bên dưới) |
   | `ci_warning MESSAGE` | `::warning::` | `warning: ...` | dòng thường |
   | `ci_temp_dir` | `$RUNNER_TEMP` | `/tmp` | `${TMPDIR:-/tmp}` |
   | `ci_repo` | `$GITHUB_REPOSITORY` | `anhnvcoder/short-video-platform` | `CI_PROJECT_PATH` |
   | `ci_run_id`, `ci_run_url`, `ci_run_attempt_url` | `GITHUB_RUN_ID`, `.../actions/runs/<id>`, `.../attempts/<n>` | `local` | `CI_PIPELINE_ID`, `CI_PIPELINE_URL`, `CI_JOB_URL` |
   | `ci_builder_id` | `$GITHUB_SERVER_URL/$GITHUB_WORKFLOW_REF` | `local` | `https://` + claim `ci_config_ref_uri` |
   | `ci_bot_name`, `ci_bot_email` | `github-actions[bot]` | như `github` (dry run tạo đúng commit của CI) | user bot của project access token |
   | `ci_change_request_list BRANCH BASE`, `ci_change_request_pick`, `ci_change_request_write [--dry-run] NUMBER BRANCH BASE TITLE BODY_FILE` | `gh pr list/edit/create`; chỉ PR do bot mở từ chính repo | đọc qua `gh`; ghi chỉ in `dry run: gh ...` | `glab mr list/create/update` bằng project access token |
   | `ci_dispatch_hint WORKFLOW REF [NAME=VALUE...]` | in `gh workflow run ...` (không chạy) | như `github` | `glab ci run` với `--input` |
   | `ci_push_time SHA` | sự kiện `PushEvent` (100 sự kiện mới nhất) | như `github` (đọc) | events API của project |

4. **Identity ký một chỗ:** issuer và subject chỉ viết ở `imageVerification.issuer`, `.subject` của
   `deploy/helm/svp-policy/values.yaml` (comment "đổi khi đổi nền tảng CI"); `common.sh` (`sign_identity`, dùng bởi
   `verify_signature`, `verify-release.sh`) và `drills/supplychain.sh` đọc hai dòng đó. Bản render của chart không đổi.
5. **`changed-services.sh`:** `platform.sh` nằm trong pipeline image (được `common.sh` source) nên đổi nó build lại cả bảy như đổi
   `common.sh`; `platform-test.sh` và `platform-guard.sh` (test và phép kiểm, chạy ở job `config` và trên máy, không job image nào
   đọc) được loại như `verify-collect-test.sh` (test của bộ lọc artifact, cũng chạy ở job `config`); ADR
   (`docs/`) và values của `svp-policy` không thuộc đường dẫn image nào nên không build gì.
6. **Hành vi:** trên GitHub không đổi (so từng script cũ và mới với cùng biến giả: output, summary, log, lệnh `gh`, predicate `vuln`
   giống từng byte). Trên máy khác có chủ ý: `promote.sh` không mở PR thật mà in lệnh và không push lên origin mạng (mục 3), link
   lượt chạy là `local` thay vì
   `.../actions/runs/` cụt; `verify-mask.sh` không in lệnh mask (trước đây in chính giá trị ra terminal); thư mục tạm mặc định của
   năm script `verify-*` là `/tmp` (trước: `/tmp` hay `$TMPDIR` tuỳ script).

## Bảng ánh xạ CI: GitHub Actions ↔ GitLab CI

Tài liệu đọc ngày 2026-10-25. Bậc giá ghi theo nhãn trên trang tài liệu GitLab; không ghi là có ở Free.

| Khái niệm | GitHub Actions | GitLab CI | Ghi chú khi mang |
| --- | --- | --- | --- |
| File, trigger | `.github/workflows/*.yml`, `on:` | một `.gitlab-ci.yml`; `workflow:rules` quyết có pipeline, `rules:` quyết từng job [L7] | Ba workflow thành một file (hay `include:`), mỗi job có `rules` theo `CI_PIPELINE_SOURCE` |
| Job, thứ tự | `jobs`, `needs` | `stages` + job; `needs` (tối đa 50) thành DAG; `parallel:matrix` (tối đa 200 tổ hợp) [L8] | Ma trận service × kiến trúc của `plan.sh` thành `parallel:matrix` hay pipeline con |
| Runner | hosted `ubuntu-24.04`, `ubuntu-24.04-arm` (repo public miễn phí) | gitlab.com: runner hosted Linux, arm64 `saas-linux-small-arm64` ở mọi bậc, medium/large arm64 chỉ Premium, Ultimate; self-managed: không có runner hosted, tự cài runner [L9] | Nhãn runner nằm ở `plan.sh` (`runner` của ma trận) thành `tags:` |
| Secret, biến | secret (che trong log), `vars` | CI/CD variable: masked (một dòng, không khoảng trắng, ≥ 8 ký tự), masked and hidden (GA 17.6), protected (chỉ pipeline của nhánh/tag bảo vệ) [L3][L4] | Biến protected thay cho "job ghi chỉ chạy trên `main`" |
| Mask giá trị sinh lúc chạy | `::add-mask::` | **không có**: chỉ biến định nghĩa trong cài đặt được che [L3] | Không mang 1-1 (bên dưới) |
| Output giữa bước, giữa job | `$GITHUB_OUTPUT`; `needs.<job>.outputs` | giữa job: báo cáo dotenv (5 KB, không giá trị nhiều dòng, không dùng trong `rules`, số biến có giới hạn: gitlab.com Free 50); trong một job: biến shell [L2] | `legs` JSON của `plan.sh` phải gọn dưới 5 KB, hay thành pipeline con sinh động |
| Summary | `$GITHUB_STEP_SUMMARY` | không có trang summary của job | Bảng của `scan-gate.sh`, `plan.sh` chỉ còn trong log hay artifact |
| Annotation | `::warning::`, `::error::` [G1] | không có | Dòng thường |
| Environment, bảo vệ | environment, required reviewers (gói Free, Pro, Team: chỉ repo public) [G4] | environments (Free); protected environments và deployment approvals: Premium, Ultimate [L10] | Repo này chưa dùng environment |
| Artifact | `upload-artifact`, `retention-days` | `artifacts:`, `expire_in` (gitlab.com mặc định 30 ngày) [L8] | Bộ lọc artifact của `verify-collect.sh` giữ nguyên |
| Cache | `actions/cache` | `cache:` [L8] | Cache trivy DB theo ngày thành `cache:key` |
| Service container | `services:` với `ports: ["127.0.0.1:5432:5432"]` | `services:` [L8]; job gọi service bằng tên host (alias) "instead of a socket or `localhost`" [L19]; executor Kubernetes: service chạy chung pod, "share the same localhost address" [L20] | `internal/pgtest`, `internal/redistest` chỉ nhận `127.0.0.1`: chạy được trên executor Kubernetes; executor Docker phải kiểm, hay dựng DB trong job |
| OIDC token | `permissions: id-token: write`; issuer `https://token.actions.githubusercontent.com` [G3] | `id_tokens:` với `aud`; `iss` là URL của instance; claim `ci_config_ref_uri` (`<host>/<nhóm>/<project>//.gitlab-ci.yml@refs/heads/main`) [L5] | Ký keyless: mục "gitlab.com và self-managed" |
| Ngữ cảnh | `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_SERVER_URL`, `GITHUB_WORKFLOW_REF`, `GITHUB_SHA`, `GITHUB_REF_NAME`, `GITHUB_EVENT_NAME`, `RUNNER_TEMP`, `GITHUB_ACTIONS` [G2] | `CI_PROJECT_PATH`, `CI_PIPELINE_ID`/`CI_PIPELINE_URL`, `CI_JOB_ID`/`CI_JOB_URL` (job chạy lại có id mới), `CI_SERVER_URL`, `CI_CONFIG_PATH`, `CI_COMMIT_SHA`, `CI_COMMIT_REF_NAME`, `CI_PIPELINE_SOURCE`, `CI_MERGE_REQUEST_IID`, `CI_DEFAULT_BRANCH`, `CI_REGISTRY`/`CI_REGISTRY_IMAGE`, `GITLAB_CI` [L1] | Nhánh `gitlab` của `platform.sh` (comment trong file liệt kê) |
| Token của job | `GITHUB_TOKEN`, quyền theo `permissions:` | `CI_JOB_TOKEN`: chỉ một số endpoint; với merge request chỉ `GET`, không mở được MR; push git bằng job token tắt mặc định [L13] | Job promote cần project access token |
| PR, MR pipeline | `pull_request` | merge request pipeline (`CI_PIPELINE_SOURCE == merge_request_event`) [L7] | |
| Lịch | `schedule: cron` | pipeline schedules [L7] | Rescan hằng ngày |
| Chạy tay có input | `workflow_dispatch` + `inputs` | "Run pipeline" hay `glab ci run` (`--input`, `--variables`); biến pipeline mặc định **không ai được đặt** ở project mới trong namespace mới trên gitlab.com (từ 17.7), self-managed mặc định maintainer [L7] | Input `services`, `rescan`, `values_ref`, `drill` của `images.yml`, `scenario` của `verify.yml` nên thành `spec:inputs` |
| Concurrency | `concurrency:` group, `cancel-in-progress` | `resource_group`, `interruptible` | Ngữ nghĩa hàng chờ khác: quy tắc base của ADR-0015 §3 phải xét lại |

## Bảng ánh xạ repo và nền tảng: GitHub ↔ GitLab

| Khái niệm | GitHub | GitLab | Bậc GitLab |
| --- | --- | --- | --- |
| Đề xuất thay đổi | Pull request | Merge request | Free |
| Bảo vệ `main` | ruleset `.github/rulesets/main.json`: cấm xoá, cấm force push, bắt PR, check `ci-ok`, `images-ok` từ app GitHub Actions | protected branch (tắt "Allowed to force push"), merge check "Pipelines must succeed" (cả pipeline, không chọn tên check) [L11] | Free |
| Push rules (chặn commit, tên nhánh, file) | một phần của ruleset | push rules [L11] | Premium, Ultimate |
| Duyệt bắt buộc | ruleset `required_approving_review_count` (repo này đặt 0) | approval rules; ở Free duyệt chỉ là tuỳ chọn, không chặn merge [L11] | Premium, Ultimate |
| Code owners | `CODEOWNERS` + "Require review from Code Owners" [G4] | Code Owners, cần nhánh bảo vệ và bật duyệt của Code Owner [L11] | Premium, Ultimate |
| Registry image | GHCR `ghcr.io/<owner>/<repo>/<svc>` | Container Registry `<registry>/<nhóm>/<project>/<svc>`; gitlab.com: `registry.gitlab.com`; self-managed: `registry_external_url` của công ty [L12] | Free |
| Token của bot mở PR/MR | `GITHUB_TOKEN` với "Allow GitHub Actions to create and approve pull requests" | project hay group access token (tạo user bot); `CI_JOB_TOKEN` không mở được MR [L13] | gitlab.com: Premium, Ultimate; self-managed, Dedicated: mọi license |
| Argo CD đọc repo | deploy key chỉ đọc (SSH), hay HTTPS ẩn danh khi repo public | deploy key (chỉ đọc hay đọc ghi) hay deploy token `read_repository` (không gọi được API) [L14] | Free |
| Webhook cho Argo CD | có | có, khoá `webhook.gitlab.secret` [L18] | Free |
| Quét bí mật | secret scanning + push protection (repo public) | pipeline secret detection (báo cáo JSON ở mọi bậc; widget MR và vulnerability report: Ultimate); secret push protection [L15] | push protection: Ultimate |
| Kết quả quét bảo mật | SARIF lên tab Security (`upload-sarif`) | security report, vulnerability report, security dashboard; nhận SARIF 2.1.0 từ 19.2 [L16] | Ultimate |
| Cập nhật dependency | Renovate (App Mend), Dependabot alerts | Renovate (platform `gitlab`, token scope `api`, vai Developer; tài liệu Renovate không khuyên project access token) [L17]; Dependabot là tính năng của repo GitHub [G5] | Free (Renovate tự chạy theo lịch pipeline) |
| Duyệt chạy CI của PR bot | "Approve workflows to run" (PR do `GITHUB_TOKEN` mở) | không có bước tương đương được kiểm ở đây | — |

## gitlab.com và GitLab self-managed khác nhau ở đâu

- **Ký keyless:** Sigstore công khai (Fulcio) chỉ tin issuer có trong cấu hình của nó: `https://gitlab.com` và vài instance do GitLab
  vận hành (`dev.gitlab.org`, `ops.gitlab.net`, `gitlab.archlinux.org`), không tin instance tự host [L6]. Trên gitlab.com:
  `id_tokens` với `aud: sigstore`, xác minh bằng `--certificate-oidc-issuer https://gitlab.com` và
  `--certificate-identity https://gitlab.com/<nhóm>/<project>//.gitlab-ci.yml@refs/heads/main` (SAN của Fulcio là
  `https://` + `ci_config_ref_uri`) [L6]. Trên self-managed, tài liệu GitLab dựng Fulcio, Rekor, CT log riêng (Fulcio đòi issuer
  khớp đúng URL của instance) [L6]; đường còn lại là ký bằng khoá (KMS) thay keyless. Cả hai đều đổi `attestors` của Kyverno.
- **URL:** `CI_SERVER_URL` là URL của instance (domain công ty), nên issuer OIDC, link lượt chạy, registry đều theo domain đó.
- **Runner:** gitlab.com có runner hosted (arm64 nhỏ ở Free); self-managed tự cài và quản runner (cả arm64 nếu cần build native).
- **Token:** project access token cần Premium trên gitlab.com, có ở mọi license trên self-managed [L13].
- **Biến pipeline khi chạy tay:** gitlab.com tắt mặc định cho project mới trong namespace mới; self-managed mặc định cho maintainer
  [L7].

## Mang sang nền tảng khác (GitLab)

Từng bước, theo thứ tự; đổi nào cũng đi qua review như mọi thay đổi.

1. **`.gitlab-ci.yml`** gọi đúng target và script đang có: `make check-go TESTFLAGS=-count=1`, `make web-check`, `make generate-check`,
   `deploy/ci/scan-gate.sh --check-ignorefile`, `make slo-check`, … (job `config` của `ci.yml`); `deploy/ci/plan.sh`,
   `build-image.sh`, `push-image.sh`, `merge-index.sh`, `sign-image.sh`, `promote.sh`, `rescan.sh`, `values-check.sh` (`images.yml`);
   `verify-*.sh` (`verify.yml`). Input của script vẫn qua biến môi trường (`EVENT_NAME`, `GIT_REF`, `PR_BASE_REF`, `INPUT_*`,
   `LAST_SUCCESS_JSON`, `PR_NUMBER`, `SVP_*`), YAML chỉ ánh xạ từ biến GitLab sang các tên đó. Job `last-success` đổi sang API
   pipeline của GitLab (pipeline thành công cuối trên `main`).
2. **Nhánh `gitlab)` trong mỗi hàm của `deploy/ci/platform.sh`** theo comment đầu file; `ci_platform` nhận `GITLAB_CI=true`. Thêm ca
   `gitlab` vào `deploy/ci/platform-test.sh` (biến giả `CI_*`, `glab` giả).
3. **Identity OIDC cho Kyverno:** sửa `imageVerification.issuer`, `.subject` ở `deploy/helm/svp-policy/values.yaml` (một chỗ); job ký
   lấy token từ `id_tokens` (`SIGSTORE_ID_TOKEN`, `aud: sigstore`). Self-managed: chọn Sigstore riêng hay ký bằng khoá trước (mục trên).
4. **Registry:** `ghcr_prefix` (`deploy/k8s/lib.sh`), `imagePrefix` (`svp-policy` values), danh sách image của project trong
   `deploy/k8s/check-image-digests.sh`, label `org.opencontainers.image.source` (`oci_labels` của `common.sh`), kiểm kéo ẩn danh
   `ghcr_manifest_status` (`lib.sh`, endpoint token của GHCR), bước `docker login` trong YAML.
5. **Nhánh bảo vệ:** protected branch cho `main` (cấm force push), "Pipelines must succeed", rule của `.github/rulesets/main.json` viết
   lại bằng API GitLab. Check tổng `ci-ok`, `images-ok` không còn cần cho rule (GitLab xét cả pipeline) nhưng vẫn giữ được làm job
   tổng.
6. **Repo cho Argo CD:** `repo_url` của `deploy/k8s/gitops.sh`, `deploy/argocd/project.yaml`, `deploy/argocd/apps/values.yaml`;
   deploy key hay deploy token.
7. **Promote:** project access token (masked, protected) cho push `bot/promote` và mở MR; `ci_bot_name`, `ci_bot_email` là user bot của
   token đó.
8. **Renovate:** `renovate.json` dùng lại; chạy Renovate tự host theo lịch pipeline với token `api`.
9. **Chỗ khác nhắc GitHub nhưng không phải CI:** `runbook_url` của rule cảnh báo trỏ `github.com/.../blob/main/docs/runbooks/`,
   ca k của `drills/supplychain.sh` (image CloudNativePG do workflow GitHub của nhà cung cấp ký: giữ nguyên), job `sarif` (chỉ có ý
   nghĩa ở Ultimate), `make ci-bridge-check` in `::error::` (ở nền tảng khác là dòng chữ thường).
10. **Summary viết trong YAML:** bảng SARIF (anchor `sarif-summary` của `ci.yml`) và dòng bỏ qua của `buf` ghi
    `$GITHUB_STEP_SUMMARY` từ YAML, không qua `ci_summary`: khi viết `.gitlab-ci.yml` cho in ra log (hay ghi file artifact).

**Không mang được 1-1:**

- Mask giá trị sinh lúc chạy (`verify-mask.sh`): GitLab chỉ che biến định nghĩa trong cài đặt; trên GitLab, quy tắc "script không in
  bí mật" và bộ lọc artifact là lớp duy nhất, log của job phải coi như không được che.
- Trang summary và annotation: chỉ còn log và artifact.
- Output theo bước: dotenv theo job, 5 KB, không nhiều dòng.
- Bước người học duyệt lượt chạy CI của PR bot ("Approve workflows to run") làm cổng triển khai: trên GitLab phải dựng cổng khác (duyệt
  MR bắt buộc là Premium).
- Check bắt buộc theo tên từ một app cụ thể (`integration_id`): GitLab chỉ có "pipeline phải thành công".
- Ký keyless bằng Sigstore công khai trên self-managed.
- Service container trên `127.0.0.1`: chỉ chắc ở executor Kubernetes.

## Hệ quả

- Được: chỗ gắn nền tảng của script nằm trong một file có test (`deploy/ci/platform-test.sh`, chạy trên máy, không mạng); mang sang
  GitLab là một danh sách việc có thứ tự, kể cả việc không mang được; identity ký sửa một chỗ; chạy script trên máy không bao giờ mở PR
  thật, push lên remote mạng hay in giá trị mask (push `bot/promote` chỉ tới origin là đường dẫn trên đĩa, mục Quyết định 3).
- Phải trả: một lớp gián tiếp (đọc script phải biết `ci_*`); mỗi script mới phải dùng adapter (`platform-guard.sh` ở job `config`
  bắt, mục Quyết định 1); đổi
  `platform.sh` build lại cả bảy image như đổi `common.sh`.
- Xem lại khi: có project GitLab thật để chạy (viết `.gitlab-ci.yml` và nhánh `gitlab`, đo lại; xét Dagger nếu phải chạy y hệt ở cả
  hai), hay khi một bước mới cần khái niệm không có ở bảng trên.

## Hiện thực ở

- `deploy/ci/platform.sh` (adapter), `deploy/ci/platform-test.sh` (test), `deploy/ci/platform-guard.sh` (phép kiểm); cả hai chạy ở
  job `config` của `.github/workflows/ci.yml`.
- Script gọi adapter: `deploy/ci/common.sh` (`sign_identity`), `plan.sh`, `promote.sh`, `rescan.sh`, `scan-gate.sh`, `values-check.sh`,
  `verify-release.sh`, `vuln-predicate.sh`, `verify-host.sh`, `verify-run.sh`, `verify-sample.sh`, `verify-mask.sh`,
  `verify-collect.sh` (và `verify-collect-test.sh` chạy chúng như job GitHub); `deploy/k8s/gitops.sh`, `deploy/k8s/drills/gitops.sh`,
  `deploy/k8s/drills/supplychain.sh`; bước `rescan` của `.github/workflows/images.yml`.
- Identity ký: `deploy/helm/svp-policy/values.yaml`. Quy tắc build: `deploy/ci/changed-services.sh`.

## Kiểm chứng (đã kiểm ngày 2026-10-25)

| Kiểm gì | Lệnh | Kết quả |
| --- | --- | --- |
| Adapter từng nền tảng, script gọi nó | `deploy/ci/platform-test.sh` | Xanh: `github` với biến giả (output, summary, mask, link, lệnh `gh`), `local` (stdout, không mask, không gọi `gh` để ghi), GitLab CI và `CI=true` bị từ chối; `plan.sh`, `vuln-predicate.sh`, `scan-gate.sh`, `values-check.sh`, `promote.sh` trong repo tạm; `promote.sh` trên máy với origin `https://`, `git@host:` bị từ chối, với `PROMOTE_DRY_RUN=1` và URL push mạng chỉ in lệnh push, nhánh không đổi; origin trên đĩa thì push như cũ; `platform-guard.sh` sạch trên repo tạm, đỏ (exit 1, `file:dòng:`) với script chưa track ghi `$GITHUB_OUTPUT` và script đã track gọi `gh pr`; đổi `platform-guard.sh` không build image nào. Ca promote và guard đỏ khi bỏ phần sửa (thử trên bản sao) |
| Không script nào ngoài adapter đọc nền tảng | `deploy/ci/platform-guard.sh` | Sạch trên working tree (grep BSD và GNU); bản sao working tree thêm một dòng `$GITHUB_OUTPUT` vào bản chép của `plan.sh` → exit 1, in đúng dòng đó |
| Không đổi hành vi | bản script trước và sau, cùng biến giả và `gh`, `cosign` giả | Trên GitHub giống từng byte (`plan.sh` năm ca, `scan-gate.sh` năm ca, `vuln-predicate.sh`, `values-check.sh`, `promote.sh` dry run và thật, chặn `rescan.sh`); trên máy chỉ khác ở ba điểm của Quyết định 6 |
| Bộ lọc và mask của lượt verify | `deploy/ci/verify-collect-test.sh` | Xanh, 98 phép kiểm như trước |
| Render policy | `helm template deploy/helm/svp-policy` (Enforce, Audit) trước và sau; `make helm-check` | Giống hệt; `helm-check` xanh |
| Workflow | `make actionlint` | Sạch |

Kiểm sau push: lượt CI của PR (`ci-ok`, `images-ok`, `build-nopush` cả bảy image vì `deploy/ci/` đổi, `values-check` nếu PR đổi
values; hai bước `platform-guard.sh`, `platform-test.sh` của job `config` trên runner Linux).

## Nguồn

Đọc ngày 2026-10-25.

- [G1] GitHub, "Workflow commands for GitHub Actions": <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands>
- [G2] GitHub, "Variables reference": <https://docs.github.com/en/actions/reference/workflows-and-actions/variables>
- [G3] GitHub, "OpenID Connect reference": <https://docs.github.com/en/actions/reference/security/oidc>
- [G4] GitHub, "Deployments and environments": <https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments>;
  "About code owners": <https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners>
- [G5] GitHub, "Supported ecosystems and repositories": <https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories>
- [L1] GitLab, "Predefined CI/CD variables reference": <https://docs.gitlab.com/ci/variables/predefined_variables/>
- [L2] GitLab, "Pass an environment variable to another job" (dotenv): <https://docs.gitlab.com/ci/variables/dotenv_variables/>;
  giới hạn của gitlab.com: <https://docs.gitlab.com/user/gitlab_com/>
- [L3] [L4] GitLab, "CI/CD variables" (masked, hidden, protected): <https://docs.gitlab.com/ci/variables/>
- [L5] GitLab, "OpenID Connect (OIDC) Authentication Using ID Tokens": <https://docs.gitlab.com/ci/secrets/id_token_authentication/>
- [L6] GitLab, "Use Sigstore for keyless signing": <https://docs.gitlab.com/ci/yaml/signing_examples/>; "Keyless signing on GitLab
  Self-Managed": <https://docs.gitlab.com/ci/yaml/signing_self_hosted/>; Fulcio `config/identity/config.yaml` và `docs/oidc.md`:
  <https://github.com/sigstore/fulcio>
- [L7] GitLab, `.gitlab-ci.yml` keyword reference: <https://docs.gitlab.com/ci/yaml/>; schedules:
  <https://docs.gitlab.com/ci/pipelines/schedules/>; merge request pipelines: <https://docs.gitlab.com/ci/pipelines/merge_request_pipelines/>;
  `glab ci run`: <https://docs.gitlab.com/cli/ci/run/>
- [L8] GitLab, `.gitlab-ci.yml` keyword reference (`services`, `cache`, `artifacts`, `needs`, `parallel:matrix`): <https://docs.gitlab.com/ci/yaml/>
- [L9] GitLab, hosted runners on Linux: <https://docs.gitlab.com/ci/runners/hosted_runners/linux/>; runners: <https://docs.gitlab.com/ci/runners/>
- [L10] GitLab, protected environments: <https://docs.gitlab.com/ci/environments/protected_environments/>; deployment approvals:
  <https://docs.gitlab.com/ci/environments/deployment_approvals/>
- [L11] GitLab, protected branches: <https://docs.gitlab.com/user/project/repository/branches/protected/>; push rules:
  <https://docs.gitlab.com/user/project/repository/push_rules/>; approval rules:
  <https://docs.gitlab.com/user/project/merge_requests/approvals/rules/>; Code Owners: <https://docs.gitlab.com/user/project/codeowners/>;
  auto-merge và "Pipelines must succeed": <https://docs.gitlab.com/user/project/merge_requests/auto_merge/>
- [L12] GitLab, container registry: <https://docs.gitlab.com/user/packages/container_registry/>
- [L13] GitLab, project access tokens: <https://docs.gitlab.com/user/project/settings/project_access_tokens/>; CI/CD job token:
  <https://docs.gitlab.com/ci/jobs/ci_job_token/>
- [L14] GitLab, deploy keys: <https://docs.gitlab.com/user/project/deploy_keys/>; deploy tokens:
  <https://docs.gitlab.com/user/project/deploy_tokens/>
- [L15] GitLab, pipeline secret detection: <https://docs.gitlab.com/user/application_security/secret_detection/pipeline/>; secret push
  protection: <https://docs.gitlab.com/user/application_security/secret_detection/secret_push_protection/>
- [L16] GitLab, vulnerability report, security dashboard, SARIF: <https://docs.gitlab.com/user/application_security/detect/sarif/>
- [L17] Renovate, GitLab platform: <https://docs.renovatebot.com/modules/platform/gitlab/>
- [L18] Argo CD, Git webhook configuration: <https://argo-cd.readthedocs.io/en/stable/operator-manual/webhook/>
- [L19] GitLab, "Services": <https://docs.gitlab.com/ci/services/>
- [L20] GitLab Runner, Kubernetes executor: <https://docs.gitlab.com/runner/executors/kubernetes/>
