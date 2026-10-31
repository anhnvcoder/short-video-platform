# 0026. Secret của đường GitOps (stg, prd) do External Secrets Operator dựng từ một kho nguồn ngoài git: ở stg trên k3d là namespace nguồn `svp-secrets` đọc qua provider `kubernetes`, ở prd là AWS Secrets Manager (giai đoạn 7) và GCP Secret Manager (giai đoạn 8); đường dev giữ `make k8s-secrets` từ `.env`

- Trạng thái: Chấp nhận (người học duyệt 2026-10-28, chọn (a) ở cả năm dòng "Cần người học chọn"); hiện thực 2026-10-29 trên
  đường GitOps (mục Hiện thực ở), kiểm tĩnh trên máy đạt; trên cluster (kịch bản `gitops` của `verify.yml`) đạt 2026-10-29 trước khi
  tách repo và 2026-10-30 sau khi tách (values, overlay ở `svp-gitops` theo [ADR-0025](0025-gitops-config-repo.md)); `force-sync` trên
  cluster và giai đoạn 7 chưa kiểm (mục Kiểm chứng sau)
- Ngày: 2026-10-28

## Bối cảnh

- **Yêu cầu** (lộ trình của lab, giai đoạn 6b phần 4: "secret theo GitOps (External Secrets / SOPS + age, ADR)"): ở phần 4, cấu
  hình của đường GitOps chuyển sang repo **public** `svp-gitops` ([ADR-0025](0025-gitops-config-repo.md), đề xuất song song; chốt của
  lộ trình ngày 2026-10-25: repo cấu hình public, không secret). Secret phải tới cluster của stg (k3d trên runner ở giai đoạn 6b; EKS ở
  giai đoạn 7, GKE ở giai đoạn 8) và prd (chỉ render tới giai đoạn 7) mà không có giá trị, khoá hay file khoá nào trong repo nào.
  [ADR-0024](0024-multi-environment.md) §9 đã ghi hướng của giai đoạn 7: "Secrets Manager theo đường `svp/<env>/…`, External Secrets
  của mỗi cluster chỉ đọc đường của env mình (Pod Identity); không có `.env` trên EKS"; threat model SEC-3 ghi cùng biện pháp.
- **Hiện trạng** ([ADR-0014](0014-kubernetes-local-stage4.md) §8): không Secret nào trong git. `deploy/k8s/secrets.sh` (`make
  k8s-secrets`) đọc `.env` theo quy tắc chặt của `deploy/observability/glitchtip/dotenv.sh` rồi tạo 25 Secret bằng `kubectl apply
  --server-side` qua stdin; `deploy/k8s/glitchtip-init.sh` đọc DSN và hai token trong pod GlitchTip rồi tạo thêm 3 Secret. Cả hai
  đường dùng hai script đó: đường dev (`install.sh` gọi sau `svp-cluster`), đường GitOps (`gitops.sh` gọi trước khi cài Argo CD, rồi
  gọi `glitchtip-init.sh` khi GlitchTip Healthy). Secret nằm ngoài Argo CD, nên Argo CD không biết cluster cần Secret nào; đổi `.env`
  trên cluster GitOps là bước tay ở comment đầu `gitops.sh`.
- **Ràng buộc:**
  - Repo public, không secret trong repo nào (kể cả `svp-gitops`); job của `verify.yml` không có secret, không environment
    ([ADR-0021](0021-deferred-verification-stage6b.md); ngoại lệ duy nhất là job ghi bản ghi triển khai stg của ADR-0024 §8).
  - Cluster của kịch bản `gitops` mới mỗi lượt, sống vài giờ trên runner; `.env` của lượt đó sinh trên runner bằng `make env`.
  - RAM: đường GitOps trên runner đã không đạt RAM nghỉ (b) của ADR-0014 §2: điểm 60 s 7 510 MiB so với ngưỡng 6 656 MiB
    ([ADR-0017](0017-gitops-capacity-media-worker-max2.md), lượt 2026-10-28). Mọi pod thêm trên đường đó làm chênh lệch lớn hơn.
    Máy 16 GB chạy đường dev (`make k8s-up`), không chạy đường GitOps thường xuyên.
  - PSA `restricted` cho mọi namespace của project và namespace công cụ, NetworkPolicy mặc định chặn hai chiều, image bên thứ ba
    ghim `@sha256:` (ADR-0014 §3, ADR-0015 §10).
  - Công cụ mới theo quy tắc của người học: bảng có trạng thái ngành, người học chọn trước khi cài.

## Các lựa chọn

### 1. Công cụ

Trạng thái ngành đọc ngày 2026-10-28. "RAM thêm" là ước lượng thứ tự lớn, **chưa đo** (mục Kiểm chứng sau); chart không đặt
`resources` mặc định nên không có số của nhà cung cấp để dẫn.

| Lựa chọn | Trạng thái ngành | Được | Mất | RAM thêm trên k3d | Trên runner | Lên AWS (7) / GCP (8) | Hợp chốt "repo public không secret"? |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **A. External Secrets Operator (ESO)** | **Hiện hành**: CNCF Sandbox từ 2022-07-26 [N4]; bản v2.14.0 ngày 2026-10-23, nhịp phát hành 1–2 tuần [N2]; năm 2025 dự án dừng phát hành vì thiếu maintainer (issue "Health of External Secrets project", 2025-07-30) rồi bỏ phiếu phát hành lại (2025-09-10) [N3]; Argo CD xếp vào cách "secret quản ở cluster đích", cách được khuyên dùng [N1] | Repo chỉ chứa tham chiếu (tên entry, tên key), không ciphertext; cùng một mẫu ExternalSecret cho mọi env, chỉ store khác; Argo CD có sẵn health check và action refresh cho ExternalSecret [N26]; giá trị không đi qua Argo CD (không vào cache Redis của nó [N1]) | Một controller có quyền ghi Secret ở nhiều namespace (mục 6); thêm CRD; webhook kiểm tra của chart cần chứng chỉ (cert-controller đọc Secret mọi namespace, hay một Issuer của cert-manager có trước ESO), ADR này tắt webhook (Quyết định 1); ở lab, kho nguồn vẫn phải được đổ giá trị từ `.env` bằng script (bài toán "secret zero" chỉ hết ở cloud, nhờ Pod Identity/Workload Identity) | Ước lượng 40–100 MiB: một pod controller (webhook và cert-controller tắt; mặc định của chart là ba pod [N10]) | Không cần secret của CI: `.env` sinh trên runner đổ vào kho nguồn trong cluster | Provider AWS Secrets Manager hỗ trợ EKS Pod Identity (store không có khối `auth`), assume role theo store [N6]; GCP Secret Manager hỗ trợ GKE Workload Identity và Workload Identity Federation, không khoá tĩnh [N7] | **Hợp**: repo không có giá trị lẫn ciphertext |
| B. SOPS + age, Argo CD giải mã qua plugin (KSOPS, hay helm-secrets qua Config Management Plugin) | **Hiện hành**: SOPS CNCF Sandbox từ 2023, v3.13.3 ngày 2026-07-23 [N13]; age v1.3.2 [N14]; KSOPS v4.5.1 [N15], helm-secrets v4.7.10 ngày 2026-10-25 [N16]; Flux giải mã SOPS sẵn trong kustomize-controller [N17]. Với Argo CD: Argo CD "strongly caution against" cách tiêm secret lúc dựng manifest vì manifest đã dựng nằm dạng rõ trong cache Redis [N1] | Secret đi cùng commit, diff thấy key nào đổi; không controller mới trong cluster | Repo-server của Argo CD phải có khoá age (hay quyền KMS) và plugin (KSOPS cần `--enable-alpha-plugins --enable-exec`, patch repo-server hay image riêng [N15]); plaintext trong cache Redis của Argo CD [N1]; cluster mới mỗi lượt cần khoá giải mã từ ngoài vào | Gần 0 pod mới; repo-server lớn hơn khi render (init container, plugin) | Khoá age phải là secret của job `gitops` (trái ADR-0021), hay sinh mỗi lượt và mã hoá lại mọi file mỗi lượt (ciphertext trong repo thành vô dụng) | AWS KMS / GCP KMS thay age; repo-server cần quyền KMS (Pod Identity cho repo-server); vẫn qua đường plugin mà Argo CD không ưu tiên [N1] | **Không hợp** (quan điểm ở dưới) |
| C. Sealed Secrets | **Hiện hành**: v0.41.2 ngày 2026-10-26, image `docker.io/bitnami/sealed-secrets-controller` [N18]; Argo CD xếp vào cách quản ở cluster đích [N1] | Một controller nhỏ; `SealedSecret` theo GitOps như mọi manifest | Khoá niêm phong sinh trong từng cluster, tự gia hạn mỗi 30 ngày, khoá cũ không xoá [N18]; cluster mới mỗi lượt thì ciphertext của lượt trước không mở được, trừ khi mang khoá riêng vào (một secret phải giữ ngoài cluster); mỗi env một bộ ciphertext | Ước lượng 30–60 MiB (một pod) | Như B: khoá phải vào từ secret của CI, hay niêm phong lại mọi lượt | Không dùng kho của cloud; giai đoạn 7 vẫn phải chuyển sang ESO như ADR-0024 §9 | **Không hợp** (quan điểm ở dưới) |
| D. Vault/OpenBao trong cluster + Vault Secrets Operator (VSO), hay ESO với provider Vault/OpenBao | Vault đổi sang Business Source License từ 2023-08-10 [N20]; VSO v1.6.2 ngày 2026-10-21, giấy phép BSL [N21]; **OpenBao mới nổi**: fork MPL-2.0 dưới OpenSSF, v2.7.2 ngày 2026-10-26 [N19]; ESO đọc OpenBao bằng provider Vault [N12] | Kho thật trong cluster: policy, audit log, secret động | Thêm một hệ phải unseal, giữ token root hay khoá unseal (lại là secret zero); VSO là BSL và chỉ cho Vault; nặng RAM nhất; không giống kho của prd (Secrets Manager) | Ước lượng 150–300 MiB (server OpenBao) cộng operator | OpenBao chế độ dev (dữ liệu trong RAM) được, không cần secret của CI | Prd vẫn là Secrets Manager: kho lab khác hẳn kho prd | Hợp (repo không có giá trị) |
| E. Argo CD Vault Plugin (AVP) | **Legacy**: bản cuối v1.18.1 ngày 2024-06-07, commit cuối 2024-12-18 [N22]; cách tiêm lúc dựng manifest mà Argo CD khuyên tránh [N1] | Một plugin, không controller | Như B (plaintext trong cache Redis); dự án gần như đứng | 0 pod mới | Cần kho Vault/OpenBao như D | Có backend AWS, nhưng là đường Argo CD không ưu tiên | Hợp (repo có placeholder) |
| F. Secrets Store CSI Driver | **Hiện hành**: kubernetes-sigs, v1.5.7 ngày 2026-09-15 [N23]; Argo CD xếp vào cách quản ở cluster đích [N1] | Secret mount thành file, không cần lưu thành Secret | DaemonSet `privileged: true` với `hostPath` [N23]: namespace của nó không đạt PSA `restricted`; service đọc cấu hình bằng biến môi trường (`envFrom`) nên vẫn phải bật đồng bộ sang Secret | DaemonSet trên mỗi node | Không cần secret của CI | Provider AWS và GCP có | Hợp |

