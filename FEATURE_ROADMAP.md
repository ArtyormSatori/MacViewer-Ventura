# Feature roadmap · Lộ trình tính năng bổ sung (repo owner's request · yêu cầu của chủ repo, 2026-10-18)

Technical-honesty principle: MacViewer speaks the **UltraViewer protocol** through UltraViewer's relay servers. A feature that depends on both ends of the wire is only fully possible when the other end is also MacViewer (Mac↔Mac); when the other end is UltraViewer on Windows, the ceiling is the UltraViewer protocol itself. Each item below states that ceiling.

Nguyên tắc trung thực kỹ thuật: MacViewer nói chuyện bằng **giao thức UltraViewer** qua máy chủ trung gian của UltraViewer. Tính năng nào phụ thuộc cả hai đầu dây thì chỉ làm được trọn vẹn khi đầu kia cũng là MacViewer (Mac↔Mac); đầu kia là UltraViewer trên Windows thì bị trần của chính giao thức UltraViewer. Từng mục dưới đây ghi rõ trần đó.

## Stage A — client-side, doable now on the Ventura base · Giai đoạn A — phía client, làm được ngay trên nền bản Ventura

1. **Unattended access** — ✅ DONE (branch stage-a)
   Mechanism clarified: the host already verifies the connecting party's password proof itself (nonce challenge in `UltraViewerHostSession`) BEFORE showing the on-screen prompt — the Approve button is only a second consent layer. So on the legacy protocol there is no separate second password; unattended = auto-approve after the password proof matches. Added: a Settings toggle (on/off, control or view-only), auto-start sharing at app launch when enabled, Login Item (SMAppService, macOS 13+), and sleep prevention while sharing. If permissions (Screen Recording/Accessibility) are missing, the request waits for manual approval as before. Unit tests cover the decision logic.

   **Truy cập không cần người ngồi máy (unattended)** — ✅ ĐÃ LÀM (nhánh stage-a)
   Làm rõ cơ chế: phía host vốn đã tự xác minh bằng chứng mật khẩu của người kết nối (thử thách nonce trong `UltraViewerHostSession`) TRƯỚC khi hiện yêu cầu lên màn hình — nút Duyệt chỉ là lớp đồng ý thứ hai. Vì vậy trên giao thức legacy không có mật khẩu thứ hai riêng; unattended = tự duyệt sau khi bằng chứng mật khẩu đã khớp. Đã bổ sung: công tắc trong Cài đặt (bật/tắt, cho điều khiển hay chỉ xem), tự khởi động chia sẻ khi mở app nếu đang bật, Login Item (SMAppService, macOS 13+), và ngăn máy ngủ khi đang chia sẻ. Thiếu quyền (Quay màn hình/Tiếp cận) thì yêu cầu vẫn nằm chờ duyệt tay như cũ. Có unit test cho logic quyết định.

2. **US / VNI keyboard**
   `KeyboardMessage` carries virtual-key + scan-code + 1 UTF-16 character; the encoder currently converts single ASCII characters only (`MacRemoteInputEncoder`). Added keyboard modes: (a) physical keycode (US, as now); (b) VNI passthrough — the Mac-side IME does not swallow keys; raw letter + digit keys are sent so the VNI IME (Unikey) on the Windows side composes the marks itself; (c) Text mode — sends precomposed Unicode characters for the remaining cases.

   **Bàn phím US / VNI**
   `KeyboardMessage` mang virtual-key + scan-code + 1 ký tự UTF-16; encoder hiện chỉ chuyển ký tự ASCII đơn (`MacRemoteInputEncoder`). Bổ sung chế độ bàn phím: (a) Keycode vật lý (US, như hiện tại); (b) VNI passthrough — không để bộ gõ phía Mac nuốt phím, gửi nguyên phím chữ + số để bộ gõ VNI (Unikey) phía Windows tự ghép dấu; (c) Text mode — gửi ký tự Unicode đã ghép sẵn cho các trường hợp còn lại.

