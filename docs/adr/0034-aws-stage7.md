# 0034. Giai đoạn 7: biến thể AWS chạy trên EKS ở Singapore; hạ tầng là Terraform trong repo riêng `svp-infra` (module `terraform-aws-modules` bọc mỏng, mỗi env một cấu hình gốc, stg cắt chi phí và prd chuẩn production chỉ khác ở biến); RDS PostgreSQL và S3 + CloudFront là dịch vụ managed, Redpanda, Valkey và observability chạy trong cluster; khác biệt k3d/EKS là lớp `platforms/` của `svp-gitops` cùng giá trị theo cluster do bootstrap đặt; NLB L4 giữ IP client trước Envoy, TLS Let's Encrypt DNS-01, `X-Forwarded-For` giữ 1 hop

- Trạng thái: Chấp nhận. Người học trả lời ngày 2026-10-31 các dòng 2, 4, 5, 8 và mức chuẩn theo env (mục 20); các dòng còn lại
  theo đề xuất, người học duyệt kế hoạch ngày 2026-10-31. Chưa hiện thực; số đo của buổi AWS stg ghi vào cột Kết quả của mục Kiểm
  chứng sau. Chỉnh [0024](0024-multi-environment.md) §9 (nơi và tên thư mục Terraform; cách mô tả lớp nền tảng)
- Ngày: 2026-10-31

## Bối cảnh

- **Yêu cầu** (lộ trình, mục "7. AWS"): dựng cả hệ thống trên EKS, đạt SLO dưới tải k6, có báo cáo chi phí, destroy và quét không còn
  tài nguyên sót. ADR đầu giai đoạn phải so **ECS Fargate và EKS** (và App Runner nếu hợp) theo yêu cầu thật của hệ thống, nói rõ lúc nào
  ECS Fargate đúng hơn và giá của việc chọn EKS; chọn nơi đặt Terraform, một hay hai account, observability trên cloud, registry, Kafka và
  Redis managed hay trong cluster. Người học chia giai đoạn thành ba lớp (2026-10-31): **7a** (ADR này, một cluster stg, smoke và k6, destroy
  sạch), **7b** (cluster prd, promote stg → prd thật, Secrets Manager qua Pod Identity, trạng thái triển khai của [0032](0032-argocd-deploy-status.md)
  A và B, migration không downtime trên RDS), **7c** (tuỳ chọn từng mục: MediaConvert, video premium, nâng minor EKS, GitHub dưới dạng
  code, preview mỗi PR, Istio ambient, Falco, OpenCost, blackbox exporter, bản EKS tự viết ở `labs/`).
