# 0035. Renovate tự merge bản patch và digest của Go module, gói npm, base image và image dịch vụ khi `ci-ok`, `images-ok` xanh, ở repo backend và `svp-web`; action, công cụ ghim, commit backend, hợp đồng API, minor, major giữ duyệt tay

- Trạng thái: Chấp nhận (người học chốt 2026-10-31)
- Ngày: 2026-10-31

## Bối cảnh

[ADR-0015](0015-cicd-devsecops-stage5.md) §10 chọn "không automerge ở giai đoạn 5": mọi PR của Renovate có người đọc và merge tay;
[ADR-0033](0033-svp-web-repo.md) §10 giữ đúng điều đó cho `renovate.json` của `svp-web`.
Từ khi tách `svp-web` ([ADR-0033](0033-svp-web-repo.md)) có hai repo cùng lịch sáng thứ Bảy; ngày 2026-10-31 người học phải duyệt
tay 16 PR Renovate một lần, phần lớn là bản vá hay digest mà việc đọc PR không thêm gì so với CI. Ruleset `main` của cả hai repo đã
bắt PR và hai check `ci-ok`, `images-ok` (không duyệt bắt buộc, `strict_required_status_checks_policy: false`), nên một PR xanh merge
được mà không cần ai.

Cái người đọc PR còn chặn được là thay đổi có quyền: action chạy trong job có `id-token: write`, `packages: write` hay environment
`promote` (identity ký mà Kyverno tin), công cụ ký, đẩy, quét bản phát hành (`COSIGN_IMAGE`, `ORAS_IMAGE`, `TRIVY_IMAGE`, `SYFT_IMAGE`,
`GRYPE_IMAGE`…), commit backend mà `svp-web` chạy script CI từ đó (`.backend-commit`), và bản hợp đồng API (`api/contract.json`).
`minimumReleaseAge` 3 ngày vẫn giữ: bản bị chiếm thường bị gỡ trong vài giờ.

## Các lựa chọn

### A. Giữ không automerge

- Được: mọi thay đổi có người đọc.
- Mất: mỗi tuần hàng chục PR đọc tay mà không ai đọc kỹ thật; bản vá vào chậm.

### B. Tự merge mọi update không phải major

- Được: ít PR nhất.
- Mất: minor của action hay công cụ ký vào `main` không ai đọc; minor đổi hành vi (cấu hình, mặc định) chỉ CI chặn.

### C. Tự merge chỉ `patch` và `digest`, theo danh sách cho phép manager và file (chọn)

- Được: phần lớn PR hằng tuần (bản vá Go module, gói npm, digest image dựng lại) tự đi; thứ chưa xác định mặc định vẫn tay.
- Mất: phải giữ danh sách; nhóm lẫn update tự merge và update tay thì cả nhóm chờ tay.

### D. `automergeType: branch` (Renovate đẩy thẳng lên `main` khi nhánh xanh)

- Được: không PR, không thông báo.
- Mất: ruleset `main` bắt PR nên không đẩy thẳng được; mất dấu vết PR.

## Quyết định

Chọn **C**, cấu hình đơn giản nhất của Renovate (bản đang chạy: image ghim `RENOVATE_IMAGE` 44.165.1, App Mend theo bản mới):

- Gốc giữ `automerge: false`; thêm `automergeType: "pr"`, `automergeStrategy: "squash"`, `platformAutomerge: true` (`automergeType`,
  `platformAutomerge` là mặc định của Renovate, ghi ra cho rõ; `automergeStrategy` mặc định `auto`). Renovate bật auto-merge của GitHub trên PR lúc tạo (GraphQL `enablePullRequestAutoMerge`,
  `tryPrAutomerge` trong `modules/platform/github/index.js`, chỉ khi repo bật "Allow auto-merge"), GitHub merge khi `ci-ok`, `images-ok`
  xanh. Squash giữ commit trên `main` là tiêu đề PR `chore(deps): …` / `fix(deps): …` (conventional commit), kèm `(#<số>)`.
- `packageRules` đặt `automerge: true` cho `matchUpdateTypes: ["patch", "digest"]` của:
  - backend: manager `gomod` (`go.mod`, cả directive `go`), `dockerfile` (`deploy/docker/*.Dockerfile`), `docker-compose` và regex của
    `deploy/compose/compose.yaml` (anchor image), `deploy/compose/compose.mk` (`LGTM_IMAGE`), `helm-values` của
    `deploy/helm/*/values.yaml` (Valkey, RustFS, Redpanda, Postgres của CloudNativePG, GlitchTip), service container của workflow
    (Postgres, Redis của `ci.yml`, `verify.yml`), `go-version` của `actions/setup-go` (chỉ patch; cùng nhánh với directive `go` và image
    `golang`);
  - `svp-web`: manager `npm` (`package.json`, cả `pnpm` của `packageManager` và `engines`), `nvm` (`.nvmrc`), `dockerfile`
    (`Dockerfile`: `node`, distroless Node), service container của `ci.yml`.
- **Giữ duyệt tay**, mỗi nhóm một `packageRule` có `automerge: false` tường minh: nhóm `github actions` (cả hai repo), nhóm `tools`
  (`Makefile`, `deploy/k8s/lib.sh`: mọi công cụ và image công cụ ghim, cả `K3S_IMAGE_TAG`, `HELM_VERSION`) và nhóm `cosign` của backend;
  nhóm `backend commit` (`git-refs`) và `api contract` của `svp-web`. Mọi `minor`, `major`, `pin`, `pinDigest`, chart của cluster cloud
  (`deploy/k8s/cloud/`), image node k3s (`deploy/k8s/k3d.yaml`) không có rule nào bật nên giữ `automerge: false` của gốc; image
  helper của k3d (`k3d-proxy`, `k3d-tools`, `registry`) ghim ở `deploy/k8s/lib.sh` nên thuộc nhóm `tools`.
