# Đổi khoá ký JWT theo `kid`

- Quy trình làm tay, không có cảnh báo. Làm định kỳ, hay **ngay** khi nghi khoá ký bị lộ (SEC-4, JWT-10 của
  [threat model](../threat-model.md)).
- Trạng thái: viết theo mã, chưa chạy thử; diễn tập đổi khoá ở giai đoạn 7 cùng Secrets Manager
  ([ADR-0020](../adr/0020-reliability-stage6.md) §12).

## Ý nghĩa và tác động tới người dùng

Access token là JWT Ed25519, hạn **1 giờ** (`TTL` của `internal/authtoken`), header mang `kid`. user-service ký bằng
`JWT_SIGNING_KID` + `JWT_SIGNING_KEY`; gateway kiểm bằng `JWT_VERIFY_KEYS`, danh sách `kid:<public key base64>` cách nhau dấu
phẩy, nên gateway nhận được nhiều khoá cùng lúc. Refresh token là chuỗi ngẫu nhiên lưu ở user-service, không phải JWT: đổi khoá
đúng trình tự không làm mất phiên đăng nhập.

Đổi khoá đúng trình tự thì người dùng không thấy gì. Bỏ khoá cũ quá sớm (khi access token ký bằng nó chưa hết hạn, như nhánh
"Khi nghi lộ khoá" bên dưới) thì access token cũ bị 401 và người dùng web **phải đăng nhập lại**: web BFF không refresh sau 401
mà xoá phiên và thu hồi cả họ refresh token. Chỉ client gọi API thẳng, tự giữ refresh token, mới lấy được token mới bằng
`POST /auth/refresh` mà không đăng nhập lại.

Khoá nằm ở `.env` (compose đọc thẳng; k3d chép vào Secret `svp/user-service-env` cho khoá ký và `svp/gateway-env` cho khoá
công khai qua `make k8s-secrets`). Không in `.env`, không in khoá.

## Kiểm tra nhanh (5 phút)

Trước khi đổi, xác nhận trạng thái hiện tại mà không in giá trị:

```sh
# số khoá gateway đang nhận và các kid (kid không bí mật; phần sau dấu ':' không in)
grep '^JWT_VERIFY_KEYS=' .env | cut -d= -f2- | tr ',' '\n' | cut -d: -f1
grep '^JWT_SIGNING_KID=' .env
# gateway và user-service đang chạy
make ps                                                     # compose
kubectl --context k3d-svp -n svp get pods -l 'app.kubernetes.io/name in (gateway,user-service)'   # k3d
```

`kid` có dạng `<ngày UTC>-<8 hex>` (`tools/jwtkey`), nên cho biết khoá đã dùng bao lâu.

## Nguyên nhân thường gặp

Lý do đổi khoá:

1. **Định kỳ**: khoá dùng mãi thì lộ lúc nào không biết (SEC-4).
2. **Nghi lộ khoá ký**: `.env` hay Secret bị đọc, khoá lọt vào log, image hay commit (gitleaks, trivy chặn ở CI nhưng không chặn
   được mọi đường).

## Giảm thiểu

Đổi định kỳ, ba bước; mỗi bước sửa `.env` bằng trình soạn thảo rồi áp dụng.

**Bước 0. Sinh cặp khoá mới vào file tạm** (mode 600, ngoài repo, không in ra màn hình):

```sh
umask 077; jwtnew=$(mktemp); go run ./tools/jwtkey > "$jwtnew"
cut -d= -f1 "$jwtnew"           # chỉ in tên ba biến: JWT_SIGNING_KID, JWT_SIGNING_KEY, JWT_VERIFY_KEYS
```

**Bước 1. Gateway nhận cả hai khoá.** Trong `.env`, nối giá trị `JWT_VERIFY_KEYS` của file tạm vào sau giá trị cũ, cách bằng dấu
phẩy: `JWT_VERIFY_KEYS=<kid cũ>:<base64 cũ>,<kid mới>:<base64 mới>`. Áp dụng trên compose (chỉ container có biến đổi, gateway, được
tạo lại):

```sh
make up OBS=lgtm
```

k3d, trước hết biết cluster đi đường nào: có Application `svp-root` là cluster GitOps, `make k8s-up` từ chối nó
(`deploy/k8s/install.sh`), Secret đổi xong phải restart tay theo các bước ở đầu `deploy/k8s/gitops.sh`.

```sh
kubectl --context k3d-svp -n argocd get applications.argoproj.io svp-root    # NotFound: đường dev
```

Đường dev: `make k8s-up` thấy Secret `gateway-env` đổi thì restart gateway qua `spec.restartAt` (từng pod, không canary) và chờ
Rollout `Healthy`.

```sh
make k8s-secrets && make k8s-up
```

