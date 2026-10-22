## MacViewer Ventura — 5.0.1

**Thay đổi chính**

- **Sửa lỗi bản 5.0 không mở lên được.** Gói cài đặt của bản 5.0 thiếu mất một thành phần bắt buộc là WebRTC framework — thành phần phục vụ Chế độ 2 (Tự host) — nên ngay khi mở app, macOS không tìm thấy thành phần này và đóng app lập tức. Bản 5.0.1 đóng gói đầy đủ thành phần đó vào trong app, và quy trình đóng gói từ nay tự kiểm tra để không một bản phát hành nào còn thiếu thành phần mà app cần khi khởi động.
- **Mọi thứ còn lại giữ nguyên như bản 5.0:** hai chế độ kết nối trong cùng một app (chế độ mặc định qua UltraViewer giữ nguyên hành vi của dòng 4.0.x; chế độ Tự host kết nối hai máy cùng chạy MacViewer Ventura qua máy chủ mesh do bạn tự vận hành, hình ảnh và điều khiển truyền trực tiếp giữa hai máy bằng WebRTC), cửa sổ chat chung cho cả hai chế độ, biểu tượng app mới, giao diện sáng và tối, và mục chọn ngôn ngữ Tiếng Việt/English trong Cài đặt.

**Quan trọng — nếu bản 5.0 trên máy bạn mở lên là đóng ngay:** bản 5.0 bị lỗi đó không thể tự cập nhật, vì app chưa kịp mở đã bị đóng. Hãy tải bản 5.0.1 từ trang Releases này và cài thủ công một lần: giải nén, chép đè vào thư mục Applications, rồi mở lần đầu bằng chuột phải → Open. Sau lần cài thủ công này, các lần cập nhật về sau lại diễn ra ngay trong app như bình thường.

- **Máy đang chạy 4.0.x không bị ảnh hưởng bởi lỗi trên:** app vẫn mở bình thường, và bạn chỉ cần cập nhật trong app như mọi lần — app sẽ đi thẳng lên bản 5.0.1, không cần qua bản 5.0.

**Cài thủ công lần đầu:** xem file Readme-macOS.txt đính kèm kèm release này (bỏ qua mục 2 nếu không dùng bản 1.0).

Nếu macOS báo "nhà phát triển chưa xác định" khi mở lần đầu sau khi cài thủ công, chạy lệnh này trong Terminal (một lần duy nhất): `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — hoặc mở app bằng chuột phải → Open.

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-macOS.txt.

---

## English

**Main changes**

- **Fixes version 5.0 failing to open at all.** The 5.0 package was missing a required component, the WebRTC framework — the component that powers Mode 2 (self-hosted) — so the moment the app was opened, macOS could not find that component and closed the app immediately. Version 5.0.1 packages that component inside the app in full, and the packaging process now checks itself, so no future release can ship missing a component the app needs at launch.
- **Everything else is identical to version 5.0:** two connection modes in one app (the default mode through UltraViewer keeps the exact behavior of the 4.0.x line; the self-hosted mode connects two machines running MacViewer Ventura through a mesh server you operate yourself, with the picture and control traveling directly between the two machines over WebRTC), one shared chat window for both modes, the new app icon, light and dark appearances, and the Tiếng Việt/English language setting in Settings.

**Important — if version 5.0 on your machine closes the moment you open it:** a 5.0 copy with this fault cannot update itself, because the app is closed before it can run. Download version 5.0.1 from this Releases page and install it manually once: unzip it, copy it over the existing app in your Applications folder, then open it the first time with right-click → Open. After this one manual install, later updates happen inside the app as usual.

- **Machines still running 4.0.x are not affected by the fault:** the app opens normally, and you update in-app as always — the app goes straight to version 5.0.1, with no need to pass through 5.0.

**First manual install:** see the Readme-macOS.txt attached to this release (skip section 2 unless you use release 1.0).

If macOS shows the "unidentified developer" warning on the first launch after a manual install, run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — or open the app with right-click → Open.

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-macOS.txt.
