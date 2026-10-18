## MacViewer Ventura — phiên bản 4.0

Bản fork của MacViewer 0.3.4 (DeanOpen) cho macOS 13 Ventura trở lên, Intel + Apple Silicon.

**Có gì mới trong bản này**
- Tên hiển thị của app đổi thành **MacViewer Ventura** (trong Finder, Launchpad, Dock và menu).
- Số phiên bản của app là **4.0** — từ nay nhìn số phiên bản là biết ngay bản nào mới hơn.
- Đây là bản cập nhật đầu tiên được giao qua cơ chế **tự cập nhật trong app** của ventura.3: nếu máy bạn đang chạy ventura.3, app sẽ tự báo có bản 4.0, bạn chỉ cần bấm **Cập nhật và khởi động lại** — app tự tải, đối chiếu mã SHA-256, cài đè và mở lại, không còn cảnh báo "nhà phát triển chưa xác định".
- Giữ nguyên toàn bộ tính năng của ventura.3: chứng thư gốc Sectigo R46 nhúng sẵn, điều khiển bật sẵn + chất lượng Ưu tiên tự áp dụng khi điều khiển máy Windows, truy cập không cần người ngồi máy, gõ VNI/Unicode, dithering Bayer.

**Cài đặt thủ công (lần đầu):** xem HUONG_DAN_CAI_DAT.md trong repo này; với các bản từ ventura.2 trở đi bạn bỏ qua được mục 2 (nạp chứng thư).

Đã kiểm chứng bằng CI: toàn bộ test chạy trước khi đóng gói. Dùng SHA256SUMS-Ventura.txt để đối chiếu bản tải về.
