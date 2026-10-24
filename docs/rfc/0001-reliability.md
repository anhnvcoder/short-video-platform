# 0001. Đầu tư vào độ tin cậy: thử hệ thống chịu tải, chịu sự cố và khôi phục dữ liệu trước khi chạy thật

- Trạng thái: Đề xuất
- Ngày: 2026-10-24
- Chi tiết kỹ thuật: [ADR-0020](../adr/0020-reliability-stage6.md)

## Vấn đề

Hệ thống đã chạy được, nhưng ba điều quan trọng nhất khi có người dùng thật thì chưa ai kiểm:

1. **Chưa biết chịu được bao nhiêu người dùng.** Với 100 000 người dùng mỗi ngày, lúc đông nhất khoảng 21 lượt tải danh sách video
   (một trang feed) mỗi giây. Mục tiêu thử là 1 000 lượt mỗi giây, gấp khoảng 50 lần, tương đương chừng 5 triệu người dùng mỗi ngày (nguồn: tài liệu
   kiến trúc). Chưa có phép đo nào trên máy đủ mạnh; máy cá nhân 16 GB không đo được con số này.
2. **Chưa từng khôi phục dữ liệu thật từ bản sao lưu.** Một bản sao lưu chưa từng được khôi phục thì chưa chắc dùng được. Chưa
   có con số "mất bao lâu để chạy lại" và "mất tối đa bao nhiêu dữ liệu gần nhất".
3. **Sự cố xử lý theo trí nhớ.** Chưa có sổ tay từng bước cho từng cảnh báo, và chưa có buổi tập nào để người trực thử làm theo.

Nếu không làm: lần đầu gặp các tình huống này sẽ là lúc có người dùng thật, và lúc đó mỗi phút gián đoạn đều tốn kém.

## Phương án

| Phương án | Được | Mất |
| --- | --- | --- |
| A. Chỉ làm trên máy cá nhân | Không tốn tiền thuê máy chủ; có sổ tay, buổi tập sự cố (tắt hẳn một phần của hệ thống, xem cảnh báo và người trực phản ứng), thử khôi phục cơ sở dữ liệu, đo tải nhỏ | Không trả lời được câu "chịu bao nhiêu người dùng"; các thử làm hỏng giữa lúc tải lớn (tắt ngẫu nhiên từng bản chạy của dịch vụ, làm chậm mạng giữa các phần, tắt hàng đợi tin nhắn) cần máy chủ thuê, không chạy được |
| **B. Làm trên máy cá nhân, rồi một buổi đo thật trên máy chủ thuê (giai đoạn 7)** | Có đủ ba con số: tải, hành vi khi sự cố, thời gian khôi phục; lệnh viết sẵn nên buổi thuê ngắn | Tốn một buổi và vài chục đô la; kết luận đầy đủ chỉ có sau giai đoạn 7 |
| C. Bỏ qua | Không tốn gì | Giữ nguyên ba điều chưa biết ở trên |

## Chi phí

**Công sức** (lộ trình tính theo cuối tuần; người viết giả định 12 giờ mỗi cuối tuần, hai ngày × 6 giờ): A là 2–3 cuối tuần
của giai đoạn 6 theo lộ trình, tức **24–36 giờ**. B là A cộng một cuối tuần cho buổi trên máy chủ thuê (chuẩn bị, buổi 8 giờ, viết
báo cáo; ước lượng của người viết, chưa có số đo), tức **36–48 giờ**, phần thêm nằm trong 4–6 cuối tuần của giai đoạn 7. C: 0 giờ.

**Tiền thuê máy chủ cho một buổi** (ước lượng từ giả định, đơn giá từ bảng giá công khai của Amazon Web Services, tra ngày
2026-10-24):

- Giả định: vùng US East (N. Virginia); 8 giờ (dựng, đo tải, thử sự cố, thử khôi phục, dọn); 3 máy 4 nhân 16 GB cho dịch vụ
  (m7g.xlarge), 2 máy 8 nhân cho xử lý video (c7g.2xlarge), 2 máy 4 nhân cho công cụ tạo tải (c7g.xlarge); ổ đĩa 300 GB; 30 GB
  đi qua cổng ra internet (NAT) khi tải phần mềm về. Cỡ máy và dung lượng là lựa chọn của người viết, chưa kiểm bằng buổi chạy thật.

