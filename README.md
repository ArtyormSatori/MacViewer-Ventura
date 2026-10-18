<div align="center">

<img src="docs/images/app-icon.png" width="128" alt="Biểu tượng MacViewer">

# MacViewer Ventura

**Điều khiển máy Windows chạy UltraViewer ngay từ máy Mac Ventura của bạn — và cho người khác truy cập máy Mac của bạn khi bạn đồng ý.**

**Tiếng Việt** · [English](README.en.md)

### [Tải bản mới nhất cho macOS Ventura](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)

Chạy trên **macOS 13 Ventura** (cả máy Intel và Apple Silicon)

[![Release](https://img.shields.io/github/v/release/ArtyormSatori/MacViewer-Ventura)](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%20Ventura-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

</div>

---

Repo này là bản fork của [DeanOpen/MacViewer](https://github.com/DeanOpen/MacViewer) (bản gốc 0.3.4), được vá để **chạy trên macOS 13 Ventura** — bản gốc yêu cầu macOS 14 nên máy Ventura không mở được. Toàn bộ tính năng của bản gốc được giữ nguyên; các thay đổi dành riêng cho Ventura được ghi trong [VENTURA.md](VENTURA.md).

[UltraViewer](https://ultraviewer.net/vi/) chỉ có bản cho Windows. MacViewer là ứng dụng macOS thuần viết bằng SwiftUI/AppKit, không cần Wine và không chạy bất kỳ file `.exe` nào của Windows.

> [!IMPORTANT]
> Đây là dự án mã nguồn mở, **không phải** sản phẩm chính thức của UltraViewer và không liên quan đến đội ngũ phát triển UltraViewer. Chỉ kết nối tới những máy mà bạn được phép truy cập.

## Ứng dụng gốc: MacViewer của DeanOpen là gì?

**MacViewer** là ứng dụng macOS mã nguồn mở do **DeanOpen** phát triển, đưa khả năng của UltraViewer — phần mềm điều khiển máy tính từ xa vốn **chỉ có trên Windows** — lên máy Mac, mà không cần Wine hay chạy file `.exe` nào.

App dùng để làm gì:

- **Điều khiển máy khác từ máy Mac của bạn:** nhập **ID và mật khẩu** đang hiển thị trên UltraViewer (hoặc MacViewer) của máy kia là bạn thấy màn hình của họ và điều khiển được chuột, bàn phím — như đang ngồi trước máy đó. Đây là cách phổ biến để hỗ trợ kỹ thuật, sửa máy từ xa cho người thân, đồng nghiệp.
- **Cho người khác truy cập máy Mac của bạn:** khi bạn cho phép, người kia xem được màn hình máy Mac của bạn và điều khiển nó, sau khi bạn bấm đồng ý trên máy của mình.
- Kết nối được **mã hóa** và đi qua máy chủ trung gian (relay) của UltraViewer; hai máy cùng mạng LAN thì kết nối trực tiếp cho nhanh.
- Kèm theo: **chat** với người bên kia, **đồng bộ clipboard** văn bản hai chiều, chụp màn hình có ghi chú, **quay video** phiên điều khiển, và lưu mật khẩu đối tác vào **Keychain** của macOS cho lần kết nối sau.

Dự án gốc: [github.com/DeanOpen/MacViewer](https://github.com/DeanOpen/MacViewer) — bản gốc (0.3.4) yêu cầu **macOS 14 Sonoma trở lên**. Toàn bộ phần giao thức, giao diện và tính năng nền của app là công sức của tác giả gốc; bản fork này đứng trên đó và chỉ thay đổi những gì cần thiết cho Ventura cùng vài cải tiến bên dưới.

## Bản fork MacViewer Ventura thêm gì, sửa gì

- **Tên và số phiên bản riêng, dễ nhớ**: app mang tên **MacViewer Ventura** và dùng dãy phiên bản riêng **4.0, 4.1, …** — mỗi lần cập nhật là một số phiên bản mới rõ ràng. (Ba bản đầu từng phát hành dưới tên ventura.1/.2/.3; nền kỹ thuật bên dưới vẫn là MacViewer 0.3.4 của DeanOpen.)
- **Chạy được trên macOS 13 Ventura** (bản gốc đòi macOS 14).
- **Không cần nạp chứng thư vào Keychain nữa**: chứng thư gốc Sectigo R46 mà máy chủ UltraViewer dùng (kho tin cậy của Ventura chưa có) đã được nhúng sẵn trong app — cài là kết nối được ngay.
- **Điều khiển bật sẵn**: kết nối tới máy Windows là điều khiển được ngay, không phải bật tay công tắc Điều khiển nữa (máy kia vẫn là bên quyết định cho phép hay không).
- **Chất lượng hình mặc định "Ưu tiên chất lượng"** và tự áp dụng ngay khi kết nối.
- **Tự cập nhật ngay trong app, không còn cảnh báo "nhà phát triển chưa xác định"**: từ bản ventura.3, app tự tải bản mới, đối chiếu mã SHA-256 với bảng tổng đã công bố, cài đè và tự mở lại. (Riêng lần cài ventura.3 vẫn cần mở tay một lần như mục Cài đặt bên dưới.)
- **Truy cập không cần người ngồi máy** (khi máy Mac làm máy chủ): tự duyệt sau khi mật khẩu đã được xác minh, có thể bật khởi động cùng máy và ngăn máy ngủ khi đang chia sẻ.
- **Bàn phím tiếng Việt**: thêm chế độ gõ VNI và chế độ văn bản Unicode bên cạnh chế độ phím US truyền thống (Cài đặt → Bàn phím).
- **Hình mượt hơn trong giới hạn giao thức**: dithering Bayer khi quy về màu 16-bit của giao thức và nhịp chụp màn hình thích ứng phía máy chủ.

## Tính năng

### Kết nối tới máy khác

- Nhập **ID và mật khẩu** hiện trên UltraViewer của máy kia là kết nối được
- Kết nối được mã hóa, đi qua máy chủ trung gian có TLS; nếu hai máy cùng mạng LAN thì tự kết nối trực tiếp cho nhanh
- Điều khiển chuột, bàn phím; phím được chuyển đổi sẵn: <kbd>⌘</kbd> → Win, <kbd>⌥</kbd> → Alt, <kbd>⌃</kbd> → Ctrl; cuộn bằng trackpad hay chuột đều được
- Thanh công cụ: chọn màn hình, thu phóng, chất lượng hình, ẩn/hiện hình nền, con trỏ chuột và **nghe âm thanh từ máy kia**
- Chụp màn hình (chọn vùng, ghi chú lên ảnh) và **quay video**
- **Chat** với người bên kia và đồng bộ **clipboard** văn bản hai chiều (có thể tắt trong Cài đặt)
- Có thể lưu mật khẩu vào **Keychain** của macOS cho lần sau

### Cho người khác truy cập máy Mac

- Người khác chỉ xem hoặc điều khiển được sau khi bạn bấm đồng ý trên máy Mac (hoặc tự động khi bạn bật truy cập không cần người ngồi máy và mật khẩu khớp)
- Có hướng dẫn từng bước để bật quyền **Ghi màn hình** và **Trợ năng**
- Quyền xem và quyền điều khiển được duyệt riêng; ngắt kết nối hoặc khóa truy cập bất cứ lúc nào

### Chưa hỗ trợ

- Gửi file (giao thức UltraViewer không có lệnh truyền file; đang nằm trong [lộ trình](FEATURE_ROADMAP.md) cho trường hợp cả hai đầu đều là MacViewer)
- Nói chuyện qua micro, phát âm thanh khi chia sẻ máy Mac, chia sẻ nhiều màn hình Mac cùng lúc
- Chất lượng hình kiểu RustDesk (video H.264/UDP) — không thể đạt được qua giao thức UltraViewer

## Cài đặt

Hướng dẫn đầy đủ, có hình dung từng bước: **[HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md)**. Tóm tắt:

1. Vào trang [**Releases**](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest) và tải file `MacViewer-Ventura-<phiên bản>.dmg` (hoặc `.zip`).
2. Mở file DMG, kéo **MacViewer** thả vào thư mục **Applications**.
3. Lần đầu mở: nhấp **chuột phải** vào MacViewer → **Open** → **Open** (bản build ký ad-hoc nên macOS hỏi một lần). Hoặc chạy lệnh: `xattr -dr com.apple.quarantine /Applications/MacViewer.app`
4. Cấp quyền **Ghi màn hình** và **Trợ năng** khi app hướng dẫn (chỉ cần khi bạn cho người khác truy cập máy Mac của bạn).

Từ bản ventura.3 trở đi, khi có bản mới app sẽ tự báo và tự cài — bạn không cần lặp lại các bước trên. Bản 4.0 này chính là bản cập nhật đầu tiên được giao qua cơ chế đó cho máy đã cài ventura.3.

## Tài liệu

- [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md) — cài đặt, cấp quyền, sử dụng, gỡ chứng thư cũ
- [VENTURA.md](VENTURA.md) — đã thay đổi những gì để chạy trên Ventura, và vì sao
- [SECURITY_AUDIT.md](SECURITY_AUDIT.md) — rà soát bảo mật toàn bộ mã nguồn
- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md) — lộ trình tính năng và các giới hạn kỹ thuật đã đo

## Build từ mã nguồn

Xem mục "Build từ mã nguồn" trong [VENTURA.md](VENTURA.md). Lưu ý: máy *build* cần macOS 14.5+ và Xcode 16 (Xcode không chạy trên Ventura); app build ra chạy trên Ventura. Mỗi lần push lên `main`, GitHub Actions tự chạy toàn bộ test, đóng gói bản universal và đăng lên Releases.

## Quyền riêng tư

MacViewer không thu thập bất kỳ dữ liệu nào. Khi kiểm tra bản cập nhật, ứng dụng chỉ đọc thông tin phiên bản công khai trên GitHub (có thể tắt trong Cài đặt). Mật khẩu chỉ được lưu khi bạn chọn ghi nhớ, và chỉ lưu trong Keychain của macOS. Lịch sử kết nối chỉ lưu ID, không bao giờ lưu mật khẩu.

## Giấy phép

MacViewer phát hành theo [giấy phép MIT](LICENSE) — giữ nguyên của dự án gốc [DeanOpen/MacViewer](https://github.com/DeanOpen/MacViewer).

Các thư viện bên thứ ba vẫn giữ giấy phép riêng của chúng, xem [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). File `8bit.dat` là dữ liệu lấy từ UltraViewer và **không** thuộc giấy phép MIT.

UltraViewer là thương hiệu của chủ sở hữu tương ứng, chỉ được nhắc đến ở đây để nói rõ khả năng tương thích.
