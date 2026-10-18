<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="MacViewer Ventura app icon · Biểu tượng MacViewer Ventura">

# MacViewer Ventura

**An UltraViewer client for macOS: control a Windows machine from your Mac, and vice versa.**
**Client UltraViewer cho macOS: điều khiển máy Windows từ máy Mac, và ngược lại.**

[Download the latest release · Tải bản mới nhất](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest) · macOS 13 Ventura+ · Intel + Apple Silicon

[![Release](https://img.shields.io/github/v/release/ArtyormSatori/MacViewer-Ventura)](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6-orange)

Tài liệu hai phần · Documentation in two parts: [Tiếng Việt](#tổng-quan) · [English](#english)

<img src="docs/images/main-window-vi.png" width="820" alt="MacViewer Ventura main window">
<br><sub>Main window (Vietnamese UI) · Giao diện chính (bản tiếng Việt)</sub>

</div>

## Tổng quan

MacViewer Ventura là client macOS mã nguồn mở cho UltraViewer — phần mềm điều khiển máy tính từ xa chỉ có bản Windows. MacViewer Ventura chạy trên **macOS 13 Ventura trở lên** (Intel và Apple Silicon). Không phải sản phẩm chính thức của UltraViewer; chỉ kết nối tới máy bạn được phép truy cập.

## App làm gì

- **Viewer:** nhập ID + mật khẩu của máy đang chạy UltraViewer/MacViewer → xem màn hình, điều khiển chuột và bàn phím.
- **Host:** cho máy khác kết nối vào máy Mac, sau khi chủ máy duyệt (quyền xem và quyền điều khiển cấp riêng).
- **Đường truyền:** TLS qua relay của UltraViewer; hai máy cùng LAN thì kết nối trực tiếp.
- **Phụ trợ:** chat, clipboard văn bản hai chiều, chụp màn hình + ghi chú, quay video phiên, nghe âm thanh của máy kia, lưu mật khẩu đối tác vào Keychain.

## Điểm nổi bật

- **Chạy trên macOS 13 Ventura** (deployment target 13.0) — Intel và Apple Silicon.
- **Chứng thư relay nhúng sẵn:** chứng thư gốc Sectigo R46 được nhúng làm trust anchor bổ sung, nên máy Ventura kết nối relay ngay mà không cần nạp chứng thư thủ công; neo hệ thống và cơ chế ghim tên chứng thư giữ nguyên.
- **Điều khiển bật mặc định** khi kết nối (máy host vẫn là bên quyết định quyền).
- **Chất lượng hình Ưu tiên chất lượng (70)** tự áp dụng khi kết nối.
- **Tự cập nhật trong app:** đối chiếu SHA-256 với bảng tổng công bố, cài đè tại chỗ và tự mở lại; không còn cảnh báo Gatekeeper đối với bản cài qua app (từ 3.0).
- **Truy cập không người trực** (mặc định tắt): tự duyệt sau khi bằng chứng mật khẩu khớp; tuỳ chọn mở cùng lúc đăng nhập và chống ngủ khi chia sẻ.
- **Bàn phím:** keycode US, VNI passthrough, văn bản Unicode (Cài đặt → Bàn phím).
- **Hình phía host:** dithering Bayer 4×4; nhịp chụp thích ứng 50–1000 ms.
- **Mật khẩu đối tác** lưu Keychain với mức `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Chi tiết kỹ thuật: [VENTURA.md](VENTURA.md).

## Giới hạn

- Không truyền file: giao thức UltraViewer không có lệnh truyền file (đang làm cho trường hợp Mac↔Mac, xem [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md)).
- Màu hình giới hạn ở RGB555 + atlas JPEG theo giao thức; không có video H.264/UDP kiểu RustDesk.
- Máy Ventura làm host: ảnh chụp không kèm con trỏ chuột (giới hạn API cũ).
- App ký ad-hoc: lần cài đầu tiên mở bằng chuột phải → Open; cập nhật trong app thì không cần.

## Cài đặt

1. Tải `MacViewer-Ventura-<phiên bản>.dmg` (hoặc `.zip`) ở [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest).
2. Kéo `MacViewer.app` vào thư mục **Applications**.
3. Mở lần đầu: **chuột phải → Open → Open**. (Hoặc: `xattr -dr com.apple.quarantine /Applications/MacViewer.app`)
4. Chỉ khi làm host: cấp quyền **Ghi màn hình** và **Trợ năng** theo hướng dẫn trong app.

Chi tiết từng bước: [readme.txt](readme.txt).

## Cập nhật

App tự kiểm tra bản mới tại repo này. Khi có bản mới, bấm **Cập nhật và khởi động lại**: app tải về, kiểm SHA-256, cài đè và tự mở lại.

## Tài liệu

- [readme.txt](readme.txt) — cài đặt, cấp quyền, sử dụng
- [VENTURA.md](VENTURA.md) — chi tiết kỹ thuật
- [SECURITY_AUDIT.md](SECURITY_AUDIT.md) — rà soát bảo mật
- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) — lộ trình tính năng, giới hạn đã đo

## Build từ mã nguồn

Máy build cần macOS 14.5+ và Xcode 16 (app build ra chạy trên macOS 13+). GitHub Actions chạy toàn bộ test và đóng gói bản universal mỗi lần push lên `main`. Xem [VENTURA.md](VENTURA.md).

## Quyền riêng tư

Không thu thập dữ liệu. Kiểm tra cập nhật chỉ đọc thông tin công khai trên GitHub (tắt được trong Cài đặt). Mật khẩu chỉ lưu vào Keychain khi người dùng chọn; lịch sử kết nối chỉ lưu ID.

## Giấy phép

Dựa trên dự án mã nguồn mở MacViewer của DeanOpen.

Giấy phép MIT — xem [LICENSE](LICENSE). Thư viện bên thứ ba giữ giấy phép riêng: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). File `8bit.dat` là dữ liệu của UltraViewer, không thuộc MIT. UltraViewer là thương hiệu của chủ sở hữu tương ứng.

---

## English

## Overview

MacViewer Ventura is an open-source macOS client for UltraViewer — remote-control software that ships for Windows only. MacViewer Ventura runs on **macOS 13 Ventura and later** (Intel and Apple Silicon). Not an official UltraViewer product; connect only to machines you are permitted to access.

## What the app does

- **Viewer:** enter the ID + password of a machine running UltraViewer/MacViewer → view its screen, control mouse and keyboard.
- **Host:** let another machine connect to this Mac after the owner approves (view and control permissions granted separately).
- **Transport:** TLS via UltraViewer's relay; machines on the same LAN connect directly.
- **Extras:** chat, two-way text clipboard, screenshot + annotation, session video recording, remote audio playback, partner passwords stored in Keychain.

## Highlights

- **Runs on macOS 13 Ventura** (deployment target 13.0) — Intel and Apple Silicon.
- **Relay certificate bundled:** the Sectigo R46 root is embedded as an additional trust anchor, so Ventura machines connect to the relay with no manual certificate step; system anchors and certificate-name pinning are unchanged.
- **Control on by default** at connect (the host machine still decides permission).
- **Prefer-quality image (70)** applied automatically at connect.
- **In-app updates:** the download is matched against the published SHA-256 checksums, installed in place and relaunched; no Gatekeeper prompt for app-installed updates (from 3.0).
- **Unattended access** (off by default): auto-approves once the password proof matches; optional launch at login and sleep prevention while sharing.
- **Keyboard:** US keycode, VNI passthrough, Unicode text (Settings → Keyboard).
- **Host image:** Bayer 4×4 dithering; adaptive capture pacing 50–1000 ms.
- **Partner passwords** stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Technical details: [VENTURA.md](VENTURA.md).

## Limits

- No file transfer: the UltraViewer protocol has no file-transfer command (in progress for the Mac↔Mac case, see [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md)).
- Image color limited to RGB555 + JPEG atlas per the protocol; no RustDesk-style H.264/UDP video.
- Ventura as host: captured frames do not include the mouse cursor (legacy API limitation).
- Ad-hoc signed: first manual install opens via right-click → Open; in-app updates do not need this.

## Install

1. Download `MacViewer-Ventura-<version>.dmg` (or `.zip`) from [Releases](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest).
2. Drag `MacViewer.app` into **Applications**.
3. First launch: **right-click → Open → Open**. (Or: `xattr -dr com.apple.quarantine /Applications/MacViewer.app`)
4. Host only: grant **Screen Recording** and **Accessibility** as prompted in the app.

Step-by-step details: [readme.txt](readme.txt).

## Updates

The app checks this repo for new versions. When one is available, click **Update and Restart**: the app downloads it, verifies the SHA-256, installs in place and relaunches.

## Documentation

- [readme.txt](readme.txt) — install, permissions, usage
- [VENTURA.md](VENTURA.md) — technical details
- [SECURITY_AUDIT.md](SECURITY_AUDIT.md) — security audit
- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) — feature roadmap, measured limits

## Building from source

The build machine needs macOS 14.5+ and Xcode 16 (the built app runs on macOS 13+). GitHub Actions runs the full test suite and packages a universal build on every push to `main`. See [VENTURA.md](VENTURA.md).

## Privacy

No data collection. Update checks only read public information on GitHub (can be disabled in Settings). Passwords are stored in Keychain only when the user opts in; connection history stores IDs only.

## License

Based on the open-source MacViewer project by DeanOpen.

MIT license — see [LICENSE](LICENSE). Third-party libraries keep their own licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The `8bit.dat` file is UltraViewer data and is not covered by MIT. UltraViewer is a trademark of its respective owner.
