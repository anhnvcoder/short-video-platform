# 0021. Giai đoạn 6b: kiểm chứng dồn chạy trên runner GitHub Actions `ubuntu-24.04` bằng workflow `verify.yml` chạy tay (`workflow_dispatch`, thêm lịch hằng tuần trên `main` từ 2026-10-25), mỗi lượt một kịch bản dựng compose hay k3d bằng target `make` có sẵn, artifact chỉ theo danh sách cho phép và qua bộ quét giá trị bí mật, VM thuê theo giờ chỉ khi runner trượt tiêu chí đo được; Argo CD đọc repo công khai qua HTTPS ẩn danh; Chaos Mesh, Velero (CSI hostpath) và k6 thu nhỏ trên k3d của runner; tệp bỏ qua misconfig có hạn, cổng quét lockfile npm, điều kiện page mới của `RateLimitFallbackActive`

- Trạng thái: Chấp nhận; nơi chạy A/B do người học chốt ngày 2026-10-24, các quyết định còn lại theo đề xuất ở đây. Phần 1
  (workflow, kịch bản `compose-obs` và `dev-k3d`, mục 9–11) hiện thực và đã chạy trên runner 2026-10-24 đến 2026-10-25 (mục Kết
  quả); phần 2 (thay object store theo [0022](0022-local-object-store-minio-replacement.md), RustFS) hiện thực và đã chạy lại
  `compose-obs`, `dev-k3d` trên runner 2026-10-25 (D15 ở mục Kết quả); phần 3 (GitOps, canary web, k6, Chaos Mesh, Velero; mục
  6–8) hiện thực và đã chạy trên runner 2026-10-26 đến 2026-10-28 (mục "Phần 3 theo dòng dời"; kịch bản `chaos`: (c) và
  (a) gateway đạt, (a) feed-service và (b) là phát hiện, D12), trừ D5 và D26 của `gitops` chỉ kiểm được trên `main` sau khi phần 3
  merge (kiểm sau merge); phần 4 (tách repo cấu hình `svp-gitops` theo [0025](0025-gitops-config-repo.md), mục 5) hiện thực và chạy
  trên runner 2026-10-29 đến 2026-10-30 (mục "Phần 4"), trừ bản ghi stg và bước chờ phát hành trên `main` (kiểm sau merge PR-B); RAM
  của đường GitOps sau khi tách vẫn không đạt (b) cuối kịch bản và đỉnh (a), ghi số, chưa kết luận. Đích object store của Velero (§7, kịch bản `velero`) và của BAK-1 trong cluster
  bị thay một phần bởi [0022](0022-local-object-store-minio-replacement.md): RustFS thay MinIO, Velero kiểm trên RustFS ở phần 3
  và đạt (mục 12 của kế hoạch kiểm 0022); kịch bản `compose-obs` (thêm `drill-duplicates`, `drill-kill-worker` sau `smoke`, ba test
  integration của output bất biến) chỉnh bởi [0029](0029-immutable-media-versions.md); kịch bản `gitops` (§6: bước
  `gitops-external-secrets`, `k8s-smoke` với `SVP_SMOKE_LEGACY_MEDIA=1` tới khi bản media-worker phát hành ghi key có version, ca `l`
  của `drill-k8s-supplychain`) chỉnh bởi [0026](0026-secrets-gitops.md), [0027](0027-slsa-build-provenance.md) và 0029; §3 (job
  `record-stg` có environment `promote`), §6 (Argo CD và kịch bản `gitops` đọc `svp-gitops`, bước chờ phát hành theo dõi `main` của
  `svp-gitops`, bản phát hành tới không qua merge tay) chỉnh bởi 0025 và [0024](0024-multi-environment.md) §8
- Chỉnh 2026-10-28 (phần 3): điều kiện mở script cloud trên k3d đi qua hàm `ci_hosted_runner` của adapter nền tảng (mục 7, Tên
  chốt); job `gitops` tách bước chờ phát hành khỏi bước kịch bản (mục 2, 6); kịch bản `chaos` chạy mỗi thí nghiệm một lượt k6 riêng
  có cửa sổ ổn định riêng, thay một lượt k6 chạy suốt (người học chốt, mục 7)
- Ghi chú 2026-10-29: D5 và D26 đạt trên `main` (pha (2) của `gitops`); hai phát hiện của `chaos` và Tempo OOM sửa ở
  [0031](0031-chaos-findings-feed-engagement-tempo.md), chạy lại `chaos` đạt cả (a), (b), (c) (D12); `k6-cloud-mini` chạy lại, mức
  cao nhất đạt vẫn 2 pod, mức 4 chạm trần CPU của runner (D11); kịch bản `chaos`, `k6-cloud-mini` thêm step `tempo-ingest-*`, sampler
  lấy thêm `svp-obs` vào `pods.tsv` (0031 §3)
- Chỉnh 2026-10-30 (phần 4): kịch bản `gitops` dựng từ `main` của `svp-gitops` (clone ẩn danh bằng `make gitops-clone` trước bước
  dựng), thôi đặt `SVP_SMOKE_LEGACY_MEDIA` ở `k8s-smoke` (mọi bản phát hành ghi key media có version, smoke chặt trên mọi đường);
  thêm bước `release-set-before` (trước `k8s-smoke`) và `release-set` (sau `ram-rest-end`), `release-set.json` vào artifact; job mới
  `record-stg` sau `gitops` (chỉ `main`) ghi bản ghi stg với environment `promote`, nên câu "không secret, không environment" của mục 3
  chỉ còn đúng cho các job dựng và kiểm
- Chỉnh 2026-10-30 (phần 4, sau final review): lịch tuần chạy thêm job `gitops` (người học chọn (a) ở dòng 4 "Cần người học chọn"
  của [0028](0028-dora-metrics.md) ngày 2026-10-28), lượt lịch không chờ phát hành (`wait-release`, `measure-gitops` `skipped` kèm lý
  do) và trong `drill-k8s-supplychain` bỏ ca (c), (l) khi image của ca đó quá tuổi tối đa của policy (SKIP kèm dòng `NOTE`); job
  `record-stg` ghi khi bước kịch bản của `gitops` xanh và `release-set.json` có trong artifact, không còn phụ thuộc bước chờ phát
  hành; `targets` bỏ một bước kiểm nào (trừ `wait-release`, `measure-gitops`) thì `release-set` `skipped`, không ghi (mục 3)
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
| Workflow | Job | `compose` (kịch bản `compose-obs`), `k3d` (mọi kịch bản k3d trừ `gitops`), `gitops` (phần 3); mỗi lượt dispatch chạy đúng một job, hai job kia `skipped`; lượt `schedule` chạy `compose` (`compose-obs`), `k3d` (`dev-k3d`) và, từ 2026-10-30, `gitops` (`gitops`) song song |
| Workflow | Runner | `ubuntu-24.04` (amd64) cho cả ba job |
| Workflow | `concurrency` | group `verify-<kịch bản>` (lượt `schedule`: `verify-schedule`), `cancel-in-progress: false` (mục 3, sửa 2026-10-25) |
| Script | `deploy/ci/verify-host.sh` | Kiểm và chuẩn bị máy: cổng đĩa, `/etc/hosts`, độ lệch version kubectl, `sch_netem`, hạn chế AppArmor của user namespace cho sandbox của Chrome ở `compose-obs` (mục 2, 3) |
| Script | `deploy/ci/verify-run.sh <kịch bản>` | Chạy trình tự target `make` của kịch bản, mỗi target có hạn riêng (mục 3, 5); dừng sớm khi bước dựng đỏ, chỉ chạy các bước `SVP_VERIFY_TARGETS` chọn (mục 3); chạy được cả trên VM của B |
| Script | `deploy/ci/verify/<kịch bản>.sh` | Trình tự của một kịch bản (từ phần 3, mỗi kịch bản một file mà `verify-run.sh` nạp, tên kiểm bằng `case`): bước dựng `build` (`up`, `k8s-up` hay `k8s-gitops-up`), hạn job mặc định, danh sách bước; bảy file `compose-obs.sh`, `dev-k3d.sh`, `gitops.sh`, `web-canary.sh`, `k6-cloud-mini.sh`, `chaos.sh`, `velero.sh` |
| Script | `deploy/ci/verify-sample.sh start\|stop\|peak\|s3-peak\|sample` | Lấy mẫu nền: RAM, đĩa, CPU của máy, `docker stats` và `memory.stat` của node k3d, số pod media-worker đang transcode, trạng thái node, RAM và số restart của từng container compose; `peak` tính RAM đỉnh cho bước `ram-peak` (mục 2), `s3-peak` RAM đỉnh của object store cho bước `ram-s3-upload` (phần 2), `sample` lấy một mẫu ngay (trước khi `object-store-roundtrip` gỡ stack) |
| Script | `deploy/ci/verify-mask.sh env\|cluster` | `::add-mask::` cho giá trị bí mật của `.env` hay của Secret trong cluster (mục 4) |
| Script | `deploy/ci/verify-collect.sh` | Gom file theo danh sách cho phép, quét giá trị và mẫu, bỏ file nghi (mục 4) |
| Thư mục kết quả | `$RUNNER_TEMP/verify/` (biến `SVP_VERIFY_OUT`) | Mẫu, bảng, JSON trước khi lọc; không bao giờ upload nguyên thư mục |
| Artifact | `verify-<kịch bản>` | Chỉ thư mục do `verify-collect.sh` dựng; `retention-days: 30` |
| Máy | Dòng `/etc/hosts` | `127.0.0.1 svp.localhost api.svp.localhost s3.svp.localhost` |
| Chặn tai nạn | Điều kiện mở `run.sh`, `drill-restore.sh` trên k3d | `ci_hosted_runner` của `deploy/ci/platform.sh` exit 0 (chế độ `github`: `GITHUB_ACTIONS=true` và `RUNNER_ENVIRONMENT=github-hosted`; script không tự đọc biến `GITHUB_*`), `uname -s` là `Linux`, context đúng `k3d-svp`; kiểm trước mọi lệnh `kubectl` (mục 7, sửa ở phần 3) |
| Phần 3 | Thư mục phủ chỉ cho runner | `deploy/k8s/cloud/runner/`: `csi/` (driver CSI hostpath, CRD và controller external-snapshotter, StorageClass `csi-hostpath`, VolumeSnapshotClass), `velero/` (values phủ, NetworkPolicy `svp-data/velero-s3`), `chaos-mesh/` (values phủ); `runnerValues` của `deploy/k8s/cloud/charts.json` là file phủ của mỗi chart (mục 7) |
| Phần 3 | Velero trên runner | Bucket `velero`, user object store `svp-velero` (quyền chỉ bucket đó), Secret `velero/velero-s3`; `SVP_K8S_RUNNER_CSI=1` cho `make k8s-up` cài driver CSI ngay trước release `redpanda` (chỉ kịch bản `velero`) |
| Phần 3 | Source map image CI | Artifact `web-sourcemaps-<arch>` của job build trong `images.yml`, mang file `image-digest` (digest manifest của chân đã push); `deploy/ci/gitops-sourcemaps.sh` chọn lượt có `image-digest` bằng manifest con `linux/amd64` của digest web đang chạy; `make k8s-web-sourcemaps SOURCEMAPS_DIR=<thư mục>` tải thư mục đó (mục 6) |
| Phần 3 | Bước của job `gitops` | `Find the source maps of the web image` (trước kịch bản), `Scenario` (175 phút), `Waiting for a release on main` (sau kịch bản, 115 phút); `GH_TOKEN` chỉ ở bước đầu và bước cuối (mục 2, 6) |
| Phần 3 | Bỏ phép kiểm có lý do | `SVP_WEB_OBS_SKIP_ERRORS=<lý do>` bỏ riêng phép kiểm `errors` của `drill-k8s-web-obs` (rỗng hay chỉ khoảng trắng bị từ chối); chỉ kịch bản `gitops` trên nhánh `feat/stage6b-*` đặt khi không có artifact source map khớp (mục 6) |
| Phần 3 | Canary web | `make drill-k8s-web-canary` (`deploy/k8s/drills/web-canary.sh`, client trình duyệt `web/e2e/canary/clients.ts`), JSON `.k8s/drills/web-canary-<time>.json` (D6) |
| Phần 3 | k6 thu nhỏ | Mức 1, 2, 4, 8 pod của profile `cloud`, mỗi pod đúng phần tải của thiết kế 20 pod (mục 8): `render.sh --pods N [--ramp D] [--hold D]`, `run.sh --pods N start`; mốc cửa sổ giữ ở `$SVP_VERIFY_OUT/k6-windows.tsv` cho tiêu chí throttle |
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
  `gitops` 285 phút). Sửa ở phần 3: job `gitops` chia 285 phút thành bước kịch bản 175 phút và bước `Waiting for a release on main`
  115 phút chạy sau nó, vì token chỉ được nằm ở bước chờ (mục 6). Bước đầu của job ghi thời điểm bắt đầu job vào `$SVP_VERIFY_OUT`; `verify-run.sh` chạy mỗi target `make` dưới
  `timeout` riêng (ví dụ `make k8s-up` 60 phút, mỗi diễn tập 30 phút, chờ bản phát hành 90 phút) nhưng không quá mốc "bắt đầu job +
  hạn job − 25 phút", và không bắt đầu target mới khi đã qua mốc đó. Như vậy setup chậm hơn ước lượng chỉ làm kịch bản ngắn lại, một
  target treo làm đỏ đúng target đó, và các bước gom, lọc, tải artifact (`if: always()`) luôn còn 25 phút; hạn 6 giờ của GitHub không
  bao giờ là thứ cắt job. Lượt đầu mỗi kịch bản ghi thời gian setup thật; quá 20 phút thì sửa ngân sách ở đây.

**Bảng "runner đủ"** (mọi điều phải đạt; không đạt vì tài nguyên hai lượt liền thì dòng đó sang B):

