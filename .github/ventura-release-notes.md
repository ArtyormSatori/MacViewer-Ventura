## MacViewer Ventura — 4.0

Fork của MacViewer của DeanOpen, cho macOS 13 Ventura trở lên, Intel + Apple Silicon.

**Thay đổi chính**
- Tên hiển thị mới: **MacViewer Ventura**; số phiên bản riêng **4.0**.
- Bản cập nhật đầu tiên giao qua cơ chế tự cập nhật trong app (có từ 3.0): máy đang chạy 3.0 sẽ tự thấy bản 4.0 — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không còn cảnh báo "nhà phát triển chưa xác định".
- Giữ nguyên toàn bộ tính năng hiện có: chứng thư Sectigo R46 nhúng sẵn, điều khiển bật sẵn + chất lượng Ưu tiên tự áp dụng, truy cập không người trực, gõ VNI/Unicode, dithering Bayer.
- Sửa ba lỗi từ sử dụng thực tế: phím ⌘ giờ hoạt động như Ctrl phía Windows (⌘C/⌘V sao chép và dán bình thường, đổi lại được trong Cài đặt → Bàn phím); văn bản chép trên Mac dán được sang Windows với mọi đời UltraViewer; phiên điều khiển chịu được mạng chập chờn, không còn tự ngắt chỉ vì một lần mất tín hiệu giữ kết nối.

**Cài thủ công lần đầu:** xem HUONG_DAN_CAI_DAT.md (bỏ qua mục 2 nếu không dùng bản 1.0).

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-Ventura.txt.

---

## English

Fork of MacViewer by DeanOpen, for macOS 13 Ventura and later, Intel + Apple Silicon.

**Main changes**
- New display name: **MacViewer Ventura**; own version number **4.0**.
- The first update delivered through the in-app self-update mechanism (available since 3.0): a machine running 3.0 will see 4.0 automatically — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.
- All existing features kept: bundled Sectigo R46 certificate, control on + Prefer-quality applied automatically, unattended access, VNI/Unicode typing, Bayer dithering.
- Three field-reported fixes: the Command key now acts as Ctrl on the Windows side (⌘C/⌘V copy and paste work; switchable in Settings → Keyboard); text copied on the Mac pastes on Windows across UltraViewer versions; sessions ride out transient network drops instead of disconnecting on a single lost keepalive.

**First manual install:** see HUONG_DAN_CAI_DAT.md (skip section 2 unless you use release 1.0).

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-Ventura.txt.