- **Nhóm lẫn loại:** Renovate chỉ tự merge một nhánh khi mọi upgrade trong nhánh có `automerge`
  (`config.automerge = config.upgrades.every((upgrade) => upgrade.automerge)`, `workers/repository/updates/generate.js` của 44.165.1).
  Nên nhóm `go modules` (minor, patch, digest), `npm packages` (minor, patch), `node`, `sentry`, `go toolchain and base images`, `image
  digests` chỉ tự merge khi cả nhóm là patch hay digest của danh sách cho phép; có một minor hay một update tay là cả nhánh chờ người.
  Nhóm `k3s` (node image cùng `K3S_IMAGE_TAG` của `Makefile`), `opentelemetry-collector chart` (cùng `OTELCOL_IMAGE`) luôn tay.
- **Lịch:** `schedule` (sáng thứ Bảy) chỉ giới hạn lúc Renovate tạo nhánh; `automergeSchedule` để mặc định `["at any time"]`. PR
  `vulnerabilityAlerts` mở ngay ngoài lịch, không chờ `minimumReleaseAge` (mặc định của Renovate: `schedule: []`,
  `minimumReleaseAge: null`, `groupName: null`), nên PR bản vá lỗ hổng kiểu patch của danh sách cho phép **tự merge ngay khi check xanh**;
  bản sửa lỗ hổng phải nâng minor hay major thì vẫn tay.
- **Phát hành:** ở backend, một lần tự merge vào `main` chạy `images.yml` như merge tay: service đổi được build, quét, ký, và PR promote
  `bot/promote-stg` của `svp-gitops` tự merge khi `gitops-ok` xanh, nên bản vá vào stg không ai bấm; chart của `deploy/helm/` đổi
  (image bên thứ ba) thì `charts.yaml` của stg đi theo. Ở `svp-web`, image web mới vào stg qua `bot/promote-stg-web` như vậy. Prd vẫn
  chỉ đổi qua PR promote prd có người duyệt.

Nguồn: tài liệu cấu hình Renovate (`https://docs.renovatebot.com/configuration-options/`: `automerge`, `automergeType`,
`automergeStrategy`, `platformAutomerge`, `automergeSchedule`, `vulnerabilityAlerts`, `minimumReleaseAge`) và mã của đúng bản ghim
trong image `RENOVATE_IMAGE` (`/usr/local/renovate/dist/`: `workers/repository/updates/generate.js`, `workers/repository/update/pr/index.js`
`getPlatformPrOptions`, `workers/repository/update/pr/automerge.js`, `config/options/index.js`, `modules/manager/github-actions/dep-types.js`).

## Hệ quả

- Được: PR Renovate đọc tay mỗi tuần chỉ còn minor, major, action, công cụ, commit backend, hợp đồng; bản vá vào stg trong ngày CI xanh.
- Phải trả:
  - Hai check bắt buộc là lớp chặn duy nhất của bản tự merge. Job `stack` (compose, e2e, k6) ở ngoài `ci-ok`, nên patch của image
    compose (RustFS, Redpanda, GlitchTip…) hỏng lúc chạy mà `compose-config` không thấy chỉ lộ ở lượt `verify.yml` hằng tuần hay lần
    `make up` sau; hoàn tác bằng PR revert.
  - `minimumReleaseAge` 3 ngày là lớp giảm nhẹ duy nhất trước bản bị chiếm; PR lỗ hổng bỏ qua nó. Renovate không tạo nhánh trước
    hạn đó (`internalChecksFilter` mặc định `strict`, cả với update `digest`), nên auto-merge của GitHub không merge sớm được. Tuổi
    đó là giờ của registry với gói npm và image Docker Hub (`tag_last_pushed`); với Go module là giờ commit do người phát hành tự đặt
    (`Time` trong `.info` của goproxy, ngày của tag GitHub; ngày của GitHub Release, do GitHub ghi, chỉ thay khi muộn hơn;
    `modules/datasource/go/releases-goproxy.js`), nên tag Go bị chiếm trỏ commit lùi ngày qua hạn ngay và chỉ còn CI chặn.
  - Bản vá bị chiếm mà qua 3 ngày và CI (trivy, grype chỉ bắt lỗ hổng đã công bố) được ký bằng identity Kyverno tin và tự vào stg
    không ai đọc: SC-8 của [threat model](../threat-model.md) lên ưu tiên Cao, rủi ro chấp nhận ghi ở mục 6 của nó.
  - Repo phải bật "Allow auto-merge" và cho merge squash; repo backend đang tắt auto-merge, người học bật trước khi cấu hình này vào
    `main` (thiếu thì Renovate bỏ qua bước bật auto-merge của GitHub).
- Xem lại khi: một bản tự merge làm đỏ `main` hay hỏng stg (thu danh sách lại), hay job `stack` vào `ci-ok` (khi đó image compose có
  lớp chặn chạy thật).

## Hiện thực ở

- `renovate.json`: khoá automerge ở gốc, bốn `packageRule` tự merge, `automerge: false` của nhóm `github actions`, `tools`, `cosign`.
- `renovate.json` của `svp-frontend`: khoá automerge ở gốc, hai `packageRule` tự merge, `automerge: false` của nhóm `github actions`,
  `backend commit`, `api contract`.
