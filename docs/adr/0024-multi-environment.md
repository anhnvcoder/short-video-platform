# 0024. Nhiều môi trường dev, stg, prd: build một lần, mọi env chạy cùng digest đã ký, khác biệt chỉ ở overlay values `deploy/k8s/envs/<env>/` mà Argo CD chọn theo giá trị `env` của root Application; ở giai đoạn 6b cluster GitOps trên k3d đóng vai stg, prd chỉ render và kiểm tĩnh

- Trạng thái: Chấp nhận (người học duyệt 2026-10-26, chọn (a) ở cả bảy dòng "Cần người học chọn"). Phần 3 của giai đoạn 6b
  hiện thực 2026-10-26; "k3d đóng vai stg" chạy trên runner 2026-10-28 (kịch bản `gitops`, mục Kiểm chứng sau); phần 4 và giai
  đoạn 7 chưa hiện thực; §9 (Secret mỗi env: ExternalSecret của từng namespace qua store riêng, ở prd mỗi store assume một role chỉ
  đọc entry namespace đó cần) chỉnh bởi [0026](0026-secrets-gitops.md)
- Ngày: 2026-10-26

## Bối cảnh

- **Yêu cầu** (lộ trình của lab, mục "Bài SA bổ sung", dòng "Nhiều môi trường dev / stg / prd", người học hỏi 2026-10-25): build
  một lần, promote cùng digest; cấu hình chia gốc + `envs/{dev,stg,prd}`; stg tự đồng bộ sau merge, prd qua PR có người duyệt; khác
  biệt giữa env chỉ ở config (replica, resources, tên miền, cỡ database, secret); Terraform cùng module, mỗi env một state; dữ liệu
  prd không chép sang stg; chạy thử trên runner với k3d đóng vai stg. Giai đoạn 7 dựng stg nhỏ và prd trong cùng buổi trên **hai
  cluster EKS riêng** (người học chốt 2026-10-25). Phần 3 của giai đoạn 6b viết thiết kế này và cấu trúc overlay; phần 4 tách repo
  cấu hình `svp-gitops` (public, PR promote mở bằng GitHub App, chốt 2026-10-25).
- **Hiện trạng** (`main` ở `744f108`):
  - Một cluster k3d `svp` mỗi lúc, hai đường cài không chạy chung trên một cluster ([ADR-0014](0014-kubernetes-local-stage4.md)
    §12). Đường dev `make k8s-up`: helm từ working tree theo `deploy/argocd/apps/components.json`, image `dev-*` chưa ký của
    registry k3d (`install.sh` truyền `--set image.repository`, `image.tag`, `image.digest=`), Kyverno Audit (`--set
    imageVerification.mode=Audit`). Đường GitOps `make k8s-gitops-up`: Argo CD dựng từ GitHub ở `GITOPS_REV`, image GHCR theo
    digest đã ký, Kyverno Enforce (mặc định của chart `svp-policy`). Compose vẫn là đường dev chính (ADR-0014 §14).
  - Values: `deploy/k8s/values/<component>.yaml` cho chart upstream, `deploy/k8s/values/services/<svc>.yaml` cho bảy release của
    chart `svp-service`; bốn chart của repo (`svp-cluster`, `svp-data`, `svp-observability`, `svp-policy`) chỉ dùng `values.yaml`
    của chính chart, `components.json` không ghi file values nào cho chúng.
  - Root Application `svp-root` do `argocd_root_app` (`deploy/k8s/lib.sh`) sinh, chỉ truyền `targetRevision` cho chart
    `deploy/argocd/apps`; phần 3 thêm một giá trị chọn kiến trúc node (plugin Argo Rollouts amd64 cho runner).
  - Digest phát hành: job `promote` của `images.yml` ghi `image.repository`, `image.tag`, `image.digest` vào
    `deploy/k8s/values/services/` trên nhánh `bot/promote`, mở PR cuộn; người học duyệt lượt chạy rồi merge
    ([ADR-0015](0015-cicd-devsecops-stage5.md) §9). `values-check` (lượt PR), `rescan` (hằng ngày, §7) và `gitops.sh`
    (`release_image` cùng `deploy/ci/verify-release.sh`) đọc đúng thư mục đó; Renovate bỏ qua nó (§10).
  - Image không mang gì theo môi trường: service Go đọc cấu hình bằng biến môi trường
    ([ADR-0007](0007-go-monorepo-toolchain-and-stage1-scope.md)), web không có biến `NEXT_PUBLIC_*` nào, origin và URL media đọc lúc
    chạy, `SVP_BUILD_ID` là 12 hex của commit ([ADR-0019](0019-web-k3d-supply-chain-observability.md)). Một digest chạy được ở mọi
    env, và một chữ ký (identity `images.yml@refs/heads/main`) đúng cho nó ở mọi env.
  - Tên miền của k3d (`svp.localhost`, `*.svp.localhost`, cổng 8443) nằm ở 11 giá trị trong 5 file: `wildcardHost`, `apexHost` của
    `svp-cluster`; `s3.host`, `s3.corsAllowedOrigins` của `svp-data`; `MEDIA_PUBLIC_BASE_URL`, `httpRoute.host` của gateway;
    `S3_PUBLIC_ENDPOINT` của video-service; `APP_ORIGIN`, `MEDIA_ORIGIN`, `UPLOAD_ORIGIN`, `httpRoute.host` của web. Runner trỏ ba
    tên `*.svp.localhost` về `127.0.0.1` ([ADR-0021](0021-deferred-verification-stage6b.md), Tên chốt). Sáu release báo lỗi tới
    GlitchTip với `SENTRY_ENVIRONMENT: k3d` ở cả hai đường.
- **Ràng buộc:**
  - Phần 3 chỉ sửa `deploy/k8s/envs/` (thư mục mới), `deploy/argocd/apps/`, `deploy/argocd/project.yaml`, `deploy/k8s/gitops.sh`,
    `deploy/k8s/k8s.mk`, `deploy/k8s/lib.sh`, `deploy/k8s/check-image-digests.sh`, target `helm-check` của `Makefile`,
    `renovate.json`, `deploy/ci/verify/gitops.sh`. `install.sh` (đường dev giữ nguyên), `images.yml`, `promote.sh`,
    `values-check.sh`, `rescan.sh`, chart `deploy/helm/*` và values gốc không đổi: thiết kế nào cần đổi chúng là việc của phần 4 hay
    giai đoạn 7, ghi rõ ở dưới.
  - Một cluster lab mỗi lúc (máy 16 GB hay runner 4 vCPU, ADR-0021 §1): không đòi dev và stg chạy cùng lúc. Kịch bản của
    `verify.yml` giữ tên đã chốt (ADR-0021, Tên chốt): k3d đóng vai stg là kịch bản `gitops`, không thêm kịch bản nào.
  - Repo public: overlay không chứa secret. Code không nhắc ADR (comment tự nói lý do).
