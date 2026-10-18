## MacViewer Ventura — 4.0

Fork of MacViewer by DeanOpen, for macOS 13 Ventura and later, Intel + Apple Silicon.
Fork của MacViewer của DeanOpen, cho macOS 13 Ventura trở lên, Intel + Apple Silicon.

**Main changes · Thay đổi chính**
- New display name: **MacViewer Ventura**; own version number **4.0**.
  Tên hiển thị mới: **MacViewer Ventura**; số phiên bản riêng **4.0**.
- The first update delivered through the in-app self-update mechanism (available since 3.0): a machine running 3.0 will see 4.0 automatically — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.
  Bản cập nhật đầu tiên giao qua cơ chế tự cập nhật trong app (có từ 3.0): máy đang chạy 3.0 sẽ tự thấy bản 4.0 — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không còn cảnh báo "nhà phát triển chưa xác định".
- All existing features kept: bundled Sectigo R46 certificate, control on + Prefer-quality applied automatically, unattended access, VNI/Unicode typing, Bayer dithering.
  Giữ nguyên toàn bộ tính năng hiện có: chứng thư Sectigo R46 nhúng sẵn, điều khiển bật sẵn + chất lượng Ưu tiên tự áp dụng, truy cập không người trực, gõ VNI/Unicode, dithering Bayer.

**First manual install · Cài thủ công lần đầu:** see · xem HUONG_DAN_CAI_DAT.md (skip section 2 unless you use release 1.0 · bỏ qua mục 2 nếu không dùng bản 1.0).

CI: the full test suite runs before packaging · toàn bộ test chạy trước khi đóng gói. Verify downloads with · Đối chiếu bản tải về bằng SHA256SUMS-Ventura.txt.
