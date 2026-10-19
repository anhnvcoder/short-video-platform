# 0014. Giai đoạn 4: Kubernetes local trên k3d với Helm, Envoy Gateway, dữ liệu trong cluster, Argo CD và canary bằng Argo Rollouts

- Trạng thái: Chấp nhận
- Ngày: 2026-10-18

## Bối cảnh

- Giai đoạn 0–3 xong ([plan](../../plans/261004-devops-sa-roadmap/plan.md), mục Tiến độ). Giai đoạn 4 phải chạy cả hệ thống
  trên Kubernetes local: k3d, Helm chart cho service, Gateway API + Envoy Gateway + cert-manager, observability tách thành
  deployment riêng, probe/resource/PDB/HPA, KEDA scale media-worker theo lag, NetworkPolicy, RBAC, Argo CD app-of-apps,
  Argo Rollouts canary có phân tích. **Xong khi:** đẩy code lên git thì Argo CD tự đồng bộ, và bản canary lỗi tự rollback.
- Đã chốt từ trước (plan, mục Quyết định đã chốt): Gateway API + Envoy Gateway (ingress-nginx ngừng bảo trì), Argo CD,
  KEDA, cert-manager; số hop proxy tin cậy RL-1 = 1 trên k3d; `MetadataMinAge` 1 s
  ([ADR-0013](0013-kafka-metadata-min-age.md)); `internal/kafkax` đọc `KAFKA_SASL_USERNAME`/`KAFKA_SASL_PASSWORD`
  (SCRAM-SHA-256, cả hai rỗng thì không SASL, một trong hai rỗng thì lỗi khởi động); gateway đọc `TRUSTED_PROXY_HOPS`
  (mặc định 0) và `TRUSTED_PROXY_CIDRS`.
