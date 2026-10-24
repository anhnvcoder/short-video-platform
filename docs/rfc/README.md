# RFC

RFC (Request for Comments) là tài liệu **một trang** cho người quyết định tiền, thời gian và rủi ro mà không làm kỹ thuật:
quản lý, người đặt hàng. Mỗi giai đoạn lớn của dự án có một RFC, viết trước hoặc cùng lúc với ADR của giai đoạn đó.

## Khác ADR thế nào

| | RFC | ADR |
| --- | --- | --- |
| Người đọc | Người quyết định, không cần biết kỹ thuật | Người làm kỹ thuật, kể cả chính mình sáu tháng sau |
| Trả lời | Có nên làm không, tốn bao nhiêu, rủi ro gì | Làm thế nào, vì sao chọn cách này, cái giá kỹ thuật |
| Độ dài | Khoảng một trang in | Đủ để tái hiện quyết định |
| Thuật ngữ | Giải thích ngay lần đầu dùng, không nêu tên công cụ khi không cần | Dùng thoải mái |
| Con số | Có nguồn hoặc nói rõ là ước lượng và từ giả định nào | Kèm cách kiểm |

RFC không thay ADR và không lặp chi tiết của ADR: chỗ nào cần chi tiết thì dẫn tới ADR. Hai tài liệu phải khớp nhau; ADR sửa thì
RFC sửa theo.

## Quy ước

- Tên file `NNNN-<slug>.md`, số tăng dần, không dùng lại số. Viết tiếng Việt.
- Trạng thái: **Đề xuất** (chờ người đọc quyết) → **Chấp nhận** hoặc **Từ chối**, kèm ngày và quyết định cụ thể.
- Số về chi phí ghi nguồn (địa chỉ trang, ngày tra) và giả định (số giờ, loại máy, vùng); giá thay đổi nên ghi cả ngày tra.
- Số về hệ thống của dự án lấy từ ADR và roadmap, không ước lượng lại.

## Mẫu

```markdown
# NNNN. <Đề xuất, viết thành một câu>

- Trạng thái: Đề xuất
- Ngày: YYYY-MM-DD

## Vấn đề
Vì sao cần quyết định bây giờ. Chuyện gì xảy ra nếu không làm gì.

## Phương án
Mỗi phương án một dòng: được gì, mất gì.

## Chi phí
Công sức (giờ, số buổi) và tiền, mỗi con số có nguồn hoặc giả định.

## Rủi ro
Điều có thể sai, và cách biết sớm.

## Đề xuất
Chọn phương án nào, vì sao.

## Quyết định cần từ người đọc
Câu hỏi cụ thể, trả lời được bằng có/không hoặc một lựa chọn.
```

## Danh sách

| Số | Tên | Giai đoạn | Trạng thái |
| --- | --- | --- | --- |
| [0001](0001-reliability.md) | Đầu tư vào độ tin cậy của hệ thống | 6 | Đề xuất |
