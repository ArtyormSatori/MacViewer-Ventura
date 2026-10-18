# Install & usage guide · Hướng dẫn cài đặt và sử dụng — MacViewer Ventura

MacViewer Ventura is an UltraViewer client for macOS (fork of [MacViewer by DeanOpen](https://github.com/DeanOpen/MacViewer)): control a Windows machine running UltraViewer from your Mac with its ID + password, and let another machine access your Mac after you approve. Requires macOS 13 Ventura or later, Intel or Apple Silicon.

MacViewer Ventura là client UltraViewer cho macOS (fork của [MacViewer của DeanOpen](https://github.com/DeanOpen/MacViewer)): điều khiển máy Windows chạy UltraViewer từ máy Mac bằng ID + mật khẩu, và cho máy khác truy cập máy Mac của bạn sau khi bạn đồng ý. Yêu cầu: macOS 13 Ventura trở lên, Intel hoặc Apple Silicon.

## 1. Install · Cài đặt

1. Download the latest release from [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases) — the **ZIP** file (`MacViewer-Ventura-4.0.zip`) is recommended.
   Tải bản mới nhất ở [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases) — khuyến nghị file **ZIP** (`MacViewer-Ventura-4.0.zip`).
2. Unzip, drag **MacViewer.app** into **Applications**.
   Giải nén, kéo **MacViewer.app** vào **Applications**.
3. First launch: **right-click → Open** (the app is ad-hoc signed; Gatekeeper blocks a first double-click). If still blocked, run in Terminal:
   Mở lần đầu bằng **chuột phải → Open** (app ký ad-hoc, Gatekeeper chặn nhấp đúp lần đầu). Nếu vẫn bị chặn, chạy trong Terminal:
   `xattr -dr com.apple.quarantine /Applications/MacViewer.app`

From 3.0 on, step 3 is not repeated for updates: the app installs new versions in-app (see section 3).
Từ bản 3.0 trở đi không cần lặp lại bước 3 cho các lần cập nhật: app tự cài bản mới trong app (xem mục 3).

## 2. Release 1.0 only: add the Sectigo R46 certificate · Chỉ dành cho bản 1.0: nạp chứng thư Sectigo R46

Cause: UltraViewer's relay uses a certificate signed by the *Sectigo Public Server Authentication Root R46* root; macOS 13's trust store does not include this root (Apple added it in macOS 14.4), so release 1.0 cannot verify the relay. From 2.0 the certificate is bundled in the app — skip this section.

Nguyên nhân: relay của UltraViewer dùng chứng thư ký bởi gốc *Sectigo Public Server Authentication Root R46*; kho chứng thư của macOS 13 chưa có gốc này (Apple bổ sung từ macOS 14.4), nên bản 1.0 không xác thực được relay. Từ bản 2.0, chứng thư đã nhúng sẵn trong app — bỏ qua mục này.

Download the certificate · Tải chứng thư: [SectigoPublicServerAuthenticationRootR46.crt](https://raw.githubusercontent.com/ArtyormSatori/MacViewer-Ventura/main/certs/SectigoPublicServerAuthenticationRootR46.crt)
SHA-256 fingerprint for verification · SHA-256 để đối chiếu: `7B:B6:47:A6:2A:EE:AC:88:BF:25:7A:A5:22:D0:1F:FE:A3:95:E0:AB:45:C7:3F:93:F6:56:54:EC:38:F2:5A:06`

Method 1 — Terminal · Cách 1 — Terminal:

```
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```

Method 2 — Keychain Access: double-click the `.crt` file → add to the **System** keychain; open Keychain Access → System → double-click the certificate → **Trust** section → "When using this certificate" = **Always Trust** → close and enter the admin password.
Cách 2 — Keychain Access: nhấp đúp file `.crt` → thêm vào keychain **System**; mở Keychain Access → System → nhấp đúp chứng thư → mục **Trust** → "When using this certificate" = **Always Trust** → đóng và nhập mật khẩu quản trị.

Verify · Kiểm tra: `security dump-trust-settings -d | grep -i -A2 sectigo` must return a result · phải có kết quả. Then quit the app fully (Cmd+Q) and reopen it · Xong thì thoát hẳn app (Cmd+Q) và mở lại.

Remove the certificate when no longer needed · Gỡ chứng thư khi không cần nữa:

```
sudo security remove-trusted-cert -d ~/Downloads/SectigoPublicServerAuthenticationRootR46.crt
```

## 3. Updates · Cập nhật

From 3.0, the app checks for new versions itself. When one is available, click **Update and Restart** — the app downloads it, matches the SHA-256 against the published checksum file, installs in place and relaunches, with no "unidentified developer" prompt. (Releases 1.0/2.0 cannot see newer releases; install 3.0 or 4.0 manually once.)

Từ bản 3.0, app tự kiểm tra bản mới. Có bản mới: bấm **Cập nhật và khởi động lại** — app tải về, đối chiếu SHA-256 với bảng tổng công bố, cài đè và tự mở lại, không còn cảnh báo "nhà phát triển chưa xác định". (Bản 1.0/2.0 không tự thấy các bản mới hơn; hãy cài 3.0 hoặc 4.0 thủ công một lần.)

## 4. Permissions (Mac as host only) · Cấp quyền (chỉ khi máy Mac làm host)

**System Settings → Privacy & Security** — enable MacViewer in two sections: **Screen Recording** (so the other side sees the screen) and **Accessibility** (so the other side can control). Then quit and reopen the app.

**System Settings → Privacy & Security**, bật MacViewer ở hai mục: **Screen Recording** (để phía kia thấy màn hình) và **Accessibility** (để phía kia điều khiển). Xong, thoát và mở lại app.

## 5. Usage · Sử dụng

- **Control another machine:** enter the other machine's UltraViewer ID + password → Connect. Control and Prefer-quality are on by default.
- **Share this machine:** start sharing, send the ID + password the app shows to the person who needs access, then approve the request on this machine (unless unattended access is enabled).
- **Clipboard:** copy text on one machine, paste on the other — automatic, two-way, text only.
- **Vietnamese typing:** Settings → Keyboard → choose VNI (the Windows-side IME composes the marks) or Unicode (sends precomposed characters); keep the Mac input source on ABC/US.

- **Điều khiển máy khác:** nhập ID + mật khẩu UltraViewer của máy kia → Kết nối. Điều khiển và mức chất lượng Ưu tiên bật sẵn mặc định.
- **Chia sẻ máy này:** bấm bắt đầu chia sẻ, gửi ID + mật khẩu app hiển thị cho người cần truy cập, rồi duyệt yêu cầu trên máy (trừ khi đã bật truy cập không người trực).
- **Clipboard:** sao chép văn bản ở máy này, dán ở máy kia và ngược lại — tự động hai chiều, chỉ văn bản.
- **Gõ tiếng Việt:** Cài đặt → Bàn phím → chọn VNI (để bộ gõ phía Windows ghép dấu) hoặc Unicode (gửi ký tự đã ghép sẵn); máy Mac giữ bộ gõ ABC/US.

## 6. Known limits · Giới hạn đã biết

- Host on Ventura: captured frames do not include the mouse cursor.
- Image color per the protocol is RGB555 (16-bit) — a limit of the UltraViewer protocol; this build adds dithering so gradients are smoother.
- No file transfer yet (the protocol has no file-transfer command).

- Host trên Ventura: ảnh chụp không kèm con trỏ chuột.
- Màu hình theo giao thức là RGB555 (16-bit) — giới hạn của giao thức UltraViewer; bản này có dithering nên dải màu mượt hơn.
- Chưa truyền được file (giao thức không có lệnh truyền file).