- **Hiện trạng ngành** (đọc 2026-10-26):
  - Môi trường là thư mục trên một nhánh của repo cấu hình, promote là chép giá trị từ thư mục env này sang env kế; mỗi env một
    nhánh bị coi là anti-pattern (merge giữa nhánh lệch dần, thay đổi riêng của env lẫn vào lịch sử chung) [N1][N2]. Argo CD lấy
    file values từ một nguồn git thứ hai qua `ref: values` (multi-source) [N3].
  - Đang lên: Argo CD Source Hydrator (render sẵn manifest của mỗi env vào nhánh riêng, Technical Preview trong OpenShift GitOps 1.22,
    2026-10) đi cùng GitOps Promoter của argoproj-labs (chưa tới 1.0), controller mở và merge PR promote theo health của env
    [N5][N6]. Kargo của Akuity cùng loại.
  - Terraform: workspace dùng chung một backend, nên "not a suitable isolation mechanism" khi các bản triển khai cần credential và
    quyền khác nhau; khuyến cáo là module dùng chung, mỗi bản triển khai một cấu hình gốc với backend riêng [N4].

## Các lựa chọn

### 1. Mô tả khác biệt giữa các env

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Values gốc + overlay Helm values mỗi env (`deploy/k8s/envs/<env>/<component>.yaml`), Argo CD ghép bằng `valueFiles`** | Cùng công cụ mọi chart đang dùng; overlay chỉ chứa phần khác, đọc một thư mục là biết env khác gốc ở đâu; một nhánh, một lịch sử; `helm template` vẫn là phép kiểm chung | Gỡ lỗi phải đọc hai lớp values cùng lúc; một thay đổi ở gốc tới mọi env cùng lúc |
| B. Kustomize overlay trên manifest Helm đã render | Patch được cả field mà chart không mở thành value | Công cụ thứ hai cho cùng việc (Kustomize chỉ là lựa chọn so sánh ở lộ trình); Argo CD render Helm trong Kustomize cần bật `--enable-helm`; mất `helm template` làm phép kiểm chung của hai đường |
| C. Một nhánh mỗi env (prd theo nhánh `prd`) | Cổng prd là merge sang nhánh đó | Anti-pattern [N1]: nhánh lệch dần, cherry-pick; không diff được hai env trong một cây |
| D. Bộ values đầy đủ cho mỗi env, không có gốc | Mỗi env đọc độc lập | Chép values của 24 component cho mỗi env, lệch dần; "chỉ khác config" không kiểm được |
| E. Source Hydrator + GitOps Promoter, hay Kargo (đang lên) | Manifest render sẵn mỗi env; PR promote do controller mở, chờ env trước Healthy | Thêm controller và CRD (RAM của k3d); tính năng còn preview, chưa 1.0; thay luôn cơ chế PR promote vừa kiểm ở giai đoạn 5 |

### 2. Digest của mỗi env nằm ở đâu

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| A. Một digest ở values gốc cho mọi env (hiện trạng) | Không đổi promote | prd đổi cùng lúc với stg: không có cổng riêng cho prd |
| **B. Mỗi env một bộ file digest trong thư mục env; promote prd là PR chép cả bộ digest của một bản stg đã chạy và kiểm** | Cổng prd là diff của PR; nhìn cây là biết bản nào chạy ở đâu; rollback một env không đụng env kia; vẫn đúng một digest đã ký | Đổi `promote.sh`, `values-check.sh`, `rescan.sh`, `gitops.sh` để đọc theo env: việc của phần 4 |
| C. Một digest, prd theo một ref git khác (nhánh, tag) | Không thêm file | Là lựa chọn 1C cho riêng digest: config và digest của prd đi theo hai nguồn |
| D. Argo CD Image Updater mỗi env | Tự động | Đã loại ở ADR-0015 §9 (khoá ghi git trong cluster, đọc tag không gắn với chữ ký và kết quả quét) |

### 3. Argo CD chọn env thế nào

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Giá trị `env` của root Application do bước bootstrap đặt; chart `deploy/argocd/apps` thấy overlay nào có (thư mục env qua symlink trong `files/`) và chỉ thêm đúng các file đó** | Không controller mới; overlay gõ sai tên hay env lạ là lỗi render, không bị bỏ qua lặng lẽ; một chart cho mọi env | Chart app-of-apps thêm logic; thêm một symlink thư mục (Argo CD nhận symlink nằm trong repo, ADR-0014 §7) |
| B. Luôn ghi `$values/deploy/k8s/envs/<env>/<name>.yaml` với `ignoreMissingValueFiles: true` [N3] | Template đơn giản nhất | File đặt sai tên bị bỏ qua lặng lẽ: prd chạy values gốc mà không ai biết |
| C. ApplicationSet, generator theo env hay cluster | Mẫu chuẩn khi một Argo CD quản nhiều cluster; thêm env là thêm thư mục | Thêm controller (ADR-0014 §12 đặt `applicationSet.replicas: 0`); mặc định mọi Application sinh ra được cập nhật cùng lúc, thứ tự theo bước chỉ có qua Progressive Syncs, Beta từ v3.3 (tắt mặc định, bật bằng biến môi trường của controller), và chiến lược `RollingSync` tắt autosync của mọi Application nó quản [N7]; mất thứ tự wave đã kiểm ở ADR-0014 §12 |
| D. Một bản chart app-of-apps cho mỗi env | Không tham số | Chép template, lệch dần |

### 4. dev

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. dev là values gốc qua `make k8s-up` (và compose), không có `deploy/k8s/envs/dev/`** | Đường dev không đổi; không thư mục nào không ai đọc | Lệch chữ với lộ trình (`envs/{dev,stg,prd}`) |
| B. `envs/dev/` cùng một env Argo CD đi theo bản build mới nhất của `main` | Giống mô hình công ty nhiều team | Không có cluster để chạy nó (một cluster mỗi lúc); đường dev thật đọc working tree, không đọc git |

### 5. prd trước giai đoạn 7

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Chỉ render và kiểm tĩnh (`make helm-check`, `deploy/k8s/check-image-digests.sh`)** | Lỗi của overlay prd (giá trị chưa ghi đè, image lệch gốc, tên lạ) lộ trước buổi cloud tính tiền | Không chạy thật tới giai đoạn 7 |
| B. Dựng prd trên k3d | Chạy thật overlay | Nền tảng của prd là EKS; trên k3d tên miền prd không tới được và drill nhắm `svp.localhost`: không kiểm thêm điều gì so với A |

