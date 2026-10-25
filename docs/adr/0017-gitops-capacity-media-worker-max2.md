# 0017. media-worker tối đa 2 replica và tiêu chí ổn định (c): k3s server không restart trong diễn tập KEDA

- Trạng thái: Chấp nhận. Ghi chú 2026-10-24: phần kiểm lại dời "giai đoạn 7" (hai worker cùng transcode, RAM nghỉ) chuyển sang
  giai đoạn 6b "Kiểm chứng dồn" (runner CI 16 GB hay VM thuê theo giờ, không dịch vụ AWS/GCP); quyết định không đổi. Ghi chú
  2026-10-25: đường dev đã đo trên runner `ubuntu-24.04` 4 vCPU ([0021](0021-deferred-verification-stage6b.md), mục Kết quả): hai
  worker cùng transcode giữ (c) ở hai lượt, RAM nghỉ (b) đạt ở điểm 60 s; đỉnh (a) không đạt ngân sách của laptop, chấp nhận.
  Đường GitOps (hai lượt KEDA, RAM nghỉ) ở phần sau của giai đoạn 6b (ADR-0021 mục 5)
- Ngày: 2026-10-21

## Bối cảnh

- [ADR-0014 §2](0014-kubernetes-local-stage4.md#2-topology-và-ngân-sách-ram) đo cluster k3d `svp` chỉ bằng RAM: nghỉ
  > 6,5 GiB hay đỉnh > 8,7 GiB thì cắt lần lượt (1) Pyroscope, (2) metrics-generator của Tempo, (3) media-worker tối đa 2
  replica, (4) giới hạn và retention của Loki, Prometheus; nghỉ trên 6,5 GiB mà đủ (a) đỉnh dưới 8,7 GiB và (b) phần vượt
  là page cache thì ghi số, không cắt. Đỉnh đo "trong khi media-worker đủ 3 replica đang transcode" (diễn tập KEDA).
  [ADR-0015 §8](0015-cicd-devsecops-stage5.md#8-kyverno) thêm bước (1) tắt reports controller của Kyverno lên đầu thứ tự đó.
- [ADR-0014 §10](0014-kubernetes-local-stage4.md#10-workload): ScaledObject media-worker `maxReplicaCount: 3` "= 3
  partition của `video.lifecycle.v1`", mỗi worker giới hạn **2 CPU / 2 Gi** như compose (FF-3). Docker VM khoảng 9,7 GiB,
  8 vCPU.
- Diễn tập chuỗi cung ứng giai đoạn 5 đo lại trên cluster GitOps (có Argo CD và Kyverno, 23 Application), ngày
  2026-10-21:
  - **Lượt 1** (máy đang chạy song song test của việc khác, CPU host bị chia, nên số đỉnh không dùng được): nghỉ 8,14 GiB;
    `make drill-k8s-keda N=9` FAIL, k3s server chết `level=fatal "Transaction commit failed"` (kine/SQLite chậm), Docker
    khởi động lại container, mọi pod và Application tự hồi sau 13 phút.
  - **Lượt 2** (máy yên, cắm sạc, Low Power Mode tắt): nghỉ 6,93–6,97 GiB ở ba lúc đo, đủ (b) (tổng pod 4,34–4,44 GiB,
    MEM USAGE trừ `active_file` 5,92–6,17 GiB); đỉnh cửa sổ 6 mẫu có 3 worker cùng transcode **8,45 GiB**, mẫu cao nhất
    8,54 GiB, đủ (a). Theo quy tắc của ADR-0014 §2 là "ghi số, không cắt". Nhưng `drill-k8s-keda N=9` FAIL lần nữa: ~25 s
    sau khi 3 worker cùng transcode, compaction của kine chạy `SELECT` 8,25 s rồi `DELETE` 20,03 s, chạm hạn 20 s, k3s
    `level=fatal "Transaction commit failed"`; container `k3d-svp-server-0` restart (`RestartCount` 2, không OOM), API server
    mất 2,5 phút, drill dừng vì `curl` và `kubectl` không tới được cluster.
  - VM lúc đỉnh 3 worker của lượt 2: `/proc/stat` **99 % bận** trong 5 s (iowait 1 %), `MemAvailable` **1,06 GiB** trên
    9,70 GiB, swap đang dùng 679 MiB (35 s trước là 415 MiB). Ba worker đã giữ 6 trong 8 vCPU; phần còn lại chia cho k3s (API
    server, kine/SQLite), Argo CD, Kyverno, Prometheus, Redpanda. Đường dev cùng code (không Argo CD) đo đỉnh 7,92 GiB
    và không chết; giai đoạn 4 trên GitOps chưa từng có mẫu 3 worker cùng transcode.
- Như vậy ngưỡng RAM đạt mà cluster vẫn không đứng được: nghẽn là CPU (và swap đi kèm), thứ ADR-0014 §2 không đo. "Đạt"
  ở đây là (b) đo ở các lúc nghỉ muộn của lượt 2; ở điểm đo của ADR-0014 §2 (60 s sau khi mọi pod Ready) cả hai cluster
  GitOps thiếu (b), xem mục Kiểm chứng.

## Các lựa chọn

### A. Ghi nhận là rủi ro, không cắt

- Được: giữ 3 job transcode song song; không đổi gì.
- Mất: mỗi lần KEDA lên 3 trên cluster GitOps có thể làm API server chết vài phút (Argo CD, HPA, mọi `kubectl` đứng theo);
  `drill-k8s-keda` không PASS được, nên không còn bằng chứng scale-down giữa job không mất video.

### B. Cắt theo đúng thứ tự đã chốt: reports controller, Pyroscope, metrics-generator, rồi mới media-worker tối đa 2

- Được: theo đúng thứ tự của ADR-0015 §8 và ADR-0014 §2.
- Mất: ba bước đầu chỉ bớt RAM (~55, ~120, ~30 MiB lúc nghỉ), gần như không bớt CPU; mỗi bước phải dựng lại và đo lại
  cluster GitOps (một lượt KEDA ~20 phút), trong khi dự đoán là cả ba không đủ. Mất PolicyReport, profile, service graph
  mà không chữa được nguyên nhân.

### C. Đi thẳng tới bước 3: media-worker tối đa 2 replica

- Được: bớt đúng 2 vCPU lúc đỉnh (một worker transcode dùng trọn 2 CPU) và ~0,7 GiB RAM (một job 728–734 MiB), tác động
  thẳng lên cả CPU 99 % lẫn swap. Một dòng values; observability và Kyverno giữ nguyên.
- Mất: tối đa 2 job transcode cùng lúc thay vì 3, burst video chờ lâu hơn.

### D. Giữ 3 replica, hạ limit CPU của media-worker (ví dụ 1,5)

- Được: vẫn 3 consumer, mỗi partition một worker.
- Mất: tổng CPU của worker gần như không giảm khi cả ba cùng chạy, mỗi job chậm hơn; lệch với limit của compose (FF-3);
  không nằm trong thứ tự cắt đã chốt.

### E. Tăng CPU/RAM của Docker VM

- Được: không đổi gì trong cluster.
- Mất: máy 16 GB, VM lấy thêm thì macOS và compose (giai đoạn khác) thiếu; ngoài mọi ADR đã chốt về ngân sách.

## Quyết định

Chọn **C** (người học chọn ngày 2026-10-21).

1. **Tiêu chí ổn định (c)**, thêm vào (a), (b) của ADR-0014 §2: **k3s server không restart trong suốt `make
   drill-k8s-keda`**, tức container `k3d-svp-server-0` giữ nguyên `RestartCount` và `State.StartedAt` (đọc bằng
   `docker inspect` lúc đầu và lúc kết thúc diễn tập). Drill tự kiểm (c), kể cả khi nó dừng vì lỗi khác (API server mất
   thì `kubectl` lỗi trước, nhưng FAIL vẫn nêu restart); `docker inspect` không trả lời được cũng là FAIL, không tính là
   đạt. Thiếu (c) thì cắt như thiếu (a) hay (b).
2. **Thứ tự cắt khi thiếu (c):** đi thẳng tới bước 3 của ADR-0014 §2 (media-worker tối đa 2), bỏ qua reports controller
   (ADR-0015 §8), Pyroscope và metrics-generator: nguyên nhân là CPU, mỗi worker 2 vCPU, còn ba bước kia chỉ bớt RAM. Thiếu
   (a) hay (b) thì vẫn cắt theo thứ tự cũ.
3. **media-worker `maxReplicaCount: 2`** (`keda.maxReplicas` trong `deploy/k8s/values/services/media-worker.yaml`). Cả
   hai đường (dev `make k8s-up` và GitOps) đọc cùng file nên cả hai cùng tối đa 2: một file values cho mọi đường, dù đường
   dev đã chịu được 3.
4. **Topic `video.lifecycle.v1` giữ 3 partition**, thay ý "`maxReplicaCount` = số partition" của ADR-0014 §10: KEDA
   (`limitToPartitionsWithLag`) không xin quá một replica cho mỗi partition có lag, nên điều cần là số partition **≥**
   `maxReplicaCount`; với 2 worker, một worker giữ 2 partition. Không đổi số partition: Kafka không giảm được số partition của
   topic, tăng thì đổi ánh xạ khoá → partition; compose và cluster tạo topic bằng cùng `deploy/redpanda/create-topics.sh`.
5. **Cửa sổ đỉnh** của cách đo ADR-0014 §2 thành "6 mẫu liền trong khi đủ `maxReplicaCount` (2) worker cùng transcode".
6. **`drill-k8s-keda`** theo đó: điều kiện đầu là số partition ≥ `maxReplicaCount` ≥ 2; chờ `maxReplicaCount` replica
   Ready, mỗi pod giữ ít nhất một partition; ghim scale-down xuống `maxReplicaCount − 1` (1); đỉnh Ready phải đạt
   `maxReplicaCount`; vẫn upload tới khi record phủ đủ 3 partition (worker giữ 2 partition cũng có việc). N giữ mặc định 9,
   cận 6–12: 2 worker rút hàng chờ chậm hơn 3, nên lúc chọn pod để scale down còn nhiều record chờ hơn trước (cận dưới 6
   vẫn đủ); 12 video với 2 worker là 6 vòng ~45 s, dưới hạn 15 phút cho `READY`.

## Hệ quả

- Được: lúc đỉnh bớt 2 vCPU và ~0,7 GiB; dự báo (chưa đo) đỉnh GitOps ~7,8 GiB thay vì 8,45 GiB. Có tiêu chí đo được cho
  việc "cluster đứng được", không chỉ "RAM vừa".
- Phải trả: tối đa 2 job transcode song song; burst 9 video cần ~5 vòng thay vì ~3. Đường dev cũng mất worker thứ ba.
  Sau khi đổi, cluster GitOps phải đo lại: nghỉ, rồi `make drill-k8s-keda N=9` **hai lần**, cả hai PASS gồm (c).
- Kiểm chứng (2026-10-21): thay đổi vào `main` qua PR (`bea9954`), cluster GitOps dựng mới từ revision đó
  (`maxReplicaCount` = 2), cắm sạc, Low Power Mode tắt, ba lượt `make drill-k8s-keda N=9`:
  - (c) đạt cả ba lượt: `RestartCount` 0, `StartedAt` không đổi.
  - Drill FAIL, PASS, PASS. Lượt 1 là lượt duy nhất có 2 worker cùng transcode (~3,5 phút); giữa lúc đó node server đứng
    ~40 s: mọi probe của pod trên node timeout, Envoy Gateway mất leader, operator CloudNativePG và reports controller của
    Kyverno restart vì mất lease, Prometheus mất mẫu của node 75 s, k3s Slow SQL 1,5–14,3 s (không có compaction lúc
    đó). video-service hết endpoint Ready, gateway trả 503, drill dừng; cả 9 video vẫn `READY` sau đó. Lượt 2 và 3 đạt
    đủ (lên 2 replica, mỗi pod một partition, scale down giữa job, mỗi video transcode đúng một lần, về 1 replica sau
    ~290 s), nhưng hai worker transcode lần lượt, không có cửa sổ nào 2 worker cùng bận. Điều kiện "hai lần PASS gồm
    (c)" ở trên đạt theo số lượt, chưa đạt ở đỉnh 2 worker.
  - RAM: cửa sổ 6 mẫu có 2 worker cùng transcode 8,46 GiB, mẫu cao nhất 8,54 GiB: đủ (a), không thấp hơn đỉnh 3 worker
    như dự báo. Nghỉ ở dòng RAM của mục "Kiểm chứng sau phát hành" trong ADR-0015: ở điểm đo của ADR-0014 §2 (60 s sau
    khi mọi pod Ready) cả hai cluster GitOps thiếu (b), MEM USAGE trừ `active_file` 7,17–7,18 GiB so với ngưỡng 6,5 GiB;
    (b) chỉ đạt sau 70–90 phút (5,92–6,20 GiB). Chưa áp bước cắt nào; phần này kiểm lại ở giai đoạn 6b.
    Kết quả trên runner (2026-10-25, [ADR-0021](0021-deferred-verification-stage6b.md) D2, D9; số của amd64 không VM, so với
    ngân sách, không thay số của máy): **đường dev** (b) đạt ở điểm 60 s hai lượt, MEM USAGE trừ `active_file` 6 084 và 5 972
    MiB, tổng pod 3 163 và 3 024 MiB ([40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985),
    [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)); đỉnh (a) 9 994 và 8 878 MiB, không đạt ổn định 8,7 GiB, chấp nhận không cắt
    (ngân sách là của Docker VM trên laptop; xem lại khi chọn cỡ node ở giai đoạn 7). **Đường GitOps:** phần sau của giai đoạn
    6b (ADR-0021 mục 5, kịch bản `gitops`).
  - Máy host thiếu bộ nhớ suốt lúc đo (áp lực bộ nhớ của macOS ở mức cảnh báo, swap 15–17 GB); số đo không tách được
    phần do host và phần do VM.
  - Quyết định (người học, 2026-10-21): nhận (c) đạt 3/3, drill đạt 2/3, không đo lại ở local. Cluster local chứng minh
    logic scale 1 ↔ 2, scale down êm và transcode đúng một lần; lượt có 2 worker cùng transcode làm node server đứng ~40 s
    là giới hạn của máy lab, ghi là rủi ro mở. Hai worker cùng transcode trên node thật kiểm ở giai đoạn 6b.
    Kết quả trên runner 4 vCPU (2026-10-25, ADR-0021 D1, **đường dev**): `drill-k8s-keda N=9` PASS hai lượt có hai worker cùng
    transcode (137 s ở [40145677985](https://github.com/anhnvcoder/short-video-platform/actions/runs/40145677985), khoảng 80 s ở
    [40151447243](https://github.com/anhnvcoder/short-video-platform/actions/runs/40151447243)), (c) giữ (`RestartCount` 0, `StartedAt` không đổi),
    không node `NotReady`, CPU bận của máy tới 99 %: khác máy, k3s đứng được khi 4 vCPU bão hoà. Lượt thứ ba
    ([40160414327](https://github.com/anhnvcoder/short-video-platform/actions/runs/40160414327)) PASS, (c) giữ, nhưng không có khoảng hai worker cùng
    transcode: diễn tập không bảo đảm khoảng đó, độ dài của nó tuỳ cách chia partition. Hai lượt trên cluster GitOps, mỗi lượt
    ≥ 6 mẫu liền hai worker cùng transcode: phần sau của giai đoạn 6b (ADR-0021 mục 5, kịch bản `gitops`), sau khi xử lý cách
    chia partition của diễn tập.
- Xem lại khi:
  - (c) vẫn trượt với 2 worker: xét D (hạ limit CPU của worker) hay giảm CPU của thành phần khác, ghi bằng ADR mới.
  - Docker VM có thêm CPU, hay chuyển lên cluster cloud (giai đoạn 7) với node thật: tính lại `maxReplicaCount` theo CPU
    của node, tối đa bằng số partition.

## Hiện thực ở

- `deploy/k8s/values/services/media-worker.yaml`: KEDA scale media-worker tối đa 2 replica.
- `deploy/k8s/drills/keda.sh`: tiêu chí (c), k3s server không restart suốt diễn tập.
- `deploy/k8s/cloud/values/chaos-mesh.yaml`: Chaos Mesh chỉ cài trên cluster cloud, vì máy 16 GB không còn chỗ.
