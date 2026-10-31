# 0036. Đổi tên repo `short-video-platform` → `svp-backend`, `svp-web` → `svp-frontend`: image chuyển sang prefix mới mang tên repo; bảng nguồn của lượt chuyển giữ hai nguồn cũ ở dạng nghỉ hưu (được nhận, không ai phát hành) để stg, prd đi qua bằng PR bot như mọi bản phát hành, rồi gỡ khi prd chạy bộ bản mới

- Trạng thái: Chấp nhận (2026-10-31); chưa hiện thực: PR đổi tên ở backend, `svp-gitops`, `svp-frontend` chưa merge (mục Hiện thực ở,
  Kết quả)
- Ngày: 2026-10-31

## Bối cảnh

- **Việc đã xảy ra.** Ngày 2026-10-31 người học đổi tên hai repo trên GitHub: `anhnvcoder/short-video-platform` (trong ADR này gọi là
  **backend**) thành `anhnvcoder/svp-backend`, `anhnvcoder/svp-web` thành `anhnvcoder/svp-frontend`. `svp-gitops`, `svp-infra`, `svp-labs`
  giữ tên; thư mục workspace `labs/short-video-platform/` và hai bản clone `backend/`, `frontend/` giữ tên. Lượt `images.yml` cuối dưới tên
  cũ: backend [41182755096](https://github.com/anhnvcoder/svp-backend/actions/runs/41182755096) (commit `c049c1b`, 07:59–08:09 UTC, sáu
  image lên stg ở PR [#32](https://github.com/anhnvcoder/svp-gitops/pull/32) của `svp-gitops`), frontend
  [41186290234](https://github.com/anhnvcoder/svp-frontend/actions/runs/41186290234) (commit `2d78ad1`, 08:51–08:57 UTC, web lên stg ở PR
  [#34](https://github.com/anhnvcoder/svp-gitops/pull/34)); cả hai PR qua check `gitops-ok` ở checker `c049c1b`, chỉ nhận identity cũ.
- **GitHub sau khi đổi tên** [W1]: web và `git clone`, `git fetch`, `git push` theo tên cũ được chuyển sang tên mới; action của repo đổi
  tên thì không ("will fail with the error `repository not found`"): không workflow nào `uses:` action hay reusable workflow của hai repo
  ([ADR-0033](0033-svp-web-repo.md) §5 chọn checkout ở commit ghim), nên điều này không chạm gì. Tạo repo mới trùng tên cũ thì "redirects
  to the renamed repository will no longer work". Trang không nói về REST API hay GitHub Packages.
- **Identity ký mang tên repo.** SAN của chứng chỉ Fulcio là `server_url` + `job_workflow_ref` (ADR-0033, Bối cảnh), claim
  `workflow_ref`, `job_workflow_ref` có dạng `owner/repo/.github/workflows/…@ref` [W3]. Từ lúc đổi tên, mọi lượt `images.yml` ký bằng
  `https://github.com/anhnvcoder/svp-backend/.github/workflows/images.yml@refs/heads/main` (frontend tương tự) và provenance nêu
  `workflow.repository` mới. Không CI nào ký hay attest được identity cũ nữa.
- **Bảng nguồn còn tên cũ.** `deploy/helm/svp-policy/files/sources.json` ở `main` có hai nguồn, `backend` (`repository`, `imagePrefix`,
  `subject` của `short-video-platform`) và `web` (của `svp-web`). `use_build_source` của `deploy/ci/common.sh` chọn nguồn có `repository`
  bằng `ci_repo_url` (tên hiện tại), nên lượt `images.yml` của cả hai repo không tìm ra nguồn của mình và không build, ký gì (fail-closed);
  policy `svp-images`, `verify-release.sh` và check `svp-gitops` từ chối identity mới.
- **Bảng đọc theo `revision` của env** (ADR-0033 §2, §3): Kyverno của một env áp chart `svp-policy` ở `revision` của
  `envs/<env>/charts.yaml`; `verify-release.sh --gitops`, `gitops-check.sh` đọc bảng ở đúng revision đó. Hiện stg ở `c049c1b`, prd ở
  `f6bbc0e`, cả hai bảng hai nguồn tên cũ; cả hai env chạy sáu bản `ghcr.io/anhnvcoder/short-video-platform/<svc>` và web
  `ghcr.io/anhnvcoder/svp-web/web` (stg từ 2026-10-30, PR [#22](https://github.com/anhnvcoder/svp-gitops/pull/22); prd từ 2026-10-31, PR
  [#29](https://github.com/anhnvcoder/svp-gitops/pull/29), merge `86d33bd`).
- **Hai repo phát hành độc lập** (ADR-0033 §4): backend promote stg (sáu file image và `charts.yaml`) trước; frontend chỉ build được khi
  `.backend-commit` của nó trỏ commit có nguồn `web` mới, nên web tới stg sau. Giữa hai PR bot, stg ở `revision` mới chạy sáu bản identity
  mới và web identity cũ: bảng ở revision đó phải nhận cả hai.
- **Luật của bảng hôm nay** (`_release_sources_jq` của `deploy/k8s/lib.sh` và template của chart, viết hai nơi, `deploy/ci/sources-test.sh`
  giữ hai nơi khớp): prefix không trùng, không là đầu của prefix khác (policy chọn attestor theo prefix); một service ở tối đa hai nguồn;
  mọi nguồn có `promoter`, không hai nguồn chung một `promoter` (luật tác giả PR của check biết bot thuộc nguồn nào qua đó).
- **Đồng hồ:** `values-check.sh --gitops` (check `svp-gitops`, `make k8s-gitops-up`) đòi attestation `vuln` không quá 48 giờ; Kyverno
  `maxAttestationAge: 72h`. Attestation của bản cũ chỉ còn già đi.
- **Ràng buộc:** không nới chính sách (một prefix một identity, Enforce, provenance); CI/CD một đường thẳng, không nhánh `if` theo chế độ,
  tương thích ngược tối đa một bản (người học, 2026-10-31); không xoá package cũ; mọi đổi chart, nguồn đi stg trước prd.

## Các lựa chọn

### 1. Prefix image

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Prefix mới theo tên repo: `ghcr.io/anhnvcoder/svp-backend/`, `ghcr.io/anhnvcoder/svp-frontend/`** | Tên package khớp repo; nguồn mới và nguồn cũ có prefix riêng nên policy chọn attestor như nay, không đổi schema; bản đang chạy giữ identity và provenance của nó dưới nguồn cũ | 12 package mới (backend: sáu service, `api/gateway`, ba image diễn tập; frontend: `web`, `web-sourcemaps`), mặc định private và không kế thừa visibility của repo [W2]: người học bật public từng cái |
| B. Giữ prefix cũ, đổi `repository`, `subject` của nguồn tại chỗ | Không package mới | Một prefix một attestor (bảng cấm prefix trùng): mọi bản đang chạy ở stg, prd và mọi rollback ký identity cũ bị từ chối ngay ở chart đó; provenance của bản cũ nêu repo cũ nên phép provenance cũng từ chối; tên package không còn khớp repo |
| C. Giữ prefix cũ, một nguồn nhiều identity (danh sách `subject`) | Không package mới; bản cũ vẫn được nhận | Đổi schema của bảng, CEL của policy, `sign_identity`, `provenance_source`, `verify-release.sh`, rescan, check; một prefix nhận nhiều identity là nới chính sách theo một trục mới, phải tự thu lại về sau |
| D. Identity theo id bất biến của repo (claim `repository_id` [W3]) thay tên | Đổi tên sau này không đổi identity | Policy và `cosign verify --certificate-identity` so SAN, là đường workflow có tên repo; chứng chỉ có mang id repo và Kyverno khớp được theo nó hay không: chưa đọc tài liệu; mọi script đổi; provenance vẫn nêu tên |

### 2. Lượt chuyển của bảng nguồn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Bảng chuyển bốn nguồn: hai nguồn mới và hai nguồn cũ nghỉ hưu (đúng giá trị cũ, không `promoter`)** | Stg, prd đi qua bằng PR bot và PR prd như mọi bản phát hành; lúc nào bảng ở revision của env cũng nhận đúng các bản env chạy; dùng lại cơ chế một service hai nguồn của ADR-0033 | `promoter` thành tuỳ chọn ở hai nơi viết luật; luật tác giả PR và `promote.sh` thêm tiếp quản từ nguồn nghỉ hưu, gỡ ở PR sau |
| B. Đổi tại chỗ, bảng hai nguồn tên mới; một PR của người thay cả bảy file stg khi hai repo đã có bản mới | Không nguồn nghỉ hưu, không luật tiếp quản | Từ lúc PR backend merge tới PR tay, PR bot nào của stg cũng đỏ (PR của backend đưa stg lên bảng không còn nhận web cũ; PR của web ở `revision` cũ không thấy prefix mới); cắt một lần bằng tay; không lùi về bản cũ được ngay sau merge |
| C. Như A nhưng hai nguồn cũ giữ `promoter` | Không đổi schema | Hai nguồn chung một `promoter`: bảng bị từ chối, và bot không còn thuộc đúng một nguồn |

### 3. Ca (l) của `drill-k8s-supplychain`

Ca (l) cần một bản đã ký, có `vuln` còn hạn, không provenance, dưới prefix được nhận. Sau đổi tên không còn bản phát hành nào như vậy: mọi
bản dưới prefix mới có provenance; bản không provenance (web của backend trước ADR-0027) chỉ còn dưới prefix cũ, không rescan được bằng
identity cũ và `oldbackend` không còn `web` (mục 3 của Quyết định).

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Image diễn tập thứ ba `drill-no-provenance`: bản sạch như `drill-unsigned`, ký và attest `vuln` như bản phát hành, không provenance** | Phép provenance vẫn được chứng minh dưới Enforce ở mỗi lượt `gitops`; không dựa vào bản phát hành cũ | Thêm một image diễn tập, một package |
| B. Ca (l) SKIP có lý do | Ít việc | Mất bằng chứng phép provenance trên cluster |

## Quyết định

Chọn 1A, 2A, 3A (3A chọn ở mốc duyệt kế hoạch, 2026-10-31). Lý do chung: giữ nguyên mọi phép kiểm (một prefix một identity, provenance theo
repo của nguồn) và đi qua bằng đúng đường phát hành đang có; phần riêng của lượt chuyển chỉ là dữ liệu (hai nguồn nghỉ hưu) và một luật
tiếp quản, gỡ ở bản sau.

### 1. Vì sao phải có lượt chuyển

- Subject keyless của `images.yml` mang tên repo nên đổi theo tên (Bối cảnh); không thể ký lại bản cũ bằng identity mới hay ngược lại.
- Kyverno, `verify-release.sh` và check `svp-gitops` kiểm theo bảng ở `revision` của env, và revision của stg, prd chỉ đổi qua PR promote.
- Stg sẽ có lúc lẫn bản identity cũ và mới (backend promote trước, web sau, mục 4); prd lẫn tên cũ tới khi PR promote prd thay cả bảy.
- Vậy bảng của commit đưa vào stg phải nhận cả bản cũ đang chạy lẫn bản mới sắp tới, và chỉ bỏ bản cũ khi không env nào còn chạy nó.

### 2. Prefix image mới

- Nguồn `backend`: `ghcr.io/anhnvcoder/svp-backend/` (sáu service Go, ba image diễn tập, hợp đồng `api/gateway`); nguồn `web`:
  `ghcr.io/anhnvcoder/svp-frontend/` (`web`, `web-sourcemaps`). Không giữ prefix cũ cho bản mới (lựa chọn 1B, 1C ở trên).
- Hợp đồng API phát hành lại dưới `ghcr.io/anhnvcoder/svp-backend/api/gateway:<version>` (cùng version, ký identity backend mới), vì
  `make generate` của `svp-frontend` kiểm chữ ký hợp đồng bằng identity của nguồn `backend` đọc từ bảng ở `.backend-commit`.
- Người học bật public 12 package mới (mặc định private, không kế thừa visibility; public rồi không đổi lại private được [W2]); check
  `svp-gitops` và Kyverno kéo manifest ẩn danh nên package phải public trước khi PR bot của nó được kiểm. Package cũ giữ nguyên, không xoá:
  bản ghi stg cũ và lịch sử trỏ tới chúng.

### 3. Nguồn nghỉ hưu

- Bảng của bản chuyển (commit merge của PR đổi tên ở backend, gọi là **T**); mọi nguồn có `issuer` `https://token.actions.githubusercontent.com`,
  `provenanceRef` `refs/heads/main`, `subject` là `<repository>/.github/workflows/images.yml@refs/heads/main`:

  | `name` | `repository` | `imagePrefix` | `services` | `drillImages` | `promoter` |
  | --- | --- | --- | --- | --- | --- |
  | `backend` | `https://github.com/anhnvcoder/svp-backend` | `ghcr.io/anhnvcoder/svp-backend/` | sáu service Go | `drill-vulnerable`, `drill-unsigned`, `drill-no-provenance` | `svp-gitops-promoter` |
  | `web` | `https://github.com/anhnvcoder/svp-frontend` | `ghcr.io/anhnvcoder/svp-frontend/` | `web` | — | `svp-web-promoter` |
  | `oldbackend` | `https://github.com/anhnvcoder/short-video-platform` | `ghcr.io/anhnvcoder/short-video-platform/` | sáu service Go | — | — |
  | `oldweb` | `https://github.com/anhnvcoder/svp-web` | `ghcr.io/anhnvcoder/svp-web/` | `web` | — | — |

- **Nguồn không `promoter` là nguồn nghỉ hưu.** Policy, `verify-release.sh`, check nhận bản của nó như mọi nguồn (chữ ký, `vuln`,
  provenance theo identity cũ). Không lượt CI nào là của nó (`ci_repo_url` luôn là tên mới); hàm nào cần `promoter` (`promote.sh --source`,
  `rescan.sh --source`) từ chối nó với message nêu tên nguồn; rescan bỏ file của nó khỏi tập bằng một dòng, không đỏ. Attestation của nó
  không được làm mới nên bản của nó tự hết hạn (mục 5). Không bot nào là bot của nguồn nghỉ hưu.
- Mọi luật khác của bảng giữ: một service tối đa hai nguồn; `promoter` không trùng giữa các nguồn có `promoter`; prefix không trùng, không
  lồng. Sửa cùng lúc hai nơi viết luật (`_release_sources_jq`, template), `sources-test.sh` đưa ca mới qua cả hai.
- **`oldbackend` bỏ `web`:** web đã ở `web` và `oldweb`, thêm nữa là ba nguồn. Không env nào chạy `short-video-platform/web` (stg từ PR #22,
  prd từ PR #29 chạy web của `svp-web`), tức điều kiện gỡ nguồn web cũ của ADR-0033 §2 đã đạt: bảng chuyển cũng là bước 8 (PR-3) của
  ADR-0033 §9. Rollback web về `short-video-platform/web` bị phép 1 từ chối từ T.
- **Tiếp quản.** Luật tác giả PR (bước 1c của `gitops-check.sh`): bot của nguồn N được thay image của service `svc` khi image trước là bản
  của N, của `backend` (nguồn giữ chart) hay **của một nguồn nghỉ hưu có `svc`**; image sau vẫn phải là bản của N, nên bot không bao giờ đưa
  service về nguồn nghỉ hưu. `promote.sh`: file trên `main` của `svp-gitops` mà chủ là nguồn nghỉ hưu có service đó thì lượt của nguồn đang
  phát hành service đó tiếp quản (dòng `takeover` nêu nguồn cũ, câu đầu comment thành câu của nguồn mới), ở chế độ backend (có
  `charts.yaml`, vẫn kiểm image không mới hơn `revision`) và ở `--source web`; file của một nguồn **đang hoạt động** khác vẫn để nguyên như
  ADR-0033 §4. `promote-prd.sh` chép cả bộ của một bản ghi stg nên không cần luật này.
- **Check `svp-gitops` không trỏ bản clone repo nguồn nào nữa** (bỏ `SVP_SOURCE_DIR_*` và bước checkout repo web của `check.yml`): bảng ở
  revision cũ có `web` là URL `svp-web`, bảng ở T có `web` là URL `svp-frontend` và `oldweb` là URL `svp-web`, tức một repo dưới hai URL;
  `source_clone` so origin của bản clone với `repository` nguyên văn, nên một bản clone không khớp được cả hai. Không đặt biến thì check clone
  ẩn danh, blob-less từng URL; URL cũ đi theo chuyển hướng của GitHub [W1]. Đặt biến bằng tay trên máy thì vẫn so nguyên văn như cũ.
- Bản của `oldbackend` kiểm như nguồn khác `backend`: tag là commit trên `main` của repo nguồn (clone theo URL cũ), không theo luật tổ tiên
  với `revision` (luật đó chỉ cho nguồn giữ chart, tên `backend` cố định trong check). Đó là đúng các bản đang chạy, dựng trước T.

### 4. Trình tự và mốc

1. **PR backend** (bảng bốn nguồn, `promoter` tuỳ chọn, script theo bảng mới, mọi tên, Go module, image diễn tập `drill-no-provenance`)
   merge, thành T. Lượt `images.yml` push ở T build và ký sáu image và hợp đồng dưới prefix mới bằng identity mới; job `promote` mở PR
   `bot/promote-stg` (sáu file từ `oldbackend` sang `backend`, `charts.yaml` lên T). Check của PR này còn chạy checker cũ (`c049c1b`), không
   đọc được bảng có nguồn không `promoter`, nên đỏ: dự kiến.
2. **PR `svp-gitops`:** `CHECKER_COMMIT` = T, checkout repo code `anhnvcoder/svp-backend`, bỏ checkout repo web và `SVP_SOURCE_DIR_WEB`,
   `chartRepoURL`, `sourceRepos` theo tên mới; merge (người học, `gitops-ok` xanh). Checker T đọc cả bảng cũ (stg, prd) lẫn bảng T. Phải
   merge **trước** khi PR bot của bước 1 được kiểm lại.
3. Người học bật public bảy package `svp-backend/{gateway, user-service, video-service, engagement-service, feed-service, media-worker,
   api/gateway}`.
4. Chạy lại job `promote` của lượt `images.yml` ở T (đẩy lại nhánh bot, lượt check mới với checker T): PR bot có dòng tiếp quản từ
   `oldbackend`, tự merge khi `gitops-ok` xanh. Stg ở T: sáu bản mới và web `oldweb`. Dispatch `images.yml -f drill=true` (ba image diễn
   tập), người học bật public ba package đó.
5. **PR `svp-frontend`:** `.backend-commit` = T, `api/contract.json` trỏ hợp đồng dưới `svp-backend/api/gateway` (version như cũ, digest đọc
   lại từ registry); merge. Lượt `images.yml` của frontend đẩy `web`, `web-sourcemaps` dưới `svp-frontend/`; người học bật public hai package;
   PR `bot/promote-stg-web` tiếp quản `web.yaml` từ `oldweb`, tự merge. Stg đủ bảy bản mới.
6. `verify.yml` kịch bản `gitops` trên `main`: Enforce nhận bảy bản mới, mọi ca của `drill-k8s-supplychain`, job `record-stg` ghi bản ghi stg.
7. Promote prd bản ghi đó (`images.yml -f promote_prd=true`; người học duyệt PR prd).
8. **PR backend gỡ** `oldbackend`, `oldweb` và luật tiếp quản từ nguồn nghỉ hưu (tương thích ngược tối đa một bản); chỉ mở khi mọi file
   `envs/stg/images/`, `envs/prd/images/` trên `main` của `svp-gitops` đã dưới hai prefix mới. Giữ việc đọc được bảng có nguồn không
   `promoter` (`_release_sources_jq`, template) tới khi không env nào còn ở commit có nó: prd ở T tới lần promote prd sau bước 8. Giữ phần
   đọc lịch sử dưới tên cũ (mục 8).
9. Nâng `CHECKER_COMMIT` lên commit merge của bước 8 (mục 9).

Cách lùi:

- Trước bước 4: không env nào đổi; bảng T nhận cả bản cũ. Revert PR backend không đưa CI về được (dưới tên mới, bảng cũ không có nguồn nào
  khớp repo), nên lùi là sửa tiếp.
- Sau bước 4, 5, bản mới hỏng ở stg: PR của người học trả file đó về digest cũ (`oldbackend`, `oldweb` vẫn được nhận ở T), chỉ trong hạn 48
  giờ của attestation cũ (mục 5); quá hạn thì chỉ còn sửa tiến bằng bản mới hơn.
- Sau bước 8: bản trước đổi tên bị phép 1 từ chối (prefix không thuộc nguồn nào); revert bước 8 không giúp gì sau 72 giờ.

### 5. Đồng hồ attestation

- Attestation `vuln` cuối của các bản identity cũ (khung thời gian của lượt chạy; không đọc `scanFinishedOn` của từng bản):
  - stg, sáu bản backend `c049c1bc8089`: build [41182755096](https://github.com/anhnvcoder/svp-backend/actions/runs/41182755096),
    2026-10-31 07:59–08:09 UTC; web `2d78ad129f14`: build [41186290234](https://github.com/anhnvcoder/svp-frontend/actions/runs/41186290234),
    08:51–08:57 UTC (bản cuối ký bằng identity cũ);
  - prd, bảy bản của bản ghi stg `7455657881`: rescan theo lịch của backend
    [41178810691](https://github.com/anhnvcoder/svp-backend/actions/runs/41178810691) 07:00–07:03 UTC và của frontend
    [41180818852](https://github.com/anhnvcoder/svp-frontend/actions/runs/41180818852) 07:29–07:31 UTC.
- PR bot stg của backend (bước 4) để lại đúng một bản cũ ở stg, web `oldweb`, và check của nó chạy `values-check` trên cả bảy file stg
  (48 giờ): hạn thật khoảng 2026-11-02 08:51 UTC. **Mốc vận hành: PR đó merge trước 2026-11-02 07:00 UTC** (48 giờ sau rescan sớm nhất, sớm
  hơn mọi hạn thật, không phải tính từng bản). PR bot web (bước 5) thay bản cũ cuối của stg nên không có hạn này; prd không có hạn trước
  bước 7 vì PR promote prd thay cả bảy.
- Trễ mốc: PR bot của backend đỏ vì web cũ quá 48 giờ, PR bot của web cũng đỏ (stg còn ở `revision` cũ, bảng cũ không có prefix
  `svp-frontend/`). Đường lùi: khi frontend đã có bản mới, người học mở một PR thay cả bảy file stg và `charts.yaml` (T) cùng lúc; PR của
  người không bị luật tác giả giới hạn, check vẫn kiểm từng bản.
- Lượt lịch `verify.yml` kế tiếp (thứ Bảy 2026-11-07 00:37 UTC, có kịch bản `gitops`) dựng stg từ `main` của `svp-gitops`: tới lúc đó stg phải
  đủ bảy bản mới, không thì `k8s-gitops-up` dừng ở `values-check`.
- Rollback về bản trước đổi tên: check từ chối sau 48 giờ, Kyverno sau 72 giờ tính từ attestation cuối của bản đó; muộn nhất từ khoảng
  2026-11-03 08:57 UTC không bản identity cũ nào qua được check hay Kyverno Enforce, kể cả trước bước 8.

### 6. Ca (l) của `drill-k8s-supplychain`

- `images.yml -f drill=true` dựng ba image diễn tập dưới prefix của `backend`: `drill-vulnerable`, `drill-unsigned` như cũ và
  `drill-no-provenance` (bản build sạch như `drill-unsigned`, ký và attest `vuln` như bản phát hành, **không** attest provenance;
  `--allow-critical` vẫn chỉ cho `drill-vulnerable`). `drillImages` của `backend` và `drill_images` của `common.sh` thêm tên đó. Rescan hằng
  ngày không đụng image diễn tập (không ở `envs/`).
- `supplychain.sh` ca (l): mặc định `<imagePrefix của backend>drill-no-provenance@<digest>` (`SUPPLYCHAIN_NO_PROVENANCE` vẫn ghi đè); bỏ đường
  tìm bản web cũ qua lịch sử `deploy/k8s/values/services/` và lệnh rescan `values_ref` của nó. Script vẫn kiểm trước khi gửi pod (chữ ký,
  đúng một `vuln` hai nền tảng không CRITICAL còn hạn, không provenance), thiếu một điều thì FAIL kèm lệnh dispatch `drill=true`.
- Kịch bản `gitops` của `verify.yml` lấy digest `drill-no-provenance` mới nhất như ca (c) lấy `drill-vulnerable`, cùng luật: lượt lịch mà
  attestation quá 72 giờ thì ca SKIP kèm dòng `NOTE`.
- Ca (m) chạy với bốn nguồn; cặp có nguồn nghỉ hưu mà không pod nào chạy bản của nó thì SKIP có lý do.

### 7. Giữ và đổi

- **Đổi:** `anhnvcoder/short-video-platform` → `anhnvcoder/svp-backend`, `anhnvcoder/svp-web` → `anhnvcoder/svp-frontend` ở URL,
  `owner/name`, checkout, clone, `depName` của Renovate, link `…/blob/main/…` (cả `runbook_url` của rule cảnh báo); prefix image như mục 2
  (cả `api/gateway`, `web-sourcemaps`); thư mục clone của CI `.web/svp-web` → `.web/svp-frontend`; chữ `svp-web` khi nói về repo →
  `svp-frontend`; Go module `github.com/anhnvcoder/short-video-platform` → `github.com/anhnvcoder/svp-backend`: module path là tên repo, và
  không repo nào khác import module này (đã tìm trong `frontend/`, `infra/`, `labs/`).
- **Giữ:** thư mục workspace `labs/short-video-platform/`; tên nguồn `backend`, `web` và service `web`; GitHub App `svp-gitops-promoter`,
  `svp-web-promoter` và nhánh bot `bot/promote-stg`, `bot/promote-stg-web`; tên thành phần lúc chạy (meter OTel `svp-web`, dashboard Grafana,
  project GlitchTip `svp`); repo `svp-gitops`, `svp-infra`, `svp-labs`; nội dung lịch sử (Bối cảnh và Quyết định của ADR cũ, postmortem,
  `plans/`); hai nguồn nghỉ hưu `oldbackend`, `oldweb` (URL, prefix, subject cũ) và fixture test mô tả commit hay bản ghi trước đổi tên.

### 8. Đọc lịch sử dưới tên cũ là lâu dài, không phải phần chuyển tiếp

- Bản ghi stg trước đổi tên (Deployment trên `svp-gitops`, [ADR-0028](0028-dora-metrics.md)) có `run_url` dưới
  `https://github.com/anhnvcoder/short-video-platform/actions/runs/…` và image dưới prefix cũ; chúng còn trong cửa sổ của `dora.yml` (mặc định
  30 ngày, `days` tới 3650).
- Tên cũ của repo code khai **một chỗ, dạng dữ liệu** trong adapter CI (`deploy/ci/platform.sh`): `ci_is_run_url`, `ci_run_workflow` nhận
  `run_url` dưới tên cũ; mọi lời gọi API đọc lượt bằng tên hiện tại của repo và id của lượt (không dựa vào chuyển hướng của API, điều tài liệu
  đổi tên không nói [W1]). Cùng hàm phục vụ `release-set.sh` (promote prd) và phép kiểm bản ghi của `gitops-check.sh`.
- `dora.sh` gán nguồn cho image của mỗi bản ghi theo bảng ở `charts.revision` của chính bản ghi (`release_sources REV`, đọc được cả commit
  trước bảng), không theo bảng của working tree; gom commit theo **repo**, tên cũ quy về tên hiện tại qua cùng dữ liệu (bản checkout này cho
  backend, `web_dir` cho web); `--clones` in `web` khi có bản build từ repo `svp-frontend` dưới bất kỳ tên nguồn nào. Nên bước 8 không làm
  `dora.yml` đỏ, và lần triển khai đầu sau đổi tên không tính lại cả lịch sử là thay đổi mới.

### 9. Sau khi gỡ

- Ngay khi PR gỡ (bước 8) merge, người điều phối mở PR một dòng ở `svp-gitops` nâng `CHECKER_COMMIT` lên commit merge đó, merge khi
  `gitops-ok` xanh; không chờ Renovate (lịch sáng thứ Bảy và `minimumReleaseAge` 3 ngày). Checker còn ở T thì check vẫn giữ luật tiếp quản
  từ nguồn nghỉ hưu.
- Checker mới vẫn phải đọc được bảng bốn nguồn khi prd còn ở T (mục 4, bước 8).

### 10. Không dùng lại hai tên cũ

Không tạo repo nào tên `short-video-platform` hay `svp-web` dưới `anhnvcoder`, kể cả sau khi gỡ nguồn nghỉ hưu:

- GitHub thôi chuyển hướng tên cũ khi tên đó được dùng lại [W1], mà check `svp-gitops` clone theo URL cũ của bảng ở revision cũ (prd ở
  `f6bbc0e` tới bước 7, rollback, bản ghi stg cũ).
- Repo mới mang tên cũ có `images.yml` ký được đúng subject cũ: bảng ở mọi revision trước bước 8 (gồm T và mọi commit trước đổi tên) nhận
  identity đó, nên một rollback trỏ về revision như vậy sẽ nhận chữ ký của repo lạ.
- `ci_is_run_url` nhận `run_url` dưới tên cũ (mục 8): lượt chạy của repo mới cùng tên sẽ qua phép kiểm đường lượt chạy của bản ghi.

## Hệ quả

- **Được:**
  - Tên package khớp tên repo; mỗi nguồn vẫn một prefix, một identity, một credential như ADR-0033.
  - Đi qua bằng PR bot và PR prd như mọi bản phát hành, không cắt tay, không lúc nào bảng của env từ chối bản env đang chạy.
  - Phần riêng của lượt chuyển là dữ liệu (hai nguồn không `promoter`) và một luật tiếp quản, không nhánh theo chế độ; gỡ ở bản sau.
- **Phải trả:**
  - 12 package mới bật public tay, theo thứ tự của mục 4; package cũ ở lại.
  - Một bản (T) mang luật tiếp quản từ nguồn nghỉ hưu; việc đọc bảng có nguồn không `promoter` giữ tới khi không env nào còn ở T.
  - Hạn 48 giờ của mục 5 nằm trên đường găng; trễ thì một PR tay.
  - Từ lúc đổi tên tới khi PR của mỗi repo merge, `images.yml` của repo đó không build, ký gì; `make web-*`, `WEB_FROM=clone` và
    `scripts/backend.sh` trên máy từ chối bản clone có origin tên mới tới khi PR tương ứng merge.
  - Trong lượt chuyển, sáu bản của `oldbackend` không qua luật tổ tiên với `revision` (mục 3).
  - Rollback về bản trước đổi tên mất hẳn sau 72 giờ (mục 5); lùi chỉ còn sửa tiến.
  - Check `svp-gitops` clone ẩn danh mọi nguồn khác `backend` theo URL ở mỗi lượt, dựa vào chuyển hướng của GitHub cho URL cũ (mục 10).
- **Xem lại khi:**
  - Không env nào còn ở commit có nguồn nghỉ hưu và không bản ghi stg nào mà promote prd còn chép trỏ tới commit đó: bỏ phần đọc bảng không
    `promoter`.
  - Đổi tên repo lần nữa: dùng lại mục 2, 3; hay xét lựa chọn 1D nếu Kyverno khớp được identity theo id của repo.
  - Giai đoạn 7 thêm trust OIDC từ GitHub Actions sang cloud: repo đổi tên sau 2026-07-15 dùng `sub` dạng id bất biến [W3], trust policy
    viết theo dạng đó.
- **ADR cũ được chỉnh một phần:** [ADR-0033](0033-svp-web-repo.md) §2 (identity, prefix của hai nguồn; nguồn web cũ gỡ trong bảng chuyển),
  §3 (check không đặt `SVP_SOURCE_DIR_<TÊN>`), §9 (bước 8 làm ở đây), ghi ở trạng thái của nó;
  [ADR-0025](0025-gitops-config-repo.md) §5 (check checkout repo code tên mới, không checkout repo web);
  [ADR-0027](0027-slsa-build-provenance.md) §6 (rollback về bản trước đổi tên bị từ chối như về bản trước provenance).

## Kết quả

Chưa có. Ghi khi lượt phát hành đầu dưới tên mới tới stg (mục 4, bước 4, 5), bản ghi stg (bước 6), prd (bước 7) và PR gỡ (bước 8): id lượt
chạy, PR, commit.

## Hiện thực ở

PR đổi tên ở backend (chưa merge):

- Bảng nguồn (mục 3): `deploy/helm/svp-policy/files/sources.json` (bốn nguồn), `deploy/helm/svp-policy/templates/imagevalidatingpolicy.yaml`
  (`promoter` tuỳ chọn); `deploy/k8s/lib.sh` (`_release_sources_jq`, `ghcr_prefix`, `web_url`, `web_ci_clone`, `web_is_clone`,
  `web_release_repository`); `deploy/ci/common.sh` (nguồn không `promoter`, `drill_images`); `deploy/ci/sources-test.sh`.
- Tên repo trong adapter và đường GitOps (mục 7, 8): `deploy/ci/platform.sh` (`_ci_code_repo`, tên cũ dạng dữ liệu cho `ci_is_run_url`,
  `ci_run_workflow`) và `deploy/ci/platform-test.sh`; `deploy/k8s/gitops.sh` (`chart_repo_url`).
- Script phát hành (mục 3, 8): `deploy/ci/gitops-check.sh` (`author_rule` tiếp quản từ nguồn nghỉ hưu, `source_clone`, comment đầu file),
  `deploy/ci/promote.sh` (tiếp quản ở hai chế độ), `deploy/ci/promote-prd.sh`, `deploy/ci/rescan.sh` (từ chối `--source` nguồn nghỉ hưu),
  `deploy/ci/contract.sh` (hợp đồng dưới prefix mới), `deploy/ci/dora.sh` (bảng ở `charts.revision`, bản clone theo repo, `--clones`), các
  script còn lại của `deploy/ci/` và `deploy/ci/verify/` (tên repo, `.web/svp-frontend`), mọi `deploy/ci/*-test.sh`.
- Ca (l) (mục 6): `.github/workflows/images.yml` (input `drill` dựng ba image), `deploy/ci/verify/gitops.sh`, `deploy/k8s/drills/supplychain.sh`
  (ca l, ca m với bốn nguồn).
- Go module (mục 7): `go.mod`, import của `services/`, `internal/`, `tools/`, `gen/go` sinh lại.
- Tên ở cấu hình (mục 7): `.github/workflows/`, `Makefile`, `deploy/compose/`, chart dưới `deploy/helm/`, `runbook_url` dưới
  `deploy/observability/` (rule sinh lại bằng `make slo`), `renovate.json`.
- Tài liệu: `CLAUDE.md` (cả `CLAUDE.md` của workspace), `README.md`, `docs/` (runbook dựng repo web đổi tên thành
  `docs/runbooks/svp-frontend-setup.md`), mục Hiện thực ở của ADR cũ; trạng thái của ADR-0033.

Ở repo khác:

- `svp-gitops`: `.github/workflows/check.yml` (`CHECKER_COMMIT`, checkout `anhnvcoder/svp-backend`, bỏ checkout repo web và
  `SVP_SOURCE_DIR_WEB`), `argocd/apps/values.yaml` (`chartRepoURL`), `argocd/project.yaml` (`sourceRepos`), `base/services/web.yaml`
  (comment), `README.md`.
- `svp-frontend`: `.backend-commit`, `api/contract.json`, `scripts/backend.sh`, `.github/workflows/`, `renovate.json`, tài liệu.

PR gỡ (mục 4, bước 8; chưa làm): `sources.json` còn `backend`, `web`; bỏ nhánh tiếp quản từ nguồn nghỉ hưu ở `gitops-check.sh`,
`promote.sh` và phần riêng cho nguồn nghỉ hưu ở `rescan.sh`, `supplychain.sh`; giữ `_release_sources_jq`, template đọc được nguồn không
`promoter` và phần lịch sử của mục 8.

## Nguồn

Đọc ngày 2026-10-31.

- [W1] GitHub Docs, "Renaming a repository" ("all existing information, with the exception of project site URLs, is automatically
  redirected to the new name"; "all `git clone`, `git fetch`, or `git push` operations targeting the previous location will continue to
  function"; "GitHub will not redirect calls to an action hosted by a renamed repository"; "do not reuse the original name of the renamed
  repository. If you do, redirects to the renamed repository will no longer work"; không nói về REST API hay GitHub Packages):
  <https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository>
- [W2] GitHub Docs, "Configuring a package's access control and visibility" ("the package automatically inherits the access permissions (but
  not the visibility) of the linked repository"; "When you first publish a package that is scoped to your personal account, the default
  visibility is private"; "Once you make a package public, you cannot make it private again"):
  <https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility>
- [W3] GitHub Docs, "OpenID Connect reference" (claim `repository`, `repository_id` "The ID of the repository from where the workflow is
  running", `workflow_ref` dạng `octocat/hello-world/.github/workflows/my-workflow.yml@refs/heads/my_branch`, `job_workflow_ref`; "Repository
  renames and transfers after July 15, 2026 also move to the immutable subject format"):
  <https://docs.github.com/en/actions/reference/security/oidc>