3. **16-bit / 32-bit color + image quality** — ADJUSTED AFTER A DEEP READ (2026-10-18) · ĐÃ ĐIỀU CHỈNH SAU KHI ĐỌC SÂU (2026-10-18)
   Measured fact: BOTH image paths of the protocol are RGB555 — the legacy path and the "modern" one (main frames RGB555; the only full color lives in the auxiliary JPEG atlas of UltraViewer Windows). So "32-bit" cannot be fitted into any existing frame format; true 32-bit color for Mac↔Mac would need a separate side channel outside UltraViewer's screen commands (separate design work, not done).
   What fits inside the protocol ceiling — DONE (branch stage-a): ordered dithering (Bayer 4×4) when down-converting BGRA → RGB555 on the host. Previously truncation (>>3) caused visible color banding on gradients; now each pixel is rounded by its positional Bayer threshold — gradients are visibly smoother, flat colors stay bit-exact, and static frames still produce the identical byte stream (the unchanged-frame skip mechanism is preserved). Unit-tested.
   RustDesk-grade quality (H.264/VP9 + UDP) is not achievable while going through the UltraViewer protocol; this item only improves within that ceiling.

   Sự thật đo được: CẢ HAI đường hình của giao thức đều là RGB555 — đường legacy và cả đường "modern" (khung chính RGB555; màu đầy đủ duy nhất nằm ở atlas JPEG phụ của UltraViewer Windows). Vì vậy "32-bit" không thể nhét vào bất kỳ định dạng khung sẵn có nào; muốn có màu 32-bit thật cho Mac↔Mac phải dựng một kênh phụ riêng ngoài các lệnh màn hình của UltraViewer (việc thiết kế riêng, chưa làm).
   Phần làm được ngay trong trần giao thức — ĐÃ LÀM (nhánh stage-a): dithering có thứ tự (Bayer 4x4) khi hạ BGRA → RGB555 phía host. Trước đây chặt cụt (>>3) gây vệt bậc màu rõ trên gradient; nay mỗi pixel được làm tròn theo ngưỡng Bayer theo vị trí, gradient mịn hẳn mà màu phẳng vẫn chính xác tuyệt đối, và khung tĩnh vẫn cho ra cùng một dãy byte (giữ nguyên cơ chế bỏ qua khung không đổi). Có unit test.
   Chất lượng kiểu RustDesk (H.264/VP9 + UDP) không đạt được khi còn đi qua giao thức UltraViewer; mục này chỉ cải thiện trong trần đó.

## Stage B — both ends MacViewer · Giai đoạn B — hai đầu MacViewer

4. **File sending (Mac↔Mac)**
   The protocol currently has no file-transfer command (only chat commands 12/29/30 and clipboard). Add a separate file channel between two MacViewer instances: chunked, integrity-checked, send/receive with a progress bar in the Session Tools window. With a Windows UltraViewer peer: NOT possible from this client, because UltraViewer publishes no compatible file-transfer command.

   **Gửi file (Mac↔Mac)**
   Giao thức hiện không có lệnh truyền file (chỉ có chat lệnh 12/29/30 và clipboard). Bổ sung kênh file riêng giữa hai MacViewer: chia khối, kiểm tra toàn vẹn, gửi/nhận có thanh tiến độ trong cửa sổ Session Tools. Với đầu Windows UltraViewer: KHÔNG làm được từ phía client này vì UltraViewer không công bố lệnh truyền file tương thích.

## Stage C — needs its own server, decide the approach first · Giai đoạn C — cần máy chủ riêng, phải chốt phương án trước

5. **DeskIn-style account management**
   The current build has no account concept: identity is a numeric ID issued by the UltraViewer relay (`ClientRegistration`). Login, per-account device lists and multi-machine sync require a backend: (a) self-host on the repo owner's server (vega + Cloudflare Tunnel); (b) Supabase/Firebase free tier; (c) local profiles on the machine for now. This is a separate sub-project (registration/login, security, sync) and is not bundled into the first Ventura build.

   **Quản lý theo tài khoản kiểu DeskIn**
   Bản hiện tại không có khái niệm tài khoản: danh tính là ID số do relay UltraViewer cấp (`ClientRegistration`). Muốn có đăng nhập, danh sách thiết bị theo tài khoản, đồng bộ nhiều máy thì phải có backend: (a) tự host trên máy chủ của chủ repo (vega + Cloudflare Tunnel); (b) Supabase/Firebase free tier; (c) tạm để hồ sơ cục bộ trên máy. Đây là một tiểu dự án riêng (đăng ký/đăng nhập, bảo mật, đồng bộ), không gộp vào bản Ventura đầu tiên.

## Quality pack · Gói chất lượng (added request · yêu cầu bổ sung 2026-10-18: as smooth + sharp as RustDesk · mượt + nét như RustDesk)

Measurements from the current code show the real bottlenecks:
Số liệu đo từ code hiện tại cho thấy nút thắt thật:

- The host (controlled Mac) captures the screen on a **250 ms** cadence (`UltraViewerHostSession`, waiting for an ACK per frame) → at most ~4 FPS. This is the largest source of jerkiness, not the network.
- The modern path compresses with Zstd level 1 (speed-first); the RGB555 image shows clear banding on gradients.
- The viewer already has Automatic / Speed / Quality / Custom levels.

- Phía host (Mac bị điều khiển) chụp màn hình theo nhịp **250 ms/lần** (`UltraViewerHostSession`, chờ ACK từng khung) → tối đa ~4 FPS. Đây là nguồn giật lớn nhất, không phải mạng.
- Đường modern nén Zstd level 1 (ưu tiên tốc độ), ảnh RGB555 gây vệt bậc màu (banding) rõ trên gradient.
- Phía viewer đã có sẵn các mức Automatic / Speed / Quality / Custom.

