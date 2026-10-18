# Hướng dẫn cài đặt và sử dụng MacViewer Ventura

**App này dùng để làm gì?** MacViewer Ventura là ứng dụng điều khiển máy tính từ xa cho máy Mac: từ máy Mac của bạn, bạn kết nối tới một máy đang chạy **UltraViewer** (thường là máy Windows) bằng ID và mật khẩu để xem màn hình và điều khiển máy đó — và ngược lại, người khác cũng có thể truy cập máy Mac của bạn sau khi bạn đồng ý. App là bản fork của [MacViewer 0.3.4 của DeanOpen](https://github.com/DeanOpen/MacViewer) được vá để chạy trên **macOS 13 Ventura** (bản gốc yêu cầu macOS 14 trở lên). Hỗ trợ cả máy Intel và Apple Silicon.

## 1. Tải và cài đặt

1. Vào trang [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases) và tải bản mới nhất. Khuyến nghị dùng file **ZIP** (`MacViewer-Ventura-4.0.zip`).
2. Giải nén, kéo **MacViewer.app** vào thư mục **Applications**.
3. Mở lần đầu bằng **chuột phải → Open** (app ký ad-hoc nên macOS Gatekeeper sẽ chặn nếu mở bằng nhấp đúp). Nếu vẫn bị chặn, chạy trong Terminal:
   `xattr -dr com.apple.quarantine /Applications/MacViewer.app`

## 2. Bước bắt buộc đối với bản ventura.1: nạp chứng thư gốc Sectigo R46

**Vì sao cần:** máy chủ chuyển tiếp của UltraViewer dùng chứng thư ký bởi chứng thư gốc *Sectigo Public Server Authentication Root R46*. Kho chứng thư hệ thống của macOS 13 chưa có chứng thư gốc này (Apple chỉ bổ sung từ macOS 14.4), nên trên Ventura app không xác thực được máy chủ và báo lỗi không kết nối được. Nạp chứng thư gốc này vào máy là hết. **Từ bản ventura.2 trở đi app đã tự mang theo chứng thư này, không cần làm bước này nữa.**

**Tải chứng thư:** [SectigoPublicServerAuthenticationRootR46.crt](https://raw.githubusercontent.com/ArtyormSatori/MacViewer-Ventura/main/certs/SectigoPublicServerAuthenticationRootR46.crt)
Dấu vân tay SHA-256 để đối chiếu: `7B:B6:47:A6:2A:EE:AC:88:BF:25:7A:A5:22:D0:1F:FE:A3:95:E0:AB:45:C7:3F:93:F6:56:54:EC:38:F2:5A:06`

**Cách 1 — Terminal (nhanh nhất):**

```
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```

(Đổi đường dẫn nếu file nằm ở thư mục khác, hoặc kéo thả file vào cửa sổ Terminal để máy tự điền đường dẫn.)

**Cách 2 — Giao diện Keychain Access:**

1. Nhấp đúp file `.crt`, chọn thêm vào keychain **System** (nhập mật khẩu quản trị nếu được hỏi).
2. Mở **Keychain Access**, chọn keychain **System**, tìm **Sectigo Public Server Authentication Root R46** và nhấp đúp vào nó.
3. Mở mục **Trust**, đặt "When using this certificate" thành **Always Trust**, đóng cửa sổ và nhập mật khẩu quản trị để lưu.

**Kiểm tra đã nạp đúng chưa** (phải ra kết quả):

```
security dump-trust-settings -d | grep -i -A2 sectigo
```

Làm xong, thoát hẳn MacViewer (Cmd+Q) rồi mở lại.

## Cập nhật các bản sau (từ ventura.3)

Từ bản **ventura.3** trở đi, app tự kiểm tra và cài bản mới ngay trong app (tải về, đối chiếu mã SHA-256 với bảng tổng đã công bố, thay thế tại chỗ và tự mở lại) — các lần cập nhật sau sẽ **không** còn gặp cảnh báo "nhà phát triển chưa xác định". Riêng việc cài ventura.3 lần này vẫn cần mở tay một lần (chuột phải → Mở) như các bản trước.

## 3. Cấp quyền (chỉ khi máy này làm máy chủ — bị điều khiển)

Vào **System Settings → Privacy & Security** và bật MacViewer ở hai mục:

- **Screen Recording** (để phía bên kia thấy màn hình)
- **Accessibility** (để phía bên kia điều khiển chuột/phím)

Sau khi cấp quyền, thoát và mở lại app.

## 4. Sử dụng

- **Chia sẻ máy này:** bấm bắt đầu chia sẻ — app hiện **ID** và **mật khẩu** của máy. Gửi hai thông tin này cho người cần điều khiển.
- **Điều khiển máy khác:** nhập **ID UltraViewer trên Windows** của đối tác và mật khẩu của họ, bấm kết nối. Khi phía Windows chấp nhận, màn hình của họ hiện ra và bạn điều khiển bằng chuột/phím của Mac.
- **Clipboard:** sao chép văn bản ở máy này và dán ở máy kia (và ngược lại) — hoạt động tự động hai chiều, chỉ với văn bản.

## 5. Giới hạn đã biết

- Khi máy Ventura làm máy chủ, ảnh chụp màn hình **không kèm con trỏ chuột** (hạn chế của đường chụp tương thích Ventura).
- Màu hiển thị theo giao thức UltraViewer là 16-bit (RGB555) — đây là giới hạn của giao thức, không phải của app. Bản Ventura có thêm dithering nên dải màu mượt hơn bản gốc.
- Chưa gửi được file qua UltraViewer (giao thức không có lệnh truyền file). Tính năng truyền file giữa hai máy MacViewer sẽ có ở bản sau.
- Tính năng truy cập không cần người ngồi máy, chế độ gõ tiếng Việt VNI và các cải tiến mượt hình có từ bản **ventura.2**.

## 6. Gỡ chứng thư (nếu muốn)

```
sudo security remove-trusted-cert -d ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```