**Ciphertext trong repo public có tính là secret trong repo không?** Quan điểm của ADR này: **có**, với chốt của lab. Hai công cụ B,
C tự nói ciphertext an toàn để ở repo public (README của Sealed Secrets: "safe to store - even inside a public repository" [N18]).
Nhưng cùng README đó ghi: thứ gì đã vào kho phiên bản, nhất là kho public, "you must assume you cannot ever delete that
information", và khoá niêm phong lộ thì mọi `SealedSecret` mã hoá bằng nó coi như lộ, xoay khoá hay mã hoá lại không đổi được điều
đó [N18]. Với repo public bị fork và mirror, mọi giá trị cũ ở mọi env chỉ còn được bảo vệ bằng một khoá, mãi mãi; xoay mật khẩu
không rút được ciphertext cũ khỏi lịch sử. Ở lab, khoá đó lại phải tới mỗi cluster mới trên runner bằng secret của CI, trái với
ADR-0021. Nên "không secret, không khoá trong repo nào" của ADR-0025 đọc là cũng không ciphertext của secret.

### 2. Kho nguồn của stg trên k3d/runner (nếu chọn ESO)

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **a. Provider `kubernetes` đọc Secret ở namespace nguồn `svp-secrets` của chính cluster** [N5] | Không pod nào thêm ngoài ESO; `secrets.sh` đổ giá trị từ `.env` vào đó như nay; quyền đọc theo từng store bằng Role Kubernetes (`resourceNames`), giống cách IAM chia theo đường ở prd | Không thử đường gọi API của Secrets Manager và Pod Identity trước giai đoạn 7; provider không dùng được ServiceAccount của chính operator, mỗi store cần ServiceAccount riêng [N5] |
| b. Giả lập Secrets Manager bằng moto server (Apache-2.0, v5.2.5 ngày 2026-10-27 [N25]), ESO trỏ tới bằng `AWS_SECRETSMANAGER_ENDPOINT` [N6] | Cùng provider `aws` với prd, cùng cấu trúc tên `svp/<env>/…` | Thêm một pod; biến endpoint áp cho mọi store của controller [N6]; cần credential AWS giả (không thử được Pod Identity); không kiểm IAM thật nên phần quyền vẫn chưa được chứng minh |
| c. OpenBao chế độ dev trong cluster, ESO provider Vault [N12] | Kho có policy, audit | Thêm pod nặng nhất; kho lab không giống kho prd |
| d. Provider `fake` [N8] | Không pod nào | Giá trị nằm ngay trong spec của store ("returns static key/value pairs and nothing else" [N8]), tức trong git: chỉ dùng cho test render với giá trị giả |
| e. LocalStack | Giả lập AWS đầy đủ | Từ bản 2026.03.0 cần auth token cho mọi lần chạy [N24]: một secret của CI, trái ADR-0021 |

### 3. Phạm vi

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **a. ESO chỉ trên đường GitOps (stg, prd); đường dev giữ `make k8s-secrets` từ `.env`** | Máy 16 GB không thêm RAM; đường dev, compose và mọi target diễn tập của đường dev không đổi | Hai cách đưa Secret vào cluster cùng tồn tại; mẫu ExternalSecret chỉ được chạy trên runner |
| b. ESO cả đường dev | Một cách cho mọi cluster k3d | Thêm RAM lên máy 16 GB; `make k8s-up` thêm một component và một bước chờ; dev đọc working tree, không đọc git, nên lợi ích GitOps không có ở đó |

## Quyết định

Đề xuất: **1A, 2a, 3a**, người học duyệt ngày 2026-10-28. Mục 1–8 dưới đây viết theo đề xuất đó.

### 1. Công cụ: External Secrets Operator

ESO là công cụ chính, vì: repo không chứa giá trị lẫn ciphertext (hợp chốt của ADR-0025); giai đoạn 7 đã định dùng nó (ADR-0024
§9, SEC-3), nên lab học đúng mẫu sẽ chạy ở EKS và GKE, chỉ store đổi; Argo CD khuyên cách quản ở cluster đích [N1]; job `gitops` của
`verify.yml` vẫn không secret. Chart `external-secrets` của nhà phát triển, ghim version (lúc viết: chart và app 2.14.0 [N2]) và image
`@sha256:` như mọi chart bên thứ ba; Renovate nâng theo `minimumReleaseAge` của `renovate.json`. Rủi ro dừng phát hành năm 2025 [N3]
được ghi ở "Xem lại khi".

Cấu hình (values `deploy/k8s/values/external-secrets.yaml`), mỗi dòng một lý do:

- Chỉ kind namespaced: tắt `processClusterStore`, `processClusterExternalSecret`, `processPushSecret`, `processClusterPushSecret`,
  `processClusterGenerator` và CRD tương ứng [N10]. Không `ClusterSecretStore` nghĩa là không store nào đọc kho nguồn cho mọi
  namespace; quyền đọc theo từng namespace (mục 6).
- `rbac.aggregateToView/Edit/Admin: false` [N10]: ClusterRole `view`, `edit`, `admin` mặc định không được thêm quyền với
  ExternalSecret; ai tạo được ExternalSecret là đọc được thứ store của namespace đó đọc (SEC-7).
- **Không webhook, không cert-controller:** `webhook.create: false`, `certController.create: false` (cert-controller vẫn render khi
  chỉ tắt webhook, nên phải tắt riêng), `crds.conversion.enabled` để mặc định `false` [N10]. Lý do:
  - Webhook của chart chỉ kiểm tra (`ValidatingWebhookConfiguration` cho `secretstores`, `clustersecretstores`, `externalsecrets`);
    CRD không cần webhook chuyển đổi: chart tắt conversion mặc định từ khi bỏ v1alpha1 và chỉ đòi tắt nó khi tắt webhook [N10].
    Controller tự kiểm template trước khi ghi; mã của nó ghi rõ việc này dành cho cluster chạy không webhook [N27].
  - Chứng chỉ cho webhook có hai cách, cách nào cũng vướng: (1) cert-controller của chart là một pod nữa với ClusterRole
    `get/list/watch` Secret mọi namespace [N10]: thêm một workload đọc Secret toàn cluster; (2) cert-manager
    (`webhook.certManager.enabled`) cần một Issuer có trước: chart mặc định trỏ Issuer `my-issuer` không tồn tại [N10]; hai
    ClusterIssuer của project (`svp-selfsigned`, `svp-ca`) thuộc `svp-cluster` ở wave 1, mà ESO phải ở wave 0 để CRD có trước
    `svp-cluster` (nơi đặt ExternalSecret, mục 5). Issuer tự ký render cùng ESO (`extraObjects` của chart, như `cnpg-selfsigned` của CloudNativePG) là kind của cert-manager,
    cùng wave 0 nên lúc ESO sync chưa chắc có CRD (wave 0 không có `SkipDryRunOnMissingResource`), chỉ tới được nhờ retry. Không wave
    nào vừa có Issuer trước ESO vừa có CRD của ESO trước `svp-cluster`, trừ khi tách ExternalSecret khỏi `svp-cluster` sang chart
    riêng ở wave sau (Cần người học chọn, dòng 5).
  - Mất: SecretStore, ExternalSecret sai chỉ bị API server kiểm theo schema của CRD; lỗi còn lại (provider, template, store không có)
    hiện ở condition `Ready=False` lúc reconcile, health check của Argo CD thành Degraded kèm message [N26], `svp-cluster` không
    Healthy nên root dừng ở wave 1 và bảng Application của `gitops.sh` in lỗi. Bù bằng kiểm tĩnh: `make helm-check` chạy kubeconform
    trên render stg, prd với schema sinh từ CRD của đúng chart ghim, như `make cloud-check`.
  - Với cấu hình này chart chỉ render CRD, Deployment controller, ServiceAccount, RBAC, Service metrics: không kind nào của chart
    khác (ServiceMonitor tắt, CRD của nó tới ở wave 2), nên Application ESO sync ngay trên cluster mới và Healthy khi controller Ready.