| Kịch bản | Đủ khi |
| --- | --- |
| Mọi kịch bản | Cổng đĩa đạt; job xong trong hạn bước; `MemAvailable` thấp nhất ≥ 2 GiB; không container nào `OOMKilled`, kernel không ghi OOM; chỗ trống thấp nhất ≥ ngưỡng chạy ở trên |
| `compose-obs` | Thêm: không container nào của project restart ngoài các lần diễn tập chủ động dựng lại. Đếm (sửa 2026-10-25, phần 2): sampler ghi `samples/restarts.tsv` mỗi 10 s (tên, thời điểm tạo, `RestartCount` của mọi container project `svp`) và một mẫu ngay trước `make down` của `object-store-roundtrip`; `runner.json` lấy số cao nhất của mỗi container (tên + thời điểm tạo) rồi cộng theo tên, nên restart của container đã bị gỡ hay dựng lại vẫn được đếm; container `make up` hay diễn tập tạo mới bắt đầu từ 0, nên lần dựng lại chủ động không thành restart |
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
| **Mỗi lượt một kịch bản, mỗi nhóm kịch bản một job** (`compose`, `k3d`, `gitops`) | Runner mới cho mỗi kịch bản; service container chỉ ở job compose; quyền `actions: read` (và `pull-requests: read`, từ 2026-10-29) chỉ ở job `gitops` | Kịch bản dùng chung bước setup phải khai ở nhiều job |
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
  - **Từ 2026-10-30 lượt lịch chạy thêm job `gitops`** (dòng 4 của "Cần người học chọn" ở [0028](0028-dora-metrics.md): không có
    nó, deployment frequency của stg lab chỉ đo nhịp người học dispatch). `if:` của job đúng khi `github.event_name == 'schedule'`
    hay `inputs.scenario == 'gitops'`, bước kiểm ref nhận `schedule:refs/heads/main` như hai job kia, `SCENARIO` vẫn là `gitops`,
    `targets` rỗng, quyền giữ nguyên. YAML báo cho script biết lượt là lịch qua `SVP_VERIFY_SCHEDULED` (`true` ở lượt lịch, rỗng ở
    lượt dispatch; script chỉ coi đúng `true` là lịch) ở bước kịch bản và bước chờ. Lượt lịch **không chờ phát hành**: không ai merge
    bản phát hành cho nó, nên bước chờ chỉ có thể đỏ; `wait-release`, `measure-gitops` in lý do rồi qua. Ca (c) của
    `drill-k8s-supplychain` (image diễn tập `drill-vulnerable`) và ca (l) (bản web trước provenance) chỉ đạt trong 72 giờ sau lượt
    `images.yml` dựng lại image diễn tập hay rescan bản đó; rescan hằng ngày không quét hai image này, và không ai dispatch trước
    lượt lịch. Chỉ ở lượt lịch, `gitops_stale` của `deploy/ci/verify/gitops.sh` đọc `scanFinishedOn` của hai image (cosign ẩn danh,
    như drill đọc) và khi quá tuổi tối đa của policy thì không đưa image đó cho drill (ca đó SKIP, không làm gì đỏ), in một dòng
    `NOTE` nêu ca, tuổi và lệnh dispatch; mọi ca khác vẫn phải PASS. Lượt dispatch giữ nguyên: ca quá hạn là đỏ. Vì vậy (c), (l)
    chỉ được chứng minh ở lượt dispatch chạy sau lượt dựng lại hay rescan đó. Job dài nhất của lượt lịch (330 phút) xong trước
    06:17 UTC, trước `dora.yml` (09:17 UTC, [0028](0028-dora-metrics.md) §8).
  - **Bản ghi stg** (job `record-stg`, [0025](0025-gitops-config-repo.md) §6, [0024](0024-multi-environment.md) §8) ghi theo một quy
    tắc, cho lượt dispatch lẫn lượt lịch: **bước kịch bản của job `gitops` xanh và `release-set.json` có trong artifact**. Bước kịch
    bản có `id: scenario`; sau bước gom và lọc, một bước `if: !cancelled() && steps.ref.outcome == 'success' &&
    steps.scenario.outcome == 'success'` (không có hàm trạng thái thì GitHub ngầm thêm `success()`, bước chờ đỏ sẽ làm bước này bị
    bỏ) đặt output `recorded=true` khi file có; job `gitops` xuất output đó (chỉ cờ, không giá trị nào của artifact); `record-stg`
    có `if: !cancelled() && needs.gitops.outputs.recorded == 'true' && github.ref == 'refs/heads/main'`. Bước chờ phát hành đỏ vẫn
    làm job `gitops` đỏ (số đo `measure-gitops` là của nó) nhưng không chặn bản ghi; một bước kiểm nào của kịch bản đỏ thì bước
    kịch bản đỏ, không ghi. `targets` của dispatch bỏ một bước của kịch bản (trừ `wait-release`, `measure-gitops`, chạy sau lần chụp
    cuối) thì `release-set` `skipped` kèm lý do (bộ chưa được mọi bước kiểm): không ghi. Lượt trên nhánh `feat/stage6b-*` không bao
    giờ ghi (environment `promote` chỉ nhận `main`), lượt bị huỷ cũng không. Trước 2026-10-30 `record-stg` đòi cả job `gitops` xanh,
    gồm bước chờ trên `main`: dispatch không kèm phát hành không có bản ghi, promote prd báo "no record of stg counts yet".
- **Ref:** bước đầu của mỗi job dừng (exit 1, nêu lý do) khi `GITHUB_REF` không phải `refs/heads/main` hay `refs/heads/feat/stage6b-*`
  (lượt `schedule`: chỉ `refs/heads/main`).
  Đây là chặn tai nạn (dispatch nhầm nhánh cũ), không phải ranh giới bảo mật: ai có quyền ghi đẩy được nhánh có `verify.yml` của
  chính họ (cùng mức tin như SC-8). Ranh giới là không secret và token chỉ đọc.
- **Thứ tự:** `workflow_dispatch` chỉ chạy khi file có trên nhánh mặc định, nên PR đưa `verify.yml` vào `main` (đủ `ci-ok`,
  `images-ok`) merge **trước** lượt dispatch đầu; sau đó dispatch được với `--ref main` hay nhánh `feat/stage6b-*` (chạy bản file và
  code của nhánh đó). AI dispatch (`gh workflow run verify.yml --ref <nhánh> -f scenario=<tên>`) và đọc kết quả (`gh run view`,
  `gh run download`) từng lượt; lượt kế của một kịch bản chỉ dispatch khi lượt trước của nó đã xong.
- **Quyền:** `permissions: {}` đầu file; `compose`, `k3d`: `contents: read`; `gitops`: `contents: read`, `actions: read` (tải artifact
  source map của lượt `images.yml`, mục 6), `pull-requests: read` (từ 2026-10-29: `merged_at` của PR promote có `merge_commit_sha`
  là commit phát hành, mốc push của `make measure-gitops`, qua `GET commits/{sha}/pulls`). Không secret, không environment (từ phần 4
  trừ job `record-stg`, không dựng, không chạy kịch bản: environment `promote`, token App chỉ `deployments` write trên `svp-gitops`;
  [ADR-0025](0025-gitops-config-repo.md) §6). `GH_TOKEN: ${{ github.token }}` chỉ ở bước gọi `gh`
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
    `timeout`, `cancelled` và `skipped` vì `deadline`, nên các bước đó không làm runner "thiếu". Tiêu chí đó còn cần dấu
    `run-end` mà `verify-run.sh` ghi sau dòng của bước cuối (sửa 2026-10-25): lượt bị huỷ hay bị `timeout-minutes` cắt có thể dừng
    trước khi bước đang chạy kịp có dòng `cancelled` (runner không chờ), `results.tsv` khi đó trông như đủ mà thiếu bước đang chạy
    và mọi bước sau; thiếu dấu thì `within_deadline=false` và `runner.txt` ghi `verify-run.sh reached its end false`. File dấu
    không vào artifact (ngoài danh sách cho phép, không cảnh báo).
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
  (`web/test-results/lighthouse/*.json`, `*.html`, như job `stack`), `error-context.md` của test Playwright đỏ
  (`web/test-results/playwright/<test>/`: lỗi và cây accessibility của trang lúc đó, dạng chữ; thêm 2026-10-30 vì e2e đỏ ở lượt
  40986504316 không để lại bằng chứng; trace vẫn cấm), mẫu của sampler, bảng RAM, đầu ra `make k8s-status` và `kubectl
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
  | `svp-data` | Redpanda (log text của seastar: kiểm hệ thống lúc khởi động, lỗi cấu hình, bộ nhớ), Valkey, object store `s3` (MinIO trước phần 2), sidecar của chart, Job init | Mọi pod Postgres của CloudNativePG (nhãn `cnpg.io/cluster`): dòng lỗi trích câu lệnh thất bại, gồm cả giá trị |
  | `svp-obs` | Prometheus, Alertmanager, Grafana, Loki, Tempo, Pyroscope, Collector (logfmt hay console của zap, không exporter `debug`), operator của kube-prometheus-stack | GlitchTip (nhãn `app.kubernetes.io/name=glitchtip`): access log mang `sentry_key=` là khoá công khai của DSN, mà phép quét chỉ biết nguyên DSN; lỗi của nó có thể trích event nhận được |
  | `cnpg-system`, `keda`, `argo-rollouts`, `kyverno`, `cert-manager` | Operator và controller: lỗi reconcile, webhook, chứng chỉ (CloudNativePG in JSON nên đã bị bỏ theo luật JSON; KEDA in dạng console của zap, mặc định của chart `keda` 2.21.0 cho operator, metrics server và webhook (`logging.operator.format: console`, `deploy/k8s/values/keda.yaml` không đổi), nên đuôi log của nó được giữ) | — |
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
| `compose-obs` | compose `OBS=lgtm` | `make up OBS=lgtm` → `make smoke` → `make drill-obs-threats` → `make load-local` (quan sát cảnh báo, p99 Redis) → `make web-lighthouse` ×3; phần 2 thêm `make test-stack PKGS=./internal/objstore/...` → `make drill-upload-cleanup` → `make measure-upload` → RAM đỉnh của `s3` trong lúc đó → (`make drill-alert-to-sentry`) → đường quay lại: `make down`, `make object-store-copy TO=minio`, `make up OBS=lgtm` lần hai, `make smoke` | 1, 2 |
| `dev-k3d` | k3d đường dev | `make k8s-up` → `make k8s-smoke` → RAM nghỉ 60 s → `make drill-k8s-threats` → `make drill-k8s-pdb` → `make drill-k8s-canary` → `make k8s-web-sourcemaps` → `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` → `make drill-k8s-web-obs` → `make drill-k8s-keda N=9` (RAM đỉnh; kết luận chỉ cho đường dev) → `make drill-k8s-backup` rồi `MODE=pitr` → RAM nghỉ cuối | 1 |
| `gitops` | k3d GitOps | `make k8s-gitops-up` → `make k8s-smoke` → RAM nghỉ 60 s → `make drill-k8s-supplychain` → `make drill-k8s-threats` → source map của image CI → e2e GlitchTip → `make drill-k8s-web-obs` → `make drill-k8s-keda N=9` ×2 → chờ bản phát hành → `make measure-gitops` → RAM nghỉ cuối | 3 |
| `web-canary` | k3d đường dev | `make k8s-up` → traffic diễn tập + client trình duyệt → canary web bản tốt rồi bản lỗi (drill mới) | 3 |
| `k6-cloud-mini` | k3d đường dev | `make k8s-up` → seed ≥ 30 video `READY` → Job k6 các mức của mục 8, sau mỗi mức `tempo-ingest-<n>` (từ 2026-10-29, [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md) §3) | 3 |
| `chaos` | k3d đường dev | `make k8s-up` → cài Chaos Mesh → k6 ở mức giữ → (b) trên pod thử → (a), (b), (c), sau mỗi thí nghiệm `tempo-ingest-chaos-<x>` (từ 2026-10-29, ADR-0031 §3) → gỡ | 3 |
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
  nữa, `make k8s-gitops-up` bỏ `ARGOCD_DEPLOY_KEY`; người học xoá deploy key cũ trên GitHub sau khi đường mới chạy (chạy từ
  2026-10-28, lượt `gitops` [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534)). Đây là chỉnh
  ADR-0014 §12 ("Repo … qua SSH bằng deploy key"); đã ghi chỉnh ở ADR-0014 ngày 2026-10-28. Đường GitOps vì vậy
  **không cần secret nào**.
- **Bản phát hành trong lúc cluster chạy:** trước khi dispatch `gitops`, một thay đổi không đổi hành vi của **một service có
  Postgres** (ví dụ feed-service) đã merge vào `main`, `images.yml` đã mở PR promote với `ci-ok`, `images-ok` xanh, chưa merge.
  Lượt `gitops` dựng cluster theo `main`, chạy các diễn tập, rồi tới bước tên **"Waiting for a release on main"**: bật traffic diễn
  tập, đọc `git ls-remote origin refs/heads/main` mỗi 30 s trong tối đa 90 phút. Hiện thực ở phần 3: đây là bước riêng của job
  sau bước kịch bản (`bash deploy/ci/verify/gitops.sh release`), không phải một bước của `verify-run.sh`, để bước kịch bản không giữ
  token; `targets` vẫn nhận hai tên `wait-release`, `measure-gitops`; lượt trên nhánh `feat/stage6b-*` ghi bước này `skipped`. Khi bước đó đang chạy (đọc qua `gh api
  repos/<repo>/actions/jobs/<id>`, trạng thái từng bước), người học hay AI được người học uỷ quyền merge PR promote. `main` đổi thì job `git fetch`,
  kiểm commit mới đổi `image.digest` trong `deploy/k8s/values/services/` (đúng một bản phát hành), chạy `make measure-gitops
  REV=<sha>` lặp tới khi exit khác 2 (tối đa 20 phút). Push không có reflog trên runner nên script đọc `merged_at` của PR promote
  có `merge_commit_sha` là commit, không có thì PushEvent, bằng `gh api` (`GH_TOKEN` chỉ ở bước này; sửa 2026-10-29: Events API trễ
  có chủ đích, lượt D26 đầu không có PushEvent). Hết 90 phút không có push thì bước FAIL "no release", các diễn tập khác vẫn có kết quả.
  Tiêu chí D26: số đo có, pod mới không restart.
- **Ca web chưa ký của Kyverno:** `SUPPLYCHAIN_UNSIGNED` là **digest manifest con `linux/amd64` của bản web đang phát hành** (đọc từ
  index đã ký): cùng repository `…/web`, digest thật, kéo được, nhưng chữ ký và attestation gắn với digest index, không với manifest
  con, nên rule chữ ký phải từ chối. Lý do: chứng minh đúng "image web chưa ký" mà không cần đẩy gì lên GHCR (job chỉ đọc). Nếu
  Kyverno nhận pod đó thì ca dùng `drill-unsigned` (`SUPPLYCHAIN_UNSIGNED_FALLBACK`) như giai đoạn 5 và ghi lý do. Xác nhận
  2026-10-28 (D4): Kyverno không lần từ manifest con về index, rule chữ ký từ chối, không cần `drill-unsigned`.
  Ca (c) cần `drill-vulnerable` có attestation dưới 72 giờ: dispatch `images.yml -f drill=true` trong 72 giờ trước lượt `gitops`.
- **Source map của image CI** (ADR-0019 §9, dời từ giai đoạn 7 về đây): job build web của `images.yml` xuất stage `sourcemaps` ngay
  sau image, cùng cache, thành artifact `web-sourcemaps-<arch>` (source map của code vốn public, không bí mật; retention mặc định).
  Job `gitops` tìm lượt `images.yml` đã build digest web đang chạy (tag 12 hex là commit), tải `web-sourcemaps-amd64` bằng
  `actions: read`, rồi tải lên GlitchTip của cluster theo cách của `make k8s-web-sourcemaps` (dạng nhận thư mục có sẵn thay vì tự
  build); kiểm như D5. Đổi `images.yml` làm build lại cả bảy image một lần (ADR-0015 §3). Một commit có thể được build nhiều lần
  (dispatch `-f services=web` ở commit cũ), nên commit không đủ để nhận bản build: artifact chỉ upload ở lượt phát hành, sau bước
  push, kèm `image-digest`; job duyệt mọi lượt của commit (mới nhất trước, qua `ci_artifact_runs`, `ci_artifact_fetch` của adapter,
  không theo conclusion của cả lượt) và chỉ nhận lượt có `image-digest` bằng manifest con `linux/amd64`. Không lượt nào khớp: trên
  nhánh `feat/stage6b-*` bước ghi `skipped` kèm lý do, e2e chạy không `SVP_E2E_GLITCHTIP=1`, `drill-k8s-web-obs` bỏ riêng phép kiểm
  `errors`; trên `main` là FAIL. D5 vì vậy chỉ nghiệm thu trên `main`.
- **RAM và KEDA:** đo RAM nghỉ ở điểm 60 s ngay sau `k8s-gitops-up` (D2), hai lượt `drill-k8s-keda N=9` (D1), RAM nghỉ cuối kịch bản.
- **Thời lượng:** dựng khoảng 20–30 phút, diễn tập khoảng 90 phút: dưới hạn 175 phút của bước kịch bản; chờ phát hành tối đa 90
  phút, đo tối đa 20 phút: dưới hạn 115 phút của bước chờ (mục 2, sửa ở phần 3; trước đó 285 phút chung). Lượt pha (1)
  [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): setup 6 phút, bước kịch bản 57 phút.

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
  `k3d-svp` chỉ khi `ci_hosted_runner` của `deploy/ci/platform.sh` exit 0 (chế độ `github`: `GITHUB_ACTIONS=true` và
  `RUNNER_ENVIRONMENT=github-hosted`; sửa ở phần 3: script không tự đọc biến `GITHUB_*`, `platform-guard.sh` cấm điều đó) và
  `uname -s` là `Linux` (kiểm trước mọi lệnh `kubectl`); context `k3d-*` khác và context rỗng vẫn bị từ chối. Đây là chặn tai nạn
  cho máy 16 GB (ai cũng đặt được biến môi trường), không phải ranh giới bảo mật. VM của B đặt các biến này bằng tay khi chạy đúng
  kịch bản. Ở chế độ này `run.sh` tự thêm CA `.k8s/ca.crt`, origin web `https://svp.localhost:8443` (CSRF của web so `Origin` với
  `APP_ORIGIN` có cổng), request CPU 250m và limit 1 CPU cho pod k6 (8 pod × 1 CPU không lịch được cạnh stack; không limit thì tiêu
  chí throttle luôn 0); manifest cloud mặc định không đổi.