Cluster GitOps: chép Secret rồi restart gateway như vậy bằng tay. Gateway chỉ đọc biến môi trường lúc khởi động, nên tới khi
lệnh kiểm in `<giá trị $at> Healthy`, pod cũ (chỉ có khoá cũ) có thể vẫn còn phục vụ.

```sh
make k8s-secrets
at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl --context k3d-svp -n svp patch rollout gateway --type merge -p "{\"spec\":{\"restartAt\":\"$at\"}}"
# xong khi in "<giá trị $at> Healthy"; trước đó chưa sang bước 2
kubectl --context k3d-svp -n svp get rollout gateway -o jsonpath='{.status.restartedAt} {.status.phase}{"\n"}'
```

Gateway không khởi động khi `JWT_VERIFY_KEYS` sai dạng hay trùng `kid`: kiểm mọi pod gateway đã Ready với khoá mới trước khi
sang bước 2.

**Bước 2. user-service ký bằng khoá mới.** Trong `.env`, thay `JWT_SIGNING_KID` và `JWT_SIGNING_KEY` bằng hai dòng của file tạm.
Áp dụng: compose và đường dev như bước 1 (lần này user-service được tạo lại hay restart, Secret `user-service-env`); cluster
GitOps:

```sh
make k8s-secrets
kubectl --context k3d-svp -n svp rollout restart deployment/user-service
kubectl --context k3d-svp -n svp rollout status deployment/user-service --timeout=300s
```

Token mới mang `kid` mới, gateway đã nhận nó từ bước 1; token cũ còn hợp lệ tới khi hết hạn.

**Bước 3. Bỏ khoá cũ**, sau khi user-service cuối cùng còn khoá cũ đã dừng ít nhất **1 giờ** (hạn access token) cộng vài phút dư
cho lệch đồng hồ: xoá mục `<kid cũ>:<base64 cũ>,` khỏi `JWT_VERIFY_KEYS`, áp dụng như bước 1. Rồi xoá file tạm:

```sh
rm -f "$jwtnew"; ls -l .env        # .env vẫn mode 600 (-rw-------)
```

**Khi nghi lộ khoá:** làm bước 0, 1, 2 rồi bước 3 **ngay**, không chờ 1 giờ: mọi access token ký bằng khoá cũ (kể cả token giả
mạo) bị 401 từ lúc đó. Cái giá là người dùng web **phải đăng nhập lại**: BFF chỉ refresh khi access token còn dưới 30 s
(`web/server/session-access.ts`), nên phiên có token cũ còn hạn lâu hơn gửi nó đi, gateway trả 401, và web coi phiên là hỏng
(`web/server/feed.ts`, `web/server/api-proxy.ts`: `SessionAccess.end`): xoá phiên và thu hồi cả họ refresh token; trang feed
chuyển về đăng nhập. Client gọi API thẳng và tự giữ refresh token thì gọi `POST /auth/refresh` sau 401 là được token mới. Ghi
lại thời điểm để đối chiếu log.

## Khôi phục và xác nhận

```sh
grep '^JWT_VERIFY_KEYS=' .env | cut -d= -f2- | tr ',' '\n' | cut -d: -f1     # sau bước 3: chỉ còn kid mới
make smoke         # compose: đăng ký, đăng nhập (token kid mới), refresh, feed (LOCAL LAB ONLY)
make k8s-smoke     # k3d
```

Trong log gateway không có lỗi kiểm token tăng bất thường sau bước 3 (ngoài token cũ của client chưa refresh).

## Leo thang

- Gateway không khởi động sau bước 1: trả `JWT_VERIFY_KEYS` về giá trị cũ, áp dụng lại; kiểm dấu phẩy, `kid` trùng, khoảng trắng.
- Người dùng bị 401 hàng loạt sau bước 2: gateway chưa có khoá mới (bước 1 chưa áp dụng hay pod gateway cũ còn phục vụ); thêm
  khoá mới vào `JWT_VERIFY_KEYS` trước, không quay lại khoá ký cũ khi đang nghi lộ.
- Khoá bị lộ thật: mở postmortem; xét thêm thu hồi refresh token (đăng xuất mọi phiên) nếu kẻ lộ khoá có thể đã dùng nó.

## Liên kết

- [Threat model](../threat-model.md) SEC-4, JWT-10; [ADR-0020](../adr/0020-reliability-stage6.md) §12;
  [ADR-0016](../adr/0016-web-client.md) §2 (refresh token).
- Mã: `tools/jwtkey`, `internal/authtoken` (`TTL`, `ParseVerifyKeys`), `deploy/k8s/secrets.sh`.
- Diễn tập: chưa có; diễn tập đổi khoá ở giai đoạn 7.
