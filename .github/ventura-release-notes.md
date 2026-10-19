## MacViewer Ventura — 5.0

**Thay đổi chính**

- **Hai chế độ kết nối trong cùng một app.** Chế độ mặc định đi qua UltraViewer hoạt động đúng như các bản 4.x. Chế độ mới **Tự host** kết nối hai máy cùng chạy MacViewer Ventura thông qua một máy chủ mesh do bạn tự vận hành: chuyển chế độ bằng nút gạt ngay dưới thanh tiêu đề của cửa sổ chính.
- **Chế độ Tự host cần máy chủ của riêng bạn.** Bản 5.0 không kèm máy chủ công cộng: bạn dựng máy chủ mesh (một chương trình Go nhỏ, mã nguồn nằm ngay trong repo này) trên máy của mình hoặc trên một VPS, rồi nhập địa chỉ máy chủ trong Cài đặt → Máy chủ tự host. Hướng dẫn cụ thể từng bước — dựng máy chủ, tạo mã mời, đăng ký máy, ghép nối và kết nối — nằm trong [SELF_HOSTING.md](https://github.com/ArtyormSatori/MacViewer-Ventura/blob/main/SELF_HOSTING.md).
- **Hình ảnh và điều khiển qua WebRTC ở chế độ Tự host.** Sau khi hai máy được ghép nối (một bên gửi yêu cầu bằng Mesh ID 9 số, bên kia duyệt), hình ảnh truyền trực tiếp giữa hai máy bằng WebRTC với mã hoá H.264 bằng phần cứng và mã hoá đầu cuối; máy chủ chỉ làm nhiệm vụ đăng ký, ghép nối và chuyển tiếp tín hiệu bắt tay — không thấy nội dung màn hình của bạn. Thanh công cụ của phiên hiện huy hiệu **Trực tiếp** hoặc **Qua relay** cùng độ trễ và tốc độ khung hình thật. Máy chủ được điều khiển vẫn là bên duyệt mỗi phiên, và quyền xem/quyền điều khiển cấp riêng như trước.
- **Chat dùng chung một cửa sổ nổi cho cả hai chế độ.** Cửa sổ chat của bản 5.0 phục vụ cả phiên UltraViewer lẫn phiên Tự host, lưu lịch sử theo từng đối tác và hiện số tin chưa đọc. Trạng thái "Đã gửi" ghi đúng mức đường truyền chứng minh được: tin đã được trao cho đường gửi, không phải "đối tác đã đọc".
- **Giao diện làm mới.** Biểu tượng app mới ngay trong bản dựng, cửa sổ chính mang tên "MacViewer Ventura", hỗ trợ đủ giao diện sáng và tối (mặc định theo hệ thống, tự chọn lại trong Cài đặt → Chung), và mục Ngôn ngữ (Tiếng Việt/English) áp dụng cho toàn app trong Cài đặt → Chung.
- **Chế độ UltraViewer giữ nguyên hành vi của 4.0.3**, gồm toàn bộ các sửa lỗi lag và chết điều khiển đã phát hành ở 4.0.3.
- Cách cập nhật: máy đang chạy 4.0.x sẽ thấy bản 5.0 qua kiểm tra cập nhật trong app — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không có cảnh báo "nhà phát triển chưa xác định".

**Cài thủ công lần đầu:** xem file Readme-macOS.txt đính kèm kèm release này (bỏ qua mục 2 nếu không dùng bản 1.0).

Nếu macOS báo "nhà phát triển chưa xác định" khi mở lần đầu sau khi cài thủ công, chạy lệnh này trong Terminal (một lần duy nhất): `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — hoặc mở app bằng chuột phải → Open.

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-macOS.txt.

---

## Bản Linux

Bản Linux 5.0 sẽ được đính kèm vào release này sau khi hoàn tất đồng bộ; bản Linux hiện tại vẫn là 4.0.3 ở release tương ứng.

## English

**Main changes**

- **Two connection modes in one app.** The default mode goes through UltraViewer and behaves exactly as in the 4.x releases. The new **Self-hosted** mode connects two machines running MacViewer Ventura through a mesh server you operate yourself: switch modes with the segmented control under the main window's title bar.
- **Self-hosted mode needs your own server.** Version 5.0 bundles no public server: you run the mesh server (a small Go program whose source is in this repository) on your own machine or a VPS, then enter its address in Settings → Self-hosted server. A concrete step-by-step guide — running the server, creating invite codes, registering a device, pairing and connecting — is in [SELF_HOSTING.md](https://github.com/ArtyormSatori/MacViewer-Ventura/blob/main/SELF_HOSTING.md).
- **Picture and control over WebRTC in self-hosted mode.** Once two machines are paired (one side requests by the 9-digit Mesh ID, the other approves), the picture travels directly between the machines over WebRTC with hardware H.264 encoding and end-to-end encryption; the server only handles registration, pairing and handshake signaling — it never sees your screen content. The session toolbar shows a **Direct** or **Relay** badge with live latency and frame rate. The controlled machine still approves every session, with view and control permissions granted separately, as before.
- **One shared floating chat window for both modes.** The 5.0 chat window serves both UltraViewer sessions and self-hosted sessions, keeps per-partner history, and shows unread counts. The "Sent" state records exactly what the transport can prove: the message was handed to the send path, not that the partner has read it.
- **Refreshed interface.** The new app icon ships inside the build, the main window is titled "MacViewer Ventura", light and dark appearances are both fully supported (system by default, changeable in Settings → General), and a Language setting (Tiếng Việt/English) applies app-wide in Settings → General.
- **The UltraViewer mode keeps the 4.0.3 behavior**, including all the lag and dead-control fixes shipped in 4.0.3.
- How to update: a machine running 4.0.x will see 5.0 through the in-app update check — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.

**First manual install:** see the Readme-macOS.txt attached to this release (skip section 2 unless you use release 1.0).

If macOS shows the "unidentified developer" warning on the first launch after a manual install, run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — or open the app with right-click → Open.

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-macOS.txt.

## Linux build

The Linux build of 5.0 will be attached to this release once its sync is complete; the current Linux build remains 4.0.3 on its own release.
