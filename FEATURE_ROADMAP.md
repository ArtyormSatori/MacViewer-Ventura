# Lộ trình tính năng bổ sung (yêu cầu của chủ repo, 2026-10-18)

Nguyên tắc trung thực kỹ thuật: MacViewer nói chuyện bằng **giao thức
UltraViewer** qua máy chủ trung gian của UltraViewer. Tính năng nào phụ
thuộc cả hai đầu dây thì chỉ làm được trọn vẹn khi đầu kia cũng là
MacViewer (Mac↔Mac); đầu kia là UltraViewer trên Windows thì bị trần của
chính giao thức UltraViewer. Từng mục dưới đây ghi rõ trần đó.

## Giai đoạn A — phía client, làm được ngay trên nền bản Ventura

1. **Truy cập không cần người ngồi máy (unattended)**
   Hiện tại host luôn chờ người dùng bấm Duyệt (`MacHostingModel.approve`).
   Bổ sung: mật khẩu unattended riêng lưu trong Keychain + chế độ tự duyệt
   khi mật khẩu khớp, mục đăng nhập cùng hệ thống (Login Item, macOS 13+)
   và tuỳ chọn ngăn máy ngủ. Không đổi giao thức.

2. **Bàn phím US / VNI**
   `KeyboardMessage` mang virtual-key + scan-code + 1 ký tự UTF-16;
   encoder hiện chỉ chuyển ký tự ASCII đơn (`MacRemoteInputEncoder`).
   Bổ sung chế độ bàn phím: (a) Keycode vật lý (US, như hiện tại);
   (b) VNI passthrough — không để bộ gõ phía Mac nuốt phím, gửi nguyên
   phím chữ + số để bộ gõ VNI (Unikey) phía Windows tự ghép dấu;
   (c) Text mode — gửi ký tự Unicode đã ghép sẵn cho các trường hợp còn lại.

3. **Màu 16-bit / 32-bit + chất lượng hình**
   Đường legacy UltraViewer đang là RGB555 (màu 15-bit đóng trong 16-bit)
   — đó là trần của giao thức, phía Windows UltraViewer cũng chỉ yêu cầu
   16-bit. Bổ sung định dạng khung BGRA 32-bit cho phiên Mac↔Mac (ảnh chụp
   vốn đã là 32BGRA trước khi bị hạ xuống 555) + tuỳ chọn trong Cài đặt:
   "Tiết kiệm — 16-bit" / "Đầy đủ — 32-bit (chỉ Mac↔Mac)".
   Chất lượng kiểu RustDesk (H.264/VP9 + UDP) không đạt được khi còn đi
   qua giao thức UltraViewer; mục này chỉ cải thiện trong trần đó.

## Giai đoạn B — hai đầu MacViewer

4. **Gửi file (Mac↔Mac)**
   Giao thức hiện không có lệnh truyền file (chỉ có chat lệnh 12/29/30 và
   clipboard). Bổ sung kênh file riêng giữa hai MacViewer: chia块, kiểm
   tra toàn vẹn, gửi/nhận có thanh tiến độ trong cửa sổ Session Tools.
   Với đầu Windows UltraViewer: KHÔNG làm được từ phía client này vì
   UltraViewer không công bố lệnh truyền file tương thích.

## Giai đoạn C — cần máy chủ riêng, phải chốt phương án trước

5. **Quản lý theo tài khoản kiểu DeskIn**
   Bản hiện tại không có khái niệm tài khoản: danh tính là ID số do relay
   UltraViewer cấp (`ClientRegistration`). Muốn có đăng nhập, danh sách
   thiết bị theo tài khoản, đồng bộ nhiều máy thì phải có backend:
   (a) tự host trên máy chủ của chủ repo (vega + Cloudflare Tunnel);
   (b) Supabase/Firebase free tier; (c) tạm để hồ sơ cục bộ trên máy.
   Đây là một tiểu dự án riêng (đăng ký/đăng nhập, bảo mật, đồng bộ),
   không gộp vào bản Ventura đầu tiên.

## Gói chất lượng (yêu cầu bổ sung 2026-10-18: mượt + nét như RustDesk)

Số liệu đo từ code hiện tại cho thấy nút thắt thật:

- Phía host (Mac bị điều khiển) chụp màn hình theo nhịp **250 ms/lần**
  (`UltraViewerHostSession`, chờ ACK từng khung) → tối đa ~4 FPS. Đây là
  nguồn giật lớn nhất, không phải mạng.
- Đường modern nén Zstd level 1 (ưu tiên tốc độ), ảnh RGB555 gây vệt bậc
  màu (banding) rõ trên gradient.
- Phía viewer đã có sẵn các mức Automatic / Speed / Quality / Custom.

Đòn bẩy sẽ làm trong Giai đoạn A2 (Mac↔Mac đạt nhiều nhất):

1. Nhịp chụp thích ứng: 250 ms → 50–100 ms khi màn hình đang thay đổi,
   lùi lại khi tĩnh; vẫn chờ ACK nhưng pipeline sâu hơn khi mạng khỏe.
   Mục tiêu: 15–20 FPS phía host thay vì ~4.
2. Màu 32-bit (mục 3 ở Giai đoạn A) — hết banding trên ảnh gradient.
3. Tinh chỉnh Zstd theo chế độ chất lượng (level + dictionary) thay vì
   một level 1 cố định cho mọi trường hợp.
4. Ưu tiên đường kết nối trực tiếp trong LAN (đã có
   `TCPDirectPeerTransport`) và hiển thị rõ đang đi trực tiếp hay qua relay.
5. Viewer: gộp khung mới nhất (bỏ khung trễ thay vì phát lại hàng đợi),
   smooth scaling mặc định bật.

Trần trung thực: RustDesk dùng giao thức riêng, nén video phần cứng
H.264/VP9 qua UDP. Khi đầu kia là UltraViewer Windows, trần chất lượng là
của chính giao thức UltraViewer (TCP relay, cập nhật theo hình chữ nhật,
16-bit) — không một client nào vượt được trần đó. Gói này nâng tới trần
đó, và nâng cao hơn hẳn cho phiên Mac↔Mac nơi ta kiểm soát cả hai đầu.