- **Hệ thống phải chạy** ([architecture §5.1](../architecture.md#51-triển-khai-trên-k3d-giai-đoạn-4)): 6 service Go và web, 25 component
  của `argocd/apps/components.json` theo wave (cert-manager, Envoy Gateway, External Secrets Operator, CloudNativePG, KEDA, Argo Rollouts,
  Kyverno, kube-prometheus-stack, Redpanda, Loki, Tempo, Pyroscope, Collector; chart `svp-data` gồm Postgres, Valkey, object store; chart
  `svp-observability` gồm GlitchTip). Những thứ đã gắn với
  Kubernetes: media-worker scale theo lag Kafka bằng KEDA; canary của gateway và web bằng Argo Rollouts, phân tích từ Prometheus
  ([0014](0014-kubernetes-local-stage4.md) §13); triển khai bằng Argo CD đọc `svp-gitops` ([0025](0025-gitops-config-repo.md)); Kyverno
  Enforce kiểm chữ ký keyless, attestation `vuln` và provenance ([0015](0015-cicd-devsecops-stage5.md) §8, [0027](0027-slsa-build-provenance.md));
  Secret do ESO dựng ([0026](0026-secrets-gitops.md)). RAM của cluster GitOps trên runner: nghỉ ~7,1 GiB, đỉnh ~8,7 GiB
  ([architecture §5.5](../architecture.md#55-hai-repo-code-và-cấu-hình-triển-khai-giai-đoạn-6b-phần-4)).
- **Tải:** NFR 1 000 req/s vào feed ([architecture §2](../architecture.md#2-yêu-cầu-phi-chức-năng)); Job k6 profile `cloud` của
  [0020](0020-reliability-stage6.md) §2. 7a đo bậc 1, 2, 4, 8 pod trên 3 node; 1 000 req/s với 20 pod là việc của prd ở 7b.
- **Ràng buộc:** ba repo đều public, nên không account ID, IP cá nhân, email hay tên miền thật nào vào file (ví dụ dùng `svp.example`,
  `000…`); AI không chạy lệnh nào chạm account AWS, người học chạy script viết sẵn; mỗi buổi dựng, đo, destroy trong tối đa 4 giờ; budget
  cảnh báo từ ngày đầu. Quyết định đã chốt (lộ trình, 2026-10-18): một instance Postgres cho mọi service, mỗi service database và role
  riêng; file gốc 30 ngày ở lớp chuẩn rồi Glacier Deep Archive, xoá sau 365 ngày; số hop `X-Forwarded-For` (RL-1) chốt lại ở giai đoạn 7
  theo kiến trúc load balancer thật.
- **Đã có sẵn cho cloud:** overlay `envs/prd/` của `svp-gitops` render được với store `aws` của ESO (region giữ chỗ `us-east-1`, role
  `svp-prd-external-secrets-<namespace>` với account giữ chỗ); `deploy/k8s/cloud/` (Chaos Mesh, Velero, Job k6) kiểm tĩnh bằng
  `make cloud-check`. [0024](0024-multi-environment.md) §9 để ngỏ hai việc cho ADR này: cách mô tả khác biệt của nền tảng (danh sách
  component theo nền tảng hay một lớp values giữa gốc và env) và tên thư mục Terraform.
- **Mẫu của người học** (`templates/terraform-base`): ECS Fargate, ba tầng account / platform / app, state S3 khoá native. Lấy cách làm
  (tầng account một lần mỗi account, mỗi env một state), không lấy nền tảng.

## Các lựa chọn

Số mục dưới đây là số của câu hỏi người học trả lời; dòng in đậm là lựa chọn.

### 1. Nền tảng chạy container

| Yêu cầu của hệ thống | EKS | ECS Fargate | App Runner |
| --- | --- | --- | --- |
| Trạng thái (đọc 2026-10-31) | Hiện hành; minor 1.34–1.37 ở standard support, 1.37 ra 2026-10-01 [N18] | Hiện hành; linear và canary có sẵn từ 2025-10 (ALB, Service Connect), thêm NLB từ 2026-02 [N17] | **Không nhận khách mới từ 2026-04-30**, không thêm tính năng, AWS khuyên ECS Express Mode [N16] |
| 6 service gRPC, web, worker không có HTTP | Chart `svp-service` chạy nguyên | 7 service, mỗi service một task definition; gRPC nội bộ qua Service Connect | Chỉ service HTTP; media-worker nghe Kafka không có chỗ |
| media-worker scale theo lag | KEDA như k3d | Application Auto Scaling theo metric CloudWatch: phải tự đẩy lag lên CloudWatch | Không |
| Canary có phân tích | Argo Rollouts, phân tích PromQL của 0014 §13 | Canary có sẵn, rollback theo CloudWatch alarm, hook kiểm tra: viết lại phân tích thành alarm | Không |
| GitOps, bản ghi stg, promote prd | Argo CD, `svp-gitops` chạy nguyên | Không controller kéo từ git: triển khai là pipeline hay Terraform đẩy | Như ECS |
| Policy lúc chạy (image ký, `vuln`, provenance) | Kyverno `svp-images` | Không admission: chỉ chặn được ở pipeline | Như ECS |
| Dữ liệu đang chạy trong cluster (Redpanda, Valkey, Prometheus, Loki, Tempo) | Chạy với PVC `gp3` | Chuyển sang managed (MSK, ElastiCache, Amazon Managed Prometheus) | Không chạy được |
| Phí nền | $0,10/cluster-giờ, $0,60 khi minor sang extended support [N1][N2] | Không phí control plane; Fargate ARM $0,04045/vCPU-giờ + $0,00442/GB-giờ ở Singapore [N15] | Đã đóng |
| Công vận hành | Nâng minor theo lịch (standard support ~14 tháng [N18]), addon, AMI node, ~10 controller mỗi cái một role IAM | AWS lo control plane; Fargate không có node | |

So một đơn vị tài nguyên: node `m7g.large` (2 vCPU, 8 GiB) on-demand $0,102/giờ ở Singapore [N3]; task Fargate ARM cùng cỡ
2 × 0,04045 + 8 × 0,00442 = $0,1163/giờ, đắt hơn ~14 % nhưng chỉ trả theo request của task (không có phần node trống hay DaemonSet).

### 2. Nơi đặt Terraform; repo public hay private

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Repo riêng `svp-infra`, public, clone ở `infra/` của workspace** | Mô phỏng team DevOps giữ hạ tầng; quyền plan/apply và CI tách khỏi repo code; một chỗ cho AWS (7), GCP (8), Cloudflare (8b) và GitHub dưới dạng code (7c); ruleset dùng được ở gói Free như hai repo kia | Thêm một repo; thay đổi chéo repo đi theo thứ tự |
| B. `deploy/terraform/` trong repo code (như lộ trình và 0024 §9 đề xuất) | Một PR đổi cả chart lẫn hạ tầng | Ai merge được code thì đổi được hạ tầng; CI của repo code thêm một mảng không liên quan tới service |
| C. Repo riêng, private | Giấu cấu hình mạng | Ruleset của repo private cần gói trả phí; lab học công khai; không thứ gì trong Terraform phải giấu khi biến cá nhân ở ngoài git |

### 3. Một hay hai account AWS

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Một account sandbox; mỗi env một state key và quyền riêng; prd thiết kế để dời sang account riêng ở 7b** | 7a chỉ có stg; không dựng Organizations khi chưa có env thứ hai; backend riêng mỗi env nên tách account sau chỉ đổi backend và provider (0024 §6A) | Ranh giới stg/prd ở 7a là IAM và state, không phải account |
| B. Organizations, account prd riêng ngay 7a | Chuẩn cao nhất (blast radius theo account) | Thêm SSO, SCP, budget mỗi account trước khi có prd |

### 4. Region

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. `ap-southeast-1` (Singapore)** | Gần Việt Nam (người dùng giả định của lab, độ trễ khi mở web và phát video); mọi dịch vụ dùng ở 7a đều có | Đắt hơn `us-east-1` ~14 % mỗi giờ của buổi với node Spot, ~21 % với on-demand (bảng mục Quyết định 12); overlay prd đang giữ chỗ `us-east-1` |
| B. `us-east-1` | Rẻ nhất; overlay prd đã ghi | Xa người dùng; k6 chạy trong cluster nên số đo như nhau, chỉ trải nghiệm tay khác |

So từng giá ở hai region (cùng nguồn [N1]–[N8], đọc 2026-10-31): `m7g.large` on-demand $0,102 so với $0,0816 (+25 %), Spot $0,0398 so
với $0,0367 (+8 %); NAT gateway $0,059 so với $0,045 mỗi giờ và mỗi GB (+31 %); NLB $0,0252 so với $0,0225 mỗi giờ (+12 %); RDS
`db.t4g.small` PostgreSQL single-AZ $0,051 so với $0,032 (+59 %); EBS gp3 $0,096 so với $0,08 mỗi GB-tháng (+20 %). EKS $0,10 như nhau.

### 5. Tên miền thật

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Domain người học đã có; uỷ quyền một subdomain `aws.<miền>` sang hosted zone Route 53 bằng bốn bản ghi `NS` ở DNS đang phục vụ domain** | Không mua gì; không đổi registrar hay name server của domain; zone Route 53 chỉ chứa phần của lab; ExternalDNS và cert-manager chỉ ghi được zone đó | Uỷ quyền phải lan truyền trước buổi đầu (bước tay riêng); zone giữ giữa các buổi ($0,50/tháng [N12]) |
| B. Mua domain mới | Tách hẳn khỏi domain cá nhân | Tiền và một registrar nữa |
| C. Không domain (tên của ELB, dịch vụ DNS wildcard công cộng) | Không chuẩn bị gì | Không có chứng chỉ công khai cho tên của ELB; origin của web và CORS gắn với tên đổi mỗi buổi |

### 6. Load balancer và TLS

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. NLB L4 (AWS Load Balancer Controller tạo từ Service của Envoy, target `ip`, giữ IP client) + Envoy kết thúc TLS bằng chứng chỉ Let's Encrypt (DNS-01 qua Route 53)** | Chart giữ nguyên Gateway HTTPS như k3d, chỉ đổi issuer; gateway vẫn tin đúng 1 hop (RL-1); không cần ACM | Giới hạn của Let's Encrypt (mục Quyết định 5); NLB không có tầng L7 (WAF gắn được vào ALB, CloudFront, không vào NLB) |
| B. ALB L7 + chứng chỉ ACM | Có WAF, ACM tự gia hạn | `X-Forwarded-For` thành 2 hop, mọi pod tới được Envoy ghi được hop đó (RL-7); chart đổi cách vào; hai lớp L7 nối tiếp |
| C. NLB listener TLS + ACM, Envoy nhận lại kết nối | Chứng chỉ ACM, vẫn L4 | Mất IP client nếu không bật Proxy Protocol v2 trên cả NLB lẫn Envoy; chứng chỉ trong cluster (giữa NLB và Envoy) vẫn phải có |

### 7. Cấp node

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Managed node group Graviton Spot ở 7a; Karpenter ở 7b** | Cluster sống vài giờ, cỡ cố định: ít thành phần nhất; Spot `m7g.large` $0,0398/giờ, 39 % giá on-demand ở Singapore [N4] | Spot có thể bị thu hồi giữa buổi; không học autoscale node ở 7a |
| B. EKS Auto Mode | AWS quản node (Karpenter bên trong), LB, EBS, network policy, Pod Identity agent [N22] | Phí quản lý $0,01224/giờ mỗi `m7g.large` ở Singapore (12 % giá EC2) [N1]; giấu đúng những thứ lab muốn học (controller, IAM của chúng) |
| C. Cluster Autoscaler | Quen thuộc | Chỉ scale số node của node group định sẵn loại instance; Karpenter chọn loại theo pod đang chờ |

Karpenter bản mới nhất v1.15.1 (2026-10-23) [N25].

### 8. Module Terraform

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Đường chính: `terraform-aws-modules/vpc` và `/eks` ghim version chính xác, bọc trong module nội bộ mỏng `aws/modules/<tên>`; RDS, S3, CloudFront tự viết từ resource; bản VPC + EKS tự viết từ resource là lab `labs/eks-from-scratch` của 7c** | Module phổ biến nhất, gói sẵn access entry, addon, Pod Identity, node group; module nội bộ cố định chuẩn của lab (tag, biến mức stg/prd, mặc định an toàn); phần nhỏ tự viết để học | Đọc code module để biết nó tạo gì (`plan` chỉ người học chạy); nâng major của module có breaking |
| B. Tự viết mọi resource ở đường chính | Hiểu từng resource | Đường chính lệch chuẩn ngành; nhiều code để giữ đúng |

Bản mới nhất lúc đọc: `terraform-aws-eks` v21.29.0 (2026-10-07), `terraform-aws-vpc` v6.7.3 (2026-09-18) [N28].

### 9. Observability trên cloud

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Stack trong cluster như k3d (7a)** | Canary của Rollouts, rule Sloth, cảnh báo, dashboard đã nối Prometheus trong cluster; không đổi gì | Tốn RAM node và PVC cho Prometheus, Loki, Tempo, Pyroscope |
| B. Amazon Managed Prometheus + Managed Grafana + X-Ray | Không vận hành backend | Đổi exporter, datasource của phân tích canary, cách cảnh báo; tính tiền theo mẫu |
| C. Grafana Cloud gói miễn phí | Không vận hành backend | Dữ liệu rời AWS; giới hạn gói |

B và C so ở 7c (`observability-managed-compare`); code không đổi vì đã dùng OpenTelemetry, chỉ đổi Collector.

### 10. Registry

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Giữ GHCR, kéo ẩn danh theo digest** | Chữ ký keyless, attestor Kyverno theo prefix, promote, rescan đều gắn GHCR | Kéo qua Internet và NAT (tính tiền theo GB) |
| B. ECR + OIDC từ CI | Kéo trong region, có VPC endpoint | Đổi prefix của mọi nguồn phát hành, policy, rescan, check của `svp-gitops`; làm ở 7c (`ci-oidc-ecr`) |

Image bên thứ ba kéo từ Docker Hub (Redpanda, Valkey, Envoy Gateway, Grafana, Loki, Pyroscope, Collector, GlitchTip và vài image khác) chịu
giới hạn ẩn danh **100 lượt mỗi 6 giờ cho mỗi IPv4** [N29]; mọi node ra Internet qua một IP NAT nên cả cluster chung một hạn mức.
Một lần dựng ước lượng vài chục lượt (chưa đếm chính xác); dựng lại nhiều lần trong 6 giờ thì có thể chạm.

### 11. Kafka, Redis

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Redpanda, Valkey trong cluster (7a)** | Không đổi chart, ACL, cấu hình service; dựng và xoá theo cluster | Không học dịch vụ managed; dữ liệu nằm trên PVC |
| B. MSK, ElastiCache | Managed, đa AZ | Tạo lâu, đắt nhất trong các thành phần (chưa kiểm giá ở ADR này); đổi SASL của Redpanda sang IAM hay SCRAM của MSK |

B xét ở 7b khi prd cần độ bền (tuỳ chọn).

### 12. Khác biệt k3d/EKS trong `svp-gitops`

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Lớp `platforms/{k3d,eks}/` giữa `base/` và `envs/`; giá trị phụ thuộc account hay buổi chỉ qua giá trị `cluster` của root do bootstrap đặt (kiểu GitOps Bridge [N38])** | `envs/stg` dùng chung cho k3d stg và EKS stg: bản ghi stg, promote prd, check không đổi; account, VPC, bucket không vào git | Thêm một lớp values và một hợp đồng giữa ba repo (mục Quyết định 7) |
| B. Env mới `stg-aws` | Không thêm khái niệm | Hai env cùng vai stg: promote, bản ghi, check nhân đôi; khác biệt nền tảng lẫn vào khác biệt env (0024 §9 tránh điều này) |
| C. Ghi giá trị của account vào repo public | Đơn giản nhất | Account ID, VPC, bucket công khai; đổi mỗi lần dựng lại |

### 13. Secret của EKS stg ở 7a

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. ESO provider `kubernetes` như stg lab, nguồn ở `svp-secrets` nạp bằng `make eks-secrets` (người học chạy)** | Cùng chart, cùng 28 ExternalSecret, cùng phép kiểm SEC-5…7 | Có `.env` trên máy người học cho stg EKS |
| B. Secrets Manager + Pod Identity ngay 7a | Đúng đích cuối | Overlay prd đã viết cho đường này; làm cùng prd ở 7b đỡ làm hai lần |

### 14. Cài Argo CD lên EKS

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Dùng lại `deploy/k8s/gitops.sh` qua lối vào EKS (`make eks-gitops-up CONTEXT=svp-stg CLUSTER_VALUES=<file>`); script buổi chỉ gọi nó** | Một bản cài đã kiểm (ghim SHA, kiểm bản phát hành, chờ Application, GlitchTip) cho cả k3d và EKS | Script buổi phải đọc output Terraform rồi gọi `make` của repo code |
| B. Provider Helm/Kubernetes của Terraform trong cùng cấu hình gốc với cluster | Một lệnh `apply` | Mô tả của provider Kubernetes khuyên quản cluster và tài nguyên trong cluster bằng hai lần `apply` riêng [N27]; viết lại cài Argo CD ở repo khác |

### 15. Kiểm IaC

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. `terraform fmt`/`validate`, tflint với ruleset AWS ghim version, trivy config bằng image ghim** | Hai công cụ, chạy trên máy và CI không credential | Không ước lượng chi phí trong PR |
| B. Thêm checkov | Thêm luật | Trùng phần lớn với trivy |
| C. Thêm Infracost comment PR | Chi phí trong PR | Cần API key (một secret của CI); người học chọn ở 7c |

### 16. Credential S3 của service

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. EKS Pod Identity (code Go thêm chế độ `S3_CREDENTIALS=container`)** | Không khoá dài hạn; association theo namespace + ServiceAccount, không cần OIDC provider; cùng cơ chế ESO dùng ở prd | Credential tạm hết hạn: form upload ký bằng nó cũng hết hiệu lực theo (mục Kiểm chứng sau) |
| B. IRSA | Như A | Cũ hơn, cần OIDC provider và annotation ServiceAccount |
| C. Access key của IAM user trong `.env` | Code không đổi | Khoá dài hạn (legacy) |

### 17. Major PostgreSQL trên RDS

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. 15 như local** | Test, bootstrap, migration chạy trên 15; RDS hết standard support cho 15 ngày 2028-02-29 [N37] | Không học nâng major |
| B. 17 hay 18 | Dài hơn | Lệch Postgres local và CloudNativePG; nâng major là bài riêng (7c cùng nâng EKS) |

### 18. Tên của CloudFront

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Tên mặc định `*.cloudfront.net` (7a)** | Không chứng chỉ, distribution dựng và xoá mỗi buổi | URL video đổi mỗi buổi (dữ liệu stg cũng đổi) |
| B. Tên riêng + chứng chỉ ACM | URL cố định | Chứng chỉ của CloudFront phải ở `us-east-1`; làm cùng bài video premium (7c) |

### 19. CloudFront tính tiền

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Pay-as-you-go (7a)** | Hạn mức miễn phí luôn có: 1 TB ra Internet, 10 triệu request HTTP(S), 2 triệu lần gọi CloudFront Functions mỗi tháng [N10]; không điều kiện gì thêm | Vượt hạn mức thì trả theo GB và request (nhóm có Singapore $0,120/GB ở bậc kế tiếp) [N10] |
| B. Flat-rate plan | Không phí vượt mức: Free $0 (100 GB, 1 triệu request), Pro $15, Business $200, Premium $1 000 mỗi tháng (50 TB; 10, 125, 500 triệu request), tính theo distribution, gồm WAF, chứng chỉ, DNS Route 53 [N10] | Vượt hạn mức thì "traffic delivery might be adjusted" (ít điểm edge hơn, xa hơn), đánh giá qua 2–3 tháng; bắt buộc gắn web ACL của WAF; không real-time log; account đang ở AWS Free Tier không đăng ký được; tối đa 3 plan Free mỗi account [N10]. Trang tài liệu không nói plan có dùng được với tên `*.cloudfront.net` hay không: **chưa kiểm** |

### 20. Mức chuẩn theo env

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **A. Một bộ module, stg cắt chi phí và prd chuẩn production, khác nhau chỉ ở biến** | 7b chỉ đổi biến và thêm một cấu hình gốc; điều đã chạy ở stg là cùng code với prd | Module phải có biến cho cả hai mức từ 7a |
| B. Hai bộ code | Mỗi bộ gọn | Lệch dần, điều kiểm ở stg không nói gì về prd |
| C. stg cùng mức prd | Giống nhau nhất | Gấp ~2 chi phí mỗi buổi stg (NAT mỗi AZ, RDS Multi-AZ, on-demand) |

## Quyết định

Chọn 1 EKS; 2A; 3A; 4A; 5A; 6A; 7A; 8A; 9A; 10A; 11A; 12A; 13A; 14A; 15A; 16A; 17A; 18A; 19A; 20A. Dòng 2, 4, 5, 8, 20 theo câu trả lời
của người học ngày 2026-10-31; các dòng còn lại theo đề xuất, người học duyệt kế hoạch ngày 2026-10-31.

### 1. Nền tảng: EKS 1.36

- **Vì sao EKS cho hệ thống này:** mọi thứ ở bảng mục 1 đã viết và kiểm trên Kubernetes (KEDA, Argo Rollouts với phân tích PromQL,
  Argo CD đọc `svp-gitops`, Kyverno với chữ ký và attestation, ESO, NetworkPolicy, PSA). Trên ECS mỗi thứ đó phải viết lại bằng dịch vụ
  AWS (alarm thay phân tích, pipeline đẩy thay GitOps kéo, chặn ở pipeline thay admission) và dữ liệu trong cluster phải thành managed.
  Lộ trình còn dùng EKS cho hai cluster (7b) và GKE (giai đoạn 8): một cách triển khai cho cả ba.
- **Lúc nào ECS Fargate đúng hơn** (câu trả lời của bài tập kiểu phỏng vấn SA): ít service (chục trở xuống), stateless HTTP và worker hàng
  đợi (SQS scale sẵn), team không có người vận hành Kubernetes, chỉ chạy trên AWS, dữ liệu đã ở dịch vụ managed, không cần công cụ của hệ
  sinh thái Kubernetes (GitOps kéo, admission policy, canary theo PromQL). Khi đó ECS bỏ được phí control plane, việc nâng minor và các
  controller; canary và rollback có sẵn [N17]. Mẫu `terraform-base` của người học chọn ECS Fargate đúng vì dự án khách thường như vậy.
  App Runner không còn là lựa chọn cho dự án mới [N16].
- **Giá của việc chọn EKS:** $0,10/giờ mỗi cluster (2 cluster chạy liên tục ≈ $146/tháng chỉ control plane; lab chỉ trả theo giờ của
  buổi), thành $0,60/giờ nếu để minor trôi sang extended support [N2]; nâng minor ít nhất mỗi ~14 tháng [N18]; ~10 controller (LBC,
  ExternalDNS, cert-manager, EBS CSI, metrics-server, ESO, KEDA, Rollouts, Kyverno, Argo CD) phải giữ version và quyền; node: Spot, AMI,
  drain; người vận hành phải hiểu cả Kubernetes lẫn IAM. Lab đã trả phần lớn công học đó ở giai đoạn 4–6b.
- **Minor của stg: 1.36.** Cùng minor với k3s v1.36.5 mà mọi chart, policy, drill đã kiểm trên đó; `podSecurityVersion: v1.36` của
  `envs/stg/charts.yaml` (lấy từ node k3d) khớp đúng API server; standard support tới 2027-08-02 [N18], đủ cho giai đoạn 7–9. 1.37
  (mới nhất, ra 2026-10-01) chưa kiểm với các chart; nâng 1.36 → 1.37 là bài `eks-minor-upgrade` của 7c. `CLOUD_K8S_VERSION` của
  `deploy/k8s/k8s.mk` (schema của `make cloud-check`, 0020 ghi "chốt lại theo EKS ở giai đoạn 7") theo 1.36.

### 2. Repo `svp-infra` và bố cục

Repo `anhnvcoder/svp-infra` (public, team DevOps giả định), bản clone ở `<workspace>/infra`. Cài đặt GitHub và ruleset theo
[runbook `svp-infra-setup.md`](../runbooks/svp-infra-setup.md).

```text
infra/                          repo svp-infra
  Makefile                      make check: fmt-check, validate (init -backend=false), tflint, trivy, shellcheck; make lock
  .tflint.hcl  .trivyignore.yaml  renovate.json
  .github/workflows/check.yml   PR và push main, chỉ contents: read, không secret, không OIDC; gọi make check
  aws/
    bootstrap/                  một lần mỗi account, giữ giữa các buổi: bucket state, budget, hosted zone aws.<miền>
    modules/
      network/                  bọc terraform-aws-modules/vpc
      eks/                      bọc terraform-aws-modules/eks: cluster, node group, addon, Pod Identity cho controller
      rds/                      RDS PostgreSQL (tự viết)
      media/                    S3 uploads, media + CloudFront OAC, policy IAM của hai service (tự viết)
    envs/
      stg/                      cấu hình gốc của stg: backend S3 key aws/stg/terraform.tfstate, output cluster_values
      prd/                      7b
    scripts/                    script buổi: kiểm account, kiểm DNS, bootstrap Argo CD, đo, pre-destroy, sweep
  docs/runbooks/session-stg.md  trình tự buổi AWS stg
  gcp/ cloudflare/ github/      giai đoạn 8, 8b, 7c
```

- **Tầng** (so với mẫu `terraform-base`): `aws/bootstrap` là tầng account (tạo một lần, không nằm trong buổi); `aws/envs/<env>` là tầng
  platform (mạng, cluster, dữ liệu của một env); tầng app **không** ở Terraform mà là GitOps (Argo CD đọc `svp-gitops`). Lý do: cái chạy
  trong cluster đã có cổng riêng (bản ghi stg, promote prd, Kyverno), Terraform không nên giữ trạng thái thứ hai của nó.
- **State:** bucket do `aws/bootstrap` tạo (versioning, SSE-S3, chặn public, `BucketOwnerEnforced`, chỉ TLS, `prevent_destroy`), khoá
  native của backend S3 (`use_lockfile = true`; khoá DynamoDB đã deprecated [N26]); mỗi env một key; state của chính bootstrap lúc đầu
  local rồi chuyển vào bucket. Tên bucket, region nạp từ `backend.hcl` không commit.
- **Biến cá nhân** (CIDR được gọi API EKS, email budget và ACME, tên subdomain) chỉ qua `*.auto.tfvars` không commit hay `TF_VAR_*`; repo
  có file `.example`. Không tên nào ghép từ account ID.
- **CI** chỉ kiểm tĩnh (Terraform, tflint, trivy chạy bằng image hay bản tải ghim), không credential AWS ở 7a; đăng nhập CI vào AWS bằng
  OIDC là việc của 7c. Mọi `plan`, `apply`, `destroy` do người học chạy từ máy bằng SSO, theo script và runbook của repo.
- **Thay đổi chéo ba repo** đi theo thứ tự: code (chart nhận giá trị mới, mặc định giữ render cũ) → `svp-gitops` (lớp `platforms/`, nâng
  `CHECKER_COMMIT`) → `svp-infra` (output khớp hợp đồng). Thêm khoá vào hợp đồng `cluster.*` thì sửa cả bốn nơi của mục 7.
- **Chỉnh 0024 §9:** thư mục Terraform là `aws/envs/<env>/` và `aws/modules/` của repo `svp-infra`, không phải
  `deploy/terraform/envs/aws/<env>/` của repo code; tên `envs/{aws,gcp,cf}` của lộ trình thành thư mục cấp một `aws/`, `gcp/`,
  `cloudflare/`.

### 3. Account và quyền

- Một account sandbox cho 7a, profile SSO của người học; trước mọi lệnh ghi, `aws sts get-caller-identity` với cùng profile, hai bên
  cùng đọc account (script kiểm so với biến môi trường, không ghi account vào file).
- Mỗi env một backend (state, khoá) và một cấu hình gốc. 7b xét account prd riêng (Organizations, SSO theo account); khi đó chỉ đổi backend
  và provider của `aws/envs/prd`.
- Budget tháng của account (cảnh báo email 50/80/100 % thực tế và 100 % dự báo) tạo ở `aws/bootstrap`; theo dõi và nhận thông báo của
  budget miễn phí [N13]. Cost Anomaly Detection người học bật bằng tay (bản mặc định "no effort or cost" theo FAQ [N14]).

### 4. Region

`ap-southeast-1` cho mọi thứ của 7a. Hệ quả: overlay prd của `svp-gitops` (region của store `aws` đang giữ chỗ `us-east-1`) đổi sang
`ap-southeast-1` ở 7b; chứng chỉ ACM cho tên riêng của CloudFront (7c) vẫn phải ở `us-east-1`.

### 5. DNS, TLS, load balancer và `X-Forwarded-For`

- **DNS:** hosted zone `aws.<miền>` (ví dụ `aws.svp.example`) ở `aws/bootstrap`, giữ giữa các buổi. Uỷ quyền bằng bốn bản ghi `NS` ở DNS đang
  phục vụ domain là **bước tay trước buổi đầu**, vài ngày trước (không đổi gì khác của domain); mỗi buổi bắt đầu bằng phép kiểm
  `dig NS aws.<miền> +short` ra đúng bốn name server của zone, sai thì không `apply`. Tên của stg là biến, ví dụ web
  `stg.aws.svp.example`, API `api.stg.aws.svp.example` (khoá `domain` của hợp đồng). ExternalDNS (nguồn `gateway-httproute`,
  `policy: sync`, `txtOwnerId` là tên cluster, chỉ zone của `hostedZoneId`) ghi bản ghi trỏ NLB.
- **TLS:** cert-manager, issuer ACME Let's Encrypt **production** cho buổi đo, DNS-01 qua Route 53 bằng Pod Identity; chứng chỉ wildcard
  cho các tên dưới `<domain>` và chứng chỉ riêng cho tên gốc (listener `https-apex`, như k3d). Giới hạn [N30]: 5 chứng chỉ cho cùng một bộ
  tên mỗi 7 ngày (mỗi buổi xin hai bộ, nên tối đa 5 buổi/tuần với cùng tên), 50 chứng chỉ mỗi registered domain mỗi 7 ngày (chung với mọi
  dùng khác của domain gốc), 5 lần xác thực lỗi mỗi tên mỗi giờ. Staging có giới hạn cao hơn nhưng smoke và k6 không tin chứng chỉ của nó:
  chỉ dùng khi thử riêng issuer.
- **Load balancer:** AWS Load Balancer Controller tạo NLB `internet-facing` từ Service của Envoy (`aws-load-balancer-type: external`,
  `aws-load-balancer-nlb-target-type: ip`, thuộc tính target group `preserve_client_ip.enabled=true` [N32]); với target `ip` và TCP, giữ IP
  client **mặc định tắt** nên phải bật [N31]. Listener chỉ TCP 443; NetworkPolicy của Envoy mở cổng listener cho mọi nguồn (IP client thật)
  và health check từ CIDR của VPC. NAT loopback (hairpin) không chạy khi giữ IP client [N31]: không pod nào được gọi tên công khai của
  chính cluster qua NLB. Job k6 đã thoả: nó phân giải tên công khai về ClusterIP của Envoy (`deploy/k6/cloud/render.sh`), nên đo hệ thống,
  không đo NLB; web gọi gateway bằng tên Service.
- **`X-Forwarded-For` (chốt RL-1):** không có L7 nào trước Envoy, nên gateway giữ **1 hop** như k3d:

  | Môi trường | `TRUSTED_PROXY_HOPS` | `TRUSTED_PROXY_CIDRS` | Ai là hop tin cậy |
  | --- | --- | --- | --- |
  | compose | 0 | — | không: địa chỉ kết nối |
  | k3d | 1 | `10.42.0.0/16` (dải pod) | Envoy |
  | EKS | 1 | CIDR của VPC (`cluster.vpcCidr`): VPC CNI cấp IP pod từ subnet của VPC | Envoy, thấy IP client thật nhờ NLB giữ IP |

  Dải tin cậy rộng hơn dải của Envoy (như k3d), nên NetworkPolicy của gateway (chỉ nhận từ Envoy và web) là thứ giữ cho pod khác không tự
  làm hop tin cậy. Job k6 không cần `--forwarded-for`: mỗi pod tới Envoy bằng IP của nó, mỗi pod một khoá rate limit theo IP (RL-7).
- **Endpoint API của EKS:** public giới hạn CIDR của người học (biến không commit, không bao giờ `0.0.0.0/0`), private luôn bật để node và
  pod tới API trong VPC (giới hạn CIDR mà tắt private thì node đi qua IP NAT nằm ngoài danh sách; tài liệu EKS khuyên bật private khi giới
  hạn CIDR [N23]). API server nghe 443 (k3s 6443): value `kubeAPIPort` của `svp-cluster` cho NetworkPolicy `allow-kube-api` (đích sau DNAT
  của kube-proxy là ENI của control plane trong VPC, nên `nodeSubnet` = CIDR VPC, cổng 443). `authentication_mode = API` (access entry),
  quyền admin chỉ cho người tạo.

### 6. Node

- Managed node group Graviton (arm64, cùng kiến trúc với máy dev; image phát hành đa kiến trúc), `m7g.large` × 3, **Spot** cho stg, danh
  sách loại thay thế cùng cỡ qua biến (Spot Singapore lúc đọc: `m7g.large` $0,0398, `m6g.large` $0,0409, `t4g.large` $0,0322 mỗi giờ [N4]).
  3 × 8 GiB cho RAM đo trên k3d (~7–9 GiB) cộng phần hệ thống của EKS và chỗ cho k6. Node thêm cho k6 bậc 4–8: `aws eks update-nodegroup-config`
  trong buổi (module cộng đồng `ignore_changes` `desired_size` sau khi tạo, nên biến không đổi được số node đang chạy).
- Addon: `vpc-cni` (bật network policy agent, cần VPC CNI ≥ 1.21.0 [N20]; prefix delegation), `coredns`, `kube-proxy`,
  `eks-pod-identity-agent`, `aws-ebs-csi-driver` (Pod Identity), `metrics-server` (addon **community** của EKS: AWS chỉ hỗ trợ thao tác
  cài và gỡ qua API [N19]; k3s có sẵn metrics-server, EKS không, mà HPA CPU của gateway, feed-service cần nó).
- IMDSv2 bắt buộc với hop limit 1 trên node: pod không lấy được credential của node. Module EKS từ v21 để hop limit 1 khi không đặt, và
  driver EBS CSI phía node khi đó phải lấy metadata từ Kubernetes thay vì IMDS (bài viết của Classmethod về lỗi sau khi nâng module [N39]).
  Vì vậy controller nào cần region hay VPC (LBC) nhận chúng qua values từ `cluster.*`, không đọc IMDS.

### 7. Lớp nền tảng và hợp đồng giá trị theo cluster

- Repo `svp-gitops` thêm giá trị `platform` (`k3d` | `eks`, bắt buộc như `env`) cho root `svp-root`, thư mục `platforms/<platform>/` và trường
  `platforms` của mỗi component trong `components.json` (vắng = mọi nền tảng; LBC, ExternalDNS chỉ `eks`; CloudNativePG và plugin Barman
  Cloud chỉ `k3d`). Mỗi Application đọc values theo thứ tự `base/` < `platforms/<platform>/<tên>.yaml` < `envs/<env>/<tên>.yaml` <
  `envs/<env>/images/` < phần sinh từ mẫu `platforms/<platform>/<tên>.values.tpl` (Helm `tpl` trên `.Values.cluster`, đặt vào
  `helm.valuesObject`). Render `env=stg platform=k3d` phải ra đúng các Application như trước khi có lớp này.
- **Hợp đồng `cluster.*`**: giá trị phụ thuộc account hay buổi, không bao giờ vào git.

  | Khoá | Nghĩa, ai dùng |
  | --- | --- |
  | `name` | Tên cluster EKS (`svp-stg`): `clusterName` của LBC, `txtOwnerId` của ExternalDNS |
  | `region` | Region: LBC, ExternalDNS, cert-manager, endpoint S3 vùng |
  | `vpcId` | VPC: LBC (không đọc IMDS) |
  | `vpcCidr` | CIDR VPC: `TRUSTED_PROXY_CIDRS` của gateway, `nodeSubnet` của `svp-cluster` và `svp-observability`, health check NLB |
  | `serviceCidr` | Dải Service của EKS: `kubeAPIServiceIP` (địa chỉ `.1`) |
  | `dbCidrs` | Subnet của RDS (list): egress 5432 của service có database, Job bootstrap, GlitchTip |
  | `domain` | Tên web stg; API là `api.<domain>`: host của route, `APP_ORIGIN`, origin CORS của bucket |
  | `hostedZoneId` | Zone Route 53 của lab: ExternalDNS, issuer ACME |
  | `acmeEmail` | Email tài khoản ACME |
  | `rdsAddress` | Endpoint RDS: `postgres.external.host` (Service `ExternalName` `svp-pg-rw` của `svp-data`) |
  | `uploadsBucket` | Bucket `uploads`: `UPLOAD_ORIGIN` của web `https://<uploadsBucket>.s3.<region>.amazonaws.com` (virtual-hosted) |
  | `mediaBucket` | Bucket `media` |
  | `mediaDomain` | Tên `*.cloudfront.net` của distribution: `MEDIA_ORIGIN` của web, `MEDIA_PUBLIC_BASE_URL` của gateway |
  | `s3Cidrs` | Các dải IPv4 AWS công bố cho S3 của region (list; output Terraform từ `data "aws_ip_ranges"`, đọc lại mỗi lần `apply`): egress 443 tới S3 (`externalPeers.s3`) của video-service, media-worker |

  **Ai ghi:** output `cluster_values` (một map) của `aws/envs/<env>`; script buổi ghi nó ra file rồi `make eks-gitops-up
  CLUSTER_VALUES=<file>` đặt thành `helm.valuesObject.cluster` của root. **Ai đọc:** mẫu `platforms/eks/*.values.tpl` của `svp-gitops`;
  check (`deploy/ci/gitops-check.sh`) render bằng fixture `deploy/ci/cluster-values.example.yaml` (tên `.example`, CIDR tài liệu, account
  toàn số 0). File nào trong git đặt `cluster` thì check đỏ. Thêm khoá thì sửa cả bốn nơi: output Terraform, mẫu của `svp-gitops`, fixture,
  bảng này.

### 8. Thành phần local → AWS

| Thành phần | k3d (giai đoạn 4–6b) | EKS stg (7a) |
| --- | --- | --- |
| Control plane | k3s server trong container, API `127.0.0.1:6550` (trong cluster 6443) | EKS managed, $0,10/giờ; API 443 (value `kubeAPIPort`); endpoint public giới hạn CIDR, private luôn bật |
| Node | 1 server + 1 agent arm64 trên Docker Desktop | Managed node group 3 × `m7g.large` Graviton Spot, 2 AZ, subnet private |
| CNI, NetworkPolicy | flannel, network policy controller của k3s | VPC CNI (IP pod lấy từ subnet VPC), network policy agent của VPC CNI |
| Service `LoadBalancer` | serverlb của k3d + svclb | AWS Load Balancer Controller → NLB `internet-facing`, target `ip`, giữ IP client |
| Ingress | Envoy Gateway, Gateway `svp` | Như k3d |
| TLS | cert-manager, CA tự ký, `*.svp.localhost` | cert-manager, ACME Let's Encrypt DNS-01 qua Route 53 |
| DNS | `*.localhost` phân giải về loopback | Zone Route 53 `aws.<miền>` (uỷ quyền từ DNS của domain), ExternalDNS từ HTTPRoute |
| metrics-server | k3s có sẵn | Addon `metrics-server` của EKS (community) |
| CoreDNS, kube-proxy | k3s có sẵn | Addon EKS |
| StorageClass mặc định | `local-path` của k3s; `base/` ghim `local-path` ở Loki, Prometheus, Alertmanager, Tempo, Pyroscope | `gp3` (EBS CSI, mã hoá, `WaitForFirstConsumer`, `reclaimPolicy: Delete`) do chart `svp-cluster` tạo và đánh dấu mặc định; `platforms/eks/` đè các chỗ ghim `local-path`. Addon EBS CSI không tạo StorageClass, EKS từ 1.30 không còn đánh dấu `gp2` là mặc định [N24] |
| Postgres | CloudNativePG `svp-pg`, backup Barman Cloud lên object store trong cluster | RDS PostgreSQL 15 single-AZ, backup tự động; Service `ExternalName` `svp-pg-rw` giữ chuỗi kết nối `svp-pg-rw.svp-data:5432` |
| Object store | RustFS `s3` (StatefulSet), route `s3.<host>`, user và policy theo service | S3 `uploads`, `media`; upload thẳng tới endpoint vùng (virtual-hosted); credential Pod Identity |
| CDN | Không có | CloudFront trước `media` bằng OAC, tên `*.cloudfront.net` |
| Redis | Valkey trong cluster | Như k3d (ElastiCache tuỳ chọn ở 7b) |
| Kafka | Redpanda SASL + ACL | Như k3d, PVC `gp3` |
| Secret | ESO provider `kubernetes`, nguồn `svp-secrets` từ `.env` | Như k3d; mật khẩu master của RDS lấy từ Secrets Manager (RDS giữ) lúc nạp nguồn; prd: Secrets Manager + Pod Identity (7b) |
| Quyền AWS của pod | Không có | Pod Identity: role cho video-service, media-worker, LBC, ExternalDNS, cert-manager, EBS CSI |
| Registry | GHCR theo digest (đường dev: registry k3d) | GHCR theo digest, kéo ẩn danh qua NAT |
| Policy image | Kyverno Enforce (stg) | Như k3d |
| GitOps | Argo CD, root `env=stg` | Argo CD, root `env=stg`, `platform=eks`, `cluster` từ Terraform |
| Quan sát | kube-prometheus-stack, Loki, Tempo, Pyroscope, Collector, GlitchTip trên `svp-pg` | Như k3d, PVC `gp3`, database `svp_glitchtip` trên RDS |
| Autoscale | KEDA theo lag, HPA CPU | Như k3d (HPA nhờ addon metrics-server); node cố định ở 7a, Karpenter ở 7b |
| Canary | Argo Rollouts, plugin Gateway API | Như k3d |
| Pod tới API server | `nodeSubnet` cổng 6443, `kubeAPIServiceIP` 443 | `nodeSubnet` = CIDR VPC cổng 443, `kubeAPIServiceIP` = `.1` của dải Service EKS |
| Egress ra mạng ngoài | Không cần (trừ GHCR của node) | NAT gateway (1 ở stg); S3 qua gateway endpoint miễn phí; pod cần credential tới agent `169.254.170.23` TCP 80 |
| Tải k6 | Job trên k3d của runner | Job `svp-load` qua `deploy/k6/cloud/run.sh --context svp-stg` |
| Hạ tầng | `make k8s-up` / `k8s-gitops-up` | Terraform `aws/envs/stg` + `make eks-gitops-up` |

### 9. Dữ liệu

- **RDS:** một instance cho mọi service (quyết định 2026-10-18), PostgreSQL 15, `db.t4g.small`, gp3 20 GB, subnet group private, không
  public, security group chỉ nhận 5432 từ security group của node và cluster, `rds.force_ssl = 1`, mã hoá lưu trữ, mật khẩu master do RDS
  giữ ở Secrets Manager (`manage_master_user_password`, không vào state). **Master username cố định `postgres`**: là tên mặc định của RDS
  PostgreSQL, hợp luật 1–16 ký tự gồm chữ, số, gạch dưới, bắt đầu bằng chữ [N41]; ExternalSecret `pg-superuser` của chart `svp-cluster` đã ghim
  `username: postgres` và nguồn chỉ mang mật khẩu, nên một tên ở mọi nền tảng, không thêm biến. User này thuộc `rds_superuser`, có
  `CREATEROLE`, `CREATEDB`, **không** phải superuser [N36]: `deploy/postgres/bootstrap.sql` phải chạy được dưới quyền đó (và vẫn đúng dưới
  superuser local). Job `pg-bootstrap` nối với `PGSSLMODE=require`.
- **S3:** bucket `uploads`, `media` tên `<tiền tố>-uploads-<hậu tố ngẫu nhiên>`, chặn public, `BucketOwnerEnforced`, SSE-S3, CORS theo bucket
  như local (`uploads` chỉ `POST`, `media` chỉ `GET`, `HEAD`, origin của web), lifecycle của `uploads` theo quyết định 2026-10-18 cộng huỷ
  multipart dở sau 1 ngày; stg `force_destroy`. Policy IAM của video-service và media-worker dịch đúng policy theo tiền tố của store local
  (`deploy/s3/*-policy.json`), không rộng hơn. Code dùng ghi có điều kiện `If-None-Match: *` (S3 nhận ở PutObject, CompleteMultipartUpload
  [N33]) và CRC32 full-object cho multipart (S3 nhận CRC32 full-object [N34]).
- **CloudFront:** OAC, bucket `media` chỉ cho distribution này đọc (`AWS:SourceArn`), viewer HTTPS, cache policy theo `Cache-Control` của
  object (HLS mang `immutable`), cache key bỏ query và cookie, header CORS của `media` qua origin request/response headers policy, **price class
  `PriceClass_200`** (gồm nhóm Singapore, Việt Nam; bỏ Nam Mỹ, Úc [N10]), pay-as-you-go. URL HLS là `https://<mediaDomain>/` + khoá của
  object trong bucket `media` (không có hậu tố `/media` như đường path-style của k3d).

### 10. Secret, IAM và Pod Identity

- 7a: ESO provider `kubernetes` như stg lab, `make eks-secrets CONTEXT=svp-stg` ghi nguồn ở `svp-secrets`; riêng mật khẩu master RDS script
  buổi đọc từ secret do RDS giữ vào biến môi trường (không ra file, không in) rồi ghi vào nguồn `pg-superuser`. Khi object store ở ngoài,
  chart không render `s3-root`, `s3-users`, `pg-backup-s3` và bỏ khoá S3 tĩnh khỏi Secret của video-service, media-worker.
- Pod Identity: association theo namespace + ServiceAccount, mỗi role một policy hẹp: video-service, media-worker (S3 theo tiền tố), LBC
  (policy chính thức ghim theo version controller), ExternalDNS và cert-manager (chỉ zone lab), EBS CSI. Agent nghe `169.254.170.23` cổng
  80, credential tới pod qua `AWS_CONTAINER_CREDENTIALS_FULL_URI` và `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` [N21]; NetworkPolicy chỉ mở
  `169.254.170.23/32` TCP 80 cho pod cần, không mở `169.254.0.0/16`. Trang tài liệu không ghi thời hạn của credential tạm (mục Kiểm chứng
  sau).
- Egress tới S3 (threat model FF-5): NetworkPolicy của video-service, media-worker chỉ mở TCP 443 tới `s3Cidrs` và agent Pod Identity, không bao giờ
  `0.0.0.0/0`; S3 đi qua gateway endpoint của VPC, chưa có endpoint policy. Rủi ro còn lại, **chấp nhận ở stg**: luật theo địa chỉ không phân
  biệt bucket, nên media-worker đã bị chiếm bằng file dựng sẵn chép được file gốc của `uploads` (role của nó đọc được) sang một bucket lạ
  nhận ghi trong region. Cần chạy được code trong worker trước; stg chỉ có dữ liệu thử và chỉ sống trong buổi. Không làm ngay vì endpoint
  policy thiếu một bucket mà node cần (bucket layer ECR của region, nơi node kéo image addon của EKS) thì node không kéo được image và buổi
  đo tính tiền hỏng. **Trước prd (7b):** endpoint policy chỉ bucket `uploads`, `media` của env cộng bucket layer ECR của region, kiểm trong
  một buổi stg rồi mới áp cho prd; khi đó FF-5 đóng.
- 7b: Secrets Manager `svp/prd/<entry>`, store `aws` mỗi namespace assume một role chỉ đọc entry của nó (0026).

### 11. Mức chuẩn theo env và bảng biến

prd làm chuẩn production (NAT mỗi AZ, RDS Multi-AZ, node trải nhiều AZ, backup và bảo vệ xoá, không Spot cho phần stateful); stg cắt chi phí
(một NAT, RDS một AZ, Spot, dịch vụ trong cluster khi hợp). Một bộ module, khác ở biến; module có biến cho cả hai mức từ 7a. Tên biến chính
xác do module chốt; cột prd là hướng, cỡ đo từ k6 trên stg ở 7b.

| Module | Biến | stg (7a) | prd (7b) |
| --- | --- | --- | --- |
| network | số AZ | 2 | 3 |
| network | `single_nat_gateway` | `true` (một NAT) | `false` (một NAT mỗi AZ, route table private mỗi AZ) |
| network | flow log | tắt | bật, retention chốt ở 7b |
| eks | version | `1.36` | như stg lúc dựng |
| eks | endpoint public | CIDR của người học | CIDR của người học hay chỉ private, chốt ở 7b |
| eks | `capacity_type` | `SPOT` | `ON_DEMAND` |
| eks | loại node, min/desired/max | `m7g.large` (cùng cỡ thay thế), 3/3/5 | trải 3 AZ, cỡ đo ở 7b |
| eks | log control plane | tắt | `api`, `audit` |
| rds | lớp | `db.t4g.small` | đo ở 7b |
| rds | `multi_az` | `false` | `true` |
| rds | `backup_retention_period` | 1 | chốt ở 7b (≥ 7) |
| rds | `deletion_protection` | `false` | `true` |
| rds | `skip_final_snapshot` | `true` | `false` |
| media | `force_destroy` | `true` | `false` |
| media | price class | `PriceClass_200` | `PriceClass_200` |

### 12. Chi phí 7a (Singapore)

Giá on-demand công khai, đọc ngày 2026-10-31 (bảng giá của trang giá AWS và AWS Price List công khai; ngày phát hành của tệp giá ghi ở
mục Nguồn). Spot đổi theo giờ.

| Hạng mục | Giá (nguồn, ngày đọc) | Mỗi giờ của buổi stg |
| --- | --- | --- |
| EKS control plane | $0,10/cluster-giờ; extended support thêm $0,50 [N1][N2], 2026-10-31 | $0,100 |
| 3 node `m7g.large` | Spot $0,0398/giờ [N4]; on-demand $0,102/giờ [N3], 2026-10-31 | $0,119 Spot ($0,306 on-demand) |
| 1 NAT gateway | $0,059/giờ + $0,059/GB xử lý [N5], 2026-10-31 | $0,059 + dữ liệu |
| IPv4 công khai (NAT 1, NLB 2 AZ) | $0,005/IP-giờ [N5], 2026-10-31 | $0,015 |
| NLB | $0,0252/giờ + $0,006/NLCU-giờ [N6], 2026-10-31 | ~$0,031 (ước lượng 1 NLCU) |
| RDS `db.t4g.small` PostgreSQL single-AZ + gp3 20 GB | $0,051/giờ; gp3 $0,138/GB-tháng [N7], 2026-10-31 (Multi-AZ $0,102/giờ) | $0,055 |
| EBS gp3 ~120 GB (đĩa node + PVC) | $0,096/GB-tháng [N8], 2026-10-31; dung lượng là ước lượng | $0,016 |
| S3 | $0,025/GB-tháng (50 TB đầu); PUT/POST $0,005/1 000, GET $0,004/10 000 [N9], 2026-10-31 | ~$0 (vài GB) |
| CloudFront | 1 TB và 10 triệu request mỗi tháng miễn phí [N10], 2026-10-31 | $0 |
| Secrets Manager (secret master của RDS) | $0,40/secret-tháng, $0,05/10 000 API [N11], 2026-10-31 | ~$0 |
| **Tổng mỗi giờ** | Cộng các dòng trên (giá đọc 2026-10-31) | **~$0,40 Spot · ~$0,58 on-demand** |
| **Mỗi buổi 4 giờ** | 4 × tổng mỗi giờ + dữ liệu NAT ~10 GB (kéo image; ước lượng) × $0,059 ≈ $0,59 + 1–2 node thêm cho k6 bậc 4–8 trong ~1 giờ ($0,04 Spot, $0,10 on-demand mỗi node-giờ); giá đọc 2026-10-31 | **~$2,2–2,4 Spot · ~$3,0–3,1 on-demand; trần đặt $5** |
| Cố định giữa các buổi | Hosted zone $0,50/tháng [N12], 2026-10-31; bucket state < $0,01 (ước lượng); budget miễn phí [N13], 2026-10-31; domain đã có | ~$0,50/tháng |
| Quên destroy | 24 × tổng mỗi giờ (giá đọc 2026-10-31) | ~$10 Spot, ~$14 on-demand; budget và Cost Anomaly Detection cảnh báo |

Cùng cấu hình ở `us-east-1` (cùng nguồn): ~$0,35/giờ Spot, ~$0,48/giờ on-demand. 7b (hai cluster, prd on-demand nhiều AZ, NAT mỗi AZ, RDS
Multi-AZ, k6 20 pod) ước lượng ~$1,2–1,6/giờ; ADR của 7b tính lại.

Đòn bẩy đã dùng: Spot + Graviton; một NAT; S3 gateway endpoint (dữ liệu S3 không qua NAT); Valkey, Redpanda trong cluster; không interface
endpoint, không KMS key riêng, log control plane tắt; CloudFront trong hạn mức miễn phí; dựng và destroy trong buổi, `sweep.sh` chặn sót;
budget từ ngày đầu. Infracost là lựa chọn của người học ở 7c.

### 13. Tài nguyên có thể nằm ngoài state Terraform và cách quét

| Tài nguyên | Ai tạo | Gỡ trước `terraform destroy` | Quét |
| --- | --- | --- | --- |
| NLB, target group, rule security group | LBC, từ Service của Envoy | Xoá Application workload, chờ Service `LoadBalancer` và TargetGroupBinding biến mất khi LBC còn chạy | Tag `elbv2.k8s.aws/cluster`, `kubernetes.io/cluster/<tên>` |
| Volume EBS của PVC (Redpanda, Prometheus, Alertmanager, Loki, Tempo, Pyroscope) | EBS CSI, từ `volumeClaimTemplates` (Argo CD không prune PVC) | Xoá PVC ở mọi namespace khi EBS CSI còn chạy, chờ PV hết | Tag `Project=svp` (`extraVolumeTags`), tag của EBS CSI |
| Bản ghi Route 53 (A, TXT của ExternalDNS; TXT `_acme-challenge` sót khi DNS-01 lỗi) | ExternalDNS, cert-manager | Chờ bản ghi biến mất khi ExternalDNS còn chạy | Bản ghi của zone lab ngoài NS/SOA ở đỉnh zone |
| ENI sót của VPC CNI | VPC CNI | Tự gỡ khi node xoá; sót thì chặn xoá subnet | ENI theo VPC id |
| Log group | EKS khi bật log control plane, flow log | Module quản khi bật; stg tắt | Log group theo tên cluster |
| Secret master của RDS | RDS (`manage_master_user_password`) | Đi theo instance (chưa kiểm) | Secrets Manager theo tag, kể cả secret đang chờ xoá |
| Backup tự động, snapshot RDS | RDS | `delete_automated_backups = true`, stg bỏ final snapshot | Snapshot theo instance |
| Snapshot EBS | Velero (7b) | Diễn tập tự dọn | Tag `Project=svp` |

Trình tự gỡ (script `pre-destroy.sh`): xoá root `svp-root` trước (không finalizer, child ở yên) hay tắt `automated` của nó; xoá Application
workload (trừ `svp-cluster`), chờ NLB, TargetGroupBinding, bản ghi DNS biến mất khi LBC, ExternalDNS, Envoy Gateway còn chạy; xoá PVC
khi EBS CSI còn chạy, chờ PV hết; xoá phần còn lại rồi `terraform destroy`. `sweep.sh` chỉ đọc: liệt kê mọi tài nguyên tag `Project=svp` hay
tag của Kubernetes, ENI của VPC, bản ghi zone, secret chờ xoá, exit 1 khi còn bất cứ thứ gì ngoài tài nguyên của `aws/bootstrap`.

### 14. Buổi AWS

Mọi lệnh chạm account do người học chạy theo runbook của `svp-infra` (`docs/runbooks/session-stg.md`), profile và region ghi trong lệnh:
kiểm account → kiểm DNS → `terraform plan` lưu file, đọc, `apply` file đó → `make eks-gitops-up` → smoke, seed, k6 bậc 1, 2, 4, 8 → pre-destroy →
`terraform destroy` → `sweep.sh`. Giới hạn 4 giờ (quá 3 giờ chưa đo xong thì bỏ phần đo còn lại, sang gỡ). Chạy sau khi code, `svp-gitops`
và `svp-infra` đã merge và uỷ quyền NS đã lan.

## Kiểm chứng sau

Giả định chỉ chứng minh được trên AWS. Phép kiểm chạy ở buổi AWS stg; lệnh tay nằm trong runbook buổi.

| Giả định | Phép kiểm | Kết quả |
| --- | --- | --- |
| VPC CNI thực thi NetworkPolicy của bốn namespace như kube-router trên k3d (chặn mặc định hai chiều, cho theo label) | Pod thử không label ở `svp` gọi `gateway:8080`, `feed-service:9104` và RDS 5432: quá hạn; pod đối chứng có label đúng tới được; smoke qua | Chưa kiểm |
| Pod tới API server qua `nodeSubnet` = CIDR VPC cổng 443 sau DNAT của kube-proxy (ESO, Prometheus discovery, Argo CD) | 28 ExternalSecret `Ready`; target `kubernetes-*` của Prometheus `up` | Chưa kiểm |
| Form upload tạo sát lúc credential Pod Identity sắp hết hạn vẫn dùng được tới hết 15 phút. URL ký bằng credential tạm hết hiệu lực khi credential hết hạn [N35]; tài liệu Pod Identity không ghi thời hạn credential [N21] | Ba lần trong buổi, cách nhau ≥ 20 phút: tạo form, tải lên ở phút 14; mọi lần 204, không 403 `ExpiredToken`. Phép kiểm không phủ mọi thời điểm: nếu agent trả credential còn dưới 15 phút thì SDK làm mới vẫn nhận bản cũ | Chưa kiểm |
| Ghi có điều kiện `If-None-Match: *` và CRC32 full-object multipart chạy trên S3 thật | `make eks-smoke` (master có version, `Cache-Control … immutable` qua CloudFront); phát lại `video.uploaded` bằng `rpk group seek` qua `kubectl exec`: log `transcode output exists`, không object mới dưới thư mục của video; log media-worker không lỗi checksum | Chưa kiểm |
| Nhãn PSA `v1.36` (`podSecurityVersion`) trên EKS 1.36: namespace nhận nhãn, pod qua `restricted` như k3d. KEP-2579: version mới hơn cluster được nhận như `latest` [N40]; có warning hay không: chưa kiểm | `kubectl get ns -L pod-security.kubernetes.io/enforce-version`; không warning PSA khi Argo CD apply; mọi pod `svp` Running | Chưa kiểm |
| NLB giữ IP client với target `ip` | Smoke từ máy người học: access log gateway có IP công khai của máy; hai request với `X-Forwarded-For` giả rơi cùng một khoá rate limit | Chưa kiểm |
| Không pod nào gọi tên công khai qua NLB (hairpin không chạy khi giữ IP client [N31]) | Lỗi kết nối trong k6 bằng 0; số khoá `svp:gw:rl:register:*` bằng số pod k6 (RL-7) | Chưa kiểm |
| Addon `metrics-server` có cho 1.36, HPA đọc được CPU | `kubectl top node`; HPA của gateway, feed-service không `FailedGetResourceMetric` | Chưa kiểm |
| IMDSv2 hop limit 1: pod không tới IMDS, EBS CSI vẫn chạy | Pod thử `curl http://169.254.169.254/latest/api/token -X PUT` quá hạn; PVC `Bound` | Chưa kiểm |
| Job bootstrap chạy dưới `rds_superuser` (không superuser) | Job `pg-bootstrap` Complete; năm database và cặp role đúng như local | Chưa kiểm |
| Spot `m7g.large` đủ cho buổi 4 giờ ở 2 AZ | Số lần thu hồi, node thay thế; phép đo không hỏng | Chưa kiểm |
| Docker Hub ẩn danh qua một IP NAT không chạm 100 lượt/6 giờ | Không `ErrImagePull` 429 khi dựng; đếm image `docker.io` đã kéo | Chưa kiểm |
| Chứng chỉ production cấp được trong buổi; ExternalDNS xoá bản ghi khi gỡ | Thời gian tới Certificate `Ready`; `sweep.sh` không bản ghi sót | Chưa kiểm |
| PVC xoá khi EBS CSI còn chạy thì volume EBS xoá (`reclaimPolicy: Delete`) | `sweep.sh` không volume | Chưa kiểm |
| Chi phí buổi khớp ước lượng mục 12 (trong ±50 %) | Cost Explorer sau 24 giờ, theo dịch vụ | Chưa kiểm |
| Thời gian `apply` → mọi Application Synced/Healthy; `pre-destroy` + `destroy`; quét sạch | Mốc ghi trong runbook buổi; `sweep.sh` exit 0 | Chưa kiểm |
| Bucket `media` không liệt kê được ẩn danh cả khi gọi thẳng endpoint vùng của S3, không qua CloudFront (UP-6, AWS-2); `make eks-smoke` chỉ thử được phép liệt kê qua gốc của CloudFront | Bước tay của runbook buổi: `curl -s -o /dev/null -w '%{http_code}' 'https://<mediaBucket>.s3.<region>.amazonaws.com/?list-type=2'` với `mediaBucket`, `region` của `cluster-values.json`; mong `403` | Chưa kiểm |
| k6 profile `cloud` trên 3 node: bậc cao nhất đạt mọi threshold theo SLO | `run.sh --pods 1, 2, 4, 8`; p95/p99 phía server trong cửa sổ giữ | Chưa kiểm |

## Hệ quả

- **Được:**
  - Chart, policy, GitOps, bản ghi stg, promote prd chạy nguyên trên cloud; khác biệt của nền tảng nằm ở `platforms/eks/` và `cluster.*`,
    k3d stg và EKS stg cùng `envs/stg` và cùng bộ digest.
  - Một repo hạ tầng cho ba cloud và GitHub dưới dạng code; quyền apply tách khỏi repo code; CI kiểm tĩnh không credential.
  - prd ở 7b chỉ đổi biến và thêm `aws/envs/prd`.
- **Phải trả:**
  - EKS: phí control plane mỗi cluster, nâng minor (1.36 hết standard support 2027-08-02), ~10 controller với quyền AWS.
  - Repo thứ tư và hợp đồng `cluster.*` giữa ba repo; thay đổi chéo theo thứ tự.
  - Singapore đắt hơn `us-east-1` ~14–21 % mỗi giờ của buổi; overlay prd đổi region ở 7b.
  - Spot có thể bị thu hồi giữa buổi; dữ liệu qua NAT tính tiền theo GB.
  - Let's Encrypt: tối đa 5 buổi mỗi tuần với cùng bộ tên; hạn mức của domain gốc dùng chung.
  - Zone Route 53 giữ giữa các buổi; bản ghi NS ở DNS ngoài phải gỡ trước khi xoá zone (threat model AWS-7).
  - Endpoint API của EKS công khai (giới hạn CIDR) thay vì chỉ private kèm đường vào riêng; IP của người học đổi thì cập nhật biến.
  - NLB không có WAF; DoS ở tầng L7 chỉ có rate limit của gateway.
- **Xem lại khi:**
  - Một hệ thống khác có ít service và team không vận hành Kubernetes: ECS Fargate (hay ECS Express Mode).
  - 1.36 còn dưới 2 tháng standard support: nâng minor (7c).
  - Spot bị thu hồi quá một lần mỗi buổi: stg dùng on-demand.
  - Gặp 429 của Docker Hub: pull-through cache của ECR hay pull secret.
  - prd cần độ bền của Kafka, Redis: MSK, ElastiCache (7b).
  - CloudFront vượt 1 TB/tháng hay cần WAF trước video: xét flat-rate (mô hình 100k DAU ở giai đoạn 9).
- **ADR cũ được chỉnh:**
  - [0024](0024-multi-environment.md) §9: Terraform ở repo `svp-infra`, `aws/envs/<env>/` và `aws/modules/` (thay `deploy/terraform/…` của
    repo code); lớp nền tảng là lớp values `platforms/<platform>/` giữa `base/` và `envs/`, giá trị theo cluster qua `cluster.*`. Quy tắc env
    giữa stg và prd giữ nguyên.
  - Không đổi quyết định nhưng hoàn tất chỗ để ngỏ: [0020](0020-reliability-stage6.md) (`CLOUD_K8S_VERSION` theo EKS 1.36), threat model
    RL-1 (1 hop qua NLB L4), [0026](0026-secrets-gitops.md) (region của store `aws` ở prd là `ap-southeast-1` khi dựng ở 7b).

## Hiện thực ở

Chưa hiện thực (2026-10-31). Nơi sẽ hiện thực:

- Repo `svp-infra` (`infra/`): `Makefile`, `.tflint.hcl`, `.trivyignore.yaml`, `renovate.json`, `.github/workflows/check.yml` (mục 2, 15);
  `aws/bootstrap/` (state, budget, zone; mục 2, 3, 5); `aws/modules/network/`, `aws/modules/eks/`, `aws/modules/rds/`, `aws/modules/media/`
  (mục 6, 8, 9, 11); `aws/envs/stg/` (output `cluster_values`, role Pod Identity của hai service; mục 7, 10); `aws/scripts/`,
  `docs/runbooks/session-stg.md` (mục 13, 14).
- Repo code: `internal/objstore` (`S3_CREDENTIALS`, `S3_PATH_STYLE`; mục 9, 10); `deploy/helm/svp-data` (`postgres.mode`, `s3.mode`),
  `deploy/helm/svp-observability` (`postgres.mode`), `deploy/helm/svp-cluster` (StorageClass `gp3`, issuer `acme`, Service NLB của Envoy,
  `kubeAPIPort`), `deploy/helm/svp-service` (egress tới RDS, S3, agent Pod Identity), `deploy/postgres/bootstrap.sql` (mục 5, 8, 9);
  `deploy/ci/gitops-check.sh`, `deploy/ci/cluster-values.example.yaml`, `deploy/k8s/gitops.sh`, `deploy/k8s/install.sh`, `deploy/k8s/lib.sh`,
  target `eks-*` của `deploy/k8s/k8s.mk`, `deploy/k8s/eks-seed.sh`, nhánh `eks` của `deploy/compose/lib.sh` (mục 7, 14).
- Repo `svp-gitops`: `platforms/k3d/`, `platforms/eks/`, `argocd/apps/` (`platform`, `cluster`, trường `platforms`), `argocd/project.yaml`,
  `base/aws-load-balancer-controller.yaml`, `base/external-dns.yaml` (mục 7, 8).
- Tài liệu: [architecture §5.7](../architecture.md#57-biến-thể-aws-giai-đoạn-7), [threat model](../threat-model.md) RL-1 và
  [4.11](../threat-model.md#411-biên-aws-giai-đoạn-7), [runbook `svp-infra-setup.md`](../runbooks/svp-infra-setup.md).

## Nguồn

Đọc ngày 2026-10-31. Giá lấy từ AWS Price List công khai (tệp offer theo region, không cần đăng nhập) và dữ liệu của trang giá; ngày phát
hành của tệp ghi trong ngoặc.

- [N1] AWS Price List, Amazon EKS, `ap-southeast-1` (phát hành 2026-10-27): phí cluster, extended support, phí quản lý EKS Auto Mode theo loại
  instance: <https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEKS/current/ap-southeast-1/index.json>
- [N2] Amazon EKS pricing: <https://aws.amazon.com/eks/pricing/>
- [N3] Amazon EC2 On-Demand pricing (Linux, Singapore và N. Virginia): <https://aws.amazon.com/ec2/pricing/on-demand/>
- [N4] Amazon EC2 Spot pricing (dữ liệu của trang: <https://website.spot.ec2.aws.a2z.com/spot.js>): <https://aws.amazon.com/ec2/spot/pricing/>
- [N5] Amazon VPC pricing (NAT gateway, IPv4 công khai) và AWS Price List `AmazonVPC` `ap-southeast-1` (phát hành 2026-10-16):
  <https://aws.amazon.com/vpc/pricing/>
- [N6] Elastic Load Balancing pricing và AWS Price List `AWSELB` `ap-southeast-1` (phát hành 2026-09-11):
  <https://aws.amazon.com/elasticloadbalancing/pricing/>
- [N7] Amazon RDS for PostgreSQL pricing và AWS Price List `AmazonRDS` `ap-southeast-1` (phát hành 2026-10-29):
  <https://aws.amazon.com/rds/postgresql/pricing/>
- [N8] Amazon EBS pricing: <https://aws.amazon.com/ebs/pricing/>
- [N9] Amazon S3 pricing và AWS Price List `AmazonS3` `ap-southeast-1` (phát hành 2026-10-15): <https://aws.amazon.com/s3/pricing/>
- [N10] Amazon CloudFront pricing (flat-rate), pay-as-you-go (hạn mức miễn phí, giá theo vùng, price class) và hướng dẫn flat-rate plan:
  <https://aws.amazon.com/cloudfront/pricing/>, <https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/>,
  <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html>
- [N11] AWS Secrets Manager pricing và AWS Price List `AWSSecretsManager` `ap-southeast-1`: <https://aws.amazon.com/secrets-manager/pricing/>
- [N12] Amazon Route 53 pricing (hosted zone $0,50/tháng cho 25 zone đầu): <https://aws.amazon.com/route53/pricing/>
- [N13] AWS Budgets pricing: <https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/>
- [N14] AWS Cost Anomaly Detection FAQ: <https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/faqs/>
- [N15] AWS Fargate pricing và AWS Price List `AmazonECS` `ap-southeast-1` (ARM vCPU, GB): <https://aws.amazon.com/fargate/pricing/>
- [N16] AWS App Runner (thông báo ngừng nhận khách mới từ 2026-04-30): <https://aws.amazon.com/apprunner/>,
  <https://docs.aws.amazon.com/apprunner/latest/dg/what-is-apprunner.html>
- [N17] Amazon ECS linear và canary có sẵn (2025-10-30), thêm NLB (2026-02):
  <https://aws.amazon.com/about-aws/whats-new/2025/10/amazon-ecs-built-in-linear-canary-deployments>,
  <https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-ecs-nlb-linear-canary-deployments/>
- [N18] Amazon EKS Kubernetes versions (standard 1.34–1.37, ngày hết hỗ trợ): <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>
- [N19] Amazon EKS community add-ons (`metrics-server`): <https://docs.aws.amazon.com/eks/latest/userguide/community-addons.html>
- [N20] Amazon EKS, network policy với VPC CNI (≥ 1.21.0, giới hạn): <https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html>
- [N21] EKS Pod Identity, cách hoạt động (agent `169.254.170.23`, biến môi trường):
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html>
- [N22] EKS Auto Mode: <https://docs.aws.amazon.com/eks/latest/userguide/automode.html>
- [N23] Amazon EKS cluster endpoint access: <https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html>
- [N24] Amazon EKS release notes cho version ở extended support (1.30: `gp2` không còn mặc định; đọc qua kết quả tìm kiếm, chưa mở trang):
  <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-extended.html>
- [N25] Karpenter releases (v1.15.1): <https://github.com/aws/karpenter-provider-aws/releases>
- [N26] Terraform, backend S3 (`use_lockfile`; khoá DynamoDB deprecated): <https://developer.hashicorp.com/terraform/language/backend/s3>
- [N27] Provider Kubernetes của Terraform, mục "Stacking with managed Kubernetes cluster resources" (trang registry không hiện nội dung khi
  tải; đọc câu khuyên qua bản sao mô tả của provider): <https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs>
- [N28] `terraform-aws-modules`: <https://github.com/terraform-aws-modules/terraform-aws-eks/releases>,
  <https://github.com/terraform-aws-modules/terraform-aws-vpc/releases>
- [N29] Docker Hub pull limits (ẩn danh 100 lượt/6 giờ mỗi IPv4 hay /64 IPv6): <https://docs.docker.com/docker-hub/usage/pulls/>
- [N30] Let's Encrypt rate limits (cập nhật 2026-08-05): <https://letsencrypt.org/docs/rate-limits/>
- [N31] NLB target group attributes, "Client IP preservation" (mặc định với target `ip` TCP, NAT loopback):
  <https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html>
- [N32] AWS Load Balancer Controller, annotation của Service:
  <https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/>
- [N33] Amazon S3 conditional writes: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html>
- [N34] Amazon S3 checking object integrity (CRC32 full-object cho multipart):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html>
- [N35] Amazon S3 presigned URL (URL ký bằng credential tạm hết hiệu lực khi credential hết hạn):
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html>
- [N36] RDS for PostgreSQL, role và `rds_superuser` (master mặc định `postgres`, `CREATEDB`, `CREATEROLE`, không superuser):
  <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Roles.html>
- [N37] RDS for PostgreSQL release calendar: <https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html>
- [N38] GitOps Bridge: <https://github.com/gitops-bridge-dev/gitops-bridge>
- [N39] Classmethod, lỗi IMDS khi module EKS v21 để hop limit 1 (đọc qua kết quả tìm kiếm): <https://dev.classmethod.jp/articles/eks-v21-hop-limit-imds-error/>
- [N40] KEP-2579, Pod Security Admission (version mới hơn cluster được xử lý như `latest`): <https://www.kubernetes.dev/resources/keps/2579/>
- [N41] RDS API `CreateDBInstance`, tham số `MasterUsername` (1–16 chữ, số, gạch dưới; ký tự đầu là chữ): <https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_CreateDBInstance.html>