### 6. Terraform mỗi env (giai đoạn 7)

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Module chung, mỗi env một cấu hình gốc với backend riêng (state và khoá riêng), khác biệt ở `terraform.tfvars`** | Đúng khuyến cáo của HashiCorp [N4]; quyền đọc state tách theo env; tách account AWS cho prd sau này chỉ đổi backend và provider | Hai thư mục gốc gần giống nhau |
| B. Một cấu hình, workspace `stg`, `prd` | Ít file | Chung backend, chung quyền: không tách được state của prd khỏi stg [N4] |

## Quyết định

Chọn 1A, 2B, 3A, 4A, 5A và 6A (4A và 2B theo câu trả lời dòng 1 và 2 của "Cần người học chọn"). Lý do chung: giữ một công cụ (Helm) và một
nhánh, đặt khác biệt của env ở nơi đọc được và kiểm được bằng render, và không thêm controller nào khi mỗi lúc chỉ có một cluster.

### 1. Ba môi trường

| Env | Chạy ở đâu | Image | Kyverno | Values | Cổng |
| --- | --- | --- | --- | --- | --- |
| dev | máy: compose (`make up`), k3d `make k8s-up` | build từ working tree, `dev-*` chưa ký | Audit (`install.sh`) | gốc | không |
| stg | phần 3: k3d `make k8s-gitops-up` (máy, hay kịch bản `gitops` của runner); giai đoạn 7: EKS stg | GHCR, digest đã ký | Enforce | gốc + `envs/stg/` | phần 3: PR promote như ADR-0015 §9; phần 4: tự động sau build trên `main` |
| prd | phần 3: chỉ render; giai đoạn 7: EKS prd | đúng bộ digest đã chạy cùng nhau ở stg | Enforce | gốc + `envs/prd/` | phần 4: PR có người duyệt, cả bộ digest phải bằng một bản ghi triển khai stg (mục 8) |

- Cùng tên cluster `svp`, một cluster mỗi lúc: dev và stg luân phiên. `make k8s-up` vẫn từ chối cluster có Application `svp-root`,
  `make k8s-gitops-up` vẫn chỉ dựng cluster mới. Kịch bản `gitops` của `verify.yml` là "k3d đóng vai stg"; `dev-k3d` vẫn là dev.
  Tên env `dev`, `stg`, `prd` không trùng tên kịch bản hay job nào của ADR-0021.
- stg và prd đều tự đồng bộ (`automated`, `selfHeal`): cổng là merge vào git, không phải nút Sync, nên git luôn là thứ đang chạy.

### 2. Cấu trúc thư mục (phần 3)

```text
deploy/
  k8s/
    values/                      gốc: mọi env; đường dev chỉ đọc lớp này (install.sh không đổi)
      <component>.yaml
      services/<svc>.yaml        cả image.repository/tag/digest: ở phần 3 là digest của stg (PR promote ghi)
    envs/
      stg/<component>.yaml       chỉ phần khác gốc; <component> là name trong components.json
      prd/<component>.yaml
  argocd/apps/
    files/envs -> ../../../k8s/envs    để chart thấy env nào, overlay nào có
```

Quy tắc của overlay:

- Một file cho mỗi component có khác biệt, tên file là `name` của component trong `components.json` (cũng là tên release và
  Application); component không có file thì chạy values gốc. Thư mục env không có `README`: comment đầu mỗi file (tiếng Anh) nói vì
  sao env đó khác gốc.
- Thứ tự ghép: `values.yaml` của chart → file `values` của component trong `components.json` (nếu có) → overlay của env. Helm ghép
  map đệ quy và thay cả danh sách: overlay muốn đổi một phần tử của list thì ghi lại cả list.
- Overlay **không được** có: (a) image ở bất kỳ dạng nào (khối `image` của release `svp-service`, `postgres.image`, `tag:
  …@sha256:…` của chart upstream): mọi env chạy đúng image của gốc, build một lần; (b) `canary` và `httpRoute.name` của release
  `svp-service`: `canaryRoute` của `components.json` phản chiếu hai khoá đó cho mọi env (ignoreDifferences của Application); (c)
  secret hay giá trị bí mật: overlay chỉ nêu tên Secret, như values gốc.
- Ở phần 3 chỉ chart của repo và release `svp-service` có overlay; chart upstream không cần khác giữa stg và prd lúc này. Quy tắc
  vẫn áp cho chart upstream khi giai đoạn 7 cần.

### 3. Nội dung overlay ở phần 3

**stg** (k3d đóng vai stg; cấu hình chạy giữ như đường GitOps hiện nay để RAM nghỉ (b) và D1 của ADR-0021 so được với các lượt
trước):

- `env.SENTRY_ENVIRONMENT: stg` cho sáu release báo lỗi (gateway, user-service, video-service, engagement-service, feed-service, web),
  thay `k3d` của gốc: event GlitchTip nói đúng env. Đường dev giữ `k3d` (gốc không đổi).
- Không gì khác: tên miền giữ `svp.localhost` (runner và mọi drill nhắm tên đó; một cluster mỗi lúc nên không đụng tên của dev),
  replica và resources như gốc.
- Render các component của stg khác render GitOps trước khi có overlay đúng ở sáu biến đó; render của root chỉ khác ở `valueFiles`
  (và nguồn `ref: values` thêm vào) của các Application có overlay. Việc hiện thực so hai lần render và ghi lại.

**prd** (chỉ render):

- `env.SENTRY_ENVIRONMENT: prd` cho sáu release.
- Tên miền, theo dòng 3 của "Cần người học chọn". Đề xuất: tên giữ chỗ dưới TLD dành riêng `.example` (RFC 2606), không bao giờ
  phân giải tới máy nào: `svp.example` cho web, `api.svp.example`, `s3.svp.example` dưới `*.svp.example`, không ghi cổng (443); đủ
  11 giá trị ở Bối cảnh. Render của prd không được còn chuỗi `svp.localhost` (phép kiểm ở mục 6). Tên thật chọn ở giai đoạn 7 (Route
  53 và ACM).
- Sàn replica (chính sách của prd, không phải cỡ đo được): mọi release trên đường request ít nhất 2 replica trải hai node, có PDB
  `minAvailable: 1`. Gateway (HPA tối thiểu 2) và web (2 replica) đã có ở gốc; user-service, video-service, engagement-service thêm
  `replicas: 2`, `pdb`, `spreadAcrossNodes: true`; feed-service thêm `hpa.minReplicas: 2` (tối đa giữ 2 của gốc tới khi đo), `pdb`,
  `spreadAcrossNodes: true`. media-worker giữ KEDA tối thiểu 1: là consumer ngoài đường request, worker chết chỉ làm video `READY`
  chậm hơn.
- Chưa đặt ở phần 3: resources, `hpa.maxReplicas`, `canaryLimits`, cỡ database. Đó là số đo của giai đoạn 7 (k6 trên stg EKS),
  không đoán trước. Không có digest: render của prd dùng digest của gốc (mục 5).