- **Chaos Mesh** (kịch bản `chaos`): chart, image ghim như ADR-0020 §7; phủ chỉ cho runner ở `deploy/k8s/cloud/runner/`:
  `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/k3s/containerd/containerd.sock` (containerd của k3s trong
  container node). Namespace `chaos-mesh` có nhãn `pod-security.kubernetes.io/enforce=privileged` (nhãn namespace thắng mặc định
  `restricted` của k3d), chỉ trong job. `clusterScoped: false`, đích `svp` cho (a), (b), `svp-data` cho (c) bằng `helm upgrade` như
  ADR-0020. Controller chỉ bật các controller không multi-cluster (`controllerManager.enabledControllers` của values chung, cloud lẫn
  runner: bỏ `remotecluster` và 14 `<kind>-remote-apply`; sửa 2026-10-28): ở chế độ `clusterScoped: false` chart không cấp quyền
  đọc kind cấp cluster `RemoteCluster`, nên với mặc định `*` controller 2.8.5 không đồng bộ được cache và khởi động lại liên tục
  (Kết quả, lượt `chaos` 2). Bước cài chờ controller giữ cùng pod, 0 restart, không dòng `is forbidden` trong 150 s (quá hạn đồng bộ
  cache 2 phút); trước mỗi `apply` và sau `helm upgrade` của (c) chờ webhook của controller có endpoint Ready (tới 120 s). Pod-kill
  chọn pod theo `app.kubernetes.io/component: server`, không trúng pod Job migrate cùng nhãn tên. Trước (b): bản thử nạp
  `sch_netem` trên runner (kernel chung với node k3d; module của kernel không có thì cài `linux-modules-extra-<kernel>` rồi nạp) và
  một NetworkChaos thử trên pod thử ở `svp` (thời gian 20 kết nối TCP tới DNS của cluster trước, trong, sau); không nạp được thì bản
  thử FAIL kèm lý do và (b) không chạy (sửa 2026-10-28; trước đó (b) ghi SKIP và sang B). **Tải** (sửa 2026-10-28, người học chốt):
  mỗi thí nghiệm (bản thử, (a), (b), (c)) một lượt k6 riêng ở mức một nửa mức cao nhất đạt của `k6-cloud-mini` (2 pod, nên 1 pod),
  mỗi lượt có cửa sổ trạng thái ổn định 5 phút riêng ngay trước khi gây lỗi (bản thử: RTT "trước" làm mốc), và từ lúc Job chạy tới
  hết tải dưới 55 phút vì token truy cập sống 1 giờ; giả thuyết và điều kiện dừng sớm như ADR-0020 §7, (c) xét lag về 0 theo từng
  consumer group. Trước đó thiết kế là một lượt k6 chạy suốt mọi thí nghiệm: lượt dài hơn 1 giờ cần k6 đăng nhập lại giữa chừng (code
  chỉ để diễn tập), còn mỗi giả thuyết trạng thái ổn định nên đo ngay trước lỗi của chính nó. Cuối kịch bản chạy đúng các lệnh gỡ của buổi cloud (`helm uninstall`, xoá namespace, xoá CRD
  `chaos-mesh.org`) và kiểm không còn gì: diễn tập luôn lệnh gỡ. Kyverno đường dev là Audit nên `pod-failure` ở `svp` không bị chặn;
  thí nghiệm (c) vẫn ở `svp-data` như thiết kế. Chaos Mesh 2.8.5 chỉ được CI thử tới Kubernetes 1.35, k3s là 1.36: ghi ở Kết quả nếu
  có lỗi version (không có, k3s v1.36.5: Kiểm chứng sau).
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
| Setup trước bước kịch bản ≤ 20 phút ở cả ba job | Thời gian các bước setup ở lượt đầu mỗi job (`gh run view --json jobs`) | `compose`: 1 phút 35 s (job 20:18:41 → bước kịch bản 20:20:16 UTC, [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)); `k3d`: 2 phút 28 s (20:46:01 → 20:48:29 UTC, [40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)); lượt 4: 1 phút 51 s (00:10:46 → 00:12:37 UTC, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)); lượt 5: 1 phút 28 s (01:38:49 → 01:40:17 UTC, [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)). `gitops`: 6 phút (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534) lần chạy 2; bước kịch bản 57 phút). Đạt ở cả ba job |
| Miễn trừ giới hạn pull của Docker Hub cho runner GitHub cũng áp cho pull từ containerd trong node k3d | `dev-k3d`, `gitops`: không event `Failed` nào có `429 Too Many Requests` trong `kubectl get events -A` của artifact, không lỗi 429 ở `docker pull` | `dev-k3d` lượt 1 ([40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651)): 41 lần đọc event (0 lỗi), 0 pull bị từ chối 429, 0 output có 429; lượt 2 ([40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975)): như lượt 1; mới kéo image tới wave 3, chưa kết luận; lượt 3 ([40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978)): kéo image của mọi wave 0–7 (gateway, web lấy từ registry k3d), 59 lần đọc event (0 lỗi), 0 pull bị từ chối 429, 0 output có 429: đạt cho `dev-k3d`; lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): 67 lần đọc (0 lỗi), 0 pull 429; lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): 68 lần đọc (0 lỗi), 0 pull 429; `gitops`: lượt [40618612946](https://github.com/anhnvcoder/short-video-platform/actions/runs/40618612946) (2026-10-28) có 1 pull bị từ chối 429, của ECR Public (Redis của chart Argo CD), không phải Docker Hub: đã đổi image đó sang Docker Hub ghim digest (`298e1bc`); lượt [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534) lần chạy 2: 54 lần đọc (0 lỗi), 0 pull 429. Đạt cho Docker Hub ở cả hai đường; giới hạn của ECR Public ẩn danh là chuyện khác, không có miễn trừ nào cho runner |
| Script k3d chạy trên bash 5 và coreutils GNU sau các sửa của phần 1 | `dev-k3d` xanh | Lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): 13 trên 14 bước đạt. Lịch abort của `drill-k8s-canary` in `date: <giây>: No such file or directory` thay cho giờ (`date -r` của BSD trong `hms` của `deploy/k8s/drills/canary.sh`; chỉ phần in, phép kiểm vẫn đạt), đã đổi sang cách chạy được cả hai nơi. `drill-k8s-threats` đỏ, chưa biết mục nào (mục Kết quả, lượt 4). Lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): lịch abort in giờ đúng; mục WEB-7 của `drill-k8s-threats` dừng vì `local i` không giá trị (bash 3.2 gán `""`, bash từ 4.0 để chưa đặt) rồi `$((i + 1))` dưới `set -u`; đã sửa, các script diễn tập và cài đặt của hai kịch bản không còn chỗ như vậy. Lượt 6 ([40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740), chỉ `k8s-up`, `k8s-smoke`, `drill-k8s-threats`): `drill-k8s-threats` 16/16 mục PASS, WEB-7 chạy hết (HTML bốn trang, hai payload RSC, tìm token). Đạt: 14 bước của `dev-k3d` đều đã đạt trên runner (13 ở lượt 5, `drill-k8s-threats` ở lượt 6) |
| Broker Redpanda của chart khởi động trên runner x86_64 với `--reserve-memory=128M` (`vm.min_free_kbytes` 67 584 kB) | `dev-k3d`: `make k8s-up` qua release `redpanda`; `verify-host.sh` in `vm.min_free_kbytes` | Đạt (2026-10-24, [40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978)): `verify-host.sh` in `vm.min_free_kbytes 67584 kB`, đúng số suy từ lỗi của lượt 2; release `redpanda` Ready, `redpanda-0` 2/2 Running, 0 restart trong 52 phút; RAM cao nhất của container `redpanda` 232 MiB, sidecar 165 MiB. Lượt 4 ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): như vậy, 0 restart trong 61 phút, `redpanda` cao nhất 301 MiB; lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): 0 restart trong 62 phút, cao nhất 361 MiB |
| Controller Argo Rollouts chạy được plugin Gateway API trên node amd64 của runner (bản `linux-amd64` cùng release, `--set-json` của `deploy/k8s/install.sh`) | `dev-k3d`: `make k8s-up` in `ok    Argo Rollouts gets the Gateway API plugin built for amd64 nodes`, rồi `rollout gateway Healthy`, `rollout web Healthy` | Đạt (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): `k8s-up` in đúng dòng đó trước `ok    argo-rollouts`, rồi `rollout gateway Healthy`, `rollout web Healthy` (1 109 s); `drill-k8s-canary` đổi trọng số qua plugin (25 %, 50 %, 100 %, abort về 100/0) |
| Hai worker cùng transcode trên runner 4 vCPU giữ (c) | `dev-k3d` (đường dev), `gitops` (D1) | Đường dev: đạt (2026-10-25, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985)): hai worker cùng transcode từ 00:53:53Z tới 00:56:10Z (14 mẫu 10 s liền, CPU của cả hai node 130–240 %, mỗi pod 1 338–1 990m theo `kubectl top`, CPU bận của máy tới 99 %); `drill-k8s-keda` PASS, k3s server `RestartCount` 0 và `StartedAt` không đổi suốt kịch bản, không node `NotReady` ở mẫu nào. Lượt 5 ([40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)): đạt lần hai, hai worker cùng transcode từ 02:20:58Z tới 02:22:15Z (8 mẫu 10 s liền), k3s server `RestartCount` 0, `StartedAt` không đổi. Hai khoảng này tính tay từ CPU của node và `kubectl top`; từ 2026-10-25 sampler tự đếm (dòng dưới). Lượt 7 ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)): `drill-k8s-keda` PASS, (c) giữ, nhưng hai worker cùng transcode chỉ một mẫu: diễn tập không bảo đảm khoảng đó, độ dài của nó tuỳ cách chia partition (mục Kết quả, lượt 7). `gitops` (D1, hai lượt, mỗi lượt ≥ 6 mẫu liền): phần 3; với diễn tập như hiện nay D1 có thể trượt vì cách chia partition chứ không vì runner, nên phải xử lý điều đó trước phần 3 |
| Argo CD sync qua HTTPS ẩn danh, không Secret repo | `gitops`: mọi Application Synced; `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository` rỗng | Sync đạt (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534)): 25/25 Application Synced/Healthy, sync cuối Succeeded ở `298e1bc`, root đọc `https://github.com/anhnvcoder/short-video-platform.git` không credential. Phép đếm Secret repo chưa chạy thành lệnh riêng: theo cách dựng không có Secret nào như vậy (cluster mới, `gitops.sh` không tạo, values Argo CD không có `repositories` hay `credentialTemplates`), thêm phép kiểm tường minh vào bước `gitops-env` ở lượt trên `main` |
| Kyverno từ chối digest manifest con của web bằng rule chữ ký | `gitops`: ca (b) của `drill-k8s-supplychain` | Đạt (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534)): manifest con amd64 `sha256:70f5e90f…` của web bị rule chữ ký từ chối (ReplicaSet `FailedCreate` "image without a keyless signature"), không cần `drill-unsigned` |
| chaos-daemon dùng được socket containerd của k3s; `sch_netem` có trên kernel runner | `chaos`: NetworkChaos trên pod thử | Đạt (2026-10-28, [40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770), [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)): 2/2 chaos-daemon Ready, 23 CRD, NetworkChaos thử `injected` qua socket `/run/k3s/containerd/containerd.sock`, mỗi kết nối chậm thêm 183 / 203 ms trong lúc trễ, −9 / 0 ms sau; `sch_netem` đã nạp sẵn trên cả hai kernel (6.17.0-1022-azure, 7.0.0-1017-azure), không cần cài gói; không lỗi version của chart 2.8.5 trên k3s v1.36.5. Hai lượt trước không kết luận được (webhook không endpoint, rồi controller khởi động lại liên tục vì `RemoteCluster`; Kết quả, lượt `chaos` 1, 2) |
| Driver CSI hostpath, snapshot controller và Velero 1.18.4 chạy trên k3s 1.36 | `velero`: backup có VolumeSnapshot, restore PVC từ snapshot | Đạt (2026-10-28, [40620319661](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620319661), [40626700272](https://github.com/anhnvcoder/short-video-platform/actions/runs/40626700272)): driver v1.19.0 Ready trước Redpanda, PVC Redpanda trên `hostpath.csi.k8s.io`, backup Completed có 1 VolumeSnapshot CSI, restore Completed sau 18 s, pod Ready sau 40 / 35 s; không lỗi version của Velero 1.18.4 hay driver trên k3s 1.36. Cảnh báo PodSecurity `restricted` (chỉ cảnh báo, namespace `csi-hostpath` enforce `privileged`) in ở `k8s-up` |
| trivy đọc được lockfile của pnpm 12 | `make web-lockfile-scan` với ca âm | Đạt (2026-10-24): lockfile v9.0 của pnpm 12, trivy đọc 997 gói npm (gồm dev dependency; `pnpm list --depth Infinity` 988 gói đã cài, lockfile 1 012 mục gồm gói tuỳ chọn của nền tảng khác; thiếu `--include-dev-deps` chỉ 319); ca âm (`minimist` 1.2.8 → 1.2.5 trong bản sao) exit 2 với CVE-2021-44906; lockfile trivy không đọc được (0 gói) exit 2. Job `web` trên runner: 997 gói, CRITICAL 0 ([40157835981](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157835981)) |
| trivy nhận `misconfigurations` với `paths`, `expired_at` trong tệp bỏ qua của `trivy config` | `make trivy-config` trước và sau khi thêm một mục: số kết quả giảm đúng mục đó | Đạt (2026-10-24): `make trivy-config` 18 → 0 kết quả trên 31 target (4 sửa, 14 vào `deploy/ci/trivy-config-ignore.yaml`, hạn 2027-01-22); tệp tạm có KSV-0125 chỉ cho file của Valkey thì cảnh báo của MinIO vẫn hiện (`paths` đúng phạm vi); `expired_at` là hôm nay thì DS-0026 hiện lại, là ngày mai thì bị bỏ |
| Rule mới của `RateLimitFallbackActive` đúng tám ca (a)–(h) của mục 11 và giữ RL-2 | `make slo-check` (test promtool); `compose-obs` (`drill-obs-threats` RL-2: page trong 240 s) | Test promtool: `make slo-check` xanh trong job `config` của lượt CI [40129094568](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129094568) (`main` `a9b035a`). RL-2 trên runner ([40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687)): page `startsAt` 76 s, thấy trong Alertmanager 81 s sau login đầu (hạn 240 s): đạt; lượt 2 ([40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276)): 88 s, 91 s |
| Sampler đếm đúng worker đang transcode trên runner: cgroup của tiến trình `ffmpeg` có UID của pod media-worker (mục 2, sửa 2026-10-25) | `dev-k3d` với `targets='drill-k8s-keda ram-peak'` (hay lượt đủ kịch bản): cột worker transcode của `samples/docker.tsv` lên 2 đúng khoảng CPU của hai pod media-worker cùng cao (`samples/pods.tsv`), `ram-peak.json` có cửa sổ 6 mẫu và MEM USAGE trừ `active_file` | Đếm đúng (2026-10-25, [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327), `targets='drill-k8s-keda ram-peak'`): trong diễn tập 64 trên 69 mẫu có hai pod `Running`, nhưng cột worker transcode là 1 ở 36 mẫu, 2 ở một mẫu (04:22:41Z, giữa lúc pod thứ hai nhận partition và lúc ghim, đúng mốc 86,2 s và 89,5 s của diễn tập), 0 sau `READY` cuối. Mỗi mẫu có node trên 150 % CPU đều đếm ít nhất 1, mẫu đếm 0 trong diễn tập không node nào trên 150 %; ba pod lần lượt transcode trên cả hai node đều được đếm; `kubectl top` cho cùng hình (một pod 1 873–2 000m, pod kia 1m, trừ mẫu chuyển giữa hai pod lúc 04:23:52Z và mẫu trễ sau `READY` cuối lúc 04:27:56Z). Cửa sổ 6 mẫu và MEM USAGE trừ `active_file` của `ram-peak.json` chưa có số: lượt này thật sự chỉ một worker transcode mỗi lúc (mục Kết quả, lượt 7); kiểm ở lượt đầu có khoảng hai worker cùng transcode. Test của `verify-collect-test.sh` (mẫu giả của `/proc`, `docker`, `kubectl`, `pgrep`; cả đường cgroupfs lẫn systemd, `ffmpeg` ngoài pod, pod không phải media-worker) xanh ngày 2026-10-25 |
| Lượt `schedule` chạy job `gitops` (từ 2026-10-30) cạnh `compose`, `k3d`: `wait-release`, `measure-gitops` in lý do lượt lịch, ca (c), (l) quá hạn SKIP kèm `NOTE`, mọi bước khác đạt, `record-stg` ghi bản ghi stg `success` | Lượt lịch đầu sau khi merge (**kiểm sau merge**): `gh run view <id>`, `results.tsv` và log `drill-k8s-supplychain` của artifact `verify-gitops`, bản ghi stg mới trên `svp-gitops` | Chưa kiểm. Ca (c), (l) chỉ được chứng minh ở lượt dispatch chạy trong 72 giờ sau lượt `images.yml -f drill=true` hay rescan bản đó |
| Lượt `schedule` chạy `compose` và `k3d` song song trên `main`, mỗi job đúng kịch bản của nó, mọi bước, hai artifact | Lượt lịch đầu sau khi merge vào `main` (**kiểm sau push**): `gh run list --workflow verify.yml --event schedule`, hai job, `results.tsv` không bước nào `not in targets` | Bước kiểm ref theo `$GITHUB_EVENT_NAME:$GITHUB_REF` qua với `workflow_dispatch` trên nhánh ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)). Lượt lịch: chưa kiểm |

