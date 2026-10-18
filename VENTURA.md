# MacViewer Ventura — Ghi chú kỹ thuật macOS 13 · Technical notes for macOS 13

Tài liệu này mô tả những thay đổi kỹ thuật giúp MacViewer Ventura chạy trên **macOS 13 Ventura**. Một bản dựng đặt mức hệ điều hành tối thiểu là macOS 14 sẽ bị Ventura từ chối mở với thông báo: *"Bạn không thể sử dụng phiên bản này của ứng dụng "MacViewer.app" với phiên bản macOS này."* Các thay đổi gồm: hạ mức tối thiểu xuống 13.0, thay thế hoặc bọc điều kiện các API chỉ có từ macOS 14, và nhúng chứng thư gốc Sectigo R46 vào app.

Tải bản đã build sẵn ở mục **Releases** của repo này: `MacViewer-Ventura-<phiên bản>.dmg` hoặc `.zip` (universal: arm64 + x86_64).

## Đã thay đổi những gì (và vì sao)

Mọi API dưới đây đều được đối chiếu với tài liệu chính thức của Apple (platform availability trong Apple Developer Documentation):

| Chỗ chặn Ventura | API / khai báo | Có từ macOS | Cách xử lý trong bản này |
|---|---|---|---|
| `Package.swift` | `platforms: [.macOS(.v14)]` | — | Hạ xuống `.v13` |
| `scripts/package_app.sh` | `LSMinimumSystemVersion = 14.0` trong Info.plist (đây là dòng khiến macOS từ chối mở app) | — | Hạ xuống `13.0` |
| `MacScreenCapture.swift` | `SCScreenshotManager.captureImage` | 14.0 | Trên macOS 14+ giữ nguyên; trên Ventura dùng `CGDisplayCreateImage` (vẫn trả nội dung thật trên 13 sau khi cấp quyền Ghi màn hình) rồi thu nhỏ về kích thước đích |
| `MacScreenCapture.swift` | `SCContentFilter.pointPixelScale`, `SCContentFilter.contentRect` | 14.0 | Lấy kích thước pixel từ CoreGraphics (`CGDisplayPixelsWide/High`) — `DisplayKey` vốn đã lưu sẵn hai giá trị này |
| `MacScreenCapture.swift` | `SCStreamConfiguration.preservesAspectRatio` | 14.0 | Chỉ đặt khi `#available(macOS 14.0, *)` |
| 4 file giao diện, 10 chỗ | `.onChange(of:) { _, new in … }` (closure hai tham số) | 14.0 | Quay về dạng một tham số `{ new in … }` (có từ macOS 11, vẫn biên dịch được trên 14+) |
| `FramedTCPTransport.swift` | Kho chứng thư hệ thống của Ventura chưa có chứng thư gốc Sectigo R46 mà relay UltraViewer dùng (Apple bổ sung vào kho tin cậy từ macOS 14.4) — app kiểm chứng thư bằng kho hệ thống nên kết nối relay bị đánh rớt trên Ventura | 14.4 (kho chứng thư) | Nhúng chứng thư gốc R46 vào app, cộng thêm làm trust anchor khi kiểm chứng thư relay (vẫn giữ neo hệ thống và kiểm tra đúng tên chứng thư) |
| `UpdateChecker.swift` | Tự kiểm tra cập nhật | — | Trỏ về Releases của repo này, để app luôn cập nhật lên bản chạy được trên Ventura |

Các API còn lại đều tương thích Ventura (đã kiểm chứng): `Scene.defaultSize` (13.0), `LabeledContent` (13.0), `FormStyle.grouped` (13.0), `SCStreamConfiguration.capturesAudio` (13.0), `scalesToFit` (12.3), `SCShareableContent`/`SCStream` (12.3).

## Giới hạn đã biết trên Ventura

- Khi **chia sẻ màn hình máy Mac này cho người khác xem** (chiều host), đường chụp Ventura dùng API cũ: ảnh chụp không kèm con trỏ chuột. Chiều chính — **điều khiển máy Windows chạy UltraViewer từ máy Mac** — không dùng đường chụp này, hoạt động đầy đủ.
- Bản build ký **ad-hoc** (không có chứng chỉ Developer ID): khi cài thủ công, lần đầu mở cần nhấp chuột phải vào app → **Open**, hoặc chạy `xattr -dr com.apple.quarantine /Applications/MacViewer.app`. Từ bản 3.0, các bản cập nhật do app tự cài (có đối chiếu SHA-256) sẽ không còn gặp bước này.
- File nhị phân `Sources/UltraViewerProtocol/Resources/8bit.dat` (112 KB, từ điển Zstandard của giao thức) không lưu trong repo này; các workflow tự tải nó tại một commit cố định và kiểm tra SHA-256 (`9aa45789…bfe6b`) trước khi build.

## Build từ mã nguồn

Bản đã build sẵn nằm ở Releases. Nếu muốn tự build, cần một máy Mac chạy macOS 14.5+ với Xcode 16 (chỉ máy *build* mới cần Sonoma — Xcode 16 không chạy trên Ventura; app build ra chạy trên Ventura):

```sh
git clone https://github.com/ArtyormSatori/MacViewer-Ventura.git
cd MacViewer-Ventura
curl -fL -o Sources/UltraViewerProtocol/Resources/8bit.dat \
  https://raw.githubusercontent.com/DeanOpen/MacViewer/f8d1b6529e673df3fe35fccdd4b65f7474e354b7/Sources/UltraViewerProtocol/Resources/8bit.dat
MACVIEWER_UNIVERSAL=1 scripts/package_app.sh release
open dist/MacViewer.app
```

