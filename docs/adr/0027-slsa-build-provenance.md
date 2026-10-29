# 0027. SLSA build provenance cho bảy image phát hành: predicate SLSA v1 do script của repo dựng, `cosign attest --type slsaprovenance1` định dạng cũ trên digest index ở job `sign`, Kyverno `svp-images` kiểm thêm provenance trên đường GitOps, bật theo bậc sau khi cả bảy service có bản phát hành mang provenance

- Trạng thái: Chấp nhận (người học duyệt 2026-10-28, chọn (a) ở cả ba dòng "Cần người học chọn"); bậc 1 của mục 6 hiện thực
  2026-10-29 (provenance trong `images.yml`, policy và `verify-release.sh` có giá trị bật, mặc định tắt); bậc 2–5 xong 2026-10-29
  đến 2026-10-30: bảy bản phát hành build ở `6ca2d8a` mang provenance (PR promote #36), bật `requireProvenance` ở `envs/stg/`,
  `envs/prd/svp-policy.yaml` của `svp-gitops` ngay từ commit khởi tạo ([ADR-0025](0025-gitops-config-repo.md)), kịch bản `gitops` với
  policy bật đạt cả ca `a` và ca `l` (mục Kiểm chứng sau)
- Ngày: 2026-10-28

## Bối cảnh

- **Yêu cầu** (giai đoạn 6b phần 4): mỗi bản phát hành của bảy image (`gateway`, `user-service`, `video-service`, `media-worker`,
  `engagement-service`, `feed-service`, `web`) có attestation provenance của build, ký keyless như `vuln`; Kyverno `svp-images` kiểm thêm
  provenance (builder, repository, ref) trên đường GitOps; mức SLSA đạt được ghi trung thực.
  [ADR-0015](0015-cicd-devsecops-stage5.md) §7 để SLSA provenance tới giai đoạn 9 (khi đó định dùng `actions/attest-build-provenance`).
- **Hiện trạng** (`.github/workflows/images.yml`, [ADR-0015](0015-cicd-devsecops-stage5.md) §4, §7, §8;
  [ADR-0019](0019-web-k3d-supply-chain-observability.md) cho image `web`):
  - Job `build` (ma trận service × {amd64, arm64}, runner GitHub-hosted `ubuntu-24.04`/`ubuntu-24.04-arm`, quyền `contents: read`,
    `packages: write`, không `id-token`): `deploy/ci/build-image.sh` build `--load --provenance=false --sbom=false` (tắt provenance của
    BuildKit để image là một manifest đơn), quét trivy và syft trên tar, cổng, push, so config digest. Cache chung duy nhất là DB của
    trivy (`actions/cache`, theo ngày), không có cache layer từ xa.
  - Job `merge` ghép index từ đúng hai manifest con. Job `sign` (quyền `contents: read`, `packages: write`, `id-token: write`, không
    cache) chạy `deploy/ci/sign-image.sh`: `cosign sign` trên digest index, `cosign attest --type spdxjson` trên từng manifest con,
    `cosign attest --type vuln` trên digest index; mọi lệnh **định dạng cũ** (`.sig`/`.att`, `--new-bundle-format=false
    --use-signing-config=false`) kèm `--replace`. Lý do (ADR-0015 §7): Kyverno v1.19.1 giữ **một payload mỗi `predicateType`**, cái đọc sau
    cùng thắng; ở định dạng cũ `--replace` thay layer cùng `predicateType` và giữ layer khác, nên `.att` của index luôn có đúng một `vuln`;
    có bất kỳ bundle mới nào trên một digest thì cả `cosign verify` lẫn Kyverno chỉ đọc bundle và bỏ `.sig`/`.att`.
  - Identity ký: issuer `https://token.actions.githubusercontent.com`, subject
    `https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main`, viết một chỗ ở
    `deploy/helm/svp-policy/values.yaml` (`imageVerification.issuer`, `.subject`), `sign_identity` của `deploy/ci/common.sh` đọc lại.
    `ci_builder_id` của `deploy/ci/platform.sh` in đúng chuỗi subject đó trên GitHub (`GITHUB_SERVER_URL` + `GITHUB_WORKFLOW_REF`), `local`
    trên máy ([ADR-0023](0023-ci-platform-neutral.md)).
  - ImageValidatingPolicy `svp-images` (chart `deploy/helm/svp-policy`) kiểm theo thứ tự, dừng ở lỗi đầu: (1) prefix + digest, (2) chữ ký,
    (3) attestation `vuln` cùng identity, (4) đủ hai nền tảng, (5) không CRITICAL, (6) `scanFinishedOn` không quá 72 giờ. Enforce trên
    GitOps (stg, prd), Audit trên dev ([ADR-0024](0024-multi-environment.md)). `deploy/ci/verify-release.sh` (dùng bởi `values-check.sh`
    của lượt PR và `deploy/k8s/gitops.sh`) kiểm cùng điều kiện với ngưỡng tuổi 48 giờ, và đòi **đúng một** attestation `vuln`.
  - Diễn tập `make drill-k8s-supplychain` (`deploy/k8s/drills/supplychain.sh`) có các ca a–i, k; ca c dùng `drill-vulnerable` (ký, có
    `vuln` có CRITICAL), nhờ CRITICAL được kiểm trước tuổi.
- **Ràng buộc:** Actions của repo chỉ cho action của GitHub và `sigstore/cosign-installer`, ghim SHA bắt buộc (ADR-0015 §11); CI trung lập
  nền tảng, mọi ngữ cảnh CI qua hàm `ci_*` (ADR-0023); không thêm công cụ ngoài danh sách đã có (cosign v3.1.3 đã có); repo public, mọi
  attestation ghi công khai trên Rekor.
- **Phát hiện lúc viết (2026-10-28):** Kyverno **v1.19.2** phát hành 2026-10-20, vá 24 advisory (9 Critical, 14 High), trong đó nhóm
  "Image verification and attestation hardening (Critical and High)", và thêm `additionalExtensions` cho keyless của ImageValidatingPolicy
  (kiểm extension GitHub workflow trigger, sha, name, repository, ref của chứng chỉ) [S13]. Repo đang ghim v1.19.1 (chart 3.9.1). Bản sửa
  "extract newest attestation" (PR #18049, merge vào `main` 2026-10-17) **không** có trong danh sách thay đổi của v1.19.2 [S13]: giới hạn
  một payload mỗi loại của ADR-0015 §7 vẫn đứng. Nâng Kyverno là thay đổi riêng (Renovate, ADR-0015 §10), ngoài ADR này; thiết kế dưới đây
  không phụ thuộc v1.19.2.

### SLSA Build track (đặc tả v1.2, bản "Approved" hiện hành)

| Mức | Yêu cầu (dẫn đặc tả) | Nguồn |
| --- | --- | --- |
| Build L1 | Nền tảng build "Automatically generate provenance describing how the artifact was built"; provenance "MUST ... unambiguously identif[y] the output package by cryptographic digest". "Can be used to prevent mistakes but is trivial to bypass or forge." | [S1], [S2] |
| Build L2 | L1, cộng **Hosted**: mọi bước build chạy trên nền tảng build hosted (ví dụ GitHub Actions), không trên máy cá nhân; **Provenance Authentic**: "Consumers MUST be able to validate the authenticity of the provenance attestation", "SHOULD be through a digital signature from a private key accessible only to the build platform component"; về độ chính xác, provenance phải do control plane sinh, không phải tenant, dữ liệu lấy từ chính nền tảng; ngoại lệ: `subject` và các field không bắt buộc ở L2 như `resolvedDependencies` được do tenant sinh. | [S1], [S2] |
| Build L3 | L2, cộng **Provenance Unforgeable**: "Provenance MUST be strongly resistant to forgery by tenants"; khoá hay bí mật dùng để xác thực provenance chỉ service account của build chạm được và "MUST NOT be accessible to the environment running the user-defined build steps"; mọi field do control plane tin cậy sinh hay kiểm; `externalParameters` "MUST be complete". **Isolated**: "It MUST NOT be possible for two builds that overlap in time to influence one another", môi trường mới mỗi lần build, không đầu độc cache dùng chung, build không chạm được bí mật của nền tảng. | [S1], [S2], [S3] |

`builder.id` là "URI indicating the transitive closure of the trusted build platform" và là thứ quyết định mức Build [S3]. Predicate SLSA v1
có `predicateType` `https://slsa.dev/provenance/v1`, gồm `buildDefinition` (`buildType`, `externalParameters`, `internalParameters`,
`resolvedDependencies`) và `runDetails` (`builder.id`, `metadata.invocationId`, `startedOn`, `finishedOn`, `byproducts`) [S3]. GitHub tự
đánh giá: "Artifact attestations by itself provides SLSA v1.0 Build Level 2"; lên L3 cần reusable workflow tách build khỏi workflow gọi [S4].

## Các lựa chọn

### Cách sinh provenance

| Lựa chọn | Trạng thái ngành (2026-10-28) | Mức SLSA Build đạt được với repo này | Kyverno v1.19.1 đọc được cùng digest đã có chữ ký và `vuln` định dạng cũ | `cosign verify-attestation` trên máy | Chạy được trên GitLab sau này |
| --- | --- | --- | --- | --- | --- |
| **A. `cosign attest --type slsaprovenance1`, predicate SLSA v1 do script của repo dựng** (cùng định dạng cũ, cùng identity với `vuln`) | Hiện hành: cosign v3.1.3 nhận `slsaprovenance1`, gắn `predicateType` `https://slsa.dev/provenance/v1`, kiểm có đủ hai khoá `buildDefinition`, `runDetails` rồi đọc bằng protojson bỏ field lạ [S10]. Không phải "công cụ chuẩn của nền tảng" mà là cách tự dựng | **L1**. **Chưa L2**: Hosted đạt (runner GitHub-hosted) và chữ ký xác minh được (chứng chỉ Fulcio cấp từ token OIDC của nền tảng, Kyverno và `verify-release.sh` xác minh), nhưng Authentic về độ chính xác chưa đạt: predicate do **bước của tenant** (script của repo) dựng từ biến môi trường của runner, trái "The provenance MUST be generated by the control plane" của L2 [S2]. Bên kiểm đối chiếu vài field với chứng chỉ (identity = `builder.id`, repository, ref; commit qua extension [S11]) là bảo đảm riêng của chữ ký, không thay yêu cầu đó. **Không L3**: job ký chạy script của repo với `id-token: write` | **Có**: cùng `.att` của index, thêm một layer `predicateType` khác; `--replace` thay đúng layer cùng loại, giữ `vuln` (ADR-0015 §7). Đọc bằng `attestations[].intoto.type` + `extractPayload` như `vuln` [S12] | Có, `--type slsaprovenance1` với `--certificate-identity`, `--certificate-oidc-issuer`; thêm `--certificate-github-workflow-sha` để đối chiếu commit với chứng chỉ [S10] | **Có**: cosign keyless trên gitlab.com với `id_tokens` (ADR-0023, [S15]); `ci_builder_id` đã có nhánh GitLab mô tả sẵn; `buildType` khác (bên dưới) |
| B. `actions/attest` / `actions/attest-build-provenance` (v4.2.2, 2026-08; từ v4 chỉ là wrapper của `actions/attest`) | Hiện hành, đường GitHub khuyến nghị (`slsa-github-generator` cũng trỏ về đây) [S4][S5][S8]. Predicate dựng từ claim của token OIDC: `buildType` `https://actions.github.io/buildtypes/workflow/v1`, `builder.id` = server + `job_workflow_ref` [S6] | **L2** theo đánh giá của GitHub [S4]; không L3 khi gọi trong job của chính workflow build (cùng job có bước của tenant) [S4] | **Không, nếu giữ định dạng cũ**: attestation là Sigstore bundle, lưu ở API attestation của GitHub, đẩy vào registry chỉ khi `push-to-registry` (referrer OCI) [S5]. GHCR không có API referrers (ADR-0015 §7) nên đi tag dự phòng `sha256-<hex>`; có bundle trên digest thì Kyverno và cosign **bỏ** `.sig`/`.att`: chữ ký và `vuln` hiện có mất tác dụng. Đi đường này phải chuyển cả chữ ký và `vuln` sang bundle: mất `--replace`, mỗi lượt rescan thêm một `vuln`, Kyverno đọc một cái bất kỳ (bản sửa #18049 chưa có trong bản phát hành nào [S13]) | `gh attestation verify` (cần `gh`); cosign đọc bundle từ referrer — chưa kiểm trên GHCR | **Không**: action của GitHub, không chạy trên GitHub Enterprise Server [S5] |
| C. `slsa-framework/slsa-github-generator` (reusable workflow `generator_container_slsa3.yml`) | **Không còn bảo trì tích cực** ("no longer actively maintained", bản cuối v2.1.0 ngày 2025-02-24, workflow "should not be assumed to receive updates") [S8] | **L3** về thiết kế: provenance sinh và ký trong reusable workflow tách khỏi job build [S8][S4] | Có về định dạng: generator container ký bằng cosign (định dạng attestation của cosign), predicate **SLSA v0.2** (`https://slsa.dev/provenance/v0.2`) [S8], tức policy kiểm khác v1. Ghi `.att` không `--replace` của repo: chưa kiểm cách nó giữ layer `vuln` | Có (`--type slsaprovenance02`) hay `slsa-verifier` | **Không** (reusable workflow của GitHub). Thêm nữa: ngoài allow list (chỉ action của GitHub và `sigstore/cosign-installer`), và **phải** gọi bằng tag `@vX.Y.Z`, không theo SHA [S8], trái "ghim SHA bắt buộc" của ADR-0015 §11 (cài đặt `sha_pinning_required` có áp cho reusable workflow không: chưa kiểm) |
| D. Provenance của BuildKit (`--provenance=mode=max,version=v1`) | Hiện hành, mặc định `mode=min`, `version=v0.2`; `mode=max` "exposes the values of build arguments" [S9] | **L1**: không ký, nên không có Authentic | **Không** dùng được làm phép kiểm: attestation BuildKit không có chữ ký keyless nào để `verifyAttestationSignatures` xác minh. Còn đổi hình image (manifest attestation trong index), trái ADR-0015 §4 bước 1 (`--provenance=false` để image là một manifest đơn, `--load` vào image store cổ điển) | Không (không có chữ ký để xác minh) | Có (buildx chạy mọi nơi), cùng giới hạn không ký. GitLab Runner tự sinh provenance SLSA v1 (`RUNNER_GENERATE_ARTIFACTS_METADATA`) nhưng cho artifact của job, không cho image, tài liệu không nói có ký [S14] |

### Subject

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Chỉ digest index** | Pod chạy digest index, Kyverno xác minh đúng digest đó, như chữ ký và `vuln`; một attestation mỗi bản phát hành | Công cụ đi theo digest manifest con (ví dụ khi đọc image đã kéo về một nền tảng) không thấy provenance; phải đi qua index (index đã ký, bất biến, liệt kê đúng hai manifest con) |
| Digest index và cả hai manifest con | Tra từ digest nào cũng thấy | Ba attestation, ba lượt ghi Rekor mỗi image; Kyverno không đọc bản trên manifest con; thêm đường để giữ ba cái khớp nhau |

### Nơi attest

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Job `sign` hiện có** | Đã có `id-token: write`, không cache; attest cùng lượt với `vuln`, cùng lệnh, cùng identity; subject là digest index chỉ có sau `merge` | Provenance sinh ở job khác job build: nó mô tả lượt chạy (workflow, commit, run) chứ không đọc được gì bên trong build ngoài artifact của chân |
| Job `build` | Gần build nhất | Phải cấp `id-token: write` cho job có cache (trái ADR-0015 §4, §7: không job nào cầm `id-token` dùng cache); job build theo từng nền tảng, chưa có digest index |

## Quyết định

### 1. Cách sinh: A, `cosign attest --type slsaprovenance1` định dạng cũ, predicate do repo dựng

Chọn A vì là cách duy nhất vừa giữ định dạng cũ mà Kyverno v1.19.1 và `verify-release.sh` đang đọc (không đụng chữ ký, `vuln`, rescan), vừa
không thêm action hay reusable workflow ngoài allow list, vừa mang sang GitLab được; cái giá là chỉ đạt Build L1 (mục 3). B đạt L2 (GitHub
tự xếp) nhưng buộc chuyển cả chuỗi sang bundle khi Kyverno chưa có bản sửa một-payload-mỗi-loại; C đạt L3 nhưng không còn bảo trì,
predicate v0.2, gọi bằng tag; D không ký.

- Script mới `deploy/ci/provenance-predicate.sh OUT` dựng predicate **chỉ** từ hàm `ci_*` của `deploy/ci/platform.sh` (thêm hàm còn thiếu,
  kèm ca trong `platform-test.sh`); `sign-image.sh` gọi nó và attest **sau** `vuln`:
  `cosign attest --yes --new-bundle-format=false --use-signing-config=false --replace --type slsaprovenance1 --predicate <file> <repo>@<digest index>`.
- **Predicate** (hình theo `buildType` GitHub Actions Workflow v1 mà `actions/attest` dùng [S6][S7], để đọc như provenance của GitHub):

  ```json
  {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      "externalParameters": {
        "workflow": {
          "ref": "refs/heads/main",
          "repository": "https://github.com/anhnvcoder/short-video-platform",
          "path": ".github/workflows/images.yml"
        },
        "inputs": {"services": "<chỉ khi lượt dispatch có input services khác rỗng>"}
      },
      "resolvedDependencies": [
        {
          "uri": "git+https://github.com/anhnvcoder/short-video-platform@refs/heads/main",
          "digest": {"gitCommit": "<40 hex của commit được build>"}
        }
      ]
    },
    "runDetails": {
      "builder": {"id": "https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main"},
      "metadata": {"invocationId": "https://github.com/anhnvcoder/short-video-platform/actions/runs/<run_id>/attempts/<attempt>"}
    }
  }
  ```

  - `builder.id` = `ci_builder_id` (trên GitHub trùng subject của chứng chỉ Fulcio của chính job ký). `externalParameters.workflow` lấy từ
    ngữ cảnh CI (repository, ref, đường file workflow); `inputs` chỉ ghi input `services` khác rỗng của lượt dispatch (`buildType` đòi ghi
    input của `workflow_dispatch`, bỏ input rỗng [S7]); chế độ `build` chỉ chạy ở push `main` và dispatch, hai sự kiện `buildType` này nhận
    [S7] (rescan theo lịch không sinh provenance). `images.yml` không dùng `vars`, nên không có khoá `vars`.
  - `resolvedDependencies`: đúng một mục, commit nguồn. `runDetails.metadata.invocationId` = `ci_run_attempt_url`.
  - Không `internalParameters`, `byproducts`, `startedOn`/`finishedOn` (đều tuỳ chọn [S3]): không ai kiểm chúng. Không token, URL có
    credential hay biến môi trường tuỳ ý.
  - Trên máy (`ci_platform` = `local`) script vẫn ra predicate hợp lệ với `builder.id` `local` để test; CI chỉ ký trong job `sign` (identity
    `images.yml@refs/heads/main`), nên predicate `local` không bao giờ được ký. Kyverno và `verify-release.sh` từ chối mọi `builder.id` khác
    subject.
  - GitLab (khi mang sang, ADR-0023): `builder.id` = nhánh GitLab của `ci_builder_id`, `buildType` là một URI riêng của repo mô tả pipeline
    GitLab (chưa có `buildType` chuẩn cho pipeline GitLab: chưa kiểm), `externalParameters` theo biến `CI_*` tương ứng.
- **Kích thước:** vài trăm byte; không đáng kể với Rekor và cache của Kyverno (payload cost, ADR-0015 §8).
- **Image diễn tập không mang provenance** (`drill-sign` không đổi): `drill-vulnerable` vẫn bị từ chối bởi CRITICAL vì phép kiểm provenance
  đứng sau (mục 3), `drill-unsigned` không có gì.
- **Rescan không động tới provenance:** `--replace --type vuln` thay đúng layer `vuln`, giữ layer provenance (ADR-0015 §7). Provenance là sự
  thật của một lần build, không có hạn tuổi.

### 2. Subject: chỉ digest index; attest ở job `sign`

Đúng thứ pod chạy và Kyverno xác minh, một attestation mỗi bản phát hành; giữ quy tắc "không job nào cầm `id-token` dùng cache". Job
`sign` không thêm quyền nào.

### 3. Mức SLSA ghi trung thực

- **Ghi là Build L1.** Không ghi L2 (kể cả "L2 có điều kiện"), không ghi L3, cho tới khi có thiết kế chứng minh mọi field bắt buộc ở L2 do
  nền tảng sinh hay kiểm trong control plane (xem "Việc để lên mức kế"). Phép đối chiếu với chứng chỉ (dưới đây, mục 5) là bảo đảm của chữ
  ký, ghi riêng, không phải bằng chứng cho một mức SLSA.
- **Đạt (L1):** provenance có cho mọi bản phát hành, chỉ đúng digest index. Riêng một yêu cầu của L2 cũng đạt: build và ký chạy trên runner
  GitHub-hosted (Hosted). Môi trường build: mỗi job một VM mới, cache chung chỉ là DB của trivy (đổi kết quả cổng, không đổi byte của
  image), không cache layer từ xa (chưa kiểm hết các điều kiện Isolated của L3).
- **Bảo đảm của chữ ký (ngoài thang SLSA, không nâng mức):** provenance ký keyless, bên dùng (Kyverno, `verify-release.sh`) xác minh được:
  sửa sau khi ký thì lộ, và người ký là identity `images.yml@refs/heads/main`. Chứng chỉ Fulcio, cấp từ token OIDC mà nền tảng ký, ghi Build
  Signer URI, Source Repository Digest (commit), Source Repository Ref, Run Invocation URI, Runner Environment [S11]. Field của predicate mà
  bên kiểm so bằng giá trị đó (`builder.id`, repository, ref ở Kyverno; thêm commit ở `verify-release.sh`, mục 4, 5) không khai khác lượt
  chạy đã ký mà không bị phát hiện. Điều này chỉ nói attestation do một lượt chạy `images.yml` trên `main` ở commit đó ký; không nói image
  được build từ commit đó (subject do bước của repo đưa vào), và các field không so (`inputs`, `invocationId`) chỉ đáng tin bằng script đã
  dựng chúng.
- **Chưa đạt:**
  - L2 (Authentic, độ chính xác): "The provenance MUST be generated by the control plane", dữ liệu lấy từ chính nền tảng [S2]; ở đây
    predicate do script của repo dựng trong một bước của tenant, từ biến môi trường của runner, và chính script đó quyết định nội dung được
    ký. Đối chiếu một phần field ở bên kiểm (bảo đảm của chữ ký ở trên) không thay yêu cầu này. `actions/attest` cũng chạy trong bước của
    tenant nhưng dựng từ claim của token OIDC đã ký, và GitHub tự xếp L2 [S4][S6].
  - L3 (Unforgeable): job `sign` chạy script của repo (`sign-image.sh`, `provenance-predicate.sh` từ checkout của chính commit) với
    `id-token: write`; ai merge được vào `main` thay được script và ký provenance tuỳ ý dưới identity đúng. Bí mật xác thực provenance (token
    OIDC → chứng chỉ) nằm trong môi trường chạy bước do người dùng viết, điều L3 cấm [S2].
  - L3 (`externalParameters` đầy đủ): chưa có phép kiểm chứng minh mọi tham số bên ngoài ảnh hưởng build nằm trong predicate (build arg
    `SVP_BUILD_ID` suy từ commit; version công cụ ghim trong repo).
- **Việc để lên mức kế:**
  - Lên L2: một thiết kế mà mọi field bắt buộc ở L2 do nền tảng sinh hay kiểm trong control plane, kèm lập luận theo từng yêu cầu của [S2]
    trong một ADR (hay bản sửa ADR này) trước khi đổi nhãn. Hai hướng: chuyển sang B khi Kyverno có bản phát hành đọc attestation mới nhất
    mỗi loại (#18049) và đổi cả chữ ký, `vuln` sang bundle một lượt (GitHub tự xếp L2 [S4]); hay dựng predicate từ claim của token OIDC đã
    ký thay vì biến môi trường (cách `actions/attest` làm [S6]): hướng này vẫn chạy trong bước của tenant nên phải chứng minh riêng, không
    mặc nhiên thành L2.
  - Lên L3: chuyển phần sinh và ký provenance vào một reusable workflow ở chỗ repo build không sửa được (repo riêng, nhánh được bảo vệ), job
    build chỉ trao digest; `builder.id` và subject của chứng chỉ thành reusable workflow đó, nên identity của Kyverno và
    `deploy/helm/svp-policy/values.yaml` đổi theo [S4]. Với lab một người, tách repo chỉ chặn thay đổi lọt qua repo build, không chặn chính
    người có quyền ở cả hai repo.

### 4. Kyverno: kiểm provenance trên đường GitOps

- Chart `svp-policy` thêm attestation `provenance` (`intoto.type: https://slsa.dev/provenance/v1`) và các phép kiểm **sau** sáu phép kiểm
  hiện có (message của ca cũ không đổi; ca thiếu provenance chỉ lộ khi image qua mọi phép kiểm khác), mỗi phép một message nêu image bị
  từ chối:
  7. attestation provenance ký bởi đúng identity (`verifyAttestationSignatures(i, attestations.provenance, [attestors.images]) > 0`);
  8. `predicate.runDetails.builder.id` bằng `imageVerification.subject` (cùng một giá trị, viết một chỗ);
  9. `predicate.buildDefinition.externalParameters.workflow.repository` bằng repository của repo
     (`https://github.com/anhnvcoder/short-video-platform`);
  10. `predicate.buildDefinition.externalParameters.workflow.ref` bằng `refs/heads/main`.

  `extractPayload` chỉ sau `verifyAttestationSignatures` của chính attestation đó [S12]. Giá trị mới (repository, ref) vào chuỗi CEL nên
  kiểm ký tự như giá trị hiện có (không nháy, `\`, xuống dòng). Không thêm phép kiểm tuổi cho provenance.
- **Giá trị chart mặc định tắt** (`imageVerification.provenance.enabled: false` hay tên tương đương, chốt lúc hiện thực): tắt thì render giống
  hệt hiện nay. Đường dev (`make k8s-up`, Audit, `install.sh --set`) không đổi.
- **Bật ở cấu hình GitOps** (values của `svp-policy` mà Argo CD dùng cho stg và prd: overlay `deploy/k8s/envs/<env>/` của ADR-0024, từ khi
  tách repo là cây `svp-gitops` của [ADR-0025](0025-gitops-config-repo.md)), không bật trong `values.yaml` của chart.
- Biết trước: các phép 8–10 lặp lại điều identity của chữ ký đã chứng minh (subject đã ghim workflow, repository và ref), nên với Kyverno
  giá trị thêm chủ yếu là **có** provenance đúng identity và **khớp** với chữ ký; đối chiếu commit với chứng chỉ chỉ làm ở
  `verify-release.sh` (commit đổi mỗi bản, policy không có giá trị cố định để so). Kyverno v1.19.2 có `additionalExtensions` [S13] nhưng
  cũng chỉ so với giá trị cố định.
- **Chi phí admission:** mỗi image thêm một lần xác minh attestation khi chưa trúng cache (ADR-0015 §8 đo 6–8 s mỗi lần trên cluster lab,
  webhook `timeoutSeconds: 30`): ba lần xác minh mỗi image, chưa đo.

### 5. `verify-release.sh` kiểm cùng điều kiện, cùng lúc với policy

- `verify-release.sh` đọc trạng thái bật từ **cùng nguồn giá trị** mà Argo CD dùng cho policy ở revision đang kiểm (như identity đọc từ
  `values.yaml` của chart): bật thì kiểm thêm, tắt thì như cũ. Một chỗ ghi, nên `values-check` (lượt PR), `gitops.sh` (trước khi dựng
  cluster) và Kyverno luôn đòi cùng một điều.
- Khi bật: `cosign verify-attestation --type slsaprovenance1` với identity hiện có; **đúng một** attestation provenance (Kyverno giữ một
  payload mỗi loại); `predicateType`, subject = digest, `builder.id`, `workflow.repository`, `workflow.ref` như phép 8–10; `gitCommit` là
  40 hex và **bằng commit trong chứng chỉ** (claim `sha`: `--certificate-github-workflow-sha <commit>` của cosign đọc extension
  1.3.6.1.4.1.57264.1.3, Fulcio ghi là deprecated; hay Source Repository Digest 1.3.6.1.4.1.57264.1.13 [S10][S11]; cách đọc chốt lúc hiện
  thực, phép kiểm phải đỏ khi lệch).

### 6. Triển khai theo bậc

Bản phát hành đang chạy (trước ADR này) không có provenance; bật kiểm trước khi đủ bảy bản mới thì cluster GitOps từ chối pod của service chưa
phát hành lại, và `gitops.sh` dừng trước khi dựng.

1. Merge thay đổi sinh provenance (`images.yml`, `sign-image.sh`, script predicate) cùng policy và `verify-release.sh` **tắt**.
2. Trên `main`: `gh workflow run images.yml --ref main -f services=all` (người học chạy, hay AI khi được giao); merge PR promote cuộn. Bảy
   digest mới trong values.
3. Kiểm bảy digest bằng `verify-release.sh` ở chế độ bật (trên bản sao tạm của giá trị, hay ngay trong PR bật ở bước 4: `values-check` đỏ
   nếu thiếu).
4. PR bật provenance ở cấu hình GitOps; từ đây stg/prd Enforce provenance.
5. Kịch bản `gitops` của `verify.yml` chạy ca mới của diễn tập (mục 7) với policy bật.

Rollback về digest phát hành trước bậc 2 bị Kyverno từ chối khi đã bật: rollback phải trỏ bản có provenance, hay đi qua PR tắt giá trị trước.

### 7. Diễn tập

`make drill-k8s-supplychain` thêm ca (đề xuất tên `l`, biến `SUPPLYCHAIN_NO_PROVENANCE`; tên chốt lúc hiện thực):

- **Ca âm:** một digest phát hành cũ trước provenance (ký, có `vuln` đúng identity, không CRITICAL) bị từ chối **đúng message của phép 7**.
  Ca chỉ PASS khi image qua mọi phép kiểm khác: `vuln` của bản cũ không còn trong values thì rescan hằng ngày không làm mới, nên trong 72 giờ
  trước lượt diễn tập phải dispatch `images.yml -f rescan=true -f values_ref=<commit chứa digest đó>`; quá hạn thì Kyverno từ chối vì tuổi và
  ca FAIL nêu lệnh dispatch. Kịch bản `gitops` tự tìm digest đó trong lịch sử `deploy/k8s/values/services/web.yaml` (bản mới nhất có chữ ký
  mà không có provenance); không tìm được thì SKIP có lý do.
- **Ca nhận:** ca a hiện có (bản phát hành đang chạy) được nhận khi policy bật, nghĩa là provenance của nó qua 7–10.
- Policy ở revision đang dựng tắt provenance thì ca in SKIP nêu "policy tắt".

### Cần người học chọn

Mỗi dòng đề xuất đứng trước (a). Người học duyệt ngày 2026-10-28: chọn (a) ở cả ba dòng.

1. **Cách sinh provenance.** (a) A: cosign `slsaprovenance1` định dạng cũ, predicate do repo dựng. Lý do: không đổi định dạng chữ ký và `vuln`,
   không thêm action, mang sang GitLab được; chỉ đạt Build L1 (mục 3). (b) B: `actions/attest` định dạng bundle: L2 (GitHub tự xếp), công cụ
   chuẩn của GitHub, nhưng phải chuyển chữ ký, SBOM, `vuln` sang bundle một lượt, mất `--replace` (nhiều `vuln` mỗi digest) khi Kyverno chưa
   có bản phát hành chứa #18049, thêm quyền `attestations: write`, `artifact-metadata: write`, chỉ chạy trên GitHub. (c) C:
   `slsa-github-generator`: L3 nhưng không còn bảo trì, predicate v0.2, gọi bằng tag, phải mở allow list. (d) D: provenance BuildKit: L1, không
   ký, không làm phép kiểm của Kyverno được.
2. **Subject.** (a) Chỉ digest index. Lý do: đúng thứ pod chạy và Kyverno kiểm, một attestation mỗi bản. (b) Index và hai manifest con:
   tra được từ digest con, gấp ba số attestation và lượt ghi Rekor.
3. **Cách bật theo bậc.** (a) Giá trị chart mặc định tắt, bật bằng PR ở cấu hình GitOps sau khi bảy service có bản phát hành mang provenance
   (mục 6). Lý do: không lúc nào cluster GitOps từ chối bản đang chạy hợp lệ. (b) Bật ngay cùng merge: ít bước hơn, nhưng từ merge tới khi đủ
   bảy bản mới, `gitops.sh` và `values-check` đỏ, cluster GitOps không dựng được. (c) Policy thứ hai `svp-provenance` ở Audit trước rồi đổi
   Enforce: thấy vi phạm trong PolicyReport trước khi chặn, nhưng thêm một webhook và một lượt xác minh mỗi pod, hai policy phải giữ khớp.

## Kiểm chứng sau

Giả định chưa kiểm được lúc viết; mỗi dòng nêu phép kiểm chứng minh nó; kết quả và ngày ghi vào cột cuối.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| Bảy bản phát hành sau bậc 2 có đúng một attestation provenance đúng identity, đúng predicate | **Kiểm sau push**, trên máy: `cosign verify-attestation --type slsaprovenance1 --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity https://github.com/anhnvcoder/short-video-platform/.github/workflows/images.yml@refs/heads/main ghcr.io/anhnvcoder/short-video-platform/<svc>@<digest>`: một envelope, `predicateType` `https://slsa.dev/provenance/v1`, `builder.id`, `workflow.ref`, 12 hex đầu của `gitCommit` bằng tag image | Đạt: `gitops` [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229) (2026-10-29): `verify-release.sh` qua 7/7 digest của `envs/stg/images/`, mỗi bản đúng một provenance "of 6ca2d8a795dd by …images.yml@refs/heads/main"; trước đó `values-check` của CI PR-A ([40873929718](https://github.com/anhnvcoder/short-video-platform/actions/runs/40873929718)) kiểm cả bảy bản đã ký |
| Commit của predicate trùng commit trong chứng chỉ | Cùng lệnh thêm `--certificate-github-workflow-sha <gitCommit>` (extension 1.3.6.1.4.1.57264.1.3 còn được Fulcio ghi cho GitHub?), và một lệnh với commit khác phải đỏ | Đạt: `verify-release.sh` đối chiếu bằng `--certificate-github-workflow-sha` và qua 7/7 ở [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229). Ca commit khác bị từ chối: kiểm trên máy 2026-10-29 bằng cosign, không có id lượt chạy |
| Thêm provenance không làm mất `vuln`, rescan không làm mất provenance | Sau bậc 2 và sau một lượt rescan: `cosign verify-attestation --type vuln` và `--type slsaprovenance1` mỗi loại đúng một envelope trên cùng digest | Đạt: sau lượt rescan [40937034809](https://github.com/anhnvcoder/short-video-platform/actions/runs/40937034809) (2026-10-29, job `rescan` xanh), [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229) vẫn qua `vuln` và provenance của cả bảy bản; số envelope mỗi loại chưa đếm riêng bằng `cosign verify-attestation` |
| Kyverno v1.19.1 đọc được attestation `slsaprovenance1` định dạng cũ nằm cùng `.att` với `vuln` | Kịch bản `gitops`, policy bật: ca a được nhận, pod `svp` Running | Đạt: [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229): "policy svp-images in Deny, provenance checked: yes", ca a nhận hai lần, pod `svp` của bảy release Running (26/26 Application Healthy) |
| Kyverno từ chối bản thiếu provenance đúng message của phép 7 | Ca mới của `make drill-k8s-supplychain` (kịch bản `gitops`, sau rescan làm mới `vuln` của digest cũ) PASS, không SKIP | Đạt: [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229): ca l với digest web của `34a4bc2` (chưa provenance, `vuln` còn trong 72 giờ) PASS đúng message "image without a provenance attestation signed by …images.yml@refs/heads/main" |
| Admission khi chưa trúng cache vẫn dưới `timeoutSeconds: 30` với ba lần xác minh mỗi image | Thời gian lần đầu của ca a in bởi diễn tập | Một phần: ca a PASS hai lần ở [40954609229](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954609229), nên lần đầu dưới `timeoutSeconds: 30`; thời gian lần đầu chưa trích từ artifact |
| Tắt (mặc định) thì render `svp-policy` và `verify-release.sh` như trước | `helm template` trước và sau, `diff` rỗng; test của `verify-release.sh` | Đạt trên máy 2026-10-29 lúc hiện thực: `diff` render mặc định, `mode=Audit` và bản của ca f trước và sau rỗng; `deploy/ci/platform-test.sh` (gồm `verify-release.sh`, `values-check.sh`, `plan.sh`) xanh |

## Hệ quả

- **Được:**
  - Mỗi bản phát hành mang một attestation ký nêu commit, workflow và lượt chạy đã build nó, đọc bằng `cosign` không cần token; bên kiểm
    đối chiếu được commit với chứng chỉ (bảo đảm của chữ ký, mục 3).
  - Không đổi định dạng hay identity của chữ ký, SBOM, `vuln`; rescan, Kyverno, `verify-release.sh` giữ cơ chế hiện có.
  - Mang sang GitLab chỉ thêm nhánh của hàm `ci_*` và `buildType`.
- **Phải trả:**
  - Mức SLSA chỉ Build L1 (Hosted đạt, Authentic chưa đạt nên chưa L2); không L3. Ai merge được vào `main` (và sửa được script ký) ký
    được provenance tuỳ ý dưới identity đúng, như với `vuln` hiện nay.
  - Một predicate của repo phải giữ đúng đặc tả và `buildType`; thêm một lượt ghi Rekor mỗi bản phát hành.
  - Rollback về bản trước provenance phải tắt kiểm trước. Ca diễn tập mới cần rescan làm mới `vuln` của digest cũ trong 72 giờ trước lượt chạy.
  - Phép kiểm 8–10 của Kyverno phần lớn lặp lại identity của chữ ký.
- **Xem lại khi:**
  - Kyverno có bản phát hành đọc attestation mới nhất mỗi loại (#18049) và repo nâng tới bản đó: xét lựa chọn B, định dạng bundle cho cả chuỗi.
  - Có reusable workflow dùng chung tin cậy được (repo riêng của tổ chức) hay chuyển CI: xét L3 (mục 3).
  - Nâng Kyverno lên v1.19.2 trở đi (bản vá bảo mật, Bối cảnh): xét `additionalExtensions` cho repository, ref.
  - `cosign` bỏ định dạng cũ (cosign v4, ADR-0015 §7): đổi cả chuỗi sang bundle cùng lúc.
- **ADR cũ được chỉnh** (đã ghi "chỉnh bởi 0027" ở trạng thái của chúng và ở `docs/adr/README.md` ngày 2026-10-29):
  - [ADR-0015](0015-cicd-devsecops-stage5.md) §7: dòng "SLSA provenance (`actions/attest-build-provenance`) để giai đoạn 9" thay bằng mục 1,
    2 ở đây (cosign `slsaprovenance1`, định dạng cũ, digest index, job `sign`); `.att` của index chứa `vuln` và provenance.
  - ADR-0015 §8: thứ tự kiểm thêm 7–10 khi giá trị bật (GitOps), đường dev không đổi.

## Hiện thực ở

Hiện thực 2026-10-29 tới bậc 1 của mục 6 (sinh provenance, policy và `verify-release.sh` có giá trị bật, mặc định tắt):

- `deploy/ci/provenance-predicate.sh`: dựng predicate (mục 1) chỉ từ hàm `ci_*`, kiểm commit, repository, giá trị rỗng; lỗi thì
  không ghi file. `deploy/ci/provenance-predicate-test.sh`: test predicate và bước attest của `sign-image.sh` (docker, cosign giả).
- `deploy/ci/platform.sh`, `deploy/ci/platform-test.sh`: `ci_repo_url`, `ci_ref`, `ci_commit`, `ci_workflow_path`, `ci_workflow_ref`,
  `ci_dispatch_input`.
- `deploy/ci/sign-image.sh`: với bản phát hành, `builder.id` phải bằng identity ký, predicate dựng trước khi ký gì, attest
  `--type slsaprovenance1` `--replace` trên digest index sau `vuln`; image diễn tập không provenance. `.github/workflows/images.yml`
  (comment của job `sign`, `drill-sign`), job `config` của `.github/workflows/ci.yml` chạy test mới.
- `deploy/helm/svp-policy/` (`values.yaml`: `imageVerification.requireProvenance`, `provenanceRepository`, `provenanceRef`;
  `templates/imagevalidatingpolicy.yaml`: attestation `provenance`, phép 7–10): mục 4.
- `deploy/ci/common.sh` (`provenance_required`, `provenance_source`, `check_provenance_statement`, `policy_values_paths`,
  `provenance_absent`), `deploy/ci/verify-release.sh` (`--rev`, `--env`, đối chiếu commit bằng `--certificate-github-workflow-sha`),
  `deploy/ci/values-check.sh` (cả bảy khi values hay overlay của `svp-policy` đổi), `deploy/ci/plan.sh` (`values_changed`),
  `deploy/k8s/gitops.sh` (`--rev <revision> --env stg`): mục 5.
- `deploy/k8s/drills/supplychain.sh` (ca `l`, `SUPPLYCHAIN_NO_PROVENANCE`), `deploy/k8s/k8s.mk`, `deploy/ci/verify/gitops.sh`
  (`gitops_no_provenance` tìm bản web thiếu provenance): mục 7.
- Bậc 4: overlay `envs/stg/svp-policy.yaml`, `envs/prd/svp-policy.yaml` của repo `svp-gitops` (`requireProvenance: true`). Từ PR-B
  (tách repo, [ADR-0025](0025-gitops-config-repo.md)): `provenance_required` của `deploy/ci/common.sh` đọc overlay đó trong thư mục cấu
  hình, `deploy/ci/verify-release.sh` thêm `--gitops DIR`, `deploy/ci/values-check.sh` chỉ còn `--gitops` (chạy trong check của
  `svp-gitops`), `deploy/ci/plan.sh` bỏ `values_changed`; `gitops_no_provenance` của `deploy/ci/verify/gitops.sh` vẫn tìm bản web trong
  lịch sử `deploy/k8s/values/services/web.yaml` của repo code, `deploy/ci/rescan.sh` nhận `values_ref` là commit đó.

## Nguồn

Đọc ngày 2026-10-28.

- [S1] SLSA v1.2, "Build: Track Basics" (Build L1, L2, L3: summary, requirements, benefits): <https://slsa.dev/spec/v1.2/build-track-basics>
- [S2] SLSA v1.2, "Build: Requirements for producing artifacts" (Provenance Exists, Authentic, Unforgeable; Hosted; Isolated):
  <https://slsa.dev/spec/v1.2/build-requirements>
- [S3] SLSA v1.2, "Build: Provenance" (`predicateType` `https://slsa.dev/provenance/v1`, `builder.id`, `externalParameters` đầy đủ ở L3):
  <https://slsa.dev/spec/v1.2/build-provenance>
- [S4] GitHub Docs, "Artifact attestations" ("by itself provides SLSA v1.0 Build Level 2", reusable workflow cho L3):
  <https://docs.github.com/en/actions/concepts/security/artifact-attestations>
- [S5] `actions/attest` (v4.2.2, 2026-08-04; `push-to-registry`, quyền, không hỗ trợ GitHub Enterprise Server):
  <https://github.com/actions/attest>; `actions/attest-build-provenance` (v4.2.2, 2026-08-06, từ v4 là wrapper của `actions/attest`):
  <https://github.com/actions/attest-build-provenance>
- [S6] `@actions/attest`, `packages/attest/src/provenance.ts` (`buildType`, `builder.id` = server + `job_workflow_ref`, predicate dựng từ claim
  của token OIDC): <https://github.com/actions/toolkit/blob/main/packages/attest/src/provenance.ts>
- [S7] Build Type "GitHub Actions Workflow" v1 (`externalParameters.workflow`, `inputs`, sự kiện được nhận, `resolvedDependencies`):
  <https://github.com/slsa-framework/github-actions-buildtypes/tree/main/workflow/v1>
- [S8] `slsa-framework/slsa-github-generator` README ("no longer actively maintained", v2.1.0 2025-02-24, gọi bằng tag `@vX.Y.Z`):
  <https://github.com/slsa-framework/slsa-github-generator>; generator container v2.1.0 (predicate `https://slsa.dev/provenance/v0.2`):
  <https://github.com/slsa-framework/slsa-github-generator/blob/v2.1.0/internal/builders/container/README.md>
- [S9] Docker Docs, "Provenance attestations" (`mode=min|max`, `version=v0.2|v1`, `mode=max` lộ build arg):
  <https://docs.docker.com/build/metadata/attestations/slsa-provenance/>
- [S10] cosign v3.1.3, `pkg/cosign/attestation/attestation.go` (`slsaprovenance1`, khoá bắt buộc, protojson bỏ field lạ):
  <https://github.com/sigstore/cosign/blob/v3.1.3/pkg/cosign/attestation/attestation.go>; `doc/cosign_verify-attestation.md`
  (`--type`, `--certificate-github-workflow-*`): <https://github.com/sigstore/cosign/blob/v3.1.3/doc/cosign_verify-attestation.md>
- [S11] Fulcio, "OID information" (1.3.6.1.4.1.57264.1.3 GitHub Workflow SHA deprecated; .9 Build Signer URI; .11 Runner Environment; .13
  Source Repository Digest; .14 Source Repository Ref; .21 Run Invocation URI): <https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md>
- [S12] Kyverno, "ImageValidatingPolicy" (Stable, v1.19; `attestations[].intoto.type`, `verifyAttestationSignatures`, `extractPayload`
  cần xác minh trước; keyless `identities`): <https://kyverno.io/docs/policy-types/image-validating-policy/>
- [S13] Kyverno v1.19.2 release notes (2026-10-20; 24 advisory; #17814 `additionalExtensions`; không có #18049):
  <https://github.com/kyverno/kyverno/releases/tag/v1.19.2>; PR #18049 "extract newest attestation for ImageValidatingPolicy" (merge vào
  `main` 2026-10-17): <https://github.com/kyverno/kyverno/pull/18049>
- [S14] GitLab Docs, "Configuring runners", mục artifact provenance metadata (`RUNNER_GENERATE_ARTIFACTS_METADATA`, SLSA v1 cho artifact
  của job): <https://docs.gitlab.com/ci/runners/configure_runners/#artifact-provenance-metadata>
- [S15] GitLab Docs, "Use Sigstore for keyless signing" (`id_tokens`, `aud: sigstore`): <https://docs.gitlab.com/ci/yaml/signing_examples/>
