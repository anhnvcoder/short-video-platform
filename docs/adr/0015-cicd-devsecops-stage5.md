# 0015. Giai đoạn 5: CI/CD và chuỗi cung ứng image với GitHub Actions ghim SHA, image đa kiến trúc trên GHCR, trivy chặn trước push, SBOM syft, ký keyless cosign, Kyverno chỉ nhận image đã ký và sạch, promote bằng PR GitOps, Renovate

- Trạng thái: Chấp nhận; §2 (job `web`, job `check` chạy `make check-go`, `ci-ok` bảy job) chỉnh bởi [0016](0016-web-client.md);
  thứ tự cắt RAM của §8 chỉnh bởi [0017](0017-gitops-capacity-media-worker-max2.md) (thiếu tiêu chí (c) thì đi thẳng tới
  media-worker tối đa 2); §3–§9 (image thứ bảy `web`: context `web/`, `image_paths`, build arg `SVP_BUILD_ID`) chỉnh bởi
  [0019](0019-web-k3d-supply-chain-observability.md); §1 (workflow thứ ba `verify.yml`, chỉ dispatch và lịch hằng tuần, ngoài
  check bắt buộc), §2 (job `trivy-config` bỏ qua có hạn qua `deploy/ci/trivy-config-ignore.yaml`; job `web` thêm cổng CRITICAL
  `make web-lockfile-scan`) và §6 (tệp bỏ qua thứ hai chỉ `misconfigurations`, mỗi mục có `paths`, hạn tối đa 90 ngày,
  `scan-gate.sh --check-ignorefile` kiểm cả hai tệp) chỉnh bởi [0021](0021-deferred-verification-stage6b.md); §3 (đổi các file
  của `deploy/ci/` mà không job image nào đọc: tệp bỏ qua misconfig, script và test của `verify.yml`, `platform-test.sh`,
  `platform-guard.sh`, không build lại image) chỉnh bởi 0021 và [0023](0023-ci-platform-neutral.md); §1 (job `gitops` của
  `verify.yml` thêm `actions: read`, `GH_TOKEN` chỉ ở bước tìm source map và bước chờ phát hành), §4 (chân build `web` của lượt
  phát hành xuất artifact `web-sourcemaps-<arch>` cùng build cache sau bước push, kèm `image-digest`; mọi chân `web`, cả ở PR, kiểm
  debug ID của chunk image có trong bộ map) và §9 (cluster GitOps đọc repo qua HTTPS ẩn danh, `make k8s-gitops-up` không còn deploy
  key) chỉnh bởi 0021 ngày 2026-10-28; §8, §9 (cluster GitOps đóng vai stg với overlay `deploy/k8s/envs/stg/`; Enforce trên stg và
  prd, Audit trên dev) chỉnh bởi [0024](0024-multi-environment.md); §3 (dòng `GRYPE_IMAGE` của `Makefile` cũng build lại cả bảy
  image), §6 (grype quét SBOM syft của mỗi chân trước push cạnh trivy, cùng cổng CRITICAL và `.trivyignore.yaml`) và §12
  (govulncheck, DAST thôi là việc để sau) chỉnh bởi [0030](0030-devsecops-supplement.md)
- Ngày: 2026-10-20

## Bối cảnh

- Giai đoạn 0–4 xong, `main` ở `c89cf10` ([plan](../../plans/261004-devops-sa-roadmap/plan.md), mục Tiến độ). Giai đoạn 5
  phải có: GitHub Actions chỉ build service có thay đổi; image đa kiến trúc lên GHCR; quét bảo mật bằng trivy, gosec,
  gitleaks; SBOM bằng syft, ký image bằng cosign; Kyverno chỉ cho chạy image đã ký và đạt policy cơ bản; Renovate; đánh
  version; promote image qua pull request GitOps. **Xong khi:** cluster từ chối image chưa ký hoặc có lỗ hổng nghiêm trọng.
- [Threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn), hàng giai đoạn 5: FF-8 (ffmpeg có lỗ hổng đã công bố),
  SC-1 (image bị thay hay không rõ nguồn), SC-2 (action bên thứ ba bị chiếm, đọc được secret của CI), SEC-1 (gitleaks),
  SEC-2 (trivy quét bí mật trong image), JWT-10 (khoá ký nằm trong repo hay image); xét lại threat model theo bề mặt mới.
- Repo `anhnvcoder/short-video-platform` **public từ 2026-10-20**: runner chuẩn không tính phút, runner Linux arm64 dùng
  được, package GHCR public không tính dung lượng, tab Security nhận SARIF. Cái giá: mọi thứ được commit, log và artifact
  của mọi lượt Actions, mọi package public ai cũng đọc được, và PR từ fork chạy workflow của repo.
- Hiện trạng: `make check` chỉ chạy trên máy; image phát hành build trên máy bằng `make k8s-release`, tag 12 hex của SHA
  commit, nằm trong registry k3d và mất cùng cluster ([ADR-0014](0014-kubernetes-local-stage4.md) §6, §12); image bên thứ
  ba chạy theo tag của chart, "chưa ghim digest hay ký" (ADR-0014 §1, Hệ quả); base image của Dockerfile theo tag
  ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md) §7); version công cụ trong `Makefile` cập nhật bằng tay
  (ADR-0007 §3, "tới khi có Renovate").
- Ràng buộc RAM của cluster: đường GitOps nghỉ 7,03 GiB, đỉnh 8,10 GiB, ngưỡng đỉnh 8,7 GiB (ADR-0014 §2, điều kiện (a),
  (b)). Không cài trivy, syft, cosign hay CLI Kyverno vào máy: trên máy chúng chạy bằng image ghim digest (`docker run`
  qua `Makefile`), trong CI cài như mục 1.
- ADR này chốt version, SHA commit của từng action, digest image, tên image, tên job và check, identity ký, tên biến mà
  mọi phần CI/CD của giai đoạn 5 dùng. Số liệu tra ngày **2026-10-20** (GitHub, registry, Sigstore thay đổi theo thời
  gian). Giả định chỉ kiểm được khi workflow chạy thật trên GitHub, khi có chữ ký thật hay trên cluster nằm ở mục "Kiểm
  chứng sau phát hành", mỗi dòng kèm tên phép kiểm chứng minh nó.

## 1. Hai workflow, action ghim SHA, quyền tối thiểu (SC-2)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Hai workflow: `ci.yml` (kiểm code) và `images.yml` (image), mỗi cái một check tổng** | Ruleset chỉ cần hai tên check; quyền ghi GHCR, `id-token`, ghi repo chỉ nằm trong `images.yml` | Hai file phải giữ cùng quy ước |
| Một workflow chung | Một file | Job quét code và job ký chung trigger, concurrency; khó tách quyền |
| Một workflow mỗi service | Lọc bằng `paths:` tự nhiên | Sáu check bắt buộc; `paths:` làm check treo (mục 3) |
| **Action ghim theo SHA commit đầy đủ, comment ghi tag** | Tag bị đẩy lại (tj-actions, trivy-action) không đổi code chạy | Phải cập nhật SHA (Renovate làm) |
| Action theo tag (`@v7`) | Tự nhận bản vá | Ai chiếm được repo action là chạy code trong job |
| Lockfile workflow (`.github/workflows/actions.lock`, `gh actions-lock`) | Thoả "pinned to SHA" mà không sửa file workflow | Public preview từ 2026-10-14; thêm một extension của `gh` |
| **Chỉ action của GitHub và của chính nhà cung cấp công cụ** | Ít bên phải tin; mỗi action là đường chính thức của công cụ | Tự viết vài dòng shell thay action tiện ích |
| Action tiện ích bên thứ ba (lọc đường dẫn, changed-files, comment PR) | Ít code | Thêm bên phải tin, đọc được token và log của job |
| `pull_request_target` / `workflow_run` cho PR fork | Có token ghi và secret cho PR fork | Chạy trong ngữ cảnh đặc quyền của nhánh base; đường chiếm repo của các vụ Ultralytics (12/2024), nx (8/2025) |
| Một job build cho mọi sự kiện, `packages: write` tĩnh, bước push chỉ chạy trên `main` | Một định nghĩa job | Lượt PR (cả PR Renovate đổi SHA action, chạy trước khi ai đọc) chạy code và script của chính nó với token ghi được mọi package của repo: đẩy lại tag, đè `.att` bằng kết quả quét cũ |
| **Đường PR và đường `main` là hai job khác nhau gọi chung một script** | Mọi job của lượt PR chỉ có `contents: read` | Ma trận và vài bước khai hai lần trong `images.yml` |
| Workflow con (`workflow_call`) gọi hai lần với `permissions` khác nhau | Một định nghĩa bước | Thêm file workflow thứ ba; tên job lồng `<job> / <job con>` |
| **trivy, syft: image chính thức ghim digest, chạy bằng `docker run`** | Cùng một tham chiếu trên máy dev và CI; digest bất biến; Renovate cập nhật digest; không cần action | Mỗi lần chạy kéo image |
| trivy, syft: action cài đặt chính thức ghim SHA (`aquasecurity/setup-trivy`, `anchore/sbom-action`) | Một bước | Thêm action phải tin (chính `setup-trivy`, `trivy-action` bị chiếm 3/2026); bản công cụ do action quyết (`trivy-action` v0.36.0 mặc định trivy v0.70.0) |
| trivy, syft: tải bản release, kiểm checksum và chữ ký cosign của checksum | Đúng binary upstream, kèm chữ ký của nhà cung cấp | Thêm script tải/kiểm cho hai công cụ; chữ ký chỉ chứng minh bản đi qua đường phát hành của nhà cung cấp, không chứng minh nó lành (v0.69.4 độc hại được phát hành bằng thông tin đăng nhập bị chiếm) |

### Quyết định

- **Hai file:** `.github/workflows/ci.yml` (mục 2) và `.github/workflows/images.yml` (mục 3–7, 9); check tổng `ci-ok` và
  `images-ok` là hai check bắt buộc (mục 11). Không workflow nào có `paths:` ở trigger: lọc ở cấp job (mục 3).