Trên GitHub, workflow **Ventura Build & Release** tự chạy mỗi lần push lên `main`: test → đóng gói universal → đăng DMG/ZIP vào release mới nhất (tag `v<phiên bản>`, ví dụ `v4.0`), đồng thời lưu log build ở release `ci-logs`.

## Giấy phép

Giấy phép MIT (xem `LICENSE`). Các thư viện bên thứ ba giữ giấy phép riêng (xem `THIRD_PARTY_NOTICES.md`).

---

## English

This document describes the technical changes that let MacViewer Ventura run on **macOS 13 Ventura**. A build that sets its minimum system version to macOS 14 is refused by Ventura with: *"You can't use this version of the application "MacViewer.app" with this version of macOS."* The changes: the minimum is lowered to 13.0, macOS 14-only APIs are replaced or availability-gated, and the Sectigo R46 root is bundled in the app.

Download the prebuilt app from this repo's **Releases**: `MacViewer-Ventura-<version>.dmg` or `.zip` (universal: arm64 + x86_64).

## What changed (and why)

Every API below was checked against Apple's official documentation (platform availability in Apple Developer Documentation):

| Ventura blocker | API / declaration | Available since | Handling in this build |
|---|---|---|---|
| `Package.swift` | `platforms: [.macOS(.v14)]` | — | Lowered to `.v13` |
| `scripts/package_app.sh` | `LSMinimumSystemVersion = 14.0` in Info.plist (the line that makes macOS refuse to open the app) | — | Lowered to `13.0` |
| `MacScreenCapture.swift` | `SCScreenshotManager.captureImage` | 14.0 | Kept on macOS 14+; on Ventura uses `CGDisplayCreateImage` (still returns real content on 13 once Screen Recording is granted), then scales down to the target size |
| `MacScreenCapture.swift` | `SCContentFilter.pointPixelScale`, `SCContentFilter.contentRect` | 14.0 | Pixel dimensions taken from CoreGraphics (`CGDisplayPixelsWide/High`) — `DisplayKey` already stores both values |
| `MacScreenCapture.swift` | `SCStreamConfiguration.preservesAspectRatio` | 14.0 | Set only under `#available(macOS 14.0, *)` |
| 4 UI files, 10 sites | `.onChange(of:) { _, new in … }` (two-parameter closure) | 14.0 | Back to the one-parameter form `{ new in … }` (available since macOS 11, still compiles on 14+) |
| `FramedTCPTransport.swift` | Ventura's system trust store lacks the Sectigo R46 root that UltraViewer's relay uses (Apple added it to the trust store in macOS 14.4) — the app verifies certificates against the system store, so relay connections are rejected on Ventura | 14.4 (trust store) | The R46 root is bundled in the app and added as a trust anchor when verifying the relay certificate (system anchors and the certificate-name check kept) |
| `UpdateChecker.swift` | Self-update checks | — | Points at this repo's Releases, so updates always land on a Ventura-capable build |

The remaining APIs are verified Ventura-compatible: `Scene.defaultSize` (13.0), `LabeledContent` (13.0), `FormStyle.grouped` (13.0), `SCStreamConfiguration.capturesAudio` (13.0), `scalesToFit` (12.3), `SCShareableContent`/`SCStream` (12.3).

## Known limitations on Ventura

- When **sharing this Mac's screen with someone else** (host direction), the Ventura capture path uses a legacy API: captured frames do not include the mouse cursor. The main direction — **controlling a Windows machine running UltraViewer from the Mac** — does not use this capture path and works fully.
- The build is **ad-hoc** signed (no Developer ID certificate): on manual install, the first launch needs right-click → **Open**, or `xattr -dr com.apple.quarantine /Applications/MacViewer.app`. From 3.0, app-installed updates (SHA-256 verified) no longer hit this step.
- The binary file `Sources/UltraViewerProtocol/Resources/8bit.dat` (112 KB, the protocol's Zstandard dictionary) is not stored in this repo; the workflows download it at a fixed pinned commit and verify the SHA-256 (`9aa45789…bfe6b`) before building.

## Building from source

Prebuilt builds are in Releases. To build it yourself, you need a Mac running macOS 14.5+ with Xcode 16 (only the *build* machine needs Sonoma — Xcode 16 does not run on Ventura; the built app runs on Ventura):

```sh
git clone https://github.com/ArtyormSatori/MacViewer-Ventura.git
cd MacViewer-Ventura
curl -fL -o Sources/UltraViewerProtocol/Resources/8bit.dat \
  https://raw.githubusercontent.com/DeanOpen/MacViewer/f8d1b6529e673df3fe35fccdd4b65f7474e354b7/Sources/UltraViewerProtocol/Resources/8bit.dat
MACVIEWER_UNIVERSAL=1 scripts/package_app.sh release
open dist/MacViewer.app
```

On GitHub, the **Ventura Build & Release** workflow runs on every push to `main`: test → universal package → publish the DMG/ZIP to the latest release (tag `v<version>`, e.g. `v4.0`), and store the build log in the `ci-logs` release.

## License

MIT license (see `LICENSE`). Third-party libraries keep their own licenses (see `THIRD_PARTY_NOTICES.md`).