Levers for Stage A2 (Mac↔Mac gains the most):
Đòn bẩy sẽ làm trong Giai đoạn A2 (Mac↔Mac đạt nhiều nhất):

1. Adaptive capture pacing — ✅ DONE (branch stage-a): `HostCapturePacing` halves the delay whenever a frame actually changes (floor 50 ms → up to ~20 captures/second, still queued behind the viewer's ACKs) and doubles it when frames are unchanged (ceiling 1000 ms → a static screen costs ~1 capture/second; a change is caught within 1 second and ramps back to maximum within a few frames). Unit tests cover the pacing state machine.
   Nhịp chụp thích ứng — ✅ ĐÃ LÀM (nhánh stage-a): `HostCapturePacing` giảm một nửa độ trễ mỗi khi khung hình thật sự thay đổi (sàn 50 ms → tối đa ~20 lần chụp/giây, vẫn xếp hàng theo ACK của phía xem) và tăng gấp đôi khi khung không đổi (trần 1000 ms → màn hình tĩnh chỉ tốn ~1 lần chụp/giây, có thay đổi là bắt lại trong vòng 1 giây rồi tăng tốc về tối đa sau vài khung). Có unit test cho máy trạng thái nhịp.
2. 32-bit color (item 3 in Stage A) — removes banding on gradient images.
   Màu 32-bit (mục 3 ở Giai đoạn A) — hết banding trên ảnh gradient.
3. Zstd tuning per quality mode — RE-EVALUATED (correction): `ZstdScreenEncoder` IS on the real path — it compresses legacy host frames (`HostedScreenMessage`) and the clipboard, currently fixed at level 1 with no dictionary. Raising the level for static frames is feasible (every zstd level is decompressible by the peer) but trades host CPU, and there is no real measurement yet to pick a level — deferred until a real Ventura machine measures FPS/bandwidth in Stage A2 round 2. Not done.
   Tinh chỉnh Zstd theo chế độ chất lượng — ĐÁNH GIÁ LẠI (đính chính): ZstdScreenEncoder CÓ nằm trên đường thật — nó nén khung hình legacy phía host (`HostedScreenMessage`) và clipboard, đang cố định level 1 không dictionary. Nâng level cho khung tĩnh là khả thi (mọi level zstd đều giải nén được phía đối tác) nhưng đánh đổi CPU phía host và chưa có số đo thực tế để chọn mức — để dành khi có máy Ventura thật đo FPS/băng thông ở Giai đoạn A2 vòng 2. Chưa làm.
4. Prefer the LAN direct path (`TCPDirectPeerTransport` already exists) and show clearly whether the session is direct or via relay — waiting on a design together with the Mac↔Mac side channel in Stage B.
   Ưu tiên đường kết nối trực tiếp trong LAN (đã có `TCPDirectPeerTransport`) và hiển thị rõ đang đi trực tiếp hay qua relay — chờ thiết kế cùng kênh phụ Mac↔Mac ở Giai đoạn B.
5. Viewer: coalesce to the newest frame — RE-EVALUATED: the viewer's event stream already has a bounded buffer at the relay layer (bufferingOldest(8)); the adapter layer consumes each frame in a few microseconds (just assigns the displayed frame). The risk of frame pile-up causing latency is low and transient; left untouched to avoid breaking a pipeline that works. Smooth scaling is already on by default.
   Viewer: gộp khung mới nhất — ĐÁNH GIÁ LẠI: luồng sự kiện phía xem đã có trần đệm ở tầng relay (bufferingOldest(8)); tầng adapter tiêu thụ từng khung trong vài micro-giây (chỉ gán frame hiển thị). Nguy cơ dồn khung gây trễ là thấp và thoáng qua; không can thiệp để tránh phá đường ống đang chạy đúng. Smooth scaling vốn đã bật mặc định.

The honest ceiling: RustDesk uses its own protocol with hardware H.264/VP9 video over UDP. When the other end is UltraViewer Windows, the quality ceiling belongs to the UltraViewer protocol itself (TCP relay, rectangle updates, 16-bit) — no client can exceed it. This pack raises quality to that ceiling, and well beyond it for Mac↔Mac sessions where we control both ends.

Trần trung thực: RustDesk dùng giao thức riêng, nén video phần cứng H.264/VP9 qua UDP. Khi đầu kia là UltraViewer Windows, trần chất lượng là của chính giao thức UltraViewer (TCP relay, cập nhật theo hình chữ nhật, 16-bit) — không một client nào vượt được trần đó. Gói này nâng tới trần đó, và nâng cao hơn hẳn cho phiên Mac↔Mac nơi ta kiểm soát cả hai đầu.