- `rbac.serviceAccountTokenCreate: false` [N10] và quyền xin token đặt lại hẹp ở mục 6.
- Namespace `external-secrets`, PSA `restricted` (pod mặc định của chart: không leo quyền, root fs chỉ đọc, non-root [N10]; kiểm
  bằng render như ADR-0014 §3).

### 2. Kho nguồn

- **stg trên k3d/runner:** namespace **`svp-secrets`**, chỉ chứa Secret nguồn, không pod nào. Mỗi entry là một Secret, key là tên
  biến của `.env`. Store là `SecretStore` provider `kubernetes` [N5], `remoteNamespace: svp-secrets`, `server.caProvider` là
  ConfigMap `kube-root-ca.crt` của namespace đích, `auth.serviceAccount` là ServiceAccount riêng của store.
- **prd (giai đoạn 7):** AWS Secrets Manager, mỗi entry một secret tên `svp/<env>/<entry>`, giá trị là JSON cùng key. Store provider
  `aws`, không khối `auth` (Pod Identity của controller [N6]), mỗi `SecretStore` một `role` để assume [N6]: role của namespace nào
  chỉ được `secretsmanager:GetSecretValue` trên đúng các entry namespace đó cần. Giai đoạn 8: GCP Secret Manager, store provider
  `gcpsm` với `auth.workloadIdentity` [N7]. Chi tiết IAM do ADR giai đoạn 7, 8 chốt; ở giai đoạn 6b prd chỉ render.
- ExternalSecret dùng `remoteRef.key: <prefix><entry>`, `property: <KEY>`; `prefix` rỗng ở stg, `svp/prd/` ở prd, đặt ở overlay env.
- Entry, theo nhóm người dùng để `resourceNames` của Role và chính sách IAM có nghĩa:

| Entry | Key (tên biến `.env` hay tên do script đặt) | Ai ghi ở stg |
| --- | --- | --- |
| `pg-superuser` | `SVP_PG_SUPERUSER_PASSWORD` | `secrets.sh` |
| `pg-roles` | `SVP_{USER,VIDEO,ENGAGEMENT,FEED,GLITCHTIP}_{MIGRATOR,APP}_DB_PASSWORD` (10 key) | `secrets.sh` |
| `s3-root` | `SVP_S3_ROOT_PASSWORD` | `secrets.sh` |
| `s3-users` | `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`, `SVP_PG_BACKUP_S3_SECRET_KEY` | `secrets.sh` |
| `kafka-admin` | `SVP_KAFKA_ADMIN_PASSWORD` | `secrets.sh` |
| `kafka-users` | `SVP_KAFKA_{KEDA,USER_SERVICE,VIDEO_SERVICE,ENGAGEMENT_SERVICE,FEED_SERVICE,MEDIA_WORKER}_PASSWORD` | `secrets.sh` |
| `jwt-signing` | `JWT_SIGNING_KID`, `JWT_SIGNING_KEY` | `secrets.sh` |
| `jwt-verify` | `JWT_VERIFY_KEYS` | `secrets.sh` |
| `web` | `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | `secrets.sh` (kiểm dạng base64 32 byte như nay) |
| `obs` | `SVP_GRAFANA_ADMIN_PASSWORD`, `GLITCHTIP_SECRET_KEY`, `GLITCHTIP_ADMIN_EMAIL`, `GLITCHTIP_ADMIN_PASSWORD`, `SVP_ALERT_TELEGRAM_BOT_TOKEN`, `SVP_ALERT_TELEGRAM_CHAT_ID` (hai biến Telegram rỗng được) | `secrets.sh` |
| `glitchtip-runtime` | `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_SOURCEMAPS_TOKEN` | `secrets.sh` tạo với giá trị rỗng; `glitchtip-init.sh` ghi giá trị thật |

### 3. Phạm vi và ai đổ giá trị

- ESO chỉ trên đường GitOps: component mới trong `deploy/argocd/apps/components.json` có một field mà `install.sh` bỏ qua (đường dev
  không cài nó); ExternalSecret và store tắt ở values gốc, bật ở overlay `envs/stg/`, `envs/prd/`. Đường dev (`make k8s-up`, `make
  k8s-secrets`) không đổi hành vi.
- **stg lab:** `secrets.sh` có chế độ GitOps (do `gitops.sh` gọi như nay, trước Argo CD): đọc và kiểm `.env` như nay, chạy
  `redpanda_admin` như nay (khi cluster có dữ liệu Redpanda), rồi chỉ apply các Secret nguồn ở `svp-secrets`; không tạo Secret đích
  nào. Namespace `svp-secrets` do `svp-cluster` khai (gắn PSA), `gitops.sh` tạo sớm như các namespace khác của project.
- **`glitchtip-init.sh` ở đường GitOps:** ghi DSN và hai token vào entry `glitchtip-runtime` của `svp-secrets` (không ghi Secret đích),
  annotate `force-sync` [N9] cho ba ExternalSecret `sentry`, `glitchtip-api`, `glitchtip-sourcemaps`, chờ mỗi cái xong một lượt
  đồng bộ mới (cách chờ ở mục 7: chạy lại với DSN không đổi thì Secret đích không đổi), rồi restart như nay
  (`restart_on_secret_change`: chỉ khi `resourceVersion` của Secret đích khác annotation của workload). Entry có sẵn với giá trị rỗng từ `secrets.sh` để
  ExternalSecret `sentry` Ready ngay khi `svp-cluster` sync (không thì `svp-cluster` không Healthy, chờ GlitchTip ở wave sau: khoá vòng);
  `SENTRY_DSN` rỗng là reporter tắt, như compose. Script đọc token phải coi giá trị rỗng như chưa có.
- **prd (giai đoạn 7):** giá trị do người học đặt vào Secrets Manager bằng đăng nhập của mình (lệnh do AI soạn); DSN của GlitchTip ở
  prd chốt cùng quyết định observability của giai đoạn 7 (PushSecret không bật ở đây).

### 4. Danh sách Secret

Mọi Secret mà `deploy/k8s/secrets.sh` (25) và `deploy/k8s/glitchtip-init.sh` (3) tạo. Ở đường GitOps, mỗi Secret là một ExternalSecret
cùng tên, cùng namespace, cùng key và cùng type. Mọi ExternalSecret có `target.template`, ít nhất `type` (lý do ở mục 7); cột cuối
ghi "template" khi template còn dựng giá trị ghép (chuỗi kết nối, `users.txt`, cấu hình Alertmanager) như script dựng nay. Đường
dev giữ script cho cả 28.

| Namespace | Secret | Key | Entry nguồn | Đường GitOps |
| --- | --- | --- | --- | --- |
| `svp-data` | `pg-superuser` (`kubernetes.io/basic-auth`, nhãn `cnpg.io/reload: "true"`) | `username` (= `postgres`), `password` | `pg-superuser` | ExternalSecret, type và nhãn qua `target.template` |
| `svp-data` | `pg-roles` | 10 key `SVP_*_DB_PASSWORD` | `pg-roles` | ExternalSecret |
| `svp-data` | `s3-root` | `S3_ROOT_USER` (= `svp-admin`), `S3_ROOT_PASSWORD` | `s3-root` | ExternalSecret |
| `svp-data` | `s3-users` | `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY`, `SVP_PG_BACKUP_S3_SECRET_KEY` | `s3-users` | ExternalSecret |
| `svp-data` | `pg-backup-s3` | `ACCESS_KEY_ID` (= `svp-pg-backup`), `ACCESS_SECRET_KEY` | `s3-users` | ExternalSecret |
| `svp-data` | `redpanda-bootstrap` | `password` | `kafka-admin` | ExternalSecret |
| `svp-data` | `redpanda-superusers` | `users.txt` (`svp-admin:<mật khẩu>:SCRAM-SHA-256`) | `kafka-admin` | ExternalSecret, template |
| `svp-data` | `kafka-users` | 6 key theo tên user Kafka | `kafka-users` | ExternalSecret |
| `svp` | `user-service-env` | `DATABASE_URL` (role app), `JWT_SIGNING_KID`, `JWT_SIGNING_KEY`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` | `pg-roles`, `jwt-signing`, `kafka-users` | ExternalSecret, template; khoá ký chỉ ở đây (JWT-10) |
| `svp` | `video-service-env` | `DATABASE_URL`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, `S3_SECRET_ACCESS_KEY` | `pg-roles`, `kafka-users`, `s3-users` | ExternalSecret, template |
| `svp` | `engagement-service-env` | `DATABASE_URL`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` | `pg-roles`, `kafka-users` | ExternalSecret, template |
| `svp` | `feed-service-env` | `DATABASE_URL`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` | `pg-roles`, `kafka-users` | ExternalSecret, template |
| `svp` | `media-worker-env` | `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, `S3_SECRET_ACCESS_KEY` | `kafka-users`, `s3-users` | ExternalSecret |
| `svp` | `gateway-env` | `JWT_VERIFY_KEYS` | `jwt-verify` | ExternalSecret; gateway chỉ có khoá công khai |
| `svp` | `web-env` | `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | `web` | ExternalSecret |
| `svp` | `user-service-migrate-env`, `video-service-migrate-env`, `engagement-service-migrate-env`, `feed-service-migrate-env` (4 Secret) | `DATABASE_URL` (role migrator) | `pg-roles` | 4 ExternalSecret, template |
| `svp` | `sentry` (từ `glitchtip-init.sh`) | `SENTRY_DSN` | `glitchtip-runtime` | ExternalSecret; rỗng tới khi `glitchtip-init.sh` ghi |
| `svp-obs` | `grafana-admin` | `admin-user` (= `admin`), `admin-password` | `obs` | ExternalSecret |
| `svp-obs` | `alertmanager-svp` | `alertmanager.yaml` | `obs` | ExternalSecret; `target.template` dựng định tuyến của `alertmanager_config` (Telegram bật khi token có và chat id là số nguyên); bản thứ ba của định tuyến, cạnh `secrets.sh` và `deploy/observability/alertmanager/entrypoint.sh` |
| `svp-obs` | `alertmanager-telegram` | `bot_token` (rỗng khi Telegram tắt) | `obs` | ExternalSecret |
| `svp-obs` | `glitchtip-env` | `SECRET_KEY`, `DATABASE_URL`, `MAINTENANCE_DATABASE_URL` | `obs`, `pg-roles` | ExternalSecret, template |
| `svp-obs` | `glitchtip-admin` | `GLITCHTIP_ADMIN_EMAIL`, `GLITCHTIP_ADMIN_PASSWORD` | `obs` | ExternalSecret |
| `svp-obs` | `glitchtip-api` (từ `glitchtip-init.sh`) | `SENTRY_AUTH_TOKEN` | `glitchtip-runtime` | ExternalSecret (diễn tập đọc Secret này như nay) |
| `svp-obs` | `glitchtip-sourcemaps` (từ `glitchtip-init.sh`) | `SENTRY_SOURCEMAPS_TOKEN` | `glitchtip-runtime` | ExternalSecret (`make k8s-web-sourcemaps` đọc như nay) |
| `keda` | `keda-kafka` | `sasl` (= `scram_sha256`), `tls` (= `disable`), `username` (= `svp-keda`), `password` | `kafka-users` | ExternalSecret |

