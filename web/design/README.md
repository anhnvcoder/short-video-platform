# Thiết kế giao diện web (bản chép từ Claude Design)

Thư mục này giữ nguyên văn thiết kế giao diện của web client, để phần code đọc thiết kế từ repo thay vì từ dịch vụ ngoài.
Nội dung ở đây **chỉ để tham khảo**: không file nào được web phục vụ, không file nào được import vào code.

## Nguồn

- Project Claude Design "SVP design system complete" (id `6fd87e46-82cd-4dd5-a26e-01578f471ec3`), chép ngày 2026-10-21.
- Trang Claude Design độc lập đóng ngày 2026-12-14, nên bản chép này là bản gốc còn lại sau ngày đó.
- File chép byte-đối-byte (kích thước khớp với danh sách file của project). Không sửa file trong thư mục này; thiết kế đổi thì
  chép lại bản mới rồi ghi ngày vào mục này.
- Không chép `uploads/` (ảnh chụp màn hình tham khảo của bên thứ ba) và `.thumbnail`.

## Danh sách file

| File | Vai trò |
| --- | --- |
| `svp-tokens.css` | Token màu, chữ, bo góc, chuyển động đặt tên theo vai trò (oklch). Tối là mặc định, sáng qua `[data-theme="light"]`. Map 1:1 sang `@theme` của Tailwind v4 |
| `SVP Design System.dc.html` | Tài liệu token và component: màu, chữ, button, like, nhãn trạng thái, text field, toast, rút gọn số, đoạn `globals.css` và props component |
| `SVP Mobile.dc.html` | Màn hình mobile 390×844, M01–M45: feed, đăng nhập/đăng ký, tải lên, video của tôi, hồ sơ, trang chia sẻ, trang lỗi, toast |
| `SVP Desktop.dc.html` | Màn hình desktop 1440×900, D01–D11: feed, trang chia sẻ, tải lên, đăng nhập, video của tôi, hồ sơ, 404 |
| `FeedMobile.dc.html` | Component feed dọc mobile: mọi trạng thái phát (tải, buffer, lỗi, mất mạng), like, theo dõi, tiêu đề mở rộng |
| `FeedDesktop.dc.html` | Component feed desktop: video 9:16, cột hành động bên cạnh, nút chuyển video, hộp thoại mời đăng nhập |
| `AuthForm.dc.html` | Form đăng nhập/đăng ký và các trạng thái: lỗi theo trường, sai thông tin, email đã dùng, giới hạn tần suất |
| `UploadFlow.dc.html` | Luồng tải lên 3 bước: chọn file, chi tiết, tiến độ, xử lý, xong/lỗi |
| `BottomNav.dc.html` | Thanh điều hướng dưới của mobile |
| `SidebarDesktop.dc.html` | Thanh bên của desktop (điều hướng, phím tắt, tài khoản) |
| `support.js` | Runtime để mở các file `.dc.html` |

## Cách mở

Các file `.dc.html` là trang tĩnh. Mở `SVP Mobile.dc.html`, `SVP Desktop.dc.html` hay `SVP Design System.dc.html` bằng trình
duyệt (kéo file vào cửa sổ, hoặc `open "web/design/SVP Mobile.dc.html"`); các file còn lại là component được ba trang đó nhúng.
`support.js` nạp React, Babel từ unpkg và `svp-tokens.css` nạp font Google, icon Lucide từ unpkg, nên cần mạng khi mở.

## Quy ước đã chốt

- Feed mobile dùng **cột hành động bên phải** (M01–M12). Biến thể "viên nổi" (M43–M45, `layout="pill"` trong `FeedMobile`) bỏ.
- Tải lên, hồ sơ, video của tôi và trang chia sẻ công khai nằm ở phần sau của giai đoạn web; thiết kế đã có sẵn nhưng chưa
  hiện thực.

## Chỗ khi hiện thực không chép nguyên

- **Font:** Be Vietnam Pro và JetBrains Mono tự host (qua `next/font`), không nạp từ Google Fonts.
- **Icon:** dùng `lucide-react` thay cho font icon `lucide-static` nạp từ unpkg, để CSP chỉ cần `font-src 'self'` và `style-src 'self'`.
- **Số rút gọn** (1,2 N, 3,4 Tr): `Intl.NumberFormat('vi', { notation: 'compact' })`, kiểm lại kết quả cho khớp bảng trong
  `SVP Design System.dc.html` (một chữ số thập phân, dấu phẩy, làm tròn xuống).
- **Màu avatar:** sinh từ id tác giả (hash vào 8 hue cố định, L 0.5, C 0.09), không gán tay như trong các khung mẫu.
- **Dữ liệu mẫu** (tên, email như `minhanh@gmail.com`, số liệu) chỉ là chỗ giữ chỗ của thiết kế, không phải dữ liệu thật.
