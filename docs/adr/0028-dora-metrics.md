# 0028. DORA metrics của lab tính bằng script của repo (`deploy/ci/dora.sh`, workflow `dora.yml` chỉ đọc) từ bằng chứng đã triển khai (bản ghi Deployment `success` của stg trên `svp-gitops`), không từ merge; mọi số là của stg lab, prd ghi "chưa có dữ liệu" tới giai đoạn 7, chỉ số thiếu mẫu ghi "chưa đủ dữ liệu", không xếp hạng theo mức DORA

- Trạng thái: Chấp nhận (người học duyệt 2026-10-28, chọn (a) ở cả bốn dòng "Cần người học chọn", gồm kịch bản `gitops` vào
  lịch tuần của `verify.yml`); hiện thực 2026-10-29 (phần 4 của giai đoạn 6b, PR-B, nhánh `feat/stage6b-gitops-split`, PR #39; mục
  Hiện thực ở): `dora-test.sh` xanh ở job `config`; lượt `dora.yml` đầu chạy 2026-10-30 (kết quả ở mục Kiểm chứng sau); dòng 4 (kịch
  bản `gitops` vào lịch tuần) hiện thực 2026-10-30 ([ADR-0021](0021-deferred-verification-stage6b.md) mục 3): lịch tuần của
  `verify.yml` chạy job `gitops` không chờ phát hành, bản ghi stg ghi khi bước kịch bản xanh; lượt lịch đầu kiểm sau merge
- Ngày: 2026-10-28

## Bối cảnh

- **Yêu cầu** (lộ trình của lab, giai đoạn 6b phần 4, dòng "DORA metrics"): đo deployment frequency, lead time for changes, change
  failure rate, time to restore từ dữ liệu có thật của lab (commit, PR promote, bản ghi triển khai, đồng bộ của Argo CD, sự cố và
  postmortem); nơi tính là script CI trung lập nền tảng qua `deploy/ci/platform.sh` ([ADR-0023](0023-ci-platform-neutral.md)); nơi
  hiển thị do ADR này chọn.
- **Định nghĩa hiện hành của DORA** (đọc 2026-10-28):
  - Trang hướng dẫn của DORA (cập nhật 2026-01-05) nêu **năm** chỉ số giao phần mềm [N1]:
    - change lead time: "the amount of time it takes for a change to go from committed to version control to deployed in production";
    - deployment frequency: "the number of deployments over a given period or the time between deployments";
    - failed deployment recovery time: "the time it takes to recover from a deployment that fails and requires immediate intervention";
    - change fail rate: "the ratio of deployments that require immediate intervention following a deployment";
    - deployment rework rate: "the ratio of deployments that are unplanned but happen as a result of an incident in production".

    Ba chỉ số đầu thuộc nhóm throughput, hai chỉ số sau thuộc nhóm instability [N1].
  - Lịch sử của DORA [N2]: năm 2023 MTTR được đổi tên và định nghĩa lại thành failed deployment recovery time, vì định nghĩa cũ không
    tách sự cố do thay đổi phần mềm khỏi sự cố do nguyên nhân ngoài (ví dụ mất trung tâm dữ liệu); năm 2024 thêm chỉ số thứ năm,
    deployment rework rate. Báo cáo 2024 hỏi rework rate bằng câu "approximately how many deployments in the last six months were not
    planned but were performed to address a user-facing bug in the application?" [N3, tr. 11]. "Time to restore" trong yêu cầu của lab
    vì thế đọc là failed deployment recovery time.
  - Mức hiệu năng: báo cáo 2024 có bốn cụm phân tích trên bốn chỉ số gốc [N3, tr. 13]:

    | Mức (2024) | Change lead time | Deployment frequency | Change fail rate | Failed deployment recovery time | Tỷ lệ người trả lời |
    | --- | --- | --- | --- | --- | --- |
    | Elite | dưới một ngày | theo nhu cầu (nhiều lần mỗi ngày) | 5% | dưới một giờ | 19% |
    | High | một ngày tới một tuần | một lần mỗi ngày tới một lần mỗi tuần | 20% | dưới một ngày | 22% |
    | Medium | một tuần tới một tháng | một lần mỗi tuần tới một lần mỗi tháng | 10% | dưới một ngày | 35% |
    | Low | một tới sáu tháng | một lần mỗi tháng tới một lần mỗi sáu tháng | 40% | một tuần tới một tháng | 25% |

    Báo cáo ghi các mức không đặt trước mà "emerge from the survey responses", là ảnh chụp của năm đó [N3, tr. 13]. Bài công bố báo
    cáo 2025 (2025-09-24) mô tả phân tích cụm ra **bảy hồ sơ nhóm** theo hiệu năng, độ ổn định và well-being, không nêu bảng bốn mức
    [N4]; toàn văn báo cáo 2025 phát hành qua trang của Google Cloud, ADR này không đọc, nên không khẳng định báo cáo 2025 bỏ hay giữ
    bảng bốn mức.
  - DORA khuyên không đặt chỉ số làm mục tiêu ("increases the likelihood that teams will try to game the metrics"), áp dụng ở mức ứng
    dụng hay service, không so giữa các ứng dụng rất khác nhau hay thi đua giữa các nhóm [N1].