Giữ cách cũ, không thành ExternalSecret:

- **Mọi Secret trên đường dev**: `make k8s-secrets`, `make k8s-glitchtip-init` không đổi (phạm vi 3a).
- **Secret do operator hay chart tự sinh** (không script nào tạo, không có trong kho nguồn): CA, chứng chỉ của cert-manager
  (`svp-local-ca`, `svp-wildcard-tls`, chứng chỉ của listener apex), Secret PKI và replication của CloudNativePG, Secret của Argo CD
  (`argocd-secret`, `argocd-initial-admin-secret`, Redis), chứng chỉ webhook của Kyverno (ESO không có webhook, mục 1). Chúng sinh và xoay trong
  cluster; đưa qua kho nguồn chỉ thêm một bản sao phải giữ khớp.
- **Secret nguồn ở `svp-secrets`**: chính là kho nguồn của stg lab, do `secrets.sh` và `glitchtip-init.sh` ghi.

### 5. Đặt manifest ở đâu

- Template ở chart **`svp-cluster`** của repo code (`templates/external-secrets.yaml`), một file liệt kê đủ 28 ExternalSecret, 4
  SecretStore, ServiceAccount và Role: cùng một chỗ đọc được như danh sách trong `secrets.sh`, so hai bên dễ. `svp-cluster` ở wave 1
  đã tạo mọi namespace đích; component ESO ở wave 0 để CRD có trước (chart không cần kind nào của chart khác, mục 1), namespace
  `external-secrets` do Argo CD tạo với nhãn PSA như mọi namespace của wave 0. Kho nguồn đã đầy trước khi Argo CD cài (`gitops.sh`
  gọi `secrets.sh` trước), nên ExternalSecret Ready trước pod đầu tiên đọc Secret (wave 2 trở đi).
- Values gốc: `externalSecrets.enabled: false` (đường dev render không có gì). Overlay **chỉ nêu tên**, không giá trị:
  `envs/stg/svp-cluster.yaml` bật, `store: kubernetes`, `prefix: ""`; `envs/prd/svp-cluster.yaml` bật, `store: aws`, `prefix: svp/prd/`, region,
  tên role của từng store, host Postgres của prd (tên máy, không phải secret). Quy tắc overlay của ADR-0024 (không `image`) giữ nguyên.
- Ở phần 4, overlay chuyển sang `envs/` của `svp-gitops` cùng các overlay khác; chart vẫn ở repo code theo cách ADR-0025 chốt.
- prd render với store AWS trong `make helm-check` (render prd không được còn `svp-secrets`); không chạy tới giai đoạn 7.

### 6. Bảo mật

- **Quyền của controller.** ClusterRole mặc định của chart cho controller `get/list/watch/create/update/patch/delete` Secret toàn
  cluster và `create` `serviceaccounts/token` toàn cluster [N10]. Hai việc:
  - **Xin token: thu hẹp, bắt buộc.** `rbac.serviceAccountTokenCreate: false`; chart `svp-cluster` thêm ở mỗi namespace đích một Role
    chỉ `create` `serviceaccounts/token` với `resourceNames` là ServiceAccount của store namespace đó. Không thu hẹp thì controller bị
    chiếm xin được token của mọi ServiceAccount (kể cả controller của Argo CD) và leo quyền.
  - **Đọc, ghi Secret: thử thu hẹp, ghi ngoại lệ nếu không được.** Mặc định controller cache Secret do ExternalSecret quản bằng một
    watch toàn cluster (`--enable-managed-secrets-caching`, mặc định bật; `--namespace` chỉ nhận một namespace [N11]), nên RBAC theo
    namespace không đủ. Lúc hiện thực thử `--enable-managed-secrets-caching=false` với Role ghi Secret chỉ ở `svp`, `svp-data`,
    `svp-obs`, `keda` (`rbac.create` của controller tắt, ClusterRole còn lại không có `secrets`); mọi ExternalSecret Ready trên runner
    thì giữ, không thì giữ ClusterRole của chart và `make drill-k8s-threats` in ngoại lệ kèm lý do (như các ngoại lệ RBAC đã có).
    Đây là quyền ngang controller của Argo CD; ghi ở threat model SEC-5.