- **Không `pull_request_target`, không `workflow_run`.** Workflow của PR (kể cả fork) chỉ đọc repo và không có secret:
  GitHub chỉ cho `GITHUB_TOKEN` quyền đọc và không truyền secret với PR từ fork ("The `GITHUB_TOKEN` has read-only
  permissions in pull requests from forked repositories", tài liệu GitHub, `pull_request_forked_repos_link.md`).
- **`permissions: {}` ở đầu mỗi file**, mỗi job khai đúng quyền nó cần (`ci.yml` ở mục 2, bảng job của `images.yml` ở mục
  4). **Mọi job chạy trong lượt `pull_request` chỉ có `contents: read`**, kể cả PR từ nhánh của chính repo và PR của
  Renovate: lượt PR chạy code và script của chính PR trước khi ai đọc nó (PR đổi SHA action chạy ngay, và tag bị đẩy lại
  vẫn qua `minimumReleaseAge`, mục 10). Quyền khai tĩnh theo job, nên job nào cần quyền ghi (`packages`, `id-token`,
  `security-events`, `contents`, `pull-requests`) hay `actions: read` là một job riêng có `if:` chỉ chạy khi sự kiện khác
  `pull_request` và `github.ref == 'refs/heads/main'`; đường PR và đường `main` của build là hai job gọi chung một script
  (mục 4), không phải một job có bước push bị bỏ qua. Trên `main`, script chạy với quyền ghi là script đã qua PR và check
  (mục 11); code Go và lệnh `RUN` của Dockerfile chạy trong container BuildKit, không thấy token.
- **`actions/checkout` với `persist-credentials: false`** ở mọi job (token không nằm lại trong `.git/config`), trừ job
  promote cần push (mục 9).
- **Input không tin cậy** (tiêu đề và thân PR, tên nhánh `github.head_ref`, input `workflow_dispatch`) chỉ vào script qua
  `env:` rồi đọc bằng `"$VAR"`; không bao giờ nội suy `${{ ... }}` của chúng trong `run:` (script injection, cách vụ nx
  8/2025 lấy được `GITHUB_TOKEN`).
- **Không action tiện ích bên thứ ba.** Lọc đường dẫn tự viết bằng `git diff --name-only` (mục 3); comment, PR, login
  GHCR bằng `gh` và `docker` có sẵn trên runner.
- **Vụ chiếm action đã xác minh** (nguồn GHSA/NVD, đọc 2026-10-20):
  - `tj-actions/changed-files`, CVE-2025-30066 (GHSA-mrrh-fwg8-r2c3): 14–15/3/2025 các tag v1 tới v45.0.7 bị trỏ lại về một
    commit độc hại in secret của CI ra log; CISA thêm vào KEV ngày 18/3/2025.
  - `reviewdog/action-setup@v1`, CVE-2025-30154 (GHSA-qmg3-hpqr-gqvc): 11/3/2025, cùng kiểu in secret ra log, "regardless of
    version or pinning method" với năm action reviewdog dùng nó.
  - `xygeni/xygeni-action`, CVE-2026-31976 (GHSA-f8q5-h5qh-33mh): tag `v5` bị dời sang commit độc hại khoảng 3–10/3/2026.
  - **Trivy**, CVE-2026-33634 (GHSA-69fq-xp46-6x23, critical): 19/3/2026 kẻ tấn công dùng thông tin đăng nhập bị chiếm phát
    hành trivy v0.69.4 độc hại, đẩy lại 76/77 tag của `aquasecurity/trivy-action` và cả 7 tag của `aquasecurity/setup-trivy`
    sang mã đánh cắp credential (đọc bộ nhớ `Runner.Worker` qua `/proc/<pid>/mem`); 22/3/2026 thêm image Docker Hub
    0.69.5, 0.69.6 độc hại. Advisory ghi không bị ảnh hưởng: image kéo theo digest, action ghim SHA (sau 9/4/2025).
  - Bài học áp vào đây: ghim SHA cho action, ghim digest cho image công cụ, chờ 3 ngày trước khi nhận bản mới (mục 10);
    action ghim SHA vẫn kéo action con theo tag thì vẫn hở, nên chỉ dùng action không gọi action bên thứ ba.
- **Cài trivy, syft:** image chính thức ghim digest (bảng dưới), biến `TRIVY_IMAGE`, `SYFT_IMAGE` trong `Makefile`, cả CI
  và máy dev chạy `env -u DOCKER_DEFAULT_PLATFORM docker run ...` với đúng biến đó. Lý do: digest bất biến, không action
  nào (hai action cài trivy đã bị chiếm), cùng một tham chiếu ở mọi nơi, Renovate cập nhật digest. Không kiểm chữ ký cosign
  của image công cụ: digest ghim đã cố định nội dung, chữ ký không thêm gì.
- **cosign:** `sigstore/cosign-installer` ghim SHA, `cosign-release: v3.1.3`. Installer tải cosign v3.0.6 làm bản khởi động
  và so sha256 ghim ngay trong `action.yml`, rồi dùng nó kiểm chữ ký keyless của bản yêu cầu
  (`keyless@projectsigstore.iam.gserviceaccount.com`, issuer `https://accounts.google.com`) và từ v3.0.3 thêm chữ ký KMS
  (`action.yml@v4.1.2`). Trên máy: image `COSIGN_IMAGE` ghim digest, chỉ để xác minh (ký chỉ chạy trong CI).
- **Thử workflow trước push:** `actionlint` ghim `ACTIONLINT_VERSION`, cài bằng `make tools` (`go install`), target
  `make actionlint` chạy trên mọi file `.github/workflows/` và nằm trong `make check`. actionlint gọi `shellcheck` khi có
  trên PATH (runner có 0.9.0; máy dev không bắt buộc).

**Bảng version** (tra 2026-10-20; mọi bản đã phát hành ít nhất 3 ngày, như `minimumReleaseAge` của mục 10).

Action (SHA là commit, tag annotated đã đi tiếp tới commit):

| Action | Tag | SHA commit | Phát hành |
| --- | --- | --- | --- |
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` | 2026-07-20 |
| `actions/setup-go` | v7.0.0 | `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` | 2026-07-16 |
| `actions/cache` | v6.1.0 | `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` | 2026-06-26 |
| `actions/upload-artifact` | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` | 2026-10-07 |
| `actions/download-artifact` | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` | 2026-10-07 |
| `github/codeql-action/upload-sarif` | v4.39.0 (tag annotated) | `6f2ac81f5cd81fe351a197ba0b00d91d03cd2aee` | 2026-10-15 |
| `sigstore/cosign-installer` | v4.1.2 | `6f9f17788090df1f26f669e9d70d6ae9567deba6` | 2026-05-07 |

Năm action của `actions/*` chạy `node24`; `cosign-installer` là composite. `download-artifact` v8 mặc định lỗi khi hash
của artifact lệch (`digest-mismatch: error`), nên artifact giữa các job không bị thay giữa đường.

Công cụ:

| Công cụ | Version | Cách cài, tham chiếu ghim | Ghi chú |
| --- | --- | --- | --- |
| trivy | 0.76.0 (2026-10-14) | `ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222` (`TRIVY_IMAGE`) | Cùng index trên `docker.io/aquasec/trivy`, `public.ecr.aws/aquasecurity/trivy`; bản phát hành `immutable` |
| syft | v1.54.1 (2026-10-06) | `ghcr.io/anchore/syft:v1.54.1@sha256:3eb5379ba7b409c3f4069b686110527af0c47df993fa5c10d13e7cf34f49b1aa` (`SYFT_IMAGE`) | v1.55.0 phát hành 2026-10-19, chưa đủ 3 ngày |
| cosign | v3.1.3 (2026-08-06) | CI: `cosign-installer` với `cosign-release: v3.1.3`; máy: `ghcr.io/sigstore/cosign/cosign:v3.1.3@sha256:9e5c2f2edc34351160407ca3416c61855bdf9403c3c5936e0f0be7fc261611b8` (`COSIGN_IMAGE`) | v3.1.3 sửa GHSA-fx35-mq7g-6g98 (mục 7) |
| actionlint | v1.7.12 (2026-03-30) | `go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12` (`ACTIONLINT_VERSION`) | `go.mod` khai `go 1.25.0` |
| golangci-lint (gồm gosec) | v2.14.0 | đã ghim (`GOLANGCI_LINT_VERSION`) | gosec `github.com/securego/gosec/v2 v2.29.0` trong `go.mod` của golangci-lint v2.14.0; bản mới nhất v2.15.0 vẫn gosec v2.29.0 |
| gitleaks | v8.30.1 (2026-03-21) | đã ghim (`GITLEAKS_VERSION`) | Bản mới nhất |
| buf | v1.74.0 (2026-10-14) | CI: `go install github.com/bufbuild/buf/cmd/buf@v1.74.0` (`BUF_VERSION`, cách cài có trong tài liệu buf); máy: Homebrew 1.74.0 | |
| Helm | v4.3.1 (2026-10-15) | CI: `https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz`, sha256 ghim trong repo `0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b` (`HELM_VERSION`, `HELM_LINUX_AMD64_SHA256`); máy: Homebrew v4.3.1 | Runner có sẵn Helm 3.22.0, không dùng; `go install` của Helm không có trong tài liệu và in sai version |
| Renovate (kiểm cấu hình trên máy) | 44.165.1 (2026-10-16) | `ghcr.io/renovatebot/renovate:44.165.1@sha256:455f4169a364a4c8bdc38a08694e3509649f3d7cb9aaea35c86946b38015ac47` (`RENOVATE_IMAGE`) | App Mend chạy bản do Mend quyết, "can lag a few hours to a week" so với bản mã nguồn mở |
| Kyverno | chart 3.9.1, app v1.19.1 (2026-09-10) | repo `https://kyverno.github.io/kyverno`, image bảng mục 8 | v1.19.2 mới ở bản RC |

Service container của `ci.yml` và base image (index đa kiến trúc, đã kiểm có `linux/amd64` và `linux/arm64`):

| Image | Tham chiếu ghim | Vì sao bản này |
| --- | --- | --- |
| Postgres | `docker.io/library/postgres:15.19-trixie@sha256:c961aa287d8698297cb26cdfadfbe9fd2cbaf77e53cfffe9636e8d8a1e4d842c` | Major 15 như bản native (15.18) và `svp-pg` (15.19); 15.19 là bản 15.x mới nhất |
| Redis | `docker.io/library/redis:8.8.3-trixie@sha256:eb1aa641bc5380ed14442398e45a5a51aeaaac919fab811e4f134eb77c71dd2d` | Cùng nhánh 8.8 với Redis native (8.8.0); 8.10.2 là bản 8.x mới nhất |
| Go builder | `golang:1.27.2-trixie@sha256:47667934874913a449b96faa7ef4777fa285d9ec29126ee80ed61c45b7cccf0e` | Cùng Go của máy dev; 1.27.3 ra 2026-10-20, Renovate đề xuất sau 3 ngày |
| Runtime Go | `gcr.io/distroless/static-debian13:nonroot@sha256:516757106de35205efb70b91ba03f6f1298424a0678c603255cf2852a7000087` | Tag `nonroot` đổi theo bản dựng; digest cố định nội dung |
| Runtime media-worker | `alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6` | 3.24.2 là bản 3.24 mới nhất |

Runner: `ubuntu-24.04` (image 20261012.334.1) và `ubuntu-24.04-arm` (image 20261012.149.1), cùng Docker 28.0.4, buildx
0.38.0, Compose 2.38.2, jq 1.7, skopeo 1.13.3, gh 2.102.0, shellcheck 0.9.0; không có ffmpeg, không có crane
(`images/ubuntu/Ubuntu2404-Readme.md`, `Ubuntu2404-Arm64-Readme.md` của `actions/runner-images`). Docker 28 dùng image
store cổ điển (không containerd snapshotter). Label ghi rõ `ubuntu-24.04`, không `ubuntu-latest`: `ubuntu-latest` chuyển
sang 26.04 (Docker 29) từ tháng 11/2026.

## 2. `ci.yml`: đủ mục Kiểm tra của `CLAUDE.md`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Nhiều job song song, job tổng `ci-ok` là check bắt buộc duy nhất của `ci.yml`** | Mỗi phần lỗi riêng, chạy song song; thêm hay đổi tên job không phải sửa ruleset | Job tổng phải tự đọc `needs.*.result` (job bị bỏ qua hay huỷ không tự làm nó đỏ) |
| Một job chạy tuần tự mọi lệnh | Đơn giản | Chậm; lỗi đầu che các lỗi sau |
| **Postgres, Redis là service container của Actions** | Image ghim digest; GitHub dựng và dọn; cổng map ra `127.0.0.1` nên `internal/pgtest`, `internal/redistest` nhận như máy dev | Hai image phải giữ mới (Renovate) |
| Postgres, Redis cài bằng `apt` trên runner | Không cần Docker | Version theo kho của Ubuntu, không ghim, lệch bản native |
| **gosec trong golangci-lint, kết quả SARIF** | Một bộ luật, một version (theo `GOLANGCI_LINT_VERSION`), một cấu hình `.golangci.yml`, đã chặn ở `make check` và git hook | Version gosec đi theo golangci-lint |
| gosec cài riêng (binary hay action) | Bản gosec mới nhất | Thêm một công cụ ghim, cấu hình thứ hai, cùng phát hiện báo hai lần |
| `make generate` rồi `git diff --exit-code` (cách ADR-0007 §2 dự kiến) | Ngắn | Ghi vào working tree: trên máy dev đè thay đổi chưa commit của code sinh, nên chỉ chạy an toàn trong CI |
| **`make generate-check` trong bản sao tạm** | Không bao giờ ghi working tree; máy dev và CI chạy như nhau; bắt cả file mới sinh | Chép cây làm việc mỗi lần |
| **Upload SARIF chỉ ngoài PR** | Lượt PR không có `security-events: write` | PR không có chú thích code scanning trên diff; kết quả của PR chỉ nằm ở artifact và job summary |
| Upload SARIF cả ở PR từ nhánh của repo | Chú thích trên diff PR | Lượt PR giữ quyền ghi tab Security trước khi ai đọc PR |

### Quyết định

Trigger `pull_request` (mọi nhánh base), `push` nhánh `main`, `workflow_dispatch`; `concurrency` group
`ci-${{ github.ref }}`, `cancel-in-progress` chỉ khi `github.event_name == 'pull_request'`. Mọi job `runs-on:
ubuntu-24.04`, `permissions: contents: read` trừ job SARIF. Tên job là contract của ruleset chỉ ở `ci-ok`; tên khác do file
workflow quyết. Các job:

- **`check`:** `make check-go TESTFLAGS=-count=1 LINTFLAGS="$LINTFLAGS"` (từ giai đoạn 5b `make check` = `check-go` +
  `web-check`; phần web chạy ở job `web` bên dưới), với `env:` của bước đặt `LINTFLAGS` là
  `--output.text.path=stdout --output.sarif.path=${{ runner.temp }}/golangci-lint.sarif` (đường dẫn đã điền sẵn: `$` còn
  lại trong giá trị sẽ bị make đọc thành biến của nó; thứ tự hiện có `fmt-check`, `vet`, `lint`, `actionlint`,
  `buf-lint`, `test`; `-count=1` để cache build của `actions/setup-go` không cho một lượt "xanh" mà không chạy test nào).
  - Service container Postgres (bảng mục 1), env `POSTGRES_PASSWORD=postgres`, `ports: ["127.0.0.1:5432:5432"]`,
    healthcheck `pg_isready -U postgres`; Redis (bảng mục 1), `ports: ["127.0.0.1:6379:6379"]`, healthcheck
    `redis-cli ping`. Runner chuyển nguyên chuỗi `ports` thành `docker create -p <chuỗi>` (`ContainerInfo.cs`,
    `DockerCommandManager.cs` của `actions/runner`), nên dạng có địa chỉ host chạy được dù tài liệu không nêu.
    `SVP_TEST_POSTGRES_URL`, `SVP_TEST_REDIS_URL` giữ mặc định của `Makefile` (`127.0.0.1:5432`, superuser `postgres`;
    `127.0.0.1:6379/15`): helper của test vẫn chỉ nhận đúng địa chỉ đó, tên database `svp_*_test`, Redis db 15, không
    `FLUSHDB`.
  - ffmpeg: `sudo apt-get install -y --no-install-recommends ffmpeg` (kho Ubuntu 24.04, bản 6.1) để test transcode của
    media-worker chạy thay vì `t.Skip` ("not in PATH"). Bản này cũ hơn bản trong image (Alpine 3.24) và máy dev; test chỉ
    dùng cờ có từ lâu. Xem lại khi một test transcode cho kết quả khác giữa CI và image.
  - Go: `actions/setup-go` với `go-version: 1.27.2` (cùng image `golang` của Dockerfile và máy dev), cache module và build
    bật (khoá theo `go.sum`); GOBIN của `make tools` cache bằng `actions/cache` khoá theo hash của `Makefile`.
  - golangci-lint chạy **một lần** (trong `make check`) với thêm đầu ra SARIF qua `LINTFLAGS` (bên dưới; cờ ở
    `pkg/commands/flagsets.go@v2.14.0`). Phải đặt cả `--output.text.path=stdout`: có định dạng ra nào được đặt thì
    golangci-lint bỏ đầu ra chữ mặc định (`Print`, `pkg/printers/printer.go@v2.14.0`), log của job sẽ không có lỗi lint.
    gosec nằm trong đó (bật ở `.golangci.yml`; gosec không thuộc nhóm `standard` nên phải bật tên).
- **`web`** (thêm ở giai đoạn 5b, [ADR-0016](0016-web-client.md) §10): Node theo `web/.nvmrc` (`actions/setup-node`), pnpm
  bằng `npm install -g pnpm@<packageManager của web/package.json>` (không Corepack, không action bên thứ ba), cache store
  pnpm bằng `actions/cache` khoá theo hash `web/pnpm-lock.yaml`, Redis là service container như `check` (test session
  dùng db 15); chạy `make web-install`, `make web-check`, `make web-generate-check`. `contents: read`, không secret.
- **`generate`:** `make generate-check` (target mới): chép file đã track và file chưa track không bị ignore
  (`git ls-files -z -co --exclude-standard`, không đọc `.env`) vào `mktemp -d`, chạy `make generate` trong bản sao, so với
  working tree (file đổi và file mới sinh), in danh sách và diff, thoát ≠ 0 khi lệch, xoá thư mục tạm bằng `trap`. Không
  bao giờ ghi vào working tree. Cần `buf` và plugin của `make tools`, `sqlc` (cgo, `gcc` có sẵn trên runner).
- **`buf`:** `buf breaking`: PR so với merge-base của nhánh base (`--against ".git#ref=<sha>"`), push `main` so với
  `github.event.before` (trạng thái `main` trước push; toàn số 0 thì bỏ qua, ghi summary), `workflow_dispatch` so với
  merge-base của HEAD với `origin/main` như `images.yml` (sự kiện này không có `before`). Checkout `fetch-depth: 0`.
  `buf lint`, `buf build` đã nằm trong `make check`.
- **`config`:** bước đầu `deploy/ci/scan-gate.sh --check-ignorefile` (quy tắc của `.trivyignore.yaml`, mục 6; không cần
  image, công cụ hay token); `make slo-check`; `make otelcol-validate`; `make env` rồi `make compose-config` (`.env`
  sinh trên runner, mode 600, sống tới hết job, không in, không upload; `config --quiet` không in file đã điền secret);
  `helm lint` và
  `helm template` mọi chart trong `deploy/helm/` và `deploy/argocd/apps` với values của đường GitOps (`HELM_*_HOME` trong
  `$RUNNER_TEMP`); `deploy/k8s/check-image-digests.sh` (mục 8). Release `svp-service` của service nào có `image.digest`
  rỗng trong `deploy/k8s/values/services/<svc>.yaml` (trước PR promote đầu, mục 9) được render thêm `--set
  image.digest=sha256:<64 số 0>`, để đi đúng nhánh digest của đường GitOps thay vì vấp `required` của tag; có digest thì
  không `--set` gì.
- **`gitleaks`:** `gitleaks git --redact --no-banner --report-format sarif --report-path gitleaks.sarif` trên **toàn lịch
  sử** (`fetch-depth: 0`; không `--log-opts`, vì đặt nó là bỏ `--full-history --all` mặc định, `sources/git.go@v8.30.1`),
  bản `GITLEAKS_VERSION` của `Makefile`; phát hiện nào cũng làm job đỏ (mã thoát 1). `--redact` bắt buộc: log và SARIF của
  repo public ai cũng đọc. Phát hiện giả (fixture test) chỉ được loại bằng `.gitleaks.toml` có allowlist hẹp theo đường
  dẫn hay regex kèm comment lý do.
- **`trivy-config`:** `trivy config --format sarif` cho Dockerfile và chart trong repo, **chỉ báo** (không `--exit-code`,
  thoát 0), trivy bản ghim (mục 1).
- **`sarif`:** chỉ chạy trên `main` khi sự kiện khác `pull_request` (push, `workflow_dispatch`); tải SARIF của các job trên
  (artifact), upload bằng `github/codeql-action/upload-sarif`, mỗi công cụ một `category` (`golangci-lint`, `gitleaks`,
  `trivy-config`). Chỉ job này có `security-events: write` và nó không chạy code của repo. Ở mọi PR (nhánh của repo hay
  fork) kết quả nằm trong artifact và bảng tóm tắt ở job summary; tab Security chỉ nhận kết quả của `main`.
- **`ci-ok`:** `needs` đúng bảy job kiểm `check`, `web`, `generate`, `buf`, `config`, `gitleaks`, `trivy-config` (`web` thêm
  ở giai đoạn 5b; trước đó sáu); **không** gồm
  `sarif` (báo cáo, không phải phép kiểm; upload lỗi vẫn làm lượt chạy đỏ và GitHub gửi thông báo). `if: always()`, đọc
  `toJSON(needs)` qua `env:`, thoát ≠ 0 khi bất kỳ job nào khác `success`, kể cả `skipped`: bảy job này không có điều
  kiện, nên `skipped` ở đây chỉ có thể là `if:` viết sai. Không bao giờ có điều kiện làm chính `ci-ok` bị bỏ qua: GitHub
  tính check `skipped` là đạt ("Successful check statuses are `success`, `skipped`, and `neutral`", tài liệu
  "Troubleshooting required status checks").
- **Contract chung của hai check tổng** (`ci-ok`, `images-ok`): `failure`, `cancelled` luôn đỏ; `skipped` chỉ được nhận
  cho job có trong bảng "bỏ qua hợp lệ" của workflow đó (`ci.yml`: không job nào; `images.yml`: bảng job ở mục 4), khi
  chính job tổng tính lại điều kiện từ sự kiện, ref và output của `plan` và thấy đúng; job khác `skipped` là đỏ. Job
  chỉ để báo cáo (`sarif`) không nằm trong `needs`.
- **`TESTFLAGS`, `LINTFLAGS`:** `make test` và `make cover` nhận `TESTFLAGS ?=`, `make lint` nhận `LINTFLAGS ?=`, cùng chèn
  trước `$(PKGS)` (rỗng thì lệnh như cũ), ví dụ `make test TESTFLAGS=-count=1`.

## 3. Chỉ build service có thay đổi

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Lọc đường dẫn theo `image_paths` của `deploy/k8s/lib.sh`** | Một nguồn với tập đường dẫn `make k8s-release` từng kiểm; một hàm shell, chạy được trên máy | Build thừa: đổi một gói trong `internal/` mà chỉ một service import vẫn build cả sáu |
| `go list -deps` theo từng service | Ít build thừa nhất | Thêm logic phải đúng mãi (đồ thị import, `embed` migration SQL, code sinh), cần Go ở job chọn service |
| Action lọc đường dẫn (`dorny/paths-filter`, `tj-actions/changed-files`) | Có sẵn | Action bên thứ ba đọc được token và log của job (mục 1) |
| `paths:` ở trigger | GitHub tự lọc | Workflow không chạy thì check bắt buộc không bao giờ có, PR treo "Expected — Waiting for status to be reported" |
| Base = `github.event.before` (commit ngay trước push) | Có sẵn trong event | Mất thay đổi khi lượt chờ bị lượt mới thay hay lượt trước lỗi (bên dưới) |
| Concurrency `queue: max` (tới 100 lượt chờ, changelog 2026-05-07) | Không lượt chờ nào bị thay | Không cứu lượt lỗi; không đi cùng `cancel-in-progress: true`; thứ tự FIFO "không bảo đảm" (tài liệu concurrency) |
| **Base = `head_sha` của lượt `images.yml` push `main` thành công gần nhất** | Lượt lỗi hay bị bỏ khỏi hàng chờ được lượt sau build bù | Một lời gọi API Actions; không có, force push hay API lỗi thì build cả sáu |

### Quyết định

- **Tập đường dẫn của một image** = `image_paths <svc>` của `deploy/k8s/lib.sh` (`go.mod`, `go.sum`, `gen`, `internal`,
  `services/<svc>`, Dockerfile của nó, `.dockerignore`). Script `deploy/ci/changed-services.sh <base> <head>` source
  `lib.sh` và dùng đúng `image_paths`, `svp_services`, không chép danh sách. Đổi đường build, quét, ký thì **build lại cả
  sáu**: `.github/workflows/images.yml`, bất cứ gì dưới `deploy/ci/`, cả file `deploy/k8s/lib.sh` (hàm đọc và ghi values,
  `ghcr_prefix`, `docker_` mà script CI dùng chung), và `Makefile` khi dòng ghim `TRIVY_IMAGE`, `SYFT_IMAGE` hay
  `COSIGN_IMAGE` đổi (`git diff -G`, dòng khác của `Makefile` không tính). Lý do: PR nâng trivy hay đổi hàm dùng chung
  chạy cổng quét mới trên cả sáu trước merge, thay vì để rescan hằng ngày trên `main` lộ khác biệt (dừng attest, 72 giờ
  sau Kyverno từ chối pod mới). Cái giá trên `main`: phát hành lại cả sáu (digest mới), PR promote cập nhật, gateway có
  canary dù code không đổi. Hệ quả của tập này: đổi `internal/`, `gen/`,
  `go.mod`, `go.sum`, `.dockerignore` build cả sáu; đổi `deploy/docker/service.Dockerfile` build năm service Go thuần; đổi
  `deploy/docker/media-worker.Dockerfile` chỉ build media-worker.
- **Không dùng `go list -deps`:** ít build thừa hơn nhưng thêm logic; với sáu service, build thừa chỉ tốn phút runner miễn
  phí. Xem lại khi build CI của một thay đổi nhỏ quá 10 phút (cùng điều kiện "Xem lại khi" của ADR-0007).
- **Go test luôn chạy toàn repo** (`make check` ở `ci.yml`, phần test khoảng 10 s): lọc chỉ áp cho image.
- **Lọc ở cấp job:** job `plan` in danh sách service vào output; job build chạy theo ma trận từ danh sách đó; danh sách
  rỗng thì job build không chạy và `images-ok` vẫn xanh (bỏ qua hợp lệ, bảng job ở mục 4).
- **Base của phép so** (không dùng `github.event.before`):
  - **Push `main`:** `head_sha` của lượt `images.yml` gần nhất trên `main` có `event=push` và kết luận `success`
    (`GET /repos/anhnvcoder/short-video-platform/actions/workflows/images.yml/runs?branch=main&event=push&status=success`).
    Lời gọi nằm ở job riêng `last-success` (chỉ push `main`, `actions: read`, không checkout, không chạy code của repo; API
    lỗi thì output rỗng và job vẫn xanh); `plan` chỉ có `contents: read` và nhận output đó. Ba trường hợp:
    - `head_sha` là tổ tiên của HEAD hay chính HEAD → so `head_sha..HEAD`.
    - HEAD là tổ tiên thật sự của `head_sha` (chạy lại một lượt cũ sau khi lượt mới hơn đã thành công) → **không build
      gì**, ghi summary: lượt mới hơn đã build mọi thay đổi tới commit của nó.
    - Không có lượt nào, output rỗng, hay hai commit không so được (force push, lịch sử bị viết lại) → **cả sáu**, ghi lý
      do vào job summary: build thừa, không bao giờ sót.
    - Base chỉ quyết build bao nhiêu; việc không ghi lùi bản phát hành nằm ở promote (mục 9), không dựa vào base.
  - **Pull request:** merge-base của HEAD với nhánh base của PR (checkout đủ lịch sử).
  - **`workflow_dispatch`:** merge-base của HEAD với `origin/main`. Input `services` (`all` hay danh sách tên cách bằng
    khoảng trắng, mỗi tên phải thuộc `svp_services`, đọc qua `env:`) ghi đè phép so. Trên `main` merge-base là chính HEAD,
    nên chỉ có input `services` mới build: build lại cùng commit để lấy bản vá của gói chưa ghim (`ffmpeg` của Alpine,
    mục 4, 6), rồi ký và promote như lượt push.
  - **Vì sao không `github.event.before`:** concurrency mặc định giữ tối đa một lượt chạy và một lượt chờ mỗi group, lượt
    chờ mới huỷ và thay lượt chờ cũ ("By default, any existing `pending` job or workflow in the same concurrency group will
    be canceled and the new queued job or workflow will take its place", tài liệu concurrency); và một lượt lỗi để lại
    service chưa phát hành. So với commit ngay trước thì thay đổi của lượt bị thay hay lượt lỗi mất. Ví dụ ba push liên
    tiếp: A đang chạy, B (đổi gateway) chờ, C (đổi feed-service) tới và thay B. Khi C chạy, base là A nếu A thành công,
    nên C build **gateway và feed-service**; nếu A lỗi, base lùi về trước A và C build bù cả service của A.
  - `queue: max` có trên GitHub.com từ 2026-05-07; không dùng, vì quy tắc base trên đã đúng với `queue: single` mặc định
    và vẫn cần cho lượt lỗi.
- **Concurrency của `images.yml`:** group theo ref **và** chế độ, `images-${{ github.ref }}-<build|rescan|drill>`;
  `cancel-in-progress` chỉ khi `github.event_name == 'pull_request'` (không huỷ lượt `main` đang ký hay promote). Tách
  chế độ vì rescan theo lịch và image diễn tập cũng chạy trên `refs/heads/main`: chung group thì chúng thay một lượt push
  đang chờ, và thay đổi của lượt đó chỉ được build ở push kế tiếp. Lượt build trên `main` chạy lần lượt, nên một lượt luôn
  thấy kết quả của lượt trước khi tính base.
- **Một service lỗi không giữ service khác:** ma trận build `fail-fast: false`; service nào qua cổng ở cả hai kiến trúc
  thì được ghép index, ký, attest và promote; `images-ok` đỏ khi bất kỳ chân nào lỗi. Lượt đó không `success`, nên base
  không tiến và lượt sau build lại service lỗi cùng mọi service đã đổi từ lần thành công cuối.

## 4. Image đa kiến trúc, build native, chỉ push đúng thứ đã quét

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Ma trận service × {`ubuntu-24.04`, `ubuntu-24.04-arm`}, build native rồi ghép index** | Không giả lập; Dockerfile giữ nguyên cho đường dev; hai kiến trúc build song song | Gấp đôi số job; phải ghép index ở một job sau |
| QEMU trên runner amd64 (`--platform linux/amd64,linux/arm64`) | Một job | `go build` và `apk add ffmpeg` dưới giả lập chậm nhiều lần; thêm action `setup-qemu` |
| Cross-compile Go trong Dockerfile (`--platform=$BUILDPLATFORM`, `GOARCH`) | Build Go nhanh trên một runner | Stage runtime của media-worker vẫn phải `RUN apk add` theo kiến trúc đích (vẫn cần QEMU); đổi Dockerfile của đường dev |
| Push lên GHCR rồi quét theo digest | Quét đúng thứ trên registry | Image (cả bí mật nếu có) đã nằm trong package public trước khi cổng chạy; xoá sau không thu hồi được |
| Build hai lần (một lần quét, một lần `--push`) | Đơn giản | Không bảo đảm cùng nội dung (cache, giờ, mạng lúc `apk add`) |
| Xuất OCI layout rồi push bằng `skopeo` (có sẵn 1.13.3 trên cả hai runner) | Manifest digest giống hệt bản quét | Exporter `oci` cần driver `docker-container`, thêm image BuildKit phải ghim digest |
| **`--load` vào Docker của runner, `docker save` ra tar, quét tar, `docker push`, so config digest** | Chỉ dùng `docker`/`buildx` có sẵn trên cả hai runner; config digest giống nhau nghĩa là cùng nội dung đã quét | Manifest digest trên GHCR khác bản cục bộ (Docker nén lại layer); phải so config digest sau push |

### Quyết định

- **Ma trận** `service × arch`: `amd64` trên `ubuntu-24.04`, `arm64` trên `ubuntu-24.04-arm` (miễn phí cho repo public,
  GA 2025-08-07, 4 vCPU; changelog "Arm64 hosted runners for public repositories are now generally available"). Hai job
  cùng ma trận gọi chung `deploy/ci/build-image.sh` cho bước 1–3 (mục 1): **`build-nopush`** (PR và mọi ref khác `main`,
  chỉ `contents: read`) dừng sau bước 3; **`build`** (chỉ `refs/heads/main`, chế độ build) có thêm `packages: write` và
  chạy bước 4–5. Mỗi chân, theo thứ tự; không bước nào đẩy gì lên GHCR trước bước 4:
  1. `docker buildx build --load --provenance=false --sbom=false` từ Dockerfile hiện có (driver `docker` mặc định, kiến
     trúc của chính runner), tag cục bộ, label OCI của mục 5. Không QEMU, không cross-compile; Dockerfile giữ nguyên cho
     đường dev (`make up`, `make k8s-up`). Tắt provenance/SBOM của BuildKit để image là một manifest đơn, không kèm manifest
     attestation `unknown/unknown`.
  2. `docker save` ra tar trong `$RUNNER_TEMP`; trivy (mục 6) và syft (mục 7) đọc **chính tar đó** bằng `docker run` image
     ghim digest, tar mount chỉ đọc. Trivy ghi `Metadata.ImageID` = config digest của image (`ID()` gọi `ConfigName()`,
     `pkg/fanal/image/image.go`, `archive.go@v0.76.0`); với tar, `RepoDigests` luôn rỗng.
  3. `deploy/ci/scan-gate.sh` (mục 6). Lỗi thì dừng. `build-nopush` luôn dừng sau bước này (không push).
  4. Chỉ ở job `build`, cổng đạt: `docker push ghcr.io/anhnvcoder/short-video-platform/<svc>:<12 hex>-<arch>`; lấy digest
     manifest vừa đẩy, đọc manifest đó từ GHCR (`docker buildx imagetools inspect --raw <repo>@<digest>`) và so
     `.config.digest` với `Metadata.ImageID` của báo cáo đã quét; lệch → job đỏ, digest đó không được ghép, ký hay promote.
     Config chứa `rootfs.diff_ids` (digest từng layer chưa nén), nên cùng config digest nghĩa là cùng nội dung đã quét, dù
     Docker 28 (image store cổ điển) nén lại layer khi push và manifest digest khác bản cục bộ.
  5. Ghi artifact của chân (`actions/upload-artifact`): digest manifest con, báo cáo JSON trivy, SBOM, giờ bắt đầu và kết
     thúc quét. Artifact là đầu vào duy nhất của `merge` và `sign`.
  6. Chỉ image `web` (thêm 2026-10-28, [ADR-0021](0021-deferred-verification-stage6b.md) §6): ngay sau `buildx build --load`,
     `deploy/ci/build-image.sh` xuất stage `sourcemaps` của `deploy/docker/web.Dockerfile` cùng build cache, cùng `SVP_BUILD_ID`,
     kiểm bộ file (chỉ `_next/static/**/*.{js,map}`, mọi `.js` còn `sourceMappingURL`) và kiểm mọi debug ID của chunk trong image
     vừa build có trong bộ map (cả ở lượt PR); ở lượt phát hành, sau bước push, upload artifact `web-sourcemaps-<arch>` mang thêm
     file `image-digest` (digest manifest con đã push của chính chân đó). Lượt PR không upload: không có digest để khớp.
- **Job `merge`** (mỗi service, khi cả hai chân đạt; `packages: write`): `docker buildx imagetools create --tag
  <repo>:<12 hex>` từ đúng hai `<repo>@<digest con>` trong artifact, kèm annotation index của mục 5 (`--annotation
  "index:<khoá>=<giá trị>"`, `docs/reference/buildx_imagetools_create.md` của buildx); đọc lại index và kiểm nó có đúng hai
  manifest, `linux/amd64` và `linux/arm64`, đúng hai digest đó. Digest index là thứ được ký, attest và promote.
- **Manifest con đã push mà chưa ký:** chân amd64 đạt còn arm64 lỗi thì manifest con amd64 đã nằm trên GHCR (đã qua cổng:
  không bí mật, không CRITICAL) nhưng không có index, chữ ký hay attestation; Kyverno từ chối nó (mục 8).
- **Base image ghim digest** trong Dockerfile, dạng `tag@sha256:<index đa kiến trúc>` (bảng mục 1): `golang:1.27.2-trixie`,
  `gcr.io/distroless/static-debian13:nonroot`, `alpine:3.24.2`; giữ comment cũ, thêm lý do ghim; Renovate cập nhật digest
  (mục 10). Gói `ffmpeg` của Alpine vẫn không ghim version (ADR-0008 §9): build lại lấy bản vá của nhánh 3.24, và trivy
  quét đúng bản đã cài. **Không dòng `# syntax=`** trong Dockerfile nào (cả image diễn tập): frontend có sẵn của BuildKit
  đã chạy `RUN --mount`, còn image frontend sẽ kéo từ Docker Hub theo tag đẩy lại được, là image duy nhất của đường build
  không ghim digest.
- **Login GHCR** chỉ ở job có `packages: write`: `docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin` với
  `GITHUB_TOKEN` qua `env:`. Không action login nào.
- **Job của `images.yml`** (contract của quyền và của `images-ok`). Chế độ do `plan` tính và xuất ra: `rescan` khi
  `schedule` hay dispatch `rescan=true`, `drill` khi dispatch `drill=true`, còn lại `build`; cả hai input cùng bật, hay
  `rescan`/`drill` trên ref khác `main`, thì `plan` đỏ. Group concurrency (mục 3) tính cùng quy tắc bằng biểu thức trên
  `github.event_name` và `inputs`. Mọi job có quyền ghi còn có điều kiện `github.event_name != 'pull_request'` và
  `github.ref == 'refs/heads/main'`.

  | Job | Chạy khi | Quyền | `skipped` hợp lệ khi |
  | --- | --- | --- | --- |
  | `last-success` | push `main` (mục 3) | `actions: read` | sự kiện khác push |
  | `plan` | mọi lượt | `contents: read` | không bao giờ |
  | `build-nopush` | ref khác `main`, danh sách service khác rỗng | `contents: read` | ref là `main`, hay danh sách rỗng |
  | `values-check` | ref khác `main`, `plan` báo `deploy/k8s/values/services/` đổi so với base (mục 7) | `contents: read` | ref là `main`, hay `plan` báo không đổi |
  | `build` | `main`, chế độ build, danh sách khác rỗng | `contents: read`, `packages: write` | ref khác `main`, chế độ khác build, hay danh sách rỗng |
  | `merge` (ghép index) | sau `build` | `contents: read`, `packages: write` | như `build` |
  | `sign` (ký, attest) | sau `merge` | `contents: read`, `packages: write`, `id-token: write` | như `build` |
  | `promote` | sau `sign` (mục 9) | `contents: write`, `pull-requests: write` | như `build` |
  | `rescan` | `main`, chế độ rescan (mục 7) | `contents: read`, `pull-requests: read`, `packages: write`, `id-token: write` | chế độ khác rescan |
  | `drill-*` (image diễn tập) | `main`, chế độ drill (mục 7) | `contents: read`, `packages: write`, `id-token: write` | chế độ khác drill |
  | `sarif` | `main`, sự kiện khác `pull_request` | `security-events: write` | không nằm trong `needs` của `images-ok` |
  | `images-ok` | mọi lượt, `if: always()` | không quyền nào | không bao giờ |

## 5. Tên, tag và version của image

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Version = 12 hex đầu SHA commit** (quy ước ADR-0014 §6) | Truy thẳng về commit; không thêm luồng nào | Không đọc ra mức thay đổi (patch/minor) |
| Semver theo từng service (release-please, tag git `gateway/v1.4.0`) | Ghi chú phát hành, mức thay đổi rõ | Thêm một PR phát hành song song PR promote; commit phải theo quy ước để tính version; không thêm thông tin cho người tiêu thụ duy nhất là GitOps của repo này |
| Semver chung cả repo | Một version | Mọi service "lên version" dù không đổi |
| Tag `latest` hay theo nhánh | Không ghi gì | Không bất biến; Argo CD và kubelet không biết image đã đổi |

### Quyết định

- **Tên:** `ghcr.io/anhnvcoder/short-video-platform/<svc>` cho 6 service (`gateway`, `user-service`, `video-service`,
  `engagement-service`, `feed-service`, `media-worker`); hai image diễn tập `…/drill-vulnerable`, `…/drill-unsigned`
  (mục 7, 8). Không image nào khác được đẩy vào namespace này.
- **Tag:** index đa kiến trúc `<12 hex>`; hai manifest con `<12 hex>-amd64`, `<12 hex>-arm64` (`docker push` cần một tag).
  Tag trên GHCR **đổi được** (ai có `packages: write` đẩy lại cùng tag), nên mọi chỗ triển khai trỏ **digest**:
  `image.digest` trong values (mục 9), Kyverno từ chối image không có digest (mục 8). Tag chỉ để người đọc.
- **Label OCI trên config** (`docker buildx build --label`): `org.opencontainers.image.source` =
  `https://github.com/anhnvcoder/short-video-platform`, `org.opencontainers.image.revision` = SHA 40 hex,
  `org.opencontainers.image.created` = giờ commit (UTC, RFC 3339): cùng commit cho cùng label, không đổi theo giờ build.
  Index mang ba annotation cùng giá trị. GHCR liên kết package với repo khi label `org.opencontainers.image.source` có từ
  lần publish đầu ("A package only inherits the access permissions of a linked repository automatically if you link the
  repository to the package before you publish the package, such as by adding the `org.opencontainers.image.source`
  Docker label", tài liệu GitHub Packages).
- **Version = SHA commit, không semver theo service:** người tiêu thụ duy nhất của image là GitOps của chính repo này;
  contract giữa các service đã có version riêng (`proto/svp/<domain>/v1` và `buf breaking`, ADR-0006), image không phải
  contract. Semver hay release-please thêm luồng PR thứ hai song song PR promote mà không thêm thông tin nào cho Argo CD.
  Xem lại khi: image có người tiêu thụ ngoài repo, hoặc nhiều môi trường cần ghi chú phát hành (giai đoạn 7).
- **Visibility:** tài liệu GitHub tự mâu thuẫn: trang workflow ghi package do `GITHUB_TOKEN` tạo "inherits the visibility
  and permissions model of the repository", trang access control ghi package của tài khoản cá nhân lần publish đầu "the
  default visibility is private". REST của GitHub Packages chỉ có GET, DELETE và restore, **không có API đổi
  visibility**: đổi ở Package settings → Change visibility, và "Once you make a package public, you cannot make it private
  again". Sau push đầu đọc `visibility` của từng package, chỉ đọc:
  `gh api users/anhnvcoder/packages/container/short-video-platform%2F<svc> -q .visibility`; package nào `private` thì người
  học bấm public một lần (6 package service, 2 package diễn tập). Cluster GitOps kéo ẩn danh, nên package private thì
  `gitops.sh` dừng trước khi tạo cluster (mục 9).

## 6. Quét lỗ hổng và bí mật, trước khi push

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Chặn CRITICAL (kể cả chưa có bản vá), HIGH chỉ báo** | Lỗ hổng nặng nhất không lên cluster; phát hành không đứng vì lỗi không ai sửa được | HIGH có bản vá có thể nằm lâu nếu không ai đọc báo cáo |
| Chặn cả HIGH | Chặt hơn | Base Alpine + ffmpeg thường có HIGH chưa có bản vá: mọi phát hành đứng vì việc ngoài tầm tay |
| Chặn CRITICAL chỉ khi có bản vá (`--ignore-unfixed`) | Ít chặn | CRITICAL chưa vá vẫn chạy trong cluster, trái tiêu chí "Xong khi" |
| **Bí mật: mọi phát hiện chặn, mọi severity, không đường bỏ qua** | Package public và chữ ký không thu hồi được bí mật đã đẩy lên; sửa image rẻ hơn xoay khoá | Phát hiện giả cũng chặn (phải sửa image) |
| Bỏ qua bằng `.trivyignore` (dạng chữ) | Đơn giản | Không lý do, không hạn: mục bỏ qua sống mãi |
| **Bỏ qua bằng `.trivyignore.yaml`: lý do + hạn ≤ 30 ngày, thêm qua PR** | Mỗi ngoại lệ có lý do, tự hết hạn, có người review | Định dạng YAML của trivy còn EXPERIMENTAL, phải truyền `--ignorefile` |

### Quyết định

- **Một lần quét mỗi kiến trúc**, trên tar cục bộ của mục 4, trivy bản ghim:
  `trivy image --input <tar> --scanners vuln,secret --ignorefile .trivyignore.yaml --format json --output <report>` (mặc
  định mọi severity, thoát 0). `deploy/ci/scan-gate.sh` đọc báo cáo JSON đó và quyết:
  - **Bí mật:** bất kỳ phần tử `Results[].Secrets[]` nào → thoát ≠ 0, mọi severity (trivy lọc bí mật theo `--severity`
    như lỗ hổng, `filterSecrets` ở `pkg/result/filter.go@v0.76.0`; không truyền `--severity` nên giữ hết). Không đường bỏ
    qua: script từ chối `.trivyignore.yaml` có khoá gốc nào khác `vulnerabilities` (định dạng này có cả `secrets`,
    `misconfigurations`, `licenses`, mọi phần đều được `Prune`/áp dụng, `pkg/result/ignore.go@v0.76.0`), và không truyền
    `--skip-files`, `--skip-dirs`, `--secret-config`. Báo cáo, SARIF và summary chỉ có mã quy tắc, file, dòng: trivy che giá
    trị bí mật trong phát hiện (`censorLocation`, `pkg/fanal/secret/scanner.go@v0.76.0`).
  - **Lỗ hổng:** phần tử `Results[].Vulnerabilities[]` có `Severity` `CRITICAL` (sau `.trivyignore.yaml`) → thoát ≠ 0, kể cả
    chưa có bản vá. HIGH và các mức khác chỉ báo: SARIF và bảng trong job summary.
  - Thoát ≠ 0 thì không push gì (mục 4), không ký, không attest.
- **Giới hạn của quét bí mật trong image:** trivy bỏ qua file nhị phân trừ `.pyc` (`allowedBinaries`,
  `pkg/fanal/analyzer/secret/secret.go@v0.76.0`), nên khoá biên dịch hay `embed` vào binary Go không bị phát hiện ở đây;
  gitleaks toàn lịch sử ở `ci.yml` bắt nó ở mã nguồn (SEC-1, JWT-10). Quét image bắt file bí mật bị chép vào image (SEC-2).
- **SARIF:** `trivy convert --format sarif --severity HIGH,CRITICAL <report>` (convert chạy cùng bộ lọc của lúc quét,
  `pkg/commands/convert/run.go@v0.76.0`), category `trivy-image-<svc>-<arch>`, upload bằng job `sarif` (mục 4) trên `main`
  và ở lượt rescan; PR chỉ ghi bảng vào job summary.
- **`.trivyignore.yaml` ở gốc repo**, chỉ cho lỗ hổng: mỗi mục `id` (CVE hay GHSA), `statement` (lý do, bắt buộc),
  `expired_at` (`yyyy-mm-dd`), phạm vi hẹp nhất có thể (`purls` hay `paths`). `scan-gate.sh` từ chối mục thiếu `statement`
  hay `expired_at`, và mục có `expired_at` quá **30 ngày** sau ngày chạy, nên không mục nào sống quá 30 ngày kể từ lúc
  thêm. Trivy bỏ mục hết hạn trước khi tính kết quả (`Prune`: `ExpiredAt.Before(now)` thì bỏ), nên lỗ hổng hiện lại và cổng
  chặn lại. Mục thôi tác dụng từ **00:00 UTC** ngày `expired_at` (07:00 giờ Việt Nam): `gopkg.in/yaml.v3` v3.0.1, bản
  trivy v0.76.0 dùng, đọc `expired_at: 2026-11-19` thành `2026-11-19T00:00:00Z` (chạy thử trong thư mục tạm); đường đầu-cuối
  qua trivy kiểm ở mục "Kiểm chứng sau phát hành". Thêm
  mục là một PR được review; có bản vá ở base mới hơn thì nâng base thay vì bỏ qua. Đổi riêng `.trivyignore.yaml` không
  build lại gì: service bị chặn ở lượt trước chưa phát hành nên vẫn nằm trong phép so của lượt sau (mục 3). Vì PR như thế
  không chạy cổng image nào, quy tắc của file được kiểm ở **mọi PR** bằng `scan-gate.sh --check-ignorefile` trong job
  `config` của `ci.yml` (mục 2): mục sai quy tắc mà vào `main` sẽ làm rescan từ chối attest cả sáu service.
- **Trivy DB:** chỉ DB lỗ hổng chính. Trivy v0.76.0 tải `mirror.gcr.io/aquasec/trivy-db:2`, gặp 429 hay 5xx thì sang
  `ghcr.io/aquasecurity/trivy-db:2` (`pkg/flag/db_flags.go`, `docs/guide/configuration/db.md@v0.76.0`); Java DB chỉ tải khi
  gặp file JAR (image của project không có). Thư mục cache của trivy lưu bằng `actions/cache`, khoá theo ngày (cách trivy
  khuyên để tránh giới hạn tải, discussion aquasecurity/trivy#8009); trivy vẫn tự tải bản mới khi DB trong cache cũ.
  Không tải được DB thì trivy lỗi và job đỏ (không quét bằng DB không rõ tuổi): chạy lại job. Cache tạo trên `main` không bị
  lượt PR ghi đè: cache của PR chỉ nằm ở ref `refs/pull/.../merge` (tài liệu "Restrictions for accessing a cache").
- **govulncheck để sau** (mục 12): trivy đã đọc module trong binary Go (`-trimpath` vẫn giữ build info).
- Cái giá: HIGH có bản vá chỉ hiện ở SARIF và summary. Xem lại khi số HIGH có bản vá còn mở quá 30 ngày.

## 7. SBOM, chữ ký, attestation (SC-1)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **cosign keyless (OIDC của GitHub → Fulcio, ghi Rekor)** | Không khoá dài hạn nào để lộ hay xoay; identity là workflow và ref, Kyverno kiểm được | Phụ thuộc Sigstore công khai lúc ký và lúc xác minh; identity ghi công khai trên Rekor |
| cosign với khoá (KMS hay file) | Không phụ thuộc Fulcio | Một khoá dài hạn trong secret của repo public; phải xoay |
| Notation (Notary v2) | Chuẩn OCI, Kyverno đọc được | Cần CA và khoá riêng; ít công cụ đi kèm |
| **Ký theo digest index đa kiến trúc** | Pod trỏ digest index, nên Kyverno xác minh đúng thứ chạy | Muốn xác minh một manifest con phải đi qua index |
| Ký theo tag | Đơn giản | Tag đổi được: chữ ký không gắn với nội dung |
| **Attestation `vuln` trên index gộp kết quả quét hai nền tảng** | Kyverno đọc một attestation cho cả image; thiếu nền tảng là từ chối được | `scanner.result` là contract riêng của project |
| Quét index một lần | Một báo cáo | Trivy mặc định chọn `linux/amd64` khi đọc index (`docs/guide/target/container_image.md@v0.76.0`): không chứng minh arm64 sạch |
| **SBOM SPDX mỗi nền tảng, attest trên digest manifest con** | Mỗi SBOM mô tả đúng nội dung một nền tảng (gói apk, binary khác nhau); công cụ đọc SBOM theo digest đang chạy tìm thấy nó | Hai attestation SBOM mỗi image; tìm SBOM từ index phải đọc manifest con |
| Một SBOM gộp trên index | Một chỗ | Không công cụ nào gộp hai SPDX thành một tài liệu đúng; SBOM gộp không khớp nội dung của manifest nào |
| **Định dạng cũ của cosign (`.sig`/`.att`), `--replace` cho `vuln`** | Đúng một attestation `vuln` sau mỗi lần rescan; Kyverno 1.19.1 đọc được; GHCR lưu được (image `ghcr.io/kyverno/kyverno:v1.19.1` có tag `.att`) | Hai cờ đang dùng (`--new-bundle-format`, `--replace`) đã deprecated ở v3.1.3, `--use-signing-config` deprecated trên nhánh `main` của cosign; cosign v4 sẽ bỏ; chỉ Rekor v1, không dấu thời gian TSA |
| Bundle mới (mặc định của cosign v3, OCI 1.1 referrer) | Không cờ nào; định dạng chuẩn của Sigstore | `--replace` bị bỏ qua: sau N lần rescan còn N+1 attestation `vuln`; Kyverno 1.19.1 chọn một cái bất kỳ |

### Quyết định

- **SBOM:** syft bản ghim đọc tar của mục 4: `syft docker-archive:/img.tar -o spdx-json=/out/sbom.spdx.json`
  (`--network none`), một SPDX JSON mỗi nền tảng, attest trên **digest manifest con** của nền tảng đó (`--type spdxjson`).
  Không SBOM nào trên index. Kyverno giai đoạn 5 không kiểm SBOM. Phép kiểm tương ứng: `cosign verify-attestation --type
  spdxjson` trên từng digest con cho đúng một attestation có `subject[0].digest.sha256` bằng digest con đó; trên digest
  index không có attestation `spdxjson` nào.
- **cosign v3.1.3, định dạng cũ cho mọi lệnh ký và attest:** `--new-bundle-format=false --use-signing-config=false` (hai
  cờ đi cùng nhau: `--new-bundle-format=false` một mình bị từ chối khi signing config đang bật,
  `cmd/cosign/cli/signcommon/common.go@v3.1.3`). Không đặt `--rekor-url`, `--tlog-upload` (giữ mặc định: Rekor v1
  `rekor.sigstore.dev`, Fulcio `fulcio.sigstore.dev`).
  - `cosign sign --yes --new-bundle-format=false --use-signing-config=false <repo>@<digest index>` (không `--recursive`:
    pod trỏ digest index).
  - `cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type spdxjson --predicate
    <sbom> <repo>@<digest con>` cho mỗi nền tảng.
  - `cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type vuln --predicate
    <vuln.json> <repo>@<digest index>`, ở lượt build và ở mỗi lượt rescan.
  - **Vì sao định dạng cũ** (mã ở tag, 2026-10-20): ở bundle mới, `cosign attest` trả về trước nhánh `--replace`
    (`cmd/cosign/cli/attest/attest.go@v3.1.3`), mỗi lượt thêm một referrer; ở định dạng cũ, `ReplaceOp`
    (`pkg/cosign/remote/remote.go@v3.1.3`) thay layer cùng `predicateType` và giữ layer khác, nên image `.att` của index
    luôn có **đúng một** `vuln`. ImageValidatingPolicy của Kyverno v1.19.1 lưu payload đã xác minh trong map theo
    `predicateType` (`AddVerifiedIntotoPayloads`, `extensions/imagedataloader/loader.go` của `kyverno/sdk`): nhiều attestation
    cùng loại thì cái đọc sau cùng thắng, không phải cái mới nhất (issue kyverno/kyverno#18023; bản sửa #18049 merge vào
    `main` 2026-10-17, chưa có trong bản phát hành nào). GHCR không có API referrers (`GET /v2/<name>/referrers/<digest>`
    trả 404 `MANIFEST_UNKNOWN`, thử ẩn danh 2026-10-20), bundle mới phải đi tag dự phòng `sha256-<hex>`, được cập nhật kiểu
    đọc-sửa-ghi không khoá (`pkg/v1/remote/write.go` của go-containerregistry v0.21.7).
  - **Không bao giờ trộn hai định dạng trên một digest:** có bất kỳ bundle mới nào thì cả `cosign verify`
    (`cmd/cosign/cli/verify/verify.go@v3.1.3`) lẫn Kyverno (`pkg/image/verifiers/ivpol/cosign/verifier.go@v1.19.1`, tự dò
    bundle) chỉ đọc bundle và bỏ `.sig`/`.att`. Image diễn tập cũng ký định dạng cũ.
  - GHSA-fx35-mq7g-6g98 (cosign ≤ 3.1.2: bỏ qua kiểm identity với bundle JSON cũ) chỉ chạm `verify-blob`,
    `verify-blob-attestation`; xác minh image (`cosign verify`, `verify-attestation`) không bị ảnh hưởng (advisory).
  - Không ghim signing config Rekor v2: TUF hiện phát Rekor v1 (`signing_config.v0.2.json`), và hỗ trợ Rekor v2 của Kyverno
    chưa có test (issue kyverno/kyverno#15557 còn mở).
- **Identity ký** (Kyverno và `cosign verify` kiểm đúng hai giá trị này):
  - issuer `https://token.actions.githubusercontent.com`;
  - subject `https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main` (SAN của
    chứng chỉ Fulcio là `server_url + job_workflow_ref`, Build Signer URI, `docs/oid-info.md` của Fulcio). Mọi trigger của
    `images.yml` trên `main` (push, lịch, dispatch) có cùng subject; lượt của PR không có `id-token: write`, và lượt của
    nhánh khác có subject khác nên Kyverno từ chối.
  - `id-token: write` chỉ ở `sign`, `rescan` và job ký của image diễn tập (bảng job mục 4); các job đó có `packages:
    write` để ghi `.sig`/`.att`, không dùng cache nào.
  - Rekor là log công khai: chứng chỉ ghi repo, workflow, ref, commit, link lượt chạy của mỗi lần ký ("will be stored in
    public transparency logs and cannot be removed later", `cmd/cosign/cli/sign/privacy/privacy.go@v3.1.3`). Repo đã
    public nên không lộ thêm gì.
- **Contract của predicate `vuln` cho index** (một script `deploy/ci/vuln-predicate.sh` dựng nó, dùng chung cho build và
  rescan). Trivy quét một nền tảng mỗi lần, nên predicate gộp đúng hai lần quét chặn của mục 6, mỗi lần trên một manifest
  con:

  ```json
  {
    "invocation": {
      "uri": "https://github.com/anhnvcoder/short-video-platform/actions/runs/<run_id>/attempts/<attempt>",
      "event_id": "<run_id>",
      "builder.id": "https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main",
      "parameters": null
    },
    "scanner": {
      "uri": "pkg:github/aquasecurity/trivy@v0.76.0",
      "version": "0.76.0",
      "db": {"uri": "<repository DB trivy đã dùng>", "version": "<UpdatedAt của DB, RFC 3339>"},
      "result": {
        "platforms": [
          {"platform": "linux/amd64", "digest": "sha256:<manifest con amd64>", "report": {"SchemaVersion": 2}},
          {"platform": "linux/arm64", "digest": "sha256:<manifest con arm64>", "report": {"SchemaVersion": 2}}
        ]
      }
    },
    "metadata": {"scanStartedOn": "<RFC 3339 UTC>", "scanFinishedOn": "<RFC 3339 UTC>"}
  }
  ```

  - `scanner.result.platforms` có **đúng hai** phần tử, thứ tự `linux/amd64` rồi `linux/arm64`; `digest` là `sha256:<64
    hex>` của manifest con nằm trong index đã ký; `report` là **toàn bộ** báo cáo JSON trivy của chính lần quét chặn trên
    manifest đó (trong ví dụ chỉ ghi khoá đầu), sau `.trivyignore.yaml` (mục bỏ qua không có trong `Vulnerabilities`), và
    `report.Metadata.ImageID` bằng config digest của manifest con.
  - `metadata.scanStartedOn` = lần bắt đầu sớm hơn trong hai; `metadata.scanFinishedOn` = giờ kết thúc của lần quét **cũ
    hơn** trong hai (tuổi của attestation là tuổi của kết quả cũ nhất). RFC 3339 bắt buộc: cosign đọc predicate vào struct
    `CosignVulnPredicate` (`pkg/cosign/attestation/attestation.go@v3.1.3`), giờ sai dạng thì `attest` lỗi; trường ngoài
    `invocation`, `scanner`, `metadata` bị bỏ; `scanner.result` là `interface{}` nên giữ nguyên nội dung (số thành số
    thực). `predicateType` là `https://cosign.sigstore.dev/attestation/vuln/v1`; in-toto statement có `subject` là digest
    index.
  - Script thoát ≠ 0 khi thiếu hay thừa nền tảng, digest sai dạng, `ImageID` lệch hay báo cáo có CRITICAL; cờ
    `--allow-critical` chỉ dùng cho rescan (ghi kết quả thật rồi job đỏ) và cho `drill-vulnerable`.
  - Kyverno đọc payload là cả in-toto statement, nên đường dẫn trong policy là `predicate.metadata.scanFinishedOn`,
    `predicate.scanner.result.platforms` (mục 8). Hai digest con nằm bất biến trong index đã ký nên ai cũng đối chiếu được;
    **Kyverno không tự đối chiếu** chúng với index (giới hạn đã biết).
- **Chỉ ký và attest khi cả hai nền tảng đạt cổng** (mục 4, 6), trừ `drill-vulnerable` (bên dưới).
- **Rescan hằng ngày** trong `images.yml` (`schedule` cron `17 1 * * *` UTC, tránh đầu giờ; và `workflow_dispatch` input
  `rescan: true`, tuỳ chọn `values_ref`), job `rescan`, concurrency group riêng (mục 3), script `deploy/ci/rescan.sh`:
  - **Tập digest:** `image.repository` + `image.digest` trong `deploy/k8s/values/services/*.yaml` ở `main`; ở `bot/promote`
    khi có PR đang mở từ nhánh đó (PR cuộn, mục 9: chỉ PR do `github-actions[bot]` mở từ chính repo, PR từ fork cùng tên
    nhánh không tính; `gh pr list --limit 500`, danh sách về đầy 500 thì job đỏ thay vì đoán); và ở `values_ref` khi
    dispatch có input này (nhánh hay SHA, đọc qua `env:`, phải khớp `^[A-Za-z0-9][A-Za-z0-9._/-]*$`). Job checkout `main`,
    fetch riêng từng ref kia (`git fetch --depth 1`: `actions/checkout` không lấy `bot/promote` hay `refs/pull/*`) rồi đọc
    values bằng `git show <ref>:<file>` qua hàm đọc values chặt của `deploy/k8s/lib.sh` ở `main`: chỉ đọc dữ liệu, không
    chạy code nào của ref đó. Digest rỗng thì bỏ qua, ghi summary. Repository khác
    `ghcr.io/anhnvcoder/short-video-platform/<svc>` của đúng file, digest sai dạng `sha256:<64 hex>`, hay `cosign verify`
    với identity bên trên thất bại → không attest digest đó, job đỏ. Chỉ digest do chính `images.yml` trên `main` đã ký
    mới được attest lại, nên danh sách đọc từ ref nào cũng không làm Kyverno nhận một image lạ.
  - **Mỗi digest:** đọc hai manifest con của index, quét **từng** digest con từ GHCR bằng DB mới nhất và cùng
    `.trivyignore.yaml` của `main` (`trivy image <repo>@<digest con>`, cùng cờ của mục 6), dựng predicate bằng cùng script,
    `cosign attest --replace --type vuln` lên index. CRITICAL → attestation vẫn ghi kết quả thật (Kyverno chặn pod mới) và
    job đỏ (người học nhận email). SARIF chỉ upload cho digest của `main`, cùng category với lượt build, nên tab Security
    có kết quả mới nhất của bản đang chạy.
  - `--replace` là đọc-sửa-ghi image `.att`: hai lượt attest cùng digest cùng lúc có thể mất một layer. Một digest chỉ vào
    tập của rescan sau khi lượt build của nó đã attest xong và promote đã ghi nó vào values, và các lượt rescan nối nhau
    trong một group, nên không có hai lượt attest cùng một digest cùng lúc. `.att` của index chỉ chứa `vuln` (SBOM nằm
    trên manifest con).
  - **Image diễn tập không được rescan:** rescan của image có CRITICAL cố ý sẽ đỏ mỗi ngày. Kyverno dừng ở phép kiểm sai
    đầu tiên và CRITICAL (bước 5 ở mục 8) đứng trước tuổi (bước 6), nên quá 72 giờ image diễn tập vẫn bị từ chối với
    message CRITICAL, và message đó không cho biết rule tuổi có giữ hay không. Ca CRITICAL của diễn tập vì vậy tự đọc
    `scanFinishedOn` của attestation `vuln` bằng cosign (ẩn danh, identity của policy) và FAIL, không gửi pod, khi quá
    72 giờ: ca này chạy trong 72 giờ kể từ lúc dispatch image diễn tập.
- **Digest vào `main` phải có attestation mới.** Kyverno nhận attestation tới 72 giờ (mục 8), mà một digest có thể vào
  `main` với attestation cũ hơn: PR cuộn mang một service đã build từ nhiều ngày trước, rollback bằng `git revert` về
  digest đã rời `main`, hay `make k8s-gitops-up GITOPS_REV=<revision cũ>`. Ba lớp:
  - Rescan đọc cả PR cuộn đang mở (bên trên): digest chờ merge được làm mới mỗi ngày như digest của `main`.
  - **`values-check`** (job của lượt PR, `contents: read`, không dùng token, `deploy/ci/values-check.sh`): với mỗi file của
    `deploy/k8s/values/services/` mà PR đổi so với base, digest khác rỗng phải có repository đúng, chữ ký đúng identity,
    attestation `vuln` đúng identity, đủ hai nền tảng, không CRITICAL, `scanFinishedOn` không quá **48 giờ** (`cosign
    verify`, `cosign verify-attestation`, ẩn danh). Đỏ thì message in lệnh làm mới `gh workflow run images.yml --ref main
    -f rescan=true -f values_ref=refs/pull/<số PR>/head` (dạng ref này dùng được cả với PR từ fork), xong thì chạy lại
    job. 48 giờ để lại ít nhất 24 giờ trước ngưỡng của Kyverno cho merge và sync; sau merge, rescan hằng ngày của `main`
    giữ tiếp.
  - **`gitops.sh`** kiểm cùng điều kiện, cùng ngưỡng (bằng `COSIGN_IMAGE`, ẩn danh) cho 6 digest ở revision trước khi tạo
    cluster; đỏ thì in lệnh dispatch với `values_ref=<revision>` (mục 9).
  - Ngưỡng 48 giờ nằm ở một hàm dùng chung; chỉ diễn tập mới hạ nó, qua biến `SVP_ATTEST_MAX_AGE` (không đặt trong
    `.env`, như các biến diễn tập khác).
  - Giới hạn: check của PR chạy khi PR được cập nhật, không chạy lại lúc merge. PR đổi values (không phải PR cuộn) để quá
    72 giờ sau lần làm mới cuối rồi mới merge thì pod mới bị từ chối tới lượt rescan kế (≤ 24 giờ) hay tới khi dispatch
    `rescan=true`; vì vậy chạy lại `values-check` ngay trước khi merge PR như thế.
- **Image diễn tập** (`workflow_dispatch` input `drill: true`, chỉ trên `main`, group riêng), cùng ma trận hai kiến trúc
  để khác nhau duy nhất là CRITICAL hay chữ ký: `drill-vulnerable` (base cũ ghim digest có CRITICAL ở cả hai kiến trúc, cổng
  bí mật vẫn giữ, bỏ chặn CRITICAL chỉ cho tên này) ký và attest `vuln` bình thường; `drill-unsigned` (build như một
  service sạch, qua cổng) push mà không ký, không attest. Không chart nào trỏ tới hai image này.
- **Kích thước:** predicate gồm hai báo cáo trivy đầy đủ (vài trăm KB tới vài MB với media-worker). Rekor v1 nhận cả DSSE
  envelope (`pkg/sign/transparency.go` của sigstore-go v1.2.2); giới hạn của instance công khai không được công bố
  (issue sigstore/rekor#2808, một bên thứ ba đo khoảng 24 MiB); vượt thì `attest` lỗi trước khi ghi gì lên GHCR.
- **SLSA provenance** (`actions/attest-build-provenance`, v4.2.2 là wrapper của `actions/attest`) để giai đoạn 9.

## 8. Kyverno

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **`ImageValidatingPolicy` (`policies.kyverno.io/v1`, CEL)** | Loại ổn định ("Stable (since v1.18)", tài liệu v1.19); đọc cosign v3 cả bundle lẫn định dạng cũ; CEL cho kiểm tuổi, nền tảng, CRITICAL | Bản v1.19 vẫn lưu ở `v1beta1` (lên `v1` từ v1.20); ít ví dụ hơn |
| ClusterPolicy `verifyImages` | Nhiều ví dụ | Tài liệu ghi deprecated từ v1.17, tài liệu v1.19 ghi "Deprecated (v1.19), removed in v1.20"; CRD của chart 3.9.1 gắn `deprecated: true` kèm cảnh báo; bundle mới chỉ qua `type: SigstoreBundle` (tối đa 50 referrer) |
| **Webhook `Fail` chỉ cho namespace `svp`** | Kyverno chết không chặn pod platform; ít request đi qua Kyverno | Pod của namespace khác không được kiểm ở admission |
| Webhook cho mọi namespace, Audit ở platform | Báo image bên thứ ba không digest | Webhook trên mọi namespace platform: thêm độ trễ và điểm lỗi lúc platform khởi động; background scan đã tắt nên pod có trước Kyverno không được báo |
| **Image bên thứ ba: ghim digest, kiểm tĩnh trong CI** | Bắt lỗi trước merge, rẻ, không phụ thuộc cluster | Không kiểm chữ ký nhà cung cấp |
| Kiểm chữ ký nhà cung cấp ở admission | Chặt nhất | Mỗi nhà cung cấp một identity hay khoá theo version; thêm phụ thuộc Sigstore lúc platform khởi động |
| **Enforce trên GitOps, Audit trên dev (cùng chart, `--set`)** | Đường dev giữ image `dev-*` chưa ký ở registry k3d; Enforce chạy với chữ ký thật | Logic Enforce chỉ kiểm thật trên đường GitOps sau push |
| Ký cả image dev bằng khoá tạm | Enforce ở cả hai đường | Khoá trên máy, identity khác của CI; đường dev chậm hơn |

### Quyết định

- **Version:** chart `kyverno/kyverno` **3.9.1**, app **v1.19.1** (phát hành 2026-09-10; các bản v1.19.2 còn là RC).
  Kubernetes được hỗ trợ của v1.19: "v1.33 - v1.35" ("Other Kubernetes versions may work, but are not tested",
  `installation/releases.md` nhánh `release-1-19-0` của `kyverno/website`); job conformance `image-validating-policies`
  chạy 1.33.7, 1.34.3, 1.35.1 (`.github/workflows/tests-conformance.yaml@v1.19.1`); `client-go` đã ở v0.36.3. Cluster
  chạy k3s v1.36.5 (ADR-0014 §1), tức Kyverno chạy ngoài dải đã test **một minor**, như Argo Rollouts ở ADR-0014: chỉ dùng
  API ổn định (`admissionregistration.k8s.io/v1`, core). Phương án thay là k3s 1.35, ngoài skew của `kubectl` 1.37.
  Mọi ca diễn tập ở dưới chạy trên chính k3s 1.36.5. Xem lại khi Kyverno phát hành bản tuyên bố hỗ trợ 1.36.
- **CVE-2026-100704** (GHSA-5cjf-wwfg-pj4c, high 7.7): ImageValidatingPolicy 1.14.0–1.19.0 bỏ qua `spec.images`/
  `allowedValues` của `PolicyException`, nên một exception cục bộ bỏ kiểm cả resource; sửa ở 1.19.1 (exception cục bộ bị bỏ
  qua hẳn với ImageValidatingPolicy). Ghim ≥ 1.19.1. Chart 3.9.1 còn tắt PolicyException mặc định
  (`--enablePolicyException=false`), giữ nguyên tắt.
- **Image** (index đa kiến trúc; chart mặc định kéo từ `reg.kyverno.io`, là GHCR của Kyverno: `WWW-Authenticate` trỏ
  `ghcr.io/token`, cùng digest):

  | Image (v1.19.1) | Digest index | Dùng ở |
  | --- | --- | --- |
  | `ghcr.io/kyverno/kyverno` | `sha256:b31d8511ae5fd6010e2a01ea72ebae08eb82fa51d91af14a1d9fe989949b4edb` | admission controller |
  | `ghcr.io/kyverno/kyvernopre` | `sha256:c25c47461f06f2845a48c319ae86fbbc1730a7b9ed5b701889c9dc1f9ee94b09` | initContainer của admission controller |
  | `ghcr.io/kyverno/reports-controller` | `sha256:c0eee97b9b44a0dd35805d56b358fa52548480f79d4944602b9609538eccd64c` | reports controller |
  | `ghcr.io/kyverno/kyverno-cli` | `sha256:ced7b2be0b04250cabfe695f15307f69eb715fe23234816388af4f3812915b2a` | Job `kyverno-migrate-resources` (hook `post-upgrade`) |
  | `ghcr.io/kyverno/readiness-checker` (chỉ có tag `latest` và tag SHA commit) | `sha256:8dab9b157f3b14b2e406fbb8659efc47637f92d9d9704aaaa8b9c9a58f272da3` | Pod hook `test` của chart (`test.image`), chỉ chạy bằng `helm test` |

  `helm template` render cả pod hook `test`, nên phép kiểm digest tĩnh (bên dưới) thấy nó: ghim digest qua `test.image`
  thay vì thêm ngoại lệ.
- **Component:** `kyverno` trong `components.json` cho cả hai đường, namespace `kyverno`, wave sau `svp-cluster` và trước
  service; values `deploy/k8s/values/kyverno.yaml`. Chart mới của repo `deploy/helm/svp-policy` (policy), wave sau
  `kyverno` (CRD `imagevalidatingpolicies.policies.kyverno.io` đến từ chart Kyverno). Namespace `kyverno` thêm vào
  `svp-cluster`: nhãn PSA `restricted`, `default-deny`, `allow-dns`.
- **Chỉ admission controller (1 replica) + reports controller:** `admissionController.replicas: 1`,
  `backgroundController.enabled: false`, `cleanupController.enabled: false`, `reportsController.enabled: true` (để chế độ
  Audit có PolicyReport), `features.backgroundScan.enabled: false`, `webhooksCleanup.enabled: false`. Tài nguyên mặc định
  của chart: admission request 100m/128Mi, limit 384Mi; reports request 100m/64Mi, limit 128Mi. Mọi container của chart
  đặt `runAsNonRoot`, uid/gid 65534, drop `ALL`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem`, seccomp
  `RuntimeDefault`, không `hostNetwork`, volume chỉ `emptyDir` và projected token: đạt PSA `restricted` (`helm template`
  3.9.1).
- **Policy:** một `ImageValidatingPolicy` cluster-scope tên `svp-images` trong `svp-policy`:

  ```yaml
  apiVersion: policies.kyverno.io/v1
  kind: ImageValidatingPolicy
  metadata:
    name: svp-images
  spec:
    validationActions: [Deny]        # dev: [Audit]
    failurePolicy: Fail              # dev: Ignore
    webhookConfiguration:
      timeoutSeconds: 30             # tối đa API server cho; mặc định của Kyverno 10
    evaluation:
      background: {enabled: false}
    autogen:
      podControllers: {controllers: []}
    matchConstraints:
      namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: svp}
      resourceRules:
        - apiGroups: [""]
          apiVersions: [v1]
          operations: [CREATE, UPDATE]
          resources: [pods, pods/ephemeralcontainers]
    matchImageReferences:
      - glob: ghcr.io/anhnvcoder/short-video-platform/*
    validationConfigurations:
      mutateDigest: false
      verifyDigest: true
      required: true
    attestors:
      - name: images
        cosign:
          keyless:
            identities:
              - issuer: https://token.actions.githubusercontent.com
                subject: https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main
    attestations:
      - name: vuln
        intoto:
          type: https://cosign.sigstore.dev/attestation/vuln/v1
    validations: []                  # bên dưới
  ```

  - **Chỉ Pod, không autogen:** `autogen.podControllers.controllers: []` (rỗng nhưng khác nil là không sinh rule cho
    controller, `pkg/cel/policies/ivpol/autogen/autogen.go@v1.19.1`); autogen cũng tự tắt khi `resources` khác đúng
    `["pods"]`. Policy chặn ở Pod nên Deployment, Rollout, Job migrate, ReplicaSet của KEDA đều đi qua đúng một chỗ.
  - **Không đổi image:** `mutateDigest: false` (mặc định `true`) bỏ hẳn webhook mutating của policy
    (`pkg/controllers/webhook/controller.go@v1.19.1`), nên Argo CD không thấy lệch giữa git và Pod sống. Digest đã nằm trong
    git (mục 9).
  - **Mọi đường đưa image vào Pod:** extractor mặc định cho Pod lấy `containers`, `initContainers`, `ephemeralContainers`
    (`pkg/cel/compiler/images.go@v1.19.1`); `pods/ephemeralcontainers` phải ghi rõ trong `resources` ("must be listed
    explicitly … do not implicitly extend a "pods" match", test conformance `subresources/block-ephemeral-containers`), với
    `CREATE` và `UPDATE` (`kubectl debug` là UPDATE subresource đó).
  - **Thứ tự kiểm** (mỗi validation một message riêng, nói rule nào, image nào):
    1. **Prefix + digest, không gọi mạng:** mọi image trong `object.spec.containers`, `initContainers`,
       `ephemeralContainers` (dùng `.?…orValue([])`) bắt đầu bằng `ghcr.io/anhnvcoder/short-video-platform/` và có
       `@sha256:`. Image không khớp `matchImageReferences` bị **bỏ khỏi** phần xác minh chữ ký (bị coi như cho qua,
       `pkg/image/verification/evaluator/policy.go@v1.19.1`), nên phép kiểm này là thứ từ chối image của registry k3d hay
       Docker Hub; Kyverno chỉ tải trước dữ liệu của image khớp prefix, nên không tra registry nào ngoài GHCR. Pod có
       image khớp prefix thì GHCR được gọi trước khi validation chạy.
    2. **Chữ ký:** `verifyImageSignatures(image, [attestors.images]) > 0` cho mọi image khớp.
    3. **Attestation `vuln`:** `verifyAttestationSignatures(image, attestations.vuln, [attestors.images]) > 0`; rồi
       `extractPayload(image, attestations.vuln)` (là cả in-toto statement, nên mọi đường dẫn bắt đầu bằng `.predicate`;
       `intoto.type` phải là URI đầy đủ, viết tắt `vuln` không khớp).
    4. **Đủ hai nền tảng:** `predicate.scanner.result.platforms` có đúng hai phần tử, tập `platform` là {`linux/amd64`,
       `linux/arm64`}; thiếu một → từ chối.
    5. **Không CRITICAL:** không phần tử nào có `report.Results[].Vulnerabilities[].Severity == 'CRITICAL'`.
    6. **Tuổi ≤ 72 giờ:** `time.now() - timestamp(payload.predicate.metadata.scanFinishedOn) <= duration('72h')`
       (`time.now()` từ thư viện CEL của Kyverno, `timestamp`/`duration` của CEL chuẩn). 72 giờ = rescan hằng ngày chịu
       được hai lần lỡ lịch.
    Message của quá hạn, CRITICAL, thiếu nền tảng là ba message khác nhau.
  - **`timeoutSeconds: 30`:** một lần xác minh chưa có trong cache tới TUF và GHCR, một chữ ký mất 6–8 s trên cluster
    của lab, mỗi image xác minh hai lần (chữ ký, rồi attestation `vuln`); ở Enforce lời gọi webhook quá hạn là từ chối
    pod. Policy có `webhookConfiguration` thì Kyverno cho nó một webhook riêng, tên
    `ivpol.validate.kyverno.svc-fail-finegrained-svp-images` (`-ignore-` thay `-fail-` ở Audit;
    `pkg/controllers/webhook/validating.go@v1.19.1`), nên script tìm webhook theo selector và `failurePolicy`, không theo
    tên.
  - **`--dry-run=server` đi qua policy:** Kyverno đặt `sideEffects: NoneOnDryRun`
    (`pkg/controllers/webhook/validating.go@v1.19.1`), API server gửi request dry-run tới webhook đó, và engine chỉ bỏ ghi
    report khi dry-run, vẫn xác minh image (`pkg/cel/policies/ivpol/engine/engine.go@v1.19.1`).
- **Phạm vi webhook:** `matchConstraints.namespaceSelector` của chính policy được ghép (AND) với `webhooks.namespaceSelector`
  của ConfigMap Kyverno rồi ghi lên webhook sinh ra (`resolveNamespaceSelector`, `validating.go@v1.19.1`; webhook
  `ivpol.validate.kyverno.svc-fail-finegrained-svp-images` trong `kyverno-resource-validating-webhook-cfg`). Giữ mặc định
  của chart cho ConfigMap (`NotIn [kube-system]`, và `excludeKyvernoNamespace: true` thêm `NotIn [kyverno]`), nên webhook
  `Fail` chỉ nhận request của namespace `svp`; namespace khác không đi qua nó, `kube-system` và `kyverno` còn bị resource
  filter loại. Không có webhook Audit nào cho namespace platform.
- **Ca diễn tập "attestation quá hạn":** một policy tạm cùng loại, tuổi tối đa **5 giây**, `objectSelector` khớp nhãn
  diễn tập riêng, cùng `namespaceSelector` `svp`; kiểm bằng `--dry-run=server`, xoá khi xong (`trap`). Không mở rộng phạm
  vi webhook. Attestation của một bản phát hành luôn cũ hơn 5 giây lúc diễn tập chạy (CI attest trước khi promote), nên ca
  này không chờ, không đọc đồng hồ; trước khi tạo policy tạm nó kiểm bằng cosign rằng image có attestation `vuln` (không
  có thì FAIL ngay: Kyverno sẽ từ chối vì thiếu attestation, không nói gì về tuổi).
- **Image bên thứ ba** (operator, Postgres, Redpanda, observability, Argo CD, Kyverno): **ghim digest mọi image** chart
  render (values; Renovate giữ mới), kiểm **tĩnh** bằng `deploy/k8s/check-image-digests.sh`: `helm template --include-crds`
  mọi component có `chart` của `components.json` và chart Argo CD của `gitops.sh` với đúng values đường GitOps, liệt kê mọi
  image (trường `image:`, image trong `args`/`env`), loại 6 image service, thoát ≠ 0 khi image nào thiếu `@sha256:`; ngoại
  lệ (image chart không cho ghi đè) liệt kê trong script kèm lý do. Chạy trong job `config` của `ci.yml`. Không kiểm chữ ký
  nhà cung cấp ở giai đoạn 5 (rủi ro chấp nhận; xem lại ở giai đoạn 7 hay 9). Phần "chưa ghim digest hay ký" của ADR-0014
  §1 đóng bằng mục này (ghim digest) và bằng chữ ký của 6 image service.
- **Hai đường:**
  - **GitOps** (`make k8s-gitops-up`, image từ GHCR): values trong git, `Deny` + `failurePolicy: Fail`.
  - **Dev** (`make k8s-up`, image `dev-*` chưa ký ở registry k3d): cùng chart, `install.sh` truyền `--set` sang **Audit**
    (`validationActions: [Audit]`, `failurePolicy: Ignore`), không ghi file. Với `Audit`, lỗi khi xác minh không từ chối
    (engine chỉ từ chối khi action có `Deny`, `pkg/webhooks/resource/ivpol/handler.go@v1.19.1`), webhook lỗi cũng cho qua.
    `install.sh` chờ webhook của policy đăng ký xong trước wave service.
  - Diễn tập "Xong khi" chạy trên đường GitOps sau push. Trước push, logic Enforce kiểm trên cluster dev bằng cài tạm
    `Deny` + `Fail` rồi `kubectl --dry-run=server` (các ca từ chối, và ca nhận với image công khai có chữ ký keyless của
    nhà cung cấp khác bằng một policy thử trỏ identity đó).
- **Kyverno lỗi hay không tới được Sigstore, GHCR → đóng** trên GitOps: webhook `Fail`, và lỗi khi xác minh (registry, TUF
  không tới được) cũng từ chối vì action là `Deny`. Namespace khác không qua webhook này. "Kyverno lỗi" là crash, pod
  không lịch được, mất node: cấu hình webhook còn đó mà không endpoint nào, nên pod `svp` bị từ chối. **Scale về 0 hay gỡ
  Kyverno thì mở:** Kyverno v1.19.1 xoá mọi cấu hình webhook của nó khi admission controller dừng lúc Deployment đòi
  `replicas: 0` hay đang bị xoá (`IsGoingDown`, `pkg/utils/runtime/utils.go`, dọn ở `pkg/webhooks/server.go`), và từ đó
  mọi pod được nhận không kiểm (đã thấy trên cluster dev: scale 0 thì `kyverno-resource-validating-webhook-cfg` biến mất,
  pod `svp` được nhận). Chấp nhận: chỉ ai sửa được Deployment ở namespace `kyverno` (cluster-admin, Argo CD) làm được, và
  trên đường GitOps Argo CD self-heal trả `replicas` về 1. Ca "Kyverno tắt" của diễn tập vì vậy làm pod không lịch được
  (strategy `Recreate` và `nodeSelector` không node nào có), không scale 0.
- **Cache kết quả xác minh:** bật mặc định, TTL 60 phút (`--imageVerifyCacheEnabled=true`,
  `--imageVerifyCacheTTLDuration=60m`, `--imageVerifyCacheMaxSize=1000`, `cmd/internal/flag.go@v1.19.1`; chart không có value
  riêng, đặt qua `admissionController.container.extraArgs`). `MaxSize` là ngân sách "cost" của ristretto: kết quả chữ ký
  tốn 1, kết quả attestation tốn 1 + số byte payload nó giữ (`payloadCost`, `pkg/image/verification/cache/client.go@v1.19.1`),
  không phải số mục: với 1000, payload `vuln` (hai báo cáo trivy, hàng chục KB trở lên) không bao giờ được cache, mỗi Pod
  mới đều gọi TUF và GHCR. Cùng cờ đó định cỡ sketch tần suất và bloom filter của ristretto (NumCounters = 10 × ngân sách,
  làm tròn lên luỹ thừa của 2; ristretto v2.4.2), Go tính là heap ngay từ đầu: 64 MiB thành khoảng 3 GiB heap, vượt xa
  GOMEMLIMIT (~362 MB) Kyverno suy từ limit 384Mi nên GC chạy liên tục; 1 MiB khoảng 48 MiB. Đặt
  **`--imageVerifyCacheMaxSize=1048576` (1 MiB)**: chứa payload của 6 service và 2 image diễn tập nhiều lần. Hệ quả: tuổi
  thật của attestation được nhận có thể tới 72 giờ + 60 phút, và Sigstore lỗi sau khi kết quả đã vào cache vẫn nhận pod
  tới hết TTL.
- **Egress của Kyverno** (namespace `kyverno`, NetworkPolicy không lọc theo tên miền): DNS; API server; TCP 443 ra địa chỉ
  công khai, **trừ** mọi dải private (`10.0.0.0/8` gồm mạng Docker `10.200.0.0/24` của k3d và dải pod/service,
  `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `169.254.0.0/16`), nên không tới được registry k3d (`5111`) hay dải
  nào trong máy. Đích thật cần (đọc mã v1.19.1): TUF `tuf-repo-cdn.sigstore.dev` (mỗi lần xác minh không trúng cache,
  `tuf.Initialize` của `sigstore/sigstore` v1.10.9 "Force an update with remote", và `trusted_root.json` luôn lấy từ mirror);
  `ghcr.io` và `pkg-containers.githubusercontent.com` (blob của GHCR). Không gọi Fulcio, Rekor, CT log: policy không đặt
  `ctlog`, nên `getRekor` không dựng client Rekor mà trả khoá công khai Rekor/CT lấy từ TUF, và `opts.Offline = true`
  (`pkg/image/verifiers/ivpol/cosign/opts.go@v1.19.1`): với định dạng cũ, bằng chứng Rekor (SET) trong annotation của
  `.sig`/`.att` được kiểm offline bằng khoá đó (đọc mã, đọc lại 2026-10-21; chưa có phép thử chặn riêng Rekor).
  `features.registryClient.credentialHelpers: [default]` (package public, không helper nào gọi metadata của cloud).
  Ingress chỉ tới cổng webhook (Service 443 → container 9443), từ mạng node (`nodeSubnet` `10.200.0.0/24`) và địa chỉ
  VXLAN của từng node (`kyverno.vxlanAddresses` của `svp-cluster`, `10.42.0.0/32`, `10.42.1.0/32`): API server chạy trên
  node server, lời gọi tới pod ở node agent đi ra từ giao diện `flannel.1` của server, mang địa chỉ mạng của dải pod /24
  của node đó (k3s gán theo thứ tự node join); không pod nào được vào. Thêm node thì thêm địa chỉ.
- **Argo CD:** **không** đặt `resource.exclusions`: danh sách mặc định của chart argo-cd 10.10.5 đã loại các kind report
  của Kyverno v1.19.1 (`reports.kyverno.io` `EphemeralReport`, `ClusterEphemeralReport`; `wgpolicyk8s.io` `PolicyReport`,
  `ClusterPolicyReport`; đã render `argocd-cm` kiểm), và đặt giá trị là thay cả danh sách, mất các loại trừ khác của chart
  (`deploy/k8s/values/argo-cd.yaml` có comment dặn). Danh sách trong README của chart Kyverno đã cũ: `AdmissionReport`,
  `BackgroundScanReport` không còn ở v1.19.1. Health check Lua cho `policies.kyverno.io/ImageValidatingPolicy`: Healthy
  khi `status.conditionStatus.ready`, Progressing kèm điều kiện đầu chưa True (policy vừa áp mà Kyverno chưa biên dịch,
  chưa đăng ký webhook), không bao giờ Degraded; nhờ đó wave service không tạo trước khi webhook của policy sẵn sàng.
  AppProject `svp` thêm đích `kyverno` và đúng các kind cluster-scope mà `helm template --include-crds` của Kyverno và
  `svp-policy` cần.
- **RAM:** dự kiến +0,25–0,35 GiB (admission controller và reports controller lúc nghỉ, cộng cache tới 1 MiB với sketch
  khoảng 48 MiB heap): cluster GitOps nghỉ ~7,3 GiB, đỉnh ~8,4 GiB, dưới ngưỡng 8,7 GiB của ADR-0014 §2, điều kiện (a),
  (b) giữ nguyên. Vượt thì cắt lần lượt: (1) tắt reports controller (mất PolicyReport của Audit, Enforce không đổi); (2)
  trở đi theo thứ tự cắt của ADR-0014 §2. Đo thật trên đường dev (lượt kiểm cuối) và trên đường GitOps (diễn tập chuỗi
  cung ứng).
  - **Đo trên đường dev (2026-10-21, cluster dựng mới, cắm sạc, Low Power Mode tắt, cách đo ADR-0014 §2):** Kyverno 168
    MiB lúc nghỉ 60 s sau `make k8s-up` (admission controller 113, reports controller 55) và 132 MiB sau các diễn tập,
    dưới mức dự kiến. Cả cluster nghỉ **6,40 GiB** (trung vị 6 mẫu, dưới ngưỡng 6,5; tổng pod 2,46 GiB; MEM USAGE trừ
    `active_file` 5,36 GiB); đỉnh trong `make drill-k8s-keda N=9`: cửa sổ 6 mẫu cao nhất có 3 replica Ready (2 worker
    transcode) 7,68 GiB, mẫu cao nhất 7,92 GiB (mẫu duy nhất có 3 worker cùng transcode), dưới ngưỡng 8,7. Không áp bước
    cắt nào. Đường GitOps (có Argo CD): kiểm sau push.
  - **Đo trên đường GitOps (2026-10-21):** ngưỡng RAM đạt (nghỉ 6,93–6,97 GiB đủ (b), đỉnh 3 worker 8,45 GiB) nhưng k3s
    server chết trong `drill-k8s-keda` vì VM hết CPU; số đo, tiêu chí (c) và quyết định media-worker tối đa 2 ở
    [ADR-0017](0017-gitops-capacity-media-worker-max2.md).

## 9. Promote qua PR GitOps (thay `make k8s-release`)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Job `promote` ghi `repository`/`tag`/`digest` vào values và mở một PR cuộn; người học merge** | Cổng triển khai là con người; lịch sử phát hành nằm trong git, rollback bằng `git revert` | Một PR mỗi đợt phát hành; job có quyền ghi repo |
| Job ghi thẳng lên `main` | Không có PR | Phải cho bot bypass ruleset; không ai duyệt bản sắp chạy |
| Argo CD Image Updater | Không cần job | Thêm controller (RAM); khoá có quyền ghi git nằm trong cluster; đọc tag, không gắn với chữ ký và quét |
| Mỗi lượt build một PR riêng | Đơn giản | PR cũ merge sau PR mới thì ghi lùi digest; nhiều PR trùng service |
| **Một nhánh bot cố định, dựng lại từ `main` mỗi lần, gom digest mới nhất của mọi service chưa merge** | Không ghi lùi; luôn một PR | Script phải so "mới hơn" theo lịch sử commit |
| Promote gọi `workflow_dispatch` của `ci.yml`, `images.yml` trên nhánh bot | Check chạy trên commit đầu PR mà không cần người | **Không dùng được:** check của job do `workflow_dispatch` tạo không hiện ở PR và không thoả check bắt buộc của ruleset (bên dưới) |
| **Người học bấm "Approve workflows to run" trên PR promote** | Lượt `pull_request` chạy như PR thường, check thoả ruleset; không job nào cần `actions: write` | Một cú bấm mỗi lần PR được cập nhật |
| Token của GitHub App riêng hay PAT cho job promote | PR chạy CI không cần duyệt | Khoá dài hạn trong secret của repo public; thêm một App phải quản |

### Quyết định

- **Job `promote`** trong `images.yml`, trên `main` ở chế độ build (push, hay dispatch có input `services`, mục 3), sau
  khi ký và attest xong các service của lượt đó; script `deploy/ci/promote.sh`, checkout đủ lịch sử:
  - dựng lại **nhánh bot cố định `bot/promote`** từ `origin/main` mỗi lần; với mỗi service ghi `image.repository`
    (`ghcr.io/anhnvcoder/short-video-platform/<svc>`), `image.tag` (`<12 hex>`), `image.digest` (digest index đã ký) vào
    `deploy/k8s/values/services/<svc>.yaml`, giá trị chọn theo quy tắc dưới;
  - **chọn giá trị của mỗi service, không bao giờ ghi lùi.** Ứng viên: giá trị trên `main`; giá trị trên `bot/promote`
    **chỉ khi có PR đang mở** từ nhánh đó, do `github-actions[bot]` mở từ chính repo (PR từ fork cùng tên nhánh hay PR do
    người mở không tính), và chỉ cho service mà PR đó đổi (`git diff` từ merge-base của `main` với nhánh bot, nên đúng cả
    khi "Update branch" đã merge `main` vào nhánh) (PR đã merge thì nội dung đã nằm trong `main`; PR đã đóng là bản bị
    bỏ, dùng lại sẽ hồi sinh bản người học vừa rollback); digest vừa ký ở lượt này. Commit của ứng viên là `image.tag`
    (12 hex) tra trong lịch sử; tag rỗng là "chưa phát hành", thua mọi ứng viên. Chọn ứng viên có commit là hậu duệ hay chính commit
    của mọi ứng viên khác; hai ứng viên cùng commit thì lấy digest vừa ký (cùng code, build mới hơn, có bản vá của gói
    chưa ghim). Hai commit không so được (lịch sử bị viết lại) hay tag không tra được → không ghi service đó, job đỏ,
    summary nói lý do. Ví dụ: chạy lại lượt của push A sau khi lượt của hậu duệ B đã promote gateway@B → A là tổ tiên của
    B nên gateway giữ B (mục 3 cũng cho lượt chạy lại đó không build gì). PR cuộn vì vậy gom digest mới nhất của mọi
    service chưa merge;
  - commit tác giả `github-actions[bot]` (`41898282+github-actions[bot]@users.noreply.github.com`), `git push
    --force-with-lease=bot/promote:<sha đã đọc>` (lượt khác vừa đẩy thì lỗi thay vì đè; chỉ chống hai lượt ghi cùng lúc,
    chống ghi lùi là quy tắc chọn ở trên);
  - tạo PR nếu chưa có, cập nhật nếu có (`gh pr create`/`gh pr edit`): tiêu đề `chore(release): phát hành <svc…> <12 hex>`,
    mô tả tiếng Việt liệt kê service, tag, digest, link lượt chạy;
  - không gì khác `main` thì không push, không PR.
  - Quyền: `contents: write`, `pull-requests: write`; không `id-token`, không `packages`, **không `actions: write`**.
  - Cần cài đặt "Allow GitHub Actions to create and approve pull requests" ("By default, when you create a new repository
    in your personal account, workflows are not allowed to create or approve pull requests", mục 11).
- **Check của PR promote** (kiểm 2026-10-20; khác giả định ban đầu "PR do `GITHUB_TOKEN` tạo không kích hoạt workflow"):
  - Từ 2026-06-11, PR do `GITHUB_TOKEN` tạo hay cập nhật **có** lượt `pull_request` (`opened`, `synchronize`, `reopened`)
    ở trạng thái chờ duyệt; người có quyền ghi bấm "Approve workflows to run" trên PR (changelog "Bot-created pull requests
    can run workflows if approved"; tài liệu `GITHUB_TOKEN`: "the resulting `pull_request` event creates workflow runs in an
    approval-required state"). Lúc chờ, check suite `action_required` không có check run nào, nên check bắt buộc chưa có và
    nút merge bị khoá: đúng phía an toàn.
  - Check của job do `workflow_dispatch` trên nhánh đầu PR tạo **không** hiện ở PR và không thoả check bắt buộc ("if a
    workflow is triggered by `workflow_dispatch` on a pull request's head branch, checks reported by its jobs do not appear
    in the pull request's checks section. Even if the checks pass for the head commit, they do not satisfy a required
    status check in a branch ruleset", tài liệu "Troubleshooting required status checks", thêm 2026-09-14). Cách "promote
    gọi `workflow_dispatch`" vì vậy bị bỏ, thay bằng cú bấm duyệt của người học: vẫn giữ mục đích (check bắt buộc chạy
    trên commit đầu PR, cổng triển khai là con người).
  - Không job nào gọi `POST /repos/{owner}/{repo}/actions/runs/{run_id}/approve` (cần `actions: write`; bot tự duyệt PR của
    mình thì bước duyệt mất nghĩa).
  - Lượt `images.yml` của PR promote: merge-base với `main`, chỉ `deploy/k8s/values/services/` đổi → không build,
    `values-check` kiểm các digest của PR (mục 7), `images-ok` xanh khi nó đạt; `ci.yml` chạy đủ.
- **Người học review, duyệt lượt chạy, merge.** Merge → Argo CD poll thấy commit (thường ≤ 60 s, tệ nhất ~120 s, ADR-0014
  §12) → sync → canary của gateway như giai đoạn 4.
  - **Đã đo trên cluster GitOps (2026-10-29, `main`):** phát hành `user-service` (PR #29 merge 02:49:25Z): sync bắt đầu +120 s,
    pod Ready +139 s (phần lớn là chờ Argo CD poll git: `timeout.reconciliation` 60 s, ADR-0014 §12 ghi tệ nhất ~120 s; +120 s nằm ở cận tệ nhất đó), Job migrate tạo đúng
    trong sync đó, 0 restart; source map của image CI đạt. Mốc push lấy từ `merged_at` của PR promote vì Events API trễ. Lượt
    [40801610039](https://github.com/anhnvcoder/short-video-platform/actions/runs/40801610039); chi tiết và tiêu chí ở D5, D26
    của [ADR-0021](0021-deferred-verification-stage6b.md).
- **Rollback:** PR `git revert` commit phát hành (hay sửa values về digest cũ), như mọi PR. Đóng PR cuộn đang mở nếu nó
  còn mang bản bị rollback (quy tắc chọn ở trên chỉ đọc nhánh bot khi PR còn mở). `values-check` đỏ vì attestation của
  digest cũ quá 48 giờ thì dispatch rescan với `values_ref=refs/pull/<số PR>/head` (mục 7), chạy lại check, rồi merge.
- **Cluster GitOps kéo image từ GHCR** theo digest, ẩn danh (package public). Chart `svp-service` nhận `image.digest`: có
  digest thì render `<repository>:<tag>@<digest>` (tag rỗng mà có digest thì `<repository>@<digest>`), không có thì như cũ
  (`required` tag); thông báo của `required` nói đúng hai đường (dev: `make k8s-up` truyền tag dev; GitOps: PR promote ghi
  tag và digest).
- **Đường dev giữ registry k3d:** `install.sh` truyền `--set image.repository=k3d-svp-registry:5111/svp/<svc>`,
  `--set image.tag=dev-<12 hex image ID>`, `--set image.digest=` cho mỗi release `svp-service` (không ghi file).
- **Repo của Argo CD** (sửa 2026-10-28, ADR-0021 §6): cluster GitOps đọc repo qua HTTPS ẩn danh, không deploy key, không Secret
  repo; `make k8s-gitops-up` chỉ còn `GITOPS_REV`, và cluster đó đóng vai stg với overlay `deploy/k8s/envs/stg/`
  ([ADR-0024](0024-multi-environment.md)).
- **Bỏ** `make k8s-release`, `deploy/k8s/release.sh` và bước dựng lại image phát hành trong `gitops.sh`. `gitops.sh` đọc
  `repository`, `tag`, `digest` của 6 file ở đúng revision (không working tree) và từ chối **trước khi tạo cluster** khi
  digest rỗng (merge PR promote trước), repository khác `ghcr.io/anhnvcoder/short-video-platform/<svc>`, hay manifest theo
  digest không đọc được ẩn danh (`HEAD /v2/<name>/manifests/<digest>` với token ẩn danh của `ghcr.io/token`; 401, 403, 404
  nghĩa là package chưa public hay chưa có), hay chữ ký và attestation `vuln` không đạt điều kiện 48 giờ của mục 7 (in
  lệnh dispatch rescan với `values_ref=<revision>`). Registry k3d vẫn tạo (cấu hình `k3d.yaml` chung hai đường).
- Values của 6 service trên `main` lúc đầu: `image.repository` GHCR, `image.tag: ""`, `image.digest: ""` (chưa có bản phát
  hành trên GHCR); PR promote đầu tiên điền.

## 10. Renovate

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **GitHub App Mend Renovate (bản host), chỉ repo này** | PR do App tạo chạy CI như PR thường; App có quyền "Workflows" nên cập nhật được SHA action; không job nào giữ token | Một App bên thứ ba có quyền ghi nội dung, PR, workflow; người học cài một lần |
| Renovate self-hosted trong Actions bằng `GITHUB_TOKEN` | Không App ngoài | `GITHUB_TOKEN` không có quyền `workflows` nên không sửa được `.github/workflows/` (không cập nhật SHA action); PR của nó chỉ chạy CI sau khi người duyệt (mục 9) |
| Self-hosted với PAT hay App riêng | Đủ quyền | Thêm một secret dài hạn (hay App tự quản) trong repo public |
| Dependabot | Có sẵn | Không có custom manager cho `Makefile`, `components.json`, `lib.sh`; mỗi hệ sinh thái một cấu hình |
| **Không automerge ở giai đoạn 5** | Mọi thay đổi dependency có người đọc | Người học merge tay |
| **`minimumReleaseAge` 3 ngày** | Bản vừa phát hành bị chiếm thường bị gỡ trong vài giờ (vụ trivy 3/2026, mục 1) trước khi Renovate đề xuất | Bản vá chậm 3 ngày (trừ cảnh báo lỗ hổng) |

### Quyết định

- **App Mend Renovate**, người học cài, "Only select repositories" = repo này. `renovate.json` ở gốc repo có sẵn từ trước
  khi cài, nên App coi repo đã onboard và không mở PR onboarding (`isOnboarded()` trả đúng khi có file cấu hình).
- **Phủ:** `gomod` (`go.mod`, `postUpdateOptions: ["gomodTidy", "gomodUpdateImportPaths"]`: PR major của module sửa luôn
  đường import `/vN`); directive `go`/toolchain cùng một nhóm với image
  `golang` của Dockerfile và `go-version` của `actions/setup-go` (Go của máy dev, CI và image đi cùng nhịp, ADR-0007 §7);
  `dockerfile` cho `deploy/docker/*.Dockerfile` giữ dạng `tag@sha256` (thư mục image diễn tập loại trừ: base cũ cố ý);
  `github-actions` theo SHA với preset `helpers:pinGitHubActionDigests` (SHA kèm comment version); **custom manager**
  (regex, chú thích `# renovate: datasource=… depName=…` ngay trên dòng) cho version công cụ trong `Makefile`
  (`*_VERSION :=`, image ghim như `OTELCOL_IMAGE`, `TRIVY_IMAGE`, `SYFT_IMAGE`, `COSIGN_IMAGE`, `RENOVATE_IMAGE`),
  `LGTM_IMAGE` của `deploy/compose/compose.mk`, image ghim ở `deploy/k8s/lib.sh`, chart trong
  `deploy/argocd/apps/components.json` (`repo`/`chart`/`version`; chart `oci://` dùng datasource `docker`),
  `argocd_chart_version` của `deploy/k8s/gitops.sh`, image node k3s (`deploy/k8s/k3d.yaml`) **cùng nhóm** với
  `K3S_IMAGE_TAG` của `Makefile`; digest image trong `deploy/k8s/values/*.yaml`, `deploy/helm/*/values.yaml`,
  `deploy/compose/compose.yaml` và service container của `ci.yml`. Ghim ở `deploy/k8s/values/*.yaml` có dạng `tag:
  <version>@sha256:<digest>` (manager `helm-values` khi khoá kết thúc bằng `image`, còn lại chú thích `# renovate:` ngay
  trên `tag:`), nên version và digest đổi cùng một PR; riêng Prometheus và Alertmanager của kube-prometheus-stack (operator
  đọc tag của chúng thành `version`) ghim `version: <tag>` cạnh `image.tag: <tag>@sha256:<digest>`, không dùng `sha:`,
  manager regex đọc version và digest từ `tag` rồi ghi cả hai dòng (RE2 không có backreference, nên tay sửa lệch hai dòng
  thì chỉ lần cập nhật sau mới làm khớp lại). `HELM_VERSION` đổi thì `HELM_LINUX_AMD64_SHA256` phải đổi
  tay theo `.sha256sum` của bản đó (Renovate không tính checksum): job `config` đỏ cho tới khi sửa.
- **Không đụng** `deploy/k8s/values/services/` (của promote, mục 9) và `gen/`.
- **Nhóm:** Go module non-major một PR; action một PR; công cụ `Makefile` một PR; base image Dockerfile (cùng Go) một PR;
  Elasticsearch, Kibana, APM Server của compose (`elastic stack`) một PR; **mỗi chart một PR** (nâng chart cần kiểm trên
  cluster); k3s (`separateMinorPatch`): chỉ bản patch tự mở PR, minor/major chờ duyệt trên Dependency Dashboard vì kéo
  theo `podSecurityVersion` của `svp-cluster`, ba version của `deploy/k8s/pod-security-admission.yaml` (`make k8s-up` từ
  chối khi lệch) và bảng tương thích Kubernetes của mọi thành phần (cả Kyverno, mục 8).
- **Lịch:** hằng tuần, `timezone: Asia/Ho_Chi_Minh`, sáng thứ Bảy (`schedule: ["* 0-8 * * 6"]`); `minimumReleaseAge:
  "3 days"`; Dependency Dashboard bật; **không automerge**.
  - `minimumReleaseAge` cần giờ phát hành của datasource; mặc định `minimumReleaseAgeBehaviour: timestamp-required` giữ lại
    bản không có giờ phát hành. Datasource nào bị giữ mãi (thấy trên Dependency Dashboard) mới được một `packageRule`
    `timestamp-optional` riêng, ghi lý do.
  - Giới hạn đã biết: với action, tag bị đẩy lại sang commit mới được tính tuổi theo ngày phát hành gốc, nên có thể qua
    `minimumReleaseAge` ngay (tài liệu `minimumReleaseAge`). Lớp chặn với action là SHA ghim và người đọc PR, không phải
    tuổi.
- **Cảnh báo lỗ hổng:** `vulnerabilityAlerts` mở PR ngay, ngoài lịch, không chờ `minimumReleaseAge` ("Security updates
  bypass any `minimumReleaseAge` checks"); cần Dependency graph và Dependabot alerts bật trên repo ("For this to work, you
  must enable the Dependency graph, and Dependabot alerts", mục 11). Không bật Dependabot security updates (Renovate mở PR).
- **Commit và PR:** `semanticCommits` bật, tiền tố `chore(deps)` (`fix(deps)` cho cảnh báo lỗ hổng) khớp conventional
  commits của repo; mô tả do bot sinh bằng tiếng Anh (nội dung sinh tự động, không phải tài liệu của repo).
- **Kiểm cấu hình trên máy:** `renovate-config-validator --strict --no-global renovate.json` trong image `RENOVATE_IMAGE`
  (`docker run` mount repo chỉ đọc; file phải đọc được với uid 12021 của image), không cài gì.

## 11. Bảo vệ `main` và cài đặt repo

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Ruleset (file JSON trong repo, áp bằng `gh api`)** | Cấu hình review được, áp lại được | Người học áp tay mỗi lần đổi file |
| Branch protection cổ điển | Quen thuộc | Cấu hình rời rạc qua UI hay API |
| Không bảo vệ | Không ma sát | Push thẳng `main` bỏ qua mọi check; force push xoá lịch sử GitOps |
| Bắt 1 approval | Đúng quy trình nhóm | Repo một người: không ai approve được PR của chính mình |
| **0 approval, bắt PR và check** | Mọi thay đổi qua `ci-ok`, `images-ok` | Không có người thứ hai duyệt |

### Quyết định

- **`.github/rulesets/main.json`** theo schema `POST /repos/{owner}/{repo}/rulesets`: `name: main`, `target: branch`,
  `enforcement: active`, `conditions.ref_name.include: ["~DEFAULT_BRANCH"]`, `exclude: []`, `bypass_actors: []` (không ai
  bypass), rule:
  - `deletion`, `non_fast_forward` (cấm xoá nhánh, cấm force push);
  - `pull_request`: `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push`, `require_code_owner_review`,
    `require_last_push_approval`, `required_review_thread_resolution` đều `false` (repo một người: bắt đi qua PR và check,
    không bắt người thứ hai);
  - `required_status_checks`: `ci-ok` và `images-ok`, mỗi mục `integration_id: 15368` (app `github-actions`, `gh api
    /apps/github-actions`): chỉ check do GitHub Actions tạo mới tính, status cùng tên từ app hay token khác không thoả;
    `strict_required_status_checks_policy: false` (không bắt nhánh PR cập nhật theo `main` trước merge: một người, và lượt
    push `main` chạy lại mọi kiểm tra; xem lại khi có thêm người).
  - Áp sau push đầu (push đầu đi thẳng `main`): `gh api -X POST repos/anhnvcoder/short-video-platform/rulesets --input
    .github/rulesets/main.json`; sửa sau đó bằng `PUT repos/anhnvcoder/short-video-platform/rulesets/<id>`.
- Từ khi bật, **mọi thay đổi vào `main` qua PR**, cả của người học; hoàn tác bằng PR revert, không bao giờ force push.
- **Cài đặt repo người học bật trước push đầu** (mọi lệnh ghi là của người học; endpoint và trường theo tài liệu REST):
  - "Allow GitHub Actions to create and approve pull requests", giữ quyền mặc định chỉ đọc:
    `PUT /repos/anhnvcoder/short-video-platform/actions/permissions/workflow` với `default_workflow_permissions: read`,
    `can_approve_pull_request_reviews: true`. Cài đặt này cũng cho workflow approve review; ruleset không bắt approval nên
    không mở thêm đường merge nào.
  - Chỉ action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc: `PUT .../actions/permissions` với
    `enabled: true`, `allowed_actions: selected`, `sha_pinning_required: true` ("any workflow that attempts to use an action
    that isn't pinned will fail", changelog 2025-08-15); `PUT .../actions/permissions/selected-actions` với
    `github_owned_allowed: true`, `verified_allowed: false`, `patterns_allowed: ["sigstore/cosign-installer@*"]`. Nền tảng
    giữ quy tắc mục 1 thay vì chỉ review.
  - Duyệt workflow của PR fork cho mọi người ngoài: `PUT .../actions/permissions/fork-pr-contributor-approval` với
    `approval_policy: all_external_contributors`.
  - Secret scanning và push protection: `PATCH /repos/anhnvcoder/short-video-platform` với
    `security_and_analysis.secret_scanning.status` và `security_and_analysis.secret_scanning_push_protection.status`
    `enabled`.
  - Dependabot alerts: `PUT .../vulnerability-alerts` (Dependency graph bật sẵn với repo public).
- **Thứ tự phát hành đầu** (người học làm, mỗi bước có điểm dừng; diễn tập chuỗi cung ứng đo theo các bước này):
  - **A.** Bật các cài đặt trên.
  - **B.** Push đầu `git push origin main`: `ci.yml` và `images.yml` chạy trên `main`, 6 service × 2 kiến trúc, ký, attest,
    PR promote mở. Dừng nếu `ci-ok`/`images-ok` đỏ hay PR promote không mở.
  - **C.** Đặt public package nào còn private (mục 5); áp ruleset; cài App Renovate; duyệt lượt chạy của PR promote, merge
    khi `ci-ok`, `images-ok` xanh; `gh workflow run images.yml --ref main -f drill=true`, đặt public hai package diễn tập.
  - **D.** Một thay đổi nhỏ ở một service qua PR → merge → PR promote chỉ có service đó → duyệt, merge. Dừng nếu PR build
    service khác, hay Kyverno từ chối pod mới.

## 12. Để giai đoạn sau

| Việc | Giai đoạn | Vì sao chưa làm |
| --- | --- | --- |
| Đăng nhập AWS bằng OIDC, đẩy image lên ECR (SC-2 phần cloud) | 7 | Chưa có tài khoản cloud nào trong CI; GHCR đủ cho cluster local |
| Kiểm chữ ký nhà cung cấp cho image bên thứ ba; policy Kyverno ngoài image | 7 hoặc 9 | Mục 8: mỗi nhà cung cấp một identity hay khoá theo version, thêm phụ thuộc Sigstore lúc platform khởi động; securityContext đã có PSA |
| SLSA provenance (`actions/attest-build-provenance`) | 9 | Kyverno giai đoạn 5 không kiểm provenance; chữ ký theo identity workflow đã nói image do workflow nào build |
| govulncheck (lỗ hổng Go theo đường gọi thật) | Sau giai đoạn 5 | trivy đã đọc module trong binary Go; govulncheck bớt cảnh báo giả nhưng thêm một công cụ ghim |
| zizmor (lint bảo mật cho workflow) | Sau giai đoạn 5 | actionlint bắt lỗi cú pháp và một phần script injection; quy tắc mục 1 do review giữ |
| DAST (quét gateway đang chạy) | 6 hoặc 9 | Cần stack chạy trong CI; giai đoạn 6 có k6 và stack đo |
| Webhook GitHub → Argo CD | 7 | Cluster local không nhận được request từ internet (ADR-0014 §12) |
| Chuyển chữ ký sang bundle mới của cosign | Khi Kyverno phát hành bản chọn attestation mới nhất (#18049) | Mục 7: trước đó chỉ định dạng cũ cho đúng một attestation `vuln` |

## Ngân sách thời gian CI

- Một service đổi → `images.yml` trên `main` tới lúc PR promote mở hay cập nhật: **dưới 10 phút**.
- `ci.yml` từ lúc bắt đầu tới `ci-ok`: **dưới 10 phút**.
- Đo ở bước D của thứ tự phát hành đầu (`gh run view`, chỉ đọc). Vượt thì xem lại theo mục 3 (`go list -deps`) và cache
  (Go, trivy DB).

## Kiểm chứng (đã kiểm ngày 2026-10-20)

Không chạy workflow, không ký, không dựng cluster. Chart tải vào thư mục tạm ngoài repo với `HELM_CACHE_HOME`,
`HELM_CONFIG_HOME`, `HELM_DATA_HOME` trỏ vào đó; mã nguồn đọc ở đúng tag ghim qua API GitHub (chỉ đọc); digest đọc bằng
Registry HTTP API (token ẩn danh, `Accept` OCI index + Docker manifest list, header `Docker-Content-Digest`, rồi đọc index để
kiểm có `linux/amd64` và `linux/arm64`).

| Kiểm gì | Lệnh / cách kiểm | Kết quả |
| --- | --- | --- |
| SHA commit của action | `gh api repos/<o>/<r>/releases/latest`, `git/ref/tags/<tag>`, tag annotated đi tiếp `git/tags/<sha>` | Bảng mục 1; `codeql-action` v4.39.0 là tag annotated |
| Runtime và hành vi của action | `action.yml` ở tag; release notes `download-artifact` v8, `upload-artifact` v7 | `node24`; `cosign-installer` composite, mặc định cosign v3.0.6, kiểm bootstrap bằng sha256 và bản yêu cầu bằng chữ ký keyless + KMS; `download-artifact` v8 lỗi khi hash lệch |
| Bản phát hành và tuổi | `gh api repos/<o>/<r>/releases` | Bảng mục 1; syft v1.55.0 (2026-10-19) chưa đủ 3 ngày nên ghim v1.54.1 |
| Digest image | Registry HTTP API | Bảng mục 1, 8; trivy 0.76.0 một index trên ba registry; `reg.kyverno.io` là GHCR (`WWW-Authenticate` trỏ `ghcr.io/token`) |
| Vụ chiếm action và công cụ | GitHub Advisory Database (`gh api /advisories/<GHSA>`), NVD | Mục 1 |
| Trivy | `pkg/fanal/image/{image,archive}.go`, `pkg/fanal/analyzer/secret/secret.go`, `pkg/fanal/secret/scanner.go`, `pkg/result/{filter,ignore}.go`, `pkg/flag/db_flags.go`, `pkg/commands/convert/run.go`, tài liệu ở v0.76.0 | Mục 4, 6 |
| Ngày `expired_at` của `.trivyignore.yaml` | Chương trình Go trong thư mục tạm ngoài repo: `gopkg.in/yaml.v3` v3.0.1 (bản trong `go.mod` của trivy v0.76.0) đọc `expired_at: 2026-11-19` vào `time.Time`, so `Before` ở 23:59:59Z hôm trước và 00:00:01Z hôm đó | `2026-11-19T00:00:00Z`; mục bị bỏ từ 00:00 UTC ngày đó (mục 6) |
| syft, golangci-lint, gitleaks, actionlint, buf, Helm | Mã và tài liệu ở tag; `.sha256sum` của Helm v4.3.1 | Mục 1, 2, 7; golangci-lint chỉ in đầu ra chữ mặc định khi không định dạng ra nào được đặt (`pkg/printers/printer.go@v2.14.0`) |
| cosign | `cmd/cosign/cli/{attest,verify,signcommon}`, `pkg/cosign/{attestation,remote}`, `pkg/oci/remote/write.go` ở v3.1.3; advisory GHSA-fx35-mq7g-6g98; signing config trong TUF | Mục 7 |
| GHCR | Thử ẩn danh trên `ghcr.io/sigstore/cosign/cosign@<digest v3.1.3>` và `ghcr.io/kyverno/kyverno:v1.19.1` | `referrers` 404, tag dự phòng `sha256-<hex>` 200 (index referrer); Kyverno: `.att` 200 |
| Chart Kyverno | `helm search repo kyverno/kyverno -l`, `helm pull --untar`, `helm template` 3.9.1 (`--kube-version 1.36.5`, values dự định), đọc CRD | Mục 8: `ClusterPolicy` deprecated trong CRD; `ImageValidatingPolicy` phục vụ `v1`, lưu `v1beta1`; securityContext đạt `restricted` |
| Kyverno | Mã ở v1.19.1 (`pkg/controllers/webhook`, `pkg/cel`, `pkg/image`, `cmd/internal/flag.go`, test conformance), `kyverno/sdk`, `kyverno/website` nhánh `release-1-19-0`, advisory GHSA-5cjf-wwfg-pj4c, NVD CVE-2026-100704 | Mục 8 |
| Fulcio | `docs/oid-info.md` của `sigstore/fulcio` | SAN là `server_url + job_workflow_ref` |
| GitHub | `github/docs` (nội dung và cờ phiên bản trong `data/features`), changelog, `actions/runner`, `actions/runner-images`, `gh api /apps/github-actions` | Mục 1–5, 9–11 |
| Renovate | `docs/usage/configuration-options.md`, tài liệu App của Mend | Mục 10 |

## Kiểm chứng sau phát hành

Các giả định chưa chạy được lúc viết ADR: phần lớn chỉ kiểm được khi workflow chạy thật, có chữ ký thật hay trên cluster;
dòng nào kiểm được trên máy thì phép kiểm ghi "trước push". Mỗi dòng nêu phép kiểm chứng minh nó; kết quả và ngày ghi vào
cột cuối khi đã kiểm. Kiểm sau push ngày 2026-10-21 (giờ UTC): trên GitHub từ push đầu `36e0ba2` tới `983f761` (PR #1
tới #6), chữ ký đọc ẩn danh bằng cosign, và trên hai cluster GitOps dựng từ GitHub ở `8a4e21c` và `bea9954`.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Runner `ubuntu-24.04-arm` chạy job build, service container và Docker như bảng mục 1 | Bước B: chân `arm64` của job `build` trong `images.yml` xanh cho cả sáu service | Đạt (2026-10-21): 6 chân `arm64` của `build` ở push đầu (`36e0ba2`) xanh, 71–94 s mỗi chân (`amd64` 83–102 s); lượt một service (`983f761`) xanh cả hai chân |
| `ports: ["127.0.0.1:5432:5432"]` của service container chạy; test Postgres/Redis và ffmpeg không SKIP | Bước B: log job `check` của `ci.yml` không có dòng SKIP của `internal/pgtest`, `internal/redistest` hay "not in PATH" | Đạt (2026-10-21), phép kiểm sửa: service container map `127.0.0.1:5432`, `127.0.0.1:6379`, cả hai healthy; ffmpeg 6.1.1 cài; 42 gói `ok`. `go test` không chạy `-v` nên không bao giờ in dòng SKIP, grep log không chứng minh được gì; bằng chứng là đường code: `internal/pgtest`, `internal/redistest` chỉ skip khi URL rỗng mà `Makefile` luôn đặt (không tới được là `t.Fatal`), test transcode chỉ skip khi không có ffmpeg |
| Mọi job của lượt `pull_request` chỉ có `contents: read` | Bước D: mục "GITHUB_TOKEN Permissions" ở đầu log từng job của lượt PR chỉ có `Contents: read` và `Metadata: read` | Đạt (2026-10-21): mọi job của lượt PR promote (#1, #5) và PR thường (#4, gồm hai chân `build-nopush`) chỉ có `Contents: read`, `Metadata: read`; `ci-ok`, `images-ok` chỉ `Metadata: read`. Lượt `main`: `build` thêm `Packages: write`, `last-success` chỉ `Actions: read` |
| `ci-ok`, `images-ok`: job bỏ qua hợp lệ thì xanh, job bỏ qua ngoài bảng hay `failure`/`cancelled` thì đỏ | Trước push: logic của hai job tổng chạy với `needs` JSON giả cho từng ca (PR fork, PR promote, danh sách rỗng, rescan, `check` bị `skipped`); bước D: PR thường và PR promote xanh | Trước push đạt (2026-10-21): đoạn `run:` cắt nguyên từ hai workflow, 19 ca đúng cả 19: `ci-ok` (đủ 6 `success` xanh; một job `skipped`, `failure`, `cancelled` hay thiếu thì đỏ), `images-ok` (PR có image, PR promote chỉ values, push `main` danh sách rỗng, push `main` đủ job, rescan theo lịch, dispatch diễn tập: xanh; `values-check` hay `build-nopush` bị bỏ khi lượt cần nó, `build` bị bỏ khi có image, `promote` lỗi, `rescan` lỗi hay bị bỏ ở chế độ rescan, `plan` lỗi: đỏ). Sau push đạt (2026-10-21): xanh ở PR thường (#3 chỉ values, script, tài liệu; #4 một service), PR promote (#1, #5: build bỏ qua, `values-check` chạy), push `main` có image (`983f761`) và không image (`b7b7cbc`, `8a4e21c`, `bea9954`), dispatch diễn tập, hai rescan; đỏ khi job lỗi thật (`ci-ok` của `36e0ba2`: `make tools` lỗi trên GNU Make 4.x của runner) |
| Base của phép so (lần thành công cuối), ca ba push, lượt cũ chạy lại không build gì, chỉ build service đổi | `deploy/ci/changed-services.sh` trên repo git tạm (trước push); bước D: PR và lượt `main` chỉ build service đã đổi | Trước push đạt (2026-10-20, repo git tạm): base = A, head = C sau B đổi gateway và C đổi feed-service → hai service; lượt cũ chạy lại (HEAD là tổ tiên của base) → không build gì; base rỗng, toàn số 0, không tra được hay không phải tổ tiên → cả sáu; `deploy/k8s/lib.sh` hay dòng `TRIVY_IMAGE`/`SYFT_IMAGE`/`COSIGN_IMAGE` của `Makefile` → cả sáu, dòng ghim khác của `Makefile` → không gì. Trên commit thật (2026-10-21): `8e7a6d8` → gateway, `c4d82f5` (chỉ values) → không gì, `1b6f2c8` (`lib.sh`) → cả sáu. Sau push (2026-10-21): PR #4 (một dòng comment trong `services/feed-service/`) chỉ chạy `build-nopush` của feed-service; push `b7b7cbc` (dòng `Makefile` ngoài ghim), `8a4e21c`, `bea9954` (values, script, tài liệu) không build gì; push `983f761` build đúng feed-service. Quy tắc base đúng nhưng cho một lần phát hành thừa: GitHub (sự cố Webhooks) không chạy workflow nào cho push `94c3dbe` (merge PR #4), feed-service phát hành bằng dispatch `services=feed-service` (PR promote #5); dispatch không đẩy base, nên lượt push `983f761` (merge PR #5) so từ `bea9954` và build lại feed-service cùng code, digest mới, PR promote #6 |
| Promote không ghi lùi: lượt cũ chạy lại, cùng commit, không so được, PR cuộn đã đóng hay đã merge | Trước push: `deploy/ci/promote.sh` chọn ứng viên trên repo git tạm cho từng ca; bước D: "Re-run all jobs" một lượt `main` cũ sau khi lượt mới hơn xong → không build, PR cuộn không đổi | Trước push đạt (2026-10-20, origin trần + clone tạm, `PROMOTE_DRY_RUN=1`): PR mở gom service cũ và mới; kết quả cũ tới sau giữ bản mới hơn; nhánh bot bị đổi giữa chừng → `--force-with-lease` từ chối; PR đã merge, ký lại cùng digest → không push; cùng commit → digest vừa ký thắng; tag không thuộc `main` → service đó không promote, job đỏ; rollback bằng `git revert` không bị PR cuộn hồi sinh; PR từ fork hay do người mở không tính. Bước D: chưa kiểm (2026-10-21), chưa chạy lại lượt `main` cũ nào |
| Mục `.trivyignore.yaml` thôi tác dụng từ 00:00 UTC ngày `expired_at` | Trước push: `trivy image` bằng `TRIVY_IMAGE` trên một image có CVE đã biết với hai file bỏ qua, `expired_at` = hôm nay và = ngày mai (UTC): CVE hiện lại và `scan-gate.sh` chặn với file thứ nhất, bị bỏ và cổng đạt với file thứ hai | Đạt (2026-10-20, image có 4 CRITICAL đã biết): `expired_at` ngày mai → 0 CRITICAL, cổng đạt; hôm nay → 4 CRITICAL, cổng chặn; quá 30 ngày, có phần `secrets:`, thiếu `statement` hay `expired_at` → chặn. `scan-gate.sh --check-ignorefile` (job `config`) chặn cùng các lỗi quy tắc mà không cần image |
| Digest vào `main` có attestation ≤ 48 giờ: rescan đọc PR cuộn và `values_ref`, `values-check`, kiểm của `gitops.sh` | Bước C: `values-check` xanh trên PR promote; sau đó trên máy `values-check.sh` và `make k8s-gitops-up` với `SVP_ATTEST_MAX_AGE=1m` dừng (trước khi tạo cluster) kèm lệnh dispatch; dispatch rescan với `values_ref`, xong thì chạy lại ngay với `SVP_ATTEST_MAX_AGE=15m` và đạt | Đạt (2026-10-21): `values-check` xanh trên PR promote #1, #5; trên máy với `SVP_ATTEST_MAX_AGE=1m`, `values-check.sh` báo 6 FAIL và `make k8s-gitops-up` dừng trước khi tạo container nào, cả hai in lệnh dispatch có `values_ref`; dispatch rescan `values_ref=8a4e21c` (xanh sau 2 phút) rồi với `15m` cả hai đạt 6/6 |
| Push đúng artifact đã quét: config digest trên GHCR bằng `Metadata.ImageID` | Bước B: bước so của mọi chân build trên `main` | Đạt (2026-10-21): 12 chân build ở push đầu ghi config digest của bản đã quét; đọc ẩn danh trên GHCR, config digest của mỗi manifest con bằng `Metadata.ImageID` trong predicate (6 service × 2 nền tảng) |
| Index có đúng hai manifest `linux/amd64`, `linux/arm64` | Bước B: `docker buildx imagetools inspect` từng digest index | Đạt (2026-10-21): 6/6 digest là index đúng hai manifest `linux/amd64`, `linux/arm64` (log job `merge`, đọc lại ẩn danh) |
| Visibility mặc định của package mới; package liên kết repo qua label | Bước B: `gh api users/anhnvcoder/packages/container/short-video-platform%2F<svc>` (`visibility`, `repository`) | Liên kết đạt (2026-10-21): config có label `org.opencontainers.image.source`, trang package nằm dưới repo. Visibility mặc định: không kiểm được (token `gh` không có `read:packages`, trạng thái trước khi đặt public không ai ghi lại). Cả 8 package (6 service, 2 diễn tập) đã public, kéo ẩn danh được |
| Chữ ký và attestation định dạng cũ nằm được trên GHCR; xác minh ẩn danh | Bước C: `cosign verify`, `cosign verify-attestation --type vuln`/`--type spdxjson` bằng `COSIGN_IMAGE` với đúng issuer + subject | Đạt (2026-10-21): tag `.sig`, `.att` cạnh digest; `cosign verify`, `verify-attestation --type vuln` và `--type spdxjson` ẩn danh bằng `COSIGN_IMAGE` với issuer + subject của mục 7: mỗi image 1 chữ ký và 1 `vuln` trên index, 1 `spdxjson` trên mỗi manifest con, không có trên index (đúng chỗ attest của mục 7) |
| `--replace` giữ đúng một attestation `vuln` trên index sau rescan | Bước C: hai lượt `gh workflow run images.yml --ref main -f rescan=true`, rồi `cosign verify-attestation --type vuln` đếm được 1 | Đạt (2026-10-21): sau bản phát hành (quét 03:12Z) và hai rescan (06:07Z, 06:45Z), mỗi image vẫn đúng 1 attestation `vuln`, `scanFinishedOn` theo lần quét mới, đủ hai nền tảng |
| Predicate `vuln` đủ hai nền tảng, `scanFinishedOn` là lần quét cũ hơn; `attest` không vượt giới hạn Rekor | Bước B: job `sign` của media-worker xanh; payload đọc bằng `cosign verify-attestation` có hai phần tử `platforms` | Đạt (2026-10-21): `platforms` có đúng hai phần tử, digest trùng hai manifest con của index; `scanFinishedOn` là lúc lần quét xong sớm hơn (nằm giữa `CreatedAt` của hai báo cáo); envelope của media-worker 346 KB, job `sign` xanh; sau hai rescan vẫn đủ hai nền tảng |
| PR promote: lượt `pull_request` chờ duyệt, sau khi duyệt `ci-ok`, `images-ok` thoả ruleset | Bước C: PR promote mở, bấm duyệt, nút merge mở khi hai check xanh | Đạt tới PR #5 (2026-10-21): PR promote #1 có lượt chạy lúc 03:14:27Z, job chỉ bắt đầu khi bấm duyệt (04:46:30Z) nhưng lượt đó đỏ (`ci-ok` đỏ: chạy code trước `b7b7cbc`); `ci-ok`, `images-ok` xanh đến từ lượt đóng rồi mở lại PR lúc 04:49:32Z (không chờ duyệt), merge 04:55:45Z khi ruleset đã active; PR #5 duyệt 87 s sau khi mở, hai check xanh, merge 15:50:15Z |
| Kyverno v1.19.1 trên k3s v1.36.5 nhận image đã ký, sạch; từ chối chưa ký, CRITICAL, ngoài prefix, không digest, quá hạn | `make drill-k8s-supplychain` trên cluster GitOps sau bước C (ca CRITICAL trong 72 giờ sau dispatch image diễn tập) | Trước push (cluster dev, `SUPPLYCHAIN_ENFORCE_TMP=1`, 2026-10-21): ngoài prefix (registry k3d, Docker Hub) và không digest bị từ chối đúng message của rule; đường keyless với image công khai đã ký của nhà cung cấp khác (CloudNativePG v1.28.1 trên GHCR, policy thử): đúng identity nhận (7,5 s, chưa có trong cache), sai subject từ chối (6,2 s). Đã ký và sạch, chưa ký, CRITICAL, quá hạn: sau push đạt (2026-10-21, cluster GitOps, ba lượt trên hai cluster): bản phát hành nhận hai lần liền; chưa ký từ chối (Deployment thật có `FailedCreate` "image without a keyless signature by …/images.yml@refs/heads/main"); CRITICAL từ chối ("vuln attestation reports a CRITICAL vulnerability", image diễn tập quét 03:45:39Z, chạy trong 72 giờ); registry k3d, Docker Hub và image không digest từ chối đúng message; attestation quá hạn (policy tạm tuổi 5 s) từ chối "vuln attestation older than 5s" |
| Webhook chỉ nhận `svp`; Kyverno tắt thì pod `svp` bị từ chối, namespace khác vẫn tạo được | `make drill-k8s-supplychain`, ca admission controller tắt; ảnh chụp cấu hình webhook trước và sau | Trước push đạt (cluster dev, Enforce tạm, 2026-10-21): admission controller không lịch được thì pod `svp` bị từ chối ("no endpoints available for service kyverno-svc", 81 ms), pod `svp-probe` được nhận; webhook sau khi Kyverno lên lại trùng ảnh chụp trước. Webhook của policy chỉ có `matchLabels` `svp` cùng hai `NotIn` (`kube-system`, `kyverno`), `timeoutSeconds: 30`. GitOps đạt (2026-10-21, ba lượt): pod `svp` bị từ chối ("failed calling webhook … no endpoints available", 70–230 ms), pod `svp-probe` được nhận (80–111 ms); webhook và `syncPolicy` của Argo CD sau diễn tập trùng ảnh chụp đầu |
| Ephemeral container (`kubectl debug`) và UPDATE sang image chưa ký bị từ chối | `make drill-k8s-supplychain`, ca ephemeral container và ca UPDATE | Trước push, phần từ chối đạt (cluster dev, Enforce tạm, 2026-10-21): ephemeral container và UPDATE sang image registry k3d bị từ chối với message của rule prefix (71, 67 ms). Image chưa ký của GHCR và nửa nhận (ephemeral đã ký): sau push đạt (2026-10-21, GitOps): ephemeral và UPDATE sang `drill-unsigned` bị từ chối theo rule chữ ký, ephemeral đã ký được nhận (dry-run 2,9–6,3 s). Lượt đầu nửa nhận báo FAIL dù Kyverno đã nhận (`kubectl` v1.37.1 `patch --dry-run=server` không in "(server dry run)"); phép kiểm của diễn tập đã sửa theo đó |
| `--dry-run=server` đi qua xác minh image | `make drill-k8s-supplychain`: các ca dry-run cho đúng message của rule | Trước push đạt (cluster dev, 2026-10-21): mọi ca dry-run cho đúng message của rule cần từ chối (prefix, digest), và ca keyless dry-run đi qua xác minh chữ ký thật (đúng identity nhận, sai subject từ chối với message chữ ký). Sau push đạt (2026-10-21, GitOps): ca CRITICAL, quá hạn, ephemeral chưa ký đi qua xác minh chữ ký và attestation thật (lạnh 8,3–12,4 s) và cho đúng message |
| Ngoài prefix bị từ chối không chờ mạng | `make drill-k8s-supplychain`, ca image registry k3d và Docker Hub: độ trễ admission < 1 s | Trước push đạt (cluster dev, 2026-10-21): registry k3d 80 ms, Docker Hub theo digest 80 ms, image GHCR không digest 76 ms. GitOps (2026-10-21, ba lượt): registry k3d và Docker Hub 78–315 ms, không digest 77–166 ms |
| Cache 1 MiB (`--imageVerifyCacheMaxSize=1048576`, mục 8) giữ được kết quả có payload | `make drill-k8s-supplychain`, ca image đã ký chạy hai lần liền: lần hai nhanh hơn rõ (không gọi TUF, GHCR) | Đạt một phần (2026-10-21, GitOps): lần lặp không có log xác minh (`verifying cosign …` chỉ ở lần đầu mỗi digest), lạnh 8,3–12,4 s, có cache 2,6–3,5 s; nhưng mỗi admission vẫn đọc dữ liệu image từ GHCR (phần ~2,5 s còn lại), nên "không gọi TUF, GHCR" chỉ đúng với phần xác minh (TUF, chữ ký, attestation) |
| Kyverno chạy dưới PSA `restricted`, NetworkPolicy egress đủ cho TUF và GHCR | `make k8s-up` không có event PodSecurity; ca nhận image đã ký của `make drill-k8s-supplychain` PASS khi policy egress đã áp | Trước push đạt (cluster dev, 2026-10-21): `make k8s-up` từ đầu 0 event PodSecurity, hai pod Kyverno Ready không restart; ca keyless nhận image đã ký trên GHCR khi NetworkPolicy egress (443 ra địa chỉ công khai, không dải private) đã áp, nên TUF và GHCR tới được. GitOps đạt (2026-10-21): `make k8s-gitops-up` ở `8a4e21c` 0 event PodSecurity (cluster `bea9954` chỉ có 23/23 Application Healthy, không chụp event); bản phát hành được nhận khi NetworkPolicy egress của `kyverno` đã áp |
| Argo CD bỏ qua kind report của Kyverno; Application `kyverno`, `svp-policy` Synced | `make k8s-gitops-up` xong với mọi Application Synced/Healthy | Đạt (2026-10-21): `make k8s-gitops-up` ở `8a4e21c` và `bea9954`: 23/23 Application Synced/Healthy, sync cuối Succeeded; Argo CD không theo dõi PolicyReport, EphemeralReport nào |
| RAM Kyverno trong ngân sách mục 8 | Đo theo cách ADR-0014 §2 ở lượt kiểm cuối (đường dev) và diễn tập chuỗi cung ứng (đường GitOps) | Đường dev đạt (2026-10-21): Kyverno 168 MiB nghỉ, 132 MiB sau diễn tập; cluster nghỉ 6,40 GiB, đỉnh KEDA 7,68 GiB (cửa sổ 6 mẫu, 3 replica Ready), mẫu cao nhất 7,92 GiB; chi tiết ở mục 8. Đường GitOps (2026-10-21): Kyverno 117–250 MiB, trong ngân sách. Cả cluster (thêm Argo CD 0,9–1,4 GiB) nghỉ 60 s sau khi mọi pod Ready 8,04 GiB, tổng pod 4,0 GiB nhưng MEM USAGE trừ `active_file` 7,17 GiB nên thiếu (b) của ADR-0014 §2 (lần dựng trước cũng vậy: 8,14 và 7,18 GiB); (b) chỉ đạt sau 70–90 phút (5,92–6,20 GiB, lúc VM đã đẩy một phần anon ra swap); (a) đạt (đỉnh 3 worker 8,45 GiB, 2 worker 8,46 GiB). Ở đỉnh 3 worker k3s server chết: tiêu chí (c) và media-worker tối đa 2 ở [ADR-0017](0017-gitops-capacity-media-worker-max2.md). Chưa áp bước cắt nào cho (b) |
| `schedule` của rescan chạy hằng ngày | `gh run list --workflow images.yml --event schedule` sau 48 giờ | Chưa kiểm (2026-10-21): lượt theo lịch đầu tiên 2026-10-22 01:17Z |
| App Renovate không mở PR onboarding; PR cập nhật được SHA action | Sau khi cài App: issue Dependency Dashboard có, không PR onboarding; PR đầu cho action đổi file trong `.github/workflows/` | Nửa đầu đạt (2026-10-21): không PR onboarding, App mở issue Dependency Dashboard (#2); danh sách khớp extract của HEAD (`--platform=local --dry-run=extract`, 238 dependency) trừ dependency Renovate không tra (image compose build tại chỗ, ffmpeg không version, module Go gián tiếp). `ghcr.io/cloudnative-pg/postgresql` v18 nằm ở "Pending Status Checks" thay vì "Pending Approval": Renovate 44.165.1 xét `minimumReleaseAge` trước `dependencyDashboardApproval`, nên bản cần duyệt hiện là pending tới khi đủ 3 ngày; không nhánh, không PR ở cả hai trạng thái. Nửa sau (PR đổi SHA action): chưa kiểm, sau khung sáng thứ Bảy 2026-10-24 |
| Ngân sách thời gian CI | Bước D: `gh run view` của lượt `main` và lượt PR | Đạt (2026-10-21): `ci.yml` tới `ci-ok` 4,9–6,3 phút (PR #3, #4, #5; push `8a4e21c`, `bea9954`, `983f761`), 7,6 phút khi cache công cụ trống (`b7b7cbc` đổi `Makefile`); `images.yml` một service trên `main` tới PR promote 3,7 phút (push `983f761` → PR #6) và 3,5 phút (dispatch → PR #5), cả sáu service 3,2 phút (push đầu → PR #1) |

## Hệ quả

- **Được:**
  - Mọi thay đổi vào `main` qua PR đã chạy đủ mục Kiểm tra (`ci-ok`) và build, quét image (`images-ok`); code sinh lệch,
    contract proto phá vỡ, bí mật trong lịch sử git đều đỏ trước merge.
  - Image phát hành build trên runner sạch, đa kiến trúc, nằm trên GHCR theo digest, không mất cùng cluster; mỗi image có
    chữ ký keyless truy được về workflow và commit, SBOM mỗi nền tảng, kết quả quét cả hai kiến trúc làm mới hằng ngày.
  - Threat model hàng giai đoạn 5 có biện pháp cụ thể: FF-8 (CRITICAL chặn ở CI và ở admission, Renovate giữ base mới),
    SC-1 (chữ ký + attestation `vuln` theo digest, Kyverno ở `svp`, digest bên thứ ba ghim và kiểm tĩnh), SC-2 (action ghim
    SHA, chỉ action của GitHub và của nhà cung cấp công cụ, nền tảng ép bằng `allowed_actions` và `sha_pinning_required`,
    quyền theo job, không secret cho PR fork), SEC-1 và JWT-10 (gitleaks toàn lịch sử), SEC-2 (trivy quét bí mật trước
    push, chặn mọi severity).
  - Phát hành không còn chạy trên máy; `make k8s-release` và bước dựng lại image của `gitops.sh` bị bỏ.
- **Phải trả:**
  - Từ khi bật ruleset, cả người học cũng vào `main` qua PR; mỗi phát hành thêm một PR promote phải duyệt lượt chạy rồi
    merge tay.
  - Bên ngoài có quyền trên repo hay chuỗi cung ứng: GitHub Actions (`packages: write`, `contents: write` ở job promote) và
    App Renovate (ghi nội dung, PR, workflow). Sigstore công khai (Fulcio, Rekor lúc ký; TUF lúc Kyverno xác minh) và GHCR
    là phụ thuộc: không tới được thì không phát hành được và pod `svp` mới bị từ chối.
  - Kyverno một replica, `failurePolicy: Fail` trên đường GitOps: Kyverno chết (crash, không lịch được, mất node) thì không
    pod `svp` mới nào được tạo (scale KEDA, restart, rollout); namespace khác không bị ảnh hưởng. Ngược lại, scale
    admission controller về 0 hay gỡ Kyverno thì Kyverno tự xoá webhook và mọi pod `svp` được nhận không kiểm (mục 8):
    ai sửa được Deployment ở namespace `kyverno` là tắt được policy; trên đường GitOps Argo CD self-heal trả lại. Kyverno
    chạy ngoài dải Kubernetes đã test một minor.
  - **`schedule` bị tắt:** GitHub tắt workflow theo lịch của repo public sau 60 ngày không hoạt động ("scheduled workflows
    are automatically disabled when no repository activity has occurred in 60 days"; tài liệu không định nghĩa "activity").
    Khi đó attestation `vuln` quá 72 giờ và mọi pod `svp` mới (scale KEDA, restart, `make k8s-gitops-up`) bị từ chối tới khi
    có người bật lại workflow (`gh workflow enable images.yml`) và dispatch rescan (`gh workflow run images.yml --ref main
    -f rescan=true`).
  - Định dạng cũ của cosign dựa vào cờ đã deprecated (`--new-bundle-format`, `--replace`; `--use-signing-config` deprecated
    trên nhánh `main`), cosign v4 sẽ bỏ.
  - Để lượt PR chỉ có `contents: read`: ma trận build khai hai lần (`build-nopush`, `build`), lời gọi API Actions tách ra
    `last-success`, PR không có chú thích code scanning trên diff (mục 1, 2, 4).
  - PR đổi values cần attestation không quá 48 giờ (mục 7): rollback về digest cũ cần một lượt dispatch rescan trước khi
    merge; PR như thế để quá 72 giờ sau lần làm mới cuối rồi mới merge thì pod mới bị từ chối tới lượt rescan kế.
  - Lượt `images.yml` lỗi làm lượt sau build lại cả service đã phát hành ở lượt lỗi (digest mới, PR promote cập nhật,
    gateway có canary dù code không đổi). Chấp nhận vì lượt lỗi trên `main` hiếm.
  - Image diễn tập (`drill-vulnerable` có CRITICAL thật, `drill-unsigned`) nằm công khai trên GHCR tới khi người học xoá;
    package đã public thì không đổi lại private được.
  - Chữ ký của nhà cung cấp image bên thứ ba chưa kiểm (chỉ ghim digest, kiểm tĩnh); identity ký nhận mọi trigger của
    `images.yml` trên `main` (push, lịch, dispatch); Kyverno không tự đối chiếu hai digest con trong predicate với index;
    kết quả xác minh được cache tới 60 phút (tuổi nhận được tới 72 giờ + 60 phút).
  - RAM: Kyverno dự kiến thêm 0,25–0,35 GiB vào cả hai đường; đo trên đường dev 0,13–0,16 GiB, cluster dev nghỉ 6,40
    GiB, đỉnh 7,92 GiB (mục 8).
- **Xem lại khi:**
  - Build CI của một thay đổi nhỏ quá 10 phút (cân nhắc `go list -deps`, mục 3), hay `ci.yml` quá 10 phút.
  - Số HIGH có bản vá còn mở quá 30 ngày (cân nhắc chặn HIGH có bản vá, mục 6).
  - Image có người tiêu thụ ngoài repo, hay nhiều môi trường cần ghi chú phát hành (semver, mục 5; giai đoạn 7).
  - Kyverno phát hành bản tuyên bố hỗ trợ Kubernetes 1.36, hay bản có #18049 (chọn attestation mới nhất): xét nâng Kyverno
    và chuyển cosign sang bundle mới (mục 7), ký lại mọi digest đang chạy.
  - cosign v4 phát hành (bỏ cờ của định dạng cũ), hay TUF phát Rekor v2 làm mặc định.
  - Lên cluster cloud (giai đoạn 7) hay review bảo mật giai đoạn 9: kiểm chữ ký nhà cung cấp, policy ngoài image, SLSA.
  - RAM đo thật vượt ngưỡng ADR-0014 §2 sau bước cắt đầu của mục 8.
  - Image runner Ubuntu 24.04 bị ngừng, hay Docker trên runner chuyển sang containerd image store (kiểm lại phép so config
    digest của mục 4).
  - Có thêm người làm repo: bắt 1 approval, `strict_required_status_checks_policy`, tách quyền promote.

## Hiện thực ở

- Workflow, quyền, job của `ci.yml` (§1, §2): `.github/workflows/ci.yml`, `.github/workflows/images.yml`, target `check`,
  `generate-check` của `Makefile`.
- Chỉ build service đổi (§3): `deploy/ci/changed-services.sh`, `deploy/ci/last-success.sh`, `deploy/ci/plan.sh`.
- Image đa kiến trúc, quét trước khi push (§4–§6): `deploy/ci/build-image.sh`, `deploy/ci/push-image.sh`, `deploy/ci/merge-index.sh`,
  `deploy/ci/scan-gate.sh`, `deploy/ci/common.sh`, `deploy/docker/service.Dockerfile`, `deploy/docker/web.Dockerfile`,
  `.trivyignore.yaml`, image diễn tập `deploy/ci/drill/vulnerable.Dockerfile`.
- SBOM, chữ ký, attestation, rescan (§7): `deploy/ci/sign-image.sh`, `deploy/ci/vuln-predicate.sh`, `deploy/ci/rescan.sh`,
  `deploy/ci/verify-release.sh`.
- Kyverno (§8): `deploy/helm/svp-policy/` (`templates/imagevalidatingpolicy.yaml`, `values.yaml`), `deploy/k8s/values/kyverno.yaml`,
  namespace và NetworkPolicy của Kyverno ở `deploy/helm/svp-cluster/` (`values.yaml`, `templates/networkpolicies.yaml`), cách cài
  Audit/Enforce ở `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`; diễn tập `deploy/k8s/drills/supplychain.sh`,
  `deploy/k8s/drills/threats.sh`.
- Promote qua PR GitOps (§9): `deploy/ci/promote.sh`, `deploy/ci/values-check.sh`, `deploy/k8s/values/services/`,
  `deploy/k8s/gitops.sh`, `deploy/k8s/drills/gitops.sh`, `deploy/k8s/install.sh` (đường dev không đọc digest phát hành).
- Renovate và ghim digest (§10): `renovate.json`, `deploy/k8s/check-image-digests.sh`; dòng ghim `# renovate:` ở `Makefile`,
  `deploy/k8s/lib.sh`, `deploy/k8s/k8s.mk` và values bên thứ ba ở `deploy/k8s/values/` (`argo-cd.yaml`, `argo-rollouts.yaml`,
  `cert-manager.yaml`, `cloudnative-pg.yaml`, `envoy-gateway.yaml`, `keda.yaml`, `kube-prometheus-stack.yaml`, `kyverno.yaml`,
  `loki.yaml`, `otel-collector.yaml`, `plugin-barman-cloud.yaml`, `pyroscope.yaml`, `tempo.yaml`).
- Bảo vệ `main` (§11): `.github/rulesets/main.json`.
