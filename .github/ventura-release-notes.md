## MacViewer 0.3.4 cho macOS Ventura — v0.3.4-ventura.3

Bản cập nhật + tương thích cho macOS 13 Ventura (Intel + Apple Silicon).

**Có gì mới trong bản này**
- Đã sửa cơ chế tự cập nhật cho bản fork: khi có bản Ventura mới hơn, app nay tự nhận ra, tải về, đối chiếu file DMG với mã SHA-256 đã công bố, cài đè tại chỗ và tự mở lại — các bản cập nhật cài theo cách này sẽ không còn gặp cảnh báo "nhà phát triển chưa xác định". (Riêng việc cài ventura.3 lần này vẫn cần mở tay một lần bằng chuột phải → Open; mọi bản cập nhật sau đó đều tự động trơn tru.)
- Mặc định cho chiều điều khiển máy Windows chạy UltraViewer: điều khiển bật sẵn ngay khi phiên kết nối, và mức chất lượng hình "Ưu tiên chất lượng" (70) được áp dụng tự động khi kết nối.
- Toàn bộ nội dung của ventura.2: chứng thư gốc Sectigo R46 nhúng sẵn (không cần nạp Keychain), truy cập không cần người ngồi máy, chế độ gõ VNI/Unicode, dithering Bayer, nhịp chụp màn hình thích ứng phía máy chủ.

**Cài đặt:** xem HUONG_DAN_CAI_DAT.md trong repo này; với bản này bạn bỏ qua được mục 2 (nạp chứng thư).

Đã kiểm chứng bằng CI: toàn bộ test chạy trước khi đóng gói. Dùng SHA256SUMS-Ventura.txt để đối chiếu bản tải về.
