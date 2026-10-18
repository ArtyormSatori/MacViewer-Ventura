# Security audit · Rà soát bảo mật — MacViewer Ventura (audit date · ngày rà soát: 2026-10-18)

Scope: a full source audit of the attack surfaces a remote-control app exposes: the network path, the legacy protocol cryptography, credential storage, host-side consent and input injection, parser limits against a malicious peer, and the update mechanism. "Fixed" items are changes present in this repo; "inherent" items are properties of the UltraViewer protocol itself that no compatible client can change.

Phạm vi: rà soát toàn bộ mã nguồn ở các bề mặt tấn công mà một ứng dụng điều khiển từ xa phơi ra: đường truyền mạng, mật mã của giao thức cũ, nơi lưu thông tin đăng nhập, cơ chế đồng ý và tiêm đầu vào phía máy chủ, giới hạn của các bộ phân tích cú pháp trước đối tác độc hại, và cơ chế cập nhật. Mục "Đã sửa" là các thay đổi đã có trong repo này; mục "Vốn có" là đặc tính của chính giao thức UltraViewer, không một client tương thích nào thay đổi được.

## Fixed in this fork · Đã sửa trong bản fork này

1. **Keychain access level for stored partner passwords** (`PartnerCredentialStore`): items were previously stored without an explicit `kSecAttrAccessible`, leaving protection at the platform default. They are now stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on both add and update: readable only while this Mac is unlocked, never migrated or restored to another device. (They were already non-syncing and service-scoped.) The change also applies cleanly to upstream.

   **Mức truy cập Keychain cho mật khẩu đối tác đã lưu** (`PartnerCredentialStore`): trước đây các mục được lưu mà không đặt `kSecAttrAccessible` tường minh, để mức bảo vệ theo mặc định của nền tảng. Nay chúng được lưu với `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` ở cả thao tác thêm mới lẫn cập nhật: chỉ đọc được khi máy Mac này đang mở khóa, không bao giờ được di trú hay khôi phục sang thiết bị khác. (Vốn đã không đồng bộ và đã giới hạn theo dịch vụ.) Thay đổi này cũng áp dụng sạch cho bản gốc upstream.

2. **Ventura build pipeline** (`.github/workflows/ventura-release.yml`): the single binary needed at build time (`8bit.dat`) is downloaded from upstream at a pinned commit and verified against a pinned SHA-256 before use.

   **Đường ống build cho Ventura** (`.github/workflows/ventura-release.yml`): file nhị phân duy nhất cần lúc build (`8bit.dat`) được tải từ repo gốc tại một commit đã ghim và được kiểm tra với SHA-256 đã ghim trước khi dùng.

3. **Self-update for ad-hoc builds** (from 3.0, `UpdateChecker`): upstream's self-installer requires an Apple team signature, so ad-hoc builds could not self-install before. An ad-hoc build now self-installs only when: the downloaded DMG **matches the SHA-256** in the checksum file published with the release, and the staged app is a consistently-signed ad-hoc build with the correct bundle ID. Before the swap, the app strips the `com.apple.quarantine` attribute from the staged copy (created by the already-trusted process itself from the verified download) so the relaunched app is not blocked by Gatekeeper. Team-signed builds (if any) keep upstream's team-signature requirement.

   **Tự cập nhật cho bản ký ad-hoc** (từ bản 3.0, `UpdateChecker`): bộ tự cài của bản gốc đòi chữ ký đội Apple nên bản ad-hoc trước đây không tự cài được. Nay bản ad-hoc chỉ tự cài khi: file DMG tải về **khớp mã SHA-256** trong bảng tổng đã công bố kèm release, và bản app đã staged là bản ad-hoc có chữ ký nhất quán, đúng mã định danh. Trước khi thay thế, app gỡ thuộc tính `com.apple.quarantine` khỏi bản staged (vốn do chính tiến trình đã được tin cậy tạo ra từ bản tải đã kiểm chứng) để bản mở lại không bị Gatekeeper chặn. Bản ký theo đội (nếu có) vẫn giữ nguyên yêu cầu chữ ký đội như bản gốc.

## Verified strong (no change needed) · Đã kiểm chứng là mạnh (không cần thay đổi)

- **Relay connections always use TLS** with platform verification plus certificate *name* pinning (`SecPolicyCreateSSL` + `SecTrustEvaluateWithError`) for UltraViewer's service endpoints; the SNI routing label cannot substitute for identity. (This fork adds the Sectigo R46 root as an additional anchor for Ventura — additive only, system anchors are not replaced.)
- **Host-side consent is explicit and revocable**: incoming sessions must be approved at the host; view-only and control permissions are granted separately, re-checked per input batch (`isControlAllowed`), and every held key/button is released when control permission is revoked or the session ends.
- **Host-side password proof**: the host itself verifies `MD5(nonce + password)` (`HostLoginRequest.verify`) — the password is never sent to the host, and the nonce prevents replay.
- **Malicious-peer hardening at the parser layer**: every input format has an explicit ceiling — frame/payload length (16 MB), post-decompression zstd size (128 MB), screen size (8192 / 16M pixels), chat text (64 KB), multipart part count — plus overflow-checked arithmetic in the pixel buffers.
- **Credentials live only in Keychain** (no UserDefaults/file fallback, by design and pinned by tests); secrets are never logged.
- **Updater integrity**: releases are only accepted from `github.com`; team-signed builds must pass the designated-requirement signature check with a stable team identity; ad-hoc builds must pass the SHA-256 verification in item 3 above.
- **The LAN direct-connect listener** is bounded (expiry timer, LAN addresses only) and its payloads are encrypted with a session key.