- [Threat model §5](../threat-model.md#5-tổng-hợp-theo-giai-đoạn), hàng giai đoạn 4: FF-3, FF-4, FF-5, FF-6, IN-2, IN-4,
  IN-9, RL-1, OPS-2. Kiểm bằng: pod thử ở namespace khác không gọi được gRPC và Redpanda; worker không ra được internet;
  service không ghi được topic không phải của mình.
- Máy Apple M2 16 GB; Docker Desktop khoảng **9,7 GiB**, 8 CPU. `kubectl` 1.37.1, `helm` 4.3.0 (Homebrew, có sẵn); chưa có
  k3d; Go 1.27.2; Postgres native 15.18 (`show server_version`). Compose `core` + `obs` lúc nghỉ 1,71–2,61 GiB (plan, Ràng
  buộc máy). Không chạy song song compose và k3d; chỉ publish trên `127.0.0.1`; docker/compose/k3d qua `Makefile` với
  `env -u DOCKER_DEFAULT_PLATFORM`; `kubectl`/`helm` luôn ghi `--context k3d-svp`.
- ADR này chốt version, digest, tên namespace, Secret, cổng, biến môi trường và tên metric mà mọi phần hạ tầng của giai đoạn
  4 dùng. Giả định chỉ kiểm được khi có cluster ghi "**kiểm trên cluster**" kèm bước dựng tương ứng; các bước theo thứ tự:
  dựng cluster và biên vào → tầng dữ liệu → chart service → co giãn → observability → GlitchTip và cảnh báo → GitOps →
  canary → diễn tập threat model → lượt kiểm cuối → diễn tập GitOps sau khi push.

## 1. Công cụ và version

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **k3d bằng `go install` ghim trong `make tools`, version đặt qua `-ldflags`** | Cùng cách với các công cụ khác ([ADR-0007 §3](0007-go-monorepo-toolchain-and-stage1-scope.md#3-dependency-và-công-cụ)); version ghim trong `Makefile`, kiểm được bằng `k3d version` | Build mất ~40 s; phải tự đặt biến version, không thì image helper kéo tag `latest` |
| k3d bằng Homebrew | Một lệnh | Không ghim version trong repo; máy khác cài bản khác |
| Tải binary release, kiểm sha256 | Đúng binary upstream | Thêm script tải/kiểm checksum riêng cho một công cụ |
| Cài thêm CLI `argocd`, `kubectl-argo-rollouts` | Lệnh tiện (`argocd app sync`, `kubectl argo rollouts get`) | Thêm hai công cụ phải ghim; mọi việc cần làm được bằng `kubectl` với CRD |

**Version Kubernetes của node.** `kubectl` 1.37.1 chỉ được hỗ trợ với API server lệch ±1 minor (1.36–1.38). Hỗ trợ
Kubernetes theo tuyên bố chính thức của bản mới nhất mỗi thành phần (tra 2026-10-18):

| Thành phần | Bản | Kubernetes | Nguồn |
| --- | --- | --- | --- |
| Envoy Gateway | v1.9.2 | 1.33–1.36 | <https://gateway.envoyproxy.io/news/releases/matrix/> |
| KEDA | v2.21.0 | 1.34–1.36 | <https://keda.sh/docs/2.21/operate/cluster/> |
| CloudNativePG | 1.30.1 | 1.34–1.36 (1.37 "tested, but not supported") | <https://cloudnative-pg.io/docs/1.30/supported_releases> |
| Argo CD | v3.5.5 | 1.33–1.36 | `docs/operator-manual/tested-kubernetes-versions.md@v3.5.5` |
| cert-manager | v1.21.2 | 1.33–1.36 | <https://cert-manager.io/docs/releases/> |
| Argo Rollouts | v1.10.1 | e2e 1.32–1.35 (mục "Supported versions" của `docs/installation.md@v1.10.1` chỉ trỏ tới file e2e) | `.github/workflows/testing.yaml@v1.10.1`; nhánh `master` đã chuyển e2e sang 1.34–1.37 ngày 2026-09-22, chưa phát hành |

Không minor nào vừa nằm trong skew của `kubectl` 1.37 vừa nằm trong dải e2e của Argo Rollouts 1.10.1.

### Quyết định

Chọn **k3s v1.36.5**: minor mới nhất mà mọi thành phần có tuyên bố hỗ trợ chính thức đều nhận, nằm trong skew của
`kubectl` 1.37, và là kênh `stable` của k3s ngày 2026-10-18 (`latest` là v1.37.1). Argo Rollouts 1.10.1 chạy ngoài dải
e2e đúng một minor; controller chỉ dùng API ổn định (`apps/v1`, core, HTTPRoute `v1` qua plugin), rủi ro thấp. Đã chạy
trên cluster k3s v1.36.5 (2026-10-18): canary qua plugin, phân tích, abort, restart bằng `spec.restartAt` (evict qua PDB)
đều đúng, log controller không có `forbidden` (mục 13). Phương án thay nếu muốn mọi thành phần nằm trong dải đã test:
k3s v1.35.9 (ngoài skew của `kubectl` 1.37). Xem lại khi Argo Rollouts phát hành bản test 1.36+.

Cài thêm **chỉ k3d**, bằng `make tools`:

```make
K3D_VERSION := v5.9.0
K3S_IMAGE_TAG := v1.36.5-k3s1
GOBIN=$(GOBIN) go install -ldflags='-X github.com/k3d-io/k3d/v5/version.Version=$(K3D_VERSION) \
	-X github.com/k3d-io/k3d/v5/version.K3sVersion=$(K3S_IMAGE_TAG)' github.com/k3d-io/k3d/v5@$(K3D_VERSION)
```

- Biến `Version`, `K3sVersion` thuộc gói `github.com/k3d-io/k3d/v5/version` (`version/version.go@v5.9.0`), đúng LDFLAGS
  trong `Makefile@v5.9.0` của k3d. `Version` rỗng thì k3d kéo `k3d-proxy:latest`, `k3d-tools:latest`
  (`pkg/types/images.go`). `go.mod` của k3d v5.9.0 khai `go 1.26.3`, không có `replace`; `go install` build được bằng Go
  1.27.2 và `k3d version` in đúng hai version đã đặt.
- Image helper ghim digest qua biến môi trường của k3d (`pkg/types/env.go@v5.9.0`): `K3D_IMAGE_LOADBALANCER`,
  `K3D_IMAGE_TOOLS`; registry ghim bằng `k3d registry create --image`.
- `kubectl` 1.37.1, `helm` 4.3.0 giữ nguyên. **Không** cài CLI `argocd`, `kubectl-argo-rollouts`: dùng
  `kubectl get applications.argoproj.io`, `kubectl get rollout -o json`, `kubectl get analysisrun`.

Bảng version (chart ghim version; cột digest là digest manifest list/OCI index đa kiến trúc, đã kiểm có `linux/arm64` và
`linux/amd64`):

| Thành phần | Chart (repo) | Chart | App | Image project tự ghim |
| --- | --- | --- | --- | --- |
| k3d | `go install github.com/k3d-io/k3d/v5` | — | v5.9.0 | `ghcr.io/k3d-io/k3d-proxy:5.9.0@sha256:7be40abfeb6ac9a81d0d4157a7cbf3aacc68a64a1780ca2efb160f1aea915177`, `ghcr.io/k3d-io/k3d-tools:5.9.0@sha256:c57abce697e66feeb826922718738fe186b47779312d49d4e51e6fb9b8a6f34d` |
| k3s (node) | — | — | v1.36.5+k3s1 | `rancher/k3s:v1.36.5-k3s1@sha256:057cfd5a9d51b89f1f0ee139c28d5d5fdd5aa7ddeac2742a0ba90c6dbc0329bb` |
| Registry local | — | — | distribution 3.1.2 | `docker.io/library/registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8` |
| cert-manager | `https://charts.jetstack.io` `cert-manager` | v1.21.2 | v1.21.2 | Theo chart |
| Envoy Gateway | `oci://docker.io/envoyproxy/gateway-helm` | v1.9.2 | v1.9.2 | Theo chart; proxy `envoyproxy/envoy:distroless-v1.39.1` do Envoy Gateway ghim digest trong `api/v1alpha1/shared_types.go@v1.9.2`; CRD Gateway API v1.6.1 kênh experimental đi kèm chart |
| CloudNativePG | `https://cloudnative-pg.github.io/charts` `cloudnative-pg` | 0.29.1 | 1.30.1 | Postgres `ghcr.io/cloudnative-pg/postgresql:15.19-minimal-trixie@sha256:f6091200bc5e1926efea8babe8a511d091e9a253d8f33fe4e920d0e89a67b57e` |
| Redpanda | `https://charts.redpanda.com` `redpanda` | 26.2.4 | v26.2.4 (mặc định của chart là v26.2.3) | Broker `docker.io/redpandadata/redpanda:v26.2.4@sha256:c98c2f04a751e6646012cc701bac5183252cee44c88ba1dfa412e4c7124f2e89` (cùng compose); sidecar `docker.io/redpandadata/redpanda-operator:v26.2.4@sha256:247d43566fffd766618f08f318c7adb78310305900db968b879dfd58cdc32722` |
| KEDA | `https://kedacore.github.io/charts` `keda` | 2.21.0 | 2.21.0 | Theo chart |
| kube-prometheus-stack | `https://prometheus-community.github.io/helm-charts` `kube-prometheus-stack` | 92.10.1 | operator v0.94.1; Prometheus v3.15.0, Alertmanager v0.34.1 (cùng compose), Grafana 13.2.4 (subchart `grafana` 14.0.1 của grafana-community), kube-state-metrics v2.20.0 | Theo chart |
| Loki | `https://grafana-community.github.io/helm-charts` `loki` | 18.17.1 | 3.7.8 (cùng compose) | Theo chart |
| Tempo | `https://grafana-community.github.io/helm-charts` `tempo` | 3.2.0 | 3.1.0 (cùng compose) | Theo chart |
| Pyroscope | `https://grafana.github.io/helm-charts` `pyroscope` | 2.4.0 | 2.4.0 (compose 2.3.1) | Theo chart |
| OTel Collector | `https://open-telemetry.github.io/opentelemetry-helm-charts` `opentelemetry-collector` | 0.176.0 | 0.162.0 | `otel/opentelemetry-collector-contrib@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6` (index của 0.162.0, cùng compose; chart nhận `image.digest`) |
| Argo CD | `https://argoproj.github.io/argo-helm` `argo-cd` | 10.10.5 | v3.5.5 (Helm bên trong 4.2.1) | Theo chart |
| Argo Rollouts | `https://argoproj.github.io/argo-helm` `argo-rollouts` | 2.43.8 | v1.10.1 | Theo chart; plugin `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi` v0.17.0 (bảng mục 13) |
| Valkey | — | — | 9.1.2 | `docker.io/valkey/valkey:9.1.2-alpine@sha256:48332870af354a799964c0012ae1194a0bf2bf894eb508f945810596dc2d8d11` |
| MinIO | — | — | `RELEASE.2026-09-22T19-25-18Z` | `cgr.dev/chainguard/minio@sha256:7df55d002b698e4494a131b848dd553361bbe58b7e19f62d9623c29af1ba9ccf` (cùng compose) |
| GlitchTip | — | — | 6.2.6 | `glitchtip/glitchtip:6.2.6@sha256:a3d8eb1b36c1e1603d55ab32711ea3dd8115874742a781a57391a62a16e0dff6` (cùng compose) |

- "Theo chart": image operator/backend dùng tag mặc định của chart đã ghim version (tag bất biến theo version chart). Ghim
  digest và ký image cho mọi thứ chạy trong cluster là việc của giai đoạn 5 (Kyverno, FF-8, SC-1).
- Chart `grafana/tempo`, `grafana/loki`, `grafana/grafana` đã chuyển sang `grafana-community/helm-charts`: README của
  `grafana/helm-charts` ghi chart Tempo "has been migrated to grafana-community/helm-charts" (commit "deprecate chart tempo",
  2026-01-30, index đánh `deprecated: true`); chart Loki OSS chuyển từ 2026-03-16 (grafana/loki#20705), `grafana/loki` chỉ
  còn cho GEL (7.3.0, Loki 3.6.12). Chart Tempo single-binary **không** bị bỏ để thay bằng `tempo-distributed`. Chart
  Pyroscope vẫn nằm trong repo `grafana/pyroscope` (`operations/pyroscope/helm/pyroscope`), phát hành ở
  `https://grafana.github.io/helm-charts`, không deprecated.
- Image Valkey: 9.1.2 là bản ổn định mới nhất (9.2.0 mới ở `rc1`, GitHub `valkey-io/valkey` releases).

## 2. Topology và ngân sách RAM

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| 1 node (server chạy workload) | Ít RAM nhất | PDB, topology spread, drain không có nghĩa: không có node thứ hai để chuyển pod |
| **1 server + 1 agent, server vẫn chạy workload** | PDB của gateway và phân bố 2 replica có nghĩa; drain một node học được | Thêm ~0,2 GiB cho agent |
| 3 node | Gần cluster thật hơn | Thêm RAM không có giá trị học thêm ở giai đoạn này |
| Giữ Traefik của k3s | Có sẵn | Ingress thứ hai bên cạnh Envoy Gateway; hai controller cùng tranh cổng 80/443 |
| Bỏ servicelb, dùng MetalLB hay NodePort | MetalLB gần cloud hơn | Thêm thành phần; NodePort đổi cổng của Envoy |

### Quyết định

Cluster k3d tên **`svp`**, context **`k3d-svp`**, cấu hình ở `deploy/k8s/k3d.yaml` (`apiVersion: k3d.io/v1alpha5`, kind
`Simple`; tên trường đối chiếu `pkg/config/v1alpha5/schema.json@v5.9.0`, đã chạy `ValidateSchemaFile` của k3d trên một
cấu hình mẫu đủ các trường dưới):

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: svp
servers: 1
agents: 1
image: rancher/k3s:v1.36.5-k3s1@sha256:057cfd5a9d51b89f1f0ee139c28d5d5fdd5aa7ddeac2742a0ba90c6dbc0329bb
subnet: 10.200.0.0/24
kubeAPI:
  hostIP: 127.0.0.1
  hostPort: "6550"
ports:
  - port: 127.0.0.1:8443:443
    nodeFilters: [loadbalancer]
registries:
  use: [k3d-svp-registry:5111]
volumes:
  - volume: ${SVP_REPO_ROOT}/deploy/k8s/pod-security-admission.yaml:/etc/rancher/k3s/pod-security-admission.yaml:ro
    nodeFilters: ["server:*"]
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters: ["server:*"]
      - arg: --kube-apiserver-arg=admission-control-config-file=/etc/rancher/k3s/pod-security-admission.yaml
        nodeFilters: ["server:*"]
      - arg: --kubelet-arg=pod-max-pids=512
        nodeFilters: ["server:*", "agent:*"]
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: false
```

- **Cổng host chỉ `127.0.0.1`:** API `6550` (mặc định của k3d là `0.0.0.0`, `pkg/types/defaults.go`, nên phải đặt
  `hostIP`), Envoy HTTPS `8443` → `443` của load balancer k3d, registry `5111`.
- **Subnet cố định `10.200.0.0/24`** cho mạng Docker `k3d-svp` (trường `subnet`, chỉ áp cho mạng k3d tự tạo,
  `pkg/client/cluster.go@v5.9.0`): NetworkPolicy cần biết dải địa chỉ node để mở egress tới API server và kubelet (mục 3).
  Không trùng dải pod `10.42.0.0/16`, service `10.43.0.0/16` của k3s, cũng không nằm trong pool mặc định của Docker
  (172.17–172.31, 192.168).
- Tắt Traefik; giữ **servicelb** (Service LoadBalancer của Envoy), **local-path** (PVC), **metrics-server** (HPA).
- **`pod-max-pids=512`** (FF-3, thay `pids_limit: 256` của media-worker ở compose). Giá trị kubelet áp cho **mọi** pod
  của node, Kubernetes không có giới hạn riêng từng pod. 256 đủ cho media-worker (đã chạy ở compose), nhưng Postgres mở một
  process mỗi kết nối (`max_connections` 100 của CloudNativePG cộng tiến trình nền khoảng 110 khi đầy), Envoy và các
  backend Go tăng thread theo syscall chặn; 512 gấp đôi mức compose của worker mà vẫn chặn được fork bomb rất xa trước
  `pid_max` của node. Kiểm trong cấu hình kubelet ở diễn tập threat model.
- **PSA `restricted` mặc định** cho mọi namespace trừ `kube-system`: `volumes` và cờ `admission-control-config-file` ở trên
  (mục 3). **Sửa 2026-10-19.**
- Kubeconfig gộp vào `~/.kube/config` nhưng **không đổi context hiện tại** (context đang dùng có thể là cluster khác);
  mọi lệnh vẫn ghi `--context k3d-svp`.
- Node chạy native arm64: mọi lệnh `k3d`/`docker` qua `Makefile` với `env -u DOCKER_DEFAULT_PLATFORM`.

**Không chạy song song compose và k3d:** `make up` từ chối khi có container mang label `k3d.cluster=svp` hoặc registry
`k3d-svp-registry`; `make k8s-up` (và `k8s-gitops-up`) từ chối khi `docker compose -p svp ps -q` khác rỗng. Tên label kiểm
trên cluster ở bước dựng cluster.

**Ngân sách RAM.** Số dưới là cận trên dùng để lập kế hoạch, chưa phải số đo; đo thật ở bước observability và lượt kiểm
cuối. Cột "Giới hạn" là `limits.memory` đặt trong values (mục 10).

| Nhóm | Thành phần (namespace) | RAM dự kiến | Giới hạn |
| --- | --- | --- | --- |
| Node | k3s server (`k3d-svp-server-0`: API server, controller, scheduler, kine/SQLite, kubelet, containerd) | 650 MiB | — |
| Node | k3s agent (`k3d-svp-agent-0`), serverlb, registry | 250 MiB | — |
| Platform | cert-manager (controller, webhook, cainjector; `cert-manager`) | 150 MiB | theo chart |
| Platform | Envoy Gateway controller (`envoy-gateway-system`) | 200 MiB | 256 MiB |
| Platform | Envoy proxy + shutdown-manager (`envoy-gateway-system`) | 150 MiB | 256 MiB |
| Platform | KEDA operator, metrics apiserver, admission webhooks (`keda`) | 250 MiB | theo chart |
| Platform | CloudNativePG operator (`cnpg-system`) | 150 MiB | 256 MiB |
| Platform | Argo Rollouts controller (`argo-rollouts`) | 150 MiB | 256 MiB |
| Dữ liệu | Postgres `svp-pg` (`svp-data`) | 250 MiB | 512 MiB |
| Dữ liệu | Valkey (`svp-data`) | 20 MiB | 128 MiB |
| Dữ liệu | Redpanda broker + sidecar (`svp-data`) | 450 MiB | 1280 MiB (broker) |
| Dữ liệu | MinIO (`svp-data`) | 250 MiB | 512 MiB |
| Service | 6 service lúc nghỉ, gateway 2 replica (`svp`) | 300 MiB | bảng mục 10 |
| Observability | Prometheus + config-reloader (`svp-obs`) | 620 MiB | 1 GiB |
| Observability | Loki | 300 MiB | 512 MiB |
| Observability | Tempo (có metrics-generator) | 400 MiB | 768 MiB |
| Observability | Pyroscope | 250 MiB | 512 MiB |
| Observability | Grafana + 2 sidecar | 250 MiB | 448 MiB + 2 × 128 MiB |
| Observability | Alertmanager + config-reloader, Prometheus operator, kube-state-metrics | 140 MiB | 64 / 128 / 128 MiB |
| Observability | Collector | 250 MiB | 256 MiB |
| Observability | GlitchTip | 250 MiB | 512 MiB |
| **Tổng lúc nghỉ** | node 0,9 + platform 1,05 + dữ liệu 0,95 + service 0,3 + observability 2,4 | **~5,6 GiB** | |
| Đỉnh | 3 media-worker transcode cùng lúc, ~0,75 GiB mỗi replica (compose đo 728–734 MiB) | **~7,9 GiB** | 2 GiB mỗi replica |
| Đường GitOps | Argo CD tối giản (server, repo-server, application-controller, redis) thêm | ~0,4 GiB | |

Ở compose, riêng container LGTM đã 0,73–1,25 GiB, Collector 0,25, GlitchTip 0,23; tách thành khoảng 10 tiến trình còn thêm
operator, kube-state-metrics và phần nền Go của từng tiến trình, nên observability lấy 2,4 GiB thay vì cộng số compose.

**Sửa 2026-10-18:** giới hạn của Grafana đổi từ 384 MiB cho cả nhóm thành 448 MiB cho container `grafana` và 128 MiB cho
mỗi sidecar. Đo ở bước observability: Grafana 13 nạp đủ dashboard dùng 286 MiB lúc nghỉ, chạm giới hạn 288 MiB của lần
đặt đầu; mỗi sidecar (k8s-sidecar, Python) bị OOM ở 48 MiB khi nạp danh sách ConfigMap đầu tiên. Cả pod lúc nghỉ 439 MiB
(`grafana` 284, hai sidecar 77 và 76). Tổng cluster vẫn dưới ngưỡng (nghỉ 5,71 GiB, đỉnh 7,16 GiB), nên không áp bước cắt
nào.

**Cách đo:** tổng cột MEM USAGE của `env -u DOCKER_DEFAULT_PLATFORM docker stats --no-stream` cho mọi container
`k3d-svp-*` (server-0, agent-0, serverlb) và `k3d-svp-registry`; 6 mẫu cách 10 s, lấy trung vị. Lúc nghỉ: mọi pod Ready rồi
nghỉ 60 s. Lúc đỉnh: trong khi media-worker đủ 3 replica đang transcode (diễn tập KEDA).

**Ngưỡng:** nghỉ **> 6,5 GiB** hoặc đỉnh **> 8,7 GiB** (Docker VM 9,7 GiB, chừa ~1 GiB cho dockerd và cache trang). Vượt
thì áp **lần lượt**, dừng ở bước đầu tiên đưa số đo về dưới ngưỡng, ghi số trước/sau từng bước:

1. Tắt Pyroscope: không cài release `pyroscope`, `PYROSCOPE_SERVER_ADDRESS` rỗng ở 5 service (như `OBS=off`); mất profile.
2. Tắt metrics-generator của Tempo: mất series `traces_service_graph_*` và `traces_spanmetrics_*`, nên panel service
   graph (node graph của datasource Tempo) và mọi panel RED sinh từ span trống; dashboard RED/SLO dựa trên metric trực tiếp
   của service vẫn có số.
3. media-worker tối đa 2 replica (`maxReplicaCount` của ScaledObject).
4. Giảm giới hạn bộ nhớ và retention của Loki và Prometheus (ghi giá trị mới và lý do).

Áp và đo ở bước observability; lượt kiểm cuối chỉ đo, không cắt thêm. Hết bước mà vẫn vượt thì dừng, báo số.

**Sửa 2026-10-20:** ngưỡng nghỉ là dự báo cho đỉnh, không phải giới hạn riêng: ràng buộc thật là Docker VM 9,7 GiB, và
ngưỡng đỉnh đã tính nó. MEM USAGE của `docker stats` là `memory.current` trừ `inactive_file` của cgroup node, nên gồm cả
page cache "active" (image vừa pull, file của Prometheus, Loki, Tempo) mà kernel thu lại được khi cần. Lượt kiểm cuối đo
nghỉ 5,87 GiB ở một lượt và 6,69–6,78 GiB ở lượt sau cùng code, tổng pod hai lượt chỉ khác 104 MiB: phần chênh là page
cache, bước cắt 1 (Pyroscope ~57 MiB) không đổi được số đó. Vì vậy nghỉ trên 6,5 GiB mà đủ cả hai điều dưới thì ghi số,
không cắt; thiếu một trong hai thì áp bước cắt như trên:

- (a) đỉnh đo được (cách đo ở trên, cùng code) dưới 8,7 GiB;
- (b) phần vượt là page cache: tổng pod (`kubectl --context k3d-svp top pods -A`) không vượt 4,7 GiB dự kiến cho
  platform, dữ liệu, service và observability, và MEM USAGE trừ `active_file` của các node dưới 6,5 GiB.

Cách đo thêm: cạnh MEM USAGE, ghi `anon`, `active_file` và `kernel` của từng node đọc từ cgroup v2 ngay sau 6 mẫu
(`env -u DOCKER_DEFAULT_PLATFORM docker exec k3d-svp-server-0 cat /sys/fs/cgroup/memory.current
/sys/fs/cgroup/memory.stat`, tương tự với `k3d-svp-agent-0`). Hai ngưỡng không đổi; ngưỡng đỉnh vẫn tính cả page cache.

## 3. Namespace, Pod Security, NetworkPolicy

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Namespace theo vai trò (`svp`, `svp-data`, `svp-obs`, `svp-edge`) + namespace mặc định của từng chart platform** | Policy và PSA theo vai trò; chart upstream giữ namespace quen thuộc | Luồng giữa namespace phải mở tường minh |
| Một namespace cho tất cả | Policy đơn giản | Một mức PSA cho mọi thứ; chart platform cần quyền khác app |
| PSA `restricted` mọi namespace của project | Mức chặt nhất của Kubernetes | Chart upstream phải chỉnh securityContext (đã kiểm từng chart, bên dưới) |
| PSA `baseline` cho `svp-data`, `svp-obs` | Chart chạy với giá trị mặc định | Cho phép container chạy root, không seccomp |
| **NetworkPolicy mặc định chặn ingress + egress, mỗi luồng một policy theo label pod** | Đúng IN-2, FF-5; luồng nào cũng đọc được trong repo | Nhiều policy; thứ tự cài phải để policy có trước luồng nó mở |
| Chỉ chặn ingress | Ít policy | Pod bị chiếm vẫn gọi ra mọi nơi (FF-5 không đạt) |

### Quyết định

**Namespace:** `svp` (6 service), `svp-data` (Postgres, Valkey, Redpanda, MinIO), `svp-obs` (observability, GlitchTip),
`svp-edge` (resource `Gateway`, Certificate wildcard); namespace mặc định của chart platform: `cert-manager`,
`envoy-gateway-system`, `cnpg-system`, `keda`, `argocd`, `argo-rollouts`.

**Pod Security Admission:** cả bốn namespace của project nhãn `pod-security.kubernetes.io/enforce: restricted`,
`enforce-version: v1.36`, cùng `warn`/`audit: restricted`. Đã kiểm bằng `helm template` các chart ghim với values dự định,
so từng pod (cả init container, sidecar, hook Job) với bảng tiêu chuẩn "restricted" (`runAsNonRoot`, seccomp
`RuntimeDefault`, `allowPrivilegeEscalation: false`, drop `ALL`, không hostPath/hostNetwork/privileged):

| Namespace | Thành phần | Kết quả | Values cần |
| --- | --- | --- | --- |
| `svp-data` | CloudNativePG instance | Đạt theo mặc định của operator (drop ALL, non-root, root fs chỉ đọc, seccomp `RuntimeDefault`; `pkg/specs/containers.go`, `pods.go`, `docs/src/security.md@v1.30.1`); không render được khi chưa có cluster | — |
| `svp-data` | Redpanda | Mặc định chỉ đạt `baseline` (thiếu drop ALL, seccomp); `tune_aio_events: true` (mặc định) thêm init container privileged chạy root | `tuning.tune_aio_events: false`; `podTemplate.spec.securityContext` `runAsNonRoot: true`, `runAsUser`/`runAsGroup`/`fsGroup: 101`, seccomp `RuntimeDefault`; `capabilities.drop: [ALL]` cho `redpanda`, `sidecar`, `redpanda-configurator`, `bootstrap-yaml-envsubst` qua `statefulset.podTemplate.spec`; `post_install_job.enabled: false` (mục 7) |
| `svp-data` | Valkey, MinIO, Job init | Project tự viết | Valkey `runAsUser: 999`, `runAsGroup: 1000` (`valkey-container` `9.1/alpine/Dockerfile`; entrypoint chỉ `setpriv` khi chạy root); MinIO `65532` (user của image); `/data` là volume |
| `svp-obs` | kube-prometheus-stack | Đạt khi tắt node-exporter (hostNetwork, hostPID, hostPath) | `nodeExporter.enabled: false`; Grafana không persistence (init `chown` chỉ có khi bật persistence) |
| `svp-obs` | Loki | Đạt theo mặc định | — |
| `svp-obs` | Tempo | Cần chỉnh | pod `runAsUser`/`runAsGroup`/`fsGroup: 10001`, `runAsNonRoot`, seccomp `RuntimeDefault`; `tempo.securityContext` drop ALL, không leo quyền |
| `svp-obs` | Pyroscope | Cần chỉnh | `alloy.enabled: false` (mặc định bật, pod alloy không đạt); `pyroscope.podSecurityContext` thêm seccomp `RuntimeDefault`; `pyroscope.securityContext` drop ALL, không leo quyền |
| `svp-obs` | Collector | Cần chỉnh | `podSecurityContext` `runAsNonRoot`, `runAsUser`/`runAsGroup: 10001` (user của image), seccomp; `securityContext` drop ALL, không leo quyền |
| `svp-obs` | GlitchTip | Project tự viết | `runAsUser: 5000` (`useradd -u 5000 app` trong `Dockerfile@v6.2.6`; image khai `USER app:app` không phải số nên phải ghi số), `runAsGroup: 5000` kiểm trên cluster ở bước GlitchTip; `emptyDir` cho `/tmp`, `/code/uploads` khi root fs chỉ đọc |
| `svp` | 6 service | Project tự viết (mục 10) | — |

Pod controller và proxy của Envoy Gateway, cert-manager, KEDA, Argo CD đều đạt `restricted` theo mặc định (đã render), và
namespace của chúng gắn nhãn `restricted` (bên dưới). Pod `svclb-*` của servicelb (cần `NET_ADMIN`) chạy ở `kube-system`,
không gắn nhãn, miễn trừ khỏi mức mặc định toàn cluster (bên dưới). PSA thật (admission controller) kiểm trên cluster ở bước dựng cluster và từng bước cài.

**Namespace `argo-rollouts`** cũng gắn đủ sáu nhãn PSA `restricted`: chart `svp-cluster` tạo nó ở wave 1
(`platformNamespaces` trong values), trước chart Rollouts, không kèm `default-deny` hay route. Role của chart Rollouts ở
namespace này (không value nào của chart 2.43.8 thu hẹp được) cho controller tạo Job, `update` Deployment và pod; không có
PSA nào thì controller bị chiếm tạo được pod privileged với hostPath của node và đọc mọi Secret của cluster từ đó (mục 13).
Mức mặc định toàn cluster (bên dưới) đã chặn việc đó ở namespace không nhãn, nhưng nhãn vẫn cần: ghim mức và version ngay
trên namespace, nhìn thấy ở đó, không phụ thuộc cấu hình API server; mặc định chỉ là lưới khi nhãn thiếu. Cluster tạo
trước khi có nhãn này có namespace do `--create-namespace` của chart Rollouts tạo, ngoài release nào, nên `install.sh`
cài `svp-cluster` với `--take-ownership` để Helm nhận namespace đó. **Sửa 2026-10-19.**

**Namespace công cụ** `cert-manager`, `envoy-gateway-system`, `cnpg-system`, `keda`, `argocd` cũng gắn đủ sáu nhãn PSA
`restricted`, version `podSecurityVersion` của `svp-cluster` (`v1.36`). Controller bị chiếm có quyền tạo pod (hay Job,
Deployment) ở namespace đó, nếu không có PSA nào, tạo được pod privileged với hostPath của node. Mức mặc định toàn cluster
(bên dưới) là lưới khi nhãn thiếu; nhãn vẫn gắn vì ghim version theo values, nhìn thấy ngay trên namespace và không phụ
thuộc cấu hình API server. **Sửa 2026-10-19.**
Mức chọn bằng cách so từng pod của `helm template` chart ghim với values (cả Job, init container) với tiêu chí `baseline` và
`restricted` v1.36; bộ so có đối chứng (pod trần, pod privileged bị bắt đủ lỗi):

| Namespace | Pod | Mức | Lý do |
| --- | --- | --- | --- |
| `cert-manager` | controller, cainjector, webhook, Job `startupapicheck` | `restricted` | Mọi pod đạt theo mặc định của chart |
| `envoy-gateway-system` | controller, Job certgen; proxy Envoy do controller tạo | `restricted` | Đạt; proxy theo `DefaultSecurityContext` của mã nguồn v1.9.2 (drop ALL, non-root 65532, seccomp `RuntimeDefault`, không leo quyền, volume Secret/ConfigMap, không init container) |
| `cnpg-system` | manager | `restricted` | Đạt; instance và Job của Postgres chạy ở `svp-data` |
| `keda` | operator, metrics-apiserver, admission webhooks | `restricted` | Đạt; không ScaledJob nên không Job |
| `argocd` | 6 pod (gồm Job `redis-secret-init`; applicationset 0 replica) | `restricted` | Đạt |

Không namespace nào cần `baseline`, không securityContext nào phải chỉnh. Cách gắn theo từng đường; nhãn và version chỉ định
nghĩa một chỗ, template `namespaces.yaml` của `svp-cluster`:

- `cert-manager`, `envoy-gateway-system` (wave 0, trước `svp-cluster`, vì `svp-cluster` cần CRD của chúng): đường dev
  `install.sh` render template đó (`helm template --show-only`, không release) rồi `kubectl apply --server-side
  --field-manager=svp-pod-security` trước wave 0 (namespace có sẵn từ `--create-namespace` của lần cài cũ được thêm nhãn);
  đường GitOps `syncPolicy.managedNamespaceMetadata.labels` trên hai Application đó, đi cùng `CreateNamespace=true` (version
  đọc qua symlink `deploy/argocd/apps/files/svp-cluster-values.yaml`). Namespace do `CreateNamespace` tạo là task PreSync,
  có trước mọi object của Application (gitops-engine). Hai Namespace này không render trong `svp-cluster`: hai chủ một
  Namespace thì Argo CD báo `SharedResourceWarning` và nhãn giằng nhau.
- `cnpg-system`, `keda`: `platformNamespaces` của `svp-cluster` (wave 1) như `argo-rollouts`; Argo CD chỉ đụng namespace có sẵn
  khi có `managedNamespaceMetadata`, nên hai namespace này chỉ một chủ.
- `argocd`: `gitops.sh` tạo và gắn nhãn cùng cách trước `helm upgrade --install argocd`, không `--create-namespace`.
- Namespace của project (`svp`, `svp-data`, `svp-obs`, `svp-edge`): cả hai script cũng tạo từ cùng template trước wave 0, vì
  Envoy Gateway (wave 0) gắn Role ở mỗi namespace nó watch (mục 12) và không cài được khi namespace chưa có; `svp-cluster` nhận
  lại sau (`--take-ownership` ở đường dev). `gitops.sh` render chart ở đúng revision Argo CD theo (`git archive`), không từ
  working tree.

`make drill-k8s-threats` (mục `PSA-platform`) FAIL khi một namespace ngoài `kube-system`, `kube-public`, `kube-node-lease`,
`default` không enforce `restricted` ở version của values, hay thiếu một namespace của `components.json`.
**Sửa 2026-10-19:** trước chỉ `argo-rollouts` có nhãn, năm namespace công cụ còn lại để trống.

**Mức mặc định toàn cluster** (**sửa 2026-10-19**): API server đọc `AdmissionConfiguration`
`deploy/k8s/pod-security-admission.yaml`: plugin `PodSecurity` mặc định `enforce`, `audit`, `warn` đều `restricted` ở
version `v1.36`, miễn trừ `kube-system`. Mặc định áp cho mọi namespace không có nhãn PSA (`default`, `kube-public`,
`kube-node-lease`, namespace tạo sau); nhãn của namespace thắng mặc định, nên nhãn ở trên giữ nguyên (chỗ đọc rõ
ràng), mặc định là lưới an toàn khi nhãn thiếu. Lý do: ClusterRole solver ACME của cert-manager cho controller tạo pod ở
mọi namespace (mục 12); không có mặc định thì `default` nhận pod privileged với hostPath của node, tức root trên node.

- **Cơ chế:** `k3d.yaml` mount file vào node server (`/etc/rancher/k3s/pod-security-admission.yaml`, chỉ đọc) và truyền
  `--kube-apiserver-arg=admission-control-config-file=` đường đó. k3s không có cờ PSA riêng
  (`--pod-security-admission-config-file` là của RKE2) và không tự sinh file; plugin `PodSecurity` bật sẵn, chỉ thiếu cấu
  hình (tài liệu hardening của k3s dùng đúng cờ này). Đường trên máy: k3d v5.9.0 không đổi đường tương đối của `volumes`
  thành tuyệt đối (Docker từ chối bind tương đối) nhưng thay biến môi trường trong file config trước khi đọc, nên
  `k3d.yaml` ghi `${SVP_REPO_ROOT}/deploy/k8s/...` và `ensure_cluster` (`deploy/k8s/lib.sh`) export biến này; `k3d.yaml`
  không được có `$` nào khác. File thiếu thì k3d chỉ cảnh báo và Docker mount thư mục rỗng thay vào, API server không lên,
  nên `ensure_cluster` dừng trước `cluster create`. Đường GitOps (`gitops.sh`) gọi cùng `ensure_cluster`, dùng cùng
  `k3d.yaml`.
- **Version:** ba version trong file phải bằng `podSecurityVersion` của `svp-cluster`, version mọi namespace có nhãn
  enforce (hai chỗ phải đổi cùng nhau); `ensure_cluster` so mỗi lần chạy, trước khi tạo hay khởi động cluster, lệch thì
  dừng. **Sửa 2026-10-19.**
- **Chỉ miễn trừ `kube-system`:** pod của k3s ở đó cần hơn `restricted`: `svclb-*` (`NET_ADMIN`), helper pod của
  `local-path-provisioner` (hostPath của node cho mỗi PersistentVolume của Redpanda, MinIO, CloudNativePG), coredns,
  metrics-server, Job của helm-controller. Provisioner tạo helper pod ở chính namespace của nó (`POD_NAMESPACE`; manifest
  `local-storage.yaml` của k3s v1.36.5+k3s1 đặt Deployment ở `kube-system`), nên không namespace nào khác cần miễn trừ.
- **Đọc lại mỗi lần node khởi động** (**sửa 2026-10-19**): đối số và mount do k3d gắn cho node lúc tạo, nên sửa `k3d.yaml`
  chỉ có hiệu lực ở cluster mới; còn file thì API server đọc lại từ đường trên máy mỗi lần node server khởi động
  (`k3d cluster start`, hay Docker tự bật lại node theo restart policy `unless-stopped` sau khi Docker hay máy khởi động
  lại). Sửa file có hiệu lực ở lần khởi động sau (muốn áp ngay thì dựng lại cluster). Dời hay đổi tên repo, hay checkout
  thiếu file: Docker tạo thư mục rỗng ở đường cũ và mount nó, API server không lên (`k3d cluster start` chờ hết 300 s).
  Nên với cluster có sẵn, đang dừng hay đang chạy, `ensure_cluster` đọc đối số và bind của `k3d-svp-server-0`
  (`docker inspect`) rồi dừng với lệnh `make k8s-down && make k8s-up` (mất dữ liệu cluster), không tự xoá, khi: thiếu đối
  số hay bind; nguồn của bind không còn là file thường; nguồn khác file của repo hiện tại (khác đường mà cũng khác nội
  dung; clone khác cùng nội dung vẫn dùng được). Version của file kiểm như mục trên.
- **Còn hở:** `kube-system` không enforce gì; ai tạo được pod ở đó (gồm controller cert-manager, mục 12) vẫn tới root trên
  node.
- `make drill-k8s-threats` (`PSA-platform`): `default`, `kube-public`, `kube-node-lease` không được có nhãn enforce (nhãn
  `privileged` sẽ thắng mặc định); pod privileged với hostPath `/` bị từ chối ở cả ba (`--dry-run=server`, thông báo
  `restricted:v1.36`), đối chứng pod `restricted` được nhận; `kube-system` in `info` kèm lý do.

**NetworkPolicy:** ở `svp`, `svp-data`, `svp-obs`, `svp-edge` có policy `default-deny` chặn cả `Ingress` lẫn `Egress` cho
mọi pod, và policy `allow-dns` mở egress tới `kube-dns` (`kube-system`, label `k8s-app: kube-dns`) cổng 53 UDP/TCP cho mọi
pod. Mỗi luồng khác một policy riêng theo label pod, đặt trong chart cài cùng hoặc trước thành phần đó (thứ tự cài ở mục 7).
Namespace platform không chặn mặc định.

- **Thực thi:** k3s nhúng network policy controller lấy từ kube-router (`github.com/k3s-io/kube-router/v2 v2.6.3-k3s1`,
  `pkg/agent/netpol@v1.36.5+k3s1`; tài liệu <https://docs.k3s.io/networking/networking-services#network-policy-controller>).
  Tài liệu k3s không nói rõ egress, nhưng mã nguồn có: `policy.go` (`processEgressRules`) và `pod.go` đưa traffic từ mỗi
  pod IP qua chain firewall của pod ở cả INPUT, FORWARD và OUTPUT. Chạy thử ingress/egress trên cluster ở bước dựng cluster.
- **Traffic từ node:** Kubernetes ghi pod không chặn được truy cập từ node mà nó đang chạy
  (<https://kubernetes.io/docs/concepts/services-networking/network-policies/>, mục "What you can't do"), nên probe của
  kubelet và `kubectl port-forward` (đi qua kubelet và runtime, không qua mạng pod) không cần policy.
- **Gọi API server:** API server của k3s chạy ở mạng host của node server, cổng 6443; pod gọi Service `kubernetes`
  `10.43.0.1:443`, kube-proxy DNAT sang `<IP node server>:6443`. Rule của kube-router nằm ở bảng filter, chạy **sau** DNAT,
  nên rule theo `10.43.0.1:443` không còn khớp (suy từ mã nguồn; Kubernetes để thứ tự này "not defined"). Quyết định: policy
  `allow-kube-api` ở `svp-data` và `svp-obs` mở egress tới `ipBlock 10.200.0.0/24` cổng TCP 6443 **và** `10.43.0.1/32` cổng
  TCP 443 (đúng ở cả hai thứ tự), chỉ cho pod có label **`svp-kube-api: allow`**. Values của từng chart gắn label đó cho
  đúng pod cần: instance CloudNativePG (`inheritedMetadata.labels` của `Cluster`, instance manager gọi API server theo
  `docs/src/security.md` và kiểm cô lập primary ở `instance_manager.md`), Redpanda (sidecar giữ lease qua Role `rp-sidecar`),
  Prometheus operator, Prometheus (service discovery của PodMonitor/ServiceMonitor), kube-state-metrics, Grafana (sidecar
  đọc ConfigMap dashboard). Chạy thử trên cluster ở bước dựng cluster; nếu đường không qua DNAT như suy luận thì giữ cả hai
  rule. Namespace platform không chặn egress nên không cần gì.
- **Webhook:** API server gọi webhook từ mạng node; webhook nằm ở namespace platform (không chặn mặc định) thì không cần
  policy. Webhook duy nhất định đặt ở namespace bị chặn là admission webhook của Prometheus operator: **tắt**
  (`prometheusOperator.admissionWebhooks.enabled: false`, `prometheusOperator.tls.enabled: false`); rule đã được
  `make slo-check` kiểm bằng promtool trước khi vào repo.

**Luồng được mở.** Bảng dưới là danh sách đủ; thêm luồng là thêm dòng cùng policy. Nguồn và đích nằm ở hai namespace bị
chặn thì cần policy egress ở namespace nguồn **và** ingress ở namespace đích; nguồn ở namespace platform (không chặn egress)
chỉ cần ingress ở đích. Chọn namespace bằng nhãn `kubernetes.io/metadata.name`. Cổng là cổng của pod (NetworkPolicy so
cổng sau DNAT), không phải cổng Service: Grafana `3000` sau Service `kps-grafana:80`.

| Nguồn (namespace) | Đích (namespace) | Cổng TCP | Lý do |
| --- | --- | --- | --- |
| Envoy proxy (`envoy-gateway-system`; `app.kubernetes.io/name: envoy`, `gateway.envoyproxy.io/owning-gateway-name: svp`) | gateway, gồm pod canary (`svp`) | 8080 | HTTPRoute `api` (mục 9, 13); RL-1 |
| Envoy proxy | MinIO (`svp-data`) | 9000 | HTTPRoute `s3`: presigned POST, phát HLS |
| gateway (`svp`) | user-, video-, engagement-, feed-service (`svp`) | 9101, 9102, 9103, 9104 | gRPC (`*_SERVICE_ADDR` của compose) |
| gateway, feed-service (`svp`) | Valkey (`svp-data`) | 6379 | rate limit db 10, cache explore db 14 |
| user-, video-, engagement-, feed-service, media-worker (`svp`) | Redpanda (`svp-data`) | 9092 | Kafka (mục 5) |
| KEDA operator (`keda`; `app: keda-operator`) | Redpanda (`svp-data`) | 9092 | Đọc lag cho ScaledObject (mục 10) |
| user-, video-, engagement-, feed-service và Job migrate của chúng (`svp`) | Postgres `svp-pg` (`svp-data`; `cnpg.io/cluster: svp-pg`) | 5432 | Database của từng service |
| video-service, media-worker (`svp`) | MinIO (`svp-data`) | 9000 | `S3_ENDPOINT` |
| CloudNativePG operator (`cnpg-system`; `app.kubernetes.io/name: cloudnative-pg`) | instance `svp-pg` (`svp-data`) | 8000 | Operator đọc trạng thái instance qua cổng status (TLS); `docs/src/security.md@v1.30.1`, mục "Network Policies" |
| Job init của chart `svp-data` (`svp-data`) | Postgres, MinIO, Redpanda (`svp-data`) | 5432; 9000; 9092, 9644 | Bootstrap database, `init.sh`, topic + user + ACL (Admin API) |
| 6 service (`svp`) | Collector (`svp-obs`) | 4317 | OTLP (mục 11) |
| 5 service, không media-worker (`svp`) | Pyroscope, GlitchTip (`svp-obs`) | 4040; 8000 | Profile, lỗi (như compose) |
| Collector (`svp-obs`) | Prometheus, Loki, Tempo (`svp-obs`) | 9090; 3100; 4317 | Exporter OTLP |
| Collector (`svp-obs`) | Redpanda (`svp-data`) | 9644 | Scrape `/public_metrics` (mục 5) |
| Tempo (`svp-obs`) | Prometheus (`svp-obs`) | 9090 | Remote write của metrics-generator |
| Grafana (`svp-obs`) | Prometheus, Loki, Tempo, Pyroscope, Alertmanager (`svp-obs`) | 9090; 3100; 3200; 4040; 9093 | Datasource |
| Prometheus (`svp-obs`) | Alertmanager (`svp-obs`) | 9093 | Gửi cảnh báo |
| Prometheus (`svp-obs`) | Grafana, kube-state-metrics, Alertmanager, Prometheus operator (`svp-obs`) | 3000; 8080; 9093, 8080; 8080 | Scrape theo 6 ServiceMonitor của kube-prometheus-stack (chính Prometheus thì trong pod, không cần) |
| Prometheus (`svp-obs`) | Envoy proxy (`envoy-gateway-system`) | 19001 | `PodMonitor` metric canary (mục 13) |
| Prometheus (`svp-obs`) | kubelet, `ipBlock 10.200.0.0/24` | 10250 | cAdvisor, probe (mục 11) |
| Argo Rollouts controller (`argo-rollouts`; `app.kubernetes.io/name: argo-rollouts`) | Prometheus (`svp-obs`) | 9090 | AnalysisRun truy vấn `http://kps-prometheus.svp-obs:9090` (mục 13) |
| GlitchTip và Job init GlitchTip (`svp-obs`) | Postgres `svp-pg` (`svp-data`) | 5432 | Database `svp_glitchtip` |
| Alertmanager (`svp-obs`) | Internet: `ipBlock 0.0.0.0/0` trừ dải riêng | 443 | Telegram (bên dưới) |
| Pod có nhãn `svp-kube-api: allow` (`svp-data`, `svp-obs`) | API server | 6443, 443 | `allow-kube-api` (ở trên) |

Không luồng nào khác ra ngoài cluster: media-worker và mọi pod của project không tới được internet (FF-5).

**Egress của Alertmanager tới Telegram.** NetworkPolicy không có luật theo tên miền (`NetworkPolicyPeer` chỉ có
`podSelector`, `namespaceSelector`, `ipBlock`), kube-router của k3s cũng không thêm. Policy `allow-alertmanager-telegram`
chỉ chọn pod Alertmanager, mở egress TCP **443** tới `ipBlock 0.0.0.0/0` với `except: [10.0.0.0/8, 172.16.0.0/12,
192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10]`; DNS đã có `allow-dns`. Dải pod `10.42.0.0/16`, service `10.43.0.0/16` và
node `10.200.0.0/24` nằm trong `10.0.0.0/8`, nên luật này không mở đường vào cluster hay mạng máy. kube-router dịch
`except` thành mục `nomatch` của ipset (`pkg/controllers/netpol/policy.go@v2.6.3-k3s1`). Policy có cả khi Telegram tắt
(Alertmanager không gửi gì khi thiếu biến). Cái giá: không khoá được đúng `api.telegram.org`; Alertmanager bị chiếm gửi được
tới mọi địa chỉ công khai cổng 443. Lựa chọn bị loại: `ipBlock` theo danh sách CIDR Telegram công bố
(<https://core.telegram.org/resources/cidr.txt>, 9 dải IPv4 ngày 2026-10-18) hẹp hơn, nhưng danh sách đổi không báo trước và
khi lệch thì cảnh báo mất mà không có lỗi nào chỉ ra. Compose cũng không giới hạn đích của Alertmanager.

## 4. Dữ liệu ở đâu (IN-9)

### Các lựa chọn

#### A. Postgres và Redis native trên máy (pod tới qua `host.k3d.internal`)

- Được: giống compose; giống cloud ở chỗ database nằm ngoài cluster (RDS, ElastiCache ở giai đoạn 7); không thêm RAM.
- Mất: Postgres native là `trust` cho loopback và dùng chung với project khác (IN-9): pod tới host đi qua đúng lỗ đó, pod bị
  chiếm đăng nhập được superuser không mật khẩu và đọc database của project khác. Sửa `pg_hba` là sửa máy dùng chung, ngoài
  phạm vi lab. Redis native db 0/5/7 chứa dữ liệu dự án khác, IN-7 không có ranh giới. Không dựng/xoá sạch theo cluster.

#### B. Tất cả trong cluster: CloudNativePG, Valkey, Redpanda, MinIO

- Được: cluster tự chứa, không còn lỗ `trust`; Postgres xác thực `scram-sha-256` (IN-9 đạt); không đụng Redis dùng chung;
  `k8s-down` xoá sạch; học operator (CRD `Cluster`, backup về sau ở giai đoạn 6).
- Mất: thêm ~0,6 GiB so với chỉ Redpanda + MinIO; tự vận hành operator; khác cloud ở chỗ database nằm trong cluster.

#### C. Postgres trong cluster bằng StatefulSet tự viết hay chart Bitnami

- Mất: tự viết bootstrap, failover, TLS; Bitnami đã đổi chính sách image miễn phí từ 2025. CloudNativePG là operator CNCF
  phổ biến nhất cho Postgres trên Kubernetes.

### Quyết định

Chọn **B**. Test (`make test`) vẫn dùng Postgres/Redis native như cũ.

- **Postgres:** CloudNativePG operator ở `cnpg-system`; một `Cluster` **`svp-pg`** ở `svp-data`, `instances: 1`,
  `imageName` ở bảng mục 1 (major **15** khớp Postgres native 15.18 mà test chạy; 15.19 là bản vá mới nhất của major 15,
  cùng digest với image catalog chính thức của CloudNativePG; loại `minimal` vì không cần extension; loại `system` đã
  deprecated theo README `cloudnative-pg/postgres-containers`), PVC local-path 2 Gi. Service ghi `svp-pg-rw.svp-data:5432`.
  - `pg_hba` mặc định của CloudNativePG 1.30 (`docs/src/postgresql_conf.md@v1.30.1`, `pkg/postgres/configuration.go`): chỉ
    `local ... peer` cho kết nối socket trong pod, `hostssl ... streaming_replica ... cert` cho replication, rule của người
    dùng, rồi dòng cuối **`host all all all scram-sha-256`** (Postgres ≥ 14). Không thêm rule nào: kết nối TCP luôn cần mật
    khẩu SCRAM, không có `trust`. Kiểm ở diễn tập threat model (kết nối không mật khẩu bị từ chối).
  - TLS của server do operator tự cấp: chuỗi kết nối dùng `sslmode=require` (mã hoá, không xác minh CA; xác minh cùng mTLS
    là IN-3, giai đoạn 6).
  - `enableSuperuserAccess: true`, `superuserSecret: pg-superuser` (mặc định tắt): superuser `postgres` chỉ để Job
    bootstrap chạy **`deploy/postgres/bootstrap.sql` có sẵn** cho `user`, `video`, `engagement`, `feed`, `glitchtip`, mật khẩu
    qua `SVP_MIGRATOR_PASSWORD`/`SVP_APP_PASSWORD` như `bootstrap.sh` (không lên dòng lệnh). Không service nào nhận Secret
    superuser (IN-6).
  - Một instance nhiều database, mỗi service role migrator/app riêng: khớp quyết định "Postgres trên cloud: một instance"
    (plan, 2026-10-18). Database `app` mà `initdb` mặc định tạo để nguyên; không service nào dùng, chỉ exporter metric của
    CloudNativePG nối vào.
  - **CONNECT của `postgres`, `app`, `template1`:** `bootstrap.sql` đã bỏ CONNECT của PUBLIC trên mọi database `svp_*`, ba
    database của `initdb` giữ CONNECT mặc định của PUBLIC, nên mọi role `svp_*` đăng nhập được vào đó (và tạo bảng tạm ở hai
    database đầu) dù không service nào cần. Superuser bỏ qua kiểm quyền, role chủ `app` giữ CONNECT trên database của nó. Job
    `pg-bootstrap` (mỗi lần install/upgrade, nên cluster cũ cũng có) chờ hai role của operator có trong `pg_roles` (instance
    manager tạo chúng sau khi server chạy, có thể muộn hơn lần login superuser đầu; quá hạn chờ thì Job lỗi, không đổi gì),
    rồi trong **một transaction**: `GRANT CONNECT ON DATABASE postgres TO cnpg_metrics_exporter, streaming_replica`,
    `GRANT CONNECT ON DATABASE app TO cnpg_metrics_exporter`, `REVOKE CONNECT ON DATABASE postgres, app, template1 FROM
    PUBLIC`. Theo mã nguồn CloudNativePG v1.30.1: `cnpg_metrics_exporter` (NOSUPERUSER, `pg_monitor`) nối `postgres` (up, WAL)
    và `app` (query mặc định của collector chạy trên database ứng dụng); `streaming_replica` nối `postgres` (pg_rewind, slot ở
    replica; chỉ dùng khi `instances` > 1); không role không-superuser nào của operator nối `template1`. **Sửa 2026-10-19.**
- **Valkey:** Deployment `valkey` 1 replica ở `svp-data`, Service `valkey.svp-data:6379`, image ở bảng mục 1, lệnh
  `valkey-server --save "" --appendonly no --maxmemory 64mb --maxmemory-policy noeviction` (không persistence; `noeviction`
  như Redis native ở [ADR-0010 §1](0010-redis-ratelimit-cache-resilience-stage2c.md#1-redis): đầy thì ghi lỗi, gateway rơi
  về bộ đếm dự phòng có metric, không lặng lẽ xoá khoá rate limit). Không mật khẩu: IN-7 vẫn chấp nhận ở local, NetworkPolicy
  chỉ cho pod gateway và feed-service vào 6379. Giữ số db và tiền tố: gateway `redis://valkey.svp-data:6379/10` (`svp:gw:`),
  feed-service `redis://valkey.svp-data:6379/14` (`svp:feed:`).
- **Redpanda:** chart chính thức (mục 1), release `redpanda` ở `svp-data`, 1 broker, `resources.cpu.cores: 1` +
  `overprovisioned: true` + `memory.container.max: 1280Mi` (chart sinh `--smp=1 --memory=1024M --reserve-memory=202M`, như
  compose `--smp 1 --memory 1G`), PVC 2 Gi, `console.enabled: false`, `tuning.tune_aio_events: false`, **SASL
  SCRAM-SHA-256, không TLS** (`tls.enabled: false`; mã hoá đường truyền nội bộ là IN-3, giai đoạn 6), listener Kafka nội bộ
  **9092** (`listeners.kafka.port: 9092`, mặc định của chart là 9093; đặt như compose), mọi listener external tắt bằng
  `listeners.{admin,kafka,http,schemaRegistry}.external.default.enabled: false`: `external.enabled: false` chỉ bỏ Service,
  listener `default` vẫn nghe trên `0.0.0.0` ở 9645, 9094, 8083, 8084 (`redpanda.ExternalListener.IsEnabled` mặc định `true`;
  đã `helm template`). Broker quảng bá `redpanda-0.redpanda.svp-data.svc.cluster.local.:9092`; client dùng
  `KAFKA_BROKERS=redpanda.svp-data.svc.cluster.local:9092`. Admin API 9644, bắt buộc xác thực (mục 5).
  - Topic tạo bằng **`deploy/redpanda/create-topics.sh` có sẵn** (Job init, mục 5). `rpk` đọc `RPK_BROKERS`, `RPK_USER`,
    `RPK_PASS`, `RPK_SASL_MECHANISM`, `RPK_ADMIN_HOSTS` (bảng biến của
    <https://docs.redpanda.com/current/reference/rpk/rpk-x-options/> và mã nguồn rpk), và gửi chính user/pass SASL làm
    HTTP Basic cho Admin API (`adminapi/admin.go`). Script giữ nguyên, chỉ thêm biến môi trường; compose không thấy khác.
  - `auto_create_topics_enabled: false`, `enable_consumer_group_metrics: [group, partition, consumer_lag]` và
    `admin_api_require_auth: true` (mục 5) đặt ở `config.cluster` (áp khi cluster hình thành qua `.bootstrap.yaml`;
    `helm template` thấy cả ba trong `.bootstrap.json.in`); `create-topics.sh` vẫn đặt lại thuộc tính thứ hai mỗi lần chạy
    như ở compose.
- **MinIO:** StatefulSet `minio` 1 replica ở `svp-data`, image Chainguard ghim digest như compose (uid 65532), PVC 5 Gi,
  Service `minio.svp-data:9000` (console 9001 không có route). Job init chạy **`deploy/minio/init.sh` có sẵn** cùng ba file
  policy JSON; script dùng `MC_HOST_svp=http://...@minio:9000`, trong namespace `svp-data` tên `minio` phân giải đúng nên
  không phải sửa.

**Trade-off:** phương án A giống cloud hơn (giai đoạn 7 dùng RDS/ElastiCache ngoài cluster, cấu hình gần hơn), B tự chứa
(không lỗ `trust`, không đụng Redis dùng chung, dựng/xoá sạch theo cluster) đổi lấy ~0,6 GiB RAM và công vận hành
operator. Cách nối của service (biến `DATABASE_URL`, `REDIS_URL`) giống nhau ở cả hai, nên giai đoạn 7 chỉ đổi giá trị.

## 5. Redpanda SASL và ACL (IN-4, FF-6)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **SASL SCRAM-SHA-256 mỗi service một user + ACL theo topic/group** | Broker ép luật "chỉ service sở hữu event được ghi topic" (ADR-0001 luật 3); franz-go hỗ trợ trong cùng module | Thêm user, mật khẩu, Job tạo ACL |
| mTLS (chứng chỉ client làm danh tính) | Có cả mã hoá | Phải cấp/xoay chứng chỉ cho từng service; IN-3 là việc giai đoạn 6 |
| Một user chung | Ít cấu hình | Không có phân quyền: service bị chiếm vẫn ghi mọi topic |
| Bật SASL cả ở compose | Một cấu hình | Diễn tập giai đoạn 2–3 dùng `rpk` không mật khẩu, phải sửa hết; dev chậm hơn |

### Quyết định

SASL SCRAM-SHA-256, mỗi service một user, ACL tối thiểu, `resource-pattern-type literal`. **Compose không bật SASL**
(dev nhanh, diễn tập giai đoạn 2–3 giữ nguyên): IN-4 chỉ thực thi ở k3d.

- **Client:** `internal/kafkax` (đã có) đọc `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`; cả hai rỗng thì không SASL, một
  trong hai rỗng thì lỗi khởi động; cơ chế cố định SCRAM-SHA-256 qua `github.com/twmb/franz-go/pkg/sasl/scram` (cùng module
  franz-go, không thêm dependency).
- **Producer idempotent không cần `IDEMPOTENT_WRITE`:** handler `InitProducerId` của Redpanda (`src/v/kafka/server/server.cc`,
  đọc ở tag v26.2.2, bản công khai mới nhất của nhánh v26.2.x) duyệt mọi topic xem principal có `WRITE` không, chỉ khi không
  có topic nào mới xét `IDEMPOTENT_WRITE` trên cluster, đúng ngữ nghĩa KIP-679. `WRITE` trên topic của mình là đủ. Redpanda suy
  `DESCRIBE` từ `READ`, `WRITE`, `DELETE`, `ALTER` như Kafka (`security/authorizer.cc`, `acl_any_implied_ops_allowed`). Kiểm
  trên cluster ở diễn tập threat model (broker v26.2.4).
- **Superuser:** chart tạo bootstrap user và coi mọi dòng trong Secret `auth.sasl.secretRef` là superuser; sidecar của chart
  ghi đè `superusers` bằng đúng tập đó (chạy `rpk cluster config set superusers` tay sẽ bị ghi đè). Đặt
  `auth.sasl.bootstrapUser.name: svp-admin` (mật khẩu từ Secret `redpanda-bootstrap`), `auth.sasl.users: []` và Secret
  `redpanda-superusers` chỉ có dòng `svp-admin`: superuser duy nhất là **`svp-admin`**, chỉ Job init dùng. User ứng dụng
  **không bao giờ** nằm trong Secret đó; Job init tạo chúng bằng `rpk security user create`.
- **Bảng user → quyền**, tên topic và group lấy từ code:

| User | WRITE topic | READ topic | READ group | Nguồn trong code |
| --- | --- | --- | --- | --- |
| `svp-user-service` | `user.follows.v1` | — | — | `services/user-service/internal/server/server.go` (`TopicUserFollows`, relay outbox) |
| `svp-video-service` | `video.lifecycle.v1`, `media.transcodes.v1.dlq` | `media.transcodes.v1` | `video-service` | `services/video-service/internal/server/server.go` (`TopicVideoLifecycle`), `transcode.go` (`TopicMediaTranscodes`, `TranscodeGroup`) |
| `svp-engagement-service` | `engagement.views.v1`, `engagement.views.v1.dlq` | `engagement.views.v1` | `engagement-service` | `services/engagement-service/internal/server/server.go` (`TopicViews`), `views.go` (`ViewsGroup`; `kafkax.EndOffsets` cần `DESCRIBE` topic, đã có nhờ `READ`) |
| `svp-feed-service` | `user.follows.v1.dlq`, `video.lifecycle.v1.dlq` | `user.follows.v1`, `video.lifecycle.v1` | `feed-service` | `services/feed-service/internal/projector/projector.go` (`TopicUserFollows`, `TopicVideoLifecycle`, `Group`) |
| `svp-media-worker` | `media.transcodes.v1`, `video.lifecycle.v1.dlq` | `video.lifecycle.v1` | `media-worker` | `services/media-worker/internal/worker/worker.go` (`InputTopic`, `OutputTopic`, `Group`) |
| `svp-keda` | — | — (chỉ `DESCRIBE` topic `video.lifecycle.v1`) | — (chỉ `DESCRIBE` group `media-worker`) | Kafka scaler của KEDA 2.21 (IBM/sarama v1.60.2) gửi Metadata, FindCoordinator, OffsetFetch, ListOffsets: cần `DESCRIBE` trên topic và group |
| `svp-admin` | superuser | superuser | superuser | Chỉ Job init |

  Topic DLQ là `<topic>` + `kafkax.DLQSuffix` (`".dlq"`, `internal/kafkax/consumer.go`), do consumer của topic gốc ghi (cả
  consumer theo lô của engagement-service ghi DLQ cho record hỏng). `video.lifecycle.v1.dlq` có hai người ghi (feed-service,
  media-worker), phân biệt bằng header `dlq-group`. Không user ứng dụng nào được `CREATE`, `ALTER`, `DELETE` hay quyền trên
  cluster. ACL phân quyền đọc theo group nên service này không đọc được group của service khác.
- **Job init** (chart `svp-data`, cùng Job với `create-topics.sh`), chạy bằng `svp-admin` qua `RPK_USER`/`RPK_PASS`/
  `RPK_SASL_MECHANISM=SCRAM-SHA-256`, `RPK_BROKERS=redpanda.svp-data.svc.cluster.local:9092`,
  `RPK_ADMIN_HOSTS=redpanda-0.redpanda.svp-data.svc.cluster.local:9644`; idempotent:
  - `rpk security user create <user> -p "$PW" --mechanism scram-sha-256` (ở lệnh này `-p` là `--new-password`; thông tin
    đăng nhập admin đi qua biến môi trường, không qua cờ), user đã có thì `rpk security user update` để đổi theo `.env`;
  - `rpk security acl create --allow-principal User:<user> --operation <op> --topic <t> | --group <g>
    --resource-pattern-type literal` (<https://docs.redpanda.com/current/reference/rpk/rpk-security/rpk-security-acl-create/>).
- **Admin API bắt buộc xác thực:** chart bật `enable_sasl`, `kafka_enable_authorization` và `authentication_method: sasl`
  cho listener Kafka nhưng **không** đặt `admin_api_require_auth`; khi đó người gọi Admin API không kèm `Authorization`
  được coi như superuser (`src/v/security/request_auth.cc@v26.2.2`, nhánh "No Authorization header"). Để vậy thì pod nào
  tới được 9644 (Collector chỉ cần scrape) cũng đổi được cấu hình cluster và quản lý user, vượt ACL Kafka và vượt giới hạn
  "`svp-admin` chỉ Job init". Quyết định: **`config.cluster.admin_api_require_auth: true`**. Đã kiểm từng thứ gọi Admin API:
  - Route có mức quyền riêng (`register_route<publik|user|superuser>` trong `src/v/redpanda/admin/server.cc@v26.2.2`):
    `/v1/status/ready` là `publik` (startupProbe của chart vẫn chạy); `/v1/node_config` và bật/tắt maintenance là
    `superuser`; `/v1/brokers` là `user`. Người gọi ẩn danh khi đã bật thì không phải superuser, route `user`/`superuser`
    trả lỗi xác thực.
  - **`/public_metrics` và `/metrics` không cần xác thực:** `configure_metrics_route` đăng ký thẳng qua
    `ss::prometheus::add_prometheus_routes` của seastar, ngoài `register_route`. Collector scrape
    `http://redpanda-0.redpanda.svp-data.svc.cluster.local:9644/public_metrics` không kèm mật khẩu và không có mật khẩu nào
    để làm gì khác. Không cần receiver `kafkametrics` hay user Kafka riêng cho Collector.
  - **Sidecar của chart** (broker probe gọi `GetNodeConfig`, đồng bộ user, decommissioner) chạy với `RPK_USER=svp-admin`,
    `RPK_PASS` từ Secret `redpanda-bootstrap`, `RPK_SASL_MECHANISM` (`helm template`); rpk ánh xạ `RPK_USER`/`RPK_PASS` vào
    profile (`envOverrides`, `src/go/rpk/pkg/config/params.go@v26.2.2`) và client Admin API của operator gửi chúng làm HTTP
    Basic (`getAdminAuth`, `operator/pkg/client/rpk.go@operator/v26.2.4`). Init container `redpanda-configurator` chỉ sửa
    `redpanda.yaml` cục bộ, không gọi Admin API.
  - **Hook `postStart` của container `redpanda`** gọi `curl` không kèm thông tin đăng nhập (`common.sh` trong
    `templates/_secrets.go.tpl` của chart 26.2.4 chỉ thêm cờ TLS; không value nào thêm được `-u`): `/v1/node_config` bị từ
    chối, vòng `until` chạy tới `timeout` 45 s (một nửa `terminationGracePeriodSeconds` 90), rồi wrapper trả `true`
    (`redpanda.wrapLifecycleHook`). Container không bị kill, nhưng probe chỉ bắt đầu sau `postStart`, nên mỗi lần pod khởi động
    chậm thêm ~45 s. Việc của hook là gỡ chế độ maintenance mà `preStop` đặt; `preStop` chỉ đặt maintenance khi chart có hơn 2
    replica (`templates/_secrets.go.tpl`), nên với một broker hook không có việc gì. Quyết định: thay `postStart` bằng lệnh
    rỗng qua `statefulset.podTemplate.spec.containers: [{name: redpanda, lifecycle: {postStart: {exec: {command:
    ["/bin/true"]}}}}]` (đã `helm template`: `postStart` bị thay, `preStop` giữ nguyên). Job init không phải làm thay việc gì.
    Lên 3 broker trở lên thì hook này cần chạy lại với thông tin đăng nhập: chart chưa hỗ trợ, phải xem lại.
  - **Job init** gọi Admin API qua `rpk` bằng `svp-admin` (`RPK_USER`/`RPK_PASS`, HTTP Basic như sidecar); `rpk cluster
    config set` trong `create-topics.sh` cần superuser.
  - Chạy thật ở bước tầng dữ liệu: pod Redpanda Ready không chờ 45 s, `curl` không kèm thông tin đăng nhập tới
    `/v1/node_config` bị từ chối, tới `/public_metrics` trả 200.
- **NetworkPolicy:** **9644** chỉ từ Job init và Collector; 8081 (schema registry, chạy không xác thực) và 8082 (HTTP proxy)
  không mở cho ai. Kafka 9092 chỉ từ 5 service có Kafka, KEDA (`keda`) và Job init (bảng luồng mục 3).

## 6. Image

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Registry local của k3d** | Argo CD/Rollouts kéo theo tag như cloud; giữ lịch sử tag; mọi node kéo từ một chỗ | Thêm một container (~20 MiB) |
| `k3d image import` | Không thêm container | Không có tag để Argo CD trỏ tới; chép vào từng node; mất khi node tạo lại |
| **Tag phát hành = SHA commit, ghi vào values bằng commit** | Truy được image về commit; GitOps thấy thay đổi qua git | Phải commit thêm một lần mỗi lần phát hành |
| Tag `latest`/`dev` cố định | Không ghi gì | Argo CD và kubelet không biết image đã đổi; không rollback được theo git |
| **Tag dev theo image ID** | Cùng đầu vào → cùng tag, `k8s-up` lặp lại không tạo revision mới (gateway là `Rollout`, mỗi revision là một canary cần traffic) | Tag không đọc ra commit |

### Quyết định

- **Registry:** `k3d registry create svp-registry --port 127.0.0.1:5111 --image <registry ghim ở mục 1>`. Container tên
  `k3d-svp-registry` (k3d thêm tiền tố `k3d-`), cổng trong là 5000, chỉ bind `127.0.0.1:5111`. Cluster dùng nó qua
  `registries.use: [k3d-svp-registry:5111]`; k3d sinh `registries.yaml` cho containerd ánh xạ cả `k3d-svp-registry:5111` lẫn
  `k3d-svp-registry:5000` về `http://k3d-svp-registry:5000` (`pkg/client/registry.go@v5.9.0`).
  - Đẩy từ host: `127.0.0.1:5111/svp/<svc>:<tag>` (Docker cho HTTP tới `127.0.0.1` mà không cần sửa cấu hình daemon).
  - Image trong manifest: **`k3d-svp-registry:5111/svp/<svc>:<tag>`** (cùng registry, tên mà node phân giải được trong mạng
    `k3d-svp`). Values file ghi `image.repository: k3d-svp-registry:5111/svp/<svc>`.
  - `k8s-up`, `k8s-gitops-up`, `k8s-release` dùng chung một hàm `ensure_registry` (tạo khi chưa có, idempotent, cùng tên và
    cổng); `k8s-release` chỉ cần registry, không cần cluster. `k8s-down` xoá cluster và registry.
- **Build** qua Makefile: `env -u DOCKER_DEFAULT_PLATFORM docker build` (arm64), `deploy/docker/service.Dockerfile` và
  `media-worker.Dockerfile` có sẵn.
- **Tag phát hành** = **12 ký tự hex đầu SHA của commit** đã build. `make k8s-release SVC=<svc>|all` từ chối khi đường dẫn
  image đọc có thay đổi chưa commit (`go.mod`, `go.sum`, `gen/`, `internal/`, `services/<svc>/`, Dockerfile của nó), build từ
  `git archive <sha>` vào thư mục tạm (không đụng working tree), push, rồi ghi `image.tag` vào
  `deploy/k8s/values/services/<svc>.yaml` để người học commit. Cùng một hàm `build_release_image <svc> <sha>` dựng lại image
  của một tag phát hành bị mất (registry xoá cùng cluster).
- **Tag dev** từ working tree = **`dev-<12 ký tự hex đầu của image ID>`**: build cache cho cùng image ID khi đầu vào không đổi,
  nên `k8s-up` lặp lại không đổi pod template. Chỉ truyền qua `--set image.tag=...`, không ghi file.
- Chart `svp-service` báo lỗi bằng `required` (nêu tên release) khi `image.tag` rỗng.

## 7. Chart và bố cục thư mục

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Một chart ứng dụng chung `svp-service`, 6 release, 6 values file** | 6 service cùng một hình (một binary Go, cùng probe, securityContext, policy); phần riêng chỉ là cờ | Template có nhánh `if` cho gRPC/HTTP, migrate, Rollout, HPA, PDB, ScaledObject |
| 6 chart riêng | Mỗi chart đơn giản | Lặp template 6 lần; sửa securityContext ở 6 chỗ |
| Library chart + 6 chart mỏng | Không lặp, chart riêng | Phải `helm dependency build` trước khi cài; thêm bước cho Argo CD |
| Danh sách thành phần ở hai nơi (script cài và Argo CD) | Mỗi bên tự do | Hai đường cài lệch nhau |
| **Một file `components.json` cho cả hai đường** | Đường dev và GitOps cài cùng thứ tự, cùng version | Chart app-of-apps phải đọc JSON |
| **File giai đoạn 3 dùng lại bằng symlink trong chart** | Một nguồn cho compose và k8s | Phụ thuộc Helm và Argo CD theo symlink (đã kiểm, bên dưới) |
| Chép file vào chart + target kiểm giống nhau | Không phụ thuộc symlink | Hai bản phải giữ khớp |

### Quyết định

```text
deploy/
  helm/
    svp-service/          chart ứng dụng chung, 6 release
    svp-cluster/          namespace, PSA, default-deny, allow-dns, allow-kube-api, ClusterIssuer, Certificate, Gateway
    svp-data/             CloudNativePG Cluster, Valkey, MinIO, Job init (Postgres, MinIO, Redpanda), policy svp-data,
                          HTTPRoute s3
    svp-observability/    PrometheusRule, dashboard, datasource, PodMonitor Envoy, ConfigMap Collector, GlitchTip,
                          policy svp-obs
  k8s/
    k8s.mk                target k8s-* (include từ Makefile)
    k3d.yaml  install.sh  secrets.sh  lib.sh  release.sh  gitops.sh  glitchtip-init.sh
    pod-security-admission.yaml       mức PSA mặc định của API server (mục 3)
    values/<component>.yaml           values cho chart upstream
    values/services/<svc>.yaml        values của 6 release svp-service
    drills/
  argocd/apps/            chart app-of-apps: Chart.yaml, templates/, components.json
  observability/otelcol/k8s-config.yaml   cấu hình Collector trong cluster
```

**`deploy/argocd/apps/components.json`** là danh sách một nguồn: mỗi phần tử có `name` (= tên release Helm = tên
Application), `namespace`, `wave`, nguồn (`repo` + `chart` + `version`, hoặc `path` trong repo) và `values` (đường dẫn values
file). Chart app-of-apps đọc nó bằng `.Files.Get "components.json" | fromJson` để sinh `Application`; `install.sh` đọc bằng
`jq` để `helm upgrade --install --wait` theo wave tăng dần. Thứ tự (wave nhỏ cài trước):

| Wave | Thành phần (namespace) | Vì sao ở đây |
| --- | --- | --- |
| 0 | `cert-manager` (`cert-manager`), `envoy-gateway` (`envoy-gateway-system`) | CRD Certificate/ClusterIssuer và Gateway API cho wave 1 |
| 1 | `svp-cluster` | Namespace, PSA, `default-deny`, `allow-dns`, `allow-kube-api` có trước mọi pod của project; namespace `argo-rollouts`, `cnpg-system`, `keda` (chỉ PSA, mục 3) trước chart của chúng; Role và Certificate webhook của CloudNativePG (mục 12); issuer, `Gateway` (sửa 2026-10-19: thêm `cnpg-system`, `keda`, phần CloudNativePG) |
| 2 | `cloudnative-pg` (`cnpg-system`), `keda` (`keda`), `argo-rollouts` (`argo-rollouts`), `kube-prometheus-stack` (`svp-obs`) | Operator và CRD; pod của kube-prometheus-stack chỉ cần `allow-kube-api` lúc cài |
| 3 | `redpanda` (`svp-data`), `loki`, `tempo`, `pyroscope` (`svp-obs`) | Pod sẵn sàng được dưới `default-deny` (probe từ node, gọi chính mình trong pod); chart Redpanda tắt `post_install_job` vì Job đó cần tới broker trước khi policy của `svp-data` có |
| 4 | `svp-data` | Policy của `svp-data` (kể cả cho pod Redpanda đã chạy), `Cluster` Postgres, Valkey, MinIO, rồi Job init dạng hook `post-install,post-upgrade` (bootstrap Postgres, `init.sh` MinIO, topic + user + ACL Redpanda) |
| 5 | `svp-observability` | Policy của `svp-obs`, rule, dashboard, PodMonitor, ConfigMap của Collector, GlitchTip (cần database `svp_glitchtip` từ wave 4) |
| 6 | `otel-collector` (`svp-obs`) | ConfigMap cấu hình có từ wave 5 |
| 7 | `user-service`, `video-service`, `engagement-service`, `feed-service`, `media-worker`, `gateway` (`svp`) | Mọi phụ thuộc đã sẵn sàng |

Argo CD không nằm trong `components.json`: `k8s-gitops-up` cài nó trước, rồi nó dựng phần còn lại (mục 12).

**Symlink** (`files/` trong chart trỏ ra `deploy/observability/...`, `deploy/postgres/bootstrap.sql`, `deploy/minio/`,
`deploy/redpanda/create-topics.sh`, `deploy/observability/otelcol/k8s-config.yaml`,
`deploy/observability/glitchtip/bootstrap.py`):

- **Helm 4.3.0** (đã kiểm): chart tạm ở `/tmp` có symlink tệp và symlink thư mục trỏ ra ngoài chart nhưng trong cùng cây;
  `helm template` đọc được qua `.Files.Get` và `.Files.Glob`, `helm package` đóng nội dung thật vào gói; Helm in dòng INFO
  `found symbolic link in path. Contents of linked file included and used`. Mã nguồn `internal/sympath/walk.go` của Helm
  4.2.1 (bản nằm trong Argo CD v3.5.5, `hack/tool-versions.sh`) có cùng đoạn đi theo symlink và cùng dòng log.
- **Argo CD v3.5.5:** repo-server từ chối symlink trỏ ra ngoài **gốc repo** (kiểm `CheckOutOfBoundsSymlinks(gitClient.Root(),
  ..., ".git")` trong `reposerver/repository/repository.go`; tài liệu `docs/operator-manual/upgrading/2.4-2.5.md`). Kiểm theo
  gốc chart chỉ áp cho chart tải từ Helm repo hay OCI. Symlink tương đối nằm trong repo được phép. Chạy thật ở bước GitOps.

## 8. Secret

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Script đọc `.env` (quy tắc chặt có sẵn), tạo Secret bằng `kubectl apply` từ stdin** | Một nguồn bí mật cho compose và k8s; không gì vào git | Secret nằm ngoài GitOps; đường GitOps phải chạy script trước |
| Sealed Secrets / SOPS trong git | Secret đi qua GitOps | Thêm controller/khoá; khoá giải mã lại là một bí mật phải giữ |
| External Secrets + secret store | Đúng mô hình cloud | Cần secret store; là việc giai đoạn 7 (SEC-3) |

### Quyết định

Không Secret nào trong git. `make env` sinh thêm vào `.env` (cùng quy tắc: chỉ bổ sung biến thiếu hay rỗng, không đổi giá
trị đã đặt; `openssl rand -hex 24`): **`SVP_PG_SUPERUSER_PASSWORD`**, **`SVP_KAFKA_ADMIN_PASSWORD`**,
**`SVP_KAFKA_KEDA_PASSWORD`**, **`SVP_KAFKA_USER_SERVICE_PASSWORD`**, **`SVP_KAFKA_VIDEO_SERVICE_PASSWORD`**,
**`SVP_KAFKA_ENGAGEMENT_SERVICE_PASSWORD`**, **`SVP_KAFKA_FEED_SERVICE_PASSWORD`**, **`SVP_KAFKA_MEDIA_WORKER_PASSWORD`**,
**`SVP_GRAFANA_ADMIN_PASSWORD`**; tên thêm vào `.env.example`. `deploy/k8s/secrets.sh` đọc `.env` bằng
`deploy/observability/glitchtip/dotenv.sh`, tạo/cập nhật Secret bằng `kubectl apply -f -` (stdin), không in giá trị, không
ghi file tạm ngoài `mktemp` mode 600 xoá ngay. Đường dev: `install.sh` chạy nó ngay sau `svp-cluster` (wave 1, tạo namespace),
trước mọi chart đọc Secret (wave 2 trở đi); đường GitOps: `gitops.sh` chạy nó sau khi tạo namespace của project, trước Argo
CD và root app. **Sửa 2026-10-19:** trước ghi "chạy trước `install.sh`".

| Namespace | Secret | Key | Từ `.env` | Ai đọc |
| --- | --- | --- | --- | --- |
| `svp-data` | `pg-superuser` (`kubernetes.io/basic-auth`) | `username` (= `postgres`), `password` | `SVP_PG_SUPERUSER_PASSWORD` | CloudNativePG `superuserSecret`, Job bootstrap |
| `svp-data` | `pg-roles` | `SVP_{USER,VIDEO,ENGAGEMENT,FEED,GLITCHTIP}_{MIGRATOR,APP}_DB_PASSWORD` (10 key) | cùng tên | Job bootstrap |
| `svp-data` | `minio-root` | `MINIO_ROOT_USER` (= `svp-admin`), `MINIO_ROOT_PASSWORD` | `SVP_MINIO_ROOT_PASSWORD` | MinIO, Job init MinIO |
| `svp-data` | `minio-users` | `SVP_VIDEO_S3_SECRET_KEY`, `SVP_MEDIA_WORKER_S3_SECRET_KEY` | cùng tên | Job init MinIO |
| `svp-data` | `redpanda-bootstrap` | `password` | `SVP_KAFKA_ADMIN_PASSWORD` | Chart Redpanda (bootstrap user `svp-admin`), Job init (`RPK_PASS`) |
| `svp-data` | `redpanda-superusers` | `users.txt` (`svp-admin:<pw>:SCRAM-SHA-256`) | `SVP_KAFKA_ADMIN_PASSWORD` | Sidecar của chart Redpanda |
| `svp-data` | `kafka-users` | `svp-keda`, `svp-user-service`, `svp-video-service`, `svp-engagement-service`, `svp-feed-service`, `svp-media-worker` | `SVP_KAFKA_*_PASSWORD` | Job init Redpanda |
| `svp` | `user-service-env` | `DATABASE_URL` (app), `JWT_SIGNING_KID`, `JWT_SIGNING_KEY`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` | role app, JWT, Kafka | user-service (khoá ký chỉ ở đây, JWT-10) |
| `svp` | `video-service-env` | `DATABASE_URL`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, `S3_SECRET_ACCESS_KEY` | | video-service |
| `svp` | `engagement-service-env`, `feed-service-env` | `DATABASE_URL`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD` | | service tương ứng |
| `svp` | `media-worker-env` | `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, `S3_SECRET_ACCESS_KEY` | | media-worker |
| `svp` | `gateway-env` | `JWT_VERIFY_KEYS` | | gateway (chỉ khoá công khai) |
| `svp` | `<svc>-migrate-env` (4 service có database) | `DATABASE_URL` (role migrator) | | Job migrate |
| `svp` | `sentry` | `SENTRY_DSN` | do `k8s-glitchtip-init` ghi, không vào `.env` | 5 service (tham chiếu `optional`), không media-worker |
| `keda` | `keda-kafka` | `sasl` (= `scram_sha256`), `tls` (= `disable`), `username` (= `svp-keda`), `password` | `SVP_KAFKA_KEDA_PASSWORD` | `ClusterTriggerAuthentication` của KEDA (mục 10) |
| `svp-obs` | `grafana-admin` | `admin-user` (= `admin`), `admin-password` | `SVP_GRAFANA_ADMIN_PASSWORD` | Grafana (`admin.existingSecret`) |
| `svp-obs` | `alertmanager-svp` | `alertmanager.yaml` | dựng theo định tuyến của `deploy/observability/alertmanager/entrypoint.sh` | Alertmanager (`configSecret`) |
| `svp-obs` | `alertmanager-telegram` | `bot_token` (rỗng khi thiếu một trong hai biến Telegram) | `SVP_ALERT_TELEGRAM_BOT_TOKEN` | Alertmanager (`alertmanagerSpec.secrets`, mount ở `/etc/alertmanager/secrets/alertmanager-telegram/bot_token`) |
| `svp-obs` | `glitchtip-env` | `SECRET_KEY`, `DATABASE_URL`, `MAINTENANCE_DATABASE_URL` | `GLITCHTIP_SECRET_KEY`, mật khẩu hai role `svp_glitchtip_*` | GlitchTip, Job init |
| `svp-obs` | `glitchtip-admin` | `GLITCHTIP_ADMIN_EMAIL`, `GLITCHTIP_ADMIN_PASSWORD` | cùng tên | Job init GlitchTip |
| `svp-obs` | `glitchtip-api` | `SENTRY_AUTH_TOKEN` | do `k8s-glitchtip-init` ghi, không vào `.env` | Diễn tập |
| `argocd` | `repo-short-video-platform` (label `argocd.argoproj.io/secret-type: repository`) | `type` (= `git`), `url`, `sshPrivateKey` | file deploy key truyền vào make target, không phải `.env` | Argo CD repo-server |

- Chuỗi kết nối: `postgres://<role>:<pw>@svp-pg-rw.svp-data:5432/svp_<db>?sslmode=require`. Mật khẩu hex nên không cần
  mã hoá URL.
- `SVP_ALERT_TELEGRAM_CHAT_ID` nằm trong `alertmanager.yaml`, không ở biến môi trường. Secret `alertmanager-telegram` luôn
  được tạo (rỗng khi Telegram tắt) để pod Alertmanager không kẹt vì thiếu volume.
- Secret `keda-kafka` nằm ở namespace `keda`, không ở `svp`: operator KEDA chỉ được đọc Secret của namespace mình
  (`permissions.operator.restrict.secret: true` và RBAC tự cấp, mục 10). Namespace `keda` do `svp-cluster` (wave 1, kèm nhãn
  PSA, mục 3) tạo trước khi `install.sh` chạy script; ở đường GitOps script chạy trước mọi sync nên tự tạo `keda` trần, rồi
  Argo CD áp `svp-cluster` gắn nhãn trước pod đầu của KEDA (wave 2). **Sửa 2026-10-19:** trước ghi namespace do chart KEDA
  tạo. Đổi mật khẩu thì `install.sh` restart `keda-operator` sau wave dữ liệu, cùng cơ
  chế annotation `resourceVersion` như các service. **Sửa 2026-10-18:** trước ghi Secret ở `svp` cho
  `TriggerAuthentication`; đổi vì ClusterRole mặc định của chart KEDA cho operator `get/list/watch` mọi Secret toàn
  cluster, kể cả khoá ký JWT.
- Giai đoạn 7 thay script bằng External Secrets + AWS Secrets Manager (SEC-3).

**Đổi mật khẩu trong `.env`** (`make k8s-secrets`, rồi `make k8s-up`). Secret mới không tự đổi được backend hay pod đang chạy
(tiến trình chỉ đọc biến môi trường lúc khởi động; Secret nằm ngoài Helm và Argo CD nên không chart nào lăn pod theo
checksum), nên:

- **Redpanda** giữ superuser `svp-admin` và mật khẩu trong dữ liệu của nó (chỉ đọc Secret `redpanda-bootstrap` lúc
  cluster hình thành). `secrets.sh` đặt mật khẩu mới vào broker **trước khi apply Secret nào**: trong `redpanda-0` đăng
  nhập bằng mật khẩu của `.env`, không được thì bằng mật khẩu của Secret, rồi của lúc container khởi động, và `rpk
  security user update svp-admin`. Chỉ lỗi 401 mới thử mật khẩu kế. Shell trong container báo kết cục bằng mã thoát
  riêng của nó; `secrets.sh` đọc mã đó, in thông báo theo từng mã rồi dừng bằng `fail()`, nên caller (`make
  k8s-secrets`, `install.sh`, `gitops.sh`) luôn nhận exit 1: không mật khẩu nào được nhận (mã 3 trong container) → gợi ý
  trả lại mật khẩu cũ hay làm lại dữ liệu; đổi mật khẩu lỗi (mã 4); Admin API không trả lời (từ chối kết nối, quá hạn,
  output lạ; mã 5) → chạy lại `make k8s-secrets`, không gợi ý xoá dữ liệu; mật khẩu đổi mà broker không chạy → dừng. Mọi
  đường lỗi đều chưa đổi Secret nào.
- **MinIO, Redpanda** đang chạy với mật khẩu khác `.env` (so trong container qua stdin, không in) thì `secrets.sh` restart,
  trước khi Job init của `svp-data` đăng nhập bằng mật khẩu mới.
- **Postgres:** Secret `pg-superuser` mang nhãn `cnpg.io/reload`, nên CloudNativePG đặt lại mật khẩu superuser không cần
  restart (operator chỉ theo dõi Secret nó tạo hay Secret có nhãn đó); mật khẩu role do Job `pg-bootstrap` đặt.
- **Sáu service, `kps-grafana`, `glitchtip`, `keda-operator`:** `install.sh` restart sau khi Job init đã đặt mật khẩu mới
  (restart sớm hơn thì pod khởi động với mật khẩu backend chưa nhận), chỉ khi `resourceVersion` của Secret khác giá trị ghi
  trong annotation của workload lúc pod đọc nó (annotation ở metadata của workload, không ở pod template, không chứa giá trị
  hay hash bí mật); gateway restart bằng `spec.restartAt` (mục 13).
- **Đường GitOps:** bước tay ở comment đầu `deploy/k8s/gitops.sh` (`make k8s-secrets`, sync Application `svp-data`, rồi
  restart từng workload có Secret đổi). **Sửa 2026-10-19.**

## 9. Biên vào (Gateway API)

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Envoy Gateway** | Bản triển khai thuần Gateway API của CNCF (đã chốt ở plan) | Thêm controller + proxy |
| Traefik có sẵn của k3s | Không cài gì | Gateway API chỉ là phần phụ; khác công cụ đã chốt |
| ingress-nginx | Quen thuộc | Ngừng bảo trì từ 3/2026 |
| **TLS bằng CA tự ký của cert-manager** | Học cert-manager (Issuer, Certificate, gia hạn) như trên cloud | Client phải tin CA riêng (`--cacert`) |
| HTTP không TLS / mkcert | Đơn giản | Không học cert-manager; mkcert cài CA vào máy |
| **Một listener HTTPS, phân biệt bằng hostname** | Một cổng host; route theo tên như cloud | Cần tên `*.svp.localhost` phân giải về loopback |

### Quyết định

- Envoy Gateway; `GatewayClass` **`svp`** (`controllerName: gateway.envoyproxy.io/gatewayclass-controller`) và `Gateway`
  **`svp`** ở `svp-edge`, một listener tên `https`, **cổng 443, HTTPS, hostname `*.svp.localhost`**, TLS `Terminate` với
  Secret `svp-wildcard-tls`. `allowedRoutes` chỉ nhận route từ namespace có label `svp-gateway-routes: "true"` (`svp`,
  `svp-data`). CRD Gateway API v1.6.1 kênh experimental đi kèm chart Envoy Gateway.
- `EnvoyProxy` của `GatewayClass` đặt Service của Envoy là LoadBalancer với **`externalTrafficPolicy: Cluster`** (mặc định
  của Envoy Gateway là `Local`): load balancer k3d chia kết nối cho cả hai node, và với `Local` thì pod `svclb` của node không
  có Envoy chuyển tới `hostIP:nodePort` của chính node đó (`pkg/cloudprovider/servicelb.go@v1.36.5+k3s1`), phải nhờ kube-proxy
  chuyển tiếp traffic có nguồn là pod. Địa chỉ client đằng nào cũng mất (bên dưới), nên `Cluster` không mất gì.
- **Chứng chỉ:** ClusterIssuer `svp-selfsigned` (selfSigned) → Certificate `svp-local-ca` (`isCA: true`, ở namespace
  `cert-manager`, Secret `svp-local-ca`) → ClusterIssuer `svp-ca` (`ca.secretName: svp-local-ca`; ClusterIssuer đọc Secret ở
  "cluster resource namespace" mặc định là `cert-manager`) → Certificate `svp-wildcard` ở `svp-edge`, `dnsNames:
  ["*.svp.localhost"]`, Secret `svp-wildcard-tls`. CA xuất ra **`.k8s/ca.crt`** (gitignore) từ key `ca.crt` của Secret
  `svp-local-ca`, dùng cho `curl --cacert` hay `CURL_CA_BUNDLE`.
- **Route:** HTTPRoute `api` (namespace `svp`, release gateway) `api.svp.localhost` → Service `gateway:8080` (mục 13 thêm
  `gateway-canary`); HTTPRoute `s3` (namespace `svp-data`) `s3.svp.localhost` → `minio:9000` cho presigned POST và phát HLS,
  với `timeouts.request: 10m`: không đặt thì Envoy Gateway không ghi timeout cho route (`internal/xds/translator/route.go`,
  `getEffectiveRequestTimeout`) và Envoy dùng mặc định 15 s, không đủ cho upload tới 500 MiB. video-service:
  `S3_PUBLIC_ENDPOINT=https://s3.svp.localhost:8443`; gateway: `MEDIA_PUBLIC_BASE_URL=https://s3.svp.localhost:8443/media`.
  **Không route nào cho UI vận hành** (OPS-2).
- **`X-Forwarded-For`:** không có ClientTrafficPolicy thì Envoy Gateway v1.9.2 đặt `use_remote_address: true` và không đặt
  `xff_num_trusted_hops` (= 0) (`internal/xds/translator/listener.go`), nên Envoy **nối địa chỉ của kết nối tới nó vào cuối**
  `X-Forwarded-For` (tài liệu `headers.rst` của Envoy v1.39.1; trang ClientTrafficPolicy của Envoy Gateway v1.9). Gateway đặt
  `TRUSTED_PROXY_HOPS=1`, `TRUSTED_PROXY_CIDRS=10.42.0.0/16` (dải pod mặc định của k3s,
  <https://docs.k3s.io/cli/server>): chỉ đọc phần tử cuối khi kết nối tới từ dải pod. Đủ an toàn vì NetworkPolicy chỉ cho pod
  Envoy (namespace `envoy-gateway-system`, label `app.kubernetes.io/name: envoy`,
  `gateway.envoyproxy.io/owning-gateway-name: svp`) vào cổng 8080 của gateway (RL-1). Gateway so địa chỉ kết nối đã bỏ dạng
  IPv4-mapped, nên dải viết dạng mapped (`::ffff:10.42.0.0/112`) được đọc như dải IPv4 nó chỉ (`10.42.0.0/16`); dải mapped
  ngắn hơn /96 (vượt ra ngoài IPv4) bị từ chối lúc khởi động. **Sửa 2026-10-19:** trước đó dải mapped parse được mà không
  bao giờ khớp.
- **Địa chỉ client mà gateway thấy ở k3d:** `127.0.0.1:8443` → Docker → `k3d-svp-serverlb` (nginx chế độ `stream`, chỉ
  `proxy_pass`, không proxy protocol: `proxy/templates/nginx.tmpl@v5.9.0`) → cổng 443 của một trong hai node (nginx chia
  round-robin theo kết nối) → pod `svclb` của node đó (klipper-lb v0.4.17: DNAT rồi `MASQUERADE`, script `entry`) → Envoy.
  Envoy thấy, và nối vào `X-Forwarded-For`, **địa chỉ mạng pod của node nhận kết nối** (`10.42.0.1`, `10.42.1.0` trên cluster
  diễn tập: địa chỉ của node trên mạng pod, mà traffic từ node đó mang sau SNAT), không phải địa chỉ pod `svclb`.
  Mọi client trên máy vì vậy chung tối đa **hai** bucket IP ở gateway (mỗi node một), và một client có thể rơi vào cả hai.
  **Sửa 2026-10-19:** trước ghi Envoy thấy địa chỉ pod `svclb`; kết luận hai bucket không đổi. Ở k3d, diễn tập RL-1 chứng minh
  header giả không đổi được bucket, **không** chứng minh phân biệt được client thật; số khoá `login-ip` mới sau một loạt là
  tối đa hai, không phải một. `externalTrafficPolicy: Local` không giúp vì serverlb đã proxy TCP. Giữ nguyên địa chỉ client
  cần load balancer có proxy protocol ở giai đoạn 7. Kiểm trên cluster ở bước dựng biên vào và diễn tập threat model.

## 10. Workload

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Readiness của gateway là `/readyz` (kiểm mọi service) | Không nhận traffic khi phụ thuộc chết | Một service tắt là mọi pod gateway bị rút, trong khi gateway được thiết kế xuống cấp theo route nhờ breaker ([ADR-0010 §4](0010-redis-ratelimit-cache-resilience-stage2c.md#4-timeout-retry-circuit-breaker-bulkhead)) |
| **Readiness và liveness của gateway là `/healthz`** | Giữ hành vi xuống cấp từng route | Pod gateway nhận traffic cả khi service phía sau chết (đúng ý đồ) |
| **Probe `grpc` gốc của Kubernetes cho service gRPC** | Không cần binary healthcheck trong probe; health service luôn SERVING tới lúc tắt | — |
| Migrate bằng initContainer | Đơn giản | Mọi replica chạy migrate mỗi lần khởi động; role migrator nằm trong pod chạy lâu |
| **Migrate bằng Job hook `pre-install,pre-upgrade`** | Chạy một lần trước bản mới; Argo CD hiểu là PreSync | Hook chạy trước mọi resource thường nên SA và policy của nó phải có trước |
| HPA theo CPU cho media-worker | Có sẵn | CPU không phản ánh hàng chờ; worker rảnh CPU thấp dù lag cao |
| **KEDA Kafka scaler theo lag** | Scale theo hàng chờ thật | Thêm operator và một user Kafka |

### Quyết định

- **ServiceAccount** riêng mỗi service, `automountServiceAccountToken: false`, **không** Role/RoleBinding nào.
- **securityContext** (FF-4) mọi pod và container ở `svp`: `runAsNonRoot: true`, `runAsUser`/`runAsGroup: 65532`,
  `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile:
  RuntimeDefault`.
- **media-worker:** `emptyDir` `/work` (`sizeLimit: 2Gi`; một job < 1 GB theo ADR-0008 §9), `emptyDir` `/tmp`
  (`medium: Memory`, `sizeLimit: 16Mi`), giới hạn **2 CPU / 2 Gi** như compose (FF-3), không cổng, không probe (tiến trình
  thoát khi consumer lỗi, kubelet khởi động lại). Mỗi pod có `/work` riêng, nên ràng buộc "đúng một replica" của compose
  (khởi động thì xoá mọi thư mục job còn trong volume dùng chung,
  [ADR-0008 §9](0008-async-upload-pipeline-stage2a.md#9-media-worker)) **không áp ở k8s**; compose giữ nguyên.
- **Probe:** gateway liveness và readiness `httpGet /healthz :8080` (không `/readyz`, lý do ở bảng trên). Service gRPC
  (`:9101`–`:9104`, `LISTEN_ADDR=":<cổng>"` để nghe trên IP pod): probe `grpc` gốc vào health service chuẩn
  (`internal/grpcserver`: `health.NewServer()`, chỉ chuyển NOT_SERVING khi tắt, không phụ thuộc database). media-worker không
  probe.
- **Migrate:** Job hook `helm.sh/hook: pre-install,pre-upgrade`, `helm.sh/hook-weight: "0"`, `hook-delete-policy:
  before-hook-creation`, lệnh `migrate`, Secret `<svc>-migrate-env`. Hook chạy **trước** mọi resource thường của release
  trong namespace đã chặn mặc định, nên ServiceAccount và NetworkPolicy egress (DNS, Postgres `svp-data:5432`) của Job cũng
  là hook `pre-install,pre-upgrade` với `hook-weight: "-10"` và `before-hook-creation`. Argo CD v3.5.5 ánh xạ `pre-install`
  và `pre-upgrade` thành `PreSync`, `helm.sh/hook-weight` thành sync wave trong phase đó, `before-hook-creation` thành
  `BeforeHookCreation` (`docs/user-guide/helm.md@v3.5.5`, `gitops-engine/pkg/sync/hook/helm/delete_policy.go`); tài liệu
  ghi thêm: có bất kỳ hook kiểu Argo CD nào thì mọi hook Helm bị bỏ qua, nên chart không trộn annotation
  `argocd.argoproj.io/hook`. Chạy thật trên cluster sạch ở bước chart service và bước GitOps.
- **Số replica và co giãn:** gateway 2 replica + PDB `minAvailable: 1` + HPA 2–4 theo CPU (`averageUtilization: 70`), trải
  hai node bằng `topologySpreadConstraints` mềm; feed-service HPA 1–2 (CPU 70%); user-, video-, engagement-service 1 replica
  (không PDB: PDB với một replica hoặc chặn drain mãi hoặc vô nghĩa). media-worker **KEDA** `ScaledObject`
  `minReplicaCount: 1`, `maxReplicaCount: 3` (= 3 partition của `video.lifecycle.v1`), không đặt `pollingInterval`; trigger
  `kafka`: `bootstrapServers: redpanda.svp-data.svc.cluster.local:9092`, `consumerGroup: media-worker`, `topic:
  video.lifecycle.v1`, **`lagThreshold: "1"`** (mỗi worker xử lý một job một lúc, ADR-0008 §9: một replica cho mỗi record
  đang chờ hay đang xử lý), `limitToPartitionsWithLag: "true"` (không thêm consumer cho partition không có việc),
  `offsetResetPolicy: earliest` (khớp mặc định `ConsumeResetOffset` đầu partition của franz-go), `allowIdleConsumers: false`;
  `ClusterTriggerAuthentication` `keda-kafka` đọc Secret cùng tên ở namespace `keda` (SASL `scram_sha256`, `tls: disable`;
  mục 8), do chart `svp-data` tạo một lần cho cả cluster (wave 4: sau CRD của KEDA ở wave 2, cạnh user `svp-keda` và ACL
  của nó): render trong mỗi release `svp-service` có ScaledObject thì release thứ hai vướng kiểm ownership của Helm, gỡ một
  release là xoá luôn đăng nhập của các release khác. Phải là `ClusterTriggerAuthentication`, không `TriggerAuthentication`
  trong `svp`: operator chỉ đọc Secret ở `keda` (gạch đầu dòng dưới); mọi ScaledObject đều trỏ được tới nó, nhưng
  `svp-keda` chỉ có `DESCRIBE`. **Sửa 2026-10-18:** bỏ `pollingInterval: 15`: webhook KEDA 2.21 báo trường này "not
  relevant for scaling" khi `minReplicaCount` ≥ 1; HPA vẫn hỏi lag qua metrics API của KEDA mỗi 15 s (chu kỳ của HPA
  controller). **`cooldownPeriod` chỉ áp khi về 0 replica** (tài liệu KEDA 2.21; mặc định 300 s), nên với
  `minReplicaCount: 1` nó không có tác dụng; giảm từ 3 về 1 theo `stabilizationWindowSeconds` scale-down của HPA, giữ mặc
  định 300 s: một job 60 s 1080p mất ~45 s nên tới lúc giảm thì job đang chạy gần như chắc đã xong; job bị cắt giữa chừng
  vẫn được giao lại (at-least-once, ADR-0008 §8). `make drill-k8s-keda` ép một lần như vậy: ghim ScaledObject thấp hơn một
  replica (annotation `autoscaling.keda.sh/paused-replicas`) khi một pod đang transcode, pod đó có `pod-deletion-cost` thấp
  nhất nên bị xoá, rồi kiểm video bị cắt vẫn `READY` với đúng một `transcode.completed`.
- **Quyền của operator KEDA** (`deploy/k8s/values/keda.yaml`). Operator giữ quyền toàn cluster, ai chiếm được token
  ServiceAccount của nó có đúng các quyền đó. Ba giá trị của chart giữ các quyền ấy không với tới Secret nào ngoài namespace
  `keda` (khoá ký JWT ở `svp/user-service-env`, mật khẩu ở `svp-data`):
  - `permissions.operator.restrict.secret: true`: bỏ `list/watch` Secret toàn cluster; operator chỉ đọc Secret ở `keda`
    (Role `keda-operator-certs`).
  - `certificates.certManager.enabled: true`: cert-manager (wave 0) cấp chứng chỉ TLS cho operator, metrics server và
    webhook từ một CA riêng ở `keda`; cainjector của nó ghi CA vào APIService `v1beta1.external.metrics.k8s.io` và
    ValidatingWebhookConfiguration `keda-admission`. Để KEDA tự sinh (mặc định) thì operator cần `patch` mọi
    ValidatingWebhookConfiguration và APIService của cluster: đủ để thêm một webhook mà API server gửi tới mọi Secret được
    ghi, hay chuyển một API group sang Service do nó chọn.
  - `rbac.create: false`, và `extraObjects` chứa mọi Role, ClusterRole, binding mà chart render với hai giá trị trên, cùng
    tên, giữ nguyên trừ ClusterRole `keda-operator`: bỏ `pods` (`get/list/watch`), `batch/jobs` (mọi verb), mọi verb ghi
    trên `scaledjobs` cùng `scaledjobs/finalizers` và `scaledjobs/status`; chỉ giữ `get/list/watch` trên `scaledjobs` vì
    controller ScaledJob luôn chạy và watch chúng. Project không dùng ScaledJob. ClusterRole của chart luôn cho `create` Job
    và `get` pod ở mọi namespace, không giá trị nào tắt được: một Job trong `svp` với `envFrom: user-service-env` ghi biến
    môi trường ra termination log, ai đọc status của pod là có khoá ký. `rbac.create: false` tắt cả RBAC của metrics server
    và webhook, nên hai phần đó cũng được chép nguyên vào `extraObjects`.
  - **Còn lại** khi operator bị chiếm: đọc mọi ConfigMap, Service, ServiceAccount (không lấy được token), EndpointSlice,
    Deployment, ReplicaSet, StatefulSet; đổi số replica của mọi Deployment/StatefulSet, tạo, sửa, xoá mọi HPA (dừng được
    workload, Redpanda và MinIO cũng vậy, nhưng không đọc được Secret của chúng); sửa object của KEDA; đọc Secret ở `keda`
    (`keda-kafka`: `svp-keda` chỉ `DESCRIBE`; CA và chứng chỉ của KEDA).
  - **Nâng KEDA:** render chart mới với RBAC của chart (`helm template ... --set rbac.create=true --set
    rbac.enabledCustomScaledRefKinds=false --set-json 'extraObjects=[]'`, lệnh đủ ở comment của `keda.yaml`), so Role,
    ClusterRole, binding với `extraObjects`, nhận mọi thay đổi trừ các rule đã bỏ khỏi `keda-operator`, rồi kiểm log của
    operator không có `forbidden` trong 5 phút.
  - **Sửa 2026-10-18:** trước là `TriggerAuthentication` trong `svp` và chart KEDA để mặc định (operator `get/list/watch`
    mọi Secret toàn cluster). Lần thu hẹp đầu chỉ bật `restrict.secret` và tắt `rbac.enabledCustomScaledRefKinds`; review
    chỉ ra đường Job + termination log, rồi lúc sửa thấy thêm đường webhook/APIService, nên chuyển sang RBAC tự cấp và chứng
    chỉ qua cert-manager.
- **Không render `replicas` khi số replica do HPA giữ:** gateway (`Rollout`) và feed-service có HPA, media-worker có
  ScaledObject (KEDA tạo HPA `keda-hpa-media-worker`). Với ba workload đó chart `svp-service` **bỏ hẳn `spec.replicas`**:
  có giá trị trong manifest thì selfHeal của Argo CD (mục 12) coi số HPA vừa đặt là lệch và trả về số trong git, hai bên
  giành nhau mỗi lần co giãn (`docs/user-guide/best_practices.md@v3.5.5`, mục "Leaving Room For Imperativeness"). Lúc tạo,
  workload nhận mặc định 1 replica rồi HPA nâng lên `minReplicas` (gateway 2). Chỉ workload không có HPA mới ghi
  `replicas: 1`. Không dùng `ignoreDifferences` cho `/spec/replicas`: đường dev (Helm) cũng ghi đè số của HPA mỗi lần
  `helm upgrade` nếu manifest có `replicas`.
- **Resource request/limit** cho mọi container của project (FF-3):

| Container | Request CPU / RAM | Limit CPU / RAM | Ghi chú |
| --- | --- | --- | --- |
| gateway | 100m / 64Mi | 1 / 256Mi | 2–4 replica; compose đo 18–48 MiB |
| user-service | 100m / 64Mi | 1 / 384Mi | argon2id tối đa 4 hash × 64 MiB theo cận trên tham số đọc được (JWT-9, `internal/password`) cộng runtime và pool |
| video-service | 50m / 64Mi | 500m / 256Mi | |
| engagement-service | 50m / 32Mi | 500m / 256Mi | compose `mem_limit: 256m` |
| feed-service | 100m / 64Mi | 1 / 256Mi | 1–2 replica; compose đỉnh 82 MiB khi nạp 200.000 follow |
| media-worker | 500m / 256Mi | 2 / 2Gi | ephemeral `/work` 2 Gi; compose đỉnh 734 MiB |
| Job migrate | 50m / 32Mi | 500m / 128Mi | |
| Postgres `svp-pg` | 100m / 256Mi | 1 / 512Mi | |
| Valkey | 20m / 16Mi | 1 / 128Mi | `maxmemory 64mb`; limit CPU và probe: bên dưới |
| Redpanda | 1 / 1280Mi | 1 / 1280Mi | do chart tính từ `resources` |
| MinIO | 100m / 256Mi | 1 / 512Mi | compose 512 MiB |
| GlitchTip | 100m / 256Mi | 1 / 512Mi | compose 512 MiB |
| Job init (Postgres, MinIO, Redpanda, GlitchTip) | 50m / 64Mi | 500m / 512Mi | GlitchTip migrate cần nhiều nhất (compose 512 MiB) |
| Chart upstream | — | Cột "Giới hạn" của bảng RAM mục 2 | |

**Valkey: limit CPU `1`, probe `tcpSocket`.** Với limit 200m, CFS cấp 20 ms CPU mỗi chu kỳ 100 ms; một loạt lệnh dùng hết
quota thì Valkey bị throttle tới hết chu kỳ, tức chờ tới ~100 ms, dài hơn hạn 50 ms mỗi lần gọi store của gateway (rate
limit) và feed-service (cache explore), nên gateway rơi sang bộ đếm dự phòng giữa diễn tập RL-1. Probe exec `valkey-cli ping`
mỗi 10 s chạy trong cgroup của container nên cũng ăn quota, một phần mức throttle lúc nghỉ. Limit lên `1`, request giữ 20m;
readiness và liveness đổi sang `tcpSocket` (Valkey không persistence nên không có pha `LOADING` cần PING để phân biệt). Cái
giá: không phát hiện được Valkey treo mà cổng vẫn mở, lab chấp nhận. Limit CPU của gateway (1) giữ nguyên.
**Sửa 2026-10-19:** trước là limit 200m và probe exec.

## 11. Observability trong cluster

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| Chạy lại image `grafana/otel-lgtm` trong một pod | Ít cấu hình | Image dev, không phải cách triển khai thật; plan yêu cầu tách deployment |
| **kube-prometheus-stack + Loki, Tempo, Pyroscope single-binary + Collector chart** | Đúng cách triển khai phổ biến; học operator (`PrometheusRule`, `PodMonitor`) | ~10 tiến trình, nhiều RAM hơn compose |
| Bản distributed của Loki/Tempo | Gần production lớn | Hàng chục pod, vượt ngân sách RAM |
| GlitchTip giữ ở compose | Không chuyển gì | Chạy compose song song k3d bị cấm |
| **GlitchTip trong cluster** | Cluster tự chứa | Thêm Deployment, Job init, database |

### Quyết định

- **kube-prometheus-stack**, release `kube-prometheus-stack` ở `svp-obs`, `fullnameOverride: kps`,
  **`grafana.fullnameOverride: kps-grafana`**, **`kube-state-metrics.fullnameOverride: kps-kube-state-metrics`** (subchart
  không nhận `fullnameOverride` của chart cha: thiếu hai dòng này thì tên là `kube-prometheus-stack-grafana`,
  `kube-prometheus-stack-kube-state-metrics`) → Service `kps-prometheus:9090`, `kps-alertmanager:9093`, `kps-grafana:80`
  (pod 3000), `kps-kube-state-metrics:8080`, `kps-operator:8080` (đã `helm template` chart 92.10.1 với các values này: đúng
  năm tên đó, mọi resource namespaced ở `svp-obs`). Trường của Prometheus CR
  đã đối chiếu CRD đi kèm chart 92.10.1 (operator v0.94.1), dưới `prometheus.prometheusSpec`:
  - `enableOTLPReceiver: true`; `otlp.promoteResourceAttributes` = đúng danh sách trong
    `deploy/observability/prometheus/prometheus.yaml`; `otlp.keepIdentifyingResourceAttributes: true`;
    `tsdb.outOfOrderTimeWindow: 10m`; `scrapeNativeHistograms: true` (như `global.scrape_native_histograms` của compose);
    `enableFeatures: [exemplar-storage]`: tên metric và label trùng compose, dashboard và rule chạy không sửa.
  - `enableRemoteWriteReceiver: true` (metrics-generator của Tempo ghi vào `http://kps-prometheus.svp-obs:9090/api/v1/write`).
  - `retention: 30d` (SLO 30 ngày, [ADR-0011 §8](0011-observability-stage3.md#8-slo-và-cảnh-báo)), `retentionSize: 4GB`,
    PVC local-path 5 Gi; `evaluationInterval: 15s`, `scrapeInterval: 15s`.
  - `externalUrl: http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus`, `routePrefix: /` (link "Source" của cảnh báo đi
    qua Grafana như compose; Grafana mở bằng port-forward `127.0.0.1:3000`).
  - `ruleSelectorNilUsesHelmValues`, `podMonitorSelectorNilUsesHelmValues`, `serviceMonitorSelectorNilUsesHelmValues`,
    `probeSelectorNilUsesHelmValues`, `scrapeConfigSelectorNilUsesHelmValues` đều `false` (selector rỗng chọn mọi object
    **trong namespace operator watch**, tức chỉ `svp-obs`, xem "Quyền của observability" dưới) để Prometheus nhận
    `PrometheusRule`/`PodMonitor` của chart project. `*NamespaceSelector` rỗng không mở ra ngoài `svp-obs`: `PodMonitor`,
    `ServiceMonitor` đặt ở namespace khác không bao giờ được scrape và không đâu báo lỗi. Muốn scrape pod namespace khác thì
    đặt monitor ở `svp-obs` với `namespaceSelector` (`PodMonitor` `envoy-svp` chọn pod Envoy ở `envoy-gateway-system`, mục
    13). **Sửa 2026-10-19:** trước ghi "`*NamespaceSelector` rỗng là mọi namespace", sai vì operator chỉ watch `svp-obs`.
- **Alertmanager:** `alertmanager.alertmanagerSpec.configSecret: alertmanager-svp` (key bắt buộc là `alertmanager.yaml`, CRD
  ghi thiếu key thì receiver rỗng bỏ mọi cảnh báo), `alertmanager.alertmanagerSpec.useExistingSecret: true` (không thì chart
  vẫn sinh Secret mặc định), `alertmanager.alertmanagerSpec.secrets: [alertmanager-telegram]`; cấu hình cùng định tuyến
  như compose (`severity=page` → Telegram khi `.env` có đủ hai biến, `bot_token_file` trỏ file mount; còn lại chỉ xem UI).
  Egress của Alertmanager: DNS và TCP 443 tới địa chỉ công khai (`ipBlock` `0.0.0.0/0` trừ dải riêng, mục 3), vì
  NetworkPolicy không khoá được theo tên `api.telegram.org`. Pod Alertmanager **không mount token ServiceAccount**
  (`alertmanagerSpec.automountServiceAccountToken: false`; trường có trong CRD của chart 92.10.1, operator v0.94.1 chép vào
  pod spec): Alertmanager không gọi API server, config-reloader chỉ watch file Secret và gọi `/-/reload` trên `127.0.0.1`
  (không có client Kubernetes), nên pod duy nhất của project ra được internet không giữ credential nào của cluster.
  **Sửa 2026-10-19.**
- **Grafana:** `admin.existingSecret: grafana-admin` (`userKey: admin-user`, `passwordKey: admin-password`);
  `grafana.ini`: `auth.anonymous.enabled: false`, `plugins.preinstall_disabled: true`, `plugins.preinstall_auto_update: false`,
  `plugins.public_key_retrieval_disabled: true`, `analytics.reporting_enabled`, `check_for_updates`,
  `check_for_plugin_updates` đều `false` (không tải plugin, không gửi thống kê, như compose); không persistence. Datasource
  **cùng UID với `deploy/observability/grafana/provisioning/datasources/grafana-datasources.yaml`**: `prometheus`
  (`sidecar.datasources.uid`, mặc định đúng tên này) `http://kps-prometheus.svp-obs:9090`, `tempo`
  `http://tempo.svp-obs:3200`, `loki` `http://loki.svp-obs:3100`, `pyroscope` `http://pyroscope.svp-obs:4040`, giữ nguyên
  `jsonData` (liên kết trace ↔ log, service map, exemplar); thêm `alertmanager` của chart. Dashboard: sidecar
  (`sidecar.dashboards.label: grafana_dashboard`, `labelValue: "1"`, `searchNamespace: svp-obs`) đọc ConfigMap do chart
  `svp-observability` dựng từ 4 file JSON qua symlink. Rule: `PrometheusRule` dựng từ `slo-generated.yaml` và
  `svp-alerts.yaml` qua symlink, không chép.
- **Tắt** (lý do): node-exporter (node là container trong VM Docker, số đo của "máy" là của VM dùng chung, và cần hostNetwork/
  hostPID/hostPath trái PSA); scrape `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy` (k3s gộp chúng trong
  một tiến trình, không mở endpoint metric riêng theo mặc định), `kubeApiServer` (hàng chục nghìn series histogram, không
  dùng ở giai đoạn này), `coreDns`. **Giữ** kubelet/cAdvisor (CPU, RAM theo pod; egress tới `10.200.0.0/24:10250`) và
  kube-state-metrics. Default rule giữ nhóm `alertmanager`, `configReloaders`, `general`, `k8sContainer*`, `k8sPodOwner`,
  `kubelet`, `kubePrometheusGeneral`, `kubeStateMetrics`, `kubernetesApps`, `kubernetesResources`, `kubernetesStorage`,
  `prometheus`, `prometheusOperator`; tắt `etcd`, `kubeApiserver*`, `kubeControllerManager`, `kubeProxy`, `kubeScheduler*`,
  `kubernetesSystem` (cần metric API server), `node`, `nodeExporter*`, `kubePrometheusNodeRecording`, `network`, `windows`
  (bốn nhóm node/network **không** tự tắt theo `nodeExporter.enabled`, phải tắt tay).
- **Loki** (`grafana-community/loki` 18.17.1): `deploymentMode: Monolithic` (tên mới của SingleBinary),
  `singleBinary.replicas: 1` (mặc định 0), `loki.auth_enabled: false`, `loki.commonConfig.replication_factor: 1`,
  `loki.storage.type: filesystem`, `loki.schemaConfig` tsdb v13 filesystem (mặc định rỗng, phải đặt), `limits_config`
  `allow_structured_metadata: true` và `otlp_config` chỉ index `service.name` như `deploy/observability/lgtm/loki-config.yaml`;
  tắt `gateway`, `lokiCanary`, `test`, `resultsCache`, `chunksCache`, `sidecar.rules`; `write/read/backend.replicas: 0`;
  `loki.analytics.reporting_enabled: false`; PVC 5 Gi. Service `loki:3100` (OTLP `/otlp`).
- **Tempo** (`grafana-community/tempo` 3.2.0): metrics-generator bật (`tempo.metricsGenerator.enabled: true`,
  `overrides.defaults.metrics_generator.processors: [service-graphs, span-metrics]`, `storage.path:
  /var/tempo/generator/wal`, `remote_write` tới Prometheus ở trên với `send_exemplars: true`), như `tempo-config.yaml` của
  otel-lgtm; Tempo 3.1.0 ghi single-binary cấp dữ liệu cho generator không cần Kafka (CHANGELOG #6729);
  `tempo.reportingEnabled: false`; PVC 5 Gi. Giữ receiver mặc định của chart (đặt `tempo.receivers.jaeger: null` làm template
  lỗi; ghi đè cả `config:` thì phải tự viết lại cả metrics-generator); Service `tempo` vẫn liệt kê cổng Jaeger/Zipkin nhưng
  NetworkPolicy chỉ mở 4317 từ Collector và 3200 từ Grafana.
- **Pyroscope** (`grafana/pyroscope` 2.4.0): `alloy.enabled: false`, single binary (mặc định `-target=all`), storage
  `filesystem` `/data/shared`, PVC, `usage-stats.enabled=false`. Service `pyroscope:4040`. 5 service đẩy profile tới
  `PYROSCOPE_SERVER_ADDRESS=http://pyroscope.svp-obs:4040`, media-worker không.
- **Collector** (`opentelemetry-collector` 0.176.0): `mode: deployment`, `replicaCount: 1`, `fullnameOverride:
  otel-collector`, `image.repository: otel/opentelemetry-collector-contrib` + `image.digest` (mục 1), chỉ cổng `otlp` 4317 →
  Service **`otel-collector.svp-obs:4317`**. Cấu hình **không** dùng `config:` của chart (giá trị đó gộp sâu với mặc định của
  chart): `configMap.create: false`, `configMap.existingName` trỏ ConfigMap do `svp-observability` dựng từ
  **`deploy/observability/otelcol/k8s-config.yaml`** (key `relay`). File đó giữ cùng processor (`memory_limiter`,
  `attributes/scrub`, `resource/scrub`, `batch`) và self-telemetry như `config.yaml` của compose, exporter tới Prometheus OTLP
  (`http://kps-prometheus.svp-obs:9090/api/v1/otlp`), Loki OTLP (`http://loki.svp-obs:3100/otlp`), Tempo OTLP gRPC
  (`tempo.svp-obs:4317`), scrape `/public_metrics` của Redpanda (mục 5) mỗi 15 s; `health_check` nghe `:13133` cho probe của
  chart. `make otelcol-validate` kiểm thêm file này.
  - **Bộ nhớ:** container 256 MiB như compose; `memory_limiter` `limit_mib: 192`, `spike_limit_mib: 48` từ chối dữ liệu ở mọi
    pipeline từ 144 MiB heap (mức mềm). **`GOMEMLIMIT=140MiB`** qua `extraEnvs`, ngay dưới mức mềm, để runtime Go dọn rác
    trước khi limiter đếm nó là heap; không dùng `useGOMEMLIMIT` của chart (80% limit container = 204 MiB, trên cả hai mức).
  - **Queue của ba exporter theo byte** (`sizer: bytes`, `queue_size: 4194304`, 4 MiB mỗi exporter; ước lượng, chưa đo): một
    limiter đo heap của cả process, nên queue đếm theo request (256 lô mọi cỡ) của một backend chậm có thể đẩy heap qua mức
    mềm và chặn cả ba tín hiệu ở receiver. Queue đầy thì bỏ dữ liệu (không chặn exporter khác); kích thước tính cả lô đang
    retry. **Sửa 2026-10-19** (hai gạch đầu dòng này).
- **Service:** `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.svp-obs:4317`, `OTEL_EXPORTER_OTLP_INSECURE=true`;
  `SENTRY_ENVIRONMENT=k3d`.
- **GlitchTip trong cluster** (`svp-obs`, chart `svp-observability`): một Deployment all-in-one (image cùng digest compose,
  cùng biến an toàn như `x-glitchtip-env` của compose), database `svp_glitchtip` trên `svp-pg` (role do Job bootstrap tạo),
  Job init chạy migrate, `createcachetable`, `maintain_partitions` và **`deploy/observability/glitchtip/bootstrap.py`** qua
  symlink. `ALLOWED_HOSTS` gồm `glitchtip.svp-obs`, `glitchtip`, `127.0.0.1`, `localhost` (Django so Host bỏ cổng);
  `GLITCHTIP_DOMAIN=http://127.0.0.1:8000` (port-forward). DSN cho service đổi host thành `glitchtip.svp-obs:8000`, chỉ nằm
  trong Secret `sentry` của `svp`, không vào `.env`; token API chỉ đọc ở Secret `glitchtip-api` của `svp-obs`.
  - **Token API của diễn tập là token cũ nhất mang nhãn `svp-drill`**, tìm theo nhãn, không theo admin: `bootstrap.py`
    chỉ tạo token (cho admin hiện tại) khi chưa có token nào mang nhãn đó, `deploy/k8s/glitchtip-init.sh` đọc đúng token
    ấy (`APIToken.objects.filter(label="svp-drill").order_by("pk").first()` ở cả hai). Đổi `GLITCHTIP_ADMIN_EMAIL` thì
    admin cũ vẫn là thành viên organization, token của họ vẫn đọc được và vẫn là token dùng, không sinh token thứ hai;
    đã có hai token (do quy tắc cũ để lại) thì hai bên cùng chọn token cũ nhất. Quy tắc này thay bước 4 của
    `bootstrap.py` ở [ADR-0011 §7](0011-observability-stage3.md#7-theo-dõi-lỗi-bằng-glitchtip-và-ranh-giới-dữ-liệu)
    (`get_or_create(user=admin, label="svp-drill")`: đổi email thì sinh token mới, khác `SENTRY_AUTH_TOKEN` đã ghi), cho
    cả `make glitchtip-init` của compose vì `bootstrap.py` dùng chung. **Sửa 2026-10-19.**
- **Truy cập UI:** chỉ `kubectl port-forward --context k3d-svp` trên `127.0.0.1` (Grafana 3000, Prometheus 9090,
  Alertmanager 9093, GlitchTip 8000, Argo CD 8081); Grafana, Argo CD, GlitchTip có đăng nhập (OPS-2). Không HTTPRoute,
  Service LoadBalancer hay NodePort nào cho UI.
- **Quyền của observability** (`deploy/k8s/values/kube-prometheus-stack.yaml`). Cùng nguyên tắc với KEDA (mục 10): không
  workload nào ngoài control plane đọc được Secret ngoài namespace của chính nó. Đã rà mọi ClusterRole, Role và binding của
  năm chart (`helm template` và object sống); ba chỗ chart mặc định vượt nguyên tắc, sửa như sau:
  - **Grafana:** `rbac.namespaced: true`, `rbac.useExistingRole: kps-grafana`; Role `kps-grafana` (trong `extraManifests`
    của kube-prometheus-stack) chỉ `get/list/watch` ConfigMap ở `svp-obs`, không Secret (Role mà chart tự sinh luôn kèm
    Secret); hai sidecar `resource: configmap`. Pod đặt `automountServiceAccountToken: false`; chỉ hai sidecar mount một
    volume projected giống volume kubelet tự gắn (token 3607 s, CA, namespace) ở đường dẫn chuẩn, nên container `grafana`,
    nơi người dùng đăng nhập, không có token.
  - **kube-state-metrics:** `collectorsExclude: [secrets]`; ClusterRole không còn `secrets`. Không rule hay dashboard nào
    dùng `kube_secret_*`.
  - **Prometheus operator:** chỉ watch `svp-obs` (`prometheusOperator.namespaces.releaseNamespace: true`, tức
    `--namespaces=svp-obs`); Service và Endpoints kubelet mà operator giữ chuyển từ `kube-system` về `svp-obs`
    (`prometheusOperator.kubeletService.namespace`, `kubelet.namespace`). `global.rbac.create: false` (chỉ tắt RBAC của
    operator và Prometheus; subchart Grafana, kube-state-metrics có công tắc riêng), `extraManifests` chứa RBAC mà chart
    render, tách đôi: ClusterRole `kps-operator` chỉ còn `nodes` (`list/watch`), `namespaces` (`get/list/watch`),
    `storageclasses` (`get`), event (`create/patch`: operator v0.94.1 kiểm quyền này cho mọi namespace dù chỉ watch
    `svp-obs`, thiếu thì không phát event nào); mọi rule khác (Secret, ConfigMap, StatefulSet, pod, Service, Endpoints,
    EndpointSlice, ingress, CR `monitoring.coreos.com`) giữ nguyên verb trong Role `kps-operator` ở `svp-obs`. ClusterRole
    `kps-prometheus` chép nguyên. Hệ quả: `PrometheusRule`, `ServiceMonitor`, `PodMonitor` của project phải nằm ở
    `svp-obs`; muốn scrape pod namespace khác (Envoy, mục 13) thì đặt `namespaceSelector` trong `PodMonitor`, Prometheus tự
    discover bằng quyền của nó.
  - **Còn lại** khi bị chiếm: operator đọc, ghi, xoá mọi Secret ở `svp-obs` (`grafana-admin`, `alertmanager-*`,
    `glitchtip-*`), tạo StatefulSet ở `svp-obs`, ghi (không đọc) event ở mọi namespace. Trong các Secret đó có
    `kps-prometheus-token`, token không hết hạn của ServiceAccount `kps-prometheus` mà chart render cho scrape kubelet: có
    nó, operator bị chiếm có thêm mọi quyền đọc toàn cluster của ClusterRole `kps-prometheus` (bên dưới), vẫn không Secret
    nào ngoài `svp-obs` (**sửa 2026-10-19**, trước không ghi). Prometheus `get/list/watch` pod,
    Service, Endpoints, EndpointSlice, Ingress, node toàn cluster và đọc `/metrics`, `/metrics/cadvisor` của kubelet (spec
    pod không chứa giá trị bí mật: service nhận Secret qua `envFrom`/`secretKeyRef`); kube-state-metrics `list/watch`
    ConfigMap và các kind nó đếm toàn cluster; Pyroscope Role `pyroscope-discovery` (endpoints, service, pod ở `svp-obs`);
    Loki ClusterRole rỗng; Tempo, Collector, Alertmanager không Role nào (Alertmanager cũng không mount token).
  - **Nâng kube-prometheus-stack:** render bản mới với RBAC của chart (lệnh đủ ở comment `global.rbac` của values), so
    ClusterRole `kps-operator`, `kps-prometheus` với `extraManifests`, nhận mọi thay đổi nhưng giữ rule có namespace trong
    Role, rồi kiểm log operator không có `forbidden` trong 5 phút.
  - **Sửa 2026-10-18:** trước để RBAC mặc định: Grafana có ClusterRole `get/list/watch` ConfigMap **và Secret** toàn cluster
    với token mount ở cả ba container, kube-state-metrics `list/watch` Secret toàn cluster, operator mọi verb trên Secret và
    StatefulSet toàn cluster; chiếm Grafana là đọc được khoá ký JWT ở `svp/user-service-env`.

## 12. GitOps

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Argo CD app-of-apps** | Đã chốt ở plan; UI và health tốt để học | Thêm ~0,4 GiB |
| Flux | Nhẹ hơn | Khác công cụ đã chốt; chỉ đọc để so sánh |
| ApplicationSet | Sinh Application theo generator | Thêm controller; một file JSON đã đủ |
| **Poll 60 s, jitter 0** | Không cần cluster nhận webhook từ internet | Thấy commit mới thường ≤ 60 s sau push, tệ nhất ~120 s (bên dưới) |
| Webhook GitHub | Đồng bộ gần như ngay | Cluster local không nhận được request từ GitHub |
| **Ghi tag bằng commit (`make k8s-release`)** | Lịch sử phát hành nằm trong git; rollback bằng `git revert` | Một commit thêm mỗi lần phát hành |
| Argo CD Image Updater / CI tự ghi tag | Tự động | Là việc của giai đoạn 5 |

### Quyết định

- **Argo CD** chart mục 1, release `argocd` ở `argocd`, tối giản: `dex.enabled: false`, `notifications.enabled: false`,
  `applicationSet.replicas: 0` (chart không có cờ tắt hẳn; Deployment vẫn render nhưng không có pod), Service
  `argocd-server` ClusterIP, đăng nhập admin (mật khẩu ở Secret `argocd-initial-admin-secret`; script chỉ in lệnh đọc, không
  in giá trị).
- **Poll:** `configs.cm."timeout.reconciliation": 60s` **và** `configs.cm."timeout.reconciliation.jitter": 0s` (cả hai
  thuộc `argocd-cm`, không phải `configs.params`). Chart 10.10.5 mặc định jitter `60s`, và controller v3.5.5 hoãn mỗi lần
  làm mới định kỳ thêm một khoảng ngẫu nhiên 0–jitter (`controller/appcontroller.go`, `statusRefreshJitter`), nên chỉ đặt
  `60s` thì chu kỳ thật là 60–120 s. `helm template` với hai giá trị trên: `argocd-cm` có `timeout.reconciliation: 60s`,
  `timeout.reconciliation.jitter: 0s`; StatefulSet controller đọc chúng qua `ARGOCD_RECONCILIATION_TIMEOUT`,
  `ARGOCD_RECONCILIATION_JITTER` (`0s` là không hoãn).
  - Repo-server cache kết quả `ls-remote` theo URL repo, hạn bằng chính `timeout.reconciliation` (Deployment repo-server
    cũng nhận `ARGOCD_RECONCILIATION_TIMEOUT`; cờ `--revision-cache-expiration`, `reposerver/cache/cache.go@v3.5.5`), và
    cache đó dùng chung cho mọi Application trỏ cùng repo (khoá `git-refs|<URL repo>`, `gitRefsKey` cùng file; đọc ở
    `getRefs`, `util/git/client.go`). Một Application tới lượt làm mới
    có thể đọc ref do Application khác lấy tới 60 s trước. Vì vậy push → Argo CD thấy commit **thường ≤ 60 s, tệ nhất
    ~120 s**; diễn tập GitOps so số đo với cận này. Giảm `timeout.reconciliation` thì cả hai cận giảm theo, đổi lấy thêm
    `ls-remote` tới GitHub.
- **Repo:** `git@github.com:anhnvcoder/short-video-platform.git` qua SSH bằng **deploy key chỉ đọc do người học tạo**,
  đường dẫn file truyền vào `make k8s-gitops-up ARGOCD_DEPLOY_KEY=<file>` (không vào repo, không in); `known_hosts` của
  GitHub có sẵn trong `argocd-ssh-known-hosts-cm`.
- **`AppProject` `svp`:** `sourceRepos` = repo trên + đúng các repo chart ở bảng mục 1 (`https://charts.jetstack.io`,
  `docker.io/envoyproxy` (OCI), `https://cloudnative-pg.github.io/charts`, `https://charts.redpanda.com`,
  `https://kedacore.github.io/charts`, `https://prometheus-community.github.io/helm-charts`,
  `https://grafana-community.github.io/helm-charts`, `https://grafana.github.io/helm-charts`,
  `https://open-telemetry.github.io/opentelemetry-helm-charts`, `https://argoproj.github.io/argo-helm`).
  - `destinations` = các namespace ở mục 3 (kể cả `cert-manager` cho CA của `svp-cluster`) **và `kube-system`**. Chart
    KEDA 2.21.0 render RoleBinding `keda-operator-auth-reader` ở `kube-system`, gắn Role có sẵn
    `extension-apiserver-authentication-reader` để metrics apiserver của KEDA đọc ConfigMap
    `extension-apiserver-authentication`; Role đó chỉ có ở `kube-system` nên RoleBinding không dời được. Thiếu `kube-system`
    thì Argo CD từ chối resource đó ("namespace kube-system is not permitted in project 'svp'") và Application `keda` không
    bao giờ sync.
  - cert-manager đặt **`global.leaderElection.namespace: cert-manager`**: mặc định `kube-system` làm chart render
    Role/RoleBinding `cert-manager:leaderelection`, `cert-manager-cainjector:leaderelection` ở đó; Lease bầu leader chuyển về
    namespace của chart.
  - Đã `helm template --include-crds` mọi chart upstream ở bảng mục 1 với values dự định: ngoài namespace release của từng
    chart, chỉ còn RoleBinding trên của KEDA. Service kubelet ở `kube-system` do Prometheus operator tự tạo
    (`prometheusOperator.kubeletService`), không qua Argo CD; scrape `coreDns`, `kubeProxy`, `kubeEtcd`... đã tắt (mục 11)
    nên kube-prometheus-stack không render Service nào ở `kube-system` (bật lại cái nào thì chart render Service ở đó).
  - Cái giá của `kube-system`: Application của project `svp` được ghi resource vào namespace hệ thống. Quyền thực chất không
    tăng, vì whitelist dưới đã cho `ClusterRole`/`ClusterRoleBinding` (ai đổi được nhánh `main` hay chart đã ghim đã có quyền
    ngang cluster-admin), nhưng values sai có thể đặt nhầm resource vào đó. Hẹp hơn là tách AppProject riêng cho chart
    platform (được `kube-system`) và cho phần ứng dụng (không được); chưa cần ở lab, xem lại khi thêm người hay repo.
  - Whitelist cluster-scope, lấy từ cùng lượt `helm template`: `Namespace`, `CustomResourceDefinition`, `ClusterRole`,
    `ClusterRoleBinding`, `ValidatingWebhookConfiguration`, `MutatingWebhookConfiguration`, `ValidatingAdmissionPolicy`,
    `ValidatingAdmissionPolicyBinding` (Envoy Gateway: `safe-upgrades.gateway.networking.k8s.io`), `APIService` (KEDA),
    `ClusterIssuer`, `GatewayClass` (hai kind cuối từ chart `svp-cluster`), `ClusterTriggerAuthentication` (chart
    `svp-data`, mục 10). Chart của project kiểm ở bước GitOps (thiếu kind nào thì Application báo lỗi, thêm đúng kind đó).
    **Sửa 2026-10-18:** thêm `ClusterTriggerAuthentication`, có từ khi đăng nhập Kafka của KEDA chuyển sang chart
    `svp-data` (mục 10). `helm template --include-crds` lại cả 19 thành phần của `components.json` với values hiện tại (kể
    cả `extraObjects` của KEDA, `extraManifests` của kube-prometheus-stack, 4 chart của project) và API version của
    cluster: không còn kind cluster-scope nào khác; resource ghi namespace khác namespace của Application chỉ có các
    namespace của project (do `svp-cluster`) và RoleBinding của KEDA ở `kube-system`. `PrometheusRule` là kind có
    namespace, AppProject không giới hạn kind có namespace nên không phải thêm.
- **Quyền của Argo CD** (ngoại lệ của nguyên tắc "không workload nào ngoài control plane đọc được Secret ngoài namespace
  của chính nó", mục 10, 11). Chart 10.10.5 cho application-controller ClusterRole `*` trên mọi resource và
  `nonResourceURLs`, cho argocd-server ClusterRole `get`/`patch`/`delete` trên mọi resource (cả Secret), `create` Job, `get`
  log pod ở mọi namespace, và Role ghi Application, AppProject, Secret, ConfigMap ở `argocd`. Giữ nguyên, ghi là ngoại lệ:
  - **Bản chất công cụ:** controller áp mọi chart của cluster, gồm Secret do chart render (`kps-prometheus-token`,
    `redpanda-sts-lifecycle`, `redpanda-configurator`), `ClusterRole`, `ClusterRoleBinding`, webhook; Argo CD tương đương
    cluster-admin, như mọi công cụ GitOps quản lý cả platform.
  - **Thu hẹp server không giảm được gì:** Role của server ở `argocd` cho tạo Application và AppProject, controller áp mọi
    thứ một Application khai; server bị chiếm (hay ai đăng nhập được admin) vẫn tới được mọi Secret qua một Application.
    Bỏ `secrets` khỏi ClusterRole của server mà giữ `patch` Deployment thì vẫn đọc được qua sửa pod rồi đọc log; bỏ hết
    thì mất nút restart, xoá, xem manifest sống trên UI.
  - **Phạm vi được bảo vệ bằng:** không Service nào ra ngoài cluster (`argocd-server` ClusterIP, chỉ port-forward
    `127.0.0.1:8081`, đăng nhập admin, OPS-2); không SSO, không notifications; deploy key chỉ đọc nên Argo CD không ghi được
    repo; AppProject `svp` giới hạn nguồn, đích, kind cluster-scope cho mọi Application, kể cả Application thử ngoài danh
    sách (bị từ chối `InvalidSpecError`). AppProject `default` (argocd-server tạo khi thiếu, mở mọi nguồn, đích, kind;
    Application khai `project: default` hay không khai project thì thoát giới hạn của `svp`) bị **khoá** bằng chính
    `deploy/argocd/project.yaml`: `sourceRepos`, `sourceNamespaces`, `destinations`, `clusterResourceWhitelist` rỗng,
    `namespaceResourceBlacklist` `*/*`, không deploy được gì; `gitops.sh` áp với `--force-conflicts` (argocd-server giữ
    field của bản nó tạo). argocd-server chỉ tạo khi chưa có (`initializeDefaultProject`, `server/server.go@v3.5.5`), nên
    bản khoá giữ qua restart; xoá nó đi thì lần khởi động sau tạo lại bản mở. **Sửa 2026-10-19:** trước ghi `default` là
    "còn hở, chấp nhận ở lab".
  - Đo trên cluster GitOps lúc mới cài (chưa có Application con): controller 150 MiB, repo-server 75, server 51, Redis
    12 (`kubectl top`). **Sửa 2026-10-18** (mục này thêm ở bước GitOps).
- **Quyền của ba operator platform còn lại** (cùng nguyên tắc; KEDA ở mục 10, observability mục 11, Argo Rollouts mục 13).
  `make drill-k8s-threats` kiểm bằng `kubectl auth can-i` và SelfSubjectRulesReview ở mọi namespace; ngoại lệ in `info` kèm
  lý do. **Sửa 2026-10-19** (mục này thêm ở vòng sửa sau diễn tập threat model):
  - **CloudNativePG: không còn là ngoại lệ.** Chart 0.29.1 mặc định cho operator ClusterRole tạo, đọc, xoá Secret, pod,
    `pods/exec`, Deployment, Job, Role ở mọi namespace và `get/patch` mọi Mutating/ValidatingWebhookConfiguration (đủ để sửa
    một webhook nhận mọi Secret được ghi trong cluster). `deploy/k8s/values/cloudnative-pg.yaml`: `rbac.create: false`, env
    `WATCH_NAMESPACE=svp-data` và `MANAGE_WEBHOOK_CONFIGURATIONS=false` (`clusterWide: false` của chart không dùng được: nó
    đặt env `WATCH_NAMESPACE=cnpg-system`, và operator 1.30.1 dựng cache theo env trước khi đọc ConfigMap, nên không bao giờ
    thấy `svp-pg`). `svp-cluster` render `templates/cnpg-rbac.yaml`: rule có namespace của chart (`commonRules`) trong Role ở
    `cnpg-system` và `svp-data`, ClusterRole chỉ đọc nodes và ClusterImageCatalogs, không quyền webhook nào. Chứng chỉ webhook
    do cert-manager cấp (`templates/cnpg-webhook-certificate.yaml`: Issuer selfSigned + Certificate `cnpg-system/cnpg-webhook`
    → Secret `cnpg-webhook-cert` mà chart đã mount, đúng một DNS `cnpg-webhook-service.cnpg-system.svc`; operator giữ Secret có
    sẵn khớp DNS và còn hơn 7 ngày, cert-manager gia hạn trước 30 ngày), cainjector chèn CA vào hai webhook config theo
    annotation `cert-manager.io/inject-ca-from`. Tự ký, không chuỗi CA: lúc gia hạn API server tin cert mới ngay còn operator
    phục vụ cert cũ tới khi kubelet làm mới mount (~1 phút), giống cách operator tự xoay vòng; Issuer CA thì caBundle đứng yên
    nhưng thêm hai object, xét lại kèm ADR nếu cần. `install.sh` chờ Certificate Ready sau `svp-cluster` và caBundle của cả
    hai webhook config sau `cloudnative-pg`; đường GitOps: health Certificate chặn wave, `retry` lo lần gọi webhook sớm. Còn
    lại khi bị chiếm: Secret, pod, exec ở `cnpg-system` và `svp-data`; ghi được `cnpg-webhook-cert` thì cainjector chèn CA khác
    vào **chỉ hai webhook của CNPG**, rule và đích không đổi (chỉ CR `postgresql.cnpg.io`), nên không Secret nào ngoài hai
    namespace đó tới được nó.
  - **Envoy Gateway: ngoại lệ đã thu hẹp.** Mặc định controller watch mọi namespace với ClusterRole đọc mọi Secret và `patch`
    mọi pod (topology injector). `deploy/k8s/values/envoy-gateway.yaml`: `watch.namespaces: [envoy-gateway-system, svp,
    svp-data, svp-edge]` (chart chuyển rule có namespace thành Role ở từng namespace đó; toàn cluster chỉ còn đọc nodes,
    namespaces, GatewayClass, ServiceImport), tắt topology injector (không webhook, không quyền pod; node k3d không có zone).
    Còn lại: đọc Secret ở bốn namespace đó, gồm `svp` và `svp-data`. v1.9.2 cache Secret ở mọi namespace watch, không value
    nào thu hẹp theo tên, và `svp`, `svp-data` phải watch vì có HTTPRoute và Service backend. Vì Role của nó ở namespace dự án
    có từ wave 0, hai script tạo namespace dự án trước wave 0 (mục 3).
  - **cert-manager: ngoại lệ đầy đủ**, RBAC của chart giữ nguyên (`deploy/k8s/values/cert-manager.yaml`). Controller:
    mọi verb trên Secret, tạo/xoá pod và Service, tạo/sửa Ingress, HTTPRoute (solver ACME HTTP-01, không dùng) ở mọi
    namespace; cainjector: đọc Secret mọi namespace, `update/patch` mọi webhook config, APIService, CRD. Lý do:
    Certificate ở bốn namespace (`cert-manager`: `svp-local-ca`, `svp-edge`: `svp-wildcard`, `keda`: chứng chỉ của KEDA,
    `cnpg-system`: `cnpg-webhook`); v1.21.2 không có RBAC theo namespace, `--namespace` chỉ phục vụ một namespace và tắt
    ClusterIssuer (`svp-selfsigned`, `svp-ca`). cainjector chèn CA cho KEDA (APIService
    `v1beta1.external.metrics.k8s.io`, webhook `keda-admission`), CloudNativePG (hai webhook config) và chính
    cert-manager: chính nó cho KEDA và CNPG không giữ quyền nào trên webhook và APIService. Pod của chính cert-manager
    chạy dưới PSA `restricted` của namespace `cert-manager` (mục 3) và không route nào của Gateway `svp` tới chúng.
    ClusterRole `cert-manager-controller-challenges` cho ServiceAccount `cert-manager/cert-manager` `create` pod ở mọi
    namespace; pod đó bị giữ ở `restricted` ở namespace có nhãn và, nhờ mức mặc định của API server
    (`deploy/k8s/pod-security-admission.yaml`, mục 3), ở mọi namespace không nhãn (`default`, `kube-public`,
    `kube-node-lease`, namespace tạo sau). **Còn hở:** `kube-system`, miễn trừ cho pod của k3s (`svclb-*` cần
    `NET_ADMIN`, helper pod của local-path cần hostPath): token của controller bị lấy vẫn tạo được pod privileged với
    hostPath của node ở đó, tức root trên node, mà node server giữ kubeconfig admin của k3s. Đóng hẳn cần bỏ quyền tạo
    pod của controller (RBAC tự render không có phần solver ACME, như CloudNativePG) hay một ValidatingAdmissionPolicy
    từ chối pod do ServiceAccount đó tạo; chưa làm.
    **Sửa 2026-10-19:** trước ghi "Giới hạn bằng PSA `restricted` của `cert-manager`", như thể PSA đó chặn mọi pod
    mà controller tạo; sau đó thêm mức mặc định `restricted` toàn cluster trừ `kube-system`, trước đó `default`,
    `kube-public`, `kube-node-lease` cũng hở.
- **Root Application `svp-root`** → chart `deploy/argocd/apps` (`targetRevision: main`) → mỗi phần tử của `components.json`
  một Application con: chart upstream dùng multi-source (chart + `ref: values` của repo, `valueFiles: [$values/...]`; ổn định
  từ v2.13, không còn beta), chart trong repo dùng `path`; `syncPolicy.automated` có `prune` + `selfHeal`;
  `argocd.argoproj.io/sync-wave` = `wave`; `ServerSideApply=true` cho mọi Application (CRD `httproutes`, `envoyproxies`,
  `securitypolicies` của Envoy Gateway, `scaledjobs` của KEDA, `clusters`/`poolers` của CloudNativePG vượt giới hạn 262144 byte
  của annotation client-side apply), `SkipDryRunOnMissingResource=true` khi CRD đến từ wave trước; tên release = `name` (như
  đường dev). `targetRevision` luôn là chuỗi: root do `jq --arg` sinh thành JSON, chart `apps` quote mọi `targetRevision`;
  nhánh tên `2026`, `true`, `1e3` viết trần vào YAML thành số hay boolean và CRD Application từ chối. **Sửa 2026-10-19.**
- **Health của Application con:** từ 1.8 Argo CD không còn đánh giá health của `argoproj.io/Application`
  (`docs/operator-manual/health.md@v3.5.5`, mục "Argocd App"), nên sync wave của app-of-apps không chờ thành phần trước
  Healthy. Values của Argo CD thêm `configs.cm."resource.customizations.health.argoproj.io_Application"`, dựa trên đoạn Lua
  của tài liệu bản đó (chỉ chép `status.health`) và thêm trạng thái sync, vì `status.health` bỏ qua hook
  (`controller/health.go@v3.5.5`): `svp-data` đã Healthy trong khi Job PostSync `pg-bootstrap` (tạo database, role) còn chạy
  hay đã lỗi thì root vẫn sang wave 5. Application con là:
  - **Progressing** khi chưa có status; khi sync đang chạy (`operationState.phase` khác `Succeeded`/`Failed`/`Error`: gồm
    hook, và cả lúc thử lại một sync lỗi, vì Argo CD để `Running` giữa các lần thử); khi `OutOfSync` ở revision chưa có
    sync nào xong (`syncResult.revision(s)` khác `sync.revision(s)`: sync tự động của revision đó chưa bắt đầu). Chỉ xét
    lúc `OutOfSync`: Argo CD chỉ tự sync Application `OutOfSync` (`autoSync`, `controller/appcontroller.go@v3.5.5`), nên
    Application vẫn `Synced` ở revision mới (commit không đổi gì của nó) giữ kết quả sync của revision cũ; đòi kết quả đúng
    revision hiện tại thì nó Progressing mãi và chặn mọi wave sau.
  - **Degraded** khi sync cuối `Failed`/`Error` sau khi hết lượt thử: sync của root dừng kèm message thay vì chờ.
  - còn lại: `status.health` của chính nó, như đoạn Lua của tài liệu.

  Còn một khe nhỏ chưa đóng: khi root đổi spec của một Application con đã có, tới lần so sánh kế của con (vài giây) status
  vẫn là của spec cũ, nên wave sau có thể bắt đầu sớm. Lúc dựng cluster mới thì không có khe này (con mới chưa có status là
  Progressing). Kiểm bằng `argocd admin settings resource-overrides health` trong pod `argocd-server` với các mẫu ở trên.
  **Sửa 2026-10-18** (bản đầu chỉ chép đoạn Lua của tài liệu).

  Health của CR `Alertmanager` (`monitoring.coreos.com`): Argo CD v3.5.5 có sẵn health cho `Prometheus` mà không cho
  `Alertmanager`, nên Application `kube-prometheus-stack` Healthy khi pod Alertmanager còn đang khởi động (đường dev
  `install.sh` chờ condition `Available`). Values của Argo CD thêm
  `resource.customizations.health.monitoring.coreos.com_Alertmanager`: **Progressing** khi chưa có condition, condition của
  generation cũ hay `Available` khác True (không Degraded như health Prometheus khi `NoPodReady`: Degraded làm wave đang chờ
  thất bại, mà Alertmanager mới nào cũng bắt đầu không pod Ready); **Degraded** khi `Reconciled` False (operator không áp được
  CR, như Secret cấu hình không đọc hay không parse được); **Healthy** khi `Available` True. **Sửa 2026-10-19.**
- **Hai đường cài:** **dev** `make k8s-up` (helm từ working tree theo `components.json`, mọi bước dựng dùng) và **GitOps**
  `make k8s-gitops-up` (cluster mới; chỉ cài Argo CD, Secret, repo, `AppProject`, root app; Argo CD dựng phần còn lại từ
  GitHub). Không chạy hai đường trên một cluster: `k8s-up` từ chối khi có Application `svp-root`.
- **Push code → image mới → Argo CD thấy:** người học commit code → `make k8s-release SVC=<svc>` build/push tag SHA và ghi tag
  vào values → người học duyệt commit + push → Argo CD poll thấy (thường ≤ 60 s, tệ nhất ~120 s) → sync →
  Rollout/Deployment. Argo CD Image Updater
  và CI tự ghi tag là **giai đoạn 5**.
- **Bootstrap không phụ thuộc working tree:** `k8s-gitops-up` đọc tag phát hành từ đúng revision Argo CD sẽ đồng bộ (`git show
  origin/main:deploy/k8s/values/services/<svc>.yaml`, không `git fetch`, in SHA của revision). Revision chưa có thư mục đó thì
  bỏ qua bước image và ghi rõ; có file mà tag rỗng hay không phải commit có thật thì lỗi nêu tên service **trước khi tạo
  cluster**. Danh sách Application phải chờ (root + mỗi thành phần) cũng đọc từ `components.json` ở đúng revision đó, trước
  khi tạo cluster. Image thiếu trong registry dựng lại bằng `build_release_image` (mục 6). Khi Application GlitchTip Healthy,
  chạy cùng bước `k8s-glitchtip-init` như đường dev để DSN có trong Secret. Vòng chờ cuối coi một Application xong khi
  `Synced`, Healthy **và** sync cuối `Succeeded` (cùng tiêu chí với health check ở trên); condition loại `*Error`
  (`ComparisonError` khi deploy key chưa thêm trên GitHub hay revision không có...) hay sync `Failed` được in ngay khi xuất
  hiện, và còn nguyên sau 180 s (ba lần poll, không phải lỗi thoáng qua) thì script dừng, không chờ hết 1800 s.
  **Sửa 2026-10-18.**
- **Đo push → pod mới Ready:** giờ push từ reflog `refs/remotes/origin/main` (người học push từ máy này); không có thì
  PushEvent của GitHub (`gh api repos/anhnvcoder/short-video-platform/events`, chỉ đọc, ghi nguồn); không có cả hai thì "không
  đo được", **không** thay bằng giờ commit; giờ sync từ `status.operationState`/`status.history`, giờ Ready từ condition
  của pod. Sync đang chạy nhận theo cả revision được yêu cầu lẫn revision đã resolve (`syncResult`): sync tay theo `main`
  chỉ ghi SHA trong kết quả. Commit không còn đo được thì báo thẳng (exit 1) thay vì chờ mãi: Argo CD đã sync một commit
  sau nó mà không sync nó (push chung, hay bị commit sau thay trước lần poll), hoặc Application của service nó phát hành
  đã sync một commit sau (pod có thể đến từ lần sync đó). **Sửa 2026-10-18.**
  Commit không đổi `image.tag` nào bị báo ngay từ git, trước khi đọc cluster (không Application nào sync nó). Giờ Ready chỉ
  lấy từ pod còn giữ giờ Ready của lượt rollout: pod có `restartCount > 0` (Ready lại sau lần khởi động cuối) và pod tạo sau
  lượt rollout (HPA scale-out, pod thay pod bị evict) bị bỏ khỏi số đo và ghi tên; không còn pod nào thì báo không đo được.
  Pod đầu của lượt rollout do chính sync của Application service đó tạo, nên chỉ được tính khi tạo trong cửa sổ từ
  `deployStartedAt` tới `deployedAt` + 10 s (`rollout_slack`, cho phản ứng của controller và giây chẵn của timestamp) của lần
  sync đầu theo REV trong `status.history`; pod tạo trước hay sau cửa sổ (như pod thay pod bị evict khi mọi pod của rollout
  đã mất) bị loại và ghi tên, không còn pod nào thì exit 1 "không đo được". Mốc dưới là `deployStartedAt`: sync áp template
  trong khoảng [bắt đầu, kết thúc], pod tạo trong khoảng đó là của rollout. Sau đó, xếp theo giờ tạo, pod thuộc lượt rollout
  khi được tạo không quá GAP giây sau pod đầu hay sau giờ Ready của một pod rollout trước nó (rolling update tạo pod kế ngay
  khi pod trước Ready; chart không đặt `minReadySeconds`). GAP = `rollout_slack`, cộng thêm, khi service là Rollout, thời
  gian tối đa các bước canary giữ nó, đọc từ Rollout đang chạy: tổng `pause.duration` và với mỗi bước `analysis` thì metric
  lâu nhất của AnalysisTemplate (`initialDelay + (count − 1) × interval + count × (lỗi × (timeout + 10) + timeout)`, mặc định
  `timeout` 30 s, `consecutiveErrorLimit` 4; metric không có `count` thì trần 600 s mỗi bước). Gateway: hai pause 60 s và
  bước gate (mục 13) → GAP 180 s; pod thứ hai của nó tạo sau cả hai pause và gate. HPA scale-out trong khoảng GAP của Rollout
  không bị loại (giới hạn đã biết). **Sửa 2026-10-19:** bản trước cho 10 s kể từ pod đầu, không cửa sổ theo sync; pod thứ hai
  của gateway (~120 s sau pod đầu Ready, sau các pause) bị bỏ, và pod thay pod bị evict sau lượt rollout vẫn được tính.

## 13. Canary

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Argo Rollouts + plugin Gateway API** | Canary chia traffic thật ở Envoy; phân tích tự động từ Prometheus; hợp Argo CD | Thêm controller + plugin tải lúc chạy |
| Flagger | Hỗ trợ Gateway API sẵn | Hệ sinh thái Flux; khác công cụ đã chốt |
| Chỉ rolling update | Không thêm gì | Không có phân tích, không tự rollback |
| **Chỉ gateway là Rollout** | Dịch vụ ở biên, đo được ở Envoy theo backend | Service khác không có canary |
| **Metric của Envoy theo backend** | Đo đúng thứ client nhận, không phụ thuộc instrumentation của bản mới | Phải buộc Envoy Gateway tách cluster theo backendRef (bên dưới) |
| Metric OTLP của chính gateway, lọc theo pod canary (`service.version` từ label `rollouts-pod-template-hash`) | Không phụ thuộc cách Envoy Gateway đặt cluster | Bản lỗi crash sớm hay hỏng exporter thì không có metric; phải thêm biến từ downward API |

### Quyết định

- **Argo Rollouts** (chart mục 1) với plugin **`argoproj-labs/gatewayAPI`** đăng ký qua `controller.trafficRouterPlugins`
  (`name`, `location`, `sha256`; sha256 chỉ được kiểm khi tải qua http(s), `PluginItem` ở `types.go@v1.10.1`):

  | Asset | URL | sha256 |
  | --- | --- | --- |
  | `gatewayapi-plugin-linux-arm64` (node arm64, dùng) | `https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.17.0/gatewayapi-plugin-linux-arm64` | `5221279f7bf2c9b2c0ff6ed7ff12718ecce1d4892f1ff5e5224bb723cfd0fd92` |
  | `gatewayapi-plugin-linux-amd64` | `.../v0.17.0/gatewayapi-plugin-linux-amd64` | `1904ca787d33107c140521899d61fff030ee75d99908bd175fca5a4647759061` |

  Release không có file checksum; sha256 tính bằng `shasum -a 256` trên file tải về, khớp digest asset của GitHub. Controller
  tải plugin từ GitHub lúc khởi động (namespace `argo-rollouts` không chặn egress). Plugin build với Gateway API v1.4.0, dùng
  HTTPRoute `gateway.networking.k8s.io/v1`, chỉ đọc rồi `Update` trọng số; so field của HTTPRoute giữa v1.4.0 và v1.6.1 (bản
  đi kèm Envoy Gateway) không có field mới nên Update không làm mất field (suy luận). Đã chạy trên cluster (2026-10-18):
  plugin tải đúng sha256, đổi trọng số HTTPRoute `api` qua Envoy Gateway v1.9.2 đầu-cuối, filter của backendRef còn nguyên.
- **Quyền của controller** (cùng nguyên tắc mục 10, 11: không workload nào ngoài control plane đọc được Secret ngoài namespace
  của chính nó). Chart 2.43.8 mặc định cho controller ClusterRole đọc mọi Secret (cho AnalysisTemplate trỏ Secret), tạo Job
  ở mọi namespace (job metric), `update` mọi pod, `patch` mọi Service, và `providerRBAC` thêm `get/list/watch/update` trên mọi
  `httproutes`. Thay bằng controller namespaced (`deploy/k8s/values/argo-rollouts.yaml`):
  - `clusterInstall: false` (chart truyền `--namespaced` và render rule của nó thành Role ở `argo-rollouts`),
    `controller.extraArgs: [--namespace=svp]` (mọi informer chỉ watch `svp`, namespace duy nhất có Rollout),
    `providerRBAC.enabled: false`, `ARGO_ROLLOUTS_ANALYSIS_JOB_NAMESPACE=argo-rollouts` (không phân tích nào dùng Job; có thì
    Job chạy ở `argo-rollouts`). Lease, ConfigMap `argo-rollouts-config` (plugin), ConfigMap và Secret notification ở lại
    `argo-rollouts`: controller đọc chúng theo namespace của ServiceAccount, không theo `--namespace`.
  - Role `argo-rollouts` ở `svp` (`extraObjects`): Rollout (cả `status`, `finalizers`), AnalysisRun, đọc AnalysisTemplate và
    Experiment, ReplicaSet, `get/list/watch/patch` Service (thêm `rollouts-pod-template-hash` vào selector), `list/watch` pod và
    `create` `pods/eviction` (restart bằng `spec.restartAt`), event, `list/watch` Ingress (controller luôn khởi động informer
    Ingress và chờ nó sync), `httproutes` chỉ `resourceNames: [api]` với `get/update`. Không Secret, ConfigMap, Job,
    Deployment, `update` pod, tạo/xoá Service, ClusterAnalysisTemplate.
  - **Ngoại lệ:** ở `argo-rollouts`, Role của chart (render khi `clusterInstall: false`, không value nào của chart 2.43.8 thu
    hẹp được) cho controller đọc Secret ở đó, tạo Job, `update` Deployment (cả của chính nó) và pod, tạo Service và Ingress.
    PSA `restricted` của namespace này (mục 3) giới hạn thứ chúng chạy được: pod non-root, không privileged, capability,
    hostPath hay host namespace, nên không tới được node; pod đó chỉ có Secret và ServiceAccount của `argo-rollouts`, tức của
    chính controller. Ở `svp`, controller tạo ReplicaSet và evict pod, nên bị chiếm thì tới được Secret của `svp` gián tiếp
    (một ReplicaSet có pod `envFrom` `user-service-env`), như mọi workload controller (Deployment controller của control
    plane cũng vậy). Không quyền đọc Secret nào ngoài `argo-rollouts`; không pod, Service, route nào ngoài `argo-rollouts` và
    `svp`; không route nào của `svp` ngoài HTTPRoute `api`. **Sửa 2026-10-19:** trước ghi ở `argo-rollouts` chỉ có "Secret
    của chính nó" khi namespace chưa gắn PSA, trong lúc Job privileged với hostPath `/` dưới ServiceAccount của controller
    được admission nhận (server dry-run).
  - Đã kiểm trên cluster: ServiceAccount `argo-rollouts` chỉ có RoleBinding `argo-rollouts/argo-rollouts` và
    `svp/argo-rollouts`, không ClusterRoleBinding; log controller không `forbidden` qua canary, abort và `restartAt`. PSA của
    `argo-rollouts` (2026-10-19): pod privileged với hostPath `/` bị admission từ chối (`--dry-run=server`); Job như vậy chỉ bị
    cảnh báo vì PSA xét pod, và pod của nó bị từ chối như trên; pod controller tạo lại dưới nhãn chạy, tải plugin, qua một lượt
    `drill-k8s-canary`. Nâng chart: cách so rule ở comment đầu file values. **Sửa 2026-10-19:** trước để RBAC mặc định của chart (ClusterRole, Secret
    toàn cluster).
- **Restart gateway không tạo revision:** mọi thay đổi pod template của Rollout là một revision, tức một canary cần traffic,
  nên `kubectl rollout restart` (đóng dấu annotation vào template) không dùng cho gateway. Script (`restart_workload` của
  `deploy/k8s/lib.sh`, dùng khi Secret của service đổi và ở `glitchtip-init.sh`) đặt `spec.restartAt` bằng giờ hiện tại:
  controller evict lần lượt pod tạo trước mốc đó qua PDB, template không đổi; xong khi `status.restartedAt` bằng mốc và
  Rollout Healthy. `restartAt` không chart nào ghi, nên Helm hay Argo CD không trả lại. Đường GitOps restart tay bằng lệnh
  `patch` ở comment đầu `deploy/k8s/gitops.sh`. Dưới traffic diễn tập một lần restart có 4 × 503 / 236 request (pod đang tắt
  còn nhận request trước khi Envoy cập nhật endpoint). **Sửa 2026-10-19.**
- **Helm cho release có canary** (đường dev, `deploy/k8s/install.sh`): release `gateway` cài **client-side**
  (`--server-side=false`) với `--wait=hookOnly`. Rollouts ghi vào hai object của chart: selector của Service `gateway`,
  `gateway-canary` (`rollouts-pod-template-hash`) và trọng số trong HTTPRoute `api`. Server-side apply của Helm 4 gửi nguyên
  `Service.spec.selector` và `HTTPRoute.spec.rules` của chart, cả hai là field atomic đã thuộc controller và plugin, nên
  upgrade lỗi vì xung đột; thêm `--force-conflicts` thì xoá hash khỏi selector, mọi request tới cả pod stable lẫn canary tới
  khi controller đặt lại. Client-side chỉ patch phần khác giữa manifest của release trước và bản này, nên Service và route
  không đổi được giữ như controller đặt. `--wait` của Helm (kstatus) không bao giờ thấy Rollout ready và treo tới
  `--timeout`: Helm chỉ chờ hook, `wait_rollout` của `install.sh` chờ Rollout `Healthy` có hạn. Năm service còn lại giữ
  server-side apply. **Sửa 2026-10-19.**
- **Chỉ gateway** là `Rollout`; service khác là Deployment rolling update. Service `gateway` (stable) và `gateway-canary`;
  HTTPRoute `api` một rule, hai backendRef theo thứ tự `gateway` rồi `gateway-canary`; `trafficRouting.plugins`
  `argoproj-labs/gatewayAPI: {httpRoute: api, namespace: svp}`.
- **Bước:** `setWeight: 25` → `pause: {duration: 60s}` → `setWeight: 50` → `pause: {duration: 60s}` → bước `analysis` với
  AnalysisTemplate **`gateway-canary-gate`** → 100%; `progressDeadlineSeconds: 600`, `progressDeadlineAbort: true`. Phân tích
  chạy nền từ bước đầu (`analysis.templates`, `startingStep: 0`).
  - **Vì sao có bước gate:** riêng phân tích nền không giữ được canary khỏi 100%: các bước không chờ nó, và khi Rollout xong
    thì run nền bị dừng và thành Successful dù đã đo gì (kể cả chưa đo được lần nào vì mọi truy vấn quá hạn). Bước gate chỉ
    xong khi AnalysisRun của nó Successful (Argo Rollouts v1.10.1, `rollout/analysis.go`), nên canary chỉ lên 100% sau một lần
    đo hợp lệ mỗi metric ở 50%. Run nền hay gate `Failed`/`Error` → abort; Inconclusive → dừng chờ người, không promote.
    `progressDeadline` không chạy trong bước analysis (Rollouts tính nó là "indefinite"); gate tự xong trong 50 s (bên dưới).
    **Sửa 2026-10-19:** trước chỉ có phân tích nền, bước cuối là pause.
- **Envoy Gateway gộp backend:** với hai backendRef có trọng số, Envoy Gateway v1.9.2 mặc định tạo **một** cluster Envoy cho cả
  rule (`httproute/<ns>/<route>/rule/<i>`), stable và canary chỉ là hai locality có `load_balancing_weight`
  (`internal/xds/translator/translator.go`, `route.go` `buildXdsRouteAction`, `cluster.go` `buildWeightedLocalities`; fixture
  `http-route-weighted-backend`), nên metric cluster của Envoy **không** tách được canary. Khi mỗi backendRef có `filters`
  khác rỗng, `HasFiltersInSettings()` buộc mỗi backend một cluster và route dùng `weighted_clusters` (fixture
  `...-with-filters`), tên **`httproute/svp/api/rule/0/backend/<j>`** với `<j>` là vị trí trong `backendRefs`. Quyết định: mỗi
  backendRef của HTTPRoute `api` có một filter `RequestHeaderModifier` đặt header `x-svp-backend: stable` / `canary` (gateway bỏ
  qua header này); canary là **`httproute/svp/api/rule/0/backend/1`**. Điều kiện: không đặt `telemetry.metrics.clusterStatName`
  của `EnvoyProxy` (đặt thì các cluster của rule chung một `alt_stat_name`), giữ `mergeBackends` tắt (mặc định). backendRef
  trọng số 0 bị bỏ, nên series của canary chỉ có khi trọng số > 0. Plugin chỉ đổi trọng số nên filter được giữ. Đã kiểm trên
  cluster (2026-10-18): canary là `httproute/svp/api/rule/0/backend/1`, stable `backend/0` cả khi trọng số canary là 0,
  series canary có khi trọng số 25, target Envoy `up` trong Prometheus.
- **Metric** (proxy Envoy cổng **19001**, đường dẫn `/stats/prometheus`, `bootstrap.go` của Envoy Gateway; tên theo tag
  extraction của Envoy v1.39.1, `well_known_names.cc`, `cluster_stats.rst`): `envoy_cluster_upstream_rq_xx` (label
  `envoy_response_code_class`, `envoy_cluster_name`), `envoy_cluster_upstream_rq_total`,
  `envoy_cluster_upstream_rq_time_bucket` (đơn vị ms). Prometheus scrape bằng `PodMonitor` `envoy-svp` (chart
  `svp-observability`; nằm ở `svp-obs` vì operator chỉ watch namespace đó, `namespaceSelector` chọn pod Envoy ở
  `envoy-gateway-system`, mục 11), `metricRelabelings` chỉ giữ ba họ metric trên với
  `envoy_cluster_name=~"httproute/svp/api/.*"`.
- **AnalysisTemplate `gateway-canary`** (nền), hai metric, `interval: 30s`, `initialDelay: 60s` (lần đo đầu đã có đủ một cửa
  sổ traffic ở 25%; không có thì lần đo ngay khi bắt đầu luôn thiếu mẫu), `failureLimit: 1` (cho qua một lần đo hỏng lẻ, lần
  hỏng thứ hai thì Failed → abort); **`gateway-canary-gate`** cùng hai truy vấn, `count: 1`, `failureLimit: 0` (một lần đo,
  không có lần hỏng lẻ nào để bỏ qua). Cả hai: `inconclusiveLimit` mặc định 0, **`consecutiveErrorLimit: 2`**, truy vấn
  **`timeout: 10`** (giây; mặc định của provider 30), provider **`prometheus.address: http://kps-prometheus.svp-obs:9090`**
  (controller Rollouts ở `argo-rollouts` chạy truy vấn; policy ingress ở bảng luồng mục 3). Với `C` là cluster canary và cửa
  sổ `[1m]`:

  ```promql
  # canary-5xx-ratio: 5xx / phản hồi không phải 4xx; -1 khi chưa đủ 30 phản hồi không phải 4xx
  (
    (sum(increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name="C",envoy_response_code_class="5"}[1m])) or on() vector(0))
    / sum(increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name="C",envoy_response_code_class!="4"}[1m]))
  )
  and on() (sum(increase(envoy_cluster_upstream_rq_xx{envoy_cluster_name="C",envoy_response_code_class!="4"}[1m])) >= 30)
  or on() vector(-1)
  ```

  - `successCondition: result[0] >= 0 && result[0] < 0.01` (SLO availability 99,9% nới thành 1% cho cỡ mẫu nhỏ),
    `failureCondition: result[0] >= 0.01`; −1 thì không điều kiện nào đúng → **Inconclusive**.
  - `canary-p99-ms`:
    `histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name="C"}[1m])))`
    với cùng điều kiện ≥ 30 và `or on() vector(-1)`; success `>= 0 && < 150` (SLO feed p99 150 ms), failure `>= 150`.
  - **Vì sao ≥ 30:** ~10 req/s diễn tập ở trọng số 25% cho ~150 phản hồi/phút tới canary; 30 là 20% số đó, traffic bình thường
    luôn đạt, còn traffic phần lớn là 401/429 (token hết hạn, vượt rate limit) thì không đạt và phân tích **không pass**: bản
    lỗi không được promote nhờ traffic hỏng. Mẫu số bỏ 4xx để 4xx không pha loãng tỉ lệ 5xx.
  - Inconclusive làm Rollout dừng (paused) chờ người, không promote; `progressDeadline` không tính lúc paused. Đường dev coi
    đó là thất bại (bên dưới).
  - Bucket mặc định của Envoy quanh ngưỡng là 100 và 250 ms (`HistogramSettingsImpl::defaultBuckets`,
    `source/common/stats/histogram_impl.cc` của Envoy): p99 < 150 ms được nội suy trong bucket đó, chỉ là ước lượng thô; metric
    5xx là tiêu chí chính.
  - **Prometheus không trả lời:** truy vấn lỗi hay quá hạn là một lần đo `Error`, thử lại 10 s sau khi nó kết thúc; Error
    không tính là đạt hay hỏng, lần Error thứ ba liên tiếp làm cả run `Error` → abort (Argo Rollouts v1.10.1,
    `analysis/analysis.go`). Dòng thời gian tính từ lúc mỗi run bắt đầu (suy từ mã nguồn, chưa đo): run nền khi Prometheus
    treo Error ở 70, 90, 110 → abort ~110 s, trước khi hai pause hết (ít nhất 120 s cộng thời gian pod canary khởi động);
    Prometheus từ chối ngay → abort ~80 s; gate khi treo Error ở 10, 30, 50 → abort ~50 s, không promote; bản tốt: gate đo
    ngay và promote chậm hơn hai pause chừng một lần truy vấn. Lỗi Prometheus thoáng qua có thể abort một bản tốt; chạy lại
    canary là xong (lối ra bên dưới): canary không rõ sức khoẻ thì không giữ 50% traffic. **Sửa 2026-10-19:** trước là
    mặc định (timeout 30 s, 4 lỗi liên tiếp): lỗi đầu ~90 s, lỗi thứ hai ~130 s, các bước đã hết trước và canary lên 100% với
    run nền Successful không một lần đo.
- **Argo CD:** Application của gateway `ignoreDifferences` hai chỗ Rollouts ghi: trọng số backendRef của HTTPRoute `api`
  (`jqPathExpressions: [".spec.rules[].backendRefs[].weight"]`) và hash trong selector của Service ở `svp`
  (`.spec.selector["rollouts-pod-template-hash"]`), cùng `syncOptions: [RespectIgnoreDifferences=true]`. Bỏ qua thì selfHeal
  không trả trọng số giữa lúc canary; `RespectIgnoreDifferences` giữ giá trị sống cả khi một sync áp các object này: Argo CD
  áp server-side với `--force-conflicts`, nên không có nó thì mỗi sync của Application (tag phát hành mới) xoá hash khỏi hai
  selector (request tới cả pod stable lẫn canary tới khi controller đặt lại) và trả trọng số 100/0 giữa lúc canary.
  - **Cái giá** (đọc `normalizeTargetResources`, `controller/sync.go@v3.5.5`): giá trị sống vào manifest được áp qua JSON
    merge patch, patch này thay cả mảng, nên **cả `spec.rules` đang chạy** được áp, không chỉ trọng số. Đổi rule trong git
    (match, filter, timeout) không tới cluster khi route còn: lúc không có canary, xoá route (`kubectl --context k3d-svp -n
    svp delete httproute api`), selfHeal dựng lại từ git trong vài giây, API không tới được trong lúc đó (ghi ở comment
    `deploy/argocd/apps/templates/applications.yaml`).
  - **Giữ `RespectIgnoreDifferences`:** sync giữa canary không được trả trọng số về 100/0, còn đổi rule của route hiếm hơn
    nhiều so với phát hành. Đường GitOps với Rollout chưa chạy: kiểm ở bước diễn tập GitOps.
  - **Sửa 2026-10-19:** trước chỉ bỏ qua trọng số và ghi "có thể chép cả `spec.rules`", nay đã đọc mã nguồn và thêm hash của
    selector.
- **"Bản lỗi" cho diễn tập:** gateway với `FEED_SERVICE_ADDR` trỏ Service không tồn tại: pod vẫn Ready (probe `/healthz`) nhưng
  feed trả 5xx, đúng loại lỗi cấu hình hay gặp. Traffic nền ~10 req/s vào `GET /feed/explore`, `GET /feed/following` chia cho
  **≥ 4 user** diễn tập (lớp `read` 600/phút, burst 200 mỗi user; mỗi user ≤ 3 req/s), mỗi user đăng nhập lại trước khi token
  hết hạn (1 giờ, JWT-3) và ngay khi gặp 401, để traffic sống qua thời gian người học push.
  - **User lệch pha:** vòng lặp của các user bắt đầu cách nhau `interval / số user` (100 ms với 4 user × 2,5 req/s), không gửi
    đồng loạt. Khoá nhịp thì một lời gọi chậm sau gateway (cache miss trang explore) làm bốn phản hồi chậm cùng lúc và tính bốn
    lần vào p99 của canary. Đo p99 của stable cửa sổ 1 phút: khoá nhịp 5/26 cửa sổ > 150 ms (max 482 ms) và một canary tốt
    bị abort vì p99 496/480 ms dù 0 5xx; lệch pha 32 cửa sổ, trung vị 41 ms, max 84 ms; cửa sổ 5 phút 25–93 ms. Ngưỡng 150 ms
    giữ nguyên. **Sửa 2026-10-19.**
- **Đường dev:** khi `k8s-up` đổi pod template của gateway, `install.sh` tự chạy traffic trong lúc canary và chờ Rollout
  `Healthy` có hạn (Helm `--wait` không hiểu `Rollout`), abort hay inconclusive thì `k8s-up` thất bại nêu AnalysisRun; không đổi
  gì thì không có revision mới (tag theo image ID, mục 6).
  - **Khi nào chạy traffic:** trước upgrade, `install.sh` so document `Rollout` mà upgrade sắp áp (`helm template` cùng values
    và tag; chart không đọc gì từ cluster) với document đó trong revision hiện tại của release (`helm get manifest`). Giống
    nhau và Rollout `Healthy` thì không có canary, không chạy traffic (mỗi lần chạy đăng ký user mới và xoá khoá rate limit
    đăng ký ở Valkey db 10, nên help của `k8s-up` ghi "LOCAL LAB ONLY"); khác ở bất cứ chỗ nào, hay Rollout đang canary,
    paused, aborted, thì chạy. **Sửa 2026-10-19:** trước chạy traffic ở mọi `k8s-up` khi gateway đã là Rollout.
  - **Lối ra khi `k8s-up` thất bại** (in trước dòng `FAIL`; không cài plugin `kubectl-argo-rollouts`, mục 1, nên abort và
    retry là patch subresource `status` như plugin làm): canary chưa abort (inconclusive, quá 900 s) vẫn giữ trọng số, nên
    abort trước: `kubectl --context k3d-svp -n svp patch rollout gateway --subresource status --type merge -p
    '{"status":{"abort":true}}'` (mọi request về pod stable). Rồi sửa nguyên nhân và chạy lại `k8s-up` (template mới là canary
    mới), hoặc chạy lại canary của chính revision đó khi phân tích hỏng vì nhiễu: `make k8s-traffic-start`, patch
    `'{"status":{"abort":false}}'`, `make k8s-up`, `make k8s-traffic-stop`. Đã kiểm dưới traffic diễn tập: abort giữa bước 25%
    → `Degraded`, route 100/0 sau 3 s; retry → canary chạy lại từ 25% với AnalysisRun mới (`<tên cũ>.1`), promote sau ~2 phút.
    **Sửa 2026-10-19.**

## 14. Compose vẫn là đường dev chính

### Các lựa chọn

| Lựa chọn | Được | Mất |
| --- | --- | --- |
| **Compose là đường dev chính, k3d là môi trường học vận hành** | Khởi động ~10–20 s; mọi diễn tập giai đoạn 2–3 giữ nguyên | Hai môi trường phải giữ khớp cấu hình service |
| Chuyển hẳn sang k3d | Một môi trường | Dựng chậm (nhiều phút), RAM gấp ~2,5 lần; phải port mọi diễn tập |

### Quyết định

Compose giữ nguyên vai trò và mọi target cũ giữ nguyên hành vi (không SASL, Postgres/Redis native, `make up`/`smoke`/diễn
tập). k3d dùng để học vận hành Kubernetes; diễn tập giai đoạn 2–3 **không** port sang k3d, ngoài `make k8s-smoke` (chạy
`deploy/compose/smoke.sh` qua `https://api.svp.localhost:8443` với `.k8s/ca.crt`).

## Kiểm chứng (đã kiểm ngày 2026-10-18)

Không dựng cluster, không chạy Docker. Chart tải vào thư mục tạm ngoài repo với `HELM_CACHE_HOME`, `HELM_CONFIG_HOME`,
`HELM_DATA_HOME` trỏ vào đó (không đụng cấu hình Helm của máy); mã nguồn đọc ở đúng tag ghim.

| Kiểm gì | Lệnh / cách kiểm | Kết quả |
| --- | --- | --- |
| Postgres native | `psql -h 127.0.0.1 -p 5432 -U postgres -At -c 'show server_version'` | 15.18 |
| k3d build và ldflags | `GOBIN=<tạm> go install -ldflags='-X .../version.Version=v5.9.0 -X .../version.K3sVersion=...' github.com/k3d-io/k3d/v5@v5.9.0`; chạy `k3d version`; đọc `go.mod`, `version/version.go`, `Makefile` ở v5.9.0; xoá binary | Build ~37 s bằng Go 1.27.2; in đúng hai version; không `-X` thì `v5-dev` và k3s v1.32.5 |
| Cấu hình k3d | `ValidateSchemaFile` của k3d v5.9.0 trên cấu hình mẫu; đọc `schema.json`, `types.go`, `transform.go`, `defaults.go`, `cluster.go`, `registry.go` | Mục 2, 6 (`subnet`, `kubeAPI.hostIP`, `registries.use`, `extraArgs` + `nodeFilters`) |
| Version và digest image | Registry HTTP API (token ẩn danh, Accept OCI index + Docker manifest list, đọc `Docker-Content-Digest`), đọc config blob arm64 để lấy `User` | Bảng mục 1; digest compose của Redpanda, MinIO, GlitchTip, Collector khớp registry; user: Redpanda `redpanda`, MinIO `65532`, GlitchTip `app:app`, Collector `10001:10001`, Valkey rỗng (root, entrypoint hạ quyền) |
| k3s | Release GitHub, kênh `update.k3s.io`, release notes v1.36.5/v1.37.1, `go.mod` và `pkg/cloudprovider/servicelb.go`, `pkg/agent/netpol` ở tag | Mục 1–3, 9 |
| Hỗ trợ Kubernetes | Trang hỗ trợ của từng dự án (bảng mục 1) | Không minor nào vừa trong skew `kubectl` 1.37 vừa trong e2e của Argo Rollouts 1.10.1; chọn 1.36 |
| Chart | `helm search repo -l`, `helm show chart/values --version`, `helm pull --untar` cho mọi chart ở mục 1 | Version, appVersion, tên giá trị ở mục 1, 3, 4, 11–13 |
| PSA | `helm template` từng chart với values dự định, script so mọi pod spec với tiêu chuẩn "restricted" | Bảng mục 3 |
| Redpanda | `helm template` với `image.tag: v26.2.4@sha256:...` (lỗi `image.tag must start with a 'v' and be a valid semver`), với image ghi đè theo tên container (đúng chuỗi digest trong StatefulSet), với `listeners.kafka.port: 9092`; đọc `server.cc`, `authorizer.cc`, `request_auth.cc`, `admin/server.cc` ở v26.2.2, mã nguồn rpk | Mục 4, 5 |
| Redpanda Admin API bắt buộc xác thực | `helm template` chart 26.2.4 với `admin_api_require_auth: true` (có trong `.bootstrap.json.in`), với `postStart` ghi đè (thay được, `preStop` giữ), với `external.default.enabled: false` (chỉ còn listener `internal`); đọc `common.sh`, `wrapLifecycleHook` của chart; `src/v/redpanda/admin/server.cc`, `src/v/security/request_auth.cc`, `src/go/rpk/pkg/config/params.go` ở v26.2.2; `operator/cmd/sidecar/sidecar.go`, `operator/internal/probes/broker.go`, `operator/pkg/client/rpk.go` ở `operator/v26.2.4` | Mục 4, 5 |
| Tên Service kube-prometheus-stack | `helm template` chart 92.10.1 với `fullnameOverride: kps` và hai `fullnameOverride` của subchart | `kps-prometheus`, `kps-alertmanager`, `kps-grafana`, `kps-kube-state-metrics`, `kps-operator`; 6 ServiceMonitor (bảng luồng mục 3) |
| Namespace và kind cluster-scope cho AppProject | `helm template --include-crds` 11 chart upstream ở bảng mục 1 với values dự định (cert-manager có `global.leaderElection.namespace: cert-manager`), liệt kê namespace của mọi resource và kind không namespace | Chỉ RoleBinding `keda-operator-auth-reader` ở `kube-system`; không đổi namespace thì cert-manager thêm 2 Role + 2 RoleBinding ở `kube-system`; kind cluster-scope như mục 12 |
| Argo CD poll | `helm template` chart 10.10.5 với `timeout.reconciliation: 60s`, `timeout.reconciliation.jitter: 0s`; đọc `controller/appcontroller.go`, `cmd/argocd-application-controller/commands/argocd_application_controller.go`, `reposerver/cache/cache.go`, `util/git/client.go`, `docs/user-guide/best_practices.md` ở v3.5.5 | Mục 10, 12 |
| Luồng của CloudNativePG, kube-router | `docs/src/security.md`, `pkg/utils/labels_annotations.go` ở v1.30.1; `pkg/controllers/netpol/policy.go` của `k3s-io/kube-router` v2.6.3-k3s1 | Operator → instance 8000; nhãn `cnpg.io/cluster`; `ipBlock.except` thành `nomatch` của ipset |
| Envoy Gateway | Đọc `translator.go`, `route.go`, `cluster.go`, `helpers.go`, `listener.go`, `bootstrap.go` và fixture ở v1.9.2; `helm template` | Mục 9, 13 |
| Bucket histogram Envoy | `source/common/stats/histogram_impl.cc` ở v1.40.0 (bản mới nhất; danh sách không đổi nhiều năm) | 0.5, 1, 5, 10, 25, 50, 100, 250, 500, 1000, ... ms |
| Symlink trong Helm | Chart tạm ở `/tmp` có symlink tệp và thư mục ra ngoài chart; `helm template`, `helm package`, `tar tzf`; đọc `internal/sympath/walk.go` của Helm v4.2.1 | Mục 7 |
| Argo CD | `hack/tool-versions.sh` (Helm 4.2.1), `reposerver/repository/repository.go`, `docs/operator-manual/health.md`, `docs/user-guide/helm.md` ở v3.5.5 | Mục 7, 10, 12 |
| CloudNativePG, KEDA, cert-manager | Tài liệu bản ghim, mã nguồn ở tag, `helm template` | Mục 3, 4, 10 |
| Plugin Gateway API | Tải hai asset v0.17.0 vào thư mục tạm, `shasum -a 256`, so digest asset GitHub | Bảng mục 13 |
| GlitchTip uid | `Dockerfile` ở tag `v6.2.6` của `gitlab.com/glitchtip/glitchtip-backend` | `useradd -u 5000 app` |

Chưa kiểm (cần cluster, ghi ở từng mục): PSA thật của admission controller; đường DNAT tới API server và rule `allow-kube-api`;
địa chỉ client Envoy thấy qua serverlb/svclb; ACL của broker v26.2.4 (mã nguồn đọc ở v26.2.2, bản v26.2.4 chưa có tag công
khai); hook Helm trong PreSync của Argo CD trên cluster sạch; phần GitOps của canary (`ignoreDifferences` và
`RespectIgnoreDifferences` của Application gateway, bỏ qua hash selector, health của Rollout trong Argo CD);
`readOnlyRootFilesystem` của Pyroscope, Collector, GlitchTip, MinIO lúc chạy; `runAsGroup` của GlitchTip; tên label k3d dùng
cho kiểm loại trừ compose/k3d; Redpanda chạy với Admin API bắt buộc xác thực và `postStart` rỗng (sidecar Ready,
`/public_metrics` 200 không mật khẩu, `/v1/node_config` bị từ chối); từng dòng của bảng luồng mục 3 và egress Telegram;
Application `keda` sync được với `kube-system` trong `destinations`; độ trễ push → Argo CD thấy commit; RAM thật.
**Sửa 2026-10-19:** bỏ plugin v0.17.0 với Envoy Gateway v1.9.2 đầu-cuối và tên cluster canary trong stats của Envoy (đã kiểm,
mục 13), thêm phần GitOps của canary.

**Sửa 2026-10-19**, vòng sửa sau diễn tập threat model, chỉ kiểm tĩnh (`helm lint`/`helm template`, `bash -n`, hàm của
script chạy với `kubectl`/`rpk`/`curl` giả, mã nguồn ở tag ghim, SQL trên database `svp_*_test`); chưa kiểm trên cluster, kiểm
ở lượt kiểm cuối dựng lại cluster từ đầu:

- PSA (mục 3): admission thật ở năm namespace công cụ (pod của chart Running, không cảnh báo PodSecurity, pod privileged
  `--dry-run=server` bị từ chối, proxy Envoy tạo lại được); `install.sh` trên cluster cũ (thêm nhãn `cert-manager`,
  `envoy-gateway-system`, nhận `cnpg-system`, `keda`); GitOps: `managedNamespaceMetadata` gắn nhãn trước pod đầu, symlink
  `svp-cluster-values.yaml` qua repo-server, namespace dự án tạo sẵn từ git để wave 0 Synced. Mức mặc định toàn cluster:
  cluster mới (cả đường GitOps) dựng xong mọi wave, không event `FailedCreate` nào vì PodSecurity; pod privileged
  `--dry-run=server` bị từ chối ở `default` và ở một namespace mới không nhãn; `kube-system` vẫn chạy `svclb-*`, coredns,
  metrics-server, helper pod của local-path (PVC của Redpanda, MinIO, CloudNativePG `Bound`); `ensure_cluster` dừng trên
  cluster tạo trước khi có cấu hình này, và với `docker inspect` thật đọc đúng nguồn bind của node (cluster dừng rồi
  `make k8s-up` lại thì khởi động bình thường). **Sửa 2026-10-19.**
- Postgres (mục 4): Job `pg-bootstrap` chờ hai role rồi GRANT/REVOKE trên `svp-pg` (cluster mới và cũ); `cnpg_collector_up`
  = 1, metric của query mặc định vẫn có, `cnpg_errors_total` không tăng; role `svp_*_app` bị từ chối ở `postgres`, `app`,
  `template1`, mọi service, migrate, GlitchTip vẫn chạy. pg_rewind và slot của `streaming_replica` chỉ có khi `instances` >
  1: lab không kiểm được.
- Secret (mục 8): với lỗi thật của rpk v26.2.4 (Admin API từ chối kết nối, quá hạn), shell trong `redpanda-0` thoát mã 5
  và `secrets.sh` in thông báo của mã đó (Admin API không trả lời, chạy lại `make k8s-secrets`), thoát 1, không Secret nào
  đổi; `make k8s-glitchtip-init` qua `manage.py shell -c` trên Django thật, chạy lại thì Secret không đổi.
- Biên vào (mục 9): kết nối IPv4-mapped thật (socket dual-stack) vẫn khớp `TRUSTED_PROXY_CIDRS` dải pod thường.
- Valkey (mục 10): Ready/Live với `tcpSocket`, hết throttle lúc nghỉ, RL-1 không còn rơi sang bộ đếm dự phòng.
- Observability (mục 11): pod Alertmanager không có `/var/run/secrets/kubernetes.io/serviceaccount` mà reload cấu hình vẫn
  chạy; Collector dưới tải: heap so với 140/144 MiB, `otelcol_receiver_refused_*`, `otelcol_exporter_queue_size` theo byte.
- GitOps và RBAC (mục 12): AppProject `default` rỗng sau restart `argocd-server`, Application `project: default` bị từ chối;
  health Alertmanager chặn wave; cert-manager cấp `cnpg-webhook`, cainjector chèn CA vào hai webhook CNPG, operator phục vụ
  bằng cert đó không ký lại, log không `forbidden`, `svp-pg` (pod, Secret, Role) tạo qua webhook không lỗi x509;
  Envoy Gateway với `watch.namespaces` nhận HTTPRoute `api`, `s3`, đọc `svp-wildcard-tls`, Gateway Programmed; mục RBAC của
  `make drill-k8s-threats` với `can-i` và SelfSubjectRulesReview thật; `measure-gitops`: cửa sổ `deployStartedAt` với lịch sử
  Argo CD thật, bước canary đọc từ Rollout sống, GAP 180 s của gateway.
- Canary (mục 13): Prometheus bị chặn hay treo thì run nền abort ~110 s hoặc gate ~50 s, không lên 100%; bản tốt promote
  qua gate (`make drill-k8s-canary`).
- Diễn tập: `make drill-k8s-threats` hai lượt liên tiếp (RL-1 với burst rải nhịp và số lượt bị bỏ vì fallback, baseline
  fallback theo từng pod, `PSA-platform`); `make drill-k8s-pdb` có pod thay rơi về node còn lại.

**Sửa 2026-10-19, lượt kiểm cuối** trên cluster dựng lại từ đầu (`make k8s-down && make k8s-up`, hai lượt cách nhau
hơn 2 giờ, cùng code trừ script diễn tập threat model), chỉ đường dev; số đo ở
[plan](../../plans/261004-devops-sa-roadmap/plan.md), Tiến độ giai đoạn 4. Trạng thái của các dòng "Chưa kiểm" ở trên:

- **Đã kiểm, đúng như các mục trên:**
  - PSA (mục 2, 3): cluster mới không có event PodSecurity hay `FailedCreate`; pod privileged với hostPath `/`
    (`--dry-run=server`) bị từ chối (`restricted:v1.36`) ở 11 namespace: bốn namespace công cụ của đường dev
    (`cert-manager`, `envoy-gateway-system`, `cnpg-system`, `keda`), `argo-rollouts`, bốn namespace của project, `default`
    và một namespace mới không nhãn; `argocd` chỉ có ở đường GitOps nên chưa thử (mục "Còn chưa kiểm"). `kube-system`
    nhận, vẫn chạy `svclb-*`, coredns, metrics-server và helper pod của local-path (7 PVC `Bound`). Cluster dừng rồi
    `make k8s-up` thì khởi động lại bình thường (`docker inspect` thật). Mục `PSA-platform` của `make drill-k8s-threats`
    PASS.
  - API server (mục 3): pod có nhãn `svp-kube-api: allow` chạy đúng việc (instance CloudNativePG, sidecar Redpanda,
    Prometheus, Grafana); media-worker không tới `kubernetes.default:443`, pod thử không có policy thì tới (đối chứng). Chưa
    tách trong hai rule của `allow-kube-api` rule nào là rule khớp.
  - Địa chỉ client Envoy thấy (mục 9): địa chỉ mạng pod của node nhận kết nối (`10.42.0.1` ở lượt đầu, `10.42.1.1` ở lượt
    sau); RL-1 đếm theo địa chỉ đó đọc từ `X-Forwarded-For`, tức kết nối từ Envoy khớp `TRUSTED_PROXY_CIDRS`.
  - Redpanda (mục 4, 5): ACL của broker v26.2.4 như bảng mục 5 (mục IN-4/FF-6 của diễn tập: topic khác
    `TOPIC_AUTHORIZATION_FAILED`, group khác `GROUP_AUTHORIZATION_FAILED`, `svp-keda` produce idempotent
    `CLUSTER_AUTHORIZATION_FAILED`); Admin API không thông tin đăng nhập trả 403 ở `/v1/node_config`, `/v1/cluster_config`,
    `/v1/security/users`; sidecar Ready; Prometheus có `up{job="redpanda"}` = 1 từ `/public_metrics` không mật khẩu.
  - `readOnlyRootFilesystem` lúc chạy: Pyroscope và Collector (uid/gid 10001), GlitchTip (5000/5000, `runAsGroup` đúng,
    ghi vào `/` bị từ chối), MinIO (65532) đều Running.
  - Loại trừ compose/k3d (mục 2): `make k8s-up` bị từ chối khi compose chạy, `make up` bị từ chối khi cluster chạy.
  - Bảng luồng mục 3: luồng bị chặn và đối chứng của diễn tập (IN-2/IN-4, FF-5) PASS. Egress Telegram đã gửi thật một
    thông báo ở bước cảnh báo; lượt kiểm cuối chỉ kiểm receiver `severity=page` → Telegram trong cấu hình.
  - Postgres (mục 4): Job `pg-bootstrap` tạo 5 database và cặp role, REVOKE CONNECT trên `postgres`, `app`, `template1`;
    `svp_glitchtip_app` bị từ chối CONNECT ở `postgres`, `app`, `template1`, `svp_user`; `cnpg_collector_up` = 1,
    `cnpg_collector_last_collection_error` và `cnpg_last_error` = 0 ở hai mẫu cách 77 phút; mọi service, Job migrate và
    GlitchTip chạy. Lúc dựng mới, 3–4 service và 4 Job migrate restart một lần ("connection refused" tới `svp-pg-rw` những
    giây đầu) rồi chạy bình thường.
  - Secret (mục 8): rpk v26.2.4 với Admin API từ chối mật khẩu thì `secrets.sh` thử mật khẩu kế; Admin API không trả lời
    (kết nối bị từ chối) thì shell trong `redpanda-0` thoát 5. `make k8s-glitchtip-init` chạy lại trên Django thật:
    `resourceVersion` của Secret `svp/sentry`, `svp-obs/glitchtip-api` và pod không đổi, một token `svp-drill`, một key.
  - Valkey (mục 10): Ready/Live bằng `tcpSocket`, limit CPU 1; RL-1 không rơi sang bộ đếm dự phòng ở hai lượt liên tiếp.
  - Observability (mục 11): pod Alertmanager không có thư mục token ServiceAccount, config-reloader vẫn nạp cấu hình.
    Collector trong ba cửa sổ diễn tập KEDA (cả lúc node bão hoà CPU): heap tối đa 91 MiB (dưới GOMEMLIMIT 140 MiB),
    `otelcol_receiver_refused_*` 0, hàng đợi exporter tối đa 233 920 byte của 4 MiB; mẫu Prometheus cách 15 s, xa nhất
    18,8 s. Grafana: 13/13 nhóm rule
    của project, 41/43 panel có dữ liệu (panel service graph lỗi `unsupported query type: 'serviceMap'` như lúc dựng
    observability, panel cảnh báo SLO trống khi không cảnh báo nào bật).
  - RBAC (mục 12): cert-manager cấp `cnpg-webhook`, cainjector chèn CA vào 4 webhook mutating và 5 validating của
    CloudNativePG (`caBundle` = `ca.crt` của chứng chỉ), log operator 0 dòng forbidden/x509/error, `svp-pg` healthy; Envoy
    Gateway nhận HTTPRoute `api`, `s3`, Gateway `Programmed`, 0 dòng forbidden; mục RBAC của diễn tập (SelfSubjectRulesReview
    và `can-i` thật, 814 lần kiểm; đối chứng: controller Rollouts list được pod của `svp`) PASS hai lượt liên tiếp.
  - Canary (mục 13): `make drill-k8s-canary` (bản tốt promote sau 126 s, run nền và gate `Successful`; bản lỗi abort 87 s
    sau khi canary nhận traffic, stable 0 5xx). Controller Rollouts không tới được Prometheus (NetworkPolicy diễn tập chỉ
    mở DNS, API server và 443 ra ngoài cluster cho pod controller, rồi restart controller): run nền `Error` sau 3 lần
    `connection refused`, Rollout abort 82 s sau bản mới, trọng số tối đa 50%, ReplicaSet và pod stable không đổi; gỡ
    policy, restart lại thì bản tốt promote qua gate. Ba lần chặn trước đó không restart controller đều promote: rule
    NetworkPolicy của kube-router chỉ chặn kết nối mới, controller giữ kết nối keep-alive tới Prometheus mở từ trước.
    Chưa dựng ca Prometheus treo (không trả lời trong 10 s).
  - Diễn tập: `make drill-k8s-threats` hai lượt liên tiếp 10/10 PASS; `make drill-k8s-pdb` PASS (cordon hai node, eviction
    đầu 201, pod thay `Pending`, eviction thứ hai 429, uncordon thì gateway về hai node).
- **Sai trong danh sách trên:** `svp-pg` không có PodMonitor (`enablePodMonitor` mặc định `false`), nên Prometheus không
  thu `cnpg_*`; lượt kiểm đọc thẳng endpoint metric của instance. Dòng mục 12 ở trên đã bỏ chữ PodMonitor.
- **Đạt theo quyết định của người học (sửa 2026-10-20):**
  - RAM thật (mục 2, cách đo và điều kiện (a), (b) ở đó): nghỉ 5,87 GiB ở lượt đầu (dưới ngưỡng); 6,69 và 6,78 GiB ở lượt
    sau, trên ngưỡng 6,5 GiB nhưng đủ (a) và (b): đỉnh có đủ 3 worker transcode 7,95 GiB (lượt đầu, mẫu cao nhất 8,25 GiB,
    dưới 8,7), tổng pod 2,36 và 2,44 GiB, MEM USAGE trừ `active_file` 4,68 và 4,77 GiB (hai node cộng lại: `anon` 3,84
    GiB, `active_file` 2,01 GiB, `kernel` 0,35 GiB; VM Docker còn `MemAvailable` 4,5 GiB, swap không dùng). Không áp bước
    cắt nào. Sau mọi diễn tập 6,24 và 6,30 GiB.
    Hai chỗ số đỉnh lệch cách đo mục 2, ghi lại chứ không gọi là đo đúng cách:
    - Cửa sổ đỉnh của lượt đầu (13:19:44–13:22:35 UTC) là 6 mẫu liền nhưng cách nhau 24–45 s, trải 171 s, không phải 10 s:
      máy chạy pin với Low Power Mode, CPU bão hoà, `docker stats` và `kubectl exec` (đếm job transcode của từng worker)
      mất tới 45 s mỗi vòng nên mẫu kế tiếp chỉ lấy được khi vòng trước xong; script lấy mẫu còn ghi giờ sau các lệnh
      `kubectl`, nên giờ ghi trễ tới 45 s so với lúc `docker stats`. Cả 9 mẫu đủ 3 worker (13:19:13–13:22:35) nằm trong
      7 814–8 445 MiB, đều dưới 8,7 GiB; cửa sổ nào trong đó cũng cho trung vị 7,69–7,95 GiB. Script lấy mẫu đã sửa: ghi
      giờ ngay lúc `docker stats` và khoảng cách tới mẫu trước; script tìm cửa sổ in khoảng cách và báo cửa sổ lệch nhịp.
    - Đỉnh đủ 3 worker của lượt sau **chưa đo**: không có cửa sổ 6 mẫu nào đủ 3 worker cùng transcode (worker đầu làm xong
      partition của nó trước khi rebalance xong), cửa sổ 2 worker 7,80 GiB, mẫu cao nhất 8,09 GiB. Cộng mức tăng của lượt
      đầu (7,95 − 5,87 = 2,08 GiB) vào nghỉ của lượt sau (6,69–6,78 GiB) thì được 8,77–8,86 GiB, trên 8,7, nếu page cache
      không bị thu lại khi tải. Vẫn nhận vì phần vượt lúc nghỉ là `active_file` (kernel thu lại khi thiếu bộ nhớ: sau diễn
      tập KEDA của lượt sau còn 1,3 GiB so với 2,01 GiB lúc nghỉ) và cửa sổ 2 worker của lượt sau không vượt 8,09 GiB; đo
      lại đỉnh 3 worker đúng cách mục 2 nằm ở "Còn chưa kiểm".
  - KEDA (mục 10): `make drill-k8s-keda` đạt một lần khi máy cắm sạc, Low Power Mode tắt; fail hai lần khi máy chạy pin
    với Low Power Mode và một lần khi máy bị giới hạn nhiệt ngay sau lần đạt, tính là lỗi môi trường: node bão hoà CPU thì
    probe 1 s quá hạn, API server chậm (`kubectl` gặp TLS handshake timeout), controller có leader election mất lease và
    restart, Envoy trả 503; cluster tự hồi sau ~3 phút.
- **Còn chưa kiểm:** phần cần đường GitOps (hook Helm trong PreSync trên cluster sạch, phần GitOps của canary, Application
  `keda` với `kube-system`, độ trễ push → Argo CD, AppProject `default` sau restart `argocd-server`, health Alertmanager chặn
  wave, `managedNamespaceMetadata`, symlink qua repo-server, `measure-gitops`, PSA của namespace `argocd`: pod privileged
  `--dry-run=server` bị từ chối, pod Argo CD vẫn Running); `install.sh` và `ensure_cluster` trên cluster tạo trước khi có
  nhãn PSA của namespace công cụ hay cấu hình PSA mặc định (không còn cluster cũ để thử); nhánh rpk quá hạn (egress của
  broker trả "connection refused" cả cho địa chỉ không định tuyến); pg_rewind và slot `streaming_replica` (`instances` 1);
  đổi `GLITCHTIP_ADMIN_EMAIL` (phải đổi `.env`); gate `Inconclusive` thật; đỉnh RAM đủ 3 worker transcode đo đúng cách
  mục 2 (6 mẫu cách 10 s, giờ ghi lúc `docker stats`, kèm `anon`, `active_file`, `kernel` từng node) trên cluster dựng
  mới, máy cắm sạc, Low Power Mode tắt: làm ở lượt diễn tập GitOps.

## Hệ quả

- **Được:**
  - Hệ thống chạy trên Kubernetes với cùng code và cùng cấu hình bằng biến môi trường; đổi môi trường chỉ đổi values.
  - Threat model hàng giai đoạn 4 có biện pháp cụ thể: NetworkPolicy mặc định chặn hai chiều (IN-2, FF-5), PSA `restricted` và
    securityContext (FF-4), resource limit và `pod-max-pids` (FF-3), SASL + ACL và Admin API bắt buộc xác thực (IN-4, FF-6),
    Postgres SCRAM không `trust` (IN-9), proxy tin cậy một hop (RL-1), UI chỉ qua port-forward có đăng nhập (OPS-2).
  - Một file `components.json` cho cả đường dev và Argo CD; file giai đoạn 3 (rule, dashboard, bootstrap SQL, script init)
    dùng lại bằng symlink, không chép.
  - Canary có phân tích tự động và tự abort; bản lỗi không qua được nhờ traffic hỏng.
- **Phải trả:**
  - Hai đường cài (dev và GitOps) phải giữ khớp qua `components.json` và wave; thêm thành phần là sửa một file nhưng phải
    xếp đúng wave để policy có trước luồng.
  - Secret nằm ngoài GitOps: đường GitOps vẫn cần `secrets.sh` chạy từ máy có `.env`; deploy key do người học tạo và giữ;
    Argo CD poll 60 s không jitter, nhưng cache ref của repo-server làm push tới lúc thấy commit trễ thường ≤ 60 s, tệ nhất
    ~120 s.
  - AppProject `svp` được ghi vào `kube-system` (RoleBinding bắt buộc của KEDA); Alertmanager ra được mọi địa chỉ công khai
    cổng 443, không chỉ Telegram.
  - Ngoại lệ quyền còn lại của operator (mục 12): Envoy Gateway đọc Secret ở bốn namespace nó watch (gồm `svp`,
    `svp-data`); cert-manager đọc, ghi Secret và tạo pod ở mọi namespace, PSA `restricted` (nhãn hay mức mặc định của API
    server) chặn pod privileged ở mọi namespace trừ `kube-system`, nên token controller của nó bị lấy vẫn tới được root
    trên node qua `kube-system` (còn hở); Argo CD ở đường GitOps tương đương cluster-admin. **Sửa 2026-10-19.**
  - Mức PSA mặc định nằm trong file cấu hình API server, mount từ đường của repo lúc tạo cluster: sửa file có hiệu lực ở
    lần node khởi động sau, muốn áp ngay hay dời repo thì dựng lại cluster (`make k8s-down && make k8s-up`), mất dữ liệu
    trong cluster; đổi đối số hay mount trong `k3d.yaml` cũng vậy. **Sửa 2026-10-19.**
  - RAM lúc nghỉ dự kiến ~5,6 GiB so với 1,7–2,6 GiB của compose; phải tuân ngưỡng và thứ tự cắt ở mục 2.
  - Phụ thuộc chi tiết hiện thực của bên thứ ba: tên cluster theo backendRef của Envoy Gateway chỉ tách khi backendRef có
    filter; hook `postStart` của chart Redpanda không gửi được thông tin đăng nhập nên bị thay bằng lệnh rỗng, chỉ đúng khi
    có một broker; `/public_metrics` của Redpanda mở không xác thực (chỉ số đo); Argo Rollouts chạy ngoài dải e2e một minor.
  - Ở k3d, gateway thấy tối đa hai địa chỉ client (địa chỉ mạng pod của mỗi node), nên rate limit theo IP gộp mọi client
    của máy; RL-1 chỉ kiểm được phần "header giả không đổi bucket". **Sửa 2026-10-19:** trước ghi "(pod svclb)" (mục 9).
  - Image operator/backend theo tag của chart, chưa ghim digest hay ký (giai đoạn 5).
  - Release `gateway` cài client-side, khác năm service còn lại; Application gateway áp lại `spec.rules` đang chạy, nên đổi rule
    của HTTPRoute `api` trong git phải xoá route (mục 13).
- **Xem lại khi:**
  - RAM đo thật vượt ngưỡng sau mọi bước cắt, hoặc Docker Desktop đổi dung lượng.
  - Argo Rollouts phát hành bản có e2e trên 1.36 (hay 1.37): xét nâng Rollouts và k3s cùng lúc.
  - Nâng Envoy Gateway: kiểm lại cách đặt tên cluster theo backendRef và cổng/đường dẫn stats; nâng Redpanda chart: kiểm lại
    hook `postStart`/`preStop` có gửi được thông tin đăng nhập chưa (được thì bỏ lệnh rỗng), mức quyền route Admin API mà
    sidecar dùng và cách ghi đè image theo tên container.
  - Redpanda lên 3 broker trở lên: hook maintenance cần chạy thật với thông tin đăng nhập.
  - Thêm người hay repo vào GitOps: tách AppProject platform (được `kube-system`) khỏi AppProject ứng dụng.
  - Lên cloud (giai đoạn 7): database ra ngoài cluster (RDS, ElastiCache), External Secrets thay `secrets.sh`, load balancer có
    proxy protocol hay L7 để giữ địa chỉ client (RL-1 hai hop), CI ghi tag thay `k8s-release` (giai đoạn 5).
