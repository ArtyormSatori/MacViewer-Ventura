# Lộ trình tính năng bổ sung (yêu cầu của chủ repo, 2026-10-18)

Nguyên tắc trung thực kỹ thuật: MacViewer nói chuyện bằng **giao thức
UltraViewer** qua máy chủ trung gian của UltraViewer. Tính năng nào phụ
thuộc cả hai đầu dây thì chỉ làm được trọn vẹn khi đầu kia cũng là
MacViewer (Mac↔Mac); đầu kia là UltraViewer trên Windows thì bị trần của
chính giao thức UltraViewer. Từng mục dưới đây ghi rõ trần đó.

## Giai đoạn A — phía client, làm được ngay trên nền bản Ventura

1. **Truy cập không cần người ngồi máy (unattended)** — ✅ ĐÃ LÀM (nhánh stage-a)
   Làm rõ cơ chế: phía host vốn đã tự xác minh bằng chứng mật khẩu của
   người kết nối (thử thách nonce trong `UltraViewerHostSession`) TRƯỚC
   khi hiện yêu cầu lên màn hình — nút Duyệt chỉ là lớp đồng ý thứ hai.
   Vì vậy trên giao thức legacy không có mật khẩu thứ hai riêng; unattended
   = tự duyệt sau khi bằng chứng mật khẩu đã khớp. Đã bổ sung: công tắc
   trong Cài đặt (bật/tắt, cho điều khiển hay chỉ xem), tự khởi động chia
   sẻ khi mở app nếu đang bật, Login Item (SMAppService, macOS 13+), và
   ngăn máy ngủ khi đang chia sẻ. Thiếu quyền (Quay màn hình/Tiếp cận) thì
   yêu cầu vẫn nằm chờ duyệt tay như cũ. Có unit test cho logic quyết định.

2. **Bàn phím US / VNI**
   `KeyboardMessage` mang virtual-key + scan-code + 1 ký tự UTF-16;
   encoder hiện chỉ chuyển ký tự ASCII đơn (`MacRemoteInputEncoder`).
   Bổ sung chế độ bàn phím: (a) Keycode vật lý (US, như hiện tại);
   (b) VNI passthrough — không để bộ gõ phía Mac nuốt phím, gửi nguyên
   phím chữ + số để bộ gõ VNI (Unikey) phía Windows tự ghép dấu;
   (c) Text mode — gửi ký tự Unicode đã ghép sẵn cho các trường hợp còn lại.

3. **Màu 16-bit / 32-bit + chất lượng hình** — ĐÃ ĐIỀU CHỈNH SAU KHI ĐỌC SÂU (2026-10-18)
   Sự thật đo được: CẢ HAI đường hình của giao thức đều là RGB555 — đường
   legacy và cả đường "modern" (khung chính RGB555; màu đầy đủ duy nhất
   nằm ở atlas JPEG phụ của UltraViewer Windows). Vì vậy "32-bit" không
   thể nhét vào bất kỳ định dạng khung sẵn có nào; muốn có màu 32-bit thật
   cho Mac↔Mac phải dựng một kênh phụ riêng ngoài các lệnh màn hình của
   UltraViewer (việc thiết kế riêng, chưa làm).
   Phần làm được ngay trong trần giao thức — ĐÃ LÀM (nhánh stage-a):
   dithering có thứ tự (Bayer 4x4) khi hạ BGRA → RGB555 phía host. Trước
   đây chặt cụt (>>3) gây vệt bậc màu rõ trên gradient; nay mỗi pixel được
   làm tròn theo ngưỡng Bayer theo vị trí, gradient mịn hẳn mà màu phẳng
   vẫn chính xác tuyệt đối, và khung tĩnh vẫn cho ra cùng một dãy byte
   (giữ nguyên cơ chế bỏ qua khung không đổi). Có unit test.
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

1. Nhịp chụp thích ứng — ✅ ĐÃ LÀM (nhánh stage-a): `HostCapturePacing`
   giảm một nửa độ trễ mỗi khi khung hình thật sự thay đổi (sàn 50 ms →
   tối đa ~20 lần chụp/giây, vẫn xếp hàng theo ACK của phía xem) và tăng
   gấp đôi khi khung không đổi (trần 1000 ms → màn hình tĩnh chỉ tốn ~1
   lần chụp/giây, có thay đổi là bắt lại trong vòng 1 giây rồi tăng tốc
   về tối đa sau vài khung). Có unit test cho máy trạng thái nhịp.
2. Màu 32-bit (mục 3 ở Giai đoạn A) — hết banding trên ảnh gradient.
3. Tinh chỉnh Zstd theo chế độ chất lượng — ĐÁNH GIÁ LẠI (đính chính):
   ZstdScreenEncoder CÓ nằm trên đường thật — nó nén khung hình legacy
   phía host (`HostedScreenMessage`) và clipboard, đang cố định level 1
   không dictionary. Nâng level cho khung tĩnh là khả thi (mọi level zstd
   đều giải nén được phía đối tác) nhưng đánh đổi CPU phía host và chưa
   có số đo thực tế để chọn mức — để dành khi có máy Ventura thật đo FPS/
   băng thông ở Giai đoạn A2 vòng 2. Chưa làm.
4. Ưu tiên đường kết nối trực tiếp trong LAN (đã có
   `TCPDirectPeerTransport`) và hiển thị rõ đang đi trực tiếp hay qua relay
   — chờ thiết kế cùng kênh phụ Mac↔Mac ở Giai đoạn B.
5. Viewer: gộp khung mới nhất — ĐÁNH GIÁ LẠI: luồng sự kiện phía xem đã có
   trần đệm ở tầng relay (bufferingOldest(8)); tầng adapter tiêu thụ từng
   khung trong vài micro-giây (chỉ gán frame hiển thị). Nguy cơ dồn khung
   gây trễ là thấp và thoáng qua; không can thiệp để tránh phá đường ống
   đang chạy đúng. Smooth scaling vốn đã bật mặc định.

Trần trung thực: RustDesk dùng giao thức riêng, nén video phần cứng
H.264/VP9 qua UDP. Khi đầu kia là UltraViewer Windows, trần chất lượng là
của chính giao thức UltraViewer (TCP relay, cập nhật theo hình chữ nhật,
16-bit) — không một client nào vượt được trần đó. Gói này nâng tới trần
đó, và nâng cao hơn hẳn cho phiên Mac↔Mac nơi ta kiểm soát cả hai đầu.