### 4. Argo CD chọn env (phần 3)

- Root `svp-root` mang `env` trong `spec.source.helm.valuesObject`, cạnh `targetRevision` và giá trị kiến trúc node. `argocd_root_app`
  (`deploy/k8s/lib.sh`) nhận env làm tham số thứ ba và ghi nó bằng `jq --arg` như revision, nên luôn là chuỗi.
- `gitops.sh` luôn đặt `env` là `stg` và không nhận biến môi trường nào cho env: k3d chỉ đóng vai stg (mục 1, lựa chọn 5A), một biến
  chỉ có một giá trị hợp lệ là thừa. Script in `env: stg` cạnh dòng revision. Revision theo dõi chưa có `deploy/k8s/envs/stg/`
  (trước khi hiện thực) thì in `skip` như các bước khác và Argo CD dựng bằng values gốc, vì chart `apps` ở revision đó không đọc
  `env`.
- Chart `deploy/argocd/apps`:
  - `env` bắt buộc (`required`, không mặc định) và phải là tên một thư mục dưới `files/envs/`;
  - mỗi file `files/envs/<env>/<x>.yaml` phải có `x` là `name` của một component, và với release `svp-service` không được có khoá
    `image`, `canary` hay `httpRoute.name` (quy tắc (a), (b) ở mục 2; image của chart khác do mục 6 kiểm);
  - sai một điều thì `fail` lúc render: Argo CD báo `ComparisonError` trên root và `gitops.sh` dừng sau 180 s như với mọi lỗi Argo CD
    báo liên tục (ADR-0014 §12); `make helm-check` báo cùng lỗi trên máy và ở CI;
  - component có overlay thì Application của nó thêm `$values/deploy/k8s/envs/<env>/<name>.yaml` sau file values gốc; chart của repo
    chưa có nguồn `ref: values` (không có `values` trong `components.json`) thì được thêm nguồn đó.
- `deploy/argocd/project.yaml` không đổi: cùng repo, cùng đích, cùng kind.
- Không ApplicationSet ở phần 3: một cluster, một env mỗi lúc (lựa chọn 3C).

### 5. Digest và phép kiểm bản phát hành

- **Phần 3:** digest chỉ ở values gốc (`deploy/k8s/values/services/`) và đó là digest của stg. PR promote của ADR-0015 §9 (người
  học duyệt lượt chạy rồi merge) là cổng của stg; merge thì Argo CD của stg đồng bộ. `release_image` và `verify-release.sh` của
  `gitops.sh` kiểm bảy digest đó như nay; `values-check`, `rescan`, `make measure-gitops` và bước "Waiting for a release on main"
  của kịch bản `gitops` không đổi.
- Overlay không có digest (quy tắc (a)), nên không có digest nào nằm ngoài tầm của rescan (attestation quá 72 giờ thì Kyverno từ chối
  pod mới), và Renovate không có gì để đụng trong `deploy/k8s/envs/`: `renovate.json` không đổi (manager `helm-values` của repo chỉ
  đọc `deploy/k8s/values/<tên>.yaml` và `deploy/k8s/cloud/values/`, mẫu mặc định chỉ khớp file tên `values.yaml`).
- **Phần 4** (dòng 2 của "Cần người học chọn"): mục 8.

### 6. Phép kiểm tĩnh (phần 3)

- `make helm-check`: render root chart với `env=stg` và `env=prd` (cho mỗi kiến trúc mà target render), và mỗi chart của repo với
  values gốc cộng overlay của từng env; render của prd không chứa `svp.localhost`.
- `deploy/k8s/check-image-digests.sh`: render thêm mỗi component có overlay với overlay của từng env; danh sách image của render env
  (kể cả bảy image service) phải bằng đúng danh sách của render gốc. Đây là phép kiểm "build một lần, mọi env cùng image".
- Ca âm của chart `apps` (env lạ, file overlay không có component, overlay có `image`) kiểm một lần lúc hiện thực bằng bản sao tạm,
  ghi kết quả; không thành bước của `helm-check`.
- `deploy/ci/verify/gitops.sh`: sau `make k8s-gitops-up`, kiểm overlay áp thật trên cluster: Application `gateway` có
  `deploy/k8s/envs/stg/gateway.yaml` trong `valueFiles`, pod gateway có `SENTRY_ENVIRONMENT=stg` (chỉ đọc đúng biến đó).

### 7. Việc của phần 3

Nằm trọn trong các đường dẫn ở Ràng buộc; làm sau khi người học duyệt ADR này:

1. `deploy/k8s/envs/stg/`: sáu file của mục 3.
2. `deploy/k8s/envs/prd/`: sáu file release (`SENTRY_ENVIRONMENT`, sàn replica, tên miền của gateway, video-service, web) cùng
   `svp-cluster.yaml`, `svp-data.yaml` (tên miền), theo câu trả lời dòng 3.
3. `deploy/argocd/apps/`: symlink `files/envs`, giá trị `env` trong `values.yaml`, template theo mục 4.
4. `deploy/k8s/lib.sh`: `argocd_root_app REPO_URL REVISION ENV`.
5. `deploy/k8s/gitops.sh`: đặt và in `env: stg`, dòng `skip` cho revision chưa có overlay.
6. `deploy/k8s/k8s.mk`: help của `k8s-gitops-up` nói cluster đóng vai stg.
7. `Makefile` (`helm-check`) và `deploy/k8s/check-image-digests.sh`: mục 6.
8. `deploy/ci/verify/gitops.sh`: bước kiểm overlay của mục 6.
9. `deploy/argocd/project.yaml`, `renovate.json`: không đổi (mục 4, 5); chỉ sửa nếu render chỉ ra là cần, ghi lý do.
10. ADR này: trạng thái "Chấp nhận" kèm ngày duyệt và các câu trả lời; mục Hiện thực ở.

Tài liệu (`CLAUDE.md`, `docs/architecture.md` §5.1–5.2, `docs/ci-cd.md`) và dòng "chỉnh bởi 0024" ở các ADR cũ là việc cập nhật
tài liệu sau khi hiện thực.

### 8. Phần 4: repo `svp-gitops`

- Chuyển sang `svp-gitops`: values gốc (thành `base/`), `deploy/k8s/envs/{stg,prd}` (thành `envs/`), danh sách component, manifest
  Argo CD (AppProject, chart app-of-apps). Chart của repo nằm ở đâu (gói OCI do CI của repo code phát hành, hay chart nằm luôn ở
  `svp-gitops`) do ADR tách repo của phần 4 chọn; ADR này chỉ đòi cấu trúc env ở đây giữ nguyên.
