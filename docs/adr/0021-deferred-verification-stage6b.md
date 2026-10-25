# 0021. Giai đoạn 6b: kiểm chứng dồn chạy trên runner GitHub Actions `ubuntu-24.04` bằng workflow `verify.yml` chạy tay (`workflow_dispatch`, thêm lịch hằng tuần trên `main` từ 2026-10-25), mỗi lượt một kịch bản dựng compose hay k3d bằng target `make` có sẵn, artifact chỉ theo danh sách cho phép và qua bộ quét giá trị bí mật, VM thuê theo giờ chỉ khi runner trượt tiêu chí đo được; Argo CD đọc repo công khai qua HTTPS ẩn danh; Chaos Mesh, Velero (CSI hostpath) và k6 thu nhỏ trên k3d của runner; tệp bỏ qua misconfig có hạn, cổng quét lockfile npm, điều kiện page mới của `RateLimitFallbackActive`

- Trạng thái: Chấp nhận; nơi chạy A/B do người học chốt ngày 2026-10-24, các quyết định còn lại theo đề xuất ở đây. Phần 1
  (workflow, kịch bản `compose-obs` và `dev-k3d`, mục 9–11) hiện thực và đã chạy trên runner 2026-10-24 đến 2026-10-25 (mục Kết
  quả); chưa hiện thực: phần 2 (thay object store, [0022](0022-local-object-store-minio-replacement.md) đang Đề xuất), phần 3
  (GitOps, canary web, k6, Chaos Mesh, Velero) và phần 4 (mục 5)
- Ngày: 2026-10-24

## Bối cảnh

- Roadmap thêm **giai đoạn 6b "Kiểm chứng dồn"** ngày 2026-10-24
  ([plan](../../plans/261004-devops-sa-roadmap/plan.md), mục 6b): gom mọi việc dời từ giai đoạn 4–6 vì máy 16 GB không chạy nổi
  mà không cần dịch vụ AWS/GCP, để giai đoạn 7 chỉ còn việc của cloud. **Xong khi:** mọi dòng "kiểm sau"/"dời" của ADR-0017,
  ADR-0019, ADR-0020 có kết quả đo hay lý do còn lại. Người học chốt nơi chạy: **(A)** mặc định là runner GitHub Actions của repo
  public, workflow `workflow_dispatch` dựng k3d hay compose bằng đúng target `make` hiện có; **(B)** VM thuê theo giờ chỉ khi A thật
  sự không đủ, người học chạy lệnh, xoá trong ngày. ADR này chốt phần còn lại: loại runner và tiêu chí "runner đủ", hình workflow,
  quyền và secret, cách lọc log và artifact, kịch bản cho từng dòng dời, và các quyết định nhỏ của giai đoạn.
- Các dòng dời:
  - [ADR-0017](0017-gitops-capacity-media-worker-max2.md): hai media-worker cùng transcode trên node đủ CPU, hai lượt
    `drill-k8s-keda` PASS gồm tiêu chí (c); RAM nghỉ (b) ở điểm đo của ADR-0014 §2 trên cluster GitOps (thiếu ở cả hai lượt giai
    đoạn 5, "Còn mở: RAM (b)" của roadmap).
  - [ADR-0019](0019-web-k3d-supply-chain-observability.md) §12: cluster GitOps chạy image `web` đã ký, Kyverno Enforce từ chối
    image web chưa ký, source map của image CI, canary web dưới traffic (404 asset, số lần tải lại), `drill-obs-threats` (WEB-9),
    RAM có web và `resources` của web, cổng CI quét `web/pnpm-lock.yaml`.
  - [ADR-0020](0020-reliability-stage6.md) mục 1 (sửa 2026-10-24): k6 tải lớn nhất nơi chạy chịu được, ba thí nghiệm Chaos Mesh,
    Velero đích MinIO trong cluster, hai media-worker và RAM nghỉ, ngưỡng p99 canary và HPA của web, thay MinIO cho đường local,
    ngưỡng page của `RateLimitFallbackActive`; LCP xem lại khi Lighthouse chạy trên runner; các dòng "Kiểm chứng sau" của 6b.
  - [Threat model](../threat-model.md) hàng 6b: OPS-4, BAK-2, WEB-9 và OPS-1 qua `drill-obs-threats`, SC-1 cho web.
  - Việc tĩnh của roadmap 6b: 19 cảnh báo code scanning (18 của `trivy-config`), cổng lockfile npm, P2 của giai đoạn 6.
- Hiện trạng code (đọc ngày 2026-10-24, chi tiết ở mục Kiểm chứng):
  - Job `stack` của `ci.yml` đã dựng compose `core` trên `ubuntu-24.04`: Postgres và Redis là service container publish trên
    `127.0.0.1` và IP bridge `172.17.0.1`, `make ci-bridge-check`, gói apt `postgresql-client redis-tools ffmpeg jq`, `make env`
    trong job, `contents: read`, không secret, artifact chỉ hai loại đã lọc. Chưa job nào dựng k3d.
  - Script k3d viết và chạy trên macOS: drill ghi "written for bash 3.2"; `deploy/k8s/gitops.sh` đọc mode của deploy key bằng
    `stat -f %Lp` (chỉ BSD); `make ci-tools` chỉ chạy trên Linux x86_64 (Helm linux-amd64 ghim sha256); k3d cài bằng `make tools`.
  - Drill và e2e gọi `api.svp.localhost`, `svp.localhost`, `s3.svp.localhost` tới `127.0.0.1:8443` bằng phân giải tên của hệ
    thống, không `--resolve`.
  - `deploy/k6/cloud/run.sh` và `deploy/k8s/cloud/velero/drill-restore.sh` từ chối mọi context `k3d-*`; values Chaos Mesh viết cho
    EKS (socket `/run/containerd/containerd.sock`), Velero cho S3 + Pod Identity + snapshot CSI của EBS; `render.sh` dựng đúng 20
    pod.
  - Argo CD đọc repo qua SSH bằng deploy key chỉ đọc (`gitops.sh` `repo_url`, `repoURL` của `deploy/argocd/apps/values.yaml`,
    `sourceRepos` của `deploy/argocd/project.yaml`).
  - `RateLimitFallbackActive` (page) cháy khi gateway có một quyết định trên bộ đếm dự phòng trong 1 phút; game day 2026-10-24
    thấy nó cháy dưới tải k6 `local` vì lệnh Redis quá hạn 50 ms vài lần mỗi phút qua `host.docker.internal`.
  - `trivy-config` chỉ báo; `.trivyignore.yaml` chỉ nhận `vulnerabilities` (`scan-gate.sh`), nên misconfig chưa có đường ghi lý
    do bỏ qua có hạn. Trivy trong image web chỉ thấy 14 gói npm (ADR-0019 §1), lockfile chưa có cổng nào quét.
- Ràng buộc: repo công khai, nên log và artifact của mọi lượt Actions ai cũng đọc, kể cả khi job đỏ; `workflow_dispatch` chỉ chạy
  được khi file có trên nhánh mặc định; không dịch vụ AWS/GCP; AI không chạy lệnh nào chạm tài khoản cloud; máy 16 GB không chạy
  k3d hay tải, chỉ kiểm tĩnh.

## Kiểm chứng (đã kiểm ngày 2026-10-24)

Tài liệu GitHub và Docker đọc ngày 2026-10-24; code đọc ở `main` `8b473ad`; cảnh báo code scanning đọc bằng `gh api` (chỉ đọc).

| Kiểm gì | Nguồn hay lệnh | Kết quả |
| --- | --- | --- |
| Runner chuẩn cho repo public | <https://docs.github.com/en/actions/reference/runners/github-hosted-runners> | Linux x64 (`ubuntu-24.04`, `ubuntu-latest`) và Linux arm64 (`ubuntu-24.04-arm`): **4 CPU, 16 GB RAM, 14 GB SSD** mỗi loại. "Use of the standard GitHub-hosted runners is free and unlimited on public repositories." Mỗi runner (trừ loại một CPU) là một VM mới; `sudo` không mật khẩu. Trang không nói swap, không nói dung lượng trống thật của ổ |
| Giới hạn | <https://docs.github.com/en/actions/reference/limits> | Job trên runner GitHub tối đa **6 giờ** ("the job is terminated and fails"); lượt workflow tối đa 35 ngày; gói Free tối đa 20 job đồng thời |
| `workflow_dispatch` | <https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow>; `workflow-syntax` | "your workflow must be in the default branch"; "Write access to the repository is required"; tối đa 25 `inputs` |
| Image runner `ubuntu-24.04` | <https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md> (Image Version 20261012.334.1) | Kernel 6.17.0-1022-azure, systemd 255, Docker 28.0.4, Compose 2.38.2, buildx 0.38.0, kubectl **1.37.1**, Helm 3.22.0 (không dùng: `make ci-tools` cài bản ghim), jq 1.7, gh 2.102.0. Không nói swap hay phân vùng; `ubuntu-latest` sang 26.04 từ tháng 11/2026 |
| Docker Hub ẩn danh | <https://docs.docker.com/docker-hub/usage/pulls/>, <https://docs.docker.com/docker-hub/usage/>; <https://docs.github.com/en/actions/reference/limits> (mục "Docker Hub's rate limit for GitHub Actions") | Docker: **100 pull mỗi 6 giờ** cho mỗi IPv4 (hay /64 IPv6) với người dùng ẩn danh; trang của Docker không nhắc GitHub, chỉ nói IP có thể "unlimited in partnership with a publisher, provider, or an open source organization". GitHub: "GitHub-hosted runners pulling public images: Docker Hub's rate limit is not applied" (image riêng tư vẫn bị tính). Pull từ containerd trong node k3d đi ra cùng IP của runner, nhưng không trang nào nói riêng ca đó |
| Phân giải `*.localhost` | Image runner có systemd 255; hành vi của systemd-resolved theo `systemd-resolved.service(8)` (không đọc lại ngày này): tổng hợp mọi tên `*.localhost` về `127.0.0.1` và `::1` | k3d chỉ publish `127.0.0.1:8443`: client chọn `::1` trước thì bị từ chối kết nối rồi mới thử IPv4, hay hỏng nếu không thử lại. Chưa đo trên runner |
| Mẫu job `stack` | `.github/workflows/ci.yml` dòng 355–479 | `timeout-minutes: 45`, `contents: read`, service container trên `127.0.0.1` và `172.17.0.1`, `make ci-bridge-check`, apt, `make env`, artifact chỉ khi bước chạy xong và đã grep |
| Script chỉ chạy trên macOS | `deploy/k8s/gitops.sh` dòng 50; `Makefile` target `ci-tools`; đầu `deploy/k8s/drills/lib.sh` | `stat -f %Lp` (BSD); `ci-tools` từ chối khác `Linux x86_64`; drill viết cho bash 3.2 (chạy được trên bash 5) |
| Script cloud | `deploy/k6/cloud/run.sh`, `render.sh`; `deploy/k8s/cloud/velero/drill-restore.sh`; `deploy/k8s/cloud/values/` | `run.sh`, `drill-restore.sh` từ chối `k3d-*` và context rỗng trước mọi lệnh `kubectl`; `render.sh` không có tham số số pod; Chaos Mesh `socketPath: /run/containerd/containerd.sock`; Velero `deployNodeAgent: false`, `EnableCSI`, BSL S3 có `kmsKeyId` |
| Argo CD đọc repo | `deploy/k8s/gitops.sh` (`repo_url`, Secret `argocd/repo-short-video-platform`), `deploy/argocd/apps/values.yaml`, `deploy/argocd/project.yaml` | SSH `git@github.com:anhnvcoder/short-video-platform.git` bằng deploy key; cùng URL ở `sourceRepos` của AppProject `svp` |
| Metric rate limit | `services/gateway/internal/ratelimit/ratelimit.go` dòng 127–196; `internal/telemetry/telemetry.go` dòng 64 | `svp.ratelimit.decisions` (Prometheus `svp_ratelimit_decisions_total`), nhãn `class`, `result`, `store` (`redis`, `fallback`); `New` cộng 0 vào mọi series khi khởi động; quyết định của request đã huỷ không đếm `fallback`; xuất mỗi 15 s |
| Rule hiện tại | `deploy/observability/prometheus/rules/svp-alerts.yaml` dòng 48–58 | `sum(increase(...{store="fallback"}[1m])) > 0` (cộng nhánh `unless ... offset 1m`), không `for`, `severity: page` |
| Cảnh báo code scanning mở | `gh api 'repos/anhnvcoder/short-video-platform/code-scanning/alerts?state=open&per_page=100'` | 19: 18 của `trivy-config` (3 high: KSV-0053, KSV-0056 ở `cnpg-rbac.yaml`, DS-0002 ở `deploy/ci/drill/vulnerable.Dockerfile`; 9 medium; 6 low) và 1 CVE của stdlib Go 1.27.2 |
| Quy tắc tệp bỏ qua | `deploy/ci/scan-gate.sh` (`check_ignorefile`); ADR-0015 §6 | `.trivyignore.yaml` chỉ `vulnerabilities`, mỗi mục `id`, `statement`, `expired_at` ≤ 30 ngày, `purls`/`paths`; khoá gốc khác bị từ chối |
| Chu kỳ phân tích Argo CD, quyền GitOps | ADR-0014 §12; ADR-0015 §9 | Poll 60 s, jitter 0; `gitops.sh` đọc values ở `refs/remotes/origin/<nhánh>` như lần fetch cuối, không fetch |

## Tên chốt

Code, cấu hình và tài liệu dùng đúng các tên này; đổi tên nào thì sửa ADR này trước.

