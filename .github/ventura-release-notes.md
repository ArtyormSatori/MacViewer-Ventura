## MacViewer Ventura — 4.0

**Thay đổi chính**
- Tên hiển thị mới: **MacViewer Ventura**; số phiên bản riêng **4.0**.
- Bản cập nhật đầu tiên giao qua cơ chế tự cập nhật trong app (có từ 3.0): máy đang chạy 3.0 sẽ tự thấy bản 4.0 — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không còn cảnh báo "nhà phát triển chưa xác định".
- Giữ nguyên toàn bộ tính năng hiện có: chứng thư Sectigo R46 nhúng sẵn, điều khiển bật sẵn + chất lượng Ưu tiên tự áp dụng, truy cập không người trực, gõ VNI/Unicode, dithering Bayer.
- Sửa ba lỗi từ sử dụng thực tế: phím ⌘ giờ hoạt động như Ctrl phía Windows (⌘C/⌘V sao chép và dán bình thường, đổi lại được trong Cài đặt → Bàn phím); văn bản chép trên Mac dán được sang Windows với mọi đời UltraViewer; phiên điều khiển chịu được mạng chập chờn, không còn tự ngắt chỉ vì một lần mất tín hiệu giữ kết nối.

**Cài thủ công lần đầu:** xem file readme.txt đính kèm kèm release này (bỏ qua mục 2 nếu không dùng bản 1.0).

Nếu macOS báo "nhà phát triển chưa xác định" khi mở lần đầu sau khi cài thủ công, chạy lệnh này trong Terminal (một lần duy nhất): `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — hoặc mở app bằng chuột phải → Open.

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-Ventura.txt.

---


## Bản Linux

Release này kèm bản viewer cho Linux (Ubuntu 24.04, x86_64): file `MacViewer-Ventura-Linux.tar.gz` (giải nén là chạy) hoặc gói `.deb`. Các gói phụ thuộc lúc chạy được liệt kê trong `README-Linux.txt` nằm trong gói.

## English

**Main changes**
- New display name: **MacViewer Ventura**; own version number **4.0**.
- The first update delivered through the in-app self-update mechanism (available since 3.0): a machine running 3.0 will see 4.0 automatically — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.
- All existing features kept: bundled Sectigo R46 certificate, control on + Prefer-quality applied automatically, unattended access, VNI/Unicode typing, Bayer dithering.
- Three field-reported fixes: the Command key now acts as Ctrl on the Windows side (⌘C/⌘V copy and paste work; switchable in Settings → Keyboard); text copied on the Mac pastes on Windows across UltraViewer versions; sessions ride out transient network drops instead of disconnecting on a single lost keepalive.

**First manual install:** see the readme.txt attached to this release (skip section 2 unless you use release 1.0).

If macOS shows the "unidentified developer" warning on the first launch after a manual install, run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — or open the app with right-click → Open.

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-Ventura.txt.

## Linux build

This release also includes the Linux viewer (Ubuntu 24.04, x86_64): `MacViewer-Ventura-Linux.tar.gz` (extract and run) or the `.deb` package. Runtime dependencies are listed in `README-Linux.txt` inside the package.
