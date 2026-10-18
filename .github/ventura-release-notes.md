Bản MacViewer 0.3.4 được build lại từ mã nguồn gốc (DeanOpen/MacViewer @ f8d1b65) để chạy trên **macOS 13 Ventura** — bản gốc yêu cầu macOS 14 Sonoma nên Ventura báo "Bạn không thể sử dụng phiên bản này của ứng dụng MacViewer.app với phiên bản macOS này".

Thay đổi so với bản gốc (xem VENTURA.md): hạ deployment target xuống macOS 13.0, thay 4 API chỉ có trên macOS 14 (SCScreenshotManager, SCContentFilter.pointPixelScale/contentRect, SCStreamConfiguration.preservesAspectRatio, onChange hai tham số), và trỏ trình kiểm tra cập nhật về repo này để app không tự "cập nhật" trở lại bản macOS 14.

Cài đặt: tải MacViewer-0.3.4-Ventura.dmg (hoặc .zip), kéo MacViewer vào Applications. Bản build ký ad-hoc nên lần đầu mở hãy nhấp chuột phải vào app -> Open, hoặc chạy: xattr -dr com.apple.quarantine /Applications/MacViewer.app

Universal binary: Apple Silicon (arm64) + Intel (x86_64).
