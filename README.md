<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Biểu tượng MacViewer Ventura">

# MacViewer Ventura

**Client UltraViewer cho macOS: điều khiển máy Windows từ máy Mac, và ngược lại.**

[Tải bản mới nhất](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest) · macOS 13 Ventura trở lên · Intel + Apple Silicon

[![Release](https://img.shields.io/github/v/release/ArtyormSatori/MacViewer-Ventura)](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6-orange)

**Tiếng Việt** · [English](README.en.md)

<img src="docs/images/main-window-vi.png" width="820" alt="Giao diện chính của MacViewer Ventura">

</div>

## Tổng quan

Fork của [MacViewer 0.3.4](https://github.com/DeanOpen/MacViewer) (tác giả DeanOpen). MacViewer là client macOS mã nguồn mở cho UltraViewer — phần mềm điều khiển máy tính từ xa chỉ có bản Windows. Fork này hạ yêu cầu hệ điều hành từ macOS 14 xuống **macOS 13** và bổ sung các thay đổi ở bảng "Khác bản gốc". Không phải sản phẩm chính thức của UltraViewer; chỉ kết nối tới máy bạn được phép truy cập.

## App làm gì

- **Viewer:** nhập ID + mật khẩu của máy đang chạy UltraViewer/MacViewer → xem màn hình, điều khiển chuột và bàn phím.
- **Host:** cho máy khác kết nối vào máy Mac, sau khi chủ máy duyệt (quyền xem và quyền điều khiển cấp riêng).
- **Đường truyền:** TLS qua relay của UltraViewer; hai máy cùng LAN thì kết nối trực tiếp.
- **Phụ trợ:** chat, clipboard văn bản hai chiều, chụp màn hình + ghi chú, quay video phiên, nghe âm thanh của máy kia, lưu mật khẩu đối tác vào Keychain.

## Khác bản gốc

| Hạng mục | Bản gốc 0.3.4 | Fork này |
| --- | --- | --- |
| Hệ điều hành | macOS 14+ | macOS 13+ (deployment target 13.0; API macOS 14 được thay thế hoặc bọc điều kiện) |
| Chứng thư relay | Dùng kho hệ thống — Ventura thiếu gốc Sectigo R46, kết nối thất bại | Nhúng R46 làm trust anchor bổ sung; giữ nguyên neo hệ thống và ghim tên chứng thư |
| Điều khiển từ xa | Mặc định tắt (chỉ xem) | Mặc định bật khi kết nối (máy host vẫn là bên quyết định quyền) |
| Chất lượng hình | Mặc định Tự động (45), chỉ gửi khi người dùng đổi tay | Mặc định Ưu tiên chất lượng (70), tự gửi khi kết nối |
| Cập nhật | Chiếu tới repo gốc | Trỏ về repo này; tự cài tại chỗ sau khi đối chiếu SHA-256 với bảng tổng công bố; gỡ quarantine khỏi bản mới nên không còn cảnh báo Gatekeeper (từ ventura.3) |
| Truy cập không người trực | Không có | Tự duyệt sau khi bằng chứng mật khẩu khớp; tuỳ chọn mở cùng lúc đăng nhập, chống ngủ khi chia sẻ (mặc định tắt) |
| Bàn phím | Keycode US | Thêm VNI passthrough và văn bản Unicode (Cài đặt → Bàn phím) |
| Hình phía host | Cắt cụt về RGB555; chụp cố định mỗi 250 ms | Dithering Bayer 4×4; nhịp chụp thích ứng 50–1000 ms |
| Lưu mật khẩu | Keychain theo mặc định nền tảng | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Tên / phiên bản | MacViewer / 0.3.4 | **MacViewer Ventura** / 4.0 trở đi (nền kỹ thuật giữ nguyên 0.3.4) |

Chi tiết kỹ thuật bản vá Ventura: [VENTURA.md](VENTURA.md).

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

Chi tiết từng bước: [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md).

## Cập nhật

App tự kiểm tra bản mới tại repo này. Khi có bản mới, bấm **Cập nhật và khởi động lại**: app tải về, kiểm SHA-256, cài đè và tự mở lại.

## Tài liệu

- [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md) — cài đặt, cấp quyền, sử dụng
- [VENTURA.md](VENTURA.md) — chi tiết kỹ thuật bản vá Ventura
- [SECURITY_AUDIT.md](SECURITY_AUDIT.md) — rà soát bảo mật
- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) — lộ trình tính năng, giới hạn đã đo

## Build từ mã nguồn

Máy build cần macOS 14.5+ và Xcode 16 (app build ra chạy trên macOS 13+). GitHub Actions chạy toàn bộ test và đóng gói bản universal mỗi lần push lên `main`. Xem [VENTURA.md](VENTURA.md).

## Quyền riêng tư

Không thu thập dữ liệu. Kiểm tra cập nhật chỉ đọc thông tin công khai trên GitHub (tắt được trong Cài đặt). Mật khẩu chỉ lưu vào Keychain khi người dùng chọn; lịch sử kết nối chỉ lưu ID.

## Giấy phép

MIT, giữ nguyên của dự án gốc. Thư viện bên thứ ba giữ giấy phép riêng: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). File `8bit.dat` là dữ liệu của UltraViewer, không thuộc MIT. UltraViewer là thương hiệu của chủ sở hữu tương ứng.
