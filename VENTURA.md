# MacViewer cho macOS 13 Ventura

Repo này là bản build lại của [DeanOpen/MacViewer](https://github.com/DeanOpen/MacViewer)
(tại commit `f8d1b6529e673df3fe35fccdd4b65f7474e354b7`) để chạy được trên
**macOS 13 Ventura**. Bản gốc yêu cầu macOS 14 Sonoma ở mọi tầng, nên máy
Ventura báo: *"Bạn không thể sử dụng phiên bản này của ứng dụng
"MacViewer.app" với phiên bản macOS này."* — dòng chữ "hỗ trợ Apple Silicon
và Intel" trong README gốc nói về kiến trúc CPU (universal binary), không
phải về phiên bản macOS.

Tải bản đã build sẵn ở mục **Releases** của repo này:
`MacViewer-0.3.4-Ventura.dmg` hoặc `.zip` (universal: arm64 + x86_64).

## Đã thay đổi những gì (và vì sao)

Mọi API dưới đây đều được đối chiếu với tài liệu chính thức của Apple
(platform availability trong Apple Developer Documentation):

| Chỗ chặn Ventura | API / khai báo | Có từ macOS | Cách xử lý trong bản này |
|---|---|---|---|
| `Package.swift` | `platforms: [.macOS(.v14)]` | — | Hạ xuống `.v13` |
| `scripts/package_app.sh` | `LSMinimumSystemVersion = 14.0` trong Info.plist (đây là dòng khiến macOS từ chối mở app) | — | Hạ xuống `13.0` |
| `MacScreenCapture.swift` | `SCScreenshotManager.captureImage` | 14.0 | Trên macOS 14+ giữ nguyên; trên Ventura dùng `CGDisplayCreateImage` (vẫn trả nội dung thật trên 13 sau khi cấp quyền Ghi màn hình) rồi thu nhỏ về kích thước đích |
| `MacScreenCapture.swift` | `SCContentFilter.pointPixelScale`, `SCContentFilter.contentRect` | 14.0 | Lấy kích thước pixel từ CoreGraphics (`CGDisplayPixelsWide/High`) — `DisplayKey` vốn đã lưu sẵn hai giá trị này |
| `MacScreenCapture.swift` | `SCStreamConfiguration.preservesAspectRatio` | 14.0 | Chỉ đặt khi `#available(macOS 14.0, *)` |
| 4 file giao diện, 10 chỗ | `.onChange(of:) { _, new in … }` (closure hai tham số) | 14.0 | Quay về dạng một tham số `{ new in … }` (có từ macOS 11, vẫn biên dịch được trên 14+) |
| `FramedTCPTransport.swift` | Kho chứng thư hệ thống của Ventura chưa có chứng thư gốc Sectigo R46 mà relay UltraViewer dùng (Apple bổ sung vào kho tin cậy từ macOS 14.4) — app kiểm chứng thư bằng kho hệ thống nên kết nối relay bị đánh rớt trên Ventura | 14.4 (kho chứng thư) | Nhúng chứng thư gốc R46 vào app, cộng thêm làm trust anchor khi kiểm chứng thư relay (vẫn giữ neo hệ thống và kiểm tra đúng tên chứng thư như bản gốc) |
| `UpdateChecker.swift` | Tự kiểm tra cập nhật ở repo gốc | — | Trỏ về Releases của repo này, để app không tự "cập nhật" trở lại bản macOS 14 rồi hỏng tiếp |

Các API còn lại đều tương thích Ventura (đã kiểm chứng):
`Scene.defaultSize` (13.0), `LabeledContent` (13.0), `FormStyle.grouped`
(13.0), `SCStreamConfiguration.capturesAudio` (13.0), `scalesToFit` (12.3),
`SCShareableContent`/`SCStream` (12.3).

## Giới hạn đã biết trên Ventura

- Khi **chia sẻ màn hình máy Mac này cho người khác xem** (chiều host),
  đường chụp Ventura dùng API cũ: ảnh chụp không kèm con trỏ chuột.
  Chiều chính — **điều khiển máy Windows chạy UltraViewer từ máy Mac** —
  không dùng đường chụp này, hoạt động đầy đủ.
- Bản build ký **ad-hoc** (giống bản gốc khi không có chứng chỉ Developer
  ID): khi cài thủ công, lần đầu mở cần nhấp chuột phải vào app → **Open**,
  hoặc chạy `xattr -dr com.apple.quarantine /Applications/MacViewer.app`.
  Từ ventura.3, các bản cập nhật do app tự cài (có đối chiếu SHA-256) sẽ
  không còn gặp bước này.
- File nhị phân `Sources/UltraViewerProtocol/Resources/8bit.dat` (112 KB,
  từ điển Zstandard của giao thức, giấy phép theo repo gốc) không lưu trong
  repo này; các workflow tự tải nó từ repo gốc tại đúng commit trên và kiểm
  tra SHA-256 (`9aa45789…bfe6b`) trước khi build.

## Build từ mã nguồn

Bản đã build sẵn nằm ở Releases. Nếu muốn tự build, cần một máy Mac chạy
macOS 14.5+ với Xcode 16 (chỉ máy *build* mới cần Sonoma — Xcode 16 không
chạy trên Ventura; app build ra chạy trên Ventura):

```sh
git clone https://github.com/ArtyormSatori/MacViewer-Ventura.git
cd MacViewer-Ventura
curl -fL -o Sources/UltraViewerProtocol/Resources/8bit.dat \
  https://raw.githubusercontent.com/DeanOpen/MacViewer/f8d1b6529e673df3fe35fccdd4b65f7474e354b7/Sources/UltraViewerProtocol/Resources/8bit.dat
MACVIEWER_UNIVERSAL=1 scripts/package_app.sh release
open dist/MacViewer.app
```

Trên GitHub, workflow **Ventura Build & Release** tự chạy mỗi lần push lên
`main`: test → đóng gói universal → đăng DMG/ZIP vào release
ventura mới nhất (`v0.3.4-ventura.N`), đồng thời lưu log build ở release `ci-logs`.

## Giấy phép

Giữ nguyên giấy phép MIT của dự án gốc; các thư viện bên thứ ba giữ giấy
phép riêng (xem `THIRD_PARTY_NOTICES.md` trong repo gốc).