## Kết quả

Mỗi lượt dispatch ghi một dòng (ngày, kịch bản, ref và commit, link lượt chạy, runner đủ hay không), số đo vào bảng của dòng
dời tương ứng (D1–D27, mục 5), và dòng nào sang B hay giai đoạn 7 kèm lý do.

| Kịch bản | Lượt (ngày, commit, link) | Runner đủ | Kết quả chính |
| --- | --- | --- | --- |
| `compose-obs` | 1: 2026-10-24, `main` `a9b035a`, [40129183687](https://github.com/anhnvcoder/short-video-platform/actions/runs/40129183687) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 156 MiB, không OOM, đĩa trống thấp nhất 67,9 GiB, không container nào restart ngoài các lần diễn tập dựng lại | Đỏ vì hai lỗi của script, không vì runner: WEB-9 của `drill-obs-threats` dừng giữa chừng, `make web-lighthouse` ×3 không mở được Chrome nên không có LCP; mọi bước còn lại đạt (dưới đây). Đã sửa, xem lượt 2 |
| `compose-obs` | 2 (lượt cuối của phần 1): 2026-10-24, `feat/stage6b-verify-results` `0cb842e`, [40132157276](https://github.com/anhnvcoder/short-video-platform/actions/runs/40132157276) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 658 MiB, không OOM, đĩa trống thấp nhất 67,9 GiB, không container nào restart ngoài các lần diễn tập dựng lại | Mọi bước đạt trừ D17: Lighthouse chạy đủ 3 lượt, LCP median của `/` 3 253 ms vượt 2 500 ms (bước `lcp` đỏ vì số đo, không vì script); `/v/{id}` 2 182 ms đạt (dưới đây) |
| `compose-obs` | 3 (phần 2, RustFS): 2026-10-25, `feat/stage6b-objstore` `f63c484`, [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781) | Đủ theo `runner.txt`: xong trong hạn, `MemAvailable` thấp nhất 8 072 MiB, swap tối đa 1 MiB, không OOM, đĩa trống thấp nhất 66,7 GiB, `compose_no_restart=true`; nhưng sampler của lượt này chưa đếm restart của container đã bị gỡ hay dựng lại (đã sửa ở `a1741ff`, mục 2), nên tiêu chí restart đọc ở lượt 4 | Mọi bước object store đạt (D15); `web-lighthouse` ×3 và `lcp` đỏ như lượt 2 (D17) |
| `compose-obs` | 4 (phần 2, cách đếm restart và so RAM mới): 2026-10-25, `feat/stage6b-objstore` `a1741ff`, [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 678 MiB, swap tối đa 4 MiB, không OOM, đĩa trống thấp nhất 66,9 GiB, `compose_no_restart=true` theo cách đếm mới (mẫu `restarts.tsv` gồm cả mẫu ngay trước `make down` của đường quay lại) | Như lượt 3: mọi bước object store đạt (D15; RAM `s3` đỉnh 325,1 MiB trong `measure-upload`, tính lại từ `samples/compose.tsv` vì `ram-s3-upload.json` thiếu mẫu cuối), chỉ `web-lighthouse` ×3 và `lcp` đỏ (D17: median `/` 2 948 ms, `/v/{id}` 2 261 ms) |
| `compose-obs` | 5 (phần 3, D17 vòng 1, chỉ bước chọn): 2026-10-26, `feat/stage6b-runner-deep` `708c5c3`, [40328971601](https://github.com/anhnvcoder/short-video-platform/actions/runs/40328971601), `smoke`, `web-lighthouse` ×3, `lcp` | Đủ: xong trong hạn, `MemAvailable` thấp nhất 8 744 MiB, swap 0, không OOM, `compose_no_restart=true` | `lcp` đạt: median `/` 2 473 ms, `/v/{id}` 2 094 ms (`benchmarkIndex` 1 882–2 009); ba bước `web-lighthouse` đỏ vì TBT 266–443 ms (ngưỡng 200) |
| `compose-obs` | 6, 7 (phần 3, D17 vòng 2): 2026-10-26, `1147015` [40335702467](https://github.com/anhnvcoder/short-video-platform/actions/runs/40335702467) và `6d4a5ce` (cùng code web) [40341024107](https://github.com/anhnvcoder/short-video-platform/actions/runs/40341024107), bước chọn như lượt 5 | Đủ: `MemAvailable` thấp nhất 8 680 / 7 756 MiB, không OOM, không restart | `lcp` đỏ: sáu mẫu `/` median khoảng 2 555 ms, TBT khoảng 454 ms, không tốt hơn vòng 1, nên vòng 2 bị bỏ (`6073b0f`) |
| `compose-obs` | 8 (phần 3, xác nhận vòng 1): 2026-10-26, `6073b0f`, [40344795348](https://github.com/anhnvcoder/short-video-platform/actions/runs/40344795348), bước chọn như lượt 5 | Đủ: `MemAvailable` thấp nhất 8 367 MiB, không OOM, không restart | `lcp` đỏ: `/` 2 749 · 2 200 · 2 622 ms, `/v/{id}` 2 464 · 2 513 · 2 645 ms; TBT 147–220 ms. Sáu mẫu của vòng 1: median `/` khoảng 2 548, `/v/{id}` khoảng 2 488 ms (D17 dưới đây) |
| `dev-k3d` | 1: 2026-10-24, `main` `a9b035a`, [40131253651](https://github.com/anhnvcoder/short-video-platform/actions/runs/40131253651) | Chưa kết luận: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 10 807 MiB, không OOM, không evict, đĩa trống thấp nhất 66,0 GiB; `within_deadline=false` chỉ vì hai bước RAM nghỉ chờ đủ 900 s một pod không bao giờ Ready, hệ quả của bước đỏ chứ không phải runner thiếu | Đỏ ở bước đầu `make k8s-up`: broker Redpanda thoát ngay mỗi lần khởi động, release `redpanda` (wave 3) không Ready; mọi bước sau đỏ theo. Nguyên nhân chưa biết vì lượt không giữ log container; `deploy/k8s/install.sh` giờ in log đó khi một release không Ready (dưới đây). Nguyên nhân ở lượt 2 |
| `dev-k3d` | 2: 2026-10-24, `feat/stage6b-verify-results` `d767d42`, [40137101975](https://github.com/anhnvcoder/short-video-platform/actions/runs/40137101975) | Chưa kết luận, như lượt 1: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 10 877 MiB, không OOM, không evict, đĩa trống thấp nhất 66,1 GiB; `within_deadline=false` cùng lý do | Đỏ cùng chỗ. Log broker cho nguyên nhân: Seastar không khởi động vì phép kiểm bộ nhớ của nó trừ `vm.min_free_kbytes` của kernel, trên runner x86_64 lớn hơn trong VM Docker Desktop. Đã sửa ở `deploy/k8s/values/redpanda.yaml` (dưới đây). Chờ lượt 3 |
| `dev-k3d` | 3: 2026-10-24, `feat/stage6b-verify-results` `ca102a4`, [40140868978](https://github.com/anhnvcoder/short-video-platform/actions/runs/40140868978) | Chưa kết luận: k3s server không restart, node luôn Ready, `MemAvailable` thấp nhất 9 051 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 59,1 GiB, `within_deadline=true`; cluster thiếu pod gateway, web nên chưa có tải nào (KEDA không có video để transcode) | Redpanda qua (lỗi của lượt 1–2 hết). Đỏ ở `make k8s-up` sau 1 926 s: Rollout `gateway` (wave 7, lần cài đầu) đứng ở `Progressing`, ReplicaSet tạo mà không bao giờ có pod, vì plugin Gateway API của Argo Rollouts ghim bản `linux-arm64` không chạy được trên node amd64. Mọi bước sau đỏ theo (không có gateway, web chưa cài). Đã sửa ở `deploy/k8s/install.sh` (dưới đây). Chờ lượt 4 |
| `dev-k3d` | 4: 2026-10-25, `feat/stage6b-verify-results` `d1b4529`, [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985) | Đủ: xong trong hạn (`within_deadline=true`), `MemAvailable` thấp nhất 6 172 MiB, swap tối đa 85 MiB, không OOM, không evict, đĩa trống thấp nhất 56,6 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Plugin amd64 đúng (lỗi lượt 3 hết). 13 trên 14 bước đạt: smoke, RAM nghỉ (b) cho đường dev, PDB, canary gateway, source map, e2e web 64/64 với GlitchTip, `drill-k8s-web-obs`, KEDA với hai worker cùng transcode, backup `latest` và `pitr`. RAM đỉnh (a) 9 994 MiB vượt 8,7 GiB. `drill-k8s-threats` đỏ (exit 2), chưa biết mục nào: bộ lọc artifact bỏ oan dòng phán quyết của nó. Đã sửa bộ lọc (dưới đây). Chờ lượt 5 |
| `dev-k3d` | 5: 2026-10-25, `feat/stage6b-verify-results` `07e32fa`, [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243) | Đủ: xong trong hạn (`within_deadline=true`), `MemAvailable` thấp nhất 6 183 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 56,6 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Dòng phán quyết của `drill-k8s-threats` tới artifact (sửa bộ lọc của lượt 4 đúng): 15/16 mục PASS, WEB-7 FAIL vì mục dừng giữa chừng dưới bash 5, không vì một phép kiểm trượt. Đã sửa ở `deploy/k8s/drills/threats.sh` (dưới đây). 13 bước còn lại đạt như lượt 4; RAM đỉnh theo định nghĩa 8 878 MiB. Lượt đủ kịch bản cuối của phần 1 |
| `dev-k3d` | 6 (chỉ bước chọn): 2026-10-25, `feat/stage6b-verify-results` `2df0493`, [40157833740](https://github.com/anhnvcoder/short-video-platform/actions/runs/40157833740), `targets='k8s-smoke drill-k8s-threats'` | Đủ cho các bước đã chạy: xong trong hạn, `MemAvailable` thấp nhất 8 682 MiB, swap 0, không OOM, không evict, đĩa trống thấp nhất 59,5 GiB, k3s server giữ `RestartCount` và `StartedAt`, node luôn Ready, 0 pull 429; lượt chọn bước không thay lượt đủ kịch bản (mục 3) | Xanh, 24 phút: `k8s-up` 1 083 s, `k8s-smoke` 58 bước, `drill-k8s-threats` 16/16 mục PASS gồm WEB-7 (sửa của lượt 5 đúng); 11 bước `skipped` `not in targets`. Dừng sớm và chọn bước chạy đúng trên runner |
| `dev-k3d` | 7 (lượt cuối của phần 1, chỉ bước chọn): 2026-10-25, `feat/stage6b-verify-results` `77bd25c`, [40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327), `targets='drill-k8s-keda ram-peak'` | Đủ cho các bước đã chạy: xong trong hạn, `MemAvailable` thấp nhất 7 802 MiB, swap tối đa 1 MiB, không OOM, không evict, đĩa trống thấp nhất 58,4 GiB, k3s server giữ `RestartCount` 0 và `StartedAt`, node luôn Ready, 0 pull 429 | Xanh, 31 phút: `k8s-up` 1 028 s, `drill-k8s-keda` PASS lần ba (690 s). Sampler đếm đúng worker đang transcode, nhưng lượt này không có khoảng hai worker cùng transcode: 9 video chia 4/2/3 vào ba partition và pod thay vào sau lúc ghim nhận cả hai partition còn video, nên `ram-peak` không có cửa sổ 6 mẫu (đúng định nghĩa, không phải lỗi đếm; dưới đây) |
| `dev-k3d` | 8 (phần 2, RustFS): 2026-10-25, `feat/stage6b-objstore` `50f1cfe`, [40202083397](https://github.com/anhnvcoder/short-video-platform/actions/runs/40202083397) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 6 422 MiB, swap tối đa 2 MiB, không OOM, không evict, đĩa trống thấp nhất 57,6 GiB, k3s server giữ `RestartCount` và `StartedAt`, node luôn Ready, 0 pull 429 | 14/14 bước đạt trên RustFS (D15); sau `50f1cfe` chỉ script kiểm của `compose-obs` đổi, nên là lượt cuối của mọi bước k3d |
| `dev-k3d` | 9 (phần 3, diễn tập KEDA dàn đều partition, chỉ bước chọn): 2026-10-26, `feat/stage6b-runner-deep` `1147015`, [40335732223](https://github.com/anhnvcoder/short-video-platform/actions/runs/40335732223), `targets='drill-k8s-keda ram-peak'` | Đủ: `MemAvailable` thấp nhất 7 754 MiB, không OOM, không evict, k3s server giữ trạng thái, node luôn Ready | Xanh: 9 video chia 3/3/3, hai pod cùng transcode 60 s liền (từ 104,7 s sau lần complete đầu), mỗi video đúng một lần, `ram-peak.json` 3 cửa sổ 6 mẫu (dài nhất 7 mẫu), trung vị trừ `active_file` 7 074,5 MiB |
| `dev-k3d` | 10 (sau [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md)): 2026-10-29, `feat/stage6b-chaos-fixes` `98715d9`, [40810781486](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810781486) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 7 841 MiB, swap 0, không OOM, không evict, k3s server giữ trạng thái, node luôn Ready, 0 pull 429 | Xanh 14/14: `drill-k8s-pdb` gồm feed-service (hai pod ở hai node, evict 201 rồi 429, về 2 pod Ready ở hai node), `drill-k8s-web-obs` trace, rum, errors PASS qua Tempo cấu hình mới; RAM nghỉ (b) đường dev ở điểm 60 s: MEM USAGE trừ `active_file` 5 066 MiB, pod 2 812 MiB (`svp-obs` 1 280, `svp-data` 611, `svp` 266), cuối kịch bản 5 488 / 3 264 MiB; RAM đỉnh (a) trung vị 6 mẫu 9 193,5 MiB (trừ `active_file` 6 685,5), trên 8,7 GiB |
| `gitops` | 1: 2026-10-28, `feat/stage6b-runner-deep` `ff9bdf1`, [40618612946](https://github.com/anhnvcoder/short-video-platform/actions/runs/40618612946) | Không kết luận được: dừng ở bước dựng | Đỏ ở `k8s-gitops-up`: cài Argo CD gặp 429 của ECR Public khi kéo Redis của chart; đổi sang Docker Hub ghim digest ở `298e1bc` |
| `gitops` | 2 (pha (1): Argo CD theo nhánh, bản phát hành của `main` `744f108`, tag `39dcedeacb80`): 2026-10-28, `298e1bc`, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534) lần chạy 2 (lần 1 hỏng ở bước cài module Go vì lỗi mạng của proxy.golang.org) | Đủ: xong trong hạn, `MemAvailable` thấp nhất 4 629 MiB, swap tối đa 24 MiB, không OOM, không evict, đĩa trống thấp nhất 56,6 GiB, k3s server giữ trạng thái, node luôn Ready, 0 pull 429, `gitops_keda_two_transcoding=true` | 13/14 bước `ok`, `gitops-sourcemaps` `skipped` đúng quy tắc của nhánh (image web phát hành trước khi `images.yml` xuất artifact); job đỏ chỉ vì `verify-run.sh` đếm bước `skipped` đó. D1, D3, D4, D7 đạt; RAM (b) và đỉnh (a) của đường GitOps không đạt (D2). D5, D26: pha (2) trên `main`, kiểm sau merge |
| `gitops` | 3 (pha (2) trên `main`, bản phát hành `0f3156f`): 2026-10-29, [40801610039](https://github.com/anhnvcoder/short-video-platform/actions/runs/40801610039) | Đủ trừ `gitops_keda_two_transcoding=false` của lần 1 (`MemAvailable` thấp nhất 6 591 MiB, không OOM, không evict, node luôn Ready) | D5, D26 đạt (dòng dời); `drill-k8s-keda` lần 1 FAIL ở điều kiện chuẩn bị (partition của pod mới hết video trước khi hai pod cùng transcode 60 s), lần 2 đạt |
| `web-canary` | 1, 2: 2026-10-28, `627872b` [40635084121](https://github.com/anhnvcoder/short-video-platform/actions/runs/40635084121), `1cb8c05` [40637616734](https://github.com/anhnvcoder/short-video-platform/actions/runs/40637616734) | Đủ cả hai: `MemAvailable` thấp nhất 7 038 / 7 340 MiB, không OOM, không evict, node luôn Ready | `k8s-up`, `k8s-smoke` xanh; `drill-k8s-web-canary` đỏ vì lỗi của diễn tập: lượt 1 lỗi jq lúc ghi JSON (sửa `1cb8c05`); lượt 2 bản tốt được promote nhưng diễn tập đòi 0 lần đo trượt ở AnalysisRun nền, trong khi run đó có một lần trượt nằm trong `failureLimit: 1` của chính nó (diễn tập nay đọc giới hạn của spec, `1a0f68d`) |
| `web-canary` | 3: 2026-10-28, `1a0f68d`, [40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955) | Đủ: `MemAvailable` thấp nhất 6 952 MiB, swap 0, không OOM, không evict, k3s server giữ trạng thái, node luôn Ready | Xanh 3/3 (`drill-k8s-web-canary` 518 s): bản tốt promote, bản lỗi abort, trả build A promote; D6, D14, D18 (web) ở dưới |
| `k6-cloud-mini` | 1: 2026-10-26, `6073b0f`, [40344818171](https://github.com/anhnvcoder/short-video-platform/actions/runs/40344818171) | Chấm theo tiêu chí trước `52cfd4d` (khi đó mức chưa đòi mọi điều kiện runner có mẫu trong cửa sổ của mức), nên không dùng làm kết quả | Mức 1, 2, 4 `pass`; mức 8 `fail: system` (1 158 `dropped_iterations`) dù CPU máy runner tới 99 %: tiêu chí throttle CFS của k6 không thấy tranh CPU của máy |
| `k6-cloud-mini` | 2: 2026-10-28, `8a5b4e3`, [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867) | Đủ ở mức 1, 2 (mọi điều kiện có mẫu trong cửa sổ, `MemAvailable` thấp nhất 8 467 / 7 771 MiB, throttle k6 0 %); mức 4 `fail: runner` vì `no_oom=false` (dưới đây) | Mức cao nhất đạt: **2 pod**, 110,5 req/s; mức 4 trượt (3 `dropped_iterations`, Tempo OOMKilled ở limit riêng); mức 8 không chạy. D11, D14, D23 ở dưới |
| `k6-cloud-mini` | 3, 4 (sau ADR-0031): 2026-10-29, `feat/stage6b-chaos-fixes` `98715d9` [40810768238](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810768238), `c7ca403` (Job k6 `backoffLimitPerIndex: 0`) [40820505634](https://github.com/anhnvcoder/short-video-platform/actions/runs/40820505634) | `runner_enough` đủ ở mọi mức (`MemAvailable` thấp nhất 8 220 MiB ở lượt 4, không OOM, throttle k6 0 %), nhưng CPU máy ở mức 4 trung bình 89 %, cao nhất 100 %: tiêu chí chưa xét CPU máy (Hệ quả "Xem lại khi") | Mức cao nhất đạt vẫn **2 pod**; mức 4 trượt ở cả hai lượt (lượt 3 chỉ 2/4 pod có summary, lượt 4 đủ 4/4); `tempo-ingest-1`, `-2`, `-4` đạt cả hai lượt, Tempo không OOM (dòng D11) |
| `chaos` | 1: 2026-10-28, `77ae28a`, [40649659955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40649659955) | Không đủ: `no_oom=false` (container `tempo` của `svp-obs/tempo-0` OOMKilled ở limit riêng từ giữa bước (c)) | Đỏ, không kết luận về thí nghiệm: NetworkChaos thử `injected: false` (+3 ms mỗi kết nối), (a) webhook `mpodchaos.kb.io` không có endpoint, (b) bỏ theo bản thử, (c) lỗi không gây ra trong 60 s; artifact chưa có trạng thái của namespace `chaos-mesh`. Thêm chẩn đoán, chờ webhook Ready trước `apply`, kiểm module (`9144215`) |
| `chaos` | 2: 2026-10-28, `9144215`, [40668691396](https://github.com/anhnvcoder/short-video-platform/actions/runs/40668691396) (huỷ tay giữa (c)) | Không kết luận (`within_deadline=false` vì huỷ) | Chẩn đoán cho nguyên nhân gốc: controller-manager khởi động lại liên tục (`timed out waiting for cache to be synced`, log `remoteclusters.chaos-mesh.org is forbidden`), NetworkChaos không bao giờ được reconcile; `sch_netem` không phải nguyên nhân. Tắt controller multi-cluster (`1cb49e6`, mục 7), Event bị từ chối của chính controller không làm hỏng bước cài (`f71aff2`) |
| `chaos` | 3: 2026-10-28, `f71aff2`, [40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770) | Không đủ chỉ vì `no_oom=false`: duy nhất container `tempo` OOMKilled ở limit 768 Mi (64 dòng OOM của kernel cộng dồn, 16 restart), `MemAvailable` thấp nhất 6 552 MiB; không evict, node luôn Ready, k3s server giữ trạng thái, throttle k6 0 %, 0 pull 429 | Cài đạt (cùng pod controller, 0 restart trong 152 s, 0 dòng `forbidden`), bản thử đạt, (a) gateway đạt, **(c) đạt**, gỡ sạch (không còn thí nghiệm, CRD, webhook). (a) feed-service và (b) không gây được lỗi: pod-kill chọn trúng pod Job migrate đã Completed cùng nhãn tên, sửa selector (`ccdf320`). Bước (c) `fail` chỉ vì `no_oom`. 2 giờ 06 phút |
| `chaos` | 4: 2026-10-28, `ccdf320`, [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895), `targets` không gồm (c) và gỡ | Không đủ chỉ vì `no_oom=false` như lượt 3 (44 dòng OOM, 10 restart của `tempo`), `MemAvailable` thấp nhất 8 499 MiB; mọi điều kiện khác đạt | Cài và bản thử đạt; (a) gateway đạt, feed-service **phát hiện**; (b) **phát hiện**. Bước (a), (b) `fail` (phát hiện và `no_oom`). D12 ở dưới |
| `chaos` | 5 (sau ADR-0031): 2026-10-29, `feat/stage6b-chaos-fixes` `98715d9`, [40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085) | Đủ: `no_oom=true`, không container `OOMKilled`, 0 dòng OOM của kernel, `MemAvailable` thấp nhất 8 209 MiB, không evict, node luôn Ready, k3s server giữ trạng thái, throttle k6 0 % | Xanh 11/11: bản thử, (a) gateway, (a) feed-service, (b), (c) đạt, ba `tempo-ingest-chaos-*` đạt, gỡ sạch (mục "Thí nghiệm `chaos`") |
| `velero` | 1: 2026-10-28, `17efcb9`, [40614474717](https://github.com/anhnvcoder/short-video-platform/actions/runs/40614474717) | Đủ: `MemAvailable` thấp nhất 8 473 MiB, không OOM, không evict | 9/10: `drill-restore` đỏ vì `kubectl get backup` phân giải sang Backup của CloudNativePG; script gọi mọi kind Velero bằng tên đầy đủ `*.velero.io` (`8a5b4e3`) |
| `velero` | 2, 3: 2026-10-28, `8a5b4e3` [40620319661](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620319661), `f6038bc` (manifest CSI siết `securityContext`) [40626700272](https://github.com/anhnvcoder/short-video-platform/actions/runs/40626700272) | Đủ cả hai: `MemAvailable` thấp nhất 8 513 / 8 387 MiB, không OOM, không evict, k3s server giữ trạng thái, node luôn Ready | Xanh 10/10 cả hai; D13 đạt, RTO 58 s / 57 s |

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

### Phần 2 theo dòng dời

| # | Kết quả | Lượt, số |
| --- | --- | --- |
| D15 | Đạt: mục 1–11 và 13 của kế hoạch kiểm ADR-0022 (mục 12, Velero, ở phần 3), chi tiết ở mục Kết quả của [ADR-0022](0022-local-object-store-minio-replacement.md) | `compose-obs` [40203123781](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203123781): test tích hợp của store 39 PASS, 0 SKIP; `drill-upload-cleanup`, `drill-obs-threats` (OPS-1 bảy cổng) PASS; RAM `s3` đỉnh 338 MiB trong `measure-upload` (tính lại từ `samples/compose.tsv`: `ram-s3-upload.json` thiếu mẫu cuối, ADR-0022 mục 9 của Kết quả), cao nhất cả lượt 356 MiB (< 512 MiB); đường quay lại MinIO chép 22 video `READY` tạo trên RustFS rồi `make smoke` lại xanh; lượt 4 [40207235062](https://github.com/anhnvcoder/short-video-platform/actions/runs/40207235062) (`a1741ff`) như vậy, RAM `s3` đỉnh 325,1 MiB (tính lại như trên), `compose_no_restart=true` theo cách đếm mới. `dev-k3d` [40202083397](https://github.com/anhnvcoder/short-video-platform/actions/runs/40202083397): `k8s-smoke`, `drill-k8s-threats` 16/16; backup `latest` RTO 89,7 s, RPO ≥ 63,4 s; `pitr` RTO 89,6 s, RPO 37,1 s (lượt MinIO 4, 5: 95,2/92,8 s và 80,8/84,3 s); RAM `s3` đỉnh 286 MiB. Job `stack` [40203127200](https://github.com/anhnvcoder/short-video-platform/actions/runs/40203127200): `make smoke`, `make web-e2e` 64/64 |

### Phần 3 theo dòng dời

Số của runner, ghi cạnh số của máy và của phần 1 (không thay). Artifact `verify-<kịch bản>` của mỗi lượt giữ 30 ngày.

| # | Kết quả | Lượt, số |
| --- | --- | --- |
| D1 | Đạt hai lượt trên đường GitOps; đỉnh (a) không đạt | [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): `drill-k8s-keda N=9` lần 1 / lần 2 PASS: 2 replica Ready sau 11,2 / 8,8 s, hai pod cùng transcode từ 141,8 / 140,2 s giữ 60 / 63 s, chuỗi dài nhất 7 / 14 mẫu liền hai worker transcode (2 / 12 cửa sổ 6 mẫu), 9 video `READY` sau 575,4 / 501,6 s, mỗi video đúng một lần kể cả video bị ngắt khi ghim 1 replica, lag đỉnh 9; (c) giữ: `k3d-svp-server-0` `RestartCount` 0, `StartedAt` không đổi suốt kịch bản; worker đỉnh 1 979m / 1 914m CPU, 698 / 665 MiB. Đỉnh (a): trung vị 6 mẫu 11 049,5 / 11 170,5 MiB (trừ `active_file` 9 995,5 / 10 106,5), trên 8,7 GiB. Diễn tập trước đó dàn đều partition (N là 6, 9 hay 12, đúng N/3 video mỗi partition, chờ tới 240 s cho tới khi mọi pod cùng có job liền 60 s): `dev-k3d` [40335732223](https://github.com/anhnvcoder/short-video-platform/actions/runs/40335732223) xanh, 3/3/3, 3 cửa sổ 6 mẫu |
| D2 | **(b) không đạt cho đường GitOps trên runner**: cluster vượt ngân sách thật; người học quyết cắt theo thứ tự cũ hay ghi nhận (mục 2) | [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): điểm 60 s (02:45:03–02:45:53Z) MEM USAGE trung vị 8 937 MiB, trừ `active_file` 7 510 MiB (ngưỡng 6 656 MiB), tổng pod 4 073 MiB (`argocd` 1 024, `svp-obs` 1 334, `svp-data` 702, `svp` 357); cuối kịch bản (03:29:43Z) 9 863 / 8 789 MiB, pod 5 547 MiB (`argocd` 1 655, application-controller 829 → 1 418 MiB). Đường dev: 6 084 MiB ở 60 s (phần 1); phần chênh phần lớn là Argo CD |
| D3 | Đạt (pha (1)) | [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): 7/7 bản phát hành đã ký, attestation `vuln` ≤ 48 giờ, hai nền tảng, không CRITICAL, kéo ẩn danh từ GHCR; `k8s-gitops-up` 582 s; 25/25 Application Synced/Healthy qua HTTPS ẩn danh; overlay stg có hiệu lực (pod gateway `SENTRY_ENVIRONMENT=stg`, bước `gitops-env`); `k8s-smoke` 58/58; e2e 64/64 (chromium 29, webkit 29, publishing 3 + 3), khung đầu p50/p95 chromium 94/115 ms, webkit 104/224 ms; mọi pod `svp` restart 0. Rollout `web` Healthy đọc qua Application `web` Healthy (Argo CD tính health của Rollout theo `status.phase`) |
| D4 | Đạt | [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): policy Deny + Fail; (a) nhận hai lần (1 010 / 638 ms); (b) manifest con amd64 của web bị rule chữ ký từ chối; (c) `drill-vulnerable` từ chối vì CRITICAL; (d) registry k3d (274 ms) và Docker Hub; (e) không digest; (f) policy tạm 5 s; (g) admission controller tắt: pod `svp` bị từ chối, `svp-probe` được nhận, webhook trả như ảnh chụp; (h) ephemeral chưa ký từ chối, đã ký nhận; (i) UPDATE chưa ký từ chối; (k) SKIP theo thiết kế (Enforce) |
| D5 | Đạt (pha (2) trên `main`) | Pha (2) [40801610039](https://github.com/anhnvcoder/short-video-platform/actions/runs/40801610039) (2026-10-29): `gitops-sourcemaps` chọn lượt `images.yml` [40733866890](https://github.com/anhnvcoder/short-video-platform/actions/runs/40733866890) (`0f3156f`) có `web-sourcemaps-amd64` cho manifest con amd64 của digest web đang chạy, 30 source map, 13 chunk `/login` có debug ID đều có trong bộ map, 29 file tải lên GlitchTip; `SVP_E2E_GLITCHTIP=1 make k8s-web-e2e` 66/66, event GlitchTip chromium 10/10, webkit 13/13 frame map về source của web; `drill-k8s-web-obs` trace, rum, errors PASS. Pha (1) [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): `gitops-sourcemaps` `skipped` (không lượt `images.yml` nào của `39dcede` có `web-sourcemaps-amd64` cho digest đang chạy: bản đó build trước khi `images.yml` xuất artifact), e2e không `SVP_E2E_GLITCHTIP=1`, `drill-k8s-web-obs` trace và rum PASS, `errors` SKIP có lý do. Phía sản xuất kiểm trên máy: `deploy/ci/build-image.sh web arm64` xuất 30 source map, debug ID của 29 chunk có ID trong image đều có trong bộ map |
| D6 | Đạt; tỷ lệ action 409 vượt 10 % nên mở việc xét khoá Server Action cố định (ADR riêng, chưa làm) | [40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955): build B cùng nguồn, `SVP_BUILD_ID` khác (image khác A); bản tốt qua 25 %, 50 %, promote 128,9 s sau khi đổi; bản lỗi (`GATEWAY_URL` tới Service không có, `GET /api/feed/explore` 502) bị abort 83,4 s sau khi canary nhận traffic ("canary-5xx-ratio … failed (2) > failureLimit (1)"), HTTPRoute về 100/0, pod stable cùng UID, không restart; trả build A bằng canary thứ hai, promote 127,4 s. Đối chứng có lệch bản: tab cũ mở trước canary nhận action 409 6, chunk 404 2, `deploymentId` khác 11 lần và tải lại 2 lần (action 1, chunk 1). Tải lại nhiều nhất của một client trong một canary: 2 (giới hạn 2). `web-asset` 404: 0 (156 + 154 request ở hai canary tốt). Server Action ở hai canary tốt: 133 gửi, 30 trả 409, tỷ lệ 22,6 % |
| D7 | Đạt trên đường GitOps | [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): 16/16 mục PASS (gồm WEB-7, WEB-2, WEB-10, WEB-13, WEB-8, BAK-1, RBAC, PSA), 357 dòng `ok` gồm đối chứng, không giá trị nào của 10 Secret đã đọc trong output |
| D9 | `resources` web giữ (limit 384 Mi, request 128 Mi, limit CPU 1); RAM như D2 | Đường GitOps [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534): working set mỗi pod web 88 / 90 MiB ở 60 s, 138 / 146 MiB cuối kịch bản, cao nhất 149 MiB (trong e2e). k6 [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867): cao nhất 178 MiB (mức 4), 1,5 × 178 = 267 → bội 64 là 320 Mi < 384 Mi; throttle CPU web 1,5 % (< 5 %) |
| D11 | Mức cao nhất đạt trên runner: **2 pod** (10 % thiết kế), không phải năng lực hệ thống; 20 pod → GĐ7. Chạy lại 2026-10-29 sau [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md): vẫn 2 pod; mức 4 chạm trần CPU của runner | [40820505634](https://github.com/anhnvcoder/short-video-platform/actions/runs/40820505634) (`c7ca403`): mức 1: 55,2 req/s, mọi threshold, drop 0, 429 0, k6 p99 explore 15,4 / following 10,2 / web `/` 104,8 ms, gateway p99 explore 19,9 ms, `p99_E` 96,1 ms; mức 2: 110,4 req/s, mọi threshold, drop 0, k6 p99 25,2 / 17,0 / 104,3 ms, gateway 23,9 ms, `p99_E` 96,5 ms; mức 4: 220,2 req/s, **4/4 pod có summary** (Job `backoffLimitPerIndex: 0`; `run.sh logs` báo khi thiếu pod), trượt: 125 `dropped_iterations`, k6 p99 explore 698 ms (gateway 674), following 444 ms, `p99_E` 1 851 ms, lỗi web trên 0,1 %; CPU máy runner (`samples/host.tsv`) trung bình 33 % ở mức 1, 51 % ở mức 2, **89 %** (cao nhất 100 %, 27/102 mẫu ≥ 95 %) ở mức 4: trần CPU của một VM 4 vCPU chạy k3d, mọi service, observability và 4 pod k6, không phải số của hệ thống; `runner_enough` vẫn `true` vì tiêu chí chưa xét CPU máy, nên mức 4 ghi `fail: system` (Hệ quả "Xem lại khi"). Tempo không OOM ở mức nào, `tempo-ingest-1`, `-2`, `-4` đạt (0 span bị từ chối hay bỏ; 726 / 1 444 / 3 036 span/s). [40810768238](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810768238) (`98715d9`): mức 1, 2 như trên (55,2 / 110,5 req/s, đạt); mức 4 chỉ 2/4 pod có summary (`backoffLimit: 0` làm Job xoá pod đang chạy khi một pod trượt), số của nó là nửa tải, không dùng. Lượt 2026-10-28: [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867): mức 1: 55,2 req/s, 11/11 threshold, `dropped_iterations` 0, 429 0, k6 p99 explore 10,4 / following 7,3 / web `/` 48,7 / `/v/[id]` 56,3 / `/login` 47,9 ms, gateway p99 explore 9,7 / following 5,0 ms, `p99_E` 49,5 ms, CPU web 0,052 core/pod; mức 2: 110,5 req/s, 11/11, drop 0, 429 0, k6 p99 12,3 / 7,8 / 60,2 / 55,3 / 48,0 ms, gateway 10,0 / 5,4 ms, `p99_E` 50 ms, CPU web 0,082 core/pod, working set 162 MiB; mức 4: Job `Failed` (`backoffLimit: 0`, summary của 1/4 pod), 3 `dropped_iterations`/43 139 nên hệ thống cũng trượt, k6 p99 32,5 / 20,7 / 107,2 / 107,7 ms, `p99_E` 98,3 ms; pod `svp-obs/tempo-0` OOMKilled ở limit 768 Mi của nó rồi `CrashLoopBackOff` (6 restart) dù máy runner còn 7 580 MiB và node luôn Ready: tiêu chí `no_oom` đếm cả container chết ở limit riêng nên ghi `fail: runner`, bản chất là cấu hình Tempo của project (Hệ quả "Xem lại khi") |
| D12 | Đạt: bản thử, (a) gateway, (a) feed-service, (b), (c) đạt ở lượt 2026-10-29 sau [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md); hai phát hiện của lượt 2026-10-28 đã sửa; gỡ sạch. Version EKS và kernel AL2023 → GĐ7 | [40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085) (`98715d9`, mọi bước, runner đủ, `no_oom=true`); lượt 2026-10-28: [40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770) ((c), gỡ), [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895) ((a), (b)); mỗi thí nghiệm một lượt k6 1 pod: bảng ở mục "Thí nghiệm `chaos`" dưới đây |
| D13 | Đạt (hai lượt) | [40620319661](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620319661), [40626700272](https://github.com/anhnvcoder/short-video-platform/actions/runs/40626700272): backup Completed, 1 VolumeSnapshot CSI, 17 kind trong backup, không Secret; tarball 14,8 MB multipart ba phần với CRC32 COMPOSITE trên RustFS; xoá StatefulSet, PVC, volume và 12 ConfigMap fixture (600 KiB ngẫu nhiên mỗi cái); restore Completed sau 18 s; bước 5 PASS (offset bằng lúc backup ở 5 group-partition có offset > 0, lag 0, DLQ không đổi); sha256 12 fixture khớp; smoke sau restore qua; RTO 58 s / 57 s. BAK-2 25 PASS mỗi lượt; NetworkPolicy chỉ cho pod server Velero tới `s3:9000` (pod khác bị từ chối, DNS vẫn mở). Gỡ sạch: không còn CRD `*.velero.io`, webhook, cluster RBAC, namespace, NetworkPolicy; bucket `velero` rỗng |
| D14 | Đạt: `canaryLimits.p99Ms` của web 500 → **250 ms**; không thêm HPA | Quy tắc mục 8 trên mức 2 của [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867): 2 × `p99_E` 50 ms = 100 ms → bucket 250 ms; CPU web 8,2 % limit (< 50 %), p99 k6 web mức 2 / mức 1 = 1,24× (`/`), 0,98× (`/v/[id]`), 1,00× (`/login`) (< 2×) → giữ 2 replica. `web-canary` [40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955) với 250 ms promote bản tốt hai lần, không abort oan |
| D17 | Không đạt ổn định; theo quyết định của người học Lighthouse mô phỏng là tín hiệu hồi quy, chuẩn chất lượng là RUM p75 | Vòng 1 (font nạp sau `load` với font dự phòng chỉnh cỡ, `messages.precompile` của next-intl) giữ; vòng 2 (hydrate không dựng formatter) bỏ vì không có bằng chứng giúp. Sáu mẫu vòng 1 ([40328971601](https://github.com/anhnvcoder/short-video-platform/actions/runs/40328971601), [40344795348](https://github.com/anhnvcoder/short-video-platform/actions/runs/40344795348)): median `/` khoảng 2 548 ms, `/v/{id}` khoảng 2 488 ms (ngưỡng 2 500, trước đó 2 951 và 2 870), TBT 147–443 ms giữa các lượt cùng code, CLS ≤ 0,001, phần tử LCP luôn là ảnh poster. Đòn bẩy còn lại lớn nhất (bỏ hls.js khi trình duyệt có HLS native) trái [ADR-0016](0016-web-client.md) §8; người học giữ một đường phát hls.js. RUM trên cluster GitOps ([40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534), lượt e2e của Playwright trên runner, không throttle): LCP p75 641 ms (`/` 1 208, `/v/[id]` 733 ms), CLS p75 0,0075, INP p75 46 ms |
| D18 (web) | Đạt | [40641057955](https://github.com/anhnvcoder/short-video-platform/actions/runs/40641057955): bản tốt và build A promote, bản lỗi abort; 7 pod web thấy trong diễn tập, không pod nào restart |
| D23 | Đạt | [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867): số khoá `svp:gw:rl:register:*` sau `setup()` bằng số pod ở mức 1, 2, 4 (1, 2, 4) |
| D26 | Đạt (pha (2) trên `main`) | Pha (2) [40801610039](https://github.com/anhnvcoder/short-video-platform/actions/runs/40801610039): phát hành `user-service` (PR #29, merge 02:49:25Z) trong bước `Waiting for a release on main`: sync bắt đầu 02:51:25Z (+120 s), xong 02:51:41Z (+136 s), pod Ready 02:51:44Z (+139 s; phần lớn là chờ Argo CD poll git: `timeout.reconciliation` 60 s, tệ nhất ~120 s theo ADR-0014 §12); Job `user-service-migrate` tạo trong cửa sổ của đúng sync đó, xong, pod mới và Job `restartCount` 0, mỗi bên một dòng `database not reachable, retrying` rồi `database connected after retries`. Lượt đó `measure-gitops` ghi mốc push "not measurable" (không reflog, Events API chưa có PushEvent); từ nay mốc push lấy theo `merged_at` của PR có `merge_commit_sha` là commit (`ci_push_time` của `deploy/ci/platform.sh`), đọc lại cho commit `678717f` ra 02:49:25Z, các offset trên tính từ mốc đó. Cùng lượt `drill-k8s-keda` lần 1 FAIL ở điều kiện chuẩn bị (partition của pod mới hết video trước khi hai pod cùng transcode 60 s, không phải lỗi KEDA), lần 2 đạt. Pha (1) trên nhánh ghi bước `Waiting for a release on main` `skipped` theo thiết kế. Phép đo nay chỉ nhận Job migrate tạo trong cửa sổ của đúng sync đã đo; thiếu Job ở service có `migrate: true` là FAIL |

### Thí nghiệm `chaos` (D12)

Giả thuyết của [ADR-0020](0020-reliability-stage6.md) §7; mỗi thí nghiệm một lượt k6 1 pod (một nửa mức cao nhất đạt của
`k6-cloud-mini`), cửa sổ ổn định 5 phút riêng ngay trước khi gây lỗi. Số ở `k8s-drills/chaos-*.json` và `k6/` của artifact
`verify-chaos`.

| Thí nghiệm (lượt) | Giả thuyết | Số đo | Kết quả |
| --- | --- | --- | --- |
| Bản thử ([40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770), [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)) | Trễ 200 ms trên pod thử: mỗi kết nối chậm thêm ≥ 150 ms trong lúc trễ, ≤ 50 ms sau | +183 / +203 ms trong, −9 / 0 ms sau | Đạt |
| (a) gateway (cả hai lượt) | 10 phút quanh kill: feed 5xx < 0,1 %, p99 ≤ 150 ms (trừ 30 s đầu), pod thay Ready < 60 s, không page | 2 replica Ready lúc kill, pod thay Ready sau 1 s, feed 5xx 0, p99 9,4 → 9,6 ms ([40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)), 5xx của Envoy 0, page 0 | Đạt |
| (a) feed-service ([40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)) | Như gateway; chỉ 1 replica thì ghi thời gian feed mất pod | 1 replica, pod thay Ready sau 2 s, feed 5xx 0,28 % trong 10 phút (k6: explore, following lỗi 0,33 % cả lượt), p99 9,6 → 9,5 ms, page 0 | **Phát hiện** |
| (b) ([40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)) | engagement-service trễ 200 ± 20 ms trong 5 phút: feed vẫn 200, bỏ `stats` khi quá 100 ms, 5xx < 0,1 %, p99 ≤ 150 ms; like, view không 5xx; breaker không mở | Feed 5xx 0, p99 149,1 ms (sát ngưỡng), explore 200 với 20 mục, 0 mục có `stats`, `stats` trở lại ngay khi gỡ; breaker không mở, `CircuitBreakerOpen` không cháy; **556 / 2 149 request like + view trả 5xx** (k6: like lỗi 18,5 %, p99 3 004 ms; view 0 lỗi, p99 455 ms) | **Phát hiện** |
| (c) ([40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770)) | Redpanda tắt 5 phút: tạo, hoàn tất upload và feed vẫn chạy, view lỗi tính riêng; sau đó 3 video `READY` đúng một lần trong 15 phút, DLQ không tăng, lag mỗi group về mức ổn định | Upload init 5xx 0, feed 5xx 0, p99 9,7 ms, view 5xx khoảng 1 134 (tính riêng); broker về sau 7 s; 3 video `READY` ngay (0 s), mỗi video một lần transcode, một lần `READY`; lag ba group về 0 sau 1 s, engagement-service về mức batch 5 sau 39 s; DLQ không đổi sau 10 phút | Đạt |
| Bản thử ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085)) | Như trên | +199 ms trong, +1 ms sau (20 kết nối: 411 → 4 398 → 428 ms) | Đạt |
| (a) gateway ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085)) | Như trên | 2 replica Ready lúc kill, pod thay Ready sau 2 s, feed 5xx 0, p99 11,5 → 13,1 ms, 5xx của Envoy 0, page 0 | Đạt |
| (a) feed-service ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085)) | Như gateway (nay 2 replica, ADR-0031 §1) | 2 replica Ready lúc kill, pod thay Ready sau 3 s, feed 5xx 0 trong 10 phút, p99 13,3 → 13,1 ms, 5xx của Envoy 0, page 0 | Đạt |
| (b) ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085)) | Như trên (Like/Unlike một câu SQL, hạn ghi 1 s, ADR-0031 §2) | Feed 5xx 0, p99 149,2 ms, explore 200 với 20 mục, 0 mục có `stats`, `stats` trở lại sau 1 s; breaker tối đa 0, `CircuitBreakerOpen` không cháy; like + view 5xx **0** trên khoảng 2 255 request (k6 cả lượt: like lỗi 1 / 3 074, p99 618 ms; view 0 lỗi, p99 458 ms) | Đạt |
| (c) ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085)) | Như trên | Upload init 5xx 0, feed 5xx 0, p99 10,8 ms, view 5xx khoảng 1 120 (tính riêng); broker về sau 9 s; 3 video `READY` ngay (0 s), mỗi video một lần transcode, một lần `READY`; lag ba group về 0 ngay, engagement-service về mức batch 5 sau 40 s; DLQ không đổi sau 10 phút | Đạt |

- **(a) feed-service, nguyên nhân (đọc từ code):** `hpa.minReplicas: 1` ở `deploy/k8s/values/services/feed-service.yaml` (gateway có
  2). Gateway thử lại `GetExploreFeed`, `GetFollowingFeed` khi `UNAVAILABLE` tối đa 3 lần, tổng chờ không quá 0,15 s (cấu hình
  retry ở `services/gateway/cmd/gateway/main.go`), ngắn hơn 2 s tới khi pod mới Ready: request feed rơi vào khoảng đó trả 5xx. Đây
  là dữ liệu về số replica tối thiểu, không phải giả thuyết sai.
- **(b), nguyên nhân (đọc từ code):** NetworkChaos không `target` trễ mọi gói engagement-service gửi đi, cả tới Postgres. Like là
  một transaction (Begin, InsertLike, IncrementLikeCount khi like mới, Commit; `services/engagement-service/internal/server/server.go`):
  3–4 round trip Postgres nối tiếp, mỗi cái ≥ 200 ms, cộng trả lời gateway; gateway cắt mọi call ở 3 s
  (`services/gateway/internal/api/api.go`), `DEADLINE_EXCEEDED` thành 504: p99 like 3 004 ms đúng bằng hạn đó. `RecordView` không
  đụng Postgres (một lần produce) nên view không lỗi. Giả thuyết của manifest tính một lần trễ cho cả call: sai với Like. Phần từ
  1 s tới 3 s là suy luận chưa đo: pool pgx mặc định 4 kết nối (runner 4 CPU) dùng chung với `GetStats` hạn 100 ms; `GetStats` hết
  hạn trước khi Postgres trả lời và pgx đóng kết nối đó, nên pool liên tục mở kết nối mới (TCP, TLS, SCRAM) và Like chờ lấy kết nối;
  artifact chưa có metric `pgxpool.*` để kiểm.
- **Breaker không mở ở (b)** (đúng ý "chậm không phải chết"): `DEADLINE_EXCEEDED` của `GetStats` không tính; like hết hạn có tính,
  nhưng view thành công xen giữa (k6 gửi 6 147 view, 2 992 like), 5xx chỉ 26 % số like + view ở gateway, không có chuỗi 5 lỗi liền.
  Đổi lại mỗi like lỗi chờ đủ 3 s thay vì lỗi ngay.
- **Runner:** container `tempo` của `svp-obs/tempo-0` (limit 768 Mi) là pod OOMKilled duy nhất ở cả hai lượt, bắt đầu trong lượt k6
  của (a); `MemAvailable` thấp nhất 6,4 / 8,3 GiB nên là limit của container, không phải hết RAM máy. Vì `no_oom=false`, bước (a),
  (b), (c) ghi `fail` dù thí nghiệm đạt hay là phát hiện (cùng lỗi tiêu chí với `k6-cloud-mini` mức 4, Hệ quả "Xem lại khi").
- **Thời lượng** ([40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770)): `k8s-up` 19,5 phút, cài 3 phút, bản thử 11,5, (a) 28,3, (b) 22,3, (c) 39,5, gỡ 1,1 phút; cả
  kịch bản 2 giờ 06 phút, trong hạn 330 phút của job `k3d`.
- **Quyền của Chaos Mesh trên runner** (OPS-4): không thêm quyền, không ngoại lệ RBAC mới; tắt controller multi-cluster chỉ bỏ
  watch, không bỏ quyền nào của chart.
- **Lượt 2026-10-29** ([40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085), sau [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md)): mọi bước `ok`; runner
  đủ mọi tiêu chí (`no_oom=true`, không container `OOMKilled`, `MemAvailable` thấp nhất 8 209 MiB, CPU cao nhất 99 %); Tempo
  `restartCount` 0 suốt kịch bản, working set đỉnh 754 MiB (limit 1 Gi), step `tempo-ingest-chaos-a`, `-b`, `-c` đạt (0 span bị
  từ chối hay bỏ, 695–723 span/s). Controller Chaos Mesh giữ cùng pod, 0 restart, 0 dòng `is forbidden`; gỡ sạch. Threshold k6 của
  lượt (b) (`dropped_iterations` 4) và (c) (`dropped_iterations` 353, `checks`, lỗi view khi Redpanda tắt) trượt: dữ liệu của tải trong
  thí nghiệm, không phải kết quả thí nghiệm. Thời lượng: `k8s-up` 18,3 phút, cài 3,0, bản thử 11,3, (a) 28,3, (b) 22,4, (c) 39,4, gỡ
  1,2 phút; cả kịch bản khoảng 2 giờ 4 phút.

D8, D10, D15, D16, D19–D22 đã có kết quả ở phần 1, 2; D24 là GĐ7; D25 ở mục 12 và [threat model](../threat-model.md) (OPS-4,
BAK-2); D27 không cần runner.

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

### Phần 4: tách `svp-gitops`

Chuẩn bị (PR-A: provenance, media có version, External Secrets; ADR 0026, 0027, 0029) rồi cắt (PR-B, nhánh `feat/stage6b-gitops-split`,
PR #39: Argo CD và đường dev đọc `svp-gitops`, [ADR-0025](0025-gitops-config-repo.md)). Kết quả của từng giả định ở mục Kiểm chứng
sau của 0024–0029; ở đây là các lượt và số của runner.

| Kịch bản | Lượt (ngày, commit, link) | Kết quả chính |
| --- | --- | --- |
| `gitops` | PR-A 1: 2026-10-29, `3689648`, [40857855305](https://github.com/anhnvcoder/short-video-platform/actions/runs/40857855305) | Mọi bước; `k8s-gitops-up` 687 s, 26 Application Synced/Healthy (có `external-secrets`), 28 ExternalSecret Ready; `k8s-smoke` xanh với dòng `NOTE` của layout media cũ (bản phát hành của `main` khi đó); supplychain a–i PASS, (l) `SKIP policy off`; e2e 66/66; threats 17/18 (SEC-5/6/7 đỏ ở ca đối chứng, đã sửa); `drill-k8s-keda` lần 1 FAIL ở bước chuẩn bị (hai worker cùng transcode dài nhất 55 s, cần 60 s; không phải lỗi KEDA), lần 2 xanh |
| `gitops` | PR-A 2: 2026-10-29, `bfbf29a`, [40873382301](https://github.com/anhnvcoder/short-video-platform/actions/runs/40873382301) (chỉ `drill-k8s-threats`) | SEC-5/6/7, `SEC-6-reader` PASS; IN-2/IN-4, FF-5 đỏ vì explore rỗng (lượt bỏ `k8s-smoke`), PASS ở lượt trên |
| `gitops` | PR-A, lượt dừng ở dựng: [40868396800](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868396800) | `kube-prometheus-stack` Progressing tới hết 1 800 s; cùng triệu chứng với lượt PR-B 1 dưới đây (lỗi lúc đó coi là của môi trường) |
| `dev-k3d` | PR-A: 2026-10-29, `3689648`, [40857870284](https://github.com/anhnvcoder/short-video-platform/actions/runs/40857870284) | `k8s-up` 1 072 s, không `external-secrets`/`svp-secrets`; `k8s-smoke` 13 s, key có version và `Cache-Control … immutable`, không `NOTE`; k3d tối đa 5 724 MiB |
| `compose-obs` | PR-A: 2026-10-29, `bfbf29a` [40868380823](https://github.com/anhnvcoder/short-video-platform/actions/runs/40868380823); `a3549f3` [40873923182](https://github.com/anhnvcoder/short-video-platform/actions/runs/40873923182) (chỉ bước chọn) | Smoke key có version, không `NOTE`; `drill-kill-worker` ok; `test-stack-objstore` 70 passed, 0 skipped; `drill-duplicates` ok (10 object, cùng ETag, không transcode) |
| `gitops` | PR-B 1: 2026-10-29, [40938235138](https://github.com/anhnvcoder/short-video-platform/actions/runs/40938235138) | Dừng ở dựng: `kube-prometheus-stack` Progressing, không pod hay StatefulSet Prometheus nào. Nguyên nhân: Prometheus Operator chỉ dò CRD một lần lúc khởi động, operator lên trước CRD `prometheuses.monitoring.coreos.com` thì không dựng controller Prometheus. Sửa trong `svp-gitops` (PR #2, `cf28b34`): sync wave cho chart con, CRD wave 0, operator 1, CR Prometheus và Alertmanager 2. `k8s-gitops-up` từ nay hết hạn chờ thì in trạng thái từng Application, tài nguyên chưa Healthy (đọc thẳng từ cluster: Argo CD 3.x không ghi health của tài nguyên vào Application) và sự kiện |
| `gitops` | PR-B 2: 2026-10-29, [40944295274](https://github.com/anhnvcoder/short-video-platform/actions/runs/40944295274) | Dựng qua; `release-set-before` đỏ 1 s sau khi mọi Application Healthy: HPA `feed-service` chưa có số của metrics-server làm Application Degraded thoáng qua; mọi bước sau đạt. Sửa: `release-set.sh snapshot --settle` chờ tới ~300 s cho tới khi mọi Application Synced, Healthy, không sync đang chạy qua hai lần đọc liền rồi mới chụp; hết hạn vẫn ghi bản chụp nhưng bước đỏ (hạn bước 2 → 8 phút) |
| `dev-k3d` | PR-B: 2026-10-29, `f4b3e79`, [40937054425](https://github.com/anhnvcoder/short-video-platform/actions/runs/40937054425) (`k8s-smoke`, `drill-k8s-threats`; bản clone `svp-gitops` `a84e26d`) | `k8s-up` 1 054 s, `k8s-smoke` 12 s (key có version, `Cache-Control … immutable`), threats 15/15; k3d tối đa 7 268 MiB, `MemAvailable` thấp nhất 9 674 MiB. `f4b3e79` → `027f8bd` không đổi đường dev |
| `gitops` | PR-B 3: 2026-10-29, `027f8bd` (`svp-gitops` `cf28b34`), [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229) | 17/17 target ok. Root theo `refs/heads/main` của `svp-gitops` qua HTTPS ẩn danh, chart ở `c59c7426663d`; 26/26 Application Synced/Healthy/Succeeded (610 s); overlay stg trên pod gateway; 28/28 ExternalSecret; `k8s-smoke` không `NOTE` (biến chuyển tiếp đã bỏ); policy Deny có kiểm provenance, ca (a) PASS hai lần, (l) PASS đúng message, b–i PASS, (k) SKIP; threats 16/16; e2e, `drill-k8s-web-obs` PASS; `release-set` trước và sau bằng nhau; bước chờ phát hành `skipped` (nhánh) |

RAM của đường GitOps (D1, D2; cách đo và ngưỡng của mục 2: (b) 6,5 GiB = 6 656 MiB trừ `active_file`, pod 4,7 GiB; đỉnh (a)
8,7 GiB = 8 909 MiB), ghi trung thực, **chưa kết luận đạt**:

- [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229): điểm 60 s MEM USAGE trung vị 8 967 MiB, trừ `active_file` 6 558 MiB, pod 3 787 MiB: (b) đạt ở điểm này. Cuối kịch
  bản 7 657 / **7 241** / 4 517 MiB: (b) **không đạt** (trên 6 656). Đỉnh: `ram-peak-2` trung vị **8 954 MiB**, trên 8,7 GiB (không đạt);
  `ram-peak-1` không có cửa sổ 6 mẫu liền hai worker cùng transcode (`null`; `drill-k8s-keda` lần 1 dài nhất 5 mẫu, lần 2 9 mẫu), nên
  `gitops_keda_two_transcoding=false` trong `runner.txt`.
- [40857855305](https://github.com/anhnvcoder/short-video-platform/actions/runs/40857855305) (PR-A, trước khi tách): điểm 60 s 8 987 / 6 731 / 4 020 MiB (`external-secrets` 46 MiB); cuối 7 110,5 MiB; hai
  `ram-peak` cũng không có cửa sổ hai worker, mẫu cao nhất 8 762 / 8 660 MiB. So với lượt 2026-10-28 (D2): 8 937 / 7 510 / 4 073 MiB ở
  60 s, 9 863 MiB cuối.

Còn mở, kiểm sau merge PR-B: lượt `gitops` trên `main` với job `record-stg` (bản ghi stg `success`, payload bằng digest trên pod), bước
chờ phát hành trên `main` của `svp-gitops` và `measure-gitops` đo commit của repo đó, event GlitchTip mang environment `stg`; lượt lịch
tuần đầu có job `gitops` (bản ghi stg không cần bước chờ, mục 3).

## Hệ quả

- **Được:**
  - Mọi việc dời vì máy 16 GB chạy được mà không cần dịch vụ cloud, không tốn tiền, trên môi trường sạch, lặp lại được bằng một
    lệnh dispatch; giai đoạn 7 chỉ còn việc của cloud.
  - Mỗi lượt có tiêu chí "runner đủ" đo được, nên lượt đỏ tách được lỗi code với giới hạn của runner, và B chỉ mở khi có số.
  - Không secret nào trong job dựng hay kiểm, kể cả đường GitOps; deploy key của Argo CD bỏ luôn ở máy (từ phần 4 job `record-stg`
    cầm khoá App qua environment `promote`, không chạy kịch bản nào).
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
  - Lượt lịch hằng tuần (từ 2026-10-25; từ 2026-10-30 ba kịch bản, thêm `gitops`) chạy trên `main` dù không ai đọc: log và artifact
    công khai thêm mỗi tuần, qua cùng bộ lọc.
  - Tuần không có bản ghi stg khi `release-set` đỏ vì `main` của `svp-gitops` đổi giữa lượt (một PR promote stg của bot merge đúng lúc
    đó), hay khi artifact `web-sourcemaps-amd64` của bản web đang chạy đã hết hạn giữ của `images.yml` (bước `gitops-sourcemaps` đỏ
    trên `main`): đúng thiết kế, tuần đó DORA không có deployment.
- **Xem lại khi:**
  - Một dòng trượt tiêu chí runner hai lượt liền: chạy dòng đó trên B, ghi chi phí.
  - Repo thành private, hay GitHub giới hạn git ẩn danh: Argo CD quay lại deploy key (secret của environment được bảo vệ).
  - Pull từ node k3d trên runner gặp 429 (miễn trừ của GitHub không áp cho ca đó): xét đăng nhập Docker Hub bằng token chỉ đọc, khi
    đó mới có secret, ghi vào ADR này trước.
  - `ubuntu-24.04` bị GitHub bỏ hay đổi cấu hình runner chuẩn: đo lại cổng đĩa và tiêu chí RAM.
  - Lượt lịch đỏ: đọc và sửa như lượt dispatch; GitHub tắt lịch sau 60 ngày repo không hoạt động: bật lại ở tab Actions.
  - Bộ lọc artifact bỏ oan nhiều file hợp lệ: thu hẹp mẫu theo loại file, không bỏ quét theo giá trị.
  - Tiêu chí "runner đủ" của kịch bản k6 (phát hiện ở phần 3): `no_oom` coi container chết ở limit riêng (Tempo ở mức 4 của
    [40620333867](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620333867)) như máy thiếu RAM, còn throttle CFS của k6 không thấy CPU máy bão hoà (mức 8 của [40344818171](https://github.com/anhnvcoder/short-video-platform/actions/runs/40344818171) ghi `fail:
    system` lúc CPU máy 99 %): tách OOM của máy hay node khỏi pod chết ở limit riêng và thêm CPU máy trong cửa sổ giữ vào tiêu chí
    trước lượt k6 kế (giai đoạn 7 dùng cùng script). Lượt 2026-10-29 ([40820505634](https://github.com/anhnvcoder/short-video-platform/actions/runs/40820505634)) lặp lại phần CPU: mức 4 CPU máy trung bình
    89 %, cao nhất 100 %, mà `runner_enough` vẫn `true` (tiêu chí chưa xét CPU máy) nên mức chạm trần CPU của runner ghi `fail:
    system`; phần OOM không còn xảy ra từ khi Tempo có trần ([ADR-0031](0031-chaos-findings-feed-engagement-tempo.md)).
  - Tempo dưới tải: sampling 100 % (mặc định SDK) với metrics-generator trong một tiến trình limit 768 Mi chết ở khoảng 220 req/s,
    và cả dưới k6 1 pod, từ lượt k6 của thí nghiệm (a) (lượt `chaos` [40691107770](https://github.com/anhnvcoder/short-video-platform/actions/runs/40691107770), [40712072895](https://github.com/anhnvcoder/short-video-platform/actions/runs/40712072895)).
    Trước buổi đo cloud: chốt chính sách sampling của lượt tải bằng ADR (diễn tập giai đoạn 3 cần tìm trace của đúng một request),
    cỡ Tempo theo tốc độ span mục tiêu, sampler lấy thêm namespace `svp-obs`. Đã làm ở [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md)
    §3 (không sampling ở giai đoạn này, Tempo tự giới hạn bộ nhớ, `svp-obs` vào `pods.tsv`, step `tempo-ingest-*`): lượt 2026-10-29
    không OOM, 0 span bị từ chối hay bỏ tới mức 4 pod (3 036 span/s), working set đỉnh 784 MiB dưới limit 1 Gi, sát `GOMEMLIMIT`
    800 MiB. Sampling và cỡ Tempo cho 1 000 req/s vẫn quyết ở giai đoạn 7.
  - Hai phát hiện của Chaos Mesh (D12, mục "Thí nghiệm `chaos`"): mất pod feed-service duy nhất làm feed 5xx 0,28 % trong 10
    phút: nâng `hpa.minReplicas` của feed-service lên 2 kèm PDB như gateway; trễ 200 ms ở engagement-service làm 18,5 % like hết
    hạn 3 s: engagement chịu trễ database (pool kết nối riêng hay lớn hơn, huỷ `GetStats` mà không đóng kết nối, timeout và breaker
    theo số round trip), đo `pgxpool.*` trước khi sửa, sửa cùng lúc giả thuyết trong manifest (b). Cả hai làm trước buổi chaos
    của giai đoạn 7, rồi chạy lại `chaos` trên runner. Đã làm ở [ADR-0031](0031-chaos-findings-feed-engagement-tempo.md) §1, §2
    (`pgxpool.*` chưa đo trước khi sửa, kết quả không cần nó): `chaos` [40810755085](https://github.com/anhnvcoder/short-video-platform/actions/runs/40810755085) (a) feed-service feed 5xx 0, (b) like + view
    5xx 0. Còn lại: CPU hai pod feed lệch khoảng 2:1 dưới tải (`k6-cloud-mini` [40820505634](https://github.com/anhnvcoder/short-video-platform/actions/runs/40820505634)), rủi ro ghim kết nối qua
    ClusterIP mà ADR-0031 §1 đã nêu.
  - Tỷ lệ Server Action 409 trong canary web 22,6 % (> 10 %, D6): ADR riêng xét khoá Server Action cố định không bí mật
    ([ADR-0019](0019-web-k3d-supply-chain-observability.md) §1).
- **ADR cũ được chỉnh** (đã ghi "chỉnh bởi 0021" ở trạng thái của chúng và ở `docs/adr/README.md` ngày 2026-10-28):
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

Phần 2 (bước object store của `compose-obs`, đếm restart theo container): `deploy/ci/verify-run.sh` (`test-stack-objstore`,
`drill-upload-cleanup`, `measure-upload`, `ram-s3-upload`, `object-store-roundtrip`), `deploy/ci/verify-sample.sh` (`compose.tsv`,
`restarts.tsv`, `s3-peak`, `sample`), `deploy/ci/verify-collect-test.sh`, chú thích của `.github/workflows/verify.yml`; phần của
store ở mục Hiện thực ở của [ADR-0022](0022-local-object-store-minio-replacement.md).

Phần 3:

- Trình tự mỗi kịch bản một file (Tên chốt): `deploy/ci/verify/compose-obs.sh`, `dev-k3d.sh`, `gitops.sh`, `web-canary.sh`,
  `k6-cloud-mini.sh`, `chaos.sh`, `velero.sh`, nạp từ `deploy/ci/verify-run.sh`; năm giá trị `scenario` mới và job `gitops` của
  `.github/workflows/verify.yml`; tiêu chí runner mới (`gitops_keda_two_transcoding`, `k6_cpu_throttle_5pct`, `k6-windows.tsv`) ở
  `deploy/ci/verify-sample.sh`; `sch_netem` ở `deploy/ci/verify-host.sh`; namespace `chaos-mesh`, `svp-load` ở
  `deploy/ci/verify-mask.sh`; `.k6/cloud-*/pod-*.json` ở `deploy/ci/verify-collect.sh`; test ở `deploy/ci/verify-collect-test.sh`.
- Hàm adapter `ci_hosted_runner`, `ci_artifact_runs`, `ci_artifact_fetch` (§6, §7): `deploy/ci/platform.sh`, test ở
  `deploy/ci/platform-test.sh`, bảng hàm của [ADR-0023](0023-ci-platform-neutral.md).
- Đường GitOps (§6): HTTPS ẩn danh ở `deploy/argocd/apps/values.yaml`, `deploy/argocd/project.yaml`, `deploy/k8s/gitops.sh`
  (không Secret repo, không `ARGOCD_DEPLOY_KEY`), `deploy/k8s/k8s.mk`; plugin Argo Rollouts theo kiến trúc node
  (`deploy/k8s/values/argo-rollouts-amd64.yaml`, `archValues`/`nodeArch` của chart `deploy/argocd/apps`, `deploy/k8s/install.sh`);
  overlay môi trường của [ADR-0024](0024-multi-environment.md); source map của image CI: bước xuất và kiểm debug ID của
  `deploy/ci/build-image.sh` (`--sourcemaps-artifact`), job `build` của `.github/workflows/images.yml`,
  `deploy/ci/gitops-sourcemaps.sh` (test `deploy/ci/gitops-sourcemaps-test.sh`),
  `deploy/observability/glitchtip/sourcemaps.sh` (thư mục có sẵn, `SOURCEMAPS_DIR`), `SVP_WEB_OBS_SKIP_ERRORS` của
  `deploy/k8s/drills/web-obs.sh`, `SUPPLYCHAIN_UNSIGNED_FALLBACK` của `deploy/k8s/drills/supplychain.sh`; đo phát hành gắn đúng
  revision và Job migrate ở `deploy/k8s/drills/gitops.sh` (`make measure-gitops`).
- KEDA dàn đều partition (D1): `deploy/k8s/drills/keda.sh`, `create`/`upload` của `deploy/k8s/drills/lib.sh`.
- Canary web (D6, D14, D18): `deploy/k8s/drills/web-canary.sh`, target `drill-k8s-web-canary` của `deploy/k8s/k8s.mk`,
  `web/e2e/canary/clients.ts`, tham số build id của `build_image` (`deploy/k8s/lib.sh`); `canaryLimits.p99Ms: 250` ở
  `deploy/k8s/values/services/web.yaml`.
- k6 thu nhỏ (§8): `--pods`, `--ramp`, `--hold` của `deploy/k6/cloud/render.sh` và `run.sh` (chế độ runner),
  `deploy/k6/cloud/job.yaml.in`.
- Velero và CSI (§7): `deploy/k8s/cloud/runner/csi/`, `deploy/k8s/cloud/runner/velero/`, nhánh `SVP_K8S_RUNNER_CSI` của
  `deploy/k8s/install.sh`, chế độ runner của `deploy/k8s/cloud/velero/drill-restore.sh`, `runnerValues` của
  `deploy/k8s/cloud/charts.json`, kiểm ở `deploy/k8s/cloud/check.sh`; mục bỏ qua có hạn của driver CSI ở
  `deploy/ci/trivy-config-ignore.yaml`.
- Chaos Mesh (§7): `deploy/k8s/cloud/runner/chaos-mesh/`, thí nghiệm ở `deploy/k8s/cloud/chaos/` (gồm bản thử
  `b-trial-network-delay-probe.yaml`), `deploy/ci/verify/chaos.sh`; danh sách controller không multi-cluster ở
  `deploy/k8s/cloud/values/chaos-mesh.yaml` (chung cloud và runner), kiểm cả hai bản render ở `deploy/k8s/cloud/check.sh`.
- Web (D17): font nạp sau `load` ở `web/app/styles/web-fonts.tsx`, `fonts.ts`, `globals.css`; `messages.precompile` ở `web/next.config.ts`.

Phần 4 (tách `svp-gitops`; danh sách đầy đủ ở mục Hiện thực ở của [ADR-0025](0025-gitops-config-repo.md)):

- Các file `deploy/argocd/…`, `deploy/k8s/values/…` nêu ở phần 3 nằm ở repo `svp-gitops` (`argocd/`, `base/`); `canaryLimits.p99Ms`
  của web ở `base/services/web.yaml` của repo đó.
- Kịch bản `gitops`: `deploy/ci/verify/gitops.sh` (Argo CD theo `main` của `svp-gitops`, bỏ `SVP_SMOKE_LEGACY_MEDIA`, bước
  `release-set-before`, `release-set`), `deploy/ci/verify-run.sh` (`make gitops-clone` trước kịch bản k3d), `release-set.json` ở
  `deploy/ci/verify-collect.sh` (test ở `deploy/ci/verify-collect-test.sh`); `deploy/ci/release-set.sh` (`snapshot --settle`); chẩn đoán
  khi dựng quá hạn: `gitops_timeout_report` của `deploy/k8s/lib.sh`, gọi từ `deploy/k8s/gitops.sh`.
- Job `record-stg` của `.github/workflows/verify.yml`, `deploy/ci/record-stg.sh`; điều kiện ghi (output `recorded` của job `gitops`),
  job `gitops` trong lịch tuần và `SVP_VERIFY_SCHEDULED` (`release_wait`, `gitops_stale`, phép kiểm `targets` trước `release-set` của
  `deploy/ci/verify/gitops.sh`; test ở `deploy/ci/verify-collect-test.sh`) từ 2026-10-30.
- Sync wave của `kube-prometheus-stack`: `base/kube-prometheus-stack.yaml` của repo `svp-gitops`.