- **Digest theo env** (dòng 2): file digest tách khỏi file cấu hình env, ở thư mục con `envs/<env>/images/<svc>.yaml`, mỗi file
  chỉ một khối `image` (repository, tag, digest; `values_set_image` của `lib.sh` ghi được file này như nay vì nó giữ nguyên mọi dòng
  ngoài ba dòng đó); `base/services/<svc>.yaml` không còn khối `image`. File cấu hình env `envs/<env>/<name>.yaml` giữ nguyên từ
  phần 3 (tên miền, `SENTRY_ENVIRONMENT`, sàn replica, PDB) và quy tắc (a) vẫn áp cho nó. Thứ tự ghép của mục 2 thêm một lớp cuối:
  `values.yaml` của chart → gốc → `envs/<env>/<name>.yaml` → `envs/<env>/images/<name>.yaml`. Chart app-of-apps đòi đủ bảy file
  digest cho env nó dựng (thiếu một là lỗi render: env chưa được promote một service không chạy lặng lẽ bằng digest của env khác)
  và từ chối file ở `images/` có khoá ngoài `image`. Promote chỉ ghi `envs/<env>/images/`, nên diff của PR promote chỉ là digest;
  vẫn đúng một digest đã ký cho mỗi bản. Cách kia, giữ digest trong file cấu hình và promote chỉ sửa khối `image`, làm phép kiểm
  "overlay không có `image`" của chart phải có ngoại lệ theo env và diff của PR promote lẫn với cấu hình; không chọn.
- **Đơn vị promote là cả bộ bảy digest**, không phải từng digest: thư mục `envs/<env>/images/` đọc như một khối (một bộ
  `repository@digest` cho bảy service), promote prd ghi cả bảy file trong một PR và phép kiểm so cả bộ với một bản ghi (bên dưới).
  Lý do: smoke và k6 ở stg kiểm một **tổ hợp** service cùng chạy; hai digest mỗi cái từng chạy ở stg trong hai bản khác nhau chưa
  chắc đã chạy được với nhau. stg vẫn nhận từng service (build chỉ service đổi, ADR-0015 §9): bộ của stg là thứ đang có trong
  `envs/stg/images/` lúc kiểm, bản ghi chụp lại đúng bộ đó. Gom bảy digest vào một file `release.yaml` cũng được bàn (bộ thành một
  khối ngay trong cấu trúc, diff một file), nhưng chart app-of-apps phải đọc file đó và tách khối `image` của từng service vào
  `valuesObject` thay vì nối `valueFiles`, và `values_set_image` phải viết lại; bảy file cộng phép kiểm cả bộ cho cùng bảo đảm với
  ít thay đổi hơn; không chọn.
- **stg tự động:** job `promote` của `images.yml` ghi `envs/stg/images/` bằng token của GitHub App (secret ở environment
  `promote` của repo code), mở PR và bật auto-merge; check của PR trong `svp-gitops`: `values-check` (chữ ký, attestation `vuln`
  ≤ 48 giờ) và render. Không cần người duyệt: CODEOWNERS không có dòng nào cho `envs/stg/`.
- **prd qua PR có người duyệt** (dòng 4): dispatch "promote prd" nhận một bản ghi triển khai stg (mặc định bản mới nhất; chỉ ra
  bản cũ hơn khi rollback), chép **cả bộ bảy digest** trong payload của bản ghi đó sang `envs/prd/images/` (ghi cả bảy file, file
  nào không đổi thì không vào diff), PR do GitHub App mở, mô tả PR ghi id bản ghi, commit stg và URL lượt kiểm. Không có promote
  prd theo service: bộ chưa từng chạy cùng nhau ở stg không có đường lên prd. Ruleset của `svp-gitops` bật
  `require_code_owner_review`; CODEOWNERS sở hữu `envs/prd/` và mọi file chung (gốc, danh sách component, manifest Argo CD), nên
  thay đổi nào tới prd cũng cần người học duyệt. Check của PR: ngoài chữ ký và attestation như `values-check`, **cả bộ** bảy digest
  ở `envs/prd/images/` tại HEAD của PR phải bằng đúng payload của một bản ghi triển khai stg `success` (bên dưới); từng digest khớp
  các bản ghi khác nhau không đủ.
- **Bằng chứng stg đã chạy** (bản ghi triển khai stg): lịch sử git không đủ, vì digest A merge vào `envs/stg/` rồi bị B thay trước
  khi Argo CD đồng bộ (trường hợp ADR-0014 §12 đã ghi), hay stg đồng bộ hỏng, thì A vẫn nằm trong lịch sử mà chưa chạy. Bản ghi là
  một Deployment của GitHub trên repo `svp-gitops`, environment `stg`, `ref` là commit của `svp-gitops` mà Argo CD của stg đã đồng
  bộ, trạng thái `success`, payload là bộ bảy `repository@digest` đọc từ **pod đang chạy** (image sau `@`, như `measure-gitops`
  đọc; mỗi service đúng một digest vì Rollout và Deployment đã Healthy, còn hai digest cho một service thì không ghi) và URL của
  lượt kiểm; chỉ ghi sau khi phép kiểm trên stg qua (`make k8s-smoke` trên lab; smoke và k6 trên EKS). Ai ghi (dòng 7):
  phép kiểm đã chứng minh stg, từ ngoài cluster. Phần 4 là một job của `verify.yml` chạy sau job `gitops` khi job đó xanh, nhận
  digest qua artifact; chỉ job đó có environment `promote` (token GitHub App, thêm quyền `deployments: write` trên `svp-gitops`) và
  không làm gì khác, job `gitops` vẫn không secret. Giai đoạn 7 là script kiểm stg mà người học chạy, ghi bằng đăng nhập của người
  học. Ghi và đọc bản ghi đi qua hàm `ci_*` của `platform.sh` (ADR-0023; GitLab có deployments của environment ở gói Free). Check
  của PR prd: bộ bảy `repository@digest` đọc từ `envs/prd/images/` tại HEAD của PR phải **bằng đúng payload của một bản ghi**
  `success` mà `ref` nằm trên nhánh chính của `svp-gitops` (`git merge-base --is-ancestor`); so cả bộ, không so từng digest: stg
  từng chạy `[A=x, B=b0]` rồi `[A=a1, B=z]` thì prd `[A=x, B=z]` bị từ chối, vì tổ hợp đó chưa được smoke và k6 kiểm ở stg dù từng
  digest đều có bản ghi. Không khớp bản ghi nào thì check đỏ, kể cả khi mọi digest đều có trong lịch sử của `envs/stg/`. Ở phần 4
  stg chỉ tồn tại trong một lượt `gitops`, nên promote prd chỉ có sau một lượt `gitops` xanh: "cùng bộ digest đã chạy ở stg" do máy
  kiểm, không phải quy ước.