| Nhóm | Tên | Giá trị, ý nghĩa |
| --- | --- | --- |
| Workflow | `.github/workflows/verify.yml`, `name: verify` | `workflow_dispatch` và `schedule` hằng tuần trên `main` (mục 3, lịch thêm 2026-10-25) |
| Workflow | Input `scenario` (`type: choice`) | Phần 1: `compose-obs`, `dev-k3d`. Phần 3 thêm: `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero`. Ngoài nó chỉ có `targets` |
| Workflow | Input `targets` (`type: string`, mặc định rỗng) | Tên bước của kịch bản cách bằng khoảng trắng, rỗng là mọi bước; vào `verify-run.sh` qua `SVP_VERIFY_TARGETS` (mục 3, sửa 2026-10-25) |
| Workflow | Job | `compose` (kịch bản `compose-obs`), `k3d` (mọi kịch bản k3d trừ `gitops`), `gitops` (phần 3); mỗi lượt dispatch chạy đúng một job, hai job kia `skipped`; lượt `schedule` chạy `compose` (`compose-obs`) và `k3d` (`dev-k3d`) song song |
| Workflow | Runner | `ubuntu-24.04` (amd64) cho cả ba job |
| Workflow | `concurrency` | group `verify-<kịch bản>` (lượt `schedule`: `verify-schedule`), `cancel-in-progress: false` (mục 3, sửa 2026-10-25) |
| Script | `deploy/ci/verify-host.sh` | Kiểm và chuẩn bị máy: cổng đĩa, `/etc/hosts`, độ lệch version kubectl, `sch_netem`, hạn chế AppArmor của user namespace cho sandbox của Chrome ở `compose-obs` (mục 2, 3) |
| Script | `deploy/ci/verify-run.sh <kịch bản>` | Trình tự target `make` của kịch bản, mỗi target có hạn riêng (mục 3, 5); dừng sớm khi bước dựng đỏ, chỉ chạy các bước `SVP_VERIFY_TARGETS` chọn (mục 3); chạy được cả trên VM của B |
| Script | `deploy/ci/verify-sample.sh start\|stop\|peak` | Lấy mẫu nền: RAM, đĩa, CPU của máy, `docker stats` và `memory.stat` của node k3d, số pod media-worker đang transcode, trạng thái node; `peak` tính RAM đỉnh cho bước `ram-peak` (mục 2) |
| Script | `deploy/ci/verify-mask.sh env\|cluster` | `::add-mask::` cho giá trị bí mật của `.env` hay của Secret trong cluster (mục 4) |
| Script | `deploy/ci/verify-collect.sh` | Gom file theo danh sách cho phép, quét giá trị và mẫu, bỏ file nghi (mục 4) |
| Thư mục kết quả | `$RUNNER_TEMP/verify/` (biến `SVP_VERIFY_OUT`) | Mẫu, bảng, JSON trước khi lọc; không bao giờ upload nguyên thư mục |
| Artifact | `verify-<kịch bản>` | Chỉ thư mục do `verify-collect.sh` dựng; `retention-days: 30` |
| Máy | Dòng `/etc/hosts` | `127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost` |
| Chặn tai nạn | Điều kiện mở `run.sh`, `drill-restore.sh` trên k3d | `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, `uname -s` là `Linux`, context đúng `k3d-svp` (mục 7) |
| Phần 3 | Thư mục phủ chỉ cho runner | `deploy/k8s/cloud/runner/`: values Chaos Mesh, Velero, BackupStorageLocation, VolumeSnapshotClass của driver CSI hostpath (mục 7) |
| Phần 3 | Velero trên runner | Bucket `velero`, user object store `svp-velero` (quyền chỉ bucket đó), Secret `velero/velero-s3` |
| Phần 3 | Source map image CI | Artifact `web-sourcemaps-<arch>` của job build trong `images.yml` (mục 6) |
| Phần 3 | k6 thu nhỏ | Mức 1, 2, 4, 8 pod của profile `cloud`, mỗi pod đúng phần tải của thiết kế 20 pod (mục 8) |
| CI | `deploy/ci/trivy-config-ignore.yaml` | Bỏ qua có hạn cho misconfig của `trivy-config` (mục 9) |
| CI | `make web-lockfile-scan` | trivy `fs` trên `web/pnpm-lock.yaml`, cổng CRITICAL; SARIF category `trivy-lockfile-web` (mục 10) |
| Cảnh báo | `RateLimitFallbackActive` (page), `RateLimitFallbackElevated` (ticket) | Điều kiện ở mục 11 |

## 1. Nơi chạy và loại runner

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Runner chuẩn của repo public, workflow `workflow_dispatch`** | Miễn phí; mỗi job một VM mới, sạch; cùng image với job `stack` và mọi job CI; AI dispatch và đọc kết quả bằng `gh`, không chạm tài khoản cloud nào | 4 vCPU (nửa Docker VM 8 vCPU của máy), 14 GB SSD công bố, tối đa 6 giờ mỗi job; log và artifact công khai; chạy code của ref được dispatch |
| B. VM thuê theo giờ | CPU, RAM, đĩa chọn được; không giới hạn 6 giờ | Tốn tiền; người học dựng, chạy, xoá; không có công cụ sẵn; kết quả chép tay về |
| Runner lớn của GitHub | Nhiều CPU, vẫn trong Actions | Cần gói trả phí của tổ chức (chưa xác nhận cho repo của tài khoản cá nhân); ngoài lựa chọn người học đã chốt |
| Runner self-hosted trên máy | Không tốn tiền | Máy 16 GB chính là thứ thiếu; runner self-hosted gắn repo public chạy code của ref được dispatch trên máy cá nhân |
| **`ubuntu-24.04` (amd64)** | `make ci-tools` chạy được (Helm linux-amd64 ghim sha256); Playwright Chromium và WebKit đã chạy ở job `stack`; mọi image phát hành có `linux/amd64` | Khác kiến trúc máy (arm64): image dev build amd64, số RAM và thời gian không thay số của máy |
| `ubuntu-24.04-arm` | Cùng kiến trúc máy và image dev | `make ci-tools` từ chối (cần ghim thêm sha256 Helm linux-arm64); Playwright WebKit trên Linux arm64 chưa từng chạy trong repo |

### Quyết định

- **A cho mọi kịch bản.** B chỉ cho một dòng cụ thể khi kịch bản của nó trượt tiêu chí "runner đủ" (mục 2) **hai lượt liền vì tài
  nguyên** (lượt đầu trượt có thể do hàng xóm ồn, nên chạy lại một lần trước), ghi lý do vào mục Kết quả.
- **Runner `ubuntu-24.04` amd64**, ghi rõ label, không `ubuntu-latest`. Lý do: công cụ CI ghim cho amd64 và job `stack` đã chứng minh
  đường compose, Playwright trên amd64. Mọi image phát hành là index đa kiến trúc nên cluster GitOps trên runner kéo chân amd64
  của đúng digest đã ký. Cái giá: số đo trên runner là số của amd64, không thay số của máy (mục 2, "Số nào so được").
- **Ngoại lệ arm64:** nếu RAM nghỉ (b) của một cluster đo trên amd64 nằm trong khoảng ±0,3 GiB quanh 6,5 GiB (kết luận có thể đổi
  theo kiến trúc), chạy thêm một lượt `dev-k3d` trên `ubuntu-24.04-arm` để so; khi đó ghim thêm sha256 Helm linux-arm64 cạnh
  `HELM_LINUX_AMD64_SHA256` và cho `ci-tools` nhận `Linux aarch64`.
- **B khi cần:** Ubuntu 24.04 amd64, ít nhất 8 vCPU, 32 GB RAM, 100 GB SSD, nhà cung cấp do người học chọn. Người học cài các công
  cụ như các bước setup của `verify.yml`, chạy `deploy/ci/verify-run.sh <kịch bản>`, rồi `deploy/ci/verify-collect.sh` (cùng bộ
  lọc của mục 4), chép thư mục đã lọc về; xoá VM trong ngày, ghi chi phí vào Kết quả. AI soạn lệnh, không chạy lệnh nào chạm nhà
  cung cấp; nhà cung cấp là AWS hay GCP thì theo mục An toàn cloud của `CLAUDE.md` (kiểm account trước lệnh ghi, lệnh destroy và
  quét tài nguyên sót).

## 2. Tiêu chí "runner đủ": đĩa, RAM, CPU, thời gian

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| "Đủ" là kịch bản xanh | Không cần đo thêm | Không tách được lỗi của code với lỗi vì runner thiếu tài nguyên; B không có điều kiện mở |
| **Tiêu chí đo được viết trước cho mỗi kịch bản, lấy mẫu nền suốt lượt chạy** | Biết lượt đỏ vì runner hay vì code; điều kiện sang B rõ ràng | Thêm sampler và một bảng cần đọc ở mỗi lượt |
| Dọn đĩa ở mọi lượt | Luôn đủ chỗ | Mất 1–3 phút mỗi lượt khi không cần; xoá cả thứ có thể dùng |
| **Đo đĩa trước, dọn khi thiếu, thiếu sau khi dọn thì dừng** | Chỉ trả giá khi cần; thất bại ở bước đo đĩa, không ở giữa diễn tập | Cần ước lượng chỗ cần trước lượt đầu |

### Quyết định

- **Đĩa** (`verify-host.sh`, trước mọi target `make`): đo `df -B1` của hệ thống tệp chứa thư mục dữ liệu của Docker
  (`docker info -f '{{.DockerRootDir}}'`) và in kèm `docker system df`. Cần trống ít nhất `need + 15% dung lượng + 2 GiB`:
  `need` là ước lượng dùng thêm của kịch bản (**16 GiB** cho `compose-obs`: 1,25 × 12,7 GiB đo ở lượt đầu, ước lượng trước đó
  15 GiB; **30 GiB** cho kịch bản k3d: build cache bảy image, image của khoảng 40 container bên thứ ba trong kho containerd của hai
  node, PV, trình duyệt Playwright), 15% là khoảng dưới ngưỡng dọn image mặc định của kubelet (`imageGCHighThresholdPercent` 85, chưa đọc lại cấu hình k3s). Thiếu thì xoá các bộ công cụ cài sẵn mà
  repo không dùng (`/usr/local/lib/android`, `/usr/share/dotnet`, `/opt/ghc`, `/usr/local/.ghcup`, `/opt/hostedtoolcache/CodeQL`;
  không đụng Go, Node trong `hostedtoolcache` mà `setup-go`, `setup-node` dùng), đo lại; vẫn thiếu thì dừng với số đo, trước mọi
  build. Lượt đầu của mỗi kịch bản ghi mức dùng thật; `need` đổi thành 1,25 × mức dùng cao nhất đo được.
- **Đĩa trong lúc chạy:** sampler ghi chỗ trống mỗi 30 s; xuống dưới `15% + 1 GiB` thì ghi dấu, `verify-run.sh` dừng kịch bản ở
  target kế với lý do "disk", không để kubelet evict pod giữa diễn tập rồi báo một lỗi xa nguyên nhân.
- **RAM:** Linux chạy Docker native, không có Docker VM: node k3d là container trên chính máy runner 16 GB, nên RAM của cluster
  đo được như trên máy (cùng cgroup v2) nhưng giới hạn khác (16 GB của runner trừ OS, runner agent và dockerd, thay 9,7 GiB của
  VM). Đo:
  - **Ngân sách của cluster** theo đúng cách ADR-0014 §2 (sửa 2026-10-20) và ADR-0017 điểm 5: tổng MEM USAGE của
    `docker stats --no-stream` cho `k3d-svp-*` và `k3d-svp-registry`, 6 mẫu cách 10 s lấy trung vị; nghỉ là 60 s sau khi mọi pod
    Ready, đỉnh là 6 mẫu liền trong khi đủ `maxReplicaCount` (2) worker cùng transcode; cạnh đó `anon`, `active_file`, `kernel` của
    từng node từ `memory.stat`, tổng pod `kubectl --context k3d-svp top pods -A` theo namespace và `kubectl top node`. Thêm một lần
    đo nghỉ cuối kịch bản (sau mọi diễn tập) để thấy hiệu ứng "(b) chỉ đạt sau 70–90 phút" của máy có lặp lại không.
  - **Đếm worker đang transcode** (sửa 2026-10-25, sau lượt `dev-k3d` 5): ở mỗi mẫu 10 s, sampler đếm pod media-worker `Running` có
    tiến trình `ffmpeg` trong cgroup của pod (`/proc/<pid>/cgroup` trên máy runner chứa UID của pod); media-worker chỉ chạy `ffmpeg`
    khi transcode. Trước đó bước `ram-peak` coi hai pod `Running` là hai worker cùng transcode, nên ở lượt 5 cửa sổ đỉnh rơi vào
    lúc chỉ một pod transcode (pod kia chờ partition). Không chọn CPU của `kubectl top` vượt một ngưỡng: số đó là trung bình qua một
    chu kỳ của metrics-server, nên trễ một hai mẫu ở hai đầu cửa sổ, và cần một ngưỡng tự đặt; tiến trình `ffmpeg` đúng ở từng mẫu,
    và `ffmpeg` mà diễn tập chạy trên chính máy runner để sinh video thử không nằm trong pod nào. Sampler cũng ghi `anon`,
    `active_file`, `kernel` của hai node (cộng lại) ở mỗi mẫu, nên `ram-peak` có thêm trung vị MEM USAGE trừ `active_file` của cùng
    cửa sổ đỉnh.
  - **Máy runner:** `MemAvailable` và swap đang dùng (`/proc/meminfo`) mỗi 5 s, `free -m` lúc đầu và lúc đo nghỉ, `swapon --show`
    lúc đầu (tài liệu không nói runner có swap), container nào `OOMKilled` (`docker inspect`) và dòng OOM của kernel (`sudo dmesg`).
- **Trả lời "RAM (b)" của giai đoạn 5** (quy tắc viết trước), áp riêng cho từng đường ở điểm đo 60 s; kết luận chỉ đúng cho đường
  đã đo. "Còn mở: RAM (b)" của roadmap và ADR-0017 là của **đường GitOps** (Argo CD, image GHCR): chỉ kịch bản `gitops` (phần 3) đóng
  được nó. `dev-k3d` (phần 1) đạt hay trượt chỉ kết luận cho đường dev, không đóng dòng đó.
  - MEM USAGE trừ `active_file` của các node dưới 6,5 GiB và tổng pod không vượt 4,7 GiB: (b) đạt trên runner cho đường đó; chỗ
    thiếu ở máy là của Docker VM (swap, áp lực bộ nhớ của macOS), không cắt gì ở đường đó; số đo trên máy vẫn để nguyên trong
    ADR-0015/0017, số của runner ghi cạnh.
  - Trên 6,5 GiB: cluster thật sự vượt ngân sách; theo ADR-0014 §2 và điểm 2 của ADR-0017 thiếu (b) thì cắt theo thứ tự cũ.
    Người học quyết cắt (việc riêng, đo lại trên runner) hay ghi nhận như (c); ADR này không quyết trước.
- **CPU:** runner có 4 vCPU, trong khi một media-worker giới hạn 2 CPU (FF-3): hai worker cùng transcode giữ trọn 4 vCPU, chưa kể
  k3s, Envoy, Prometheus. Máy đã chết với 3 worker trên 8 vCPU (6/8); trên runner 2 worker là 4/4. Vì vậy runner **không** phải
  "node đủ CPU" của ADR-0020 §9 theo nghĩa đen: PASS trên runner là bằng chứng mạnh (k3s đứng được khi CPU bão hoà), FAIL (c) trên
  runner không nói thêm gì về thiết kế, và dòng đó sang B (VM 8 vCPU, như Docker VM của máy) theo quy tắc ở trên. Sampler ghi
  `/proc/stat` bận theo phần trăm mỗi 5 s và CPU của container node theo `docker stats`; không dùng PSI làm bằng chứng nghẽn (giai
  đoạn 5 thấy PSI không đáng tin trong VM).
- **Thời gian:** job `compose` 120 phút, `k3d` và `gitops` 330 phút (dưới hạn 6 giờ của GitHub 30 phút). Trước bước kịch bản là
  các bước setup (công cụ, apt, Playwright `--with-deps`, dọn đĩa khi cần: ước lượng 10–15 phút), nên ngân sách setup là **20 phút**
  và bước kịch bản có `timeout-minutes` bằng hạn job trừ 20 phút setup trừ 25 phút cho các bước sau (`compose` 75 phút, `k3d`,
  `gitops` 285 phút). Bước đầu của job ghi thời điểm bắt đầu job vào `$SVP_VERIFY_OUT`; `verify-run.sh` chạy mỗi target `make` dưới
  `timeout` riêng (ví dụ `make k8s-up` 60 phút, mỗi diễn tập 30 phút, chờ bản phát hành 90 phút) nhưng không quá mốc "bắt đầu job +
  hạn job − 25 phút", và không bắt đầu target mới khi đã qua mốc đó. Như vậy setup chậm hơn ước lượng chỉ làm kịch bản ngắn lại, một
  target treo làm đỏ đúng target đó, và các bước gom, lọc, tải artifact (`if: always()`) luôn còn 25 phút; hạn 6 giờ của GitHub không
  bao giờ là thứ cắt job. Lượt đầu mỗi kịch bản ghi thời gian setup thật; quá 20 phút thì sửa ngân sách ở đây.

**Bảng "runner đủ"** (mọi điều phải đạt; không đạt vì tài nguyên hai lượt liền thì dòng đó sang B):

| Kịch bản | Đủ khi |
| --- | --- |
| Mọi kịch bản | Cổng đĩa đạt; job xong trong hạn bước; `MemAvailable` thấp nhất ≥ 2 GiB; không container nào `OOMKilled`, kernel không ghi OOM; chỗ trống thấp nhất ≥ ngưỡng chạy ở trên |
| `compose-obs` | Thêm: không container nào của project restart ngoài các lần diễn tập chủ động dựng lại |
| Kịch bản k3d | Thêm: container `k3d-svp-server-0` giữ nguyên `RestartCount` và `State.StartedAt` suốt kịch bản (tiêu chí (c) của ADR-0017, mở rộng từ `drill-k8s-keda` ra cả kịch bản); không node nào `NotReady` ở mẫu nào (sampler đọc `kubectl get nodes` mỗi 10 s); không event `Evicted`, `EvictionThresholdMet`, `FreeDiskSpaceFailed` |
| `gitops` (KEDA) | Thêm: mỗi lượt `drill-k8s-keda` có cửa sổ ít nhất 6 mẫu liền 2 worker cùng transcode |
| `k6-cloud-mini`, `chaos` | Thêm: pod k6 không bị throttle CPU quá 5% chu kỳ ở mức được tính (mục 8): k6 thiếu CPU thì `dropped_iterations` là giới hạn của runner, không của hệ thống |

**Số nào so được với máy:**

| Loại số | So được không | Vì sao, cách ghi |
| --- | --- | --- |
| Kết quả đúng/sai của diễn tập (threats, supplychain, giả thuyết chaos, offset sau restore, canary promote/abort) | Có | Logic không phụ thuộc máy |
| RAM của cluster theo cách ADR-0014 §2 | So với **ngân sách** (6,5 / 8,7 GiB, 4,7 GiB pod), không so như số thay cho máy | Cùng cách đo, khác kiến trúc (amd64) và khác hệ điều hành chủ (không VM, không áp lực bộ nhớ của macOS); ghi cạnh số của máy, không xoá số cũ |
| Thời gian (`k8s-up`, RTO, mốc canary, scale KEDA, tới `READY`) | Không | 4 vCPU amd64, cache lạnh mỗi lượt; ghi là số của runner |
| Độ trễ dưới tải (k6 p95/p99) | Không với máy; chỉ dùng trong quy tắc của mục 8 | Ghi kèm điều kiện runner |
| LCP Lighthouse (Lantern mô phỏng) | So với ngưỡng 2 500 ms | Ghi kèm `benchmarkIndex` của báo cáo |

## 3. Workflow `verify.yml`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Thêm job vào `ci.yml` (theo lịch hay dispatch) | Không thêm file | Trộn kiểm của mỗi PR với buổi đo dài; trigger, concurrency, quyền khác hẳn |
| **Workflow thứ ba, chỉ `workflow_dispatch`** | Chỉ người có quyền ghi chạy được; không bao giờ chạy code của PR fork; tách hẳn khỏi `ci-ok`, `images-ok` | Thêm một file ngoài hai workflow của ADR-0015 §1 (kèm quy ước của nó) |
| **Mỗi lượt một kịch bản, mỗi nhóm kịch bản một job** (`compose`, `k3d`, `gitops`) | Runner mới cho mỗi kịch bản; service container chỉ ở job compose; quyền `actions: read` chỉ ở job `gitops` | Kịch bản dùng chung bước setup phải khai ở nhiều job |
| Mọi kịch bản trong một job, bước theo điều kiện | Một định nghĩa | Service container (job-level) dựng cả khi không cần; quyền lớn nhất cho mọi kịch bản |
| Matrix nhiều kịch bản một lượt | Chạy song song | Nhiều kết quả cùng lúc cho một người đọc; lỗi chung (script chưa chạy được trên Linux) lặp ở mọi chân |
| `concurrency` một lượt mỗi lúc (chọn lúc đầu) | Lỗi chung sửa xong trước lượt kế; không hai lượt cùng chờ một bản phát hành | Không song song; dispatch lượt thứ ba khi đã có một lượt chạy và một lượt chờ thì lượt chờ bị huỷ (cách GitHub giữ hàng chờ) |
| **Group theo kịch bản** (sửa 2026-10-25) | Kịch bản khác nhau chạy song song, cùng kịch bản vẫn tuần tự (vẫn chỉ một lượt `gitops` chờ bản phát hành) | Lỗi chung của hai kịch bản đỏ ở cả hai lượt; hàng chờ như trên, theo từng kịch bản |
| **Thêm lịch hằng tuần trên `main`, hai kịch bản phần 1 song song, mọi bước** (người học chốt 2026-10-25) | Hồi quy mỗi tuần mà không cần ai dispatch: bắt được thứ trôi theo thời gian (image runner, image bên thứ ba, bản Renovate đã merge) trước khi giai đoạn sau cần số đo; miễn phí như mọi lượt của repo public | Hai lượt mỗi tuần dù không ai đọc, log và artifact công khai thêm (cùng bộ lọc); GitHub có thể trễ hay bỏ lượt lúc tải cao và tắt lịch sau 60 ngày repo không hoạt động; chỉ kiểm được sau khi merge vào `main` |
| Environment được bảo vệ cho mọi job | Có người duyệt trước khi chạy | Không có secret nào cần bảo vệ (mục 6); thêm bước duyệt mà không bớt rủi ro nào |

### Quyết định

- **Trigger** `workflow_dispatch`, input `scenario` (`type: choice`, danh sách ở Tên chốt) và, từ 2026-10-25, `targets` (dưới
  đây), không input nào khác: tham số của kịch bản nằm trong `verify-run.sh`, review được như code. Input chỉ vào script qua `env:`
  (`SCENARIO: ${{ inputs.scenario }}`, `SVP_VERIFY_TARGETS: ${{ inputs.targets }}`), `verify-run.sh` kiểm lại giá trị bằng `case`;
  `if:` của job so `inputs.scenario` (biểu thức, không vào shell).
- **Lịch hằng tuần** (thêm 2026-10-25): `schedule` `cron: "37 0 * * 6"`, tức 00:37 UTC thứ Bảy, 07:37 giờ Việt Nam (cron của GitHub
  tính theo UTC; phút lệch khỏi đầu giờ vì GitHub nói lượt lịch có thể trễ, thậm chí bị bỏ khi tải cao, "High load times include the
  start of every hour"). Lượt lịch chạy cả hai kịch bản phần 1 song song, mọi bước, cùng quyền, cùng bộ lọc artifact như lượt
  dispatch. Lượt lịch không có `inputs`, nên `if:` của `compose` và `k3d` đúng khi `github.event_name == 'schedule'`, `SCENARIO`
  của mỗi job là `inputs.scenario || '<kịch bản của job>'` và `SVP_VERIFY_TARGETS` rỗng. Không dùng matrix: hai kịch bản vốn là hai
  job (chỉ `compose` có service container), lượt lịch bật cả hai nên chúng chạy song song trên hai runner, mỗi job một artifact
  `verify-<kịch bản>`. Theo tài liệu GitHub (đọc ngày 2026-10-25,
  <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows>, mục `schedule`): lượt lịch
  "run on the latest commit on the default branch", `GITHUB_REF` là nhánh mặc định; "In a public repository, scheduled workflows
  are automatically disabled when no repository activity has occurred in 60 days" (bật lại ở tab Actions). Lượt lịch chỉ kiểm được
  sau khi `verify.yml` có lịch đã merge vào `main` (**kiểm sau push**).
- **Ref:** bước đầu của mỗi job dừng (exit 1, nêu lý do) khi `GITHUB_REF` không phải `refs/heads/main` hay `refs/heads/feat/stage6b-*`
  (lượt `schedule`: chỉ `refs/heads/main`).
  Đây là chặn tai nạn (dispatch nhầm nhánh cũ), không phải ranh giới bảo mật: ai có quyền ghi đẩy được nhánh có `verify.yml` của
  chính họ (cùng mức tin như SC-8). Ranh giới là không secret và token chỉ đọc.
- **Thứ tự:** `workflow_dispatch` chỉ chạy khi file có trên nhánh mặc định, nên PR đưa `verify.yml` vào `main` (đủ `ci-ok`,
  `images-ok`) merge **trước** lượt dispatch đầu; sau đó dispatch được với `--ref main` hay nhánh `feat/stage6b-*` (chạy bản file và
  code của nhánh đó). AI dispatch (`gh workflow run verify.yml --ref <nhánh> -f scenario=<tên>`) và đọc kết quả (`gh run view`,
  `gh run download`) từng lượt; lượt kế của một kịch bản chỉ dispatch khi lượt trước của nó đã xong.
- **Quyền:** `permissions: {}` đầu file; `compose`, `k3d`: `contents: read`; `gitops`: `contents: read`, `actions: read` (tải artifact
  source map của lượt `images.yml`, mục 6). Không secret, không environment. `GH_TOKEN: ${{ github.token }}` chỉ ở bước gọi `gh`
  (job `gitops`). Mọi action ghim SHA như ADR-0015 §1 (`checkout`, `setup-go`, `setup-node`, `cache`, `upload-artifact`,
  `download-artifact` đã ghim trong repo); `persist-credentials: false`; không `pull_request_target`, `workflow_run`.
- **`concurrency: { group: verify-${{ inputs.scenario || github.event_name }}, cancel-in-progress: false }`** (sửa 2026-10-25;
  trước đó group `verify` chung): mỗi lượt có runner riêng, nên hai kịch bản không tranh tài nguyên; lỗi chung của hai kịch bản
  (script chưa chạy trên Linux) đã sửa qua các lượt đầu của phần 1, và giữ tuần tự chỉ còn bắt `dev-k3d` chờ `compose-obs` (và ngược
  lại) trong khi sửa từng lỗi. Lượt lịch là group `verify-schedule`: lượt dispatch trong lúc nó chạy vẫn chạy song song, trên runner
  riêng.
- **Dừng sớm và chọn bước** (sửa 2026-10-25): lượt `dev-k3d` 1–3 đỏ ở `k8s-up` vẫn chạy mười ba bước sau cho tới khi đỏ theo (hai
  bước RAM nghỉ chờ đủ 900 s), mỗi lượt phí 30–40 phút; lượt chỉ để xem `drill-k8s-threats` vẫn chạy đủ 14 bước (khoảng 80 phút).
  - Bước dựng (`up` của `compose-obs`, `k8s-up` của `dev-k3d`) không `ok` thì mọi bước sau ghi `skipped` với note
    `infrastructure step failed`, không chạy, không chờ; các bước gom, lọc, tải vẫn chạy. Tiêu chí `within_deadline` chỉ tính bước
    `timeout`, `cancelled` và `skipped` vì `deadline`, nên các bước đó không làm runner "thiếu".
  - Input `targets` (rỗng là mọi bước) chọn bước để chạy: bước dựng luôn chạy; bước không được chọn ghi `skipped` với note
    `not in targets`, không làm lượt đỏ, giữ số thứ tự (tên log như mọi lượt). Tên không thuộc danh sách bước của kịch bản (danh
    sách sinh từ chính trình tự của `verify-run.sh`) hay ký tự ngoài `a-z`, `0-9`, `-`, khoảng trắng thì `verify-run.sh` dừng
    (exit 2) trước khi dựng gì; chuỗi có ký tự lạ không được in lại vào log.
  - Bước đọc kết quả của bước khác phải được chọn cùng nó: `ram-peak` cần `drill-k8s-keda` (thiếu thì `skipped`, lượt đỏ);
    `drill-k8s-threats` và `load-local` cần video `READY` của `k8s-smoke`/`smoke`, `lcp` cần `web-lighthouse-<n>`, `drill-k8s-web-obs`
    cần `k8s-web-e2e`. Bước đo RAM chỉ chạy khi được chọn (hay khi `targets` rỗng). Lượt chọn bước chỉ cho kết quả của các bước đó:
    số RAM và "runner đủ" của nó không thay lượt đủ kịch bản.
- **Job `compose`** theo mẫu job `stack`: cùng service container Postgres/Redis (image ghim, publish trên `127.0.0.1` và `172.17.0.1`),
  `make ci-bridge-check`, `setup-go`, Node theo `web/.nvmrc` và pnpm theo `packageManager`, apt `postgresql-client redis-tools ffmpeg
  jq`, `make web-install` và `pnpm exec playwright install --with-deps chromium` (trong `web/`, như job `stack`: `make web-lighthouse`
  của `compose-obs` cần `lhci` trong `web/node_modules` và Chromium của Playwright, `web/lighthouse/run.sh` dừng ngay khi thiếu một
  trong hai; không target nào của kịch bản tự cài chúng, và `compose-obs` không chạy e2e nên không cần WebKit), `make env`, rồi
  `verify-host.sh` (ở `compose-obs` còn đặt `kernel.apparmor_restrict_unprivileged_userns=0`: Ubuntu 24.04 chặn user namespace
  không đặc quyền với binary không có profile AppArmor, Chromium tải về của Playwright không có, nên Lighthouse mở Chrome với sandbox
  thì Chrome dừng "No usable sandbox"; bỏ hạn chế trên VM dùng một lần, vốn đã có root qua `sudo`, giữ được sandbox của Chrome, thay
  vì tắt sandbox bằng `--no-sandbox`; e2e của Playwright tự tắt sandbox nên không cần), `verify-mask.sh env`, `verify-sample.sh start`, `verify-run.sh "$SCENARIO"` (gọi lại
  `verify-mask.sh env` sau mỗi target, mục 4), và các bước `if: always()`: `verify-sample.sh stop`, `verify-collect.sh`,
  `upload-artifact`.
- **Job `k3d`, `gitops`:** không service container (Postgres, Redis của cluster nằm trong cluster). Bước: `checkout` (`gitops`:
  `fetch-depth: 0`, vì `gitops.sh` đọc `refs/remotes/origin/main` và `measure-gitops` đọc commit cha), `setup-go`, cache GOBIN như
  job `config` rồi `make tools ci-tools` (k3d, Helm, buf ghim), Node/pnpm, `make web-install` và `pnpm exec playwright install
  --with-deps chromium webkit` (e2e web), apt `ffmpeg jq`, kubectl của image runner (1.37.1; `verify-host.sh` dừng khi lệch quá một
  minor so với k3s 1.36 của `K3S_IMAGE_TAG`, theo chính sách lệch version của kubectl), `make env`, `verify-host.sh` (cổng đĩa, ghi ba
  tên vào `/etc/hosts` rồi kiểm `getent ahosts` của mỗi tên chỉ trả `127.0.0.1`, dừng nếu khác, trước `make k8s-up`: một lượt hỏng vì
  DNS tốn khoảng một giờ), `verify-mask.sh env`, sampler, `verify-run.sh`; sau khi cluster lên, `verify-run.sh` gọi
  `verify-mask.sh cluster`; các bước `if: always()` như job `compose`.
- **Không dọn gì ngoài runner:** mọi thứ kịch bản tạo (cluster, stack, volume, Chaos Mesh, Velero) nằm trên VM của runner, bị huỷ
  cùng job; không tài nguyên nào ở ngoài cần quét. Kịch bản vẫn chạy lệnh gỡ của buổi cloud (Chaos Mesh, Velero) để diễn tập chính
  các lệnh đó (mục 7). Trước khi gom kết quả, `verify-sample.sh stop` và `verify-run.sh` dừng đúng pid tiến trình nền chúng đã ghi
  (sampler, traffic diễn tập) để file kết quả đủ.
- **Script macOS:** lệnh chỉ có ở macOS (BSD `stat -f`, `date -v`) gặp trên runner đổi sang dạng chạy được cả hai nơi; phần 1 sửa
  chỗ mà `dev-k3d` gặp và hai script GitOps (`gitops.sh`, `drills/gitops.sh`), phần còn lại theo lỗi của lượt chạy.
- **Docker Hub:** runner kéo ẩn danh. GitHub công bố giới hạn pull của Docker Hub không áp cho runner GitHub kéo image công khai
  (mục Kiểm chứng), và mọi image `docker.io` của repo là công khai, nên workflow không đếm pull và không có token Docker Hub. Pull
  từ containerd trong node k3d chưa được trang nào nói riêng: nếu một lượt gặp `429 Too Many Requests` (event `Failed` của kubelet,
  lỗi của `docker pull`), ghi vào Kết quả và xét lại trước lượt kế.

## 4. Log và artifact công khai

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Không artifact, chỉ log của job | Không thêm đường lộ | JSON của diễn tập, mẫu RAM phải in ra log (dài, khó đọc lại); log cũng công khai |
| Tải mọi thứ lên, tin script không in bí mật | Đủ chứng cứ | Trace, video, HAR, báo cáo HTML của Playwright mang cookie; một file sót là lộ vĩnh viễn |
| Mã hoá artifact bằng khoá của người học | Tải được cả thứ nhạy cảm | Cần secret trong workflow, đúng thứ phần này tránh; người học phải giải mã mỗi lần đọc |
| **Danh sách cho phép, quét theo giá trị bí mật đã biết và theo mẫu, file nghi thì bỏ (fail-closed)** | Chỉ thứ cần đọc lên artifact; lỗi của script in sót cũng bị chặn ở lớp thứ hai | Giá trị bị biến đổi (base64 lồng, URL-encode) có thể lọt; file hợp lệ có thể bị bỏ oan |
| **`::add-mask::` các giá trị bí mật ngay khi chúng có** | Lớp thứ hai cho log của job | Chỉ che dòng in sau lệnh, chỉ che đúng chuỗi; không phải biện pháp chính |

### Quyết định

- **Log của job công khai, kể cả khi đỏ:** biện pháp chính vẫn là script không in giá trị bí mật (quy ước đã có ở mọi target, drill
  tự dò log của chính nó). Trong `verify-*.sh` và các bước của `verify.yml`: không `set -x`, không `env`/`printenv`, không in `.env`,
  không `docker compose config` thiếu `--quiet`, không `kubectl get secret` ra stdout, không `make logs` hay `kubectl logs` của
  service vào log job (lỗi thì chỉ `make ps`, `make k8s-status`, `kubectl get events`: trạng thái, không nội dung; ngoại lệ duy nhất
  là đuôi log của container hạ tầng bên thứ ba, theo luật ở dưới). Giá trị đọc vào
  biến rồi chuyền qua stdin hay file mode 600 trong `$RUNNER_TEMP`, như `secrets.sh` đã làm.
- **Mask:** `verify-mask.sh env` ngay sau `make env`: `::add-mask::` cho giá trị của mọi biến trong `.env` có tên kết thúc bằng
  `PASSWORD`, `SECRET`, `SECRET_KEY`, `TOKEN`, `_KEY`, `_KEYS` hay là `SENTRY_DSN`, độ dài ≥ 8 (che giá trị ngắn hay không bí mật như
  `svp`, `admin@svp.local` sẽ làm log không đọc được). `.env` còn được ghi thêm giữa kịch bản (`make up OBS=lgtm` gọi
  `make glitchtip-init`, thêm `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_SOURCEMAPS_TOKEN`), nên `verify-run.sh` gọi lại
  `verify-mask.sh env` ngay sau **mỗi** target `make` (mask lại một giá trị đã che là vô hại); giá trị do target thêm được che từ
  target kế, còn trong chính target đó chỉ quy ước không in che. `verify-mask.sh cluster` sau khi cluster lên và trước khi gom: mỗi giá trị
  (và mỗi dòng của giá trị nhiều dòng) ≥ 8 ký tự của mọi Secret trong `svp`, `svp-data`, `svp-obs`, `argocd`, `velero`. Lệnh mask
  không bao giờ được in lại (không `set -x`).
- **Danh sách cho phép** (`verify-collect.sh`, chép vào `$RUNNER_TEMP/verify-artifact/`): đầu ra của mỗi target
  `logs/NN-<target>.log` sau khi bỏ các dòng log theo luật ở dưới (của hai diễn tập threat model chỉ giữ dòng phán quyết), JSON và
  bảng của `.k8s/drills/*.json`,
  `.k8s/drills/traffic-*.log` (mỗi dòng chỉ có thời điểm, `u1`…`u4`/`web`, tên route, mã HTTP, mili giây), `.k6/*/summary.json`,
  JSON kết quả của `web/test-results/` mà target đo ghi (`measure-*`, `glitchtip-*.json`), báo cáo Lighthouse đã lọc cookie
  (`web/test-results/lighthouse/*.json`, `*.html`, như job `stack`), mẫu của sampler, bảng RAM, đầu ra `make k8s-status` và `kubectl
  get events -A` lúc cuối, `df` trước/sau. Mỗi file tối đa 5 MiB.
- **Cấm, dù script nào ghi ra:** `.env`, kubeconfig, `.k8s/ca.*`, `.k8s/helm/`, `.k8s/drills/threats-*.log` (nội dung thăm dò),
  trace, video, ảnh, HAR, báo cáo HTML của Playwright, `machine.json` của k6, thư mục ẩn, mọi log của service.
- **Dòng log trong đầu ra của target, một luật cho artifact và log job** (log job chỉ nhận 40 dòng cuối của target đỏ lấy từ bản đã
  lọc trong artifact, nên cái gì artifact giữ thì log job in được, không hơn). `verify-collect.sh` bỏ mọi dòng của bản ghi log JSON
  (khoá `"msg"`, `"level"`: slog của service và phần lớn server bên thứ ba) và mọi dòng trích access log (`access log of trace`).
  Sau một release không Ready, `make k8s-up` in trạng thái mỗi container chưa Ready (lý do, mã thoát), và chỉ với container hạ tầng
  bên thứ ba thì in thêm 40 dòng cuối của log, của lần chạy trước khi đã restart (`unready_report` của `deploy/k8s/lib.sh`), mỗi
  dòng dạng `    [<namespace>] <dòng>`; log của Job migrate thất bại cũng in theo dạng đó. `verify-collect.sh` chỉ giữ dòng có
  dấu đó khi namespace nằm trong `log_tail_namespaces` của `deploy/k8s/lib.sh` (đọc từ chính file đó, không đọc được thì bỏ mọi dòng
  có dấu). Lý do: lỗi của Redpanda ở lượt `dev-k3d` 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975),
  `Could not initialize seastar: std::runtime_error (insufficient physical memory …)`) chỉ thấy được qua log của broker; Helm chỉ
  báo `1 pods have failed`, còn cluster bị huỷ cùng runner. Quét giá trị bí mật chỉ khớp **nguyên** giá trị (không khớp mảnh), nên
  phạm vi là danh sách namespace và loại trừ có lý do, không phải tin vào phép quét:

  | Namespace | Log được in | Bị loại, lý do |
  | --- | --- | --- |
  | `svp-data` | Redpanda (log text của seastar: kiểm hệ thống lúc khởi động, lỗi cấu hình, bộ nhớ), Valkey, MinIO, sidecar của chart, Job init | Mọi pod Postgres của CloudNativePG (nhãn `cnpg.io/cluster`): dòng lỗi trích câu lệnh thất bại, gồm cả giá trị |
  | `svp-obs` | Prometheus, Alertmanager, Grafana, Loki, Tempo, Pyroscope, Collector (logfmt hay console của zap, không exporter `debug`), operator của kube-prometheus-stack | GlitchTip (nhãn `app.kubernetes.io/name=glitchtip`): access log mang `sentry_key=` là khoá công khai của DSN, mà phép quét chỉ biết nguyên DSN; lỗi của nó có thể trích event nhận được |
  | `cnpg-system`, `keda`, `argo-rollouts`, `kyverno`, `cert-manager` | Operator và controller: lỗi reconcile, webhook, chứng chỉ (CloudNativePG, KEDA in JSON nên đã bị bỏ theo luật JSON) | — |
  | `svp` (7 service của project) | Không bao giờ: chỉ trạng thái, lý do, mã thoát, và `terminationMessage` khi `terminationMessagePolicy` là `File` (message của `FallbackToLogsOnError` là đuôi log nên không in) | Log của service có thể mang dữ liệu người dùng |
  | `envoy-gateway-system` | Không | Access log của proxy Envoy mang đường dẫn và query, gồm chữ ký của presigned upload |
  | `kube-system`, `argocd` và namespace khác | Không | Không cần cho chẩn đoán cài đặt; ngoài danh sách thì bỏ (fail-closed) |

  Log thật đã đọc: chỉ đuôi log của `redpanda-0` (cả hai lần chạy) và sidecar của nó ở lượt 2 nói trên; các dòng còn lại của bảng
  dựa trên định dạng log của từng server, chưa gặp lỗi thật. Mỗi file vẫn qua phép quét bên dưới như mọi file khác, khớp thì bỏ cả
  file. Trên máy người học (`make k8s-up`) cùng luật: không in log của service ở `svp` để một đường code duy nhất; riêng log của Job
  migrate thất bại vẫn hiện trên terminal (Helm xoá pod của nó), artifact bỏ vì là namespace `svp`.
- **Quét trước khi chép mỗi file** (fail-closed): (1) theo **giá trị**: mọi giá trị bí mật của `.env` (cùng luật tên như mask), và
  mọi giá trị trong Secret của các namespace ở trên đọc lúc cuối (cluster còn sống) hay lúc vừa lên (bản đã đọc, file mode 600 trong
  `$RUNNER_TEMP`, không upload), mỗi giá trị ở dạng thô và dạng base64; (2) theo **mẫu**:
  `eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.` (JWT, JWS: header và payload JSON cùng mở bằng `eyJ`, nối bằng dấu chấm),
  `svp_sid`, `Bearer `, `Set-Cookie`, `-----BEGIN [A-Z ]*PRIVATE KEY-----`. Mẫu JWT neo vào hình `header.payload.` vì `eyJ` đứng một
  mình khớp cả trong base64 của ảnh chụp: trên báo cáo Lighthouse local của 2026-10-24, `eyJ[A-Za-z0-9_-]{8,}` khớp 6 trong 18 lượt
  `/v/{id}` (12 file, cả JSON lẫn HTML) mà không có JWT nào, tức bỏ oan một phần ba bằng chứng LCP của trang đó; mẫu neo khớp 0 file,
  vì base64 của ảnh không có dấu chấm. Khớp thì bỏ file và ghi
  `::warning::<đường dẫn>: <tên luật>` (không bao giờ in đoạn khớp). Không dựng được danh sách giá trị của cluster (cluster chết
  trước khi đọc được lần nào) thì chỉ chép file do runner ghi (mẫu của sampler, `df`), bỏ mọi file đến từ cluster hay stack.
- Artifact kèm `files.txt`: tên mọi file đã chép và mọi file bị bỏ cùng tên luật, để người đọc biết thứ thiếu là do lọc.
- **Job đỏ, bị huỷ hay quá hạn bước:** các bước gom, lọc, tải có `if: always()` và cùng bộ lọc; hạn bước của mục 2 để lại thời gian
  cho chúng. Runner mất kết nối (VM chết) thì không có artifact, chỉ log.

## 5. Chia phần và bản đồ dòng dời

**Phần 1** (không cần object store mới, không secret): việc tĩnh (mục 9, 10, 11, P2 của giai đoạn 6, sửa hai e2e đỏ của job `stack`),
`verify.yml` với `compose-obs` và `dev-k3d` dùng target có sẵn. **Phần 2:** ADR riêng chọn object store thay MinIO cho compose và
k3d (presigned POST UP-1…UP-7, CORS, quyền theo user, bucket backup), hiện thực, kiểm lại bằng `compose-obs` và `dev-k3d`. **Phần
3:** `gitops`, `web-canary`, `k6-cloud-mini`, `chaos`, `velero` (thêm vào `scenario` khi hiện thực), sau phần 2 vì Velero và BAK-1 đích
object store trong cluster. **Phần 4:** bài SA tách repo GitOps (roadmap, "Bài SA bổ sung"), cần người học tạo repo và quyền mới.

**Kịch bản** (mỗi kịch bản một lượt dispatch, runner mới):

| Kịch bản | Đường | Trình tự chính (`verify-run.sh`) | Phần |
| --- | --- | --- | --- |
| `compose-obs` | compose `OBS=lgtm` | `make up OBS=lgtm` → `make smoke` → `make drill-obs-threats` → `make load-local` (quan sát cảnh báo, p99 Redis) → `make web-lighthouse` ×3 | 1 |
| `dev-k3d` | k3d đường dev | `make k8s-up` → `make k8s-smoke` → RAM nghỉ 60 s → `make drill-k8s-threats` → `make drill-k8s-pdb` → `make drill-k8s-canary` → `make k8s-web-sourcemaps` → `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` → `make drill-k8s-web-obs` → `make drill-k8s-keda N=9` (RAM đỉnh; kết luận chỉ cho đường dev) → `make drill-k8s-backup` rồi `MODE=pitr` → RAM nghỉ cuối | 1 |
| `gitops` | k3d GitOps | `make k8s-gitops-up` → `make k8s-smoke` → RAM nghỉ 60 s → `make drill-k8s-supplychain` → `make drill-k8s-threats` → source map của image CI → e2e GlitchTip → `make drill-k8s-web-obs` → `make drill-k8s-keda N=9` ×2 → chờ bản phát hành → `make measure-gitops` → RAM nghỉ cuối | 3 |
| `web-canary` | k3d đường dev | `make k8s-up` → traffic diễn tập + client trình duyệt → canary web bản tốt rồi bản lỗi (drill mới) | 3 |
| `k6-cloud-mini` | k3d đường dev | `make k8s-up` → seed ≥ 30 video `READY` → Job k6 các mức của mục 8 | 3 |
| `chaos` | k3d đường dev | `make k8s-up` → cài Chaos Mesh → k6 ở mức giữ → (b) trên pod thử → (a), (b), (c) → gỡ | 3 |
| `velero` | k3d đường dev | `make k8s-up` với driver CSI hostpath → cài Velero → `drill-restore.sh` chế độ runner → gỡ, quét | 3 |

**Bản đồ dòng dời → kịch bản** (tiêu chí đạt viết trước; "GĐ7" là giai đoạn 7, kèm lý do):

| # | Dòng dời (nguồn) | Kịch bản, lệnh | Đạt khi | Phần |
| --- | --- | --- | --- | --- |
| D1 | Hai media-worker cùng transcode trên node đủ CPU, hai lượt `drill-k8s-keda N=9` PASS gồm (c) (ADR-0017 Trạng thái, Hệ quả "Phải trả", Kiểm chứng "Hai worker cùng transcode trên node thật kiểm ở giai đoạn 6b"; ADR-0020 §1, §9, Kiểm chứng sau "Hai media-worker…") | `gitops`: `make drill-k8s-keda N=9` hai lần trên cluster có Argo CD | Hai lượt PASS, mỗi lượt có ≥ 6 mẫu liền 2 worker cùng transcode, (c) giữ, không node `NotReady`; đỉnh (a) < 8,7 GiB. Trượt (c) hai lượt → B (VM 8 vCPU, mục 2 "CPU"); node pool riêng → GĐ7 (EKS) | 3 |
| D2 | RAM nghỉ (b) ở điểm đo 60 s của ADR-0014 §2 (ADR-0017 Trạng thái, Kiểm chứng "RAM … kiểm lại ở giai đoạn 6b"; roadmap "Còn mở: RAM (b)") | `dev-k3d` (đường dev), `gitops` (đường GitOps): RAM nghỉ 60 s và cuối kịch bản | Số theo cách đo của mục 2 ghi ở Kết quả; trả lời theo quy tắc "RAM (b)" của mục 2 | 1, 3 |
| D3 | Cluster GitOps chạy image `web` đã ký từ GHCR (ADR-0019 Trạng thái, Bối cảnh, §12, "Chưa kiểm ở phần C"; threat model hàng 5b, 6b) | `gitops`: `make k8s-gitops-up`, `make k8s-smoke`, `make k8s-web-e2e` | `k8s-gitops-up` qua kiểm 7/7 bản phát hành (chữ ký, `vuln` ≤ 48 giờ), mọi Application Synced/Healthy, Rollout `web` Healthy; smoke 58 bước; e2e web xanh hai trình duyệt | 3 |
| D4 | Kyverno Enforce từ chối image web chưa ký (ADR-0019 §12; threat model SC-1 cho web, hàng 5b, 6b) | `gitops`: `make drill-k8s-supplychain SUPPLYCHAIN_UNSIGNED=<digest con amd64 của web> SUPPLYCHAIN_VULNERABLE=<drill-vulnerable>` (mục 6) | Ca (a)–(i) PASS đúng message; (b) với digest web chưa ký bị rule chữ ký từ chối | 3 |
| D5 | Source map của image CI (ADR-0019 §9, §12, Hệ quả "Xem lại khi … map của image CI") | `gitops`: artifact `web-sourcemaps-amd64` của lượt build digest đang chạy → GlitchTip của cluster → `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` → `make drill-k8s-web-obs` | Mọi chunk `/login` đang phục vụ có debug ID trong bộ map; event có frame map về `turbopack:///[project]/…` ở hai trình duyệt; `drill-k8s-web-obs` errors PASS | 3 |
| D6 | Canary web dưới traffic: promote, abort, 404 asset, số lần tải lại; tải lại vì action có đáng kể không (ADR-0019 §1 "Xem lại khi số đo ở giai đoạn 6b…", §3 cuối, §12, Hệ quả "Xem lại khi") | `web-canary` (drill mới, phần 3) | Bản tốt qua 25%, 50%, 100% và promote; bản lỗi (trả 5xx trên route traffic đo) bị phân tích abort, trọng số về 0, pod stable không đổi; ghi số 404 `web-asset`, số lần tải lại mỗi client theo loại (chunk, action), tỷ lệ action 409; mỗi client tải lại ≤ 2 lần mỗi canary. Tỷ lệ action 409 trong canary > 10% → mở việc xét khoá cố định không bí mật (ADR-0019 §1) bằng ADR riêng | 3 |
| D7 | `drill-k8s-threats` đủ, gồm các ca WEB mới (ADR-0019 §12; threat model hàng 6b) | `dev-k3d` (hồi quy trên runner; đường dev đã 16/16 ở giai đoạn 6), `gitops` (đường GitOps có web) | Mọi mục PASS, mỗi ca có đối chứng | 1, 3 |
| D8 | `drill-obs-threats` với WEB-9, refresh token, OPS-1 tám cổng (ADR-0019 §12; threat model OPS-1, WEB-9, hàng 5b, 6b) | `compose-obs`: `make up OBS=lgtm`, `make smoke`, `make drill-obs-threats` | Mọi ca PASS (Telegram SKIP vì không secret) | 1 |
| D9 | RAM của cluster có web (nghỉ, đỉnh) và `resources` của web (ADR-0019 §2 "đo lại ở giai đoạn 6b", §12; ADR-0020 §9) | `dev-k3d` (e2e), `k6-cloud-mini` (tải), `gitops` | Quy tắc `resources` của mục 8 áp với số đo; RAM như D2 | 1, 3 |
| D10 | Cổng CI quét `web/pnpm-lock.yaml` (ADR-0019 §1, §12) | Không runner: `make web-lockfile-scan` trong job `web` của `ci.yml` (mục 10) | Ca âm có CRITICAL làm target exit ≠ 0; lockfile hiện tại qua | 1 |
| D11 | k6 tải lớn nhất nơi chạy chịu được, profile `cloud` thu nhỏ (ADR-0020 Trạng thái, §1, Kiểm chứng sau "20 pod k6 giữ được tốc độ…", Hệ quả "Xong khi … chờ giai đoạn 6b … tải lớn") | `k6-cloud-mini` (mục 8) | Mức cao nhất mà mọi threshold đạt, `dropped_iterations` 0 và runner đủ, ghi số k6 và phía server; 20 pod 1 250 req/s → GĐ7 (EKS) | 3 |
| D12 | Ba thí nghiệm Chaos Mesh, (b) thử trên một pod trước (ADR-0020 §1, §7, Kiểm chứng sau "Chaos Mesh 2.8.5 và Velero 1.18.4…", Hệ quả; threat model OPS-4, hàng 6, 6b) | `chaos` (mục 7) | Giả thuyết của ADR-0020 §7 cho (a), (b), (c), mỗi cái ghi đạt hay phát hiện; gỡ sạch; version EKS và kernel AL2023 → GĐ7 | 3 |
| D13 | Velero đích object store trong cluster, mở script có điều kiện; restore giữ offset đã commit (ADR-0020 §1, §6, Kiểm chứng sau "Restore namespace có Redpanda…"; threat model BAK-2, hàng 6, 6b) | `velero` (mục 7) | Bước 5 của `drill-restore.sh` PASS (offset bằng lúc backup, lag 0, DLQ không tăng), smoke qua, RTO ghi; danh sách resource trong bucket không có Secret. "Pod `svp` phục hồi qua Kyverno" → GĐ7: phạm vi trên runner chỉ Redpanda ở `svp-data` (mục 7), ngoài namespace của Kyverno | 3 |
| D14 | Ngưỡng p99 canary của web và HPA web theo số đo (ADR-0020 §1, §3, Kết quả "Tải local") | `k6-cloud-mini` rồi `web-canary` | Quy tắc mục 8 cho `canaryLimits.p99Ms` và HPA; `web-canary` với ngưỡng mới promote bản tốt (không abort oan) | 3 |
| D15 | Thay MinIO cho đường local (ADR-0020 §1, §16) | Phần 2 (ADR riêng); kiểm lại `compose-obs`, `dev-k3d`; `velero` dùng bản thay | Theo ADR của phần 2 | 2 |
| D16 | Ngưỡng page `RateLimitFallbackActive` dưới tải lab (ADR-0020 §1, Kết quả "p99 Redis", Hệ quả "Xem lại khi") | Mục 11 (promtool, không runner); `compose-obs` quan sát dưới `make load-local` | Test promtool (a)–(h) của mục 11 xanh; trên runner cảnh báo không cháy dưới k6 `local`, ghi p99 lệnh Redis và số `context_timeout` (đường tới Redis trên runner là bridge Linux, không phải `host.docker.internal` của Docker Desktop, nên lần cháy giả có thể không tái hiện: test promtool là phép kiểm chính) | 1 |
| D17 | LCP mobile `/` và `/v/{id}`, xem lại khi Lighthouse chạy trên runner (ADR-0020 §1, §16, Kết quả "LCP") | `compose-obs`: `make web-lighthouse` 3 lượt | Median ≤ 2 500 ms cả hai trang (ghi `benchmarkIndex`). Không đạt → đòn bẩy (a) của ADR-0020 ("render trang đầu không qua `Suspense`") là việc code riêng sau phần 1, không chờ GĐ7 | 1 |
| D18 | Canary dưới probe mới chưa chạy (ADR-0020 Kiểm chứng sau "Probe mới…") | `dev-k3d`: `make drill-k8s-canary` (gateway); `web-canary` (web) | Bản tốt promote, bản lỗi abort, không pod nào restart vì probe | 1, 3 |
| D19 | RAM plugin Barman Cloud và sidecar, ngân sách cluster dev (ADR-0020 Kiểm chứng sau "RAM plugin và sidecar…") | `dev-k3d` | Plugin, sidecar dưới limit 256 Mi; cluster theo D2 | 1 |
| D20 | RTO/RPO cần nhiều lượt hơn (ADR-0020 Kết quả "Restore RTO/RPO") | `dev-k3d`: `make drill-k8s-backup` rồi `MODE=pitr` | Hai lượt PASS; RTO, RPO thêm hai mẫu, ghi là số của runner | 1 |
| D21 | `k6 inspect` và kubeconform trên amd64, kiểm sau push (ADR-0020 Kiểm chứng sau, dòng đầu và dòng kubeconform) | Không kịch bản: job `config` của PR #16 (`make k6-check`, `make cloud-check` trong `ci-ok`, bắt buộc để merge) | Việc cập nhật tài liệu ghi link lượt chạy đó | 1 |
| D22 | Job `stack` chạy đủ bước, chỉ `contents: read`, artifact hai loại (ADR-0020 Kiểm chứng sau "Service container…"; threat model SC-10, hàng 6) | Không phải `verify.yml`: job `stack` của PR phần 1, sau khi sửa hai e2e đỏ trên runner | Job xanh; quyền ở đầu log chỉ `Contents: read`; artifact chỉ `lighthouse`, `k6-summary` | 1 |
| D23 | Mỗi pod k6 là một khoá rate limit (ADR-0020 Kiểm chứng sau) | `k6-cloud-mini`: sau `setup()`, số khoá `svp:gw:rl:register:*` ở Valkey db 10 bằng số pod | Bằng số pod ở mỗi mức; trường hợp 2 hop và ElastiCache → GĐ7 | 3 |
| D24 | Plugin AWS của Velero nhận credential từ Pod Identity (ADR-0020 Kiểm chứng sau) | → GĐ7: runner không có Pod Identity; trên runner Velero dùng Secret của user object store (mục 7) | — | GĐ7 |
| D25 | Chaos Mesh và Velero cần đặc quyền lớn trong buổi đo (ADR-0020 Hệ quả; threat model mục 6) | Mục 7, mục 12 | Threat model ghi kiểm soát cho runner | 1 (thiết kế), 3 |
| D26 | `measure-gitops` không đo được bản phát hành của service có Postgres (roadmap "Còn mở" giai đoạn 5; ADR-0020 Bối cảnh, mục 11) | `gitops`: phát hành một service có Postgres trong lúc cluster chạy (mục 6) | `make measure-gitops REV=<commit>` exit 0 có số; pod mới và Job migrate `restartCount` 0, log có `database connected after retries` hay nối ngay | 3 |
| D27 | e2e cho `upload_url` lạ origin, "còn từ phần B" (threat model hàng 5b) | Không cần runner: một spec ở `web/e2e/`, chạy ở job `stack` và `make web-e2e`; chưa nằm trong phần 1 | Spec xanh, ca âm: form với `upload_url` lạ origin không được gửi | sau phần 1 |

## 6. Đường GitOps trên runner (hiện thực ở phần 3)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Deploy key chỉ đọc làm secret của environment được bảo vệ, chỉ job `gitops` dùng | Giữ nguyên `gitops.sh` | Secret đầu tiên của repo cho Actions; khoá sống trên runner suốt job (Argo CD giữ trong Secret của cluster); thêm environment, người duyệt; repo public nên khoá không thêm quyền đọc nào |
| **HTTPS ẩn danh** (`https://github.com/anhnvcoder/short-video-platform.git`) | Không secret nào ở runner lẫn máy; Argo CD không cần Secret repo; repo vốn public từ giai đoạn 5 | Repo thành private thì phải quay lại khoá; GitHub không công bố giới hạn tốc độ cho git ẩn danh qua HTTPS (Argo CD chỉ `ls-remote` khoảng 60 lần mỗi giờ nhờ cache, ADR-0014 §12) |
| Token GitHub App chỉ đọc | Thu hồi được, có hạn | Thêm App, secret để xin token; nặng hơn nhu cầu chỉ đọc repo public |
| `measure-gitops` với bản phát hành có sẵn trước khi cluster dựng | Không phải chờ | Không đo được: script cần push xảy ra sau khi Argo CD theo dõi |
| **Một bản phát hành được merge trong lúc cluster chạy** | Đo đúng push → sync → pod Ready | Job chờ một thao tác của người (tối đa 90 phút); phải chuẩn bị sẵn một PR promote |

### Quyết định

- **Argo CD đọc repo qua HTTPS ẩn danh trên cả hai nơi** (runner và máy), một URL cho mọi chỗ: `repoURL` của
  `deploy/argocd/apps/values.yaml`, `sourceRepos` của AppProject `svp`, `repo_url` của `gitops.sh`. `gitops.sh` không tạo Secret repo
  nữa, `make k8s-gitops-up` bỏ `ARGOCD_DEPLOY_KEY`; người học xoá deploy key cũ trên GitHub sau khi đường mới chạy. Đây là chỉnh
  ADR-0014 §12 ("Repo … qua SSH bằng deploy key"); phần ghi chỉnh ở ADR-0014 do việc cập nhật tài liệu sau làm. Đường GitOps vì vậy
  **không cần secret nào**.
- **Bản phát hành trong lúc cluster chạy:** trước khi dispatch `gitops`, một thay đổi không đổi hành vi của **một service có
  Postgres** (ví dụ feed-service) đã merge vào `main`, `images.yml` đã mở PR promote với `ci-ok`, `images-ok` xanh, chưa merge.
  Lượt `gitops` dựng cluster theo `main`, chạy các diễn tập, rồi tới bước tên **"Waiting for a release on main"**: bật traffic diễn
  tập, đọc `git ls-remote origin refs/heads/main` mỗi 30 s trong tối đa 90 phút. Khi bước đó đang chạy (đọc qua `gh api
  repos/<repo>/actions/jobs/<id>`, trạng thái từng bước), người học hay AI được người học uỷ quyền merge PR promote. `main` đổi thì job `git fetch`,
  kiểm commit mới đổi `image.digest` trong `deploy/k8s/values/services/` (đúng một bản phát hành), chạy `make measure-gitops
  REV=<sha>` lặp tới khi exit khác 2 (tối đa 20 phút). Push không có reflog trên runner nên script đọc PushEvent bằng `gh api`
  (`GH_TOKEN` chỉ ở bước này). Hết 90 phút không có push thì bước FAIL "no release", các diễn tập khác vẫn có kết quả.
  Tiêu chí D26: số đo có, pod mới không restart.
- **Ca web chưa ký của Kyverno:** `SUPPLYCHAIN_UNSIGNED` là **digest manifest con `linux/amd64` của bản web đang phát hành** (đọc từ
  index đã ký): cùng repository `…/web`, digest thật, kéo được, nhưng chữ ký và attestation gắn với digest index, không với manifest
  con, nên rule chữ ký phải từ chối. Lý do: chứng minh đúng "image web chưa ký" mà không cần đẩy gì lên GHCR (job chỉ đọc). Chưa xác
  nhận Kyverno không tự lần từ manifest con về index; nếu nó nhận pod đó thì ca dùng `drill-unsigned` như giai đoạn 5 và ghi lý do.
  Ca (c) cần `drill-vulnerable` có attestation dưới 72 giờ: dispatch `images.yml -f drill=true` trong 72 giờ trước lượt `gitops`.
- **Source map của image CI** (ADR-0019 §9, dời từ giai đoạn 7 về đây): job build web của `images.yml` xuất stage `sourcemaps` ngay
  sau image, cùng cache, thành artifact `web-sourcemaps-<arch>` (source map của code vốn public, không bí mật; retention mặc định).
  Job `gitops` tìm lượt `images.yml` đã build digest web đang chạy (tag 12 hex là commit), tải `web-sourcemaps-amd64` bằng
  `actions: read`, rồi tải lên GlitchTip của cluster theo cách của `make k8s-web-sourcemaps` (dạng nhận thư mục có sẵn thay vì tự
  build); kiểm như D5. Đổi `images.yml` làm build lại cả bảy image một lần (ADR-0015 §3).
- **RAM và KEDA:** đo RAM nghỉ ở điểm 60 s ngay sau `k8s-gitops-up` (D2), hai lượt `drill-k8s-keda N=9` (D1), RAM nghỉ cuối kịch bản.
- **Thời lượng:** dựng khoảng 20–30 phút, diễn tập khoảng 90 phút, chờ phát hành tối đa 90 phút, đo tối đa 20 phút: dưới hạn 285
  phút của bước kịch bản (mục 2).

## 7. Chaos Mesh và Velero trên k3d của runner (hiện thực ở phần 3)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Velero node-agent file-system backup (Kopia) | Không cần driver CSI; local-path của k3d dùng được | Đường mà giai đoạn 7 cố ý bỏ (ADR-0020 §6): diễn tập không thử đường sẽ chạy thật; node-agent root, hostPath, PSA `privileged`; mật khẩu repo Kopia thêm một secret |
| **Velero với driver CSI hostpath có snapshot** (external-snapshotter, chỉ trên runner) | Cùng đường của giai đoạn 7: `EnableCSI`, VolumeSnapshotClass có nhãn của Velero, `deletionPolicy: Retain`, restore PVC từ snapshot, không node-agent | Thêm driver CSI hostpath (pod privileged, hostPath, driver để thử, không cho production), CRD và controller snapshot; PVC của Redpanda dùng StorageClass của driver chỉ trên runner |
| Velero chỉ resource, không PV | Đơn giản nhất | Restore ra PVC rỗng: giả thuyết chính (offset giữ nguyên) không kiểm được |
| **Phạm vi diễn tập: chỉ Redpanda trong `svp-data` (theo nhãn), xoá StatefulSet và PVC của nó** | `svp-data` của k3d còn chứa object store giữ chính backup, Postgres (đã có diễn tập DR riêng) và Valkey: xoá cả namespace là xoá đích backup | Không thử phần "xoá cả namespace" (ServiceAccount, Role, NetworkPolicy của namespace); giai đoạn 7 thử |
| Đích object store riêng ở namespace khác chỉ cho Velero | Xoá được cả `svp-data` | Thêm một object store thứ hai chỉ cho runner; Postgres của k3d cũng mất cùng namespace, phục hồi CloudNativePG từ snapshot Velero chưa có trong thiết kế nào |

### Quyết định

- **Điều kiện mở script cloud trên k3d:** `deploy/k6/cloud/run.sh` và `deploy/k8s/cloud/velero/drill-restore.sh` nhận context
  `k3d-svp` chỉ khi đủ `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, `uname -s` là `Linux` (kiểm trước mọi lệnh
  `kubectl`); context `k3d-*` khác và context rỗng vẫn bị từ chối. Đây là chặn tai nạn cho máy 16 GB (ai cũng đặt được biến môi
  trường), không phải ranh giới bảo mật. VM của B đặt các biến này bằng tay khi chạy đúng kịch bản.
- **Chaos Mesh** (kịch bản `chaos`): chart, image ghim như ADR-0020 §7; phủ chỉ cho runner ở `deploy/k8s/cloud/runner/`:
  `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/k3s/containerd/containerd.sock` (containerd của k3s trong
  container node). Namespace `chaos-mesh` có nhãn `pod-security.kubernetes.io/enforce=privileged` (nhãn namespace thắng mặc định
  `restricted` của k3d), chỉ trong job. `clusterScoped: false`, đích `svp` cho (a), (b), `svp-data` cho (c) bằng `helm upgrade` như
  ADR-0020. Trước (b): `sudo modprobe sch_netem` trên runner (kernel chung với node k3d) và một NetworkChaos thử trên pod thử ở
  `svp` (đo RTT trước, trong, sau); không có module thì (b) ghi SKIP kèm lý do và sang B. Ba thí nghiệm chạy dưới k6 ở mức giữ bằng
  một nửa mức cao nhất của `k6-cloud-mini` (mặc định 2 pod khi chưa có số), mỗi cái sau 5 phút ổn định, giả thuyết và điều kiện dừng
  sớm như ADR-0020 §7. Cuối kịch bản chạy đúng các lệnh gỡ của buổi cloud (`helm uninstall`, xoá namespace, xoá CRD
  `chaos-mesh.org`) và kiểm không còn gì: diễn tập luôn lệnh gỡ. Kyverno đường dev là Audit nên `pod-failure` ở `svp` không bị chặn;
  thí nghiệm (c) vẫn ở `svp-data` như thiết kế. Chaos Mesh 2.8.5 chỉ được CI thử tới Kubernetes 1.35, k3s là 1.36: ghi ở Kết quả nếu
  có lỗi version.
- **Velero** (kịch bản `velero`): `make k8s-up` với Redpanda trên StorageClass của driver CSI hostpath (đè value chỉ trong job, không
  đổi values của đường dev và GitOps); driver, snapshot CRD và controller ghim digest, ở namespace riêng PSA `privileged` chỉ trong
  job; VolumeSnapshotClass của driver có nhãn `velero.io/csi-volumesnapshot-class: "true"`, `deletionPolicy: Retain`. Velero
  1.18.4 cùng chart, plugin AWS, values cloud cộng phủ của runner: BackupStorageLocation tới object store trong cluster
  (`s3Url` nội bộ, `s3ForcePathStyle`), `credentials.useSecret: true` với Secret `velero/velero-s3`.
- **BAK-2 cho đích object store trong cluster:** bucket `velero` và user `svp-velero` riêng, policy chỉ bucket đó (đọc, ghi, xoá, liệt
  kê), không user service nào tới được bucket đó (kiểm như BAK-1); khoá của user sinh ngẫu nhiên trong job, mask ngay, không vào
  `.env`, chỉ ở Secret `velero/velero-s3`; backup có `excludedResources: [secrets]` và `drill-restore.sh` dừng trước khi xoá gì nếu
  danh sách resource đọc từ bucket có Secret; namespace `velero` không nằm trong backup. Hết kịch bản chạy `drill-restore.sh sweep`
  rồi gỡ Velero như buổi cloud. `cluster-admin` của Velero và quyền của driver CSI chỉ sống trong cluster tạm của job.
- **Phạm vi diễn tập trên runner:** thêm cho `drill-restore.sh` một chế độ chỉ dùng trên k3d của runner: backup `svp-data` lọc theo
  nhãn của Redpanda, bước xoá chỉ xoá StatefulSet và PVC của Redpanda (không xoá namespace), các bước Argo CD bỏ qua khi cluster
  không có Argo CD (đường dev). Giả thuyết, bước 5 và RTO giữ nguyên ADR-0020 §6.

## 8. k6 thu nhỏ, ngưỡng p99 canary, HPA và `resources` của web

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| k6 container trên máy runner gọi `127.0.0.1:8443` | Không thêm gì vào cluster | Mọi request chung một IP sau load balancer của k3d (RL-1): chạm rate limit theo IP trước khi chạm hệ thống; không thử Job của giai đoạn 7 |
| **Job Indexed trong cluster (đúng `render.sh`, `run.sh`), số pod là mức tải** | Mỗi pod một IP như thiết kế cloud; thử luôn manifest và script của giai đoạn 7; mỗi pod giữ đúng phần tải của thiết kế 20 pod nên bảng rate limit của ADR-0020 §2 vẫn đúng | Pod k6 tranh CPU với hệ thống trên cùng 4 vCPU (tiêu chí throttle ở mục 2) |
| Một tốc độ cố định | Một lượt | Không biết đâu là mức cao nhất chịu được |

### Quyết định

- **Mức tải:** Job k6 profile `cloud` với 1, 2, 4, 8 pod (5%, 10%, 20%, 40% của thiết kế 1 250 req/s; feed 50, 100, 200, 400 req/s),
  mỗi pod 12 user và đúng tốc độ mỗi pod của ADR-0020 §2; `render.sh` nhận số pod, mỗi pod chạy segment i/N của tổng đã nhân. Mỗi
  mức: 2 phút lên, giữ 10 phút, 1 phút xuống, threshold như profile `cloud`; giữa hai mức xoá khoá `svp:gw:rl:register:*` ở Valkey
  db 10 của cluster (**LOCAL LAB ONLY**, như mọi diễn tập k3d). Dừng ở mức đầu tiên trượt. **Tải lớn nhất nơi chạy chịu được** là mức
  cao nhất mà mọi threshold đạt, `dropped_iterations` 0 và runner đủ (mục 2); đó là giới hạn của runner 4 vCPU chung cả hệ thống,
  không phải năng lực hệ thống. Trước khi chạy cần ≥ 30 video `READY` (RL-3, ADR-0020 §2).
- **`canaryLimits.p99Ms` của web:** `p99_E` là p99 thời gian upstream của Envoy cho cluster stable của route `web`
  (`httproute/svp/web/rule/0/backend/0`, cùng metric phân tích canary đọc) trong cửa sổ giữ của mức cao nhất đạt. Ngưỡng mới là biên
  bucket nhỏ nhất trong {250, 500, 1000, 2500} ms không nhỏ hơn 2 × `p99_E`. Hệ số 2 chừa cho pod canary lạnh (giả định; xem lại khi
  có lần abort oan). Kết quả là 500 thì giữ nguyên. `web-canary` sau đó phải promote bản tốt với ngưỡng mới.
- **HPA web:** thêm HPA khi, ở mức cao nhất đạt, CPU trung bình của pod web ≥ 50% limit (1 CPU), hoặc p99 k6 của các route web lớn hơn
  2 lần p99 ở mức 1 pod (độ trễ tăng theo tải). Khi thêm: `minReplicas: 2` (PDB), `maxReplicas: 4`, mục tiêu CPU 70% của request,
  request CPU bằng CPU trung bình mỗi pod ở mức 1 pod. Không đủ điều kiện thì giữ 2 replica cố định, ghi số.
- **`resources` của web:** limit bộ nhớ = max(384 Mi, làm tròn lên bội 64 Mi của 1,5 × working set cao nhất của một pod web qua các
  kịch bản có web); request bộ nhớ = làm tròn lên bội 32 Mi của trung vị working set lúc nghỉ, tối thiểu 128 Mi; limit CPU giữ 1, lên
  2 khi `container_cpu_cfs_throttled_periods_total` trên `container_cpu_cfs_periods_total` của web > 5% ở mức cao nhất đạt. Phần 1
  áp với số của `dev-k3d` (e2e), phần 3 áp lại với số k6 (chỉ tăng).

## 9. Bỏ qua có hạn cho cảnh báo `trivy-config` (chỉnh ADR-0015 §2, §6)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Thêm phần `misconfigurations` vào `.trivyignore.yaml` | Một tệp | `.trivyignore.yaml` dùng cho cổng image; quy tắc "chỉ `vulnerabilities`" của ADR-0015 §6 là để không đường nào bỏ qua được bí mật hay thứ khác trong cổng chặn |
| **Tệp riêng `deploy/ci/trivy-config-ignore.yaml`, chỉ `misconfigurations`, mỗi mục có `paths`, `statement`, `expired_at`** | Review qua PR, có hạn, có lý do, phạm vi theo đường dẫn; cùng trình kiểm quy tắc ở mọi PR; không đụng cổng image | Một tệp thêm, một nhánh kiểm thêm trong `scan-gate.sh` |
| Comment bỏ qua tại chỗ (`#trivy:ignore:<id>`) | Lý do nằm cạnh cấu hình | Không có trường hạn bắt buộc, không trình kiểm tập trung; không phải loại tệp nào cũng nhận |
| Chỉ dismiss trên code scanning | Không đổi repo | Lý do nằm ngoài git, không hạn, không review; lượt PR vẫn liệt kê ở summary |

### Quyết định

- **`deploy/ci/trivy-config-ignore.yaml`** theo định dạng YAML của trivy, chỉ khoá gốc `misconfigurations`; mỗi mục: `id` (KSV-…, DS-…),
  `paths` bắt buộc (không bỏ một id cho cả repo), `statement` (lý do), `expired_at` (`yyyy-mm-dd`) **tối đa 90 ngày** sau ngày chạy.
  `make trivy-config` truyền `--ignorefile deploy/ci/trivy-config-ignore.yaml`. 90 ngày thay vì 30 của lỗ hổng: misconfig là lựa chọn
  cấu hình chỉ đổi khi chính repo đổi, không có bản vá upstream tự xuất hiện; 90 ngày là khoảng một giai đoạn, đủ để xét lại khi
  cấu hình liên quan đổi mà không gia hạn mỗi tháng.
- **Ai kiểm:** `scan-gate.sh --check-ignorefile` kiểm cả hai tệp ở job `config` của mọi PR: `.trivyignore.yaml` như cũ; tệp mới chỉ
  `misconfigurations`, đủ bốn trường, `expired_at` ≤ 90 ngày. Hết hạn thì trivy bỏ mục đó, cảnh báo hiện lại ở lượt `main` kế.
  `trivy-config` vẫn chỉ báo (không `--exit-code`), quy tắc bí mật và lỗ hổng của cổng image không đổi.
- Mỗi cảnh báo được sửa nếu sửa được không đổi hành vi; chỉ cái nào là lựa chọn có chủ đích (ví dụ quyền Secret của operator
  CloudNativePG, image diễn tập cố ý có lỗ hổng) mới vào tệp, `statement` dẫn tới lý do trong ADR tương ứng.
- Đây là chỉnh ADR-0015 §2 (job `trivy-config`) và §6 (quy tắc tệp bỏ qua); phần ghi chỉnh ở ADR-0015 do việc cập nhật tài liệu sau
  làm.

## 10. Cổng quét lỗ hổng `web/pnpm-lock.yaml`

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Chỉ Renovate và Dependabot alerts | Không thêm job | Không chặn PR nào; CVE của gói Turbopack gộp vào chunk không hiện ở quét image (ADR-0019 §1) |
| `pnpm audit` | Có sẵn | Gọi API của registry npm, kết quả đổi theo dịch vụ đó; ngưỡng và bỏ qua khác cách của trivy |
| **trivy `fs` trên lockfile bằng `TRIVY_IMAGE` ghim** | Cùng công cụ, cùng DB, cùng `scan-gate.sh` và `.trivyignore.yaml` với cổng image | Thêm một lần kéo DB trivy ở job web (cache như `images.yml`) |

### Quyết định

- **`make web-lockfile-scan`:** `trivy fs --scanners vuln --include-dev-deps --format json` trên `web/pnpm-lock.yaml` bằng
  `TRIVY_IMAGE`, `--ignorefile .trivyignore.yaml`, rồi `scan-gate.sh` quyết: **CRITICAL chặn** (cả chưa có bản vá), HIGH trở xuống chỉ
  báo, như cổng image. Gồm dev dependency: chúng chạy trong CI (`next build`, test) và tạo ra bundle phát hành.
- Chạy ở **job `web` của `ci.yml`** (trong `ci-ok`), cạnh `make web-check`; SARIF `trivy-lockfile-web` (HIGH, CRITICAL) do job `sarif`
  tải lên trên `main`, như các category khác.
- Bỏ qua chỉ qua `.trivyignore.yaml` theo đúng quy tắc lỗ hổng hiện có (`purls` dạng `pkg:npm/...`, ≤ 30 ngày).
- Phiên bản lockfile của pnpm 12 có nằm trong các bản trivy đọc được không: kiểm khi hiện thực, bằng một ca âm (lockfile chứa bản
  có CRITICAL đã biết) phải làm target exit ≠ 0.

## 11. `RateLimitFallbackActive`: page khi Redis mất hẳn, không page khi quá hạn lẻ tẻ

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Giữ rule (một quyết định dự phòng trong 1 phút là page) | Nhạy nhất | Page giả dưới tải khi lệnh Redis vượt hạn 50 ms vài lần mỗi phút (game day 2026-10-24); người trực học cách bỏ qua page |
| Thêm `for` vào rule cũ | Một dòng | Tải đều thì một lần dự phòng mỗi phút vẫn giữ điều kiện đúng qua `for`; không phân biệt "Redis chết" với "vài lệnh chậm" |
| Nâng hạn 50 ms hay đổi đường Redis | Bớt nguyên nhân | Hạn 50 ms quyết lại ở giai đoạn 7 trên ElastiCache (ADR-0020 §4); đường `host.docker.internal` là của Docker Desktop, không của hệ thống |
| **Tỷ lệ quyết định dự phòng trên tổng, theo từng instance, có sàn số lượng, `for: 1m`, giữ nhánh series mới sinh của rule cũ; ticket riêng cho tỷ lệ thấp kéo dài** | Redis mất hẳn đẩy tỷ lệ về gần 100%, vượt hạn lẻ tẻ chỉ vài phần nghìn; burst trước lần xuất metric đầu (hình của RL-2) vẫn cháy; metric có sẵn, không đổi code | Lưu lượng rất thấp thì cần đủ quyết định mới cháy; biểu thức hai nhánh dài hơn; hai rule thay một |
| Chỉ tỷ lệ trên `increase`, bỏ nhánh series mới sinh | Biểu thức ngắn | Series sinh đã dương rồi đứng yên có `increase` bằng 0: RL-2 không cháy (dưới đây) |

### Quyết định

- **`RateLimitFallbackActive` (page)**, cho từng instance của gateway (nhãn instance mà series có; việc hiện thực chọn đúng nhãn), trên
  `svp_ratelimit_decisions_total{service_name="gateway"}`, cháy khi một trong hai nhánh đúng, **`for: 1m`** cho cả rule (hai nhánh cùng
  nhãn sau khi cộng theo instance, nên chuyển nhánh không ngắt cảnh báo):
  - **Nhánh tăng:** tỷ lệ `increase(...{store="fallback"}[2m])` trên `increase(...[2m])` **≥ 0,5**, **và**
    `increase(...{store="fallback"}[2m])` **≥ 3**.
  - **Nhánh series mới sinh** (giữ ý của nhánh `unless ... offset` ở ADR-0011 §8): chỉ các series không có mẫu 2 phút trước
    (`X unless X offset 2m`, khớp đủ nhãn trước khi cộng theo instance), cùng hai ngưỡng áp lên giá trị của chúng: tổng `fallback`
    trên tổng mọi store của các series đó **≥ 0,5** và tổng `fallback` **≥ 3**. `New` tạo mọi series ở 0 lúc khởi động nên giá trị
    mẫu đầu là số quyết định từ lúc khởi động; nhưng mẫu 0 chỉ tới Prometheus nếu kịp một lần xuất, nên burst trước lần xuất 15 s
    đầu có mẫu đầu đã dương rồi đứng yên, và `increase` của nó bằng 0. Cửa sổ 2 phút thay 1 phút của rule cũ vì nhánh phải đúng lâu
    hơn `for` cộng hai chu kỳ đánh giá: với `offset 1m` nó tắt đúng lúc `for` vừa đủ và không bao giờ cháy.
  - Tỷ lệ ở nhánh series mới sinh cũng bỏ hai lần cháy giả mà rule cũ có: gateway khởi động lại dưới tải khi Redis khoẻ, với vài lần
    quá hạn trước lần xuất đầu (vài quyết định dự phòng trên hàng trăm); và sau một khoảng mất dữ liệu dài, khi counter tích luỹ của
    một instance sống lâu trông như series mới (ADR-0011 §8 chấp nhận cảnh báo thận trọng đó; với tỷ lệ, nó chỉ cháy khi phần lớn
    quyết định từ lúc khởi động là dự phòng).

  Redis không tới được thì mọi quyết định của instance đó là dự phòng (tỷ lệ 1); một trong hai pod gateway mất Redis cũng cháy (cảnh
  báo theo instance, không pha loãng bởi pod kia).
- **`RateLimitFallbackElevated` (ticket)**, cùng nhãn: tỷ lệ trong 30 phút ≥ 0,01 và ≥ 30 quyết định dự phòng trong 30 phút. Vượt hạn lẻ
  tẻ như game day (khoảng 3 trên khoảng 1 200 quyết định mỗi phút, 0,25%) không page, không ticket, chỉ thấy trên dashboard và dòng
  WARN có sẵn.
- **Giữ RL-2:** `drill-obs-threats` dựng lại gateway với Redis không tới được, gửi ba login sai (mỗi login hai quyết định dự phòng,
  `login-ip` và `login-email`: tổng 6) rồi chỉ chờ, không traffic nào khác, và đòi page có trong Alertmanager **trong 240 s** từ login
  đầu (đọc mỗi 5 s). Hai hình, cả hai dưới hạn:
  - Login tới trước lần xuất đầu (gateway sẵn sàng sau vài giây, xuất mỗi 15 s): mẫu đầu đã là 6, tỷ lệ 1. Nhánh series mới sinh đúng
    từ lần đánh giá đầu sau mẫu đó (≤ 30 s sau login đầu), firing sau `for` (khoảng 75–90 s sau login đầu, cộng vài giây để tới
    Alertmanager), đúng thêm 45–60 s rồi resolve khi series có 2 phút lịch sử.
  - Login tới sau lần xuất đầu (mẫu đầu 0): nhánh tăng đúng từ mẫu kế (tăng 6, tỷ lệ 1), firing sau `for` cùng khoảng đó, resolve khi
    cửa sổ 2 phút trôi qua burst.
- **Test promtool** (sửa nhóm `RateLimitFallbackActive` của `svp-alerts.test.yaml`, thêm ca cho ticket):
  - (a) một instance ~20 quyết định/s chuyển hẳn sang dự phòng, series bắt đầu từ 0: page trong 4 phút;
  - (b) 20 quyết định/s với 3 dự phòng mỗi phút suốt 30 phút: không page, không ticket;
  - (c) lưu lượng thấp, 2 quyết định mỗi phút, một dự phòng trong 2 phút: không page;
  - (d) 2% dự phòng suốt 30 phút: ticket, không page;
  - (e) hai instance, chỉ một sang dự phòng: page cho instance đó;
  - (f) series sinh đã dương rồi đứng yên, không traffic nào khác (hình RL-2: `fallback` 6, `redis` 0): page sau `for`, resolve khi
    series có 2 phút lịch sử; cùng hình với `fallback` 2: không page (dưới sàn);
  - (g) gateway khởi động lại khi Redis vẫn mất: instance cũ (có lịch sử từ 0) dừng, instance mới sinh với `fallback` 6: page cho
    instance mới, không cho instance cũ;
  - (h) gateway khởi động lại khi Redis khoẻ: instance mới sinh với `redis` 300, `fallback` 5: không page (tỷ lệ dưới 0,5).

  Bốn test của rule cũ: "Fallback counters at 0 and a growing Redis counter do not fire" giữ nguyên; "Fallback series born above 0"
  thành (f) và "Gateway restart" thành (g), với giá trị sinh nâng từ 3 và 2 lên 6 (đúng số của RL-2) và mốc thời gian theo `for`;
  "Fallback counter 0 -> 1 then flat fires" đổi kỳ vọng thành không page, vì một quyết định dự phòng đứng một mình là hình của một
  lần quá hạn, đúng thứ rule mới bỏ. Hai chỗ không còn page (một quyết định dự phòng đứng một mình, series sinh với 2) là thay đổi
  có chủ đích của mục này, không phải nới test; comment của test ghi lý do.
  Runbook `docs/runbooks/rate-limit-fallback-active.md` cập nhật theo điều kiện mới. Đây là chỉnh rule của ADR-0011 §8 (bảng cảnh báo
  và công thức); phần ghi chỉnh ở ADR-0011 do việc cập nhật tài liệu sau làm.

## 12. Threat model

Thêm vào [`docs/threat-model.md`](../threat-model.md): **SC-11** (workflow `verify.yml`: dispatch, runner, log và artifact công khai,
công cụ đặc quyền trên runner) và **SC-12** (Argo CD đọc repo qua HTTPS ẩn danh, từ phần 3) ở 4.8; cập nhật **OPS-4** (Chaos Mesh
trên k3d của runner) và **BAK-2** (kiểm soát cho đích object store trong cluster); hàng giai đoạn 6b của mục 5; dòng ở mục 6 cho
giới hạn của bộ lọc artifact; đề xuất xem lại ở mục 7. Dòng chỉ kiểm được khi chạy ghi "kiểm khi chạy" kèm kịch bản.

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết; mỗi dòng nêu kịch bản hay phép kiểm chứng minh nó; kết quả và ngày ghi vào cột cuối.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Ba tên `*.svp.localhost` qua `/etc/hosts` chỉ trả `127.0.0.1` trên runner; drill và Playwright tới được Envoy | `verify-host.sh` (`getent ahosts`) và `make k8s-smoke` ở `dev-k3d` | `verify-host.sh` đạt (2026-10-24, [40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)): ba tên chỉ trả `127.0.0.1`. `make k8s-smoke` đạt ở lượt 4 (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): 58 bước qua Envoy; e2e của web 64/64 qua `svp.localhost`. Đạt |
| Cổng đĩa đúng: kịch bản k3d dùng ≤ 30 GiB, không pod nào bị evict vì đĩa | `df` trước/sau và sampler ở `dev-k3d`, `compose-obs` | `compose-obs` (2026-10-24, [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): dùng 12,7 GiB (trống 80,6 GiB lúc vào kịch bản, thấp nhất 67,9 GiB, ổ `/dev/root` 144,3 GiB: ổ thật lớn hơn 14 GB của tài liệu), không lần nào dưới ngưỡng chạy; `need` đổi 15 → 16 GiB; lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)) dùng 12,5 GiB, `need` giữ. k3d: lượt 1 ([40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)) dừng ở wave 3, tới đó dùng 14,3 GiB (trống 80,4 GiB lúc vào kịch bản, thấp nhất 66,0 GiB); lượt 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975)) dừng cùng chỗ, dùng 14,3 GiB (thấp nhất 66,1 GiB); lượt 3 ([40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978)) cài tới wave 7 và chạy mọi bước (thiếu pod gateway, web), dùng 22 GiB (trống 81 GiB lúc vào kịch bản, thấp nhất 59,1 GiB), không pod nào bị evict; lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)) chạy đủ kịch bản, dùng 23,8 GiB (trống 80,4 GiB lúc vào kịch bản, thấp nhất 56,6 GiB), không pod nào bị evict, `need` giữ 30 GiB (1,25 × 23,8 = 29,8); lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)) cũng dùng 23,8 GiB, thấp nhất 56,6 GiB. Đạt ở cả hai kịch bản phần 1 |
| `docker stats` và `memory.stat` của node k3d trên runner (cgroup v2, Docker 28) đo được như trên máy | RAM nghỉ, đỉnh ở `dev-k3d` | Đạt (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): MEM USAGE của bốn container k3d mỗi 10 s suốt kịch bản; `anon`, `active_file`, `kernel` của hai node đọc được qua `docker exec` ở hai điểm nghỉ (mục Kết quả, lượt 4). Lúc đỉnh lượt không đọc `memory.stat` (đỉnh tính từ mẫu `docker stats` sau diễn tập); từ 2026-10-25 sampler ghi `memory.stat` của hai node mỗi mẫu 10 s và `ram-peak` tính cả MEM USAGE trừ `active_file` của cửa sổ đỉnh. Lượt 7 ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)): đọc được `memory.stat` của hai node ở cả 170 mẫu có cluster; trung vị trừ `active_file` của cửa sổ đỉnh chưa có số vì lượt đó không có cửa sổ (mục Kết quả, lượt 7) |
| Runner có hay không có swap; `MemAvailable` thấp nhất ≥ 2 GiB ở mọi kịch bản | Sampler ở mọi kịch bản | Có swap: `/swapfile` 3 GiB (`swapon --show`). `compose-obs` ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): `MemAvailable` thấp nhất 8 156 MiB, swap dùng tối đa 17 MiB; lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)): 8 658 MiB, swap 16 MiB. `dev-k3d` lượt 1 ([40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651), dừng ở wave 3): thấp nhất 10 807 MiB, swap 0; lượt 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975), cùng chỗ): 10 877 MiB, swap 0; lượt 3 ([40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978), thiếu pod gateway, web): 9 051 MiB, swap 0; lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), đủ kịch bản, gồm hai worker cùng transcode): 6 172 MiB, swap dùng tối đa 85 MiB; lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): 6 183 MiB, swap 0. Đạt ở cả hai kịch bản phần 1 |
| Bộ lọc bỏ file có giá trị bí mật hay mẫu cấm, giữ file sạch | Test của `verify-collect.sh` với giá trị giả (ca có và ca không); lượt `compose-obs`, `dev-k3d`: `files.txt` | `verify-collect-test.sh` xanh (ca có và ca không, 2026-10-25). `compose-obs` ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): `files.txt` giữ 26 file, bỏ 4 đều `not-allowed` (`job-start`, `sampler.pid`, `sampler.err`, `machine.json` của k6), không `::warning::` nào của bộ lọc. Bộ lọc dòng phán quyết của `drill-obs-threats` giữ đúng ý nhưng giấu luôn dòng lỗi của bash khi một mục dừng vì `set -e` mà không in `FAIL` (lỗi WEB-9 của lượt này): mục nào dừng giờ in thêm `FAIL  <mục>: the item ended with exit status <n>`. `compose-obs` lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)): cùng 4 file bỏ `not-allowed`, không `::warning::`; báo cáo Lighthouse giữ `Cookie` của `extraHeaders` ở dạng `[redacted]`. `dev-k3d` lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): giữ 40 file, bỏ 11: 9 `not-allowed` (`job-start`, `sampler.pid`, `sampler.err`, `threats-*.log`, đầu ra của traffic diễn tập, hai clip `.mp4` và hai JSON `first-frame-*` của e2e), 1 `hidden` (`.last-run.json` của Playwright), và dòng phán quyết của `drill-k8s-threats`, bỏ oan với luật `session-cookie`: câu `ok` của mục WEB-7 nêu tên cookie `__Host-Http-svp_sid`, nên mọi lượt có web mất dòng phán quyết của drill, kể cả khi nó đỏ. Đã sửa: ở dòng phán quyết của hai drill threat model, `svp_sid` đứng trước một dấu cách là câu nói về cookie; đứng trước ký tự khác hay cuối dòng (dạng `name=value`, dòng cookie jar, JSON) vẫn làm bỏ file, mọi file khác giữ luật cũ; `verify-collect-test.sh` thêm một ca giữ và năm ca bỏ (bốn dạng ghi giá trị trong dòng phán quyết, một câu nêu tên trong đầu ra target thường), và không có bản sửa thì test đỏ đúng chỗ của lượt 4. `dev-k3d` lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): `logs/04-drill-k8s-threats.verdicts.log` giữ (bản sửa đúng), có đủ tiêu đề mục, phán quyết và bảng cuối; dòng lỗi của bash khi mục WEB-7 dừng vẫn bị bỏ (đúng ý: không phải dòng phán quyết), nên drill k3d giờ cũng in `FAIL  <mục>: the item ended with exit status <n>` như drill compose (test có ca giữ dòng đó, bỏ dòng lỗi của bash). Lượt 5 còn một `::warning::` mỗi lượt có e2e, `web/test-results/playwright/.last-run.json: hidden` (tệp Playwright ghi ở mọi lượt, chỉ có id test đỏ): từ 2026-10-25 tệp đó ghi `not-allowed` không cảnh báo, tệp ẩn khác vẫn `hidden` kèm cảnh báo (test có cả hai ca). Lượt 6 ([40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740)): không `::warning::` nào, bỏ 4 tệp đều `not-allowed` |
| Mask che giá trị trong log job, lệnh mask không hiện | Lượt `compose-obs`: `verify-mask.sh` mask một giá trị ngẫu nhiên làm mốc rồi in dòng `mask-check: <giá trị>`; log thô (`gh run view --log`) phải có `mask-check: ***` và không có dòng `::add-mask::` nào (không cần biết giá trị để kiểm) | Đạt ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): log thô có `mask-check: ***` ở bước `verify-mask.sh env`, không dòng `::add-mask::` nào; không mẫu JWT, `Bearer`, `Set-Cookie`, `svp_sid`, khoá riêng nào trong log. Lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)): như vậy, cả trong artifact. `dev-k3d` lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): như vậy, cả sau `verify-mask.sh cluster` (317 giá trị); lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): như vậy |
| Bước `if: always()` vẫn gom và tải sau khi bước kịch bản quá hạn | Lượt đầu có bước đỏ hay quá hạn | Sau bước đỏ: đạt ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687): bước kịch bản đỏ, `verify-sample.sh stop`, `verify-collect.sh`, tải artifact, `make down` đều chạy). Sau bước quá hạn: chưa gặp |
| Setup trước bước kịch bản ≤ 20 phút ở cả ba job | Thời gian các bước setup ở lượt đầu mỗi job (`gh run view --json jobs`) | `compose`: 1 phút 35 s (job 20:18:41 → bước kịch bản 20:20:16 UTC, [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)); `k3d`: 2 phút 28 s (20:46:01 → 20:48:29 UTC, [40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)); lượt 4: 1 phút 51 s (00:10:46 → 00:12:37 UTC, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)); lượt 5: 1 phút 28 s (01:38:49 → 01:40:17 UTC, [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)). `gitops`: phần 3 |
| Miễn trừ giới hạn pull của Docker Hub cho runner GitHub cũng áp cho pull từ containerd trong node k3d | `dev-k3d`, `gitops`: không event `Failed` nào có `429 Too Many Requests` trong `kubectl get events -A` của artifact, không lỗi 429 ở `docker pull` | `dev-k3d` lượt 1 ([40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)): 41 lần đọc event (0 lỗi), 0 pull bị từ chối 429, 0 output có 429; lượt 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975)): như lượt 1; mới kéo image tới wave 3, chưa kết luận; lượt 3 ([40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978)): kéo image của mọi wave 0–7 (gateway, web lấy từ registry k3d), 59 lần đọc event (0 lỗi), 0 pull bị từ chối 429, 0 output có 429: đạt cho `dev-k3d`; lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): 67 lần đọc (0 lỗi), 0 pull 429; lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): 68 lần đọc (0 lỗi), 0 pull 429; `gitops` ở phần 3 |
| Script k3d chạy trên bash 5 và coreutils GNU sau các sửa của phần 1 | `dev-k3d` xanh | Lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): 13 trên 14 bước đạt. Lịch abort của `drill-k8s-canary` in `date: <giây>: No such file or directory` thay cho giờ (`date -r` của BSD trong `hms` của `deploy/k8s/drills/canary.sh`; chỉ phần in, phép kiểm vẫn đạt), đã đổi sang cách chạy được cả hai nơi. `drill-k8s-threats` đỏ, chưa biết mục nào (mục Kết quả, lượt 4). Lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): lịch abort in giờ đúng; mục WEB-7 của `drill-k8s-threats` dừng vì `local i` không giá trị (bash 3.2 gán `""`, bash từ 4.0 để chưa đặt) rồi `$((i + 1))` dưới `set -u`; đã sửa, các script diễn tập và cài đặt của hai kịch bản không còn chỗ như vậy. Lượt 6 ([40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740), chỉ `k8s-up`, `k8s-smoke`, `drill-k8s-threats`): `drill-k8s-threats` 16/16 mục PASS, WEB-7 chạy hết (HTML bốn trang, hai payload RSC, tìm token). Đạt: 14 bước của `dev-k3d` đều đã đạt trên runner (13 ở lượt 5, `drill-k8s-threats` ở lượt 6) |
| Broker Redpanda của chart khởi động trên runner x86_64 với `--reserve-memory=128M` (`vm.min_free_kbytes` 67 584 kB) | `dev-k3d`: `make k8s-up` qua release `redpanda`; `verify-host.sh` in `vm.min_free_kbytes` | Đạt (2026-10-24, [40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978)): `verify-host.sh` in `vm.min_free_kbytes 67584 kB`, đúng số suy từ lỗi của lượt 2; release `redpanda` Ready, `redpanda-0` 2/2 Running, 0 restart trong 52 phút; RAM cao nhất của container `redpanda` 232 MiB, sidecar 165 MiB. Lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): như vậy, 0 restart trong 61 phút, `redpanda` cao nhất 301 MiB; lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): 0 restart trong 62 phút, cao nhất 361 MiB |
| Controller Argo Rollouts chạy được plugin Gateway API trên node amd64 của runner (bản `linux-amd64` cùng release, `--set-json` của `deploy/k8s/install.sh`) | `dev-k3d`: `make k8s-up` in `ok    Argo Rollouts gets the Gateway API plugin built for amd64 nodes`, rồi `rollout gateway Healthy`, `rollout web Healthy` | Đạt (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): `k8s-up` in đúng dòng đó trước `ok    argo-rollouts`, rồi `rollout gateway Healthy`, `rollout web Healthy` (1 109 s); `drill-k8s-canary` đổi trọng số qua plugin (25 %, 50 %, 100 %, abort về 100/0) |
| Hai worker cùng transcode trên runner 4 vCPU giữ (c) | `dev-k3d` (đường dev), `gitops` (D1) | Đường dev: đạt (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): hai worker cùng transcode từ 00:53:53Z tới 00:56:10Z (14 mẫu 10 s liền, CPU của cả hai node 130–240 %, mỗi pod 1 338–1 990m theo `kubectl top`, CPU bận của máy tới 99 %); `drill-k8s-keda` PASS, k3s server `RestartCount` 0 và `StartedAt` không đổi suốt kịch bản, không node `NotReady` ở mẫu nào. Lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): đạt lần hai, hai worker cùng transcode từ 02:20:58Z tới 02:22:15Z (8 mẫu 10 s liền), k3s server `RestartCount` 0, `StartedAt` không đổi. Hai khoảng này tính tay từ CPU của node và `kubectl top`; từ 2026-10-25 sampler tự đếm (dòng dưới). Lượt 7 ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)): `drill-k8s-keda` PASS, (c) giữ, nhưng hai worker cùng transcode chỉ một mẫu: diễn tập không bảo đảm khoảng đó, độ dài của nó tuỳ cách chia partition (mục Kết quả, lượt 7). `gitops` (D1, hai lượt, mỗi lượt ≥ 6 mẫu liền): phần 3; với diễn tập như hiện nay D1 có thể trượt vì cách chia partition chứ không vì runner, nên phải xử lý điều đó trước phần 3 |
| Argo CD sync qua HTTPS ẩn danh, không Secret repo | `gitops`: mọi Application Synced; `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository` rỗng | Chưa kiểm |
| Kyverno từ chối digest manifest con của web bằng rule chữ ký | `gitops`: ca (b) của `drill-k8s-supplychain` | Chưa kiểm |
| chaos-daemon dùng được socket containerd của k3s; `sch_netem` có trên kernel runner | `chaos`: NetworkChaos trên pod thử | Chưa kiểm |
| Driver CSI hostpath, snapshot controller và Velero 1.18.4 chạy trên k3s 1.36 | `velero`: backup có VolumeSnapshot, restore PVC từ snapshot | Chưa kiểm |
| trivy đọc được lockfile của pnpm 12 | `make web-lockfile-scan` với ca âm | Đạt (2026-10-24): lockfile v9.0 của pnpm 12, trivy đọc 997 gói npm (gồm dev dependency; `pnpm list --depth Infinity` 988 gói đã cài, lockfile 1 012 mục gồm gói tuỳ chọn của nền tảng khác; thiếu `--include-dev-deps` chỉ 319); ca âm (`minimist` 1.2.8 → 1.2.5 trong bản sao) exit 2 với CVE-2021-44906; lockfile trivy không đọc được (0 gói) exit 2. Job `web` trên runner: 997 gói, CRITICAL 0 ([40157835981](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157835981)) |
| trivy nhận `misconfigurations` với `paths`, `expired_at` trong tệp bỏ qua của `trivy config` | `make trivy-config` trước và sau khi thêm một mục: số kết quả giảm đúng mục đó | Đạt (2026-10-24): `make trivy-config` 18 → 0 kết quả trên 31 target (4 sửa, 14 vào `deploy/ci/trivy-config-ignore.yaml`, hạn 2027-01-22); tệp tạm có KSV-0125 chỉ cho file của Valkey thì cảnh báo của MinIO vẫn hiện (`paths` đúng phạm vi); `expired_at` là hôm nay thì DS-0026 hiện lại, là ngày mai thì bị bỏ |
| Rule mới của `RateLimitFallbackActive` đúng tám ca (a)–(h) của mục 11 và giữ RL-2 | `make slo-check` (test promtool); `compose-obs` (`drill-obs-threats` RL-2: page trong 240 s) | Test promtool: `make slo-check` xanh trong job `config` của lượt CI [40129094568](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129094568) (`main` `a9b035a`). RL-2 trên runner ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): page `startsAt` 76 s, thấy trong Alertmanager 81 s sau login đầu (hạn 240 s): đạt; lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)): 88 s, 91 s |
| Sampler đếm đúng worker đang transcode trên runner: cgroup của tiến trình `ffmpeg` có UID của pod media-worker (mục 2, sửa 2026-10-25) | `dev-k3d` với `targets='drill-k8s-keda ram-peak'` (hay lượt đủ kịch bản): cột worker transcode của `samples/docker.tsv` lên 2 đúng khoảng CPU của hai pod media-worker cùng cao (`samples/pods.tsv`), `ram-peak.json` có cửa sổ 6 mẫu và MEM USAGE trừ `active_file` | Đếm đúng (2026-10-25, [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327), `targets='drill-k8s-keda ram-peak'`): trong diễn tập 64 trên 69 mẫu có hai pod `Running`, nhưng cột worker transcode là 1 ở 36 mẫu, 2 ở một mẫu (04:22:41Z, giữa lúc pod thứ hai nhận partition và lúc ghim, đúng mốc 86,2 s và 89,5 s của diễn tập), 0 sau `READY` cuối. Mỗi mẫu có node trên 150 % CPU đều đếm ít nhất 1, mẫu đếm 0 trong diễn tập không node nào trên 150 %; ba pod lần lượt transcode trên cả hai node đều được đếm; `kubectl top` cho cùng hình (một pod 1 873–2 000m, pod kia 1m, trừ mẫu chuyển giữa hai pod lúc 04:23:52Z và mẫu trễ sau `READY` cuối lúc 04:27:56Z). Cửa sổ 6 mẫu và MEM USAGE trừ `active_file` của `ram-peak.json` chưa có số: lượt này thật sự chỉ một worker transcode mỗi lúc (mục Kết quả, lượt 7); kiểm ở lượt đầu có khoảng hai worker cùng transcode. Test của `verify-collect-test.sh` (mẫu giả của `/proc`, `docker`, `kubectl`, `pgrep`; cả đường cgroupfs lẫn systemd, `ffmpeg` ngoài pod, pod không phải media-worker) xanh ngày 2026-10-25 |
| Lượt `schedule` chạy `compose` và `k3d` song song trên `main`, mỗi job đúng kịch bản của nó, mọi bước, hai artifact | Lượt lịch đầu sau khi merge vào `main` (**kiểm sau push**): `gh run list --workflow verify.yml --event schedule`, hai job, `results.tsv` không bước nào `not in targets` | Bước kiểm ref theo `$GITHUB_EVENT_NAME:$GITHUB_REF` qua với `workflow_dispatch` trên nhánh ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)). Lượt lịch: chưa kiểm |

## Kết quả

Mỗi lượt dispatch ghi một dòng (ngày, kịch bản, ref và commit, link lượt chạy, runner đủ hay không), số đo vào bảng của dòng
dời tương ứng (D1–D27, mục 5), và dòng nào sang B hay giai đoạn 7 kèm lý do.

| Kịch bản | Lượt (ngày, commit, link) | Runner đủ | Kết quả chính |
| --- | --- | --- | --- |
| `compose-obs` | 1: 2026-10-24, `main` `a9b035a`, [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 156 MiB, không OOM, đĩa trống thấp nhất 67,9 GiB, không container nào restart ngoài các lần diễn tập dựng lại | Đỏ vì hai lỗi của script, không vì runner: WEB-9 của `drill-obs-threats` dừng giữa chừng, `make web-lighthouse` ×3 không mở được Chrome nên không có LCP; mọi bước còn lại đạt (dưới đây). Đã sửa, xem lượt 2 |
| `compose-obs` | 2 (lượt cuối): 2026-10-24, `feat/stage6b-verify-results` `0cb842e`, [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 658 MiB, không OOM, đĩa trống thấp nhất 67,9 GiB, không container nào restart ngoài các lần diễn tập dựng lại | Mọi bước đạt trừ D17: Lighthouse chạy đủ 3 lượt, LCP median của `/` 3 253 ms vượt 2 500 ms (bước `lcp` đỏ vì số đo, không vì script); `/v/{id}` 2 182 ms đạt (dưới đây) |
| `dev-k3d` | 1: 2026-10-24, `main` `a9b035a`, [40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651) | Chưa kết luận: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 10 807 MiB, không OOM, không evict, đĩa trống thấp nhất 66,0 GiB; `within_deadline=false` chỉ vì hai bước RAM nghỉ chờ đủ 900 s một pod không bao giờ Ready, hệ quả của bước đỏ chứ không phải runner thiếu | Đỏ ở bước đầu `make k8s-up`: broker Redpanda thoát ngay mỗi lần khởi động, release `redpanda` (wave 3) không Ready; mọi bước sau đỏ theo. Nguyên nhân chưa biết vì lượt không giữ log container; `deploy/k8s/install.sh` giờ in log đó khi một release không Ready (dưới đây). Nguyên nhân ở lượt 2 |
| `dev-k3d` | 2: 2026-10-24, `feat/stage6b-verify-results` `d767d42`, [40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975) | Chưa kết luận, như lượt 1: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 10 877 MiB, không OOM, không evict, đĩa trống thấp nhất 66,1 GiB; `within_deadline=false` cùng lý do | Đỏ cùng chỗ. Log broker cho nguyên nhân: Seastar không khởi động vì phép kiểm bộ nhớ của nó trừ `vm.min_free_kbytes` của kernel, trên runner x86_64 lớn hơn trong VM Docker Desktop. Đã sửa ở `deploy/k8s/values/redpanda.yaml` (dưới đây). Chờ lượt 3 |
| `dev-k3d` | 3: 2026-10-24, `feat/stage6b-verify-results` `ca102a4`, [40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978) | Chưa kết luận: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 9 051 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 59,1 GiB, `within_deadline=true`; cluster thiếu pod gateway, web nên chưa có tải nào (KEDA không có video để transcode) | Redpanda qua (lỗi của lượt 1–2 hết). Đỏ ở `make k8s-up` sau 1 926 s: Rollout `gateway` (wave 7, lần cài đầu) đứng ở `Progressing`, ReplicaSet tạo mà không bao giờ có pod, vì plugin Gateway API của Argo Rollouts ghim bản `linux-arm64` không chạy được trên node amd64. Mọi bước sau đỏ theo (không có gateway, web chưa cài). Đã sửa ở `deploy/k8s/install.sh` (dưới đây). Chờ lượt 4 |
| `dev-k3d` | 4: 2026-10-25, `feat/stage6b-verify-results` `d1b4529`, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985) | Đủ: xong trong hạn (`within_deadline=true`), `MemAvailable` thấp nhất 6 172 MiB, swap tối đa 85 MiB, không OOM, không evict, đĩa trống thấp nhất 56,6 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Plugin amd64 đúng (lỗi lượt 3 hết). 13 trên 14 bước đạt: smoke, RAM nghỉ (b) cho đường dev, PDB, canary gateway, source map, e2e web 64/64 với GlitchTip, `drill-k8s-web-obs`, KEDA với hai worker cùng transcode, backup `latest` và `pitr`. RAM đỉnh (a) 9 994 MiB vượt 8,7 GiB. `drill-k8s-threats` đỏ (exit 2), chưa biết mục nào: bộ lọc artifact bỏ oan dòng phán quyết của nó. Đã sửa bộ lọc (dưới đây). Chờ lượt 5 |
| `dev-k3d` | 5: 2026-10-25, `feat/stage6b-verify-results` `07e32fa`, [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243) | Đủ: xong trong hạn (`within_deadline=true`), `MemAvailable` thấp nhất 6 183 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 56,6 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Dòng phán quyết của `drill-k8s-threats` tới artifact (sửa bộ lọc của lượt 4 đúng): 15/16 mục PASS, WEB-7 FAIL vì mục dừng giữa chừng dưới bash 5, không vì một phép kiểm trượt. Đã sửa ở `deploy/k8s/drills/threats.sh` (dưới đây). 13 bước còn lại đạt như lượt 4; RAM đỉnh theo định nghĩa 8 878 MiB. Lượt đủ kịch bản cuối của phần 1 |
| `dev-k3d` | 6 (chỉ bước chọn): 2026-10-25, `feat/stage6b-verify-results` `2df0493`, [40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740), `targets='k8s-smoke drill-k8s-threats'` | Đủ cho các bước đã chạy: xong trong hạn, `MemAvailable` thấp nhất 8 682 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 59,5 GiB, k3s server giữ `RestartCount` và `StartedAt`, node luôn Ready, 0 pull 429; lượt chọn bước không thay lượt đủ kịch bản (mục 3) | Xanh, 24 phút: `k8s-up` 1 083 s, `k8s-smoke` 58 bước, `drill-k8s-threats` 16/16 mục PASS gồm WEB-7 (sửa của lượt 5 đúng); 11 bước `skipped` `not in targets`. Dừng sớm và chọn bước chạy đúng trên runner |
| `dev-k3d` | 7 (lượt cuối, chỉ bước chọn): 2026-10-25, `feat/stage6b-verify-results` `77bd25c`, [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327), `targets='drill-k8s-keda ram-peak'` | Đủ cho các bước đã chạy: xong trong hạn, `MemAvailable` thấp nhất 7 802 MiB, swap tối đa 1 MiB, không OOM, không evict, đĩa trống thấp nhất 58,4 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Xanh, 31 phút: `k8s-up` 1 028 s, `drill-k8s-keda` PASS lần ba (690 s). Sampler đếm đúng worker đang transcode, nhưng lượt này không có khoảng hai worker cùng transcode: 9 video chia 4/2/3 vào ba partition và pod thay vào sau lúc ghim nhận cả hai partition còn video, nên `ram-peak` không có cửa sổ 6 mẫu (đúng định nghĩa, không phải lỗi đếm; dưới đây) |
| `gitops` | — (phần 3) | — | — |
| `web-canary` | — (phần 3) | — | — |
| `k6-cloud-mini` | — (phần 3) | — | — |
| `chaos` | — (phần 3) | — | — |
| `velero` | — (phần 3) | — | — |

### `compose-obs`, lượt 1 ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687))

- **Runner:** kernel 6.17.0-1022-azure, 4 CPU, RAM 15 989 MiB, swap `/swapfile` 3 GiB; ổ `/dev/root` 144,3 GiB, trống 80,6 GiB lúc
  vào kịch bản. CPU bận cao nhất 100 %, MEM USAGE của stack compose cao nhất 2 638 MiB. `make up OBS=lgtm` 346 s, `make smoke` 12 s
  (58 bước đạt).
- **D8 `drill-obs-threats`:** JWT-8, UP-8, OPS-1 (đúng 8 cổng, mọi cổng trên `127.0.0.1`), RL-2 đạt. WEB-9 đạt tới đăng ký, đăng
  nhập lại, feed và upload qua form của web, 3 beacon `/rum` (204), báo lỗi `/monitoring` (202), rồi dừng ở kiểm đối chứng đầu: hàm
  `control` chỉ có trong drill của k3d, nên bash dừng mục với `command not found` (exit 127) mà không in dòng `FAIL` nào, và bộ lọc
  dòng phán quyết của artifact giấu luôn dòng lỗi đó. Phần tìm giá trị trong GlitchTip, Tempo, Loki, Prometheus chưa chạy: **chưa
  kết luận**. Đã sửa: drill định nghĩa `control`, và mục nào dừng in thêm `FAIL  <mục>: the item ended with exit status <n>`.
- **D16 `RateLimitFallbackActive` dưới `make load-local`:** không page trên runner: không cảnh báo nào bắt đầu trong 483 s quan sát
  (50 lần hỏi Alertmanager, không lần nào lỗi); p99 lệnh Redis của gateway 4,95 ms, không lệnh `context_timeout`, 0 quyết định dự
  phòng trên 8 201 quyết định (`rate-limit-load.json`). Bằng chứng yếu như đã nói ở D16: Redis tới qua bridge Linux, không qua
  `host.docker.internal` của Docker Desktop; test promtool là phép kiểm chính (Kiểm chứng sau).
- **`make load-local`:** mọi threshold đạt; 7 624 request (23,0 req/s), 0 lỗi, `dropped_iterations` 0. p95/p99 (ms): `/feed/explore`
  7,0/10,0, `/feed/following` 4,8/7,1, like 8,7/10,5, views 6,8/9,5, `POST /videos` 12,9/14,4, web `/` 42,7/53,5, `/v/[id]` 47,0/64,2,
  `/login` 34,2/41,2. Số của runner, không so với máy.
- **`drill-alert-to-sentry`:** đạt, T1 − T0 = 53,4 s, T4 − T1 = 4,4 s (< 300 s), 4 event GlitchTip từ T0; Telegram SKIP (không
  secret). Lượt này in giờ trống ở các mốc vì `date -r` của BSD (trên GNU là đọc mtime của tệp); đã đổi sang cách chạy được cả hai nơi.
- **D17 LCP:** không đo được: Lighthouse mở Chromium của Playwright với sandbox, Ubuntu 24.04 chặn user namespace không đặc quyền
  bằng AppArmor nên Chrome dừng "No usable sandbox" ở cả 3 lượt. Đã sửa ở `verify-host.sh` (mục 3, job `compose`); chờ lượt 2.
- **Đĩa:** dùng 12,7 GiB, `need` của `compose-obs` đổi 15 → 16 GiB (mục 2).

### `compose-obs`, lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276))

- **Runner:** như lượt 1 (kernel 6.17.0-1022-azure, 4 CPU, swap 3 GiB). CPU bận cao nhất 100 %, MEM USAGE của stack compose cao nhất
  2 903 MiB. `make up OBS=lgtm` 342 s, `make smoke` 13 s. `verify-host.sh` in `kernel.apparmor_restrict_unprivileged_userns 0`.
- **D8 `drill-obs-threats`:** đạt mọi mục: JWT-8, UP-8, OPS-1, RL-2 (page `startsAt` 88 s, thấy 91 s sau login đầu), WEB-9 (đối chứng
  có dữ liệu của web ở GlitchTip 1 event, Tempo 18 trace, Prometheus 216 series; Loki 49 dòng của các service Go, web chỉ log ra stdout; không giá trị nào
  của form, phiên hay chữ ký trong cả bốn).
- **D16:** không page trên runner lần nữa: không cảnh báo nào bắt đầu trong 484 s (50 lần hỏi, 0 lỗi), p99 lệnh Redis 4,95 ms, không
  `context_timeout`, 0 quyết định dự phòng trên 8 176.
- **`make load-local`:** mọi threshold đạt, 7 625 check, 0 lỗi, `dropped_iterations` 0; p95 `/feed/explore` 7,0 ms, `/feed/following`
  4,5 ms, web `/` 40,4 ms, `/v/[id]` 45,5 ms, `/login` 31,3 ms.
- **`drill-alert-to-sentry`:** đạt, T0 21:51:01Z, T1 − T0 = 54,5 s, T4 − T1 = 3,4 s (< 300 s); giờ các mốc in đúng trên GNU.
- **D17 LCP:** không đạt. `/`: 3 510, 3 253, 2 760 ms, median 3 253 ms (> 2 500); `/v/{id}`: 2 256, 1 952, 2 182 ms, median 2 182 ms
  (đạt). `benchmarkIndex` 1 942–2 040. TBT 334–417 ms ở cả sáu lượt (ngưỡng 200 ms), CLS ≤ 0,069. Theo D17, đòn bẩy (a) của ADR-0020
  ("render trang đầu không qua `Suspense`") thành việc code riêng sau phần 1.
- **Đĩa:** dùng 12,5 GiB, `need` 16 GiB giữ.

### `dev-k3d`, lượt 1 ([40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651))

- **Tới đâu:** cluster tạo trong 21 s, bảy image build và push, wave 0–3 cài tới `plugin-barman-cloud`; `helm upgrade --install
  redpanda` báo `StatefulSet/svp-data/redpanda not ready … 1 pods have failed` khoảng 2,5 phút sau khi pod được tạo, `make k8s-up`
  dừng sau 553 s. Mười ba bước sau đỏ theo (không có Valkey, Tempo; hai bước RAM nghỉ chờ hết 900 s).
- **Pod `redpanda-0`:** hai init container xong, container `redpanda` vào `CrashLoopBackOff` với 11 lần restart trong 34 phút; 4 lần
  khởi động trong chừng hai phút đầu, tức thoát ngay sau mỗi lần chạy (sampler chưa lần nào đọc được RAM của nó). Không `OOMKilled`, kernel
  không có dòng OOM nào. Sidecar chạy, readiness trả 500 vì broker không trả lời.
- **Nguyên nhân: chưa biết.** Lượt không giữ log container, log job chỉ có dòng của Helm. Cùng image broker chạy được ở `compose-obs`
  trên cùng loại runner; broker của chart khác ở ba chỗ: `rpk redpanda start` có kiểm hệ thống (compose đặt `--check=false`),
  `--memory=1024M --reserve-memory=202M` trong limit 1 280 MiB (compose `--memory=1G` trong 1 536 MiB), và `crash_loop_limit: 5`
  (sau 5 lần thoát không êm trong một giờ broker không khởi động nữa, nên các lần restart sau chỉ lặp lại). Đã loại theo mã nguồn
  Seastar và rpk 26.2: giới hạn AIO (một shard tối thiểu cần 1 027 khối điều khiển, mặc định của kernel là 65 536, thiếu thì
  Seastar tự giảm phần mạng), thư mục dữ liệu (local-path tạo `0777`).
- **Đã đổi:** khi một release không Ready, `deploy/k8s/install.sh` in trạng thái, lần thoát trước và 40 dòng log cuối (cả của lần
  chạy trước khi đã restart) của mọi container chưa Ready trong namespace của release, vào log `k8s-up` của artifact (qua bộ lọc như
  mọi log khác). Lượt 2 sẽ cho thấy lỗi của broker.

### `dev-k3d`, lượt 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975))

- **Tới đâu:** như lượt 1: wave 0–3 cài tới `plugin-barman-cloud`, release `redpanda` không Ready, `make k8s-up` dừng sau 558 s, mười
  ba bước sau đỏ theo; `redpanda-0` 11 lần restart trong 34 phút. `MemAvailable` thấp nhất 10 877 MiB, swap 0, đĩa dùng 14,3 GiB
  (trống 80,4 GiB lúc vào kịch bản, thấp nhất 66,1 GiB), 41 lần đọc event (0 lỗi), 0 pull bị từ chối 429. MEM USAGE của k3d cao nhất
  3 872 MiB là của cluster dừng ở wave 3, không phải số RAM của D2, D9.
- **Nguyên nhân** (log mà `install.sh` in): kiểm hệ thống của rpk qua (chỉ lỗi không chặn), rồi `redpanda --overprovisioned
  --memory=1024M --reserve-memory=202M --smp=1` dừng với `Could not initialize seastar: std::runtime_error (insufficient physical
  memory: needed 1073741824 available 1061158912)`. Theo `calculate_memory` của Seastar (bản của Redpanda, nhánh `v26.2.x`,
  `src/core/resource.cc`), bộ nhớ dùng được là min(RAM máy, `memory.max` của cgroup) − `vm.min_free_kbytes` − `--reserve-memory`,
  và phải ≥ `--memory`. `vm.min_free_kbytes` không theo namespace: container thấy số của kernel máy. Trên runner: 1 280 − 66 − 202 =
  1 012 MiB (1 061 158 912 B) < 1 024 MiB, tức `vm.min_free_kbytes` = 67 584 kB (suy từ số của lỗi; `verify-host.sh` in số này từ
  lượt 3). Trên máy (VM arm64 của Docker Desktop, đọc trong một container): 45 056 kB, nên 1 280 − 44 − 202 = 1 034 MiB, qua với dư
  10 MiB. Hai số đúng bằng mức kernel tự đặt khi transparent huge pages bật (`[always]` ở máy): 22 528 kB mỗi vùng nhớ (2 + 9
  pageblock 2 MiB); x86_64 có 3 vùng (DMA, DMA32, Normal), VM arm64 có 2. Với cách chart tự tính (`--reserve-memory` = 0,2 % limit +
  200 MiB), node Linux x86_64 bật THP như runner gặp lại lỗi này ở limit 1 280 MiB, cả node cloud của giai đoạn 7. Broker compose chạy được
  trên cùng runner với limit 1 536 MiB.
- **Đã đổi:** `deploy/k8s/values/redpanda.yaml` đặt `resources.memory.redpanda.memory: 1Gi`, `reserveMemory: 128Mi` thay cho cách
  chart tự tính: cờ sinh ra `--memory=1024M --reserve-memory=128M`, limit và request của pod giữ 1 280 MiB (bảng RAM của ADR-0014
  không đổi); `helm template` của chart 26.2.4 trước và sau chỉ khác đúng dòng `--reserve-memory`. Còn 128 MiB cho
  `vm.min_free_kbytes`, gần gấp đôi số của runner. Ngoài phép kiểm lúc khởi động, Redpanda chỉ ghi `--reserve-memory` vào log
  (`src/v/redpanda/application_config.cc`): broker vẫn lấy 1 024 MiB, phần ngoài Seastar trong limit vẫn 256 MiB. Không chọn: hạ
  `vm.min_free_kbytes` của runner ở `verify-host.sh` (giấu lỗi mà node x86_64 nào cũng gặp), hay nâng limit lên ít nhất 1 344 MiB cho
  công thức của chart đủ chỗ (đổi ngân sách RAM của ADR-0014 §2). Checksum cấu hình trên pod không gồm cờ khởi động, nên cluster đang
  chạy trên máy không restart broker khi `make k8s-up`; cờ mới có hiệu lực ở lần broker khởi động sau.

### `dev-k3d`, lượt 3 ([40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978))

- **Tới đâu:** `verify-host.sh` in `vm.min_free_kbytes 67584 kB`; release `redpanda` Ready (sửa của lượt 2 đúng). Wave 0–6 và năm release
  đầu của wave 7 (`user-service`, `video-service`, `engagement-service`, `feed-service`, `media-worker`) cài xong; release `gateway`
  cài, rồi `wait_rollout` chờ hết 900 s với Rollout ở `step 0, weight 0%, phase Progressing`, không AnalysisRun, `make k8s-up` dừng
  sau 1 926 s; release `web` (sau `gateway`) chưa cài. Mười ba bước sau đỏ theo: `readyz within 60s` (smoke, threats, KEDA, hai lượt
  backup), PDB không thấy pod gateway, canary từ chối Rollout chưa Healthy, `/login` 404, global setup của e2e. Hai lượt
  `drill-k8s-backup` vẫn khôi phục Cluster `svp-pg` vào thế hệ mới tới Ready và restart năm service, chỉ smoke sau khôi phục đỏ
  (chưa có RTO). Hai bước RAM nghỉ qua, nhưng là RAM của cluster thiếu gateway, web (2 818 MiB pod lúc đầu), không phải số của D2, D9.
- **Nguyên nhân** (event của artifact, mã nguồn Argo Rollouts `v1.10.1`): event của `rollout/gateway` chỉ có `NewReplicaSetCreated`
  (`gateway-658c5d88cf`, revision 1) và `RolloutNotCompleted`; HPA đặt 2 replica; ReplicaSet không có event nào (không
  `FailedCreate`, nên không phải PSA hay Kyverno), không event `ScalingReplicaSet`. Trong `rolloutCanary` (`rollout/canary.go`),
  `reconcileTrafficRouting` chạy trước `reconcileCanaryReplicaSets`: lỗi của nó trả về trước khi ReplicaSet được scale, và controller
  chỉ ghi lỗi đó vào log của nó, không vào event. Bước traffic routing khởi động plugin bằng `exec.Command` (go-plugin,
  `rollout/trafficrouting/plugin/client/client.go`). `deploy/k8s/values/argo-rollouts.yaml` ghim asset
  `gatewayapi-plugin-linux-arm64` (`file`: ELF ARM aarch64) cho node arm64 của máy; node của runner là amd64 (`kubernetes.io/arch=amd64`),
  nên plugin không chạy được. Controller vẫn Running, 0 restart: plugin chỉ được tải lúc khởi động (sha256 khớp), chạy ở lần reconcile
  đầu có canary.
- **Đã đổi:** `deploy/k8s/install.sh` (`rollouts_plugin_sets`) đọc kiến trúc của node; trên amd64 truyền
  `--set-json controller.trafficRouterPlugins=[…]` với asset `gatewayapi-plugin-linux-amd64` cùng release `v0.17.0`, sha256
  `1904ca78…9061` (khớp digest asset GitHub trả và `shasum -a 256` của file tải về; cùng số ở bảng của ADR-0014 §13); node arm64
  không nhận cờ nào, release cài như trước. `helm template` của chart 2.43.8 có cờ chỉ khác đúng `location`, `sha256` trong
  ConfigMap `argo-rollouts-config` và checksum của nó trên pod (controller restart khi cấu hình đổi). File values phải ghim đúng asset
  arm64 của cùng release, không thì `make k8s-up` dừng, nên hai ghim không lệch nhau khi đổi release. Đường GitOps cài file values
  như nó là: cluster GitOps trên runner amd64 (phần 3) cần chọn asset theo kiến trúc ở đó.
- **Số khác:** đĩa dùng 22 GiB (trống 81 GiB lúc vào kịch bản, thấp nhất 59,1 GiB); MEM USAGE của k3d cao nhất 7 698 MiB (cluster
  thiếu gateway, web, không tải); 59 lần đọc event (0 lỗi), 0 pull bị từ chối 429. Plugin Barman Cloud 24 MiB, sidecar của nó trong
  pod Postgres 78 MiB, dưới limit 256 Mi (D19 chưa kết luận: cluster chưa đủ).

### `dev-k3d`, lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985))

- **Tới đâu:** `make k8s-up` 1 109 s: `ok    Argo Rollouts gets the Gateway API plugin built for amd64 nodes`, mọi wave cài xong,
  `rollout gateway Healthy`, `rollout web Healthy` (sửa của lượt 3 đúng). `make k8s-smoke` 58 bước, 11 s. Mọi bước sau đạt trừ
  `drill-k8s-threats`. Không pod nào restart suốt kịch bản (`RESTARTS` 0 ở `k8s-status.txt` lúc cuối); event probe duy nhất của
  gateway, web là một lần readiness `connection refused` lúc mỗi pod vừa khởi động.
- **D2 RAM nghỉ, đường dev** (cách đo của mục 2): ở điểm 60 s (00:32:27Z–00:33:17Z) MEM USAGE trung vị 8 121,5 MiB (6 mẫu 8 071–8 167),
  `active_file` của hai node 1 334 + 703 MiB, MEM USAGE trừ `active_file` **6 084 MiB** (dưới 6,5 GiB = 6 656 MiB), tổng pod
  **3 163 MiB** (dưới 4,7 GiB; `svp-obs` 1 427, `svp-data` 644, `svp` 318, `kyverno` 165, `cert-manager` 152, `keda` 120,
  `envoy-gateway-system` 106, `argo-rollouts` 93, `kube-system` 76, `cnpg-system` 62): **(b) đạt cho đường dev**. Cuối kịch bản
  (01:19:02Z, sau mọi diễn tập): 8 495 MiB, trừ `active_file` 6 598 MiB (dưới ngưỡng 58 MiB), pod 3 712 MiB: (b) vẫn đạt. Hiệu ứng
  "(b) chỉ đạt sau 70–90 phút" của máy không lặp lại: trên runner (b) đạt ngay ở điểm 60 s, rồi tăng sau diễn tập. MEM USAGE nghỉ
  (8,1 GiB) cao hơn số của máy vì page cache: runner không có áp lực bộ nhớ (`free -m` lúc nghỉ: buff/cache 8 933 MiB, available
  8 740 MiB). Ngoại lệ arm64 của mục 1 không mở: ở điểm 60 s, số (b) 5,94 GiB nằm ngoài 6,2–6,8 GiB. Kết luận chỉ cho đường dev;
  "Còn mở: RAM (b)" của roadmap và ADR-0017 là của đường GitOps (phần 3).
- **D9 RAM đỉnh, cluster có web:** trung vị 6 mẫu liền có 2 worker cao nhất **9 994 MiB** (cửa sổ từ 00:53:53Z), mẫu cao nhất
  10 040 MiB: vượt 8,7 GiB (8 909 MiB), **(a) không đạt** cho đường dev trên runner. Ngưỡng đỉnh tính cả page cache (ADR-0014 §2),
  và trên runner kernel không phải thu page cache; lượt không đọc `memory.stat` lúc đỉnh, nên không tách được phần page cache của
  đỉnh (ở hai điểm nghỉ, `active_file` của hai node 2 037 và 1 897 MiB). Như quy tắc (b) của mục 2, ADR này không quyết trước:
  người học chọn cắt theo thứ tự của ADR-0014 §2 (việc riêng, đo lại trên runner) hay ghi nhận (chốt: ghi nhận, lượt 5). Cách đếm "2 worker" của `ram-peak` là
  số pod media-worker `Running` (73 mẫu, 63 cửa sổ); từ 00:51 tới 00:53 hai pod `Running` mà chỉ một transcode (pod kia khoảng 1m
  CPU). Cửa sổ đỉnh của lượt này nằm trong khoảng hai worker cùng transcode thật (dòng KEDA dưới đây).
- **KEDA, đường dev** (một lượt; D1 cần hai lượt trên GitOps): `drill-k8s-keda N=9` PASS. Lên 2 replica 7,0 s sau `CompleteUpload`
  đầu, mỗi pod một partition sau 123 s; lag đỉnh 9 (KEDA đưa HPA 3); ghim 1 replica 127,3 s sau `CompleteUpload` đầu làm pod đang
  transcode v5 dừng, pod khác làm lại, `READY` 136,4 s sau SIGTERM; 9 video `READY` sau 459,2 s, mỗi video đúng một
  `transcode.completed` và một `video.ready`; về 1 replica 299,7 s sau `READY` cuối. Hai worker cùng transcode từ 00:53:53Z tới
  00:56:10Z (14 mẫu 10 s liền, CPU của cả hai node 130–240 %; `kubectl top` 5 mẫu 30 s liền, mỗi pod 1 338–1 990m). Một worker đỉnh
  CPU 1 993m (limit 2 000m), RAM 723 MiB; mọi worker cùng lúc 1 376 MiB. (c) giữ: `k3d-svp-server-0` `RestartCount` 0, `StartedAt`
  không đổi suốt kịch bản; không node `NotReady` ở mẫu nào; không event probe lỗi nào trong khoảng hai worker cùng transcode (các
  event `Unhealthy` của lượt đều lúc pod khởi động hay trong hai diễn tập backup); CPU bận của máy runner tới 99 %. Khác máy (node
  server đứng khoảng 40 s với 2 worker, ADR-0017), k3s đứng được khi 4 vCPU bão hoà.
- **D18 canary gateway dưới probe mới:** `drill-k8s-canary` PASS. Bản tốt qua 25 %, 50 %, 100 %, promote 129,9 s sau upgrade, hai
  AnalysisRun Successful, 0 trên 1 788 request của traffic diễn tập là 5xx trong lúc đó; bản lỗi (`FEED_SERVICE_ADDR` trỏ Service
  không có) bị phân tích abort 88,0 s sau khi canary nhận traffic (`canary-5xx-ratio` Failed 2 > `failureLimit` 1), HTTPRoute `api`
  về 100/0, pod stable cùng UID, 0 restart; trả bản tốt, Rollout Healthy 1,1 s. Phía client: 949 request feed, 287 là 5xx, 0 401/429.
  p99 của backend stable trong 5 phút trước canary 490 ms dưới traffic diễn tập (số của runner; phân tích fail canary ở 150 ms, p99
  canary đo được 244 và 180 ms ở bản lỗi). Lịch abort in `date: …: No such file or directory` thay giờ (`date -r` của BSD trong
  `hms`), đã sửa.
- **Web (ADR-0019, đường dev):** `make k8s-web-sourcemaps`: 32 source map của build `dev-e621db23f0bf`, 15 chunk của `/login` có debug
  ID đều thuộc build đó, 31 file tải lên. `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e`: 64/64 (chromium 29, webkit 29,
  chromium-publishing 3, webkit-publishing 3; 7,7 phút). `make drill-k8s-web-obs`: PASS cả ba: trace có span của `web` 19, gateway 8,
  user-service 6, feed-service 6, engagement-service 3; RUM LCP p75 0,57 s (64 mẫu; `/` 0,93 s, `/v/[id]` 0,85 s), CLS p75 0,0075 (19
  mẫu), INP p75 35 ms (28 mẫu); event GlitchTip của chromium 10/10 frame, webkit 13/13 frame map về mã nguồn của web.
- **D20 backup** (số của runner): `latest`: RTO 95,2 s, RPO ít nhất 63,2 s (không dòng đánh dấu nào trở lại: không ép đổi WAL, bản
  khôi phục dừng ở WAL lưu cuối 01:05:20Z, dòng đầu ghi 01:05:24Z). `pitr`: RTO 80,8 s, RPO 38,1 s (30/60 dòng giữ, dòng mới nhất
  0,5 s trước mục tiêu, không dòng nào sau mục tiêu). Cả hai lượt khôi phục `svp-pg` vào thế hệ mới, restart một lần bốn service có
  Postgres và GlitchTip, smoke sau khôi phục qua; xoá Cluster và PVC mất khoảng 187 s mỗi lượt.
- **D19:** plugin Barman Cloud cao nhất 26 MiB, sidecar của nó trong pod Postgres 71 MiB: dưới limit 256 Mi; cluster theo D2: (b)
  đạt. **Đạt** cho đường dev.
- **`resources` của web** (quy tắc mục 8, số của `dev-k3d`): working set mỗi pod 88–90 MiB ở điểm nghỉ 60 s, 136–137 MiB ở điểm nghỉ
  cuối, cao nhất 144 MiB (00:45:15Z, trong `k8s-web-e2e`); CPU cao nhất 101m (e2e), nghỉ 2–3m. Limit bộ nhớ = max(384 Mi, bội 64 Mi
  làm tròn lên của 1,5 × 144 = 216 Mi, tức 256 Mi) = **384 Mi**; request bộ nhớ = bội 32 Mi làm tròn lên của trung vị lúc nghỉ (bốn
  số của hai điểm nghỉ: 88, 89, 136, 137 MiB, trung vị 112,5 MiB), tối thiểu 128 Mi = **128 Mi**; limit CPU giữ 1 (throttle đo ở phần 3
  với k6), request CPU giữ 100m. Giữ nguyên giá trị, comment của `deploy/k8s/values/services/web.yaml` ghi số; phần 3 áp lại với số
  k6 (chỉ tăng).
- **D7 `drill-k8s-threats`: chưa kết luận.** Drill chạy 232 s, exit 2 (ít nhất một mục FAIL). Dòng phán quyết của nó không tới
  artifact: bộ lọc bỏ cả file với luật `session-cookie`, vì câu `ok` của mục WEB-7 nêu tên cookie `__Host-Http-svp_sid` (tên, không
  phải giá trị); log job chỉ có dòng kết quả của target. Mục 4 chọn bỏ file khi nghi, nên lượt này không cho biết mục nào đỏ. Đã sửa
  bộ lọc (Kiểm chứng sau, dòng bộ lọc); chờ lượt 5.
- **Số khác:** đĩa dùng 23,8 GiB (trống 80,4 GiB lúc vào kịch bản, thấp nhất 56,6 GiB), `need` 30 GiB giữ; setup 1 phút 51 s;
  67 lần đọc event (0 lỗi), 0 pull 429; log job có `mask-check: ***`, không dòng `::add-mask::`, không mẫu bí mật nào trong log và
  artifact.

### `dev-k3d`, lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243))

- **Tới đâu:** `make k8s-up` 1 037 s (plugin amd64, `rollout gateway Healthy`, `rollout web Healthy`), `make k8s-smoke` 58 bước,
  12 s; 13 trên 14 bước đạt, chỉ `drill-k8s-threats` đỏ. Không pod nào restart suốt kịch bản (`k8s-status.txt`). Setup 1 phút 28 s
  (01:38:49 → 01:40:17 UTC).
- **D7 `drill-k8s-threats`: chưa kết luận.** Bảng cuối có trong artifact: IN-2/IN-4, IN-4/FF-6, FF-5, FF-3/FF-4, IN-9, RBAC, OPS-1,
  OPS-2, WEB-2, WEB-10, WEB-13, RL-1, WEB-8, PSA-platform, BAK-1 PASS; WEB-7 FAIL. Mọi dòng của WEB-7 là `ok` (17 đường ngoài danh
  sách của BFF đều 400 hay 404, hay 307 của Envoy về đường cùng origin đã bỏ `%2F`, rồi 404; hai đối chứng `/api/feed/explore`,
  `/api/me` 200), rồi mục dừng mà không in `FAIL` nào. Nguyên nhân: lệnh kế là `i=$((i + 1))` với `i` khai `local` không giá trị.
  Bash 3.2 của macOS gán `""` cho biến đó (`declare -p` in `i=""`), nên drill chạy được trên máy; từ bash 4.0 biến khai không giá
  trị là chưa đặt (CHANGES của bash-4.0-beta: "Fixed a bug that caused local variables to be created with the empty string for a
  value rather than no value"), và dưới `set -u` mở rộng số học của tên chưa đặt dừng subshell của mục (bash 3.2 cũng dừng như vậy
  với một tên chưa đặt: `x: unbound variable`). Dòng lỗi của bash không phải dòng phán quyết nên bộ lọc bỏ (đúng ý), và `run_item`
  của drill k3d không in gì khi mục dừng. Lượt 4 đỏ exit 2 ở cùng drill, cùng code: rất có thể cùng nguyên nhân (dòng phán quyết
  của lượt đó đã mất). **Đã sửa:** `i=0` ở khai báo; `run_item` in thêm `FAIL  <mục>: the item ended with exit status <n>` khi mục
  đỏ, như drill compose từ lượt `compose-obs` 1. Đã dò các script diễn tập và cài đặt của hai kịch bản tìm biến `local` không giá
  trị bị đọc trước khi gán: không còn chỗ nào khác. Phần sau của WEB-7 (HTML bốn trang, hai payload RSC, tìm token) chưa chạy
  trên runner; chờ lượt 6, chỉ `k8s-smoke` và `drill-k8s-threats` (`targets`, mục 3; drill cần video `READY` của smoke).
- **D2 RAM nghỉ, đường dev** (lượt hai): ở điểm 60 s (01:58:58Z–01:59:48Z) MEM USAGE trung vị 7 758,5 MiB, `active_file` của hai node
  528 + 1 258 MiB, MEM USAGE trừ `active_file` **5 972 MiB**, tổng pod **3 024 MiB** (`svp-obs` 1 369, `svp-data` 611, `svp` 295):
  **(b) đạt** lần hai. Cuối kịch bản (02:47:09Z, sau hai lượt khôi phục Postgres): trung vị 7 385 MiB, trừ `active_file`
  **6 752 MiB**, trên 6,5 GiB 96 MiB; pod 3 806 MiB (dưới 4,7 GiB; `svp-obs` 1 810, `svp-data` 801, `svp` 419). Quy tắc (b) của mục
  2 áp ở điểm 60 s, nên kết luận giữ; điểm cuối cho thấy cluster lớn dần qua các diễn tập (lượt 4: 6 598 MiB) trong khi page cache bị
  thu (`active_file` hai node 634 MiB thay 1 786 MiB lúc đầu).
- **D9 RAM đỉnh:** `ram-peak.json` ghi trung vị 9 037 MiB (cửa sổ từ 02:20:07Z), nhưng trong cửa sổ đó chỉ một worker transcode:
  `ram-peak` coi mẫu có hai pod media-worker `Running` là hai worker cùng transcode (80 mẫu), còn theo CPU hai worker cùng transcode
  chỉ từ 02:20:58Z tới 02:22:15Z (8 mẫu 10 s liền, CPU của mỗi node 127–219 %; `kubectl top` 02:21:20Z–02:22:25Z mỗi pod
  1 377–1 513m; trước đó và sau đó một pod 1m). Theo định nghĩa của mục 2 (6 mẫu liền trong khi 2 worker cùng transcode): trung vị
  cao nhất **8 878 MiB** (cửa sổ từ 02:20:58Z), dưới 8 909 MiB 31 MiB; mẫu cao nhất 9 822 MiB (02:20:58Z, lúc worker thứ hai vừa
  vào). Hai lượt: 9 994 MiB (lượt 4, cửa sổ nằm trong khoảng hai worker cùng transcode thật) và 8 878 MiB: **(a) không đạt ổn
  định** cho đường dev. **Chốt ngày 2026-10-25: không đạt theo ngân sách của laptop, chấp nhận, không cắt.** Ngân sách 8,7 GiB là
  của Docker VM 9,7 GiB trên laptop, nơi k3d nặng không còn chạy (đo trên runner hay cloud); trên runner `MemAvailable` thấp nhất
  vẫn từ 6 172 MiB trở lên, và MEM USAGE tính cả page cache. Xem lại khi chọn cỡ node ở giai đoạn 7. Cách đếm worker của `ram-peak` phải theo việc transcode thật trước kịch bản `gitops` (D1 đếm "≥ 6 mẫu liền 2
  worker cùng transcode"): đã đổi ngày 2026-10-25, sampler đếm pod có tiến trình `ffmpeg` (mục 2), đếm đúng trên runner ở lượt 7.
- **KEDA, đường dev** (lượt hai): `drill-k8s-keda N=9` PASS. 2 replica 7,8 s sau `CompleteUpload` đầu, mỗi pod một partition sau
  133,0 s, ghim 1 replica 139,1 s sau `CompleteUpload` đầu làm pod đang transcode v8 dừng, pod khác làm lại, `READY` 146,4 s sau
  SIGTERM; 9 video `READY` sau 533,3 s, mỗi video đúng một `transcode.completed` và một `video.ready`; về 1 replica 300,3 s sau
  `READY` cuối. Vì pod thứ hai chỉ nhận partition ngay trước lúc ghim, hai worker cùng transcode chỉ khi pod thay vào: khoảng 80 s
  (8 mẫu), thay 137 s (14 mẫu) ở lượt 4. (c) giữ: `k3d-svp-server-0` `RestartCount` 0, `StartedAt` không đổi suốt kịch bản, không node
  `NotReady`; CPU bận của máy runner tới 99 %.
- **D18 canary gateway** (lượt hai): PASS. Bản tốt promote 124,2 s sau upgrade; bản lỗi bị phân tích abort 87,3 s sau khi canary nhận
  traffic (`canary-5xx-ratio` Failed 2 > `failureLimit` 1), HTTPRoute `api` về 100/0, pod stable cùng UID, 0 restart; trả bản tốt,
  Rollout Healthy 1,6 s. Phía client 941 request feed, 276 là 5xx, 0 401/429; p99 backend stable 5 phút trước canary 480 ms. Lịch
  abort in giờ đúng trên GNU `date` (sửa `hms` của lượt 4 đúng).
- **Web:** `make k8s-web-sourcemaps` 32 source map của build `dev-e621db23f0bf`, 15 chunk `/login` có debug ID thuộc build đó;
  `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` 64/64 (chromium 29, webkit 29, chromium-publishing 3, webkit-publishing 3; 7,8 phút);
  `make drill-k8s-web-obs` PASS cả ba (RUM LCP p75 0,575 s trên 64 mẫu, CLS p75 0,0075, INP p75 44 ms; GlitchTip chromium 10/10,
  webkit 13/13 frame map về mã nguồn). `resources` của web: working set 85–89 MiB ở điểm 60 s, 138–139 MiB ở điểm cuối, cao nhất
  144 MiB (02:12:04Z, trong e2e), CPU cao nhất 155m (lúc smoke): theo quy tắc mục 8 vẫn limit 384 Mi, request 128 Mi (trung vị tám
  số nghỉ của hai lượt 112,5 MiB); giữ.
- **D20 backup** (số của runner): `latest` RTO 92,8 s, RPO ít nhất 63,4 s (không dòng đánh dấu nào trở lại, không ép đổi WAL); `pitr`
  RTO 84,3 s, RPO 36,1 s (30/60 dòng giữ, dòng mới nhất 0,5 s trước mục tiêu, không dòng nào sau mục tiêu).
- **D19:** plugin Barman Cloud cao nhất 31 MiB, sidecar của nó 67 MiB: dưới limit 256 Mi.
- **Số khác:** đĩa dùng 23,8 GiB (trống 80,4 GiB lúc vào kịch bản, thấp nhất 56,6 GiB); 68 lần đọc event (0 lỗi), 0 pull 429; Redpanda
  0 restart trong 62 phút, container `redpanda` cao nhất 361 MiB; log job có `mask-check: ***`, không dòng `::add-mask::`, không mẫu
  bí mật nào trong log và artifact.

### `dev-k3d`, lượt 6 ([40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740))

- **Phạm vi:** lượt chọn bước đầu (`targets='k8s-smoke drill-k8s-threats'`; drill cần video `READY` của smoke): `k8s-up` luôn chạy,
  11 bước kia ghi `skipped` với `not in targets`, giữ số thứ tự (log `04-drill-k8s-threats`), lượt xanh. Job 24 phút, thay khoảng 80
  phút của lượt đủ kịch bản. Setup 1 phút 30 s (03:20:22 → 03:21:52 UTC).
- **Tới đâu:** `make k8s-up` 1 083 s (plugin amd64, `rollout gateway Healthy`, `rollout web Healthy`), `make k8s-smoke` 58 bước, 12 s.
- **D7 `drill-k8s-threats`: đạt.** 242 s, 16/16 mục PASS (IN-2/IN-4, IN-4/FF-6, FF-5, FF-3/FF-4, IN-9, RBAC, OPS-1, OPS-2, WEB-7,
  WEB-2, WEB-10, WEB-13, RL-1, WEB-8, PSA-platform, BAK-1), 354 dòng `ok`, không dòng `FAIL`, `SKIP`, `WARN` nào; drill tự dò log của
  nó không thấy giá trị Secret nào trong 10 giá trị đã đọc. WEB-7 lần đầu chạy hết trên runner: 17 đường ngoài danh sách của BFF đều
  400, 404 hay 307 của Envoy về đường cùng origin rồi 404; HTML của `/`, `/me`, `/upload`, `/u/<handle>`, payload RSC của `/` và
  `/me`, JSON của `/api/feed/explore`, `/api/me` không có chuỗi dạng JWT hay token, sid của phiên; đối chứng: cùng phép tìm thấy JWT
  trong câu trả lời login của gateway.
- **Số khác:** đĩa trống thấp nhất 59,5 GiB, MEM USAGE của k3d cao nhất 7 518 MiB (không có tải nào ngoài smoke, drill); 23 lần đọc
  event (0 lỗi), 0 pull 429; log job có `mask-check: ***`, không dòng `::add-mask::`, không mẫu bí mật nào trong log và artifact.

### `dev-k3d`, lượt 7 ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327))

- **Phạm vi:** `targets='drill-k8s-keda ram-peak'`, lượt đầu của cách đếm worker mới (pod có tiến trình `ffmpeg`, mục 2) và của bước
  kiểm ref theo `$GITHUB_EVENT_NAME:$GITHUB_REF` (qua với `workflow_dispatch` trên nhánh). Job 31 phút, setup 1 phút 26 s
  (04:02:24 → 04:03:50 UTC), `make k8s-up` 1 028 s.
- **KEDA, đường dev** (lượt ba): `drill-k8s-keda N=9` PASS, 690 s. 2 replica 13,9 s sau `CompleteUpload` đầu, mỗi pod một partition
  sau 86,2 s, ghim 1 replica 89,5 s sau `CompleteUpload` đầu làm pod đang transcode v1 dừng, pod khác làm lại, `READY` 80,7 s sau
  SIGTERM; 9 video `READY` sau 376,8 s, mỗi video đúng một `transcode.completed` và một `video.ready`; về 1 replica 294,4 s sau `READY`
  cuối. (c) giữ: `k3d-svp-server-0` `RestartCount` 0, `StartedAt` không đổi ở cả 170 mẫu, không node `NotReady`.
- **Không có khoảng hai worker cùng transcode.** `READY` cách nhau đều khoảng 42 s (42,6; 84,8; 129,0; 170,5; … 376,6 s): từng video
  một. Partition của từng video, tính lại từ id bằng `kafka_partition` của `deploy/k8s/drills/lib.sh`: partition 0 có 4 video (v1,
  v3, v4, v9), partition 1 có 2 (v5, v7), partition 2 có 3 (v2, v6, v8); lượt 4 và lượt 5 đều 3/3/3. Pod đầu làm v2, v6 (partition 2)
  rồi v1; pod thứ hai nhận partition 2 khi chỉ còn v8; sau lúc ghim, pod thay vào nhận partition 0 và 1 (sáu video), còn pod kia giữ
  partition 2 đã hết việc (`kubectl top` 1m từ 04:24:23Z). Lượt 4 và lượt 5 cũng vậy: pod còn lại giữ partition nó nhận ở lần chia
  đầu, pod thay vào nhận hai partition kia; khoảng hai worker cùng transcode chỉ kéo dài khi partition của pod còn lại còn video
  (lượt 4: hai video, 137 s; lượt 5: một, 80 s; lượt 7: không video nào). Diễn tập không bảo đảm khoảng này, nên dòng D1 của phần 3
  (mỗi lượt ≥ 6 mẫu liền) có thể trượt vì cách chia partition chứ không vì runner.
- **Đếm worker đúng** (dòng Kiểm chứng sau): 69 mẫu trong diễn tập (04:20:59Z–04:32:29Z), 64 mẫu có hai pod `Running`; cột worker
  transcode là 1 ở 36 mẫu, 2 ở một mẫu (04:22:41Z, vài giây giữa lúc pod thứ hai nhận partition và lúc ghim), 0 từ 04:27:35Z. Mỗi
  mẫu có node trên 150 % CPU đều đếm ít nhất 1 worker. Ba pod transcode lần lượt (pod đầu và pod thay vào ở node server, pod thứ hai
  ở agent) đều được đếm, nên khớp UID trong cgroup đúng ở cả hai node.
- **`memory.stat`:** đọc được ở cả 170 mẫu có cluster; trong diễn tập `anon` 4 604–5 895 MiB, `active_file` 1 420–1 761 MiB, `kernel`
  474–509 MiB (hai node cộng lại).
- **D9 RAM đỉnh:** không có cửa sổ 6 mẫu nào nên không có số đỉnh (a) ở lượt này (đúng định nghĩa của mục 2); mẫu cao nhất 8 175 MiB
  (04:22:31Z, một worker transcode, `active_file` 1 761 MiB). `verify-sample.sh peak` chạy lại trên macOS với `docker.tsv` của
  artifact cho đúng `ram-peak.json` đó.
- **Số khác:** MEM USAGE của k3d cao nhất 8 175 MiB, web cao nhất 104 MiB (lượt không có e2e), `redpanda` 322 MiB, media-worker
  675 MiB (limit 2 048 MiB); 29 lần đọc event (0 lỗi), 0 pull 429; artifact giữ 20 tệp, bỏ 3 `not-allowed` (`job-start`,
  `sampler.pid`, `sampler.err`), không `::warning::`, không annotation; log job có `mask-check: ***` một lần, không dòng
  `::add-mask::`, không mẫu bí mật nào trong log và artifact.

### Phần 1 theo dòng dời

Kết quả của các dòng phần 1 ở mục 5 có kịch bản trên runner (D10, D21 kiểm ở CI; D15 là phần 2).

| # | Kết quả | Lượt, số |
| --- | --- | --- |
| D1 (đường dev) | Đạt hai lượt (4, 5); lượt 7 PASS mà không có khoảng hai worker cùng transcode (cách chia partition, không vì runner); D1 là của đường GitOps (phần 3) | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): `drill-k8s-keda N=9` PASS, hai worker cùng transcode 137 s, (c) giữ; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): PASS, hai worker cùng transcode khoảng 80 s (8 mẫu), (c) giữ. Khoảng hai worker cùng transcode của hai lượt tính tay; sampler tự đếm từ 2026-10-25 (mục 2), cần cho D1 của phần 3; [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327): PASS, (c) giữ, sampler đếm hai worker cùng transcode ở một mẫu (đúng: 9 video chia 4/2/3, pod thay vào nhận cả hai partition còn video) |
| D2 (đường dev) | Đạt (điểm 60 s, hai lượt) | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): điểm 60 s, MEM USAGE trừ `active_file` 6 084 MiB, pod 3 163 MiB; cuối kịch bản 6 598 MiB, 3 712 MiB; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): 5 972 MiB, 3 024 MiB; cuối 6 752 MiB (trên 6,5 GiB), 3 806 MiB |
| D7 (đường dev) | Đạt (đường dev); đường GitOps ở phần 3 | [40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740): 16/16 mục PASS, gồm WEB-7; trước đó [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): exit 2, dòng phán quyết bị bộ lọc bỏ oan; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): 15/16, WEB-7 dừng giữa chừng dưới bash 5 (lỗi của drill, đã sửa; không phải chập chờn) |
| D8 | Đạt | [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276): JWT-8, UP-8, OPS-1 (8 cổng), RL-2 (page 88 s, thấy 91 s), WEB-9 |
| `drill-alert-to-sentry` (giai đoạn 3, chạy trong `compose-obs`) | Đạt | [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276): T1 − T0 = 54,5 s, T4 − T1 = 3,4 s (< 300 s); lượt 1 [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687): 53,4 s, 4,4 s |
| D9 (đường dev) | Đỉnh (a) không đạt ổn định theo ngân sách laptop, chấp nhận (không cắt; xem lại khi chọn cỡ node ở giai đoạn 7); `resources` web giữ theo quy tắc | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): đỉnh 9 994 MiB > 8 909 MiB; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): 8 878 MiB theo định nghĩa của mục 2 (`ram-peak.json` 9 037 MiB tính cả cửa sổ chỉ một worker transcode); web cao nhất 144 MiB ở cả hai lượt, nghỉ 85–139 MiB: limit 384 Mi, request 128 Mi; [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327): không cửa sổ 6 mẫu nào (một worker transcode mỗi lúc), nên không có số đỉnh; mẫu cao nhất 8 175 MiB |
| D16 | Không page trên runner (bằng chứng yếu, test promtool là phép kiểm chính) | [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687), [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276): 0 cảnh báo trong 483–484 s, p99 Redis 4,95 ms, 0 quyết định dự phòng |
| D17 | `/` không đạt, `/v/{id}` đạt, cả sau đòn bẩy (a); TBT không đạt | [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276): median `/` 3 253 ms, `/v/{id}` 2 182 ms; đòn bẩy (a) của ADR-0020 thành việc code riêng. Việc đó (`db35f86`: trang đầu của feed trong HTML, bỏ `Suspense`, skeleton khi chuyển tab bằng transition; hls.js transmux trong worker), đo bằng job `stack` ba lần chạy, một lượt mỗi trang ([40160528767](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160528767)): `/` LCP 3 144, 2 674, 3 152 ms (median 3 144), TBT median 224 ms; `/v/{id}` LCP 2 360, 2 358, 3 908 ms (median 2 360), TBT median 220 ms; pha LCP lần ba `/` TTFB 454, Load Delay 1 148, Load 255, Render Delay 1 292 ms. Còn lại: preload ảnh LCP, font, hydrate của `/v/{id}` (ADR-0020, Kết quả "LCP") |
| D18 (gateway) | Đạt (hai lượt); canary web ở phần 3 | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): promote 129,9 s, abort 88,0 s sau traffic, 0 restart; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): 124,2 s, 87,3 s, 0 restart |
| D19 | Đạt | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): plugin 26 MiB, sidecar 71 MiB (< 256 Mi); [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): 31 MiB, 67 MiB |
| D20 | Đạt | [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985): `latest` RTO 95,2 s, RPO ≥ 63,2 s; `pitr` RTO 80,8 s, RPO 38,1 s; [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243): `latest` 92,8 s, ≥ 63,4 s; `pitr` 84,3 s, 36,1 s |
| D22 | Đạt | [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) (`7df7973`), ba lần chạy xanh |

### Job `stack` của `ci.yml` (D22) và e2e trên runner

| Lượt | Commit | Kết quả |
| --- | --- | --- |
| [40129094568](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129094568) (push `main`) | `a9b035a` | `web-e2e` đỏ: webkit 23/28, chromium 28/28, chromium-publishing 3/3, webkit-publishing 3/3; `load-ci`, `web-lighthouse` không chạy |
| [40130863434](https://github.com/anhnvcoder/short-video-platform/actions/runs/40130863434) (PR #20) | `c960ed1` (bản sửa WebKit Linux) | `web-e2e` đỏ: webkit 26/28, chromium 28/28, chromium-publishing 3/3, webkit-publishing 3/3. Đỏ: `first-frame.e2e.ts:17` (lần vuốt 19: `data-state=buffering`, `readyState=4`, `currentTime=0.17`, khác hẳn lỗi lần vuốt 1–2 trước bản sửa), `feed.e2e.ts:17` (mục 0 không `playing` trong 15 s). Đạt: upload chromium-publishing, upload có rớt kết nối webkit-publishing, `flow.e2e.ts:17` và WEB-1 trên WebKit. `load-ci`, `web-lighthouse` không chạy |
| [40132160690](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132160690) (PR #20) | `0cb842e` (web như `c960ed1`) | `web-e2e` đỏ: webkit 23/28, webkit-publishing 2/3, chromium 28/28, chromium-publishing 3/3. Đỏ: `a11y.e2e.ts:49`, `feed.e2e.ts:17`, `first-frame.e2e.ts:17`, `security.e2e.ts:24` (WEB-1), `share.e2e.ts:44` trên WebKit, upload có rớt kết nối trên webkit-publishing: cùng bản sửa, lượt trước chỉ đỏ hai, nên còn chập chờn |
| [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) lần chạy 1 (PR #20) | `7df7973` (player chỉ phát nguồn hls.js khi đủ dữ liệu) | Xanh: `web-e2e` 62/62 (chromium 28/28, webkit 28/28, chromium-publishing 3/3, webkit-publishing 3/3); `load-ci` mọi threshold đạt (323 check); `web-lighthouse` chạy, `/` LCP 2 833 ms, `/v/{id}` 4 040 ms (đỏ ngưỡng, bước `continue-on-error`) |
| [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) lần chạy 2 | `7df7973` | Xanh: `web-e2e` 62/62 như lần 1; `load-ci` đạt (324 check); `web-lighthouse` `/` 3 553 ms, `/v/{id}` 2 394 ms |
| [40133806424](https://github.com/anhnvcoder/short-video-platform/actions/runs/40133806424) lần chạy 3 | `7df7973` | Xanh: `web-e2e` 62/62 như lần 1; `load-ci` đạt (323 check); `web-lighthouse` `/` 3 793 ms, `/v/{id}` 2 754 ms |

D22 đạt ở `7df7973` (ba lần chạy liền đều xanh): quyền ở đầu log `Contents: read` (cùng `Metadata: read` GitHub luôn cấp), artifact
của job chỉ `lighthouse`, `k6-summary`. Job này cũng bỏ hạn chế AppArmor của user namespace trước `make web-lighthouse` như
`compose-obs`, nên Lighthouse có báo cáo. Sáu ca WebKit và upload (first-frame, feed, flow, WEB-1 trên WebKit, upload trên
chromium-publishing, upload có rớt kết nối trên webkit-publishing) đạt ở cả ba lần chạy.

## Hệ quả

- **Được:**
  - Mọi việc dời vì máy 16 GB chạy được mà không cần dịch vụ cloud, không tốn tiền, trên môi trường sạch, lặp lại được bằng một
    lệnh dispatch; giai đoạn 7 chỉ còn việc của cloud.
  - Mỗi lượt có tiêu chí "runner đủ" đo được, nên lượt đỏ tách được lỗi code với giới hạn của runner, và B chỉ mở khi có số.
  - Không secret nào trong workflow, kể cả đường GitOps; deploy key của Argo CD bỏ luôn ở máy.
  - Script và manifest của giai đoạn 7 (Job k6, Chaos Mesh, Velero, lệnh gỡ) được chạy thật một lần trước buổi cloud tính tiền.
  - Cảnh báo misconfig có đường bỏ qua có lý do, có hạn, review được; lockfile npm có cổng CRITICAL; page `RateLimitFallbackActive`
    chỉ khi Redis mất thật.
- **Phải trả:**
  - Một workflow thứ ba và năm script `deploy/ci/verify-*.sh` phải giữ đúng quy ước của ADR-0015.
  - Log và artifact công khai: bộ lọc theo giá trị và mẫu không bắt được giá trị đã biến đổi; biện pháp chính vẫn là không script nào
    in bí mật.
  - Số đo của runner là amd64, 4 vCPU, không VM: không thay số của máy, chỉ so với ngân sách và ngưỡng.
  - Runner 4 vCPU không phải "node đủ CPU" cho hai worker 2 CPU: dòng D1 có thể phải sang VM thuê.
  - Velero trên runner thử phạm vi hẹp hơn giai đoạn 7 (chỉ Redpanda, không xoá cả namespace) và cần driver CSI để thử; Chaos Mesh,
    Velero, driver CSI chạy đặc quyền trong cluster tạm của job.
  - Đường GitOps phụ thuộc repo còn public và GitHub không chặn git ẩn danh; bản phát hành trong lúc đo cần một người merge đúng lúc.
  - Một lượt mỗi kịch bản mỗi lúc (từ 2026-10-25; trước đó một lượt cho cả workflow): lỗi chung của hai kịch bản có thể đỏ ở cả
    hai lượt chạy song song.
  - Lượt lịch hằng tuần (từ 2026-10-25) chạy hai kịch bản trên `main` dù không ai đọc: log và artifact công khai thêm mỗi tuần, qua
    cùng bộ lọc.
- **Xem lại khi:**
  - Một dòng trượt tiêu chí runner hai lượt liền: chạy dòng đó trên B, ghi chi phí.
  - Repo thành private, hay GitHub giới hạn git ẩn danh: Argo CD quay lại deploy key (secret của environment được bảo vệ).
  - Pull từ node k3d trên runner gặp 429 (miễn trừ của GitHub không áp cho ca đó): xét đăng nhập Docker Hub bằng token chỉ đọc, khi
    đó mới có secret, ghi vào ADR này trước.
  - `ubuntu-24.04` bị GitHub bỏ hay đổi cấu hình runner chuẩn: đo lại cổng đĩa và tiêu chí RAM.
  - Lượt lịch đỏ: đọc và sửa như lượt dispatch; GitHub tắt lịch sau 60 ngày repo không hoạt động: bật lại ở tab Actions.
  - Bộ lọc artifact bỏ oan nhiều file hợp lệ: thu hẹp mẫu theo loại file, không bỏ quét theo giá trị.
- **ADR cũ được chỉnh** (ghi "chỉnh bởi 0021" ở trạng thái của chúng và ở `docs/adr/README.md` là việc cập nhật tài liệu sau):
  - ADR-0011 §8: điều kiện của `RateLimitFallbackActive` (mục 11), thêm `RateLimitFallbackElevated`.
  - ADR-0014 §12: Argo CD đọc repo qua HTTPS ẩn danh thay deploy key SSH (mục 6).
  - ADR-0015 §1 (workflow thứ ba `verify.yml` ngoài hai workflow), §2 (job `trivy-config` đọc tệp bỏ qua misconfig, job `web` thêm
    `make web-lockfile-scan`), §6 (quy tắc của tệp bỏ qua thứ hai) (mục 3, 9, 10).
  - ADR-0019 §9: source map của image CI kéo từ giai đoạn 7 về giai đoạn 6b, `images.yml` xuất artifact `web-sourcemaps-<arch>` (mục 6).
  - ADR-0020 §6, §7 (Velero, Chaos Mesh chạy trên k3d của runner với phủ riêng), §2 (`render.sh` nhận số pod) (mục 7, 8).

## Hiện thực ở

Phần 1:

- Workflow `verify.yml` và tiêu chí "runner đủ" (§2–§5): `.github/workflows/verify.yml`, `deploy/ci/verify-host.sh`,
  `deploy/ci/verify-run.sh`, `deploy/ci/verify-sample.sh`, `deploy/ci/verify-mask.sh`, `deploy/ci/verify-collect.sh`,
  `deploy/ci/verify-collect-test.sh` (chạy cả ở job `config` của `.github/workflows/ci.yml`); đuôi log hạ tầng (§4):
  `log_tail_namespaces`, `unready_report` của `deploy/k8s/lib.sh`, gọi từ `deploy/k8s/install.sh`.
- Bỏ qua có hạn cho cảnh báo `trivy-config` (§9): `deploy/ci/trivy-config-ignore.yaml`, `deploy/ci/scan-gate.sh`
  (`--check-ignorefile`), target `trivy-config` của `Makefile`, job `config` của `.github/workflows/ci.yml`.
- Cổng quét `web/pnpm-lock.yaml` (§10): target `web-lockfile-scan` của `Makefile`, `deploy/ci/scan-gate.sh` (`--fs`), job `web` của
  `.github/workflows/ci.yml`.
- `RateLimitFallbackActive` theo tỷ lệ dự phòng (§11): `deploy/observability/prometheus/rules/svp-alerts.yaml`,
  `deploy/observability/prometheus/rules/svp-alerts.test.yaml`.

Phần 2–4 chưa hiện thực.