- **Kết nối relay luôn dùng TLS** với kiểm chứng của nền tảng cộng ghim *tên* chứng thư (`SecPolicyCreateSSL` + `SecTrustEvaluateWithError`) cho các đầu dịch vụ của UltraViewer; nhãn định tuyến SNI không thể thay thế danh tính. (Bản fork cộng thêm chứng thư gốc Sectigo R46 làm neo bổ sung cho Ventura — chỉ cộng thêm, không thay thế neo hệ thống.)
- **Đồng ý phía máy chủ là tường minh và thu hồi được**: phiên đến phải được duyệt tại máy; quyền chỉ-xem và quyền điều khiển được cấp riêng, kiểm tra lại theo từng lô đầu vào (`isControlAllowed`), và mọi phím/nút đang nhấn đều được nhả ra khi quyền điều khiển bị thu hồi hoặc phiên kết thúc.
- **Bằng chứng mật khẩu phía máy chủ**: máy chủ tự kiểm chứng `MD5(nonce + mật khẩu)` (`HostLoginRequest.verify`) — mật khẩu không bao giờ được gửi tới máy chủ, và nonce ngăn phát lại.
- **Chống đối tác độc hại ở tầng phân tích cú pháp**: mọi định dạng đầu vào đều có trần tường minh — độ dài khung/tải tin (16 MB), kích thước sau giải nén zstd (128 MB), kích thước màn hình (8192 / 16 triệu điểm), văn bản chat (64 KB), số phần multipart — cùng số học chống tràn trong các bộ đệm điểm ảnh.
- **Thông tin đăng nhập chỉ sống trong Keychain** (không có đường dự phòng UserDefaults/file, theo thiết kế và có test chốt); bí mật không bị ghi vào log.
- **Tính toàn vẹn của trình cập nhật**: release chỉ được nhận từ `github.com`; bản ký đội phải qua kiểm tra chữ ký theo yêu cầu chỉ định với định danh đội ổn định; bản ad-hoc phải qua kiểm chứng SHA-256 như mục 3 ở trên.
- **Listener kết nối trực tiếp qua LAN** có giới hạn (hẹn giờ hết hạn, chỉ địa chỉ LAN) và tải tin của nó được mã hóa bằng khóa phiên.

## Inherent to the UltraViewer protocol (not fixable client-side) · Vốn có trong giao thức UltraViewer (không sửa được ở phía client)

- **Legacy cryptography**: the command channel uses 3DES with a key derived from SHA1 and a fixed IV; the screen envelope uses AES-CBC with no MAC. This is UltraViewer's recovered on-the-wire format — changing it would break compatibility with every UltraViewer host and client. Relay hops are additionally wrapped in TLS (see above).
- **8-digit host password** (~10^8 possibilities): UltraViewer's account convention. Online guessing is limited by the relay and the nonce challenge, but users should treat the ID + password pair like a key: do not publish it. (This fork's unattended mode uses this same password-proof mechanism, plus macOS's Screen Recording/Accessibility permission gates.)
- **Trust in the relay**: session-setup metadata passes through UltraViewer's relay servers, as in the original product.
- **Clipboard sharing on by default** (upstream behavior, matching UltraViewer on Windows): within a session, text copied on one side is shared to the other. It can be turned off in Settings; the session UI shows its state.

- **Mật mã cũ**: kênh lệnh dùng 3DES với khóa suy từ SHA1 và IV cố định; phong bì màn hình dùng AES-CBC không có MAC. Đây là định dạng trên dây đã khôi phục của chính UltraViewer — thay đổi nó sẽ phá tương thích với mọi máy chủ và client UltraViewer. Các chặng qua relay còn được bọc thêm TLS (xem trên).
- **Mật khẩu máy chủ 8 chữ số** (~10^8 khả năng): quy ước tài khoản của UltraViewer. Việc đoán trực tuyến bị giới hạn bởi relay và thử thách nonce, nhưng người dùng nên coi cặp ID + mật khẩu như một chiếc chìa khóa: đừng công bố. (Chế độ không-người-ngồi-máy của bản fork dùng chính cơ chế bằng chứng mật khẩu này, cộng thêm cổng quyền hệ thống Ghi màn hình/Trợ năng của macOS.)
- **Niềm tin vào relay**: siêu dữ liệu thiết lập phiên đi qua máy chủ trung gian của UltraViewer, giống sản phẩm gốc.
- **Chia sẻ clipboard mặc định bật** (hành vi của bản gốc, khớp với UltraViewer trên Windows): trong một phiên, văn bản sao chép ở một phía sẽ được chia sẻ sang phía kia. Có thể tắt trong Cài đặt; giao diện phiên hiển thị trạng thái của nó.

## Note on the Ventura build · Ghi chú về bản Ventura

This fork's releases are **ad-hoc** signed (no Apple Developer certificate), so Gatekeeper warns on the first launch of a manual install; verify downloads against the `SHA256SUMS-Ventura.txt` published with each release. From 3.0, app-installed updates no longer hit this warning (see item 3).

Bản phát hành của fork này ký **ad-hoc** (không có chứng chỉ Apple Developer), nên Gatekeeper sẽ cảnh báo ở lần mở đầu tiên khi cài thủ công; hãy đối chiếu bản tải về với `SHA256SUMS-Ventura.txt` công bố kèm mỗi release. Từ bản 3.0, các bản cập nhật do app tự cài sẽ không còn gặp cảnh báo này (xem mục 3).