- Rollback prd: dispatch promote prd với một bản ghi stg cũ hơn (bot mở PR chép cả bộ của bản ghi đó); bộ cũ khớp bản ghi của nó,
  nhưng check còn đòi attestation `vuln` của mỗi digest không quá 48 giờ (như `values-check`), nên bộ cũ hơn hai ngày làm PR đỏ:
  trước khi dispatch promote, dispatch rescan với `values_ref` trỏ revision của bản ghi đó (`images.yml -f rescan=true -f
  values_ref=<ref>`) để quét lại và ký attestation mới, rồi mới mở PR rollback. Lùi hay sửa gấp **một** service riêng ở prd không có: bộ mới đi qua stg (build → `envs/stg/images/` → lượt kiểm
  ghi bản ghi) rồi mới promote, như mọi bản. Người học không duyệt được PR do chính mình mở, nên mọi PR đổi `envs/prd/` đều do bot
  mở.
- Đổi ở repo code: `images.yml` (`promote` và job promote prd chép cả bộ từ một bản ghi), `verify.yml` (job ghi bản ghi triển
  khai stg), `promote.sh`, `values-check.sh`, `rescan.sh` (tập digest: `envs/*/images/` của `svp-gitops` và PR đang mở ở đó),
  `gitops.sh` và `release_image` (đọc digest của env đang dựng), `deploy/k8s/drills/gitops.sh` (`measure-gitops`: commit phát hành
  là commit của `svp-gitops`), `platform.sh` (hàm ghi và đọc bản ghi triển khai). Renovate của `svp-gitops` bỏ qua `envs/**`.
- Cơ chế chọn env (dòng 5): đề xuất giữ chart app-of-apps với `env`, chuyển nguyên sang `svp-gitops`.
- Chuyển kiểu brownfield trong một buổi: hai nguồn không chạy song song quá một buổi (lộ trình).
- Trên GitLab, Code Owners và approval rule bắt buộc là của gói Premium ([ADR-0023](0023-ci-platform-neutral.md), bảng repo): ở
  gói Free cổng prd chỉ còn protected branch cộng quy ước; environment và deployment (bản ghi stg) có ở Free; ghi vào bảng của
  ADR-0023 khi mang sang.

### 9. Giai đoạn 7: stg và prd trên hai cluster EKS

- Dựng stg nhỏ và prd trong cùng buổi, xoá cả hai cuối buổi. Mỗi cluster một Argo CD (dòng 6) với `env` của nó, chỉ đọc thư mục env
  đó; không cluster nào giữ credential của cluster kia.
- **Lớp nền tảng khác lớp env.** k3d và EKS khác nhau ở thành phần: Postgres, Redis, object store managed (RDS, ElastiCache, S3 và
  CloudFront) thay CloudNativePG, Valkey, RustFS; Load Balancer Controller, ACM, ExternalDNS thay CA tự ký và load balancer của k3d.
  Đó là khác biệt của nền tảng, không của env, nên không vào `envs/`. ADR của giai đoạn 7 chọn cách mô tả (danh sách component theo
  nền tảng, hay một lớp values nền tảng giữa gốc và env), giữ quy tắc env của ADR này giữa stg và prd trên EKS.
- Overlay prd nhận tên miền thật và cỡ đo được (resources, `hpa.maxReplicas`, `canaryLimits`) từ k6 trên stg EKS; stg trên EKS nhận
  cùng sàn replica với prd (lỗi chỉ có khi nhiều replica lộ ở stg trước), resources nhỏ hơn.
- **Terraform (6A):** đề xuất `deploy/terraform/envs/aws/stg/` và `deploy/terraform/envs/aws/prd/`, mỗi thư mục một cấu hình gốc
  gọi module chung `deploy/terraform/modules/…`, backend S3 và khoá riêng; khác biệt ở `terraform.tfvars` (số và loại node, lớp và
  dung lượng RDS, tên miền); `plan` → review → `apply` stg trước prd, `destroy` cả hai. Lộ trình đang đặt `envs/{aws,gcp,cf}` cho
  biến thể cloud, nên ADR giai đoạn 7 chốt tên cuối. Tách account AWS cho prd xét ở ADR giai đoạn 7; backend riêng từ đầu làm việc
  tách đó chỉ còn đổi backend và provider.
- **Secret mỗi env:** Secrets Manager theo đường `svp/<env>/…`, External Secrets của mỗi cluster chỉ đọc đường của env mình (Pod
  Identity); không có `.env` trên EKS.
- **Dữ liệu:** mỗi env database, bucket, cache, topic riêng. Không chép hay restore dữ liệu prd sang stg, kể cả snapshot và bản "đã
  ẩn danh": dữ liệu prd có email, hash mật khẩu, còn stg có nhiều đường vào hơn (drill, k6, chaos). stg dùng dữ liệu tổng hợp
  (`make k8s-smoke`, seed của k6, `tools/fakefollows`); diễn tập restore của prd khôi phục vào chính phía prd. Cần dữ liệu giống prd ở
  stg thì viết ADR riêng (che dữ liệu) trước.
- Migration expand/contract đi qua stg trước prd (lộ trình, bổ sung giai đoạn 7).

### Cần người học chọn

Mỗi dòng hai phương án đều dùng được; đề xuất đứng trước. Chỉ dòng 1 và 3 đổi việc hiện thực của phần 3; các dòng còn lại chốt
hướng cho phần 4 và giai đoạn 7, phần 3 như nhau với mọi câu trả lời.

Người học trả lời ngày 2026-10-26: (a) ở cả bảy dòng (1a không có `envs/dev/`; 2a mỗi env một bộ file digest, promote prd chép cả
bộ của một bản ghi triển khai stg; 3a `svp.example` cùng phép kiểm render prd không còn `svp.localhost`; 4a CODEOWNERS bắt buộc trên
`envs/prd/` và file chung; 5a giữ chart app-of-apps với `env`; 6a mỗi cluster một Argo CD; 7a bản ghi stg do phép kiểm ngoài cluster
ghi).

1. **dev có thư mục `envs/dev/` không?** (a) Không: dev là values gốc qua `make k8s-up` và compose. Lý do: đường dev đọc working tree,
   không đọc git; không có cluster thứ hai để chạy một env dev của Argo CD; thư mục không ai đọc là thừa. (b) Có, kèm một env Argo CD đi
   theo bản build mới nhất của `main`: giống công ty nhiều team, nhưng cần thêm một cluster.
2. **Digest của prd nằm ở đâu, từ phần 4?** (a) Mỗi env một bộ file digest trong `svp-gitops`, promote prd là PR chép cả bộ digest
   của một bản ghi triển khai stg. Lý do: cổng nằm ở diff, rollback từng env, máy kiểm được "cả bộ đã chạy cùng nhau ở stg". (b) Một digest cho mọi env, prd theo một ref git khác (nhánh
   hay tag): ít file hơn, nhưng là mỗi env một nhánh cho riêng digest (lựa chọn 1C).
