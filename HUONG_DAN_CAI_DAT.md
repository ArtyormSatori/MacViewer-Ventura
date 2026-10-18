# Hướng dẫn cài đặt và sử dụng MacViewer Ventura

MacViewer Ventura là client UltraViewer cho macOS (fork của [MacViewer 0.3.4 — DeanOpen](https://github.com/DeanOpen/MacViewer)): điều khiển máy Windows chạy UltraViewer từ máy Mac bằng ID + mật khẩu, và cho máy khác truy cập máy Mac của bạn sau khi bạn đồng ý. Yêu cầu: macOS 13 Ventura trở lên, Intel hoặc Apple Silicon.

## 1. Cài đặt

1. Tải bản mới nhất ở [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases) — khuyến nghị file **ZIP** (`MacViewer-Ventura-4.0.zip`).
2. Giải nén, kéo **MacViewer.app** vào **Applications**.
3. Mở lần đầu bằng **chuột phải → Open** (app ký ad-hoc, Gatekeeper chặn nhấp đúp lần đầu). Nếu vẫn bị chặn, chạy trong Terminal:
   `xattr -dr com.apple.quarantine /Applications/MacViewer.app`

Từ bản ventura.3 trở đi không cần lặp lại bước 3 cho các lần cập nhật: app tự cài bản mới trong app (xem mục 3).

## 2. Chỉ dành cho bản ventura.1: nạp chứng thư Sectigo R46

Nguyên nhân: relay của UltraViewer dùng chứng thư ký bởi gốc *Sectigo Public Server Authentication Root R46*; kho chứng thư của macOS 13 chưa có gốc này (Apple bổ sung từ macOS 14.4), nên bản ventura.1 không xác thực được relay. Từ ventura.2, chứng thư đã nhúng sẵn trong app — bỏ qua mục này.

Tải chứng thư: [SectigoPublicServerAuthenticationRootR46.crt](https://raw.githubusercontent.com/ArtyormSatori/MacViewer-Ventura/main/certs/SectigoPublicServerAuthenticationRootR46.crt)
SHA-256 để đối chiếu: `7B:B6:47:A6:2A:EE:AC:88:BF:25:7A:A5:22:D0:1F:FE:A3:95:E0:AB:45:C7:3F:93:F6:56:54:EC:38:F2:5A:06`

Cách 1 — Terminal:

```
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```

Cách 2 — Keychain Access: nhấp đúp file `.crt` → thêm vào keychain **System**; mở Keychain Access → System → nhấp đúp chứng thư → mục **Trust** → "When using this certificate" = **Always Trust** → đóng và nhập mật khẩu quản trị.

Kiểm tra: `security dump-trust-settings -d | grep -i -A2 sectigo` phải có kết quả. Xong thì thoát hẳn app (Cmd+Q) và mở lại.

Gỡ chứng thư khi không cần nữa:

```
sudo security remove-trusted-cert -d ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```

## 3. Cập nhật

Từ ventura.3, app tự kiểm tra bản mới. Có bản mới: bấm **Cập nhật và khởi động lại** — app tải về, đối chiếu SHA-256 với bảng tổng công bố, cài đè và tự mở lại, không còn cảnh báo "nhà phát triển chưa xác định". (Bản ventura.1/ventura.2 không tự thấy các bản mới hơn; hãy cài ventura.3 hoặc 4.0 thủ công một lần.)

## 4. Cấp quyền (chỉ khi máy Mac làm host)

**System Settings → Privacy & Security**, bật MacViewer ở hai mục: **Screen Recording** (để phía kia thấy màn hình) và **Accessibility** (để phía kia điều khiển). Xong, thoát và mở lại app.

## 5. Sử dụng

- **Điều khiển máy khác:** nhập ID + mật khẩu UltraViewer của máy kia → Kết nối. Điều khiển và mức chất lượng Ưu tiên bật sẵn mặc định.
- **Chia sẻ máy này:** bấm bắt đầu chia sẻ, gửi ID + mật khẩu app hiển thị cho người cần truy cập, rồi duyệt yêu cầu trên máy (trừ khi đã bật truy cập không người trực).
- **Clipboard:** sao chép văn bản ở máy này, dán ở máy kia và ngược lại — tự động hai chiều, chỉ văn bản.
- **Gõ tiếng Việt:** Cài đặt → Bàn phím → chọn VNI (để bộ gõ phía Windows ghép dấu) hoặc Unicode (gửi ký tự đã ghép sẵn); máy Mac giữ bộ gõ ABC/US.

## 6. Giới hạn đã biết

- Host trên Ventura: ảnh chụp không kèm con trỏ chuột.
- Màu hình theo giao thức là RGB555 (16-bit) — giới hạn của giao thức UltraViewer; bản này có dithering nên dải màu mượt hơn.
- Chưa truyền được file (giao thức không có lệnh truyền file).