- **ServiceAccount của store chỉ đọc kho nguồn theo nhu cầu.** Bốn ServiceAccount (`svp-secrets-reader` ở `svp`, `svp-data`,
  `svp-obs`, `keda`), mỗi cái một Role ở `svp-secrets` chỉ `get` Secret với `resourceNames` là entry namespace đó dùng (cột "Entry
  nguồn" của mục 4) và `create` `selfsubjectrulesreviews` mà store dùng để tự kiểm quyền [N5]. Tài liệu provider ghi Role
  `get/list/watch` [N5]; chỉ `get` với `resourceNames` là giả định (mục Kiểm chứng sau). Ví dụ store của `svp` không đọc được
  `pg-superuser`, `s3-root`, `kafka-admin`, `obs`. Không ServiceAccount nào của pod service được gắn Role này.
- **Không pod nào chạy dưới ServiceAccount của store.** `automountServiceAccountToken: false` của `svp-secrets-reader` chỉ là mặc
  định: pod spec (`automountServiceAccountToken: true`) hay projected token volume ghi đè được, PSA `restricted` cho phép cả hai, và
  pod như vậy đọc mọi entry nguồn của namespace (ở `svp`: cả `pg-roles` lẫn `s3-users`, `kafka-users`, hơn mọi Secret ở đó). Chart
  `svp-cluster` thêm hai ValidatingAdmissionPolicy khi bật ESO với store `kubernetes` (store `aws` không có ServiceAccount đó):
  `svp-store-serviceaccount-pods` từ chối tạo pod có `spec.serviceAccountName` là `svp-secrets-reader` ở mọi namespace,
  `svp-store-serviceaccount-tokens` từ chối Secret `kubernetes.io/service-account-token` gắn với ServiceAccount đó (một pod
  ServiceAccount khác mount được). Policy trên pod là đủ cho mọi workload: Deployment, Job, StatefulSet chỉ chạy qua pod controller của nó tạo, pod đó bị từ chối (workload báo `FailedCreate`);
  static pod không được gắn ServiceAccount; `serviceAccountName` không đổi được sau khi tạo nên chỉ cần `CREATE`. Controller ESO
  không bị chặn: provider `kubernetes` lấy token bằng TokenRequest (`ServiceAccounts(ns).CreateToken`, hạn 3600 s), không tạo pod
  hay Secret token [N28].
- **Ai tạo được ExternalSecret** thì đọc được thứ store của namespace đó đọc: chỉ Argo CD (AppProject `svp`, Application
  `svp-cluster`) tạo; aggregate vào `edit`/`admin` tắt; `drill-k8s-threats` kiểm không ServiceAccount nào của `svp` tạo được
  ExternalSecret hay SecretStore.
- **NetworkPolicy** ở `external-secrets` như Kyverno (ADR-0014 §3, `svp-cluster` thêm ở wave 1): `default-deny`, `allow-dns`,
  `allow-kube-api` cho pod có nhãn `svp-kube-api=allow`; không webhook nên không ingress nào từ API server, chỉ ingress vào cổng
  metrics từ Prometheus. stg: không egress nào khác (provider `kubernetes` chỉ gọi API server). prd: thêm TCP 443 ra địa chỉ public
  (endpoint Secrets Manager, STS) và TCP 80 chỉ tới `169.254.170.23/32` (NetworkPolicy `allow-pod-identity-agent`, chỉ pod
  controller): store `aws` không khối `auth` lấy credential từ agent EKS Pod Identity, agent chạy `hostNetwork` trên node và nghe ở
  `169.254.170.23` cổng 80 (`AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials`) [N29]; rule 443 trừ mọi dải
  private, gồm `169.254.0.0/16`, nên thiếu rule này controller không lấy được credential và cả 4 store, 28 ExternalSecret lỗi. Không mở
  `169.254.0.0/16` (IMDS `169.254.169.254` nằm trong đó) hay cổng 2703 của agent (pod không gọi tới). Agent cũng nghe ở IPv6
  `[fd00:ec2::23]:80` [N29]: chưa thêm rule IPv6, giai đoạn 7 chốt họ IP của cluster prd rồi chọn địa chỉ (IPv6 thì `fd00:ec2::23/128`). Từ wave 0 tới wave 1 controller chưa có NetworkPolicy, nhưng chưa có store nào để đọc. `svp-secrets`
  không có pod, vẫn có `default-deny`.
- **PSA `restricted`** cho `external-secrets` và `svp-secrets`; image controller ghim `@sha256:`, qua
  `deploy/k8s/check-image-digests.sh`; AppProject `svp` chỉ thêm namespace `external-secrets`, `svp-secrets` và kind cluster-scoped
  mà chart render (CRD, ClusterRole, ClusterRoleBinding; không ValidatingWebhookConfiguration vì webhook tắt), không hơn.
- **Dòng mới cho `docs/threat-model.md`** (§4.7 Bí mật, tên dự kiến):
  - **SEC-5** — Controller ESO bị chiếm: đọc, ghi Secret của các namespace nó ghi (hay toàn cluster nếu giữ ClusterRole của chart),
    xin token cho ServiceAccount khác. Biện pháp: token chỉ cho ServiceAccount của store (Role theo namespace), không kind cluster,
    không cert-controller (ClusterRole đọc Secret mọi namespace), PSA, NetworkPolicy, image ghim digest; ngoại lệ đọc Secret (nếu
    còn) in kèm lý do ở `drill-k8s-threats`.
  - **SEC-6** — Kho nguồn: store của một namespace đọc entry không phải của nó; store của env này đọc kho của env khác. Biện pháp:
    stg: Role `get` theo `resourceNames`; prd: role assume theo store chỉ trên `svp/<env>/<entry>` cần, mỗi cluster chỉ đường env
    mình (ADR-0024 §9); không `ClusterSecretStore`.
  - **SEC-7** — Quyền tạo ExternalSecret là quyền đọc kho: chỉ Argo CD tạo, aggregate tắt, kiểm bằng `kubectl auth can-i`.
  - SEC-3 (giai đoạn 7, 8) giữ, ghi thêm "hiện thực bằng ESO theo ADR-0026".
- **Ca mới của `make drill-k8s-threats`** (chỉ khi cluster có ESO, mỗi ca có đối chứng): (a) ServiceAccount store của `svp` `get`
  `pg-superuser` ở `svp-secrets` bị từ chối, `get` `pg-roles` được; (b) controller ESO không `create` token cho
  `argocd-application-controller`, được cho ServiceAccount store của `svp`; (c) mọi ServiceAccount của `svp` không `create`
  `externalsecrets`, `secretstores`; (d) quyền Secret của controller: thu hẹp thì `list` Secret ở `argocd` bị từ chối, không thì in
  ngoại lệ `SEC-5` kèm lý do; (e) cluster không có ValidatingWebhookConfiguration hay pod cert-controller nào của ESO; pod thử ở
  `svp-probe` không tới cổng metrics của controller, Prometheus tới được (đối chứng); (f) mục `SEC-6-reader`: dry run ở `svp-data`, pod
  chạy dưới `svp-secrets-reader` và Secret token của nó bị hai policy trên từ chối đúng message, cùng pod với `default` và Secret token
  của `default` được nhận (đối chứng). `verify-mask.sh` mask Secret của `svp-secrets`.

### 7. Xoay vòng

- **Đường dev (như nay):** sửa `.env` → `make k8s-secrets` apply ngay → `make k8s-up` chạy Job init và restart workload có Secret đổi
  (so `resourceVersion` với annotation của workload).
- **ESO, mọi ExternalSecret `refreshPolicy: OnChange`** [N9]: Secret đích chỉ đổi khi spec hay metadata của ExternalSecret đổi, tức
  khi script annotate `force-sync` [N9]; `refreshInterval` không dùng (OnChange không phụ thuộc nó [N9]). Lý do không dùng `Periodic`:
  thứ tự đổi mật khẩu có ràng buộc mà làm mới định kỳ không giữ được: mật khẩu superuser Redpanda phải vào broker trước khi Secret
  `redpanda-bootstrap` đổi (không thì broker, sidecar, Job init bị khoá ở lần khởi động sau); object store phải restart trước khi
  Job `s3-init` đăng nhập bằng mật khẩu mới; service phải restart sau khi Job init đặt mật khẩu ở backend. Đổi giá trị luôn kèm
  restart và Job init, nên tự làm mới không thêm gì.
- **stg lab:** sửa `.env` → `make k8s-secrets` (chế độ GitOps: `redpanda_admin` trước, rồi apply Secret nguồn, annotate `force-sync`
  mọi ExternalSecret và chờ mỗi cái xong một lượt đồng bộ mới, rồi restart object store, Redpanda nếu còn mật khẩu cũ như nay) →
  sync Application `svp-data` (Job init) → restart workload có Secret đổi bằng cùng cơ chế annotation `resourceVersion` (gateway, web
  qua `spec.restartAt`): Secret đích không đổi thì workload không restart. Bước tay ở comment đầu `gitops.sh` thu lại còn một lệnh.
  Action `refresh` của Argo CD làm việc của `force-sync` cho từng ExternalSecret từ UI [N26].
- **Chờ một lượt đồng bộ mới, không chờ Secret đích đổi.** ESO so Secret dựng ra với Secret đang có và không ghi khi giống nhau [N27],
  nên đổi một giá trị chỉ đổi vài Secret đích (chỉ đổi `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` thì chỉ `web-env` đổi, `user-service-env`
  giữ `resourceVersion`); chờ mọi Secret đích có `resourceVersion` mới sẽ treo. Với mỗi ExternalSecret, script (`secrets.sh` và
  `glitchtip-init.sh`) đọc `status.syncedResourceVersion`, annotate `force-sync` bằng một giá trị chưa dùng, rồi chờ có hạn tới khi
  `status.syncedResourceVersion` khác giá trị đã đọc và condition `Ready` là `True`; quá hạn thì in `reason`, `message` của condition
  và dừng (message chỉ chi tiết lỗi mà ESO đánh dấu an toàn, lỗi của provider và template giữ message chung [N27]). Theo mã ESO
  v2.14.0 [N27]: `syncedResourceVersion` là `<generation>-<hash của label, annotation>` của ExternalSecret, ghi ở mọi lượt đồng bộ
  thành công kể cả khi Secret đích không đổi, không ghi khi lỗi; với `OnChange`, lượt đồng bộ chạy khi hash đó khác giá trị đã ghi.
  Giá trị annotation mới thì hash mới, nên điều kiện chờ đạt đúng khi lượt đồng bộ sau annotation thành công, miễn không ai khác đổi
  ExternalSecret trong lúc chờ: script đọc `metadata.generation` trước và sau, khác nhau (Argo CD vừa áp bản mới) thì dừng, in lệnh
  chạy lại.
- **Mọi ExternalSecret có `target.template`, ít nhất `type`.** Không template thì ESO chép label, annotation của ExternalSecret, gồm
  `force-sync`, sang Secret đích [N27]: mỗi lần `force-sync` mọi Secret đó đổi `resourceVersion` dù giá trị không đổi, và workload
  đọc nó bị restart thừa. Có template thì metadata của Secret đích chỉ lấy từ `template.metadata`; template không `data`,
  `templateFrom` thì giá trị giữ nguyên như không template [N27].
- **prd (giai đoạn 7):** đổi giá trị trong Secrets Manager (người học), rồi script của giai đoạn 7 làm như stg từ bước `force-sync`.
  Không thêm Reloader (công cụ thứ hai) ở 6b; xét lại khi prd có xoay tự động.

### Cần người học chọn

Mỗi dòng đều dùng được; đề xuất đứng trước. Người học duyệt ngày 2026-10-28: chọn (a) ở cả năm dòng.

1. **Công cụ:** (a) ESO. Lý do: repo không ciphertext, giai đoạn 7, 8 dùng cùng mẫu, runner không cần secret, Argo CD khuyên cách
   này [N1]. (b) SOPS + age qua helm-secrets: secret đi cùng commit, nhưng ciphertext trong repo public, khoá age là secret của CI,
   Argo CD khuyên tránh [N1]. (c) Sealed Secrets: một controller nhỏ, nhưng khoá gắn cluster mới mỗi lượt và vẫn phải chuyển sang ESO ở
   giai đoạn 7. (d) OpenBao + ESO: kho thật trong cluster, nặng RAM nhất, kho lab khác kho prd.
2. **Kho nguồn của stg lab (nếu 1a):** (a) provider `kubernetes`, namespace `svp-secrets`. Lý do: không pod thêm trên đường đã vượt
   RAM, quyền chia theo entry kiểm được bằng RBAC. (b) moto giả lập Secrets Manager: cùng provider `aws` với prd nhưng thêm pod,
   credential giả, không kiểm IAM thật. (c) OpenBao dev.
3. **Phạm vi:** (a) chỉ đường GitOps, dev giữ `make k8s-secrets`. Lý do: máy 16 GB không thêm RAM, đường dev không đọc git. (b) cả
   đường dev.
4. **Pod nhận giá trị mới:** (a) script restart như nay, ExternalSecret `OnChange`. Lý do: giữ thứ tự đổi mật khẩu; không thêm
   công cụ. (b) thêm Reloader (stakater) để pod tự restart khi Secret đổi: ít bước tay hơn, nhưng là công cụ thứ hai, thêm pod, và
   restart sớm hơn Job init (lỗi thứ tự của mục 7).
5. **Webhook của ESO:** (a) tắt, chỉ controller. Lý do: không cần Issuer hay cert-controller, ESO ở wave 0 sync ngay, một pod; lỗi
   spec hiện ở health Degraded thay vì bị từ chối lúc áp, bù bằng kubeconform. (b) bật, chứng chỉ của cert-manager: Issuer tự ký
   `external-secrets-selfsigned` render cùng ESO bằng `extraObjects`, ESO dời sang wave 1 (CRD của cert-manager đã có), ExternalSecret,
   store tách khỏi `svp-cluster` sang chart mới ở wave 2; Secret `grafana-admin`, `alertmanager-svp` khi đó tới cùng wave với
   kube-prometheus-stack đọc chúng (pod chờ Secret rồi tự chạy), thêm một pod webhook. (c) bật, cert-controller của chart: không cần
   Issuer, nhưng thêm hai pod, một pod có ClusterRole đọc Secret mọi namespace [N10].

## Kiểm chứng sau

Giả định chưa kiểm lúc viết; kiểm tĩnh trên máy lúc hiện thực và trên runner bằng lượt `verify.yml` (kịch bản `gitops`).

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Render dev không có ESO, stg có store `kubernetes`, prd có store `aws` và không còn `svp-secrets` | `make helm-check`, `deploy/k8s/check-image-digests.sh` | Đạt trên máy 2026-10-29: `make helm-check` exit 0 (render gốc không ExternalSecret, SecretStore; stg và prd mỗi env 28 ExternalSecret, 4 SecretStore, provider `kubernetes`/`aws`; prd không `svp-secrets`); `check-image-digests.sh` exit 0, image ESO ghim digest |
| Chart ESO với `webhook.create: false`, `certController.create: false` chỉ render CRD, controller, RBAC, Service (không Certificate, Issuer, ValidatingWebhookConfiguration, pod cert-controller); Application ESO Healthy ở wave 0 trên cluster mới | `helm template` chart ghim với values (lúc hiện thực); kịch bản `gitops`: root qua wave 0 | Phần render: đạt trên máy 2026-10-29 lúc hiện thực; Application Healthy ở wave 0: đạt (`gitops` [40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305) 2026-10-29: 26 Application Synced và Healthy, gồm `external-secrets`; sau tách repo [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) 2026-10-30: 26/26) |
| ExternalSecret, SecretStore render ra hợp schema CRD của chart ghim | `make helm-check` (kubeconform) | Đạt trên máy 2026-10-29: kubeconform `-strict` 32 hợp lệ mỗi env; ca âm (field lạ trong ExternalSecret) đỏ lúc hiện thực |
| 28 ExternalSecret Ready, mỗi Secret đích có đủ key (chỉ đọc tên key) trước pod đầu tiên đọc nó | Kịch bản `gitops`: bước kiểm ExternalSecret của `deploy/ci/verify/gitops.sh`, rồi `make k8s-smoke` | Đạt: [40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305) (2026-10-29) bước `gitops-external-secrets` ra `28 ExternalSecrets Ready, each Secret with its type and keys`, `k8s-smoke` xanh; [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) (2026-10-29) 28/28 Ready, đúng type và key |
| Đường dev không đổi | Kịch bản `dev-k3d`, bước `k8s-smoke`; `make k8s-up` không cài component ESO | Đạt: `dev-k3d` [40857870284](https://github.com/anhnvcoder/svp-backend/actions/runs/40857870284) (2026-10-29): log `k8s-up` và `k8s-status.txt` không có `external-secrets` hay `svp-secrets`, `k8s-smoke` xanh; sau tách repo [40937054425](https://github.com/anhnvcoder/svp-backend/actions/runs/40937054425) (2026-10-29) `k8s-smoke` xanh |
| Role chỉ `get` với `resourceNames` đủ cho provider `kubernetes` (tài liệu ghi `get/list/watch` [N5]) | Kịch bản `gitops`: ExternalSecret Ready với Role đó | Đạt: ExternalSecret Ready với Role đó ở [40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305) và [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) |
| Controller chạy được với `--enable-managed-secrets-caching=false` và Role ghi Secret theo namespace | Kịch bản `gitops`; không được thì ngoại lệ SEC-5 in ở `drill-k8s-threats` | Không làm (đọc mã v2.14.0 lúc hiện thực, 2026-10-29): controller luôn watch metadata của Secret toàn cluster bất kể cờ đó, nên cần list/watch Secret mọi namespace. Giữ ClusterRole của chart; ghi Secret giới hạn bằng ValidatingAdmissionPolicy `svp-external-secrets-writes`; trên cluster SEC-5 PASS ([40873382301](https://github.com/anhnvcoder/svp-backend/actions/runs/40873382301), [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229)); dòng `info SEC-5 exception …` không có trong artifact (bộ lọc chỉ giữ dòng kết luận), đọc ở `.k8s/drills/threats-<time>.log` khi chạy trên máy |
| `force-sync` không đổi giá trị: `status.syncedResourceVersion` của ExternalSecret đổi (script không treo), Secret đích giữ `resourceVersion` nhờ template (không restart thừa); chỉ đổi một giá trị thì chỉ Secret đọc nó đổi | Kịch bản `gitops`: `make k8s-secrets` hai lần không đổi `.env`, rồi một lần chỉ đổi `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`; mỗi lần so `syncedResourceVersion` của 28 ExternalSecret và `resourceVersion` của 28 Secret đích: mọi lượt chờ kết thúc, lần cuối chỉ `web-env` đổi | Chưa kiểm: chưa lượt nào chạy `make k8s-secrets` trên cluster GitOps |
| `force-sync` tới Secret đích trong vài giây | Kịch bản `gitops`: đo khi `glitchtip-init.sh` ghi DSN | Chưa kiểm: chưa trích số đo |
| Ca SEC-5, SEC-6, SEC-7 của `drill-k8s-threats` PASS với đối chứng | Kịch bản `gitops`, bước `drill-k8s-threats` | Đạt: [40873382301](https://github.com/anhnvcoder/svp-backend/actions/runs/40873382301) (2026-10-29, chỉ `drill-k8s-threats`) SEC-5, SEC-6, SEC-7 PASS gồm đối chứng; lượt trước [40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305) FAIL ở ca đối chứng (danh tính dùng để thử, đã sửa); sau tách repo [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) (2026-10-29) 16/16 mục PASS |
| RAM thêm của ESO (một pod controller) trong khoảng ước lượng 40–100 MiB | Kịch bản `gitops`: RAM nghỉ điểm 60 s và cuối, so lượt 2026-10-28 của ADR-0017 | Đạt: pod `external-secrets` 46 MiB ([40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305)); RAM nghỉ điểm 60 s 8 987 MiB, trừ `active_file` 6 731, pod 4 020 (lượt 2026-10-28: 8 937 / 7 510 / 4 073); cuối 7 110,5 MiB (lượt 2026-10-28: 9 863) |
| Không giá trị secret nào trong log, artifact của lượt chạy | `verify-collect.sh` quét theo giá trị đã biết, gồm Secret của `svp-secrets` | Chưa kiểm riêng ở đường GitOps: chưa đọc lại kết quả quét của `verify-collect.sh` (`files.txt`) của [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229); `dev-k3d` [40937054425](https://github.com/anhnvcoder/svp-backend/actions/runs/40937054425): không lộ Secret |
| Pod Identity + assume role theo store chỉ đọc được entry của namespace mình ở prd | Giai đoạn 7, người học chạy, đọc lỗi từ chối | Chưa kiểm |
| Controller ESO trên EKS lấy được credential qua agent Pod Identity với NetworkPolicy `allow-pod-identity-agent` (chỉ `169.254.170.23/32` TCP 80), không cần egress link-local nào khác; họ IP của cluster (IPv4 hay IPv6 `[fd00:ec2::23]:80`) | Giai đoạn 7: mọi SecretStore `aws` Ready, ExternalSecret Ready; chọn rule theo họ IP | Chưa kiểm; render prd kiểm trên máy 2026-10-29 (`make helm-check`, kubeconform `-strict`) |
| `svp-store-serviceaccount-pods`, `-tokens` từ chối pod chạy dưới `svp-secrets-reader` và Secret token của nó, không chặn pod khác hay TokenRequest của controller | Kịch bản `gitops`: mục `SEC-6-reader` của `drill-k8s-threats` (dry run ở `svp-data`, đối chứng với `default`), 28 ExternalSecret vẫn Ready | Đạt: mục `SEC-6-reader` PASS kèm hai ca đối chứng `default` ở [40857855305](https://github.com/anhnvcoder/svp-backend/actions/runs/40857855305), [40873382301](https://github.com/anhnvcoder/svp-backend/actions/runs/40873382301) (2026-10-29) và [40954609229](https://github.com/anhnvcoder/svp-backend/actions/runs/40954609229) (2026-10-29), 28 ExternalSecret vẫn Ready; trên máy 2026-10-29: kubeconform `-strict` nhận hai policy, biểu thức CEL biên dịch và cho đúng kết quả từng ca bằng cel-go |

## Hệ quả

- **Được:**
  - Danh sách Secret mà cluster cần nằm trong git (chỉ tên, key, nguồn), Argo CD sync và báo health từng cái; repo vẫn không có giá
    trị hay ciphertext nào.
  - Cùng mẫu ExternalSecret cho stg lab, stg và prd trên EKS, GKE; giai đoạn 7 chỉ thêm store `aws` và IAM.
  - Đổi `.env` trên cluster GitOps còn một lệnh thay vì các bước tay ở comment đầu `gitops.sh`.
  - Đường dev và máy 16 GB không đổi.
- **Phải trả:**
  - Thêm một controller có quyền rộng trên Secret (SEC-5), một pod và CRD trên đường GitOps vốn đã vượt RAM nghỉ (b) trên runner.
  - Không webhook kiểm tra: SecretStore, ExternalSecret sai được API server nhận (chỉ kiểm schema), lỗi hiện ở health Degraded của
    Argo CD lúc sync, bù bằng kubeconform ở `make helm-check`.
  - Hai cách đưa Secret vào cluster cùng tồn tại (script ở dev, ESO ở GitOps); `secrets.sh` có hai chế độ; định tuyến Alertmanager
    có bản thứ ba phải giữ khớp.
  - Ở stg lab, kho nguồn chỉ là một namespace khác của cùng cluster: lợi ích bảo mật thật (không secret zero, IAM) chỉ có ở cloud.
  - Phụ thuộc một dự án từng dừng phát hành năm 2025 [N3].
- **Xem lại khi:**
  - ESO dừng phát hành lại, hay không còn bản vá cho CVE của image ghim quá 30 ngày: xét Secrets Store CSI Driver hay provider khác.
  - ESO hỗ trợ cache theo nhiều namespace: bỏ ngoại lệ SEC-5 (nếu còn).
  - Có xoay secret tự động ở prd (giai đoạn 7): xét Reloader hay restart theo sự kiện.
  - RAM nghỉ của đường GitOps đo được với ESO vượt thêm quá 100 MiB: đặt `resources` cho controller và xem lại cache (mục 6).
  - Chart ESO bật lại conversion webhook hay bỏ cách chạy không webhook: chọn lại dòng 5 của Cần người học chọn.
- **Thay đổi ở tài liệu khác khi ADR này được chấp nhận** (đã ghi ngày 2026-10-29):
  - `docs/adr/README.md`: dòng 0026.
  - [ADR-0014](0014-kubernetes-local-stage4.md): trạng thái thêm "§8 (Secret của đường GitOps) chỉnh bởi 0026"; câu "Giai đoạn 7 thay
    script bằng External Secrets + AWS Secrets Manager" thành "đường GitOps dùng ESO từ giai đoạn 6b phần 4, store AWS ở giai đoạn 7".
  - [ADR-0024](0024-multi-environment.md) §9: dòng "Secret mỗi env" thêm assume role theo store (mục 2).
  - [ADR-0021](0021-deferred-verification-stage6b.md): kịch bản `gitops` thêm bước kiểm ExternalSecret.
  - `docs/threat-model.md`: SEC-5, SEC-6, SEC-7 ở §4.7, SEC-3 ghi hiện thực bằng ESO, bảng giai đoạn 6b.
  - `CLAUDE.md`: mục `make k8s-secrets`, `make k8s-glitchtip-init`, `make k8s-gitops-up`, `make drill-k8s-threats`; `docs/architecture.md`
    phần Secret.

## Hiện thực ở

Hiện thực 2026-10-29 (đường GitOps, values và overlay ở repo code tới khi tách `svp-gitops` theo ADR-0025). Từ 2026-10-30 các file
`deploy/argocd/…`, `deploy/k8s/values/…`, `deploy/k8s/envs/…` dưới đây nằm ở repo `svp-gitops` (`argocd/apps/components.json`,
`argocd/apps/templates/applications.yaml`, `argocd/project.yaml`, `base/external-secrets.yaml`, `envs/stg/svp-cluster.yaml`,
`envs/prd/svp-cluster.yaml`); phép kiểm của `deploy/k8s/check-image-digests.sh` và `helm-check` gộp vào `deploy/ci/gitops-check.sh`.

- `deploy/argocd/apps/components.json` (component `external-secrets`, chart 2.14.0, wave 0, `gitopsOnly: true`),
  `deploy/argocd/apps/templates/applications.yaml` (nhãn PSA cho namespace của wave 0, ý nghĩa `gitopsOnly`),
  `deploy/k8s/values/external-secrets.yaml` (chỉ controller, không webhook, cert-controller; aggregate tắt;
  `serviceAccountTokenCreate: false`; image ghim digest), `deploy/argocd/project.yaml` (repo chart, namespace `external-secrets`,
  `svp-secrets`).
- `deploy/helm/svp-cluster/files/external-secrets.yaml`: danh sách 28 Secret (tên, namespace, type, entry/key nguồn, template).
  `deploy/helm/svp-cluster/templates/external-secrets.yaml`: 4 SecretStore `svp-store`, ServiceAccount `svp-secrets-reader` và Role
  `get` theo `resourceNames` ở `svp-secrets`, Role token theo tên, 28 ExternalSecret `refreshPolicy: OnChange` có
  `target.template`, ValidatingAdmissionPolicy `svp-external-secrets-writes` (ghi Secret của controller chỉ ở bốn namespace đích,
  không Secret token; mục 6, thay cho Role ghi theo namespace, xem Kiểm chứng sau), `svp-store-serviceaccount-pods` và `-tokens`
  (không pod nào chạy dưới `svp-secrets-reader`, không Secret token của nó; mục 6). `templates/namespaces.yaml` (namespace
  `svp-secrets`), `templates/networkpolicies.yaml` (`external-secrets`, `svp-secrets`; prd thêm `allow-pod-identity-agent`),
  `values.yaml` (`externalSecrets`, tắt).
- `deploy/k8s/envs/stg/svp-cluster.yaml` (bật, store `kubernetes`), `deploy/k8s/envs/prd/svp-cluster.yaml` (bật, store `aws`, prefix
  `svp/prd/`, region, role mỗi namespace, host Postgres; giá trị giữ chỗ tới giai đoạn 7).
- `deploy/k8s/secrets.sh` (chế độ GitOps theo namespace `svp-secrets`: ghi nguồn, tạo `glitchtip-runtime` rỗng, `force-sync`),
  `deploy/k8s/glitchtip-init.sh` (ghi `glitchtip-runtime`, `force-sync` ba ExternalSecret), `deploy/k8s/lib.sh` (`es_force_sync`:
  chờ `syncedResourceVersion` đổi và `Ready`, dừng khi `generation` đổi), `deploy/k8s/gitops.sh` (render namespace với overlay env
  của revision), `deploy/k8s/install.sh` (bỏ qua component `gitopsOnly`).
- `deploy/k8s/drills/threats.sh` (SEC-5, SEC-6, SEC-7; mục `SEC-6-reader`), `deploy/ci/verify/gitops.sh` (bước `gitops-external-secrets`),
  `deploy/ci/verify-mask.sh` (mask Secret của `svp-secrets`), `deploy/ci/verify-collect-test.sh`, `deploy/k8s/check-image-digests.sh`,
  `Makefile` (`helm-check`: đếm ExternalSecret, SecretStore, provider theo env và kubeconform theo CRD của chart ghim),
  `renovate.json` (chart và image ESO).

## Nguồn

Mọi nguồn đọc ngày 2026-10-28.

- [N1] Argo CD, "Secret Management" (hai cách; "We strongly recommend the former", "We strongly caution against this style",
  manifest đã dựng nằm dạng rõ trong cache Redis): <https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/>
- [N2] External Secrets Operator, releases (v2.14.0 và helm-chart-2.14.0 ngày 2026-10-23, v2.13.0 ngày 2026-10-16, v2.12.0 ngày
  2026-10-06): <https://github.com/external-secrets/external-secrets/releases>
- [N3] External Secrets Operator, issue #5084 "Health of External Secrets project" (2025-07-30) và #5293 "Vote on continuing releases"
  (2025-09-10, đã đóng): <https://github.com/external-secrets/external-secrets/issues/5084>,
  <https://github.com/external-secrets/external-secrets/issues/5293>
- [N4] CNCF, trang dự án External Secrets (Sandbox, nhận ngày 2022-07-26): <https://www.cncf.io/projects/external-secrets/>
- [N5] ESO, provider Kubernetes (`remoteNamespace`, `auth.serviceAccount`, Role `get/list/watch` + `selfsubjectrulesreviews`, không dùng
  được ServiceAccount của operator): <https://external-secrets.io/latest/provider/kubernetes/>
- [N6] ESO, AWS Access (EKS Pod Identity không khối `auth`, assume role, endpoint tuỳ chỉnh `AWS_SECRETSMANAGER_ENDPOINT` áp cho mọi
  resource của controller): <https://external-secrets.io/latest/provider/aws-access/>; provider AWS Secrets Manager:
  <https://external-secrets.io/latest/provider/aws-secrets-manager/>
- [N7] ESO, provider Google Cloud Secret Manager (`auth.workloadIdentity`, `auth.workloadIdentityFederation`):
  <https://external-secrets.io/latest/provider/google-secrets-manager/>
- [N8] ESO, provider Fake ("returns static key/value pairs and nothing else", giá trị ở `spec.provider.fake.data`):
  <https://external-secrets.io/latest/provider/fake/>
- [N9] ESO, ExternalSecret (`refreshPolicy` `CreatedOnce`/`Periodic`/`OnChange`, annotation `force-sync`), bản v2.14.0:
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/docs/api/externalsecret.md>
- [N10] ESO, chart helm-chart-2.14.0: `values.yaml` (`process*`, `rbac.aggregateTo*`, `rbac.serviceAccountTokenCreate`,
  `webhook.create` "If set to false, crds.conversion.enabled should also be set to false", `crds.conversion.enabled: false`
  "Conversion is disabled by default as we stopped supporting v1alpha1", `webhook.certManager.cert.issuerRef` mặc định Issuer
  `my-issuer`, `certController`, securityContext); `templates/rbac.yaml` (ClusterRole controller: Secret
  `get/list/watch/create/update/delete/patch`, `serviceaccounts/token` `create`); `templates/webhook-certificate.yaml` (Certificate
  theo `issuerRef`); `templates/validatingwebhook.yaml` (chỉ kiểm `secretstores`, `clustersecretstores`, `externalsecrets`);
  `templates/cert-controller-deployment.yaml` (render khi `certController.create` và không `webhook.certManager.enabled`, không xét
  `webhook.create`); `templates/cert-controller-rbac.yaml` (ClusterRole cert-controller: Secret `get/list/watch` không
  `resourceNames`): <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/values.yaml>,
  <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/templates/rbac.yaml>,
  <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/templates/webhook-certificate.yaml>,
  <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/templates/validatingwebhook.yaml>,
  <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/templates/cert-controller-deployment.yaml>,
  <https://github.com/external-secrets/external-secrets/blob/helm-chart-2.14.0/deploy/charts/external-secrets/templates/cert-controller-rbac.yaml>
- [N11] ESO, `cmd/controller/root.go` bản v2.14.0 (cờ `--enable-managed-secrets-caching` mặc định true, `--enable-secrets-caching`
  mặc định false, `--namespace` một namespace):
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/cmd/controller/root.go>
- [N12] ESO, provider OpenBao (qua provider HashiCorp Vault):
  <https://github.com/external-secrets/external-secrets/blob/main/docs/provider/openbao.md>
- [N13] SOPS (CNCF Sandbox từ 2023; v3.13.3 ngày 2026-07-23): <https://github.com/getsops/sops>
- [N14] age (v1.3.2 ngày 2026-08-29): <https://github.com/FiloSottile/age>
- [N15] KSOPS, README mục "Argo CD Integration" (`--enable-alpha-plugins`, `--enable-exec`, patch repo-server; v4.5.1 ngày 2026-04-13):
  <https://github.com/viaduct-ai/kustomize-sops>
- [N16] helm-secrets, "ArgoCD Integration" (khoá từ Secret hay KMS; v4.7.10 ngày 2026-10-25):
  <https://github.com/jkroepke/helm-secrets/blob/main/docs/ArgoCD%20Integration.md>
- [N17] Flux, "Manage Kubernetes secrets with SOPS" (kustomize-controller giải mã, khuyên age):
  <https://fluxcd.io/flux/guides/mozilla-sops/>
- [N18] Sealed Secrets, README ("safe to store - even inside a public repository"; "you must assume you cannot ever delete that
  information"; khoá niêm phong lộ thì mọi SealedSecret của nó lộ; gia hạn khoá mỗi 30 ngày, khoá cũ không xoá) và chart
  (`docker.io/bitnami/sealed-secrets-controller`, v0.41.2 ngày 2026-10-26): <https://github.com/bitnami-labs/sealed-secrets>
- [N19] OpenBao (MPL-2.0, OpenSSF; v2.7.2 ngày 2026-10-26): <https://github.com/openbao/openbao>
- [N20] HashiCorp, "HashiCorp adopts Business Source License" (2023-08-10):
  <https://www.hashicorp.com/en/blog/hashicorp-adopts-business-source-license>
- [N21] Vault Secrets Operator (giấy phép Business Source License; v1.6.2 ngày 2026-10-21):
  <https://github.com/hashicorp/vault-secrets-operator>
- [N22] Argo CD Vault Plugin (bản cuối v1.18.1 ngày 2024-06-07, commit cuối 2024-12-18):
  <https://github.com/argoproj-labs/argocd-vault-plugin>
- [N23] Secrets Store CSI Driver (v1.5.7 ngày 2026-09-15; DaemonSet `privileged: true`, `hostPath` trong template chart):
  <https://github.com/kubernetes-sigs/secrets-store-csi-driver>
- [N24] LocalStack, "LocalStack for AWS Is Moving to a Single Image" và "Announcing the LocalStack for AWS 2026.03.0 Release" (auth
  token bắt buộc): <https://blog.localstack.cloud/localstack-single-image-next-steps/>,
  <https://blog.localstack.cloud/localstack-for-aws-release-2026-03-0/>
- [N25] moto (Apache-2.0; v5.2.5 ngày 2026-10-27): <https://github.com/getmoto/moto>
- [N26] Argo CD, resource customization của `external-secrets.io/ExternalSecret` và `SecretStore` (`health.lua`: `Ready=False` là
  Degraded kèm message, `Ready=True` là Healthy; action `refresh` của ExternalSecret):
  <https://github.com/argoproj/argo-cd/tree/master/resource_customizations/external-secrets.io/ExternalSecret>,
  <https://github.com/argoproj/argo-cd/tree/master/resource_customizations/external-secrets.io/SecretStore>
- [N27] ESO, mã nguồn bản v2.14.0: `externalsecret_controller.go` (`markAsDone` ghi `status.refreshTime`,
  `status.syncedResourceVersion` ở mọi lượt đồng bộ thành công; `markAsFailed` không ghi `syncedResourceVersion`, message chỉ chi tiết
  lỗi đã đánh dấu an toàn; `shouldRefresh` với `OnChange`; `updateSecret` trả về sớm khi Secret dựng ra giống Secret đang có);
  `externalsecret_controller_template.go` (`ApplyTemplate` kiểm template cả khi không webhook; không template thì chép label,
  annotation của ExternalSecret sang Secret, có template thì lấy từ `template.metadata`; template không `data`, `templateFrom` thì giữ
  giá trị); `pkg/controllers/util/util.go` (`GetResourceVersion` = `<generation>-<hash label, annotation>`);
  `pkg/controllers/util/statuserr.go` (`SafeMessage`):
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/pkg/controllers/externalsecret/externalsecret_controller.go>,
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/pkg/controllers/externalsecret/externalsecret_controller_template.go>,
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/pkg/controllers/util/util.go>,
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/pkg/controllers/util/statuserr.go>
- [N28] ESO, mã nguồn bản v2.14.0, đọc ngày 2026-10-29: `providers/v1/kubernetes/auth.go` (gọi
  `BuildRESTConfigFromKubernetesConnection`); `runtime/esutils/k8s_rest_config.go` (`auth.ServiceAccount` → `serviceAccountToken`:
  `coreV1.ServiceAccounts(namespace).CreateToken(...)`, `ExpirationSeconds` 3600, token làm bearer; không tạo pod, không đọc Secret
  token): <https://github.com/external-secrets/external-secrets/blob/v2.14.0/providers/v1/kubernetes/auth.go>,
  <https://github.com/external-secrets/external-secrets/blob/v2.14.0/runtime/esutils/k8s_rest_config.go>
- [N29] AWS, Amazon EKS User Guide, đọc ngày 2026-10-29: "Understand how EKS Pod Identity works"
  (`AWS_CONTAINER_CREDENTIALS_FULL_URI` `http://169.254.170.23/v1/credentials`); "Set up the Amazon EKS Pod Identity Agent" ("The
  agent uses the loopback (localhost) IP address `169.254.170.23` for `IPv4` and the localhost IP address `[fd00:ec2::23]` for
  `IPv6`"); "Learn how EKS Pod Identity grants pods access to AWS services" (`hostNetwork`, "occupying ports `80` and `2703` on the
  link-local address"): <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>,
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html>,
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