| Khoản | Đơn giá | Thành tiền 8 giờ |
| --- | --- | --- |
| Cụm điều phối máy chủ do AWS quản lý (EKS) | 0,10 USD/giờ | 0,80 USD |
| 3 × m7g.xlarge | 0,1632 USD/giờ mỗi máy | 3,92 USD |
| 2 × c7g.2xlarge | 0,29 USD/giờ mỗi máy | 4,64 USD |
| 2 × c7g.xlarge | 0,145 USD/giờ mỗi máy | 2,32 USD |
| Cổng ra internet (NAT): giờ + 30 GB | 0,045 USD/giờ; 0,045 USD/GB | 0,36 + 1,35 USD |
| Ổ đĩa 300 GB (loại gp3) | 0,08 USD/GB-tháng | 0,26 USD |
| **Cộng** | | **khoảng 13,65 USD** |

Chưa tính: bộ cân bằng tải, bản chụp ổ đĩa (0,05 USD/GB-tháng, xoá cuối buổi). Làm tròn lên cho hai khoản này: **dưới 20 USD
một buổi**, dưới 40 USD nếu cần chạy lại một lần. **Trần này không gồm cơ sở dữ liệu thuê** (Postgres và Redis do AWS quản,
RDS và ElastiCache), mà buổi đo **có** dùng: ở giai đoạn 7 hệ thống chạy trên chúng, phép đo tải cũng đọc số trên Redis thuê đó.
Vậy 20 USD chưa đủ cho một buổi đo; người viết giả định giá của chúng được tra và xin duyệt cùng kế hoạch giai đoạn 7, cộng
thêm vào trần này. Quên tắt máy: khoảng 36 USD mỗi ngày (1,5046 USD/giờ × 24, chưa gồm cơ sở dữ liệu thuê).
Cuối buổi luôn có lệnh xoá và lệnh quét tài nguyên sót; quy tắc của dự án là bật cảnh báo ngân sách từ ngày đầu.

Nguồn đơn giá (ngày tra 2026-10-24): [giá EKS](https://aws.amazon.com/eks/pricing/),
[giá EC2](https://aws.amazon.com/ec2/pricing/on-demand/), [giá EBS](https://aws.amazon.com/ebs/pricing/),
[giá NAT](https://aws.amazon.com/vpc/pricing/); số cụ thể đọc từ bảng giá công khai của chính AWS
([EC2 US East](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.json) bản
2026-10-23, [EKS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEKS/current/index.json) bản 2026-09-28).
Giá đổi theo vùng và thời điểm: cần tra lại ngày làm.

## Rủi ro

- **Chi phí vượt dự kiến** do quên tắt máy hoặc lỗi cấu hình. Giảm: lệnh xoá và quét sót chạy cuối buổi, cảnh báo ngân sách,
  người học xác nhận từng lệnh chạm tài khoản cloud.
- **Buổi đo hỏng giữa chừng** (công cụ lỗi, quyền thiếu) khiến phải thuê thêm buổi. Giảm: phần chạy được trên máy cá nhân xong
  trước; lệnh phía cloud đã kiểm tĩnh (đúng định dạng, đúng phiên bản), chưa chạy thật.
- **Kết quả đo xấu hơn mục tiêu.** Đây là điều cần biết; không phải rủi ro của việc đo. Kết quả đi vào báo cáo và việc cần sửa.
- **Con số lệch**: chi phí trên là ước lượng; số thật chỉ có sau buổi chạy và sẽ ghi vào báo cáo chi phí giai đoạn 7.

## Đề xuất

Chọn **B**: làm phần chạy được trên máy cá nhân ngay (giai đoạn 6), đo thật trên máy chủ thuê một buổi ở giai đoạn 7. Phần
local cho ra sổ tay, buổi tập sự cố và thời gian khôi phục cơ sở dữ liệu đo được; phần thuê chỉ để trả lời câu "chịu bao nhiêu
người dùng" và "sự cố giữa lúc tải lớn có lan ra không", hai câu mà máy cá nhân không trả lời được.

## Quyết định cần từ người đọc

1. Đồng ý chọn B, với trần chi phí **20 USD mỗi buổi đo** (40 USD nếu chạy lại một lần) cho phần máy chủ, cộng giá cơ sở dữ
   liệu thuê sẽ tra và xin duyệt cùng kế hoạch giai đoạn 7, không?
2. Nếu không: chọn A (chấp nhận chưa biết con số tải) hay C?
