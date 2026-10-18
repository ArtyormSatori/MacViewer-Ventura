## MacViewer Ventura — 4.0.1

**Thay đổi chính**
- Sửa lỗi phiên tự ngắt khi để yên: app nay phát hiện được đường truyền chết im lặng (trước đây phiên có thể đã chết ngầm mà app không hề biết), mọi thao tác gửi đều có thời gian chờ tối đa, tín hiệu giữ kết nối được gửi đều trên cả hai kênh và socket bật TCP keepalive, app giữ phiên không bị App Nap bóp khi để yên, và khi kết nối rớt app tự kết nối lại (giãn cách tăng dần, trong khoảng hai phút) thay vì kết thúc phiên ngay.
- Phiên bền hơn khi phía xử lý bị quá tải: thay vì kết thúc phiên, app nay bỏ qua khung hình thừa; lỗi giải nén màn hình đơn lẻ cũng được bỏ qua và tự khôi phục thay vì làm sập phiên.
- Đặt lại tên các file đính kèm cho rõ nền tảng: bản Mac mang hậu tố -macOS, file tổng kiểm đổi thành SHA256SUMS-macOS.txt.
- Cách cập nhật: máy đang chạy 4.0 sẽ thấy bản 4.0.1 qua kiểm tra cập nhật trong app — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không có cảnh báo "nhà phát triển chưa xác định".

**Cài thủ công lần đầu:** xem file Readme-macOS.txt đính kèm kèm release này (bỏ qua mục 2 nếu không dùng bản 1.0).

Nếu macOS báo "nhà phát triển chưa xác định" khi mở lần đầu sau khi cài thủ công, chạy lệnh này trong Terminal (một lần duy nhất): `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — hoặc mở app bằng chuột phải → Open.

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-macOS.txt.

---

## Bản Linux

Bản Linux hiện ở bản dựng 4.0, đính kèm tại release 4.0 trên trang Releases; các sửa lỗi giao thức của 4.0.1 sẽ được đồng bộ sang Linux ở bước tiếp theo.

## English

**Main changes**
- Fixed sessions dropping while idle: the app now detects a silently dead connection (previously a session could be dead underneath without the app noticing), every send is time-bounded, keepalives run evenly on both channels with TCP keepalive enabled, the app holds the session against App Nap throttling while idle, and a dropped connection now reconnects automatically (with backoff, over about two minutes) instead of ending the session.
- Sessions survive processing overload: rather than ending the session, the app now sheds excess frames; isolated screen-decode errors are tolerated and recover instead of killing the session.
- Release assets renamed for clarity: Mac builds carry the -macOS suffix and the checksum file is now SHA256SUMS-macOS.txt.
- How to update: a machine running 4.0 will see 4.0.1 through the in-app update check — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.

**First manual install:** see the Readme-macOS.txt attached to this release (skip section 2 unless you use release 1.0).

If macOS shows the "unidentified developer" warning on the first launch after a manual install, run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — or open the app with right-click → Open.

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-macOS.txt.

## Linux build

The Linux build is currently at version 4.0, attached to the 4.0 release on the Releases page; the 4.0.1 protocol fixes will be synced to Linux next.
