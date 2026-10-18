## MacViewer Ventura — 4.0.2

**Thay đổi chính**
- Sửa lỗi lag tăng dần và chết điều khiển trong phiên dài (báo cáo thực tế trên 4.0.1): trước đây khung hình đã giải mã mà chưa kịp hiển thị bị dồn thành hàng đợi ngày càng dài — hình vẫn chạy nhưng trễ dần, và hiệu quả của mỗi cú bấm chuột phải chờ cả hàng đợi đó. Bản này chỉ giữ khung hình mới nhất cho khâu hiển thị (bỏ khung cũ, đếm số đã bỏ), đồng thời điều tiết nhịp báo nhận hình theo tốc độ hiển thị thật (tối đa 2 khung chờ) nên độ trễ không còn tích lũy.
- Sửa lỗi chuột/bàn phím chết im lặng: mọi thao tác gửi lệnh điều khiển nay có thời gian chờ tối đa 5 giây — nếu đường gửi bị kẹt, app báo lỗi rõ ràng và cho bật lại điều khiển thay vì treo không dấu hiệu.
- Phát hiện đường chuyển tiếp chết một chiều: app đã có tín hiệu thăm dò tới máy đích trong mỗi phiên; bản này dùng luôn tín hiệu đó làm cổng sức khoẻ — nếu máy đích ngừng trả lời thăm dò trong khi kênh relay vẫn sống, app tự kết nối lại thay vì để phiên "sống mà không điều khiển được".
- Ngân sách làm mới màn hình sau lỗi giải mã nay được tính theo từng phiên kết nối (không cộng dồn suốt vòng đời app), và trạng thái phím/chuột đang giữ được đồng bộ lại sau mỗi lần tự kết nối lại.
- Cách cập nhật: máy đang chạy 4.0.1 sẽ thấy bản 4.0.2 qua kiểm tra cập nhật trong app — bấm **Cập nhật và khởi động lại**, app tự tải, đối chiếu SHA-256, cài đè và mở lại, không có cảnh báo "nhà phát triển chưa xác định".

**Cài thủ công lần đầu:** xem file Readme-macOS.txt đính kèm kèm release này (bỏ qua mục 2 nếu không dùng bản 1.0).

Nếu macOS báo "nhà phát triển chưa xác định" khi mở lần đầu sau khi cài thủ công, chạy lệnh này trong Terminal (một lần duy nhất): `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — hoặc mở app bằng chuột phải → Open.

CI: toàn bộ test chạy trước khi đóng gói. Đối chiếu bản tải về bằng SHA256SUMS-macOS.txt.

---

## Bản Linux

Bản Linux 4.0.2 (đồng bộ đầy đủ các sửa lỗi trên) đính kèm tại release này: `MacViewer-Ventura-4.0.2-Linux.tar.gz` và `MacViewer-Ventura-4.0.2-Linux-amd64.deb`, mỗi file kèm một file `.sha256`.

## English

**Main changes**
- Fixed progressive lag and dead control in long sessions (field report on 4.0.1): decoded frames that had not been displayed yet used to pile into an ever-growing queue — the picture kept moving but fell further behind, and every click had to wait out the queue. This release keeps only the newest frame for display (older ones are dropped and counted) and paces frame acknowledgements to the real presentation rate (at most 2 frames in flight), so latency can no longer accumulate.
- Fixed silent mouse/keyboard death: every control send is now bounded by a 5-second timeout — if the send path wedges, the app reports a clear error and lets you re-enable control instead of hanging without a trace.
- Detects a one-way-dead forwarding path: the app already probes the host every session; this release uses that probe as a health gate — if the host stops answering probes while the relay channel stays alive, the app reconnects instead of leaving a session that "looks alive but takes no input".
- The screen-refresh budget after decode errors is now per connection session (not accumulated over the app's lifetime), and held key/mouse state is resynchronised after every automatic reconnect.
- How to update: a machine running 4.0.1 will see 4.0.2 through the in-app update check — click **Update and Restart**; the app downloads it, verifies the SHA-256, installs in place and relaunches, with no "unidentified developer" prompt.

**First manual install:** see the Readme-macOS.txt attached to this release (skip section 2 unless you use release 1.0).

If macOS shows the "unidentified developer" warning on the first launch after a manual install, run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/MacViewer.app` — or open the app with right-click → Open.

CI: the full test suite runs before packaging. Verify downloads with SHA256SUMS-macOS.txt.

## Linux build

The Linux 4.0.2 build (with all of the fixes above synced) is attached to this release: `MacViewer-Ventura-4.0.2-Linux.tar.gz` and `MacViewer-Ventura-4.0.2-Linux-amd64.deb`, each with a `.sha256` sidecar.
