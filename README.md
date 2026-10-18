<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="MacViewer Ventura app icon · Biểu tượng MacViewer Ventura">

# MacViewer Ventura

**An UltraViewer client for macOS: control a Windows machine from your Mac, and vice versa.**
**Client UltraViewer cho macOS: điều khiển máy Windows từ máy Mac, và ngược lại.**

[Download the latest release](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest) · [Tải bản mới nhất](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest) · macOS 13 Ventura and later · trở lên · Intel + Apple Silicon

[![Release](https://img.shields.io/github/v/release/ArtyormSatori/MacViewer-Ventura)](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6-orange)

English · Tiếng Việt (documentation in this file is bilingual · tài liệu trong file này là song ngữ)

<img src="docs/images/main-window-vi.png" width="820" alt="MacViewer Ventura main window">
<br><sub>Main window (Vietnamese UI) · Giao diện chính (bản tiếng Việt)</sub>

</div>

## Overview · Tổng quan

Fork of [MacViewer](https://github.com/DeanOpen/MacViewer) by DeanOpen. MacViewer is an open-source macOS client for UltraViewer — remote-control software that ships for Windows only. This fork lowers the OS requirement from macOS 14 to **macOS 13** and adds the changes in the "Differences from upstream" table. Not an official UltraViewer product; connect only to machines you are permitted to access.

Fork của [MacViewer](https://github.com/DeanOpen/MacViewer) của DeanOpen. MacViewer là client macOS mã nguồn mở cho UltraViewer — phần mềm điều khiển máy tính từ xa chỉ có bản Windows. Fork này hạ yêu cầu hệ điều hành từ macOS 14 xuống **macOS 13** và bổ sung các thay đổi ở bảng "Khác bản gốc". Không phải sản phẩm chính thức của UltraViewer; chỉ kết nối tới máy bạn được phép truy cập.

## What the app does · App làm gì

- **Viewer:** enter the ID + password of a machine running UltraViewer/MacViewer → view its screen, control mouse and keyboard.
- **Host:** let another machine connect to this Mac after the owner approves (view and control permissions granted separately).
- **Transport:** TLS via UltraViewer's relay; machines on the same LAN connect directly.
- **Extras:** chat, two-way text clipboard, screenshot + annotation, session video recording, remote audio playback, partner passwords stored in Keychain.

- **Viewer:** nhập ID + mật khẩu của máy đang chạy UltraViewer/MacViewer → xem màn hình, điều khiển chuột và bàn phím.
- **Host:** cho máy khác kết nối vào máy Mac, sau khi chủ máy duyệt (quyền xem và quyền điều khiển cấp riêng).
- **Đường truyền:** TLS qua relay của UltraViewer; hai máy cùng LAN thì kết nối trực tiếp.
- **Phụ trợ:** chat, clipboard văn bản hai chiều, chụp màn hình + ghi chú, quay video phiên, nghe âm thanh của máy kia, lưu mật khẩu đối tác vào Keychain.

## Differences from upstream · Khác bản gốc

| Area | Upstream | This fork |
| --- | --- | --- |
| Operating system | macOS 14+ | macOS 13+ (deployment target 13.0; macOS 14 APIs replaced or availability-gated) |
| Relay certificate | System trust store — Ventura lacks the Sectigo R46 root, connection fails | R46 bundled as an additional trust anchor; system anchors and certificate-name pinning unchanged |
| Remote control | Off by default (view only) | On by default at connect (the host machine still decides permission) |
| Image quality | Default Automatic (45), sent only when the user changes it | Default Prefer quality (70), sent automatically at connect |
| Updates | Points at the upstream repo | Points at this repo; installs in place after matching the SHA-256 against the published checksum file; quarantine stripped from the staged copy, so no Gatekeeper prompt (from 3.0) |
| Unattended access | Not available | Auto-approves after the password proof matches; optional launch at login, sleep prevention while sharing (off by default) |
| Keyboard | US keycode | Adds VNI passthrough and Unicode text (Settings → Keyboard) |
| Host image | Truncated to RGB555; fixed 250 ms capture | Bayer 4×4 dithering; adaptive capture pacing 50–1000 ms |
| Password storage | Keychain with platform defaults | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Name / version | MacViewer | **MacViewer Ventura** / 4.0 and later (the fork's own version series) |

| Hạng mục | Bản gốc | Fork này |
| --- | --- | --- |
| Hệ điều hành | macOS 14+ | macOS 13+ (deployment target 13.0; API macOS 14 được thay thế hoặc bọc điều kiện) |
| Chứng thư relay | Dùng kho hệ thống — Ventura thiếu gốc Sectigo R46, kết nối thất bại | Nhúng R46 làm trust anchor bổ sung; giữ nguyên neo hệ thống và ghim tên chứng thư |
| Điều khiển từ xa | Mặc định tắt (chỉ xem) | Mặc định bật khi kết nối (máy host vẫn là bên quyết định quyền) |
| Chất lượng hình | Mặc định Tự động (45), chỉ gửi khi người dùng đổi tay | Mặc định Ưu tiên chất lượng (70), tự gửi khi kết nối |
| Cập nhật | Chiếu tới repo gốc | Trỏ về repo này; tự cài tại chỗ sau khi đối chiếu SHA-256 với bảng tổng công bố; gỡ quarantine khỏi bản mới nên không còn cảnh báo Gatekeeper (từ 3.0) |
| Truy cập không người trực | Không có | Tự duyệt sau khi bằng chứng mật khẩu khớp; tuỳ chọn mở cùng lúc đăng nhập, chống ngủ khi chia sẻ (mặc định tắt) |
| Bàn phím | Keycode US | Thêm VNI passthrough và văn bản Unicode (Cài đặt → Bàn phím) |
| Hình phía host | Cắt cụt về RGB555; chụp cố định mỗi 250 ms | Dithering Bayer 4×4; nhịp chụp thích ứng 50–1000 ms |
| Lưu mật khẩu | Keychain theo mặc định nền tảng | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Tên / phiên bản | MacViewer | **MacViewer Ventura** / 4.0 trở đi (dãy phiên bản riêng của fork) |

Ventura patch technical details: [VENTURA.md](VENTURA.md) · Chi tiết kỹ thuật bản vá Ventura: [VENTURA.md](VENTURA.md).

## Limits · Giới hạn

- No file transfer: the UltraViewer protocol has no file-transfer command (in progress for the Mac↔Mac case, see [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md)).
- Image color limited to RGB555 + JPEG atlas per the protocol; no RustDesk-style H.264/UDP video.
- Ventura as host: captured frames do not include the mouse cursor (legacy API limitation).
- Ad-hoc signed: first manual install opens via right-click → Open; in-app updates do not need this.

- Không truyền file: giao thức UltraViewer không có lệnh truyền file (đang làm cho trường hợp Mac↔Mac, xem [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md)).
- Màu hình giới hạn ở RGB555 + atlas JPEG theo giao thức; không có video H.264/UDP kiểu RustDesk.
- Máy Ventura làm host: ảnh chụp không kèm con trỏ chuột (giới hạn API cũ).
- App ký ad-hoc: lần cài đầu tiên mở bằng chuột phải → Open; cập nhật trong app thì không cần.

## Install · Cài đặt

1. Download `MacViewer-Ventura-<version>.dmg` (or `.zip`) from [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest). / Tải `MacViewer-Ventura-<phiên bản>.dmg` (hoặc `.zip`) ở [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest).
2. Drag `MacViewer.app` into **Applications**. / Kéo `MacViewer.app` vào thư mục **Applications**.
3. First launch: **right-click → Open → Open**. (Or: `xattr -dr com.apple.quarantine /Applications/MacViewer.app`) / Mở lần đầu: **chuột phải → Open → Open**. (Hoặc: `xattr -dr com.apple.quarantine /Applications/MacViewer.app`)
4. Host only: grant **Screen Recording** and **Accessibility** as prompted in the app. / Chỉ khi làm host: cấp quyền **Ghi màn hình** và **Trợ năng** theo hướng dẫn trong app.

Step-by-step details · Chi tiết từng bước: [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md).

## Updates · Cập nhật

The app checks this repo for new versions. When one is available, click **Update and Restart**: the app downloads it, verifies the SHA-256, installs in place and relaunches.

App tự kiểm tra bản mới tại repo này. Khi có bản mới, bấm **Cập nhật và khởi động lại**: app tải về, kiểm SHA-256, cài đè và tự mở lại.

## Documentation · Tài liệu

- [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md) — install, permissions, usage · cài đặt, cấp quyền, sử dụng
- [VENTURA.md](VENTURA.md) — Ventura patch technical details · chi tiết kỹ thuật bản vá Ventura
- [SECURITY_AUDIT.md](SECURITY_AUDIT.md) — security audit · rà soát bảo mật
- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) — feature roadmap, measured limits · lộ trình tính năng, giới hạn đã đo

## Building from source · Build từ mã nguồn

The build machine needs macOS 14.5+ and Xcode 16 (the built app runs on macOS 13+). GitHub Actions runs the full test suite and packages a universal build on every push to `main`. See [VENTURA.md](VENTURA.md).

Máy build cần macOS 14.5+ và Xcode 16 (app build ra chạy trên macOS 13+). GitHub Actions chạy toàn bộ test và đóng gói bản universal mỗi lần push lên `main`. Xem [VENTURA.md](VENTURA.md).

## Privacy · Quyền riêng tư

No data collection. Update checks only read public information on GitHub (can be disabled in Settings). Passwords are stored in Keychain only when the user opts in; connection history stores IDs only.

Không thu thập dữ liệu. Kiểm tra cập nhật chỉ đọc thông tin công khai trên GitHub (tắt được trong Cài đặt). Mật khẩu chỉ lưu vào Keychain khi người dùng chọn; lịch sử kết nối chỉ lưu ID.

## License · Giấy phép

MIT, unchanged from upstream. Third-party libraries keep their own licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The `8bit.dat` file is UltraViewer data and is not covered by MIT. UltraViewer is a trademark of its respective owner.

MIT, giữ nguyên của dự án gốc. Thư viện bên thứ ba giữ giấy phép riêng: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). File `8bit.dat` là dữ liệu của UltraViewer, không thuộc MIT. UltraViewer là thương hiệu của chủ sở hữu tương ứng.