3. **Tên miền trong overlay prd ở phần 3?** (a) Tên giữ chỗ `svp.example` (RFC 2606) cùng phép kiểm render prd không còn
   `svp.localhost`. Lý do: chứng minh cả 11 giá trị ghi đè được từ overlay trước buổi EKS tính tiền. (b) Chưa đặt tên miền tới giai
   đoạn 7: overlay prd ít hơn, nhưng chỗ sót tên của k3d chỉ lộ trên EKS.
4. **Cổng của prd ở phần 4?** (a) Review CODEOWNERS bắt buộc trên PR đổi `envs/prd/` và file chung. Lý do: Argo CD kéo từ git nên
   merge chính là deploy, người duyệt thấy đúng diff, không cần job nào ngồi chờ. (b) Environment `prd` có required reviewers trên job
   ghi prd (cách lộ trình nêu): duyệt một lượt chạy, không thấy diff. Trên GitLab cả hai cần gói Premium.
5. **Cơ chế chọn env ở phần 4?** (a) Giữ chart app-of-apps với `env`, chuyển nguyên sang `svp-gitops`. Lý do: giữ thứ tự wave và
   health đã kiểm ở ADR-0014 §12, không thêm controller. (b) ApplicationSet như lộ trình ghi: mẫu chuẩn khi nhiều cluster, nhưng thứ tự
   wave chỉ có qua Progressive Syncs (Beta từ v3.3, tắt mặc định) và `RollingSync` tắt autosync của mọi Application [N7].
6. **Argo CD ở giai đoạn 7?** (a) Mỗi cluster một Argo CD. Lý do: không credential chéo giữa cluster, prd không phụ thuộc cluster stg,
   xoá cluster nào thì Argo CD của nó đi theo. (b) Một Argo CD quản cả hai: một màn hình và một bản RAM, nhưng giữ credential của prd
   trên cluster khác.