- **Hiện trạng dữ liệu của lab** (`origin/main` ở `744f108`, cộng phần 3 trên PR #26):
  - **PR promote trong repo code** ([ADR-0015](0015-cicd-devsecops-stage5.md) §9): 10 PR đã merge, #1, #5, #9, #11, #15, #17, #19,
    #21, #23, #25, từ 2026-10-21 tới 2026-10-25 (`gh pr list --state merged --search head:bot/promote`). Merge chỉ đổi file values; lúc
    đó không cluster nào chạy liên tục theo `main`: cluster GitOps chỉ dựng trong một lượt kiểm.
  - **Merge không chứng minh đã triển khai** ([ADR-0024](0024-multi-environment.md) §8): digest A merge vào `envs/stg/images/` rồi bị
    B thay trước khi Argo CD đồng bộ, hay stg đồng bộ hỏng, thì A vẫn nằm trong lịch sử git mà chưa từng chạy.
  - **Bản ghi triển khai stg** (ADR-0024 §8, phần 4 chưa hiện thực): Deployment GitHub trên `svp-gitops`, environment `stg`, `ref` là
    commit `svp-gitops` mà Argo CD đã đồng bộ, trạng thái `success`, payload là bộ bảy `repository@digest` đọc từ pod và URL lượt kiểm;
    chỉ ghi sau khi phép kiểm trên stg qua. Phần 4 thêm vào payload: revision R, `deployed_at` (lúc Argo CD đồng bộ xong R) và chỉ ghi
    khi bộ không đổi suốt cửa sổ kiểm của lượt `gitops`; [ADR-0025](0025-gitops-config-repo.md) §2 (Đề xuất) thêm `charts` (commit chart
    của repo code mà env chạy). Chưa có bản ghi nào: `GET /repos/anhnvcoder/short-video-platform/deployments` trả `[]` (2026-10-28).
  - **Trạng thái của Deployment GitHub** [N17]: tạo trạng thái mới với `auto_inactive` mặc định `true` thì mọi Deployment trước đó
    cùng environment (không transient, không production; `stg` không phải production theo mặc định [N10]) từng `success` nhận thêm
    trạng thái `inactive`. Trạng thái trước đó chỉ giữ 90 ngày rồi bị xoá khỏi API; trạng thái hiện tại lưu trên chính Deployment nên
    không bị xoá. Deployment không sửa được sau khi tạo, và khi repo có hơn một Deployment chỉ xoá được Deployment `inactive` [N10].
  - **`measure-gitops`** (`deploy/k8s/drills/gitops.sh`): đo một commit phát hành từ lúc push qua đồng bộ của Argo CD tới pod đầu và
    cuối Ready, JSON ở `.k8s/drills/gitops-<commit>.json`; trên runner chỉ ở bước chờ phát hành của kịch bản `gitops` trên `main`
    ([ADR-0021](0021-deferred-verification-stage6b.md)), nằm trong artifact `verify-gitops` giữ 30 ngày. Chưa có lượt nào đo được (các
    lượt `gitops` 2026-10-26 tới 2026-10-28 chạy trên nhánh, bước đó `skipped`).
  - **stg chỉ sống trong một lượt runner:** mỗi lượt `gitops` dựng cluster mới từ đầu, đồng bộ revision hiện tại của `main`, kiểm, rồi
    xoá. Lúc viết, kịch bản `gitops` chỉ chạy khi được dispatch, không nằm trong lịch tuần của `verify.yml` (ADR-0021); dòng 4 của
    "Cần người học chọn" đổi điều đó.
  - **prd** chỉ render và kiểm tĩnh tới giai đoạn 7 (ADR-0024 §5, §9).
  - **Postmortem:** một bản, `docs/postmortems/261024-gameday-engagement-down.md`: game day trên compose, sự cố tiêm có chủ ý, không
    do triển khai nào. Mẫu postmortem chưa có trường máy đọc được.
- **Ràng buộc:** một người làm, hai repo public (không token ghi cho việc đọc); CI trung lập nền tảng (YAML chỉ nối bước, API của nền
  tảng qua `ci_*`); máy 16 GB không chạy thêm dịch vụ thường trực; không bịa số, mỗi con số có nguồn.

## Các lựa chọn

### 1. Công cụ tính và hiển thị

| Lựa chọn | Trạng thái ngành (đọc 2026-10-28) | Được | Mất | RAM, chi phí | Chạy trên runner |
| --- | --- | --- | --- | --- | --- |
| **A. Script của repo (`deploy/ci/dora.sh`) qua `ci_*` của `platform.sh`** | Hiện hành (cách tự đo từ API của nền tảng; Four Keys của Google cũng tự khuyên dùng repo của nó "as inspiration for your own metrics instrumentation" [N5]) | Định nghĩa đúng của lab (bằng chứng triển khai, khử trùng lượt kiểm, nhãn stg lab) viết thẳng thành code có test; dữ liệu đọc qua API công khai và git; trung lập nền tảng; không dịch vụ nào phải giữ | Tự viết và tự giữ; không có dashboard lịch sử sẵn; định nghĩa sai thì không ai khác bắt | Không thêm RAM; phút runner của repo public miễn phí (ADR-0021) | Có: một job vài phút |
| B. Apache DevLake | Hiện hành: Top-Level Project của ASF từ 2025-10-07 [N7]; bản phát hành mới nhất `v1.0.3-beta18` (2026-09-27) mang nhãn beta [N6] | Dashboard DORA dựng sẵn trên Grafana; từ v0.20 tự đổi Deployment của GitHub thành deployment của DevLake; nhận deployment, incident qua webhook; đọc GitHub, GitLab, Jenkins [N6] | Bốn container (`mysql:8`, Grafana, `config-ui`, `devlake`) phải chạy thường trực để thu và giữ dữ liệu [N6]; định nghĩa riêng của lab (khử trùng lượt kiểm theo revision, rollback theo quy ước, nhãn stg lab) phải ép vào mô hình của DevLake; trang DORA của DevLake chỉ nêu bốn chỉ số, không có rework rate [N6] | Tài liệu không ghi yêu cầu RAM [N6], phải đo trước; thêm MySQL và Grafana thường trực, vượt ngân sách máy 16 GB khi chạy cùng stack | Chỉ tạm: runner dùng một lần, mỗi lượt thu lại từ đầu rồi mất dashboard |
| C. Four Keys của Google (`dora-team/fourkeys`) | Legacy: repo đã archive, push cuối 2024-01-23, README ghi "not currently maintained" [N5] | Mẫu tham khảo của chính nhóm DORA | Không còn bảo trì; kiến trúc gắn GCP: webhook trên Cloud Run, Pub/Sub, BigQuery [N5]; định nghĩa cũ ("Time to Restore Services") | Tính tiền GCP theo dịch vụ; trái "local trước, cloud sau" | Không |
| D. DORA có sẵn của GitLab | Hiện hành, chỉ gói **Ultimate** (gitlab.com, Self-Managed, Dedicated) [N8] | Bốn chỉ số dựng sẵn; deployment ngoài GitLab CI (kéo kiểu GitOps) ghi được bằng Deployments API [N8] | Lab đang ở GitHub (CI thật trên GitLab mới là việc sau phần 4); lead time tính từ lúc merge MR, change fail rate và restore tính từ incident của GitLab theo quan hệ một-một với deployment [N8]; gói trả phí | Gói Ultimate trả phí | Không áp dụng (tính năng của nền tảng) |
| E. SaaS: Swarmia, LinearB, DX (Atlassian) | Hiện hành | Không phải vận hành; dashboard, so sánh theo thời gian | Swarmia miễn phí dưới 10 developer, có DORA [N12]; LinearB không có gói miễn phí, tối thiểu 50 user trả phí, dùng thử 45 ngày [N13]; DX thuộc Atlassian từ 2025-11-10, bán cho doanh nghiệp [N14]; mọi dịch vụ cần cài App đọc repo vào bên thứ ba, mô hình deployment của họ không biết "bằng chứng đã chạy ở stg lab" | 0 tới vài chục USD mỗi developer mỗi tháng [N12, N13] | Không (dịch vụ ngoài) |

### 2. Một "deployment" là gì

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| A. Merge vào `envs/<env>/images/` (commit promote) | Có sẵn trong git, đủ lịch sử | Sai với ADR-0024 §8: digest merge rồi bị thay trước khi đồng bộ vẫn được đếm; lead time dừng ở lúc merge, không ở lúc chạy |
| B. Mục `status.history` của Argo CD | Đúng lúc đồng bộ | Mất cùng cluster sau mỗi lượt runner; không nói phép kiểm đã qua; đọc phải vào cluster |
| **C. Bản ghi Deployment `success` của stg (ADR-0024 §8), danh tính (env, revision R, bộ digest)** | Bằng chứng đã chạy và đã qua kiểm; Deployment, payload và trạng thái hiện tại không bị xoá theo thời gian [N17], tính lại được bất cứ lúc nào khi bên ghi giữ trạng thái hiện tại là `success`; có `deployed_at` | Chỉ có khi một lượt `gitops` xanh trên `main`; nhiều lượt kiểm cùng R phải khử trùng; với `auto_inactive` mặc định, bản ghi mới đặt bản ghi trước thành `inactive` và sau 90 ngày không còn thấy nó từng `success` [N17], nên bên ghi phải tắt cờ đó |
| D. C cộng JSON `measure-gitops` | Thêm thời gian push → pod Ready của bản phát hành đo trong lượt | Bản đó không có phép kiểm sau nó trong lượt (ghi bản ghi ở lượt sau); artifact hết hạn sau 30 ngày; cần thêm hàm đọc danh sách lượt và quyền `actions: read` |

### 3. Mốc đầu của lead time

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Thời điểm commit có trên `main` của repo (commit squash của PR, committer date)** | Đúng "committed to version control" của nhánh chính; đọc bằng git, không API; mọi commit của `main` repo code là commit squash một cha | Không tính thời gian trên nhánh tính năng |
| B. Commit đầu tiên của PR | Gần "lúc viết code" hơn | Commit của nhánh không còn trên `main` sau squash, phải đọc qua API của PR; nhánh dài nhiều ngày của một người làm làm số phình theo nhịp học, không theo đường giao |

### 4. Failure và restore

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Bằng chứng sau bản ghi: rollback có quy ước trong `svp-gitops`, dispatch rollback prd (giai đoạn 7), postmortem có trường máy đọc chỉ vào deployment; restore từ mốc UTC của postmortem, không có thì từ `deployed_at` của deployment hỏng tới `deployed_at` của deployment khôi phục** | Đúng "deployment that requires immediate intervention" [N1]; chỉ đọc git và file trong repo | Phần lớn lỗi bị phép kiểm stg chặn trước khi có bản ghi, nên tỷ lệ của stg lab gần như luôn thấp hơn thực tế giao hàng |
| B. Lượt `gitops` đỏ là một failure | Có nhiều mẫu hơn | Lượt đỏ vì runner (đĩa, mạng, quota) lẫn với lỗi của thay đổi; bộ chưa từng được ghi thì không phải deployment |
| C. Mọi postmortem | Đơn giản | Gồm sự cố không do triển khai (game day tiêm có chủ ý) mà DORA đã tách ra khỏi chỉ số từ 2023 [N2] |

### 5. Nơi hiển thị

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Tóm tắt của lượt chạy (bảng Markdown) và JSON artifact** | Không thêm dịch vụ; ai cũng đọc được lượt chạy của repo public; tính lại được từ bản ghi vĩnh viễn nên không cần giữ lịch sử artifact | Không có biểu đồ theo thời gian |
| B. A cộng dashboard Grafana | Biểu đồ quen thuộc | Grafana của lab chỉ sống khi stack hay cluster bật; dữ liệu phải có đường vào (Pushgateway, datasource JSON đọc một URL công khai) mà artifact cần đăng nhập để tải; đường ghi lên GitHub Pages hay một nhánh cần quyền ghi |
| C. Dashboard của DevLake | Có sẵn | Chỉ khi chọn 1B |

## Quyết định

### 1. Công cụ: script của repo (1A)

`deploy/ci/dora.sh` (sẽ tạo) tính, `.github/workflows/dora.yml` (sẽ tạo) chỉ nối bước. Lý do: định nghĩa đúng của lab (deployment là
bằng chứng đã chạy, khử trùng lượt kiểm theo revision, rollback theo quy ước, nhãn stg lab, "chưa đủ dữ liệu") là phần khó, công cụ
nào cũng phải được dạy lại phần đó; script nhỏ có test làm việc đó trực tiếp, không thêm dịch vụ thường trực, đọc dữ liệu công khai, và
mang sang GitLab bằng nhánh `gitlab` của các hàm `ci_*`. DevLake là lựa chọn đáng xét lại khi lab có nhiều repo, nhiều người, hay một
máy chủ chạy thường trực (mục Hệ quả).

### 2. Nguồn và danh tính deployment (2C)

- **Deployment** là một bản ghi Deployment `success` trên `svp-gitops` (ADR-0024 §8), environment `stg` hay `prd`, do App
  `svp-gitops-promoter` tạo và có URL lượt `verify.yml` trên `main` của repo code (cùng bộ lọc mà check PR prd dùng, ADR-0025 §6).
  Bản ghi không qua bộ lọc, hay thiếu `deployed_at`, bị bỏ và liệt kê kèm lý do.
- **Bằng chứng giữ bền:** bên ghi bản ghi stg (và prd sau này) tạo trạng thái `success` với **`auto_inactive: false`**. Với mặc định
  `true`, mỗi bản ghi stg mới đặt mọi bản ghi stg trước thành `inactive` [N17]: chỉ đọc trạng thái hiện tại thì hai revision chỉ còn
  một deployment, và lượt kiểm lại cùng R làm bản ghi đầu mất, mốc `deployed_at` trôi sang lượt sau. Tắt cờ thì trạng thái hiện tại của
  mọi bản ghi vẫn là `success`, lưu trên chính Deployment nên không bị xoá sau 90 ngày như trạng thái trước đó [N17]; xoá một bản ghi
  phải đặt `inactive` trước [N10], tức cần quyền ghi trên `svp-gitops`, cùng ranh giới tin cậy với lịch sử git của repo đó.
- **Bên đọc** đọc mọi trạng thái API còn trả của từng bản ghi:
  - trạng thái hiện tại `success`: tính;
  - trạng thái hiện tại `inactive` mà danh sách còn một `success` (bản ghi ghi khi chưa có quy ước, trong 90 ngày): tính, kèm cảnh báo
    nêu id bản ghi;
  - trạng thái hiện tại `inactive` không còn `success` nào trong danh sách, hay trạng thái khác: bỏ, liệt kê id kèm lý do ("không còn
    bằng chứng `success`"), để mất mát hiện ra trong output thay vì làm số nhỏ đi lặng lẽ.
- **Danh tính:** (env, revision R của `svp-gitops` mà Argo CD đã đồng bộ, bộ bảy `repository@digest`). Bản ghi stg chỉ được ghi khi
  bộ bằng đúng `envs/stg/images/` ở R, nên trên stg R quyết định bộ; giữ bộ trong danh tính để so được với prd và bắt bản ghi sai.
  - Nhiều bản ghi **cùng** (env, R, bộ) là **một** deployment (lần kiểm lại của cùng bản phát hành trên một stg dựng lại): deployment
    lấy `deployed_at` của bản ghi **đầu tiên**; các bản ghi sau đếm riêng là **lượt kiểm**.
  - **R khác** là **deployment mới**, kể cả khi bộ digest bằng bộ cũ: đổi chart, values hay `charts.yaml` cũng là triển khai.
  - Bộ trùng một bộ cũ **không** tự là rollback; rollback chỉ khi có bằng chứng (mục 5).
- **`measure-gitops` không dùng** (2D không chọn): bản phát hành nó đo chưa qua phép kiểm nào sau đó trong lượt, và nếu lượt sau kiểm
  nó thì nó có bản ghi riêng; artifact hết hạn sau 30 ngày; thêm nguồn này cần hàm đọc danh sách lượt và quyền `actions: read` chỉ để
  được một số đo phụ. Số của `measure-gitops` vẫn là số đo của diễn tập (ADR-0021).
- **Dữ liệu trước khi tách repo:** 10 PR promote trong repo code (#1 tới #25) **không** tính vào bốn chỉ số: không có bản ghi nào
  chứng minh chúng đã chạy. Chúng vào chỉ số riêng "tần suất promote" với nhãn "trước tách, repo code", nguồn là commit squash trên
  `main` của repo code có tiêu đề `chore(release): …` của job promote (đọc bằng git; commit khác cũng có thể sửa
  `deploy/k8s/values/services/` nên không lọc theo đường dẫn), để thấy nhịp phát hành từ giai đoạn 5.
- **prd:** chưa có bản ghi tới giai đoạn 7 (bản ghi prd do ADR của giai đoạn 7 chốt). Output ghi "chưa có dữ liệu prd" cho mọi chỉ số
  của prd, không ghi 0.

### 3. Ánh xạ từng chỉ số vào lab

Mọi số của stg mang nhãn **"stg lab (cụm dựng trong một lượt runner)"**.

| Chỉ số (định nghĩa [N1]) | Ánh xạ vào lab | Dữ liệu |
| --- | --- | --- |
| Deployment frequency | Số deployment (mục 2) có `deployed_at` trong cửa sổ, và số mỗi tuần; in kèm số lượt kiểm | Bản ghi Deployment |
| Change lead time | Mỗi thay đổi (mục 4): `deployed_at` của deployment sớm nhất ở env chứa nó − thời điểm commit; trung vị và từng giá trị | Bản ghi, git của hai repo |
| Change fail rate | Số deployment thất bại (mục 5) / số deployment trong cửa sổ | Bản ghi, git `svp-gitops`, postmortem |
| Failed deployment recovery time | Mỗi deployment thất bại: từ mốc bắt đầu tới mốc khôi phục (mục 5); trung vị và từng giá trị | Như trên |
| Deployment rework rate | Số deployment là rollback hay là deployment **sớm nhất** ở env chứa một commit sửa mà postmortem liệt kê (mỗi commit sửa tính một lần, như lead time ở mục 4: phát hành sau chứa nó vì là hậu duệ không phải rework) / số deployment trong cửa sổ | Như trên |
| Tần suất promote (chỉ số riêng, không phải DORA) | Số commit trên `main` của `svp-gitops` đổi `envs/<env>/images/`, cộng PR promote trước tách (mục 2) | git |
| Đã merge, chưa triển khai (danh sách) | Mỗi `repository@digest` từng có trong `envs/<env>/images/` trên `main` mà không bản ghi nào của env đó chứa | git, bản ghi |

### 4. Lead time chi tiết (3A)

- Mốc đầu: committer date của commit trên `main` (repo code: commit squash; `svp-gitops`: commit trên `main`). Mốc cuối: `deployed_at`
  của deployment **sớm nhất** của env có chứa thay đổi đó (bên dưới), không phải lúc merge.
- **Thay đổi** là một trong ba loại commit:
  - commit một cha của `main` repo code mà `deploy/ci/changed-services.sh <commit>^ <commit>` liệt kê một service s (thay đổi của s);
  - commit một cha của `main` repo code đổi `deploy/helm/` hay file dẫn xuất (nếu ADR-0025 giữ 2A, chart theo `charts.revision`);
  - commit của `svp-gitops` đổi gì đó ngoài `envs/*/images/` và `envs/*/charts.yaml` (thay đổi cấu hình; commit promote của bot chỉ
    chở thay đổi code đã đếm ở trên nên bỏ).

  Commit không tới thứ gì triển khai (tài liệu, test) không phải thay đổi được giao, không vào lead time.
- Deployment D **chứa** thay đổi c khi c là chính hay tổ tiên (`git merge-base --is-ancestor`) của mốc tương ứng trong D: commit của
  image service s trong bộ của D (12 hex trong `image.tag`), `charts.revision` của D, hay R của D.
- Mỗi thay đổi có **một** mẫu lead time, ở deployment **sớm nhất** (theo `deployed_at`) của env chứa nó. Không lấy khoảng giữa
  deployment và deployment ngay trước: sau A → B → rollback A → C (C sau B), khoảng (A, C] chọn lại thay đổi của B dù B đã có bằng
  chứng ở env; theo quy tắc này thay đổi của (A, B] chỉ có mẫu ở B, C chỉ thêm thay đổi của (B, C]. Lượt kiểm lại, đổi chart hay tiến
  tiếp sau rollback không thêm mẫu cho thay đổi đã giao.
- Thay đổi mà deployment đầu tiên của env đã chứa không có mẫu: nó có thể đã chạy ở env trước khi có bản ghi, không biết lúc nào.
  Deployment đầu tiên đếm vào deployment frequency, không vào lead time.
- Ở stg lab, lead time gồm cả thời gian chờ tới lượt `gitops` kế tiếp; output nói rõ điều đó.

### 5. Failure, rollback, restore (4A)

- **Rollback trong `svp-gitops`:** commit trên `main` (xét mọi commit trong khoảng, không chỉ dòng một cha, để đúng cả với merge commit)
  có tiêu đề `revert: …` và footer `Refs: <sha>` theo khuyến nghị của Conventional Commits [N15], hay dạng của `git revert` (`Revert
  "…"`, `This reverts commit <sha>.`). Để commit squash giữ được footer, `svp-gitops` đặt mặc định của squash là tiêu đề và mô tả của
  PR (`squash_merge_commit_title: PR_TITLE`, `squash_merge_commit_message: PR_BODY` [N16]). Deployment có R chứa (lần đầu) một commit
  như vậy là **rollback**; deployment **thất bại** là deployment gần nhất trước nó, cùng env, có R chứa commit bị revert. Commit bị revert
  khi chưa từng được triển khai không làm deployment nào thất bại.
- **Rollback prd** (giai đoạn 7): PR prd do dispatch promote prd mở với một bản ghi stg cũ hơn bản đang ở prd (ADR-0024 §8).
- **Postmortem chỉ vào deployment** (front matter, mục 7): deployment mà postmortem ghi `deployment` là thất bại.
- **Mốc khôi phục:** bắt đầu là `started_at` của postmortem nếu có, không thì `deployed_at` của deployment thất bại; kết thúc là
  `restored_at` của postmortem nếu có, không thì `deployed_at` của deployment rollback hay deployment đầu tiên chứa một commit trong
  `fix_commits` của postmortem. Chưa có mốc kết thúc thì ghi "chưa khôi phục", không tính.
- Postmortem có `deployment: none` (như game day 2026-10-24) không vào bốn chỉ số; output liệt kê nó dưới "sự cố không do triển khai".
- Lượt `gitops` đỏ không phải failure (4B không chọn): bộ chưa có bản ghi thì chưa là deployment.

### 6. Đủ dữ liệu, không xếp hạng

- Ngưỡng của lab (không phải của DORA): tỷ lệ (change fail rate, rework rate) cần ít nhất 10 deployment trong cửa sổ; trung vị (lead
  time, recovery time) cần ít nhất 5 mẫu. Dưới ngưỡng thì in "chưa đủ dữ liệu (n = …, cần ≥ …)" cùng tử số, mẫu số hay từng giá trị,
  không in phần trăm hay trung vị. stg chưa có bản ghi nào thì mọi chỉ số của stg là "chưa đủ dữ liệu"; có bản ghi mà cửa sổ không có
  deployment nào thì deployment frequency là 0 (số có nghĩa).
- **Không xếp mức** Elite/High/Medium/Low: bảng 2024 [N3] là của production và của mẫu khảo sát năm đó, prd của lab chưa có dữ liệu,
  stg lab bị chặn bởi nhịp lượt runner, bài công bố 2025 mô tả hồ sơ nhóm thay vì bốn mức [N4], và DORA khuyên không đặt chỉ số làm mục
  tiêu hay so giữa các nhóm [N1]. Bảng 2024 chỉ nằm trong ADR này làm tham khảo, không vào output.

### 7. Quy ước dữ liệu cần thêm

- **Payload bản ghi stg** (đã chốt ở phần 4 cho job ghi bản ghi): `deployed_at` (RFC 3339 UTC, muộn nhất trong các `deployedAt` của R
  ở `status.history` các Application), R, bộ bảy `repository@digest`, `charts` (nếu ADR-0025 giữ 2A), URL lượt chạy.
- **Trạng thái của bản ghi:** job ghi bản ghi tạo trạng thái `success` với `auto_inactive: false` (mục 2); bản ghi prd của giai đoạn 7
  cũng vậy.
- **Postmortem:** front matter YAML ở đầu file, thêm vào mẫu của `docs/postmortems/README.md` và vào postmortem đang có:

  ```yaml
  ---
  env: stg                    # stg | prd | compose | k3d
  deployment: <40 hex>        # revision of svp-gitops of the deployment that caused it, or none
  started_at: <RFC 3339 UTC>  # T0, same source as the timeline
  restored_at: <RFC 3339 UTC> # recovery, same source as the timeline
  fix_commits: []             # <repository>@<40 hex> of the commits that fixed it, either repository
  ---
  ```

  Mốc lấy đúng từ dòng thời gian có nguồn của postmortem; postmortem game day 2026-10-24 ghi `env: compose`, `deployment: none`,
  `started_at: 2026-10-24T07:24:49Z` (T0), `restored_at: 2026-10-24T07:27:53Z` (mốc `recovered`).
- **`svp-gitops`:** quy ước rollback ở mục 5 và hai cài đặt squash; ghi vào `README.md` của repo đó.

### 8. Workflow và output

- `.github/workflows/dora.yml` trong repo code (nơi có script): trigger `schedule` hằng tuần (thứ Bảy 09:17 UTC, sau lịch tuần của
  `verify.yml`) và `workflow_dispatch` với input `days` (mặc định 30). `permissions: {}` ở đầu file, job chỉ `contents: read`; không
  secret, không environment, không `pull_request`; action ghim SHA.
- Không cần token ghi: hai repo public. Script đọc bản ghi qua API bằng `GITHUB_TOKEN` của job chỉ để được giới hạn 1 000 request mỗi
  giờ thay vì 60 của request ẩn danh [N11]; đọc dữ liệu công khai của `svp-gitops` không cần quyền nào trên repo đó. Git của hai repo
  đọc bằng clone ẩn danh (`make gitops-clone` của ADR-0025, repo code với đủ lịch sử).
- Cửa sổ: 30 ngày lăn tới lúc chạy, cộng cột "từ khi tách repo" (mẫu nhỏ nên cửa sổ ngắn thường dưới ngưỡng).
- Output: bảng Markdown vào tóm tắt của lượt (`ci_summary`), JSON là artifact `dora` giữ 30 ngày. Không giữ lịch sử artifact:
  Deployment, payload và trạng thái hiện tại của nó không bị xoá theo thời gian (chỉ trạng thái trước đó bị xoá sau 90 ngày [N17]) và
  bên ghi giữ trạng thái hiện tại là `success` (mục 2), nên số của bất kỳ khoảng nào tính lại được bằng dispatch với `days` lớn hơn.
  Bản ghi ghi trước quy ước mà đã `inactive` quá 90 ngày thì không tính lại được; output liệt kê nó (mục 2). Không dashboard Grafana
  (5A).
- Chạy trên máy: `deploy/ci/dora.sh` ở chế độ `local` của `platform.sh`, chỉ đọc, qua đăng nhập `gh` của máy hay ẩn danh.

### 9. Hàm `ci_*` cần có và tương đương trên GitLab

| Việc | Hàm (`platform.sh`) | GitHub | GitLab |
| --- | --- | --- | --- |
| Liệt kê bản ghi của một env ở repo cấu hình, kèm payload, người tạo, mọi trạng thái API còn trả (trạng thái hiện tại luôn có) | Hàm đọc Deployment của phần 4 (ghi và đọc bản ghi đã nằm trong việc của job ghi bản ghi), nhận repo đích; thêm payload và danh sách trạng thái nếu bản đó chưa trả; hàm ghi trạng thái nhận `auto_inactive: false` | `GET /repos/{o}/{r}/deployments?environment=` [N10] và `/deployments/{id}/statuses` [N17] | `GET /projects/:id/deployments?environment=&status=success` (gói Free) [N9]; **Deployment của GitLab không có trường payload** [N9], nên bộ digest, R và `deployed_at` phải nằm chỗ khác (artifact của job ghi bản ghi, hay generic package của project); chốt khi mang CI sang GitLab, ghi vào bảng của ADR-0023 |
| Tóm tắt, artifact | `ci_summary` có sẵn; artifact do YAML khai | job summary | log hay artifact của job (ADR-0023) |
| PR promote đã merge, revert, thay đổi theo đường dẫn | Không cần hàm: đọc bằng `git log` của bản clone | — | — |
| Postmortem | Không cần hàm: file trong repo code | — | — |

DORA dựng sẵn của GitLab (Ultimate, [N8]) không thay script này khi mang sang: nó tính lead time từ lúc merge MR và failure theo
incident của GitLab, khác định nghĩa ở mục 3 đến 5.

### Cần người học chọn

Mỗi dòng đề xuất đứng trước. Người học duyệt ngày 2026-10-28: chọn (a) ở cả bốn dòng.

1. **Công cụ.** (a) Script của repo (1A). Lý do: định nghĩa của lab viết thẳng thành code có test, không dịch vụ thường trực, trung lập
   nền tảng. (b) Apache DevLake (1B): dashboard sẵn, nhưng thêm MySQL và Grafana thường trực, chưa có số RAM, định nghĩa của lab phải ép
   vào mô hình của nó. Four Keys (legacy) và GitLab Ultimate không đề xuất.
2. **Nơi hiển thị.** (a) Tóm tắt của lượt chạy và JSON artifact (5A). Lý do: không thêm dịch vụ, tính lại được từ bản ghi giữ `success`
   (mục 2).
   (b) Thêm dashboard Grafana (5B): cần một đường đưa dữ liệu vào Grafana, xét lại khi giai đoạn 7 có Grafana sống lâu hơn một buổi.
3. **Định nghĩa failure.** (a) Chỉ bằng chứng sau bản ghi: rollback theo quy ước của `svp-gitops`, rollback prd, postmortem chỉ vào
   deployment (4A). Lý do: đúng định nghĩa của DORA, không lẫn lỗi của runner. (b) Thêm lượt `gitops` đỏ (4B): nhiều mẫu hơn nhưng đếm
   cả lỗi hạ tầng của runner và bộ chưa từng là deployment.
4. **Lượt `gitops` theo lịch** (đổi lịch của `verify.yml`, ngoài phần hiện thực DORA). (a) Thêm kịch bản `gitops` vào lịch tuần trên
   `main`, bỏ bước chờ phát hành. Lý do: không có nó, deployment frequency của stg lab chỉ đo nhịp người học dispatch; mỗi tuần một lượt
   cho stg một nhịp đều (vẫn là trần một deployment mỗi tuần, ghi rõ trong output); phút runner của repo public miễn phí. (b) Giữ chỉ
   dispatch: không đổi `verify.yml`, dữ liệu thưa và không đều.

## Kiểm chứng sau

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| `dora.sh` đếm đúng: ba bản ghi cùng (stg, R, bộ) là một deployment, ba lượt kiểm, lead time từ bản ghi đầu; R1/A → R2/A (chỉ đổi chart) là hai deployment, không rollback; A → B → A ở ba revision có commit revert là ba deployment, cái cuối là rollback, cái giữa thất bại; digest merge không có bản ghi chỉ nằm trong "đã merge, chưa triển khai" và trong tần suất promote | `deploy/ci/dora-test.sh` với dữ liệu giả cố định, chạy ở job `config` | Đạt (2026-10-29): `deploy/ci/dora-test.sh` (dữ liệu giả cố định, `--now` cố định) xanh ở job `config` của CI PR #39 [40954602918](https://github.com/anhnvcoder/short-video-platform/actions/runs/40954602918) (`027f8bd`) |
| Lead time một mẫu mỗi thay đổi: A → B → rollback A → C (C sau B) thì thay đổi của (A, B] chỉ có mẫu ở B, C chỉ thêm thay đổi của (B, C]; thay đổi mà deployment đầu tiên đã chứa không có mẫu | Như trên | Đạt, như dòng trên |
| Bản ghi trạng thái hiện tại `inactive` mà danh sách còn `success` được tính kèm cảnh báo (hai bản ghi cùng R, bản đầu bị bản sau đặt `inactive`: vẫn một deployment, `deployed_at` của bản đầu); không còn `success` thì bị bỏ và liệt kê | Như trên | Đạt, như dòng trên |
| Prd không dữ liệu in "chưa có dữ liệu prd", chỉ số dưới ngưỡng in "chưa đủ dữ liệu" | Như trên | Đạt, như dòng trên |
| `GITHUB_TOKEN` của job repo code đọc được Deployment và trạng thái của repo public `svp-gitops` | Lượt dispatch đầu của `dora.yml`; lỗi thì đọc ẩn danh (60 request mỗi giờ) và đếm số request | Đạt (2026-10-30): `dora.yml` dispatch trên `main` [41022984599](https://github.com/anhnvcoder/short-video-platform/actions/runs/41022984599) xanh, đọc được bản ghi stg của `svp-gitops` (deployment frequency 1), không cảnh báo |
| Footer `Refs:` của PR revert còn trong commit squash của `svp-gitops` với hai cài đặt squash | Một PR revert thử trên `svp-gitops` sau khi tách, đọc `git log` | Chưa chạy (2026-10-30): chưa có PR revert thử; cài đặt squash của `svp-gitops` chưa đổi |
| Lượt `dora.yml` đầu sau một lượt `gitops` xanh trên `main` ra một deployment stg, lead time có số, các chỉ số tỷ lệ "chưa đủ dữ liệu" | Phần 4, **kiểm sau push** | **Một phần** (2026-10-30, [41022984599](https://github.com/anhnvcoder/short-video-platform/actions/runs/41022984599), artifact `dora.json`): ra một deployment stg (0,2 mỗi tuần); fail rate và rework "n = 1, cần ≥ 10: 0 / 1"; recovery n = 0; prd "no record of prd exists before prd runs for real"; promote stg 2, prd 1, trước khi tách repo 15. **Lead time không có số:** "chưa đủ dữ liệu (n = 0, cần ≥ 5)" dù đã có một deployment, khác kỳ vọng; có thể do thiết kế (bản ghi đầu tiên không có mốc trước), chưa kiểm |
| Sau lượt `gitops` xanh thứ hai trên `main`, bản ghi stg của lượt đầu vẫn có trạng thái hiện tại `success` (`auto_inactive: false`) | `GET .../deployments/{id}/statuses` của bản ghi đầu, phần 4, **kiểm sau push** | Chưa chạy (2026-10-30): mới có một bản ghi stg (Deployment `7433303337`, `success`), chưa có lượt `gitops` thứ hai trên `main` |
| Dòng 4: lượt lịch tuần của `verify.yml` chạy job `gitops` không chờ phát hành và ghi một bản ghi stg mỗi tuần, nên `dora.yml` (09:17 UTC) thấy deployment của tuần đó | Lượt lịch đầu sau merge (**kiểm sau merge**): job `gitops` có bước kịch bản xanh, `record-stg` ghi bản ghi `success`; lượt `dora.yml` cùng ngày đếm nó. Ca (c), (l) của `drill-k8s-supplychain` quá hạn thì SKIP ở lượt lịch, chỉ được chứng minh ở lượt dispatch chạy sau lượt dựng lại image diễn tập hay rescan (ADR-0021 mục 3) | Chưa chạy: lượt lịch đầu sau merge là thứ Bảy 2026-10-31. Nếu sai: tuần không có bản ghi khi `release-set` đỏ vì `main` của `svp-gitops` đổi giữa lượt (một PR promote stg của bot merge đúng lúc đó), hay khi artifact `web-sourcemaps-amd64` của bản web đang chạy đã hết hạn giữ của `images.yml` (bước `gitops-sourcemaps` đỏ trên `main`); tuần đó không có deployment, trần một deployment mỗi tuần thành ít hơn |

## Hệ quả

- **Được:**
  - Số của lab đọc được từ bằng chứng đã chạy, không từ merge; mỗi số có nhãn môi trường và nguồn, số thiếu mẫu không giả làm số thật.
  - Bản ghi stg phục vụ cả cổng prd (ADR-0024 §8) lẫn DORA: một dữ liệu, hai việc.
  - Không thêm dịch vụ, không token ghi, không phụ thuộc nền tảng ngoài các hàm `ci_*`.
- **Phải trả:**
  - Ở stg lab, số đo nhịp lượt runner hơn là nhịp giao hàng: deployment frequency bị trần bởi số lượt `gitops`, lead time gồm thời gian
    chờ tới lượt kế, và change fail rate gần như luôn thấp vì phép kiểm stg chặn lỗi trước khi có bản ghi. Không số nào so được với
    bảng của DORA.
  - Một người làm, mẫu nhỏ: nhiều tuần liền mọi tỷ lệ và trung vị sẽ là "chưa đủ dữ liệu".
  - Quy ước mới phải giữ bằng kỷ luật: front matter của postmortem, tiêu đề và footer của PR revert, cài đặt squash của `svp-gitops`; sai
    quy ước thì rollback không được đếm.
  - Tự viết, tự giữ: định nghĩa của DORA đổi (như năm 2023, 2024) thì script đổi theo.
- **Xem lại khi:**
  - Giai đoạn 7 có prd thật: ADR của giai đoạn 7 chốt bản ghi prd, DORA tính prd; xét lại xếp mức và `measure-gitops` khi stg, prd sống
    liên tục.
  - Lab có nhiều repo (phần 4b `svp-web`), nhiều người, hay một máy chủ thường trực: xét DevLake (đo RAM trước).
  - CI chạy thật trên GitLab: chốt chỗ giữ payload bản ghi (mục 9).
  - DORA công bố định nghĩa hay chỉ số mới.
- **Việc khi hiện thực** (ADR này không sửa file khác):
  - `docs/postmortems/README.md` và `docs/postmortems/261024-gameday-engagement-down.md`: front matter của mục 7.
  - `deploy/ci/platform.sh`, `deploy/ci/platform-test.sh`: hàm đọc Deployment nhận repo đích, trả payload và mọi trạng thái; hàm ghi
    trạng thái `success` với `auto_inactive: false`; script ghi bản ghi stg dùng đúng hàm đó.
  - `.github/workflows/ci.yml`: job `config` chạy `deploy/ci/dora-test.sh`.
  - `README.md` và cài đặt squash của `svp-gitops`: quy ước rollback (mục 5).
- **ADR khác cần ghi khi ADR này được chấp nhận:** [ADR-0023](0023-ci-platform-neutral.md) bảng ánh xạ (dòng đọc Deployment, GitLab không
  có payload); [ADR-0024](0024-multi-environment.md) §8 ghi "GitLab có deployments của environment ở gói Free": đúng, nhưng payload phải
  nằm chỗ khác; cũng ở §8, bản ghi stg phải tạo trạng thái `success` với `auto_inactive: false`, vì check PR prd và rollback prd
  (promote prd với một bản ghi stg cũ hơn) cần bản ghi cũ còn `success`, mà với mặc định bản ghi stg mới đặt nó thành `inactive` [N17]; [ADR-0025](0025-gitops-config-repo.md): cài đặt squash và quy ước rollback của `svp-gitops`. Lịch `gitops` (dòng 4) là
  thay đổi của [ADR-0021](0021-deferred-verification-stage6b.md).

## Hiện thực ở

Hiện thực 2026-10-29 (PR-B, nhánh `feat/stage6b-gitops-split`):

- `deploy/ci/dora.sh`: định nghĩa và cách tính của mục 2 đến 6 (danh tính (env, R, bộ), khử trùng lượt kiểm, lead time một mẫu mỗi
  thay đổi, rollback và revert theo mục 5, ngưỡng 10/5, "chưa đủ dữ liệu", "chưa có dữ liệu prd", số promote không tính commit khởi
  tạo của `svp-gitops`, cảnh báo khi danh sách chạm trần 100 bản ghi), bảng Markdown qua `ci_summary` và JSON.
  `deploy/ci/dora-test.sh`: dữ liệu giả cố định, chạy ở job `config` của `.github/workflows/ci.yml`.
- `.github/workflows/dora.yml`: lịch thứ Bảy 09:17 UTC, dispatch `days`, `contents: read` và `actions: read` (đọc lượt mà bản ghi trỏ
  tới), không secret, không environment; `make gitops-clone`; artifact `dora` (mục 8).
- `deploy/ci/platform.sh`: `ci_deployment_list` (trả payload và các trạng thái, tham số `states`), `ci_run_workflow`;
  `ci_deployment_record` ghi `success` với `auto_inactive: false` (dùng bởi `deploy/ci/record-stg.sh`); test ở
  `deploy/ci/platform-test.sh` (mục 9).
- `docs/postmortems/README.md` và `docs/postmortems/261024-gameday-engagement-down.md`: front matter của mục 7.
- Dòng 4 của "Cần người học chọn" (hiện thực 2026-10-30): job `gitops` của `.github/workflows/verify.yml` chạy cả ở lượt lịch tuần,
  `SVP_VERIFY_SCHEDULED` bỏ bước chờ phát hành và ca (c), (l) quá hạn của `drill-k8s-supplychain` (`deploy/ci/verify/gitops.sh`);
  `record-stg` ghi khi bước kịch bản xanh và `release-set.json` có trong artifact (ADR-0021 mục 3).
- Chưa kiểm: cài đặt squash của `svp-gitops` (mục 5).

## Nguồn

Đọc ngày 2026-10-28.

- [N1] DORA, "DORA's software delivery performance metrics" (cập nhật 2026-01-05): <https://dora.dev/guides/dora-metrics/>
- [N2] DORA, "A history of DORA's software delivery metrics" (2026-01-02): <https://dora.dev/insights/dora-metrics-history/>
- [N3] DORA, "Accelerate State of DevOps Report 2024" (v. 2024.3), tr. 11 (rework rate), tr. 13 (bốn mức hiệu năng):
  <https://dora.dev/research/2024/dora-report/2024-dora-accelerate-state-of-devops-report.pdf>
- [N4] Google Cloud, "Announcing the 2025 DORA Report" (2025-09-24, bảy hồ sơ nhóm):
  <https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report>
- [N5] `dora-team/fourkeys` (archived, push cuối 2024-01-23; README: kiến trúc Cloud Run, Pub/Sub, BigQuery, "not currently
  maintained"): <https://github.com/dora-team/fourkeys>
- [N6] Apache DevLake, "DORA" và "Docker Compose Setup" (bản Next); bản phát hành: <https://devlake.apache.org/docs/DORA/>,
  <https://devlake.apache.org/docs/GettingStarted/DockerComposeSetup>, <https://github.com/apache/devlake/releases>
- [N7] The Apache Software Foundation, "The Apache Software Foundation Announces New Top-Level Projects" (2025-10-07, DevLake, Grails):
  <https://news.apache.org/foundation/entry/the-apache-software-foundation-announces-new-top-level-projects-2>
- [N8] GitLab, "DORA metrics" (Ultimate; định nghĩa và Deployments API cho triển khai kiểu kéo):
  <https://docs.gitlab.com/user/analytics/dora_metrics/>
- [N9] GitLab, "Deployments API" (thuộc tính tạo deployment, lọc theo environment và status, gói Free):
  <https://docs.gitlab.com/api/deployments/>
- [N10] GitHub REST, "REST API endpoints for deployments" (`payload`, lọc `environment`, `ref`, `sha`; `production_environment` mặc định
  chỉ đúng khi environment tên `production`; không có endpoint sửa Deployment; repo có hơn một Deployment chỉ xoá được Deployment
  `inactive`): <https://docs.github.com/en/rest/deployments/deployments>
- [N11] GitHub REST, "Rate limits for the REST API" (ẩn danh 60 request mỗi giờ, `GITHUB_TOKEN` 1 000 request mỗi giờ mỗi repo):
  <https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api>
- [N12] Swarmia, "Pricing" (miễn phí dưới 10 developer, có DORA): <https://www.swarmia.com/pricing/>
- [N13] LinearB, "Pricing" (Essentials tối thiểu 50 user, dùng thử 45 ngày): <https://linearb.io/pricing>
- [N14] Business Wire, "Atlassian Completes Acquisition of DX, Advancing Engineering Intelligence for Enterprises" (2025-11-10):
  <https://www.businesswire.com/news/home/20251110683591/en/Atlassian-Completes-Acquisition-of-DX-Advancing-Engineering-Intelligence-for-Enterprises>
- [N15] Conventional Commits 1.0.0, FAQ "How does Conventional Commits handle revert commits?":
  <https://www.conventionalcommits.org/en/v1.0.0/>
- [N16] GitHub REST, "Update a repository" (`squash_merge_commit_title`, `squash_merge_commit_message`):
  <https://docs.github.com/en/rest/repos/repos#update-a-repository>
- [N17] GitHub REST, "REST API endpoints for deployment statuses" (mục "About deployment statuses": trạng thái trước đó giữ 90 ngày,
  trạng thái hiện tại lưu trên Deployment không bị ảnh hưởng; `auto_inactive` của "Create a deployment status", mặc định `true`):
  <https://docs.github.com/en/rest/deployments/statuses>
