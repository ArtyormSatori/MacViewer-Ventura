## MacViewer Ventura — 4.0

Fork của MacViewer 0.3.4 (DeanOpen) cho macOS 13 Ventura trở lên, Intel + Apple Silicon.

**Thay đổi chính**
- Tên hiển thị mới: **MacViewer Ventura**; số phiên bản riêng **4.0** (nền kỹ thuật giữ nguyên MacViewer 0.3.4).
- Bản cập nhật đầu tiên giao qua cơ chế tự cập nhật trong app (có từ ventura.3): máy đang chạy ventura.3 sẽ tự thấy bản 4.0 — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không còn cảnh báo "nhà phát triển chưa xác định".
- Giữ nguyên toàn bộ tính năng hiện có: chứng thư Sectigo R46 nhúng sẵn, điều khiển bật sẵn + chất lượng Ưu tiên tự áp dụng, truy cập không người trực, gõ VNI/Unicode, dithering Bayer.

**Cài thủ công lần đầu:** xem HUONG_DAN_CAI_DAT.md (bỏ qua mục 2 nếu không dùng ventura.1).

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-Ventura.txt.