7. **Ai ghi bản ghi triển khai stg (phần 4, giai đoạn 7)?** (a) Phép kiểm đã chứng minh stg, từ ngoài cluster: job sau `gitops` của
   `verify.yml` ở phần 4, script kiểm stg người học chạy ở giai đoạn 7. Lý do: không token nào nằm trong cluster, bản ghi gắn với
   phép kiểm đã qua chứ không chỉ Healthy của Argo CD, một dạng payload cho cả hai. (b) Argo CD Notifications của cluster stg
   (trigger `on-deployed`, service `github`, hiện tắt trong values): ghi ngay khi Healthy, không cần lượt kiểm, nhưng cần token
   `deployments: write` trong cluster và bản ghi không nói smoke đã qua.

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết; mỗi dòng nêu phép kiểm chứng minh nó; kết quả và ngày ghi vào cột cuối.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Helm trong Argo CD v3.5.5 đọc `.Files.Glob` qua symlink thư mục `files/envs` của chart `apps` như `helm` trên máy | Phần 3: `make helm-check` trên máy; kịch bản `gitops` trên runner: root `Synced`, Application `gateway` có `deploy/k8s/envs/stg/gateway.yaml` trong `valueFiles` | Đạt: `make helm-check` trên máy (2026-10-26); runner (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534), bước `gitops-env`): root và 25/25 Application Synced/Healthy, Application `gateway` có `$values/deploy/k8s/envs/stg/gateway.yaml` trong `valueFiles` |
| Overlay stg áp thật lên pod | Kịch bản `gitops`: pod gateway có `SENTRY_ENVIRONMENT=stg`; event GlitchTip của lượt e2e mang environment `stg` | Pod: đạt (2026-10-28, [40620627534](https://github.com/anhnvcoder/short-video-platform/actions/runs/40620627534)): hai pod gateway Running có `SENTRY_ENVIRONMENT=stg`. Event GlitchTip: chưa kiểm, lượt trên nhánh chạy e2e không `SVP_E2E_GLITCHTIP=1` (không có source map của image CI); kiểm ở lượt `gitops` trên `main` sau merge |
| Render các component của stg chỉ khác render GitOps trước overlay ở sáu biến `SENTRY_ENVIRONMENT` | Phần 3: `helm template` trước và sau, `diff` | Đạt (2026-10-26): mỗi service đúng một dòng `SENTRY_ENVIRONMENT` `k3d` → `stg`; root với `env=stg` chỉ thêm một dòng `valueFiles` cho sáu Application, không thêm nguồn; chart khác không đổi |
| Render prd không còn `svp.localhost`, image của mọi env bằng gốc | Phần 3: `make helm-check`, `deploy/k8s/check-image-digests.sh` | Đạt (2026-10-26): `make helm-check` exit 0 (bỏ `apexHost` của prd trên bản sao thì FAIL đúng hai dòng); `check-image-digests.sh` exit 0 với 14 render overlay, ca âm (`postgres.image` ở prd, `image.tag` ở stg) FAIL nêu đúng hai overlay |
| Chart `apps` từ chối env lạ, file overlay không có component, overlay có `image` | Phần 3: ba ca âm trên bản sao tạm | Đạt (2026-10-26): env `dev`, `../stg`, `stg/x`, rỗng; file `nosuch.yaml`, `gateway.yml`; overlay có `image`, `canary`, `httpRoute.name`; file là list, YAML hỏng: đều fail đúng message; file ẩn bị bỏ qua |
| user-service, video-service, engagement-service đúng khi chạy 2 replica (relay outbox một khoá advisory, consumer group, job dọn upload một khoá) | Giai đoạn 7: stg EKS với sàn replica của prd, `make k8s-smoke` và diễn tập trùng event | Chưa kiểm |
| PR của bot chỉ đổi `envs/stg/images/` tự merge sau check; PR đổi `envs/prd/` hay file chung không merge được khi chưa có duyệt của người học | Phần 4, **kiểm sau push**: một bản phát hành và một lần promote prd thật | Chưa kiểm |
| Check của PR prd nhận bộ digest bằng đúng payload của một bản ghi triển khai stg `success`, từ chối bộ ghép từ hai bản ghi và bộ chỉ có trong lịch sử `envs/stg/` | Phần 4, **kiểm sau push**: một lượt `gitops` xanh ghi bản ghi rồi promote prd (check xanh); một PR thử sửa tay một file của `envs/prd/images/` sang digest của bản ghi khác (check đỏ); một PR thử với bộ đã merge vào `envs/stg/images/` mà không có lượt `gitops` nào (check đỏ) | Chưa kiểm |
| Mỗi env một backend Terraform: quyền chạy `plan` của stg không đọc được state của prd | Giai đoạn 7: người học chạy, đọc lỗi từ chối | Chưa kiểm |

## Hệ quả

- **Được:**
  - Một chỗ để đọc env khác gốc ở đâu; "chỉ khác config" và "mọi env cùng image" thành phép kiểm tĩnh chạy ở CI, không phải quy ước.
  - Đường dev và mọi số đo của đường GitOps giữ nguyên ở phần 3; k3d đóng vai stg bằng đúng kịch bản `gitops` đã có.
  - Phần 4 chỉ còn dời thư mục sang `svp-gitops` và đổi chỗ ghi digest; giai đoạn 7 nhận sẵn overlay prd đã render được và các quy tắc
    dữ liệu, secret, Terraform.
- **Phải trả:**
  - Thay đổi ở gốc (values chung, version chart do Renovate nâng) tới mọi env cùng lúc, không qua stg trước. Muốn thử trước thì đặt nó
    ở overlay stg, chạy, rồi dời vào gốc; ở phần 4 CODEOWNERS bắt duyệt mọi thay đổi gốc.
  - Chart app-of-apps thêm logic kiểm overlay và một symlink thư mục; gỡ lỗi values phải `helm template` với hai lớp.
  - prd không chạy thật tới giai đoạn 7: overlay prd chỉ đúng về hình (render, image, tên miền), chưa đúng về cỡ.
  - Phần 4: check của prd phụ thuộc một bản ghi ngoài git (Deployment của `svp-gitops`); xoá environment `stg` hay bản ghi thì phải
    chạy lại lượt kiểm stg trước khi promote; `verify.yml` có thêm một job cầm secret (chỉ job ghi bản ghi). prd chỉ nhận cả bộ:
    sửa gấp một service vẫn đi qua stg và một lượt kiểm, không có đường tắt theo digest.
  - Theo đề xuất, lệch chữ với lộ trình ở hai chỗ (không có `envs/dev/`, không ApplicationSet); người học quyết ở dòng 1 và 5.
- **Xem lại khi:**
  - Có cluster thứ hai chạy cùng lúc (VM thuê, EKS): xét env dev của Argo CD (dòng 1).
  - Source Hydrator lên GA trong bản Argo CD ghim, hay GitOps Promoter tới 1.0: xét thay PR promote tự viết (lựa chọn 1E).
  - Overlay của một env dài gần bằng gốc: xét lại cái gì thuộc gốc.
  - Một Grafana xem nhiều env (giai đoạn 7): thêm `deployment.environment.name` vào resource của telemetry.
- **ADR cũ được chỉnh** (đã ghi "chỉnh bởi 0024" ở trạng thái của chúng và ở `docs/adr/README.md` ngày 2026-10-28):
  - [ADR-0014](0014-kubernetes-local-stage4.md) §12: hai đường cài thành env dev và stg; root `svp-root` thêm giá trị `env`; Application
    con thêm overlay của env; `make k8s-gitops-up` dựng cluster đóng vai stg (phần 3). ApplicationSet, bị loại ở §12, được xét lại ở
    phần 4 (dòng 5).
  - ADR-0014 §13: không đổi ở phần 3; overlay không được đặt `canary` (quy tắc (b)); `canaryLimits` của prd đặt ở giai đoạn 7 theo số đo.
  - [ADR-0015](0015-cicd-devsecops-stage5.md) §7: không đổi ở phần 3 (một chữ ký, một identity cho mọi env); phần 4: tập digest của
    rescan thành digest của mọi env trong `svp-gitops` và PR đang mở ở đó.
  - ADR-0015 §8: "Enforce trên GitOps, Audit trên dev" đọc thành Enforce trên stg và prd, Audit trên dev; cơ chế không đổi.
  - ADR-0015 §9: phần 3 không đổi (PR promote là cổng của stg); phần 4: promote stg tự động vào `envs/stg/images/` của `svp-gitops`,
    promote prd bằng PR có người duyệt chép cả bộ digest của một bản ghi triển khai stg, check so cả bộ.
  - ADR-0015 §10: phần 3 không đổi; phần 4: Renovate của `svp-gitops` bỏ qua `envs/**`.
  - [ADR-0021](0021-deferred-verification-stage6b.md): phần 3 không đổi; Tên chốt giữ nguyên, kịch bản `gitops` là k3d đóng vai stg.
    Phần 4: `verify.yml` thêm một job sau `gitops` ghi bản ghi triển khai stg với environment `promote` (mục 8), nên câu "không
    secret, không environment" của ADR-0021 hẹp lại cho đúng job đó; tên job chốt lúc hiện thực phần 4.

## Hiện thực ở

- Phần 3 (hiện thực 2026-10-26): `deploy/k8s/envs/stg/`, `deploy/k8s/envs/prd/` (overlay); `deploy/argocd/apps/` (`files/envs`, giá trị `env`, overlay
  trong template); `argocd_root_app` của `deploy/k8s/lib.sh` và `deploy/k8s/gitops.sh` (env của root); target `helm-check` của
  `Makefile` và `deploy/k8s/check-image-digests.sh` (phép kiểm tĩnh); `deploy/ci/verify/gitops.sh` (kiểm overlay trên cluster).
- Phần 4 (chưa hiện thực): repo `svp-gitops` (`base/`, `envs/`, CODEOWNERS, ruleset), job promote của `.github/workflows/images.yml`, job ghi bản ghi
  triển khai stg của `.github/workflows/verify.yml` và các script của mục 8.
- Giai đoạn 7 (chưa hiện thực): `deploy/terraform/` theo mục 9.

## Nguồn

- [N1] Codefresh, "Stop Using Branches for Deploying to Different GitOps Environments":
  <https://codefresh.io/about-gitops/branches-gitops-environments/>
- [N2] Codefresh, "How to Model Your GitOps Environments and Promote Releases between Them":
  <https://codefresh.io/blog/how-to-model-your-gitops-environments-and-promote-releases-between-them>
- [N3] Argo CD, "Multiple Sources for an Application" và "Helm" (bản 3.5: `$values`, `ignoreMissingValueFiles`):
  <https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>,
  <https://argo-cd.readthedocs.io/en/release-3.5/user-guide/helm/>
- [N4] HashiCorp, Terraform "Manage Workspaces" (khi nào không dùng workspace): <https://developer.hashicorp.com/terraform/cli/workspaces>
- [N5] Red Hat Developer, "What's new in OpenShift GitOps 1.22" (2026-10-06, Source Hydrator Technical Preview):
  <https://developers.redhat.com/blog/2026/10/06/whats-new-openshift-gitops-122>
- [N6] GitOps Promoter (argoproj-labs): <https://gitops-promoter.readthedocs.io/>
- [N7] Argo CD, "Progressive Syncs" (ApplicationSet; bản release-3.5 ghi Beta từ v3.3.0, bật bằng
  `ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS`, `RollingSync` tắt autosync):
  <https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/applicationset/Progressive-Syncs/>
